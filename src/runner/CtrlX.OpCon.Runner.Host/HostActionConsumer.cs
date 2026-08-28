using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Host;

internal interface IHostActionExecutor
{
    Task<RunnerExecutionResult> ExecuteAsync(RunnerInboxEntry entry, CancellationToken cancellationToken);
}

internal sealed class HostActionExecutor : IHostActionExecutor
{
    private readonly string engineeringRoot;

    public HostActionExecutor(string engineeringRoot)
    {
        this.engineeringRoot = engineeringRoot;
    }

    public Task<RunnerExecutionResult> ExecuteAsync(
        RunnerInboxEntry entry,
        CancellationToken cancellationToken)
    {
        ISessionBrokerClient broker = new NamedPipeSessionBrokerClient(
            engineeringRoot,
            registrationPath: null,
            connectTimeout: TimeSpan.FromSeconds(2),
            responseTimeout: TimeSpan.FromMinutes(30));
        var executor = new RunnerExecutor(broker, new PowerShellEvidenceSealer());
        return executor.ExecuteAsync(
            new RunnerExecutionRequest(
                engineeringRoot,
                entry.ActionPath,
                entry.ActionSha256,
                TimeSpan.FromSeconds(5),
                RunnerSessionUnavailableBehavior.KeepPending),
            cancellationToken);
    }
}

internal sealed class HostActionConsumer
{
    private readonly string engineeringRoot;
    private readonly DateTimeOffset activatedAtUtc;
    private readonly RunnerActionInbox inbox;
    private readonly IHostActionExecutor executor;
    private Task<RunnerExecutionResult>? activeTask;
    private RunnerInboxEntry? activeEntry;

    public HostActionConsumer(
        string engineeringRoot,
        DateTimeOffset activatedAtUtc,
        RunnerActionInbox? inbox = null,
        IHostActionExecutor? executor = null)
    {
        this.engineeringRoot = engineeringRoot;
        this.activatedAtUtc = activatedAtUtc;
        this.inbox = inbox ?? new RunnerActionInbox();
        this.executor = executor ?? new HostActionExecutor(engineeringRoot);
    }

