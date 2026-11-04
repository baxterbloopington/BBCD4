import Foundation
import SwiftUI

enum DateFormats {
    static func duration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        var components: [String] = []
        if hours > 0 { components.append("\(hours)h") }
        if minutes > 0 { components.append("\(minutes)m") }
        if seconds > 0 || components.isEmpty { components.append("\(seconds)s") }
        return components.joined(separator: " ")
    }

    struct Choice: Identifiable {
        let pattern: String
        let description: String?

        var id: String { pattern }
    }

    static let choices = [
        Choice(pattern: "dd-MM-yyyy", description: "dd-mm-yyyy"),
        Choice(pattern: "yyyy-MM-dd", description: "yyyy-mm-dd"),
        Choice(pattern: "MM-dd-yyyy", description: "mm-dd-yyyy"),
        Choice(pattern: "dd/MM/yyyy", description: "dd/mm/yyyy"),
        Choice(pattern: "yyyy/MM/dd", description: "yyyy/mm/dd"),
        Choice(pattern: "MM/dd/yyyy", description: "mm/dd/yyyy"),
        Choice(pattern: "dd.MM.yyyy", description: "dd.mm.yyyy"),
        Choice(pattern: "yyyy.MM.dd", description: "yyyy.mm.dd"),
        Choice(pattern: "MM.dd.yyyy", description: "mm.dd.yyyy"),
        Choice(pattern: "dd MM yyyy", description: "dd mm yyyy"),
        Choice(pattern: "yyyy MM dd", description: "yyyy mm dd"),
        Choice(pattern: "MM dd yyyy", description: "mm dd yyyy"),
        Choice(pattern: "dd MMM yyyy", description: nil),
        Choice(pattern: "MMM dd yyyy", description: nil)
    ]

    static func formatter(for pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = choices.contains(where: { $0.pattern == pattern }) ? pattern : "dd/MM/yyyy"
        formatter.isLenient = false
        return formatter
    }

    static func filenameDate(_ date: Date, format pattern: String) -> String {
        formatter(for: pattern)
            .string(from: date)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func displayDateTime(_ date: Date, format pattern: String) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_GB")
        timeFormatter.dateFormat = "HH:mm:ss"
        return "\(formatter(for: pattern).string(from: date)) at \(timeFormatter.string(from: date))"
    }

    static func date(from input: String, format pattern: String) -> Date? {
        let formatter = formatter(for: pattern)
        guard let date = formatter.date(from: input), formatter.string(from: date) == input else {
            return nil
        }
        return date
    }

    static func supportsNumericEntry(for pattern: String) -> Bool {
        !pattern.contains("MMM")
    }

    static func sanitizedNumericInput(_ input: String, format pattern: String) -> String {
        guard supportsNumericEntry(for: pattern) else { return input }

        let limitedInput = String(input.prefix(11))
        let digits = limitedInput.filter(\.isNumber)
        let components = numericComponents(for: pattern)
        var accepted = ""

        for digit in digits.prefix(8) {
            let candidate = accepted + String(digit)
            if isPossibleNumericPrefix(candidate, components: components) {
                accepted = candidate
            }
        }

        if accepted.count == 8, !isValidNumericDate(accepted, components: components) {
            accepted.removeLast()
        }

        return formatNumericDigits(accepted, typedInput: limitedInput, components: components)
    }

    private static func numericComponents(for pattern: String) -> [(token: String, separator: Character?)] {
        var result: [(String, Character?)] = []
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let start = index
            let tokenCharacter = pattern[index]
            while index < pattern.endIndex, pattern[index] == tokenCharacter {
                index = pattern.index(after: index)
            }
            let token = String(pattern[start..<index])
            var separator: Character?
            if index < pattern.endIndex {
                separator = pattern[index]
                index = pattern.index(after: index)
            }
            result.append((token, separator))
        }
        return result
    }

    private static func isPossibleNumericPrefix(_ digits: String, components: [(token: String, separator: Character?)]) -> Bool {
        var offset = 0
        for component in components {
            let width = component.token.count
            let remaining = digits.count - offset
            guard remaining > 0 else { break }
            let count = min(width, remaining)
            let part = String(digits.dropFirst(offset).prefix(count))
            if component.token == "dd", !isPossibleDay(part) { return false }
            if component.token == "MM", !isPossibleMonth(part) { return false }
            offset += count
            if count < width { break }
        }
        return true
    }

    private static func isPossibleDay(_ value: String) -> Bool {
        guard let number = Int(value) else { return false }
        return value.count == 1 ? (0...3).contains(number) : (1...31).contains(number)
    }

    private static func isPossibleMonth(_ value: String) -> Bool {
        guard let number = Int(value) else { return false }
        return value.count == 1 ? (0...1).contains(number) : (1...12).contains(number)
    }

    private static func isValidNumericDate(_ digits: String, components: [(token: String, separator: Character?)]) -> Bool {
        var values: [String: Int] = [:]
        var offset = 0
        for component in components {
            let width = component.token.count
            values[component.token] = Int(digits.dropFirst(offset).prefix(width))
            offset += width
        }
        guard let day = values["dd"], let month = values["MM"], let year = values["yyyy"] else { return false }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else { return false }
        let checked = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return checked.year == year && checked.month == month && checked.day == day
    }

    private static func formatNumericDigits(
        _ digits: String,
        typedInput: String,
        components: [(token: String, separator: Character?)]
    ) -> String {
        var result = ""
        var offset = 0
        var typedSeparatorCounts: [Character: Int] = [:]
        for character in typedInput where !character.isNumber {
            typedSeparatorCounts[character, default: 0] += 1
        }
        var usedSeparatorCounts: [Character: Int] = [:]

        for component in components {
            let width = component.token.count
            let part = String(digits.dropFirst(offset).prefix(width))
            result += part
            offset += part.count
            if part.count == width, let separator = component.separator {
                let typedCount = typedSeparatorCounts[separator, default: 0]
                let usedCount = usedSeparatorCounts[separator, default: 0]
                if offset < digits.count || typedCount > usedCount {
                    result.append(separator)
                    usedSeparatorCounts[separator, default: 0] += 1
                }
            }
            if part.count < width { break }
        }
        return result
    }

    static func label(for choice: Choice, date: Date = Date()) -> String {
        let example = formatter(for: choice.pattern).string(from: date)
        return choice.description.map { "\(example) (\($0))" } ?? example
    }
}

