import Foundation

struct DownloadRequest: Sendable {
    let stream: Stream
    let start: Date
    let duration: Int
    let outputFolder: URL
    let encodeH265: Bool
    let retryAttempts: Int
    let retryDelay: Double
    let maximumConcurrentSegments: Int
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
            "Choose a video duration."
        case .futureTime:
            "Chosen time cannot be in the future."
        case .dateTooOld:
            "Chosen date must be within the past 14 days."
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

@MainActor
final class DownloadController: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var progress = 0.0
    @Published private(set) var isDownloading = false
    @Published var completedOutput: URL?
    @Published var errorMessage: String?
    @Published var incompleteDownload: IncompleteDownload?
    private var activeTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var activeIncompleteDownload: IncompleteDownload?

    func start(_ request: DownloadRequest) {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        status = "Preparing download…"
        let operationID = beginOperation()

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.run(request) { update in
                    await self.apply(update)
                }
                guard self.isCurrent(operationID) else { return }
                completedOutput = output
                progress = 1
                status = "Done!"
                finishOperation(operationID)
            } catch DownloadError.incomplete(let incomplete) {
                guard self.isCurrent(operationID) else { return }
                incompleteDownload = incomplete
                status = "Download incomplete"
                finishOperation(operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                errorMessage = error.localizedDescription
                status = "Error"
                finishOperation(operationID)
            }
        }
    }

    func savePartialDownload() {
        guard let incomplete = incompleteDownload, !isDownloading else { return }
        incompleteDownload = nil
        isDownloading = true
        status = "Saving downloaded segments…"
        activeIncompleteDownload = incomplete
        let operationID = beginOperation()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.savePartial(incomplete) { update in
                    await self.apply(update)
                }
                guard self.isCurrent(operationID) else { return }
                completedOutput = output
                progress = 1
                status = "Done!"
                finishOperation(operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                incompleteDownload = incomplete
                errorMessage = error.localizedDescription
                status = "Error"
                finishOperation(operationID)
            }
        }
    }

    func retryIncompleteDownload() {
        guard let incomplete = incompleteDownload, !isDownloading else { return }
        incompleteDownload = nil
        isDownloading = true
        status = "Retrying from the failed segment…"
        activeIncompleteDownload = incomplete
        let operationID = beginOperation()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await DownloadEngine.retry(incomplete) { update in
                    await self.apply(update)
                }
                guard self.isCurrent(operationID) else { return }
                completedOutput = output
                progress = 1
                status = "Done!"
                finishOperation(operationID)
            } catch DownloadError.incomplete(let nextIncomplete) {
                guard self.isCurrent(operationID) else { return }
                incompleteDownload = nextIncomplete
                status = "Download incomplete"
                finishOperation(operationID)
            } catch is CancellationError {
                finishCancelled(operationID)
            } catch {
                guard self.isCurrent(operationID) else { return }
                errorMessage = error.localizedDescription
                status = "Error"
                finishOperation(operationID)
            }
        }
    }

    func cancelCurrentDownload() {
        guard isDownloading else { return }
        activeTask?.cancel()
        if let incomplete = activeIncompleteDownload {
            DownloadEngine.discard(incomplete)
        }
        activeTask = nil
        activeOperationID = nil
        activeIncompleteDownload = nil
        incompleteDownload = nil
        completedOutput = nil
        errorMessage = nil
        progress = 0
        isDownloading = false
        status = "Cancelled"
    }

    func discardIncompleteDownload() {
        guard let incomplete = incompleteDownload else { return }
        DownloadEngine.discard(incomplete)
        incompleteDownload = nil
        status = "Ready"
    }

    private func apply(_ update: DownloadUpdate) {
        guard isDownloading else { return }
        status = update.status
        progress = update.progress
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
        isDownloading = false
    }

    private func finishCancelled(_ operationID: UUID) {
        guard isCurrent(operationID) else { return }
        activeTask = nil
        activeOperationID = nil
        activeIncompleteDownload = nil
        progress = 0
        status = "Cancelled"
        isDownloading = false
    }
}

enum DownloadEngine {
    private static let segmentDuration = 3.84
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

