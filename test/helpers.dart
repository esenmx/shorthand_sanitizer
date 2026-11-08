import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A fresh directory under the system temp directory, deleted after the test.
Directory tempDir(String name) {
  final dir = Directory.systemTemp.createTempSync('shorthand_$name');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

final _simplePubspec = RegExp(
  r'^name:\s*([a-zA-Z0-9_]+)\s*\nenvironment:\s*\n\s+sdk:\s*\^(\d+\.\d+)\.\d+\s*$',
);

/// A fresh package under the system temp directory holding [files] (paths
/// relative to its root, `/`-separated) beside a `^3.10.0` pubspec that
/// [files] may replace, deleted after the test. `dart pub get` runs unless
/// [pubGet] is false.
Directory fixture(
  String name,
  Map<String, String> files, {
  bool pubGet = true,
}) {
  final dir = tempDir(name);
  final all = {
    'pubspec.yaml': 'name: $name\nenvironment:\n  sdk: ^3.10.0\n',
    ...files,
  };
  for (final MapEntry(key: rel, value: source) in all.entries) {
    write(dir, rel, source);
  }
  if (pubGet) {
    final match = _simplePubspec.firstMatch(all['pubspec.yaml'] ?? '');
    final hasNestedPubspec = files.keys.any((k) => k.endsWith('/pubspec.yaml'));
    if (match != null && !hasNestedPubspec) {
      write(
        dir,
        '.dart_tool/package_config.json',
        '{\n'
            '  "configVersion": 2,\n'
            '  "packages": [\n'
            '    {\n'
            '      "name": "${match.group(1)}",\n'
            '      "rootUri": "../",\n'
            '      "packageUri": "lib/",\n'
            '      "languageVersion": "${match.group(2)}"\n'
            '    }\n'
            '  ]\n'
            '}\n',
      );
    } else {
      pubGetIn(dir.path);
    }
  }
  return dir;
}

/// Writes [source] to [rel] (`/`-separated) under [dir], creating parents.
File write(Directory dir, String rel, String source) =>
    File(p.joinAll([dir.path, ...rel.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);

/// `dart pub get` in [path], offline first.
void pubGetIn(String path) {
  final offline = Process.runSync('dart', [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: path);
  if (offline.exitCode == 0) return;
  final online = Process.runSync('dart', [
    'pub',
    'get',
  ], workingDirectory: path);
  if (online.exitCode != 0) {
    throw StateError('pub get failed: ${online.stderr}');
  }
}

String canonical(String path) => p.normalize(p.absolute(path));

final String _cliSnapshot = () {
  final dill = File(p.absolute('.dart_tool/shorthand_test.dill'));
  final sources = [
    File('pubspec.yaml'),
    File('bin/shorthand.dart'),
    ...Directory('lib').listSync(recursive: true).whereType<File>(),
  ];
  final newestSource = sources
      .map((f) => f.lastModifiedSync())
      .reduce((a, b) => a.isAfter(b) ? a : b);
  if (!dill.existsSync() || dill.lastModifiedSync().isBefore(newestSource)) {
    final tmp = File('${dill.path}.$pid.tmp');
    final compile = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/shorthand.dart',
      '-o',
      tmp.path,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('kernel compile failed: ${compile.stderr}');
    }
    try {
      tmp.renameSync(dill.path);
    } on FileSystemException {
      if (!dill.existsSync()) rethrow;
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }
  return dill.path;
}();

/// The `shorthand` CLI from this repo, run in [cwd] (default: the repo root).
/// It writes UTF-8; the default decoding is the system code page, which is not
/// UTF-8 on Windows (the warning's `—` came back as `â€”`).
ProcessResult shorthand(
  List<String> args, {
  String? cwd,
  Map<String, String>? environment,
}) => Process.runSync(
  Platform.resolvedExecutable,
  [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    _cliSnapshot,
    ...args,
  ],
  workingDirectory: cwd,
  environment: environment,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);
