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

/// Locates the Dart SDK for the analyzer, or null when none is found. Inside
/// a JIT run the executable lives in the SDK; an AOT-compiled binary does
/// not, so fall back to `DART_SDK`, then to the `dart` on PATH (`which`, or
/// `where` on Windows; following the Flutter shim, whose SDK sits under
/// `bin/cache/dart-sdk`). `package:cli_util`'s `sdkPath` is
/// the resolvedExecutable step alone — no validity check, no AOT or shim
/// fallback — so it cannot replace this.
String? sdkPath() {
  if (_cachedSdkPath != null) return _cachedSdkPath;

  bool isSdk(String dir) =>
      File(p.join(dir, 'version')).existsSync() &&
      Directory(p.join(dir, 'lib', '_internal')).existsSync();

  final env = Platform.environment['DART_SDK'];
  if (env != null && isSdk(env)) return _cachedSdkPath = env;

  final exeSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  if (isSdk(exeSdk)) return _cachedSdkPath = exeSdk;

  final which = _dartOnPath();
  if (which == null) return null;
  final bin = p.dirname(File(which).resolveSymbolicLinksSync());
  for (final candidate in [p.join(bin, 'cache', 'dart-sdk'), p.dirname(bin)]) {
    if (isSdk(candidate)) return _cachedSdkPath = candidate;
  }
  return null;
}

/// `where` lists every match, with CRLF line endings.
String? _dartOnPath() {
  final ProcessResult lookup;
  try {
    lookup = Process.runSync(Platform.isWindows ? 'where' : 'which', ['dart']);
  } on ProcessException {
    return null;
  }
  for (final line in LineSplitter.split(lookup.stdout.toString())) {
    if (line.trim() case final path when path.isNotEmpty) return path;
  }
  return null;
}

