import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory pkg;

void main() {
  setUpAll(() {
    pkg = Directory.systemTemp.createTempSync('dotsan_cli_test');
    Directory(p.join(pkg.path, 'lib')).createSync();
    // Floor below 3.10 so the run exercises the warning path.
    const spec = 'name: floor_fixture\nenvironment:\n  sdk: ^3.0.0\n';
    File(p.join(pkg.path, 'pubspec.yaml')).writeAsStringSync(spec);
    File(p.join(pkg.path, 'lib', 'main.dart')).writeAsStringSync('''
enum Fit { cover, contain }
void main() {
  Fit f = Fit.cover;
  print(f);
}
''');
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: pkg.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
  });

  tearDownAll(() => pkg.deleteSync(recursive: true));

  test('--explain lists kept sites after the converted ones', () {
    final file = explainFixture();
    final run = dotsan(['--dry-run', '--explain', file.parent.path]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(
      run.stdout,
      '${p.normalize(p.absolute(file.path))}\n'
      '  4: Fit.cover -> .cover\n'
      '  3: Fit.contain kept: no context type\n'
      'would convert 1 site(s) in 1 file(s), 1 kept\n',
    );
  });

  test('piped streams carry only the report and plain warning', () {
    // Full-string equality is the oracle: piped stdout is the parseable
    // report, so no progress/spinner text and no ANSI codes may leak into
    // either stream when they are not terminals.
    final run = dotsan(['--dry-run', p.join(pkg.path, 'lib')]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stdout, 'would convert 0 site(s) in 0 file(s)\n');
    final root = p.normalize(p.absolute(pkg.path));
    expect(
      run.stderr,
      'warning: skipped 1 file(s) in $root at language version 3.0 — dot '
      'shorthands need 3.10. Raise `environment: sdk:` in '
      '${p.join(root, 'pubspec.yaml')} (or drop a `// @dart=` override); the '
      'installed SDK does not decide this.\n',
    );
  });

  group('SS-G1 --set-exit-if-changed', () {
    test('a dry run that would convert exits 1 and writes nothing', () {
      final file = explainFixture();
      final before = file.readAsStringSync();
      final run = dotsan(['-n', '--set-exit-if-changed', file.parent.path]);
      expect(run.exitCode, 1, reason: '${run.stderr}');
      expect(file.readAsStringSync(), before);
    });

    test('a run with nothing to convert exits 0', () {
      final run = dotsan([
        '-n',
        '--set-exit-if-changed',
        p.join(pkg.path, 'lib'),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    });

    test('a real run exits 1 and still writes', () {
      final file = explainFixture();
      final run = dotsan(['--set-exit-if-changed', file.parent.path]);
      expect(run.exitCode, 1, reason: '${run.stderr}');
      expect(file.readAsStringSync(), contains('Fit f = .cover;'));
    });
  });

  test('SS-G3 --format=json prints the report as one JSON document', () {
    final file = explainFixture();
    final run = dotsan(['-n', '--explain', '--format=json', file.parent.path]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stderr, isEmpty);
    expect(jsonDecode(run.stdout as String), {
      'dryRun': true,
      'converted': 1,
      'kept': 1,
      'skipListed': 0,
      'removedImports': 0,
      'files': [
        {
          'path': p.normalize(p.absolute(file.path)),
          'removedImports': 0,
          'sites': [
            {
              'line': 3,
              'column': 19,
              'before': 'Fit.contain',
              'after': null,
              'keptReason': 'no context type',
            },
            {
              'line': 4,
              'column': 11,
              'before': 'Fit.cover',
              'after': '.cover',
              'keptReason': null,
            },
          ],
        },
      ],
    });
  });

  test('SS-B10 a path that does not exist is an error, not a no-op', () {
    final run = dotsan(['-n', 'lib/does_not_exist.dart']);
    expect(run.exitCode, 64);
    expect(run.stderr, contains('does_not_exist'));
  });

  test('SS-B11 an invalid --exclude glob is a usage error (exit 64)', () {
    final run = dotsan(['-n', 'lib', '--exclude=[']);
    expect(run.exitCode, 64);
    expect(run.stderr, isNot(contains('Unhandled exception')));
  });

  test('SS-M4 file lines are relative to the working directory', () {
    final fixture = Directory.systemTemp.createTempSync('dotsan_relative');
    addTearDown(() => fixture.deleteSync(recursive: true));
    Directory(p.join(fixture.path, 'lib')).createSync();
    const spec = 'name: relative_fixture\nenvironment:\n  sdk: ^3.10.0\n';
    File(p.join(fixture.path, 'pubspec.yaml')).writeAsStringSync(spec);
    File(p.join(fixture.path, 'lib', 'main.dart')).writeAsStringSync('''
enum Fit { cover, contain }
void main() {
  Fit f = Fit.cover;
  print(f);
}
''');
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: fixture.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');

    final run = Process.runSync(Platform.resolvedExecutable, [
      '--packages=${p.absolute('.dart_tool/package_config.json')}',
      p.absolute('bin/dotsan.dart'),
      '-n',
      'lib',
    ], workingDirectory: fixture.path);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stdout, startsWith('${p.join('lib', 'main.dart')}\n'));
  });

  test('SS-S1 an AOT build finds the SDK on PATH without DART_SDK', () {
    final file = explainFixture();
    final out = Directory.systemTemp.createTempSync('dotsan_aot');
    addTearDown(() => out.deleteSync(recursive: true));
    final exe = p.join(out.path, Platform.isWindows ? 'dotsan.exe' : 'dotsan');
    final compile = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/dotsan.dart',
      '-o',
      exe,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('compile failed: ${compile.stderr}');
    }

    final run = Process.runSync(
      exe,
      ['-n', file.parent.path],
      environment: {...Platform.environment}..remove('DART_SDK'),
      includeParentEnvironment: false,
    );
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stdout, endsWith('would convert 1 site(s) in 1 file(s)\n'));
    expect(run.stderr, isNot(contains('Exception')));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('SS-R4 a file it cannot write is an error (exit 74), not a crash', () {
    final file = explainFixture();
    final before = file.readAsStringSync();
    Process.runSync('chmod', ['444', file.path]);
    addTearDown(() => Process.runSync('chmod', ['644', file.path]));
    final run = dotsan([file.parent.path]);
    expect(run.exitCode, 74, reason: '${run.stderr}');
    expect(run.stderr, contains('could not write'));
    expect(run.stderr, isNot(contains('Unhandled exception')));
    expect(file.readAsStringSync(), before);
  }, testOn: '!windows');

  test(
    'R3-SS-4 a relative --exclude glob holds for a path through a symlink',
    () {
      final file = explainFixture();
      final root = file.parent.parent.path;
      final alias = Directory.systemTemp.createTempSync('dotsan_alias');
      addTearDown(() => alias.deleteSync(recursive: true));
      final link = Link(p.join(alias.path, 'pkg'))..createSync(root);
      final run = Process.runSync(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('bin/dotsan.dart'),
        '-n',
        '--exclude=lib/main.dart',
        p.join(link.path, 'lib'),
      ], workingDirectory: root);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, 'would convert 0 site(s) in 0 file(s)\n');
    },
    testOn: '!windows',
  );

  test('--version prints the pubspec version', () {
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
    expect(version, isNotNull);
    expect(dotsan(['--version']).stdout, 'dotsan $version\n');
  });
}

/// A fresh `^3.10.0` package whose `lib/main.dart` has one convertible site
/// (line 4) and one without a context type (line 3); returns that file.
File explainFixture() {
  final dir = Directory.systemTemp.createTempSync('dotsan_explain');
  addTearDown(() => dir.deleteSync(recursive: true));
  Directory(p.join(dir.path, 'lib')).createSync();
  const spec = 'name: explain_fixture\nenvironment:\n  sdk: ^3.10.0\n';
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(spec);
  final file = File(p.join(dir.path, 'lib', 'main.dart'))
    ..writeAsStringSync('''
enum Fit { cover, contain }
void main() {
  final untyped = Fit.contain;
  Fit f = Fit.cover;
  print([f, untyped]);
}
''');
  final get = Process.runSync('dart', [
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
  return file;
}

/// dotsan writes UTF-8; the default decoding is the system code page, which
/// is not UTF-8 on Windows (the warning's `—` came back as `â€”`).
ProcessResult dotsan(List<String> args) => Process.runSync(
  'dart',
  ['run', 'bin/dotsan.dart', ...args],
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);
