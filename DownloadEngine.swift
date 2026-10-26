import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum EncodingMethod: String, Codable, CaseIterable, Sendable {
    case software, hardware
    var title: String {
        self == .software ? "Software (Slower, smaller file size)" : "Hardware (Faster, larger file size)"
    }
}

enum EncodingQuality: String, Codable, CaseIterable, Sendable {
    case high, standard
    var title: String { rawValue.capitalized }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let storedValue = try container.decode(String.self)
        if storedValue == "best" {
            self = .high
        } else if let quality = Self(rawValue: storedValue) {
            self = quality
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown encoding quality")
        }
    }
    var softwareCRF: String {
        switch self {
        case .high: "16"
        case .standard: "28"
        }
    }
    var hardwareQuality: String {
        switch self {
        case .high: "80"
        case .standard: "65"
        }
    }
}

struct EncodingConfiguration: Codable, Equatable, Sendable {
    static let preferenceKey = "encodingConfigurationV1"
    static let defaultEnabled = true
    static let defaults = EncodingConfiguration()
    var method: EncodingMethod = .hardware
    var quality: EncodingQuality = .high

    init(method: EncodingMethod = .hardware, quality: EncodingQuality = .high) {
        self.method = method
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey { case method, quality }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = (try? values.decode(EncodingMethod.self, forKey: .method)) ?? .hardware
        quality = (try? values.decode(EncodingQuality.self, forKey: .quality)) ?? .high
    }

    static func load() -> EncodingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults }
        return value
    }

    func videoArguments() -> [String] {
        switch method {
        case .software:
            return ["-c:v", "libx265", "-tag:v", "hvc1", "-crf", quality.softwareCRF,
                    "-preset", "ultrafast", "-c:a", "copy"]
        case .hardware:
            return ["-c:v", "hevc_videotoolbox", "-allow_sw", "0",
                    "-q:v", quality.hardwareQuality, "-tag:v", "hvc1", "-c:a", "copy"]
        }
    }
}

enum DownloadFilenameFormat: String, CaseIterable, Sendable, Hashable, Codable {
    case firstSegment, startDateTime, startTime
    case currentDateTime, streamNameRandom, random, askEachTime
    static let defaultFormat = Self.streamNameRandom

    var title: String {
        switch self {
        case .firstSegment: "Stream name - first segment"
        case .startDateTime: "Stream name - start date - start time"
        case .startTime: "Stream name - start time"
        case .currentDateTime: "Stream name - current date - current time"
        case .streamNameRandom: "Stream name - random 10-character string"
        case .random: "Random 10-character string"
        case .askEachTime: "Ask each time"
        }
    }
}

struct DownloadRequest: Sendable, Codable {
    let stream: Stream
    let start: Date
    let duration: Int
    let outputFolder: URL
    let encodeH265: Bool
    let retryAttempts: Int
    let retryDelay: Double
    let maximumConcurrentSegments: Int
    let filenameFormat: DownloadFilenameFormat
    // Optional for compatibility with queues saved before encoding settings existed.
    var encodingConfiguration: EncodingConfiguration? = nil
}

extension DownloadRequest {
    private enum CodingKeys: String, CodingKey {
        case stream, start, duration, outputFolder, encodeH265, retryAttempts, retryDelay
        case maximumConcurrentSegments, filenameFormat, encodingConfiguration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stream = try values.decode(Stream.self, forKey: .stream)
        start = try values.decode(Date.self, forKey: .start)
        duration = try values.decode(Int.self, forKey: .duration)
        outputFolder = try values.decode(URL.self, forKey: .outputFolder)
        guard (1...DownloadLimits.maximumDuration).contains(duration), start.timeIntervalSince1970.isFinite,
              outputFolder.isFileURL else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid saved download range or folder"))
        }
        encodeH265 = (try? values.decode(Bool.self, forKey: .encodeH265)) ?? false
        retryAttempts = min(10, max(1, (try? values.decode(Int.self, forKey: .retryAttempts)) ?? 3))
        retryDelay = DownloadLimits.retryDelay((try? values.decode(Double.self, forKey: .retryDelay)) ?? 2)
        maximumConcurrentSegments = min(50, max(1, (try? values.decode(Int.self, forKey: .maximumConcurrentSegments)) ?? 5))
        filenameFormat = (try? values.decode(DownloadFilenameFormat.self, forKey: .filenameFormat)) ?? .firstSegment
        encodingConfiguration = try? values.decode(EncodingConfiguration.self, forKey: .encodingConfiguration)
        if encodingConfiguration == nil, encodeH265 {
            encodingConfiguration = EncodingConfiguration(method: .software, quality: .standard)
        }
    }
}

struct QueuedDownload: Identifiable, Codable, Sendable {
    let id: UUID
    let request: DownloadRequest

    init(id: UUID = UUID(), request: DownloadRequest) {
        self.id = id
        self.request = request
    }
}

extension QueuedDownload {
    private enum CodingKeys: String, CodingKey { case id, request }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        request = try values.decode(DownloadRequest.self, forKey: .request)
    }
}

struct DownloadUpdate: Sendable {
    let status: String
    let progress: Double
}

enum PartialDownloadKind: Sendable {
    case mpd
    case fmp4
    case transportStream
}

struct IncompleteDownload: Identifiable, Sendable {
    let id = UUID()
    let request: DownloadRequest
    let workspace: URL
    let kind: PartialDownloadKind
    let segments: [Int]
    let failedSegments: [Int]
    let output: URL
    let firstAvailableSegment: Int?

    init(
        request: DownloadRequest,
        workspace: URL,
        kind: PartialDownloadKind,
        segments: [Int],
        failedSegments: [Int],
        output: URL,
        firstAvailableSegment: Int? = nil
    ) {
        self.request = request
        self.workspace = workspace
        self.kind = kind
        self.segments = segments
        self.failedSegments = failedSegments
        self.output = output
        self.firstAvailableSegment = firstAvailableSegment
    }
}

enum DownloadError: LocalizedError {
    case invalidStream
    case invalidDuration
    case futureTime
    case dateTooOld
    case radioDateTooOld
    case ffmpegMissing
    case failedSegments([Int])
    case incomplete(IncompleteDownload)
    case httpStatus(Int, URL)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidStream:
            "Only .mpd or .m3u8 streams are accepted."
        case .invalidDuration:
            "Choose media duration."
        case .futureTime:
            "Chosen time cannot be in the future."
        case .dateTooOld:
            "Chosen date must be within the past 14 days."
        case .radioDateTooOld:
            "Chosen date must be within the past 24 hours."
        case .ffmpegMissing:
            "ffmpeg was not found. Install it with Homebrew before downloading."
        case .failedSegments(let segments):
            "Some segments could not be downloaded: \(segments.prefix(3).map(String.init).joined(separator: ", "))."
        case .incomplete:
            "The stream ended or is not available for the complete requested time."
        case .httpStatus(let status, let url):
            "HTTP \(status): \(url.absoluteString)"
        case .processFailed(let message):
            message
        }
    }
}

enum NotificationDelivery: String, CaseIterable, Sendable, Hashable {
    case inApp = "In-app"
    case system = "System"
    case both = "All"
    case none = "None"

    var usesInAppPopup: Bool {
        self == .inApp || self == .both
    }

    var usesSystemNotification: Bool {
        self == .system || self == .both
    }
}

enum NotificationEventDelivery: String, CaseIterable, Sendable, Hashable {
    case useDefault = "Use default"
    case inApp = "In-app"
    case system = "System"
    case both = "All"
    case none = "None"

    func resolved(using defaultDelivery: NotificationDelivery) -> NotificationDelivery {
        switch self {
        case .useDefault: defaultDelivery
        case .inApp: .inApp
        case .system: .system
        case .both: .both
        case .none: .none
        }
    }
}

enum DownloadNotificationAction {
    static let completionCategoryIdentifier = "download-complete"
    static let showInFinderIdentifier = "show-in-finder"
}

@MainActor
enum DownloadNotifications {
    private static let preferenceKey = "downloadNotificationDelivery"
    private static let previousPreferenceKey = "downloadCompletionNotificationStyle"
    private static let legacyPreferenceKey = "downloadNotifications"
    private static let startPreferenceKey = "downloadStartNotificationDelivery"
    private static let completionPreferenceKey = "downloadCompletionNotificationDelivery"
    private static let failurePreferenceKey = "downloadFailureNotificationDelivery"
    private static let legacyStartPreferenceKey = "showDownloadStartNotification"
    private static let legacyCompletionPreferenceKey = "showDownloadCompletionNotification"
    private static let legacyFailurePreferenceKey = "showDownloadFailureNotification"
    private static let startInAppPreferenceKey = "downloadStartInAppNotification"
    private static let startSystemPreferenceKey = "downloadStartSystemNotification"
    private static let completionInAppPreferenceKey = "downloadCompletionInAppNotification"
    private static let completionSystemPreferenceKey = "downloadCompletionSystemNotification"
    private static let failureInAppPreferenceKey = "downloadFailureInAppNotification"
    private static let failureSystemPreferenceKey = "downloadFailureSystemNotification"

