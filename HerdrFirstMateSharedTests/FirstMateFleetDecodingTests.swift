import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate fleet summary decoding")
struct FirstMateFleetDecodingTests {
    @Test("A complete entry decodes every field from snake_case keys")
    func completeEntry() throws {
        let json = """
        {"ok": true, "generated_at": "2030-01-01T12:00:00Z", "features": [{
          "feature_id": "fmf_receipts", "title": "Receipt export", "label": "Receipts", "emoji": "🧾",
          "label_source": "user", "emoji_source": "user", "status": "blocked", "hud_status": "blocked", "step_index": 3,
          "step_fraction": 0.0, "percent": 50, "now": "QA failed twice on iPad.",
          "latest_message": {"id": "fmm_2", "role": "assistant", "text": "I stopped QA.", "created_at": "2030-01-01T11:20:00Z",
                             "skim_say": "QA failed twice, so I stopped."},
          "latest_first_mate_message_id": "fmm_2", "read_through_message_id": "fmm_1", "unread": true,
          "working_on_reply": true, "activity_at": "2030-01-01T11:20:00Z", "updated_at": "2030-01-01T11:21:00Z",
          "archived_at": null
        }]}
        """
        let response = try JSONDecoder().decode(FirstMateFleetResponse.self, from: Data(json.utf8))
        #expect(response.ok)
        #expect(response.generatedAt == "2030-01-01T12:00:00Z")
        let entry = try #require(response.features.first)
        #expect(entry.id == "fmf_receipts")
        #expect(entry.title == "Receipt export")
        #expect(entry.label == "Receipts")
        #expect(entry.labelSource == "user")
        #expect(entry.isUserLabel)
        #expect(entry.emoji == "🧾")
        #expect(entry.emojiSource == "user")
        #expect(entry.status == "blocked")
        #expect(entry.hudStatus == .blocked)
        #expect(entry.stepIndex == 3)
        #expect(entry.stepFraction == 0)
        #expect(entry.percent == 50)
        #expect(entry.now == "QA failed twice on iPad.")
        #expect(entry.latestMessage?.id == "fmm_2")
        #expect(entry.latestMessage?.isFromUser == false)
        #expect(entry.latestMessage?.skimSay == "QA failed twice, so I stopped.")
        #expect(entry.latestFirstMateMessageID == "fmm_2")
        #expect(entry.readThroughMessageID == "fmm_1")
        #expect(entry.unread)
        #expect(entry.workingOnReply)
        #expect(entry.activityAt == "2030-01-01T11:20:00Z")
        #expect(entry.updatedAt == "2030-01-01T11:21:00Z")
        #expect(entry.archivedAt == nil)
        #expect(!entry.isArchived)
    }

    @Test("Missing, null, and unexpected fields fall back instead of failing the entry")
    func tolerantEntry() throws {
        let json = """
        {"ok": true, "features": [
          {"feature_id": "fmf_minimal"},
          {"feature_id": "fmf_nulls", "title": "  Nulls everywhere and a long title  ", "label": null, "emoji": "",
           "label_source": "default", "status": "awaiting_direction", "hud_status": null, "step_index": null, "step_fraction": null,
           "percent": null, "now": null, "latest_message": null, "unread": null, "working_on_reply": null},
          {"feature_id": "fmf_future", "status": "running", "hud_status": "celebrating", "step_index": 9,
           "latest_message": {"id": "fmm_1", "role": "human", "text": "Ship it"}, "unread": "yes"},
          {"title": "No identifier"}
        ]}
        """
        let response = try JSONDecoder().decode(FirstMateFleetResponse.self, from: Data(json.utf8))
        #expect(response.features.map(\.featureID) == ["fmf_minimal", "fmf_nulls", "fmf_future"])

        let minimal = response.features[0]
        #expect(minimal.title == "")
        #expect(minimal.labelSource == nil)
        #expect(!minimal.isUserLabel)
        #expect(minimal.status == "unknown")
        #expect(minimal.hudStatus == .idle)
        #expect(minimal.emoji == FirstMateDefaultEmoji.emoji(for: "fmf_minimal"))
        #expect(minimal.stepIndex == nil)
        #expect(minimal.latestMessage == nil)
        #expect(!minimal.unread)
        #expect(!minimal.workingOnReply)

        let nulls = response.features[1]
        #expect(nulls.label == "Nulls everywhere and a l")
        #expect(nulls.label.count == 24)
        #expect(nulls.labelSource == "default")
        #expect(!nulls.isUserLabel)
        #expect(nulls.emoji == FirstMateDefaultEmoji.emoji(for: "fmf_nulls"))
        #expect(nulls.hudStatus == .turn, "A missing hud_status uses the client-side fallback")
        #expect(nulls.stepFraction == nil)
        #expect(nulls.percent == nil)
        #expect(nulls.now == nil)
        #expect(!nulls.unread)

        let future = response.features[2]
        #expect(future.hudStatus == .unknown, "An unknown hud_status never fails decoding")
        #expect(future.stepIndex == nil, "A step outside the six known steps is unknown")
        #expect(future.latestMessage?.isFromUser == true)
        #expect(future.latestMessage?.skimSay == nil)
        #expect(future.latestMessage?.createdAt == nil)
        #expect(!future.unread)
    }

