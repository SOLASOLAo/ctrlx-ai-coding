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

    private const string CompileSummaryStart = "### COMPILE_SUMMARY_START ###";
    private const string CompileSummaryEnd = "### COMPILE_SUMMARY_END ###";
    private const string FreshCompileProducer = "codesys-persistent.compile_project";
    private const string FreshCompilePatchId = "ctrlx-fresh-compile-v2";
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
            "compile_project",
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
            return new BrokerEngineeringOutcome(
                "BLOCKED",
                "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
                BrokerObservationBuilder.BlockedAfterEngineering(
                    action,
                    "fresh-build",
                    "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
                    ["get_codesys_status", "compile_project"],
                    completedAt,
                    [
                        "Action reused the Broker pre-established persistent session; it did not launch PLE or open a project.",
                        $"Fresh compile evidence contract unavailable: {freshCapabilityFailure ?? "BUILD_FRESH_SUMMARY_UNAVAILABLE"}."
                    ]));
        }

        if (compile.IsError != (freshBuild.Errors > 0))
        {
            throw new BrokerEngineeringUncertainException(
                "BUILD_TOOL_STATUS_MISMATCH",
                "compile_project isError does not match its same-call fresh summary.");
        }

        if (freshBuild.Errors > 0)
        {
            return new BrokerEngineeringOutcome(
                "FAILED",
                "BUILD_ERRORS_PRESENT",
                BrokerObservationBuilder.Failed(
                    action,
                    "fresh-build",
                    "BUILD_ERRORS_PRESENT",
                    ["get_codesys_status", "compile_project"],
                    completedAt,
                    freshBuild.Records
                        .Where(record => record.Severity == "error")
                        .Select(record => record.Text)
                        .ToArray()));
        }

        // A clean Build is necessary but not sufficient for either allowlisted
        // action. Ownership, mapping, readback, recoverable-baseline and Symbol
        // post-processing all need independent auditable producers. Until those
        // producers exist, the Broker must not synthesize a successful result.
        return new BrokerEngineeringOutcome(
            "BLOCKED",
            "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
            BrokerObservationBuilder.BlockedAfterEngineering(
                action,
                "semantic-acceptance",
                "BLOCKED_CAPABILITY_NOT_IMPLEMENTED",
                ["get_codesys_status", "compile_project"],
                completedAt,
                [
                    "Action reused the Broker pre-established persistent session; it did not launch PLE or open a project.",
                    "Semantic acceptance producers for ownership, mapping, readback and recoverable baseline are not implemented.",
                    action.ActionKind == "verify_after_export_2"
                        ? "Symbol Configuration post-processing was not independently verified."
                        : "Second-export requirement was not inferred from action name alone."
                ]));
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
                "compile_project did not return exactly one same-call structured summary.");
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
                "compile_project returned malformed structured summary JSON.",
                exception);
        }

        if (RequiredJson<int>(summary, "contractVersion") != 1 ||
            RequiredJson<string>(summary, "producer") != FreshCompileProducer ||
            RequiredJson<string>(summary, "adapterPatchId") != FreshCompilePatchId ||
            RequiredJson<string>(summary, "buildInvocation") != "application.build" ||
            !RequiredJson<bool>(summary, "fresh") ||
            !RequiredJson<bool>(summary, "verified") ||
            !RequiredJson<bool>(summary, "dirtyPreflightVerified") ||
            !RequiredJson<bool>(summary, "expectedCategoryCoverageVerified") ||
            !RequiredJson<bool>(summary, "allExpectedCategoriesCleared") ||
            !RequiredJson<bool>(summary, "allExpectedCategoriesRead") ||
            !RequiredJson<bool>(summary, "explicitBuildSummaryVerified") ||
            !RequiredJson<bool>(summary, "patchPreflightVerified") ||
            !RequiredJson<bool>(summary, "recordsComplete"))
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_CAPABILITY_UNVERIFIED",
                "compile_project fresh-build contract or preflight proof is unavailable.");
        }

        var project = RequiredJson<string>(summary, "projectFilePath");
        var token = RequiredJson<string>(summary, "buildToken");
        var errors = RequiredJson<int>(summary, "errorCount");
        var warnings = RequiredJson<int>(summary, "warningCount");
        var messageCount = RequiredJson<int>(summary, "messageCount");
        if (!SamePath(project, expectedProject) || !IsSafeIdentifier(token) || token.Length < 16 ||
            errors < 0 || warnings < 0 || messageCount < 0 ||
            errors > 1_000_000 || warnings > 1_000_000)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_INVALID",
                "compile_project fresh-build identity or counts are invalid.");
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
                "compile_project summary timestamps do not correlate with this tool call.");
        }

        var recordNodes = summary["records"] as JsonArray
            ?? throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "compile_project summary records are missing.");
        var records = new List<CompileRecord>(recordNodes.Count);
        foreach (var node in recordNodes)
        {
            if (node is not JsonObject record)
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_RECORDS_INVALID",
                    "compile_project summary contains a non-object record.");
            }

            var severity = RequiredJson<string>(record, "severity").ToLowerInvariant();
            var recordText = RequiredJson<string>(record, "text").Trim();
            if (severity is not ("error" or "warning") || string.IsNullOrWhiteSpace(recordText))
            {
                throw new BrokerEngineeringException(
                    "BUILD_FRESH_RECORDS_INVALID",
                    "compile_project summary contains an invalid severity or empty record.");
            }

            records.Add(new CompileRecord(severity, recordText));
        }

        if (records.Count != messageCount ||
            records.Count(record => record.Severity == "error") != errors ||
            records.Count(record => record.Severity == "warning") != warnings)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_RECORDS_INVALID",
                "compile_project summary counts do not match its same-call records.");
        }

        return new FreshCompileSummary(
            token,
            producerStarted,
            producerCompleted,
            errors,
            warnings,
            records);
    }

    private static T RequiredJson<T>(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<T>(out var result) || result is null)
        {
            throw new BrokerEngineeringException(
                "BUILD_FRESH_SUMMARY_INVALID",
                $"compile_project structured summary is missing '{name}'.");
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

    private static string ProjectStructureUri(string projectPath)
    {
        var normalized = Path.GetFullPath(projectPath).Replace('\\', '/');
        var encoded = string.Join('/', normalized.Split('/').Select(Uri.EscapeDataString));
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
        IReadOnlyList<CompileRecord> Records);
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