    static func migrateLegacyPreferenceIfNeeded(in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: preferenceKey) == nil {
            if let previousValue = defaults.string(forKey: previousPreferenceKey),
               NotificationDelivery(rawValue: previousValue) != nil {
                defaults.set(previousValue, forKey: preferenceKey)
            } else if defaults.object(forKey: legacyPreferenceKey) != nil {
                let delivery: NotificationDelivery = defaults.bool(forKey: legacyPreferenceKey) ? .both : .inApp
                defaults.set(delivery.rawValue, forKey: preferenceKey)
                defaults.removeObject(forKey: legacyPreferenceKey)
            }
        }

        migrateChannelPreferences(
            in: defaults,
            inAppKey: startInAppPreferenceKey,
            systemKey: startSystemPreferenceKey,
            eventDeliveryKey: startPreferenceKey,
            legacyKey: legacyStartPreferenceKey,
            defaultDelivery: .inApp
        )
        migrateChannelPreferences(
            in: defaults,
            inAppKey: completionInAppPreferenceKey,
            systemKey: completionSystemPreferenceKey,
            eventDeliveryKey: completionPreferenceKey,
            legacyKey: legacyCompletionPreferenceKey,
            defaultDelivery: .useDefault
        )
        migrateChannelPreferences(
            in: defaults,
            inAppKey: failureInAppPreferenceKey,
            systemKey: failureSystemPreferenceKey,
            eventDeliveryKey: failurePreferenceKey,
            legacyKey: legacyFailurePreferenceKey,
            defaultDelivery: .useDefault
        )
    }

    private static var startSystem: Bool { boolPreference(forKey: startSystemPreferenceKey) }
    private static var completionSystem: Bool { boolPreference(forKey: completionSystemPreferenceKey) }
    private static var failureInApp: Bool { boolPreference(forKey: failureInAppPreferenceKey) }
    private static var failureSystem: Bool { boolPreference(forKey: failureSystemPreferenceKey) }
    private static var streamCheckSystem: Bool {
        (UserDefaults.standard.object(forKey: StreamAvailabilityPreferences.enabledKey) as? Bool ?? StreamAvailabilityPreferences.defaultEnabled)
            && UserDefaults.standard.bool(forKey: StreamAvailabilityPreferences.startSystemKey)
    }

    static func requestPermission() {
        guard startSystem || completionSystem || failureSystem || streamCheckSystem else {
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static var showsInAppFailure: Bool { failureInApp }

    static func postStarted(request: DownloadRequest) {
        guard startSystem else { return }
        postSystemNotification(
            title: "Download started",
            body: startMessage(for: request)
        )
    }

    static func startMessage(for request: DownloadRequest) -> String {
        "Downloading \(request.stream.name) from \(formattedDateTime(request.start)) for \(formattedDuration(request.duration))."
    }

    static func inAppStartMessage(for request: DownloadRequest) -> String {
        "Downloading \(request.stream.name) for \(formattedDuration(request.duration))"
    }

    static func postStreamStatusCheckStarted(_ event: StreamStatusCheckStarted) {
        guard streamCheckSystem else { return }
        postSystemNotification(title: "Stream status check started", body: event.message)
    }

    static func postCompletion(request: DownloadRequest, output: URL) {
        guard completionSystem else { return }
        postSystemNotification(
            title: "Download complete!",
            body: completionMessage(for: request),
            userInfo: ["completedOutputPath": output.path],
            categoryIdentifier: DownloadNotificationAction.completionCategoryIdentifier
        )
    }

    static func completionMessage(for request: DownloadRequest) -> String {
        "Successfully downloaded \(request.stream.name) for \(formattedDuration(request.duration)) on \(formattedDateTime(request.start))."
    }

    static func postIncomplete(failedSegmentCount: Int, totalSegmentCount: Int) {
        guard failureSystem else { return }
        postSystemNotification(
            title: "Download incomplete",
            body: "Failed to download \(failedSegmentCount) of \(totalSegmentCount) segments."
        )
    }

    static func postFailure(request: DownloadRequest, message: String) {
        guard failureSystem else { return }
        postSystemNotification(
            title: "Download failed",
            body: "\(request.stream.name) (\(formattedDateTime(request.start))): \(message)"
        )
    }

    private static func formattedDateTime(_ date: Date) -> String {
        DateFormats.displayDateTime(
            date,
            format: UserDefaults.standard.string(forKey: "dateFormat") ?? "dd/MM/yyyy"
        )
    }

    private static func formattedDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        var components: [String] = []
        if hours > 0 { components.append("\(hours)h") }
        if minutes > 0 { components.append("\(minutes)m") }
        if seconds > 0 || components.isEmpty { components.append("\(seconds)s") }
        return components.joined(separator: " ")
    }

    private static func postSystemNotification(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        categoryIdentifier: String? = nil
    ) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            content.categoryIdentifier = categoryIdentifier ?? ""
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    private static func migrateChannelPreferences(
        in defaults: UserDefaults,
        inAppKey: String,
        systemKey: String,
        eventDeliveryKey: String,
        legacyKey: String,
        defaultDelivery: NotificationEventDelivery
    ) {
        guard defaults.object(forKey: inAppKey) == nil || defaults.object(forKey: systemKey) == nil else {
            return
        }

        let eventDelivery: NotificationEventDelivery
        if let value = defaults.string(forKey: eventDeliveryKey),
           let parsedValue = NotificationEventDelivery(rawValue: value) {
            eventDelivery = parsedValue
        } else if defaults.object(forKey: legacyKey) != nil {
            eventDelivery = defaults.bool(forKey: legacyKey) ? .useDefault : .none
        } else {
            eventDelivery = defaultDelivery
        }

        let defaultDelivery = NotificationDelivery(
            rawValue: defaults.string(forKey: preferenceKey) ?? ""
        ) ?? .inApp
        let resolvedDelivery = eventDelivery.resolved(using: defaultDelivery)
        if defaults.object(forKey: inAppKey) == nil {
            defaults.set(resolvedDelivery.usesInAppPopup, forKey: inAppKey)
        }
        if defaults.object(forKey: systemKey) == nil {
            defaults.set(resolvedDelivery.usesSystemNotification, forKey: systemKey)
        }
    }

    private static func boolPreference(forKey key: String) -> Bool {
        migrateLegacyPreferenceIfNeeded()
        return UserDefaults.standard.bool(forKey: key)
    }
}

