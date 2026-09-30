import Foundation

/// iOS-local additions to the shared synthetic First Mate demo.
///
/// The shared `HerdrFirstMateShared` demo is shared with the Mac app and is not
/// changed here. The mobile fleet has more than one demo host, so this file adds
/// one entirely synthetic, host-owned feature to the second host. That gives the
/// combined All Machines list a duplicate feature ID on two hosts (the shared
/// demo features) plus a genuinely host-specific row, without live agents and
/// without touching the shared Mac demo.
enum FirstMateMobileDemo {
    static func initialSnapshots(forMachineID machineID: String) -> [FirstMateSnapshot]? {
        if machineID == "demo2" {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateOlderHosts") { return FirstMateDemo.features(step: 0) }
            #endif
            return FirstMateDemo.features(step: 0) + [FirstMateDemo.chatWindowLead()]
        }
        guard machineID == "demo1" else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateOlderHosts") {
            return FirstMateDemo.features(step: 0) + FirstMateDemo.chatWindowFeatures()
        }
        if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateComposerScenarios") { return composerSnapshots() }
        if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateAdditionalResponse") { return [additionalResponseSnapshot()] }
        if FirstMateTranscriptPerformanceProbe.enabled { return [transcriptPerformanceSnapshot()] }
        if FirstMateListPerformanceProbe.enabled { return performanceSnapshots() + [FirstMateDemo.chatWindowLead()] }
        #endif
        // Keep existing automation fixtures alongside the curated chat dataset;
        // their IDs remain valid through the list-to-detail transition.
        return FirstMateDemo.features(step: 0) + FirstMateDemo.chatWindowFeatures() + [FirstMateDemo.chatWindowLead()]
    }

    static func chatFleet(forMachineID machineID: String) -> [FirstMateFleetEntry] {
        guard machineID == "demo1" else { return [] }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateAdditionalResponse") {
            return FirstMateDemo.chatWindowFleet().filter { $0.featureID == "demo-receipts" }
        }
        if FirstMateTranscriptPerformanceProbe.enabled { return [] }
        if FirstMateListPerformanceProbe.enabled {
            return performanceSnapshots().enumerated().map { index, snapshot in
                .init(featureID: snapshot.feature.id, title: snapshot.feature.title, status: snapshot.feature.status,
                      hudStatus: index < 8 ? .blocked : .working, stepIndex: 1,
                      latestMessage: .init(id: "reply-\(index)", role: "assistant", text: "Synthetic update \(index). No agents launched.", createdAt: snapshot.feature.updatedAt),
                      latestFirstMateMessageID: "reply-\(index)", unread: index < 8, activityAt: snapshot.feature.updatedAt)
            }
        }
        #endif
        return FirstMateDemo.chatWindowFleet()
    }

    #if DEBUG
    static func composerSnapshots() -> [FirstMateSnapshot] {
        var values = FirstMateDemo.features(step: 0) + FirstMateDemo.chatWindowFeatures() + [FirstMateDemo.chatWindowLead()]
        if let index = values.firstIndex(where: { $0.feature.id == "demo-receipts" }) {
            var feature = values[index].feature
            feature.nativeSessionID = "synthetic-receipts-session"
            feature.coordinatorModel = "synthetic/sample-reasoner"
            feature.coordinatorThinking = "high"
            feature.modelSelection = .init(profile: "synthetic", requestedModel: "synthetic/sample-reasoner", requestedThinking: "high",
                actualModel: "synthetic/sample-fast", actualThinking: "low", source: "synthetic")
            feature.coordinatorContext = .init(nativeSessionID: "synthetic-receipts-session", status: .measured,
                tokens: 38_400, contextWindow: 100_000, handoffTargetTokens: 80_000)
            values[index].feature = feature
        }
        return values
    }

    static func additionalResponseSnapshot() -> FirstMateSnapshot {
        var snapshot = FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" }!
        let turn = "synthetic-additional-turn"
        snapshot.messages[snapshot.messages.count - 1].metadata = .init(turnID: turn, checkpoint: true)
        let closing = FirstMateMessage(id: "additional-closing", featureID: snapshot.feature.id, role: "assistant",
            text: "Supplementary decision note has the details. The saved pull request is attached.", status: "completed",
            createdAt: snapshot.feature.updatedAt, metadata: .init(inReplyTo: turn))
        snapshot.messages.append(closing)
        snapshot.documents.append(.init(id: "additional-document", featureID: snapshot.feature.id, title: "Supplementary decision note",
            mediaType: "text/markdown", contentHash: "synthetic-additional", createdAt: snapshot.feature.updatedAt,
            content: "Synthetic supplementary evidence. No agents launched."))
        snapshot.links.append(.init(id: "additional-pr", featureID: snapshot.feature.id,
            url: "https://github.com/example/synthetic/pull/1", kind: "pull_request", title: "Synthetic pull request", source: "coordinator",
            provenance: .init(messageID: closing.id), createdAt: snapshot.feature.updatedAt, updatedAt: snapshot.feature.updatedAt))
        return snapshot
    }

    static func transcriptPerformanceSnapshot() -> FirstMateSnapshot {
        var snapshot = FirstMateDemo.newFeature(title: "Transcript performance", goal: "Synthetic scrolling only.", cwd: "/workspace/synthetic", id: "demo-chat-performance")
        snapshot.messages = (0..<200).map { index in
            FirstMateMessage(id: "performance-message-\(index)", featureID: snapshot.feature.id,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "Message \(index). A complete synthetic turn; no agents launched.", status: "completed",
                createdAt: HerdrTimestamp.string(from: Date(timeIntervalSince1970: 1_900_000_000 + Double(index * 60))))
        }
        snapshot.messages[199].text += "\n\n" + (1...24).map { "Long paragraph \($0). Every sentence remains available while scrolling this synthetic message." }.joined(separator: "\n\n") + "\n\nEND OF COMPLETE MESSAGE"
        return snapshot
    }

    static func performanceSnapshots() -> [FirstMateSnapshot] { performanceFixture }

    private static let performanceFixture: [FirstMateSnapshot] = {
        let formatter = ISO8601DateFormatter()
        return (0..<100).map { index in
            let id = String(format: "performance-%03d", index)
            var feature = FirstMateDemo.newFeature(title: String(format: "Performance conversation %03d", index),
                goal: "A wholly synthetic scrolling fixture.", cwd: "/workspace/synthetic", id: id).feature
            feature.status = index < 8 ? "blocked" : "running"
            feature.updatedAt = formatter.string(from: Date(timeIntervalSince1970: 1_900_000_000 - Double(index)))
            return FirstMateSnapshot(feature: feature)
        }
    }()
    #endif

    /// Extra synthetic snapshots owned by one demo host. Nothing is fetched,
    /// nothing leaves the device, and every value is invented.
    static func supplementalSnapshots(forMachineID machineID: String) -> [FirstMateSnapshot] {
        guard machineID == "demo2" else { return [] }
        let featureID = "demo2-release-checklist"
        let visitID = "demo2-verify"
        let feature = FirstMateFeature(
            id: featureID,
            title: "Ship the release checklist",
            goal: "Keep signing, notarization, and rollback steps together on the laptop.",
            cwd: "/workspace/release-tools",
            status: "awaiting_direction",
            currentVisitID: visitID,
            revision: 1,
            createdAt: FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            workItemID: "DEMO-207"
        )
        let visit = FirstMateVisit(
            id: visitID,
            featureID: featureID,
            stageKey: "proof",
            title: "Proof",
            status: "awaiting_direction",
            revision: 1,
            createdAt: FirstMateDemo.timestamp
        )
        let message = FirstMateMessage(
            id: "demo2-release-welcome",
            featureID: featureID,
            role: "assistant",
            text: "The release checklist is drafted. Confirm the signing order before the laptop continues.\n\nSynthetic demo. No model or repository changes were executed.",
            status: "delivered",
            createdAt: FirstMateDemo.timestamp
        )
        return [FirstMateSnapshot(feature: feature, visits: [visit], messages: [message])]
    }
}
