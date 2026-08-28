using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public sealed class RunnerRunStore
{
    private readonly string eventsRoot;

    private RunnerRunStore(ValidatedRunnerAction action, string runRoot, string runId)
    {
        Action = action;
        RunId = runId;
        RunRoot = runRoot;
        ResultPath = Path.Combine(runRoot, "result.json");
        ClaimPath = Path.Combine(runRoot, "claim.json");
        ObservationPath = Path.Combine(runRoot, "observation.json");
        eventsRoot = Path.Combine(runRoot, "events");
    }

    public ValidatedRunnerAction Action { get; }

    public string RunId { get; }

    public string RunRoot { get; }

    public string ResultPath { get; }

    public string ClaimPath { get; }

    public string ObservationPath { get; }

    public static RunnerRunStore ForAction(ValidatedRunnerAction action)
    {
        var runId = GetRunId(action.ActionId, action.ActionSha256);
        var root = GetRunRoot(action.EngineeringRoot, action.ActionId, action.ActionSha256);
        return new RunnerRunStore(action, root, runId);
    }

    public static string GetRunId(string actionId, string actionSha256)
    {
        if (!RunnerValidation.IsSafeIdentifier(actionId) ||
            !RunnerValidation.IsSha256(actionSha256))
        {
            throw new RunnerGateException(
                "RUN_IDENTITY_INVALID",
                "Runner action identity or SHA-256 is malformed.");
        }

        return $"{actionId}-{actionSha256[..12].ToLowerInvariant()}-a001";
    }

    public static string GetRunRoot(string engineeringRoot, string actionId, string actionSha256)
    {
        var root = RunnerValidation.FullPath(engineeringRoot);
        var runRoot = Path.Combine(root, "data", "runs", "runner-p12");
        var candidate = RunnerValidation.EnsureInside(
            runRoot,
            Path.Combine(runRoot, GetRunId(actionId, actionSha256)),
            "Runner run directory");
        return RunnerValidation.AssertExistingPathChainNotReparse(
            root,
            candidate,
            "RUN_PATH_REPARSE_POINT",
            "Runner run directory");
    }

    public bool TryReadResult(out RunnerExecutionResult? result)
    {
        result = null;
        AssertSafeRunPath(ResultPath, "Runner result");
        if (!File.Exists(ResultPath))
        {
            return false;
        }

        var json = RunnerJson.ReadObject(ResultPath, "Runner result");
        ValidateResultIdentity(json);
        ValidateResultIntegrity(json);
        result = ParseResult(json, ResultPath, replayed: true);
        return true;
    }

    public bool TryCreateClaim(string transportName)
    {
        AssertSafeRunPath(RunRoot, "Runner run directory");
        Directory.CreateDirectory(RunRoot);
        Directory.CreateDirectory(eventsRoot);
        AssertSafeRunPath(ClaimPath, "Runner claim");
        AssertSafeRunPath(eventsRoot, "Runner event directory");
        var claim = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-claim",
            ["runId"] = RunId,
            ["actionId"] = Action.ActionId,
            ["actionKind"] = Action.ActionKind,
            ["actionPath"] = Action.ActionPath,
            ["actionSha256"] = Action.ActionSha256,
            ["idempotencyKey"] = Action.IdempotencyKey,
            ["transport"] = transportName,
            ["createdAtUtc"] = DateTimeOffset.UtcNow.ToString("O")
        };

        try
        {
            using var stream = new FileStream(ClaimPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            writer.Write(claim.ToJsonString(RunnerJson.SerializerOptions));
            writer.WriteLine();
            return true;
        }
        catch (IOException) when (File.Exists(ClaimPath))
        {
            ValidateExistingClaim();
            return false;
        }
    }

    public void AppendEvent(string state, string reasonCode)
    {
        AssertSafeRunPath(eventsRoot, "Runner event directory");
        Directory.CreateDirectory(eventsRoot);
        AssertSafeRunPath(eventsRoot, "Runner event directory");
        var next = Directory.EnumerateFiles(eventsRoot, "*.json", SearchOption.TopDirectoryOnly).Count() + 1;
        var path = Path.Combine(eventsRoot, $"{next:0000}-{state.ToLowerInvariant()}.json");
        RunnerJson.WriteAtomic(path, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["runId"] = RunId,
            ["sequence"] = next,
            ["state"] = state,
            ["reasonCode"] = reasonCode,
            ["atUtc"] = DateTimeOffset.UtcNow.ToString("O")
        }, overwrite: false);
    }

    public string WriteObservation(JsonObject observation)
    {
        AssertSafeRunPath(ObservationPath, "Runner observation");
        RunnerJson.WriteAtomic(ObservationPath, observation, overwrite: false);
        return RunnerHash.Sha256File(ObservationPath);
    }

    public RunnerExecutionResult Complete(
        string state,
        string reasonCode,
        int exitCode,
        string? observationSha256,
        EvidenceSealResult? evidence)
    {
        AssertSafeRunPath(ResultPath, "Runner result");
        var result = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-result",
            ["runId"] = RunId,
            ["state"] = state,
            ["reasonCode"] = reasonCode,
            ["exitCode"] = exitCode,
            ["actionId"] = Action.ActionId,
            ["actionKind"] = Action.ActionKind,
            ["actionPath"] = Action.ActionPath,
            ["actionSha256"] = Action.ActionSha256,
            ["idempotencyKey"] = Action.IdempotencyKey,
            ["observationPath"] = observationSha256 is null ? null : ObservationPath,
            ["observationSha256"] = observationSha256,
            ["evidencePath"] = evidence?.Path,
            ["evidenceSha256"] = evidence?.Sha256,
            ["producerStatus"] = evidence?.ProducerStatus,
            ["guardrails"] = new JsonObject
            {
                ["onlineOperationsUsed"] = false,
                ["pleOrMcpStartedByAction"] = false,
                ["secondPleStarted"] = false,
                ["directWatcherIpcUsed"] = false,
                ["deploymentAllowed"] = false
            },
            ["completedAtUtc"] = DateTimeOffset.UtcNow.ToString("O")
        };
        RunnerJson.WriteAtomic(ResultPath, result, overwrite: false);
        AppendEvent(state, reasonCode);
        return ParseResult(result, ResultPath, replayed: false);
    }

    public JsonObject Verify()
    {
        AssertSafeRunPath(ResultPath, "Runner result");
        if (!File.Exists(ResultPath))
        {
            throw new RunnerGateException("RUN_NOT_FOUND", $"Runner result does not exist: {ResultPath}");
        }

        var json = RunnerJson.ReadObject(ResultPath, "Runner result");
        var resultContractOk = true;
        try
        {
            ValidateResultIdentity(json);
            ValidateResultContract(json);
            ValidateArtifactContents(json);
        }
        catch (RunnerGateException)
        {
            resultContractOk = false;
        }

        var actionPath = RunnerValidation.RequiredString(json, "actionPath", "Runner result");
        var expectedActionSha = RunnerValidation.RequiredString(json, "actionSha256", "Runner result");
        var actionOk = File.Exists(actionPath) && RunnerHash.Sha256File(actionPath).Equals(expectedActionSha, StringComparison.OrdinalIgnoreCase);
        var observationOk = VerifyOptionalArtifact(json, "observationPath", "observationSha256", ObservationPath, requiredRoot: null);
        var evidenceOk = VerifyOptionalArtifact(
            json,
            "evidencePath",
            "evidenceSha256",
            expectedPath: null,
            requiredRoot: Path.Combine(Action.EngineeringRoot, "data", "runner-evidence"));
        var valid = resultContractOk && actionOk && observationOk && evidenceOk;
        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-verification",
            ["runId"] = RunId,
            ["valid"] = valid,
            ["resultContractValid"] = resultContractOk,
            ["actionHashValid"] = actionOk,
            ["observationHashValid"] = observationOk,
            ["evidenceHashValid"] = evidenceOk,
            ["verifiedAtUtc"] = DateTimeOffset.UtcNow.ToString("O")
        };
    }

    public static JsonObject ReadStatus(string engineeringRoot, string runId)
    {
        if (!RunnerValidation.IsSafeIdentifier(runId, 256))
        {
            throw new RunnerGateException("RUN_ID_INVALID", "Runner run-id is malformed.", RunnerExitCodes.Usage);
        }

        var root = Path.Combine(RunnerValidation.FullPath(engineeringRoot), "data", "runs", "runner-p12");
        var path = RunnerValidation.EnsureInside(root, Path.Combine(root, runId, "result.json"), "Runner result");
        RunnerValidation.AssertExistingPathChainNotReparse(
            engineeringRoot,
            path,
            "RUN_PATH_REPARSE_POINT",
            "Runner result");
        return RunnerJson.ReadObject(path, "Runner result");
    }

    public static JsonObject VerifyById(string engineeringRoot, string runId)
    {
        var result = ReadStatus(engineeringRoot, runId);
        var actionPath = RunnerValidation.RequiredString(result, "actionPath", "Runner result");
        var actionSha = RunnerValidation.RequiredString(result, "actionSha256", "Runner result");
        var action = new RunnerActionValidator().Validate(engineeringRoot, actionPath, actionSha);
        return ForAction(action).Verify();
    }

    private void ValidateExistingClaim()
    {
        AssertSafeRunPath(ClaimPath, "Runner claim");
        var claim = RunnerJson.ReadObject(ClaimPath, "Runner claim");
        if (RunnerValidation.RequiredString(claim, "actionId", "Runner claim") != Action.ActionId ||
            !RunnerValidation.RequiredString(claim, "actionSha256", "Runner claim").Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.RequiredString(claim, "idempotencyKey", "Runner claim").Equals(Action.IdempotencyKey, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("IDEMPOTENCY_CONFLICT", "Existing Runner claim does not match action identity/hash/idempotency key.");
        }
    }

    private void AssertSafeRunPath(string path, string description) =>
        RunnerValidation.AssertExistingPathChainNotReparse(
            Action.EngineeringRoot,
            path,
            "RUN_PATH_REPARSE_POINT",
            description);

    private void ValidateResultIdentity(JsonObject result)
    {
        if (RunnerValidation.RequiredInt32(result, "schemaVersion", "Runner result") != 1 ||
            RunnerValidation.RequiredString(result, "kind", "Runner result") != "ctrlx-opcon-runner-result" ||
            RunnerValidation.RequiredString(result, "runId", "Runner result") != RunId ||
            RunnerValidation.RequiredString(result, "actionId", "Runner result") != Action.ActionId ||
            RunnerValidation.RequiredString(result, "actionKind", "Runner result") != Action.ActionKind ||
            !RunnerValidation.RequiredString(result, "actionPath", "Runner result")
                .Equals(Action.ActionPath, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.RequiredString(result, "actionSha256", "Runner result")
                .Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase) ||
            !RunnerValidation.RequiredString(result, "idempotencyKey", "Runner result")
                .Equals(Action.IdempotencyKey, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("RUN_RESULT_IDENTITY_MISMATCH", "Existing Runner result does not match the immutable action/run identity.");
        }

        var state = RunnerValidation.RequiredString(result, "state", "Runner result");
        var reasonCode = RunnerValidation.RequiredString(result, "reasonCode", "Runner result");
        if (!RunnerStates.IsTerminal(state) || !RunnerValidation.IsSafeIdentifier(reasonCode, 96))
        {
            throw new RunnerGateException("RUN_RESULT_INVALID", "Existing Runner result is not a safe terminal record.");
        }
    }

    private void ValidateResultIntegrity(JsonObject result)
    {
        ValidateResultContract(result);
        if (!File.Exists(Action.ActionPath) ||
            !RunnerHash.Sha256File(Action.ActionPath).Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase) ||
            !VerifyOptionalArtifact(result, "observationPath", "observationSha256", ObservationPath, requiredRoot: null) ||
            !VerifyOptionalArtifact(
                result,
                "evidencePath",
                "evidenceSha256",
                expectedPath: null,
                requiredRoot: Path.Combine(Action.EngineeringRoot, "data", "runner-evidence")))
        {
            throw new RunnerGateException("RUN_RESULT_INTEGRITY_INVALID", "Existing Runner result or a bound artifact failed SHA/path verification.");
        }

        ValidateArtifactContents(result);
    }

    private void ValidateResultContract(JsonObject result)
    {
        RunnerValidation.RequireOnly(
            result,
            "Runner result",
            "schemaVersion",
            "kind",
            "runId",
            "state",
            "reasonCode",
            "exitCode",
            "actionId",
            "actionKind",
            "actionPath",
            "actionSha256",
            "idempotencyKey",
            "observationPath",
            "observationSha256",
            "evidencePath",
            "evidenceSha256",
            "producerStatus",
            "guardrails",
            "completedAtUtc");
        foreach (var property in new[]
        {
            "observationPath",
            "observationSha256",
            "evidencePath",
            "evidenceSha256",
            "producerStatus"
        })
        {
            if (!result.ContainsKey(property))
            {
                throw new RunnerGateException("RUN_RESULT_INVALID", $"Runner result is missing '{property}'.");
            }
        }

        var state = RunnerValidation.RequiredString(result, "state", "Runner result");
        var exitCode = RunnerValidation.RequiredInt32(result, "exitCode", "Runner result");
        var exitCodeOk = state switch
        {
            RunnerStates.Done => exitCode == RunnerExitCodes.Done,
            RunnerStates.Blocked => exitCode == RunnerExitCodes.Blocked,
            RunnerStates.Unknown => exitCode == RunnerExitCodes.GateFailure,
            RunnerStates.Failed => exitCode is RunnerExitCodes.GateFailure or RunnerExitCodes.InternalError,
            _ => false
        };
        if (!exitCodeOk ||
            !DateTimeOffset.TryParse(RunnerValidation.RequiredString(result, "completedAtUtc", "Runner result"), out _))
        {
            throw new RunnerGateException("RUN_RESULT_INVALID", "Runner result state/exitCode/time is inconsistent.");
        }

        var guardrails = RunnerValidation.RequiredObject(result, "guardrails", "Runner result");
        RunnerValidation.RequireOnly(
            guardrails,
            "Runner result guardrails",
            "onlineOperationsUsed",
            "pleOrMcpStartedByAction",
            "secondPleStarted",
            "directWatcherIpcUsed",
            "deploymentAllowed");
        foreach (var name in new[]
        {
            "onlineOperationsUsed",
            "pleOrMcpStartedByAction",
            "secondPleStarted",
            "directWatcherIpcUsed",
            "deploymentAllowed"
        })
        {
            if (RunnerValidation.RequiredBoolean(guardrails, name, "Runner result guardrails"))
            {
                throw new RunnerGateException("RUN_RESULT_GUARDRAIL_INVALID", $"Runner result reports prohibited guardrail '{name}'.");
            }
        }

        var observationPresent = result["observationPath"] is not null || result["observationSha256"] is not null;
        var evidencePresent = result["evidencePath"] is not null || result["evidenceSha256"] is not null;
        if ((state is RunnerStates.Done or RunnerStates.Blocked) && (!observationPresent || !evidencePresent))
        {
            throw new RunnerGateException("RUN_RESULT_INVALID", "Successful/blocked Runner results require observation and evidence artifacts.");
        }

        if (state == RunnerStates.Unknown && (observationPresent || evidencePresent))
        {
            throw new RunnerGateException("RUN_RESULT_INVALID", "UNKNOWN Runner results must not fabricate observation/evidence artifacts.");
        }

        if (evidencePresent)
        {
            var producerStatus = RunnerValidation.RequiredString(result, "producerStatus", "Runner result");
            if (producerStatus is not "WRITTEN" and not "UNCHANGED")
            {
                throw new RunnerGateException("RUN_RESULT_INVALID", "Runner evidence producer status is invalid.");
            }
        }
        else if (result["producerStatus"] is not null)
        {
            throw new RunnerGateException("RUN_RESULT_INVALID", "Runner result reports a producer status without evidence.");
        }
    }

    private void ValidateArtifactContents(JsonObject result)
    {
        var state = RunnerValidation.RequiredString(result, "state", "Runner result");
        var reasonCode = RunnerValidation.RequiredString(result, "reasonCode", "Runner result");
        if (result["observationPath"] is JsonValue observationPathValue &&
            observationPathValue.TryGetValue<string>(out var observationPath))
        {
            var observation = RunnerJson.ReadObject(observationPath, "Runner observation");
            ValidateArtifactIdentity(observation, "Runner observation");
            var observedStatus = RunnerValidation.RequiredString(observation, "status", "Runner observation");
            if ((state == RunnerStates.Done && observedStatus != "succeeded") ||
                (state == RunnerStates.Blocked && observedStatus != "blocked"))
            {
                throw new RunnerGateException("RUN_RESULT_ARTIFACT_MISMATCH", "Runner observation status does not match result state.");
            }
        }

        if (result["evidencePath"] is JsonValue evidencePathValue &&
            evidencePathValue.TryGetValue<string>(out var evidencePath))
        {
            var evidence = RunnerJson.ReadObject(evidencePath, "Runner evidence");
            ValidateArtifactIdentity(evidence, "Runner evidence");
            var evidenceGuardrails = RunnerValidation.RequiredObject(evidence, "guardrails", "Runner evidence");
            var actionProjectGateAcquired = RunnerValidation.RequiredBoolean(
                evidenceGuardrails,
                "actionProjectGateAcquired",
                "Runner evidence guardrails");
            var actionProjectGateReleased = RunnerValidation.RequiredBoolean(
                evidenceGuardrails,
                "actionProjectGateReleased",
                "Runner evidence guardrails");
            var actionProjectGateKind = RunnerValidation.RequiredString(
                evidenceGuardrails,
                "actionProjectGateKind",
                "Runner evidence guardrails");
            var actionProjectGateConsistent = actionProjectGateAcquired
                ? actionProjectGateKind == "broker-session-action-serialization"
                : actionProjectGateKind == "none";
            if (RunnerValidation.RequiredBoolean(evidenceGuardrails, "onlineOperationsUsed", "Runner evidence guardrails") ||
                RunnerValidation.RequiredBoolean(evidenceGuardrails, "secondPleStarted", "Runner evidence guardrails") ||
                RunnerValidation.RequiredBoolean(evidenceGuardrails, "pleOrMcpStartedByAction", "Runner evidence guardrails") ||
                RunnerValidation.RequiredBoolean(evidenceGuardrails, "directWatcherIpcUsed", "Runner evidence guardrails") ||
                !actionProjectGateReleased ||
                !actionProjectGateConsistent ||
                (state == RunnerStates.Done && !actionProjectGateAcquired))
            {
                throw new RunnerGateException("RUN_RESULT_GUARDRAIL_INVALID", "Runner evidence violates offline/action-gate guardrails.");
            }

            var evidenceResult = RunnerValidation.RequiredObject(evidence, "result", "Runner evidence");
            var evidenceStatus = RunnerValidation.RequiredString(evidenceResult, "status", "Runner evidence result");
            if ((state == RunnerStates.Done && evidenceStatus != "succeeded") ||
                (state == RunnerStates.Blocked && evidenceStatus != "blocked") ||
                (state == RunnerStates.Failed && evidenceStatus == "succeeded"))
            {
                throw new RunnerGateException("RUN_RESULT_ARTIFACT_MISMATCH", "Runner evidence status does not match result state.");
            }

            if (state is RunnerStates.Blocked or RunnerStates.Failed)
            {
                var evidenceReason = RunnerValidation.RequiredString(evidenceResult, "reasonCode", "Runner evidence result");
                if (evidenceReason != reasonCode)
                {
                    throw new RunnerGateException("RUN_RESULT_ARTIFACT_MISMATCH", "Runner evidence reason does not match result reason.");
                }
            }
        }
    }

    private void ValidateArtifactIdentity(JsonObject artifact, string context)
    {
        if (RunnerValidation.RequiredInt32(artifact, "schemaVersion", context) != 1 ||
            RunnerValidation.RequiredString(artifact, "operationId", context) != Action.OperationId ||
            RunnerValidation.RequiredString(artifact, "actionId", context) != Action.ActionId ||
            RunnerValidation.RequiredString(artifact, "actionKind", context) != Action.ActionKind ||
            !RunnerValidation.RequiredString(artifact, "actionRequestSha256", context)
                .Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("RUN_RESULT_ARTIFACT_MISMATCH", $"{context} identity does not match the immutable action.");
        }
    }

    private static RunnerExecutionResult ParseResult(JsonObject json, string resultPath, bool replayed)
    {
        var runId = RunnerValidation.RequiredString(json, "runId", "Runner result");
        var state = RunnerValidation.RequiredString(json, "state", "Runner result");
        var reasonCode = RunnerValidation.RequiredString(json, "reasonCode", "Runner result");
        var exitCode = RunnerValidation.RequiredInt32(json, "exitCode", "Runner result");
        var observation = json["observationPath"]?.GetValue<string>();
        var evidence = json["evidencePath"]?.GetValue<string>();
        return new RunnerExecutionResult(runId, state, reasonCode, exitCode, resultPath, observation, evidence, replayed);
    }

    private static bool VerifyOptionalArtifact(
        JsonObject result,
        string pathProperty,
        string hashProperty,
        string? expectedPath,
        string? requiredRoot)
    {
        if (result[pathProperty] is null && result[hashProperty] is null)
        {
            return true;
        }

        if (result[pathProperty] is not JsonValue pathValue ||
            !pathValue.TryGetValue<string>(out var path) ||
            result[hashProperty] is not JsonValue hashValue ||
            !hashValue.TryGetValue<string>(out var expected) ||
            !RunnerValidation.IsSha256(expected) ||
            !File.Exists(path))
        {
            return false;
        }

        string resolvedPath;
        try
        {
            resolvedPath = requiredRoot is null
                ? RunnerValidation.FullPath(path)
                : RunnerValidation.EnsureInside(requiredRoot, path, "Runner result artifact");
        }
        catch (Exception exception) when (exception is RunnerGateException or ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }

        if (expectedPath is not null &&
            !resolvedPath.Equals(RunnerValidation.FullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return RunnerHash.Sha256File(resolvedPath).Equals(expected, StringComparison.OrdinalIgnoreCase);
    }
}
