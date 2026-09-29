import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

extension FirstMateLeadBriefingTests {
    @Test("The sidebar subtitle agrees in number")
    func sidebarSubtitle() {
        #expect(FirstMateChatSidebar.subtitle(featureCount: 1, needCount: 1) == "1 feature, 1 needs you")
        #expect(FirstMateChatSidebar.subtitle(featureCount: 7, needCount: 3) == "7 features, 3 need you")
        #expect(FirstMateChatSidebar.subtitle(featureCount: 7, needCount: 0) == "7 features, 0 need you")
    }
}
