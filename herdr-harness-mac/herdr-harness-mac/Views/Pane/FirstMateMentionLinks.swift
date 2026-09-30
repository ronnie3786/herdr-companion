import Foundation
import Observation
import SwiftUI

extension EnvironmentValues {
    /// The names `PiMarkdownText` turns into First Mate mention runs. Nil (the
    /// default) leaves every existing chat exactly as it was; only the First
    /// Mate chat window sets it.
    @Entry var firstMateMentionCatalog: FirstMateMentionCatalog? = nil
}

/// Mention linking is derived solely from the complete attributed input and
/// catalog. Cold scans stay off the UI thread, and a result is displayed only
/// when it belongs to the view's current input. Until then, the current plain
/// attributed text remains visible instead of links from an older catalog.
@MainActor @Observable
final class FirstMateMentionLinks {
    struct Input: Hashable, Sendable {
        let source: AttributedString
        let catalog: FirstMateMentionCatalog
    }

    struct Result: Equatable, Sendable {
        let input: Input
        let text: AttributedString
    }

    typealias Link = @Sendable (Input, @Sendable () -> Bool) -> AttributedString

    private(set) var result: Result?
    @ObservationIgnored private var acceptedInput: Input?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let link: Link

    init(link: @escaping Link = { input, isCancelled in
        FirstMateMentionLinker.link(input.source, catalog: input.catalog, isCancelled: isCancelled)
    }) {
        self.link = link
    }

    /// Returns current unlinked text unless the published result has the same
    /// complete identity. This makes stale-target links impossible during a
    /// text or catalog transition.
    func text(for input: Input) -> AttributedString {
        guard result?.input == input else { return input.source }
        return result?.text ?? input.source
    }

    func update(_ input: Input) async {
        let request = UUID()
        requestID = request
        guard input != acceptedInput else { return }
        let link = link
        let scan = Task.detached(priority: .userInitiated) {
            link(input, { Task<Never, Never>.isCancelled })
        }
        let text = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard !Task.isCancelled, request == requestID else { return }
        acceptedInput = input
        let value = Result(input: input, text: text)
        if result != value { result = value }
    }
}
