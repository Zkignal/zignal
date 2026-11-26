import CryptoKit
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

    /// Only the first server is used, for syncing and for sending. The others are there to be
    /// moved to the top by hand (Network settings); the app never switches on its own.
    var servers: [Server]
    var torEnabled: Bool

    /// Public lightwalletd servers from three separate operators: zec.rocks, Stardust and Cake
    /// Wallet. Not run by Zignal. The user can replace them with any server, including their own.
    static let defaultServers: [Server] = [
        Server(host: "zec.rocks", port: 443),
        Server(host: "na.zec.rocks", port: 443),
        Server(host: "eu.zec.rocks", port: 443),
        Server(host: "us.zec.stardust.rest", port: 443),
        Server(host: "eu.zec.stardust.rest", port: 443),
        Server(host: "zec-node.cakewallet.com", port: 443),
    ]

    /// What a new profile starts with: Tor on, so the server sees a Tor exit instead of this
    /// phone's IP address when messages are sent and fetched (blocks still download directly).
    /// Turning it off in Network makes the wallet start faster. Saved in every new profile's
    /// file (`ProfileSession.emptyData`), and what "Restore defaults" puts back.
    static let standard = WalletSettings(servers: defaultServers, torEnabled: true)

    /// What a profile file without wallet settings means. Before Tor was on by default, Tor
    /// started off and a profile saved nothing until its settings were changed, so such a
    /// profile keeps Tor off, as it had, until the user turns it on.
    static let savedBeforeTorDefault = WalletSettings(servers: defaultServers, torEnabled: false)
}

extension ProfileKeyset {
    /// Names this profile's wallet files ("c_<alias>_data.db" and so on). Derived from the
    /// profile key, so it says nothing about which profile is which.
    var walletAlias: String { subkeyBytes(KeyLabel.walletAlias, count: 8).hexString }
}

/// Dates the wallet-date pickers offer (restoring from a phrase, and a profile whose file wasn't
/// on the phone).
enum WalletDates {
    /// Sapling activation (2018-10-29). No Zcash shielded wallet can be older.
    static let earliest = day(2018, 10, 29)
    /// October 1, 2026: the first Zignal wallets were made in October 2026, so no wallet made in
    /// Zignal is older. The pickers start here, which is safe for every Zignal wallet; a later
    /// date only makes the first sync faster.
    static let zignalFirst = day(2026, 10, 1)

    /// Midnight in the phone's time zone, so the pickers show this very day.
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}

/// Where a wallet restored from its recovery phrase starts scanning.
///
/// The restore screen asks only for a day, but the date it hands over keeps the time of day the
/// screen was opened at, which can be later than the wallet's real start on that day. The SDK
/// starts from the newest bundled checkpoint before that moment, and a checkpoint made later
/// that same day would skip the wallet's first transactions. So scanning starts at the
/// beginning of the day before the picked one: at most a day more to scan, never too late,
/// whatever the phone's time zone.
enum RestoreStart {
    static func date(for picked: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: picked)
        return calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay.addingTimeInterval(-86_400)
    }
}

/// What was entered for a restored wallet's start: a block height, a date, both or neither.
struct RestorePoint: Equatable, Sendable {
    var date: Date?
    var height: Int?
}

/// The block a restored wallet starts scanning from.
///
/// A typed block height and a picked date can both be given. Starting too early only makes the
/// first sync slower; starting too late misses funds. So with both, the earlier one wins, and
/// with neither, October 1, 2026 stands in (the recovery phrase doesn't hold the wallet's real
/// start, and no Zignal wallet is older).
enum WalletStart {
    /// Sapling activation: no shielded wallet can start earlier.
    static let earliestHeight = 419_200
    /// NU7's activation block and its time (2026-11-06 02:34 UTC). After it, a block about every
    /// 25 seconds; used only to tell a height that can't have been mined yet.
    static let nu7Height = 3_543_405
    static let nu7Time = Date(timeIntervalSince1970: 1_793_932_440)
    /// Shown in the height field as an example: a block a little before October 1, 2026.
    static let exampleHeight = 3_500_000

    enum HeightCheck: Equatable {
        case empty, valid(Int), notANumber, tooLow, notMinedYet

        /// The height to use, or nil (nothing typed, or not usable).
        var value: Int? {
            if case .valid(let height) = self { return height }
            return nil
        }

        /// Nothing typed, or a height that can be used.
        var isUsable: Bool { self == .empty || value != nil }

