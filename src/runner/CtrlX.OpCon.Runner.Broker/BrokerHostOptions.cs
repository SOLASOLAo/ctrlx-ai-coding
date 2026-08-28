using CtrlX.OpCon.Runner.Broker.Mcp;

namespace CtrlX.OpCon.Runner.Broker;

public sealed record BrokerHostOptions
{
    public required string EngineeringRoot { get; init; }

    public required string StationRoot { get; init; }

    public required string PlcProject { get; init; }

    public required string Profile { get; init; }

    public required McpProcessOptions Mcp { get; init; }

    public TimeSpan OwnerLeaseTimeout { get; init; } = TimeSpan.FromSeconds(2);

    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan HeartbeatTtl { get; init; } = TimeSpan.FromSeconds(15);

    public TimeSpan SessionStartupTimeout { get; init; } = TimeSpan.FromMinutes(5);

    public TimeSpan StatusTimeout { get; init; } = TimeSpan.FromSeconds(30);

    public TimeSpan BuildTimeout { get; init; } = TimeSpan.FromMinutes(20);

    // Test seam only. Production always derives the current-user checkpoint
    // root from BrokerRuntimePaths and never accepts it from an action/client.
    internal string? ProjectCheckpointRoot { get; init; }

    public void Validate()
    {
        RequireDirectory(EngineeringRoot, nameof(EngineeringRoot));
        RequireDirectory(StationRoot, nameof(StationRoot));
        RequireFile(PlcProject, nameof(PlcProject));
        if (!Path.GetFullPath(PlcProject).StartsWith(
                Path.GetFullPath(StationRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("The PLC project must be inside the Station root.", nameof(PlcProject));
        }

        if (string.IsNullOrWhiteSpace(Profile) || Profile.IndexOfAny(['\0', '\r', '\n']) >= 0)
        {
            throw new ArgumentException("The exact PLE profile is required.", nameof(Profile));
        }

        ArgumentNullException.ThrowIfNull(Mcp);
        ValidateRange(OwnerLeaseTimeout, TimeSpan.FromMilliseconds(100), TimeSpan.FromMinutes(2), nameof(OwnerLeaseTimeout));
        ValidateRange(HeartbeatInterval, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(10), nameof(HeartbeatInterval));
        ValidateRange(HeartbeatTtl, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(30), nameof(HeartbeatTtl));
        if (HeartbeatTtl <= HeartbeatInterval)
        {
            throw new ArgumentException("Heartbeat TTL must exceed the heartbeat interval.", nameof(HeartbeatTtl));
        }

        ValidateRange(SessionStartupTimeout, TimeSpan.FromSeconds(10), TimeSpan.FromMinutes(15), nameof(SessionStartupTimeout));
        ValidateRange(StatusTimeout, TimeSpan.FromSeconds(1), TimeSpan.FromMinutes(2), nameof(StatusTimeout));
        ValidateRange(BuildTimeout, TimeSpan.FromMinutes(17), TimeSpan.FromHours(1), nameof(BuildTimeout));
    }

    private static void RequireDirectory(string path, string name)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || !Directory.Exists(path))
        {
            throw new ArgumentException($"{name} must be an existing absolute directory.", name);
        }
    }

    private static void RequireFile(string path, string name)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || !File.Exists(path))
        {
            throw new ArgumentException($"{name} must be an existing absolute file.", name);
        }
    }

    private static void ValidateRange(TimeSpan value, TimeSpan minimum, TimeSpan maximum, string name)
    {
        if (value < minimum || value > maximum)
        {
            throw new ArgumentOutOfRangeException(name, $"{name} must be between {minimum} and {maximum}.");
        }
    }
}
