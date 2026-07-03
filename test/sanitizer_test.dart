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
}
