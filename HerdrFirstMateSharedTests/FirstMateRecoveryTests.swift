import Foundation
import Testing
#if os(macOS)
import SwiftUI
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate recovery visibility", .serialized)
@MainActor
struct FirstMateRecoveryTests {
    @Test func olderSnapshotsRemainCompatible() throws {
        let snapshot = FirstMateDemo.features(step: 0)[0]
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.runtimeHealth == nil)
        let list = try JSONDecoder().decode(FirstMateFeatureList.self, from: Data(#"{"ok":true,"features":[]}"#.utf8))
        #expect(list.runtimeHealth == nil)
    }

    @Test func healthWarningsNeverClaimThatWorkContinues() throws {
        let raw = #"{"status":"degraded","scheduler_alive":true,"error_kind":"storage_full","last_success_at":"2026-01-01T00:00:00Z","consecutive_failures":2}"#
        var health = try JSONDecoder().decode(FirstMateRuntimeHealth.self, from: Data(raw.utf8))
        #expect(health.warning?.contains("storage is full") == true)
        #expect(health.lastSuccessAt == "2026-01-01T00:00:00Z")
        for status in ["stalled", "stopped", "starting", "future-status"] {
            health.status = status
            #expect(health.warning != nil)
        }
        health.status = "healthy"
        #expect(health.warning == nil)
    }

    @Test func healthOverridesActiveLabelsWithoutChangingWorkflowFacts() {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.status = "running"
        snapshot.runtimeHealth = .init(status: "degraded", schedulerAlive: true, errorKind: "storage_full", consecutiveFailures: 1)
        let store = FirstMateStore()
        store.receive(snapshot)
        store.select(snapshot.feature.id)
        #expect(store.executionDisplayStatus(for: snapshot.feature) == "unverified")
        #expect(store.snapshot?.feature.status == "running")
        snapshot.feature.status = "completed"
        #expect(store.executionDisplayStatus(for: snapshot.feature) == "completed")
        snapshot.feature.status = "running"
        snapshot.runtimeHealth?.status = "healthy"
        store.receive(snapshot)
        #expect(store.executionDisplayStatus(for: snapshot.feature) == "running")
        store.configure(client: nil, demo: false)
        #expect(store.runtimeHealth == nil)
    }

    @Test func recoveryNoticeSurvivesAFeatureStatusMismatch() {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.status = "running"
        snapshot.assignments[0].status = "recovering"
        #expect(snapshot.recoveryNeedsDirection)
        snapshot.assignments[0].status = "completed"
        snapshot.feature.status = "recovering"
        #expect(snapshot.recoveryNeedsDirection)
    }

    @Test func recoveryFactsDecodeWithoutInterpretingUnrelatedEventPayloads() throws {
        let raw = #"{"sequence":12,"id":"recovery-event","feature_id":"synthetic-feature","type":"recovery.checkpoint","summary":"Recovery facts retained","created_at":"2026-01-01T00:00:00Z","payload":{"assignment_id":"synthetic-assignment","generation":2,"workspace_path":"/workspace/example","head":"synthetic-head","working_tree_status":" M Sources/Timer.swift","side_effects_verified":false,"handoff_document_id":"latest-handoff","native_session_id":"interrupted-session"}}"#
        let event = try JSONDecoder().decode(FirstMateEvent.self, from: Data(raw.utf8))
        let facts = try #require(event.recoveryCheckpoint)
        #expect(facts.workspacePath == "/workspace/example")
        #expect(facts.handoffDocumentID == "latest-handoff")
        #expect(facts.workingTreeStatus?.contains("Timer.swift") == true)
        #expect(facts.nativeSessionID == "interrupted-session")
        #expect(try JSONDecoder().decode(FirstMateEvent.self, from: JSONEncoder().encode(event)) == event)
        let unrelated = raw.replacingOccurrences(of: "recovery.checkpoint", with: "pi.tool_execution_end")
        #expect(try JSONDecoder().decode(FirstMateEvent.self, from: Data(unrelated.utf8)).recoveryCheckpoint == nil)
        let advisor = raw.replacingOccurrences(of: #""workspace_path":"/workspace/example","# , with: "")
        #expect(try JSONDecoder().decode(FirstMateEvent.self, from: Data(advisor.utf8)).recoveryCheckpoint?.workspacePath == nil)
    }

    @Test func reliabilityScheduleAndCurrentPositionAreAdditive() throws {
        let raw = #"{"status":"healthy","scheduler_alive":true,"consecutive_failures":0,"guardian_alive":true,"automatic_recovery":true,"sweep_interval_seconds":3600,"last_sweep_at":"2026-01-01T00:00:00Z","next_sweep_at":"2026-01-01T01:00:00Z","scheduler_restarts":1}"#
        let health = try JSONDecoder().decode(FirstMateRuntimeHealth.self, from: Data(raw.utf8))
        #expect(health.automaticRecovery == true)
        #expect(health.guardianAlive == true)
        #expect(health.sweepIntervalSeconds == 3600)
        #expect(health.schedulerRestarts == 1)
        var assignment = FirstMateDemo.features(step: 0)[0].assignments[0]
        assignment.metadata = .init(progress: .init(summary: "Parser implemented", nextAction: "Run focused tests", evidence: "Two source files updated", recordedAt: "2026-01-01T00:00:00Z", waitUntilEpoch: nil))
        let decoded = try JSONDecoder().decode(FirstMateAssignment.self, from: JSONEncoder().encode(assignment))
        #expect(decoded.metadata?.progress?.nextAction == "Run focused tests")
        #expect(decoded == assignment)
    }

    @Test func storageReserveIsNotReportedAsAnActualFullDisk() {
        let health = FirstMateRuntimeHealth(status: "degraded", schedulerAlive: true, errorKind: "storage_low", consecutiveFailures: 1)
        #expect(health.warning?.contains("free-space reserve") == true)
        #expect(health.warning?.contains("storage is full") == false)
    }

    #if os(macOS)
    @Test func stabilityViewRendersScheduleAndProgress() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.assignments[0].metadata = .init(progress: .init(summary: "Parser implemented", nextAction: "Run focused tests", evidence: "Two source files updated", recordedAt: "2026-01-01T00:00:00Z", waitUntilEpoch: nil))
        var health = FirstMateRuntimeHealth(status: "healthy", schedulerAlive: true, consecutiveFailures: 0)
        health.automaticRecovery = true
        health.guardianAlive = true
        health.sweepIntervalSeconds = 3600
        health.lastSweepAt = "2026-01-01T00:00:00Z"
        health.nextSweepAt = "2026-01-01T01:00:00Z"
        let view = FirstMateReliabilityView(health: health, snapshot: snapshot).frame(width: 420)
        let image = try #require(ImageRenderer(content: view).nsImage)
        #expect(image.size.height > 100)
    }

    @Test func warningRendersAtNarrowReadingWidth() throws {
        let health = FirstMateRuntimeHealth(status: "degraded", schedulerAlive: true, errorKind: "storage_full", consecutiveFailures: 1)
        let view = FirstMateExecutionNotice(text: try #require(health.warning), lastSuccessAt: "2026-01-01T00:00:00Z")
            .frame(width: 360)
        let image = try #require(ImageRenderer(content: view).nsImage)
        #expect(image.size.width == 360)
        #expect(image.size.height > 60)
    }
    #endif
}
