using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CtrlX.OpCon.Workbench;

public sealed record WorkbenchOptions(string EngineeringRoot, bool SmokeTest)
{
    public static WorkbenchOptions Parse(IReadOnlyList<string> args)
    {
        string? root = null;
        var smokeTest = false;

        for (var index = 0; index < args.Count; index++)
        {
            switch (args[index].ToLowerInvariant())
            {
                case "--engineering-root":
                    if (++index >= args.Count || string.IsNullOrWhiteSpace(args[index]))
                    {
                        throw new ArgumentException("--engineering-root requires a path.");
                    }
                    root = args[index];
                    break;
                case "--smoke-test":
                    smokeTest = true;
                    break;
                default:
                    throw new ArgumentException($"Unknown option: {args[index]}");
            }
        }

        return new WorkbenchOptions(root ?? Environment.CurrentDirectory, smokeTest);
    }
}

public sealed record WorkbenchPaths(
    string EngineeringRoot,
    string ProjectConfiguration,
    string Todo,
    string RunnerScript,
    string HostScript,
    string ProjectPackScript,
    string? CpStudioProject,
    string? PlcProject,
    string? IoProject,
    string RunRoot,
    string OperationRoot)
{
    public string LatestManifest => WorkbenchFiles.FindNewestFile(RunRoot, "run-manifest.json") ?? string.Empty;
}

public static class WorkbenchRoot
{
    public static WorkbenchPaths Validate(string engineeringRoot)
    {
        if (string.IsNullOrWhiteSpace(engineeringRoot))
        {
            throw new ArgumentException("Engineering root is required.", nameof(engineeringRoot));
        }

        var root = Path.GetFullPath(engineeringRoot);
        if (!Directory.Exists(root))
        {
            throw new DirectoryNotFoundException($"Engineering root does not exist: {root}");
        }

        var configuration = RequireFile(root, "config", "project.yaml");
        var todo = RequireFile(root, "TODO.md");
        var runner = RequireFile(root, "scripts", "runner", "Invoke-CtrlXOpconRunner.ps1");
        var host = RequireFile(root, "scripts", "runner", "Invoke-CtrlXOpconRunnerHost.ps1");
        var projectPack = RequireFile(root, "scripts", "project", "Build-CtrlXOpconProjectPack.ps1");
        var yaml = WorkbenchFiles.ReadBoundedText(configuration, 2 * 1024 * 1024);

        return new WorkbenchPaths(
            root,
            configuration,
            todo,
            runner,
            host,
            projectPack,
            ResolveConfiguredPath(root, SimpleYaml.GetScalar(yaml, "paths.cpstudio_project")),
            ResolveConfiguredPath(root, SimpleYaml.GetScalar(yaml, "paths.plc_project")),
            ResolveConfiguredPath(root, SimpleYaml.GetScalar(yaml, "paths.io_project")),
            Path.Combine(root, "data", "runs", "runner"),
            Path.Combine(root, "data", "operations"));
    }

    private static string RequireFile(string root, params string[] segments)
    {
        var path = segments.Aggregate(root, Path.Combine);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Required engineering file is missing: {path}", path);
        }
        return path;
    }

    private static string? ResolveConfiguredPath(string root, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        return Path.GetFullPath(Path.IsPathRooted(value) ? value : Path.Combine(root, value));
    }
}

public sealed record PhaseProgress(string Id, string Title, bool Complete, bool Current, string Summary);

public static partial class WorkbenchProgressParser
{
    [GeneratedRegex(@"^\s*-\s*\[(?<done>[ xX])\]\s*\*\*(?<id>P[0-4])\s*·\s*(?<title>[^*]+)\*\*\s*：?(?<summary>.*)$", RegexOptions.Multiline)]
    private static partial Regex PhasePattern();

    [GeneratedRegex(@"^\s*##\s*(?<id>P[0-4])\s*[：:]\s*(?<title>[^\r\n]+?)\s*$", RegexOptions.Multiline)]
    private static partial Regex HeadingPhasePattern();

    [GeneratedRegex(@"^\s*-\s*\[(?<done>[ xX])\]", RegexOptions.Multiline)]
    private static partial Regex ChecklistPattern();

