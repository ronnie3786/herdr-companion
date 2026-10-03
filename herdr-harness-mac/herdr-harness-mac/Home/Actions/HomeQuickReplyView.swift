import SwiftUI

extension EnvironmentValues {
    @Entry var homeQuickReplyController: HomeQuickReplyController? = nil
}

/// Options come only from hydrated conversation evidence. Open remains in
/// the owning card for unsupported sources and pending permission prompts.
struct HomeQuickReplyView: View {
    var route: HomeRoute
    var compact = false
    @Environment(\.homeQuickReplyController) private var controller

    var body: some View {
        if let controller, let presentation = controller.presentations[route] {
            VStack(alignment: .leading, spacing: 7) {
                if let question = presentation.question, presentation.phase == .ready {
                    HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(presentation.actions) { action in
                            Button {
                                Task { await controller.send(action, to: route, question: question) }
                            } label: {
                                Text(action.displayLabel).herdrFont(size: compact ? 12 : 13, weight: .semibold)
                                    .foregroundStyle(HomePalette.accent)
                                    .padding(.horizontal, 10).frame(minHeight: compact ? 28 : 32)
                            }
                            .buttonStyle(HomeButtonStyle(fill: HomePalette.accentWash, border: HomePalette.accentLine))
                            .help(action.explanation)
                            .accessibilityHint(action.explanation)
                            .accessibilityIdentifier("home.quick-reply.\(action.id)")
                        }
                    }
                }
                if let message = presentation.phase.message {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message).herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if presentation.phase.canRetry {
                            Button("Retry reply") { Task { await controller.retry(route: route) } }
                                .herdrFont(size: 12, weight: .semibold).foregroundStyle(HomePalette.accent)
                                .buttonStyle(HomeButtonStyle())
                                .disabled(!controller.canRetry(route: route))
                                .accessibilityIdentifier("home.quick-reply.retry")
                        }
                    }
                }
            }
            .padding(.leading, compact ? 17 : 0)
            .padding(.top, compact ? 8 : 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reply options")
        }
    }
}
