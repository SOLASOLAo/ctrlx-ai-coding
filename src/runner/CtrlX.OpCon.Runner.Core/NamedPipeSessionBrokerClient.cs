using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

/// <summary>
/// Uses current-user validated Broker registration and protocol v2 durable
/// submit/query semantics. This client has no process-lifecycle capability.
/// </summary>
public sealed class NamedPipeSessionBrokerClient : ISessionBrokerClient
{
    public const int ProtocolVersion = BrokerWireProtocol.Version;
    public const int MaximumMessageBytes = BrokerWireProtocol.MaximumMessageBytes;

    private const string SessionUnavailable = "BLOCKED_SESSION_UNAVAILABLE";
    private const string ProtocolInvalid = "BLOCKED_SESSION_PROTOCOL_INVALID";
    private const string ProtocolMismatch = "BLOCKED_SESSION_PROTOCOL_MISMATCH";
    private const string BrokerIdentityInvalid = "BLOCKED_BROKER_IDENTITY_INVALID";
    private const string ExecutionPending = "EXECUTION_CONTINUES_IN_BROKER";

    private readonly string engineeringRoot;
    private readonly string? registrationPath;
    private readonly TimeSpan connectTimeout;
    private readonly TimeSpan responseTimeout;
    private readonly TimeSpan pollInterval;

    public NamedPipeSessionBrokerClient(string engineeringRoot)
        : this(engineeringRoot, null, TimeSpan.FromSeconds(2), TimeSpan.FromMinutes(30), TimeSpan.FromMilliseconds(250))
    {
    }

    public NamedPipeSessionBrokerClient(
        string engineeringRoot,
        string? registrationPath,
        TimeSpan connectTimeout,
        TimeSpan responseTimeout,
        TimeSpan? pollInterval = null)
    {
        this.engineeringRoot = RunnerValidation.FullPath(engineeringRoot);
        this.registrationPath = registrationPath;
        this.connectTimeout = RequireTimeout(connectTimeout, nameof(connectTimeout), TimeSpan.FromMinutes(2));
        this.responseTimeout = RequireTimeout(responseTimeout, nameof(responseTimeout), TimeSpan.FromMinutes(60));
        this.pollInterval = RequireTimeout(
            pollInterval ?? TimeSpan.FromMilliseconds(250),
            nameof(pollInterval),
            TimeSpan.FromSeconds(10));
    }

    public string TransportName => "registered-named-pipe:v2";

    public async Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        cancellationToken.ThrowIfCancellationRequested();
        if (!action.EngineeringRoot.Equals(engineeringRoot, StringComparison.OrdinalIgnoreCase))
        {
            return Unavailable("BLOCKED_BROKER_REGISTRATION_PROJECT_MISMATCH");
        }

        BrokerRegistration registration;
        try
        {
            registration = BrokerRegistrationReader.ReadValidated(engineeringRoot, registrationPath);
            ValidateRegistrationForAction(registration, action);
        }
        catch (RunnerGateException exception)
        {
            return Unavailable(SafeReason(exception.ReasonCode, BrokerIdentityInvalid));
        }

        var clientNonce = Guid.NewGuid().ToString("N");
        SubmitReceipt receipt;
        try
        {
            var reply = await ExchangeAsync(
                registration,
                CreateSubmit(action, registration, clientNonce),
                cancellationToken).ConfigureAwait(false);
            receipt = ParseSubmitReply(action, registration, clientNonce, reply);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception) when (IsTransportOrProtocolFailure(exception))
        {
            return Unavailable(ReasonFor(exception));
        }

        if (!receipt.Accepted)
        {
            return Unavailable(receipt.ReasonCode);
        }

