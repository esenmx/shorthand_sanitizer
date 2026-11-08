// Audit 2026-10-15 ("natural API, no cover-ups"), keyed by item (`AU-<n>`):
// every skip, mismatch and side edit is reported instead of swallowed.
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const convertible = '''
enum Fit { cover, contain }
void take(Fit f) {}
void run() => take(Fit.cover);
''';

/// [source] with a non-UTF-8 byte (Latin-1 `é`) in a comment.
List<int> latin1Comment(String source) => [
  ...utf8.encode('// caf'),
  0xE9,
  ...utf8.encode('\n$source'),
];

void main() {
  group('a file the analyzer cannot read as written is a skip', () {
    test('a named non-UTF-8 file fails the gate instead of passing clean', () {
      final dir = fixture('utf8_named', {});
      final file = File(p.join(dir.path, 'lib', 'a.dart'))
        ..parent.createSync()
        ..writeAsBytesSync(latin1Comment(convertible));
      final run = shorthand([
        '-n',
        '-e',
        '--set-exit-if-changed',
        p.join('lib', 'a.dart'),
      ], cwd: dir.path);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      check(run.stderr as String).contains(
        'could not read ${p.join('lib', 'a.dart')} (not valid UTF-8); it and '
        'its library were not processed.\n',
      );
      check(file.readAsBytesSync()).deepEquals(latin1Comment(convertible));
    });

    test('a walk still processes the rest and lists the file in JSON', () {
      final dir = fixture('utf8_walk', {'lib/good.dart': convertible});
      final bad = File(p.join(dir.path, 'lib', 'bad.dart'))
        ..writeAsBytesSync(latin1Comment(convertible));
      final run = shorthand(['--format=json', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['converted']).equals(1);
      check(report['unreadableFiles']).isA<List<Object?>>().deepEquals([
        {'path': canonical(bad.path), 'error': 'not valid UTF-8'},
      ]);
      check(bad.readAsBytesSync()).deepEquals(latin1Comment(convertible));
    });

    test('a file it may not read is listed with the reason', () {
      final dir = fixture('unreadable_file', {'lib/a.dart': convertible});
      final file = p.join(dir.path, 'lib', 'a.dart');
      Process.runSync('chmod', ['000', file]);
      addTearDown(() => Process.runSync('chmod', ['644', file]));
      final run = shorthand(['-n', '--format=json', file]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['unreadableFiles'])
          .isA<List<Object?>>()
          .single
          .isA<Map<String, Object?>>()
        ..['path'].equals(canonical(file))
        ..['error'].isA<String>().isNotEmpty();
    }, testOn: '!windows');

    test('the library result counts it as a skip', () async {
      final dir = fixture('utf8_lib', {});
      final file = File(p.join(dir.path, 'lib', 'a.dart'))
        ..parent.createSync()
        ..writeAsBytesSync(latin1Comment(convertible));
      final result = await Sanitizer(dryRun: true).run([file.path]);
      check(result.hasSkips).isTrue();
      check(result.unreadableFiles.single.path).equals(canonical(file.path));
    });

    test('a file left alone by request is not read as a skip', () {
      final dir = fixture('utf8_request', {});
      File(p.join(dir.path, 'lib', 'excluded.dart'))
        ..parent.createSync()
        ..writeAsBytesSync(latin1Comment(convertible));
      File(p.join(dir.path, 'lib', 'generated.dart')).writeAsBytesSync([
        ...utf8.encode('// GENERATED CODE - DO NOT MODIFY BY HAND\n'),
        ...latin1Comment(convertible),
      ]);
      final run = shorthand([
        '-n',
        '--exclude=excluded.dart',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
    });

    group('an unreadable part stops its whole library', () {
      const library =
          "import 'fit.dart';\nimport 'sink.dart';\npart 'p.dart';\n"
          'void m() => take(Fit.a);\n';
      Directory partFixture(String name) => fixture(name, {
        'lib/fit.dart': 'enum Fit { a }\n',
        'lib/sink.dart': "import 'fit.dart';\nvoid take(Fit f) {}\n",
        'lib/m.dart': library,
      });

      for (final (description, name, flags) in [
        ('with --allow-errors', 'part_allow', ['--allow-errors']),
        ('without it', 'part_plain', const <String>[]),
      ]) {
        test('non-UTF-8, $description', () {
          final dir = partFixture(name);
          File(p.join(dir.path, 'lib', 'p.dart')).writeAsBytesSync([
            ...utf8.encode("part of 'm.dart';\n// caf"),
            0xE9,
            ...utf8.encode('\nFit g() => Fit.a;\n'),
          ]);
          final m = p.join('lib', 'm.dart');

          final run = shorthand([m, ...flags], cwd: dir.path);

          check(because: '${run.stderr}', run.exitCode).equals(65);
          check(run.stderr as String).contains(
            'could not read ${p.join('lib', 'p.dart')} (not valid UTF-8); it '
            'and its library were not processed.\n',
          );
          check(File(p.join(dir.path, m)).readAsStringSync()).equals(library);
        });
      }

      test('one it may not read, with --allow-errors', () {
        final dir = partFixture('part_denied');
        final part = File(p.join(dir.path, 'lib', 'p.dart'))
          ..writeAsStringSync("part of 'm.dart';\nFit g() => Fit.a;\n");
        Process.runSync('chmod', ['000', part.path]);
        addTearDown(() => Process.runSync('chmod', ['644', part.path]));
        final m = p.join('lib', 'm.dart');

        final run = shorthand([m, '--allow-errors'], cwd: dir.path);

        check(because: '${run.stderr}', run.exitCode).equals(65);
        check(File(p.join(dir.path, m)).readAsStringSync()).equals(library);
      }, testOn: '!windows');

      group('a part with no unit keeps the imports it may need', () {
        for (final (description, uri, setUp, stopsLibrary)
            in <(String, String, void Function(Directory lib), bool)>[
              ('not generated yet', 'p.g.dart', (_) {}, false),
              ('in an unknown package', 'package:nope/p.dart', (_) {}, false),
              ('a dart: library', 'dart:foo', (_) {}, false),
              ('over http', 'http://x.y/p.dart', (_) {}, false),
              ('an invalid URI', ':bad:', (_) {}, false),
              ('an empty URI', '', (_) {}, false),
              (
                'not a part',
                'p.txt',
                (lib) => write(lib, 'p.txt', 'Fit g() => Fit.a;\n'),
                false,
              ),
              (
                'outside lib',
                '../other/p.dart',
                (lib) =>
                    write(lib.parent, 'other/p.dart', 'Fit g() => Fit.a;\n'),
                false,
              ),
              (
                'a dangling symlink',
                'link.dart',
                (lib) =>
                    Link(p.join(lib.path, 'link.dart')).createSync('nowhere'),
                false,
              ),
              (
                'a symlink to itself',
                'link.dart',
                (lib) =>
                    Link(p.join(lib.path, 'link.dart')).createSync('link.dart'),
                true,
              ),
              (
                'a symlink to a directory',
                'link.dart',
                (lib) => Link(p.join(lib.path, 'link.dart')).createSync('.'),
                true,
              ),
              (
                'a directory',
                'dir.dart',
                (lib) => Directory(p.join(lib.path, 'dir.dart')).createSync(),
                true,
              ),
            ]) {
          test(description, () async {
            final dir = partFixture('part_no_unit');
            final lib = Directory(p.join(dir.path, 'lib'));
            final m = File(p.join(lib.path, 'm.dart'))
              ..writeAsStringSync(library.replaceFirst('p.dart', uri));
            setUp(lib);

            final result = await Sanitizer(allowErrors: true).run([m.path]);

            check(m.readAsStringSync()).contains("import 'fit.dart';");
            check(result.removedImportCount).equals(0);
            check(result.hasSkips).equals(stopsLibrary);
            check(result.convertedCount).equals(stopsLibrary ? 0 : 1);
          });
        }

        test('in a nested part', () async {
          final dir = partFixture('part_no_unit_nested');
          final m = File(p.join(dir.path, 'lib', 'm.dart'));
          write(dir, 'lib/p.dart', "part of 'm.dart';\npart 'q.g.dart';\n");

          final result = await Sanitizer(allowErrors: true).run([m.path]);

          check(m.readAsStringSync())
            ..contains("import 'fit.dart';")
            ..contains('take(.a)');
          check(result.removedImportCount).equals(0);
        });
      });

      test('a nested unreadable part stops the library too', () async {
        final dir = partFixture('part_nested');
        final m = File(p.join(dir.path, 'lib', 'm.dart'));
        write(dir, 'lib/p.dart', "part of 'm.dart';\npart 'q.dart';\n");
        final q = File(p.join(dir.path, 'lib', 'q.dart'))
          ..writeAsBytesSync([
            ...utf8.encode("part of 'p.dart';\n// caf"),
            0xE9,
            ...utf8.encode('\n'),
          ]);

        final result = await Sanitizer(allowErrors: true).run([m.path]);

        check(m.readAsStringSync()).equals(library);
        check([for (final (:path, error: _) in result.unreadableFiles) path])
            .deepEquals([canonical(q.path)]);
      });

      group('a part in a directory it may not enter', () {
        Directory denied(String name) {
          final dir = partFixture(name);
          write(dir, 'lib/m.dart', library.replaceFirst('p.dart', 'no/p.dart'));
          final no = p.join(dir.path, 'lib', 'no');
          write(dir, 'lib/no/p.dart', "part of '../m.dart';\n");
          Process.runSync('chmod', ['000', no]);
          addTearDown(() => Process.runSync('chmod', ['755', no]));
          return dir;
        }

        String mText(Directory dir) =>
            File(p.join(dir.path, 'lib', 'm.dart')).readAsStringSync();

        for (final allowErrors in [true, false]) {
          test('named, allowErrors: $allowErrors, stops the library', () async {
            final dir = denied('part_no_entry_$allowErrors');
            final before = mText(dir);

            final result = await Sanitizer(allowErrors: allowErrors)
                .run([p.join(dir.path, 'lib', 'm.dart')]);

            check(result.hasSkips).isTrue();
            check(mText(dir)).equals(before);
          });
        }

        test('walked, the warning holds: nothing in it was rewritten', () {
          final dir = denied('part_no_entry_walk');
          final before = mText(dir);

          final run = shorthand(['lib'], cwd: dir.path);

          check(because: '${run.stderr}', run.exitCode).equals(65);
          check(run.stderr as String).contains('none of its files were');
          check(mText(dir)).equals(before);
        });
      }, testOn: '!windows');

      test(
        'the library result lists it once when both were collected',
        () async {
          final dir = partFixture('part_once');
          final part = File(p.join(dir.path, 'lib', 'p.dart'))
            ..writeAsBytesSync([
              ...utf8.encode("part of 'm.dart';\n// caf"),
              0xE9,
              ...utf8.encode('\n'),
            ]);
          final result = await Sanitizer(allowErrors: true)
              .run([p.join(dir.path, 'lib')]);
          check([for (final (:path, error: _) in result.unreadableFiles) path])
              .deepEquals([canonical(part.path)]);
          check(result.convertedCount).equals(0);
        },
      );
    });

    test('a file the package itself excludes is not read as a skip', () async {
      final dir = fixture('utf8_analyzer_excluded', {
        'analysis_options.yaml': 'analyzer:\n  exclude: [lib/legacy/**]\n',
        'lib/a.dart': convertible,
      });
      final old = File(p.join(dir.path, 'lib', 'legacy', 'old.dart'))
        ..parent.createSync()
        ..writeAsBytesSync(latin1Comment(convertible));

      final run = shorthand(['-n', 'lib'], cwd: dir.path);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String).isEmpty();

      final result = await Sanitizer(dryRun: true)
          .run([p.join(dir.path, 'lib')]);
      check(result.hasSkips).isFalse();
      check(result.unreadableFiles).isEmpty();
      check([for (final (:path, reason: _) in result.excluded) path])
          .deepEquals([canonical(old.path)]);
    });

    test('a git mode does not read a file git filtered out', () {
      final dir = fixture('utf8_git', {'lib/changed.dart': convertible});
      File(p.join(dir.path, '.gitignore'))
          .writeAsStringSync('.dart_tool\nlib/ignored.dart\n');
      final init = Process.runSync('git', [
        'init',
        '-q',
      ], workingDirectory: dir.path);
      check(because: '${init.stderr}', init.exitCode).equals(0);
      File(p.join(dir.path, 'lib', 'ignored.dart'))
          .writeAsBytesSync(latin1Comment(convertible));
      final run = shorthand(['-n', '--changed', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .endsWith('would convert 1 site(s) in 1 file(s)\n');
    });
  });

  group('every hoisted <Type> is reported', () {
    const hoisted = '''
enum Fit { a, b }
final list = [Fit.a, Fit.b];
final set = const {
  Fit.a,
  Fit.b,
};
''';

    test('the JSON report names each insertion per file and in total', () {
      final dir = fixture('hoist_json', {'lib/a.dart': hoisted});
      final run = shorthand(['-n', '--format=json', 'lib'], cwd: dir.path);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['hoists']).equals(2);
      check(report['files'])
          .isA<List<Object?>>()
          .single
          .isA<Map<String, Object?>>()['hoistedTypes']
          .isA<List<Object?>>()
          .deepEquals([
            {'line': 2, 'column': 14, 'inserted': '<Fit>'},
            {'line': 3, 'column': 19, 'inserted': '<Fit>'},
          ]);
    });

    test('text names each insertion and a real run makes the same edits', () {
      final dir = fixture('hoist_text', {'lib/a.dart': hoisted});
      final file = p.join('lib', 'a.dart');
      final preview = shorthand(['-n', 'lib'], cwd: dir.path);
      check(because: '${preview.stderr}', preview.exitCode).equals(0);
      check(preview.stdout as String).equals(
        '$file\n'
        '  2: Fit.a -> .a\n'
        '  2: Fit.b -> .b\n'
        '  4: Fit.a -> .a\n'
        '  5: Fit.b -> .b\n'
        '  2: inserted <Fit>\n'
        '  3: inserted <Fit>\n'
        'would convert 4 site(s) in 1 file(s), would hoist 2 type(s)\n',
      );

      final real = shorthand(['lib'], cwd: dir.path);
      check(because: '${real.stderr}', real.exitCode).equals(0);
      check(real.stdout as String)
          .endsWith('converted 4 site(s) in 1 file(s), hoisted 2 type(s)\n');
      check(File(p.join(dir.path, file)).readAsStringSync())
        ..contains('final list = <Fit>[.a, .b];')
        ..contains('final set = const <Fit>{');
    });

    test(
      'the library result carries them; a refused hoist reports none',
      () async {
        final dir = fixture('hoist_lib', {
          'lib/a.dart': hoisted,
          'lib/b.dart': 'enum Fit { a }\nfinal one = [Fit.a];\n',
        });
        final result = await Sanitizer(dryRun: true)
            .run([p.join(dir.path, 'lib')]);
        check(result.hoistedTypeCount).equals(2);
        final file = result.files.single;
        check(p.basename(file.path)).equals('a.dart');
        check(file.hoistedTypes.map((h) => h.description).toList())
            .deepEquals(['2: inserted <Fit>', '3: inserted <Fit>']);
      },
    );
  });

  group('revertedCount does not depend on explain', () {
    const refused = '''
class Base {
  const Base();
  static const a = Base();
}
class Sub extends Base {
  const Sub();
  static const a = Sub();
}
const Base x = Sub.a;
''';
    const unviable = 'enum Fit { a }\nfinal x = Fit.a;\n';
    const skipListed = 'enum Fit { a }\nFit f() => Fit.a;\n';

    for (final (description, source, skips, count) in [
      ('a site the verify loop refused', refused, const <String>{}, 1),
      ('a site the static pre-check ruled out', unviable, const <String>{}, 1),
      ('a skip-listed site does not count', skipListed, {'Fit.a'}, 0),
    ]) {
      for (final explain in [false, true]) {
        test('$description, explain: $explain', () async {
          final dir = fixture('reverted', {'lib/a.dart': source});
          final result = await Sanitizer(
            dryRun: true,
            explain: explain,
            skips: skips,
          ).run([p.join(dir.path, 'lib')]);
          check(result.convertedCount).equals(0);
          check(result.revertedCount).equals(count);
        });
      }
    }
  });

  group('AU-1 a skipped file fails the run', () {
    test('a library with analysis errors exits 65 and is listed in JSON', () {
      final dir = fixture('au1_errors', {
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final bad = canonical(p.join(dir.path, 'lib', 'bad.dart'));
      final run = shorthand([
        '-n',
        '--set-exit-if-changed',
        '--format=json',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['skippedWithErrors']).isA<List<Object?>>().deepEquals([bad]);
      check(report['skippedBelowFloor']).isA<List<Object?>>().isEmpty();
      check(report['skippedUnconfigured']).isA<List<Object?>>().isEmpty();
      check(report['skippedOrphanParts']).isA<List<Object?>>().isEmpty();
      check(report['unreadableDirectories']).isA<List<Object?>>().isEmpty();
      check(report['writeFailures']).isA<List<Object?>>().isEmpty();
    });

    test('a package below the language floor exits 65 without the gate', () {
      final dir = fixture('au1_floor', {
        'pubspec.yaml': 'name: au1_floor\nenvironment:\n  sdk: ^3.0.0\n',
        'lib/a.dart': convertible,
      });
      final run = shorthand(['-n', '--format=json', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['skippedBelowFloor']).isA<List<Object?>>().deepEquals([
        {'root': canonical(dir.path), 'version': '3.0', 'files': 1},
      ]);
    });

    test('a package without a package config exits 65 and says why', () {
      final dir = fixture('au1_unconfigured', {
        'lib/a.dart': convertible,
      }, pubGet: false);
      final run = shorthand(['-n', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      check(run.stderr as String).equals(
        'warning: skipped 1 file(s) in ${canonical(dir.path)}: no package '
        'config entry — run `dart pub get` there first.\n',
      );
    });

    test('--allow-errors processes a library with analysis errors', () {
      final dir = fixture('au1_allow', {
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final run = shorthand(['-n', '--allow-errors', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .endsWith('would convert 1 site(s) in 1 file(s)\n');
    });

    test('a skip outranks --set-exit-if-changed', () {
      final dir = fixture('au1_rank', {
        'lib/a.dart': convertible,
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final run = shorthand([
        '-n',
        '--set-exit-if-changed',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      check(run.stdout as String)
          .endsWith('would convert 1 site(s) in 1 file(s)\n');
    });

    test('a write failure still exits 74, ahead of the skip code', () {
      final dir = fixture('au1_write', {
        'lib/a.dart': convertible,
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final a = File(p.join(dir.path, 'lib', 'a.dart'));
      Process.runSync('chmod', ['444', a.path]);
      addTearDown(() => Process.runSync('chmod', ['644', a.path]));
      final run = shorthand(['--format=json', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(74);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['writeFailures'])
          .isA<List<Object?>>()
          .single
          .isA<Map<String, Object?>>()
        ..['file'].equals(canonical(a.path))
        ..['path'].equals(canonical(a.path))
        ..['error'].isA<String>();
    }, testOn: '!windows');
  });

  group('AU-2 generated detection and reporting', () {
    test('generated skips stay silent by default and are listed with -e', () {
      final dir = fixture('au2_count', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
        'lib/b.dart': convertible,
      });
      final gen = canonical(p.join(dir.path, 'lib', 'a.g.dart'));
      final plain = shorthand(['-n', p.join(dir.path, 'lib')]);
      check(because: '${plain.stderr}', plain.exitCode).equals(0);
      check(plain.stderr as String).isEmpty();

      final explained = shorthand(['-n', '-e', p.join(dir.path, 'lib')]);
      check(explained.stderr as String)
          .contains('skipped 1 generated file(s) (--include-generated');
      check(explained.stderr as String).contains('  $gen\n');

      final json = shorthand(['-n', '--format=json', p.join(dir.path, 'lib')]);
      final report = jsonDecode(json.stdout as String) as Map<String, Object?>;
      check(report['skippedGenerated']).isA<List<Object?>>().deepEquals([gen]);
    });

    test('--include-generated processes a generated file', () {
      final dir = fixture('au2_include', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
      });
      final run = shorthand([
        '-n',
        '--include-generated',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .endsWith('would convert 1 site(s) in 1 file(s)\n');
    });

    test('a file named on the command line and skipped says so', () {
      final dir = fixture('au2_named', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
      });
      final gen = p.join(dir.path, 'lib', 'a.g.dart');
      final run = shorthand(['-n', gen]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String)
          .contains('warning: skipped ${canonical(gen)}: generated');
    });
  });

  test('AU-3 only the package root build/ is skipped', () async {
    final dir = fixture('au3_build', {
      'lib/src/build/config.dart': convertible,
      'build/out.dart': convertible,
    });
    final result = await Sanitizer(dryRun: true).run([dir.path]);
    check([for (final f in result.files) f.path]).deepEquals([
      canonical(p.join(dir.path, 'lib', 'src', 'build', 'config.dart')),
    ]);
  });

  test('AU-4 an orphan part file is listed as skipped', () async {
    final dir = fixture('au4_orphan', {
      'lib/orph/p.dart': "part of 'missing.dart';\nint x = 1;\n",
    });
    final part = canonical(p.join(dir.path, 'lib', 'orph', 'p.dart'));
    final result = await Sanitizer(dryRun: true).run([p.join(dir.path, 'lib')]);
    check(result.skippedOrphanParts).deepEquals([part]);

    final run = shorthand(['-n', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(65);
    check(run.stderr as String).contains(part);
  });

  test('AU-5 an unreadable directory is a warning and fails the run', () async {
    final dir = fixture('au5_unreadable', {
      'lib/a.dart': convertible,
      'lib/locked/b.dart': convertible,
    });
    final locked = p.join(dir.path, 'lib', 'locked');
    Process.runSync('chmod', ['000', locked]);
    addTearDown(() => Process.runSync('chmod', ['755', locked]));
    final result = await Sanitizer(dryRun: true).run([p.join(dir.path, 'lib')]);
    check([for (final d in result.unreadableDirectories) d.path])
        .deepEquals([canonical(locked)]);

    final run = shorthand(['-n', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(65);
    check(run.stderr as String).contains('could not read ${canonical(locked)}');
  }, testOn: '!windows');

  group('AU-6 skip entries', () {
    test('a malformed --skip entry is a usage error', () {
      for (final entry in ['.cover', 'Fit.', 'a..b', 'Fit cover']) {
        final run = shorthand(['-n', '--skip=$entry', 'lib']);
        check(
          because: 'entry "$entry": ${run.stderr}',
          run.exitCode,
        ).equals(64);
        check(run.stderr as String).contains('invalid --skip entry');
      }
    });

    test('padding around a comma-separated --skip list is fine', () {
      final dir = fixture('au6_pad', {'lib/a.dart': convertible});
      final run = shorthand([
        '-n',
        '--skip=Fit.cover, Fit.contain',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String).contains('would convert 0 site(s)');
    });

    test('a --skip entry that matched no site is reported', () async {
      final dir = fixture('au6_typo', {'lib/a.dart': convertible});
      final run = shorthand(['-n', '--skip=Fit.covr', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String)
          .contains('warning: --skip entry "Fit.covr" matched no site');
      check(run.stdout as String).contains('would convert 1 site(s)');

      final result = await Sanitizer(
        skips: {'Fit.covr', 'Fit.cover'},
        dryRun: true,
      ).run([p.join(dir.path, 'lib')]);
      check(result.unmatchedSkips).deepEquals({'Fit.covr'});
    });

    test('the library takes skips as given and rejects malformed ones', () {
      for (final entry in ['Fit.cover,Fit.contain', ' Fit.cover', '']) {
        check(
          because: 'entry "$entry"',
          () => Sanitizer(skips: {entry}),
        ).throws<ArgumentError>().has((e) => e.name, 'name').equals('skips');
      }
    });
  });

  group('run rejects a path it cannot sanitize', () {
    for (final (description, rel) in [
      ('that does not exist', 'lib/missing.dart'),
      ('to a file that is not Dart', 'notes.txt'),
    ]) {
      test('a path $description', () {
        final dir = fixture('bad_path', {'notes.txt': ''}, pubGet: false);
        check(() => Sanitizer().run([p.join(dir.path, rel)]))
            .throws<ArgumentError>()
            .has((e) => e.name, 'name')
            .equals('paths');
      });
    }
  });

  group('AU-7 excludes', () {
    test('an --exclude glob that matched no file is reported', () {
      final dir = fixture('au7_typo', {'lib/a.dart': convertible});
      final run = shorthand([
        '-n',
        '--exclude=lib/aa.dart',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String)
          .contains('warning: --exclude "lib/aa.dart" matched no file');
    });

    test(
      'a path glob is relative to the working directory, like the paths',
      () {
        final dir = fixture('au7_anchor', {'lib/a.dart': convertible});
        final a = p.join(p.basename(dir.path), 'lib', 'a.dart');
        final missed = shorthand([
          '-n',
          '--exclude=lib/a.dart',
          a,
        ], cwd: dir.parent.path);
        check(because: '${missed.stderr}', missed.exitCode).equals(0);
        check(missed.stdout as String).contains('would convert 1 site(s)');
        check(missed.stderr as String).contains(
          'warning: --exclude "lib/a.dart" matched no file (a glob with a / '
          'is relative to the working directory',
        );

        final glob = p.posix.join(p.basename(dir.path), 'lib', 'a.dart');
        final hit = shorthand([
          '-n',
          '--exclude=$glob',
          a,
        ], cwd: dir.parent.path);
        check(because: '${hit.stderr}', hit.exitCode).equals(0);
        check(hit.stdout as String)
            .equals('would convert 0 site(s) in 0 file(s)\n');
        check(hit.stderr as String)
            .contains('warning: skipped $a: matches --exclude');
      },
    );
  });

  test('AU-8 an invalid DART_SDK is an error naming the variable', () {
    final run = shorthand(
      ['-n', 'lib'],
      environment: {...Platform.environment, 'DART_SDK': '/nonexistent/sdk'},
    );
    check(because: '${run.stderr}', run.exitCode).equals(69);
    check(run.stderr as String).contains('DART_SDK');
    check(run.stderr as String).contains('/nonexistent/sdk');
  });

  test('AU-8 --explain names the Dart SDK it analyzes with', () {
    final dir = fixture('au8_sdk', {'lib/a.dart': convertible});
    final run = shorthand(['-n', '-e', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(0);
    check(run.stderr as String).contains('Dart SDK ${sdkPath()}');
  });

  test('AU-9 a dry run predicts the prunes of the write', () async {
    Directory make() => fixture('au9_parity', {
      'lib/fit.dart': 'enum Fit { fill, cover }\n',
      'lib/use.dart': "import 'fit.dart';\nvoid use(Fit f) {}\n",
      'lib/lp/l.dart':
          "import '../fit.dart';\nimport '../use.dart';\n"
          "part 'l_part.dart';\nvoid a() => use(Fit.fill);\n",
      'lib/lp/l_part.dart': "part of 'l.dart';\nvoid b() => use(Fit.cover);\n",
    });
    final dry = await Sanitizer(dryRun: true)
        .run([p.join(make().path, 'lib', 'lp')]);
    final wet = await Sanitizer().run([p.join(make().path, 'lib', 'lp')]);
    check(dry.convertedCount).equals(wet.convertedCount);
    check(dry.removedImportCount).equals(wet.removedImportCount);
    check(wet.removedImportCount).equals(1);
  });

  group('AU-10 every pruned import is reported where it was pruned', () {
    Directory make() => fixture('au10_prune', {
      'lib/fit.dart': 'enum Fit { fill, cover }\n',
      'lib/use.dart': "import 'fit.dart';\nvoid use(Fit f) {}\n",
      'lib/h.dart':
          "import 'fit.dart'; // keep: needed until the v2 migration lands\n"
          "import 'use.dart';\nvoid a() => use(Fit.fill);\n",
    });

    test('in text, beside the conversions of the same file', () {
      final dir = make();
      final run = shorthand(['-n', p.join(dir.path, 'lib', 'h.dart')]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String).equals(
        '${canonical(p.join(dir.path, 'lib', 'h.dart'))}\n'
        '  3: Fit.fill -> .fill\n'
        "  1: import 'fit.dart' -> removed, with its trailing comment "
        '// keep: needed until the v2 migration lands\n'
        'would convert 1 site(s) in 1 file(s), '
        'would prune 1 orphaned import(s)\n',
      );
    });

    test('in JSON, with the URI and the side edit', () {
      final dir = make();
      final run = shorthand([
        '-n',
        '--format=json',
        p.join(dir.path, 'lib', 'h.dart'),
      ]);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['files'])
          .isA<List<Object?>>()
          .single
          .isA<Map<String, Object?>>()
          .has((f) => f['prunedImports'], 'prunedImports')
          .isA<List<Object?>>()
          .deepEquals([
            {
              'line': 1,
              'uri': 'fit.dart',
              'replacement': null,
              'deletedComment': '// keep: needed until the v2 migration lands',
              'keptComment': null,
            },
          ]);
    });

    test('an emitted library; and a kept ignore_for_file are reported', () {
      final dir = fixture('au10_header', {
        'lib/fit.dart': 'enum Fit { fill }\n',
        'lib/use.dart': "import 'fit.dart';\nvoid use(Fit f) {}\n",
        // The pruned import is the only directive: `library;` keeps the doc.
        'lib/doc_aliases.dart': "import 'doc.dart';\ntypedef Mode = Fit;\n",
        'lib/doc.dart':
            "/// Library notes.\nimport 'doc_aliases.dart';\n\n"
            'enum Fit { fill }\nvoid take(Fit f) {}\n'
            'void a() => take(Mode.fill);\n',
        'lib/ig.dart':
            "import 'fit.dart'; // ignore_for_file: avoid_print\n"
            "import 'use.dart';\nvoid a() => use(Fit.fill);\n",
      });
      final run = shorthand([
        '-n',
        p.join(dir.path, 'lib', 'doc.dart'),
        p.join(dir.path, 'lib', 'ig.dart'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .contains("  2: import 'doc_aliases.dart' -> library;\n");
      check(run.stdout as String).contains(
        "  1: import 'fit.dart' -> removed, keeping its trailing comment "
        '// ignore_for_file: avoid_print on the line\n',
      );
    });
  });

  group('AU-11 analysis_options excludes', () {
    Directory make() => fixture('au11_options', {
      'analysis_options.yaml': 'analyzer:\n  exclude:\n    - lib/legacy/**\n',
      'lib/a.dart': convertible,
      'lib/legacy/old.dart': convertible,
    });

    test('are honoured by default', () async {
      final dir = make();
      final result = await Sanitizer(dryRun: true)
          .run([p.join(dir.path, 'lib')]);
      check([for (final f in result.files) f.path])
          .deepEquals([canonical(p.join(dir.path, 'lib', 'a.dart'))]);
    });

    test('--no-analyzer-excludes processes them', () {
      final dir = make();
      final run = shorthand([
        '-n',
        '--no-analyzer-excludes',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String)
          .contains('would convert 2 site(s) in 2 file(s)');
    });

    Directory nested(Map<String, String> exampleFiles) {
      final dir = fixture('au11_nested', {
        'analysis_options.yaml': 'analyzer:\n  exclude:\n    - example/**\n',
        'example/pubspec.yaml':
            'name: au11_example\nenvironment:\n  sdk: ^3.10.0\n',
        ...exampleFiles,
      });
      pubGetIn(p.join(dir.path, 'example'));
      return dir;
    }

    test(
      "a parent package's exclude does not reach a nested package",
      () async {
        final dir = nested({'example/lib/main.dart': convertible});
        final result = await Sanitizer(dryRun: true).run([dir.path]);
        check(result.excluded).isEmpty();
        check([for (final f in result.files) f.path]).deepEquals([
          canonical(p.join(dir.path, 'example', 'lib', 'main.dart')),
        ]);
      },
    );

    test("a nested package's own exclude still applies", () async {
      final dir = nested({
        'example/analysis_options.yaml':
            'analyzer:\n  exclude:\n    - lib/legacy/**\n',
        'example/lib/a.dart': convertible,
        'example/lib/legacy/old.dart': convertible,
      });
      final result = await Sanitizer(dryRun: true).run([dir.path]);
      check([for (final e in result.excluded) e.path]).deepEquals([
        canonical(p.join(dir.path, 'example', 'lib', 'legacy', 'old.dart')),
      ]);
      check([
        for (final f in result.files) f.path,
      ]).deepEquals([canonical(p.join(dir.path, 'example', 'lib', 'a.dart'))]);
    });

    test('a named file they exclude is a warning', () {
      final dir = make();
      final old = p.join(dir.path, 'lib', 'legacy', 'old.dart');
      final run = shorthand(['-n', old]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String)
          .contains('warning: skipped ${canonical(old)}: excluded by');
    });
  });
}
