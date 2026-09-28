import SwiftUI

extension EnvironmentValues {
    /// Marks a First Mate chat read through a First Mate message:
    /// `(featureID, messageID)`. `FirstMateChatView` calls it while it is in
    /// the key window and scrolled to the newest message; the host binds it to
    /// its machine. Nil (the default, and in renders) does nothing.
    @Entry var firstMateMarkRead: (@MainActor (_ featureID: String, _ messageID: String) -> Void)? = nil
}
