import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Home chat presentation geometry")
struct HomeChatPresentationTests {
    @Test("The Ask bar and tray match the reference at the supported minimum")
    func minimumWindow() {
        let size = CGSize(width: 1000, height: 680)
        #expect(HomeChatPresentationLayout.askWidth(in: size.width) == 448)
        #expect(HomeChatPresentationLayout.traySize(in: size) == CGSize(width: 574, height: 530.4))
    }

    @Test("Large windows cap the tray while narrow containers retain their horizontal insets")
    func constrainedAndLargeWindows() {
        #expect(HomeChatPresentationLayout.traySize(in: CGSize(width: 1600, height: 1000)) == CGSize(width: 574, height: 700))
        #expect(HomeChatPresentationLayout.askWidth(in: 460) == 396)
        #expect(HomeChatPresentationLayout.traySize(in: CGSize(width: 460, height: 600)) == CGSize(width: 412, height: 468))
    }
}
