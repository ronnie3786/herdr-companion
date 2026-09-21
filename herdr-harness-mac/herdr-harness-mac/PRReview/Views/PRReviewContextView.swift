import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PRReviewContextView: View {
    @Bindable var store: PRReviewStore
    @State private var isDropTargeted = false
    @State private var isPresentingLinkSheet = false
    @State private var linkURL = ""
    @State private var linkTitle = ""

    private let sections: [(String, [PRReviewDocumentKind])] = [
        ("Reports", [.html]),
        ("Findings", [.markdown]),
        ("Audio", [.audio]),
        ("Videos", [.video]),
        ("Links", [.link]),
        ("Other", [.file, .unknown]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HerdrTheme.cardPadding) {
                dropZone
                if let error = store.contextImportError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.alert)
                        .padding(10)
                        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                }
                if !store.documentUploads.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uploads").herdrFont(.headline)
                        ForEach(store.documentUploads.values.sorted { $0.url.path < $1.url.path }, id: \.url) { upload in
                            PRReviewUploadRow(store: store, upload: upload)
                        }
                    }
                }
                if store.snapshot?.documents.isEmpty != false {
                    ContentUnavailableView("No context documents", systemImage: "doc.badge.plus")
                } else {
                    ForEach(sections, id: \.0) { section in
                        let documents = (store.snapshot?.documents ?? []).filter { section.1.contains($0.kind) }
                        if !documents.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.0).herdrFont(.headline)
                                ForEach(documents) { document in
                                    PRReviewDocumentRow(store: store, document: document)
                                }
                            }
                        }
                    }
                }
            }
            .padding(HerdrTheme.pagePadding)
        }
        .background(HerdrTheme.graphite)
        .sheet(isPresented: $isPresentingLinkSheet) {
            addLinkSheet
        }
        .accessibilityIdentifier("pr-review-context")
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(HerdrTheme.accent)
            Text("Drop files, folders, or links here")
                .herdrFont(.headline)
            HStack {
                Button("Add file…", systemImage: "doc.badge.plus", action: chooseFiles)
                    .accessibilityIdentifier("pr-review-add-file")
                Button("Add link…", systemImage: "link") {
                    isPresentingLinkSheet = true
                }
                .accessibilityIdentifier("pr-review-add-link")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(HerdrTheme.pagePadding)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
            store.acceptContextDrop(providers)
        }
        .background {
            HerdrHudDropTarget(
                onTargetingChanged: { isDropTargeted = $0 },
                onDrop: { store.acceptContextPasteboardDrop($0) },
                registeredTypes: PRReviewContextDropPolicy.registeredTypes,
                accepts: PRReviewContextDropPolicy.accepts
            )
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.accent, lineWidth: 2)
            }
        }
        .accessibilityIdentifier("pr-review-context-drop-zone")
    }

    private var addLinkSheet: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            Text("Add context link").herdrFont(.title2, weight: .semibold)
            TextField("https://example.com/report", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pr-review-link-url")
            TextField("Title (optional)", text: $linkTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pr-review-link-title")
            HStack {
                Spacer()
                Button("Cancel") { isPresentingLinkSheet = false }
                Button("Add link") {
                    let url = linkURL
                    let title = linkTitle
                    linkURL = ""
                    linkTitle = ""
                    isPresentingLinkSheet = false
                    Task { await store.addLink(url: url, title: title) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HerdrTheme.pagePadding)
        .frame(width: 440)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .accessibilityIdentifier("pr-review-add-link-sheet")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data, .folder]
        guard panel.runModal() == .OK else { return }
        store.importContextItems(urls: panel.urls)
    }
}

private struct PRReviewUploadRow: View {
    @Bindable var store: PRReviewStore
    let upload: PRReviewStore.PRReviewDocumentUpload

    var body: some View {
        HStack(spacing: 8) {
            switch upload.status {
            case .uploading:
                ProgressView().controlSize(.small)
            case .uploaded:
                Image(systemName: "checkmark.circle").foregroundStyle(HerdrTheme.success)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(HerdrTheme.alert)
            }
            Text(upload.url.lastPathComponent).herdrFont(.caption)
            Spacer()
            if case .failed = upload.status {
                Button("Retry") { store.retryUpload(url: upload.url) }
                    .accessibilityIdentifier("pr-review-upload-retry-\(upload.url.lastPathComponent)")
            }
        }
        .padding(8)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }
}

private struct PRReviewDocumentRow: View {
    @Bindable var store: PRReviewStore
    let document: PRReviewDocument
    @State private var isHovering = false
    @State private var openError: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).herdrFont(.body, weight: .semibold).lineLimit(1)
                Text("\(originCaption) · \(byteCountCaption) · \(dateCaption)")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                if let openError {
                    Text(openError).herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                } else if let phaseCaption {
                    Text(phaseCaption).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                }
            }
            Spacer(minLength: 8)
            if isHovering {
                actions
            }
        }
        .padding(10)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("pr-review-document-\(document.id)")
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button("Open", systemImage: "arrow.up.right.square", action: open)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Open \(document.title)")
                .accessibilityIdentifier("pr-review-document-open-\(document.id)")
            if case let .ready(url) = store.documentPhases[document.id] ?? .idle {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Reveal \(document.title) in Finder")
            }
            if let url = document.url {
                Button("Copy link", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Copy link for \(document.title)")
            }
        }
        .buttonStyle(.borderless)
    }

    private var symbol: String {
        switch document.kind {
        case .markdown: "doc.text"
        case .html: "chart.bar.doc.horizontal"
        case .audio: "waveform"
        case .video: "video"
        case .link: "link"
        case .file, .unknown: "doc"
        }
    }

    private var originCaption: String {
        if let runID = document.runID,
           let run = store.snapshot?.runs.first(where: { $0.id == runID }) {
            return run.skillTitle
        }
        switch document.origin.lowercased() {
        case "user", "manual": return "Added by you"
        case "cli": return "CLI"
        default: return "Agent"
        }
    }

    private var byteCountCaption: String {
        document.byteSize > 0 ? ByteCountFormatter.string(fromByteCount: document.byteSize, countStyle: .file) : "Link"
    }

    private var dateCaption: String {
        guard let createdAt = document.createdAt else { return "Just now" }
        return String(createdAt.prefix(10))
    }

    private var phaseCaption: String? {
        switch store.documentPhases[document.id] ?? .idle {
        case .idle: nil
        case .uploading: "Uploading…"
        case .downloading: "Downloading…"
        case .ready: "Ready"
        case let .failed(message): message
        }
    }

    private func open() {
        openError = nil
        switch document.kind {
        case .markdown:
            PRReviewDocumentWindow.showMarkdown(document: document, store: store)
        case .html:
            PRReviewDocumentWindow.showHTML(document: document, store: store)
        case .link:
            guard let value = document.url, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                openError = "This link is not a valid http or https address."
                return
            }
            Task {
                do { try await ActiveWorkLinkOpener.open(url) }
                catch { openError = error.localizedDescription }
            }
        case .audio, .video:
            Task {
                do {
                    let url = try await store.localURL(for: document)
                    try await openInQuickTime(url)
                } catch {
                    openError = error.localizedDescription
                }
            }
        case .file, .unknown:
            Task {
                do {
                    let url = try await store.localURL(for: document)
                    guard NSWorkspace.shared.open(url) else {
                        openError = "No application could open this document."
                        return
                    }
                } catch {
                    openError = error.localizedDescription
                }
            }
        }
    }

    private func openInQuickTime(_ url: URL) async throws {
        guard let quickTime = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else {
            guard NSWorkspace.shared.open(url) else { throw ActiveWorkLinkOpener.OpenError.unavailable }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: quickTime, configuration: configuration) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            guard NSWorkspace.shared.open(url) else { throw error }
        }
    }
}
