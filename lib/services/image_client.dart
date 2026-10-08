import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_http.dart';

/// Image generation through the /images/generations endpoint of an OpenAI-compatible API.
class ImageClient {
  /// Generates one image and saves it in the app documents folder. Returns the file path.
  static Future<String> generate({
    required String host,
    required String apiKey,
    required String model,
    required String prompt,
    String size = '1024x1024',
    http.Client? client,
    Directory? outputDir,
  }) async {
    final c = client ?? AppHttp.newClient();
    try {
      final body = <String, dynamic>{
        'model': model,
        'prompt': prompt,
        'n': 1,
        'size': size,
      };
      // DALL-E models need an explicit format, the gpt-image models always return base64
      if (model.startsWith('dall-e')) body['response_format'] = 'b64_json';

      final response = await c
          .post(
            Uri.parse(
              '${host.replaceAll(RegExp(r'/+$'), '')}/images/generations',
            ),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 3));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['data'];
      if (data is! List || data.isEmpty) {
        throw Exception('The server returned no image');
      }
      final item = data.first as Map;

      final List<int> bytes;
      if (item['b64_json'] is String) {
        bytes = base64Decode(
          (item['b64_json'] as String).replaceAll(RegExp(r'\s'), ''),
        );
      } else if (item['url'] is String) {
        final img = await c
            .get(Uri.parse(item['url'] as String))
            .timeout(const Duration(minutes: 1));
        if (img.statusCode != 200) {
          throw Exception(
            'Could not download the image (HTTP ${img.statusCode})',
          );
        }
        bytes = img.bodyBytes;
      } else {
        throw Exception('The server returned no image');
      }

      final dir =
          outputDir ??
          Directory(
            '${(await getApplicationDocumentsDirectory()).path}/images',
          );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      return file.path;
    } finally {
      if (client == null) c.close();
    }
  }
}
