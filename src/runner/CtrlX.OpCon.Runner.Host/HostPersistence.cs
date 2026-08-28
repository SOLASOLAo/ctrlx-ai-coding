using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Host;

internal static class HostJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static byte[] Serialize<T>(T value, bool indented = true)
    {
        var options = indented ? Options : new JsonSerializerOptions(Options) { WriteIndented = false };
        return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value, options) + Environment.NewLine);
    }

    public static T Deserialize<T>(byte[] bytes, string description)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(bytes, Options)
                ?? throw new RunnerGateException("HOST_STATE_INVALID", $"{description} is empty.");
        }
        catch (JsonException exception)
        {
            throw new RunnerGateException("HOST_STATE_INVALID", $"{description} is invalid JSON: {exception.Message}");
        }
    }
}

internal static class HostFileSystem
{
    private const int MaximumStatusBytes = 64 * 1024;
    private const int IoAttempts = 6;
    private static readonly TimeSpan IoRetryDelay = TimeSpan.FromMilliseconds(25);

    public static void EnsurePrivateDirectory(string path)
    {
        var info = new DirectoryInfo(path);
        if (info.Exists && (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException("HOST_RUNTIME_REPARSE_POINT", $"Runtime directory must not be a reparse point: {path}");
        }

        Directory.CreateDirectory(path);
        info.Refresh();
        if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException("HOST_RUNTIME_REPARSE_POINT", $"Runtime directory must not be a reparse point: {path}");
        }
    }

    public static byte[] ReadBounded(string path, string description, int maximumBytes = MaximumStatusBytes)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                var info = new FileInfo(path);
                info.Refresh();
                if (!info.Exists)
                {
                    throw new FileNotFoundException($"{description} is missing.", path);
                }
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new RunnerGateException("HOST_STATE_INVALID", $"{description} is a reparse point: {path}");
                }

                using var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    bufferSize: 4096,
                    FileOptions.SequentialScan);
                var length = stream.Length;
                if (length <= 0 || length > maximumBytes)
                {
                    throw new RunnerGateException("HOST_STATE_INVALID", $"{description} has an invalid size.");
                }

                var bytes = new byte[checked((int)length)];
                stream.ReadExactly(bytes);
                if (stream.Position != stream.Length)
                {
                    throw new IOException($"{description} changed while it was read.");
                }
                return bytes;
            }
            catch (IOException) when (attempt < IoAttempts)
            {
                Thread.Sleep(IoRetryDelay);
            }
        }
    }

    public static void WriteAtomic(string path, byte[] bytes)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new RunnerGateException("HOST_STATE_PATH_INVALID", "Host state path has no directory.");
        EnsurePrivateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                       temporary,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            ExecuteIoWithRetry(() =>
            {
                if (File.Exists(path))
                {
                    File.Replace(temporary, path, destinationBackupFileName: null, ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(temporary, path);
                }
            });
        }
        finally
        {
            if (File.Exists(temporary))
            {
                DeleteWithRetry(temporary);
            }
        }
    }

    public static void DeleteWithRetry(string path) =>
        ExecuteIoWithRetry(() => File.Delete(path));

    private static void ExecuteIoWithRetry(Action action)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (IOException) when (attempt < IoAttempts)
            {
                Thread.Sleep(IoRetryDelay);
            }
        }
    }
}

internal sealed class HostOwnerLease : IDisposable
{
    private readonly FileStream stream;

    private HostOwnerLease(FileStream stream)
    {
        this.stream = stream;
    }

