import 'dart:typed_data';

/// Packs mono samples between -1 and 1 into a 16 bit PCM WAV file.
Uint8List encodeWav(List<double> samples, {int sampleRate = 16000}) {
  final dataSize = samples.length * 2;
  final bytes = ByteData(44 + dataSize);

  void tag(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // size of the format chunk
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, 1, Endian.little); // mono
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little); // bytes per second
  bytes.setUint16(32, 2, Endian.little); // bytes per frame
  bytes.setUint16(34, 16, Endian.little); // bits per sample
  tag(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final value = (samples[i] * 32768).round().clamp(-32768, 32767);
    bytes.setInt16(44 + i * 2, value, Endian.little);
  }
  return bytes.buffer.asUint8List();
}
