import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Hosted render coverage for the composer compaction status area. Renders the
/// real `PiCompactionStatusBar` at a narrow iPhone width and an iPad width with
/// default and accessibility Dynamic Type. These are synthetic layout checks,
/// not installed-device smoke tests, and they start no network or Pi work.
@MainActor
final class PiCompactionRenderTests: XCTestCase {
    private let harness = IOSNativeRenderHarness()
    private let widths: [CGFloat] = [320, 834]

    func testCompactionStatusStatesRenderAcrossWidthsAndDynamicType() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-ios-compaction-renders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("HERDR_IOS_COMPACTION_RENDER_DIR=\(directory.path)")

        for width in widths {
            var defaultHeights: [String: CGFloat] = [:]
            for dynamicType in [
                IOSNativeRenderHarness.DynamicTypeFixture.defaultSize,
                .accessibility3,
            ] {
                for state in states {
                    let render = await harness.render(
                        VStack(alignment: .leading, spacing: 10) {
                            PiCompactionStatusBar(presentation: state.presentation)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(HerdrTheme.graphite),
                        width: width,
                        dynamicType: dynamicType
                    )

                    let context = "\(state.name), \(Int(width))pt, \(dynamicType.name)"
                    XCTAssertTrue(render.drewHierarchy, "UIKit must draw the compaction bar: \(context)")
                    XCTAssertGreaterThan(render.fittingSize.height, 0, "Missing height: \(context)")
                    XCTAssertLessThanOrEqual(render.fittingSize.width, width, "Horizontal overflow: \(context)")
                    XCTAssertGreaterThanOrEqual(
                        render.fittingSize.height,
                        44,
                        "Compaction bar collapsed below the touch target: \(context)"
                    )

                    let measured = try XCTUnwrap(
                        render.element(identifier: state.presentation.accessibilityIdentifier),
                        "Missing \(state.presentation.accessibilityIdentifier): \(context)\n\(render.measurementDiagnostics)"
                    )
                    XCTAssertGreaterThanOrEqual(measured.frame.height, 44, "Status row collapsed: \(context)")
                    XCTAssertLessThanOrEqual(
                        measured.frame.maxX,
                        render.bounds.maxX + 0.5,
                        "Status row clips horizontally: \(context)"
                    )
                    XCTAssertGreaterThanOrEqual(measured.frame.minY, render.bounds.minY - 0.5, "Row clips top: \(context)")
                    XCTAssertLessThanOrEqual(measured.frame.maxY, render.bounds.maxY + 0.5, "Row clips bottom: \(context)")
                    XCTAssertNotNil(
                        render.element(label: state.presentation.accessibilityLabel),
                        "Accessibility label is not attached to the rendered row: \(context)"
                    )

                    if dynamicType.name == "default" {
                        defaultHeights[state.name] = render.fittingSize.height
                    } else if let standard = defaultHeights[state.name] {
                        XCTAssertGreaterThanOrEqual(
                            render.fittingSize.height,
                            standard,
                            "Accessibility text must not shrink or clip the row: \(context)"
                        )
                    }

                    let image = try XCTUnwrap(render.image.pngData())
                    XCTAssertGreaterThan(image.count, 512, "Rendered row is blank: \(context)")
                    let filename = "compaction-\(state.name)-\(Int(width))-\(dynamicType.name).png"
                    try image.write(to: directory.appending(path: filename), options: .atomic)
                }
            }
        }
    }

    private var states: [(name: String, presentation: PiCompactionStatusPresentation)] {
        [
            (
                "progress",
                PiCompactionStatusPresentation(
                    kind: .progress,
                    title: "Compacting context after overflow, then retrying…",
                    detail: nil,
                    systemImage: "arrow.triangle.2.circlepath"
                )
            ),
            (
                "completed-idle",
                completionPresentation(
                    completion: completion(reason: .threshold),
                    readiness: PiCompactionReadiness(
                        isConnected: true,
                        phase: .idle,
                        availableDispositions: [.prompt]
                    )
                )
            ),
            (
                "completed-working",
                completionPresentation(
                    completion: completion(reason: .overflow),
                    readiness: PiCompactionReadiness(
                        isConnected: true,
                        phase: .working,
                        availableDispositions: [.steer, .followUp]
                    )
                )
            ),
            (
                "offline",
                completionPresentation(
                    completion: completion(reason: .manual),
                    readiness: PiCompactionReadiness(
                        isConnected: false,
                        phase: .idle,
                        availableDispositions: []
                    )
                )
            ),
        ]
    }

    private func completionPresentation(
        completion: PiCompactionCompletion,
        readiness: PiCompactionReadiness
    ) -> PiCompactionStatusPresentation {
        PiCompactionStatusPresentation.resolve(
            activity: nil,
            completion: completion,
            readiness: readiness
        ) ?? PiCompactionStatusPresentation(
            kind: .progress,
            title: "Missing",
            detail: nil,
            systemImage: "questionmark"
        )
    }

    private func completion(reason: PiCompactionReason) -> PiCompactionCompletion {
        PiCompactionCompletion(
            evidence: .entry("compact-1"),
            reason: reason,
            sessionID: "s1",
            timestamp: nil
        )
    }
}
