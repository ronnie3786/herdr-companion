import CoreGraphics
import CoreVideo
import ImageIO
import Vision

/// Feed Vision a CPU-prepared luminance buffer. Its default PNG/RGB → NV12
/// conversion can return empty OCR after Metal command-buffer failures on a
/// sandboxed/headless test host, even with CPU compute devices selected.
/// Recognition and all rendered-text assertions remain unchanged.
enum HerdrOCR {
    enum Failure: Error { case image, buffer, context }

    static func perform(_ request: VNRecognizeTextRequest, url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.image }
        try perform(request, image: image)
    }

    static func perform(_ request: VNRecognizeTextRequest, image: CGImage) throws {
        let width = (image.width + 1) / 2 * 2
        let height = (image.height + 1) / 2 * 2
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &value) == kCVReturnSuccess,
              let buffer = value else { throw Failure.buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
                  let context = CGContext(data: luma, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw Failure.context }
            // Neutral chroma preserves luminance contrast without a GPU color
            // conversion. OCR tests assert text and positions, not chromaticity.
            chroma.initializeMemory(as: UInt8.self, repeating: 128,
                                    count: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
    }
}
