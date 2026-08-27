using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Core;

return await RunnerSelfTest.RunAsync().ConfigureAwait(false);

internal static class RunnerSelfTest
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static int assertionCount;

    public static async Task<int> RunAsync()
    {
        var repositoryRoot = FindRepositoryRoot();
        var temporaryRoot = Path.Combine(
            Path.GetTempPath(),
            "ctrlx-opcon-runner-p12-selftest-" + Guid.NewGuid().ToString("N"));

        try
        {
            Check(OperatingSystem.IsWindows(), "P1.2 Runner self-test requires Windows Named Pipes and Windows PowerShell.");
            using var fixture = new RunnerFixture(repositoryRoot, temporaryRoot);

            RunnerExecutionResult noSessionResult = null!;
            CountingBrokerClient noSessionBroker = null!;
            CapturingEvidenceSealer noSessionSealer = null!;
            await CaseAsync("01 NoSession produces sealed BLOCKED evidence", async () =>
            {
                var action = fixture.CreateAction("fixture-nosession", "inspect_and_build");
                noSessionBroker = new CountingBrokerClient(new NoSessionBrokerClient());
                noSessionSealer = new CapturingEvidenceSealer(
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));
                var executor = new RunnerExecutor(noSessionBroker, noSessionSealer);

                noSessionResult = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(noSessionBroker.Calls == 1, "NoSession Broker must be probed exactly once.");
                Check(
                    noSessionResult.State == RunnerStates.Blocked,
                    $"NoSession result must be BLOCKED (actual={noSessionResult.State}, reason={noSessionResult.ReasonCode}, sealer={noSessionSealer.LastError}).");
                Check(noSessionResult.ReasonCode == "BLOCKED_SESSION_UNAVAILABLE", "NoSession reason code changed.");
                Check(noSessionResult.ExitCode == RunnerExitCodes.Blocked, "NoSession exit code must be 40.");
                Check(!noSessionResult.Replayed, "First execution must not be marked replayed.");
                Check(noSessionResult.ObservationPath is not null && File.Exists(noSessionResult.ObservationPath), "Blocked observation was not written.");
                Check(noSessionResult.EvidencePath is not null && File.Exists(noSessionResult.EvidencePath), "Blocked evidence was not sealed.");

                var evidence = ReadObject(noSessionResult.EvidencePath!);
                Check(String(evidence, "actionId") == action.ActionId, "Evidence actionId is not bound to the action.");
                Check(String(evidence, "actionRequestSha256").Equals(action.Sha256, StringComparison.OrdinalIgnoreCase), "Evidence action SHA is not bound.");
                Check(!evidence.ContainsKey("session"), "Blocked evidence must not contain session.");
                var result = Object(evidence, "result");
                Check(String(result, "status") == "blocked", "Sealed evidence lost blocked status.");
                Check(String(result, "reasonCode") == "BLOCKED_SESSION_UNAVAILABLE", "Sealed evidence lost reason code.");
                Check(!result.ContainsKey("build"), "Blocked evidence must not contain build.");
                Check(!result.ContainsKey("acceptance"), "Blocked evidence must not contain acceptance.");
                Check(Array(result, "proposedChanges").Count == 0, "Blocked evidence proposedChanges must be empty.");
                Check(Array(result, "appliedChanges").Count == 0, "Blocked evidence appliedChanges must be empty.");
                var guardrails = Object(evidence, "guardrails");
                Check(!Boolean(guardrails, "onlineOperationsUsed"), "Evidence reported an online operation.");
                Check(!Boolean(guardrails, "pleOrMcpStarted"), "Evidence reported a PLE/MCP start.");
                Check(Boolean(guardrails, "projectLeaseReleased"), "Evidence did not prove lease release.");
            }).ConfigureAwait(false);

            await CaseAsync("02 Same immutable action replays without a second Broker call", async () =>
            {
                var action = fixture.GetAction("fixture-nosession");
                var executor = new RunnerExecutor(
                    noSessionBroker,
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));
                var replay = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(replay.Replayed, "Second execution must be marked replayed.");
                Check(replay.RunId == noSessionResult.RunId, "Replay changed runId.");
                Check(replay.ResultPath == noSessionResult.ResultPath, "Replay changed result path.");
                Check(replay.EvidencePath == noSessionResult.EvidencePath, "Replay changed evidence path.");
                Check(noSessionBroker.Calls == 1, "Replay invoked the Broker a second time.");
            }).ConfigureAwait(false);

            await CaseAsync("03 SHA, path and sensitive-field gates reject before Broker", async () =>
            {
                var action = fixture.GetAction("fixture-nosession");
                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(broker, sealer);

                await ExpectGateAsync(
                    () => executor.ExecuteAsync(new RunnerExecutionRequest(
                        fixture.EngineeringRoot,
                        action.Path,
                        new string('0', 64),
                        TimeSpan.Zero)),
                    "ACTION_HASH_MISMATCH").ConfigureAwait(false);
                Check(broker.Calls == 0, "Wrong SHA reached Broker.");
                Check(sealer.Calls == 0, "Wrong SHA reached evidence sealing.");

                var escapedPath = Path.Combine(fixture.EngineeringRoot, "escaped-action.json");
                File.Copy(action.Path, escapedPath);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(new RunnerExecutionRequest(
                        fixture.EngineeringRoot,
                        escapedPath,
                        RunnerHash.Sha256File(escapedPath),
                        TimeSpan.Zero)),
                    "PATH_ESCAPE").ConfigureAwait(false);
                Check(broker.Calls == 0, "Escaped path reached Broker.");

                var sensitive = (JsonObject)action.Document.DeepClone();
                sensitive["password"] = "must-never-pass";
                var sensitivePath = Path.Combine(
                    fixture.EngineeringRoot,
                    "data",
                    "operations",
                    "sensitive",
                    "actions",
                    "0001-inspect_and_build.json");
                WriteJson(sensitivePath, sensitive);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(new RunnerExecutionRequest(
                        fixture.EngineeringRoot,
                        sensitivePath,
                        RunnerHash.Sha256File(sensitivePath),
                        TimeSpan.Zero)),
                    "SENSITIVE_FIELD_REJECTED").ConfigureAwait(false);
                Check(broker.Calls == 0, "Sensitive action reached Broker.");
                Check(sealer.Calls == 0, "Rejected actions reached evidence sealing.");
            }).ConfigureAwait(false);

            await CaseAsync("04 Apply action fails closed before Broker", async () =>
            {
                var changeSet = new JsonArray
                {
                    new JsonObject
                    {
                        ["changeId"] = "fixture-change-0001",
                        ["authorization"] = "ai_owned",
                        ["targetPath"] = "Application/Fbs/Fixture",
                        ["writeMode"] = "full_object",
                        ["hookIds"] = new JsonArray(),
                        ["interfaceWrite"] = false,
                        ["expectedBefore"] = new JsonObject { ["sha256"] = new string('A', 64) },
                        ["desired"] = new JsonObject { ["sha256"] = new string('B', 64) },
                        ["requiresReadback"] = true
                    }
                };
                var action = fixture.CreateAction(
                    "fixture-apply",
                    "apply_change_set_and_build",
                    changeSet);
                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var executor = new RunnerExecutor(
                    broker,
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(result.State == RunnerStates.Blocked, "Apply action must be BLOCKED in P1.2 read-only scope.");
                Check(result.ReasonCode == "BLOCKED_UNSUPPORTED_ACTION", "Apply fail-closed reason changed.");
                Check(result.ExitCode == RunnerExitCodes.Blocked, "Unsupported apply must return exit 40.");
                Check(broker.Calls == 0, "Unsupported apply reached Broker.");
                Check(result.EvidencePath is not null && File.Exists(result.EvidencePath), "Unsupported apply did not produce sealed blocker evidence.");
            }).ConfigureAwait(false);

            await CaseAsync("05 Existing claim without result becomes UNKNOWN", async () =>
            {
                var action = fixture.CreateAction("fixture-interrupted", "inspect_and_build");
                var validated = new RunnerActionValidator().Validate(
                    fixture.EngineeringRoot,
                    action.Path,
                    action.Sha256);
                var store = RunnerRunStore.ForAction(validated);
                Check(store.TryCreateClaim("none"), "Fixture could not create the interrupted claim.");
                Check(!File.Exists(store.ResultPath), "Interrupted fixture unexpectedly has a result.");

                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(broker, sealer);
                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(result.State == RunnerStates.Unknown, "Interrupted claim must become UNKNOWN.");
                Check(result.ReasonCode == "INTERRUPTED_RUN_REVIEW_REQUIRED", "Interrupted claim reason changed.");
                Check(result.ExitCode == RunnerExitCodes.GateFailure, "Interrupted claim must return gate failure.");
                Check(result.ObservationPath is null, "Interrupted claim fabricated an observation.");
                Check(result.EvidencePath is null, "Interrupted claim fabricated evidence.");
                Check(broker.Calls == 0, "Interrupted claim reached Broker.");
                Check(sealer.Calls == 0, "Interrupted claim reached evidence sealing.");
            }).ConfigureAwait(false);

            await CaseAsync("06 Evidence tamper rejects verification and replay", async () =>
            {
                var action = fixture.GetAction("fixture-nosession");
                Check(noSessionResult.EvidencePath is not null, "Tamper fixture has no evidence path.");
                File.AppendAllText(noSessionResult.EvidencePath!, " ", new UTF8Encoding(false));
                var verification = RunnerRunStore.VerifyById(fixture.EngineeringRoot, noSessionResult.RunId);
                Check(!Boolean(verification, "valid"), "Tampered evidence verified successfully.");
                Check(Boolean(verification, "actionHashValid"), "Evidence tamper incorrectly invalidated the action hash.");
                Check(Boolean(verification, "observationHashValid"), "Evidence tamper incorrectly invalidated the observation hash.");
                Check(!Boolean(verification, "evidenceHashValid"), "Evidence tamper was not isolated to evidence hash.");

                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(broker, sealer);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(fixture.Request(action)),
                    "RUN_RESULT_INTEGRITY_INVALID").ConfigureAwait(false);
                Check(broker.Calls == 0, "Tampered replay reached Broker.");
                Check(sealer.Calls == 0, "Tampered replay reached evidence sealing.");
            }).ConfigureAwait(false);

            await CaseAsync("07 Forged DONE result cannot replay blocked artifacts", async () =>
            {
                var action = fixture.CreateAction("fixture-forged-done", "inspect_and_build");
                var initialBroker = new CountingBrokerClient(new NoSessionBrokerClient());
                var initialExecutor = new RunnerExecutor(
                    initialBroker,
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));
                var blocked = await initialExecutor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(blocked.State == RunnerStates.Blocked, "Forged-result fixture did not start from BLOCKED.");
                Check(initialBroker.Calls == 1, "Forged-result fixture did not probe NoSession exactly once.");

                var forged = ReadObject(blocked.ResultPath);
                forged["state"] = RunnerStates.Done;
                forged["reasonCode"] = "RUNNER_SUCCEEDED";
                forged["exitCode"] = RunnerExitCodes.Done;
                WriteJson(blocked.ResultPath, forged);

                var replayBroker = new CountingBrokerClient(new NoSessionBrokerClient());
                var replaySealer = new RecordingEvidenceSealer();
                var replayExecutor = new RunnerExecutor(replayBroker, replaySealer);
                await ExpectGateAsync(
                    () => replayExecutor.ExecuteAsync(fixture.Request(action)),
                    "RUN_RESULT_ARTIFACT_MISMATCH").ConfigureAwait(false);
                Check(replayBroker.Calls == 0, "Forged DONE replay reached Broker.");
                Check(replaySealer.Calls == 0, "Forged DONE replay reached evidence sealing.");
            }).ConfigureAwait(false);

            await CaseAsync("08 Operation currentAction SHA/path drift rejects before Broker", async () =>
            {
                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(broker, sealer);

                var shaAction = fixture.CreateAction("fixture-ledger-sha", "inspect_and_build");
                var shaOperationPath = Path.Combine(
                    Directory.GetParent(Path.GetDirectoryName(shaAction.Path)!)!.FullName,
                    "operation.json");
                var shaOperation = ReadObject(shaOperationPath);
                Object(shaOperation, "currentAction")["sha256"] = new string('0', 64);
                WriteJson(shaOperationPath, shaOperation);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(fixture.Request(shaAction)),
                    "OPERATION_LEDGER_INVALID").ConfigureAwait(false);
                Check(broker.Calls == 0, "Ledger SHA drift reached Broker.");
                Check(sealer.Calls == 0, "Ledger SHA drift reached evidence sealing.");

                var pathAction = fixture.CreateAction("fixture-ledger-path", "inspect_and_build");
                var pathOperationPath = Path.Combine(
                    Directory.GetParent(Path.GetDirectoryName(pathAction.Path)!)!.FullName,
                    "operation.json");
                var pathOperation = ReadObject(pathOperationPath);
                Object(pathOperation, "currentAction")["path"] = Path.Combine(
                    Path.GetDirectoryName(pathAction.Path)!,
                    "not-the-current-action.json");
                WriteJson(pathOperationPath, pathOperation);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(fixture.Request(pathAction)),
                    "OPERATION_LEDGER_INVALID").ConfigureAwait(false);
                Check(broker.Calls == 0, "Ledger path drift reached Broker.");
                Check(sealer.Calls == 0, "Ledger path drift reached evidence sealing.");
            }).ConfigureAwait(false);

            await CaseAsync("09 Named Pipe success binds the exact action request", async () =>
            {
                var action = fixture.CreateAction("fixture-pipe-success", "inspect_and_build");
                var pipeName = "ctrlx-opcon-selftest-" + Guid.NewGuid().ToString("N");
                var server = ServeOnceAsync(
                    pipeName,
                    request => BuildBrokerReply(action, request));
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        pipeName,
                        Environment.ProcessId,
                        TimeSpan.FromSeconds(5),
                        TimeSpan.FromSeconds(10)),
                    sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                var request = await server.ConfigureAwait(false);

                Check(
                    result.State == RunnerStates.Done,
                    $"Valid Named Pipe reply did not complete DONE (actual={result.State}, reason={result.ReasonCode}).");
                Check(result.ReasonCode == "RUNNER_SUCCEEDED", "Valid Named Pipe result reason changed.");
                Check(result.ExitCode == RunnerExitCodes.Done, "Valid Named Pipe result exit code changed.");
                Check(sealer.Calls == 1, "Named Pipe success was not sealed exactly once.");
                AssertBrokerRequestBound(request, action);
            }).ConfigureAwait(false);

            await CaseAsync("10 Named Pipe profile mismatch fails closed", async () =>
            {
                var action = fixture.CreateAction("fixture-pipe-profile", "inspect_and_build");
                var pipeName = "ctrlx-opcon-selftest-" + Guid.NewGuid().ToString("N");
                var server = ServeOnceAsync(
                    pipeName,
                    request => BuildBrokerReply(action, request, profileOverride: "ctrlX PLC wrong"));
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        pipeName,
                        Environment.ProcessId,
                        TimeSpan.FromSeconds(5),
                        TimeSpan.FromSeconds(10)),
                    sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                var request = await server.ConfigureAwait(false);
                Check(result.State == RunnerStates.Blocked, "Profile mismatch must be BLOCKED.");
                Check(result.ReasonCode == "BLOCKED_SESSION_PROFILE_MISMATCH", "Profile mismatch reason changed.");
                Check(result.ExitCode == RunnerExitCodes.Blocked, "Profile mismatch exit code changed.");
                Check(sealer.Calls == 1, "Profile mismatch blocker was not sealed.");
                AssertBrokerRequestBound(request, action);
            }).ConfigureAwait(false);

            await CaseAsync("11 Named Pipe project mismatch fails closed", async () =>
            {
                var action = fixture.CreateAction("fixture-pipe-project", "inspect_and_build");
                var wrongProject = Path.Combine(fixture.StationRoot, "Plc", "Wrong.project");
                var pipeName = "ctrlx-opcon-selftest-" + Guid.NewGuid().ToString("N");
                var server = ServeOnceAsync(
                    pipeName,
                    request => BuildBrokerReply(action, request, projectOverride: wrongProject));
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        pipeName,
                        Environment.ProcessId,
                        TimeSpan.FromSeconds(5),
                        TimeSpan.FromSeconds(10)),
                    sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                var request = await server.ConfigureAwait(false);
                Check(result.State == RunnerStates.Blocked, "Project mismatch must be BLOCKED.");
                Check(result.ReasonCode == "BLOCKED_SESSION_PROJECT_MISMATCH", "Project mismatch reason changed.");
                Check(result.ExitCode == RunnerExitCodes.Blocked, "Project mismatch exit code changed.");
                Check(sealer.Calls == 1, "Project mismatch blocker was not sealed.");
                AssertBrokerRequestBound(request, action);
            }).ConfigureAwait(false);

            await CaseAsync("12 Session lease cannot be bypassed by a transport alias", async () =>
            {
                var firstAction = fixture.CreateAction("fixture-lease-alias-a", "inspect_and_build");
                var secondAction = fixture.CreateAction("fixture-lease-alias-b", "inspect_and_build");
                var holdingBroker = new BlockingNoSessionBrokerClient("named-pipe:alias-a");
                var firstExecutor = new RunnerExecutor(holdingBroker, new RecordingEvidenceSealer());
                var firstRun = firstExecutor.ExecuteAsync(new RunnerExecutionRequest(
                    fixture.EngineeringRoot,
                    firstAction.Path,
                    firstAction.Sha256,
                    TimeSpan.FromSeconds(1)));

                await holdingBroker.WaitUntilEnteredAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                var secondBroker = new CountingBrokerClient(new NamedNoSessionBrokerClient("named-pipe:alias-b"));
                var secondExecutor = new RunnerExecutor(secondBroker, new RecordingEvidenceSealer());
                try
                {
                    await ExpectGateAsync(
                        () => secondExecutor.ExecuteAsync(new RunnerExecutionRequest(
                            fixture.EngineeringRoot,
                            secondAction.Path,
                            secondAction.Sha256,
                            TimeSpan.Zero)),
                        "RUNNER_BUSY").ConfigureAwait(false);
                    Check(secondBroker.Calls == 0, "Transport alias bypass reached the second Broker.");
                }
                finally
                {
                    holdingBroker.Release();
                }

                var firstResult = await firstRun.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
                Check(firstResult.State == RunnerStates.Blocked, "Holding fixture did not release as a blocked NoSession run.");
                Check(holdingBroker.Calls == 1, "Holding Broker was not invoked exactly once.");
            }).ConfigureAwait(false);

            await CaseAsync("13 Trusted evidence producer drift fails closed", async () =>
            {
                var action = fixture.CreateAction("fixture-producer-drift", "inspect_and_build");
                var producerPath = Path.Combine(
                    fixture.EngineeringRoot,
                    "scripts",
                    "cpstudio",
                    "New-PostExportRunnerEvidence.ps1");
                File.AppendAllText(
                    producerPath,
                    Environment.NewLine + "# fixture integrity drift" + Environment.NewLine,
                    new UTF8Encoding(false));

                var broker = new CountingBrokerClient(new NoSessionBrokerClient());
                var executor = new RunnerExecutor(
                    broker,
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));
                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(result.State == RunnerStates.Failed, "Producer drift must terminate FAILED.");
                Check(
                    result.ReasonCode == "EVIDENCE_PRODUCER_INTEGRITY_MISMATCH",
                    $"Producer drift reason changed: {result.ReasonCode}.");
                Check(result.ExitCode == RunnerExitCodes.GateFailure, "Producer drift must return gate failure 50.");
                Check(broker.Calls == 1, "Producer drift fixture did not reach the bounded NoSession probe exactly once.");
                Check(result.ObservationPath is not null && File.Exists(result.ObservationPath), "Producer drift lost its pre-seal observation.");
                Check(result.EvidencePath is null, "Producer drift fabricated evidence in the CLI result.");
                var stored = ReadObject(result.ResultPath);
                Check(stored.ContainsKey("evidencePath") && stored["evidencePath"] is null, "Producer drift result did not explicitly record null evidencePath.");
                Check(stored.ContainsKey("evidenceSha256") && stored["evidenceSha256"] is null, "Producer drift result did not explicitly record null evidenceSha256.");
                var expectedEvidencePath = Path.Combine(
                    fixture.EngineeringRoot,
                    "data",
                    "runner-evidence",
                    $"{action.ActionId}-{action.Sha256[..12].ToLowerInvariant()}.json");
                Check(!File.Exists(expectedEvidencePath), "Producer drift wrote an evidence artifact before failing integrity.");
            }).ConfigureAwait(false);

            await CaseAsync("14 CLI/Core source has no PLE/MCP or online command surface", () =>
            {
                AssertStaticSafety(repositoryRoot);
                return Task.CompletedTask;
            }).ConfigureAwait(false);

            Console.WriteLine($"PASS ALL: {assertionCount} assertions");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"FAIL after {assertionCount} assertions: {exception}");
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

    private static async Task CaseAsync(string name, Func<Task> body)
    {
        await body().ConfigureAwait(false);
        Console.WriteLine("PASS " + name);
    }

    private static void Check(bool condition, string message)
    {
        assertionCount++;
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static async Task ExpectGateAsync(Func<Task<RunnerExecutionResult>> operation, string reasonCode)
    {
        try
        {
            _ = await operation().ConfigureAwait(false);
            Check(false, $"Expected gate '{reasonCode}' was not raised.");
        }
        catch (RunnerGateException exception)
        {
            Check(exception.ReasonCode == reasonCode, $"Expected gate '{reasonCode}', got '{exception.ReasonCode}'.");
        }
    }

    private static async Task<JsonObject> ServeOnceAsync(
        string pipeName,
        Func<JsonObject, JsonObject> replyFactory)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous);
        await server.WaitForConnectionAsync(timeout.Token).ConfigureAwait(false);

        using var reader = new StreamReader(
            server,
            new UTF8Encoding(false, true),
            detectEncodingFromByteOrderMarks: false,
            bufferSize: 4096,
            leaveOpen: true);
        var line = await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(line) || JsonNode.Parse(line) is not JsonObject request)
        {
            throw new InvalidOperationException("Fake Broker received an invalid request.");
        }

        var reply = replyFactory(request);
        var bytes = new UTF8Encoding(false).GetBytes(
            reply.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) + "\n");
        await server.WriteAsync(bytes, timeout.Token).ConfigureAwait(false);
        await server.FlushAsync(timeout.Token).ConfigureAwait(false);
        return request;
    }

    private static JsonObject BuildBrokerReply(
        ActionFixture action,
        JsonObject request,
        string? profileOverride = null,
        string? projectOverride = null)
    {
        var profile = profileOverride ?? action.Profile;
        var project = projectOverride ?? action.PlcProject;
        var sessionId = "fixture-persistent-session";
        const int plePid = 4242;
        var buildStarted = DateTimeOffset.UtcNow;
        var buildCompleted = buildStarted.AddMilliseconds(10);
        var completed = buildCompleted.AddMilliseconds(10);
        var session = new JsonObject
        {
            ["protocolVersion"] = NamedPipeSessionBrokerClient.ProtocolVersion,
            ["brokerPid"] = Environment.ProcessId,
            ["sessionId"] = sessionId,
            ["plePid"] = plePid,
            ["profile"] = profile,
            ["activeProjectPath"] = project,
            ["state"] = "ready",
            ["startedByRunner"] = false
        };
        var observedSession = new JsonObject
        {
            ["state"] = "ready",
            ["mode"] = "persistent",
            ["sessionId"] = sessionId,
            ["plePid"] = plePid,
            ["profile"] = profile,
            ["activeProjectPath"] = project,
            ["startedByRunner"] = false
        };
        var observation = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = action.OperationId,
            ["actionId"] = action.ActionId,
            ["actionKind"] = action.ActionKind,
            ["actionRequestSha256"] = action.Sha256,
            ["status"] = "succeeded",
            ["completedAtUtc"] = completed.ToString("O"),
            ["capabilitiesInvoked"] = new JsonArray(
                "get_codesys_status",
                "compile_project",
                "get_compile_messages"),
            ["session"] = observedSession,
            ["guardrails"] = new JsonObject
            {
                ["onlineOperationsUsed"] = false,
                ["secondPleStarted"] = false,
                ["projectLeaseAcquired"] = true,
                ["projectLeaseReleased"] = true,
                ["projectLeaseScope"] = "workflow-local",
                ["symbolLeaseHeld"] = false,
                ["pleOrMcpStarted"] = false,
                ["directWatcherIpcUsed"] = false
            },
            ["result"] = new JsonObject
            {
                ["verificationOk"] = true,
                ["appliedReadbackOk"] = true,
                ["repairRequired"] = false,
                ["requiresSecondExport"] = false,
                ["requiresCpStudioChange"] = false,
                ["proposedChanges"] = new JsonArray(),
                ["appliedChanges"] = new JsonArray(),
                ["build"] = new JsonObject
                {
                    ["buildId"] = "fixture:pipe:build",
                    ["projectPath"] = action.PlcProject,
                    ["profile"] = action.Profile,
                    ["projectSha256"] = RunnerHash.Sha256File(action.PlcProject),
                    ["startedAtUtc"] = buildStarted.ToString("O"),
                    ["completedAtUtc"] = buildCompleted.ToString("O"),
                    ["verified"] = true,
                    ["errors"] = 0,
                    ["warnings"] = 0,
                    ["summarySource"] = "codesys-persistent.compile_project",
                    ["warningRecords"] = new JsonArray()
                },
                ["acceptance"] = new JsonObject
                {
                    ["ownershipVerified"] = true,
                    ["mappingConsistent"] = true,
                    ["readbackVerified"] = true,
                    ["recoverableBaselineVerified"] = true,
                    ["warningSignaturesReviewed"] = true,
                    ["existingSessionReused"] = true,
                    ["pleOrMcpStarted"] = false,
                    ["directWatcherIpcUsed"] = false,
                    ["symbolPostProcessingVerified"] = true
                }
            }
        };

        return new JsonObject
        {
            ["protocolVersion"] = NamedPipeSessionBrokerClient.ProtocolVersion,
            ["kind"] = "ctrlx-opcon-runner-broker-reply",
            ["requestId"] = String(request, "requestId"),
            ["available"] = true,
            ["reasonCode"] = "SESSION_AVAILABLE",
            ["session"] = session,
            ["observation"] = observation
        };
    }

    private static void AssertBrokerRequestBound(JsonObject request, ActionFixture action)
    {
        Check(Integer(request, "protocolVersion") == NamedPipeSessionBrokerClient.ProtocolVersion, "Broker protocolVersion changed.");
        Check(String(request, "kind") == "ctrlx-opcon-runner-broker-execute", "Broker request kind changed.");
        Check(String(request, "requestId") == action.ActionId, "Broker requestId is not action-bound.");
        var requestAction = Object(request, "action");
        Check(String(requestAction, "operationId") == action.OperationId, "Broker operationId is not bound.");
        Check(String(requestAction, "actionId") == action.ActionId, "Broker actionId is not bound.");
        Check(String(requestAction, "actionKind") == action.ActionKind, "Broker actionKind is not bound.");
        Check(Path.GetFullPath(String(requestAction, "actionRequestPath")) == action.Path, "Broker action path is not bound.");
        Check(String(requestAction, "actionRequestSha256").Equals(action.Sha256, StringComparison.OrdinalIgnoreCase), "Broker action SHA is not bound.");
        Check(String(requestAction, "idempotencyKey").Equals(action.IdempotencyKey, StringComparison.OrdinalIgnoreCase), "Broker idempotency key is not bound.");
        var project = Object(request, "project");
        Check(Path.GetFullPath(String(project, "engineeringRoot")) == action.EngineeringRoot, "Broker engineeringRoot is not bound.");
        Check(Path.GetFullPath(String(project, "stationRoot")) == action.StationRoot, "Broker stationRoot is not bound.");
        Check(Path.GetFullPath(String(project, "plcProject")) == action.PlcProject, "Broker PLC project is not bound.");
        Check(String(project, "profile") == action.Profile, "Broker profile is not bound.");
        var guardrails = Object(request, "guardrails");
        Check(Boolean(guardrails, "offlineOnly"), "Broker request is not offline-only.");
        Check(!Boolean(guardrails, "onlineOperationsAllowed"), "Broker request permits online operations.");
        Check(Boolean(guardrails, "requireExistingPersistentSession"), "Broker request does not require an existing session.");
        Check(Boolean(guardrails, "prohibitStartPleOrMcp"), "Broker request does not prohibit PLE/MCP start.");
        Check(Boolean(guardrails, "prohibitDirectWatcherIpc"), "Broker request does not prohibit watcher IPC.");
        Check(Boolean(guardrails, "requireExactProjectOpen"), "Broker request does not require the exact project.");
        Check(!Boolean(guardrails, "startedByRunnerAllowed"), "Broker request permits Runner-started session.");
    }

    private static void AssertStaticSafety(string repositoryRoot)
    {
        var sourceRoot = Path.Combine(repositoryRoot, "src", "runner");
        var sourceFiles = Directory.EnumerateFiles(sourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !HasSegment(path, "bin") && !HasSegment(path, "obj"))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        Check(sourceFiles.Length >= 8, "Runner source scan did not find the expected Core/CLI files.");
        var sources = sourceFiles.ToDictionary(
            path => path,
            File.ReadAllText,
            StringComparer.OrdinalIgnoreCase);
        var combined = string.Join("\n", sources.Values);

        foreach (var forbidden in new[]
        {
            "ctrlX-PLC-Engineering.exe",
            "CODESYS.exe",
            "codesys-mcp",
            "node.exe",
            "npm.cmd",
            "npx.cmd"
        })
        {
            Check(!combined.Contains(forbidden, StringComparison.OrdinalIgnoreCase), $"Runner source contains executable launch token '{forbidden}'.");
        }

        foreach (var forbiddenCapability in new[]
        {
            "connect_to_device",
            "download_to_device",
            "start_stop_application",
            "write_variable",
            "read_variable",
            "monitor_variables",
            "set_simulation_mode",
            "set_pou_code"
        })
        {
            Check(!combined.Contains(forbiddenCapability, StringComparison.OrdinalIgnoreCase), $"Runner source contains forbidden capability '{forbiddenCapability}'.");
        }

        foreach (var genericToolSurface in new[]
        {
            "--tool",
            "toolName",
            "call_tool",
            "tools/call",
            "invokeTool"
        })
        {
            Check(!combined.Contains(genericToolSurface, StringComparison.OrdinalIgnoreCase), $"Runner source contains generic tool surface '{genericToolSurface}'.");
        }

        var processStartCount = Regex.Matches(combined, "new\\s+ProcessStartInfo", RegexOptions.CultureInvariant).Count;
        Check(processStartCount == 1, "Runner must have exactly one allowlisted child-process boundary.");
        var sealerSource = sources.Single(item => Path.GetFileName(item.Key) == "PowerShellEvidenceSealer.cs").Value;
        Check(
            sealerSource.Contains("Environment.SpecialFolder.System", StringComparison.Ordinal) &&
            sealerSource.Contains("WindowsPowerShell", StringComparison.Ordinal) &&
            sealerSource.Contains("FileName = windowsPowerShell", StringComparison.Ordinal),
            "Runner child-process target is not the absolute Windows evidence producer host.");

        var pipeSourcePath = Path.Combine(
            sourceRoot,
            "CtrlX.OpCon.Runner.Core",
            "NamedPipeSessionBrokerClient.cs");
        var pipeSource = File.ReadAllText(pipeSourcePath);
        Check(!pipeSource.Contains("ProcessStartInfo", StringComparison.Ordinal), "Named Pipe client gained process-start capability.");
        Check(!pipeSource.Contains("Process.Start", StringComparison.Ordinal), "Named Pipe client gained process-start capability.");

        var selfTestProject = Path.Combine(
            repositoryRoot,
            "tests",
            "runner",
            "CtrlX.OpCon.Runner.SelfTest",
            "CtrlX.OpCon.Runner.SelfTest.csproj");
        Check(!File.ReadAllText(selfTestProject).Contains("PackageReference", StringComparison.OrdinalIgnoreCase), "Self-test gained a NuGet dependency.");
    }

    private static bool HasSegment(string path, string segment)
    {
        var separator = Path.DirectorySeparatorChar;
        return path.Contains(separator + segment + separator, StringComparison.OrdinalIgnoreCase);
    }

    private static string FindRepositoryRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var producer = Path.Combine(
                current.FullName,
                "templates",
                "ctrlx-opcon-project",
                "scripts",
                "cpstudio",
                "New-PostExportRunnerEvidence.ps1");
            if (File.Exists(producer) && Directory.Exists(Path.Combine(current.FullName, "src", "runner")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate the ctrlx-ai-coding repository root.");
    }

    private static JsonObject ReadObject(string path) =>
        JsonNode.Parse(File.ReadAllBytes(path)) as JsonObject
        ?? throw new InvalidOperationException("Expected a JSON object: " + path);

    private static void WriteJson(string path, JsonNode value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(
            path,
            value.ToJsonString(JsonOptions) + Environment.NewLine,
            new UTF8Encoding(false));
    }

    private static JsonObject Object(JsonObject value, string property) =>
        value[property] as JsonObject
        ?? throw new InvalidOperationException($"Expected object '{property}'.");

    private static JsonArray Array(JsonObject value, string property) =>
        value[property] as JsonArray
        ?? throw new InvalidOperationException($"Expected array '{property}'.");

    private static string String(JsonObject value, string property) =>
        value[property]?.GetValue<string>()
        ?? throw new InvalidOperationException($"Expected string '{property}'.");

    private static bool Boolean(JsonObject value, string property) =>
        value[property]?.GetValue<bool>()
        ?? throw new InvalidOperationException($"Expected Boolean '{property}'.");

    private static int Integer(JsonObject value, string property) =>
        value[property]?.GetValue<int>()
        ?? throw new InvalidOperationException($"Expected integer '{property}'.");
}

