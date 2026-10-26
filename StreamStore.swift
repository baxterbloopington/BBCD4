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
    var groupID: UUID? = nil

    var id: String { name }
}

extension Stream {
    private enum CodingKeys: String, CodingKey { case name, url, category, isFavourite, groupID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        url = try values.decode(String.self, forKey: .url)
        category = (try? values.decode(StreamCategory.self, forKey: .category)) ?? .inferred(from: url)
        isFavourite = (try? values.decode(Bool.self, forKey: .isFavourite)) ?? false
        groupID = try? values.decode(UUID.self, forKey: .groupID)
    }
}

struct StreamGroup: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String

    static func validatedName(_ value: String, in groups: [StreamGroup], excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StreamError.missingGroupName }
        guard name.caseInsensitiveCompare("Ungrouped") != .orderedSame else { throw StreamError.reservedGroupName }
        guard !groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw StreamError.duplicateGroupName
        }
        return name
    }
}

struct StreamGroupSection: Identifiable, Sendable {
    let id: UUID?
    let title: String?
    let streams: [Stream]
}

enum StreamGrouping {
    static func searchSections(for streams: [Stream], groups: [StreamGroup], query: String) -> [StreamGroupSection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections(for: streams, groups: groups, includeEmptyGroups: true) }
        let membersByGroup = Dictionary(grouping: streams, by: \.groupID)
        var result = groups.compactMap { group -> StreamGroupSection? in
            let matchesGroup = group.name.localizedCaseInsensitiveContains(query)
            let members = (membersByGroup[group.id] ?? []).filter {
                matchesGroup || $0.name.localizedCaseInsensitiveContains(query)
            }
            guard matchesGroup || !members.isEmpty else { return nil }
            return StreamGroupSection(id: group.id, title: group.name, streams: members)
        }
        let ids = Set(groups.map(\.id))
        let matchesUngrouped = !groups.isEmpty && "Ungrouped".localizedCaseInsensitiveContains(query)
        let ungrouped = streams.filter {
            ($0.groupID.map { !ids.contains($0) } ?? true) && (matchesUngrouped || $0.name.localizedCaseInsensitiveContains(query))
        }
        if !ungrouped.isEmpty || matchesUngrouped {
            result.append(StreamGroupSection(id: nil, title: groups.isEmpty ? nil : "Ungrouped", streams: ungrouped))
        }
        return result
    }

    static func sections(for streams: [Stream], groups: [StreamGroup], includeEmptyGroups: Bool = false) -> [StreamGroupSection] {
        let membersByGroup = Dictionary(grouping: streams, by: \.groupID)
        var sections = groups.compactMap { group -> StreamGroupSection? in
            let members = membersByGroup[group.id] ?? []
            return members.isEmpty && !includeEmptyGroups ? nil : StreamGroupSection(id: group.id, title: group.name, streams: members)
        }
        let groupIDs = Set(groups.map(\.id))
        let ungrouped = streams.filter { stream in
            stream.groupID.map { !groupIDs.contains($0) } ?? true
        }
        if !ungrouped.isEmpty || (includeEmptyGroups && !groups.isEmpty) {
            sections.append(StreamGroupSection(id: nil, title: sections.isEmpty ? nil : "Ungrouped", streams: ungrouped))
        }
        return sections
    }
}

enum StreamAvailabilityPreferences {
    static let enabledKey = "checkStreamAvailability"
    static let defaultEnabled = true
    static let intervalKey = "streamAvailabilityInterval"
    static let startInAppKey = "streamStatusCheckStartInAppNotification"
    static let startSystemKey = "streamStatusCheckStartSystemNotification"
    static let maximumConcurrentChecks = 8
    static let activeOnlineOnlyKey = "activeOnlineStreamsOnly"
    static let defaultInterval = 0
    static let intervals = [0, 60, 300, 1_800, 3_600]

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "On app launch"
        case 60: "Every minute"
        case 3_600: "Every hour"
        default: "Every \(seconds / 60) minutes"
        }
    }
}

