using System.Diagnostics;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
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
            ("C# canonical JSON matches frozen Unicode adapter vector", CanonicalUnicodeVectorMatchesAsync),
            ("C# warning signature matches PowerShell Unicode vector", WarningUnicodeVectorMatchesAsync),
            ("project structure URI preserves Windows drive colon and escapes path segments", ProjectStructureUriPreservesWindowsDriveColonAsync),
            ("external exact session is reused and never shut down", ExternalSessionIsReusedAsync),
            ("missing ownership adapter blocks before launch", MissingOwnershipContractBlocksBeforeLaunchAsync),
            ("already-ready broker-owned PLE is rejected", ExistingBrokerOwnedPleIsRejectedAsync),
            ("PLE created by this Start is owned and shut down", CreatedPleIsOwnedAsync),
            ("external project mismatch is not altered or shut down", ExternalProjectMismatchIsRejectedAsync),
            ("owned PLE shutdown failure propagates after MCP cleanup", OwnedPleShutdownFailurePropagatesAsync),
            ("fresh Build plus all independent semantic proofs succeeds", CompleteSemanticEvidenceSucceedsAsync),
            ("missing reviewed semantic baseline still snapshots then blocks", SemanticBootstrapCollectsThenBlocksAsync),
            ("warning bootstrap captures current multiset then blocks", WarningBootstrapCollectsThenBlocksAsync),
            ("PLE warning truncation sentinel cannot satisfy a reviewed baseline", WarningTruncationSentinelBlocksReviewedBaselineAsync),
            ("formal baseline cannot contain PLE warning truncation signature", WarningTruncationSignatureInvalidatesFormalBaselineAsync),
            ("action-bound warning baseline rejects an atomic file replacement", WarningBaselineFileSwapBlocksAsync),
            ("oversized warning baseline is rejected before JSON parsing", OversizedWarningBaselineBlocksAsync),
            ("oversized semantic scope is rejected before JSON parsing", OversizedSemanticScopeBlocksAsync),
            ("oversized semantic baseline is rejected before JSON parsing", OversizedSemanticBaselineBlocksAsync),
            ("untyped warning rows remain reviewable but cannot be accepted", UntypedWarningRowsBlockAsync),
            ("incomplete diagnostic rows remain blocked", IncompleteDiagnosticRowsBlockAsync),
            ("blocked warning review redacts sensitive values", SensitiveWarningReviewIsRedactedAsync),
            ("untyped diagnostic rows redact credential syntax", SensitiveUntypedDiagnosticRowsAreRedactedAsync),
            ("blocked warning review bounds oversized rows", OversizedWarningReviewIsBoundedAsync),
            ("mapping mismatch cannot be accepted", MappingMismatchBlocksAsync),
            ("Symbol mismatch routes to CpStudio review", SymbolMismatchBlocksAsync),
            ("semantic response at 480 KiB boundary is parsed", SemanticSnapshotAtSizeLimitIsParsedAsync),
            ("large Unicode semantic and warning observation fits Broker wire frame", MaximumUnicodeObservationFitsBrokerPipeAsync),
            ("maximum combined terminal observation fails closed within Broker wire frame", MaximumCombinedObservationFailsClosedAsync),
            ("semantic response over 480 KiB is rejected before parsing", OversizedSemanticSnapshotBlocksAsync),
            ("semantic snapshot captured before Build completion is rejected", StaleSemanticSnapshotBlocksAsync),
            ("unknown mapping record field is rejected", UnknownMappingFieldBlocksAsync),
            ("root connector parameter with empty device index is valid", RootConnectorParameterIsValidAsync),
            ("ownership manifest drift cannot be accepted", OwnershipDriftBlocksAsync),
            ("PLC bytes outside exact Git HEAD cannot be accepted", RecoverableBaselineDriftBlocksAsync),
            ("fresh 0/0 Build without adapter evidence stays blocked", FreshZeroBuildStaysBlockedAsync),
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

    private static Task CanonicalUnicodeVectorMatchesAsync()
    {
        Fixture.VerifyCanonicalVector();
        return Task.CompletedTask;
    }

    private static Task WarningUnicodeVectorMatchesAsync()
    {
        const string expected = "7F47FA28CC13BF9B3405BA3091F44ADB1FDDCBDA88544E39AEAAD06C70357421";
        var actual = BrokerSemanticAcceptance.WarningRecordSignatureSha256(
            code: "  C9001  ",
            message: "温度\t过高   🚀",
            objectPath: " Application/工位😀 ",
            position: "行  22",
            source: " 编译器 ");
        Require(actual == expected,
            $"C# warning canonicalization differs from the frozen PowerShell Unicode/astral vector: actual={actual}.");
        return Task.CompletedTask;
    }

    private static Task ProjectStructureUriPreservesWindowsDriveColonAsync()
    {
        const string projectPath = @"C:\Station Root\测试 project.project";
        const string expected = "codesys://project/C:/Station%20Root/%E6%B5%8B%E8%AF%95%20project.project/structure";

        var actual = BrokerEngineeringSession.ProjectStructureUri(projectPath);

        Require(!actual.Contains("C%3A", StringComparison.OrdinalIgnoreCase),
            $"Windows drive colon must not be encoded in the CODESYS resource URI: {actual}");
        Require(actual == expected,
            $"Project structure URI must preserve the drive colon and escape each remaining segment: {actual}");
        return Task.CompletedTask;
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

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_ADAPTER_RETURNED_ERROR",
            "A clean Build must stay blocked until semantic producers exist.");
        Require(rpc.Count("get_compile_messages") == 0, "Cached messages must never decide fresh success.");
        Require(rpc.Count("launch_codesys") == launchCalls && rpc.Count("open_project") == openCalls,
            "Action execution must not launch PLE or open a project.");
        var result = outcome.Observation["result"] as JsonObject
            ?? throw new InvalidOperationException("Blocked result missing.");
        var build = result["build"] as JsonObject
            ?? throw new InvalidOperationException("Blocked result must retain the fresh Build evidence needed for review.");
        Require(build["verified"]?.GetValue<bool>() == true &&
                build["errors"]?.GetValue<int>() == 0 &&
                build["warnings"]?.GetValue<int>() == 0 &&
                build["messageCount"]?.GetValue<int>() == 0 &&
                build["projectPath"]?.GetValue<string>() == fixture.ProjectPath &&
                build["profile"]?.GetValue<string>() == fixture.Options.Profile &&
                build["projectSha256"]?.GetValue<string>().Equals(
                    RunnerHash.Sha256File(fixture.ProjectPath),
                    StringComparison.OrdinalIgnoreCase) == true &&
                result["acceptance"] is null,
            "Blocked observation must retain bounded fresh Build evidence without claiming acceptance.");
    }

    private static async Task CompleteSemanticEvidenceSucceedsAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-success");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("verify_after_export_2"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "SUCCEEDED" && outcome.ReasonCode == "BUILD_AND_SEMANTICS_VERIFIED",
            "Complete, matching evidence must be able to succeed.");
        Require(rpc.Count("get_ctrlx_semantic_snapshot") == 1,
            "Semantic snapshot must be called exactly once after the fresh Build.");
        var result = outcome.Observation["result"] as JsonObject
            ?? throw new InvalidOperationException("Success result missing.");
        var proofs = result["semanticProofs"] as JsonObject
            ?? throw new InvalidOperationException("Semantic proofs missing.");
        foreach (var name in new[]
        {
            "ownership", "readback", "recoverableBaseline", "warnings",
            "semanticBaseline", "mapping", "symbolPostProcessing"
        })
        {
            Require(proofs[name]?["verified"]?.GetValue<bool>() == true, $"Proof {name} was not verified.");
        }
    }

    private static async Task SemanticBootstrapCollectsThenBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-bootstrap");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        var action = fixture.CreateAction("inspect_and_build", semanticReviewed: false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED",
            "Semantic bootstrap must remain blocked with a stable reason.");
        Require(rpc.Count("get_ctrlx_semantic_snapshot") == 1,
            "Missing reviewed baseline must not prevent actual snapshot collection.");
        var mapping = outcome.Observation["result"]?["semanticProofs"]?["mapping"] as JsonObject
            ?? throw new InvalidOperationException("Mapping candidate proof missing.");
        Require(mapping["verified"]?.GetValue<bool>() == false &&
            mapping["candidateCanonicalFacts"] is JsonObject,
            "Bootstrap observation must retain actual canonical mapping facts without accepting them.");
    }

    private static async Task WarningBootstrapCollectsThenBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "warning-bootstrap");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath, "C0543: fixture warning");
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        var action = fixture.CreateAction("inspect_and_build", warningReviewed: false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "WARNING_BASELINE_BOOTSTRAP_REQUIRED",
            "Unreviewed warning signatures must remain blocked with a stable reason.");
        var warnings = outcome.Observation["result"]?["semanticProofs"]?["warnings"] as JsonObject
            ?? throw new InvalidOperationException("Warning proof missing.");
        Require(warnings["verified"]?.GetValue<bool>() == false &&
            warnings["currentSignatures"] is JsonArray signatures && signatures.Count == 1,
            "Bootstrap observation must retain the complete current warning multiset.");
        var build = outcome.Observation["result"]?["build"] as JsonObject
            ?? throw new InvalidOperationException("Blocked bootstrap observation has no fresh Build evidence.");
        Require(build["errors"]?.GetValue<int>() == 0 &&
            build["warnings"]?.GetValue<int>() == 1 &&
            build["messageCount"]?.GetValue<int>() == 1 &&
            build["verified"]?.GetValue<bool>() == true &&
            !string.IsNullOrWhiteSpace(build["buildId"]?.GetValue<string>()) &&
            build["projectPath"]?.GetValue<string>() == fixture.ProjectPath &&
            build["profile"]?.GetValue<string>() == fixture.Options.Profile &&
            build["projectSha256"]?.GetValue<string>().Equals(
                RunnerHash.Sha256File(fixture.ProjectPath),
                StringComparison.OrdinalIgnoreCase) == true &&
            build["summarySource"]?.GetValue<string>() == "codesys-persistent.compile_project" &&
            DateTimeOffset.TryParse(build["startedAtUtc"]?.GetValue<string>(), out _) &&
            DateTimeOffset.TryParse(build["completedAtUtc"]?.GetValue<string>(), out _) &&
            build["warningRecords"] is JsonArray records &&
            records.Count == 1 &&
            records[0]?.GetValue<string>() == "C0543: fixture warning",
            "Blocked bootstrap must retain bounded raw warning rows and same-call Build metadata for human review.");
    }

    private static async Task WarningTruncationSentinelBlocksReviewedBaselineAsync()
    {
        const string sentinel = "More than 250 warnings occurred:   Skipping all further warning messages";
        using var fixture = new Fixture();
        fixture.SetWarningBaseline(sentinel);
        var rpc = ExecutionRpc(fixture, "warning-truncated");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath, sentinel);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" &&
            outcome.ReasonCode == "PLE_WARNING_OUTPUT_TRUNCATED",
            "A reviewed signature match must not accept PLE's truncated warning population.");
        var warnings = outcome.Observation["result"]?["semanticProofs"]?["warnings"] as JsonObject
            ?? throw new InvalidOperationException("Truncated warning proof missing.");
        Require(warnings["verified"]?.GetValue<bool>() == false &&
            warnings["reasonCode"]?.GetValue<string>() == "PLE_WARNING_OUTPUT_TRUNCATED" &&
            outcome.Observation["result"]?["acceptance"] is null,
            "Truncated PLE output must remain an unverified comparison with no success acceptance envelope.");
    }

    private static async Task WarningTruncationSignatureInvalidatesFormalBaselineAsync()
    {
        const string sentinel = "More than 100 warnings occured: Skipping all further warning messages";
        using var fixture = new Fixture();
        fixture.SetWarningBaseline(sentinel);
        var rpc = ExecutionRpc(fixture, "warning-baseline-truncated");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" &&
            outcome.ReasonCode == "PLE_WARNING_OUTPUT_TRUNCATED" &&
            outcome.Observation["result"]?["semanticProofs"]?["warnings"]?["verified"]?.GetValue<bool>() == false,
            "A formal warning baseline containing the known PLE truncation signature must be rejected even when the new Build has no sentinel.");
    }

    private static async Task WarningBaselineFileSwapBlocksAsync()
    {
        using var fixture = new Fixture();
        var action = fixture.CreateAction("inspect_and_build");
        fixture.AtomicSwapWarningBaseline("{\"schemaVersion\":1,\"replacement\":true}");
        var rpc = ExecutionRpc(fixture, "warning-baseline-file-swap");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "WARNING_BASELINE_DRIFT",
            $"An atomic replacement after action binding must fail the same-byte hash/parse gate; actual={outcome.ReasonCode}.");
    }

    private static async Task OversizedWarningBaselineBlocksAsync()
    {
        using var fixture = new Fixture();
        var action = fixture.CreateAction("inspect_and_build");
        fixture.OverwriteWarningBaseline(new string('w', (2 * 1024 * 1024) + 1));
        var rpc = ExecutionRpc(fixture, "warning-baseline-too-large");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "WARNING_BASELINE_TOO_LARGE",
            $"An oversized warning baseline must fail before allocation/parsing; actual={outcome.ReasonCode}.");
    }

    private static async Task OversizedSemanticScopeBlocksAsync()
    {
        using var fixture = new Fixture();
        var action = fixture.CreateAction("inspect_and_build");
        fixture.OverwriteSemanticScope(new string('s', (256 * 1024) + 1));
        var rpc = ExecutionRpc(fixture, "semantic-scope-too-large");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_SCOPE_TOO_LARGE",
            $"An oversized semantic scope must fail before allocation/parsing; actual={outcome.ReasonCode}.");
    }

    private static async Task OversizedSemanticBaselineBlocksAsync()
    {
        using var fixture = new Fixture();
        var action = fixture.CreateAction("inspect_and_build");
        fixture.OverwriteSemanticBaseline(new string('b', (2 * 1024 * 1024) + 1));
        var rpc = ExecutionRpc(fixture, "semantic-baseline-too-large");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_BASELINE_TOO_LARGE",
            $"An oversized semantic baseline must fail before allocation/parsing; actual={outcome.ReasonCode}.");
    }

    private static async Task SensitiveWarningReviewIsRedactedAsync()
    {
        foreach (var sensitive in SensitiveDiagnosticCases())
        {
            using var fixture = new Fixture();
            var rpc = ExecutionRpc(fixture, $"warning-sensitive-{sensitive.Name}");
            rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath, $"C9002: {sensitive.Text}");
            rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
            await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
            var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

            var outcome = await session.ExecuteAsync(
                fixture.CreateAction("inspect_and_build", warningReviewed: false),
                runtime,
                CancellationToken.None).ConfigureAwait(false);

            var build = outcome.Observation["result"]?["build"] as JsonObject
                ?? throw new InvalidOperationException("Unsafe warning Build evidence is missing.");
            var serialized = outcome.Observation.ToJsonString();
            Require(outcome.ReasonCode == "WARNING_RECORDS_UNSAFE_FOR_REVIEW" &&
                build["warningRecordsSafeForReview"]?.GetValue<bool>() == false &&
                build["warningRecords"] is JsonArray warningRecords && warningRecords.Count == 0 &&
                build["diagnosticRows"] is JsonArray diagnosticRows &&
                diagnosticRows.Count == 1 &&
                diagnosticRows[0]?.GetValue<string>() == "[REDACTED_SENSITIVE_DIAGNOSTIC]" &&
                !serialized.Contains(sensitive.Secret, StringComparison.Ordinal),
                $"Secret-bearing typed warning '{sensitive.Name}' was not safely redacted.");
        }
    }

    private static Task SensitiveUntypedDiagnosticRowsAreRedactedAsync()
    {
        var cases = SensitiveDiagnosticCases();
        var rows = BrokerSemanticAcceptance.ObservationDiagnosticRows(
            cases.Select(item => $"C9004: {item.Text}").ToArray());
        Require(rows.Count == cases.Length && rows.All(row =>
                row?.GetValue<string>() == "[REDACTED_SENSITIVE_DIAGNOSTIC]"),
            "Every untyped credential syntax must become the constant sensitive-diagnostic placeholder.");
        var serialized = rows.ToJsonString();
        foreach (var sensitive in cases)
        {
            Require(!serialized.Contains(sensitive.Secret, StringComparison.Ordinal),
                $"Untyped diagnostic '{sensitive.Name}' retained its raw credential value.");
        }

        return Task.CompletedTask;
    }

    private static async Task UntypedWarningRowsBlockAsync()
    {
        const string diagnostic = "C9004: 未分类告警 🚀";
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "warning-untyped");
        rpc.CompileResponseFactory = () => FreshCompileUntyped(
            fixture.ProjectPath,
            diagnosticRowsComplete: true,
            diagnostic);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "WARNING_RECORDS_UNTYPED" &&
            rpc.Count("get_ctrlx_semantic_snapshot") == 1,
            "Untyped warning rows must allow actual semantic collection but can never produce acceptance.");
        var build = outcome.Observation["result"]?["build"] as JsonObject
            ?? throw new InvalidOperationException("Untyped Build review evidence is missing.");
        Require(build["typedRecordsVerified"]?.GetValue<bool>() == false &&
            build["diagnosticRowsComplete"]?.GetValue<bool>() == true &&
            build["warningRecords"] is JsonArray warningRecords && warningRecords.Count == 0 &&
            build["diagnosticRows"] is JsonArray diagnosticRows &&
            diagnosticRows.Count == 1 && diagnosticRows[0]?.GetValue<string>() == diagnostic,
            "Untyped Build evidence must retain bounded diagnostic rows without inventing warning signatures.");
    }

    private static async Task IncompleteDiagnosticRowsBlockAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "warning-incomplete");
        rpc.CompileResponseFactory = () => FreshCompileUntyped(
            fixture.ProjectPath,
            diagnosticRowsComplete: false);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "WARNING_RECORDS_INCOMPLETE" &&
            outcome.Observation["result"]?["semanticProofs"]?["warnings"]?["verified"]?.GetValue<bool>() == false,
            "Incomplete diagnostic rows must remain blocked and cannot produce reviewed warning proof.");
    }

    private static async Task OversizedWarningReviewIsBoundedAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "warning-oversized");
        rpc.CompileResponseFactory = () => FreshCompile(
            fixture.ProjectPath,
            "C9003: " + new string('测', 5000));
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build", warningReviewed: false),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        var build = outcome.Observation["result"]?["build"] as JsonObject
            ?? throw new InvalidOperationException("Oversized warning Build evidence is missing.");
        Require(outcome.ReasonCode == "WARNING_RECORDS_UNSAFE_FOR_REVIEW" &&
            build["warningRecordsSafeForReview"]?.GetValue<bool>() == false &&
            build["warningRecords"] is JsonArray warningRecords && warningRecords.Count == 0 &&
            Encoding.UTF8.GetByteCount(outcome.Observation.ToJsonString()) < 64 * 1024,
            "Oversized typed warnings must block without expanding the bounded local observation.");
    }

    private static async Task MappingMismatchBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "mapping-mismatch");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot(actualVariable: "Application.Other.Binding");
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "MAPPING_CANONICAL_SHA_MISMATCH",
            $"Mapping mismatch must block with a stable reason; actual={outcome.ReasonCode}.");
        Require(outcome.Observation["result"]?["semanticProofs"]?["mapping"]?["verified"]?.GetValue<bool>() == false,
            "Mapping mismatch must not be converted into a pass Boolean.");
    }

    private static async Task SymbolMismatchBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "symbol-mismatch");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot(symbolRevision: 2);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("verify_after_export_2"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SYMBOL_BASELINE_MISMATCH",
            "Symbol mismatch must block with a stable reason.");
        Require(outcome.Observation["result"]?["semanticProofs"]?["symbolPostProcessing"]?["verified"]?.GetValue<bool>() == false,
            "Symbol mismatch must not be accepted.");
        Require(outcome.Observation["result"]?["nextRoute"]?["kind"]?.GetValue<string>() == "cpstudio-change-review",
            "verify_after_export_2 Symbol mismatch must route to CpStudio change review.");
    }

    private static async Task OwnershipDriftBlocksAsync()
    {
        using var fixture = new Fixture();
        var action = fixture.CreateAction("inspect_and_build");
        File.AppendAllText(fixture.OwnershipPath, "\n# drift");
        var rpc = ExecutionRpc(fixture, "ownership-drift");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(action, runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "OWNERSHIP_MANIFEST_DRIFT" &&
            outcome.Observation["result"]?["semanticProofs"]?["ownership"]?["verified"]?.GetValue<bool>() == false,
            "Ownership drift must block semantic acceptance.");
    }

    private static async Task StaleSemanticSnapshotBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-stale");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot(capturedAtUtc: DateTimeOffset.UtcNow.AddMinutes(-1));
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_ADAPTER_CORRELATION_INVALID",
            "A pre-Build semantic snapshot must not be accepted by the same-call Build gate.");
    }

    private static async Task UnknownMappingFieldBlocksAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-extra-field");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = fixture.CreateSemanticSnapshotWithUnknownMappingField;
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_PROOF_SCHEMA_INVALID",
            "Unknown mapping record fields must be rejected before they enter evidence.");
    }

    private static async Task RootConnectorParameterIsValidAsync()
    {
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-root-connector");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = fixture.CreateRootConnectorSemanticSnapshot;
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "MAPPING_CANONICAL_SHA_MISMATCH",
            $"A valid root connector parameter must reach baseline comparison instead of schema rejection; actual={outcome.ReasonCode}.");
    }

    private static async Task OversizedSemanticSnapshotBlocksAsync()
    {
        const int maximumSemanticSnapshotBytes = 480 * 1024;
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-oversized");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => "{" + new string('x', maximumSemanticSnapshotBytes);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "SEMANTIC_SNAPSHOT_TOO_LARGE",
            $"Oversized semantic evidence must be rejected with its stable bounded-response reason; actual={outcome.ReasonCode}.");
    }

    private static async Task SemanticSnapshotAtSizeLimitIsParsedAsync()
    {
        const int maximumSemanticSnapshotBytes = 480 * 1024;
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-at-size-limit");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshotAtByteCount(maximumSemanticSnapshotBytes);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "MAPPING_CANONICAL_SHA_MISMATCH",
            $"A semantic response exactly at 480 KiB must pass the size gate and reach semantic comparison; actual={outcome.ReasonCode}.");
    }

    private static async Task MaximumUnicodeObservationFitsBrokerPipeAsync()
    {
        const int largeSemanticSnapshotBytes = 256 * 1024;
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-wire-unicode");
        var warnings = Enumerable.Range(0, 64)
            .Select(index => $"C91{index:00}: " + new string('测', 1340) + " 🚀")
            .ToArray();
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath, warnings);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshotAtByteCount(largeSemanticSnapshotBytes);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build", warningReviewed: false, semanticReviewed: false),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED",
            "A bootstrap candidate with unreviewed warnings must remain blocked.");
        var escapedBytes = Encoding.UTF8.GetByteCount(outcome.Observation.ToJsonString());
        Require(escapedBytes > BrokerWireProtocol.MaximumMessageBytes,
            "The regression fixture no longer proves that default JSON Unicode escaping would overflow the Broker frame.");

        using var stream = new MemoryStream();
        await BrokerPipeCodec.WriteAsync(stream, outcome.Observation, CancellationToken.None).ConfigureAwait(false);
        Require(stream.Length - 1 <= BrokerWireProtocol.MaximumMessageBytes,
            "Literal UTF-8 Broker serialization exceeded the one-MiB body limit.");
        var wireText = Encoding.UTF8.GetString(stream.ToArray());
        stream.Position = 0;
        var roundTrip = await BrokerPipeCodec.ReadAsync(stream, CancellationToken.None).ConfigureAwait(false);
        Require(JsonNode.DeepEquals(roundTrip, outcome.Observation) && wireText.Contains("🚀", StringComparison.Ordinal),
            "The maximum Unicode/emoji semantic and warning observation did not round-trip through the real Broker codec.");
    }

    private static async Task MaximumCombinedObservationFailsClosedAsync()
    {
        const int maximumSemanticSnapshotBytes = 480 * 1024;
        using var fixture = new Fixture();
        var rpc = ExecutionRpc(fixture, "semantic-wire-maximum-combination");
        var warnings = Enumerable.Range(0, 2048)
            .Select(index => $"C{index:0000}: distinct warning {index:0000} " + new string('w', 72))
            .ToArray();
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath, warnings);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshotAtByteCount(maximumSemanticSnapshotBytes);
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build", warningReviewed: false, semanticReviewed: false),
            runtime,
            CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" &&
            outcome.ReasonCode == "TERMINAL_OBSERVATION_TOO_LARGE" &&
            outcome.Observation["result"]?["reasonCode"]?.GetValue<string>() == "TERMINAL_OBSERVATION_TOO_LARGE" &&
            BrokerPipeCodec.SerializedUtf8ByteCount(outcome.Observation) <= BrokerWireProtocol.MaximumTerminalObservationBytes,
            "Maximum combined warning/signature/semantic evidence must be replaced by a stable bounded terminal observation.");

        using var stream = new MemoryStream();
        await BrokerPipeCodec.WriteAsync(stream, outcome.Observation, CancellationToken.None).ConfigureAwait(false);
        Require(stream.Length - 1 <= BrokerWireProtocol.MaximumMessageBytes,
            "Bounded maximum-combination fallback exceeded the Broker wire frame.");
        stream.Position = 0;
        var roundTrip = await BrokerPipeCodec.ReadAsync(stream, CancellationToken.None).ConfigureAwait(false);
        Require(JsonNode.DeepEquals(roundTrip, outcome.Observation),
            "Maximum-combination fallback did not round-trip through the real Broker codec.");
    }

    private static async Task RecoverableBaselineDriftBlocksAsync()
    {
        using var fixture = new Fixture();
        File.WriteAllText(fixture.ProjectPath, "fixture-not-at-head");
        var rpc = ExecutionRpc(fixture, "git-drift");
        rpc.CompileResponseFactory = () => FreshCompile(fixture.ProjectPath);
        rpc.SemanticResponseFactory = () => fixture.CreateSemanticSnapshot();
        await using var session = new BrokerEngineeringSession(rpc, fixture.Options);
        var runtime = await session.StartAsync(CancellationToken.None).ConfigureAwait(false);

        var outcome = await session.ExecuteAsync(
            fixture.CreateAction("inspect_and_build"), runtime, CancellationToken.None).ConfigureAwait(false);

        Require(outcome.TerminalState == "BLOCKED" && outcome.ReasonCode == "RECOVERABLE_BASELINE_NOT_AT_HEAD" &&
            outcome.Observation["result"]?["semanticProofs"]?["recoverableBaseline"]?["verified"]?.GetValue<bool>() == false,
            "Working PLC bytes that differ from Git HEAD must block acceptance.");
    }

    private static FakeRpc ExecutionRpc(Fixture fixture, string sessionId) => FakeRpc.WithStatuses(
        fixture.ProjectPath,
        Status("stopped", "headless", "N/A", "N/A", "none"),
        Status("ready", "persistent", "48001", sessionId, "broker"),
        Status("ready", "persistent", "48001", sessionId, "broker"));

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

    private static (string Name, string Text, string Secret)[] SensitiveDiagnosticCases() =>
    [
        ("password", "password=credential-password-01", "credential-password-01"),
        ("passwd", "passwd=credential-passwd-02", "credential-passwd-02"),
        ("pwd", "pwd=credential-pwd-03", "credential-pwd-03"),
        ("bearer", "Authorization: Bearer bearer-credential-04", "bearer-credential-04"),
        ("basic", "Authorization: Basic QWxhZGRpbjpvcGVuLXNlc2FtZQ==", "QWxhZGRpbjpvcGVuLXNlc2FtZQ=="),
        ("access-token", "access_token=access-credential-05", "access-credential-05"),
        ("refresh-token", "refresh-token=refresh-credential-06", "refresh-credential-06"),
        ("api-key", "api-key=api-credential-07", "api-credential-07"),
        ("url-userinfo", "https://operator:url-credential-08@plc.local/symbols", "url-credential-08")
    ];

    private static string FreshCompile(string projectPath, params string[] warnings)
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
            ["warningCount"] = warnings.Length,
            ["messageCount"] = warnings.Length,
            ["recordsComplete"] = true,
            ["typedRecordsVerified"] = true,
            ["diagnosticRowsComplete"] = true,
            ["diagnosticRows"] = new JsonArray(warnings.Select(value => (JsonNode)value).ToArray()),
            ["records"] = new JsonArray(warnings.Select(value =>
                (JsonNode)new JsonObject
                {
                    ["severity"] = "warning",
                    ["text"] = value
                }).ToArray())
        };
        return $"### COMPILE_SUMMARY_START ###\n{summary.ToJsonString()}\n### COMPILE_SUMMARY_END ###";
    }

    private static string FreshCompileUntyped(
        string projectPath,
        bool diagnosticRowsComplete,
        params string[] diagnosticRows)
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
            ["warningCount"] = 1,
            ["messageCount"] = 1,
            ["recordsComplete"] = true,
            ["typedRecordsVerified"] = false,
            ["diagnosticRowsComplete"] = diagnosticRowsComplete,
            ["diagnosticRows"] = new JsonArray(diagnosticRows.Select(value => (JsonNode)value).ToArray()),
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
    private readonly DateTimeOffset reviewTime = DateTimeOffset.UtcNow.AddMinutes(-10);
    private readonly string warningBaselinePath;
    private readonly string warningEvidencePath;
    private readonly string semanticScopePath;
    private readonly string semanticBaselinePath;
    private readonly string semanticEvidencePath;

    public Fixture()
    {
        EngineeringRoot = Path.Combine(root, "engineering");
        StationRoot = Path.Combine(root, "station");
        Directory.CreateDirectory(EngineeringRoot);
        Directory.CreateDirectory(StationRoot);
        ProjectPath = Path.Combine(StationRoot, "fixture.project");
        File.WriteAllText(ProjectPath, "fixture");
        OwnershipPath = Path.Combine(EngineeringRoot, "ai", "ownership.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(OwnershipPath)!);
        File.WriteAllText(OwnershipPath, "schemaVersion: 1\nobjects: []\n");

        var config = Path.Combine(EngineeringRoot, "config");
        var evidence = Path.Combine(EngineeringRoot, "data", "evidence");
        Directory.CreateDirectory(config);
        Directory.CreateDirectory(evidence);
        warningBaselinePath = Path.Combine(config, "warning-signature-baseline.json");
        warningEvidencePath = Path.Combine(evidence, "warning-review.txt");
        semanticScopePath = Path.Combine(config, "engineering-semantic-scope.json");
        semanticBaselinePath = Path.Combine(config, "engineering-semantic-baseline.json");
        semanticEvidencePath = Path.Combine(evidence, "semantic-review.txt");
        File.WriteAllText(warningEvidencePath, "Reviewed empty fresh-Build warning multiset.");
        File.WriteAllText(semanticEvidencePath, "Reviewed fake semantic snapshot for self-test.");

        WriteJson(semanticScopePath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-engineering-semantic-scope",
            ["project"] = ProjectIdentity(),
            ["mappingScopes"] = new JsonArray
            {
                new JsonObject
                {
                    ["devicePath"] = "Device/Realtime_Data",
                    ["recursive"] = true,
                    ["includeAllMappableChannels"] = true
                }
            },
            ["symbolApplicationPath"] = "Device/Plc Logic/Application"
        });

        WriteJson(warningBaselinePath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-warning-signature-baseline",
            ["project"] = ProjectIdentity(),
            ["signatureAlgorithm"] = "sha256:v1:normalized-warning-record",
            ["signatures"] = new JsonArray(),
            ["review"] = Review(
                "warning-review-0001",
                "Runner self-test reviewer",
                "data/evidence/warning-review.txt",
                RunnerHash.Sha256File(warningEvidencePath))
        });

        var canonicalFacts = SemanticCanonicalFacts("Application.Peripherals.测量通道_1", 1);
        WriteJson(semanticBaselinePath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-engineering-semantic-baseline",
            ["project"] = ProjectIdentity(),
            ["scopeSha256"] = RunnerHash.Sha256File(semanticScopePath),
            ["canonicalFacts"] = canonicalFacts.DeepClone(),
            ["hashes"] = SemanticHashes(canonicalFacts),
            ["review"] = Review(
                "semantic-review-0001",
                "Runner self-test reviewer",
                "data/evidence/semantic-review.txt",
                RunnerHash.Sha256File(semanticEvidencePath))
        });

        RunGit("init", "--quiet");
        RunGit("config", "user.email", "runner-selftest@example.invalid");
        RunGit("config", "user.name", "Runner SelfTest");
        RunGit("add", "fixture.project");
        RunGit("commit", "--quiet", "-m", "fixture baseline");

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

    public string OwnershipPath { get; }

    public BrokerHostOptions Options { get; }

    public void AtomicSwapWarningBaseline(string content)
    {
        var replacement = warningBaselinePath + ".replacement";
        File.WriteAllText(replacement, content);
        File.Move(replacement, warningBaselinePath, overwrite: true);
    }

    public void OverwriteWarningBaseline(string content) => File.WriteAllText(warningBaselinePath, content);

    public void OverwriteSemanticScope(string content) => File.WriteAllText(semanticScopePath, content);

    public void OverwriteSemanticBaseline(string content) => File.WriteAllText(semanticBaselinePath, content);

    public void SetWarningBaseline(params string[] warningRecords)
    {
        var counts = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var warning in warningRecords)
        {
            var sha = BrokerSemanticAcceptance.WarningRecordSignatureSha256(
                code: string.Empty,
                message: warning,
                objectPath: string.Empty,
                position: string.Empty,
                source: string.Empty);
            counts[sha] = counts.TryGetValue(sha, out var count) ? count + 1 : 1;
        }

        WriteJson(warningBaselinePath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-warning-signature-baseline",
            ["project"] = ProjectIdentity(),
            ["signatureAlgorithm"] = "sha256:v1:normalized-warning-record",
            ["signatures"] = new JsonArray(counts.Select(item =>
                (JsonNode)new JsonObject
                {
                    ["sha256"] = item.Key,
                    ["occurrences"] = item.Value
                }).ToArray()),
            ["review"] = Review(
                "warning-review-0001",
                "Runner self-test reviewer",
                "data/evidence/warning-review.txt",
                RunnerHash.Sha256File(warningEvidencePath))
        });
    }

    public ValidatedRunnerAction CreateAction(
        string actionKind,
        bool warningReviewed = true,
        bool semanticReviewed = true)
    {
        var actionId = $"fixture-{actionKind}-0001";
        var warningReference = warningReviewed
            ? ReviewedReference(
                "config/warning-signature-baseline.json",
                warningBaselinePath,
                "data/evidence/warning-review.txt",
                warningEvidencePath)
            : MissingReference("config/warning-signature-baseline.json");
        var semanticReference = semanticReviewed
            ? ReviewedReference(
                "config/engineering-semantic-baseline.json",
                semanticBaselinePath,
                "data/evidence/semantic-review.txt",
                semanticEvidencePath)
            : MissingReference("config/engineering-semantic-baseline.json");
        var document = new JsonObject
        {
            ["preconditions"] = new JsonObject
            {
                ["manifests"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["path"] = "ai/ownership.yaml",
                        ["exists"] = true,
                        ["sha256"] = RunnerHash.Sha256File(OwnershipPath)
                    }
                },
                ["warningBaseline"] = warningReference,
                ["semanticSnapshotRequest"] = new JsonObject
                {
                    ["path"] = "config/engineering-semantic-scope.json",
                    ["sha256"] = RunnerHash.Sha256File(semanticScopePath)
                },
                ["semanticBaseline"] = semanticReference
            }
        };
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
            DateTimeOffset.UtcNow,
            RunnerHash.Sha256Text($"idempotency-{actionId}"),
            IsSupported: true,
            UnsupportedReasonCode: null,
            Document: document);
    }

    public string CreateSemanticSnapshot(
        string actualVariable = "Application.Peripherals.测量通道_1",
        int symbolRevision = 1,
        DateTimeOffset? capturedAtUtc = null)
    {
        var facts = SemanticCanonicalFacts(actualVariable, symbolRevision);
        var symbolPayload = new JsonObject
        {
            ["revision"] = symbolRevision,
            ["symbols"] = new JsonArray("Application.Station")
        };
        return CanonicalJson(new JsonObject
        {
            ["contractVersion"] = 1,
            ["contractId"] = "ctrlx-semantic-snapshot-v1",
            ["producer"] = "codesys-persistent.get_ctrlx_semantic_snapshot",
            ["adapterPatchId"] = "ctrlx-semantic-snapshot-v1",
            ["capturedAtUtc"] = (capturedAtUtc ?? DateTimeOffset.UtcNow).ToString("O"),
            ["projectFilePath"] = ProjectPath,
            ["dirtyStateVerified"] = true,
            ["projectDirty"] = false,
            ["recordsComplete"] = true,
            ["stableAcrossRead"] = true,
            ["sources"] = new JsonObject
            {
                ["mapping"] = "PLE ScriptEngine double-read",
                ["symbolConfig"] = new JsonObject
                {
                    ["source"] = "PLE REST api v2 GET",
                    ["applicationPath"] = "Device/Plc Logic/Application",
                    ["endpointPath"] = "/api/v2/symbol-configuration",
                    ["httpStatus"] = 200,
                    ["rawPayloadByteCount"] = Encoding.UTF8.GetByteCount(symbolPayload.ToJsonString())
                }
            },
            ["canonicalFacts"] = facts.DeepClone(),
            ["hashes"] = SemanticHashes(facts)
        });
    }

    public string CreateSemanticSnapshotAtByteCount(int targetBytes)
    {
        var empty = CreateSemanticSnapshot(actualVariable: string.Empty);
        var emptyBytes = Encoding.UTF8.GetByteCount(empty);
        if (targetBytes < emptyBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(targetBytes),
                $"Target size {targetBytes} is below the fixture minimum {emptyBytes}.");
        }

        var remaining = targetBytes - emptyBytes;
        var padding = new StringBuilder(remaining / 3);
        const string unicodeChunk = "测🚀";
        const int unicodeChunkBytes = 7;
        while (remaining >= unicodeChunkBytes)
        {
            padding.Append(unicodeChunk);
            remaining -= unicodeChunkBytes;
        }

        padding.Append('x', remaining);
        var snapshot = CreateSemanticSnapshot(actualVariable: padding.ToString());
        var actualBytes = Encoding.UTF8.GetByteCount(snapshot);
        if (actualBytes != targetBytes)
        {
            throw new InvalidOperationException(
                $"Semantic boundary fixture did not reach the exact requested UTF-8 size: expected={targetBytes}, actual={actualBytes}.");
        }

        return snapshot;
    }

    public string CreateSemanticSnapshotWithUnknownMappingField()
    {
        var snapshot = JsonNode.Parse(CreateSemanticSnapshot()) as JsonObject
            ?? throw new InvalidOperationException("Fake semantic snapshot is invalid.");
        var facts = snapshot["canonicalFacts"] as JsonObject
            ?? throw new InvalidOperationException("Fake semantic facts are missing.");
        var record = facts["mapping"]?["records"]?[0] as JsonObject
            ?? throw new InvalidOperationException("Fake mapping record is missing.");
        record["unexpectedField"] = "must-not-enter-evidence";
        snapshot["hashes"] = SemanticHashes(facts);
        return snapshot.ToJsonString();
    }

    public string CreateRootConnectorSemanticSnapshot()
    {
        var snapshot = JsonNode.Parse(CreateSemanticSnapshot()) as JsonObject
            ?? throw new InvalidOperationException("Fake semantic snapshot is invalid.");
        var facts = snapshot["canonicalFacts"] as JsonObject
            ?? throw new InvalidOperationException("Fake semantic facts are missing.");
        var record = facts["mapping"]?["records"]?[0] as JsonObject
            ?? throw new InvalidOperationException("Fake mapping record is missing.");
        record["deviceIndexPath"] = string.Empty;
        record["sourceKind"] = "connector-parameter";
        record["parameterSetKind"] = "parameters";
        record["connectorIndex"] = null;
        record["parameterIndex"] = 0;
        record["parameterId"] = "root-parameter";
        record["parameterName"] = "Root parameter";
        snapshot["hashes"] = SemanticHashes(facts);
        return snapshot.ToJsonString();
    }

    public static void VerifyCanonicalVector()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        string? vectorPath = null;
        while (directory is not null)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "patches",
                "codesys-mcp-persistent-crlf",
                "semantic-canonical-vectors.json");
            if (File.Exists(candidate))
            {
                vectorPath = candidate;
                break;
            }

            directory = directory.Parent;
        }

        if (vectorPath is null)
        {
            throw new InvalidOperationException("Frozen semantic canonical vector was not found.");
        }

        var root = JsonNode.Parse(File.ReadAllText(vectorPath)) as JsonObject
            ?? throw new InvalidOperationException("Frozen semantic canonical vector is invalid.");
        var vector = root["vectors"]?[0] as JsonObject
            ?? throw new InvalidOperationException("Frozen semantic canonical vector has no first case.");
        var payload = vector["symbolPayloadInput"]
            ?? throw new InvalidOperationException("Frozen vector payload is missing.");
        var payloadJson = CanonicalJson(payload);
        if (payloadJson != vector["expectedSymbolPayloadCanonicalJson"]?.GetValue<string>() ||
            Encoding.UTF8.GetByteCount(payloadJson) != vector["expectedSymbolPayloadUtf8Bytes"]?.GetValue<int>() ||
            !RunnerHash.Sha256Text(payloadJson).Equals(
                vector["expectedSymbolPayloadSha256"]?.GetValue<string>(),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"C# canonical Symbol payload differs from the frozen adapter vector. actual={payloadJson}; bytes={Encoding.UTF8.GetByteCount(payloadJson)}; sha={RunnerHash.Sha256Text(payloadJson)}");
        }

        var facts = vector["canonicalFactsInput"] as JsonObject
            ?? throw new InvalidOperationException("Frozen vector canonical facts are missing.");
        var factsJson = CanonicalJson(facts);
        if (factsJson != vector["expectedCanonicalFactsJson"]?.GetValue<string>() ||
            !CanonicalSha(facts).Equals(vector["expectedSnapshotSha256"]?.GetValue<string>(), StringComparison.OrdinalIgnoreCase) ||
            !CanonicalSha(facts["mapping"]!).Equals(vector["expectedMappingSha256"]?.GetValue<string>(), StringComparison.OrdinalIgnoreCase) ||
            !CanonicalSha(facts["symbolConfig"]!).Equals(vector["expectedSymbolConfigSha256"]?.GetValue<string>(), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("C# canonical facts hashes differ from the frozen adapter vector.");
        }
    }

    private JsonObject ProjectIdentity() => new()
    {
        ["plcProjectRelativePath"] = "fixture.project",
        ["profile"] = "ctrlX PLC 2.6.8"
    };

    private JsonObject Review(
        string reviewId,
        string reviewer,
        string evidencePath,
        string evidenceSha256) => new()
    {
        ["reviewId"] = reviewId,
        ["reviewer"] = reviewer,
        ["reviewedAtUtc"] = reviewTime.ToString("O"),
        ["evidencePath"] = evidencePath,
        ["evidenceSha256"] = evidenceSha256
    };

    private static JsonObject ReviewedReference(
        string relativePath,
        string fullPath,
        string evidenceRelativePath,
        string evidenceFullPath) => new()
    {
        ["state"] = "reviewed",
        ["path"] = relativePath,
        ["sha256"] = RunnerHash.Sha256File(fullPath),
        ["reviewEvidence"] = new JsonObject
        {
            ["path"] = evidenceRelativePath,
            ["sha256"] = RunnerHash.Sha256File(evidenceFullPath)
        }
    };

    private static JsonObject MissingReference(string relativePath) => new()
    {
        ["state"] = "missing-bootstrap",
        ["path"] = relativePath
    };

    private static JsonObject SemanticCanonicalFacts(string actualVariable, int symbolRevision)
    {
        var canonicalMapping = new JsonObject
        {
            ["scopeCount"] = 1,
            ["explicitTargetCount"] = 0,
            ["recordCount"] = 1,
            ["recordLimit"] = 2048,
            ["scopes"] = new JsonArray
            {
                new JsonObject
                {
                    ["scopeIndex"] = 0,
                    ["devicePath"] = "Device/Realtime_Data",
                    ["recursive"] = true,
                    ["rootName"] = "Realtime_Data",
                    ["recordCount"] = 1
                }
            },
            ["records"] = new JsonArray(MappingRecord(actualVariable))
        };
        var payload = new JsonObject
        {
            ["revision"] = symbolRevision,
            ["symbols"] = new JsonArray("Application.Station")
        };
        var canonicalPayloadText = CanonicalJson(payload);
        var canonicalSymbol = new JsonObject
        {
            ["applicationPath"] = "Device/Plc Logic/Application",
            ["canonicalPayloadByteCount"] = Encoding.UTF8.GetByteCount(canonicalPayloadText),
            ["payloadSha256"] = RunnerHash.Sha256Text(canonicalPayloadText),
            ["shapeSummary"] = new JsonObject
            {
                ["rootKind"] = "object",
                ["topLevelKeys"] = new JsonArray("revision", "symbols"),
                ["objectCount"] = 1,
                ["arrayCount"] = 1,
                ["scalarCount"] = 2,
                ["nodeCount"] = 4,
                ["maxDepth"] = 2
            }
        };
        return (JsonObject)Canonicalize(new JsonObject
        {
            ["mapping"] = canonicalMapping,
            ["symbolConfig"] = canonicalSymbol
        })!;
    }

    private static JsonObject MappingRecord(string actualVariable) => new()
    {
        ["recordKind"] = "scope-channel",
        ["scopeIndex"] = 0,
        ["scopeDevicePath"] = "Device/Realtime_Data",
        ["relativeDevicePath"] = "",
        ["deviceIndexPath"] = "0",
        ["deviceName"] = "Channel_1",
        ["sourceKind"] = "tree-channel",
        ["channelIdentity"] = "scope:000000:tree:0",
        ["channelName"] = "Channel_1",
        ["bindingSource"] = "io_mapping",
        ["actualVariable"] = actualVariable
    };

    private static JsonObject SemanticHashes(JsonObject canonicalFacts)
    {
        var mapping = canonicalFacts["mapping"]!;
        var symbol = canonicalFacts["symbolConfig"]!;
        return new JsonObject
        {
            ["algorithm"] = "SHA-256",
            ["canonicalization"] = "ctrlx-semantic-canonical-json-v1",
            ["mappingSha256"] = CanonicalSha(mapping),
            ["symbolConfigSha256"] = CanonicalSha(symbol),
            ["snapshotSha256"] = CanonicalSha(canonicalFacts)
        };
    }

    private static string CanonicalSha(JsonNode node) => RunnerHash.Sha256Text(CanonicalJson(node));

    private static string CanonicalJson(JsonNode node)
    {
        var serialized = Canonicalize(node)!.ToJsonString(new JsonSerializerOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            WriteIndented = false
        });
        serialized = Regex.Replace(
            serialized,
            "(?<!\\\\)\\\\u(?<high>D[89ABab][0-9A-Fa-f]{2})\\\\u(?<low>D[C-Fc-f][0-9A-Fa-f]{2})",
            match => char.ConvertFromUtf32(char.ConvertToUtf32(
                (char)int.Parse(match.Groups["high"].Value, System.Globalization.NumberStyles.HexNumber),
                (char)int.Parse(match.Groups["low"].Value, System.Globalization.NumberStyles.HexNumber))));
        return Regex.Replace(
            serialized,
            "(?<!\\\\)\\\\u(?<code>[0-9A-Fa-f]{4})",
            match =>
            {
                var code = int.Parse(match.Groups["code"].Value, System.Globalization.NumberStyles.HexNumber);
                return code >= 0x20 && code is not (0x22 or 0x5C) && !char.IsSurrogate((char)code)
                    ? ((char)code).ToString()
                    : match.Value;
            });
    }

    private static JsonNode? Canonicalize(JsonNode? node)
    {
        if (node is JsonObject value)
        {
            var result = new JsonObject();
            foreach (var item in value.OrderBy(item => item.Key, StringComparer.Ordinal))
            {
                result[item.Key] = Canonicalize(item.Value);
            }

            return result;
        }

        if (node is JsonArray array)
        {
            return new JsonArray(array.Select(Canonicalize).ToArray());
        }

        return node is null ? null : JsonNode.Parse(node.ToJsonString());
    }

    private static void WriteJson(string path, JsonObject value) =>
        File.WriteAllText(path, value.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

    private void RunGit(params string[] arguments)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "git",
                WorkingDirectory = StationRoot,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };
        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        if (!process.Start())
        {
            throw new InvalidOperationException("Self-test git process did not start.");
        }

        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Self-test git failed: {process.StandardError.ReadToEnd()}");
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                File.SetAttributes(path, FileAttributes.Normal);
            }

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

    public Func<string>? SemanticResponseFactory { get; set; }

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
        var isError = (toolName == "shutdown_codesys" && ShutdownFails) ||
            (toolName == "get_ctrlx_semantic_snapshot" && SemanticResponseFactory is null);
        var text = toolName switch
        {
            "get_codesys_status" when statuses.Count > 0 => statuses.Dequeue(),
            "get_codesys_status" => throw new InvalidOperationException("No fake status response remains."),
            "open_project" => OpenProject(arguments),
            "compile_project" => CompileResponseFactory?.Invoke()
                ?? throw new InvalidOperationException("No fake compile response configured."),
            "get_ctrlx_semantic_snapshot" => SemanticResponseFactory?.Invoke()
                ?? JsonSerializer.Serialize(new
                {
                    contractVersion = 1,
                    contractId = "ctrlx-semantic-snapshot-v1",
                    producer = "codesys-persistent.get_ctrlx_semantic_snapshot",
                    adapterPatchId = "ctrlx-semantic-snapshot-v1",
                    capturedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
                    projectFilePath = projectPath,
                    recordsComplete = false,
                    stableAcrossRead = false,
                    reasonCode = "SEMANTIC_SNAPSHOT_FAILED",
                    reason = "fake capability missing"
                }),
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
