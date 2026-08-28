using System.Text.Json;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Core;
using CtrlX.OpCon.Runner.Host;

return await HostCli.RunAsync(args).ConfigureAwait(false);

internal static class HostCli
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
            var options = HostCliOptions.Parse(args[1..]);
            options.RequireOnly("engineering-root", "runtime-root", "json");
            var engineeringRoot = options.Require("engineering-root");
            var runtimeRoot = options.Optional("runtime-root");
            if (runtimeRoot is not null &&
                Environment.GetEnvironmentVariable("CTRLX_OPCON_RUNNER_HOST_TEST_MODE") != "1")
            {
                throw new RunnerGateException(
                    "HOST_RUNTIME_OVERRIDE_FORBIDDEN",
                    "--runtime-root is reserved for isolated offline SelfTests.",
                    RunnerExitCodes.Usage);
            }

            var paths = HostRuntimePaths.Create(engineeringRoot, runtimeRoot);
            return command switch
            {
                "run" => await new HostRuntime(paths).RunAsync(cancellation.Token).ConfigureAwait(false),
                "status" => RunStatus(paths),
                "stop" => await RunStopAsync(paths, cancellation.Token).ConfigureAwait(false),
                "logs" => RunLogs(paths),
                _ => throw new RunnerGateException("HOST_UNKNOWN_COMMAND", $"Unknown Runner Host command: {command}", RunnerExitCodes.Usage)
            };
        }
        catch (RunnerGateException exception)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = HostConstants.SchemaVersion,
                ["kind"] = "ctrlx-opcon-runner-host-error",
                ["reasonCode"] = exception.ReasonCode,
                ["message"] = exception.Message,
                ["exitCode"] = exception.ExitCode,
                ["safety"] = SafetyJson()
            });
            return exception.ExitCode;
        }
        catch (OperationCanceledException)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = HostConstants.SchemaVersion,
                ["kind"] = "ctrlx-opcon-runner-host-error",
                ["reasonCode"] = "HOST_COMMAND_CANCELLED",
                ["exitCode"] = RunnerExitCodes.GateFailure,
                ["safety"] = SafetyJson()
            });
            return RunnerExitCodes.GateFailure;
        }
        catch (Exception exception)
        {
            WriteJson(new JsonObject
            {
                ["schemaVersion"] = HostConstants.SchemaVersion,
                ["kind"] = "ctrlx-opcon-runner-host-error",
                ["reasonCode"] = "HOST_INTERNAL_ERROR",
                ["message"] = exception.GetType().Name,
                ["exitCode"] = RunnerExitCodes.InternalError,
                ["safety"] = SafetyJson()
            });
            return RunnerExitCodes.InternalError;
        }
    }

    private static int RunStatus(HostRuntimePaths paths)
    {
        var observation = new HostStatusStore(paths).Observe();
        if (observation.Live && observation.Document is not null)
        {
            WriteJson(JsonSerializer.SerializeToNode(observation.Document, HostJson.Options)!);
            return RunnerExitCodes.Done;
        }

        WriteJson(new JsonObject
        {
            ["schemaVersion"] = HostConstants.SchemaVersion,
            ["kind"] = HostConstants.StatusKind,
            ["state"] = HostStates.Stopped,
            ["reasonCode"] = observation.ReasonCode,
            ["engineeringRoot"] = paths.EngineeringRoot,
            ["rootKey"] = paths.RootKey,
            ["logDirectory"] = paths.LogDirectory,
            ["crashRecoveryPending"] = observation.CrashRecoveryPending,
            ["lastHostInstanceId"] = observation.Document?.HostInstanceId,
            ["lastHostPid"] = observation.Document?.HostPid,
            ["safety"] = SafetyJson()
        });
        return RunnerExitCodes.Done;
    }

    private static async Task<int> RunStopAsync(HostRuntimePaths paths, CancellationToken cancellationToken)
    {
        var reply = await new HostControlClient(paths).StopAsync(cancellationToken).ConfigureAwait(false);
        WriteJson(JsonSerializer.SerializeToNode(reply, HostJson.Options)!);
        return RunnerExitCodes.Done;
    }

    private static int RunLogs(HostRuntimePaths paths)
    {
        var store = new HostLogStore(paths);
        var files = new JsonArray(store.ListRecent()
            .Select(item => (JsonNode?)new JsonObject
            {
                ["path"] = item.Path,
                ["bytes"] = item.Bytes,
                ["lastWriteTimeUtc"] = item.LastWriteTimeUtc
            })
            .ToArray());
        WriteJson(new JsonObject
        {
            ["schemaVersion"] = HostConstants.SchemaVersion,
            ["kind"] = "ctrlx-opcon-runner-host-logs",
            ["engineeringRoot"] = paths.EngineeringRoot,
            ["logDirectory"] = paths.LogDirectory,
            ["files"] = files,
            ["safety"] = SafetyJson()
        });
        return RunnerExitCodes.Done;
    }

    private static JsonObject SafetyJson() => new()
    {
        ["startsBroker"] = false,
        ["startsPleOrMcp"] = false,
        ["onlineOperationsAllowed"] = false,
        ["automaticActionExecutionEnabled"] = false
    };

    private static void WriteJson(JsonNode node) =>
        Console.Out.WriteLine(node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

    private static void WriteHelp()
    {
        Console.Out.WriteLine(
            """
            vcrunner-host - current-user ctrlX OpCon Runner background host

            Commands:
              run    --engineering-root <path>
              status --engineering-root <path> [--json]
              stop   --engineering-root <path> [--json]
              logs   --engineering-root <path> [--json]

            Boundary:
              The Host never starts Broker, MCP, Node, PLE or an online PLC operation.
              Missing validated interactive Agent registration is WAITING_FOR_AGENT.
              This P1.3a slice provides lifecycle, status and bounded logs; automatic
              action consumption remains disabled until a later reviewed slice.
            """);
    }
}

internal sealed class HostCliOptions
{
    private readonly Dictionary<string, string> values;

    private HostCliOptions(Dictionary<string, string> values)
    {
        this.values = values;
    }

    public static HostCliOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Length; index++)
        {
            var token = args[index];
            if (!token.StartsWith("--", StringComparison.Ordinal) || token.Length == 2)
            {
                throw new RunnerGateException("HOST_CLI_ARGUMENT_INVALID", $"Expected --option, found: {token}", RunnerExitCodes.Usage);
            }

            var name = token[2..];
            var value = name == "json"
                ? "true"
                : index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)
                    ? args[++index]
                    : throw new RunnerGateException("HOST_CLI_ARGUMENT_MISSING", $"Option --{name} requires a value.", RunnerExitCodes.Usage);
            if (!values.TryAdd(name, value))
            {
                throw new RunnerGateException("HOST_CLI_ARGUMENT_DUPLICATE", $"Option --{name} was specified more than once.", RunnerExitCodes.Usage);
            }
        }

        return new HostCliOptions(values);
    }

    public string Require(string name) => values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new RunnerGateException("HOST_CLI_ARGUMENT_MISSING", $"Required option --{name} is missing.", RunnerExitCodes.Usage);

    public string? Optional(string name) => values.TryGetValue(name, out var value) ? value : null;

    public void RequireOnly(params string[] allowed)
    {
        var allowlist = new HashSet<string>(allowed, StringComparer.Ordinal);
        var unexpected = values.Keys.FirstOrDefault(key => !allowlist.Contains(key));
        if (unexpected is not null)
        {
            throw new RunnerGateException("HOST_CLI_ARGUMENT_UNKNOWN", $"Unsupported option --{unexpected}.", RunnerExitCodes.Usage);
        }
    }
}
