import Foundation

enum HerdrHudWorkingFolderError: LocalizedError, Equatable, Sendable {
    case invalidMachine
    case invalidPath
    case homeIsBuiltIn

    var errorDescription: String? {
        switch self {
        case .invalidMachine:
            "Choose a machine before adding a working folder."
        case .invalidPath:
            "Enter an absolute folder path, up to 4096 characters."
        case .homeIsBuiltIn:
            "The home folder is already available as ~."
        }
    }
}
