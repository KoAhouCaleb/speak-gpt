import 'package:assistant/services/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [text] to a splitter one character at a time, like a streamed answer.
List<String> streamed(String text) {
  final splitter = SentenceSplitter();
  final out = <String>[];
  for (var i = 1; i <= text.length; i++) {
    out.addAll(splitter.update(text.substring(0, i)));
  }
  out.addAll(splitter.finish(text));
  return out;
}

void main() {
  group('sanitize', () {
    test(
      'plain text is kept',
      () => expect(SpeechText.sanitize('Hello there.'), 'Hello there.'),
    );

    test('markdown is removed', () {
      expect(SpeechText.sanitize('## Title'), 'Title');
      expect(
        SpeechText.sanitize('This is **bold**, _italic_ and `code`.'),
        'This is bold, italic and code.',
      );
      expect(
        SpeechText.sanitize('See [the docs](https://example.com/x) now'),
        'See the docs now',
      );
      expect(SpeechText.sanitize('![a cat](cat.png) sits'), 'a cat sits');
      expect(SpeechText.sanitize('> quoted words'), 'quoted words');
      expect(SpeechText.sanitize('- one'), 'one');
      expect(SpeechText.sanitize('3) three'), 'three');
    });

    test('urls, code blocks and html are dropped', () {
      expect(
        SpeechText.sanitize('Go to https://example.com/page please'),
        'Go to please',
      );
      expect(
        SpeechText.sanitize('Run:\n```bash\nrm -rf /\n```\nDone'),
        'Run: Done',
      );
      expect(
        SpeechText.sanitize('An <b>important</b> point'),
        'An important point',
      );
    });

    test(
      'underscores inside words stay',
      () => expect(
        SpeechText.sanitize('use snake_case names'),
        'use snake_case names',
      ),
    );

    test('nothing speakable gives an empty string', () {
      expect(SpeechText.sanitize('---'), '');
      expect(SpeechText.sanitize('```\ncode only\n```'), '');
      expect(SpeechText.sanitize('  ...  '), '');
    });

    test('tables become comma separated', () {
      expect(
        SpeechText.sanitize('| a | b |\n|---|---|\n| 1 | 2 |'),
        contains('a, b'),
      );
    });
  });

  group('SentenceSplitter', () {
    test('splits at sentence punctuation followed by whitespace', () {
      expect(streamed('Hello there. How are you? Fine!'), [
        'Hello there.',
        'How are you?',
        'Fine!',
      ]);
    });

    test('a sentence is released as soon as the next character arrives', () {
      final s = SentenceSplitter();
      expect(
        s.update('Hello there.'),
        isEmpty,
      ); // may continue as "3.14" or "..."
      expect(s.update('Hello there. '), ['Hello there.']);
    });

    test('decimal numbers and ellipses are not boundaries', () {
      expect(streamed('Pi is 3.14 roughly. Next'), [
        'Pi is 3.14 roughly.',
        'Next',
      ]);
      // an ellipsis followed by a space is a pause, so it ends the sentence
      expect(streamed('Wait... what? Yes'), ['Wait...', 'what?', 'Yes']);
      expect(streamed('Version 1.2.3 is out. Ok'), [
        'Version 1.2.3 is out.',
        'Ok',
      ]);
    });

    test('abbreviations and initials do not end a sentence', () {
      expect(streamed('Ask Dr. Who about it. Then go.'), [
        'Ask Dr. Who about it.',
        'Then go.',
      ]);
      expect(streamed('Written by J. Smith today. Fine.'), [
        'Written by J. Smith today.',
        'Fine.',
      ]);
      expect(streamed('Use fruit, e.g. apples. Good.'), [
        'Use fruit, e.g. apples.',
        'Good.',
      ]);
    });

    test('numbered list markers do not end a sentence', () {
      expect(streamed('Steps:\n1. Open the app\n2. Press start\n'), [
        'Steps:',
        'Open the app',
        'Press start',
      ]);
    });

    test('line breaks end a sentence', () {
      expect(streamed('First line\nSecond line\n'), [
        'First line',
        'Second line',
      ]);
    });

    test('code blocks are never split and are removed as a whole', () {
      expect(
        streamed('Try this. ```py\nprint("a. b")\nx = 1\n``` Then rest.'),
        ['Try this.', 'Then rest.'],
      );
    });

    test('the unterminated tail is released by finish', () {
      final s = SentenceSplitter();
      expect(s.update('One. Two without end'), ['One.']);
      expect(s.finish('One. Two without end'), ['Two without end']);
    });

    test('rewritten text starts over instead of repeating', () {
      final s = SentenceSplitter();
      expect(s.update('First one. Second '), ['First one.']);
      // the visible text changed at the start (for example a think block was removed)
      expect(s.update('Different start. Second '), ['Different start.']);
      expect(s.finish('Different start. Second sentence'), ['Second sentence']);
    });

    test('CJK punctuation ends a sentence', () {
      // the splitter waits for whitespace after the punctuation, so it needs a space
      expect(streamed('你好。 再见 '), ['你好。', '再见']);
    });

    test('closing quotes stay with the sentence', () {
      expect(streamed('He said "stop." Then left.'), [
        'He said "stop."',
        'Then left.',
      ]);
    });

    test('every sentence is produced exactly once for any chunking', () {
      const text = 'One. Two! Three? Four five.\nSix\n- seven. Eight.';
      final whole = SentenceSplitter().finish(text);
      expect(streamed(text), whole);
    });
  });
}
