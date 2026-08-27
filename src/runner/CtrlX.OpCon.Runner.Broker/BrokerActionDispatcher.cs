using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker.Infrastructure;
using CtrlX.OpCon.Runner.Broker.Session;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker;

public sealed record BrokerDispatchReceipt(
    bool Accepted,
    string ReasonCode,
    string ExecutionId,
    string Disposition,
    string State);

public sealed record BrokerQueryResult(
    string ExecutionId,
    bool Terminal,
    bool ReviewRequired,
    string ReasonCode,
    string State,
    BrokerSessionRuntime? Session,
    JsonObject? Observation);

/// <summary>
/// Durable typed dispatcher. It serializes all engineering work through one
/// session gate and never accepts a generic MCP tool name or free-form command.
/// </summary>
public sealed class BrokerActionDispatcher
{
    private readonly BrokerHostOptions options;
    private readonly string brokerInstanceId;
    private readonly IBrokerEngineeringSession session;
    private readonly BrokerOperationStore operations;
    private readonly RunnerActionValidator validator = new();
    private readonly SemaphoreSlim sessionGate = new(1, 1);
    private readonly ConcurrentDictionary<string, Lazy<Task>> active = new(StringComparer.Ordinal);
    private BrokerSessionRuntime? runtime;

    public BrokerActionDispatcher(
        BrokerHostOptions options,
        string brokerInstanceId,
        IBrokerEngineeringSession session,
        BrokerOperationStore operations)
    {
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.brokerInstanceId = brokerInstanceId ?? throw new ArgumentNullException(nameof(brokerInstanceId));
        this.session = session ?? throw new ArgumentNullException(nameof(session));
        this.operations = operations ?? throw new ArgumentNullException(nameof(operations));
    }

