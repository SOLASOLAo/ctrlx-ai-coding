using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker.Session;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker;

internal static class BrokerObservationBuilder
{
    public static JsonObject BlockedAfterEngineering(
        ValidatedRunnerAction action,
        string failureStage,
        string reasonCode,
        IReadOnlyList<string> capabilities,
        DateTimeOffset completedAtUtc,
        IReadOnlyList<string> diagnostics,
        JsonObject? semanticProofs = null,
        JsonObject? nextRoute = null,
        BrokerCompileProofState? build = null,
        BrokerProjectProofState? project = null,
        JsonArray? warningRecords = null,
        JsonArray? diagnosticRows = null,
        bool? warningRecordsSafeForReview = null)
    {
        var observation = Failed(
            action,
            failureStage,
            reasonCode,
            capabilities,
            completedAtUtc,
            diagnostics);
        observation["status"] = "blocked";
        if (observation["result"] is JsonObject result)
        {
            if (semanticProofs is not null)
            {
                result["semanticProofs"] = semanticProofs.DeepClone();
            }

            if (nextRoute is not null)
            {
                result["nextRoute"] = nextRoute.DeepClone();
            }

            if (build is not null)
            {
                if (project is null || warningRecords is null || diagnosticRows is null || !warningRecordsSafeForReview.HasValue ||
                    build.MessageCount < 0 || build.MessageCount > 2048 ||
                    diagnosticRows.Count > build.MessageCount ||
                    (build.DiagnosticRowsComplete && diagnosticRows.Count != build.MessageCount) ||
                    (build.TypedRecordsVerified && warningRecordsSafeForReview.Value && warningRecords.Count != build.Warnings) ||
                    (build.TypedRecordsVerified && !warningRecordsSafeForReview.Value && warningRecords.Count != 0) ||
                    (!build.TypedRecordsVerified && warningRecords.Count != 0))
                {
                    throw new InvalidOperationException(
                        "A blocked fresh-Build observation requires the complete bounded warning review records.");
                }

                result["build"] = new JsonObject
                {
                    ["buildId"] = build.BuildId,
                    ["projectPath"] = action.PlcProject,
                    ["profile"] = action.Profile,
                    ["projectSha256"] = project.ProjectSha256,
                    ["startedAtUtc"] = build.StartedAtUtc.ToUniversalTime().ToString("O"),
                    ["completedAtUtc"] = build.CompletedAtUtc.ToUniversalTime().ToString("O"),
                    ["verified"] = true,
                    ["errors"] = build.Errors,
                    ["warnings"] = build.Warnings,
                    ["messageCount"] = build.MessageCount,
                    ["typedRecordsVerified"] = build.TypedRecordsVerified,
                    ["diagnosticRowsComplete"] = build.DiagnosticRowsComplete,
                    ["warningRecordsSafeForReview"] = warningRecordsSafeForReview.Value,
                    ["warningRecords"] = warningRecords.DeepClone(),
                    ["diagnosticRows"] = diagnosticRows.DeepClone(),
                    ["summarySource"] = "codesys-persistent.compile_project"
                };
            }
        }

        return observation;
    }

    public static JsonObject EnforceTerminalObservationBudget(
        ValidatedRunnerAction action,
        JsonObject observation,
        IReadOnlyList<string> capabilities,
        DateTimeOffset completedAtUtc,
        out bool replaced)
    {
        ArgumentNullException.ThrowIfNull(action);
        ArgumentNullException.ThrowIfNull(observation);
        if (BrokerPipeCodec.SerializedUtf8ByteCount(observation) <= BrokerWireProtocol.MaximumTerminalObservationBytes)
        {
            replaced = false;
            return observation;
        }

        replaced = true;
        var bounded = BlockedAfterEngineering(
            action,
            "terminal-observation",
            "TERMINAL_OBSERVATION_TOO_LARGE",
            capabilities,
            completedAtUtc,
            ["Combined terminal evidence exceeded the controlled local observation budget; no partial evidence was accepted."]);
        if (BrokerPipeCodec.SerializedUtf8ByteCount(bounded) > BrokerWireProtocol.MaximumTerminalObservationBytes)
        {
            throw new InvalidOperationException("The compact terminal observation exceeds its controlled budget.");
        }

        return bounded;
    }

