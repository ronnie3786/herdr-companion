import SwiftUI

struct FirstMateResourceMetadataView: View {
    let resource: FirstMateResource

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                switch resource {
                case .document(let document):
                    Text(document.mediaType).font(.footnote)
                    if let sessionID = document.nativeSessionID {
                        Text("Producing session").font(.footnote).foregroundStyle(.secondary)
                        Text(sessionID).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    if let revision = document.inputRevision {
                        Text("Input revision \(revision)").font(.footnote)
                    }
                    Text("Content hash").font(.footnote).foregroundStyle(.secondary)
                    Text(document.contentHash).font(.footnote.monospaced()).textSelection(.enabled)
                case .session(let agent):
                    Text("Native Pi session").font(.footnote).foregroundStyle(.secondary)
                    Text(agent.nativeSessionID ?? "Session pending").font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Attempt \(agent.attempt) · input revision \(agent.inputRevision)").font(.footnote)
                case .history(let session):
                    Text("Native Pi session").font(.footnote).foregroundStyle(.secondary)
                    Text(session.nativeSessionID).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("Ownership: \(session.ownershipStatus)").font(.footnote)
                    if let attempt = session.attempt { Text("Attempt \(attempt)").font(.footnote) }
                    if let revision = session.inputRevision { Text("Input revision \(revision)").font(.footnote) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } label: {
            Text("Source details")
                .accessibilityIdentifier("first-mate-source-details")
        }
        .font(.subheadline)
        .padding(.vertical, 8)
    }
}
