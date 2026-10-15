import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/line_info.dart';
// The public `AnalysisContextCollection` factory takes neither a byte store
// nor an options hook; `dart analyze` and the analysis server build on these
// same classes.
// ignore_for_file: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:cli_util/cli_util.dart';
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

String? _cachedSdkPath;

/// Locates the Dart SDK for the analyzer, or null when none is found. A set
/// `DART_SDK` decides alone: null when it names no SDK, never a silent
/// fallback to another one. Unset, inside a JIT run the executable lives in
/// the SDK; an AOT-compiled binary does not, so fall back to the `dart` on
/// PATH (`which`, or `where` on Windows; following the Flutter shim, whose SDK
/// sits under `bin/cache/dart-sdk`). `package:cli_util`'s `sdkPath` is the
/// resolvedExecutable step alone — no validity check, no AOT or shim
/// fallback — so it cannot replace this.
String? sdkPath() {
  if (_cachedSdkPath != null) return _cachedSdkPath;

  final env = Platform.environment['DART_SDK'];
  if (env != null) return isDartSdk(env) ? _cachedSdkPath = env : null;

  final exeSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  if (isDartSdk(exeSdk)) return _cachedSdkPath = exeSdk;

  final which = _dartOnPath();
  if (which == null) return null;
  final String resolved;
  try {
    resolved = File(which).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  final bin = p.dirname(resolved);
  for (final candidate in [p.join(bin, 'cache', 'dart-sdk'), p.dirname(bin)]) {
    if (isDartSdk(candidate)) return _cachedSdkPath = candidate;
  }
  return null;
}

/// Whether [dir] is a Dart SDK: it holds `version` and `lib/_internal`.
bool isDartSdk(String dir) =>
    File(p.join(dir, 'version')).existsSync() &&
    Directory(p.join(dir, 'lib', '_internal')).existsSync();

/// `where` lists every match, with CRLF line endings.
String? _dartOnPath() {
  final ProcessResult lookup;
  try {
    lookup = Process.runSync(Platform.isWindows ? 'where' : 'which', ['dart']);
  } on ProcessException {
    return null;
  }
  if (lookup.exitCode != 0) return null;
  for (final line in LineSplitter.split(lookup.stdout.toString())) {
    if (line.trim() case final path when path.isNotEmpty) return path;
  }
  return null;
}

/// One `Type.member` occurrence that may convert to `.member`.
final class _Candidate({
  /// Start of the `Type` prefix to delete.
  required final int deleteStart,

  /// End (exclusive) of the deleted prefix — the char before the `.`.
  required final int deleteEnd,

  /// Offset of the `.` — where the shorthand node begins after the rewrite.
  required final int shorthandOffset,

  /// `Type` or `prefix.Type` as written — the imported reference the rewrite
  /// drops.
  required final String owner,

  /// `Type.member` as written, for reporting and skip-list matching.
  required final String display,

  /// The accessed member (`all` in `EdgeInsets.all`).
  required final String memberName,

  /// The declaring type's name — identity check anchor.
  required final String? containerName,

  /// The declaring library's URI — identity check anchor.
  required final String? libraryUri,

  /// For constructors, the instantiated return type and formal parameter
  /// list (see `_constructorSignature`); null for every other member. A
  /// redirecting-factory forwarder is accepted only against an identical one.
  final String? signature,

  /// The site's static type as a `_typeKey`; the shorthand must keep it.
  final String? staticType,

  /// The site's static type as displayed, for the kept reason.
  final String? shownType,

  /// The `_typeKey` of the slot a licensed rebind must land in exactly (see
  /// `_Viability.typedSlotOf`); null outside a typed slot.
  final String? typedSlot,

  /// The member's use-restricting annotations (see `_restrictionsOf`).
  final Set<String> restrictions = const {},

  /// Offset of the enclosing statement (or declaration, outside a body).
  /// Type inference does not cross that boundary, so two candidates with
  /// different keys cannot affect each other's resolution — which is what
  /// lets the recovery pass test one per key at a time in a single resolve.
  final int groupKey = -1,
}) {
  /// Creates a candidate; produced by the sanitizer's AST pass.
  this;
}

/// One reported `Type.member` site: converted, or (with [Sanitizer.explain])
/// left prefixed.
final class Site({
  /// 1-based line of the `Type` prefix, in the file as the run found it.
  required final int line,

  /// 1-based column of the `Type` prefix, in the file as the run found it.
  required final int column,

  /// `Type.member` as written.
  required final String before,

  /// `.member` when the site converted; null when it was kept.
  final String? after,

  /// Why the site stayed prefixed; null when it converted.
  final String? keptReason,
}) {
  /// Creates a site report.
  this;
}

/// One import directive pruned because a conversion orphaned it, with every
/// edit made beside it.
final class PrunedImport({
  /// 1-based line of the `import` keyword, in the file as the run found it.
  required final int line,

  /// The import's URI as written, without quotes.
  required final String uri,

  /// `library;` when the directive was replaced to keep the file's leading
  /// doc comment or annotation on the library; null when it was removed.
  final String? replacement,

  /// The trailing `//` comment deleted with the directive.
  final String? deletedComment,

  /// The trailing `// ignore_for_file:` comment left on the line, since it
  /// covers the whole file.
  final String? keptComment,
}) {
  /// Creates a pruned-import report.
  this;

  /// `"line: import 'uri' -> removed"`, naming any side edit.
  String get description => [
    "$line: import '$uri' -> ${replacement ?? 'removed'}",
    if (deletedComment case final c?) ', with its trailing comment $c',
    if (keptComment case final c?)
      ', keeping its trailing comment $c on the line',
  ].join();
}

/// Per-file outcome of a sanitize run.
final class FileResult(
  /// Canonical path of the rewritten file.
  final String path,
  List<Site> sites,

  /// Candidates that failed verification and were left prefixed.
  final int reverted, {

  /// Imports pruned from this file because a conversion — here or in another
  /// unit of its library — orphaned them (see [Sanitizer]), by line.
  List<PrunedImport> prunedImports = const [],
}) {
  /// Creates a result for [path]; [sites] are kept sorted by line, then
  /// column.
  this;

  /// Imports pruned from this file, by line.
  final List<PrunedImport> prunedImports = [...prunedImports]
    ..sort((a, b) => a.line.compareTo(b.line));

  /// How many imports were pruned from this file.
  int get removedImports => prunedImports.length;

  /// Every converted site and, with [Sanitizer.explain], every site left
  /// prefixed — skip-listed, ruled out by the static pre-check, or refused by
  /// the verify loop — by line, then column.
  final List<Site> sites = [...sites]
    ..sort(
      (a, b) => a.line != b.line
          ? a.line.compareTo(b.line)
          : a.column.compareTo(b.column),
    );

  /// One `"line: Type.member -> .member"` entry per converted site.
  List<String> get converted => [
    for (final s in sites)
      if (s.after case final after?) '${s.line}: ${s.before} -> $after',
  ];

  /// With [Sanitizer.explain], one `"line: Type.member kept: reason"` entry
  /// per site left prefixed; empty otherwise.
  List<String> get kept => [
    for (final s in sites)
      if (s.keptReason case final reason?)
        '${s.line}: ${s.before} kept: $reason',
  ];
}

/// Aggregate outcome across all files of a run.
final class SanitizeResult {
  /// Every file written (or, in a dry run, that would be): one with a
  /// converted site or a pruned import — and, with [Sanitizer.explain], every
  /// file with a site left prefixed. One entry per path.
  final List<FileResult> files = [];

  /// Sites left prefixed because they matched the skip list.
  int skippedByList = 0;

  /// Files skipped whole because their package's language version predates
  /// dot shorthands, counted per package root and `major.minor` version (the
  /// file's directory when no `pubspec.yaml` encloses it). Such a package
  /// cannot hold the rewrite at all, so an otherwise convertible run reports
  /// zero conversions — this is what makes that visible.
  final Map<({String root, String version}), int> skippedBelowFloor = {};

  /// Files skipped whole per package root: no entry in the package config the
  /// analyzer used; run `dart pub get` in `root`.
  final Map<String, int> skippedUnconfigured = {};

  /// Files skipped whole because their library already has an error-severity
  /// diagnostic, as canonical paths; see [Sanitizer.allowErrors].
  final List<String> skippedWithErrors = [];

  /// Conversions dropped because a file they had to write could not be
  /// written; [Sanitizer.run] records them here instead of throwing. `file`
  /// is the file whose conversion was dropped, `path` the one that could not
  /// be written (`file` itself, or a unit of its library losing an orphaned
  /// import), `error` the OS's reason. Such a conversion and the imports it
  /// prunes are written all or nothing; files converted before it, even in
  /// the same library, stay written.
  final List<({String file, String path, String error})> writeFailures = [];

  /// Part files skipped whole because the library they declare `part of`
  /// does not exist, as canonical paths.
  final List<String> skippedOrphanParts = [];

  /// Directories whose listing failed, with the OS's reason: none of their
  /// files were processed.
  final List<({String path, String error})> unreadableDirectories = [];

  /// Files skipped because their leading comment declares them generated
  /// ([Sanitizer.isGenerated]), as canonical paths.
  final List<String> skippedGenerated = [];

  /// Files left alone by [Sanitizer.excludes] or an `analysis_options.yaml`
  /// exclude, as canonical paths, with the rule that matched.
  final List<({String path, String reason})> excluded = [];

  /// [Sanitizer.skips] entries that matched no site in the run.
  final Set<String> unmatchedSkips = {};

  /// [Sanitizer.excludes] globs that matched no file in the run.
  final List<String> unmatchedExcludes = [];

  /// Whether a file the run should have processed was skipped instead: below
  /// the language floor, unconfigured, with analysis errors, an orphan part,
  /// or under an unreadable directory. Generated and excluded files are left
  /// alone by request and do not count.
  bool get hasSkips =>
      skippedBelowFloor.isNotEmpty ||
      skippedUnconfigured.isNotEmpty ||
      skippedWithErrors.isNotEmpty ||
      skippedOrphanParts.isNotEmpty ||
      unreadableDirectories.isNotEmpty;

  /// Total converted sites.
  int get convertedCount => files.fold(0, (n, f) => n + f.converted.length);

  /// Total reverted sites.
  int get revertedCount => files.fold(0, (n, f) => n + f.reverted);

  /// Total imports pruned because the conversion orphaned them.
  int get removedImportCount => files.fold(0, (n, f) => n + f.removedImports);

  /// Total explained sites left prefixed, skip-listed ones included; zero
  /// without [Sanitizer.explain].
  int get keptCount => files.fold(0, (n, f) => n + f.kept.length);
}

/// Rewrites `Type.member` to dot-shorthand `.member` (enum values, static
/// getters/fields/methods, named — incl. factory/const — constructors) at
/// every site where the rewrite provably resolves to the SAME element with the
/// SAME static type.
///
/// Strategy per file: filter out sites that cannot verify statically, rewrite
/// every remaining candidate, resolve the rewritten text, then keep only
/// candidates whose shorthand node resolved back to the original element with
/// the same static type, no new use-restricting annotations (`@useResult`,
/// `@Deprecated`, `@visibleForTesting`, `@internal`, `@protected`, etc.), and
/// no new diagnostics in the library. Anything else — unwitnessed context
/// (`Object`, generics), typedefs fixing type arguments
/// (`typedef IntG = G<int>`), members living on a sibling namespace
/// (`Colors.red` in a `Color` slot), silent rebinds to a same-named static —
/// is reverted.
///
/// Two cross-type rebinds are licensed, both observably no-ops when they land
/// in a typed slot of the target type (`_Viability.typedSlotOf`) and add no
/// disallowed restriction:
/// - a `static const` alias of the original
///   (`AlignmentGeometry.topCenter = Alignment.topCenter`) — a different
///   element holding the identical canonicalized constant. Const-value
///   identity, not element identity, decides — see `_isConstAlias`.
/// - a redirecting factory whose chain ends at the original constructor with
///   compatible formal parameters (`const factory EdgeInsetsGeometry.all(double
///   value) = EdgeInsets.all`) — the language forwards the arguments
///   untouched, so `.all(8)` in an `EdgeInsetsGeometry` slot constructs the
///   very `EdgeInsets` the prefix did. See `_ResolvedShorthand.forwardsTo`.
///
/// Dropping a `Type` prefix can orphan the import that supplied it. The
/// verified resolve is the oracle: an `unused_import`/`unnecessary_import` it
/// reports that the original did not is self-inflicted, so its directive is
/// pruned. Imports the file already left unused are the user's — they stay.
final class Sanitizer({
  /// `Type.member`, `prefix.Type.member` or bare `member` names that must
  /// stay prefixed; anything else throws an [ArgumentError].
  Set<String> skips = const {},

  /// Glob patterns of files to leave alone. A glob with a `/` matches the
  /// path relative to the working directory, like the paths handed to [run]
  /// (`lib/legacy/**`, `**/legacy/**`); one without matches the file name
  /// (`firebase_options.dart`, `*.g.dart`).
  final List<String> excludes = const [],

  /// Report what would convert without writing any file.
  final bool dryRun = false,

  /// Skip files whose leading comment declares them generated ([isGenerated]).
  final bool skipGenerated = true,

  /// Also report every site left prefixed, with the reason
  /// ([FileResult.kept]).
  final bool explain = false,

  /// Also rewrite files whose library already has an error-severity
  /// diagnostic; otherwise they are listed in
  /// [SanitizeResult.skippedWithErrors] and left alone.
  final bool allowErrors = false,

  /// Leave alone files matching the `analyzer: exclude:` globs of their own
  /// package's `analysis_options.yaml`. Unlike `dart analyze`, a parent
  /// package's excludes never reach a nested package. They are listed in
  /// [SanitizeResult.excluded].
  final bool analyzerExcludes = true,
}) {
  /// Creates a sanitizer; see [run].
  this;

  /// `Type.member`, `prefix.Type.member` or bare `member` names that must
  /// stay prefixed.
  final Set<String> skips = {
    for (final entry in skips)
      if (isSkipEntry(entry))
        entry
      else
        throw ArgumentError.value(
          entry,
          'skips',
          'expected Type.member, prefix.Type.member or member',
        ),
  };

  static final _skipShape = RegExp(
    r'^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*){0,2}$',
  );

  /// Whether [entry] is a valid [skips] entry: `Type.member`,
  /// `prefix.Type.member` or `member`, as written — no padding, no list.
  static bool isSkipEntry(String entry) => _skipShape.hasMatch(entry);

  /// Language version that introduced dot shorthands.
  static const _floorMajor = 3;
  static const _floorMinor = 10;

  static final _generatedMarker = RegExp(
    r'\b(auto[-\s]?generated|generated\s+(code|file|by))\b',
    caseSensitive: false,
  );

  /// [_generatedMarker] opening a doc comment's text.
  static final _docMarker = RegExp(
    r'^(auto[-\s]?generated|generated\s+(code|file|by))\b',
    caseSensitive: false,
  );

  /// Generated-code filter: the file's leading comment says so (build_runner,
  /// FlutterFire, pigeon, protoc, slang). Filename shape (`*.g.dart` vs a
  /// handwritten `*.preview.dart`) proves nothing, the header does.
  ///
  /// The banner is the run of `//`, `#` and `/* … */` comments before the
  /// first other token: a generator writes its marker there, so a comment
  /// below the first declaration is ordinary prose no matter what it says. A
  /// doc comment (`///` or `/** … */`) documents the library or the first
  /// declaration, so it ends the banner, and counts only when its text opens
  /// with the marker (`/// Generated file. Do not edit.`, as slang writes):
  /// a library doc merely mentioning "generated code" is prose. A leading BOM
  /// is skipped, and a banner of any length is read whole. The marker matches
  /// `generated`/`auto-generated`, never the bare stem — that would flag a
  /// handwritten header merely noting that something *regenerates*.
  static bool isGenerated(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      return false;
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    String lineFrom(int start) {
      final end = text.indexOf('\n', start);
      return text.substring(start, end == -1 ? text.length : end);
    }

    var i = 0;
    while (true) {
      while (i < text.length && text[i].trim().isEmpty) {
        i++;
      }
      final rest = text.substring(i);
      if (rest.startsWith('///')) {
        return _docMarker.hasMatch(lineFrom(i).substring(3).trimLeft());
      }
      if (rest.startsWith('/**') && !rest.startsWith('/**/')) {
        final close = text.indexOf('*/', i + 3);
        final body = text.substring(i + 3, close == -1 ? text.length : close);
        return _docMarker.hasMatch(body.replaceFirst(RegExp(r'^[\s*]*'), ''));
      }
      if (rest.startsWith('//') || rest.startsWith('#')) {
        final line = lineFrom(i);
        if (_generatedMarker.hasMatch(line)) return true;
        i += line.length;
        continue;
      }
      if (rest.startsWith('/*')) {
        final close = text.indexOf('*/', i + 2);
        final body = text.substring(i + 2, close == -1 ? text.length : close);
        if (_generatedMarker.hasMatch(body)) return true;
        if (close == -1) return false;
        i = close + 2;
        continue;
      }
      return false;
    }
  }

  /// Sanitizes every non-generated `.dart` file under [paths]
  /// (files or directories).
  ///
  /// Throws a [StateError] when no Dart SDK is found (see [sdkPath]).
  Future<SanitizeResult> run(List<String> paths) async {
    final sdk = sdkPath();
    if (sdk == null) {
      throw StateError(switch (Platform.environment['DART_SDK']) {
        final env? => 'DART_SDK is set to $env, which is not a Dart SDK',
        null => 'could not locate the Dart SDK: set DART_SDK to its directory',
      });
    }
    final globs = {for (final e in excludes) e: Glob(e)};
    final matchedGlobs = <String>{};
    final cwd = _real(p.current);
    String? excludedBy(String path) {
      final relative = p
          .relative(_real(path), from: cwd)
          .replaceAll(p.separator, '/');
      for (final MapEntry(key: pattern, value: glob) in globs.entries) {
        final subject = pattern.contains('/') ? relative : p.basename(path);
        if (glob.matches(subject)) {
          matchedGlobs.add(pattern);
          return 'matches --exclude "$pattern"';
        }
      }
      return null;
    }

    final result = SanitizeResult();
    final collected = _collectFiles(paths, excludedBy, result);
    final matchedSkips = <String>{};
    try {
      if (collected.isEmpty) return result;
      await _runOn(collected, paths, sdk, excludedBy, result, matchedSkips);
      return result;
    } finally {
      result.unmatchedSkips.addAll(skips.difference(matchedSkips));
      result.unmatchedExcludes.addAll(
        excludes.where((e) => !matchedGlobs.contains(e)),
      );
    }
  }

  Future<void> _runOn(
    List<String> collected,
    List<String> paths,
    String sdk,
    String? Function(String path) excludedBy,
    SanitizeResult result,
    Set<String> matchedSkips,
  ) async {
    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    final gate = _PackageGate();
    // Roots, not files: the locator spends ~2ms per included path, a second
    // per 500 files. Every discovered package root is included explicitly so
    // each nested package gets its own AnalysisContext, language version and
    // package config.
    final packageRoots = {for (final f in collected) ?gate.rootOf(f)};
    final roots = {...paths.map(_canonical), ...packageRoots};
    final collection = AnalysisContextCollectionImpl(
      includedPaths: [
        for (final root in roots)
          if (packageRoots.contains(root) ||
              !roots.any((other) => p.isWithin(other, root)))
            root,
      ],
      resourceProvider: overlay,
      sdkPath: sdk,
      byteStore: _byteStore(),
      // Lint rules run on every speculative resolve and inform no verdict —
      // only errors and the analyzer's own import warnings do.
      configureAnalysisOptionsBuilder: ({required analysisOptionsBuilder}) {
        analysisOptionsBuilder
          ..lint = false
          ..lintRules = [];
      },
    );
    try {
      final contexts = [...collection.contexts]
        ..sort(
          (a, b) => b.contextRoot.root.path.length.compareTo(
            a.contextRoot.root.path.length,
          ),
        );
      AnalysisContext contextOf(String file) => contexts.firstWhere(
        (c) =>
            c.contextRoot.root.isOrContains(file) ||
            c.contextRoot.root.isOrContains(_real(file)),
      );
      // Unlike `dart analyze`, a package obeys only its own options file: one
      // inherited from an enclosing package (its `example/**`) excludes
      // nothing here.
      String? analyzerExcluded(String file) {
        if (!analyzerExcludes) return null;
        final root = contextOf(file).contextRoot;
        final options = root.optionsFile?.path;
        final package = gate.rootOf(file);
        if (options == null ||
            package == null ||
            !(p.isWithin(package, options) ||
                p.isWithin(_real(package), _real(options)))) {
          return null;
        }
        if (root.isAnalyzed(file) || root.isAnalyzed(_real(file))) return null;
        return 'excluded by $options';
      }

      final files = <String>[];
      for (final file in collected) {
        if (analyzerExcluded(file) case final reason?) {
          result.excluded.add((path: file, reason: reason));
        } else {
          files.add(file);
        }
      }

      // Pruning may edit another unit of a file's library: only one this run
      // would have processed itself.
      final scope = files.map(_real).toSet();
      String? offLimits(String path) => switch (path) {
        _ when scope.contains(_real(path)) => null,
        _ when excludedBy(path) != null => 'excluded',
        _ when analyzerExcluded(path) != null => 'excluded',
        _ when skipGenerated && isGenerated(path) => 'generated',
        _ => 'not among the given paths',
      };

      // A dry run writes nothing, so each verified rewrite stays in the
      // overlay for the rest of the run: every later file of its library is
      // judged against the text a real run would have written.
      final verified = <String, String>{};
      final origins = _Origins();
      // A file pruned for one of its parts may convert sites of its own too.
      final byPath = <String, FileResult>{};
      for (final file in files) {
        for (final r in await _sanitizeFile(
          contextOf(file),
          overlay,
          file,
          result,
          gate,
          offLimits,
          verified,
          origins,
          matchedSkips,
        )) {
          byPath.update(
            r.path,
            (prior) => FileResult(
              r.path,
              [...prior.sites, ...r.sites],
              prior.reverted + r.reverted,
              prunedImports: [...prior.prunedImports, ...r.prunedImports],
            ),
            ifAbsent: () => r,
          );
        }
      }
      result.files.addAll(byPath.values);
    } finally {
      await collection.dispose();
    }
  }

  /// Linked element models — the SDK's, every package's, every library's —
  /// persist across runs under the user's cache home (`~/Library/Caches`,
  /// `$XDG_CACHE_HOME`, `%LOCALAPPDATA%`), at most 1 GiB, least recently
  /// used evicted first. Linking them dominates the first run on a codebase;
  /// the next run — `--dry-run`, then for real — finds them ready and takes
  /// less than half the time. Entries are keyed by content signature, so a
  /// stale one is never a wrong one. A memory tier of the same size fronts
  /// the files: a smaller one thrashed, re-reading what it had just written
  /// and doubling the cold run. No usable cache home → memory only.
  static ByteStore _byteStore() {
    // cli_util knows no cache home elsewhere and throws an Error for it.
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      return MemoryByteStore();
    }
    try {
      final dir = BaseDirectories('dotsan').cacheHome;
      Directory(dir).createSync(recursive: true);
      return MemoryCachingByteStore(
        EvictingFileByteStore(dir, 1 << 30),
        1 << 30,
      );
    } on Exception {
      return MemoryByteStore();
    }
  }

  Future<List<FileResult>> _sanitizeFile(
    AnalysisContext context,
    OverlayResourceProvider overlay,
    String file,
    SanitizeResult result,
    _PackageGate gate,
    String? Function(String path) offLimits,
    Map<String, String> verified,
    _Origins origins,
    Set<String> matchedSkips,
  ) async {
    // Without its own package config a package is analyzed as part of
    // whichever one encloses it, at that package's language version.
    final root = gate.rootOf(file);
    if (root != null && !await gate.isConfigured(context, file, root)) {
      result.skippedUnconfigured.update(root, (n) => n + 1, ifAbsent: () => 1);
      return const [];
    }

    final library = await context.currentSession.getResolvedLibraryContaining(
      file,
    );
    if (library is NotLibraryButPartResult) {
      result.skippedOrphanParts.add(file);
      return const [];
    }
    if (library is! ResolvedLibraryResult) {
      throw StateError('could not resolve $file: ${library.runtimeType}');
    }
    final original =
        library.unitWithPath(file) ??
        (throw StateError('$file is missing from its own library'));

    // The installed SDK does not decide this — the package's own `environment:
    // sdk:` constraint does. Below the floor every rewrite fails to parse, so
    // the verify loop would revert all of them and report an ordinary
    // "converted 0 site(s)", indistinguishable from having nothing to convert.
    final language = library.element.languageVersion.effective;
    if (language.major < _floorMajor ||
        (language.major == _floorMajor && language.minor < _floorMinor)) {
      result.skippedBelowFloor.update(
        (
          root: root ?? p.dirname(file),
          version: '${language.major}.${language.minor}',
        ),
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      return const [];
    }

    if (!allowErrors &&
        library.units.any(
          (u) => u.diagnostics.any((d) => d.severity == .error),
        )) {
      result.skippedWithErrors.add(file);
      return const [];
    }

    final collector = _CandidateCollector(original.typeProvider);
    original.unit.accept(collector);
    for (final site in collector.sites) {
      matchedSkips.addAll(_skipsMatching(site));
    }
    final candidates = <_Candidate>[];
    final kept = [...collector.unviable];
    for (final c in collector.candidates) {
      if (_isSkipped(c)) {
        result.skippedByList++;
        kept.add((
          offset: c.deleteStart,
          display: c.display,
          reason: 'skip-listed',
        ));
      } else {
        candidates.add(c);
      }
    }
    if (candidates.isEmpty) {
      return [
        if (explain && kept.isNotEmpty)
          FileResult(
            file,
            _keptSites(
              (offset) => origins.locate(file, original.lineInfo, offset),
              kept,
            ),
            collector.unviable.length,
          ),
      ];
    }

    return await _FileSanitizer(
      context: context,
      overlay: overlay,
      file: file,
      library: library,
      original: original,
      candidates: candidates,
      unviable: collector.unviable.length,
      kept: explain ? kept : null,
      dryRun: dryRun,
      verified: verified,
      origins: origins,
      offLimits: offLimits,
      result: result,
      packageRootOf: gate.rootOf,
    ).run();
  }

  /// [c] as written, by its declaring type (`m.Fit.cover` and a typedef's
  /// `Mode.cover` both match `Fit.cover`), or by its bare member name.
  bool _isSkipped(_Candidate c) => _skipsMatching((
    display: c.display,
    memberName: c.memberName,
    containerName: c.containerName,
  )).isNotEmpty;

  /// The [skips] entries naming [site]; see [_isSkipped].
  Iterable<String> _skipsMatching(_SiteName site) => [
    site.display,
    site.memberName,
    if (site.containerName case final container?)
      '$container.${site.memberName}',
  ].where(skips.contains);

  /// Canonical paths of the files under [paths], each once, sorted. Files
  /// left alone — excluded, generated — and unreadable directories are
  /// recorded in [result].
  List<String> _collectFiles(
    List<String> paths,
    String? Function(String path) excludedBy,
    SanitizeResult result,
  ) {
    // Keyed by real path: one file reached through a symlink and directly
    // is still one file.
    final files = <String, String>{};
    final seen = <String>{};
    void consider(String path) {
      final canonical = _canonical(path);
      if (!seen.add(_real(canonical))) return;
      if (excludedBy(canonical) case final reason?) {
        result.excluded.add((path: canonical, reason: reason));
      } else if (skipGenerated && isGenerated(canonical)) {
        result.skippedGenerated.add(canonical);
      } else {
        files.putIfAbsent(_real(canonical), () => canonical);
      }
    }

    for (final rootPath in paths) {
      if (FileSystemEntity.isFileSync(rootPath)) {
        if (rootPath.endsWith('.dart')) consider(rootPath);
        continue;
      }
      if (!FileSystemEntity.isDirectorySync(rootPath)) continue;

      final dirQueue = <Directory>[Directory(rootPath)];
      while (dirQueue.isNotEmpty) {
        final dir = dirQueue.removeLast();
        final List<FileSystemEntity> entities;
        try {
          entities = dir.listSync(followLinks: false);
        } on FileSystemException catch (e) {
          result.unreadableDirectories.add((
            path: _canonical(dir.path),
            error: e.osError?.message ?? e.message,
          ));
          continue;
        }
        // A package's own build output, not a `build/` directory of sources.
        final isPackageRoot = File(p.join(dir.path, 'pubspec.yaml'))
            .existsSync();
        for (final entity in entities) {
          final base = p.basename(entity.path);
          if (entity is Directory) {
            if (base.startsWith('.') || (isPackageRoot && base == 'build')) {
              continue;
            }
            dirQueue.add(entity);
          } else if (entity is File && entity.path.endsWith('.dart')) {
            consider(entity.path);
          }
        }
      }
    }
    return files.values.toList()..sort();
  }
}

/// Absolute and normalized, case kept: `p.canonicalize` lowercases on
/// Windows, where package-config roots keep their case.
String _canonical(String path) => p.normalize(p.absolute(path));

/// [path] with symlinks resolved, for deciding membership only: a path
/// through a link (macOS `/tmp` and `/var` are links) and the real one must
/// match, while reports keep the path as given.
String _real(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// Which package a file belongs to, and whether the analyzer was handed that
/// package's own config. One per [Sanitizer.run]; lookups are memoised.
final class _PackageGate() {
  final _roots = <String, String?>{};
  final _configs = <String, PackageConfig?>{};

  String? rootOf(String file) =>
      _rootOfDir(p.dirname(file)) ?? _rootOfDir(p.dirname(_real(file)));

  String? _rootOfDir(String dir) {
    if (_roots.containsKey(dir)) return _roots[dir];
    final parent = p.dirname(dir);
    return _roots[dir] = switch (dir) {
      _ when File(p.join(dir, 'pubspec.yaml')).existsSync() => dir,
      _ when parent == dir => null,
      _ => _rootOfDir(parent),
    };
  }

  /// Whether [c]'s package config has an entry whose root is [root] and
  /// which holds [file]. A nested package without its own config joins the
  /// enclosing package's context, whose config attributes the file to the
  /// enclosing package — so a config merely existing proves nothing.
  Future<bool> isConfigured(AnalysisContext c, String file, String root) async {
    final packagesFile = c.contextRoot.packagesFile;
    if (packagesFile == null) return false;
    final config = await _configOf(packagesFile.path);
    final pkg =
        config?.packageOf(Uri.file(file)) ??
        config?.packageOf(Uri.file(_real(file)));
    return pkg != null &&
        (p.equals(_canonical(p.fromUri(pkg.root)), root) ||
            p.equals(_real(p.fromUri(pkg.root)), _real(root)));
  }

  Future<PackageConfig?> _configOf(String path) async {
    if (_configs.containsKey(path)) return _configs[path];
    try {
      return _configs[path] = await loadPackageConfig(File(path));
    } on Exception {
      return _configs[path] = null;
    }
  }
}

/// The verify-and-narrow pipeline for one file: apply every candidate, read
/// the verdict off the rewritten resolve, drop what it convicts, then re-offer
/// what a broken neighbour may merely have starved. Owns [file]'s overlay for
/// the duration of [run].
final class _FileSanitizer({
  required final AnalysisContext context,
  required final OverlayResourceProvider overlay,
  required final String file,
  required final List<_Candidate> candidates,

  /// Sites the collector's static pre-check ruled out before any resolve;
  /// reported as reverted, since they too stay prefixed.
  required final int unviable,

  /// Sites left prefixed before any resolve, when explaining; the verify
  /// loop's refusals join them in [FileResult.kept]. Null: not explaining.
  required final List<_Kept>? kept,
  required final bool dryRun,

  /// The dry run's verified texts so far, by path: they stand in for the
  /// writes it does not make, so an overlay this file leaves is restored to
  /// one of them instead of to the disk.
  required final Map<String, String> verified,

  /// The run's edits so far, which every reported line is mapped back
  /// through; this file's are added once its own are reported.
  required final _Origins origins,
  required final ResolvedLibraryResult library,
  required final ResolvedUnitResult original,
  required final String? Function(String path) offLimits,
  required final SanitizeResult result,
  required final String? Function(String path) packageRootOf,
}) {
  final String content = original.content;

  /// Every diagnostic of [file]'s library before the rewrite, counted per
  /// key. A rewrite may add none.
  final Map<_DiagKey, int> baseline = _census(library);

  /// Imports already unused (or unnecessary) before the rewrite: the user's
  /// to keep, so only orphans the rewrite newly creates get pruned.
  final Set<_ImportIssue> _userImportIssues = _importIssuesOf(library);
  final _constCache = <(String, String, String), DartObject?>{};

  /// Candidates still in the running; once [_clean] is set, exactly the ones
  /// it converts.
  List<_Candidate> _active = [...candidates]..sort(_byOffset);
  final _dropped = <_Candidate>[];
  _Rewritten? _clean;
  ResolvedLibraryResult? _cleanLibrary;

  /// The latest verdict's reason for each refused candidate.
  final _why = <_Candidate, String>{};

  /// Directive edits to apply on write, per unit path of [file]'s library;
  /// [file]'s in [_clean]'s coordinates, every other unit's in its own.
  var _orphanCuts = const <String, List<_DirectiveCut>>{};

  final _overlaid = <String>{};

  Future<List<FileResult>> run() async {
    Map<String, String>? texts;
    // What each unit's text now carries: every unit a dry run stands in for,
    // or every unit a write reached, even when a later one failed.
    var applied = const <String, _UnitEdits>{};
    try {
      if (await _converge()) await _recover();
      texts = await _finalize();
      if (texts != null && dryRun) applied = _editsByUnit();
      // Written while the overlays still hold the same text: removing them
      // first would have the analyzer re-read the pre-write disk, and every
      // later file of the library would be judged against stale text.
      if (texts != null && !dryRun) {
        final edits = _editsByUnit();
        // All or nothing: a part written without its library leaves the
        // import it orphaned behind.
        final unwritable = _unwritable(texts.keys);
        final (:written, :failure) = unwritable == null
            ? _writeAll(texts)
            : (written: const <String>[], failure: unwritable);
        applied = {for (final path in written) path: ?edits[path]};
        if (failure case (:final path, :final error)) {
          result.writeFailures.add((file: file, path: path, error: error));
          final shown = p.relative(path, from: p.dirname(file));
          _refuseAll('cannot write $shown: $error');
          texts = null;
        }
      }
    } finally {
      // Unconditional: an overlay holds speculative text, so bailing out with
      // it still installed leaks an unverified rewrite into every file
      // resolved after it in the same context. A dry run keeps its verified
      // text instead, standing in for the write it does not make.
      for (final path in _overlaid) {
        if (texts?[path] case final text? when dryRun) verified[path] = text;
        if (verified[path] case final text?) {
          overlay.setOverlay(path, content: text, modificationStamp: ++_stamp);
        } else {
          overlay.removeOverlay(path);
        }
        context.changeFile(path);
      }
      await context.applyPendingFileChanges();
    }

    // No verified set: nothing converts and the files stay untouched.
    final converted = texts == null ? const <_Candidate>[] : _active;
    final cuts = texts == null
        ? const <String, List<_DirectiveCut>>{}
        : _orphanCuts;
    final done = converted.toSet();
    final deletions = [
      for (final c in converted)
        (start: c.deleteStart, end: c.deleteEnd, length: 0),
    ];
    CharacterLocation at(int offset) =>
        origins.locate(file, original.lineInfo, offset);
    final results = [
      if (converted.isNotEmpty || kept != null)
        FileResult(
          file,
          [
            for (final c in converted)
              _siteAt(at, c.deleteStart, c.display, after: '.${c.memberName}'),
            if (kept case final kept?)
              ..._keptSites(at, [
                ...kept,
                for (final c in candidates)
                  if (!done.contains(c))
                    (
                      offset: c.deleteStart,
                      display: c.display,
                      reason: _why[c] ?? _unverified,
                    ),
              ]),
          ],
          candidates.length - converted.length + unviable,
          prunedImports: [
            for (final cut in cuts[file] ?? const <_DirectiveCut>[])
              cut.info(at(_unapply(deletions, cut.keyword)).lineNumber),
          ],
        ),
      for (final unit in library.units)
        if (cuts[unit.path] case final pruned? when unit.path != file)
          FileResult(
            unit.path,
            const [],
            0,
            prunedImports: [
              for (final cut in pruned)
                cut.info(
                  origins
                      .locate(unit.path, unit.lineInfo, cut.keyword)
                      .lineNumber,
                ),
            ],
          ),
    ];
    for (final MapEntry(key: path, value: (:before, :batches))
        in applied.entries) {
      origins.record(path, before, batches);
    }
    return results;
  }

  /// The edits writing the verified set makes to each unit of the library,
  /// with the lines of the text they apply to.
  Map<String, _UnitEdits> _editsByUnit() => {
    file: (
      before: original.lineInfo,
      batches: [
        [
          for (final c in _active)
            (start: c.deleteStart, end: c.deleteEnd, length: 0),
        ],
        [
          for (final cut in _orphanCuts[file] ?? const <_DirectiveCut>[])
            _editOf(cut),
        ],
      ],
    ),
    for (final MapEntry(key: path, value: cuts) in _orphanCuts.entries)
      if (path != file)
        if (library.unitWithPath(path) case final unit?)
          path: (
            before: unit.lineInfo,
            batches: [
              [for (final cut in cuts) _editOf(cut)],
            ],
          ),
  };

  /// Narrows [_active] to a set that verifies clean, if one exists. Returns
  /// false when the speculative text stopped resolving at all.
  ///
  /// Failure is attributed by evidence on the candidate's own node, never by
  /// proximity: a shorthand that did not resolve, or rebound elsewhere, names
  /// its author exactly, and dropping those re-verifies clean for ordinary
  /// files because the diagnostics they caused vanish with them. Proximity is
  /// what this replaces — a broken neighbour (a namespace-class static landing
  /// in a slot of an unrelated type) splashes its error onto the nearest
  /// candidate, regularly a perfectly valid site in the same argument list,
  /// and recovering those one per round left most of them behind.
  ///
  /// Only damage that no candidate accounts for — a cascade whose author
  /// resolved fine — falls back to bisection. Terminates: every iteration
  /// accepts or drops at least one candidate, and bisection exits the loop.
  Future<bool> _converge() async {
    while (_active.isNotEmpty) {
      final a = await _attempt(_active);
      if (a == null) return false;
      if (a.isClean) {
        _accept(a);
        return true;
      }
      if (a.culprits.isNotEmpty) {
        _dropped.addAll(a.culprits);
        _active = [
          for (final c in _active)
            if (!a.culprits.contains(c)) c,
        ];
        continue;
      }
      for (var round = 0; round < 3 && _active.isNotEmpty; round++) {
        _active = await _largestClean(_active);
        if (_active.isEmpty) break;
        final confirm = await _attempt(_active);
        if (confirm == null) return false;
        if (confirm.isClean) {
          _accept(confirm);
          break;
        }
      }
      return true;
    }
    return true;
  }

  /// Largest subset of [set] that verifies clean. Halving is deterministic and
  /// needs no proximity constant: a subset that verifies is accepted whole,
  /// and one that does not is split until each half either verifies or is a
  /// single candidate standing alone with its own verdict.
  Future<List<_Candidate>> _largestClean(List<_Candidate> set) async {
    if (set.isEmpty) return set;
    final a = await _attempt(set);
    if (a == null) return const [];
    if (a.isClean) return set;
    if (set.length == 1) {
      if (a.stray case final stray?) {
        _why[set.single] = 'introduces $stray';
      }
      return const [];
    }
    final mid = set.length ~/ 2;
    return [
      ...await _largestClean(set.sublist(0, mid)),
      ...await _largestClean(set.sublist(mid)),
    ];
  }

  /// Re-offers the dropped candidates: one may have been unresolvable only
  /// because a broken neighbour in the same statement starved it of a context
  /// type (`Pad.all(1) + Pad.only(2)`: the context-less LHS takes the RHS down
  /// with it). Candidates under different [_Candidate.groupKey]s cannot
  /// interact, so a whole wave is judged at once and the pass costs the
  /// largest statement's candidate count, not the number of dropped sites.
  ///
  /// Runs even when [_converge] accepted nothing: an empty verified base is
  /// the original file, which trivially resolves. A file made entirely of
  /// `static const x = Outer.all(Inner.of(1));` fields drops every candidate
  /// in round one — the context-less outer takes its own argument down with
  /// it — and only this pass can hand the inner sites back.
  Future<void> _recover() async {
    var pending = _dropped;
    while (pending.isNotEmpty) {
      final seen = <int>{};
      final wave = <_Candidate>[];
      final rest = <_Candidate>[];
      for (final c in pending) {
        (seen.add(c.groupKey) ? wave : rest).add(c);
      }
      pending = rest;
      // Skip a redundant full-set resolve when the trial would re-test the
      // exact initial candidate set that already failed in [_converge].
      if (_active.isEmpty && wave.length == candidates.length) continue;

      final trial = [..._active, ...wave]..sort(_byOffset);
      final a = await _attempt(trial);
      if (a == null) break;
      final regained = [
        for (final c in trial)
          if (!a.culprits.contains(c)) c,
      ];
      if (regained.length > _active.length) {
        final settled = a.isClean ? a : await _attempt(regained);
        if (settled != null && settled.isClean) {
          _active = a.isClean ? trial : regained;
          _accept(settled);
        } else if (settled?.stray case final stray?) {
          for (final c in wave) {
            if (!a.culprits.contains(c)) _why[c] = '$_unverified: $stray';
          }
        }
      }
    }
  }

  void _accept(_Attempt a) {
    _clean = a.rewritten;
    _cleanLibrary = a.library;
    _orphanCuts = _orphanRanges(a.library, _userImportIssues);
  }

  /// The texts to write — [_clean] and every unit losing an orphaned import,
  /// pruned — or null when nothing converts. Pruning is re-verified: if the
  /// pruned library gains any diagnostic, nothing in [file] converts.
  Future<Map<String, String>?> _finalize() async {
    while (true) {
      final clean = _clean;
      if (clean == null) return null;
      if (_orphanCuts.isEmpty) return {file: clean.text};

      var retried = false;
      for (final path in _orphanCuts.keys.where((other) => other != file)) {
        if (offLimits(path) case final why?) {
          final shown = p.relative(path, from: p.dirname(file));
          final reason =
              'pruning its orphaned imports would edit $shown, which is $why';
          final checkUnit = _cleanLibrary?.unitWithPath(path);
          final orphanImports = <ImportDirective>[
            if (checkUnit != null)
              for (final d in checkUnit.diagnostics)
                if (_isRemovableImport(d))
                  if (_importAt(checkUnit, d.offset) case final index?
                      when !_userImportIssues.contains((
                        path,
                        index,
                        d.diagnosticCode.lowerCaseName,
                      )))
                    if (checkUnit.unit.directives[index]
                        case final ImportDirective imp)
                      imp,
          ];
          final offenders = {
            for (final c in _active)
              if (orphanImports.any(
                (imp) => imp.libraryImport?.namespace.get2(c.owner) != null,
              ))
                c,
          };
          if (offenders.isEmpty || offenders.length == _active.length) {
            _refuseAll(reason);
            return null;
          }
          for (final c in offenders) {
            _why[c] = reason;
          }
          _active = [
            for (final c in _active)
              if (!offenders.contains(c)) c,
          ];
          final retry = await _attempt(_active);
          if (retry == null || !retry.isClean) {
            _refuseAll(reason);
            return null;
          }
          _accept(retry);
          retried = true;
          break;
        }
      }
      if (!retried) break;
    }

    final clean = _clean;
    if (clean == null) return null;
    final texts = {file: clean.text};
    for (final MapEntry(key: path, value: cuts) in _orphanCuts.entries) {
      final text = path == file
          ? clean.text
          : library.unitWithPath(path)?.content;
      if (text != null) texts[path] = _stripRanges(text, cuts);
    }
    texts.forEach(_overlay);
    await context.applyPendingFileChanges();
    final check = await context.currentSession.getResolvedLibraryContaining(
      file,
    );
    final stray = check is ResolvedLibraryResult
        ? _firstNew(check, (_, _) => false)
        : null;
    if (check is ResolvedLibraryResult && stray == null) return texts;

    final leaves = stray == null ? 'an unresolvable library' : _describe(stray);
    _refuseAll('pruning its orphaned imports leaves $leaves');
    return null;
  }

  void _refuseAll(String reason) {
    for (final c in _active) {
      _why[c] = reason;
    }
    _active = [];
  }

  void _overlay(String path, String text) {
    overlay.setOverlay(path, content: text, modificationStamp: ++_stamp);
    _overlaid.add(path);
    context.changeFile(path);
  }

  static ({String path, String error})? _unwritable(Iterable<String> paths) {
    for (final path in paths) {
      try {
        File(path).openSync(mode: .append).closeSync();
      } on FileSystemException catch (e) {
        return (path: path, error: e.osError?.message ?? e.message);
      }
    }
    return null;
  }

  /// Writes [texts]; a failure past the [_unwritable] check (a full disk) is
  /// reported, not thrown, along with the files already written.
  static ({List<String> written, ({String path, String error})? failure})
  _writeAll(Map<String, String> texts) {
    final written = <String>[];
    for (final MapEntry(key: path, value: text) in texts.entries) {
      try {
        _write(path, text);
      } on FileSystemException catch (e) {
        return (
          written: written,
          failure: (path: path, error: e.osError?.message ?? e.message),
        );
      }
      written.add(path);
    }
    return (written: written, failure: null);
  }

  /// The analyzer's content carries no BOM; one the file had is kept.
  static void _write(String path, String text) {
    final file = File(path);
    file.writeAsStringSync(_hasBom(file) ? '\uFEFF$text' : text);
  }

  static bool _hasBom(File file) {
    final raf = file.openSync();
    try {
      final head = raf.readSync(3);
      return head.length == 3 &&
          head[0] == 0xEF &&
          head[1] == 0xBB &&
          head[2] == 0xBF;
    } finally {
      raf.closeSync();
    }
  }

  /// Rewrites the file with [set] applied and resolves the result, or null if
  /// that text no longer resolves.
  Future<_Attempt?> _attempt(List<_Candidate> set) async {
    final rewritten = _apply(set);
    _overlay(file, rewritten.text);
    await context.applyPendingFileChanges();
    final check = await context.currentSession.getResolvedLibraryContaining(
      file,
    );
    if (check is! ResolvedLibraryResult) return null;
    final unit = check.unitWithPath(file);
    if (unit == null) return null;
    return await _verdict(rewritten, check, unit);
  }

  _Rewritten _apply(List<_Candidate> set) {
    final buffer = StringBuffer();
    final newOffsets = <_Candidate, int>{};
    var cursor = 0;
    var shift = 0;
    for (final c in [...set]..sort(_byOffset)) {
      buffer.write(content.substring(cursor, c.deleteStart));
      shift += c.deleteEnd - c.deleteStart;
      newOffsets[c] = c.shorthandOffset - shift;
      cursor = c.deleteEnd;
    }
    buffer.write(content.substring(cursor));
    return _Rewritten(buffer.toString(), newOffsets);
  }

  /// Node-level verdict on an applied set. A candidate is convicted only by
  /// its own shorthand node — it did not resolve, or it rebound to an element
  /// that is not a const alias of the original — so the verdict names the
  /// author exactly and the drop is final. Diagnostics deliberately accuse no
  /// one: the diagnostics a broken candidate causes vanish with it. Any the
  /// library gains only raise [_Attempt.stray], damage with no author, which
  /// forces the set to be bisected.
  ///
  /// Each conviction records its reason in [_why]: the analyzer's own error
  /// on the shorthand head, or the element it rebound to.
  Future<_Attempt> _verdict(
    _Rewritten rewritten,
    ResolvedLibraryResult library,
    ResolvedUnitResult check,
  ) async {
    final shorthands = _ShorthandIndex();
    check.unit.accept(shorthands);
    final selfUri = check.libraryElement.uri.toString();

    final culprits = <_Candidate>{};
    for (final MapEntry(key: candidate, value: offset)
        in rewritten.newOffsets.entries) {
      final resolved = shorthands.byOffset[offset];
      if (resolved == null || resolved.libraryUri == null) {
        culprits.add(candidate);
        _why[candidate] =
            _errorOn(check, offset, candidate.memberName) ??
            'the shorthand does not resolve';
      } else if (resolved.useResult) {
        // `dart analyze` reports `unused_result` on such a shorthand even
        // where its value is used; the bundled analyzer does not.
        culprits.add(candidate);
        _why[candidate] =
            'resolves to a @useResult member, whose shorthand dart analyze '
            'reports as unused';
      } else if (resolved.matches(candidate)) {
        if (resolved.staticType != candidate.staticType) {
          culprits.add(candidate);
          // Same display, different types: two classes named `X`.
          final to = resolved.shownType == candidate.shownType
              ? 'a different ${resolved.shownType}'
              : resolved.shownType;
          _why[candidate] =
              'changes the static type from ${candidate.shownType} to $to';
        }
      } else {
        final target = [?resolved.containerName, resolved.memberName].join('.');
        final licensed =
            resolved.forwardsTo(candidate) ||
            await _isConstAlias(candidate, resolved, selfUri);
        final inSlot =
            candidate.typedSlot != null &&
            candidate.typedSlot == resolved.staticType;
        final gained = resolved.restrictions
            .difference(candidate.restrictions)
            .where((r) => !_mayUse(r, resolved, selfUri))
            .toList();
        if (!licensed || !inSlot || gained.isNotEmpty) {
          culprits.add(candidate);
          _why[candidate] = switch ((licensed, inSlot)) {
            (false, _) => 'rebinds to $target',
            (true, false) => 'rebinds to $target outside a typed slot',
            (true, true) => 'rebinds to $target, which is ${gained.join(', ')}',
          };
        }
      }
    }

    // Removable import diagnostics are excused in every unit: the accepted
    // text gets its orphans pruned, and the pruned text is re-verified.
    final stray = culprits.isEmpty
        ? _firstNew(library, (_, d) => _isRemovableImport(d))
        : null;
    return _Attempt(
      rewritten,
      library,
      check,
      culprits,
      stray: stray == null ? null : _describe(stray),
    );
  }

  /// The first diagnostic [lib] has more of than [baseline] — the edited
  /// unit first, then the others in library order, each by offset — skipping
  /// [excused] ones; null when the library gained nothing.
  Diagnostic? _firstNew(
    ResolvedLibraryResult lib,
    bool Function(String path, Diagnostic d) excused,
  ) {
    final seen = <_DiagKey, int>{};
    for (final unit in [
      ...lib.units.where((u) => u.path == file),
      ...lib.units.where((u) => u.path != file),
    ]) {
      for (final d in _byPosition(unit.diagnostics)) {
        if (excused(unit.path, d)) continue;
        final key = _keyOf(unit.path, d);
        final count = seen.update(key, (n) => n + 1, ifAbsent: () => 1);
        if (count > (baseline[key] ?? 0)) return d;
      }
    }
    return null;
  }

  /// Whether [file] may use a member restricted by [annotation], as the SDK
  /// analyzer rules it: `@internal` within its own package,
  /// `@visibleForTesting` in its declaring library or under the package's
  /// `test/` or `integration_test/`, and `@protected` / `@visibleForTemplate` /
  /// `@visibleForOverriding` in its declaring library (or when a
  /// `@visibleForTesting` exemption also applies). Every other restriction
  /// stays a refusal.
  bool _mayUse(String annotation, _ResolvedShorthand target, String selfUri) {
    final root = packageRootOf(file);
    return switch (annotation) {
      '@internal' => switch ((root, target.libraryPath)) {
        (final root?, final path?) => switch (packageRootOf(path)) {
          final other? => _real(other) == _real(root),
          null => false,
        },
        _ => false,
      },
      '@visibleForTesting' =>
        target.libraryUri == selfUri ||
            (root != null &&
                (p.isWithin(p.join(root, 'test'), file) ||
                    p.isWithin(p.join(root, 'integration_test'), file))),
      '@protected' || '@visibleForTemplate' =>
        target.libraryUri == selfUri ||
            (target.restrictions.contains('@visibleForTesting') &&
                _mayUse('@visibleForTesting', target, selfUri)),
      '@visibleForOverriding' => target.libraryUri == selfUri,
      _ => false,
    };
  }

  /// Whether a rebind landed on a `static const` **alias** of the original —
  /// a distinct element declaring the identical canonicalized constant, as
  /// `AlignmentGeometry.topCenter = Alignment.topCenter` does. Const
  /// canonicalization makes the two `identical` at runtime, so the rewrite is
  /// observably a no-op.
  ///
  /// Value identity is deliberately narrower than element identity: it
  /// rescues the alias while still refusing every forwarder that *computes* an
  /// equivalent (`static Geo all(double v) => Box.all(v);` allocates a fresh,
  /// non-const instance — no constant value, no rescue; a redirecting factory
  /// is the one forwarder rescued, by [_ResolvedShorthand.forwardsTo]) and
  /// every same-named sibling
  /// holding a different value (`Base.a` vs `Sub.a`,
  /// `AlignmentDirectional.center` in an `AlignmentGeometry` slot — the
  /// value's type differs).
  ///
  /// Both sides are looked up fresh through the session rather than reusing the
  /// elements the two resolves handed back: a constant only evaluates on an
  /// element whose library is the session's current one, and the two values
  /// must come from one element model for their types to compare equal.
  ///
  /// A constant declared in [selfUri] is read out of the speculative text,
  /// which would make the check circular — the rewrite could be what changed
  /// the value it is judged against. Every other library is untouched by the
  /// overlay, so its constants are pristine; same-library aliases never
  /// rescue.
  Future<bool> _isConstAlias(
    _Candidate candidate,
    _ResolvedShorthand resolved,
    String selfUri,
  ) async {
    if (candidate.libraryUri == selfUri || resolved.libraryUri == selfUri) {
      return false;
    }

    final before = await _constantOf(
      candidate.libraryUri,
      candidate.containerName,
      candidate.memberName,
    );
    if (before == null || !before.hasKnownValue) return false;

    final after = await _constantOf(
      resolved.libraryUri,
      resolved.containerName,
      resolved.memberName,
    );
    return after != null && after.hasKnownValue && before == after;
  }

  /// The compile-time value of `container.member` in library [uri], or null
  /// when any link is missing or the member is not a constant — a static
  /// method (`EdgeInsetsGeometry.all`) or a plain getter has no constant, so
  /// it can never satisfy [_isConstAlias].
  Future<DartObject?> _constantOf(
    String? uri,
    String? container,
    String member,
  ) async {
    if (uri == null || container == null) return null;
    final key = (uri, container, member);
    if (_constCache.containsKey(key)) return _constCache[key];

    final library = await context.currentSession.getLibraryByUri(uri);
    if (library is! LibraryElementResult) return _constCache[key] = null;
    final holder =
        library.element.getClass(container) ??
        library.element.getEnum(container) ??
        library.element.getMixin(container) ??
        library.element.getExtensionType(container);
    return _constCache[key] = holder?.getField(member)?.computeConstantValue();
  }
}

/// Overlay modification stamps, rising across every file of every run: a
/// path overlaid by one file and restored by another never repeats a stamp.
var _stamp = 0;

/// One verified rewrite of a candidate set: the text, its library's resolve
/// and the edited [unit] within it, the candidates node-level evidence
/// convicts, and the first new diagnostic none of them accounts for (see
/// [_FileSanitizer._verdict]), as `an error: …`, `a warning: …` or
/// `an info: …`.
final class _Attempt(
  final _Rewritten rewritten,
  final ResolvedLibraryResult library,
  final ResolvedUnitResult unit,
  final Set<_Candidate> culprits, {
  required final String? stray,
}) {
  bool get isClean => culprits.isEmpty && stray == null;
}

/// A site left prefixed, and why — for [FileResult.kept].
typedef _Kept = ({int offset, String display, String reason});

/// What a skip entry can name a site by; see [Sanitizer._isSkipped].
typedef _SiteName = ({
  String display,
  String memberName,
  String? containerName,
});

/// [start, end) of a text replaced by [length] characters.
typedef _Edit = ({int start, int end, int length});

/// Edit batches, in order, and the lines of the text the first applies to.
typedef _UnitEdits = ({LineInfo before, List<List<_Edit>> batches});

/// The offset in the text before [edits] of [offset] in the text after them;
/// an offset inside a replacement maps to the start of the range it replaced.
int _unapply(List<_Edit> edits, int offset) {
  var delta = 0;
  for (final e in [...edits]..sort((a, b) => a.start.compareTo(b.start))) {
    final start = e.start + delta;
    if (offset < start) break;
    if (offset < start + e.length) return e.start;
    delta += e.length - (e.end - e.start);
  }
  return offset - delta;
}

/// Each file's text as the run first read it, and the edits the run has made
/// to it since: a library processed after its part was already pruned by
/// the part's pass, yet reports lines of the file the user ran it on.
final class _Origins {
  final _input = <String, LineInfo>{};
  final _edits = <String, List<List<_Edit>>>{};
  final _keys = <String, String>{};

  String _key(String path) => _keys[path] ??= _real(path);

  /// Records [batches], applied in order to the text [before] describes.
  void record(String path, LineInfo before, List<List<_Edit>> batches) {
    final key = _key(path);
    _input.putIfAbsent(key, () => before);
    (_edits[key] ??= []).addAll(batches);
  }

  /// Where [offset] of [path]'s current text, whose lines are [current], was
  /// in the text the run first read.
  CharacterLocation locate(String path, LineInfo current, int offset) {
    final key = _key(path);
    final input = _input[key];
    if (input == null) return current.getLocation(offset);
    var o = offset;
    for (final edits in _edits[key]?.reversed ?? const <List<_Edit>>[]) {
      o = _unapply(edits, o);
    }
    return input.getLocation(o);
  }
}

/// Fallback reason for a candidate that only ever failed as part of a set.
const _unverified = 'not verifiable alongside the other rewrites';

List<Site> _keptSites(
  CharacterLocation Function(int offset) locate,
  List<_Kept> kept,
) => [
  for (final k in kept)
    _siteAt(locate, k.offset, k.display, keptReason: k.reason),
];

Site _siteAt(
  CharacterLocation Function(int offset) locate,
  int offset,
  String before, {
  String? after,
  String? keptReason,
}) {
  final location = locate(offset);
  return Site(
    line: location.lineNumber,
    column: location.columnNumber,
    before: before,
    after: after,
    keptReason: keptReason,
  );
}

/// The analyzer's error on the shorthand head `.member` whose `.` sits at
/// [offset] in [check] — why that shorthand failed, in the analyzer's words.
String? _errorOn(ResolvedUnitResult check, int offset, String member) {
  final end = offset + 1 + member.length;
  for (final d in check.diagnostics) {
    if (d.severity == .error &&
        d.offset < end &&
        d.offset + d.length > offset) {
      return _sentence(d.message);
    }
  }
  return null;
}

String _describe(Diagnostic d) =>
    '${switch (d.severity) {
      .error => 'an error',
      .warning => 'a warning',
      .info => 'an info',
    }}: ${_sentence(d.message)}';

