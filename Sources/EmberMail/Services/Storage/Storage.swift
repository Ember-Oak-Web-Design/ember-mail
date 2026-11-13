import Foundation
import Security

/// All secrets live in ONE Keychain item (a small JSON "vault"), read once per launch and cached in memory.
///
/// The item is created and read through Apple's own `/usr/bin/security` tool, not through this app's own
/// Keychain access. macOS pins app-owned Keychain items to the app's exact binary hash ("partition"),
/// which changes on every rebuild and brought back the password prompt after each update. Items made by
/// the Apple tool are trusted to that tool instead, which never changes, so there are no prompts at all
/// after the one-time migration.
enum Keychain {
    /// Overridable only so tests can use a separate service name.
    nonisolated(unsafe) static var service = "com.emberoak.EmberMail"
    /// Vault stored via the `security` tool.
    private static let vaultAccount = "vault-v3"
    /// Previous vault, created by this app directly (migrated once, then deleted).
    private static let directVaultAccount = "vault-v1"

    nonisolated(unsafe) private static var cache: [String: String]?
    /// True when the vault exists but couldn't be read (e.g. access denied). Never overwrite it then.
    nonisolated(unsafe) private static var readFailed = false
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return vault()[key]
    }

    static func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = writableVault()
        guard dict[key] != value else { return }
        dict[key] = value
        cache = dict
        if !readFailed { persist(dict) }
    }

    /// Drops the in-memory copy (tests only).
    static func resetCacheForTesting() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        readFailed = false
    }

    static func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = writableVault()
        guard dict[key] != nil else { return }
        dict[key] = nil
        cache = dict
        if !readFailed { persist(dict) }
    }

    // MARK: Vault (call with lock held)

    /// Before writing, retry a failed read once so we never replace real secrets with an empty vault.
    private static func writableVault() -> [String: String] {
        if readFailed {
            let pending = cache ?? [:]
            cache = nil
            let fresh = vault()
            if readFailed { return pending }
            return fresh.merging(pending) { _, new in new }
        }
        return vault()
    }

    private static func vault() -> [String: String] {
        if let cache { return cache }
        readFailed = false
        var dict: [String: String] = [:]
        switch cliRead(vaultAccount) {
        case .found(let data):
            dict = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        case .failed:
            readFailed = true
        case .missing:
            dict = migrate()
        }
        cache = dict
        return dict
    }

    /// One-time: bring secrets from older layouts into the new vault. This is the only step that can
    /// ask for the Mac password (to read the old items); after it, nothing ever does.
    private static func migrate() -> [String: String] {
        var dict: [String: String] = [:]
        let (data, status) = readItem(directVaultAccount)
        if let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        } else if status == errSecItemNotFound {
            dict = migrateLegacyItems()
        } else {
            // Denied or cancelled: keep the old item and try again next launch.
            readFailed = true
            return [:]
        }
        guard !dict.isEmpty else { return dict }
        if persist(dict) {
            deleteItem(directVaultAccount)
        }
        return dict
    }

    @discardableResult
    private static func persist(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        return cliWrite(vaultAccount, data)
    }

    // MARK: `security` tool

    private enum CLIResult { case found(Data), missing, failed }

    private static func cliRead(_ account: String) -> CLIResult {
        let (status, out) = runSecurity(["find-generic-password", "-a", account, "-s", service, "-w"])
        guard status == 0 else { return status == 44 ? .missing : .failed } // 44 = item not found
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: text) else { return .failed }
        return .found(data)
    }

    /// Writes via `security -i` so the secret goes over stdin (never visible in the process list).
    private static func cliWrite(_ account: String, _ data: Data) -> Bool {
        let command = "add-generic-password -a \(account) -s \(service) -U -w \(data.base64EncodedString())\n"
        _ = runSecurity(["-i"], stdin: command)
        // Interactive mode doesn't report failures in its exit status, so verify by reading back.
        if case .found(let stored) = cliRead(account) { return stored == data }
        return false
    }

    private static func runSecurity(_ arguments: [String], stdin: String? = nil) -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        do { try process.run() } catch { return (-1, Data()) }
        // Safety net: never hang the app if the system shows a dialog nobody answers.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    // MARK: Direct access (migration only)

    private static func readItem(_ account: String) -> (Data?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    private static func deleteItem(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private static func migrateLegacyItems() -> [String: String] {
        // Listing attributes doesn't need permission; reading each value may prompt once (last time).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var dict: [String: String] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != directVaultAccount, account != vaultAccount else { continue }
            if let data = readItem(account).0, let value = String(data: data, encoding: .utf8) {
                dict[account] = value
                deleteItem(account)
            }
        }
        return dict
    }

    // Well-known keys
    static func imapPasswordKey(_ id: UUID) -> String { "imap-password-\(id.uuidString)" }
    static func googleTokensKey(_ id: UUID) -> String { "google-tokens-\(id.uuidString)" }
    static let googleClientSecretKey = "google-client-secret"
    static let trackingSecretKey = "tracking-secret"
}

/// JSON files under ~/Library/Application Support/EmberMail.
enum DiskStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EmberMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    static func removeAll(withPrefix prefix: String) {
        let safePrefix = url(prefix).lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasPrefix(safePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
