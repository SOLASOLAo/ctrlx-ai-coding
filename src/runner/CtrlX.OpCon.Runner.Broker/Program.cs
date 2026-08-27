using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker;
using CtrlX.OpCon.Runner.Broker.Infrastructure;
using CtrlX.OpCon.Runner.Broker.Mcp;
using CtrlX.OpCon.Runner.Core;

return await BrokerProgram.RunAsync(args).ConfigureAwait(false);

internal static class BrokerProgram
{
    public static async Task<int> RunAsync(string[] args)
    {
        try
        {
            if (args.Length == 0 || args[0] is "help" or "--help" or "-h")
            {
                PrintHelp();
                return 0;
            }

            var command = args[0];
            var values = Parse(args[1..]);
            return command switch
            {
                "start" => await StartAsync(values).ConfigureAwait(false),
                "status" => Status(values),
                _ => throw new ArgumentException($"Unknown Broker command: {command}")
            };
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"BROKER_FAILED: {exception.Message}");
            return 70;
        }
    }

    private static async Task<int> StartAsync(IReadOnlyDictionary<string, string> values)
    {
        var engineeringRoot = Required(values, "engineering-root");
        var stationRoot = Required(values, "station-root");
        var plcProject = Required(values, "plc-project");
        var profile = values.GetValueOrDefault("profile", "ctrlX PLC 2.6.8");
        var node = values.GetValueOrDefault(
            "node-exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "node.exe"));
        var mcpEntry = values.GetValueOrDefault(
            "mcp-entrypoint",
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "npm",
                "node_modules",
                "codesys-mcp-persistent",
                "dist",
                "bin.js"));
        var ple = values.GetValueOrDefault(
            "ple-exe",
            @"C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\StudioPlc\Common\ctrlX-PLC-Engineering.exe");
        if (!File.Exists(mcpEntry))
        {
            throw new FileNotFoundException("Pinned codesys-mcp-persistent entrypoint was not found.", mcpEntry);
        }

        if (!File.Exists(ple))
        {
            throw new FileNotFoundException("ctrlX PLC Engineering executable was not found.", ple);
        }

        var mcp = new McpProcessOptions
        {
            ExecutablePath = Path.GetFullPath(node),
            WorkingDirectory = Path.GetFullPath(engineeringRoot),
            Arguments =
            [
                Path.GetFullPath(mcpEntry),
                "--codesys-path", Path.GetFullPath(ple),
                "--codesys-profile", profile,
                "--workspace", Path.GetFullPath(stationRoot),
                "--mode", "persistent",
                "--no-auto-launch",
                "--timeout", "1020000"
            ]
        };
        var options = new BrokerHostOptions
        {
            EngineeringRoot = Path.GetFullPath(engineeringRoot),
            StationRoot = Path.GetFullPath(stationRoot),
            PlcProject = Path.GetFullPath(plcProject),
            Profile = profile,
            Mcp = mcp
        };

        Console.WriteLine("Starting the unique interactive ctrlX OpCon Broker.");
        Console.WriteLine("This explicit command owns one persistent MCP/PLE session; Ctrl+C performs graceful shutdown.");
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += OnCancel;
        try
        {
            await new BrokerHost(options).RunAsync(cancellation.Token).ConfigureAwait(false);
            return 0;
        }
        finally
        {
            Console.CancelKeyPress -= OnCancel;
        }

        void OnCancel(object? sender, ConsoleCancelEventArgs eventArgs)
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        }
    }

    private static int Status(IReadOnlyDictionary<string, string> values)
    {
        var engineeringRoot = Required(values, "engineering-root");
        try
        {
            var registration = BrokerRegistrationReader.ReadValidated(engineeringRoot);
            Console.WriteLine(new JsonObject
            {
                ["validated"] = true,
                ["state"] = registration.State,
                ["brokerPid"] = registration.BrokerPid,
                ["mcpPid"] = registration.McpPid,
                ["plePid"] = registration.PlePid,
                ["sessionId"] = registration.PersistentSessionId,
                ["profile"] = registration.Profile,
                ["project"] = registration.PlcProject,
                ["registrationPath"] = registration.RegistrationPath
            }.ToJsonString(new() { WriteIndented = true }));
            return 0;
        }
        catch (RunnerGateException exception)
        {
            Console.WriteLine(new JsonObject
            {
                ["validated"] = false,
                ["reasonCode"] = exception.ReasonCode,
                ["registrationPath"] = BrokerWireProtocol.GetDefaultRegistrationPath(engineeringRoot)
            }.ToJsonString(new() { WriteIndented = true }));
            return 40;
        }
    }

    private static Dictionary<string, string> Parse(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length || !args[index].StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException("Broker options must use '--name value' pairs.");
            }

            var name = args[index][2..];
            if (name is not ("engineering-root" or "station-root" or "plc-project" or "profile" or "node-exe" or "mcp-entrypoint" or "ple-exe") ||
                !result.TryAdd(name, args[index + 1]))
            {
                throw new ArgumentException($"Unknown or duplicate Broker option: --{name}");
            }
        }

        return result;
    }

    private static string Required(IReadOnlyDictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required option --{name}.");

    private static void PrintHelp()
    {
        Console.WriteLine("vcrunner-broker start --engineering-root <path> --station-root <path> --plc-project <path> [--profile <exact>] [--node-exe <path>] [--mcp-entrypoint <path>] [--ple-exe <path>]");
        Console.WriteLine("vcrunner-broker status --engineering-root <path>");
        Console.WriteLine("The Broker is explicit, interactive-session only, and accepts inspect_and_build or verify_after_export_2 only.");
    }
}
