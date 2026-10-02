import Foundation

struct AgentRoleSkillIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case folderAccess, linkedFolderAccess, missingFolder, unreadableSkill, scanLimit
    }

    var kind: Kind
    let sourceName: String
    let path: String
    var skillNames: Set<String> = []
    var detail: String? = nil

    var id: String { kind.rawValue + ":" + path }
    var needsAccess: Bool { kind == .folderAccess || kind == .linkedFolderAccess }

    var title: String {
        switch kind {
        case .folderAccess: "Allow access to \(sourceName)"
        case .linkedFolderAccess: "\(skillNames.count) linked \(skillNames.count == 1 ? "skill needs" : "skills need") folder access"
        case .missingFolder: "\(sourceName) folder isn't available"
        case .unreadableSkill: "\(skillNames.sorted().first ?? sourceName) couldn't be read"
        case .scanLimit: "\(sourceName) is too large to scan"
        }
    }

    var message: String {
        switch kind {
        case .folderAccess:
            detail ?? "macOS needs your permission to read this skill folder."
        case .linkedFolderAccess:
            "These skills link to another folder. Allow access to that folder to include them."
        case .missingFolder:
            "Reconnect this folder or remove it from Skills from this Mac."
        case .unreadableSkill:
            detail ?? "Check that SKILL.md is a readable UTF-8 file, no larger than 2 MB."
        case .scanLimit:
            "Choose a smaller folder containing skill packages."
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== error, isPermissionError(underlying) { return true }
        return (error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code))
    }

    static func isMissingError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == 2)
    }
}