    public HostActionStatus Tick(bool agentAvailable, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (activeTask is not null && activeEntry is not null)
        {
            if (!activeTask.IsCompleted)
            {
                return ForEntry(
                    activeEntry,
                    HostActionStates.Executing,
                    "HOST_ACTION_EXECUTING",
                    pendingCount: 1,
                    invalidCount: 0,
                    legacyIgnoredCount: 0);
            }

            var completedTask = activeTask;
            var completedEntry = activeEntry;
            activeTask = null;
            activeEntry = null;
            try
            {
                var result = completedTask.GetAwaiter().GetResult();
                return ResultReady(completedEntry, result, 0, 0, 0);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (RunnerGateException exception) when (IsPending(exception.ReasonCode))
            {
                return ForEntry(
                    completedEntry,
                    PendingActionState(exception),
                    PendingStatusReason(exception),
                    pendingCount: 1,
                    invalidCount: 0,
                    legacyIgnoredCount: 0);
            }
            catch (RunnerGateException exception)
            {
                return Invalid(exception.ReasonCode, pendingCount: 1, invalidCount: 1, legacyIgnoredCount: 0);
            }
            catch
            {
                return Invalid("HOST_ACTION_EXECUTION_FAILED", pendingCount: 1, invalidCount: 1, legacyIgnoredCount: 0);
            }
        }

        RunnerActionInboxSnapshot catalog;
        try
        {
            catalog = inbox.Locate(engineeringRoot, activatedAtUtc);
        }
        catch (RunnerGateException exception)
        {
            return Invalid(exception.ReasonCode, pendingCount: 0, invalidCount: 1, legacyIgnoredCount: 0);
        }
        catch
        {
            return Invalid("ACTION_INBOX_UNREADABLE", pendingCount: 0, invalidCount: 1, legacyIgnoredCount: 0);
        }

        var resultEntries = catalog.Entries
            .Where(entry => entry.State == RunnerInboxEntryState.ResultReady)
            .ToArray();
        if (resultEntries.Length > 1)
        {
            return new HostActionStatus
            {
                State = HostActionStates.Ambiguous,
                ReasonCode = "ACTION_RESULT_QUEUE_AMBIGUOUS",
                PendingCount = catalog.Entries.Count(entry => entry.State != RunnerInboxEntryState.ResultReady),
                InvalidCount = catalog.Issues.Count,
                LegacyIgnoredCount = catalog.LegacyIgnoredCount
            };
        }
        if (resultEntries.Length == 1)
        {
            var entry = resultEntries[0];
            return new HostActionStatus
            {
                State = HostActionStates.ResultReady,
                ReasonCode = "HOST_ACTION_RESULT_READY",
                OperationId = entry.OperationId,
                ActionId = entry.ActionId,
                ActionKind = entry.ActionKind,
                ActionSha256 = entry.ActionSha256,
                RunId = entry.RunId,
                ResultState = entry.ResultState,
                ResultPath = entry.ResultPath,
                EvidencePath = entry.EvidencePath,
                PendingCount = catalog.Entries.Count(entry => entry.State != RunnerInboxEntryState.ResultReady),
                InvalidCount = catalog.Issues.Count,
                LegacyIgnoredCount = catalog.LegacyIgnoredCount
            };
        }

        // A malformed non-legacy ledger blocks all new execution. A valid
        // candidate must never hide a second operation that failed validation.
        if (catalog.Issues.Count > 0)
        {
            return Invalid(
                catalog.Issues[0].ReasonCode,
                catalog.Entries.Count(entry => entry.State != RunnerInboxEntryState.ResultReady),
                catalog.Issues.Count,
                catalog.LegacyIgnoredCount);
        }

        var recovery = catalog.Entries
            .Where(entry => entry.State == RunnerInboxEntryState.RecoveryPending)
            .ToArray();
        var pending = catalog.Entries
            .Where(entry => entry.State == RunnerInboxEntryState.Pending)
            .ToArray();
        var candidates = recovery.Length > 0 ? recovery : pending;
        var pendingCount = recovery.Length + pending.Length;
        if (candidates.Length > 1)
        {
            return new HostActionStatus
            {
                State = HostActionStates.Ambiguous,
                ReasonCode = "ACTION_QUEUE_AMBIGUOUS",
                PendingCount = pendingCount,
                InvalidCount = catalog.Issues.Count,
                LegacyIgnoredCount = catalog.LegacyIgnoredCount
            };
        }

        if (candidates.Length == 0)
        {
            return new HostActionStatus
            {
                State = HostActionStates.None,
                ReasonCode = "HOST_NO_PENDING_ACTION",
                PendingCount = 0,
                InvalidCount = 0,
                LegacyIgnoredCount = catalog.LegacyIgnoredCount
            };
        }

        var selected = candidates[0];
        if (!agentAvailable)
        {
            return ForEntry(
                selected,
                HostActionStates.WaitingForAgent,
                "HOST_WAITING_FOR_AGENT",
                pendingCount,
                catalog.Issues.Count,
                catalog.LegacyIgnoredCount);
        }

        try
        {
            var execution = executor.ExecuteAsync(selected, cancellationToken)
                ?? throw new RunnerGateException(
                    "HOST_ACTION_EXECUTION_FAILED",
                    "Runner Host action executor returned no task.");
            activeEntry = selected;
            activeTask = execution;
        }
        catch (RunnerGateException exception) when (IsPending(exception.ReasonCode))
        {
            return ForEntry(
                selected,
                PendingActionState(exception),
                PendingStatusReason(exception),
                pendingCount,
                catalog.Issues.Count,
                catalog.LegacyIgnoredCount);
        }
        catch (RunnerGateException exception)
        {
            return Invalid(
                exception.ReasonCode,
                pendingCount,
                catalog.Issues.Count + 1,
                catalog.LegacyIgnoredCount);
        }
        catch
        {
            return Invalid(
                "HOST_ACTION_EXECUTION_FAILED",
                pendingCount,
                catalog.Issues.Count + 1,
                catalog.LegacyIgnoredCount);
        }
        return ForEntry(
            selected,
            selected.State == RunnerInboxEntryState.RecoveryPending
                ? HostActionStates.RecoveryPending
                : HostActionStates.Executing,
            selected.State == RunnerInboxEntryState.RecoveryPending
                ? "HOST_ACTION_RECOVERY_STARTED"
                : "HOST_ACTION_EXECUTION_STARTED",
            pendingCount,
            catalog.Issues.Count,
            catalog.LegacyIgnoredCount);
    }

    public async Task<bool> DrainAsync(TimeSpan timeout)
    {
        var task = activeTask;
        if (task is null)
        {
            return true;
        }

        try
        {
            await task.WaitAsync(timeout).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException)
        {
            return false;
        }
        catch
        {
            // Runner cancellation/pending keeps claim.json as the recovery
            // anchor. Host shutdown must not invent or overwrite a terminal.
            return true;
        }
    }

    private static HostActionStatus ResultReady(
        RunnerInboxEntry entry,
        RunnerExecutionResult result,
        int pendingCount,
        int invalidCount,
        int legacyIgnoredCount) => new()
    {
        State = HostActionStates.ResultReady,
        ReasonCode = "HOST_ACTION_RESULT_READY",
        OperationId = entry.OperationId,
        ActionId = entry.ActionId,
        ActionKind = entry.ActionKind,
        ActionSha256 = entry.ActionSha256,
        RunId = result.RunId,
        ResultState = result.State,
        ResultPath = result.ResultPath,
        EvidencePath = result.EvidencePath,
        PendingCount = pendingCount,
        InvalidCount = invalidCount,
        LegacyIgnoredCount = legacyIgnoredCount
    };

    private static HostActionStatus ForEntry(
        RunnerInboxEntry entry,
        string state,
        string reasonCode,
        int pendingCount,
        int invalidCount,
        int legacyIgnoredCount) => new()
    {
        State = state,
        ReasonCode = reasonCode,
        OperationId = entry.OperationId,
        ActionId = entry.ActionId,
        ActionKind = entry.ActionKind,
        ActionSha256 = entry.ActionSha256,
        RunId = entry.RunId,
        PendingCount = pendingCount,
        InvalidCount = invalidCount,
        LegacyIgnoredCount = legacyIgnoredCount
    };

    private static HostActionStatus Invalid(
        string reasonCode,
        int pendingCount,
        int invalidCount,
        int legacyIgnoredCount) => new()
    {
        State = HostActionStates.Invalid,
        ReasonCode = SafeReason(reasonCode),
        PendingCount = pendingCount,
        InvalidCount = invalidCount,
        LegacyIgnoredCount = legacyIgnoredCount
    };

    private static bool IsPending(string reasonCode) => reasonCode is
        "BROKER_OPERATION_PENDING" or
        "BROKER_RECOVERY_PENDING" or
        "BROKER_SESSION_PENDING";

    private static string PendingActionState(RunnerGateException exception) =>
        exception.ReasonCode == "BROKER_SESSION_PENDING" ||
        exception.DiagnosticReasonCode is not null
            ? HostActionStates.WaitingForAgent
            : HostActionStates.RecoveryPending;

    private static string PendingStatusReason(RunnerGateException exception) =>
        SafeReason(exception.DiagnosticReasonCode ?? exception.ReasonCode);

    private static string SafeReason(string value) =>
        value.Length is > 0 and <= 96 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-')
            ? value
            : "HOST_ACTION_INVALID";
}
