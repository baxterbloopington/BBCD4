import AVFoundation
import Foundation
import ImageIO

enum FrameCaptureDestination: String, CaseIterable, Hashable, Sendable {
    case clipboard
    case videoFolder

    static let preferenceKey = "frameCaptureDestination"
    static let defaultDestination = Self.clipboard

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .videoFolder: "Download folder"
        }
    }

    var actionTitle: String {
        switch self {
        case .clipboard: "Copy frame to clipboard"
        case .videoFolder: "Save frame to download folder"
        }
    }
}

enum MediaFrameCapture {
    enum CaptureError: LocalizedError {
        case unavailable, invalidImage, clipboardUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "This frame could not be captured."
            case .invalidImage: "The captured frame could not be opened as an image."
            case .clipboardUnavailable: "The captured frame could not be copied to the clipboard."
            }
        }
    }

    @concurrent
    static func imageData(source: URL, time: Double) async throws -> Data {
        try Task.checkCancellation()
        guard source.isFileURL, time.isFinite, time >= 0, time <= FrameTimecode.maximumTime else {
            throw CaptureError.unavailable
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bbcd4-frame-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("frame.png")
        let timestamp = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), max(0, time - 0.000_001))
        try await MediaProcess.run(executable: MediaProcess.ffmpegExecutable(), arguments:
            ["-v", "error", "-nostdin", "-ss", timestamp, "-accurate_seek", "-i", source.path,
             "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn", "-vf", "scale=iw*sar:ih,setsar=1",
             "-c:v", "png", "-threads", "1", "-update", "1", image.path])
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(image as CFURL, nil),
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else { throw CaptureError.invalidImage }
        return try Data(contentsOf: image)
    }

    @concurrent
    static func saveImage(_ data: Data, source: URL, folder: URL, time: Double, frameDuration: Double) async throws -> URL {
        try Task.checkCancellation()
        let timecode = FrameTimecode.format(time, frameDuration: frameDuration).replacingOccurrences(of: ":", with: "-")
        let name = source.deletingPathExtension().lastPathComponent + " - " + timecode
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index = 1
        while true {
            try Task.checkCancellation()
            let suffix = index == 1 ? "" : " (\(index))"
            let image = folder.appendingPathComponent(name + suffix).appendingPathExtension("png")
            do {
                try data.write(to: image, options: .withoutOverwriting)
                return image
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                index += 1
            }
        }
    }
}

struct MediaTrimTimelineViewport: Equatable {
    private(set) var start = 0.0
    private(set) var length = 1.0
    var end: Double { start + length }
    var isZoomed: Bool { length < 1 }

    mutating func zoom(delta: Double, precise: Bool, anchor: Double, duration: Double, frameDuration: Double) {
        guard delta.isFinite, anchor.isFinite, duration.isFinite, duration > 0,
              frameDuration.isFinite, frameDuration > 0 else { return }
        let anchor = min(1, max(0, anchor))
        let time = start + anchor * length
        let minimum = min(1, max(1.0 / 1_024, 8 * frameDuration / duration))
        length = min(1, max(minimum, length * exp(-min(20, max(-20, delta)) * (precise ? 0.012 : 0.18))))
        start = min(1 - length, max(0, time - anchor * length))
    }

    mutating func pan(_ fraction: Double) {
        guard fraction.isFinite else { return }
        start = min(1 - length, max(0, start + fraction * length))
    }

    mutating func move(to fraction: Double) {
        guard fraction.isFinite else { return }
        start = min(1, max(0, fraction)) * (1 - length)
    }

    mutating func reveal(_ fraction: Double) {
        guard fraction.isFinite, isZoomed else { return }
        if fraction < start { start = max(0, fraction - length * 0.8) }
        else if fraction > end { start = min(1 - length, fraction - length * 0.2) }
    }
}

struct MediaTrimHandleDrag {
    let isStart: Bool
    var location: Double
    var width: Double

    var fraction: Double { min(1, max(0, location / width)) }

    var panPerTick: Double {
        let edge = min(24, width / 4)
        let left = max(0, (edge - location) / edge)
        let right = max(0, (location - width + edge) / edge)
        return min(1, max(-1, right - left)) * 0.8 / 30
    }
}

enum MediaTrimPlayback {
    static func range(atOrAfter time: Double, in ranges: [MediaTrimSelection]) -> MediaTrimSelection? {
        guard time.isFinite else { return nil }
        return ranges.first { $0.end > time }
    }
}

