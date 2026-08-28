using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CtrlX.OpCon.Runner.Core;

public static class RunnerExitCodes
{
    public const int Done = 0;
    public const int Busy = 20;
    public const int Blocked = 40;
    public const int GateFailure = 50;
    public const int Usage = 64;
    public const int InternalError = 70;
}

public static class RunnerStates
{
    public const string Received = "RECEIVED";
    public const string ActionValidated = "ACTION_VALIDATED";
    public const string ActionLeased = "ACTION_LEASED";
    public const string SessionProbed = "SESSION_PROBED";
    public const string Executing = "EXECUTING";
    public const string ObservationWritten = "OBSERVATION_WRITTEN";
    public const string Sealing = "SEALING";
    public const string Done = "DONE";
    public const string Blocked = "BLOCKED";
    public const string Failed = "FAILED";
    public const string Unknown = "UNKNOWN";

    public static bool IsTerminal(string? value) =>
        value is Done or Blocked or Failed or Unknown;
}

public sealed class RunnerGateException : Exception
{
    public RunnerGateException(
        string reasonCode,
        string message,
        int exitCode = RunnerExitCodes.GateFailure,
        string? diagnosticReasonCode = null)
        : base(message)
    {
        ReasonCode = reasonCode;
        ExitCode = exitCode;
        DiagnosticReasonCode = diagnosticReasonCode;
    }

    public string ReasonCode { get; }

    public int ExitCode { get; }

    /// <summary>
    /// Optional safe reason from the lower transport/session layer. The primary
    /// ReasonCode still controls pending-versus-terminal behavior; this value is
    /// only surfaced so a Host does not hide why a session is unavailable.
    /// </summary>
    public string? DiagnosticReasonCode { get; }
}

public sealed record ValidatedRunnerAction(
    string EngineeringRoot,
    string StationRoot,
    string PlcProject,
    string Profile,
    string ActionPath,
    string ActionSha256,
    string OperationId,
    string ActionId,
    string ActionKind,
    int Sequence,
    DateTimeOffset CreatedAtUtc,
    string IdempotencyKey,
    bool IsSupported,
    string? UnsupportedReasonCode,
    JsonObject Document);

public sealed record RunnerExecutionRequest(
    string EngineeringRoot,
    string ActionPath,
    string ExpectedActionSha256,
    TimeSpan LeaseTimeout,
    RunnerSessionUnavailableBehavior SessionUnavailableBehavior = RunnerSessionUnavailableBehavior.Block);

public enum RunnerSessionUnavailableBehavior
{
    Block = 0,
    KeepPending = 1
}

public sealed record RunnerExecutionResult(
    string RunId,
    string State,
    string ReasonCode,
    int ExitCode,
    string ResultPath,
    string? ObservationPath,
    string? EvidencePath,
    bool Replayed)
{
    public JsonObject ToJson() => new()
    {
        ["schemaVersion"] = 1,
        ["kind"] = "ctrlx-opcon-runner-cli-result",
        ["runId"] = RunId,
        ["state"] = State,
        ["reasonCode"] = ReasonCode,
        ["exitCode"] = ExitCode,
        ["resultPath"] = ResultPath,
        ["observationPath"] = ObservationPath,
        ["evidencePath"] = EvidencePath,
        ["replayed"] = Replayed
    };
}

public sealed record BrokerSessionIdentity(
    int ProtocolVersion,
    int BrokerPid,
    string SessionId,
    int McpPid,
    int PlePid,
    string Profile,
    string ActiveProjectPath,
    string State,
    bool PleOwnedByBroker);

public sealed record BrokerExecutionReply(
    bool Available,
    string ReasonCode,
    BrokerSessionIdentity? Session,
    JsonObject? Observation)
{
    /// <summary>
    /// True only after the Broker has durably accepted the immutable action.
    /// Once accepted, a client timeout is not equivalent to "not executed".
    /// </summary>
    public bool Accepted { get; init; }

    /// <summary>
    /// True when the Broker returned a durable terminal outcome. Successful,
    /// blocked, and failed outcomes carry an observation. A terminal outcome
    /// that cannot safely claim what happened in PLE sets ReviewRequired and
    /// deliberately omits session/observation evidence.
    /// </summary>
    public bool Terminal { get; init; }

    /// <summary>
    /// True only for a durable terminal outcome which must be sealed locally as
    /// UNKNOWN without replaying the engineering call.
    /// </summary>
    public bool ReviewRequired { get; init; }

    public string? ExecutionId { get; init; }
}

public interface ISessionBrokerClient
{
    string TransportName { get; }

    Task<BrokerExecutionReply> ExecuteAsync(ValidatedRunnerAction action, CancellationToken cancellationToken);
}

public sealed class NoSessionBrokerClient : ISessionBrokerClient
{
    public string TransportName => "none";

    public Task<BrokerExecutionReply> ExecuteAsync(ValidatedRunnerAction action, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new BrokerExecutionReply(
            Available: false,
            ReasonCode: "BLOCKED_SESSION_UNAVAILABLE",
            Session: null,
            Observation: null)
        {
            Accepted = false,
            Terminal = false
        });
    }
}

public sealed record EvidenceSealResult(string Path, string Sha256, string ProducerStatus);

public interface IEvidenceSealer
{
    Task<EvidenceSealResult> SealAsync(
        ValidatedRunnerAction action,
        string observationPath,
        CancellationToken cancellationToken);
}

