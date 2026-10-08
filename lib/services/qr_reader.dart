import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Finds QR codes in a picture and returns the text of each one.
///
/// The ZXing port used here reads one code per image, so besides the whole picture
/// it also reads overlapping tiles. That finds several codes on a busy screenshot
/// and small codes that the whole-picture pass misses.
class QrReader {
  /// Pictures larger than this are scaled down first, screenshots do not need more.
  static const maxSide = 2000;

  /// Reads a picture file in a background isolate.
  static Future<List<String>> readFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return Isolate.run(() => readBytes(bytes));
  }

  /// Synchronous version, call it from a background isolate for large pictures.
  static List<String> readBytes(Uint8List bytes) {
    img.Image? image;
    try {
      image = img.decodeImage(bytes);
    } catch (_) {
      // Corrupt data makes the decoder throw instead of returning null
      return const [];
    }
    if (image == null) return const [];

    final longSide = image.width > image.height ? image.width : image.height;
    if (longSide > maxSide) {
      final scale = maxSide / longSide;
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
      );
    }

    final found = <String>{};

    // Whole picture, then tiles. A tile boundary can cut a code, hence the overlap.
    for (final region in _regions(image.width, image.height)) {
      final tile = region == null
          ? image
          : img.copyCrop(
              image,
              x: region.x,
              y: region.y,
              width: region.w,
              height: region.h,
            );
      final text = _decode(tile);
      if (text != null) found.add(text);
    }

    return found.toList();
  }

  static Iterable<({int x, int y, int w, int h})?> _regions(
    int width,
    int height,
  ) sync* {
    yield null;
    for (final grid in const [2, 3]) {
      // Tiles cover 1/grid of the side plus 50% overlap on each inner edge
      final tileW = (width / grid * 1.5).round().clamp(1, width);
      final tileH = (height / grid * 1.5).round().clamp(1, height);
      for (var gy = 0; gy < grid; gy++) {
        for (var gx = 0; gx < grid; gx++) {
          final x = grid == 1 ? 0 : ((width - tileW) * gx / (grid - 1)).round();
          final y = grid == 1
              ? 0
              : ((height - tileH) * gy / (grid - 1)).round();
          yield (x: x, y: y, w: tileW, h: tileH);
        }
      }
    }
  }

  static String? _decode(img.Image image) {
    final rgba = image.convert(numChannels: 4);
    final pixels = rgba
        .getBytes(order: img.ChannelOrder.abgr)
        .buffer
        .asInt32List();
    final source = RGBLuminanceSource(image.width, image.height, pixels);
    final hints = DecodeHints()..put(DecodeHintType.tryHarder);

    // The hybrid binarizer suits most screens, the global one low contrast codes.
    // Light codes on a dark background need the inverted source.
    final attempts = <LuminanceSource>[source, InvertedLuminanceSource(source)];
    for (final s in attempts) {
      for (final binarizer in [
        HybridBinarizer(s),
        GlobalHistogramBinarizer(s),
      ]) {
        try {
          return QRCodeReader()
              .decode(BinaryBitmap(binarizer), hints: hints)
              .text;
        } on ReaderException {
          // Nothing found with this combination, try the next
        }
      }
    }
    return null;
  }
}
