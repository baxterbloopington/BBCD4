import AVFoundation
import Darwin
import Foundation

enum MediaTrimPreferences {
    static let enabledKey = "askToTrimCompletedVideos"
    static let defaultEnabled = false

    static func canEncodeDownload(category: StreamCategory, editing: Bool) -> Bool {
        category != .radio && !editing
    }
}

struct MediaTrimSelection: Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }

    func validated(for duration: Double) throws -> CMTimeRange {
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite,
              duration <= FrameTimecode.maximumTime,
              start >= 0, end > start, end <= duration + 0.000_5 else {
            throw MediaTrimError.invalidRange
        }
        return CMTimeRange(
            start: CMTime(value: Int64((start * 600_000).rounded()), timescale: 600_000),
            end: CMTime(value: Int64((min(end, duration) * 600_000).rounded()), timescale: 600_000)
        )
    }
}

enum MediaTrimPlan {
    static func inclusiveCut(from first: Double, through last: Double, within selection: MediaTrimSelection,
                             frameDuration: Double) -> MediaTrimSelection? {
        guard first.isFinite, last.isFinite, frameDuration.isFinite, frameDuration > 0,
              selection.start.isFinite, selection.end.isFinite, selection.start >= 0,
              selection.end > selection.start, selection.end <= FrameTimecode.maximumTime else { return nil }
        let firstFrame = floor(selection.start / frameDuration + 0.000_000_1)
        let lastFrame = max(firstFrame, ceil(selection.end / frameDuration - 0.000_000_1) - 1)
        let a = min(lastFrame, max(firstFrame, floor(first / frameDuration + 0.000_000_1)))
        let b = min(lastFrame, max(firstFrame, floor(last / frameDuration + 0.000_000_1)))
        let lower = max(selection.start, min(a, b) * frameDuration)
        let upper = min(selection.end, (max(a, b) + 1) * frameDuration)
        return upper > lower ? .init(start: lower, end: upper) : nil
    }

    static func keptSelections(in selection: MediaTrimSelection, removing cuts: [MediaTrimSelection],
                               duration: Double) throws -> [MediaTrimSelection] {
        let outer = try selection.validated(for: duration)
        let removed = try cuts.map { try $0.validated(for: duration) }.sorted { $0.start < $1.start }
        var cursor = outer.start.seconds
        let end = outer.end.seconds
        var kept: [MediaTrimSelection] = []
        for cut in removed {
            let lower = max(outer.start.seconds, cut.start.seconds)
            let upper = min(end, cut.end.seconds)
            guard upper > lower else { continue }
            if lower > cursor { kept.append(.init(start: cursor, end: lower)) }
            cursor = max(cursor, upper)
        }
        if cursor < end { kept.append(.init(start: cursor, end: end)) }
        guard !kept.isEmpty else { throw MediaTrimError.emptySelection }
        return kept
    }
}

enum FrameTimecode {
    static let maximumTime = 1_000_000_000.0

    static func allowsEditing(_ input: String) -> Bool {
        input.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ":") }
    }

    static func nominalRate(frameDuration: Double) -> Int? {
        guard frameDuration.isFinite, frameDuration > 0 else { return nil }
        let rate = (1 / frameDuration).rounded()
        guard rate >= 1, rate <= 1_000 else { return nil }
        return Int(rate)
    }

    static func parse(_ input: String, frameDuration: Double = 1.0 / 30) -> Double? {
        guard allowsEditing(input), let rate = nominalRate(frameDuration: frameDuration) else { return nil }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty }),
              let hours = Int(parts[0]), hours >= 0, hours <= Int(maximumTime / 3_600),
              let minutes = Int(parts[1]), (0..<60).contains(minutes),
              let seconds = Int(parts[2]), (0..<60).contains(seconds),
              let frames = Int(parts[3]), (0..<rate).contains(frames) else { return nil }
        let totalFrames = ((Double(hours) * 60 + Double(minutes)) * 60 + Double(seconds)) * Double(rate) + Double(frames)
        let result = totalFrames * frameDuration
        return result.isFinite && result <= maximumTime ? result : nil
    }

    static func format(_ seconds: Double, frameDuration: Double = 1.0 / 30, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumTime,
              let rate = nominalRate(frameDuration: frameDuration) else { return "00:00:00:00" }
        let frame = Int((seconds / frameDuration + 0.000_000_1).rounded(rounding))
        return String(format: "%02d:%02d:%02d:%0*d", frame / (rate * 3_600), frame / (rate * 60) % 60,
                      frame / rate % 60, max(2, String(rate - 1).count), frame % rate)
    }
}

