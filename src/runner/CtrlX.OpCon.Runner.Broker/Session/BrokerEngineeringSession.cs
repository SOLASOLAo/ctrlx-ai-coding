using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Broker.Mcp;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.Session;

public sealed record BrokerSessionRuntime(
    int McpPid,
    int PlePid,
    string PersistentSessionId,
    string Profile,
    string ActiveProjectPath,
    bool PleOwnedByBroker);

public sealed record BrokerEngineeringOutcome(
    string TerminalState,
    string ReasonCode,
    JsonObject Observation);

public interface IBrokerEngineeringSession : IAsyncDisposable
{
    Task<BrokerSessionRuntime> StartAsync(CancellationToken cancellationToken);

    Task<BrokerSessionRuntime> VerifyReadyAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken);

    Task<BrokerEngineeringOutcome> ExecuteAsync(
        ValidatedRunnerAction action,
        BrokerSessionRuntime expectedSession,
        CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Owns exactly one stdio MCP child. It may either adopt an already-running
/// persistent PLE or start one itself; only the latter may be shut down here.
/// Action handlers reuse the session established by StartAsync and never
/// launch PLE or open a project themselves.
/// </summary>
public sealed class BrokerEngineeringSession : IBrokerEngineeringSession
{
    private static readonly Regex StatusLine = new(
        "^(?<name>State|Mode|PID|Session|PLE Ownership|PLE Ownership Contract):\\s*(?<value>.+)$",
        RegexOptions.Multiline | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex ProjectLine = new(
        "^\\s*-\\s*(?<name>Project Open|Project Path):\\s*(?<value>.+)$",
        RegexOptions.Multiline | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private const string CompileSummaryStart = "### CLEAN_COMPILE_SUMMARY_START ###";
    private const string CompileSummaryEnd = "### CLEAN_COMPILE_SUMMARY_END ###";
    private const string FreshCompileContractId = "ctrlx-clean-compile-v1";
    private const string FreshCompileProducer = "codesys-persistent.clean_compile_project";
    private const string PleOwnershipContract = "ctrlx-ple-ownership-v1";

    private readonly IMcpRpcClient mcp;
    private readonly BrokerHostOptions options;
    private BrokerSessionRuntime? runtime;
    private bool ownsPle;
    private bool stopped;
    private bool disposed;

    public BrokerEngineeringSession(IMcpRpcClient mcp, BrokerHostOptions options)
    {
        this.mcp = mcp ?? throw new ArgumentNullException(nameof(mcp));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<BrokerSessionRuntime> StartAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (stopped)
        {
            throw new BrokerEngineeringException(
                "BROKER_SESSION_STOPPED",
                "A stopped Broker engineering session cannot be restarted.");
        }

        if (runtime is not null)
        {
            return runtime;
        }

        await mcp.StartAsync(cancellationToken).ConfigureAwait(false);
        var deadline = DateTimeOffset.UtcNow + options.SessionStartupTimeout;
        var status = await ReadStatusAsync(cancellationToken).ConfigureAwait(false);
        var launchedByThisStart = false;
        if (status.State == "stopped")
        {
            if (status.Ownership != PleOwnership.None)
            {
                throw new BrokerEngineeringException(
                    "BROKER_PLE_OWNERSHIP_INCONSISTENT",
                    "Stopped PLE status must report ownership=none.");
            }

            var launch = await mcp.CallToolAsync(
                "launch_codesys",
                arguments: null,
                options.SessionStartupTimeout,
                cancellationToken).ConfigureAwait(false);
            RequireToolSuccess(launch, "BROKER_PLE_LAUNCH_FAILED");
            launchedByThisStart = true;
        }
        else if (status.State == "ready")
        {
            if (status.Ownership != PleOwnership.External)
            {
                throw new BrokerEngineeringException(
                    "BROKER_EXISTING_PLE_OWNERSHIP_REJECTED",
                    "An already-ready PLE is reusable only when explicitly reported as external.");
            }
        }
        else
        {
            throw new BrokerEngineeringException(
                "BROKER_SESSION_STATE_REJECTED",
                $"Persistent PLE is in unsupported state '{status.State}'.");
        }

        while (true)
        {
            status = await ReadStatusAsync(cancellationToken).ConfigureAwait(false);
            if (status.State == "ready")
            {
                break;
            }

            if (DateTimeOffset.UtcNow >= deadline)
            {
                throw new BrokerEngineeringException(
                    "BROKER_SESSION_START_TIMEOUT",
                    $"Persistent PLE did not become ready; last state was '{status.State}'.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken).ConfigureAwait(false);
        }

        RequirePersistent(status);
        ownsPle = (launchedByThisStart, status.Ownership) switch
        {
            (true, PleOwnership.Broker) => true,
            (true, PleOwnership.External) => false,
            (false, PleOwnership.External) => false,
            _ => throw new BrokerEngineeringException(
                "BROKER_PLE_OWNERSHIP_UNVERIFIED",
                "Ready PLE ownership does not correlate with this Broker startup.")
        };

        var project = await ReadProjectAsync(cancellationToken).ConfigureAwait(false);
        if (!project.IsOpen)
        {
            if (!ownsPle)
            {
                throw new BrokerEngineeringException(
                    "BROKER_EXTERNAL_PROJECT_NOT_OPEN",
                    "An adopted external PLE has no project open; Broker will not alter it.");
            }

            var opened = await mcp.CallToolAsync(
                "open_project",
                new JsonObject { ["filePath"] = options.PlcProject },
                options.SessionStartupTimeout,
                cancellationToken).ConfigureAwait(false);
            RequireToolSuccess(opened, "BROKER_PROJECT_OPEN_FAILED");
            project = await ReadProjectAsync(cancellationToken).ConfigureAwait(false);
        }

        RequireExactProject(project, options.PlcProject);
        runtime = new BrokerSessionRuntime(
            McpPid: mcp.ProcessId ?? throw new BrokerEngineeringException("BROKER_MCP_PID_UNAVAILABLE", "MCP child PID is unavailable."),
            PlePid: status.PlePid,
            PersistentSessionId: status.SessionId,
            Profile: options.Profile,
            ActiveProjectPath: Path.GetFullPath(project.Path),
            PleOwnedByBroker: ownsPle);
        return runtime;
    }

    public async Task<BrokerSessionRuntime> VerifyReadyAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        var expected = runtime ?? throw new BrokerEngineeringException("BROKER_SESSION_NOT_STARTED", "Broker session has not started.");
        var status = await ReadStatusAsync(cancellationToken).ConfigureAwait(false);
        RequirePersistent(status);
        var project = await ReadProjectAsync(cancellationToken).ConfigureAwait(false);
        RequireExactProject(project, action.PlcProject);
        if (status.PlePid != expected.PlePid ||
            status.SessionId != expected.PersistentSessionId ||
            (status.Ownership == PleOwnership.Broker) != expected.PleOwnedByBroker ||
            action.Profile != expected.Profile ||
            !SamePath(action.PlcProject, expected.ActiveProjectPath))
        {
            throw new BrokerEngineeringException("BROKER_SESSION_IDENTITY_CHANGED", "Persistent PLE session identity changed.");
        }

        return expected;
    }

    public async Task<BrokerEngineeringOutcome> ExecuteAsync(
        ValidatedRunnerAction action,
        BrokerSessionRuntime expectedSession,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        ArgumentNullException.ThrowIfNull(expectedSession);
        var before = await CaptureProjectSnapshotAsync(action.PlcProject, cancellationToken).ConfigureAwait(false);
        var compileRequestedAtUtc = DateTimeOffset.UtcNow;
        var compile = await mcp.CallToolAsync(
            "clean_compile_project",
            new JsonObject { ["projectFilePath"] = action.PlcProject },
            options.BuildTimeout,
            cancellationToken).ConfigureAwait(false);
        var compileText = JoinText(compile.TextContent);
        FreshCompileSummary? freshBuild = null;
        string? freshCapabilityFailure = null;
        try
        {
            freshBuild = ParseFreshCompileSummary(
                compileText,
                action.PlcProject,
                compileRequestedAtUtc,
                DateTimeOffset.UtcNow);
        }
        catch (BrokerEngineeringException exception) when (
            exception.ReasonCode.StartsWith("BUILD_FRESH_", StringComparison.Ordinal))
        {
            freshCapabilityFailure = exception.ReasonCode;
        }

        BrokerSemanticSnapshotPlan? semanticPlan = null;
        McpToolCallResult? semanticSnapshot = null;
        var capabilities = new List<string> { "get_codesys_status", "clean_compile_project" };
        if (freshBuild is not null)
        {
            if (compile.IsError != (freshBuild.Errors > 0))
            {
                throw new BrokerEngineeringUncertainException(
                    "BUILD_TOOL_STATUS_MISMATCH",
                    "clean_compile_project isError does not match its same-call clean summary.");
            }

            if (freshBuild.Errors == 0)
            {
                semanticPlan = BrokerSemanticAcceptance.PrepareSnapshotPlan(action);
                if (semanticPlan.CanInvoke)
                {
                    semanticSnapshot = await mcp.CallToolAsync(
                        "get_ctrlx_semantic_snapshot",
                        semanticPlan.Arguments,
                        options.StatusTimeout + TimeSpan.FromMinutes(2),
                        cancellationToken).ConfigureAwait(false);
                    capabilities.Add("get_ctrlx_semantic_snapshot");
                }
            }
        }

        var afterSession = await VerifyReadyAsync(action, cancellationToken).ConfigureAwait(false);
        if (afterSession != expectedSession)
        {
            throw new BrokerEngineeringUncertainException(
                "BROKER_SESSION_CHANGED_DURING_BUILD",
                "Persistent session changed while Build was running.");
        }

        var after = await CaptureProjectSnapshotAsync(action.PlcProject, cancellationToken).ConfigureAwait(false);
        var completedAt = DateTimeOffset.UtcNow;
        var stable = before.ProjectSha256.Equals(after.ProjectSha256, StringComparison.OrdinalIgnoreCase) &&
            before.Length == after.Length &&
            before.StructureSha256.Equals(after.StructureSha256, StringComparison.OrdinalIgnoreCase);
        if (!stable)
        {
            throw new BrokerEngineeringUncertainException(
                "PROJECT_CHANGED_DURING_BUILD",
                "PLC project or project structure changed while Build was running.");
        }

        if (freshBuild is null)
        {
            var observation = BrokerObservationBuilder.BlockedAfterEngineering(
                action,
                "fresh-build",
                "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
                capabilities,
                completedAt,
                [
                    "Action reused the Broker pre-established persistent session; it did not launch PLE or open a project.",
                    $"Fresh compile evidence contract unavailable: {freshCapabilityFailure ?? "BUILD_FRESH_SUMMARY_UNAVAILABLE"}."
                ]);
            return BoundedOutcome(
                action,
                "BLOCKED",
                "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
                observation,
                capabilities,
                completedAt);
        }

        if (freshBuild.Errors > 0)
        {
            var diagnosticRows = BrokerSemanticAcceptance.ObservationDiagnosticRows(freshBuild.DiagnosticRows);
            var observation = BrokerObservationBuilder.Failed(
                action,
                "fresh-build",
                "BUILD_ERRORS_PRESENT",
                capabilities,
                completedAt,
                diagnosticRows.Select(row => row?.GetValue<string>() ?? string.Empty).ToArray());
            return BoundedOutcome(
                action,
                "FAILED",
                "BUILD_ERRORS_PRESENT",
                observation,
                capabilities,
                completedAt);
        }

        semanticPlan ??= BrokerSemanticAcceptance.PrepareSnapshotPlan(action);
        var buildProof = new BrokerCompileProofState(
            freshBuild.BuildToken,
            freshBuild.StartedAtUtc,
            freshBuild.CompletedAtUtc,
            freshBuild.Errors,
            freshBuild.Warnings,
            freshBuild.MessageCount,
            freshBuild.TypedRecordsVerified,
            freshBuild.DiagnosticRowsComplete,
            freshBuild.Records
                .Select(record => new BrokerCompileProofRecord(record.Severity, record.Text))
                .ToArray(),
            freshBuild.DiagnosticRows);
        var semantic = await BrokerSemanticAcceptance.ProduceAsync(
            action,
            new BrokerProjectProofState(
                before.ProjectSha256,
                before.Length,
                before.LastWriteTimeUtc,
                before.StructureSha256),
            new BrokerProjectProofState(
                after.ProjectSha256,
                after.Length,
                after.LastWriteTimeUtc,
                after.StructureSha256),
            buildProof,
            semanticPlan,
            semanticSnapshot is null ? null : JoinText(semanticSnapshot.TextContent),
            semanticSnapshot?.IsError ?? false,
            completedAt,
            cancellationToken).ConfigureAwait(false);
        if (!semantic.Verified)
        {
            var observation = BrokerObservationBuilder.BlockedAfterEngineering(
                action,
                "semantic-acceptance",
                semantic.ReasonCode,
                capabilities,
                completedAt,
                new[]
                {
                    "Action reused the Broker pre-established persistent session; it did not launch PLE or open a project."
                }.Concat(semantic.Diagnostics).ToArray(),
                semantic.Proofs,
                semantic.NextRoute,
                buildProof,
                new BrokerProjectProofState(
                    after.ProjectSha256,
                    after.Length,
                    after.LastWriteTimeUtc,
                    after.StructureSha256),
                semantic.WarningRecords,
                semantic.DiagnosticRows,
                semantic.WarningRecordsSafeForReview);
            return BoundedOutcome(
                action,
                "BLOCKED",
                semantic.ReasonCode,
                observation,
                capabilities,
                completedAt);
        }

        var succeeded = BrokerObservationBuilder.Succeeded(
            action,
            expectedSession,
            buildProof,
            new BrokerProjectProofState(
                after.ProjectSha256,
                after.Length,
                after.LastWriteTimeUtc,
                after.StructureSha256),
            semantic,
            capabilities,
            completedAt);
        return BoundedOutcome(
            action,
            "SUCCEEDED",
            "BUILD_AND_SEMANTICS_VERIFIED",
            succeeded,
            capabilities,
            completedAt);
    }

    private static BrokerEngineeringOutcome BoundedOutcome(
        ValidatedRunnerAction action,
        string terminalState,
        string reasonCode,
        JsonObject observation,
        IReadOnlyList<string> capabilities,
        DateTimeOffset completedAtUtc)
    {
        var bounded = BrokerObservationBuilder.EnforceTerminalObservationBudget(
            action,
            observation,
            capabilities,
            completedAtUtc,
            out var replaced);
        return replaced
            ? new BrokerEngineeringOutcome("BLOCKED", "TERMINAL_OBSERVATION_TOO_LARGE", bounded)
            : new BrokerEngineeringOutcome(terminalState, reasonCode, bounded);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (disposed || stopped)
        {
            return;
        }

        Exception? shutdownFailure = null;
        if (ownsPle && mcp.Handshake is not null)
        {
            try
            {
                var shutdown = await mcp.CallToolAsync(
                    "shutdown_codesys",
                    arguments: null,
                    options.SessionStartupTimeout,
                    cancellationToken).ConfigureAwait(false);
                RequireToolSuccess(shutdown, "BROKER_OWNED_PLE_SHUTDOWN_FAILED");
            }
            catch (Exception exception)
            {
                shutdownFailure = exception;
            }
        }

        Exception? mcpStopFailure = null;
        try
        {
            await mcp.StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            mcpStopFailure = exception;
        }
        finally
        {
            runtime = null;
            ownsPle = false;
            stopped = true;
        }

        if (shutdownFailure is not null)
        {
            throw new BrokerEngineeringException(
                "BROKER_OWNED_PLE_SHUTDOWN_FAILED",
                "Broker-owned PLE shutdown failed; stdio MCP cleanup was still attempted.",
                mcpStopFailure is null
                    ? shutdownFailure
                    : new AggregateException(shutdownFailure, mcpStopFailure));
        }

        if (mcpStopFailure is not null)
        {
            throw new BrokerEngineeringException(
                "BROKER_MCP_STOP_FAILED",
                "Broker-owned stdio MCP child did not stop cleanly.",
                mcpStopFailure);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        Exception? stopFailure = null;
        try
        {
            await StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            stopFailure = exception;
        }

        Exception? disposeFailure = null;
        try
        {
            await mcp.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            disposeFailure = exception;
        }
        finally
        {
            disposed = true;
        }

        if (stopFailure is not null)
        {
            if (disposeFailure is not null)
            {
                throw new BrokerEngineeringException(
                    "BROKER_SESSION_DISPOSE_FAILED",
                    "Engineering session stop failed and MCP disposal also failed.",
                    new AggregateException(stopFailure, disposeFailure));
            }

            throw stopFailure;
        }

        if (disposeFailure is not null)
        {
            throw disposeFailure;
        }
    }

    private async Task<StatusSnapshot> ReadStatusAsync(CancellationToken cancellationToken)
    {
        var result = await mcp.CallToolAsync(
            "get_codesys_status",
            arguments: null,
            options.StatusTimeout,
            cancellationToken).ConfigureAwait(false);
        RequireToolSuccess(result, "BROKER_STATUS_FAILED");
        var values = ParseLines(StatusLine, JoinText(result.TextContent));
        var state = Required(values, "State").ToLowerInvariant();
        var mode = Required(values, "Mode").ToLowerInvariant();
        var pidText = Required(values, "PID");
        var session = Required(values, "Session");
        var ownership = ParseOwnership(values);
        if (state != "ready")
        {
            if (!pidText.Equals("N/A", StringComparison.OrdinalIgnoreCase) &&
                (!int.TryParse(pidText, NumberStyles.None, CultureInfo.InvariantCulture, out var transientPid) || transientPid <= 0))
            {
                throw new BrokerEngineeringException("BROKER_STATUS_INVALID", "Non-ready PLE status contains an invalid PID.");
            }

            if (!session.Equals("N/A", StringComparison.OrdinalIgnoreCase) && !IsSafeIdentifier(session))
            {
                throw new BrokerEngineeringException("BROKER_STATUS_INVALID", "Non-ready PLE status contains an invalid Session ID.");
            }

            return new StatusSnapshot(state, mode, 0, string.Empty, ownership);
        }

        if (!int.TryParse(pidText, NumberStyles.None, CultureInfo.InvariantCulture, out var pid) || pid <= 0)
        {
            throw new BrokerEngineeringException("BROKER_STATUS_INVALID", "Ready PLE status did not contain a valid PID.");
        }

        if (!IsSafeIdentifier(session))
        {
            throw new BrokerEngineeringException("BROKER_STATUS_INVALID", "PLE status did not contain a safe persistent Session ID.");
        }

        return new StatusSnapshot(state, mode, pid, session, ownership);
    }

    private static PleOwnership ParseOwnership(IReadOnlyDictionary<string, string> values)
    {
        if (!values.TryGetValue("PLE Ownership Contract", out var contract) ||
            contract != PleOwnershipContract ||
            !values.TryGetValue("PLE Ownership", out var raw))
        {
            throw new BrokerEngineeringException(
                "BROKER_PLE_OWNERSHIP_CAPABILITY_MISSING",
                "PLE ownership contract is unavailable; refusing launch or adoption.");
        }

        return raw.ToLowerInvariant() switch
        {
            "broker" => PleOwnership.Broker,
            "external" => PleOwnership.External,
            "none" => PleOwnership.None,
            _ => throw new BrokerEngineeringException(
                "BROKER_PLE_OWNERSHIP_UNVERIFIED",
                $"PLE status reported unsupported ownership '{raw}'.")
        };
    }

    private async Task<ProjectSnapshot> ReadProjectAsync(CancellationToken cancellationToken)
    {
        var result = await mcp.ReadResourceAsync(
            "codesys://project/status",
            options.StatusTimeout,
            cancellationToken).ConfigureAwait(false);
        if (result.IsError)
        {
            throw new BrokerEngineeringException("BROKER_PROJECT_STATUS_FAILED", JoinText(result.TextContent));
        }

        var values = ParseLines(ProjectLine, JoinText(result.TextContent));
        var openText = Required(values, "Project Open");
        if (!bool.TryParse(openText, out var isOpen))
        {
            throw new BrokerEngineeringException("BROKER_PROJECT_STATUS_INVALID", "Project Open status is not Boolean.");
        }

        var path = Required(values, "Project Path");
        return new ProjectSnapshot(isOpen, path);
    }

    private async Task<FileProjectSnapshot> CaptureProjectSnapshotAsync(
        string projectPath,
        CancellationToken cancellationToken)
    {
        var file = new FileInfo(projectPath);
        if (!file.Exists)
        {
            throw new BrokerEngineeringException("PLC_PROJECT_NOT_FOUND", $"PLC project disappeared: {projectPath}");
        }

        var structure = await mcp.ReadResourceAsync(
            ProjectStructureUri(projectPath),
            options.StatusTimeout + TimeSpan.FromMinutes(1),
            cancellationToken).ConfigureAwait(false);
        if (structure.IsError || structure.TextContent.Count == 0)
        {
            throw new BrokerEngineeringException("PROJECT_STRUCTURE_READ_FAILED", JoinText(structure.TextContent));
        }

        return new FileProjectSnapshot(
            RunnerHash.Sha256File(projectPath),
            file.Length,
            file.LastWriteTimeUtc,
            RunnerHash.Sha256Text(JoinText(structure.TextContent)));
    }

    private static FreshCompileSummary ParseFreshCompileSummary(
        string text,
        string expectedProject,
        DateTimeOffset requestedAtUtc,
        DateTimeOffset receivedAtUtc)
    {
        var start = text.IndexOf(CompileSummaryStart, StringComparison.Ordinal);
        var end = start < 0
            ? -1
            : text.IndexOf(CompileSummaryEnd, start + CompileSummaryStart.Length, StringComparison.Ordinal);
        if (start < 0 || end < 0 ||
            text.IndexOf(CompileSummaryStart, start + CompileSummaryStart.Length, StringComparison.Ordinal) >= 0 ||
            text.IndexOf(CompileSummaryEnd, end + CompileSummaryEnd.Length, StringComparison.Ordinal) >= 0)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_UNAVAILABLE",
                "clean_compile_project did not return exactly one same-call structured summary.");
        }

        JsonObject summary;
        try
        {
            var json = text[(start + CompileSummaryStart.Length)..end].Trim();
            summary = JsonNode.Parse(json) as JsonObject
                ?? throw new JsonException("Fresh compile summary is not an object.");
        }
        catch (JsonException exception)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_INVALID",
                "clean_compile_project returned malformed structured summary JSON.",
                exception);
        }

        if (RequiredJson<int>(summary, "contractVersion") != 1 ||
            RequiredJson<string>(summary, "contractId") != FreshCompileContractId ||
            RequiredJson<string>(summary, "producer") != FreshCompileProducer ||
            RequiredJson<string>(summary, "adapterPatchId") != FreshCompileContractId ||
            RequiredJson<string>(summary, "cleanInvocation") != "application.clean" ||
            RequiredJson<string>(summary, "buildInvocation") != "application.build" ||
            RequiredJson<int>(summary, "cleanInvocationCount") != 1 ||
            RequiredJson<int>(summary, "buildInvocationCount") != 1 ||
            !RequiredJson<bool>(summary, "cleanSucceeded") ||
            !RequiredJson<bool>(summary, "buildSucceeded") ||
            !RequiredJson<bool>(summary, "semanticRebuildVerified") ||
            !RequiredJson<bool>(summary, "messageEvidenceComplete") ||
            !RequiredJson<bool>(summary, "fresh") ||
            !RequiredJson<bool>(summary, "verified") ||
            !RequiredJson<bool>(summary, "dirtyPreflightVerified") ||
            !RequiredJson<bool>(summary, "dirtyPostflightVerified") ||
            !RequiredJson<bool>(summary, "identityPreflightVerified") ||
            !RequiredJson<bool>(summary, "identityPostflightVerified") ||
            !RequiredJson<bool>(summary, "expectedCategoryCoverageVerified") ||
            !RequiredJson<bool>(summary, "allExpectedCategoriesCleared") ||
            !RequiredJson<bool>(summary, "allExpectedCategoriesRead") ||
            !RequiredJson<bool>(summary, "explicitBuildSummaryVerified") ||
            !RequiredJson<bool>(summary, "patchPreflightVerified") ||
            !RequiredJson<bool>(summary, "recordsComplete"))
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                "clean_compile_project semantic-rebuild contract or preflight proof is unavailable.");
        }

        ValidateCleanCategoryResults(summary);

        var project = RequiredJson<string>(summary, "projectFilePath");
        var token = RequiredJson<string>(summary, "buildToken");
        var errors = RequiredJson<int>(summary, "errorCount");
        var warnings = RequiredJson<int>(summary, "warningCount");
        var messageCount = RequiredJson<int>(summary, "messageCount");
        var typedRecordsVerified = RequiredJson<bool>(summary, "typedRecordsVerified");
        var warningDetailsComplete = RequiredJson<bool>(summary, "warningDetailsComplete");
        var diagnosticRowsComplete = RequiredJson<bool>(summary, "diagnosticRowsComplete");
        if (!SamePath(project, expectedProject) || !IsSafeIdentifier(token) || token.Length < 16 ||
            errors < 0 || warnings < 0 || messageCount < 0 ||
            errors > 1_000_000 || warnings > 1_000_000 || messageCount > 2048)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_INVALID",
                "clean_compile_project semantic-rebuild identity or counts are invalid.");
        }

        if (!DateTimeOffset.TryParse(
                RequiredJson<string>(summary, "startedAtUtc"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var producerStarted) ||
            !DateTimeOffset.TryParse(
                RequiredJson<string>(summary, "completedAtUtc"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var producerCompleted) ||
            producerStarted < requestedAtUtc - TimeSpan.FromSeconds(2) ||
            producerCompleted < producerStarted ||
            producerCompleted > receivedAtUtc + TimeSpan.FromSeconds(2))
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_CORRELATION_INVALID",
                "clean_compile_project summary timestamps do not correlate with this tool call.");
        }

        var recordNodes = summary["records"] as JsonArray
            ?? throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "clean_compile_project summary records are missing.");
        var records = new List<CompileRecord>(recordNodes.Count);
        foreach (var node in recordNodes)
        {
            if (node is not JsonObject record)
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_RECORDS_INVALID",
                    "clean_compile_project summary contains a non-object record.");
            }

            var severity = RequiredJson<string>(record, "severity").ToLowerInvariant();
            var recordText = RequiredJson<string>(record, "text").Trim();
            if (severity != "warning" || string.IsNullOrWhiteSpace(recordText))
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_RECORDS_INVALID",
                    "clean_compile_project summary contains a non-warning or empty record.");
            }

            records.Add(new CompileRecord(severity, recordText));
        }

        var successfulEvidenceComplete = errors == 0 &&
            typedRecordsVerified &&
            warningDetailsComplete &&
            records.Count == warnings &&
            messageCount == warnings;
        var failedBuildEvidenceValid = errors > 0 &&
            !typedRecordsVerified &&
            !warningDetailsComplete &&
            records.Count == 0 &&
            messageCount == errors + warnings;
        if (!successfulEvidenceComplete && !failedBuildEvidenceValid)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "clean_compile_project summary counts do not match its complete same-call warning records.");
        }

        var diagnosticNodes = summary["diagnosticRows"] as JsonArray
            ?? throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "clean_compile_project summary diagnostic rows are missing.");
        if (diagnosticNodes.Count > messageCount ||
            (diagnosticRowsComplete &&
             diagnosticNodes.Count != messageCount &&
             !(successfulEvidenceComplete && diagnosticNodes.Count == 0)))
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "clean_compile_project diagnostic row completeness does not match its same-call message count.");
        }

        var diagnosticRows = new List<string>(diagnosticNodes.Count);
        foreach (var node in diagnosticNodes)
        {
            if (node is not JsonValue value ||
                !value.TryGetValue<string>(out var row) ||
                string.IsNullOrWhiteSpace(row))
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_RECORDS_INVALID",
                    "clean_compile_project summary contains an invalid diagnostic row.");
            }

            diagnosticRows.Add(row.Trim());
        }

        if (successfulEvidenceComplete && diagnosticRowsComplete && diagnosticRows.Count == 0)
        {
            diagnosticRows.AddRange(records.Select(record => record.Text));
        }

        return new FreshCompileSummary(
            token,
            producerStarted,
            producerCompleted,
            errors,
            warnings,
            messageCount,
            typedRecordsVerified,
            diagnosticRowsComplete,
            records,
            diagnosticRows);
    }

    private static void ValidateCleanCategoryResults(JsonObject summary)
    {
        var categoryNodes = summary["categoryClearResults"] as JsonArray
            ?? throw new BrokerEngineeringException(
                "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                "clean_compile_project category-clear proof is missing.");
        if (categoryNodes.Count != 2)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                "clean_compile_project must prove exactly two cleared compiler categories.");
        }

        var expected = new HashSet<string>(["Build", "Additional code checks"], StringComparer.Ordinal);
        foreach (var node in categoryNodes)
        {
            if (node is not JsonObject category ||
                !expected.Remove(RequiredJson<string>(category, "category")) ||
                !RequiredJson<bool>(category, "clearedAndVerified"))
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                    "clean_compile_project category-clear proof is invalid or duplicated.");
            }
        }

        if (expected.Count != 0)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                "clean_compile_project category-clear proof is incomplete.");
        }
    }

    private static T RequiredJson<T>(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<T>(out var result) || result is null)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_INVALID",
                $"clean_compile_project structured summary is missing '{name}'.");
        }

        return result;
    }

    private static Dictionary<string, string> ParseLines(Regex regex, string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (Match match in regex.Matches(text))
        {
            if (!result.TryAdd(match.Groups["name"].Value, match.Groups["value"].Value.Trim()))
            {
                throw new BrokerEngineeringException("BROKER_RESPONSE_INVALID", "MCP response contained a duplicate status field.");
            }
        }

        return result;
    }

    private static string Required(IReadOnlyDictionary<string, string> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
        {
            throw new BrokerEngineeringException("BROKER_RESPONSE_INVALID", $"MCP response is missing '{name}'.");
        }

        return value;
    }

    private static void RequirePersistent(StatusSnapshot status)
    {
        if (status.State != "ready" || status.Mode != "persistent")
        {
            throw new BrokerEngineeringException(
                "BROKER_SESSION_NOT_PERSISTENT",
                $"Expected ready persistent PLE, received state={status.State}, mode={status.Mode}.");
        }
    }

    private static void RequireExactProject(ProjectSnapshot project, string expectedPath)
    {
        if (!project.IsOpen || project.Path.Equals("N/A", StringComparison.OrdinalIgnoreCase) || !SamePath(project.Path, expectedPath))
        {
            throw new BrokerEngineeringException(
                "BROKER_PROJECT_MISMATCH",
                $"Persistent session has a different project open: {project.Path}");
        }
    }

    private static void RequireToolSuccess(McpToolCallResult result, string reasonCode)
    {
        if (result.IsError)
        {
            throw new BrokerEngineeringException(reasonCode, JoinText(result.TextContent));
        }
    }

    private static bool SamePath(string left, string right)
    {
        try
        {
            return Path.GetFullPath(left).Equals(Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    internal static string ProjectStructureUri(string projectPath)
    {
        var normalized = Path.GetFullPath(projectPath).Replace('\\', '/');
        var encoded = string.Join('/', normalized.Split('/').Select((segment, index) =>
            index == 0 && segment.Length == 2 && char.IsAsciiLetter(segment[0]) && segment[1] == ':'
                ? segment
                : Uri.EscapeDataString(segment)));
        return $"codesys://project/{encoded}/structure";
    }

    private static string JoinText(IReadOnlyList<string> content) => string.Join("\n", content);

    private static bool IsSafeIdentifier(string value) =>
        value.Length is > 0 and <= 128 && value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-');

    private enum PleOwnership
    {
        None,
        Broker,
        External
    }

    private sealed record StatusSnapshot(
        string State,
        string Mode,
        int PlePid,
        string SessionId,
        PleOwnership Ownership);

    private sealed record ProjectSnapshot(bool IsOpen, string Path);

    private sealed record FileProjectSnapshot(
        string ProjectSha256,
        long Length,
        DateTime LastWriteTimeUtc,
        string StructureSha256);

    internal sealed record CompileRecord(string Severity, string Text);

    internal sealed record FreshCompileSummary(
        string BuildToken,
        DateTimeOffset StartedAtUtc,
        DateTimeOffset CompletedAtUtc,
        int Errors,
        int Warnings,
        int MessageCount,
        bool TypedRecordsVerified,
        bool DiagnosticRowsComplete,
        IReadOnlyList<CompileRecord> Records,
        IReadOnlyList<string> DiagnosticRows);
}

public class BrokerEngineeringException : Exception
{
    public BrokerEngineeringException(string reasonCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ReasonCode = reasonCode;
    }

    public string ReasonCode { get; }
}

public sealed class BrokerEngineeringUncertainException : BrokerEngineeringException
{
    public BrokerEngineeringUncertainException(string reasonCode, string message, Exception? innerException = null)
        : base(reasonCode, message, innerException)
    {
    }
}
