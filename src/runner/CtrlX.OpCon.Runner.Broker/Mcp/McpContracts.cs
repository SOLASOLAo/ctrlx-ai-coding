using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Broker.Mcp;

public interface IMcpRpcClient : IAsyncDisposable
{
    int? ProcessId { get; }

    McpHandshake? Handshake { get; }

    event Action<string>? StandardErrorReceived;

    Task<McpHandshake> StartAsync(CancellationToken cancellationToken = default);

    Task<McpToolCallResult> CallToolAsync(
        string toolName,
        JsonObject? arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);

    Task<McpResourceReadResult> ReadResourceAsync(
        string uri,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Stops only the stdio child. The owning Broker must call the explicit
    /// shutdown_codesys tool first when it also intends to stop PLE.
    /// </summary>
    Task StopAsync(CancellationToken cancellationToken = default);
}

public sealed record McpToolDescriptor(
    string Name,
    string? Description,
    JsonObject InputSchema,
    JsonObject Document);

public sealed record McpHandshake(
    string ProtocolVersion,
    string ServerName,
    string ServerVersion,
    JsonObject Capabilities,
    IReadOnlyDictionary<string, McpToolDescriptor> Tools);

public sealed record McpToolCallResult(
    string ToolName,
    bool IsError,
    IReadOnlyList<string> TextContent,
    JsonObject Document);

public sealed record McpResourceReadResult(
    string Uri,
    bool IsError,
    IReadOnlyList<string> TextContent,
    JsonObject Document);

public class McpClientException : Exception
{
    public McpClientException(string reasonCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        ReasonCode = reasonCode;
    }

    public string ReasonCode { get; }
}

public sealed class McpRemoteException : McpClientException
{
    public McpRemoteException(int code, string message, JsonNode? data)
        : base("MCP_REMOTE_ERROR", $"MCP remote error {code}: {message}")
    {
        Code = code;
        DataNode = data?.DeepClone();
    }

    public int Code { get; }

    public JsonNode? DataNode { get; }
}
