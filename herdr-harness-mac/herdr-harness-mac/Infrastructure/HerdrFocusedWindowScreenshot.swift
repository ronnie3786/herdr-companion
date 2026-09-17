import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum HerdrFocusedWindowScreenshotError: LocalizedError, Equatable {
    case permissionRequired
    case noFocusedApplication
    case noFocusedWindow
    case captureFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Open Herdr Settings → Screen & System Audio Recording → Request Access/Open System Settings, allow Herdr, then quit and reopen it."
        case .noFocusedApplication:
            "Herdr couldn’t identify the app in front. Bring its window forward and try again."
        case .noFocusedWindow:
            "Herdr couldn’t find a visible app window to capture. Bring the window forward and try again."
        case .captureFailed:
            "Herdr couldn’t capture that window. Make sure it is still visible and try again."
        case .encodingFailed:
            "Herdr captured the window but couldn’t save the PNG. Try again."
        }
    }
}

struct HerdrFocusedWindowTarget: Equatable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
}

struct HerdrWindowCandidate: Equatable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

@MainActor
enum HerdrFocusedWindowScreenshot {
    static func prepare(
        processID: pid_t?,
        permissionCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) throws -> HerdrFocusedWindowTarget {
        guard permissionCheck() else {
            throw HerdrFocusedWindowScreenshotError.permissionRequired
        }
        return try target(processID: processID, candidates: currentWindowCandidates())
    }

    static func target(
        processID: pid_t?,
        candidates: [HerdrWindowCandidate]
    ) throws -> HerdrFocusedWindowTarget {
        guard let processID else {
            throw HerdrFocusedWindowScreenshotError.noFocusedApplication
        }
        guard let window = candidates.first(where: {
            $0.processID == processID
                && $0.layer == 0
                && $0.alpha > 0
                && $0.bounds.width >= 64
                && $0.bounds.height >= 64
        }) else {
            throw HerdrFocusedWindowScreenshotError.noFocusedWindow
        }
        return HerdrFocusedWindowTarget(processID: processID, windowID: window.windowID)
    }

    static func capture(
        target: HerdrFocusedWindowTarget,
        permissionCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) async throws -> URL {
        guard permissionCheck() else {
            throw HerdrFocusedWindowScreenshotError.permissionRequired
        }
        try Task.checkCancellation()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HerdrFocusedWindowScreenshotError.captureFailed
        }
        try Task.checkCancellation()
        guard let window = content.windows.first(where: {
            $0.windowID == target.windowID
                && $0.owningApplication?.processID == target.processID
        }) else {
            throw HerdrFocusedWindowScreenshotError.noFocusedWindow
        }

        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = false
        configuration.includeChildWindows = true
        configuration.dynamicRange = .sdr
        let output: SCScreenshotOutput
        do {
            output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HerdrFocusedWindowScreenshotError.captureFailed
        }
        try Task.checkCancellation()
        guard let image = output.sdrImage else {
            throw HerdrFocusedWindowScreenshotError.captureFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrFocusedWindowCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "Focused Window \(timestamp()) \(UUID().uuidString.prefix(8)).png"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HerdrFocusedWindowScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw HerdrFocusedWindowScreenshotError.encodingFailed
        }
        return url
    }

    private static func currentWindowCandidates() -> [HerdrWindowCandidate] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return rawWindows.compactMap { window in
            guard let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            return HerdrWindowCandidate(
                processID: processID,
                windowID: windowID,
                layer: layer,
                alpha: (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