    public static JsonObject Succeeded(
        ValidatedRunnerAction action,
        BrokerSessionRuntime session,
        BrokerCompileProofState build,
        BrokerProjectProofState project,
        BrokerSemanticProduction semantic,
        IReadOnlyList<string> capabilities,
        DateTimeOffset completedAtUtc)
    {
        if (!semantic.Verified)
        {
            throw new InvalidOperationException("A successful observation requires complete semantic proofs.");
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = action.OperationId,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionRequestSha256"] = action.ActionSha256,
            ["status"] = "succeeded",
            ["completedAtUtc"] = completedAtUtc.ToUniversalTime().ToString("O"),
            ["capabilitiesInvoked"] = Capabilities(capabilities.ToArray()),
            ["session"] = Session(session),
            ["guardrails"] = Guardrails(),
            ["result"] = new JsonObject
            {
                ["verificationOk"] = true,
                ["appliedReadbackOk"] = true,
                ["repairRequired"] = false,
                ["requiresSecondExport"] = false,
                ["requiresCpStudioChange"] = false,
                ["proposedChanges"] = new JsonArray(),
                ["appliedChanges"] = new JsonArray(),
                ["build"] = new JsonObject
                {
                    ["buildId"] = build.BuildId,
                    ["projectPath"] = action.PlcProject,
                    ["profile"] = action.Profile,
                    ["projectSha256"] = project.ProjectSha256,
                    ["startedAtUtc"] = build.StartedAtUtc.ToUniversalTime().ToString("O"),
                    ["completedAtUtc"] = build.CompletedAtUtc.ToUniversalTime().ToString("O"),
                    ["verified"] = true,
                    ["errors"] = build.Errors,
                    ["warnings"] = build.Warnings,
                    ["messageCount"] = build.MessageCount,
                    ["typedRecordsVerified"] = build.TypedRecordsVerified,
                    ["diagnosticRowsComplete"] = build.DiagnosticRowsComplete,
                    ["warningRecordsSafeForReview"] = semantic.WarningRecordsSafeForReview,
                    ["warningRecords"] = semantic.WarningRecords.DeepClone(),
                    ["summarySource"] = "codesys-persistent.compile_project"
                },
                ["acceptance"] = new JsonObject
                {
                    ["ownershipVerified"] = true,
                    ["mappingConsistent"] = true,
                    ["readbackVerified"] = true,
                    ["recoverableBaselineVerified"] = true,
                    ["warningSignaturesReviewed"] = true,
                    ["existingSessionReused"] = true,
                    ["pleOrMcpStartedByAction"] = false,
                    ["directWatcherIpcUsed"] = false,
                    ["symbolPostProcessingVerified"] = true
                },
                ["semanticProofs"] = semantic.Proofs.DeepClone()
            }
        };
    }

    public static JsonObject Failed(
        ValidatedRunnerAction action,
        string failureStage,
        string reasonCode,
        IReadOnlyList<string> capabilities,
        DateTimeOffset completedAtUtc,
        IReadOnlyList<string>? diagnostics = null)
    {
        var diagnosticRecords = new JsonArray();
        foreach (var diagnostic in diagnostics ?? Array.Empty<string>())
        {
            diagnosticRecords.Add(diagnostic);
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = action.OperationId,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionRequestSha256"] = action.ActionSha256,
            ["status"] = "failed",
            ["completedAtUtc"] = completedAtUtc.ToUniversalTime().ToString("O"),
            ["capabilitiesInvoked"] = Capabilities(capabilities.ToArray()),
            ["guardrails"] = Guardrails(),
            ["result"] = new JsonObject
            {
                ["verificationOk"] = false,
                ["appliedReadbackOk"] = false,
                ["repairRequired"] = false,
                ["requiresSecondExport"] = false,
                ["requiresCpStudioChange"] = false,
                ["proposedChanges"] = new JsonArray(),
                ["appliedChanges"] = new JsonArray(),
                ["failureStage"] = failureStage,
                ["reasonCode"] = reasonCode,
                ["diagnostics"] = diagnosticRecords
            }
        };
    }

    public static JsonObject Blocked(
        ValidatedRunnerAction action,
        string failureStage,
        string reasonCode)
    {
        var observation = Failed(
            action,
            failureStage,
            reasonCode,
            Array.Empty<string>(),
            DateTimeOffset.UtcNow);
        observation["status"] = "blocked";
        return observation;
    }

    public static JsonObject Session(BrokerSessionRuntime session) => new()
    {
        ["state"] = "ready",
        ["mode"] = "persistent",
        ["sessionId"] = session.PersistentSessionId,
        ["mcpPid"] = session.McpPid,
        ["plePid"] = session.PlePid,
        ["profile"] = session.Profile,
        ["activeProjectPath"] = session.ActiveProjectPath,
        ["pleOwnedByBroker"] = session.PleOwnedByBroker
    };

    // These are action-scoped delivery facts, not the Broker owner lease. The
    // dispatcher writes the terminal observation while holding its session gate
    // and withholds it from Query until that gate has been released.
    private static JsonObject Guardrails() => new()
    {
        ["onlineOperationsUsed"] = false,
        ["secondPleStarted"] = false,
        ["actionProjectGateAcquired"] = true,
        ["actionProjectGateReleased"] = true,
        ["actionProjectGateKind"] = "broker-session-action-serialization",
        ["symbolLeaseHeld"] = false,
        ["pleOrMcpStartedByAction"] = false,
        ["directWatcherIpcUsed"] = false
    };

    private static JsonArray Capabilities(params string[] values)
    {
        var result = new JsonArray();
        foreach (var value in values)
        {
            result.Add(value);
        }

        return result;
    }
}
