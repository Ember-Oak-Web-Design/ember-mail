import AppKit
import CryptoKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer version and (if the user agrees) downloads and swaps the app in place.
/// Nothing is installed without a click, and "Skip this version" is remembered.
@MainActor
@Observable
final class UpdateStore {
    enum State: Equatable {
        case idle
        case checking
        case available(ReleaseInfo)
        case installing(ReleaseInfo, String)   // status text
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Hidden for this session only ("Later").
    private(set) var dismissed = false

    private static let skippedKey = "skippedUpdateVersion"
    private static let autoCheckKey = "autoCheckUpdates"

    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") ?? AppVersion("0")!
    }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// The release to show in the update bar (nil if none, skipped, or dismissed).
    var pending: ReleaseInfo? {
        switch state {
        case .available(let r):
            return dismissed || UserDefaults.standard.string(forKey: Self.skippedKey) == r.version.description ? nil : r
        case .installing(let r, _): return r
        default: return nil
        }
    }

    // MARK: Checking

    /// Checks on launch and every 6 hours while running.
    func startAutomaticChecks() {
        Task {
            while !Task.isCancelled {
                if autoCheck { await check(manual: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Returns a short message for manual checks ("You're up to date…"), nil otherwise.
    @discardableResult
    func check(manual: Bool) async -> String? {
        if case .installing = state { return nil }
        if manual { state = .checking; dismissed = false; UserDefaults.standard.removeObject(forKey: Self.skippedKey) }
        var request = URLRequest(url: UpdateConfig.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EmberMail/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if manual { state = .failed("Couldn't check for updates (\(code)).") }
                else { state = .idle }
                return manual ? "Couldn't check for updates." : nil
            }
            guard let release = UpdateLogic.parseRelease(data) else { state = .idle; return manual ? "You're up to date." : nil }
            if release.version > Self.currentVersion {
                state = .available(release)
                return nil
            }
            state = .idle
            return manual ? "You're up to date (version \(Self.currentVersion))." : nil
        } catch {
            state = manual ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
            return manual ? "Couldn't check for updates." : nil
        }
    }

    func dismissForNow() { dismissed = true }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
        state = .idle
    }

    // MARK: Installing

    func install(_ release: ReleaseInfo) async {
        do {
            state = .installing(release, "Downloading…")
            let (zipFile, _) = try await URLSession.shared.download(from: release.zipURL)

            if let sumURL = release.checksumURL {
                state = .installing(release, "Verifying…")
                let (sumData, _) = try await URLSession.shared.data(from: sumURL)
                guard let expected = UpdateLogic.parseChecksum(String(decoding: sumData, as: UTF8.self)) else {
                    throw UpdateError("The update's checksum file is invalid.")
                }
                let actual = try Self.sha256(of: zipFile)
                guard actual == expected else { throw UpdateError("The download didn't match its checksum, so it was not installed.") }
            }

            state = .installing(release, "Installing…")
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("EmberMailUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let extracted = work.appendingPathComponent("extracted")
            try Self.run("/usr/bin/ditto", ["-xk", zipFile.path, extracted.path])
            let newApp = extracted.appendingPathComponent("Ember Mail.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == UpdateConfig.bundleID,
                  AppVersion(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") == release.version else {
                throw UpdateError("The downloaded app wasn't what we expected, so it was not installed.")
            }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError("Ember Mail can't replace itself in this folder. Move it to Applications and try again.")
            }
            try Self.launchSwapper(newApp: newApp, target: target, work: work)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            dismissed = false
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the update (\(URL(fileURLWithPath: tool).lastPathComponent) failed).") }
    }

    /// A detached shell script waits for this process to quit, swaps the bundle (keeping a backup until it
    /// succeeds) and relaunches. Downloaded via URLSession, so the new app carries no quarantine flag.
    private static func launchSwapper(newApp: URL, target: URL, work: URL) throws {
        let script = """
        #!/bin/bash
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW="\(newApp.path)"
        TARGET="\(target.path)"
        for i in $(seq 1 100); do kill -0 $PID 2>/dev/null || break; sleep 0.3; done
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && mv "$NEW" "$TARGET"; then
          rm -rf "$TARGET.old"
        else
          rm -rf "$TARGET"; mv "$TARGET.old" "$TARGET"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        /usr/bin/open "$TARGET"
        rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", scriptURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
    }
}
