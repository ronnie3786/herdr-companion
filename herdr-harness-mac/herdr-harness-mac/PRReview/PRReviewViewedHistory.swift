struct PRReviewViewedHistory: Equatable {
    struct Change: Equatable {
        let path: String
        let before: Bool
    }

    struct Entry: Equatable {
        let changes: [Change]
        let after: Bool
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ entry: Entry) {
        undoStack.append(entry)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
    }

    mutating func takeUndo() -> Entry? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry
    }

    mutating func takeRedo() -> Entry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