        var deadline = DateTimeOffset.UtcNow + responseTimeout;
        while (true)
        {
            if (cancellationToken.IsCancellationRequested || DateTimeOffset.UtcNow >= deadline)
            {
                return Pending(receipt.ExecutionId, ExecutionPending);
            }

            try
            {
                registration = BrokerRegistrationReader.ReadValidated(engineeringRoot, registrationPath);
                ValidateRegistrationForAction(registration, action);
                var queryNonce = Guid.NewGuid().ToString("N");
                using var queryCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                var remaining = deadline - DateTimeOffset.UtcNow;
                queryCancellation.CancelAfter(remaining < connectTimeout + TimeSpan.FromSeconds(5)
                    ? remaining
                    : connectTimeout + TimeSpan.FromSeconds(5));
                var reply = await ExchangeAsync(
                    registration,
                    CreateQuery(action, registration, queryNonce, receipt.ExecutionId),
                    queryCancellation.Token).ConfigureAwait(false);
                var current = ParseQueryReply(
                    action,
                    registration,
                    queryNonce,
                    receipt.ExecutionId,
                    reply);
                if (current.Terminal)
                {
                    return current;
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                // A durable receipt already exists. Query timeout is not proof that
                // the engineering operation did not run.
            }
            catch (Exception exception) when (IsTransportOrProtocolFailure(exception))
            {
                if (exception is RunnerGateException gate &&
                    gate.ReasonCode is ProtocolInvalid or ProtocolMismatch)
                {
                    return Pending(receipt.ExecutionId, gate.ReasonCode);
                }
            }

            try
            {
                await Task.Delay(pollInterval, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return Pending(receipt.ExecutionId, ExecutionPending);
            }
        }
    }

    private async Task<JsonObject> ExchangeAsync(
        BrokerRegistration registration,
        JsonObject request,
        CancellationToken cancellationToken)
    {
        await using var pipe = new NamedPipeClientStream(
            ".",
            registration.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await pipe.ConnectAsync(ToMilliseconds(connectTimeout), cancellationToken).ConfigureAwait(false);
        var identity = GetServerIdentity(pipe);
        using var current = Process.GetCurrentProcess();
        if (identity.ProcessId != registration.BrokerPid ||
            identity.WindowsSessionId != registration.WindowsSessionId ||
            identity.WindowsSessionId != current.SessionId)
        {
            throw new RunnerGateException(BrokerIdentityInvalid, "Named Pipe server identity does not match the validated Broker registration.");
        }

        await BrokerPipeCodec.WriteAsync(pipe, request, cancellationToken).ConfigureAwait(false);
        return await BrokerPipeCodec.ReadAsync(pipe, cancellationToken).ConfigureAwait(false);
    }

    private static JsonObject CreateSubmit(
        ValidatedRunnerAction action,
        BrokerRegistration registration,
        string nonce) => new()
    {
        ["protocolVersion"] = ProtocolVersion,
        ["kind"] = BrokerWireProtocol.SubmitKind,
        ["requestId"] = action.ActionId,
        ["brokerInstanceId"] = registration.BrokerInstanceId,
        ["clientNonce"] = nonce,
        ["action"] = BrokerWireProtocol.ActionIdentity(action),
        ["project"] = BrokerWireProtocol.ProjectIdentity(action),
        ["guardrails"] = BrokerWireProtocol.OfflineGuardrails()
    };

    private static JsonObject CreateQuery(
        ValidatedRunnerAction action,
        BrokerRegistration registration,
        string nonce,
        string executionId) => new()
    {
        ["protocolVersion"] = ProtocolVersion,
        ["kind"] = BrokerWireProtocol.QueryKind,
        ["requestId"] = action.ActionId,
        ["brokerInstanceId"] = registration.BrokerInstanceId,
        ["clientNonce"] = nonce,
        ["executionId"] = executionId,
        ["actionId"] = action.ActionId,
        ["actionRequestSha256"] = action.ActionSha256,
        ["idempotencyKey"] = action.IdempotencyKey
    };

    private static SubmitReceipt ParseSubmitReply(
        ValidatedRunnerAction action,
        BrokerRegistration registration,
        string nonce,
        JsonObject reply)
    {
        RunnerValidation.AssertNoSensitiveFields(reply);
        RunnerValidation.RequireOnly(
            reply,
            "Broker submit reply",
            "protocolVersion",
            "kind",
            "requestId",
            "brokerInstanceId",
            "clientNonce",
            "accepted",
            "reasonCode",
            "executionId",
            "disposition",
            "state");
        ValidateReplyEnvelope(reply, BrokerWireProtocol.SubmitReplyKind, action, registration, nonce);
        var accepted = RunnerValidation.RequiredBoolean(reply, "accepted", "Broker submit reply");
        var reason = SafeReason(RunnerValidation.RequiredString(reply, "reasonCode", "Broker submit reply"), ProtocolInvalid);
        var executionId = RunnerValidation.RequiredString(reply, "executionId", "Broker submit reply");
        var disposition = RunnerValidation.RequiredString(reply, "disposition", "Broker submit reply");
        var state = RunnerValidation.RequiredString(reply, "state", "Broker submit reply");
        if (!RunnerValidation.IsSafeIdentifier(executionId) ||
            disposition is not ("ACCEPTED" or "REPLAYED" or "REJECTED") ||
            !RunnerValidation.IsSafeIdentifier(state, 64) ||
            (accepted && disposition == "REJECTED") ||
            (!accepted && disposition != "REJECTED"))
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker submit receipt is malformed.");
        }

        return new SubmitReceipt(accepted, reason, executionId);
    }

    private static BrokerExecutionReply ParseQueryReply(
        ValidatedRunnerAction action,
        BrokerRegistration registration,
        string nonce,
        string executionId,
        JsonObject reply)
    {
        RunnerValidation.AssertNoSensitiveFields(reply);
        RunnerValidation.RequireOnly(
            reply,
            "Broker query reply",
            "protocolVersion",
            "kind",
            "requestId",
            "brokerInstanceId",
            "clientNonce",
            "executionId",
            "terminal",
            "reasonCode",
            "state",
            "reviewRequired",
            "session",
            "observation");
        ValidateReplyEnvelope(reply, BrokerWireProtocol.QueryReplyKind, action, registration, nonce);
        if (RunnerValidation.RequiredString(reply, "executionId", "Broker query reply") != executionId)
        {
            throw new RunnerGateException(ProtocolMismatch, "Broker query execution identity changed.");
        }

        var terminal = RunnerValidation.RequiredBoolean(reply, "terminal", "Broker query reply");
        var reviewRequired = RunnerValidation.RequiredBoolean(reply, "reviewRequired", "Broker query reply");
        var reason = SafeReason(RunnerValidation.RequiredString(reply, "reasonCode", "Broker query reply"), ProtocolInvalid);
        var state = RunnerValidation.RequiredString(reply, "state", "Broker query reply");
        if (!RunnerValidation.IsSafeIdentifier(state, 64))
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker query state is malformed.");
        }

        if (!terminal)
        {
            if (reviewRequired || reply["session"] is not null || reply["observation"] is not null)
            {
                throw new RunnerGateException(ProtocolInvalid, "A non-terminal Broker reply cannot contain terminal evidence.");
            }

            return Pending(executionId, reason);
        }

        if (reviewRequired)
        {
            if (state is not ("UNKNOWN_REVIEW_REQUIRED" or "CANCELED") ||
                reply["session"] is not null ||
                reply["observation"] is not null)
            {
                throw new RunnerGateException(ProtocolInvalid, "Terminal review outcome contains an invalid state or fabricated evidence.");
            }

            return new BrokerExecutionReply(true, reason, Session: null, Observation: null)
            {
                Accepted = true,
                Terminal = true,
                ReviewRequired = true,
                ExecutionId = executionId
            };
        }

        if (reply["session"] is not JsonObject sessionNode || reply["observation"] is not JsonObject observation)
        {
            throw new RunnerGateException(ProtocolInvalid, "Terminal Broker reply is missing session or observation.");
        }

        var session = ParseSession(sessionNode, registration);
        ValidateSession(action, session);
        ValidateObservation(action, session, observation);
        return new BrokerExecutionReply(true, reason, session, (JsonObject)observation.DeepClone())
        {
            Accepted = true,
            Terminal = true,
            ReviewRequired = false,
            ExecutionId = executionId
        };
    }

