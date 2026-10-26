import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('--explain lists kept sites after the converted ones', () {
    final file = explainFixture();
    final run = dotsan(['--dry-run', '--explain', file.parent.path]);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stdout as String).equals(
      '${canonical(file.path)}\n'
      '  4: Fit.cover -> .cover\n'
      '  3: Fit.contain kept: no context type\n'
      'would convert 1 site(s) in 1 file(s), 1 kept\n',
    );
  });

  test('piped streams carry only the report and plain warning', () {
    // Full-string equality is the oracle: piped stdout is the parseable
    // report, so no progress/spinner text and no ANSI codes may leak into
    // either stream when they are not terminals. A skipped package fails the
    // run (65); its floor is below 3.10 to exercise the warning path.
    final pkg = fixture('floor_fixture', {
      'pubspec.yaml': 'name: floor_fixture\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/main.dart':
          'enum Fit { cover }\nvoid main() {\n  Fit f = Fit.cover;\n}\n',
    });
    final run = dotsan(['--dry-run', p.join(pkg.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(65);
    check(run.stdout as String)
        .equals('would convert 0 site(s) in 0 file(s)\n');
    final root = canonical(pkg.path);
    check(run.stderr as String).equals(
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
      check(because: '${run.stderr}', run.exitCode).equals(1);
      check(file.readAsStringSync()).equals(before);
    });

    test('a run with nothing to convert exits 0', () {
      final file = explainFixture()
        ..writeAsStringSync('enum Fit { cover }\nvoid main() {}\n');
      final run = dotsan(['-n', '--set-exit-if-changed', file.parent.path]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
    });

    test('a real run exits 1 and still writes', () {
      final file = explainFixture();
      final run = dotsan(['--set-exit-if-changed', file.parent.path]);
      check(because: '${run.stderr}', run.exitCode).equals(1);
      check(file.readAsStringSync()).contains('Fit f = .cover;');
    });
  });

  test('SS-G3 --format=json prints the report as one JSON document', () {
    final file = explainFixture();
    final run = dotsan(['-n', '--explain', '--format=json', file.parent.path]);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stderr as String).startsWith('note: using Dart SDK ');
    check(LineSplitter.split(run.stderr as String)).length.equals(1);
    check(jsonDecode(run.stdout as String))
        .isA<Map<String, Object?>>()
        .deepEquals({
          'dryRun': true,
          'converted': 1,
          'kept': 1,
          'skipListed': 0,
          'removedImports': 0,
          'skippedWithErrors': <Object?>[],
          'skippedBelowFloor': <Object?>[],
          'skippedUnconfigured': <Object?>[],
          'skippedOrphanParts': <Object?>[],
          'unreadableDirectories': <Object?>[],
          'skippedGenerated': <Object?>[],
          'writeFailures': <Object?>[],
          'unmatchedSkips': <Object?>[],
          'unmatchedExcludes': <Object?>[],
          'files': [
            {
              'path': canonical(file.path),
              'removedImports': 0,
              'prunedImports': <Object?>[],
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
    check(run.exitCode).equals(64);
    check(run.stderr as String).contains('does_not_exist');
  });

  test('SS-B11 an invalid --exclude glob is a usage error (exit 64)', () {
    final run = dotsan(['-n', 'lib', '--exclude=[']);
    check(run.exitCode).equals(64);
    check(run.stderr as String).not((it) => it.contains('Unhandled exception'));
  });

  test('SS-M4 file lines are relative to the working directory', () {
    final dir = fixture('relative_fixture', {
      'lib/main.dart': 'enum Fit { cover }\nFit f() => Fit.cover;\n',
    });
    final run = dotsan(['-n', 'lib'], cwd: dir.path);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stdout as String).startsWith('${p.join('lib', 'main.dart')}\n');
  });

  group('workspace list', () {
    // Pub expands workspace globs from language 3.11 on. The root's own
    // default directory (`tool/`) must not hide the members'.
    const spec = 'environment:\n  sdk: ^3.11.0\n';
    Directory workspace(
      String declaration, {
      bool pubGet = true,
    }) => fixture('ws_root', {
      'pubspec.yaml': 'name: ws_root\npublish_to: none\n$spec$declaration\n',
      'tool/.keep': '',
      for (final name in ['pkg_a', 'pkg_b']) ...{
        'pkgs/$name/pubspec.yaml': 'name: $name\nresolution: workspace\n$spec',
        'pkgs/$name/lib/$name.dart':
            'enum Fit { cover }\nFit f() => Fit.cover;\n',
      },
    }, pubGet: pubGet);

    for (final (form, declaration) in [
      ('an indented block list', 'workspace:\n  - pkgs/pkg_a\n  - pkgs/pkg_b'),
      ('column-0 block items', 'workspace:\n- pkgs/pkg_a\n- pkgs/pkg_b'),
      ('a flow glob', 'workspace: [pkgs/*]'),
      ('a brace glob', 'workspace: ["pkgs/{pkg_a,pkg_b}"]'),
      ('a bracket glob', 'workspace: ["pkgs/pkg_[ab]"]'),
    ]) {
      test('finds both members declared as $form', () {
        final run = dotsan(['-n'], cwd: workspace(declaration).path);
        check(because: '${run.stderr}', run.exitCode).equals(0);
        check(run.stdout as String)
          ..contains('${p.join('pkgs', 'pkg_a', 'lib', 'pkg_a.dart')}\n')
          ..endsWith('would convert 2 site(s) in 2 file(s)\n');
      });
    }

    for (final (form, declaration, error) in [
      (
        'a scalar',
        'workspace: pkgs/pkg_a',
        '"workspace" must be a list of strings',
      ),
      (
        'an unclosed flow list',
        'workspace: [pkgs/pkg_a',
        "expected ',' or ']'",
      ),
      (
        'a member glob that matches nothing',
        'workspace:\n  - pkgs/nonexistent_*',
        'workspace member "pkgs/nonexistent_*" matched no directory',
      ),
      (
        'a member that does not exist',
        'workspace:\n  - pkgs/pkg_c',
        'workspace member "pkgs/pkg_c" does not exist',
      ),
      (
        'an invalid member glob',
        'workspace: ["pkgs/["]',
        'invalid workspace member glob "pkgs/["',
      ),
    ]) {
      test('exits 64 on $form', () {
        final ws = workspace(declaration, pubGet: false);
        final run = dotsan(['-n'], cwd: ws.path);
        check(because: '${run.stderr}', run.exitCode).equals(64);
        check(run.stderr as String).contains(error);
      });
    }
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
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stdout as String)
        .endsWith('would convert 1 site(s) in 1 file(s)\n');
    check(run.stderr as String).not((it) => it.contains('Exception'));
  }, timeout: const .new(.new(minutes: 5)));

  test('SS-R4 a file it cannot write is an error (exit 74), not a crash', () {
    final file = explainFixture();
    final before = file.readAsStringSync();
    Process.runSync('chmod', ['444', file.path]);
    addTearDown(() => Process.runSync('chmod', ['644', file.path]));
    final run = dotsan([file.parent.path]);
    check(because: '${run.stderr}', run.exitCode).equals(74);
    check(run.stderr as String).contains('could not write');
    check(run.stderr as String).not((it) => it.contains('Unhandled exception'));
    check(file.readAsStringSync()).equals(before);
  }, testOn: '!windows');

  test(
    'R3-SS-4 a relative --exclude glob holds for a path through a symlink',
    () {
      final file = explainFixture();
      final root = file.parent.parent.path;
      final alias = Directory.systemTemp.createTempSync('dotsan_alias');
      addTearDown(() => alias.deleteSync(recursive: true));
      final link = Link(p.join(alias.path, 'pkg'))..createSync(root);
      final run = dotsan([
        '-n',
        '--exclude=lib/main.dart',
        p.join(link.path, 'lib'),
      ], cwd: root);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .equals('would convert 0 site(s) in 0 file(s)\n');
    },
    testOn: '!windows',
  );

  test('--version prints the pubspec version', () {
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
    check(version).isNotNull();
    check(dotsan(['--version']).stdout as String).equals('dotsan $version\n');
  });

  /// A part whose one site orphans its library's import of `fit.dart`.
  Map<String, String> partOrphan({String lib = ''}) => {
    'lib/fit.dart': 'enum Fit { cover }\n',
    'lib/sink.dart': "import 'fit.dart';\nvoid take(Fit f) {}\n",
    'lib/lib.dart':
        "import 'fit.dart';\nimport 'sink.dart';\npart 'part.dart';\n$lib",
    'lib/part.dart': "part of 'lib.dart';\nvoid run() => take(Fit.cover);\n",
  };

  test('SS-I1 names the pruned import and counts its file in changed', () {
    final dir = fixture('part_orphan_cli', partOrphan());
    final run = dotsan(['-n', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stdout as String).equals(
      '${canonical(p.join(dir.path, 'lib', 'part.dart'))}\n'
      '  2: Fit.cover -> .cover\n'
      '${canonical(p.join(dir.path, 'lib', 'lib.dart'))}\n'
      "  1: import 'fit.dart' -> removed\n"
      'would convert 1 site(s) in 2 file(s), '
      'would prune 1 orphaned import(s)\n',
    );
  });

  test("explain names the pruned import beside a library's kept sites", () {
    final dir = fixture(
      'part_orphan_kept_cli',
      partOrphan(lib: 'void other() => print(Duration.zero);\n'),
    );
    final run = dotsan(['-n', '-e', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stdout as String).equals(
      '${canonical(p.join(dir.path, 'lib', 'lib.dart'))}\n'
      '  4: Duration.zero kept: context type Object? declares no static zero\n'
      "  1: import 'fit.dart' -> removed\n"
      '${canonical(p.join(dir.path, 'lib', 'part.dart'))}\n'
      '  2: Fit.cover -> .cover\n'
      'would convert 1 site(s) in 2 file(s), 1 kept, '
      'would prune 1 orphaned import(s)\n',
    );
  });

  test('--since with an unknown git revision or non-repo path exits 64', () {
    final run = dotsan(['--since=unknown_revision_xyz', 'lib']);
    check(run.exitCode).equals(64);
    check(run.stderr as String).contains('unknown git revision');

    final file = explainFixture();
    final nonRepo = dotsan(['--changed', file.path]);
    check(nonRepo.exitCode).equals(64);
    check(nonRepo.stderr as String).contains('not a git repository');
  });
}

/// A fresh `^3.10.0` package whose `lib/main.dart` has one convertible site
/// (line 4) and one without a context type (line 3); returns that file.
File explainFixture() {
  final dir = fixture('explain_fixture', {
    'lib/main.dart': '''
enum Fit { cover, contain }
void main() {
  final untyped = Fit.contain;
  Fit f = Fit.cover;
  print([f, untyped]);
}
''',
  });
  return File(p.join(dir.path, 'lib', 'main.dart'));
}