    public static IReadOnlyList<PhaseProgress> Parse(string todoText)
    {
        ArgumentNullException.ThrowIfNull(todoText);
        var matches = PhasePattern().Matches(todoText);
        var phases = new List<PhaseProgress>(5);
        foreach (Match match in matches)
        {
            var id = match.Groups["id"].Value;
            if (phases.Any(item => item.Id.Equals(id, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            var title = match.Groups["title"].Value.Trim();
            var summary = match.Groups["summary"].Value.Trim();
            phases.Add(new PhaseProgress(
                id,
                title,
                !string.IsNullOrWhiteSpace(match.Groups["done"].Value),
                title.Contains("当前", StringComparison.OrdinalIgnoreCase) || summary.Contains("当前", StringComparison.OrdinalIgnoreCase),
                summary));
        }

        if (phases.Count == 0)
        {
            var headings = HeadingPhasePattern().Matches(todoText);
            for (var index = 0; index < headings.Count; index++)
            {
                var heading = headings[index];
                var bodyStart = heading.Index + heading.Length;
                var bodyEnd = index + 1 < headings.Count ? headings[index + 1].Index : todoText.Length;
                var body = todoText[bodyStart..bodyEnd];
                var checklist = ChecklistPattern().Matches(body);
                var complete = checklist.Count > 0 && checklist.All(item =>
                    !string.IsNullOrWhiteSpace(item.Groups["done"].Value));
                var title = heading.Groups["title"].Value.Trim();
                phases.Add(new PhaseProgress(
                    heading.Groups["id"].Value,
                    title,
                    complete,
                    title.Contains("当前", StringComparison.OrdinalIgnoreCase),
                    checklist.Count == 0 ? string.Empty : $"{checklist.Count} checklist item(s)"));
            }
        }

        var ordered = phases
            .GroupBy(item => item.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .OrderBy(item => item.Id, StringComparer.Ordinal)
            .ToArray();
        if (ordered.Length > 0 && !ordered.Any(item => item.Current))
        {
            var currentIndex = Array.FindIndex(ordered, item => !item.Complete);
            if (currentIndex >= 0)
            {
                ordered[currentIndex] = ordered[currentIndex] with { Current = true };
            }
        }
        return ordered;
    }
}

public enum WorkflowStatusKind
{
    Idle,
    Ready,
    WaitingForHuman,
    WaitingForAgent,
    RunningOffline,
    DoneOffline,
    Done,
    Blocked,
    Failed,
    Unknown
}

public sealed record WorkflowStatus(WorkflowStatusKind Kind, string State, string Caption, string NextAction);

public static class RunnerStateMapper
{
    public static WorkflowStatus Map(string? runnerState, string? nextAction)
    {
        var state = string.IsNullOrWhiteSpace(runnerState) ? "UNKNOWN" : runnerState.Trim().ToUpperInvariant();
        var next = string.IsNullOrWhiteSpace(nextAction) ? DefaultNextAction(state) : nextAction.Trim();
        return state switch
        {
            "IDLE" or "WAITING_FOR_ACTION" => new(WorkflowStatusKind.Idle, state, "Waiting for export / 等待导出", next),
            "READY" or "REQUEST_READY" or "ACTION_READY" => new(WorkflowStatusKind.Ready, state, "Ready / 可以继续", next),
            "WAITING_FOR_CPSTUDIO" or "WAITING_FOR_LINK_IO" or "WAITING_FOR_EXPORT_2" => new(WorkflowStatusKind.WaitingForHuman, state, "Manual step required / 需要人工操作", next),
            "WAITING_FOR_AGENT" or "WAITING_FOR_AI_REVIEW" or "WAITING_FOR_COORDINATOR" => new(WorkflowStatusKind.WaitingForAgent, state, "AI review required / 等待 AI", next),
            "AUDITING" or "RUNNING" or "RUNNING_OFFLINE" => new(WorkflowStatusKind.RunningOffline, state, "Running offline / 离线执行中", next),
            "DONE_OFFLINE" => new(WorkflowStatusKind.DoneOffline, state, "Offline checks done / 离线检查完成", next),
            "DONE" => new(WorkflowStatusKind.Done, state, "Workflow complete / 流程完成", next),
            "BLOCKED" or "PREFLIGHT_BLOCKED" => new(WorkflowStatusKind.Blocked, state, "Blocked / 门禁阻止", next),
            "FAILED" => new(WorkflowStatusKind.Failed, state, "Failed / 执行失败", next),
            _ => new(WorkflowStatusKind.Unknown, state, "Status unknown / 状态未知", next)
        };
    }

    private static string DefaultNextAction(string state) => state switch
    {
        "IDLE" or "WAITING_FOR_ACTION" => "Complete CpStudio Export, then click Run next.",
        "WAITING_FOR_CPSTUDIO" => "Complete the shown CpStudio step, save, and export.",
        "WAITING_FOR_LINK_IO" => "In PLE, click Link I/O with variables, then Build.",
        "WAITING_FOR_EXPORT_2" => "Return to CpStudio and complete Export #2.",
        "WAITING_FOR_AGENT" or "WAITING_FOR_AI_REVIEW" => "Open the evidence and ask AI to review it.",
        "DONE_OFFLINE" => "Review evidence before field acceptance.",
        "DONE" => "No workflow action is pending.",
        "BLOCKED" or "PREFLIGHT_BLOCKED" or "FAILED" => "Open the latest manifest and correct the reported gate.",
        _ => "Refresh status or open the latest evidence."
    };
}

public enum WorkbenchCommand
{
    RefreshRunnerStatus,
    RunNext,
    HostStatus,
    HostStart,
    HostStop,
    ProjectPackCheck
}

public sealed record CommandSpec(string FileName, IReadOnlyList<string> Arguments, TimeSpan Timeout, string DisplayName);

public static class WorkbenchCommandCatalog
{
    public static CommandSpec Create(WorkbenchCommand command, WorkbenchPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return command switch
        {
            WorkbenchCommand.RefreshRunnerStatus => PowerShell(paths.RunnerScript, "Runner status", TimeSpan.FromMinutes(2),
                "-Command", "Status", "-EngineeringRoot", paths.EngineeringRoot),
            WorkbenchCommand.RunNext => PowerShell(paths.RunnerScript, "Run next", TimeSpan.FromMinutes(30),
                "-Command", "Run", "-EngineeringRoot", paths.EngineeringRoot),
            WorkbenchCommand.HostStatus => PowerShell(paths.HostScript, "Host status", TimeSpan.FromMinutes(2),
                "-Command", "Status", "-EngineeringRoot", paths.EngineeringRoot),
            WorkbenchCommand.HostStart => PowerShell(paths.HostScript, "Start Host", TimeSpan.FromMinutes(2),
                "-Command", "Start", "-EngineeringRoot", paths.EngineeringRoot),
            WorkbenchCommand.HostStop => PowerShell(paths.HostScript, "Stop Host", TimeSpan.FromMinutes(2),
                "-Command", "Stop", "-EngineeringRoot", paths.EngineeringRoot),
            WorkbenchCommand.ProjectPackCheck => PowerShell(paths.ProjectPackScript, "Check Project Pack", TimeSpan.FromMinutes(2),
                "-Command", "Check", "-EngineeringRoot", paths.EngineeringRoot, "-RequireReady", "-Json"),
            _ => throw new ArgumentOutOfRangeException(nameof(command), command, "Command is not allowlisted.")
        };
    }

    private static CommandSpec PowerShell(string script, string displayName, TimeSpan timeout, params string[] arguments)
    {
        var values = new List<string> { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script };
        values.AddRange(arguments);
        return new CommandSpec("pwsh.exe", values, timeout, displayName);
    }
}

public sealed record CommandResult(int ExitCode, string StandardOutput, string StandardError, TimeSpan Duration)
{
    public bool Succeeded => ExitCode == 0;
    public string CombinedOutput => string.Join(Environment.NewLine,
        new[] { StandardOutput.Trim(), StandardError.Trim() }.Where(value => value.Length > 0));
}

public static class CommandExecutor
{
    public static async Task<CommandResult> RunAsync(CommandSpec command, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        var start = new ProcessStartInfo
        {
            FileName = command.FileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in command.Arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(command.Timeout);
        using var process = new Process { StartInfo = start };
        var stopwatch = Stopwatch.StartNew();
        if (!process.Start())
        {
            throw new InvalidOperationException($"Could not start {command.DisplayName}.");
        }

        var stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
        var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            throw new TimeoutException($"{command.DisplayName} exceeded {command.Timeout.TotalMinutes:0.#} minutes.");
        }

        return new CommandResult(process.ExitCode, await stdout.ConfigureAwait(false), await stderr.ConfigureAwait(false), stopwatch.Elapsed);
    }
}

public sealed record RunnerSnapshot(
    WorkflowStatus Status,
    string ManifestPath,
    string HostState,
    string Output,
    DateTimeOffset RefreshedAt,
    JsonObject? Manifest);

public static class WorkbenchStatusReader
{
    public static RunnerSnapshot Read(WorkbenchPaths paths, string runnerOutput, string hostOutput)
    {
        var state = ReadOutputValue(runnerOutput, "RUNNER_STATE") ?? "UNKNOWN";
        var manifestPath = ReadOutputValue(runnerOutput, "RUNNER_MANIFEST") ?? paths.LatestManifest;
        var manifest = WorkbenchFiles.ReadJsonObject(manifestPath, 8 * 1024 * 1024);
        var manifestState = manifest?["result"]?["status"]?.GetValue<string>();
        var nextAction = manifest?["result"]?["nextAction"]?.GetValue<string>();
        if (!string.IsNullOrWhiteSpace(manifestState))
        {
            state = manifestState;
        }

        return new RunnerSnapshot(
            RunnerStateMapper.Map(state, nextAction),
            manifestPath,
            ReadJsonScalar(hostOutput, "state") ?? "UNKNOWN",
            JoinOutput(runnerOutput, hostOutput),
            DateTimeOffset.Now,
            manifest);
    }

    public static string? ReadOutputValue(string text, string key)
    {
        foreach (var line in text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            var prefix = key + "=";
            if (line.StartsWith(prefix, StringComparison.Ordinal))
            {
                return line[prefix.Length..].Trim();
            }
        }
        return null;
    }

    private static string? ReadJsonScalar(string text, string property)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        if (start < 0 || end <= start)
        {
            return null;
        }
        try
        {
            return JsonNode.Parse(text[start..(end + 1)])?[property]?.GetValue<string>();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string JoinOutput(params string[] values) => string.Join(
        Environment.NewLine + Environment.NewLine,
        values.Where(item => !string.IsNullOrWhiteSpace(item)).Select(item => item.Trim()));
}

public static class WorkbenchFiles
{
    public static string ReadBoundedText(string path, int maximumBytes)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new FileNotFoundException("File does not exist.", path);
        }
        if (info.Length > maximumBytes)
        {
            throw new InvalidDataException($"File exceeds the {maximumBytes} byte limit: {path}");
        }
        return File.ReadAllText(path, Encoding.UTF8);
    }

    public static string? FindNewestFile(string root, string fileName)
    {
        if (!Directory.Exists(root))
        {
            return null;
        }
        return Directory.EnumerateFiles(root, fileName, SearchOption.AllDirectories)
            .Select(path => new FileInfo(path))
            .OrderByDescending(item => item.LastWriteTimeUtc)
            .Select(item => item.FullName)
            .FirstOrDefault();
    }

    public static JsonObject? ReadJsonObject(string? path, int maximumBytes)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            return null;
        }
        try
        {
            return JsonNode.Parse(ReadBoundedText(path!, maximumBytes)) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public static class SimpleYaml
{
    public static string? GetScalar(string text, string key)
    {
        ArgumentNullException.ThrowIfNull(text);
        var parts = key.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length != 2)
        {
            throw new ArgumentException("Only section.key YAML paths are supported.", nameof(key));
        }

        string? section = null;
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith('#'))
            {
                continue;
            }
            if (!char.IsWhiteSpace(line[0]) && line.EndsWith(':'))
            {
                section = line[..^1].Trim();
                continue;
            }
            if (!string.Equals(section, parts[0], StringComparison.Ordinal) || !char.IsWhiteSpace(line[0]))
            {
                continue;
            }

            var separator = line.IndexOf(':');
            if (separator < 0 || !line[..separator].Trim().Equals(parts[1], StringComparison.Ordinal))
            {
                continue;
            }
            var value = line[(separator + 1)..].Trim();
            var comment = value.IndexOf(" #", StringComparison.Ordinal);
            if (comment >= 0)
            {
                value = value[..comment].TrimEnd();
            }
            return value.Trim('"', '\'');
        }
        return null;
    }
}

public sealed record SmokeTestResult(
    string Kind,
    bool Ready,
    string EngineeringRoot,
    int PhaseCount,
    string CurrentPhase,
    bool CpStudioProjectExists,
    bool P2ApplyEnabled,
    bool OnlineOperationsAllowed);

public static class WorkbenchSmokeTest
{
    public static SmokeTestResult Run(WorkbenchPaths paths)
    {
        var phases = WorkbenchProgressParser.Parse(WorkbenchFiles.ReadBoundedText(paths.Todo, 4 * 1024 * 1024));
        var current = phases.FirstOrDefault(item => item.Current) ?? phases.FirstOrDefault(item => !item.Complete);
        var phasesAreContiguous = phases.Count > 0 && phases
            .Select((phase, index) => phase.Id.Equals($"P{index}", StringComparison.OrdinalIgnoreCase))
            .All(value => value);
        return new SmokeTestResult(
            "ctrlx-opcon-workbench-smoke",
            phasesAreContiguous,
            paths.EngineeringRoot,
            phases.Count,
            current?.Id ?? "UNKNOWN",
            paths.CpStudioProject is not null && File.Exists(paths.CpStudioProject),
            P2ApplyEnabled: false,
            OnlineOperationsAllowed: false);
    }
}