    static func run(
        _ request: DownloadRequest,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws -> URL {
        guard request.duration > 0 else { throw DownloadError.invalidDuration }
        let urlText = request.stream.url.lowercased()
        guard urlText.hasSuffix(".mpd") || urlText.hasSuffix(".m3u8") else {
            throw DownloadError.invalidStream
        }
        guard request.start <= Date() else { throw DownloadError.futureTime }
        let now = Date()
        let earliestAllowedDay = Calendar.current.date(
            byAdding: .day,
            value: -14,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now
        guard request.start >= earliestAllowedDay else {
            throw DownloadError.dateTooOld
        }

        let startSegment = Int(floor(request.start.timeIntervalSince1970 / segmentDuration))
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
        let output = request.outputFolder.appendingPathComponent("\(safeFilename(request.stream.name))_\(startSegment).mp4")

        if urlText.hasSuffix(".mpd") {
            await update(.init(status: "Reading MPD…", progress: 0))
            let representations = try await parseMPD(URL(string: request.stream.url)!)
            guard let video = selectVideo(from: representations), let audio = selectAudio(from: representations) else {
                throw DownloadError.processFailed("No usable video and audio representations were found.")
            }

            await update(.init(status: "Downloading initialisation files…", progress: 0))
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

            await update(.init(status: "Combining video fragments…", progress: 1))
            try concatenate([workspace.appendingPathComponent("video.init")] + availableSegments.map {
                workspace.appendingPathComponent("v_\($0).m4s")
            }, to: workspace.appendingPathComponent("video.mp4"))
            await update(.init(status: "Combining audio fragments…", progress: 1))
            try concatenate([workspace.appendingPathComponent("audio.init")] + availableSegments.map {
                workspace.appendingPathComponent("a_\($0).m4s")
            }, to: workspace.appendingPathComponent("audio.mp4"))
            await update(.init(status: request.encodeH265 ? "Encoding…" : "Merging…", progress: 1))
            try runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("video.mp4").path,
                "-i", workspace.appendingPathComponent("audio.mp4").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        } else if urlText.contains(".fmp4.m3u8") {
            await update(.init(status: "Reading fMP4 playlist…", progress: 0))
            let playlist = try await parseFMP4Playlist(URL(string: request.stream.url)!)
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
            await update(.init(status: "Combining fragments…", progress: 1))
            try concatenate([workspace.appendingPathComponent("fmp4.init")] + segments.map {
                workspace.appendingPathComponent("f_\($0).m4s")
            }, to: workspace.appendingPathComponent("fmp4.mp4"))
            await update(.init(status: request.encodeH265 ? "Encoding…" : "Merging…", progress: 1))
            try runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("fmp4.mp4").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        } else {
            let playlistURL = URL(string: request.stream.url)!
            let baseURL = playlistURL.deletingLastPathComponent()
            let failures = try await fetchSegments(segments, maximumConcurrent: request.maximumConcurrentSegments, update: update) { segment in
                let file = URL(string: "\(segment).ts", relativeTo: baseURL)!.absoluteURL
                try await fetch(file, to: workspace.appendingPathComponent("\(segment).ts"), request: request)
            }
            guard failures.isEmpty else {
                preserveWorkspace = true
                throw DownloadError.incomplete(IncompleteDownload(
                    request: request,
                    workspace: workspace,
                    kind: .transportStream,
                    segments: segments,
                    failedSegments: incompleteTail(in: segments, after: failures),
                    output: output
                ))
            }
            let listing = segments.map { "file '\(workspace.appendingPathComponent("\($0).ts").path)'" }
                .joined(separator: "\n")
            try listing.write(to: workspace.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
            await update(.init(status: request.encodeH265 ? "Encoding…" : "Merging…", progress: 1))
            try runFFmpeg([
                "-y", "-f", "concat", "-safe", "0", "-i", workspace.appendingPathComponent("list.txt").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        }

        return output
    }

    static func savePartial(
        _ incomplete: IncompleteDownload,
        update: @escaping @Sendable (DownloadUpdate) async -> Void
    ) async throws -> URL {
        guard let firstFailedSegment = incomplete.failedSegments.min() else {
            throw DownloadError.processFailed("There are no failed segments to save around.")
        }
        let available = incomplete.segments.filter { $0 < firstFailedSegment }
            .prefix { segmentIsComplete($0, in: incomplete) }
        guard !available.isEmpty else {
            throw DownloadError.processFailed("There are no downloaded segments available to save.")
        }
        await update(.init(status: "Saving downloaded video…", progress: 1))
        try finish(
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
        guard let firstFailedSegment = incomplete.failedSegments.min() else {
            throw DownloadError.processFailed("There are no failed segments to retry.")
        }
        let retrySegments = incomplete.segments.filter { $0 >= firstFailedSegment }
        var segmentsToFinish = incomplete.segments

        switch incomplete.kind {
        case .mpd:
            let representations = try await parseMPD(URL(string: incomplete.request.stream.url)!)
            guard let video = selectVideo(from: representations), let audio = selectAudio(from: representations) else {
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
            let failures = try await fetchMPDSegmentsInOrder(
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
            let playlist = try await parseFMP4Playlist(URL(string: incomplete.request.stream.url)!)
            if !FileManager.default.fileExists(atPath: incomplete.workspace.appendingPathComponent("fmp4.init").path) {
                try await fetch(playlist.initialization, to: incomplete.workspace.appendingPathComponent("fmp4.init"), request: incomplete.request)
            }
            for (index, segment) in retrySegments.enumerated() {
                do {
                    try await fetch(segmentURL(playlist.media, number: segment), to: incomplete.workspace.appendingPathComponent("f_\(segment).m4s"), request: incomplete.request)
                } catch {
                    throw retryFailure(for: incomplete, segment: segment)
                }
                await update(.init(status: "Retrying \(index + 1)/\(retrySegments.count) segments…", progress: Double(index + 1) / Double(max(1, retrySegments.count))))
            }
        case .transportStream:
            let baseURL = URL(string: incomplete.request.stream.url)!.deletingLastPathComponent()
            for (index, segment) in retrySegments.enumerated() {
                do {
                    let file = URL(string: "\(segment).ts", relativeTo: baseURL)!.absoluteURL
                    try await fetch(file, to: incomplete.workspace.appendingPathComponent("\(segment).ts"), request: incomplete.request)
                } catch {
                    throw retryFailure(for: incomplete, segment: segment)
                }
                await update(.init(status: "Retrying \(index + 1)/\(retrySegments.count) segments…", progress: Double(index + 1) / Double(max(1, retrySegments.count))))
            }
        }

        await update(.init(status: incomplete.request.encodeH265 ? "Encoding…" : "Merging…", progress: 1))
        try finish(
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
    ) throws {
        switch kind {
        case .mpd:
            try concatenate([workspace.appendingPathComponent("video.init")] + segments.map {
                workspace.appendingPathComponent("v_\($0).m4s")
            }, to: workspace.appendingPathComponent("video.mp4"))
            try concatenate([workspace.appendingPathComponent("audio.init")] + segments.map {
                workspace.appendingPathComponent("a_\($0).m4s")
            }, to: workspace.appendingPathComponent("audio.mp4"))
            try runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("video.mp4").path,
                "-i", workspace.appendingPathComponent("audio.mp4").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        case .fmp4:
            try concatenate([workspace.appendingPathComponent("fmp4.init")] + segments.map {
                workspace.appendingPathComponent("f_\($0).m4s")
            }, to: workspace.appendingPathComponent("fmp4.mp4"))
            try runFFmpeg([
                "-y", "-i", workspace.appendingPathComponent("fmp4.mp4").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        case .transportStream:
            let listing = segments.map { "file '\(workspace.appendingPathComponent("\($0).ts").path)'" }
                .joined(separator: "\n")
            try listing.write(to: workspace.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
            try runFFmpeg([
                "-y", "-f", "concat", "-safe", "0", "-i", workspace.appendingPathComponent("list.txt").path
            ] + codecArguments(encodeH265: request.encodeH265) + [output.path])
        }
    }

    private static func fetchSegments(
        _ segments: [Int],
        maximumConcurrent: Int,
        update: @escaping @Sendable (DownloadUpdate) async -> Void,
        action: @escaping @Sendable (Int) async throws -> Void
    ) async throws -> [Int] {
        try Task.checkCancellation()
        var failures: [Int] = []
        var completed = 0
        var nextSegmentIndex = 0
        let simultaneousDownloads = min(max(1, maximumConcurrent), segments.count)

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
                    status: "Downloading \(completed)/\(segments.count) segments…",
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
        let files = segments.flatMap { segment in
            [
                MPDMediaFile(
                    segment: segment,
                    source: segmentURL(video.media, number: segment),
                    output: workspace.appendingPathComponent("v_\(segment).m4s")
                ),
                MPDMediaFile(
                    segment: segment,
                    source: segmentURL(audio.media, number: segment),
                    output: workspace.appendingPathComponent("a_\(segment).m4s")
                )
            ]
        }
        let segmentPositions = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element, $0.offset + 1) })
        var successfulParts = Dictionary(uniqueKeysWithValues: segments.map { ($0, 0) })
        var failedSegments = Set<Int>()
        var nextFileIndex = 0
        var stopQueueing = false
        let transferLimit = min(max(1, maximumConcurrent), files.count)

        func completedPrefix() -> Int {
            var count = 0
            for segment in segments {
                guard failedSegments.contains(segment) == false, successfulParts[segment] == 2 else { break }
                count += 1
            }
            return count
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
                        try await fetchMPDFileIfNeeded(file.source, to: file.output, request: request, onRetry: retryUpdate)
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
                    status: "\(statusPrefix) segment \(min(completed + 1, segments.count)) of \(segments.count)…",
                    progress: Double(completed) / Double(segments.count)
                ))
                enqueueNextFile()
            }
        }
        try Task.checkCancellation()
        return failedSegments.sorted()
    }

    private static func fetchMPDSegmentsInOrder(
        _ segments: [Int],
        video: MPDRepresentation,
        audio: MPDRepresentation,
        workspace: URL,
        maximumConcurrent: Int,
        request: DownloadRequest,
        update: @escaping @Sendable (DownloadUpdate) async -> Void,
        statusPrefix: String
    ) async throws -> [Int] {
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let position = index + 1
            let progress = Double(index) / Double(max(1, segments.count))
            await update(.init(
                status: "\(statusPrefix) segment \(position) of \(segments.count)…",
                progress: progress
            ))

            let retryUpdate: @Sendable (Int) async -> Void = { nextAttempt in
                await update(.init(
                    status: "Retrying segment \(position) of \(segments.count) (attempt \(nextAttempt)/\(request.retryAttempts))…",
                    progress: progress
                ))
            }
            do {
                if maximumConcurrent > 1 {
                    async let videoDownload: Void = fetchMPDFileIfNeeded(
                        segmentURL(video.media, number: segment),
                        to: workspace.appendingPathComponent("v_\(segment).m4s"),
                        request: request,
                        onRetry: retryUpdate
                    )
                    async let audioDownload: Void = fetchMPDFileIfNeeded(
                        segmentURL(audio.media, number: segment),
                        to: workspace.appendingPathComponent("a_\(segment).m4s"),
                        request: request,
                        onRetry: retryUpdate
                    )
                    try await videoDownload
                    try await audioDownload
                } else {
                    try await fetchMPDFileIfNeeded(
                        segmentURL(video.media, number: segment),
                        to: workspace.appendingPathComponent("v_\(segment).m4s"),
                        request: request,
                        onRetry: retryUpdate
                    )
                    try await fetchMPDFileIfNeeded(
                        segmentURL(audio.media, number: segment),
                        to: workspace.appendingPathComponent("a_\(segment).m4s"),
                        request: request,
                        onRetry: retryUpdate
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return [segment]
            }

            await update(.init(
                status: "\(statusPrefix) segment \(position) of \(segments.count)…",
                progress: Double(position) / Double(max(1, segments.count))
            ))
        }
        return []
    }

    private static func fetchMPDFileIfNeeded(
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
                let (data, response) = try await URLSession.shared.data(for: request)
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
            try destination.write(contentsOf: Data(contentsOf: file))
        }
    }

    private static func codecArguments(encodeH265: Bool) -> [String] {
        encodeH265 ? ["-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "copy"] : ["-c", "copy"]
    }

    private static func runFFmpeg(_ arguments: [String]) throws {
        let locations = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DownloadError.ffmpegMissing
        }
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "ffmpeg could not create the video."
            throw DownloadError.processFailed(detail)
        }
    }

    private static func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    private static func segmentURL(_ template: URL, number: Int) -> URL {
        let string = fillSegmentTemplate(template.absoluteString, number: number)
        return URL(string: string)!
    }

    private static func fillSegmentTemplate(_ template: String, number: Int) -> String {
        var result = template
            .replacingOccurrences(of: "$Number$", with: String(number))
            .replacingOccurrences(of: "$Time$", with: String(number))
        let pattern = #"\$Number%0(\d+)d\$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let widthRange = Range(match.range(at: 1), in: result), let tokenRange = Range(match.range, in: result) else { continue }
            let width = Int(result[widthRange]) ?? 0
            result.replaceSubrange(tokenRange, with: String(format: "%0\(width)d", number))
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
        return SegmentTemplate(
            initialization: URL(string: mapPath, relativeTo: base)!.absoluteURL,
            media: URL(string: template, relativeTo: base)!.absoluteURL
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

    private static func parseMPD(_ url: URL) async throws -> [MPDRepresentation] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let parser = MPDParser(baseURL: url.deletingLastPathComponent())
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw DownloadError.processFailed("Could not read the MPD stream manifest.")
        }
        return parser.representations
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

private struct SegmentTemplate {
    let initialization: URL
    let media: URL
}

private struct MPDMediaFile: Sendable {
    let segment: Int
    let source: URL
    let output: URL
}

private struct MPDRepresentation {
    enum MediaType { case audio, video }
    let type: MediaType
    let bandwidth: Int
    let initialization: URL
    let media: URL
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
    }

    let baseURL: URL
    var representations: [MPDRepresentation] = []
    private var adaptation: Adaptation?
    private var representation: Representation?

    init(baseURL: URL) {
        self.baseURL = baseURL
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
            let template = RawTemplate(initialization: initialization, media: media)
            if representation != nil {
                representation?.template = template
            } else {
                adaptation?.template = template
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
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
            representations.append(MPDRepresentation(
                type: type,
                bandwidth: representation.bandwidth,
                initialization: URL(string: initialization, relativeTo: baseURL)!.absoluteURL,
                media: URL(string: media, relativeTo: baseURL)!.absoluteURL
            ))
            self.representation = nil
        case "AdaptationSet":
            adaptation = nil
        default:
            break
        }
    }
}
