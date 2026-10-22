part of 'sanitizer.dart';

final _generatedMarker = RegExp(
  r'\b(auto[-\s]?generated|generated\s+(code|file|by))\b',
  caseSensitive: false,
);

/// [_generatedMarker] opening a doc comment's text.
final _docMarker = RegExp(
  r'^(auto[-\s]?generated|generated\s+(code|file|by))\b',
  caseSensitive: false,
);

/// Generated-code filter: the file's leading comment says so (build_runner,
/// FlutterFire, pigeon, protoc, slang). Filename shape (`*.g.dart` vs a
/// handwritten `*.preview.dart`) proves nothing, the header does.
bool _isGeneratedFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return false;
  final RandomAccessFile raf;
  try {
    raf = file.openSync();
  } on FileSystemException {
    return false;
  }
  try {
    var chunk = 4096;
    final bytes = <int>[];
    var eof = false;
    var text = '';
    void readMore() {
      if (eof) return;
      final next = raf.readSync(chunk);
      if (next.length < chunk) eof = true;
      chunk *= 2;
      bytes.addAll(next);
      final raw = utf8.decode(bytes, allowMalformed: true);
      text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    }

    readMore();
    String lineFrom(int start) {
      var end = text.indexOf('\n', start);
      while (end == -1 && !eof) {
        readMore();
        end = text.indexOf('\n', start);
      }
      return text.substring(start, end == -1 ? text.length : end);
    }

    int blockClose(int start) {
      var close = text.indexOf('*/', start);
      while (close == -1 && !eof) {
        readMore();
        close = text.indexOf('*/', start);
      }
      return close;
    }

    var i = 0;
    while (true) {
      while (true) {
        if (i + 4 > text.length && !eof) readMore();
        if (i < text.length && text[i].trim().isEmpty) {
          i++;
        } else {
          break;
        }
      }
      if (text.startsWith('///', i)) {
        return _docMarker.hasMatch(lineFrom(i).substring(3).trimLeft());
      }
      if (text.startsWith('/**', i) && !text.startsWith('/**/', i)) {
        final close = blockClose(i + 3);
        final body = text.substring(i + 3, close == -1 ? text.length : close);
        return _docMarker.hasMatch(body.replaceFirst(RegExp(r'^[\s*]*'), ''));
      }
      if (text.startsWith('//', i) || text.startsWith('#', i)) {
        final line = lineFrom(i);
        if (_generatedMarker.hasMatch(line)) return true;
        i += line.length;
        continue;
      }
      if (text.startsWith('/*', i)) {
        final close = blockClose(i + 2);
        final body = text.substring(i + 2, close == -1 ? text.length : close);
        if (_generatedMarker.hasMatch(body)) return true;
        if (close == -1) return false;
        i = close + 2;
        continue;
      }
      return false;
    }
  } finally {
    raf.closeSync();
  }
}
