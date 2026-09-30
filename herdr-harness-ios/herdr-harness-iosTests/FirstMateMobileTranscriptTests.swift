import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Phone transcript ownership, submission and visibility", .serialized)
@MainActor
struct FirstMateMobileTranscriptTests {
    private func demo() async -> HerdrAppModel {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "Transcript.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }
    @Test("Reserve synchronously detaches only submitted text; newer edits and other owners survive")
    func reservation() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let row = try #require(fleet.conversations.first { $0.hudStatus == .blocked })
        let target = FirstMateMobileListPresentation.target(row)
        #expect(fleet.open(target))
        let store = try #require(fleet.store(for: target))
        store.draft = "Frozen original\nsecond line"
        let handle = try #require(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true))
        #expect(store.draft.isEmpty)
        #expect(store.outgoingMessage(handle)?.text == "Frozen original\nsecond line")
        store.draft = "Newer material"
        #expect(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true) == nil)
        #expect(store.draft == "Newer material")
        await store.completeOutgoingMessage(handle)
        #expect(store.draft == "Newer material")
        #expect(store.outgoingMessage(handle)?.submission?.draft == "Frozen original\nsecond line" || store.outgoingMessage(handle) == nil)
        #expect(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: false) == nil)
        #expect(store.draft == "Newer material")
        let other = try #require(fleet.conversations.first { $0.machineID != target.machineID })
        let otherTarget = FirstMateMobileListPresentation.target(other)
        #expect(fleet.open(otherTarget))
        #expect(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true) == nil)
        #expect(fleet.open(target))
        #expect(store.draft == "Newer material")
    }
    @Test("Inline replies cannot consume a separately composed draft, and closed features reject sends")
    func inlineAndClosed() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let row = try #require(fleet.conversations.first { $0.hudStatus == .blocked })
        let target = FirstMateMobileListPresentation.target(row)
        #expect(fleet.open(target))
        let store = try #require(fleet.store(for: target))
        store.draft = "Keep this draft"
        let handle = try #require(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true, reply: "Server choice"))
        #expect(store.draft == "Keep this draft")
        #expect(store.outgoingMessage(handle)?.text == "Server choice")
        await store.completeOutgoingMessage(handle)
        var closed = try #require(store.snapshots[target.featureID]); closed.feature.status = "completed"; store.receive(closed)
        #expect(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true) == nil)
        #expect(store.draft == "Keep this draft")
    }
    @Test("Unconfirmed delivery retries only explicitly with frozen identity/payload and preserves newer draft")
    func frozenRetry() async throws {
        let feature = ChatFixtures.feature("feature", status: "blocked")
        let client = SyntheticChatFleetClient(features: [feature])
        client.snapshots = [feature.id: FirstMateSnapshot(feature: feature)]
        let machine = ChatFixtures.machine("alpha")
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "FrozenRetry.\(UUID())")!)
        fleet.activate(sources: [.init(machine: machine, configuration: .init(urlString: machine.urlString, token: "synthetic"), client: client)], connectionGeneration: 1)
        await fleet.refreshAll()
        let target = FirstMateFeatureTarget(machineID: machine.id, featureID: feature.id)
        #expect(fleet.open(target))
        let store = try #require(fleet.store(for: target))
        store.draft = "One frozen payload"
        let handle = try #require(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true))
        client.beforeSend = { throw URLError(.timedOut) }
        await store.completeOutgoingMessage(handle)
        let failure = try #require(store.sendFailure(for: feature.id))
        if case .deliveryUnconfirmed = failure.state { } else { Issue.record("Expected honest uncertain delivery") }
        store.draft = "New work survives"
        await fleet.refreshAll()
        #expect(client.sentRequestIDs == [handle.requestID], "Refresh must not resend")
        client.beforeSend = nil
        let retry = try #require(FirstMateMobileSubmission.retryHandle(failure, store: store, target: target, fleet: fleet, canControl: true))
        #expect(retry.requestID == handle.requestID)
        await store.retryOutgoingMessage(retry)
        #expect(client.sentRequestIDs == [handle.requestID, handle.requestID])
        #expect(client.sent.allSatisfy { $0.featureID == target.featureID && $0.text == "One frozen payload" })
        #expect(client.sentContexts.isEmpty, "A frozen nil context must stay nil")
        #expect(store.draft == "New work survives")
        #expect(FirstMateMobileSubmission.retryHandle(failure, store: store, target: target, fleet: fleet, canControl: true) == nil)
    }

    @Test("Read gate requires actual visible active chat, bottom and a server identity")
    func visibility() async throws {
        let model = await demo()
        let row = try #require(model.firstMateFleet.conversations.first { $0.isUnread && $0.latestFirstMateMessageID != nil })
        let active = FirstMateMobileTranscriptPolicy.Visibility(appeared: true, activeScene: true, firstMateTab: true, topmost: true)
        let messages = [FirstMateMessage(id: try #require(row.latestFirstMateMessageID), featureID: row.featureID,
            role: "assistant", text: "Displayed reply", status: "completed", createdAt: "2030-01-01T00:00:00Z")]
        let store = try #require(model.firstMateFleet.store(forMachineID: row.machineID))
        let layout = FirstMateMobileTranscriptPolicy.ReadLayout(storeID: ObjectIdentifier(store), lifecycle: store.lifecycle,
            messages: messages, displayedServerIDs: Set(messages.map(\.id)), followsLatest: true)
        #expect(FirstMateMobileTranscriptPolicy.readMessage(conversation: row, visibility: active, messages: messages, layout: layout) == row.latestFirstMateMessageID)
        for field in 0..<6 {
            var visibility = active
            switch field {
            case 0: visibility.appeared = false
            case 1: visibility.activeScene = false
            case 2: visibility.firstMateTab = false
            case 3: visibility.topmost = false // Info, including its back transition
            case 4: visibility.covered = true // Create/archive/excerpt/resource sheet
            default: visibility.followsLatest = false
            }
            #expect(FirstMateMobileTranscriptPolicy.readMessage(conversation: row, visibility: visibility, messages: messages, layout: layout) == nil)
        }
        #expect(FirstMateMobileTranscriptPolicy.readMessage(conversation: nil, visibility: active, messages: messages, layout: layout) == nil)
        #expect(FirstMateMobileTranscriptPolicy.readMessage(conversation: row, visibility: active, messages: messages, layout: nil) == nil)
        var changed = messages; changed[0].text = "New layout, same server ID"
        #expect(FirstMateMobileTranscriptPolicy.readMessage(conversation: row, visibility: active, messages: changed, layout: layout) == nil)
        #expect(FirstMateMobileTranscriptPolicy.nearBottom(offset: 560, viewport: 400, content: 1_000, bottomInset: 0))
        #expect(!FirstMateMobileTranscriptPolicy.nearBottom(offset: 559, viewport: 400, content: 1_000, bottomInset: 0))
        #expect(!FirstMateMobileTranscriptPolicy.nearBottom(offset: 560, viewport: 400, content: 1_000, bottomInset: 30))
    }
    @Test("Only rendered canonical or expanded additional server replies grant read authority")
    func readProjection() {
        let feature = "feature"
        let main = FirstMateMessage(id: "A", featureID: feature, role: "assistant", text: "Checkpoint", status: "completed",
            createdAt: "2030-01-01T00:00:00Z", metadata: .init(turnID: "turn", checkpoint: true))
        var additional = main; additional.id = "B"; additional.metadata = .init(inReplyTo: "turn")
        var local = main; local.id = "local-outgoing-synthetic"; local.metadata = nil
        var user = main; user.id = "U"; user.role = "user"; user.metadata = nil
        var foreign = main; foreign.id = "F"; foreign.featureID = "foreign"; foreign.metadata = nil
        let rows = FirstMateTranscriptLayout.rows(for: [main, additional, local, user, foreign], now: .now, calendar: .current)
        #expect(FirstMateMobileTranscriptPolicy.displayedServerIDs(rows: rows, expanded: [], featureID: feature) == ["A"])
        #expect(FirstMateMobileTranscriptPolicy.displayedServerIDs(rows: rows, expanded: ["A"], featureID: feature) == ["A", "B"])
    }

    @Test("A newly closed snapshot cannot show stale fleet needs-you actions or a Blocked header")
    func closedSnapshotOverridesStalePresentation() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let row = try #require(fleet.conversations.first { $0.featureID == "demo-receipts" })
        var snapshot = try #require(fleet.store(for: FirstMateMobileListPresentation.target(row))?.snapshots[row.featureID])
        let messages = snapshot.messages.filter(\.isConversation)
        #expect(!FirstMateMobileTranscriptPolicy.replies(messages: messages, snapshot: snapshot, needsYou: true, isTyping: false).isEmpty)
        #expect(FirstMateMobileTranscriptPolicy.replies(messages: messages, snapshot: snapshot, needsYou: true, isTyping: true).isEmpty)
        snapshot.feature.status = "completed"
        #expect(FirstMateMobileTranscriptPolicy.replies(messages: messages, snapshot: snapshot, needsYou: true, isTyping: false).isEmpty)
        #expect(FirstMateMobileTranscriptPolicy.statusWord(snapshot: snapshot, conversation: row) == "Complete")
        snapshot.feature.status = "cancelled"
        #expect(FirstMateMobileTranscriptPolicy.statusWord(snapshot: snapshot, conversation: row) == "Cancelled")
    }

    @Test("Readouts lose navigation authority on a newer action or owner replacement; feature changes reset Info")
    func readoutOwnership() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let first = try #require(fleet.conversations.first { $0.machineID == "demo1" })
        let second = try #require(fleet.conversations.first { $0.machineID == first.machineID && $0.featureID != first.featureID })
        let request = try #require(FirstMateMobileReadoutRequest.capture(first, fleet: fleet))
        #expect(request.isCurrent(in: fleet))
        model.beginAppNavigation()
        #expect(!request.isCurrent(in: fleet))
        #expect(fleet.open(request.target))
        request.store.inspector = .documents
        #expect(fleet.open(FirstMateMobileListPresentation.target(second)))
        #expect(request.store.inspector == .overview)
        let replacement = try #require(FirstMateMobileReadoutRequest.capture(first, fleet: fleet))
        fleet.activate(sources: [], connectionGeneration: 100)
        #expect(!replacement.isCurrent(in: fleet))
    }

    @Test("Mention catalogs exclude foreign hosts and ambiguous display names")
    func mentionOwnership() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let duplicate = try #require(fleet.conversations.first { $0.featureID == "demo-session-continuity" && $0.machineID == "demo1" })
        let target = FirstMateMobileListPresentation.target(duplicate)
        let snapshot = try #require(fleet.store(for: target)?.snapshots[target.featureID])
        let catalog = FirstMateMobileTranscriptPolicy.mentionCatalog(conversations: fleet.conversations, snapshot: snapshot, owner: target)
        #expect(!catalog.entries.contains { $0.target.featureID == "demo2-release-checklist" })
        var ambiguous = snapshot
        let featureName = duplicate.name
        if !ambiguous.assignments.isEmpty { ambiguous.assignments[0].title = featureName }
        let filtered = FirstMateMobileTranscriptPolicy.mentionCatalog(conversations: fleet.conversations, snapshot: ambiguous, owner: target)
        if !ambiguous.assignments.isEmpty { #expect(!filtered.entries.contains { $0.name == featureName }) }
    }

    @Test("Mention cache includes catalog identity and remains bounded")
    func mentionCache() {
        let entry = FirstMateMentionCatalog.Entry(name: "Sample feature", emoji: "🧾", status: .blocked, target: .feature(featureID: "alpha"))
        var catalog = FirstMateMentionCatalog(entries: [entry])
        let first = FirstMateMentionText.render("Sample feature", catalog: catalog)
        catalog.entries[0].target = .feature(featureID: "beta")
        let second = FirstMateMentionText.render("Sample feature", catalog: catalog)
        #expect(first != second)
        for index in 0..<100 { _ = FirstMateMentionText.render("Sample feature \(index)", catalog: catalog) }
        #expect(FirstMateMentionText.cachedCount <= 64)
        let code = FirstMateMentionText.render("`Sample feature`", catalog: catalog)
        #expect(code.runs.allSatisfy { $0.link == nil })
    }
    @Test("Owned-link failures are visible, but superseded links cannot replace newer feedback")
    func ownedLinkFeedback() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let row = try #require(fleet.conversations.first { $0.machineID == "demo1" })
        let owner = FirstMateMobileListPresentation.target(row)
        #expect(fleet.open(owner))
        let store = try #require(fleet.store(for: owner))
        let invalid = try #require(URL(string: "herdr://first-mate?feature_id=one&feature_id=two"))
        #expect(FirstMateMobileOwnedNavigation.open(invalid, owner: owner, store: store, model: model) == nil)
        #expect(model.toastMessage == "This First Mate link is invalid.")
        let unknown = FirstMateMention.url(for: .feature(featureID: "not-in-this-demo"))
        await FirstMateMobileOwnedNavigation.open(unknown, owner: owner, store: store, model: model)?.value
        #expect(model.toastMessage == "The feature could not be opened on its owning machine.")
        let pending = FirstMateMobileOwnedNavigation.open(unknown, owner: owner, store: store, model: model)
        model.beginAppNavigation(); model.toastMessage = "Newer navigation result"
        await pending?.value
        #expect(model.toastMessage == "Newer navigation result")
        #expect(fleet.selectedTarget == owner)
    }

    @Test("Owned-link UI navigation keeps its source machine and rejects retired sources")
    func ownedLinkOwner() async throws {
        let model = await demo(), fleet = model.firstMateFleet
        let owner = FirstMateFeatureTarget(machineID: "demo2", featureID: "demo-session-continuity")
        #expect(fleet.open(owner))
        let store = try #require(fleet.store(for: owner))
        let other = try #require(fleet.conversations.first { $0.machineID == owner.machineID && $0.featureID != owner.featureID })
        let url = FirstMateMention.url(for: .feature(featureID: other.featureID))
        await FirstMateMobileOwnedNavigation.open(url, owner: owner, store: store, model: model)?.value
        #expect(fleet.selectedTarget == FirstMateMobileListPresentation.target(other))
        #expect(model.toastMessage == nil)
        fleet.activate(sources: [], connectionGeneration: 99)
        model.toastMessage = "Replacement owner"
        #expect(FirstMateMobileOwnedNavigation.open(url, owner: owner, store: store, model: model) == nil)
        #expect(model.toastMessage == "Replacement owner")
    }

    @Test("Mention styling cannot erase explicit origins or invalid security-bearing URL fields")
    func mentionURLPreservation() throws {
        let catalog = FirstMateMentionCatalog(entries: [.init(name: "Feature", emoji: "🧾", status: .blocked, target: .feature(featureID: "feature"))])
        for source in [
            "herdr://first-mate?feature_id=feature&server_url=https%3A%2F%2Fexample.invalid",
            "herdr://first-mate?feature_id=feature&feature_id=another",
            "herdr://first-mate?feature_id=feature&token=not-authority",
            "herdr://first-mate?feature_id=feature&tab=documents",
            "herdr://user@first-mate?feature_id=feature"
        ] {
            let url = try #require(URL(string: source))
            let result = FirstMateMentionText.render("[Feature](\(source))", catalog: catalog)
            #expect(result.runs.contains { $0.link == url })
            #expect(!result.runs.contains { $0.link == FirstMateMention.url(for: .feature(featureID: "feature")) })
        }
        let canonical = FirstMateMentionText.render("Feature", catalog: catalog)
        #expect(canonical.runs.contains { $0.link == FirstMateMention.url(for: .feature(featureID: "feature")) })
    }

    @Test("PR cards require authoritative association, exact owner and safe visible destinations")
    func pullRequestCards() {
        let feature = ChatFixtures.feature("owned")
        let url = "https://github.com/example/synthetic/pull/1"
        var link = FirstMateLink(id: "saved-link", featureID: feature.id, url: url, kind: "pull_request", title: "Saved change",
            source: "coordinator", createdAt: "2030-01-01T00:00:00Z", updatedAt: "2030-01-01T00:00:00Z")
        var snapshot = FirstMateSnapshot(feature: feature)
        var message = FirstMateMessage(id: "reply", featureID: feature.id, role: "assistant", text: "Saved change", status: "completed", createdAt: feature.updatedAt)
        snapshot.links = [link]
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot).isEmpty, "Title alone never invents PR identity")
        message.text = "[Saved change](\(url))"
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot)[message.id]?.map(\.id) == [link.id])
        message.text = "No URL here"; link.provenance.messageID = message.id; snapshot.links = [link]
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot)[message.id]?.count == 1)
        snapshot.links[0].hidden = true
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot).isEmpty)
        snapshot.links = [link]; snapshot.links[0].featureID = "foreign"
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot).isEmpty)
        snapshot.links = [link]; snapshot.links[0].url = "javascript:alert(1)"
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [message], snapshot: snapshot).isEmpty)
    }

    @Test("PR provenance outranks earlier quoted URLs and ambiguous fallbacks never pick a row")
    func pullRequestProvenancePriority() {
        let feature = ChatFixtures.feature("owned")
        let url = "https://github.com/example/synthetic/pull/1"
        let link = FirstMateLink(id: "saved-pr", featureID: feature.id, url: url, kind: "pull_request", title: "Saved change",
            source: "coordinator", provenance: .init(messageID: "M2"), createdAt: feature.updatedAt, updatedAt: feature.updatedAt)
        var snapshot = FirstMateSnapshot(feature: feature)
        let first = FirstMateMessage(id: "M1", featureID: feature.id, role: "assistant", text: "[Earlier quote](\(url))",
            status: "completed", createdAt: feature.updatedAt, metadata: .init(turnID: "turn", checkpoint: true))
        let second = FirstMateMessage(id: "M2", featureID: feature.id, role: "assistant", text: "Actual origin",
            status: "completed", createdAt: feature.updatedAt, metadata: .init(inReplyTo: "turn"))
        snapshot.links = [link]
        let cards = FirstMateMobileTranscriptPolicy.linkCards(messages: [first, second], snapshot: snapshot)
        #expect(cards[first.id] == nil)
        #expect(cards[second.id] == [link])
        let rows = FirstMateTranscriptLayout.rows(for: [first, second], now: .now, calendar: .current)
        #expect(rows.first?.additionalReplies.map(\.id) == [second.id])
        snapshot.links[0].provenance.messageID = nil
        var quote = second; quote.text = first.text
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [first, quote], snapshot: snapshot).isEmpty)
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [first, second], snapshot: snapshot)[first.id]?.first?.destination == link.destination)
        snapshot.links[0].provenance.messageID = second.id
        var foreign = second; foreign.featureID = "foreign"
        #expect(FirstMateMobileTranscriptPolicy.linkCards(messages: [first, foreign], snapshot: snapshot).isEmpty)
    }

    @Test("Document cards use authoritative owner and unique title, never hidden handoffs or duplicate identity")
    func resources() throws {
        var snapshot = try #require(FirstMateDemo.chatWindowFeatures().first { !$0.documents.isEmpty })
        let document = try #require(snapshot.presentedDocuments.first)
        let message = FirstMateMessage(id: "names-document", featureID: snapshot.feature.id, role: "assistant", text: document.title, status: "completed", createdAt: "2030-01-01T00:00:00Z")
        #expect(FirstMateMobileTranscriptPolicy.fileCards(messages: [message], snapshot: snapshot)[message.id]?.map(\.id) == [document.id])
        var duplicate = document; duplicate.id = "duplicate"; snapshot.documents.append(duplicate)
        #expect(FirstMateMobileTranscriptPolicy.fileCards(messages: [message], snapshot: snapshot)[message.id] == nil)
        snapshot.documents = [document]; snapshot.documents[0].featureID = "foreign-owner"
        #expect(FirstMateMobileTranscriptPolicy.fileCards(messages: [message], snapshot: snapshot).isEmpty)
    }
}
