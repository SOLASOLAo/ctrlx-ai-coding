using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Core;

return await RunnerCli.RunAsync(args).ConfigureAwait(false);

internal static class RunnerCli
{
    public static async Task<int> RunAsync(string[] args)
    {
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };

        try
        {
            if (args.Length == 0 || args[0] is "help" or "--help" or "-h")
            {
                WriteHelp();
                return args.Length == 0 ? RunnerExitCodes.Usage : RunnerExitCodes.Done;
            }

            var command = args[0];
            var options = CliOptions.Parse(args[1..]);
            return command switch
            {
                "doctor" => RunDoctor(options),
                "execute-action" => await RunExecuteActionAsync(options, cancellation.Token).ConfigureAwait(false),
                "status" => RunStatus(options),
                "verify" => RunVerify(options),
                _ => throw new RunnerGateException("UNKNOWN_COMMAND", $"Unknown command: {command}", RunnerExitCodes.Usage)
            };
        }
        catch (RunnerGateException exception)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = 1,
                ["kind"] = "ctrlx-opcon-runner-cli-error",
                ["reasonCode"] = exception.ReasonCode,
                ["message"] = exception.Message,
                ["exitCode"] = exception.ExitCode
            });
            return exception.ExitCode;
        }
        catch (OperationCanceledException)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = 1,
                ["kind"] = "ctrlx-opcon-runner-cli-error",
                ["reasonCode"] = "CLI_CANCELLED",
                ["message"] = "Runner command was cancelled.",
                ["exitCode"] = RunnerExitCodes.GateFailure
            });
            return RunnerExitCodes.GateFailure;
        }
        catch (Exception exception)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = 1,
                ["kind"] = "ctrlx-opcon-runner-cli-error",
                ["reasonCode"] = "CLI_INTERNAL_ERROR",
                ["message"] = exception.Message,
                ["exitCode"] = RunnerExitCodes.InternalError
            });
            return RunnerExitCodes.InternalError;
        }
    }

    private static int RunDoctor(CliOptions options)
    {
        options.RequireOnly("engineering-root", "json");
        var engineeringRoot = Path.GetFullPath(options.Require("engineering-root"));
        var producer = Path.Combine(engineeringRoot, "scripts", "cpstudio", "New-PostExportRunnerEvidence.ps1");
        var actionRoot = Path.Combine(engineeringRoot, "data", "operations");
        var registrationPath = BrokerWireProtocol.GetDefaultRegistrationPath(engineeringRoot);
        BrokerRegistration? registration = null;
        var registrationValidationReasonCode = "BROKER_REGISTRATION_VALIDATED";
        try
        {
            registration = BrokerRegistrationReader.ReadValidated(engineeringRoot);
        }
        catch (RunnerGateException exception)
        {
            registrationValidationReasonCode = exception.ReasonCode;
        }

        var localPrerequisitesReady = OperatingSystem.IsWindows() &&
            Directory.Exists(engineeringRoot) &&
            File.Exists(producer);
        // Doctor validates the installed action client independently from the
        // explicitly started interactive Broker. This keeps project creation
        // and offline workstation checks usable before an engineering session
        // is opened; execution readiness is reported separately below.
        var ready = localPrerequisitesReady;
        WriteJson(new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-doctor",
            ["readyForActionClient"] = ready,
            ["readyForRegisteredExecution"] = ready && registration is not null,
            ["windows"] = OperatingSystem.IsWindows(),
            ["framework"] = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
            ["engineeringRoot"] = engineeringRoot,
            ["actionRootExists"] = Directory.Exists(actionRoot),
            ["evidenceProducerExists"] = File.Exists(producer),
            ["brokerProtocolVersion"] = BrokerWireProtocol.Version,
            ["brokerRegistrationPath"] = registrationPath,
            ["brokerRegistrationExists"] = File.Exists(registrationPath),
            ["brokerRegistrationValidated"] = registration is not null,
            ["brokerRegistrationValidationReasonCode"] = registrationValidationReasonCode,
            ["brokerState"] = registration?.State,
            ["brokerPid"] = registration?.BrokerPid,
            ["brokerWindowsSessionId"] = registration?.WindowsSessionId,
            ["startsPleOrMcp"] = false,
            ["onlineOperationsAllowed"] = false
        });
        return ready ? RunnerExitCodes.Done : RunnerExitCodes.GateFailure;
    }

    private static async Task<int> RunExecuteActionAsync(CliOptions options, CancellationToken cancellationToken)
    {
        options.RequireOnly(
            "engineering-root",
            "action-path",
            "expected-sha256",
            "broker-connect-timeout-ms",
            "broker-action-timeout-ms",
            "lease-timeout-ms",
            "json");
        var engineeringRoot = options.Require("engineering-root");
        var actionPath = options.Require("action-path");
        var expectedSha256 = options.Require("expected-sha256");
        var leaseTimeout = TimeSpan.FromMilliseconds(options.GetInt32("lease-timeout-ms", 5_000, minimum: 0, maximum: 120_000));
        var brokerConnectTimeout = TimeSpan.FromMilliseconds(
            options.GetInt32("broker-connect-timeout-ms", 2_000, minimum: 100, maximum: 120_000));
        var brokerActionTimeout = TimeSpan.FromMilliseconds(
            options.GetInt32("broker-action-timeout-ms", 600_000, minimum: 1_000, maximum: 1_800_000));

        ISessionBrokerClient broker = new NamedPipeSessionBrokerClient(
            engineeringRoot,
            registrationPath: null,
            brokerConnectTimeout,
            brokerActionTimeout);
        var executor = new RunnerExecutor(broker, new PowerShellEvidenceSealer());
        var result = await executor.ExecuteAsync(
            new RunnerExecutionRequest(engineeringRoot, actionPath, expectedSha256, leaseTimeout),
            cancellationToken).ConfigureAwait(false);
        WriteJson(result.ToJson());
        return result.ExitCode;
    }

    private static int RunStatus(CliOptions options)
    {
        options.RequireOnly("engineering-root", "run-id", "json");
        WriteJson(RunnerRunStore.ReadStatus(options.Require("engineering-root"), options.Require("run-id")));
        return RunnerExitCodes.Done;
    }

    private static int RunVerify(CliOptions options)
    {
        options.RequireOnly("engineering-root", "run-id", "json");
        var verification = RunnerRunStore.VerifyById(options.Require("engineering-root"), options.Require("run-id"));
        WriteJson(verification);
        return verification["valid"]?.GetValue<bool>() == true
            ? RunnerExitCodes.Done
            : RunnerExitCodes.GateFailure;
    }

    private static void WriteJson(JsonNode value)
    {
        Console.Out.WriteLine(value.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
    }

    private static void WriteHelp()
    {
        Console.Out.WriteLine(
            """
            vcrunner - ctrlX OpCon offline Stage2 action client

            Commands:
              doctor --engineering-root <path> [--json]
              execute-action --engineering-root <path> --action-path <path> --expected-sha256 <sha256>
                             [--broker-connect-timeout-ms <ms>] [--broker-action-timeout-ms <ms>]
                             [--lease-timeout-ms <ms>] [--json]
              status --engineering-root <path> --run-id <id> [--json]
              verify --engineering-root <path> --run-id <id> [--json]

            Safety boundary:
              This client never starts PLE, MCP, a Broker, or any online PLC operation.
              Broker protocol v2 is discovered only through the current-user validated registration path.
              The same Windows user is the present local trust boundary.
              Callers cannot override the Broker Pipe or PID.
            """);
    }
}

