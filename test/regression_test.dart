// Sweep 2026-10-03 regressions, keyed by finding ID (`SS-<ID>` in each test
// name). Each one failed on 0.9.0.
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
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
  check(because: 'fixture has errors', result.skippedWithErrors).isEmpty();
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

/// A part whose two sites orphan both of its library's imports of
/// `<tag>_fit.dart`; returns the library and the part.
(File, File) partPrune(String tag, {String header = ''}) {
  write(pkg, 'lib/${tag}_fit.dart', 'enum Fit { cover }\nenum Mode { a }\n');
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
    check(out).contains('IntG.of(1)');
    check(out).contains('IntList.filled(1, 0)');
  });

  test('SS-B2 licensed rebind must not change a cascade target type', () async {
    // Box.all(1)..tag() dispatches BoxTag; .all(1) is typed Geo -> GeoTag.
    final out = await sanitize('''
import 'geo.dart';
final Geo a = Box.all(1)..tag();
final Geo b = Box.zero..tag();
''');
    check(out).contains('Box.all(1)..tag()');
    check(out).contains('Box.zero..tag()');
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
    check(out).contains('g = Box.all(2);');
  });

  test('SS-B3 a new error matching a baseline message is not masked', () async {
    // The cascade is refused by the typed-slot rule before the multiset check
    // runs; e2e `duplicate_info` pins the multiset. allowErrors only keeps
    // the pre-existing error from skipping the file.
    final out = await sanitize('''
import 'geo.dart';
void pre(Geo g) => g.boxOnly(); // pre-existing error, same message
final Geo fresh = Box.all(1)..boxOnly();
''', allowErrors: true);
    check(out).contains('Box.all(1)..boxOnly()');
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
    check(file.readAsStringSync()).equals(source);
    check(result.skippedUnconfigured)
        .deepEquals({p.normalize(p.absolute(old.path)): 1});
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
      check(main.readAsStringSync()).equals(source);
      check(
        result.skippedUnconfigured,
      ).deepEquals({p.normalize(p.absolute(p.join(outer.path, 'example'))): 1});
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
    check(part.readAsStringSync()).contains('take(.cover)');
    check(analyze(pkg, 'po_lib.dart'))
        .not((it) => it.contains('UNUSED_IMPORT'));
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
    check(analyze(app, 'use.dart'))
        .not((it) => it.contains('DEPRECATED_MEMBER_USE'));
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
    check(part.readAsStringSync()).contains('take(.cover)');
    check(lib.readAsStringSync()).contains('take(.contain)');
    check(analyze(pkg, 'z_s4_lib.dart'))
        .not((it) => it.contains('UNUSED_IMPORT'));
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
      check(out).contains('take(Fit.cover)');
      check(out).contains('m.Fit.cover');
      check(out).contains('Mode.cover');
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
      '${'// Licensed under the Apache License, Version 2.0.\n' * 120}'
          '// GENERATED CODE - DO NOT MODIFY BY HAND\n',
    );
    check(Sanitizer.isGenerated(bom.path)).isTrue();
    check(Sanitizer.isGenerated(block.path)).isTrue();
    check(Sanitizer.isGenerated(deep.path)).isTrue();
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
    check(bytes.take(3)).deepEquals([0xEF, 0xBB, 0xBF]);
    check(utf8.decode(bytes.skip(3).toList())).equals(
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
    check(result.convertedCount).equals(1);
    check(result.files).length.equals(1);
  });

  test('SS-S3 a library with analysis errors is skipped by default', () async {
    const source =
        'enum Fit { cover }\nvoid t(Fit f) {}\nvoid r() => t(Fit.cover);\n'
        "int bad = '';\n";
    final file = write(pkg, 'lib/s3_errors.dart', source);
    final result = await Sanitizer().run([file.path]);
    check(file.readAsStringSync()).equals(source);
    check(result.skippedWithErrors)
        .deepEquals([p.normalize(p.absolute(file.path))]);

    await Sanitizer(allowErrors: true).run([file.path]);
    check(file.readAsStringSync()).contains('t(.cover)');
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
    check(result.convertedCount).equals(0);
    check(result.files.single.kept.single).equals(
      '5: AG.of kept: changes the static type from G<X> to a different G<X>',
    );
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
    check(result.files.single.kept).deepEquals([
      '4: Box.all kept: rebinds to Geo.all, which is @visibleForTesting',
      '5: Box.zero kept: rebinds to Geo.zero, which is @visibleForTesting',
    ]);
  });

  group('SS-R3 pruning a part', () {
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
        check(lib.readAsStringSync()).equals(libBefore);
        check(part.readAsStringSync()).equals(partBefore);
        check(result.files.single.kept).every(
          (it) => it.endsWith('would edit ${tag}_lib.dart, which is $why'),
        );
      });
    }

    test('reports every file it writes', () async {
      final (lib, part) = partPrune('r3w');
      final result = await Sanitizer(dryRun: true).run([lib.path, part.path]);
      check({for (final f in result.files) f.path: f.removedImports})
          .deepEquals({
            p.normalize(p.absolute(part.path)): 0,
            p.normalize(p.absolute(lib.path)): 2,
          });
      check(result.convertedCount).equals(2);
    });
  });

  test('SS-R4 a read-only unit leaves its whole library unchanged', () async {
    final (lib, part) = partPrune('r4');
    final libBefore = lib.readAsStringSync();
    final partBefore = part.readAsStringSync();
    Process.runSync('chmod', ['444', lib.path]);
    addTearDown(() => Process.runSync('chmod', ['644', lib.path]));

    final result = await Sanitizer().run([lib.path, part.path]);
    check(part.readAsStringSync()).equals(partBefore);
    check(lib.readAsStringSync()).equals(libBefore);
    check(result.convertedCount).equals(0);
    check(result.writeFailures.single.path)
        .equals(p.normalize(p.absolute(lib.path)));
  }, testOn: '!windows');

  test(
    'SS-R5 pruning keeps the import the user had already left unused',
    () async {
      write(pkg, 'lib/r5_fit.dart', 'enum Fit { cover }\nenum Mode { a }\n');
      write(
        pkg,
        'lib/r5_sink.dart',
        "import 'r5_fit.dart';\nvoid takeMode(Mode m) {}\n",
      );
      final out = await sanitize('''
import 'r5_fit.dart' show Mode;
import 'r5_fit.dart' as keep_me;
import 'r5_sink.dart';

void run() => takeMode(Mode.a);
''');
      check(out).equals('''
import 'r5_fit.dart' as keep_me;
import 'r5_sink.dart';

void run() => takeMode(.a);
''');
    },
  );

  test(
    'R3-SS-4 a library reached through a symlink is still in scope',
    () async {
      final (lib, part) = partPrune('r34');
      final alias = Directory.systemTemp.createTempSync('dotsan_alias');
      addTearDown(() => alias.deleteSync(recursive: true));
      final link = Link(p.join(alias.path, 'pkg'))..createSync(pkg.path);
      final result = await Sanitizer(dryRun: true)
          .run([p.join(link.path, 'lib', p.basename(lib.path)), part.path]);
      check(result.convertedCount).equals(2);
    },
    testOn: '!windows',
  );

  group('R3-SS-n1 a library processed after its part reports input lines', () {
    for (final dryRun in [true, false]) {
      test(dryRun ? 'in a dry run' : 'in a write', () async {
        final tag = dryRun ? 'n1d' : 'n1w';
        write(pkg, 'lib/${tag}_fit.dart', 'enum Fit { cover, contain }\n');
        write(pkg, 'lib/${tag}_mode.dart', 'enum Mode { on, off }\n');
        write(
          pkg,
          'lib/${tag}_use.dart',
          "import '${tag}_fit.dart';\nimport '${tag}_mode.dart';\n"
              'void take(Fit f) {}\nvoid set(Mode m) {}\n',
        );
        final part = write(
          pkg,
          'lib/a_${tag}_part.dart',
          "part of 'z_${tag}_lib.dart';\nvoid run() => take(Fit.cover);\n",
        );
        final lib = write(
          pkg,
          'lib/z_${tag}_lib.dart',
          "import '${tag}_fit.dart';\n"
              "import '${tag}_use.dart';\n"
              "import '${tag}_mode.dart';\n"
              "part 'a_${tag}_part.dart';\n"
              '\n'
              'void own() => set(Mode.on);\n',
        );
        final result = await Sanitizer(dryRun: dryRun)
            .run([part.path, lib.path]);
        final own = result.files.singleWhere(
          (f) => p.basename(f.path) == p.basename(lib.path),
        );
        check(own.converted).deepEquals(['6: Mode.on -> .on']);
        check([for (final i in own.prunedImports) i.description]).deepEquals([
          "1: import '${tag}_fit.dart' -> removed",
          "3: import '${tag}_mode.dart' -> removed",
        ]);
      });
    }
  });

  group('R3-SS-n1 two parts prune a headed library before it runs', () {
    for (final dryRun in [true, false]) {
      test(dryRun ? 'in a dry run' : 'in a write', () async {
        final tag = dryRun ? 'n1hd' : 'n1hw';
        final fit = '${tag}_fit_with_a_rather_long_file_name.dart';
        write(pkg, 'lib/$fit', 'enum Fit { cover }\n');
        write(pkg, 'lib/${tag}_mode.dart', 'enum Mode { on }\n');
        write(pkg, 'lib/${tag}_tone.dart', 'enum Tone { warm }\n');
        write(pkg, 'lib/${tag}_keep.dart', 'enum Keep { k }\n');
        write(
          pkg,
          'lib/${tag}_use.dart',
          "import '$fit';\nimport '${tag}_mode.dart';\n"
              "import '${tag}_tone.dart';\n"
              'void take(Fit f) {}\nvoid set(Mode m) {}\n'
              'void tint(Tone t) {}\n',
        );
        final partA = write(
          pkg,
          'lib/a_${tag}_part.dart',
          "part of 'z_${tag}_lib.dart';\nvoid runA() => take(Fit.cover);\n",
        );
        final partB = write(
          pkg,
          'lib/b_${tag}_part.dart',
          "part of 'z_${tag}_lib.dart';\nvoid runB() => tint(Tone.warm);\n",
        );
        final lib = write(
          pkg,
          'lib/z_${tag}_lib.dart',
          '/// Lib doc.\n'
              "import '$fit';\n"
              '\n'
              "import '${tag}_mode.dart';\n"
              "import '${tag}_use.dart';\n"
              "import '${tag}_tone.dart';\n"
              "import '${tag}_keep.dart';\n"
              "part 'a_${tag}_part.dart';\n"
              "part 'b_${tag}_part.dart';\n"
              '\n'
              'void own() => set(Mode.on);\n'
              'final k = Keep.k;\n',
        );
        final result = await Sanitizer(
          dryRun: dryRun,
          explain: true,
        ).run([partA.path, partB.path, lib.path]);
        final own = result.files.singleWhere(
          (f) => p.basename(f.path) == p.basename(lib.path),
        );
        check([for (final s in own.sites) (s.line, s.column, s.before)])
            .deepEquals([(11, 19, 'Mode.on'), (12, 11, 'Keep.k')]);
        check(own.kept).deepEquals(['12: Keep.k kept: no context type']);
        check([for (final i in own.prunedImports) i.description]).deepEquals([
          "2: import '$fit' -> removed",
          "4: import '${tag}_mode.dart' -> removed",
          "6: import '${tag}_tone.dart' -> removed",
        ]);
      });
    }
  });

  test(
    'R3-SS-n2 a generic forwarder with renamed positionals converts',
    () async {
      final out = await sanitize('''
abstract class Geo<T> {
  const factory Geo.pair(T a) = Box<T>.pair;
}
class Box<T> implements Geo<T> {
  const Box.pair(this.v);
  final T v;
}
void take(Geo<int> g) {}
void main() => take(Box.pair(1));
''');
      check(out).contains('take(.pair(1))');
    },
  );

  test('silently prunes orphaned identifier from show combinator without '
      'reporting a removed import', () async {
    write(
      pkg,
      'lib/show_defs.dart',
      'enum Fit { cover }\nenum Mode { a }\nenum Unused { u }\n'
          'void take(Fit f, Mode m) {}\n',
    );
    final file = write(pkg, 'lib/show_use.dart', '''
import 'show_defs.dart' show Fit, Mode, Unused, take;

void run(Mode m) => take(Fit.cover, m);
''');
    final result = await Sanitizer().run([file.path]);
    check(result.convertedCount).equals(1);
    check(result.removedImportCount).equals(0);
    final out = file.readAsStringSync();
    // `Fit` is pruned; pre-existing unused `Unused` and used `Mode`, `take`
    // stay untouched.
    check(out).contains("import 'show_defs.dart' show Mode, Unused, take;");
    check(out).contains('take(.cover, m);');
  });

  test('converts licensed rebinds in closure returns, factory bodies, records, '
      'patterns, ?? LHS, and setter/cascade assignments', () async {
    final out = await sanitize('''
import 'geo.dart';

enum Fit { cover, contain }

Geo runGeo(Geo Function() fn) => fn();

class FactoryItem {
  const FactoryItem.raw(this.v);
  factory FactoryItem.zero() => const FactoryItem.raw(0);
  factory FactoryItem.block() {
    return const FactoryItem.raw(1);
  }
  final int v;
}

class Holder {
  Geo prop = const Geo();
}

Geo? maybeGeo() => Box.zero;

String testPatterns(Fit f, int x) => switch ((f, x)) {
  (== Fit.cover, _) => 'eq',
  (Fit.contain, _) when f == Fit.contain => 'const',
  _ => 'other',
};

void run(Holder h, Fit f) {
  assert(f != Fit.cover);
  final Geo fromClosure = runGeo(() => Box.all(1));
  final Geo fromBlockClosure = runGeo(() {
    return Box.all(2);
  });
  final (Geo, {Geo named}) rec = (Box.all(3), named: Box.zero);
  final Geo lhsCoalesce = maybeGeo() ?? Box.all(4);
  final Fit lhsFit = (null as Fit?) ?? Fit.cover;
  final untypedCoalesce = maybeGeo() ?? Geo.all(5);
  h.prop = Box.all(6);
  h..prop = Box.zero;
  final untypedClosure = () => Box.all(7);
  print([
    fromClosure,
    fromBlockClosure,
    rec,
    lhsCoalesce,
    lhsFit,
    untypedCoalesce,
    untypedClosure(),
    testPatterns(Fit.cover, 1),
    FactoryItem.zero(),
    FactoryItem.block(),
  ]);
}
''');
    check(out).contains('factory FactoryItem.zero() => const .raw(0);');
    check(out).contains('return const .raw(1);');
    check(out).contains('assert(f != .cover);');
    check(out).contains('runGeo(() => .all(1))');
    check(out).contains('return .all(2);');
    check(out).contains('(.all(3), named: .zero)');
    check(out).contains('maybeGeo() ?? .all(4)');
    check(out).contains('(null as Fit?) ?? .cover');
    check(out).contains('maybeGeo() ?? .all(5)');
    check(out).contains('h.prop = .all(6);');
    check(out).contains('h..prop = .zero;');
    check(out).contains('final untypedClosure = () => Box.all(7);');
    check(out).contains('(== .cover, _) =>');
    check(out).contains('(.contain, _) when f == .contain =>');
  });

  test(
    'converts same-type static getter selector chains and preserves comments '
    'inside prefix',
    () async {
      final out = await sanitize('''
class Side {
  const Side(this.w);
  final double w;
  static const Side none = Side(0);
  Side copyWith({double? w}) => Side(w ?? this.w);
}

void main() {
  final Side a = Side.none.copyWith(w: 2);
  final Side b = Side /* keep comment */ .none;
  print([a, b]);
}
''');
      check(out).contains('final Side a = .none.copyWith(w: 2);');
      check(out).contains('final Side b = Side /* keep comment */ .none;');
    },
  );
}
