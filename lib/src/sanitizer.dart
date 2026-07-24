import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Locates the Dart SDK for the analyzer. Inside a JIT run the executable
/// lives in the SDK; an AOT-compiled binary does not, so fall back to
/// `DART_SDK`, then to the `dart` on PATH (following the Flutter shim, whose
/// SDK sits under `bin/cache/dart-sdk`).
String? sdkPath() {
  bool isSdk(String dir) =>
      File(p.join(dir, 'version')).existsSync() &&
      Directory(p.join(dir, 'lib', '_internal')).existsSync();

  final env = Platform.environment['DART_SDK'];
  if (env != null && isSdk(env)) return env;

  final exeSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  if (isSdk(exeSdk)) return exeSdk;

  final which = Process.runSync('which', ['dart']).stdout.toString().trim();
  if (which.isEmpty) return null;
  final bin = p.dirname(File(which).resolveSymbolicLinksSync());
  for (final candidate in [p.join(bin, 'cache', 'dart-sdk'), p.dirname(bin)]) {
    if (isSdk(candidate)) return candidate;
  }
  return null;
}

/// One `Type.member` occurrence that may convert to `.member`.
final class Candidate {
  /// Creates a candidate; produced by the sanitizer's AST pass.
  Candidate({
    required this.deleteStart,
    required this.deleteEnd,
    required this.shorthandOffset,
    required this.display,
    required this.memberName,
    required this.containerName,
    required this.libraryUri,
    this.groupKey = -1,
  });

  /// Start of the `Type` prefix to delete.
  final int deleteStart;

  /// End (exclusive) of the deleted prefix — the char before the `.`.
  final int deleteEnd;

  /// Offset of the `.` — where the shorthand node begins after the rewrite.
  final int shorthandOffset;

  /// `Type.member` as written, for reporting and skip-list matching.
  final String display;

  /// The accessed member (`all` in `EdgeInsets.all`).
  final String memberName;

  /// The declaring type's name — identity check anchor.
  final String? containerName;

  /// The declaring library's URI — identity check anchor.
  final String? libraryUri;

  /// Offset of the enclosing statement (or declaration, outside a body).
  /// Type inference does not cross that boundary, so two candidates with
  /// different keys cannot affect each other's resolution — which is what
  /// lets the recovery pass test one per key at a time in a single resolve.
  final int groupKey;
}

/// Per-file outcome of a sanitize run.
final class FileResult {
  /// Creates a result for [path].
  FileResult(
    this.path,
    this.converted,
    this.reverted, {
    this.removedImports = 0,
  });

  /// Canonical path of the rewritten file.
  final String path;

  /// One `"line: Type.member -> .member"` entry per converted site.
  final List<String> converted;

  /// Candidates that failed verification and were left prefixed.
  final int reverted;

  /// Imports the conversion orphaned and this run pruned (see [Sanitizer]).
  final int removedImports;
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
/// One rebind is licensed: a shorthand landing on a `static const` alias of
/// the original (`AlignmentGeometry.topCenter = Alignment.topCenter`) is a
/// different element holding the identical canonicalized constant, so the
/// rewrite is observably a no-op. Const-value identity, not element identity,
/// decides that case — see `_isConstAlias` for what it still refuses.
///
/// Dropping a `Type` prefix can orphan the import that supplied it. The
/// verified resolve is the oracle: an `unused_import`/`unnecessary_import` it
/// reports that the original did not is self-inflicted, so its directive is
/// pruned. Imports the file already left unused are the user's — they stay.
final class Sanitizer {
  /// Creates a sanitizer; see [run].
  Sanitizer({
    this.skips = const {},
    this.excludes = const [],
    this.dryRun = false,
    this.skipGenerated = true,
  });

  /// `Type.member` or bare `member` names that must stay prefixed.
  final Set<String> skips;

  /// Glob patterns of files to leave alone — matched against the
  /// CWD-relative path when the pattern contains `/`, else the basename
  /// (`firebase_options.dart`, `**/legacy/**`).
  final List<String> excludes;

  /// Report what would convert without writing any file.
  final bool dryRun;

  /// Skip files whose leading comment declares them generated ([isGenerated]).
  final bool skipGenerated;

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
    final collection = AnalysisContextCollection(
      includedPaths: files.map(p.canonicalize).toList(),
      resourceProvider: overlay,
      sdkPath: sdkPath(),
    );

    for (final file in files.map(p.canonicalize)) {
      final fileResult = await _sanitizeFile(collection, overlay, file, result);
      if (fileResult != null) result.files.add(fileResult);
    }
    return result;
  }

