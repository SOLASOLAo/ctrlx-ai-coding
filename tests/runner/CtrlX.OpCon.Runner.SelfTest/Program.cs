using System.IO.Pipes;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Core;
using CtrlX.OpCon.Runner.Broker.Infrastructure;

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
            Check(OperatingSystem.IsWindows(), "P1.2 Runner self-test requires Windows Named Pipes and PowerShell 7.");
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
                Check(!Boolean(guardrails, "pleOrMcpStartedByAction"), "Evidence reported a PLE/MCP start by this action.");
                Check(!Boolean(guardrails, "actionProjectGateAcquired"), "NoSession evidence claimed an action project gate.");
                Check(Boolean(guardrails, "actionProjectGateReleased"), "NoSession evidence did not prove a vacuous gate release.");
                Check(String(guardrails, "actionProjectGateKind") == "none", "NoSession evidence claimed an action project gate kind.");
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

                var legacy = fixture.CreateAction("fixture-legacy-action-schema", "inspect_and_build");
                var legacyDocument = ReadObject(legacy.Path);
                var legacyGuardrails = Object(legacyDocument, "guardrails");
                legacyGuardrails.Remove("prohibitPleOrMcpStartByAction");
                legacyGuardrails.Remove("actionProjectGateRequired");
                legacyGuardrails.Remove("releaseActionProjectGateBeforeTerminalDelivery");
                legacyGuardrails.Remove("actionProjectGateKind");
                legacyGuardrails["prohibitStartPleOrMcp"] = true;
                legacyGuardrails["projectLeaseRequired"] = true;
                legacyGuardrails["releaseLeaseAfterAction"] = true;
                legacyGuardrails["coordinationScope"] = "workflow-local-until-runner-lease";
                WriteJson(legacy.Path, legacyDocument);
                var legacySha = RunnerHash.Sha256File(legacy.Path);
                var legacyOperationPath = Path.Combine(
                    Directory.GetParent(Path.GetDirectoryName(legacy.Path)!)!.FullName,
                    "operation.json");
                var legacyOperation = ReadObject(legacyOperationPath);
                Object(legacyOperation, "currentAction")["sha256"] = legacySha;
                WriteJson(legacyOperationPath, legacyOperation);
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(new RunnerExecutionRequest(
                        fixture.EngineeringRoot,
                        legacy.Path,
                        legacySha,
                        TimeSpan.Zero)),
                    "ACTION_SCHEMA_INVALID").ConfigureAwait(false);
                Check(broker.Calls == 0, "Legacy P1.1 action guardrails reached Broker.");
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

            await CaseAsync("05 Existing claim remains pending and resumes through Broker", async () =>
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
                await ExpectGateAsync(
                    () => executor.ExecuteAsync(fixture.Request(action)),
                    "BROKER_RECOVERY_PENDING").ConfigureAwait(false);

                Check(broker.Calls == 1, "Interrupted claim was not resumed through Broker exactly once.");
                Check(sealer.Calls == 0, "Pending recovery reached evidence sealing.");
                Check(!File.Exists(store.ResultPath), "Pending recovery fabricated a terminal result.");
                Check(!File.Exists(store.ObservationPath), "Pending recovery fabricated an observation.");
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

            await CaseAsync("09 Missing Broker registration fails closed before Pipe connect", async () =>
            {
                var action = fixture.CreateAction("fixture-registration-missing", "inspect_and_build");
                fixture.CleanBrokerRuntime();
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        fixture.EngineeringRoot,
                        null,
                        TimeSpan.FromMilliseconds(100),
                        TimeSpan.FromMilliseconds(250)),
                    sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(result.State == RunnerStates.Blocked, "Missing registration must be BLOCKED.");
                Check(result.ReasonCode == "BLOCKED_BROKER_REGISTRATION_INVALID", "Missing registration reason changed.");
                Check(sealer.Calls == 1, "Missing-registration blocker was not sealed.");
            }).ConfigureAwait(false);

            await CaseAsync("10 Malicious registration is rejected before Pipe connect", async () =>
            {
                var action = fixture.CreateAction("fixture-registration-malicious", "inspect_and_build");
                var paths = fixture.CleanBrokerRuntime();
                var store = new BrokerRegistrationStore(paths);
                store.Publish(
                    "fixture-broker",
                    "fixture-pipe-" + Guid.NewGuid().ToString("N"),
                    Environment.ProcessId,
                    Environment.ProcessId,
                    "fixture-session",
                    BrokerRegistrationStates.Ready,
                    TimeSpan.FromSeconds(20));
                var malicious = ReadObject(paths.RegistrationPath);
                malicious["unexpectedCommand"] = "start_mcp";
                WriteJson(paths.RegistrationPath, malicious);

                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        fixture.EngineeringRoot,
                        null,
                        TimeSpan.FromMilliseconds(100),
                        TimeSpan.FromMilliseconds(250)),
                    sealer);
                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(result.State == RunnerStates.Blocked, "Malicious registration must be BLOCKED.");
                Check(result.ReasonCode == "ACTION_SCHEMA_INVALID", "Malicious registration rejection reason changed.");
                Check(sealer.Calls == 1, "Malicious-registration blocker was not sealed.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("11 Validated registration with missing Pipe fails closed", async () =>
            {
                var action = fixture.CreateAction("fixture-pipe-missing", "inspect_and_build");
                var paths = fixture.CleanBrokerRuntime();
                var store = new BrokerRegistrationStore(paths);
                store.Publish(
                    "fixture-broker",
                    "fixture-missing-" + Guid.NewGuid().ToString("N"),
                    Environment.ProcessId,
                    Environment.ProcessId,
                    "fixture-session",
                    BrokerRegistrationStates.Ready,
                    TimeSpan.FromSeconds(20));

                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        fixture.EngineeringRoot,
                        null,
                        TimeSpan.FromMilliseconds(100),
                        TimeSpan.FromMilliseconds(250)),
                    sealer);
                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);

                Check(result.State == RunnerStates.Blocked, "Missing Pipe must be BLOCKED.");
                Check(result.ReasonCode == "BLOCKED_SESSION_UNAVAILABLE", "Missing Pipe reason changed.");
                Check(sealer.Calls == 1, "Missing-Pipe blocker was not sealed.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("12 Broker serialization replaces Runner session-client lease", async () =>
            {
                var firstAction = fixture.CreateAction("fixture-serialized-a", "inspect_and_build");
                var secondAction = fixture.CreateAction("fixture-serialized-b", "inspect_and_build");
                var broker = new SerializingNoSessionBrokerClient();
                var firstExecutor = new RunnerExecutor(broker, new RecordingEvidenceSealer());
                var secondExecutor = new RunnerExecutor(broker, new RecordingEvidenceSealer());

                var firstRun = firstExecutor.ExecuteAsync(fixture.Request(firstAction));
                var secondRun = secondExecutor.ExecuteAsync(fixture.Request(secondAction));
                var results = await Task.WhenAll(firstRun, secondRun).ConfigureAwait(false);

                Check(results.All(item => item.State == RunnerStates.Blocked), "Serialized fixture did not complete both actions.");
                Check(broker.Calls == 2, "Runner-side alias/session lease suppressed a distinct action.");
                Check(broker.MaximumConcurrent == 1, "Broker did not serialize concurrent engineering actions.");
            }).ConfigureAwait(false);

            await CaseAsync("13 Accepted operation stays pending then replays one terminal result", async () =>
            {
                var action = fixture.CreateAction("fixture-pending-replay", "inspect_and_build");
                var broker = new SequenceBrokerClient(
                    PendingBrokerReply(action, "exec-fixture-pending"),
                    SuccessfulBrokerReply(action));
                var sealer = new CountingEvidenceSealer(
                    new PowerShellEvidenceSealer(TimeSpan.FromSeconds(30)));
                var executor = new RunnerExecutor(broker, sealer);
                var validated = new RunnerActionValidator().Validate(
                    fixture.EngineeringRoot,
                    action.Path,
                    action.Sha256);
                var runStore = RunnerRunStore.ForAction(validated);

                await ExpectGateAsync(
                    () => executor.ExecuteAsync(fixture.Request(action)),
                    "BROKER_OPERATION_PENDING").ConfigureAwait(false);
                Check(File.Exists(runStore.ClaimPath), "Accepted pending action lost its immutable claim.");
                Check(!File.Exists(runStore.ResultPath), "Accepted pending action was sealed as terminal.");
                Check(!File.Exists(runStore.ObservationPath), "Accepted pending action fabricated an observation.");
                Check(sealer.Calls == 0, "Accepted pending action reached evidence sealing.");

                var completed = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(completed.State == RunnerStates.Done, "Idempotent recovery did not complete DONE.");
                Check(broker.Calls == 2, "Pending recovery did not query the same Broker operation exactly once more.");
                Check(sealer.Calls == 1, "Recovered terminal observation was not sealed exactly once.");

                var replay = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(replay.Replayed, "Completed idempotent action did not replay locally.");
                Check(broker.Calls == 2, "Completed replay dispatched a duplicate Broker action.");
            }).ConfigureAwait(false);

            await CaseAsync("14 Protocol v2 Pipe timeout preserves accepted operation as pending", async () =>
            {
                var action = fixture.CreateAction("fixture-v2-pipe-pending", "inspect_and_build");
                var paths = fixture.CleanBrokerRuntime();
                var brokerInstanceId = "fixture-v2-broker";
                var pipeName = "fixture-v2-" + Guid.NewGuid().ToString("N");
                var executionId = BrokerOperationStore.ExecutionIdFor(action.ActionId);
                var registrationStore = new BrokerRegistrationStore(paths);
                registrationStore.Publish(
                    brokerInstanceId,
                    pipeName,
                    Environment.ProcessId,
                    Environment.ProcessId,
                    "fixture-v2-session",
                    BrokerRegistrationStates.Ready,
                    TimeSpan.FromSeconds(20));
                using var serverCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                var serverReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var queryReceived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var server = ServeNonterminalV2Async(
                    pipeName,
                    brokerInstanceId,
                    executionId,
                    serverReady,
                    serverCancellation.Token,
                    nonterminalQueryReceived: queryReceived);
                await serverReady.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        fixture.EngineeringRoot,
                        null,
                        TimeSpan.FromSeconds(2),
                        TimeSpan.FromSeconds(3),
                        TimeSpan.FromMilliseconds(40)),
                    sealer);
                var validated = new RunnerActionValidator().Validate(
                    fixture.EngineeringRoot,
                    action.Path,
                    action.Sha256);
                var runStore = RunnerRunStore.ForAction(validated);

                var execution = executor.ExecuteAsync(fixture.Request(action));
                await queryReceived.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                await ExpectGateAsync(
                    () => execution,
                    "BROKER_OPERATION_PENDING").ConfigureAwait(false);
                serverCancellation.Cancel();
                var requests = await server.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

                Check(requests.Count == 2, "Protocol v2 fixture did not receive exactly one submit and one bounded query.");
                Check(requests.Count(item => String(item, "kind") == BrokerWireProtocol.SubmitKind) == 1, "Protocol v2 action was submitted more than once.");
                Check(requests.Any(item => String(item, "kind") == BrokerWireProtocol.QueryKind), "Protocol v2 client did not query accepted operation state.");
                Check(File.Exists(runStore.ClaimPath), "Protocol v2 timeout lost the immutable claim.");
                Check(!File.Exists(runStore.ObservationPath), "Protocol v2 timeout fabricated an observation.");
                Check(!File.Exists(runStore.ResultPath), "Protocol v2 timeout was sealed as terminal failure.");
                Check(sealer.Calls == 0, "Protocol v2 timeout reached evidence sealing.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("15 Client cancellation after claim leaves operation recoverable", async () =>
            {
                var action = fixture.CreateAction("fixture-client-detach", "inspect_and_build");
                var blocking = new BlockingCancelableBrokerClient();
                var executor = new RunnerExecutor(blocking, new RecordingEvidenceSealer());
                using var cancellation = new CancellationTokenSource();
                var run = executor.ExecuteAsync(fixture.Request(action), cancellation.Token);
                await blocking.WaitUntilEnteredAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                cancellation.Cancel();
                await ExpectCanceledAsync(run).ConfigureAwait(false);

                var validated = new RunnerActionValidator().Validate(
                    fixture.EngineeringRoot,
                    action.Path,
                    action.Sha256);
                var runStore = RunnerRunStore.ForAction(validated);
                Check(File.Exists(runStore.ClaimPath), "Canceled client lost its recovery claim.");
                Check(!File.Exists(runStore.ResultPath), "Canceled client was incorrectly sealed FAILED/UNKNOWN.");
                Check(!File.Exists(runStore.ObservationPath), "Canceled client fabricated an observation.");

                var recoveryBroker = new CountingBrokerClient(new FixedBrokerClient(SuccessfulBrokerReply(action)));
                var recovery = await new RunnerExecutor(recoveryBroker, new RecordingEvidenceSealer())
                    .ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(recovery.State == RunnerStates.Done, "Canceled-client recovery did not reach terminal success.");
                Check(recoveryBroker.Calls == 1, "Canceled-client recovery did not use one idempotent Broker query.");
            }).ConfigureAwait(false);

            await CaseAsync("15a Protocol v2 terminal review is not reduced to pending", async () =>
            {
                var action = fixture.CreateAction("fixture-v2-terminal-review", "inspect_and_build");
                var paths = fixture.CleanBrokerRuntime();
                var brokerInstanceId = "fixture-v2-review-broker";
                var pipeName = "fixture-v2-review-" + Guid.NewGuid().ToString("N");
                var executionId = BrokerOperationStore.ExecutionIdFor(action.ActionId);
                new BrokerRegistrationStore(paths).Publish(
                    brokerInstanceId,
                    pipeName,
                    Environment.ProcessId,
                    Environment.ProcessId,
                    "fixture-v2-review-session",
                    BrokerRegistrationStates.Ready,
                    TimeSpan.FromSeconds(20));
                using var serverCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var serverReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var server = ServeNonterminalV2Async(
                    pipeName,
                    brokerInstanceId,
                    executionId,
                    serverReady,
                    serverCancellation.Token,
                    terminalReviewReason: "BROKER_CRASH_DURING_ENGINEERING_CALL");
                await serverReady.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(
                    new NamedPipeSessionBrokerClient(
                        fixture.EngineeringRoot,
                        null,
                        TimeSpan.FromSeconds(2),
                        TimeSpan.FromSeconds(3),
                        TimeSpan.FromMilliseconds(40)),
                    sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                var requests = await server.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                Check(result.State == RunnerStates.Unknown, "Protocol v2 terminal review was reduced to pending.");
                Check(result.ReasonCode == "BROKER_CRASH_DURING_ENGINEERING_CALL", "Protocol v2 review reason changed.");
                Check(result.ObservationPath is null && result.EvidencePath is null && sealer.Calls == 0,
                    "Protocol v2 review fabricated terminal evidence.");
                Check(requests.Count(item => String(item, "kind") == BrokerWireProtocol.SubmitKind) == 1,
                    "Protocol v2 review submitted the immutable action more than once.");
                Check(requests.Count(item => String(item, "kind") == BrokerWireProtocol.QueryKind) == 1,
                    "Protocol v2 review did not terminate after the authoritative query.");

                var replay = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(replay.Replayed, "Protocol v2 UNKNOWN was not replayed locally.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("15b Terminal Broker review becomes local UNKNOWN without replay", async () =>
            {
                var action = fixture.CreateAction("fixture-terminal-review", "inspect_and_build");
                var broker = new CountingBrokerClient(new FixedBrokerClient(new BrokerExecutionReply(
                    Available: true,
                    ReasonCode: "BROKER_CRASH_DURING_ENGINEERING_CALL",
                    Session: null,
                    Observation: null)
                {
                    Accepted = true,
                    Terminal = true,
                    ReviewRequired = true,
                    ExecutionId = "exec-fixture-terminal-review"
                }));
                var sealer = new RecordingEvidenceSealer();
                var executor = new RunnerExecutor(broker, sealer);

                var result = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(result.State == RunnerStates.Unknown, "Terminal Broker review was not sealed UNKNOWN.");
                Check(result.ReasonCode == "BROKER_CRASH_DURING_ENGINEERING_CALL", "Terminal review reason changed.");
                Check(result.ObservationPath is null && result.EvidencePath is null,
                    "Terminal review fabricated observation or evidence.");
                Check(sealer.Calls == 0, "Terminal review reached evidence sealing.");

                var replay = await executor.ExecuteAsync(fixture.Request(action)).ConfigureAwait(false);
                Check(replay.Replayed, "Terminal review did not replay its local UNKNOWN result.");
                Check(broker.Calls == 1, "Terminal review submitted or queried engineering work twice.");
            }).ConfigureAwait(false);

            await CaseAsync("16 Durable Broker store is idempotent and concurrent-safe", async () =>
            {
                var paths = fixture.CleanBrokerRuntime();
                var store = new BrokerOperationStore(paths, TimeSpan.FromSeconds(2));
                var action = fixture.GetAction("fixture-pending-replay");
                var identity = OperationIdentity(action);
                var first = store.Accept(identity, "broker-a");
                var replay = store.Accept(identity, "broker-a");
                Check(first.Disposition == BrokerOperationDisposition.Accepted, "First Broker accept was not new.");
                Check(replay.Disposition == BrokerOperationDisposition.Replayed, "Duplicate Broker accept was not replayed.");
                Check(first.Operation.ExecutionId == replay.Operation.ExecutionId, "Duplicate accept changed executionId.");

                var conflicting = identity with { ActionSha256 = new string('F', 64) };
                ExpectInfrastructure(
                    () => store.Accept(conflicting, "broker-a"),
                    "BROKER_OPERATION_IDEMPOTENCY_CONFLICT");

                var concurrentAction = fixture.GetAction("fixture-client-detach");
                var concurrentIdentity = OperationIdentity(concurrentAction);
                var accepts = await Task.WhenAll(
                    Enumerable.Range(0, 8)
                        .Select(_ => Task.Run(() => store.Accept(concurrentIdentity, "broker-a"))))
                    .ConfigureAwait(false);
                Check(accepts.Count(item => item.Disposition == BrokerOperationDisposition.Accepted) == 1, "Concurrent accept created more than one operation.");
                Check(accepts.Count(item => item.Disposition == BrokerOperationDisposition.Replayed) == 7, "Concurrent duplicate requests were not all replayed.");
                Check(accepts.Select(item => item.Operation.ExecutionId).Distinct(StringComparer.Ordinal).Count() == 1, "Concurrent duplicates changed executionId.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("16a Atomic Broker state tolerates a bounded transient Windows file lock", async () =>
            {
                var paths = fixture.CleanBrokerRuntime();
                var statePath = Path.Combine(paths.IdentityRoot, "atomic-retry-fixture.json");
                BrokerAtomicJson.Write(statePath, new { Revision = 1 }, overwrite: true);

                var destinationLock = new FileStream(
                    statePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read);
                var releaseLock = Task.Run(async () =>
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(60)).ConfigureAwait(false);
                    destinationLock.Dispose();
                });

                try
                {
                    BrokerAtomicJson.Write(statePath, new { Revision = 2 }, overwrite: true);
                }
                finally
                {
                    await releaseLock.ConfigureAwait(false);
                    destinationLock.Dispose();
                }

                var updated = ReadObject(statePath);
                Check(updated["revision"]?.GetValue<int>() == 2,
                    "Atomic Broker state did not commit after the transient destination lock cleared.");
                ExpectInfrastructure(
                    () => BrokerAtomicJson.Write(statePath, new { Revision = 3 }, overwrite: false),
                    "BROKER_IMMUTABLE_STATE_EXISTS");

                var finalFailureObserved = false;
                var retryWindow = Stopwatch.StartNew();
                using (var persistentDestinationLock = new FileStream(
                    statePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read))
                {
                    try
                    {
                        BrokerAtomicJson.Write(statePath, new { Revision = 4 }, overwrite: true);
                    }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                    {
                        finalFailureObserved = true;
                    }
                }

                retryWindow.Stop();
                Check(finalFailureObserved, "Atomic Broker state did not fail after its bounded retry window expired.");
                Check(retryWindow.Elapsed < TimeSpan.FromSeconds(2),
                    "Atomic Broker state transient retry exceeded its short bounded window.");
                Check(!Directory.EnumerateFiles(
                        paths.IdentityRoot,
                        ".atomic-retry-fixture.json.*.tmp",
                        SearchOption.TopDirectoryOnly).Any(),
                    "Atomic Broker state left a temporary file after the bounded retry failed.");
                fixture.CleanBrokerRuntime();
            }).ConfigureAwait(false);

            await CaseAsync("17 Broker crash recovery never misreports engineering success", () =>
            {
                var paths = fixture.CleanBrokerRuntime();
                var store = new BrokerOperationStore(paths);
                var action = fixture.GetAction("fixture-client-detach");
                var accepted = store.Accept(OperationIdentity(action), "broker-before-crash").Operation;
                store.Transition(accepted.ExecutionId, "broker-before-crash", BrokerOperationStates.Queued, "QUEUED");
                store.Transition(accepted.ExecutionId, "broker-before-crash", BrokerOperationStates.SessionVerified, "SESSION_VERIFIED");
                store.Transition(accepted.ExecutionId, "broker-before-crash", BrokerOperationStates.Executing, "EXECUTING");
                var recovered = store.RecoverInterrupted("broker-after-crash").Single();

                Check(recovered.Disposition == BrokerRecoveryDisposition.UnknownReviewRequired, "In-flight crash was not quarantined as UNKNOWN.");
                Check(recovered.Operation.State == BrokerOperationStates.UnknownReviewRequired, "In-flight crash state was not UNKNOWN_REVIEW_REQUIRED.");
                Check(recovered.Operation.TerminalReasonCode == "BROKER_CRASH_DURING_ENGINEERING_CALL", "Crash recovery reason changed.");
                Check(recovered.Operation.ObservationPath is null, "Crash recovery fabricated a success observation.");
                Check(recovered.Operation.ObservationSha256 is null, "Crash recovery fabricated an observation hash.");
                Check(recovered.Operation.State != BrokerOperationStates.Succeeded, "Crash recovery misreported success.");
                fixture.CleanBrokerRuntime();
                return Task.CompletedTask;
            }).ConfigureAwait(false);

            await CaseAsync("18 Cancellation after dispatch records request and continues", () =>
            {
                var paths = fixture.CleanBrokerRuntime();
                var store = new BrokerOperationStore(paths);
                var action = fixture.GetAction("fixture-pending-replay");
                var accepted = store.Accept(OperationIdentity(action), "broker-cancel").Operation;
                store.Transition(accepted.ExecutionId, "broker-cancel", BrokerOperationStates.Queued, "QUEUED");
                store.Transition(accepted.ExecutionId, "broker-cancel", BrokerOperationStates.SessionVerified, "SESSION_VERIFIED");
                store.Transition(accepted.ExecutionId, "broker-cancel", BrokerOperationStates.Executing, "EXECUTING");
                var cancellation = store.RequestCancellation(accepted.ExecutionId, "broker-cancel");

                Check(cancellation.Disposition == BrokerCancellationDisposition.NotCancelableContinuing, "Dispatched operation was incorrectly canceled.");
                Check(cancellation.Operation.CancellationRequested, "Cancellation request was not journaled.");
                Check(cancellation.Operation.State == BrokerOperationStates.Executing, "Cancellation changed an in-flight engineering state.");
                Check(!BrokerOperationStates.IsTerminal(cancellation.Operation.State), "In-flight cancellation was falsely terminal.");
                fixture.CleanBrokerRuntime();
                return Task.CompletedTask;
            }).ConfigureAwait(false);

            await CaseAsync("19 One Broker owner lease excludes a second owner", () =>
            {
                var paths = fixture.CleanBrokerRuntime();
                using (var first = BrokerOwnerLease.Acquire(paths, "broker-owner-a", TimeSpan.FromSeconds(1)))
                {
                    ExpectInfrastructure(
                        () => BrokerOwnerLease.Acquire(paths, "broker-owner-b", TimeSpan.Zero),
                        "BROKER_OWNER_BUSY");
                }

                using var reacquired = BrokerOwnerLease.Acquire(paths, "broker-owner-c", TimeSpan.FromSeconds(1));
                Check(reacquired.InstanceId == "broker-owner-c", "Owner lease did not become available after release.");
                fixture.CleanBrokerRuntime(keepIdentityRoot: true);
                return Task.CompletedTask;
            }).ConfigureAwait(false);

            await CaseAsync("20 Trusted evidence producer drift fails closed", async () =>
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

            await CaseAsync("21 Client source and Broker dispatcher have no online command surface", () =>
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

    private static async Task ExpectCanceledAsync(Task<RunnerExecutionResult> operation)
    {
        try
        {
            _ = await operation.ConfigureAwait(false);
            Check(false, "Expected client cancellation was not observed.");
        }
        catch (OperationCanceledException)
        {
            Check(true, "Client cancellation propagated without sealing a terminal result.");
        }
    }

    private static void ExpectInfrastructure(Action operation, string reasonCode)
    {
        try
        {
            operation();
            Check(false, $"Expected Broker infrastructure gate '{reasonCode}' was not raised.");
        }
        catch (BrokerInfrastructureException exception)
        {
            Check(exception.ReasonCode == reasonCode, $"Expected Broker gate '{reasonCode}', got '{exception.ReasonCode}'.");
        }
    }

    private static BrokerOperationIdentity OperationIdentity(ActionFixture action) => new(
        action.ActionId,
        action.Sha256,
        action.IdempotencyKey,
        action.ActionKind);

    private static BrokerExecutionReply PendingBrokerReply(ActionFixture action, string executionId) => new(
        Available: true,
        ReasonCode: "EXECUTION_CONTINUES_IN_BROKER",
        Session: new BrokerSessionIdentity(
            ProtocolVersion: BrokerWireProtocol.Version,
            BrokerPid: Environment.ProcessId,
            SessionId: "fixture-persistent-session",
            McpPid: 4200,
            PlePid: 4242,
            Profile: action.Profile,
            ActiveProjectPath: action.PlcProject,
            State: "ready",
            PleOwnedByBroker: false),
        Observation: null)
    {
        Accepted = true,
        Terminal = false,
        ExecutionId = executionId
    };

    private static BrokerExecutionReply SuccessfulBrokerReply(ActionFixture action)
    {
        var legacy = BuildBrokerReply(
            action,
            new JsonObject { ["requestId"] = action.ActionId });
        return new BrokerExecutionReply(
            Available: true,
            ReasonCode: "RUNNER_SUCCEEDED",
            Session: new BrokerSessionIdentity(
                ProtocolVersion: BrokerWireProtocol.Version,
                BrokerPid: Environment.ProcessId,
                SessionId: "fixture-persistent-session",
                McpPid: 4200,
                PlePid: 4242,
                Profile: action.Profile,
                ActiveProjectPath: action.PlcProject,
                State: "ready",
                PleOwnedByBroker: false),
            Observation: (JsonObject)Object(legacy, "observation").DeepClone())
        {
            Accepted = true,
            Terminal = true,
            ExecutionId = BrokerOperationStore.ExecutionIdFor(action.ActionId)
        };
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

    private static async Task<IReadOnlyList<JsonObject>> ServeNonterminalV2Async(
        string pipeName,
        string brokerInstanceId,
        string executionId,
        TaskCompletionSource ready,
        CancellationToken cancellationToken,
        string? terminalReviewReason = null,
        TaskCompletionSource? nonterminalQueryReceived = null)
    {
        var requests = new List<JsonObject>();
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await using var server = new NamedPipeServerStream(
                    pipeName,
                    PipeDirection.InOut,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                ready.TrySetResult();
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                var request = await BrokerPipeCodec.ReadAsync(server, cancellationToken).ConfigureAwait(false);
                requests.Add((JsonObject)request.DeepClone());
                var kind = String(request, "kind");
                JsonObject reply;
                if (kind == BrokerWireProtocol.SubmitKind)
                {
                    reply = new JsonObject
                    {
                        ["protocolVersion"] = BrokerWireProtocol.Version,
                        ["kind"] = BrokerWireProtocol.SubmitReplyKind,
                        ["requestId"] = String(request, "requestId"),
                        ["brokerInstanceId"] = brokerInstanceId,
                        ["clientNonce"] = String(request, "clientNonce"),
                        ["accepted"] = true,
                        ["reasonCode"] = "ACTION_ACCEPTED",
                        ["executionId"] = executionId,
                        ["disposition"] = "ACCEPTED",
                        ["state"] = BrokerOperationStates.Accepted
                    };
                }
                else if (kind == BrokerWireProtocol.QueryKind)
                {
                    if (terminalReviewReason is null)
                    {
                        nonterminalQueryReceived?.TrySetResult();
                        // Keep this accepted operation deliberately nonterminal until
                        // the client's bounded response deadline expires.  This avoids
                        // inferring pending state from a 250 ms server-recreation race.
                        await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
                        continue;
                    }

                    var reviewRequired = terminalReviewReason is not null;
                    reply = new JsonObject
                    {
                        ["protocolVersion"] = BrokerWireProtocol.Version,
                        ["kind"] = BrokerWireProtocol.QueryReplyKind,
                        ["requestId"] = String(request, "requestId"),
                        ["brokerInstanceId"] = brokerInstanceId,
                        ["clientNonce"] = String(request, "clientNonce"),
                        ["executionId"] = executionId,
                        ["terminal"] = reviewRequired,
                        ["reviewRequired"] = reviewRequired,
                        ["reasonCode"] = terminalReviewReason ?? "EXECUTION_CONTINUES_IN_BROKER",
                        ["state"] = reviewRequired
                            ? BrokerOperationStates.UnknownReviewRequired
                            : BrokerOperationStates.Executing,
                        ["session"] = null,
                        ["observation"] = null
                    };
                }
                else
                {
                    throw new InvalidOperationException("Fake protocol v2 Broker received unsupported request kind: " + kind);
                }

                await BrokerPipeCodec.WriteAsync(server, reply, cancellationToken).ConfigureAwait(false);
                if (terminalReviewReason is not null && kind == BrokerWireProtocol.QueryKind)
                {
                    return requests;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Expected harness shutdown after the Runner response timeout.
        }
        catch (IOException) when (cancellationToken.IsCancellationRequested)
        {
            // The client may detach as the bounded harness is canceled.
        }
        catch (RunnerGateException exception) when (exception.ReasonCode == "BROKER_PROTOCOL_INVALID")
        {
            // A final bounded query can connect and then detach when its deadline
            // expires.  It did not receive or execute another typed request.
        }

        return requests;
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
        const int mcpPid = 4200;
        const int plePid = 4242;
        var buildStarted = DateTimeOffset.UtcNow;
        var buildCompleted = buildStarted.AddMilliseconds(10);
        var completed = buildCompleted.AddMilliseconds(10);
        var session = new JsonObject
        {
            ["protocolVersion"] = NamedPipeSessionBrokerClient.ProtocolVersion,
            ["brokerPid"] = Environment.ProcessId,
            ["sessionId"] = sessionId,
            ["mcpPid"] = mcpPid,
            ["plePid"] = plePid,
            ["profile"] = profile,
            ["activeProjectPath"] = project,
            ["state"] = "ready",
            ["pleOwnedByBroker"] = false
        };
        var observedSession = new JsonObject
        {
            ["state"] = "ready",
            ["mode"] = "persistent",
            ["sessionId"] = sessionId,
            ["mcpPid"] = mcpPid,
            ["plePid"] = plePid,
            ["profile"] = profile,
            ["activeProjectPath"] = project,
            ["pleOwnedByBroker"] = false
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
                "clean_compile_project",
                "get_ctrlx_semantic_snapshot"),
            ["session"] = observedSession,
            ["guardrails"] = new JsonObject
            {
                ["onlineOperationsUsed"] = false,
                ["secondPleStarted"] = false,
                ["actionProjectGateAcquired"] = true,
                ["actionProjectGateReleased"] = true,
                ["actionProjectGateKind"] = "broker-session-action-serialization",
                ["symbolLeaseHeld"] = false,
                ["pleOrMcpStartedByAction"] = false,
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
                    ["summarySource"] = "codesys-persistent.clean_compile_project",
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
                    ["pleOrMcpStartedByAction"] = false,
                    ["directWatcherIpcUsed"] = false,
                    ["symbolPostProcessingVerified"] = true
                },
                ["semanticProofs"] = new JsonObject
                {
                    ["contractVersion"] = 1,
                    ["ownership"] = VerifiedProof("fixture.ownership"),
                    ["readback"] = VerifiedProof("fixture.readback"),
                    ["recoverableBaseline"] = VerifiedProof("fixture.git-head"),
                    ["warnings"] = VerifiedProof("fixture.warning-baseline"),
                    ["semanticBaseline"] = VerifiedProof("fixture.semantic-baseline"),
                    ["mapping"] = VerifiedProof("fixture.mapping"),
                    ["symbolPostProcessing"] = VerifiedProof("fixture.symbol")
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

    private static JsonObject VerifiedProof(string producer) => new()
    {
        ["producer"] = producer,
        ["contractVersion"] = 1,
        ["verified"] = true
    };

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
        Check(Boolean(guardrails, "prohibitPleOrMcpStartByAction"), "Broker request does not prohibit PLE/MCP start by this action.");
        Check(Boolean(guardrails, "prohibitDirectWatcherIpc"), "Broker request does not prohibit watcher IPC.");
        Check(Boolean(guardrails, "requireExactProjectOpen"), "Broker request does not require the exact project.");
        Check(!Boolean(guardrails, "pleOrMcpStartedByActionAllowed"), "Broker request permits this action to start PLE/MCP.");
    }

    private static void AssertStaticSafety(string repositoryRoot)
    {
        var sourceRoot = Path.Combine(repositoryRoot, "src", "runner");
        var clientSourceFiles = Directory.EnumerateFiles(sourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !HasSegment(path, "bin") && !HasSegment(path, "obj"))
            .Where(path => !HasSegment(path, "CtrlX.OpCon.Runner.Broker"))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        Check(clientSourceFiles.Length >= 8, "Runner source scan did not find the expected Core/CLI files.");
        var sources = clientSourceFiles.ToDictionary(
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

        foreach (var obsoleteLifecycleField in new[]
        {
            "prohibitStartPleOrMcp",
            "projectLeaseRequired",
            "releaseLeaseAfterAction",
            "coordinationScope",
            "requireProjectLeaseReleased",
            "projectLeaseScope",
            "projectLeaseAcquired",
            "pleOrMcpStarted\"",
            "startedByRunner\""
        })
        {
            Check(!combined.Contains(obsoleteLifecycleField, StringComparison.Ordinal),
                $"Runner production source still contains obsolete lifecycle field '{obsoleteLifecycleField}'.");
        }

        var processStartCount = Regex.Matches(combined, "new\\s+ProcessStartInfo", RegexOptions.CultureInvariant).Count;
        Check(processStartCount == 1, "Runner must have exactly one allowlisted child-process boundary.");
        var sealerSource = sources.Single(item => Path.GetFileName(item.Key) == "PowerShellEvidenceSealer.cs").Value;
        Check(
            sealerSource.Contains("Environment.SpecialFolder.ProgramFiles", StringComparison.Ordinal) &&
            sealerSource.Contains("\"PowerShell\"", StringComparison.Ordinal) &&
            sealerSource.Contains("\"7\"", StringComparison.Ordinal) &&
            sealerSource.Contains("\"pwsh.exe\"", StringComparison.Ordinal) &&
            sealerSource.Contains("FileName = powerShell7", StringComparison.Ordinal),
            "Runner child-process target is not the absolute PowerShell 7 evidence producer host.");

        var pipeSourcePath = Path.Combine(
            sourceRoot,
            "CtrlX.OpCon.Runner.Core",
            "NamedPipeSessionBrokerClient.cs");
        var pipeSource = File.ReadAllText(pipeSourcePath);
        Check(!pipeSource.Contains("ProcessStartInfo", StringComparison.Ordinal), "Named Pipe client gained process-start capability.");
        Check(!pipeSource.Contains("Process.Start", StringComparison.Ordinal), "Named Pipe client gained process-start capability.");
        Check(
            pipeSource.Contains("TimeSpan.FromMinutes(30)", StringComparison.Ordinal) &&
            pipeSource.Contains("TimeSpan.FromMinutes(60)", StringComparison.Ordinal),
            "Named Pipe client default response timeout is shorter than the controlled Clean Build action window.");
        var cliSource = File.ReadAllText(Path.Combine(
            sourceRoot,
            "CtrlX.OpCon.Runner.Cli",
            "Program.cs"));
        Check(
            cliSource.Contains(
                "\"broker-action-timeout-ms\", 1_800_000, minimum: 1_000, maximum: 3_600_000",
                StringComparison.Ordinal),
            "Runner CLI must expose the controlled 30-minute default and 60-minute maximum action timeout.");
        var wrapperSource = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "templates",
            "ctrlx-opcon-project",
            "scripts",
            "runner",
            "Invoke-CtrlXOpconRunner.ps1"));
        Check(
            wrapperSource.Contains("[ValidateRange(1000, 3600000)]", StringComparison.Ordinal) &&
            wrapperSource.Contains("$BrokerActionTimeoutMilliseconds = 1800000", StringComparison.Ordinal),
            "Runner PowerShell wrapper must preserve the controlled 30-minute default and 60-minute maximum action timeout.");

        var brokerSourceRoot = Path.Combine(sourceRoot, "CtrlX.OpCon.Runner.Broker");
        var brokerDispatchSources = Directory.EnumerateFiles(brokerSourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !HasSegment(path, "bin") && !HasSegment(path, "obj") && !HasSegment(path, "Mcp"))
            .Select(File.ReadAllText)
            .ToArray();
        Check(brokerDispatchSources.Length >= 8, "Broker infrastructure/dispatcher source scan was unexpectedly empty.");
        var brokerDispatchCombined = string.Join("\n", brokerDispatchSources);
        Check(
            brokerDispatchCombined.Contains("\"--timeout\", \"1020000\"", StringComparison.Ordinal) &&
            brokerDispatchCombined.Contains("TimeSpan.FromMinutes(20)", StringComparison.Ordinal) &&
            brokerDispatchCombined.Contains("TimeSpan.FromMinutes(17)", StringComparison.Ordinal),
            "Broker/MCP timeout chain can expire before the controlled Clean Build completes.");
        foreach (var obsoleteLifecycleField in new[]
        {
            "projectLeaseScope",
            "projectLeaseAcquired",
            "pleOrMcpStarted\"",
            "startedByRunner\""
        })
        {
            Check(!brokerDispatchCombined.Contains(obsoleteLifecycleField, StringComparison.Ordinal),
                $"Broker production source still contains obsolete lifecycle field '{obsoleteLifecycleField}'.");
        }

        foreach (var onlineCapability in new[]
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
            Check(!brokerDispatchCombined.Contains(onlineCapability, StringComparison.OrdinalIgnoreCase), $"Broker dispatcher contains online capability '{onlineCapability}'.");
        }

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
                ["prohibitPleOrMcpStartByAction"] = true,
                ["prohibitDirectWatcherIpc"] = true,
                ["requireExactProjectOpen"] = true,
                ["actionProjectGateRequired"] = true,
                ["releaseActionProjectGateBeforeTerminalDelivery"] = true,
                ["symbolAccessSerialized"] = true,
                ["actionProjectGateKind"] = "broker-session-action-serialization"
            },
            ["changeSet"] = changeSet ?? new JsonArray(),
            ["instructions"] = new JsonArray("fixture"),
            ["evidenceContract"] = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["requireActionRequestSha256"] = true,
                ["requireOfflineOnly"] = true,
                ["requireActionProjectGateReleased"] = true,
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

    public BrokerRuntimePaths CleanBrokerRuntime(bool keepIdentityRoot = false)
    {
        var paths = new BrokerRuntimePaths(
            EngineeringRoot,
            StationRoot,
            "ctrlX PLC 2.6.8",
            PlcProject);
        if (File.Exists(paths.RegistrationPath))
        {
            File.Delete(paths.RegistrationPath);
        }

        if (!keepIdentityRoot && Directory.Exists(paths.IdentityRoot))
        {
            Directory.Delete(paths.IdentityRoot, recursive: true);
        }

        return paths;
    }

    public void Dispose()
    {
        CleanBrokerRuntime();
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

internal sealed class FixedBrokerClient : ISessionBrokerClient
{
    private readonly BrokerExecutionReply reply;

    public FixedBrokerClient(BrokerExecutionReply reply)
    {
        this.reply = reply;
    }

    public string TransportName => "fixture-fixed-broker";

    public Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(reply);
    }
}

internal sealed class SequenceBrokerClient : ISessionBrokerClient
{
    private readonly Queue<BrokerExecutionReply> replies;

    public SequenceBrokerClient(params BrokerExecutionReply[] replies)
    {
        this.replies = new Queue<BrokerExecutionReply>(replies);
    }

    public int Calls { get; private set; }

    public string TransportName => "fixture-idempotent-broker";

    public Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls++;
        if (replies.Count == 0)
        {
            throw new InvalidOperationException("Fixture Broker received an unexpected duplicate dispatch.");
        }

        return Task.FromResult(replies.Dequeue());
    }
}

internal sealed class SerializingNoSessionBrokerClient : ISessionBrokerClient
{
    private readonly SemaphoreSlim serial = new(1, 1);
    private int active;
    private int calls;
    private int maximumConcurrent;

    public int Calls => Volatile.Read(ref calls);

    public int MaximumConcurrent => Volatile.Read(ref maximumConcurrent);

    public string TransportName => "fixture-serialized-broker";

    public async Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref calls);
        await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var current = Interlocked.Increment(ref active);
            UpdateMaximum(current);
            await Task.Delay(75, cancellationToken).ConfigureAwait(false);
            return new BrokerExecutionReply(
                Available: false,
                ReasonCode: "BLOCKED_SESSION_UNAVAILABLE",
                Session: null,
                Observation: null)
            {
                Accepted = false,
                Terminal = false
            };
        }
        finally
        {
            Interlocked.Decrement(ref active);
            serial.Release();
        }
    }

    private void UpdateMaximum(int current)
    {
        while (true)
        {
            var observed = Volatile.Read(ref maximumConcurrent);
            if (current <= observed ||
                Interlocked.CompareExchange(ref maximumConcurrent, current, observed) == observed)
            {
                return;
            }
        }
    }
}

internal sealed class BlockingCancelableBrokerClient : ISessionBrokerClient
{
    private readonly TaskCompletionSource entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource neverCompletes = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public string TransportName => "fixture-cancelable-broker";

    public async Task<BrokerExecutionReply> ExecuteAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        entered.TrySetResult();
        await neverCompletes.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        throw new InvalidOperationException("Unreachable fixture path.");
    }

    public Task WaitUntilEnteredAsync(TimeSpan timeout) => entered.Task.WaitAsync(timeout);
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

internal sealed class CountingEvidenceSealer : IEvidenceSealer
{
    private readonly IEvidenceSealer inner;

    public CountingEvidenceSealer(IEvidenceSealer inner)
    {
        this.inner = inner;
    }

    public int Calls { get; private set; }

    public async Task<EvidenceSealResult> SealAsync(
        ValidatedRunnerAction action,
        string observationPath,
        CancellationToken cancellationToken)
    {
        Calls++;
        return await inner.SealAsync(action, observationPath, cancellationToken).ConfigureAwait(false);
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
