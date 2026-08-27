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
        IReadOnlyList<string> diagnostics)
    {
        var observation = Failed(
            action,
            failureStage,
            reasonCode,
            capabilities,
            completedAtUtc,
            diagnostics);
        observation["status"] = "blocked";
        return observation;
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
