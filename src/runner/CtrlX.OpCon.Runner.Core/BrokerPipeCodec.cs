using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public static class BrokerPipeCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly JsonSerializerOptions CompactJson = new() { WriteIndented = false };

    public static async Task WriteAsync(Stream stream, JsonObject message, CancellationToken cancellationToken)
    {
        var json = message.ToJsonString(CompactJson);
        if (json.IndexOfAny(['\r', '\n']) >= 0)
        {
            throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker message contains a line break.");
        }

        var bytes = StrictUtf8.GetBytes(json);
        if (bytes.Length == 0 || bytes.Length > BrokerWireProtocol.MaximumMessageBytes)
        {
            throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker message exceeds the bounded frame size.");
        }

        await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(new byte[] { (byte)'\n' }, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<JsonObject> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[4096];
        using var line = new MemoryStream(4096);
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker message ended before a complete frame was received.");
            }

            var newline = Array.IndexOf(buffer, (byte)'\n', 0, read);
            var bodyLength = newline < 0 ? read : newline;
            if (line.Length + bodyLength > BrokerWireProtocol.MaximumMessageBytes)
            {
                throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker message exceeds the bounded frame size.");
            }

            line.Write(buffer, 0, bodyLength);
            if (newline < 0)
            {
                continue;
            }

            for (var index = newline + 1; index < read; index++)
            {
                if (buffer[index] is not (byte)' ' and not (byte)'\t')
                {
                    throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker frame contains trailing data.");
                }
            }

            var bytes = line.ToArray();
            if (bytes.Length == 0 || Array.IndexOf(bytes, (byte)'\r') >= 0)
            {
                throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker frame is empty or contains CR characters.");
            }

            _ = StrictUtf8.GetString(bytes);
            using (var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            }))
            {
                if (document.RootElement.ValueKind != JsonValueKind.Object || HasDuplicateProperty(document.RootElement))
                {
                    throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker frame is not a unique-property JSON object.");
                }
            }

            return JsonNode.Parse(bytes, nodeOptions: null, documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            }) as JsonObject
                ?? throw new RunnerGateException("BROKER_PROTOCOL_INVALID", "Broker frame is not a JSON object.");
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
}
