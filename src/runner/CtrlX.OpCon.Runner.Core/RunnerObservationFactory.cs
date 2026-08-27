using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

internal static class RunnerObservationFactory
{
    public static JsonObject Blocked(ValidatedRunnerAction action, string failureStage, string reasonCode)
    {
        if (!RunnerValidation.IsSafeIdentifier(failureStage, 64) ||
            !RunnerValidation.IsSafeIdentifier(reasonCode, 96))
        {
            throw new RunnerGateException("BLOCK_REASON_INVALID", "Runner block stage/reason must use safe identifiers.");
        }

        var completedAt = DateTimeOffset.UtcNow;
        if (completedAt < action.CreatedAtUtc)
        {
            completedAt = action.CreatedAtUtc;
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = action.OperationId,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionRequestSha256"] = action.ActionSha256,
            ["status"] = "blocked",
            ["completedAtUtc"] = completedAt.ToUniversalTime().ToString("O"),
            ["capabilitiesInvoked"] = new JsonArray(),
            ["guardrails"] = new JsonObject
            {
                ["onlineOperationsUsed"] = false,
                ["secondPleStarted"] = false,
                ["actionProjectGateAcquired"] = false,
                ["actionProjectGateReleased"] = true,
                ["actionProjectGateKind"] = "none",
                ["symbolLeaseHeld"] = false,
                ["pleOrMcpStartedByAction"] = false,
                ["directWatcherIpcUsed"] = false
            },
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
                ["reasonCode"] = reasonCode
            }
        };
    }
}
