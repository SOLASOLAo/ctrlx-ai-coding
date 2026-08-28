using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Core;
using CtrlX.OpCon.Runner.Host;

namespace CtrlX.OpCon.Runner.Host.SelfTest;

internal static class Program
{
    internal static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(15);

    public static async Task<int> Main()
    {
        var engineeringProcessesBefore = EngineeringProcessSnapshot.Capture();
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("Host source has no Broker, MCP, PLE, or Node launch path", StaticSafetyBoundaryAsync),
            ("single owner lease rejects a second Host and can be reacquired", SingleOwnerLeaseAsync),
            ("corrupt status fails run, status, and stop closed", CorruptStatusFailsClosedAsync),
            ("WAITING_FOR_AGENT status rejects an available Agent", WaitingForAgentRejectsAvailableAgentAsync),
            ("stale schema-v1 status is safely superseded by a schema-v2 Host", StaleLegacyStatusAllowsUpgradeAsync),
            ("live schema-v1 status maps to blocked and prevents a second Host", LiveLegacyStatusFailsClosedAsync),
            ("logs roll over and retain only bounded in-root files", BoundedLogsStayInsideRuntimeRootAsync),
            ("forged alphabetic log segment is ignored during startup and listing", ForgedLogNameIsIgnoredAsync),
            ("half-open same-user Pipe is dropped without blocking status or stop", HalfOpenPipeDoesNotBlockControlAsync),
            ("concurrent heartbeat status reads never observe a sharing fault", ConcurrentHeartbeatReadsAreSafeAsync),
            ("unexpected Host termination preserves crash-recovery status", UnexpectedTerminationPreservesCrashRecoveryAsync),
            ("run, status, exact stop identity, and graceful stop are deterministic", LifecycleIsDeterministicAsync),
            ("pending action waits for Agent without execution", PendingActionWaitsForAgentAsync),
            ("Broker diagnostic pending is displayed as WAITING_FOR_AGENT", BrokerDiagnosticPendingIsDisplayedAsync),
            ("one current action executes once and exposes its terminal marker", UniqueActionExecutesExactlyOnceAsync),
            ("multiple current actions fail closed as ambiguous", MultipleActionsAreAmbiguousAsync),
            ("existing terminal result is exposed without execution", ExistingResultDoesNotExecuteAsync),
            ("long action remains single-dispatch and has a bounded shutdown drain", LongActionRemainsExecutingAsync)
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

        await Task.Delay(250).ConfigureAwait(false);
        var engineeringProcessesAfter = EngineeringProcessSnapshot.Capture();
        var unexpectedProcesses = engineeringProcessesAfter.AddedSince(engineeringProcessesBefore);
        if (unexpectedProcesses.Count > 0)
        {
            var detail = string.Join(", ", unexpectedProcesses.Select(process => $"{process.Name}({process.ProcessId})"));
            failures.Add($"Engineering process PID set increased during Host SelfTest: {detail}");
            Console.Error.WriteLine($"FAIL: {failures[^1]}");
        }

        if (failures.Count == 0)
        {
            Console.WriteLine("Runner Host offline self-test passed. No Broker, MCP, PLE, Node, or online PLC operation was started.");
            return 0;
        }

        Console.Error.WriteLine($"Runner Host offline self-test failed: {failures.Count} case(s).");
        return 1;
    }

    private static Task StaticSafetyBoundaryAsync()
    {
        var repositoryRoot = FindRepositoryRoot();
        var hostSourceRoot = Path.Combine(repositoryRoot, "src", "runner", "CtrlX.OpCon.Runner.Host");
        var sources = Directory.EnumerateFiles(hostSourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !IsBuildOutput(path))
            .ToArray();
        Require(sources.Length > 0, "Runner Host source files were not found.");

        var source = string.Join(Environment.NewLine, sources.Select(File.ReadAllText));
        Require(!source.Contains("Process.Start(", StringComparison.Ordinal) &&
            !source.Contains("Process.Start (", StringComparison.Ordinal) &&
            !source.Contains("new ProcessStartInfo", StringComparison.Ordinal),
            "Runner Host source contains a child-process launch API.");

        var project = File.ReadAllText(Path.Combine(hostSourceRoot, "CtrlX.OpCon.Runner.Host.csproj"));
        Require(!project.Contains("CtrlX.OpCon.Runner.Broker", StringComparison.OrdinalIgnoreCase),
            "Runner Host must not reference the Broker executable project.");
        Require(!project.Contains("codesys", StringComparison.OrdinalIgnoreCase) &&
            !project.Contains("node", StringComparison.OrdinalIgnoreCase),
            "Runner Host project must not reference an MCP or Node package.");
        Require(source.Contains("StartsBroker = false", StringComparison.Ordinal) &&
            source.Contains("StartsPleOrMcp = false", StringComparison.Ordinal) &&
            source.Contains("OnlineOperationsAllowed = false", StringComparison.Ordinal) &&
            source.Contains("AutomaticActionExecutionEnabled = true", StringComparison.Ordinal),
            "Runner Host status does not explicitly publish its automatic offline-consumption safety boundary.");
        return Task.CompletedTask;
    }

    private static Task SingleOwnerLeaseAsync()
    {
        using var fixture = new HostFixture();
        var paths = fixture.Paths;
        using (HostOwnerLease.Acquire(paths))
        {
            RunnerGateException? rejection = null;
            try
            {
                using var unexpected = HostOwnerLease.Acquire(paths);
            }
            catch (RunnerGateException exception)
            {
                rejection = exception;
            }

            Require(rejection?.ReasonCode == "HOST_ALREADY_RUNNING" &&
                rejection.ExitCode == RunnerExitCodes.Busy,
                "A second owner must be rejected with HOST_ALREADY_RUNNING / Busy.");
        }

        using var reacquired = HostOwnerLease.Acquire(paths);
        return Task.CompletedTask;
    }

    private static async Task CorruptStatusFailsClosedAsync()
    {
        using var fixture = new HostFixture();
        Directory.CreateDirectory(fixture.Paths.RuntimeRoot);
        File.WriteAllText(fixture.Paths.StatusPath, "{ definitely-not-valid-json", new UTF8Encoding(false));

        foreach (var command in new[] { "status", "stop", "run" })
        {
            var result = await HostCommand.RunAsync(
                command,
                fixture.EngineeringRoot,
                fixture.Paths.RuntimeRoot,
                CommandTimeout).ConfigureAwait(false);
            Require(result.ExitCode == RunnerExitCodes.GateFailure,
                $"{command} must fail closed for corrupt status, exit={result.ExitCode}.");
            Require(result.Json?["reasonCode"]?.GetValue<string>() == "HOST_STATE_INVALID",
                $"{command} did not preserve the HOST_STATE_INVALID reason.");
            Require(File.Exists(fixture.Paths.StatusPath),
                $"{command} must not silently delete corrupt status evidence.");
        }
    }

