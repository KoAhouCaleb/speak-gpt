import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Parameters the Super Productivity apps use to derive the key from the sync password. They
/// are part of the data format and must not be changed.
const argon2Memory = 65536; // KiB
const argon2Iterations = 3;
const argon2Parallelism = 1;
const _saltLength = 16;
const _ivLength = 12;
const _tagLength = 16;
const _keyLength = 32;

class DecryptException implements Exception {
  @override
  String toString() =>
      'A payload could not be decrypted. The encryption password is probably wrong.';
}

Future<List<int>> _deriveKey(
  String password,
  Uint8List salt,
  int memory,
  int iterations,
) => Isolate.run(() async {
  final argon = Argon2id(
    memory: memory,
    parallelism: argon2Parallelism,
    iterations: iterations,
    hashLength: _keyLength,
  );
  final key = await argon.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  return key.extractBytes();
});

/// Encrypts and decrypts operation payloads the way Super Productivity does:
/// base64 of `[salt 16][iv 12][AES-256-GCM ciphertext and tag]`, with the key derived from the
/// password and the salt by Argon2id.
///
/// Every payload carries its own salt. Deriving a key takes a second or more, so the keys are
/// kept per salt.
class PayloadCrypto {
  PayloadCrypto(
    this.password, {
    this.memory = argon2Memory,
    this.iterations = argon2Iterations,
  });

  final String password;
  final int memory;
  final int iterations;

  final Map<String, List<int>> _keys = {};
  Uint8List? _ownSalt;
  final _aes = AesGcm.with256bits();

  /// Number of key derivations done so far, for diagnostics and tests.
  int derivations = 0;

  Future<List<int>> _keyFor(Uint8List salt) async {
    final id = base64.encode(salt);
    final known = _keys[id];
    if (known != null) return known;
    derivations++;
    return _keys[id] = await _deriveKey(password, salt, memory, iterations);
  }

  Future<String> decrypt(String payload) async {
    final bytes = base64.decode(payload);
    if (bytes.length < _saltLength + _ivLength + _tagLength) {
      throw DecryptException();
    }
    final salt = Uint8List.sublistView(bytes, 0, _saltLength);
    final iv = bytes.sublist(_saltLength, _saltLength + _ivLength);
    final rest = bytes.sublist(_saltLength + _ivLength);
    final key = await _keyFor(Uint8List.fromList(salt));
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          rest.sublist(0, rest.length - _tagLength),
          nonce: iv,
          mac: Mac(rest.sublist(rest.length - _tagLength)),
        ),
        secretKey: SecretKey(key),
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw DecryptException();
    }
  }

  /// Decrypts many payloads, deriving each distinct key only once.
  Future<List<String>> decryptAll(List<String> payloads) async {
    final out = <String>[];
    for (final p in payloads) {
      out.add(await decrypt(p));
    }
    return out;
  }

  Future<String> encrypt(String text) async {
    final random = Random.secure();
    final salt = _ownSalt ??= Uint8List.fromList(
      List.generate(_saltLength, (_) => random.nextInt(256)),
    );
    final key = await _keyFor(salt);
    final iv = List.generate(_ivLength, (_) => random.nextInt(256));
    final box = await _aes.encrypt(
      utf8.encode(text),
      secretKey: SecretKey(key),
      nonce: iv,
    );
    return base64.encode([...salt, ...iv, ...box.cipherText, ...box.mac.bytes]);
  }
}