@MainActor
final class TimeOptionsStore: ObservableObject {
    @Published private(set) var options: [String]

    private let defaultsKey = "BBCD4Mac.startTimeOptions"
    private let defaults: UserDefaults
    private static let defaultOptions = (0..<48).map { index in
        String(format: "%02d:%02d:00", index / 2, index.isMultiple(of: 2) ? 0 : 30)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: defaultsKey) ?? Self.defaultOptions
        options = Self.normalised(stored)
        if options != stored { save() }
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

    static func scrollTarget(from value: String, options: [String], step: Int) -> String? {
        guard !options.isEmpty, step != 0, let current = try? validated(value) else { return nil }
        if let index = options.firstIndex(of: current) {
            let next = min(max(index + step.signum(), 0), options.count - 1)
            return next == index ? nil : options[next]
        }
        func seconds(_ time: String) -> Int? {
            guard let normalized = try? validated(time) else { return nil }
            return normalized.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        guard let currentSeconds = seconds(current) else { return nil }
        var target: (value: String, distance: Int)?
        for option in options {
            guard let time = seconds(option) else { continue }
            let distance = step < 0 ? currentSeconds - time : time - currentSeconds
            guard distance > 0, target.map({ distance < $0.distance }) ?? true else { continue }
            target = (option, distance)
        }
        return target?.value
    }

    private func save() {
        defaults.set(options, forKey: defaultsKey)
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
