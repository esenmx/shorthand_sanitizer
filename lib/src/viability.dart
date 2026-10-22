part of 'sanitizer.dart';

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

int _byOffset(_Candidate a, _Candidate b) {
  final unitCmp = a.unitPath.compareTo(b.unitPath);
  return unitCmp != 0 ? unitCmp : a.deleteStart.compareTo(b.deleteStart);
}

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

final class _CandidateCollector({
  required final TypeProvider typeProvider,
  required final Uri selfUri,
  required final String unitPath,
  required final String scopePath,
}) extends RecursiveAstVisitor<void> {
  final List<_Candidate> candidates = [];

  /// Sites ruled out by [_viability] before any resolve.
  final List<_Kept> unviable = [];

  /// Every site considered — viable or not, plus receiver-position static
  /// accesses — so `unmatchedSkips` knows whether a skip entry named anything
  /// in the run.
  final List<_SiteName> sites = [];
  final _viability = _Viability(typeProvider, selfUri);
  var _inAnnotation = false;

  /// Doc-comment `[Foo.bar]` references resolve as `PrefixedIdentifier`s;
  /// they are prose, not expressions.
  @override
  void visitComment(Comment node) {}

  /// `@MyAnnot.instance` is an `Annotation` node, not an expression: Dart
  /// metadata grammar does not allow `@.instance`. Arguments inside
  /// `@Annot(Fit.cover)` ARE expressions and may convert.
  @override
  void visitAnnotation(Annotation node) {
    final prev = _inAnnotation;
    _inAnnotation = true;
    node.name.accept(this);
    _inAnnotation = prev;
    node.typeArguments?.accept(this);
    node.arguments?.accept(this);
  }

  void _add({
    required Expression node,
    required Token startToken,
    required Token endToken,
    required String owner,
    required String display,
    required String memberName,
    required Element? memberElement,
    String replacement = '',
    bool isEndExclusive = true,
    String? typeArgTypes,
  }) {
    if (_inAnnotation) return;
    final container = memberElement?.enclosingElement?.displayName;
    sites.add((
      display: display,
      memberName: memberName,
      containerName: container,
    ));
    if (_hasInteriorComment(startToken, endToken)) {
      unviable.add((
        offset: startToken.offset,
        display: display,
        reason: 'comment inside prefix',
      ));
      return;
    }
    final slot = _viability.typedSlotOf(node);
    if (_viability.whyNot(
          node,
          memberName,
          memberElement: memberElement,
          typedSlot: slot,
        )
        case final reason?) {
      unviable.add((
        offset: startToken.offset,
        display: display,
        reason: reason,
      ));
      return;
    }
    final type = node.staticType;
    candidates.add(
      .new(
        unitPath: unitPath,
        scopePath: scopePath,
        deleteStart: startToken.offset,
        deleteEnd: isEndExclusive ? endToken.offset : endToken.end,
        replacement: replacement,
        owner: owner,
        display: display,
        memberName: memberName,
        containerName: container,
        libraryUri: memberElement?.library?.uri.toString(),
        signature: memberElement is ConstructorElement
            ? _constructorSignature(memberElement)
            : null,
        typeArgTypes: typeArgTypes,
        staticType: type == null ? null : _typeKey(type),
        shownType: type?.getDisplayString(),
        typedSlot: slot,
        restrictions: _restrictionsOf(memberElement),
        groupKey: (unitPath, _groupKeyOf(node)),
      ),
    );
  }

  /// Whether any comment token sits between [start] and [end] (or on [end]
  /// before it when [end] is the `.` token).
  static bool _hasInteriorComment(Token start, Token end) {
    for (
      Token? tok = start;
      tok != null && tok.offset <= end.offset;
      tok = tok.next
    ) {
      if (tok != start && tok.precedingComments != null) return true;
      if (tok == end) break;
    }
    return false;
  }

  /// Whether a receiver-position static access [node] (e.g. `Box.a.self`) has
  /// a selector chain head whose static type (or a supertype) declares static
  /// [member], so `.a.self` has a chance to resolve against the chain's
  /// context type. Cross-type chains like `Fit.cover.name` (`String` has no
  /// `cover`) or `Scaler.noScaling.pixels` (`int` has no `noScaling`) return
  /// false upfront without polluting `--explain`.
  static bool _canChainResolve(Expression node, String member) {
    AstNode head = node;
    for (
      var parent = head.parent;
      parent != null && _Viability._isSelectorFor(parent, head);
      parent = head.parent
    ) {
      head = parent;
    }
    final type = head is Expression ? head.staticType : null;
    if (type is! InterfaceType) return false;
    return type.element.getStatic(member) != null ||
        type.element.allSupertypes.any(
          (t) => t.element.getStatic(member) != null,
        );
  }

  static int _groupKeyOf(AstNode node) {
    var best = -1;
    for (AstNode? cur = node; cur != null; cur = cur.parent) {
      if ((cur is Statement && cur is! Block) || cur is VariableDeclaration) {
        best = cur.offset;
      } else if (cur is CompilationUnitMember || cur is ClassMember) {
        return best != -1 ? best : cur.offset;
      }
    }
    return best;
  }

  /// `EnumType.value` or `Class.staticField` / `Class.staticGetter`.
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final member = node.identifier.element;
    if (_isTypeRef(node.prefix) && _isStaticMember(member)) {
      if (_isReceiverPosition(node) &&
          !_canChainResolve(node, node.identifier.name)) {
        sites.add((
          display: '${node.prefix.name}.${node.identifier.name}',
          memberName: node.identifier.name,
          containerName: member?.enclosingElement?.displayName,
        ));
      } else {
        _add(
          node: node,
          startToken: node.prefix.beginToken,
          endToken: node.period,
          owner: node.prefix.name,
          display: '${node.prefix.name}.${node.identifier.name}',
          memberName: node.identifier.name,
          memberElement: member,
        );
      }
    }
    super.visitPrefixedIdentifier(node);
  }

  /// `prefix.Type.staticField` / `prefix.Type.staticGetter` — an import prefix
  /// makes the type reference itself a `PrefixedIdentifier`, so the member
  /// access above it parses as a `PropertyAccess` rather than a second
  /// `PrefixedIdentifier`.
  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    final member = node.propertyName.element;
    if (target != null &&
        !node.isCascaded &&
        _isTypeRef(target) &&
        _isStaticMember(member)) {
      final owner = target.toSource();
      if (_isReceiverPosition(node) &&
          !_canChainResolve(node, node.propertyName.name)) {
        sites.add((
          display: '$owner.${node.propertyName.name}',
          memberName: node.propertyName.name,
          containerName: member?.enclosingElement?.displayName,
        ));
      } else {
        _add(
          node: node,
          startToken: target.beginToken,
          endToken: node.operator,
          owner: owner,
          display: '$owner.${node.propertyName.name}',
          memberName: node.propertyName.name,
          memberElement: member,
        );
      }
    }
    super.visitPropertyAccess(node);
  }

  /// `Type.staticMethod(...)` or `prefix.Type.staticMethod(...)`, including
  /// `Type.staticMethod<T>(...)` when `<T>` is inferred identically by
  /// `.staticMethod(...)`.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final dot = node.operator;
    final typeArgs = node.typeArguments;
    if (target != null &&
        dot != null &&
        _isTypeRef(target) &&
        _isStaticMember(node.methodName.element)) {
      final owner = target.toSource();
      final name = node.methodName.name;
      if (typeArgs == null) {
        _add(
          node: node,
          startToken: target.beginToken,
          endToken: dot,
          owner: owner,
          display: '$owner.$name',
          memberName: name,
          memberElement: node.methodName.element,
        );
      } else {
        _add(
          node: node,
          startToken: target.beginToken,
          endToken: typeArgs.endToken,
          isEndExclusive: false,
          replacement: '.$name',
          owner: owner,
          display: '$owner.$name',
          memberName: name,
          memberElement: node.methodName.element,
          typeArgTypes: node.typeArgumentTypes?.map(_typeKey).join(', '),
        );
      }
    }
    super.visitMethodInvocation(node);
  }

  /// `Type.named(...)` and `new Type.named(...)`.
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final name = node.constructorName.name;
    final period = node.constructorName.period;
    final type = node.constructorName.type;
    final isNewKeyword = node.keyword?.keyword == .NEW;
    final startToken = isNewKeyword
        ? (node.keyword ?? node.constructorName.beginToken)
        : node.constructorName.beginToken;
    if (name != null && period != null && type.typeArguments == null) {
      _add(
        node: node,
        startToken: startToken,
        endToken: period,
        owner: type.qualifiedName(),
        display: '${type.qualifiedName()}.${name.name}',
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
  /// resolves `.bar` against the chain's context type (see [_Viability]);
  /// cross-type chains where the outer type cannot declare `bar` are filtered
  /// by [_canChainResolve].
  static bool _isReceiverPosition(Expression node) {
    final parent = node.parent;
    return (parent is PropertyAccess && identical(parent.target, node)) ||
        (parent is MethodInvocation && identical(parent.target, node));
  }
}

/// Static pre-check that a `Type.member` site can possibly verify, so that
/// sites which cannot are never handed to the resolve loop.
final class _Viability(final TypeProvider typeProvider, final Uri selfUri) {
  /// Why [site] can never verify, or null when it might.
  String? whyNot(
    Expression site,
    String member, {
    Element? memberElement,
    String? typedSlot,
  }) {
    if (_holdersOf(memberElement).any((e) => e.metadata.hasUseResult)) {
      return 'resolves to a @useResult member, whose shorthand dart analyze '
          'reports as unused';
    }
    AstNode head = site;
    // Selector chains (`PropertyAccess`, `MethodInvocation`, `IndexExpression`,
    // `CascadeExpression`, `PostfixExpression`) only propagate their context
    // type to a direct selector target — never through parentheses or a
    // conditional expression (`(Box.all(5)).let(...)` has no context type).
    for (
      var parent = head.parent;
      parent != null && _isSelectorFor(parent, head);
      parent = head.parent
    ) {
      head = parent;
    }
    for (
      var parent = head.parent;
      parent != null && _passesContextTo(parent, head);
      parent = head.parent
    ) {
      head = parent;
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
  /// collection or record element, a constant or relational pattern, an index
  /// or binary operator operand, a compound or non-promotable setter/cascade
  /// assignment RHS, or a parameter default whose context type is an interface
  /// type, reached only through wrappers that pass the value on unobserved
  /// ([_isTransparent]).
  /// Keyed without one trailing `?`: a nullable slot types the shorthand
  /// as its non-null class. Null elsewhere — a cascade target, a promotable
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
    if (_isInPinnedSlot(head.parent, head)) {
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

  bool _isInPinnedSlot(AstNode? parent, AstNode head) => switch (parent) {
    ArgumentList() => !_isUnpinnedGenericArgument(head as Argument),
    VariableDeclaration() ||
    ConstructorFieldInitializer() ||
    ListLiteral() ||
    SetOrMapLiteral() ||
    MapLiteralEntry() ||
    ConstantPattern() ||
    RelationalPattern() ||
    FormalParameterDefaultClause() => true,
    (ReturnStatement() || YieldStatement() || ExpressionFunctionBody()) &&
        final node =>
      _hasPinnedReturnSlot(node?.thisOrAncestorOfType()),
    RecordLiteral(:final fields) =>
      _recordFieldContext(parent, fields, head, pinnedOnly: true) != null,
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
          ((operator.type != .EQ && operator.type != .QUESTION_QUESTION_EQ) ||
              (parent.writeElement is PropertyAccessorElement &&
                  (parent.parent is ExpressionStatement ||
                      parent.parent is CascadeExpression))),
    _ => false,
  };

  bool _hasPinnedReturnSlot(FunctionBody? body) => switch (body?.parent) {
    ConstructorDeclaration() => true,
    MethodDeclaration(:final returnType, :final declaredFragment) =>
      returnType != null ||
          declaredFragment?.element.returnType is! DynamicType,
    FunctionExpression(parent: FunctionDeclaration(:final returnType)) =>
      returnType != null,
    final FunctionExpression closure =>
      _closureReturnType(closure, pinnedOnly: true) != null,
    _ => false,
  };

  /// Whether [parent] passes [child]'s value through to its own slot
  /// unobserved. A switch scrutinee is observed by its patterns.
  static bool _isTransparent(AstNode parent, AstNode child) => switch (parent) {
    ParenthesizedExpression() ||
    NamedArgument() ||
    RecordLiteralNamedField() ||
    ForElement() ||
    NullAwareElement() => true,
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      identical(thenExpression, child) || identical(elseExpression, child),
    BinaryExpression(
      :final operator,
      :final leftOperand,
      :final rightOperand,
    ) =>
      operator.type == .QUESTION_QUESTION &&
          (identical(leftOperand, child) || identical(rightOperand, child)),
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
        RecordLiteralNamedField() ||
        ForElement() ||
        NullAwareElement() => true,
        SwitchExpression(:final expression) => !identical(expression, child),
        ConditionalExpression(:final thenExpression, :final elseExpression) =>
          identical(thenExpression, child) || identical(elseExpression, child),
        BinaryExpression(:final operator, :final leftOperand) =>
          operator.type == .QUESTION_QUESTION && identical(leftOperand, child),
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
    return switch (parent) {
      ExpressionStatement() ||
      AsExpression() ||
      IsExpression() ||
      InterpolationExpression() => none,
      SwitchExpression(:final expression) || SwitchStatement(:final expression)
          when identical(expression, head) =>
        none,
      VariableDeclaration(:final parent) =>
        parent is VariableDeclarationList ? parent.type?.type ?? none : none,
      ConstructorFieldInitializer(:final fieldName) =>
        switch (fieldName.element) {
          FieldElement(:final type) => type,
          PropertyAccessorElement(:final variable) => variable.type,
          _ => null,
        },
      ThrowExpression() => typeProvider.objectType,
      PrefixExpression(:final operator) => operator.type == .BANG ? bool : none,
      IndexExpression(:final index) when identical(index, head) =>
        _indexContext(parent),
      BinaryExpression() => _binaryContext(parent, head),
      IfStatement(:final expression) ||
      IfElement(:final expression) ||
      WhileStatement(condition: final expression) ||
      DoStatement(condition: final expression) ||
      Assertion(condition: final expression) ||
      WhenClause(:final expression) when identical(expression, head) => bool,
      ConstantPattern(:final expression) when identical(expression, head) =>
        parent.matchedValueType,
      RelationalPattern(:final operand, :final operator)
          when identical(operand, head) =>
        operator.type == .EQ_EQ || operator.type == .BANG_EQ
            ? parent.matchedValueType
            : _firstParamType(parent.element),
      RecordLiteral(:final fields) => _recordFieldContext(
        parent,
        fields,
        head,
        pinnedOnly: false,
      ),
      ArgumentList() => _argumentContext(head as Argument),
      AssignmentExpression(:final operator, :final rightHandSide)
          when identical(rightHandSide, head) =>
        operator.type == .EQ || operator.type == .QUESTION_QUESTION_EQ
            ? parent.writeType
            : _firstParamType(parent.element),
      FormalParameterDefaultClause(parent: final FormalParameter param) =>
        param.declaredFragment?.element.type,
      ReturnStatement() || ExpressionFunctionBody() => switch (parent
          .thisOrAncestorOfType<FunctionBody>()) {
        final body? => _returnContext(body),
        null => null,
      },
      YieldStatement() => switch (parent.thisOrAncestorOfType<FunctionBody>()) {
        final body? => _yieldContext(parent, body),
        null => null,
      },
      ListLiteral(:final staticType) ||
      SetOrMapLiteral(:final staticType) => _elementType(staticType, 0),
      MapLiteralEntry(:final key) => _elementType(
        parent.thisOrAncestorOfType<SetOrMapLiteral>()?.staticType,
        identical(key, head) ? 0 : 1,
      ),
      _ => null,
    };
  }

  static DartType? _firstParamType(Element? element) {
    final type = element is ExecutableElement
        ? element.formalParameters.firstOrNull?.type
        : null;
    return type is TypeParameterType ? null : type;
  }

  static DartType? _indexContext(IndexExpression indexExpr) => _firstParamType(
    indexExpr.element ??
        switch (indexExpr.parent) {
          AssignmentExpression(:final leftHandSide, :final writeElement)
              when identical(leftHandSide, indexExpr) =>
            writeElement,
          PostfixExpression(:final operand, :final writeElement) ||
          PrefixExpression(
            :final operand,
            :final writeElement,
          ) when identical(operand, indexExpr) => writeElement,
          _ => null,
        },
  );

  DartType? _binaryContext(BinaryExpression parent, AstNode head) {
    final op = parent.operator.type;
    if (op == .AMPERSAND_AMPERSAND || op == .BAR_BAR) {
      return typeProvider.boolType;
    }
    if (op == .QUESTION_QUESTION && identical(parent.rightOperand, head)) {
      AstNode binHead = parent;
      for (
        var next = binHead.parent;
        next != null && _passesContextTo(next, binHead);
        next = binHead.parent
      ) {
        binHead = next;
      }
      final outer = _contextOf(binHead);
      return outer != null && outer is! NeverType
          ? outer
          : parent.leftOperand.staticType;
    }
    if (identical(parent.leftOperand, head)) return typeProvider.neverType;
    if (op == .EQ_EQ || op == .BANG_EQ) return parent.leftOperand.staticType;
    return _firstParamType(parent.element);
  }

  DartType? _recordFieldContext(
    RecordLiteral record,
    NodeList<RecordLiteralField> fields,
    AstNode field, {
    required bool pinnedOnly,
  }) {
    AstNode head = record;
    for (
      var parent = head.parent;
      parent != null &&
          (pinnedOnly
              ? _isTransparent(parent, head)
              : _passesContextTo(parent, head));
      parent = head.parent
    ) {
      head = parent;
    }
    if (pinnedOnly && !_isInPinnedSlot(head.parent, head)) return null;
    var ctx = _contextOf(head);
    while (ctx is InterfaceType && ctx.isDartAsyncFutureOr) {
      ctx = ctx.typeArguments.first;
    }
    if (ctx is NeverType) return pinnedOnly ? null : ctx;
    if (ctx is! RecordType) return null;
    if (field is RecordLiteralNamedField) {
      final name = field.name.lexeme;
      for (final f in ctx.namedFields) {
        if (f.name == name) return f.type;
      }
      return pinnedOnly ? null : typeProvider.neverType;
    }
    var posIndex = 0;
    for (final f in fields) {
      if (identical(f, field)) break;
      if (f is! RecordLiteralNamedField) posIndex++;
    }
    if (posIndex < ctx.positionalFields.length) {
      return ctx.positionalFields[posIndex].type;
    }
    return pinnedOnly ? null : typeProvider.neverType;
  }

  static bool _hasExplicitTypeArgs(AstNode? call) => switch (call) {
    MethodInvocation(:final typeArguments) ||
    FunctionExpressionInvocation(:final typeArguments) => typeArguments != null,
    InstanceCreationExpression(:final constructorName) =>
      constructorName.type.typeArguments != null,
    _ => true,
  };

  bool _callHasNoContext(Argument arg) {
    if (arg.parent?.parent case var callHead?) {
      for (
        var parent = callHead.parent;
        parent != null && _isSelectorFor(parent, callHead);
        parent = callHead.parent
      ) {
        callHead = parent;
      }
      for (
        var parent = callHead.parent;
        parent != null && _passesContextTo(parent, callHead);
        parent = callHead.parent
      ) {
        callHead = parent;
      }
      return _contextOf(callHead) == typeProvider.neverType;
    }
    return false;
  }

  bool _isUnpinnedGenericArgument(Argument arg) {
    final param = arg.correspondingParameter;
    if (param == null) return false;
    final call = arg.parent?.parent;
    if (_hasExplicitTypeArgs(call)) return false;
    return switch (param.baseElement.type) {
      TypeParameterType(:final element)
          when element.enclosingElement is! InstanceElement ||
              call is InstanceCreationExpression =>
        call is! Expression || typedSlotOf(call) == null,
      _ => false,
    };
  }

  TypeParameterElement? _unpinnedReturnParam(Argument arg) {
    final param = arg.correspondingParameter;
    if (param == null) return null;
    final call = arg.parent?.parent;
    if (_hasExplicitTypeArgs(call)) return null;
    var base = param.baseElement.type;
    while (base is InterfaceType && base.isDartAsyncFutureOr) {
      base = base.typeArguments.first;
    }
    if (base is! FunctionType) return null;
    var ret = base.returnType;
    while (ret is InterfaceType &&
        (ret.isDartAsyncFuture || ret.isDartAsyncFutureOr)) {
      ret = ret.typeArguments.first;
    }
    if (ret case TypeParameterType(:final element)
        when element.enclosingElement is! InstanceElement ||
            call is InstanceCreationExpression) {
      if (call is! Expression || typedSlotOf(call) == null) {
        return element;
      }
    }
    return null;
  }

  DartType? _argumentContext(Argument arg) {
    final param = arg.correspondingParameter;
    if (param == null) return null;
    if (_isUnpinnedGenericArgument(arg)) {
      if (param.baseElement.type case TypeParameterType(:final element)) {
        if (_callHasNoContext(arg)) {
          return element.bound ?? typeProvider.neverType;
        }
        return null;
      }
    }
    final type = param.type;
    return type is TypeParameterType ? null : type;
  }

  DartType? _closureReturnType(
    FunctionExpression closure, {
    required bool pinnedOnly,
  }) {
    AstNode head = closure;
    for (
      var parent = head.parent;
      parent != null &&
          (pinnedOnly
              ? _isTransparent(parent, head)
              : _passesContextTo(parent, head));
      parent = head.parent
    ) {
      head = parent;
    }
    final parent = head.parent;
    if (parent is ArgumentList && head is Argument) {
      if (_unpinnedReturnParam(head) case final element?) {
        if (pinnedOnly) return null;
        return _callHasNoContext(head)
            ? (element.bound ?? typeProvider.neverType)
            : null;
      }
    }
    if (pinnedOnly && !_isInPinnedSlot(parent, head)) return null;
    var ctx = _contextOf(head);
    while (ctx is InterfaceType && ctx.isDartAsyncFutureOr) {
      ctx = ctx.typeArguments.first;
    }
    return switch (ctx) {
      FunctionType(:final returnType) => returnType,
      NeverType() when !pinnedOnly => ctx,
      _ => null,
    };
  }

  /// The context type of a `return` (or `=>` body) in [body]: its function's
  /// declared or context-derived return type, unwrapped once for an `async`
  /// body.
  DartType? _returnContext(FunctionBody body) {
    if (body.isGenerator) return null;
    final owner = body.parent;
    final type = switch (owner) {
      ConstructorDeclaration() => owner.declaredFragment?.element.returnType,
      MethodDeclaration(:final returnType) =>
        returnType == null &&
                owner.declaredFragment?.element.returnType is DynamicType
            ? typeProvider.neverType
            : owner.declaredFragment?.element.returnType,
      FunctionExpression(:final parent) when parent is FunctionDeclaration =>
        parent.returnType == null
            ? typeProvider.neverType
            : owner.declaredFragment?.element.returnType,
      FunctionExpression() => _closureReturnType(owner, pinnedOnly: false),
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
  DartType? _yieldContext(YieldStatement node, FunctionBody body) {
    if (!body.isGenerator) return null;
    final owner = body.parent;
    final type = switch (owner) {
      MethodDeclaration(:final returnType) =>
        returnType == null &&
                owner.declaredFragment?.element.returnType is DynamicType
            ? typeProvider.neverType
            : owner.declaredFragment?.element.returnType,
      FunctionExpression(:final parent) when parent is FunctionDeclaration =>
        parent.returnType == null
            ? typeProvider.neverType
            : owner.declaredFragment?.element.returnType,
      FunctionExpression() => _closureReturnType(owner, pinnedOnly: false),
      _ => null,
    };
    if (type is NeverType) return type;
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
  String? _refusal(
    DartType type,
    String member, {
    Element? memberElement,
    String? typedSlot,
  }) {
    var t = type;
    while (t is InterfaceType && t.isDartAsyncFutureOr) {
      t = t.typeArguments.first;
    }
    if (t case InterfaceType(:final element)) {
      if (element.getStatic(member) case final target?) {
        final origContainer = memberElement?.enclosingElement;
        if (origContainer is InterfaceElement &&
            origContainer.baseElement != element.baseElement) {
          if (!_mayBeLicensedRebind(memberElement, target, selfUri)) {
            return 'rebinds to ${element.name}.$member';
          }
          if (typedSlot == null) {
            return 'rebinds to ${element.name}.$member outside a typed slot';
          }
        }
        return null;
      }
    }
    return switch (t) {
      TypeParameterType() || DynamicType() || InvalidType() => null,
      NeverType() => 'no context type',
      // An interface lacking it; void, function and record types declare
      // nothing.
      _ => 'context type ${t.getDisplayString()} declares no static $member',
    };
  }

  static bool _mayBeLicensedRebind(
    Element? original,
    Element target,
    Uri selfUri,
  ) {
    if (original is ConstructorElement && target is ConstructorElement) {
      final seen = <ConstructorElement>{};
      var cur = target;
      while (cur.isFactory) {
        final next = cur.redirectedConstructor;
        if (next == null || !seen.add(cur.baseElement)) break;
        cur = next;
      }
      return !identical(cur, target) && cur.baseElement == original.baseElement;
    }
    if (original is PropertyAccessorElement &&
        target is PropertyAccessorElement) {
      final origVar = original.variable;
      final targetVar = target.variable;
      if (!origVar.isConst || !targetVar.isConst) return false;
      if (original.library.uri == selfUri || target.library.uri == selfUri) {
        return false;
      }
      final v1 = origVar.computeConstantValue();
      final v2 = targetVar.computeConstantValue();
      if (v1 != null && v1.hasKnownValue && v2 != null && v2.hasKnownValue) {
        return v1 == v2;
      }
      return true;
    }
    return false;
  }
}

extension _InterfaceLookup on InterfaceElement {
  /// A static member or constructor called [name], if declared here.
  Element? getStatic(String name) {
    final method = getMethod(name);
    if (method != null && method.isStatic) return method;
    final getter = getGetter(name);
    if (getter != null && getter.isStatic) return getter;
    if (name == 'new') return unnamedConstructor ?? getNamedConstructor(name);
    return getNamedConstructor(name);
  }
}

extension _NamedTypeQualifiedName on NamedType {
  String qualifiedName() => switch (importPrefix) {
    final prefix? => '${prefix.name.lexeme}.${name.lexeme}',
    null => name.lexeme,
  };
}
