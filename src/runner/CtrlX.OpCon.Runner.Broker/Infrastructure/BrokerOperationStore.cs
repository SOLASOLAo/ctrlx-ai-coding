using System.Diagnostics;
using System.Text.Json.Serialization;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public static class BrokerOperationStates
{
    public const string Accepted = "ACCEPTED";
    public const string Queued = "QUEUED";
    public const string SessionVerified = "SESSION_VERIFIED";
    public const string Executing = "EXECUTING";
    public const string Completing = "COMPLETING";
    public const string Succeeded = "SUCCEEDED";
    public const string Blocked = "BLOCKED";
    public const string Failed = "FAILED";
    public const string Canceled = "CANCELED";
    public const string UnknownReviewRequired = "UNKNOWN_REVIEW_REQUIRED";

    private static readonly HashSet<string> KnownStates = new(StringComparer.Ordinal)
    {
        Accepted,
        Queued,
        SessionVerified,
        Executing,
        Completing,
        Succeeded,
        Blocked,
        Failed,
        Canceled,
        UnknownReviewRequired
    };

    public static bool IsKnown(string state) => KnownStates.Contains(state);

    public static bool IsTerminal(string state) =>
        state is Succeeded or Blocked or Failed or Canceled or UnknownReviewRequired;
}

public sealed record BrokerOperationIdentity(
    string ActionId,
    string ActionSha256,
    string IdempotencyKey,
    string ActionKind);

public enum BrokerOperationDisposition
{
    Accepted,
    Replayed
}

public enum BrokerCancellationDisposition
{
    CanceledBeforeDispatch,
    NotCancelableContinuing,
    AlreadyTerminal
}

public enum BrokerRecoveryDisposition
{
    None,
    RequeuedBeforeDispatch,
    UnknownReviewRequired
}

public sealed record BrokerOperationAcceptance(
    BrokerOperationDisposition Disposition,
    BrokerOperationRecord Operation);

public sealed record BrokerCancellationResult(
    BrokerCancellationDisposition Disposition,
    BrokerOperationRecord Operation);

