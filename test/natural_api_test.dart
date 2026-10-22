// Audit 2026-10-15 ("natural API, no cover-ups"), keyed by item (`AU-<n>`):
// every skip, mismatch and side edit is reported instead of swallowed.
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:test/test.dart';

/// A fresh package holding [files] (paths relative to its root), after
/// `dart pub get` unless [pubGet] is false.
Directory fixture(
  String name,
  Map<String, String> files, {
  bool pubGet = true,
}) {
  final dir = Directory.systemTemp.createTempSync('dotsan_au_$name');
  addTearDown(() => dir.deleteSync(recursive: true));
  final all = {
    'pubspec.yaml': 'name: $name\nenvironment:\n  sdk: ^3.10.0\n',
    ...files,
  };
  for (final MapEntry(key: rel, value: source) in all.entries) {
    File(p.join(dir.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
  }
  if (pubGet) {
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: dir.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
  }
  return dir;
}

String canonical(String path) => p.normalize(p.absolute(path));

/// dotsan from this repo, run in [cwd] (default: the repo root).
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

const convertible = '''
enum Fit { cover, contain }
void take(Fit f) {}
void run() => take(Fit.cover);
''';

void main() {
  group('AU-1 a skipped file fails the run', () {
    test('a library with analysis errors exits 65 and is listed in JSON', () {
      final dir = fixture('au1_errors', {
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final bad = canonical(p.join(dir.path, 'lib', 'bad.dart'));
      final run = dotsan([
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
      final run = dotsan(['-n', '--format=json', p.join(dir.path, 'lib')]);
      check(because: '${run.stderr}', run.exitCode).equals(65);
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      check(report['skippedBelowFloor']).isA<List<Object?>>().deepEquals([
        {'root': canonical(dir.path), 'version': '3.0', 'files': 1},
      ]);
    });

    test('a write failure still exits 74, ahead of the skip code', () {
      final dir = fixture('au1_write', {
        'lib/a.dart': convertible,
        'lib/bad.dart': "$convertible\nint bad = '';\n",
      });
      final a = File(p.join(dir.path, 'lib', 'a.dart'));
      Process.runSync('chmod', ['444', a.path]);
      addTearDown(() => Process.runSync('chmod', ['644', a.path]));
      final run = dotsan(['--format=json', p.join(dir.path, 'lib')]);
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
    test('a library doc that mentions generated code is not a banner', () {
      final dir = fixture('au2_doc', {
        'lib/doc_gen.dart':
            '/// Helpers for reading generated code from protoc.\n'
            'library;\n\n$convertible',
      }, pubGet: false);
      check(Sanitizer.isGenerated(p.join(dir.path, 'lib', 'doc_gen.dart')))
          .isFalse();
    });

    test('a doc banner that opens with the marker still counts (slang)', () {
      final dir = fixture('au2_slang', {
        'lib/strings.g.dart':
            '/// Generated file. Do not edit.\n///\n/// Source: lib/i18n\n'
            '// ignore_for_file: type=lint\n$convertible',
      }, pubGet: false);
      check(Sanitizer.isGenerated(p.join(dir.path, 'lib', 'strings.g.dart')))
          .isTrue();
    });

    test('generated skips are counted on stderr and listed with -e', () {
      final dir = fixture('au2_count', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
        'lib/b.dart': convertible,
      });
      final gen = canonical(p.join(dir.path, 'lib', 'a.g.dart'));
      final plain = dotsan(['-n', p.join(dir.path, 'lib')]);
      check(because: '${plain.stderr}', plain.exitCode).equals(0);
      check(plain.stderr as String)
          .contains('skipped 1 generated file(s) (--include-generated');
      check(plain.stderr as String).not((it) => it.contains(gen));

      final explained = dotsan(['-n', '-e', p.join(dir.path, 'lib')]);
      check(explained.stderr as String).contains('  $gen\n');

      final json = dotsan(['-n', '--format=json', p.join(dir.path, 'lib')]);
      final report = jsonDecode(json.stdout as String) as Map<String, Object?>;
      check(report['skippedGenerated']).isA<List<Object?>>().deepEquals([gen]);
    });

    test('a file named on the command line and skipped says so', () {
      final dir = fixture('au2_named', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
      });
      final gen = p.join(dir.path, 'lib', 'a.g.dart');
      final run = dotsan(['-n', gen]);
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

    final run = dotsan(['-n', p.join(dir.path, 'lib')]);
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

    final run = dotsan(['-n', p.join(dir.path, 'lib')]);
    check(because: '${run.stderr}', run.exitCode).equals(65);
    check(run.stderr as String).contains('could not read ${canonical(locked)}');
  }, testOn: '!windows');

  group('AU-6 skip entries', () {
    test('a malformed --skip entry is a usage error', () {
      for (final entry in ['.cover', 'Fit.', 'a..b', 'Fit cover']) {
        final run = dotsan(['-n', '--skip=$entry', 'lib']);
        check(
          because: 'entry "$entry": ${run.stderr}',
          run.exitCode,
        ).equals(64);
        check(run.stderr as String).contains('invalid --skip entry');
      }
    });

    test('padding around a comma-separated --skip list is fine', () {
      final dir = fixture('au6_pad', {'lib/a.dart': convertible});
      final run = dotsan([
        '-n',
        '--skip=Fit.cover, Fit.contain',
        p.join(dir.path, 'lib'),
      ]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stdout as String).contains('would convert 0 site(s)');
    });

    test('a --skip entry that matched no site is reported', () async {
      final dir = fixture('au6_typo', {'lib/a.dart': convertible});
      final run = dotsan(['-n', '--skip=Fit.covr', p.join(dir.path, 'lib')]);
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

  group('AU-7 excludes', () {
    test('an --exclude glob that matched no file is reported', () {
      final dir = fixture('au7_typo', {'lib/a.dart': convertible});
      final run = dotsan([
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
        final missed = dotsan([
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
        final hit = dotsan(['-n', '--exclude=$glob', a], cwd: dir.parent.path);
        check(because: '${hit.stderr}', hit.exitCode).equals(0);
        check(hit.stdout as String)
            .equals('would convert 0 site(s) in 0 file(s)\n');
        check(hit.stderr as String)
            .contains('warning: skipped $a: matches --exclude');
      },
    );
  });

  test('AU-8 an invalid DART_SDK is an error naming the variable', () {
    final run = dotsan(
      ['-n', 'lib'],
      environment: {...Platform.environment, 'DART_SDK': '/nonexistent/sdk'},
    );
    check(because: '${run.stderr}', run.exitCode).equals(69);
    check(run.stderr as String).contains('DART_SDK');
    check(run.stderr as String).contains('/nonexistent/sdk');
  });

  test('AU-8 --explain names the Dart SDK it analyzes with', () {
    final dir = fixture('au8_sdk', {'lib/a.dart': convertible});
    final run = dotsan(['-n', '-e', p.join(dir.path, 'lib')]);
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
      final run = dotsan(['-n', p.join(dir.path, 'lib', 'h.dart')]);
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
      final run = dotsan([
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
      final run = dotsan([
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
      final run = dotsan([
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
      final get = Process.runSync('dart', [
        'pub',
        'get',
      ], workingDirectory: p.join(dir.path, 'example'));
      if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
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
      final run = dotsan(['-n', old]);
      check(because: '${run.stderr}', run.exitCode).equals(0);
      check(run.stderr as String)
          .contains('warning: skipped ${canonical(old)}: excluded by');
    });
  });
}
