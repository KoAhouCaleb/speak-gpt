import 'dart:typed_data';

import 'package:assistant/services/qr_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Draws a QR code with a quiet zone at the given position.
void drawQr(
  img.Image canvas,
  String text,
  int left,
  int top,
  int scale, {
  bool inverted = false,
}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final fg = inverted ? img.ColorRgb8(255, 255, 255) : img.ColorRgb8(0, 0, 0);
  final bg = inverted ? img.ColorRgb8(0, 0, 0) : img.ColorRgb8(255, 255, 255);
  final quiet = 4 * scale;
  img.fillRect(
    canvas,
    x1: left,
    y1: top,
    x2: left + matrix.width * scale + 2 * quiet,
    y2: top + matrix.height * scale + 2 * quiet,
    color: bg,
  );
  for (var x = 0; x < matrix.width; x++) {
    for (var y = 0; y < matrix.height; y++) {
      if (matrix.get(x, y) == 1) {
        img.fillRect(
          canvas,
          x1: left + quiet + x * scale,
          y1: top + quiet + y * scale,
          x2: left + quiet + (x + 1) * scale,
          y2: top + quiet + (y + 1) * scale,
          color: fg,
        );
      }
    }
  }
}

Uint8List png(img.Image image) => Uint8List.fromList(img.encodePng(image));

img.Image screen(int w, int h) {
  final canvas = img.Image(width: w, height: h, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(230, 235, 245));
  // Some text-like clutter so the picture is not trivially blank
  for (var i = 0; i < 20; i++) {
    img.fillRect(
      canvas,
      x1: 20,
      y1: 30 + i * 40,
      x2: 200 + (i * 37) % 300,
      y2: 42 + i * 40,
      color: img.ColorRgb8(90, 100, 120),
    );
  }
  return canvas;
}

void main() {
  test('reads a single code', () {
    final canvas = screen(800, 1000);
    drawQr(canvas, 'https://example.com/ticket/42', 300, 400, 4);
    expect(QrReader.readBytes(png(canvas)), ['https://example.com/ticket/42']);
  });

  test('reads several codes on one screen', () {
    final canvas = screen(900, 1400);
    drawQr(canvas, 'first-code', 40, 60, 3);
    drawQr(canvas, 'second-code', 560, 900, 3);
    expect(QrReader.readBytes(png(canvas)).toSet(), {
      'first-code',
      'second-code',
    });
  });

  test('reads a light code on a dark background', () {
    final canvas = screen(700, 700);
    drawQr(canvas, 'dark-mode', 200, 200, 4, inverted: true);
    expect(QrReader.readBytes(png(canvas)), ['dark-mode']);
  });

  test('returns nothing when there is no code', () {
    expect(QrReader.readBytes(png(screen(600, 600))), isEmpty);
  });

  test('returns nothing for data that is not a picture', () {
    expect(QrReader.readBytes(Uint8List.fromList([1, 2, 3])), isEmpty);
  });

  test('large screenshots are scaled down and still read', () {
    final canvas = screen(2400, 3200);
    drawQr(canvas, 'big-screen', 900, 1500, 12);
    expect(QrReader.readBytes(png(canvas)), ['big-screen']);
  });
}
