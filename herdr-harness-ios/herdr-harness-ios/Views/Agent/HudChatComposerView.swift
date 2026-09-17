import SwiftUI

struct HudChatComposerView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: HudChatStore
    @Binding var thinkingLevel: PiThinkingLevel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.isNewChat {
                        folderControls
                    }

                    adaptiveMenuControls

                    TextField("Message this saved HUD chat…", text: $store.draft, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.body)
                        .foregroundStyle(HerdrTheme.text)
                        .focused($isPromptFocused)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        .padding(12)
                        .frame(minHeight: 44)
                        .background(HerdrTheme.input)
                        .overlay {
                            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                                .strokeBorder(isPromptFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
                        }
                        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                        .disabled(store.hasActiveRun || store.isSubmitting || store.isStopping)
                        .accessibilityIdentifier("hud-chat-prompt")
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.visible)
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: store.isNewChat ? 300 : 190)
            .accessibilityIdentifier("hud-chat-composer-scroll")

            Divider()
                .overlay(HerdrTheme.surface)

            primaryAction
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 10)
        }
        .background(HerdrTheme.graphite)
        .onAppear { isPromptFocused = store.isNewChat }
    }

    @ViewBuilder
    private var adaptiveMenuControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                modelMenu
                thinkingMenu
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    modelMenu
                    thinkingMenu
                }
                VStack(spacing: 8) {
                    modelMenu
                    thinkingMenu
                }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if store.hasActiveRun {
            Button(role: .destructive) {
                Task { await store.stop(transport: model) }
            } label: {
                Label(store.isStopping ? "Stopping…" : "Stop latest run", systemImage: "stop.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(HerdrTheme.alert)
            .disabled(store.isStopping)
            .accessibilityIdentifier("hud-chat-stop")
        } else {
            Button(action: submit) {
                Label(store.isSubmitting ? "Sending…" : "Send", systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .disabled(!store.canSubmit)
            .accessibilityIdentifier("hud-chat-send")
        }
    }

    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RUN ON THE MACHINE IN")
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(HerdrTheme.muted)

            adaptiveFolderButtons

            if store.usesCustomWorkingDirectory {
                TextField("/absolute/path/on/this/machine", text: $store.newWorkingDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(12)
                    .frame(minHeight: 44)
                    .background(HerdrTheme.input)
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                    .accessibilityLabel("Custom working directory on the selected machine")
                    .accessibilityIdentifier("hud-chat-cwd")

                Text(store.capabilities?.hudChatWorkingDirectory == true
                    ? "The server validates this opaque machine path. iOS does not expand or create it."
                    : "This machine needs a Companion server update before custom folders can be sent.")
                    .font(.subheadline)
                    .foregroundStyle(store.capabilities?.hudChatWorkingDirectory == true ? HerdrTheme.muted : HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var adaptiveFolderButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                homeButton
                customPathButton
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    homeButton
                    customPathButton
                }
                VStack(spacing: 8) {
                    homeButton
                    customPathButton
                }
            }
        }
    }

    private var homeButton: some View {
        Button {
            store.usesCustomWorkingDirectory = false
        } label: {
            Label("Home (~)", systemImage: store.usesCustomWorkingDirectory ? "house" : "checkmark.circle.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("hud-chat-home-folder")
    }

    private var customPathButton: some View {
        Button {
            store.usesCustomWorkingDirectory = true
        } label: {
            Label("Custom path", systemImage: store.usesCustomWorkingDirectory ? "checkmark.circle.fill" : "folder")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("hud-chat-custom-folder")
    }

    private var modelMenu: some View {
        Menu {
            Button {
                model.setAgentModel("")
            } label: {
                Label("Machine default", systemImage: model.agentModel.isEmpty ? "checkmark.circle.fill" : "cpu")
            }
            ForEach(modelProviders, id: \.self) { provider in
                Section(provider) {
                    ForEach(modelsByProvider[provider] ?? []) { candidate in
                        Button {
                            model.setAgentModel(candidate.id)
                        } label: {
                            Label(
                                candidate.displayName,
                                systemImage: model.agentModel == candidate.id ? "checkmark.circle.fill" : "cpu"
                            )
                        }
                    }
                }
            }
        } label: {
            Label(modelLabel, systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.accent)
        .disabled(store.hasActiveRun || store.isSubmitting)
        .accessibilityLabel("Model: \(modelLabel)")
        .accessibilityIdentifier("hud-chat-model")
    }

    private var thinkingMenu: some View {
        Menu {
            ForEach(PiThinkingLevel.allCases, id: \.self) { level in
                Button {
                    thinkingLevel = level
                } label: {
                    Label(level.displayName, systemImage: thinkingLevel == level ? "checkmark.circle.fill" : "brain")
                }
            }
        } label: {
            Label(thinkingLevel.displayName, systemImage: "brain")
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.accent)
        .disabled(store.hasActiveRun || store.isSubmitting)
        .accessibilityLabel("Thinking: \(thinkingLevel.displayName)")
        .accessibilityIdentifier("hud-chat-thinking")
    }

    private var modelsByProvider: [String: [PiAvailableModel]] {
        Dictionary(grouping: store.modelCatalog?.models ?? [], by: \.provider)
    }

    private var modelProviders: [String] {
        modelsByProvider.keys.sorted()
    }

    private var modelLabel: String {
        if !model.agentModel.isEmpty {
            return store.modelCatalog?.models.first(where: { $0.id == model.agentModel })?.displayName
                ?? model.agentModel
        }
        return store.modelCatalog?.defaultModel?.displayName ?? "Machine default"
    }

    private func submit() {
        guard store.canSubmit else { return }
        isPromptFocused = false
        Task {
            await store.submit(
                model: model.agentModel.isEmpty ? nil : model.agentModel,
                thinkingLevel: thinkingLevel.rawValue,
                transport: model
            )
        }
    }
}
