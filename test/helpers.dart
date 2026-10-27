import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A fresh directory under the system temp directory, deleted after the test.
Directory tempDir(String name) {
  final dir = Directory.systemTemp.createTempSync('dotsan_$name');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

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
  if (pubGet) pubGetIn(dir.path);
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

/// dotsan from this repo, run in [cwd] (default: the repo root). dotsan writes
/// UTF-8; the default decoding is the system code page, which is not UTF-8 on
/// Windows (the warning's `—` came back as `â€”`).
ProcessResult dotsan(
  List<String> args, {
  String? cwd,
  Map<String, String>? environment,
}) => Process.runSync(
  Platform.resolvedExecutable,
  [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    p.absolute('bin/dotsan.dart'),
    ...args,
  ],
  workingDirectory: cwd,
  environment: environment,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);
