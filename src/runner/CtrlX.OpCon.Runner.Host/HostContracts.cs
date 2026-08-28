using System.Text.Json.Serialization;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Host;

internal static class HostConstants
{
    public const int StatusSchemaVersion = 2;
    public const int ControlSchemaVersion = 1;
    public const int ProtocolVersion = 1;
    public const int MaximumPipeMessageBytes = 32 * 1024;
    public const string StatusKind = "ctrlx-opcon-runner-host-status";
    public const string StatusObservationKind = "ctrlx-opcon-runner-host-observation";
    public const string StopRequestKind = "ctrlx-opcon-runner-host-stop-request";
    public const string StopReplyKind = "ctrlx-opcon-runner-host-stop-reply";
    public const string LogKind = "ctrlx-opcon-runner-host-log";
}

internal static class HostStates
{
    public const string Starting = "STARTING";
    public const string WaitingForAction = "WAITING_FOR_ACTION";
    public const string WaitingForAgent = "WAITING_FOR_AGENT";
    public const string Executing = "EXECUTING";
    public const string WaitingForCoordinator = "WAITING_FOR_COORDINATOR";
    public const string Blocked = "BLOCKED";
    public const string Idle = "IDLE";
    public const string Stopping = "STOPPING";
    public const string Faulted = "FAULTED";
    public const string Stopped = "STOPPED";

    public static bool IsKnown(string value) => value is
        Starting or WaitingForAction or WaitingForAgent or Executing or
        WaitingForCoordinator or Blocked or Idle or Stopping or Faulted or Stopped;

    public static bool IsLive(string value) => value is
        Starting or WaitingForAction or WaitingForAgent or Executing or
        WaitingForCoordinator or Blocked or Idle or Stopping or Faulted;
}

internal static class HostActionStates
{
    public const string None = "NONE";
    public const string WaitingForAgent = "WAITING_FOR_AGENT";
    public const string Executing = "EXECUTING";
    public const string RecoveryPending = "RECOVERY_PENDING";
    public const string ResultReady = "RESULT_READY";
    public const string Invalid = "INVALID";
    public const string Ambiguous = "AMBIGUOUS";

    public static bool IsKnown(string value) => value is
        None or WaitingForAgent or Executing or RecoveryPending or
        ResultReady or Invalid or Ambiguous;
}

internal sealed record HostRuntimePaths(
    string EngineeringRoot,
    string RootKey,
    string RuntimeRoot,
    string OwnerLockPath,
    string StatusPath,
    string ConsumerStatePath,
    string LogDirectory,
    string PipeName)
{
    public static HostRuntimePaths Create(string engineeringRoot, string? runtimeRootOverride = null)
    {
        var root = NormalizePath(engineeringRoot);
        if (!Directory.Exists(root))
        {
            throw new RunnerGateException("HOST_ENGINEERING_ROOT_NOT_FOUND", $"Engineering root does not exist: {root}");
        }

        var rootInfo = new DirectoryInfo(root);
        if ((rootInfo.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException(
                "HOST_ENGINEERING_ROOT_ALIAS_FORBIDDEN",
                "Engineering root must be a direct directory, not a junction or symbolic link.");
        }

        var identityPath = OperatingSystem.IsWindows() ? root.ToUpperInvariant() : root;
        var rootKey = RunnerHash.Sha256Text(identityPath)[..32].ToLowerInvariant();
        string runtimeRoot;
        if (string.IsNullOrWhiteSpace(runtimeRootOverride))
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(local))
            {
                throw new RunnerGateException("HOST_RUNTIME_ROOT_UNAVAILABLE", "Current-user LocalApplicationData is unavailable.");
            }

            runtimeRoot = Path.Combine(local, "CtrlX.OpCon.Runner", "hosts", rootKey);
        }
        else
        {
            runtimeRoot = Path.GetFullPath(runtimeRootOverride);
        }

        runtimeRoot = NormalizePath(runtimeRoot);
        return new HostRuntimePaths(
            root,
            rootKey,
            runtimeRoot,
            Path.Combine(runtimeRoot, "owner.lock"),
            Path.Combine(runtimeRoot, "status.json"),
            Path.Combine(runtimeRoot, "consumer.json"),
            Path.Combine(runtimeRoot, "logs"),
            $"ctrlx-opcon-runner-host-{rootKey}");
    }

    public static string NormalizePath(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}

