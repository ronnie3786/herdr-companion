import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox
@testable import herdr_harness_mac

/// Encodes synthetic frames with VideoToolbox the way SimPortal's helper does,
/// so the parser and sample builder are checked against real encoder output.
enum SimulatorTestH264Encoder {
    struct Output: Sendable {
        var avcC: Data?
        var bytes: Data
        var isKeyframe: Bool
        var width: Int32
        var height: Int32
    }

    static let width = 64
    static let height = 128

    static var isAvailable: Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    static func encode(frameCount: Int) throws -> [Output] {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        let session = try #require(created, "VTCompressionSessionCreate failed (\(status))")
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)

        let outputs = Mutex<[Output]>([])
        for index in 0..<frameCount {
            let pixels = try pixelBuffer(shade: UInt8(40 + index * 60))
            let properties = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                duration: .invalid, frameProperties: properties, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let format = sample.formatDescription else { return }
                let atoms = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
                let notSync = sample.sampleAttachments.first?[.notSync] as? Bool ?? false
                let bytes = (try? sample.dataBuffer?.dataBytes()) ?? Data()
                let dimensions = format.dimensions
                outputs.withLock {
                    $0.append(Output(avcC: atoms?["avcC"] as? Data, bytes: bytes, isKeyframe: !notSync,
                                     width: dimensions.width, height: dimensions.height))
                }
            }
            #expect(encodeStatus == noErr)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return outputs.withLock { $0 }
    }

    private static func pixelBuffer(shade: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = base + row * rowBytes + column * 4
                // A gradient, so the encoder has something to encode.
                pixel[0] = UInt8(truncatingIfNeeded: column * 4)
                pixel[1] = UInt8(truncatingIfNeeded: row * 2)
                pixel[2] = shade
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// Decodes one sample with VideoToolbox; the decoded image's size.
    static func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription) throws -> (width: Int, height: Int)? {
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &created)
        let session = try #require(created, "VTDecompressionSessionCreate failed (\(status))")
        defer { VTDecompressionSessionInvalidate(session) }
        let size = Mutex<(width: Int, height: Int)?>(nil)
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            guard status == noErr, let image else { return }
            let decoded = (width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            size.withLock { $0 = decoded }
        }
        #expect(decodeStatus == noErr)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return size.withLock { $0 }
    }
}

@Suite("Simulator H.264 round trip")
struct SimulatorH264RoundTripTests {
    @Test("Real encoder output survives SimPortal's framing, the parser and the sample builder, and decodes",
          .enabled(if: SimulatorTestH264Encoder.isAvailable, "VideoToolbox cannot encode H.264 here"))
    func roundTrip() throws {
        let outputs = try SimulatorTestH264Encoder.encode(frameCount: 3)
        try #require(outputs.count == 3, "The encoder produced \(outputs.count) of 3 frames")
        let avcC = try #require(outputs[0].avcC, "The encoder's format has no avcC atom")
        #expect(outputs[0].isKeyframe)

        // Wire messages exactly as SimPortal frames them.
        let configWire = SimulatorWire.config(width: Int(outputs[0].width), height: Int(outputs[0].height), avcC: avcC)
        guard case .h264Config(let config)? = try SimulatorBinaryMessage.parse(configWire) else {
            Issue.record("The configuration did not parse")
            return
        }
        #expect(config.codec == SimulatorWire.codecString(for: avcC))
        #expect(config.codec.hasPrefix("avc1."))
        #expect(config.width == SimulatorTestH264Encoder.width && config.height == SimulatorTestH264Encoder.height)
        #expect(config.avcC == avcC)

        var frames: [SimulatorH264Frame] = []
        for (index, output) in outputs.enumerated() {
            let wire = SimulatorWire.frame(keyframe: output.isKeyframe, timestampUs: UInt64(1_000_000 + index * 16_667), data: output.bytes)
            guard case .h264Frame(let frame)? = try SimulatorBinaryMessage.parse(wire) else {
                Issue.record("Frame \(index) did not parse")
                return
            }
            #expect(frame.isKeyframe == output.isKeyframe)
            #expect(frame.data == output.bytes)
            #expect(frame.isWellFormed(nalLengthSize: config.nalLengthSize))
            frames.append(frame)
        }

        let format = try SimulatorH264SampleBuilder.formatDescription(for: config)
        #expect(format.mediaSubType == .h264)
        #expect(format.dimensions.width == 64 && format.dimensions.height == 128)

        let keySample = try SimulatorH264SampleBuilder.sampleBuffer(for: frames[0], format: format, nalLengthSize: config.nalLengthSize)
        let keyFormat = try #require(keySample.formatDescription)
        #expect(keyFormat.dimensions.width == 64 && keyFormat.dimensions.height == 128)
        #expect(keySample.presentationTimeStamp == CMTime(value: 1_000_000, timescale: 1_000_000))
        #expect(keySample.sampleAttachments[0][.displayImmediately] as? Bool == true)
        #expect(keySample.sampleAttachments[0][.notSync] == nil)

        let decoded = try SimulatorTestH264Encoder.decode(keySample, format: format)
        #expect(decoded?.width == 64 && decoded?.height == 128, "The keyframe did not decode: \(String(describing: decoded))")

        if let delta = frames.dropFirst().first(where: { !$0.isKeyframe }) {
            let deltaSample = try SimulatorH264SampleBuilder.sampleBuffer(for: delta, format: format, nalLengthSize: config.nalLengthSize)
            #expect(deltaSample.sampleAttachments[0][.notSync] as? Bool == true)
        }
    }

    @Test("The renderer takes the configuration, asks for a keyframe and shows real frames",
          .enabled(if: SimulatorTestH264Encoder.isAvailable, "VideoToolbox cannot encode H.264 here"))
    @MainActor
    func rendererAcceptsEncoderOutput() throws {
        let outputs = try SimulatorTestH264Encoder.encode(frameCount: 3)
        try #require(outputs.count == 3)
        let avcC = try #require(outputs[0].avcC)
        let renderer = SimulatorVideoRenderer()
        var events: [SimulatorVideoRenderer.Event] = []
        renderer.onEvent = { events.append($0) }

        guard case .h264Config(let config)? = try SimulatorBinaryMessage.parse(
            SimulatorWire.config(width: 64, height: 128, avcC: avcC)) else {
            Issue.record("The configuration did not parse")
            return
        }
        renderer.configure(config)
        #expect(events == [.needsKeyframe])
        #expect(renderer.needsKeyframe)

        // A delta frame before any keyframe is dropped.
        if let delta = outputs.dropFirst().first(where: { !$0.isKeyframe }) {
            renderer.enqueue(SimulatorH264Frame(isKeyframe: false, timestampUs: 1, data: delta.bytes))
            #expect(events == [.needsKeyframe])
        }
        for (index, output) in outputs.enumerated() {
            renderer.enqueue(SimulatorH264Frame(isKeyframe: output.isKeyframe, timestampUs: UInt64(index), data: output.bytes))
        }
        #expect(events.filter { $0 == .frameShown }.count == 3)
        #expect(!events.contains(.decodeFailed))
        #expect(!renderer.needsKeyframe)

        // The same configuration again changes nothing; a new one resets the decoder.
        renderer.configure(config)
        #expect(!renderer.needsKeyframe)
        var resized = config
        resized.width = 32
        renderer.configure(resized)
        #expect(renderer.needsKeyframe)
        #expect(events.last == .needsKeyframe)
    }
}