@MainActor
final class DownloadController: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var progress = 0.0 {
        didSet { updateDockProgress() }
    }
    @Published private(set) var isDownloading = false {
        didSet { updateDockProgress() }
    }
    @Published var completedOutput: URL?
    @Published var completedRequest: DownloadRequest?
    @Published var errorMessage: String?
    @Published var incompleteDownload: IncompleteDownload?
    @Published private(set) var currentRequest: DownloadRequest?
    @Published private(set) var lastDownloadStarted: DownloadRequest?
    @Published private(set) var downloadStartID: UUID?
    @Published private(set) var lastDownloadStartedFromQueue = false
    @Published private(set) var queue: [QueuedDownload]
    @Published private(set) var isQueuePaused: Bool
    private var completionSequencePosition = 0
    private var activeTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var activeIncompleteDownload: IncompleteDownload?
    private let queueDefaultsKey = "BBCD4Mac.downloadQueue"
    private let queuePauseDefaultsKey = "BBCD4Mac.downloadQueuePaused"

    private let defaults: UserDefaults
    private var queueRecoveryData: Data?

    init(defaults: UserDefaults = .standard, automaticallyStartsQueue: Bool = true) {
        self.defaults = defaults
        let loaded = Self.loadQueue(in: defaults)
        queue = loaded.items
        queueRecoveryData = loaded.recovery
        isQueuePaused = defaults.bool(forKey: queuePauseDefaultsKey)
        if automaticallyStartsQueue {
            DispatchQueue.main.async { [weak self] in
                self?.startNextDownloadIfPossible()
            }
        }
    }

    private func updateDockProgress() {
        if isDownloading {
            DockDownloadProgress.shared.show(progress: progress)
        } else {
            DockDownloadProgress.shared.hide()
        }
    }

    func submit(_ request: DownloadRequest) {
        if isDownloading || incompleteDownload != nil {
            enqueue(request)
        } else {
            start(request)
        }
    }

    func enqueue(_ request: DownloadRequest) {
        queue.append(QueuedDownload(request: request))
        saveQueue()
        startNextDownloadIfPossible()
    }

    func removeQueuedDownload(_ item: QueuedDownload) {
        queue.removeAll { $0.id == item.id }
        saveQueue()
    }

    func moveQueuedDownloads(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        saveQueue()
    }

    func clearQueue() {
        queue.removeAll()
        saveQueue()
    }

    func toggleQueuePaused() {
        isQueuePaused.toggle()
        defaults.set(isQueuePaused, forKey: queuePauseDefaultsKey)

        if !isQueuePaused {
            startNextDownloadIfPossible()
        }
    }

    private func start(_ request: DownloadRequest, fromQueue: Bool = false) {
        guard !isDownloading else { return }
        if !playbackBatchActive {
            completionSequencePosition = 0
            playbackBatchActive = true
        }
        completedOutput = nil
        completedRequest = nil
        currentRequest = request
        lastDownloadStarted = request
        lastDownloadStartedFromQueue = fromQueue
        downloadStartID = UUID()
        isDownloading = true
        progress = 0
        status = "Preparing download…"
        DownloadNotifications.postStarted(request: request)
        let operationID = beginOperation()

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.run(request) { update in
                    await self.apply(update, operationID: operationID)
                }
                guard self.isCurrent(operationID) else { return }
                let namedOutput = try chooseCompletedFilename(for: request, output: output)
                recordCompletion(request: request, output: namedOutput)
                progress = 1
                status = "Done!"
                DownloadNotifications.postCompletion(request: request, output: namedOutput)
                finishOperation(operationID)
            } catch DownloadError.incomplete(let incomplete) {
                guard self.isCurrent(operationID) else { return }
                status = "Download incomplete"
                DownloadNotifications.postIncomplete(
                    failedSegmentCount: incomplete.failedSegments.count,
                    totalSegmentCount: incomplete.segments.count
                )
                resolveIncompleteDownload(incomplete, operationID: operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                errorMessage = error.localizedDescription
                status = "Error"
                DownloadNotifications.postFailure(request: request, message: error.localizedDescription)
                finishOperation(operationID)
            }
        }
    }

    func savePartialDownload() {
        guard let incomplete = incompleteDownload, !isDownloading else { return }
        incompleteDownload = nil
        currentRequest = incomplete.request
        isDownloading = true
        status = "Saving downloaded segments…"
        activeIncompleteDownload = incomplete
        let operationID = beginOperation()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.savePartial(incomplete) { update in
                    await self.apply(update, operationID: operationID)
                }
                guard self.isCurrent(operationID) else { return }
                let namedOutput = try chooseCompletedFilename(for: incomplete.request, output: output)
                recordCompletion(request: incomplete.request, output: namedOutput)
                progress = 1
                status = "Done!"
                DownloadNotifications.postCompletion(request: incomplete.request, output: namedOutput)
                finishOperation(operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                errorMessage = error.localizedDescription
                status = "Error"
                DownloadNotifications.postFailure(request: incomplete.request, message: error.localizedDescription)
                if DownloadNotifications.showsInAppFailure {
                    incompleteDownload = incomplete
                    finishOperation(operationID)
                } else {
                    DownloadEngine.discard(incomplete)
                    incompleteDownload = nil
                    errorMessage = nil
                    finishOperation(operationID)
                }
            }
        }
    }

    func retryIncompleteDownload() {
        guard let incomplete = incompleteDownload, !isDownloading else { return }
        incompleteDownload = nil
        currentRequest = incomplete.request
        isDownloading = true
        status = "Retrying from the failed segment…"
        activeIncompleteDownload = incomplete
        let operationID = beginOperation()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.retry(incomplete) { update in
                    await self.apply(update, operationID: operationID)
                }
                guard self.isCurrent(operationID) else { return }
                let namedOutput = try chooseCompletedFilename(for: incomplete.request, output: output)
                recordCompletion(request: incomplete.request, output: namedOutput)
                progress = 1
                status = "Done!"
                DownloadNotifications.postCompletion(request: incomplete.request, output: namedOutput)
                finishOperation(operationID)
            } catch DownloadError.incomplete(let nextIncomplete) {
                guard self.isCurrent(operationID) else { return }
                status = "Download incomplete"
                DownloadNotifications.postIncomplete(
                    failedSegmentCount: nextIncomplete.failedSegments.count,
                    totalSegmentCount: nextIncomplete.segments.count
                )
                resolveIncompleteDownload(nextIncomplete, operationID: operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                errorMessage = error.localizedDescription
                status = "Error"
                DownloadNotifications.postFailure(request: incomplete.request, message: error.localizedDescription)
                finishOperation(operationID)
            }
        }
    }

    func cancelCurrentDownload() {
        guard isDownloading else { return }
        let cancelledTask = activeTask
        cancelledTask?.cancel()
        if let incomplete = activeIncompleteDownload {
            Task {
                await cancelledTask?.value
                DownloadEngine.discard(incomplete)
            }
        }
        activeTask = nil
        activeOperationID = nil
        activeIncompleteDownload = nil
        incompleteDownload = nil
        currentRequest = nil
        completedOutput = nil
        errorMessage = nil
        progress = 0
        isDownloading = false
        status = "Cancelled"
        startNextDownloadIfPossible()
    }

    func discardIncompleteDownload() {
        guard let incomplete = incompleteDownload else { return }
        DownloadEngine.discard(incomplete)
        incompleteDownload = nil
        status = "Ready"
        startNextDownloadIfPossible()
    }

    func resolveIncompleteDownloadWithoutPrompt() {
        guard let incomplete = incompleteDownload, !isDownloading else { return }
        if DownloadEngine.hasSaveablePartial(incomplete) {
            savePartialDownload()
        } else {
            discardIncompleteDownload()
        }
    }

    private func apply(_ update: DownloadUpdate, operationID: UUID) {
        guard isDownloading, isCurrent(operationID) else { return }
        status = update.status
        progress = update.progress
    }

    /// The completed download is kept under its generated name if Save is cancelled.
    private func chooseCompletedFilename(for request: DownloadRequest, output: URL) throws -> URL {
        guard request.filenameFormat == .askEachTime else { return output }
        let panel = NSSavePanel()
        panel.title = "Name downloaded media"
        panel.prompt = "Save"
        panel.directoryURL = output.deletingLastPathComponent()
        panel.nameFieldStringValue = output.lastPathComponent
        if let type = UTType(filenameExtension: output.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url,
              destination.standardizedFileURL != output.standardizedFileURL else { return output }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: output)
        } else {
            try FileManager.default.moveItem(at: output, to: destination)
        }
        return destination
    }

    private var playbackBatchActive = false

    private func recordCompletion(request: DownloadRequest, output: URL) {
        completionSequencePosition += 1
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "revealFinishedVideo") {
            let mode = defaults.string(forKey: "completionPlaybackMode") ?? "each"
            let shouldPlay = mode == "each"
                || (mode == "first" && completionSequencePosition == 1)
                || (mode == "last" && queue.isEmpty)
            if shouldPlay { NSWorkspace.shared.open(output) }
        }
        completedRequest = request
        completedOutput = output
    }

    private func resolveIncompleteDownload(_ incomplete: IncompleteDownload, operationID: UUID) {
        if DownloadNotifications.showsInAppFailure {
            incompleteDownload = incomplete
            finishOperation(operationID)
            return
        }

        if DownloadEngine.hasSaveablePartial(incomplete) {
            incompleteDownload = incomplete
            finishOperation(operationID)
            DispatchQueue.main.async { [weak self] in
                self?.savePartialDownload()
            }
        } else {
            DownloadEngine.discard(incomplete)
            incompleteDownload = nil
            status = "Download incomplete"
            finishOperation(operationID)
        }
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        activeOperationID = id
        return id
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private func finishOperation(_ operationID: UUID) {
        guard isCurrent(operationID) else { return }
        activeTask = nil
        activeOperationID = nil
        activeIncompleteDownload = nil
        currentRequest = nil
        isDownloading = false
        startNextDownloadIfPossible()
    }

    private func finishCancelled(_ operationID: UUID) {
        guard isCurrent(operationID) else { return }
        activeTask = nil
        activeOperationID = nil
        activeIncompleteDownload = nil
        currentRequest = nil
        progress = 0
        status = "Cancelled"
        isDownloading = false
        startNextDownloadIfPossible()
    }

    private func startNextDownloadIfPossible() {
        if !isDownloading && incompleteDownload == nil && queue.isEmpty {
            playbackBatchActive = false
        }
        guard !isQueuePaused, !isDownloading, incompleteDownload == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        saveQueue()
        start(next.request, fromQueue: true)
    }

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        if let queueRecoveryData {
            defaults.set(queueRecoveryData, forKey: queueDefaultsKey + ".recovery-" + UUID().uuidString)
            self.queueRecoveryData = nil
        }
        defaults.set(data, forKey: queueDefaultsKey)
    }

    private static func loadQueue(in defaults: UserDefaults) -> (items: [QueuedDownload], recovery: Data?) {
        guard let data = defaults.data(forKey: "BBCD4Mac.downloadQueue") else { return ([], nil) }
        guard let decoded = try? JSONDecoder().decode(RecoverableArray<QueuedDownload>.self, from: data) else { return ([], data) }
        var seen = Set<UUID>()
        var repaired = decoded.skippedCount > 0
        let items = decoded.values.map { item in
            if seen.insert(item.id).inserted { return item }
            repaired = true
            return QueuedDownload(request: item.request)
        }
        return (items, repaired ? data : nil)
    }
}

enum DownloadEngine {
    private static let segmentDuration = 3.84
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

