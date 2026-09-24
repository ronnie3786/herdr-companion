import AVFoundation
import Observation
import SwiftUI

enum HerdrVoiceRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

/// The minimal recording surface `HerdrVoiceRecorder` drives.
///
/// `AVAudioRecorder` is the app implementation. Deterministic tests inject a
/// plain fake through `makeRecordingEngine`, so preparation/start failures and
/// delayed completion callbacks never touch a real microphone or audio device.
protocol HerdrRecordingEngine: AnyObject {
    var delegate: (any AVAudioRecorderDelegate)? { get set }
    var isMeteringEnabled: Bool { get set }
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func prepareToRecord() -> Bool
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: HerdrRecordingEngine {}

/// The shared record/preview engine behind both voice entry points.
///
/// Mac notes: macOS has no `AVAudioSession`, so the iOS category/activation
/// calls are gone outright — `AVAudioRecorder`/`AVAudioPlayer` drive the default
/// input/output devices directly. Microphone authorization goes through
/// `AVCaptureDevice` instead, and the sandbox needs
/// `com.apple.security.device.audio-input`. Everything else — the WAV settings,
/// the 10 minute cap, the 10 Hz metering into a 40 sample ring — is unchanged
/// from iOS on purpose: the server validates the uploaded bytes as mono 16 kHz
/// 16-bit PCM and rejects anything else.
@MainActor
@Observable
final class HerdrVoiceRecorder: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60
    private static let sampleCount = 40
    private static let captureStartFailureMessage = "The microphone could not start recording. "
        + "Check the audio input device and try again."

    private(set) var status: HerdrVoiceRecorderStatus = .idle
    /// True while the system microphone prompt is up and capture has not
    /// started. A caller that glows only for actual capture must key off
    /// `isRecording`, never a requested recording.
    private(set) var isRequestingPermission = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputURL: URL?
    private(set) var samples = HerdrVoiceRecorder.baselineSamples()
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval = 0
    var errorMessage: String?

    /// Microphone-permission seams. The app uses the system APIs; tests inject
    /// an authorized or denied status so no real prompt or capture runs.
    @ObservationIgnored var microphoneAuthorizationStatus: @MainActor () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    @ObservationIgnored var requestMicrophoneAccess: @MainActor () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The recording-engine factory. Tests replace it with a fake engine to
    /// exercise failed preparation/start and delayed delegate callbacks.
    @ObservationIgnored var makeRecordingEngine: @MainActor (URL, [String: Any]) throws -> any HerdrRecordingEngine = { url, settings in
        try AVAudioRecorder(url: url, settings: settings)
    }

    /// Called after any permission, status, or error change. Existing callers
    /// never set it; the report sheet's adapter uses it to mirror capture
    /// state (permission pending versus recording) without polling.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Called exactly once each time a capture session ends with a file ready
    /// to transcribe, whether by explicit `stopRecording()` or the automatic
    /// duration limit. The generation check makes the two paths converge on
    /// one callback instead of racing.
    @ObservationIgnored var onCaptureFinished: (() -> Void)?

    // Reached from `deinit`, which is nonisolated, and never observed by a view.
    @ObservationIgnored nonisolated(unsafe) private var recorder: (any HerdrRecordingEngine)?
    private var player: AVAudioPlayer?
    @ObservationIgnored nonisolated(unsafe) private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var startGeneration = 0
    @ObservationIgnored private var notifiedCaptureGeneration = -1

    var isRecording: Bool { status == .recording }
    var hasRecording: Bool { outputURL != nil || elapsedTime > 0 }
    var canSave: Bool { status == .finished && outputURL != nil && elapsedTime > 0 }

    var playbackProgress: Double {
        guard elapsedTime > 0 else { return 0 }
        return min(max(playbackTime / elapsedTime, 0), 1)
    }

