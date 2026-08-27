using System.Text.RegularExpressions;

namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

internal static class BrokerValueValidation
{
    private static readonly Regex SafeIdentifierRegex = new(
        "\\A[A-Za-z0-9_.:-]+\\z",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex Sha256Regex = new(
        "\\A[A-Fa-f0-9]{64}\\z",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    public static void RequireSafeIdentifier(string value, string name, int maximumLength = 128)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            value is "." or ".." ||
            !SafeIdentifierRegex.IsMatch(value))
        {
            throw new BrokerInfrastructureException("BROKER_IDENTIFIER_INVALID", $"{name} is not a safe identifier.");
        }
    }

    public static void RequireSha256(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || !Sha256Regex.IsMatch(value))
        {
            throw new BrokerInfrastructureException("BROKER_SHA256_INVALID", $"{name} must be a SHA-256 value.");
        }
    }

    public static void RequireBoundedText(string? value, string name, int maximumLength)
    {
        if (value is null)
        {
            return;
        }

        if (value.Length > maximumLength || value.Contains('\0'))
        {
            throw new BrokerInfrastructureException("BROKER_TEXT_INVALID", $"{name} is too long or contains a null character.");
        }
    }
}
