package ts.printer;

import go.IdentityMap;

// Port of factory.go (types and NodeFactory methods; NewNodeFactory, flattenCommaElement and
// flattenCommaElements are package statics in class Printer).

// PORT: Go embeds ast.NodeFactory by value; here the printer NodeFactory extends it (Go
// `f.AsNodeFactory()` / `&f.NodeFactory` is the object itself). The name shadows ts.ast's
// NodeFactory inside ts.printer (import.hx imports this module after ts.ast.Ast).
@:allow(ts.printer)
class NodeFactory extends ts.ast.Ast.NodeFactory {
	var emitContext:EmitContext = null;

	public function new() {
		super();
	}

	// PORT: the field initialization of Go NewNodeFactory (package static Printer.NewNodeFactory);
	// the ast hooks field is only reachable from the subclass.
	function init(context:EmitContext):Void {
		final hooks = new NodeFactoryHooks();
		hooks.OnCreate = context.onCreate;
		hooks.OnUpdate = context.onUpdate;
		hooks.OnClone = context.onClone;
		this.hooks = hooks;
		this.emitContext = context;
	}

	function newGeneratedIdentifier(kind:GeneratedIdentifierFlags, text:std.String, node:Node, options:AutoGenerateOptions):IdentifierNode {
		final id:AutoGenerateId = Printer.NextAutoGenerateId();

		if (text.length == 0) {
			if (node == null) {
				text = '(auto@${id})';
			} else if (Ast.IsMemberName(node)) {
				text = node.Text();
			} else {
				text = '(generated@${Ast.GetNodeId(emitContext.getNodeForGeneratedNameWorker(node, id))})';
			}
			text = Printer.FormatGeneratedName(false /*privateName*/, options.Prefix, text, options.Suffix);
		}

		final name = NewIdentifier(text);
		final autoGenerate = new AutoGenerateInfo();
		autoGenerate.Id = id;
		autoGenerate.Flags = kind | (options.Flags & ~GeneratedIdentifierFlagsKindMask);
		autoGenerate.Prefix = options.Prefix;
		autoGenerate.Suffix = options.Suffix;
		autoGenerate.Node = node;
		if (emitContext.autoGenerate == null) {
			emitContext.autoGenerate = new IdentityMap<Node, AutoGenerateInfo>();
		}
		emitContext.autoGenerate.set(name, autoGenerate);
		return name;
	}

	// Allocates a new temp variable name, but does not record it in the environment. It is recommended to pass this to either
	// `AddVariableDeclaration` or `AddLexicalDeclaration` to ensure it is properly tracked, if you are not otherwise handling
	// it yourself.
	public function NewTempVariable():IdentifierNode {
		return NewTempVariableEx(new AutoGenerateOptions());
	}

	// Allocates a new temp variable name, but does not record it in the environment. It is recommended to pass this to either
	// `AddVariableDeclaration` or `AddLexicalDeclaration` to ensure it is properly tracked, if you are not otherwise handling
	// it yourself.
	public function NewTempVariableEx(options:AutoGenerateOptions):IdentifierNode {
		return newGeneratedIdentifier(GeneratedIdentifierFlagsAuto, "", null /*node*/, options);
	}

	// Allocates a new loop variable name.
	public function NewLoopVariable():IdentifierNode {
		return NewLoopVariableEx(new AutoGenerateOptions());
	}

	// Allocates a new loop variable name.
	public function NewLoopVariableEx(options:AutoGenerateOptions):IdentifierNode {
		return newGeneratedIdentifier(GeneratedIdentifierFlagsLoop, "", null /*node*/, options);
	}

	// Allocates a new unique name based on the provided text.
	public function NewUniqueName(text:std.String):IdentifierNode {
		return NewUniqueNameEx(text, new AutoGenerateOptions());
	}

	// Allocates a new unique name based on the provided text.
	public function NewUniqueNameEx(text:std.String, options:AutoGenerateOptions):IdentifierNode {
		return newGeneratedIdentifier(GeneratedIdentifierFlagsUnique, text, null /*node*/, options);
	}

	// Allocates a new unique name based on the provided node.
	public function NewGeneratedNameForNode(node:Node):IdentifierNode {
		return NewGeneratedNameForNodeEx(node, new AutoGenerateOptions());
	}

	// Allocates a new unique name based on the provided node.
	public function NewGeneratedNameForNodeEx(node:Node, options:AutoGenerateOptions):IdentifierNode {
		// PORT: Go passes the options struct by value; copy before the mutation.
		options = options.copy();
		if (options.Prefix.length > 0 || options.Suffix.length > 0) {
			options.Flags |= GeneratedIdentifierFlagsOptimistic;
		}

		return newGeneratedIdentifier(GeneratedIdentifierFlagsNode, "", node, options);
	}

	function newGeneratedPrivateIdentifier(kind:GeneratedIdentifierFlags, text:std.String, node:Node, options:AutoGenerateOptions):PrivateIdentifierNode {
		final id:AutoGenerateId = Printer.NextAutoGenerateId();

		if (text.length == 0) {
			if (node == null) {
				text = '(auto@${id})';
			} else if (Ast.IsMemberName(node)) {
				text = node.Text();
			} else {
				text = '(generated@${Ast.GetNodeId(emitContext.getNodeForGeneratedNameWorker(node, id))})';
			}
			text = Printer.FormatGeneratedName(true /*privateName*/, options.Prefix, text, options.Suffix);
		} else if (!StringTools.startsWith(text, "#")) {
			throw "First character of private identifier must be #: " + text;
		}

		final name = NewPrivateIdentifier(text);
		final autoGenerate = new AutoGenerateInfo();
		autoGenerate.Id = id;
		autoGenerate.Flags = kind | (options.Flags & ~GeneratedIdentifierFlagsKindMask);
		autoGenerate.Prefix = options.Prefix;
		autoGenerate.Suffix = options.Suffix;
		autoGenerate.Node = node;
		if (emitContext.autoGenerate == null) {
			emitContext.autoGenerate = new IdentityMap<Node, AutoGenerateInfo>();
		}
		emitContext.autoGenerate.set(name, autoGenerate);
		return name;
	}

