using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker;
using CtrlX.OpCon.Runner.Broker.Mcp;
using CtrlX.OpCon.Runner.Broker.Session;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.EngineeringSelfTest;

internal static class Program
{
    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("external exact session is reused and never shut down", ExternalSessionIsReusedAsync),
            ("missing ownership adapter blocks before launch", MissingOwnershipContractBlocksBeforeLaunchAsync),
            ("already-ready broker-owned PLE is rejected", ExistingBrokerOwnedPleIsRejectedAsync),
            ("PLE created by this Start is owned and shut down", CreatedPleIsOwnedAsync),
            ("external project mismatch is not altered or shut down", ExternalProjectMismatchIsRejectedAsync),
            ("owned PLE shutdown failure propagates after MCP cleanup", OwnedPleShutdownFailurePropagatesAsync),
            ("fresh 0/0 Build is parsed but semantic result stays blocked", FreshZeroBuildStaysBlockedAsync),
            ("legacy fresh contract is rejected even when it reports 0/0", LegacyFreshContractStaysBlockedAsync),
            ("missing fresh summary fails closed without cached messages", MissingFreshSummaryStaysBlockedAsync)
        };

        var failures = new List<string>();
        foreach (var test in tests)
        {
            try
            {
                await test.Run().ConfigureAwait(false);
                Console.WriteLine($"PASS: {test.Name}");
            }
            catch (Exception exception)
            {
                failures.Add($"{test.Name}: {exception.GetType().Name}: {exception.Message}");
                Console.Error.WriteLine($"FAIL: {failures[^1]}");
            }
        }

        if (failures.Count == 0)
        {
            Console.WriteLine("Engineering-session self-test passed. Fake IMcpRpcClient only; no Node, MCP, or PLE was started.");
            return 0;
        }

        Console.Error.WriteLine($"Engineering-session self-test failed: {failures.Count} case(s).");
        return 1;
    }

    private static async Task ExternalSessionIsReusedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.ExternalReady(fixture.ProjectPath);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);

        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        Require(runtime.McpPid == rpc.ProcessId, "Session evidence must expose the owned MCP child PID.");
        Require(!runtime.PleOwnedByBroker, "External PLE must not become Broker-owned.");
        Require(rpc.Count("launch_codesys") == 0, "Ready external PLE must not trigger launch.");
        Require(rpc.Count("open_project") == 0, "Exact external project must not be reopened.");

        await session.StopAsync(CancellationToken.None).ConfigureAwait(false);
        Require(rpc.Count("shutdown_codesys") == 0, "External PLE must never be shut down.");
        Require(rpc.StopCalls == 1, "Broker-owned MCP child must be stopped.");
    }

    private static async Task MissingOwnershipContractBlocksBeforeLaunchAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", ownership: null));
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);

        var failure = await CaptureAsync(() => session.StartAsync(CancellationToken.None)).ConfigureAwait(false);
        Require(failure.ReasonCode == "BROKER_PLE_OWNERSHIP_CAPABILITY_MISSING", "Missing adapter must have a stable reason.");
        Require(rpc.Count("launch_codesys") == 0, "Missing ownership adapter must block before launch.");
        Require(rpc.Count("open_project") == 0, "Missing ownership adapter must block before project access.");
    }

    private static async Task ExistingBrokerOwnedPleIsRejectedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("ready", "persistent", "43001", "other-broker", "broker"));
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);

        var failure = await CaptureAsync(() => session.StartAsync(CancellationToken.None)).ConfigureAwait(false);
        Require(failure.ReasonCode == "BROKER_EXISTING_PLE_OWNERSHIP_REJECTED", "Foreign Broker ownership must be explicit.");
        Require(rpc.Count("launch_codesys") == 0, "Already-ready Broker PLE must not trigger launch.");
        Require(rpc.Count("open_project") == 0, "Foreign Broker project must not be touched.");
        Require(rpc.Count("shutdown_codesys") == 0, "Foreign Broker PLE must not be shut down.");
    }

    private static async Task CreatedPleIsOwnedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", "none"),
            Status("ready", "persistent", "44001", "created-session", "broker"));
        rpc.ProjectOpenInitially = false;
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);

        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        Require(runtime.McpPid == rpc.ProcessId, "Session evidence must expose the owned MCP child PID.");
        Require(runtime.PleOwnedByBroker, "PLE launched by this Start must be Broker-owned.");
        Require(rpc.Count("launch_codesys") == 1, "Stopped adapter must be launched exactly once.");
        Require(rpc.Count("open_project") == 1, "Broker-owned empty PLE may open the exact project once.");

        await session.StopAsync(CancellationToken.None).ConfigureAwait(false);
        Require(rpc.Count("shutdown_codesys") == 1, "Broker-owned PLE must be shut down exactly once.");
        Require(rpc.StopCalls == 1, "MCP cleanup must follow PLE shutdown.");
    }

    private static async Task ExternalProjectMismatchIsRejectedAsync()
    {
        using var fixture = new Fixture();
        var otherProject = Path.Combine(fixture.StationRoot, "other.project");
        File.WriteAllText(otherProject, "other");
        var rpc = FakeRpc.ExternalReady(otherProject);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);

        var failure = await CaptureAsync(() => session.StartAsync(CancellationToken.None)).ConfigureAwait(false);
        Require(failure.ReasonCode == "BROKER_PROJECT_MISMATCH", "External mismatch must have a stable reason.");
        Require(rpc.Count("open_project") == 0, "External mismatch must not be corrected by Broker.");
        Require(rpc.Count("shutdown_codesys") == 0, "External mismatch must not be shut down.");
    }

    private static async Task OwnedPleShutdownFailurePropagatesAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", "none"),
            Status("ready", "persistent", "45001", "owned-failure", "broker"));
        rpc.ShutdownFails = true;
        var session = new BrokerEngineeringSession(rpc, fixture.Options);
        _ = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var failure = await CaptureAsync(() => session.StopAsync(CancellationToken.None)).ConfigureAwait(false);
        Require(failure.ReasonCode == "BROKER_OWNED_PLE_SHUTDOWN_FAILED", "Shutdown failure must propagate.");
        Require(rpc.Count("shutdown_codesys") == 1, "Shutdown must be attempted once.");
        Require(rpc.StopCalls == 1, "MCP child cleanup must still be attempted.");
        await session.DisposeAsync().ConfigureAwait(false);
    }

    private static async Task FreshZeroBuildStaysBlockedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", "none"),
            Status("ready", "persistent", "46001", "fresh-zero", "broker"),
            Status("ready", "persistent", "46001", "fresh-zero", "broker"));
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        var launchCalls = rpc.Count("launch_codesys");
        var openCalls = rpc.Count("open_project");

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
            "A clean Build must stay blocked until semantic producers exist.");
        Require(rpc.Count("get_compile_messages") == 0, "Cached messages must never decide fresh success.");
        Require(rpc.Count("launch_codesys") == launchCalls && rpc.Count("open_project") == openCalls,
            "Action execution must not launch PLE or open a project.");
        var result = outcome.Observation["result"] as JsonObject
            ?? throw new InvalidOperationException("Blocked result missing.");
        Require(result["build"] is null && result["acceptance"] is null,
            "Blocked observation must not contain success-only Build/acceptance fields.");
    }

    private static async Task MissingFreshSummaryStaysBlockedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", "none"),
            Status("ready", "persistent", "47001", "fresh-missing", "broker"),
            Status("ready", "persistent", "47001", "fresh-missing", "broker"));
        rpc.CompileResponseFactory = () => "Compilation initiated without a structured same-call summary.";
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("verify_after_export_2"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
            "Missing fresh summary must fail closed as a capability blocker.");
        Require(rpc.Count("get_compile_messages") == 0, "Cached messages must not be queried as a fallback.");
        var result = outcome.Observation["result"] as JsonObject
            ?? throw new InvalidOperationException("Blocked result missing.");
        Require(result["acceptance"] is null, "verify_after_export_2 must not fabricate Symbol verification.");
    }

    private static async Task LegacyFreshContractStaysBlockedAsync()
    {
        using var fixture = new Fixture();
        var rpc = FakeRpc.WithStatuses(
            fixture.ProjectPath,
            Status("stopped", "headless", "N/A", "N/A", "none"),
            Status("ready", "persistent", "47501", "fresh-legacy", "broker"),
            Status("ready", "persistent", "47501", "fresh-legacy", "broker"));
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath)
            .Replace("ctrlx-fresh-compile-v2", "ctrlx-fresh-compile-v1", StringComparison.Ordinal);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
            "Legacy fresh evidence must fail closed even when its counts are 0/0.");
        Require(rpc.Count("compile_project") == 1, "The requested Build must run exactly once.");
        Require(rpc.Count("get_compile_messages") == 0, "Cached messages must not rescue a legacy summary.");
    }

    private static string FreshCompile(string projectPath)
    {
        var started = DateTimeOffset.UtcNow;
        var completed = started.AddMilliseconds(1);
        var summary = new JsonObject
        {
            ["contractVersion"] = 1,
            ["producer"] = "codesys-persistent.compile_project",
            ["adapterPatchId"] = "ctrlx-fresh-compile-v2",
            ["buildInvocation"] = "application.build",
            ["fresh"] = true,
            ["verified"] = true,
            ["projectFilePath"] = projectPath,
            ["buildToken"] = Guid.NewGuid().ToString("N"),
            ["startedAtUtc"] = started.ToString("O"),
            ["completedAtUtc"] = completed.ToString("O"),
            ["dirtyPreflightVerified"] = true,
            ["expectedCategoryCoverageVerified"] = true,
            ["allExpectedCategoriesCleared"] = true,
            ["allExpectedCategoriesRead"] = true,
            ["explicitBuildSummaryVerified"] = true,
            ["patchPreflightVerified"] = true,
            ["errorCount"] = 0,
            ["warningCount"] = 0,
            ["messageCount"] = 0,
            ["recordsComplete"] = true,
            ["records"] = new JsonArray()
        };
        return $"### COMPILE_SUMMARY_START ###\n{summary.ToJsonString()}\n### COMPILE_SUMMARY_END ###";
    }

    private static string Status(string state, string mode, string pid, string session, string? ownership) =>
        string.Join(
            '\n',
            new[]
            {
                $"State: {state}",
                $"Mode: {mode}",
                $"PID: {pid}",
                $"Session: {session}",
                ownership is null ? null : $"PLE Ownership: {ownership}",
                ownership is null ? null : "PLE Ownership Contract: ctrlx-ple-ownership-v1"
            }.Where(value => value is not null));

    private static async Task<BrokerEngineeringException> CaptureAsync(Func<Task> action)
    {
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (BrokerEngineeringException exception)
        {
            return exception;
        }

        throw new InvalidOperationException("Expected BrokerEngineeringException was not thrown.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

internal sealed class Fixture : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "ctrlx-broker-engineering-selftest", Guid.NewGuid().ToString("N"));

    public Fixture()
    {
        EngineeringRoot = Path.Combine(root, "engineering");
        StationRoot = Path.Combine(root, "station");
        Directory.CreateDirectory(EngineeringRoot);
        Directory.CreateDirectory(StationRoot);
        ProjectPath = Path.Combine(StationRoot, "fixture.project");
        File.WriteAllText(ProjectPath, "fixture");
        Options = new BrokerHostOptions
        {
            EngineeringRoot = EngineeringRoot,
            StationRoot = StationRoot,
            PlcProject = ProjectPath,
            Profile = "ctrlX PLC 2.6.8",
            Mcp = new McpProcessOptions
            {
                ExecutablePath = Environment.ProcessPath ?? throw new InvalidOperationException("Process path unavailable."),
                WorkingDirectory = root
            },
            SessionStartupTimeout = TimeSpan.FromSeconds(10),
            StatusTimeout = TimeSpan.FromSeconds(1),
            BuildTimeout = TimeSpan.FromMinutes(1)
        };
    }

    public string EngineeringRoot { get; }

    public string StationRoot { get; }

    public string ProjectPath { get; }

    public BrokerHostOptions Options { get; }

    public ValidatedRunnerAction CreateAction(string actionKind)
    {
        var actionId = $"fixture-{actionKind}-0001";
        return new ValidatedRunnerAction(
            EngineeringRoot,
            StationRoot,
            ProjectPath,
            Options.Profile,
            Path.Combine(EngineeringRoot, $"{actionId}.json"),
            RunnerHash.Sha256Text(actionId),
            $"operation-{actionKind}",
            actionId,
            actionKind,
            1,
            DateTimeOffset.UtcNow.AddMinutes(-1),
            RunnerHash.Sha256Text($"idempotency-{actionId}"),
            IsSupported: true,
            UnsupportedReasonCode: null,
            Document: new JsonObject());
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

internal sealed class FakeRpc : IMcpRpcClient
{
    private readonly Queue<string> statuses;
    private readonly List<string> calls = [];
    private string projectPath;

    private FakeRpc(string projectPath, IEnumerable<string> statuses)
    {
        this.projectPath = projectPath;
        this.statuses = new Queue<string>(statuses);
    }

    public static FakeRpc ExternalReady(string projectPath) => WithStatuses(
        projectPath,
        ProgramStatus("ready", "persistent", "42001", "external-session", "external"),
        ProgramStatus("ready", "persistent", "42001", "external-session", "external"));

    public static FakeRpc WithStatuses(string projectPath, params string[] statuses) => new(projectPath, statuses);

    public int? ProcessId => 41000;

    public McpHandshake? Handshake { get; private set; }

    public event Action<string>? StandardErrorReceived
    {
        add { }
        remove { }
    }

    public bool ProjectOpenInitially { get; set; } = true;

    public bool ShutdownFails { get; set; }

    public Func<string>? CompileResponseFactory { get; set; }

    public int StopCalls { get; private set; }

    public int Count(string tool) => calls.Count(value => value == tool);

    public Task<McpHandshake> StartAsync(CancellationToken cancellationToken = default)
    {
        Handshake = new McpHandshake(
            "2025-11-25",
            "fake",
            "1",
            new JsonObject(),
            new Dictionary<string, McpToolDescriptor>());
        return Task.FromResult(Handshake);
    }

    public Task<McpToolCallResult> CallToolAsync(
        string toolName,
        JsonObject? arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        calls.Add(toolName);
        var isError = toolName == "shutdown_codesys" && ShutdownFails;
        var text = toolName switch
        {
            "get_codesys_status" when statuses.Count > 0 => statuses.Dequeue(),
            "get_codesys_status" => throw new InvalidOperationException("No fake status response remains."),
            "open_project" => OpenProject(arguments),
            "compile_project" => CompileResponseFactory?.Invoke()
                ?? throw new InvalidOperationException("No fake compile response configured."),
            "shutdown_codesys" when ShutdownFails => "fake shutdown failure",
            _ => "ok"
        };
        return Task.FromResult(new McpToolCallResult(toolName, isError, [text], new JsonObject()));
    }

    public Task<McpResourceReadResult> ReadResourceAsync(
        string uri,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (uri != "codesys://project/status")
        {
            return Task.FromResult(new McpResourceReadResult(uri, false, ["fixture project structure"], new JsonObject()));
        }

        var open = ProjectOpenInitially;
        var text = $"Project Status:\n  - Project Open: {open}\n  - Project Path: {(open ? projectPath : "N/A")}";
        return Task.FromResult(new McpResourceReadResult(uri, false, [text], new JsonObject()));
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        StopCalls++;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    private string OpenProject(JsonObject? arguments)
    {
        projectPath = arguments?["filePath"]?.GetValue<string>()
            ?? throw new InvalidOperationException("Fake open_project lacks filePath.");
        ProjectOpenInitially = true;
        return "opened";
    }

    private static string ProgramStatus(string state, string mode, string pid, string session, string ownership) =>
        $"State: {state}\nMode: {mode}\nPID: {pid}\nSession: {session}\nPLE Ownership: {ownership}\nPLE Ownership Contract: ctrlx-ple-ownership-v1";
}