    private static void ValidateReplyEnvelope(
        JsonObject reply,
        string expectedKind,
        ValidatedRunnerAction action,
        BrokerRegistration registration,
        string nonce)
    {
        if (RunnerValidation.RequiredInt32(reply, "protocolVersion", "Broker reply") != ProtocolVersion ||
            RunnerValidation.RequiredString(reply, "kind", "Broker reply") != expectedKind ||
            RunnerValidation.RequiredString(reply, "requestId", "Broker reply") != action.ActionId ||
            RunnerValidation.RequiredString(reply, "brokerInstanceId", "Broker reply") != registration.BrokerInstanceId ||
            RunnerValidation.RequiredString(reply, "clientNonce", "Broker reply") != nonce)
        {
            throw new RunnerGateException(ProtocolMismatch, "Broker reply envelope does not match the request.");
        }
    }

    private static BrokerSessionIdentity ParseSession(JsonObject node, BrokerRegistration registration)
    {
        RunnerValidation.RequireOnly(
            node,
            "Broker session",
            "protocolVersion",
            "brokerPid",
            "sessionId",
            "mcpPid",
            "plePid",
            "profile",
            "activeProjectPath",
            "state",
            "pleOwnedByBroker");
        var session = new BrokerSessionIdentity(
            RunnerValidation.RequiredInt32(node, "protocolVersion", "Broker session"),
            RunnerValidation.RequiredInt32(node, "brokerPid", "Broker session"),
            RunnerValidation.RequiredString(node, "sessionId", "Broker session"),
            RunnerValidation.RequiredInt32(node, "mcpPid", "Broker session"),
            RunnerValidation.RequiredInt32(node, "plePid", "Broker session"),
            RunnerValidation.RequiredString(node, "profile", "Broker session"),
            RunnerValidation.RequiredString(node, "activeProjectPath", "Broker session"),
            RunnerValidation.RequiredString(node, "state", "Broker session"),
            RunnerValidation.RequiredBoolean(node, "pleOwnedByBroker", "Broker session"));
        if (session.ProtocolVersion != ProtocolVersion ||
            session.BrokerPid != registration.BrokerPid ||
            session.McpPid != registration.McpPid ||
            session.PlePid != registration.PlePid ||
            session.SessionId != registration.PersistentSessionId)
        {
            throw new RunnerGateException(BrokerIdentityInvalid, "Broker terminal session does not match registration.");
        }

        return session;
    }

