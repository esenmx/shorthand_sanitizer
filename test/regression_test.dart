// Sweep 2026-10-03 regressions, keyed by finding ID (`SS-<ID>` in each test
// name). Each one failed on 0.9.0.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:test/test.dart';

late Directory pkg;
int fileId = 0;

Directory makePackage(String name, String spec, {bool pubGet = true}) {
  final dir = Directory.systemTemp.createTempSync('sweep_$name');
  Directory(p.join(dir.path, 'lib')).createSync();
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(spec);
  if (pubGet) {
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: dir.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
  }
  return dir;
}

File write(Directory dir, String rel, String source) =>
    File(p.join(dir.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);

Future<String> sanitize(
  String source, {
  Set<String> skips = const {},
  bool allowErrors = false,
}) async {
  final file = write(pkg, 'lib/case_${fileId++}.dart', source);
  final result = await Sanitizer(
    skips: skips,
    allowErrors: allowErrors,
  ).run([file.path]);
  // A fixture with an analysis error is skipped whole: the assertion would
  // pass without testing anything.
  expect(result.skippedWithErrors, isEmpty, reason: 'fixture has errors');
  return file.readAsStringSync();
}

/// `dart analyze` machine lines (both streams) for files under [dir] whose
/// path contains [file].
String analyze(Directory dir, String file) {
  final r = Process.runSync('dart', [
    'analyze',
    '--format=machine',
    '.',
  ], workingDirectory: dir.path);
  return '${r.stdout}${r.stderr}'
      .split('\n')
      .where((l) => l.contains(file))
      .join('\n');
}

const geoLibrary = '''
class Geo {
  const Geo();
  const factory Geo.all(int v) = Box.all;
  static const Geo zero = Box.zero;
}
class Box extends Geo {
  const Box.all(this.v);
  final int v;
  static const Box zero = Box.all(0);
  void boxOnly() {}
}
extension GeoTag on Geo {
  String tag() => 'Geo';
}
extension BoxTag on Box {
  String tag() => 'Box';
}
''';

void main() {
  setUpAll(() {
    pkg = makePackage('shared', 'name: sweep\nenvironment:\n  sdk: ^3.10.0\n');
    write(pkg, 'lib/geo.dart', geoLibrary);
  });
  tearDownAll(() => pkg.deleteSync(recursive: true));

  test('SS-B1 typedef with fixed type arguments keeps its prefix', () async {
    // `IntG.of(1)` builds a G<int>; `.of(1)` in a G<num> slot builds a
    // G<num> — same element, different reified type argument.
    final out = await sanitize('''
class G<T> {
  G.of(this.value);
  T value;
}
typedef IntG = G<int>;
typedef IntList = List<int>;
final G<num> g = IntG.of(1);
final List<num> l = IntList.filled(1, 0);
''');
    expect(out, contains('IntG.of(1)'));
    expect(out, contains('IntList.filled(1, 0)'));
  });

  test('SS-B2 licensed rebind must not change a cascade target type', () async {
    // Box.all(1)..tag() dispatches BoxTag; .all(1) is typed Geo -> GeoTag.
    final out = await sanitize('''
import 'geo.dart';
final Geo a = Box.all(1)..tag();
final Geo b = Box.zero..tag();
''');
    expect(out, contains('Box.all(1)..tag()'));
    expect(out, contains('Box.zero..tag()'));
  });

  test('SS-B2 licensed rebind must not drop assignment promotion', () async {
    final out = await sanitize('''
import 'geo.dart';
String f() {
  Geo g = const Geo();
  if (g is Box) return '';
  g = Box.all(2);
  return g.tag(); // BoxTag before, GeoTag after the rewrite
}
''');
    expect(out, contains('g = Box.all(2);'));
  });

  test('SS-B3 a new error matching a baseline message is not masked', () async {
    // allowErrors: by default the pre-existing error skips the whole file.
    final out = await sanitize('''
import 'geo.dart';
void pre(Geo g) => g.boxOnly(); // pre-existing error, same message
final Geo fresh = Box.all(1)..boxOnly();
''', allowErrors: true);
    expect(out, contains('Box.all(1)..boxOnly()'));
  });

  test('SS-B4 package below 3.10 without package_config is skipped', () async {
    final old = makePackage(
      'nocfg',
      'name: nocfg\nenvironment:\n  sdk: ^3.9.0\n',
      pubGet: false,
    );
    addTearDown(() => old.deleteSync(recursive: true));
    const source = '''
enum Fit { cover, contain }
void take(Fit f) {}
void run() => take(Fit.cover);
''';
    final file = write(old, 'lib/a.dart', source);
    final result = await Sanitizer().run([file.path]);
    expect(file.readAsStringSync(), source);
    expect(result.skippedUnconfigured, {p.normalize(p.absolute(old.path)): 1});
  });

  test(
    'SS-B4 a nested example without its own package config is skipped',
    () async {
      final outer = makePackage(
        'outer',
        'name: outer\nenvironment:\n  sdk: ^3.10.0\n',
      );
      addTearDown(() => outer.deleteSync(recursive: true));
      write(
        outer,
        'example/pubspec.yaml',
        'name: ex\nenvironment:\n  sdk: ^3.9.0\n'
            'dependencies:\n  outer:\n    path: ..\n',
      );
      const source = '''
enum Fit { cover, contain }
void take(Fit f) {}
void run() => take(Fit.cover);
''';
      final main = write(outer, 'example/lib/main.dart', source);
      final get = Process.runSync('dart', [
        'pub',
        'get',
      ], workingDirectory: outer.path);
      if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
      Directory(p.join(outer.path, 'example', '.dart_tool'))
          .deleteSync(recursive: true);
      File(p.join(outer.path, 'example', 'pubspec.lock')).deleteSync();

      final result = await Sanitizer().run([outer.path]);
      expect(main.readAsStringSync(), source);
      expect(result.skippedUnconfigured, {
        p.normalize(p.absolute(p.join(outer.path, 'example'))): 1,
      });
    },
  );

  test('SS-B5 rewriting a part prunes the import it orphans', () async {
    write(pkg, 'lib/po_fit.dart', 'enum Fit { cover, contain }\n');
    write(
      pkg,
      'lib/po_sink.dart',
      "import 'po_fit.dart';\nvoid take(Fit f) {}\n",
    );
    final lib = write(
      pkg,
      'lib/po_lib.dart',
      "import 'po_fit.dart';\nimport 'po_sink.dart';\npart 'po_part.dart';\n",
    );
    final part = write(
      pkg,
      'lib/po_part.dart',
      "part of 'po_lib.dart';\nvoid run() => take(Fit.cover);\n",
    );
    await Sanitizer().run([lib.path, part.path]);
    expect(part.readAsStringSync(), contains('take(.cover)'));
    expect(analyze(pkg, 'po_lib.dart'), isNot(contains('UNUSED_IMPORT')));
  });

  test('SS-B6 a rebind onto a @Deprecated alias stays prefixed', () async {
    final dep = makePackage(
      'geo_pkg',
      'name: geo_pkg\nenvironment:\n  sdk: ^3.10.0\n',
      pubGet: false,
    );
    write(
      dep,
      'lib/geo.dart',
      geoLibrary
          .replaceFirst('const factory', "@Deprecated('x') const factory")
          .replaceFirst(
            'static const Geo',
            "@Deprecated('x') static const Geo",
          ),
    );
    final app = makePackage(
      'app',
      'name: app\nenvironment:\n  sdk: ^3.10.0\n'
          'dependencies:\n  geo_pkg:\n    path: ${dep.path}\n',
    );
    addTearDown(() {
      app.deleteSync(recursive: true);
      dep.deleteSync(recursive: true);
    });
    final file = write(app, 'lib/use.dart', '''
import 'package:geo_pkg/geo.dart';
void use(Geo g) {}
void run() {
  use(Box.all(1));
  use(Box.zero);
}
''');
    await Sanitizer().run([file.path]);
    expect(analyze(app, 'use.dart'), isNot(contains('DEPRECATED_MEMBER_USE')));
  });

  test("SS-S4 a library sees its part's earlier write", () async {
    write(pkg, 'lib/s4_fit.dart', 'enum Fit { cover, contain }\n');
    write(
      pkg,
      'lib/s4_sink.dart',
      "import 's4_fit.dart';\nvoid take(Fit f) {}\n",
    );
    final part = write(
      pkg,
      'lib/a_s4_part.dart',
      "part of 'z_s4_lib.dart';\nvoid run() => take(Fit.cover);\n",
    );
    final lib = write(
      pkg,
      'lib/z_s4_lib.dart',
      "import 's4_fit.dart';\nimport 's4_sink.dart';\npart 'a_s4_part.dart';\n"
          'void own() => take(Fit.contain);\n',
    );
    await Sanitizer().run([part.path, lib.path]);
    expect(part.readAsStringSync(), contains('take(.cover)'));
    expect(lib.readAsStringSync(), contains('take(.contain)'));
    expect(analyze(pkg, 'z_s4_lib.dart'), isNot(contains('UNUSED_IMPORT')));
  });

  test(
    'SS-I1 --skip=Type.member also covers prefixed and aliased spellings',
    () async {
      write(pkg, 'lib/sk_fit.dart', '''
enum Fit { cover, contain }
typedef Mode = Fit;
void take(Fit f) {}
''');
      final out = await sanitize(
        '''
import 'sk_fit.dart' as m;
import 'sk_fit.dart';
void a() => take(Fit.cover);
void b() => m.take(m.Fit.cover);
void c() => take(Mode.cover);
''',
        skips: {'Fit.cover'},
      );
      expect(out, contains('take(Fit.cover)'));
      expect(out, contains('m.Fit.cover'));
      expect(out, contains('Mode.cover'));
    },
  );

  test('SS-B7 generated header behind a BOM, in a block comment, or late', () {
    final bom = write(pkg, 'lib/bom.g.dart', '')
      ..writeAsBytesSync([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('// GENERATED CODE - DO NOT MODIFY BY HAND\n'),
      ]);
    final block = write(
      pkg,
      'lib/block.g.dart',
      '/* GENERATED CODE - DO NOT MODIFY BY HAND */\n',
    );
    final deep = write(
      pkg,
      'lib/late.g.dart',
      '${'// Licensed under the Apache License, Version 2.0.\n' * 40}'
          '// GENERATED CODE - DO NOT MODIFY BY HAND\n',
    );
    expect(Sanitizer.isGenerated(bom.path), isTrue);
    expect(Sanitizer.isGenerated(block.path), isTrue);
    expect(Sanitizer.isGenerated(deep.path), isTrue);
  });

  test('SS-B8 a rewrite keeps the UTF-8 BOM and CRLF line endings', () async {
    final file = write(pkg, 'lib/bom_keep.dart', '')
      ..writeAsBytesSync([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(
          'enum Fit { cover, contain }\r\nvoid t(Fit f) {}\r\n'
          'void r() => t(Fit.cover);\r\n',
        ),
      ]);
    await Sanitizer().run([file.path]);
    final bytes = file.readAsBytesSync();
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    expect(
      utf8.decode(bytes.skip(3).toList()),
      'enum Fit { cover, contain }\r\nvoid t(Fit f) {}\r\n'
      'void r() => t(.cover);\r\n',
    );
  });

  test('SS-B9 overlapping path arguments are processed once', () async {
    final dir = Directory(p.join(pkg.path, 'lib', 'dup'))..createSync();
    write(pkg, 'lib/dup/a.dart', '''
enum Fit { cover, contain }
void t(Fit f) {}
void r() => t(Fit.cover);
''');
    final result = await Sanitizer(dryRun: true)
        .run([dir.path, dir.path, '${dir.path}/.']);
    expect(result.convertedCount, 1);
    expect(result.files, hasLength(1));
  });

  test('SS-S3 a library with analysis errors is skipped by default', () async {
    const source =
        'enum Fit { cover }\nvoid t(Fit f) {}\nvoid r() => t(Fit.cover);\n'
        "int bad = '';\n";
    final file = write(pkg, 'lib/s3_errors.dart', source);
    final result = await Sanitizer().run([file.path]);
    expect(file.readAsStringSync(), source);
    expect(result.skippedWithErrors, [p.normalize(p.absolute(file.path))]);

    await Sanitizer(allowErrors: true).run([file.path]);
    expect(file.readAsStringSync(), contains('t(.cover)'));
  });

  test('SS-R1 two same-named classes are different static types', () async {
    write(pkg, 'lib/r1_b.dart', 'class X {\n  const X();\n}\n');
    write(
      pkg,
      'lib/r1_a.dart',
      "import 'r1_b.dart' as b;\nclass X extends b.X {\n  const X();\n}\n",
    );
    write(
      pkg,
      'lib/r1_g.dart',
      'class G<T> {\n  G.of(this.value);\n  T value;\n}\n',
    );
    final file = write(pkg, 'lib/r1_use.dart', '''
import 'r1_a.dart' as a;
import 'r1_b.dart' as b;
import 'r1_g.dart';
typedef AG = G<a.X>;
final G<b.X> g = AG.of(const a.X());
''');
    final result = await Sanitizer(
      dryRun: true,
      explain: true,
    ).run([file.path]);
    expect(result.convertedCount, 0);
    expect(result.files.single.kept.single, contains('r1_a.dart::X>'));
  });

  test('SS-R2 a rebind onto a @visibleForTesting member is refused', () async {
    final app = makePackage(
      'r2',
      'name: r2\nenvironment:\n  sdk: ^3.10.0\n'
          'dependencies:\n  meta: ^1.15.0\n',
    );
    addTearDown(() => app.deleteSync(recursive: true));
    final restricted = geoLibrary
        .replaceFirst('const factory', '@visibleForTesting const factory')
        .replaceFirst(
          'static const Geo',
          '@visibleForTesting static const Geo',
        );
    write(app, 'lib/geo.dart', "import 'package:meta/meta.dart';\n$restricted");
    final file = write(app, 'lib/use.dart', '''
import 'geo.dart';
void use(Geo g) {}
void run() {
  use(Box.all(1));
  use(Box.zero);
}
''');
    final result = await Sanitizer(
      dryRun: true,
      explain: true,
    ).run([file.path]);
    expect(result.files.single.kept, [
      '4: Box.all kept: rebinds to Geo.all, which is @visibleForTesting',
      '5: Box.zero kept: rebinds to Geo.zero, which is @visibleForTesting',
    ]);
  });

  group('SS-R3 pruning a part', () {
    /// A part whose two sites orphan both of its library's imports of
    /// `<tag>_fit.dart`; returns the library and the part.
    (File, File) partPrune(String tag, {String header = ''}) {
      write(
        pkg,
        'lib/${tag}_fit.dart',
        'enum Fit { cover }\nenum Mode { a }\n',
      );
      write(
        pkg,
        'lib/${tag}_sink.dart',
        "import '${tag}_fit.dart';\n"
            'void take(Fit f) {}\nvoid takeMode(Mode m) {}\n',
      );
      final lib = write(
        pkg,
        'lib/${tag}_lib.dart',
        "${header}import '${tag}_fit.dart' as f;\n"
            "import '${tag}_fit.dart' show Mode;\n"
            "import '${tag}_sink.dart';\n"
            "export '${tag}_fit.dart';\n"
            "part '${tag}_part.dart';\n",
      );
      final part = write(
        pkg,
        'lib/${tag}_part.dart',
        "part of '${tag}_lib.dart';\n"
            'void runPart() {\n  take(f.Fit.cover);\n  takeMode(Mode.a);\n}\n',
      );
      return (lib, part);
    }

    for (final (tag, why, header, excluded, onlyPart) in [
      ('r3x', 'excluded', '', true, false),
      (
        'r3g',
        'generated',
        '// GENERATED CODE - DO NOT MODIFY BY HAND\n',
        false,
        false,
      ),
      ('r3o', 'not among the given paths', '', false, true),
    ]) {
      test('never edits a library that is $why', () async {
        final (lib, part) = partPrune(tag, header: header);
        final libBefore = lib.readAsStringSync();
        final partBefore = part.readAsStringSync();
        final result = await Sanitizer(
          excludes: [if (excluded) '${tag}_lib.dart'],
          explain: true,
        ).run([if (!onlyPart) lib.path, part.path]);
        expect(lib.readAsStringSync(), libBefore);
        expect(part.readAsStringSync(), partBefore);
        expect(
          result.files.single.kept,
          everyElement(endsWith('would edit ${tag}_lib.dart, which is $why')),
        );
      });
    }

    test('reports every file it writes', () async {
      final (lib, part) = partPrune('r3w');
      final result = await Sanitizer(dryRun: true).run([lib.path, part.path]);
      expect(
        {for (final f in result.files) f.path: f.removedImports},
        {
          p.normalize(p.absolute(part.path)): 0,
          p.normalize(p.absolute(lib.path)): 2,
        },
      );
      expect(result.convertedCount, 2);
    });
  });
}
