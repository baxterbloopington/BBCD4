import Foundation

enum DateFormats {
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

    static func numericPlaceholder(for pattern: String) -> String {
        supportsNumericEntry(for: pattern) ? pattern.replacingOccurrences(of: "y", with: "Y") : "Enter date"
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