  Future<FileResult?> _sanitizeFile(
    AnalysisContextCollection collection,
    OverlayResourceProvider overlay,
    String file,
    SanitizeResult result,
  ) async {
    final context = collection.contextFor(file);
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

    final collector = _CandidateCollector();
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

    return _FileSanitizer(
      context: context,
      overlay: overlay,
      file: file,
      original: original,
      candidates: candidates,
      dryRun: dryRun,
    ).run();
  }

  List<String> _collectFiles(List<String> paths) {
    final globs = [for (final e in excludes) Glob(e)];
    bool excluded(String path) {
      if (skipGenerated && isGenerated(path)) return true;
      final relative = p
          .relative(p.canonicalize(path))
          .replaceAll(p.separator, '/');
      return globs.any(
        (g) => g.matches(relative) || g.matches(p.basename(path)),
      );
    }

    final files = <String>[];
    for (final path in paths) {
      if (FileSystemEntity.isFileSync(path)) {
        if (path.endsWith('.dart') && !excluded(path)) files.add(path);
        continue;
      }
      if (!FileSystemEntity.isDirectorySync(path)) continue;
      for (final entity in Directory(path).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('${p.separator}.') ||
            entity.path.contains('${p.separator}build${p.separator}')) {
          continue;
        }
        if (excluded(entity.path)) continue;
        files.add(entity.path);
      }
    }
    return files..sort();
  }
}

/// The verify-and-narrow pipeline for one file: apply every candidate, read
/// the verdict off the rewritten resolve, drop what it convicts, then re-offer
/// what a broken neighbour may merely have starved. Owns [file]'s overlay for
/// the duration of [run].
final class _FileSanitizer {
  _FileSanitizer({
    required this.context,
    required this.overlay,
    required this.file,
    required this.candidates,
    required this.dryRun,
    required ResolvedUnitResult original,
  }) : content = original.content,
       baseline = _errorKeys(original.diagnostics),
       // Imports already unused before we touched the file are the user's to
       // keep; only orphans we newly create get pruned.
       baselineImports = _importIssueKeys(original.diagnostics),
       _active = [...candidates]..sort(_byOffset);

  final AnalysisContext context;
  final OverlayResourceProvider overlay;
  final String file;
  final String content;
  final List<Candidate> candidates;
  final bool dryRun;
  final Set<String> baseline;
  final Set<String> baselineImports;

  /// Candidates still in the running; once [_clean] is set, exactly the ones
  /// it converts.
  List<Candidate> _active;
  final _dropped = <Candidate>[];
  _Rewritten? _clean;

  /// Directive ranges (in [_clean]'s coordinates) to strip on write.
  var _orphanCuts = const <(int, int)>[];

  var _stamp = 0;
  late final List<int> _lines = _lineStarts(content);

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