    private static Task WaitingForAgentRejectsAvailableAgentAsync()
    {
        using var fixture = new HostFixture();
        var identity = HostProcessIdentity.CaptureCurrentInteractive();
        var log = new HostLogStore(fixture.Paths);
        var now = DateTimeOffset.UtcNow;
        const string actionId = "waiting-agent-status-action";
        const string diagnosticReason = "BLOCKED_BROKER_PIPE_UNAVAILABLE";
        var actionSha256 = new string('A', 64);
        var document = new HostStatusDocument
        {
            HostInstanceId = "waiting-agent-invariant",
            State = HostStates.WaitingForAgent,
            ReasonCode = diagnosticReason,
            HostPid = identity.ProcessId,
            ProcessStartTimeUtc = identity.ProcessStartTimeUtc,
            WindowsSessionId = identity.WindowsSessionId,
            UserSid = identity.UserSid,
            ExecutablePath = identity.ExecutablePath,
            ExecutableSha256 = identity.ExecutableSha256,
            EngineeringRoot = fixture.Paths.EngineeringRoot,
            RootKey = fixture.Paths.RootKey,
            PipeName = fixture.Paths.PipeName,
            StartedAtUtc = now.AddMinutes(-1),
            HeartbeatAtUtc = now,
            ExpiresAtUtc = now.AddSeconds(10),
            Agent = new HostAgentStatus
            {
                Available = true,
                ReasonCode = "BROKER_REGISTRATION_VALIDATED",
                State = "ready",
                BrokerPid = identity.ProcessId,
                WindowsSessionId = identity.WindowsSessionId,
                Profile = "ctrlX PLC 2.6.8",
                PlcProject = Path.Combine(fixture.EngineeringRoot, "fixture.project")
            },
            Action = new HostActionStatus
            {
                State = HostActionStates.WaitingForAgent,
                ReasonCode = diagnosticReason,
                OperationId = "waiting-agent-operation",
                ActionId = actionId,
                ActionKind = "inspect_and_build",
                ActionSha256 = actionSha256,
                RunId = RunnerRunStore.GetRunId(actionId, actionSha256),
                PendingCount = 1
            },
            Safety = new HostSafetyStatus
            {
                StartsBroker = false,
                StartsPleOrMcp = false,
                OnlineOperationsAllowed = false,
                AutomaticActionExecutionEnabled = true
            },
            LogDirectory = fixture.Paths.LogDirectory,
            ActiveLogPath = log.ActiveLogPath
        };

        RunnerGateException? rejection = null;
        try
        {
            new HostStatusStore(fixture.Paths).Publish(document);
        }
        catch (RunnerGateException exception)
        {
            rejection = exception;
        }
        Require(rejection?.ReasonCode == "HOST_STATE_INVALID" &&
            !File.Exists(fixture.Paths.StatusPath),
            "WAITING_FOR_AGENT accepted a contradictory Agent.Available=true status.");

        document.Agent = new HostAgentStatus
        {
            Available = false,
            ReasonCode = diagnosticReason
        };
        var store = new HostStatusStore(fixture.Paths);
        store.Publish(document);
        var accepted = store.ReadStructured();
        Require(accepted?.State == HostStates.WaitingForAgent &&
            accepted.Agent.Available == false &&
            accepted.ReasonCode == diagnosticReason,
            "WAITING_FOR_AGENT rejected its consistent unavailable-Agent counterpart.");
        return Task.CompletedTask;
    }

    private static async Task StaleLegacyStatusAllowsUpgradeAsync()
    {
        await using var fixture = new RunningHostFixture();
        using var current = Process.GetCurrentProcess();
        WriteLegacyStatusV1(fixture.Paths, hostPid: int.MaxValue, current);
        var legacyBytes = File.ReadAllBytes(fixture.Paths.StatusPath);
        Require(JsonNode.Parse(legacyBytes)?["schemaVersion"]?.GetValue<int>() == 1,
            "Stale-status fixture did not start from a schema-v1 document.");

        _ = await fixture.StartAsync().ConfigureAwait(false);
        var upgraded = await fixture.WaitForStateAsync(
            HostStates.WaitingForAction,
            CommandTimeout).ConfigureAwait(false);
        Require(upgraded.SchemaVersion == HostConstants.StatusSchemaVersion &&
            upgraded.Action.State == HostActionStates.None &&
            upgraded.Safety.AutomaticActionExecutionEnabled,
            "A dead schema-v1 status was not safely superseded by the current Host contract.");

        var persisted = JsonNode.Parse(File.ReadAllBytes(fixture.Paths.StatusPath));
        Require(persisted?["schemaVersion"]?.GetValue<int>() == HostConstants.StatusSchemaVersion &&
            persisted["action"]?["state"]?.GetValue<string>() == HostActionStates.None,
            "The replacement Host did not publish a complete schema-v2 status document.");
        await StopGracefullyAsync(fixture).ConfigureAwait(false);
    }