	// Allocates a new unique private name based on the provided text.
	public function NewUniquePrivateName(text:std.String):PrivateIdentifierNode {
		return NewUniquePrivateNameEx(text, new AutoGenerateOptions());
	}

	// Allocates a new unique private name based on the provided text.
	public function NewUniquePrivateNameEx(text:std.String, options:AutoGenerateOptions):PrivateIdentifierNode {
		return newGeneratedPrivateIdentifier(GeneratedIdentifierFlagsUnique, text, null /*node*/, options);
	}

	// Allocates a new unique private name based on the provided node.
	public function NewGeneratedPrivateNameForNode(node:Node):PrivateIdentifierNode {
		return NewGeneratedPrivateNameForNodeEx(node, new AutoGenerateOptions());
	}

	// Allocates a new unique private name based on the provided node.
	public function NewGeneratedPrivateNameForNodeEx(node:Node, options:AutoGenerateOptions):PrivateIdentifierNode {
		// PORT: Go passes the options struct by value; copy before the mutation.
		options = options.copy();
		if (options.Prefix.length > 0 || options.Suffix.length > 0) {
			options.Flags |= GeneratedIdentifierFlagsOptimistic;
		}

		return newGeneratedPrivateIdentifier(GeneratedIdentifierFlagsNode, "", node, options);
	}

	// Allocates a new StringLiteral whose source text is derived from the provided node. This is often used to create a
	// string representation of an Identifier or NumericLiteral.
	public function NewStringLiteralFromNode(textSourceNode:Node):Node {
		var text = "";
		switch (textSourceNode.Kind) {
			case KindIdentifier | KindPrivateIdentifier | KindJsxNamespacedName | KindStringLiteral | KindNumericLiteral | KindBigIntLiteral |
				KindNoSubstitutionTemplateLiteral | KindTemplateHead | KindTemplateMiddle | KindTemplateTail | KindRegularExpressionLiteral:
				text = textSourceNode.Text();
			default:
		}
		final node = NewStringLiteral(text, TokenFlagsNone);
		if (emitContext.textSource == null) {
			emitContext.textSource = new IdentityMap<Node, Node>();
		}
		emitContext.textSource.set(node, textSourceNode);
		return node;
	}

	//
	// Common Tokens
	//

	public function NewThisExpression():Expression {
		return NewKeywordExpression(KindThisKeyword);
	}

	public function NewTrueExpression():Expression {
		return NewKeywordExpression(KindTrueKeyword);
	}

	public function NewFalseExpression():Expression {
		return NewKeywordExpression(KindFalseKeyword);
	}

	//
	// Common Operators
	//