enum AudioTimecode {
    static func parse(_ input: String) -> Double? {
        guard !input.isEmpty, input.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }) else { return nil }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              let seconds = Double(parts[2]), hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        let value = Double(hours) * 3_600 + Double(minutes) * 60 + seconds
        return value.isFinite && value <= FrameTimecode.maximumTime ? value : nil
    }

    static func format(_ seconds: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= FrameTimecode.maximumTime else { return "00:00:00.000" }
        let milliseconds = Int((seconds * 1_000 + 0.000_000_1).rounded(rounding))
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1_000 % 60, milliseconds % 1_000)
    }
}

enum MediaTrimError: LocalizedError {
    case invalidRange, emptySelection, unfinishedCut, cutsRequireEncoding, audioSectionTooShort, sourceChanged, noMedia, unsupported, inaccurateExport, previewUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRange: "Invalid time range."
        case .emptySelection: "The cuts remove the entire selection. Remove a cut or extend the trim range before saving."
        case .unfinishedCut: "Move the playhead to the cut's other end and click the scissors again, or cancel the cut."
        case .cutsRequireEncoding: "Video cuts require Encode and save. Remove all cuts to save video without encoding."
        case .audioSectionTooShort: "A retained audio section is too short to copy without encoding. Use Encode and save for precise cuts."
        case .sourceChanged: "The media changed while saving. Your file was not overwritten. Reopen it before trying again."
        case .noMedia: "This file does not contain a playable video or audio track. The original download has been kept."
        case .unsupported: "This media cannot be trimmed without re-encoding. The original download has been kept."
        case .inaccurateExport: "The edited media did not preserve the selected timing. Your file was not overwritten."
        case .previewUnavailable: "A media preview could not be opened. The original download has been kept."
        }
    }
}

