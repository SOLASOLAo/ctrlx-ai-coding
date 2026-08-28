using System.Security.Cryptography;
using System.Text;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public sealed class BrokerRuntimePaths
{
    public BrokerRuntimePaths(string engineeringRoot, string profile, string plcProject)
        : this(engineeringRoot, InferStationRoot(plcProject), profile, plcProject)
    {
    }

    public BrokerRuntimePaths(string engineeringRoot, string stationRoot, string profile, string plcProject)
    {
        if (string.IsNullOrWhiteSpace(profile))
        {
            throw new ArgumentException("The PLE profile is required.", nameof(profile));
        }

        EngineeringRoot = NormalizePath(engineeringRoot);
        StationRoot = NormalizePath(stationRoot);
        Profile = profile.Trim();
        PlcProject = NormalizePath(plcProject);

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new BrokerInfrastructureException("BROKER_LOCALAPPDATA_UNAVAILABLE", "LocalApplicationData is unavailable.");
        }

        var identityText = string.Join("\n", CanonicalForIdentity(EngineeringRoot), Profile, CanonicalForIdentity(PlcProject));
        IdentityKey = Sha256Text(identityText);
        ProductRoot = Path.Combine(NormalizePath(localAppData), "CtrlX.OpCon.Runner");
        IdentityRoot = Path.Combine(ProductRoot, "identities", IdentityKey.ToLowerInvariant());
        ProfileLeaseKey = Sha256Text(Profile.ToUpperInvariant());
        // A CODESYS/ctrlX profile is the real process-wide exclusion domain.
        // Scoping the owner lock only by project would allow two Brokers for
        // different projects to start competing PLE instances on one profile.
        LeaseRoot = Path.Combine(ProductRoot, "leases", "profiles", ProfileLeaseKey.ToLowerInvariant());
        RegistrationPath = Path.GetFullPath(BrokerWireProtocol.GetDefaultRegistrationPath(EngineeringRoot));
        RegistrationRoot = Path.GetDirectoryName(RegistrationPath)
            ?? throw new BrokerInfrastructureException("BROKER_REGISTRATION_PATH_INVALID", "Broker registration path has no parent directory.");
        OperationsRoot = Path.Combine(IdentityRoot, "operations");
        ProjectCheckpointsRoot = Path.Combine(IdentityRoot, "checkpoints", "plc-projects");
    }

    public string EngineeringRoot { get; }

    public string StationRoot { get; }

    public string Profile { get; }

    public string PlcProject { get; }

    public string IdentityKey { get; }

    public string ProfileLeaseKey { get; }

    public string ProductRoot { get; }

    public string IdentityRoot { get; }

    public string LeaseRoot { get; }

    public string RegistrationRoot { get; }

    public string RegistrationPath { get; }

    public string OperationsRoot { get; }

    public string ProjectCheckpointsRoot { get; }

    public void EnsureCreated()
    {
        Directory.CreateDirectory(LeaseRoot);
        Directory.CreateDirectory(RegistrationRoot);
        Directory.CreateDirectory(OperationsRoot);
    }

    public string OperationDirectory(string executionId)
    {
        BrokerValueValidation.RequireSafeIdentifier(executionId, nameof(executionId), maximumLength: 96);
        return Path.Combine(OperationsRoot, executionId);
    }

    internal static string NormalizePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("A non-empty absolute path is required.", nameof(path));
        }

        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath) ?? string.Empty;
        while (fullPath.Length > root.Length &&
               (fullPath.EndsWith(Path.DirectorySeparatorChar) || fullPath.EndsWith(Path.AltDirectorySeparatorChar)))
        {
            fullPath = fullPath[..^1];
        }

        return fullPath;
    }

    internal static string Sha256Text(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    internal static string Sha256File(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string CanonicalForIdentity(string path) =>
        OperatingSystem.IsWindows() ? path.ToUpperInvariant() : path;

    private static string InferStationRoot(string plcProject)
    {
        var project = NormalizePath(plcProject);
        var plcDirectory = Path.GetDirectoryName(project);
        var stationRoot = plcDirectory is null ? null : Directory.GetParent(plcDirectory)?.FullName;
        if (string.IsNullOrWhiteSpace(stationRoot))
        {
            throw new BrokerInfrastructureException(
                "BROKER_STATION_ROOT_REQUIRED",
                "The station root could not be inferred from the PLC project; use the constructor with an explicit station root.");
        }

        return stationRoot;
    }
}
