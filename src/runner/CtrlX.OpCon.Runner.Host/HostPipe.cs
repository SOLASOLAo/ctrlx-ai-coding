using System.Diagnostics;
using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Host;

internal static class HostPipeCodec
{
    public static async Task WriteAsync<T>(Stream stream, T value, CancellationToken cancellationToken)
    {
        var payload = HostJson.Serialize(value, indented: false);
        if (payload.Length <= 0 || payload.Length > HostConstants.MaximumPipeMessageBytes)
        {
            throw new RunnerGateException("HOST_PIPE_MESSAGE_TOO_LARGE", "Runner Host control message exceeds its fixed size limit.");
        }

        var length = BitConverter.GetBytes(payload.Length);
        await stream.WriteAsync(length, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<T> ReadAsync<T>(Stream stream, CancellationToken cancellationToken)
    {
        var lengthBytes = new byte[sizeof(int)];
        await ReadExactlyAsync(stream, lengthBytes, cancellationToken).ConfigureAwait(false);
        var length = BitConverter.ToInt32(lengthBytes);
        if (length <= 0 || length > HostConstants.MaximumPipeMessageBytes)
        {
            throw new RunnerGateException("HOST_PIPE_MESSAGE_INVALID", "Runner Host control message length is invalid.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        return HostJson.Deserialize<T>(payload, "Runner Host control message");
    }

    private static async Task ReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException("Runner Host control Pipe closed before the complete message was received.");
            }

            offset += read;
        }
    }
}

internal sealed class HostControlServer
{
    private static readonly TimeSpan ConnectionDeadline = TimeSpan.FromSeconds(3);
    private readonly HostRuntimePaths paths;
    private readonly HostProcessIdentity identity;
    private readonly string hostInstanceId;
    private readonly Action requestStop;

    public HostControlServer(
        HostRuntimePaths paths,
        HostProcessIdentity identity,
        string hostInstanceId,
        Action requestStop)
    {
        this.paths = paths;
        this.identity = identity;
        this.hostInstanceId = hostInstanceId;
        this.requestStop = requestStop;
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await using var server = new NamedPipeServerStream(
                paths.PipeName,
                PipeDirection.InOut,
                maxNumberOfServerInstances: 1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
                inBufferSize: HostConstants.MaximumPipeMessageBytes,
                outBufferSize: HostConstants.MaximumPipeMessageBytes);
            try
            {
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var connectionDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                connectionDeadline.CancelAfter(ConnectionDeadline);
                await HandleAsync(server, connectionDeadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException)
            {
                // A half-open current-user client exceeded its per-connection
                // deadline. Drop only that connection and keep serving.
            }
            catch (Exception exception) when (exception is IOException or RunnerGateException or JsonException)
            {
                // A malformed or prematurely disconnected client is isolated to
                // this one connection. It cannot stop the Host.
            }
        }
    }

    private async Task HandleAsync(NamedPipeServerStream server, CancellationToken cancellationToken)
    {
        if (!GetNamedPipeClientProcessId(server.SafePipeHandle.DangerousGetHandle(), out var clientPid) || clientPid == 0)
        {
            throw new RunnerGateException("HOST_PIPE_CLIENT_IDENTITY_INVALID", "Runner Host could not identify the control client.");
        }

        try
        {
            using var process = Process.GetProcessById(checked((int)clientPid));
            if (process.HasExited || process.SessionId != identity.WindowsSessionId)
            {
                throw new RunnerGateException("HOST_PIPE_CLIENT_SESSION_MISMATCH", "Runner Host control client is not in the Host Windows session.");
            }
        }
        catch (RunnerGateException)
        {
            throw;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or Win32Exception)
        {
            throw new RunnerGateException(
                "HOST_PIPE_CLIENT_IDENTITY_INVALID",
                $"Runner Host control client identity could not be verified: {exception.Message}");
        }

        var request = await HostPipeCodec.ReadAsync<HostStopRequest>(server, cancellationToken).ConfigureAwait(false);
        var accepted = request.SchemaVersion == HostConstants.ControlSchemaVersion &&
            request.Kind == HostConstants.StopRequestKind &&
            request.ProtocolVersion == HostConstants.ProtocolVersion &&
            request.HostInstanceId == hostInstanceId &&
            request.EngineeringRoot.Equals(paths.EngineeringRoot, StringComparison.OrdinalIgnoreCase) &&
            request.UserSid == identity.UserSid &&
            request.WindowsSessionId == identity.WindowsSessionId &&
            IsSafeNonce(request.ClientNonce);
        var reply = new HostStopReply
        {
            HostInstanceId = hostInstanceId,
            ClientNonce = IsSafeNonce(request.ClientNonce) ? request.ClientNonce : "invalid",
            Accepted = accepted,
            ReasonCode = accepted ? "HOST_STOP_ACCEPTED" : "HOST_STOP_IDENTITY_MISMATCH"
        };
        await HostPipeCodec.WriteAsync(server, reply, cancellationToken).ConfigureAwait(false);
        if (accepted)
        {
            requestStop();
        }
    }

