using System.Security.Cryptography;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

internal sealed record BrokerProjectCheckpointProof(
    string IdentityKey,
    string CheckpointId,
    string RelativePath,
    string ProjectSha256,
    string CheckpointSha256,
    long Length,
    bool CreatedNow,
    bool AtomicWriteVerified,
    bool ReadbackVerified,
    string? FailureReason = null)
{
    public bool Verified =>
        AtomicWriteVerified &&
        ReadbackVerified &&
        string.IsNullOrWhiteSpace(FailureReason) &&
        ProjectSha256.Equals(CheckpointSha256, StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Stores one immutable local recovery copy for each distinct PLC project SHA.
/// It never overwrites an existing checkpoint and never restores a project.
/// </summary>
internal sealed class BrokerProjectCheckpointStore
{
    private const int BufferSize = 128 * 1024;
    private readonly string root;
    private readonly string identityKey;

    public BrokerProjectCheckpointStore(string root, string identityKey)
    {
        this.root = Path.GetFullPath(root ?? throw new ArgumentNullException(nameof(root)));
        this.identityKey = RequireSha256(identityKey, nameof(identityKey));
    }

    public BrokerProjectCheckpointProof Ensure(
        string sourcePath,
        string expectedSha256,
        long expectedLength)
    {
        var source = Path.GetFullPath(sourcePath);
        var expectedSha = RequireSha256(expectedSha256, nameof(expectedSha256));
        if (expectedLength < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(expectedLength));
        }

        RejectFileReparsePoint(source, "RECOVERABLE_CHECKPOINT_SOURCE_UNSAFE");
        var destination = CheckpointPath(expectedSha);
        var directory = Path.GetDirectoryName(destination)
            ?? throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_PATH_INVALID",
                "Recovery checkpoint path has no parent directory.");
        EnsureSafeDirectory(root);
        EnsureSafeDirectory(Path.Combine(root, "sha256"));
        EnsureSafeDirectory(directory);

        if (File.Exists(destination))
        {
            return VerifyExisting(destination, expectedSha, expectedLength, createdNow: false);
        }

        var temporary = Path.Combine(directory, $".{expectedSha}.{Guid.NewGuid():N}.tmp");
        var createdNow = true;
        try
        {
            var copied = CopyAndHash(source, temporary);
            if (copied.Length != expectedLength ||
                !copied.Sha256.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new BrokerInfrastructureException(
                    "RECOVERABLE_CHECKPOINT_SOURCE_DRIFT",
                    "PLC project bytes changed while the pre-Build recovery checkpoint was being created.");
            }

            try
            {
                File.Move(temporary, destination, overwrite: false);
            }
            catch (IOException) when (File.Exists(destination))
            {
                // A concurrent creator won the immutable destination. Its bytes
                // must still match before it may be reused.
                createdNow = false;
            }

            return VerifyExisting(destination, expectedSha, expectedLength, createdNow);
        }
        catch (BrokerInfrastructureException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_CREATE_FAILED",
                "The local PLC recovery checkpoint could not be created.",
                exception);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                try
                {
                    File.Delete(temporary);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    // A stale random temp file is never accepted as a checkpoint.
                    // Cleanup is best-effort and cannot invalidate a verified blob.
                }
            }
        }
    }

    public BrokerProjectCheckpointProof Verify(BrokerProjectCheckpointProof proof)
    {
        ArgumentNullException.ThrowIfNull(proof);
        if (!proof.IdentityKey.Equals(identityKey, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_IDENTITY_MISMATCH",
                "Recovery checkpoint identity does not match the active Broker project identity.");
        }

        var sha = RequireSha256(proof.ProjectSha256, nameof(proof.ProjectSha256));
        var verified = VerifyExisting(CheckpointPath(sha), sha, proof.Length, proof.CreatedNow);
        if (!verified.CheckpointId.Equals(proof.CheckpointId, StringComparison.Ordinal) ||
            !verified.RelativePath.Equals(proof.RelativePath, StringComparison.Ordinal))
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_IDENTITY_MISMATCH",
                "Recovery checkpoint locator changed after creation.");
        }

        return verified;
    }

    public void VerifySource(
        string sourcePath,
        string expectedSha256,
        long expectedLength)
    {
        var source = Path.GetFullPath(sourcePath);
        RejectFileReparsePoint(source, "RECOVERABLE_CHECKPOINT_SOURCE_UNSAFE");
        var actual = HashFile(source);
        if (actual.Length != expectedLength ||
            !actual.Sha256.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_SOURCE_DRIFT",
                "PLC project bytes changed after checkpoint creation and before Build.");
        }
    }

    internal string CheckpointPath(string sha256)
    {
        var sha = RequireSha256(sha256, nameof(sha256));
        return Path.Combine(root, "sha256", sha[..2].ToLowerInvariant(), $"{sha.ToLowerInvariant()}.project");
    }

    private BrokerProjectCheckpointProof VerifyExisting(
        string path,
        string expectedSha,
        long expectedLength,
        bool createdNow)
    {
        if (!File.Exists(path))
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_READBACK_FAILED",
                "The local PLC recovery checkpoint is missing after creation.");
        }

        RejectFileReparsePoint(path, "RECOVERABLE_CHECKPOINT_CORRUPT");
        var actual = HashFile(path);
        if (actual.Length != expectedLength ||
            !actual.Sha256.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_CORRUPT",
                "An existing local PLC recovery checkpoint does not match its content-addressed identity.");
        }

        var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
        return new BrokerProjectCheckpointProof(
            identityKey,
            $"sha256:{expectedSha.ToLowerInvariant()}",
            relative,
            expectedSha,
            actual.Sha256,
            actual.Length,
            createdNow,
            AtomicWriteVerified: true,
            ReadbackVerified: true);
    }

    private static FileHash CopyAndHash(string sourcePath, string destinationPath)
    {
        using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            BufferSize,
            FileOptions.SequentialScan);
        using var destination = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            BufferSize,
            FileOptions.SequentialScan | FileOptions.WriteThrough);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[BufferSize];
        long length = 0;
        int read;
        while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
        {
            destination.Write(buffer, 0, read);
            hash.AppendData(buffer, 0, read);
            length += read;
        }

        destination.Flush(flushToDisk: true);
        return new FileHash(Convert.ToHexString(hash.GetHashAndReset()), length);
    }

    private static FileHash HashFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            BufferSize,
            FileOptions.SequentialScan);
        return new FileHash(Convert.ToHexString(SHA256.HashData(stream)), stream.Length);
    }

    private static void EnsureSafeDirectory(string path)
    {
        Directory.CreateDirectory(path);
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BrokerInfrastructureException(
                "RECOVERABLE_CHECKPOINT_ROOT_UNSAFE",
                "Recovery checkpoint directory must not be a reparse point.");
        }
    }

    private static void RejectFileReparsePoint(string path, string reasonCode)
    {
        if (!File.Exists(path))
        {
            throw new BrokerInfrastructureException(reasonCode, "Recovery checkpoint source or artifact is missing.");
        }

        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new BrokerInfrastructureException(reasonCode, "Recovery checkpoint source or artifact must not be a reparse point.");
        }
    }

    private static string RequireSha256(string value, string name)
    {
        var normalized = value?.Trim().ToUpperInvariant() ?? string.Empty;
        if (normalized.Length != 64 || normalized.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new ArgumentException("A 64-character SHA-256 value is required.", name);
        }

        return normalized;
    }

    private sealed record FileHash(string Sha256, long Length);
}
