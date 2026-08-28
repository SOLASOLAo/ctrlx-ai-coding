using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CtrlX.OpCon.Runner.Core;

namespace CtrlX.OpCon.Runner.Broker.Session;

internal sealed record BrokerProjectProofState(
    string ProjectSha256,
    long Length,
    DateTime LastWriteTimeUtc,
    string StructureSha256);

internal sealed record BrokerCompileProofState(
    string BuildId,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int Errors,
    int Warnings,
    int MessageCount,
    bool TypedRecordsVerified,
    bool DiagnosticRowsComplete,
    IReadOnlyList<BrokerCompileProofRecord> Records,
    IReadOnlyList<string> DiagnosticRows);

internal sealed record BrokerCompileProofRecord(string Severity, string Text);

internal sealed record BrokerSemanticProduction(
    bool Verified,
    string ReasonCode,
    JsonObject Proofs,
    JsonArray WarningRecords,
    bool WarningRecordsSafeForReview,
    JsonArray DiagnosticRows,
    JsonArray WarningSignatures,
    IReadOnlyList<string> Diagnostics,
    JsonObject? NextRoute);

internal sealed record BrokerSemanticSnapshotPlan(
    bool CanInvoke,
    string ReasonCode,
    JsonObject? Arguments,
    JsonObject BaselineProof,
    BrokerSemanticSnapshotScope? Scope,
    BrokerReviewedSemanticBaseline? Baseline);

internal sealed record BrokerSemanticSnapshotScope(
    string ArtifactPath,
    string ArtifactSha256,
    JsonArray MappingScopes,
    JsonArray MappingTargets,
    string SymbolApplicationPath);

internal sealed record BrokerReviewedSemanticBaseline(
    string ArtifactPath,
    string ArtifactSha256,
    string ScopeSha256,
    int ExpectedMappingCount,
    JsonObject ExpectedCanonicalFacts,
    string ExpectedMappingSha256,
    string SymbolApplicationPath,
    string ExpectedSymbolConfigSha256,
    string ExpectedSnapshotSha256,
    JsonObject ReviewProof);

internal sealed record BrokerReviewedJsonArtifact(
    JsonObject Document,
    string Sha256,
    int ByteCount);

/// <summary>
/// Produces independent, auditable proofs for a successful read-only Runner
/// action. No station BMK, object name or process rule is embedded here.
/// Mapping and Symbol state are accepted only from the explicit adapter
/// contract; neither a zero-error Build nor a stable project hash is used as a
/// substitute for those proofs.
/// </summary>
internal static class BrokerSemanticAcceptance
{
    private const string SemanticProducer = "codesys-persistent.get_ctrlx_semantic_snapshot";
    private const string SemanticPatchId = "ctrlx-semantic-snapshot-v1";
    private const string WarningBaselineRelativePath = "config/warning-signature-baseline.json";
    private const string SemanticBaselineRelativePath = "config/engineering-semantic-baseline.json";
    private const string WarningSignatureAlgorithm = "sha256:v1:normalized-warning-record";
    private const string PleWarningTruncationSignatureSha256 = "B801B38B18AAA422A0A34B3BDB867CD5F038C46AD5135A73E432AF0C58C86D9B";
    private const int MaximumSemanticSnapshotBytes = 480 * 1024;
    private const int MaximumSemanticScopeArtifactBytes = 256 * 1024;
    private const int MaximumReviewedBaselineArtifactBytes = 2 * 1024 * 1024;
    private const int MaximumWarningRecordCount = 2048;
    private const int MaximumObservationWarningRecordBytes = 4096;
    private const int MaximumObservationWarningRecordsBytes = 256 * 1024;
    private const string SensitiveDiagnosticPlaceholder = "[REDACTED_SENSITIVE_DIAGNOSTIC]";

    private static readonly Regex Whitespace = new(
        "\\s+",
        RegexOptions.CultureInvariant);

    private static readonly Regex PleWarningOutputTruncationSentinel = new(
        "\\AMore than [0-9]+ warnings occurr?ed: Skipping all further warning messages\\z",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex SensitiveWarningText = new(
        "(?:\\b(?:password|passwd|pwd|secret|token|access[_-]?token|refresh[_-]?token|api[_-]?key|private[_-]?key|credential|authorization)\\b\\s*[:=]\\s*[^\\s,;]+)|" +
        "(?:\\b(?:Bearer|Basic)\\s+[A-Za-z0-9+/_=.-]+)|" +
        "(?:\\b(?:https?|ftp)://[^\\s/@:]+:[^\\s/@]+@)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex JsonSurrogateEscape = new(
        "(?<!\\\\)\\\\u(?<high>D[89ABab][0-9A-Fa-f]{2})\\\\u(?<low>D[C-Fc-f][0-9A-Fa-f]{2})",
        RegexOptions.CultureInvariant);

    private static readonly Regex JsonBmpEscape = new(
        "(?<!\\\\)\\\\u(?<code>[0-9A-Fa-f]{4})",
        RegexOptions.CultureInvariant);

    private static readonly JsonSerializerOptions CanonicalJsonOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false
    };

    public static BrokerSemanticSnapshotPlan PrepareSnapshotPlan(ValidatedRunnerAction action)
    {
        ArgumentNullException.ThrowIfNull(action);
        try
        {
            var scope = ReadSemanticSnapshotScope(action);
            BrokerReviewedSemanticBaseline? baseline = null;
            string baselineReason;
            JsonObject baselineProof;
            try
            {
                baseline = ReadReviewedSemanticBaseline(action, scope);
                baselineReason = "READY";
                baselineProof = new JsonObject
                {
                    ["producer"] = "runner.reviewed-semantic-baseline",
                    ["contractVersion"] = 1,
                    ["verified"] = true,
                    ["artifactPath"] = baseline.ArtifactPath,
                    ["artifactSha256"] = baseline.ArtifactSha256,
                    ["scopeSha256"] = baseline.ScopeSha256,
                    ["expectedMappingCount"] = baseline.ExpectedMappingCount,
                    ["expectedMappingSha256"] = baseline.ExpectedMappingSha256,
                    ["symbolApplicationPath"] = baseline.SymbolApplicationPath,
                    ["expectedSymbolConfigSha256"] = baseline.ExpectedSymbolConfigSha256,
                    ["expectedSnapshotSha256"] = baseline.ExpectedSnapshotSha256,
                    ["review"] = baseline.ReviewProof.DeepClone()
                };
            }
            catch (SemanticProofException exception)
            {
                baselineReason = exception.ReasonCode;
                baselineProof = UnverifiedProof("runner.reviewed-semantic-baseline", exception.ReasonCode);
            }

            return new BrokerSemanticSnapshotPlan(
                CanInvoke: true,
                ReasonCode: baselineReason,
                Arguments: new JsonObject
                {
                    ["projectFilePath"] = action.PlcProject,
                    ["mappingScopes"] = scope.MappingScopes.DeepClone(),
                    ["mappingTargets"] = scope.MappingTargets.DeepClone(),
                    ["symbolApplicationPath"] = scope.SymbolApplicationPath
                },
                BaselineProof: baselineProof,
                Scope: scope,
                Baseline: baseline);
        }
        catch (SemanticProofException exception)
        {
            return new BrokerSemanticSnapshotPlan(
                CanInvoke: false,
                ReasonCode: exception.ReasonCode,
                Arguments: null,
                BaselineProof: UnverifiedProof("runner.reviewed-semantic-baseline", exception.ReasonCode),
                Scope: null,
                Baseline: null);
        }
    }

