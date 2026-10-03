import AppKit
import UniformTypeIdentifiers

/// Open and save panels for roles files. The share model only sees URLs and data.
@MainActor
enum AgentRolesSharePanels {
    static func chooseImportFile(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import Roles"
        panel.message = "Choose a roles file exported from Herdr. You review every role before anything is imported."
        panel.prompt = "Review"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    /// Saves the file exactly as exported, then shows it in Finder.
    static func save(_ export: AgentRolesExport, model: AgentRolesShareModel, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Roles"
        panel.message = "Teammates import this file in Settings › Agent Roles › Share."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = AgentRolesShareModel.exportFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            let saved = model.saveExport(export, to: url)
            if saved { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            completion(saved)
        }
    }
}
