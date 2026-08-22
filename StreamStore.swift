import Foundation

enum StreamCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case television
    case radio
    case liveStream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .television:
            "TV"
        case .liveStream:
            "Live stream"
        case .radio:
            "Radio"
        }
    }

    var iconName: String {
        switch self {
        case .television:
            "tv"
        case .liveStream:
            "dot.radiowaves.left.and.right"
        case .radio:
            "radio"
        }
    }

    static func inferred(from url: String) -> StreamCategory {
        let value = url.lowercased()
        return value.contains("/audio/") || value.contains("bbc_radio") || value.contains("bbc_world_service")
            ? .radio
            : .television
    }
}

struct Stream: Identifiable, Codable, Hashable, Sendable {
    var name: String
    var url: String
    var category: StreamCategory
    var isFavourite: Bool = false

    var id: String { name }
}

private struct StoredStream: Codable {
    var url: String
    var category: StreamCategory?
    var isFavourite: Bool

    init(url: String, category: StreamCategory?, isFavourite: Bool = false) {
        self.url = url
        self.category = category
        self.isFavourite = isFavourite
    }

    init(from decoder: Decoder) throws {
        if let url = try? decoder.singleValueContainer().decode(String.self) {
            self.init(url: url, category: nil)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(String.self, forKey: .url),
            category: try container.decodeIfPresent(StreamCategory.self, forKey: .category),
            isFavourite: try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        )
    }
}

private struct StoredStreams: Codable {
    var streams: [String: StoredStream]
    var order: [String]?
}

@MainActor
final class StreamStore: ObservableObject {
    @Published private(set) var streams: [Stream] = []
    @Published var selectedStreamID: String?

    private let fileManager = FileManager.default
    private let orderDefaultsKey = "BBCD4Mac.streamOrder"

    init() {
        load()
    }

    var selectedStream: Stream? {
        streams.first { $0.id == selectedStreamID }
    }

    func add(name: String, url: String, category: StreamCategory) throws {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty, !cleanedURL.isEmpty else {
            throw StreamError.missingDetails
        }
        guard Self.isSupportedURL(cleanedURL) else {
            throw StreamError.invalidURL
        }
        guard !streams.contains(where: { $0.name.caseInsensitiveCompare(cleanedName) == .orderedSame }) else {
            throw StreamError.duplicateName
        }
        guard !streams.contains(where: { $0.url == cleanedURL }) else {
            throw StreamError.duplicateURL
        }

        streams.append(Stream(name: cleanedName, url: cleanedURL, category: category))
        selectedStreamID = cleanedName
        save()
    }

    func update(originalName: String, name: String, url: String, category: StreamCategory) throws {
        guard let index = streams.firstIndex(where: { $0.name == originalName }) else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty, !cleanedURL.isEmpty else {
            throw StreamError.missingDetails
        }
        guard Self.isSupportedURL(cleanedURL) else {
            throw StreamError.invalidURL
        }
        guard !streams.enumerated().contains(where: {
            $0.offset != index && $0.element.name.caseInsensitiveCompare(cleanedName) == .orderedSame
        }) else {
            throw StreamError.duplicateName
        }
        guard !streams.enumerated().contains(where: {
            $0.offset != index && $0.element.url == cleanedURL
        }) else {
            throw StreamError.duplicateURL
        }

        streams[index] = Stream(
            name: cleanedName,
            url: cleanedURL,
            category: category,
            isFavourite: streams[index].isFavourite
        )
        selectedStreamID = cleanedName
        save()
    }

    func toggleFavourite(_ id: String) {
        guard let index = streams.firstIndex(where: { $0.id == id }) else { return }
        streams[index].isFavourite.toggle()
        save()
    }

    func setCategory(_ category: StreamCategory, for id: String) {
        guard let index = streams.firstIndex(where: { $0.id == id }) else { return }
        streams[index].category = category
        save()
    }

