import CryptoKit
import Foundation
import Observation

/// Read receipts: creates pixel URLs for outgoing mail and polls the tracking Worker for opens.
@MainActor
@Observable
final class TrackingStore {
    private(set) var items: [TrackedMessage] = []
    var lastRefresh: Date?
    var lastError: String?
    var isRefreshing = false

    private static let fileName = "tracked.json"
    /// Opens this soon after sending are almost always the sender's own client.
    private static let graceSeconds: TimeInterval = 15

    init() {
        items = DiskStore.load([TrackedMessage].self, from: Self.fileName) ?? []
    }

    // MARK: Configuration

    /// The Ember Mail Worker. Nothing to configure and no secret in the app: each message has its own read key.
    static let defaultBaseURL = LocalConfig.workerBaseURL
    let baseURL: URL? = URL(string: defaultBaseURL)
    var isConfigured: Bool { baseURL != nil }

    /// A random read key (kept on this Mac) and the public pixel id derived from it.
    func newTrackingKeys() -> (readKey: String, id: String) {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let key = String((0..<32).map { _ in chars.randomElement()! })
        return (key, Self.pixelID(forKey: key))
    }

    static func pixelID(forKey key: String) -> String {
        Data(SHA256.hash(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    func pixelURL(for id: String) -> URL? {
        baseURL?.appendingPathComponent("p").appendingPathComponent("\(id).gif")
    }

    /// True if the URL string points at our own tracker (so we never count our own views).
    func isTrackerURL(_ string: String) -> Bool {
        guard let host = baseURL?.host else { return false }
        return string.contains(host)
    }

    /// Removes our own tracking pixel from HTML before rendering.
    func stripPixels(from html: String) -> String {
        guard let host = baseURL?.host else { return html }
        let escaped = NSRegularExpression.escapedPattern(for: host)
        return html.replacingOccurrences(of: "<img[^>]+\(escaped)[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: Records

    func add(_ item: TrackedMessage) {
        items.insert(item, at: 0)
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func record(for message: MessageSummary) -> TrackedMessage? {
        if let header = message.messageIDHeader, let hit = items.first(where: { $0.messageIDHeader == header }) {
            return hit
        }
        if let hit = items.first(where: { $0.providerID == message.remoteID && $0.accountID == message.accountID }) {
            return hit
        }
        // Fallback: same subject, sent within two minutes.
        return items.first {
            $0.accountID == message.accountID && $0.subject == message.subject && abs($0.sentAt.timeIntervalSince(message.date)) < 120
        }
    }

    private func save() {
        DiskStore.save(items, as: Self.fileName)
    }

    // MARK: Server

    private struct OpenDTO: Decodable {
        var t: Double          // epoch ms
        var ua: String?
        var city: String?
        var country: String?
        var org: String?
    }

    func testConnection() async -> String? {
        guard let base = baseURL else { return "Read receipts aren't available." }
        do {
            _ = try await HTTP.data(URLRequest(url: base.appendingPathComponent("api/health")))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Polls opens for messages sent in the last 60 days. Returns every newly detected open
    /// (including "may be automatic" ones: check `OpenEvent.automatic`).
    @discardableResult
    func refresh() async -> [(TrackedMessage, OpenEvent)] {
        guard let base = baseURL, !isRefreshing else { return [] }
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        // Only messages with a read key can be read back (older ones used the retired shared secret).
        let ids = items.filter { $0.sentAt > cutoff && $0.readKey != nil }.compactMap(\.readKey)
        guard !ids.isEmpty else { return [] }
        isRefreshing = true
        defer { isRefreshing = false }

        var newOpens: [(TrackedMessage, OpenEvent)] = []
        for chunkStart in stride(from: 0, to: ids.count, by: 80) {
            let chunk = ids[chunkStart..<min(ids.count, chunkStart + 80)]
            var components = URLComponents(url: base.appendingPathComponent("api/opens"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "keys", value: chunk.joined(separator: ","))]
            let req = URLRequest(url: components.url!)
            do {
                let result = try await HTTP.json([String: [OpenDTO]].self, req)
                for (key, opens) in result {
                    guard let index = items.firstIndex(where: { $0.readKey == key }) else { continue }
                    let sentAt = items[index].sentAt
                    let events = opens
                        .map { Self.classify($0) }
                        .filter { $0.at.timeIntervalSince(sentAt) > Self.graceSeconds }
                        .sorted { $0.at < $1.at }
                    let before = items[index].opens.count
                    if events.count > before {
                        for event in events.dropFirst(before) {
                            newOpens.append((items[index], event))
                        }
                    }
                    items[index].opens = events
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        lastRefresh = Date()
        save()
        return newOpens
    }

    private static func classify(_ dto: OpenDTO) -> OpenEvent {
        let ua = dto.ua ?? ""
        let org = dto.org ?? ""
        let client: String
        var automatic = false
        if ua.contains("GoogleImageProxy") {
            client = "Gmail"
        } else if ua.contains("YahooMailProxy") {
            client = "Yahoo Mail"
        } else if ua.contains("Outlook") || ua.contains("Microsoft") || org.contains("Microsoft") {
            client = "Outlook"
        } else if org.localizedCaseInsensitiveContains("Apple") {
            client = "Apple Mail"
            automatic = true // Mail Privacy Protection pre-fetches images
        } else if ua.contains("iPhone") || ua.contains("iPad") {
            client = "iPhone / iPad"
        } else if ua.contains("Macintosh") && !ua.contains("Chrome") && !ua.contains("Firefox") {
            client = "Mac Mail"
        } else if ua.contains("Android") {
            client = "Android"
        } else if ua.contains("Mozilla") {
            client = "Web browser"
        } else {
            client = "Email client"
        }
        let location = [dto.city, dto.country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        // Proxies (Gmail/Apple) hide location, so don't show their data-centre city.
        let showLocation = client != "Gmail" && !automatic && !location.isEmpty
        return OpenEvent(at: Date(timeIntervalSince1970: dto.t / 1000), client: client,
                         location: showLocation ? location : nil, automatic: automatic)
    }
}
