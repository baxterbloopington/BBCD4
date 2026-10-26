import Foundation
import Combine
import Testing
@testable import BBCD4Mac

private final class IsolatedDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "BBCD4-tests-\(UUID())")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

private func legacyRequest(duration: Int = 60) -> [String: Any] {
    ["stream": ["name": "Legacy radio", "url": "https://example.test/audio/index.mpd"],
     "start": 800_000_000, "duration": duration, "outputFolder": "file:///private/tmp/BBCD4-tests/",
     "encodeH265": true]
}

@Test func legacyQueueFieldsAndEncodingArePreserved() throws {
    let request = try JSONDecoder().decode(DownloadRequest.self, from: json(legacyRequest()))
    #expect(request.stream.category == .radio)
    #expect(!request.stream.isFavourite)
    #expect(request.stream.groupID == nil)
    #expect(request.filenameFormat == .firstSegment)
    #expect(request.encodingConfiguration == EncodingConfiguration(method: .software, quality: .standard))
    #expect(request.maximumConcurrentSegments == 5)
    #expect(request.retryAttempts == 3)
    #expect(request.retryDelay == 2)
    let roundTrip = try JSONDecoder().decode(DownloadRequest.self, from: JSONEncoder().encode(request))
    #expect(roundTrip.stream == request.stream)
    #expect(roundTrip.encodingConfiguration == request.encodingConfiguration)
}

@Test @MainActor func queueRecoversNeighborsAndBacksUpOriginal() throws {
    let defaults = IsolatedDefaults()
    let id = UUID().uuidString
    let original = try json([["id": id, "request": legacyRequest()],
                             ["request": legacyRequest(duration: -1)],
                             ["id": id, "request": legacyRequest()]])
    defaults.set(original, forKey: "BBCD4Mac.downloadQueue")
    defaults.set(true, forKey: "BBCD4Mac.downloadQueuePaused")
    let controller = DownloadController(defaults: defaults, automaticallyStartsQueue: false)
    #expect(controller.queue.count == 2)
    #expect(Set(controller.queue.map(\.id)).count == 2)
    #expect(controller.isQueuePaused)
    #expect(!controller.isDownloading)
    controller.removeQueuedDownload(controller.queue[0])
    let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("BBCD4Mac.downloadQueue.recovery-") }
    #expect(backups.count == 1)
    #expect(backups.values.first as? Data == original)
    let restored = DownloadController(defaults: defaults, automaticallyStartsQueue: false)
    #expect(restored.queue.count == 1)
}

@Test @MainActor func unreadableQueueIsNotOverwrittenOnLaunch() throws {
    let defaults = IsolatedDefaults()
    let original = Data("not JSON".utf8)
    defaults.set(original, forKey: "BBCD4Mac.downloadQueue")
    let controller = DownloadController(defaults: defaults, automaticallyStartsQueue: false)
    #expect(controller.queue.isEmpty)
    #expect(defaults.data(forKey: "BBCD4Mac.downloadQueue") == original)
    controller.clearQueue()
    #expect(defaults.dictionaryRepresentation().contains { $0.key.contains(".recovery-") && ($0.value as? Data) == original })
}

@Test @MainActor func streamRecoveryPreservesOrderAndHealthyEntries() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bbcd4-upgrade-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("streams.json")
    let groupID = UUID()
    let original = try json([
        "streams": ["Radio": "https://example.test/audio/index.mpd",
                    "TV": ["url": "https://example.test/video.mpd", "isFavourite": true, "groupID": groupID.uuidString],
                    "Broken": ["url": 12]],
        "order": ["TV", "Radio", "TV"],
        "groups": [["id": groupID.uuidString, "name": "News"],
                   ["id": groupID.uuidString, "name": "Duplicate"],
                   ["id": UUID().uuidString, "name": "news"], ["name": "Malformed"]]
    ])
    try original.write(to: url)
    let store = StreamStore(storageURL: url, defaults: IsolatedDefaults())
    #expect(store.streams.map(\.name) == ["TV", "Radio"])
    #expect(store.streams[0].isFavourite)
    #expect(store.streams[1].category == .radio)
    #expect(store.groups.map(\.name) == ["News"])
    #expect(try Data(contentsOf: url) == original)
    var publishes = 0
    let observer = store.$streams.dropFirst().sink { _ in publishes += 1 }
    store.setFavourite(true, for: Set(store.streams.map(\.id)))
    #expect(publishes == 1)
    store.setFavourite(true, for: Set(store.streams.map(\.id)))
    #expect(publishes == 1)
    withExtendedLifetime(observer) {}
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".recovery-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    let restored = StreamStore(storageURL: url, defaults: IsolatedDefaults())
    #expect(restored.streams == store.streams)
    #expect(restored.groups == store.groups)
    #expect(throws: StreamError.self) { try store.renameGroup(groupID, name: "Ungrouped") }
    #expect(store.groups[0].name == "News")
}

