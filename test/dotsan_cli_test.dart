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
    final explained = Directory.systemTemp.createTempSync('dotsan_explain');
    addTearDown(() => explained.deleteSync(recursive: true));
    Directory(p.join(explained.path, 'lib')).createSync();
    const spec = 'name: explain_fixture\nenvironment:\n  sdk: ^3.10.0\n';
    File(p.join(explained.path, 'pubspec.yaml')).writeAsStringSync(spec);
    final file = File(p.join(explained.path, 'lib', 'main.dart'))
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
    ], workingDirectory: explained.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');

    final run = Process.runSync('dart', [
      'run',
      'bin/dotsan.dart',
      '--dry-run',
      '--explain',
      p.join(explained.path, 'lib'),
    ]);
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
    final run = Process.runSync('dart', [
      'run',
      'bin/dotsan.dart',
      '--dry-run',
      p.join(pkg.path, 'lib'),
    ]);
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

  test('--version prints the pubspec version', () {
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
    expect(version, isNotNull);
    expect(dotsan(['--version']).stdout, 'dotsan $version\n');
  });
}

ProcessResult dotsan(List<String> args) =>
    Process.runSync('dart', ['run', 'bin/dotsan.dart', ...args]);
