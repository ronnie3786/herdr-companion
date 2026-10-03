import UIKit

final class SimulatorInputTouch: UITouch {
    var point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    override func location(in view: UIView?) -> CGPoint { point }
}
