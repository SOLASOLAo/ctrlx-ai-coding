using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public sealed class RunnerActionValidator
{
    private static readonly HashSet<string> SupportedReadOnlyKinds = new(StringComparer.Ordinal)
    {
        "inspect_and_build",
        "verify_after_export_2"
    };

    public ValidatedRunnerAction Validate(string engineeringRoot, string actionPath, string expectedActionSha256)
    {
        var root = RunnerValidation.FullPath(engineeringRoot);
        if (!Directory.Exists(root))
        {
            throw new RunnerGateException("ENGINEERING_ROOT_NOT_FOUND", $"Engineering root does not exist: {root}");
        }

        if (!RunnerValidation.IsSha256(expectedActionSha256))
        {
            throw new RunnerGateException("ACTION_HASH_INVALID", "Expected action SHA-256 must contain exactly 64 hexadecimal characters.");
        }

        var allowedActionRoot = Path.Combine(root, "data", "operations");
        var resolvedActionPath = RunnerValidation.EnsureInside(allowedActionRoot, actionPath, "Runner action");
        if (!File.Exists(resolvedActionPath))
        {
            throw new RunnerGateException("ACTION_NOT_FOUND", $"Runner action does not exist: {resolvedActionPath}");
        }

        var actualSha256 = RunnerHash.Sha256File(resolvedActionPath);
        if (!actualSha256.Equals(expectedActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("ACTION_HASH_MISMATCH", "Immutable action SHA-256 does not match the expected ledger hash.");
        }

        var action = RunnerJson.ReadObject(resolvedActionPath, "Runner action");
        RunnerValidation.AssertNoSensitiveFields(action);
        RunnerValidation.RequireOnly(
            action,
            "Runner action",
            "schemaVersion",
            "kind",
            "operationId",
            "actionId",
            "actionKind",
            "sequence",
            "createdAtUtc",
            "status",
            "source",
            "project",
            "preconditions",
            "guardrails",
            "changeSet",
            "instructions",
            "evidenceContract");

        if (RunnerValidation.RequiredInt32(action, "schemaVersion", "Runner action") != 1 ||
            RunnerValidation.RequiredString(action, "kind", "Runner action") != "ctrlx-opcon-runner-request" ||
            RunnerValidation.RequiredString(action, "status", "Runner action") != "WAITING_FOR_RUNNER")
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", "Runner action schemaVersion/kind/status is not supported.");
        }

        var operationId = RunnerValidation.RequiredString(action, "operationId", "Runner action");
        var actionId = RunnerValidation.RequiredString(action, "actionId", "Runner action");
        var actionKind = RunnerValidation.RequiredString(action, "actionKind", "Runner action");
        var sequence = RunnerValidation.RequiredInt32(action, "sequence", "Runner action");
        if (!RunnerValidation.IsSafeIdentifier(operationId) ||
            !RunnerValidation.IsSafeIdentifier(actionId) ||
            sequence <= 0 ||
            !actionId.Equals($"{operationId}-{sequence:0000}", StringComparison.Ordinal))
        {
            throw new RunnerGateException("ACTION_IDENTITY_INVALID", "Runner operation/action identity or sequence is malformed.");
        }

        var createdAtText = RunnerValidation.RequiredString(action, "createdAtUtc", "Runner action");
        if (!DateTimeOffset.TryParse(createdAtText, out var createdAtUtc) ||
            createdAtUtc > DateTimeOffset.UtcNow.AddMinutes(5))
        {
            throw new RunnerGateException("ACTION_TIME_INVALID", "Runner action createdAtUtc is invalid or too far in the future.");
        }

        var project = RunnerValidation.RequiredObject(action, "project", "Runner action");
        RunnerValidation.RequireOnly(project, "Runner action project", "engineeringRoot", "stationRoot", "plcProject", "profile");
        var actionEngineeringRoot = RunnerValidation.FullPath(RunnerValidation.RequiredString(project, "engineeringRoot", "Runner action project"));
        if (!actionEngineeringRoot.Equals(root, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("ENGINEERING_ROOT_MISMATCH", "Runner action engineeringRoot does not match the requested project.");
        }

        var stationRoot = RunnerValidation.FullPath(RunnerValidation.RequiredString(project, "stationRoot", "Runner action project"));
        if (!Directory.Exists(stationRoot))
        {
            throw new RunnerGateException("STATION_ROOT_NOT_FOUND", $"Runner action Station root does not exist: {stationRoot}");
        }

        var plcProject = RunnerValidation.EnsureInside(
            stationRoot,
            RunnerValidation.RequiredString(project, "plcProject", "Runner action project"),
            "Runner action PLC project");
        if (!File.Exists(plcProject))
        {
            throw new RunnerGateException("PLC_PROJECT_NOT_FOUND", $"Runner action PLC project does not exist: {plcProject}");
        }

        var profile = RunnerValidation.RequiredString(project, "profile", "Runner action project");

        var source = RunnerValidation.RequiredObject(action, "source", "Runner action");
        RunnerValidation.RequireOnly(source, "Runner action source", "stage1RequestId", "auditReport", "auditReportSha256", "export2Audit");
        _ = RunnerValidation.RequiredString(source, "stage1RequestId", "Runner action source");
        var auditPath = RunnerValidation.EnsureInside(
            Path.Combine(root, "data", "reports"),
            RunnerValidation.RequiredString(source, "auditReport", "Runner action source"),
            "Stage 1 audit report");
        ValidateFileHash(auditPath, RunnerValidation.RequiredString(source, "auditReportSha256", "Runner action source"), "Stage 1 audit report");

        var preconditions = RunnerValidation.RequiredObject(action, "preconditions", "Runner action");
        RunnerValidation.RequireOnly(
            preconditions,
            "Runner action preconditions",
            "workflowRevision",
            "idempotencyKey",
            "manifests",
            "fingerprints",
            "warningBaseline",
            "semanticBaseline",
            "semanticSnapshotRequest");
        _ = RunnerValidation.RequiredString(preconditions, "workflowRevision", "Runner action preconditions");
        var idempotencyKey = RunnerValidation.RequiredString(preconditions, "idempotencyKey", "Runner action preconditions");
        if (!RunnerValidation.IsSha256(idempotencyKey))
        {
            throw new RunnerGateException("IDEMPOTENCY_KEY_INVALID", "Runner action idempotencyKey must be a SHA-256 value.");
        }

        var manifests = RunnerValidation.RequiredArray(preconditions, "manifests", "Runner action preconditions");
        foreach (var item in manifests)
        {
            ValidateFingerprint(root, RequireObjectItem(item, "Ownership manifest"), "Ownership manifest");
        }

        ValidateReviewedArtifactReference(
            root,
            preconditions["warningBaseline"],
            "config/warning-signature-baseline.json",
            "warningBaseline");
        ValidateReviewedArtifactReference(
            root,
            preconditions["semanticBaseline"],
            "config/engineering-semantic-baseline.json",
            "semanticBaseline");
        ValidateSnapshotScopeReference(root, preconditions["semanticSnapshotRequest"]);

        var fingerprints = RunnerValidation.RequiredArray(preconditions, "fingerprints", "Runner action preconditions");
        if (actionKind == "verify_after_export_2")
        {
            if (source["export2Audit"] is not JsonObject export2Audit)
            {
                throw new RunnerGateException("EXPORT2_AUDIT_MISSING", "verify_after_export_2 has no bound Export #2 audit.");
            }

            RunnerValidation.RequireOnly(export2Audit, "Export #2 audit reference", "requestId", "path", "sha256");
            _ = RunnerValidation.RequiredString(export2Audit, "requestId", "Export #2 audit reference");
            var export2Path = RunnerValidation.EnsureInside(
                Path.Combine(root, "data", "reports"),
                RunnerValidation.RequiredString(export2Audit, "path", "Export #2 audit reference"),
                "Export #2 audit report");
            ValidateFileHash(export2Path, RunnerValidation.RequiredString(export2Audit, "sha256", "Export #2 audit reference"), "Export #2 audit report");
            var export2Document = RunnerJson.ReadObject(export2Path, "Export #2 audit report");
            fingerprints = RunnerValidation.RequiredArray(export2Document, "fingerprints", "Export #2 audit report");
        }
        else if (source["export2Audit"] is not null)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", "Only verify_after_export_2 may bind an Export #2 audit.");
        }

        var plcRelativePath = Path.GetRelativePath(stationRoot, plcProject).Replace('\\', '/');
        ValidateRequiredFingerprint(fingerprints, stationRoot, "Engineering/Engineering_Data.xml");
        if (actionKind is "inspect_and_build" or "verify_after_export_2")
        {
            ValidateRequiredFingerprint(fingerprints, stationRoot, plcRelativePath);
        }

        ValidateGuardrails(RunnerValidation.RequiredObject(action, "guardrails", "Runner action"));
        ValidateEvidenceContract(RunnerValidation.RequiredObject(action, "evidenceContract", "Runner action"));

        var changeSet = RunnerValidation.RequiredArray(action, "changeSet", "Runner action");
        var instructions = RunnerValidation.RequiredArray(action, "instructions", "Runner action");
        if (instructions.Any(item => item is null || item.GetValueKind() != System.Text.Json.JsonValueKind.String))
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", "Runner action instructions must contain only strings.");
        }

        var knownKind = actionKind is "inspect_and_build" or "apply_change_set_and_build" or "verify_after_export_2";
        if (!knownKind)
        {
            throw new RunnerGateException("ACTION_KIND_INVALID", $"Unsupported runner action kind: {actionKind}");
        }

        if (SupportedReadOnlyKinds.Contains(actionKind) && changeSet.Count != 0)
        {
            throw new RunnerGateException("ACTION_SCHEMA_INVALID", "Inspect/verify actions must have an empty changeSet.");
        }

        ValidateOperationLedger(
            root,
            resolvedActionPath,
            actualSha256,
            operationId,
            actionId,
            actionKind,
            sequence,
            createdAtText,
            idempotencyKey,
            stationRoot,
            plcProject,
            profile,
            RunnerValidation.RequiredString(preconditions, "workflowRevision", "Runner action preconditions"));

        var isSupported = SupportedReadOnlyKinds.Contains(actionKind);
        return new ValidatedRunnerAction(
            root,
            stationRoot,
            plcProject,
            profile,
            resolvedActionPath,
            actualSha256,
            operationId,
            actionId,
            actionKind,
            sequence,
            createdAtUtc.ToUniversalTime(),
            idempotencyKey.ToUpperInvariant(),
            isSupported,
            isSupported ? null : "BLOCKED_UNSUPPORTED_ACTION",
            action);
    }

    private static void ValidateOperationLedger(
        string engineeringRoot,
        string actionPath,
        string actionSha256,
        string operationId,
        string actionId,
        string actionKind,
        int sequence,
        string createdAtText,
        string idempotencyKey,
        string stationRoot,
        string plcProject,
        string profile,
        string workflowRevision)
    {
        var actionsDirectory = Path.GetDirectoryName(actionPath)
            ?? throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner action has no actions directory.");
        if (!Path.GetFileName(actionsDirectory).Equals("actions", StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner action is not stored in an operation actions directory.");
        }

        var operationDirectory = Directory.GetParent(actionsDirectory)?.FullName
            ?? throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner action has no operation directory.");
        if (!Path.GetFileName(operationDirectory).Equals(operationId, StringComparison.Ordinal))
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner operation directory does not match operationId.");
        }

        var operationPath = RunnerValidation.EnsureInside(
            Path.Combine(engineeringRoot, "data", "operations"),
            Path.Combine(operationDirectory, "operation.json"),
            "Runner operation ledger");
        var operation = RunnerJson.ReadObject(operationPath, "Runner operation ledger");
        RunnerValidation.AssertNoSensitiveFields(operation);
        if (RunnerValidation.RequiredInt32(operation, "schemaVersion", "Runner operation ledger") != 1 ||
            RunnerValidation.RequiredString(operation, "kind", "Runner operation ledger") != "ctrlx-opcon-post-export-operation" ||
            RunnerValidation.RequiredString(operation, "operationId", "Runner operation ledger") != operationId ||
            RunnerValidation.RequiredString(operation, "status", "Runner operation ledger") != "WAITING_FOR_RUNNER" ||
            RunnerValidation.RequiredString(operation, "workflowRevision", "Runner operation ledger") != workflowRevision)
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner operation ledger is not waiting for this workflow/action.");
        }

        var operationIdempotency = RunnerValidation.RequiredObject(operation, "idempotency", "Runner operation ledger");
        if (!RunnerValidation.RequiredString(operationIdempotency, "key", "Runner operation idempotency")
                .Equals(idempotencyKey, StringComparison.OrdinalIgnoreCase) ||
            RunnerValidation.RequiredString(operationIdempotency, "algorithm", "Runner operation idempotency") != "SHA256")
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner operation idempotency does not match the action.");
        }

        var identity = RunnerValidation.RequiredObject(operation, "identity", "Runner operation ledger");
        if (!RunnerValidation.FullPath(RunnerValidation.RequiredString(identity, "engineeringRoot", "Runner operation identity"))
                .Equals(engineeringRoot, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.FullPath(RunnerValidation.RequiredString(identity, "stationRoot", "Runner operation identity"))
                .Equals(stationRoot, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.FullPath(RunnerValidation.RequiredString(identity, "plcProject", "Runner operation identity"))
                .Equals(plcProject, StringComparison.OrdinalIgnoreCase) ||
            RunnerValidation.RequiredString(identity, "profile", "Runner operation identity") != profile)
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner operation project identity does not match the action.");
        }

        var currentAction = RunnerValidation.RequiredObject(operation, "currentAction", "Runner operation ledger");
        RunnerValidation.RequireOnly(
            currentAction,
            "Runner operation currentAction",
            "actionId",
            "kind",
            "sequence",
            "createdAtUtc",
            "path",
            "sha256");
        if (RunnerValidation.RequiredString(currentAction, "actionId", "Runner operation currentAction") != actionId ||
            RunnerValidation.RequiredString(currentAction, "kind", "Runner operation currentAction") != actionKind ||
            RunnerValidation.RequiredInt32(currentAction, "sequence", "Runner operation currentAction") != sequence ||
            RunnerValidation.RequiredString(currentAction, "createdAtUtc", "Runner operation currentAction") != createdAtText ||
            !RunnerValidation.FullPath(RunnerValidation.RequiredString(currentAction, "path", "Runner operation currentAction"))
                .Equals(actionPath, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.RequiredString(currentAction, "sha256", "Runner operation currentAction")
                .Equals(actionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("OPERATION_LEDGER_INVALID", "Runner action is not the ledger's exact currentAction.");
        }
    }

    private static void ValidateGuardrails(JsonObject guardrails)
    {
        RunnerValidation.RequireOnly(
            guardrails,
            "Runner action guardrails",
            "offlineOnly",
            "onlineOperationsAllowed",
            "requireExistingPersistentSession",
            "prohibitPleOrMcpStartByAction",
            "prohibitDirectWatcherIpc",
            "requireExactProjectOpen",
            "actionProjectGateRequired",
            "releaseActionProjectGateBeforeTerminalDelivery",
            "symbolAccessSerialized",
            "actionProjectGateKind");

        if (!RunnerValidation.RequiredBoolean(guardrails, "offlineOnly", "Runner action guardrails") ||
            RunnerValidation.RequiredBoolean(guardrails, "onlineOperationsAllowed", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "requireExistingPersistentSession", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "prohibitPleOrMcpStartByAction", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "prohibitDirectWatcherIpc", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "requireExactProjectOpen", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "actionProjectGateRequired", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "releaseActionProjectGateBeforeTerminalDelivery", "Runner action guardrails") ||
            !RunnerValidation.RequiredBoolean(guardrails, "symbolAccessSerialized", "Runner action guardrails") ||
            RunnerValidation.RequiredString(guardrails, "actionProjectGateKind", "Runner action guardrails") !=
                "broker-session-action-serialization")
        {
            throw new RunnerGateException("ACTION_GUARDRAIL_INVALID", "Runner action does not contain the required offline/single-session guardrails.");
        }
    }

    private static void ValidateEvidenceContract(JsonObject contract)
    {
        RunnerValidation.RequireOnly(
            contract,
            "Runner action evidenceContract",
            "schemaVersion",
            "requireActionRequestSha256",
            "requireOfflineOnly",
            "requireActionProjectGateReleased",
            "requireReadbackOnSuccess",
            "requireFreshBuildOnSuccess",
            "terminalFailureMayOmitBuild",
            "warningComparison");
        if (RunnerValidation.RequiredInt32(contract, "schemaVersion", "Runner action evidenceContract") != 1 ||
            !RunnerValidation.RequiredBoolean(contract, "requireActionRequestSha256", "Runner action evidenceContract") ||
            !RunnerValidation.RequiredBoolean(contract, "requireOfflineOnly", "Runner action evidenceContract") ||
            !RunnerValidation.RequiredBoolean(contract, "requireActionProjectGateReleased", "Runner action evidenceContract") ||
            !RunnerValidation.RequiredBoolean(contract, "requireReadbackOnSuccess", "Runner action evidenceContract") ||
            !RunnerValidation.RequiredBoolean(contract, "requireFreshBuildOnSuccess", "Runner action evidenceContract") ||
            !RunnerValidation.RequiredBoolean(contract, "terminalFailureMayOmitBuild", "Runner action evidenceContract") ||
            RunnerValidation.RequiredString(contract, "warningComparison", "Runner action evidenceContract") != "signature-multiset-not-count-only")
        {
            throw new RunnerGateException("EVIDENCE_CONTRACT_INVALID", "Runner action evidence contract is not supported.");
        }
    }

    private static void ValidateReviewedArtifactReference(
        string engineeringRoot,
        JsonNode? referenceNode,
        string requiredRelativePath,
        string referenceName)
    {
        var invalidReason = referenceName == "semanticBaseline"
            ? "SEMANTIC_BASELINE_REFERENCE_INVALID"
            : "WARNING_BASELINE_REFERENCE_INVALID";
        var displayName = referenceName == "semanticBaseline"
            ? "semantic baseline"
            : "warning baseline";

        // Older Stage 2 producers do not emit this optional reference. Treat
        // its absence as bootstrap mode so inspect_and_build can still collect
        // a fresh warning multiset, but it cannot later claim reviewed warning
        // acceptance.
        if (referenceNode is null)
        {
            return;
        }

        if (referenceNode is not JsonObject reference)
        {
            throw new RunnerGateException(
                invalidReason,
                $"Runner action preconditions.{referenceName} must be an object.");
        }

        RunnerValidation.RequireOnly(
            reference,
            $"Runner action {referenceName}",
            "state",
            "path",
            "sha256",
            "reviewEvidence");
        var state = RunnerValidation.RequiredString(reference, "state", $"Runner action {referenceName}");
        var relativePath = RunnerValidation.RequiredString(reference, "path", $"Runner action {referenceName}")
            .Replace('\\', '/');
        if (!relativePath.Equals(requiredRelativePath, StringComparison.Ordinal))
        {
            throw new RunnerGateException(
                invalidReason,
                $"Runner {referenceName} must use {requiredRelativePath}.");
        }

        var baselinePath = RunnerValidation.EnsureInside(
            engineeringRoot,
            Path.Combine(engineeringRoot, relativePath),
            $"Runner {referenceName}");
        if (state == "missing-bootstrap")
        {
            if (reference["sha256"] is not null || reference["reviewEvidence"] is not null)
            {
                throw new RunnerGateException(
                    invalidReason,
                    $"A missing-bootstrap {referenceName} cannot carry accepted SHA/review evidence.");
            }

            return;
        }

        if (state != "reviewed")
        {
            throw new RunnerGateException(
                invalidReason,
                $"Unsupported {displayName} state '{state}'.");
        }

        var expectedSha = RunnerValidation.RequiredString(reference, "sha256", $"Runner action {referenceName}");
        ValidateFileHash(baselinePath, expectedSha, $"Reviewed {referenceName}");
        var review = RunnerValidation.RequiredObject(reference, "reviewEvidence", $"Runner action {referenceName}");
        RunnerValidation.RequireOnly(review, $"Runner action {referenceName} reviewEvidence", "path", "sha256");
        var reviewPath = RunnerValidation.EnsureInside(
            engineeringRoot,
            Path.Combine(
                engineeringRoot,
                RunnerValidation.RequiredString(review, "path", $"Runner action {referenceName} reviewEvidence")),
            $"Runner {referenceName} review evidence");
        ValidateFileHash(
            reviewPath,
            RunnerValidation.RequiredString(review, "sha256", $"Runner action {referenceName} reviewEvidence"),
            $"Reviewed {referenceName} provenance");
    }

    private static void ValidateSnapshotScopeReference(string engineeringRoot, JsonNode? referenceNode)
    {
        if (referenceNode is null)
        {
            return;
        }

        if (referenceNode is not JsonObject reference)
        {
            throw new RunnerGateException(
                "SEMANTIC_SCOPE_REFERENCE_INVALID",
                "Runner action preconditions.semanticSnapshotRequest must be an object.");
        }

        RunnerValidation.RequireOnly(reference, "Runner semanticSnapshotRequest", "path", "sha256");
        var relativePath = RunnerValidation.RequiredString(reference, "path", "Runner semanticSnapshotRequest")
            .Replace('\\', '/');
        if (relativePath != "config/engineering-semantic-scope.json")
        {
            throw new RunnerGateException(
                "SEMANTIC_SCOPE_REFERENCE_INVALID",
                "Runner semantic snapshot scope must use config/engineering-semantic-scope.json.");
        }

        var path = RunnerValidation.EnsureInside(
            engineeringRoot,
            Path.Combine(engineeringRoot, relativePath),
            "Engineering semantic snapshot scope");
        ValidateFileHash(
            path,
            RunnerValidation.RequiredString(reference, "sha256", "Runner semanticSnapshotRequest"),
            "Engineering semantic snapshot scope");
    }

    private static void ValidateRequiredFingerprint(JsonArray fingerprints, string root, string requiredPath)
    {
        var matches = fingerprints
            .OfType<JsonObject>()
            .Where(item =>
                item["path"] is JsonValue pathValue &&
                pathValue.TryGetValue<string>(out var path) &&
                path.Replace('\\', '/').Equals(requiredPath, StringComparison.Ordinal))
            .ToArray();
        if (matches.Length != 1)
        {
            throw new RunnerGateException("FINGERPRINT_MISSING", $"Runner action does not contain one required Station fingerprint: {requiredPath}");
        }

        ValidateFingerprint(root, matches[0], "Station fingerprint");
    }

    private static void ValidateFingerprint(string root, JsonObject record, string kind)
    {
        RunnerValidation.RequireOnly(record, $"{kind} record", "path", "exists", "sizeBytes", "lastWriteTimeUtc", "sha256");
        var relativePath = RunnerValidation.RequiredString(record, "path", $"{kind} record");
        var fullPath = RunnerValidation.EnsureInside(root, Path.Combine(root, relativePath), $"{kind} path");
        var expectedExists = RunnerValidation.RequiredBoolean(record, "exists", $"{kind} record");
        if (File.Exists(fullPath) != expectedExists)
        {
            throw new RunnerGateException("FINGERPRINT_DRIFT", $"{kind} existence drifted: {relativePath}");
        }

        if (expectedExists)
        {
            var expectedSha = RunnerValidation.RequiredString(record, "sha256", $"{kind} record");
            ValidateFileHash(fullPath, expectedSha, $"{kind} '{relativePath}'");
        }
    }

    private static void ValidateFileHash(string path, string expectedSha256, string description)
    {
        if (!File.Exists(path) || !RunnerValidation.IsSha256(expectedSha256))
        {
            throw new RunnerGateException("FINGERPRINT_DRIFT", $"{description} is missing or has an invalid expected hash.");
        }

        var actual = RunnerHash.Sha256File(path);
        if (!actual.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("FINGERPRINT_DRIFT", $"{description} SHA-256 drifted.");
        }
    }

    private static JsonObject RequireObjectItem(JsonNode? item, string description) =>
        item as JsonObject ?? throw new RunnerGateException("ACTION_SCHEMA_INVALID", $"{description} entry must be an object.");
}

internal static class JsonNodeExtensions
{
    public static System.Text.Json.JsonValueKind GetValueKind(this JsonNode node)
    {
        using var document = System.Text.Json.JsonDocument.Parse(node.ToJsonString());
        return document.RootElement.ValueKind;
    }
}