    @Test("Every HUD status round-trips, and an unknown one decodes as unknown")
    func hudStatusDecoding() throws {
        for status in FirstMateHudStatus.allCases where status != .unknown {
            let data = try JSONEncoder().encode([status])
            #expect(try JSONDecoder().decode([FirstMateHudStatus].self, from: data) == [status])
        }
        let decoded = try JSONDecoder().decode([FirstMateHudStatus].self, from: Data(#"["later","blocked"]"#.utf8))
        #expect(decoded == [.unknown, .blocked])
        #expect(FirstMateHudStatus.allCases.filter(\.needsYou) == [.blocked, .turn, .ready])
    }

    @Test("An entry re-encodes to the same snake_case payload it came from")
    func entryRoundTrip() throws {
        let entry = FirstMateFleetEntry(
            featureID: "fmf_round", title: "Round trip", status: "running", hudStatus: .working,
            stepIndex: 1, stepFraction: 0, percent: 17, now: "Building",
            latestMessage: .init(id: "fmm_1", role: "user", text: "Go", createdAt: "2030-01-01T10:00:00Z"),
            unread: false, activityAt: "2030-01-01T10:00:00Z", labelSource: "user"
        )
        let data = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["feature_id"] as? String == "fmf_round")
        #expect(object["hud_status"] as? String == "working")
        #expect(object["step_index"] as? Int == 1)
        #expect(object["label_source"] as? String == "user")
        #expect(object["featureID"] == nil)
        #expect(try JSONDecoder().decode(FirstMateFleetEntry.self, from: data) == entry)
    }

    @Test("Read and HUD responses decode their effective values")
    func mutationResponses() throws {
        let read = try JSONDecoder().decode(FirstMateReadResponse.self, from: Data(
            #"{"ok":true,"feature_id":"fmf_1","read_through_message_id":"fmm_9","unread":false}"#.utf8
        ))
        #expect(read.featureID == "fmf_1")
        #expect(read.readThroughMessageID == "fmm_9")
        #expect(!read.unread)
        let hud = try JSONDecoder().decode(FirstMateHudUpdateResponse.self, from: Data(
            #"{"ok":true,"feature":{"feature_id":"fmf_1","title":"Sample","label":"Short","emoji":"🧪","emoji_source":"user","status":"ready","hud_status":"idle"}}"#.utf8
        ))
        #expect(hud.feature.label == "Short")
        #expect(hud.feature.emojiSource == "user")
    }

    @Test("Label provenance overrides heuristics; older companions use the server's clip")
    func labelProvenance() throws {
        func entry(_ title: String, _ label: String, source: String? = nil) -> FirstMateFleetEntry {
            .init(featureID: "fmf_synthetic", title: title, label: label, status: "ready", labelSource: source)
        }
        let title = "Receipt export for every storefront region"
        #expect(entry(title, title, source: "user").isUserLabel)
        #expect(entry(title, "Receipt export for…", source: "user").isUserLabel)
        #expect(!entry(title, "Custom", source: "default").isUserLabel)
        #expect(!entry(title, title).isUserLabel)
        #expect(!entry(title, "Receipt export for…").isUserLabel)
        #expect(!entry("  Receipt   export  ", "Receipt export").isUserLabel)
        #expect(entry(title, "Receipts").isUserLabel)
        #expect(!entry("", "").isUserLabel)
        #expect(entry("Receipt export", "", source: "user").isUserLabel,
                "An explicit user source remains authoritative even for an empty label")

        let json = #"{"feature_id":"fmf_old","title":"Receipt export for every storefront region","label":"Receipts","label_source":null}"#
        let decoded = try JSONDecoder().decode(FirstMateFleetEntry.self, from: Data(json.utf8))
        #expect(decoded.labelSource == nil)
        #expect(decoded.isUserLabel)
    }

    @Test("The server default label matches Python code-point and whitespace vectors", arguments: [
        ("Receipt export", "Receipt export"),
        ("Receipt export for every storefront region", "Receipt export for…"),
        ("Supercalifragilisticexpialidocious", "Supercalifragilisticexp…"),
        ("  QA\t failed\n  twice.  ", "QA failed twice."),
        ("\u{001C}Receipt\u{00A0}  export  ", "Receipt export"),
        ("12345678901234567890123 next", "12345678901234567890123…"),
        ("1234567890123456789012, next", "1234567890123456789012…"),
        (String(repeating: "e\u{0301}", count: 13), String(repeating: "e\u{0301}", count: 11) + "e…"),
    ])
    func serverDefaultLabel(title: String, expected: String) {
        #expect(FirstMateFleetEntry.serverDefaultLabel(title: title) == expected)
    }