public sealed record BrokerRecoveryResult(
    BrokerRecoveryDisposition Disposition,
    BrokerOperationRecord Operation);

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed class BrokerOperationHistoryEntry
{
    public DateTimeOffset AtUtc { get; set; }
    public string Event { get; set; } = string.Empty;
    public string? From { get; set; }
    public string To { get; set; } = string.Empty;
    public string? Detail { get; set; }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed class BrokerOperationRecord
{
    public int SchemaVersion { get; set; } = 1;
    public string Kind { get; set; } = "ctrlx-opcon-broker-operation";
    public string ExecutionId { get; set; } = string.Empty;
    public string ActionId { get; set; } = string.Empty;
    public string ActionSha256 { get; set; } = string.Empty;
    public string IdempotencyKey { get; set; } = string.Empty;
    public string ActionKind { get; set; } = string.Empty;
    public string BrokerInstanceId { get; set; } = string.Empty;
    public string State { get; set; } = string.Empty;
    public bool CancellationRequested { get; set; }
    public DateTimeOffset AcceptedAtUtc { get; set; }
    public DateTimeOffset UpdatedAtUtc { get; set; }
    public DateTimeOffset? CompletedAtUtc { get; set; }
    public string? TerminalReasonCode { get; set; }
    public string? ObservationPath { get; set; }
    public string? ObservationSha256 { get; set; }
    public List<BrokerOperationHistoryEntry> History { get; set; } = [];
}

public sealed class BrokerOperationStore
{
    private static readonly IReadOnlyDictionary<string, HashSet<string>> AllowedTransitions =
        new Dictionary<string, HashSet<string>>(StringComparer.Ordinal)
        {
            [BrokerOperationStates.Accepted] = [BrokerOperationStates.Queued, BrokerOperationStates.Blocked, BrokerOperationStates.Failed, BrokerOperationStates.Canceled, BrokerOperationStates.UnknownReviewRequired],
            [BrokerOperationStates.Queued] = [BrokerOperationStates.SessionVerified, BrokerOperationStates.Blocked, BrokerOperationStates.Failed, BrokerOperationStates.Canceled, BrokerOperationStates.UnknownReviewRequired],
            [BrokerOperationStates.SessionVerified] = [BrokerOperationStates.Executing, BrokerOperationStates.Blocked, BrokerOperationStates.Failed, BrokerOperationStates.Canceled, BrokerOperationStates.UnknownReviewRequired],
            [BrokerOperationStates.Executing] = [BrokerOperationStates.Completing, BrokerOperationStates.Blocked, BrokerOperationStates.Failed, BrokerOperationStates.UnknownReviewRequired],
            [BrokerOperationStates.Completing] = [BrokerOperationStates.Succeeded, BrokerOperationStates.Blocked, BrokerOperationStates.Failed, BrokerOperationStates.UnknownReviewRequired]
        };

    private readonly BrokerRuntimePaths paths;
    private readonly TimeSpan lockTimeout;

    public BrokerOperationStore(BrokerRuntimePaths paths, TimeSpan? lockTimeout = null)
    {
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));
        this.lockTimeout = lockTimeout ?? TimeSpan.FromSeconds(5);
        if (this.lockTimeout < TimeSpan.Zero || this.lockTimeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(nameof(lockTimeout));
        }

        paths.EnsureCreated();
    }

    public BrokerOperationAcceptance Accept(
        BrokerOperationIdentity identity,
        string brokerInstanceId,
        DateTimeOffset? acceptedAtUtc = null)
    {
        ValidateIdentity(identity);
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        var executionId = ExecutionIdFor(identity.ActionId);
        return WithLockedOperation(executionId, () =>
        {
            var operationPath = OperationPath(executionId);
            if (File.Exists(operationPath))
            {
                var existing = ReadAndValidate(operationPath);
                EnsureSameIdentity(existing, identity);
                return new BrokerOperationAcceptance(BrokerOperationDisposition.Replayed, existing);
            }

            var now = acceptedAtUtc ?? DateTimeOffset.UtcNow;
            var operation = new BrokerOperationRecord
            {
                ExecutionId = executionId,
                ActionId = identity.ActionId,
                ActionSha256 = identity.ActionSha256.ToUpperInvariant(),
                IdempotencyKey = identity.IdempotencyKey.ToUpperInvariant(),
                ActionKind = identity.ActionKind,
                BrokerInstanceId = brokerInstanceId,
                State = BrokerOperationStates.Accepted,
                AcceptedAtUtc = now,
                UpdatedAtUtc = now,
                History =
                [
                    NewHistory(now, "ACTION_ACCEPTED", null, BrokerOperationStates.Accepted, null)
                ]
            };
            Validate(operation);
            BrokerAtomicJson.Write(operationPath, operation, overwrite: false);
            return new BrokerOperationAcceptance(BrokerOperationDisposition.Accepted, operation);
        });
    }

    public BrokerOperationRecord Read(string executionId)
    {
        BrokerValueValidation.RequireSafeIdentifier(executionId, nameof(executionId), maximumLength: 96);
        if (!Directory.Exists(paths.OperationDirectory(executionId)))
        {
            throw new BrokerInfrastructureException("BROKER_STATE_NOT_FOUND", $"Broker operation does not exist: {executionId}");
        }

        return WithLockedOperation(executionId, () => ReadAndValidate(OperationPath(executionId)));
    }

    public BrokerOperationRecord Transition(
        string executionId,
        string brokerInstanceId,
        string targetState,
        string eventName,
        string? detail = null,
        string? terminalReasonCode = null,
        string? observationPath = null,
        string? observationSha256 = null,
        DateTimeOffset? atUtc = null)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        BrokerValueValidation.RequireSafeIdentifier(eventName, nameof(eventName), maximumLength: 96);
        return WithLockedOperation(executionId, () =>
        {
            var path = OperationPath(executionId);
            var operation = ReadAndValidate(path);
            if (operation.BrokerInstanceId != brokerInstanceId)
            {
                throw new BrokerInfrastructureException("BROKER_OPERATION_NOT_OWNER", "Operation belongs to another Broker instance.");
            }

            if (operation.State == targetState)
            {
                return operation;
            }

            if (BrokerOperationStates.IsTerminal(operation.State) ||
                !AllowedTransitions.TryGetValue(operation.State, out var allowed) ||
                !allowed.Contains(targetState))
            {
                throw new BrokerInfrastructureException(
                    "BROKER_OPERATION_TRANSITION_INVALID",
                    $"Operation cannot transition from {operation.State} to {targetState}.");
            }

            var now = atUtc ?? DateTimeOffset.UtcNow;
            var previous = operation.State;
            operation.State = targetState;
            operation.UpdatedAtUtc = now;
            operation.History.Add(NewHistory(now, eventName, previous, targetState, detail));
            if (BrokerOperationStates.IsTerminal(targetState))
            {
                ApplyTerminal(operation, targetState, terminalReasonCode, observationPath, observationSha256, now);
            }

            Validate(operation);
            BrokerAtomicJson.Write(path, operation, overwrite: true);
            return operation;
        });
    }

    public BrokerCancellationResult RequestCancellation(
        string executionId,
        string brokerInstanceId,
        DateTimeOffset? atUtc = null)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        return WithLockedOperation(executionId, () =>
        {
            var path = OperationPath(executionId);
            var operation = ReadAndValidate(path);
            if (operation.BrokerInstanceId != brokerInstanceId)
            {
                throw new BrokerInfrastructureException("BROKER_OPERATION_NOT_OWNER", "Operation belongs to another Broker instance.");
            }

            if (BrokerOperationStates.IsTerminal(operation.State))
            {
                return new BrokerCancellationResult(BrokerCancellationDisposition.AlreadyTerminal, operation);
            }

            var now = atUtc ?? DateTimeOffset.UtcNow;
            var previous = operation.State;
            operation.CancellationRequested = true;
            operation.UpdatedAtUtc = now;
            if (operation.State is BrokerOperationStates.Accepted or BrokerOperationStates.Queued or BrokerOperationStates.SessionVerified)
            {
                operation.State = BrokerOperationStates.Canceled;
                operation.CompletedAtUtc = now;
                operation.TerminalReasonCode = "CANCELED_BEFORE_DISPATCH";
                operation.History.Add(NewHistory(now, "ACTION_CANCELED_BEFORE_DISPATCH", previous, operation.State, null));
                Validate(operation);
                BrokerAtomicJson.Write(path, operation, overwrite: true);
                return new BrokerCancellationResult(BrokerCancellationDisposition.CanceledBeforeDispatch, operation);
            }

            operation.History.Add(NewHistory(now, "CANCELLATION_REQUESTED_CONTINUING", previous, previous, "MCP/PLE call is already non-cancelable."));
            Validate(operation);
            BrokerAtomicJson.Write(path, operation, overwrite: true);
            return new BrokerCancellationResult(BrokerCancellationDisposition.NotCancelableContinuing, operation);
        });
    }

    public IReadOnlyList<BrokerRecoveryResult> RecoverInterrupted(
        string brokerInstanceId,
        DateTimeOffset? atUtc = null)
    {
        BrokerValueValidation.RequireSafeIdentifier(brokerInstanceId, nameof(brokerInstanceId));
        var results = new List<BrokerRecoveryResult>();
        foreach (var directory in Directory.EnumerateDirectories(paths.OperationsRoot))
        {
            var executionId = Path.GetFileName(directory);
            if (string.IsNullOrWhiteSpace(executionId))
            {
                continue;
            }

            results.Add(WithLockedOperation(executionId, () =>
            {
                var path = OperationPath(executionId);
                var operation = ReadAndValidate(path);
                if (BrokerOperationStates.IsTerminal(operation.State))
                {
                    return new BrokerRecoveryResult(BrokerRecoveryDisposition.None, operation);
                }

                var now = atUtc ?? DateTimeOffset.UtcNow;
                var previous = operation.State;
                operation.BrokerInstanceId = brokerInstanceId;
                operation.UpdatedAtUtc = now;
                BrokerRecoveryDisposition disposition;
                if (previous is BrokerOperationStates.Accepted or BrokerOperationStates.Queued or BrokerOperationStates.SessionVerified)
                {
                    operation.State = BrokerOperationStates.Queued;
                    operation.History.Add(NewHistory(now, "RECOVERED_BEFORE_DISPATCH", previous, operation.State, "Session identity must be verified again."));
                    disposition = BrokerRecoveryDisposition.RequeuedBeforeDispatch;
                }
                else
                {
                    operation.State = BrokerOperationStates.UnknownReviewRequired;
                    operation.CompletedAtUtc = now;
                    operation.TerminalReasonCode = "BROKER_CRASH_DURING_ENGINEERING_CALL";
                    operation.History.Add(NewHistory(now, "RECOVERED_AS_UNKNOWN", previous, operation.State, "The engineering call must not be repeated automatically."));
                    disposition = BrokerRecoveryDisposition.UnknownReviewRequired;
                }

                Validate(operation);
                BrokerAtomicJson.Write(path, operation, overwrite: true);
                return new BrokerRecoveryResult(disposition, operation);
            }));
        }

        return results;
    }

    public static string ExecutionIdFor(string actionId)
    {
        BrokerValueValidation.RequireSafeIdentifier(actionId, nameof(actionId));
        return "exec-" + BrokerRuntimePaths.Sha256Text(actionId).ToLowerInvariant();
    }

    private T WithLockedOperation<T>(string executionId, Func<T> body)
    {
        BrokerValueValidation.RequireSafeIdentifier(executionId, nameof(executionId), maximumLength: 96);
        var directory = paths.OperationDirectory(executionId);
        Directory.CreateDirectory(directory);
        var lockPath = Path.Combine(directory, "operation.lock");
        var stopwatch = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                using var stream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                return body();
            }
            catch (IOException) when (stopwatch.Elapsed < lockTimeout)
            {
                Thread.Sleep(25);
            }
            catch (IOException exception)
            {
                throw new BrokerInfrastructureException("BROKER_OPERATION_BUSY", $"Operation state is locked: {executionId}", exception);
            }
        }
    }

    private string OperationPath(string executionId) =>
        Path.Combine(paths.OperationDirectory(executionId), "operation.json");

    private static BrokerOperationRecord ReadAndValidate(string path)
    {
        var operation = BrokerAtomicJson.Read<BrokerOperationRecord>(path, "Broker operation");
        Validate(operation);
        return operation;
    }

    private static void EnsureSameIdentity(BrokerOperationRecord existing, BrokerOperationIdentity requested)
    {
        if (existing.ActionId != requested.ActionId ||
            !existing.ActionSha256.Equals(requested.ActionSha256, StringComparison.OrdinalIgnoreCase) ||
            !existing.IdempotencyKey.Equals(requested.IdempotencyKey, StringComparison.OrdinalIgnoreCase) ||
            existing.ActionKind != requested.ActionKind)
        {
            throw new BrokerInfrastructureException(
                "BROKER_OPERATION_IDEMPOTENCY_CONFLICT",
                "The actionId already exists with a different hash, idempotency key, or action kind.");
        }
    }

    private static void ApplyTerminal(
        BrokerOperationRecord operation,
        string targetState,
        string? reasonCode,
        string? observationPath,
        string? observationSha256,
        DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(reasonCode))
        {
            throw new BrokerInfrastructureException("BROKER_TERMINAL_REASON_REQUIRED", "A terminal operation requires a reason code.");
        }

        BrokerValueValidation.RequireSafeIdentifier(reasonCode, nameof(reasonCode), maximumLength: 96);
        operation.TerminalReasonCode = reasonCode;
        operation.CompletedAtUtc = now;
        if (targetState is BrokerOperationStates.Succeeded or BrokerOperationStates.Blocked or BrokerOperationStates.Failed)
        {
            if (string.IsNullOrWhiteSpace(observationPath) || string.IsNullOrWhiteSpace(observationSha256))
            {
                throw new BrokerInfrastructureException("BROKER_TERMINAL_OBSERVATION_REQUIRED", "Succeeded/blocked/failed operations require a terminal observation.");
            }

            BrokerValueValidation.RequireSha256(observationSha256, nameof(observationSha256));
            operation.ObservationPath = BrokerRuntimePaths.NormalizePath(observationPath);
            operation.ObservationSha256 = observationSha256.ToUpperInvariant();
        }
    }

    private static void ValidateIdentity(BrokerOperationIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        BrokerValueValidation.RequireSafeIdentifier(identity.ActionId, nameof(identity.ActionId));
        BrokerValueValidation.RequireSafeIdentifier(identity.ActionKind, nameof(identity.ActionKind));
        BrokerValueValidation.RequireSha256(identity.ActionSha256, nameof(identity.ActionSha256));
        BrokerValueValidation.RequireSha256(identity.IdempotencyKey, nameof(identity.IdempotencyKey));
    }

    private static void Validate(BrokerOperationRecord operation)
    {
        if (operation.SchemaVersion != 1 || operation.Kind != "ctrlx-opcon-broker-operation")
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation schema is unsupported.");
        }

        BrokerValueValidation.RequireSafeIdentifier(operation.ExecutionId, nameof(operation.ExecutionId), maximumLength: 96);
        BrokerValueValidation.RequireSafeIdentifier(operation.ActionId, nameof(operation.ActionId));
        BrokerValueValidation.RequireSafeIdentifier(operation.ActionKind, nameof(operation.ActionKind));
        BrokerValueValidation.RequireSafeIdentifier(operation.BrokerInstanceId, nameof(operation.BrokerInstanceId));
        BrokerValueValidation.RequireSha256(operation.ActionSha256, nameof(operation.ActionSha256));
        BrokerValueValidation.RequireSha256(operation.IdempotencyKey, nameof(operation.IdempotencyKey));
        if (!BrokerOperationStates.IsKnown(operation.State))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", $"Unknown Broker operation state: {operation.State}");
        }

        if (operation.ExecutionId != ExecutionIdFor(operation.ActionId) || operation.UpdatedAtUtc < operation.AcceptedAtUtc)
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation identity or timestamps are inconsistent.");
        }

        if (BrokerOperationStates.IsTerminal(operation.State) != operation.CompletedAtUtc.HasValue)
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation terminal timestamp is inconsistent with its state.");
        }

        if (BrokerOperationStates.IsTerminal(operation.State) && string.IsNullOrWhiteSpace(operation.TerminalReasonCode))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Terminal Broker operation has no reason code.");
        }

        if (operation.TerminalReasonCode is not null)
        {
            BrokerValueValidation.RequireSafeIdentifier(operation.TerminalReasonCode, nameof(operation.TerminalReasonCode), maximumLength: 96);
        }

        if (!BrokerOperationStates.IsTerminal(operation.State) &&
            (operation.TerminalReasonCode is not null || operation.ObservationPath is not null || operation.ObservationSha256 is not null))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Nonterminal Broker operation contains terminal fields.");
        }

        if (operation.CompletedAtUtc.HasValue &&
            (operation.CompletedAtUtc.Value < operation.AcceptedAtUtc || operation.CompletedAtUtc.Value != operation.UpdatedAtUtc))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation completion timestamp is inconsistent.");
        }

        if (operation.ObservationSha256 is not null)
        {
            BrokerValueValidation.RequireSha256(operation.ObservationSha256, nameof(operation.ObservationSha256));
        }

        if ((operation.ObservationPath is null) != (operation.ObservationSha256 is null))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Observation path/hash must be present together.");
        }

        if (operation.ObservationPath is not null && !Path.IsPathFullyQualified(operation.ObservationPath))
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Observation path must be absolute.");
        }

        if (operation.State is BrokerOperationStates.Succeeded or BrokerOperationStates.Blocked or BrokerOperationStates.Failed &&
            operation.ObservationPath is null)
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Succeeded/blocked/failed operation has no terminal observation.");
        }

        ValidateHistory(operation);
    }

    private static void ValidateHistory(BrokerOperationRecord operation)
    {
        if (operation.History is null || operation.History.Count is 0 or > 1024)
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation history is missing or too large.");
        }

        DateTimeOffset? previousAt = null;
        for (var index = 0; index < operation.History.Count; index++)
        {
            var entry = operation.History[index];
            if (entry is null ||
                entry.AtUtc < operation.AcceptedAtUtc ||
                entry.AtUtc > operation.UpdatedAtUtc ||
                (previousAt.HasValue && entry.AtUtc < previousAt.Value) ||
                !BrokerOperationStates.IsKnown(entry.To) ||
                (entry.From is not null && !BrokerOperationStates.IsKnown(entry.From)))
            {
                throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation history is inconsistent.");
            }

            BrokerValueValidation.RequireSafeIdentifier(entry.Event, nameof(entry.Event), maximumLength: 96);
            BrokerValueValidation.RequireBoundedText(entry.Detail, nameof(entry.Detail), maximumLength: 4096);
            previousAt = entry.AtUtc;

            if (index == 0 &&
                (entry.Event != "ACTION_ACCEPTED" || entry.From is not null || entry.To != BrokerOperationStates.Accepted))
            {
                throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation history does not start at acceptance.");
            }
        }

        if (operation.History[^1].To != operation.State)
        {
            throw new BrokerInfrastructureException("BROKER_OPERATION_INVALID", "Broker operation history does not end at the current state.");
        }
    }

    private static BrokerOperationHistoryEntry NewHistory(
        DateTimeOffset atUtc,
        string eventName,
        string? from,
        string to,
        string? detail) => new()
    {
        AtUtc = atUtc,
        Event = eventName,
        From = from,
        To = to,
        Detail = detail
    };
}
