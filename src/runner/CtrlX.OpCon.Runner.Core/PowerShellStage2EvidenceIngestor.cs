using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public interface IStage2EvidenceIngestor
{
    Task IngestAsync(RunnerInboxEntry entry, CancellationToken cancellationToken);
}

/// <summary>
/// Hands a fully verified Runner result/evidence pair to the existing Stage 2
/// coordinator. This adapter does not implement or bypass the Stage 2 ledger
/// state machine and has no Broker, MCP, PLE, REST, or online PLC capability.
/// </summary>
public sealed class PowerShellStage2EvidenceIngestor : IStage2EvidenceIngestor
{
    // SHA-256 of Invoke-PostExportEngineering.ps1 after CRLF/CR are normalized
    // to LF. Updating the coordinator requires an explicit Runner release.
    public const string TrustedCoordinatorNormalizedSha256 =
        "52BEC49AD01AB9549ADDABFAC920B36ED1F6D86CF79DDED79DB724BF6B491BE0";

    private const int MaximumOperationBytes = 1024 * 1024;
    private const int MaximumEvidenceBytes = 8 * 1024 * 1024;
    private const int MaximumCoordinatorBytes = 2 * 1024 * 1024;
    private const int MaximumDiagnosticCharacters = 8 * 1024;
    private const string LedgerBusyText =
        "Another Stage2 coordinator holds the workflow-local ledger lock";
    private readonly string engineeringRoot;
    private readonly string coordinatorPath;
    private readonly string powerShell7Path;
    private readonly TimeSpan timeout;

    public PowerShellStage2EvidenceIngestor(
        string engineeringRoot,
        TimeSpan? timeout = null)
    {
        this.engineeringRoot = RunnerValidation.FullPath(engineeringRoot);
        this.timeout = timeout ?? TimeSpan.FromSeconds(60);
        if (this.timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        coordinatorPath = RunnerValidation.EnsureInside(
            this.engineeringRoot,
            Path.Combine(
                this.engineeringRoot,
                "scripts",
                "cpstudio",
                "Invoke-PostExportEngineering.ps1"),
            "Stage 2 coordinator");

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles))
        {
            throw new RunnerGateException(
                "STAGE2_POWERSHELL7_NOT_FOUND",
                "The trusted Program Files directory is unavailable.");
        }

