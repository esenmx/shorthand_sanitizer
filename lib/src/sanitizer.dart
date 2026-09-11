import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
// The public `AnalysisContextCollection` factory takes neither a byte store
// nor an options hook; `dart analyze` and the analysis server build on these
// same classes.
// ignore_for_file: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:cli_util/cli_util.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

String? _cachedSdkPath;

/// Locates the Dart SDK for the analyzer. Inside a JIT run the executable
/// lives in the SDK; an AOT-compiled binary does not, so fall back to
/// `DART_SDK`, then to the `dart` on PATH (following the Flutter shim, whose
/// SDK sits under `bin/cache/dart-sdk`). `package:cli_util`'s `sdkPath` is
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

  final which = Process.runSync('which', ['dart']).stdout.toString().trim();
  if (which.isEmpty) return null;
  final bin = p.dirname(File(which).resolveSymbolicLinksSync());
  for (final candidate in [p.join(bin, 'cache', 'dart-sdk'), p.dirname(bin)]) {
    if (isSdk(candidate)) return _cachedSdkPath = candidate;
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

  /// Offset of the enclosing statement (or declaration, outside a body).
  /// Type inference does not cross that boundary, so two candidates with
  /// different keys cannot affect each other's resolution — which is what
  /// lets the recovery pass test one per key at a time in a single resolve.
  final int groupKey = -1,
}) {
  /// Creates a candidate; produced by the sanitizer's AST pass.
  this;
}

/// Per-file outcome of a sanitize run.
final class FileResult(
  /// Canonical path of the rewritten file.
  final String path,

  /// One `"line: Type.member -> .member"` entry per converted site.
  final List<String> converted,

  /// Candidates that failed verification and were left prefixed.
  final int reverted, {

  /// Imports the conversion orphaned and this run pruned (see [Sanitizer]).
  final int removedImports = 0,
}) {
  /// Creates a result for [path].
  this;
}

/// Aggregate outcome across all files of a run.
final class SanitizeResult {
  /// Files that had at least one candidate.
  final List<FileResult> files = [];

  /// Sites left prefixed because they matched the skip list.
  int skippedByList = 0;

  /// Files skipped whole because their package's language version predates
  /// dot shorthands, counted per `major.minor` version. Such a package cannot
  /// hold the rewrite at all, so an otherwise convertible run reports zero
  /// conversions — this is what makes that visible.
  final Map<String, int> skippedBelowFloor = {};

  /// Total converted sites.
  int get convertedCount => files.fold(0, (n, f) => n + f.converted.length);

  /// Total reverted sites.
  int get revertedCount => files.fold(0, (n, f) => n + f.reverted);

  /// Total imports pruned because the conversion orphaned them.
  int get removedImportCount => files.fold(0, (n, f) => n + f.removedImports);
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

  /// Glob patterns of files to leave alone — matched against the
  /// CWD-relative path when the pattern contains `/`, else the basename
  /// (`firebase_options.dart`, `**/legacy/**`).
  final List<String> excludes = const [],

  /// Report what would convert without writing any file.
  final bool dryRun = false,

