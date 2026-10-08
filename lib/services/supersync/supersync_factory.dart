import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../storage.dart';
import 'payload_crypto.dart';
import 'supersync_client.dart';
import 'supersync_tasks.dart';

SuperSyncTasks? _cached;
String? _cachedFor;

/// The task service for the server in the settings. The same instance is reused while the
/// settings stay the same, so its keys and its cache are not rebuilt for every tool call.
Future<SuperSyncTasks> superSyncTasksFor(
  Storage storage, {
  Directory? dir,
}) async {
  if (!storage.supersyncConfigured) {
    throw SuperSyncException(
      'The task server is not set up. Enter its address, access token and encryption password in Settings > Tools.',
    );
  }
  final signature = [
    storage.supersyncUrl,
    storage.supersyncToken,
    storage.supersyncPassword,
    storage.supersyncCertificate,
    storage.supersyncClientId,
  ].join('\u0000');
  if (_cached != null && _cachedFor == signature) return _cached!;

  final base = dir ?? await getApplicationSupportDirectory();
  final service = SuperSyncTasks(
    client: SuperSyncClient(
      url: storage.supersyncUrl,
      token: storage.supersyncToken,
      clientId: storage.supersyncClientId,
      certificate: storage.supersyncCertificate,
    ),
    cacheFile: File(
      '${base.path}/${supersyncCacheName(storage.supersyncUrl, storage.supersyncClientId)}',
    ),
    crypto: storage.supersyncPassword.isEmpty
        ? null
        : PayloadCrypto(storage.supersyncPassword),
  );
  _cached = service;
  _cachedFor = signature;
  return service;
}
