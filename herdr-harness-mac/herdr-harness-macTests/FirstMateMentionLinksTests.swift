import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate async mention links")
@MainActor
struct FirstMateMentionLinksTests {
    private static let catalog = FirstMateMentionCatalog(entries: [
        .init(
            name: "Synthetic feature",
            emoji: "🧪",
            status: .working,
            target: .feature(featureID: "synthetic-feature")
        ),
    ])

    private static func wait(for semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    @Test("Current text stays plain until its links finish, and an older result cannot replace it")
    func newestInputWins() async {
        let old = FirstMateMentionLinks.Input(source: AttributedString("old"), catalog: Self.catalog)
        let current = FirstMateMentionLinks.Input(source: AttributedString("current"), catalog: Self.catalog)
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let links = FirstMateMentionLinks { input, _ in
            if input == old {
                oldStarted.signal()
                releaseOld.wait()
                return AttributedString("stale linked text")
            }
            return AttributedString("current linked text")
        }

        let oldUpdate = Task { await links.update(old) }
        let didStart = await Self.wait(for: oldStarted)
        #expect(didStart)
        #expect(links.text(for: old) == old.source)

        await links.update(current)
        #expect(links.text(for: current) == AttributedString("current linked text"))
        #expect(links.text(for: old) == old.source)

        releaseOld.signal()
        await oldUpdate.value
        #expect(links.text(for: current) == AttributedString("current linked text"))
        #expect(links.text(for: old) == old.source)
    }

    @Test("Cancelling a cold link pass prevents publication")
    func cancelledUpdateDoesNotPublish() async {
        let input = FirstMateMentionLinks.Input(source: AttributedString("current"), catalog: Self.catalog)
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let links = FirstMateMentionLinks { _, _ in
            started.signal()
            finish.wait()
            return AttributedString("cancelled linked text")
        }

        let update = Task { await links.update(input) }
        let didStart = await Self.wait(for: started)
        #expect(didStart)
        update.cancel()
        finish.signal()
        await update.value

        #expect(links.result == nil)
        #expect(links.text(for: input) == input.source)
    }
}
