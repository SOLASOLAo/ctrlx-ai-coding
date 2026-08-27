using System.Buffers;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Broker.Mcp;

/// <summary>
/// Strict, single-flight MCP stdio client. It owns exactly one child process,
/// uses UTF-8 JSONL framing, and faults permanently when response correlation
/// becomes uncertain (timeout, cancellation, malformed data, or wrong id).
/// </summary>
public sealed class JsonLineMcpClient : IMcpRpcClient
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false
    };

    private readonly McpProcessOptions options;
    private readonly string[] processArguments;
    private readonly HashSet<string> requiredTools;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();

    private Process? process;
    private BoundedJsonLineReader? stdout;
    private Task? stderrDrain;
    private McpClientState state = McpClientState.Created;
    private long nextRequestId;
    private int disposed;

    public JsonLineMcpClient(McpProcessOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();

        this.options = options with
        {
            Arguments = options.Arguments.ToArray(),
            RequiredTools = options.RequiredTools.ToArray()
        };
        processArguments = this.options.Arguments.ToArray();
        requiredTools = new HashSet<string>(this.options.RequiredTools, StringComparer.Ordinal);
    }

    public int? ProcessId
    {
        get
        {
            var current = process;
            if (current is null)
            {
                return null;
            }

            try
            {
                return current.HasExited ? null : current.Id;
            }
            catch (ObjectDisposedException)
            {
                return null;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }

    public McpHandshake? Handshake { get; private set; }

    public event Action<string>? StandardErrorReceived;

    public async Task<McpHandshake> StartAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (state != McpClientState.Created)
            {
                throw StateError("MCP stdio client can only be started once.");
            }

            state = McpClientState.Starting;
            StartChildProcess();

            using var timeout = CreateOperationTimeout(options.InitializeTimeout, cancellationToken);
            try
            {
                var initialize = await SendRequestCoreAsync(
                    "initialize",
                    new JsonObject
                    {
                        ["protocolVersion"] = options.RequestedProtocolVersion,
                        ["capabilities"] = new JsonObject(),
                        ["clientInfo"] = new JsonObject
                        {
                            ["name"] = options.ClientName,
                            ["version"] = options.ClientVersion
                        }
                    },
                    timeout.Token).ConfigureAwait(false);

                var identity = ValidateInitializeResult(initialize);
                await SendNotificationCoreAsync(
                    "notifications/initialized",
                    new JsonObject(),
                    timeout.Token).ConfigureAwait(false);

                var toolList = await SendRequestCoreAsync(
                    "tools/list",
                    new JsonObject(),
                    timeout.Token).ConfigureAwait(false);
                var tools = ValidateToolList(toolList);
                EnsureRequiredToolsAdvertised(requiredTools, tools);

                var handshake = new McpHandshake(
                    identity.ProtocolVersion,
                    identity.ServerName,
                    identity.ServerVersion,
                    (JsonObject)identity.Capabilities.DeepClone(),
                    tools);
                Handshake = handshake;
                state = McpClientState.Running;
                return handshake;
            }
            catch (OperationCanceledException exception)
            {
                state = McpClientState.Faulted;
                await TerminateChildCoreAsync().ConfigureAwait(false);
                if (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }

                throw new McpClientException(
                    "MCP_INITIALIZE_TIMEOUT",
                    $"MCP initialize handshake exceeded {options.InitializeTimeout}.",
                    exception);
            }
            catch
            {
                state = McpClientState.Faulted;
                await TerminateChildCoreAsync().ConfigureAwait(false);
                throw;
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<McpToolCallResult> CallToolAsync(
        string toolName,
        JsonObject? arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ValidateSingleLineValue(toolName, nameof(toolName));
        ValidateOperationTimeout(timeout);

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureRunning();
            if (Handshake is null || !Handshake.Tools.ContainsKey(toolName))
            {
                throw new McpClientException(
                    "MCP_TOOL_NOT_ADVERTISED",
                    $"MCP tool was not present in the verified tools/list response: {toolName}");
            }

            using var operationTimeout = CreateOperationTimeout(timeout, cancellationToken);
            JsonObject result;
            try
            {
                result = await SendRequestCoreAsync(
                    "tools/call",
                    new JsonObject
                    {
                        ["name"] = toolName,
                        ["arguments"] = arguments?.DeepClone() ?? new JsonObject()
                    },
                    operationTimeout.Token).ConfigureAwait(false);
            }
            catch (McpRemoteException)
            {
                throw;
            }
            catch (OperationCanceledException exception)
            {
                FaultAfterUncertainResponse();
                if (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }

                throw new McpClientException(
                    "MCP_CALL_TIMEOUT",
                    $"MCP tool '{toolName}' exceeded {timeout}; final IDE state is unknown.",
                    exception);
            }
            catch
            {
                FaultAfterUncertainResponse();
                throw;
            }

            try
            {
                return ValidateToolResult(toolName, result);
            }
            catch
            {
                FaultAfterUncertainResponse();
                throw;
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<McpResourceReadResult> ReadResourceAsync(
        string uri,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ValidateSingleLineValue(uri, nameof(uri));
        if (!System.Uri.TryCreate(uri, UriKind.Absolute, out _))
        {
            throw new ArgumentException("MCP resource URI must be absolute.", nameof(uri));
        }

        ValidateOperationTimeout(timeout);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureRunning();
            using var operationTimeout = CreateOperationTimeout(timeout, cancellationToken);
            JsonObject result;
            try
            {
                result = await SendRequestCoreAsync(
                    "resources/read",
                    new JsonObject { ["uri"] = uri },
                    operationTimeout.Token).ConfigureAwait(false);
            }
            catch (McpRemoteException)
            {
                throw;
            }
            catch (OperationCanceledException exception)
            {
                FaultAfterUncertainResponse();
                if (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }

                throw new McpClientException(
                    "MCP_RESOURCE_TIMEOUT",
                    $"MCP resource read exceeded {timeout}; response correlation is unknown.",
                    exception);
            }
            catch
            {
                FaultAfterUncertainResponse();
                throw;
            }

            try
            {
                return ValidateResourceResult(uri, result);
            }
            catch
            {
                FaultAfterUncertainResponse();
                throw;
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        lifetime.Cancel();
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (state == McpClientState.Stopped)
            {
                return;
            }

            await TerminateChildCoreAsync().ConfigureAwait(false);
            state = McpClientState.Stopped;
        }
        finally
        {
            gate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        try
        {
            await StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            lifetime.Dispose();
            gate.Dispose();
        }
    }

    private void StartChildProcess()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = options.ExecutablePath,
            WorkingDirectory = options.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = StrictUtf8,
            StandardOutputEncoding = StrictUtf8,
            StandardErrorEncoding = StrictUtf8
        };

        foreach (var argument in processArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        var child = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };

        try
        {
            if (!child.Start())
            {
                throw new McpClientException("MCP_PROCESS_START_FAILED", "MCP child process did not start.");
            }

            process = child;
            stdout = new BoundedJsonLineReader(child.StandardOutput.BaseStream);
            stderrDrain = DrainStandardErrorAsync(child.StandardError, lifetime.Token);
        }
        catch (Exception exception) when (exception is not McpClientException)
        {
            child.Dispose();
            throw new McpClientException(
                "MCP_PROCESS_START_FAILED",
                $"Failed to start the MCP child at '{options.ExecutablePath}'.",
                exception);
        }
    }

    private async Task<JsonObject> SendRequestCoreAsync(
        string method,
        JsonObject parameters,
        CancellationToken cancellationToken)
    {
        var requestId = checked(++nextRequestId);
        await WriteMessageCoreAsync(
            new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["id"] = requestId,
                ["method"] = method,
                ["params"] = parameters
            },
            cancellationToken).ConfigureAwait(false);

        return await ReadResponseCoreAsync(requestId, cancellationToken).ConfigureAwait(false);
    }

    private Task SendNotificationCoreAsync(
        string method,
        JsonObject parameters,
        CancellationToken cancellationToken) =>
        WriteMessageCoreAsync(
            new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["method"] = method,
                ["params"] = parameters
            },
            cancellationToken);

    private async Task WriteMessageCoreAsync(JsonObject message, CancellationToken cancellationToken)
    {
        var child = process ?? throw StateError("MCP process is unavailable.");
        if (child.HasExited)
        {
            throw new McpClientException(
                "MCP_PROCESS_EXITED",
                $"MCP process exited before the request was written (exit code {child.ExitCode}).");
        }

        var json = message.ToJsonString(CompactJson);
        if (json.IndexOfAny(['\r', '\n', '\0']) >= 0 || StrictUtf8.GetByteCount(json) > McpProcessOptions.MaximumMessageBytes)
        {
            throw ProtocolError("Outgoing MCP JSONL message is invalid or exceeds 1 MiB.");
        }

        await child.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken).ConfigureAwait(false);
        await child.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<JsonObject> ReadResponseCoreAsync(long expectedId, CancellationToken cancellationToken)
    {
        while (true)
        {
            var reader = stdout ?? throw StateError("MCP stdout is unavailable.");
            var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            var envelope = ParseObject(line, "MCP response");

            var version = RequiredString(envelope, "jsonrpc", "MCP envelope");
            if (!version.Equals("2.0", StringComparison.Ordinal))
            {
                throw ProtocolError("MCP response jsonrpc must equal '2.0'.");
            }

            if (envelope["method"] is not null)
            {
                ValidateAndIgnoreNotification(envelope);
                continue;
            }

            RequireOnly(envelope, "MCP response", "jsonrpc", "id", "result", "error");
            var responseId = RequiredInt64(envelope, "id", "MCP response");
            if (responseId != expectedId)
            {
                throw ProtocolError($"MCP response id mismatch: expected {expectedId}, received {responseId}.");
            }

            var hasResult = envelope["result"] is not null;
            var hasError = envelope["error"] is not null;
            if (hasResult == hasError)
            {
                throw ProtocolError("MCP response must contain exactly one of result or error.");
            }

            if (hasError)
            {
                if (envelope["error"] is not JsonObject error)
                {
                    throw ProtocolError("MCP response error must be an object.");
                }

                RequireOnly(error, "MCP error", "code", "message", "data");
                var code = RequiredInt32(error, "code", "MCP error");
                var message = RequiredString(error, "message", "MCP error");
                throw new McpRemoteException(code, message, error["data"]);
            }

            if (envelope["result"] is not JsonObject result)
            {
                throw ProtocolError("MCP response result must be an object.");
            }

            return (JsonObject)result.DeepClone();
        }
    }

    private InitializeIdentity ValidateInitializeResult(JsonObject result)
    {
        RequireOnly(result, "MCP initialize result", "protocolVersion", "capabilities", "serverInfo", "instructions", "_meta");
        var protocolVersion = RequiredString(result, "protocolVersion", "MCP initialize result");
        if (!protocolVersion.Equals(options.RequestedProtocolVersion, StringComparison.Ordinal))
        {
            throw new McpClientException(
                "MCP_PROTOCOL_VERSION_MISMATCH",
                $"Expected MCP protocol {options.RequestedProtocolVersion}, received {protocolVersion}.");
        }

        if (result["capabilities"] is not JsonObject capabilities ||
            capabilities["tools"] is not JsonObject ||
            capabilities["resources"] is not JsonObject)
        {
            throw ProtocolError("MCP server did not advertise tools and resources capabilities.");
        }

        if (result["serverInfo"] is not JsonObject serverInfo)
        {
            throw ProtocolError("MCP initialize result has no serverInfo object.");
        }

        var serverName = RequiredString(serverInfo, "name", "MCP serverInfo");
        var serverVersion = RequiredString(serverInfo, "version", "MCP serverInfo");
        if (!serverName.Equals(options.ExpectedServerName, StringComparison.Ordinal) ||
            !serverVersion.Equals(options.ExpectedServerVersion, StringComparison.Ordinal))
        {
            throw new McpClientException(
                "MCP_SERVER_IDENTITY_MISMATCH",
                $"Unexpected MCP server identity '{serverName}' version '{serverVersion}'.");
        }

        return new InitializeIdentity(protocolVersion, serverName, serverVersion, capabilities);
    }

    private IReadOnlyDictionary<string, McpToolDescriptor> ValidateToolList(JsonObject result)
    {
        RequireOnly(result, "MCP tools/list result", "tools", "nextCursor", "_meta");
        if (result["nextCursor"] is not null)
        {
            throw ProtocolError("Paginated MCP tools/list responses are not supported by this fixed server contract.");
        }

        if (result["tools"] is not JsonArray tools)
        {
            throw ProtocolError("MCP tools/list result has no tools array.");
        }

        var descriptors = new Dictionary<string, McpToolDescriptor>(StringComparer.Ordinal);
        foreach (var node in tools)
        {
            if (node is not JsonObject tool)
            {
                throw ProtocolError("MCP tools/list contains a non-object item.");
            }

            RequireOnly(
                tool,
                "MCP tool descriptor",
                "name",
                "title",
                "description",
                "inputSchema",
                "outputSchema",
                "annotations",
                "execution",
                "_meta");
            var name = RequiredString(tool, "name", "MCP tool descriptor");
            ValidateSingleLineValue(name, "MCP tool name");
            if (tool["inputSchema"] is not JsonObject inputSchema)
            {
                throw ProtocolError($"MCP tool '{name}' has no inputSchema object.");
            }

            var description = OptionalString(tool, "description", "MCP tool descriptor");
            if (!descriptors.TryAdd(
                    name,
                    new McpToolDescriptor(
                        name,
                        description,
                        (JsonObject)inputSchema.DeepClone(),
                        (JsonObject)tool.DeepClone())))
            {
                throw ProtocolError($"MCP tools/list contains duplicate tool '{name}'.");
            }
        }

        return descriptors;
    }

    internal static void EnsureRequiredToolsAdvertised(
        IEnumerable<string> required,
        IReadOnlyDictionary<string, McpToolDescriptor> advertised)
    {
        ArgumentNullException.ThrowIfNull(required);
        ArgumentNullException.ThrowIfNull(advertised);
        foreach (var requiredTool in required)
        {
            if (!advertised.ContainsKey(requiredTool))
            {
                throw ProtocolError($"Required MCP tool is not advertised: {requiredTool}");
            }
        }
    }

    private static McpToolCallResult ValidateToolResult(string toolName, JsonObject result)
    {
        RequireOnly(result, "MCP tool result", "content", "isError", "structuredContent", "_meta");
        if (result["content"] is not JsonArray content)
        {
            throw ProtocolError("MCP tool result has no content array.");
        }

        var isError = RequiredBoolean(result, "isError", "MCP tool result");
        return new McpToolCallResult(
            toolName,
            isError,
            ExtractTextContent(content, "MCP tool result"),
            (JsonObject)result.DeepClone());
    }

    private static McpResourceReadResult ValidateResourceResult(string uri, JsonObject result)
    {
        RequireOnly(result, "MCP resource result", "contents", "isError", "_meta");
        if (result["contents"] is not JsonArray contents)
        {
            throw ProtocolError("MCP resource result has no contents array.");
        }

        var isError = result["isError"] is null
            ? false
            : RequiredBoolean(result, "isError", "MCP resource result");
        return new McpResourceReadResult(
            uri,
            isError,
            ExtractTextContent(contents, "MCP resource result"),
            (JsonObject)result.DeepClone());
    }

    private static IReadOnlyList<string> ExtractTextContent(JsonArray content, string context)
    {
        var text = new List<string>();
        foreach (var node in content)
        {
            if (node is not JsonObject item)
            {
                throw ProtocolError($"{context} contains a non-object content item.");
            }

            if (item["type"] is JsonValue typeNode &&
                typeNode.TryGetValue<string>(out var type) &&
                type.Equals("text", StringComparison.Ordinal))
            {
                text.Add(RequiredString(item, "text", context));
                continue;
            }

            // Resource content from this MCP version does not include a type;
            // it uses { uri, text, contentType }. Preserve its text as evidence.
            if (item["text"] is JsonValue textNode && textNode.TryGetValue<string>(out var resourceText))
            {
                text.Add(resourceText);
            }
        }

        return text;
    }

    private static JsonObject ParseObject(byte[] utf8, string context)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object || HasDuplicateProperty(document.RootElement))
            {
                throw ProtocolError($"{context} must be one JSON object without duplicate properties.");
            }

            if (JsonNode.Parse(utf8, nodeOptions: null, documentOptions: new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64
                }) is not JsonObject result)
            {
                throw ProtocolError($"{context} could not be parsed as a JSON object.");
            }

            return result;
        }
        catch (JsonException exception)
        {
            throw new McpClientException("MCP_PROTOCOL_INVALID", $"{context} is invalid JSON.", exception);
        }
    }

    private static bool HasDuplicateProperty(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name) || HasDuplicateProperty(property.Value))
                {
                    return true;
                }
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in element.EnumerateArray())
            {
                if (HasDuplicateProperty(child))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static void ValidateAndIgnoreNotification(JsonObject envelope)
    {
        RequireOnly(envelope, "MCP notification", "jsonrpc", "method", "params");
        if (envelope["id"] is not null)
        {
            throw ProtocolError("Server-initiated MCP requests are not supported.");
        }

        var method = RequiredString(envelope, "method", "MCP notification");
        if (!method.StartsWith("notifications/", StringComparison.Ordinal))
        {
            throw ProtocolError($"Unexpected MCP server message method: {method}");
        }

        if (envelope["params"] is not null && envelope["params"] is not JsonObject)
        {
            throw ProtocolError("MCP notification params must be an object when present.");
        }
    }

    private async Task DrainStandardErrorAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        const int maximumDiagnosticCharacters = 64 * 1024;
        var buffer = new char[4096];
        var line = new StringBuilder();
        var truncated = false;

        try
        {
            while (true)
            {
                var read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }

                for (var index = 0; index < read; index++)
                {
                    var character = buffer[index];
                    if (character == '\n')
                    {
                        EmitDiagnostic(line, truncated);
                        line.Clear();
                        truncated = false;
                    }
                    else if (character != '\r')
                    {
                        if (line.Length < maximumDiagnosticCharacters)
                        {
                            line.Append(character);
                        }
                        else
                        {
                            truncated = true;
                        }
                    }
                }
            }

            if (line.Length > 0 || truncated)
            {
                EmitDiagnostic(line, truncated);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal during StopAsync.
        }
        catch (ObjectDisposedException)
        {
            // Normal when a failed handshake tears the child down.
        }
    }

    private void EmitDiagnostic(StringBuilder line, bool truncated)
    {
        var handler = StandardErrorReceived;
        if (handler is null)
        {
            return;
        }

        var message = truncated ? line + "...[truncated]" : line.ToString();
        try
        {
            handler(message);
        }
        catch
        {
            // A diagnostic subscriber must never block or fault protocol I/O.
        }
    }

    private async Task TerminateChildCoreAsync()
    {
        lifetime.Cancel();
        var child = process;
        if (child is null)
        {
            return;
        }

        try
        {
            child.StandardInput.Close();
        }
        catch
        {
            // Best effort; a failed handshake may already have closed stdin.
        }

        if (!child.HasExited)
        {
            using var wait = new CancellationTokenSource(options.ShutdownTimeout);
            try
            {
                await child.WaitForExitAsync(wait.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    // Never kill the whole tree: ctrlX PLE is a separately
                    // managed visible process and has its own lifecycle gate.
                    child.Kill(entireProcessTree: false);
                }
                catch
                {
                    // Process may have exited between the check and Kill.
                }

                try
                {
                    await child.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                }
                catch
                {
                    // Disposal below is the final local cleanup.
                }
            }
        }

        if (stderrDrain is not null)
        {
            try
            {
                await stderrDrain.ConfigureAwait(false);
            }
            catch
            {
                // Diagnostics are non-authoritative and already drained best effort.
            }
        }

        child.Dispose();
        process = null;
        stdout?.Dispose();
        stdout = null;
    }

    private CancellationTokenSource CreateOperationTimeout(TimeSpan timeout, CancellationToken callerToken)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(callerToken, lifetime.Token);
        source.CancelAfter(timeout);
        return source;
    }

    private void EnsureRunning()
    {
        if (state != McpClientState.Running || process is null || process.HasExited || Handshake is null)
        {
            throw StateError($"MCP stdio client is not running (state: {state}).");
        }
    }

    private void FaultAfterUncertainResponse()
    {
        if (state == McpClientState.Running)
        {
            state = McpClientState.Faulted;
        }
    }

    private static void ValidateOperationTimeout(TimeSpan timeout)
    {
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(timeout),
                "MCP operation timeout must be greater than zero and no more than one hour.");
        }
    }

    private static void ValidateSingleLineValue(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) || value.IndexOfAny(['\0', '\r', '\n']) >= 0)
        {
            throw new ArgumentException("Value must be a non-empty single-line string.", parameterName);
        }
    }

    private static void RequireOnly(JsonObject value, string context, params string[] allowedProperties)
    {
        var allowed = new HashSet<string>(allowedProperties, StringComparer.Ordinal);
        foreach (var property in value)
        {
            if (!allowed.Contains(property.Key))
            {
                throw ProtocolError($"{context} contains unsupported property '{property.Key}'.");
            }
        }
    }

    private static string RequiredString(JsonObject value, string propertyName, string context)
    {
        if (value[propertyName] is not JsonValue node ||
            !node.TryGetValue<string>(out var result) ||
            string.IsNullOrWhiteSpace(result) ||
            result.IndexOfAny(['\0', '\r']) >= 0)
        {
            throw ProtocolError($"{context}.{propertyName} must be a non-empty string.");
        }

        return result;
    }

    private static string? OptionalString(JsonObject value, string propertyName, string context)
    {
        if (value[propertyName] is null)
        {
            return null;
        }

        return RequiredString(value, propertyName, context);
    }

    private static bool RequiredBoolean(JsonObject value, string propertyName, string context)
    {
        if (value[propertyName] is not JsonValue node || !node.TryGetValue<bool>(out var result))
        {
            throw ProtocolError($"{context}.{propertyName} must be a boolean.");
        }

        return result;
    }

    private static int RequiredInt32(JsonObject value, string propertyName, string context)
    {
        if (value[propertyName] is not JsonValue node || !node.TryGetValue<int>(out var result))
        {
            throw ProtocolError($"{context}.{propertyName} must be an Int32.");
        }

        return result;
    }

    private static long RequiredInt64(JsonObject value, string propertyName, string context)
    {
        if (value[propertyName] is not JsonValue node || !node.TryGetValue<long>(out var result))
        {
            throw ProtocolError($"{context}.{propertyName} must be an Int64.");
        }

        return result;
    }

    private static McpClientException ProtocolError(string message) =>
        new("MCP_PROTOCOL_INVALID", message);

    private static McpClientException StateError(string message) =>
        new("MCP_STATE_INVALID", message);

    private sealed record InitializeIdentity(
        string ProtocolVersion,
        string ServerName,
        string ServerVersion,
        JsonObject Capabilities);

    private enum McpClientState
    {
        Created,
        Starting,
        Running,
        Faulted,
        Stopped
    }

    private sealed class BoundedJsonLineReader : IDisposable
    {
        private readonly Stream stream;
        private readonly byte[] buffer = ArrayPool<byte>.Shared.Rent(8192);
        private int start;
        private int end;
        private bool disposed;

        public BoundedJsonLineReader(Stream stream)
        {
            this.stream = stream;
        }

        public async Task<byte[]> ReadLineAsync(CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            using var line = new MemoryStream(capacity: 4096);

            while (true)
            {
                if (start < end)
                {
                    var newline = Array.IndexOf(buffer, (byte)'\n', start, end - start);
                    var segmentEnd = newline >= 0 ? newline : end;
                    var segmentLength = segmentEnd - start;
                    if (line.Length + segmentLength > McpProcessOptions.MaximumMessageBytes)
                    {
                        throw ProtocolError("Incoming MCP JSONL message exceeds 1 MiB.");
                    }

                    line.Write(buffer, start, segmentLength);
                    start = newline >= 0 ? newline + 1 : end;
                    if (newline >= 0)
                    {
                        var result = line.ToArray();
                        if (result.Length > 0 && result[^1] == (byte)'\r')
                        {
                            Array.Resize(ref result, result.Length - 1);
                        }

                        if (result.Length == 0 || Array.IndexOf(result, (byte)'\r') >= 0)
                        {
                            throw ProtocolError("Incoming MCP JSONL message is empty or contains a raw carriage return.");
                        }

                        return result;
                    }
                }

                start = 0;
                end = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (end == 0)
                {
                    throw new McpClientException("MCP_STDOUT_CLOSED", "MCP stdout closed before a complete response arrived.");
                }
            }
        }

        public void Dispose()
        {
            DisposeBuffer();
            GC.SuppressFinalize(this);
        }

        ~BoundedJsonLineReader() => DisposeBuffer();

        private void DisposeBuffer()
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
        }
    }
}
