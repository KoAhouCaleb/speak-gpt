import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Folder for pictures that belong to chats (sent, attached, generated).
Future<Directory> imagesDirectory() async {
  final dir = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/images',
  );
  await dir.create(recursive: true);
  return dir;
}

/// Copies a picture from a temporary location into the app's permanent images folder.
Future<String> persistImage(String path, {Directory? into}) async {
  final dir = into ?? await imagesDirectory();
  final ext = path.contains('.')
      ? path.substring(path.lastIndexOf('.'))
      : '.jpg';
  final target = File(
    '${dir.path}/img_${DateTime.now().microsecondsSinceEpoch}$ext',
  );
  await File(path).copy(target.path);
  return target.path;
}

/// Removes Markdown so a speech engine does not read out symbols.
String plainTextForSpeech(String markdown) {
  var t = markdown;
  t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' code block. ');
  t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  t = t.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'[*_`>~|]'), '');
  t = t.replaceAll(RegExp(r'\n{2,}'), '. ');
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  return t.trim();
}

/// Plain-text transcript of a chat, used for sharing.
String transcript(
  String title,
  Iterable<({bool isBot, String text})> messages,
  String assistantName,
) {
  final b = StringBuffer('$title\n\n');
  for (final m in messages) {
    b.writeln('${m.isBot ? assistantName : 'You'}:');
    b.writeln(m.text);
    b.writeln();
  }
  return b.toString().trim();
}