    public static HostOwnerLease Acquire(HostRuntimePaths paths)
    {
        HostFileSystem.EnsurePrivateDirectory(paths.RuntimeRoot);
        var lockInfo = new FileInfo(paths.OwnerLockPath);
        if (lockInfo.Exists && (lockInfo.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException("HOST_OWNER_LOCK_INVALID", "Runner Host owner lock is a reparse point.");
        }

        try
        {
            var stream = new FileStream(
                paths.OwnerLockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 256,
                FileOptions.WriteThrough);
            stream.SetLength(0);
            var content = Encoding.UTF8.GetBytes($"pid={Environment.ProcessId}{Environment.NewLine}");
            stream.Write(content);
            stream.Flush(flushToDisk: true);
            return new HostOwnerLease(stream);
        }
        catch (IOException exception)
        {
            throw new RunnerGateException("HOST_ALREADY_RUNNING", $"Another Runner Host owns this engineering root: {exception.Message}", RunnerExitCodes.Busy);
        }
    }

    public void Dispose() => stream.Dispose();
}

internal sealed class HostConsumerStateStore
{
    private static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(5);
    private readonly HostRuntimePaths paths;

    public HostConsumerStateStore(HostRuntimePaths paths)
    {
        this.paths = paths;
    }

    public HostConsumerStateDocument ReadOrCreate(DateTimeOffset now)
    {
        if (!File.Exists(paths.ConsumerStatePath))
        {
            var created = new HostConsumerStateDocument
            {
                EngineeringRoot = paths.EngineeringRoot,
                RootKey = paths.RootKey,
                ActivatedAtUtc = now
            };
            try
            {
                var bytes = HostJson.Serialize(created);
                var directory = Path.GetDirectoryName(paths.ConsumerStatePath)!;
                HostFileSystem.EnsurePrivateDirectory(directory);
                using var stream = new FileStream(
                    paths.ConsumerStatePath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    4096,
                    FileOptions.WriteThrough);
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
                return created;
            }
            catch (IOException) when (File.Exists(paths.ConsumerStatePath))
            {
                // A concurrent creator cannot be trusted until the exact file is
                // read and validated below.
            }
        }

        var document = HostJson.Deserialize<HostConsumerStateDocument>(
            HostFileSystem.ReadBounded(paths.ConsumerStatePath, "Runner Host consumer state"),
            "Runner Host consumer state");
        if (document.SchemaVersion != 1 ||
            document.Kind != "ctrlx-opcon-runner-host-consumer-state" ||
            !document.EngineeringRoot.Equals(paths.EngineeringRoot, StringComparison.OrdinalIgnoreCase) ||
            document.RootKey != paths.RootKey ||
            document.ActivatedAtUtc == default ||
            document.ActivatedAtUtc > DateTimeOffset.UtcNow + ClockSkew)
        {
            throw new RunnerGateException(
                "HOST_CONSUMER_STATE_INVALID",
                "Runner Host consumer activation state is invalid.");
        }

        return document;
    }
}

internal static class LegacyHostStates
{
    public static bool IsKnown(string value) => value is
        HostStates.Starting or HostStates.WaitingForAgent or HostStates.Idle or
        HostStates.Stopping or HostStates.Faulted or HostStates.Stopped;

    public static bool IsLive(string value) => value is
        HostStates.Starting or HostStates.WaitingForAgent or HostStates.Idle or
        HostStates.Stopping or HostStates.Faulted;
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed class LegacyHostStatusDocumentV1
{
    public int SchemaVersion { get; set; }
    public string Kind { get; set; } = string.Empty;
    public int ProtocolVersion { get; set; }
    public string HostInstanceId { get; set; } = string.Empty;
    public string State { get; set; } = string.Empty;
    public string ReasonCode { get; set; } = string.Empty;
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
    public HostSafetyStatus Safety { get; set; } = new();
    public string LogDirectory { get; set; } = string.Empty;
    public string ActiveLogPath { get; set; } = string.Empty;
}

internal sealed class HostStatusStore
{
    private static readonly TimeSpan ClockSkew = TimeSpan.FromSeconds(5);
    private readonly HostRuntimePaths paths;

    public HostStatusStore(HostRuntimePaths paths)
    {
        this.paths = paths;
    }

    public void Publish(HostStatusDocument document)
    {
        ValidateStructure(document);
        HostFileSystem.WriteAtomic(paths.StatusPath, HostJson.Serialize(document));
    }

