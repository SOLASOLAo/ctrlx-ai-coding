using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace CtrlX.OpCon.Runner.Core;

public sealed class PowerShellEvidenceSealer : IEvidenceSealer
{
    // SHA-256 of the trusted producer after CRLF/CR are normalized to LF.
    // Updating the producer requires an explicit Runner release and constant update.
    public const string TrustedEvidenceProducerNormalizedSha256 =
        "E55359F5B373340C26DD10C8A48C8F2C6BE790933F18FFE20097E8142E3046FD";

    private readonly TimeSpan timeout;

    public PowerShellEvidenceSealer(TimeSpan? timeout = null)
    {
        this.timeout = timeout ?? TimeSpan.FromSeconds(60);
        if (this.timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
    }

    public async Task<EvidenceSealResult> SealAsync(
        ValidatedRunnerAction action,
        string observationPath,
        CancellationToken cancellationToken)
    {
        var scriptPath = RunnerValidation.EnsureInside(
            action.EngineeringRoot,
            Path.Combine(action.EngineeringRoot, "scripts", "cpstudio", "New-PostExportRunnerEvidence.ps1"),
            "Runner evidence producer");
        RunnerValidation.AssertExistingPathChainNotReparse(
            action.EngineeringRoot,
            scriptPath,
            "EVIDENCE_PATH_REPARSE_POINT",
            "Runner evidence producer");
        if (!File.Exists(scriptPath))
        {
            throw new RunnerGateException(
                "EVIDENCE_PRODUCER_NOT_FOUND",
                $"Runner evidence producer does not exist: {scriptPath}");
        }

        if ((File.GetAttributes(scriptPath) & FileAttributes.ReparsePoint) != 0 ||
            !HashNormalizedScript(scriptPath).Equals(
                TrustedEvidenceProducerNormalizedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException(
                "EVIDENCE_PRODUCER_INTEGRITY_MISMATCH",
                "Runner evidence producer is not the trusted, release-bound script.");
        }

        var resolvedObservation = RunnerValidation.EnsureInside(
            Path.Combine(action.EngineeringRoot, "data", "runs", "runner-p12"),
            observationPath,
            "Runner observation");
        RunnerValidation.AssertExistingPathChainNotReparse(
            action.EngineeringRoot,
            resolvedObservation,
            "EVIDENCE_PATH_REPARSE_POINT",
            "Runner observation");
        if (!File.Exists(resolvedObservation))
        {
            throw new RunnerGateException("OBSERVATION_NOT_FOUND", $"Runner observation does not exist: {resolvedObservation}");
        }

        var evidenceRoot = Path.Combine(action.EngineeringRoot, "data", "runner-evidence");
        var outputPath = RunnerValidation.EnsureInside(
            evidenceRoot,
            Path.Combine(evidenceRoot, $"{action.ActionId}-{action.ActionSha256[..12].ToLowerInvariant()}.json"),
            "Runner evidence");
        RunnerValidation.AssertExistingPathChainNotReparse(
            action.EngineeringRoot,
            outputPath,
            "EVIDENCE_PATH_REPARSE_POINT",
            "Runner evidence output");
        var existedBefore = File.Exists(outputPath);

        var powerShell7 = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "PowerShell",
            "7",
            "pwsh.exe");
        if (!File.Exists(powerShell7))
        {
            throw new RunnerGateException("EVIDENCE_SEAL_FAILED", "Trusted PowerShell 7 executable was not found.");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = powerShell7,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = action.EngineeringRoot
        };
        // Use only the controlled PowerShell 7 installation and its built-in modules.
        // Do not inherit a caller-specific module path.
        startInfo.Environment.Remove("PSModulePath");
        foreach (var argument in new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            scriptPath,
            "-ActionPath",
            action.ActionPath,
            "-ExpectedActionSha256",
            action.ActionSha256,
            "-ObservationPath",
            resolvedObservation,
            "-OutputPath",
            outputPath
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new RunnerGateException("EVIDENCE_SEAL_FAILED", "The evidence producer process did not start.");
            }
        }
        catch (Exception exception) when (exception is not RunnerGateException)
        {
            throw new RunnerGateException("EVIDENCE_SEAL_FAILED", $"Could not start the evidence producer: {exception.Message}");
        }

        var standardOutputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var standardErrorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            throw new RunnerGateException("EVIDENCE_SEAL_TIMEOUT", "Runner evidence producer exceeded its offline timeout.");
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        var standardOutput = await standardOutputTask.ConfigureAwait(false);
        var standardError = await standardErrorTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var diagnostic = LimitDiagnostic(string.IsNullOrWhiteSpace(standardError) ? standardOutput : standardError);
            throw new RunnerGateException("EVIDENCE_SEAL_FAILED", $"Runner evidence producer rejected the observation. {diagnostic}");
        }

        if (!File.Exists(outputPath))
        {
            throw new RunnerGateException("EVIDENCE_SEAL_FAILED", "Runner evidence producer returned success without an evidence file.");
        }

        var evidence = RunnerJson.ReadObject(outputPath, "Runner evidence");
        if (RunnerValidation.RequiredString(evidence, "actionId", "Runner evidence") != action.ActionId ||
            !RunnerValidation.RequiredString(evidence, "actionRequestSha256", "Runner evidence")
                .Equals(action.ActionSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new RunnerGateException("EVIDENCE_IDENTITY_MISMATCH", "Sealed evidence does not match the immutable action.");
        }

        return new EvidenceSealResult(
            outputPath,
            RunnerHash.Sha256File(outputPath),
            existedBefore ? "UNCHANGED" : "WRITTEN");
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
        catch (InvalidOperationException)
        {
            // The process exited between the state check and Kill.
        }
    }

    private static string HashNormalizedScript(string path)
    {
        string source;
        try
        {
            source = File.ReadAllText(path, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true));
        }
        catch (DecoderFallbackException exception)
        {
            throw new RunnerGateException(
                "EVIDENCE_PRODUCER_INTEGRITY_MISMATCH",
                $"Runner evidence producer is not strict UTF-8: {exception.Message}");
        }

        var normalized = source.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        return RunnerHash.Sha256Text(normalized);
    }

    private static string LimitDiagnostic(string value)
    {
        const int maximumLength = 2_000;
        var normalized = value.Trim().Replace('\r', ' ').Replace('\n', ' ');
        return normalized.Length <= maximumLength ? normalized : normalized[..maximumLength] + "...";
    }
}
