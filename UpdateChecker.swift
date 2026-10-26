import Foundation

private enum AppVersion {
    static let releaseVersion = "3.9"
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? releaseVersion
}

struct AvailableRelease: Sendable {
    let version: String
    let url: URL
    let notes: String
}

enum UpdateCheckFrequency: String, CaseIterable {
    case onLaunch, hourly, daily, never

    static let preferenceKey = "updateCheckFrequency"

    var title: String {
        switch self {
        case .onLaunch: "On app launch"
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .never: "Never"
        }
    }

    var interval: Duration? {
        switch self {
        case .hourly: .seconds(3_600)
        case .daily: .seconds(86_400)
        case .onLaunch, .never: nil
        }
    }

    static func migratePreferences(in defaults: UserDefaults = .standard) {
        if defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) == nil {
            let legacyEnabled = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
            defaults.set((legacyEnabled ? Self.onLaunch : .never).rawValue, forKey: preferenceKey)
        }
        defaults.removeObject(forKey: "checkForUpdates")
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var release: AvailableRelease?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sleep: @Sendable (Duration) async throws -> Void
    private let currentVersion: String
    private var generation = UUID()
    private var retryNotBefore = Date.distantPast

    init(
        currentVersion: String = AppVersion.current,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.sleep = sleep
    }

    func run(frequency: UpdateCheckFrequency) async {
        let generation = UUID()
        self.generation = generation
        guard frequency != .never else { return }
        do {
            repeat {
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                await check(generation: generation)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard let interval = frequency.interval else { return }
                try await sleep(interval)
            } while !Task.isCancelled
        } catch {}
    }

    private func check(generation: UUID) async {
        guard Date() >= retryNotBefore else { return }
        guard let url = URL(string: "https://api.github.com/repos/baxterbloopington/BBCD4/releases/latest") else {
            return
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("BBCD4", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard self.generation == generation, let response = response as? HTTPURLResponse else { return }
            if response.statusCode == 403 || response.statusCode == 429 {
                let retryDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) ?? 0
                retryNotBefore = max(Date().addingTimeInterval(max(60, retryDelay)), Date(timeIntervalSince1970: reset))
            }
            guard response.statusCode == 200 else { return }
            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(version, than: currentVersion), let releaseURL = URL(string: payload.htmlURL) else {
                release = nil
                return
            }
            release = AvailableRelease(
                version: version,
                url: releaseURL,
                notes: payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {}
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let left = candidateParts.indices.contains(index) ? candidateParts[index] : 0
            let right = currentParts.indices.contains(index) ? currentParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }
}
