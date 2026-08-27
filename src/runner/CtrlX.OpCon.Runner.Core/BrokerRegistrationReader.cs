using System.Diagnostics;
using System.ComponentModel;

namespace CtrlX.OpCon.Runner.Core;

public static class BrokerRegistrationReader
{
    private static readonly TimeSpan MaximumHeartbeatAge = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ClockSkew = TimeSpan.FromSeconds(5);

    public static BrokerRegistration ReadValidated(string engineeringRoot, string? registrationPath = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new RunnerGateException("BLOCKED_SESSION_UNAVAILABLE", "The interactive Broker is Windows-only.");
        }

        var resolvedEngineeringRoot = RunnerValidation.FullPath(engineeringRoot);
        var expectedPath = Path.GetFullPath(BrokerWireProtocol.GetDefaultRegistrationPath(resolvedEngineeringRoot));
        var resolvedPath = Path.GetFullPath(registrationPath ?? expectedPath);
        if (!resolvedPath.Equals(expectedPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException(
                "BLOCKED_BROKER_REGISTRATION_PATH_INVALID",
                $"Broker registration must use the current-user discovery path: {expectedPath}");
        }

        var file = new FileInfo(resolvedPath);
        if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException(
                "BLOCKED_BROKER_REGISTRATION_INVALID",
                $"Broker registration is missing or is a reparse point: {resolvedPath}");
        }

        var document = RunnerJson.ReadObject(resolvedPath, "Broker registration");
        RunnerValidation.AssertNoSensitiveFields(document);
        RunnerValidation.RequireOnly(
            document,
            "Broker registration",
            "schemaVersion",
            "kind",
            "protocolVersion",
            "brokerInstanceId",
            "pipeName",
            "brokerPid",
            "processStartTimeUtc",
            "windowsSessionId",
            "userSid",
            "executablePath",
            "executableSha256",
            "engineeringRoot",
            "stationRoot",
            "plcProject",
            "profile",
            "mcpPid",
            "plePid",
            "persistentSessionId",
            "state",
            "issuedAtUtc",
            "heartbeatAtUtc",
            "expiresAtUtc");

        if (RunnerValidation.RequiredInt32(document, "schemaVersion", "Broker registration") != 1 ||
            RunnerValidation.RequiredString(document, "kind", "Broker registration") != BrokerWireProtocol.RegistrationKind ||
            RunnerValidation.RequiredInt32(document, "protocolVersion", "Broker registration") != BrokerWireProtocol.Version)
        {
            throw new RunnerGateException("BLOCKED_SESSION_PROTOCOL_MISMATCH", "Broker registration protocol does not match this Runner.");
        }

        var registration = new BrokerRegistration(
            ProtocolVersion: BrokerWireProtocol.Version,
            BrokerInstanceId: SafeString(document, "brokerInstanceId", 128),
            PipeName: SafeString(document, "pipeName", 128),
            BrokerPid: Positive(document, "brokerPid"),
            ProcessStartTimeUtc: Timestamp(document, "processStartTimeUtc"),
            WindowsSessionId: Positive(document, "windowsSessionId"),
            UserSid: RunnerValidation.RequiredString(document, "userSid", "Broker registration"),
            ExecutablePath: Path.GetFullPath(RunnerValidation.RequiredString(document, "executablePath", "Broker registration")),
            ExecutableSha256: Sha256(document, "executableSha256"),
            EngineeringRoot: RunnerValidation.FullPath(RunnerValidation.RequiredString(document, "engineeringRoot", "Broker registration")),
            StationRoot: RunnerValidation.FullPath(RunnerValidation.RequiredString(document, "stationRoot", "Broker registration")),
            PlcProject: Path.GetFullPath(RunnerValidation.RequiredString(document, "plcProject", "Broker registration")),
            Profile: RunnerValidation.RequiredString(document, "profile", "Broker registration"),
            McpPid: Positive(document, "mcpPid"),
            PlePid: Positive(document, "plePid"),
            PersistentSessionId: SafeString(document, "persistentSessionId", 128),
            State: SafeString(document, "state", 32),
            IssuedAtUtc: Timestamp(document, "issuedAtUtc"),
            HeartbeatAtUtc: Timestamp(document, "heartbeatAtUtc"),
            ExpiresAtUtc: Timestamp(document, "expiresAtUtc"),
            RegistrationPath: resolvedPath);