    @Test("The fleet capability flag is read from the capability list")
    func capabilityFlag() throws {
        let with = try JSONDecoder().decode(FirstMateCapabilities.self, from: Data(
            #"{"ok":true,"capabilities":["first-mate-v1","first-mate-fleet-v1"]}"#.utf8
        ))
        let without = try JSONDecoder().decode(FirstMateCapabilities.self, from: Data(
            #"{"ok":true,"capabilities":["first-mate-v1","first-mate-fleet-v2"]}"#.utf8
        ))
        #expect(with.supportsFleet)
        #expect(!without.supportsFleet)
    }

    @Test("A message's crew assignment comes from metadata and never breaks old shapes")
    func messageAssignment() throws {
        let json = """
        [{"id":"m1","feature_id":"f1","role":"assistant","text":"QA failed","status":"delivered","created_at":"2030-01-01T00:00:00Z",
          "metadata":{"assignment_id":"as_9","turn_id":"t1"}},
         {"id":"m2","feature_id":"f1","role":"assistant","text":"Plain","status":"delivered","created_at":"2030-01-01T00:00:00Z",
          "metadata":{"assignment_id":42}},
         {"id":"m3","feature_id":"f1","role":"assistant","text":"Odd","status":"delivered","created_at":"2030-01-01T00:00:00Z",
          "metadata":"not an object"},
         {"id":"m4","feature_id":"f1","role":"user","text":"Hi","status":"delivered","created_at":"2030-01-01T00:00:00Z"}]
        """
        let messages = try JSONDecoder().decode([FirstMateMessage].self, from: Data(json.utf8))
        #expect(messages.map(\.assignmentID) == ["as_9", nil, nil, nil])

        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(messages[3])) as? [String: Any])
        #expect(plain["metadata"] == nil, "A message without an assignment keeps its old encoded shape")
        let crew = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(messages[0])) as? [String: Any])
        #expect((crew["metadata"] as? [String: Any])?["assignment_id"] as? String == "as_9")
        #expect(try JSONDecoder().decode(FirstMateMessage.self, from: JSONEncoder().encode(messages[0])) == messages[0])
    }
}

@Suite("First Mate HUD status fallback")
struct FirstMateHudStatusFallbackTests {
    @Test("Older companions map raw feature statuses by the spec table", arguments: [
        ("blocked", FirstMateHudStatus.blocked), ("awaiting_direction", .turn), ("running", .working),
        ("coordinating", .working), ("recovering", .working), ("unverified", .working), ("ready", .idle),
        ("paused", .idle), ("completed", .done), ("cancelled", .idle), ("something_new", .idle), ("", .idle),
    ])
    func mapping(status: String, expected: FirstMateHudStatus) {
        #expect(FirstMateHudStatus.fallback(featureStatus: status) == expected)
    }

    @Test("The fallback needs you exactly when First Mate attention does")
    func matchesAttention() {
        let statuses = ["blocked", "awaiting_direction", "running", "coordinating", "recovering", "ready", "paused",
                        "completed", "cancelled", "unverified", "unknown"]
        for status in statuses {
            #expect(FirstMateHudStatus.fallback(featureStatus: status).needsYou == ["awaiting_direction", "blocked"].contains(status))
        }
    }
}

@Suite("First Mate default emoji")
struct FirstMateDefaultEmojiTests {
    @Test("The palette is the shared sixteen single-scalar emoji, in order")
    func palette() {
        #expect(FirstMateDefaultEmoji.palette == ["🧭", "📦", "🧪", "🔍", "🧾", "📋", "🧩", "🚀", "🔔", "🎨", "📚", "🌱", "💡", "🔧", "🧰", "🪁"])
        #expect(FirstMateDefaultEmoji.palette.allSatisfy { $0.unicodeScalars.count == 1 })
    }

    @Test("Hash vectors match the companion exactly", arguments: [
        ("fmf_00000000000000000000000000000001", UInt32(3_332_065_392), 11, "🌱"),
        ("fmf_receipts", 779_939_090, 14, "🧰"),
        ("demo-session-continuity", 2_487_823_904, 9, "🎨"),
        ("receipts", 4_180_312_464, 10, "📚"),
        ("a", 3_826_002_220, 0, "🧭"),
        ("", 2_166_136_261, 9, "🎨"),
        ("fmf_9f8e7d6c5b4a39281706f5e4d3c2b1a0", 696_065_923, 14, "🧰"),
        ("fmf_ü✓", 1_798_211_435, 5, "📋"),
    ])
    func vectors(featureID: String, hash: UInt32, index: Int, emoji: String) {
        #expect(FirstMateDefaultEmoji.fnv1a(featureID) == hash)
        #expect(FirstMateDefaultEmoji.index(for: featureID) == index)
        #expect(FirstMateDefaultEmoji.emoji(for: featureID) == emoji)
    }
}

