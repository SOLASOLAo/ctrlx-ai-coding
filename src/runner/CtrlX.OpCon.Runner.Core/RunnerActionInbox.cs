using System.Text.Json;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public enum RunnerInboxEntryState
{
    Pending = 0,
    RecoveryPending = 1,
    ResultReady = 2
}

public sealed record RunnerInboxEntry(
    string OperationId,
    string ActionId,
    string ActionKind,
    int Sequence,
    DateTimeOffset CreatedAtUtc,
    DateTimeOffset LedgerLastWriteTimeUtc,
    string ActionPath,
    string ActionSha256,
    string RunId,
    string RunRoot,
    string ClaimPath,
    string ResultPath,
    RunnerInboxEntryState State,
    string? ResultState,
    string? EvidencePath);

public sealed record RunnerInboxIssue(string ReasonCode, string? OperationId);

public sealed record RunnerActionInboxSnapshot(
    IReadOnlyList<RunnerInboxEntry> Entries,
    IReadOnlyList<RunnerInboxIssue> Issues,
    int LegacyIgnoredCount);

/// <summary>
/// Locates only current actions named by CpStudio Stage 2 operation ledgers.
/// This is a bounded discovery layer; RunnerActionValidator remains the final
/// authority before an action can reach a Broker.
/// </summary>
public sealed class RunnerActionInbox
{
    private const int MaximumOperationCount = 2048;
    private const int MaximumJsonBytes = 1024 * 1024;
    private const int ReadAttempts = 6;
    private static readonly TimeSpan ReadRetryDelay = TimeSpan.FromMilliseconds(25);

