import SwiftUI

/// Readable names for Proxmox task types.
enum TaskNames {
    static func label(_ type: String) -> String {
        let names: [String: String] = [
            "qmstart": "Start", "vzstart": "Start",
            "qmstop": "Stop", "vzstop": "Stop",
            "qmshutdown": "Shut down", "vzshutdown": "Shut down",
            "qmreboot": "Reboot", "vzreboot": "Reboot",
            "qmreset": "Reset", "qmsuspend": "Suspend", "qmresume": "Resume",
            "vzsuspend": "Suspend", "vzresume": "Resume",
            "qmcreate": "Create", "vzcreate": "Create",
            "qmdestroy": "Delete", "vzdestroy": "Delete",
            "qmclone": "Clone", "vzclone": "Clone",
            "qmigrate": "Migrate", "vzmigrate": "Migrate",
            "vzdump": "Backup", "qmrestore": "Restore", "vzrestore": "Restore",
            "qmsnapshot": "Snapshot", "vzsnapshot": "Snapshot",
            "qmdelsnapshot": "Delete snapshot", "vzdelsnapshot": "Delete snapshot",
            "qmrollback": "Rollback", "vzrollback": "Rollback",
            "qmmove": "Move disk", "move_volume": "Move volume",
            "qmresize": "Resize disk", "resize": "Resize disk",
            "qmtemplate": "Convert to template", "vztemplate": "Convert to template",
            "qmconfig": "Change configuration", "vzconfig": "Change configuration",
            "vncproxy": "Console (noVNC)", "vncshell": "Shell", "termproxy": "Console (xterm.js)",
            "spiceproxy": "Console (SPICE)", "spiceshell": "Shell (SPICE)",
            "imgcopy": "Copy image", "download": "Download",
        ]
        return NSLocalizedString(names[type] ?? type, comment: "Proxmox task type")
    }
}

/// History of a VM's or container's Proxmox tasks, with the log of the selected one.
struct VMLogsView: View {
    let session: ServerSession
    let vm: ProxmoxVM
    /// Previews: show these instead of asking the server.
    var preview: (tasks: [ProxmoxClient.TaskEntry], log: [String])?
    @Environment(\.presentationMode) private var presentation
    @State private var tasks: [ProxmoxClient.TaskEntry] = []
    @State private var selection: String?
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var loading = true

    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History & Logs").font(.title2.bold())
                    Text(verbatim: "\(vm.displayName) (\(vm.vmid)) · \(vm.node)").foregroundColor(.secondary)
                }
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button("Close") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                taskList.frame(width: 330)
                Divider()
                logPane
            }
        }
        .frame(width: 980, height: 620)
        .task { await reload() }
        .onReceive(timer) { _ in
            // Keep following tasks that are still running.
            if tasks.contains(where: \.isRunning) { Task { await reload() } }
        }
    }

    private var taskList: some View {
        Group {
            if loading && tasks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tasks.isEmpty {
                Text(error ?? NSLocalizedString("No tasks recorded for this machine yet.", comment: ""))
                    .foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tasks, selection: $selection) { task in
                    TaskRow(task: task).tag(task.upid)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: selection) { _ in Task { await loadLog() } }
            }
        }
    }

    private var logPane: some View {
        Group {
            if selection == nil {
                Text("Select a task to see its log.").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogText(lines: lines)
            }
        }
    }

    private func reload() async {
        if let preview {
            tasks = preview.tasks
            selection = selection ?? tasks.first?.upid
            lines = preview.log
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            tasks = try await session.api.tasks(for: vm)
            error = nil
            if selection == nil { selection = tasks.first?.upid }
            await loadLog()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLog() async {
        if let preview { lines = preview.log; return }
        guard let upid = selection, let task = tasks.first(where: { $0.upid == upid }) else { return }
        lines = (try? await session.api.taskLog(node: task.node, upid: upid)) ?? []
    }
}

private struct TaskRow: View {
    let task: ProxmoxClient.TaskEntry

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: TaskNames.label(task.type)).fontWeight(.medium)
                Text(verbatim: subtitle).font(.caption).foregroundColor(.secondary)
                if let status = task.status, !task.succeeded {
                    Text(verbatim: status).font(.caption).foregroundColor(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        if task.isRunning {
            ProgressView().controlSize(.small)
        } else if task.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }

    private var subtitle: String {
        let date = DateFormatter.localizedString(from: task.startDate, dateStyle: .short, timeStyle: .medium)
        var parts = [date]
        if let d = task.duration, d >= 1 {
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated
            f.allowedUnits = d >= 3600 ? [.hour, .minute] : d >= 60 ? [.minute, .second] : [.second]
            if let s = f.string(from: d) { parts.append(s) }
        }
        if let user = task.user { parts.append(user) }
        return parts.joined(separator: " · ")
    }
}

/// Monospaced, selectable log text that scrolls to the end.
struct LogText: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            // Vertical only: a two-axis ScrollView centres content smaller than the view.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onChange(of: lines.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") { return .red }
        if l.contains("warning") || l.contains("warn") { return .orange }
        return .primary
    }
}

/// A node's system journal, with a filter.
struct NodeLogView: View {
    let session: ServerSession
    let node: String
    var preview: [String]?
    @Environment(\.presentationMode) private var presentation
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var error: String?
    @State private var follow = true

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var shown: [String] {
        filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Log").font(.title2.bold())
                    Text(verbatim: node).foregroundColor(.secondary)
                }
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle("Follow", isOn: $follow)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button("Close") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error {
                Text(verbatim: error).foregroundColor(.red).padding()
            }
            LogText(lines: shown)
        }
        .frame(width: 980, height: 640)
        .task { await reload() }
        .onReceive(timer) { _ in if follow { Task { await reload() } } }
    }

    private func reload() async {
        if let preview { lines = preview; return }
        do {
            lines = try await session.api.syslog(node: node)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
