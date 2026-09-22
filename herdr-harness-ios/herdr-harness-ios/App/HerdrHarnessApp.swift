import Foundation
import SwiftUI

@main
struct HerdrHarnessApp: App {
    @UIApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @AppStorage("herdr.firstMate.appearance") private var firstMateAppearance = FirstMateAppearance.system
    @State private var model = HerdrAppModel()
    @State private var herdPulse = HerdPulseCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-HerdrPiOptionsFixture") {
                    PiOptionsUITestFixtureView()
                } else {
                    AppRootView(model: model)
                }
                #else
                AppRootView(model: model)
                #endif
            }
            .environment(herdPulse)
            .preferredColorScheme(model.selectedTab == .firstMate ? firstMateAppearance.colorScheme : .dark)
            .tint(HerdrTheme.accent)
        }
    }
}