    func deleteSelected() {
        guard let selectedStreamID, let index = streams.firstIndex(where: { $0.id == selectedStreamID }) else {
            return
        }
        streams.remove(at: index)
        self.selectedStreamID = streams.indices.contains(index)
            ? streams[index].id
            : streams.last?.id
        save()
    }

    func moveFiltered(fromOffsets source: IndexSet, toOffset destination: Int, in filteredStreams: [Stream]) {
        let sourceIDs = source.compactMap { filteredStreams.indices.contains($0) ? filteredStreams[$0].id : nil }
        let sourceIndexes = IndexSet(sourceIDs.compactMap { id in streams.firstIndex { $0.id == id } })
        guard !sourceIndexes.isEmpty else { return }

        let destinationIndex: Int
        if filteredStreams.indices.contains(destination) {
            let destinationID = filteredStreams[destination].id
            destinationIndex = streams.firstIndex { $0.id == destinationID } ?? streams.endIndex
        } else if let lastVisible = filteredStreams.last,
                  let lastIndex = streams.firstIndex(where: { $0.id == lastVisible.id }) {
            destinationIndex = min(lastIndex + 1, streams.endIndex)
        } else {
            destinationIndex = streams.endIndex
        }

        streams.move(fromOffsets: sourceIndexes, toOffset: destinationIndex)
        selectedStreamID = sourceIDs.first
        save()
    }

    func resetToDefaults() {
        guard let stored = loadBundledStreams() else { return }
        let orderedNames = stored.order ?? Array(stored.streams.keys).sorted()
        streams = orderedNames.compactMap { name in
            stored.streams[name].map { Stream(
                name: name,
                url: $0.url,
                category: $0.category ?? StreamCategory.inferred(from: $0.url),
                isFavourite: $0.isFavourite
            ) }
        }
        selectedStreamID = streams.first?.id
        save()
    }

    private func load() {
        let stored = loadStoredStreams(from: storageURL)
            ?? loadBundledStreams()
            ?? StoredStreams(streams: [:], order: [])
        let storedOrder = stored.order ?? UserDefaults.standard.stringArray(forKey: orderDefaultsKey)
        let orderedNames = storedOrder ?? Array(stored.streams.keys)
        streams = orderedNames.compactMap { name in
            stored.streams[name].map { Stream(
                name: name,
                url: $0.url,
                category: $0.category ?? StreamCategory.inferred(from: $0.url),
                isFavourite: $0.isFavourite
            ) }
        }
        selectedStreamID = streams.first?.id
    }

    private func save() {
        UserDefaults.standard.set(streams.map(\.name), forKey: orderDefaultsKey)
        let stored = StoredStreams(
            streams: Dictionary(uniqueKeysWithValues: streams.map { ($0.name, StoredStream(url: $0.url, category: $0.category, isFavourite: $0.isFavourite)) }),
            order: streams.map(\.name)
        )
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("Could not save streams: \(error)")
        }
    }

    private var storageURL: URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("BBCD4 Mac", isDirectory: true)
            .appendingPathComponent("streams.json")
    }

    private func loadBundledStreams() -> StoredStreams? {
        guard let url = AppResources.url(
            forResource: "default-streams", withExtension: "json"
        ) else {
            return nil
        }
        return loadStoredStreams(from: url)
    }

    private func loadStoredStreams(from url: URL) -> StoredStreams? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredStreams.self, from: data)
    }

    private static func isSupportedURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return false
        }
        let path = url.path.lowercased()
        return ["https", "http"].contains(scheme)
            && (path.hasSuffix(".mpd") || path.hasSuffix(".m3u8"))
    }
}

enum StreamError: LocalizedError {
    case missingDetails
    case invalidURL
    case duplicateName
    case duplicateURL

    var errorDescription: String? {
        switch self {
        case .missingDetails:
            "Enter both a stream name and URL."
        case .invalidURL:
            "Enter either an .mpd or .m3u8 link."
        case .duplicateName:
            "Stream name already exists."
        case .duplicateURL:
            "Stream URL already exists."
        }
    }
}