enum MediaTrimmer {
    static func export(source: URL, selection: MediaTrimSelection, cuts: [MediaTrimSelection] = [], encoding: EncodingConfiguration? = nil,
                       onProgress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        let sourceVersion = try SourceVersion(source)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let selections = try MediaTrimPlan.keptSelections(in: selection, removing: cuts, duration: duration)
        let ranges = try selections.map { try $0.validated(for: duration) }
        let outputDuration = ranges.reduce(0) { $0 + $1.duration.seconds }
        var expectedDuration = outputDuration
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasVideo = !videoTracks.isEmpty
        let hasAudio = !audioTracks.isEmpty
        guard hasVideo || hasAudio else { throw MediaTrimError.noMedia }
        guard encoding != nil || cuts.isEmpty || !hasVideo else { throw MediaTrimError.cutsRequireEncoding }
        let folder = source.deletingLastPathComponent()
        var temporary = folder.appendingPathComponent(".bbcd4-trim-\(UUID().uuidString).\(hasVideo ? "mp4" : "m4a")")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let encoding {
            let inputArguments: [String]
            if let range = ranges.first, ranges.count == 1 {
                inputArguments = ["-ss", timestamp(range.start.seconds), "-accurate_seek", "-i", source.path,
                                  "-t", timestamp(range.duration.seconds)]
                    + (hasVideo ? ["-map", "0:v:0"] : []) + (hasAudio ? ["-map", "0:a:0"] : [])
            } else {
                let offset = ranges[0].start.seconds
                var filters: [String] = []
                var inputs = ""
                for (index, range) in ranges.enumerated() {
                    let bounds = "start=\(timestamp(range.start.seconds - offset)):end=\(timestamp(range.end.seconds - offset))"
                    if hasVideo {
                        filters.append("[0:v:0]trim=\(bounds),setpts=PTS-STARTPTS[v\(index)]")
                        inputs += "[v\(index)]"
                    }
                    if hasAudio {
                        filters.append("[0:a:0]atrim=\(bounds),asetpts=PTS-STARTPTS[a\(index)]")
                        inputs += "[a\(index)]"
                    }
                }
                filters.append("\(inputs)concat=n=\(ranges.count):v=\(hasVideo ? 1 : 0):a=\(hasAudio ? 1 : 0)\(hasVideo ? "[v]" : "")\(hasAudio ? "[a]" : "")")
                inputArguments = ["-ss", timestamp(offset), "-accurate_seek", "-i", source.path,
                                  "-filter_complex", filters.joined(separator: ";")]
                    + (hasVideo ? ["-map", "[v]"] : []) + (hasAudio ? ["-map", "[a]"] : [])
            }
            try await MediaProcess.runFFmpegWithProgress(arguments:
                inputArguments + ["-map_metadata", "0", "-sn", "-dn"]
                + (hasVideo ? encoding.videoArguments(copyAudio: false) + ["-fps_mode", "passthrough"] : ["-vn"])
                + (hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : [])
                + ["-movflags", "+faststart", temporary.path],
                duration: outputDuration, onProgress: onProgress)
        } else if !hasVideo, ranges.count > 1, let audioTrack = audioTracks.first {
            expectedDuration = try await copyAudioPackets(asset: asset, track: audioTrack, ranges: ranges, to: temporary)
        } else {

            let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
            movie.timescale = 600_000
            movie.metadata = try await asset.load(.metadata)
            try movie.insertTimeRange(ranges[0], of: asset, at: .zero, copySampleData: false)
            let fileType: AVFileType = hasVideo ? .mp4 : .m4a
            guard let exporter = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough),
                  await exporter.compatibleFileTypes.contains(fileType) else { throw MediaTrimError.unsupported }
            do { try await exporter.export(to: temporary, as: fileType) }
            catch { try Task.checkCancellation(); throw error }
        }
        try Task.checkCancellation()

        var result = AVURLAsset(url: temporary, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var exportedDuration = try await result.load(.duration).seconds
        if encoding == nil, !hasVideo, ranges.count == 1, let audioTrack = audioTracks.first,
           !exportedDuration.isFinite || abs(exportedDuration - expectedDuration) > 0.001 {
            try FileManager.default.removeItem(at: temporary)
            temporary = folder.appendingPathComponent(".bbcd4-trim-\(UUID().uuidString).m4a")
            expectedDuration = try await copyAudioPackets(asset: asset, track: audioTrack, ranges: ranges, to: temporary)
            result = AVURLAsset(url: temporary, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            exportedDuration = try await result.load(.duration).seconds
        }
        if encoding == nil {
            guard exportedDuration.isFinite, abs(exportedDuration - expectedDuration) <= 0.001,
                  try await codecs(in: result) == codecs(in: asset) else { throw MediaTrimError.inaccurateExport }
        } else if let videoTrack = videoTracks.first {
            let rate = try await videoTrack.load(.nominalFrameRate)
            let tolerance = max(rate > 0 ? 1 / Double(rate) : 0.04, 0.025) + 0.005
            guard exportedDuration.isFinite, exportedDuration > 0,
                  abs(exportedDuration - outputDuration) <= tolerance,
                  try await !result.loadTracks(withMediaType: .video).isEmpty else { throw MediaTrimError.inaccurateExport }
        } else {
            guard exportedDuration.isFinite, exportedDuration > 0, abs(exportedDuration - outputDuration) <= 0.03,
                  try await !result.loadTracks(withMediaType: .audio).isEmpty,
                  try await result.loadTracks(withMediaType: .video).isEmpty else { throw MediaTrimError.inaccurateExport }
        }
        try Task.checkCancellation()

        guard try SourceVersion(source) == sourceVersion else { throw MediaTrimError.sourceChanged }
        if let permissions = sourceVersion.permissions {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: temporary.path)
        }
        try Task.checkCancellation()

        let replacementError = temporary.withUnsafeFileSystemRepresentation { input -> Int32 in
            source.withUnsafeFileSystemRepresentation { output -> Int32 in
                guard let input, let output else { return EINVAL }
                return Darwin.rename(input, output) == 0 ? 0 : errno
            }
        }
        guard replacementError == 0 else { throw POSIXError(POSIXErrorCode(rawValue: replacementError) ?? .EIO) }
        if encoding != nil { await onProgress(1) }
        return source
    }

