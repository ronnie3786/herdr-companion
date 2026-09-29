import SwiftUI
import UIKit

/// A hidden SwiftUI navigation bar must not remove the native edge gesture.
/// Own only this visible controller's gesture grant and restore its delegate.
struct FirstMateInteractiveBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { }
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        private weak var priorDelegate: (any UIGestureRecognizerDelegate)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            self.gesture = gesture
            priorDelegate = gesture.delegate
            gesture.delegate = self
            gesture.isEnabled = true
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if gesture?.delegate === self { gesture?.delegate = priorDelegate }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1 && navigationController.transitionCoordinator == nil
        }
    }
}
