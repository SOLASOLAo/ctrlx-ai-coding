using System.Diagnostics;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Host;

internal sealed class HostRuntime
{
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan HeartbeatTtl = TimeSpan.FromSeconds(10);
    private readonly HostRuntimePaths paths;

    public HostRuntime(HostRuntimePaths paths)
    {
        this.paths = paths;
    }

    public async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        var identity = HostProcessIdentity.CaptureCurrentInteractive();
        using var owner = HostOwnerLease.Acquire(paths);
        var statusStore = new HostStatusStore(paths);
        statusStore.AssertRecoverableBeforeStart();
        var log = new HostLogStore(paths);
        var hostInstanceId = Guid.NewGuid().ToString("N");
        var startedAt = DateTimeOffset.UtcNow;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var server = new HostControlServer(paths, identity, hostInstanceId, stop.Cancel);
        var serverTask = server.RunAsync(stop.Token);
        var previousState = string.Empty;
        var previousReason = string.Empty;
        var faulted = false;

        try
        {
            Publish(HostStates.Starting, "HOST_STARTING", ProbeAgent(identity), DateTimeOffset.UtcNow);
            log.Write("HOST_STARTED", HostStates.Starting, "HOST_STARTED", hostInstanceId);
            while (!stop.IsCancellationRequested)
            {
                var now = DateTimeOffset.UtcNow;
                var agent = ProbeAgent(identity);
                var state = agent.Available ? HostStates.Idle : HostStates.WaitingForAgent;
                var reason = agent.Available ? "HOST_AGENT_AVAILABLE" : agent.ReasonCode;
                Publish(state, reason, agent, now);
                if (state != previousState || reason != previousReason)
                {
                    log.Write("HOST_STATE_CHANGED", state, reason, hostInstanceId);
                    previousState = state;
                    previousReason = reason;
                }

                var delay = Task.Delay(HeartbeatInterval, stop.Token);
                var completed = await Task.WhenAny(delay, serverTask).ConfigureAwait(false);
                if (completed == serverTask)
                {
                    await serverTask.ConfigureAwait(false);
                    if (!stop.IsCancellationRequested)
                    {
                        throw new RunnerGateException(
                            "HOST_CONTROL_SERVER_STOPPED",
                            "Runner Host control server stopped unexpectedly.");
                    }
                }
                await delay.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
            // Graceful stop from Ctrl+C or the instance-bound control Pipe.
        }
        catch
        {
            faulted = true;
            var now = DateTimeOffset.UtcNow;
            Publish(HostStates.Faulted, "HOST_RUNTIME_FAULTED", ProbeAgent(identity), now);
            log.Write("HOST_FAULTED", HostStates.Faulted, "HOST_RUNTIME_FAULTED", hostInstanceId);
            throw;
        }
        finally
        {
            stop.Cancel();
            if (!faulted)
            {
                var now = DateTimeOffset.UtcNow;
                Publish(HostStates.Stopping, "HOST_STOPPING", ProbeAgent(identity), now);
                log.Write("HOST_STOPPING", HostStates.Stopping, "HOST_STOPPING", hostInstanceId);
            }
            try
            {
                await serverTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected while closing the control Pipe.
            }
            catch when (faulted)
            {
                // Preserve the original runtime failure and its FAULTED status.
            }

            if (faulted)
            {
                log.Write("HOST_FAULT_TERMINATED", HostStates.Faulted, "HOST_RUNTIME_FAULTED", hostInstanceId);
            }
            else
            {
                statusStore.DeleteIfOwned(hostInstanceId);
                log.Write("HOST_STOPPED", HostStates.Stopped, "HOST_STOPPED", hostInstanceId);
            }
        }

        return RunnerExitCodes.Done;

        void Publish(string state, string reasonCode, HostAgentStatus agent, DateTimeOffset now)
        {
            statusStore.Publish(new HostStatusDocument
            {
                HostInstanceId = hostInstanceId,
                State = state,
                ReasonCode = SafeReason(reasonCode),
                HostPid = identity.ProcessId,
                ProcessStartTimeUtc = identity.ProcessStartTimeUtc,
                WindowsSessionId = identity.WindowsSessionId,
                UserSid = identity.UserSid,
                ExecutablePath = identity.ExecutablePath,
                ExecutableSha256 = identity.ExecutableSha256,
                EngineeringRoot = paths.EngineeringRoot,
                RootKey = paths.RootKey,
                PipeName = paths.PipeName,
                StartedAtUtc = startedAt,
                HeartbeatAtUtc = now,
                ExpiresAtUtc = now + HeartbeatTtl,
                Agent = agent,
                Safety = new HostSafetyStatus
                {
                    StartsBroker = false,
                    StartsPleOrMcp = false,
                    OnlineOperationsAllowed = false,
                    AutomaticActionExecutionEnabled = false
                },
                LogDirectory = paths.LogDirectory,
                ActiveLogPath = log.ActiveLogPath
            });
        }
    }

    private HostAgentStatus ProbeAgent(HostProcessIdentity identity)
    {
        try
        {
            var registration = BrokerRegistrationReader.ReadValidated(paths.EngineeringRoot);
            if (registration.WindowsSessionId != identity.WindowsSessionId)
            {
                return Unavailable("BLOCKED_BROKER_SESSION_MISMATCH");
            }

            return new HostAgentStatus
            {
                Available = true,
                ReasonCode = "BROKER_REGISTRATION_VALIDATED",
                State = registration.State,
                BrokerPid = registration.BrokerPid,
                WindowsSessionId = registration.WindowsSessionId,
                Profile = registration.Profile,
                PlcProject = registration.PlcProject
            };
        }
        catch (RunnerGateException exception)
        {
            return Unavailable(SafeReason(exception.ReasonCode));
        }
        catch (Exception)
        {
            return Unavailable("BLOCKED_SESSION_UNAVAILABLE");
        }
    }

    private static HostAgentStatus Unavailable(string reasonCode) => new()
    {
        Available = false,
        ReasonCode = SafeReason(reasonCode)
    };

    private static string SafeReason(string value) =>
        value.Length is > 0 and <= 96 && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-')
            ? value
            : "BLOCKED_SESSION_UNAVAILABLE";
}
