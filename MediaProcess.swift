import Darwin
import Foundation

enum MediaProcess {
    static func ffmpegExecutable() throws -> URL {
        let locations = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DownloadError.ffmpegMissing
        }
        return URL(fileURLWithPath: path)
    }

    static func runFFmpegWithProgress(
        arguments: [String],
        duration: Double,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let executable = try ffmpegExecutable()
        let reader = FFmpegProgressReader()
        let totalDuration = duration.isFinite && duration > 0 ? duration : 1
        let (updates, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await onProgress(0)
        let delivery = Task {
            var previous = 0.0
            for await progress in updates {
                guard !Task.isCancelled else { return }
                guard progress > previous else { continue }
                previous = progress
                await onProgress(progress)
            }
        }
        do {
            try await run(
                executable: executable,
                arguments: ["-v", "error", "-nostdin", "-progress", "pipe:1", "-nostats"] + arguments
            ) { data in
                if let seconds = reader.consume(data).last {
                    continuation.yield(min(0.99, max(0, seconds / totalDuration)))
                }
            }
            continuation.finish()
            await delivery.value
            try Task.checkCancellation()
        } catch {
            continuation.finish()
            delivery.cancel()
            await delivery.value
            throw error
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let diagnostics = BoundedProcessOutput()
        let outputReadLock = NSLock()
        let errorReadLock = NSLock()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            outputReadLock.withLock {
                let data = handle.availableData
                if !data.isEmpty { onOutput?(data) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorReadLock.withLock { diagnostics.append(handle.availableData) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        output.fileHandleForReading.readabilityHandler = nil
        outputReadLock.withLock {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty { onOutput?(data) }
        }
        errors.fileHandleForReading.readabilityHandler = nil
        errorReadLock.withLock { diagnostics.append(errors.fileHandleForReading.readDataToEndOfFile()) }
        guard process.terminationStatus == 0 else {
            throw DownloadError.processFailed(diagnostics.message)
        }
    }
}

final class FFmpegProgressReader: @unchecked Sendable {
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

final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int = 65_536) { self.limit = max(1, limit) }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk.suffix(limit))
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var message: String {
        lock.withLock {
            data.isEmpty ? "ffmpeg could not create the media file." : String(decoding: data, as: UTF8.self)
        }
    }
}
