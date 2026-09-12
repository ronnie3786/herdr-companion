import Foundation

/// Generation-scoped state for photo imports that may outlive a picker presentation.
struct ComposerPhotoPreparationState: Equatable {
    struct Token: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private(set) var token: Token?
    private(set) var photoCount = 0

    var isPreparing: Bool {
        token != nil
    }

    var blocksSending: Bool {
        isPreparing
    }

    var statusText: String {
        photoCount == 1 ? "Preparing photo…" : "Preparing \(photoCount) photos…"
    }

    mutating func begin(photoCount: Int) -> Token {
        precondition(photoCount > 0)
        let token = Token(id: UUID())
        self.token = token
        self.photoCount = photoCount
        return token
    }

    func owns(_ token: Token) -> Bool {
        self.token == token
    }

    /// Returns false for a superseded task so it cannot clear newer progress.
    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard owns(token) else { return false }
        self.token = nil
        photoCount = 0
        return true
    }

    mutating func cancel() {
        token = nil
        photoCount = 0
    }
}