/// One `Type.member` occurrence that may convert to `.member`.
final class Candidate({
  /// Start of the `Type` prefix to delete.
  required final int deleteStart,

  /// End (exclusive) of the deleted prefix — the char before the `.`.
  required final int deleteEnd,

  /// Offset of the `.` — where the shorthand node begins after the rewrite.
  required final int shorthandOffset,

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
  /// 1-based line of the `Type` prefix.
  required final int line,

  /// 1-based column of the `Type` prefix.
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

/// Per-file outcome of a sanitize run.
final class FileResult(
  /// Canonical path of the rewritten file.
  final String path,
  List<Site> sites,

  /// Candidates that failed verification and were left prefixed.
  final int reverted, {

  /// Imports pruned from this file because a conversion — here or in another
  /// unit of its library — orphaned them (see [Sanitizer]).
  final int removedImports = 0,
}) {
  /// Creates a result for [path]; [sites] are kept sorted by line, then
  /// column.
  this;

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

  /// Files left unchanged because a file their conversion had to write could
  /// not be written: `path` is that file (`file` itself, or a unit of its
  /// library losing an orphaned import), `error` the OS's reason. Nothing of
  /// that library is written.
  final List<({String file, String path, String error})> writeFailures = [];

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
/// every site where the rewrite provably resolves to the SAME element.
///
/// Strategy per file: resolve once, rewrite every syntactic candidate, resolve
/// the rewritten text once, then keep only candidates whose shorthand node
/// resolved back to the original element with no new diagnostics. Anything
/// else — unwitnessed context (`Object`, generics), members living on a
/// sibling namespace (`Colors.red` in a `Color` slot, `Curves.easeIn` in a
/// `Curve` slot), silent rebinds to a same-named static — is reverted.
///
/// Two rebinds are licensed, both observably no-ops:
/// - a `static const` alias of the original
///   (`AlignmentGeometry.topCenter = Alignment.topCenter`) — a different
///   element holding the identical canonicalized constant. Const-value
///   identity, not element identity, decides — see `_isConstAlias`.
/// - a redirecting factory whose chain ends at the original constructor with
///   the same formal parameters (`const factory EdgeInsetsGeometry.all(double
///   value) = EdgeInsets.all`) — the language forwards the arguments
///   untouched, so `.all(8)` in an `EdgeInsetsGeometry` slot constructs the
///   very `EdgeInsets` the prefix did. See `_ResolvedShorthand.forwardsTo`.
///
/// Dropping a `Type` prefix can orphan the import that supplied it. The
/// verified resolve is the oracle: an `unused_import`/`unnecessary_import` it
/// reports that the original did not is self-inflicted, so its directive is
/// pruned. Imports the file already left unused are the user's — they stay.
final class Sanitizer({
  /// `Type.member` or bare `member` names that must stay prefixed.
  final Set<String> skips = const {},

  /// Glob patterns of files to leave alone. Each glob is matched against
  /// both the CWD-relative path (`/` separators) and the basename
  /// (`firebase_options.dart`, `**/legacy/**`).
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
}) {
  /// Creates a sanitizer; see [run].
  this;

  /// Language version that introduced dot shorthands.
  static const _floorMajor = 3;
  static const _floorMinor = 10;

  static final _generatedMarker = RegExp(
    r'\b(auto[-\s]?generated|generated\s+(code|file|by))\b',
    caseSensitive: false,
  );

  /// Generated-code filter: the file's leading comment says so (build_runner,
  /// FlutterFire, pigeon, protoc, slang). Filename shape (`*.g.dart` vs a
  /// handwritten `*.preview.dart`) proves nothing, the header does.
  ///
  /// Scanning stops at the first line that is neither blank nor a comment
  /// (`//`, `#`, or a `/* … */` block): a generator writes its marker in the
  /// banner, so a comment sitting below the first declaration is ordinary
  /// prose no matter what it says. A leading BOM is skipped, and a banner of
  /// any length is read whole. The marker matches `generated`/`auto-generated`,
  /// never the bare stem — that would flag a handwritten header merely noting
  /// that something *regenerates* and silently skip the whole file.
  static bool isGenerated(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final raw = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    var inBlock = false;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final opens = !inBlock && trimmed.startsWith('/*');
      if (!inBlock &&
          !opens &&
          trimmed.isNotEmpty &&
          !trimmed.startsWith('//') &&
          !trimmed.startsWith('#')) {
        return false;
      }
      if (_generatedMarker.hasMatch(trimmed)) return true;
      if (opens) {
        inBlock = !trimmed.substring(2).contains('*/');
      } else if (inBlock) {
        inBlock = !trimmed.contains('*/');
      }
    }
    return false;
  }

  /// Sanitizes every non-generated `.dart` file under [paths]
  /// (files or directories).
  Future<SanitizeResult> run(List<String> paths) async {
    final globs = [for (final e in excludes) Glob(e)];
    bool isExcluded(String path) {
      final relative = p.relative(path).replaceAll(p.separator, '/');
      return globs.any(
        (g) => g.matches(relative) || g.matches(p.basename(path)),
      );
    }

    final files = _collectFiles(paths, isExcluded);
    final result = SanitizeResult();
    if (files.isEmpty) return result;

    // Pruning may edit another unit of a file's library: only one this run
    // would have processed itself.
    final scope = files.toSet();
    String? offLimits(String path) => switch (path) {
      _ when scope.contains(path) => null,
      _ when isExcluded(path) => 'excluded',
      _ when skipGenerated && isGenerated(path) => 'generated',
      _ => 'not among the given paths',
    };

    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    // Roots, not files: the locator spends ~2ms per included path, a second
    // per 500 files. An `analyzer: exclude:` in the package's options then
    // hides those files from `contextFor`, so contexts are picked by root
    // below — every collected file is analyzed, as before.
    final roots = paths.map(_canonical).toSet();
    final collection = AnalysisContextCollectionImpl(
      includedPaths: [
        for (final root in roots)
          if (!roots.any((other) => p.isWithin(other, root))) root,
      ],
      resourceProvider: overlay,
      sdkPath: sdkPath(),
      byteStore: _byteStore(),
      // Lint rules run on every speculative resolve and inform no verdict —
      // only errors and the analyzer's own import warnings do.
      configureAnalysisOptionsBuilder: ({required analysisOptionsBuilder}) {
        analysisOptionsBuilder
          ..lint = false
          ..lintRules = [];
      },
    );
    final contexts = [...collection.contexts]
      ..sort(
        (a, b) => b.contextRoot.root.path.length.compareTo(
          a.contextRoot.root.path.length,
        ),
      );

    final gate = _PackageGate();
    // A file pruned for one of its parts may convert sites of its own too.
    final byPath = <String, FileResult>{};
    for (final file in files) {
      final context = contexts.firstWhere(
        (c) => c.contextRoot.root.isOrContains(file),
      );
      for (final r in await _sanitizeFile(
        context,
        overlay,
        file,
        result,
        gate,
        offLimits,
      )) {
        byPath.update(
          r.path,
          (prior) => FileResult(
            r.path,
            [...prior.sites, ...r.sites],
            prior.reverted + r.reverted,
            removedImports: prior.removedImports + r.removedImports,
          ),
          ifAbsent: () => r,
        );
      }
    }
    result.files.addAll(byPath.values);
    return result;
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
    if (library is! ResolvedLibraryResult) return const [];
    final original = library.unitWithPath(file);
    if (original == null) return const [];

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
    final candidates = <Candidate>[];
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
            _keptSites(original.lineInfo, kept),
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
      offLimits: offLimits,
      result: result,
    ).run();
  }

  /// [c] as written, by its declaring type (`m.Fit.cover` and a typedef's
  /// `Mode.cover` both match `Fit.cover`), or by its bare member name.
  bool _isSkipped(Candidate c) =>
      skips.contains(c.display) ||
      skips.contains(c.memberName) ||
      (c.containerName != null &&
          skips.contains('${c.containerName}.${c.memberName}'));

  /// Canonical paths of the files under [paths], each once, sorted.
  List<String> _collectFiles(
    List<String> paths,
    bool Function(String path) isExcluded,
  ) {
    final files = <String>{};
    for (final rootPath in paths) {
      if (FileSystemEntity.isFileSync(rootPath)) {
        if (rootPath.endsWith('.dart') &&
            !isExcluded(_canonical(rootPath)) &&
            (!skipGenerated || !isGenerated(rootPath))) {
          files.add(_canonical(rootPath));
        }
        continue;
      }
      if (!FileSystemEntity.isDirectorySync(rootPath)) continue;

      final dirQueue = <Directory>[Directory(rootPath)];
      while (dirQueue.isNotEmpty) {
        final dir = dirQueue.removeLast();
        final List<FileSystemEntity> entities;
        try {
          entities = dir.listSync(followLinks: false);
        } on FileSystemException {
          continue;
        }

        for (final entity in entities) {
          final base = p.basename(entity.path);
          if (entity is Directory) {
            if (base.startsWith('.') || base == 'build') continue;
            dirQueue.add(entity);
          } else if (entity is File && entity.path.endsWith('.dart')) {
            if (isExcluded(_canonical(entity.path))) continue;
            if (skipGenerated && isGenerated(entity.path)) continue;
            files.add(_canonical(entity.path));
          }
        }
      }
    }
    return files.toList()..sort();
  }
}

/// Absolute and normalized, case kept: `p.canonicalize` lowercases on
/// Windows, where package-config roots keep their case.
String _canonical(String path) => p.normalize(p.absolute(path));

/// Which package a file belongs to, and whether the analyzer was handed that
/// package's own config. One per [Sanitizer.run]; lookups are memoised.
final class _PackageGate() {
  final _roots = <String, String?>{};
  final _configs = <String, PackageConfig?>{};

  String? rootOf(String file) => _rootOfDir(p.dirname(file));

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
    final pkg = config?.packageOf(Uri.file(file));
    return pkg != null && _canonical(p.fromUri(pkg.root)) == root;
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
  required final List<Candidate> candidates,

  /// Sites the collector's static pre-check ruled out before any resolve;
  /// reported as reverted, since they too stay prefixed.
  required final int unviable,

  /// Sites left prefixed before any resolve, when explaining; the verify
  /// loop's refusals join them in [FileResult.kept]. Null: not explaining.
  required final List<_Kept>? kept,
  required final bool dryRun,
  required final ResolvedLibraryResult library,
  required final ResolvedUnitResult original,
  required final String? Function(String path) offLimits,
  required final SanitizeResult result,
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
  List<Candidate> _active = [...candidates]..sort(_byOffset);
  final _dropped = <Candidate>[];
  _Rewritten? _clean;

  /// The latest verdict's reason for each refused candidate.
  final _why = <Candidate, String>{};

  /// Directive ranges to strip on write, per unit path of [file]'s library;
  /// [file]'s in [_clean]'s coordinates, every other unit's in its own.
  var _orphanCuts = const <String, List<(int, int)>>{};

  final _overlaid = <String>{};

  var _stamp = 0;

  Future<List<FileResult>> run() async {
    Map<String, String>? texts;
    try {
      if (await _converge()) await _recover();
      texts = await _finalize();
      // Written while the overlays still hold the same text: removing them
      // first would have the analyzer re-read the pre-write disk, and every
      // later file of the library would be judged against stale text.
      if (texts != null && !dryRun) {
        // All or nothing: a part written without its library leaves the
        // import it orphaned behind.
        final failure = _unwritable(texts.keys) ?? _writeAll(texts);
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
      // resolved after it in the same context.
      for (final path in _overlaid) {
        overlay.removeOverlay(path);
        context.changeFile(path);
      }
      await context.applyPendingFileChanges();
    }

    // No verified set: nothing converts and the files stay untouched.
    final converted = texts == null ? const <Candidate>[] : _active;
    final cuts = texts == null
        ? const <String, List<(int, int)>>{}
        : _orphanCuts;
    final done = converted.toSet();
    return [
      if (converted.isNotEmpty || kept != null)
        FileResult(
          file,
          [
            for (final c in converted)
              _siteAt(
                original.lineInfo,
                c.deleteStart,
                c.display,
                after: '.${c.memberName}',
              ),
            if (kept case final kept?)
              ..._keptSites(original.lineInfo, [
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
          removedImports: cuts[file]?.length ?? 0,
        ),
      for (final MapEntry(key: path, value: pruned) in cuts.entries)
        if (path != file)
          FileResult(path, const [], 0, removedImports: pruned.length),
    ];
  }

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
  Future<List<Candidate>> _largestClean(List<Candidate> set) async {
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
  /// with it). Candidates under different [Candidate.groupKey]s cannot
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
      final wave = <Candidate>[];
      final rest = <Candidate>[];
      for (final c in pending) {
        (seen.add(c.groupKey) ? wave : rest).add(c);
      }

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
      pending = rest;
    }
  }

  void _accept(_Attempt a) {
    _clean = a.rewritten;
    _orphanCuts = _orphanRanges(a.library, _userImportIssues);
  }

  /// The texts to write — [_clean] and every unit losing an orphaned import,
  /// pruned — or null when nothing converts. Pruning is re-verified: if the
  /// pruned library gains any diagnostic, nothing in [file] converts.
  Future<Map<String, String>?> _finalize() async {
    final clean = _clean;
    if (clean == null) return null;
    if (_orphanCuts.isEmpty) return {file: clean.text};

    for (final path in _orphanCuts.keys.where((other) => other != file)) {
      if (offLimits(path) case final why?) {
        final shown = p.relative(path, from: p.dirname(file));
        _refuseAll(
          'pruning its orphaned imports would edit $shown, which is $why',
        );
        return null;
      }
    }

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
  /// reported, not thrown, though earlier files may already be written.
  static ({String path, String error})? _writeAll(Map<String, String> texts) {
    for (final MapEntry(key: path, value: text) in texts.entries) {
      try {
        _write(path, text);
      } on FileSystemException catch (e) {
        return (path: path, error: e.osError?.message ?? e.message);
      }
    }
    return null;
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
  Future<_Attempt?> _attempt(List<Candidate> set) async {
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

  _Rewritten _apply(List<Candidate> set) {
    final buffer = StringBuffer();
    final newOffsets = <Candidate, int>{};
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

    final culprits = <Candidate>{};
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
        final gained = resolved.restrictions.difference(candidate.restrictions);
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
    Candidate candidate,
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

/// One verified rewrite of a candidate set: the text, its library's resolve
/// and the edited [unit] within it, the candidates node-level evidence
/// convicts, and the first new diagnostic none of them accounts for (see
/// [_FileSanitizer._verdict]), as `an error: …`, `a warning: …` or
/// `an info: …`.
final class _Attempt(
  final _Rewritten rewritten,
  final ResolvedLibraryResult library,
  final ResolvedUnitResult unit,
  final Set<Candidate> culprits, {
  required final String? stray,
}) {
  bool get isClean => culprits.isEmpty && stray == null;
}

/// A site left prefixed, and why — for [FileResult.kept].
typedef _Kept = ({int offset, String display, String reason});

/// Fallback reason for a candidate that only ever failed as part of a set.
const _unverified = 'not verifiable alongside the other rewrites';

List<Site> _keptSites(LineInfo lines, List<_Kept> kept) => [
  for (final k in kept)
    _siteAt(lines, k.offset, k.display, keptReason: k.reason),
];

Site _siteAt(
  LineInfo lines,
  int offset,
  String before, {
  String? after,
  String? keptReason,
}) {
  final location = lines.getLocation(offset);
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
  final Map<Candidate, int> newOffsets,
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
}) {
  bool matches(Candidate c) =>
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
  /// class; `_verdict` accepts that only where `Candidate.typedSlot` is
  /// exactly that type, so no cascade, assignment or inference observes it.
  bool forwardsTo(Candidate c) =>
      redirectTarget != null &&
      redirectTarget!.matches(c) &&
      redirectTarget!.signature == c.signature;
}

/// `ReturnType(params)` of a constructor, instantiated as resolved — the
/// identity [_ResolvedShorthand.forwardsTo] compares across a redirect.
String _constructorSignature(ConstructorElement e) =>
    '${_typeKey(e.returnType)}${_parametersOf(e)}';

/// The formal parameter list of [e]: kind, type and name of each, positional
/// in order, named sorted by name — `only({left, right, top, bottom})` and
/// `only({left, top, right, bottom})` accept the same calls.
String _parametersOf(ConstructorElement e) {
  String show(FormalParameterElement p) =>
      '${p.isOptionalPositional ? '[' : ''}'
      '${_typeKey(p.type)} ${p.name}';
  final positional = [
    for (final p in e.formalParameters)
      if (!p.isNamed) show(p),
  ];
  final named = [
    for (final p in e.formalParameters)
      if (p.isNamed) '{${show(p)}',
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
    if (holder.metadata.hasVisibleForTesting) '@visibleForTesting',
    if (holder.metadata.hasVisibleOutsideTemplate) '@visibleOutsideTemplate',
  },
};

/// A field's annotations sit on the field, not on its getter.
List<Element> _holdersOf(Element? element) => [
  ?element,
  if (element is PropertyAccessorElement) element.variable,
];

int _byOffset(Candidate a, Candidate b) =>
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

/// Directive ranges (each spanning `import … ;` plus its line ending) for
/// imports the rewrite orphaned — a removable-import diagnostic of [check]
/// not among [userIssues] — keyed by unit path. Coordinates are each unit's
/// content in [check]: the rewritten text for the edited unit, the untouched
/// text for every other.
Map<String, List<(int, int)>> _orphanRanges(
  ResolvedLibraryResult check,
  Set<_ImportIssue> userIssues,
) {
  final cuts = <String, List<(int, int)>>{};
  for (final unit in check.units) {
    final text = unit.content;
    final cut = <int>{};
    for (final d in unit.diagnostics) {
      if (!_isRemovableImport(d)) continue;
      final index = _importAt(unit, d.offset);
      if (index == null ||
          userIssues.contains((
            unit.path,
            index,
            d.diagnosticCode.lowerCaseName,
          )) ||
          !cut.add(index)) {
        continue;
      }
      final directive = unit.unit.directives[index];
      var end = directive.end;
      if (end < text.length && text.codeUnitAt(end) == 0x0D) end++; // \r
      if (end < text.length && text.codeUnitAt(end) == 0x0A) end++; // \n
      (cuts[unit.path] ??= []).add((directive.offset, end));
    }
  }
  return cuts;
}

/// Splices [ranges] out of [text] in order.
String _stripRanges(String text, List<(int, int)> ranges) {
  final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
  final buffer = StringBuffer();
  var cursor = 0;
  for (final (start, end) in sorted) {
    buffer.write(text.substring(cursor, start));
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
  final candidates = <Candidate>[];

  /// Sites [_Viability] ruled out — they stay prefixed without a resolve.
  final unviable = <_Kept>[];

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
    if (_viability.whyNot(node, memberName) case final reason?) {
      unviable.add((offset: deleteStart, display: display, reason: reason));
      return;
    }
    candidates.add(
      Candidate(
        groupKey: _groupKeyOf(node),
        deleteStart: deleteStart,
        deleteEnd: dotOffset,
        shorthandOffset: dotOffset,
        display: display,
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
        typedSlot: _viability.typedSlotOf(node),
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
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final name = node.constructorName.name;
    final type = node.constructorName.type;
    if (name != null && type.typeArguments == null) {
      _add(
        node: node,
        deleteStart: node.constructorName.offset,
        dotOffset: name.offset - 1, // the `.` sits right before the name
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
/// postfix chain it heads — `.of(context).colorScheme` looks `of` up on
/// `ColorScheme`, `.tryParse(s)!` on `int` — and the rewrite is a no-op only
/// if that type declares a static `member` the verdict accepts (the original,
/// a const alias, a redirecting factory). So:
///
/// - where the syntax pins the context type down (an argument's parameter,
///   a declared variable type, the enclosing function's return type, an
///   assignment target, a collection literal's element type), that type must
///   declare `member`;
/// - where the position provably has no context type (an expression
///   statement, `var x = …`, an `as`/`is` operand, an interpolation, a
///   binary left operand) or one that can't declare it (`throw` resolves
///   against `Object`), the site never converts;
/// - otherwise the chain's own static type must be assignable to the context
///   type, so one of its supertypes must declare `member`.
///
/// Every rule is a necessary condition only — a site that passes is still
/// verified by the resolve, a site that fails would have been reverted after
/// costing one. Type parameters, `dynamic` and an unresolved parameter are
/// "can't tell" and pass.
final class _Viability(final TypeProvider typeProvider) {
  /// Why [site] can never verify, or null when it might.
  String? whyNot(Expression site, String member) {
    AstNode head = site;
    while (_passesContextTo(head.parent, head)) {
      head = head.parent!;
    }
    final context = _contextOf(head);
    if (context != null) return _refusal(context, member);
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
  /// argument, a typed declaration, a return, a collection element or a
  /// parameter default whose context type is an interface type, reached only
  /// through wrappers that pass the value on unobserved ([_isTransparent]).
  /// Keyed without one trailing `?`: a nullable slot types the shorthand
  /// as its non-null class. Null elsewhere — a cascade target, an assignment
  /// or an inferred declaration observes the shorthand's own static type.
  String? typedSlotOf(Expression site) {
    AstNode head = site;
    for (
      var parent = head.parent;
      parent != null && _isTransparent(parent, head);
      parent = head.parent
    ) {
      head = parent;
    }
    if (head.parent
        case ArgumentList() ||
            VariableDeclaration() ||
            ReturnStatement() ||
            ExpressionFunctionBody() ||
            ListLiteral() ||
            SetOrMapLiteral() ||
            MapLiteralEntry() ||
            FormalParameterDefaultClause()) {
      if (_contextOf(head) case final InterfaceType slot) {
        final key = _typeKey(slot);
        return key.endsWith('?') ? key.substring(0, key.length - 1) : key;
      }
    }
    return null;
  }

  /// Whether [parent] passes [child]'s value through to its own slot
  /// unobserved. A switch scrutinee is observed by its patterns.
  static bool _isTransparent(AstNode parent, AstNode child) => switch (parent) {
    ParenthesizedExpression() || NamedArgument() || ForElement() => true,
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      identical(thenExpression, child) || identical(elseExpression, child),
    SwitchExpressionCase(:final expression) => identical(expression, child),
    SwitchExpression(:final expression) => !identical(expression, child),
    IfElement(:final thenElement, :final elseElement) =>
      identical(thenElement, child) || identical(elseElement, child),
    _ => false,
  };

  /// Whether [parent] hands its own context type down to [child] — as the
  /// head of a selector chain, or as a syntactic wrapper the context type
  /// passes through.
  static bool _passesContextTo(AstNode? parent, AstNode child) =>
      switch (parent) {
        PropertyAccess(:final target) => identical(target, child),
        MethodInvocation(:final target) => identical(target, child),
        IndexExpression(:final target) => identical(target, child),
        CascadeExpression(:final target) => identical(target, child),
        PostfixExpression() ||
        ParenthesizedExpression() ||
        AwaitExpression() ||
        NamedArgument() ||
        SwitchExpression() ||
        ForElement() ||
        NullAwareElement() => true,
        ConditionalExpression(:final thenExpression, :final elseExpression) =>
          identical(thenExpression, child) || identical(elseExpression, child),
        BinaryExpression(:final operator) =>
          operator.type == .QUESTION_QUESTION,
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
    switch (parent) {
      case ExpressionStatement() ||
          AsExpression() ||
          IsExpression() ||
          InterpolationExpression():
        return none;
      case VariableDeclaration():
        return (parent.parent! as VariableDeclarationList).type?.type ?? none;
      case ThrowExpression():
        return typeProvider.objectType;
      case PrefixExpression(:final operator):
        return operator.type == .BANG ? bool : none;
      case BinaryExpression(:final operator, :final leftOperand):
        if (operator.type == .AMPERSAND_AMPERSAND ||
            operator.type == .BAR_BAR) {
          return bool;
        }
        if (identical(leftOperand, head)) return none;
        if (operator.type == .EQ_EQ || operator.type == .BANG_EQ) {
          return leftOperand.staticType;
        }
        return parent.element?.formalParameters.firstOrNull?.type;
      case IfStatement(:final expression) ||
              IfElement(:final expression) ||
              WhileStatement(condition: final expression) ||
              DoStatement(condition: final expression) ||
              AssertStatement(condition: final expression)
          when identical(expression, head):
        return bool;
      case ArgumentList():
        final type = (head as Argument).correspondingParameter?.type;
        return type is TypeParameterType ? null : type;
      case AssignmentExpression(:final rightHandSide)
          when identical(rightHandSide, head):
        return parent.writeType;
      case FormalParameterDefaultClause(parent: final FormalParameter param):
        return param.declaredFragment?.element.type;
      case ReturnStatement() || ExpressionFunctionBody():
        return _returnContext(parent.thisOrAncestorOfType<FunctionBody>()!);
      case ListLiteral(:final staticType) || SetOrMapLiteral(:final staticType):
        return _elementType(staticType, 0);
      case MapLiteralEntry(:final key, parent: final Expression literal):
        return _elementType(literal.staticType, identical(key, head) ? 0 : 1);
      default:
        return null;
    }
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

  static DartType? _elementType(DartType? literal, int index) =>
      literal is InterfaceType && literal.typeArguments.length > index
      ? literal.typeArguments[index]
      : null;

  /// Why a context type [type] cannot hold a static [member] the verdict
  /// would accept, or null when it could. `FutureOr<T>` resolves the
  /// shorthand on `T`; `Never` is [_contextOf]'s "no context type".
  static String? _refusal(DartType type, String member) {
    var t = type;
    if (t is InterfaceType && t.isDartAsyncFutureOr) t = t.typeArguments.first;
    return switch (t) {
      InterfaceType(:final element) when element.getStatic(member) != null =>
        null,
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
