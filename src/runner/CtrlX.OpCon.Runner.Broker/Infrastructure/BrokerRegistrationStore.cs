using System.Diagnostics;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public static class BrokerRegistrationStates
{
    public const string Starting = "starting";
    public const string Ready = "ready";
    public const string Busy = "busy";
    public const string Draining = "draining";
    public const string Faulted = "faulted";

    private static readonly HashSet<string> KnownStates = new(StringComparer.Ordinal)
    {
        Starting, Ready, Busy, Draining, Faulted
    };

    public static bool IsKnown(string state) => KnownStates.Contains(state);
}

/// <summary>
/// Publishes the Core wire-protocol registration at its one canonical discovery
/// path. Owner leases and durable operation records remain scoped more narrowly
/// by profile/project identity, but clients discover the Broker by engineering root.
/// </summary>
public sealed class BrokerRegistrationStore
{
    private static readonly TimeSpan RegistrationLockTimeout = TimeSpan.FromSeconds(2);

    private static readonly Regex PipeNamePattern = new(
        "\\A[A-Za-z0-9_.-]+\\z",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private readonly BrokerRuntimePaths paths;

    public BrokerRegistrationStore(BrokerRuntimePaths paths)
    {
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));
    }

    public BrokerRegistration Publish(
        string brokerInstanceId,
        string pipeName,
        int mcpPid,
        int plePid,
        string persistentSessionId,
        string state,
        TimeSpan heartbeatTtl)
    {
        ValidatePublishArguments(
            brokerInstanceId,
            pipeName,
            mcpPid,
            plePid,
            persistentSessionId,
            state,
            heartbeatTtl);

        paths.EnsureCreated();
        var process = BrokerProcessIdentity.CaptureCurrentInteractive();
        return WithRegistrationLock(() =>
        {
            var now = DateTimeOffset.UtcNow;
            if (File.Exists(paths.RegistrationPath))
            {
                var existing = ReadDocument(requireCurrentProjectIdentity: false);
                if (existing.ExpiresAtUtc > now &&
                    (!IsOwnedBy(existing, brokerInstanceId, process) ||
                     !MatchesCurrentProjectIdentity(existing)))
                {
                    throw new BrokerInfrastructureException(
                        "BROKER_REGISTRATION_ACTIVE_OWNER",
                        "An unexpired Broker registration already owns this engineering root.");
                }
            }

            var document = new BrokerRegistrationDocument
            {
                ProtocolVersion = BrokerWireProtocol.Version,
                BrokerInstanceId = brokerInstanceId,
                PipeName = pipeName,
                BrokerPid = process.ProcessId,
                ProcessStartTimeUtc = process.ProcessStartTimeUtc,
                WindowsSessionId = process.WindowsSessionId,
                UserSid = process.UserSid,
                ExecutablePath = process.ExecutablePath,
                ExecutableSha256 = process.ExecutableSha256,
                EngineeringRoot = paths.EngineeringRoot,
                StationRoot = paths.StationRoot,
                PlcProject = paths.PlcProject,
                Profile = paths.Profile,
                McpPid = mcpPid,
                PlePid = plePid,
                PersistentSessionId = persistentSessionId,
                State = state,
                IssuedAtUtc = now,
                HeartbeatAtUtc = now,
                ExpiresAtUtc = now + heartbeatTtl
            };
            Validate(document);
            BrokerAtomicJson.Write(paths.RegistrationPath, document, overwrite: true);
            return ToCore(document);
        });
    }

    public BrokerRegistration Heartbeat(
        string brokerInstanceId,
        string state,
        TimeSpan heartbeatTtl)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        ValidateStateAndTtl(state, heartbeatTtl);
        paths.EnsureCreated();
        return WithRegistrationLock(() =>
        {
            var document = ReadDocument();
            EnsureCurrentProcessOwns(document, brokerInstanceId);

            var now = DateTimeOffset.UtcNow;
            document.State = state;
            document.HeartbeatAtUtc = now;
            document.ExpiresAtUtc = now + heartbeatTtl;
            Validate(document);
            BrokerAtomicJson.Write(paths.RegistrationPath, document, overwrite: true);
            return ToCore(document);
        });
    }

    public BrokerRegistration Read()
    {
        var document = ReadDocument();
        return ToCore(document);
    }

    public void RemoveIfOwned(string brokerInstanceId)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        paths.EnsureCreated();
        WithRegistrationLock(() =>
        {
            if (!File.Exists(paths.RegistrationPath))
            {
                return true;
            }

            var document = ReadDocument();
            EnsureCurrentProcessOwns(document, brokerInstanceId);
            File.Delete(paths.RegistrationPath);
            return true;
        });
    }

    private BrokerRegistrationDocument ReadDocument(bool requireCurrentProjectIdentity = true)
    {
        var document = BrokerAtomicJson.Read<BrokerRegistrationDocument>(paths.RegistrationPath, "Broker registration");
        Validate(document, requireCurrentProjectIdentity);
        return document;
    }

    private void Validate(BrokerRegistrationDocument document, bool requireCurrentProjectIdentity = true)
    {
        if (document.SchemaVersion != 1 ||
            document.Kind != BrokerWireProtocol.RegistrationKind ||
            document.ProtocolVersion != BrokerWireProtocol.Version)
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_INVALID", "Broker registration schema or protocol is unsupported.");
        }

        BrokerValueValidation.RequireSafeIdentifier(document.BrokerInstanceId, nameof(document.BrokerInstanceId));
        BrokerValueValidation.RequireSafeIdentifier(document.PersistentSessionId, nameof(document.PersistentSessionId));
        BrokerValueValidation.RequireSha256(document.ExecutableSha256, nameof(document.ExecutableSha256));
        if (!PipeNamePattern.IsMatch(document.PipeName) || document.PipeName is "." or ".." || document.PipeName.Length > 128)
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_INVALID", "Broker registration pipe name is unsafe.");
        }

        if (!BrokerRegistrationStates.IsKnown(document.State) ||
            document.BrokerPid <= 0 ||
            document.McpPid <= 0 ||
            document.PlePid <= 0 ||
            document.WindowsSessionId <= 0 ||
            string.IsNullOrWhiteSpace(document.UserSid) ||
            document.ProcessStartTimeUtc == default ||
            document.IssuedAtUtc == default ||
            document.IssuedAtUtc > document.HeartbeatAtUtc ||
            document.HeartbeatAtUtc > document.ExpiresAtUtc ||
            document.ExpiresAtUtc - document.HeartbeatAtUtc < TimeSpan.FromSeconds(2) ||
            document.ExpiresAtUtc - document.HeartbeatAtUtc > TimeSpan.FromSeconds(30))
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_INVALID", "Broker registration process, state, or heartbeat is invalid.");
        }

        if (!Path.IsPathFullyQualified(document.ExecutablePath) ||
            !Path.IsPathFullyQualified(document.EngineeringRoot) ||
            !Path.IsPathFullyQualified(document.StationRoot) ||
            !Path.IsPathFullyQualified(document.PlcProject))
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_INVALID", "Broker registration paths must be absolute.");
        }

        if (!Path.GetFullPath(paths.RegistrationPath)
                .Equals(Path.GetFullPath(BrokerWireProtocol.GetDefaultRegistrationPath(paths.EngineeringRoot)), StringComparison.OrdinalIgnoreCase) ||
            (requireCurrentProjectIdentity && !MatchesCurrentProjectIdentity(document)))
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_IDENTITY_MISMATCH", "Broker registration project identity or discovery path is inconsistent.");
        }
    }

    private static void ValidatePublishArguments(
        string brokerInstanceId,
        string pipeName,
        int mcpPid,
        int plePid,
        string persistentSessionId,
        string state,
        TimeSpan heartbeatTtl)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        BrokerValueValidation.RequireSafeIdentifier(persistentSessionId, nameof(persistentSessionId));
        if (!PipeNamePattern.IsMatch(pipeName) || pipeName is "." or ".." || pipeName.Length > 128)
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_INVALID", "Broker registration pipe name is unsafe.");
        }

        if (mcpPid <= 0 || plePid <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(mcpPid), "MCP and PLE process IDs must both be positive.");
        }

        ValidateStateAndTtl(state, heartbeatTtl);
    }

    private static void ValidateStateAndTtl(string state, TimeSpan heartbeatTtl)
    {
        if (!BrokerRegistrationStates.IsKnown(state))
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_STATE_INVALID", $"Unsupported Broker state: {state}");
        }

        if (heartbeatTtl < TimeSpan.FromSeconds(2) || heartbeatTtl > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(nameof(heartbeatTtl), "Heartbeat TTL must be from 2 through 30 seconds.");
        }
    }

    private static void EnsureCurrentProcessOwns(BrokerRegistrationDocument document, string brokerInstanceId)
    {
        if (document.BrokerInstanceId != brokerInstanceId)
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_NOT_OWNER", "Registration belongs to another Broker instance.");
        }

        var process = BrokerProcessIdentity.CaptureCurrentInteractive();
        if (!IsOwnedBy(document, brokerInstanceId, process))
        {
            throw new BrokerInfrastructureException("BROKER_REGISTRATION_PROCESS_MISMATCH", "Current process no longer matches the registered Broker identity.");
        }
    }

    private static bool IsOwnedBy(
        BrokerRegistrationDocument document,
        string brokerInstanceId,
        BrokerProcessIdentity process) =>
        document.BrokerInstanceId == brokerInstanceId &&
        document.BrokerPid == process.ProcessId &&
        document.WindowsSessionId == process.WindowsSessionId &&
        document.UserSid == process.UserSid &&
        document.ProcessStartTimeUtc == process.ProcessStartTimeUtc &&
        document.ExecutablePath.Equals(process.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        document.ExecutableSha256.Equals(process.ExecutableSha256, StringComparison.OrdinalIgnoreCase);

    private bool MatchesCurrentProjectIdentity(BrokerRegistrationDocument document) =>
        BrokerRuntimePaths.NormalizePath(document.EngineeringRoot).Equals(paths.EngineeringRoot, StringComparison.OrdinalIgnoreCase) &&
        BrokerRuntimePaths.NormalizePath(document.StationRoot).Equals(paths.StationRoot, StringComparison.OrdinalIgnoreCase) &&
        BrokerRuntimePaths.NormalizePath(document.PlcProject).Equals(paths.PlcProject, StringComparison.OrdinalIgnoreCase) &&
        document.Profile == paths.Profile;

    private T WithRegistrationLock<T>(Func<T> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        using var registrationLock = AcquireRegistrationLock();
        return action();
    }

    private FileStream AcquireRegistrationLock()
    {
        var lockPath = paths.RegistrationPath + ".lock";
        var stopwatch = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                return new FileStream(
                    lockPath,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    bufferSize: 1,
                    FileOptions.WriteThrough);
            }
            catch (IOException) when (stopwatch.Elapsed < RegistrationLockTimeout)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(25));
            }
            catch (IOException exception)
            {
                throw new BrokerInfrastructureException(
                    "BROKER_REGISTRATION_BUSY",
                    "Broker registration is currently being updated by another process.",
                    exception);
            }
        }
    }

    private BrokerRegistration ToCore(BrokerRegistrationDocument document) => new(
        ProtocolVersion: document.ProtocolVersion,
        BrokerInstanceId: document.BrokerInstanceId,
        PipeName: document.PipeName,
        BrokerPid: document.BrokerPid,
        ProcessStartTimeUtc: document.ProcessStartTimeUtc,
        WindowsSessionId: document.WindowsSessionId,
        UserSid: document.UserSid,
        ExecutablePath: document.ExecutablePath,
        ExecutableSha256: document.ExecutableSha256,
        EngineeringRoot: document.EngineeringRoot,
        StationRoot: document.StationRoot,
        PlcProject: document.PlcProject,
        Profile: document.Profile,
        McpPid: document.McpPid,
        PlePid: document.PlePid,
        PersistentSessionId: document.PersistentSessionId,
        State: document.State,
        IssuedAtUtc: document.IssuedAtUtc,
        HeartbeatAtUtc: document.HeartbeatAtUtc,
        ExpiresAtUtc: document.ExpiresAtUtc,
        RegistrationPath: paths.RegistrationPath);

    [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
    private sealed class BrokerRegistrationDocument
    {
        public int SchemaVersion { get; set; } = 1;
        public string Kind { get; set; } = BrokerWireProtocol.RegistrationKind;
        public int ProtocolVersion { get; set; }
        public string BrokerInstanceId { get; set; } = string.Empty;
        public string PipeName { get; set; } = string.Empty;
        public int BrokerPid { get; set; }
        public DateTimeOffset ProcessStartTimeUtc { get; set; }
        public int WindowsSessionId { get; set; }
        public string UserSid { get; set; } = string.Empty;
        public string ExecutablePath { get; set; } = string.Empty;
        public string ExecutableSha256 { get; set; } = string.Empty;
        public string EngineeringRoot { get; set; } = string.Empty;
        public string StationRoot { get; set; } = string.Empty;
        public string PlcProject { get; set; } = string.Empty;
        public string Profile { get; set; } = string.Empty;
        public int McpPid { get; set; }
        public int PlePid { get; set; }
        public string PersistentSessionId { get; set; } = string.Empty;
        public string State { get; set; } = string.Empty;
        public DateTimeOffset IssuedAtUtc { get; set; }
        public DateTimeOffset HeartbeatAtUtc { get; set; }
        public DateTimeOffset ExpiresAtUtc { get; set; }
    }
}