internal sealed class RunnerFixture : IDisposable
{
    private readonly Dictionary<string, ActionFixture> actions = new(StringComparer.Ordinal);
    private readonly string auditPath;

    public RunnerFixture(string repositoryRoot, string root)
    {
        Root = Path.GetFullPath(root);
        EngineeringRoot = Path.Combine(Root, "AI Sidecar");
        StationRoot = Path.Combine(Root, "Station Fixture");
        PlcProject = Path.Combine(StationRoot, "Plc", "Fixture PLC.project");
        Directory.CreateDirectory(EngineeringRoot);
        Directory.CreateDirectory(Path.Combine(StationRoot, "Engineering"));
        Directory.CreateDirectory(Path.GetDirectoryName(PlcProject)!);

        File.WriteAllText(
            Path.Combine(StationRoot, "Engineering", "Engineering_Data.xml"),
            "<fixture />",
            new UTF8Encoding(false));
        File.WriteAllBytes(PlcProject, new byte[] { 1, 3, 3, 7, 9 });

        foreach (var relative in new[]
        {
            Path.Combine("ai", "ownership.yaml"),
            Path.Combine("ai", "hooks.yaml"),
            Path.Combine("ai", "graphical.yaml")
        })
        {
            var path = Path.Combine(EngineeringRoot, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "fixture: true" + Environment.NewLine, new UTF8Encoding(false));
        }

        auditPath = Path.Combine(EngineeringRoot, "data", "reports", "cpstudio", "fixture.json");
        WriteJson(auditPath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["requestId"] = "fixture-request"
        });

