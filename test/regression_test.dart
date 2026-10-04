// Sweep 2026-10-03 regressions, keyed by finding ID (`SS-<ID>` in each test
// name). Each one failed on 0.9.0.
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

Future<String> sanitize(String source, {Set<String> skips = const {}}) async {
  final file = write(pkg, 'lib/case_${fileId++}.dart', source);
  await Sanitizer(skips: skips).run([file.path]);
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
    final out = await sanitize('''
import 'geo.dart';
void pre(Geo g) => g.boxOnly(); // pre-existing error, same message
final Geo fresh = Box.all(1)..boxOnly();
''');
    expect(out, contains('Box.all(1)..boxOnly()'));
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
}
