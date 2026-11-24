import AppKit
import CryptoKit
import SwiftUI

/// A macOS release on GitHub that is newer than the running app.
struct ReleaseInfo: Equatable {
    let version: [Int]
    let tag: String
    let pageURL: URL?
    let dmgURL: URL
    let sha256URL: URL?

    var versionString: String { Updates.format(version) }
}

/// Update checks against the project's GitHub releases. Releases are tagged `v<version>` (since 1.1.0
/// they also carry the Windows setup; the old Windows-only `windows-v<version>` ones are ignored here) and
/// carry `Chili-<version>-<arch>.dmg` plus a `.dmg.sha256` file; releases without a DMG for this Mac are skipped. Drafts and pre-releases are ignored. Same behaviour as the Windows app.
enum Updates {
    static let repository = "edgarfraus/Chili"

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// "v1.2.3" → [1, 2, 3]; anything else ("windows-v1.0.1", "v1.2-beta") → nil.
    static func parseTag(_ tag: String?) -> [Int]? {
        guard let tag, tag.hasPrefix("v") else { return nil }
        return parseVersion(String(tag.dropFirst()))
    }

    /// "1.2.3" → [1, 2, 3]; only digits and dots.
    static func parseVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Compares versions with missing parts as 0 (1.2 == 1.2.0).
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// At least three parts: [1, 2] → "1.2.0".
    static func format(_ v: [Int]) -> String {
        (v + Array(repeating: 0, count: max(0, 3 - v.count))).map(String.init).joined(separator: ".")
    }

    /// The newest macOS release in a GitHub /releases response that is newer than `current` and has a
    /// DMG for `arch`.
    static func newest(in releases: [[String: Any]], current: [Int], arch: String) -> ReleaseInfo? {
        var best: ReleaseInfo?
        for r in releases {
            if r["draft"] as? Bool == true || r["prerelease"] as? Bool == true { continue }
            let tag = r["tag_name"] as? String
            guard let version = parseTag(tag), isNewer(version, than: current) else { continue }
            if let best, !isNewer(version, than: best.version) { continue }
            var dmg: URL?, sha: URL?
            for a in r["assets"] as? [[String: Any]] ?? [] {
                let name = a["name"] as? String ?? ""
                let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:))
                if name.hasSuffix("-\(arch).dmg") { dmg = url }
                else if name.hasSuffix("-\(arch).dmg.sha256") { sha = url }
            }
            guard let dmg else { continue }
            best = ReleaseInfo(version: version, tag: tag!, pageURL: (r["html_url"] as? String).flatMap(URL.init(string:)),
                               dmgURL: dmg, sha256URL: sha)
        }
        return best
    }

    /// "<hex>  file.dmg" (sha256sum format) → the hex digest.
    static func parseSha256(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).first.map(String.init) ?? ""
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum UpdateError: LocalizedError {
    case checksumMismatch
    case install(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch:
            return NSLocalizedString("The downloaded update is damaged (checksum mismatch). Try again later.", comment: "")
        case .install(let detail): return detail
        }
    }
}

/// Checks GitHub for a newer macOS release at launch and every 12 hours, and installs it: downloads the
/// DMG, verifies its SHA-256, copies Chili.app next to the running bundle, and a small helper swaps the
/// two once Chili has quit, then opens the new one.
@MainActor
final class Updater: NSObject, ObservableObject {
    enum Phase: Equatable {
        case available
        case downloading(Double)
        case installing
        case done(String)       // dev build: downloaded and verified, not installed
        case failed(String)
    }

    @Published private(set) var pending: ReleaseInfo?
    @Published private(set) var phase = Phase.available
    @Published var dismissed = false

    private static let interval: TimeInterval = 12 * 3600
    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?

    /// The running version. CHILI_DEBUG_UPDATE_CURRENT pretends another one, to test against real releases.
    static let current: [Int] = {
        if let fake = ProcessInfo.processInfo.environment["CHILI_DEBUG_UPDATE_CURRENT"], let v = Updates.parseVersion(fake) {
            return v
        }
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return Updates.parseVersion(s) ?? [0]
    }()

    static var isDebug: Bool { ProcessInfo.processInfo.environment["CHILI_DEBUG_UPDATE_CURRENT"] != nil }

