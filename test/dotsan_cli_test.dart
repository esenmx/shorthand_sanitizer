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
    expect(
      run.stderr,
      'warning: skipped 1 file(s) at language version 3.0 — dot shorthands '
      "need 3.10. Raise `environment: sdk:` in that package's pubspec.yaml; "
      'the installed SDK does not decide this.\n',
    );
  });
}
