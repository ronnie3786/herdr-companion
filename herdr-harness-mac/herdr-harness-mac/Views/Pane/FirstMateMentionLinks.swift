import SwiftUI

extension EnvironmentValues {
    /// The names `PiMarkdownText` turns into First Mate mention runs. Nil (the
    /// default) leaves every existing chat exactly as it was; only the First
    /// Mate chat window sets it.
    @Entry var firstMateMentionCatalog: FirstMateMentionCatalog? = nil
}