internal sealed record HostProcessIdentity(
    int ProcessId,
    DateTimeOffset ProcessStartTimeUtc,
    int WindowsSessionId,
    string UserSid,
    string ExecutablePath,
    string ExecutableSha256)
{
    public static HostProcessIdentity CaptureCurrentInteractive()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new RunnerGateException("HOST_WINDOWS_REQUIRED", "The Runner Host is supported only on Windows.");
        }

        using var process = System.Diagnostics.Process.GetCurrentProcess();
        if (!Environment.UserInteractive || process.SessionId <= 0)
        {
            throw new RunnerGateException(
                "HOST_INTERACTIVE_SESSION_REQUIRED",
                "The Runner Host must run in a current-user interactive session, never Session 0.");
        }

        var executablePath = Environment.ProcessPath ?? process.MainModule?.FileName;
        if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath))
        {
            throw new RunnerGateException("HOST_EXECUTABLE_UNAVAILABLE", "Runner Host executable identity is unavailable.");
        }

        return new HostProcessIdentity(
            process.Id,
            process.StartTime.ToUniversalTime(),
            process.SessionId,
            BrokerWireProtocol.CurrentUserSid(),
            HostRuntimePaths.NormalizePath(executablePath),
            RunnerHash.Sha256File(executablePath));
    }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostStatusDocument
{
    public int SchemaVersion { get; set; } = HostConstants.StatusSchemaVersion;
    public string Kind { get; set; } = HostConstants.StatusKind;
    public int ProtocolVersion { get; set; } = HostConstants.ProtocolVersion;
    public string HostInstanceId { get; set; } = string.Empty;
    public string State { get; set; } = HostStates.Starting;
    public string ReasonCode { get; set; } = "HOST_STARTING";
    public int HostPid { get; set; }
    public DateTimeOffset ProcessStartTimeUtc { get; set; }
    public int WindowsSessionId { get; set; }
    public string UserSid { get; set; } = string.Empty;
    public string ExecutablePath { get; set; } = string.Empty;
    public string ExecutableSha256 { get; set; } = string.Empty;
    public string EngineeringRoot { get; set; } = string.Empty;
    public string RootKey { get; set; } = string.Empty;
    public string PipeName { get; set; } = string.Empty;
    public DateTimeOffset StartedAtUtc { get; set; }
    public DateTimeOffset HeartbeatAtUtc { get; set; }
    public DateTimeOffset ExpiresAtUtc { get; set; }
    [JsonRequired]
    public HostAgentStatus Agent { get; set; } = new();
    [JsonRequired]
    public HostActionStatus Action { get; set; } = new();
    [JsonRequired]
    public HostSafetyStatus Safety { get; set; } = new();
    public string LogDirectory { get; set; } = string.Empty;
    public string ActiveLogPath { get; set; } = string.Empty;
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostActionStatus
{
    public string State { get; set; } = HostActionStates.None;
    public string ReasonCode { get; set; } = "HOST_NO_PENDING_ACTION";
    public string? OperationId { get; set; }
    public string? ActionId { get; set; }
    public string? ActionKind { get; set; }
    public string? ActionSha256 { get; set; }
    public string? RunId { get; set; }
    public string? ResultState { get; set; }
    public string? ResultPath { get; set; }
    public string? EvidencePath { get; set; }
    public int PendingCount { get; set; }
    public int InvalidCount { get; set; }
    public int LegacyIgnoredCount { get; set; }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostAgentStatus
{
    [JsonRequired]
    public bool Available { get; set; }
    [JsonRequired]
    public string ReasonCode { get; set; } = "BLOCKED_SESSION_UNAVAILABLE";
    public string? State { get; set; }
    public int? BrokerPid { get; set; }
    public int? WindowsSessionId { get; set; }
    public string? Profile { get; set; }
    public string? PlcProject { get; set; }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostSafetyStatus
{
    [JsonRequired]
    public bool StartsBroker { get; set; }
    [JsonRequired]
    public bool StartsPleOrMcp { get; set; }
    [JsonRequired]
    public bool OnlineOperationsAllowed { get; set; }
    [JsonRequired]
    public bool AutomaticActionExecutionEnabled { get; set; }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostStopRequest
{
    public int SchemaVersion { get; set; } = HostConstants.ControlSchemaVersion;
    public string Kind { get; set; } = HostConstants.StopRequestKind;
    public int ProtocolVersion { get; set; } = HostConstants.ProtocolVersion;
    public string HostInstanceId { get; set; } = string.Empty;
    public string EngineeringRoot { get; set; } = string.Empty;
    public string UserSid { get; set; } = string.Empty;
    public int WindowsSessionId { get; set; }
    public string ClientNonce { get; set; } = string.Empty;
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostStopReply
{
    public int SchemaVersion { get; set; } = HostConstants.ControlSchemaVersion;
    public string Kind { get; set; } = HostConstants.StopReplyKind;
    public int ProtocolVersion { get; set; } = HostConstants.ProtocolVersion;
    public string HostInstanceId { get; set; } = string.Empty;
    public string ClientNonce { get; set; } = string.Empty;
    public bool Accepted { get; set; }
    public string ReasonCode { get; set; } = string.Empty;
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class HostConsumerStateDocument
{
    public int SchemaVersion { get; set; } = 1;
    public string Kind { get; set; } = "ctrlx-opcon-runner-host-consumer-state";
    public string EngineeringRoot { get; set; } = string.Empty;
    public string RootKey { get; set; } = string.Empty;
    public DateTimeOffset ActivatedAtUtc { get; set; }
}

internal sealed record HostLogFileInfo(string Path, long Bytes, DateTimeOffset LastWriteTimeUtc);

internal sealed record HostStatusObservation(
    HostStatusDocument? Document,
    bool Live,
    bool CrashRecoveryPending,
    string ReasonCode);
