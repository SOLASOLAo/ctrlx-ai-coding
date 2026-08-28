using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
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
                if (stream.Length <= 0 || stream.Length > maximumBytes)
                {
                    throw new RunnerGateException("HOST_STATE_INVALID", $"{description} has an invalid size.");
                }

                var bytes = new byte[checked((int)stream.Length)];
                stream.ReadExactly(bytes);
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

internal sealed class HostStatusStore
{
    private static readonly TimeSpan ClockSkew = TimeSpan.FromSeconds(5);
    private readonly HostRuntimePaths paths;

    public HostStatusStore(HostRuntimePaths paths)
    {
        this.paths = paths;
    }

    public void Publish(HostStatusDocument document) =>
        HostFileSystem.WriteAtomic(paths.StatusPath, HostJson.Serialize(document));

    public HostStatusDocument? ReadStructured()
    {
        if (!File.Exists(paths.StatusPath))
        {
            return null;
        }

        HostStatusDocument document;
        try
        {
            document = HostJson.Deserialize<HostStatusDocument>(
                HostFileSystem.ReadBounded(paths.StatusPath, "Runner Host status"),
                "Runner Host status");
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
        ValidateStructure(document);
        return document;
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
        if (document.SchemaVersion != HostConstants.SchemaVersion ||
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
            document.Safety is null ||
            !Path.GetFullPath(document.LogDirectory).Equals(paths.LogDirectory, StringComparison.OrdinalIgnoreCase) ||
            !IsSafeLogPath(document.ActiveLogPath) ||
            !Path.IsPathFullyQualified(document.ExecutablePath) ||
            !IsSha256(document.ExecutableSha256) ||
            document.Safety.StartsBroker ||
            document.Safety.StartsPleOrMcp ||
            document.Safety.OnlineOperationsAllowed ||
            document.Safety.AutomaticActionExecutionEnabled)
        {
            throw new RunnerGateException("HOST_STATE_INVALID", "Runner Host status identity, schema, or safety contract is invalid.");
        }
    }

    private static bool IsSafeIdentifier(string value) =>
        value.Length is > 0 and <= 128 && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-');

    private static bool IsSha256(string value) =>
        value.Length == 64 && value.All(Uri.IsHexDigit);

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
            schemaVersion = HostConstants.SchemaVersion,
            kind = HostConstants.LogKind,
            atUtc = DateTimeOffset.UtcNow,
            eventName,
            state,
            reasonCode,
            hostInstanceId,
            engineeringRootKey = paths.RootKey,
            safety = new { startsBroker = false, startsPleOrMcp = false, onlineOperationsAllowed = false }
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