	public function NewCommaExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindCommaToken), right);
	}

	public function NewAssignmentExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindEqualsToken), right);
	}

	public function NewLogicalORExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindBarBarToken), right);
	}

	public function NewLogicalANDExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindAmpersandAmpersandToken), right);
	}

	// func (f *NodeFactory) NewLogicalANDExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
	// func (f *NodeFactory) NewBitwiseORExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
	// func (f *NodeFactory) NewBitwiseXORExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
	// func (f *NodeFactory) NewBitwiseANDExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
	public function NewStrictEqualityExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindEqualsEqualsEqualsToken), right);
	}

	public function NewStrictInequalityExpression(left:Expression, right:Expression):Expression {
		return NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, NewToken(KindExclamationEqualsEqualsToken), right);
	}

	//
	// Compound Nodes
	//

	public function NewVoidZeroExpression():Expression {
		return NewVoidExpression(NewNumericLiteral("0", TokenFlagsNone));
	}

	// Converts a slice of expressions into a single comma-delimited expression. Returns nil if expressions is nil or empty.
	public function InlineExpressions(expressions:Array<Expression>):Expression {
		if (Core.len(expressions) == 0) {
			return null;
		}
		if (expressions.length == 1) {
			return expressions[0];
		}
		expressions = Printer.flattenCommaElements(expressions);
		var expression = expressions[0];
		for (i in 1...expressions.length) {
			expression = NewCommaExpression(expression, expressions[i]);
		}
		return expression;
	}

	//
	// Utilities
	//

	public function CreateExpressionFromEntityName(node:Node):Expression {
		if (Ast.IsQualifiedName(node)) {
			final left = CreateExpressionFromEntityName(node.AsQualifiedName().Left);
			final right = node.AsQualifiedName().Right.Clone(AsNodeFactory());
			right.Loc = node.AsQualifiedName().Right.Loc;
			// TODO(rbuckton): Does this need to be parented?
			right.Parent = node.AsQualifiedName().Right.Parent;
			final propAccess = NewPropertyAccessExpression(left, null, right, NodeFlagsNone);
			propAccess.Loc = node.Loc;
			return propAccess;
		}
		final res = node.Clone(AsNodeFactory());
		res.Loc = node.Loc;
		// TODO(rbuckton): Does this need to be parented?
		res.Parent = node.Parent;
		return res;
	}

	public function RestoreEnclosingLabel(node:Node, outermostLabeledStatement:LabeledStatement):Node {
		if (outermostLabeledStatement == null) {
			return node;
		}
		var innerLabel = node;
		if (Ast.IsLabeledStatement(outermostLabeledStatement.Statement)) {
			innerLabel = RestoreEnclosingLabel(node, outermostLabeledStatement.Statement.AsLabeledStatement());
		}
		return UpdateLabeledStatement(outermostLabeledStatement, outermostLabeledStatement.Label, innerLabel);
	}

	// CreateForOfBindingStatement creates a statement to bind the iteration value.
	public function CreateForOfBindingStatement(node:Node, boundValue:Node):Node {
		if (Ast.IsVariableDeclarationList(node)) {
			final firstDeclaration = node.AsVariableDeclarationList().Declarations.Nodes[0];
			final updatedDeclaration = UpdateVariableDeclaration(firstDeclaration.AsVariableDeclaration(), firstDeclaration.Name(), null, /*exclamationToken*/
				null, /*type*/ boundValue);
			final statement = NewVariableStatement(null,
				UpdateVariableDeclarationList(node.AsVariableDeclarationList(), NewNodeList([updatedDeclaration]), node.AsVariableDeclarationList().Flags));
			statement.Loc = node.Loc;
			return statement;
		}
		final updatedExpression = NewAssignmentExpression(node, boundValue);
		updatedExpression.Loc = node.Loc;
		final statement = NewExpressionStatement(updatedExpression);
		statement.Loc = node.Loc;
		return statement;
	}

	public function NewTypeCheck(value:Node, tag:std.String):Node {
		if (tag == "null") {
			return NewStrictEqualityExpression(value, NewKeywordExpression(KindNullKeyword));
		} else if (tag == "undefined") {
			return NewStrictEqualityExpression(value, NewVoidZeroExpression());
		} else {
			return NewStrictEqualityExpression(NewTypeOfExpression(value), NewStringLiteral(tag, TokenFlagsNone));
		}
	}

	public function NewMethodCall(object:Node, methodName:Node, argumentsList:Array<Node>):Node {
		// Preserve the optionality of `object`.
		if (Ast.IsCallExpression(object) && (object.Flags & NodeFlagsOptionalChain != 0)) {
			return NewCallExpression(NewPropertyAccessExpression(object, null, methodName, NodeFlagsNone), null, null, NewNodeList(argumentsList),
				NodeFlagsOptionalChain);
		}
		return NewCallExpression(NewPropertyAccessExpression(object, null, methodName, NodeFlagsNone), null, null, NewNodeList(argumentsList), NodeFlagsNone);
	}

	public function NewGlobalMethodCall(globalObjectName:std.String, methodName:std.String, argumentsList:Array<Node>):Node {
		return NewMethodCall(NewIdentifier(globalObjectName), NewIdentifier(methodName), argumentsList);
	}

	public function NewFunctionCallCall(target:Expression, thisArg:Expression, argumentsList:Array<Node>):Node {
		if (thisArg == null) {
			throw "Attempted to construct function call call without this argument expression";
		}
		final args:Array<Node> = [thisArg];
		if (argumentsList != null) {
			for (a in argumentsList) {
				args.push(a);
			}
		}
		return NewMethodCall(target, NewIdentifier("call"), args);
	}

	public function NewArraySliceCall(array:Expression, start:Int):Node {
		var args:Array<Node> = null;
		if (start != 0) {
			args = [NewNumericLiteral(Std.string(start), TokenFlagsNone)];
		}
		return NewMethodCall(array, NewIdentifier("slice"), args);
	}

	// Determines whether a node is a parenthesized expression that can be ignored when recreating outer expressions.
	//
	// A parenthesized expression can be ignored when all of the following are true:
	//
	// - It's `pos` and `end` are not -1
	// - It does not have a custom source map range
	// - It does not have a custom comment range
	// - It does not have synthetic leading or trailing comments
	//
	// If an outermost parenthesized expression is ignored, but the containing expression requires a parentheses around
	// the expression to maintain precedence, a new parenthesized expression should be created automatically when
	// the containing expression is created/updated.
	function isIgnorableParen(node:Expression):Bool {
		return Ast.IsParenthesizedExpression(node)
			&& Ast.NodeIsSynthesized(node)
			&& Ast.RangeIsSynthesized(emitContext.SourceMapRange(node))
			&& Ast.RangeIsSynthesized(emitContext.CommentRange(node)); // &&
		// len(emitContext.SyntheticLeadingComments(node)) == 0 &&
		// len(emitContext.SyntheticTrailingComments(node)) == 0
	}

	function updateOuterExpression(outerExpression:Expression /*OuterExpression*/, expression:Expression):Expression {
		switch (outerExpression.Kind) {
			case KindParenthesizedExpression:
				return UpdateParenthesizedExpression(outerExpression.AsParenthesizedExpression(), expression);
			case KindTypeAssertionExpression:
				return UpdateTypeAssertion(outerExpression.AsTypeAssertion(), outerExpression.Type(), expression);
			case KindAsExpression:
				return UpdateAsExpression(outerExpression.AsAsExpression(), expression, outerExpression.Type());
			case KindSatisfiesExpression:
				return UpdateSatisfiesExpression(outerExpression.AsSatisfiesExpression(), expression, outerExpression.Type());
			case KindNonNullExpression:
				return UpdateNonNullExpression(outerExpression.AsNonNullExpression(), expression, outerExpression.Flags);
			case KindExpressionWithTypeArguments:
				return UpdateExpressionWithTypeArguments(outerExpression.AsExpressionWithTypeArguments(), expression, outerExpression.TypeArgumentList());
			case KindPartiallyEmittedExpression:
				return UpdatePartiallyEmittedExpression(outerExpression.AsPartiallyEmittedExpression(), expression);
			default:
				throw 'Unexpected outer expression kind: ${outerExpression.Kind.String()}';
		}
	}

	public function RestoreOuterExpressions(outerExpression:Expression, innerExpression:Expression, kinds:OuterExpressionKinds):Expression {
		if (outerExpression != null && Ast.IsOuterExpression(outerExpression, kinds) && !isIgnorableParen(outerExpression)) {
			return updateOuterExpression(outerExpression, RestoreOuterExpressions(outerExpression.Expression(), innerExpression, OEKAll));
		}
		return innerExpression;
	}

	// Ensures `"use strict"` is the first statement of a slice of statements.
	public function EnsureUseStrict(statements:Array<Statement>):Array<Statement> {
		if (statements != null) {
			for (statement in statements) {
				if (Ast.IsPrologueDirective(statement) && statement.Expression().Text() == "use strict") {
					return statements;
				} else {
					break;
				}
			}
		}
		final useStrictPrologue = NewExpressionStatement(NewStringLiteral("use strict", TokenFlagsNone));
		final result:Array<Statement> = [useStrictPrologue];
		if (statements != null) {
			for (s in statements) {
				result.push(s);
			}
		}
		return result;
	}

	// Splits a slice of statements into two parts: standard prologue statements and the rest of the statements
	// PORT: Go returns (prologue, rest) → Pair (a = prologue, b = rest).
	public function SplitStandardPrologue(source:Array<Statement>):Pair<Array<Statement>, Array<Statement>> {
		if (source != null) {
			for (i in 0...source.length) {
				final statement = source[i];
				if (!Ast.IsPrologueDirective(statement)) {
					return new Pair(source.slice(0, i), source.slice(i));
				}
			}
		}
		return new Pair(source, null);
	}

	// Splits a slice of statements into two parts: custom prologue statements (e.g., with `EFCustomPrologue` set) and the rest of the statements
	// PORT: Go returns (prologue, rest) → Pair (a = prologue, b = rest).
	public function SplitCustomPrologue(source:Array<Statement>):Pair<Array<Statement>, Array<Statement>> {
		if (source != null) {
			for (i in 0...source.length) {
				final statement = source[i];
				if (Ast.IsPrologueDirective(statement) || emitContext.EmitFlags(statement) & EFCustomPrologue == 0) {
					return new Pair(source.slice(0, i), source.slice(i));
				}
			}
		}
		return new Pair(null, source);
	}

	//
	// Declaration Names
	//

	function getName(node:Declaration, emitFlags:EmitFlags, opts:AssignedNameOptions):IdentifierNode {
		var nodeName:IdentifierNode = null;
		if (node != null) {
			if (opts.IgnoreAssignedName) {
				nodeName = Ast.GetNonAssignedNameOfDeclaration(node);
			} else {
				nodeName = Ast.GetNameOfDeclaration(node);
			}
		}

		if (nodeName != null) {
			final name = nodeName.Clone(this);
			if (!opts.AllowComments) {
				emitFlags |= EFNoComments;
			}
			if (!opts.AllowSourceMaps) {
				emitFlags |= EFNoSourceMap;
			}
			emitContext.AddEmitFlags(name, emitFlags);
			return name;
		}

		return NewGeneratedNameForNode(node);
	}

	// Gets the local name of a declaration. This is primarily used for declarations that can be referred to by name in the
	// declaration's immediate scope (classes, enums, namespaces). A local name will *never* be prefixed with a module or
	// namespace export modifier like "exports." when emitted as an expression.
	public function GetLocalName(node:Declaration):IdentifierNode {
		return GetLocalNameEx(node, new AssignedNameOptions());
	}

	// Gets the local name of a declaration. This is primarily used for declarations that can be referred to by name in the
	// declaration's immediate scope (classes, enums, namespaces). A local name will *never* be prefixed with a module or
	// namespace export modifier like "exports." when emitted as an expression.
	public function GetLocalNameEx(node:Declaration, opts:AssignedNameOptions):IdentifierNode {
		return getName(node, EFLocalName, opts);
	}

	// Gets the export name of a declaration. This is primarily used for declarations that can be
	// referred to by name in the declaration's immediate scope (classes, enums, namespaces). An
	// export name will *always* be prefixed with an module or namespace export modifier like
	// `"exports."` when emitted as an expression if the name points to an exported symbol.
	public function GetExportName(node:Declaration):IdentifierNode {
		return GetExportNameEx(node, new AssignedNameOptions());
	}

	// Gets the export name of a declaration. This is primarily used for declarations that can be
	// referred to by name in the declaration's immediate scope (classes, enums, namespaces). An
	// export name will *always* be prefixed with an module or namespace export modifier like
	// `"exports."` when emitted as an expression if the name points to an exported symbol.
	public function GetExportNameEx(node:Declaration, opts:AssignedNameOptions):IdentifierNode {
		return getName(node, EFExportName, opts);
	}

	// Gets the name of a declaration to use during emit.
	public function GetDeclarationName(node:Declaration):IdentifierNode {
		return GetDeclarationNameEx(node, new NameOptions());
	}

	// Gets the name of a declaration to use during emit.
	public function GetDeclarationNameEx(node:Declaration, opts:NameOptions):IdentifierNode {
		return getName(node, EFNone, new AssignedNameOptions(opts.AllowComments, opts.AllowSourceMaps));
	}

	public function GetNamespaceMemberName(ns:IdentifierNode, name:IdentifierNode, opts:NameOptions):IdentifierNode {
		if (!emitContext.HasAutoGenerateInfo(name)) {
			name = name.Clone(this);
		}
		final qualifiedName = NewPropertyAccessExpression(ns, null /*questionDotToken*/, name, NodeFlagsNone);
		emitContext.AssignCommentAndSourceMapRanges(qualifiedName, name);
		if (!opts.AllowComments) {
			emitContext.AddEmitFlags(qualifiedName, EFNoComments);
		}
		if (!opts.AllowSourceMaps) {
			emitContext.AddEmitFlags(qualifiedName, EFNoSourceMap);
		}
		return qualifiedName;
	}

	// Gets the export name of a declaration for use in expressions.
	//
	// An export name will *always* be prefixed with a module or namespace export modifier like
	// `"exports."` when emitted as an expression if the name points to an exported symbol.
	public function GetExternalModuleOrNamespaceExportName(ns:IdentifierNode, node:Declaration, allowComments:Bool, allowSourceMaps:Bool):Node {
		if (ns != null && Ast.HasSyntacticModifier(node, ModifierFlagsExport)) {
			final nameOpts = new NameOptions(allowComments, allowSourceMaps);
			return GetNamespaceMemberName(ns, GetDeclarationNameEx(node, nameOpts), nameOpts);
		}
		return GetExportNameEx(node, new AssignedNameOptions(allowComments, allowSourceMaps));
	}

	//
	// Emit Helpers
	//

	// Allocates a new Identifier representing a reference to a helper function.
	public function NewUnscopedHelperName(name:std.String):IdentifierNode {
		final node = NewIdentifier(name);
		emitContext.SetEmitFlags(node, EFHelperName);
		return node;
	}

	// TypeScript Helpers

	public function NewDecorateHelper(decoratorExpressions:Array<Node>, target:Node, memberName:Node, descriptor:Node):Expression {
		emitContext.RequestEmitHelper(Printer.decorateHelper);

		var argumentsArray:Array<Node> = [];
		argumentsArray.push(NewArrayLiteralExpression(NewNodeList(decoratorExpressions), true));
		argumentsArray.push(target);
		if (memberName != null) {
			argumentsArray.push(memberName);
			if (descriptor != null) {
				argumentsArray.push(descriptor);
			}
		}

		return NewCallExpression(NewUnscopedHelperName("__decorate"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList(argumentsArray),
			NodeFlagsNone);
	}

	public function NewMetadataHelper(metadataKey:std.String, metadataValue:Node):Node {
		emitContext.RequestEmitHelper(Printer.metadataHelper);

		return NewCallExpression(NewUnscopedHelperName("__metadata"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([NewStringLiteral(metadataKey, TokenFlagsNone), metadataValue]), NodeFlagsNone);
	}

	public function NewParamHelper(expression:Node, parameterOffset:Int, location:TextRange):Expression {
		emitContext.RequestEmitHelper(Printer.paramHelper);
		final helper = NewCallExpression(NewUnscopedHelperName("__param"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([NewNumericLiteral(Std.string(parameterOffset), TokenFlagsNone), expression]), NodeFlagsNone);
		helper.Loc = location;
		return helper;
	}

	// ESNext Helpers

	public function NewAddDisposableResourceHelper(envBinding:Expression, value:Expression, async:Bool):Expression {
		emitContext.RequestEmitHelper(Printer.addDisposableResourceHelper);
		return NewCallExpression(NewUnscopedHelperName("__addDisposableResource"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([envBinding, value, NewKeywordExpression(Core.IfElse(async, KindTrueKeyword, KindFalseKeyword))]), NodeFlagsNone);
	}

	public function NewDisposeResourcesHelper(envBinding:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.disposeResourcesHelper);
		return NewCallExpression(NewUnscopedHelperName("__disposeResources"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([envBinding]), NodeFlagsNone);
	}

	// Class Fields Helpers

	public function NewClassPrivateFieldGetHelper(receiver:Expression, state:IdentifierNode, kind:PrivateIdentifierKind, fn:IdentifierNode):Expression {
		emitContext.RequestEmitHelper(Printer.classPrivateFieldGetHelper);
		var args:Array<Node>;
		if (fn == null) {
			args = [receiver, state, NewStringLiteral(kind, TokenFlagsNone)];
		} else {
			args = [receiver, state, NewStringLiteral(kind, TokenFlagsNone), fn];
		}
		return NewCallExpression(NewUnscopedHelperName("__classPrivateFieldGet"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList(args),
			NodeFlagsNone);
	}

	public function NewClassPrivateFieldSetHelper(receiver:Expression, state:IdentifierNode, value:Expression, kind:PrivateIdentifierKind,
			fn:IdentifierNode):Expression {
		emitContext.RequestEmitHelper(Printer.classPrivateFieldSetHelper);
		var args:Array<Node>;
		if (fn == null) {
			args = [receiver, state, value, NewStringLiteral(kind, TokenFlagsNone)];
		} else {
			args = [receiver, state, value, NewStringLiteral(kind, TokenFlagsNone), fn];
		}
		return NewCallExpression(NewUnscopedHelperName("__classPrivateFieldSet"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList(args),
			NodeFlagsNone);
	}

	public function NewClassPrivateFieldInHelper(state:IdentifierNode, receiver:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.classPrivateFieldInHelper);
		return NewCallExpression(NewUnscopedHelperName("__classPrivateFieldIn"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([state, receiver]), NodeFlagsNone);
	}

	// Creates `Object.defineProperty(target, name, descriptor)`.
	public function NewObjectDefinePropertyCall(target:Expression, name:Expression, descriptor:Expression):Expression {
		return NewCallExpression(NewPropertyAccessExpression(NewIdentifier("Object"), null, NewIdentifier("defineProperty"), NodeFlagsNone), null,
			/*questionDotToken*/ null, /*typeArguments*/ NewNodeList([target, name, descriptor]), NodeFlagsNone);
	}

	// Creates `Reflect.get(target, propertyKey, receiver)`.
	public function NewReflectGetCall(target:Expression, propertyKey:Expression, receiver:Expression):Expression {
		return NewCallExpression(NewPropertyAccessExpression(NewIdentifier("Reflect"), null, NewIdentifier("get"), NodeFlagsNone), null,
			/*questionDotToken*/ null, /*typeArguments*/ NewNodeList([target, propertyKey, receiver]), NodeFlagsNone);
	}

	// Creates `Reflect.set(target, propertyKey, value, receiver)`.
	public function NewReflectSetCall(target:Expression, propertyKey:Expression, value:Expression, receiver:Expression):Expression {
		return NewCallExpression(NewPropertyAccessExpression(NewIdentifier("Reflect"), null, NewIdentifier("set"), NodeFlagsNone), null,
			/*questionDotToken*/ null, /*typeArguments*/ NewNodeList([target, propertyKey, value, receiver]), NodeFlagsNone);
	}

	// Creates `target.bind(thisArg, ...args)`.
	public function NewFunctionBindCall(target:Expression, thisArg:Expression, argumentsList:Array<Node>):Expression {
		final args:Array<Node> = [];
		args.push(thisArg);
		if (argumentsList != null) {
			for (a in argumentsList) {
				args.push(a);
			}
		}
		return NewMethodCall(target, NewIdentifier("bind"), args);
	}

	// Creates `(() => { ...statements })()` — an immediately invoked arrow function.
	public function NewImmediatelyInvokedArrowFunction(statements:Array<Statement>):Expression {
		final arrow = NewArrowFunction(null, /*modifiers*/ null, /*typeParameters*/ NewNodeList([]), /*parameters*/ null, /*returnType*/ null,
			/*fullSignature*/ NewToken(KindEqualsGreaterThanToken), /*equalsGreaterThanToken*/ NewBlock(NewNodeList(statements), true));
		return NewCallExpression(NewParenthesizedExpression(arrow), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList([]), NodeFlagsNone);
	}

	// Creates `export default <expression>;`.
	public function NewExportDefault(expression:Expression):Statement {
		return NewExportAssignment(null, false, null, expression);
	}

	// Creates `export { <name> };`.
	public function NewExternalModuleExport(name:IdentifierNode):Statement {
		final specifier = NewExportSpecifier(false, null, name);
		final namedExports = NewNamedExports(NewNodeList([specifier]));
		return NewExportDeclaration(null, false, namedExports, null, null);
	}

	// ES2018 Helpers
	// Chains a sequence of expressions using the __assign helper or Object.assign if available in the target
	public function NewAssignHelper(attributesSegments:Array<Expression>, scriptTarget:ScriptTarget):Expression {
		return NewCallExpression(NewPropertyAccessExpression(NewIdentifier("Object"), null, NewIdentifier("assign"), NodeFlagsNone), null, null,
			NewNodeList(attributesSegments), NodeFlagsNone);
	}

	// ES2018 Destructuring Helpers

	public function NewRestHelper(value:Expression, elements:Array<Node>, computedTempVariables:Array<Node>, location:TextRange):Expression {
		emitContext.RequestEmitHelper(Printer.restHelper);
		var propertyNames:Array<Node> = null;
		var computedTempVariableOffset = 0;
		if (elements != null) {
			for (i in 0...elements.length) {
				final element = elements[i];
				if (i == elements.length - 1) {
					break;
				}
				final propertyName = Ast.TryGetPropertyNameOfBindingOrAssignmentElement(element);
				if (propertyName != null) {
					if (propertyNames == null) {
						propertyNames = [];
					}
					if (Ast.IsComputedPropertyName(propertyName)) {
						Debug.Assert(computedTempVariables != null, "Encountered computed property name but 'computedTempVariables' argument was not provided.");
						final temp = computedTempVariables[computedTempVariableOffset];
						computedTempVariableOffset++;
						// typeof _tmp === "symbol" ? _tmp : _tmp + ""
						propertyNames.push(NewConditionalExpression(NewTypeCheck(temp, "symbol"), NewToken(KindQuestionToken), temp, NewToken(KindColonToken),
							NewBinaryExpression(null, temp, null, NewToken(KindPlusToken), NewStringLiteral("", TokenFlagsNone))));
					} else {
						propertyNames.push(NewStringLiteralFromNode(propertyName));
					}
				}
			}
		}
		final propNames = NewArrayLiteralExpression(NewNodeList(propertyNames), false);
		propNames.Loc = location;
		return NewCallExpression(NewUnscopedHelperName("__rest"), null, null, NewNodeList([value, propNames]), NodeFlagsNone);
	}

	// ES2018 Helpers

	// Allocates a new Call expression to the `__await` helper.
	public function NewAwaitHelper(expression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.awaitHelper);
		return NewCallExpression(NewUnscopedHelperName("__await"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList([expression]),
			NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__asyncGenerator` helper.
	public function NewAsyncGeneratorHelper(generatorFunc:Expression, hasLexicalThis:Bool):Expression {
		emitContext.RequestEmitHelper(Printer.awaitHelper);
		emitContext.RequestEmitHelper(Printer.asyncGeneratorHelper);

		// Mark this node as originally an async function body
		emitContext.AddEmitFlags(generatorFunc, EFAsyncFunctionBody | EFReuseTempVariableScope);

		var thisArg:Expression;
		if (hasLexicalThis) {
			thisArg = NewKeywordExpression(KindThisKeyword);
		} else {
			thisArg = NewVoidZeroExpression();
		}

		return NewCallExpression(NewUnscopedHelperName("__asyncGenerator"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([thisArg, NewIdentifier("arguments"), generatorFunc]), NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__asyncDelegator` helper.
	public function NewAsyncDelegatorHelper(expression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.awaitHelper);
		emitContext.RequestEmitHelper(Printer.asyncDelegatorHelper);
		return NewCallExpression(NewUnscopedHelperName("__asyncDelegator"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([expression]), NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__asyncValues` helper.
	public function NewAsyncValuesHelper(expression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.asyncValuesHelper);
		return NewCallExpression(NewUnscopedHelperName("__asyncValues"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([expression]), NodeFlagsNone);
	}

	// !!! ES2017 Helpers

	// Allocates a new Call expression to the `__awaiter` helper.
	public function NewAwaiterHelper(hasLexicalThis:Bool, argumentsExpression:Expression, parameters:NodeList, body:BlockNode):Expression {
		emitContext.RequestEmitHelper(Printer.awaiterHelper);

		var params:NodeList;
		if (parameters != null) {
			params = parameters;
		} else {
			params = NewNodeList([]);
		}

		final generatorFunc = NewFunctionExpression(null, /*modifiers*/ NewToken(KindAsteriskToken), null, /*name*/ null, /*typeParameters*/ params,
			null, /*returnType*/ null, /*fullSignature*/ body);

		// Mark this node as originally an async function body
		emitContext.AddEmitFlags(generatorFunc, EFAsyncFunctionBody | EFReuseTempVariableScope);

		var thisArg:Expression;
		if (hasLexicalThis) {
			thisArg = NewKeywordExpression(KindThisKeyword);
		} else {
			thisArg = NewVoidZeroExpression();
		}

		var argsArg:Expression;
		if (argumentsExpression != null) {
			argsArg = argumentsExpression;
		} else {
			argsArg = NewVoidZeroExpression();
		}

		return NewCallExpression(NewUnscopedHelperName("__awaiter"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([thisArg, argsArg, NewVoidZeroExpression(), generatorFunc]), NodeFlagsNone);
	}

	// ES Decorator Helpers

	public function NewESDecorateClassContextObject(nameExpr:Expression, metadata:IdentifierNode):Expression {
		final props:Array<Node> = [
			NewPropertyAssignment(null, NewIdentifier("kind"), null, null, NewStringLiteral("class", 0)),
			NewPropertyAssignment(null, NewIdentifier("name"), null, null, nameExpr),
			NewPropertyAssignment(null, NewIdentifier("metadata"), null, null, metadata),
		];
		return NewObjectLiteralExpression(NewNodeList(props), false);
	}

	public function NewESDecorateClassElementAccessGetMethod(nameComputed:Bool, nameExpr:Expression):Node {
		var accessor:Expression;
		if (nameComputed) {
			accessor = NewElementAccessExpression(NewIdentifier("obj"), null, nameExpr, NodeFlagsNone);
		} else {
			accessor = NewPropertyAccessExpression(NewIdentifier("obj"), null, nameExpr, NodeFlagsNone);
		}

		final objParam = NewParameterDeclaration(null, null, NewIdentifier("obj"), null, null, null);

		final arrow = NewArrowFunction(null, null, NewNodeList([objParam]), null, null, NewToken(KindEqualsGreaterThanToken), accessor);

		return NewPropertyAssignment(null, NewIdentifier("get"), null, null, arrow);
	}

	public function NewESDecorateClassElementAccessSetMethod(nameComputed:Bool, nameExpr:Expression):Node {
		var accessor:Expression;
		if (nameComputed) {
			accessor = NewElementAccessExpression(NewIdentifier("obj"), null, nameExpr, NodeFlagsNone);
		} else {
			accessor = NewPropertyAccessExpression(NewIdentifier("obj"), null, nameExpr, NodeFlagsNone);
		}

		final assignment = NewAssignmentExpression(accessor, NewIdentifier("value"));
		final stmt = NewExpressionStatement(assignment);
		final body = NewBlock(NewNodeList([stmt]), false);

		final objParam = NewParameterDeclaration(null, null, NewIdentifier("obj"), null, null, null);
		final valueParam = NewParameterDeclaration(null, null, NewIdentifier("value"), null, null, null);

		final arrow = NewArrowFunction(null, null, NewNodeList([objParam, valueParam]), null, null, NewToken(KindEqualsGreaterThanToken), body);

		return NewPropertyAssignment(null, NewIdentifier("set"), null, null, arrow);
	}

	public function NewESDecorateClassElementAccessHasMethod(nameComputed:Bool, nameExpr:Expression):Node {
		// The property name for the "in" expression
		var propertyName:Expression;
		if (!nameComputed && nameExpr != null && Ast.IsIdentifier(nameExpr)) {
			propertyName = NewStringLiteralFromNode(nameExpr);
		} else {
			propertyName = nameExpr;
		}

		final objParam = NewParameterDeclaration(null, null, NewIdentifier("obj"), null, null, null);
		final inExpr = NewBinaryExpression(null, propertyName, null, NewToken(KindInKeyword), NewIdentifier("obj"));

		final arrow = NewArrowFunction(null, null, NewNodeList([objParam]), null, null, NewToken(KindEqualsGreaterThanToken), inExpr);

		return NewPropertyAssignment(null, NewIdentifier("has"), null, null, arrow);
	}

	// Creates the "access" object for a class element decorator context.
	//
	// 15.7.3 CreateDecoratorAccessObject (kind, name)
	//
	//  2. If _kind_ is ~field~, ~method~, ~accessor~, or ~getter~, then
	//     a. Let _getAccess_ be a new Abstract Closure with parameters (_object_) that captures _kind_ and _name_ ...
	//     b. Perform ! CreateDataPropertyOrThrow(_access_, "get", _getAccess_).
	//  3. If _kind_ is ~field~, ~accessor~, or ~setter~, then
	//     a. Let _setAccess_ be a new Abstract Closure with parameters (_object_, _value_) that captures _kind_ and _name_ ...
	//     b. Perform ! CreateDataPropertyOrThrow(_access_, "set", _setAccess_).
	public function NewESDecorateClassElementAccessObject(nameComputed:Bool, nameExpr:Expression, hasGet:Bool, hasSet:Bool):Expression {
		final accessProps:Array<Node> = [];

		// "has" method: obj => name in obj
		accessProps.push(NewESDecorateClassElementAccessHasMethod(nameComputed, nameExpr));

		// "get" method: obj => obj.name or obj => obj[name]
		if (hasGet) {
			accessProps.push(NewESDecorateClassElementAccessGetMethod(nameComputed, nameExpr));
		}

		// "set" method: (obj, value) => { obj.name = value; } or (obj, value) => { obj[name] = value; }
		if (hasSet) {
			accessProps.push(NewESDecorateClassElementAccessSetMethod(nameComputed, nameExpr));
		}

		return NewObjectLiteralExpression(NewNodeList(accessProps), false);
	}

	public function NewESDecorateClassElementContextObject(kind:std.String, nameComputed:Bool, nameExpr:Expression, isStatic:Bool, isPrivate:Bool,
			hasGet:Bool, hasSet:Bool, metadata:IdentifierNode):Expression {
		// Build the name value for the context's "name" property
		var nameValue:Expression;
		if (!nameComputed && nameExpr != null && (Ast.IsPrivateIdentifier(nameExpr) || Ast.IsIdentifier(nameExpr))) {
			nameValue = NewStringLiteralFromNode(nameExpr);
		} else {
			nameValue = nameExpr;
		}

		// Build the access object with has/get/set arrow functions
		final accessObj = NewESDecorateClassElementAccessObject(nameComputed, nameExpr, hasGet, hasSet);

		var staticExpr:Node;
		if (isStatic) {
			staticExpr = NewTrueExpression();
		} else {
			staticExpr = NewFalseExpression();
		}

		var privateExpr:Node;
		if (isPrivate) {
			privateExpr = NewTrueExpression();
		} else {
			privateExpr = NewFalseExpression();
		}

		final props:Array<Node> = [
			NewPropertyAssignment(null, NewIdentifier("kind"), null, null, NewStringLiteral(kind, 0)),
			NewPropertyAssignment(null, NewIdentifier("name"), null, null, nameValue),
			NewPropertyAssignment(null, NewIdentifier("static"), null, null, staticExpr),
			NewPropertyAssignment(null, NewIdentifier("private"), null, null, privateExpr),
			NewPropertyAssignment(null, NewIdentifier("access"), null, null, accessObj),
			NewPropertyAssignment(null, NewIdentifier("metadata"), null, null, metadata),
		];
		return NewObjectLiteralExpression(NewNodeList(props), false);
	}

	public function NewESDecorateHelper(ctor:Expression, descriptorIn:Expression, decorators:Expression, contextIn:Expression, initializers:Expression,
			extraInitializers:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.esDecorateHelper);
		return NewCallExpression(NewUnscopedHelperName("__esDecorate"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers]), NodeFlagsNone);
	}

	public function NewRunInitializersHelper(thisArg:Expression, initializers:Expression, value:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.runInitializersHelper);
		var arguments:Array<Expression>;
		if (value != null) {
			arguments = [thisArg, initializers, value];
		} else {
			arguments = [thisArg, initializers];
		}
		return NewCallExpression(NewUnscopedHelperName("__runInitializers"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList(arguments),
			NodeFlagsNone);
	}

	// ES2015 Helpers

	public function NewTemplateObjectHelper(cookedArray:Expression, rawArray:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.makeTemplateObjectHelper);
		return NewCallExpression(NewUnscopedHelperName("__makeTemplateObject"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([cookedArray, rawArray]), NodeFlagsNone);
	}

	public function NewPropKeyHelper(expr:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.propKeyHelper);
		return NewCallExpression(NewUnscopedHelperName("__propKey"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList([expr]),
			NodeFlagsNone);
	}

	public function NewSetFunctionNameHelper(fn:Expression, name:Expression, prefix:std.String):Expression {
		emitContext.RequestEmitHelper(Printer.setFunctionNameHelper);
		var arguments:Array<Expression>;
		if (prefix.length > 0) {
			arguments = [fn, name, NewStringLiteral(prefix, TokenFlagsNone)];
		} else {
			arguments = [fn, name];
		}
		return NewCallExpression(NewUnscopedHelperName("__setFunctionName"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList(arguments), NodeFlagsNone);
	}

	// ES Module Helpers

	// Allocates a new Call expression to the `__importDefault` helper.
	public function NewImportDefaultHelper(expression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.importDefaultHelper);
		return NewCallExpression(NewUnscopedHelperName("__importDefault"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([expression]), NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__importStar` helper.
	public function NewImportStarHelper(expression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.importStarHelper);
		return NewCallExpression(NewUnscopedHelperName("__importStar"), null, /*questionDotToken*/ null, /*typeArguments*/ NewNodeList([expression]),
			NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__exportStar` helper.
	public function NewExportStarHelper(moduleExpression:Expression, exportsExpression:Expression):Expression {
		emitContext.RequestEmitHelper(Printer.exportStarHelper);
		return NewCallExpression(NewUnscopedHelperName("__exportStar"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList([moduleExpression, exportsExpression]), NodeFlagsNone);
	}

	public function NewAssignmentTargetWrapper(paramName:IdentifierNode, expression:Expression):Node {
		final setAccessor = NewSetAccessorDeclaration(null, /*modifiers*/ NewIdentifier("value"), null, /*typeParameters*/
			NewNodeList([NewParameterDeclaration(null, null, paramName, null, null, null)]), null, /*returnType*/ null, /*fullSignature*/
			NewBlock(NewNodeList([NewExpressionStatement(expression)]), false));
		final objLiteral = NewObjectLiteralExpression(NewNodeList([setAccessor]), false);
		// Explicit parens required because of v8 regression (https://bugs.chromium.org/p/v8/issues/detail?id=9560)
		return NewPropertyAccessExpression(NewParenthesizedExpression(objLiteral), null, /*questionDotToken*/ NewIdentifier("value"), NodeFlagsNone);
	}

	// Allocates a new Call expression to the `__rewriteRelativeImportExtension` helper.
	public function NewRewriteRelativeImportExtensionsHelper(firstArgument:Node, preserveJsx:Bool):Expression {
		emitContext.RequestEmitHelper(Printer.rewriteRelativeImportExtensionsHelper);
		var arguments:Array<Expression>;
		if (preserveJsx) {
			arguments = [firstArgument, NewToken(KindTrueKeyword)];
		} else {
			arguments = [firstArgument];
		}
		return NewCallExpression(NewUnscopedHelperName("__rewriteRelativeImportExtension"), null, /*questionDotToken*/ null, /*typeArguments*/
			NewNodeList(arguments), NodeFlagsNone);
	}
}

class NameOptions {
	public var AllowComments:Bool = false; // indicates whether comments may be emitted for the name.
	public var AllowSourceMaps:Bool = false; // indicates whether source maps may be emitted for the name.

	public function new(AllowComments:Bool = false, AllowSourceMaps:Bool = false) {
		this.AllowComments = AllowComments;
		this.AllowSourceMaps = AllowSourceMaps;
	}
}

class AssignedNameOptions {
	public var AllowComments:Bool = false; // indicates whether comments may be emitted for the name.
	public var AllowSourceMaps:Bool = false; // indicates whether source maps may be emitted for the name.
	public var IgnoreAssignedName:Bool = false; // indicates whether the assigned name of a declaration shouldn't be considered.

	public function new(AllowComments:Bool = false, AllowSourceMaps:Bool = false, IgnoreAssignedName:Bool = false) {
		this.AllowComments = AllowComments;
		this.AllowSourceMaps = AllowSourceMaps;
		this.IgnoreAssignedName = IgnoreAssignedName;
	}
}

// Class Fields Helpers

enum abstract PrivateIdentifierKind(std.String) from std.String to std.String {
	var PrivateIdentifierKindField = "f";
	var PrivateIdentifierKindMethod = "m";
	var PrivateIdentifierKindAccessor = "a";
	var PrivateIdentifierKindUntransformed = "untransformed";
}