/// An analyzer message as a reason clause: the closing period dropped.
String _sentence(String message) =>
    message.endsWith('.') ? message.substring(0, message.length - 1) : message;

final class _Rewritten(
  final String text,

  /// Where each candidate's shorthand `.` landed in [text].
  final Map<_Candidate, int> newOffsets,
);

/// Identity of what a shorthand node resolved to, keyed by node offset.
final class _ResolvedShorthand(
  final String memberName,
  final String? containerName,
  final String? libraryUri, {

  /// Where the element's redirecting-factory chain ends, when it is one and
  /// every hop keeps the formal parameters — null otherwise. Its [signature]
  /// is the terminal's return type over the entry's parameters, i.e. what the
  /// forwarded call constructs and what it accepts.
  final _ResolvedShorthand? redirectTarget,
  final String? signature,

  final String? staticType,
  final String? shownType,
  final Set<String> restrictions = const {},
  final bool useResult = false,
  final String? libraryPath,
}) {
  bool matches(_Candidate c) =>
      memberName == c.memberName &&
      containerName == c.containerName &&
      libraryUri == c.libraryUri;

  /// Whether the element is a redirecting factory that forwards the call,
  /// argument for argument, to [c]'s constructor. Dart forbids default values
  /// on a redirecting factory and passes arguments straight through, so the
  /// only way the rewrite could differ from the original is a parameter type
  /// that changes an argument's context type (`Geo.all(double)` redirecting
  /// to `Box.all(num)` turns `Box.all(1)`'s `int` into a `double`) — the
  /// signature comparison refuses that. Its static type is the factory's
  /// class; `_verdict` accepts that only where `_Candidate.typedSlot` is
  /// exactly that type, so no cascade, assignment or inference observes it.
  bool forwardsTo(_Candidate c) =>
      redirectTarget != null &&
      redirectTarget!.matches(c) &&
      redirectTarget!.signature == c.signature;
}