public static class RunnerHash
{
    public static string Sha256File(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    public static string Sha256Text(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}

internal static partial class RunnerValidation
{
    private static readonly Regex SafeId = SafeIdentifierRegex();
    private static readonly Regex Sha256 = Sha256Regex();
    private static readonly Regex SensitiveName = SensitiveNameRegex();

    public static bool IsSafeIdentifier(string value, int maximumLength = 128) =>
        value.Length <= maximumLength && SafeId.IsMatch(value) && value is not "." and not "..";

    public static bool IsSha256(string value) => Sha256.IsMatch(value);

    public static string FullPath(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    public static string EnsureInside(string root, string candidate, string description)
    {
        var resolvedRoot = FullPath(root);
        var resolvedCandidate = Path.GetFullPath(candidate);
        var prefix = resolvedRoot + Path.DirectorySeparatorChar;
        if (!resolvedCandidate.Equals(resolvedRoot, StringComparison.OrdinalIgnoreCase) &&
            !resolvedCandidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("PATH_ESCAPE", $"{description} escaped its configured root: {resolvedCandidate}");
        }

        return resolvedCandidate;
    }

    public static string AssertExistingPathChainNotReparse(
        string trustedRoot,
        string candidate,
        string reasonCode,
        string description)
    {
        var root = FullPath(trustedRoot);
        var resolved = EnsureInside(root, candidate, description);
        var current = root;
        AssertExistingNodeNotReparse(current, reasonCode, description);
        var relative = Path.GetRelativePath(root, resolved);
        if (relative == ".")
        {
            return resolved;
        }

        foreach (var segment in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            AssertExistingNodeNotReparse(current, reasonCode, description);
        }

        return resolved;
    }

    private static void AssertExistingNodeNotReparse(
        string path,
        string reasonCode,
        string description)
    {
        if ((File.Exists(path) || Directory.Exists(path)) &&
            (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException(
                reasonCode,
                $"{description} must not contain a junction or symbolic link: {path}");
        }
    }

    public static void AssertNoSensitiveFields(JsonNode? value, string path = "$")
    {
        if (value is JsonObject obj)
        {
            foreach (var property in obj)
            {
                if (SensitiveName.IsMatch(property.Key))
                {
                    throw new RunnerGateException("SENSITIVE_FIELD_REJECTED", $"Prohibited secret-bearing field: {path}.{property.Key}");
                }

                AssertNoSensitiveFields(property.Value, path + "." + property.Key);
            }
        }
        else if (value is JsonArray array)
        {
            for (var index = 0; index < array.Count; index++)
            {
                AssertNoSensitiveFields(array[index], $"{path}[{index}]");
            }
        }
    }

    public static void RequireOnly(JsonObject obj, string context, params string[] allowed)
    {
        var set = new HashSet<string>(allowed, StringComparer.Ordinal);
        foreach (var key in obj.Select(item => item.Key))
        {
            if (!set.Contains(key))
            {
                throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context} contains unsupported property '{key}'.");
            }
        }
    }

    public static string RequiredString(JsonObject obj, string name, string context)
    {
        if (!obj.TryGetPropertyValue(name, out var node) || node is null)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context} is missing '{name}'.");
        }

        string? value;
        try
        {
            value = node.GetValue<string>();
        }
        catch (InvalidOperationException)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be a string.");
        }

        if (string.IsNullOrWhiteSpace(value))
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be non-empty.");
        }

        return value;
    }

    public static bool RequiredBoolean(JsonObject obj, string name, string context)
    {
        if (!obj.TryGetPropertyValue(name, out var node) || node is null)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context} is missing Boolean '{name}'.");
        }

        try
        {
            return node.GetValue<bool>();
        }
        catch (InvalidOperationException)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be Boolean.");
        }
    }

    public static int RequiredInt32(JsonObject obj, string name, string context)
    {
        if (!obj.TryGetPropertyValue(name, out var node) || node is null)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context} is missing integer '{name}'.");
        }

        try
        {
            return node.GetValue<int>();
        }
        catch (InvalidOperationException)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be an integer.");
        }
    }

    public static JsonObject RequiredObject(JsonObject obj, string name, string context)
    {
        if (obj[name] is not JsonObject child)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be an object.");
        }

        return child;
    }

    public static JsonArray RequiredArray(JsonObject obj, string name, string context)
    {
        if (obj[name] is not JsonArray child)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{context}.{name} must be an array.");
        }

        return child;
    }

    [GeneratedRegex("^[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex SafeIdentifierRegex();

    [GeneratedRegex("^[A-Fa-f0-9]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex Sha256Regex();

    [GeneratedRegex("(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SensitiveNameRegex();
}

internal static class RunnerJson
{
    public static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static JsonObject ReadObject(string path, string description)
    {
        if (!File.Exists(path))
        {
            throw new RunnerGateException("FILE_NOT_FOUND", $"{description} does not exist: {path}");
        }

        try
        {
            var bytes = File.ReadAllBytes(path);
            var node = JsonNode.Parse(bytes, nodeOptions: null, documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            });
            return node as JsonObject ?? throw new JsonException("Root must be an object.");
        }
        catch (Exception exception) when (exception is JsonException or DecoderFallbackException)
        {
            throw new RunnerGateException("JSON_INVALID", $"{description} is not valid strict JSON: {path}. {exception.Message}");
        }
    }

    public static void WriteAtomic(string path, JsonNode value, bool overwrite)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        var bytes = Encoding.UTF8.GetBytes(value.ToJsonString(SerializerOptions) + Environment.NewLine);
        try
        {
            File.WriteAllBytes(temporary, bytes);
            if (File.Exists(path))
            {
                if (!overwrite)
                {
                    throw new RunnerGateException("IMMUTABLE_FILE_EXISTS", $"Immutable file already exists: {path}");
                }

                File.Move(temporary, path, overwrite: true);
            }
            else
            {
                File.Move(temporary, path);
            }
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }
}
