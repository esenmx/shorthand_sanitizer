// Audit 2026-10-15 ("natural API, no cover-ups"), keyed by item (`AU-<n>`):
// every skip, mismatch and side edit is reported instead of swallowed.
import 'dart:convert';
import 'dart:io';

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
      expect(run.exitCode, 65, reason: '${run.stderr}');
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      expect(report['skippedWithErrors'], [bad]);
      expect(report['skippedBelowFloor'], isEmpty);
      expect(report['skippedUnconfigured'], isEmpty);
      expect(report['skippedOrphanParts'], isEmpty);
      expect(report['unreadableDirectories'], isEmpty);
      expect(report['writeFailures'], isEmpty);
    });

    test('a package below the language floor exits 65 without the gate', () {
      final dir = fixture('au1_floor', {
        'pubspec.yaml': 'name: au1_floor\nenvironment:\n  sdk: ^3.0.0\n',
        'lib/a.dart': convertible,
      });
      final run = dotsan(['-n', '--format=json', p.join(dir.path, 'lib')]);
      expect(run.exitCode, 65, reason: '${run.stderr}');
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      expect(report['skippedBelowFloor'], [
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
      expect(run.exitCode, 74, reason: '${run.stderr}');
      final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
      expect(report['writeFailures'], [
        {
          'file': canonical(a.path),
          'path': canonical(a.path),
          'error': isA<String>(),
        },
      ]);
    }, testOn: '!windows');
  });

  group('AU-2 generated detection and reporting', () {
    test('a library doc that mentions generated code is not a banner', () {
      final dir = fixture('au2_doc', {
        'lib/doc_gen.dart':
            '/// Helpers for reading generated code from protoc.\n'
            'library;\n\n$convertible',
      }, pubGet: false);
      expect(
        Sanitizer.isGenerated(p.join(dir.path, 'lib', 'doc_gen.dart')),
        isFalse,
      );
    });

    test('a doc banner that opens with the marker still counts (slang)', () {
      final dir = fixture('au2_slang', {
        'lib/strings.g.dart':
            '/// Generated file. Do not edit.\n///\n/// Source: lib/i18n\n'
            '// ignore_for_file: type=lint\n$convertible',
      }, pubGet: false);
      expect(
        Sanitizer.isGenerated(p.join(dir.path, 'lib', 'strings.g.dart')),
        isTrue,
      );
    });

    test('generated skips are counted on stderr and listed with -e', () {
      final dir = fixture('au2_count', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
        'lib/b.dart': convertible,
      });
      final gen = canonical(p.join(dir.path, 'lib', 'a.g.dart'));
      final plain = dotsan(['-n', p.join(dir.path, 'lib')]);
      expect(plain.exitCode, 0, reason: '${plain.stderr}');
      expect(
        plain.stderr,
        contains('skipped 1 generated file(s) (--include-generated'),
      );
      expect(plain.stderr, isNot(contains(gen)));

      final explained = dotsan(['-n', '-e', p.join(dir.path, 'lib')]);
      expect(explained.stderr, contains('  $gen\n'));

      final json = dotsan(['-n', '--format=json', p.join(dir.path, 'lib')]);
      final report = jsonDecode(json.stdout as String) as Map<String, Object?>;
      expect(report['skippedGenerated'], [gen]);
    });

    test('a file named on the command line and skipped says so', () {
      final dir = fixture('au2_named', {
        'lib/a.g.dart':
            '// GENERATED CODE - DO NOT MODIFY BY HAND\n$convertible',
      });
      final gen = p.join(dir.path, 'lib', 'a.g.dart');
      final run = dotsan(['-n', gen]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stderr,
        contains('warning: skipped ${canonical(gen)}: generated'),
      );
    });
  });

  test('AU-3 only the package root build/ is skipped', () async {
    final dir = fixture('au3_build', {
      'lib/src/build/config.dart': convertible,
      'build/out.dart': convertible,
    });
    final result = await Sanitizer(dryRun: true).run([dir.path]);
    expect(
      [for (final f in result.files) f.path],
      [canonical(p.join(dir.path, 'lib', 'src', 'build', 'config.dart'))],
    );
  });

  test('AU-4 an orphan part file is listed as skipped', () async {
    final dir = fixture('au4_orphan', {
      'lib/orph/p.dart': "part of 'missing.dart';\nint x = 1;\n",
    });
    final part = canonical(p.join(dir.path, 'lib', 'orph', 'p.dart'));
    final result = await Sanitizer(dryRun: true).run([p.join(dir.path, 'lib')]);
    expect(result.skippedOrphanParts, [part]);

    final run = dotsan(['-n', p.join(dir.path, 'lib')]);
    expect(run.exitCode, 65, reason: '${run.stderr}');
    expect(run.stderr, contains(part));
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
    expect(
      [for (final d in result.unreadableDirectories) d.path],
      [canonical(locked)],
    );

    final run = dotsan(['-n', p.join(dir.path, 'lib')]);
    expect(run.exitCode, 65, reason: '${run.stderr}');
    expect(run.stderr, contains('could not read ${canonical(locked)}'));
  }, testOn: '!windows');

  group('AU-6 skip entries', () {
    test('a malformed --skip entry is a usage error', () {
      for (final entry in ['.cover', 'Fit.', 'a..b', 'Fit cover']) {
        final run = dotsan(['-n', '--skip=$entry', 'lib']);
        expect(run.exitCode, 64, reason: 'entry "$entry": ${run.stderr}');
        expect(run.stderr, contains('invalid --skip entry'));
      }
    });

    test('padding around a comma-separated --skip list is fine', () {
      final dir = fixture('au6_pad', {'lib/a.dart': convertible});
      final run = dotsan([
        '-n',
        '--skip=Fit.cover, Fit.contain',
        p.join(dir.path, 'lib'),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, contains('would convert 0 site(s)'));
    });

    test('a --skip entry that matched no site is reported', () async {
      final dir = fixture('au6_typo', {'lib/a.dart': convertible});
      final run = dotsan(['-n', '--skip=Fit.covr', p.join(dir.path, 'lib')]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stderr,
        contains('warning: --skip entry "Fit.covr" matched no site'),
      );
      expect(run.stdout, contains('would convert 1 site(s)'));

      final result = await Sanitizer(
        skips: {'Fit.covr', 'Fit.cover'},
        dryRun: true,
      ).run([p.join(dir.path, 'lib')]);
      expect(result.unmatchedSkips, {'Fit.covr'});
    });

    test('the library takes skips as given and rejects malformed ones', () {
      for (final entry in ['Fit.cover,Fit.contain', ' Fit.cover', '']) {
        expect(
          () => Sanitizer(skips: {entry}),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'skips')),
          reason: 'entry "$entry"',
        );
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
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stderr,
        contains('warning: --exclude "lib/aa.dart" matched no file'),
      );
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
        expect(missed.exitCode, 0, reason: '${missed.stderr}');
        expect(missed.stdout, contains('would convert 1 site(s)'));
        expect(
          missed.stderr,
          contains(
            'warning: --exclude "lib/a.dart" matched no file (a glob with a / '
            'is relative to the working directory',
          ),
        );

        final glob = p.posix.join(p.basename(dir.path), 'lib', 'a.dart');
        final hit = dotsan(['-n', '--exclude=$glob', a], cwd: dir.parent.path);
        expect(hit.exitCode, 0, reason: '${hit.stderr}');
        expect(hit.stdout, 'would convert 0 site(s) in 0 file(s)\n');
        expect(hit.stderr, contains('warning: skipped $a: matches --exclude'));
      },
    );
  });

  test('AU-8 an invalid DART_SDK is an error naming the variable', () {
    final run = dotsan(
      ['-n', 'lib'],
      environment: {...Platform.environment, 'DART_SDK': '/nonexistent/sdk'},
    );
    expect(run.exitCode, 69, reason: '${run.stderr}');
    expect(run.stderr, contains('DART_SDK'));
    expect(run.stderr, contains('/nonexistent/sdk'));
  });

  test('AU-8 --explain names the Dart SDK it analyzes with', () {
    final dir = fixture('au8_sdk', {'lib/a.dart': convertible});
    final run = dotsan(['-n', '-e', p.join(dir.path, 'lib')]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(run.stderr, contains('Dart SDK ${sdkPath()}'));
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
    expect(dry.convertedCount, wet.convertedCount);
    expect(dry.removedImportCount, wet.removedImportCount);
    expect(wet.removedImportCount, 1);
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
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stdout,
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
      final file = (report['files']! as List).single as Map<String, Object?>;
      expect(file['prunedImports'], [
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
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stdout,
        contains("  2: import 'doc_aliases.dart' -> library;\n"),
      );
      expect(
        run.stdout,
        contains(
          "  1: import 'fit.dart' -> removed, keeping its trailing comment "
          '// ignore_for_file: avoid_print on the line\n',
        ),
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
      expect(
        [for (final f in result.files) f.path],
        [canonical(p.join(dir.path, 'lib', 'a.dart'))],
      );
    });

    test('--no-analyzer-excludes processes them', () {
      final dir = make();
      final run = dotsan([
        '-n',
        '--no-analyzer-excludes',
        p.join(dir.path, 'lib'),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout, contains('would convert 2 site(s) in 2 file(s)'));
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
        expect(result.excluded, isEmpty);
        expect(
          [for (final f in result.files) f.path],
          [canonical(p.join(dir.path, 'example', 'lib', 'main.dart'))],
        );
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
      expect(
        [for (final e in result.excluded) e.path],
        [canonical(p.join(dir.path, 'example', 'lib', 'legacy', 'old.dart'))],
      );
      expect(
        [for (final f in result.files) f.path],
        [canonical(p.join(dir.path, 'example', 'lib', 'a.dart'))],
      );
    });

    test('a named file they exclude is a warning', () {
      final dir = make();
      final old = p.join(dir.path, 'lib', 'legacy', 'old.dart');
      final run = dotsan(['-n', old]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(
        run.stderr,
        contains('warning: skipped ${canonical(old)}: excluded by'),
      );
    });
  });
}
