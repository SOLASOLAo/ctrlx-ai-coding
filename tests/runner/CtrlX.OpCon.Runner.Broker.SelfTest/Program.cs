using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker;
using CtrlX.OpCon.Runner.Broker.Infrastructure;
using CtrlX.OpCon.Runner.Broker.Mcp;
using CtrlX.OpCon.Runner.Broker.Session;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.SelfTest;

internal static class Program
{
    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("both allowlisted actions execute serially", BothAllowlistedActionsExecuteSeriallyAsync),
            ("duplicate submit executes once", DuplicateSubmitExecutesOnceAsync),
            ("session verification failure is terminal blocked", VerificationFailureIsTerminalBlockedAsync),
            ("execution exception is terminal review", ExecutionExceptionRequiresReviewAsync),
            ("canceled action is terminal review", CanceledActionIsTerminalReviewAsync),
            ("invalid recovered action is quarantined without blocking Broker", InvalidRecoveredActionIsQuarantinedAsync),
            ("replayed ACCEPTED action is normalized and executes once", ReplayedAcceptedActionIsNormalizedAsync),
            ("orphaned blocked observation is recovered without Build", OrphanedBlockedObservationIsRecoveredAsync),
            ("conflicting orphan observation becomes terminal review", ConflictingOrphanObservationRequiresReviewAsync),
            ("malformed pipe clients do not stop accept loop", MalformedPipeClientsDoNotStopAcceptLoopAsync),
            ("active foreign registration cannot be overwritten", ActiveForeignRegistrationCannotBeOverwrittenAsync),
            ("host drains admitted work and preserves primary failure", HostDrainsAndPreservesPrimaryFailureAsync)
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
            Console.WriteLine("Broker offline self-test passed. No Node, MCP, or PLE process was started.");
            return 0;
        }

        Console.Error.WriteLine($"Broker offline self-test failed: {failures.Count} case(s).");
        return 1;
    }

    private static async Task BothAllowlistedActionsExecuteSeriallyAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.FromMilliseconds(80));
        var dispatcher = fixture.CreateDispatcher(session);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);

        var inspect = fixture.CreateAction("inspect", "inspect_and_build");
        var verify = fixture.CreateAction("verify", "verify_after_export_2");
        var inspectReceipt = dispatcher.Submit(inspect);
        var verifyReceipt = dispatcher.Submit(verify);

        await dispatcher.DrainAsync().ConfigureAwait(false);

        var inspectResult = Query(dispatcher, inspectReceipt, inspect);
        var verifyResult = Query(dispatcher, verifyReceipt, verify);
        Require(inspectReceipt.Accepted && verifyReceipt.Accepted, "Both allowlisted actions must be accepted.");
        Require(inspectResult.Terminal && inspectResult.State == BrokerOperationStates.Succeeded,
            "inspect_and_build must finish successfully.");
        Require(verifyResult.Terminal && verifyResult.State == BrokerOperationStates.Succeeded,
            "verify_after_export_2 must finish successfully.");
        Require(session.ExecuteCalls == 2, "The fake engineering session must execute both actions exactly once.");
        Require(session.MaximumConcurrentExecutions == 1, "Engineering actions must be serialized through one session gate.");
        Require(session.ExecutedKinds.Order().SequenceEqual(new[] { "inspect_and_build", "verify_after_export_2" }),
            "Only the two allowlisted action kinds should have reached the engineering session.");
    }

    private static async Task DuplicateSubmitExecutesOnceAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero, holdExecution: true);
        var dispatcher = fixture.CreateDispatcher(session);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);

        var action = fixture.CreateAction("duplicate", "inspect_and_build");
        var first = dispatcher.Submit(action);
        await session.WaitUntilExecutionEnteredAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        var replay = dispatcher.Submit(action);

        Require(first.Disposition == "ACCEPTED", "The first Submit must be accepted as new work.");
        Require(replay.Disposition == "REPLAYED", "The duplicate Submit must replay the durable receipt.");
        Require(first.ExecutionId == replay.ExecutionId, "Duplicate Submit must preserve the execution ID.");

        session.ReleaseExecution();
        await dispatcher.DrainAsync().ConfigureAwait(false);

        var result = Query(dispatcher, replay, action);
        Require(session.ExecuteCalls == 1, "Duplicate Submit must not execute engineering work twice.");
        Require(result.Terminal && result.State == BrokerOperationStates.Succeeded,
            "The single durable execution must still complete successfully.");
    }

    private static async Task VerificationFailureIsTerminalBlockedAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.VerificationFailure(
            "BROKER_SESSION_IDENTITY_CHANGED");
        var dispatcher = fixture.CreateDispatcher(session);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);

        var action = fixture.CreateAction("verify-failure", "verify_after_export_2");
        var receipt = dispatcher.Submit(action);
        await dispatcher.DrainAsync().ConfigureAwait(false);

        var result = Query(dispatcher, receipt, action);
        Require(result.Terminal, "A failure before an engineering call must be terminal.");
        Require(result.State == BrokerOperationStates.Blocked, "Session verification failure must be BLOCKED.");
        Require(result.ReasonCode == "BROKER_SESSION_IDENTITY_CHANGED",
            "The terminal observation must preserve the safe verification reason code.");
        Require(result.Observation?["status"]?.GetValue<string>() == "blocked",
            "The durable terminal observation must report blocked status.");
        var guardrails = result.Observation?["guardrails"] as JsonObject
            ?? throw new InvalidOperationException("Blocked observation guardrails are missing.");
        Require(guardrails["actionProjectGateAcquired"]?.GetValue<bool>() == true,
            "Delivered terminal observation did not report the acquired action serialization gate.");
        Require(guardrails["actionProjectGateReleased"]?.GetValue<bool>() == true,
            "Delivered terminal observation did not report the released action serialization gate.");
        Require(guardrails["actionProjectGateKind"]?.GetValue<string>() == "broker-session-action-serialization",
            "Delivered terminal observation reported an ambiguous action gate kind.");
        Require(guardrails["pleOrMcpStartedByAction"]?.GetValue<bool>() == false,
            "Verification action incorrectly claimed that it started PLE/MCP.");
        Require(session.ExecuteCalls == 0, "Engineering execution must not start after verification fails.");
    }

    private static async Task ExecutionExceptionRequiresReviewAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.ExecutionFailure();
        var dispatcher = fixture.CreateDispatcher(session);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);

        var action = fixture.CreateAction("execute-failure", "inspect_and_build");
        var receipt = dispatcher.Submit(action);
        await dispatcher.DrainAsync().ConfigureAwait(false);

        var result = Query(dispatcher, receipt, action);
        Require(result.State == BrokerOperationStates.UnknownReviewRequired,
            "An exception after the engineering call begins must become UNKNOWN_REVIEW_REQUIRED.");
        Require(result.Terminal && result.ReviewRequired,
            "UNKNOWN_REVIEW_REQUIRED must be a queryable terminal review outcome.");
        Require(result.Observation is null, "An uncertain engineering result must not invent terminal evidence.");
        Require(result.ReasonCode == "BROKER_INTERNAL_FAILURE", "Unexpected execution exceptions must use a safe reason code.");
        Require(result.State != BrokerOperationStates.Succeeded && result.ReasonCode != "BUILD_VERIFIED",
            "An uncertain engineering result must never be reported as success.");
        Require(session.ExecuteCalls == 1, "The failing engineering action must have been called exactly once.");
    }

    private static async Task CanceledActionIsTerminalReviewAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        const string brokerInstanceId = "fixture-cancel-broker";
        var store = fixture.CreateStore();
        var dispatcher = fixture.CreateDispatcher(session, brokerInstanceId, store);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);

        var action = fixture.CreateAction("cancel-before-dispatch", "inspect_and_build");
        var accepted = store.Accept(BrokerFixture.Identity(action), brokerInstanceId);
        var canceled = store.RequestCancellation(accepted.Operation.ExecutionId, brokerInstanceId);
        var result = dispatcher.Query(
            accepted.Operation.ExecutionId,
            action.ActionId,
            action.ActionSha256,
            action.IdempotencyKey);

        Require(canceled.Disposition == BrokerCancellationDisposition.CanceledBeforeDispatch,
            "Fixture action was not canceled before dispatch.");
        Require(result.Terminal && result.ReviewRequired && result.State == BrokerOperationStates.Canceled,
            "CANCELED must be returned as a terminal review outcome.");
        Require(result.Observation is null && result.Session is null,
            "Canceled action must not fabricate session or observation evidence.");
        Require(session.ExecuteCalls == 0, "Canceled action reached engineering execution.");
    }

    private static async Task InvalidRecoveredActionIsQuarantinedAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        var store = fixture.CreateStore();
        var staleAction = fixture.CreateAction("missing-recovery-action", "inspect_and_build");
        var stale = store.Accept(BrokerFixture.Identity(staleAction), "fixture-old-broker");
        const string brokerInstanceId = "fixture-recovery-broker";
        var dispatcher = fixture.CreateDispatcher(session, brokerInstanceId, store);

        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);
        var recovered = dispatcher.Query(
            stale.Operation.ExecutionId,
            staleAction.ActionId,
            staleAction.ActionSha256,
            staleAction.IdempotencyKey);

        Require(recovered.Terminal && recovered.ReviewRequired,
            "Missing recovered action did not become terminal review.");
        Require(recovered.ReasonCode == "BROKER_RECOVERY_ACTION_INVALID",
            "Recovered action quarantine reason changed.");

        var healthy = fixture.CreateAction("healthy-after-bad-recovery", "verify_after_export_2");
        var receipt = dispatcher.Submit(healthy);
        await dispatcher.DrainAsync().ConfigureAwait(false);
        var healthyResult = Query(dispatcher, receipt, healthy);
        Require(healthyResult.Terminal && healthyResult.State == BrokerOperationStates.Succeeded,
            "One invalid recovered action prevented later healthy work.");
        Require(session.ExecuteCalls == 1,
            "Invalid recovered action was replayed or healthy action did not execute exactly once.");
    }

    private static async Task ReplayedAcceptedActionIsNormalizedAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        const string brokerInstanceId = "fixture-accepted-broker";
        var store = fixture.CreateStore();
        var dispatcher = fixture.CreateDispatcher(session, brokerInstanceId, store);
        var action = fixture.CreateAction("accepted-replay", "inspect_and_build");
        var accepted = store.Accept(BrokerFixture.Identity(action), brokerInstanceId);

        var replay = dispatcher.Submit(action);
        await dispatcher.DrainAsync().ConfigureAwait(false);
        var operation = store.Read(accepted.Operation.ExecutionId);

        Require(replay.Disposition == "REPLAYED" && replay.State == BrokerOperationStates.Queued,
            "Replayed ACCEPTED operation was not synchronously normalized to QUEUED.");
        Require(operation.State == BrokerOperationStates.Succeeded,
            "Normalized ACCEPTED operation did not reach a legal terminal state.");
        Require(session.ExecuteCalls == 1, "Normalized ACCEPTED operation executed more than once.");
    }

    private static async Task OrphanedBlockedObservationIsRecoveredAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        const string brokerInstanceId = "fixture-orphan-broker";
        var store = fixture.CreateStore();
        var dispatcher = fixture.CreateDispatcher(session, brokerInstanceId, store);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);
        var action = fixture.CreateAction("orphan-blocked", "inspect_and_build");
        var accepted = store.Accept(BrokerFixture.Identity(action), brokerInstanceId);
        _ = store.Transition(
            accepted.Operation.ExecutionId,
            brokerInstanceId,
            BrokerOperationStates.Queued,
            "FIXTURE_QUEUED");
        fixture.WriteObservation(
            accepted.Operation.ExecutionId,
            BlockedObservation(action, "BROKER_SESSION_IDENTITY_CHANGED"));

        var replay = dispatcher.Submit(action);
        await dispatcher.DrainAsync().ConfigureAwait(false);
        var result = Query(dispatcher, replay, action);

        Require(result.Terminal && !result.ReviewRequired && result.State == BrokerOperationStates.Blocked,
            "Valid orphaned blocked observation was not reconciled.");
        Require(result.ReasonCode == "BROKER_SESSION_IDENTITY_CHANGED",
            "Recovered blocked observation lost its reason code.");
        Require(session.ExecuteCalls == 0, "Orphaned pre-dispatch observation caused a duplicate Build.");
    }

    private static async Task ConflictingOrphanObservationRequiresReviewAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        const string brokerInstanceId = "fixture-conflict-broker";
        var store = fixture.CreateStore();
        var dispatcher = fixture.CreateDispatcher(session, brokerInstanceId, store);
        await dispatcher.InitializeAsync(CancellationToken.None).ConfigureAwait(false);
        var action = fixture.CreateAction("orphan-conflict", "inspect_and_build");
        var accepted = store.Accept(BrokerFixture.Identity(action), brokerInstanceId);
        _ = store.Transition(
            accepted.Operation.ExecutionId,
            brokerInstanceId,
            BrokerOperationStates.Queued,
            "FIXTURE_QUEUED");
        var conflicting = BlockedObservation(action, "BROKER_SESSION_IDENTITY_CHANGED");
        conflicting["actionId"] = "different-action";
        fixture.WriteObservation(accepted.Operation.ExecutionId, conflicting);

        var replay = dispatcher.Submit(action);
        await dispatcher.DrainAsync().ConfigureAwait(false);
        var result = Query(dispatcher, replay, action);

        Require(result.Terminal && result.ReviewRequired &&
                result.State == BrokerOperationStates.UnknownReviewRequired,
            "Conflicting immutable observation was not quarantined as terminal review.");
        Require(result.ReasonCode == "BROKER_ORPHAN_OBSERVATION_INVALID",
            "Conflicting orphan observation reason changed.");
        Require(session.ExecuteCalls == 0, "Conflicting orphan observation caused a duplicate Build.");
    }

    private static async Task MalformedPipeClientsDoNotStopAcceptLoopAsync()
    {
        using var fixture = new BrokerFixture();
        await using var session = FakeEngineeringSession.Success(TimeSpan.Zero);
        var dispatcher = fixture.CreateDispatcher(session);
        var pipeName = $"ctrlx-opcon-selftest-{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource();
        var serverTask = new BrokerNamedPipeServer(pipeName, "fixture-pipe", dispatcher)
            .RunAsync(cancellation.Token);

        await SendMalformedFrameAsync(pipeName, [0xc3, 0x28, (byte)'\n']).ConfigureAwait(false);
        await SendMalformedFrameAsync(pipeName, Encoding.UTF8.GetBytes("{not-json}\n")).ConfigureAwait(false);
        await SendMalformedFrameAsync(pipeName, []).ConfigureAwait(false);

        Require(!serverTask.IsCompleted,
            "Invalid UTF-8, invalid JSON, and a short-lived client must be isolated to their connections.");
        cancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    private static Task ActiveForeignRegistrationCannotBeOverwrittenAsync()
    {
        using var fixture = new BrokerFixture();
        var registration = fixture.CreateRegistrationStore();
        try
        {
            var first = registration.Publish(
                "fixture-owner-one",
                "ctrlx-opcon-owner-one",
                41001,
                41002,
                "fixture-session-one",
                BrokerRegistrationStates.Ready,
                TimeSpan.FromSeconds(10));
            BrokerInfrastructureException? rejection = null;
            try
            {
                _ = registration.Publish(
                    "fixture-owner-two",
                    "ctrlx-opcon-owner-two",
                    42001,
                    42002,
                    "fixture-session-two",
                    BrokerRegistrationStates.Ready,
                    TimeSpan.FromSeconds(10));
            }
            catch (BrokerInfrastructureException exception)
            {
                rejection = exception;
            }

            var current = registration.Read();
            Require(rejection?.ReasonCode == "BROKER_REGISTRATION_ACTIVE_OWNER",
                "Publish must reject an unexpired registration owned by another Broker instance.");
            Require(current.BrokerInstanceId == first.BrokerInstanceId &&
                current.PipeName == first.PipeName,
                "A rejected publisher must not alter the active registration.");
        }
        finally
        {
            fixture.DeleteRegistrationFiles();
        }

        return Task.CompletedTask;
    }

    private static async Task HostDrainsAndPreservesPrimaryFailureAsync()
    {
        using var fixture = new BrokerFixture();
        var session = FakeEngineeringSession.Success(
            TimeSpan.Zero,
            holdExecution: true,
            failStop: true);
        var action = fixture.CreateAction("host-drain", "inspect_and_build");
        var acceptFailure = new BrokerInfrastructureException(
            "BROKER_TEST_ACCEPT_FAILED",
            "Fixture accept loop failed after admitting work.");
        var host = new BrokerHost(
            fixture.Options,
            session,
            (_, _, dispatcher) => new FailingPipeServer(dispatcher, action, acceptFailure));
        var hostTask = host.RunAsync(CancellationToken.None);

        await session.WaitUntilExecutionEnteredAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        await Task.Delay(100).ConfigureAwait(false);
        Require(session.StopCalls == 0 && session.DisposeCalls == 0 && !hostTask.IsCompleted,
            "Host teardown must wait while an admitted engineering call is still active.");

        session.ReleaseExecution();
        Exception? observed = null;
        try
        {
            await hostTask.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            observed = exception;
        }

        Require(observed is BrokerInfrastructureException infrastructure &&
            infrastructure.ReasonCode == "BROKER_TEST_ACCEPT_FAILED",
            "A teardown failure must not replace the original accept-loop failure.");
        Require(session.StopCalls == 1 && session.DisposeCalls == 1,
            "Host must attempt both Stop and Dispose even when Stop fails.");
        Require(session.StopObservedActiveExecutions == 0 && session.DisposeObservedActiveExecutions == 0,
            "Drain must complete before the engineering session is stopped or disposed.");
        Require(observed!.Data.Contains("BrokerCleanupFailures"),
            "Secondary cleanup failures must be attached to, not replace, the primary failure.");
        fixture.DeleteRegistrationFiles();
    }

    private static async Task SendMalformedFrameAsync(string pipeName, byte[] bytes)
    {
        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
        if (bytes.Length > 0)
        {
            await client.WriteAsync(bytes, timeout.Token).ConfigureAwait(false);
            await client.FlushAsync(timeout.Token).ConfigureAwait(false);
        }
    }

    private static JsonObject BlockedObservation(ValidatedRunnerAction action, string reasonCode) => new()
    {
        ["schemaVersion"] = 1,
        ["operationId"] = action.OperationId,
        ["actionId"] = action.ActionId,
        ["actionKind"] = action.ActionKind,
        ["actionRequestSha256"] = action.ActionSha256,
        ["status"] = "blocked",
        ["result"] = new JsonObject
        {
            ["reasonCode"] = reasonCode
        }
    };

    private static BrokerQueryResult Query(
        BrokerActionDispatcher dispatcher,
        BrokerDispatchReceipt receipt,
        ValidatedRunnerAction action) =>
        dispatcher.Query(
            receipt.ExecutionId,
            action.ActionId,
            action.ActionSha256,
            action.IdempotencyKey);

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

internal sealed class BrokerFixture : IDisposable
{
    private readonly BrokerRuntimePaths runtimePaths;
    private int actionSequence;

    public BrokerFixture()
    {
        Root = Path.Combine(Path.GetTempPath(), $"ctrlx-opcon-broker-selftest-{Guid.NewGuid():N}");
        EngineeringRoot = Path.Combine(Root, "Engineering");
        StationRoot = Path.Combine(Root, "Station");
        PlcProject = Path.Combine(StationRoot, "Plc", "Fixture.project");
        Directory.CreateDirectory(EngineeringRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(PlcProject)!);
        File.WriteAllBytes(PlcProject, [1, 3, 3, 7]);

        var inertExecutable = Path.Combine(Root, "never-started-mcp.exe");
        File.WriteAllText(inertExecutable, "This inert fixture file must never be executed.", new UTF8Encoding(false));
        Options = new BrokerHostOptions
        {
            EngineeringRoot = EngineeringRoot,
            StationRoot = StationRoot,
            PlcProject = PlcProject,
            Profile = "ctrlX PLC 2.6.8",
            Mcp = new McpProcessOptions
            {
                ExecutablePath = inertExecutable,
                WorkingDirectory = Root
            }
        };
        runtimePaths = new BrokerRuntimePaths(EngineeringRoot, StationRoot, Options.Profile, PlcProject);
    }

    public string Root { get; }

    public string EngineeringRoot { get; }

    public string StationRoot { get; }

    public string PlcProject { get; }

    public BrokerHostOptions Options { get; }

    public BrokerOperationStore CreateStore() => new(runtimePaths, TimeSpan.FromSeconds(1));

    public BrokerRegistrationStore CreateRegistrationStore() => new(runtimePaths);

    public void DeleteRegistrationFiles()
    {
        foreach (var path in new[] { runtimePaths.RegistrationPath, runtimePaths.RegistrationPath + ".lock" })
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    public BrokerActionDispatcher CreateDispatcher(IBrokerEngineeringSession session) =>
        CreateDispatcher(session, $"fixture-{Guid.NewGuid():N}", CreateStore());

    public BrokerActionDispatcher CreateDispatcher(
        IBrokerEngineeringSession session,
        string brokerInstanceId,
        BrokerOperationStore store) => new(
        Options,
        brokerInstanceId,
        session,
        store);

    public static BrokerOperationIdentity Identity(ValidatedRunnerAction action) => new(
        action.ActionId,
        action.ActionSha256,
        action.IdempotencyKey,
        action.ActionKind);

    public void WriteObservation(string executionId, JsonObject observation)
    {
        var path = Path.Combine(runtimePaths.OperationDirectory(executionId), "observation.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, observation.ToJsonString(), new UTF8Encoding(false));
    }

    public ValidatedRunnerAction CreateAction(string name, string actionKind)
    {
        var sequence = Interlocked.Increment(ref actionSequence);
        var operationId = $"fixture-{name}-{sequence:0000}";
        var actionId = $"{operationId}-0001";
        var actionPath = Path.Combine(
            EngineeringRoot,
            "data",
            "operations",
            operationId,
            "actions",
            $"0001-{actionKind}.json");
        var actionSha = RunnerHash.Sha256Text($"action|{actionId}|{actionKind}");
        var idempotencyKey = RunnerHash.Sha256Text($"idempotency|{actionId}");
        return new ValidatedRunnerAction(
            EngineeringRoot,
            StationRoot,
            PlcProject,
            Options.Profile,
            actionPath,
            actionSha,
            operationId,
            actionId,
            actionKind,
            1,
            DateTimeOffset.UtcNow.AddMinutes(-1),
            idempotencyKey,
            IsSupported: true,
            UnsupportedReasonCode: null,
            Document: new JsonObject
            {
                ["actionId"] = actionId,
                ["actionKind"] = actionKind
            });
    }

    public void Dispose()
    {
        DeleteRegistrationFiles();
        DeleteDirectory(runtimePaths.IdentityRoot);
        DeleteDirectory(Root);
    }

    private static void DeleteDirectory(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
        }
    }
}

internal sealed class FakeEngineeringSession : IBrokerEngineeringSession
{
    private readonly TimeSpan executionDelay;
    private readonly string? verificationFailureReason;
    private readonly bool failExecution;
    private readonly bool failStop;
    private readonly TaskCompletionSource? executionRelease;
    private readonly TaskCompletionSource executionEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly ConcurrentQueue<string> executedKinds = new();
    private int activeExecutions;
    private int executeCalls;
    private int maximumConcurrentExecutions;
    private int stopCalls;
    private int disposeCalls;
    private int stopObservedActiveExecutions = -1;
    private int disposeObservedActiveExecutions = -1;

    private FakeEngineeringSession(
        TimeSpan executionDelay,
        string? verificationFailureReason,
        bool failExecution,
        bool holdExecution,
        bool failStop)
    {
        this.executionDelay = executionDelay;
        this.verificationFailureReason = verificationFailureReason;
        this.failExecution = failExecution;
        this.failStop = failStop;
        executionRelease = holdExecution
            ? new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)
            : null;
    }

    public int ExecuteCalls => Volatile.Read(ref executeCalls);

    public int MaximumConcurrentExecutions => Volatile.Read(ref maximumConcurrentExecutions);

    public IReadOnlyCollection<string> ExecutedKinds => executedKinds.ToArray();

    public int StopCalls => Volatile.Read(ref stopCalls);

    public int DisposeCalls => Volatile.Read(ref disposeCalls);

    public int StopObservedActiveExecutions => Volatile.Read(ref stopObservedActiveExecutions);

    public int DisposeObservedActiveExecutions => Volatile.Read(ref disposeObservedActiveExecutions);

    public static FakeEngineeringSession Success(
        TimeSpan delay,
        bool holdExecution = false,
        bool failStop = false) =>
        new(delay, verificationFailureReason: null, failExecution: false, holdExecution, failStop);

    public static FakeEngineeringSession VerificationFailure(string reasonCode) =>
        new(TimeSpan.Zero, reasonCode, failExecution: false, holdExecution: false, failStop: false);

    public static FakeEngineeringSession ExecutionFailure() =>
        new(TimeSpan.Zero, verificationFailureReason: null, failExecution: true, holdExecution: false, failStop: false);

    public Task<BrokerSessionRuntime> StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Runtime());
    }

    public Task<BrokerSessionRuntime> VerifyReadyAsync(
        ValidatedRunnerAction action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (verificationFailureReason is not null)
        {
            throw new BrokerEngineeringException(
                verificationFailureReason,
                "Fixture rejected the persistent session identity.");
        }

        return Task.FromResult(Runtime(action));
    }

    public async Task<BrokerEngineeringOutcome> ExecuteAsync(
        ValidatedRunnerAction action,
        BrokerSessionRuntime expectedSession,
        CancellationToken cancellationToken)
    {
        _ = expectedSession;
        cancellationToken.ThrowIfCancellationRequested();
        Interlocked.Increment(ref executeCalls);
        executedKinds.Enqueue(action.ActionKind);
        var current = Interlocked.Increment(ref activeExecutions);
        UpdateMaximum(current);
        executionEntered.TrySetResult();
        try
        {
            if (executionRelease is not null)
            {
                await executionRelease.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            }

            if (executionDelay > TimeSpan.Zero)
            {
                await Task.Delay(executionDelay, cancellationToken).ConfigureAwait(false);
            }

            if (failExecution)
            {
                throw new InvalidOperationException("Fixture failure after engineering execution started.");
            }

            return new BrokerEngineeringOutcome(
                "SUCCEEDED",
                "BUILD_VERIFIED",
                new JsonObject
                {
                    ["schemaVersion"] = 1,
                    ["operationId"] = action.OperationId,
                    ["actionId"] = action.ActionId,
                    ["actionKind"] = action.ActionKind,
                    ["actionRequestSha256"] = action.ActionSha256,
                    ["status"] = "succeeded"
                });
        }
        finally
        {
            Interlocked.Decrement(ref activeExecutions);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Interlocked.Increment(ref stopCalls);
        Volatile.Write(ref stopObservedActiveExecutions, Volatile.Read(ref activeExecutions));
        if (failStop)
        {
            throw new InvalidOperationException("Fixture Stop cleanup failed.");
        }

        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        Interlocked.Increment(ref disposeCalls);
        Volatile.Write(ref disposeObservedActiveExecutions, Volatile.Read(ref activeExecutions));
        return ValueTask.CompletedTask;
    }

    public Task WaitUntilExecutionEnteredAsync(TimeSpan timeout) => executionEntered.Task.WaitAsync(timeout);

    public void ReleaseExecution() => executionRelease?.TrySetResult();

    private static BrokerSessionRuntime Runtime(ValidatedRunnerAction? action = null) => new(
        McpPid: 41001,
        PlePid: 41002,
        PersistentSessionId: "fixture-session",
        Profile: action?.Profile ?? "ctrlX PLC 2.6.8",
        ActiveProjectPath: action?.PlcProject ?? Path.GetFullPath("fixture.project"),
        PleOwnedByBroker: false);

    private void UpdateMaximum(int current)
    {
        while (true)
        {
            var observed = Volatile.Read(ref maximumConcurrentExecutions);
            if (current <= observed ||
                Interlocked.CompareExchange(ref maximumConcurrentExecutions, current, observed) == observed)
            {
                return;
            }
        }
    }
}

internal sealed class FailingPipeServer : IBrokerPipeServer
{
    private readonly BrokerActionDispatcher dispatcher;
    private readonly ValidatedRunnerAction action;
    private readonly Exception failure;

    public FailingPipeServer(
        BrokerActionDispatcher dispatcher,
        ValidatedRunnerAction action,
        Exception failure)
    {
        this.dispatcher = dispatcher;
        this.action = action;
        this.failure = failure;
    }

    public Task RunAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _ = dispatcher.Submit(action);
        return Task.FromException(failure);
    }
}
