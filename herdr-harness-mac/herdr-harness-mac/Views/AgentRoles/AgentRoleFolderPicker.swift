import AppKit

@MainActor
enum AgentRoleFolderPicker {
    static func choose(catalog: any AgentRoleSkillCatalog, path: String? = nil,
                       name: String? = nil, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Allow skill folder access"
        panel.message = "Herdr reads SKILL.md files and their supporting resources. Linked skills may need access to their target folder too."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = path == nil
        panel.showsHiddenFiles = true
        panel.prompt = "Allow Access"
        panel.directoryURL = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentRoleSkillLocations.userHome
        panel.begin { response in
            guard response == .OK else { return }
            do {
                for url in panel.urls { try catalog.addSource(url, name: panel.urls.count == 1 ? name : nil) }
                completion(nil)
                Task { await catalog.refresh() }
            } catch { completion(error.localizedDescription) }
        }
    }
}
