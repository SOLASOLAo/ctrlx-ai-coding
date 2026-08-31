using System.Text;
using System.Text.Json;
using CtrlX.OpCon.Workbench;

return WorkbenchSelfTest.Run();

internal static class WorkbenchSelfTest
{
    private static int assertionCount;

    public static int Run()
    {
        var temporaryRoot = Path.Combine(
            Path.GetTempPath(),
            "ctrlx-opcon-workbench-selftest-" + Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(temporaryRoot);
            var fixture = CreateFixture(temporaryRoot);

            Case("Workbench options are explicit", () =>
            {
                var options = WorkbenchOptions.Parse(new[]
                {
                    "--engineering-root",
                    fixture.EngineeringRoot,
                    "--smoke-test"
                });
                Check(options.EngineeringRoot == fixture.EngineeringRoot, "Engineering root option changed.");
                Check(options.SmokeTest, "Smoke-test option was not retained.");
                Throws<ArgumentException>(() => WorkbenchOptions.Parse(new[] { "--shell", "anything" }));
            });

            Case("Engineering root is validated and normalized", () =>
            {
                var paths = WorkbenchRoot.Validate(Path.Combine(fixture.EngineeringRoot, "."));
                Check(paths.EngineeringRoot == Path.GetFullPath(fixture.EngineeringRoot), "Engineering root was not normalized.");
                Check(paths.RunnerScript == fixture.RunnerScript, "Runner script path changed.");
                Check(paths.HostScript == fixture.HostScript, "Host script path changed.");
                Check(paths.ProjectPackScript == fixture.ProjectPackScript, "Project Pack script path changed.");
                Check(paths.CpStudioProject == fixture.CpStudioProject, "CpStudio path was not resolved from project.yaml.");
                Check(paths.PlcProject == fixture.PlcProject, "PLC path was not resolved from project.yaml.");
                Check(paths.IoProject == fixture.IoProject, "I/O path was not resolved from project.yaml.");
                Throws<DirectoryNotFoundException>(() => WorkbenchRoot.Validate(Path.Combine(temporaryRoot, "missing")));

                File.Move(fixture.RunnerScript, fixture.RunnerScript + ".hold");
                try
                {
                    Throws<FileNotFoundException>(() => WorkbenchRoot.Validate(fixture.EngineeringRoot));
                }
                finally
                {
                    File.Move(fixture.RunnerScript + ".hold", fixture.RunnerScript);
                }
            });

            Case("P0-P4 progress is parsed once and in order", () =>
            {
                var phases = WorkbenchProgressParser.Parse(FixtureTodo);
                Check(phases.Count == 5, "Expected exactly five engineering phases.");
                Check(string.Join(',', phases.Select(item => item.Id)) == "P0,P1,P2,P3,P4", "Phase order changed.");
                Check(phases[0].Complete && phases[1].Complete, "Completed phases were not recognized.");
                Check(!phases[2].Complete && phases[2].Current, "Current P2 phase was not recognized.");
                Check(!phases[3].Complete && !phases[4].Complete, "Pending phases were not recognized.");
            });

            Case("Generic template P0-P2 headings are supported", () =>
            {
                var phases = WorkbenchProgressParser.Parse(GenericHeadingTodo);
                Check(phases.Count == 3, "Generic template should expose its three declared phases.");
                Check(string.Join(',', phases.Select(item => item.Id)) == "P0,P1,P2", "Generic heading phase order changed.");
                Check(phases.Select(item => item.Title).SequenceEqual(new[] { "首次离线基线", "CpStudio 集成", "仿真与真机" }), "Generic heading titles changed.");
                Check(phases[0].Current, "First incomplete generic phase should be current.");
                Check(phases.All(item => !item.Complete), "Unchecked generic phases must remain incomplete.");
            });

            Case("Runner states preserve human and offline boundaries", () =>
            {
                Check(RunnerStateMapper.Map("IDLE", null).Kind == WorkflowStatusKind.Idle, "IDLE mapping changed.");
                Check(RunnerStateMapper.Map("ACTION_READY", null).Kind == WorkflowStatusKind.Ready, "ACTION_READY mapping changed.");
                Check(RunnerStateMapper.Map("WAITING_FOR_LINK_IO", null).Kind == WorkflowStatusKind.WaitingForHuman, "Link I/O must remain a human step.");
                Check(RunnerStateMapper.Map("WAITING_FOR_AGENT", null).Kind == WorkflowStatusKind.WaitingForAgent, "AI review state changed.");
                Check(RunnerStateMapper.Map("RUNNING_OFFLINE", null).Kind == WorkflowStatusKind.RunningOffline, "Offline-running state changed.");
                Check(RunnerStateMapper.Map("DONE_OFFLINE", null).Kind == WorkflowStatusKind.DoneOffline, "DONE_OFFLINE mapping changed.");
                Check(RunnerStateMapper.Map("DONE", null).Kind == WorkflowStatusKind.Done, "DONE mapping changed.");
                Check(RunnerStateMapper.Map("BLOCKED", null).Kind == WorkflowStatusKind.Blocked, "BLOCKED mapping changed.");
                Check(RunnerStateMapper.Map("FAILED", null).Kind == WorkflowStatusKind.Failed, "FAILED mapping changed.");
                Check(RunnerStateMapper.Map("NEW_STATE", "Review this").NextAction == "Review this", "Explicit next action was not retained.");
                Check(RunnerStateMapper.Map("DONE_OFFLINE", null).Kind != RunnerStateMapper.Map("DONE", null).Kind, "Offline completion must not equal final completion.");
            });

            Case("Command catalog is a fixed PowerShell 7 allowlist", () =>
            {
                var paths = WorkbenchRoot.Validate(fixture.EngineeringRoot);
                var allowed = Enum.GetValues<WorkbenchCommand>();
                Check(allowed.Length == 6, "Workbench command surface changed; review the allowlist test.");
                foreach (var command in allowed)
                {
                    var spec = WorkbenchCommandCatalog.Create(command, paths);
                    Check(spec.FileName == "pwsh.exe", $"{command} is not pinned to PowerShell 7.");
                    Check(spec.Arguments.Take(4).SequenceEqual(new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File" }), $"{command} PowerShell safety prefix changed.");
                    Check(spec.Arguments.Contains("-EngineeringRoot"), $"{command} is not bound to the selected engineering root.");
                    Check(spec.Arguments.Contains(paths.EngineeringRoot), $"{command} changed the engineering-root value.");
                    Check(!spec.Arguments.Any(item => ForbiddenOnlineWords.Any(word => item.Contains(word, StringComparison.OrdinalIgnoreCase))), $"{command} exposed an online PLC operation.");
                }

                var run = WorkbenchCommandCatalog.Create(WorkbenchCommand.RunNext, paths);
                Check(run.Arguments.Contains("Run"), "Run next no longer calls Runner -Command Run.");
                Check(run.Timeout == TimeSpan.FromMinutes(30), "Run-next timeout changed.");
                Check(WorkbenchCommandCatalog.Create(WorkbenchCommand.RefreshRunnerStatus, paths).Arguments[4] == paths.RunnerScript, "Runner Status script changed.");
                Check(WorkbenchCommandCatalog.Create(WorkbenchCommand.HostStart, paths).Arguments[4] == paths.HostScript, "Host Start script changed.");
                Check(WorkbenchCommandCatalog.Create(WorkbenchCommand.ProjectPackCheck, paths).Arguments[4] == paths.ProjectPackScript, "Project Pack Check script changed.");
                Throws<ArgumentOutOfRangeException>(() => WorkbenchCommandCatalog.Create((WorkbenchCommand)999, paths));
            });

            Case("Status snapshot prefers immutable manifest evidence", () =>
            {
                var paths = WorkbenchRoot.Validate(fixture.EngineeringRoot);
                Directory.CreateDirectory(paths.RunRoot);
                var manifestPath = Path.Combine(paths.RunRoot, "fixture", "run-manifest.json");
                Directory.CreateDirectory(Path.GetDirectoryName(manifestPath)!);
                File.WriteAllText(
                    manifestPath,
                    """
                    {
                      "result": {
                        "status": "WAITING_FOR_EXPORT_2",
                        "nextAction": "Return to CpStudio"
                      }
                    }
                    """,
                    new UTF8Encoding(false));

                var snapshot = WorkbenchStatusReader.Read(
                    paths,
                    $"RUNNER_STATE=READY{Environment.NewLine}RUNNER_MANIFEST={manifestPath}",
                    "{\"state\":\"RUNNING\"}");
                Check(snapshot.Status.Kind == WorkflowStatusKind.WaitingForHuman, "Manifest status did not override console state.");
                Check(snapshot.Status.NextAction == "Return to CpStudio", "Manifest next action was lost.");
                Check(snapshot.HostState == "RUNNING", "Host JSON state was not read.");
                Check(snapshot.ManifestPath == manifestPath, "Manifest path changed.");
            });

            Case("Smoke model stays offline and keeps P2 Apply disabled", () =>
            {
                var paths = WorkbenchRoot.Validate(fixture.EngineeringRoot);
                var smoke = WorkbenchSmokeTest.Run(paths);
                Check(smoke.Kind == "ctrlx-opcon-workbench-smoke", "Smoke result identity changed.");
                Check(smoke.Ready && smoke.PhaseCount == 5, "Smoke model did not load all five phases.");
                Check(smoke.CurrentPhase == "P2", "Smoke model did not select current P2.");
                Check(smoke.CpStudioProjectExists, "Smoke model did not find the configured CpStudio project.");
                Check(!smoke.P2ApplyEnabled, "P2 Apply must remain disabled until its backend contract is complete.");
                Check(!smoke.OnlineOperationsAllowed, "Workbench must not allow online PLC operations.");
            });

            Case("Generic three-phase template is smoke-ready", () =>
            {
                var paths = WorkbenchRoot.Validate(fixture.EngineeringRoot);
                File.WriteAllText(paths.Todo, GenericHeadingTodo, new UTF8Encoding(false));
                try
                {
                    var smoke = WorkbenchSmokeTest.Run(paths);
                    Check(smoke.Ready, "Smoke readiness must accept a contiguous P0-P2 template.");
                    Check(smoke.PhaseCount == 3, "Generic smoke phase count changed.");
                    Check(smoke.CurrentPhase == "P0", "Generic smoke should start at its first incomplete phase.");
                    Check(!smoke.P2ApplyEnabled && !smoke.OnlineOperationsAllowed, "Generic smoke weakened safety gates.");
                }
                finally
                {
                    File.WriteAllText(paths.Todo, FixtureTodo, new UTF8Encoding(false));
                }
            });

            Console.WriteLine($"Workbench self-test passed: {assertionCount} assertions.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
        finally
        {
            if (Directory.Exists(temporaryRoot))
            {
                Directory.Delete(temporaryRoot, recursive: true);
            }
        }
    }

    private static Fixture CreateFixture(string root)
    {
        var engineeringRoot = Path.Combine(root, "engineering");
        var stationRoot = Path.Combine(root, "StationFixture");
        var runnerScript = Path.Combine(engineeringRoot, "scripts", "runner", "Invoke-CtrlXOpconRunner.ps1");
        var hostScript = Path.Combine(engineeringRoot, "scripts", "runner", "Invoke-CtrlXOpconRunnerHost.ps1");
        var projectPackScript = Path.Combine(engineeringRoot, "scripts", "project", "Build-CtrlXOpconProjectPack.ps1");
        var cpStudioProject = Path.Combine(stationRoot, "Engineering", "Fixture.cpsp");
        var plcProject = Path.Combine(stationRoot, "Plc", "Fixture_PLC.project");
        var ioProject = Path.Combine(stationRoot, "Plc", "Fixture_IO.project");

        Write(runnerScript, "param()\n");
        Write(hostScript, "param()\n");
        Write(projectPackScript, "param()\n");
        Write(cpStudioProject, string.Empty);
        Write(plcProject, string.Empty);
        Write(ioProject, string.Empty);
        Write(Path.Combine(engineeringRoot, "TODO.md"), FixtureTodo);
        Write(
            Path.Combine(engineeringRoot, "config", "project.yaml"),
            """
            schema_version: 1
            paths:
              cpstudio_project: ../StationFixture/Engineering/Fixture.cpsp
              plc_project: ../StationFixture/Plc/Fixture_PLC.project
              io_project: ../StationFixture/Plc/Fixture_IO.project
            """);

        return new Fixture(
            engineeringRoot,
            runnerScript,
            hostScript,
            projectPackScript,
            cpStudioProject,
            plcProject,
            ioProject);
    }

    private static void Write(string path, string content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }

    private static void Case(string name, Action action)
    {
        action();
        Console.WriteLine($"PASS {name}");
    }

    private static void Check(bool condition, string message)
    {
        assertionCount++;
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        assertionCount++;
        try
        {
            action();
        }
        catch (T)
        {
            return;
        }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private const string FixtureTodo = """
        # TODO
        - [x] **P0 · Runner**：complete
        - [X] **P1 · ASC**：complete
        - [ ] **P2 · IOE（当前）**：current backend
        - [ ] **P2 · duplicate must be ignored**：duplicate
        - [ ] **P3 · Link I/O**：manual boundary
        - [ ] **P4 · DAT**：waiting for real data
        """;

    private const string GenericHeadingTodo = """
        # TODO — Fixture

        ## P0：首次离线基线

        - [ ] Validate the offline baseline.

        ## P1：CpStudio 集成

        - [ ] Configure and verify Export.

        ## P2：仿真与真机

        - [ ] Obtain explicit field authorization.
        """;

    private static readonly string[] ForbiddenOnlineWords =
    {
        "connect_to_device",
        "download_to_device",
        "start_stop_application",
        "write_variable",
        "force"
    };

    private sealed record Fixture(
        string EngineeringRoot,
        string RunnerScript,
        string HostScript,
        string ProjectPackScript,
        string CpStudioProject,
        string PlcProject,
        string IoProject);
}