    // Worker groups enforce each request's limit; the connection pool must not
    // impose a lower per-host ceiling on those transfers.
    private static let maximumMediaTransfers = 50
    private static let mediaSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = maximumMediaTransfers
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let availabilitySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = StreamAvailabilityPreferences.maximumConcurrentChecks
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func streamIsAvailable(_ urlString: String) async throws -> Bool {
        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if url.path.lowercased().hasSuffix(".m3u8") {
            return try await checkHLSAvailability(url, depth: 0)
        }
        guard url.path.lowercased().hasSuffix(".mpd") else { return false }
        let (data, finalURL) = try await availabilityManifest(url)
        let parser = MPDParser(baseURL: finalURL.deletingLastPathComponent())
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return false }
        let video = parser.representations.filter { $0.type == .video }.min { $0.bandwidth < $1.bandwidth }
        let audio = parser.representations.filter { $0.type == .audio }.min { $0.bandwidth < $1.bandwidth }
        let required = [video, audio].compactMap { $0 }
        guard !required.isEmpty else { return false }
        // Leave room for publication delay, but never treat an old manifest
        // alone as evidence that the stream is still serving live media.
        for age in [15.0, 30.0, 60.0] {
            try Task.checkCancellation()
            let time = Date().addingTimeInterval(-age)
            var available = true
            for representation in required {
                let number: Int
                if let start = parser.availabilityStartTime,
                   let duration = representation.segmentDuration, duration > 0 {
                    guard time >= start else { return false }
                    let offset = floor(time.timeIntervalSince(start) / duration)
                    guard offset.isFinite, offset >= 0, representation.startNumber >= 0,
                          offset < Double(Int.max - representation.startNumber) else { return false }
                    number = representation.startNumber + Int(offset)
                } else {
                    number = segmentStarting(atOrBefore: time)
                }
                if try await availabilityMedia(segmentURL(representation.media, number: number)) == false {
                    available = false
                    break
                }
            }
            if available { return true }
        }
        return false
    }

    private static func availabilityRequest(_ url: URL) throws -> URLRequest {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DownloadError.invalidStream
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bbc.co.uk/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bbc.co.uk", forHTTPHeaderField: "Origin")
        request.networkServiceType = .background
        return request
    }

    private static func availabilityManifest(_ url: URL) async throws -> (Data, URL) {
        let (bytes, response) = try await availabilitySession.bytes(for: availabilityRequest(url))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.invalidStream
        }
        let maximumSize = 1_048_576
        guard response.expectedContentLength <= maximumSize else { throw DownloadError.invalidStream }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumSize else { throw DownloadError.invalidStream }
            data.append(byte)
        }
        return (data, response.url ?? url)
    }

    private static func availabilityMedia(_ url: URL) async throws -> Bool {
        var request = try availabilityRequest(url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await availabilitySession.bytes(for: request)
        defer { bytes.task.cancel() }
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !mimeType.hasPrefix("text/"), !mimeType.contains("json"), !mimeType.contains("xml") else { return false }
        var iterator = bytes.makeAsyncIterator()
        guard let firstByte = try await iterator.next() else { return false }
        return firstByte != 0x3c && firstByte != 0x7b
    }

    private static func checkHLSAvailability(_ url: URL, depth: Int) async throws -> Bool {
        guard depth < 4 else { return false }
        let (data, finalURL) = try await availabilityManifest(url)
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U", !lines.contains("#EXT-X-ENDLIST") else { return false }
        let base = finalURL.deletingLastPathComponent()
        if let variant = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            guard let path = lines.dropFirst(variant + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let child = URL(string: path, relativeTo: base)?.absoluteURL,
                  try await checkHLSAvailability(child, depth: depth + 1) else { return false }
            if let group = capture(#"AUDIO=["']([^"']+)["']"#, in: lines[variant]) {
                let audioLines = lines.filter {
                    $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO")
                        && capture(#"GROUP-ID=["']([^"']+)["']"#, in: $0) == group
                }
                let audio = audioLines.first(where: { $0.contains("DEFAULT=YES") }) ?? audioLines.first
                if let audio, let path = capture(#"URI=["']([^"']+)["']"#, in: audio),
                   let child = URL(string: path, relativeTo: base)?.absoluteURL {
                    return try await checkHLSAvailability(child, depth: depth + 1)
                }
            }
            return true
        }
        var latest: URL?
        var latestStart: Date?
        var runningStart: Date?
        var duration = segmentDuration
        let dateFormatter = ISO8601DateFormatter()
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions.insert(.withFractionalSeconds)
        for line in lines {
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                runningStart = dateFormatter.date(from: value) ?? fractionalDateFormatter.date(from: value)
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") ?? segmentDuration
            } else if !line.isEmpty, !line.hasPrefix("#") {
                latest = URL(string: line, relativeTo: base)?.absoluteURL
                latestStart = runningStart
                runningStart = runningStart?.addingTimeInterval(duration)
            }
        }
        guard let latest else { return false }
        if let latestStart {
            let age = Date().timeIntervalSince(latestStart.addingTimeInterval(duration))
            guard age < max(120, duration * 3), age > -60 else { return false }
        }
        return try await availabilityMedia(latest)
    }

    static func run(
        _ request: DownloadRequest,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws -> URL {
        guard (1...DownloadLimits.maximumDuration).contains(request.duration) else { throw DownloadError.invalidDuration }
        guard let sourceURL = URL(string: request.stream.url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            throw DownloadError.invalidStream
        }
        let urlText = sourceURL.path.lowercased()
        guard urlText.hasSuffix(".mpd") || urlText.hasSuffix(".m3u8") else {
            throw DownloadError.invalidStream
        }
        guard request.start <= Date() else { throw DownloadError.futureTime }
        let now = Date()
        if request.stream.category == .radio {
            guard request.start > now.addingTimeInterval(-2 * 24 * 60 * 60) else {
                throw DownloadError.radioDateTooOld
            }
        } else {
            let earliestAllowedDay = Calendar.current.date(
                byAdding: .day,
                value: -14,
                to: Calendar.current.startOfDay(for: now)
            ) ?? now
            guard request.start >= earliestAllowedDay else {
                throw DownloadError.dateTooOld
            }
        }

        // BBC segment numbers are epoch-based. Always select the segment that
        // begins at or before the requested time, never the next segment.
        let startSegment = segmentStarting(atOrBefore: request.start)
        let endSegment = Int(ceil((request.start.timeIntervalSince1970 + Double(request.duration)) / segmentDuration)) - 1
        let segments = Array(startSegment...endSegment)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbcd4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var preserveWorkspace = false
        defer {
            if !preserveWorkspace {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        try FileManager.default.createDirectory(at: request.outputFolder, withIntermediateDirectories: true)
        var output = outputURL(for: request, firstSegment: startSegment, fileExtension: "mp4")

        if urlText.hasSuffix(".mpd") {
            await update(.init(status: "Checking stream…", progress: 0))
            let manifest = try await parseMPD(sourceURL)
            let video = selectVideo(from: manifest.representations)
            let audio = selectAudio(from: manifest.representations)

            if let video, let audio {
                await update(.init(status: "Preparing download…", progress: 0))
                try await fetch(video.initialization, to: workspace.appendingPathComponent("video.init"), request: request)
                try await fetch(audio.initialization, to: workspace.appendingPathComponent("audio.init"), request: request)
                guard let availableSegments = try await findFirstAvailableMPDSegments(
                    segments,
                    video: video,
                    audio: audio,
                    workspace: workspace,
                    request: request
                ) else {
                    preserveWorkspace = true
                    throw DownloadError.incomplete(IncompleteDownload(
                        request: request,
                        workspace: workspace,
                        kind: .mpd,
                        segments: segments,
                        failedSegments: segments,
                        output: output
                    ))
                }
                let failures = try await fetchMPDMediaFiles(
                    availableSegments,
                    video: video,
                    audio: audio,
                    workspace: workspace,
                    maximumConcurrent: request.maximumConcurrentSegments,
                    request: request,
                    update: update
                )
                guard failures.isEmpty else {
                    preserveWorkspace = true
                    throw DownloadError.incomplete(IncompleteDownload(
                        request: request,
                        workspace: workspace,
                        kind: .mpd,
                        segments: availableSegments,
                        failedSegments: incompleteTail(in: availableSegments, after: failures),
                        output: output,
                        firstAvailableSegment: availableSegments.first
                    ))
                }

                await update(.init(status: "Combining video and audio…", progress: 1))
                try concatenate([workspace.appendingPathComponent("video.init")] + availableSegments.map {
                    workspace.appendingPathComponent("v_\($0).m4s")
                }, to: workspace.appendingPathComponent("video.mp4"))
                await update(.init(status: "Combining video and audio…", progress: 1))
                try concatenate([workspace.appendingPathComponent("audio.init")] + availableSegments.map {
                    workspace.appendingPathComponent("a_\($0).m4s")
                }, to: workspace.appendingPathComponent("audio.mp4"))
                let mergeArguments = [
                    "-y", "-i", workspace.appendingPathComponent("video.mp4").path,
                    "-i", workspace.appendingPathComponent("audio.mp4").path
                ]
                    + codecArguments(for: request) + [output.path]
                if request.encodeH265 {
                    try await runFFmpegWithEncodingProgress(
                        mergeArguments,
                        duration: request.duration,
                        update: update
                    )
                } else {
                    await update(.init(status: "Merging…", progress: 1))
                    try await runFFmpeg(mergeArguments)
                }
            } else if let audio {
                guard let segmentDuration = audio.segmentDuration,
                      let availabilityStartTime = manifest.availabilityStartTime else {
                    throw DownloadError.processFailed("This audio MPD does not provide the timing needed to download a selected range.")
                }

                let audioSegments = Array(try segmentRange(start: request.start, duration: request.duration,
                    referenceStart: availabilityStartTime, referenceSegment: audio.startNumber, segmentDuration: segmentDuration))
                let startSegment = audioSegments[0]
                output = outputURL(for: request, firstSegment: startSegment, fileExtension: "m4a")

                await update(.init(status: "Preparing download…", progress: 0))
                try await fetch(audio.initialization, to: workspace.appendingPathComponent("audio.init"), request: request)
                let failures = try await fetchSegments(
                    audioSegments,
                    maximumConcurrent: request.maximumConcurrentSegments,
                    update: update
                ) { segment in
                    try await fetch(
                        segmentURL(audio.media, number: segment),
                        to: workspace.appendingPathComponent("a_\(segment).m4s"),
                        request: request
                    )
                }
                guard failures.isEmpty else {
                    throw DownloadError.failedSegments(failures)
                }

                await update(.init(status: "Merging…", progress: 1))
                try concatenate([workspace.appendingPathComponent("audio.init")] + audioSegments.map {
                    workspace.appendingPathComponent("a_\($0).m4s")
                }, to: workspace.appendingPathComponent("audio.mp4"))
                await update(.init(status: "Saving audio…", progress: 1))
                try await runFFmpeg([
                    "-y",
                    "-i", workspace.appendingPathComponent("audio.mp4").path,
                ]
                    + ["-map", "0:a:0", "-vn", "-c:a", "copy", output.path])
            } else {
                throw DownloadError.processFailed("No usable media representations were found.")
            }
        } else if urlText.contains(".fmp4.m3u8") {
            await update(.init(status: "Checking stream…", progress: 0))
            let playlist = try await parseFMP4Playlist(sourceURL)
            try await fetch(playlist.initialization, to: workspace.appendingPathComponent("fmp4.init"), request: request)
            let failures = try await fetchSegments(segments, maximumConcurrent: request.maximumConcurrentSegments, update: update) { segment in
                try await fetch(segmentURL(playlist.media, number: segment), to: workspace.appendingPathComponent("f_\(segment).m4s"), request: request)
            }
            guard failures.isEmpty else {
                preserveWorkspace = true
                throw DownloadError.incomplete(IncompleteDownload(
                    request: request,
                    workspace: workspace,
                    kind: .fmp4,
                    segments: segments,
                    failedSegments: incompleteTail(in: segments, after: failures),
                    output: output
                ))
            }
            await update(.init(status: "Combining video and audio…", progress: 1))
            try concatenate([workspace.appendingPathComponent("fmp4.init")] + segments.map {
                workspace.appendingPathComponent("f_\($0).m4s")
            }, to: workspace.appendingPathComponent("fmp4.mp4"))
            let mergeArguments = [
                "-y", "-i", workspace.appendingPathComponent("fmp4.mp4").path
            ]
                + codecArguments(for: request) + [output.path]
            if request.encodeH265 {
                try await runFFmpegWithEncodingProgress(
                    mergeArguments,
                    duration: request.duration,
                    update: update
                )
            } else {
                await update(.init(status: "Merging…", progress: 1))
                try await runFFmpeg(mergeArguments)
            }
        } else {
            await update(.init(status: "Checking stream…", progress: 0))
            let playlist = try await parseHLSPlaylist(sourceURL)
            let hlsSegments = Array(try segmentRange(start: request.start, duration: request.duration,
                referenceStart: playlist.referenceStart, referenceSegment: playlist.referenceSegment, segmentDuration: playlist.segmentDuration))
            let startHLSegment = hlsSegments[0]
            output = outputURL(
                for: request,
                firstSegment: startHLSegment,
                fileExtension: request.stream.category == .radio ? "m4a" : "mp4"
            )
            let failures = try await fetchSegments(hlsSegments, maximumConcurrent: request.maximumConcurrentSegments, update: update) { segment in
                try await fetch(segmentURL(playlist.media, number: segment), to: workspace.appendingPathComponent("\(segment).ts"), request: request)
            }
            guard failures.isEmpty else {
                preserveWorkspace = true
                throw DownloadError.incomplete(IncompleteDownload(
                    request: request,
                    workspace: workspace,
                    kind: .transportStream,
                    segments: hlsSegments,
                    failedSegments: incompleteTail(in: hlsSegments, after: failures),
                    output: output
                ))
            }
            let listing = hlsSegments.map { "file '\(workspace.appendingPathComponent("\($0).ts").path)'" }
                .joined(separator: "\n")
            try listing.write(to: workspace.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
            if request.stream.category == .radio {
                await update(.init(status: "Saving audio…", progress: 1))
                try await runFFmpeg([
                    "-y", "-f", "concat", "-safe", "0",
                    "-i", workspace.appendingPathComponent("list.txt").path,
                ]
                    + ["-map", "0:a:0", "-vn", "-c:a", "copy", "-bsf:a", "aac_adtstoasc", output.path])
            } else {
                let mergeArguments = [
                    "-y", "-f", "concat", "-safe", "0", "-i", workspace.appendingPathComponent("list.txt").path
                ]
                    + codecArguments(for: request) + [output.path]
                if request.encodeH265 {
                    try await runFFmpegWithEncodingProgress(
                        mergeArguments,
                        duration: request.duration,
                        update: update
                    )
                } else {
                    await update(.init(status: "Merging…", progress: 1))
                    try await runFFmpeg(mergeArguments)
                }
            }
        }

        return output
    }

    static func savePartial(
        _ incomplete: IncompleteDownload,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws -> URL {
        let available = availableSegments(in: incomplete)
        guard !available.isEmpty else {
            throw DownloadError.processFailed("There are no downloaded segments available to save.")
        }
        await update(.init(status: "Saving download…", progress: 1))
        try await finish(
            kind: incomplete.kind,
            workspace: incomplete.workspace,
            segments: Array(available),
            request: incomplete.request,
            output: incomplete.output
        )
        discard(incomplete)
        return incomplete.output
    }

    static func retry(
        _ incomplete: IncompleteDownload,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws -> URL {
        guard let sourceURL = URL(string: incomplete.request.stream.url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else { throw DownloadError.invalidStream }
        guard let firstFailedSegment = incomplete.failedSegments.min() else {
            throw DownloadError.processFailed("There are no failed segments to retry.")
        }
        let retrySegments = incomplete.segments.filter { $0 >= firstFailedSegment }
        var segmentsToFinish = incomplete.segments

        switch incomplete.kind {
        case .mpd:
            let manifest = try await parseMPD(sourceURL)
            guard let video = selectVideo(from: manifest.representations), let audio = selectAudio(from: manifest.representations) else {
                throw DownloadError.processFailed("No usable video and audio representations were found.")
            }
            if !FileManager.default.fileExists(atPath: incomplete.workspace.appendingPathComponent("video.init").path) {
                try await fetch(video.initialization, to: incomplete.workspace.appendingPathComponent("video.init"), request: incomplete.request)
            }
            if !FileManager.default.fileExists(atPath: incomplete.workspace.appendingPathComponent("audio.init").path) {
                try await fetch(audio.initialization, to: incomplete.workspace.appendingPathComponent("audio.init"), request: incomplete.request)
            }
            let mpdRetrySegments: [Int]
            let firstAvailableSegment: Int?
            if incomplete.firstAvailableSegment == nil {
                guard let availableSegments = try await findFirstAvailableMPDSegments(
                    incomplete.segments,
                    video: video,
                    audio: audio,
                    workspace: incomplete.workspace,
                    request: incomplete.request
                ) else {
                    throw DownloadError.incomplete(incomplete)
                }
                mpdRetrySegments = availableSegments
                firstAvailableSegment = availableSegments.first
                segmentsToFinish = availableSegments
            } else {
                mpdRetrySegments = retrySegments
                firstAvailableSegment = incomplete.firstAvailableSegment
            }
            let failures = try await fetchMPDMediaFiles(
                mpdRetrySegments,
                video: video,
                audio: audio,
                workspace: incomplete.workspace,
                maximumConcurrent: incomplete.request.maximumConcurrentSegments,
                request: incomplete.request,
                update: update,
                statusPrefix: "Retrying"
            )
            guard failures.isEmpty else {
                throw DownloadError.incomplete(IncompleteDownload(
                    request: incomplete.request,
                    workspace: incomplete.workspace,
                    kind: .mpd,
                    segments: segmentsToFinish,
                    failedSegments: incompleteTail(in: segmentsToFinish, after: failures),
                    output: incomplete.output,
                    firstAvailableSegment: firstAvailableSegment
                ))
            }
        case .fmp4:
            let playlist = try await parseFMP4Playlist(sourceURL)
            if !FileManager.default.fileExists(atPath: incomplete.workspace.appendingPathComponent("fmp4.init").path) {
                try await fetch(playlist.initialization, to: incomplete.workspace.appendingPathComponent("fmp4.init"), request: incomplete.request)
            }
            let failures = try await fetchSegments(
                retrySegments,
                maximumConcurrent: incomplete.request.maximumConcurrentSegments,
                update: update,
                statusPrefix: "Retrying"
            ) { segment in
                try await fetchFileIfNeeded(
                    segmentURL(playlist.media, number: segment),
                    to: incomplete.workspace.appendingPathComponent("f_\(segment).m4s"),
                    request: incomplete.request,
                    onRetry: nil
                )
            }
            if let firstFailure = failures.min() {
                throw retryFailure(for: incomplete, segment: firstFailure)
            }
        case .transportStream:
            let playlist = try await parseHLSPlaylist(sourceURL)
            let failures = try await fetchSegments(
                retrySegments,
                maximumConcurrent: incomplete.request.maximumConcurrentSegments,
                update: update,
                statusPrefix: "Retrying"
            ) { segment in
                try await fetchFileIfNeeded(
                    segmentURL(playlist.media, number: segment),
                    to: incomplete.workspace.appendingPathComponent("\(segment).ts"),
                    request: incomplete.request,
                    onRetry: nil
                )
            }
            if let firstFailure = failures.min() {
                throw retryFailure(for: incomplete, segment: firstFailure)
            }
        }

        await update(.init(status: incomplete.request.encodeH265 ? "Encoding…" : "Merging…", progress: 1))
        try await finish(
            kind: incomplete.kind,
            workspace: incomplete.workspace,
            segments: segmentsToFinish,
            request: incomplete.request,
            output: incomplete.output
        )
        discard(incomplete)
        return incomplete.output
    }

    static func discard(_ incomplete: IncompleteDownload) {
        try? FileManager.default.removeItem(at: incomplete.workspace)
    }

    static func hasSaveablePartial(_ incomplete: IncompleteDownload) -> Bool {
        !availableSegments(in: incomplete).isEmpty
    }

    private static func retryFailure(for incomplete: IncompleteDownload, segment: Int) -> DownloadError {
        .incomplete(IncompleteDownload(
            request: incomplete.request,
            workspace: incomplete.workspace,
            kind: incomplete.kind,
            segments: incomplete.segments,
            failedSegments: incomplete.segments.filter { $0 >= segment },
            output: incomplete.output
        ))
    }

    private static func incompleteTail(in segments: [Int], after failures: [Int]) -> [Int] {
        guard let firstFailure = failures.min() else { return [] }
        return segments.filter { $0 >= firstFailure }
    }

    private static func availableSegments(in incomplete: IncompleteDownload) -> [Int] {
        guard let firstFailedSegment = incomplete.failedSegments.min() else { return [] }
        return Array(
            incomplete.segments
                .filter { $0 < firstFailedSegment }
                .prefix { segmentIsComplete($0, in: incomplete) }
        )
    }

    private static func segmentIsComplete(_ segment: Int, in incomplete: IncompleteDownload) -> Bool {
        let workspace = incomplete.workspace
        return switch incomplete.kind {
        case .mpd:
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("v_\(segment).m4s").path)
                && FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a_\(segment).m4s").path)
        case .fmp4:
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("f_\(segment).m4s").path)
        case .transportStream:
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("\(segment).ts").path)
        }
    }

    private static func finish(
        kind: PartialDownloadKind,
        workspace: URL,
        segments: [Int],
        request: DownloadRequest,
        output: URL
    ) async throws {
        switch kind {
        case .mpd:
            try concatenate([workspace.appendingPathComponent("video.init")] + segments.map {
                workspace.appendingPathComponent("v_\($0).m4s")
            }, to: workspace.appendingPathComponent("video.mp4"))
            try concatenate([workspace.appendingPathComponent("audio.init")] + segments.map {
                workspace.appendingPathComponent("a_\($0).m4s")
            }, to: workspace.appendingPathComponent("audio.mp4"))
            try await runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("video.mp4").path,
                "-i", workspace.appendingPathComponent("audio.mp4").path
            ] + codecArguments(for: request) + [output.path])
        case .fmp4:
            try concatenate([workspace.appendingPathComponent("fmp4.init")] + segments.map {
                workspace.appendingPathComponent("f_\($0).m4s")
            }, to: workspace.appendingPathComponent("fmp4.mp4"))
            try await runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("fmp4.mp4").path
            ] + codecArguments(for: request) + [output.path])
        case .transportStream:
            let listing = segments.map { "file '\(workspace.appendingPathComponent("\($0).ts").path)'" }
                .joined(separator: "\n")
            try listing.write(to: workspace.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
            if request.stream.category == .radio {
                try await runFFmpeg([
                    "-y", "-f", "concat", "-safe", "0", "-i", workspace.appendingPathComponent("list.txt").path,
                    "-map", "0:a:0", "-vn", "-c:a", "copy", "-bsf:a", "aac_adtstoasc", output.path
                ])
            } else {
                try await runFFmpeg([
                    "-y", "-f", "concat", "-safe", "0", "-i", workspace.appendingPathComponent("list.txt").path
                ] + codecArguments(for: request) + [output.path])
            }
        }
    }

    static func fetchSegments(
        _ segments: [Int],
        maximumConcurrent: Int,
        update: @escaping @Sendable (DownloadUpdate) async -> Void,
        statusPrefix: String = "Downloading",
        action: @escaping @Sendable (Int) async throws -> Void
    ) async throws -> [Int] {
        try Task.checkCancellation()
        var failures: [Int] = []
        var completed = 0
        var nextSegmentIndex = 0
        let simultaneousDownloads = min(max(1, maximumConcurrent), maximumMediaTransfers, segments.count)

        await withTaskGroup(of: (Int, Bool).self) { group in
            func enqueueNextSegment() {
                guard nextSegmentIndex < segments.count else { return }
                let segment = segments[nextSegmentIndex]
                nextSegmentIndex += 1
                group.addTask {
                    do {
                        try await action(segment)
                        return (segment, true)
                    } catch {
                        return (segment, false)
                    }
                }
            }

            for _ in 0..<simultaneousDownloads {
                enqueueNextSegment()
            }

            while let (segment, succeeded) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                completed += 1
                if !succeeded { failures.append(segment) }
                await update(.init(
                    status: "\(statusPrefix) segments \(completed) of \(segments.count)…",
                    progress: Double(completed) / Double(segments.count)
                ))
                enqueueNextSegment()
            }
        }
        try Task.checkCancellation()
        return failures.sorted()
    }

    private static func findFirstAvailableMPDSegments(
        _ segments: [Int],
        video: MPDRepresentation,
        audio: MPDRepresentation,
        workspace: URL,
        request: DownloadRequest
    ) async throws -> [Int]? {
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let videoOutput = workspace.appendingPathComponent("v_\(segment).m4s")
            let audioOutput = workspace.appendingPathComponent("a_\(segment).m4s")
            do {
                try await fetch(
                    segmentURL(video.media, number: segment),
                    to: videoOutput,
                    request: request,
                    retryMissingSegments: false
                )
                try await fetch(
                    segmentURL(audio.media, number: segment),
                    to: audioOutput,
                    request: request,
                    retryMissingSegments: false
                )
                return Array(segments[index...])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: videoOutput)
                try? FileManager.default.removeItem(at: audioOutput)
                guard isMissingSegment(error) else { throw error }
            }
        }
        return nil
    }

    private static func fetchMPDMediaFiles(
        _ segments: [Int],
        video: MPDRepresentation,
        audio: MPDRepresentation,
        workspace: URL,
        maximumConcurrent: Int,
        request: DownloadRequest,
        update: @escaping @Sendable (DownloadUpdate) async -> Void,
        statusPrefix: String = "Downloading"
    ) async throws -> [Int] {
        guard !segments.isEmpty else { return [] }
        let files = try segments.flatMap { segment in
            [
                MPDMediaFile(
                    segment: segment,
                    source: try segmentURL(video.media, number: segment),
                    output: workspace.appendingPathComponent("v_\(segment).m4s")
                ),
                MPDMediaFile(
                    segment: segment,
                    source: try segmentURL(audio.media, number: segment),
                    output: workspace.appendingPathComponent("a_\(segment).m4s")
                )
            ]
        }
        let segmentPositions = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element, $0.offset + 1) })
        var successfulParts = Dictionary(uniqueKeysWithValues: segments.map { ($0, 0) })
        var failedSegments = Set<Int>()
        var nextFileIndex = 0
        var stopQueueing = false
        var completedCount = 0
        let transferLimit = min(max(1, maximumConcurrent), maximumMediaTransfers, files.count)

        func completedPrefix() -> Int {
            while completedCount < segments.count {
                let segment = segments[completedCount]
                guard failedSegments.contains(segment) == false, successfulParts[segment] == 2 else { break }
                completedCount += 1
            }
            return completedCount
        }

        await withTaskGroup(of: (MPDMediaFile, Bool).self) { group in
            func enqueueNextFile() {
                guard stopQueueing == false, nextFileIndex < files.count else { return }
                let file = files[nextFileIndex]
                nextFileIndex += 1
                let position = segmentPositions[file.segment] ?? 1
                group.addTask {
                    let retryUpdate: @Sendable (Int) async -> Void = { nextAttempt in
                        await update(.init(
                            status: "Retrying segment \(position) of \(segments.count) (attempt \(nextAttempt)/\(request.retryAttempts))…",
                            progress: Double(position - 1) / Double(segments.count)
                        ))
                    }
                    do {
                        try await fetchFileIfNeeded(file.source, to: file.output, request: request, onRetry: retryUpdate)
                        return (file, true)
                    } catch {
                        return (file, false)
                    }
                }
            }

            for _ in 0..<transferLimit {
                enqueueNextFile()
            }

            while let (file, succeeded) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if succeeded {
                    successfulParts[file.segment, default: 0] += 1
                } else {
                    failedSegments.insert(file.segment)
                    stopQueueing = true
                }
                let completed = completedPrefix()
                await update(.init(
                    status: "\(statusPrefix) segments \(min(completed + 1, segments.count)) of \(segments.count)…",
                    progress: Double(completed) / Double(segments.count)
                ))
                enqueueNextFile()
            }
        }
        try Task.checkCancellation()
        return failedSegments.sorted()
    }

    private static func fetchFileIfNeeded(
        _ url: URL,
        to output: URL,
        request: DownloadRequest,
        onRetry: (@Sendable (Int) async -> Void)?
    ) async throws {
        if FileManager.default.fileExists(atPath: output.path) { return }
        try await fetch(url, to: output, request: request, onRetry: onRetry)
    }

    private static func fetch(
        _ url: URL,
        to output: URL,
        request downloadRequest: DownloadRequest,
        onRetry: (@Sendable (Int) async -> Void)? = nil,
        retryMissingSegments: Bool = true
    ) async throws {
        var lastError: Error?
        for attempt in 1...downloadRequest.retryAttempts {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.bbc.co.uk/", forHTTPHeaderField: "Referer")
                request.setValue("https://www.bbc.co.uk", forHTTPHeaderField: "Origin")
                request.setValue("application/dash+xml, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
                let (data, response) = try await mediaSession.data(for: request)
                try Task.checkCancellation()
                if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                    throw DownloadError.httpStatus(response.statusCode, url)
                }
                let part = output.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: part)
                try data.write(to: part, options: .atomic)
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: part, to: output)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if !retryMissingSegments && isMissingSegment(error) {
                    throw error
                }
                if attempt < downloadRequest.retryAttempts {
                    await onRetry?(attempt + 1)
                    try await Task.sleep(for: .seconds(downloadRequest.retryDelay))
                }
            }
        }
        throw lastError ?? DownloadError.processFailed("Could not download \(url.absoluteString)")
    }

    private static func isMissingSegment(_ error: Error) -> Bool {
        guard let downloadError = error as? DownloadError else { return false }
        if case .httpStatus(404, _) = downloadError { return true }
        return false
    }

    private static func concatenate(_ files: [URL], to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        for file in files {
            try Task.checkCancellation()
            try destination.write(contentsOf: Data(contentsOf: file))
        }
    }

    private static func codecArguments(for request: DownloadRequest) -> [String] {
        guard request.encodeH265 else { return ["-c", "copy"] }
        return (request.encodingConfiguration ?? .defaults).videoArguments()
    }

    private static func segmentStarting(atOrBefore date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / segmentDuration))
    }

    private static func ffmpegExecutable() throws -> URL {
        let locations = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DownloadError.ffmpegMissing
        }
        return URL(fileURLWithPath: path)
    }

    private static func runFFmpeg(_ arguments: [String]) async throws {
        try await MediaProcess.run(executable: ffmpegExecutable(), arguments: ["-nostdin"] + arguments)
    }

    private static func runFFmpegWithEncodingProgress(
        _ arguments: [String],
        duration: Int,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws {
        let reader = FFmpegProgressReader()
        let totalDuration = Double(max(duration, 1))
        await update(.init(status: "Encoding… 0%", progress: 0))
        try await MediaProcess.run(
            executable: ffmpegExecutable(),
            arguments: ["-v", "error", "-progress", "pipe:1", "-nostats", "-nostdin"] + arguments
        ) { data in
            for seconds in reader.consume(data) {
                let progress = min(0.99, max(0, seconds / totalDuration))
                let percentage = Int((progress * 100).rounded(.down))
                Task { await update(.init(status: "Encoding… \(percentage)%", progress: progress)) }
            }
        }
        await update(.init(status: "Encoding… 100%", progress: 1))
    }

    private final class FFmpegProgressReader: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func consume(_ data: Data) -> [Double] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)

            var timestamps: [Double] = []
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)

                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    let value = line.split(separator: "=", maxSplits: 1).last.flatMap { Double($0) }
                    if let value, value.isFinite, value >= 0 {
                        timestamps.append(value / 1_000_000)
                    }
                }
            }
            if buffer.count > 65_536 { buffer.removeAll(keepingCapacity: false) }
            return timestamps
        }
    }

    private static func outputURL(
        for request: DownloadRequest,
        firstSegment: Int,
        fileExtension: String
    ) -> URL {
        let streamName = safeFilename(request.stream.name)
        let now = Date()
        let startDate = filenameDate(request.start)
        let startTime = filenameTime(request.start)
        let currentDate = filenameDate(now)
        let currentTime = filenameTime(now)
        let random = randomFilenameString()

        let baseName: String
        switch request.filenameFormat {
        case .firstSegment, .askEachTime:
            baseName = "\(streamName)_\(firstSegment)"
        case .startDateTime:
            baseName = "\(streamName)_\(startDate)_\(startTime)"
        case .startTime:
            baseName = "\(streamName)_\(startTime)"
        case .currentDateTime:
            baseName = "\(streamName)_\(currentDate)_\(currentTime)"
        case .streamNameRandom:
            baseName = "\(streamName)_\(random)"
        case .random:
            baseName = random
        }

        return uniqueOutputURL(in: request.outputFolder, baseName: baseName, fileExtension: fileExtension)
    }

    private static func uniqueOutputURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)_\(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private static func filenameDate(_ date: Date) -> String {
        DateFormats.filenameDate(
            date,
            format: UserDefaults.standard.string(forKey: "dateFormat") ?? "dd/MM/yyyy"
        )
    }

    private static func filenameTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: date)
    }

    private static func randomFilenameString() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).compactMap { _ in characters.randomElement() })
    }

    private static func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    static func segmentRange(start: Date, duration: Int, referenceStart: Date, referenceSegment: Int, segmentDuration: Double) throws -> ClosedRange<Int> {
        guard segmentDuration.isFinite, segmentDuration > 0, duration > 0 else { throw DownloadError.invalidStream }
        let firstOffset = floor(start.timeIntervalSince(referenceStart) / segmentDuration)
        let lastOffset = ceil(start.addingTimeInterval(Double(duration)).timeIntervalSince(referenceStart) / segmentDuration) - 1
        guard let first = Int(exactly: firstOffset), let last = Int(exactly: lastOffset) else { throw DownloadError.invalidStream }
        let lower = referenceSegment.addingReportingOverflow(first)
        let upper = referenceSegment.addingReportingOverflow(last)
        guard !lower.overflow, !upper.overflow, lower.partialValue >= 0,
              upper.partialValue >= lower.partialValue,
              upper.partialValue - lower.partialValue < 1_000_000 else { throw DownloadError.invalidStream }
        return lower.partialValue...upper.partialValue
    }

    private static func segmentURL(_ template: URL, number: Int) throws -> URL {
        let string = fillSegmentTemplate(template.absoluteString, number: number)
        guard let url = URL(string: string) else { throw DownloadError.invalidStream }
        return url
    }

    private static let segmentNumberPattern = try! NSRegularExpression(pattern: #"\$Number%0(\d+)d\$"#)

    private static func fillSegmentTemplate(_ template: String, number: Int) -> String {
        var result = template
            .replacingOccurrences(of: "$Number$", with: String(number))
            .replacingOccurrences(of: "$Time$", with: String(number))
        let matches = segmentNumberPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let widthRange = Range(match.range(at: 1), in: result), let tokenRange = Range(match.range, in: result) else { continue }
            let width = min(20, Int(result[widthRange]) ?? 0)
            result.replaceSubrange(tokenRange, with: String(format: "%0*lld", Int32(width), Int64(number)))
        }
        return result
    }

    private static func parseFMP4Playlist(_ url: URL) async throws -> SegmentTemplate {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        guard let mapLine = text.split(separator: "\n").first(where: { $0.hasPrefix("#EXT-X-MAP") }),
              let mapPath = capture(#"URI=[\"']([^\"']+)[\"']"#, in: String(mapLine)) else {
            throw DownloadError.processFailed("This fMP4 playlist does not provide an initialisation file.")
        }
        guard let media = text.split(separator: "\n").map(String.init).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
            throw DownloadError.processFailed("This fMP4 playlist does not contain media segments.")
        }
        let numberMatches = try! NSRegularExpression(pattern: #"\d+"#)
            .matches(in: media, range: NSRange(media.startIndex..., in: media))
        guard let number = numberMatches.max(by: { $0.range.length < $1.range.length }),
              let range = Range(number.range, in: media) else {
            throw DownloadError.processFailed("Could not find a numbered media segment in this playlist.")
        }
        var template = media
        template.replaceSubrange(range, with: "$Number$")
        let base = url.deletingLastPathComponent()
        guard let initialization = URL(string: mapPath, relativeTo: base)?.absoluteURL,
              let mediaURL = URL(string: template, relativeTo: base)?.absoluteURL else { throw DownloadError.invalidStream }
        return SegmentTemplate(
            initialization: initialization,
            media: mediaURL
        )
    }

    private static func capture(_ pattern: String, in string: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range), let capture = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[capture])
    }

    private static func parseMPD(_ url: URL) async throws -> MPDManifest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let parser = MPDParser(baseURL: url.deletingLastPathComponent())
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw DownloadError.processFailed("Could not read the MPD stream manifest.")
        }
        return MPDManifest(
            representations: parser.representations,
            availabilityStartTime: parser.availabilityStartTime
        )
    }

    private static func selectVideo(from representations: [MPDRepresentation]) -> MPDRepresentation? {
        let videos = representations.filter { $0.type == .video }
        guard !videos.isEmpty else { return nil }
        return videos.max(by: { $0.bandwidth < $1.bandwidth })
    }

    private static func selectAudio(from representations: [MPDRepresentation]) -> MPDRepresentation? {
        let audios = representations.filter { $0.type == .audio }
        guard !audios.isEmpty else { return nil }
        return audios.max(by: { $0.bandwidth < $1.bandwidth })
    }
}

