import SwiftUI
import UIKit

struct FirstMateConversationsScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let openFeature: (FirstMateFeatureTarget) -> Void
    let openInfo: (FirstMateFeatureTarget) -> Void
    let openLead: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("herdr.firstMate.folder") private var folder: FirstMateListFolder = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSearch = false
    @State private var archiveRequest: FirstMateMobileArchiveRequest?
    @State private var mutationFeedback = FirstMateListMutationFeedback()
    @FocusState private var searchFocused: Bool

    private var presentation: FirstMateMobileListPresentation { FirstMateMobileListPresentation(fleet: fleet) }
    private var leadUnread: Bool {
        fleet.leadChoice.current.map { fleet.chat.leadIsUnread(machineID: $0, fleet: fleet) } ?? false
    }
    private var archived: [FirstMateConversation] { fleet.archivedConversations }

    var body: some View {
        let presentation = presentation
        let rows = presentation.rows.filter(folder.includes)
        ScrollViewReader { proxy in
            List {
                if presentation.showsLead || !presentation.pinned.isEmpty {
                    FirstMatePinnedStrip(presentation: presentation, leadUnread: leadUnread,
                        needsYouCount: fleet.conversations.count { $0.hudStatus.needsYou },
                        orbSize: horizontalSizeClass == .regular ? 62 : verticalSizeClass == .compact ? 64 : 88,
                        columns: horizontalSizeClass == .regular ? 4 : nil,
                        openLead: openLead, openFeature: openFeature, openInfo: openInfo,
                        archive: presentArchive, canArchive: canArchive,
                        revealOverflow: { id in withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id, anchor: .top) } })
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if !presentation.rows.isEmpty {
                    FirstMateFolderChips(folder: $folder, rows: presentation.rows)
                        .padding(.bottom, 6)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(fleet.visibleHosts.filter { $0.error != nil || $0.unsupported }) { host in
                    Label(host.unsupported ? "\(host.machineName) needs a companion update" : "Updates paused for \(host.machineName)",
                          systemImage: host.unsupported ? "arrow.down.circle" : "wifi.exclamationmark")
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if let mutationError = mutationFeedback.message(in: fleet) {
                    Text(mutationError).herdrFont(.body).foregroundStyle(HerdrTheme.warning)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if presentation.rows.isEmpty, archived.isEmpty {
                    if fleet.visibleHosts.contains(where: \.isLoading) && !fleet.visibleHosts.contains(where: \.hasLoaded) {
                        ProgressView("Loading conversations…").frame(maxWidth: .infinity, minHeight: 100)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else if let message = presentation.emptyMessage {
                        Text(message).herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 24)
                            .accessibilityIdentifier("first-mate-chat-empty")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                if rows.isEmpty, !presentation.rows.isEmpty {
                    Text(folder.emptyMessage).herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.vertical, 18).padding(.horizontal, 4)
                        .accessibilityIdentifier("first-mate-folder-empty")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    conversationRow(row)
                }
                if fleet.showArchived, !archived.isEmpty {
                    Section {
                        ForEach(archived) { row in conversationRow(row) }
                    } header: {
                        HerdrMicroLabel(text: "Archived", count: archived.count)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await fleet.refreshAll() }
            .herdrEdgeFade(.top)
            .accessibilityIdentifier("first-mate-feature-list")
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    FirstMateConversationsBar(model: model, fleet: fleet, showsSearch: $showsSearch)
                    if showsSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(HerdrTheme.iconTint).accessibilityHidden(true)
                            TextField("", text: $fleet.search, prompt: Text("Search conversations").foregroundStyle(HerdrTheme.tertiaryText))
                                .herdrFont(.body).foregroundStyle(HerdrTheme.primaryText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.search)
                                .focused($searchFocused)
                                .accessibilityIdentifier("first-mate-chat-search")
                            if !fleet.search.isEmpty {
                                Button { fleet.search = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(HerdrTheme.iconTint)
                                        .frame(width: 32, height: 44).contentShape(.rect)
                                }.buttonStyle(.herdrPlain).accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .herdrControlGlass(in: .capsule, interactive: false)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground).ignoresSafeArea() }
        .herdrFirstMateChrome()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: showsSearch) { _, shown in searchFocused = shown }
        .sheet(item: $archiveRequest) { request in
            FirstMateMobileArchiveSheet(model: model, fleet: fleet, request: request)
        }
        .onChange(of: model.connectionGeneration) { _, _ in
            archiveRequest = nil
            mutationFeedback.reset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-conversations-screen")
    }

    private func conversationRow(_ row: FirstMateConversation) -> some View {
        let target = FirstMateMobileListPresentation.target(row)
        return FirstMateConversationRow(conversation: row, selected: fleet.selectedTarget == target,
                                        open: { openFeature(target) })
            .contextMenu {
                Button("Open info", systemImage: "info.circle") { openInfo(target) }
                if row.isArchived {
                    Button("Unarchive", systemImage: "arrow.uturn.backward") { unarchive(target) }.disabled(!canArchive(target))
                } else {
                    Button("Archive…", systemImage: "archivebox") { presentArchive(target) }.disabled(!canArchive(target))
                }
                Button("Copy feature ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.featureID }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if row.isArchived {
                    Button("Unarchive", systemImage: "arrow.uturn.backward") { unarchive(target) }
                        .tint(HerdrTheme.accent).disabled(!canArchive(target))
                        .accessibilityIdentifier("first-mate-unarchive-\(row.machineID)-\(row.featureID)")
                } else {
                    Button("Archive…", systemImage: "archivebox") { presentArchive(target) }
                        .tint(HerdrTheme.controlAccent).disabled(!canArchive(target))
                        .accessibilityIdentifier("first-mate-archive-\(row.machineID)-\(row.featureID)")
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("first-mate-chat-row-\(row.machineID)-\(row.featureID)")
    }

    private func canArchive(_ target: FirstMateFeatureTarget) -> Bool {
        guard let store = fleet.store(for: target), let feature = fleet.feature(for: target) else { return false }
        return !feature.isLead && model.firstMateCanControl(machineID: target.machineID) && store.archiveSupported
            && !store.isSending && !store.isSubmitting(featureID: target.featureID) && !fleet.isArchiving(target)
    }
    private func presentArchive(_ target: FirstMateFeatureTarget) {
        guard canArchive(target) else { return }
        model.beginAppNavigation()
        archiveRequest = .capture(target: target, fleet: fleet)
    }
    private func unarchive(_ target: FirstMateFeatureTarget) {
        guard canArchive(target), let store = fleet.store(for: target) else { return }
        let context = store.operationContext
        let operation = mutationFeedback.begin(target: target, store: store)
        Task {
            let succeeded = await fleet.setArchived(target, archived: false, expectedContext: context)
            mutationFeedback.complete(operation, succeeded: succeeded, error: store.error, fleet: fleet)
        }
    }
}