enum StreamAvailabilityState: Sendable {
    case unknown, online, offline

    var title: String {
        switch self {
        case .unknown: "Not checked yet"
        case .online: "Online"
        case .offline: "Offline or unreachable"
        }
    }
}

struct StreamAvailabilityResult: Sendable {
    let state: StreamAvailabilityState
    let checkedAt: Date
}

struct StreamStatusCheckStarted: Identifiable, Sendable {
    let id = UUID()
    let streamCount: Int

    var message: String {
        "Checking status of \(streamCount) \(streamCount == 1 ? "stream" : "streams")…"
    }
}

struct StreamListFilter: Sendable {
    var category: StreamCategory?
    var favouritesOnly = false
    var onlineOnly = false

    func matches(_ stream: Stream, availability: StreamAvailabilityState?) -> Bool {
        (category == nil || stream.category == category)
            && (!favouritesOnly || stream.isFavourite)
            && (!onlineOnly || availability == .online)
    }
}

struct StreamAvailabilitySchedule: Hashable, Sendable {
    let isEnabled: Bool
    let interval: Int
    let urls: [String]
    let refreshID: UUID?

    init(isEnabled: Bool, interval: Int, urls: [String], refreshID: UUID? = nil) {
        self.isEnabled = isEnabled
        self.interval = StreamAvailabilityPreferences.intervals.contains(interval)
            ? interval : StreamAvailabilityPreferences.defaultInterval
        var seen = Set<String>()
        self.urls = urls.filter { seen.insert($0).inserted }
        self.refreshID = refreshID
    }
}

@MainActor
final class StreamAvailabilityMonitor: ObservableObject {
    @Published private(set) var results: [String: StreamAvailabilityResult] = [:]
    @Published private(set) var checkingURLs: Set<String> = []
    @Published private(set) var isChecking = false
    @Published private(set) var refreshID: UUID?
    @Published private(set) var lastCheckStarted: StreamStatusCheckStarted?
    private let check: @Sendable (String) async throws -> Bool
    private var generation = UUID()
    private var handledRefreshID: UUID?
    private var knownURLs: Set<String> = []
    private var pendingChecks: [String] = []
    private var manualCheckTask: Task<Void, Never>?
    private var isEnabled = false

    init(check: @escaping @Sendable (String) async throws -> Bool = DownloadEngine.streamIsAvailable) {
        self.check = check
    }

    func requestRefresh() {
        guard !isChecking, checkingURLs.isEmpty else { return }
        refreshID = UUID()
    }

    func requestCheck(for url: String) {
        guard isEnabled, knownURLs.contains(url), checkingURLs.insert(url).inserted else { return }
        pendingChecks.append(url)
        startPendingChecks()
    }