    if (_clean case final rewritten?) return _write(rewritten);
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
  Future<void> _recover() async {
    var pending = _dropped;
    while (_clean != null && pending.isNotEmpty) {
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
      final settled = a.isClean ? a : await _attempt(regained);
      if (settled != null && settled.isClean) {
        _active = a.isClean ? trial : regained;
        _accept(settled);
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
    return _verdict(rewritten, check);
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
          !await _isConstAlias(check.session, candidate, resolved, selfUri)) {
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
  /// equivalent (`EdgeInsetsGeometry.all(8)` allocates a fresh, non-const
  /// instance — no constant value, no rescue) and every same-named sibling
  /// holding a different value (`Base.a` vs `Sub.a`,
  /// `AlignmentDirectional.center` in an `AlignmentGeometry` slot — the
  /// value's type differs).
  ///
  /// Both sides are looked up fresh through [session] rather than reusing the
  /// elements the two resolves handed back: a constant only evaluates on an
  /// element whose library is the session's current one, and the two values
  /// must come from one element model for their types to compare equal.
  ///
  /// A constant declared in [selfUri] is read out of the speculative text,
  /// which would make the check circular — the rewrite could be what changed
  /// the value it is judged against. Every other library is untouched by the
  /// overlay, so its constants are pristine; same-library aliases never
  /// rescue.
  static Future<bool> _isConstAlias(
    AnalysisSession session,
    Candidate candidate,
    _ResolvedShorthand resolved,
    String selfUri,
  ) async {
    if (candidate.libraryUri == selfUri || resolved.libraryUri == selfUri) {
      return false;
    }

    final before = await _constantOf(
      session,
      candidate.libraryUri,
      candidate.containerName,
      candidate.memberName,
    );
    if (before == null || !before.hasKnownValue) return false;

    final after = await _constantOf(
      session,
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
  static Future<DartObject?> _constantOf(
    AnalysisSession session,
    String? uri,
    String? container,
    String member,
  ) async {
    if (uri == null || container == null) return null;
    final library = await session.getLibraryByUri(uri);
    if (library is! LibraryElementResult) return null;
    final holder =
        library.element.getClass(container) ??
        library.element.getEnum(container) ??
        library.element.getMixin(container) ??
        library.element.getExtensionType(container);
    return holder?.getField(member)?.computeConstantValue();
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
      candidates.length - _active.length,
      removedImports: _orphanCuts.length,
    );
  }

  int _lineOf(int offset) {
    var low = 0;
    var high = _lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_lines[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }
}

/// One verified rewrite of a candidate set: the text, its resolve, the
/// candidates node-level evidence convicts, and whether unattributable errors
/// remain (see [_FileSanitizer._verdict]).
final class _Attempt {
  _Attempt(
    this.rewritten,
    this.check,
    this.culprits, {
    required this.strayErrors,
  });

  final _Rewritten rewritten;
  final ResolvedUnitResult check;
  final Set<Candidate> culprits;
  final bool strayErrors;

  bool get isClean => culprits.isEmpty && !strayErrors;
}

final class _Rewritten {
  _Rewritten(this.text, this.newOffsets);

  final String text;

  /// Where each candidate's shorthand `.` landed in [text].
  final Map<Candidate, int> newOffsets;
}

/// Identity of what a shorthand node resolved to, keyed by node offset.
final class _ResolvedShorthand {
  _ResolvedShorthand(this.memberName, this.containerName, this.libraryUri);

  final String memberName;
  final String? containerName;
  final String? libraryUri;

  bool matches(Candidate c) =>
      memberName == c.memberName &&
      containerName == c.containerName &&
      libraryUri == c.libraryUri;
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

/// Splices [ranges] out of [text], back-to-front so earlier offsets hold.
String _stripRanges(String text, List<(int, int)> ranges) {
  final sorted = [...ranges]..sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end) in sorted) {
    out = out.substring(0, start) + out.substring(end);
  }
  return out;
}

List<int> _lineStarts(String content) {
  final starts = [0];
  for (var i = 0; i < content.length; i++) {
    if (content.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return starts;
}

final class _ShorthandIndex extends RecursiveAstVisitor<void> {
  final byOffset = <int, _ResolvedShorthand>{};

  void _add(int offset, String memberName, Element? element) {
    byOffset[offset] = _ResolvedShorthand(
      memberName,
      element?.enclosingElement?.displayName,
      element?.library?.uri.toString(),
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

final class _CandidateCollector extends RecursiveAstVisitor<void> {
  final candidates = <Candidate>[];

  /// [dotOffset] doubles as the exclusive end of the deleted prefix — the
  /// prefix ends exactly where its `.` begins.
  void _add({
    required AstNode node,
    required int deleteStart,
    required int dotOffset,
    required String owner,
    required String memberName,
    required Element? memberElement,
  }) {
    candidates.add(
      Candidate(
        groupKey:
            node.thisOrAncestorOfType<Statement>()?.offset ??
            node.thisOrAncestorOfType<Declaration>()?.offset ??
            -1,
        deleteStart: deleteStart,
        deleteEnd: dotOffset,
        shorthandOffset: dotOffset,
        display: '$owner.$memberName',
        memberName: memberName,
        containerName: memberElement?.enclosingElement?.displayName,
        libraryUri: memberElement?.library?.uri.toString(),
      ),
    );
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

  static bool _isStaticMember(Element? element) => switch (element) {
    ExecutableElement(:final isStatic) => isStatic,
    FieldElement(:final isStatic) => isStatic,
    _ => false,
  };

  /// `Foo.bar.baz` / `Foo.bar()` — the node is itself a receiver; `.bar.baz`
  /// is not a legal shorthand position.
  static bool _isReceiverPosition(Expression node) {
    final parent = node.parent;
    return (parent is PropertyAccess && identical(parent.target, node)) ||
        (parent is MethodInvocation && identical(parent.target, node));
  }
}

extension on NamedType {
  String get qualifiedName => importPrefix == null
      ? name.lexeme
      : '${importPrefix!.name.lexeme}.${name.lexeme}';
}
