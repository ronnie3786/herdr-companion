import Darwin
import Foundation
import SwiftUI

/// Diagnostic launches exit before any app model, settings, or scenes initialize.
@main
@MainActor
enum HerdrMacEntryPoint {
    static func main() {
        if let report = HerdrKeychainProbe.runIfRequested(arguments: CommandLine.arguments) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(report) {
                FileHandle.standardOutput.write(data + Data([0x0A]))
            }
            exit(report.ok ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        HerdrHarnessMacApp.main()
    }
}
