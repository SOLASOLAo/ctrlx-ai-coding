namespace CtrlX.OpCon.Runner.Broker.Mcp;

/// <summary>
/// Immutable process and MCP handshake settings for the Broker-owned stdio
/// child. The executable and working directory must be absolute so PATH or
/// shell resolution can never select a different program.
/// </summary>
public sealed record McpProcessOptions
{
    public const int MaximumMessageBytes = 1024 * 1024;

    public required string ExecutablePath { get; init; }

    public IReadOnlyList<string> Arguments { get; init; } = Array.Empty<string>();

    public required string WorkingDirectory { get; init; }

    public string RequestedProtocolVersion { get; init; } = "2025-11-25";

    public string ClientName { get; init; } = "CtrlX.OpCon.Runner.Broker";

    public string ClientVersion { get; init; } = "1.0.0";

    public string ExpectedServerName { get; init; } = "CODESYS Persistent MCP Server";

    public string ExpectedServerVersion { get; init; } = "0.6.3";

    public TimeSpan InitializeTimeout { get; init; } = TimeSpan.FromSeconds(15);

    public TimeSpan ShutdownTimeout { get; init; } = TimeSpan.FromSeconds(5);

    public IReadOnlyCollection<string> RequiredTools { get; init; } =
    [
        "launch_codesys",
        "shutdown_codesys",
        "get_codesys_status",
        "open_project",
        "compile_project"
    ];

    internal void Validate()
    {
        ValidateAbsoluteFile(ExecutablePath, nameof(ExecutablePath));

        if (string.IsNullOrWhiteSpace(WorkingDirectory) ||
            !Path.IsPathFullyQualified(WorkingDirectory) ||
            !Directory.Exists(WorkingDirectory))
        {
            throw new ArgumentException(
                "The MCP working directory must be an existing absolute directory.",
                nameof(WorkingDirectory));
        }

        ValidateToken(RequestedProtocolVersion, nameof(RequestedProtocolVersion));
        ValidateToken(ClientName, nameof(ClientName));
        ValidateToken(ClientVersion, nameof(ClientVersion));
        ValidateToken(ExpectedServerName, nameof(ExpectedServerName));
        ValidateToken(ExpectedServerVersion, nameof(ExpectedServerVersion));

        if (InitializeTimeout <= TimeSpan.Zero || InitializeTimeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(
                nameof(InitializeTimeout),
                "Initialize timeout must be greater than zero and no more than two minutes.");
        }

        if (ShutdownTimeout <= TimeSpan.Zero || ShutdownTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(ShutdownTimeout),
                "Shutdown timeout must be greater than zero and no more than one minute.");
        }

        foreach (var argument in Arguments)
        {
            if (argument is null || argument.IndexOfAny(['\0', '\r', '\n']) >= 0)
            {
                throw new ArgumentException(
                    "MCP process arguments must be non-null single-line values without NUL characters.",
                    nameof(Arguments));
            }
        }

        var required = new HashSet<string>(StringComparer.Ordinal);
        foreach (var tool in RequiredTools)
        {
            ValidateToken(tool, nameof(RequiredTools));
            if (!required.Add(tool))
            {
                throw new ArgumentException($"Required MCP tool is duplicated: {tool}", nameof(RequiredTools));
            }
        }
    }

    private static void ValidateAbsoluteFile(string path, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            !File.Exists(path))
        {
            throw new ArgumentException(
                "The MCP executable must be an existing absolute file.",
                parameterName);
        }
    }

    private static void ValidateToken(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) || value.IndexOfAny(['\0', '\r', '\n']) >= 0)
        {
            throw new ArgumentException(
                "MCP identity values must be non-empty single-line strings.",
                parameterName);
        }
    }
}