    private static void ValidateSession(ValidatedRunnerAction action, BrokerSessionIdentity session)
    {
        if (session.State != "ready" || session.McpPid <= 0 || session.PlePid <= 0 ||
            !RunnerValidation.IsSafeIdentifier(session.SessionId) || session.Profile != action.Profile ||
            !RunnerValidation.FullPath(session.ActiveProjectPath).Equals(action.PlcProject, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("BLOCKED_SESSION_MISMATCH", "Broker session does not match the immutable action.");
        }
    }

    private static void ValidateObservation(
        ValidatedRunnerAction action,
        BrokerSessionIdentity session,
        JsonObject observation)
    {
        RunnerValidation.AssertNoSensitiveFields(observation);
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
        if (RunnerValidation.RequiredInt32(observation, "schemaVersion", "Broker observation") != 1 ||
            RunnerValidation.RequiredString(observation, "operationId", "Broker observation") != action.OperationId ||
            RunnerValidation.RequiredString(observation, "actionId", "Broker observation") != action.ActionId ||
            RunnerValidation.RequiredString(observation, "actionKind", "Broker observation") != action.ActionKind ||
            !RunnerValidation.RequiredString(observation, "actionRequestSha256", "Broker observation")
                .Equals(action.ActionSha256, StringComparison.OrdinalIgnoreCase) ||
            !DateTimeOffset.TryParse(RunnerValidation.RequiredString(observation, "completedAtUtc", "Broker observation"), out _))
        {
            throw new RunnerGateException("BLOCKED_OBSERVATION_IDENTITY_MISMATCH", "Broker observation identity is invalid.");
        }

        var status = RunnerValidation.RequiredString(observation, "status", "Broker observation");
        if (status is not ("succeeded" or "blocked" or "failed"))
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker observation status is invalid.");
        }

        ValidateCapabilities(observation, status == "succeeded");
        ValidateGuardrails(RunnerValidation.RequiredObject(observation, "guardrails", "Broker observation"));
        var result = RunnerValidation.RequiredObject(observation, "result", "Broker observation");
        _ = RunnerValidation.RequiredArray(result, "proposedChanges", "Broker observation result");
        _ = RunnerValidation.RequiredArray(result, "appliedChanges", "Broker observation result");
        if (status == "succeeded")
        {
            if (observation["session"] is not JsonObject observedSession)
            {
                throw new RunnerGateException(ProtocolInvalid, "Successful Broker observation has no session.");
            }

            ValidateObservedSession(session, observedSession);
            ValidateSuccessfulResult(result);
        }
        else if (observation["session"] is not null)
        {
            throw new RunnerGateException(ProtocolInvalid, "Non-success observation must not claim a successful session.");
        }
    }