        var now = DateTimeOffset.UtcNow;
        if (registration.State != "ready" ||
            registration.IssuedAtUtc > now + ClockSkew ||
            registration.HeartbeatAtUtc > now + ClockSkew ||
            now - registration.HeartbeatAtUtc > MaximumHeartbeatAge ||
            registration.ExpiresAtUtc <= now ||
            registration.ExpiresAtUtc < registration.HeartbeatAtUtc)
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_STALE", "Broker registration heartbeat is not current and ready.");
        }

        if (!registration.UserSid.Equals(BrokerWireProtocol.CurrentUserSid(), StringComparison.Ordinal) ||
            !registration.EngineeringRoot.Equals(resolvedEngineeringRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("BLOCKED_BROKER_IDENTITY_INVALID", "Broker registration user or engineering root does not match this client.");
        }

        ValidateProcess(registration);
        return registration;
    }

    private static void ValidateProcess(BrokerRegistration registration)
    {
        Process process;
        try
        {
            process = Process.GetProcessById(registration.BrokerPid);
        }
        catch (ArgumentException exception)
        {
            throw new RunnerGateException("BLOCKED_BROKER_IDENTITY_INVALID", "Registered Broker process is no longer running. " + exception.Message);
        }

        using (process)
        {
            try
            {
                if (process.HasExited || process.SessionId != registration.WindowsSessionId)
                {
                    throw new RunnerGateException("BLOCKED_BROKER_IDENTITY_INVALID", "Registered Broker PID or Windows session is stale.");
                }

                var actualStart = process.StartTime.ToUniversalTime();
                if (Math.Abs((actualStart - registration.ProcessStartTimeUtc.UtcDateTime).TotalMilliseconds) > 1000)
                {
                    throw new RunnerGateException("BLOCKED_BROKER_IDENTITY_INVALID", "Registered Broker PID was reused by another process.");
                }

                var actualExecutable = process.MainModule?.FileName;
                if (string.IsNullOrWhiteSpace(actualExecutable) ||
                    !Path.GetFullPath(actualExecutable).Equals(registration.ExecutablePath, StringComparison.OrdinalIgnoreCase) ||
                    !File.Exists(actualExecutable) ||
                    !RunnerHash.Sha256File(actualExecutable).Equals(registration.ExecutableSha256, StringComparison.OrdinalIgnoreCase))
                {
                    throw new RunnerGateException("BLOCKED_BROKER_IDENTITY_INVALID", "Registered Broker executable identity is invalid.");
                }
            }
            catch (Exception exception) when (exception is Win32Exception or InvalidOperationException or UnauthorizedAccessException or IOException)
            {
                throw new RunnerGateException(
                    "BLOCKED_BROKER_IDENTITY_INVALID",
                    "Registered Broker process identity could not be verified. " + exception.Message);
            }
        }
    }

    private static string SafeString(System.Text.Json.Nodes.JsonObject document, string name, int maximumLength)
    {
        var value = RunnerValidation.RequiredString(document, name, "Broker registration");
        if (!RunnerValidation.IsSafeIdentifier(value, maximumLength))
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_INVALID", $"Broker registration '{name}' is malformed.");
        }

        return value;
    }

    private static string Sha256(System.Text.Json.Nodes.JsonObject document, string name)
    {
        var value = RunnerValidation.RequiredString(document, name, "Broker registration");
        if (!RunnerValidation.IsSha256(value))
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_INVALID", $"Broker registration '{name}' is not SHA-256.");
        }

        return value.ToUpperInvariant();
    }

    private static int Positive(System.Text.Json.Nodes.JsonObject document, string name)
    {
        var value = RunnerValidation.RequiredInt32(document, name, "Broker registration");
        if (value <= 0)
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_INVALID", $"Broker registration '{name}' must be positive.");
        }

        return value;
    }

    private static DateTimeOffset Timestamp(System.Text.Json.Nodes.JsonObject document, string name)
    {
        var text = RunnerValidation.RequiredString(document, name, "Broker registration");
        if (!DateTimeOffset.TryParse(text, out var value))
        {
            throw new RunnerGateException("BLOCKED_BROKER_REGISTRATION_INVALID", $"Broker registration '{name}' is not a timestamp.");
        }

        return value.ToUniversalTime();
    }
}
