using System.Diagnostics;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public sealed class RunnerLeaseSet : IDisposable
{
    private readonly List<RunnerLeaseSlot> slots;

    private RunnerLeaseSet(List<RunnerLeaseSlot> slots)
    {
        this.slots = slots;
    }

    public string LeaseId => string.Join("+", slots.Select(slot => slot.LeaseId));

    public void ReleaseSessionLease()
    {
        if (slots.Count == 0)
        {
            throw new RunnerGateException("RUNNER_LEASE_STATE_INVALID", "Runner session lease is missing.");
        }

        // Slot 0 is the profile/project session lease. Slot 1 is the immutable
        // action-run lease and remains held until result.json is committed.
        slots[0].Dispose();
    }

    public static RunnerLeaseSet Acquire(ValidatedRunnerAction action, TimeSpan timeout)
    {
        var leaseRoot = Path.Combine(action.EngineeringRoot, "data", "runner", "leases");
        var sessionIdentity = OperatingSystem.IsWindows()
            ? $"{action.Profile}|{action.PlcProject}".ToUpperInvariant()
            : $"{action.Profile}|{action.PlcProject}";
        // Transport aliases must never partition the single-session lease for one
        // exact profile/project. The transport is audit metadata, not lock identity.
        var sessionKey = RunnerHash.Sha256Text(sessionIdentity)[..32];
        var actionKey = RunnerHash.Sha256Text($"{action.ActionId}|{action.ActionSha256}|{action.IdempotencyKey}")[..32];
        var acquired = new List<RunnerLeaseSlot>();
        try
        {
            acquired.Add(RunnerLeaseSlot.Acquire(
                Path.Combine(leaseRoot, "session-client", sessionKey),
                $"session-client:{sessionKey}",
                action,
                timeout));
            acquired.Add(RunnerLeaseSlot.Acquire(
                Path.Combine(leaseRoot, "actions", actionKey),
                $"action:{actionKey}",
                action,
                timeout));
            return new RunnerLeaseSet(acquired);
        }
        catch (Exception acquisitionFailure)
        {
            List<Exception>? cleanupFailures = null;
            for (var index = acquired.Count - 1; index >= 0; index--)
            {
                try
                {
                    acquired[index].Dispose();
                }
                catch (Exception cleanupFailure)
                {
                    cleanupFailures ??= [];
                    cleanupFailures.Add(cleanupFailure);
                }
            }

            if (cleanupFailures is not null)
            {
                acquisitionFailure.Data["RunnerLeaseSetCleanupFailures"] = new AggregateException(cleanupFailures).ToString();
            }

            throw;
        }
    }

    public void Dispose()
    {
        List<Exception>? failures = null;
        for (var index = slots.Count - 1; index >= 0; index--)
        {
            try
            {
                slots[index].Dispose();
            }
            catch (Exception exception)
            {
                failures ??= [];
                failures.Add(exception);
            }
        }

        slots.Clear();
        if (failures is not null)
        {
            throw new AggregateException("One or more Runner lease slots could not be released cleanly.", failures);
        }
    }
}

internal sealed class RunnerLeaseSlot : IDisposable
{
    private readonly ThreadBoundMutexLease mutexLease;
    private readonly FileStream lockStream;
    private readonly string ownerPath;
    private readonly object disposeGate = new();
    private bool disposed;

    private RunnerLeaseSlot(ThreadBoundMutexLease mutexLease, FileStream lockStream, string ownerPath, string leaseId)
    {
        this.mutexLease = mutexLease;
        this.lockStream = lockStream;
        this.ownerPath = ownerPath;
        LeaseId = leaseId;
    }

    public string LeaseId { get; }

