import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'native_bridge.dart';

/// Source of HTTP clients for every request to an API, speech or search server.
///
/// Dart's HTTP client trusts only the certificates that ship with the system and ignores the
/// ones the user installed in the Android settings. Self-hosted servers behind a private CA
/// would fail with a handshake error, so those certificates are read once at startup and
/// added to the trust store of every client created here.
class AppHttp {
  AppHttp._();

  static SecurityContext? _context;
  static List<String> _userPems = const [];

  /// Number of user installed certificate authorities that were added, for diagnostics.
  static int userCertificateCount = 0;

  /// Loads the user certificates. Call once at startup, before any request.
  static Future<void> init() async {
    _userPems = await NativeBridge.userCertificates();
    _context = buildContext(_userPems);
  }

  /// A context that trusts the system roots plus the given PEM certificates. Returns null
  /// if there is nothing to add, so the default client is used.
  static SecurityContext? buildContext(List<String> pems) {
    userCertificateCount = 0;
    if (pems.isEmpty) return null;

    final context = SecurityContext(withTrustedRoots: true);
    for (final pem in pems) {
      try {
        context.setTrustedCertificatesBytes(utf8.encode(pem));
        userCertificateCount++;
      } on TlsException {
        // A certificate that is already trusted or unreadable must not block the others
      }
    }
    return userCertificateCount == 0 ? null : context;
  }

  /// [extraPem] is a certificate to trust for this client only, for example the self-signed
  /// certificate of one server.
  static http.Client newClient({String? extraPem}) {
    if (extraPem != null && extraPem.trim().isNotEmpty) {
      final context = SecurityContext(withTrustedRoots: true);
      for (final pem in [..._userPems, extraPem]) {
        try {
          context.setTrustedCertificatesBytes(utf8.encode(pem));
        } on TlsException {
          // Already trusted or unreadable, the others still apply
        }
      }
      return IOClient(HttpClient(context: context));
    }
    final context = _context;
    return context == null
        ? http.Client()
        : IOClient(HttpClient(context: context));
  }
}
