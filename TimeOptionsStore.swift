import Foundation
import SwiftUI

@MainActor
final class TimeOptionsStore: ObservableObject {
    @Published private(set) var options: [String]

    private let defaultsKey = "BBCD4Mac.startTimeOptions"
    private static let defaultOptions = (0..<48).map { index in
        String(format: "%02d:%02d:00", index / 2, index.isMultiple(of: 2) ? 0 : 30)
    }

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.stringArray(forKey: defaultsKey) ?? Self.defaultOptions
        options = Self.normalised(stored)
        if options != stored { save() }
    }

    func add(_ value: String) throws {
        let time = try Self.validated(value)
        guard !options.contains(time) else { throw TimeOptionError.duplicate }
        options.append(time)
        save()
    }

    func add(lines: String) throws {
        let inputLines = lines.components(separatedBy: .newlines)
        var addedTimes: [String] = []
        var seenTimes = Set<String>()

        for (index, line) in inputLines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let time: String
            do {
                time = try Self.validated(line)
            } catch {
                throw TimeOptionError.invalidTimeOnLine(index + 1)
            }

            guard seenTimes.insert(time).inserted, !options.contains(time) else {
                throw TimeOptionError.duplicate
            }
            addedTimes.append(time)
        }

        guard !addedTimes.isEmpty else { throw TimeOptionError.noTimesEntered }
        options.append(contentsOf: addedTimes)
        save()
    }

    func update(_ original: String, to value: String) throws {
        let time = try Self.validated(value)
        guard let index = options.firstIndex(of: original) else { return }
        guard time == original || !options.contains(time) else { throw TimeOptionError.duplicate }
        options[index] = time
        save()
    }

    func delete(_ value: String) {
        options.removeAll { $0 == value }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        options.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        options = Self.defaultOptions
        save()
    }

    private func save() {
        UserDefaults.standard.set(options, forKey: defaultsKey)
    }

    private static func normalised(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let valid = values.compactMap { try? validated($0) }.filter { seen.insert($0).inserted }
        return valid.isEmpty ? defaultOptions : valid
    }

    private static func validated(_ value: String) throws -> String {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard pieces.count == 2 || pieces.count == 3,
              let hour = Int(pieces[0]), (0...23).contains(hour),
              let minute = Int(pieces[1]), (0...59).contains(minute) else {
            throw TimeOptionError.invalidTime
        }

        let second: Int
        if pieces.count == 3 {
            guard let parsedSecond = Int(pieces[2]), (0...59).contains(parsedSecond) else {
                throw TimeOptionError.invalidTime
            }
            second = parsedSecond
        } else {
            second = 0
        }

        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}

enum TimeOptionError: LocalizedError {
    case invalidTime
    case invalidTimeOnLine(Int)
    case noTimesEntered
    case duplicate

    var errorDescription: String? {
        switch self {
        case .invalidTime: "Enter a time as hours:minutes or hours:minutes:seconds."
        case .invalidTimeOnLine(let line): "Time on line \(line) must use hours:minutes or hours:minutes:seconds."
        case .noTimesEntered: "Enter at least one start time."
        case .duplicate: "This time is already on the list."
        }
    }
}