  /// Skip files whose leading comment declares them generated ([isGenerated]).
  final bool skipGenerated = true,
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
  /// Scanning stops at the first line that is neither blank nor a comment: a
  /// generator writes its marker in the banner, so a comment sitting below the
  /// first declaration is ordinary prose no matter what it says. The marker
  /// matches `generated`/`auto-generated`, never the bare stem — that would
  /// flag a handwritten header merely noting that something *regenerates* and
  /// silently skip the whole file.
  static bool isGenerated(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final raf = file.openSync();
    final String head;
    try {
      head = .fromCharCodes(raf.readSync(1024));
    } finally {
      raf.closeSync();
    }
    for (final line in head.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.startsWith('//') && !trimmed.startsWith('#')) return false;
      if (_generatedMarker.hasMatch(trimmed)) return true;
    }
    return false;
  }

  /// Sanitizes every non-generated `.dart` file under [paths]
  /// (files or directories).
  Future<SanitizeResult> run(List<String> paths) async {
    final files = _collectFiles(paths);
    final result = SanitizeResult();
    if (files.isEmpty) return result;

    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    // Roots, not files: the locator spends ~2ms per included path, a second
    // per 500 files. An `analyzer: exclude:` in the package's options then
    // hides those files from `contextFor`, so contexts are picked by root
    // below — every collected file is analyzed, as before.
    final collection = AnalysisContextCollectionImpl(
      includedPaths: paths.map(p.canonicalize).toSet().toList(),
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

    for (final file in files.map(p.canonicalize)) {
      final context = contexts.firstWhere(
        (c) => c.contextRoot.root.isOrContains(file),
      );
      final fileResult = await _sanitizeFile(context, overlay, file, result);
      if (fileResult != null) result.files.add(fileResult);
    }
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

  Future<FileResult?> _sanitizeFile(
    AnalysisContext context,
    OverlayResourceProvider overlay,
    String file,
    SanitizeResult result,
  ) async {
    final original = await context.currentSession.getResolvedUnit(file);
    if (original is! ResolvedUnitResult) return null;

    // The installed SDK does not decide this — the package's own `environment:
    // sdk:` constraint does. Below the floor every rewrite fails to parse, so
    // the verify loop would revert all of them and report an ordinary
    // "converted 0 site(s)", indistinguishable from having nothing to convert.
    final language = original.libraryElement.languageVersion.effective;
    if (language.major < _floorMajor ||
        (language.major == _floorMajor && language.minor < _floorMinor)) {
      result.skippedBelowFloor.update(
        '${language.major}.${language.minor}',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      return null;
    }

    final collector = _CandidateCollector(original.typeProvider);
    original.unit.accept(collector);
    final candidates = <Candidate>[];
    for (final c in collector.candidates) {
      if (skips.contains(c.display) || skips.contains(c.memberName)) {
        result.skippedByList++;
      } else {
        candidates.add(c);
      }
    }
    if (candidates.isEmpty) return null;

    return await _FileSanitizer(
      context: context,
      overlay: overlay,
      file: file,
      original: original,
      candidates: candidates,
      unviable: collector.unviable,
      dryRun: dryRun,
    ).run();
  }

  List<String> _collectFiles(List<String> paths) {
    final globs = [for (final e in excludes) Glob(e)];
    bool isExcludedPath(String path) {
      final relative = p
          .relative(p.canonicalize(path))
          .replaceAll(p.separator, '/');
      final base = p.basename(path);
      return globs.any((g) => g.matches(relative) || g.matches(base));
    }

    final files = <String>[];
    for (final rootPath in paths) {
      if (FileSystemEntity.isFileSync(rootPath)) {
        if (rootPath.endsWith('.dart') &&
            !isExcludedPath(rootPath) &&
            (!skipGenerated || !isGenerated(rootPath))) {
          files.add(rootPath);
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
            if (isExcludedPath(entity.path)) continue;
            if (skipGenerated && isGenerated(entity.path)) continue;
            files.add(entity.path);
          }
        }
      }
    }
    return files..sort();
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
  required final bool dryRun,
  required final ResolvedUnitResult original,
}) {
  final String content = original.content;
  final Set<String> baseline = _errorKeys(original.diagnostics);

  // Imports already unused before we touched the file are the user's to
  // keep; only orphans we newly create get pruned.
  final Set<String> baselineImports = _importIssueKeys(original.diagnostics);
  final _constCache = <(String, String, String), DartObject?>{};

  /// Candidates still in the running; once [_clean] is set, exactly the ones
  /// it converts.
  List<Candidate> _active = [...candidates]..sort(_byOffset);
  final _dropped = <Candidate>[];
  _Rewritten? _clean;

  /// Directive ranges (in [_clean]'s coordinates) to strip on write.
  var _orphanCuts = const <(int, int)>[];

  var _stamp = 0;

  Future<FileResult?> run() async {
    try {
      if (!await _converge()) return null;
      await _recover();
    } finally {
      // Unconditional: the overlay holds speculative text, so bailing out with
      // it still installed leaks this file's unverified rewrite into every
      // file resolved after it in the same context.
      overlay.removeOverlay(file);
      context.changeFile(file);
      await context.applyPendingFileChanges();
    }

    if (_clean case final rewritten? when _active.isNotEmpty) {
      return _write(rewritten);
    }
    return null; // nothing verifiable — file untouched
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
    if (set.length == 1) return const [];
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
        }
      }
      pending = rest;
    }
  }

  void _accept(_Attempt a) {
    _clean = a.rewritten;
    _orphanCuts = _orphanRanges(a.check, baselineImports);
  }

  /// Rewrites the file with [set] applied and resolves the result, or null if
  /// that text no longer resolves.
  Future<_Attempt?> _attempt(List<Candidate> set) async {
    final rewritten = _apply(set);
    overlay.setOverlay(
      file,
      content: rewritten.text,
      modificationStamp: ++_stamp,
    );
    context.changeFile(file);
    await context.applyPendingFileChanges();
    final check = await context.currentSession.getResolvedUnit(file);
    if (check is! ResolvedUnitResult) return null;
    return await _verdict(rewritten, check);
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
  /// one: the errors a broken candidate causes vanish with it. They only
  /// raise [_Attempt.strayErrors], damage with no author, which forces the
  /// set to be bisected.
  Future<_Attempt> _verdict(
    _Rewritten rewritten,
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
      } else if (!resolved.matches(candidate) &&
          !resolved.forwardsTo(candidate) &&
          !await _isConstAlias(candidate, resolved, selfUri)) {
        culprits.add(candidate);
      }
    }

    final stray =
        culprits.isEmpty &&
        check.diagnostics.any(
          (d) => d.severity == .error && !baseline.contains(_errorKey(d)),
        );
    return _Attempt(rewritten, check, culprits, strayErrors: stray);
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

  FileResult _write(_Rewritten rewritten) {
    if (!dryRun) {
      final text = _orphanCuts.isEmpty
          ? rewritten.text
          : _stripRanges(rewritten.text, _orphanCuts);
      File(file).writeAsStringSync(text);
    }
    return FileResult(
      file,
      [
        for (final c in _active)
          '${_lineOf(c.deleteStart)}: ${c.display} -> .${c.memberName}',
      ],
      candidates.length - _active.length + unviable,
      removedImports: _orphanCuts.length,
    );
  }

  int _lineOf(int offset) => original.lineInfo.getLocation(offset).lineNumber;
}