    public RunnerActionInboxSnapshot Locate(string engineeringRoot, DateTimeOffset activatedAtUtc)
    {
        var root = RunnerValidation.FullPath(engineeringRoot);
        if (!Directory.Exists(root))
        {
            throw new RunnerGateException(
                "ENGINEERING_ROOT_NOT_FOUND",
                $"Engineering root does not exist: {root}");
        }

        var inboxRoot = Path.Combine(root, "data", "operations", "cpstudio-stage2");
        RunnerValidation.AssertExistingPathChainNotReparse(
            root,
            inboxRoot,
            "ACTION_INBOX_REPARSE_POINT",
            "Runner action inbox");
        if (!Directory.Exists(inboxRoot))
        {
            return new RunnerActionInboxSnapshot([], [], 0);
        }

        var operationDirectories = Directory.EnumerateDirectories(inboxRoot, "*", SearchOption.TopDirectoryOnly)
            .Take(MaximumOperationCount + 1)
            .ToArray();
        if (operationDirectories.Length > MaximumOperationCount)
        {
            return new RunnerActionInboxSnapshot(
                [],
                [new RunnerInboxIssue("ACTION_INBOX_LIMIT_EXCEEDED", null)],
                0);
        }

        var entries = new List<RunnerInboxEntry>();
        var issues = new List<RunnerInboxIssue>();
        var legacyIgnored = 0;
        foreach (var operationDirectory in operationDirectories)
        {
            var operationId = Path.GetFileName(operationDirectory);
            var operationPath = Path.Combine(operationDirectory, "operation.json");
            var lastWriteTimeUtc = File.Exists(operationPath)
                ? new DateTimeOffset(File.GetLastWriteTimeUtc(operationPath), TimeSpan.Zero)
                : DateTimeOffset.MinValue;
            var legacy = lastWriteTimeUtc <= activatedAtUtc;

            try
            {
                RunnerValidation.AssertExistingPathChainNotReparse(
                    root,
                    operationDirectory,
                    "ACTION_OPERATION_REPARSE_POINT",
                    "Runner operation directory");
                if (!File.Exists(operationPath))
                {
                    if (!legacy)
                    {
                        issues.Add(new RunnerInboxIssue("ACTION_OPERATION_MISSING", operationId));
                    }
                    continue;
                }

                RunnerValidation.AssertExistingPathChainNotReparse(
                    root,
                    operationPath,
                    "ACTION_OPERATION_REPARSE_POINT",
                    "Runner operation ledger");
                var operation = ReadBoundedObject(operationPath, "Runner operation ledger");
                if (RequiredInt32(operation, "schemaVersion") != 1 ||
                    RequiredString(operation, "kind") != "ctrlx-opcon-post-export-operation" ||
                    RequiredString(operation, "operationId") != operationId)
                {
                    throw new RunnerGateException(
                        "ACTION_OPERATION_INVALID",
                        "Runner operation identity is invalid.");
                }

                if (RequiredString(operation, "status") != "WAITING_FOR_RUNNER")
                {
                    continue;
                }

                var currentAction = operation["currentAction"] as JsonObject
                    ?? throw new RunnerGateException(
                        "ACTION_OPERATION_INVALID",
                        "WAITING_FOR_RUNNER operation has no currentAction.");
                var actionId = RequiredString(currentAction, "actionId");
                var actionKind = RequiredString(currentAction, "kind");
                var sequence = RequiredInt32(currentAction, "sequence");
                var createdAtText = RequiredString(currentAction, "createdAtUtc");
                var actionSha256 = RequiredString(currentAction, "sha256");
                if (!RunnerValidation.IsSafeIdentifier(operationId) ||
                    !RunnerValidation.IsSafeIdentifier(actionId) ||
                    !RunnerValidation.IsSafeIdentifier(actionKind) ||
                    sequence <= 0 ||
                    actionId != $"{operationId}-{sequence:0000}" ||
                    !RunnerValidation.IsSha256(actionSha256) ||
                    !DateTimeOffset.TryParse(createdAtText, out var createdAtUtc))
                {
                    throw new RunnerGateException(
                        "ACTION_OPERATION_INVALID",
                        "Runner currentAction identity is malformed.");
                }
                createdAtUtc = createdAtUtc.ToUniversalTime();
                legacy = legacy || createdAtUtc <= activatedAtUtc;

                var actionsRoot = Path.Combine(operationDirectory, "actions");
                var actionPath = RunnerValidation.EnsureInside(
                    actionsRoot,
                    RequiredString(currentAction, "path"),
                    "Runner currentAction path");
                var expectedName = $"{sequence:0000}-{actionKind}.json";
                if (!Path.GetFileName(actionPath).Equals(expectedName, StringComparison.Ordinal) ||
                    !Path.GetDirectoryName(actionPath)!.Equals(actionsRoot, StringComparison.OrdinalIgnoreCase))
                {
                    throw new RunnerGateException(
                        "ACTION_OPERATION_INVALID",
                        "Runner currentAction path is not the exact operation action file.");
                }

                var runId = RunnerRunStore.GetRunId(actionId, actionSha256);
                var runRoot = RunnerRunStore.GetRunRoot(root, actionId, actionSha256);
                var claimPath = Path.Combine(runRoot, "claim.json");
                var resultPath = Path.Combine(runRoot, "result.json");
                RunnerValidation.AssertExistingPathChainNotReparse(
                    root,
                    runRoot,
                    "RUN_DIRECTORY_REPARSE_POINT",
                    "Runner run directory");
                var hasClaim = File.Exists(claimPath);
                var hasResult = File.Exists(resultPath);

                string? resultState = null;
                string? evidencePath = null;
                DateTimeOffset? resultCompletedAtUtc = null;
                if (hasResult)
                {
                    RunnerValidation.AssertExistingPathChainNotReparse(
                        root,
                        resultPath,
                        "RUN_RESULT_REPARSE_POINT",
                        "Runner terminal result marker");
                    var result = ReadBoundedObject(resultPath, "Runner terminal result marker");
                    if (RequiredInt32(result, "schemaVersion") != 1 ||
                        RequiredString(result, "kind") != "ctrlx-opcon-runner-result" ||
                        RequiredString(result, "runId") != runId ||
                        RequiredString(result, "actionId") != actionId ||
                        !RequiredString(result, "actionSha256").Equals(actionSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new RunnerGateException(
                            "RUN_RESULT_MARKER_INVALID",
                            "Runner terminal result marker identity is invalid.");
                    }
                    resultState = RequiredString(result, "state");
                    if (!RunnerStates.IsTerminal(resultState))
                    {
                        throw new RunnerGateException(
                            "RUN_RESULT_MARKER_INVALID",
                            "Runner result marker is not terminal.");
                    }
                    if (!DateTimeOffset.TryParse(
                            RequiredString(result, "completedAtUtc"),
                            out var parsedCompletedAtUtc) ||
                        parsedCompletedAtUtc > DateTimeOffset.UtcNow + TimeSpan.FromMinutes(5))
                    {
                        throw new RunnerGateException(
                            "RUN_RESULT_MARKER_INVALID",
                            "Runner terminal result marker completion time is invalid.");
                    }
                    resultCompletedAtUtc = parsedCompletedAtUtc.ToUniversalTime();
                    if (result["evidencePath"] is JsonValue evidenceValue &&
                        evidenceValue.TryGetValue<string>(out var parsedEvidencePath) &&
                        !string.IsNullOrWhiteSpace(parsedEvidencePath))
                    {
                        evidencePath = RunnerValidation.EnsureInside(
                            Path.Combine(root, "data", "runner-evidence"),
                            parsedEvidencePath,
                            "Runner result evidence path");
                        RunnerValidation.AssertExistingPathChainNotReparse(
                            root,
                            evidencePath,
                            "RUN_EVIDENCE_REPARSE_POINT",
                            "Runner result evidence");
                    }
                }

                // First activation quarantines historical ledgers. An old open
                // claim without a terminal result remains recoverable. If that
                // recovery completes after activation, its new result remains
                // visible until the coordinator advances the operation ledger.
                var recoveredAfterActivation = hasClaim &&
                    resultCompletedAtUtc is not null &&
                    resultCompletedAtUtc > activatedAtUtc;
                if (legacy && (!hasClaim || (hasResult && !recoveredAfterActivation)))
                {
                    legacyIgnored++;
                    continue;
                }

                if (!hasResult)
                {
                    RunnerValidation.AssertExistingPathChainNotReparse(
                        root,
                        actionsRoot,
                        "ACTION_DIRECTORY_REPARSE_POINT",
                        "Runner action directory");
                    RunnerValidation.AssertExistingPathChainNotReparse(
                        root,
                        actionPath,
                        "ACTION_FILE_REPARSE_POINT",
                        "Runner action file");
                    var actionInfo = new FileInfo(actionPath);
                    if (!actionInfo.Exists || actionInfo.Length <= 0 || actionInfo.Length > MaximumJsonBytes)
                    {
                        throw new RunnerGateException(
                            "ACTION_FILE_INVALID",
                            "Runner action is missing, empty, or exceeds its size bound.");
                    }
                    if (!RunnerHash.Sha256File(actionPath).Equals(actionSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new RunnerGateException(
                            "ACTION_HASH_MISMATCH",
                            "Runner action SHA-256 does not match its operation ledger.");
                    }
                }

                entries.Add(new RunnerInboxEntry(
                    operationId,
                    actionId,
                    actionKind,
                    sequence,
                    createdAtUtc,
                    lastWriteTimeUtc,
                    actionPath,
                    actionSha256.ToUpperInvariant(),
                    runId,
                    runRoot,
                    claimPath,
                    resultPath,
                    hasResult
                        ? RunnerInboxEntryState.ResultReady
                        : hasClaim
                            ? RunnerInboxEntryState.RecoveryPending
                            : RunnerInboxEntryState.Pending,
                    resultState,
                    evidencePath));
            }
            catch (Exception exception) when (
                exception is RunnerGateException or
                IOException or
                UnauthorizedAccessException or
                JsonException or
                ArgumentException or
                NotSupportedException or
                PathTooLongException)
            {
                if (legacy)
                {
                    legacyIgnored++;
                }
                else
                {
                    var reasonCode = exception is RunnerGateException gate
                        ? SafeReason(gate.ReasonCode)
                        : "ACTION_OPERATION_UNREADABLE";
                    issues.Add(new RunnerInboxIssue(reasonCode, SafeOperationId(operationId)));
                }
            }
        }

        var ordered = entries
            .OrderBy(entry => entry.State == RunnerInboxEntryState.RecoveryPending ? 0 : 1)
            .ThenBy(entry => entry.CreatedAtUtc)
            .ThenBy(entry => entry.OperationId, StringComparer.Ordinal)
            .ThenBy(entry => entry.Sequence)
            .ToArray();
        return new RunnerActionInboxSnapshot(ordered, issues.ToArray(), legacyIgnored);
    }

    private static JsonObject ReadBoundedObject(string path, string description)
    {
        byte[] bytes;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    4096,
                    FileOptions.SequentialScan);
                var length = stream.Length;
                if (length <= 0 || length > MaximumJsonBytes)
                {
                    throw new RunnerGateException(
                        "ACTION_OPERATION_INVALID",
                        $"{description} is missing, empty, or exceeds its size bound.");
                }
                bytes = new byte[checked((int)length)];
                stream.ReadExactly(bytes);
                if (stream.Position != stream.Length)
                {
                    throw new IOException($"{description} changed while it was read.");
                }
                break;
            }
            catch (IOException) when (attempt < ReadAttempts)
            {
                Thread.Sleep(ReadRetryDelay);
            }
        }

        var node = JsonNode.Parse(bytes, nodeOptions: null, documentOptions: new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 64
        });
        return node as JsonObject
            ?? throw new RunnerGateException("ACTION_OPERATION_INVALID", $"{description} root must be an object.");
    }

    private static string RequiredString(JsonObject value, string property)
    {
        if (value[property] is JsonValue item && item.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text))
        {
            return text;
        }
        throw new RunnerGateException("ACTION_OPERATION_INVALID", $"Runner operation is missing string '{property}'.");
    }

    private static int RequiredInt32(JsonObject value, string property)
    {
        if (value[property] is JsonValue item && item.TryGetValue<int>(out var number))
        {
            return number;
        }
        throw new RunnerGateException("ACTION_OPERATION_INVALID", $"Runner operation is missing integer '{property}'.");
    }

    private static string SafeReason(string reasonCode) =>
        RunnerValidation.IsSafeIdentifier(reasonCode, 96)
            ? reasonCode
            : "ACTION_OPERATION_INVALID";

    private static string? SafeOperationId(string value) =>
        RunnerValidation.IsSafeIdentifier(value)
            ? value
            : null;
}
