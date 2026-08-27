using System.Runtime.ExceptionServices;
using CtrlX.OpCon.Runner.Broker.Infrastructure;
using CtrlX.OpCon.Runner.Broker.Mcp;
using CtrlX.OpCon.Runner.Broker.Session;

namespace CtrlX.OpCon.Runner.Broker;

public sealed class BrokerHost
{
    private readonly BrokerHostOptions options;
    private readonly IBrokerEngineeringSession engineeringSession;
    private readonly Func<string, string, BrokerActionDispatcher, IBrokerPipeServer> pipeServerFactory;

    public BrokerHost(BrokerHostOptions options)
        : this(
            options,
            new BrokerEngineeringSession(new JsonLineMcpClient(options.Mcp), options),
            static (pipeName, instanceId, dispatcher) => new BrokerNamedPipeServer(pipeName, instanceId, dispatcher))
    {
    }

    public BrokerHost(BrokerHostOptions options, IBrokerEngineeringSession engineeringSession)
        : this(
            options,
            engineeringSession,
            static (pipeName, instanceId, dispatcher) => new BrokerNamedPipeServer(pipeName, instanceId, dispatcher))
    {
    }

    public BrokerHost(
        BrokerHostOptions options,
        IBrokerEngineeringSession engineeringSession,
        Func<string, string, BrokerActionDispatcher, IBrokerPipeServer> pipeServerFactory)
    {
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.engineeringSession = engineeringSession ?? throw new ArgumentNullException(nameof(engineeringSession));
        this.pipeServerFactory = pipeServerFactory ?? throw new ArgumentNullException(nameof(pipeServerFactory));
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        options.Validate();
        var paths = new BrokerRuntimePaths(
            options.EngineeringRoot,
            options.StationRoot,
            options.Profile,
            options.PlcProject);
        var instanceId = Guid.NewGuid().ToString("N");
        var pipeName = $"ctrlx-opcon-{paths.IdentityKey[..24].ToLowerInvariant()}-{instanceId[..12]}";
        var owner = BrokerOwnerLease.Acquire(paths, instanceId, options.OwnerLeaseTimeout);
        var registration = new BrokerRegistrationStore(paths);
        var operationStore = new BrokerOperationStore(paths);
        var dispatcher = new BrokerActionDispatcher(
            options,
            instanceId,
            engineeringSession,
            operationStore);
        var published = false;
        Task? serverTask = null;
        Task? heartbeatTask = null;
        Exception? primaryFailure = null;
        var cleanupFailures = new List<Exception>();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        try
        {
            await dispatcher.InitializeAsync(lifetime.Token).ConfigureAwait(false);
            var runtime = dispatcher.Runtime;
            registration.Publish(
                instanceId,
                pipeName,
                runtime.McpPid,
                runtime.PlePid,
                runtime.PersistentSessionId,
                BrokerRegistrationStates.Ready,
                options.HeartbeatTtl);
            published = true;

            var pipeServer = pipeServerFactory(pipeName, instanceId, dispatcher);
            serverTask = pipeServer.RunAsync(lifetime.Token);
            heartbeatTask = HeartbeatAsync(registration, instanceId, lifetime.Token);
            var first = await Task.WhenAny(serverTask, heartbeatTask).ConfigureAwait(false);
            await first.ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            primaryFailure = exception;
        }
        finally
        {
            // Stop admission first. Work already admitted by the dispatcher uses
            // CancellationToken.None and must reach a durable outcome before the
            // engineering session is stopped or disposed.
            lifetime.Cancel();
            await CaptureBackgroundCleanupAsync(serverTask, ignoreCancellation: true).ConfigureAwait(false);
            await CaptureBackgroundCleanupAsync(heartbeatTask, ignoreCancellation: true).ConfigureAwait(false);

            if (published)
            {
                CaptureCleanup(() => registration.Heartbeat(
                    instanceId,
                    BrokerRegistrationStates.Draining,
                    options.HeartbeatTtl));
            }

            await CaptureCleanupAsync(
                dispatcher.DrainAsync,
                ignoreCancellation: false).ConfigureAwait(false);
            await CaptureCleanupAsync(
                () => engineeringSession.StopAsync(CancellationToken.None),
                ignoreCancellation: false).ConfigureAwait(false);
            await CaptureCleanupAsync(
                () => engineeringSession.DisposeAsync().AsTask(),
                ignoreCancellation: false).ConfigureAwait(false);
            if (published)
            {
                CaptureCleanup(() => registration.RemoveIfOwned(instanceId));
            }

            CaptureCleanup(owner.Dispose);
        }

        if (primaryFailure is not null)
        {
            AttachCleanupFailures(primaryFailure, cleanupFailures);
            ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        }

        if (cleanupFailures.Count == 1)
        {
            ExceptionDispatchInfo.Capture(cleanupFailures[0]).Throw();
        }

        if (cleanupFailures.Count > 1)
        {
            throw new AggregateException("Broker cleanup failed.", cleanupFailures);
        }

        return;

        Task CaptureBackgroundCleanupAsync(Task? task, bool ignoreCancellation) => task is null
            ? Task.CompletedTask
            : CaptureCleanupAsync(() => task, ignoreCancellation);

        async Task CaptureCleanupAsync(Func<Task> action, bool ignoreCancellation)
        {
            try
            {
                await action().ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ignoreCancellation)
            {
                // Cancellation is expected after admission has been stopped.
            }
            catch (Exception exception)
            {
                if (!ReferenceEquals(exception, primaryFailure))
                {
                    cleanupFailures.Add(exception);
                }
            }
        }

        void CaptureCleanup(Action action)
        {
            try
            {
                action();
            }
            catch (Exception exception)
            {
                if (!ReferenceEquals(exception, primaryFailure))
                {
                    cleanupFailures.Add(exception);
                }
            }
        }
    }

    private async Task HeartbeatAsync(
        BrokerRegistrationStore registration,
        string instanceId,
        CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(options.HeartbeatInterval);
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            registration.Heartbeat(instanceId, BrokerRegistrationStates.Ready, options.HeartbeatTtl);
        }
    }

    private static void AttachCleanupFailures(Exception primaryFailure, IReadOnlyCollection<Exception> cleanupFailures)
    {
        if (cleanupFailures.Count == 0)
        {
            return;
        }

        try
        {
            primaryFailure.Data["BrokerCleanupFailures"] = cleanupFailures
                .Select(exception => $"{exception.GetType().Name}: {exception.Message}")
                .ToArray();
        }
        catch (Exception)
        {
            // Exception metadata is best-effort; never replace the primary failure.
        }
    }
}