    public static async Task<BrokerSemanticProduction> ProduceAsync(
        ValidatedRunnerAction action,
        BrokerProjectProofState before,
        BrokerProjectProofState after,
        BrokerCompileProofState build,
        BrokerSemanticSnapshotPlan snapshotPlan,
        string? semanticSnapshotText,
        bool semanticSnapshotIsError,
        DateTimeOffset receivedAtUtc,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        var diagnostics = new List<string>();
        var proofs = new JsonObject { ["contractVersion"] = 1 };

        var diagnosticRows = ObservationDiagnosticRows(build.DiagnosticRows);
        var rawWarningRecords = build.TypedRecordsVerified ? WarningRecords(build) : new JsonArray();
        var safeWarningRecords = build.TypedRecordsVerified
            ? ObservationWarningRecords(rawWarningRecords)
            : null;
        var warningRecordsSafeForReview = safeWarningRecords is not null;
        var warningRecords = safeWarningRecords ?? new JsonArray();
        var currentWarningSignatures = warningRecordsSafeForReview
            ? WarningSignatures(rawWarningRecords, build.Warnings)
            : new JsonArray();
        var currentWarningMultisetSha = RunnerHash.Sha256Text(CanonicalJson(currentWarningSignatures));
        var warningOutputTruncated = warningRecordsSafeForReview &&
            ContainsPleWarningOutputTruncationSentinel(rawWarningRecords);

        var ownership = ProduceOwnership(action, diagnostics);
        proofs["ownership"] = ownership;

        var readback = ProduceReadback(before, after, diagnostics);
        proofs["readback"] = readback;

        var recoverable = await ProduceRecoverableBaselineAsync(action, after, diagnostics, cancellationToken)
            .ConfigureAwait(false);
        proofs["recoverableBaseline"] = recoverable;

        JsonObject warnings;
        if (!build.TypedRecordsVerified)
        {
            var reason = build.DiagnosticRowsComplete
                ? "WARNING_RECORDS_UNTYPED"
                : "WARNING_RECORDS_INCOMPLETE";
            diagnostics.Add($"warnings:{reason}");
            warnings = UnverifiedProof("codesys-persistent.clean_compile_project", reason);
            warnings["typedRecordsVerified"] = false;
            warnings["diagnosticRowsComplete"] = build.DiagnosticRowsComplete;
            warnings["diagnosticRowCount"] = diagnosticRows.Count;
            warnings["currentSignatures"] = currentWarningSignatures.DeepClone();
            warnings["multisetSha256"] = currentWarningMultisetSha;
        }
        else if (!warningRecordsSafeForReview)
        {
            const string reason = "WARNING_RECORDS_UNSAFE_FOR_REVIEW";
            diagnostics.Add($"warnings:{reason}");
            warnings = UnverifiedProof("runner.warning-review-safety", reason);
            warnings["typedRecordsVerified"] = true;
            warnings["warningRecordsSafeForReview"] = false;
            warnings["currentSignatures"] = currentWarningSignatures.DeepClone();
            warnings["multisetSha256"] = currentWarningMultisetSha;
        }
        else
        {
            warnings = ProduceWarningReview(
                action,
                currentWarningSignatures,
                currentWarningMultisetSha,
                warningOutputTruncated,
                diagnostics);
        }
        proofs["warnings"] = warnings;

        proofs["semanticBaseline"] = snapshotPlan.BaselineProof.DeepClone();

        JsonObject mapping;
        JsonObject symbol;
        JsonObject? nextRoute = null;
        if (!snapshotPlan.CanInvoke)
        {
            diagnostics.Add($"semantic-baseline:{snapshotPlan.ReasonCode}");
            mapping = UnverifiedProof("runner.semantic-baseline-comparison", snapshotPlan.ReasonCode);
            symbol = UnverifiedProof("runner.semantic-baseline-comparison", snapshotPlan.ReasonCode);
            nextRoute = new JsonObject
            {
                ["kind"] = "review-engineering-semantic-baseline",
                ["reasonCode"] = snapshotPlan.ReasonCode,
                ["automaticExecutionAllowed"] = false
            };
        }
        else if (string.IsNullOrWhiteSpace(semanticSnapshotText))
        {
            const string reason = "SEMANTIC_ADAPTER_EVIDENCE_MISSING";
            diagnostics.Add($"adapter:{reason}");
            mapping = UnverifiedProof(SemanticProducer, reason);
            symbol = UnverifiedProof(SemanticProducer, reason);
        }
        else if (semanticSnapshotIsError)
        {
            try
            {
                var failure = ParseAdapterFailure(semanticSnapshotText, action.PlcProject);
                const string reason = "SEMANTIC_ADAPTER_RETURNED_ERROR";
                diagnostics.Add($"adapter:{reason}:{failure.ReasonCode}:{failure.SafeReason}");
                mapping = UnverifiedProof(SemanticProducer, reason);
                mapping["adapterReasonCode"] = failure.ReasonCode;
                mapping["adapterReasonSha256"] = failure.ReasonSha256;
                symbol = (JsonObject)mapping.DeepClone();
            }
            catch (SemanticProofException)
            {
                const string reason = "SEMANTIC_ADAPTER_ERROR_RESPONSE_INVALID";
                diagnostics.Add($"adapter:{reason}");
                mapping = UnverifiedProof(SemanticProducer, reason);
                symbol = UnverifiedProof(SemanticProducer, reason);
            }
        }
        else
        {
            try
            {
                var adapter = ParseAdapterEvidence(
                    semanticSnapshotText,
                    action.PlcProject,
                    snapshotPlan.Scope!.SymbolApplicationPath,
                    build.CompletedAtUtc,
                    receivedAtUtc);
                if (snapshotPlan.Baseline is null)
                {
                    mapping = ProduceMappingCandidate(adapter);
                    symbol = ProduceSymbolCandidate(adapter);
                    diagnostics.Add($"semantic-baseline:{snapshotPlan.ReasonCode}");
                    nextRoute = new JsonObject
                    {
                        ["kind"] = "review-engineering-semantic-baseline",
                        ["reasonCode"] = snapshotPlan.ReasonCode,
                        ["automaticExecutionAllowed"] = false
                    };
                }
                else
                {
                    mapping = ProduceMapping(snapshotPlan.Baseline, adapter, diagnostics);
                    (symbol, nextRoute) = ProduceSymbol(
                        action.ActionKind,
                        snapshotPlan.Baseline,
                        adapter,
                        diagnostics);
                }
            }
            catch (SemanticProofException exception)
            {
                diagnostics.Add($"adapter:{exception.ReasonCode}");
                mapping = UnverifiedProof(SemanticProducer, exception.ReasonCode);
                symbol = UnverifiedProof(SemanticProducer, exception.ReasonCode);
            }
        }

        proofs["mapping"] = mapping;
        proofs["symbolPostProcessing"] = symbol;

        if (nextRoute is null && !RequiredProofVerified(mapping))
        {
            nextRoute = new JsonObject
            {
                ["kind"] = "review-engineering-semantic-baseline",
                ["reasonCode"] = OptionalString(mapping, "reasonCode") is { Length: > 0 } mappingReason
                    ? mappingReason
                    : "MAPPING_PROOF_INCOMPLETE",
                ["automaticExecutionAllowed"] = false
            };
        }

        if (nextRoute is null && !RequiredProofVerified(warnings))
        {
            nextRoute = new JsonObject
            {
                ["kind"] = "review-warning-signature-baseline",
                ["reasonCode"] = OptionalString(warnings, "reasonCode") is { Length: > 0 } warningReason
                    ? warningReason
                    : "WARNING_PROOF_INCOMPLETE",
                ["automaticExecutionAllowed"] = false
            };
        }

        var verified = RequiredProofVerified(ownership) &&
            RequiredProofVerified(readback) &&
            RequiredProofVerified(recoverable) &&
            RequiredProofVerified(warnings) &&
            RequiredProofVerified(snapshotPlan.BaselineProof) &&
            RequiredProofVerified(mapping) &&
            RequiredProofVerified(symbol);
        return new BrokerSemanticProduction(
            verified,
            verified ? "SEMANTIC_ACCEPTANCE_VERIFIED" : BlockingReason(proofs, nextRoute),
            proofs,
            warningRecords,
            warningRecordsSafeForReview,
            diagnosticRows,
            currentWarningSignatures,
            diagnostics,
            nextRoute);
    }

    private static JsonObject ProduceOwnership(
        ValidatedRunnerAction action,
        ICollection<string> diagnostics)
    {
        try
        {
            var preconditions = RequiredObject(action.Document, "preconditions", "action");
            var manifests = RequiredArray(preconditions, "manifests", "action.preconditions");
            var matches = manifests
                .OfType<JsonObject>()
                .Where(item => NormalizedRelativePath(OptionalString(item, "path")) == "ai/ownership.yaml")
                .ToArray();
            if (matches.Length != 1)
            {
                throw new SemanticProofException(
                    "OWNERSHIP_MANIFEST_NOT_BOUND",
                    "The immutable action must bind ai/ownership.yaml exactly once.");
            }

            var record = matches[0];
            if (!RequiredBoolean(record, "exists", "ownership manifest"))
            {
                throw new SemanticProofException(
                    "OWNERSHIP_MANIFEST_MISSING",
                    "The bound ownership manifest is not present.");
            }

            var path = EnsureInside(
                action.EngineeringRoot,
                Path.Combine(action.EngineeringRoot, "ai", "ownership.yaml"),
                "ownership manifest");
            var expectedSha = RequiredSha(record, "sha256", "ownership manifest");
            var actualSha = RequireCurrentFileSha(path, expectedSha, "OWNERSHIP_MANIFEST_DRIFT");
            return new JsonObject
            {
                ["producer"] = "runner.action-manifest",
                ["contractVersion"] = 1,
                ["verified"] = true,
                ["manifestPath"] = "ai/ownership.yaml",
                ["manifestSha256"] = actualSha,
                ["sizeBytes"] = new FileInfo(path).Length
            };
        }
        catch (SemanticProofException exception)
        {
            diagnostics.Add($"ownership:{exception.ReasonCode}");
            return UnverifiedProof("runner.action-manifest", exception.ReasonCode);
        }
    }

    private static JsonObject ProduceReadback(
        BrokerProjectProofState before,
        BrokerProjectProofState after,
        ICollection<string> diagnostics)
    {
        var verified = before.ProjectSha256.Equals(after.ProjectSha256, StringComparison.OrdinalIgnoreCase) &&
            before.Length == after.Length &&
            before.StructureSha256.Equals(after.StructureSha256, StringComparison.OrdinalIgnoreCase);
        if (!verified)
        {
            diagnostics.Add("readback:PROJECT_READBACK_DRIFT");
        }

        return new JsonObject
        {
            ["producer"] = "runner.project-file-and-structure-readback",
            ["contractVersion"] = 1,
            ["verified"] = verified,
            ["projectSha256Before"] = before.ProjectSha256,
            ["projectSha256After"] = after.ProjectSha256,
            ["projectLengthBefore"] = before.Length,
            ["projectLengthAfter"] = after.Length,
            ["structureSha256Before"] = before.StructureSha256,
            ["structureSha256After"] = after.StructureSha256
        };
    }

    private static async Task<JsonObject> ProduceRecoverableBaselineAsync(
        ValidatedRunnerAction action,
        BrokerProjectProofState project,
        ICollection<string> diagnostics,
        CancellationToken cancellationToken)
    {
        try
        {
            var repositoryRoot = Path.GetFullPath((await RunGitAsync(
                    action.StationRoot,
                    cancellationToken,
                    "rev-parse",
                    "--show-toplevel")
                .ConfigureAwait(false)).Trim());
            _ = EnsureInside(repositoryRoot, action.PlcProject, "PLC project Git path");
            var relativeProject = Path.GetRelativePath(repositoryRoot, action.PlcProject).Replace('\\', '/');
            if (relativeProject.StartsWith("../", StringComparison.Ordinal) || relativeProject == "..")
            {
                throw new SemanticProofException(
                    "RECOVERABLE_BASELINE_PROJECT_OUTSIDE_REPOSITORY",
                    "PLC project is outside the Station Git repository.");
            }

            var headCommit = (await RunGitAsync(
                    repositoryRoot,
                    cancellationToken,
                    "rev-parse",
                    "HEAD")
                .ConfigureAwait(false)).Trim();
            var headBlob = (await RunGitAsync(
                    repositoryRoot,
                    cancellationToken,
                    "rev-parse",
                    $"HEAD:{relativeProject}")
                .ConfigureAwait(false)).Trim();
            var workingBlob = (await RunGitAsync(
                    repositoryRoot,
                    cancellationToken,
                    "hash-object",
                    "--",
                    action.PlcProject)
                .ConfigureAwait(false)).Trim();
            if (!IsGitObjectId(headCommit) || !IsGitObjectId(headBlob) || !IsGitObjectId(workingBlob) ||
                !headBlob.Equals(workingBlob, StringComparison.OrdinalIgnoreCase))
            {
                throw new SemanticProofException(
                    "RECOVERABLE_BASELINE_NOT_AT_HEAD",
                    "Current PLC project bytes are not the exact blob stored at Git HEAD.");
            }

            return new JsonObject
            {
                ["producer"] = "runner.git-head-baseline",
                ["contractVersion"] = 1,
                ["verified"] = true,
                ["repositoryRoot"] = repositoryRoot,
                ["headCommit"] = headCommit,
                ["projectRelativePath"] = relativeProject,
                ["headBlobObjectId"] = headBlob,
                ["workingBlobObjectId"] = workingBlob,
                ["projectSha256"] = project.ProjectSha256
            };
        }
        catch (Exception exception) when (exception is SemanticProofException or IOException or UnauthorizedAccessException)
        {
            var reason = exception is SemanticProofException semantic
                ? semantic.ReasonCode
                : "RECOVERABLE_BASELINE_GIT_UNAVAILABLE";
            diagnostics.Add($"recoverable-baseline:{reason}");
            return UnverifiedProof("runner.git-head-baseline", reason);
        }
    }

