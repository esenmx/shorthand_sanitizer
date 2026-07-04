import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
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
  });

  /// Start of the `Type` prefix to delete.
  final int deleteStart;

  /// End (exclusive) of the deleted prefix — the char before the `.`.
  final int deleteEnd;

  /// Offset of the `.` — where the shorthand node begins after the rewrite.
  final int shorthandOffset;

  /// `Type.member` as written, for reporting and skip-list matching.
  final String display;

  /// The accessed member (`all` in `Insets.all`).
  final String memberName;

  /// The declaring type's name — identity check anchor.
  final String? containerName;

  /// The declaring library's URI — identity check anchor.
  final String? libraryUri;
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
/// Dropping a `Type` prefix can leave the import that supplied `Type` with no
/// remaining referent. The final verified resolve is the oracle: any
/// `unused_import`/`unnecessary_import` it reports that the original file did
/// not is a self-inflicted orphan, and its directive is pruned. Imports the
/// file already left unused are the user's, not ours — they stay.
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

  static const _maxVerifyRounds = 10;

  /// Generated-code filter: the file's leading comment says so. Covers
  /// build_runner (`GENERATED CODE - DO NOT MODIFY BY HAND`), FlutterFire
  /// (`File generated by FlutterFire CLI`), pigeon (`Autogenerated`), protoc,
  /// slang — filename shape (`*.g.dart` vs a handwritten `*.preview.dart`)
  /// proves nothing, the header does.
  static bool isGenerated(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final raf = file.openSync();
    try {
      return _generatedMarker.hasMatch(
        .fromCharCodes(raf.readSync(300)),
      );
    } finally {
      raf.closeSync();
    }
  }

  static final _generatedMarker = RegExp(
    r'^\s*(//|#).*generat',
    caseSensitive: false,
    multiLine: true,
  );

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

    final collector = _CandidateCollector();
    original.unit.accept(collector);
    final candidates = <Candidate>[];
    for (final c in collector.candidates) {
      final member = c.memberName;
      if (skips.contains(c.display) || skips.contains(member)) {
        result.skippedByList++;
      } else {
        candidates.add(c);
      }
    }
    if (candidates.isEmpty) return null;

    final baseline = _errorKeys(original.diagnostics);
    // Imports already unused before we touched the file are the user's to
    // keep; only orphans we newly create get pruned.
    final baselineImports = _importIssueKeys(original.diagnostics);
    final content = original.content;

    // Element-mismatch failures are deterministic — banned for good. An
    // error-attributed failure can be collateral from a neighbor's revert
    // (`.all(1) + .only(2)`: reverting the context-less LHS makes the RHS
    // valid), so error failures with a nearby co-failure are re-tried — one
    // per round, since re-adding them together just reproduces the collision.
    var active = candidates;
    final retryQueue = <Candidate>[];
    Candidate? pendingRetry;
    (_Rewritten, List<Candidate>)? lastClean;
    // Directive ranges (in the clean rewrite's coordinates) to strip on write.
    var orphanCuts = const <(int, int)>[];

    for (
      var round = 0;
      round < _maxVerifyRounds && active.isNotEmpty;
      round++
    ) {
      final rewritten = _apply(content, active);
      overlay.setOverlay(
        file,
        content: rewritten.text,
        modificationStamp: round + 1,
      );
      context.changeFile(file);
      await context.applyPendingFileChanges();
      final check = await context.currentSession.getResolvedUnit(file);
      if (check is! ResolvedUnitResult) return null;

      final failed = _failedCandidates(check, rewritten, baseline);
      if (failed.mismatched.isEmpty && failed.errorAttributed.isEmpty) {
        lastClean = (rewritten, active);
        orphanCuts = _orphanRanges(check, baselineImports);
        if (retryQueue.isEmpty) break;
        pendingRetry = retryQueue.removeAt(0);
        active = [...active, pendingRetry]
          ..sort((a, b) => a.deleteStart.compareTo(b.deleteStart));
        continue;
      }
      final dead = {...failed.mismatched, ...failed.errorAttributed};
      for (final c in failed.errorAttributed) {
        // Collateral suspect: failed next to another failure, and not already
        // a failed retry (a retry that fails again is genuinely invalid).
        if (!identical(c, pendingRetry) &&
            dead.any(
              (o) =>
                  !identical(o, c) &&
                  (o.deleteStart - c.deleteStart).abs() <= 120,
            )) {
          retryQueue.add(c);
        }
      }
      pendingRetry = null;
      active = [
        for (final c in active)
          if (!dead.contains(c)) c,
      ];
    }

    overlay.removeOverlay(file);
    context.changeFile(file);
    await context.applyPendingFileChanges();
    if (lastClean == null) return null; // nothing verifiable — file untouched

    final (rewritten, converted) = lastClean;
    if (!dryRun) {
      final text = orphanCuts.isEmpty
          ? rewritten.text
          : _stripRanges(rewritten.text, orphanCuts);
      File(file).writeAsStringSync(text);
    }
    final lines = _lineStarts(content);
    return FileResult(
      file,
      [
        for (final c in converted)
          '${_lineOf(lines, c.deleteStart)}: ${c.display} -> .${c.memberName}',
      ],
      candidates.length - converted.length,
      removedImports: orphanCuts.length,
    );
  }

  /// Splits failed candidates by fate. `mismatched` — the shorthand resolved
  /// to a *different* element: deterministic rebind, never retry.
  /// `errorAttributed`
  /// — node missing/unresolved or nearest to a new diagnostic: possibly
  /// collateral from a neighbor, worth one retry.
  ({Set<Candidate> mismatched, Set<Candidate> errorAttributed})
  _failedCandidates(
    ResolvedUnitResult check,
    _Rewritten rewritten,
    Set<String> baseline,
  ) {
    final mismatched = <Candidate>{};
    final errorAttributed = <Candidate>{};
    final shorthands = _ShorthandIndex();
    check.unit.accept(shorthands);

    for (final entry in rewritten.newOffsets.entries) {
      final resolved = shorthands.byOffset[entry.value];
      if (resolved == null || resolved.libraryUri == null) {
        errorAttributed.add(entry.key);
      } else if (resolved.memberName != entry.key.memberName ||
          resolved.containerName != entry.key.containerName ||
          resolved.libraryUri != entry.key.libraryUri) {
        mismatched.add(entry.key);
      }
    }

    for (final diagnostic in check.diagnostics) {
      if (diagnostic.severity != .error) continue;
      if (baseline.contains(_errorKey(diagnostic))) continue;
      errorAttributed.add(_nearest(rewritten.newOffsets, diagnostic.offset));
    }
    errorAttributed.removeAll(mismatched);
    return (mismatched: mismatched, errorAttributed: errorAttributed);
  }

  Candidate _nearest(Map<Candidate, int> offsets, int errorOffset) {
    late Candidate best;
    var bestDistance = 1 << 40;
    for (final entry in offsets.entries) {
      final distance = (entry.value - errorOffset).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry.key;
      }
    }
    return best;
  }

  _Rewritten _apply(String content, List<Candidate> candidates) {
    final sorted = [...candidates]
      ..sort((a, b) => a.deleteStart.compareTo(b.deleteStart));
    final buffer = StringBuffer();
    final newOffsets = <Candidate, int>{};
    var cursor = 0;
    var shift = 0;
    for (final c in sorted) {
      buffer.write(content.substring(cursor, c.deleteStart));
      shift += c.deleteEnd - c.deleteStart;
      newOffsets[c] = c.shorthandOffset - shift;
      cursor = c.deleteEnd;
    }
    buffer.write(content.substring(cursor));
    return _Rewritten(buffer.toString(), newOffsets);
  }

  static Set<String> _errorKeys(List<Diagnostic> diagnostics) => {
    for (final d in diagnostics)
      if (d.severity == .error) _errorKey(d),
  };

  /// Offsets shift across rewrites — key errors by code + message instead.
  static String _errorKey(Diagnostic d) =>
      '${d.diagnosticCode.lowerCaseName}:${d.message}';

  /// Import-scoped diagnostics whose fix is to drop the whole directive.
  static const _removableImportCodes = {
    'unused_import',
    'unnecessary_import',
    'duplicate_import',
  };

  static Set<String> _importIssueKeys(List<Diagnostic> diagnostics) => {
    for (final d in diagnostics)
      if (_removableImportCodes.contains(d.diagnosticCode.lowerCaseName))
        _errorKey(d),
  };

  /// Directive ranges (each spanning `import … ;` plus its line ending) for
  /// imports the rewrite orphaned — those [check] now flags removable that
  /// weren't in [baseline]. Coordinates are [check]'s content, i.e. the
  /// rewritten text about to be written.
  static List<(int, int)> _orphanRanges(
    ResolvedUnitResult check,
    Set<String> baseline,
  ) {
    final text = check.content;
    final imports = [
      for (final directive in check.unit.directives)
        if (directive is ImportDirective) directive,
    ];
    if (imports.isEmpty) return const [];

    final seen = <int>{};
    final ranges = <(int, int)>[];
    for (final d in check.diagnostics) {
      if (!_removableImportCodes.contains(d.diagnosticCode.lowerCaseName)) {
        continue;
      }
      if (baseline.contains(_errorKey(d))) continue;
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
  static String _stripRanges(String text, List<(int, int)> ranges) {
    final sorted = [...ranges]..sort((a, b) => b.$1.compareTo(a.$1));
    var out = text;
    for (final (start, end) in sorted) {
      out = out.substring(0, start) + out.substring(end);
    }
    return out;
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

  static List<int> _lineStarts(String content) {
    final starts = [0];
    for (var i = 0; i < content.length; i++) {
      if (content.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }

  static int _lineOf(List<int> lineStarts, int offset) {
    var low = 0;
    var high = lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }
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

  void _add({
    required int deleteStart,
    required int deleteEnd,
    required int dotOffset,
    required String display,
    required String memberName,
    required Element? memberElement,
  }) {
    candidates.add(
      Candidate(
        deleteStart: deleteStart,
        deleteEnd: deleteEnd,
        shorthandOffset: dotOffset,
        display: display,
        memberName: memberName,
        containerName: memberElement?.enclosingElement?.displayName,
        libraryUri: memberElement?.library?.uri.toString(),
      ),
    );
  }

  /// `Enum.value`, `Type.staticGetterOrField`.
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final interface = _getTargetInterface(node.prefix);
    if (interface != null) {
      final member = node.identifier.element;
      if (_isStaticMember(member) && !_isReceiverPosition(node)) {
        _add(
          deleteStart: node.prefix.offset,
          deleteEnd: node.period.offset,
          dotOffset: node.period.offset,
          display: '${node.prefix.name}.${node.identifier.name}',
          memberName: node.identifier.name,
          memberElement: member,
        );
      }
    }
    super.visitPrefixedIdentifier(node);
  }

  /// `prefix.Type.staticGetterOrField`.
  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    if (target != null) {
      final interface = _getTargetInterface(target);
      if (interface != null) {
        final member = node.propertyName.element;
        if (_isStaticMember(member) && !_isReceiverPosition(node)) {
          _add(
            deleteStart: target.offset,
            deleteEnd: node.operator.offset,
            dotOffset: node.operator.offset,
            display: '${target.toSource()}.${node.propertyName.name}',
            memberName: node.propertyName.name,
            memberElement: member,
          );
        }
      }
    }
    super.visitPropertyAccess(node);
  }

  /// `Type.staticMethod(...)` or `prefix.Type.staticMethod(...)`.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target != null) {
      final interface = _getTargetInterface(target);
      if (interface != null &&
          node.typeArguments == null &&
          _isStaticMember(node.methodName.element)) {
        final dot = node.operator;
        if (dot != null) {
          _add(
            deleteStart: target.offset,
            deleteEnd: dot.offset,
            dotOffset: dot.offset,
            display: '${target.toSource()}.${node.methodName.name}',
            memberName: node.methodName.name,
            memberElement: node.methodName.element,
          );
        }
      }
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
        deleteStart: node.constructorName.offset,
        deleteEnd: name.offset - 1, // the `.` sits right before the name
        dotOffset: name.offset - 1,
        display: '${type.qualifiedName}.${name.name}',
        memberName: name.name,
        memberElement: node.constructorName.element,
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  static InterfaceElement? _getInterfaceElement(Element? element) {
    if (element is InterfaceElement) return element;
    if (element is TypeAliasElement) {
      final aliasedType = element.aliasedType;
      if (aliasedType is InterfaceType) {
        return aliasedType.element;
      }
    }
    return null;
  }

  static InterfaceElement? _getTargetInterface(Expression? target) {
    if (target is Identifier) {
      return _getInterfaceElement(target.element);
    }
    return null;
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
