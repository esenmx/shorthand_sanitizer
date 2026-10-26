import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart' hide FileResult;
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

part 'generated.dart';
part 'imports.dart';
part 'models.dart';
part 'sdk.dart';
part 'verifier.dart';
part 'viability.dart';
part 'workspace.dart';

/// Rewrites `Type.member` to dot-shorthand `.member` (enum values, static
/// getters/fields/methods, and named — incl. factory/const — constructors) at
/// every site where the rewrite provably resolves to the SAME element with the
/// SAME static type.
///
/// Strategy per library: filter out sites that cannot verify statically,
/// rewrite every remaining candidate across all in-scope units of the library,
/// resolve the rewritten library once, then keep only candidates whose
/// shorthand node resolved back to the original element with the same static
/// type, no new use-restricting annotations (`@useResult`, `@Deprecated`,
/// `@visibleForTesting`, `@internal`, `@protected`, etc.), and no new
/// diagnostics in the library. Anything else — unwitnessed context (`Object`,
/// generics), typedefs fixing type arguments (`typedef IntG = G<int>`),
/// members living on a sibling namespace (`Colors.red` in a `Color` slot),
/// silent rebinds to a same-named static — is reverted.
///
/// Two cross-type rebinds are licensed, both observably no-ops when they land
/// in a typed slot of the target type (`_Viability.typedSlotOf`) and add no
/// disallowed restriction:
/// - a `static const` alias of the original
///   (`AlignmentGeometry.topCenter = Alignment.topCenter`) — a different
///   element holding the identical canonicalized constant. Const-value
///   identity, not element identity, decides.
/// - a redirecting factory whose chain ends at the original constructor with
///   compatible formal parameters (`const factory EdgeInsetsGeometry.all(double
///   value) = EdgeInsets.all`) — the language forwards the arguments
///   untouched, so `.all(8)` in an `EdgeInsetsGeometry` slot constructs the
///   very `EdgeInsets` the prefix did.
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

  /// Only process `.dart` files with uncommitted changes in git (modified,
  /// staged, or untracked).
  final bool changed = false,

  /// Only process `.dart` files changed in git since this revision (including
  /// uncommitted changes).
  final String? since,
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

  /// Generated-code filter: the file's leading comment says so (build_runner,
  /// FlutterFire, pigeon, protoc, slang).
  static bool isGenerated(String path) => _isGeneratedFile(path);

  /// Sanitizes every non-generated `.dart` file under [paths]
  /// (files or directories).
  ///
  /// Throws an [ArgumentError] when a path does not exist or is neither a
  /// directory nor a `.dart` file, or when [since] is not a valid git
  /// revision; a [StateError] when no Dart SDK is found (see [sdkPath]) or
  /// when [changed] or [since] is used outside a git repository.
  Future<SanitizeResult> run(List<String> paths) {
    for (final path in paths) {
      if (switch (FileSystemEntity.typeSync(path)) {
            .directory => null,
            .file when path.endsWith('.dart') => null,
            .notFound => 'no such file or directory',
            _ => 'not a directory or a .dart file',
          }
          case final problem?) {
        throw ArgumentError.value(path, 'paths', problem);
      }
    }
    _realCache.clear();
    final sdk = sdkPath();
    if (sdk == null) {
      throw StateError(switch (Platform.environment['DART_SDK']) {
        final env? => 'DART_SDK is set to $env, which is not a Dart SDK',
        null => 'could not locate the Dart SDK: set DART_SDK to its directory',
      });
    }
    final gitRealPaths = (changed || since != null)
        ? _discoverGitChangedFiles(paths: paths, since: since)
        : null;
    return _run(paths, sdk, gitRealPaths);
  }

  Future<SanitizeResult> _run(
    List<String> paths,
    String sdk,
    Set<String>? gitRealPaths,
  ) async {
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
    final collected = _collectFiles(
      paths,
      excludedBy,
      result,
      skipGenerated: skipGenerated,
      gitRealPaths: gitRealPaths,
    );
    final matchedSkips = <String>{};
    try {
      if (collected.isEmpty) return result;
      await _runOn(
        collected,
        paths,
        sdk,
        excludedBy,
        result,
        matchedSkips,
        gitFiltered: gitRealPaths != null,
      );
      return result;
    } finally {
      if (gitRealPaths == null) {
        result.unmatchedSkips.addAll(skips.difference(matchedSkips));
        result.unmatchedExcludes.addAll(
          excludes.where((e) => !matchedGlobs.contains(e)),
        );
      }
    }
  }

  Future<void> _runOn(
    List<String> collected,
    List<String> paths,
    String sdk,
    String? Function(String path) excludedBy,
    SanitizeResult result,
    Set<String> matchedSkips, {
    required bool gitFiltered,
  }) async {
    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    final gate = _PackageGate();
    final packageRoots = {for (final f in collected) ?gate.rootOf(f)};
    final roots = {...paths.map(_canonical), ...packageRoots};
    final byteStore = _createByteStore();
    final tempRoot = _canonical(Directory.systemTemp.path);
    final tempReal = _real(tempRoot);
    final ephemeral = collected.every(
      (f) => p.isWithin(tempRoot, f) || p.isWithin(tempReal, _real(f)),
    );
    byteStore.speculative = ephemeral;
    final collection = AnalysisContextCollectionImpl(
      includedPaths: [
        for (final root in roots)
          if (packageRoots.contains(root) ||
              !roots.any((other) => p.isWithin(other, root)))
            root,
      ],
      resourceProvider: overlay,
      sdkPath: sdk,
      byteStore: byteStore,
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
      AnalysisContext? contextOfOrNull(String file) {
        for (final c in contexts) {
          if (c.contextRoot.root.isOrContains(file) ||
              c.contextRoot.root.isOrContains(_real(file))) {
            return c;
          }
        }
        return null;
      }

      AnalysisContext contextOf(String file) =>
          contextOfOrNull(file) ??
          (throw StateError('no analysis context for $file'));

      String? analyzerExcluded(String file) {
        if (!analyzerExcludes) return null;
        final context = contextOfOrNull(file);
        if (context == null) return null;
        final root = context.contextRoot;
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

      final realToScope = {for (final f in files) _real(f): f};
      final canonicalRoots = paths.map(_canonical).toList();
      bool withinGivenPaths(String path) {
        final canon = _canonical(path);
        final resolved = _real(canon);
        for (final root in canonicalRoots) {
          if (p.equals(root, canon) ||
              p.isWithin(root, canon) ||
              p.equals(_real(root), resolved) ||
              p.isWithin(_real(root), resolved)) {
            return true;
          }
        }
        return false;
      }

      String? offLimits(String path) => switch (path) {
        _ when realToScope.containsKey(_real(path)) => null,
        _ when excludedBy(path) != null => 'excluded',
        _ when analyzerExcluded(path) != null => 'excluded',
        _ when skipGenerated && isGenerated(path) => 'generated',
        _ when gitFiltered && withinGivenPaths(path) => null,
        _ => 'not among the given paths',
      };

      String scopePathOf(String unitPath) =>
          realToScope[_real(unitPath)] ?? _canonical(unitPath);

      final verified = <String, String>{};
      final byPath = <String, FileResult>{};
      final visitedReal = <String>{};

      for (final file in files) {
        final fileReal = _real(file);
        if (visitedReal.contains(fileReal)) continue;

        final context = contextOf(file);
        final root = gate.rootOf(file);
        if (root != null && !await gate.isConfigured(context, file, root)) {
          visitedReal.add(fileReal);
          result.skippedUnconfigured.update(
            root,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
          continue;
        }

        final library = await context.currentSession
            .getResolvedLibraryContaining(file);
        if (library is NotLibraryButPartResult) {
          visitedReal.add(fileReal);
          result.skippedOrphanParts.add(file);
          continue;
        }
        if (library is! ResolvedLibraryResult) {
          throw StateError('could not resolve $file: ${library.runtimeType}');
        }

        final inScopeUnits = <({String scopePath, ResolvedUnitResult unit})>[];
        for (final u in library.units) {
          final fReal = _real(u.path);
          if (realToScope[fReal] case final f?) {
            final fRoot = gate.rootOf(f);
            if (fRoot != null &&
                !await gate.isConfigured(contextOf(f), f, fRoot)) {
              visitedReal.add(fReal);
              result.skippedUnconfigured.update(
                fRoot,
                (n) => n + 1,
                ifAbsent: () => 1,
              );
              continue;
            }
            visitedReal.add(fReal);
            inScopeUnits.add((scopePath: f, unit: u));
          }
        }
        inScopeUnits.sort((a, b) => a.scopePath.compareTo(b.scopePath));
        if (inScopeUnits.isEmpty) continue;

        final language = library.element.languageVersion.effective;
        if (language.major < _floorMajor ||
            (language.major == _floorMajor && language.minor < _floorMinor)) {
          for (final (:scopePath, unit: _) in inScopeUnits) {
            final uRoot = gate.rootOf(scopePath);
            result.skippedBelowFloor.update(
              (
                root: uRoot ?? p.dirname(scopePath),
                version: '${language.major}.${language.minor}',
              ),
              (n) => n + 1,
              ifAbsent: () => 1,
            );
          }
          continue;
        }

        if (!allowErrors &&
            library.units.any(
              (u) => u.diagnostics.any((d) => d.severity == .error),
            )) {
          for (final (:scopePath, unit: _) in inScopeUnits) {
            result.skippedWithErrors.add(scopePath);
          }
          continue;
        }

        final unitPlans = [
          for (final (:scopePath, :unit) in inScopeUnits)
            _planUnit(scopePath, unit, result, matchedSkips),
        ];
        final totalCandidates = unitPlans.fold(
          0,
          (n, p) => n + p.candidates.length,
        );

        final List<FileResult> batchResults;
        if (totalCandidates == 0) {
          batchResults = [
            if (explain)
              for (final plan in unitPlans)
                if (plan.kept case final kept? when kept.isNotEmpty)
                  .new(
                    plan.scopePath,
                    _keptSites(plan.original.lineInfo.getLocation, kept),
                    plan.unviable,
                  ),
          ];
        } else {
          byteStore.speculative = true;
          try {
            batchResults = await _LibrarySanitizer(
              context: context,
              overlay: overlay,
              library: library,
              unitPlans: unitPlans,
              dryRun: dryRun,
              verified: verified,
              offLimits: offLimits,
              result: result,
              packageRootOf: gate.rootOf,
              scopePathOf: scopePathOf,
            ).run();
          } finally {
            byteStore.speculative = ephemeral;
          }
        }

        for (final r in batchResults) {
          byPath.update(
            r.path,
            (prior) => .new(
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
      byteStore.speculative = false;
      await collection.dispose();
    }
  }

  _UnitPlan _planUnit(
    String scopePath,
    ResolvedUnitResult unit,
    SanitizeResult result,
    Set<String> matchedSkips,
  ) {
    final collector = _CandidateCollector(
      typeProvider: unit.typeProvider,
      selfUri: unit.libraryElement.uri,
      unitPath: unit.path,
      scopePath: scopePath,
    );
    unit.unit.accept(collector);
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
    candidates.sort(_byOffset);
    return .new(
      scopePath: scopePath,
      unitPath: unit.path,
      original: unit,
      candidates: candidates,
      unviable: collector.unviable.length,
      kept: explain ? kept : null,
    );
  }

  bool _isSkipped(_Candidate c) => _skipsMatching((
    display: c.display,
    memberName: c.memberName,
    containerName: c.containerName,
  )).isNotEmpty;

  Iterable<String> _skipsMatching(_SiteName site) => [
    site.display,
    site.memberName,
    if (site.containerName case final container?)
      '$container.${site.memberName}',
  ].where(skips.contains);
}
