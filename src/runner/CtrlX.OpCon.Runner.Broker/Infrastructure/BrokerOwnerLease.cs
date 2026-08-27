using System.Text.Json.Serialization;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public sealed class BrokerOwnerLease : IDisposable
{
    private static readonly TimeSpan HolderShutdownTimeout = TimeSpan.FromSeconds(10);

    private readonly BrokerMutexHolder mutexHolder;
    private readonly FileStream lockStream;
    private readonly string ownerPath;
    private bool disposed;

    private BrokerOwnerLease(
        BrokerRuntimePaths paths,
        BrokerProcessIdentity process,
        string instanceId,
        string leaseId,
        BrokerMutexHolder mutexHolder,
        FileStream lockStream,
        string ownerPath)
    {
        Paths = paths;
        Process = process;
        InstanceId = instanceId;
        LeaseId = leaseId;
        this.mutexHolder = mutexHolder;
        this.lockStream = lockStream;
        this.ownerPath = ownerPath;
    }

    public BrokerRuntimePaths Paths { get; }

    public BrokerProcessIdentity Process { get; }

    public string InstanceId { get; }

    public string LeaseId { get; }

    public static BrokerOwnerLease Acquire(
        BrokerRuntimePaths paths,
        string instanceId,
        TimeSpan timeout)
    {
        ArgumentNullException.ThrowIfNull(paths);
        BrokerValueValidation.RequireSafeIdentifier(instanceId, nameof(instanceId));
        if (timeout < TimeSpan.Zero || timeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        var process = BrokerProcessIdentity.CaptureCurrentInteractive();
        paths.EnsureCreated();
        var mutexName = $"Local\\CtrlX.OpCon.Runner.Broker.Profile.{paths.ProfileLeaseKey[..32]}";
        BrokerMutexHolder? mutex = null;
        FileStream? stream = null;
        try
        {
            mutex = BrokerMutexHolder.Acquire(mutexName, paths.LeaseRoot, timeout);
            var lockPath = Path.Combine(paths.LeaseRoot, "broker.lock");
            try
            {
                stream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException exception)
            {
                throw new BrokerInfrastructureException("BROKER_OWNER_BUSY", $"Another Broker owns the project lease: {lockPath}", exception);
            }

            var leaseId = Guid.NewGuid().ToString("N");
            var ownerPath = Path.Combine(paths.LeaseRoot, "owner.json");
            BrokerAtomicJson.Write(ownerPath, new BrokerLeaseOwnerRecord
            {
                LeaseId = leaseId,
                BrokerInstanceId = instanceId,
                IdentityKey = paths.IdentityKey,
                ProcessId = process.ProcessId,
                ProcessStartTimeUtc = process.ProcessStartTimeUtc,
                WindowsSessionId = process.WindowsSessionId,
                UserSid = process.UserSid,
                ExecutablePath = process.ExecutablePath,
                ExecutableSha256 = process.ExecutableSha256,
                EngineeringRoot = paths.EngineeringRoot,
                StationRoot = paths.StationRoot,
                Profile = paths.Profile,
                PlcProject = paths.PlcProject,
                AcquiredAtUtc = DateTimeOffset.UtcNow
            }, overwrite: true);
            return new BrokerOwnerLease(paths, process, instanceId, leaseId, mutex, stream, ownerPath);
        }
        catch
        {
            stream?.Dispose();
            try
            {
                mutex?.Dispose();
            }
            catch (BrokerInfrastructureException)
            {
                // Preserve the acquisition failure. The holder has already been
                // asked to release and is a background thread with bounded wait.
            }

            throw;
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        Exception? failure = null;
        try
        {
            if (File.Exists(ownerPath))
            {
                try
                {
                    var owner = BrokerAtomicJson.Read<BrokerLeaseOwnerRecord>(ownerPath, "Broker lease owner");
                    if (owner.LeaseId == LeaseId && owner.BrokerInstanceId == InstanceId)
                    {
                        File.Delete(ownerPath);
                    }
                }
                catch (Exception exception)
                {
                    failure = exception;
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
                try
                {
                    mutexHolder.Dispose();
                }
                catch (Exception exception)
                {
                    failure ??= exception;
                }
            }
        }

        disposed = true;
        if (failure is not null)
        {
            throw new BrokerInfrastructureException("BROKER_OWNER_RELEASE_FAILED", "Broker owner lease cleanup was incomplete.", failure);
        }
    }

    [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
    private sealed class BrokerLeaseOwnerRecord
    {
        public int SchemaVersion { get; set; } = 1;
        public string Kind { get; set; } = "ctrlx-opcon-broker-owner";
        public string LeaseId { get; set; } = string.Empty;
        public string BrokerInstanceId { get; set; } = string.Empty;
        public string IdentityKey { get; set; } = string.Empty;
        public int ProcessId { get; set; }
        public DateTimeOffset ProcessStartTimeUtc { get; set; }
        public int WindowsSessionId { get; set; }
        public string UserSid { get; set; } = string.Empty;
        public string ExecutablePath { get; set; } = string.Empty;
        public string ExecutableSha256 { get; set; } = string.Empty;
        public string EngineeringRoot { get; set; } = string.Empty;
        public string StationRoot { get; set; } = string.Empty;
        public string Profile { get; set; } = string.Empty;
        public string PlcProject { get; set; } = string.Empty;
        public DateTimeOffset AcquiredAtUtc { get; set; }
    }

    private sealed class BrokerMutexHolder : IDisposable
    {
        private readonly ManualResetEventSlim acquired = new(false);
        private readonly ManualResetEventSlim release = new(false);
        private readonly ManualResetEventSlim released = new(false);
        private readonly Thread thread;
        private BrokerInfrastructureException? failure;
        private bool disposed;

        private BrokerMutexHolder(string name, string leaseRoot, TimeSpan timeout)
        {
            thread = new Thread(() => Hold(name, leaseRoot, timeout))
            {
                IsBackground = true,
                Name = "ctrlX OpCon Broker owner lease"
            };
            thread.Start();
            if (!acquired.Wait(timeout + TimeSpan.FromSeconds(5)))
            {
                StopAfterFailedAcquire();
                throw new BrokerInfrastructureException("BROKER_OWNER_TIMEOUT", "Broker mutex holder did not report its state.");
            }

            if (failure is not null)
            {
                var captured = failure;
                StopAfterFailedAcquire();
                throw captured;
            }
        }

        public static BrokerMutexHolder Acquire(string name, string leaseRoot, TimeSpan timeout) =>
            new(name, leaseRoot, timeout);

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }

            release.Set();
            if (!released.Wait(HolderShutdownTimeout) || !thread.Join(HolderShutdownTimeout))
            {
                throw new BrokerInfrastructureException("BROKER_OWNER_RELEASE_TIMEOUT", "Broker mutex holder did not stop in time.");
            }

            acquired.Dispose();
            release.Dispose();
            released.Dispose();
            disposed = true;
        }

        private void StopAfterFailedAcquire()
        {
            release.Set();
            var stopped = released.Wait(HolderShutdownTimeout) && thread.Join(HolderShutdownTimeout);
            if (stopped)
            {
                acquired.Dispose();
                release.Dispose();
                released.Dispose();
                disposed = true;
            }
        }

        private void Hold(string name, string leaseRoot, TimeSpan timeout)
        {
            Mutex? mutex = null;
            var owns = false;
            try
            {
                mutex = new Mutex(false, name);
                try
                {
                    owns = mutex.WaitOne(timeout);
                }
                catch (AbandonedMutexException)
                {
                    owns = true;
                    failure = new BrokerInfrastructureException(
                        "BROKER_OWNER_ABANDONED_REVIEW_REQUIRED",
                        $"An abandoned Broker owner mutex requires review: {leaseRoot}");
                }

                if (!owns && failure is null)
                {
                    failure = new BrokerInfrastructureException("BROKER_OWNER_BUSY", "Another Broker owns this profile/project.");
                }

                acquired.Set();
                if (owns && failure is null)
                {
                    release.Wait();
                }
            }
            catch (Exception exception)
            {
                failure ??= new BrokerInfrastructureException("BROKER_OWNER_FAILURE", "Broker mutex holder failed.", exception);
                acquired.Set();
            }
            finally
            {
                if (owns)
                {
                    try
                    {
                        mutex?.ReleaseMutex();
                    }
                    catch (ApplicationException exception)
                    {
                        failure ??= new BrokerInfrastructureException("BROKER_OWNER_RELEASE_FAILED", "Broker mutex release failed.", exception);
                    }
                }

                mutex?.Dispose();
                acquired.Set();
                released.Set();
            }
        }
    }
}
