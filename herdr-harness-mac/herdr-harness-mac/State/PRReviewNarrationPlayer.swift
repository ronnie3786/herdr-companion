import AVFoundation
import Foundation
import Observation

protocol PRReviewAudioEngine: AnyObject {
    var delegate: (any AVAudioPlayerDelegate)? { get set }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: PRReviewAudioEngine {}

@MainActor
@Observable
final class PRReviewNarrationPlayer: NSObject, AVAudioPlayerDelegate {
    enum Phase: Equatable { case empty, ready, playing, paused, finished, failed(String) }
    private(set) var phase: Phase = .empty
    private(set) var duration = 0.0
    private(set) var rate = 1.0
    /// Low-frequency display value only. Drawings always sample the media clock.
    private(set) var progressTime = 0.0
    @ObservationIgnored private(set) var generationID = UUID().uuidString
    @ObservationIgnored var onFrame: ((PRReviewGuideAnnotationFrame) -> Void)?
    @ObservationIgnored var onCompletion: (() -> Void)?
    @ObservationIgnored var makePlayer: (Data) throws -> any PRReviewAudioEngine = { try AVAudioPlayer(data: $0) }
    @ObservationIgnored private var player: (any PRReviewAudioEngine)?
    @ObservationIgnored private var cues: [PRReviewTimedCue] = []
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var lastDisplaySample = -1.0
    @ObservationIgnored private let speechOwner = UUID()
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?

    var currentTime: Double { phase == .finished ? duration : player?.currentTime ?? 0 }
    var isPlaying: Bool { phase == .playing }

    deinit { timer?.invalidate() }

    func load(_ manifest: PRReviewNarrationManifest, expectedScript: String, expectedVoice: String) throws {
        stop()
        do {
            let data = try manifest.validatedAudio(expectedScript: expectedScript, expectedVoice: expectedVoice)
            let engine = try makePlayer(data)
            guard let expectedDuration = manifest.duration,
                  engine.duration.isFinite, abs(engine.duration - expectedDuration) <= 0.1 else {
                throw PRReviewNarrationError.invalidRecording
            }
            // Setting enableRate after prepareToPlay silently fails on some audio routes.
            engine.enableRate = true
            engine.rate = Float(rate)
            engine.delegate = self
            guard engine.prepareToPlay() else { throw PRReviewNarrationError.invalidRecording }
            player = engine
            duration = engine.duration
            cues = manifest.cues
            phase = .ready
            emitFrame()
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    func play() {
        guard let player else { return }
        if phase == .finished { player.currentTime = 0 }
        HerdrSpeechOwnership.shared.claim(speechOwner) { [weak self] in self?.pause() }
        guard player.play() else {
            HerdrSpeechOwnership.shared.release(speechOwner)
            phase = .failed("The recording could not play. You can keep reading the walkthrough.")
            return
        }
        phase = .playing
        startTimer()
        emitFrame()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        timer?.invalidate()
        timer = nil
        if phase != .finished { phase = .paused }
        HerdrSpeechOwnership.shared.release(speechOwner)
        emitFrame()
    }

    func seek(to time: Double) {
        guard let player, time.isFinite else { return }
        let wasPlaying = phase == .playing
        player.currentTime = min(duration, max(0, time))
        if phase == .finished { phase = .paused }
        if wasPlaying && player.currentTime >= duration {
            finishPlayback(successfully: true)
        } else { emitFrame() }
    }

    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        rate = min(2, max(0.5, value))
        player?.rate = Float(rate)
        emitFrame()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        cues = []
        duration = 0
        progressTime = 0
        phase = .empty
        // Clear this generation before creating a new one. Queued frames cannot
        // paint after the channel switches to the replacement generation.
        emitFrame()
        generationID = UUID().uuidString
        sequence = 0
        lastDisplaySample = -1
        HerdrSpeechOwnership.shared.release(speechOwner)
    }

    func refreshFrame() { emitFrame() }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitFrame(updateDisplay: false) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitFrame(updateDisplay: Bool = true) {
        let time = currentTime
        if updateDisplay || abs(time - lastDisplaySample) >= 0.25 {
            progressTime = time
            lastDisplaySample = time
        }
        sequence &+= 1
        onFrame?(.init(generation: generationID, sequence: sequence, time: time, cues: cues))
    }

    private func finishPlayback(successfully: Bool) {
        timer?.invalidate()
        timer = nil
        player?.pause()
        phase = successfully ? .finished : .failed("Playback was interrupted. Replay the explanation to continue.")
        HerdrSpeechOwnership.shared.release(speechOwner)
        emitFrame()
        if successfully { onCompletion?() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finishedID else { return }
            self.finishPlayback(successfully: flag)
        }
    }

    #if DEBUG
    func finishForTesting(successfully: Bool = true) { finishPlayback(successfully: successfully) }
    #endif
}