enum MediaTrimTiming {
    @concurrent
    static func frameDuration(asset: AVAsset, track: AVAssetTrack) async -> Double {
        let rate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let minimum = (try? await track.load(.minFrameDuration))?.seconds ?? 0
        let nominal = rate.isFinite && rate > 0 ? 1 / rate : 0
        let validMinimum = FrameTimecode.nominalRate(frameDuration: minimum) != nil
        let validNominal = FrameTimecode.nominalRate(frameDuration: nominal) != nil
        if validMinimum, !validNominal || abs(minimum / nominal - 1) < 0.01 { return minimum }

        if let reader = try? AVAssetReader(asset: asset) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                if reader.startReading() {
                    defer { reader.cancelReading() }
                    var intervals: [Double] = []
                    for _ in 0..<32 {
                        guard !Task.isCancelled, let sample = output.copyNextSampleBuffer() else { break }
                        let count = CMSampleBufferGetNumSamples(sample)
                        guard count > 0 else { continue }
                        let interval = CMSampleBufferGetDuration(sample).seconds / Double(count)
                        if FrameTimecode.nominalRate(frameDuration: interval) != nil { intervals.append(interval) }
                    }
                    if !intervals.isEmpty {
                        intervals.sort()
                        return intervals[intervals.count / 2]
                    }
                }
            }
        }
        if validNominal { return nominal }
        return validMinimum ? minimum : 1.0 / 30
    }

    static func editPoint(from position: Double, forward: Bool, selection: MediaTrimSelection,
                          cuts: [MediaTrimSelection], frameDuration: Double) -> Double? {
        guard position.isFinite, selection.start.isFinite, selection.end.isFinite,
              selection.start >= 0, selection.end > selection.start, selection.end <= FrameTimecode.maximumTime,
              frameDuration.isFinite, frameDuration > 0 else { return nil }
        let lastFrame = max(selection.start, (ceil(selection.end / frameDuration - 0.000_000_1) - 1) * frameDuration)
        let cutEdges = cuts.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .flatMap { [$0.start, $0.end] }
            .filter { $0 >= selection.start && $0 <= selection.end }
        let points = ([selection.start, selection.end] + cutEdges).map { min(lastFrame, $0) }.sorted()
        let tolerance = min(frameDuration / 4, 2.0 / 600_000)
        if forward { return points.first { $0 > position + tolerance } ?? lastFrame }
        return points.last { $0 < position - tolerance } ?? selection.start
    }

    static func step(from position: Double, direction: Int, duration: Double, frameDuration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, frameDuration.isFinite,
              duration > 0, duration <= FrameTimecode.maximumTime, frameDuration > 0, direction != 0 else { return nil }
        let lastFrame = max(0, ceil(duration / frameDuration - 0.000_000_1) - 1)
        let currentFrame = min(lastFrame, floor(max(0, position) / frameDuration + 0.000_000_1))
        return min(lastFrame, max(0, currentFrame + Double(direction))) * frameDuration
    }
}

struct MediaTrimWheelMotion {
    private var previousTime: Double?
    private var previousDirection = 0
    private var rapidEvents = 0
    private var fractionalFrames = 0.0

    mutating func frames(delta: Double, precise: Bool, timestamp: Double) -> Int {
        guard delta.isFinite, timestamp.isFinite, delta != 0 else { return 0 }
        let direction = delta > 0 ? -1 : 1
        let interval = previousTime.map { timestamp - $0 } ?? .infinity
        if previousDirection != direction || interval <= 0 || interval > 0.2 {
            rapidEvents = 0
            fractionalFrames = 0
        } else if interval < 0.12 {
            rapidEvents = min(28, rapidEvents + 1)
        }
        previousTime = timestamp
        previousDirection = direction
        if precise {
            fractionalFrames += min(120, abs(delta) / 8)
            let frames = Int(fractionalFrames)
            fractionalFrames -= Double(frames)
            return direction * frames
        }
        let magnitude = max(1, min(30, abs(delta).rounded()))
        let acceleration = 1 + rapidEvents / 4
        return direction * min(120, Int(magnitude) * acceleration)
    }
}

struct MediaTrimPreviewSource: Sendable {
    let url: URL
    private let temporaryDirectory: URL?

    static func prepare(source: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) async throws -> Self {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var hasInBandHEVC = false
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            hasInBandHEVC = hasInBandHEVC || formats.contains { CMFormatDescriptionGetMediaSubType($0) == 0x68657631 }
        }
        guard hasInBandHEVC else {
            guard try await asset.load(.isPlayable) else { throw MediaTrimError.previewUnavailable }
            try Task.checkCancellation()
            return Self(url: source, temporaryDirectory: nil)
        }

