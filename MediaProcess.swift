import Darwin
import Foundation

enum MediaProcess {
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
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onOutput?(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            diagnostics.append(handle.availableData)
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
        errors.fileHandleForReading.readabilityHandler = nil
        diagnostics.append(errors.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else {
            throw DownloadError.processFailed(diagnostics.message)
        }
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