        powerShell7Path = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
    }

    public async Task IngestAsync(
        RunnerInboxEntry entry,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (entry.State != RunnerInboxEntryState.ResultReady)
        {
            throw new RunnerGateException(
                "STAGE2_RESULT_NOT_READY",
                "Only a terminal Runner result can be handed to Stage 2.");
        }

        var action = new RunnerActionValidator().Validate(
            engineeringRoot,
            entry.ActionPath,
            entry.ActionSha256);
        AssertActionIdentity(entry, action);

        var store = RunnerRunStore.ForAction(action);
        if (!store.TryReadResult(out var verifiedResult) || verifiedResult is null)
        {
            throw new RunnerGateException(
                "STAGE2_RESULT_NOT_FOUND",
                "The terminal Runner result disappeared before Stage 2 ingestion.");
        }
        AssertResultIdentity(entry, store, verifiedResult);

        if (string.IsNullOrWhiteSpace(verifiedResult.EvidencePath))
        {
            throw new RunnerGateException(
                "STAGE2_MANUAL_REVIEW_REQUIRED",
                "The fully validated terminal Runner result has no sealed evidence and requires manual review.");
        }
        var expectedEvidenceSha256 = verifiedResult.EvidenceSha256;
        if (string.IsNullOrWhiteSpace(expectedEvidenceSha256) ||
            !RunnerValidation.IsSha256(expectedEvidenceSha256))
        {
            throw new RunnerGateException(
                "STAGE2_TERMINAL_EVIDENCE_HASH_MISSING",
                "The terminal Runner result has no valid sealed evidence hash.");
        }

        var evidenceRoot = Path.Combine(engineeringRoot, "data", "runner-evidence");
        var evidencePath = RunnerValidation.EnsureInside(
            evidenceRoot,
            verifiedResult.EvidencePath,
            "Runner evidence");
        RunnerValidation.AssertExistingPathChainNotReparse(
            engineeringRoot,
            evidencePath,
            "STAGE2_EVIDENCE_REPARSE_POINT",
            "Runner evidence");
        if (!File.Exists(evidencePath))
        {
            throw new RunnerGateException(
                "STAGE2_TERMINAL_EVIDENCE_MISSING",
                "The sealed Runner evidence disappeared before Stage 2 ingestion.");
        }
        using var evidenceLease = OpenVerifiedEvidence(
            evidencePath,
            expectedEvidenceSha256);
        using var coordinatorLease = OpenTrustedCoordinator();

        AssertTrustedPowerShell();
        var startInfo = CreateStartInfo(entry.OperationId, evidencePath);
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new RunnerGateException(
                    "STAGE2_COORDINATOR_FAILED",
                    "The Stage 2 coordinator process did not start.");
            }
        }
        catch (Exception exception) when (exception is not RunnerGateException)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_FAILED",
                $"Could not start the Stage 2 coordinator: {exception.Message}");
        }

        var standardOutputTask = DrainBoundedAsync(process.StandardOutput);
        var standardErrorTask = DrainBoundedAsync(process.StandardError);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            await DrainAfterTerminationAsync(standardOutputTask, standardErrorTask).ConfigureAwait(false);
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_TIMEOUT",
                "The offline Stage 2 coordinator exceeded its time limit.");
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            await DrainAfterTerminationAsync(standardOutputTask, standardErrorTask).ConfigureAwait(false);
            throw;
        }

        var standardOutput = await standardOutputTask.ConfigureAwait(false);
        var standardError = await standardErrorTask.ConfigureAwait(false);
        AssertTrustedPowerShell();
        if (process.ExitCode != 0)
        {
            if (standardError.Contains(LedgerBusyText, StringComparison.Ordinal) ||
                standardOutput.Contains(LedgerBusyText, StringComparison.Ordinal))
            {
                throw new RunnerGateException(
                    "STAGE2_COORDINATOR_BUSY",
                    "Another Stage 2 coordinator currently owns the ledger lock.",
                    RunnerExitCodes.Busy);
            }

            throw new RunnerGateException(
                "STAGE2_COORDINATOR_FAILED",
                $"The Stage 2 coordinator rejected the verified evidence (exit {process.ExitCode}).");
        }

        AssertLedgerAdvanced(entry, expectedEvidenceSha256);
    }

    private ProcessStartInfo CreateStartInfo(string operationId, string evidencePath)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = powerShell7Path,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = engineeringRoot
        };
        startInfo.Environment.Remove("PSModulePath");
        foreach (var argument in new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            coordinatorPath,
            "-EngineeringRoot",
            engineeringRoot,
            "-OperationId",
            operationId,
            "-EvidencePath",
            evidencePath,
            "-LockWaitMilliseconds",
            "5000"
        })
        {
            startInfo.ArgumentList.Add(argument);
        }
        return startInfo;
    }

    private FileStream OpenTrustedCoordinator()
    {
        RunnerValidation.AssertExistingPathChainNotReparse(
            engineeringRoot,
            coordinatorPath,
            "STAGE2_COORDINATOR_REPARSE_POINT",
            "Stage 2 coordinator");
        if (!File.Exists(coordinatorPath) ||
            (File.GetAttributes(coordinatorPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_INTEGRITY_MISMATCH",
                "The Stage 2 coordinator is not the trusted, release-bound script.");
        }

        FileStream stream;
        try
        {
            stream = new FileStream(
                coordinatorPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 64 * 1024,
                FileOptions.SequentialScan);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_INTEGRITY_MISMATCH",
                $"The Stage 2 coordinator could not be locked for execution: {exception.Message}");
        }

        try
        {
            if (stream.Length <= 0 || stream.Length > MaximumCoordinatorBytes)
            {
                throw new RunnerGateException(
                    "STAGE2_COORDINATOR_INTEGRITY_MISMATCH",
                    "The Stage 2 coordinator is empty or exceeds its release limit.");
            }
            if (!HashNormalizedScript(stream).Equals(
                    TrustedCoordinatorNormalizedSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new RunnerGateException(
                    "STAGE2_COORDINATOR_INTEGRITY_MISMATCH",
                    "The Stage 2 coordinator is not the trusted, release-bound script.");
            }
            stream.Position = 0;
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    private void AssertTrustedPowerShell()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        RunnerValidation.AssertExistingPathChainNotReparse(
            programFiles,
            powerShell7Path,
            "STAGE2_POWERSHELL7_REPARSE_POINT",
            "PowerShell 7 executable");
        if (!File.Exists(powerShell7Path) ||
            (File.GetAttributes(powerShell7Path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new RunnerGateException(
                "STAGE2_POWERSHELL7_NOT_FOUND",
                "The trusted PowerShell 7 executable was not found.");
        }
    }

    private void AssertLedgerAdvanced(RunnerInboxEntry entry, string evidenceSha256)
    {
        var operationRoot = Path.Combine(
            engineeringRoot,
            "data",
            "operations",
            "cpstudio-stage2",
            entry.OperationId);
        var operationPath = RunnerValidation.EnsureInside(
            operationRoot,
            Path.Combine(operationRoot, "operation.json"),
            "Stage 2 operation ledger");
        RunnerValidation.AssertExistingPathChainNotReparse(
            engineeringRoot,
            operationPath,
            "STAGE2_OPERATION_REPARSE_POINT",
            "Stage 2 operation ledger");
        var info = new FileInfo(operationPath);
        if (!info.Exists || info.Length <= 0 || info.Length > MaximumOperationBytes)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_NO_PROGRESS",
                "Stage 2 returned success without a readable bounded operation ledger.");
        }

        var operation = RunnerJson.ReadObject(operationPath, "Stage 2 operation ledger");
        if (RunnerValidation.RequiredInt32(operation, "schemaVersion", "Stage 2 operation ledger") != 1 ||
            RunnerValidation.RequiredString(operation, "kind", "Stage 2 operation ledger") !=
                "ctrlx-opcon-post-export-operation" ||
            RunnerValidation.RequiredString(operation, "operationId", "Stage 2 operation ledger") !=
                entry.OperationId)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_NO_PROGRESS",
                "Stage 2 returned success without preserving the operation identity.");
        }

        if (operation["currentAction"] is JsonObject currentAction &&
            RunnerValidation.RequiredString(currentAction, "actionId", "Stage 2 current action") == entry.ActionId)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_NO_PROGRESS",
                "Stage 2 returned success but left the completed action current.");
        }

        var accepted = operation["evidence"] is JsonArray evidence && evidence
            .OfType<JsonObject>()
            .Any(item =>
                item["actionId"]?.GetValue<string>() == entry.ActionId &&
                item["sourceSha256"]?.GetValue<string>()?.Equals(
                    evidenceSha256,
                    StringComparison.OrdinalIgnoreCase) == true);
        if (!accepted)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_NO_PROGRESS",
                "Stage 2 returned success without binding the completed action evidence.");
        }
    }

    private static void AssertActionIdentity(
        RunnerInboxEntry entry,
        ValidatedRunnerAction action)
    {
        if (action.OperationId != entry.OperationId ||
            action.ActionId != entry.ActionId ||
            action.ActionKind != entry.ActionKind ||
            !action.ActionSha256.Equals(entry.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException(
                "STAGE2_ACTION_IDENTITY_MISMATCH",
                "The current inbox entry does not match the fully validated action.");
        }
    }

    private static void AssertResultIdentity(
        RunnerInboxEntry entry,
        RunnerRunStore store,
        RunnerExecutionResult result)
    {
        if (store.RunId != entry.RunId ||
            !store.ResultPath.Equals(entry.ResultPath, StringComparison.OrdinalIgnoreCase) ||
            result.RunId != entry.RunId ||
            !result.ResultPath.Equals(entry.ResultPath, StringComparison.OrdinalIgnoreCase) ||
            result.State != entry.ResultState ||
            !SameOptionalPath(result.EvidencePath, entry.EvidencePath))
        {
            throw new RunnerGateException(
                "STAGE2_RESULT_IDENTITY_MISMATCH",
                "The terminal result changed after inbox discovery.");
        }
    }

    private static bool SameOptionalPath(string? first, string? second) =>
        first is null && second is null ||
        first is not null && second is not null &&
        Path.GetFullPath(first).Equals(Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase);

    private static FileStream OpenVerifiedEvidence(string path, string expectedSha256)
    {
        FileStream stream;
        try
        {
            // Stage 2 may open the evidence for reading, but no writer or
            // replacement is allowed until the coordinator has committed the
            // exact result-bound hash to its ledger.
            stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 64 * 1024,
                FileOptions.SequentialScan);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new RunnerGateException(
                "STAGE2_TERMINAL_EVIDENCE_UNAVAILABLE",
                $"The sealed Runner evidence could not be locked for ingestion: {exception.Message}");
        }

        try
        {
            if (stream.Length <= 0 || stream.Length > MaximumEvidenceBytes)
            {
                throw new RunnerGateException(
                    "STAGE2_TERMINAL_EVIDENCE_SIZE_INVALID",
                    "The sealed Runner evidence is empty or exceeds its ingestion limit.");
            }
            var actualSha256 = Convert.ToHexString(SHA256.HashData(stream));
            if (!actualSha256.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new RunnerGateException(
                    "STAGE2_TERMINAL_EVIDENCE_CHANGED",
                    "The sealed Runner evidence no longer matches its terminal result hash.");
            }
            stream.Position = 0;
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    private static async Task<string> DrainBoundedAsync(StreamReader reader)
    {
        var captured = new StringBuilder(MaximumDiagnosticCharacters);
        var buffer = new char[1024];
        while (true)
        {
            var read = await reader.ReadAsync(buffer).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            var remaining = MaximumDiagnosticCharacters - captured.Length;
            if (remaining > 0)
            {
                captured.Append(buffer, 0, Math.Min(read, remaining));
            }
        }
        return captured.ToString();
    }

    private static async Task DrainAfterTerminationAsync(params Task<string>[] tasks)
    {
        try
        {
            await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch
        {
            // The coordinator was already terminated. Its bounded diagnostic
            // pipes are best-effort cleanup and are never workflow evidence.
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception exception) when (exception is
            InvalidOperationException or
            System.ComponentModel.Win32Exception or
            NotSupportedException)
        {
            // Timeout/cancellation must keep its stable reason even when the
            // OS reports that the process already exited or cannot be killed.
        }
    }

    private static string HashNormalizedScript(Stream stream)
    {
        string source;
        try
        {
            stream.Position = 0;
            using var reader = new StreamReader(
                stream,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true),
                detectEncodingFromByteOrderMarks: false,
                bufferSize: 64 * 1024,
                leaveOpen: true);
            source = reader.ReadToEnd();
        }
        catch (DecoderFallbackException exception)
        {
            throw new RunnerGateException(
                "STAGE2_COORDINATOR_INTEGRITY_MISMATCH",
                $"The Stage 2 coordinator is not strict UTF-8: {exception.Message}");
        }

        var normalized = source.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        return RunnerHash.Sha256Text(normalized);
    }
}
