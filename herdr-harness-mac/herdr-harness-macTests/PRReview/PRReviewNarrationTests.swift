import AVFoundation
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review narration", .serialized)
struct PRReviewNarrationTests {
    private let target = PRReviewGuideTarget(path: "Sources/Cache.swift", side: .after, startLine: 3, endLine: 5)

    private func fixture() -> PRReviewNarrationManifest {
        let data = Data("synthetic-recording".utf8)
        return .init(available: true, script: "Check ownership before returning.", voice: "af_jessica",
                     audioBase64: data.base64EncodedString(), contentType: "audio/wav",
                     scriptSHA256: PRReviewNarrationManifest.sha256(Data("Check ownership before returning.".utf8)),
                     audioSHA256: PRReviewNarrationManifest.sha256(data), duration: 5,
                     words: [.init(word: "Check", start: 0.1, end: 0.5), .init(word: "ownership", start: 1, end: 1.6)],
                     cues: [.init(id: "ownership", shape: "circle", targets: [target], onset: 1, drawSeconds: 0.8, until: 4)])
    }

    private func loadedPlayer() throws -> (PRReviewNarrationPlayer, NarrationEngine) {
        let player = PRReviewNarrationPlayer()
        let engine = NarrationEngine()
        player.makePlayer = { _ in engine }
        let manifest = fixture()
        try player.load(manifest, expectedScript: manifest.script, expectedVoice: manifest.voice)
        return (player, engine)
    }

    @Test("Timeline is deterministic through pause seek expiry and reduced motion")
    func cueSampling() {
        let cue = fixture().cues[0]
        #expect(cue.progress(at: 0.99) == nil)
        #expect(cue.progress(at: 1) == 0)
        #expect(abs(cue.progress(at: 1.4)! - 0.5) < 0.00001)
        #expect(cue.progress(at: 1.4, reducedMotion: true) == 1)
        #expect(cue.progress(at: 3.99) == 1)
        #expect(cue.progress(at: 4) == nil)
        #expect(cue.progress(at: 1.4) == cue.progress(at: 1.4))
    }

    @Test("A stale script voice or recording cannot reuse a cue track")
    func identities() {
        let manifest = fixture()
        #expect(throws: PRReviewNarrationError.self) {
            try manifest.validatedAudio(expectedScript: "Different narration", expectedVoice: manifest.voice)
        }
        #expect(throws: PRReviewNarrationError.self) {
            try manifest.validatedAudio(expectedScript: manifest.script, expectedVoice: "am_echo")
        }
        var changed = manifest
        changed.audioBase64 = Data("other-recording".utf8).base64EncodedString()
        #expect(throws: PRReviewNarrationError.self) {
            try changed.validatedAudio(expectedScript: manifest.script, expectedVoice: manifest.voice)
        }
    }

    @Test("Decoded audio duration must agree with its timing manifest")
    func durationMismatch() throws {
        let player = PRReviewNarrationPlayer()
        let engine = NarrationEngine()
        engine.duration = 7
        player.makePlayer = { _ in engine }
        let manifest = fixture()
        #expect(throws: PRReviewNarrationError.self) {
            try player.load(manifest, expectedScript: manifest.script, expectedVoice: manifest.voice)
        }
    }

    @Test("Pause seek rate replay and stop sample the engine clock immediately")
    func controls() throws {
        let (player, engine) = try loadedPlayer()
        defer { player.stop() }
        var frames: [PRReviewGuideAnnotationFrame] = []
        player.onFrame = { frames.append($0) }
        player.play()
        engine.currentTime = 1.4
        player.pause()
        #expect(frames.last?.time == 1.4)
        #expect(player.phase == .paused)
        player.seek(to: 0.3)
        #expect(frames.last?.time == 0.3)
        player.setRate(1.5)
        #expect(engine.rate == 1.5)
        #expect(frames.last?.time == 0.3)
        player.play()
        player.finishForTesting()
        #expect(player.phase == .finished)
        #expect(frames.last?.time == 5)
        player.play()
        #expect(engine.currentTime == 0)
        #expect(player.phase == .playing)
        let oldGeneration = player.generationID
        player.stop()
        #expect(frames.last?.cues.isEmpty == true)
        #expect(player.generationID != oldGeneration)
        #expect(engine.enabledBeforePrepare)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    }

    @Test("Another speech or capture owner pauses a guide without losing place")
    func ownership() throws {
        let (player, engine) = try loadedPlayer()
        defer { player.stop() }
        player.play()
        engine.currentTime = 2.3
        let capture = UUID()
        HerdrSpeechOwnership.shared.claim(capture, interrupt: {})
        #expect(player.phase == .paused)
        #expect(player.currentTime == 2.3)
        HerdrSpeechOwnership.shared.release(capture)
        #expect(player.phase == .paused)
    }

    @Test("Completion notifies the session once and retains final drawings")
    func explicitNext() throws {
        let (player, _) = try loadedPlayer()
        defer { player.stop() }
        var completions = 0
        player.onCompletion = { completions += 1 }
        player.play()
        player.finishForTesting()
        #expect(completions == 1)
        #expect(player.phase == .finished)
        #expect(player.progressTime == player.duration)
    }

    @Test("Unsupported captions decode as text without guessed timing")
    func fallback() throws {
        let manifest = try JSONDecoder().decode(PRReviewNarrationManifest.self, from: Data("""
        {"available":false,"script":"Keep reading.","voice":"af_jessica","words":[],"cues":[],"reason":"Unavailable"}
        """.utf8))
        #expect(manifest.duration == nil)
        #expect(manifest.cues.isEmpty)
        #expect(throws: PRReviewNarrationError.self) {
            try manifest.validatedAudio(expectedScript: manifest.script, expectedVoice: manifest.voice)
        }
    }
}

private final class NarrationEngine: PRReviewAudioEngine {
    var delegate: (any AVAudioPlayerDelegate)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 5
    var enableRate = false
    var rate: Float = 1
    var enabledBeforePrepare = false
    func prepareToPlay() -> Bool { enabledBeforePrepare = enableRate; return true }
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}
