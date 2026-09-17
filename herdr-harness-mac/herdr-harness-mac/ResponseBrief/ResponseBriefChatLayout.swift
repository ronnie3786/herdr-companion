import SwiftUI

struct ResponseBriefChatLayout<Content: View>: View {
    @Bindable var coordinator: ResponseBriefCoordinator
    let transport: ResponseBriefTransport
    let chat: ResponseBriefChatIdentity?
    let latestSource: ResponseBriefSource?
    let content: Content
    @State private var showsWideRail: Bool
    @State private var showsRailSheet = false

    private let railWidth = 400.0
    private let wideThreshold = HerdrTheme.readingWidth + 56 + 400 + 20

    init(
        coordinator: ResponseBriefCoordinator,
        transport: ResponseBriefTransport,
        chat: ResponseBriefChatIdentity?,
        latestSource: ResponseBriefSource?,
        initiallyShowsRail: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        self.transport = transport
        self.chat = chat
        self.latestSource = latestSource
        self.content = content()
        _showsWideRail = State(initialValue: initiallyShowsRail)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ResponseBriefVisibilityBar(
                    isWide: proxy.size.width >= wideThreshold,
                    showsWideRail: $showsWideRail,
                    openSheet: openSheet
                )
                Divider().overlay(HerdrTheme.separator)

                if proxy.size.width >= wideThreshold, showsWideRail {
                    HStack(spacing: 0) {
                        content
                            .frame(width: HerdrTheme.readingWidth + 56)
                        Divider().overlay(HerdrTheme.separator)
                        rail(close: nil)
                            .frame(width: railWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    content
                }
            }
        }
        .sheet(isPresented: $showsRailSheet) {
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

    private func openSheet() {
        showsRailSheet = true
    }

    private func closeSheet() {
        showsRailSheet = false
    }
}

private struct ResponseBriefVisibilityBar: View {
    let isWide: Bool
    @Binding var showsWideRail: Bool
    let openSheet: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isWide {
                Button(
                    showsWideRail ? "Hide brief" : "Show brief",
                    systemImage: "sidebar.right"
                ) {
                    showsWideRail.toggle()
                }
                .accessibilityHint(showsWideRail ? "Hides the response brief rail" : "Shows the response brief rail without narrowing the reading column")
            } else {
                Button("Open brief", systemImage: "sidebar.right", action: openSheet)
                    .help("The reading rail needs a wider window; open it as a sheet")
                    .accessibilityHint("Opens the response brief without narrowing the chat column")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.mist)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(HerdrTheme.ink)
        .accessibilityIdentifier("response-brief-visibility-bar")
    }
}
