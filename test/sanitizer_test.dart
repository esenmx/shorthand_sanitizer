import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:test/test.dart';

late Directory pkg;
int fileId = 0;

/// Writes [source] into the fixture package, sanitizes it, and returns the
/// resulting content (unchanged content when nothing converted).
Future<String> sanitize(
  String source, {
  Set<String> skips = const {},
  bool dryRun = false,
}) async {
  final file = File(p.join(pkg.path, 'lib', 'case_${fileId++}.dart'))
    ..writeAsStringSync(source);
  await Sanitizer(skips: skips, dryRun: dryRun).run([file.path]);
  return file.readAsStringSync();
}

void main() {
  setUpAll(() {
    pkg = Directory.systemTemp.createTempSync('shorthand_sanitizer_test');
    Directory(p.join(pkg.path, 'lib')).createSync();
    File(
      p.join(pkg.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.10.0\n');
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: pkg.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');
  });

  tearDownAll(() => pkg.deleteSync(recursive: true));

  test('enum values convert at witnessed slots', () async {
    final out = await sanitize('''
enum Fit { cover, contain }
Fit pick(bool b) => b ? Fit.cover : Fit.contain;
void use(Fit f) {}
void main() {
  use(Fit.cover);
  final Fit f = switch (1) { 1 => Fit.cover, _ => Fit.contain };
  if (f == Fit.contain) return;
}
''');
    expect(out, isNot(contains('Fit.cover')));
    expect(out, isNot(contains('Fit.contain')));
    expect(out, contains('b ? .cover : .contain'));
    expect(out, contains('use(.cover)'));
    expect(out, contains('1 => .cover'));
    expect(out, contains('== .contain'));
  });

  test(
    'static const fields, getters, methods, named/factory ctors convert',
    () async {
      final out = await sanitize(r'''
class Insets {
  const Insets.all(this.v);
  factory Insets.zeroed() => const Insets.all(0);
  final double v;
  static const Insets zero = Insets.all(0);
  static Insets get unit => const Insets.all(1);
  static Insets parse(String s) => Insets.all(double.parse(s));
}
void main() {
  final Insets a = Insets.all(4);
  final Insets z = Insets.zero;
  final Insets u = Insets.unit;
  final Insets p = Insets.parse('2');
  final Insets f = Insets.zeroed();
  print('$a $z $u $p $f');
}
''');
      expect(out, contains('final Insets a = .all(4)'));
      expect(out, contains('final Insets z = .zero'));
      expect(out, contains('final Insets u = .unit'));
      expect(out, contains("final Insets p = .parse('2')"));
      expect(out, contains('final Insets f = .zeroed()'));
      expect(out, contains('static const Insets zero = .all(0)'));
      // explicit `const` before the ctor — the shorthand node starts at `const`
      expect(out, contains('static Insets get unit => const .all(1)'));
      expect(out, contains('factory Insets.zeroed() => const .all(0)'));
    },
  );

  test('unwitnessed contexts stay prefixed', () async {
    const source = r'''
enum Fit { cover, contain }
void main() {
  final Object o = Fit.cover;
  final list = [Fit.cover];
  print('$o $list');
}
''';
    final out = await sanitize(source);
    expect(out, contains('final Object o = Fit.cover'));
    expect(out, contains('[Fit.cover]'));
  });

  test(
    'member on sibling namespace stays prefixed (Colors.red analog)',
    () async {
      const source = '''
class Color {
  const Color(this.v);
  final int v;
}
class Palette {
  static const Color red = Color(1);
}
void main() {
  const Color c = Palette.red;
  print(c);
}
''';
      final out = await sanitize(source);
      expect(out, contains('const Color c = Palette.red'));
    },
  );

  test(
    'silent rebind to same-named static on context type is refused',
    () async {
      const source = '''
class Base {
  const Base.id(this.tag);
  final String tag;
  static const Base a = Base.id('base');
}
class Sub extends Base {
  const Sub.id() : super.id('sub');
  static const Sub a = Sub.id();
}
void main() {
  const Base x = Sub.a;
  print(x.tag);
}
''';
      final out = await sanitize(source);
      // `.a` compiles but resolves to Base.a — a different constant. Must stay.
      expect(out, contains('const Base x = Sub.a'));
    },
  );

  test('Enum.values never converts — context is List, not the enum', () async {
    const source = '''
enum Fit { cover, contain }
List<Fit> all() => Fit.values;
void main() {
  for (final f in Fit.values) {
    print(f);
  }
  final List<Fit> l = Fit.values;
  print(all() == l);
}
''';
    final out = await sanitize(source);
    expect('Fit.values'.allMatches(out).length, 3);
  });

  test(
    'operator +: LHS keeps prefix (no context), RHS argument converts',
    () async {
      const source = '''
class Pad {
  const Pad.all(this.v);
  const Pad.only(this.v);
  final double v;
  Pad operator +(Pad other) => Pad.all(v + other.v);
}
void main() {
  final Pad p = Pad.all(1) + Pad.only(2);
  print(p.v);
}
''';
      final out = await sanitize(source);
      expect(out, contains('final Pad p = Pad.all(1) + .only(2)'));
      expect(
        out,
        contains('=> .all(v + other.v)'),
      ); // return-typed body converts
    },
  );

  test(
    'redirecting-factory forwarder is refused (EdgeInsetsGeometry analog)',
    () async {
      const source = '''
abstract class Geo {
  const factory Geo.all(double v) = Box.all;
}
class Box implements Geo {
  const Box.all(this.v);
  final double v;
}
void take(Geo g) {}
void main() => take(Box.all(1));
''';
      final out = await sanitize(source);
      // `.all(1)` binds Geo.all — a different element, even if it
      // redirects back.
      expect(out, contains('take(Box.all(1))'));
    },
  );

  test('skip list holds Type.member and bare member forms', () async {
    const source = r'''
enum Fit { cover, contain }
void main() {
  final Fit a = Fit.cover;
  final Fit b = Fit.contain;
  print('$a $b');
}
''';
    final out = await sanitize(source, skips: {'Fit.cover'});
    expect(out, contains('final Fit a = Fit.cover'));
    expect(out, contains('final Fit b = .contain'));
  });

  test('prunes an import the dropped prefix orphaned', () async {
    // `Dep` is supplied only by dep.dart and appears only as the prefix of
    // `Dep.instance`, whose slot is witnessed by Sink's constructor param
    // (from sink.dart). Collapsing to `.instance` leaves dep.dart's import
    // with no referent — it must be pruned; sink.dart's stays.
    File(p.join(pkg.path, 'lib', 'dep.dart')).writeAsStringSync('''
class Dep {
  const Dep._();
  static const Dep instance = Dep._();
}
''');
    File(p.join(pkg.path, 'lib', 'sink.dart')).writeAsStringSync('''
import 'dep.dart';
class Sink {
  Sink(this.d);
  final Dep d;
}
''');
    final file = File(p.join(pkg.path, 'lib', 'consumer.dart'))
      ..writeAsStringSync('''
import 'dep.dart';
import 'sink.dart';
final sink = Sink(Dep.instance);
''');
    final result = await Sanitizer().run([file.path]);
    final out = file.readAsStringSync();
    expect(out, contains('Sink(.instance)'));
    expect(out, isNot(contains("import 'dep.dart';")));
    expect(out, contains("import 'sink.dart';")); // still used, kept
    expect(result.removedImportCount, 1);
  });

  test('leaves a pre-existing unused import alone', () async {
    // dep2.dart stays used (Box), so nothing is orphaned; dart:async is unused
    // before we touch anything (the user's, not ours) — it must survive.
    File(p.join(pkg.path, 'lib', 'dep2.dart')).writeAsStringSync('''
class Dep2 {
  const Dep2._();
  static const Dep2 instance = Dep2._();
}
class Box {
  Box(this.d);
  final Dep2 d;
}
''');
    final file = File(p.join(pkg.path, 'lib', 'consumer2.dart'))
      ..writeAsStringSync('''
import 'dart:async';
import 'dep2.dart';
final box = Box(Dep2.instance);
''');
    await Sanitizer().run([file.path]);
    final out = file.readAsStringSync();
    expect(out, contains('Box(.instance)'));
    expect(out, contains("import 'dart:async';")); // pre-existing unused, kept
  });

  test('dry run reports without writing', () async {
    const source = '''
enum Fit { cover }
void main() {
  final Fit f = Fit.cover;
  print(f);
}
''';
    final out = await sanitize(source, dryRun: true);
    expect(out, source);
  });

  test('generated detection reads the header, not the filename', () {
    String write(String name, String content) {
      final f = File(p.join(pkg.path, 'lib', name))..writeAsStringSync(content);
      return f.path;
    }

    // build_runner-style marker — skipped whatever the name.
    expect(
      Sanitizer.isGenerated(
        write('m.g.dart', '// GENERATED CODE - DO NOT MODIFY BY HAND\n'),
      ),
      isTrue,
    );
    // FlutterFire CLI: single-dot name, still generated.
    expect(
      Sanitizer.isGenerated(
        write(
          'firebase_options.dart',
          '// File generated by FlutterFire CLI.\n',
        ),
      ),
      isTrue,
    );
    // Handwritten widget preview: double-dot name, NOT generated.
    expect(
      Sanitizer.isGenerated(
        write('page.preview.dart', "import 'page.dart';\n"),
      ),
      isFalse,
    );
  });

  test('prose about regeneration is not a generated header', () {
    String write(String name, String content) {
      final f = File(p.join(pkg.path, 'lib', name))..writeAsStringSync(content);
      return f.path;
    }

    // The stem `generat` appears, but as prose in a handwritten banner.
    expect(
      Sanitizer.isGenerated(
        write(
          'foot_slab.dart',
          '// The foot slab regenerates its tear line when the tint changes.\n',
        ),
      ),
      isFalse,
    );
    // A marker below the banner describes the code, not the file.
    expect(
      Sanitizer.isGenerated(
        write(
          'runner.dart',
          "import 'dart:io';\n\n"
              '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
              'const template = 1;\n',
        ),
      ),
      isFalse,
    );
    // Real banners still register, including past a leading license block.
    expect(
      Sanitizer.isGenerated(
        write('m.pb.dart', '//\n// Generated code. Do not modify.\n'),
      ),
      isTrue,
    );
    expect(
      Sanitizer.isGenerated(
        write('p.g.dart', '// Autogenerated from Pigeon (v9.2.5).\n'),
      ),
      isTrue,
    );
    expect(
      Sanitizer.isGenerated(
        write(
          'strings.g.dart',
          '// Copyright 2026\n\n/// Generated file. Do not edit.\n',
        ),
      ),
      isTrue,
    );
  });

  test('a header mentioning regeneration still gets sanitized', () async {
    final out = await sanitize('''
// The tear line regenerates whenever the tint changes.
enum Fit { cover }
Fit f() => Fit.cover;
''');
    expect(out, contains('=> .cover'));
  });

  test('handwritten *.preview.dart files are sanitized', () async {
    final file = File(p.join(pkg.path, 'lib', 'card.preview.dart'))
      ..writeAsStringSync('''
enum Fit { cover, contain }
Fit preview() => Fit.cover;
''');
    await Sanitizer().run([file.path]);
    expect(file.readAsStringSync(), contains('=> .cover'));
  });

  test('--exclude globs and generated headers keep files untouched', () async {
    const source = '''
enum Fit { cover }
Fit f() => Fit.cover;
''';
    final excluded = File(p.join(pkg.path, 'lib', 'firebase_options.dart'))
      ..writeAsStringSync(source);
    final generated = File(p.join(pkg.path, 'lib', 'options.dart'))
      ..writeAsStringSync('// File generated by FlutterFire CLI.\n$source');
    final normal = File(p.join(pkg.path, 'lib', 'normal_case.dart'))
      ..writeAsStringSync(source);
    await Sanitizer(
      excludes: ['firebase_options.dart'],
    ).run([excluded.path, generated.path, normal.path]);
    expect(excluded.readAsStringSync(), contains('Fit.cover'));
    expect(generated.readAsStringSync(), contains('Fit.cover'));
    expect(normal.readAsStringSync(), contains('=> .cover'));
  });

  test('sanitized output keeps compiling and means the same thing', () async {
    final file = File(p.join(pkg.path, 'lib', 'roundtrip.dart'))
      ..writeAsStringSync(r'''
enum Fit { cover, contain }
class Insets {
  const Insets.all(this.v);
  final double v;
  static const Insets zero = Insets.all(0);
}
String render() {
  final Insets a = Insets.all(4);
  final Insets z = Insets.zero;
  final Fit f = Fit.cover;
  final Object o = Fit.contain;
  return '${a.v} ${z.v} $f $o';
}
void main() => print(render());
''');
    final before = Process.runSync('dart', [
      'run',
      file.path,
    ], workingDirectory: pkg.path);
    expect(before.exitCode, 0, reason: '${before.stderr}');
    await Sanitizer().run([file.path]);
    final after = Process.runSync('dart', [
      'run',
      file.path,
    ], workingDirectory: pkg.path);
    expect(after.exitCode, 0, reason: '${after.stderr}');
    expect(after.stdout, before.stdout);
  });

  test('abstract interface class static const converts', () async {
    final out = await sanitize('''
abstract interface class TextScaler {
  static const TextScaler noScaling = _NoScalingTextScaler();
}
class _NoScalingTextScaler implements TextScaler {
  const _NoScalingTextScaler();
}
void main() {
  const TextScaler ts = TextScaler.noScaling;
  print(ts);
}
''');
    expect(out, contains('const TextScaler ts = .noScaling;'));
  });

  test('static const on prefixed-imported class converts', () async {
    File(p.join(pkg.path, 'lib', 'dep_class.dart')).writeAsStringSync('''
class Scaler {
  const Scaler.all();
  static const Scaler noScaling = Scaler.all();
}
''');
    final out = await sanitize('''
import 'dep_class.dart' as p;
void main() {
  const p.Scaler ts = p.Scaler.noScaling;
  print(ts);
}
''');
    expect(out, contains('const p.Scaler ts = .noScaling;'));
  });

  test('static method on prefixed-imported class converts', () async {
    File(p.join(pkg.path, 'lib', 'dep_class2.dart')).writeAsStringSync('''
class Scaler {
  const Scaler.all();
  static Scaler scale(double v) => Scaler.all();
}
''');
    final out = await sanitize('''
import 'dep_class2.dart' as p;
void main() {
  const p.Scaler ts = p.Scaler.scale(5);
  print(ts);
}
''');
    expect(out, contains('const p.Scaler ts = .scale(5);'));
  });

  test('static const on type alias / typedef converts', () async {
    final out = await sanitize('''
class BaseScaler {
  const BaseScaler.all();
  static const BaseScaler noScaling = BaseScaler.all();
}
typedef Scaler = BaseScaler;
void main() {
  const Scaler ts = Scaler.noScaling;
  print(ts);
}
''');
    expect(out, contains('const Scaler ts = .noScaling;'));
  });

  group('rebind onto a const alias', () {
    // `Geo` mirrors Flutter's AlignmentGeometry: it re-declares its subtype's
    // constants as its own (`topCenter`, `center`) and forwards a factory
    // (`all`). A `Geo` slot therefore binds every shorthand to `Geo`, never to
    // the `Align`/`Directional` the source names.
    setUpAll(() {
      File(p.join(pkg.path, 'lib', 'geometry.dart')).writeAsStringSync('''
abstract class Geo {
  static const Geo topCenter = Align.topCenter;
  static const Geo center = Align.center;
  static final Geo lazy = Align.lazy;
  static Geo all(double v) => Align.all(v);
}
class Align implements Geo {
  const Align(this.v);
  final double v;
  static const Align topCenter = Align(0);
  static const Align center = Align(5);
  static const Align lazy = Align(7);
  static Align all(double v) => Align(v);
}
class Directional implements Geo {
  const Directional(this.v);
  final double v;
  static const Directional center = Directional(5);
}
''');
    });

    test(
      'const alias converts — canonicalization makes it the same object',
      () async {
        final out = await sanitize('''
import 'geometry.dart';
void main() {
  const Geo g = Align.topCenter;
  print(g);
}
''');
        expect(out, contains('const Geo g = .topCenter;'));
      },
    );

    test('non-const forwarder stays prefixed', () async {
      final out = await sanitize('''
import 'geometry.dart';
void main() {
  final Geo g = Align.all(3);
  print(g);
}
''');
      // `.all(3)` binds Geo.all, which allocates a fresh instance — no
      // constant value, so nothing proves the two equivalent.
      expect(out, contains('final Geo g = Align.all(3);'));
    });

    test('non-const `static final` alias stays prefixed', () async {
      final out = await sanitize('''
import 'geometry.dart';
void main() {
  final Geo g = Align.lazy;
  print(g);
}
''');
      // Geo.lazy is `final`, not `const` — no compile-time value, so both
      // sides being the same object is unprovable even though they are.
      expect(out, contains('final Geo g = Align.lazy;'));
    });

    test('same-valued constant of another type stays prefixed', () async {
      final out = await sanitize('''
import 'geometry.dart';
void main() {
  const Geo g = Directional.center;
  print(g);
}
''');
      // Directional(5) and Geo.center's Align(5) carry identical field state;
      // only their type tells them apart, and it must.
      expect(out, contains('const Geo g = Directional.center;'));
    });

    test('alias declared in the file under rewrite stays prefixed', () async {
      // Its value would be read out of the speculative text — circular, since
      // the rewrite could be what changed the value being judged.
      final out = await sanitize('''
abstract class Box {
  static const Box wide = Fixed.wide;
}
class Fixed implements Box {
  const Fixed(this.v);
  final int v;
  static const Fixed wide = Fixed(1);
}
void main() {
  const Box b = Fixed.wide;
  print(b);
}
''');
      expect(out, contains('static const Box wide = Fixed.wide;'));
      expect(out, contains('const Box b = Fixed.wide;'));
    });

    test('converted alias stays identical to what the source named', () async {
      final file = File(p.join(pkg.path, 'lib', 'alias_roundtrip.dart'))
        ..writeAsStringSync('''
import 'geometry.dart';
void main() {
  const Geo g = Align.topCenter;
  print(identical(g, Align.topCenter));
}
''');
      await Sanitizer().run([file.path]);
      expect(file.readAsStringSync(), contains('const Geo g = .topCenter;'));
      final run = Process.runSync('dart', [
        'run',
        file.path,
      ], workingDirectory: pkg.path);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(run.stdout.toString().trim(), 'true');
    });
  });

  test(
    'receiver-position static access on a further member stays prefixed',
    () async {
      final out = await sanitize('''
class Scaler {
  const Scaler.all();
  static const Scaler noScaling = Scaler.all();
  int get pixels => 3;
}
void main() {
  final int px = Scaler.noScaling.pixels;
  print(px);
}
''');
      // `Scaler.noScaling` is the receiver of `.pixels` — dropping the prefix
      // would yield `.noScaling.pixels`, an illegal shorthand position.
      expect(out, contains('Scaler.noScaling.pixels'));
    },
  );

  test(
    'valid sites survive unconvertible neighbours in the same call',
    () async {
      // Every statement mixes one convertible site with two that can never
      // convert — namespace-class statics landing in slots of an unrelated
      // type. Attribution by proximity blamed the valid site for its
      // neighbours' errors and recovered one per round, so all but the first
      // stayed prefixed.
      const clusters = 8;
      const cluster =
          '  consume(Holders.make(count: Numbers.one, label: Labels.a)\n'
          '      .pick(t: flagged ? Tag.marked : null));';
      final rows = List.filled(clusters, cluster).join('\n');
      final out = await sanitize('''
final class Tag {
  const Tag._();
  static const Tag marked = Tag._();
}
final class Holder {
  const Holder();
  Tag? pick({Tag? t}) => t;
}
abstract final class Numbers {
  static const int one = 1;
}
abstract final class Labels {
  static const String a = 'x';
}
abstract final class Holders {
  static Holder make({int? count, String? label}) => const Holder();
}
void consume(Tag? t) {}
void main() {
  const flagged = true;
$rows
}
''');

      expect('.pick(t: flagged ? .marked'.allMatches(out).length, clusters);
      expect(out, isNot(contains('Tag.marked : null')));
      // The neighbours are genuinely unconvertible and must stay as written.
      expect('Numbers.one'.allMatches(out).length, clusters);
      expect('Labels.a'.allMatches(out).length, clusters);
    },
  );

  test('skips a package pinned below the dot-shorthand floor', () async {
    final old = Directory.systemTemp.createTempSync('shorthand_floor');
    addTearDown(() => old.deleteSync(recursive: true));
    Directory(p.join(old.path, 'lib')).createSync();
    File(
      p.join(old.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: old_fixture\nenvironment:\n  sdk: ^3.9.0\n');
    final get = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: old.path);
    if (get.exitCode != 0) throw StateError('pub get failed: ${get.stderr}');

    final file = File(p.join(old.path, 'lib', 'case.dart'))
      ..writeAsStringSync('''
enum Fit { cover }
Fit f() => Fit.cover;
''');
    final result = await Sanitizer().run([file.path]);

    // Untouched, and the run says why rather than reporting an empty success.
    expect(file.readAsStringSync(), contains('Fit.cover'));
    expect(result.skippedBelowFloor, {'3.9': 1});
    expect(result.convertedCount, 0);
  });

  test('CLI --version constant matches pubspec version', () {
    final pubspecVersion = RegExp(
      r'^version:\s*(.+)$',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1)?.trim();
    final cliVersion = RegExp(r"_version\s*=\s*'([^']+)'")
        .firstMatch(File(p.join('bin', 'dotsan.dart')).readAsStringSync())
        ?.group(1);
    expect(cliVersion, equals(pubspecVersion));
  });
}
