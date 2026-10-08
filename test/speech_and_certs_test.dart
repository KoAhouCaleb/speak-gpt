import 'dart:convert';
import 'dart:io';

import 'package:assistant/models/models.dart';
import 'package:assistant/services/app_http.dart';
import 'package:assistant/services/speech_server_client.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/speech_servers_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _caPem = """-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIUXEVPS8K44w3j+U5fD+JOz6EyNvMwDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPVGVzdCBQcml2YXRlIENBMB4XDTI2MTAwODAwMjA0OFoX
DTM2MTAwNTAwMjA0OFowGjEYMBYGA1UEAwwPVGVzdCBQcml2YXRlIENBMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAt7lWttgRVfrutb/wr3euvPHu2bH0
DKhwWpg6aBYApp1rfBoHCmp6vSOsbemIbu84TtPT63KDVfiR9mchygnjxVIirgs6
52sF6iujyIFl8wfgkthCdWanRpUhvjGW9DiAP808eHjlZ53DNn2UYOiEZFqTwiqA
fmDhN9aXlUYR76TvYaGwuzBKymSAB1TbLEjm6rdip5hg+7y2l/kXTLNUIn1jXKcS
1RJICvnxZGRmto2Gy6Q4Xc5k1XDlV09Twmbl0FNm2IFKWD59WrM8C7ZMTsokT1VG
zRnsv26NwVLlYzqk6qML3EnmBqi6GCWaYM9oAQ0rctkC5j2bWs3t6724fwIDAQAB
o1MwUTAdBgNVHQ4EFgQULl6nRsFyuHJcHBkdLz13uw9GAxswHwYDVR0jBBgwFoAU
Ll6nRsFyuHJcHBkdLz13uw9GAxswDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAY4xvrO0CBpCH0y1bDMJrgjogA7XfiWCrDaBSpast4B9wvwYZpAM7
Y0dvdoBrUodlBm4bYD8s6JGvk7eo8ebW4Aw4LTvYTntlSC/1jBJva8GkUVIsC0oJ
s4zWPdlrNzkSZIa2+iMEhkv96vy2RmhsjKWh3bkak3ZFEHOHnxtpZgtB2rzMoR+J
o2Hvz8mkbNEqLCtkJ4d36pLiHiJh3ifMpLQay/6jB4ldIvu+ovb6PL1va/UcVD/B
77QoFG1BSSb796d9cKF5rhFC9eB5FwyF60BA2hns0CGPsrKn0MdR/xqVm1eWSvT4
poms0XPCRNtm0P7JpM8MtijlD4pBFSoN2Q==
-----END CERTIFICATE-----
""";

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('AppHttp user certificates', () {
    test('a user certificate authority is added to the trust store', () {
      expect(AppHttp.buildContext([_caPem]), isNotNull);
      expect(AppHttp.userCertificateCount, 1);
    });

    test('unreadable certificates are skipped without blocking the others', () {
      expect(AppHttp.buildContext(['not a certificate', _caPem]), isNotNull);
      expect(AppHttp.userCertificateCount, 1);
    });

    test('no certificates means the default client', () {
      expect(AppHttp.buildContext([]), isNull);
      expect(AppHttp.buildContext(['garbage']), isNull);
      expect(AppHttp.userCertificateCount, 0);
    });
  });

  group('SpeechServerClient', () {
    final config = SpeechServerConfig(
      enabled: true,
      host: 'http://192.168.1.2:8000/v1/',
      apiKey: 'k',
      model: 'qwen3-asr',
      voice: 'af_heart',
      language: 'en',
    );

    test('transcribe posts multipart audio with model and language', () async {
      final file = File('${Directory.systemTemp.path}/grace_test_audio.m4a')
        ..writeAsBytesSync([1, 2, 3, 4]);
      late http.BaseRequest seen;
      String? body;
      final client = MockClient((request) async {
        seen = request;
        body = latin1.decode(request.bodyBytes);
        return http.Response('{"text":" hello world "}', 200);
      });

      final text = await SpeechServerClient.transcribe(
        config,
        file,
        client: client,
      );

      expect(text, 'hello world');
      expect(
        seen.url.toString(),
        'http://192.168.1.2:8000/v1/audio/transcriptions',
      );
      expect(seen.headers['Authorization'], 'Bearer k');
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      expect(body, contains('name="model"'));
      expect(body, contains('qwen3-asr'));
      expect(body, contains('name="language"'));
      expect(body, contains('name="file"'));
      file.deleteSync();
    });

    test('transcribe accepts a plain text answer and reports errors', () async {
      final file = File('${Directory.systemTemp.path}/grace_test_audio2.m4a')
        ..writeAsBytesSync([1]);
      expect(
        await SpeechServerClient.transcribe(
          config,
          file,
          client: MockClient((r) async => http.Response('plain words', 200)),
        ),
        'plain words',
      );
      await expectLater(
        () => SpeechServerClient.transcribe(
          config,
          file,
          client: MockClient((r) async => http.Response('nope', 500)),
        ),
        throwsA(predicate((e) => '$e'.contains('HTTP 500'))),
      );
      file.deleteSync();
    });

    test('speak posts json and returns the audio bytes', () async {
      Map<String, dynamic>? sent;
      final client = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          request.url.toString(),
          'http://192.168.1.2:8000/v1/audio/speech',
        );
        return http.Response.bytes([9, 8, 7], 200);
      });

      final bytes = await SpeechServerClient.speak(
        config,
        'Hi there',
        client: client,
      );

      expect(bytes, [9, 8, 7]);
      expect(sent, {
        'input': 'Hi there',
        'voice': 'af_heart',
        'response_format': 'mp3',
        'model': 'qwen3-asr',
      });
    });

    test('voices accept strings, objects and a wrapped list', () async {
      Future<List<String>> voices(String body) => SpeechServerClient.listVoices(
        config,
        client: MockClient((r) async => http.Response(body, 200)),
      );

      expect(await voices('["a","b"]'), ['a', 'b']);
      expect(await voices('[{"id":"a"},{"name":"b"}]'), ['a', 'b']);
      expect(await voices('{"voices":["x"]}'), ['x']);
    });
  });

  testWidgets(
    'speech server settings are saved and the key stays out of plain preferences',
    (tester) async {
      final storage = Storage(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        ChangeNotifierProvider<Storage>.value(
          value: storage,
          child: const MaterialApp(home: SpeechServersScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL').first,
        'http://10.0.0.5:8000/v1/',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'API key (optional)').first,
        'secret',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final stt = storage.speechServer(Storage.speechStt);
      expect(stt.enabled, isTrue);
      expect(stt.host, 'http://10.0.0.5:8000/v1/');
      expect(stt.apiKey, 'secret');
      expect(stt.active, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getString('speech_server_stt'),
        isNot(contains('secret')),
      );
      expect(storage.speechServer(Storage.speechTts).active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