    public HostStatusDocument? ReadStructured()
    {
        if (!File.Exists(paths.StatusPath))
        {
            return null;
        }

        HostStatusDocument document;
        try
        {
            var bytes = HostFileSystem.ReadBounded(paths.StatusPath, "Runner Host status");
            document = ReadCurrentOrUpgradeLegacy(bytes);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
        ValidateStructure(document);
        return document;
    }

    private HostStatusDocument ReadCurrentOrUpgradeLegacy(byte[] bytes)
    {
        JsonObject root;
        try
        {
            root = JsonNode.Parse(bytes, nodeOptions: null, documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 32
            }) as JsonObject
                ?? throw new JsonException("Root must be an object.");
        }
        catch (JsonException exception)
        {
            throw new RunnerGateException("HOST_STATE_INVALID", $"Runner Host status is invalid JSON: {exception.Message}");
        }

        if (root["schemaVersion"] is not JsonValue schemaValue ||
            !schemaValue.TryGetValue<int>(out var schemaVersion))
        {
            throw new RunnerGateException("HOST_STATE_INVALID", "Runner Host status has no valid schema version.");
        }

        if (schemaVersion == HostConstants.StatusSchemaVersion)
        {
            return HostJson.Deserialize<HostStatusDocument>(bytes, "Runner Host status");
        }
        if (schemaVersion != 1)
        {
            throw new RunnerGateException("HOST_STATE_INVALID", "Runner Host status schema is unsupported.");
        }

        var legacy = HostJson.Deserialize<LegacyHostStatusDocumentV1>(bytes, "legacy Runner Host status");
        if (legacy.SchemaVersion != 1 ||
            legacy.Kind != HostConstants.StatusKind ||
            legacy.ProtocolVersion != HostConstants.ProtocolVersion ||
            !LegacyHostStates.IsKnown(legacy.State) ||
            legacy.Safety is null ||
            legacy.Safety.StartsBroker ||
            legacy.Safety.StartsPleOrMcp ||
            legacy.Safety.OnlineOperationsAllowed ||
            legacy.Safety.AutomaticActionExecutionEnabled)
        {
            throw new RunnerGateException(
                "HOST_LEGACY_STATE_INVALID",
                "Legacy Runner Host status does not match the P1.3a safety contract.");
        }

        var legacyMayBeLive = LegacyHostStates.IsLive(legacy.State);
        return new HostStatusDocument
        {
            SchemaVersion = HostConstants.StatusSchemaVersion,
            Kind = legacy.Kind,
            ProtocolVersion = legacy.ProtocolVersion,
            HostInstanceId = legacy.HostInstanceId,
            State = legacyMayBeLive ? HostStates.Blocked : HostStates.Stopped,
            ReasonCode = legacyMayBeLive ? "HOST_LEGACY_VERSION_ACTIVE" : legacy.ReasonCode,
            HostPid = legacy.HostPid,
            ProcessStartTimeUtc = legacy.ProcessStartTimeUtc,
            WindowsSessionId = legacy.WindowsSessionId,
            UserSid = legacy.UserSid,
            ExecutablePath = legacy.ExecutablePath,
            ExecutableSha256 = legacy.ExecutableSha256,
            EngineeringRoot = legacy.EngineeringRoot,
            RootKey = legacy.RootKey,
            PipeName = legacy.PipeName,
            StartedAtUtc = legacy.StartedAtUtc,
            HeartbeatAtUtc = legacy.HeartbeatAtUtc,
            ExpiresAtUtc = legacy.ExpiresAtUtc,
            Agent = legacy.Agent,
            Action = legacyMayBeLive
                ? new HostActionStatus
                {
                    State = HostActionStates.Invalid,
                    ReasonCode = "HOST_LEGACY_VERSION_ACTIVE"
                }
                : new HostActionStatus
                {
                    State = HostActionStates.None,
                    ReasonCode = "HOST_NO_PENDING_ACTION"
                },
            Safety = new HostSafetyStatus
            {
                StartsBroker = false,
                StartsPleOrMcp = false,
                OnlineOperationsAllowed = false,
                AutomaticActionExecutionEnabled = true
            },
            LogDirectory = legacy.LogDirectory,
            ActiveLogPath = legacy.ActiveLogPath
        };
    }

