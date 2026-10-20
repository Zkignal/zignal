import Foundation

/// Server and Tor choices for one profile's wallet. Stored inside that profile's encrypted
/// file, so the real and decoy profiles can differ and nothing about them shows on disk.
struct WalletSettings: Codable, Equatable, Sendable {
    struct Server: Codable, Hashable, Sendable {
        var host: String
        var port: Int

        var label: String { "\(host):\(port)" }

        /// Parses "host:port" or "host" (port 443). Nil for anything else.
        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let host = parts.first, !host.isEmpty,
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return nil }
            let port = parts.count == 2 ? Int(parts[1]) : 443
            guard let port, (1...65535).contains(port) else { return nil }
            self.host = String(host)
            self.port = port
        }

        init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    /// The first server is used for syncing; the rest are fallbacks.
    var servers: [Server]
    var torEnabled: Bool

    /// Public lightwalletd servers listed in the Zcash Swift SDK's own sample app. Not run by
    /// Zignal. The user can replace them with any server, including their own.
    static let defaultServers: [Server] = [
        Server(host: "zec.rocks", port: 443),
        Server(host: "na.zec.rocks", port: 443),
        Server(host: "eu.zec.rocks", port: 443),
        Server(host: "lwd1.zcash-infra.com", port: 9067),
        Server(host: "lwd2.zcash-infra.com", port: 9067),
    ]

    /// Tor starts off (faster, more reliable start); the user can turn it on in Network.
    static let standard = WalletSettings(servers: defaultServers, torEnabled: false)
}

/// ZIP-321 payment requests for the wallet.
enum PaymentRequest {
    private static let bech32Characters = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// A mainnet unified address and nothing else: "u1" followed only by bech32 characters.
    /// Addresses from invites go into payment requests, so anything that could add request
    /// parameters ("&", "=", "?") or point elsewhere is rejected here.
    static func isShieldedAddress(_ address: String) -> Bool {
        guard address.hasPrefix("u1"), (20...1000).contains(address.count) else { return false }
        return address.dropFirst(2).allSatisfy { bech32Characters.contains($0) }
    }

    /// One zero-value payment per memo, all to `address`, in one transaction. The memos go on
    /// chain byte for byte: ZIP-321 carries them as base64url and the wallet writes them as is.
    static func memos(_ memos: [Data], to address: String) -> String {
        uri(memos.map { (address, "0", $0) })
    }

    /// Payments of `amounts` (zatoshis) to `address`, without memos.
    static func payments(_ amounts: [Int64], to address: String) -> String {
        uri(amounts.map { (address, zec($0), nil) })
    }

    /// ZIP-321 indexes: the first payment has no index, the next ones use .1, .2, ...
    private static func uri(_ payments: [(address: String, amount: String, memo: Data?)]) -> String {
        var params: [String] = []
        for (i, payment) in payments.enumerated() {
            let suffix = i == 0 ? "" : ".\(i)"
            params.append("address\(suffix)=\(payment.address)")
            params.append("amount\(suffix)=\(payment.amount)")
            if let memo = payment.memo {
                params.append("memo\(suffix)=\(Base64URL.encode(memo))")
            }
        }
        return "zcash:?" + params.joined(separator: "&")
    }

    /// Zatoshis as a ZIP-321 decimal ZEC amount: "0.0001", "1", never exponent notation.
    static func zec(_ zatoshis: Int64) -> String {
        let whole = zatoshis / 100_000_000
        let fraction = zatoshis % 100_000_000
        guard fraction != 0 else { return "\(whole)" }
        var digits = String(format: "%08lld", fraction)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits)"
    }
}

/// Unpadded base64url (RFC 4648 section 5), as ZIP-321 and invite codes use.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard base64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else {
            return nil
        }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The text form of a zkw invite, shown as a QR code or shared as text: "zignal:" + base64url.
enum InviteCode {
    static let prefix = "zignal:"

    static func encode(_ invite: Data) -> String {
        prefix + Base64URL.encode(invite)
    }

    /// Accepts the code with or without the prefix and ignores whitespace and line breaks.
    static func decode(_ text: String) -> Data? {
        var body = text.filter { !$0.isWhitespace }
        if body.lowercased().hasPrefix(prefix) { body.removeFirst(prefix.count) }
        guard let bytes = Base64URL.decode(body), bytes.count > 6, bytes.prefix(4) == Data("ZWI1".utf8) else {
            return nil
        }
        return bytes
    }

    /// The address the invite asks to be paid at, as text. Nil if it runs past the end.
    static func address(_ invite: Data) -> String? {
        let bytes = [UInt8](invite)
        guard bytes.count > 6 else { return nil }
        let length = Int(bytes[4]) << 8 | Int(bytes[5])
        guard bytes.count >= 6 + length else { return nil }
        return String(bytes: bytes[6..<6 + length], encoding: .utf8)
    }

    /// The inviter's identity key (32 bytes), read from the invite layout in zkw-core
    /// (magic, address length, address, then the bundle, which starts with that key).
    static func inviterID(_ invite: Data) -> Data? {
        let bytes = [UInt8](invite)
        guard bytes.count > 6 else { return nil }
        let addressLength = Int(bytes[4]) << 8 | Int(bytes[5])
        let start = 6 + addressLength
        guard bytes.count >= start + 32 else { return nil }
        return Data(bytes[start..<start + 32])
    }
}

/// One shielded output of a wallet transaction, reduced to what decides whether it carries a
/// message for us. Mapped from the SDK's output type so this logic stays testable.
struct WalletOutput: Equatable {
    enum Memo: Equatable {
        /// The wallet hasn't fetched the full transaction yet, so the memo isn't known.
        case notFetched
        /// ZIP-302 binary memo: the 511 bytes after the leading 0xFF.
        case binary([UInt8])
        /// Text, empty or any other memo: not a zkw envelope.
        case other
    }

    /// The output was created by this wallet (our own sends and self-transfers).
    let fromUs: Bool
    let isChange: Bool
    let isShielded: Bool
    let memo: Memo
}

enum IncomingMemos {
    /// The 512-byte memos addressed to us in one transaction, or nil while the wallet is still
    /// fetching it (memos unknown). Our own outputs, change and transparent outputs never
    /// carry messages for us.
    static func extract(from outputs: [WalletOutput]) -> [Data]? {
        var memos: [Data] = []
        for output in outputs where output.isShielded && !output.fromUs && !output.isChange {
            switch output.memo {
            case .notFetched:
                return nil
            case .binary(let bytes):
                if let memo = fullMemo(binary: bytes) { memos.append(memo) }
            case .other:
                continue
            }
        }
        return memos
    }

    /// Rebuilds the 512-byte memo from the bytes after its 0xFF marker.
    static func fullMemo(binary bytes: [UInt8]) -> Data? {
        guard bytes.count <= 511 else { return nil }
        var memo = Data([0xFF])
        memo.append(contentsOf: bytes)
        memo.append(Data(count: 512 - memo.count))
        return memo
    }
}

/// Amounts for display: ZEC with up to 8 decimals, trailing zeros trimmed.
enum ZecFormat {
    static func string(_ zatoshis: Int64) -> String {
        let sign = zatoshis < 0 ? "-" : ""
        return "\(sign)\(PaymentRequest.zec(abs(zatoshis))) ZEC"
    }
}
