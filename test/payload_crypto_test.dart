import 'package:assistant/services/supersync/payload_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Produced by encrypt() of Super Productivity's own sync-core package (hash-wasm Argon2id).
const _password = 'correct horse battery staple';
const _fromSuperProductivity =
    '+7NUIlQQaYaLs9awkpO6a4oMrpFvgLREmjK3TtlNyfsMOKYG8P5ik4LD2WbK5aOhJjMgqDgZ8qA46x86wh33bCc0j1Ji5mVM65NUWUcuuBpNKsDT2KVbH6IQ5rM3Mg+uoe/GwUUkhgPs8NtFKlbNQ/lS9hTDZtmmLrk=';

void main() {
  test(
    'reads what Super Productivity encrypted',
    () async {
      final crypto = PayloadCrypto(_password);
      final clear = await crypto.decrypt(_fromSuperProductivity);
      expect(clear, contains('Grüße ✓'));
      expect(clear, contains('"entityChanges":[]'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a wrong password is reported', () async {
    final crypto = PayloadCrypto('not the password');
    expect(
      () => crypto.decrypt(_fromSuperProductivity),
      throwsA(isA<DecryptException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'round trip, deriving the key once per salt',
    () async {
      final crypto = PayloadCrypto(_password);
      final a = await crypto.encrypt('first');
      final b = await crypto.encrypt('second');
      expect(a, isNot(b));
      expect(await crypto.decrypt(a), 'first');
      expect(await crypto.decrypt(b), 'second');
      expect(crypto.derivations, 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
