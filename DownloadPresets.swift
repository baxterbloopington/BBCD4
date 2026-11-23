import Foundation
import Combine
import SwiftUI

struct DownloadPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let streamName: String
    let streamURL: String
    let hour: Int
    let minute: Int
    let second: Int
    let duration: Int
    let editOutput: Bool
    let encode: Bool

    init(id: UUID = UUID(), name: String, stream: Stream, start: Date, duration: Int, editOutput: Bool, encode: Bool,
         calendar: Calendar = .current) {
        self.id = id
        self.name = name
        streamName = stream.name
        streamURL = stream.url
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        hour = time.hour ?? 0
        minute = time.minute ?? 0
        second = time.second ?? 0
        self.duration = duration
        self.editOutput = editOutput
        self.encode = encode
    }

    init(duplicating preset: DownloadPreset, name: String) {
        id = UUID()
        self.name = name
        streamName = preset.streamName
        streamURL = preset.streamURL
        hour = preset.hour
        minute = preset.minute
        second = preset.second
        duration = preset.duration
        editOutput = preset.editOutput
        encode = preset.encode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, streamName, streamURL, hour, minute, second, duration, editOutput, encode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        streamName = try values.decode(String.self, forKey: .streamName)
        streamURL = try values.decode(String.self, forKey: .streamURL)
        hour = try values.decode(Int.self, forKey: .hour)
        minute = try values.decode(Int.self, forKey: .minute)
        second = try values.decode(Int.self, forKey: .second)
        duration = try values.decode(Int.self, forKey: .duration)
        editOutput = try values.decode(Bool.self, forKey: .editOutput)
        encode = try values.decode(Bool.self, forKey: .encode)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !streamName.isEmpty,
              !streamURL.isEmpty, (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              (1...DownloadLimits.maximumDuration).contains(duration) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid download preset"))
        }
    }

    var time: String { String(format: "%02d:%02d:%02d", hour, minute, second) }

    func startToday(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let day = calendar.startOfDay(for: now)
        guard let start = calendar.date(bySettingHour: hour, minute: minute, second: second, of: day),
              calendar.isDate(start, inSameDayAs: now) else { return nil }
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        guard time.hour == hour, time.minute == minute, time.second == second else { return nil }
        return start
    }

    func stream(in streams: [Stream]) -> Stream? {
        streams.first { $0.url == streamURL && $0.name == streamName }
            ?? streams.first { $0.url == streamURL }
            ?? streams.first { $0.name == streamName }
    }
}

@MainActor
final class DownloadPresetStore: ObservableObject {
    static let preferenceKey = "BBCD4Mac.downloadPresets"
    @Published private(set) var presets: [DownloadPreset]
    private let defaults: UserDefaults
    private var recoveryData: Data?

    enum PresetError: LocalizedError {
        case missingName, duplicateName, invalidDuration, missingStream, invalidTime, missingPreset
        var errorDescription: String? {
            switch self {
            case .missingName: "Enter a name for this preset."
            case .duplicateName: "A preset with this name already exists."
            case .invalidDuration: "Choose a duration before saving a preset."
            case .missingStream: "Choose a stream before saving a preset."
            case .invalidTime: "Enter a valid start time before saving a preset."
            case .missingPreset: "This preset is no longer available."
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.preferenceKey) else { presets = []; return }
        let decoded = try? JSONDecoder().decode(RecoverableArray<DownloadPreset>.self, from: data)
        var ids = Set<UUID>()
        var names = Set<String>()
        presets = (decoded?.values ?? []).filter { ids.insert($0.id).inserted && names.insert($0.name.lowercased()).inserted }
        if decoded == nil || decoded?.skippedCount != 0 || presets.count != decoded?.values.count { recoveryData = data }
    }

    func add(name: String, stream: Stream, start: Date, duration: Int, editOutput: Bool, encode: Bool) throws {
        let name = try validatedName(name)
        guard (1...DownloadLimits.maximumDuration).contains(duration) else { throw PresetError.invalidDuration }
        presets.append(DownloadPreset(name: name, stream: stream, start: start, duration: duration,
                                      editOutput: editOutput, encode: encode))
        save()
    }

    func rename(_ preset: DownloadPreset, to name: String) throws {
        let name = try validatedName(name, excluding: preset.id)
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = name
        save()
    }

    func update(_ preset: DownloadPreset, name: String, stream: Stream, start: Date, duration: Int,
                editOutput: Bool, encode: Bool) throws {
        let name = try validatedName(name, excluding: preset.id)
        guard (1...DownloadLimits.maximumDuration).contains(duration) else { throw PresetError.invalidDuration }
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { throw PresetError.missingPreset }
        presets[index] = DownloadPreset(id: preset.id, name: name, stream: stream, start: start,
                                        duration: duration, editOutput: editOutput, encode: encode)
        save()
    }

    @discardableResult
    func duplicate(_ preset: DownloadPreset) -> DownloadPreset? {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return nil }
        let original = presets[index]
        let baseName = original.name + " copy"
        var name = baseName
        var suffix = 2
        while presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        let duplicate = DownloadPreset(duplicating: original, name: name)
        presets.insert(duplicate, at: index + 1)
        save()
        return duplicate
    }

    func remove(_ preset: DownloadPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func validatedName(_ value: String, excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetError.missingName }
        guard !presets.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PresetError.duplicateName
        }
        return name
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        if let recoveryData {
            defaults.set(recoveryData, forKey: Self.preferenceKey + ".recovery-" + UUID().uuidString)
            self.recoveryData = nil
        }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
