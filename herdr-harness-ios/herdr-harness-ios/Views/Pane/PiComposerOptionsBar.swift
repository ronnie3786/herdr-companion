import SwiftUI

struct PiComposerOptionsBar: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PiComposerOptionsContent(
            configuration: configuration,
            responseAudioPlayer: responseAudioPlayer,
            activateResponseAudio: activateResponseAudio,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }
}