    private static JsonObject ProduceWarningReview(
        ValidatedRunnerAction action,
        JsonArray currentSignatures,
        string currentMultisetSha,
        bool warningOutputTruncated,
        ICollection<string> diagnostics)
    {
        var currentProof = new JsonObject
        {
            ["producer"] = "runner.warning-baseline-comparison",
            ["contractVersion"] = 1,
            ["verified"] = false,
            ["signatureAlgorithm"] = WarningSignatureAlgorithm,
            ["currentMultisetSha256"] = currentMultisetSha,
            ["currentSignatures"] = currentSignatures.DeepClone()
        };

        try
        {
            var preconditions = RequiredObject(action.Document, "preconditions", "action");
            if (preconditions["warningBaseline"] is not JsonObject reference)
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_BOOTSTRAP_REQUIRED",
                    "No reviewed warning baseline is bound; current signatures are bootstrap evidence only.");
            }

            if (RequiredString(reference, "state", "warning baseline reference") != "reviewed")
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_BOOTSTRAP_REQUIRED",
                    "Warning baseline is not in reviewed state.");
            }

            if (warningOutputTruncated)
            {
                throw new SemanticProofException(
                    "PLE_WARNING_OUTPUT_TRUNCATED",
                    "PLE reported that further warnings were skipped; this warning population is not a complete baseline comparison.");
            }

            var relativePath = NormalizedRelativePath(RequiredString(reference, "path", "warning baseline reference"));
            if (relativePath != WarningBaselineRelativePath)
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_REFERENCE_INVALID",
                    "Warning baseline path is not the controlled project artifact.");
            }

            var baselinePath = EnsureInside(
                action.EngineeringRoot,
                Path.Combine(action.EngineeringRoot, relativePath),
                "warning baseline");
            var expectedBaselineSha = RequiredSha(reference, "sha256", "warning baseline reference");
            var baselineArtifact = ReadReviewedJsonArtifact(
                baselinePath,
                expectedBaselineSha,
                "WARNING_BASELINE_DRIFT",
                "WARNING_BASELINE_INVALID",
                "WARNING_BASELINE_TOO_LARGE",
                MaximumReviewedBaselineArtifactBytes);
            var baselineSha = baselineArtifact.Sha256;
            var actionReviewEvidence = RequiredObject(
                reference,
                "reviewEvidence",
                "warning baseline reference");
            RequireOnly(actionReviewEvidence, "warning baseline reference reviewEvidence", "path", "sha256");

            var baseline = baselineArtifact.Document;
            RequireOnly(
                baseline,
                "warning baseline",
                "schemaVersion",
                "kind",
                "project",
                "signatureAlgorithm",
                "signatures",
                "review");
            if (RequiredInt32(baseline, "schemaVersion", "warning baseline") != 1 ||
                RequiredString(baseline, "kind", "warning baseline") != "ctrlx-opcon-warning-signature-baseline" ||
                RequiredString(baseline, "signatureAlgorithm", "warning baseline") != WarningSignatureAlgorithm)
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_INVALID",
                    "Warning baseline contract is unsupported.");
            }

            ValidateWarningBaselineProject(action, RequiredObject(baseline, "project", "warning baseline"));
            var baselineSignatures = ValidateSignatureMultiset(
                RequiredArray(baseline, "signatures", "warning baseline"),
                "WARNING_BASELINE_INVALID");
            if (!JsonNode.DeepEquals(baselineSignatures, currentSignatures))
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_MISMATCH",
                    "Fresh Build warning multiset does not equal the reviewed baseline.");
            }

            var review = ValidateWarningReview(
                action,
                RequiredObject(baseline, "review", "warning baseline"));
            if (RequiredString(actionReviewEvidence, "path", "warning baseline reference reviewEvidence") !=
                    RequiredString(review, "evidencePath", "warning review proof") ||
                !RequiredSha(actionReviewEvidence, "sha256", "warning baseline reference reviewEvidence")
                    .Equals(RequiredSha(review, "evidenceSha256", "warning review proof"), StringComparison.OrdinalIgnoreCase))
            {
                throw new SemanticProofException(
                    "WARNING_BASELINE_REVIEW_REFERENCE_MISMATCH",
                    "Action-bound warning review evidence differs from baseline provenance.");
            }
            currentProof["verified"] = true;
            currentProof["baselinePath"] = relativePath;
            currentProof["baselineSha256"] = baselineSha;
            currentProof["review"] = review;
            return currentProof;
        }
        catch (SemanticProofException exception)
        {
            diagnostics.Add($"warnings:{exception.ReasonCode}");
            currentProof["reasonCode"] = exception.ReasonCode;
            return currentProof;
        }
    }

    private static BrokerSemanticSnapshotScope ReadSemanticSnapshotScope(ValidatedRunnerAction action)
    {
        var preconditions = RequiredObject(action.Document, "preconditions", "action");
        if (preconditions["semanticSnapshotRequest"] is not JsonObject reference)
        {
            throw new SemanticProofException(
                "SEMANTIC_SCOPE_BOOTSTRAP_REQUIRED",
                "No action-bound engineering semantic scope is available.");
        }

        RequireOnly(reference, "semantic snapshot request", "path", "sha256");
        var relativePath = NormalizedRelativePath(RequiredString(reference, "path", "semantic snapshot request"));
        if (relativePath != "config/engineering-semantic-scope.json")
        {
            throw new SemanticProofException(
                "SEMANTIC_SCOPE_REFERENCE_INVALID",
                "Engineering semantic scope path is unsupported.");
        }

        var path = EnsureInside(
            action.EngineeringRoot,
            Path.Combine(action.EngineeringRoot, relativePath),
            "engineering semantic scope");
        var expectedSha = RequiredSha(reference, "sha256", "semantic snapshot request");
        var scopeArtifact = ReadReviewedJsonArtifact(
            path,
            expectedSha,
            "SEMANTIC_SCOPE_DRIFT",
            "SEMANTIC_SCOPE_INVALID",
            "SEMANTIC_SCOPE_TOO_LARGE",
            MaximumSemanticScopeArtifactBytes);
        var actualSha = scopeArtifact.Sha256;
        var scope = scopeArtifact.Document;
        RequireOnly(
            scope,
            "engineering semantic scope",
            "schemaVersion",
            "kind",
            "project",
            "mappingScopes",
            "symbolApplicationPath");
        if (RequiredInt32(scope, "schemaVersion", "engineering semantic scope") != 1 ||
            RequiredString(scope, "kind", "engineering semantic scope") != "ctrlx-opcon-engineering-semantic-scope")
        {
            throw new SemanticProofException(
                "SEMANTIC_SCOPE_INVALID",
                "Engineering semantic scope contract is unsupported.");
        }

        ValidateSemanticProject(action, RequiredObject(scope, "project", "engineering semantic scope"), "SEMANTIC_SCOPE_PROJECT_MISMATCH");
        var mappingScopes = RequiredArray(scope, "mappingScopes", "engineering semantic scope");
        var mappingTargets = new JsonArray();
        if (mappingScopes.Count is 0 or > 64)
        {
            throw new SemanticProofException(
                "SEMANTIC_SCOPE_INVALID",
                "Engineering semantic mapping scope exceeds its bounded contract or is empty.");
        }

        var seenScopes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in mappingScopes)
        {
            if (node is not JsonObject item)
            {
                throw new SemanticProofException("SEMANTIC_SCOPE_INVALID", "mappingScopes entry must be an object.");
            }

            RequireOnly(item, "mapping scope", "devicePath", "recursive", "includeAllMappableChannels");
            var devicePath = RequiredString(item, "devicePath", "mapping scope");
            if (!RequiredBoolean(item, "recursive", "mapping scope") ||
                !RequiredBoolean(item, "includeAllMappableChannels", "mapping scope") ||
                !seenScopes.Add(devicePath))
            {
                throw new SemanticProofException(
                    "SEMANTIC_SCOPE_INVALID",
                    "mappingScopes must be unique recursive all-channel roots.");
            }
        }

        var symbolPath = RequiredString(scope, "symbolApplicationPath", "engineering semantic scope");
        if (symbolPath.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => segment is "." or ".."))
        {
            throw new SemanticProofException("SEMANTIC_SCOPE_INVALID", "Symbol application path is unsafe.");
        }

        return new BrokerSemanticSnapshotScope(
            relativePath,
            actualSha,
            (JsonArray)mappingScopes.DeepClone(),
            mappingTargets,
            symbolPath);
    }

    private static BrokerReviewedSemanticBaseline ReadReviewedSemanticBaseline(
        ValidatedRunnerAction action,
        BrokerSemanticSnapshotScope scope)
    {
        var preconditions = RequiredObject(action.Document, "preconditions", "action");
        if (preconditions["semanticBaseline"] is not JsonObject reference ||
            RequiredString(reference, "state", "semantic baseline reference") != "reviewed")
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED",
                "No reviewed engineering semantic baseline is bound.");
        }

        var relativePath = NormalizedRelativePath(RequiredString(reference, "path", "semantic baseline reference"));
        if (relativePath != SemanticBaselineRelativePath)
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_REFERENCE_INVALID",
                "Engineering semantic baseline path is unsupported.");
        }

        var path = EnsureInside(
            action.EngineeringRoot,
            Path.Combine(action.EngineeringRoot, relativePath),
            "engineering semantic baseline");
        var expectedSha = RequiredSha(reference, "sha256", "semantic baseline reference");
        var baselineArtifact = ReadReviewedJsonArtifact(
            path,
            expectedSha,
            "SEMANTIC_BASELINE_DRIFT",
            "SEMANTIC_BASELINE_INVALID",
            "SEMANTIC_BASELINE_TOO_LARGE",
            MaximumReviewedBaselineArtifactBytes);
        var actualSha = baselineArtifact.Sha256;
        var baseline = baselineArtifact.Document;
        RequireOnly(
            baseline,
            "engineering semantic baseline",
            "schemaVersion",
            "kind",
            "project",
            "scopeSha256",
            "canonicalFacts",
            "hashes",
            "review");
        if (RequiredInt32(baseline, "schemaVersion", "engineering semantic baseline") != 1 ||
            RequiredString(baseline, "kind", "engineering semantic baseline") != "ctrlx-opcon-engineering-semantic-baseline")
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_INVALID",
                "Engineering semantic baseline contract is unsupported.");
        }

        ValidateSemanticProject(action, RequiredObject(baseline, "project", "engineering semantic baseline"), "SEMANTIC_BASELINE_PROJECT_MISMATCH");
        var scopeSha = RequiredSha(baseline, "scopeSha256", "engineering semantic baseline");
        if (!scopeSha.Equals(scope.ArtifactSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_SCOPE_MISMATCH",
                "Reviewed semantic baseline does not bind the current scope artifact.");
        }

        var canonicalFacts = RequiredObject(baseline, "canonicalFacts", "engineering semantic baseline");
        RequireOnly(canonicalFacts, "semantic canonical facts", "mapping", "symbolConfig");
        var canonicalMapping = RequiredObject(canonicalFacts, "mapping", "semantic canonical facts");
        RequireOnly(
            canonicalMapping,
            "semantic canonical mapping",
            "scopeCount",
            "explicitTargetCount",
            "recordCount",
            "recordLimit",
            "scopes",
            "records");
        var mappingScopes = RequiredArray(canonicalMapping, "scopes", "semantic canonical mapping");
        var mappingRecords = RequiredArray(canonicalMapping, "records", "semantic canonical mapping");
        if (RequiredNonNegative(canonicalMapping, "scopeCount", "semantic canonical mapping") != mappingScopes.Count ||
            RequiredNonNegative(canonicalMapping, "explicitTargetCount", "semantic canonical mapping") != scope.MappingTargets.Count ||
            RequiredNonNegative(canonicalMapping, "recordCount", "semantic canonical mapping") != mappingRecords.Count ||
            RequiredInt32(canonicalMapping, "recordLimit", "semantic canonical mapping") != 2048 ||
            mappingScopes.Count != scope.MappingScopes.Count ||
            mappingRecords.Count > 2048)
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_INVALID",
                "Reviewed semantic mapping counters do not match its scope and records.");
        }

        var canonicalSymbol = RequiredObject(canonicalFacts, "symbolConfig", "semantic canonical facts");
        RequireOnly(
            canonicalSymbol,
            "semantic canonical Symbol facts",
            "applicationPath",
            "canonicalPayloadByteCount",
            "payloadSha256",
            "shapeSummary");
        var baselineSymbolPath = RequiredString(canonicalSymbol, "applicationPath", "semantic canonical Symbol facts");
        if (baselineSymbolPath != scope.SymbolApplicationPath)
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_SCOPE_MISMATCH",
                "Reviewed Symbol application path differs from the current scope.");
        }

        _ = RequiredNonNegative(canonicalSymbol, "canonicalPayloadByteCount", "semantic canonical Symbol facts");
        _ = RequiredSha(canonicalSymbol, "payloadSha256", "semantic canonical Symbol facts");
        ValidateSymbolShapeSummary(RequiredObject(canonicalSymbol, "shapeSummary", "semantic canonical Symbol facts"));

        var hashes = RequiredObject(baseline, "hashes", "engineering semantic baseline");
        RequireOnly(
            hashes,
            "semantic baseline hashes",
            "algorithm",
            "canonicalization",
            "mappingSha256",
            "symbolConfigSha256",
            "snapshotSha256");
        if (RequiredString(hashes, "algorithm", "semantic baseline hashes") != "SHA-256" ||
            RequiredString(hashes, "canonicalization", "semantic baseline hashes") != "ctrlx-semantic-canonical-json-v1")
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_INVALID",
                "Semantic baseline hash algorithm/canonicalization is unsupported.");
        }

        var mappingSha = RequiredSha(hashes, "mappingSha256", "semantic baseline hashes");
        var symbolSha = RequiredSha(hashes, "symbolConfigSha256", "semantic baseline hashes");
        var snapshotSha = RequiredSha(hashes, "snapshotSha256", "semantic baseline hashes");
        if (!mappingSha.Equals(CanonicalSha256(canonicalMapping), StringComparison.OrdinalIgnoreCase) ||
            !symbolSha.Equals(CanonicalSha256(canonicalSymbol), StringComparison.OrdinalIgnoreCase) ||
            !snapshotSha.Equals(CanonicalSha256(canonicalFacts), StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_HASH_INVALID",
                "Reviewed semantic baseline hashes do not match its canonical facts.");
        }

        var reviewProof = ValidateSemanticReview(
            action,
            reference,
            RequiredObject(baseline, "review", "engineering semantic baseline"));
        return new BrokerReviewedSemanticBaseline(
            relativePath,
            actualSha,
            scopeSha,
            mappingRecords.Count,
            (JsonObject)canonicalFacts.DeepClone(),
            mappingSha,
            baselineSymbolPath,
            symbolSha,
            snapshotSha,
            reviewProof);
    }

    private static void ValidateSemanticProject(
        ValidatedRunnerAction action,
        JsonObject project,
        string reasonCode)
    {
        RequireOnly(project, "engineering semantic project", "plcProjectRelativePath", "profile");
        var expectedRelative = Path.GetRelativePath(action.StationRoot, action.PlcProject).Replace('\\', '/');
        if (NormalizedRelativePath(RequiredString(project, "plcProjectRelativePath", "engineering semantic project")) != expectedRelative ||
            RequiredString(project, "profile", "engineering semantic project") != action.Profile)
        {
            throw new SemanticProofException(reasonCode, "Engineering semantic artifact is for another project/profile.");
        }
    }

    private static JsonObject ValidateSemanticReview(
        ValidatedRunnerAction action,
        JsonObject actionReference,
        JsonObject review)
    {
        RequireOnly(review, "semantic baseline review", "reviewId", "reviewer", "reviewedAtUtc", "evidencePath", "evidenceSha256");
        var reviewId = RequiredString(review, "reviewId", "semantic baseline review");
        var reviewer = RequiredString(review, "reviewer", "semantic baseline review");
        if (!IsSafeIdentifier(reviewId) || reviewer.Length > 160 || reviewer.Any(char.IsControl))
        {
            throw new SemanticProofException("SEMANTIC_BASELINE_REVIEW_INVALID", "Semantic review identity is invalid.");
        }

        if (!DateTimeOffset.TryParse(
                RequiredString(review, "reviewedAtUtc", "semantic baseline review"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var reviewedAt) ||
            reviewedAt > action.CreatedAtUtc + TimeSpan.FromMinutes(5))
        {
            throw new SemanticProofException("SEMANTIC_BASELINE_REVIEW_INVALID", "Semantic review timestamp is invalid.");
        }

        var evidenceRelative = NormalizedRelativePath(RequiredString(review, "evidencePath", "semantic baseline review"));
        var evidenceSha = RequiredSha(review, "evidenceSha256", "semantic baseline review");
        var evidencePath = EnsureInside(
            action.EngineeringRoot,
            Path.Combine(action.EngineeringRoot, evidenceRelative),
            "semantic review evidence");
        _ = RequireCurrentFileSha(evidencePath, evidenceSha, "SEMANTIC_BASELINE_REVIEW_EVIDENCE_DRIFT");
        if (evidenceRelative is SemanticBaselineRelativePath or "config/engineering-semantic-scope.json")
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_REVIEW_INVALID",
                "Semantic review evidence must be independent from the baseline and scope artifacts.");
        }
        var actionReview = RequiredObject(actionReference, "reviewEvidence", "semantic baseline reference");
        if (NormalizedRelativePath(RequiredString(actionReview, "path", "semantic baseline reference reviewEvidence")) != evidenceRelative ||
            !RequiredSha(actionReview, "sha256", "semantic baseline reference reviewEvidence")
                .Equals(evidenceSha, StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(
                "SEMANTIC_BASELINE_REVIEW_REFERENCE_MISMATCH",
                "Action-bound semantic review evidence differs from baseline provenance.");
        }

        return new JsonObject
        {
            ["reviewId"] = reviewId,
            ["reviewer"] = reviewer,
            ["reviewedAtUtc"] = reviewedAt.ToUniversalTime().ToString("O"),
            ["evidencePath"] = evidenceRelative,
            ["evidenceSha256"] = evidenceSha
        };
    }

    private static AdapterEvidence ParseAdapterEvidence(
        string text,
        string expectedProject,
        string expectedSymbolApplicationPath,
        DateTimeOffset buildCompletedAtUtc,
        DateTimeOffset receivedAtUtc)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaximumSemanticSnapshotBytes)
        {
            throw new SemanticProofException(
                "SEMANTIC_SNAPSHOT_TOO_LARGE",
                "Adapter semantic snapshot exceeds the bounded response contract.");
        }

        var value = ParseJsonObject(text, "SEMANTIC_ADAPTER_EVIDENCE_INVALID");
        RequireOnly(
            value,
            "adapter semantic evidence",
            "contractVersion",
            "contractId",
            "producer",
            "adapterPatchId",
            "capturedAtUtc",
            "projectFilePath",
            "dirtyStateVerified",
            "projectDirty",
            "recordsComplete",
            "stableAcrossRead",
            "sources",
            "canonicalFacts",
            "hashes");
        if (RequiredInt32(value, "contractVersion", "adapter semantic evidence") != 1 ||
            RequiredString(value, "contractId", "adapter semantic evidence") != SemanticPatchId ||
            RequiredString(value, "producer", "adapter semantic evidence") != SemanticProducer ||
            RequiredString(value, "adapterPatchId", "adapter semantic evidence") != SemanticPatchId ||
            !SamePath(RequiredString(value, "projectFilePath", "adapter semantic evidence"), expectedProject) ||
            !RequiredBoolean(value, "dirtyStateVerified", "adapter semantic evidence") ||
            RequiredBoolean(value, "projectDirty", "adapter semantic evidence") ||
            !RequiredBoolean(value, "recordsComplete", "adapter semantic evidence") ||
            !RequiredBoolean(value, "stableAcrossRead", "adapter semantic evidence"))
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_EVIDENCE_INVALID",
                "Adapter semantic identity, dirty-state or stability proof is invalid.");
        }

        if (!DateTimeOffset.TryParse(
                RequiredString(value, "capturedAtUtc", "adapter semantic evidence"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var captured) ||
            captured < buildCompletedAtUtc - TimeSpan.FromMilliseconds(250) ||
            captured > receivedAtUtc + TimeSpan.FromSeconds(2))
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_CORRELATION_INVALID",
                "Adapter semantic evidence was not captured after this same-call fresh Build.");
        }

        var sources = RequiredObject(value, "sources", "adapter semantic evidence");
        RequireOnly(sources, "adapter semantic sources", "mapping", "symbolConfig");
        if (RequiredString(sources, "mapping", "adapter semantic sources") !=
            "PLE ScriptEngine semantic-projection triple-read plus final mapping/dirty guard")
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_EVIDENCE_INVALID",
                "Adapter mapping source is not the frozen triple-read plus final-guard producer.");
        }

        var symbolSource = RequiredObject(sources, "symbolConfig", "adapter semantic sources");
        RequireOnly(
            symbolSource,
            "adapter Symbol source",
            "source",
            "applicationPath",
            "endpointPath",
            "httpStatus",
            "rawPayloadByteCount",
            "rawPayloadSha256",
            "settleReadCount",
            "authoritativeReadCount");
        var symbolApplicationPath = RequiredString(symbolSource, "applicationPath", "adapter Symbol source");
        var symbolEndpointPath = RequiredString(symbolSource, "endpointPath", "adapter Symbol source");
        var settleReadCount = RequiredInt32(symbolSource, "settleReadCount", "adapter Symbol source");
        if (RequiredString(symbolSource, "source", "adapter Symbol source") !=
                "PLE REST api v2 bounded settle plus authoritative triple-read" ||
            !symbolApplicationPath.Equals(expectedSymbolApplicationPath, StringComparison.Ordinal) ||
            !symbolEndpointPath.Equals(ExpectedSymbolEndpointPath(expectedSymbolApplicationPath), StringComparison.Ordinal) ||
            RequiredInt32(symbolSource, "httpStatus", "adapter Symbol source") != 200 ||
            RequiredNonNegative(symbolSource, "rawPayloadByteCount", "adapter Symbol source") > 8 * 1024 * 1024 ||
            settleReadCount is < 2 or > 4 ||
            RequiredInt32(symbolSource, "authoritativeReadCount", "adapter Symbol source") != 3)
        {
            throw new SemanticProofException("SYMBOL_SNAPSHOT_INVALID", "Symbol Configuration source metadata is invalid.");
        }
        _ = RequiredSha(symbolSource, "rawPayloadSha256", "adapter Symbol source");

        var canonicalFacts = RequiredObject(value, "canonicalFacts", "adapter semantic evidence");
        RequireOnly(canonicalFacts, "adapter canonical facts", "mapping", "symbolConfig");
        var mapping = RequiredObject(canonicalFacts, "mapping", "adapter canonical facts");
        RequireOnly(
            mapping,
            "adapter canonical mapping facts",
            "scopeCount",
            "explicitTargetCount",
            "recordCount",
            "recordLimit",
            "scopes",
            "records");
        var scopes = RequiredArray(mapping, "scopes", "adapter canonical mapping facts");
        var records = RequiredArray(mapping, "records", "adapter canonical mapping facts");
        var scopeCount = RequiredNonNegative(mapping, "scopeCount", "adapter canonical mapping facts");
        var explicitTargetCount = RequiredNonNegative(mapping, "explicitTargetCount", "adapter canonical mapping facts");
        var recordCount = RequiredNonNegative(mapping, "recordCount", "adapter canonical mapping facts");
        if (scopeCount != scopes.Count || recordCount != records.Count ||
            scopeCount > 64 || explicitTargetCount > 512 ||
            RequiredInt32(mapping, "recordLimit", "adapter canonical mapping facts") != 2048 ||
            recordCount > 2048)
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_EVIDENCE_INVALID",
                "Adapter canonical mapping counts or bounded record limit are invalid.");
        }

        var expectedScopeIndex = 0;
        foreach (var node in scopes)
        {
            if (node is not JsonObject scope)
            {
                throw new SemanticProofException("SEMANTIC_ADAPTER_EVIDENCE_INVALID", "Adapter mapping scope must be an object.");
            }

            RequireOnly(scope, "adapter mapping scope", "scopeIndex", "devicePath", "recursive", "rootName", "recordCount");
            if (RequiredNonNegative(scope, "scopeIndex", "adapter mapping scope") != expectedScopeIndex++ ||
                !RequiredBoolean(scope, "recursive", "adapter mapping scope") ||
                RequiredNonNegative(scope, "recordCount", "adapter mapping scope") > 2048)
            {
                throw new SemanticProofException("MAPPING_READBACK_INCOMPLETE", "Adapter mapping scope is invalid or incomplete.");
            }

            _ = RequiredString(scope, "devicePath", "adapter mapping scope");
            _ = RequiredString(scope, "rootName", "adapter mapping scope");
        }

        string? previousIdentity = null;
        string? previousRecordKey = null;
        foreach (var node in records)
        {
            if (node is not JsonObject record)
            {
                throw new SemanticProofException("MAPPING_READBACK_INCOMPLETE", "Adapter mapping record must be an object.");
            }

            ValidateMappingRecord(record);

            var identity = RequiredString(record, "channelIdentity", "adapter mapping record");
            var recordKey = CanonicalJson(record);
            var identityOrder = previousIdentity is null ? -1 : StringComparer.Ordinal.Compare(previousIdentity, identity);
            if (identityOrder > 0 ||
                (identityOrder == 0 && previousRecordKey is not null && StringComparer.Ordinal.Compare(previousRecordKey, recordKey) > 0))
            {
                throw new SemanticProofException("MAPPING_READBACK_INCOMPLETE", "Adapter mapping records are not in canonical ordinal order.");
            }

            previousIdentity = identity;
            previousRecordKey = recordKey;
        }

        var canonicalSymbol = RequiredObject(canonicalFacts, "symbolConfig", "adapter canonical facts");
        RequireOnly(
            canonicalSymbol,
            "adapter canonical Symbol facts",
            "applicationPath",
            "canonicalPayloadByteCount",
            "payloadSha256",
            "shapeSummary");
        if (RequiredString(canonicalSymbol, "applicationPath", "adapter canonical Symbol facts") != symbolApplicationPath ||
            !symbolApplicationPath.Equals(expectedSymbolApplicationPath, StringComparison.Ordinal) ||
            RequiredNonNegative(canonicalSymbol, "canonicalPayloadByteCount", "adapter canonical Symbol facts") > 64 * 1024 * 1024)
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_CANONICAL_FACTS_INVALID",
                "Adapter canonical Symbol facts do not correlate with its source metadata.");
        }

        _ = RequiredSha(canonicalSymbol, "payloadSha256", "adapter canonical Symbol facts");
        ValidateSymbolShapeSummary(RequiredObject(canonicalSymbol, "shapeSummary", "adapter canonical Symbol facts"));

        var hashes = RequiredObject(value, "hashes", "adapter semantic evidence");
        RequireOnly(
            hashes,
            "adapter semantic hashes",
            "algorithm",
            "canonicalization",
            "mappingSha256",
            "symbolConfigSha256",
            "snapshotSha256");
        if (RequiredString(hashes, "algorithm", "adapter semantic hashes") != "SHA-256" ||
            RequiredString(hashes, "canonicalization", "adapter semantic hashes") != "ctrlx-semantic-canonical-json-v1")
        {
            throw new SemanticProofException("SEMANTIC_ADAPTER_HASH_INVALID", "Adapter hash contract is unsupported.");
        }

        var mappingSha = RequiredSha(hashes, "mappingSha256", "adapter semantic hashes");
        var symbolSha = RequiredSha(hashes, "symbolConfigSha256", "adapter semantic hashes");
        var snapshotSha = RequiredSha(hashes, "snapshotSha256", "adapter semantic hashes");
        if (!mappingSha.Equals(CanonicalSha256(mapping), StringComparison.OrdinalIgnoreCase) ||
            !symbolSha.Equals(CanonicalSha256(canonicalSymbol), StringComparison.OrdinalIgnoreCase) ||
            !snapshotSha.Equals(CanonicalSha256(canonicalFacts), StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_HASH_INVALID",
                "Adapter hashes do not match its canonical actual facts.");
        }

        return new AdapterEvidence(
            (JsonObject)canonicalFacts.DeepClone(),
            (JsonObject)mapping.DeepClone(),
            (JsonObject)canonicalSymbol.DeepClone(),
            mappingSha,
            symbolSha,
            snapshotSha,
            recordCount,
            captured);
    }

    private static AdapterFailure ParseAdapterFailure(string text, string expectedProject)
    {
        if (Encoding.UTF8.GetByteCount(text) > 16 * 1024)
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_ERROR_RESPONSE_INVALID",
                "Adapter failure response exceeds its bounded contract.");
        }

        var value = ParseJsonObject(text, "SEMANTIC_ADAPTER_ERROR_RESPONSE_INVALID");
        RequireOnly(
            value,
            "adapter failure evidence",
            "contractVersion",
            "contractId",
            "producer",
            "adapterPatchId",
            "capturedAtUtc",
            "projectFilePath",
            "recordsComplete",
            "stableAcrossRead",
            "reasonCode",
            "reason");
        var reasonCode = RequiredString(value, "reasonCode", "adapter failure evidence");
        var rawReason = RequiredString(value, "reason", "adapter failure evidence");
        if (RequiredInt32(value, "contractVersion", "adapter failure evidence") != 1 ||
            RequiredString(value, "contractId", "adapter failure evidence") != SemanticPatchId ||
            RequiredString(value, "producer", "adapter failure evidence") != SemanticProducer ||
            RequiredString(value, "adapterPatchId", "adapter failure evidence") != SemanticPatchId ||
            !SamePath(RequiredString(value, "projectFilePath", "adapter failure evidence"), expectedProject) ||
            RequiredBoolean(value, "recordsComplete", "adapter failure evidence") ||
            RequiredBoolean(value, "stableAcrossRead", "adapter failure evidence") ||
            !IsSafeIdentifier(reasonCode) ||
            rawReason.Length > 4096)
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_ERROR_RESPONSE_INVALID",
                "Adapter failure identity or bounded payload is invalid.");
        }

        if (!DateTimeOffset.TryParse(
                RequiredString(value, "capturedAtUtc", "adapter failure evidence"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out _))
        {
            throw new SemanticProofException(
                "SEMANTIC_ADAPTER_ERROR_RESPONSE_INVALID",
                "Adapter failure timestamp is invalid.");
        }

        var normalized = Whitespace.Replace(rawReason.Trim(), " ");
        var safeReason = SensitiveWarningText.IsMatch(normalized)
            ? $"[REDACTED_SENSITIVE_ADAPTER_REASON sha256={RunnerHash.Sha256Text(normalized)}]"
            : TrimDiagnostic(normalized);
        return new AdapterFailure(reasonCode, safeReason, RunnerHash.Sha256Text(normalized));
    }

    private static void ValidateSymbolShapeSummary(JsonObject shape)
    {
        RequireOnly(
            shape,
            "Symbol shape summary",
            "rootKind",
            "topLevelKeys",
            "objectCount",
            "arrayCount",
            "scalarCount",
            "nodeCount",
            "maxDepth");
        var rootKind = RequiredString(shape, "rootKind", "Symbol shape summary");
        if (rootKind is not ("object" or "array" or "string" or "number" or "boolean" or "null"))
        {
            throw new SemanticProofException("SYMBOL_SNAPSHOT_INVALID", "Symbol payload root kind is unsupported.");
        }

        var topLevelKeys = RequiredArray(shape, "topLevelKeys", "Symbol shape summary");
        string? previous = null;
        foreach (var node in topLevelKeys)
        {
            if (node is not JsonValue item || !item.TryGetValue<string>(out var key) || key is null ||
                (previous is not null && StringComparer.Ordinal.Compare(previous, key) >= 0))
            {
                throw new SemanticProofException("SYMBOL_SNAPSHOT_INVALID", "Symbol top-level keys are not unique ordinal strings.");
            }

            previous = key;
        }

        if (rootKind != "object" && topLevelKeys.Count != 0)
        {
            throw new SemanticProofException("SYMBOL_SNAPSHOT_INVALID", "Only an object Symbol payload may have top-level keys.");
        }

        var objectCount = RequiredNonNegative(shape, "objectCount", "Symbol shape summary");
        var arrayCount = RequiredNonNegative(shape, "arrayCount", "Symbol shape summary");
        var scalarCount = RequiredNonNegative(shape, "scalarCount", "Symbol shape summary");
        var nodeCount = RequiredNonNegative(shape, "nodeCount", "Symbol shape summary");
        var maxDepth = RequiredNonNegative(shape, "maxDepth", "Symbol shape summary");
        if (nodeCount != objectCount + arrayCount + scalarCount || nodeCount == 0 || maxDepth > 128)
        {
            throw new SemanticProofException("SYMBOL_SNAPSHOT_INVALID", "Symbol shape counters are inconsistent.");
        }
    }

    private static void ValidateMappingRecord(JsonObject record)
    {
        RequireNoExtra(
            record,
            "adapter mapping record",
            "recordKind",
            "scopeIndex",
            "scopeDevicePath",
            "relativeDevicePath",
            "deviceIndexPath",
            "deviceName",
            "sourceKind",
            "parameterSetKind",
            "connectorIndex",
            "parameterIndex",
            "parameterId",
            "parameterName",
            "channelIdentity",
            "channelName",
            "bindingSource",
            "actualVariable",
            "targetIndex",
            "devicePath",
            "channelPath",
            "resolver");
        var kind = RequiredString(record, "recordKind", "adapter mapping record");
        _ = RequiredStringAllowEmpty(record, "actualVariable", "adapter mapping record");
        _ = RequiredString(record, "channelIdentity", "adapter mapping record");
        if (kind == "scope-channel")
        {
            _ = RequiredNonNegative(record, "scopeIndex", "adapter mapping record");
            _ = RequiredString(record, "scopeDevicePath", "adapter mapping record");
            _ = RequiredStringAllowEmpty(record, "relativeDevicePath", "adapter mapping record");
            _ = RequiredStringAllowEmpty(record, "deviceIndexPath", "adapter mapping record");
            _ = RequiredString(record, "deviceName", "adapter mapping record");
            var sourceKind = RequiredString(record, "sourceKind", "adapter mapping record");
            _ = RequiredString(record, "channelName", "adapter mapping record");
            _ = RequiredString(record, "bindingSource", "adapter mapping record");
            if (sourceKind == "tree-channel")
            {
                RequireAbsent(
                    record,
                    "scope tree-channel record",
                    "parameterSetKind",
                    "connectorIndex",
                    "parameterIndex",
                    "parameterId",
                    "parameterName");
            }
            else if (sourceKind == "connector-parameter")
            {
                _ = RequiredString(record, "parameterSetKind", "adapter mapping record");
                ValidateNullableNonNegative(record, "connectorIndex", "adapter mapping record");
                _ = RequiredNonNegative(record, "parameterIndex", "adapter mapping record");
                _ = RequiredStringAllowEmpty(record, "parameterId", "adapter mapping record");
                _ = RequiredString(record, "parameterName", "adapter mapping record");
            }
            else
            {
                throw new SemanticProofException("MAPPING_READBACK_INCOMPLETE", "Adapter scope record sourceKind is unsupported.");
            }

            RequireAbsent(record, "scope-channel record", "targetIndex", "devicePath", "channelPath", "resolver");
            return;
        }

        if (kind != "explicit-target")
        {
            throw new SemanticProofException("MAPPING_READBACK_INCOMPLETE", "Adapter mapping record kind is unsupported.");
        }

        _ = RequiredNonNegative(record, "targetIndex", "adapter mapping record");
        _ = RequiredString(record, "devicePath", "adapter mapping record");
        _ = RequiredString(record, "channelPath", "adapter mapping record");
        _ = RequiredString(record, "resolver", "adapter mapping record");
        _ = RequiredString(record, "deviceName", "adapter mapping record");
        _ = RequiredString(record, "channelName", "adapter mapping record");
        _ = RequiredString(record, "bindingSource", "adapter mapping record");
        RequireAbsent(
            record,
            "explicit-target record",
            "scopeIndex",
            "scopeDevicePath",
            "relativeDevicePath",
            "deviceIndexPath",
            "sourceKind",
            "parameterSetKind",
            "parameterName");
        if (record["parameterIndex"] is not null)
        {
            _ = RequiredNonNegative(record, "parameterIndex", "adapter mapping record");
            _ = RequiredStringAllowEmpty(record, "parameterId", "adapter mapping record");
            ValidateNullableNonNegative(record, "connectorIndex", "adapter mapping record");
        }
        else
        {
            RequireAbsent(record, "explicit tree-target record", "parameterIndex", "parameterId", "connectorIndex");
        }
    }

    private static JsonObject ProduceMappingCandidate(AdapterEvidence adapter) => new()
    {
        ["producer"] = SemanticProducer,
        ["contractVersion"] = 1,
        ["adapterPatchId"] = SemanticPatchId,
        ["verified"] = false,
        ["reasonCode"] = "SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED",
        ["actualRecordCount"] = adapter.MappingRecordCount,
        ["actualMappingSha256"] = adapter.MappingSha256,
        ["candidateCanonicalFacts"] = adapter.CanonicalMapping.DeepClone()
    };

    private static JsonObject ProduceSymbolCandidate(AdapterEvidence adapter) => new()
    {
        ["producer"] = SemanticProducer,
        ["contractVersion"] = 1,
        ["adapterPatchId"] = SemanticPatchId,
        ["verified"] = false,
        ["reasonCode"] = "SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED",
        ["actualSymbolConfigSha256"] = adapter.SymbolConfigSha256,
        ["candidateCanonicalFacts"] = adapter.CanonicalSymbolConfig.DeepClone()
    };

    private static JsonObject ProduceMapping(
        BrokerReviewedSemanticBaseline baseline,
        AdapterEvidence adapter,
        ICollection<string> diagnostics)
    {
        try
        {
            if (adapter.MappingRecordCount != baseline.ExpectedMappingCount)
            {
                throw new SemanticProofException(
                    "MAPPING_TARGET_COUNT_MISMATCH",
                    "Actual mapping record count differs from the reviewed target set.");
            }

            var expectedMapping = RequiredObject(baseline.ExpectedCanonicalFacts, "mapping", "reviewed semantic baseline");
            if (!adapter.MappingSha256.Equals(baseline.ExpectedMappingSha256, StringComparison.OrdinalIgnoreCase) ||
                !JsonNode.DeepEquals(adapter.CanonicalMapping, expectedMapping))
            {
                throw new SemanticProofException(
                    "MAPPING_CANONICAL_SHA_MISMATCH",
                    "Actual canonical mapping snapshot differs from the reviewed baseline hash.");
            }

            return new JsonObject
            {
                ["producer"] = SemanticProducer,
                ["contractVersion"] = 1,
                ["adapterPatchId"] = SemanticPatchId,
                ["verified"] = true,
                ["recordCount"] = adapter.MappingRecordCount,
                ["mappingSha256"] = adapter.MappingSha256
            };
        }
        catch (SemanticProofException exception)
        {
            diagnostics.Add($"mapping:{exception.ReasonCode}");
            return UnverifiedProof(SemanticProducer, exception.ReasonCode);
        }
    }

    private static (JsonObject Proof, JsonObject? NextRoute) ProduceSymbol(
        string actionKind,
        BrokerReviewedSemanticBaseline baseline,
        AdapterEvidence adapter,
        ICollection<string> diagnostics)
    {
        try
        {
            var expectedSymbol = RequiredObject(baseline.ExpectedCanonicalFacts, "symbolConfig", "reviewed semantic baseline");
            if (RequiredString(adapter.CanonicalSymbolConfig, "applicationPath", "adapter canonical Symbol facts") != baseline.SymbolApplicationPath ||
                !adapter.SymbolConfigSha256.Equals(baseline.ExpectedSymbolConfigSha256, StringComparison.OrdinalIgnoreCase) ||
                !JsonNode.DeepEquals(adapter.CanonicalSymbolConfig, expectedSymbol))
            {
                throw new SemanticProofException(
                    "SYMBOL_BASELINE_MISMATCH",
                    "Actual Symbol Configuration payload differs from the reviewed baseline hash.");
            }

            return (new JsonObject
            {
                ["producer"] = SemanticProducer,
                ["contractVersion"] = 1,
                ["adapterPatchId"] = SemanticPatchId,
                ["verified"] = true,
                ["applicationPath"] = baseline.SymbolApplicationPath,
                ["symbolConfigSha256"] = adapter.SymbolConfigSha256,
                ["snapshotSha256"] = adapter.SnapshotSha256
            }, null);
        }
        catch (SemanticProofException exception)
        {
            diagnostics.Add($"symbol:{exception.ReasonCode}");
            var routeKind = actionKind == "inspect_and_build"
                ? "cpstudio-export-2-review"
                : "cpstudio-change-review";
            return (
                UnverifiedProof(SemanticProducer, exception.ReasonCode),
                new JsonObject
                {
                    ["kind"] = routeKind,
                    ["reasonCode"] = exception.ReasonCode,
                    ["automaticExecutionAllowed"] = false
                });
        }
    }

    private static JsonArray WarningRecords(BrokerCompileProofState build)
    {
        if (build.Warnings < 0 || build.Warnings > MaximumWarningRecordCount)
        {
            throw new SemanticProofException(
                "WARNING_RECORDS_TOO_LARGE",
                $"Fresh Build warning count exceeds the controlled limit of {MaximumWarningRecordCount}.");
        }

        var result = new JsonArray();
        foreach (var record in build.Records.Where(value => value.Severity == "warning"))
        {
            result.Add(record.Text);
        }

        if (result.Count != build.Warnings)
        {
            throw new SemanticProofException(
                "WARNING_RECORDS_INCOMPLETE",
                "Fresh Build warning count does not match its complete records.");
        }

        return result;
    }

    private static JsonArray? ObservationWarningRecords(JsonArray rawWarningRecords)
    {
        var result = new JsonArray();
        var totalBytes = 0;
        foreach (var node in rawWarningRecords)
        {
            var raw = node?.GetValue<string>() ?? string.Empty;
            var rawBytes = JsonStringUtf8Bytes(raw);
            if (SensitiveWarningText.IsMatch(raw) ||
                rawBytes > MaximumObservationWarningRecordBytes ||
                totalBytes + rawBytes > MaximumObservationWarningRecordsBytes)
            {
                return null;
            }

            totalBytes = checked(totalBytes + rawBytes);
            result.Add(raw);
        }

        return result;
    }

    internal static JsonArray ObservationDiagnosticRows(IReadOnlyList<string> rawRows)
    {
        ArgumentNullException.ThrowIfNull(rawRows);
        if (rawRows.Count > MaximumWarningRecordCount)
        {
            throw new SemanticProofException(
                "DIAGNOSTIC_ROWS_TOO_LARGE",
                $"Fresh Build diagnostic row count exceeds the controlled limit of {MaximumWarningRecordCount}.");
        }

        var rows = new JsonArray();
        var totalBytes = 0;
        for (var index = 0; index < rawRows.Count; index++)
        {
            var raw = rawRows[index];
            if (string.IsNullOrWhiteSpace(raw))
            {
                throw new SemanticProofException(
                    "DIAGNOSTIC_ROWS_INVALID",
                    "Fresh Build contains an empty diagnostic row.");
            }

            var trimmed = raw.Trim();
            var digest = RunnerHash.Sha256Text(trimmed);
            var oversizedPlaceholder = $"[TRUNCATED_OVERSIZE_DIAGNOSTIC sha256={digest}]";
            var reservedPlaceholderBytes = Math.Max(
                JsonStringUtf8Bytes(SensitiveDiagnosticPlaceholder),
                JsonStringUtf8Bytes(oversizedPlaceholder));
            var remainingMinimumBytes = checked((rawRows.Count - index - 1) * reservedPlaceholderBytes);
            var rawBytes = JsonStringUtf8Bytes(trimmed);
            var value = SensitiveWarningText.IsMatch(trimmed)
                ? SensitiveDiagnosticPlaceholder
                : rawBytes <= MaximumObservationWarningRecordBytes &&
                  totalBytes + rawBytes + remainingMinimumBytes <= MaximumObservationWarningRecordsBytes
                    ? trimmed
                    : oversizedPlaceholder;

            totalBytes = checked(totalBytes + JsonStringUtf8Bytes(value));
            rows.Add(value);
        }

        if (totalBytes > MaximumObservationWarningRecordsBytes)
        {
            throw new SemanticProofException(
                "DIAGNOSTIC_ROWS_TOO_LARGE",
                "Sanitized diagnostic rows exceed the controlled observation budget.");
        }

        return rows;
    }

    private static int JsonStringUtf8Bytes(string value) =>
        Encoding.UTF8.GetByteCount(JsonValue.Create(value)!.ToJsonString(CanonicalJsonOptions));

    private static JsonArray WarningSignatures(JsonArray warningRecords, int expectedCount)
    {
        if (warningRecords.Count != expectedCount)
        {
            throw new SemanticProofException(
                "WARNING_RECORDS_INCOMPLETE",
                "Fresh Build warning records are incomplete.");
        }

        var counts = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var node in warningRecords)
        {
            var text = node?.GetValue<string>() ?? string.Empty;
            var normalized = Whitespace.Replace(text.Trim(), " ");
            if (string.IsNullOrWhiteSpace(normalized))
            {
                throw new SemanticProofException(
                    "WARNING_RECORDS_INVALID",
                    "Fresh Build contains an empty warning record.");
            }

            var sha = WarningRecordSignatureSha256(
                code: string.Empty,
                message: normalized,
                objectPath: string.Empty,
                position: string.Empty,
                source: string.Empty);
            counts[sha] = counts.TryGetValue(sha, out var count) ? count + 1 : 1;
        }

        var result = new JsonArray();
        foreach (var item in counts)
        {
            result.Add(new JsonObject
            {
                ["sha256"] = item.Key,
                ["occurrences"] = item.Value
            });
        }

        return result;
    }

    private static bool ContainsPleWarningOutputTruncationSentinel(JsonArray warningRecords)
    {
        foreach (var node in warningRecords)
        {
            var raw = node?.GetValue<string>() ?? string.Empty;
            var normalized = Whitespace.Replace(raw.Trim(), " ");
            if (PleWarningOutputTruncationSentinel.IsMatch(normalized))
            {
                return true;
            }
        }

        return false;
    }

    internal static string WarningRecordSignatureSha256(
        string code,
        string message,
        string objectPath,
        string position,
        string source)
    {
        var canonical = new JsonObject
        {
            ["code"] = NormalizeWarningField(code),
            ["message"] = NormalizeWarningField(message),
            ["objectPath"] = NormalizeWarningField(objectPath),
            ["position"] = NormalizeWarningField(position),
            ["source"] = NormalizeWarningField(source)
        };
        return RunnerHash.Sha256Text(CanonicalJson(canonical));
    }

    private static string NormalizeWarningField(string value) => Whitespace.Replace(value.Trim(), " ");

    private static JsonArray ValidateSignatureMultiset(JsonArray signatures, string reasonCode)
    {
        var sorted = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var node in signatures)
        {
            if (node is not JsonObject signature)
            {
                throw new SemanticProofException(reasonCode, "Warning signature must be an object.");
            }

            RequireOnly(signature, "warning signature", "sha256", "occurrences");
            var sha = RequiredSha(signature, "sha256", "warning signature");
            if (sha.Equals(PleWarningTruncationSignatureSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new SemanticProofException(
                    "PLE_WARNING_OUTPUT_TRUNCATED",
                    "Reviewed warning baseline contains PLE's warning-output truncation sentinel and cannot represent a complete warning population.");
            }
            var occurrences = RequiredInt32(signature, "occurrences", "warning signature");
            if (occurrences <= 0 || !sorted.TryAdd(sha, occurrences))
            {
                throw new SemanticProofException(reasonCode, "Warning signature multiset is invalid or duplicated.");
            }
        }

        var result = new JsonArray();
        foreach (var item in sorted)
        {
            result.Add(new JsonObject
            {
                ["sha256"] = item.Key,
                ["occurrences"] = item.Value
            });
        }

        return result;
    }

    private static void ValidateWarningBaselineProject(ValidatedRunnerAction action, JsonObject project)
    {
        RequireOnly(project, "warning baseline project", "plcProjectRelativePath", "profile");
        var expectedRelative = Path.GetRelativePath(action.StationRoot, action.PlcProject).Replace('\\', '/');
        if (NormalizedRelativePath(RequiredString(project, "plcProjectRelativePath", "warning baseline project")) != expectedRelative ||
            RequiredString(project, "profile", "warning baseline project") != action.Profile)
        {
            throw new SemanticProofException(
                "WARNING_BASELINE_PROJECT_MISMATCH",
                "Warning baseline is for a different project/profile.");
        }
    }

    private static JsonObject ValidateWarningReview(ValidatedRunnerAction action, JsonObject review)
    {
        RequireOnly(
            review,
            "warning baseline review",
            "reviewId",
            "reviewer",
            "reviewedAtUtc",
            "evidencePath",
            "evidenceSha256");
        var reviewId = RequiredString(review, "reviewId", "warning baseline review");
        var reviewer = RequiredString(review, "reviewer", "warning baseline review");
        if (!IsSafeIdentifier(reviewId) || reviewer.Length > 160 || reviewer.Any(char.IsControl))
        {
            throw new SemanticProofException(
                "WARNING_BASELINE_REVIEW_INVALID",
                "Warning review provenance contains an invalid identifier.");
        }

        if (!DateTimeOffset.TryParse(
                RequiredString(review, "reviewedAtUtc", "warning baseline review"),
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var reviewedAt) ||
            reviewedAt > action.CreatedAtUtc + TimeSpan.FromMinutes(5))
        {
            throw new SemanticProofException(
                "WARNING_BASELINE_REVIEW_INVALID",
                "Warning review timestamp is invalid or newer than the immutable action.");
        }

        var evidenceRelative = NormalizedRelativePath(
            RequiredString(review, "evidencePath", "warning baseline review"));
        var evidencePath = EnsureInside(
            action.EngineeringRoot,
            Path.Combine(action.EngineeringRoot, evidenceRelative),
            "warning review evidence");
        var evidenceSha = RequiredSha(review, "evidenceSha256", "warning baseline review");
        _ = RequireCurrentFileSha(evidencePath, evidenceSha, "WARNING_BASELINE_REVIEW_EVIDENCE_DRIFT");
        if (evidenceRelative == WarningBaselineRelativePath)
        {
            throw new SemanticProofException(
                "WARNING_BASELINE_REVIEW_INVALID",
                "Review evidence cannot be the baseline file itself.");
        }

        return new JsonObject
        {
            ["reviewId"] = reviewId,
            ["reviewer"] = reviewer,
            ["reviewedAtUtc"] = reviewedAt.ToUniversalTime().ToString("O"),
            ["evidencePath"] = evidenceRelative,
            ["evidenceSha256"] = evidenceSha
        };
    }

    private static async Task<string> RunGitAsync(
        string workingDirectory,
        CancellationToken cancellationToken,
        params string[] arguments)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "git",
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };
        process.StartInfo.ArgumentList.Add("-C");
        process.StartInfo.ArgumentList.Add(workingDirectory);
        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        try
        {
            if (!process.Start())
            {
                throw new IOException("git process did not start.");
            }
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            throw new SemanticProofException(
                "RECOVERABLE_BASELINE_GIT_UNAVAILABLE",
                "Git is unavailable for recoverable-baseline proof.",
                exception);
        }

        var standardOutput = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var standardError = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // The bounded command exited while the timeout was being handled.
            }

            throw new SemanticProofException(
                "RECOVERABLE_BASELINE_GIT_TIMEOUT",
                "Git recoverable-baseline proof exceeded its bounded timeout.");
        }

        var output = await standardOutput.ConfigureAwait(false);
        var error = await standardError.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            throw new SemanticProofException(
                "RECOVERABLE_BASELINE_GIT_FAILED",
                $"Git recoverable-baseline check failed with exit code {process.ExitCode}: {TrimDiagnostic(error)}");
        }

        return output;
    }

    private static JsonObject UnverifiedProof(string producer, string reasonCode) => new()
    {
        ["producer"] = producer,
        ["contractVersion"] = 1,
        ["verified"] = false,
        ["reasonCode"] = reasonCode
    };

    private static string BlockingReason(JsonObject proofs, JsonObject? nextRoute)
    {
        var routeReason = nextRoute is null ? string.Empty : OptionalString(nextRoute, "reasonCode");
        if (IsSafeIdentifier(routeReason))
        {
            return routeReason;
        }

        foreach (var name in new[]
        {
            "ownership",
            "readback",
            "recoverableBaseline",
            "warnings",
            "semanticBaseline",
            "mapping",
            "symbolPostProcessing"
        })
        {
            if (proofs[name] is JsonObject proof && !RequiredProofVerified(proof))
            {
                var proofReason = OptionalString(proof, "reasonCode");
                if (IsSafeIdentifier(proofReason))
                {
                    return proofReason;
                }
            }
        }

        return "SEMANTIC_ACCEPTANCE_BLOCKED";
    }

    private static bool RequiredProofVerified(JsonObject proof) =>
        proof["verified"] is JsonValue value && value.TryGetValue<bool>(out var verified) && verified;

    private static string CanonicalSha256(JsonNode node) => RunnerHash.Sha256Text(CanonicalJson(node));

    private static string CanonicalJson(JsonNode node)
    {
        var serialized = Canonicalize(node)!.ToJsonString(CanonicalJsonOptions);
        serialized = JsonSurrogateEscape.Replace(serialized, match =>
        {
            var high = int.Parse(match.Groups["high"].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var low = int.Parse(match.Groups["low"].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return char.ConvertFromUtf32(char.ConvertToUtf32((char)high, (char)low));
        });
        return JsonBmpEscape.Replace(serialized, match =>
        {
            var code = int.Parse(match.Groups["code"].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return code >= 0x20 && code is not (0x22 or 0x5C) && !char.IsSurrogate((char)code)
                ? ((char)code).ToString()
                : match.Value;
        });
    }

    private static JsonNode? Canonicalize(JsonNode? node)
    {
        if (node is null)
        {
            return null;
        }

        if (node is JsonObject value)
        {
            var result = new JsonObject();
            foreach (var item in value.OrderBy(item => item.Key, StringComparer.Ordinal))
            {
                result[item.Key] = Canonicalize(item.Value);
            }

            return result;
        }

        if (node is JsonArray array)
        {
            var result = new JsonArray();
            foreach (var item in array)
            {
                result.Add(Canonicalize(item));
            }

            return result;
        }

        return JsonNode.Parse(node.ToJsonString());
    }

    private static BrokerReviewedJsonArtifact ReadReviewedJsonArtifact(
        string path,
        string expectedSha,
        string driftReasonCode,
        string invalidReasonCode,
        string tooLargeReasonCode,
        int maximumBytes)
    {
        if (!File.Exists(path))
        {
            throw new SemanticProofException(driftReasonCode, "Reviewed artifact is missing.");
        }

        byte[] bytes;
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 16 * 1024,
                options: FileOptions.SequentialScan);
            if (stream.Length > maximumBytes)
            {
                throw new SemanticProofException(
                    tooLargeReasonCode,
                    $"Reviewed artifact exceeds the controlled limit of {maximumBytes} bytes.");
            }

            using var buffer = new MemoryStream(capacity: checked((int)Math.Min(stream.Length, maximumBytes)));
            var chunk = new byte[16 * 1024];
            while (true)
            {
                var read = stream.Read(chunk, 0, chunk.Length);
                if (read == 0)
                {
                    break;
                }

                if (buffer.Length + read > maximumBytes)
                {
                    throw new SemanticProofException(
                        tooLargeReasonCode,
                        $"Reviewed artifact exceeds the controlled limit of {maximumBytes} bytes.");
                }

                buffer.Write(chunk, 0, read);
            }

            bytes = buffer.ToArray();
        }
        catch (SemanticProofException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new SemanticProofException(
                driftReasonCode,
                "Reviewed artifact could not be read as one stable bounded byte sequence.",
                exception);
        }

        var actualSha = Convert.ToHexString(SHA256.HashData(bytes));
        if (!actualSha.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(driftReasonCode, "Reviewed artifact SHA-256 drifted.");
        }

        try
        {
            var document = JsonNode.Parse(
                bytes,
                nodeOptions: null,
                documentOptions: new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32
                }) as JsonObject
                ?? throw new JsonException("Root must be an object.");
            return new BrokerReviewedJsonArtifact(document, actualSha, bytes.Length);
        }
        catch (JsonException exception)
        {
            throw new SemanticProofException(invalidReasonCode, "Reviewed JSON artifact is invalid.", exception);
        }
    }

    private static JsonObject ParseJsonObject(string text, string reasonCode)
    {
        try
        {
            return JsonNode.Parse(
                text,
                nodeOptions: null,
                documentOptions: new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32
                }) as JsonObject
                ?? throw new JsonException("Root must be an object.");
        }
        catch (JsonException exception)
        {
            throw new SemanticProofException(reasonCode, "Adapter semantic evidence is invalid JSON.", exception);
        }
    }

    private static void RequireOnly(JsonObject value, string context, params string[] allowed)
    {
        var expected = new HashSet<string>(allowed, StringComparer.Ordinal);
        var extra = value.Select(item => item.Key).FirstOrDefault(key => !expected.Contains(key));
        if (extra is not null)
        {
            throw new SemanticProofException(
                "SEMANTIC_PROOF_SCHEMA_INVALID",
                $"{context} contains unsupported property '{extra}'.");
        }

        var missing = expected.FirstOrDefault(key => !value.ContainsKey(key));
        if (missing is not null)
        {
            throw new SemanticProofException(
                "SEMANTIC_PROOF_SCHEMA_INVALID",
                $"{context} is missing '{missing}'.");
        }
    }

    private static void RequireNoExtra(JsonObject value, string context, params string[] allowed)
    {
        var expected = new HashSet<string>(allowed, StringComparer.Ordinal);
        var extra = value.Select(item => item.Key).FirstOrDefault(key => !expected.Contains(key));
        if (extra is not null)
        {
            throw new SemanticProofException(
                "SEMANTIC_PROOF_SCHEMA_INVALID",
                $"{context} contains unsupported property '{extra}'.");
        }
    }

    private static void RequireAbsent(JsonObject value, string context, params string[] names)
    {
        var present = names.FirstOrDefault(value.ContainsKey);
        if (present is not null)
        {
            throw new SemanticProofException(
                "SEMANTIC_PROOF_SCHEMA_INVALID",
                $"{context} cannot contain '{present}'.");
        }
    }

    private static JsonObject RequiredObject(JsonObject value, string name, string context) =>
        value[name] as JsonObject
        ?? throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be an object.");

    private static JsonArray RequiredArray(JsonObject value, string name, string context) =>
        value[name] as JsonArray
        ?? throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be an array.");

    private static string RequiredString(JsonObject value, string name, string context)
    {
        if (value[name] is not JsonValue node ||
            !node.TryGetValue<string>(out var result) ||
            string.IsNullOrWhiteSpace(result))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be a non-empty string.");
        }

        return result;
    }

    private static string RequiredStringAllowEmpty(JsonObject value, string name, string context)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<string>(out var result) || result is null)
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be a string.");
        }

        return result;
    }

    private static string OptionalString(JsonObject value, string name) =>
        value[name] is JsonValue node && node.TryGetValue<string>(out var result)
            ? result ?? string.Empty
            : string.Empty;

    private static int RequiredInt32(JsonObject value, string name, string context)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<int>(out var result))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be an integer.");
        }

        return result;
    }

    private static int RequiredNonNegative(JsonObject value, string name, string context)
    {
        var result = RequiredInt32(value, name, context);
        if (result < 0 || result > 10_000_000)
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} is out of range.");
        }

        return result;
    }

    private static void ValidateNullableNonNegative(JsonObject value, string name, string context)
    {
        if (!value.ContainsKey(name))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} is required.");
        }

        if (value[name] is not null)
        {
            _ = RequiredNonNegative(value, name, context);
        }
    }

    private static bool RequiredBoolean(JsonObject value, string name, string context)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<bool>(out var result))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be Boolean.");
        }

        return result;
    }

    private static string RequiredSha(JsonObject value, string name, string context)
    {
        var result = RequiredString(value, name, context);
        if (result.Length != 64 || !result.All(Uri.IsHexDigit))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_SCHEMA_INVALID", $"{context}.{name} must be SHA-256.");
        }

        return result.ToUpperInvariant();
    }

    private static string RequireCurrentFileSha(string path, string expectedSha, string reasonCode)
    {
        if (!File.Exists(path))
        {
            throw new SemanticProofException(reasonCode, "Reviewed artifact is missing.");
        }

        var actual = RunnerHash.Sha256File(path);
        if (!actual.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException(reasonCode, "Reviewed artifact SHA-256 drifted.");
        }

        return actual;
    }

    private static string EnsureInside(string root, string path, string description)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) &&
            !fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new SemanticProofException("SEMANTIC_PROOF_PATH_ESCAPE", $"{description} escaped its root.");
        }

        return fullPath;
    }

    private static string NormalizedRelativePath(string path) => path.Replace('\\', '/').TrimStart('/');

    private static string ExpectedSymbolEndpointPath(string applicationPath) =>
        "/plc/engineering/api/v2/devices/" +
        string.Join('/', applicationPath.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString)) +
        "/symbol-config";

    private static bool IsSafeIdentifier(string value) =>
        value.Length is > 0 and <= 128 && value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-');

    private static bool IsGitObjectId(string value) =>
        value.Length is 40 or 64 && value.All(Uri.IsHexDigit);

    private static bool SamePath(string left, string right)
    {
        try
        {
            return Path.GetFullPath(left).Equals(Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static string TrimDiagnostic(string value)
    {
        var trimmed = Whitespace.Replace(value.Trim(), " ");
        return trimmed.Length <= 240 ? trimmed : trimmed[..240];
    }

    private sealed record AdapterEvidence(
        JsonObject CanonicalFacts,
        JsonObject CanonicalMapping,
        JsonObject CanonicalSymbolConfig,
        string MappingSha256,
        string SymbolConfigSha256,
        string SnapshotSha256,
        int MappingRecordCount,
        DateTimeOffset CapturedAtUtc);

    private sealed record AdapterFailure(
        string ReasonCode,
        string SafeReason,
        string ReasonSha256);

    private sealed class SemanticProofException : Exception
    {
        public SemanticProofException(string reasonCode, string message, Exception? innerException = null)
            : base(message, innerException)
        {
            ReasonCode = reasonCode;
        }

        public string ReasonCode { get; }
    }
}
