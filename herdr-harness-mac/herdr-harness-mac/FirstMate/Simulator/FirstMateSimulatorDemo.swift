import SwiftUI

/// Synthetic simulator checkpoints for demo mode and renders. Nothing here
/// contacts a companion or SimPortal.
enum FirstMateSimulatorDemo {
    static let startSteps = FirstMateSimulatorStepText.startSteps

    static let device = FirstMateSimulatorDevice(
        deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        deviceTypeName: "iPhone 17 Pro", runtimeName: "iOS 26.2")

    static let status = FirstMateSimulatorStatus(
        configured: true, state: "ready", registrationAvailable: true, previewAvailable: true,
        defaultDevice: device, policy: .init(idleShutdownMinutes: 60, maxRunningPreviews: 4), runningPreviews: 1)

    /// Two rounds of implementation and one review fix, attached to the
    /// feature's second and third stages when it has them.
    static func builds(featureID: String, visitIDs: [String]) -> [FirstMateSimulatorBuild] {
        let implementation = visitIDs.count > 1 ? visitIDs[1] : visitIDs.first
        let review = visitIDs.count > 2 ? visitIDs[2] : implementation
        let app = { (build: String) in
            FirstMateSimulatorBuild.App(name: "Receipts", bundleID: "com.example.receipts", version: "1.4", build: build, minimumOS: "18.0")
        }
        let source = FirstMateSimulatorBuild.Source(revision: "4f1c2d9e7b3a5c6d8e9f0a1b2c3d4e5f6a7b8c9d", workingTree: "clean",
                                                    configuration: "Debug", target: "Receipts")
        let running = FirstMateSimulatorPreview(
            id: "fmsp_demo0000000000000000000000000001", featureID: featureID, buildID: "demo-build-3",
            phase: "running", status: "ready", device: device)
        return [
            .init(id: "demo-build-3", featureID: featureID, name: "Receipts · Review fixes", checkpointID: "demo-review",
                  checkpointLabel: "Review fixes: export sheet", stageTitle: "Review", visitID: review,
                  assignmentID: "\(featureID)-crew-3", status: "ready", app: app("214"), source: source, launchable: true,
                  createdAt: timestamp(minutesAgo: 18), previews: [running]),
            .init(id: "demo-build-2", featureID: featureID, name: "Receipts · Round 2", checkpointID: "demo-round-2",
                  checkpointLabel: "Round 2: export sheet", stageTitle: "Implementation", visitID: implementation,
                  assignmentID: "\(featureID)-crew-2", status: "ready", app: app("213"), source: source, launchable: true,
                  createdAt: timestamp(minutesAgo: 95)),
            .init(id: "demo-build-1", featureID: featureID, name: "Receipts · Round 1", checkpointID: "demo-round-1",
                  checkpointLabel: "Round 1: receipt capture", stageTitle: "Implementation", visitID: implementation,
                  assignmentID: "\(featureID)-crew-1", status: "ready", app: app("212"), source: source, launchable: true,
                  createdAt: timestamp(minutesAgo: 190)),
        ]
    }

    static func preview(featureID: String, buildID: String, startingAt step: String? = nil) -> FirstMateSimulatorPreview {
        let current = step.flatMap { startSteps.firstIndex(of: $0) }
        let steps = startSteps.enumerated().map { index, name in
            let state = current.map { index < $0 ? "succeeded" : index == $0 ? "running" : "pending" } ?? "succeeded"
            return FirstMateSimulatorPreview.Step(name: name, state: state)
        }
        let udid = "00000000-0000-4000-8000-00000000D3E0"
        return FirstMateSimulatorPreview(
            id: "fmsp_demo0000000000000000000000000001", featureID: featureID, buildID: buildID,
            phase: current == nil ? "running" : "starting", status: step ?? "ready", device: device, udid: udid,
            // The picture appears once iOS has booted, while the app installs.
            streamAvailable: current.map { $0 >= 4 } ?? true,
            operation: .init(id: "demo-operation", kind: "start", status: current == nil ? "succeeded" : "running",
                             step: step ?? "checking_stream", steps: steps, error: nil),
            observation: .init(deviceState: "Booted", viewerCount: 1),
            browserLinks: .init(local: nil, tailnet: URL(string: "https://simportal.example.invalid:8531/d/\(udid)")),
            idle: .init(shutdownAfterMinutes: 60, shutdownAt: nil, watchers: 1))
    }

    /// The same preview after its simulator was deleted on SimPortal's Machines page.
    static func deletedPreview(featureID: String, buildID: String) -> FirstMateSimulatorPreview {
        FirstMateSimulatorPreview(
            id: "fmsp_demo0000000000000000000000000001", featureID: featureID, buildID: buildID,
            phase: "stopped", status: "simulator_deleted", device: device, stopReason: "idle",
            udid: "00000000-0000-4000-8000-00000000D3E0",
            idle: .init(shutdownAfterMinutes: 60, shutdownAt: nil, watchers: 0))
    }

    private static func timestamp(minutesAgo: Int) -> String {
        HerdrTimestamp.string(from: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60))
    }

    /// A synthetic app screen standing in for the live picture.
    @MainActor static func screenImage() -> CGImage? {
        let renderer = ImageRenderer(content: FirstMateSimulatorDemoScreen().frame(width: 402, height: 874))
        renderer.scale = 2
        return renderer.cgImage
    }
}

/// A plain iOS-style list app, drawn once for demo mode.
private struct FirstMateSimulatorDemoScreen: View {
    private let receipts: [(String, String, String)] = [
        ("Blue Bottle Coffee", "Today · Meals", "$6.25"),
        ("Hotel Emma", "Sep 27 · Lodging", "$412.80"),
        ("Lyft", "Sep 27 · Travel", "$38.10"),
        ("Office Depot", "Sep 24 · Supplies", "$84.97"),
        ("Southwest Airlines", "Sep 22 · Travel", "$286.40"),
        ("Sweetgreen", "Sep 22 · Meals", "$14.50"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("9:41").font(.system(size: 17, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .frame(height: 62)
            Text("Receipts")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer()
            }
            .font(.system(size: 17))
            .foregroundStyle(Color(white: 0.55))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(white: 0.93), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            VStack(spacing: 0) {
                ForEach(receipts.indices, id: \.self) { index in
                    let receipt = receipts[index]
                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hue: Double(index) / 7, saturation: 0.35, brightness: 0.95))
                            .frame(width: 40, height: 40)
                            .overlay { Image(systemName: "doc.text").foregroundStyle(.white) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receipt.0).font(.system(size: 17))
                            Text(receipt.1).font(.system(size: 13)).foregroundStyle(Color(white: 0.5))
                        }
                        Spacer()
                        Text(receipt.2).font(.system(size: 17, weight: .medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                    if index < receipts.count - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .background(.white, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            Spacer()
            Text("Export 6 receipts")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.0, green: 0.48, blue: 1.0), in: .rect(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 44)
        }
        .foregroundStyle(.black)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)
    }
}
