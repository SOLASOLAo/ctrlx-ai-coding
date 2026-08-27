using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

internal static class BrokerAtomicJson
{
    private const int MaximumStateBytes = 4 * 1024 * 1024;
    private const int MaximumMoveAttempts = 6;
    private const int InitialMoveRetryDelayMilliseconds = 10;
    private const int MaximumMoveRetryDelayMilliseconds = 80;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true
    };

    public static T Read<T>(string path, string description)
    {
        if (!File.Exists(path))
        {
            throw new BrokerInfrastructureException("BROKER_STATE_NOT_FOUND", $"{description} does not exist: {path}");
        }

        try
        {
            var fileInfo = new FileInfo(path);
            if ((fileInfo.Attributes & FileAttributes.ReparsePoint) != 0 || fileInfo.Length > MaximumStateBytes)
            {
                throw new BrokerInfrastructureException(
                    "BROKER_STATE_INVALID",
                    $"{description} is a reparse point or exceeds {MaximumStateBytes} bytes: {path}");
            }

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length > MaximumStateBytes)
            {
                throw new BrokerInfrastructureException(
                    "BROKER_STATE_INVALID",
                    $"{description} exceeds {MaximumStateBytes} bytes: {path}");
            }

            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object || HasDuplicateProperty(document.RootElement))
            {
                throw new JsonException("The root must be an object without duplicate properties.");
            }

            return JsonSerializer.Deserialize<T>(bytes, Options)
                ?? throw new JsonException("The JSON payload deserialized to null.");
        }
        catch (Exception exception) when (exception is JsonException or DecoderFallbackException)
        {
            throw new BrokerInfrastructureException(
                "BROKER_STATE_INVALID",
                $"{description} is not valid strict JSON: {path}",
                exception);
        }
    }

    public static void Write(string path, object value, bool overwrite)
    {
        var resolvedPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(resolvedPath)
            ?? throw new BrokerInfrastructureException("BROKER_PATH_INVALID", $"State path has no parent: {resolvedPath}");
        Directory.CreateDirectory(directory);
        RejectReparsePoint(directory);

        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Options);
        if (bytes.Length > MaximumStateBytes)
        {
            throw new BrokerInfrastructureException(
                "BROKER_STATE_TOO_LARGE",
                $"Broker state exceeds {MaximumStateBytes} bytes: {resolvedPath}");
        }

        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.WriteByte((byte)'\n');
                stream.Flush(flushToDisk: true);
            }

            if (!overwrite && File.Exists(resolvedPath))
            {
                throw new BrokerInfrastructureException(
                    "BROKER_IMMUTABLE_STATE_EXISTS",
                    $"Immutable Broker state already exists: {resolvedPath}");
            }

            MoveWithTransientRetry(temporaryPath, resolvedPath, overwrite);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void MoveWithTransientRetry(string sourcePath, string destinationPath, bool overwrite)
    {
        for (var attempt = 1; ; attempt++)
        {
            if (!overwrite && File.Exists(destinationPath))
            {
                ThrowImmutableStateExists(destinationPath);
            }

            try
            {
                File.Move(sourcePath, destinationPath, overwrite);
                return;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Re-evaluate immutable state after every failed rename. A destination that
                // wins the create race is a stable idempotency conflict, never a transient
                // sharing violation and never eligible for overwrite.
                if (!overwrite && File.Exists(destinationPath))
                {
                    ThrowImmutableStateExists(destinationPath);
                }

                if (!IsTransientWindowsMoveFailure(exception) || attempt >= MaximumMoveAttempts)
                {
                    throw;
                }

                // Antivirus and indexers can briefly open a just-written state file without
                // delete sharing. Keep the atomic rename semantics, retry only for a short,
                // bounded Windows window, and let the final exception fail the operation.
                var delayMilliseconds = Math.Min(
                    InitialMoveRetryDelayMilliseconds << (attempt - 1),
                    MaximumMoveRetryDelayMilliseconds);
                Thread.Sleep(delayMilliseconds);
            }
        }
    }

    private static bool IsTransientWindowsMoveFailure(Exception exception)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        // Win32: ERROR_ACCESS_DENIED (5), ERROR_SHARING_VIOLATION (32),
        // ERROR_LOCK_VIOLATION (33). Antivirus commonly surfaces the first two.
        return (exception.HResult & 0xFFFF) is 5 or 32 or 33;
    }

    private static void ThrowImmutableStateExists(string path) =>
        throw new BrokerInfrastructureException(
            "BROKER_IMMUTABLE_STATE_EXISTS",
            $"Immutable Broker state already exists: {path}");

    private static void RejectReparsePoint(string directory)
    {
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BrokerInfrastructureException(
                "BROKER_PATH_REPARSE_POINT",
                $"Broker runtime state directory must not be a reparse point: {directory}");
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
