using System.Diagnostics;
using System.Security.Principal;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public sealed record BrokerProcessIdentity(
    int ProcessId,
    DateTimeOffset ProcessStartTimeUtc,
    int WindowsSessionId,
    string UserSid,
    string ExecutablePath,
    string ExecutableSha256)
{
    public static BrokerProcessIdentity CaptureCurrentInteractive()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new BrokerInfrastructureException("BROKER_WINDOWS_REQUIRED", "The interactive ctrlX Broker is supported only on Windows.");
        }

        using var process = Process.GetCurrentProcess();
        if (!Environment.UserInteractive || process.SessionId <= 0)
        {
            throw new BrokerInfrastructureException(
                "BROKER_INTERACTIVE_SESSION_REQUIRED",
                "The Broker must run in an interactive user session and must not run in Session 0.");
        }

        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new BrokerInfrastructureException("BROKER_USER_SID_UNAVAILABLE", "The current Windows user SID is unavailable.");
        }

        var executablePath = Environment.ProcessPath ?? process.MainModule?.FileName;
        if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath))
        {
            throw new BrokerInfrastructureException("BROKER_EXECUTABLE_UNAVAILABLE", "The Broker executable path is unavailable.");
        }

        executablePath = BrokerRuntimePaths.NormalizePath(executablePath);
        return new BrokerProcessIdentity(
            process.Id,
            process.StartTime.ToUniversalTime(),
            process.SessionId,
            userSid,
            executablePath,
            BrokerRuntimePaths.Sha256File(executablePath));
    }
}