    private static bool IsSafeNonce(string value) =>
        value.Length == 32 && value.All(Uri.IsHexDigit);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId);
}

internal sealed class HostControlClient
{
    private readonly HostRuntimePaths paths;
    private readonly HostStatusStore statusStore;

    public HostControlClient(HostRuntimePaths paths)
    {
        this.paths = paths;
        statusStore = new HostStatusStore(paths);
    }

    public async Task<HostStopReply> StopAsync(CancellationToken cancellationToken)
    {
        var status = statusStore.ReadLive();
        if (status is null)
        {
            return new HostStopReply
            {
                HostInstanceId = "none",
                ClientNonce = "none",
                Accepted = true,
                ReasonCode = "HOST_ALREADY_STOPPED"
            };
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        await using var client = new NamedPipeClientStream(
            ".",
            status.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
        ValidateServerIdentity(client, status);
        var nonce = Guid.NewGuid().ToString("N");
        var request = new HostStopRequest
        {
            HostInstanceId = status.HostInstanceId,
            EngineeringRoot = paths.EngineeringRoot,
            UserSid = BrokerWireProtocol.CurrentUserSid(),
            WindowsSessionId = Process.GetCurrentProcess().SessionId,
            ClientNonce = nonce
        };
        await HostPipeCodec.WriteAsync(client, request, timeout.Token).ConfigureAwait(false);
        var reply = await HostPipeCodec.ReadAsync<HostStopReply>(client, timeout.Token).ConfigureAwait(false);
        if (reply.SchemaVersion != HostConstants.ControlSchemaVersion ||
            reply.Kind != HostConstants.StopReplyKind ||
            reply.ProtocolVersion != HostConstants.ProtocolVersion ||
            reply.HostInstanceId != status.HostInstanceId ||
            reply.ClientNonce != nonce ||
            !reply.Accepted)
        {
            throw new RunnerGateException("HOST_STOP_REPLY_INVALID", "Runner Host stop acknowledgement failed its identity contract.");
        }

        await WaitForExitAsync(status, timeout.Token).ConfigureAwait(false);
        return reply;
    }

    private static void ValidateServerIdentity(NamedPipeClientStream client, HostStatusDocument status)
    {
        if (!GetNamedPipeServerProcessId(client.SafePipeHandle.DangerousGetHandle(), out var serverPid) ||
            serverPid != status.HostPid)
        {
            throw new RunnerGateException("HOST_PIPE_SERVER_IDENTITY_INVALID", "Connected Runner Host Pipe server PID does not match status.");
        }
    }

    private static async Task WaitForExitAsync(HostStatusDocument status, CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var process = Process.GetProcessById(status.HostPid);
                if (process.HasExited ||
                    Math.Abs((process.StartTime.ToUniversalTime() - status.ProcessStartTimeUtc.UtcDateTime).TotalMilliseconds) > 1000)
                {
                    return;
                }
            }
            catch (ArgumentException)
            {
                return;
            }

            await Task.Delay(100, cancellationToken).ConfigureAwait(false);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
}