        var producerSource = Path.Combine(
            repositoryRoot,
            "templates",
            "ctrlx-opcon-project",
            "scripts",
            "cpstudio",
            "New-PostExportRunnerEvidence.ps1");
        var producerTarget = Path.Combine(
            EngineeringRoot,
            "scripts",
            "cpstudio",
            "New-PostExportRunnerEvidence.ps1");
        Directory.CreateDirectory(Path.GetDirectoryName(producerTarget)!);
        File.Copy(producerSource, producerTarget);
    }

    public string Root { get; }

    public string EngineeringRoot { get; }

    public string StationRoot { get; }

    public string PlcProject { get; }

    public ActionFixture CreateAction(
        string operationId,
        string actionKind,
        JsonArray? changeSet = null)
    {
        const int sequence = 1;
        var actionId = $"{operationId}-{sequence:0000}";
        var action = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-runner-request",
            ["operationId"] = operationId,
            ["actionId"] = actionId,
            ["actionKind"] = actionKind,
            ["sequence"] = sequence,
            ["createdAtUtc"] = DateTimeOffset.UtcNow.AddMinutes(-1).ToString("O"),
            ["status"] = "WAITING_FOR_RUNNER",
            ["source"] = new JsonObject
            {
                ["stage1RequestId"] = "fixture-request",
                ["auditReport"] = auditPath,
                ["auditReportSha256"] = RunnerHash.Sha256File(auditPath),
                ["export2Audit"] = null
            },
            ["project"] = new JsonObject
            {
                ["engineeringRoot"] = EngineeringRoot,
                ["stationRoot"] = StationRoot,
                ["plcProject"] = PlcProject,
                ["profile"] = "ctrlX PLC 2.6.8"
            },
            ["preconditions"] = new JsonObject
            {
                ["workflowRevision"] = "ctrlx-opcon-post-export-stage2-v1",
                ["idempotencyKey"] = RunnerHash.Sha256Text(operationId + "|fixture"),
                ["manifests"] = new JsonArray(
                    Fingerprint(EngineeringRoot, Path.Combine("ai", "ownership.yaml")),
                    Fingerprint(EngineeringRoot, Path.Combine("ai", "hooks.yaml")),
                    Fingerprint(EngineeringRoot, Path.Combine("ai", "graphical.yaml"))),
                ["fingerprints"] = new JsonArray(
                    Fingerprint(StationRoot, Path.Combine("Engineering", "Engineering_Data.xml")),
                    Fingerprint(StationRoot, Path.Combine("Plc", "Fixture PLC.project")),
                    Fingerprint(StationRoot, Path.Combine("Hmi", "missing.cache")))
            },
            ["guardrails"] = new JsonObject
            {
                ["offlineOnly"] = true,
                ["onlineOperationsAllowed"] = false,
                ["requireExistingPersistentSession"] = true,
                ["prohibitStartPleOrMcp"] = true,
                ["prohibitDirectWatcherIpc"] = true,
                ["requireExactProjectOpen"] = true,
                ["projectLeaseRequired"] = true,
                ["releaseLeaseAfterAction"] = true,
                ["symbolAccessSerialized"] = true,
                ["coordinationScope"] = "workflow-local-until-runner-lease"
            },
            ["changeSet"] = changeSet ?? new JsonArray(),
            ["instructions"] = new JsonArray("fixture"),
            ["evidenceContract"] = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["requireActionRequestSha256"] = true,
                ["requireOfflineOnly"] = true,
                ["requireProjectLeaseReleased"] = true,
                ["requireReadbackOnSuccess"] = true,
                ["requireFreshBuildOnSuccess"] = true,
                ["terminalFailureMayOmitBuild"] = true,
                ["warningComparison"] = "signature-multiset-not-count-only"
            }
        };
        var path = Path.Combine(
            EngineeringRoot,
            "data",
            "operations",
            operationId,
            "actions",
            $"{sequence:0000}-{actionKind}.json");
        WriteJson(path, action);
        var actionSha256 = RunnerHash.Sha256File(path);
        var operationDirectory = Directory.GetParent(Path.GetDirectoryName(path)!)!.FullName;
        WriteJson(Path.Combine(operationDirectory, "operation.json"), new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-post-export-operation",
            ["workflowRevision"] = String(Object(action, "preconditions"), "workflowRevision"),
            ["operationId"] = operationId,
            ["status"] = "WAITING_FOR_RUNNER",
            ["idempotency"] = new JsonObject
            {
                ["key"] = String(Object(action, "preconditions"), "idempotencyKey"),
                ["algorithm"] = "SHA256"
            },
            ["identity"] = new JsonObject
            {
                ["engineeringRoot"] = EngineeringRoot,
                ["stationRoot"] = StationRoot,
                ["plcProject"] = PlcProject,
                ["profile"] = "ctrlX PLC 2.6.8"
            },
            ["currentAction"] = new JsonObject
            {
                ["actionId"] = actionId,
                ["kind"] = actionKind,
                ["sequence"] = sequence,
                ["createdAtUtc"] = String(action, "createdAtUtc"),
                ["path"] = path,
                ["sha256"] = actionSha256
            }
        });
        var fixture = new ActionFixture(
            EngineeringRoot,
            StationRoot,
            PlcProject,
            "ctrlX PLC 2.6.8",
            operationId,
            actionId,
            actionKind,
            String(Object(action, "preconditions"), "idempotencyKey"),
            path,
            actionSha256,
            action);
        actions.Add(operationId, fixture);
        return fixture;
    }

    public ActionFixture GetAction(string operationId) => actions[operationId];

    public RunnerExecutionRequest Request(ActionFixture action) => new(
        EngineeringRoot,
        action.Path,
        action.Sha256,
        TimeSpan.FromSeconds(1));

    public void Dispose()
    {
        // The outer harness owns and removes Root after every stream/process is disposed.
    }

    private static JsonObject Fingerprint(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath);
        var exists = File.Exists(path);
        var file = exists ? new FileInfo(path) : null;
        return new JsonObject
        {
            ["path"] = relativePath.Replace('\\', '/'),
            ["exists"] = exists,
            ["sizeBytes"] = file is null ? null : JsonValue.Create(file.Length),
            ["lastWriteTimeUtc"] = file is null ? null : JsonValue.Create(file.LastWriteTimeUtc.ToString("O")),
            ["sha256"] = exists ? RunnerHash.Sha256File(path) : null
        };
    }

    private static JsonObject Object(JsonObject value, string property) =>
        value[property] as JsonObject
        ?? throw new InvalidOperationException($"Expected object '{property}'.");

    private static string String(JsonObject value, string property) =>
        value[property]?.GetValue<string>()
        ?? throw new InvalidOperationException($"Expected string '{property}'.");

    private static void WriteJson(string path, JsonNode value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(
            path,
            value.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine,
            new UTF8Encoding(false));
    }
}

