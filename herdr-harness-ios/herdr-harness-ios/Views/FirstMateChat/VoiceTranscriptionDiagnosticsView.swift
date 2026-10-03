import SwiftUI

struct VoiceTranscriptionDiagnosticsView: View {
    let report: String
    @State private var presented = false
    @State private var copied = false

    var body: some View {
        Button("Transcription details", systemImage: "exclamationmark.bubble") { presented = true }
            .font(.footnote)
            .frame(minHeight: 44)
            .accessibilityIdentifier("voice-transcription-details")
            .sheet(isPresented: $presented) {
                NavigationStack {
                    ScrollView {
                        Text(report)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Transcription details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presented = false }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button(copied ? "Copied diagnostics" : "Copy diagnostics", systemImage: "doc.on.doc", action: copy)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("voice-copy-diagnostics")
                        }
                    }
                }
            }
            .onChange(of: report) { copied = false }
    }

    private func copy() {
        UIPasteboard.general.string = report
        copied = true
    }
}
