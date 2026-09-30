import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import QuartzCore

/// CoreMedia objects built from SimPortal's H.264 messages.
enum SimulatorH264SampleBuilder {
    enum BuildError: Error, Equatable {
        case formatDescription(OSStatus)
        case malformedFrame
        case sampleBuffer(String)
    }

    /// Hands the `avcC` record to VideoToolbox as-is, the way an MP4 demuxer
    /// would, instead of re-parsing its parameter sets.
    static func formatDescription(for config: SimulatorH264Config) throws -> CMVideoFormatDescription {
        let atoms: [String: Any] = ["avcC": config.avcC]
        let extensions: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: Int32(config.width), height: Int32(config.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw BuildError.formatDescription(status) }
        return format
    }

    static func sampleBuffer(for frame: SimulatorH264Frame, format: CMVideoFormatDescription,
                             nalLengthSize: Int) throws -> CMSampleBuffer {
        guard frame.isWellFormed(nalLengthSize: nalLengthSize) else { throw BuildError.malformedFrame }
        do {
            // The decoder gets its own copy, so no message buffer outlives the socket read.
            let block = try CMBlockBuffer(length: frame.data.count, flags: .assureMemoryNow)
            try frame.data.withUnsafeBytes { try block.replaceDataBytes(with: $0) }
            let timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTime(value: CMTimeValue(clamping: frame.timestampUs), timescale: 1_000_000),
                decodeTimeStamp: .invalid)
            let sample = try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1,
                                            sampleTimings: [timing], sampleSizes: [frame.data.count])
            // Live video: show each frame as soon as it decodes, whatever its timestamp.
            sample.sampleAttachments[0][.displayImmediately] = true
            if !frame.isKeyframe { sample.sampleAttachments[0][.notSync] = true }
            return sample
        } catch {
            throw BuildError.sampleBuffer(String(describing: error))
        }
    }
}

enum SimulatorJPEGDecoder {
    /// Decodes fully off the main actor; otherwise Core Animation would
    /// decode lazily on the main thread when the image is first drawn.
    @concurrent static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// Draws the stream: H.264 through an `AVSampleBufferDisplayLayer`, JPEG into
/// a plain `CALayer`. The controller owns it, so frames keep flowing while
/// SwiftUI rebuilds views; a screen view only hosts `layer`, and a layer has
/// one superlayer, so show a controller in one screen view at a time.
@MainActor
final class SimulatorVideoRenderer {
    enum Event: Equatable, Sendable {
        /// A frame went to the display.
        case frameShown
        /// Decoding can only resume from a keyframe.
        case needsKeyframe
        /// Decoding failed and the decoder was reset.
        case decodeFailed
    }

    /// The screen: its frame is the aspect-fit stream inside the host's bounds.
    let layer = CALayer()
    let videoLayer = AVSampleBufferDisplayLayer()
    let imageLayer = CALayer()
    var onEvent: (@MainActor (Event) -> Void)?

    private(set) var codec: SimulatorStreamCodec = .h264
    private(set) var needsKeyframe = true
    /// The displayed screen in the host view's top-left coordinates; input maps against it.
    private(set) var displayRect: CGRect = .zero

    /// The host view's bounds; the host is flipped (top-left origin), and so is its layer's geometry.
    var hostBounds: CGRect = .zero {
        didSet { if hostBounds != oldValue { relayout() } }
    }

    /// The stream's size in pixels, for aspect fitting.
    var contentPixelSize: CGSize? {
        didSet { if contentPixelSize != oldValue { relayout() } }
    }

    var contentsScale: CGFloat = 2 {
        didSet {
            withoutAnimation {
                for sublayer in [layer, videoLayer, imageLayer] { sublayer.contentsScale = contentsScale }
            }
        }
    }

    private var config: SimulatorH264Config?
    private var formatDescription: CMVideoFormatDescription?
    private var isDecodingJPEG = false
    private var pendingJPEG: SimulatorJPEGFrame?
    private var jpegGeneration = 0
    private var failureObservations: [Task<Void, Never>] = []

    init() {
        layer.masksToBounds = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        videoLayer.videoGravity = .resize
        // A simulator left on screen should not keep the Mac's display awake.
        videoLayer.preventsDisplaySleepDuringVideoPlayback = false
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        layer.addSublayer(videoLayer)
        layer.addSublayer(imageLayer)
        observeDecodeFailures()
    }

    deinit {
        for observation in failureObservations { observation.cancel() }
    }

    // MARK: Codec

    func setCodec(_ codec: SimulatorStreamCodec) {
        guard codec != self.codec else { return }
        self.codec = codec
        withoutAnimation {
            videoLayer.isHidden = codec != .h264
            imageLayer.isHidden = codec != .jpeg
        }
        switch codec {
        case .jpeg:
            config = nil
            formatDescription = nil
            videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        case .h264:
            cancelJPEGWork()
            withoutAnimation { imageLayer.contents = nil }
        }
        needsKeyframe = true
    }