internal sealed record ActionFixture(
    string EngineeringRoot,
    string StationRoot,
    string PlcProject,
    string Profile,
    string OperationId,
    string ActionId,
    string ActionKind,
    string IdempotencyKey,
    string Path,
    string Sha256,
    JsonObject Document);

internal sealed class CountingBrokerClient : ISessionBrokerClient
{
    private readonly ISessionBrokerClient inner;

    public CountingBrokerClient(ISessionBrokerClient inner)
    {
        this.inner = inner;
    }

    public int Calls { get; private set; }

    public string TransportName => inner.TransportName;

    public Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        Calls++;
        return inner.ExecuteAsync(action, cancellationToken);
    }
}

internal sealed class NamedNoSessionBrokerClient : ISessionBrokerClient
{
    public NamedNoSessionBrokerClient(string transportName)
    {
        TransportName = transportName;
    }

    public string TransportName { get; }

    public Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new BrokerExecutionReply(
            Available: false,
            ReasonCode: "BLOCKED_SESSION_UNAVAILABLE",
            Session: null,
            Observation: null));
    }
}

internal sealed class BlockingNoSessionBrokerClient : ISessionBrokerClient
{
    private readonly TaskCompletionSource entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource released = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public BlockingNoSessionBrokerClient(string transportName)
    {
        TransportName = transportName;
    }

