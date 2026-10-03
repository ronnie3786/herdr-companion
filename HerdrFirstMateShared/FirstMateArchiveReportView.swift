import SwiftUI
import UniformTypeIdentifiers

struct FirstMateArchiveReportView: View {
    let store: FirstMateStore
    let featureID: String
    var archiveID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    @State private var error: String?
    @State private var exporting = false
    @State private var reload = 0
    @State private var lifecycle: FirstMateStore.LifecycleIdentity?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let report {
                    ScrollView {
                        Text(String(report.prefix(120_000)))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    if report.count > 120_000 {
                        Text("Preview shows the first 120,000 characters. Export includes the complete record.")
                            .font(.caption)
                            .padding(.horizontal)
                    }
                } else if error == nil {
                    ProgressView("Loading completion record…").padding()
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
                    Button("Reload record") { reload += 1 }.padding(.horizontal)
                }
            }
            .navigationTitle("Completion record")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export Markdown", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(report == nil)
                }
            }
            .task(id: reload) {
                error = nil
                if lifecycle == nil { lifecycle = store.lifecycle }
                do {
                    guard lifecycle == store.lifecycle else { throw CancellationError() }
                    let value = try await store.archiveReport(featureID: featureID, archiveID: archiveID)
                    guard lifecycle == store.lifecycle else { throw CancellationError() }
                    report = value
                }
                catch is CancellationError {
                    report = nil
                    error = "The connection changed. Close this screen and open the record again."
                }
                catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: FirstMateArchiveDocument(text: report ?? ""),
                          contentType: .plainText, defaultFilename: "\(featureID)-completion.md") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}
