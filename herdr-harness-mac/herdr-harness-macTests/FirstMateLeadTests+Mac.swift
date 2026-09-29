import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

extension FirstMateLeadTests {
    @Test("A header choice pins the lead's machine until Automatic")
    func pinning() throws {
        let defaults = try #require(UserDefaults(suiteName: "FirstMateLeadTests.\(UUID().uuidString)"))
        FirstMateLeadMachine.pin("devbox", defaults: defaults)
        #expect(FirstMateLeadMachine.pinned(defaults: defaults) == "devbox")
        FirstMateLeadMachine.pin(nil, defaults: defaults)
        #expect(FirstMateLeadMachine.pinned(defaults: defaults) == nil)
    }
}
