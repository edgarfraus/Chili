using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Chili.Core;

namespace Chili.Services;

public sealed class ViewerException(string message) : Exception(message);

/// <summary>Phase 1 SPICE console: the bundled remote-viewer.exe (virt-viewer) opens a .vv file.</summary>
public static class ViewerLauncher
{
    public static string LogDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chili", "Logs");

    /// <summary>The bundled viewer (viewer\bin next to Chili.exe), else an installed virt-viewer.</summary>
    public static string? FindViewer()
    {
        var candidates = new List<string> { Path.Combine(AppContext.BaseDirectory, "viewer", "bin", "remote-viewer.exe") };
        foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                     Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
        {
            if (root.Length == 0 || !Directory.Exists(root)) continue;
            candidates.AddRange(Directory.EnumerateDirectories(root, "VirtViewer*").OrderDescending()
                                         .Select(d => Path.Combine(d, "bin", "remote-viewer.exe")));
        }
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (dir.Length > 0) candidates.Add(Path.Combine(dir, "remote-viewer.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }

    /// <summary>Opens the connection described by <paramref name="config"/> through a private
    /// temporary .vv file, which remote-viewer deletes after reading.</summary>
    public static Task LaunchAsync(ViewerConfig config, string title, bool fullscreen)
    {
        var c = config.Clone();
        if (c["title"] is null) c["title"] = title;
        if (fullscreen) c["fullscreen"] = "1";
        c["delete-this-file"] = "1";
        var file = Path.Combine(Path.GetTempPath(), $"chili-{Guid.NewGuid():N}.vv");
        WritePrivate(file, c.VvText);
        return LaunchAsync([file]);
    }

    /// <summary>Starts remote-viewer with a .vv file or a spice:// URI. Completes when the viewer
    /// is up; if it dies within seconds it never connected, and the log tail is thrown.</summary>
    public static async Task LaunchAsync(IEnumerable<string> arguments)
    {
        var exe = FindViewer() ?? throw new ViewerException(L.T("remote-viewer was not found. Please reinstall Chili."));
        Directory.CreateDirectory(LogDirectory);
        var logPath = Path.Combine(LogDirectory, "remote-viewer.log");
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        if (App.Model.Settings.Preferences.ViewerDebugLog) { psi.ArgumentList.Add("--debug"); psi.ArgumentList.Add("--spice-debug"); }
        foreach (var a in arguments) psi.ArgumentList.Add(a);

        var log = new StreamWriter(logPath, append: false, Encoding.UTF8) { AutoFlush = true };
        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        void Write(object _, DataReceivedEventArgs e) { if (e.Data is { } line) lock (log) log.WriteLine(line); }
        process.OutputDataReceived += Write;
        process.ErrorDataReceived += Write;
        process.Exited += (_, _) => { lock (log) log.Dispose(); };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        var exited = process.WaitForExitAsync();
        if (await Task.WhenAny(exited, Task.Delay(TimeSpan.FromSeconds(8))) == exited && process.ExitCode != 0)
        {
            await Task.Delay(200);
            string tail = "";
            try
            {
                using var reader = new StreamReader(new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
                tail = string.Join("\n", reader.ReadToEnd().Split('\n')
                    .Where(l => l.Trim().Length > 0 && !l.Contains("Gtk-WARNING") && !l.Contains("GdkPixbuf-WARNING")).TakeLast(8));
            }
            catch (IOException) { }
            var head = L.F("The viewer quit unexpectedly (exit code %d).", process.ExitCode);
            throw new ViewerException(tail.Length == 0 ? head : head + "\n\n" + tail);
        }
    }

    /// <summary>Creates a file only the current user can read: it can hold a one-time password.</summary>
    private static void WritePrivate(string path, string text)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var me = WindowsIdentity.GetCurrent().User!;
        security.AddAccessRule(new FileSystemAccessRule(me, FileSystemRights.FullControl, AccessControlType.Allow));
        using var stream = new FileInfo(path).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None,
                                                     4096, FileOptions.None, security);
        var bytes = Encoding.UTF8.GetBytes(text);
        stream.Write(bytes);
    }
}
