import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE S256 (RFC 7636) verifier + challenge generator.
///
/// - `verifier` is 64 characters drawn from the RFC's unreserved set
///   `[A-Za-z0-9-._~]`, chosen uniformly at random via `Random.secure()`.
/// - `challenge` is the unpadded base64url encoding of SHA-256(verifier).
///
/// Regenerate a fresh [Pkce] on every login attempt — never reuse a
/// verifier/challenge across retries.
class Pkce {
  const Pkce({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  static const _verifierLength = 64;
  static const _unreservedChars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static Pkce generate() {
    final verifier = _randomString(_verifierLength);
    final digest = sha256.convert(utf8.encode(verifier)).bytes;
    final challenge = base64Url.encode(digest).replaceAll('=', '');
    return Pkce(verifier: verifier, challenge: challenge);
  }

  /// A random opaque `state` value for CSRF protection on the authorize round-trip.
  static String generateState([int length = 32]) => _randomString(length);

  static String _randomString(int length) {
    final rng = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(_unreservedChars[rng.nextInt(_unreservedChars.length)]);
    }
    return buffer.toString();
  }
}