    public static RunnerLeaseSlot Acquire(
        string slotRoot,
        string mutexKey,
        ValidatedRunnerAction action,
        TimeSpan timeout)
    {
        Directory.CreateDirectory(slotRoot);
        var mutexName = (OperatingSystem.IsWindows() ? "Global\\" : string.Empty) +
            "CtrlX.OpCon.Runner." + RunnerHash.Sha256Text(mutexKey)[..32];
        ThreadBoundMutexLease? mutexLease = null;
        FileStream? stream = null;
        try
        {
            // A named Mutex is thread-affine.  Keep acquisition and release on one
            // dedicated holder thread so an awaited Broker call cannot resume on a
            // different thread and strand the cross-process lease.
            mutexLease = ThreadBoundMutexLease.Acquire(mutexName, slotRoot, timeout);

            try
            {
                stream = new FileStream(
                    Path.Combine(slotRoot, "lease.lock"),
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None);
            }
            catch (IOException exception)
            {
                throw new RunnerGateException("RUNNER_BUSY", $"Runner file lease is already held: {slotRoot}. {exception.Message}", RunnerExitCodes.Busy);
            }

            var leaseId = Guid.NewGuid().ToString("N");
            using var process = Process.GetCurrentProcess();
            var ownerPath = Path.Combine(slotRoot, "owner.json");
            RunnerJson.WriteAtomic(ownerPath, new JsonObject
            {
                ["schemaVersion"] = 1,
                ["leaseId"] = leaseId,
                ["processId"] = Environment.ProcessId,
                ["processStartTimeUtc"] = process.StartTime.ToUniversalTime().ToString("O"),
                ["windowsSessionId"] = process.SessionId,
                ["userName"] = Environment.UserName,
                ["actionId"] = action.ActionId,
                ["actionSha256"] = action.ActionSha256,
                ["profile"] = action.Profile,
                ["plcProject"] = action.PlcProject,
                ["acquiredAtUtc"] = DateTimeOffset.UtcNow.ToString("O")
            }, overwrite: true);
            return new RunnerLeaseSlot(mutexLease, stream, ownerPath, leaseId);
        }
        catch (Exception acquisitionFailure)
        {
            List<Exception>? cleanupFailures = null;
            try
            {
                stream?.Dispose();
            }
            catch (Exception cleanupFailure)
            {
                cleanupFailures ??= [];
                cleanupFailures.Add(cleanupFailure);
            }

            try
            {
                mutexLease?.Dispose();
            }
            catch (Exception cleanupFailure)
            {
                cleanupFailures ??= [];
                cleanupFailures.Add(cleanupFailure);
            }

            if (cleanupFailures is not null)
            {
                acquisitionFailure.Data["RunnerLeaseCleanupFailures"] = new AggregateException(cleanupFailures).ToString();
            }

            throw;
        }
    }

    public void Dispose()
    {
        lock (disposeGate)
        {
            if (disposed)
            {
                return;
            }

            try
            {
                if (File.Exists(ownerPath))
                {
                    try
                    {
                        var owner = RunnerJson.ReadObject(ownerPath, "Runner lease owner");
                        if (RunnerValidation.RequiredString(owner, "leaseId", "Runner lease owner") == LeaseId)
                        {
                            File.Delete(ownerPath);
                        }
                    }
                    catch (RunnerGateException)
                    {
                        // Never delete metadata that cannot be proven to belong to us.
                    }
                }
            }
            finally
            {
                try
                {
                    lockStream.Dispose();
                }
                finally
                {
                    mutexLease.Dispose();
                }
            }

            disposed = true;
        }
    }
}

internal sealed class ThreadBoundMutexLease : IDisposable
{
    private static readonly TimeSpan HolderShutdownTimeout = TimeSpan.FromSeconds(10);

    private readonly ManualResetEventSlim acquisitionCompleted = new(initialState: false);
    private readonly ManualResetEventSlim releaseRequested = new(initialState: false);
    private readonly ManualResetEventSlim releaseCompleted = new(initialState: false);
    private readonly Thread holderThread;
    private readonly object disposeGate = new();
    private RunnerGateException? acquisitionFailure;
    private bool signalsDisposed;