/// `ReturnType(params)` of a constructor, instantiated as resolved — the
/// identity [_ResolvedShorthand.forwardsTo] compares across a redirect.
String _constructorSignature(ConstructorElement e) =>
    '${_typeKey(e.returnType)}${_parametersOf(e)}';

/// The formal parameter list of [e]: kind and type of each (plus name for
/// named parameters; positional parameter names are ignored because callers
/// cannot reference them), positional in order, named sorted by name —
/// `only({left, right, top, bottom})` and `only({left, top, right, bottom})`
/// accept the same calls.
String _parametersOf(ConstructorElement e) {
  final positional = [
    for (final p in e.formalParameters)
      if (!p.isNamed) 'p:${p.isOptional ? 'o' : 'r'}:${_typeKey(p.type)}',
  ];
  final named = [
    for (final p in e.formalParameters)
      if (p.isNamed)
        'n:${p.name}:${p.isOptional ? 'o' : 'r'}:${_typeKey(p.type)}',
  ]..sort();
  return '(${[...positional, ...named].join(', ')})';
}

/// Type identity across two resolves. `getDisplayString` names a class
/// without its library, so two distinct classes called `X` display alike;
/// this key names every interface by library URI and name, recursively over
/// type arguments, function and record types, with nullability.
String _typeKey(
  DartType type, [
  Map<TypeParameterElement, String> local = const {},
]) {
  final nullable = switch (type.nullabilitySuffix) {
    .question => '?',
    .star => '*',
    .none => '',
  };
  String key(DartType t) => _typeKey(t, local);
  String keys(Iterable<DartType> types) => types.map(key).join(', ');
  String named(RecordTypeNamedField f) => '${key(f.type)} ${f.name}';
  return switch (type) {
    InterfaceType(:final element, :final typeArguments) =>
      '${element.library.uri}::${element.name}'
          '${typeArguments.isEmpty ? '' : '<${keys(typeArguments)}>'}'
          '$nullable',
    TypeParameterType(:final element) => switch (local[element]) {
      final position? => '$position$nullable',
      null =>
        '${element.library?.uri}::${element.enclosingElement?.displayName}'
            '.${element.name}$nullable',
    },
    FunctionType() => '${_functionKey(type, local)}$nullable',
    RecordType(:final positionalFields, :final namedFields) =>
      '(${keys(positionalFields.map((f) => f.type))}; '
          '${namedFields.map(named).join(', ')})$nullable',
    // dynamic, void, Never, invalid: no library to qualify.
    _ => type.getDisplayString(),
  };
}