    deinit {
        recordingTimer?.invalidate()
        if recorder?.isRecording == true {
            recorder?.stop()
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func togglePlayback() {
        guard status == .finished, let outputURL else { return }
        if isPlaying {
            pausePlayback()
            return
        }

        do {
            let player: AVAudioPlayer
            if let current = self.player {
                player = current
            } else {
                player = try AVAudioPlayer(contentsOf: outputURL)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
            }

            if player.duration > 0, player.currentTime >= player.duration {
                player.currentTime = 0
            }
            playbackTime = player.currentTime
            player.play()
            isPlaying = true
            startPlaybackTimer()
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
            stopPlaybackTimer()
        }
    }

    func stopForBackground() {
        if isRecording {
            stopRecording()
        }
        if isPlaying {
            pausePlayback()
        }
    }

    func discard() {
        cleanup(deleteFile: true)
    }

    /// Relinquishes ownership of the temporary file so the uploader can read it
    /// after this sheet disappears.
    func relinquishSavedFile() {
        cleanup(deleteFile: false)
    }

    func startRecording() {
        errorMessage = nil
        isRequestingPermission = false
        switch microphoneAuthorizationStatus() {
        case .authorized:
            beginCapture()
        case .denied, .restricted:
            errorMessage = "Microphone access is disabled for Herdr."
            notifyStateChange()
        case .notDetermined:
            isRequestingPermission = true
            notifyStateChange()
            let generation = startGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await self.requestMicrophoneAccess()
                guard generation == self.startGeneration else { return }
                self.isRequestingPermission = false
                if granted {
                    self.beginCapture()
                } else {
                    self.errorMessage = "Microphone access is required to record a voice note."
                    self.notifyStateChange()
                }
            }
        @unknown default:
            errorMessage = "Microphone permission is unavailable."
            notifyStateChange()
        }
    }

    private func beginCapture() {
        errorMessage = nil
        do {
            discardCurrentFile()

            let outputURL = VoiceRecordingPolicy.makeTemporaryURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let engine = try makeRecordingEngine(outputURL, settings)
            engine.delegate = self
            engine.isMeteringEnabled = true
            self.recorder = engine
            self.outputURL = outputURL
            // Both calls report whether capture actually started. A glowing
            // Stop control must never appear for an unavailable audio device,
            // so a failed attempt cleans up and becomes an actionable error
            // instead of a fake recording.
            guard engine.prepareToRecord() else {
                cleanup(deleteFile: true)
                errorMessage = Self.captureStartFailureMessage
                notifyStateChange()
                return
            }
            try VoiceRecordingPolicy.applyCompleteProtection(to: outputURL)
            guard engine.record(forDuration: Self.maxDuration) else {
                cleanup(deleteFile: true)
                errorMessage = Self.captureStartFailureMessage
                notifyStateChange()
                return
            }

            elapsedTime = 0
            playbackTime = 0
            samples = Self.baselineSamples()
            status = .recording
            startRecordingTimer()
            notifyStateChange()
        } catch {
            cleanup(deleteFile: true)
            errorMessage = error.localizedDescription
            notifyStateChange()
        }
    }

    func stopRecording() {
        let duration = recorder?.currentTime ?? elapsedTime
        recorder?.stop()
        recorder = nil
        stopRecordingTimer()
        elapsedTime = min(duration, Self.maxDuration)
        status = outputURL == nil ? .idle : .finished
        notifyCaptureFinishedIfNeeded()
        notifyStateChange()
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingTimerTick()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let recorder {
            elapsedTime = recorder.currentTime
        }
    }

    private func recordingTimerTick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsedTime = min(recorder.currentTime, Self.maxDuration)

        var updatedSamples = samples
        updatedSamples.append(Self.normalizedLevel(fromPower: recorder.averagePower(forChannel: 0)))
        if updatedSamples.count > Self.sampleCount {
            updatedSamples.removeFirst(updatedSamples.count - Self.sampleCount)
        }
        samples = updatedSamples

        if recorder.currentTime >= Self.maxDuration {
            stopRecording()
        }
    }

    private func cleanup(deleteFile: Bool) {
        startGeneration += 1
        isRequestingPermission = false
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil

        if deleteFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        errorMessage = nil
        samples = Self.baselineSamples()
        status = .idle
        notifyStateChange()
    }

    private func discardCurrentFile() {
        startGeneration += 1
        isRequestingPermission = false
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        samples = Self.baselineSamples()
    }

    private func pausePlayback() {
        player?.pause()
        playbackTime = player?.currentTime ?? playbackTime
        isPlaying = false
        stopPlaybackTimer()
    }

    private func stopPlayback(reset: Bool) {
        stopPlaybackTimer()
        player?.stop()
        if reset {
            player?.currentTime = 0
            player = nil
            playbackTime = 0
        } else {
            playbackTime = player?.currentTime ?? playbackTime
        }
        isPlaying = false
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopPlaybackTimer()
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private static func baselineSamples() -> [CGFloat] {
        Array(repeating: 0.08, count: sampleCount)
    }

    private static func normalizedLevel(fromPower power: Float) -> CGFloat {
        let clamped = min(max(power, -50), 0)
        let linear = pow(10, Double(clamped) / 35)
        return CGFloat(min(max(linear, 0.08), 1))
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleCaptureFinished(recorder, successfully: flag)
        }
    }

    /// One finished-capture path for the delegate callback and the
    /// deterministic test seam. A callback from a recorder that is no longer
    /// current (after an explicit Stop, discard, restart, target change, or
    /// dismissal) is ignored, so an obsolete capture can never clear the new
    /// one, mark its file finished, or invoke the new transcription callback.
    func handleCaptureFinished(_ engine: any HerdrRecordingEngine, successfully flag: Bool) {
        guard let current = recorder, current === engine else { return }
        let duration = engine.currentTime
        stopRecordingTimer()
        recorder = nil
        elapsedTime = min(max(elapsedTime, duration), Self.maxDuration)
        status = flag && outputURL != nil ? .finished : .idle
        if !flag {
            errorMessage = "Recording failed."
        }
        notifyCaptureFinishedIfNeeded()
        notifyStateChange()
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    /// One finished-capture callback per capture session. Both the explicit
    /// Stop and the automatic duration completion land here, and the shared
    /// generation marker makes a delegate callback after an explicit stop a
    /// no-op instead of a second transcription.
    private func notifyCaptureFinishedIfNeeded() {
        guard status == .finished, outputURL != nil else { return }
        guard notifiedCaptureGeneration != startGeneration else { return }
        notifiedCaptureGeneration = startGeneration
        onCaptureFinished?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlaybackTimer()
            self.player?.currentTime = 0
            playbackTime = 0
            isPlaying = false
        }
    }

}