@Test @MainActor func timeNormalizationUsesInjectedPreferences() throws {
    let defaults = IsolatedDefaults()
    defaults.set(["1:02", "01:02:00", "invalid"], forKey: "BBCD4Mac.startTimeOptions")
    let times = TimeOptionsStore(defaults: defaults)
    #expect(times.options == ["01:02:00"])
    #expect(defaults.stringArray(forKey: "BBCD4Mac.startTimeOptions") == times.options)
    try times.add(lines: "03:45")
    #expect(defaults.stringArray(forKey: "BBCD4Mac.startTimeOptions") == ["01:02:00", "03:45:00"])
}

@Test @MainActor func migrationsPreserveExistingChoices() {
    let defaults = IsolatedDefaults()
    defaults.set(false, forKey: "checkForUpdates")
    UpdateCheckFrequency.migratePreferences(in: defaults)
    #expect(defaults.string(forKey: UpdateCheckFrequency.preferenceKey) == "never")
    defaults.set("hourly", forKey: UpdateCheckFrequency.preferenceKey)
    defaults.set(false, forKey: "checkForUpdates")
    UpdateCheckFrequency.migratePreferences(in: defaults)
    #expect(defaults.string(forKey: UpdateCheckFrequency.preferenceKey) == "hourly")
    defaults.set(false, forKey: "downloadStartInAppNotification")
    DownloadNotifications.migrateLegacyPreferenceIfNeeded(in: defaults)
    #expect(!defaults.bool(forKey: "downloadStartInAppNotification"))
    #expect(!defaults.bool(forKey: "downloadStartSystemNotification"))
    let first = defaults.dictionaryRepresentation() as NSDictionary
    DownloadNotifications.migrateLegacyPreferenceIfNeeded(in: defaults)
    #expect(first == defaults.dictionaryRepresentation() as NSDictionary)
    let fresh = IsolatedDefaults()
    UpdateCheckFrequency.migratePreferences(in: fresh)
    #expect(fresh.string(forKey: UpdateCheckFrequency.preferenceKey) == "onLaunch")
    #expect(StreamAvailabilityPreferences.defaultEnabled)
    #expect(StreamAvailabilityPreferences.defaultInterval == 0)
}

@Test func encodingConfigurationRecoversFieldsIndependently() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(EncodingConfiguration.self, from: json([:])) == .defaults)
    #expect(try decoder.decode(EncodingConfiguration.self, from: json(["method": "software", "quality": "unknown"])) == EncodingConfiguration(method: .software, quality: .high))
    #expect(try decoder.decode(EncodingConfiguration.self, from: json(["method": "software", "quality": "best"])).quality == .high)
    #expect(DownloadLimits.retryDelay(.nan) == 2)
    #expect(DownloadLimits.retryDelay(.infinity) == 2)
}

@Test func malformedSegmentTimingFailsSafely() throws {
    let reference = Date(timeIntervalSince1970: 1_000)
    #expect(try DownloadEngine.segmentRange(start: reference.addingTimeInterval(-6), duration: 10, referenceStart: reference, referenceSegment: 100, segmentDuration: 4) == 98...100)
    for duration in [0.0, -1, .nan, .infinity, 0.000_001] {
        #expect(throws: DownloadError.self) { try DownloadEngine.segmentRange(start: reference, duration: 60, referenceStart: reference, referenceSegment: 100, segmentDuration: duration) }
    }
    #expect(throws: DownloadError.self) { try DownloadEngine.segmentRange(start: reference, duration: 60, referenceStart: reference, referenceSegment: Int.max, segmentDuration: 4) }
}

@Test func processDiagnosticsAreBoundedAndCannotBlockCompletion() async throws {
    let buffer = BoundedProcessOutput(limit: 10)
    buffer.append(Data(repeating: 65, count: 100_000))
    buffer.append(Data("END".utf8))
    #expect(buffer.message == "AAAAAAAEND")
    try await MediaProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do echo diagnostic-line >&2; i=$((i+1)); done"])
    do {
        try await MediaProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo expected-failure >&2; exit 2"])
        Issue.record("Nonzero exit should fail")
    } catch { #expect(error.localizedDescription.contains("expected-failure")) }
}

@Test func processCancellationFinishesPromptly() async throws {
    let task = Task { try await MediaProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do :; done"]) }
    try await Task.sleep(for: .milliseconds(150))
    let started = Date()
    task.cancel()
    do { try await task.value; Issue.record("Cancellation should throw") }
    catch { #expect(error is CancellationError) }
    #expect(Date().timeIntervalSince(started) < 3)
}