/// A generic function type's own type parameters have no declaration that
/// identifies them across two resolves, so they are keyed by position,
/// bounds included: `T Function<T>(T)` keys alike wherever it is written.
String _functionKey(FunctionType f, Map<TypeParameterElement, String> outer) {
  final local = {
    ...outer,
    for (final (i, t) in f.typeParameters.indexed) t: '#${outer.length + i}',
  };
  String typeParameter(TypeParameterElement t) => switch (t.bound) {
    final bound? => '${local[t]} extends ${_typeKey(bound, local)}',
    null => '${local[t]}',
  };
  return '${_typeKey(f.returnType, local)} '
      'Function<${f.typeParameters.map(typeParameter).join(', ')}>'
      '(${f.formalParameters.map((p) => _parameterKey(p, local)).join(', ')})';
}

String _parameterKey(
  FormalParameterElement p, [
  Map<TypeParameterElement, String> local = const {},
]) => switch (p) {
  _ when p.isNamed =>
    '{${p.isRequired ? 'required ' : ''}${_typeKey(p.type, local)} ${p.name}}',
  _ when p.isOptionalPositional => '[${_typeKey(p.type, local)}]',
  _ => _typeKey(p.type, local),
};

/// Annotations that restrict where [element] may be used. A licensed rebind
/// onto a member carrying one the original lacks is a new restricted use,
/// which the analyzer does not always report: analyzer 14.4 skips its
/// `@visibleForTesting` check on a dot-shorthand constructor invocation.
Set<String> _restrictionsOf(Element? element) => {
  for (final holder in _holdersOf(element)) ...{
    if (holder.metadata.hasDeprecated) '@Deprecated',
    if (holder.metadata.hasDoNotSubmit) '@doNotSubmit',
    if (holder.metadata.hasExperimental) '@experimental',
    if (holder.metadata.hasInternal) '@internal',
    if (holder.metadata.hasProtected) '@protected',
    if (holder.metadata.hasVisibleForOverriding) '@visibleForOverriding',
    if (holder.metadata.hasVisibleForTemplate) '@visibleForTemplate',
    if (holder.metadata.hasVisibleForTesting) '@visibleForTesting',
    if (holder.metadata.hasVisibleOutsideTemplate) '@visibleOutsideTemplate',
  },
};

