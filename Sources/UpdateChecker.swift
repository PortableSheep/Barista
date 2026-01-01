import Foundation

struct UpdateInfo {
    let tag: String
    let url: URL
}

@MainActor
final class GitHubUpdateChecker {
    private struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }

    private let repoSlug: String
    private(set) var isChecking = false

    init(repoSlug: String) {
        self.repoSlug = repoSlug
    }

    func check(currentVersion: String) async -> UpdateInfo? {
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }

        let apiURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!

        do {
            let (data, _) = try await URLSession.shared.data(for: makeGitHubRequest(url: apiURL))
            let latest = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)

            if latest.draft == true || latest.prerelease == true {
                return nil
            }

            guard let url = URL(string: latest.html_url) else { return nil }
            if isVersion(latest.tag_name, newerThan: currentVersion) {
                return UpdateInfo(tag: latest.tag_name, url: url)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func makeGitHubRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Barista", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func normalizedVersion(_ version: String) -> [Int] {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "v", with: "", options: [.anchored])

        return cleaned
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let va = normalizedVersion(a)
        let vb = normalizedVersion(b)
        let n = max(va.count, vb.count)
        for i in 0..<n {
            let ai = i < va.count ? va[i] : 0
            let bi = i < vb.count ? vb[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}
