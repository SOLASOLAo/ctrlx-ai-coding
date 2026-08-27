using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CtrlX.OpCon.Runner.Broker.Infrastructure;
using CtrlX.OpCon.Runner.Broker.Session;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker;

public interface IBrokerPipeServer
{
    Task RunAsync(CancellationToken cancellationToken);
}

public sealed class BrokerNamedPipeServer : IBrokerPipeServer
{
    private readonly string pipeName;
    private readonly string brokerInstanceId;
    private readonly BrokerActionDispatcher dispatcher;

    public BrokerNamedPipeServer(
        string pipeName,
        string brokerInstanceId,
        BrokerActionDispatcher dispatcher)
    {
        this.pipeName = RequireSafe(pipeName, nameof(pipeName));
        this.brokerInstanceId = RequireSafe(brokerInstanceId, nameof(brokerInstanceId));
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The interactive Broker Named Pipe is Windows-only.");
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(
                pipeName,
                PipeDirection.InOut,
                NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
                inBufferSize: 8192,
                outBufferSize: 8192);
            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                ValidateClientIdentity(pipe);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));
                var request = await BrokerPipeCodec.ReadAsync(pipe, timeout.Token).ConfigureAwait(false);
                var reply = Handle(request);
                await BrokerPipeCodec.WriteAsync(pipe, reply, timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception) when (IsPerConnectionFailure(exception))
            {
                // Fail closed. A request that cannot be authenticated and parsed
                // receives no partially trusted response envelope.
            }
        }
    }

    private JsonObject Handle(JsonObject request)
    {
        RequireOnly(
            request,
            "Broker request",
            "protocolVersion",
            "kind",
            "requestId",
            "brokerInstanceId",
            "clientNonce",
            "action",
            "project",
            "guardrails",
            "executionId",
            "actionId",
            "actionRequestSha256",
            "idempotencyKey");
        if (RequiredInt(request, "protocolVersion") != BrokerWireProtocol.Version ||
            RequiredString(request, "brokerInstanceId") != brokerInstanceId)
        {
            throw new BrokerInfrastructureException("BROKER_PROTOCOL_MISMATCH", "Broker protocol or instance identity changed.");
        }

        var kind = RequiredString(request, "kind");
        var requestId = RequireSafe(RequiredString(request, "requestId"), "requestId");
        var nonce = RequireSafe(RequiredString(request, "clientNonce"), "clientNonce");
        return kind switch
        {
            BrokerWireProtocol.SubmitKind => HandleSubmit(request, requestId, nonce),
            BrokerWireProtocol.QueryKind => HandleQuery(request, requestId, nonce),
            _ => throw new BrokerInfrastructureException("BROKER_REQUEST_KIND_REJECTED", "Broker accepts only typed submit/query requests.")
        };
    }

    private JsonObject HandleSubmit(JsonObject request, string requestId, string nonce)
    {
        RequireAbsent(request, "executionId", "actionId", "actionRequestSha256", "idempotencyKey");
        var actionNode = RequiredObject(request, "action");
        RequireOnly(
            actionNode,
            "Broker action identity",
            "operationId",
            "actionId",
            "actionKind",
            "actionRequestPath",
            "actionRequestSha256",
            "idempotencyKey");
        var actionPath = RequiredString(actionNode, "actionRequestPath");
        var actionSha = RequiredString(actionNode, "actionRequestSha256");
        var action = dispatcher.ValidateAction(actionPath, actionSha);
        if (requestId != action.ActionId ||
            !JsonNode.DeepEquals(actionNode, BrokerWireProtocol.ActionIdentity(action)) ||
            !JsonNode.DeepEquals(RequiredObject(request, "project"), BrokerWireProtocol.ProjectIdentity(action)) ||
            !JsonNode.DeepEquals(RequiredObject(request, "guardrails"), BrokerWireProtocol.OfflineGuardrails()))
        {
            throw new BrokerInfrastructureException("BROKER_ACTION_IDENTITY_MISMATCH", "Submit envelope does not match the immutable action.");
        }

        var receipt = dispatcher.Submit(action);
        return new JsonObject
        {
            ["protocolVersion"] = BrokerWireProtocol.Version,
            ["kind"] = BrokerWireProtocol.SubmitReplyKind,
            ["requestId"] = requestId,
            ["brokerInstanceId"] = brokerInstanceId,
            ["clientNonce"] = nonce,
            ["accepted"] = receipt.Accepted,
            ["reasonCode"] = receipt.ReasonCode,
            ["executionId"] = receipt.ExecutionId,
            ["disposition"] = receipt.Disposition,
            ["state"] = receipt.State
        };
    }

    private JsonObject HandleQuery(JsonObject request, string requestId, string nonce)
    {
        RequireAbsent(request, "action", "project", "guardrails");
        var executionId = RequireSafe(RequiredString(request, "executionId"), "executionId");
        var actionId = RequireSafe(RequiredString(request, "actionId"), "actionId");
        var actionSha256 = RequiredSha256(request, "actionRequestSha256");
        var idempotencyKey = RequiredSha256(request, "idempotencyKey");
        if (requestId != actionId)
        {
            throw new BrokerInfrastructureException("BROKER_QUERY_IDENTITY_MISMATCH", "Query requestId does not match actionId.");
        }

        var result = dispatcher.Query(executionId, actionId, actionSha256, idempotencyKey);
        return new JsonObject
        {
            ["protocolVersion"] = BrokerWireProtocol.Version,
            ["kind"] = BrokerWireProtocol.QueryReplyKind,
            ["requestId"] = requestId,
            ["brokerInstanceId"] = brokerInstanceId,
            ["clientNonce"] = nonce,
            ["executionId"] = executionId,
            ["terminal"] = result.Terminal,
            ["reviewRequired"] = result.ReviewRequired,
            ["reasonCode"] = result.ReasonCode,
            ["state"] = result.State,
            ["session"] = result.Terminal && !result.ReviewRequired ? OuterSession(result.Session!) : null,
            ["observation"] = result.Terminal && !result.ReviewRequired ? result.Observation?.DeepClone() : null
        };
    }

    private static JsonObject OuterSession(BrokerSessionRuntime session) => new()
    {
        ["protocolVersion"] = BrokerWireProtocol.Version,
        ["brokerPid"] = Environment.ProcessId,
        ["sessionId"] = session.PersistentSessionId,
        ["mcpPid"] = session.McpPid,
        ["plePid"] = session.PlePid,
        ["profile"] = session.Profile,
        ["activeProjectPath"] = session.ActiveProjectPath,
        ["state"] = "ready",
        ["pleOwnedByBroker"] = session.PleOwnedByBroker
    };

    private static void ValidateClientIdentity(NamedPipeServerStream pipe)
    {
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var processId) ||
            !GetNamedPipeClientSessionId(pipe.SafePipeHandle.DangerousGetHandle(), out var sessionId) ||
            processId == 0)
        {
            throw new BrokerInfrastructureException("BROKER_CLIENT_IDENTITY_UNAVAILABLE", "Named Pipe client identity is unavailable.");
        }

        using var current = Process.GetCurrentProcess();
        int clientSessionId;
        try
        {
            if (processId > int.MaxValue)
            {
                throw new ArgumentOutOfRangeException(nameof(processId));
            }

            using var client = Process.GetProcessById((int)processId);
            if (client.HasExited)
            {
                throw new InvalidOperationException("Named Pipe client exited before identity validation completed.");
            }

            clientSessionId = client.SessionId;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
            InvalidOperationException or
            Win32Exception)
        {
            throw new BrokerInfrastructureException(
                "BROKER_CLIENT_IDENTITY_UNAVAILABLE",
                "Named Pipe client identity changed before validation completed.",
                exception);
        }

        if (sessionId != current.SessionId || clientSessionId != current.SessionId)
        {
            throw new BrokerInfrastructureException("BROKER_CLIENT_SESSION_REJECTED", "Named Pipe client is outside the Broker interactive session.");
        }
    }

    private static bool IsPerConnectionFailure(Exception exception) => exception is
        RunnerGateException or
        BrokerInfrastructureException or
        JsonException or
        DecoderFallbackException or
        IOException or
        UnauthorizedAccessException or
        OperationCanceledException or
        InvalidOperationException or
        ArgumentException or
        FormatException or
        OverflowException;

    private static void RequireOnly(JsonObject value, string context, params string[] allowedNames)
    {
        var allowed = new HashSet<string>(allowedNames, StringComparer.Ordinal);
        foreach (var property in value)
        {
            if (!allowed.Contains(property.Key))
            {
                throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"{context} contains unsupported property '{property.Key}'.");
            }
        }
    }

    private static void RequireAbsent(JsonObject value, params string[] names)
    {
        foreach (var name in names)
        {
            if (value[name] is not null)
            {
                throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Request contains '{name}' in the wrong message kind.");
            }
        }
    }

    private static string RequiredString(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node ||
            !node.TryGetValue<string>(out var result) ||
            string.IsNullOrWhiteSpace(result) ||
            result.IndexOfAny(['\0', '\r', '\n']) >= 0)
        {
            throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Broker request '{name}' must be a non-empty single-line string.");
        }

        return result;
    }

    private static int RequiredInt(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<int>(out var result))
        {
            throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Broker request '{name}' must be an Int32.");
        }

        return result;
    }

    private static JsonObject RequiredObject(JsonObject value, string name) =>
        value[name] as JsonObject
        ?? throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Broker request '{name}' must be an object.");

    private static string RequiredSha256(JsonObject value, string name)
    {
        var result = RequiredString(value, name);
        if (result.Length != 64 || !result.All(Uri.IsHexDigit))
        {
            throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Broker request '{name}' must be SHA-256.");
        }

        return result;
    }

    private static string RequireSafe(string value, string name)
    {
        if (value.Length is 0 or > 128 || !value.All(character =>
                char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-'))
        {
            throw new BrokerInfrastructureException("BROKER_PROTOCOL_INVALID", $"Broker request '{name}' is not a safe identifier.");
        }

        return value;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientSessionId(IntPtr pipe, out uint clientSessionId);
}
