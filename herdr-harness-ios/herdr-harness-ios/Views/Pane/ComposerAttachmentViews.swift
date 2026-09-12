import SwiftUI

struct ComposerAttachmentTray: View {
    let attachments: [TerminalAttachment]
    let retry: (TerminalAttachment) -> Void
    let remove: (TerminalAttachment) -> Void
    @ScaledMetric(relativeTo: .body) private var scaledHeight = 68.0

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentChip(
                            attachment: attachment,
                            thumbnailData: attachment.thumbnailData,
                            retry: { retry(attachment) },
                            remove: { remove(attachment) }
                        )
                        .frame(width: max(1, proxy.size.width - 2))
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: trayHeight)
        .accessibilityLabel("Attachments")
        .accessibilityIdentifier("composer-attachments")
        .composerLayoutMeasurement(id: "composer-attachments", label: "Attachments")
    }

    private var trayHeight: CGFloat {
        min(max(scaledHeight, 68), 104)
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: TerminalAttachment
    let thumbnailData: Data?
    let retry: () -> Void
    let remove: () -> Void
    @ScaledMetric(relativeTo: .body) private var scaledThumbnailSize = 48.0

    var body: some View {
        HStack(spacing: 9) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(attachment.displayName)
                    .composerLayoutMeasurement(
                        id: "composer-attachment-filename-\(attachment.id)",
                        label: attachment.displayName
                    )

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(statusText)
                    .composerLayoutMeasurement(
                        id: "composer-attachment-status-\(attachment.id)",
                        label: statusText
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            statusAccessory
                .fixedSize(horizontal: true, vertical: false)

            Button("Remove \(attachment.displayName)", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .font(.caption.bold())
                .foregroundStyle(HerdrTheme.mist)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-attachment-remove-\(attachment.id)")
                .composerLayoutMeasurement(
                    id: "composer-attachment-remove-\(attachment.id)",
                    label: "Remove \(attachment.displayName)"
                )
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-attachment-\(attachment.id)")
        .composerLayoutMeasurement(
            id: "composer-attachment-\(attachment.id)",
            label: attachment.displayName
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailData,
           let image = ComposerAttachmentThumbnail.boundedImage(from: thumbnailData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(.rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .accessibilityHidden(true)
                .composerLayoutMeasurement(
                    id: "composer-attachment-preview-\(attachment.id)",
                    label: attachment.displayName
                )
        } else {
            Image(systemName: fileIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .background(HerdrTheme.graphite, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
                .composerLayoutMeasurement(
                    id: "composer-attachment-preview-\(attachment.id)",
                    label: attachment.displayName
                )
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch attachment.status {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.accent)
                .frame(minWidth: 28, minHeight: 44)
                .accessibilityLabel("Uploading")

        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.success)
                .frame(minWidth: 28, minHeight: 44)
                .accessibilityLabel("Ready")

        case .failed:
            Button("Retry \(attachment.displayName)", systemImage: "arrow.clockwise", action: retry)
                .labelStyle(.iconOnly)
                .font(.caption.bold())
                .foregroundStyle(HerdrTheme.alert)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-attachment-retry-\(attachment.id)")
                .composerLayoutMeasurement(
                    id: "composer-attachment-retry-\(attachment.id)",
                    label: "Retry \(attachment.displayName)"
                )
        }
    }

    private var thumbnailSize: CGFloat {
        min(max(scaledThumbnailSize, 44), 64)
    }

    private var statusText: String {
        switch attachment.status {
        case .uploading:
            return "Uploading"
        case .uploaded:
            return "Ready"
        case .failed:
            let message = attachment.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? "Upload failed" : message
        }
    }

    private var statusColor: Color {
        switch attachment.status {
        case .uploading:
            HerdrTheme.accent
        case .uploaded:
            HerdrTheme.success
        case .failed:
            HerdrTheme.alert
        }
    }

    private var borderColor: Color {
        switch attachment.status {
        case .uploading:
            HerdrTheme.accent.opacity(0.5)
        case .uploaded:
            HerdrTheme.success.opacity(0.45)
        case .failed:
            HerdrTheme.alert.opacity(0.55)
        }
    }

    private var fileIcon: String {
        let fileExtension = attachment.displayName
            .split(separator: ".")
            .last
            .map { String($0).lowercased() } ?? ""

        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(fileExtension) {
            return "photo"
        }
        if ["m4a", "mp3", "wav", "aac", "caf"].contains(fileExtension) {
            return "waveform"
        }
        if fileExtension == "pdf" {
            return "doc.richtext"
        }
        if ["zip", "gz", "tar"].contains(fileExtension) {
            return "archivebox"
        }
        return "doc.text"
    }
}
