part of 'sanitizer.dart';

/// Import-scoped diagnostics whose fix is to drop the whole directive.
const _removableImportCodes = {
  'unused_import',
  'unnecessary_import',
  'duplicate_import',
};

const _unusedShownNameCode = 'unused_shown_name';

bool _isRemovableImport(Diagnostic d) =>
    _removableImportCodes.contains(d.diagnosticCode.lowerCaseName);

bool _isExcusedImportDiagnostic(Diagnostic d) {
  final code = d.diagnosticCode.lowerCaseName;
  return _removableImportCodes.contains(code) || code == _unusedShownNameCode;
}

/// A removable-import diagnostic by unit path, directive index and code (or
/// `unused_shown_name:<identifier>` for a single shown identifier).
/// A rewrite deletes no directive, so the index survives it, and it tells
/// two imports of one URI apart where their messages are identical.
typedef _ImportIssue = (String path, int directive, String code);

Set<_ImportIssue> _importIssuesOf(ResolvedLibraryResult lib) => {
  for (final unit in lib.units)
    for (final d in unit.diagnostics) ?_importIssueOf(unit, d),
};

_ImportIssue? _importIssueOf(ResolvedUnitResult unit, Diagnostic d) {
  final code = d.diagnosticCode.lowerCaseName;
  if (_removableImportCodes.contains(code)) {
    if (_importAt(unit, d.offset) case final index?) {
      return (unit.path, index, code);
    }
  } else if (code == _unusedShownNameCode) {
    if (_importAt(unit, d.offset) case final index?) {
      final directive = unit.unit.directives[index];
      if (directive is ImportDirective) {
        if (_shownNameAt(directive, d.offset) case final id?) {
          return (unit.path, index, '$code:${id.name}');
        }
      }
    }
  }
  return null;
}

SimpleIdentifier? _shownNameAt(ImportDirective directive, int offset) {
  for (final combinator in directive.combinators) {
    if (combinator is ShowCombinator) {
      for (final id in combinator.shownNames) {
        if (id.offset == offset) return id;
      }
    }
  }
  return null;
}

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
    final prunedShown = <int, Set<SimpleIdentifier>>{};
    for (final d in unit.diagnostics) {
      final index = _importAt(unit, d.offset);
      if (index == null) continue;
      final code = d.diagnosticCode.lowerCaseName;
      if (_isRemovableImport(d)) {
        if (!userIssues.contains((unit.path, index, code))) {
          cut.add(index);
        }
      } else if (code == _unusedShownNameCode) {
        final directive = unit.unit.directives[index];
        if (directive is ImportDirective) {
          if (_shownNameAt(directive, d.offset) case final id?
              when !userIssues.contains((
                unit.path,
                index,
                '$code:${id.name}',
              ))) {
            (prunedShown[index] ??= {}).add(id);
          }
        }
      }
    }
    if (cut.isEmpty && prunedShown.isEmpty) continue;
    final allPruned = cut.length == unit.unit.directives.length;
    final unitCuts = cuts[unit.path] ??= [];
    for (final index in cut) {
      unitCuts.add(
        _directiveCut(
          text,
          unit.unit.directives[index],
          index: index,
          allPruned: allPruned,
        ),
      );
    }
    for (final MapEntry(key: index, value: ids) in prunedShown.entries) {
      if (cut.contains(index)) continue;
      if (unit.unit.directives[index] case final ImportDirective directive) {
        unitCuts.addAll(_shownCombinatorCuts(directive, ids));
      }
    }
  }
  return cuts;
}

_DirectiveCut _directiveCut(
  String text,
  Directive directive, {
  required int index,
  required bool allPruned,
}) {
  final keyword = directive.firstTokenAfterCommentAndMetadata.offset;
  final hasHeader =
      index == 0 &&
      (directive.documentationComment != null || directive.metadata.isNotEmpty);
  final start = hasHeader ? keyword : directive.offset;
  final (:commentStart, :commentEnd, :comment) = _trailingComment(
    text,
    directive.end,
  );
  final hasIgnoreForFile =
      comment?.substring(2).contains('ignore_for_file:') ?? false;
  PrunedImport Function(int) info({String? replacement}) =>
      (line) => .new(
        line: line,
        uri: switch (directive) {
          ImportDirective(:final uri) => uri.stringValue ?? uri.toSource(),
          _ => directive.toSource(),
        },
        replacement: replacement,
        deletedComment: hasIgnoreForFile ? null : comment,
        keptComment: hasIgnoreForFile ? comment : null,
      );
  if (hasHeader && allPruned) {
    return (
      start: start,
      end: hasIgnoreForFile ? directive.end : commentEnd,
      replacement: 'library;',
      keyword: keyword,
      info: info(replacement: 'library;'),
    );
  }
  if (hasIgnoreForFile) {
    return (
      start: start,
      end: commentStart,
      replacement: '',
      keyword: keyword,
      info: info(),
    );
  }
  final lineEnd = _skipLineBreak(text, commentEnd);
  return (
    start: start,
    end: hasHeader ? _skipLineBreak(text, lineEnd) : lineEnd,
    replacement: '',
    keyword: keyword,
    info: info(),
  );
}

({int commentStart, int commentEnd, String? comment}) _trailingComment(
  String text,
  int from,
) {
  var commentStart = from;
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
  return (commentStart: commentStart, commentEnd: commentEnd, comment: comment);
}

int _skipLineBreak(String text, int offset) {
  var end = offset;
  if (end < text.length && text.codeUnitAt(end) == 0x0D) end++;
  if (end < text.length && text.codeUnitAt(end) == 0x0A) end++;
  return end;
}

Iterable<_DirectiveCut> _shownCombinatorCuts(
  ImportDirective directive,
  Set<SimpleIdentifier> prunedIds,
) sync* {
  final keyword = directive.firstTokenAfterCommentAndMetadata.offset;
  final uri = directive.uri.stringValue ?? directive.uri.toSource();
  for (final combinator in directive.combinators) {
    if (combinator is! ShowCombinator) continue;
    final shown = combinator.shownNames;
    final keptNames = [
      for (final id in shown)
        if (!prunedIds.contains(id)) id.name,
    ];
    if (keptNames.isEmpty) {
      yield (
        start: combinator.offset,
        end: combinator.end,
        replacement: '',
        keyword: keyword,
        info: (line) => .new(
          line: line,
          uri: uri,
          replacement: 'without ${combinator.toSource()}',
        ),
      );
    } else if (keptNames.length < shown.length) {
      final keptClause = 'show ${keptNames.join(', ')}';
      yield (
        start: shown.first.offset,
        end: shown.last.end,
        replacement: keptNames.join(', '),
        keyword: keyword,
        info: (line) => .new(line: line, uri: uri, replacement: keptClause),
      );
    }
  }
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