    private static func copyAudioPackets(asset: AVAsset, track: AVAssetTrack, ranges: [CMTimeRange], to output: URL) async throws -> Double {
        guard let format = try await track.load(.formatDescriptions).first else { throw MediaTrimError.unsupported }
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)

        writer.movieTimeScale = try await track.load(.naturalTimeScale)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        writer.metadata = try await asset.load(.metadata)
        guard writer.canAdd(input) else { throw MediaTrimError.unsupported }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaTrimError.unsupported }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        var outputTime = CMTime.zero
        for range in ranges {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            samples.alwaysCopiesSampleData = false
            reader.timeRange = range
            guard reader.canAdd(samples) else { throw MediaTrimError.unsupported }
            reader.add(samples)
            guard reader.startReading() else { throw reader.error ?? MediaTrimError.unsupported }
            defer { reader.cancelReading() }
            let sectionStart = outputTime
            while let buffer = samples.copyNextSampleBuffer() {
                try Task.checkCancellation()
                for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                    try Task.checkCancellation()
                    var packet: CMSampleBuffer?
                    guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                        sampleRange: CFRange(location: index, length: 1), sampleBufferOut: &packet) == noErr,
                          let packet else { throw MediaTrimError.unsupported }
                    let time = CMSampleBufferGetPresentationTimeStamp(packet)
                    let duration = CMSampleBufferGetDuration(packet)
                    guard time.isNumeric, duration.isNumeric, duration.seconds > 0 else { throw MediaTrimError.unsupported }

                    guard CMTimeCompare(time, range.start) >= 0,
                          CMTimeCompare(CMTimeAdd(time, duration), range.end) <= 0 else { continue }
                    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: outputTime, decodeTimeStamp: .invalid)
                    var retimed: CMSampleBuffer?
                    guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: packet,
                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
                          let retimed else { throw MediaTrimError.unsupported }
                    CMRemoveAttachment(retimed, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
                    CMRemoveAttachment(retimed, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writer.status == .writing else { throw writer.error ?? MediaTrimError.unsupported }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard input.append(retimed) else { throw writer.error ?? MediaTrimError.unsupported }
                    outputTime = CMTimeAdd(outputTime, duration)
                }
            }
            if reader.status == .failed { throw reader.error ?? MediaTrimError.unsupported }
            guard CMTimeCompare(outputTime, sectionStart) > 0 else { throw MediaTrimError.audioSectionTooShort }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: outputTime)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? MediaTrimError.unsupported }
        return outputTime.seconds
    }

    private struct SourceVersion: Equatable {
        let fileNumber: UInt64?
        let volumeNumber: UInt64?
        let size: UInt64?
        let modified: Date?
        let permissions: UInt16?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            volumeNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
            size = (attributes[.size] as? NSNumber)?.uint64Value
            modified = attributes[.modificationDate] as? Date
            permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private static func codecs(in asset: AVAsset) async throws -> [FourCharCode] {
        var result: [FourCharCode] = []
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                result += try await track.load(.formatDescriptions).map { CMFormatDescriptionGetMediaSubType($0) }
            }
        }
        return result
    }
}
