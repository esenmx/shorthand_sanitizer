// End-to-end oracle over whole fixture packages: `dart analyze` and the
// fixture's own `bin/main.dart` output, before and after a sanitize run.
// Fixtures are string constants written under the system temp dir, never
// tracked `.dart` files (they carry deliberate errors and nested pubspecs).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:test/test.dart';

void main() {
  e2e('battery', battery, converted: 69);
  e2e('masked_error', maskedError, allowErrors: true);
  e2e('deprecated_alias', deprecatedAlias);
  e2e('neg_zero_alias', negZeroAlias);
  e2e('doc_ref_import', docRefImport);
  e2e('unused_import_error', unusedImportError);
  e2e('typedef_fixed_args', typedefFixedArgs);
  e2e('static_type_widen', staticTypeWiden);
  e2e('part_orphan', partOrphan, converted: 1);
  e2e('display_collision', displayCollision);
  e2e('vft_warning', vftWarning);
  e2e('duplicate_info', duplicateInfo);
  e2e('use_result', useResult);
}

/// Sanitizes `lib` and `bin` of a package built from [files] (paths relative
/// to its root; a `.keep` entry makes an empty directory). The run must add
/// no `dart analyze` diagnostic, leave `bin/main.dart`'s output unchanged and,
/// when given, convert exactly [converted] sites. [allowErrors] keeps a
/// fixture with a deliberate error from being skipped whole.
void e2e(
  String name,
  Map<String, String> files, {
  int? converted,
  bool allowErrors = false,
}) {
  test('e2e $name', () async {
    final root = Directory.systemTemp.createTempSync('dotsan_e2e_');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final MapEntry(key: rel, value: text) in files.entries) {
      final path = p.joinAll([root.path, ...rel.split('/')]);
      if (p.basename(path) == '.keep') {
        Directory(p.dirname(path)).createSync(recursive: true);
      } else {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }
    }
    final offline = Process.runSync('dart', [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: root.path);
    if (offline.exitCode != 0) {
      final online = Process.runSync('dart', [
        'pub',
        'get',
      ], workingDirectory: root.path);
      if (online.exitCode != 0) {
        throw StateError('pub get failed: ${online.stderr}');
      }
    }

    final diagnosticsBefore = _diagnostics(root);
    final runBefore = _run(root);
    final result = await Sanitizer(allowErrors: allowErrors).run([
      for (final dir in ['lib', 'bin'])
        if (Directory(p.join(root.path, dir)).existsSync())
          p.join(root.path, dir),
    ]);

    expect(result.skippedWithErrors, isEmpty, reason: 'fixture has errors');

    final surplus = _diagnostics(root);
    diagnosticsBefore.forEach(surplus.remove);
    expect(surplus, isEmpty, reason: 'new diagnostics:\n${surplus.join('\n')}');
    expect(_run(root), runBefore);
    if (converted != null) expect(result.convertedCount, converted);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// `severity|code|file|message` of each `dart analyze --format=machine` line.
List<String> _diagnostics(Directory root) {
  final r = Process.runSync('dart', [
    'analyze',
    '--format=machine',
    '.',
  ], workingDirectory: root.path);
  return [
    for (final line in '${r.stdout}${r.stderr}'.split('\n'))
      if (line.contains('|'))
        switch (line.split('|')) {
          final f => [f[0], f[2], f[3], f.sublist(7).join('|')].join('|'),
        },
  ];
}

/// Exit code and both streams of `dart run bin/main.dart`, when it exists.
String? _run(Directory root) {
  if (!File(p.join(root.path, 'bin', 'main.dart')).existsSync()) return null;
  final r = Process.runSync('dart', [
    'run',
    'bin/main.dart',
  ], workingDirectory: root.path);
  return 'exit ${r.exitCode}\n${r.stdout}\n${r.stderr}';
}

const battery = {
  'bin/main.dart': r'''
import 'dart:async';

import 'package:battery/types.dart';
import 'package:battery/types.dart' as t;

Fit arrow() => Fit.cover;
Future<Fit> asyncArrow() async => Fit.contain;
Future<Fit> asyncBlock() async {
  return Fit.cover;
}
FutureOr<Insets> futureOr() => Insets.zero;
Iterable<Fit> gen() sync* {
  yield Fit.cover;
}

@Annot(Fit.contain)
void annotated() {}

void main() async {
  final b = DateTime.now().year > 2000;
  final Fit? maybe = b ? null : Fit.cover;
  print([
    arrow(), await asyncArrow(), await asyncBlock(), futureOr(), gen().first,
  ]);
  takeObj(Fit.cover);
  takeDyn(Fit.cover);
  takeNullable(Fit.contain);
  takeFutureOr(Fit.cover);
  takeNamed(insets: Insets.all(2), fit: Fit.contain);
  takeNamed(insets: SubInsets.zero);
  takeNamed(insets: Insets.sub());
  takeDefault();
  takeRecord((fit: Fit.cover, i: Insets.unit));
  final Pair pair = (Fit.contain, Insets.parse('3'));
  print(pair);
  final Fit t1 = b ? Fit.cover : Fit.contain;
  final Object t2 = b ? Fit.cover : 1;
  final Fit t3 = maybe ?? Fit.contain;
  print('$t1 $t2 $t3');
  final List<Fit> l1 = [Fit.cover, if (b) Fit.contain, for (var i = 0; i < 1; i++) Fit.cover];
  final l2 = <Fit>[Fit.contain, ...[Fit.cover]];
  final Map<Fit, Insets> m = {Fit.cover: Insets.zero, Fit.contain: Insets.all(1)};
  final Set<Fit> s = {Fit.cover};
  print('$l1 $l2 $m $s');
  final Holder h = Holder(Fit.contain)..field = Fit.cover;
  print('${h.fit} ${h.field} ${h.insets} ${h.later}');
  final dynamic d = Fit.cover;
  print(d as Fit == Fit.cover);
  print(d is Fit);
  print(maybe == Fit.cover);
  print(Fit.cover != maybe);
  final r = switch (h.fit) { Fit.cover => 'c', Fit.contain => 'n' };
  switch (h.fit) {
    case Fit.cover:
      print('case cover');
    case Fit.contain:
      print('case contain');
  }
  const Insets ci = Insets.all(5);
  const List<Insets> cl = [Insets.zero, Insets.all(6)];
  print('$r $ci $cl');
  final Id id = Id.first;
  final Fit fb = Fit.fallback;
  final Insets alias = Alias.zero;
  final Insets pfx = t.Insets.all(7);
  final Insets subZero = SubInsets.zero;
  final Insets pick = Insets.pick(Insets.zero);
  final Insets explicitPick = Insets.pick<Insets>(Insets.unit);
  final Fit gen1 = generic(Fit.cover);
  final Fit gen2 = generic<Fit>(Fit.contain);
  print('$id $fb $alias $pfx $subZero $pick $explicitPick $gen1 $gen2');
  print('interp ${Fit.cover}');
  Fit assigned = Fit.cover;
  assigned = Fit.contain;
  print(assigned);
  print(WithArg.a.fit);
  print(Insets.zero == Insets.zero);
  final Insets nested = Insets.all(Insets.zero.v);
  print(nested);
  final Insets fact = Insets.sub();
  print(fact);
  final Iterable<Fit> mapped = [1].map((_) => Fit.contain);
  print(mapped.toList());
  final List<Insets> filled = List.filled(1, Insets.zero);
  print(filled);
  annotated();
}
''',
  'lib/types.dart': r'''
import 'dart:async';

enum Fit { cover, contain; static const Fit fallback = contain; }

class Insets {
  const Insets.all(this.v);
  const Insets.only({this.v = 0});
  factory Insets.sub() = SubInsets.make;
  final double v;
  static const Insets zero = Insets.all(0);
  static Insets get unit => const Insets.all(1);
  static Insets parse(String s) => Insets.all(double.parse(s));
  static T pick<T>(T a) => a;
  @override
  String toString() => '$runtimeType($v)';
}

class SubInsets extends Insets {
  const SubInsets.make() : super.all(9);
  static const Insets zero = Insets.all(42);
}

extension type const Id(int v) {
  static const Id first = Id(1);
}

class Holder {
  Holder(this.fit, {this.insets = Insets.zero}) : later = Fit.cover;
  final Fit fit;
  final Insets insets;
  final Fit later;
  Fit field = Fit.contain;
}

class Annot {
  const Annot(this.fit);
  final Fit fit;
}

enum WithArg {
  a(Fit.cover),
  b(Fit.contain);

  const WithArg(this.fit);
  final Fit fit;
}

typedef Pair = (Fit, Insets);
typedef Alias = Insets;

T generic<T>(T x) => x;
void takeObj(Object o) => print('obj $o');
void takeDyn(dynamic o) => print('dyn $o');
void takeNullable(Fit? f) => print('nullable $f');
void takeFutureOr(FutureOr<Fit> f) => print('futureOr $f');
void takeNamed({required Insets insets, Fit fit = Fit.cover}) =>
    print('named $insets $fit');
void takeDefault([Fit f = Fit.contain]) => print('default $f');
void takeRecord(({Fit fit, Insets i}) r) => print('record $r');
''',
  'pubspec.yaml': '''
name: battery
environment:
  sdk: ^3.10.0
''',
};

// Refused by the typed-slot rule (a cascade) before the multiset check runs;
// `duplicateInfo` pins the multiset.
const maskedError = {
  'lib/geo.dart': '''
class Geo {
  const Geo();
  const factory Geo.all(int v) = Box.all;
}

class Box extends Geo {
  const Box.all(this.v);
  final int v;
  void boxOnly() {}
}
''',
  'lib/use.dart': '''
import 'package:masked_error/geo.dart';

void pre(Geo g) => g.boxOnly(); // pre-existing error, same message

final Geo fresh = Box.all(1)..boxOnly();
''',
  'pubspec.yaml': '''
name: masked_error
environment:
  sdk: ^3.10.0
''',
};

const deprecatedAlias = {
  'bin/main.dart': '''
import 'package:geo_pkg/geo.dart';

void use(Geo g) => print(g);

void main() {
  use(Box.all(1));
  use(Box.zero);
}
''',
  'geo_pkg/lib/geo.dart': '''
class Geo {
  const Geo();
  @Deprecated('use Box.all')
  const factory Geo.all(int v) = Box.all;
  @Deprecated('use Box.zero')
  static const Geo zero = Box.zero;
}

class Box extends Geo {
  const Box.all(this.v);
  final int v;
  static const Box zero = Box.all(0);
}
''',
  'geo_pkg/pubspec.yaml': '''
name: geo_pkg
environment:
  sdk: ^3.10.0
''',
  'lib/.keep': '',
  'pubspec.yaml': '''
name: deprecated_alias
environment:
  sdk: ^3.10.0
dependencies:
  geo_pkg:
    path: geo_pkg
''',
};

const negZeroAlias = {
  'bin/main.dart': r'''
import 'package:neg_zero_alias/num.dart';

void main() {
  const Num n = Sub.zero;
  print('1/v = ${1 / n.v}, identical(Sub.zero) = ${identical(n, Sub.zero)}');
}
''',
  'lib/num.dart': '''
class Num {
  const Num(this.v);
  final double v;
  static const Num zero = Num(0.0);
}

class Sub extends Num {
  const Sub(super.v);
  static const Num zero = Num(-0.0);
}
''',
  'pubspec.yaml': '''
name: neg_zero_alias
environment:
  sdk: ^3.10.0
''',
};

const docRefImport = {
  'lib/fit.dart': '''
enum Fit { cover, contain }
''',
  'lib/sink.dart': '''
import 'package:doc_ref_import/fit.dart';

void take(Fit f) => print(f);
''',
  'lib/use.dart': '''
import 'package:doc_ref_import/fit.dart';
import 'package:doc_ref_import/sink.dart';

/// Passes [Fit.cover] — see [Fit].
void run() => take(Fit.cover);
''',
  'pubspec.yaml': '''
name: doc_ref_import
environment:
  sdk: ^3.10.0
''',
};

const unusedImportError = {
  'analysis_options.yaml': '''
analyzer:
  errors:
    unused_import: error
''',
  'lib/fit.dart': '''
enum Fit { cover, contain }
''',
  'lib/sink.dart': '''
import 'package:unused_import_error/fit.dart';

void take(Fit f) => print(f);
''',
  'lib/use.dart': '''
import 'package:unused_import_error/fit.dart';
import 'package:unused_import_error/sink.dart';

void run() => take(Fit.cover);
''',
  'pubspec.yaml': '''
name: unused_import_error
environment:
  sdk: ^3.10.0
''',
};

const typedefFixedArgs = {
  'bin/main.dart': r'''
import 'package:typedef_fixed_args/g.dart';

G<num> make() => IntG.of(1);

void main() {
  final G<num> g = IntG.of(1);
  final List<num> l = IntList.filled(1, 0);
  print('${g.runtimeType} ${make().runtimeType} ${l.runtimeType}');
  try {
    g.value = 1.5;
    l[0] = 1.5;
    print('stored doubles');
  } on TypeError catch (e) {
    print('TypeError: $e');
  }
}
''',
  'lib/g.dart': '''
class G<T> {
  G.of(this.value);
  T value;
}

typedef IntG = G<int>;
typedef IntList = List<int>;
''',
  'pubspec.yaml': '''
name: typedef_fixed_args
environment:
  sdk: ^3.10.0
''',
};

const staticTypeWiden = {
  'bin/main.dart': r'''
import 'package:static_type_widen/geo.dart';

void main() {
  // Cascade target: static type Box before, Geo after the forwarder rebind.
  final Geo a = Box.all(1)..log();
  final Geo b = Box.zero..log();
  print([a, b].length);

  // Promotion on assignment: Box is a type of interest, so `g = Box.all(2)`
  // promotes g to Box; `.all(2)` has static type Geo and does not.
  Geo g = const Geo();
  if (g is Box) print('never');
  g = Box.all(2);
  print('after ctor assignment: ${g.describe()}');
  g = const Geo();
  if (g is Box) print('never');
  g = Box.zero;
  print('after alias assignment: ${g.describe()}');
}
''',
  'lib/geo.dart': '''
class Geo {
  const Geo();
  const factory Geo.all(int v) = Box.all;
  static const Geo zero = Box.zero;
}

class Box extends Geo {
  const Box.all(this.v);
  final int v;
  static const Box zero = Box.all(0);
}

extension GeoDescribe on Geo {
  String describe() => 'Geo';
  void log() => print('log via Geo extension');
}

extension BoxDescribe on Box {
  String describe() => 'Box';
  void log() => print('log via Box extension');
}
''',
  'pubspec.yaml': '''
name: static_type_widen
environment:
  sdk: ^3.10.0
''',
};

const partOrphan = {
  'lib/fit.dart': '''
enum Fit { cover, contain }
''',
  'lib/lib.dart': '''
import 'package:part_orphan/fit.dart';
import 'package:part_orphan/sink.dart';

part 'lib_part.dart';
''',
  'lib/lib_part.dart': '''
part of 'lib.dart';

void run() => take(Fit.cover);
''',
  'lib/sink.dart': '''
import 'package:part_orphan/fit.dart';

void take(Fit f) => print(f);
''',
  'pubspec.yaml': '''
name: part_orphan
environment:
  sdk: ^3.10.0
''',
};

// Two classes named `X`: their display strings match, their types do not.
const displayCollision = {
  'bin/main.dart': '''
import 'package:dc/a.dart' as a;
import 'package:dc/b.dart' as b;
import 'package:dc/g.dart';

typedef AG = G<a.X>;

void main() {
  final G<b.X> g = AG.of(const a.X());
  try {
    g.value = const b.X();
    print('stored b.X');
  } on TypeError {
    print('TypeError: G<a.X> rejects b.X');
  }
}
''',
  'lib/a.dart': '''
import 'b.dart' as b;

class X extends b.X {
  const X();
}
''',
  'lib/b.dart': '''
class X {
  const X();
}
''',
  'lib/g.dart': '''
class G<T> {
  G.of(this.value);
  T value;
}
''',
  'pubspec.yaml': '''
name: dc
environment:
  sdk: ^3.10.0
''',
};

// The forwarder and the alias are @visibleForTesting; the originals are not.
const vftWarning = {
  'bin/main.dart': '''
import 'package:geo_pkg/geo.dart';

void use(Geo g) => print(g.runtimeType);

void main() {
  use(Box.all(1));
  use(Box.zero);
}
''',
  'geo_pkg/lib/geo.dart': '''
import 'package:meta/meta.dart';

class Geo {
  const Geo();
  @visibleForTesting
  const factory Geo.all(int v) = Box.all;
  @visibleForTesting
  static const Geo zero = Box.zero;
}

class Box extends Geo {
  const Box.all(this.v);
  final int v;
  static const Box zero = Box.all(0);
}
''',
  'geo_pkg/pubspec.yaml': '''
name: geo_pkg
environment:
  sdk: ^3.10.0
dependencies:
  meta: ^1.15.0
''',
  'lib/.keep': '',
  'pubspec.yaml': '''
name: vft
environment:
  sdk: ^3.10.0
dependencies:
  geo_pkg:
    path: geo_pkg
''',
};

// `.all(v: 2)` passes every node-level check (a licensed forwarder in a slot
// typed as it, with no restricting annotation of its own), but its argument
// lands on the forwarder's deprecated parameter: a second copy of the info
// `pre` already has. Only the multiset count catches it. It must be
// cross-package: within a package, the deprecation code is a lint.
const duplicateInfo = {
  'geo_pkg/lib/geo.dart': '''
class Geo {
  const Geo();
  const factory Geo.all({@Deprecated('use v2') int? v}) = Box.all;
}

class Box extends Geo {
  const Box.all({this.v});
  final int? v;
}
''',
  'geo_pkg/pubspec.yaml': '''
name: geo_pkg
environment:
  sdk: ^3.10.0
''',
  'lib/use.dart': '''
import 'package:geo_pkg/geo.dart';

final pre = Geo.all(v: 1);

void take(Geo g) => print(g);

void run() => take(Box.all(v: 2));
''',
  'pubspec.yaml': '''
name: duplicate_info
environment:
  sdk: ^3.10.0
dependencies:
  geo_pkg:
    path: geo_pkg
''',
};

// `dart analyze` reports `unused_result` on a shorthand of a `@useResult`
// member even where its value is used; the bundled analyzer does not.
const useResult = {
  'bin/main.dart': '''
import 'package:geo_pkg/geo.dart';

Geo ret(int x) => Geo.make(x);

Geo block(int x) {
  return Geo.named(x);
}

void main(List<String> args) {
  final x = args.length;
  use(Geo.make(x));
  use(Geo.named(x));
  use(Geo.origin);
  final Geo g = Geo.make(x);
  use(g);
  use(pass(Geo.make(x)));
  final list = <Geo>[Geo.make(x)];
  use(list.first);
  use(ret(x));
  use(block(x));
  use(Box.res(x));
}
''',
  'geo_pkg/lib/geo.dart': r'''
import 'package:meta/meta.dart';

class Geo {
  const Geo(this.v);
  final int v;
  @useResult
  static Geo make(int v) => Geo(v);
  @useResult
  factory Geo.named(int v) => Geo(v);
  @useResult
  static Geo get origin => const Geo(0);
  @useResult
  const factory Geo.res(int v) = Box.res;
}

class Box extends Geo {
  const Box.res(super.v);
}

void use(Geo g) => print('use ${g.v} ${g.runtimeType}');
Geo pass(Geo g) => g;
''',
  'geo_pkg/pubspec.yaml': '''
name: geo_pkg
environment:
  sdk: ^3.10.0
dependencies:
  meta: ^1.16.0
''',
  'lib/.keep': '',
  'pubspec.yaml': '''
name: use_result
environment:
  sdk: ^3.10.0
dependencies:
  geo_pkg:
    path: geo_pkg
''',
};