private struct HLSPlaylist {
    let media: URL
    let segmentDuration: Double
    let referenceSegment: Int
    let referenceStart: Date
}

private extension DownloadEngine {
    static func parseHLSPlaylist(_ url: URL, depth: Int = 0) async throws -> HLSPlaylist {
        guard depth < 8 else { throw DownloadError.invalidStream }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bbc.co.uk/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bbc.co.uk", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw DownloadError.httpStatus(response.statusCode, url)
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let variantIndex = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            guard let path = lines[(variantIndex + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let variantURL = URL(string: path, relativeTo: url.deletingLastPathComponent())?.absoluteURL else {
                throw DownloadError.processFailed("This HLS stream does not provide a usable media playlist.")
            }
            return try await parseHLSPlaylist(variantURL, depth: depth + 1)
        }

        var mediaSequence = 0
        var pendingDuration: Double?
        var pendingStart: Date?
        var runningStart: Date?
        var segments: [(url: URL, duration: Double, sequence: Int, start: Date?)] = []
        let dateFormatter = ISO8601DateFormatter()

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(value)
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                pendingStart = dateFormatter.date(from: value)
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let segmentURL = URL(string: line, relativeTo: url.deletingLastPathComponent())?.absoluteURL else { continue }
                let duration = pendingDuration ?? 6.4
                guard duration.isFinite, duration > 0, mediaSequence >= 0,
                      mediaSequence <= Int.max - segments.count else { throw DownloadError.invalidStream }
                let start = pendingStart ?? runningStart
                segments.append((segmentURL, duration, mediaSequence + segments.count, start))
                if let start {
                    runningStart = start.addingTimeInterval(duration)
                }
                pendingDuration = nil
                pendingStart = nil
            }
        }