@Suite("First Mate chat window demo")
@MainActor
struct FirstMateChatDemoTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("Every demo skim is ready and verifies against its reply")
    func skimReaders() throws {
        let skimmed = FirstMateDemo.chatWindowFeatures(now: now).flatMap(\.messages).filter { $0.skim != nil }
        #expect(skimmed.count >= 3)
        for message in skimmed {
            #expect(FirstMateSkimReader(skim: message.skim, reply: message.text) != nil, "\(message.id) skim did not verify")
        }
        let long = try #require(skimmed.first { $0.text.split(separator: " ").count > 80 })
        #expect(FirstMateSkimReader(skim: long.skim, reply: long.text)?.restCount ?? 0 > 0)
        let question = try #require(FirstMateDemo.chatWindowFeatures(now: now).first { $0.feature.id == "demo-receipts" }?
            .messages.last)
        #expect(FirstMateSkimReader(skim: question.skim, reply: question.text)?.replies == ["Ship iPhone-only", "Investigate iPad"])
    }

    @Test("Early in the day the demo moves back so no message is in the future; later it keeps the design's times")
    func demoTimesNeverAhead() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let morning = try #require(calendar.date(bySettingHour: 9, minute: 26, second: 0, of: day))
        let evening = try #require(calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day))

        func times(_ now: Date) -> [String: [Date]] {
            Dictionary(uniqueKeysWithValues: FirstMateDemo.chatWindowFeatures(now: now, calendar: calendar).map { snapshot in
                (snapshot.feature.id, snapshot.messages.compactMap { HerdrTimestamp.date(from: $0.createdAt) })
            })
        }
        let early = times(morning), late = times(evening)
        let newest = try #require(early.values.flatMap { $0 }.max())
        #expect(newest <= morning.addingTimeInterval(-59))
        #expect(newest > morning.addingTimeInterval(-120))
        // One uniform shift, so every chat keeps the evening demo's order and spacing.
        let shift = try #require(late["demo-receipts"]?.first).timeIntervalSince(try #require(early["demo-receipts"]?.first))
        #expect(shift > 0)
        for (id, dates) in late {
            let shifted = try #require(early[id])
            #expect(dates.count == shifted.count)
            #expect(zip(dates, shifted).allSatisfy { abs($0.timeIntervalSince($1) - shift) < 1 })
        }
        let receipts = try #require(late["demo-receipts"]?.last)
        let clock = calendar.dateComponents([.hour, .minute], from: receipts)
        #expect(clock.hour == 11 && clock.minute == 20)
        #expect(FirstMateDemo.chatDemoShift(now: evening, calendar: calendar) == 0)
    }

    @Test("The demo has seven features, a crew message with a document, and three unread chats that need you")
    func demoShape() throws {
        let features = FirstMateDemo.chatWindowFeatures(now: now)
        let fleet = FirstMateDemo.chatWindowFleet(now: now)
        #expect(features.count == 7)
        #expect(fleet.map(\.featureID) == features.map(\.feature.id))
        #expect(Set(fleet.map(\.hudStatus)) == Set([.blocked, .turn, .ready, .working, .idle, .done]))
        #expect(fleet.filter { $0.unread && $0.hudStatus.needsYou }.map(\.featureID) == ["demo-receipts", "demo-release", "demo-search"])
        #expect(fleet.allSatisfy { $0.latestFirstMateMessageID != nil && $0.latestMessage != nil })

        let receipts = try #require(features.first { $0.feature.id == "demo-receipts" })
        let crew = try #require(receipts.messages.first { $0.assignmentID != nil })
        let assignment = try #require(receipts.assignments.first { $0.id == crew.assignmentID })
        #expect(assignment.title == "Device QA")
        #expect(assignment.role == "Tester")
        #expect(crew.text.contains("QA failure log"))
        #expect(receipts.documents.contains { $0.title == "QA failure log" && $0.assignmentID == assignment.id })

        let receiptEntry = try #require(fleet.first { $0.featureID == "demo-receipts" })
        #expect(receiptEntry.latestMessage?.skimSay?.isEmpty == false)
        #expect(receiptEntry.stepIndex == 3)
    }

    @Test("A store configured with the chat demo leaves the default demo untouched")
    func storeConfiguration() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true, demoFeatures: FirstMateDemo.chatWindowFeatures(now: now))
        #expect(store.features.count == 7)
        let classic = FirstMateStore()
        classic.configure(client: nil, demo: true)
        #expect(classic.features.count == 2)
    }
}
