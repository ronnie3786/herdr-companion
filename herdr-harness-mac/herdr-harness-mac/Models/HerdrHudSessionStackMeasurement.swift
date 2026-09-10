import CoreGraphics

struct HerdrHudSessionStackMeasurement: Equatable {
    let height: CGFloat
    let chipCount: Int
    let overflow: Int
    let fontScale: Double

    func matches(chipCount: Int, overflow: Int, fontScale: Double) -> Bool {
        self.chipCount == chipCount && self.overflow == overflow && self.fontScale == fontScale
    }
}
