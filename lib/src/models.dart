part of 'sanitizer.dart';

/// One `Type.member` occurrence that may be shortened.
final class _Candidate({
  /// Analyzer path of the compilation unit holding this candidate.
  required final String unitPath,

  /// Canonical user-facing path of the compilation unit.
  required final String scopePath,

  /// Start of the range to replace.
  required final int deleteStart,

  /// End (exclusive) of the replaced range.
  required final int deleteEnd,

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

  /// Replacement text (`''` when deleting `Type` before `.member`, or
  /// `'.method'` when dropping both `Type.` and `<T>`).
  final String replacement = '',

  /// For constructors, the instantiated return type and formal parameter
  /// list (see `_constructorSignature`); null otherwise.
  final String? signature,

  /// For generic static method invocations (`Type.method<T>(...)`), the
  /// instantiated type-argument keys; null otherwise.
  final String? typeArgTypes,

  /// The site's static type as a `_typeKey`; the rewrite must keep it.
  final String? staticType,

  /// The site's static type as displayed, for the kept reason.
  final String? shownType,

  /// The `_typeKey` of the slot a licensed rebind must land in exactly (see
  /// `_Viability.typedSlotOf`); null outside a typed slot.
  final String? typedSlot,

  /// The member's use-restricting annotations (see `_restrictionsOf`).
  final Set<String> restrictions = const {},

  /// Unit path and offset of the enclosing statement (or declaration, outside
  /// a body). Type inference does not cross that boundary, so two candidates
  /// with different keys cannot affect each other's resolution — which is what
  /// lets the recovery pass test one per key at a time in a single resolve.
  final (String, int) groupKey = ('', -1),
});

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
  /// unit of its library — orphaned them, by line.
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
  /// import), `error` the OS's reason. A library's conversions and the
  /// imports they prune are written all or nothing; libraries converted before
  /// it stay written.
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

/// Candidate plan for one compilation unit within a library batch.
final class _UnitPlan({
  required final String scopePath,
  required final String unitPath,
  required final ResolvedUnitResult original,
  required final List<_Candidate> candidates,
  required final int unviable,
  required final List<_Kept>? kept,
});

/// Rewritten texts for the units of a library and where each candidate's
/// shorthand `.` landed in its unit's text.
final class _LibraryRewritten(
  final Map<String, String> texts,
  final Map<_Candidate, int> newOffsets,
);

/// One verified rewrite of a candidate set across a library.
final class _Attempt(
  final _LibraryRewritten rewritten,
  final ResolvedLibraryResult library,
  final Set<_Candidate> culprits, {
  required final String? stray,
}) {
  bool get isClean => culprits.isEmpty && stray == null;
}

/// A site left prefixed, and why — for [FileResult.kept].
typedef _Kept = ({int offset, String display, String reason});

/// What a skip entry can name a site by.
typedef _SiteName = ({
  String display,
  String memberName,
  String? containerName,
});

/// [start, end) of a text replaced by [length] characters.
typedef _Edit = ({int start, int end, int length});

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

/// Offsets shift across rewrites — a diagnostic is keyed by its unit,
/// severity, code and message instead. `severity` is the code's default:
/// `analyzer: errors:` overrides are not applied, on either side.
typedef _DiagKey = ({
  String path,
  String severity,
  String code,
  String message,
});

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
  final String? typeArgTypes,

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
  /// argument for argument, to [c]'s constructor.
  bool forwardsTo(_Candidate c) => switch (redirectTarget) {
    final target? => target.matches(c) && target.signature == c.signature,
    null => false,
  };
}

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
