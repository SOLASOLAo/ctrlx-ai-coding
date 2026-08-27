using System.Security.Principal;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

/// <summary>
/// Fixed, typed local IPC contract between the action client and the unique
/// interactive-session Broker. It deliberately exposes no generic tool call.
/// </summary>
public static class BrokerWireProtocol
{
    public const int Version = 2;
    public const int MaximumMessageBytes = 1024 * 1024;

    public const string RegistrationKind = "ctrlx-opcon-runner-broker-registration";
    public const string SubmitKind = "ctrlx-opcon-runner-broker-submit";
    public const string SubmitReplyKind = "ctrlx-opcon-runner-broker-submit-reply";
    public const string QueryKind = "ctrlx-opcon-runner-broker-query";
    public const string QueryReplyKind = "ctrlx-opcon-runner-broker-query-reply";

    public static string GetDefaultRegistrationPath(string engineeringRoot)
    {
        var normalized = NormalizeIdentityPath(engineeringRoot);
        var rootKey = RunnerHash.Sha256Text(normalized)[..32].ToLowerInvariant();
        var localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new RunnerGateException(
                "BROKER_RUNTIME_ROOT_UNAVAILABLE",
                "The current user LocalApplicationData directory is unavailable.");
        }

        return Path.Combine(
            localApplicationData,
            "CtrlX.OpCon.Runner",
            "registrations",
            rootKey,
            "registration.json");
    }

    public static string NormalizeIdentityPath(string path)
    {
        var normalized = RunnerValidation.FullPath(path);
        return OperatingSystem.IsWindows() ? normalized.ToUpperInvariant() : normalized;
    }

    public static string CurrentUserSid()
    {
        if (!OperatingSystem.IsWindows())
        {
            return Environment.UserName;
        }

        return WindowsIdentity.GetCurrent().User?.Value
            ?? throw new RunnerGateException("BROKER_USER_IDENTITY_UNAVAILABLE", "The current Windows user SID is unavailable.");
    }

    public static JsonObject ActionIdentity(ValidatedRunnerAction action) => new()
    {
        ["operationId"] = action.OperationId,
        ["actionId"] = action.ActionId,
        ["actionKind"] = action.ActionKind,
        ["actionRequestPath"] = action.ActionPath,
        ["actionRequestSha256"] = action.ActionSha256,
        ["idempotencyKey"] = action.IdempotencyKey
    };

    public static JsonObject ProjectIdentity(ValidatedRunnerAction action) => new()
    {
        ["engineeringRoot"] = action.EngineeringRoot,
        ["stationRoot"] = action.StationRoot,
        ["plcProject"] = action.PlcProject,
        ["profile"] = action.Profile
    };

    public static JsonObject OfflineGuardrails() => new()
    {
        ["offlineOnly"] = true,
        ["onlineOperationsAllowed"] = false,
        ["requireExistingPersistentSession"] = true,
        ["prohibitPleOrMcpStartByAction"] = true,
        ["prohibitDirectWatcherIpc"] = true,
        ["requireExactProjectOpen"] = true,
        ["pleOrMcpStartedByActionAllowed"] = false
    };
}

public sealed record BrokerRegistration(
    int ProtocolVersion,
    string BrokerInstanceId,
    string PipeName,
    int BrokerPid,
    DateTimeOffset ProcessStartTimeUtc,
    int WindowsSessionId,
    string UserSid,
    string ExecutablePath,
    string ExecutableSha256,
    string EngineeringRoot,
    string StationRoot,
    string PlcProject,
    string Profile,
    int McpPid,
    int PlePid,
    string PersistentSessionId,
    string State,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset HeartbeatAtUtc,
    DateTimeOffset ExpiresAtUtc,
    string RegistrationPath);
