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
        var claimPresent = false;
        var recoveringExistingClaim = false;
        RunnerLeaseSet? leaseSet = null;

        try
        {
            leaseSet = RunnerLeaseSet.Acquire(action, request.LeaseTimeout);
            if (store.TryReadResult(out replay) && replay is not null)
            {
                return replay;
            }

            var claimCreated = store.TryCreateClaim(brokerClient.TransportName);
            claimPresent = true;
            recoveringExistingClaim = !claimCreated;
            if (recoveringExistingClaim)
            {
                if (store.TryReadResult(out replay) && replay is not null)
                {
                    return replay;
                }

                // A previous client may have detached after the Broker accepted
                // this idempotent action.  Keep the claim open and ask the Broker
                // for the authoritative operation state instead of fabricating an
                // UNKNOWN terminal result or dispatching a second Build.
                store.AppendEvent(RunnerStates.Received, "ACTION_RECOVERY_REQUESTED");
            }
            else
            {
                store.AppendEvent(RunnerStates.Received, "ACTION_RECEIVED");
                store.AppendEvent(RunnerStates.ActionValidated, "ACTION_VALIDATED");
                store.AppendEvent(RunnerStates.ActionLeased, "ACTION_LEASED");
            }

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
                    if (recoveringExistingClaim)
                    {
                        store.AppendEvent(RunnerStates.Executing, "BROKER_RECOVERY_PENDING");
                        throw Pending("BROKER_RECOVERY_PENDING");
                    }

                    terminal = new ExecutionTerminal(
                        RunnerStates.Blocked,
                        SafeBrokerReason(reply.ReasonCode, "BLOCKED_SESSION_UNAVAILABLE"),
                        RunnerExitCodes.Blocked);
                    observation = RunnerObservationFactory.Blocked(action, "session_probe", terminal.ReasonCode);
                }
                else if (reply.Terminal && reply.ReviewRequired)
                {
                    // UNKNOWN_REVIEW_REQUIRED and CANCELED are durable Broker
                    // terminal outcomes, not a polling state.  Seal a local
                    // UNKNOWN result without inventing evidence and, critically,
                    // without submitting the immutable action for another Build.
                    return store.Complete(
                        RunnerStates.Unknown,
                        SafeBrokerReason(reply.ReasonCode, "BROKER_REVIEW_REQUIRED"),
                        RunnerExitCodes.GateFailure,
                        observationSha256: null,
                        evidence: null);
                }
                else if ((reply.Accepted && !reply.Terminal) ||
                         (!reply.Terminal && reply.Observation is null))
                {
                    // A durable Broker acceptance is not a terminal result.  The
                    // second condition preserves the short-lived v1 bridge where
                    // Available=true plus Observation=null represented pending.
                    // Do not write observation.json or result.json here; the next
                    // call resumes by idempotency key / execution id.
                    store.AppendEvent(RunnerStates.Executing, "BROKER_OPERATION_PENDING");
                    throw Pending("BROKER_OPERATION_PENDING");
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
                    throw new RunnerGateException(
                        "BROKER_TERMINAL_OBSERVATION_MISSING",
                        "Broker marked the operation terminal without returning its durable observation.");
                }
                else
                {
                    store.AppendEvent(RunnerStates.Executing, "BROKER_EXECUTED_ACTION");
                    ValidateObservationIdentity(action, reply.Observation);
                    observation = reply.Observation;
                    terminal = MapObservationResult(observation);
                }
            }

            if (File.Exists(store.ObservationPath))
            {
                // Recovery can resume after a terminal observation was persisted
                // but before evidence/result commit.  The Broker must replay the
                // exact terminal observation for the idempotent action.
                var existingObservation = RunnerJson.ReadObject(store.ObservationPath, "Runner observation");
                ValidateObservationIdentity(action, existingObservation);
                if (!JsonNode.DeepEquals(existingObservation, observation))
                {
                    throw new RunnerGateException(
                        "BROKER_OBSERVATION_REPLAY_MISMATCH",
                        "Broker replay did not match the already persisted terminal observation.");
                }

                observation = existingObservation;
                observationSha256 = RunnerHash.Sha256File(store.ObservationPath);
            }
            else
            {
                observationSha256 = store.WriteObservation(observation);
            }
            store.AppendEvent(RunnerStates.ObservationWritten, "OBSERVATION_WRITTEN");

            if (terminal is null || observationSha256 is null)
            {
                throw new RunnerGateException("RUNNER_STATE_INVALID", "Runner did not reach a sealable terminal observation.");
            }

            // The Broker observation is authoritative for its action-scoped
            // project serialization gate. The Runner's separate immutable-action
            // lease stays held through evidence sealing and atomic result commit.
            store.AppendEvent(RunnerStates.Sealing, "SEALING_EVIDENCE");
            var evidence = await evidenceSealer.SealAsync(action, store.ObservationPath, cancellationToken).ConfigureAwait(false);
            return store.Complete(terminal.State, terminal.ReasonCode, terminal.ExitCode, observationSha256, evidence);
        }
        catch (OperationCanceledException) when (claimPresent)
        {
            // Client cancellation/detach is not proof that an accepted MCP/PLE
            // operation stopped.  Keep claim.json without a terminal result so a
            // later call can query/replay the Broker operation idempotently.
            store.AppendEvent(RunnerStates.Executing, "CLIENT_DETACHED_CANCELLATION_REQUESTED");
            throw;
        }
        catch (RunnerGateException exception) when (claimPresent && IsPending(exception))
        {
            // Pending is deliberately non-terminal: the immutable claim remains
            // the recovery anchor and no observation/evidence/result is sealed.
            throw;
        }
        catch (RunnerGateException exception) when (claimPresent)
        {
            return CompleteAfterClaimIfNeeded(
                store,
                RunnerStates.Failed,
                exception.ReasonCode,
                exception.ExitCode == RunnerExitCodes.Busy ? RunnerExitCodes.GateFailure : exception.ExitCode);
        }
        catch (Exception) when (claimPresent)
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

    private static RunnerGateException Pending(string reasonCode) => new(
        reasonCode,
        "The Broker operation is accepted or recoverable but has not reached a terminal state.",
        RunnerExitCodes.Busy);

    private static bool IsPending(RunnerGateException exception) =>
        exception.ReasonCode is "BROKER_OPERATION_PENDING" or "BROKER_RECOVERY_PENDING";

    private static bool SessionMatches(ValidatedRunnerAction action, BrokerSessionIdentity? session)
    {
        if (session is null ||
            session.ProtocolVersion != BrokerWireProtocol.Version ||
            session.BrokerPid <= 0 ||
            session.McpPid <= 0 ||
            session.PlePid <= 0 ||
            session.State != "ready" ||
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