    public BrokerSessionRuntime Runtime =>
        runtime ?? throw new InvalidOperationException("Broker dispatcher is not initialized.");

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        runtime = await session.StartAsync(cancellationToken).ConfigureAwait(false);
        foreach (var recovery in operations.RecoverInterrupted(brokerInstanceId))
        {
            if (recovery.Disposition != BrokerRecoveryDisposition.RequeuedBeforeDispatch)
            {
                continue;
            }

            try
            {
                var action = FindAndValidateAction(recovery.Operation);
                ValidateSupportedIdentity(action);
                Schedule(action, recovery.Operation.ExecutionId);
            }
            catch (Exception exception) when (IsRecoverableActionFailure(exception))
            {
                // One missing, duplicated, or tampered immutable action must not
                // prevent unrelated durable operations from being recovered.
                // It also must never be guessed and dispatched for another Build.
                operations.Transition(
                    recovery.Operation.ExecutionId,
                    brokerInstanceId,
                    BrokerOperationStates.UnknownReviewRequired,
                    "RECOVERY_ACTION_REQUIRES_REVIEW",
                    detail: exception.GetType().Name,
                    terminalReasonCode: "BROKER_RECOVERY_ACTION_INVALID");
            }
        }
    }

    public ValidatedRunnerAction ValidateAction(string actionPath, string actionSha256) =>
        validator.Validate(options.EngineeringRoot, actionPath, actionSha256);

    public BrokerDispatchReceipt Submit(ValidatedRunnerAction action)
    {
        ArgumentNullException.ThrowIfNull(action);
        ValidateSupportedIdentity(action);
        var accepted = operations.Accept(
            new BrokerOperationIdentity(
                action.ActionId,
                action.ActionSha256,
                action.IdempotencyKey,
                action.ActionKind),
            brokerInstanceId);
        var operation = accepted.Operation;
        if (operation.State == BrokerOperationStates.Accepted)
        {
            operation = operations.Transition(
                operation.ExecutionId,
                brokerInstanceId,
                BrokerOperationStates.Queued,
                accepted.Disposition == BrokerOperationDisposition.Accepted
                    ? "ACTION_QUEUED"
                    : "REPLAYED_ACCEPTED_ACTION_QUEUED");
        }

        if (operation.State == BrokerOperationStates.Queued)
        {
            Schedule(action, operation.ExecutionId);
        }

        return new BrokerDispatchReceipt(
            Accepted: true,
            ReasonCode: accepted.Disposition == BrokerOperationDisposition.Accepted ? "ACTION_ACCEPTED" : "ACTION_REPLAYED",
            ExecutionId: operation.ExecutionId,
            Disposition: accepted.Disposition == BrokerOperationDisposition.Accepted ? "ACCEPTED" : "REPLAYED",
            State: operation.State);
    }

    public BrokerQueryResult Query(
        string executionId,
        string actionId,
        string actionSha256,
        string idempotencyKey)
    {
        var operation = operations.Read(executionId);
        if (operation.ActionId != actionId ||
            !operation.ActionSha256.Equals(actionSha256, StringComparison.OrdinalIgnoreCase) ||
            !operation.IdempotencyKey.Equals(idempotencyKey, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException("BROKER_QUERY_IDENTITY_MISMATCH", "Query does not match the durable action identity.");
        }

        if (operation.State is BrokerOperationStates.UnknownReviewRequired or BrokerOperationStates.Canceled)
        {
            return new BrokerQueryResult(
                executionId,
                Terminal: true,
                ReviewRequired: true,
                ReasonCode: operation.TerminalReasonCode ?? "BROKER_REVIEW_REQUIRED",
                State: operation.State,
                Session: null,
                Observation: null);
        }

        if (!BrokerOperationStates.IsTerminal(operation.State))
        {
            return new BrokerQueryResult(
                executionId,
                Terminal: false,
                ReviewRequired: false,
                ReasonCode: "EXECUTION_CONTINUES_IN_BROKER",
                State: operation.State,
                Session: null,
                Observation: null);
        }

        // The durable terminal file is committed while the serialized action
        // gate is still held. Do not expose it until RunAndRemoveAsync has left
        // the gate; only then are the observation's action-gate lifecycle facts
        // true for the completed action as delivered to the client.
        if (active.ContainsKey(executionId))
        {
            return new BrokerQueryResult(
                executionId,
                Terminal: false,
                ReviewRequired: false,
                ReasonCode: "TERMINAL_COMMIT_RELEASING_LEASE",
                State: operation.State,
                Session: null,
                Observation: null);
        }

        if (string.IsNullOrWhiteSpace(operation.ObservationPath) ||
            string.IsNullOrWhiteSpace(operation.ObservationSha256) ||
            !File.Exists(operation.ObservationPath) ||
            !RunnerHash.Sha256File(operation.ObservationPath).Equals(operation.ObservationSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException("BROKER_TERMINAL_EVIDENCE_INVALID", "Terminal Broker observation is missing or its hash changed.");
        }

        var observation = ReadObservation(operation.ObservationPath);
        return new BrokerQueryResult(
            executionId,
            Terminal: true,
            ReviewRequired: false,
            ReasonCode: operation.TerminalReasonCode ?? "BROKER_TERMINAL",
            State: operation.State,
            Session: Runtime,
            Observation: observation);
    }

    public async Task DrainAsync()
    {
        var tasks = active.Values.Select(value => value.Value).ToArray();
        if (tasks.Length > 0)
        {
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
    }

    private void Schedule(ValidatedRunnerAction action, string executionId)
    {
        var operation = active.GetOrAdd(
            executionId,
            _ => new Lazy<Task>(
                () => RunAndRemoveAsync(action, executionId),
                LazyThreadSafetyMode.ExecutionAndPublication));
        _ = operation.Value;
    }

    private async Task RunAndRemoveAsync(ValidatedRunnerAction action, string executionId)
    {
        try
        {
            await ExecuteCoreAsync(action, executionId).ConfigureAwait(false);
        }
        finally
        {
            active.TryRemove(executionId, out _);
        }
    }

    private async Task ExecuteCoreAsync(ValidatedRunnerAction action, string executionId)
    {
        await sessionGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
        var engineeringCallStarted = false;
        try
        {
            var current = operations.Read(executionId);
            if (BrokerOperationStates.IsTerminal(current.State))
            {
                return;
            }

            if (TryReconcilePredispatchObservation(action, executionId, current))
            {
                return;
            }

            var verified = await session.VerifyReadyAsync(action, CancellationToken.None).ConfigureAwait(false);
            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.SessionVerified,
                "SESSION_IDENTITY_VERIFIED");
            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.Executing,
                "ENGINEERING_SEQUENCE_STARTED");
            engineeringCallStarted = true;

            var outcome = await session.ExecuteAsync(action, verified, CancellationToken.None).ConfigureAwait(false);
            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.Completing,
                "OBSERVATION_COMPLETING");
            var observationPath = GetObservationPath(executionId);
            var observationSha256 = CommitExpectedObservation(action, observationPath, outcome.Observation);
            var target = outcome.TerminalState switch
            {
                "SUCCEEDED" => BrokerOperationStates.Succeeded,
                "BLOCKED" => BrokerOperationStates.Blocked,
                "FAILED" => BrokerOperationStates.Failed,
                _ => throw new BrokerInfrastructureException("BROKER_OUTCOME_INVALID", "Engineering session returned an invalid terminal state.")
            };
            operations.Transition(
                executionId,
                brokerInstanceId,
                target,
                "TERMINAL_OBSERVATION_COMMITTED",
                terminalReasonCode: outcome.ReasonCode,
                observationPath: observationPath,
                observationSha256: observationSha256);
        }
        catch (Exception exception)
        {
            await HandleExecutionFailureAsync(action, executionId, engineeringCallStarted, exception).ConfigureAwait(false);
        }
        finally
        {
            sessionGate.Release();
        }
    }

    private Task HandleExecutionFailureAsync(
        ValidatedRunnerAction action,
        string executionId,
        bool engineeringCallStarted,
        Exception exception)
    {
        var operation = operations.Read(executionId);
        if (BrokerOperationStates.IsTerminal(operation.State))
        {
            return Task.CompletedTask;
        }

        var reasonCode = SafeReason(exception);
        if (engineeringCallStarted || operation.State is BrokerOperationStates.Executing or BrokerOperationStates.Completing)
        {
            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.UnknownReviewRequired,
                "ENGINEERING_RESULT_UNCERTAIN",
                detail: exception.GetType().Name,
                terminalReasonCode: reasonCode);
            return Task.CompletedTask;
        }


        if (TryReconcilePredispatchObservation(action, executionId, operation))
        {
            return Task.CompletedTask;
        }

        var observation = BrokerObservationBuilder.Blocked(
            action,
            "session-verification",
            reasonCode);
        var observationPath = GetObservationPath(executionId);
        var observationSha256 = CommitExpectedObservation(action, observationPath, observation);
        operations.Transition(
            executionId,
            brokerInstanceId,
            BrokerOperationStates.Blocked,
            "ACTION_BLOCKED_BEFORE_ENGINEERING",
            detail: exception.GetType().Name,
            terminalReasonCode: reasonCode,
            observationPath: observationPath,
            observationSha256: observationSha256);
        return Task.CompletedTask;
    }

    private bool TryReconcilePredispatchObservation(
        ValidatedRunnerAction action,
        string executionId,
        BrokerOperationRecord operation)
    {
        if (operation.State is not (BrokerOperationStates.Accepted or
            BrokerOperationStates.Queued or
            BrokerOperationStates.SessionVerified))
        {
            return false;
        }

        var observationPath = GetObservationPath(executionId);
        if (!File.Exists(observationPath))
        {
            return false;
        }

        try
        {
            var observation = ReadObservation(observationPath);
            ValidateObservationIdentity(action, observation);
            var status = RequiredObservationString(observation, "status");
            if (status != "blocked" || observation["result"] is not JsonObject result)
            {
                throw new BrokerInfrastructureException(
                    "BROKER_ORPHAN_OBSERVATION_UNSAFE",
                    "A pre-dispatch operation contains an observation which could only have followed engineering execution.");
            }

            var reasonCode = RequiredObservationString(result, "reasonCode");
            if (!IsSafeReasonCode(reasonCode))
            {
                throw new BrokerInfrastructureException(
                    "BROKER_ORPHAN_OBSERVATION_INVALID",
                    "The orphaned blocked observation has an unsafe reason code.");
            }

            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.Blocked,
                "ORPHANED_BLOCKED_OBSERVATION_RECOVERED",
                terminalReasonCode: reasonCode,
                observationPath: observationPath,
                observationSha256: RunnerHash.Sha256File(observationPath));
        }
        catch (Exception exception) when (IsRecoverableObservationFailure(exception))
        {
            operations.Transition(
                executionId,
                brokerInstanceId,
                BrokerOperationStates.UnknownReviewRequired,
                "ORPHANED_OBSERVATION_REQUIRES_REVIEW",
                detail: exception.GetType().Name,
                terminalReasonCode: "BROKER_ORPHAN_OBSERVATION_INVALID");
        }

        return true;
    }

    private string CommitExpectedObservation(
        ValidatedRunnerAction action,
        string observationPath,
        JsonObject expected)
    {
        if (File.Exists(observationPath))
        {
            return ValidateExistingExpectedObservation(action, observationPath, expected);
        }

        try
        {
            BrokerAtomicJson.Write(observationPath, expected, overwrite: false);
            return RunnerHash.Sha256File(observationPath);
        }
        catch (BrokerInfrastructureException exception) when (
            exception.ReasonCode == "BROKER_IMMUTABLE_STATE_EXISTS" &&
            File.Exists(observationPath))
        {
            return ValidateExistingExpectedObservation(action, observationPath, expected);
        }
    }

    private static string ValidateExistingExpectedObservation(
        ValidatedRunnerAction action,
        string observationPath,
        JsonObject expected)
    {
        var existing = ReadObservation(observationPath);
        ValidateObservationIdentity(action, existing);
        if (!JsonNode.DeepEquals(existing, expected))
        {
            throw new BrokerInfrastructureException(
                "BROKER_OBSERVATION_CONFLICT",
                "Immutable Broker observation already exists with different content.");
        }

        return RunnerHash.Sha256File(observationPath);
    }

    private string GetObservationPath(string executionId) => Path.Combine(
        new BrokerRuntimePaths(options.EngineeringRoot, options.StationRoot, options.Profile, options.PlcProject)
            .OperationDirectory(executionId),
        "observation.json");

    private static void ValidateObservationIdentity(ValidatedRunnerAction action, JsonObject observation)
    {
        if (observation["schemaVersion"] is not JsonValue schema ||
            !schema.TryGetValue<int>(out var schemaVersion) ||
            schemaVersion != 1 ||
            RequiredObservationString(observation, "operationId") != action.OperationId ||
            RequiredObservationString(observation, "actionId") != action.ActionId ||
            RequiredObservationString(observation, "actionKind") != action.ActionKind ||
            !RequiredObservationString(observation, "actionRequestSha256")
                .Equals(action.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException(
                "BROKER_OBSERVATION_IDENTITY_MISMATCH",
                "Immutable Broker observation does not match the durable action identity.");
        }
    }

    private static string RequiredObservationString(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node ||
            !node.TryGetValue<string>(out var result) ||
            string.IsNullOrWhiteSpace(result))
        {
            throw new BrokerInfrastructureException(
                "BROKER_OBSERVATION_INVALID",
                $"Immutable Broker observation is missing '{name}'.");
        }

        return result;
    }

    private static bool IsRecoverableActionFailure(Exception exception) =>
        exception is RunnerGateException or BrokerInfrastructureException or IOException or UnauthorizedAccessException;

    private static bool IsRecoverableObservationFailure(Exception exception) =>
        exception is BrokerInfrastructureException or IOException or UnauthorizedAccessException or JsonException;

    private static bool IsSafeReasonCode(string value) =>
        value.Length is > 0 and <= 96 && value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-');

    private ValidatedRunnerAction FindAndValidateAction(BrokerOperationRecord operation)
    {
        var root = Path.Combine(options.EngineeringRoot, "data", "operations");
        var matches = new List<ValidatedRunnerAction>();
        foreach (var path in Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories))
        {
            try
            {
                var action = validator.Validate(options.EngineeringRoot, path, operation.ActionSha256);
                if (action.ActionId == operation.ActionId)
                {
                    matches.Add(action);
                }
            }
            catch (RunnerGateException)
            {
                // Only the immutable file with the persisted SHA and action ID
                // can be recovered; unrelated operation JSON is expected here.
            }
        }

        return matches.Count == 1
            ? matches[0]
            : throw new BrokerInfrastructureException(
                "BROKER_RECOVERY_ACTION_NOT_UNIQUE",
                $"Could not recover exactly one immutable action for {operation.ActionId}.");
    }

    private void ValidateSupportedIdentity(ValidatedRunnerAction action)
    {
        if (!action.IsSupported || action.ActionKind is not ("inspect_and_build" or "verify_after_export_2") ||
            !Path.GetFullPath(action.EngineeringRoot).Equals(Path.GetFullPath(options.EngineeringRoot), StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(action.StationRoot).Equals(Path.GetFullPath(options.StationRoot), StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(action.PlcProject).Equals(Path.GetFullPath(options.PlcProject), StringComparison.OrdinalIgnoreCase) ||
            action.Profile != options.Profile)
        {
            throw new BrokerInfrastructureException("BROKER_ACTION_NOT_ALLOWLISTED", "Action is not allowlisted for this Broker project identity.");
        }
    }

    private static string SafeReason(Exception exception)
    {
        var candidate = exception switch
        {
            BrokerEngineeringException engineering => engineering.ReasonCode,
            BrokerInfrastructureException infrastructure => infrastructure.ReasonCode,
            Mcp.McpClientException mcp => mcp.ReasonCode,
            _ => "BROKER_INTERNAL_FAILURE"
        };
        return candidate.Length is > 0 and <= 96 && candidate.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-')
            ? candidate
            : "BROKER_INTERNAL_FAILURE";
    }

    private static JsonObject ReadObservation(string path)
    {
        try
        {
            return JsonNode.Parse(
                File.ReadAllBytes(path),
                nodeOptions: null,
                documentOptions: new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64
                }) as JsonObject
                ?? throw new JsonException("Observation root is not an object.");
        }
        catch (JsonException exception)
        {
            throw new BrokerInfrastructureException("BROKER_TERMINAL_EVIDENCE_INVALID", "Terminal observation is invalid JSON.", exception);
        }
    }
}
