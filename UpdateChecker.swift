import Foundation

private enum AppVersion {
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0.1"
}

struct AvailableRelease: Sendable {
    let version: String
    let url: URL
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var release: AvailableRelease?

    func check() async {
        guard let url = URL(string: "https://api.github.com/repos/baxterbloopington/BBCD4/releases/latest") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("BBCD4", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(version, than: AppVersion.current), let releaseURL = URL(string: payload.htmlURL) else { return }
            release = AvailableRelease(version: version, url: releaseURL)
        } catch {
            release = nil
        }
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

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
