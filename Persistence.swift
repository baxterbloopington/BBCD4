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
    static let maximumSelectableHours = 168
    static let maximumDuration = 351 * 3_600 - 1

    static func earliestStart(for category: StreamCategory, now: Date = Date()) -> Date {
        if category == .radio { return now.addingTimeInterval(-2 * 24 * 60 * 60) }
        return Calendar.current.date(byAdding: .day, value: -8, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    static func immediateStart(from selected: Date, duration: Int, category: StreamCategory, now: Date = Date()) -> Date {
        let latest = max(earliestStart(for: category, now: now).addingTimeInterval(1),
                         now.addingTimeInterval(-TimeInterval(duration)))
        guard selected > latest else { return selected }
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: selected)
        let today = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                  second: time.second ?? 0, of: now) ?? latest
        return min(today, latest)
    }

    static func scrolledStart(from selected: Date, step: Int, duration: Int, category: StreamCategory,
                              scheduled: Bool, now: Date = Date()) -> Date? {
        let base = scheduled ? selected : immediateStart(from: selected, duration: duration, category: category, now: now)
        guard let date = Calendar.current.date(byAdding: .day, value: step, to: base),
              date > earliestStart(for: category, now: now), scheduled || date <= now else { return nil }
        return date
    }

    static func retryDelay(_ value: Double) -> Double {
        value.isFinite ? min(10, max(1, value)) : 2
    }
}