    private func startPendingChecks() {
        guard !isChecking, manualCheckTask == nil, !pendingChecks.isEmpty else { return }
        let generation = self.generation
        manualCheckTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.manualCheckTask = nil
                    self.startPendingChecks()
                }
            }
            guard !Task.isCancelled, self.generation == generation, !self.isChecking else { return }
            let urls = self.pendingChecks
            self.pendingChecks.removeAll()
            await self.scan(urls, generation: generation)
        }
    }

    func run(_ schedule: StreamAvailabilitySchedule) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        self.generation = generation
        manualCheckTask?.cancel()
        manualCheckTask = nil
        pendingChecks.removeAll()
        checkingURLs.removeAll()
        knownURLs = Set(schedule.urls)
        isEnabled = schedule.isEnabled
        isChecking = false
        let isManualRefresh = schedule.refreshID != nil && schedule.refreshID != handledRefreshID
        handledRefreshID = schedule.refreshID
        results = schedule.isEnabled ? results.filter { knownURLs.contains($0.key) } : [:]
        guard schedule.isEnabled, !schedule.urls.isEmpty else { return }
        if schedule.interval == 0 {
            let urls = isManualRefresh ? schedule.urls : schedule.urls.filter { results[$0] == nil }
            await scan(urls, generation: generation)
            return
        }
        let clock = ContinuousClock()
        var nextScan = clock.now
        while !Task.isCancelled, self.generation == generation {
            await scan(schedule.urls, generation: generation)
            guard !Task.isCancelled, self.generation == generation else { return }
            // Skip missed ticks instead of overlapping scans or immediately
            // starting another large scan after a slow network response.
            repeat { nextScan += .seconds(schedule.interval) } while nextScan <= clock.now
            do { try await clock.sleep(until: nextScan) } catch { return }
        }
    }

    private func scan(_ urls: [String], generation: UUID) async {
        guard !urls.isEmpty, !Task.isCancelled, self.generation == generation, !isChecking else { return }
        pendingChecks.removeAll { urls.contains($0) }
        isChecking = true
        checkingURLs.formUnion(urls)
        lastCheckStarted = StreamStatusCheckStarted(streamCount: urls.count)
        defer {
            if self.generation == generation {
                checkingURLs.subtract(urls)
                isChecking = false
                startPendingChecks()
            }
        }
        let check = self.check
        await withTaskGroup(of: (String, StreamAvailabilityResult?).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard !Task.isCancelled, nextIndex < urls.count else { return }
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask(priority: .background) {
                    do {
                        let available = try await check(url)
                        try Task.checkCancellation()
                        return (url, StreamAvailabilityResult(state: available ? .online : .offline, checkedAt: Date()))
                    } catch {
                        guard !Task.isCancelled, !(error is CancellationError) else { return (url, nil) }
                        return (url, StreamAvailabilityResult(state: .offline, checkedAt: Date()))
                    }
                }
            }
            for _ in 0..<min(StreamAvailabilityPreferences.maximumConcurrentChecks, urls.count) { enqueueNext() }
            while let (url, result) = await group.next() {
                guard !Task.isCancelled, self.generation == generation else {
                    group.cancelAll()
                    return
                }
                if let result { results[url] = result }
                checkingURLs.remove(url)
                enqueueNext()
            }
        }
    }
}

private struct StoredStream: Codable {
    var url: String
    var category: StreamCategory?
    var isFavourite: Bool
    var groupID: UUID?

    init(url: String, category: StreamCategory?, isFavourite: Bool = false, groupID: UUID? = nil) {
        self.url = url
        self.category = category
        self.isFavourite = isFavourite
        self.groupID = groupID
    }

    init(from decoder: Decoder) throws {
        if let url = try? decoder.singleValueContainer().decode(String.self) {
            self.init(url: url, category: nil)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(String.self, forKey: .url),
            category: try? container.decode(StreamCategory.self, forKey: .category),
            isFavourite: (try? container.decode(Bool.self, forKey: .isFavourite)) ?? false,
            groupID: try? container.decode(UUID.self, forKey: .groupID)
        )
    }
}

private struct StoredStreams: Codable {
    var streams: [String: StoredStream]
    var order: [String]?
    var groups: [StreamGroup]? = nil
    var needsRecovery = false

    private enum CodingKeys: String, CodingKey { case streams, order, groups }

    init(streams: [String: StoredStream], order: [String]?, groups: [StreamGroup]? = nil) {
        self.streams = streams
        self.order = order
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([String: RecoverableValue<StoredStream>].self, forKey: .streams)
        streams = entries.compactMapValues(\.value)
        needsRecovery = streams.count != entries.count
        order = try? container.decode([String].self, forKey: .order)
        if container.contains(.groups), (try? container.decodeNil(forKey: .groups)) != true {
            if let decoded = try? container.decode(RecoverableArray<StreamGroup>.self, forKey: .groups) {
                groups = decoded.values
                needsRecovery = needsRecovery || decoded.skippedCount > 0
            } else {
                groups = []
                needsRecovery = true
            }
        }
    }
}

