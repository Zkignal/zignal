//
//  FetchUTXOsAction.swift
//
//
//  Created by Michal Fousek on 05.05.2023.
//

import Foundation

final class FetchUTXOsAction {
    var utxoFetcher: UTXOFetcher
    let logger: Logger

    init(container: DIContainer) {
        utxoFetcher = container.resolve(UTXOFetcher.self)
        logger = container.resolve(Logger.self)
    }
}

extension FetchUTXOsAction: Action {
    var removeBlocksCacheWhenFailed: Bool { false }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        // Zignal patch: no UTXO fetch. It sends every transparent address of the wallet to the
        // light server on each sync, without Tor, which hands the server a stable identifier of
        // the wallet. Zignal uses shielded addresses only and never shows a transparent one.
        logger.debug("Skipping the UTXO fetch (Zignal: shielded addresses only)")

        await context.update(state: .handleSaplingParams)
        return context
    }

    func stop() async { }
}
