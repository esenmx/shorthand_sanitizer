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
  final result = await Sanitizer(skips: skips, dryRun: dryRun).run([file.path]);
  // A fixture with an analysis error is skipped whole: the assertion would
  // pass without testing anything.
  expect(result.skippedWithErrors, isEmpty, reason: 'fixture has errors');
  return file.readAsStringSync();
}

void main() {
  setUpAll(() {
    pkg = Directory.systemTemp.createTempSync('shorthand_sanitizer_test');
    Directory(p.join(pkg.path, 'lib')).createSync();
    const spec = 'name: fixture\nenvironment:\n  sdk: ^3.10.0\n';
    File(p.join(pkg.path, 'pubspec.yaml')).writeAsStringSync(spec);
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

  test('nested args convert when every outer ctor is context-less', () async {
    // Token-file shape: every declaration is an inferred `static const`
    // wrapping a nested ctor. Round one drops all candidates — the
    // context-less outer starves its own argument — so only a recovery
    // pass that runs from an empty verified base can rescue the inners.
    final out = await sanitize('''
class Item {
  const Item.named(this.v);
  final int v;
}
class Wrap {
  const Wrap.all(Item item) : first = item;
  final Item first;
}
class Tokens {
  static const a = Wrap.all(Item.named(1));
  static const b = Wrap.all(Item.named(2));
}
''');
    expect(out, contains('static const a = Wrap.all(.named(1))'));
    expect(out, contains('static const b = Wrap.all(.named(2))'));
  });

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
    'redirecting-factory forwarder is accepted (EdgeInsetsGeometry analog)',
    () async {
      const source = '''
abstract class Geo {
  const factory Geo.all(double v) = Box.all;
  const factory Geo.sym({double h, double v}) = Box.sym;
}
class Box implements Geo {
  const Box.all(this.v) : h = 0;
  const Box.sym({this.h = 0, this.v = 0});
  final double h;
  final double v;
}
class Pad {
  const Pad(this.g);
  final Geo g;
}
void take(Geo g) {}
void main() {
  take(Box.all(1));
  take(const Box.sym(h: 4));
  const Pad(Box.sym(v: 2));
}
''';
      final out = await sanitize(source);
      // `.all(1)` binds Geo.all, which forwards the call untouched to
      // Box.all — same object, same defaults.
      expect(out, contains('take(.all(1))'));
      expect(out, contains('take(const .sym(h: 4))'));
      expect(out, contains('const Pad(.sym(v: 2))'));
    },
  );

  test(
    'forwarder declaring named parameters in another order is accepted',
    () async {
      const source = '''
abstract class Geo {
  const factory Geo.only({double l, double r, double t, double b}) = Box.only;
}
class Box implements Geo {
  const Box.only({this.l = 0, this.t = 0, this.r = 0, this.b = 0});
  final double l;
  final double t;
  final double r;
  final double b;
}
void take(Geo g) {}
void main() => take(Box.only(l: 1));
''';
      final out = await sanitize(source);
      expect(out, contains('take(.only(l: 1))'));
    },
  );

  test('forwarder whose parameter types differ is refused', () async {
    const source = '''
abstract class Geo {
  const factory Geo.all(double v) = Box.all;
}
class Box implements Geo {
  const Box.all(this.v);
  final num v;
}
void take(Geo g) {}
void main() => take(Box.all(1));
''';
    final out = await sanitize(source);
    // Through Geo.all the literal `1` is typed double, not int.
    expect(out, contains('take(Box.all(1))'));
  });

  test('forwarder with a body, not a redirect, is refused', () async {
    const source = '''
abstract class Geo {
  factory Geo.all(double v) => Box.all(v);
}
class Box implements Geo {
  const Box.all(this.v);
  final double v;
}
void take(Geo g) {}
void main() => take(Box.all(1));
''';
    final out = await sanitize(source);
    expect(out, contains('take(Box.all(1))'));
  });

  test('forwarder onto a different constructor is refused', () async {
    const source = '''
abstract class Geo {
  const factory Geo.all(double v) = Box.other;
}
class Box implements Geo {
  const Box.all(this.v);
  const Box.other(this.v);
  final double v;
}
void take(Geo g) {}
void main() => take(Box.all(1));
''';
    final out = await sanitize(source);
    expect(out, contains('take(Box.all(1))'));
  });

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
    final sanitizer = Sanitizer(excludes: ['firebase_options.dart']);
    await sanitizer.run([excluded.path, generated.path, normal.path]);
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
  final p.Scaler ts = p.Scaler.scale(5);
  print(ts);
}
''');
    expect(out, contains('final p.Scaler ts = .scale(5);'));
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
    const spec = 'name: old_fixture\nenvironment:\n  sdk: ^3.9.0\n';
    File(p.join(old.path, 'pubspec.yaml')).writeAsStringSync(spec);
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
    expect(result.skippedBelowFloor, {
      (root: p.normalize(p.absolute(old.path)), version: '3.9'): 1,
    });
    expect(result.convertedCount, 0);
  });

  test('skips hidden directories and build folder during traversal', () async {
    final hiddenDir = Directory(p.join(pkg.path, '.hidden'))..createSync();
    final buildDir = Directory(p.join(pkg.path, 'build'))..createSync();
    final normalDir = Directory(p.join(pkg.path, 'src'))..createSync();

    File(p.join(hiddenDir.path, 'ignored.dart')).writeAsStringSync('''
enum Fit { cover }
Fit f() => Fit.cover;
''');
    File(p.join(buildDir.path, 'ignored.dart')).writeAsStringSync('''
enum Fit { cover }
Fit f() => Fit.cover;
''');
    final normalFile = File(p.join(normalDir.path, 'converted.dart'))
      ..writeAsStringSync('''
enum Fit { cover }
Fit f() => Fit.cover;
''');

    final result = await Sanitizer().run([pkg.path]);
    expect(result.files.any((f) => f.path.contains('.hidden')), isFalse);
    expect(result.files.any((f) => f.path.contains('build')), isFalse);
    expect(result.files.any((f) => f.path == normalFile.path), isTrue);
  });

  group('static pre-check', () {
    // The check must never rule out a site the resolve would accept: every
    // context-bearing position it reasons about is exercised here.
    const box = '''
import 'dart:async';
class Box {
  const Box.named(this.v);
  final int v;
  static const Box a = Box.named(1);
  static Box make() => const Box.named(2);
  static Box? maybe() => const Box.named(3);
  static Future<Box> load() async => const Box.named(4);
  Box get self => this;
  Box operator +(Box o) => Box.named(v + o.v);
}
T id<T>(T x) => x;
void take(Box p, {required Box n}) {}
void dflt({Box b = Box.a}) {}
''';

    test('context-bearing positions all convert', () async {
      final out = await sanitize('''
$box
Box ret() { return Box.a; }
Box arrow() => Box.make();
Future<Box> asyncRet() async { return Box.a; }
Future<Box> awaited() async { Box b = await Box.load(); return b; }
Box Function() closure() => () => Box.make();
Box? nullable() => Box.maybe();
FutureOr<Box> futureOr() => Box.a;
Box switched(int x) => switch (x) { 1 => Box.a, _ => Box.make() };
Box cond(bool c) => c ? Box.a : Box.make();
Box coalesce(Box? p) => p ?? Box.a;
Box bang() => Box.maybe()!;
Box chain() => Box.make().self;
Box cascade() => Box.a..v;
Box generic() => id(Box.a);
Box rhs() => Box.a + Box.make();
List<Box> list(bool c) => [Box.a, if (c) Box.make()];
Map<String, Box> map() => {'k': Box.a};
void main() {
  take(Box.a, n: Box.make());
  Box typed = Box.a;
  typed = Box.make();
  if (typed == Box.a) return;
}
''');
      for (final shorthand in [
        '{ return .a; }',
        'arrow() => .make();',
        'async { return .a; }',
        'await .load()',
        '() => .make();',
        'nullable() => .maybe();',
        'futureOr() => .a;',
        '1 => .a, _ => .make()',
        'c ? .a : .make()',
        'p ?? .a',
        'bang() => .maybe()!',
        'chain() => .make().self',
        'cascade() => .a..v',
        'generic() => id(.a)',
        'rhs() => Box.a + .make()',
        '[.a, if (c) .make()]',
        "{'k': .a}",
        'take(.a, n: .make())',
        'Box typed = .a;',
        'typed = .make();',
        'typed == .a',
        'dflt({Box b = .a})',
        'static const Box a = .named(1)',
      ]) {
        expect(out, contains(shorthand));
      }
    });

    test('positions without a context type stay prefixed', () async {
      final file = File(p.join(pkg.path, 'lib', 'case_${fileId++}.dart'))
        ..writeAsStringSync('''
$box
class Err implements Exception { const Err.code(this.c); final int c; }
/// Prose about [Box.a] is not a site.
Future<void> main() async {
  Box.make();
  await Box.load();
  final untyped = Box.a;
  final Object cast = Box.a as Object;
  final String interp = '\${Box.a}';
  final Box lhs = Box.a + Box.a;
  final int other = Box.make().v;
  if (untyped.v > 9) throw Err.code(1);
  print('\$cast \$interp \$lhs \$other');
}
''');
      final result = await Sanitizer().run([file.path]);
      final out = file.readAsStringSync();
      for (final kept in [
        '[Box.a] is not a site',
        '  Box.make();',
        'await Box.load();',
        'final untyped = Box.a;',
        'Box.a as Object',
        r"'${Box.a}'",
        'Box.a + .a;',
        'int other = Box.make().v;',
        'throw Err.code(1)',
      ]) {
        expect(out, contains(kept));
      }
      // Sites the check rules out are reported as reverted like any other;
      // the doc-comment reference is prose, not a ninth.
      expect(result.files.single.reverted, 8);
    });
  });

  group('explain', () {
    test('lists every site left prefixed, with the reason', () async {
      final file = File(p.join(pkg.path, 'lib', 'case_${fileId++}.dart'))
        ..writeAsStringSync('''
class Color {
  const Color(this.v);
  final int v;
}
class Palette {
  static const Color red = Color(1);
}
class Base {
  const Base.id(this.tag);
  final String tag;
  static const Base a = Base.id('base');
}
class Sub extends Base {
  const Sub.id() : super.id('sub');
  static const Sub a = Sub.id();
}
abstract class Geo {
  const factory Geo.all(double v) = Box.all;
}
class Box implements Geo {
  const Box.all(this.v);
  final double v;
  static const Box zero = Box.all(0);
  static const Box unit = Box.all(1);
}
enum Fit { cover, contain }
T id<T>(T x) => x;
void main() {
  final Fit f = Fit.cover;
  final untyped = Fit.contain;
  const Color c = Palette.red;
  const Base x = Sub.a;
  final y = id(Box.zero);
  final Geo g = Box.all(1)..v;
  final Box skipped = Box.unit;
  print([f, untyped, c, x, y, g, skipped]);
}
''');
      final result = await Sanitizer(
        skips: {'Box.unit'},
        dryRun: true,
        explain: true,
      ).run([file.path]);

      final fileResult = result.files.single;
      expect(fileResult.kept, [
        // Ruled out by the static pre-check, before any resolve.
        '30: Fit.contain kept: no context type',
        '31: Palette.red kept: context type Color declares no static red',
        // Refused by the verify loop: a rebind, the analyzer's own error on
        // the shorthand, and damage only bisection pins on the site (`..v`
        // reads a getter the forwarder's class lacks).
        '32: Sub.a kept: rebinds to Base.a',
        matches(r'^33: Box\.zero kept: .*context type'),
        '34: Box.all kept: rebinds to Geo.all outside a typed slot',
        '35: Box.unit kept: skip-listed',
      ]);
      expect(fileResult.converted, hasLength(5));
      // Every kept site but the skip-listed one counts as reverted.
      expect(fileResult.reverted, 5);
      expect(result.keptCount, 6);
    });

    test(
      'a file with nothing to convert is reported only when explaining',
      () async {
        final file = File(p.join(pkg.path, 'lib', 'case_${fileId++}.dart'))
          ..writeAsStringSync('''
enum Fit { cover }
void main() {
  final untyped = Fit.cover;
  print(untyped);
}
''');
        final plain = await Sanitizer(dryRun: true).run([file.path]);
        expect(plain.files, isEmpty);

        final explained = await Sanitizer(
          dryRun: true,
          explain: true,
        ).run([file.path]);
        expect(explained.files.single.converted, isEmpty);
        expect(explained.files.single.kept, [
          '3: Fit.cover kept: no context type',
        ]);
      },
    );
  });

  test('sdkPath returns valid SDK path and caches result', () {
    final path1 = sdkPath();
    expect(path1, isNotNull);
    final path2 = sdkPath();
    expect(path2, equals(path1));
  });

  test('SS-1 licensed rebinds convert in new typed-slot positions', () async {
    final out = await sanitize('''
import 'dart:async';
abstract class Geo {
  const factory Geo.all(double v) = Box.all;
  static Geo? maybe(double v) => Box.maybe(v);
}
class Box implements Geo {
  const Box.all(this.v);
  static Box? maybe(double v) => Box.all(v);
  final double v;
}
class Holder {
  Holder() : g = Box.all(1);
  final Geo g;
}
class Table {
  void operator []=(Geo k, int v) {}
}
class Vec {
  Vec operator +(Geo g) => this;
}
FutureOr<Geo> futureOrGeo() => Box.all(2);
Iterable<Geo> genGeo() sync* {
  yield Box.all(3);
}
void f(Geo? custom, bool b, Table t, Vec v) {
  final Geo coalesced = custom ?? Box.all(4);
  final Geo leftCoalesced = Box.maybe(5) ?? Box.all(4);
  final list = <Geo>[?(b ? Box.all(6) : null)];
  final map = <String, Geo>{if (b) 'k': Box.all(7)};
  t[Box.all(8)] = 1;
  final sum = v + Box.all(9);
  print([coalesced, leftCoalesced, list, map, sum]);
}
''');
    expect(out, contains(': g = .all(1);'));
    expect(out, contains('futureOrGeo() => .all(2);'));
    expect(out, contains('yield .all(3);'));
    expect(out, contains('custom ?? .all(4);'));
    expect(out, contains('Box.maybe(5) ?? .all(4);'));
    expect(out, contains('<Geo>[?(b ? .all(6) : null)];'));
    expect(out, contains("if (b) 'k': .all(7)};"));
    expect(out, contains('t[.all(8)] = 1;'));
    expect(out, contains('v + .all(9);'));
  });

  test('extension type parameters are pinned by the receiver', () async {
    final out = await sanitize('''
enum Fit { cover, fill }
class Subject<T> {}
extension Checks<T> on Subject<T> {
  void equals(T other) {}
  void same<U>(U other) {}
}
Subject<Fit> check(Fit a) => Subject<Fit>();
T id<T>(T x) => x;
void main() {
  check(Fit.fill).equals(Fit.cover);
  check(Fit.fill).same(Fit.cover);
  print(id(Fit.cover));
}
''');
    expect(out, contains('check(.fill).equals(.cover);'));
    expect(out, contains('check(.fill).same(Fit.cover);'));
    expect(out, contains('print(id(Fit.cover));'));
  });

  test(
    'SS-2 compound assignment += uses operator parameter context type',
    () async {
      final out = await sanitize('''
class Delta {
  const Delta(this.v);
  final int v;
  static const Delta zero = Delta(0);
}
class Vec {
  Vec operator +(Delta d) => this;
}
void main() {
  var v = Vec();
  v += Delta.zero;
  print(v);
}
''');
      expect(out, contains('v += .zero;'));
    },
  );

  test('SS-3 switch scrutinee and ternary receiver have no context', () async {
    final file = File(p.join(pkg.path, 'lib', 'case_${fileId++}.dart'))
      ..writeAsStringSync('''
enum Fit { cover, contain }
class Box {
  const Box();
  static const Box a = Box();
  static const Box b = Box();
  Box get self => this;
}
void f(bool c) {
  final String s = switch (Fit.cover) { _ => 'b' };
  final Box x = (c ? Box.a : Box.b).self;
  print([s, x]);
}
''');
    final result = await Sanitizer(
      dryRun: true,
      explain: true,
    ).run([file.path]);
    expect(result.skippedWithErrors, isEmpty);
    expect(result.files.single.kept, [
      '9: Fit.cover kept: no context type',
      '10: Box.a kept: no context type',
      '10: Box.b kept: no context type',
    ]);
  });

  test('SS-4 skips @Annot.member and new Type.named(), keeps gap', () async {
    final out = await sanitize('''
class MyAnnot {
  const MyAnnot._();
  static const MyAnnot instance = MyAnnot._();
}
class Inner {
  const Inner.named(this.v);
  final int v;
}
class Box {
  const Box.all(this.v) : inner = null;
  Box.wrap(this.inner) : v = 0;
  final int v;
  final Inner? inner;
}
@MyAnnot.instance
void main() {
  final Box a = new Box.all(1);
  final Box b = new Box.wrap(Inner.named(2));
  final Box c = Box.
    all(3);
  print([a, b, c]);
}
''');
    expect(out, contains('@MyAnnot.instance'));
    expect(out, contains('final Box a = new Box.all(1);'));
    expect(out, contains('final Box b = new Box.wrap(.named(2));'));
    expect(out, contains('final Box c = .\n    all(3);'));
  });

  test('SS-5 doomed assignment does not poison later promotion', () async {
    final out = await sanitize('''
class Geo {
  const Geo();
  const factory Geo.all(int v) = Box.all;
}
class Box extends Geo {
  const Box.all(this.v);
  const Box.only(this.v);
  final int v;
  void boxOnly(Box b) {}
}
T id<T>(T x) => x;
void promoted() {
  Geo g = const Geo();
  if (g is Box) return;
  g = Box.all(2);
  g.boxOnly(Box.only(3));
}
void inferred() {
  final x = id(Box.all(2));
  x.boxOnly(Box.only(4));
}
''');
    expect(out, contains('g = Box.all(2);'));
    expect(out, contains('g.boxOnly(.only(3));'));
    expect(out, contains('final x = id(Box.all(2));'));
    expect(out, contains('x.boxOnly(.only(4));'));
  });

  test(
    'SS-6 pruning first import keeps /// doc and strips trailing //',
    () async {
      File(p.join(pkg.path, 'lib', 'ss6_dep.dart')).writeAsStringSync('''
class Dep {
  const Dep._();
  static const Dep instance = Dep._();
}
''');
      File(p.join(pkg.path, 'lib', 'ss6_sink.dart')).writeAsStringSync('''
import 'ss6_dep.dart';
class Sink {
  Sink(this.d);
  final Dep d;
}
''');
      final file = File(p.join(pkg.path, 'lib', 'ss6_consumer.dart'))
        ..writeAsStringSync('''
/// Library doc comment.
import 'ss6_dep.dart'; // trailing comment
import 'ss6_sink.dart';

final sink = Sink(Dep.instance);
''');
      await Sanitizer().run([file.path]);
      final out = file.readAsStringSync();
      expect(
        out,
        startsWith("/// Library doc comment.\nimport 'ss6_sink.dart';"),
      );
      expect(out, isNot(contains('trailing comment')));
      expect(out, contains('Sink(.instance)'));
    },
  );

  test(
    'SS-7 part keeps valid rewrites when another orphans off-limits import',
    () async {
      File(p.join(pkg.path, 'lib', 'ss7_dep.dart')).writeAsStringSync('''
class Dep {
  const Dep._();
  static const Dep instance = Dep._();
}
''');
      File(p.join(pkg.path, 'lib', 'ss7_sink.dart')).writeAsStringSync('''
import 'ss7_dep.dart';
enum Fit { cover }
class Sink {
  Sink(this.d);
  final Dep d;
}
''');
      File(p.join(pkg.path, 'lib', 'ss7_lib.dart')).writeAsStringSync('''
import 'ss7_dep.dart';
import 'ss7_sink.dart';
part 'ss7_part.dart';
''');
      final partFile = File(p.join(pkg.path, 'lib', 'ss7_part.dart'))
        ..writeAsStringSync('''
part of 'ss7_lib.dart';
final Fit f = Fit.cover;
final sink = Sink(Dep.instance);
''');
      final result = await Sanitizer(explain: true).run([partFile.path]);
      final out = partFile.readAsStringSync();
      expect(out, contains('final Fit f = .cover;'));
      expect(out, contains('final sink = Sink(Dep.instance);'));
      const keptReason =
          '3: Dep.instance kept: pruning its orphaned imports would edit '
          'ss7_lib.dart, which is not among the given paths';
      expect(result.files.single.kept, [keptReason]);
    },
  );

  test(
    'SS-8 allows @protected+@visibleForTesting in test/ and checks class meta',
    () async {
      final root = Directory.systemTemp.createTempSync('shorthand_ss8');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final d in ['lib', 'test', 'integration_test']) {
        Directory(p.join(root.path, d)).createSync(recursive: true);
      }
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: ss8_pkg
environment:
  sdk: ^3.10.0
dependencies:
  meta: ^1.15.0
''');
      File(p.join(root.path, 'lib', 'defs.dart')).writeAsStringSync('''
import 'package:meta/meta.dart';

class Geo {
  const Geo();
  @protected
  @visibleForTesting
  const factory Geo.both(int v) = Box.both;
  @visibleForTesting
  const factory Geo.vft(int v) = Box.vft;
}
class Box extends Geo {
  const Box.both(this.v);
  const Box.vft(this.v);
  final int v;
}
@visibleForTesting
class VftHost {
  const VftHost();
  const factory VftHost.make(int v) = VftSub.make;
}
class VftSub extends VftHost {
  const VftSub.make(this.v);
  final int v;
}
void takeGeo(Geo g) {}
void takeHost(VftHost h) {}
''');
      final libUse = File(p.join(root.path, 'lib', 'use.dart'))
        ..writeAsStringSync('''
import 'defs.dart';
void f() {
  takeGeo(Box.both(1));
  takeHost(VftSub.make(2));
}
''');
      final testUse = File(p.join(root.path, 'test', 'use_test.dart'))
        ..writeAsStringSync('''
import 'package:ss8_pkg/defs.dart';
void main() {
  takeGeo(Box.both(1));
  takeHost(VftSub.make(2));
}
''');
      final itUse = File(p.join(root.path, 'integration_test', 'app_test.dart'))
        ..writeAsStringSync('''
import 'package:ss8_pkg/defs.dart';
void main() {
  takeGeo(Box.vft(1));
  takeHost(VftSub.make(2));
}
''');
      final get = Process.runSync('dart', [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root.path);
      if (get.exitCode != 0) {
        Process.runSync('dart', ['pub', 'get'], workingDirectory: root.path);
      }
      await Sanitizer().run([libUse.path, testUse.path, itUse.path]);
      expect(libUse.readAsStringSync(), contains('takeGeo(Box.both(1));'));
      expect(libUse.readAsStringSync(), contains('takeHost(VftSub.make(2));'));
      expect(testUse.readAsStringSync(), contains('takeGeo(.both(1));'));
      expect(testUse.readAsStringSync(), contains('takeHost(.make(2));'));
      expect(itUse.readAsStringSync(), contains('takeGeo(.vft(1));'));
      expect(itUse.readAsStringSync(), contains('takeHost(.make(2));'));
    },
  );

  test("SS-9 nested package converts despite the parent's exclude", () async {
    final root = Directory.systemTemp.createTempSync('shorthand_ss9');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory(p.join(root.path, 'lib')).createSync();
    Directory(p.join(root.path, 'example', 'lib')).createSync(recursive: true);
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: parent_pkg
environment:
  sdk: ^3.10.0
''');
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - example/**
''');
    File(p.join(root.path, 'example', 'pubspec.yaml')).writeAsStringSync('''
name: example_pkg
environment:
  sdk: ^3.10.0
''');
    final exFile = File(p.join(root.path, 'example', 'lib', 'main.dart'))
      ..writeAsStringSync('''
enum Fit { cover }
Fit f() => Fit.cover;
''');
    for (final dir in [root.path, p.join(root.path, 'example')]) {
      final get = Process.runSync('dart', [
        'pub',
        'get',
      ], workingDirectory: dir);
      if (get.exitCode != 0) {
        throw StateError('pub get failed: ${get.stderr}');
      }
    }
    // The nested package obeys only its own options, unlike `dart analyze`:
    // the parent's example/** excludes nothing there.
    final result = await Sanitizer().run([root.path]);
    expect(result.excluded, isEmpty);
    expect(result.skippedUnconfigured, isEmpty);
    expect(exFile.readAsStringSync(), contains('=> .cover;'));
  });

  test(
    'SS-11 isGenerated stops after single-line block comment before code',
    () {
      String write(String name, String content) {
        final f = File(p.join(pkg.path, 'lib', name))
          ..writeAsStringSync(content);
        return f.path;
      }

      expect(
        Sanitizer.isGenerated(
          write(
            'ss11_code.dart',
            "/* header */ import 'dart:core';\n"
                '// GENERATED CODE - DO NOT MODIFY\n',
          ),
        ),
        isFalse,
      );
      expect(
        Sanitizer.isGenerated(
          write('ss11_gen.dart', '/* GENERATED CODE - DO NOT MODIFY */\n'),
        ),
        isTrue,
      );
    },
  );

  test('SS-I3 Sanitizer takes skip entries as given', () async {
    expect(
      () => Sanitizer(skips: {' Fit.cover , contain '}),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'skips')),
    );
    final out = await sanitize(
      '''
enum Fit { cover, contain, fill }
void main() {
  final Fit a = Fit.cover;
  final Fit b = Fit.contain;
  final Fit c = Fit.fill;
  print([a, b, c]);
}
''',
      skips: {'Fit.cover', 'contain'},
    );
    expect(out, contains('final Fit a = Fit.cover;'));
    expect(out, contains('final Fit b = Fit.contain;'));
    expect(out, contains('final Fit c = .fill;'));
  });

  test(
    'E1 forwarder with different positional parameter name converts',
    () async {
      final out = await sanitize('''
abstract class Geo {
  const factory Geo.pair(double a) = Box.pair;
}
class Box implements Geo {
  const Box.pair(this.v);
  final double v;
}
void take(Geo g) {}
void main() => take(Box.pair(1));
''');
      expect(out, contains('take(.pair(1))'));
    },
  );

  test(
    'pruning import with trailing ignore_for_file keeps comment on own line',
    () async {
      File(p.join(pkg.path, 'lib', 'ig_dep.dart')).writeAsStringSync('''
class Dep {
  const Dep._();
  static const Dep instance = Dep._();
}
''');
      File(p.join(pkg.path, 'lib', 'ig_sink.dart')).writeAsStringSync('''
import 'ig_dep.dart';
class Sink {
  Sink(this.d);
  final Dep d;
}
''');
      final file = File(p.join(pkg.path, 'lib', 'ig_consumer.dart'))
        ..writeAsStringSync('''
import 'ig_dep.dart'; // ignore_for_file: avoid_print
import 'ig_sink.dart';

final sink = Sink(Dep.instance);
''');
      await Sanitizer().run([file.path]);
      final out = file.readAsStringSync();
      expect(
        out,
        startsWith("// ignore_for_file: avoid_print\nimport 'ig_sink.dart';"),
      );
      expect(out, contains('Sink(.instance)'));
    },
  );

  test(
    'pruning sole directive with doc comment or annotation emits library;',
    () async {
      File(p.join(pkg.path, 'lib', 'sole_aliases.dart')).writeAsStringSync('''
import 'sole_doc.dart';
typedef Mode = Fit;
''');
      final docFile = File(p.join(pkg.path, 'lib', 'sole_doc.dart'))
        ..writeAsStringSync('''
/// Library-level notes.
import 'sole_aliases.dart';

enum Fit { cover, fill }
Fit f() => Mode.fill;
''');
      File(p.join(pkg.path, 'lib', 'sole_annot_aliases.dart'))
          .writeAsStringSync('''
import 'sole_annot.dart';
typedef Mode2 = Fit2;
''');
      final annotFile = File(p.join(pkg.path, 'lib', 'sole_annot.dart'))
        ..writeAsStringSync('''
@Deprecated('lib')
import 'sole_annot_aliases.dart';

enum Fit2 { cover, fill }
Fit2 f2() => Mode2.fill;
''');
      await Sanitizer().run([docFile.path, annotFile.path]);
      expect(
        docFile.readAsStringSync(),
        startsWith('/// Library-level notes.\nlibrary;\n\nenum Fit'),
      );
      expect(
        annotFile.readAsStringSync(),
        startsWith("@Deprecated('lib')\nlibrary;\n\nenum Fit2"),
      );
    },
  );

  test(
    'refused rebind wave does not bisect across statements in _recover',
    () async {
      final calls = List.generate(40, (_) => '  take(Sub.a);').join('\n');
      final sw = Stopwatch()..start();
      final out = await sanitize('''
class Base {
  const Base(this.v);
  static const Base a = Base(1);
  final int v;
}
class Sub extends Base {
  const Sub() : super(2);
  static const Sub a = Sub();
}
enum Fit { cover }
void take(Base b) {}
void takeFit(Fit f) {}
void main() {
  takeFit(Fit.cover);
$calls
}
''');
      sw.stop();
      expect(out, contains('takeFit(.cover);'));
      expect(out, contains('take(Sub.a);'));
      expect(sw.elapsedMilliseconds, lessThan(5000));
    },
  );
}
