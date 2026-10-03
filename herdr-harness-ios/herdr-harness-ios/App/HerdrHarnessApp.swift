import Foundation
import SwiftUI

@main
struct HerdrHarnessApp: App {
    @UIApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var model = HerdrAppModel()
    @State private var herdPulse = HerdPulseCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-HerdrThemeDuskSample") {
                    HerdrThemeSampleView()
                } else if ProcessInfo.processInfo.arguments.contains("-HerdrSimulatorInputFixture") {
                    SimulatorInputUITestFixtureView()
                } else if ProcessInfo.processInfo.arguments.contains("-HerdrPiOptionsFixture") {
                    PiOptionsUITestFixtureView()
                } else {
                    AppRootView(model: model)
                }
                #else
                AppRootView(model: model)
                #endif
            }
            .environment(herdPulse)
            .preferredColorScheme(.dark)
            .tint(HerdrTheme.accent)
        }
    }
}