    private static async Task LiveLegacyStatusFailsClosedAsync()
    {
        using var fixture = new HostFixture();
        using var current = Process.GetCurrentProcess();
        WriteLegacyStatusV1(fixture.Paths, current.Id, current);
        var legacyBytes = File.ReadAllBytes(fixture.Paths.StatusPath);

        var observation = new HostStatusStore(fixture.Paths).Observe();
        Require(observation.Live &&
            observation.Document?.SchemaVersion == HostConstants.StatusSchemaVersion &&
            observation.Document.State == HostStates.Blocked &&
            observation.Document.ReasonCode == "HOST_LEGACY_VERSION_ACTIVE" &&
            observation.Document.Action.State == HostActionStates.Invalid &&
            observation.Document.Action.ReasonCode == "HOST_LEGACY_VERSION_ACTIVE",
            "A live schema-v1 status was not exposed as the explicit schema-v2 blocked state.");

        var run = await HostCommand.RunAsync(
            "run",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(run.ExitCode == RunnerExitCodes.Busy &&
            run.Json?["reasonCode"]?.GetValue<string>() == "HOST_ALREADY_RUNNING",
            "A live schema-v1 Host identity did not fail closed against a second Host start.");
        Require(File.ReadAllBytes(fixture.Paths.StatusPath).SequenceEqual(legacyBytes),
            "Reading or rejecting a live schema-v1 status rewrote its original evidence.");
    }

    private static void WriteLegacyStatusV1(
        HostRuntimePaths paths,
        int hostPid,
        Process identityProcess)
    {
        var executablePath = identityProcess.MainModule?.FileName;
        Require(!string.IsNullOrWhiteSpace(executablePath) && File.Exists(executablePath),
            "SelfTest process executable identity is unavailable.");
        var now = DateTimeOffset.UtcNow;
        var activeLogPath = new HostLogStore(paths).ActiveLogPath;
        var document = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = HostConstants.StatusKind,
            ["protocolVersion"] = HostConstants.ProtocolVersion,
            ["hostInstanceId"] = "legacy-host-selftest",
            ["state"] = "WAITING_FOR_AGENT",
            ["reasonCode"] = "BLOCKED_BROKER_REGISTRATION_MISSING",
            ["hostPid"] = hostPid,
            ["processStartTimeUtc"] = identityProcess.StartTime.ToUniversalTime(),
            ["windowsSessionId"] = identityProcess.SessionId,
            ["userSid"] = BrokerWireProtocol.CurrentUserSid(),
            ["executablePath"] = HostRuntimePaths.NormalizePath(executablePath!),
            ["executableSha256"] = RunnerHash.Sha256File(executablePath!),
            ["engineeringRoot"] = paths.EngineeringRoot,
            ["rootKey"] = paths.RootKey,
            ["pipeName"] = paths.PipeName,
            ["startedAtUtc"] = now.AddMinutes(-1),
            ["heartbeatAtUtc"] = now,
            ["expiresAtUtc"] = now.AddSeconds(10),
            ["agent"] = new JsonObject
            {
                ["available"] = false,
                ["reasonCode"] = "BLOCKED_BROKER_REGISTRATION_MISSING"
            },
            ["safety"] = new JsonObject
            {
                ["startsBroker"] = false,
                ["startsPleOrMcp"] = false,
                ["onlineOperationsAllowed"] = false,
                ["automaticActionExecutionEnabled"] = false
            },
            ["logDirectory"] = paths.LogDirectory,
            ["activeLogPath"] = activeLogPath
        };
        Directory.CreateDirectory(paths.RuntimeRoot);
        File.WriteAllText(
            paths.StatusPath,
            document.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static Task BoundedLogsStayInsideRuntimeRootAsync()
    {
        using var fixture = new HostFixture();
        Directory.CreateDirectory(fixture.Paths.LogDirectory);
        var outsideSentinel = Path.Combine(fixture.Root, "host-19990101-99.jsonl");
        var unrelatedInside = Path.Combine(fixture.Paths.LogDirectory, "keep-me.txt");
        var forgedInside = Path.Combine(
            fixture.Paths.LogDirectory,
            $"host-{DateTime.UtcNow:yyyyMMdd}-aa.jsonl");
        File.WriteAllText(outsideSentinel, "outside-runtime-log-directory", new UTF8Encoding(false));
        File.WriteAllText(unrelatedInside, "unrelated-file", new UTF8Encoding(false));
        File.WriteAllText(forgedInside, "forged-log-name", new UTF8Encoding(false));

        var now = DateTime.UtcNow;
        for (var index = 0; index < 20; index++)
        {
            var path = Path.Combine(fixture.Paths.LogDirectory, $"host-20000101-{index:00}.jsonl");
            File.WriteAllText(path, $"fixture-{index}", new UTF8Encoding(false));
            File.SetLastWriteTimeUtc(path, now.AddMinutes(-100 + index));
        }

        var fullSegment = Path.Combine(
            fixture.Paths.LogDirectory,
            $"host-{DateTime.UtcNow:yyyyMMdd}-00.jsonl");
        using (var stream = new FileStream(fullSegment, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            stream.SetLength(4L * 1024 * 1024);
        }
        File.SetLastWriteTimeUtc(fullSegment, now);

        var store = new HostLogStore(fixture.Paths);
        Require(!store.ActiveLogPath.Equals(fullSegment, StringComparison.OrdinalIgnoreCase),
            "A full 4 MiB segment must roll over before another record is written.");
        store.Write("SELFTEST", HostStates.Idle, "SELFTEST_LOG", "fixture-log-host");

        var recent = store.ListRecent();
        Require(recent.Count <= 14, "Runner Host retained more than 14 managed log segments.");
        Require(recent.All(file =>
                Path.GetDirectoryName(file.Path)?.Equals(fixture.Paths.LogDirectory, StringComparison.OrdinalIgnoreCase) == true),
            "Runner Host reported a log outside its dedicated log directory.");
        Require(File.Exists(outsideSentinel) && File.ReadAllText(outsideSentinel) == "outside-runtime-log-directory",
            "Log retention deleted or altered a matching filename outside its log directory.");
        Require(File.Exists(unrelatedInside) && File.ReadAllText(unrelatedInside) == "unrelated-file",
            "Log retention deleted or altered an unrelated in-directory file.");
        Require(File.Exists(forgedInside) && File.ReadAllText(forgedInside) == "forged-log-name",
            "Log retention deleted or altered an alphabetic forged segment.");
        Require(!HostLogStore.IsManagedLogName(Path.GetFileName(forgedInside)) &&
            recent.All(file => !file.Path.Equals(forgedInside, StringComparison.OrdinalIgnoreCase)),
            "An alphabetic forged segment was treated as a managed Host log.");
        Require(File.Exists(store.ActiveLogPath) && new FileInfo(store.ActiveLogPath).Length < 4L * 1024 * 1024,
            "The active rollover segment is missing or already exceeds its fixed bound.");
        return Task.CompletedTask;
    }

    private static async Task ForgedLogNameIsIgnoredAsync()
    {
        await using var fixture = new RunningHostFixture();
        Directory.CreateDirectory(fixture.Paths.LogDirectory);
        var forged = Path.Combine(
            fixture.Paths.LogDirectory,
            $"host-{DateTime.UtcNow:yyyyMMdd}-aa.jsonl");
        File.WriteAllText(forged, "must-remain-unmanaged", new UTF8Encoding(false));
        var now = DateTime.UtcNow;
        for (var index = 0; index < 18; index++)
        {
            var managed = Path.Combine(fixture.Paths.LogDirectory, $"host-20010101-{index:00}.jsonl");
            File.WriteAllText(managed, $"managed-{index}", new UTF8Encoding(false));
            File.SetLastWriteTimeUtc(managed, now.AddMinutes(-100 + index));
        }

        var status = await fixture.StartAsync().ConfigureAwait(false);
        Require(status.HostInstanceId.Length == 32 && File.Exists(forged),
            "A forged alphabetic segment prevented Host startup or was deleted during retention.");

        var logs = await HostCommand.RunAsync(
            "logs",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        var files = logs.Json?["files"] as JsonArray
            ?? throw new InvalidOperationException("Host logs command returned no files array.");
        Require(logs.ExitCode == RunnerExitCodes.Done && files.Count <= 14,
            "Host logs listing failed or exceeded its managed retention bound.");
        Require(files.All(node =>
                !string.Equals(node?["path"]?.GetValue<string>(), forged, StringComparison.OrdinalIgnoreCase)),
            "Host logs listing exposed the forged alphabetic segment as managed data.");
        Require(File.ReadAllText(forged) == "must-remain-unmanaged",
            "Host startup or listing altered the forged alphabetic segment.");

        await StopGracefullyAsync(fixture).ConfigureAwait(false);
    }

    private static async Task HalfOpenPipeDoesNotBlockControlAsync()
    {
        await using var fixture = new RunningHostFixture();
        var status = await fixture.StartAsync().ConfigureAwait(false);
        await using var halfOpen = new NamedPipeClientStream(
            ".",
            status.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var connectTimeout = new CancellationTokenSource(CommandTimeout);
        await halfOpen.ConnectAsync(connectTimeout.Token).ConfigureAwait(false);

        // HostControlServer owns a three-second per-connection deadline. Keep the
        // client open and silent beyond it; only this connection may be dropped.
        await Task.Delay(TimeSpan.FromMilliseconds(3750)).ConfigureAwait(false);
        var observed = await HostCommand.RunAsync(
            "status",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(observed.ExitCode == RunnerExitCodes.Done &&
            observed.Json?["hostInstanceId"]?.GetValue<string>() == status.HostInstanceId,
            "A half-open control Pipe prevented status from observing the live Host.");

        await StopGracefullyAsync(fixture).ConfigureAwait(false);
    }

    private static async Task ConcurrentHeartbeatReadsAreSafeAsync()
    {
        await using var fixture = new RunningHostFixture();
        var initial = await fixture.StartAsync().ConfigureAwait(false);
        var failures = new ConcurrentQueue<Exception>();
        var reads = 0;
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromMilliseconds(4500);
        var readers = Enumerable.Range(0, 4).Select(async _ =>
        {
            var store = new HostStatusStore(fixture.Paths);
            while (DateTimeOffset.UtcNow < deadline)
            {
                try
                {
                    var status = store.ReadLive();
                    if (status?.HostInstanceId != initial.HostInstanceId)
                    {
                        throw new InvalidOperationException("Concurrent status read returned a missing or foreign Host identity.");
                    }
                    Interlocked.Increment(ref reads);
                }
                catch (Exception exception)
                {
                    failures.Enqueue(exception);
                }

                await Task.Delay(20).ConfigureAwait(false);
            }
        }).ToArray();
        await Task.WhenAll(readers).ConfigureAwait(false);

        Require(reads >= 200, $"Concurrent heartbeat test made too few successful reads: {reads}.");
        Require(failures.IsEmpty,
            $"Concurrent status reads failed during atomic heartbeat replacement: {string.Join(" | ", failures.Select(failure => failure.Message))}");
        await StopGracefullyAsync(fixture).ConfigureAwait(false);
    }

    private static async Task UnexpectedTerminationPreservesCrashRecoveryAsync()
    {
        await using var fixture = new RunningHostFixture();
        var live = await fixture.StartAsync().ConfigureAwait(false);
        await fixture.TerminateUnexpectedlyAsync().ConfigureAwait(false);

        Require(File.Exists(fixture.Paths.StatusPath),
            "Unexpected termination removed the last live status evidence.");
        var observation = new HostStatusStore(fixture.Paths).Observe();
        Require(!observation.Live && observation.CrashRecoveryPending &&
            observation.ReasonCode == "HOST_CRASH_RECOVERY_PENDING" &&
            observation.Document?.HostInstanceId == live.HostInstanceId,
            "Dead-process status was not preserved as an exact crash-recovery tombstone.");

        var status = await HostCommand.RunAsync(
            "status",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(status.ExitCode == RunnerExitCodes.Done &&
            status.Json?["state"]?.GetValue<string>() == HostStates.Stopped &&
            status.Json?["reasonCode"]?.GetValue<string>() == "HOST_CRASH_RECOVERY_PENDING" &&
            status.Json?["crashRecoveryPending"]?.GetValue<bool>() == true &&
            status.Json?["lastHostInstanceId"]?.GetValue<string>() == live.HostInstanceId &&
            status.Json?["lastHostPid"]?.GetValue<int>() == live.HostPid,
            "CLI status did not expose the preserved crash-recovery identity.");
    }

    private static async Task StopGracefullyAsync(RunningHostFixture fixture)
    {
        var stop = await HostCommand.RunAsync(
            "stop",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(stop.ExitCode == RunnerExitCodes.Done &&
            stop.Json?["accepted"]?.GetValue<bool>() == true &&
            stop.Json?["reasonCode"]?.GetValue<string>() == "HOST_STOP_ACCEPTED",
            "Runner Host did not acknowledge an exact-identity graceful stop.");
        await fixture.WaitForExitAsync(CommandTimeout).ConfigureAwait(false);
        Require(fixture.ExitCode == RunnerExitCodes.Done,
            $"Runner Host graceful stop returned exit={fixture.ExitCode}.");
    }

    private static async Task LifecycleIsDeterministicAsync()
    {
        await using var fixture = new RunningHostFixture();
        var forbiddenBefore = EngineeringProcessSnapshot.Capture();
        _ = await fixture.StartAsync().ConfigureAwait(false);
        var firstStatus = await fixture.WaitForStateAsync(
            HostStates.WaitingForAction,
            CommandTimeout).ConfigureAwait(false);

        Require(firstStatus.State == HostStates.WaitingForAction &&
            firstStatus.ReasonCode == "HOST_NO_PENDING_ACTION" &&
            firstStatus.Action.State == HostActionStates.None,
            $"An isolated Host should wait for a current action, state={firstStatus.State}, reason={firstStatus.ReasonCode}.");
        Require(!firstStatus.Agent.Available,
            "An isolated Host must not invent an available interactive Broker Agent.");
        Require(!firstStatus.Safety.StartsBroker &&
            !firstStatus.Safety.StartsPleOrMcp &&
            !firstStatus.Safety.OnlineOperationsAllowed &&
            firstStatus.Safety.AutomaticActionExecutionEnabled,
            "Live Host status violated its offline safety contract.");

        var statusOne = await HostCommand.RunAsync(
            "status",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        var statusTwo = await HostCommand.RunAsync(
            "status",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(statusOne.ExitCode == RunnerExitCodes.Done && statusTwo.ExitCode == RunnerExitCodes.Done,
            "Repeated status commands must succeed.");
        Require(StatusIdentity(statusOne.Json) == StatusIdentity(statusTwo.Json),
            "Repeated status commands did not return the same exact live Host identity.");
        Require(statusOne.Json?["hostInstanceId"]?.GetValue<string>() == firstStatus.HostInstanceId &&
            statusOne.Json?["hostPid"]?.GetValue<int>() == fixture.ProcessId,
            "Status did not bind to the running Host instance and PID.");

        var duplicateRun = await HostCommand.RunAsync(
            "run",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(duplicateRun.ExitCode == RunnerExitCodes.Busy &&
            duplicateRun.Json?["reasonCode"]?.GetValue<string>() == "HOST_ALREADY_RUNNING",
            "A duplicate run did not fail with the stable single-owner result.");

        var mismatchReply = await SendIdentityMismatchStopAsync(firstStatus).ConfigureAwait(false);
        Require(!mismatchReply.Accepted && mismatchReply.ReasonCode == "HOST_STOP_IDENTITY_MISMATCH",
            "A stop request with the wrong Host instance identity was not rejected.");
        Require(!fixture.HasExited && fixture.Paths.CreateStatusStore().ReadLive()?.HostInstanceId == firstStatus.HostInstanceId,
            "An identity-mismatched stop request altered the running Host.");

        await Task.Delay(200).ConfigureAwait(false);
        Require(EngineeringProcessSnapshot.Capture().AddedSince(forbiddenBefore).Count == 0,
            "Runner Host started a Broker, MCP, PLE, or Node process while idle.");

        var stop = await HostCommand.RunAsync(
            "stop",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(stop.ExitCode == RunnerExitCodes.Done &&
            stop.Json?["accepted"]?.GetValue<bool>() == true &&
            stop.Json?["reasonCode"]?.GetValue<string>() == "HOST_STOP_ACCEPTED",
            "The exact-identity stop command was not acknowledged.");
        await fixture.WaitForExitAsync(CommandTimeout).ConfigureAwait(false);
        Require(fixture.ExitCode == RunnerExitCodes.Done,
            $"Runner Host did not exit cleanly after stop, exit={fixture.ExitCode}.");
        Require(!File.Exists(fixture.Paths.StatusPath),
            "Graceful stop left a live status document behind.");

        var secondStop = await HostCommand.RunAsync(
            "stop",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(secondStop.ExitCode == RunnerExitCodes.Done &&
            secondStop.Json?["accepted"]?.GetValue<bool>() == true &&
            secondStop.Json?["reasonCode"]?.GetValue<string>() == "HOST_ALREADY_STOPPED",
            "Repeated stop must be an idempotent HOST_ALREADY_STOPPED success.");

        var stoppedStatus = await HostCommand.RunAsync(
            "status",
            fixture.EngineeringRoot,
            fixture.Paths.RuntimeRoot,
            CommandTimeout).ConfigureAwait(false);
        Require(stoppedStatus.ExitCode == RunnerExitCodes.Done &&
            stoppedStatus.Json?["state"]?.GetValue<string>() == HostStates.Stopped &&
            stoppedStatus.Json?["reasonCode"]?.GetValue<string>() == "HOST_NOT_RUNNING",
            "Status after graceful stop must deterministically report STOPPED.");

        var logText = string.Join(
            Environment.NewLine,
            Directory.EnumerateFiles(fixture.Paths.LogDirectory, "host-*.jsonl", SearchOption.TopDirectoryOnly)
                .Select(File.ReadAllText));
        Require(logText.Contains("\"eventName\":\"HOST_STOPPING\"", StringComparison.Ordinal) &&
            logText.Contains("\"eventName\":\"HOST_STOPPED\"", StringComparison.Ordinal),
            "Graceful stop log does not contain both STOPPING and STOPPED evidence.");
    }

    private static Task PendingActionWaitsForAgentAsync()
    {
        using var fixture = new HostConsumerFixture();
        var action = fixture.CreatePendingAction("cpstudio-stage2-no-agent");
        var executor = new RecordingHostActionExecutor((_, _) =>
            throw new InvalidOperationException("An action was executed without an Agent."));
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var first = consumer.Tick(agentAvailable: false, CancellationToken.None);
        var second = consumer.Tick(agentAvailable: false, CancellationToken.None);

        Require(first.State == HostActionStates.WaitingForAgent &&
            first.ReasonCode == "HOST_WAITING_FOR_AGENT" &&
            first.OperationId == action.OperationId &&
            first.ActionId == action.ActionId &&
            first.ActionSha256 == action.ActionSha256 &&
            first.PendingCount == 1,
            "A current action without an Agent was not exposed as WAITING_FOR_AGENT.");
        Require(second.State == HostActionStates.WaitingForAgent && executor.Calls == 0,
            "Repeated no-Agent ticks executed or lost the pending action.");
        Require(!File.Exists(action.ResultPath) && !File.Exists(action.ClaimPath),
            "Waiting for an Agent fabricated a claim or terminal result.");
        return Task.CompletedTask;
    }

    private static Task BrokerDiagnosticPendingIsDisplayedAsync()
    {
        using var fixture = new HostConsumerFixture();
        var action = fixture.CreatePendingAction("cpstudio-stage2-broker-diagnostic");
        var pending = new RunnerGateException(
            "BROKER_SESSION_PENDING",
            "The Broker session remains unavailable.",
            RunnerExitCodes.Busy,
            "BLOCKED_BROKER_PROFILE_MISMATCH");
        var executor = new RecordingHostActionExecutor((_, _) =>
            Task.FromException<RunnerExecutionResult>(pending));
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var dispatch = consumer.Tick(agentAvailable: true, CancellationToken.None);
        var displayed = consumer.Tick(agentAvailable: true, CancellationToken.None);

        Require(pending.ReasonCode == "BROKER_SESSION_PENDING" &&
            pending.DiagnosticReasonCode == "BLOCKED_BROKER_PROFILE_MISMATCH",
            "The pending exception did not preserve separate control and diagnostic reasons.");
        Require(dispatch.State == HostActionStates.Executing &&
            displayed.State == HostActionStates.WaitingForAgent &&
            displayed.ReasonCode == "BLOCKED_BROKER_PROFILE_MISMATCH" &&
            displayed.OperationId == action.OperationId &&
            displayed.ActionId == action.ActionId &&
            displayed.PendingCount == 1 &&
            executor.Calls == 1,
            "HostActionConsumer did not display the Broker diagnostic as WAITING_FOR_AGENT.");
        Require(!File.Exists(action.ResultPath),
            "Diagnostic pending fabricated a terminal result marker.");
        return Task.CompletedTask;
    }

    private static Task UniqueActionExecutesExactlyOnceAsync()
    {
        using var fixture = new HostConsumerFixture();
        var action = fixture.CreatePendingAction("cpstudio-stage2-one-action");
        var executor = new RecordingHostActionExecutor((entry, _) =>
        {
            Require(entry.ActionId == action.ActionId &&
                entry.ActionSha256 == action.ActionSha256,
                "Host dispatched an action identity other than the unique current action.");
            return Task.FromResult(fixture.WriteTerminalResult(action, RunnerStates.Done));
        });
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var started = consumer.Tick(agentAvailable: true, CancellationToken.None);
        var completed = consumer.Tick(agentAvailable: true, CancellationToken.None);
        var rediscovered = consumer.Tick(agentAvailable: true, CancellationToken.None);

        Require(started.State == HostActionStates.Executing &&
            started.ReasonCode == "HOST_ACTION_EXECUTION_STARTED",
            "The unique current action did not enter EXECUTING.");
        Require(completed.State == HostActionStates.ResultReady &&
            completed.ReasonCode == "HOST_ACTION_RESULT_READY" &&
            completed.ResultState == RunnerStates.Done &&
            completed.ResultPath == action.ResultPath &&
            File.Exists(action.ResultPath),
            "The unique action did not expose its terminal result marker.");
        Require(rediscovered.State == HostActionStates.ResultReady && executor.Calls == 1,
            "A terminal result marker caused the unique action to execute more than once.");
        return Task.CompletedTask;
    }

    private static Task MultipleActionsAreAmbiguousAsync()
    {
        using var fixture = new HostConsumerFixture();
        _ = fixture.CreatePendingAction("cpstudio-stage2-ambiguous-a", createdAtUtc: DateTimeOffset.UtcNow.AddSeconds(-2));
        _ = fixture.CreatePendingAction("cpstudio-stage2-ambiguous-b", createdAtUtc: DateTimeOffset.UtcNow.AddSeconds(-1));
        var executor = new RecordingHostActionExecutor((_, _) =>
            throw new InvalidOperationException("An ambiguous queue reached execution."));
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var status = consumer.Tick(agentAvailable: true, CancellationToken.None);

        Require(status.State == HostActionStates.Ambiguous &&
            status.ReasonCode == "ACTION_QUEUE_AMBIGUOUS" &&
            status.PendingCount == 2 &&
            status.OperationId is null &&
            status.ActionId is null,
            "Multiple current actions were not rejected as an identity-free ambiguous queue.");
        Require(executor.Calls == 0,
            "An ambiguous queue dispatched an action.");
        return Task.CompletedTask;
    }

    private static Task ExistingResultDoesNotExecuteAsync()
    {
        using var fixture = new HostConsumerFixture();
        var action = fixture.CreatePendingAction("cpstudio-stage2-existing-result");
        _ = fixture.WriteTerminalResult(action, RunnerStates.Blocked);
        var executor = new RecordingHostActionExecutor((_, _) =>
            throw new InvalidOperationException("An existing terminal result reached execution."));
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var status = consumer.Tick(agentAvailable: true, CancellationToken.None);

        Require(status.State == HostActionStates.ResultReady &&
            status.ReasonCode == "HOST_ACTION_RESULT_READY" &&
            status.OperationId == action.OperationId &&
            status.ActionId == action.ActionId &&
            status.ResultState == RunnerStates.Blocked &&
            status.ResultPath == action.ResultPath,
            "An existing terminal result was not exposed without dispatch.");
        Require(executor.Calls == 0,
            "An existing terminal result replayed its action through the executor.");
        return Task.CompletedTask;
    }

    private static async Task LongActionRemainsExecutingAsync()
    {
        using var fixture = new HostConsumerFixture();
        var action = fixture.CreatePendingAction("cpstudio-stage2-long-action");
        var completion = new TaskCompletionSource<RunnerExecutionResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var executor = new RecordingHostActionExecutor((entry, _) =>
        {
            Require(entry.ActionId == action.ActionId,
                "Long-action executor received the wrong action identity.");
            return completion.Task;
        });
        var consumer = new HostActionConsumer(
            fixture.EngineeringRoot,
            fixture.ActivatedAtUtc,
            executor: executor);

        var started = consumer.Tick(agentAvailable: true, CancellationToken.None);
        var stillRunningOne = consumer.Tick(agentAvailable: true, CancellationToken.None);
        var stillRunningTwo = consumer.Tick(agentAvailable: false, CancellationToken.None);

        Require(started.State == HostActionStates.Executing &&
            stillRunningOne.State == HostActionStates.Executing &&
            stillRunningTwo.State == HostActionStates.Executing &&
            executor.Calls == 1,
            "A long-running action did not remain EXECUTING under one dispatch.");
        Require(!File.Exists(action.ResultPath),
            "A long-running action fabricated a terminal result before completion.");

        var drainTimer = Stopwatch.StartNew();
        var drained = await consumer.DrainAsync(TimeSpan.FromMilliseconds(100)).ConfigureAwait(false);
        drainTimer.Stop();
        Require(!drained &&
            drainTimer.Elapsed < TimeSpan.FromSeconds(2) &&
            !completion.Task.IsCompleted &&
            executor.Calls == 1,
            "Shutdown drain did not return within its bound while preserving the active action for recovery.");

        var result = fixture.WriteTerminalResult(action, RunnerStates.Done);
        completion.SetResult(result);
        var completed = consumer.Tick(agentAvailable: true, CancellationToken.None);
        Require(completed.State == HostActionStates.ResultReady &&
            completed.ResultState == RunnerStates.Done &&
            executor.Calls == 1,
            "A completed long-running action was not surfaced once as RESULT_READY.");
    }

    private static async Task<HostStopReply> SendIdentityMismatchStopAsync(HostStatusDocument status)
    {
        using var timeout = new CancellationTokenSource(CommandTimeout);
        await using var client = new NamedPipeClientStream(
            ".",
            status.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
        var nonce = Guid.NewGuid().ToString("N");
        await HostPipeCodec.WriteAsync(
            client,
            new HostStopRequest
            {
                HostInstanceId = Guid.NewGuid().ToString("N"),
                EngineeringRoot = status.EngineeringRoot,
                UserSid = status.UserSid,
                WindowsSessionId = status.WindowsSessionId,
                ClientNonce = nonce
            },
            timeout.Token).ConfigureAwait(false);
        var reply = await HostPipeCodec.ReadAsync<HostStopReply>(client, timeout.Token).ConfigureAwait(false);
        Require(reply.HostInstanceId == status.HostInstanceId && reply.ClientNonce == nonce,
            "Rejected stop reply was not bound to the live Host and client nonce.");
        return reply;
    }

    private static string StatusIdentity(JsonNode? status)
    {
        Require(status is not null, "Status command returned no JSON document.");
        return string.Join(
            "|",
            status!["hostInstanceId"]?.GetValue<string>(),
            status["hostPid"]?.GetValue<int>(),
            status["processStartTimeUtc"]?.GetValue<DateTimeOffset>(),
            status["windowsSessionId"]?.GetValue<int>(),
            status["userSid"]?.GetValue<string>(),
            status["executablePath"]?.GetValue<string>(),
            status["executableSha256"]?.GetValue<string>(),
            status["engineeringRoot"]?.GetValue<string>(),
            status["rootKey"]?.GetValue<string>(),
            status["pipeName"]?.GetValue<string>());
    }

    private static bool IsBuildOutput(string path) =>
        path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Any(part => part is "bin" or "obj");

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var current = new DirectoryInfo(Path.GetFullPath(start));
            while (current is not null)
            {
                if (File.Exists(Path.Combine(current.FullName, "src", "runner", "CtrlX.OpCon.Runner.Host", "CtrlX.OpCon.Runner.Host.csproj")))
                {
                    return current.FullName;
                }

                current = current.Parent;
            }
        }

        throw new InvalidOperationException("Could not locate the ctrlx-ai-coding repository root.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

internal sealed record HostConsumerActionFixture(
    string OperationId,
    string ActionId,
    string ActionKind,
    string ActionPath,
    string ActionSha256,
    string RunId,
    string RunRoot,
    string ClaimPath,
    string ResultPath);

internal sealed class HostConsumerFixture : IDisposable
{
    public HostConsumerFixture()
    {
        Root = Path.Combine(Path.GetTempPath(), $"ctrlx-opcon-host-consumer-selftest-{Guid.NewGuid():N}");
        EngineeringRoot = Path.Combine(Root, "Engineering");
        Directory.CreateDirectory(EngineeringRoot);
        ActivatedAtUtc = DateTimeOffset.UtcNow.AddMinutes(-10);
    }

    public string Root { get; }

    public string EngineeringRoot { get; }

    public DateTimeOffset ActivatedAtUtc { get; }

    public HostConsumerActionFixture CreatePendingAction(
        string operationId,
        string actionKind = "inspect_and_build",
        int sequence = 1,
        DateTimeOffset? createdAtUtc = null)
    {
        var created = (createdAtUtc ?? DateTimeOffset.UtcNow).ToUniversalTime();
        var actionId = $"{operationId}-{sequence:0000}";
        var operationRoot = Path.Combine(
            EngineeringRoot,
            "data",
            "operations",
            "cpstudio-stage2",
            operationId);
        var actionsRoot = Path.Combine(operationRoot, "actions");
        Directory.CreateDirectory(actionsRoot);
        var actionPath = Path.Combine(actionsRoot, $"{sequence:0000}-{actionKind}.json");
        WriteJson(actionPath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-request",
            ["operationId"] = operationId,
            ["actionId"] = actionId,
            ["actionKind"] = actionKind,
            ["sequence"] = sequence,
            ["createdAtUtc"] = created.ToString("O"),
            ["status"] = "WAITING_FOR_RUNNER"
        });
        var actionSha256 = RunnerHash.Sha256File(actionPath);
        var operationPath = Path.Combine(operationRoot, "operation.json");
        WriteJson(operationPath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-post-export-operation",
            ["operationId"] = operationId,
            ["status"] = "WAITING_FOR_RUNNER",
            ["currentAction"] = new JsonObject
            {
                ["actionId"] = actionId,
                ["kind"] = actionKind,
                ["sequence"] = sequence,
                ["createdAtUtc"] = created.ToString("O"),
                ["path"] = actionPath,
                ["sha256"] = actionSha256
            }
        });
        File.SetLastWriteTimeUtc(operationPath, DateTime.UtcNow);

        var runId = RunnerRunStore.GetRunId(actionId, actionSha256);
        var runRoot = RunnerRunStore.GetRunRoot(EngineeringRoot, actionId, actionSha256);
        return new HostConsumerActionFixture(
            operationId,
            actionId,
            actionKind,
            actionPath,
            actionSha256,
            runId,
            runRoot,
            Path.Combine(runRoot, "claim.json"),
            Path.Combine(runRoot, "result.json"));
    }

    public RunnerExecutionResult WriteTerminalResult(
        HostConsumerActionFixture action,
        string state)
    {
        RequireTerminal(state);
        Directory.CreateDirectory(action.RunRoot);
        var reasonCode = state switch
        {
            RunnerStates.Done => "RUNNER_SUCCEEDED",
            RunnerStates.Blocked => "BLOCKED_SELFTEST",
            RunnerStates.Failed => "FAILED_SELFTEST",
            RunnerStates.Unknown => "UNKNOWN_SELFTEST",
            _ => throw new InvalidOperationException($"Unsupported terminal fixture state: {state}")
        };
        var exitCode = state switch
        {
            RunnerStates.Done => RunnerExitCodes.Done,
            RunnerStates.Blocked => RunnerExitCodes.Blocked,
            _ => RunnerExitCodes.GateFailure
        };
        WriteJson(action.ResultPath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-result",
            ["runId"] = action.RunId,
            ["state"] = state,
            ["reasonCode"] = reasonCode,
            ["exitCode"] = exitCode,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionPath"] = action.ActionPath,
            ["actionSha256"] = action.ActionSha256,
            ["observationPath"] = null,
            ["evidencePath"] = null,
            ["completedAtUtc"] = DateTimeOffset.UtcNow.ToString("O")
        });
        return new RunnerExecutionResult(
            action.RunId,
            state,
            reasonCode,
            exitCode,
            action.ResultPath,
            ObservationPath: null,
            EvidencePath: null,
            Replayed: false);
    }

    public void Dispose()
    {
        if (Directory.Exists(Root))
        {
            Directory.Delete(Root, recursive: true);
        }
    }

    private static void WriteJson(string path, JsonObject document)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(
            path,
            document.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static void RequireTerminal(string state)
    {
        if (!RunnerStates.IsTerminal(state))
        {
            throw new InvalidOperationException($"Fixture result state is not terminal: {state}");
        }
    }
}

internal sealed class RecordingHostActionExecutor : IHostActionExecutor
{
    private readonly Func<RunnerInboxEntry, CancellationToken, Task<RunnerExecutionResult>> execute;

    public RecordingHostActionExecutor(
        Func<RunnerInboxEntry, CancellationToken, Task<RunnerExecutionResult>> execute)
    {
        this.execute = execute;
    }

    public int Calls { get; private set; }

    public Task<RunnerExecutionResult> ExecuteAsync(
        RunnerInboxEntry entry,
        CancellationToken cancellationToken)
    {
        Calls++;
        return execute(entry, cancellationToken);
    }
}

internal sealed class HostFixture : IDisposable
{
    public HostFixture()
    {
        Root = Path.Combine(Path.GetTempPath(), $"ctrlx-opcon-host-selftest-{Guid.NewGuid():N}");
        EngineeringRoot = Path.Combine(Root, "Engineering");
        Directory.CreateDirectory(EngineeringRoot);
        Paths = HostRuntimePaths.Create(EngineeringRoot, Path.Combine(Root, "Runtime"));
    }

    public string Root { get; }

    public string EngineeringRoot { get; }

    public HostRuntimePaths Paths { get; }

    public void Dispose()
    {
        if (Directory.Exists(Root))
        {
            Directory.Delete(Root, recursive: true);
        }
    }
}

internal sealed class RunningHostFixture : IAsyncDisposable
{
    private readonly HostFixture fixture = new();
    private Process? process;
    private Task<string>? stdoutTask;
    private Task<string>? stderrTask;

    public string EngineeringRoot => fixture.EngineeringRoot;

    public HostRuntimePaths Paths => fixture.Paths;

    public int ProcessId => process?.Id ?? throw new InvalidOperationException("Runner Host has not started.");

    public bool HasExited => process?.HasExited ?? true;

    public int ExitCode => process is { HasExited: true }
        ? process.ExitCode
        : throw new InvalidOperationException("Runner Host has not exited.");

    public async Task<HostStatusDocument> StartAsync()
    {
        if (process is not null)
        {
            throw new InvalidOperationException("Runner Host fixture was started more than once.");
        }

        process = HostCommand.StartProcess("run", EngineeringRoot, Paths.RuntimeRoot);
        stdoutTask = process.StandardOutput.ReadToEndAsync();
        stderrTask = process.StandardError.ReadToEndAsync();
        var deadline = DateTimeOffset.UtcNow + Program.CommandTimeout;
        var store = new HostStatusStore(Paths);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (process.HasExited)
            {
                var stdout = await stdoutTask.ConfigureAwait(false);
                var stderr = await stderrTask.ConfigureAwait(false);
                throw new InvalidOperationException(
                    $"Runner Host exited before publishing status. exit={process.ExitCode}; stdout={stdout}; stderr={stderr}");
            }

            var status = store.ReadLive();
            if (status is not null)
            {
                return status;
            }

            await Task.Delay(50).ConfigureAwait(false);
        }

        throw new TimeoutException("Runner Host did not publish live status in time.");
    }

    public async Task<HostStatusDocument> WaitForStateAsync(string expectedState, TimeSpan timeout)
    {
        if (process is null)
        {
            throw new InvalidOperationException("Runner Host has not started.");
        }

        var deadline = DateTimeOffset.UtcNow + timeout;
        var store = new HostStatusStore(Paths);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (process.HasExited)
            {
                var stdout = await (stdoutTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
                var stderr = await (stderrTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
                throw new InvalidOperationException(
                    $"Runner Host exited while waiting for {expectedState}. exit={process.ExitCode}; stdout={stdout}; stderr={stderr}");
            }

            var status = store.ReadLive();
            if (status?.State == expectedState)
            {
                return status;
            }

            await Task.Delay(50).ConfigureAwait(false);
        }

        throw new TimeoutException($"Runner Host did not enter {expectedState} in time.");
    }

    public async Task WaitForExitAsync(TimeSpan timeout)
    {
        if (process is null)
        {
            throw new InvalidOperationException("Runner Host has not started.");
        }

        using var cancellation = new CancellationTokenSource(timeout);
        await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
        _ = await (stdoutTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
        _ = await (stderrTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
    }

    public async Task TerminateUnexpectedlyAsync()
    {
        if (process is null || process.HasExited)
        {
            throw new InvalidOperationException("Runner Host is not available for abnormal-termination injection.");
        }

        // This is an isolated SelfTest child PID. Killing only this PID models a
        // power/process loss without invoking the Host's graceful stop path.
        process.Kill(entireProcessTree: false);
        await process.WaitForExitAsync().ConfigureAwait(false);
        _ = await (stdoutTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
        _ = await (stderrTask ?? Task.FromResult(string.Empty)).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (process is not null)
        {
            if (!process.HasExited)
            {
                try
                {
                    _ = await HostCommand.RunAsync(
                        "stop",
                        EngineeringRoot,
                        Paths.RuntimeRoot,
                        TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                }
                catch
                {
                    // Exact fixture PID cleanup below is the last-resort test cleanup.
                }
            }

            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: false);
                await process.WaitForExitAsync().ConfigureAwait(false);
            }

            if (stdoutTask is not null)
            {
                _ = await stdoutTask.ConfigureAwait(false);
            }

            if (stderrTask is not null)
            {
                _ = await stderrTask.ConfigureAwait(false);
            }

            process.Dispose();
        }

        fixture.Dispose();
    }
}

internal sealed record HostCommandResult(int ExitCode, string StandardOutput, string StandardError, JsonNode? Json);

internal static class HostCommand
{
    public static Process StartProcess(string command, string engineeringRoot, string runtimeRoot)
    {
        var hostAssembly = Path.Combine(AppContext.BaseDirectory, "vcrunner-host.dll");
        if (!File.Exists(hostAssembly))
        {
            throw new InvalidOperationException($"Runner Host assembly was not copied beside SelfTest: {hostAssembly}");
        }

        var info = new ProcessStartInfo
        {
            FileName = ResolveDotNetHost(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        info.ArgumentList.Add(hostAssembly);
        info.ArgumentList.Add(command);
        info.ArgumentList.Add("--engineering-root");
        info.ArgumentList.Add(engineeringRoot);
        info.ArgumentList.Add("--runtime-root");
        info.ArgumentList.Add(runtimeRoot);
        info.ArgumentList.Add("--json");
        info.Environment["CTRLX_OPCON_RUNNER_HOST_TEST_MODE"] = "1";
        info.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        return Process.Start(info)
            ?? throw new InvalidOperationException("Failed to start the isolated Runner Host process.");
    }

    public static async Task<HostCommandResult> RunAsync(
        string command,
        string engineeringRoot,
        string runtimeRoot,
        TimeSpan timeout)
    {
        using var process = StartProcess(command, engineeringRoot, runtimeRoot);
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: false);
                await process.WaitForExitAsync().ConfigureAwait(false);
            }

            throw new TimeoutException($"Runner Host command timed out: {command}");
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        JsonNode? json = null;
        if (!string.IsNullOrWhiteSpace(stdout))
        {
            try
            {
                json = JsonNode.Parse(stdout);
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException(
                    $"Runner Host {command} returned invalid JSON: {stdout}",
                    exception);
            }
        }

        return new HostCommandResult(process.ExitCode, stdout, stderr, json);
    }

    private static string ResolveDotNetHost()
    {
        var configured = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        return string.IsNullOrWhiteSpace(configured) ? "dotnet" : configured;
    }
}

internal sealed record EngineeringProcessIdentity(int ProcessId, string Name);

internal sealed class EngineeringProcessSnapshot
{
    private readonly IReadOnlyDictionary<int, EngineeringProcessIdentity> processes;

    private EngineeringProcessSnapshot(IReadOnlyDictionary<int, EngineeringProcessIdentity> processes)
    {
        this.processes = processes;
    }

    public static EngineeringProcessSnapshot Capture()
    {
        var captured = new Dictionary<int, EngineeringProcessIdentity>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (IsEngineeringTool(process.ProcessName))
                    {
                        captured[process.Id] = new EngineeringProcessIdentity(process.Id, process.ProcessName);
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    // A process that exits during an observation cannot be a new persistent child.
                }
            }
        }

        return new EngineeringProcessSnapshot(captured);
    }

    public IReadOnlyList<EngineeringProcessIdentity> AddedSince(EngineeringProcessSnapshot before) =>
        processes.Values
            .Where(process => !before.processes.ContainsKey(process.ProcessId))
            .OrderBy(process => process.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(process => process.ProcessId)
            .ToArray();

    private static bool IsEngineeringTool(string processName) =>
        processName.Equals("node", StringComparison.OrdinalIgnoreCase) ||
        processName.Equals("nodejs", StringComparison.OrdinalIgnoreCase) ||
        processName.Equals("vcrunner-broker", StringComparison.OrdinalIgnoreCase) ||
        processName.Equals("codesys-mcp-persistent", StringComparison.OrdinalIgnoreCase) ||
        processName.Contains("codesys", StringComparison.OrdinalIgnoreCase) ||
        (processName.Contains("ctrlx", StringComparison.OrdinalIgnoreCase) &&
            processName.Contains("engineering", StringComparison.OrdinalIgnoreCase));
}

internal static class HostRuntimePathExtensions
{
    public static HostStatusStore CreateStatusStore(this HostRuntimePaths paths) => new(paths);
}
