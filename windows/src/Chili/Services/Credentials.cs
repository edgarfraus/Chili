using System.Runtime.InteropServices;
using System.Text;

namespace Chili.Services;

/// <summary>Passwords and token secrets in Windows Credential Manager (generic credentials,
/// target "Chili/&lt;server id&gt;"). Read once per launch; written only when they change.</summary>
public static class Credentials
{
    private static readonly Dictionary<string, string?> Cache = [];

    /// <summary>The server's password or token secret: "Chili/<id>"; other secrets (e.g. the Cloudflare
    /// Access service token): "Chili/<id>/<purpose>".</summary>
    private static string Target(Guid id, string? purpose) => purpose is null ? $"Chili/{id}" : $"Chili/{id}/{purpose}";

    public static string? Load(Guid id, string? purpose = null)
    {
        if (Demo.IsOn) return null;
        var target = Target(id, purpose);
        if (Cache.TryGetValue(target, out var cached)) return cached;
        string? value = null;
        if (CredReadW(target, CRED_TYPE_GENERIC, 0, out var ptr))
        {
            try
            {
                var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
                if (cred.CredentialBlobSize > 0)
                    value = Marshal.PtrToStringUni(cred.CredentialBlob, (int)cred.CredentialBlobSize / 2);
            }
            finally { CredFree(ptr); }
        }
        Cache[target] = value;
        return value;
    }

    public static void Save(Guid id, string secret, string? purpose = null)
    {
        if (Demo.IsOn || Load(id, purpose) == secret) return;
        var blob = Encoding.Unicode.GetBytes(secret);
        var handle = GCHandle.Alloc(blob, GCHandleType.Pinned);
        try
        {
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Target(id, purpose),
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = handle.AddrOfPinnedObject(),
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = Environment.UserName,
                Comment = "Chili – Proxmox server",
            };
            if (CredWriteW(ref cred, 0)) Cache[Target(id, purpose)] = secret;
        }
        finally { handle.Free(); }
    }

    public static void Delete(Guid id, string? purpose = null)
    {
        if (Demo.IsOn) return;
        CredDeleteW(Target(id, purpose), CRED_TYPE_GENERIC, 0);
        Cache[Target(id, purpose)] = null;
    }

    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
