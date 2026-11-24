namespace Chili.Core.Proxmox;

public class ProxmoxException(string message) : Exception(message);

public sealed class UntrustedCertificateException(string host, string fingerprint)
    : ProxmoxException(L.F("The certificate of %@ is not trusted.", host))
{
    public string Host { get; } = host;
    public string Fingerprint { get; } = fingerprint;
}

public sealed class NeedsTotpException()
    : ProxmoxException(L.T("A two-factor authentication code is required."));

public sealed class NoSpiceException()
    : ProxmoxException(L.T("This VM has no SPICE display. In Proxmox, set Hardware → Display to “SPICE (qxl)” and restart the VM."));

public sealed class InvalidHostException(string host)
    : ProxmoxException(L.F("“%@” is not a valid host name or IP address.", host));

public sealed class BadResponseException()
    : ProxmoxException(L.T("Unexpected response from the server."));

/// <summary>An HTTP error (status 0 = not HTTP: a failed task, a timeout…).</summary>
public sealed class HttpProxmoxException(int status, string detail)
    : ProxmoxException(Describe(status, detail))
{
    public int Status { get; } = status;
    public string Detail { get; } = detail;

    private static string Describe(int status, string detail) =>
        status == 401 ? L.T("Authentication failed: check user name, realm and password.")
        : detail.Length == 0 ? L.F("Server error (HTTP %d).", status)
        : detail;
}

/// <summary>Cloudflare Access answered instead of Proxmox: a service token is needed (or the
/// one configured was refused).</summary>
public sealed class CloudflareAccessException(string host, bool tokenSent)
    : ProxmoxException(tokenSent
        ? L.F("Cloudflare Access refused the service token for %@. Check the Client ID and Secret, and that the Access application has a Service Auth policy that includes this token.", host)
        : L.F("%@ is protected by Cloudflare Access, which Chili can't log in to with a browser page. Create a service token in Cloudflare Zero Trust, allow it with a Service Auth policy, and enter it in the server settings, under Cloudflare Access.", host))
{
    public bool TokenSent { get; } = tokenSent;
}
