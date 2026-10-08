/// Text helpers for speech synthesis: Markdown stripping and sentence splitting.
class SpeechText {
  SpeechText._();

  static final _fencedBlock = RegExp(r'```[\s\S]*?(```|$)');
  static final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
  static final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
  static final _url = RegExp(r'https?://\S+');
  static final _htmlTag = RegExp(r'</?[a-zA-Z][^>]*>');
  static final _heading = RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true);
  static final _blockquote = RegExp(r'^\s*(>\s*)+', multiLine: true);
  static final _horizontalRule = RegExp(
    r'^\s*([-*_])(\s*\1){2,}\s*$',
    multiLine: true,
  );
  static final _tableSeparator = RegExp(
    r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$',
    multiLine: true,
  );
  static final _listMarker = RegExp(r'^\s*([-*+]|\d+[.)])\s+', multiLine: true);
  static final _taskMarker = RegExp(r'^\s*\[[ xX]\]\s+', multiLine: true);
  static final _tablePipe = RegExp(r'\s*\|\s*');
  static final _emphasis = RegExp(r'[*~]+');
  static final _underscore = RegExp(
    r'(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])',
    unicode: true,
  );
  static final _latexDelimiter = RegExp(r'\\[()\[\]]');
  static final _whitespace = RegExp(r'\s+');
  static final _edgeSeparators = RegExp(r'^[,\s]+|[,\s]+$');
  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static const _sentenceEnd = {'.', '!', '?', '。', '！', '？'};
  static const _closers = {'"', "'", ')', ']', '*', '_', '`', '”', '’'};
  static const _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'dr',
    'st',
    'jr',
    'sr',
    'vs',
    'etc',
    'e.g',
    'i.e',
    'approx',
    'no',
    'fig',
  };

  /// Removes Markdown and other formatting so that only speakable text remains.
  /// Returns an empty string when nothing speakable is left.
  static String sanitize(String text) {
    var s = text;
    s = s.replaceAll(_fencedBlock, ' ');
    s = s.replaceAllMapped(_image, (m) => m[1]!);
    s = s.replaceAllMapped(_link, (m) => m[1]!);
    s = s.replaceAll(_url, ' ');
    s = s.replaceAll(_htmlTag, ' ');
    s = s.replaceAll(_horizontalRule, ' ');
    s = s.replaceAll(_tableSeparator, ' ');
    s = s.replaceAll(_heading, '');
    s = s.replaceAll(_blockquote, '');
    s = s.replaceAll(_listMarker, '');
    s = s.replaceAll(_taskMarker, '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(_tablePipe, ', ');
    s = s.replaceAll(_emphasis, '');
    s = s.replaceAll(_underscore, '');
    s = s.replaceAll(_latexDelimiter, ' ');
    s = s.replaceAll(_whitespace, ' ');
    s = s.replaceAll(_edgeSeparators, '');
    return _letterOrDigit.hasMatch(s) ? s : '';
  }
}

/// Incrementally splits a growing (streamed) response into sentences.
///
/// Sentences end at a line break or at sentence punctuation followed by whitespace. Fenced code
/// blocks are never split, so they can be removed as a whole by [SpeechText.sanitize].
class SentenceSplitter {
  String _text = '';
  int _consumed = 0;

  /// [fullText] is the whole response received so far. Returns the sanitized sentences that
  /// were completed since the previous call.
  List<String> update(String fullText) {
    // The response was rewritten (for example by a late closing think tag), start over
    if (_consumed > fullText.length ||
        fullText.substring(0, _consumed) != _text.substring(0, _consumed)) {
      _consumed = 0;
    }
    _text = fullText;

    final sentences = <String>[];
    var start = _consumed;
    var inFence = false;
    var i = _consumed;

    while (i < _text.length) {
      if (_text.startsWith('```', i)) {
        inFence = !inFence;
        i += 3;
        continue;
      }

      if (!inFence) {
        final end = _boundaryAt(i);
        if (end != -1) {
          _add(sentences, _text.substring(start, end));
          start = end;
          i = end;
          continue;
        }
      }

      i++;
    }

    _consumed = start;
    return sentences;
  }

  /// [fullText] is the complete response. Returns the remaining sanitized sentences,
  /// including the unterminated tail.
  List<String> finish(String fullText) {
    final sentences = update(fullText);
    _add(sentences, _text.substring(_consumed));
    _consumed = _text.length;
    return sentences;
  }

  void _add(List<String> sentences, String chunk) {
    final clean = SpeechText.sanitize(chunk);
    if (clean.isNotEmpty) sentences.add(clean);
  }

  /// Exclusive end index of the sentence that ends at [i], or -1 if [i] is not a boundary.
  int _boundaryAt(int i) {
    final c = _text[i];
    if (c == '\n') return i + 1;
    if (!SpeechText._sentenceEnd.contains(c)) return -1;

    var j = i + 1;
    while (j < _text.length &&
        (SpeechText._sentenceEnd.contains(_text[j]) ||
            SpeechText._closers.contains(_text[j]))) {
      j++;
    }

    // Wait for the next character, the response may continue with "3.14" or "..."
    if (j >= _text.length) return -1;
    if (!_isWhitespace(_text[j])) return -1;

    if (c == '.' && _isNotSentenceEnd(i)) return -1;

    return j;
  }

  static bool _isWhitespace(String ch) => ch.trim().isEmpty;

  bool _isNotSentenceEnd(int dot) {
    var k = dot - 1;
    while (k >= 0 && !_isWhitespace(_text[k])) {
      k--;
    }
    var word = _text.substring(k + 1, dot);
    word = word.replaceFirst(RegExp(r'''^[("'*_]+'''), '').toLowerCase();

    // "1. Item" list markers at the start of a line
    if (word.isNotEmpty && RegExp(r'^\d+$').hasMatch(word)) {
      final lineStart = _text.lastIndexOf('\n', dot) + 1;
      if (_text.substring(lineStart, dot).trim() == word) return true;
    }

    // Initials and common abbreviations ("J. Smith", "Dr. Who", "e.g. this")
    return (word.length == 1 &&
            RegExp(r'\p{L}', unicode: true).hasMatch(word)) ||
        SpeechText._abbreviations.contains(word);
  }
}