        let directory = temporaryRoot.appendingPathComponent("bbcd4-trim-preview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
        let preview = directory.appendingPathComponent("preview.mp4")

        try await MediaProcess.run(executable: MediaProcess.ffmpegExecutable(), arguments: [
            "-nostdin", "-v", "error", "-i", source.path,
            "-map", "0:v:0", "-map", "0:a?", "-c", "copy",
            "-bsf:v", "hevc_mp4toannexb,extract_extradata", "-tag:v", "hvc1",
            "-movflags", "+faststart", preview.path
        ])
        try Task.checkCancellation()
        let compatible = AVURLAsset(url: preview)
        let originalDuration = try await asset.load(.duration).seconds
        let previewDuration = try await compatible.load(.duration).seconds
        guard try await compatible.load(.isPlayable), originalDuration.isFinite, previewDuration.isFinite,
              abs(originalDuration - previewDuration) <= 0.001 else { throw MediaTrimError.previewUnavailable }
        try Task.checkCancellation()
        prepared = true
        return Self(url: preview, temporaryDirectory: directory)
    }

    func removeTemporaryFiles() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

@MainActor
final class MediaPreviewSeeker {
    struct Request: Equatable {
        let time: Double
        let precise: Bool
    }
    typealias Completion = @MainActor @Sendable (Bool) -> Void
    private let perform: (Request, @escaping Completion) -> Void
    private var latest: Request?
    private var active: Request?
    private var stopped = false
    var onSettled: ((Bool) -> Void)?
    var isReady = false { didSet { drain() } }
    var isSeeking: Bool { latest != nil || active != nil }

    init(perform: @escaping (Request, @escaping Completion) -> Void) { self.perform = perform }

    func seek(to time: Double, precise: Bool) {
        guard !stopped, time.isFinite else { return }
        latest = Request(time: time, precise: precise)
        drain()
    }

    private func drain() {
        guard !stopped, isReady, active == nil, let request = latest else { return }
        active = request
        perform(request) { [weak self] finished in
            guard let self, !self.stopped else { return }
            self.active = nil
            if self.latest == request { self.latest = nil }
            if self.latest != nil { self.drain() }
            else { self.onSettled?(finished) }
        }
    }

    func stop() {
        stopped = true
        isReady = false
        active = nil
        latest = nil
        onSettled = nil
    }
}

enum AudioWaveform: Equatable, Sendable {
    case loading
    case ready([Float])
    case noAudio
    case unavailable

    static func generate(source: URL, duration: Double, buckets: Int = 2_048, range: MediaTrimSelection? = nil) async throws -> Self {
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0, duration <= FrameTimecode.maximumTime else { return .unavailable }
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return .noAudio }
        let window = try (range ?? MediaTrimSelection(start: 0, end: duration)).validated(for: duration)
        let samples = WaveformPeakAccumulator(duration: window.duration.seconds, buckets: buckets)
        let length = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), window.duration.seconds)
        let start = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), window.start.seconds)
        try await MediaProcess.run(executable: MediaProcess.ffmpegExecutable(), arguments:
            ["-v", "error", "-nostdin", "-ss", start, "-i", source.path, "-t", length, "-map", "0:a:0", "-vn", "-sn", "-dn",
             "-ac", "2", "-af", "aresample=8000:async=1:first_pts=0", "-ar", "8000", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"],
            onOutput: { samples.consume($0) })
        try Task.checkCancellation()
        return .ready(samples.peaks)
    }
}

final class WaveformPeakAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var values: [Float]
    private var frameIndex = 0
    private let bucketScale: Double

    init(duration: Double, buckets: Int, sampleRate: Double = 8_000) {
        let count = min(8_192, max(1, buckets))
        values = Array(repeating: 0, count: count)
        let length = duration.isFinite && duration > 0 ? min(duration, FrameTimecode.maximumTime) : 1
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 8_000
        bucketScale = Double(count) / max(1, length * rate)
    }

    func consume(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            let length = buffer.count / 8 * 8
            buffer.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: length, by: 8) {
                    let left = Float(bitPattern: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                    let right = Float(bitPattern: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                    let peak = max(left.isFinite ? abs(left) : 0, right.isFinite ? abs(right) : 0)
                    let bucket = min(values.count - 1, Int(Double(frameIndex) * bucketScale))
                    values[bucket] = max(values[bucket], min(1, peak))
                    frameIndex += 1
                }
            }
            buffer.removeSubrange(..<length)
        }
    }

    var peaks: [Float] { lock.withLock { values } }
}