    public HostStatusDocument? ReadLive()
    {
        var observation = Observe();
        return observation.Live ? observation.Document : null;
    }

    public HostStatusObservation Observe()
    {
        var document = ReadStructured();
        if (document is null)
        {
            return new HostStatusObservation(null, Live: false, CrashRecoveryPending: false, "HOST_NOT_RUNNING");
        }
        if (!HostStates.IsLive(document.State))
        {
            return new HostStatusObservation(document, Live: false, CrashRecoveryPending: false, "HOST_NOT_RUNNING");
        }

        try
        {
            ValidateLiveProcess(document);
        }
        catch (RunnerGateException exception) when (exception.ReasonCode is "HOST_PROCESS_NOT_RUNNING" or "HOST_PROCESS_IDENTITY_INVALID")
        {
            return new HostStatusObservation(document, Live: false, CrashRecoveryPending: true, "HOST_CRASH_RECOVERY_PENDING");
        }

        var now = DateTimeOffset.UtcNow;
        if (document.HeartbeatAtUtc > now + ClockSkew || document.ExpiresAtUtc <= now)
        {
            throw new RunnerGateException("HOST_STATUS_STALE", "Runner Host status heartbeat is stale while its process is still running.");
        }

        return new HostStatusObservation(document, Live: true, CrashRecoveryPending: false, document.ReasonCode);
    }

    public void AssertRecoverableBeforeStart()
    {
        var document = ReadStructured();
        if (document is null || !HostStates.IsLive(document.State))
        {
            return;
        }

        if (TryValidateLiveProcess(document))
        {
            throw new RunnerGateException("HOST_ALREADY_RUNNING", "A live Runner Host status already exists for this engineering root.", RunnerExitCodes.Busy);
        }
    }

    public void DeleteIfOwned(string hostInstanceId)
    {
        if (!File.Exists(paths.StatusPath))
        {
            return;
        }

        var document = ReadStructured();
        if (document is null || document.HostInstanceId != hostInstanceId)
        {
            throw new RunnerGateException("HOST_STATUS_NOT_OWNER", "Runner Host status belongs to another instance.");
        }

        HostFileSystem.DeleteWithRetry(paths.StatusPath);
    }

    private void ValidateStructure(HostStatusDocument document)
    {
        if (document.SchemaVersion != HostConstants.StatusSchemaVersion ||
            document.ProtocolVersion != HostConstants.ProtocolVersion ||
            document.Kind != HostConstants.StatusKind ||
            !HostStates.IsKnown(document.State) ||
            !IsSafeIdentifier(document.HostInstanceId) ||
            !IsSafeIdentifier(document.ReasonCode) ||
            document.HostPid <= 0 ||
            document.WindowsSessionId <= 0 ||
            string.IsNullOrWhiteSpace(document.UserSid) ||
            document.ProcessStartTimeUtc == default ||
            document.StartedAtUtc == default ||
            document.HeartbeatAtUtc == default ||
            document.ExpiresAtUtc <= document.HeartbeatAtUtc ||
            document.ExpiresAtUtc - document.HeartbeatAtUtc > TimeSpan.FromSeconds(30) ||
            !document.EngineeringRoot.Equals(paths.EngineeringRoot, StringComparison.OrdinalIgnoreCase) ||
            document.RootKey != paths.RootKey ||
            document.PipeName != paths.PipeName ||
            document.UserSid != BrokerWireProtocol.CurrentUserSid() ||
            document.Agent is null ||
            !IsValidAgent(document.Agent, document.WindowsSessionId) ||
            (document.State == HostStates.WaitingForAgent && document.Agent.Available) ||
            document.Action is null ||
            !IsValidAction(document.Action) ||
            !IsConsistentState(document.State, document.ReasonCode, document.Action) ||
            document.Safety is null ||
            !Path.GetFullPath(document.LogDirectory).Equals(paths.LogDirectory, StringComparison.OrdinalIgnoreCase) ||
            !IsSafeLogPath(document.ActiveLogPath) ||
            !Path.IsPathFullyQualified(document.ExecutablePath) ||
            !IsSha256(document.ExecutableSha256) ||
            document.Safety.StartsBroker ||
            document.Safety.StartsPleOrMcp ||
            document.Safety.OnlineOperationsAllowed ||
            !document.Safety.AutomaticActionExecutionEnabled)
        {
            throw new RunnerGateException("HOST_STATE_INVALID", "Runner Host status identity, schema, or safety contract is invalid.");
        }
    }

