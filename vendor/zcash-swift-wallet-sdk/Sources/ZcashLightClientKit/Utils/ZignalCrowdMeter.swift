//
//  ZignalCrowdMeter.swift
//  ZcashLightClientKit
//
//  Zignal patch (Debug builds only): measures how crowded the synced blocks are, to size the
//  planned cover fetches. Prints counts and sizes to Xcode's console: never a transaction ID,
//  an address or a block height. Stores nothing and sends nothing. Release builds, including
//  TestFlight, don't contain it.
//

#if DEBUG
import Foundation

enum ZignalCrowdMeter {
    /// Upper bounds of the groups of Ironwood actions per transaction: 1, 2, 3-4, 5-8, 9-16, 17+.
    static let actionGroups = [1, 2, 4, 8, 16]

    static func group(ofActions count: Int) -> Int {
        actionGroups.firstIndex { count <= $0 } ?? actionGroups.count
    }

    /// One line per batch of compact blocks written to the cache.
    static func report(_ blocks: [ZcashCompactBlock]) {
        guard !blocks.isEmpty else { return }
        var transactions = 0
        var ironwood = 0
        var orchard = 0
        var sapling = 0
        var unreadable = 0
        var groups = [Int](repeating: 0, count: actionGroups.count + 1)
        for block in blocks {
            guard let parsed = try? CompactBlock(serializedBytes: block.data) else {
                unreadable += 1
                continue
            }
            for transaction in parsed.vtx {
                transactions += 1
                if !transaction.ironwoodActions.isEmpty {
                    ironwood += 1
                    groups[group(ofActions: transaction.ironwoodActions.count)] += 1
                }
                if !transaction.actions.isEmpty { orchard += 1 }
                if !transaction.outputs.isEmpty || !transaction.spends.isEmpty { sapling += 1 }
            }
        }
        let grouped = "1:\(groups[0]) 2:\(groups[1]) 3-4:\(groups[2]) 5-8:\(groups[3]) 9-16:\(groups[4]) 17+:\(groups[5])"
        let skipped = unreadable > 0 ? "; unreadable blocks \(unreadable)" : ""
        print("Zignal crowd: \(blocks.count) blocks, \(transactions) transactions; with Ironwood actions \(ironwood), Orchard \(orchard), Sapling \(sapling); Ironwood actions per transaction \(grouped)\(skipped)")
    }

    /// One line per transaction the wallet fetches by ID: its size only.
    static func fetched(_ kind: String, bytes: Int?) {
        print("Zignal crowd: fetched (\(kind)) \(bytes.map { "\($0) bytes" } ?? "nothing")")
    }
}
#endif