        guard let last = segments.last,
              let templated = numberedHLSTemplate(for: last.url, fallback: last.sequence) else {
            throw DownloadError.processFailed("This HLS playlist does not expose numbered transport-stream segments.")
        }
        return HLSPlaylist(
            media: templated.template,
            segmentDuration: last.duration,
            referenceSegment: templated.number,
            referenceStart: last.start ?? Date().addingTimeInterval(-last.duration)
        )
    }

    static func numberedHLSTemplate(for url: URL, fallback: Int) -> (template: URL, number: Int)? {
        let source = url.absoluteString
        let pattern = #"(?:-|/)(\d+)(?=\.ts(?:[?#]|$))"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.matches(in: source, range: range).last,
              let numberRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        var template = source
        let number = Int(template[numberRange]) ?? fallback
        template.replaceSubrange(numberRange, with: "$Number$")
        guard let templateURL = URL(string: template) else { return nil }
        return (templateURL, number)
    }
}

private struct SegmentTemplate {
    let initialization: URL
    let media: URL
}

private struct MPDMediaFile: Sendable {
    let segment: Int
    let source: URL
    let output: URL
}

private struct MPDManifest {
    let representations: [MPDRepresentation]
    let availabilityStartTime: Date?
}

private struct MPDRepresentation {
    enum MediaType { case audio, video }
    let type: MediaType
    let bandwidth: Int
    let initialization: URL
    let media: URL
    let segmentDuration: Double?
    let startNumber: Int
}

