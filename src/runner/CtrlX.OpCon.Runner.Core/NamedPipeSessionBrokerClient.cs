using System.IO.Pipes;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CtrlX.OpCon.Runner.Core;

/// <summary>
/// Connects to an already-running interactive-session Broker. This transport
/// has no process-lifecycle capability and never falls back to another channel.
/// </summary>
public sealed partial class NamedPipeSessionBrokerClient : ISessionBrokerClient
{
    public const int ProtocolVersion = 1;
    public const int MaximumMessageBytes = 1024 * 1024;

    private const string ExecuteRequestKind = "ctrlx-opcon-runner-broker-execute";
    private const string ExecuteReplyKind = "ctrlx-opcon-runner-broker-reply";
    private const string SessionUnavailable = "BLOCKED_SESSION_UNAVAILABLE";
    private const string ProtocolInvalid = "BLOCKED_SESSION_PROTOCOL_INVALID";
    private const string ProtocolMismatch = "BLOCKED_SESSION_PROTOCOL_MISMATCH";
    private const string SessionUnhealthy = "BLOCKED_SESSION_UNHEALTHY";
    private const string SessionProfileMismatch = "BLOCKED_SESSION_PROFILE_MISMATCH";
    private const string SessionProjectMismatch = "BLOCKED_SESSION_PROJECT_MISMATCH";
    private const string SessionProvenanceInvalid = "BLOCKED_SESSION_PROVENANCE_INVALID";
    private const string BrokerIdentityInvalid = "BLOCKED_BROKER_IDENTITY_INVALID";
    private const string ObservationIdentityMismatch = "BLOCKED_OBSERVATION_IDENTITY_MISMATCH";
    private const string ObservationInvalid = "BLOCKED_OBSERVATION_INVALID";
    private const string ObservationSensitive = "BLOCKED_OBSERVATION_SENSITIVE_FIELD";

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false
    };

    private readonly string pipeName;
    private readonly TimeSpan connectTimeout;
    private readonly TimeSpan responseTimeout;
    private readonly int expectedBrokerPid;

    public NamedPipeSessionBrokerClient(string pipeName, int expectedBrokerPid)
        : this(pipeName, expectedBrokerPid, TimeSpan.FromSeconds(1), TimeSpan.FromMinutes(5))
    {
    }

    public NamedPipeSessionBrokerClient(string pipeName, int expectedBrokerPid, TimeSpan timeout)
        : this(pipeName, expectedBrokerPid, timeout, timeout)
    {
    }

    public NamedPipeSessionBrokerClient(
        string pipeName,
        int expectedBrokerPid,
        TimeSpan connectTimeout,
        TimeSpan responseTimeout)
    {
        if (string.IsNullOrWhiteSpace(pipeName) ||
            pipeName.Length > 128 ||
            !SafePipeNameRegex().IsMatch(pipeName) ||
            pipeName is "." or "..")
        {
            throw new ArgumentException(
                "The Broker pipe name must contain only ASCII letters, digits, dot, underscore, or hyphen.",
                nameof(pipeName));
        }

        if (expectedBrokerPid <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(expectedBrokerPid), "A trusted Broker PID is required.");
        }

        this.connectTimeout = connectTimeout;
        this.responseTimeout = responseTimeout;
        this.expectedBrokerPid = expectedBrokerPid;
        ValidateTimeout(this.connectTimeout, nameof(connectTimeout), TimeSpan.FromMinutes(2));
        ValidateTimeout(this.responseTimeout, nameof(responseTimeout), TimeSpan.FromMinutes(15));
        this.pipeName = pipeName;
    }

    public string TransportName => $"named-pipe:{pipeName}";

    public async Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        cancellationToken.ThrowIfCancellationRequested();

        if (!OperatingSystem.IsWindows())
        {
            return Unavailable(SessionUnavailable);
        }

        try
        {
            await using var pipe = new NamedPipeClientStream(
                serverName: ".",
                pipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous);

            await pipe.ConnectAsync(ToTimeoutMilliseconds(connectTimeout), cancellationToken).ConfigureAwait(false);
            var serverIdentity = GetServerIdentity(pipe);
            using (var currentProcess = Process.GetCurrentProcess())
            {
                if (serverIdentity.ProcessId != expectedBrokerPid ||
                    serverIdentity.WindowsSessionId != currentProcess.SessionId)
                {
                    return Unavailable(BrokerIdentityInvalid);
                }
            }

            using var responseCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            responseCancellation.CancelAfter(responseTimeout);

            var request = CreateRequest(action);
            await WriteBoundedLineAsync(pipe, request, responseCancellation.Token).ConfigureAwait(false);
            var responseBytes = await ReadBoundedLineAsync(pipe, responseCancellation.Token).ConfigureAwait(false);
            return ParseReply(action, responseBytes, serverIdentity);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Unavailable(SessionUnavailable);
        }
        catch (TimeoutException)
        {
            return Unavailable(SessionUnavailable);
        }
        catch (IOException)
        {
            return Unavailable(SessionUnavailable);
        }
        catch (UnauthorizedAccessException)
        {
            return Unavailable(SessionUnavailable);
        }
        catch (BrokerReplyException exception)
        {
            return Unavailable(exception.ReasonCode);
        }
        catch (JsonException)
        {
            return Unavailable(ProtocolInvalid);
        }
        catch (DecoderFallbackException)
        {
            return Unavailable(ProtocolInvalid);
        }
        catch (RunnerGateException exception) when (exception.ReasonCode == "SENSITIVE_FIELD_REJECTED")
        {
            return Unavailable(ObservationSensitive);
        }
        catch (RunnerGateException)
        {
            return Unavailable(ProtocolInvalid);
        }
    }

    private static JsonObject CreateRequest(ValidatedRunnerAction action) => new()
    {
        ["protocolVersion"] = ProtocolVersion,
        ["kind"] = ExecuteRequestKind,
        ["requestId"] = action.ActionId,
        ["action"] = new JsonObject
        {
            ["operationId"] = action.OperationId,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionRequestPath"] = action.ActionPath,
            ["actionRequestSha256"] = action.ActionSha256,
            ["idempotencyKey"] = action.IdempotencyKey
        },
        ["project"] = new JsonObject
        {
            ["engineeringRoot"] = action.EngineeringRoot,
            ["stationRoot"] = action.StationRoot,
            ["plcProject"] = action.PlcProject,
            ["profile"] = action.Profile
        },
        ["guardrails"] = new JsonObject
        {
            ["offlineOnly"] = true,
            ["onlineOperationsAllowed"] = false,
            ["requireExistingPersistentSession"] = true,
            ["prohibitStartPleOrMcp"] = true,
            ["prohibitDirectWatcherIpc"] = true,
            ["requireExactProjectOpen"] = true,
            ["startedByRunnerAllowed"] = false
        }
    };

    private static async Task WriteBoundedLineAsync(
        Stream stream,
        JsonObject request,
        CancellationToken cancellationToken)
    {
        var json = request.ToJsonString(CompactJson);
        if (json.IndexOfAny(['\r', '\n']) >= 0)
        {
            throw new BrokerReplyException(ProtocolInvalid);
        }

        var bytes = StrictUtf8.GetBytes(json);
        if (bytes.Length > MaximumMessageBytes)
        {
            throw new BrokerReplyException(ProtocolInvalid);
        }

        await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(new byte[] { (byte)'\n' }, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadBoundedLineAsync(Stream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[4096];
        using var line = new MemoryStream(capacity: 4096);

        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new BrokerReplyException(ProtocolInvalid);
            }

            var newlineIndex = Array.IndexOf(buffer, (byte)'\n', 0, read);
            var bodyLength = newlineIndex >= 0 ? newlineIndex : read;
            if (line.Length + bodyLength > MaximumMessageBytes)
            {
                throw new BrokerReplyException(ProtocolInvalid);
            }

            line.Write(buffer, 0, bodyLength);
            if (newlineIndex < 0)
            {
                continue;
            }

            for (var index = newlineIndex + 1; index < read; index++)
            {
                if (buffer[index] is not (byte)' ' and not (byte)'\t' and not (byte)'\r')
                {
                    throw new BrokerReplyException(ProtocolInvalid);
                }
            }

            var result = line.ToArray();
            if (result.Length > 0 && result[^1] == (byte)'\r')
            {
                Array.Resize(ref result, result.Length - 1);
            }

            if (result.Length == 0 || Array.IndexOf(result, (byte)'\r') >= 0)
            {
                throw new BrokerReplyException(ProtocolInvalid);
            }

            return result;
        }
    }

    private static BrokerExecutionReply ParseReply(
        ValidatedRunnerAction action,
        byte[] responseBytes,
        PipeServerIdentity serverIdentity)
    {
        _ = StrictUtf8.GetString(responseBytes);
        using (var document = JsonDocument.Parse(responseBytes, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 64
        }))
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object || HasDuplicateProperty(document.RootElement))
            {
                throw new BrokerReplyException(ProtocolInvalid);
            }
        }

        if (JsonNode.Parse(responseBytes, nodeOptions: null, documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            }) is not JsonObject reply)
        {
            throw new BrokerReplyException(ProtocolInvalid);
        }

        RunnerValidation.AssertNoSensitiveFields(reply);
        RunnerValidation.RequireOnly(
            reply,
            "Broker reply",
            "protocolVersion",
            "kind",
            "requestId",
            "available",
            "reasonCode",
            "session",
            "observation");

        if (RunnerValidation.RequiredInt32(reply, "protocolVersion", "Broker reply") != ProtocolVersion ||
            RunnerValidation.RequiredString(reply, "kind", "Broker reply") != ExecuteReplyKind ||
            RunnerValidation.RequiredString(reply, "requestId", "Broker reply") != action.ActionId)
        {
            throw new BrokerReplyException(ProtocolMismatch);
        }

        var reasonCode = RunnerValidation.RequiredString(reply, "reasonCode", "Broker reply");
        if (!RunnerValidation.IsSafeIdentifier(reasonCode, maximumLength: 96))
        {
            throw new BrokerReplyException(ProtocolInvalid);
        }

        var available = RunnerValidation.RequiredBoolean(reply, "available", "Broker reply");
        if (!available)
        {
            if (reply["session"] is not null || reply["observation"] is not null)
            {
                throw new BrokerReplyException(ProtocolInvalid);
            }

            return Unavailable(reasonCode.StartsWith("BLOCKED_", StringComparison.Ordinal)
                ? reasonCode
                : SessionUnavailable);
        }

        if (reply["session"] is not JsonObject sessionNode || reply["observation"] is not JsonObject observation)
        {
            throw new BrokerReplyException(ProtocolInvalid);
        }

        var session = ParseSession(sessionNode);
        if (session.BrokerPid != serverIdentity.ProcessId)
        {
            throw new BrokerReplyException(BrokerIdentityInvalid);
        }

        ValidateSession(action, session);
        ValidateObservation(action, session, observation);

        return new BrokerExecutionReply(
            Available: true,
            ReasonCode: reasonCode,
            Session: session,
            Observation: (JsonObject)observation.DeepClone());
    }

    private static BrokerSessionIdentity ParseSession(JsonObject session)
    {
        RunnerValidation.RequireOnly(
            session,
            "Broker session",
            "protocolVersion",
            "brokerPid",
            "sessionId",
            "plePid",
            "profile",
            "activeProjectPath",
            "state",
            "startedByRunner");

        var identity = new BrokerSessionIdentity(
            ProtocolVersion: RunnerValidation.RequiredInt32(session, "protocolVersion", "Broker session"),
            BrokerPid: RunnerValidation.RequiredInt32(session, "brokerPid", "Broker session"),
            SessionId: RunnerValidation.RequiredString(session, "sessionId", "Broker session"),
            PlePid: RunnerValidation.RequiredInt32(session, "plePid", "Broker session"),
            Profile: RunnerValidation.RequiredString(session, "profile", "Broker session"),
            ActiveProjectPath: RunnerValidation.RequiredString(session, "activeProjectPath", "Broker session"),
            State: RunnerValidation.RequiredString(session, "state", "Broker session"),
            StartedByRunner: RunnerValidation.RequiredBoolean(session, "startedByRunner", "Broker session"));

        if (identity.ProtocolVersion != ProtocolVersion)
        {
            throw new BrokerReplyException(ProtocolMismatch);
        }

        if (identity.BrokerPid <= 0 || identity.PlePid <= 0 ||
            !RunnerValidation.IsSafeIdentifier(identity.SessionId))
        {
            throw new BrokerReplyException(SessionUnhealthy);
        }

        return identity;
    }

    private static void ValidateSession(ValidatedRunnerAction action, BrokerSessionIdentity session)
    {
        if (!session.State.Equals("ready", StringComparison.Ordinal))
        {
            throw new BrokerReplyException(SessionUnhealthy);
        }

        if (session.StartedByRunner)
        {
            throw new BrokerReplyException(SessionProvenanceInvalid);
        }

        if (!session.Profile.Equals(action.Profile, StringComparison.Ordinal))
        {
            throw new BrokerReplyException(SessionProfileMismatch);
        }

        string activeProjectPath;
        try
        {
            activeProjectPath = RunnerValidation.FullPath(session.ActiveProjectPath);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new BrokerReplyException(SessionProjectMismatch);
        }

        if (!activeProjectPath.Equals(action.PlcProject, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerReplyException(SessionProjectMismatch);
        }
    }

    private static void ValidateObservation(
        ValidatedRunnerAction action,
        BrokerSessionIdentity session,
        JsonObject observation)
    {
        try
        {
            RunnerValidation.AssertNoSensitiveFields(observation);
        }
        catch (RunnerGateException exception) when (exception.ReasonCode == "SENSITIVE_FIELD_REJECTED")
        {
            throw new BrokerReplyException(ObservationSensitive);
        }

        RunnerValidation.RequireOnly(
            observation,
            "Broker observation",
            "schemaVersion",
            "operationId",
            "actionId",
            "actionKind",
            "actionRequestSha256",
            "status",
            "completedAtUtc",
            "capabilitiesInvoked",
            "session",
            "guardrails",
            "result");

        var observedHash = RunnerValidation.RequiredString(observation, "actionRequestSha256", "Broker observation");
        if (RunnerValidation.RequiredInt32(observation, "schemaVersion", "Broker observation") != 1 ||
            RunnerValidation.RequiredString(observation, "operationId", "Broker observation") != action.OperationId ||
            RunnerValidation.RequiredString(observation, "actionId", "Broker observation") != action.ActionId ||
            RunnerValidation.RequiredString(observation, "actionKind", "Broker observation") != action.ActionKind ||
            !observedHash.Equals(action.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerReplyException(ObservationIdentityMismatch);
        }

        var status = RunnerValidation.RequiredString(observation, "status", "Broker observation");
        if (status is not ("succeeded" or "blocked" or "failed") ||
            !DateTimeOffset.TryParse(
                RunnerValidation.RequiredString(observation, "completedAtUtc", "Broker observation"),
                out _))
        {
            throw new BrokerReplyException(ObservationInvalid);
        }

        _ = RunnerValidation.RequiredArray(observation, "capabilitiesInvoked", "Broker observation");
        _ = RunnerValidation.RequiredObject(observation, "guardrails", "Broker observation");
        var result = RunnerValidation.RequiredObject(observation, "result", "Broker observation");
        _ = RunnerValidation.RequiredArray(result, "proposedChanges", "Broker observation result");
        _ = RunnerValidation.RequiredArray(result, "appliedChanges", "Broker observation result");

        if (status == "succeeded")
        {
            if (observation["session"] is not JsonObject observedSession)
            {
                throw new BrokerReplyException(ObservationInvalid);
            }

            ValidateObservedSession(session, observedSession);
        }
        else if (observation.ContainsKey("session"))
        {
            throw new BrokerReplyException(ObservationInvalid);
        }
    }

    private static void ValidateObservedSession(BrokerSessionIdentity expected, JsonObject observed)
    {
        RunnerValidation.RequireOnly(
            observed,
            "Broker observation session",
            "state",
            "mode",
            "sessionId",
            "plePid",
            "profile",
            "activeProjectPath",
            "startedByRunner");

        string observedProject;
        try
        {
            observedProject = RunnerValidation.FullPath(
                RunnerValidation.RequiredString(observed, "activeProjectPath", "Broker observation session"));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new BrokerReplyException(ObservationInvalid);
        }

        if (RunnerValidation.RequiredString(observed, "state", "Broker observation session") != "ready" ||
            RunnerValidation.RequiredString(observed, "mode", "Broker observation session") != "persistent" ||
            RunnerValidation.RequiredString(observed, "sessionId", "Broker observation session") != expected.SessionId ||
            RunnerValidation.RequiredInt32(observed, "plePid", "Broker observation session") != expected.PlePid ||
            RunnerValidation.RequiredString(observed, "profile", "Broker observation session") != expected.Profile ||
            !observedProject.Equals(RunnerValidation.FullPath(expected.ActiveProjectPath), StringComparison.OrdinalIgnoreCase) ||
            RunnerValidation.RequiredBoolean(observed, "startedByRunner", "Broker observation session"))
        {
            throw new BrokerReplyException(ObservationInvalid);
        }
    }

    private static bool HasDuplicateProperty(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name) || HasDuplicateProperty(property.Value))
                {
                    return true;
                }
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in element.EnumerateArray())
            {
                if (HasDuplicateProperty(child))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static BrokerExecutionReply Unavailable(string reasonCode) => new(
        Available: false,
        ReasonCode: RunnerValidation.IsSafeIdentifier(reasonCode, maximumLength: 96)
            ? reasonCode
            : ProtocolInvalid,
        Session: null,
        Observation: null);

    private static int ToTimeoutMilliseconds(TimeSpan timeout) =>
        checked((int)Math.Ceiling(timeout.TotalMilliseconds));

    private static PipeServerIdentity GetServerIdentity(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var processId) ||
            !GetNamedPipeServerSessionId(pipe.SafePipeHandle, out var sessionId) ||
            processId == 0 || processId > int.MaxValue || sessionId > int.MaxValue)
        {
            throw new BrokerReplyException(BrokerIdentityInvalid);
        }

        return new PipeServerIdentity((int)processId, (int)sessionId);
    }

    private static void ValidateTimeout(TimeSpan value, string parameterName, TimeSpan maximum)
    {
        if (value <= TimeSpan.Zero || value > maximum)
        {
            throw new ArgumentOutOfRangeException(parameterName, $"Timeout must be greater than zero and no more than {maximum}.");
        }
    }

    [GeneratedRegex("^[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex SafePipeNameRegex();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerSessionId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint serverSessionId);

    private sealed record PipeServerIdentity(int ProcessId, int WindowsSessionId);

    private sealed class BrokerReplyException : Exception
    {
        public BrokerReplyException(string reasonCode)
            : base(reasonCode)
        {
            ReasonCode = reasonCode;
        }

        public string ReasonCode { get; }
    }
}