    private static void ValidateCapabilities(JsonObject observation, bool success)
    {
        var capabilities = RunnerValidation.RequiredArray(observation, "capabilitiesInvoked", "Broker observation");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var allowed = new HashSet<string>(new[]
        {
            "get_codesys_status",
            "clean_compile_project",
            "get_ctrlx_semantic_snapshot"
        }, StringComparer.Ordinal);
        foreach (var node in capabilities)
        {
            string value;
            try
            {
                value = node?.GetValue<string>() ?? string.Empty;
            }
            catch (InvalidOperationException)
            {
                throw new RunnerGateException(ProtocolInvalid, "Broker capability identifier is not a string.");
            }

            if (!allowed.Contains(value) || !seen.Add(value))
            {
                throw new RunnerGateException(ProtocolInvalid, "Broker reported a prohibited or duplicate capability.");
            }
        }

        if (success && !seen.SetEquals(allowed))
        {
            throw new RunnerGateException(ProtocolInvalid, "Successful Broker observation lacks the fixed capability sequence.");
        }
    }

    private static void ValidateGuardrails(JsonObject guardrails)
    {
        RunnerValidation.RequireOnly(
            guardrails,
            "Broker observation guardrails",
            "onlineOperationsUsed",
            "secondPleStarted",
            "actionProjectGateAcquired",
            "actionProjectGateReleased",
            "actionProjectGateKind",
            "symbolLeaseHeld",
            "pleOrMcpStartedByAction",
            "directWatcherIpcUsed");
        if (RunnerValidation.RequiredBoolean(guardrails, "onlineOperationsUsed", "Broker observation guardrails") ||
            RunnerValidation.RequiredBoolean(guardrails, "secondPleStarted", "Broker observation guardrails") ||
            RunnerValidation.RequiredBoolean(guardrails, "symbolLeaseHeld", "Broker observation guardrails") ||
            RunnerValidation.RequiredBoolean(guardrails, "pleOrMcpStartedByAction", "Broker observation guardrails") ||
            RunnerValidation.RequiredBoolean(guardrails, "directWatcherIpcUsed", "Broker observation guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "actionProjectGateAcquired", "Broker observation guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "actionProjectGateReleased", "Broker observation guardrails") ||
            RunnerValidation.RequiredString(guardrails, "actionProjectGateKind", "Broker observation guardrails") !=
                "broker-session-action-serialization")
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker observation violates offline/action-gate guardrails.");
        }
    }

    private static void ValidateSuccessfulResult(JsonObject result)
    {
        foreach (var name in new[]
        {
            "verificationOk",
            "appliedReadbackOk",
            "repairRequired",
            "requiresSecondExport",
            "requiresCpStudioChange"
        })
        {
            _ = RunnerValidation.RequiredBoolean(result, name, "Broker observation result");
        }

        if (!RunnerValidation.RequiredBoolean(result, "verificationOk", "Broker observation result") ||
            !RunnerValidation.RequiredBoolean(result, "appliedReadbackOk", "Broker observation result") ||
            RunnerValidation.RequiredBoolean(result, "repairRequired", "Broker observation result") ||
            RunnerValidation.RequiredBoolean(result, "requiresSecondExport", "Broker observation result") ||
            RunnerValidation.RequiredBoolean(result, "requiresCpStudioChange", "Broker observation result") ||
            result["build"] is not JsonObject ||
            result["acceptance"] is not JsonObject acceptance ||
            result["semanticProofs"] is not JsonObject semanticProofs)
        {
            throw new RunnerGateException(ProtocolInvalid, "Successful Broker observation lacks complete Build/semantic evidence.");
        }

        RunnerValidation.RequireOnly(
            acceptance,
            "Broker semantic acceptance",
            "ownershipVerified",
            "mappingConsistent",
            "readbackVerified",
            "recoverableBaselineVerified",
            "warningSignaturesReviewed",
            "existingSessionReused",
            "pleOrMcpStartedByAction",
            "directWatcherIpcUsed",
            "symbolPostProcessingVerified");
        foreach (var name in new[]
        {
            "ownershipVerified",
            "mappingConsistent",
            "readbackVerified",
            "recoverableBaselineVerified",
            "warningSignaturesReviewed",
            "existingSessionReused",
            "symbolPostProcessingVerified"
        })
        {
            if (!RunnerValidation.RequiredBoolean(acceptance, name, "Broker semantic acceptance"))
            {
                throw new RunnerGateException(ProtocolInvalid, $"Successful Broker observation has false acceptance proof '{name}'.");
            }
        }

        if (RunnerValidation.RequiredBoolean(acceptance, "pleOrMcpStartedByAction", "Broker semantic acceptance") ||
            RunnerValidation.RequiredBoolean(acceptance, "directWatcherIpcUsed", "Broker semantic acceptance"))
        {
            throw new RunnerGateException(ProtocolInvalid, "Successful Broker observation violates semantic acceptance guardrails.");
        }

        RunnerValidation.RequireOnly(
            semanticProofs,
            "Broker semantic proofs",
            "contractVersion",
            "ownership",
            "readback",
            "recoverableBaseline",
            "warnings",
            "semanticBaseline",
            "mapping",
            "symbolPostProcessing");
        if (RunnerValidation.RequiredInt32(semanticProofs, "contractVersion", "Broker semantic proofs") != 1)
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker semantic proof contract is unsupported.");
        }

        foreach (var name in new[]
        {
            "ownership",
            "readback",
            "recoverableBaseline",
            "warnings",
            "semanticBaseline",
            "mapping",
            "symbolPostProcessing"
        })
        {
            var proof = RunnerValidation.RequiredObject(semanticProofs, name, "Broker semantic proofs");
            if (RunnerValidation.RequiredInt32(proof, "contractVersion", $"Broker semantic proof {name}") != 1 ||
                !RunnerValidation.RequiredBoolean(proof, "verified", $"Broker semantic proof {name}"))
            {
                throw new RunnerGateException(ProtocolInvalid, $"Successful Broker observation has incomplete semantic proof '{name}'.");
            }
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
            "mcpPid",
            "plePid",
            "profile",
            "activeProjectPath",
            "pleOwnedByBroker");
        if (RunnerValidation.RequiredString(observed, "state", "Broker observation session") != "ready" ||
            RunnerValidation.RequiredString(observed, "mode", "Broker observation session") != "persistent" ||
            RunnerValidation.RequiredString(observed, "sessionId", "Broker observation session") != expected.SessionId ||
            RunnerValidation.RequiredInt32(observed, "mcpPid", "Broker observation session") != expected.McpPid ||
            RunnerValidation.RequiredInt32(observed, "plePid", "Broker observation session") != expected.PlePid ||
            RunnerValidation.RequiredString(observed, "profile", "Broker observation session") != expected.Profile ||
            !RunnerValidation.FullPath(RunnerValidation.RequiredString(observed, "activeProjectPath", "Broker observation session"))
                .Equals(RunnerValidation.FullPath(expected.ActiveProjectPath), StringComparison.OrdinalIgnoreCase) ||
            RunnerValidation.RequiredBoolean(observed, "pleOwnedByBroker", "Broker observation session") !=
                expected.PleOwnedByBroker)
        {
            throw new RunnerGateException(ProtocolInvalid, "Broker observation session changed during execution.");
        }
    }

    private static void ValidateRegistrationForAction(BrokerRegistration registration, ValidatedRunnerAction action)
    {
        if (!registration.EngineeringRoot.Equals(action.EngineeringRoot, StringComparison.OrdinalIgnoreCase) ||
            !registration.StationRoot.Equals(action.StationRoot, StringComparison.OrdinalIgnoreCase) ||
            !registration.PlcProject.Equals(action.PlcProject, StringComparison.OrdinalIgnoreCase) ||
            registration.Profile != action.Profile)
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_PROJECT_MISMATCH", "Broker registration does not match the immutable action project.");
        }
    }

    private static BrokerExecutionReply Pending(string executionId, string reasonCode) => new(
        Available: true,
        ReasonCode: SafeReason(reasonCode, ExecutionPending),
        Session: null,
        Observation: null)
    {
        Accepted = true,
        Terminal = false,
        ReviewRequired = false,
        ExecutionId = executionId
    };

    private static BrokerExecutionReply Unavailable(string reasonCode) => new(
        Available: false,
        ReasonCode: SafeReason(reasonCode, SessionUnavailable),
        Session: null,
        Observation: null)
    {
        Accepted = false,
        Terminal = false,
        ReviewRequired = false
    };

    private static string SafeReason(string? reason, string fallback) =>
        !string.IsNullOrWhiteSpace(reason) && RunnerValidation.IsSafeIdentifier(reason, 96)
            ? reason
            : fallback;

    private static bool IsTransportOrProtocolFailure(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or TimeoutException or RunnerGateException or
            System.Text.Json.JsonException or System.Text.DecoderFallbackException;

    private static string ReasonFor(Exception exception) => exception is RunnerGateException gate
        ? SafeReason(gate.ReasonCode, ProtocolInvalid)
        : SessionUnavailable;

    private static TimeSpan RequireTimeout(TimeSpan value, string name, TimeSpan maximum)
    {
        if (value <= TimeSpan.Zero || value > maximum)
        {
            throw new ArgumentOutOfRangeException(name, $"Timeout must be greater than zero and no more than {maximum}.");
        }

        return value;
    }

    private static int ToMilliseconds(TimeSpan value) => checked((int)Math.Ceiling(value.TotalMilliseconds));

    private static PipeServerIdentity GetServerIdentity(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var processId) ||
            !GetNamedPipeServerSessionId(pipe.SafePipeHandle, out var sessionId) ||
            processId == 0 || processId > int.MaxValue || sessionId > int.MaxValue)
        {
            throw new RunnerGateException(BrokerIdentityInvalid, "Named Pipe server identity cannot be read.");
        }

        return new PipeServerIdentity((int)processId, (int)sessionId);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerSessionId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint serverSessionId);

    private sealed record PipeServerIdentity(int ProcessId, int WindowsSessionId);
    private sealed record SubmitReceipt(bool Accepted, string ReasonCode, string ExecutionId);
}