/// One verified rewrite of a candidate set: the text, its resolve, the
/// candidates node-level evidence convicts, and whether unattributable errors
/// remain (see [_FileSanitizer._verdict]).
final class _Attempt(
  final _Rewritten rewritten,
  final ResolvedUnitResult check,
  final Set<Candidate> culprits, {
  required final bool strayErrors,
}) {
  bool get isClean => culprits.isEmpty && !strayErrors;
}

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
  /// signature comparison refuses that. The invocation's own static type
  /// widens to the factory's class, which cannot leak: a candidate is never a
  /// receiver, and the shorthand only resolves where that class is already
  /// the context type.
  bool forwardsTo(Candidate c) =>
      redirectTarget != null &&
      redirectTarget!.matches(c) &&
      redirectTarget!.signature == c.signature;
}

/// `ReturnType(params)` of a constructor, instantiated as resolved — the
/// identity [_ResolvedShorthand.forwardsTo] compares across a redirect.
String _constructorSignature(ConstructorElement e) =>
    '${e.returnType.getDisplayString()}${_parametersOf(e)}';

/// The formal parameter list of [e]: kind, type and name of each, positional
/// in order, named sorted by name — `only({left, right, top, bottom})` and
/// `only({left, top, right, bottom})` accept the same calls.
String _parametersOf(ConstructorElement e) {
  String show(FormalParameterElement p) =>
      '${p.isOptionalPositional ? '[' : ''}'
      '${p.type.getDisplayString()} ${p.name}';
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

int _byOffset(Candidate a, Candidate b) =>
    a.deleteStart.compareTo(b.deleteStart);

/// Offsets shift across rewrites — key errors by code + message instead.
String _errorKey(Diagnostic d) =>
    '${d.diagnosticCode.lowerCaseName}:${d.message}';

Set<String> _errorKeys(List<Diagnostic> diagnostics) => {
  for (final d in diagnostics)
    if (d.severity == .error) _errorKey(d),
};

/// Import-scoped diagnostics whose fix is to drop the whole directive.
const _removableImportCodes = {
  'unused_import',
  'unnecessary_import',
  'duplicate_import',
};

bool _isRemovableImport(Diagnostic d) =>
    _removableImportCodes.contains(d.diagnosticCode.lowerCaseName);

Set<String> _importIssueKeys(List<Diagnostic> diagnostics) => {
  for (final d in diagnostics)
    if (_isRemovableImport(d)) _errorKey(d),
};

/// Directive ranges (each spanning `import … ;` plus its line ending) for
/// imports the rewrite orphaned — those [check] now flags removable that
/// weren't in [baseline]. Coordinates are [check]'s content, i.e. the
/// rewritten text about to be written.
List<(int, int)> _orphanRanges(ResolvedUnitResult check, Set<String> baseline) {
  final text = check.content;
  final imports = check.unit.directives.whereType<ImportDirective>().toList();
  if (imports.isEmpty) return const [];

  final seen = <int>{};
  final ranges = <(int, int)>[];
  for (final d in check.diagnostics) {
    if (!_isRemovableImport(d) || baseline.contains(_errorKey(d))) continue;
    for (final directive in imports) {
      if (d.offset < directive.offset || d.offset >= directive.end) continue;
      if (!seen.add(directive.offset)) break;
      var end = directive.end;
      if (end < text.length && text.codeUnitAt(end) == 0x0D) end++; // \r
      if (end < text.length && text.codeUnitAt(end) == 0x0A) end++; // \n
      ranges.add((directive.offset, end));
      break;
    }
  }
  return ranges;
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

  void _add(int offset, String memberName, Element? element) {
    byOffset[offset] = _ResolvedShorthand(
      memberName,
      element?.enclosingElement?.displayName,
      element?.library?.uri.toString(),
      redirectTarget: element is ConstructorElement
          ? _redirectTargetOf(element)
          : null,
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
      signature: '${cur.returnType.getDisplayString()}$params',
    );
  }

  @override
  void visitDotShorthandPropertyAccess(DotShorthandPropertyAccess node) {
    _add(node.period.offset, node.propertyName.name, node.propertyName.element);
    super.visitDotShorthandPropertyAccess(node);
  }

  @override
  void visitDotShorthandInvocation(DotShorthandInvocation node) {
    _add(node.period.offset, node.memberName.name, node.memberName.element);
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
    );
    super.visitDotShorthandConstructorInvocation(node);
  }
}

final class _CandidateCollector(TypeProvider typeProvider)
    extends RecursiveAstVisitor<void> {
  final _viability = _Viability(typeProvider);
  final candidates = <Candidate>[];

  /// Sites [_Viability] ruled out — they stay prefixed without a resolve.
  int unviable = 0;

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
    if (!_viability.check(node, memberName)) {
      unviable++;
      return;
    }
    candidates.add(
      Candidate(
        groupKey: _groupKeyOf(node),
        deleteStart: deleteStart,
        deleteEnd: dotOffset,
        shorthandOffset: dotOffset,
        display: '$owner.$memberName',
        memberName: memberName,
        containerName: memberElement?.enclosingElement?.displayName,
        libraryUri: memberElement?.library?.uri.toString(),
        signature: memberElement is ConstructorElement
            ? _constructorSignature(memberElement)
            : null,
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
  bool check(Expression site, String member) {
    AstNode head = site;
    while (_passesContextTo(head.parent, head)) {
      head = head.parent!;
    }
    final context = _contextOf(head);
    if (context != null) return _admits(context, member);
    final type = head is Expression ? head.staticType : null;
    if (type is! InterfaceType) return true;
    return type.element.getStatic(member) != null ||
        type.element.allSupertypes.any(
          (t) => t.element.getStatic(member) != null,
        );
  }

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
          operator.type == TokenType.QUESTION_QUESTION,
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
        return operator.type == TokenType.BANG ? bool : none;
      case BinaryExpression(:final operator, :final leftOperand):
        if (operator.type == TokenType.AMPERSAND_AMPERSAND ||
            operator.type == TokenType.BAR_BAR) {
          return bool;
        }
        if (identical(leftOperand, head)) return none;
        if (operator.type == TokenType.EQ_EQ ||
            operator.type == TokenType.BANG_EQ) {
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

  /// Whether a context type [type] could hold a static [member] the verdict
  /// would accept. `FutureOr<T>` resolves the shorthand on `T`.
  static bool _admits(DartType type, String member) {
    var t = type;
    if (t is InterfaceType && t.isDartAsyncFutureOr) t = t.typeArguments.first;
    return switch (t) {
      InterfaceType(:final element) => element.getStatic(member) != null,
      TypeParameterType() || DynamicType() || InvalidType() => true,
      _ => false, // void, Never, function and record types declare nothing
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