@MainActor
final class StreamStore: ObservableObject {
    @Published private(set) var streams: [Stream] = []
    @Published private(set) var groups: [StreamGroup] = []
    @Published var selectedStreamID: String?

    private let fileManager = FileManager.default
    private let orderDefaultsKey = "BBCD4Mac.streamOrder"
    private let storageURL: URL
    private let defaults: UserDefaults
    private var recoveryData: Data?

    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BBCD4 Mac", isDirectory: true)
            .appendingPathComponent("streams.json")
        load()
    }

    var selectedStream: Stream? {
        streams.first { $0.id == selectedStreamID }
    }

    func add(name: String, url: String, category: StreamCategory, groupID: UUID? = nil) throws {
        try validateGroup(groupID)
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

        streams.append(Stream(name: cleanedName, url: cleanedURL, category: category, groupID: groupID))
        selectedStreamID = cleanedName
        save()
    }

    func update(originalName: String, name: String, url: String, category: StreamCategory, groupID: UUID?) throws {
        try validateGroup(groupID)
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
            isFavourite: streams[index].isFavourite,
            groupID: groupID
        )
        selectedStreamID = cleanedName
        save()
    }

    func setCategory(_ category: StreamCategory, for ids: Set<String>) {
        updateStreams(ids) { $0.category = category }
    }

    func setFavourite(_ favourite: Bool, for ids: Set<String>) {
        updateStreams(ids) { $0.isFavourite = favourite }
    }

    @discardableResult
    func addGroup(name: String) throws -> UUID {
        let group = StreamGroup(name: try StreamGroup.validatedName(name, in: groups))
        groups.append(group)
        save()
        return group.id
    }

    func renameGroup(_ id: UUID, name: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw StreamError.missingGroup }
        let validatedName = try StreamGroup.validatedName(name, in: groups, excluding: id)
        guard groups[index].name != validatedName else { return }
        groups[index].name = validatedName
        save()
    }

    func deleteGroup(_ id: UUID) {
        deleteGroups([id])
    }

    func deleteGroups(_ ids: Set<UUID>) {
        guard groups.contains(where: { ids.contains($0.id) }) else { return }
        groups.removeAll { ids.contains($0.id) }
        var updated = streams
        for index in updated.indices {
            if let groupID = updated[index].groupID, ids.contains(groupID) { updated[index].groupID = nil }
        }
        if updated != streams { streams = updated }
        save()
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        save()
    }

    @discardableResult
    func moveGroup(_ id: UUID, relativeTo target: UUID?, after: Bool) -> Bool {
        guard id != target, let source = groups.firstIndex(where: { $0.id == id }) else { return false }
        let destination: Int
        if let target {
            guard let index = groups.firstIndex(where: { $0.id == target }) else { return false }
            destination = index + (after ? 1 : 0)
        } else {
            destination = groups.endIndex
        }
        guard destination != source && destination != source + 1 else { return false }
        moveGroups(fromOffsets: IndexSet(integer: source), toOffset: destination)
        return true
    }

    @discardableResult
    func moveStreams(_ ids: [String], toGroup groupID: UUID?, relativeTo anchor: String? = nil, after: Bool = false) throws -> Bool {
        try validateGroup(groupID)
        var seen = Set<String>()
        let byID = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0) })
        let moving = ids.compactMap { id -> Stream? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        guard !moving.isEmpty else { return false }
        let movingIDs = Set(moving.map(\.id))
        if let anchor {
            guard !movingIDs.contains(anchor), streams.contains(where: { $0.id == anchor && $0.groupID == groupID }) else { return false }
        }
        var reordered = streams.filter { !movingIDs.contains($0.id) }
        let destination: Int
        if let anchor, let index = reordered.firstIndex(where: { $0.id == anchor }) {
            destination = index + (after ? 1 : 0)
        } else if let last = reordered.lastIndex(where: { $0.groupID == groupID }) {
            destination = last + 1
        } else {
            destination = reordered.endIndex
        }
        let assigned = moving.map { stream in
            var updated = stream
            updated.groupID = groupID
            return updated
        }
        reordered.insert(contentsOf: assigned, at: destination)
        guard reordered != streams else { return false }
        streams = reordered
        save()
        return true
    }

    func setGroup(_ groupID: UUID?, for streamIDs: Set<String>) throws {
        try validateGroup(groupID)
        updateStreams(streamIDs) { $0.groupID = groupID }
    }

    private func updateStreams(_ ids: Set<String>, change: (inout Stream) -> Void) {
        var updated = streams
        for index in updated.indices where ids.contains(updated[index].id) { change(&updated[index]) }
        guard updated != streams else { return }
        streams = updated
        save()
    }

    private func validateGroup(_ id: UUID?) throws {
        if let id, !groups.contains(where: { $0.id == id }) { throw StreamError.missingGroup }
    }

    func deleteStreams(_ ids: Set<String>) {
        guard streams.contains(where: { ids.contains($0.id) }) else { return }
        let index = streams.firstIndex { $0.id == selectedStreamID } ?? 0
        streams.removeAll { ids.contains($0.id) }
        if let selectedStreamID, ids.contains(selectedStreamID) {
            self.selectedStreamID = streams.isEmpty ? nil : streams[min(index, streams.count - 1)].id
        }
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
        var ids = Set<UUID>()
        var groupNames = Set<String>()
        groups = (stored.groups ?? []).compactMap { group in
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.caseInsensitiveCompare("Ungrouped") != .orderedSame,
                  !ids.contains(group.id), !groupNames.contains(name.lowercased()) else { return nil }
            ids.insert(group.id)
            groupNames.insert(name.lowercased())
            return StreamGroup(id: group.id, name: name)
        }
        if stored.needsRecovery || groups != (stored.groups ?? []) {
            recoveryData = try? Data(contentsOf: storageURL)
        }
        let groupIDs = Set(groups.map(\.id))
        let storedOrder = stored.order ?? defaults.stringArray(forKey: orderDefaultsKey)
        let orderedNames = storedOrder ?? stored.streams.keys.sorted()
        var seen = Set<String>()
        let names = (orderedNames + stored.streams.keys.sorted()).filter { seen.insert($0).inserted }
        streams = names.compactMap { name in
            stored.streams[name].map { entry in Stream(
                name: name,
                url: entry.url,
                category: entry.category ?? StreamCategory.inferred(from: entry.url),
                isFavourite: entry.isFavourite,
                groupID: entry.groupID.flatMap { groupIDs.contains($0) ? $0 : nil }
            ) }
        }
        selectedStreamID = streams.first?.id
    }

    private func save() {
        defaults.set(streams.map(\.name), forKey: orderDefaultsKey)
        let stored = StoredStreams(
            streams: Dictionary(uniqueKeysWithValues: streams.map { ($0.name, StoredStream(url: $0.url, category: $0.category, isFavourite: $0.isFavourite, groupID: $0.groupID)) }),
            order: streams.map(\.name),
            groups: groups
        )
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let recoveryData {
                let backup = storageURL.appendingPathExtension("recovery-\(UUID().uuidString)")
                try recoveryData.write(to: backup, options: .withoutOverwriting)
                self.recoveryData = nil
            }
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("Could not save streams: \(error)")
        }
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
        do { return try JSONDecoder().decode(StoredStreams.self, from: data) }
        catch {
            if url == storageURL { recoveryData = data }
            return nil
        }
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
    case missingGroupName
    case duplicateGroupName
    case reservedGroupName
    case missingGroup

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
        case .missingGroupName:
            "Enter a group name."
        case .duplicateGroupName:
            "A group with this name already exists."
        case .reservedGroupName:
            "Choose a name other than Ungrouped."
        case .missingGroup:
            "This group no longer exists. Choose another group or Ungrouped."
        }
    }
}