    /// Forgets decoder state when the stream restarts; the last picture stays up.
    func resetStream() {
        config = nil
        formatDescription = nil
        needsKeyframe = true
        videoLayer.sampleBufferRenderer.flush()
        cancelJPEGWork()
    }

    // MARK: H.264

    func configure(_ config: SimulatorH264Config) {
        guard codec == .h264 else { return }
        if config == self.config, formatDescription != nil { return }
        do {
            formatDescription = try SimulatorH264SampleBuilder.formatDescription(for: config)
            self.config = config
            videoLayer.sampleBufferRenderer.flush()
            needsKeyframe = true
            onEvent?(.needsKeyframe)
        } catch {
            self.config = nil
            formatDescription = nil
            onEvent?(.decodeFailed)
        }
    }

    func enqueue(_ frame: SimulatorH264Frame) {
        guard codec == .h264, formatDescription != nil else { return }
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            reportDecodeFailure()
            // The report may have switched to JPEG; otherwise this frame can still be the keyframe that recovers.
            guard codec == .h264 else { return }
        }
        guard let format = formatDescription, let config else { return }
        if needsKeyframe && !frame.isKeyframe { return }
        if !frame.isKeyframe && !renderer.isReadyForMoreMediaData {
            // The decoder is behind: skip ahead to a keyframe rather than queue without bound.
            needsKeyframe = true
            onEvent?(.needsKeyframe)
            return
        }
        let sample: CMSampleBuffer
        do {
            sample = try SimulatorH264SampleBuilder.sampleBuffer(for: frame, format: format, nalLengthSize: config.nalLengthSize)
        } catch {
            reportDecodeFailure()
            return
        }
        renderer.enqueue(sample)
        if renderer.status == .failed {
            reportDecodeFailure()
            return
        }
        needsKeyframe = false
        onEvent?(.frameShown)
    }

    /// A frame never reached the decoder, so the ones after it reference a picture it lacks.
    func frameDropped() {
        guard codec == .h264, formatDescription != nil, !needsKeyframe else { return }
        needsKeyframe = true
        onEvent?(.needsKeyframe)
    }

    /// Resets the decoder so the next keyframe can resume it. Also the hook
    /// tests use to simulate a failing hardware decoder.
    func reportDecodeFailure() {
        videoLayer.sampleBufferRenderer.flush()
        needsKeyframe = true
        onEvent?(.decodeFailed)
    }

    /// Decode failures arrive asynchronously, possibly on a static screen
    /// that sends no next frame to notice them with, so listen for them.
    private func observeDecodeFailures() {
        let rendererID = ObjectIdentifier(videoLayer.sampleBufferRenderer)
        let names = [
            AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
        ]
        failureObservations = names.map { name in
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: name) {
                    guard let object = notification.object as AnyObject?, ObjectIdentifier(object) == rendererID else { continue }
                    self?.rendererReportedTrouble(name)
                }
            }
        }
    }

    private func rendererReportedTrouble(_ name: Notification.Name) {
        guard codec == .h264, formatDescription != nil else { return }
        let renderer = videoLayer.sampleBufferRenderer
        let failed = name == AVSampleBufferVideoRenderer.didFailToDecodeNotification
            || renderer.status == .failed || renderer.requiresFlushToResumeDecoding
        // A failure while already waiting for a keyframe is the same episode.
        guard failed, !needsKeyframe else { return }
        reportDecodeFailure()
    }

    // MARK: JPEG

    /// Decodes one JPEG at a time; while one decodes, only the newest waiting frame is kept.
    func showJPEG(_ frame: SimulatorJPEGFrame) {
        guard codec == .jpeg else { return }
        if isDecodingJPEG {
            pendingJPEG = frame
            return
        }
        decodeJPEG(frame)
    }

    private func decodeJPEG(_ frame: SimulatorJPEGFrame) {
        isDecodingJPEG = true
        let generation = jpegGeneration
        Task { [weak self] in
            let image = await SimulatorJPEGDecoder.decode(frame.data)
            guard let self, generation == self.jpegGeneration else { return }
            if let image, self.codec == .jpeg {
                self.withoutAnimation { self.imageLayer.contents = image }
                self.onEvent?(.frameShown)
            }
            self.isDecodingJPEG = false
            if let next = self.pendingJPEG {
                self.pendingJPEG = nil
                self.decodeJPEG(next)
            }
        }
    }

    private func cancelJPEGWork() {
        jpegGeneration += 1
        isDecodingJPEG = false
        pendingJPEG = nil
    }

    // MARK: Layout

    private func relayout() {
        displayRect = SimulatorInputMath.aspectFitRect(for: contentPixelSize, in: hostBounds)
        withoutAnimation {
            // AppKit keeps a flipped view's layer geometry top-left too, so the same rect works.
            layer.frame = displayRect
            videoLayer.frame = layer.bounds
            imageLayer.frame = layer.bounds
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
