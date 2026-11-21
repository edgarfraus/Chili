import AppKit
import Foundation

/// Connection settings understood by remote-viewer, serialized as a
/// virt-viewer ".vv" file (an INI file with a single [virt-viewer] group).
struct ViewerConfig {
    var entries: [(String, String)] = [("type", "spice")]

    subscript(key: String) -> String? {
        get { entries.first { $0.0 == key }?.1 }
        set {
            entries.removeAll { $0.0 == key }
            if let newValue { entries.append((key, newValue)) }
        }
    }

    /// Parses the body of a .vv file (as returned by Proxmox' spiceconfig API).
    init(vvText: String) {
        entries = []
        for raw in vvText.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("["), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            self[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
    }

    init() {}

    var vvText: String {
        "[virt-viewer]\n" + entries.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    /// Applies the user's viewer preferences on top of what the server sent.
    mutating func applyPreferences() {
        let d = UserDefaults.standard
        if d.bool(forKey: Prefs.fullscreen) { self["fullscreen"] = "1" }
    }
}

enum Prefs {
    static let fullscreen = "openFullscreen"
    static let quitAfterLaunch = "quitAfterOpeningFile"
    static let debugLog = "viewerDebugLog"

    static let resizeGuest = "resizeGuestToWindow"
    static let retinaResolution = "retinaResolution"
    static let shareClipboard = "shareClipboard"
    static let consolePlacement = "consolePlacement"     // "main" or "window"
    static let useClassicViewer = "useClassicViewer"     // remote-viewer instead of the built-in console

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            resizeGuest: true,
            retinaResolution: false,
            shareClipboard: true,
            consolePlacement: "main",
            useClassicViewer: false,
            fullscreen: false,
            quitAfterLaunch: true,
            debugLog: false,
        ])
    }
}

enum ViewerError: LocalizedError {
    case missingViewer(String)
    case invalidFile(String)
    case exitedEarly(Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingViewer(let path):
            return String(format: NSLocalizedString("The bundled viewer is missing (%@). Please reinstall the app.", comment: ""), path)
        case .invalidFile(let name):
            return String(format: NSLocalizedString("“%@” is not a valid SPICE connection file.", comment: ""), name)
        case .exitedEarly(let code, let log):
            let head = String(format: NSLocalizedString("The viewer quit unexpectedly (exit code %d).", comment: ""), code)
            return log.isEmpty ? head : head + "\n\n" + log
        }
    }
}

/// Starts the bundled remote-viewer with an environment that makes the
/// relocated GTK/GStreamer stack find its data files inside the app bundle.
final class ViewerLauncher {
    static let shared = ViewerLauncher()

    private var running: [Process] = []
    private let fm = FileManager.default

    // The whole GTK/GStreamer runtime lives inside the helper bundle: GTK's
    // quartz backend resolves its data relative to the running bundle's Resources.
    private var viewerApp: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Chili Viewer.app") }
    private var viewerExecutable: URL { viewerApp.appendingPathComponent("Contents/MacOS/remote-viewer") }
    private var resources: URL { viewerApp.appendingPathComponent("Contents/Resources") }
    // Loadable modules (GStreamer, gdk-pixbuf) live in Resources/lib like in GIMP/Inkscape:
    // codesign only accepts bundles in PlugIns/ and subfolders of Frameworks/.
    private var plugins: URL { resources.appendingPathComponent("lib") }

