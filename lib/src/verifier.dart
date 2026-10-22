part of 'sanitizer.dart';

/// Fallback reason for a candidate that only ever failed as part of a set.
const _unverified = 'not verifiable alongside the other rewrites';

/// Overlay modification stamps, rising across every file of every run: a
/// path overlaid by one file and restored by another never repeats a stamp.
var _stamp = 0;

/// The verify-and-narrow pipeline for a whole library batch: apply every
/// candidate across all in-scope units of [library] at once, read the verdict
/// off the single rewritten resolve, drop what it convicts, then re-offer what
/// a broken neighbour may merely have starved.
final class _LibrarySanitizer({
  required final AnalysisContext context,
  required final OverlayResourceProvider overlay,
  required final ResolvedLibraryResult library,
  required final List<_UnitPlan> unitPlans,
  required final bool dryRun,
  required final Map<String, String> verified,
  required final String? Function(String path) offLimits,
  required final SanitizeResult result,
  required final String? Function(String path) packageRootOf,
  required final String Function(String unitPath) scopePathOf,
}) {
  /// Every diagnostic of [library] before the rewrite, counted per key. A
  /// rewrite may add none.
  final Map<_DiagKey, int> baseline = _census(library);

  /// Imports already unused (or unnecessary) before the rewrite: the user's
  /// to keep, so only orphans the rewrite newly creates get pruned.
  final Set<_ImportIssue> _userImportIssues = _importIssuesOf(library);
  final _constCache = <(String, String, String), DartObject?>{};

  final List<_Candidate> allCandidates = [
    for (final plan in unitPlans) ...plan.candidates,
  ]..sort(_byOffset);

  /// Candidates still in the running; once [_clean] is set, exactly the ones
  /// it converts.
  List<_Candidate> _active = [for (final plan in unitPlans) ...plan.candidates]
    ..sort(_byOffset);
  final _dropped = <_Candidate>[];
  _LibraryRewritten? _clean;
  ResolvedLibraryResult? _cleanLibrary;

  /// The latest verdict's reason for each refused candidate.
  final _why = <_Candidate, String>{};

  /// Directive edits to apply on write, per unit path of [library].
  var _orphanCuts = const <String, List<_DirectiveCut>>{};

  final _overlaid = <String, String>{};

  Future<List<FileResult>> run() async {
    Map<String, String>? texts;
    try {
      if (await _converge()) await _recover();
      texts = await _finalize();
      // Written while the overlays still hold the same text: removing them
      // first would have the analyzer re-read the pre-write disk.
      if (texts != null && !dryRun) {
        final failure = _unwritable(texts.keys) ?? _writeAll(texts);
        if (failure case (:final path, :final error)) {
          final failScope = scopePathOf(path);
          final authorFiles = {
            for (final c in _active) c.scopePath,
            if (_active.isEmpty) ?unitPlans.firstOrNull?.scopePath,
          };
          for (final authorFile
              in authorFiles.isEmpty ? [failScope] : authorFiles) {
            result.writeFailures.add((
              file: authorFile,
              path: failScope,
              error: error,
            ));
          }
          _refuseAllForPath(failScope, error);
          texts = null;
        }
      }
    } finally {
      // Unconditional: an overlay holds speculative text, so bailing out with
      // it still installed leaks an unverified rewrite into every file
      // resolved after it in the same context. Verified texts stay in the
      // overlay so later libraries reuse the warm session.
      var changed = false;
      for (final MapEntry(key: path, value: currentOverlay)
          in _overlaid.entries) {
        if (texts?[path] case final text?) verified[path] = text;
        if (verified[path] case final text?) {
          if (currentOverlay != text) {
            overlay.setOverlay(
              path,
              content: text,
              modificationStamp: ++_stamp,
            );
            context.changeFile(path);
            changed = true;
          }
        } else {
          overlay.removeOverlay(path);
          context.changeFile(path);
          changed = true;
        }
      }
      if (changed) await context.applyPendingFileChanges();
    }

    final converted = texts == null ? const <_Candidate>[] : _active;
    final cuts = texts == null
        ? const <String, List<_DirectiveCut>>{}
        : _orphanCuts;
    final done = converted.toSet();

    final withSites = <FileResult>[];
    final pruneOnly = <FileResult>[];
    final planByUnit = {for (final p in unitPlans) p.unitPath: p};

    for (final plan in unitPlans) {
      final unitConverted = [
        for (final c in converted)
          if (c.unitPath == plan.unitPath) c,
      ];
      final edits = [
        for (final c in unitConverted)
          (
            start: c.deleteStart,
            end: c.deleteEnd,
            length: c.replacement.length,
          ),
      ];
      final locate = plan.original.lineInfo.getLocation;
      final unitKept = switch (plan.kept) {
        null => null,
        final kept => [
          ...kept,
          for (final c in plan.candidates)
            if (!done.contains(c))
              (
                offset: c.deleteStart,
                display: c.display,
                reason: _why[c] ?? _unverified,
              ),
        ],
      };
      final sites = [
        for (final c in unitConverted)
          _siteAt(locate, c.deleteStart, c.display, after: '.${c.memberName}'),
        if (unitKept != null) ..._keptSites(locate, unitKept),
      ];
      final unitPruned = [
        for (final cut in cuts[plan.unitPath] ?? const <_DirectiveCut>[])
          cut.info(locate(_unapply(edits, cut.keyword)).lineNumber),
      ];
      final revertedCount =
          plan.candidates.where((c) => !done.contains(c)).length +
          plan.unviable;
      if (sites.isNotEmpty || plan.kept != null && unitPruned.isNotEmpty) {
        withSites.add(
          .new(plan.scopePath, sites, revertedCount, prunedImports: unitPruned),
        );
      } else if (unitPruned.isNotEmpty) {
        pruneOnly.add(
          .new(plan.scopePath, const [], 0, prunedImports: unitPruned),
        );
      }
    }

    for (final unit in library.units) {
      if (planByUnit.containsKey(unit.path)) continue;
      if (cuts[unit.path] case final pruned? when pruned.isNotEmpty) {
        final reported = [
          for (final cut in pruned)
            cut.info(unit.lineInfo.getLocation(cut.keyword).lineNumber),
        ];
        pruneOnly.add(
          .new(scopePathOf(unit.path), const [], 0, prunedImports: reported),
        );
      }
    }

    return [...withSites, ...pruneOnly];
  }

  /// Narrows [_active] to a set that verifies clean, if one exists. Returns
  /// false when the speculative text stopped resolving at all.
  Future<bool> _converge() async {
    while (_active.isNotEmpty) {
      final a = await _attempt(_active);
      if (a == null) return false;
      if (a.isClean) {
        _accept(a);
        return true;
      }
      if (a.culprits.isNotEmpty) {
        final groupCounts = <(String, int), int>{};
        for (final c in _active) {
          groupCounts.update(c.groupKey, (n) => n + 1, ifAbsent: () => 1);
        }
        for (final c in a.culprits) {
          if ((groupCounts[c.groupKey] ?? 0) > 1) _dropped.add(c);
        }
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

  /// Largest subset of [set] that verifies clean.
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
  /// type. Candidates under different [_Candidate.groupKey]s cannot interact,
  /// so a whole wave across all units of the library is judged at once.
  Future<void> _recover() async {
    var pending = _dropped;
    while (pending.isNotEmpty) {
      final seen = <(String, int)>{};
      final wave = <_Candidate>[];
      final rest = <_Candidate>[];
      for (final c in pending) {
        (seen.add(c.groupKey) ? wave : rest).add(c);
      }
      pending = rest;
      if (_active.length + wave.length == allCandidates.length) continue;

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
  /// pruned library gains any diagnostic, nothing converts.
  Future<Map<String, String>?> _finalize() async {
    if (!await _dropOffLimitsOrphans()) return null;
    final clean = _clean;
    if (clean == null || _active.isEmpty) return null;
    final activeUnits = {for (final c in _active) c.unitPath};
    final texts = {
      for (final MapEntry(key: path, value: text) in clean.texts.entries)
        if (activeUnits.contains(path)) path: text,
    };
    if (_orphanCuts.isEmpty) return texts;

    for (final MapEntry(key: path, value: cuts) in _orphanCuts.entries) {
      final base =
          texts[path] ??
          clean.texts[path] ??
          library.unitWithPath(path)?.content;
      if (base != null) texts[path] = _stripRanges(base, cuts);
    }
    for (final plan in unitPlans) {
      final path = plan.unitPath;
      _overlay(
        path,
        texts[path] ?? clean.texts[path] ?? plan.original.content,
        plan.original.content,
      );
    }
    for (final MapEntry(key: path, value: text) in texts.entries) {
      if (!unitPlans.any((p) => p.unitPath == path)) {
        _overlay(path, text, library.unitWithPath(path)?.content);
      }
    }
    await context.applyPendingFileChanges();
    final check = await context.currentSession.getResolvedLibraryContaining(
      unitPlans.first.unitPath,
    );
    final stray = check is ResolvedLibraryResult
        ? _firstNew(check, (_, _) => false)
        : null;
    if (check is ResolvedLibraryResult && stray == null) return texts;

    final leaves = stray == null ? 'an unresolvable library' : _describe(stray);
    _refuseAll('pruning its orphaned imports leaves $leaves');
    return null;
  }

  /// Drops candidates whose conversion orphans an import in an [offLimits]
  /// unit, re-verifying the remaining set. Returns false when no convertible
  /// subset remains.
  Future<bool> _dropOffLimitsOrphans() async {
    while (_clean != null && _active.isNotEmpty && _orphanCuts.isNotEmpty) {
      var retried = false;
      for (final path in _orphanCuts.keys) {
        if (offLimits(path) case final why?) {
          final offenders = _offLimitsOffenders(
            _cleanLibrary?.unitWithPath(path),
          );
          String reasonFor(_Candidate c) {
            final shown = p.relative(
              scopePathOf(path),
              from: p.dirname(c.scopePath),
            );
            return 'pruning its orphaned imports would edit $shown, '
                'which is $why';
          }

          if (offenders.isEmpty || offenders.length == _active.length) {
            for (final c in _active) {
              _why[c] = reasonFor(c);
            }
            _active = [];
            return false;
          }
          for (final c in offenders) {
            _why[c] = reasonFor(c);
          }
          _active = [
            for (final c in _active)
              if (!offenders.contains(c)) c,
          ];
          final retry = await _attempt(_active);
          if (retry == null || !retry.isClean) {
            for (final c in _active) {
              _why[c] = reasonFor(c);
            }
            _active = [];
            return false;
          }
          _accept(retry);
          retried = true;
          break;
        }
      }
      if (!retried) return true;
    }
    return _clean != null && _active.isNotEmpty;
  }

  Set<_Candidate> _offLimitsOffenders(ResolvedUnitResult? checkUnit) {
    if (checkUnit == null) return const {};
    const shownPrefix = '$_unusedShownNameCode:';
    final offenders = <_Candidate>{};
    for (final d in checkUnit.diagnostics) {
      if (_importIssueOf(checkUnit, d) case (_, final idx, final code)
          when !_userImportIssues.contains((checkUnit.path, idx, code))) {
        final directive = checkUnit.unit.directives[idx];
        if (directive is! ImportDirective) continue;
        final shownName = code.startsWith(shownPrefix)
            ? code.substring(shownPrefix.length)
            : null;
        final expectedOwner = switch ((shownName, directive.prefix)) {
          (final name?, final prefix?) => '${prefix.name}.$name',
          (final name?, null) => name,
          (null, _) => null,
        };
        for (final c in _active) {
          if (expectedOwner != null && c.owner != expectedOwner) continue;
          if (directive.libraryImport?.namespace.get2(c.owner) != null) {
            offenders.add(c);
          }
        }
      }
    }
    return offenders;
  }

  void _refuseAll(String reason) {
    for (final c in _active) {
      _why[c] = reason;
    }
    _active = [];
  }

  void _refuseAllForPath(String failedPath, String error) {
    for (final c in _active) {
      final shown = p.relative(failedPath, from: p.dirname(c.scopePath));
      _why[c] = 'cannot write $shown: $error';
    }
    _active = [];
  }

  void _overlay(String path, String text, [String? originalContent]) {
    final current = _overlaid[path] ?? originalContent;
    if (current == text) return;
    overlay.setOverlay(path, content: text, modificationStamp: ++_stamp);
    _overlaid[path] = text;
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

  /// Rewrites all units in [unitPlans] with [set] applied and resolves the
  /// library once.
  Future<_Attempt?> _attempt(List<_Candidate> set) async {
    final rewritten = _apply(set);
    for (final plan in unitPlans) {
      _overlay(
        plan.unitPath,
        rewritten.texts[plan.unitPath] ?? plan.original.content,
        plan.original.content,
      );
    }
    await context.applyPendingFileChanges();
    final check = await context.currentSession.getResolvedLibraryContaining(
      unitPlans.first.unitPath,
    );
    if (check is! ResolvedLibraryResult) return null;
    return await _verdict(rewritten, check);
  }

  _LibraryRewritten _apply(List<_Candidate> set) {
    final byUnit = <String, List<_Candidate>>{};
    for (final c in set) {
      (byUnit[c.unitPath] ??= []).add(c);
    }
    final texts = <String, String>{};
    final newOffsets = <_Candidate, int>{};
    for (final plan in unitPlans) {
      final unitSet = byUnit[plan.unitPath];
      final content = plan.original.content;
      if (unitSet == null || unitSet.isEmpty) {
        texts[plan.unitPath] = content;
        continue;
      }
      unitSet.sort(_byOffset);
      final buffer = StringBuffer();
      var cursor = 0;
      var delta = 0;
      for (final c in unitSet) {
        buffer
          ..write(content.substring(cursor, c.deleteStart))
          ..write(c.replacement);
        newOffsets[c] = c.deleteStart + delta;
        delta += c.replacement.length - (c.deleteEnd - c.deleteStart);
        cursor = c.deleteEnd;
      }
      buffer.write(content.substring(cursor));
      texts[plan.unitPath] = buffer.toString();
    }
    return .new(texts, newOffsets);
  }

  /// Node-level verdict on an applied set across all units in [unitPlans].
  Future<_Attempt> _verdict(
    _LibraryRewritten rewritten,
    ResolvedLibraryResult checkLib,
  ) async {
    final activeUnitPaths = {
      for (final c in rewritten.newOffsets.keys) c.unitPath,
    };
    final indices = <String, _ShorthandIndex>{};
    final unitsByPath = <String, ResolvedUnitResult>{};
    for (final unitPath in activeUnitPaths) {
      final unit = checkLib.unitWithPath(unitPath);
      if (unit != null) {
        unitsByPath[unitPath] = unit;
        final idx = _ShorthandIndex();
        unit.unit.accept(idx);
        indices[unitPath] = idx;
      }
    }
    final selfUri = checkLib.element.uri.toString();

    final culprits = <_Candidate>{};
    for (final MapEntry(key: candidate, value: offset)
        in rewritten.newOffsets.entries) {
      final checkUnit = unitsByPath[candidate.unitPath];
      final shorthands = indices[candidate.unitPath];
      if (checkUnit == null || shorthands == null) {
        culprits.add(candidate);
        continue;
      }
      final resolved = shorthands.byOffset[offset];
      if (resolved == null || resolved.libraryUri == null) {
        culprits.add(candidate);
        _why[candidate] =
            _errorOn(checkUnit, offset, candidate.memberName) ??
            'the shorthand does not resolve';
      } else if (resolved.useResult) {
        culprits.add(candidate);
        _why[candidate] =
            'resolves to a @useResult member, whose shorthand dart analyze '
            'reports as unused';
      } else if (resolved.matches(candidate)) {
        if (resolved.staticType != candidate.staticType) {
          culprits.add(candidate);
          final to = resolved.shownType == candidate.shownType
              ? 'a different ${resolved.shownType}'
              : resolved.shownType;
          _why[candidate] =
              'changes the static type from ${candidate.shownType} to $to';
        } else if (candidate.typeArgTypes != null &&
            resolved.typeArgTypes != null &&
            resolved.typeArgTypes != candidate.typeArgTypes) {
          culprits.add(candidate);
          _why[candidate] = 'pruning type arguments changes the inferred type';
        }
      } else {
        final target = [?resolved.containerName, resolved.memberName].join('.');
        final typeArgsMatch =
            candidate.typeArgTypes == null ||
            resolved.typeArgTypes == null ||
            resolved.typeArgTypes == candidate.typeArgTypes;
        final licensed =
            typeArgsMatch &&
            (resolved.forwardsTo(candidate) ||
                await _isConstAlias(
                  candidate,
                  resolved,
                  selfUri,
                  candidate.unitPath,
                ));
        final inSlot =
            candidate.typedSlot != null &&
            candidate.typedSlot == resolved.staticType;
        final gained = resolved.restrictions
            .difference(candidate.restrictions)
            .where((r) => !_mayUse(r, resolved, selfUri, candidate.scopePath))
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

    final stray = culprits.isEmpty
        ? _firstNew(checkLib, (_, d) => _isExcusedImportDiagnostic(d))
        : null;
    return .new(
      rewritten,
      checkLib,
      culprits,
      stray: stray == null ? null : _describe(stray),
    );
  }

  Diagnostic? _firstNew(
    ResolvedLibraryResult lib,
    bool Function(String path, Diagnostic d) excused,
  ) {
    final seen = <_DiagKey, int>{};
    final inScopePaths = {for (final p in unitPlans) p.unitPath};
    for (final unit in [
      ...lib.units.where((u) => inScopePaths.contains(u.path)),
      ...lib.units.where((u) => !inScopePaths.contains(u.path)),
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

  bool _mayUse(
    String annotation,
    _ResolvedShorthand target,
    String selfUri,
    String file,
  ) {
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
                _mayUse('@visibleForTesting', target, selfUri, file)),
      '@visibleForOverriding' => target.libraryUri == selfUri,
      _ => false,
    };
  }

  Future<bool> _isConstAlias(
    _Candidate candidate,
    _ResolvedShorthand resolved,
    String selfUri,
    String unitPath,
  ) async {
    if (candidate.libraryUri == selfUri ||
        resolved.libraryUri == selfUri ||
        resolved.libraryPath == unitPath) {
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

  Future<DartObject?> _constantOf(
    String? uri,
    String? container,
    String member,
  ) async {
    if (uri == null || container == null) return null;
    final key = (uri, container, member);
    if (_constCache.containsKey(key)) return _constCache[key];

    final lib = await context.currentSession.getLibraryByUri(uri);
    if (lib is! LibraryElementResult) return _constCache[key] = null;
    final holder =
        lib.element.getClass(container) ??
        lib.element.getEnum(container) ??
        lib.element.getMixin(container) ??
        lib.element.getExtensionType(container);
    return _constCache[key] = holder?.getField(member)?.computeConstantValue();
  }
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

String _sentence(String message) =>
    message.endsWith('.') ? message.substring(0, message.length - 1) : message;

final class _ShorthandIndex extends RecursiveAstVisitor<void> {
  final byOffset = <int, _ResolvedShorthand>{};

  void _add(
    int offset,
    String memberName,
    Element? element,
    DartType? type, {
    List<DartType>? typeArgTypes,
  }) {
    byOffset[offset] = .new(
      memberName,
      element?.enclosingElement?.displayName,
      element?.library?.uri.toString(),
      redirectTarget: element is ConstructorElement
          ? _redirectTargetOf(element)
          : null,
      typeArgTypes: typeArgTypes?.map(_typeKey).join(', '),
      staticType: type == null ? null : _typeKey(type),
      shownType: type?.getDisplayString(),
      restrictions: _restrictionsOf(element),
      useResult: _holdersOf(element).any((e) => e.metadata.hasUseResult),
      libraryPath: element?.library?.firstFragment.source.fullName,
    );
  }

  static _ResolvedShorthand? _redirectTargetOf(ConstructorElement entry) {
    final params = _parametersOf(entry);
    final seen = <ConstructorElement>{};
    var cur = entry;
    while (cur.isFactory) {
      final next = cur.redirectedConstructor;
      if (next == null) break;
      if (!seen.add(cur.baseElement)) return null;
      cur = next;
      if (_parametersOf(cur) != params) return null;
    }
    if (identical(cur, entry)) return null;
    final targetName = cur.name;
    return .new(
      targetName == null || targetName.isEmpty ? 'new' : targetName,
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
      typeArgTypes: node.typeArgumentTypes,
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