internal sealed class CliOptions
{
    private readonly Dictionary<string, string> values;

    private CliOptions(Dictionary<string, string> values)
    {
        this.values = values;
    }

    public static CliOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Length; index++)
        {
            var token = args[index];
            if (!token.StartsWith("--", StringComparison.Ordinal) || token.Length == 2)
            {
                throw new RunnerGateException("CLI_ARGUMENT_INVALID", $"Expected --option, found: {token}", RunnerExitCodes.Usage);
            }

            var name = token[2..];
            string value;
            if (name == "json")
            {
                value = "true";
            }
            else
            {
                if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    throw new RunnerGateException("CLI_ARGUMENT_MISSING", $"Option --{name} requires a value.", RunnerExitCodes.Usage);
                }

                value = args[++index];
            }

            if (!values.TryAdd(name, value))
            {
                throw new RunnerGateException("CLI_ARGUMENT_DUPLICATE", $"Option --{name} was specified more than once.", RunnerExitCodes.Usage);
            }
        }

        return new CliOptions(values);
    }

    public string Require(string name)
    {
        if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
        {
            throw new RunnerGateException("CLI_ARGUMENT_MISSING", $"Required option --{name} is missing.", RunnerExitCodes.Usage);
        }

        return value;
    }

    public bool TryGet(string name, out string value) => values.TryGetValue(name, out value!);

    public int GetInt32(string name, int defaultValue, int minimum, int maximum)
    {
        if (!values.TryGetValue(name, out var text))
        {
            return defaultValue;
        }

        if (!int.TryParse(text, out var value) || value < minimum || value > maximum)
        {
            throw new RunnerGateException(
                "CLI_ARGUMENT_INVALID",
                $"Option --{name} must be an integer from {minimum} through {maximum}.",
                RunnerExitCodes.Usage);
        }

        return value;
    }

    public void RequireOnly(params string[] allowed)
    {
        var allowlist = new HashSet<string>(allowed, StringComparer.Ordinal);
        var unexpected = values.Keys.FirstOrDefault(key => !allowlist.Contains(key));
        if (unexpected is not null)
        {
            throw new RunnerGateException("CLI_ARGUMENT_UNKNOWN", $"Unsupported option --{unexpected}.", RunnerExitCodes.Usage);
        }
    }
}