    lazy var cacheDir: URL = {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Chili", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    lazy var logDir: URL = {
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/Chili", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var hasRunningViewers: Bool { running.contains { $0.isRunning } }

    /// GStreamer locations for the built-in console's audio and video decoding.
    var runtimePaths: (gstPlugins: String, gstScanner: String, gstRegistry: String) {
        (plugins.appendingPathComponent("gstreamer-1.0").path,
         viewerApp.appendingPathComponent("Contents/MacOS/gst-plugin-scanner").path,
         cacheDir.appendingPathComponent("gst-registry-console-\(Self.arch).bin").path)
    }

    /// Opens a connection described by `config` (written to a private temp file).
    func launch(config: ViewerConfig, title: String? = nil) throws {
        var config = config
        config.applyPreferences()
        if let title, config["title"] == nil { config["title"] = title }
        config["delete-this-file"] = "1"

        let file = fm.temporaryDirectory.appendingPathComponent("spice-\(UUID().uuidString).vv")
        // The file can contain a one-time password: create it readable by the user only.
        fm.createFile(atPath: file.path, contents: Data(config.vvText.utf8), attributes: [.posixPermissions: 0o600])
        try launch(arguments: [file.path])
    }

    /// Opens a .vv file or a spice:// URI as given.
    func launch(arguments: [String]) throws {
        guard fm.isExecutableFile(atPath: viewerExecutable.path) else {
            throw ViewerError.missingViewer(viewerExecutable.path)
        }
        let process = Process()
        process.executableURL = viewerExecutable
        var args = arguments
        if UserDefaults.standard.bool(forKey: Prefs.debugLog) { args.insert(contentsOf: ["--debug", "--spice-debug"], at: 0) }
        process.arguments = args
        process.environment = environment()

        let logURL = logDir.appendingPathComponent("remote-viewer.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log

        let started = Date()
        process.terminationHandler = { [weak self] p in
            try? log.close()
            DispatchQueue.main.async {
                self?.running.removeAll { $0 === p }
                // A viewer that dies within seconds never connected: tell the user why.
                if p.terminationReason == .exit, p.terminationStatus != 0, Date().timeIntervalSince(started) < 10 {
                    let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map(Self.relevantLog) ?? ""
                    NotificationCenter.default.post(name: .viewerFailed, object: ViewerError.exitedEarly(p.terminationStatus, tail))
                }
                NotificationCenter.default.post(name: .viewerExited, object: nil)
            }
        }
        try process.run()
        running.append(process)
    }

    private static func relevantLog(_ text: String) -> String {
        let lines = text.split(separator: "\n").filter { !$0.contains("Gtk-WARNING") && !$0.contains("GdkPixbuf-WARNING") }
        return lines.suffix(8).joined(separator: "\n")
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let share = resources.appendingPathComponent("share").path

        env["XDG_DATA_DIRS"] = share
        env["XDG_CACHE_HOME"] = cacheDir.path
        env["GSETTINGS_SCHEMA_DIR"] = share + "/glib-2.0/schemas"
        env["GSETTINGS_BACKEND"] = "memory"
        env["GIO_MODULE_DIR"] = cacheDir.appendingPathComponent("no-gio-modules").path
        env["GTK_DATA_PREFIX"] = resources.path
        env["GTK_EXE_PREFIX"] = resources.path
        env["GTK_PATH"] = resources.path
        env["GTK_IM_MODULE_FILE"] = "/dev/null"
        env["GDK_PIXBUF_MODULE_FILE"] = pixbufLoaderCache()
        env["FONTCONFIG_FILE"] = resources.appendingPathComponent("etc/fonts/fonts.conf").path
        env["SPICE_CLIENT_LOCALEDIR"] = share + "/locale"

        let gst = plugins.appendingPathComponent("gstreamer-1.0").path
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gst
        env["GST_PLUGIN_PATH_1_0"] = gst
        env["GST_PLUGIN_SCANNER_1_0"] = viewerApp.appendingPathComponent("Contents/MacOS/gst-plugin-scanner").path
        env["GST_REGISTRY_1_0"] = cacheDir.appendingPathComponent("gst-registry-\(Self.arch).bin").path
        env["GST_REGISTRY_FORK"] = "no"

        // Apps started from Finder get no LANG; gettext needs it to pick a translation.
        if env["LANG"] == nil, let lang = Locale.preferredLanguages.first {
            let code = lang.replacingOccurrences(of: "-", with: "_")
            env["LANG"] = (code.contains("_") ? code : "\(code)_\(code.uppercased())") + ".UTF-8"
        }
        // Follow the system appearance (GTK on macOS doesn't do it by itself).
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            env["GTK_THEME"] = "Adwaita:dark"
        }
        return env
    }

    /// gdk-pixbuf needs absolute paths to its loader modules; the bundle can live
    /// anywhere, so we render the template shipped in the bundle on every launch.
    private func pixbufLoaderCache() -> String {
        let template = resources.appendingPathComponent("lib/gdk-pixbuf-2.0/loaders.cache.in")
        let out = cacheDir.appendingPathComponent("loaders.cache")
        if let text = try? String(contentsOf: template, encoding: .utf8) {
            let rendered = text.replacingOccurrences(of: "@PLUGINS@", with: plugins.path)
            try? rendered.write(to: out, atomically: true, encoding: .utf8)
        }
        return out.path
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

extension Notification.Name {
    static let viewerFailed = Notification.Name("ViewerFailed")
    static let viewerExited = Notification.Name("ViewerExited")
}