        var message: String? {
            switch self {
            case .empty, .valid: return nil
            case .notANumber: return "A block height is a whole number, like 3,500,000."
            case .tooLow: return "Shielded Zcash wallets start at block 419,200 or later."
            case .notMinedYet: return "That block hasn't been mined yet. Check the number, or pick a date instead."
            }
        }
    }

    /// Reads a typed block height. Spaces and separators between digits are ignored, and the
    /// digits of any keyboard count (Arabic, Persian or Hindi numerals as well as 0 to 9).
    static func check(_ text: String, now: Date = Date()) -> HeightCheck {
        let digits = text.filter { !$0.isWhitespace && !",.'\u{066C}".contains($0) }
        if digits.isEmpty { return .empty }
        guard digits.count <= 9 else { return .notANumber }
        var height = 0
        for character in digits {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                return .notANumber
            }
            height = height * 10 + digit
        }
        if height < earliestHeight { return .tooLow }
        if height > likelyTip(now: now) { return .notMinedYet }
        return .valid(height)
    }

    /// About how far the chain has got at `now`, plus a week, so a phone clock that's a little
    /// off never refuses a real height.
    static func likelyTip(now: Date) -> Int {
        let seconds = max(0, now.timeIntervalSince(nu7Time))
        return nu7Height + Int(seconds / 25) + 7 * 3_456
    }

    /// The height handed to the SDK, which starts from its newest checkpoint at or below it.
    /// `estimate` is the SDK's estimate of the block at a date.
    static func birthday(for point: RestorePoint, estimate: (Date) -> Int) -> Int {
        var candidates: [Int] = []
        if let height = point.height {
            // One block earlier: a checkpoint holds the chain after its block, so a wallet whose
            // first funds came in the typed block still finds them.
            candidates.append(max(height - 1, earliestHeight))
        }
        if let date = point.date {
            candidates.append(estimate(RestoreStart.date(for: date)))
        }
        if candidates.isEmpty {
            candidates.append(estimate(RestoreStart.date(for: WalletDates.zignalFirst)))
        }
        return candidates.min() ?? earliestHeight
    }
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

    /// Recognizes an invite seen before without keeping the invite itself: SHA-256 of its bytes.
    static func fingerprint(_ invite: Data) -> Data {
        Data(SHA256.hash(data: invite))
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

enum SentMemos {
    /// The 512-byte memos one of our own transactions carried to other wallets, or nil while
    /// the wallet is still fetching it. Change and transparent outputs carry no messages, and
    /// Prepare's payments to ourselves have empty memos.
    static func extract(from outputs: [WalletOutput]) -> [Data]? {
        var memos: [Data] = []
        for output in outputs where output.isShielded && output.fromUs && !output.isChange {
            switch output.memo {
            case .notFetched:
                return nil
            case .binary(let bytes):
                if let memo = IncomingMemos.fullMemo(binary: bytes) { memos.append(memo) }
            case .other:
                continue
            }
        }
        return memos
    }
}

/// One of our own transactions, with the 512-byte memos it carried to other wallets.
struct SentTransaction: Equatable {
    let txid: Data
    let memos: [Data]
    /// In a block. Otherwise it is still waiting to be mined and hasn't expired.
    let mined: Bool
}

/// Sends cut short by a lock or a crash. `LoadedProfile.load` shows them as failed because it
/// can't know whether their transaction reached the network. This finds the ones the wallet
/// holds, so they aren't paid for twice.
enum InterruptedSends {
    /// For each failed outgoing message whose first memo one of our transactions carried:
    /// - a mined transaction marks it delivered;
    /// - one still waiting to be mined marks it sent, but only if the send was interrupted. A
    ///   send the server refused also leaves an unbroadcast transaction in the wallet, and that
    ///   message must stay ready to send again.
    /// A sent message then turns delivered once mined, or failed again if it expires, and
    /// keeps its memos for that case. Returns true if any message changed.
    static func reconcile(_ messages: inout [ChatMessage], sent: [SentTransaction]) -> Bool {
        var byMemo: [Data: SentTransaction] = [:]
        for tx in sent {
            // A mined copy wins over one still waiting (a message sent twice).
            for memo in tx.memos where byMemo[memo]?.mined != true { byMemo[memo] = tx }
        }
        var changed = false
        for i in messages.indices where messages[i].outgoing && messages[i].status == .failed {
            guard let first = messages[i].pendingMemos?.first, let tx = byMemo[first],
                  tx.mined || messages[i].interrupted == true else { continue }
            messages[i].txid = tx.txid
            messages[i].interrupted = nil
            if tx.mined {
                messages[i].status = .delivered
                messages[i].pendingMemos = nil
            } else {
                messages[i].status = .sent
            }
            changed = true
        }
        return changed
    }

    /// True while a send cut short by a lock or a crash waits for the wallet's first check after
    /// unlock: the chat shows "Checking…" instead of "Not sent". Send again is safe either way.
    static func isBeingChecked(_ message: ChatMessage, checked: Bool) -> Bool {
        !checked && message.outgoing && message.status == .failed && message.interrupted == true
    }

    /// What such a message says while it waits. The check runs once the wallet has caught up
    /// with the network; when that takes long (no server reached, or a long sync), it says so.
    /// Sending again needs the network too, so the button still waits.
    static func checkingText(takingLong: Bool) -> String {
        takingLong
            ? "Still checking whether it went out: the wallet hasn't caught up with the network yet. Zignal keeps trying."
            : "Checking whether it went out…"
    }

    /// Our transaction still waiting to be mined that carries a message's first memo, if the
    /// wallet holds one. "Send again" sends that same transaction again instead of a new one:
    /// the SDK keeps resending it on its own, so a new one could be paid for twice.
    static func waitingCopy(of firstMemo: Data, in sent: [SentTransaction]) -> SentTransaction? {
        sent.first { !$0.mined && $0.memos.contains(firstMemo) }
    }
}

/// zkw envelopes as they look in a memo. Their header can be read without any key.
enum ZkwMemo {
    /// The memo starts like a zkw envelope of protocol v0.3: 0xFF, "ZW", version 2.
    static func isEnvelope(_ memo: Data) -> Bool {
        memo.count == 512 && memo.starts(with: [0xFF, 0x5A, 0x57, 0x02])
    }

    /// The envelope is a chat's first message (type INIT).
    static func opensChat(_ memo: Data) -> Bool {
        isEnvelope(memo) && memo[memo.startIndex + 4] == 0x03
    }
}

/// In what order received transactions are read, and when one is finished with.
///
/// A contact can send a second message before their first is mined. The wallet may then list
/// the second one first, and it can only be read once the first has opened the chat.
enum IncomingReading {
    /// How long a transaction with zkw memos that can't be read yet keeps being tried.
    static let retryWindow: UInt64 = 2 * 86_400

    /// Indexes into `memos` (one list per transaction): transactions that open a chat first,
    /// otherwise in the order given.
    static func order(_ memos: [[Data]]) -> [Int] {
        let opens = memos.map { $0.contains(where: ZkwMemo.opensChat) }
        return memos.indices.filter { opens[$0] } + memos.indices.filter { !opens[$0] }
    }

    /// Whether a transaction is finished with, so it isn't read again. One with zkw memos that
    /// couldn't be read is tried again for `retryWindow` after it was sent (`sentAt`, its block
    /// time): the message that opens its chat may still be on its way. `now` is the chain's time
    /// (`ChainClock`), never the phone's; 0 while it isn't known, or while it doesn't match its
    /// block's height (`ChainClock.agreed`), which keeps trying.
    static func isDone(read: Bool, complete: Bool, memos: [Data], sentAt: UInt64, now: UInt64) -> Bool {
        if read { return true }
        // Until the wallet has scanned every block, anything may still be missing.
        guard complete else { return false }
        guard memos.contains(where: ZkwMemo.isEnvelope) else { return true }
        return now > sentAt && now - sentAt > retryWindow
    }
}

/// A chat nothing has come back on yet. Its messages are in blocks (all "delivered" can mean),
/// but nothing shows that the contact's phone could read them: an invite that was used before,
/// crossed invites and a contact who restored their profile all look the same from here.
enum FirstReply {
    /// True while no message from the contact has been read in this chat.
    static func isWaiting(_ thread: [ChatMessage]) -> Bool {
        !thread.contains { !$0.outgoing }
    }
}

/// The clock Zignal's protocol runs on: the time in the chain's own blocks, not the phone's date.
///
/// The contact reads each message at its block time, and picks its chat by a tag that changes
/// every UTC day. If the sender picked the day from the phone's clock, a phone whose date was 2
/// or more days off sent messages nobody could read, shown as delivered. Prekeys (and so
/// invites) were stamped with the phone's date too, so a wrong date made invites expire early,
/// or live too long. Now both sides use block times from the same chain.
///
/// Block times reach the wallet through its light server, which can be wrong or lie. So the
/// chain's time is checked against the height clock (`HeightClock`, `reading`): a time more
/// than a day off is replaced by the height's; steps that can't be undone wait while they
/// don't match (`agreed`), and the chat list says so (`disagree`). The phone's date plays no
/// part: a phone with a wrong date works normally.
enum ChainClock {
    /// How far (in blocks) the newest scanned block may be behind the chain tip the server
    /// reports and still count as "now": 2 hours at 25 seconds a block, 6 at 75. The contact
    /// accepts the day before and after, so anything under a day would still be read.
    static let maxLag = 288

    /// The chain's time in Unix seconds, from the newest block the wallet has scanned: nil while
    /// that block is more than `maxLag` blocks behind the tip (the wallet is still catching up),
    /// or when either height or the time is unknown.
    static func time(scannedHeight: Int, scannedTime: Int, tipHeight: Int) -> UInt64? {
        guard scannedHeight > 0, tipHeight > 0, scannedTime > 0,
              tipHeight - scannedHeight <= maxLag else { return nil }
        return UInt64(scannedTime)
    }

    /// How far the chain's time may be from what its block's height says: a day (`HeightClock`).
    static let tolerance = HeightClock.tolerance

    /// The chain's time after the height check: the server's block time while it matches the
    /// block's height (`agrees`), otherwise the height's.
    struct Reading: Equatable, Sendable {
        let time: UInt64
        let agrees: Bool
    }

    /// Checks `chain`, the time of the block at `height`, against the height clock. Nil while the
    /// chain's time isn't known, and for a block the height clock can't date
    /// (`HeightClock.reading`).
    static func reading(chain: UInt64?, height: Int) -> Reading? {
        guard let chain, let checked = HeightClock.reading(claimed: chain, height: height) else { return nil }
        return Reading(time: checked.time, agrees: !checked.mismatch)
    }

    /// True when the server's block time is more than a day away from what its height says.
    /// The chat list says so.
    static func disagree(_ reading: Reading?) -> Bool {
        reading?.agrees == false
    }

    /// The time for steps that can't be undone (dropping old prekeys, which ends every invite
    /// made from them, and giving up on a transaction that couldn't be read) and for making an
    /// invite: the chain's time, but only while it matches its block's height. Nil otherwise, so
    /// a lying server alone never destroys anything. Messages still go out and are read on the
    /// height-checked time either way.
    static func agreed(_ reading: Reading?) -> UInt64? {
        guard let reading, reading.agrees else { return nil }
        return reading.time
    }
}

/// The chain's time worked out from block height alone, to check the block times the light
/// server supplies (a server could date a block weeks ahead). No phone clock and no network:
/// anchored to checkpoints the SDK ships, and to the block spacing each network upgrade sets
/// (75 seconds; 25 from NU7, block 3,543,405, ZIP 218). Between two anchors, the difference
/// between the spacing and the real time is spread evenly. Never re-anchored from what a
/// server says. Measured Nov 25, 2026: 6 minutes off, 13 days after the newest anchor.
enum HeightClock {
    struct Anchor: Equatable, Sendable {
        let height: Int
        let time: UInt64
    }

    /// Mainnet checkpoints the SDK ships (`Resources/checkpoints/mainnet`), oldest first. The
    /// newest one it ships must be the last: a test checks, so an SDK update with a newer
    /// checkpoint asks for it here.
    static let anchors = [Anchor(height: 3_390_000, time: 1_782_372_852),
                          Anchor(height: 3_565_000, time: 1_794_477_230)]

    /// Seconds per block from each height on. A network upgrade that changes the spacing comes
    /// with an SDK update (without one the wallet stops following the chain); its row goes here.
    static let spacing: [(from: Int, seconds: Int64)] = [(0, 75), (3_543_405, 25)]

    /// How far a block's time may be from the height clock: a day.
    static let tolerance: UInt64 = 86_400

    /// The highest block height the clock dates. Block heights are 32-bit numbers in Zcash; a
    /// larger one can only come from a broken or lying server, and would overflow the
    /// arithmetic below.
    static let maxHeight = Int(UInt32.max)

    /// The expected time of the block at `height`, in Unix seconds; nil below the oldest anchor
    /// and above `maxHeight`.
    static func time(at height: Int) -> UInt64? {
        guard let first = anchors.first, let last = anchors.last,
              height >= first.height, height <= maxHeight else { return nil }
        let seconds: Int64
        if height >= last.height {
            seconds = Int64(last.time) + elapsed(from: last.height, to: height)
        } else {
            guard let upper = anchors.firstIndex(where: { $0.height > height }), upper > 0 else { return nil }
            let low = anchors[upper - 1], high = anchors[upper]
            let drift = (Int64(high.time) - Int64(low.time)) - elapsed(from: low.height, to: high.height)
            seconds = Int64(low.time) + elapsed(from: low.height, to: height)
                + drift * Int64(height - low.height) / Int64(high.height - low.height)
        }
        return seconds > 0 ? UInt64(seconds) : nil
    }

    /// Seconds from height `a` to height `b` by the spacing table (negative when `b` is lower).
    static func elapsed(from a: Int, to b: Int) -> Int64 {
        if b < a { return -elapsed(from: b, to: a) }
        var total: Int64 = 0
        for (index, step) in spacing.enumerated() {
            let end = index + 1 < spacing.count ? spacing[index + 1].from : Int.max
            let low = max(a, step.from), high = min(b, end)
            if high > low { total += Int64(high - low) * step.seconds }
        }
        return total
    }

    /// The time to read a transaction at: the server's block time while it is within a day of
    /// the height clock, otherwise the height clock's, with `mismatch` set. Nil without a
    /// height, and for a height the clock can't date (below the oldest anchor, which is older
    /// than Zignal itself, or above `maxHeight`): the time isn't known then, and the server's
    /// word alone is never taken for it.
    static func reading(claimed: UInt64?, height: Int?) -> (time: UInt64, mismatch: Bool)? {
        guard let height, let expected = time(at: height) else { return nil }
        guard let claimed else { return (expected, false) }
        let apart = claimed > expected ? claimed - expected : expected - claimed
        return apart > tolerance ? (expected, true) : (claimed, false)
    }
}

/// Whether "Prepare for chatting" would help right now.
///
/// Each message spends one note. Its change comes back as a new note of almost the same value,
/// but that note stays locked until it has 3 confirmations. So after one split the wallet keeps
/// about the same number of notes, and splitting again only helps once they have been worn
/// down by fees, or when new funds arrived as one note. The SDK doesn't report how many notes
/// the wallet holds, so the count is estimated from the spendable balance and the note value
/// of the last split.
enum ChatReadiness: Equatable, Sendable {
    /// About this many messages can go out back to back now. No split needed.
    case ready(messages: Int)
    /// Funds or change are confirming. Wait instead of splitting.
    case confirming
    /// Splitting would let several messages go out in a row.
    case prepare
    /// Too little confirmed ZEC to split. Single messages may still work.
    case notEnough(minimum: Int64)

    /// Notes a split aims for: enough for a burst of messages while earlier change confirms.
    static let target = 5
    /// With at least this many spendable notes, a split isn't worth its fee.
    static let readyAt = 3

    static func assess(spendable: Int64, pending: Int64, preparedNoteValue: Int64?) -> ChatReadiness {
        if let value = preparedNoteValue, value > 0 {
            let now = Int(spendable / value)
            if now >= readyAt { return .ready(messages: now) }
            // The notes still exist; recent messages locked some of them until their change confirms.
            if Int((spendable + pending) / value) >= readyAt { return .confirming }
        }
        let minimum = PrepareSplit.minimum(count: target)
        if spendable >= minimum { return .prepare }
        return pending > 0 ? .confirming : .notEnough(minimum: minimum)
    }
}

/// The arithmetic of "Prepare for chatting": `count - 1` new notes paid to ourselves, plus the
/// change, which becomes the last note.
enum PrepareSplit {
    /// The smallest note worth making: room for a few messages' fees.
    static let minimumNote: Int64 = 20_000

    /// ZIP 317 fee: 5,000 zatoshis per logical action, at least 2. In one shielded pool the
    /// actions are the larger of the spends and the outputs (change included).
    static func fee(spends: Int, outputs: Int) -> Int64 {
        5_000 * Int64(max(2, spends, outputs))
    }

    /// Smallest spendable balance that splits into `count` notes from a single spend.
    static func minimum(count: Int) -> Int64 {
        minimumNote * Int64(count) + fee(spends: 1, outputs: count)
    }

    /// Value of each new note once `fee` is paid. The change is at least as large.
    static func noteValue(spendable: Int64, count: Int, fee: Int64) -> Int64 {
        (spendable - fee) / Int64(max(1, count))
    }
}

/// Amounts for display: ZEC with up to 8 decimals, trailing zeros trimmed.
enum ZecFormat {
    static func string(_ zatoshis: Int64) -> String {
        let sign = zatoshis < 0 ? "-" : ""
        return "\(sign)\(PaymentRequest.zec(abs(zatoshis))) ZEC"
    }
}
