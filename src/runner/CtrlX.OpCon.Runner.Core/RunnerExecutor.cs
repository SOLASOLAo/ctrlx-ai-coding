using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public sealed class RunnerExecutor
{
    private readonly RunnerActionValidator validator;
    private readonly ISessionBrokerClient brokerClient;
    private readonly IEvidenceSealer evidenceSealer;

    public RunnerExecutor(
        ISessionBrokerClient brokerClient,
        IEvidenceSealer evidenceSealer,
        RunnerActionValidator? validator = null)
    {
        this.brokerClient = brokerClient ?? throw new ArgumentNullException(nameof(brokerClient));
        this.evidenceSealer = evidenceSealer ?? throw new ArgumentNullException(nameof(evidenceSealer));
        this.validator = validator ?? new RunnerActionValidator();
    }

    public async Task<RunnerExecutionResult> ExecuteAsync(
        RunnerExecutionRequest request,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var action = validator.Validate(
            request.EngineeringRoot,
            request.ActionPath,
            request.ExpectedActionSha256);
        var store = RunnerRunStore.ForAction(action);
        if (store.TryReadResult(out var replay) && replay is not null)
        {
            return replay;
        }

        JsonObject? observation = null;
        ExecutionTerminal? terminal = null;
        string? observationSha256 = null;
        var claimCreated = false;
        RunnerLeaseSet? leaseSet = null;

        try
        {
            leaseSet = RunnerLeaseSet.Acquire(action, request.LeaseTimeout);
            if (store.TryReadResult(out replay) && replay is not null)
            {
                return replay;
            }

            claimCreated = store.TryCreateClaim(brokerClient.TransportName);
            if (!claimCreated)
            {
                if (store.TryReadResult(out replay) && replay is not null)
                {
                    return replay;
                }

                return store.Complete(
                    RunnerStates.Unknown,
                    "INTERRUPTED_RUN_REVIEW_REQUIRED",
                    RunnerExitCodes.GateFailure,
                    observationSha256: null,
                    evidence: null);
            }

            store.AppendEvent(RunnerStates.Received, "ACTION_RECEIVED");
            store.AppendEvent(RunnerStates.ActionValidated, "ACTION_VALIDATED");
            store.AppendEvent(RunnerStates.ActionLeased, "ACTION_LEASED");

            if (!action.IsSupported)
            {
                terminal = new ExecutionTerminal(
                    RunnerStates.Blocked,
                    action.UnsupportedReasonCode ?? "BLOCKED_UNSUPPORTED_ACTION",
                    RunnerExitCodes.Blocked);
                observation = RunnerObservationFactory.Blocked(action, "action_gate", terminal.ReasonCode);
            }
            else
            {
                var reply = await brokerClient.ExecuteAsync(action, cancellationToken).ConfigureAwait(false);
                store.AppendEvent(RunnerStates.SessionProbed, reply.Available ? "SESSION_AVAILABLE" : reply.ReasonCode);
                if (!reply.Available)
                {
                    terminal = new ExecutionTerminal(
                        RunnerStates.Blocked,
                        SafeBrokerReason(reply.ReasonCode, "BLOCKED_SESSION_UNAVAILABLE"),
                        RunnerExitCodes.Blocked);
                    observation = RunnerObservationFactory.Blocked(action, "session_probe", terminal.ReasonCode);
                }
                else if (!SessionMatches(action, reply.Session))
                {
                    terminal = new ExecutionTerminal(
                        RunnerStates.Blocked,
                        "BLOCKED_SESSION_MISMATCH",
                        RunnerExitCodes.Blocked);
                    observation = RunnerObservationFactory.Blocked(action, "session_identity", terminal.ReasonCode);
                }
                else if (reply.Observation is null)
                {
                    terminal = new ExecutionTerminal(
                        RunnerStates.Blocked,
                        "BLOCKED_BROKER_OBSERVATION_MISSING",
                        RunnerExitCodes.Blocked);
                    observation = RunnerObservationFactory.Blocked(action, "broker_observation", terminal.ReasonCode);
                }
                else
                {
                    store.AppendEvent(RunnerStates.Executing, "BROKER_EXECUTED_ACTION");
                    ValidateObservationIdentity(action, reply.Observation);
                    observation = reply.Observation;
                    terminal = MapObservationResult(observation);
                }
            }

            observationSha256 = store.WriteObservation(observation);
            store.AppendEvent(RunnerStates.ObservationWritten, "OBSERVATION_WRITTEN");

            // Release only the profile/project session lease before evidence claims
            // that engineering coordination is released. The immutable action lease
            // remains held through evidence sealing and result.json commit.
            leaseSet.ReleaseSessionLease();

            if (terminal is null || observationSha256 is null)
            {
                throw new RunnerGateException("RUNNER_STATE_INVALID", "Runner did not reach a sealable terminal observation.");
            }

            // Both client/action leases are released before evidence claims
            // that coordination is no longer held.
            store.AppendEvent(RunnerStates.Sealing, "SEALING_EVIDENCE");
            var evidence = await evidenceSealer.SealAsync(action, store.ObservationPath, cancellationToken).ConfigureAwait(false);
            return store.Complete(terminal.State, terminal.ReasonCode, terminal.ExitCode, observationSha256, evidence);
        }
        catch (OperationCanceledException) when (claimCreated)
        {
            return CompleteAfterClaimIfNeeded(
                store,
                RunnerStates.Unknown,
                "EXECUTION_INTERRUPTED_REVIEW_REQUIRED",
                RunnerExitCodes.GateFailure);
        }
        catch (RunnerGateException exception) when (claimCreated)
        {
            return CompleteAfterClaimIfNeeded(
                store,
                RunnerStates.Failed,
                exception.ReasonCode,
                exception.ExitCode == RunnerExitCodes.Busy ? RunnerExitCodes.GateFailure : exception.ExitCode);
        }
        catch (Exception) when (claimCreated)
        {
            return CompleteAfterClaimIfNeeded(
                store,
                RunnerStates.Failed,
                "RUNNER_INTERNAL_ERROR",
                RunnerExitCodes.InternalError);
        }
        finally
        {
            leaseSet?.Dispose();
        }
    }

    private static RunnerExecutionResult CompleteAfterClaimIfNeeded(
        RunnerRunStore store,
        string state,
        string reasonCode,
        int exitCode)
    {
        if (store.TryReadResult(out var existing) && existing is not null)
        {
            return existing;
        }

        string? observationSha = null;
        if (File.Exists(store.ObservationPath))
        {
            observationSha = RunnerHash.Sha256File(store.ObservationPath);
        }

        return store.Complete(state, reasonCode, exitCode, observationSha, evidence: null);
    }

    private static string SafeBrokerReason(string? value, string fallback)
    {
        return !string.IsNullOrWhiteSpace(value) && RunnerValidation.IsSafeIdentifier(value, 96)
            ? value
            : fallback;
    }

    private static bool SessionMatches(ValidatedRunnerAction action, BrokerSessionIdentity? session)
    {
        if (session is null ||
            session.ProtocolVersion != 1 ||
            session.BrokerPid <= 0 ||
            session.PlePid <= 0 ||
            session.State != "ready" ||
            session.StartedByRunner ||
            session.Profile != action.Profile ||
            !RunnerValidation.IsSafeIdentifier(session.SessionId))
        {
            return false;
        }

        try
        {
            return RunnerValidation.FullPath(session.ActiveProjectPath)
                .Equals(RunnerValidation.FullPath(action.PlcProject), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static void ValidateObservationIdentity(ValidatedRunnerAction action, JsonObject observation)
    {
        RunnerValidation.AssertNoSensitiveFields(observation);
        if (RunnerValidation.RequiredInt32(observation, "schemaVersion", "Broker observation") != 1 ||
            RunnerValidation.RequiredString(observation, "operationId", "Broker observation") != action.OperationId ||
            RunnerValidation.RequiredString(observation, "actionId", "Broker observation") != action.ActionId ||
            RunnerValidation.RequiredString(observation, "actionKind", "Broker observation") != action.ActionKind ||
            !RunnerValidation.RequiredString(observation, "actionRequestSha256", "Broker observation")
                .Equals(action.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("BROKER_OBSERVATION_IDENTITY_MISMATCH", "Broker observation does not match the immutable action.");
        }

        var status = RunnerValidation.RequiredString(observation, "status", "Broker observation");
        if (status is not "succeeded" and not "blocked" and not "failed")
        {
            throw new RunnerGateException("BROKER_OBSERVATION_STATUS_INVALID", "Broker observation has an unsupported terminal status.");
        }
    }

    private static ExecutionTerminal MapObservationResult(JsonObject observation)
    {
        var status = RunnerValidation.RequiredString(observation, "status", "Broker observation");
        if (status == "succeeded")
        {
            return new ExecutionTerminal(RunnerStates.Done, "RUNNER_SUCCEEDED", RunnerExitCodes.Done);
        }

        var result = RunnerValidation.RequiredObject(observation, "result", "Broker observation");
        var reasonCode = RunnerValidation.RequiredString(result, "reasonCode", "Broker observation result");
        if (!RunnerValidation.IsSafeIdentifier(reasonCode, 96))
        {
            throw new RunnerGateException("BROKER_OBSERVATION_REASON_INVALID", "Broker observation reason code is malformed.");
        }

        return status == "blocked"
            ? new ExecutionTerminal(RunnerStates.Blocked, reasonCode, RunnerExitCodes.Blocked)
            : new ExecutionTerminal(RunnerStates.Failed, reasonCode, RunnerExitCodes.GateFailure);
    }

    private sealed record ExecutionTerminal(string State, string ReasonCode, int ExitCode);
}
