// Verifies an HMAC-SHA256 webhook signature in constant time. The first
// webhook endpoint otherwise compares hex strings with ==, which returns at
// the first differing character and leaks the signature a byte at a time.
//
// The caller passes the RAW request body — the bytes that were signed, not a
// re-serialized model — and the signature header as sent: hex, with or
// without the "sha256=" prefix GitHub-style senders add. On false, answer 401
// and raise SecurityEvents.WebhookSignatureRejected; docs/manual-setup.md has
// the endpoint.
using System.Security.Cryptography;

namespace Api;

internal static class WebhookSignature
{
    private const string Prefix = "sha256=";

    public static bool IsValid(ReadOnlySpan<byte> secret, ReadOnlySpan<byte> body, string? signature)
    {
        if (secret.IsEmpty || string.IsNullOrEmpty(signature))
        {
            return false;
        }

        var hex = signature.AsSpan();
        if (hex.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
        {
            hex = hex[Prefix.Length..];
        }

        Span<byte> provided = stackalloc byte[HMACSHA256.HashSizeInBytes];
        if (hex.Length != provided.Length * 2
            || Convert.FromHexString(hex, provided, out _, out _) != System.Buffers.OperationStatus.Done)
        {
            return false;
        }

        Span<byte> expected = stackalloc byte[HMACSHA256.HashSizeInBytes];
        HMACSHA256.HashData(secret, body, expected);
        return CryptographicOperations.FixedTimeEquals(expected, provided);
    }
}
