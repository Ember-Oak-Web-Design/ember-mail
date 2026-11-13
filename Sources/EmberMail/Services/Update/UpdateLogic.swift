import Foundation

/// Where releases are published. The app checks the repo's latest GitHub Release (the repo must be public).
enum UpdateConfig {
    static let repo = "Ember-Oak-Web-Design/ember-mail"
    static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    static let bundleID = "com.emberoak.EmberMail"
}

/// "1.2.3", "v1.2.3" or "1.2" → comparable version.
struct AppVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    let parts: [Int]

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(separator: "-").first.map(String.init) ?? s   // drop "-beta" suffixes
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

struct ReleaseInfo: Equatable, Sendable {
    var version: AppVersion
    var notes: String
    var pageURL: URL
    var zipURL: URL
    var checksumURL: URL?
}

enum UpdateLogic {
    private struct DTO: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: String }
        var tag_name: String
        var body: String?
        var html_url: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    /// Parses GitHub's "latest release" JSON. Returns nil for drafts, prereleases or releases without a .zip.
    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              dto.draft != true, dto.prerelease != true,
              let version = AppVersion(dto.tag_name),
              let page = URL(string: dto.html_url),
              let zip = dto.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let zipURL = URL(string: zip.browser_download_url) else { return nil }
        let sum = dto.assets.first { $0.name == zip.name + ".sha256" }.flatMap { URL(string: $0.browser_download_url) }
        return ReleaseInfo(version: version, notes: dto.body ?? "", pageURL: page, zipURL: zipURL, checksumURL: sum)
    }

    /// First hex token of a `shasum` style file ("<hash>  file.zip").
    static func parseChecksum(_ text: String) -> String? {
        let token = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        guard let token, token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { return nil }
        return token
    }
}