    public int Calls { get; private set; }

    public string TransportName { get; }

    public async Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        Calls++;
        entered.TrySetResult();
        await released.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        return new BrokerExecutionReply(
            Available: false,
            ReasonCode: "BLOCKED_SESSION_UNAVAILABLE",
            Session: null,
            Observation: null);
    }

    public Task WaitUntilEnteredAsync(TimeSpan timeout) => entered.Task.WaitAsync(timeout);

    public void Release() => released.TrySetResult();
}

internal sealed class RecordingEvidenceSealer : IEvidenceSealer
{
    public int Calls { get; private set; }

    public Task<EvidenceSealResult> SealAsync(
        ValidatedRunnerAction action,
        string observationPath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls++;
        var root = Path.Combine(action.EngineeringRoot, "data", "runner-evidence");
        Directory.CreateDirectory(root);
        var output = Path.Combine(root, $"recorded-{action.ActionId}-{action.ActionSha256[..12].ToLowerInvariant()}.json");
        File.Copy(observationPath, output, overwrite: false);
        return Task.FromResult(new EvidenceSealResult(
            output,
            RunnerHash.Sha256File(output),
            "WRITTEN"));
    }
}

internal sealed class CapturingEvidenceSealer : IEvidenceSealer
{
    private readonly IEvidenceSealer inner;

    public CapturingEvidenceSealer(IEvidenceSealer inner)
    {
        this.inner = inner;
    }

    public string? LastError { get; private set; }

    public async Task<EvidenceSealResult> SealAsync(
        ValidatedRunnerAction action,
        string observationPath,
        CancellationToken cancellationToken)
    {
        try
        {
            return await inner.SealAsync(action, observationPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            throw;
        }
    }
}