    private ThreadBoundMutexLease(string mutexName, string slotRoot, TimeSpan timeout)
    {
        holderThread = new Thread(() =>
        {
            Mutex? mutex = null;
            var ownsMutex = false;
            try
            {
                mutex = new Mutex(initiallyOwned: false, mutexName);
                try
                {
                    ownsMutex = mutex.WaitOne(timeout);
                }
                catch (AbandonedMutexException)
                {
                    ownsMutex = true;
                    acquisitionFailure = new RunnerGateException(
                        "LEASE_ABANDONED_REVIEW_REQUIRED",
                        $"An abandoned Runner lease requires review: {slotRoot}",
                        RunnerExitCodes.Busy);
                }

                if (!ownsMutex && acquisitionFailure is null)
                {
                    acquisitionFailure = new RunnerGateException(
                        "RUNNER_BUSY",
                        $"Runner lease is already held: {slotRoot}",
                        RunnerExitCodes.Busy);
                }

                acquisitionCompleted.Set();
                if (ownsMutex && acquisitionFailure is null)
                {
                    releaseRequested.Wait();
                }
            }
            catch (Exception exception)
            {
                acquisitionFailure ??= new RunnerGateException(
                    "RUNNER_LEASE_FAILURE",
                    $"Runner lease holder failed for {slotRoot}: {exception.Message}",
                    RunnerExitCodes.InternalError);
                acquisitionCompleted.Set();
            }
            finally
            {
                if (ownsMutex)
                {
                    try
                    {
                        mutex?.ReleaseMutex();
                    }
                    catch (ApplicationException exception)
                    {
                        acquisitionFailure ??= new RunnerGateException(
                            "RUNNER_LEASE_RELEASE_FAILURE",
                            $"Runner mutex release failed for {slotRoot}: {exception.Message}",
                            RunnerExitCodes.InternalError);
                    }
                }

                mutex?.Dispose();
                acquisitionCompleted.Set();
                releaseCompleted.Set();
            }
        })
        {
            IsBackground = true,
            Name = $"CtrlX Runner lease {Path.GetFileName(slotRoot)}"
        };

        holderThread.Start();
        var acquisitionWait = timeout + TimeSpan.FromSeconds(5);
        if (!acquisitionCompleted.Wait(acquisitionWait))
        {
            releaseRequested.Set();
            if (releaseCompleted.Wait(HolderShutdownTimeout) &&
                holderThread.Join(HolderShutdownTimeout))
            {
                DisposeSignals();
            }

            throw new RunnerGateException(
                "RUNNER_LEASE_TIMEOUT",
                $"Runner lease holder did not report its state: {slotRoot}",
                RunnerExitCodes.Busy);
        }

        if (acquisitionFailure is not null)
        {
            releaseRequested.Set();
            if (releaseCompleted.Wait(HolderShutdownTimeout) &&
                holderThread.Join(HolderShutdownTimeout))
            {
                DisposeSignals();
            }

            throw acquisitionFailure;
        }
    }

    public static ThreadBoundMutexLease Acquire(string mutexName, string slotRoot, TimeSpan timeout)
    {
        if (timeout < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        return new ThreadBoundMutexLease(mutexName, slotRoot, timeout);
    }

    public void Dispose()
    {
        lock (disposeGate)
        {
            if (signalsDisposed)
            {
                return;
            }

            releaseRequested.Set();
            if (!releaseCompleted.Wait(HolderShutdownTimeout) ||
                !holderThread.Join(HolderShutdownTimeout))
            {
                throw new RunnerGateException(
                    "RUNNER_LEASE_RELEASE_TIMEOUT",
                    "Runner lease holder did not release its named mutex within the bounded timeout.",
                    RunnerExitCodes.InternalError);
            }

            var releaseFailure = acquisitionFailure;
            DisposeSignals();
            if (releaseFailure is not null)
            {
                throw releaseFailure;
            }
        }
    }

    private void DisposeSignals()
    {
        acquisitionCompleted.Dispose();
        releaseRequested.Dispose();
        releaseCompleted.Dispose();
        signalsDisposed = true;
    }
}