private final class MPDParser: NSObject, XMLParserDelegate {
    private struct Adaptation {
        var contentType = ""
        var mimeType = ""
        var template: RawTemplate?
    }

    private struct Representation {
        var bandwidth = 0
        var codecs = ""
        var identifier = ""
        var template: RawTemplate?
    }

    private struct RawTemplate {
        let initialization: String
        let media: String
        let duration: Int?
        let timescale: Int
        let startNumber: Int
    }

    private let sourceURL: URL
    private var mediaBaseURL: URL
    var representations: [MPDRepresentation] = []
    var availabilityStartTime: Date?
    private var adaptation: Adaptation?
    private var representation: Representation?
    private var baseURLText: String?

    init(baseURL: URL) {
        sourceURL = baseURL
        mediaBaseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "MPD":
            if let value = attributeDict["availabilityStartTime"] {
                let formatter = ISO8601DateFormatter()
                availabilityStartTime = formatter.date(from: value)
                if availabilityStartTime == nil {
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    availabilityStartTime = formatter.date(from: value)
                }
            }
        case "BaseURL":
            baseURLText = ""
        case "AdaptationSet":
            adaptation = Adaptation(
                contentType: attributeDict["contentType"] ?? "",
                mimeType: attributeDict["mimeType"] ?? ""
            )
        case "Representation":
            representation = Representation(
                bandwidth: Int(attributeDict["bandwidth"] ?? "0") ?? 0,
                codecs: attributeDict["codecs"] ?? "",
                identifier: attributeDict["id"] ?? ""
            )
        case "SegmentTemplate":
            guard let initialization = attributeDict["initialization"], let media = attributeDict["media"] else { return }
            let template = RawTemplate(
                initialization: initialization,
                media: media,
                duration: Int(attributeDict["duration"] ?? ""),
                timescale: Int(attributeDict["timescale"] ?? "1") ?? 1,
                startNumber: Int(attributeDict["startNumber"] ?? "1") ?? 1
            )
            if representation != nil {
                representation?.template = template
            } else {
                adaptation?.template = template
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        baseURLText? += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "BaseURL":
            if let text = baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let resolvedURL = URL(string: text, relativeTo: sourceURL)?.absoluteURL ?? sourceURL
                if resolvedURL.host == "as-dash-uk-live.akamaized.net",
                   var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) {
                    components.host = "as-dash-uk.live.cf.md.bbci.co.uk"
                    mediaBaseURL = components.url ?? resolvedURL
                } else {
                    mediaBaseURL = resolvedURL
                }
            }
            baseURLText = nil
        case "Representation":
            guard let representation, let adaptation, let template = representation.template ?? adaptation.template else {
                self.representation = nil
                return
            }
            let type: MPDRepresentation.MediaType = adaptation.contentType == "audio"
                || adaptation.mimeType.contains("audio") || representation.codecs.hasPrefix("mp4a")
                ? .audio : .video
            let initialization = template.initialization.replacingOccurrences(of: "$RepresentationID$", with: representation.identifier)
            let media = template.media.replacingOccurrences(of: "$RepresentationID$", with: representation.identifier)
            guard template.timescale > 0, template.duration.map({ $0 > 0 }) ?? true,
                  let initializationURL = URL(string: initialization, relativeTo: mediaBaseURL)?.absoluteURL,
                  let mediaURL = URL(string: media, relativeTo: mediaBaseURL)?.absoluteURL else {
                self.representation = nil
                return
            }
            let segmentDuration = template.duration.map { Double($0) / Double(template.timescale) }
            representations.append(MPDRepresentation(
                type: type,
                bandwidth: representation.bandwidth,
                initialization: initializationURL,
                media: mediaURL,
                segmentDuration: segmentDuration,
                startNumber: template.startNumber
            ))
            self.representation = nil
        case "AdaptationSet":
            adaptation = nil
        default:
            break
        }
    }
}
