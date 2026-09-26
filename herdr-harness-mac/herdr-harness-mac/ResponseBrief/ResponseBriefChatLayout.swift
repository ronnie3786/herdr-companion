import SwiftUI

/// Whether the response brief shows as a rail beside the chat or as a sheet.
/// Owned by the pane so the brief's toggle can live in the window title bar;
/// the layout reports whether the pane is wide enough for the rail.
@Observable
@MainActor
final class ResponseBriefPresentation {
    var showsWideRail: Bool
    var showsRailSheet = false
    var isWide = false

    init(showsWideRail: Bool = false) {
        self.showsWideRail = showsWideRail
    }

    func toggle() {
        if isWide {
            showsWideRail.toggle()
        } else {
            showsRailSheet = true
        }
    }

    var title: String {
        guard isWide else { return "Open brief" }
        return showsWideRail ? "Hide brief" : "Show brief"
    }
}

/// The brief's title-bar control: MonoCode's 26pt icon button.
struct ResponseBriefToggleButton: View {
    let presentation: ResponseBriefPresentation

    var body: some View {
        Button(presentation.title, systemImage: "sidebar.right") {
            presentation.toggle()
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: presentation.isWide && presentation.showsWideRail))
        .help(presentation.isWide ? presentation.title : "The reading rail needs a wider window; open it as a sheet")
        .accessibilityHint(presentation.isWide
            ? (presentation.showsWideRail ? "Hides the response brief rail" : "Shows the response brief rail without narrowing the reading column")
            : "Opens the response brief without narrowing the chat column")
        .accessibilityIdentifier("response-brief-toggle")
    }
}

struct ResponseBriefChatLayout<Content: View>: View {
    @Bindable var coordinator: ResponseBriefCoordinator
    let transport: ResponseBriefTransport
    let chat: ResponseBriefChatIdentity?
    let latestSource: ResponseBriefSource?
    let content: Content
    /// Nil keeps the standalone strip with its own toggle (render tests and
    /// hosts without a window title bar).
    let externalPresentation: ResponseBriefPresentation?
    @State private var ownPresentation: ResponseBriefPresentation

    private let railWidth = 400.0
    private let columnWidth = HerdrTheme.transcriptWidth + 24
    private var wideThreshold: CGFloat { columnWidth + 400 + 20 }

    init(
        coordinator: ResponseBriefCoordinator,
        transport: ResponseBriefTransport,
        chat: ResponseBriefChatIdentity?,
        latestSource: ResponseBriefSource?,
        initiallyShowsRail: Bool = false,
        presentation: ResponseBriefPresentation? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        self.transport = transport
        self.chat = chat
        self.latestSource = latestSource
        self.content = content()
        externalPresentation = presentation
        _ownPresentation = State(initialValue: ResponseBriefPresentation(showsWideRail: initiallyShowsRail))
    }

    private var presentation: ResponseBriefPresentation {
        externalPresentation ?? ownPresentation
    }

    var body: some View {
        @Bindable var presentation = presentation
        VStack(spacing: 0) {
            if externalPresentation == nil {
                ResponseBriefVisibilityBar(presentation: presentation)
            }

            if presentation.isWide, presentation.showsWideRail {
                HStack(spacing: 0) {
                    content
                        .frame(width: columnWidth)
                    Rectangle()
                        .fill(HerdrTheme.hairline)
                        .frame(width: 1)
                    rail(close: nil)
                        .frame(width: railWidth)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= wideThreshold
        } action: { wide in
            presentation.isWide = wide
        }
        .sheet(isPresented: $presentation.showsRailSheet) {
            rail(close: closeSheet)
                .frame(width: railWidth)
                .frame(minHeight: 640)
        }
    }

    private func rail(close: (() -> Void)?) -> some View {
        ResponseBriefRailView(
            coordinator: coordinator,
            transport: transport,
            chat: chat,
            latestSource: latestSource,
            close: close
        )
    }

    private func closeSheet() {
        presentation.showsRailSheet = false
    }
}

private struct ResponseBriefVisibilityBar: View {
    let presentation: ResponseBriefPresentation

    var body: some View {
        HStack {
            Spacer()
            ResponseBriefToggleButton(presentation: presentation)
        }
        .padding(.horizontal, 8)
        .frame(height: HerdrTheme.ControlHeight.bar)
        .herdrHairline(.bottom)
        .accessibilityIdentifier("response-brief-visibility-bar")
    }
}
