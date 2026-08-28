using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Core;
using CtrlX.OpCon.Runner.Host;

namespace CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest;

internal static class Program
{
    private static readonly TimeSpan ProcessTimeout = TimeSpan.FromSeconds(60);

    public static async Task<int> Main()
    {
        var engineeringProcessesBefore = EngineeringProcessSnapshot.Capture();
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("Host default ingestor advances sealed terminal evidence", HostDefaultIngestorAdvancesLedgerAsync),
            ("production ingestor advances valid DONE evidence", ValidDoneEvidenceAdvancesLedgerAsync),
            ("production ingestor advances valid BLOCKED evidence", ValidBlockedEvidenceAdvancesLedgerAsync),
            ("production ingestor maps a real exclusive ledger lock to coordinator busy without mutation", ExclusiveLedgerLockFailsBusyWithoutMutationAsync),
            ("production ingestor rejects evidence SHA drift without changing the ledger", EvidenceShaDriftFailsClosedAsync),
            ("production ingestor keeps evidence-less UNKNOWN in manual review", MissingEvidenceRequiresManualReviewAsync)
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
                var failure = $"{test.Name}: {exception.GetType().Name}: {exception.Message}";
                failures.Add(failure);
                Console.Error.WriteLine($"FAIL: {failure}");
            }
        }

        await Task.Delay(250).ConfigureAwait(false);
        var addedProcesses = EngineeringProcessSnapshot.Capture().AddedSince(engineeringProcessesBefore);
        if (addedProcesses.Count > 0)
        {
            var detail = string.Join(", ", addedProcesses.Select(item => $"{item.Name}({item.ProcessId})"));
            failures.Add($"Engineering/MCP/Node process PID set increased during SelfTest: {detail}");
            Console.Error.WriteLine($"FAIL: {failures[^1]}");
        }

        if (failures.Count == 0)
        {
            Console.WriteLine(
                "Stage2 production-ingestor fixture E2E passed. Only Program Files PowerShell 7 and temporary files were used; no PLE, MCP, Node, or online operation was started.");
            return 0;
        }

        Console.Error.WriteLine($"Stage2 production-ingestor fixture E2E failed: {failures.Count} case(s).");
        return 1;
    }

    private static async Task HostDefaultIngestorAdvancesLedgerAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        var evidence = await fixture.SealDoneAsync().ConfigureAwait(false);
        var consumer = new HostActionConsumer(fixture.EngineeringRoot, fixture.ActivatedAtUtc);
        using var timeoutSource = new CancellationTokenSource(ProcessTimeout);
        HostActionStatus? lastStatus = null;
        var coordinatorStarted = false;

        while (!timeoutSource.IsCancellationRequested)
        {
            lastStatus = consumer.Tick(agentAvailable: false, timeoutSource.Token);
            coordinatorStarted |= lastStatus.ReasonCode == "HOST_COORDINATOR_STARTED";
            Require(lastStatus.State is not HostActionStates.Invalid and not HostActionStates.Ambiguous,
                $"Host default ingestor entered {lastStatus.State}: {lastStatus.ReasonCode}.");
            if (lastStatus.State == HostActionStates.None)
            {
                break;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(25), timeoutSource.Token).ConfigureAwait(false);
        }

        Require(coordinatorStarted,
            "Host did not start its default Stage2 evidence ingestor for the sealed terminal fixture.");
        Require(lastStatus?.State == HostActionStates.None &&
                lastStatus.ReasonCode == "HOST_NO_PENDING_ACTION",
            $"Host did not clear the ingested action before timeout: {lastStatus?.State ?? "no state"}/{lastStatus?.ReasonCode ?? "no reason"}.");
        fixture.RequireTerminalLedger("DONE", evidence);
    }

    private static async Task ValidDoneEvidenceAdvancesLedgerAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        var evidence = await fixture.SealDoneAsync().ConfigureAwait(false);
        var entry = fixture.ReadSingleResultReadyEntry();

        await new PowerShellStage2EvidenceIngestor(fixture.EngineeringRoot, ProcessTimeout)
            .IngestAsync(entry, CancellationToken.None)
            .ConfigureAwait(false);

        fixture.RequireTerminalLedger("DONE", evidence);
    }

    private static async Task ValidBlockedEvidenceAdvancesLedgerAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        var evidence = await fixture.SealBlockedAsync().ConfigureAwait(false);
        var entry = fixture.ReadSingleResultReadyEntry();

        await new PowerShellStage2EvidenceIngestor(fixture.EngineeringRoot, ProcessTimeout)
            .IngestAsync(entry, CancellationToken.None)
            .ConfigureAwait(false);

        fixture.RequireTerminalLedger("BLOCKED", evidence);
    }

    private static async Task ExclusiveLedgerLockFailsBusyWithoutMutationAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        var evidence = await fixture.SealDoneAsync().ConfigureAwait(false);
        var entry = fixture.ReadSingleResultReadyEntry();
        var ledgerBefore = File.ReadAllBytes(fixture.OperationPath);
        var evidenceBefore = File.ReadAllBytes(evidence.Path);
        var actionBefore = File.ReadAllBytes(fixture.Action.ActionPath);
        var operationDirectory = Path.GetDirectoryName(fixture.OperationPath)
            ?? throw new InvalidOperationException("Fixture operation path has no directory.");
        var workflowRoot = Directory.GetParent(operationDirectory)?.FullName
            ?? throw new InvalidOperationException("Fixture operation directory has no workflow root.");
        var ledgerLockPath = Path.Combine(workflowRoot, ".ledger.lock");

        RunnerGateException? rejection = null;
        using (var exclusiveLedgerLock = new FileStream(
                   ledgerLockPath,
                   FileMode.OpenOrCreate,
                   FileAccess.ReadWrite,
                   FileShare.None))
        {
            try
            {
                await new PowerShellStage2EvidenceIngestor(fixture.EngineeringRoot)
                    .IngestAsync(entry, CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch (RunnerGateException exception)
            {
                rejection = exception;
            }
        }

        Require(rejection?.ReasonCode == "STAGE2_COORDINATOR_BUSY",
            $"Exclusive workflow ledger lock did not map to STAGE2_COORDINATOR_BUSY: {rejection?.ReasonCode ?? "no rejection"}.");
        Require(File.ReadAllBytes(fixture.OperationPath).SequenceEqual(ledgerBefore),
            "Coordinator busy changed the Stage2 operation ledger.");
        Require(File.ReadAllBytes(evidence.Path).SequenceEqual(evidenceBefore),
            "Coordinator busy changed the sealed Runner evidence.");
        Require(File.ReadAllBytes(fixture.Action.ActionPath).SequenceEqual(actionBefore),
            "Coordinator busy changed the immutable Runner action.");
        fixture.RequireCurrentActionUnchanged();
    }

    private static async Task EvidenceShaDriftFailsClosedAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        var evidence = await fixture.SealDoneAsync().ConfigureAwait(false);
        var entry = fixture.ReadSingleResultReadyEntry();
        var ledgerBefore = File.ReadAllBytes(fixture.OperationPath);

        File.AppendAllText(evidence.Path, " ", new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        RunnerGateException? rejection = null;
        try
        {
            await new PowerShellStage2EvidenceIngestor(fixture.EngineeringRoot, ProcessTimeout)
                .IngestAsync(entry, CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (RunnerGateException exception)
        {
            rejection = exception;
        }

        Require(rejection?.ReasonCode == "RUN_RESULT_INTEGRITY_INVALID",
            $"Evidence drift was not rejected by the production result validator: {rejection?.ReasonCode ?? "no rejection"}.");
        Require(File.ReadAllBytes(fixture.OperationPath).SequenceEqual(ledgerBefore),
            "Evidence drift changed the Stage2 ledger before rejection.");
        fixture.RequireCurrentActionUnchanged();
    }

    private static async Task MissingEvidenceRequiresManualReviewAsync()
    {
        using var fixture = await Stage2Fixture.CreateAsync().ConfigureAwait(false);
        fixture.SealUnknownWithoutEvidence();
        var entry = fixture.ReadSingleResultReadyEntry();
        var ledgerBefore = File.ReadAllBytes(fixture.OperationPath);

        RunnerGateException? rejection = null;
        try
        {
            await new PowerShellStage2EvidenceIngestor(fixture.EngineeringRoot, ProcessTimeout)
                .IngestAsync(entry, CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (RunnerGateException exception)
        {
            rejection = exception;
        }

        Require(rejection?.ReasonCode == "STAGE2_MANUAL_REVIEW_REQUIRED",
            $"Evidence-less UNKNOWN did not enter manual review: {rejection?.ReasonCode ?? "no rejection"}.");
        Require(File.ReadAllBytes(fixture.OperationPath).SequenceEqual(ledgerBefore),
            "Evidence-less manual review changed the Stage2 ledger.");
        fixture.RequireCurrentActionUnchanged();
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class Stage2Fixture : IDisposable
    {
        private readonly string testRoot;
        private readonly DateTimeOffset activatedAtUtc;
        private bool disposed;

        private Stage2Fixture(
            string testRoot,
            string engineeringRoot,
            string stationRoot,
            string plcProject,
            string operationPath,
            ValidatedRunnerAction action,
            DateTimeOffset activatedAtUtc)
        {
            this.testRoot = testRoot;
            EngineeringRoot = engineeringRoot;
            StationRoot = stationRoot;
            PlcProject = plcProject;
            OperationPath = operationPath;
            Action = action;
            Store = RunnerRunStore.ForAction(action);
            this.activatedAtUtc = activatedAtUtc;
        }

        public string EngineeringRoot { get; }

        public string StationRoot { get; }

        public string PlcProject { get; }

        public string OperationPath { get; }

        public DateTimeOffset ActivatedAtUtc => activatedAtUtc;

        public ValidatedRunnerAction Action { get; }

        public RunnerRunStore Store { get; }

        public static async Task<Stage2Fixture> CreateAsync()
        {
            var repositoryRoot = FindRepositoryRoot();
            var sourceScripts = Path.Combine(
                repositoryRoot,
                "templates",
                "ctrlx-opcon-project",
                "scripts",
                "cpstudio");
            var coordinatorSource = Path.Combine(sourceScripts, "Invoke-PostExportEngineering.ps1");
            var producerSource = Path.Combine(sourceScripts, "New-PostExportRunnerEvidence.ps1");
            Require(File.Exists(coordinatorSource), $"Coordinator source is missing: {coordinatorSource}");
            Require(File.Exists(producerSource), $"Evidence producer source is missing: {producerSource}");
            Require(NormalizedScriptSha256(coordinatorSource).Equals(
                    PowerShellStage2EvidenceIngestor.TrustedCoordinatorNormalizedSha256,
                    StringComparison.OrdinalIgnoreCase),
                "Repository coordinator does not match the production ingestor release hash.");
            Require(NormalizedScriptSha256(producerSource).Equals(
                    PowerShellEvidenceSealer.TrustedEvidenceProducerNormalizedSha256,
                    StringComparison.OrdinalIgnoreCase),
                "Repository evidence producer does not match the production sealer release hash.");

            var testRoot = Path.Combine(
                Path.GetTempPath(),
                $"ctrlx-stage2-ingestor-e2e-{Guid.NewGuid():N}");
            var engineeringRoot = Path.Combine(testRoot, "McpCoding");
            var stationRoot = Path.Combine(testRoot, "StationDemo");
            var plcProject = Path.Combine(stationRoot, "Plc", "Demo_PLC.project");
            var scriptRoot = Path.Combine(engineeringRoot, "scripts", "cpstudio");
            var operationRoot = Path.Combine(engineeringRoot, "data", "operations", "cpstudio-stage2");
            var reportRoot = Path.Combine(engineeringRoot, "data", "reports", "cpstudio");
            var activatedAtUtc = DateTimeOffset.UtcNow.AddHours(-1);

            try
            {
                foreach (var directory in new[]
                {
                    Path.Combine(engineeringRoot, "ai"),
                    Path.Combine(engineeringRoot, "config"),
                    Path.Combine(engineeringRoot, "docs", "reviews"),
                    Path.Combine(engineeringRoot, "data", "runner-evidence"),
                    reportRoot,
                    scriptRoot,
                    Path.Combine(stationRoot, "Engineering"),
                    Path.Combine(stationRoot, "Plc")
                })
                {
                    Directory.CreateDirectory(directory);
                }

                File.Copy(coordinatorSource, Path.Combine(scriptRoot, Path.GetFileName(coordinatorSource)));
                File.Copy(producerSource, Path.Combine(scriptRoot, Path.GetFileName(producerSource)));
                WriteText(Path.Combine(engineeringRoot, "ai", "ownership.yaml"),
                    "schema_version: 1\nobjects:\n  - path: Application/Station/_this/StationUnit/OnCall\n    owner: mixed\n    write_mode: semantic_merge\n    hook_ids: [station_cyclic_controls]\n");
                WriteText(Path.Combine(engineeringRoot, "ai", "hooks.yaml"),
                    "schema_version: 1\nhooks:\n  - id: station_cyclic_controls\n    object: Application/Station/_this/StationUnit/OnCall\n    required_calls:\n      - Station.MainPressureControl\n");
                WriteText(Path.Combine(engineeringRoot, "ai", "graphical.yaml"), "schema_version: 1\n");
                WriteText(Path.Combine(stationRoot, "Engineering", "Engineering_Data.xml"),
                    "<OpConData version=\"exported\" />\n");
                WriteText(Path.Combine(stationRoot, "Engineering", "Demo.cpsp"), "<Project />\n");
                WriteText(plcProject, "encrypted-plc-placeholder\n");
                WriteText(Path.Combine(stationRoot, "Plc", "Demo_IO.project"), "encrypted-io-placeholder\n");
                WriteText(Path.Combine(engineeringRoot, "config", "project.yaml"),
                    "schema_version: 1\npaths:\n  station_root: '../StationDemo'\n  plc_project: '../StationDemo/Plc/Demo_PLC.project'\n  export_request: 'data/requests'\ntools:\n  plc_engineering_profile: 'ctrlX PLC 2.6.8'\n");

                CreateReviewedBaselines(engineeringRoot);
                var requestedAtUtc = DateTimeOffset.UtcNow.AddMinutes(-10);
                var auditPath = Path.Combine(reportRoot, "ingestor-e2e.json");
                WriteJson(auditPath, CreateStage1Audit(
                    engineeringRoot,
                    stationRoot,
                    plcProject,
                    $"ingestor-e2e-{Guid.NewGuid():N}",
                    requestedAtUtc));

                var coordinatorPath = Path.Combine(scriptRoot, "Invoke-PostExportEngineering.ps1");
                var coordinatorResult = await RunPowerShell7Async(
                    engineeringRoot,
                    coordinatorPath,
                    "-AuditReport", auditPath,
                    "-EngineeringRoot", engineeringRoot,
                    "-OperationRoot", operationRoot).ConfigureAwait(false);
                Require(coordinatorResult.ExitCode == 0,
                    $"Fixture coordinator failed (exit {coordinatorResult.ExitCode}): {Limit(coordinatorResult.StandardError)} {Limit(coordinatorResult.StandardOutput)}");

                var operationDirectories = Directory.GetDirectories(operationRoot);
                Require(operationDirectories.Length == 1,
                    $"Fixture coordinator created {operationDirectories.Length} operation directories instead of one.");
                var operationPath = Path.Combine(operationDirectories[0], "operation.json");
                var operation = ReadObject(operationPath);
                var currentAction = operation["currentAction"] as JsonObject
                    ?? throw new InvalidOperationException("Fixture operation has no current action.");
                var actionPath = RequiredString(currentAction, "path");
                var actionSha256 = RequiredString(currentAction, "sha256");
                var action = new RunnerActionValidator().Validate(engineeringRoot, actionPath, actionSha256);
                Require(action.ActionKind == "inspect_and_build" && action.IsSupported,
                    "Fixture did not create a supported inspect_and_build action.");

                return new Stage2Fixture(
                    testRoot,
                    engineeringRoot,
                    stationRoot,
                    plcProject,
                    operationPath,
                    action,
                    activatedAtUtc);
            }
            catch
            {
                TryDeleteDirectory(testRoot);
                throw;
            }
        }

        public async Task<EvidenceSealResult> SealDoneAsync()
        {
            Require(Store.TryCreateClaim("stage2-ingestor-production-e2e"),
                "Fixture Runner claim was not created.");
            var observationSha256 = Store.WriteObservation(CreateSuccessfulObservation());
            var evidence = await new PowerShellEvidenceSealer(ProcessTimeout)
                .SealAsync(Action, Store.ObservationPath, CancellationToken.None)
                .ConfigureAwait(false);
            var result = Store.Complete(
                RunnerStates.Done,
                "BUILD_VERIFIED",
                RunnerExitCodes.Done,
                observationSha256,
                evidence);
            Require(result.EvidenceSha256 == evidence.Sha256,
                "Fixture terminal result did not bind the sealed evidence SHA-256.");
            return evidence;
        }

        public async Task<EvidenceSealResult> SealBlockedAsync()
        {
            const string reasonCode = "TEST_RUNNER_BLOCKED";
            Require(Store.TryCreateClaim("stage2-ingestor-production-e2e"),
                "Fixture Runner claim was not created.");
            var observationSha256 = Store.WriteObservation(CreateBlockedObservation(reasonCode));
            var evidence = await new PowerShellEvidenceSealer(ProcessTimeout)
                .SealAsync(Action, Store.ObservationPath, CancellationToken.None)
                .ConfigureAwait(false);
            _ = Store.Complete(
                RunnerStates.Blocked,
                reasonCode,
                RunnerExitCodes.Blocked,
                observationSha256,
                evidence);
            return evidence;
        }

        public void SealUnknownWithoutEvidence()
        {
            Require(Store.TryCreateClaim("stage2-ingestor-production-e2e"),
                "Fixture Runner claim was not created.");
            _ = Store.Complete(
                RunnerStates.Unknown,
                "BROKER_REVIEW_REQUIRED",
                RunnerExitCodes.GateFailure,
                observationSha256: null,
                evidence: null);
        }

        public RunnerInboxEntry ReadSingleResultReadyEntry()
        {
            var snapshot = new RunnerActionInbox().Locate(EngineeringRoot, activatedAtUtc);
            Require(snapshot.Issues.Count == 0,
                $"Fixture inbox reported issues: {string.Join(",", snapshot.Issues.Select(item => item.ReasonCode))}");
            Require(snapshot.Entries.Count == 1,
                $"Fixture inbox returned {snapshot.Entries.Count} entries instead of one.");
            var entry = snapshot.Entries[0];
            Require(entry.State == RunnerInboxEntryState.ResultReady &&
                entry.ActionId == Action.ActionId &&
                entry.ActionSha256.Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase),
                "Fixture inbox did not expose the expected terminal action.");
            return entry;
        }

        public void RequireTerminalLedger(string expectedStatus, EvidenceSealResult evidence)
        {
            var operation = ReadObject(OperationPath);
            Require(RequiredString(operation, "status") == expectedStatus,
                $"Stage2 ledger status is not {expectedStatus}.");
            Require(operation["currentAction"] is null,
                "Stage2 terminal ledger retained currentAction.");
            var accepted = (operation["evidence"] as JsonArray)?.OfType<JsonObject>().Any(item =>
                string.Equals(item["actionId"]?.GetValue<string>(), Action.ActionId, StringComparison.Ordinal) &&
                string.Equals(item["sourceSha256"]?.GetValue<string>(), evidence.Sha256, StringComparison.OrdinalIgnoreCase)) == true;
            Require(accepted, "Stage2 terminal ledger did not bind the exact sealed evidence SHA-256.");
        }

        public void RequireCurrentActionUnchanged()
        {
            var operation = ReadObject(OperationPath);
            Require(RequiredString(operation, "status") == "WAITING_FOR_RUNNER",
                "Rejected ingestion changed the operation status.");
            var currentAction = operation["currentAction"] as JsonObject
                ?? throw new InvalidOperationException("Rejected ingestion removed currentAction.");
            Require(RequiredString(currentAction, "actionId") == Action.ActionId &&
                RequiredString(currentAction, "sha256").Equals(Action.ActionSha256, StringComparison.OrdinalIgnoreCase),
                "Rejected ingestion changed currentAction identity.");
        }

        private JsonObject CreateSuccessfulObservation()
        {
            var startedAtUtc = DateTimeOffset.UtcNow;
            if (startedAtUtc <= Action.CreatedAtUtc)
            {
                startedAtUtc = Action.CreatedAtUtc.AddMilliseconds(100);
            }
            var completedAtUtc = startedAtUtc.AddMilliseconds(100);
            var observationCompletedAtUtc = completedAtUtc.AddMilliseconds(100);
            return new JsonObject
            {
                ["schemaVersion"] = 1,
                ["operationId"] = Action.OperationId,
                ["actionId"] = Action.ActionId,
                ["actionKind"] = Action.ActionKind,
                ["actionRequestSha256"] = Action.ActionSha256,
                ["status"] = "succeeded",
                ["completedAtUtc"] = observationCompletedAtUtc.ToString("O"),
                ["capabilitiesInvoked"] = new JsonArray(
                    "get_codesys_status",
                    "clean_compile_project",
                    "get_ctrlx_semantic_snapshot"),
                ["session"] = new JsonObject
                {
                    ["state"] = "ready",
                    ["mode"] = "persistent",
                    ["sessionId"] = "fixture-stage2-session",
                    ["plePid"] = 1234,
                    ["mcpPid"] = 2345,
                    ["profile"] = Action.Profile,
                    ["activeProjectPath"] = Action.PlcProject,
                    ["pleOwnedByBroker"] = false
                },
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
                        ["buildId"] = "fixture-stage2-build",
                        ["projectPath"] = PlcProject,
                        ["profile"] = Action.Profile,
                        ["projectSha256"] = RunnerHash.Sha256File(PlcProject),
                        ["startedAtUtc"] = startedAtUtc.ToString("O"),
                        ["completedAtUtc"] = completedAtUtc.ToString("O"),
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
                    ["semanticProofs"] = CreateSemanticProofs()
                }
            };
        }

        private JsonObject CreateBlockedObservation(string reasonCode)
        {
            var completedAtUtc = DateTimeOffset.UtcNow;
            if (completedAtUtc < Action.CreatedAtUtc)
            {
                completedAtUtc = Action.CreatedAtUtc;
            }
            return new JsonObject
            {
                ["schemaVersion"] = 1,
                ["operationId"] = Action.OperationId,
                ["actionId"] = Action.ActionId,
                ["actionKind"] = Action.ActionKind,
                ["actionRequestSha256"] = Action.ActionSha256,
                ["status"] = "blocked",
                ["completedAtUtc"] = completedAtUtc.ToString("O"),
                ["capabilitiesInvoked"] = new JsonArray(),
                ["guardrails"] = new JsonObject
                {
                    ["onlineOperationsUsed"] = false,
                    ["secondPleStarted"] = false,
                    ["actionProjectGateAcquired"] = false,
                    ["actionProjectGateReleased"] = true,
                    ["actionProjectGateKind"] = "none",
                    ["symbolLeaseHeld"] = false,
                    ["pleOrMcpStartedByAction"] = false,
                    ["directWatcherIpcUsed"] = false
                },
                ["result"] = new JsonObject
                {
                    ["verificationOk"] = false,
                    ["appliedReadbackOk"] = false,
                    ["repairRequired"] = false,
                    ["requiresSecondExport"] = false,
                    ["requiresCpStudioChange"] = false,
                    ["proposedChanges"] = new JsonArray(),
                    ["appliedChanges"] = new JsonArray(),
                    ["failureStage"] = "session_health",
                    ["reasonCode"] = reasonCode
                }
            };
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            TryDeleteDirectory(testRoot);
        }
    }

    private static void CreateReviewedBaselines(string engineeringRoot)
    {
        var reviewRoot = Path.Combine(engineeringRoot, "docs", "reviews");
        var warningReviewPath = Path.Combine(reviewRoot, "warning-baseline-review.md");
        var semanticReviewPath = Path.Combine(reviewRoot, "engineering-semantic-review.md");
        WriteText(warningReviewPath, "# Warning baseline review\n\nFixture warning signatures reviewed.\n");
        WriteText(semanticReviewPath, "# Engineering semantic review\n\nFixture semantic facts reviewed.\n");

        var reviewedAtUtc = DateTimeOffset.UtcNow.AddMinutes(-1).ToString("O");
        WriteJson(Path.Combine(engineeringRoot, "config", "warning-signature-baseline.json"), new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-warning-signature-baseline",
            ["project"] = new JsonObject
            {
                ["plcProjectRelativePath"] = "Plc/Demo_PLC.project",
                ["profile"] = "ctrlX PLC 2.6.8"
            },
            ["signatureAlgorithm"] = "sha256:v1:normalized-warning-record",
            ["signatures"] = new JsonArray(),
            ["review"] = new JsonObject
            {
                ["reviewId"] = "stage2-ingestor-warning-review-v1",
                ["confirmedByUser"] = true,
                ["reviewedAtUtc"] = reviewedAtUtc,
                ["evidencePath"] = "docs/reviews/warning-baseline-review.md",
                ["evidenceSha256"] = RunnerHash.Sha256File(warningReviewPath)
            }
        });

        var semanticScopePath = Path.Combine(engineeringRoot, "config", "engineering-semantic-scope.json");
        WriteJson(semanticScopePath, new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-engineering-semantic-scope",
            ["project"] = new JsonObject
            {
                ["plcProjectRelativePath"] = "Plc/Demo_PLC.project",
                ["profile"] = "ctrlX PLC 2.6.8"
            },
            ["mappingScopes"] = new JsonArray
            {
                new JsonObject
                {
                    ["devicePath"] = "Device/Realtime_Data/DemoMaster",
                    ["recursive"] = true,
                    ["includeAllMappableChannels"] = true
                }
            },
            ["symbolApplicationPath"] = "Device/Plc Logic/Application"
        });

        var mapping = new JsonObject
        {
            ["scopeCount"] = 1,
            ["explicitTargetCount"] = 0,
            ["recordCount"] = 0,
            ["recordLimit"] = 2048,
            ["scopes"] = new JsonArray
            {
                new JsonObject
                {
                    ["scopeIndex"] = 0,
                    ["devicePath"] = "Device/Realtime_Data/DemoMaster",
                    ["recursive"] = true,
                    ["rootName"] = "DemoMaster",
                    ["recordCount"] = 0
                }
            },
            ["records"] = new JsonArray()
        };
        var symbol = new JsonObject
        {
            ["applicationPath"] = "Device/Plc Logic/Application",
            ["canonicalPayloadByteCount"] = 2,
            ["payloadSha256"] = RunnerHash.Sha256Text("{}"),
            ["shapeSummary"] = new JsonObject
            {
                ["rootKind"] = "object",
                ["topLevelKeys"] = new JsonArray(),
                ["objectCount"] = 1,
                ["arrayCount"] = 0,
                ["scalarCount"] = 0,
                ["nodeCount"] = 1,
                ["maxDepth"] = 0
            }
        };
        var canonicalFacts = new JsonObject
        {
            ["mapping"] = mapping,
            ["symbolConfig"] = symbol
        };
        var hashes = new JsonObject
        {
            ["algorithm"] = "SHA-256",
            ["canonicalization"] = "ctrlx-semantic-canonical-json-v1",
            ["mappingSha256"] = CanonicalJsonSha256(mapping),
            ["symbolConfigSha256"] = CanonicalJsonSha256(symbol),
            ["snapshotSha256"] = CanonicalJsonSha256(canonicalFacts)
        };
        WriteJson(Path.Combine(engineeringRoot, "config", "engineering-semantic-baseline.json"), new JsonObject
        {
            ["schemaVersion"] = 1,
            ["kind"] = "ctrlx-opcon-engineering-semantic-baseline",
            ["project"] = new JsonObject
            {
                ["plcProjectRelativePath"] = "Plc/Demo_PLC.project",
                ["profile"] = "ctrlX PLC 2.6.8"
            },
            ["scopeSha256"] = RunnerHash.Sha256File(semanticScopePath),
            ["canonicalFacts"] = canonicalFacts,
            ["hashes"] = hashes,
            ["review"] = new JsonObject
            {
                ["reviewId"] = "stage2-ingestor-semantic-review-v1",
                ["confirmedByUser"] = true,
                ["reviewedAtUtc"] = reviewedAtUtc,
                ["evidencePath"] = "docs/reviews/engineering-semantic-review.md",
                ["evidenceSha256"] = RunnerHash.Sha256File(semanticReviewPath)
            }
        });
    }

    private static JsonObject CreateStage1Audit(
        string engineeringRoot,
        string stationRoot,
        string plcProject,
        string requestId,
        DateTimeOffset requestedAtUtc)
    {
        var warningBaselinePath = Path.Combine(engineeringRoot, "config", "warning-signature-baseline.json");
        var warningReviewPath = Path.Combine(engineeringRoot, "docs", "reviews", "warning-baseline-review.md");
        var semanticScopePath = Path.Combine(engineeringRoot, "config", "engineering-semantic-scope.json");
        var semanticBaselinePath = Path.Combine(engineeringRoot, "config", "engineering-semantic-baseline.json");
        var semanticReviewPath = Path.Combine(engineeringRoot, "docs", "reviews", "engineering-semantic-review.md");
        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["auditedAtUtc"] = requestedAtUtc.AddSeconds(1).ToString("O"),
            ["auditStatus"] = "clean",
            ["readOnly"] = true,
            ["request"] = new JsonObject
            {
                ["requestId"] = requestId,
                ["requestedAtUtc"] = requestedAtUtc.ToString("O"),
                ["source"] = "CpStudio.PostExport",
                ["exportMode"] = "full",
                ["engineeringRoot"] = engineeringRoot,
                ["stationRoot"] = stationRoot,
                ["plcProject"] = plcProject
            },
            ["guardrails"] = new JsonObject
            {
                ["engineeringToolsStarted"] = false,
                ["generatedFilesWritten"] = false,
                ["onlineOperationsUsed"] = false,
                ["gitOptionalLocksDisabled"] = true
            },
            ["git"] = new JsonObject
            {
                ["available"] = true,
                ["optionalLocksDisabled"] = true,
                ["head"] = new string('1', 40),
                ["branch"] = "self-test",
                ["status"] = new JsonArray(" M Engineering/Engineering_Data.xml"),
                ["changedPaths"] = new JsonArray("Engineering/Engineering_Data.xml")
            },
            ["manifests"] = new JsonArray
            {
                FileFingerprint(Path.Combine(engineeringRoot, "ai", "ownership.yaml"), "ai/ownership.yaml"),
                FileFingerprint(Path.Combine(engineeringRoot, "ai", "hooks.yaml"), "ai/hooks.yaml"),
                FileFingerprint(Path.Combine(engineeringRoot, "ai", "graphical.yaml"), "ai/graphical.yaml")
            },
            ["warningBaseline"] = new JsonObject
            {
                ["state"] = "reviewed",
                ["path"] = "config/warning-signature-baseline.json",
                ["sha256"] = RunnerHash.Sha256File(warningBaselinePath),
                ["reviewEvidence"] = new JsonObject
                {
                    ["path"] = "docs/reviews/warning-baseline-review.md",
                    ["sha256"] = RunnerHash.Sha256File(warningReviewPath)
                }
            },
            ["semanticSnapshotRequest"] = new JsonObject
            {
                ["path"] = "config/engineering-semantic-scope.json",
                ["sha256"] = RunnerHash.Sha256File(semanticScopePath)
            },
            ["semanticBaseline"] = new JsonObject
            {
                ["state"] = "reviewed",
                ["path"] = "config/engineering-semantic-baseline.json",
                ["sha256"] = RunnerHash.Sha256File(semanticBaselinePath),
                ["reviewEvidence"] = new JsonObject
                {
                    ["path"] = "docs/reviews/engineering-semantic-review.md",
                    ["sha256"] = RunnerHash.Sha256File(semanticReviewPath)
                }
            },
            ["fingerprints"] = new JsonArray
            {
                FileFingerprint(
                    Path.Combine(stationRoot, "Engineering", "Engineering_Data.xml"),
                    "Engineering/Engineering_Data.xml"),
                FileFingerprint(plcProject, "Plc/Demo_PLC.project"),
                FileFingerprint(Path.Combine(stationRoot, "Plc", "Demo_IO.project"), "Plc/Demo_IO.project")
            },
            ["findings"] = new JsonArray(),
            ["nextStage"] = "controlled post-export engineering"
        };
    }

    private static JsonObject FileFingerprint(string path, string displayPath)
    {
        var info = new FileInfo(path);
        return new JsonObject
        {
            ["path"] = displayPath,
            ["exists"] = true,
            ["sizeBytes"] = info.Length,
            ["lastWriteTimeUtc"] = info.LastWriteTimeUtc.ToString("O"),
            ["sha256"] = RunnerHash.Sha256File(path)
        };
    }

    private static JsonObject CreateSemanticProofs()
    {
        var result = new JsonObject { ["contractVersion"] = 1 };
        foreach (var name in new[]
        {
            "ownership",
            "readback",
            "recoverableBaseline",
            "warnings",
            "semanticBaseline",
            "mapping",
            "symbolPostProcessing"
        })
        {
            result[name] = new JsonObject
            {
                ["producer"] = "stage2.fixture",
                ["contractVersion"] = 1,
                ["verified"] = true
            };
        }
        return result;
    }

    private static async Task<ProcessResult> RunPowerShell7Async(
        string workingDirectory,
        string scriptPath,
        params string[] arguments)
    {
        var powerShell7Path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "PowerShell",
            "7",
            "pwsh.exe");
        Require(File.Exists(powerShell7Path), "Program Files PowerShell 7 is unavailable.");
        var startInfo = new ProcessStartInfo
        {
            FileName = powerShell7Path,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.Environment.Remove("PSModulePath");
        foreach (var argument in new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            scriptPath
        }.Concat(arguments))
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        Require(process.Start(), "PowerShell 7 fixture process did not start.");
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        using var timeoutSource = new CancellationTokenSource(ProcessTimeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            throw new TimeoutException("PowerShell 7 fixture process exceeded its offline timeout.");
        }
        return new ProcessResult(
            process.ExitCode,
            await outputTask.ConfigureAwait(false),
            await errorTask.ConfigureAwait(false));
    }

    private static string FindRepositoryRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(
                current.FullName,
                "templates",
                "ctrlx-opcon-project",
                "scripts",
                "cpstudio",
                "Invoke-PostExportEngineering.ps1");
            if (File.Exists(candidate))
            {
                return current.FullName;
            }
            current = current.Parent;
        }
        throw new DirectoryNotFoundException("ctrlx-ai-coding repository root was not found.");
    }

    private static JsonObject ReadObject(string path) =>
        JsonNode.Parse(File.ReadAllBytes(path), nodeOptions: null, documentOptions: new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 64
        }) as JsonObject ?? throw new InvalidOperationException($"JSON root is not an object: {path}");

    private static string RequiredString(JsonObject value, string name) =>
        value[name] is JsonValue item && item.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text)
            ? text
            : throw new InvalidOperationException($"JSON object is missing string '{name}'.");

    private static void WriteJson(string path, JsonNode value) =>
        WriteText(path, value.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);

    private static void WriteText(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static string NormalizedScriptSha256(string path)
    {
        var source = File.ReadAllText(
            path,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true));
        return RunnerHash.Sha256Text(source.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n'));
    }

    private static string CanonicalJsonSha256(JsonNode value)
    {
        using var document = JsonDocument.Parse(value.ToJsonString());
        var builder = new StringBuilder();
        AppendCanonical(document.RootElement, builder);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())));
    }

    private static void AppendCanonical(JsonElement value, StringBuilder builder)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                builder.Append('{');
                var properties = value.EnumerateObject()
                    .OrderBy(property => property.Name, StringComparer.Ordinal)
                    .ToArray();
                for (var index = 0; index < properties.Length; index++)
                {
                    if (index > 0)
                    {
                        builder.Append(',');
                    }
                    AppendCanonicalString(properties[index].Name, builder);
                    builder.Append(':');
                    AppendCanonical(properties[index].Value, builder);
                }
                builder.Append('}');
                return;
            case JsonValueKind.Array:
                builder.Append('[');
                var first = true;
                foreach (var item in value.EnumerateArray())
                {
                    if (!first)
                    {
                        builder.Append(',');
                    }
                    first = false;
                    AppendCanonical(item, builder);
                }
                builder.Append(']');
                return;
            case JsonValueKind.String:
                AppendCanonicalString(value.GetString() ?? string.Empty, builder);
                return;
            case JsonValueKind.Number:
                builder.Append(value.GetRawText());
                return;
            case JsonValueKind.True:
                builder.Append("true");
                return;
            case JsonValueKind.False:
                builder.Append("false");
                return;
            case JsonValueKind.Null:
                builder.Append("null");
                return;
            default:
                throw new InvalidOperationException($"Unsupported canonical JSON kind: {value.ValueKind}.");
        }
    }

    private static void AppendCanonicalString(string value, StringBuilder builder)
    {
        builder.Append('"');
        foreach (var character in value)
        {
            switch (character)
            {
                case '\b': builder.Append("\\b"); break;
                case '\t': builder.Append("\\t"); break;
                case '\n': builder.Append("\\n"); break;
                case '\f': builder.Append("\\f"); break;
                case '\r': builder.Append("\\r"); break;
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                default:
                    if (character < 0x20)
                    {
                        builder.Append($"\\u{(int)character:x4}");
                    }
                    else
                    {
                        builder.Append(character);
                    }
                    break;
            }
        }
        builder.Append('"');
    }

    private static string Limit(string value)
    {
        var normalized = value.Trim().Replace('\r', ' ').Replace('\n', ' ');
        return normalized.Length <= 2_000 ? normalized : normalized[..2_000] + "...";
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // Temporary failure evidence must not hide the actual assertion.
        }
    }

    private sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);

    private sealed record ProcessItem(string Name, int ProcessId);

    private sealed class EngineeringProcessSnapshot
    {
        private static readonly string[] WatchedNames =
        {
            "ctrlX-PLC-Engineering",
            "ctrlX-IO-Engineering",
            "node"
        };

        private readonly Dictionary<string, HashSet<int>> processIds;

        private EngineeringProcessSnapshot(Dictionary<string, HashSet<int>> processIds)
        {
            this.processIds = processIds;
        }

        public static EngineeringProcessSnapshot Capture()
        {
            var result = new Dictionary<string, HashSet<int>>(StringComparer.OrdinalIgnoreCase);
            foreach (var name in WatchedNames)
            {
                result[name] = Process.GetProcessesByName(name).Select(process => process.Id).ToHashSet();
            }
            return new EngineeringProcessSnapshot(result);
        }

        public IReadOnlyList<ProcessItem> AddedSince(EngineeringProcessSnapshot before)
        {
            var added = new List<ProcessItem>();
            foreach (var pair in processIds)
            {
                before.processIds.TryGetValue(pair.Key, out var prior);
                prior ??= new HashSet<int>();
                added.AddRange(pair.Value.Where(processId => !prior.Contains(processId))
                    .Select(processId => new ProcessItem(pair.Key, processId)));
            }
            return added;
        }
    }
}
