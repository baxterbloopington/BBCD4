import Foundation

@MainActor
final class EditHistory<State: Equatable> {
    let undoManager = UndoManager()

    init() {
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
    }

    func record(_ previous: State, current: State, name: String, restore: @escaping @MainActor (State) -> Void) {
        guard previous != current else { return }
        let opensGroup = undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { history in
            restore(previous)
            history.record(current, current: previous, name: name, restore: restore)
        }
        undoManager.setActionName(name)
        if opensGroup { undoManager.endUndoGrouping() }
    }
}

struct RecoverableValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct RecoverableArray<Value: Decodable>: Decodable {
    let values: [Value]
    let skippedCount: Int

    init(from decoder: Decoder) throws {
        let entries = try [RecoverableValue<Value>](from: decoder)
        values = entries.compactMap(\.value)
        skippedCount = entries.count - values.count
    }
}

enum DownloadLimits {
    static let maximumDuration = 351 * 3_600 - 1

    static func retryDelay(_ value: Double) -> Double {
        value.isFinite ? min(10, max(1, value)) : 2
    }
}