    /// Running from an app bundle (not the bare launcher executable of a dev build): it can be replaced.
    static var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = [
            // GitHub's API requires a User-Agent.
            "User-Agent": "Chili/\(Updates.format(Self.current)) (+https://github.com/\(Updates.repository))",
            "Accept": "application/vnd.github+json",
        ]
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    func start() {
        guard !Demo.isOn else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        // First check a little after launch, so it doesn't compete with logging in.
        let delay: UInt64 = Self.isDebug ? 1 : 15
        Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            await check()
        }
    }

    func check() async {
        guard UserDefaults.standard.bool(forKey: Prefs.checkForUpdates) else { return }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Updates.repository)/releases?per_page=30")!
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.install("HTTP \(http.statusCode)")
            }
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            let release = Updates.newest(in: list, current: Self.current, arch: Updates.arch)
            log("update check: current \(Updates.format(Self.current)), latest \(release?.tag ?? "none newer")")
            guard let release, release != pending else { return }
            pending = release
            phase = .available
            dismissed = false
        } catch {
            log("update check failed: \(error.localizedDescription)")   // offline, rate-limited…: try again later
        }
    }

    func openReleaseNotes() {
        if let url = pending?.pageURL { NSWorkspace.shared.open(url) }
    }

    /// Asks first when consoles are open, then downloads, verifies and installs, and quits Chili.
    func updateNow(model: AppModel, confirm: Bool = true) {
        guard let release = pending else { return }
        if confirm && (!model.consoles.isEmpty || ViewerLauncher.shared.hasRunningViewers) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Update Chili now?", comment: "")
            alert.informativeText = NSLocalizedString(
                "Chili closes while the update installs, and reopens afterwards. Open consoles are disconnected.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Update Now", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        phase = .downloading(0)
        Task {
            do {
                let dmg = try await download(release)
                guard Self.canInstall else {
                    // Development build: never replace it.
                    phase = .done(String(format: NSLocalizedString("Downloaded and verified: %@", comment: ""), dmg.path))
                    return
                }
                phase = .installing
                try await install(dmg: dmg, model: model)
            } catch {
                log("update failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Download

    private var updatesDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Chili").appendingPathComponent("Updates")
    }

    /// Downloads the DMG and checks it against the release's .sha256 file. Returns its path.
    private func download(_ release: ReleaseInfo) async throws -> URL {
        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let dest = updatesDir.appendingPathComponent(release.dmgURL.lastPathComponent)
        let temp: URL = try await withCheckedThrowingContinuation { cont in
            let task = session.downloadTask(with: release.dmgURL) { url, response, error in
                if let error { return cont.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    return cont.resume(throwing: UpdateError.install("HTTP \(http.statusCode)"))
                }
                guard let url else { return cont.resume(throwing: URLError(.badServerResponse)) }
                // The file is removed when this handler returns: move it now.
                let keep = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".dmg")
                do { try FileManager.default.moveItem(at: url, to: keep); cont.resume(returning: keep) }
                catch { cont.resume(throwing: error) }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(f) } }
            }
            task.resume()
        }
        progressObservation = nil
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        if let shaURL = release.sha256URL {
            let (data, _) = try await session.data(from: shaURL)
            let expected = Updates.parseSha256(String(decoding: data, as: UTF8.self)).lowercased()
            let actual = try Updates.sha256(of: dest)
            if expected != actual {
                try? FileManager.default.removeItem(at: dest)
                throw UpdateError.checksumMismatch
            }
        }
        log("update downloaded and verified: \(dest.path)")
        return dest
    }

    // MARK: Install

    /// Copies Chili.app out of the DMG next to the running bundle, starts the helper that swaps the
    /// bundles once Chili has quit and opens the new one, then quits.
    private func install(dmg: URL, model: AppModel) async throws {
        let current = Bundle.main.bundleURL
        let folder = current.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: current.path) else {
            // E.g. /Applications owned by root, or a translocated copy: let the user drag it over.
            NSWorkspace.shared.open(dmg)
            throw UpdateError.install(NSLocalizedString(
                "Chili can't replace itself in this folder. Drag Chili from the disk image that just opened to your Applications folder.",
                comment: ""))
        }
        let staged = folder.appendingPathComponent(".Chili-\(pending?.versionString ?? "update").app")
        try await Task.detached {
            let mount = fm.temporaryDirectory.appendingPathComponent("chili-update-\(UUID().uuidString)")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: mount) }
            try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            let app = mount.appendingPathComponent("Chili.app")
            guard fm.fileExists(atPath: app.path) else { throw UpdateError.install("Chili.app not found in \(dmg.lastPathComponent)") }
            try? fm.removeItem(at: staged)
            try Self.run("/usr/bin/ditto", [app.path, staged.path])
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        }.value
        try? fm.removeItem(at: dmg)

        // The helper outlives Chili: wait for it to exit, swap, clear quarantine, open the new one.
        let script = """
        pid="$1"; old="$2"; new="$3"; aside="$old.old-$$"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$old" "$aside" && mv "$new" "$old"; then
            rm -rf "$aside"
        else
            [ -d "$old" ] || mv "$aside" "$old"
        fi
        xattr -dr com.apple.quarantine "$old" 2>/dev/null
        open "$old"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "chili-update", String(ProcessInfo.processInfo.processIdentifier),
                            current.path, staged.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        log("update: installing \(staged.lastPathComponent) over \(current.path), quitting")
        for c in model.consoles { model.close(c) }
        model.disconnectAll()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError.install("\((tool as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private func log(_ s: String) {
        if ProcessInfo.processInfo.environment["CHILI_DEBUG_ACTION"] != nil || Self.isDebug { DebugActions.log(s) }
    }
}

/// The banner at the top of the main window when a newer Chili is available.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let release = updater.pending, !updater.dismissed {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("Chili %@ is available", comment: ""), release.versionString))
                        .font(.headline)
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundColor(isFailure ? .red : .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if case .downloading(let p) = updater.phase {
                    ProgressView(value: p).frame(width: 140)
                } else if updater.phase == .installing {
                    ProgressView().controlSize(.small)
                }
                Button("What's New") { updater.openReleaseNotes() }
                    .buttonStyle(.link)
                Button("Update Now") { updater.updateNow(model: model) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                Button { updater.dismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .disabled(isBusy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35)))
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private var isFailure: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var message: String {
        switch updater.phase {
        case .available:
            return String(format: NSLocalizedString("You have version %@.", comment: ""), Updates.format(Updater.current))
        case .downloading: return NSLocalizedString("Downloading the update…", comment: "")
        case .installing: return NSLocalizedString("Installing…", comment: "")
        case .done(let s), .failed(let s): return s
        }
    }
}
