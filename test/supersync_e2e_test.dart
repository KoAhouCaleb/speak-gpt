@Tags(['e2e'])
library;

import 'dart:io';

import 'package:assistant/services/supersync/payload_crypto.dart';
import 'package:assistant/services/supersync/supersync_client.dart';
import 'package:assistant/services/supersync/supersync_tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// Runs against a real SuperSync server, started by hand:
//   SUPERSYNC_E2E_URL=http://localhost:1900 SUPERSYNC_E2E_TOKEN=... SUPERSYNC_E2E_PASSWORD=...
//   flutter test test/supersync_e2e_test.dart
// The account must hold the data from the seed script. Skipped when the variables are unset.
final _url = Platform.environment['SUPERSYNC_E2E_URL'];
final _token = Platform.environment['SUPERSYNC_E2E_TOKEN'];
final _password = Platform.environment['SUPERSYNC_E2E_PASSWORD'];

void main() {
  final skip = (_url == null || _token == null || _password == null)
      ? 'SUPERSYNC_E2E_* variables are not set'
      : null;

  SuperSyncTasks service(
    Directory dir,
    String clientId,
    PayloadCrypto crypto,
  ) => SuperSyncTasks(
    client: SuperSyncClient(
      url: _url!,
      token: _token!,
      clientId: clientId,
      clientFactory: () => http.Client(),
    ),
    cacheFile: File('${dir.path}/$clientId.json'),
    crypto: crypto,
  );

  test(
    'reads, writes and deletes tasks on a real server',
    () async {
      final dir = Directory.systemTemp.createTempSync('supersync_e2e');
      addTearDown(() => dir.deleteSync(recursive: true));
      final crypto = PayloadCrypto(_password!);
      final grace = service(dir, 'Grace_e2e', crypto);

      final open = await grace.list();
      final titles = open.map((t) => t.title).toList();
      expect(
        titles,
        containsAll(['Buy oat milk', 'Write report', 'Call dentist']),
      );
      final report = open.firstWhere((t) => t.title == 'Write report');
      expect(report.projectTitle, 'Work');
      expect(report.notes, 'quarterly');
      expect(report.due, DateTime(2026, 10, 8));

      final added = await grace.add(
        'Pay rent',
        project: 'work',
        dueWithTime: DateTime(2026, 10, 10, 9, 30),
        notes: 'from Grace',
      );
      expect(added.projectTitle, 'Work');

      // A second device with an empty cache sees the new task
      final other = service(dir, 'Grace_e2e_other', crypto);
      final seen = (await other.list()).firstWhere(
        (t) => t.title == 'Pay rent',
      );
      expect(seen.due, DateTime(2026, 10, 10, 9, 30));
      expect(seen.notes, 'from Grace');

      await grace.update(await grace.find(title: 'Buy oat milk'), isDone: true);
      expect(
        (await other.list()).map((t) => t.title),
        isNot(contains('Buy oat milk')),
      );
      expect(
        (await other.list(includeDone: true)).map((t) => t.title),
        contains('Buy oat milk'),
      );

      await grace.update(seen, title: 'Pay the rent', dueDay: '2026-10-11');
      final renamed = await other.find(title: 'Pay the rent');
      expect(renamed.due, DateTime(2026, 10, 11));
      expect(renamed.dueHasTime, isFalse);

      await grace.delete(renamed);
      expect(
        (await other.list(includeDone: true)).map((t) => t.title),
        isNot(contains('Pay the rent')),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