    private static bool IsSafeIdentifier(string? value, int maximumLength = 128) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-');

    private static bool IsSha256(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length == 64 &&
        value.All(Uri.IsHexDigit);

    private static bool IsValidAgent(HostAgentStatus agent, int hostSessionId)
    {
        if (!IsSafeIdentifier(agent.ReasonCode))
        {
            return false;
        }
        if (!agent.Available)
        {
            return agent.BrokerPid is null &&
                agent.WindowsSessionId is null &&
                agent.State is null &&
                agent.Profile is null &&
                agent.PlcProject is null;
        }

        return agent.ReasonCode == "BROKER_REGISTRATION_VALIDATED" &&
            agent.BrokerPid is > 0 &&
            agent.WindowsSessionId == hostSessionId &&
            !string.IsNullOrWhiteSpace(agent.State) &&
            !string.IsNullOrWhiteSpace(agent.Profile) &&
            !string.IsNullOrWhiteSpace(agent.PlcProject) &&
            Path.IsPathFullyQualified(agent.PlcProject);
    }

    private bool IsValidAction(HostActionStatus action)
    {
        if (!HostActionStates.IsKnown(action.State) ||
            !IsSafeIdentifier(action.ReasonCode) ||
            action.PendingCount < 0 || action.PendingCount > 2048 ||
            action.InvalidCount < 0 || action.InvalidCount > 2048 ||
            action.LegacyIgnoredCount < 0 || action.LegacyIgnoredCount > 2048)
        {
            return false;
        }

        var identityRequired = action.State is
            HostActionStates.WaitingForAgent or
            HostActionStates.Executing or
            HostActionStates.RecoveryPending or
            HostActionStates.ResultReady;
        if (!identityRequired)
        {
            return action.OperationId is null &&
                action.ActionId is null &&
                action.ActionKind is null &&
                action.ActionSha256 is null &&
                action.RunId is null &&
                action.ResultState is null &&
                action.ResultPath is null &&
                action.EvidencePath is null;
        }

        if (action.OperationId is null || !IsSafeIdentifier(action.OperationId) ||
            action.ActionId is null || !IsSafeIdentifier(action.ActionId) ||
            action.ActionKind is null || !IsSafeIdentifier(action.ActionKind) ||
            action.ActionSha256 is null || !IsSha256(action.ActionSha256) ||
            action.RunId is null || !IsSafeIdentifier(action.RunId, 256) ||
            action.RunId != RunnerRunStore.GetRunId(action.ActionId, action.ActionSha256))
        {
            return false;
        }

        if (action.ResultPath is not null && !IsPathInside(
                Path.Combine(paths.EngineeringRoot, "data", "runs", "runner-p12"),
                action.ResultPath))
        {
            return false;
        }
        if (action.EvidencePath is not null && !IsPathInside(
                Path.Combine(paths.EngineeringRoot, "data", "runner-evidence"),
                action.EvidencePath))
        {
            return false;
        }

        if (action.State == HostActionStates.ResultReady)
        {
            var expectedResultPath = Path.Combine(
                RunnerRunStore.GetRunRoot(paths.EngineeringRoot, action.ActionId, action.ActionSha256),
                "result.json");
            return action.ResultState is not null &&
                RunnerStates.IsTerminal(action.ResultState) &&
                action.ResultPath is not null &&
                HostRuntimePaths.NormalizePath(action.ResultPath)
                    .Equals(HostRuntimePaths.NormalizePath(expectedResultPath), StringComparison.OrdinalIgnoreCase);
        }

        return action.ResultState is null &&
            action.ResultPath is null &&
            action.EvidencePath is null;
    }

    private static bool IsConsistentState(
        string state,
        string reasonCode,
        HostActionStatus action)
    {
        var actionMatches = state switch
        {
            HostStates.Starting or HostStates.WaitingForAction or HostStates.Idle or HostStates.Stopped =>
                action.State == HostActionStates.None,
            HostStates.WaitingForAgent => action.State == HostActionStates.WaitingForAgent,
            HostStates.Executing => action.State is HostActionStates.Executing or HostActionStates.RecoveryPending,
            HostStates.WaitingForCoordinator => action.State == HostActionStates.ResultReady,
            HostStates.Blocked => action.State is HostActionStates.Invalid or HostActionStates.Ambiguous,
            HostStates.Stopping or HostStates.Faulted => true,
            _ => false
        };
        if (!actionMatches)
        {
            return false;
        }

        return state is HostStates.WaitingForAction or HostStates.WaitingForAgent or
            HostStates.Executing or HostStates.WaitingForCoordinator or HostStates.Blocked
                ? reasonCode == action.ReasonCode
                : true;
    }

    private static bool IsPathInside(string root, string candidate)
    {
        try
        {
            var normalizedRoot = HostRuntimePaths.NormalizePath(root);
            var normalizedCandidate = HostRuntimePaths.NormalizePath(candidate);
            return normalizedCandidate.StartsWith(
                normalizedRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private bool IsSafeLogPath(string value)
    {
        try
        {
            var fullPath = HostRuntimePaths.NormalizePath(value);
            return Path.GetDirectoryName(fullPath)?.Equals(paths.LogDirectory, StringComparison.OrdinalIgnoreCase) == true &&
                HostLogStore.IsManagedLogName(Path.GetFileName(fullPath));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static bool TryValidateLiveProcess(HostStatusDocument document)
    {
        try
        {
            ValidateLiveProcess(document);
            return true;
        }
        catch (RunnerGateException)
        {
            return false;
        }
    }

    private static void ValidateLiveProcess(HostStatusDocument document)
    {
        Process process;
        try
        {
            process = Process.GetProcessById(document.HostPid);
        }
        catch (ArgumentException exception)
        {
            throw new RunnerGateException("HOST_PROCESS_NOT_RUNNING", $"Registered Runner Host is not running: {exception.Message}");
        }

        using (process)
        {
            try
            {
                var executablePath = process.MainModule?.FileName;
                if (process.HasExited ||
                    process.SessionId != document.WindowsSessionId ||
                    process.SessionId != Process.GetCurrentProcess().SessionId ||
                    Math.Abs((process.StartTime.ToUniversalTime() - document.ProcessStartTimeUtc.UtcDateTime).TotalMilliseconds) > 1000 ||
                    string.IsNullOrWhiteSpace(executablePath) ||
                    !HostRuntimePaths.NormalizePath(executablePath).Equals(document.ExecutablePath, StringComparison.OrdinalIgnoreCase) ||
                    !RunnerHash.Sha256File(executablePath).Equals(document.ExecutableSha256, StringComparison.OrdinalIgnoreCase))
                {
                    throw new RunnerGateException("HOST_PROCESS_IDENTITY_INVALID", "Runner Host process identity no longer matches its status.");
                }
            }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception or UnauthorizedAccessException or IOException)
            {
                throw new RunnerGateException("HOST_PROCESS_IDENTITY_INVALID", $"Runner Host process identity cannot be verified: {exception.Message}");
            }
        }
    }
}

internal sealed class HostLogStore
{
    private const long MaximumFileBytes = 4L * 1024 * 1024;
    private const int MaximumFiles = 14;
    private static readonly Regex ManagedLogName = new(
        @"^host-(?<date>[0-9]{8})-(?<segment>[0-9]{2})[.]jsonl$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private readonly HostRuntimePaths paths;
    private string activeLogPath;

    public HostLogStore(HostRuntimePaths paths)
    {
        this.paths = paths;
        HostFileSystem.EnsurePrivateDirectory(paths.LogDirectory);
        activeLogPath = SelectActiveLog();
        ApplyRetention();
    }

    public string ActiveLogPath => activeLogPath;

    public void Write(string eventName, string state, string reasonCode, string hostInstanceId)
    {
        var record = new
        {
            schemaVersion = HostConstants.StatusSchemaVersion,
            kind = HostConstants.LogKind,
            atUtc = DateTimeOffset.UtcNow,
            eventName,
            state,
            reasonCode,
            hostInstanceId,
            engineeringRootKey = paths.RootKey,
            safety = new
            {
                startsBroker = false,
                startsPleOrMcp = false,
                onlineOperationsAllowed = false,
                automaticActionExecutionEnabled = true
            }
        };
        var bytes = HostJson.Serialize(record, indented: false);
        if (bytes.Length > MaximumFileBytes)
        {
            throw new RunnerGateException("HOST_LOG_RECORD_TOO_LARGE", "Runner Host log record exceeds the fixed log segment limit.");
        }

        var activeInfo = new FileInfo(activeLogPath);
        if (activeInfo.Exists && activeInfo.Length + bytes.Length > MaximumFileBytes)
        {
            activeLogPath = SelectActiveLog(forceNext: true);
        }

        using var stream = new FileStream(activeLogPath, FileMode.Append, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
        ApplyRetention();
    }

    public IReadOnlyList<HostLogFileInfo> ListRecent() => EnumerateSafeLogs()
        .OrderByDescending(file => file.LastWriteTimeUtc)
        .Take(MaximumFiles)
        .Select(file => new HostLogFileInfo(file.FullName, file.Length, file.LastWriteTimeUtc))
        .ToArray();

    private string SelectActiveLog(bool forceNext = false)
    {
        var prefix = $"host-{DateTime.UtcNow:yyyyMMdd}-";
        var today = EnumerateSafeLogs()
            .Where(file => file.Name.StartsWith(prefix, StringComparison.Ordinal))
            .OrderBy(file => file.Name, StringComparer.Ordinal)
            .ToArray();
        if (!forceNext && today.LastOrDefault() is { Length: < MaximumFileBytes } current)
        {
            return current.FullName;
        }

        var next = 0;
        if (today.Length > 0 &&
            TryParseManagedLogName(today[^1].Name, out _, out var lastSegment))
        {
            next = lastSegment + 1;
        }
        if (next > 99)
        {
            throw new RunnerGateException("HOST_LOG_ROLLOVER_EXHAUSTED", "Runner Host produced more than 100 log segments in one day.");
        }

        return Path.Combine(paths.LogDirectory, $"{prefix}{next:00}.jsonl");
    }

    private void ApplyRetention()
    {
        var logs = EnumerateSafeLogs()
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ThenByDescending(file => file.Name, StringComparer.Ordinal)
            .ToArray();
        foreach (var stale in logs.Skip(MaximumFiles))
        {
            if (!stale.FullName.Equals(activeLogPath, StringComparison.OrdinalIgnoreCase))
            {
                HostFileSystem.DeleteWithRetry(stale.FullName);
            }
        }
    }

    private IEnumerable<FileInfo> EnumerateSafeLogs()
    {
        var directory = new DirectoryInfo(paths.LogDirectory);
        if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            yield break;
        }

        foreach (var file in directory.EnumerateFiles("host-????????-??.jsonl", SearchOption.TopDirectoryOnly))
        {
            if ((file.Attributes & FileAttributes.ReparsePoint) == 0 &&
                file.DirectoryName?.Equals(paths.LogDirectory, StringComparison.OrdinalIgnoreCase) == true &&
                TryParseManagedLogName(file.Name, out _, out _))
            {
                yield return file;
            }
        }
    }

    internal static bool IsManagedLogName(string value) =>
        TryParseManagedLogName(value, out _, out _);

    private static bool TryParseManagedLogName(string value, out DateTime date, out int segment)
    {
        date = default;
        segment = default;
        var match = ManagedLogName.Match(value);
        return match.Success &&
            DateTime.TryParseExact(
                match.Groups["date"].Value,
                "yyyyMMdd",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out date) &&
            int.TryParse(match.Groups["segment"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out segment);
    }
}
