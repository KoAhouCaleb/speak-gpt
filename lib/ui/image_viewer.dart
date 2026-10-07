import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image'),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => Share.shareXFiles([XFile(path)]),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(maxScale: 6, child: Image.file(File(path))),
      ),
    );
  }
}
