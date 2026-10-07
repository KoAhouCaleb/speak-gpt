import 'dart:io';

import 'package:flutter/material.dart';

import '../util.dart';
import 'dialogs.dart';
import 'image_viewer.dart';

/// Grid of every picture stored by the app: generated, attached and screenshots.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  late Future<List<File>> _files = _load();

  Future<List<File>> _load() async {
    final dir = await imagesDirectory();
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Images')),
      body: FutureBuilder<List<File>>(
        future: _files,
        builder: (context, snapshot) {
          final files = snapshot.data;
          if (files == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (files.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No images yet. Use /imagine in a chat to create one.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: files.length,
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImageViewerScreen(path: files[i].path),
                ),
              ),
              onLongPress: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete image',
                  message:
                      'Delete this image? Chats that show it will lose the picture.',
                );
                if (ok) {
                  await files[i].delete();
                  setState(() => _files = _load());
                }
              },
              child: Image.file(files[i], fit: BoxFit.cover, cacheWidth: 400),
            ),
          );
        },
      ),
    );
  }
}