/// A field's annotations sit on the field, not on its getter; container-level
/// annotations (e.g. `@internal` or `@visibleForTesting` on the enclosing
/// class/enum/extension type) also restrict its members.
List<Element> _holdersOf(Element? element) => [
  ?element,
  if (element is PropertyAccessorElement) element.variable,
  ?element?.enclosingElement,
];

int _byOffset(_Candidate a, _Candidate b) =>
    a.deleteStart.compareTo(b.deleteStart);

/// Offsets shift across rewrites — a diagnostic is keyed by its unit,
/// severity, code and message instead. `severity` is the code's default:
/// `analyzer: errors:` overrides are not applied, on either side.
typedef _DiagKey = ({
  String path,
  String severity,
  String code,
  String message,
});

_DiagKey _keyOf(String path, Diagnostic d) => (
  path: path,
  severity: d.severity.name,
  code: d.diagnosticCode.lowerCaseName,
  message: d.message,
);

Map<_DiagKey, int> _census(ResolvedLibraryResult lib) {
  final counts = <_DiagKey, int>{};
  for (final unit in lib.units) {
    for (final d in unit.diagnostics) {
      counts.update(_keyOf(unit.path, d), (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return counts;
}

List<Diagnostic> _byPosition(List<Diagnostic> diagnostics) =>
    [...diagnostics]..sort((a, b) => a.offset.compareTo(b.offset));

/// Import-scoped diagnostics whose fix is to drop the whole directive.
const _removableImportCodes = {
  'unused_import',
  'unnecessary_import',
  'duplicate_import',
};

bool _isRemovableImport(Diagnostic d) =>
    _removableImportCodes.contains(d.diagnosticCode.lowerCaseName);

/// A removable-import diagnostic by unit path, directive index and code.
/// A rewrite deletes no directive, so the index survives it, and it tells
/// two imports of one URI apart where their messages are identical.
typedef _ImportIssue = (String path, int directive, String code);

Set<_ImportIssue> _importIssuesOf(ResolvedLibraryResult lib) => {
  for (final unit in lib.units)
    for (final d in unit.diagnostics)
      if (_isRemovableImport(d))
        if (_importAt(unit, d.offset) case final index?)
          (unit.path, index, d.diagnosticCode.lowerCaseName),
};

int? _importAt(ResolvedUnitResult unit, int offset) {
  final directives = unit.unit.directives;
  for (var i = 0; i < directives.length; i++) {
    final directive = directives[i];
    if (directive is ImportDirective &&
        offset >= directive.offset &&
        offset < directive.end) {
      return i;
    }
  }
  return null;
}

typedef _DirectiveCut = ({
  int start,
  int end,
  String replacement,
  int keyword,

  /// The report, given the keyword's line in the text the run first read.
  PrunedImport Function(int line) info,
});

_Edit _editOf(_DirectiveCut cut) =>
    (start: cut.start, end: cut.end, length: cut.replacement.length);

/// Directive edits for imports the rewrite orphaned — a removable-import
/// diagnostic of [check] not among [userIssues] — keyed by unit path.
/// Coordinates are each unit's content in [check]: the rewritten text for the
/// edited unit, the untouched text for every other.
///
/// When the first directive of the file is pruned and carries a doc comment or
/// metadata annotation, the header is preserved by starting the cut at
/// `firstTokenAfterCommentAndMetadata.offset` — and when no directive remains
/// in the unit after pruning, the directive is replaced with `library;` so the
/// header stays attached to the library rather than moving onto the first
/// declaration. Trailing `// ignore_for_file:` comments are preserved on their
/// own line.
Map<String, List<_DirectiveCut>> _orphanRanges(
  ResolvedLibraryResult check,
  Set<_ImportIssue> userIssues,
) {
  final cuts = <String, List<_DirectiveCut>>{};
  for (final unit in check.units) {
    final text = unit.content;
    final cut = <int>{};
    for (final d in unit.diagnostics) {
      if (!_isRemovableImport(d)) continue;
      final index = _importAt(unit, d.offset);
      if (index != null &&
          !userIssues.contains((
            unit.path,
            index,
            d.diagnosticCode.lowerCaseName,
          ))) {
        cut.add(index);
      }
    }
    if (cut.isEmpty) continue;
    final allPruned = cut.length == unit.unit.directives.length;
    for (final index in cut) {
      final directive = unit.unit.directives[index];
      final keyword = directive.firstTokenAfterCommentAndMetadata.offset;
      final hasHeader =
          index == 0 &&
          (directive.documentationComment != null ||
              directive.metadata.isNotEmpty);
      final needsLibrary = hasHeader && allPruned;
      final start = hasHeader ? keyword : directive.offset;
      var commentStart = directive.end;
      while (commentStart < text.length &&
          (text.codeUnitAt(commentStart) == 0x20 ||
              text.codeUnitAt(commentStart) == 0x09)) {
        commentStart++;
      }
      var commentEnd = commentStart;
      if (commentStart + 1 < text.length &&
          text.codeUnitAt(commentStart) == 0x2F &&
          text.codeUnitAt(commentStart + 1) == 0x2F) {
        commentEnd = commentStart + 2;
        while (commentEnd < text.length &&
            text.codeUnitAt(commentEnd) != 0x0D &&
            text.codeUnitAt(commentEnd) != 0x0A) {
          commentEnd++;
        }
      }
      final comment = commentEnd > commentStart
          ? text.substring(commentStart, commentEnd).trimRight()
          : null;
      final hasIgnoreForFile =
          comment?.substring(2).contains('ignore_for_file:') ?? false;
      PrunedImport Function(int) info({String? replacement}) =>
          (line) => PrunedImport(
            line: line,
            uri: switch (directive) {
              ImportDirective(:final uri) => uri.stringValue ?? uri.toSource(),
              _ => directive.toSource(),
            },
            replacement: replacement,
            deletedComment: hasIgnoreForFile ? null : comment,
            keptComment: hasIgnoreForFile ? comment : null,
          );
      if (needsLibrary) {
        final end = hasIgnoreForFile ? directive.end : commentEnd;
        (cuts[unit.path] ??= []).add((
          start: start,
          end: end,
          replacement: 'library;',
          keyword: keyword,
          info: info(replacement: 'library;'),
        ));
        continue;
      }
      if (hasIgnoreForFile) {
        (cuts[unit.path] ??= []).add((
          start: start,
          end: commentStart,
          replacement: '',
          keyword: keyword,
          info: info(),
        ));
        continue;
      }
      var end = commentEnd;
      if (end < text.length && text.codeUnitAt(end) == 0x0D) end++;
      if (end < text.length && text.codeUnitAt(end) == 0x0A) end++;
      if (hasHeader && end < text.length) {
        if (text.codeUnitAt(end) == 0x0D) end++;
        if (end < text.length && text.codeUnitAt(end) == 0x0A) end++;
      }
      (cuts[unit.path] ??= []).add((
        start: start,
        end: end,
        replacement: '',
        keyword: keyword,
        info: info(),
      ));
    }
  }
  return cuts;
}

/// Applies [ranges] to [text] in order.
String _stripRanges(String text, List<_DirectiveCut> ranges) {
  final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
  final buffer = StringBuffer();
  var cursor = 0;
  for (final (:start, :end, :replacement, keyword: _, info: _) in sorted) {
    buffer
      ..write(text.substring(cursor, start))
      ..write(replacement);
    cursor = end;
  }
  buffer.write(text.substring(cursor));
  return buffer.toString();
}

final class _ShorthandIndex extends RecursiveAstVisitor<void> {
  final byOffset = <int, _ResolvedShorthand>{};

  void _add(int offset, String memberName, Element? element, DartType? type) {
    byOffset[offset] = _ResolvedShorthand(
      memberName,
      element?.enclosingElement?.displayName,
      element?.library?.uri.toString(),
      redirectTarget: element is ConstructorElement
          ? _redirectTargetOf(element)
          : null,
      staticType: type == null ? null : _typeKey(type),
      shownType: type?.getDisplayString(),
      restrictions: _restrictionsOf(element),
      useResult: _holdersOf(element).any((e) => e.metadata.hasUseResult),
      libraryPath: element?.library?.firstFragment.source.fullName,
    );
  }

  /// Follows `factory A.x(...) = B.y;` hops to the first constructor that is
  /// not a redirecting factory, or null when [entry] is not one, a hop changes
  /// the formal parameters, or the chain loops. A generative constructor
  /// redirecting with `: this.y(...)` also reports a `redirectedConstructor`,
  /// but it may rewrite the arguments — the factory test stops there.
  static _ResolvedShorthand? _redirectTargetOf(ConstructorElement entry) {
    final params = _parametersOf(entry);
    final seen = <ConstructorElement>{};
    var cur = entry;
    while (cur.isFactory && cur.redirectedConstructor != null) {
      if (!seen.add(cur.baseElement)) return null;
      cur = cur.redirectedConstructor!;
      if (_parametersOf(cur) != params) return null;
    }
    if (identical(cur, entry)) return null;
    return _ResolvedShorthand(
      cur.name ?? '',
      cur.enclosingElement.displayName,
      cur.library.uri.toString(),
      signature: '${_typeKey(cur.returnType)}$params',
    );
  }

  @override
  void visitDotShorthandPropertyAccess(DotShorthandPropertyAccess node) {
    _add(
      node.period.offset,
      node.propertyName.name,
      node.propertyName.element,
      node.staticType,
    );
    super.visitDotShorthandPropertyAccess(node);
  }

  @override
  void visitDotShorthandInvocation(DotShorthandInvocation node) {
    _add(
      node.period.offset,
      node.memberName.name,
      node.memberName.element,
      node.staticType,
    );
    super.visitDotShorthandInvocation(node);
  }

  @override
  void visitDotShorthandConstructorInvocation(
    DotShorthandConstructorInvocation node,
  ) {
    _add(
      node.period.offset,
      node.constructorName.name,
      node.constructorName.element,
      node.staticType,
    );
    super.visitDotShorthandConstructorInvocation(node);
  }
}

final class _CandidateCollector(TypeProvider typeProvider)
    extends RecursiveAstVisitor<void> {
  final _viability = _Viability(typeProvider);
  final candidates = <_Candidate>[];

  /// Sites [_Viability] ruled out — they stay prefixed without a resolve.
  final unviable = <_Kept>[];

  /// Every `Type.member` site seen, viable or not — what skip entries match.
  final sites = <_SiteName>[];

  /// `[Type.member]` in a doc comment is prose, not a site.
  @override
  void visitComment(Comment node) {}

  /// [dotOffset] doubles as the exclusive end of the deleted prefix — the
  /// prefix ends exactly where its `.` begins.
  void _add({
    required Expression node,
    required int deleteStart,
    required int dotOffset,
    required String owner,
    required String memberName,
    required Element? memberElement,
  }) {
    final display = '$owner.$memberName';
    sites.add((
      display: display,
      memberName: memberName,
      containerName: memberElement?.enclosingElement?.displayName,
    ));
    final typedSlot = _viability.typedSlotOf(node);
    if (_viability.whyNot(
          node,
          memberName,
          memberElement: memberElement,
          typedSlot: typedSlot,
        )
        case final reason?) {
      unviable.add((offset: deleteStart, display: display, reason: reason));
      return;
    }
    candidates.add(
      _Candidate(
        groupKey: _groupKeyOf(node),
        deleteStart: deleteStart,
        deleteEnd: dotOffset,
        shorthandOffset: dotOffset,
        display: display,
        owner: owner,
        memberName: memberName,
        containerName: memberElement?.enclosingElement?.displayName,
        libraryUri: memberElement?.library?.uri.toString(),
        signature: memberElement is ConstructorElement
            ? _constructorSignature(memberElement)
            : null,
        staticType: switch (node.staticType) {
          final type? => _typeKey(type),
          null => null,
        },
        shownType: node.staticType?.getDisplayString(),
        typedSlot: typedSlot,
        restrictions: _restrictionsOf(memberElement),
      ),
    );
  }

  static int _groupKeyOf(AstNode node) {
    for (AstNode? cur = node; cur != null; cur = cur.parent) {
      if (cur is Statement || cur is Declaration) return cur.offset;
    }
    return -1;
  }

  /// `Enum.value`, `Type.staticGetterOrField`.
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // `@Type.member` is an annotation header, where dot-shorthand is a syntax
    // error (`@.member` does not parse).
    if (node.parent is Annotation) return;
    final member = node.identifier.element;
    if (_isTypeRef(node.prefix) &&
        _isStaticMember(member) &&
        !_isReceiverPosition(node)) {
      _add(
        node: node,
        deleteStart: node.prefix.offset,
        dotOffset: node.period.offset,
        owner: node.prefix.name,
        memberName: node.identifier.name,
        memberElement: member,
      );
    }
    super.visitPrefixedIdentifier(node);
  }

  /// `prefix.Type.staticGetterOrField`.
  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    final member = node.propertyName.element;
    if (target != null &&
        _isTypeRef(target) &&
        _isStaticMember(member) &&
        !_isReceiverPosition(node)) {
      _add(
        node: node,
        deleteStart: target.offset,
        dotOffset: node.operator.offset,
        owner: target.toSource(),
        memberName: node.propertyName.name,
        memberElement: member,
      );
    }
    super.visitPropertyAccess(node);
  }

  /// `Type.staticMethod(...)` or `prefix.Type.staticMethod(...)`.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final dot = node.operator;
    if (target != null &&
        dot != null &&
        node.typeArguments == null &&
        _isTypeRef(target) &&
        _isStaticMember(node.methodName.element)) {
      _add(
        node: node,
        deleteStart: target.offset,
        dotOffset: dot.offset,
        owner: target.toSource(),
        memberName: node.methodName.name,
        memberElement: node.methodName.element,
      );
    }
    super.visitMethodInvocation(node);
  }

  /// `Type.named(...)` — incl. factory and const constructors. Unnamed
  /// constructors stay: `.new(...)` saves nothing over `Type(...)`.
  /// `new Type.named(...)` also stays: `new .named(...)` is a syntax error.
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final name = node.constructorName.name;
    final period = node.constructorName.period;
    final type = node.constructorName.type;
    if (name != null &&
        period != null &&
        node.keyword?.keyword != .NEW &&
        type.typeArguments == null) {
      _add(
        node: node,
        deleteStart: node.constructorName.offset,
        dotOffset: period.offset,
        owner: type.qualifiedName,
        memberName: name.name,
        memberElement: node.constructorName.element,
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  /// Whether [target] names a type — directly or through a type alias — so
  /// its prefix is a namespace the shorthand can drop rather than a value.
  static bool _isTypeRef(Expression target) {
    if (target is! Identifier) return false;
    final element = target.element;
    if (element is InterfaceElement) return true;
    return element is TypeAliasElement && element.aliasedType is InterfaceType;
  }

  static bool _isStaticMember(Element? element) {
    if (element is PropertyAccessorElement &&
        element.name == 'values' &&
        element.enclosingElement is EnumElement) {
      return false;
    }
    return switch (element) {
      ExecutableElement(:final isStatic) => isStatic,
      FieldElement(:final isStatic) => isStatic,
      _ => false,
    };
  }

  /// `Foo.bar.baz` / `Foo.bar()` — the node is itself a receiver. `.bar.baz`
  /// would resolve `.bar` against the chain's context type (see
  /// [_Viability]), which is `baz`'s type, not `Foo`, in all but contrived
  /// code; kept out wholesale rather than probed.
  static bool _isReceiverPosition(Expression node) {
    final parent = node.parent;
    return (parent is PropertyAccess && identical(parent.target, node)) ||
        (parent is MethodInvocation && identical(parent.target, node));
  }
}

/// Static pre-check that a `Type.member` site can possibly verify, so that
/// sites which cannot are never handed to the resolve loop — on a Flutter
/// codebase they are the bulk of the candidates (`Theme.of(context).x`,
/// `Colors.red`, `final size = MediaQuery.sizeOf(context)`), and each one
/// costs a speculative resolve per recovery wave before being reverted.
///
/// A shorthand `.member` resolves against the context type of the whole
/// postfix selector chain it heads — `.of(context).colorScheme` looks `of` up
/// on `ColorScheme`, `.tryParse(s)!` on `int` — and the rewrite is a no-op
/// only if that type declares a static `member` the verdict accepts (the
/// original, a const alias, a redirecting factory). So:
///
/// - where the syntax pins the context type down (an argument's parameter,
///   a declared variable type, the enclosing function's return type, an
///   assignment target, a collection literal's element type), that type must
///   declare `member`;
/// - where the position provably has no context type (an expression
///   statement, `var x = …`, an `as`/`is` operand, an interpolation, a
///   binary left operand, a parenthesized or conditional receiver of a method
///   call) or one that can't declare it (`throw` resolves against `Object`),
///   the site never converts;
/// - otherwise the chain's own static type must be assignable to the context
///   type, so one of its supertypes must declare `member`.
///
/// Every rule is a necessary condition only — a site that passes is still
/// verified by the resolve, a site that fails would have been reverted after
/// costing one. Type parameters, `dynamic` and an unresolved parameter are
/// "can't tell" and pass.
final class _Viability(final TypeProvider typeProvider) {
  /// Why [site] can never verify, or null when it might.
  String? whyNot(
    Expression site,
    String member, {
    Element? memberElement,
    String? typedSlot,
  }) {
    AstNode head = site;
    // Selector chains (`PropertyAccess`, `MethodInvocation`, `IndexExpression`,
    // `CascadeExpression`, `PostfixExpression`) only propagate their context
    // type to a direct selector target — never through parentheses or a
    // conditional expression (`(Box.all(5)).let(...)` has no context type).
    while (_isSelectorFor(head.parent, head)) {
      head = head.parent!;
    }
    while (_passesContextTo(head.parent, head)) {
      head = head.parent!;
    }
    final context = _contextOf(head);
    if (context != null) {
      return _refusal(
        context,
        member,
        memberElement: memberElement,
        typedSlot: typedSlot,
      );
    }
    final type = head is Expression ? head.staticType : null;
    if (type is! InterfaceType ||
        type.element.getStatic(member) != null ||
        type.element.allSupertypes.any(
          (t) => t.element.getStatic(member) != null,
        )) {
      return null;
    }
    return 'neither ${type.getDisplayString()} nor a supertype declares '
        'static $member';
  }

  /// The `_typeKey` of [site]'s slot when a licensed rebind may land there: an
  /// argument, a typed declaration, a field initializer, a return or yield, a
  /// collection element, an index or binary operator operand, a compound
  /// assignment RHS, or a parameter default whose context type is an interface
  /// type, reached only through wrappers that pass the value on unobserved
  /// ([_isTransparent]).
  /// Keyed without one trailing `?`: a nullable slot types the shorthand
  /// as its non-null class. Null elsewhere — a cascade target, a simple
  /// assignment or an inferred declaration observes the shorthand's own static
  /// type.
  String? typedSlotOf(Expression site) {
    AstNode head = site;
    for (
      var parent = head.parent;
      parent != null && _isTransparent(parent, head);
      parent = head.parent
    ) {
      head = parent;
    }
    final parent = head.parent;
    final inSlot = switch (parent) {
      ArgumentList() => !_isUnpinnedGenericArgument(head as Argument),
      VariableDeclaration() ||
      ConstructorFieldInitializer() ||
      ReturnStatement() ||
      YieldStatement() ||
      ExpressionFunctionBody() ||
      ListLiteral() ||
      SetOrMapLiteral() ||
      MapLiteralEntry() ||
      FormalParameterDefaultClause() => true,
      IndexExpression(:final index) => identical(index, head),
      BinaryExpression(:final operator, :final rightOperand) =>
        identical(rightOperand, head) &&
            operator.type != .EQ_EQ &&
            operator.type != .BANG_EQ &&
            operator.type != .QUESTION_QUESTION &&
            operator.type != .AMPERSAND_AMPERSAND &&
            operator.type != .BAR_BAR,
      AssignmentExpression(:final operator, :final rightHandSide) =>
        identical(rightHandSide, head) &&
            operator.type != .EQ &&
            operator.type != .QUESTION_QUESTION_EQ,
      _ => false,
    };
    if (inSlot) {
      if (_contextOf(head) case final DartType rawSlot) {
        var slot = rawSlot;
        while (slot is InterfaceType && slot.isDartAsyncFutureOr) {
          slot = slot.typeArguments.first;
        }
        if (slot is InterfaceType) {
          final key = _typeKey(slot);
          return key.endsWith('?') ? key.substring(0, key.length - 1) : key;
        }
      }
    }
    return null;
  }

  /// Whether [parent] passes [child]'s value through to its own slot
  /// unobserved. A switch scrutinee is observed by its patterns.
  static bool _isTransparent(AstNode parent, AstNode child) => switch (parent) {
    ParenthesizedExpression() ||
    NamedArgument() ||
    ForElement() ||
    NullAwareElement() => true,
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      identical(thenExpression, child) || identical(elseExpression, child),
    BinaryExpression(:final operator, :final rightOperand) =>
      operator.type == .QUESTION_QUESTION && identical(rightOperand, child),
    SwitchExpressionCase(:final expression) => identical(expression, child),
    SwitchExpression(:final expression) => !identical(expression, child),
    IfElement(:final thenElement, :final elseElement) =>
      identical(thenElement, child) || identical(elseElement, child),
    _ => false,
  };

  /// Whether [parent] is a selector expression whose direct target is [child].
  static bool _isSelectorFor(AstNode? parent, AstNode child) =>
      switch (parent) {
        PropertyAccess(:final target) => identical(target, child),
        MethodInvocation(:final target) => identical(target, child),
        IndexExpression(:final target) => identical(target, child),
        CascadeExpression(:final target) => identical(target, child),
        PostfixExpression(:final operand) => identical(operand, child),
        _ => false,
      };

  /// Whether [parent] hands its own context type down to [child] as a
  /// value-level syntactic wrapper.
  static bool _passesContextTo(AstNode? parent, AstNode child) =>
      switch (parent) {
        ParenthesizedExpression() ||
        AwaitExpression() ||
        NamedArgument() ||
        ForElement() ||
        NullAwareElement() => true,
        SwitchExpression(:final expression) => !identical(expression, child),
        ConditionalExpression(:final thenExpression, :final elseExpression) =>
          identical(thenExpression, child) || identical(elseExpression, child),
        BinaryExpression(:final operator, :final rightOperand) =>
          operator.type == .QUESTION_QUESTION && identical(rightOperand, child),
        SwitchExpressionCase(:final expression) => identical(expression, child),
        IfElement(:final thenElement, :final elseElement) =>
          identical(thenElement, child) || identical(elseElement, child),
        _ => false,
      };

  /// The context type at [head], null when the syntax doesn't tell. Positions
  /// with no context type at all report `Never`: it declares nothing, and no
  /// site with a real `Never` context could convert either.
  DartType? _contextOf(AstNode head) {
    final none = typeProvider.neverType;
    final bool = typeProvider.boolType;
    final parent = head.parent;
    if (parent == null) return null;
    if (_isSelectorFor(parent, head)) return none;
    switch (parent) {
      case ExpressionStatement() ||
          AsExpression() ||
          IsExpression() ||
          InterpolationExpression():
        return none;
      case SwitchExpression(:final expression) ||
              SwitchStatement(:final expression)
          when identical(expression, head):
        return none;
      case VariableDeclaration():
        return (parent.parent! as VariableDeclarationList).type?.type ?? none;
      case ConstructorFieldInitializer(:final fieldName):
        final element = fieldName.element;
        return switch (element) {
          FieldElement(:final type) => type,
          PropertyAccessorElement(:final variable) => variable.type,
          _ => null,
        };
      case ThrowExpression():
        return typeProvider.objectType;
      case PrefixExpression(:final operator):
        return operator.type == .BANG ? bool : none;
      case IndexExpression(:final index) when identical(index, head):
        final method =
            parent.element ??
            switch (parent.parent) {
              AssignmentExpression(:final leftHandSide, :final writeElement)
                  when identical(leftHandSide, parent) =>
                writeElement,
              PostfixExpression(:final operand, :final writeElement)
                  when identical(operand, parent) =>
                writeElement,
              PrefixExpression(:final operand, :final writeElement)
                  when identical(operand, parent) =>
                writeElement,
              _ => null,
            };
        final type = method is ExecutableElement
            ? method.formalParameters.firstOrNull?.type
            : null;
        return type is TypeParameterType ? null : type;
      case BinaryExpression(:final operator, :final leftOperand):
        if (operator.type == .AMPERSAND_AMPERSAND ||
            operator.type == .BAR_BAR) {
          return bool;
        }
        if (identical(leftOperand, head)) return none;
        if (operator.type == .EQ_EQ || operator.type == .BANG_EQ) {
          return leftOperand.staticType;
        }
        final type = parent.element?.formalParameters.firstOrNull?.type;
        return type is TypeParameterType ? null : type;
      case IfStatement(:final expression) ||
              IfElement(:final expression) ||
              WhileStatement(condition: final expression) ||
              DoStatement(condition: final expression) ||
              AssertStatement(condition: final expression)
          when identical(expression, head):
        return bool;
      case ArgumentList():
        return _argumentContext(head as Argument);
      case AssignmentExpression(:final operator, :final rightHandSide)
          when identical(rightHandSide, head):
        if (operator.type == .EQ || operator.type == .QUESTION_QUESTION_EQ) {
          return parent.writeType;
        }
        final type = parent.element?.formalParameters.firstOrNull?.type;
        return type is TypeParameterType ? null : type;
      case FormalParameterDefaultClause(parent: final FormalParameter param):
        return param.declaredFragment?.element.type;
      case ReturnStatement() || ExpressionFunctionBody():
        return _returnContext(parent.thisOrAncestorOfType<FunctionBody>()!);
      case YieldStatement():
        return _yieldContext(
          parent,
          parent.thisOrAncestorOfType<FunctionBody>()!,
        );
      case ListLiteral(:final staticType) || SetOrMapLiteral(:final staticType):
        return _elementType(staticType, 0);
      case MapLiteralEntry(:final key):
        final literal = parent.thisOrAncestorOfType<SetOrMapLiteral>();
        return _elementType(literal?.staticType, identical(key, head) ? 0 : 1);
      default:
        return null;
    }
  }

  bool _isUnpinnedGenericArgument(Argument arg) {
    final param = arg.correspondingParameter;
    if (param == null) return false;
    final call = arg.parent?.parent;
    final hasExplicitTypeArgs = switch (call) {
      MethodInvocation(:final typeArguments) ||
      FunctionExpressionInvocation(
        :final typeArguments,
      ) => typeArguments != null,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.type.typeArguments != null,
      _ => true,
    };
    if (hasExplicitTypeArgs) return false;
    return switch (param.baseElement.type) {
      TypeParameterType(:final element)
          when element.enclosingElement is! InstanceElement ||
              call is InstanceCreationExpression =>
        call is! Expression || typedSlotOf(call) == null,
      _ => false,
    };
  }

  DartType? _argumentContext(Argument arg) {
    final param = arg.correspondingParameter;
    if (param == null) return null;
    if (_isUnpinnedGenericArgument(arg)) {
      if (param.baseElement.type case TypeParameterType(:final element)) {
        var callHead = arg.parent!.parent!;
        while (_isSelectorFor(callHead.parent, callHead)) {
          callHead = callHead.parent!;
        }
        while (_passesContextTo(callHead.parent, callHead)) {
          callHead = callHead.parent!;
        }
        if (_contextOf(callHead) == typeProvider.neverType) {
          return element.bound ?? typeProvider.neverType;
        }
        return null;
      }
    }
    final type = param.type;
    return type is TypeParameterType ? null : type;
  }

  /// The context type of a `return` (or `=>` body) in [body]: its function's
  /// declared or inferred return type, unwrapped once for an `async` body.
  static DartType? _returnContext(FunctionBody body) {
    if (body.isGenerator) return null;
    final owner = body.parent;
    final type = switch (owner) {
      FunctionExpression() => owner.declaredFragment?.element.returnType,
      MethodDeclaration() => owner.declaredFragment?.element.returnType,
      _ => null,
    };
    if (body.isAsynchronous &&
        type is InterfaceType &&
        type.isDartAsyncFuture) {
      return type.typeArguments.first;
    }
    return type;
  }

  /// The context type of a `yield` (or `yield*`) in [body]: for plain `yield`,
  /// the element type `T` of the enclosing generator's `Iterable<T>` or
  /// `Stream<T>` return type; for `yield*`, the return type itself.
  static DartType? _yieldContext(YieldStatement node, FunctionBody body) {
    if (!body.isGenerator) return null;
    final owner = body.parent;
    final type = switch (owner) {
      FunctionExpression() => owner.declaredFragment?.element.returnType,
      MethodDeclaration() => owner.declaredFragment?.element.returnType,
      _ => null,
    };
    if (node.star != null) return type;
    if (type is InterfaceType &&
        (type.isDartCoreIterable || type.isDartAsyncStream) &&
        type.typeArguments.isNotEmpty) {
      return type.typeArguments.first;
    }
    return null;
  }

  static DartType? _elementType(DartType? literal, int index) =>
      literal is InterfaceType && literal.typeArguments.length > index
      ? literal.typeArguments[index]
      : null;

  /// Why a context type [type] cannot hold a static [member] the verdict
  /// would accept, or null when it could. `FutureOr<T>` resolves the
  /// shorthand on `T`; `Never` is [_contextOf]'s "no context type".
  static String? _refusal(
    DartType type,
    String member, {
    Element? memberElement,
    String? typedSlot,
  }) {
    var t = type;
    while (t is InterfaceType && t.isDartAsyncFutureOr) {
      t = t.typeArguments.first;
    }
    if (t case InterfaceType(:final element)
        when element.getStatic(member) != null) {
      if (typedSlot == null) {
        final origContainer = memberElement?.enclosingElement;
        if (origContainer is InterfaceElement &&
            origContainer.baseElement != element.baseElement) {
          return 'rebinds to ${element.name}.$member outside a typed slot';
        }
      }
      return null;
    }
    return switch (t) {
      TypeParameterType() || DynamicType() || InvalidType() => null,
      NeverType() => 'no context type',
      // An interface lacking it; void, function and record types declare
      // nothing.
      _ => 'context type ${t.getDisplayString()} declares no static $member',
    };
  }
}

extension on InterfaceElement {
  /// A static member or named constructor called [name], if declared here.
  Element? getStatic(String name) {
    final method = getMethod(name);
    if (method != null && method.isStatic) return method;
    final getter = getGetter(name);
    if (getter != null && getter.isStatic) return getter;
    return getNamedConstructor(name);
  }
}

extension on NamedType {
  String get qualifiedName => importPrefix == null
      ? name.lexeme
      : '${importPrefix!.name.lexeme}.${name.lexeme}';
}
