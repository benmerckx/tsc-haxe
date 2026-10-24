package ts.ast;

import haxe.ds.IntMap;
import go.IdentityMap;
import haxe.ds.StringMap;

// Port of internal/ast.
//
// Module layout:
//   Ast.hx            class Ast (package class: package-level funcs/vars/consts of all files, Go
//                     file order, `// --- file.go ---` above each group) and the types of ast.go:
//                     abstract Node, class NodeDefault, NodeFactory, NodeList, SourceFile, ...
//   AstGenerated.hx   generated node classes, base interfaces and type aliases (ast_generated.go)
//   KindGenerated.hx  generated enum abstract Kind (kind_generated.go + stringer)
//   <file>.hx         types of the other Go files (Nodeflags.hx, Symbol.hx, Visitor.hx, ...)
// Regions marked `BEGIN GENERATED (tools/gen/ast)` in this file are rewritten by
// tools/gen/ast/GenAst.hx (run: `tools/haxe -cp tools/gen/ast --run GenAst`).
//
// Node model (PORT):
//   Go: every node data struct (Identifier, FunctionDeclaration, ...) embeds `Node`, and Node
//   points back to its data through the `nodeData` interface (`n.data`).
//   Haxe: ONE object per node, like Go's single allocation.
//   - class NodeDefault: the fields of Go `Node` (Kind, Flags, Loc as pos/end, id, Parent) and the
//     methods of Go `NodeDefault` (the nodeData interface) as virtual methods. Go `n.data` is the
//     object itself.
//   - class X extends NodeDefault (generated): the fields of the Go data struct X with all
//     embedded base structs flattened (fields of a base struct are properties so the base
//     interface DeclarationBase, ... can expose them; the inline accessors compile to field
//     access on the concrete class). The nodeData methods that Go would promote into X are
//     overrides that call the hand-written `Ast.T_method(node, ...)` statics below.
//   - abstract Node(NodeDefault): the methods of Go `*Node`. They cannot live on the class,
//     because Go data structs have fields with the same names (Expression, Type, Body, Name, ...).
//     `@:forward` exposes the class fields and the nodeData methods.
//   - `n.AsX()` is an unchecked cast; the base data accessors (DeclarationData, ...) return the
//     node itself typed as the base interface, or null, like Go.
//   - Go `IdentifierNode`, `Expression`, ... (= Node) are typedefs of Node.
// Go code that calls a promoted *Node method on a data struct (`fn.ModifierFlags()` with
// fn *FunctionDeclaration) becomes `fn.AsNode().ModifierFlags()`.
// Go lowercase (unexported) package funcs are private statics, reachable in ts.ast via @:allow.
@:allow(ts.ast)
class Ast {
	// --- ast.go ---

	// parseJSDocForNode is the package-level function for lazily parsing JSDoc.
	// It is set by the parser package via init().
	static var parseJSDocForNode:(SourceFile, Node) -> Array<Node> = null;

	// SetParseJSDocForNode registers the lazy JSDoc parse function. Called from parser's init().
	public static function SetParseJSDocForNode(fn:(SourceFile, Node) -> Array<Node>):Void {
		parseJSDocForNode = fn;
	}

	// Visitor

	static inline function visit(v:Visitor, node:Node):Bool {
		if (node != null) {
			return v(node);
		}
		return false;
	}

	static function visitNodes(v:Visitor, nodes:Array<Node>):Bool {
		if (nodes != null) {
			for (node in nodes) {
				if (v(node)) {
					return true;
				}
			}
		}
		return false;
	}

	static inline function visitNodeList(v:Visitor, nodeList:NodeList):Bool {
		if (nodeList != null) {
			return visitNodes(v, nodeList.Nodes);
		}
		return false;
	}

	static inline function visitModifiers(v:Visitor, modifiers:ModifierList):Bool {
		if (modifiers != null) {
			return visitNodes(v, modifiers.Nodes);
		}
		return false;
	}

	public static function NewNodeFactory(hooks:NodeFactoryHooks):NodeFactory {
		final f = new NodeFactory();
		f.hooks = hooks;
		return f;
	}

	static function newNode(kind:Kind, data:NodeDefault, hooks:NodeFactoryHooks):Node {
		final n = data.AsNode();
		n.Loc = Core.UndefinedTextRange();
		n.Kind = kind;
		// PORT: Go `n.data = data`: the node is its own data.
		if (hooks.OnCreate != null) {
			hooks.OnCreate(n);
		}
		return n;
	}

	static function updateNode(updated:Node, original:Node, hooks:NodeFactoryHooks):Node {
		if (updated != original) {
			updated.Flags = original.Flags;
			updated.Loc = original.Loc;
			if (hooks.OnUpdate != null) {
				hooks.OnUpdate(updated, original);
			}
		}
		return updated;
	}

	static function cloneNode(updated:Node, original:Node, hooks:NodeFactoryHooks):Node {
		updateNode(updated, original, hooks);
		if (updated != original && hooks.OnClone != null) {
			hooks.OnClone(updated, original);
		}
		return updated;
	}

	public static function IsWriteOnlyAccess(node:Node):Bool {
		return accessKind(node) == AccessKindWrite;
	}

	public static function IsWriteAccess(node:Node):Bool {
		return accessKind(node) != AccessKindRead;
	}

	public static function IsWriteAccessForReference(node:Node):Bool {
		final decl = GetDeclarationFromName(node);
		return (decl != null && declarationIsWriteAccess(decl)) || node.Kind == KindDefaultKeyword || IsWriteAccess(node);
	}

	public static function GetDeclarationFromName(name:Node):Declaration {
		if (name == null || name.Parent == null) {
			return null;
		}
		final parent = name.Parent;
		// PORT: `fallthrough` from the literal case into the identifier case → local function.
		function identifierCase():Declaration {
			if (IsDeclaration(parent)) {
				if (parent.Name() == name) {
					return parent;
				}
				return null;
			}
			if (IsQualifiedName(parent)) {
				final tag = parent.Parent;
				if (IsJSDocParameterTag(tag) && tag.Name() == parent) {
					return tag;
				}
				return null;
			}
			final binExp = parent.Parent;
			if (IsBinaryExpression(binExp) && GetAssignmentDeclarationKind(binExp) != JSDeclarationKindNone) {
				// (binExp.left as BindableStaticNameExpression).symbol || binExp.symbol
				var leftHasSymbol = false;
				if (binExp.AsBinaryExpression().Left != null && binExp.AsBinaryExpression().Left.Symbol() != null) {
					leftHasSymbol = true;
				}
				if (leftHasSymbol || binExp.Symbol() != null) {
					if (GetNameOfDeclaration(binExp.AsNode()) == name) {
						return binExp.AsNode();
					}
				}
			}
			return null;
		}
		switch (name.Kind) {
			case KindStringLiteral | KindNoSubstitutionTemplateLiteral | KindNumericLiteral:
				if (IsComputedPropertyName(parent)) {
					return parent.Parent;
				}
				return identifierCase();
			case KindIdentifier:
				return identifierCase();
			case KindPrivateIdentifier:
				if (IsDeclaration(parent) && parent.Name() == name) {
					return parent;
				}
			default:
		}
		return null;
	}

	static function declarationIsWriteAccess(decl:Node):Bool {
		if (decl == null) {
			return false;
		}
		// Consider anything in an ambient declaration to be a write access since it may be coming from JS.
		if (decl.Flags & NodeFlagsAmbient != 0) {
			return true;
		}

		switch (decl.Kind) {
			case KindBinaryExpression | KindBindingElement | KindClassDeclaration | KindClassExpression | KindDefaultKeyword | KindEnumDeclaration |
				KindEnumMember | KindExportSpecifier | KindImportClause // default import
				| KindImportEqualsDeclaration | KindImportSpecifier | KindInterfaceDeclaration | KindJSDocCallbackTag | KindJSDocTypedefTag |
				KindJsxAttribute | KindModuleDeclaration | KindNamespaceExportDeclaration | KindNamespaceImport | KindNamespaceExport | KindParameter |
				KindShorthandPropertyAssignment | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindTypeParameter:
				return true;

			case KindPropertyAssignment:
				// In `({ x: y } = 0);`, `x` is not a write access.
				return !IsArrayLiteralOrObjectLiteralDestructuringPattern(decl.Parent);

			case KindFunctionDeclaration | KindFunctionExpression | KindConstructor | KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
				// functions considered write if they provide a value (have a body)
				switch (decl.Kind) {
					case KindFunctionDeclaration:
						return decl.AsFunctionDeclaration().Body != null;
					case KindFunctionExpression:
						return decl.AsFunctionExpression().Body != null;
					case KindConstructor:
						// constructor node stores body on the parent? treat same as others
						return decl.AsConstructorDeclaration().Body != null;
					case KindMethodDeclaration:
						return decl.AsMethodDeclaration().Body != null;
					case KindGetAccessor:
						return decl.AsGetAccessorDeclaration().Body != null;
					case KindSetAccessor:
						return decl.AsSetAccessorDeclaration().Body != null;
					default:
				}
				return false;

			case KindVariableDeclaration | KindPropertyDeclaration:
				// variable/property write if initializer present or is in catch clause
				var hasInit = false;
				switch (decl.Kind) {
					case KindVariableDeclaration:
						hasInit = decl.AsVariableDeclaration().Initializer != null;
					case KindPropertyDeclaration:
						hasInit = decl.AsPropertyDeclaration().Initializer != null;
					default:
				}
				return hasInit || IsCatchClause(decl.Parent);

			case KindMethodSignature | KindPropertySignature | KindJSDocPropertyTag | KindJSDocParameterTag:
				return false;

			default:
				// preserve TS behavior: crash on unexpected kinds
				throw "Unhandled case in declarationIsWriteAccess";
		}
	}

	public static function IsArrayLiteralOrObjectLiteralDestructuringPattern(node:Node):Bool {
		if (!(IsArrayLiteralExpression(node) || IsObjectLiteralExpression(node))) {
			return false;
		}
		final parent = node.Parent;
		// [a,b,c] from:
		// [a, b, c] = someExpression;
		if (IsBinaryExpression(parent) && parent.AsBinaryExpression().Left == node
			&& parent.AsBinaryExpression().OperatorToken.Kind == KindEqualsToken) {
			return true;
		}
		// [a, b, c] from:
		// for([a, b, c] of expression)
		if (IsForOfStatement(parent) && parent.Initializer() == node) {
			return true;
		}
		// {x, a: {a, b, c} } = someExpression
		if (IsPropertyAssignment(parent)) {
			return IsArrayLiteralOrObjectLiteralDestructuringPattern(parent.Parent);
		}
		// [a, b, c] of
		// [x, [a, b, c] ] = someExpression
		return IsArrayLiteralOrObjectLiteralDestructuringPattern(parent);
	}

	static function accessKind(node:Node):AccessKind {
		final parent = node.Parent;
		if (parent == null) {
			return AccessKindRead;
		}
		switch (parent.Kind) {
			case KindParenthesizedExpression:
				return accessKind(parent);
			case KindPrefixUnaryExpression:
				final operator_ = parent.AsPrefixUnaryExpression().Operator;
				if (operator_ == KindPlusPlusToken || operator_ == KindMinusMinusToken) {
					return AccessKindReadWrite;
				}
				return AccessKindRead;
			case KindPostfixUnaryExpression:
				final operator_ = parent.AsPostfixUnaryExpression().Operator;
				if (operator_ == KindPlusPlusToken || operator_ == KindMinusMinusToken) {
					return AccessKindReadWrite;
				}
				return AccessKindRead;
			case KindBinaryExpression:
				if (parent.AsBinaryExpression().Left == node) {
					final operator_ = parent.AsBinaryExpression().OperatorToken;
					if (IsAssignmentOperator(operator_.Kind)) {
						if (operator_.Kind == KindEqualsToken) {
							return AccessKindWrite;
						}
						return AccessKindReadWrite;
					}
				}
				return AccessKindRead;
			case KindPropertyAccessExpression:
				if (parent.AsPropertyAccessExpression().Name() != node) {
					return AccessKindRead;
				}
				return accessKind(parent);
			case KindPropertyAssignment:
				final parentAccess = accessKind(parent.Parent);
				// In `({ x: varname }) = { x: 1 }`, the left `x` is a read, the right `x` is a write.
				if (node == parent.AsPropertyAssignment().Name()) {
					return reverseAccessKind(parentAccess);
				}
				return parentAccess;
			case KindShorthandPropertyAssignment:
				// Assume it's the local variable being accessed, since we don't check public properties for --noUnusedLocals.
				if (node == parent.AsShorthandPropertyAssignment().ObjectAssignmentInitializer) {
					return AccessKindRead;
				}
				return accessKind(parent.Parent);
			case KindArrayLiteralExpression:
				return accessKind(parent);
			case KindForInStatement | KindForOfStatement:
				if (node == parent.AsForInOrOfStatement().Initializer) {
					return AccessKindWrite;
				}
				return AccessKindRead;
			default:
				return AccessKindRead;
		}
	}

	static function reverseAccessKind(a:AccessKind):AccessKind {
		switch (a) {
			case AccessKindRead:
				return AccessKindWrite;
			case AccessKindWrite:
				return AccessKindRead;
			case AccessKindReadWrite:
				return AccessKindReadWrite;
		}
		throw "Unhandled case in reverseAccessKind";
	}

	// DeclarationBase

	public static function DeclarationBase_DeclarationData(node:DeclarationBase):DeclarationBase {
		return node;
	}

	public static function IsDeclarationNode(node:Node):Bool {
		return node.DeclarationData() != null;
	}

	// ExportableBase

	public static function ExportableBase_ExportableData(node:ExportableBase):ExportableBase {
		return node;
	}

	// ModifiersBase

	public static function ModifiersBase_Modifiers(node:ModifiersBase):ModifierList {
		return node.modifiers;
	}

	public static function ModifiersBase_setModifiers(node:ModifiersBase, modifiers:ModifierList):Void {
		node.modifiers = modifiers;
	}

	// LocalsContainerBase

	public static function LocalsContainerBase_LocalsContainerData(node:LocalsContainerBase):LocalsContainerBase {
		return node;
	}

	public static function IsLocalsContainer(node:Node):Bool {
		return node.LocalsContainerData() != null;
	}

	// FunctionLikeBase

	// PORT: Go returns &node.LocalsContainerBase (the embedded struct); flattened, it is the node.
	public static function FunctionLikeBase_LocalsContainerData(node:FunctionLikeBase):LocalsContainerBase {
		return node;
	}

	public static function FunctionLikeBase_FunctionLikeData(node:FunctionLikeBase):FunctionLikeBase {
		return node;
	}

	// BodyBase

	public static function BodyBase_BodyData(node:BodyBase):BodyBase {
		return node;
	}

	// FunctionLikeWithBodyBase

	public static function FunctionLikeWithBodyBase_LocalsContainerData(node:FunctionLikeWithBodyBase):LocalsContainerBase {
		return node;
	}

	public static function FunctionLikeWithBodyBase_FunctionLikeData(node:FunctionLikeWithBodyBase):FunctionLikeBase {
		return node;
	}

	public static function FunctionLikeWithBodyBase_BodyData(node:FunctionLikeWithBodyBase):BodyBase {
		return node;
	}

	// FlowNodeBase

	public static function FlowNodeBase_FlowNodeData(node:FlowNodeBase):FlowNodeBase {
		return node;
	}

	// CompositeBase

	// PORT: Go receives `self nodeData`; here the node (the object is its own data).
	public static function CompositeBase_subtreeFactsWorker(node:CompositeBase, self:Node):SubtreeFacts {
		// computeSubtreeFacts() is expected to be idempotent, so races will only impact time, not correctness.
		var facts:SubtreeFacts = node.facts;
		if (facts & SubtreeFactsComputed == 0) {
			facts |= self.computeSubtreeFacts() | SubtreeFactsComputed;
			node.facts = facts;
		}
		return facts & ~SubtreeFactsComputed;
	}

	public static function CompositeBase_computeSubtreeFacts(node:CompositeBase):SubtreeFacts {
		// This method must be implemented by the concrete node type.
		throw "not implemented";
	}

	// TypeSyntaxBase

	public static function TypeSyntaxBase_computeSubtreeFacts(node:TypeSyntaxBase):SubtreeFacts {
		return SubtreeContainsTypeScript;
	}

	public static function TypeSyntaxBase_propagateSubtreeFacts(node:TypeSyntaxBase):SubtreeFacts {
		return SubtreeContainsTypeScript;
	}

	public static function Token_computeSubtreeFacts(node:Token):SubtreeFacts {
		switch (node.Kind) {
			case KindUsingKeyword:
				return SubtreeContainsUsing;
			case KindPublicKeyword | KindPrivateKeyword | KindProtectedKeyword | KindReadonlyKeyword | KindAbstractKeyword | KindDeclareKeyword |
				KindConstKeyword | KindAnyKeyword | KindNumberKeyword | KindBigIntKeyword | KindNeverKeyword | KindObjectKeyword | KindInKeyword |
				KindOutKeyword | KindOverrideKeyword | KindStringKeyword | KindBooleanKeyword | KindSymbolKeyword | KindVoidKeyword | KindUnknownKeyword |
				KindUndefinedKeyword | KindExportKeyword:
				return SubtreeContainsTypeScript;
			case KindAccessorKeyword:
				return SubtreeContainsClassFields;
			case KindAsyncKeyword:
				return SubtreeContainsAnyAwait;
			case KindSuperKeyword:
				return SubtreeContainsLexicalSuper;
			case KindThisKeyword:
				return SubtreeContainsLexicalThis;
			case KindAsteriskAsteriskToken | KindAsteriskAsteriskEqualsToken:
				return SubtreeContainsExponentiationOperator;
			case KindQuestionQuestionToken:
				return SubtreeContainsNullishCoalescing;
			case KindQuestionDotToken:
				return SubtreeContainsOptionalChaining;
			case KindQuestionQuestionEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken:
				return SubtreeContainsLogicalAssignments;
			default:
		}
		return SubtreeFactsNone;
	}

	public static function PrivateIdentifier_computeSubtreeFacts(node:PrivateIdentifier):SubtreeFacts {
		return SubtreeContainsClassFields;
	}

	public static function Decorator_computeSubtreeFacts(node:Decorator):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsTypeScript | SubtreeContainsDecorators;
	}

	public static function ForInOrOfStatement_computeSubtreeFacts(node:ForInOrOfStatement):SubtreeFacts {
		return propagateSubtreeFacts(node.Initializer)
			| propagateSubtreeFacts(node.Expression)
			| propagateSubtreeFacts(node.Statement)
			| Core.IfElse(node.AwaitModifier != null, SubtreeContainsForAwaitOrAsyncGenerator, SubtreeFactsNone);
	}

	public static function ReturnStatement_computeSubtreeFacts(node:ReturnStatement):SubtreeFacts {
		// return in an ES2018 async generator must be awaited
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsForAwaitOrAsyncGenerator;
	}

	public static function CatchClause_computeSubtreeFacts(node:CatchClause):SubtreeFacts {
		var res = propagateSubtreeFacts(node.VariableDeclaration) | propagateSubtreeFacts(node.Block);
		if (node.VariableDeclaration == null) {
			res |= SubtreeContainsMissingCatchClauseVariable;
		}
		return res;
	}

	public static function CatchClause_propagateSubtreeFacts(node:CatchClause):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsCatchClause;
	}

	public static function VariableStatement_computeSubtreeFacts(node:VariableStatement):SubtreeFacts {
		if (node.modifiers != null && node.modifiers.ModifierFlags & ModifierFlagsAmbient != 0) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers) | propagateSubtreeFacts(node.DeclarationList);
		}
	}

	public static function VariableDeclaration_computeSubtreeFacts(node:VariableDeclaration):SubtreeFacts {
		return propagateSubtreeFacts(node.name)
			| propagateEraseableSyntaxSubtreeFacts(node.ExclamationToken)
			| propagateEraseableSyntaxSubtreeFacts(node.Type)
			| propagateSubtreeFacts(node.Initializer);
	}

	public static function VariableDeclarationList_computeSubtreeFacts(node:VariableDeclarationList):SubtreeFacts {
		return propagateNodeListSubtreeFacts(node.Declarations, propagateSubtreeFactsFunc)
			| Core.IfElse(node.Flags & NodeFlagsUsing != 0, SubtreeContainsUsing, SubtreeFactsNone);
	}

	public static function VariableDeclarationList_propagateSubtreeFacts(node:VariableDeclarationList):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsVariableDeclarationList;
	}

	public static function BindingPattern_computeSubtreeFacts(node:BindingPattern):SubtreeFacts {
		switch (node.Kind) {
			case KindObjectBindingPattern:
				return propagateNodeListSubtreeFacts(node.Elements, propagateObjectBindingElementSubtreeFactsFunc);
			case KindArrayBindingPattern:
				return propagateNodeListSubtreeFacts(node.Elements, propagateBindingElementSubtreeFactsFunc);
			default:
				return SubtreeFactsNone;
		}
	}

	public static function BindingPattern_propagateSubtreeFacts(node:BindingPattern):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsBindingPattern;
	}

	public static function ParameterDeclaration_computeSubtreeFacts(node:ParameterDeclaration):SubtreeFacts {
		if (node.name != null && IsThisIdentifier(node.name)) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.name)
				| propagateEraseableSyntaxSubtreeFacts(node.QuestionToken)
				| propagateEraseableSyntaxSubtreeFacts(node.Type)
				| propagateSubtreeFacts(node.Initializer);
		}
	}

	public static function ParameterDeclaration_propagateSubtreeFacts(node:ParameterDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsParameter;
	}

	public static function BindingElement_computeSubtreeFacts(node:BindingElement):SubtreeFacts {
		return propagateSubtreeFacts(node.PropertyName)
			| propagateSubtreeFacts(node.name)
			| propagateSubtreeFacts(node.Initializer)
			| Core.IfElse(node.DotDotDotToken != null, SubtreeContainsRestOrSpread, SubtreeFactsNone);
	}

	public static function FunctionDeclaration_computeSubtreeFacts(node:FunctionDeclaration):SubtreeFacts {
		if (node.Body == null || node.AsNode().ModifierFlags() & ModifierFlagsAmbient != 0) {
			return SubtreeContainsTypeScript;
		} else {
			final isAsync = node.AsNode().ModifierFlags() & ModifierFlagsAsync != 0;
			final isGenerator = node.AsteriskToken != null;
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.AsteriskToken)
				| propagateSubtreeFacts(node.name)
				| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
				| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
				| propagateEraseableSyntaxSubtreeFacts(node.Type)
				| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
				| propagateSubtreeFacts(node.Body)
				| Core.IfElse(isAsync && isGenerator, SubtreeContainsForAwaitOrAsyncGenerator, SubtreeFactsNone)
				| Core.IfElse(isAsync && !isGenerator, SubtreeContainsAnyAwait, SubtreeFactsNone);
		}
	}

	public static function FunctionDeclaration_propagateSubtreeFacts(node:FunctionDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsFunction;
	}

	// ClassLikeBase

	public static function ClassLikeBase_Name(node:ClassLikeBase):DeclarationName {
		return node.name;
	}

	public static function ClassLikeBase_ClassLikeData(node:ClassLikeBase):ClassLikeBase {
		return node;
	}

	public static function ClassLikeBase_computeSubtreeFacts(node:ClassLikeBase):SubtreeFacts {
		if (node.modifiers != null && node.modifiers.ModifierFlags & ModifierFlagsAmbient != 0) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.name)
				| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
				| propagateNodeListSubtreeFacts(node.HeritageClauses, propagateSubtreeFactsFunc)
				| propagateNodeListSubtreeFacts(node.Members, propagateSubtreeFactsFunc);
		}
	}

	public static function ClassDeclaration_propagateSubtreeFacts(node:ClassDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsClass;
	}

	public static function ClassExpression_propagateSubtreeFacts(node:ClassExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsClass;
	}

	public static function HeritageClause_computeSubtreeFacts(node:HeritageClause):SubtreeFacts {
		switch (node.Token) {
			case KindExtendsKeyword:
				return propagateNodeListSubtreeFacts(node.Types, propagateSubtreeFactsFunc);
			case KindImplementsKeyword:
				return SubtreeContainsTypeScript;
			default:
				return SubtreeFactsNone;
		}
	}

	public static function IsTypeOrJSTypeAliasDeclaration(node:Node):Bool {
		return node.Kind == KindTypeAliasDeclaration || node.Kind == KindJSTypeAliasDeclaration;
	}

	public static function EnumMember_computeSubtreeFacts(node:EnumMember):SubtreeFacts {
		return propagateSubtreeFacts(node.name) | propagateSubtreeFacts(node.Initializer) | SubtreeContainsTypeScript;
	}

	public static function EnumDeclaration_computeSubtreeFacts(node:EnumDeclaration):SubtreeFacts {
		if (node.modifiers != null && node.modifiers.ModifierFlags & ModifierFlagsAmbient != 0) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.name)
				| propagateNodeListSubtreeFacts(node.Members, propagateSubtreeFactsFunc)
				| SubtreeContainsTypeScript;
		}
	}

	public static function ModuleDeclaration_computeSubtreeFacts(node:ModuleDeclaration):SubtreeFacts {
		if (node.AsNode().ModifierFlags() & ModifierFlagsAmbient != 0) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.name)
				| propagateSubtreeFacts(node.Body)
				| SubtreeContainsTypeScript;
		}
	}

	public static function ModuleDeclaration_propagateSubtreeFacts(node:ModuleDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsModule;
	}

	public static function ImportEqualsDeclaration_computeSubtreeFacts(node:ImportEqualsDeclaration):SubtreeFacts {
		if (node.IsTypeOnly || !IsExternalModuleReference(node.ModuleReference)) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers) | propagateSubtreeFacts(node.name) | propagateSubtreeFacts(node.ModuleReference);
		}
	}

	public static function IsImportDeclarationOrJSImportDeclaration(node:Node):Bool {
		return node.Kind == KindImportDeclaration || node.Kind == KindJSImportDeclaration;
	}

	public static function ImportSpecifier_computeSubtreeFacts(node:ImportSpecifier):SubtreeFacts {
		if (node.IsTypeOnly) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateSubtreeFacts(node.PropertyName) | propagateSubtreeFacts(node.name);
		}
	}

	public static function ImportClause_computeSubtreeFacts(node:ImportClause):SubtreeFacts {
		if (node.PhaseModifier == KindTypeKeyword) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateSubtreeFacts(node.name) | propagateSubtreeFacts(node.NamedBindings);
		}
	}

	public static function ExportAssignment_computeSubtreeFacts(node:ExportAssignment):SubtreeFacts {
		return propagateModifierListSubtreeFacts(node.modifiers) | propagateSubtreeFacts(node.Type) | propagateSubtreeFacts(node.Expression)
			| Core.IfElse(node.IsExportEquals, SubtreeContainsTypeScript, SubtreeFactsNone);
	}

	public static function IsAnyExportAssignment(node:Node):Bool {
		return node.Kind == KindExportAssignment;
	}

	public static function ExportDeclaration_computeSubtreeFacts(node:ExportDeclaration):SubtreeFacts {
		return propagateModifierListSubtreeFacts(node.modifiers)
			| propagateSubtreeFacts(node.ExportClause)
			| propagateSubtreeFacts(node.ModuleSpecifier)
			| propagateSubtreeFacts(node.Attributes)
			| Core.IfElse(node.IsTypeOnly, SubtreeContainsTypeScript, SubtreeFactsNone);
	}

	public static function ExportSpecifier_computeSubtreeFacts(node:ExportSpecifier):SubtreeFacts {
		if (node.IsTypeOnly) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateSubtreeFacts(node.PropertyName) | propagateSubtreeFacts(node.name);
		}
	}

	// NamedMemberBase

	public static function NamedMemberBase_DeclarationData(node:NamedMemberBase):DeclarationBase {
		return node;
	}

	public static function NamedMemberBase_Modifiers(node:NamedMemberBase):ModifierList {
		return node.modifiers;
	}

	public static function NamedMemberBase_setModifiers(node:NamedMemberBase, modifiers:ModifierList):Void {
		node.modifiers = modifiers;
	}

	public static function NamedMemberBase_Name(node:NamedMemberBase):DeclarationName {
		return node.name;
	}

	public static function ConstructorDeclaration_computeSubtreeFacts(node:ConstructorDeclaration):SubtreeFacts {
		if (node.Body == null) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
				| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
				| propagateEraseableSyntaxSubtreeFacts(node.Type)
				| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
				| propagateSubtreeFacts(node.Body);
		}
	}

	public static function ConstructorDeclaration_propagateSubtreeFacts(node:ConstructorDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsConstructor;
	}

	public static function AccessorDeclarationBase_IsAccessorDeclaration(node:AccessorDeclarationBase):Void {
	}

	public static function AccessorDeclarationBase_computeSubtreeFacts(node:AccessorDeclarationBase):SubtreeFacts {
		if (node.Body == null) {
			return SubtreeContainsTypeScript;
		} else {
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.name)
				| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
				| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
				| propagateEraseableSyntaxSubtreeFacts(node.Type)
				| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
				| propagateSubtreeFacts(node.Body);
		}
	}

	public static function AccessorDeclarationBase_propagateSubtreeFacts(node:AccessorDeclarationBase):SubtreeFacts {
		// PORT: the interface does not carry the promoted *Node methods; the object is the node.
		return (cast node : Node).SubtreeFacts() & ~SubtreeExclusionsAccessor | propagateSubtreeFacts(node.name);
	}

	public static function MethodDeclaration_computeSubtreeFacts(node:MethodDeclaration):SubtreeFacts {
		if (node.Body == null) {
			return SubtreeContainsTypeScript;
		} else {
			final isAsync = node.modifiers != null && node.modifiers.ModifierFlags & ModifierFlagsAsync != 0;
			final isGenerator = node.AsteriskToken != null;
			return propagateModifierListSubtreeFacts(node.modifiers)
				| propagateSubtreeFacts(node.AsteriskToken)
				| propagateSubtreeFacts(node.name)
				| propagateEraseableSyntaxSubtreeFacts(node.PostfixToken)
				| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
				| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
				| propagateSubtreeFacts(node.Body)
				| propagateEraseableSyntaxSubtreeFacts(node.Type)
				| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
				| Core.IfElse(isAsync && isGenerator, SubtreeContainsForAwaitOrAsyncGenerator, SubtreeFactsNone)
				| Core.IfElse(isAsync && !isGenerator, SubtreeContainsAnyAwait, SubtreeFactsNone);
		}
	}

	public static function MethodDeclaration_propagateSubtreeFacts(node:MethodDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsMethod | propagateSubtreeFacts(node.name);
	}

	public static function PropertyDeclaration_computeSubtreeFacts(node:PropertyDeclaration):SubtreeFacts {
		return propagateModifierListSubtreeFacts(node.modifiers)
			| propagateSubtreeFacts(node.name)
			| propagateEraseableSyntaxSubtreeFacts(node.PostfixToken)
			| propagateEraseableSyntaxSubtreeFacts(node.Type)
			| propagateSubtreeFacts(node.Initializer)
			| SubtreeContainsClassFields;
	}

	public static function PropertyDeclaration_propagateSubtreeFacts(node:PropertyDeclaration):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsProperty | propagateSubtreeFacts(node.name);
	}

	public static function ClassStaticBlockDeclaration_computeSubtreeFacts(node:ClassStaticBlockDeclaration):SubtreeFacts {
		return propagateModifierListSubtreeFacts(node.modifiers) | propagateSubtreeFacts(node.Body) | SubtreeContainsClassFields;
	}

	public static function KeywordExpression_computeSubtreeFacts(node:KeywordExpression):SubtreeFacts {
		switch (node.Kind) {
			case KindThisKeyword:
				return SubtreeContainsLexicalThis;
			case KindSuperKeyword:
				return SubtreeContainsLexicalSuper;
			default:
		}
		return SubtreeFactsNone;
	}

	// TemplateLiteralLikeBase

	public static function LiteralLikeNodeBase_LiteralLikeData(node:LiteralLikeNodeBase):LiteralLikeNodeBase {
		return node;
	}

	public static function BigIntLiteral_computeSubtreeFacts(node:BigIntLiteral):SubtreeFacts {
		return SubtreeFactsNone; // `bigint` is not downleveled in any way
	}

	public static function Identifier_computeSubtreeFacts(node:Identifier):SubtreeFacts {
		return SubtreeContainsIdentifier;
	}

	public static function NoSubstitutionTemplateLiteral_computeSubtreeFacts(node:NoSubstitutionTemplateLiteral):SubtreeFacts {
		if (node.TemplateFlags & TokenFlagsContainsInvalidEscape != 0) {
			return SubtreeContainsInvalidTemplateEscape;
		}
		return SubtreeFactsNone;
	}

	public static function BinaryExpression_computeSubtreeFacts(node:BinaryExpression):SubtreeFacts {
		var facts = propagateModifierListSubtreeFacts(node.modifiers)
			| propagateSubtreeFacts(node.Left)
			| propagateSubtreeFacts(node.Type)
			| propagateSubtreeFacts(node.OperatorToken)
			| propagateSubtreeFacts(node.Right)
			| Core.IfElse(node.OperatorToken.Kind == KindInKeyword && IsPrivateIdentifier(node.Left),
				SubtreeContainsClassFields | SubtreeContainsPrivateIdentifierInExpression, SubtreeFactsNone);
		if (node.OperatorToken.Kind == KindEqualsToken) {
			if ((IsObjectLiteralExpression(node.Left) || IsArrayLiteralExpression(node.Left)) && ContainsObjectRestOrSpread(node.Left)) {
				facts |= SubtreeContainsObjectRestOrSpread;
			}
		}
		return facts;
	}

	public static function BinaryExpression_setModifiers(node:BinaryExpression, modifiers:ModifierList):Void {
		node.modifiers = modifiers;
	}

	public static function YieldExpression_computeSubtreeFacts(node:YieldExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsForAwaitOrAsyncGenerator;
	}

	public static function ArrowFunction_computeSubtreeFacts(node:ArrowFunction):SubtreeFacts {
		return propagateModifierListSubtreeFacts(node.modifiers)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
			| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
			| propagateEraseableSyntaxSubtreeFacts(node.Type)
			| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
			| propagateSubtreeFacts(node.Body)
			| Core.IfElse(node.AsNode().ModifierFlags() & ModifierFlagsAsync != 0, SubtreeContainsAnyAwait, SubtreeFactsNone);
	}

	public static function ArrowFunction_propagateSubtreeFacts(node:ArrowFunction):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsArrowFunction;
	}

	public static function FunctionExpression_computeSubtreeFacts(node:FunctionExpression):SubtreeFacts {
		final isAsync = node.modifiers != null && node.modifiers.ModifierFlags & ModifierFlagsAsync != 0;
		final isGenerator = node.AsteriskToken != null;
		return propagateModifierListSubtreeFacts(node.modifiers)
			| propagateSubtreeFacts(node.AsteriskToken)
			| propagateSubtreeFacts(node.name)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeParameters)
			| propagateNodeListSubtreeFacts(node.Parameters, propagateSubtreeFactsFunc)
			| propagateEraseableSyntaxSubtreeFacts(node.Type)
			| propagateEraseableSyntaxSubtreeFacts(node.FullSignature)
			| propagateSubtreeFacts(node.Body)
			| Core.IfElse(isAsync && isGenerator, SubtreeContainsForAwaitOrAsyncGenerator, SubtreeFactsNone)
			| Core.IfElse(isAsync && !isGenerator, SubtreeContainsAnyAwait, SubtreeFactsNone);
	}

	public static function FunctionExpression_propagateSubtreeFacts(node:FunctionExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsFunction;
	}

	public static function AsExpression_computeSubtreeFacts(node:AsExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsTypeScript;
	}

	public static function AsExpression_propagateSubtreeFacts(node:AsExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsOuterExpression;
	}

	public static function SatisfiesExpression_computeSubtreeFacts(node:SatisfiesExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsTypeScript;
	}

	public static function SatisfiesExpression_propagateSubtreeFacts(node:SatisfiesExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsOuterExpression;
	}

	public static function PropertyAccessExpression_computeSubtreeFacts(node:PropertyAccessExpression):SubtreeFacts {
		var privateName = SubtreeFactsNone;
		if (!IsIdentifier(node.name)) {
			privateName = SubtreeContainsPrivateIdentifierInExpression;
		}
		return propagateSubtreeFacts(node.Expression) | propagateSubtreeFacts(node.QuestionDotToken) | propagateSubtreeFacts(node.name) | privateName;
	}

	public static function PropertyAccessExpression_propagateSubtreeFacts(node:PropertyAccessExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsPropertyAccess;
	}

	public static function ElementAccessExpression_propagateSubtreeFacts(node:ElementAccessExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsElementAccess;
	}

	public static function CallExpression_computeSubtreeFacts(node:CallExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression)
			| propagateSubtreeFacts(node.QuestionDotToken)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments)
			| propagateNodeListSubtreeFacts(node.Arguments, propagateSubtreeFactsFunc)
			| Core.IfElse(node.Expression.Kind == KindImportKeyword, SubtreeContainsDynamicImport, SubtreeFactsNone);
	}

	public static function CallExpression_propagateSubtreeFacts(node:CallExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsCall;
	}

	public static function NewExpression_computeSubtreeFacts(node:NewExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments)
			| propagateNodeListSubtreeFacts(node.Arguments, propagateSubtreeFactsFunc);
	}

	public static function NewExpression_propagateSubtreeFacts(node:NewExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsNew;
	}

	public static function MetaProperty_computeSubtreeFacts(node:MetaProperty):SubtreeFacts {
		return propagateSubtreeFacts(node.name) & ~SubtreeContainsIdentifier;
	}

	public static function NonNullExpression_computeSubtreeFacts(node:NonNullExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsTypeScript;
	}

	public static function SpreadElement_computeSubtreeFacts(node:SpreadElement):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsRestOrSpread;
	}

	public static function TaggedTemplateExpression_computeSubtreeFacts(node:TaggedTemplateExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Tag)
			| propagateSubtreeFacts(node.QuestionDotToken)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments)
			| propagateSubtreeFacts(node.Template);
	}

	// Hand-written subtree facts for nontrivial generated nodes.

	public static function ArrayLiteralExpression_propagateSubtreeFacts(node:ArrayLiteralExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsArrayLiteral;
	}

	public static function ObjectLiteralExpression_propagateSubtreeFacts(node:ObjectLiteralExpression):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsObjectLiteral;
	}

	public static function SpreadAssignment_computeSubtreeFacts(node:SpreadAssignment):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsESObjectRestOrSpread | SubtreeContainsObjectRestOrSpread;
	}

	public static function PropertyAssignment_computeSubtreeFacts(node:PropertyAssignment):SubtreeFacts {
		return propagateSubtreeFacts(node.name) | propagateSubtreeFacts(node.Type) | propagateSubtreeFacts(node.Initializer);
	}

	public static function ShorthandPropertyAssignment_computeSubtreeFacts(node:ShorthandPropertyAssignment):SubtreeFacts {
		return propagateSubtreeFacts(node.name)
			| propagateSubtreeFacts(node.Type)
			| propagateSubtreeFacts(node.ObjectAssignmentInitializer)
			| SubtreeContainsTypeScript;
	}

	public static function AwaitExpression_computeSubtreeFacts(node:AwaitExpression):SubtreeFacts {
		// await in an ES2018 async generator must use `yield __await(expr)`
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsAwait | SubtreeContainsAnyAwait | SubtreeContainsForAwaitOrAsyncGenerator;
	}

	public static function TypeAssertion_computeSubtreeFacts(node:TypeAssertion):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsTypeScript;
	}

	public static function TypeAssertion_propagateSubtreeFacts(node:TypeAssertion):SubtreeFacts {
		return node.SubtreeFacts() & ~SubtreeExclusionsOuterExpression;
	}

	public static function ExpressionWithTypeArguments_computeSubtreeFacts(node:ExpressionWithTypeArguments):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments);
	}

	// FunctionOrConstructorTypeNodeBase

	public static function FunctionOrConstructorTypeNodeBase_DeclarationData(node:FunctionOrConstructorTypeNodeBase):DeclarationBase {
		// PORT: Go `node.FunctionLikeBase.DeclarationData()`; flattened, it is the node.
		return node;
	}

	public static function TemplateLiteralLikeNodeBase_LiteralLikeData(node:TemplateLiteralLikeNodeBase):LiteralLikeNodeBase {
		return node;
	}

	public static function TemplateLiteralLikeNodeBase_TemplateLiteralLikeData(node:TemplateLiteralLikeNodeBase):TemplateLiteralLikeNodeBase {
		return node;
	}

	public static function TemplateHead_computeSubtreeFacts(node:TemplateHead):SubtreeFacts {
		if (node.TemplateFlags & TokenFlagsContainsInvalidEscape != 0) {
			return SubtreeContainsInvalidTemplateEscape;
		}
		return SubtreeFactsNone;
	}

	public static function TemplateMiddle_computeSubtreeFacts(node:TemplateMiddle):SubtreeFacts {
		if (node.TemplateFlags & TokenFlagsContainsInvalidEscape != 0) {
			return SubtreeContainsInvalidTemplateEscape;
		}
		return SubtreeFactsNone;
	}

	public static function TemplateTail_computeSubtreeFacts(node:TemplateTail):SubtreeFacts {
		if (node.TemplateFlags & TokenFlagsContainsInvalidEscape != 0) {
			return SubtreeContainsInvalidTemplateEscape;
		}
		return SubtreeFactsNone;
	}

	public static function JsxElement_computeSubtreeFacts(node:JsxElement):SubtreeFacts {
		return propagateSubtreeFacts(node.OpeningElement)
			| propagateNodeListSubtreeFacts(node.Children, propagateSubtreeFactsFunc)
			| propagateSubtreeFacts(node.ClosingElement)
			| SubtreeContainsJsx;
	}

	public static function JsxAttributes_computeSubtreeFacts(node:JsxAttributes):SubtreeFacts {
		return propagateNodeListSubtreeFacts(node.Properties, propagateSubtreeFactsFunc) | SubtreeContainsJsx;
	}

	public static function JsxNamespacedName_computeSubtreeFacts(node:JsxNamespacedName):SubtreeFacts {
		return propagateSubtreeFacts(node.Namespace) | propagateSubtreeFacts(node.name) | SubtreeContainsJsx;
	}

	public static function JsxOpeningElement_computeSubtreeFacts(node:JsxOpeningElement):SubtreeFacts {
		return propagateSubtreeFacts(node.TagName)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments)
			| propagateSubtreeFacts(node.Attributes)
			| SubtreeContainsJsx;
	}

	public static function JsxSelfClosingElement_computeSubtreeFacts(node:JsxSelfClosingElement):SubtreeFacts {
		return propagateSubtreeFacts(node.TagName)
			| propagateEraseableSyntaxListSubtreeFacts(node.TypeArguments)
			| propagateSubtreeFacts(node.Attributes)
			| SubtreeContainsJsx;
	}

	public static function JsxFragment_computeSubtreeFacts(node:JsxFragment):SubtreeFacts {
		return propagateNodeListSubtreeFacts(node.Children, propagateSubtreeFactsFunc) | SubtreeContainsJsx;
	}

	public static function JsxOpeningFragment_computeSubtreeFacts(node:JsxOpeningFragment):SubtreeFacts {
		return SubtreeContainsJsx;
	}

	public static function JsxClosingFragment_computeSubtreeFacts(node:JsxClosingFragment):SubtreeFacts {
		return SubtreeContainsJsx;
	}

	public static function JsxAttribute_computeSubtreeFacts(node:JsxAttribute):SubtreeFacts {
		return propagateSubtreeFacts(node.name) | propagateSubtreeFacts(node.Initializer) | SubtreeContainsJsx;
	}

	public static function JsxSpreadAttribute_computeSubtreeFacts(node:JsxSpreadAttribute):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsJsx;
	}

	public static function JsxClosingElement_computeSubtreeFacts(node:JsxClosingElement):SubtreeFacts {
		return propagateSubtreeFacts(node.TagName) | SubtreeContainsJsx;
	}

	public static function JsxExpression_computeSubtreeFacts(node:JsxExpression):SubtreeFacts {
		return propagateSubtreeFacts(node.Expression) | SubtreeContainsJsx;
	}

	public static function JsxText_computeSubtreeFacts(node:JsxText):SubtreeFacts {
		return SubtreeContainsJsx;
	}

	// SourceFileDataKey

	static var sourceFileDataKeyCounter:Int = 0; // PORT: atomic.Uint64 → Int

	public static function NewSourceFileDataKey<T>():SourceFileDataKey<T> {
		return new SourceFileDataKey<T>(++sourceFileDataKeyCounter);
	}

	public static function GetOrComputeSourceFileData<T>(file:SourceFile, key:SourceFileDataKey<T>, compute:(SourceFile) -> T):T {
		final cell = getSourceFileDataCell(file, key);
		// PORT: sync.Once → flag.
		if (!cell.done) {
			cell.done = true;
			cell.value = compute(file);
		}
		return cell.value;
	}

	static function getSourceFileDataCell<T>(file:SourceFile, key:SourceFileDataKey<T>):SourceFileDataCell<T> {
		if (key == null || key.key == 0) {
			throw "invalid SourceFileDataKey; use NewSourceFileDataKey";
		}

		if (file.data == null) {
			file.data = new IntMap<Any>();
		}
		final existing:Null<SourceFileDataCell<T>> = cast file.data.get(key.key);
		if (existing != null) {
			return existing;
		}
		final cell = new SourceFileDataCell<T>();
		file.data.set(key.key, cell);
		return cell;
	}

	// `kind` should be a token kind.
	static function createToken(kind:Kind, file:SourceFile, pos:Int, end:Int, flags:TokenFlags):Node {
		if (file.tokenFactory == null) {
			file.tokenFactory = NewNodeFactory(new NodeFactoryHooks());
		}
		final text = file.text.substring(pos, end);
		switch (kind) {
			case KindNumericLiteral:
				return file.tokenFactory.NewNumericLiteral(text, flags);
			case KindBigIntLiteral:
				return file.tokenFactory.NewBigIntLiteral(text, flags);
			case KindStringLiteral:
				return file.tokenFactory.NewStringLiteral(text, flags);
			case KindJsxText | KindJsxTextAllWhiteSpaces:
				return file.tokenFactory.NewJsxText(text, kind == KindJsxTextAllWhiteSpaces);
			case KindRegularExpressionLiteral:
				return file.tokenFactory.NewRegularExpressionLiteral(text, flags);
			case KindNoSubstitutionTemplateLiteral:
				return file.tokenFactory.NewNoSubstitutionTemplateLiteral(text, flags);
			case KindTemplateHead:
				return file.tokenFactory.NewTemplateHead(text, "" /*rawText*/, flags);
			case KindTemplateMiddle:
				return file.tokenFactory.NewTemplateMiddle(text, "" /*rawText*/, flags);
			case KindTemplateTail:
				return file.tokenFactory.NewTemplateTail(text, "" /*rawText*/, flags);
			case KindIdentifier:
				return file.tokenFactory.NewIdentifier(text);
			case KindPrivateIdentifier:
				return file.tokenFactory.NewPrivateIdentifier(text);
			default: // Punctuation and keywords
				return file.tokenFactory.NewToken(kind);
		}
	}

	public static function GetDeclarationName(declaration:Node):String {
		final name = GetNonAssignedNameOfDeclaration(declaration);
		if (name != null) {
			if (IsComputedPropertyName(name)) {
				if (IsStringOrNumericLiteralLike(name.Expression())) {
					return name.Expression().Text();
				}
				if (IsPropertyAccessExpression(name.Expression())) {
					return name.Expression().Name().Text();
				}
			} else if (IsPropertyName(name)) {
				return name.Text();
			}
		}
		return "";
	}

	// Pragmas
	// PORT: Go `type PragmaKindFlags = uint8` (alias of uint8) → typedef of Int.

	public static inline final PragmaKindTripleSlashXML:PragmaKindFlags = 1 << 0;
	public static inline final PragmaKindSingleLine:PragmaKindFlags = 1 << 1;
	public static inline final PragmaKindMultiLine:PragmaKindFlags = 1 << 2;
	public static inline final PragmaKindFlagsNone:PragmaKindFlags = 0;
	public static inline final PragmaKindAll:PragmaKindFlags = PragmaKindTripleSlashXML | PragmaKindSingleLine | PragmaKindMultiLine;
	public static inline final PragmaKindDefault:PragmaKindFlags = PragmaKindAll;

	// Hand-written visitor implementations for nodes with runtime-dependent
	// child ordering. Generated code in ast_generated.go delegates to these.

	static function forEachChild_JSDocParameterOrPropertyTag(node:JSDocParameterOrPropertyTag, v:Visitor):Bool {
		return visit(v, node.TagName)
			|| (node.IsNameFirst && (visit(v, node.name) || visit(v, node.TypeExpression)))
			|| (!node.IsNameFirst && (visit(v, node.TypeExpression) || visit(v, node.name)))
			|| visitNodeList(v, node.Comment);
	}

	static function visitEachChild_JSDocParameterOrPropertyTag(node:JSDocParameterOrPropertyTag, v:NodeVisitor):Node {
		return v.Factory.UpdateJSDocParameterOrPropertyTag(node, v.visitNode(node.TagName), v.visitNode(node.name), node.IsBracketed,
			v.visitNode(node.TypeExpression), node.IsNameFirst, v.visitNodes(node.Comment));
	}

	// BEGIN GENERATED (tools/gen/ast) — do not edit: is
	// --- ast_generated.go: Is*() type guards ---

	public static function IsToken(node:Node):Bool {
		switch (node.Kind) {
			case KindUnknown | KindEndOfFile | KindSingleLineCommentTrivia | KindMultiLineCommentTrivia | KindNewLineTrivia | KindWhitespaceTrivia | KindConflictMarkerTrivia | KindNonTextFileMarkerTrivia | KindNumericLiteral | KindBigIntLiteral | KindStringLiteral | KindJsxText | KindJsxTextAllWhiteSpaces | KindRegularExpressionLiteral | KindNoSubstitutionTemplateLiteral | KindTemplateHead | KindTemplateMiddle | KindTemplateTail | KindOpenBraceToken | KindCloseBraceToken | KindOpenParenToken | KindCloseParenToken | KindOpenBracketToken | KindCloseBracketToken | KindDotToken | KindDotDotDotToken | KindSemicolonToken | KindCommaToken | KindQuestionDotToken | KindLessThanToken | KindLessThanSlashToken | KindGreaterThanToken | KindLessThanEqualsToken | KindGreaterThanEqualsToken | KindEqualsEqualsToken | KindExclamationEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindEqualsGreaterThanToken | KindPlusToken | KindMinusToken | KindAsteriskToken | KindAsteriskAsteriskToken | KindSlashToken | KindPercentToken | KindPlusPlusToken | KindMinusMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindAmpersandToken | KindBarToken | KindCaretToken | KindExclamationToken | KindTildeToken | KindAmpersandAmpersandToken | KindBarBarToken | KindQuestionToken | KindColonToken | KindAtToken | KindQuestionQuestionToken | KindBacktickToken | KindHashToken | KindEqualsToken | KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskEqualsToken | KindAsteriskAsteriskEqualsToken | KindSlashEqualsToken | KindPercentEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanEqualsToken | KindGreaterThanGreaterThanGreaterThanEqualsToken | KindAmpersandEqualsToken | KindBarEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken | KindCaretEqualsToken | KindIdentifier | KindPrivateIdentifier | KindJSDocCommentTextToken | KindBreakKeyword | KindCaseKeyword | KindCatchKeyword | KindClassKeyword | KindConstKeyword | KindContinueKeyword | KindDebuggerKeyword | KindDefaultKeyword | KindDeleteKeyword | KindDoKeyword | KindElseKeyword | KindEnumKeyword | KindExportKeyword | KindExtendsKeyword | KindFalseKeyword | KindFinallyKeyword | KindForKeyword | KindFunctionKeyword | KindIfKeyword | KindImportKeyword | KindInKeyword | KindInstanceOfKeyword | KindNewKeyword | KindNullKeyword | KindReturnKeyword | KindSuperKeyword | KindSwitchKeyword | KindThisKeyword | KindThrowKeyword | KindTrueKeyword | KindTryKeyword | KindTypeOfKeyword | KindVarKeyword | KindVoidKeyword | KindWhileKeyword | KindWithKeyword | KindImplementsKeyword | KindInterfaceKeyword | KindLetKeyword | KindPackageKeyword | KindPrivateKeyword | KindProtectedKeyword | KindPublicKeyword | KindStaticKeyword | KindYieldKeyword | KindAbstractKeyword | KindAccessorKeyword | KindAsKeyword | KindAssertsKeyword | KindAssertKeyword | KindAnyKeyword | KindAsyncKeyword | KindAwaitKeyword | KindBooleanKeyword | KindConstructorKeyword | KindDeclareKeyword | KindGetKeyword | KindImmediateKeyword | KindInferKeyword | KindIntrinsicKeyword | KindIsKeyword | KindKeyOfKeyword | KindModuleKeyword | KindNamespaceKeyword | KindNeverKeyword | KindOutKeyword | KindReadonlyKeyword | KindRequireKeyword | KindNumberKeyword | KindObjectKeyword | KindSatisfiesKeyword | KindSetKeyword | KindStringKeyword | KindSymbolKeyword | KindTypeKeyword | KindUndefinedKeyword | KindUniqueKeyword | KindUnknownKeyword | KindUsingKeyword | KindFromKeyword | KindGlobalKeyword | KindBigIntKeyword | KindOverrideKeyword | KindOfKeyword | KindDeferKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsIdentifier(node:Node):Bool {
		return node.Kind == KindIdentifier;
	}

	public static function IsPrivateIdentifier(node:Node):Bool {
		return node.Kind == KindPrivateIdentifier;
	}

	public static function IsQualifiedName(node:Node):Bool {
		return node.Kind == KindQualifiedName;
	}

	public static function IsComputedPropertyName(node:Node):Bool {
		return node.Kind == KindComputedPropertyName;
	}

	public static function IsDecorator(node:Node):Bool {
		return node.Kind == KindDecorator;
	}

	public static function IsEmptyStatement(node:Node):Bool {
		return node.Kind == KindEmptyStatement;
	}

	public static function IsIfStatement(node:Node):Bool {
		return node.Kind == KindIfStatement;
	}

	public static function IsDoStatement(node:Node):Bool {
		return node.Kind == KindDoStatement;
	}

	public static function IsWhileStatement(node:Node):Bool {
		return node.Kind == KindWhileStatement;
	}

	public static function IsForStatement(node:Node):Bool {
		return node.Kind == KindForStatement;
	}

	public static function IsForInStatement(node:Node):Bool {
		return node.Kind == KindForInStatement;
	}

	public static function IsForOfStatement(node:Node):Bool {
		return node.Kind == KindForOfStatement;
	}

	public static function IsBreakStatement(node:Node):Bool {
		return node.Kind == KindBreakStatement;
	}

	public static function IsContinueStatement(node:Node):Bool {
		return node.Kind == KindContinueStatement;
	}

	public static function IsReturnStatement(node:Node):Bool {
		return node.Kind == KindReturnStatement;
	}

	public static function IsWithStatement(node:Node):Bool {
		return node.Kind == KindWithStatement;
	}

	public static function IsSwitchStatement(node:Node):Bool {
		return node.Kind == KindSwitchStatement;
	}

	public static function IsCaseBlock(node:Node):Bool {
		return node.Kind == KindCaseBlock;
	}

	public static function IsCaseClause(node:Node):Bool {
		return node.Kind == KindCaseClause;
	}

	public static function IsDefaultClause(node:Node):Bool {
		return node.Kind == KindDefaultClause;
	}

	public static function IsThrowStatement(node:Node):Bool {
		return node.Kind == KindThrowStatement;
	}

	public static function IsTryStatement(node:Node):Bool {
		return node.Kind == KindTryStatement;
	}

	public static function IsCatchClause(node:Node):Bool {
		return node.Kind == KindCatchClause;
	}

	public static function IsDebuggerStatement(node:Node):Bool {
		return node.Kind == KindDebuggerStatement;
	}

	public static function IsLabeledStatement(node:Node):Bool {
		return node.Kind == KindLabeledStatement;
	}

	public static function IsExpressionStatement(node:Node):Bool {
		return node.Kind == KindExpressionStatement;
	}

	public static function IsBlock(node:Node):Bool {
		return node.Kind == KindBlock;
	}

	public static function IsVariableStatement(node:Node):Bool {
		return node.Kind == KindVariableStatement;
	}

	public static function IsVariableDeclaration(node:Node):Bool {
		return node.Kind == KindVariableDeclaration;
	}

	public static function IsVariableDeclarationList(node:Node):Bool {
		return node.Kind == KindVariableDeclarationList;
	}

	public static function IsObjectBindingPattern(node:Node):Bool {
		return node.Kind == KindObjectBindingPattern;
	}

	public static function IsArrayBindingPattern(node:Node):Bool {
		return node.Kind == KindArrayBindingPattern;
	}

	public static function IsParameterDeclaration(node:Node):Bool {
		return node.Kind == KindParameter;
	}

	public static function IsBindingElement(node:Node):Bool {
		return node.Kind == KindBindingElement;
	}

	public static function IsMissingDeclaration(node:Node):Bool {
		return node.Kind == KindMissingDeclaration;
	}

	public static function IsFunctionDeclaration(node:Node):Bool {
		return node.Kind == KindFunctionDeclaration;
	}

	public static function IsClassDeclaration(node:Node):Bool {
		return node.Kind == KindClassDeclaration;
	}

	public static function IsClassExpression(node:Node):Bool {
		return node.Kind == KindClassExpression;
	}

	public static function IsHeritageClause(node:Node):Bool {
		return node.Kind == KindHeritageClause;
	}

	public static function IsInterfaceDeclaration(node:Node):Bool {
		return node.Kind == KindInterfaceDeclaration;
	}

	public static function IsTypeAliasDeclaration(node:Node):Bool {
		return node.Kind == KindTypeAliasDeclaration;
	}

	public static function IsJSTypeAliasDeclaration(node:Node):Bool {
		return node.Kind == KindJSTypeAliasDeclaration;
	}

	public static function IsEnumMember(node:Node):Bool {
		return node.Kind == KindEnumMember;
	}

	public static function IsEnumDeclaration(node:Node):Bool {
		return node.Kind == KindEnumDeclaration;
	}

	public static function IsModuleBlock(node:Node):Bool {
		return node.Kind == KindModuleBlock;
	}

	public static function IsNotEmittedStatement(node:Node):Bool {
		return node.Kind == KindNotEmittedStatement;
	}

	public static function IsNotEmittedTypeElement(node:Node):Bool {
		return node.Kind == KindNotEmittedTypeElement;
	}

	public static function IsImportDeclaration(node:Node):Bool {
		return node.Kind == KindImportDeclaration;
	}

	public static function IsJSImportDeclaration(node:Node):Bool {
		return node.Kind == KindJSImportDeclaration;
	}

	public static function IsExternalModuleReference(node:Node):Bool {
		return node.Kind == KindExternalModuleReference;
	}

	public static function IsNamespaceImport(node:Node):Bool {
		return node.Kind == KindNamespaceImport;
	}

	public static function IsNamedImports(node:Node):Bool {
		return node.Kind == KindNamedImports;
	}

	public static function IsExportAssignment(node:Node):Bool {
		return node.Kind == KindExportAssignment;
	}

	public static function IsNamespaceExportDeclaration(node:Node):Bool {
		return node.Kind == KindNamespaceExportDeclaration;
	}

	public static function IsNamespaceExport(node:Node):Bool {
		return node.Kind == KindNamespaceExport;
	}

	public static function IsNamedExports(node:Node):Bool {
		return node.Kind == KindNamedExports;
	}

	public static function IsExportSpecifier(node:Node):Bool {
		return node.Kind == KindExportSpecifier;
	}

	public static function IsCallSignatureDeclaration(node:Node):Bool {
		return node.Kind == KindCallSignature;
	}

	public static function IsConstructSignatureDeclaration(node:Node):Bool {
		return node.Kind == KindConstructSignature;
	}

	public static function IsConstructorDeclaration(node:Node):Bool {
		return node.Kind == KindConstructor;
	}

	public static function IsGetAccessorDeclaration(node:Node):Bool {
		return node.Kind == KindGetAccessor;
	}

	public static function IsSetAccessorDeclaration(node:Node):Bool {
		return node.Kind == KindSetAccessor;
	}

	public static function IsIndexSignatureDeclaration(node:Node):Bool {
		return node.Kind == KindIndexSignature;
	}

	public static function IsMethodSignatureDeclaration(node:Node):Bool {
		return node.Kind == KindMethodSignature;
	}

	public static function IsMethodDeclaration(node:Node):Bool {
		return node.Kind == KindMethodDeclaration;
	}

	public static function IsPropertySignatureDeclaration(node:Node):Bool {
		return node.Kind == KindPropertySignature;
	}

	public static function IsPropertyDeclaration(node:Node):Bool {
		return node.Kind == KindPropertyDeclaration;
	}

	public static function IsSemicolonClassElement(node:Node):Bool {
		return node.Kind == KindSemicolonClassElement;
	}

	public static function IsClassStaticBlockDeclaration(node:Node):Bool {
		return node.Kind == KindClassStaticBlockDeclaration;
	}

	public static function IsOmittedExpression(node:Node):Bool {
		return node.Kind == KindOmittedExpression;
	}

	public static function IsKeywordExpression(node:Node):Bool {
		switch (node.Kind) {
			case KindNullKeyword | KindTrueKeyword | KindFalseKeyword | KindThisKeyword | KindSuperKeyword | KindImportKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsStringLiteral(node:Node):Bool {
		return node.Kind == KindStringLiteral;
	}

	public static function IsNumericLiteral(node:Node):Bool {
		return node.Kind == KindNumericLiteral;
	}

	public static function IsBigIntLiteral(node:Node):Bool {
		return node.Kind == KindBigIntLiteral;
	}

	public static function IsRegularExpressionLiteral(node:Node):Bool {
		return node.Kind == KindRegularExpressionLiteral;
	}

	public static function IsNoSubstitutionTemplateLiteral(node:Node):Bool {
		return node.Kind == KindNoSubstitutionTemplateLiteral;
	}

	public static function IsBinaryExpression(node:Node):Bool {
		return node.Kind == KindBinaryExpression;
	}

	public static function IsPrefixUnaryExpression(node:Node):Bool {
		return node.Kind == KindPrefixUnaryExpression;
	}

	public static function IsPostfixUnaryExpression(node:Node):Bool {
		return node.Kind == KindPostfixUnaryExpression;
	}

	public static function IsYieldExpression(node:Node):Bool {
		return node.Kind == KindYieldExpression;
	}

	public static function IsArrowFunction(node:Node):Bool {
		return node.Kind == KindArrowFunction;
	}

	public static function IsFunctionExpression(node:Node):Bool {
		return node.Kind == KindFunctionExpression;
	}

	public static function IsAsExpression(node:Node):Bool {
		return node.Kind == KindAsExpression;
	}

	public static function IsSatisfiesExpression(node:Node):Bool {
		return node.Kind == KindSatisfiesExpression;
	}

	public static function IsConditionalExpression(node:Node):Bool {
		return node.Kind == KindConditionalExpression;
	}

	public static function IsPropertyAccessExpression(node:Node):Bool {
		return node.Kind == KindPropertyAccessExpression;
	}

	public static function IsElementAccessExpression(node:Node):Bool {
		return node.Kind == KindElementAccessExpression;
	}

	public static function IsCallExpression(node:Node):Bool {
		return node.Kind == KindCallExpression;
	}

	public static function IsNewExpression(node:Node):Bool {
		return node.Kind == KindNewExpression;
	}

	public static function IsMetaProperty(node:Node):Bool {
		return node.Kind == KindMetaProperty;
	}

	public static function IsNonNullExpression(node:Node):Bool {
		return node.Kind == KindNonNullExpression;
	}

	public static function IsSpreadElement(node:Node):Bool {
		return node.Kind == KindSpreadElement;
	}

	public static function IsTemplateExpression(node:Node):Bool {
		return node.Kind == KindTemplateExpression;
	}

	public static function IsTemplateSpan(node:Node):Bool {
		return node.Kind == KindTemplateSpan;
	}

	public static function IsTaggedTemplateExpression(node:Node):Bool {
		return node.Kind == KindTaggedTemplateExpression;
	}

	public static function IsParenthesizedExpression(node:Node):Bool {
		return node.Kind == KindParenthesizedExpression;
	}

	public static function IsArrayLiteralExpression(node:Node):Bool {
		return node.Kind == KindArrayLiteralExpression;
	}

	public static function IsObjectLiteralExpression(node:Node):Bool {
		return node.Kind == KindObjectLiteralExpression;
	}

	public static function IsSpreadAssignment(node:Node):Bool {
		return node.Kind == KindSpreadAssignment;
	}

	public static function IsPropertyAssignment(node:Node):Bool {
		return node.Kind == KindPropertyAssignment;
	}

	public static function IsShorthandPropertyAssignment(node:Node):Bool {
		return node.Kind == KindShorthandPropertyAssignment;
	}

	public static function IsDeleteExpression(node:Node):Bool {
		return node.Kind == KindDeleteExpression;
	}

	public static function IsTypeOfExpression(node:Node):Bool {
		return node.Kind == KindTypeOfExpression;
	}

	public static function IsVoidExpression(node:Node):Bool {
		return node.Kind == KindVoidExpression;
	}

	public static function IsAwaitExpression(node:Node):Bool {
		return node.Kind == KindAwaitExpression;
	}

	public static function IsTypeAssertion(node:Node):Bool {
		return node.Kind == KindTypeAssertionExpression;
	}

	public static function IsKeywordTypeNode(node:Node):Bool {
		switch (node.Kind) {
			case KindAnyKeyword | KindBigIntKeyword | KindBooleanKeyword | KindIntrinsicKeyword | KindNeverKeyword | KindNumberKeyword | KindObjectKeyword | KindStringKeyword | KindSymbolKeyword | KindUndefinedKeyword | KindUnknownKeyword | KindVoidKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsUnionTypeNode(node:Node):Bool {
		return node.Kind == KindUnionType;
	}

	public static function IsIntersectionTypeNode(node:Node):Bool {
		return node.Kind == KindIntersectionType;
	}

	public static function IsConditionalTypeNode(node:Node):Bool {
		return node.Kind == KindConditionalType;
	}

	public static function IsTypeOperatorNode(node:Node):Bool {
		return node.Kind == KindTypeOperator;
	}

	public static function IsInferTypeNode(node:Node):Bool {
		return node.Kind == KindInferType;
	}

	public static function IsArrayTypeNode(node:Node):Bool {
		return node.Kind == KindArrayType;
	}

	public static function IsIndexedAccessTypeNode(node:Node):Bool {
		return node.Kind == KindIndexedAccessType;
	}

	public static function IsTypeReferenceNode(node:Node):Bool {
		return node.Kind == KindTypeReference;
	}

	public static function IsExpressionWithTypeArguments(node:Node):Bool {
		return node.Kind == KindExpressionWithTypeArguments;
	}

	public static function IsLiteralTypeNode(node:Node):Bool {
		return node.Kind == KindLiteralType;
	}

	public static function IsThisTypeNode(node:Node):Bool {
		return node.Kind == KindThisType;
	}

	public static function IsTypePredicateNode(node:Node):Bool {
		return node.Kind == KindTypePredicate;
	}

	public static function IsImportAttribute(node:Node):Bool {
		return node.Kind == KindImportAttribute;
	}

	public static function IsImportAttributes(node:Node):Bool {
		return node.Kind == KindImportAttributes;
	}

	public static function IsTypeQueryNode(node:Node):Bool {
		return node.Kind == KindTypeQuery;
	}

	public static function IsMappedTypeNode(node:Node):Bool {
		return node.Kind == KindMappedType;
	}

	public static function IsTypeLiteralNode(node:Node):Bool {
		return node.Kind == KindTypeLiteral;
	}

	public static function IsTupleTypeNode(node:Node):Bool {
		return node.Kind == KindTupleType;
	}

	public static function IsNamedTupleMember(node:Node):Bool {
		return node.Kind == KindNamedTupleMember;
	}

	public static function IsOptionalTypeNode(node:Node):Bool {
		return node.Kind == KindOptionalType;
	}

	public static function IsRestTypeNode(node:Node):Bool {
		return node.Kind == KindRestType;
	}

	public static function IsParenthesizedTypeNode(node:Node):Bool {
		return node.Kind == KindParenthesizedType;
	}

	public static function IsFunctionTypeNode(node:Node):Bool {
		return node.Kind == KindFunctionType;
	}

	public static function IsConstructorTypeNode(node:Node):Bool {
		return node.Kind == KindConstructorType;
	}

	public static function IsTemplateHead(node:Node):Bool {
		return node.Kind == KindTemplateHead;
	}

	public static function IsTemplateMiddle(node:Node):Bool {
		return node.Kind == KindTemplateMiddle;
	}

	public static function IsTemplateTail(node:Node):Bool {
		return node.Kind == KindTemplateTail;
	}

	public static function IsTemplateLiteralTypeNode(node:Node):Bool {
		return node.Kind == KindTemplateLiteralType;
	}

	public static function IsTemplateLiteralTypeSpan(node:Node):Bool {
		return node.Kind == KindTemplateLiteralTypeSpan;
	}

	public static function IsSyntheticExpression(node:Node):Bool {
		return node.Kind == KindSyntheticExpression;
	}

	public static function IsPartiallyEmittedExpression(node:Node):Bool {
		return node.Kind == KindPartiallyEmittedExpression;
	}

	public static function IsJsxElement(node:Node):Bool {
		return node.Kind == KindJsxElement;
	}

	public static function IsJsxAttributes(node:Node):Bool {
		return node.Kind == KindJsxAttributes;
	}

	public static function IsJsxNamespacedName(node:Node):Bool {
		return node.Kind == KindJsxNamespacedName;
	}

	public static function IsJsxOpeningElement(node:Node):Bool {
		return node.Kind == KindJsxOpeningElement;
	}

	public static function IsJsxSelfClosingElement(node:Node):Bool {
		return node.Kind == KindJsxSelfClosingElement;
	}

	public static function IsJsxFragment(node:Node):Bool {
		return node.Kind == KindJsxFragment;
	}

	public static function IsJsxOpeningFragment(node:Node):Bool {
		return node.Kind == KindJsxOpeningFragment;
	}

	public static function IsJsxClosingFragment(node:Node):Bool {
		return node.Kind == KindJsxClosingFragment;
	}

	public static function IsJsxAttribute(node:Node):Bool {
		return node.Kind == KindJsxAttribute;
	}

	public static function IsJsxSpreadAttribute(node:Node):Bool {
		return node.Kind == KindJsxSpreadAttribute;
	}

	public static function IsJsxClosingElement(node:Node):Bool {
		return node.Kind == KindJsxClosingElement;
	}

	public static function IsJsxExpression(node:Node):Bool {
		return node.Kind == KindJsxExpression;
	}

	public static function IsJsxText(node:Node):Bool {
		return node.Kind == KindJsxText;
	}

	public static function IsSyntaxList(node:Node):Bool {
		return node.Kind == KindSyntaxList;
	}

	public static function IsJSDoc(node:Node):Bool {
		return node.Kind == KindJSDoc;
	}

	public static function IsJSDocTypeExpression(node:Node):Bool {
		return node.Kind == KindJSDocTypeExpression;
	}

	public static function IsJSDocNonNullableType(node:Node):Bool {
		return node.Kind == KindJSDocNonNullableType;
	}

	public static function IsJSDocNullableType(node:Node):Bool {
		return node.Kind == KindJSDocNullableType;
	}

	public static function IsJSDocAllType(node:Node):Bool {
		return node.Kind == KindJSDocAllType;
	}

	public static function IsJSDocVariadicType(node:Node):Bool {
		return node.Kind == KindJSDocVariadicType;
	}

	public static function IsJSDocOptionalType(node:Node):Bool {
		return node.Kind == KindJSDocOptionalType;
	}

	public static function IsJSDocTypeTag(node:Node):Bool {
		return node.Kind == KindJSDocTypeTag;
	}

	public static function IsJSDocUnknownTag(node:Node):Bool {
		return node.Kind == KindJSDocUnknownTag;
	}

	public static function IsJSDocTemplateTag(node:Node):Bool {
		return node.Kind == KindJSDocTemplateTag;
	}

	public static function IsJSDocReturnTag(node:Node):Bool {
		return node.Kind == KindJSDocReturnTag;
	}

	public static function IsJSDocPublicTag(node:Node):Bool {
		return node.Kind == KindJSDocPublicTag;
	}

	public static function IsJSDocPrivateTag(node:Node):Bool {
		return node.Kind == KindJSDocPrivateTag;
	}

	public static function IsJSDocProtectedTag(node:Node):Bool {
		return node.Kind == KindJSDocProtectedTag;
	}

	public static function IsJSDocReadonlyTag(node:Node):Bool {
		return node.Kind == KindJSDocReadonlyTag;
	}

	public static function IsJSDocOverrideTag(node:Node):Bool {
		return node.Kind == KindJSDocOverrideTag;
	}

	public static function IsJSDocDeprecatedTag(node:Node):Bool {
		return node.Kind == KindJSDocDeprecatedTag;
	}

	public static function IsJSDocSeeTag(node:Node):Bool {
		return node.Kind == KindJSDocSeeTag;
	}

	public static function IsJSDocImplementsTag(node:Node):Bool {
		return node.Kind == KindJSDocImplementsTag;
	}

	public static function IsJSDocAugmentsTag(node:Node):Bool {
		return node.Kind == KindJSDocAugmentsTag;
	}

	public static function IsJSDocSatisfiesTag(node:Node):Bool {
		return node.Kind == KindJSDocSatisfiesTag;
	}

	public static function IsJSDocThrowsTag(node:Node):Bool {
		return node.Kind == KindJSDocThrowsTag;
	}

	public static function IsJSDocThisTag(node:Node):Bool {
		return node.Kind == KindJSDocThisTag;
	}

	public static function IsJSDocImportTag(node:Node):Bool {
		return node.Kind == KindJSDocImportTag;
	}

	public static function IsJSDocCallbackTag(node:Node):Bool {
		return node.Kind == KindJSDocCallbackTag;
	}

	public static function IsJSDocOverloadTag(node:Node):Bool {
		return node.Kind == KindJSDocOverloadTag;
	}

	public static function IsJSDocTypedefTag(node:Node):Bool {
		return node.Kind == KindJSDocTypedefTag;
	}

	public static function IsJSDocSignature(node:Node):Bool {
		return node.Kind == KindJSDocSignature;
	}

	public static function IsJSDocNameReference(node:Node):Bool {
		return node.Kind == KindJSDocNameReference;
	}

	public static function IsSourceFile(node:Node):Bool {
		return node.Kind == KindSourceFile;
	}

	public static function IsModuleDeclaration(node:Node):Bool {
		return node.Kind == KindModuleDeclaration;
	}

	public static function IsImportEqualsDeclaration(node:Node):Bool {
		return node.Kind == KindImportEqualsDeclaration;
	}

	public static function IsExportDeclaration(node:Node):Bool {
		return node.Kind == KindExportDeclaration;
	}

	public static function IsImportTypeNode(node:Node):Bool {
		return node.Kind == KindImportType;
	}

	public static function IsImportClause(node:Node):Bool {
		return node.Kind == KindImportClause;
	}

	public static function IsImportSpecifier(node:Node):Bool {
		return node.Kind == KindImportSpecifier;
	}

	public static function IsJSDocText(node:Node):Bool {
		return node.Kind == KindJSDocText;
	}

	public static function IsJSDocLink(node:Node):Bool {
		return node.Kind == KindJSDocLink;
	}

	public static function IsJSDocLinkPlain(node:Node):Bool {
		return node.Kind == KindJSDocLinkPlain;
	}

	public static function IsJSDocLinkCode(node:Node):Bool {
		return node.Kind == KindJSDocLinkCode;
	}

	public static function IsTypeParameterDeclaration(node:Node):Bool {
		return node.Kind == KindTypeParameter;
	}

	public static function IsSyntheticReferenceExpression(node:Node):Bool {
		return node.Kind == KindSyntheticReferenceExpression;
	}

	public static function IsJSDocTypeLiteral(node:Node):Bool {
		return node.Kind == KindJSDocTypeLiteral;
	}

	public static function IsJSDocParameterTag(node:Node):Bool {
		return node.Kind == KindJSDocParameterTag;
	}

	public static function IsJSDocPropertyTag(node:Node):Bool {
		return node.Kind == KindJSDocPropertyTag;
	}

	// --- ast_generated.go: kind alias guards ---

	public static function IsTriviaKind(kind:Kind):Bool {
		switch (kind) {
			case KindSingleLineCommentTrivia | KindMultiLineCommentTrivia | KindNewLineTrivia | KindWhitespaceTrivia | KindConflictMarkerTrivia:
				return true;
			default:
		}
		return false;
	}

	public static function IsLiteralKind(kind:Kind):Bool {
		return kind >= KindFirstLiteralToken && kind <= KindLastLiteralToken;
	}

	public static function IsPseudoLiteralKind(kind:Kind):Bool {
		switch (kind) {
			case KindTemplateHead | KindTemplateMiddle | KindTemplateTail:
				return true;
			default:
		}
		return false;
	}

	public static function IsPunctuationKind(kind:Kind):Bool {
		return kind >= KindFirstPunctuation && kind <= KindLastPunctuation;
	}

	public static function IsKeywordKind(kind:Kind):Bool {
		return kind >= KindFirstKeyword && kind <= KindLastKeyword;
	}

	public static function IsModifierKind(kind:Kind):Bool {
		switch (kind) {
			case KindAbstractKeyword | KindAccessorKeyword | KindAsyncKeyword | KindConstKeyword | KindDeclareKeyword | KindDefaultKeyword | KindExportKeyword | KindInKeyword | KindPrivateKeyword | KindProtectedKeyword | KindPublicKeyword | KindReadonlyKeyword | KindOutKeyword | KindOverrideKeyword | KindStaticKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsKeywordTypeKind(kind:Kind):Bool {
		switch (kind) {
			case KindAnyKeyword | KindBigIntKeyword | KindBooleanKeyword | KindIntrinsicKeyword | KindNeverKeyword | KindNumberKeyword | KindObjectKeyword | KindStringKeyword | KindSymbolKeyword | KindUndefinedKeyword | KindUnknownKeyword | KindVoidKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsKeywordExpressionKind(kind:Kind):Bool {
		switch (kind) {
			case KindNullKeyword | KindTrueKeyword | KindFalseKeyword | KindThisKeyword | KindSuperKeyword | KindImportKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsTokenKind(kind:Kind):Bool {
		return kind >= KindFirstToken && kind <= KindLastToken;
	}

	public static function IsJsxTokenKind(kind:Kind):Bool {
		switch (kind) {
			case KindLessThanSlashToken | KindEndOfFile | KindConflictMarkerTrivia | KindJsxText | KindJsxTextAllWhiteSpaces | KindOpenBraceToken | KindLessThanToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsJSDocNodeKind(kind:Kind):Bool {
		return kind >= KindFirstJSDocNode && kind <= KindLastJSDocNode;
	}

	public static function IsImportPhaseModifierKind(kind:Kind):Bool {
		switch (kind) {
			case KindTypeKeyword | KindDeferKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsPostfixUnaryOperator(kind:Kind):Bool {
		switch (kind) {
			case KindPlusPlusToken | KindMinusMinusToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsPrefixUnaryOperator(kind:Kind):Bool {
		switch (kind) {
			case KindPlusToken | KindMinusToken | KindTildeToken | KindExclamationToken | KindPlusPlusToken | KindMinusMinusToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsAssignmentOperator(kind:Kind):Bool {
		switch (kind) {
			case KindEqualsToken | KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskAsteriskEqualsToken | KindAsteriskEqualsToken | KindSlashEqualsToken | KindPercentEqualsToken | KindAmpersandEqualsToken | KindBarEqualsToken | KindCaretEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanGreaterThanEqualsToken | KindGreaterThanGreaterThanEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsBinaryOperator(kind:Kind):Bool {
		switch (kind) {
			case KindQuestionQuestionToken | KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword | KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken | KindAmpersandToken | KindBarToken | KindCaretToken | KindAmpersandAmpersandToken | KindBarBarToken | KindEqualsToken | KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskAsteriskEqualsToken | KindAsteriskEqualsToken | KindSlashEqualsToken | KindPercentEqualsToken | KindAmpersandEqualsToken | KindBarEqualsToken | KindCaretEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanGreaterThanEqualsToken | KindGreaterThanGreaterThanEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken | KindCommaToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsExponentiationOperator(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsMultiplicativeOperator(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskToken | KindSlashToken | KindPercentToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsMultiplicativeOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsAdditiveOperator(kind:Kind):Bool {
		switch (kind) {
			case KindPlusToken | KindMinusToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsAdditiveOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsShiftOperator(kind:Kind):Bool {
		switch (kind) {
			case KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsShiftOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsRelationalOperator(kind:Kind):Bool {
		switch (kind) {
			case KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsRelationalOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword:
				return true;
			default:
		}
		return false;
	}

	public static function IsEqualityOperator(kind:Kind):Bool {
		switch (kind) {
			case KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsEqualityOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword | KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsBitwiseOperator(kind:Kind):Bool {
		switch (kind) {
			case KindAmpersandToken | KindBarToken | KindCaretToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsBitwiseOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword | KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken | KindAmpersandToken | KindBarToken | KindCaretToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsLogicalOperator(kind:Kind):Bool {
		switch (kind) {
			case KindAmpersandAmpersandToken | KindBarBarToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsLogicalOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword | KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken | KindAmpersandToken | KindBarToken | KindCaretToken | KindAmpersandAmpersandToken | KindBarBarToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsCompoundAssignmentOperator(kind:Kind):Bool {
		switch (kind) {
			case KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskAsteriskEqualsToken | KindAsteriskEqualsToken | KindSlashEqualsToken | KindPercentEqualsToken | KindAmpersandEqualsToken | KindBarEqualsToken | KindCaretEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanGreaterThanEqualsToken | KindGreaterThanGreaterThanEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsAssignmentOperatorOrHigher(kind:Kind):Bool {
		switch (kind) {
			case KindQuestionQuestionToken | KindAsteriskAsteriskToken | KindAsteriskToken | KindSlashToken | KindPercentToken | KindPlusToken | KindMinusToken | KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken | KindLessThanToken | KindLessThanEqualsToken | KindGreaterThanToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword | KindEqualsEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken | KindExclamationEqualsToken | KindAmpersandToken | KindBarToken | KindCaretToken | KindAmpersandAmpersandToken | KindBarBarToken | KindEqualsToken | KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskAsteriskEqualsToken | KindAsteriskEqualsToken | KindSlashEqualsToken | KindPercentEqualsToken | KindAmpersandEqualsToken | KindBarEqualsToken | KindCaretEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanGreaterThanEqualsToken | KindGreaterThanGreaterThanEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken:
				return true;
			default:
		}
		return false;
	}

	public static function IsLogicalOrCoalescingAssignmentOperator(kind:Kind):Bool {
		switch (kind) {
			case KindAmpersandAmpersandEqualsToken | KindBarBarEqualsToken | KindQuestionQuestionEqualsToken:
				return true;
			default:
		}
		return false;
	}
	// END GENERATED: is

	// --- deepclone.go ---

	// Ideally, this would get cached on the node factory so there's only ever one set of closures made per factory
	static function getDeepCloneVisitor(f:NodeFactory, syntheticLocation:Bool):NodeVisitor {
		var visitor:NodeVisitor = null;
		final hooks = new NodeVisitorHooks();
		hooks.VisitNodes = function(nodes:NodeList, v:NodeVisitor):NodeList {
			if (nodes == null) {
				return null;
			}
			final visited = v.VisitNodes(nodes);
			var newList:NodeList;
			if (visited != nodes) {
				newList = visited;
			} else {
				newList = nodes.Clone(v.Factory);
			}
			if (syntheticLocation) {
				newList.Loc = Core.NewTextRange(-1, -1);
				if (nodes.HasTrailingComma()) {
					newList.Nodes[newList.Nodes.length - 1].Loc = Core.NewTextRange(-2, -2);
				}
			}
			return newList;
		};
		hooks.VisitModifiers = function(nodes:ModifierList, v:NodeVisitor):ModifierList {
			if (nodes == null) {
				return null;
			}
			final visited = v.VisitModifiers(nodes);
			var newList:ModifierList;
			if (visited != nodes) {
				newList = visited;
			} else {
				newList = nodes.Clone(v.Factory);
			}
			if (syntheticLocation) {
				newList.Loc = Core.NewTextRange(-1, -1);
				if (nodes.HasTrailingComma()) {
					newList.Nodes[newList.Nodes.length - 1].Loc = Core.NewTextRange(-2, -2);
				}
			}
			return newList;
		};
		visitor = NewNodeVisitor(function(node:Node):Node {
			final visited = visitor.VisitEachChild(node);
			if (visited != node) {
				if (syntheticLocation) {
					visited.Loc = Core.NewTextRange(-1, -1);
				}
				return visited;
			}
			final c = node.Clone(f); // forcibly clone leaf nodes, which will then cascade new nodes/arrays upwards via `update` calls
			// In strada, `factory.cloneNode` was dynamic and did _not_ clone positions for any "special cases", meanwhile
			// Node.Clone in corsa reliably uses `Update` calls for all nodes and so copies locations by default.
			// Deep clones are done to copy a node across files, so here, we explicitly make the location range synthetic on all cloned nodes
			if (syntheticLocation) {
				c.Loc = Core.NewTextRange(-1, -1);
			}
			return c;
		}, f, hooks);
		return visitor;
	}

	// --- diagnostic.go ---

	public static function NewDiagnosticFromSerialized(file:SourceFile, loc:TextRange, code:Int, category:Category, messageKey:Key,
			messageArgs:Array<String>, messageChain:Array<Diagnostic>, relatedInformation:Array<Diagnostic>, reportsUnnecessary:Bool,
			reportsDeprecated:Bool, skippedOnNoEmit:Bool):Diagnostic {
		final d = new Diagnostic();
		d.file = file;
		d.loc = loc;
		d.code = code;
		d.category = category;
		d.messageKey = messageKey;
		d.messageArgs = messageArgs;
		d.messageChain = messageChain;
		d.relatedInformation = relatedInformation;
		d.reportsUnnecessary = reportsUnnecessary;
		d.reportsDeprecated = reportsDeprecated;
		d.skippedOnNoEmit = skippedOnNoEmit;
		return d;
	}

	public static function NewDiagnostic(file:SourceFile, loc:TextRange, message:Message, ...args:Any):Diagnostic {
		final d = new Diagnostic();
		d.file = file;
		d.loc = loc;
		d.code = message.Code();
		d.category = message.Category();
		d.message = message;
		d.messageKey = message.Key();
		d.messageArgs = Diagnostics.StringifyArgs(args.toArray());
		d.reportsUnnecessary = message.ReportsUnnecessary();
		d.reportsDeprecated = message.ReportsDeprecated();
		return d;
	}

	public static function NewDiagnosticChain(chain:Diagnostic, message:Message, ...args:Any):Diagnostic {
		if (chain != null) {
			return NewDiagnostic(chain.file, chain.loc, message, ...args).AddMessageChain(chain).SetRelatedInfo(chain.relatedInformation);
		}
		return NewDiagnostic(null, new TextRange(0, 0), message, ...args);
	}

	public static function NewCompilerDiagnostic(message:Message, ...args:Any):Diagnostic {
		return NewDiagnostic(null, Core.UndefinedTextRange(), message, ...args);
	}

	static function getDiagnosticPath(d:Diagnostic):String {
		if (d.File() != null) {
			return d.File().FileName();
		}
		return "";
	}

	public static function EqualDiagnostics(d1:Diagnostic, d2:Diagnostic):Bool {
		if (d1 == d2) {
			return true;
		}
		return EqualDiagnosticsNoRelatedInfo(d1, d2) && Slices.EqualFunc(d1.RelatedInformation(), d2.RelatedInformation(), EqualDiagnostics);
	}

	public static function EqualDiagnosticsNoRelatedInfo(d1:Diagnostic, d2:Diagnostic):Bool {
		if (d1 == d2) {
			return true;
		}
		return getDiagnosticPath(d1) == getDiagnosticPath(d2)
			&& d1.Loc().Equals(d2.Loc())
			&& d1.Code() == d2.Code()
			&& Slices.Equal(d1.MessageArgs(), d2.MessageArgs())
			&& Slices.EqualFunc(d1.MessageChain(), d2.MessageChain(), equalMessageChain);
	}

	static function equalMessageChain(c1:Diagnostic, c2:Diagnostic):Bool {
		if (c1 == c2) {
			return true;
		}
		return c1.Code() == c2.Code()
			&& Slices.Equal(c1.MessageArgs(), c2.MessageArgs())
			&& Slices.EqualFunc(c1.MessageChain(), c2.MessageChain(), equalMessageChain);
	}

	static function compareMessageChainSize(c1:Array<Diagnostic>, c2:Array<Diagnostic>):Int {
		var c = Core.len(c2) - Core.len(c1);
		if (c != 0) {
			return c;
		}
		for (i in 0...Core.len(c1)) {
			c = compareMessageChainSize(c1[i].MessageChain(), c2[i].MessageChain());
			if (c != 0) {
				return c;
			}
		}
		return 0;
	}

	static function compareMessageChainContent(c1:Array<Diagnostic>, c2:Array<Diagnostic>):Int {
		for (i in 0...Core.len(c1)) {
			var c = Slices.Compare(c1[i].MessageArgs(), c2[i].MessageArgs());
			if (c != 0) {
				return c;
			}
			if (c1[i].MessageChain() != null) {
				c = compareMessageChainContent(c1[i].MessageChain(), c2[i].MessageChain());
				if (c != 0) {
					return c;
				}
			}
		}
		return 0;
	}

	static function compareRelatedInfo(r1:Array<Diagnostic>, r2:Array<Diagnostic>):Int {
		var c = Core.len(r2) - Core.len(r1);
		if (c != 0) {
			return c;
		}
		for (i in 0...Core.len(r1)) {
			c = CompareDiagnostics(r1[i], r2[i]);
			if (c != 0) {
				return c;
			}
		}
		return 0;
	}

	public static function CompareDiagnostics(d1:Diagnostic, d2:Diagnostic):Int {
		if (d1 == d2) {
			return 0;
		}
		var c = Strings.Compare(getDiagnosticPath(d1), getDiagnosticPath(d2));
		if (c != 0) {
			return c;
		}
		c = d1.Loc().Pos() - d2.Loc().Pos();
		if (c != 0) {
			return c;
		}
		c = d1.Loc().End() - d2.Loc().End();
		if (c != 0) {
			return c;
		}
		c = d1.Code() - d2.Code();
		if (c != 0) {
			return c;
		}
		c = Slices.Compare(d1.MessageArgs(), d2.MessageArgs());
		if (c != 0) {
			return c;
		}
		c = compareMessageChainSize(d1.MessageChain(), d2.MessageChain());
		if (c != 0) {
			return c;
		}
		c = compareMessageChainContent(d1.MessageChain(), d2.MessageChain());
		if (c != 0) {
			return c;
		}
		return compareRelatedInfo(d1.RelatedInformation(), d2.RelatedInformation());
	}

	// --- flow.go ---

	public static function NewFlowSwitchClauseData(switchStatement:Node, clauseStart:Int, clauseEnd:Int):Node {
		final node = new FlowSwitchClauseData();
		node.SwitchStatement = switchStatement;
		node.ClauseStart = clauseStart;
		node.ClauseEnd = clauseEnd;
		return newNode(KindUnknown, node, new NodeFactoryHooks());
	}

	public static function NewFlowReduceLabelData(target:FlowLabel, antecedents:FlowList):Node {
		final node = new FlowReduceLabelData();
		node.Target = target;
		node.Antecedents = antecedents;
		return newNode(KindUnknown, node, new NodeFactoryHooks());
	}

	// --- functionflags.go ---

	public static function GetFunctionFlags(node:Node):FunctionFlags {
		if (node == null) {
			return FunctionFlagsInvalid;
		}
		final data = node.BodyData();
		if (data == null) {
			return FunctionFlagsInvalid;
		}
		var flags = FunctionFlagsNormal;
		switch (node.Kind) {
			case KindFunctionDeclaration | KindFunctionExpression | KindMethodDeclaration:
				if (data.AsteriskToken != null) {
					flags |= FunctionFlagsGenerator;
				}
				// PORT: fallthrough into the KindArrowFunction case (duplicated body).
				if (HasSyntacticModifier(node, ModifierFlagsAsync)) {
					flags |= FunctionFlagsAsync;
				}
			case KindArrowFunction:
				if (HasSyntacticModifier(node, ModifierFlagsAsync)) {
					flags |= FunctionFlagsAsync;
				}
			default:
		}
		if (data.Body == null) {
			flags |= FunctionFlagsInvalid;
		}
		return flags;
	}

	// --- parseoptions.go ---

	public static function GetExternalModuleIndicatorOptions(fileName:String, options:CompilerOptions, metadata:SourceFileMetaData):ExternalModuleIndicatorOptions {
		if (Tspath.IsDeclarationFileName(fileName)) {
			return new ExternalModuleIndicatorOptions();
		}

		switch (options.GetEmitModuleDetectionKind()) {
			case ModuleDetectionKindForce:
				// All non-declaration files are modules, declaration files still do the usual isFileProbablyExternalModule
				return new ExternalModuleIndicatorOptions(false, true);
			case ModuleDetectionKindLegacy:
				// Files are modules if they have imports, exports, or import.meta
				return new ExternalModuleIndicatorOptions();
			case ModuleDetectionKindAuto:
				// If module is nodenext or node16, all esm format files are modules
				// If jsx is react-jsx or react-jsxdev then jsx tags force module-ness
				// otherwise, the presence of import or export statments (or import.meta) implies module-ness
				return new ExternalModuleIndicatorOptions(options.Jsx == JsxEmitReactJSX || options.Jsx == JsxEmitReactJSXDev,
					isFileForcedToBeModuleByFormat(fileName, options, metadata));
			default:
				return new ExternalModuleIndicatorOptions();
		}
	}

	static final isFileForcedToBeModuleByFormatExtensions:Array<String> = [
		Tspath.ExtensionCjs,
		Tspath.ExtensionCts,
		Tspath.ExtensionMjs,
		Tspath.ExtensionMts
	];

	static function isFileForcedToBeModuleByFormat(fileName:String, options:CompilerOptions, metadata:SourceFileMetaData):Bool {
		// Excludes declaration files - they still require an explicit `export {}` or the like
		// for back compat purposes. The only non-declaration files _not_ forced to be a module are `.js` files
		// that aren't esm-mode (meaning not in a `type: module` scope).
		if (GetImpliedNodeFormatForEmitWorker(fileName, options.GetEmitModuleKind(), metadata) == ModuleKindESNext
			|| Tspath.FileExtensionIsOneOf(fileName, isFileForcedToBeModuleByFormatExtensions)) {
			return true;
		}
		return false;
	}

	public static function SetExternalModuleIndicator(file:SourceFile, opts:ExternalModuleIndicatorOptions):Void {
		file.ExternalModuleIndicator = getExternalModuleIndicator(file, opts);
	}

	static function getExternalModuleIndicator(file:SourceFile, opts:ExternalModuleIndicatorOptions):Node {
		if (file.ScriptKind == ScriptKindJSON) {
			return null;
		}

		final node = isFileProbablyExternalModule(file);
		if (node != null) {
			return node;
		}

		if (file.IsDeclarationFile) {
			return null;
		}

		if (opts.JSX) {
			final node = isFileModuleFromUsingJSXTag(file);
			if (node != null) {
				return node;
			}
		}

		if (opts.Force) {
			return file.AsNode();
		}

		return null;
	}

	static function isFileProbablyExternalModule(sourceFile:SourceFile):Node {
		// PORT: Go ranges over a nil slice (empty file) without a check.
		if (sourceFile.Statements.Nodes != null) {
			for (statement in sourceFile.Statements.Nodes) {
				if (isAnExternalModuleIndicatorNode(statement)) {
					return statement;
				}
			}
		}
		return getImportMetaIfNecessary(sourceFile);
	}

	static function isAnExternalModuleIndicatorNode(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsExport)
			|| IsImportEqualsDeclaration(node) && IsExternalModuleReference(node.AsImportEqualsDeclaration().ModuleReference)
			|| IsImportDeclaration(node)
			|| IsExportAssignment(node)
			|| IsExportDeclaration(node);
	}

	static function getImportMetaIfNecessary(sourceFile:SourceFile):Node {
		if (sourceFile.AsNode().Flags & NodeFlagsPossiblyContainsImportMeta != 0) {
			return findChildNode(sourceFile.AsNode(), IsImportMeta);
		}
		return null;
	}

	static function findChildNode(root:Node, check:(Node) -> Bool):Node {
		var result:Node = null;
		var visit:(Node) -> Bool = null;
		visit = function(node:Node):Bool {
			if (check(node)) {
				result = node;
				return true;
			}
			return node.ForEachChild(visit);
		};
		visit(root);
		return result;
	}

	static function isFileModuleFromUsingJSXTag(file:SourceFile):Node {
		return walkTreeForJSXTags(file.AsNode());
	}

	// This is a somewhat unavoidable full tree walk to locate a JSX tag - `import.meta` requires the same,
	// but we avoid that walk (or parts of it) if at all possible using the `PossiblyContainsImportMeta` node flag.
	// Unfortunately, there's no `NodeFlag` space to do the same for JSX.
	static function walkTreeForJSXTags(node:Node):Node {
		var found:Node = null;

		var visitor:(Node) -> Bool = null;
		visitor = function(node:Node):Bool {
			if (found != null) {
				return true;
			}
			if (node.SubtreeFacts() & SubtreeContainsJsx == 0) {
				return false;
			}
			if (IsJsxOpeningLikeElement(node) || IsJsxFragment(node)) {
				found = node;
				return true;
			}
			return node.ForEachChild(visitor);
		};
		visitor(node);

		return found;
	}

	// --- positionmap.go ---

	// ComputePositionMap builds a PositionMap for the given text.
	// PORT: Go walks the UTF-8 bytes; here the UTF-16 code units, computing the UTF-8 size of each
	// code point (a lone surrogate counts 3 bytes, like Go's WTF-8 sentinel). See Positionmap.hx.
	public static function ComputePositionMap(text:String):PositionMap {
		final pm = new PositionMap();
		var delta = 0;
		var utf8Pos = 0; // byte offset of code unit i
		var i = 0;
		while (i < text.length) {
			final b = StringTools.fastCodeAt(text, i);
			if (b < Utf16.RuneSelf) {
				i++;
				utf8Pos++;
				continue;
			}
			final r = Stringutil.DecodeJSStringRune(text, i);
			final utf16Size = r >= 0x10000 ? 2 : 1;
			final size = r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4);
			delta += size - utf16Size;
			if (pm.entries == null)
				pm.entries = [];
			pm.entries.push(new PositionMapEntry(utf8Pos + size, delta));
			i += utf16Size;
			utf8Pos += size;
		}
		pm.asciiOnly = Core.len(pm.entries) == 0;
		return pm;
	}

	// --- precedence.go ---

	static function getOperator(expression:Expression):Kind {
		switch (expression.Kind) {
			case KindBinaryExpression:
				return expression.AsBinaryExpression().OperatorToken.Kind;
			case KindPrefixUnaryExpression:
				return expression.AsPrefixUnaryExpression().Operator;
			case KindPostfixUnaryExpression:
				return expression.AsPostfixUnaryExpression().Operator;
			default:
				return expression.Kind;
		}
	}

	// Gets the precedence of an expression
	public static function GetExpressionPrecedence(expression:Expression):OperatorPrecedence {
		final operator_ = getOperator(expression);
		var flags:OperatorPrecedenceFlags = OperatorPrecedenceFlagsNone;
		if (expression.Kind == KindNewExpression && expression.ArgumentList() == null) {
			flags = OperatorPrecedenceFlagsNewWithoutArguments;
		} else if (IsOptionalChain(expression)) {
			flags = OperatorPrecedenceFlagsOptionalChain;
		}
		return GetOperatorPrecedence(expression.Kind, operator_, flags);
	}

	// Gets the precedence of an operator
	public static function GetOperatorPrecedence(nodeKind:Kind, operatorKind:Kind, flags:OperatorPrecedenceFlags):OperatorPrecedence {
		switch (nodeKind) {
			case KindSpreadElement:
				return OperatorPrecedenceSpread;
			case KindYieldExpression:
				return OperatorPrecedenceYield;
			// !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
			case KindArrowFunction:
				return OperatorPrecedenceAssignment;
			case KindConditionalExpression:
				return OperatorPrecedenceConditional;
			case KindBinaryExpression:
				switch (operatorKind) {
					case KindCommaToken:
						return OperatorPrecedenceComma;

					case KindEqualsToken | KindPlusEqualsToken | KindMinusEqualsToken | KindAsteriskAsteriskEqualsToken | KindAsteriskEqualsToken |
						KindSlashEqualsToken | KindPercentEqualsToken | KindLessThanLessThanEqualsToken | KindGreaterThanGreaterThanEqualsToken |
						KindGreaterThanGreaterThanGreaterThanEqualsToken | KindAmpersandEqualsToken | KindCaretEqualsToken | KindBarEqualsToken |
						KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken:
						return OperatorPrecedenceAssignment;

					default:
						return GetBinaryOperatorPrecedence(operatorKind);
				}
			// TODO: Should prefix `++` and `--` be moved to the `Update` precedence?
			case KindTypeAssertionExpression | KindNonNullExpression | KindPrefixUnaryExpression | KindTypeOfExpression | KindVoidExpression |
				KindDeleteExpression | KindAwaitExpression:
				return OperatorPrecedenceUnary;

			case KindPostfixUnaryExpression:
				return OperatorPrecedenceUpdate;

			// !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
			case KindPropertyAccessExpression | KindElementAccessExpression:
				if (flags & OperatorPrecedenceFlagsOptionalChain != 0) {
					return OperatorPrecedenceOptionalChain;
				}
				return OperatorPrecedenceMember;

			case KindCallExpression:
				if (flags & OperatorPrecedenceFlagsOptionalChain != 0) {
					return OperatorPrecedenceOptionalChain;
				}
				return OperatorPrecedenceMember;

			// !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
			case KindNewExpression:
				if (flags & OperatorPrecedenceFlagsNewWithoutArguments != 0) {
					return OperatorPrecedenceLeftHandSide;
				}
				return OperatorPrecedenceMember;

			// !!! By necessity, this differs from the old compiler to better align with ParenthesizerRules. consider backporting
			case KindTaggedTemplateExpression | KindMetaProperty | KindExpressionWithTypeArguments:
				return OperatorPrecedenceMember;

			case KindAsExpression | KindSatisfiesExpression:
				return OperatorPrecedenceRelational;

			case KindThisKeyword | KindSuperKeyword | KindImportKeyword | KindIdentifier | KindPrivateIdentifier | KindNullKeyword | KindTrueKeyword |
				KindFalseKeyword | KindNumericLiteral | KindBigIntLiteral | KindStringLiteral | KindArrayLiteralExpression | KindObjectLiteralExpression |
				KindFunctionExpression | KindClassExpression | KindRegularExpressionLiteral | KindNoSubstitutionTemplateLiteral | KindTemplateExpression |
				KindOmittedExpression | KindJsxElement | KindJsxSelfClosingElement | KindJsxFragment | KindMissingDeclaration:
				return OperatorPrecedencePrimary;

			// !!! By necessity, this differs from the old compiler to support emit. consider backporting
			case KindParenthesizedExpression:
				return OperatorPrecedenceParentheses;

			default:
				return OperatorPrecedenceInvalid;
		}
	}

	// Gets the precedence of a binary operator
	public static function GetBinaryOperatorPrecedence(operatorKind:Kind):OperatorPrecedence {
		switch (operatorKind) {
			case KindQuestionQuestionToken:
				return OperatorPrecedenceCoalesce;
			case KindBarBarToken:
				return OperatorPrecedenceLogicalOR;
			case KindAmpersandAmpersandToken:
				return OperatorPrecedenceLogicalAND;
			case KindBarToken:
				return OperatorPrecedenceBitwiseOR;
			case KindCaretToken:
				return OperatorPrecedenceBitwiseXOR;
			case KindAmpersandToken:
				return OperatorPrecedenceBitwiseAND;
			case KindEqualsEqualsToken | KindExclamationEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken:
				return OperatorPrecedenceEquality;
			case KindLessThanToken | KindGreaterThanToken | KindLessThanEqualsToken | KindGreaterThanEqualsToken | KindInstanceOfKeyword | KindInKeyword |
				KindAsKeyword | KindSatisfiesKeyword:
				return OperatorPrecedenceRelational;
			case KindLessThanLessThanToken | KindGreaterThanGreaterThanToken | KindGreaterThanGreaterThanGreaterThanToken:
				return OperatorPrecedenceShift;
			case KindPlusToken | KindMinusToken:
				return OperatorPrecedenceAdditive;
			case KindAsteriskToken | KindSlashToken | KindPercentToken:
				return OperatorPrecedenceMultiplicative;
			case KindAsteriskAsteriskToken:
				return OperatorPrecedenceExponentiation;
			default:
		}
		// -1 is lower than all other precedences.  Returning it will cause binary expression
		// parsing to stop.
		return OperatorPrecedenceInvalid;
	}

	// Gets the leftmost expression of an expression, e.g. `a` in `a.b`, `a[b]`, `a++`, `a+b`, `a?b:c`, `a as B`, etc.
	public static function GetLeftmostExpression(node:Expression, stopAtCallExpressions:Bool):Expression {
		while (true) {
			switch (node.Kind) {
				case KindPostfixUnaryExpression:
					node = node.AsPostfixUnaryExpression().Operand;
					continue;
				case KindBinaryExpression:
					node = node.AsBinaryExpression().Left;
					continue;
				case KindConditionalExpression:
					node = node.AsConditionalExpression().Condition;
					continue;
				case KindTaggedTemplateExpression:
					node = node.AsTaggedTemplateExpression().Tag;
					continue;
				case KindCallExpression:
					if (stopAtCallExpressions) {
						return node;
					}
					// PORT: `fallthrough` into the next case → its body duplicated.
					node = node.Expression();
					continue;
				case KindAsExpression | KindElementAccessExpression | KindPropertyAccessExpression | KindNonNullExpression |
					KindPartiallyEmittedExpression | KindSatisfiesExpression:
					node = node.Expression();
					continue;
				default:
			}
			return node;
		}
	}

	// Gets the precedence of a TypeNode
	public static function GetTypeNodePrecedence(n:TypeNode):TypePrecedence {
		switch (n.Kind) {
			case KindConditionalType:
				return TypePrecedenceConditional;
			case KindJSDocOptionalType | KindJSDocVariadicType:
				return TypePrecedenceJSDoc;
			case KindFunctionType | KindConstructorType:
				return TypePrecedenceFunction;
			case KindUnionType:
				return TypePrecedenceUnion;
			case KindIntersectionType:
				return TypePrecedenceIntersection;
			case KindTypeOperator:
				return TypePrecedenceTypeOperator;
			case KindInferType:
				if (n.AsInferTypeNode().TypeParameter.AsTypeParameterDeclaration().Constraint != null) {
					// `infer T extends U` must be treated as FunctionTypeNode precedence as the `extends` clause eagerly consumes
					// TypeNode
					return TypePrecedenceFunction;
				}
				return TypePrecedenceTypeOperator;
			case KindIndexedAccessType | KindArrayType | KindOptionalType:
				return TypePrecedencePostfix;
			case KindTypeQuery:
				// TypeQueryNode is actually a NonArrayType, but we treat it as TypeOperatorNode
				// precedence so that it is parenthesized when used in a PostfixType
				// context (e.g., `(typeof C)[]` instead of `typeof C[]`)
				return TypePrecedenceTypeOperator;
			case KindAnyKeyword | KindUnknownKeyword | KindStringKeyword | KindNumberKeyword | KindBigIntKeyword | KindSymbolKeyword | KindBooleanKeyword |
				KindUndefinedKeyword | KindNeverKeyword | KindObjectKeyword | KindIntrinsicKeyword | KindVoidKeyword | KindJSDocAllType |
				KindJSDocNullableType | KindJSDocNonNullableType | KindLiteralType | KindTypePredicate | KindTypeReference | KindTypeLiteral |
				KindTupleType | KindRestType | KindParenthesizedType | KindThisType | KindMappedType | KindNamedTupleMember | KindTemplateLiteralType |
				KindImportType |
				// These occur in pseudo-types like `f<T>.C`, where `f` is a generic function and `C` is a local type
				KindPropertyAccessExpression | KindExpressionWithTypeArguments:
				return TypePrecedenceNonArray;
			default:
				throw "unhandled TypeNode: " + n.Kind.String();
		}
	}

	// --- subtreefacts.go ---

	static function propagateEraseableSyntaxListSubtreeFacts(children:TypeArgumentList):SubtreeFacts {
		return Core.IfElse(children != null, SubtreeContainsTypeScript, SubtreeFactsNone);
	}

	static function propagateEraseableSyntaxSubtreeFacts(child:TypeNode):SubtreeFacts {
		return Core.IfElse(child != null, SubtreeContainsTypeScript, SubtreeFactsNone);
	}

	static function propagateObjectBindingElementSubtreeFacts(child:BindingElementNode):SubtreeFacts {
		var facts = propagateSubtreeFacts(child);
		if (facts & SubtreeContainsRestOrSpread != 0) {
			facts = facts & ~SubtreeContainsRestOrSpread;
			facts |= SubtreeContainsObjectRestOrSpread | SubtreeContainsESObjectRestOrSpread;
		}
		return facts;
	}

	static function propagateBindingElementSubtreeFacts(child:BindingElementNode):SubtreeFacts {
		return propagateSubtreeFacts(child) & ~SubtreeContainsRestOrSpread;
	}

	static function propagateSubtreeFacts(child:Node):SubtreeFacts {
		if (child == null) {
			return SubtreeFactsNone;
		}
		return child.propagateSubtreeFacts();
	}

	// PORT: function values created once (PORTING.md §7a); Go passes the functions themselves.
	static final propagateSubtreeFactsFunc:(Node) -> SubtreeFacts = propagateSubtreeFacts;
	static final propagateObjectBindingElementSubtreeFactsFunc:(Node) -> SubtreeFacts = propagateObjectBindingElementSubtreeFacts;
	static final propagateBindingElementSubtreeFactsFunc:(Node) -> SubtreeFacts = propagateBindingElementSubtreeFacts;

	static function propagateNodeListSubtreeFacts(children:NodeList, propagate:(Node) -> SubtreeFacts):SubtreeFacts {
		if (children == null || children.Nodes == null) {
			return SubtreeFactsNone;
		}
		var facts = SubtreeFactsNone;
		for (child in children.Nodes) {
			facts |= propagate(child);
		}
		return facts;
	}

	static function propagateModifierListSubtreeFacts(children:ModifierList):SubtreeFacts {
		if (children == null) {
			return SubtreeFactsNone;
		}
		// PORT: Go `&children.NodeList`: ModifierList extends NodeList.
		return propagateNodeListSubtreeFacts(children, propagateSubtreeFactsFunc);
	}

	// --- symbol.go ---

	// PORT: Go uses the byte "\xFE" (invalid UTF-8, never in an IdentifierName). Haxe strings are
	// UTF-16, so the prefix is U+FFFE (a noncharacter, never in an IdentifierName). One code unit,
	// like Go's one byte.
	public static inline final InternalSymbolNamePrefix = "\u{FFFE}";

	public static inline final InternalSymbolNameCall = InternalSymbolNamePrefix + "call"; // Call signatures
	public static inline final InternalSymbolNameConstructor = InternalSymbolNamePrefix + "constructor"; // Constructor implementations
	public static inline final InternalSymbolNameNew = InternalSymbolNamePrefix + "new"; // Constructor signatures
	public static inline final InternalSymbolNameIndex = InternalSymbolNamePrefix + "index"; // Index signatures
	public static inline final InternalSymbolNameExportStar = InternalSymbolNamePrefix + "export"; // Module export * declarations
	public static inline final InternalSymbolNameGlobal = InternalSymbolNamePrefix + "global"; // Global self-reference
	public static inline final InternalSymbolNameMissing = InternalSymbolNamePrefix + "missing"; // Indicates missing symbol
	public static inline final InternalSymbolNameType = InternalSymbolNamePrefix + "type"; // Anonymous type literal symbol
	public static inline final InternalSymbolNameObject = InternalSymbolNamePrefix + "object"; // Anonymous object literal declaration
	public static inline final InternalSymbolNameJSXAttributes = InternalSymbolNamePrefix + "jsxAttributes"; // Anonymous JSX attributes object literal declaration
	public static inline final InternalSymbolNameClass = InternalSymbolNamePrefix + "class"; // Unnamed class expression
	public static inline final InternalSymbolNameFunction = InternalSymbolNamePrefix + "function"; // Unnamed function expression
	public static inline final InternalSymbolNameComputed = InternalSymbolNamePrefix + "computed"; // Computed property name declaration with dynamic name
	public static inline final InternalSymbolNameAssignmentDeclaration = InternalSymbolNamePrefix + "assignment"; // Assignment declarations
	public static inline final InternalSymbolNameInstantiationExpression = InternalSymbolNamePrefix + "instantiationExpression"; // Instantiation expressions
	public static inline final InternalSymbolNameImportAttributes = InternalSymbolNamePrefix + "importAttributes";
	public static inline final InternalSymbolNameExportEquals = "export="; // Export assignment symbol
	public static inline final InternalSymbolNameDefault = "default"; // Default export symbol (technically not wholly internal, but included here for usability)
	public static inline final InternalSymbolNameThis = "this";
	public static inline final InternalSymbolNameModuleExports = "module.exports";

	public static function SymbolName(symbol:Symbol):String {
		if (symbol.ValueDeclaration != null && IsPrivateIdentifierClassElementDeclaration(symbol.ValueDeclaration)) {
			return symbol.ValueDeclaration.Name().Text();
		}
		return symbol.Name;
	}

	// EscapeAllInternalSymbolNames replaces internal symbol name markers ("\xFE") with "__".
	public static function EscapeAllInternalSymbolNames(name:String):String {
		return Strings.ReplaceAll(name, InternalSymbolNamePrefix, "__");
	}

	public static function EscapeInternalSymbolName(name:String):String {
		if (StringTools.startsWith(name, InternalSymbolNamePrefix)) {
			return "__" + name.substring(InternalSymbolNamePrefix.length);
		}
		return name;
	}

	// EscapeSymbolName converts a binder symbol name into its escaped "__String"
	// form. Internal names (prefixed with the "\xFE" sentinel) become "__"-prefixed,
	// and user names that already begin with "__" gain an extra leading underscore
	// so they can be distinguished from internal names.
	public static function EscapeSymbolName(name:String):String {
		if (StringTools.startsWith(name, InternalSymbolNamePrefix)) {
			return "__" + name.substring(InternalSymbolNamePrefix.length);
		}
		if (name.length >= 2 && StringTools.fastCodeAt(name, 0) == "_".code && StringTools.fastCodeAt(name, 1) == "_".code) {
			return "_" + name;
		}
		return name;
	}

	// --- utilities.go ---

	// Atomic ids

	// PORT: atomic.Uint64 → plain Int (single-threaded; ids fit in 32 bits).
	static var nextNodeId:Int = 0;
	static var nextSymbolId:Int = 0;

	public static function GetNodeId(node:Node):NodeId {
		var id = node.id;
		if (id == 0) {
			// Worst case, we burn a few ids if we have to CAS.
			// PORT: Add + CompareAndSwap → increment and store (single-threaded).
			nextNodeId++;
			id = nextNodeId;
			node.id = id;
		}
		return id;
	}

	public static function GetSymbolId(symbol:Symbol):SymbolId {
		var id = symbol.id;
		if (id == 0) {
			// Worst case, we burn a few ids if we have to CAS.
			// PORT: Add + CompareAndSwap → increment and store (single-threaded).
			nextSymbolId++;
			id = nextSymbolId;
			symbol.id = id;
		}
		return id;
	}

	// PORT: pointer: Go `data *SymbolTable` → a getter/setter pair for the field.
	public static function GetSymbolTable(get:() -> SymbolTable, set:(SymbolTable) -> Void):SymbolTable {
		if (get() == null) {
			set(new SymbolTable());
		}
		return get();
	}

	public static function GetMembers(symbol:Symbol):SymbolTable {
		return GetSymbolTable(() -> symbol.Members, t -> symbol.Members = t);
	}

	public static function GetExports(symbol:Symbol):SymbolTable {
		return GetSymbolTable(() -> symbol.Exports, t -> symbol.Exports = t);
	}

	public static function GetLocals(container:Node):SymbolTable {
		final data = container.LocalsContainerData();
		return GetSymbolTable(() -> data.Locals, t -> data.Locals = t);
	}

	// Determines if a node is missing (either `nil` or empty)
	public static function NodeIsMissing(node:Node):Bool {
		return node == null || node.Loc.Pos() == node.Loc.End() && node.Loc.Pos() >= 0 && node.Kind != KindEndOfFile;
	}

	// Determines if a node is present
	public static function NodeIsPresent(node:Node):Bool {
		return !NodeIsMissing(node);
	}

	// Determines if a node contains synthetic positions
	public static function NodeIsSynthesized(node:Node):Bool {
		return PositionIsSynthesized(node.Loc.Pos()) || PositionIsSynthesized(node.Loc.End());
	}

	public static function RangeIsSynthesized(loc:TextRange):Bool {
		return PositionIsSynthesized(loc.Pos()) || PositionIsSynthesized(loc.End());
	}

	// Determines whether a position is synthetic
	public static inline function PositionIsSynthesized(pos:Int):Bool {
		return pos < 0;
	}

	public static function FindLastVisibleNode(nodes:Array<Node>):Node {
		var fromEnd = 1;
		while (fromEnd <= Core.len(nodes) && nodes[nodes.length - fromEnd].Flags & NodeFlagsReparsed != 0) {
			fromEnd++;
		}
		if (fromEnd <= Core.len(nodes)) {
			return nodes[nodes.length - fromEnd];
		}
		return null;
	}

	public static function NodeKindIs(node:Node, ...kinds:Kind):Bool {
		// PORT: perf — slices.Contains(kinds, node.Kind) without the copy of `toArray()`.
		final k = node.Kind;
		for (i in 0...kinds.length) {
			if (kinds[i] == k) {
				return true;
			}
		}
		return false;
	}

	public static function IsModifier(node:Node):Bool {
		return IsModifierKind(node.Kind);
	}

	public static function IsModifierLike(node:Node):Bool {
		return IsModifier(node) || IsDecorator(node);
	}

	public static function IsCompoundAssignment(token:Kind):Bool {
		return token >= KindFirstCompoundAssignment && token <= KindLastCompoundAssignment;
	}

	public static function IsAssignmentExpression(node:Node, excludeCompoundAssignment:Bool):Bool {
		if (node.Kind == KindBinaryExpression) {
			final expr = node.AsBinaryExpression();
			return (expr.OperatorToken.Kind == KindEqualsToken || !excludeCompoundAssignment && IsAssignmentOperator(expr.OperatorToken.Kind))
				&& IsLeftHandSideExpression(expr.Left);
		}
		return false;
	}

	public static function GetRightMostAssignedExpression(node:Node):Node {
		while (IsAssignmentExpression(node, false /*excludeCompoundAssignment*/)) {
			node = node.AsBinaryExpression().Right;
		}
		return node;
	}

	public static function IsDestructuringAssignment(node:Node):Bool {
		if (IsAssignmentExpression(node, true /*excludeCompoundAssignment*/)) {
			final kind = node.AsBinaryExpression().Left.Kind;
			return kind == KindObjectLiteralExpression || kind == KindArrayLiteralExpression;
		}
		return false;
	}

	public static function IsObjectBindingOrAssignmentElement(node:Node):Bool {
		switch (node.Kind) {
			case KindBindingElement | KindPropertyAssignment | KindShorthandPropertyAssignment | KindSpreadAssignment:
				return true;
			default:
		}
		return false;
	}

	public static function IsArrayBindingOrAssignmentElement(node:Node):Bool {
		switch (node.Kind) {
			case KindBindingElement | KindOmittedExpression | KindSpreadElement | KindArrayLiteralExpression | KindObjectLiteralExpression |
				KindIdentifier | KindPropertyAccessExpression | KindElementAccessExpression:
				return true;
			default:
		}
		return IsAssignmentExpression(node, true /*excludeCompoundAssignment*/);
	}

	public static function IsBindingPattern(node:Node):Bool {
		return node.Kind == KindObjectBindingPattern || node.Kind == KindArrayBindingPattern;
	}

	public static function IsForInOrOfStatement(node:Node):Bool {
		return node != null && (node.Kind == KindForInStatement || node.Kind == KindForOfStatement);
	}

	// A node is an assignment target if it is on the left hand side of an '=' token, if it is parented by a property
	// assignment in an object literal that is an assignment target, or if it is parented by an array literal that is
	// an assignment target. Examples include 'a = xxx', '{ p: a } = xxx', '[{ a }] = xxx'.
	// (Note that `p` is not a target in the above examples, only `a`.)
	public static function IsAssignmentTarget(node:Node):Bool {
		return GetAssignmentTarget(node) != null;
	}

	// Returns the BinaryExpression, PrefixUnaryExpression, PostfixUnaryExpression, or ForInOrOfStatement that references
	// the given node as an assignment target
	public static function GetAssignmentTarget(node:Node):Node {
		while (true) {
			final parent = node.Parent;
			switch (parent.Kind) {
				case KindBinaryExpression:
					if (IsAssignmentOperator(parent.AsBinaryExpression().OperatorToken.Kind) && parent.AsBinaryExpression().Left == node) {
						return parent;
					}
					return null;
				case KindPrefixUnaryExpression:
					if (parent.AsPrefixUnaryExpression().Operator == KindPlusPlusToken
						|| parent.AsPrefixUnaryExpression().Operator == KindMinusMinusToken) {
						return parent;
					}
					return null;
				case KindPostfixUnaryExpression:
					if (parent.AsPostfixUnaryExpression().Operator == KindPlusPlusToken
						|| parent.AsPostfixUnaryExpression().Operator == KindMinusMinusToken) {
						return parent;
					}
					return null;
				case KindForInStatement | KindForOfStatement:
					if (parent.Initializer() == node) {
						return parent;
					}
					return null;
				case KindParenthesizedExpression | KindArrayLiteralExpression | KindSpreadElement | KindNonNullExpression:
					node = parent;
				case KindSpreadAssignment:
					node = parent.Parent;
				case KindShorthandPropertyAssignment:
					if (parent.AsShorthandPropertyAssignment().Name() != node) {
						return null;
					}
					node = parent.Parent;
				case KindPropertyAssignment:
					if (parent.AsPropertyAssignment().Name() == node) {
						return null;
					}
					node = parent.Parent;
				default:
					return null;
			}
		}
	}

	public static function IsLogicalBinaryOperator(token:Kind):Bool {
		return token == KindBarBarToken || token == KindAmpersandAmpersandToken;
	}

	public static function IsLogicalOrCoalescingBinaryOperator(token:Kind):Bool {
		return IsLogicalBinaryOperator(token) || token == KindQuestionQuestionToken;
	}

	public static function IsLogicalOrCoalescingBinaryExpression(expr:Node):Bool {
		return IsBinaryExpression(expr) && IsLogicalOrCoalescingBinaryOperator(expr.AsBinaryExpression().OperatorToken.Kind);
	}

	public static function IsLogicalOrCoalescingAssignmentExpression(expr:Node):Bool {
		return IsBinaryExpression(expr) && IsLogicalOrCoalescingAssignmentOperator(expr.AsBinaryExpression().OperatorToken.Kind);
	}

	public static function IsLogicalExpression(node:Node):Bool {
		while (true) {
			if (node.Kind == KindParenthesizedExpression) {
				node = node.Expression();
			} else if (node.Kind == KindPrefixUnaryExpression && node.AsPrefixUnaryExpression().Operator == KindExclamationToken) {
				node = node.AsPrefixUnaryExpression().Operand;
			} else {
				return IsLogicalOrCoalescingBinaryExpression(node);
			}
		}
	}

	public static function IsAccessor(node:Node):Bool {
		return node.Kind == KindGetAccessor || node.Kind == KindSetAccessor;
	}

	public static function IsPropertyNameLiteral(node:Node):Bool {
		switch (node.Kind) {
			case KindIdentifier | KindStringLiteral | KindNoSubstitutionTemplateLiteral | KindNumericLiteral:
				return true;
			default:
		}
		return false;
	}

	public static function IsMemberName(node:Node):Bool {
		return node.Kind == KindIdentifier || node.Kind == KindPrivateIdentifier;
	}

	public static function IsEntityName(node:Node):Bool {
		return node.Kind == KindIdentifier || node.Kind == KindQualifiedName;
	}

	public static function IsPropertyName(node:Node):Bool {
		switch (node.Kind) {
			case KindIdentifier | KindPrivateIdentifier | KindStringLiteral | KindNumericLiteral | KindComputedPropertyName:
				return true;
			default:
		}
		return false;
	}

	// Return true if the given identifier is classified as an IdentifierName by inspecting the parent of the node
	public static function IsIdentifierName(node:Node):Bool {
		final parent = node.Parent;
		switch (parent.Kind) {
			case KindPropertyDeclaration | KindPropertySignature | KindMethodDeclaration | KindMethodSignature | KindGetAccessor | KindSetAccessor |
				KindEnumMember | KindPropertyAssignment | KindPropertyAccessExpression:
				return parent.Name() == node;
			case KindQualifiedName:
				return parent.AsQualifiedName().Right == node;
			case KindBindingElement:
				return parent.PropertyName() == node;
			case KindImportSpecifier:
				return parent.PropertyName() == node;
			case KindExportSpecifier | KindJsxAttribute | KindJsxSelfClosingElement | KindJsxOpeningElement | KindJsxClosingElement:
				return true;
			default:
		}
		return false;
	}

	public static function IsPushOrUnshiftIdentifier(node:Node):Bool {
		final text = node.Text();
		return text == "push" || text == "unshift";
	}

	public static function IsBooleanLiteral(node:Node):Bool {
		return node.Kind == KindTrueKeyword || node.Kind == KindFalseKeyword;
	}

	public static function IsLiteralExpression(node:Node):Bool {
		return IsLiteralKind(node.Kind);
	}

	public static function IsStringLiteralLike(node:Node):Bool {
		switch (node.Kind) {
			case KindStringLiteral | KindNoSubstitutionTemplateLiteral:
				return true;
			default:
		}
		return false;
	}

	public static function IsStringOrNumericLiteralLike(node:Node):Bool {
		return IsStringLiteralLike(node) || IsNumericLiteral(node);
	}

	public static function IsSignedNumericLiteral(node:Node):Bool {
		if (node.Kind == KindPrefixUnaryExpression) {
			final node = node.AsPrefixUnaryExpression();
			return (node.Operator == KindPlusToken || node.Operator == KindMinusToken) && IsNumericLiteral(node.Operand);
		}
		return false;
	}

	// Determines if a node is part of an OptionalChain
	public static function IsOptionalChain(node:Node):Bool {
		if (node.Flags & NodeFlagsOptionalChain != 0) {
			switch (node.Kind) {
				case KindPropertyAccessExpression | KindElementAccessExpression | KindCallExpression | KindNonNullExpression:
					return true;
				default:
			}
		}
		return false;
	}

	static function getQuestionDotToken(node:Expression):TokenNode {
		return node.QuestionDotToken();
	}

	// Determines if node is the root expression of an OptionalChain
	public static function IsOptionalChainRoot(node:Expression):Bool {
		return IsOptionalChain(node) && !IsNonNullExpression(node) && getQuestionDotToken(node) != null;
	}

	// Determines whether a node is the outermost `OptionalChain` in an ECMAScript `OptionalExpression`:
	//
	//  1. For `a?.b.c`, the outermost chain is `a?.b.c` (`c` is the end of the chain starting at `a?.`)
	//  2. For `a?.b!`, the outermost chain is `a?.b` (`b` is the end of the chain starting at `a?.`)
	//  3. For `(a?.b.c).d`, the outermost chain is `a?.b.c` (`c` is the end of the chain starting at `a?.` since parens end the chain)
	//  4. For `a?.b.c?.d`, both `a?.b.c` and `a?.b.c?.d` are outermost (`c` is the end of the chain starting at `a?.`, and `d` is
	//     the end of the chain starting at `c?.`)
	//  5. For `a?.(b?.c).d`, both `b?.c` and `a?.(b?.c)d` are outermost (`c` is the end of the chain starting at `b`, and `d` is
	//     the end of the chain starting at `a?.`)
	public static function IsOutermostOptionalChain(node:Expression):Bool {
		final parent = node.Parent;
		return !IsOptionalChain(parent) // cases 1, 2, and 3
			|| IsOptionalChainRoot(parent) // case 4
			|| node != parent.Expression(); // case 5
	}

	// Determines whether a node is the expression preceding an optional chain (i.e. `a` in `a?.b`).
	public static function IsExpressionOfOptionalChainRoot(node:Node):Bool {
		return IsOptionalChainRoot(node.Parent) && node.Parent.Expression() == node;
	}

	public static function IsNullishCoalesce(node:Node):Bool {
		return node.Kind == KindBinaryExpression && node.AsBinaryExpression().OperatorToken.Kind == KindQuestionQuestionToken;
	}

	public static function IsAssertionExpression(node:Node):Bool {
		final kind = node.Kind;
		return kind == KindTypeAssertionExpression || kind == KindAsExpression;
	}

	static function isLeftHandSideExpressionKind(kind:Kind):Bool {
		switch (kind) {
			case KindPropertyAccessExpression | KindElementAccessExpression | KindNewExpression | KindCallExpression | KindJsxElement |
				KindJsxSelfClosingElement | KindJsxFragment | KindTaggedTemplateExpression | KindArrayLiteralExpression | KindParenthesizedExpression |
				KindObjectLiteralExpression | KindClassExpression | KindFunctionExpression | KindIdentifier | KindPrivateIdentifier |
				KindRegularExpressionLiteral | KindNumericLiteral | KindBigIntLiteral | KindStringLiteral | KindNoSubstitutionTemplateLiteral |
				KindTemplateExpression | KindFalseKeyword | KindNullKeyword | KindThisKeyword | KindTrueKeyword | KindSuperKeyword |
				KindNonNullExpression | KindExpressionWithTypeArguments | KindMetaProperty | KindImportKeyword | KindMissingDeclaration:
				return true;
			default:
		}
		return false;
	}

	// Determines whether a node is a LeftHandSideExpression based only on its kind.
	public static function IsLeftHandSideExpression(node:Node):Bool {
		return isLeftHandSideExpressionKind(SkipPartiallyEmittedExpressions(node).Kind);
	}

	static function isUnaryExpressionKind(kind:Kind):Bool {
		switch (kind) {
			case KindPrefixUnaryExpression | KindPostfixUnaryExpression | KindDeleteExpression | KindTypeOfExpression | KindVoidExpression |
				KindAwaitExpression | KindTypeAssertionExpression:
				return true;
			default:
		}
		return isLeftHandSideExpressionKind(kind);
	}

	// Determines whether a node is a UnaryExpression based only on its kind.
	public static function IsUnaryExpression(node:Node):Bool {
		return isUnaryExpressionKind(SkipPartiallyEmittedExpressions(node).Kind);
	}

	static function isExpressionKind(kind:Kind):Bool {
		switch (kind) {
			case KindConditionalExpression | KindYieldExpression | KindArrowFunction | KindBinaryExpression | KindSpreadElement | KindAsExpression |
				KindOmittedExpression | KindPartiallyEmittedExpression | KindSatisfiesExpression:
				return true;
			default:
		}
		return isUnaryExpressionKind(kind);
	}

	// Determines whether a node is an expression based only on its kind.
	public static function IsExpression(node:Node):Bool {
		return isExpressionKind(SkipPartiallyEmittedExpressions(node).Kind);
	}

	public static function IsCommaExpression(node:Node):Bool {
		return node.Kind == KindBinaryExpression && node.AsBinaryExpression().OperatorToken.Kind == KindCommaToken;
	}

	public static function IsCommaSequence(node:Node):Bool {
		return IsCommaExpression(node);
	}

	public static function IsIterationStatement(node:Node, lookInLabeledStatements:Bool):Bool {
		switch (node.Kind) {
			case KindForStatement | KindForInStatement | KindForOfStatement | KindDoStatement | KindWhileStatement:
				return true;
			case KindLabeledStatement:
				return lookInLabeledStatements && IsIterationStatement(node.Statement(), lookInLabeledStatements);
			default:
		}

		return false;
	}

	// Determines if a node is a property or element access expression
	public static function IsAccessExpression(node:Node):Bool {
		return node.Kind == KindPropertyAccessExpression || node.Kind == KindElementAccessExpression;
	}

	static function isFunctionLikeDeclarationKind(kind:Kind):Bool {
		switch (kind) {
			case KindFunctionDeclaration | KindMethodDeclaration | KindConstructor | KindGetAccessor | KindSetAccessor | KindFunctionExpression |
				KindArrowFunction:
				return true;
			default:
		}
		return false;
	}

	// Determines if a node is function-like (but is not a signature declaration)
	public static function IsFunctionLikeDeclaration(node:Node):Bool {
		// TODO(rbuckton): Move `node != nil` test to call sites
		return node != null && isFunctionLikeDeclarationKind(node.Kind);
	}

	public static function IsFunctionLikeKind(kind:Kind):Bool {
		switch (kind) {
			case KindMethodSignature | KindCallSignature | KindJSDocSignature | KindConstructSignature | KindIndexSignature | KindFunctionType |
				KindConstructorType:
				return true;
			default:
		}
		return isFunctionLikeDeclarationKind(kind);
	}

	// Determines if a node is function- or signature-like.
	public static function IsFunctionLike(node:Node):Bool {
		// TODO(rbuckton): Move `node != nil` test to call sites
		return node != null && IsFunctionLikeKind(node.Kind);
	}

	public static function IsFunctionLikeOrClassStaticBlockDeclaration(node:Node):Bool {
		return node != null && (IsFunctionLike(node) || IsClassStaticBlockDeclaration(node));
	}

	public static function IsFunctionOrSourceFile(node:Node):Bool {
		return IsFunctionLike(node) || IsSourceFile(node);
	}

	public static function IsClassLike(node:Node):Bool {
		return node.Kind == KindClassDeclaration || node.Kind == KindClassExpression;
	}

	public static function IsClassOrInterfaceLike(node:Node):Bool {
		return node.Kind == KindClassDeclaration || node.Kind == KindClassExpression || node.Kind == KindInterfaceDeclaration;
	}

	public static function IsClassElement(node:Node):Bool {
		switch (node.Kind) {
			case KindConstructor | KindPropertyDeclaration | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindIndexSignature |
				KindClassStaticBlockDeclaration | KindSemicolonClassElement:
				return true;
			default:
		}
		return false;
	}

	public static function IsMethodOrAccessor(node:Node):Bool {
		switch (node.Kind) {
			case KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
				return true;
			default:
		}
		return false;
	}

	public static function IsPrivateIdentifierClassElementDeclaration(node:Node):Bool {
		return (IsPropertyDeclaration(node) || IsMethodOrAccessor(node)) && IsPrivateIdentifier(node.Name());
	}

	public static function IsObjectLiteralOrClassExpressionMethodOrAccessor(node:Node):Bool {
		final kind = node.Kind;
		return (kind == KindMethodDeclaration || kind == KindGetAccessor || kind == KindSetAccessor)
			&& (node.Parent.Kind == KindObjectLiteralExpression || node.Parent.Kind == KindClassExpression);
	}

	public static function IsTypeElement(node:Node):Bool {
		switch (node.Kind) {
			case KindConstructSignature | KindCallSignature | KindPropertySignature | KindMethodSignature | KindIndexSignature | KindGetAccessor |
				KindSetAccessor | KindNotEmittedTypeElement:
				return true;
			default:
		}
		return false;
	}

	public static function IsObjectLiteralElement(node:Node):Bool {
		switch (node.Kind) {
			case KindPropertyAssignment | KindShorthandPropertyAssignment | KindSpreadAssignment | KindMethodDeclaration | KindGetAccessor |
				KindSetAccessor:
				return true;
			default:
		}
		return false;
	}

	public static function IsObjectLiteralMethod(node:Node):Bool {
		return node != null && node.Kind == KindMethodDeclaration && node.Parent.Kind == KindObjectLiteralExpression;
	}

	public static function IsAutoAccessorPropertyDeclaration(node:Node):Bool {
		return IsPropertyDeclaration(node) && HasAccessorModifier(node);
	}

	public static function IsParameterPropertyDeclaration(node:Node, parent:Node):Bool {
		return IsParameterDeclaration(node) && HasSyntacticModifier(node, ModifierFlagsParameterPropertyModifier) && parent.Kind == KindConstructor;
	}

	public static function IsJsxChild(node:Node):Bool {
		switch (node.Kind) {
			case KindJsxElement | KindJsxExpression | KindJsxSelfClosingElement | KindJsxText | KindJsxFragment:
				return true;
			default:
		}
		return false;
	}

	public static function IsJsxAttributeLike(node:Node):Bool {
		return IsJsxAttribute(node) || IsJsxSpreadAttribute(node);
	}

	static function isDeclarationStatementKind(kind:Kind):Bool {
		switch (kind) {
			case KindFunctionDeclaration | KindMissingDeclaration | KindClassDeclaration | KindInterfaceDeclaration | KindTypeAliasDeclaration |
				KindJSTypeAliasDeclaration | KindEnumDeclaration | KindModuleDeclaration | KindImportDeclaration | KindJSImportDeclaration |
				KindImportEqualsDeclaration | KindExportDeclaration | KindExportAssignment | KindNamespaceExportDeclaration:
				return true;
			default:
		}
		return false;
	}

	// Determines whether a node is a DeclarationStatement. Ideally this does not use Parent pointers, but it may use them
	// to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
	//
	// NOTE: ECMA262 would just call this a Declaration
	public static function IsDeclarationStatement(node:Node):Bool {
		return isDeclarationStatementKind(node.Kind);
	}

	static function isStatementKindButNotDeclarationKind(kind:Kind):Bool {
		switch (kind) {
			case KindBreakStatement | KindContinueStatement | KindDebuggerStatement | KindDoStatement | KindExpressionStatement | KindEmptyStatement |
				KindForInStatement | KindForOfStatement | KindForStatement | KindIfStatement | KindLabeledStatement | KindReturnStatement |
				KindSwitchStatement | KindThrowStatement | KindTryStatement | KindVariableStatement | KindWhileStatement | KindWithStatement |
				KindNotEmittedStatement:
				return true;
			default:
		}
		return false;
	}

	// Determines whether a node is a Statement that is not also a Declaration. Ideally this does not use Parent pointers,
	// but it may use them to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
	//
	// NOTE: ECMA262 would just call this a Statement
	public static function IsStatementButNotDeclaration(node:Node):Bool {
		return isStatementKindButNotDeclarationKind(node.Kind);
	}

	// Determines whether a node is a Statement. Ideally this does not use Parent pointers, but it may use
	// them to rule out a Block node that is part of `try` or `catch` or is the Block-like body of a function.
	//
	// NOTE: ECMA262 would call this either a StatementListItem or ModuleListItem
	public static function IsStatement(node:Node):Bool {
		final kind = node.Kind;
		return isStatementKindButNotDeclarationKind(kind) || isDeclarationStatementKind(kind) || isBlockStatement(node);
	}

	// Determines whether a node is a BlockStatement. If parents are available, this ensures the Block is
	// not part of a `try` statement, `catch` clause, or the Block-like body of a function
	static function isBlockStatement(node:Node):Bool {
		if (node.Kind != KindBlock) {
			return false;
		}
		if (node.Parent != null && (node.Parent.Kind == KindTryStatement || node.Parent.Kind == KindCatchClause)) {
			return false;
		}
		return !IsFunctionBlock(node);
	}

	// Determines whether a node is the Block-like body of a function by walking the parent of the node
	public static function IsFunctionBlock(node:Node):Bool {
		return node != null && node.Kind == KindBlock && node.Parent != null && IsFunctionLike(node.Parent);
	}

	public static function IsBlockOrCatchScoped(declaration:Node):Bool {
		return GetCombinedNodeFlags(declaration) & NodeFlagsBlockScoped != 0 || IsCatchClauseVariableDeclarationOrBindingElement(declaration);
	}

	public static function IsCatchClauseVariableDeclarationOrBindingElement(declaration:Node):Bool {
		final node = GetRootDeclaration(declaration);
		return node.Kind == KindVariableDeclaration && node.Parent.Kind == KindCatchClause;
	}

	public static function IsTypeNodeKind(kind:Kind):Bool {
		switch (kind) {
			case KindAnyKeyword | KindUnknownKeyword | KindNumberKeyword | KindBigIntKeyword | KindObjectKeyword | KindBooleanKeyword |
				KindStringKeyword | KindSymbolKeyword | KindVoidKeyword | KindUndefinedKeyword | KindNeverKeyword | KindIntrinsicKeyword |
				KindExpressionWithTypeArguments | KindJSDocAllType | KindJSDocNullableType | KindJSDocNonNullableType | KindJSDocOptionalType |
				KindJSDocVariadicType:
				return true;
			default:
		}
		return kind >= KindFirstTypeNode && kind <= KindLastTypeNode;
	}

	public static function IsTypeNode(node:Node):Bool {
		return IsTypeNodeKind(node.Kind);
	}

	public static function IsJSDocKind(kind:Kind):Bool {
		return KindFirstJSDocNode <= kind && kind <= KindLastJSDocNode;
	}

	public static function IsJSDocTypeAssertion(node:Node):Bool {
		if (node == null || !IsParenthesizedExpression(node) || !IsInJSFile(node)) {
			return false;
		}
		final expr = node.Expression();
		return IsAsExpression(expr) && expr.Type() != null && expr.Type().Flags & NodeFlagsReparsed != 0;
	}

	public static function IsPrologueDirective(node:Node):Bool {
		return node.Kind == KindExpressionStatement && node.Expression().Kind == KindStringLiteral;
	}

	// Determines whether node is an "outer expression" of the provided kinds
	public static function IsOuterExpression(node:Expression, kinds:OuterExpressionKinds):Bool {
		switch (node.Kind) {
			case KindParenthesizedExpression:
				return kinds & OEKParentheses != 0 && !(kinds & OEKExcludeJSDocTypeAssertion != 0 && IsJSDocTypeAssertion(node));
			case KindTypeAssertionExpression | KindAsExpression:
				return kinds & OEKTypeAssertions != 0;
			case KindSatisfiesExpression:
				return kinds & (OEKExpressionsWithTypeArguments | OEKSatisfies) != 0;
			case KindExpressionWithTypeArguments:
				return kinds & OEKExpressionsWithTypeArguments != 0;
			case KindNonNullExpression:
				return kinds & OEKNonNullAssertions != 0;
			case KindPartiallyEmittedExpression:
				return kinds & OEKPartiallyEmittedExpressions != 0;
			case KindBinaryExpression:
				switch (node.AsBinaryExpression().OperatorToken.Kind) {
					case KindEqualsToken:
						return kinds & OEKAssignments != 0;
					case KindCommaToken:
						return kinds & OEKComma != 0;
					default:
				}
			default:
		}
		return false;
	}

	// Descends into an expression, skipping past "outer expressions" of the provided kinds
	public static function SkipOuterExpressions(node:Expression, kinds:OuterExpressionKinds):Expression {
		while (IsOuterExpression(node, kinds)) {
			if (IsBinaryExpression(node)) {
				node = node.AsBinaryExpression().Right;
			} else {
				node = node.Expression();
			}
		}
		return node;
	}

	// Skips past the parentheses of an expression
	public static function SkipParentheses(node:Expression):Expression {
		return SkipOuterExpressions(node, OEKParentheses);
	}

	public static function SkipTypeParentheses(node:Node):Node {
		while (IsParenthesizedTypeNode(node)) {
			node = node.Type();
		}
		return node;
	}

	public static function SkipPartiallyEmittedExpressions(node:Expression):Expression {
		return SkipOuterExpressions(node, OEKPartiallyEmittedExpressions);
	}

	// Walks up the parents of a parenthesized expression to find the containing node
	public static function WalkUpParenthesizedExpressions(node:Expression):Node {
		while (node != null && node.Kind == KindParenthesizedExpression) {
			node = node.Parent;
		}
		return node;
	}

	// Walks up the parents of a parenthesized type to find the containing node
	public static function WalkUpParenthesizedTypes(node:TypeNode):Node {
		while (node != null && node.Kind == KindParenthesizedType) {
			node = node.Parent;
		}
		return node;
	}

	// Walks up the parents of a node to find the containing SourceFile
	public static function GetSourceFileOfNode(node:Node):SourceFile {
		while (node != null) {
			if (node.Kind == KindSourceFile) {
				return node.AsSourceFile();
			}
			node = node.Parent;
		}
		return null;
	}

	// PORT: sync.Pool → a free list (single-threaded); Get pops or creates, Put pushes.
	static final setParentInChildrenPool:Array<(node:Node) -> Bool> = [];

	static function newParentInChildrenSetter():(node:Node) -> Bool {
		// Consolidate state into one allocation.
		// Similar to https://go.dev/cl/552375.
		var parent:Node = null;
		var visit:(node:Node) -> Bool = null;

		visit = function(node:Node):Bool {
			if (parent != null) {
				node.Parent = parent;
			}
			final saveParent = parent;
			parent = node;
			node.ForEachChild(visit);
			parent = saveParent;
			return false;
		};

		return visit;
	}

	public static function SetParentInChildren(node:Node):Void {
		final fn = setParentInChildrenPool.length > 0 ? setParentInChildrenPool.pop() : newParentInChildrenSetter();
		// PORT: defer Put → put back on success and on panic.
		try {
			fn(node);
		} catch (e:Dynamic) {
			setParentInChildrenPool.push(fn);
			throw e;
		}
		setParentInChildrenPool.push(fn);
	}

	// This should never be called outside the parser
	public static function SetImportsOfSourceFile(node:SourceFile, imports:Array<LiteralLikeNode>):Void {
		node.imports = imports;
	}

	// Walks up the parents of a node to find the ancestor that matches the callback
	public static function FindAncestor(node:Node, callback:(Node) -> Bool):Node {
		while (node != null) {
			if (callback(node)) {
				return node;
			}
			node = node.Parent;
		}
		return null;
	}

	// Walks up the parents of a node to find the ancestor that matches the kind
	public static function FindAncestorKind(node:Node, kind:Kind):Node {
		while (node != null) {
			if (node.Kind == kind) {
				return node;
			}
			node = node.Parent;
		}
		return null;
	}

	public static function ToFindAncestorResult(b:Bool):FindAncestorResult {
		if (b) {
			return FindAncestorTrue;
		}
		return FindAncestorFalse;
	}

	// Walks up the parents of a node to find the ancestor that matches the callback
	public static function FindAncestorOrQuit(node:Node, callback:(Node) -> FindAncestorResult):Node {
		while (node != null) {
			switch (callback(node)) {
				case FindAncestorQuit:
					return null;
				case FindAncestorTrue:
					return node;
				default:
			}
			node = node.Parent;
		}
		return null;
	}

	public static function IsNodeDescendantOf(node:Node, ancestor:Node):Bool {
		while (node != null) {
			if (node == ancestor) {
				return true;
			}
			node = node.Parent;
		}
		return false;
	}

	public static function ModifierToFlag(token:Kind):ModifierFlags {
		switch (token) {
			case KindStaticKeyword:
				return ModifierFlagsStatic;
			case KindPublicKeyword:
				return ModifierFlagsPublic;
			case KindProtectedKeyword:
				return ModifierFlagsProtected;
			case KindPrivateKeyword:
				return ModifierFlagsPrivate;
			case KindAbstractKeyword:
				return ModifierFlagsAbstract;
			case KindAccessorKeyword:
				return ModifierFlagsAccessor;
			case KindExportKeyword:
				return ModifierFlagsExport;
			case KindDeclareKeyword:
				return ModifierFlagsAmbient;
			case KindConstKeyword:
				return ModifierFlagsConst;
			case KindDefaultKeyword:
				return ModifierFlagsDefault;
			case KindAsyncKeyword:
				return ModifierFlagsAsync;
			case KindReadonlyKeyword:
				return ModifierFlagsReadonly;
			case KindOverrideKeyword:
				return ModifierFlagsOverride;
			case KindInKeyword:
				return ModifierFlagsIn;
			case KindOutKeyword:
				return ModifierFlagsOut;
			case KindDecorator:
				return ModifierFlagsDecorator;
			default:
		}
		return ModifierFlagsNone;
	}

	public static function ModifiersToFlags(modifiers:Array<Node>):ModifierFlags {
		var flags:ModifierFlags = ModifierFlagsNone;
		if (modifiers != null) {
			for (modifier in modifiers) {
				flags |= ModifierToFlag(modifier.Kind);
			}
		}
		return flags;
	}

	public static function HasSyntacticModifier(node:Node, flags:ModifierFlags):Bool {
		return node.ModifierFlags() & flags != 0;
	}

	public static function HasAccessorModifier(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsAccessor);
	}

	public static function HasStaticModifier(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsStatic);
	}

	public static function IsStatic(node:Node):Bool {
		// https://tc39.es/ecma262/#sec-static-semantics-isstatic
		return IsClassElement(node) && HasStaticModifier(node) || IsClassStaticBlockDeclaration(node);
	}

	public static function CanHaveSymbol(node:Node):Bool {
		switch (node.Kind) {
			case KindArrowFunction | KindBinaryExpression | KindBindingElement | KindCallExpression | KindCallSignature | KindClassDeclaration |
				KindClassExpression | KindClassStaticBlockDeclaration | KindConstructor | KindConstructorType | KindConstructSignature |
				KindElementAccessExpression | KindEnumDeclaration | KindEnumMember | KindExportAssignment | KindExportDeclaration |
				KindExportSpecifier | KindFunctionDeclaration | KindFunctionExpression | KindFunctionType | KindGetAccessor | KindImportClause |
				KindImportEqualsDeclaration | KindImportSpecifier | KindIndexSignature | KindInterfaceDeclaration | KindJSTypeAliasDeclaration |
				KindJsxAttribute | KindJsxAttributes | KindJsxSpreadAttribute | KindMappedType | KindMethodDeclaration | KindMethodSignature |
				KindModuleDeclaration | KindNamedTupleMember | KindNamespaceExport | KindNamespaceExportDeclaration | KindNamespaceImport |
				KindNewExpression | KindNoSubstitutionTemplateLiteral | KindNumericLiteral | KindObjectLiteralExpression | KindParameter |
				KindPropertyAccessExpression | KindPropertyAssignment | KindPropertyDeclaration | KindPropertySignature | KindSetAccessor |
				KindShorthandPropertyAssignment | KindSourceFile | KindSpreadAssignment | KindStringLiteral | KindTypeAliasDeclaration |
				KindTypeLiteral | KindTypeParameter | KindVariableDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function CanHaveIllegalDecorators(node:Node):Bool {
		switch (node.Kind) {
			case KindPropertyAssignment | KindShorthandPropertyAssignment | KindFunctionDeclaration | KindConstructor | KindIndexSignature |
				KindClassStaticBlockDeclaration | KindMissingDeclaration | KindVariableStatement | KindInterfaceDeclaration | KindTypeAliasDeclaration |
				KindEnumDeclaration | KindModuleDeclaration | KindImportEqualsDeclaration | KindImportDeclaration | KindJSImportDeclaration |
				KindNamespaceExportDeclaration | KindExportDeclaration | KindExportAssignment:
				return true;
			default:
		}
		return false;
	}

	public static function CanHaveIllegalModifiers(node:Node):Bool {
		switch (node.Kind) {
			case KindClassStaticBlockDeclaration | KindPropertyAssignment | KindShorthandPropertyAssignment | KindMissingDeclaration |
				KindNamespaceExportDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function CanHaveModifiers(node:Node):Bool {
		switch (node.Kind) {
			case KindTypeParameter | KindParameter | KindPropertySignature | KindPropertyDeclaration | KindMethodSignature | KindMethodDeclaration |
				KindConstructor | KindGetAccessor | KindSetAccessor | KindIndexSignature | KindConstructorType | KindFunctionExpression |
				KindArrowFunction | KindClassExpression | KindVariableStatement | KindFunctionDeclaration | KindClassDeclaration |
				KindInterfaceDeclaration | KindTypeAliasDeclaration | KindEnumDeclaration | KindModuleDeclaration | KindImportEqualsDeclaration |
				KindImportDeclaration | KindJSImportDeclaration | KindExportAssignment | KindExportDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function CanHaveDecorators(node:Node):Bool {
		switch (node.Kind) {
			case KindParameter | KindPropertyDeclaration | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindClassExpression |
				KindClassDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function IsFunctionOrModuleBlock(node:Node):Bool {
		return IsSourceFile(node) || IsModuleBlock(node) || IsBlock(node) && IsFunctionLike(node.Parent);
	}

	public static function IsFunctionExpressionOrArrowFunction(node:Node):Bool {
		return IsFunctionExpression(node) || IsArrowFunction(node);
	}

	// Warning: This has the same semantics as the forEach family of functions in that traversal terminates
	// in the event that 'visitor' returns true.
	public static function ForEachReturnStatement(body:Node, visitor:(stmt:Node) -> Bool):Bool {
		var traverse:(Node) -> Bool = null;
		traverse = function(node:Node):Bool {
			switch (node.Kind) {
				case KindReturnStatement:
					return visitor(node);
				case KindCaseBlock | KindBlock | KindIfStatement | KindDoStatement | KindWhileStatement | KindForStatement | KindForInStatement |
					KindForOfStatement | KindWithStatement | KindSwitchStatement | KindCaseClause | KindDefaultClause | KindLabeledStatement |
					KindTryStatement | KindCatchClause:
					return node.ForEachChild(traverse);
				default:
			}
			return false;
		};
		return traverse(body);
	}

	public static function GetRootDeclaration(node:Node):Node {
		while (node.Kind == KindBindingElement) {
			node = node.Parent.Parent;
		}
		return node;
	}

	// PORT: generic `T ~uint32` → Int (ModifierFlags and NodeFlags are Int abstracts).
	// PORT: perf — inline: the getFlags function value (a static method reference or a lambda,
	// allocated per call otherwise) becomes a direct call.
	static inline function getCombinedFlags(node:Node, getFlags:(Node) -> Int):Int {
		node = GetRootDeclaration(node);
		var flags = getFlags(node);
		if (node.Kind == KindVariableDeclaration) {
			node = node.Parent;
		}
		if (node != null && node.Kind == KindVariableDeclarationList) {
			flags |= getFlags(node);
			node = node.Parent;
		}
		if (node != null && node.Kind == KindVariableStatement) {
			flags |= getFlags(node);
		}
		return flags;
	}

	public static function GetCombinedModifierFlags(node:Node):ModifierFlags {
		return getCombinedFlags(node, n -> n.ModifierFlags());
	}

	public static function GetCombinedNodeFlags(node:Node):NodeFlags {
		return getCombinedFlags(node, n -> getNodeFlags(n)); // PORT: perf — a lambda literal is inlined, a method reference is not
	}

	static function getNodeFlags(node:Node):NodeFlags {
		return node.Flags;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of an `await using` declaration.
	public static function IsVarAwaitUsing(node:Node):Bool {
		return GetCombinedNodeFlags(node) & NodeFlagsBlockScoped == NodeFlagsAwaitUsing;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `using` declaration.
	public static function IsVarUsing(node:Node):Bool {
		return GetCombinedNodeFlags(node) & NodeFlagsBlockScoped == NodeFlagsUsing;
	}

	// GetJSDocDeprecatedTag returns the first @deprecated JSDoc tag for the given node, or nil if none exists.
	public static function GetJSDocDeprecatedTag(node:Node):Node {
		final jsdocs = node.JSDoc(null);
		if (jsdocs != null) {
			for (jsdoc in jsdocs) {
				final tags = jsdoc.AsJSDoc().Tags;
				if (tags != null) {
					for (tag in tags.Nodes) {
						if (IsJSDocDeprecatedTag(tag)) {
							return tag;
						}
					}
				}
			}
		}
		return null;
	}

	// IsDeprecatedDeclaration reports whether the given declaration is marked as @deprecated.
	// It checks NodeFlagsPossiblyContainsDeprecatedTag on combined node flags, then confirms
	// by walking up to find the node with the flag and performing a JSDoc lookup.
	public static function IsDeprecatedDeclaration(declaration:Node):Bool {
		return IsDeprecatedDeclarationWithCachedFlags(declaration, GetCombinedNodeFlags(declaration));
	}

	// IsDeprecatedDeclarationWithCachedFlags is the core logic for IsDeprecatedDeclaration,
	// parameterized on pre-computed combined flags so the checker can supply cached flags.
	public static function IsDeprecatedDeclarationWithCachedFlags(declaration:Node, combinedFlags:NodeFlags):Bool {
		if (combinedFlags & NodeFlagsPossiblyContainsDeprecatedTag == 0) {
			return false;
		}
		// Walk up to find the node that directly has the flag, since JSDoc is
		// attached to that node (e.g. VariableStatement, not VariableDeclaration).
		var n = declaration;
		while (n != null) {
			if (n.Flags & NodeFlagsPossiblyContainsDeprecatedTag != 0) {
				return GetJSDocDeprecatedTag(n) != null;
			}
			n = n.Parent;
		}
		return false;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `const` declaration.
	public static function IsVarConst(node:Node):Bool {
		return GetCombinedNodeFlags(node) & NodeFlagsBlockScoped == NodeFlagsConst;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `const`, `using` or `await using` declaration.
	public static function IsVarConstLike(node:Node):Bool {
		// PORT: switch on a flag value → comparisons (flag constants are not switch patterns).
		final flags = GetCombinedNodeFlags(node) & NodeFlagsBlockScoped;
		if (flags == NodeFlagsConst || flags == NodeFlagsUsing || flags == NodeFlagsAwaitUsing) {
			return true;
		}
		return false;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `let` declaration.
	public static function IsVarLet(node:Node):Bool {
		return GetCombinedNodeFlags(node) & NodeFlagsBlockScoped == NodeFlagsLet;
	}

	public static function IsImportMeta(node:Node):Bool {
		if (node.Kind == KindMetaProperty) {
			return node.AsMetaProperty().KeywordToken == KindImportKeyword && node.AsMetaProperty().Name().Text() == "meta";
		}
		return false;
	}

	public static function WalkUpBindingElementsAndPatterns(binding:Node):Node {
		var node = binding.Parent;
		while (IsBindingElement(node.Parent)) {
			node = node.Parent.Parent;
		}
		return node.Parent;
	}

	public static function IsSourceFileJS(file:SourceFile):Bool {
		return file.ScriptKind == ScriptKindJS || file.ScriptKind == ScriptKindJSX;
	}

	public static function IsInJSFile(node:Node):Bool {
		return node != null && node.Flags & NodeFlagsJavaScriptFile != 0;
	}

	public static function IsDeclaration(node:Node):Bool {
		if (node.Kind == KindTypeParameter) {
			return node.Parent != null;
		}
		return IsDeclarationNode(node);
	}

	// True if `name` is the name of a declaration node
	public static function IsDeclarationName(name:Node):Bool {
		return !IsSourceFile(name) && !IsBindingPattern(name) && IsDeclaration(name.Parent) && name.Parent.Name() == name;
	}

	// Like 'isDeclarationName', but returns true for LHS of `import { x as y }` or `export { x as y }`.
	public static function IsDeclarationNameOrImportPropertyName(name:Node):Bool {
		switch (name.Parent.Kind) {
			case KindImportSpecifier | KindExportSpecifier:
				return IsIdentifier(name) || name.Kind == KindStringLiteral;
			default:
				return IsDeclarationName(name);
		}
	}

	public static function IsLiteralComputedPropertyDeclarationName(node:Node):Bool {
		return IsStringOrNumericLiteralLike(node) && node.Parent.Kind == KindComputedPropertyName && IsDeclaration(node.Parent.Parent);
	}

	public static function IsExternalModuleImportEqualsDeclaration(node:Node):Bool {
		return node.Kind == KindImportEqualsDeclaration && node.AsImportEqualsDeclaration().ModuleReference.Kind == KindExternalModuleReference;
	}

	public static function IsModuleOrEnumDeclaration(node:Node):Bool {
		return node.Kind == KindModuleDeclaration || node.Kind == KindEnumDeclaration;
	}

	public static function IsLiteralImportTypeNode(node:Node):Bool {
		return IsImportTypeNode(node)
			&& IsLiteralTypeNode(node.AsImportTypeNode().Argument)
			&& IsStringLiteral(node.AsImportTypeNode().Argument.AsLiteralTypeNode().Literal);
	}

	public static function IsJsxTagName(node:Node):Bool {
		final parent = node.Parent;
		switch (parent.Kind) {
			case KindJsxOpeningElement | KindJsxClosingElement | KindJsxSelfClosingElement:
				return parent.TagName() == node;
			default:
		}
		return false;
	}

	public static function IsImportOrExportSpecifier(node:Node):Bool {
		return IsImportSpecifier(node) || IsExportSpecifier(node);
	}

	public static function IsVoidZero(node:Node):Bool {
		return IsVoidExpression(node) && IsNumericLiteral(node.Expression()) && node.Expression().Text() == "0";
	}

	public static function IsExportsIdentifier(node:Node):Bool {
		return IsIdentifier(node) && node.Text() == "exports";
	}

	public static function IsModuleIdentifier(node:Node):Bool {
		return IsIdentifier(node) && node.Text() == "module";
	}

	public static function IsThisIdentifier(node:Node):Bool {
		return IsIdentifier(node) && node.Text() == "this";
	}

	public static function IsThisParameter(node:Node):Bool {
		return IsParameterDeclaration(node) && node.Name() != null && IsThisIdentifier(node.Name());
	}

	public static function IsBindableStaticAccessExpression(node:Node, excludeThisKeyword:Bool):Bool {
		return IsPropertyAccessExpression(node)
			&& (!excludeThisKeyword && node.Expression().Kind == KindThisKeyword
				|| IsIdentifier(node.Name()) && IsBindableStaticNameExpression(node.Expression(), true /*excludeThisKeyword*/))
			|| IsBindableStaticElementAccessExpression(node, excludeThisKeyword);
	}

	public static function IsBindableStaticElementAccessExpression(node:Node, excludeThisKeyword:Bool):Bool {
		return IsLiteralLikeElementAccess(node)
			&& ((!excludeThisKeyword && node.Expression().Kind == KindThisKeyword)
				|| IsEntityNameExpression(node.Expression())
				|| IsBindableStaticAccessExpression(node.Expression(), true /*excludeThisKeyword*/));
	}

	public static function IsPrototypeAccess(node:Node):Bool {
		if (IsBindableStaticAccessExpression(node, false /*excludeThisKeyword*/)) {
			final name = GetElementOrPropertyAccessName(node);
			if (name != null) {
				return name.Text() == "prototype";
			}
		}
		return false;
	}

	public static function IsLiteralLikeElementAccess(node:Node):Bool {
		return IsElementAccessExpression(node) && IsStringOrNumericLiteralLike(node.AsElementAccessExpression().ArgumentExpression);
	}

	public static function IsBindableStaticNameExpression(node:Node, excludeThisKeyword:Bool):Bool {
		return IsEntityNameExpression(node) || IsBindableStaticAccessExpression(node, excludeThisKeyword);
	}

	// Does not handle signed numeric names like `a[+0]` - handling those would require handling prefix unary expressions
	// throughout late binding handling as well, which is awkward (but ultimately probably doable if there is demand)
	public static function GetElementOrPropertyAccessName(node:Node):Node {
		switch (node.Kind) {
			case KindPropertyAccessExpression:
				if (IsIdentifier(node.Name())) {
					return node.Name();
				}
				return null;
			case KindElementAccessExpression:
				final arg = SkipParentheses(node.AsElementAccessExpression().ArgumentExpression);
				if (IsStringOrNumericLiteralLike(arg)) {
					return arg;
				}
				return null;
			default:
		}
		throw "Unhandled case in GetElementOrPropertyAccessName";
	}

	public static function GetInitializerOfBinaryExpression(expr:BinaryExpression):Expression {
		while (IsBinaryExpression(expr.Right)) {
			expr = expr.Right.AsBinaryExpression();
		}
		return expr.Right.Expression();
	}

	public static function IsExpressionWithTypeArgumentsInClassExtendsClause(node:Node):Bool {
		return TryGetClassExtendingExpressionWithTypeArguments(node) != null;
	}

	public static function TryGetClassExtendingExpressionWithTypeArguments(node:Node):ClassLikeDeclaration {
		final r = TryGetClassImplementingOrExtendingExpressionWithTypeArguments(node);
		final cls = r.a;
		final isImplements = r.b;
		if (cls != null && !isImplements) {
			return cls;
		}
		return null;
	}

	// PORT: (class, isImplements) → Pair<ClassLikeDeclaration, Bool> (a = class, b = isImplements).
	public static function TryGetClassImplementingOrExtendingExpressionWithTypeArguments(node:Node):Pair<ClassLikeDeclaration, Bool> {
		if (IsExpressionWithTypeArguments(node)) {
			if (IsHeritageClause(node.Parent) && IsClassLike(node.Parent.Parent)) {
				return new Pair<ClassLikeDeclaration, Bool>(node.Parent.Parent, node.Parent.AsHeritageClause().Token == KindImplementsKeyword);
			}
		}
		return new Pair<ClassLikeDeclaration, Bool>(null, false);
	}

	public static function GetNameOfDeclaration(declaration:Node):Node {
		if (declaration == null) {
			return null;
		}
		final nonAssignedName = GetNonAssignedNameOfDeclaration(declaration);
		if (nonAssignedName != null) {
			return nonAssignedName;
		}
		if (IsFunctionExpression(declaration) || IsArrowFunction(declaration) || IsClassExpression(declaration)) {
			return GetAssignedName(declaration);
		}
		return null;
	}

	public static function GetNonAssignedNameOfDeclaration(declaration:Node):Node {
		// !!!
		switch (declaration.Kind) {
			case KindBinaryExpression | KindCallExpression:
				switch (GetAssignmentDeclarationKind(declaration)) {
					case JSDeclarationKindProperty | JSDeclarationKindThisProperty | JSDeclarationKindExportsProperty:
						final left = declaration.AsBinaryExpression().Left;
						final name = GetElementOrPropertyAccessName(left);
						if (name != null) {
							return name;
						}
						return left;
					case JSDeclarationKindObjectDefinePropertyValue | JSDeclarationKindObjectDefinePropertyExports:
						return declaration.Arguments()[1];
					default:
				}
				return null;
			case KindExportAssignment:
				final expr = declaration.Expression();
				if (IsIdentifier(expr)) {
					return expr;
				}
				return null;
			default:
		}
		return declaration.Name();
	}

	public static function GetAssignedName(node:Node):Node {
		final parent = node.Parent;
		if (parent != null) {
			switch (parent.Kind) {
				case KindPropertyAssignment:
					return parent.AsPropertyAssignment().Name();
				case KindBindingElement:
					return parent.AsBindingElement().Name();
				case KindBinaryExpression:
					if (node == parent.AsBinaryExpression().Right) {
						final left = parent.AsBinaryExpression().Left;
						switch (left.Kind) {
							case KindIdentifier:
								return left;
							case KindPropertyAccessExpression:
								return left.AsPropertyAccessExpression().Name();
							case KindElementAccessExpression:
								final arg = SkipParentheses(left.AsElementAccessExpression().ArgumentExpression);
								if (IsStringOrNumericLiteralLike(arg)) {
									return arg;
								}
							default:
						}
					}
				case KindVariableDeclaration:
					final name = parent.AsVariableDeclaration().Name();
					if (IsIdentifier(name)) {
						return name;
					}
				default:
			}
		}
		return null;
	}

	public static function GetAssignmentDeclarationKind(node:Node):JSDeclarationKind {
		switch (node.Kind) {
			case KindBinaryExpression:
				final bin = node.AsBinaryExpression();
				if (bin.OperatorToken.Kind == KindEqualsToken && IsAccessExpression(bin.Left)) {
					if (IsInJSFile(bin.Left)) {
						if (IsModuleExportsAccessExpression(bin.Left) && !IsExportsIdentifier(bin.Right)) {
							return JSDeclarationKindModuleExports;
						}
						if ((IsModuleExportsAccessExpression(bin.Left.Expression()) || IsExportsIdentifier(bin.Left.Expression()))
							&& GetElementOrPropertyAccessName(bin.Left) != null) {
							return JSDeclarationKindExportsProperty;
						}
						if (bin.Left.Expression().Kind == KindThisKeyword) {
							return JSDeclarationKindThisProperty;
						}
					}
					if (bin.Left.Kind == KindPropertyAccessExpression
						&& IsEntityNameExpressionEx(bin.Left.Expression(), IsInJSFile(bin.Left))
						&& IsIdentifier(bin.Left.Name())
						|| bin.Left.Kind == KindElementAccessExpression && IsEntityNameExpressionEx(bin.Left.Expression(), IsInJSFile(bin.Left))) {
						return JSDeclarationKindProperty;
					}
				}
			case KindCallExpression:
				if (IsInJSFile(node) && IsBindableObjectDefinePropertyCall(node)) {
					final entityName = node.Arguments()[0];
					if (IsExportsIdentifier(entityName) || IsModuleExportsAccessExpression(entityName)) {
						return JSDeclarationKindObjectDefinePropertyExports;
					}
					return JSDeclarationKindObjectDefinePropertyValue;
				}
			default:
		}
		return JSDeclarationKindNone;
	}

	public static function IsBindableObjectDefinePropertyCall(node:Node):Bool {
		final args = node.Arguments();
		if (Core.len(args) == 3) {
			final expr = node.Expression();
			if (IsPropertyAccessExpression(expr)
				&& IsIdentifier(expr.Expression())
				&& expr.Expression().Text() == "Object"
				&& expr.Name().Text() == "defineProperty"
				&& IsStringOrNumericLiteralLike(args[1])
				&& IsBindableStaticNameExpression(args[0] /*excludeThisKeyword*/, true)) {
				return true;
			}
		}
		return false;
	}

	/**
	 * A declaration has a dynamic name if all of the following are true:
	 *   1. The declaration has a computed property name.
	 *   2. The computed name is *not* expressed as a StringLiteral.
	 *   3. The computed name is *not* expressed as a NumericLiteral.
	 *   4. The computed name is *not* expressed as a PlusToken or MinusToken
	 *      immediately followed by a NumericLiteral.
	 */
	public static function HasDynamicName(declaration:Node):Bool {
		final name = GetNameOfDeclaration(declaration);
		return name != null && IsDynamicName(name);
	}

	public static function IsDynamicName(name:Node):Bool {
		var expr:Node = null;
		switch (name.Kind) {
			case KindComputedPropertyName:
				expr = name.Expression();
			case KindElementAccessExpression:
				expr = SkipParentheses(name.AsElementAccessExpression().ArgumentExpression);
			default:
				return false;
		}
		return !IsStringOrNumericLiteralLike(expr) && !IsSignedNumericLiteral(expr);
	}

	public static function IsEntityNameExpression(node:Node):Bool {
		return IsEntityNameExpressionEx(node, false /*allowJS*/);
	}

	public static function IsEntityNameExpressionEx(node:Node, allowJS:Bool):Bool {
		return IsIdentifier(node)
			|| IsPropertyAccessEntityNameExpression(node, allowJS)
			|| allowJS && (node.Kind == KindThisKeyword || isElementAccessEntityNameExpression(node, allowJS));
	}

	public static function IsPropertyAccessEntityNameExpression(node:Node, allowJS:Bool):Bool {
		return IsPropertyAccessExpression(node) && IsIdentifier(node.Name()) && IsEntityNameExpressionEx(node.Expression(), allowJS);
	}

	static function isElementAccessEntityNameExpression(node:Node, allowJS:Bool):Bool {
		return IsElementAccessExpression(node)
			&& IsStringOrNumericLiteralLike(node.AsElementAccessExpression().ArgumentExpression)
			&& IsEntityNameExpressionEx(node.Expression(), allowJS);
	}

	public static function IsDottedName(node:Node):Bool {
		switch (node.Kind) {
			case KindIdentifier | KindThisKeyword | KindSuperKeyword | KindMetaProperty:
				return true;
			case KindPropertyAccessExpression | KindParenthesizedExpression:
				return IsDottedName(node.Expression());
			default:
		}
		return false;
	}

	public static function HasSamePropertyAccessName(node1:Node, node2:Node):Bool {
		if (node1.Kind == KindIdentifier && node2.Kind == KindIdentifier) {
			return node1.Text() == node2.Text();
		} else if (node1.Kind == KindPropertyAccessExpression && node2.Kind == KindPropertyAccessExpression) {
			return node1.AsPropertyAccessExpression().Name().Text() == node2.AsPropertyAccessExpression().Name().Text()
				&& HasSamePropertyAccessName(node1.Expression(), node2.Expression());
		}
		return false;
	}

	public static function IsAmbientModule(node:Node):Bool {
		return IsModuleDeclaration(node) && (node.AsModuleDeclaration().Name().Kind == KindStringLiteral || IsGlobalScopeAugmentation(node));
	}

	public static function IsAmbientModuleSymbolName(s:String):Bool {
		return StringTools.startsWith(s, "\"") && StringTools.endsWith(s, "\"");
	}

	public static function IsExternalModule(file:SourceFile):Bool {
		return file.ExternalModuleIndicator != null;
	}

	public static function IsExternalOrCommonJSModule(file:SourceFile):Bool {
		return file.ExternalModuleIndicator != null || file.CommonJSModuleIndicator != null;
	}

	// TODO: Should we deprecate `IsExternalOrCommonJSModule` in favor of this function?
	public static function IsEffectiveExternalModule(node:SourceFile, compilerOptions:CompilerOptions):Bool {
		return IsExternalModule(node) || (isCommonJSContainingModuleKind(compilerOptions.GetEmitModuleKind()) && node.CommonJSModuleIndicator != null);
	}

	static function isCommonJSContainingModuleKind(kind:ModuleKind):Bool {
		return kind == ModuleKindCommonJS || ModuleKindNode16 <= kind && kind <= ModuleKindNodeNext;
	}

	public static function IsExternalModuleIndicator(node:Statement):Bool {
		// Exported top-level member indicates moduleness
		return IsAnyImportOrReExport(node) || IsExportAssignment(node) || HasSyntacticModifier(node, ModifierFlagsExport);
	}

	public static function IsExportNamespaceAsDefaultDeclaration(node:Node):Bool {
		if (IsExportDeclaration(node)) {
			final decl = node.AsExportDeclaration();
			return IsNamespaceExport(decl.ExportClause) && ModuleExportNameIsDefault(decl.ExportClause.Name());
		}
		return false;
	}

	public static function IsGlobalScopeAugmentation(node:Node):Bool {
		return IsModuleDeclaration(node) && node.AsModuleDeclaration().Keyword == KindGlobalKeyword;
	}

	public static function IsModuleAugmentationExternal(node:Node):Bool {
		// external module augmentation is a ambient module declaration that is either:
		// - defined in the top level scope and source file is an external module
		// - defined inside ambient module declaration located in the top level scope and source file not an external module
		switch (node.Parent.Kind) {
			case KindSourceFile:
				return IsExternalModule(node.Parent.AsSourceFile());
			case KindModuleBlock:
				final grandParent = node.Parent.Parent;
				return IsAmbientModule(grandParent) && IsSourceFile(grandParent.Parent) && !IsExternalModule(grandParent.Parent.AsSourceFile());
			default:
		}
		return false;
	}

	public static function IsModuleWithStringLiteralName(node:Node):Bool {
		return IsModuleDeclaration(node) && node.Name().Kind == KindStringLiteral;
	}

	public static function GetContainingClass(node:Node):Node {
		return FindAncestor(node.Parent, IsClassLike);
	}

	public static function GetExtendsHeritageClauseElement(node:Node):ExpressionWithTypeArgumentsNode {
		return Core.FirstOrNil(GetExtendsHeritageClauseElements(node));
	}

	public static function GetExtendsHeritageClauseElements(node:Node):Array<ExpressionWithTypeArgumentsNode> {
		return GetHeritageElements(node, KindExtendsKeyword);
	}

	public static function GetImplementsHeritageClauseElements(node:Node):Array<ExpressionWithTypeArgumentsNode> {
		return GetHeritageElements(node, KindImplementsKeyword);
	}

	public static function GetHeritageElements(node:Node, kind:Kind):Array<Node> {
		final clause = GetHeritageClause(node, kind);
		if (clause != null) {
			return clause.AsHeritageClause().Types.Nodes;
		}
		return null;
	}

	public static function GetHeritageClause(node:Node, kind:Kind):Node {
		final clauses = getHeritageClauses(node);
		if (clauses != null) {
			for (clause in clauses.Nodes) {
				if (clause.AsHeritageClause().Token == kind) {
					return clause;
				}
			}
		}
		return null;
	}

	static function getHeritageClauses(node:Node):NodeList {
		switch (node.Kind) {
			case KindClassDeclaration:
				return node.AsClassDeclaration().HeritageClauses;
			case KindClassExpression:
				return node.AsClassExpression().HeritageClauses;
			case KindInterfaceDeclaration:
				return node.AsInterfaceDeclaration().HeritageClauses;
			default:
		}
		return null;
	}

	public static function IsPartOfTypeQuery(node:Node):Bool {
		while (node.Kind == KindQualifiedName || node.Kind == KindIdentifier) {
			node = node.Parent;
		}
		return node.Kind == KindTypeQuery;
	}

	/**
	 * This function returns true if the this node's root declaration is a parameter.
	 * For example, passing a `ParameterDeclaration` will return true, as will passing a
	 * binding element that is a child of a `ParameterDeclaration`.
	 *
	 * If you are looking to test that a `Node` is a `ParameterDeclaration`, use `isParameter`.
	 */
	public static function IsPartOfParameterDeclaration(node:Node):Bool {
		return GetRootDeclaration(node).Kind == KindParameter;
	}

	public static function IsInTopLevelContext(node:Node):Bool {
		// The name of a class or function declaration is a BindingIdentifier in its surrounding scope.
		if (IsIdentifier(node)) {
			final parent = node.Parent;
			if ((IsClassDeclaration(parent) || IsFunctionDeclaration(parent)) && parent.Name() == node) {
				node = parent;
			}
		}
		final container = GetThisContainer(node, true /*includeArrowFunctions*/, false /*includeClassComputedPropertyName*/);
		return IsSourceFile(container);
	}

	public static function GetThisContainer(node:Node, includeArrowFunctions:Bool, includeClassComputedPropertyName:Bool):Node {
		while (true) {
			node = node.Parent;
			if (node == null) {
				throw "nil parent in getThisContainer";
			}
			switch (node.Kind) {
				case KindComputedPropertyName:
					if (includeClassComputedPropertyName && IsClassLike(node.Parent.Parent)) {
						return node;
					}
					node = node.Parent.Parent;
				case KindDecorator:
					if (node.Parent.Kind == KindParameter && IsClassElement(node.Parent.Parent)) {
						// If the decorator's parent is a ParameterDeclaration, we resolve the this container from
						// the grandparent class declaration.
						node = node.Parent.Parent;
					} else if (IsClassElement(node.Parent)) {
						// If the decorator's parent is a class element, we resolve the 'this' container
						// from the parent class declaration.
						node = node.Parent;
					}
				case KindArrowFunction:
					if (includeArrowFunctions) {
						return node;
					}
				case KindFunctionDeclaration | KindFunctionExpression | KindModuleDeclaration | KindClassStaticBlockDeclaration | KindPropertyDeclaration |
					KindPropertySignature | KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor |
					KindCallSignature | KindConstructSignature | KindIndexSignature | KindEnumDeclaration | KindSourceFile:
					return node;
				default:
			}
		}
	}

	public static function GetSuperContainer(node:Node, stopOnFunctions:Bool):Node {
		// PORT: Go `for node = node.Parent; node != nil; node = node.Parent` with `continue` → while loop
		// with the post statement at the end of the body and before the `continue`.
		node = node.Parent;
		while (node != null) {
			switch (node.Kind) {
				case KindComputedPropertyName:
					node = node.Parent;
				case KindFunctionDeclaration | KindFunctionExpression | KindArrowFunction:
					if (!stopOnFunctions) {
						node = node.Parent;
						continue;
					}
					return node;
				case KindPropertyDeclaration | KindPropertySignature | KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor |
					KindSetAccessor | KindClassStaticBlockDeclaration:
					return node;
				case KindDecorator:
					// Decorators are always applied outside of the body of a class or method.
					if (node.Parent.Kind == KindParameter && IsClassElement(node.Parent.Parent)) {
						// If the decorator's parent is a ParameterDeclaration, we resolve the this container from
						// the grandparent class declaration.
						node = node.Parent.Parent;
					} else if (IsClassElement(node.Parent)) {
						// If the decorator's parent is a class element, we resolve the 'this' container
						// from the parent class declaration.
						node = node.Parent;
					}
				default:
			}
			node = node.Parent;
		}
		return null;
	}

	public static function GetImmediatelyInvokedFunctionExpression(fn:Node):Node {
		if (IsFunctionExpressionOrArrowFunction(fn)) {
			var prev = fn;
			var parent = fn.Parent;
			while (IsParenthesizedExpression(parent)) {
				prev = parent;
				parent = parent.Parent;
			}
			if (IsCallExpression(parent) && parent.Expression() == prev) {
				return parent;
			}
		}
		return null;
	}

	public static function IsEnumConst(node:Node):Bool {
		return GetCombinedModifierFlags(node) & ModifierFlagsConst != 0;
	}

	public static function ExpressionIsAlias(node:Node):Bool {
		return IsEntityNameExpression(node) || IsClassExpression(node);
	}

	public static function IsInstanceOfExpression(node:Node):Bool {
		return IsBinaryExpression(node) && node.AsBinaryExpression().OperatorToken.Kind == KindInstanceOfKeyword;
	}

	public static function IsAnyImportOrReExport(node:Node):Bool {
		return IsImportNode(node) || IsExportDeclaration(node);
	}

	public static function IsImportNode(node:Node):Bool {
		return IsAnyImportSyntax(node) || node.Kind == KindJSImportDeclaration; // PORT: perf — NodeKindIs without the rest array
	}

	// Checks if the node is a genuine import declation. In particular the re-parsed KindJSImportDeclaration
	// is explicitly excluded because the callers of this function are typically not prepared to handle it properly.
	// For more permissive check, use IsImportNode.
	public static function IsAnyImportSyntax(node:Node):Bool {
		return node.Kind == KindImportDeclaration || node.Kind == KindImportEqualsDeclaration; // PORT: perf — NodeKindIs without the rest array
	}

	public static function IsJsonSourceFile(file:SourceFile):Bool {
		return file.ScriptKind == ScriptKindJSON;
	}

	public static function IsInJsonFile(node:Node):Bool {
		return node.Flags & NodeFlagsJsonFile != 0;
	}

	public static function GetExternalModuleName(node:Node):Expression {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration | KindExportDeclaration:
				return node.ModuleSpecifier();
			case KindImportEqualsDeclaration:
				if (node.AsImportEqualsDeclaration().ModuleReference.Kind == KindExternalModuleReference) {
					return node.AsImportEqualsDeclaration().ModuleReference.Expression();
				}
				return null;
			case KindImportType:
				return getImportTypeNodeLiteral(node);
			case KindCallExpression:
				return Core.FirstOrNil(node.Arguments());
			case KindModuleDeclaration:
				if (IsStringLiteral(node.AsModuleDeclaration().Name())) {
					return node.AsModuleDeclaration().Name();
				}
				return null;
			default:
		}
		throw "Unhandled case in getExternalModuleName";
	}

	public static function GetImportAttributes(node:Node):Node {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				return node.AsImportDeclaration().Attributes;
			case KindExportDeclaration:
				return node.AsExportDeclaration().Attributes;
			default:
		}
		throw "Unhandled case in getImportAttributes";
	}

	static function getImportTypeNodeLiteral(node:Node):Node {
		if (IsImportTypeNode(node)) {
			final importTypeNode = node.AsImportTypeNode();
			if (IsLiteralTypeNode(importTypeNode.Argument)) {
				final literalTypeNode = importTypeNode.Argument.AsLiteralTypeNode();
				if (IsStringLiteral(literalTypeNode.Literal)) {
					return literalTypeNode.Literal;
				}
			}
		}
		return null;
	}

	public static function IsExpressionNode(node:Node):Bool {
		switch (node.Kind) {
			case KindSuperKeyword | KindNullKeyword | KindTrueKeyword | KindFalseKeyword | KindRegularExpressionLiteral | KindArrayLiteralExpression |
				KindObjectLiteralExpression | KindPropertyAccessExpression | KindElementAccessExpression | KindCallExpression | KindNewExpression |
				KindTaggedTemplateExpression | KindAsExpression | KindTypeAssertionExpression | KindSatisfiesExpression | KindNonNullExpression |
				KindParenthesizedExpression | KindFunctionExpression | KindClassExpression | KindArrowFunction | KindVoidExpression |
				KindDeleteExpression | KindTypeOfExpression | KindPrefixUnaryExpression | KindPostfixUnaryExpression | KindBinaryExpression |
				KindConditionalExpression | KindSpreadElement | KindTemplateExpression | KindOmittedExpression | KindJsxElement |
				KindJsxSelfClosingElement | KindJsxFragment | KindYieldExpression | KindAwaitExpression:
				return true;
			case KindMetaProperty:
				// `import.defer` in `import.defer(...)` is not an expression
				return !IsImportCall(node.Parent) || node.Parent.Expression() != node;
			case KindExpressionWithTypeArguments:
				return !IsHeritageClause(node.Parent);
			case KindQualifiedName:
				while (node.Parent.Kind == KindQualifiedName) {
					node = node.Parent;
				}
				return IsTypeQueryNode(node.Parent) || IsJSDocLinkLike(node.Parent) || IsJSDocNameReference(node.Parent) || IsJsxTagName(node);
			case KindPrivateIdentifier:
				return IsBinaryExpression(node.Parent)
					&& node.Parent.AsBinaryExpression().Left == node
					&& node.Parent.AsBinaryExpression().OperatorToken.Kind == KindInKeyword;
			case KindIdentifier:
				if (IsTypeQueryNode(node.Parent) || IsJSDocLinkLike(node.Parent) || IsJSDocNameReference(node.Parent) || IsJsxTagName(node)) {
					return true;
				}
				// PORT: `fallthrough` → the body of the next case, duplicated.
				return IsInExpressionContext(node);
			case KindNumericLiteral | KindBigIntLiteral | KindStringLiteral | KindNoSubstitutionTemplateLiteral | KindThisKeyword:
				return IsInExpressionContext(node);
			default:
				return false;
		}
	}

	public static function IsInExpressionContext(node:Node):Bool {
		final parent = node.Parent;
		switch (parent.Kind) {
			case KindVariableDeclaration | KindParameter | KindPropertyDeclaration | KindPropertySignature | KindEnumMember | KindPropertyAssignment |
				KindBindingElement:
				return parent.Initializer() == node;
			case KindExpressionStatement | KindIfStatement | KindDoStatement | KindWhileStatement | KindReturnStatement | KindWithStatement |
				KindSwitchStatement | KindCaseClause | KindDefaultClause | KindThrowStatement | KindTypeAssertionExpression | KindAsExpression |
				KindTemplateSpan | KindComputedPropertyName | KindSatisfiesExpression:
				return parent.Expression() == node;
			case KindForStatement:
				final s = parent.AsForStatement();
				return s.Initializer == node && s.Initializer.Kind != KindVariableDeclarationList || s.Condition == node || s.Incrementor == node;
			case KindForInStatement | KindForOfStatement:
				final s = parent.AsForInOrOfStatement();
				return s.Initializer == node && s.Initializer.Kind != KindVariableDeclarationList || s.Expression == node;
			case KindDecorator | KindJsxExpression | KindJsxSpreadAttribute | KindSpreadAssignment:
				return true;
			case KindExpressionWithTypeArguments:
				return parent.Expression() == node && !IsPartOfTypeNode(parent);
			case KindShorthandPropertyAssignment:
				return parent.AsShorthandPropertyAssignment().ObjectAssignmentInitializer == node;
			default:
				return IsExpressionNode(parent);
		}
	}

	public static function IsPartOfTypeNode(node:Node):Bool {
		final kind = node.Kind;
		if (kind >= KindFirstTypeNode && kind <= KindLastTypeNode) {
			return true;
		}
		switch (node.Kind) {
			case KindAnyKeyword | KindUnknownKeyword | KindNumberKeyword | KindBigIntKeyword | KindStringKeyword | KindBooleanKeyword | KindSymbolKeyword |
				KindObjectKeyword | KindUndefinedKeyword | KindNullKeyword | KindNeverKeyword:
				return true;
			case KindVoidKeyword:
				return node.Parent.Kind != KindVoidExpression;
			case KindExpressionWithTypeArguments:
				return isPartOfTypeExpressionWithTypeArguments(node);
			case KindTypeParameter:
				return node.Parent.Kind == KindMappedType || node.Parent.Kind == KindInferType;
			case KindIdentifier:
				final parent = node.Parent;
				if (IsQualifiedName(parent) && parent.AsQualifiedName().Right == node) {
					return isPartOfTypeNodeInParent(parent);
				}
				if (IsPropertyAccessExpression(parent) && parent.AsPropertyAccessExpression().Name() == node) {
					return isPartOfTypeNodeInParent(parent);
				}
				return isPartOfTypeNodeInParent(node);
			case KindQualifiedName | KindPropertyAccessExpression | KindThisKeyword:
				return isPartOfTypeNodeInParent(node);
			default:
		}
		return false;
	}

	static function isPartOfTypeNodeInParent(node:Node):Bool {
		final parent = node.Parent;
		if (parent.Kind == KindTypeQuery) {
			return false;
		}
		if (parent.Kind == KindImportType) {
			return !parent.AsImportTypeNode().IsTypeOf;
		}

		// Do not recursively call isPartOfTypeNode on the parent. In the example:
		//
		//     let a: A.B.C;
		//
		// Calling isPartOfTypeNode would consider the qualified name A.B a type node.
		// Only C and A.B.C are type nodes.
		if (parent.Kind >= KindFirstTypeNode && parent.Kind <= KindLastTypeNode) {
			return true;
		}
		switch (parent.Kind) {
			case KindExpressionWithTypeArguments:
				return isPartOfTypeExpressionWithTypeArguments(parent);
			case KindTypeParameter:
				return node == parent.AsTypeParameterDeclaration().Constraint;
			case KindVariableDeclaration | KindParameter | KindPropertyDeclaration | KindPropertySignature | KindFunctionDeclaration |
				KindFunctionExpression | KindArrowFunction | KindConstructor | KindMethodDeclaration | KindMethodSignature | KindGetAccessor |
				KindSetAccessor | KindCallSignature | KindConstructSignature | KindIndexSignature | KindTypeAssertionExpression:
				return node == parent.Type();
			case KindCallExpression | KindNewExpression | KindTaggedTemplateExpression:
				return Slices.Contains(parent.TypeArguments(), node);
			default:
		}
		return false;
	}

	static function isPartOfTypeExpressionWithTypeArguments(node:Node):Bool {
		final parent = node.Parent;
		return IsHeritageClause(parent) && (!IsClassLike(parent.Parent) || parent.AsHeritageClause().Token == KindImplementsKeyword)
			|| IsJSDocImplementsTag(parent)
			|| IsJSDocAugmentsTag(parent);
	}

	public static function IsJSDocLinkLike(node:Node):Bool {
		final k = node.Kind; // PORT: perf — NodeKindIs without the rest array
		return k == KindJSDocLink || k == KindJSDocLinkCode || k == KindJSDocLinkPlain;
	}

	public static function IsJSDocTag(node:Node):Bool {
		return node.Kind >= KindFirstJSDocTagNode && node.Kind <= KindLastJSDocTagNode;
	}

	public static function IsSuperCall(node:Node):Bool {
		return IsCallExpression(node) && node.Expression().Kind == KindSuperKeyword;
	}

	public static function IsImportCall(node:Node):Bool {
		if (!IsCallExpression(node)) {
			return false;
		}
		final e = node.Expression();
		return e.Kind == KindImportKeyword || IsMetaProperty(e) && e.AsMetaProperty().KeywordToken == KindImportKeyword && e.Text() == "defer";
	}

	public static function IsComputedNonLiteralName(name:Node):Bool {
		return IsComputedPropertyName(name) && !IsStringOrNumericLiteralLike(name.Expression());
	}

	public static function IsQuestionToken(node:Node):Bool {
		return node != null && node.Kind == KindQuestionToken;
	}

	public static function EntityNameToString(name:Node, getTextOfNode:(Node) -> String):String {
		switch (name.Kind) {
			case KindThisKeyword:
				return "this";
			case KindIdentifier | KindPrivateIdentifier:
				if (NodeIsSynthesized(name) || getTextOfNode == null) {
					return name.Text();
				}
				return getTextOfNode(name);
			case KindQualifiedName:
				return EntityNameToString(name.AsQualifiedName().Left, getTextOfNode) + "." + EntityNameToString(name.AsQualifiedName().Right, getTextOfNode);
			case KindPropertyAccessExpression:
				return EntityNameToString(name.Expression(), getTextOfNode) + "." + EntityNameToString(name.AsPropertyAccessExpression().Name(), getTextOfNode);
			case KindJsxNamespacedName:
				return EntityNameToString(name.AsJsxNamespacedName().Namespace, getTextOfNode)
					+ ":"
					+ EntityNameToString(name.AsJsxNamespacedName().Name(), getTextOfNode);
			default:
		}
		throw "Unhandled case in EntityNameToString";
	}

	public static function GetTextOfPropertyName(name:Node):String {
		final text = TryGetTextOfPropertyName(name).value;
		return text;
	}

	public static function TryGetTextOfPropertyName(name:Node):ValueOk<String> {
		switch (name.Kind) {
			case KindIdentifier | KindPrivateIdentifier | KindStringLiteral | KindNumericLiteral | KindBigIntLiteral | KindNoSubstitutionTemplateLiteral:
				return new ValueOk(name.Text(), true);
			case KindComputedPropertyName:
				if (IsStringOrNumericLiteralLike(name.Expression())) {
					return new ValueOk(name.Expression().Text(), true);
				}
			case KindJsxNamespacedName:
				return new ValueOk(name.AsJsxNamespacedName().Namespace.Text() + ":" + name.Name().Text(), true);
			default:
		}
		return new ValueOk("", false);
	}

	public static function IsJSDocNode(node:Node):Bool {
		return node.Kind >= KindFirstJSDocNode && node.Kind <= KindLastJSDocNode;
	}

	public static function IsNonWhitespaceToken(node:Node):Bool {
		return IsTokenKind(node.Kind) && !IsWhitespaceOnlyJsxText(node);
	}

	public static function IsWhitespaceOnlyJsxText(node:Node):Bool {
		return node.Kind == KindJsxText && node.AsJsxText().ContainsOnlyTriviaWhiteSpaces;
	}

	public static function GetNewTargetContainer(node:Node):Node {
		final container = GetThisContainer(node, false /*includeArrowFunctions*/, false /*includeClassComputedPropertyName*/);
		if (container != null) {
			switch (container.Kind) {
				case KindConstructor | KindFunctionDeclaration | KindFunctionExpression:
					return container;
				default:
			}
		}
		return null;
	}

	public static function GetEnclosingBlockScopeContainer(node:Node):Node {
		return FindAncestor(node.Parent, function(current:Node):Bool {
			return IsBlockScope(current, current.Parent);
		});
	}

	public static function IsBlockScope(node:Node, parentNode:Node):Bool {
		switch (node.Kind) {
			case KindSourceFile | KindCaseBlock | KindCatchClause | KindModuleDeclaration | KindForStatement | KindForInStatement | KindForOfStatement |
				KindConstructor | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindFunctionDeclaration | KindFunctionExpression |
				KindArrowFunction | KindPropertyDeclaration | KindClassStaticBlockDeclaration:
				return true;
			case KindBlock:
				// function block is not considered block-scope container
				// see comment in binder.ts: bind(...), case for SyntaxKind.Block
				return !IsFunctionLikeOrClassStaticBlockDeclaration(parentNode);
			default:
		}
		return false;
	}

	public static function GetMeaningFromDeclaration(node:Node):SemanticMeaning {
		switch (node.Kind) {
			case KindVariableDeclaration:
				return SemanticMeaningValue;
			case KindParameter | KindBindingElement | KindPropertyDeclaration | KindPropertySignature | KindPropertyAssignment |
				KindShorthandPropertyAssignment | KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor |
				KindFunctionDeclaration | KindFunctionExpression | KindArrowFunction | KindCatchClause | KindJsxAttribute:
				return SemanticMeaningValue;

			case KindTypeParameter | KindInterfaceDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindTypeLiteral:
				return SemanticMeaningType;
			case KindEnumMember | KindClassDeclaration:
				return SemanticMeaningValue | SemanticMeaningType;

			case KindModuleDeclaration:
				if (IsAmbientModule(node)) {
					return SemanticMeaningNamespace | SemanticMeaningValue;
				} else if (GetModuleInstanceState(node) == ModuleInstanceStateInstantiated) {
					return SemanticMeaningNamespace | SemanticMeaningValue;
				} else {
					return SemanticMeaningNamespace;
				}

			case KindEnumDeclaration | KindNamedImports | KindImportSpecifier | KindImportEqualsDeclaration | KindImportDeclaration |
				KindJSImportDeclaration | KindExportAssignment | KindExportDeclaration:
				return SemanticMeaningAll;

			// An external module can be a Value
			case KindSourceFile:
				return SemanticMeaningNamespace | SemanticMeaningValue;
			default:
		}

		return SemanticMeaningAll;
	}

	public static function IsPropertyAccessOrQualifiedName(node:Node):Bool {
		return node.Kind == KindPropertyAccessExpression || node.Kind == KindQualifiedName;
	}

	public static function IsLabelName(node:Node):Bool {
		return IsLabelOfLabeledStatement(node) || IsJumpStatementTarget(node);
	}

	public static function IsLabelOfLabeledStatement(node:Node):Bool {
		if (!IsIdentifier(node)) {
			return false;
		}
		if (!IsLabeledStatement(node.Parent)) {
			return false;
		}
		return node == node.Parent.Label();
	}

	public static function IsJumpStatementTarget(node:Node):Bool {
		if (!IsIdentifier(node)) {
			return false;
		}
		if (!IsBreakOrContinueStatement(node.Parent)) {
			return false;
		}
		return node == node.Parent.Label();
	}

	public static function IsBreakOrContinueStatement(node:Node):Bool {
		return node.Kind == KindBreakStatement || node.Kind == KindContinueStatement; // PORT: perf — NodeKindIs without the rest array
	}

	// GetModuleInstanceState is used during binding as well as in transformations and tests, and therefore may be invoked
	// with a node that does not yet have its `Parent` pointer set. In this case, an `ancestors` represents a stack of
	// virtual `Parent` pointers that can be used to walk up the tree. Since `getModuleInstanceStateForAliasTarget` may
	// potentially walk up out of the provided `Node`, merely setting the parent pointers for a given `ModuleDeclaration`
	// prior to invoking `GetModuleInstanceState` is not sufficient. It is, however, necessary that the `Parent` pointers
	// for all ancestors of the `Node` provided to `GetModuleInstanceState` have been set.

	// Push a virtual parent pointer onto `ancestors` and return it.
	// PORT: Go `append` may share the backing array between the caller's slice and the result; the callers only
	// ever extend the stack they own or a copy whose shorter prefix they keep reading, so a copy keeps Go's
	// observable behaviour (a caller's slice never sees elements appended by a callee).
	static function pushAncestor(ancestors:Array<Node>, parent:Node):Array<Node> {
		final result = ancestors != null ? ancestors.copy() : [];
		result.push(parent);
		return result;
	}

	// If a virtual `Parent` exists on the stack, returns the previous stack entry and the virtual `Parent“.
	// Otherwise, we return `nil` and the value of `node.Parent`.
	static function popAncestor(ancestors:Array<Node>, node:Node):Pair<Array<Node>, Node> {
		if (Core.len(ancestors) == 0) {
			return new Pair(null, node.Parent);
		}
		final n = ancestors.length - 1;
		return new Pair(ancestors.slice(0, n), ancestors[n]);
	}

	public static function GetModuleInstanceState(node:Node):ModuleInstanceState {
		return getModuleInstanceState(node, null, null);
	}

	static function getModuleInstanceState(node:Node, ancestors:Array<Node>, visited:IntMap<ModuleInstanceState>):ModuleInstanceState {
		final module = node.AsModuleDeclaration();
		if (module.Body != null) {
			return getModuleInstanceStateCached(module.Body, pushAncestor(ancestors, node), visited);
		} else {
			return ModuleInstanceStateInstantiated;
		}
	}

	static function getModuleInstanceStateCached(node:Node, ancestors:Array<Node>, visited:IntMap<ModuleInstanceState>):ModuleInstanceState {
		if (visited == null) {
			visited = new IntMap<ModuleInstanceState>();
		}
		final nodeId = GetNodeId(node);
		if (visited.exists(nodeId)) {
			final cached = visited.get(nodeId);
			if (cached != ModuleInstanceStateUnknown) {
				return cached;
			}
			return ModuleInstanceStateNonInstantiated;
		}
		visited.set(nodeId, ModuleInstanceStateUnknown);
		final result = getModuleInstanceStateWorker(node, ancestors, visited);
		visited.set(nodeId, result);
		return result;
	}

	static function getModuleInstanceStateWorker(node:Node, ancestors:Array<Node>, visited:IntMap<ModuleInstanceState>):ModuleInstanceState {
		// A module is uninstantiated if it contains only
		switch (node.Kind) {
			case KindInterfaceDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				return ModuleInstanceStateNonInstantiated;
			case KindEnumDeclaration:
				if (IsEnumConst(node)) {
					return ModuleInstanceStateConstEnumOnly;
				}
			case KindImportDeclaration | KindJSImportDeclaration | KindImportEqualsDeclaration:
				if (!HasSyntacticModifier(node, ModifierFlagsExport)) {
					return ModuleInstanceStateNonInstantiated;
				}
			case KindExportDeclaration:
				final decl = node.AsExportDeclaration();
				if (decl.ModuleSpecifier == null && decl.ExportClause != null && decl.ExportClause.Kind == KindNamedExports) {
					var state = ModuleInstanceStateNonInstantiated;
					ancestors = pushAncestor(ancestors, node);
					ancestors = pushAncestor(ancestors, decl.ExportClause);
					// PORT: Go ranges over a nil slice (`export {}`); Haxe cannot.
					final specifiers = decl.ExportClause.Elements();
					if (specifiers != null) for (specifier in specifiers) {
						final specifierState = getModuleInstanceStateForAliasTarget(specifier, ancestors, visited);
						if ((specifierState : Int) > (state : Int)) {
							state = specifierState;
						}
						if (state == ModuleInstanceStateInstantiated) {
							return state;
						}
					}
					return state;
				}
			case KindModuleBlock:
				var state = ModuleInstanceStateNonInstantiated;
				ancestors = pushAncestor(ancestors, node);
				final childAncestors = ancestors;
				node.ForEachChild(function(n:Node):Bool {
					final childState = getModuleInstanceStateCached(n, childAncestors, visited);
					switch (childState) {
						case ModuleInstanceStateNonInstantiated:
							return false;
						case ModuleInstanceStateConstEnumOnly:
							state = ModuleInstanceStateConstEnumOnly;
							return false;
						case ModuleInstanceStateInstantiated:
							state = ModuleInstanceStateInstantiated;
							return true;
						default:
					}
					throw "Unhandled case in getModuleInstanceStateWorker";
				});
				return state;
			case KindModuleDeclaration:
				return getModuleInstanceState(node, ancestors, visited);
			default:
		}
		return ModuleInstanceStateInstantiated;
	}

	static function getModuleInstanceStateForAliasTarget(node:Node, ancestors:Array<Node>, visited:IntMap<ModuleInstanceState>):ModuleInstanceState {
		final name = node.PropertyNameOrName();
		if (name.Kind != KindIdentifier) {
			// Skip for invalid syntax like this: export { "x" }
			return ModuleInstanceStateInstantiated;
		}
		var popped = popAncestor(ancestors, node);
		ancestors = popped.a;
		var p = popped.b;
		while (p != null) {
			if (IsBlock(p) || IsModuleBlock(p) || IsSourceFile(p)) {
				var found = ModuleInstanceStateUnknown;
				final statementsAncestors = pushAncestor(ancestors, p);
				// PORT: Go ranges over a nil slice (empty block); Haxe cannot.
				final statements = p.Statements();
				if (statements != null) for (statement in statements) {
					if (NodeHasName(statement, name)) {
						final state = getModuleInstanceStateCached(statement, statementsAncestors, visited);
						if (found == ModuleInstanceStateUnknown || (state : Int) > (found : Int)) {
							found = state;
						}
						if (found == ModuleInstanceStateInstantiated) {
							return found;
						}
						if (statement.Kind == KindImportEqualsDeclaration) {
							// Treat re-exports of import aliases as instantiated since they're ambiguous. This is consistent
							// with `export import x = mod.x` being treated as instantiated:
							//   import x = mod.x;
							//   export { x };
							found = ModuleInstanceStateInstantiated;
						}
					}
				}
				if (found != ModuleInstanceStateUnknown) {
					return found;
				}
			}
			popped = popAncestor(ancestors, p);
			ancestors = popped.a;
			p = popped.b;
		}
		// Couldn't locate, assume could refer to a value
		return ModuleInstanceStateInstantiated;
	}

	public static function IsInstantiatedModule(node:Node, preserveConstEnums:Bool):Bool {
		final moduleState = GetModuleInstanceState(node);
		return moduleState == ModuleInstanceStateInstantiated || (preserveConstEnums && moduleState == ModuleInstanceStateConstEnumOnly);
	}

	public static function NodeHasName(statement:Node, id:Node):Bool {
		final name = statement.Name();
		if (name != null) {
			return IsIdentifier(name) && name.Text() == id.Text();
		}
		if (IsVariableStatement(statement)) {
			final declarations = statement.AsVariableStatement().DeclarationList.AsVariableDeclarationList().Declarations.Nodes;
			return Core.Some(declarations, function(d:Node):Bool {
				return NodeHasName(d, id);
			});
		}
		return false;
	}

	public static function IsInternalModuleImportEqualsDeclaration(node:Node):Bool {
		return IsImportEqualsDeclaration(node) && node.AsImportEqualsDeclaration().ModuleReference.Kind != KindExternalModuleReference;
	}

	public static function IsConstAssertion(node:Node):Bool {
		switch (node.Kind) {
			case KindAsExpression | KindTypeAssertionExpression:
				return IsConstTypeReference(node.Type());
			default:
		}
		return false;
	}

	public static function IsConstTypeReference(node:Node):Bool {
		return IsTypeReferenceNode(node)
			&& Core.len(node.TypeArguments()) == 0
			&& IsIdentifier(node.AsTypeReferenceNode().TypeName)
			&& node.AsTypeReferenceNode().TypeName.Text() == "const";
	}

	public static function IsGlobalSourceFile(node:Node):Bool {
		return node.Kind == KindSourceFile && !IsExternalOrCommonJSModule(node.AsSourceFile());
	}

	public static function IsParameterLike(node:Node):Bool {
		switch (node.Kind) {
			case KindParameter | KindTypeParameter:
				return true;
			default:
		}
		return false;
	}

	public static function GetDeclarationOfKind(symbol:Symbol, kind:Kind):Node {
		if (symbol.Declarations != null) {
			for (declaration in symbol.Declarations) {
				if (declaration.Kind == kind) {
					return declaration;
				}
			}
		}
		return null;
	}

	public static function FindConstructorDeclaration(node:ClassLikeDeclaration):Node {
		final members = node.Members();
		if (members != null) {
			for (member in members) {
				if (IsConstructorDeclaration(member) && NodeIsPresent(member.Body())) {
					return member;
				}
			}
		}
		return null;
	}

	public static function GetFirstIdentifier(node:Node):Node {
		switch (node.Kind) {
			case KindIdentifier:
				return node;
			case KindQualifiedName:
				return GetFirstIdentifier(node.AsQualifiedName().Left);
			case KindPropertyAccessExpression:
				return GetFirstIdentifier(node.AsPropertyAccessExpression().Expression);
			default:
		}
		throw "Unhandled case in GetFirstIdentifier";
	}

	public static function GetNamespaceDeclarationNode(node:Node):Node {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				final importClause = node.ImportClause();
				if (importClause != null
					&& importClause.AsImportClause().NamedBindings != null
					&& IsNamespaceImport(importClause.AsImportClause().NamedBindings)) {
					return importClause.AsImportClause().NamedBindings;
				}
			case KindImportEqualsDeclaration:
				return node;
			case KindExportDeclaration:
				final exportClause = node.AsExportDeclaration().ExportClause;
				if (exportClause != null && IsNamespaceExport(exportClause)) {
					return exportClause;
				}
			default:
				throw "Unhandled case in getNamespaceDeclarationNode";
		}
		return null;
	}

	public static function ModuleExportNameIsDefault(node:Node):Bool {
		return node.Text() == InternalSymbolNameDefault;
	}

	public static function IsDefaultImport(node:Node /*ImportDeclaration | ImportEqualsDeclaration | ExportDeclaration*/):Bool {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				final importClause = node.ImportClause();
				return importClause != null && importClause.AsImportClause().name != null;
			default:
		}
		return false;
	}

	public static function GetImpliedNodeFormatForFile(path:String, packageJsonType:String):ModuleKind {
		var impliedNodeFormat = Core.ResolutionModeNone;
		if (Tspath.FileExtensionIsOneOf(path, [Tspath.ExtensionDmts, Tspath.ExtensionMts, Tspath.ExtensionMjs])) {
			impliedNodeFormat = Core.ResolutionModeESM;
		} else if (Tspath.FileExtensionIsOneOf(path, [Tspath.ExtensionDcts, Tspath.ExtensionCts, Tspath.ExtensionCjs])) {
			impliedNodeFormat = Core.ResolutionModeCommonJS;
		} else if (Tspath.FileExtensionIsOneOf(path, [
			Tspath.ExtensionDts,
			Tspath.ExtensionTs,
			Tspath.ExtensionTsx,
			Tspath.ExtensionJs,
			Tspath.ExtensionJsx
		])) {
			impliedNodeFormat = Core.IfElse(packageJsonType == "module", Core.ResolutionModeESM, Core.ResolutionModeCommonJS);
		}

		return impliedNodeFormat;
	}

	public static function GetEmitModuleFormatOfFileWorker(fileName:String, options:CompilerOptions, sourceFileMetaData:SourceFileMetaData):ModuleKind {
		final result = GetImpliedNodeFormatForEmitWorker(fileName, options.GetEmitModuleKind(), sourceFileMetaData);
		if (result != ModuleKindNone) {
			return result;
		}
		return options.GetEmitModuleKind();
	}

	public static function GetImpliedNodeFormatForEmitWorker(fileName:String, emitModuleKind:ModuleKind, sourceFileMetaData:SourceFileMetaData):ResolutionMode {
		if (ModuleKindNode16 <= emitModuleKind && emitModuleKind <= ModuleKindNodeNext) {
			return sourceFileMetaData.ImpliedNodeFormat;
		}
		if (sourceFileMetaData.ImpliedNodeFormat == ModuleKindCommonJS
			&& (sourceFileMetaData.PackageJsonType == "commonjs"
				|| Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionCjs, Tspath.ExtensionCts]))) {
			return ModuleKindCommonJS;
		}
		if (sourceFileMetaData.ImpliedNodeFormat == ModuleKindESNext
			&& (sourceFileMetaData.PackageJsonType == "module"
				|| Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionMjs, Tspath.ExtensionMts]))) {
			return ModuleKindESNext;
		}
		return ModuleKindNone;
	}

	public static function GetDeclarationContainer(node:Node):Node {
		return FindAncestor(GetRootDeclaration(node), function(node:Node):Bool {
			switch (node.Kind) {
				case KindVariableDeclaration | KindVariableDeclarationList | KindImportSpecifier | KindNamedImports | KindNamespaceImport |
					KindImportClause:
					return false;
				default:
					return true;
			}
		}).Parent;
	}

	// Indicates that a symbol is an alias that does not merge with a local declaration.
	// OR Is a JSContainer which may merge an alias with a local declaration
	public static function IsNonLocalAlias(symbol:Symbol, excludes:SymbolFlags):Bool {
		if (symbol == null) {
			return false;
		}
		return symbol.Flags & (SymbolFlagsAlias | excludes) == SymbolFlagsAlias
			|| symbol.Flags & SymbolFlagsAlias != 0 && symbol.Flags & SymbolFlagsAssignment != 0;
	}

	// An alias symbol is created by one of the following declarations:
	//
	//	import <symbol> = ...
	//	const <symbol> = ... (JS only)
	//	const { <symbol>, ... } = ... (JS only)
	//	import <symbol> from ...
	//	import * as <symbol> from ...
	//	import { x as <symbol> } from ...
	//	export { x as <symbol> } from ...
	//	export * as ns <symbol> from ...
	//	export = <EntityNameExpression>
	//	export default <EntityNameExpression>
	//	module.exports = <EntityNameExpression> (JS only)
	//	module.exports.<symbol> = <EntityNameExpression> (JS only)
	//	exports.<symbol> = <EntityNameExpression> (JS only)
	public static function IsAliasSymbolDeclaration(node:Node):Bool {
		switch (node.Kind) {
			case KindImportEqualsDeclaration | KindNamespaceExportDeclaration | KindNamespaceImport | KindNamespaceExport | KindImportSpecifier |
				KindExportSpecifier:
				return true;
			case KindImportClause:
				return node.AsImportClause().Name() != null;
			case KindExportAssignment:
				return ExpressionIsAlias(node.Expression());
			case KindVariableDeclaration | KindBindingElement:
				return IsVariableDeclarationInitializedToRequire(node);
			case KindBinaryExpression:
				switch (GetAssignmentDeclarationKind(node)) {
					case JSDeclarationKindModuleExports | JSDeclarationKindExportsProperty:
						return ExpressionIsAlias(node.AsBinaryExpression().Right);
					default:
				}
			default:
		}
		return false;
	}

	public static function IsParseTreeNode(node:Node):Bool {
		return node.Flags & NodeFlagsSynthesized == 0;
	}

	// Returns a token if position is in [start-of-leading-trivia, end), includes JSDoc only if requested
	public static function GetNodeAtPosition(file:SourceFile, position:Int, includeJSDoc:Bool):Node {
		var current = file.AsNode();
		while (true) {
			var child:Node = null;
			if (includeJSDoc) {
				final jsdocs = current.JSDoc(file);
				if (jsdocs != null) {
					for (jsdoc in jsdocs) {
						if (nodeContainsPosition(jsdoc, position)) {
							child = jsdoc;
							break;
						}
					}
				}
			}
			if (child == null) {
				current.ForEachChild(function(node:Node):Bool {
					if (nodeContainsPosition(node, position)) {
						child = node;
						return true;
					}
					return false;
				});
			}
			if (child == null || IsMetaProperty(child)) {
				return current;
			}
			current = child;
		}
	}

	static function nodeContainsPosition(node:Node, position:Int):Bool {
		return node.Kind >= KindFirstNode && node.Pos() <= position && (position < node.End() || position == node.End() && node.Kind == KindEndOfFile);
	}

	// PORT: Go returns (index, size) with byte offsets; here a Pair of UTF-16 code-unit offsets
	// (PORTING.md §5). "import"/"require" are ASCII, so the matching is the same.
	static function findImportOrRequire(text:String, start:Int):Pair<Int, Int> {
		var index = start > 0 ? start : 0;
		var size = 0;
		final n = text.length;
		while (index < n) {
			final next = Strings.IndexAnyFrom(text, "ir", index); // PORT: perf (Go text[index:] is free; hxcpp substring copies: quadratic)
			if (next < 0) {
				break;
			}
			index += next;

			var expected:String;
			if (StringTools.fastCodeAt(text, index) == "i".code) {
				size = 6;
				expected = "import";
			} else {
				size = 7;
				expected = "require";
			}
			if (index + size <= n && text.substring(index, index + size) == expected) {
				return new Pair(index, size);
			}
			index++;
		}

		return new Pair(-1, 0);
	}

	public static function ForEachDynamicImportOrRequireCall(file:SourceFile, includeTypeSpaceImports:Bool, requireStringLiteralLikeArgument:Bool,
			cb:(node:Node, argument:Expression) -> Bool):Bool {
		final isJavaScriptFile = IsInJSFile(file.AsNode());
		var r = findImportOrRequire(file.Text(), 0);
		var lastIndex = r.a;
		var size = r.b;
		while (lastIndex >= 0) {
			final node = GetNodeAtPosition(file, lastIndex, isJavaScriptFile && includeTypeSpaceImports);
			if (isJavaScriptFile && IsRequireCall(node, requireStringLiteralLikeArgument)) {
				if (cb(node, node.Arguments()[0])) {
					return true;
				}
			} else if (IsImportCall(node)
				&& Core.len(node.Arguments()) > 0
				&& (!requireStringLiteralLikeArgument || IsStringLiteralLike(node.Arguments()[0]))) {
				if (cb(node, node.Arguments()[0])) {
					return true;
				}
			} else if (includeTypeSpaceImports && IsLiteralImportTypeNode(node)) {
				if (cb(node, node.AsImportTypeNode().Argument.AsLiteralTypeNode().Literal)) {
					return true;
				}
			}
			// skip past import/require
			lastIndex += size;
			r = findImportOrRequire(file.Text(), lastIndex);
			lastIndex = r.a;
			size = r.b;
		}
		return false;
	}

	// Returns true if the node is a CallExpression to the identifier 'require' with
	// exactly one argument (of the form 'require("name")').
	// This function does not test if the node is in a JavaScript file or not.
	public static function IsRequireCall(node:Node, requireStringLiteralLikeArgument:Bool):Bool {
		if (!IsCallExpression(node)) {
			return false;
		}
		final call = node.AsCallExpression();
		if (!IsIdentifier(call.Expression) || call.Expression.Text() != "require") {
			return false;
		}
		if (Core.len(call.Arguments.Nodes) != 1) {
			return false;
		}
		return !requireStringLiteralLikeArgument || IsStringLiteralLike(call.Arguments.Nodes[0]);
	}

	public static function IsRequireVariableStatement(node:Node):Bool {
		if (IsVariableStatement(node)) {
			final declarations = node.AsVariableStatement().DeclarationList.AsVariableDeclarationList().Declarations.Nodes;
			if (Core.len(declarations) > 0) {
				return Core.Every(declarations, IsVariableDeclarationInitializedToRequire);
			}
		}
		return false;
	}

	public static function GetJSXImplicitImportBase(compilerOptions:CompilerOptions, file:SourceFile):String {
		final jsxImportSourcePragma = GetPragmaFromSourceFile(file, "jsximportsource");
		final jsxRuntimePragma = GetPragmaFromSourceFile(file, "jsxruntime");
		if (GetPragmaArgument(jsxRuntimePragma, "factory") == "classic") {
			return "";
		}
		if (compilerOptions.Jsx == JsxEmitReactJSX
			|| compilerOptions.Jsx == JsxEmitReactJSXDev
			|| compilerOptions.JsxImportSource != ""
			|| jsxImportSourcePragma != null
			|| GetPragmaArgument(jsxRuntimePragma, "factory") == "automatic") {
			var result = GetPragmaArgument(jsxImportSourcePragma, "factory");
			if (result == "") {
				result = compilerOptions.JsxImportSource;
			}
			if (result == "") {
				result = "react";
			}
			return result;
		}
		return "";
	}

	public static function GetJSXRuntimeImport(base:String, options:CompilerOptions):String {
		if (base == "") {
			return base;
		}
		return base + "/" + Core.IfElse(options.Jsx == JsxEmitReactJSXDev, "jsx-dev-runtime", "jsx-runtime");
	}

	// PORT: Go returns &file.Pragmas[i]; Pragma is a class here, so the element itself.
	public static function GetPragmaFromSourceFile(file:SourceFile, name:String):Pragma {
		var result:Pragma = null;
		if (file != null) {
			for (i in 0...Core.len(file.Pragmas)) {
				if (file.Pragmas[i].Name == name) {
					result = file.Pragmas[i]; // Last one wins
				}
			}
		}
		return result;
	}

	public static function GetPragmaArgument(pragma:Pragma, name:String):String {
		if (pragma != null) {
			if (pragma.Args != null && pragma.Args.exists(name)) {
				final arg = pragma.Args.get(name);
				return arg.Value;
			}
		}
		return "";
	}

	// Of the form: `const x = require("x")` or `const { x } = require("x")` or with `var` or `let`
	// The variable must not be exported and must not have a type annotation, even a jsdoc one.
	// The initializer must be a call to `require` with a string literal or a string literal-like argument.
	public static function IsVariableDeclarationInitializedToRequire(node:Node):Bool {
		if (node.Kind == KindBindingElement) {
			node = node.Parent.Parent;
		}
		return isVariableDeclarationInitializedWithRequireHelper(node, false /*allowAccessedRequire*/);
	}

	public static function IsVariableDeclarationInitializedToBareOrAccessedRequire(node:Node):Bool {
		return isVariableDeclarationInitializedWithRequireHelper(node, true /*allowAccessedRequire*/);
	}

	static function isVariableDeclarationInitializedWithRequireHelper(node:Node, allowAccessedRequire:Bool):Bool {
		if (!IsInJSFile(node)) {
			return false;
		}
		if (node.Kind != KindVariableDeclaration) {
			return false;
		}
		var initializer = node.Initializer();
		if (initializer == null) {
			return false;
		}
		if (allowAccessedRequire) {
			initializer = GetLeftmostAccessExpression(initializer);
		}

		return node.Parent.Parent.ModifierFlags() & ModifierFlagsExport == 0
			&& node.Type() == null
			&& IsRequireCall(initializer, true /*requireStringLiteralLikeArgument*/);
	}

	public static function GetModuleSpecifierOfBareOrAccessedRequire(node:Node):Node {
		if (isVariableDeclarationInitializedWithRequireHelper(node, false /*allowAccessedRequire*/)) {
			return node.Initializer().Arguments()[0];
		}
		if (isVariableDeclarationInitializedWithRequireHelper(node, true /*allowAccessedRequire*/)) {
			final leftmost = GetLeftmostAccessExpression(node.Initializer());
			if (IsRequireCall(leftmost, true /*requireStringLiteralLikeArgument*/)) {
				return leftmost.Arguments()[0];
			}
		}
		return null;
	}

	public static function IsModuleExportsAccessExpression(node:Node):Bool {
		if (IsAccessExpression(node) && IsModuleIdentifier(node.Expression())) {
			final name = GetElementOrPropertyAccessName(node);
			if (name != null) {
				return name.Text() == "exports";
			}
		}
		return false;
	}

	public static function IsModuleExportsQualifiedName(node:Node):Bool {
		return IsQualifiedName(node) && IsModuleIdentifier(node.AsQualifiedName().Left) && node.AsQualifiedName().Right.Text() == "exports";
	}

	public static function IsCheckJSEnabledForFile(sourceFile:SourceFile, compilerOptions:CompilerOptions):Bool {
		if (sourceFile.CheckJsDirective != null) {
			return sourceFile.CheckJsDirective.Enabled;
		}
		return compilerOptions.CheckJs == TSTrue;
	}

	public static function IsPlainJSFile(file:SourceFile, checkJs:Tristate):Bool {
		return file != null
			&& (file.ScriptKind == ScriptKindJS || file.ScriptKind == ScriptKindJSX)
			&& file.CheckJsDirective == null
			&& checkJs == TSUnknown;
	}

	public static function GetLeftmostAccessExpression(expr:Node):Node {
		while (IsAccessExpression(expr)) {
			expr = expr.Expression();
		}
		return expr;
	}

	public static function IsTypeOnlyImportDeclaration(node:Node):Bool {
		switch (node.Kind) {
			case KindImportSpecifier:
				return node.IsTypeOnly() || node.Parent.Parent.IsTypeOnly();
			case KindNamespaceImport:
				return node.Parent.IsTypeOnly();
			case KindImportClause | KindImportEqualsDeclaration:
				return node.IsTypeOnly();
			default:
		}
		return false;
	}

	static function isTypeOnlyExportDeclaration(node:Node):Bool {
		switch (node.Kind) {
			case KindExportSpecifier:
				return node.IsTypeOnly() || node.Parent.Parent.IsTypeOnly();
			case KindExportDeclaration:
				final d = node.AsExportDeclaration();
				return d.IsTypeOnly && d.ModuleSpecifier != null && d.ExportClause == null;
			case KindNamespaceExport:
				return node.Parent.IsTypeOnly();
			default:
		}
		return false;
	}

	public static function IsTypeOnlyImportOrExportDeclaration(node:Node):Bool {
		return IsTypeOnlyImportDeclaration(node) || isTypeOnlyExportDeclaration(node);
	}

	public static function IsExclusivelyTypeOnlyImportOrExport(node:Node):Bool {
		switch (node.Kind) {
			case KindExportDeclaration:
				return node.IsTypeOnly();
			case KindImportDeclaration | KindJSImportDeclaration:
				final importClause = node.ImportClause();
				if (importClause != null) {
					return importClause.AsImportClause().AsNode().IsTypeOnly();
				}
			case KindJSDocImportTag:
				final importClause = node.ImportClause();
				if (importClause != null) {
					return importClause.AsImportClause().AsNode().IsTypeOnly();
				}
			default:
		}
		return false;
	}

	public static function GetClassLikeDeclarationOfSymbol(symbol:Symbol):Node {
		return Core.Find(symbol.Declarations, IsClassLike);
	}

	public static function IsCallLikeExpression(node:Node):Bool {
		switch (node.Kind) {
			case KindJsxOpeningElement | KindJsxSelfClosingElement | KindJsxOpeningFragment | KindCallExpression | KindNewExpression |
				KindTaggedTemplateExpression | KindDecorator:
				return true;
			case KindBinaryExpression:
				return node.AsBinaryExpression().OperatorToken.Kind == KindInstanceOfKeyword;
			default:
		}
		return false;
	}

	public static function IsJsxCallLike(node:Node):Bool {
		switch (node.Kind) {
			case KindJsxOpeningElement | KindJsxSelfClosingElement | KindJsxOpeningFragment:
				return true;
			default:
		}
		return false;
	}

	public static function IsCallLikeOrFunctionLikeExpression(node:Node):Bool {
		return IsCallLikeExpression(node) || IsFunctionExpressionOrArrowFunction(node);
	}

	public static function NodeHasKind(node:Node, kind:Kind):Bool {
		if (node == null) {
			return false;
		}
		return node.Kind == kind;
	}

	public static function IsContextualKeyword(token:Kind):Bool {
		return KindFirstContextualKeyword <= token && token <= KindLastContextualKeyword;
	}

	public static function IsThisInTypeQuery(node:Node):Bool {
		if (!IsThisIdentifier(node)) {
			return false;
		}
		while (IsQualifiedName(node.Parent) && node.Parent.AsQualifiedName().Left == node) {
			node = node.Parent;
		}
		return node.Parent.Kind == KindTypeQuery;
	}

	// Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `let` declaration.
	public static function IsLet(node:Node):Bool {
		return GetCombinedNodeFlags(node) & NodeFlagsBlockScoped == NodeFlagsLet;
	}

	public static function IsClassMemberModifier(token:Kind):Bool {
		return IsParameterPropertyModifier(token) || token == KindStaticKeyword || token == KindOverrideKeyword || token == KindAccessorKeyword;
	}

	public static function IsParameterPropertyModifier(kind:Kind):Bool {
		return ModifierToFlag(kind) & ModifierFlagsParameterPropertyModifier != 0;
	}

	public static function ForEachChildAndJSDoc(node:Node, sourceFile:SourceFile, v:Visitor):Bool {
		if (visitNodes(v, node.JSDoc(sourceFile))) {
			return true;
		}
		return node.ForEachChild(v);
	}

	public static function HasTypeArguments(node:Node):Bool {
		switch (node.Kind) {
			case KindCallExpression | KindNewExpression | KindTaggedTemplateExpression | KindTypeReference | KindExpressionWithTypeArguments |
				KindImportType | KindTypeQuery | KindJsxOpeningElement | KindJsxSelfClosingElement:
				return true;
			default:
		}
		return false;
	}

	public static function IsTypeReferenceType(node:Node):Bool {
		return node.Kind == KindTypeReference || node.Kind == KindExpressionWithTypeArguments;
	}

	public static function IsVariableLike(node:Node):Bool {
		switch (node.Kind) {
			case KindBindingElement | KindEnumMember | KindParameter | KindPropertyAssignment | KindPropertyDeclaration | KindPropertySignature |
				KindShorthandPropertyAssignment | KindVariableDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function HasInitializer(node:Node):Bool {
		switch (node.Kind) {
			case KindVariableDeclaration | KindParameter | KindBindingElement | KindPropertyDeclaration | KindPropertyAssignment | KindEnumMember |
				KindForStatement | KindForInStatement | KindForOfStatement | KindJsxAttribute:
				return node.Initializer() != null;
			default:
				return false;
		}
	}

	public static function IsVariableParameterOrProperty(node:Node):Bool {
		switch (node.Kind) {
			case KindVariableDeclaration | KindParameter | KindPropertySignature | KindPropertyDeclaration:
				return true;
			default:
				return false;
		}
	}

	public static function GetTypeAnnotationNode(node:Node):TypeNode {
		switch (node.Kind) {
			case KindVariableDeclaration | KindParameter | KindPropertySignature | KindPropertyDeclaration | KindTypePredicate | KindParenthesizedType |
				KindTypeOperator | KindMappedType | KindTypeAssertionExpression | KindAsExpression | KindSatisfiesExpression | KindTypeAliasDeclaration |
				KindJSTypeAliasDeclaration | KindNamedTupleMember | KindOptionalType | KindRestType | KindTemplateLiteralTypeSpan |
				KindJSDocTypeExpression | KindJSDocPropertyTag | KindJSDocNullableType | KindJSDocNonNullableType | KindJSDocOptionalType:
				return node.Type();
			default:
				final funcLike = node.FunctionLikeData();
				if (funcLike != null) {
					return funcLike.Type;
				}
				return null;
		}
	}

	public static function IsObjectTypeDeclaration(node:Node):Bool {
		return IsClassLike(node) || IsInterfaceDeclaration(node) || IsTypeLiteralNode(node);
	}

	public static function IsClassOrTypeElement(node:Node):Bool {
		return IsClassElement(node) || IsTypeElement(node);
	}

	public static function GetClassExtendsHeritageElement(node:Node):ExpressionWithTypeArgumentsNode {
		final heritageElements = GetHeritageElements(node, KindExtendsKeyword);
		if (Core.len(heritageElements) > 0) {
			return heritageElements[0];
		}
		return null;
	}

	public static function GetImplementsTypeNodes(node:Node):Array<ExpressionWithTypeArgumentsNode> {
		return GetHeritageElements(node, KindImplementsKeyword);
	}

	public static function IsTypeKeywordToken(node:Node):Bool {
		return node.Kind == KindTypeKeyword;
	}

	// See `IsJSDocSingleCommentNode`.
	public static function IsJSDocSingleCommentNodeList(nodeList:NodeList):Bool {
		if (nodeList == null || Core.len(nodeList.Nodes) == 0) {
			return false;
		}
		final parent = nodeList.Nodes[0].Parent;
		if (parent == null) {
			return false;
		}
		return IsJSDocSingleCommentNode(parent) && nodeList == parent.CommentList();
	}

	// See `IsJSDocSingleCommentNode`.
	public static function IsJSDocSingleCommentNodeComment(node:Node):Bool {
		if (node == null || node.Parent == null) {
			return false;
		}
		return IsJSDocSingleCommentNode(node.Parent) && node == node.Parent.CommentList().Nodes[0];
	}

	// In Strada, if a JSDoc node has a single comment, that comment is represented as a string property
	// as a simplification, and therefore that comment is not visited by `forEachChild`.
	public static function IsJSDocSingleCommentNode(node:Node):Bool {
		return hasComment(node.Kind) && node.CommentList() != null && Core.len(node.CommentList().Nodes) == 1;
	}

	public static function IsValidTypeOnlyAliasUseSite(useSite:Node):Bool {
		return useSite.Flags & (NodeFlagsAmbient | NodeFlagsJSDoc) != 0
			|| IsPartOfTypeQuery(useSite)
			|| isIdentifierInNonEmittingHeritageClause(useSite)
			|| isPartOfPossiblyValidTypeOrAbstractComputedPropertyName(useSite)
			|| !(IsExpressionNode(useSite) || isShorthandPropertyNameUseSite(useSite));
	}

	static function isIdentifierInNonEmittingHeritageClause(node:Node):Bool {
		if (!IsIdentifier(node)) {
			return false;
		}
		var parent = node.Parent;
		while (IsPropertyAccessExpression(parent) || IsExpressionWithTypeArguments(parent)) {
			parent = parent.Parent;
		}
		return IsHeritageClause(parent) && (parent.AsHeritageClause().Token == KindImplementsKeyword || IsInterfaceDeclaration(parent.Parent));
	}

	static function isPartOfPossiblyValidTypeOrAbstractComputedPropertyName(node:Node):Bool {
		while (node.Kind == KindIdentifier || node.Kind == KindPropertyAccessExpression) { // PORT: perf — NodeKindIs without the rest array
			node = node.Parent;
		}
		if (node.Kind != KindComputedPropertyName) {
			return false;
		}
		if (HasSyntacticModifier(node.Parent, ModifierFlagsAbstract)) {
			return true;
		}
		final k = node.Parent.Parent.Kind; // PORT: perf — NodeKindIs without the rest array
		return k == KindInterfaceDeclaration || k == KindTypeLiteral;
	}

	static function isShorthandPropertyNameUseSite(useSite:Node):Bool {
		return IsIdentifier(useSite) && IsShorthandPropertyAssignment(useSite.Parent) && useSite.Parent.AsShorthandPropertyAssignment().Name() == useSite;
	}

	public static function GetPropertyNameForPropertyNameNode(name:Node):String {
		switch (name.Kind) {
			case KindIdentifier | KindPrivateIdentifier | KindStringLiteral | KindNoSubstitutionTemplateLiteral | KindNumericLiteral | KindBigIntLiteral |
				KindJsxNamespacedName:
				return name.Text();
			case KindComputedPropertyName:
				final nameExpression = name.Expression();
				if (IsStringOrNumericLiteralLike(nameExpression)) {
					return nameExpression.Text();
				}
				if (IsSignedNumericLiteral(nameExpression)) {
					var text = nameExpression.AsPrefixUnaryExpression().Operand.Text();
					if (nameExpression.AsPrefixUnaryExpression().Operator == KindMinusToken) {
						text = "-" + text;
					}
					return text;
				}
				return InternalSymbolNameMissing;
			default:
		}
		throw "Unhandled case in getPropertyNameForPropertyNameNode";
	}

	public static function IsPartOfTypeOnlyImportOrExportDeclaration(node:Node):Bool {
		return FindAncestor(node, IsTypeOnlyImportOrExportDeclaration) != null;
	}

	public static function IsPartOfExclusivelyTypeOnlyImportOrExportDeclaration(node:Node):Bool {
		return FindAncestor(node, IsExclusivelyTypeOnlyImportOrExport) != null;
	}

	public static function IsEmittableImport(node:Node):Bool {
		switch (node.Kind) {
			case KindImportDeclaration:
				return node.ImportClause() != null && !node.ImportClause().IsTypeOnly();
			case KindExportDeclaration | KindImportEqualsDeclaration:
				return !node.IsTypeOnly();
			case KindCallExpression:
				return IsImportCall(node);
			default:
		}
		return false;
	}

	public static function IsResolutionModeOverrideHost(node:Node):Bool {
		if (node == null) {
			return false;
		}
		switch (node.Kind) {
			case KindImportType | KindExportDeclaration | KindImportDeclaration | KindJSImportDeclaration:
				return true;
			default:
		}
		return false;
	}

	public static function HasResolutionModeOverride(node:Node):Bool {
		if (node == null) {
			return false;
		}
		var attributes:ImportAttributesNode = null;
		switch (node.Kind) {
			case KindImportType:
				attributes = node.AsImportTypeNode().Attributes;
			case KindImportDeclaration | KindJSImportDeclaration:
				attributes = node.AsImportDeclaration().Attributes;
			case KindExportDeclaration:
				attributes = node.AsExportDeclaration().Attributes;
			default:
		}
		if (attributes != null) {
			final r = attributes.GetResolutionModeOverride();
			return r.ok;
		}
		return false;
	}

	public static function IsStringTextContainingNode(node:Node):Bool {
		return node.Kind == KindStringLiteral || IsTemplateLiteralKind(node.Kind);
	}

	public static function IsTemplateLiteralKind(kind:Kind):Bool {
		return KindFirstTemplateToken <= kind && kind <= KindLastTemplateToken;
	}

	public static function IsTemplateLiteralToken(node:Node):Bool {
		return IsTemplateLiteralKind(node.Kind);
	}

	public static function GetExternalModuleImportEqualsDeclarationExpression(node:Node):Node {
		Debug.Assert(IsExternalModuleImportEqualsDeclaration(node));
		return node.AsImportEqualsDeclaration().ModuleReference.Expression();
	}

	public static function CreateModifiersFromModifierFlags(flags:ModifierFlags, createModifier:(kind:Kind) -> Node):Array<Node> {
		var result:Array<Node> = null;
		// PORT: Go append to a nil slice → create the array on first push.
		function append(n:Node) {
			if (result == null) {
				result = [];
			}
			result.push(n);
		}
		if (flags & ModifierFlagsExport != 0) {
			append(createModifier(KindExportKeyword));
		}
		if (flags & ModifierFlagsAmbient != 0) {
			append(createModifier(KindDeclareKeyword));
		}
		if (flags & ModifierFlagsDefault != 0) {
			append(createModifier(KindDefaultKeyword));
		}
		if (flags & ModifierFlagsConst != 0) {
			append(createModifier(KindConstKeyword));
		}
		if (flags & ModifierFlagsPublic != 0) {
			append(createModifier(KindPublicKeyword));
		}
		if (flags & ModifierFlagsPrivate != 0) {
			append(createModifier(KindPrivateKeyword));
		}
		if (flags & ModifierFlagsProtected != 0) {
			append(createModifier(KindProtectedKeyword));
		}
		if (flags & ModifierFlagsAbstract != 0) {
			append(createModifier(KindAbstractKeyword));
		}
		if (flags & ModifierFlagsStatic != 0) {
			append(createModifier(KindStaticKeyword));
		}
		if (flags & ModifierFlagsOverride != 0) {
			append(createModifier(KindOverrideKeyword));
		}
		if (flags & ModifierFlagsReadonly != 0) {
			append(createModifier(KindReadonlyKeyword));
		}
		if (flags & ModifierFlagsAccessor != 0) {
			append(createModifier(KindAccessorKeyword));
		}
		if (flags & ModifierFlagsAsync != 0) {
			append(createModifier(KindAsyncKeyword));
		}
		if (flags & ModifierFlagsIn != 0) {
			append(createModifier(KindInKeyword));
		}
		if (flags & ModifierFlagsOut != 0) {
			append(createModifier(KindOutKeyword));
		}
		return result;
	}

	public static function GetThisParameter(signature:Node):Node {
		// callback tags do not currently support this parameters
		if (Core.len(signature.Parameters()) != 0) {
			final thisParameter = signature.Parameters()[0];
			if (IsThisParameter(thisParameter)) {
				return thisParameter;
			}
		}
		return null;
	}

	public static function ReplaceModifiers(factory:NodeFactory, node:Node, modifierArray:ModifierList):Node {
		switch (node.Kind) {
			case KindTypeParameter:
				return factory.UpdateTypeParameterDeclaration(node.AsTypeParameterDeclaration(), modifierArray, node.Name(),
					node.AsTypeParameterDeclaration().Constraint, node.AsTypeParameterDeclaration().Expression,
					node.AsTypeParameterDeclaration().DefaultType);
			case KindParameter:
				return factory.UpdateParameterDeclaration(node.AsParameterDeclaration(), modifierArray, node.AsParameterDeclaration().DotDotDotToken,
					node.Name(), node.QuestionToken(), node.Type(), node.Initializer());
			case KindConstructorType:
				return factory.UpdateConstructorTypeNode(node.AsConstructorTypeNode(), modifierArray, node.TypeParameterList(), node.ParameterList(),
					node.Type());
			case KindPropertySignature:
				return factory.UpdatePropertySignatureDeclaration(node.AsPropertySignatureDeclaration(), modifierArray, node.Name(), node.PostfixToken(),
					node.Type(), node.Initializer());
			case KindPropertyDeclaration:
				return factory.UpdatePropertyDeclaration(node.AsPropertyDeclaration(), modifierArray, node.Name(), node.PostfixToken(), node.Type(),
					node.Initializer());
			case KindMethodSignature:
				return factory.UpdateMethodSignatureDeclaration(node.AsMethodSignatureDeclaration(), modifierArray, node.Name(), node.PostfixToken(),
					node.TypeParameterList(), node.ParameterList(), node.Type());
			case KindMethodDeclaration:
				return factory.UpdateMethodDeclaration(node.AsMethodDeclaration(), modifierArray, node.AsMethodDeclaration().AsteriskToken, node.Name(),
					node.PostfixToken(), node.TypeParameterList(), node.ParameterList(), node.Type(), node.AsMethodDeclaration().FullSignature,
					node.Body());
			case KindConstructor:
				return factory.UpdateConstructorDeclaration(node.AsConstructorDeclaration(), modifierArray, node.TypeParameterList(),
					node.ParameterList(), node.Type(), node.AsConstructorDeclaration().FullSignature, node.Body());
			case KindGetAccessor:
				return factory.UpdateGetAccessorDeclaration(node.AsGetAccessorDeclaration(), modifierArray, node.Name(), node.TypeParameterList(),
					node.ParameterList(), node.Type(), node.AsGetAccessorDeclaration().FullSignature, node.Body());
			case KindSetAccessor:
				return factory.UpdateSetAccessorDeclaration(node.AsSetAccessorDeclaration(), modifierArray, node.Name(), node.TypeParameterList(),
					node.ParameterList(), node.Type(), node.AsSetAccessorDeclaration().FullSignature, node.Body());
			case KindIndexSignature:
				return factory.UpdateIndexSignatureDeclaration(node.AsIndexSignatureDeclaration(), modifierArray, node.ParameterList(), node.Type());
			case KindFunctionExpression:
				return factory.UpdateFunctionExpression(node.AsFunctionExpression(), modifierArray, node.AsFunctionExpression().AsteriskToken,
					node.Name(), node.TypeParameterList(), node.ParameterList(), node.Type(), node.AsFunctionExpression().FullSignature, node.Body());
			case KindArrowFunction:
				return factory.UpdateArrowFunction(node.AsArrowFunction(), modifierArray, node.TypeParameterList(), node.ParameterList(), node.Type(),
					node.AsArrowFunction().FullSignature, node.AsArrowFunction().EqualsGreaterThanToken, node.Body());
			case KindClassExpression:
				return factory.UpdateClassExpression(node.AsClassExpression(), modifierArray, node.Name(), node.TypeParameterList(),
					node.AsClassExpression().HeritageClauses, node.MemberList());
			case KindVariableStatement:
				return factory.UpdateVariableStatement(node.AsVariableStatement(), modifierArray, node.AsVariableStatement().DeclarationList);
			case KindFunctionDeclaration:
				return factory.UpdateFunctionDeclaration(node.AsFunctionDeclaration(), modifierArray, node.AsFunctionDeclaration().AsteriskToken,
					node.Name(), node.TypeParameterList(), node.ParameterList(), node.Type(), node.AsFunctionDeclaration().FullSignature, node.Body());
			case KindClassDeclaration:
				return factory.UpdateClassDeclaration(node.AsClassDeclaration(), modifierArray, node.Name(), node.TypeParameterList(),
					node.AsClassDeclaration().HeritageClauses, node.MemberList());
			case KindInterfaceDeclaration:
				return factory.UpdateInterfaceDeclaration(node.AsInterfaceDeclaration(), modifierArray, node.Name(), node.TypeParameterList(),
					node.AsInterfaceDeclaration().HeritageClauses, node.MemberList());
			case KindTypeAliasDeclaration:
				return factory.UpdateTypeAliasDeclaration(node.AsTypeAliasDeclaration(), modifierArray, node.Name(), node.TypeParameterList(),
					node.Type());
			case KindEnumDeclaration:
				return factory.UpdateEnumDeclaration(node.AsEnumDeclaration(), modifierArray, node.Name(), node.MemberList());
			case KindModuleDeclaration:
				return factory.UpdateModuleDeclaration(node.AsModuleDeclaration(), modifierArray, node.AsModuleDeclaration().Keyword, node.Name(),
					node.Body());
			case KindImportEqualsDeclaration:
				return factory.UpdateImportEqualsDeclaration(node.AsImportEqualsDeclaration(), modifierArray, node.IsTypeOnly(), node.Name(),
					node.AsImportEqualsDeclaration().ModuleReference);
			case KindImportDeclaration:
				return factory.UpdateImportDeclaration(node.AsImportDeclaration(), modifierArray, node.ImportClause(), node.ModuleSpecifier(),
					node.AsImportDeclaration().Attributes);
			case KindExportAssignment:
				return factory.UpdateExportAssignment(node.AsExportAssignment(), modifierArray, node.AsExportAssignment().IsExportEquals, node.Type(),
					node.Expression());
			case KindExportDeclaration:
				return factory.UpdateExportDeclaration(node.AsExportDeclaration(), modifierArray, node.IsTypeOnly(),
					node.AsExportDeclaration().ExportClause, node.ModuleSpecifier(), node.AsExportDeclaration().Attributes);
			default:
		}
		throw "Node that does not have modifiers tried to have modifier replaced: " + (node.Kind : Int);
	}

	public static function IsLateVisibilityPaintedStatement(node:Node):Bool {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration | KindImportEqualsDeclaration | KindVariableStatement | KindClassDeclaration |
				KindFunctionDeclaration | KindModuleDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindInterfaceDeclaration |
				KindEnumDeclaration:
				return true;
			default:
				return false;
		}
	}

	public static function IsExternalModuleAugmentation(node:Node):Bool {
		return IsAmbientModule(node) && IsModuleAugmentationExternal(node);
	}

	public static function GetSourceFileOfModule(module:Symbol):SourceFile {
		var declaration = module.ValueDeclaration;
		if (declaration == null) {
			declaration = GetNonAugmentationDeclaration(module);
		}
		return GetSourceFileOfNode(declaration);
	}

	public static function GetNonAugmentationDeclaration(symbol:Symbol):Node {
		return Core.Find(symbol.Declarations, function(d:Node):Bool {
			return !IsExternalModuleAugmentation(d) && !IsGlobalScopeAugmentation(d);
		});
	}

	public static function IsTypeDeclaration(node:Node):Bool {
		switch (node.Kind) {
			case KindTypeParameter | KindClassDeclaration | KindInterfaceDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration |
				KindEnumDeclaration:
				return true;
			case KindImportClause:
				return node.IsTypeOnly();
			case KindImportSpecifier | KindExportSpecifier:
				return node.Parent.Parent.IsTypeOnly();
			default:
				return false;
		}
	}

	public static function IsTypeDeclarationName(name:Node):Bool {
		return name.Kind == KindIdentifier && IsTypeDeclaration(name.Parent) && GetNameOfDeclaration(name.Parent) == name;
	}

	public static function IsRightSideOfPropertyAccess(node:Node):Bool {
		return node.Parent.Kind == KindPropertyAccessExpression && node.Parent.Name() == node;
	}

	public static function IsArgumentExpressionOfElementAccess(node:Node):Bool {
		return node.Parent != null
			&& node.Parent.Kind == KindElementAccessExpression
			&& node.Parent.AsElementAccessExpression().ArgumentExpression == node;
	}

	public static function ClimbPastPropertyAccess(node:Node):Node {
		if (IsRightSideOfPropertyAccess(node)) {
			return node.Parent;
		}
		return node;
	}

	static function climbPastPropertyOrElementAccess(node:Node):Node {
		if (IsRightSideOfPropertyAccess(node) || IsArgumentExpressionOfElementAccess(node)) {
			return node.Parent;
		}
		return node;
	}

	static function selectExpressionOfCallOrNewExpressionOrDecorator(node:Node):Node {
		if (IsCallExpression(node) || IsNewExpression(node) || IsDecorator(node)) {
			return node.Expression();
		}
		return null;
	}

	static function selectTagOfTaggedTemplateExpression(node:Node):Node {
		if (IsTaggedTemplateExpression(node)) {
			return node.AsTaggedTemplateExpression().Tag;
		}
		return null;
	}

	static function selectTagNameOfJsxOpeningLikeElement(node:Node):Node {
		if (IsJsxOpeningElement(node) || IsJsxSelfClosingElement(node)) {
			return node.TagName();
		}
		return null;
	}

	public static function IsCallExpressionTarget(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsCallExpression, selectExpressionOfCallOrNewExpressionOrDecorator, includeElementAccess, skipPastOuterExpressions);
	}

	public static function IsNewExpressionTarget(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsNewExpression, selectExpressionOfCallOrNewExpressionOrDecorator, includeElementAccess, skipPastOuterExpressions);
	}

	public static function IsCallOrNewExpressionTarget(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsCallOrNewExpression, selectExpressionOfCallOrNewExpressionOrDecorator, includeElementAccess, skipPastOuterExpressions);
	}

	public static function IsTaggedTemplateTag(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsTaggedTemplateExpression, selectTagOfTaggedTemplateExpression, includeElementAccess, skipPastOuterExpressions);
	}

	public static function IsDecoratorTarget(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsDecorator, selectExpressionOfCallOrNewExpressionOrDecorator, includeElementAccess, skipPastOuterExpressions);
	}

	public static function IsJsxOpeningLikeElementTagName(node:Node, includeElementAccess:Bool, skipPastOuterExpressions:Bool):Bool {
		return isCalleeWorker(node, IsJsxOpeningLikeElement, selectTagNameOfJsxOpeningLikeElement, includeElementAccess, skipPastOuterExpressions);
	}

	static function isCalleeWorker(node:Node, pred:(Node) -> Bool, calleeSelector:(Node) -> Node, includeElementAccess:Bool,
			skipPastOuterExpressions:Bool):Bool {
		var target:Node = null;
		if (includeElementAccess) {
			target = climbPastPropertyOrElementAccess(node);
		} else {
			target = ClimbPastPropertyAccess(node);
		}
		if (skipPastOuterExpressions) {
			// Only skip outer expressions if the target is actually an expression node
			if (IsExpression(target)) {
				target = SkipOuterExpressions(target, OEKAll);
			}
		}
		return target != null && target.Parent != null && pred(target.Parent) && calleeSelector(target.Parent) == target;
	}

	public static function IsRightSideOfQualifiedNameOrPropertyAccess(node:Node):Bool {
		final parent = node.Parent;
		switch (parent.Kind) {
			case KindQualifiedName:
				return parent.AsQualifiedName().Right == node;
			case KindPropertyAccessExpression:
				return parent.AsPropertyAccessExpression().Name() == node;
			case KindMetaProperty:
				return parent.AsMetaProperty().Name() == node;
			default:
		}
		return false;
	}

	public static function ShouldTransformImportCall(fileName:String, options:CompilerOptions, impliedNodeFormatForEmit:ModuleKind):Bool {
		final moduleKind = options.GetEmitModuleKind();
		if (ModuleKindNode16 <= moduleKind && moduleKind <= ModuleKindNodeNext || moduleKind == ModuleKindPreserve) {
			return false;
		}
		return impliedNodeFormatForEmit < ModuleKindES2015;
	}

	public static function HasQuestionToken(node:Node):Bool {
		return IsQuestionToken(node.QuestionToken());
	}

	public static function IsJsxOpeningLikeElement(node:Node):Bool {
		return IsJsxOpeningElement(node) || IsJsxSelfClosingElement(node);
	}

	public static function GetInvokedExpression(node:Node):Node {
		switch (node.Kind) {
			case KindTaggedTemplateExpression:
				return node.AsTaggedTemplateExpression().Tag;
			case KindJsxOpeningElement | KindJsxSelfClosingElement:
				return node.TagName();
			case KindBinaryExpression:
				return node.AsBinaryExpression().Right;
			case KindJsxOpeningFragment:
				return node;
			default:
				return node.Expression();
		}
	}

	public static function IsCallOrNewExpression(node:Node):Bool {
		return IsCallExpression(node) || IsNewExpression(node);
	}

	public static function IndexOfNode(nodes:Array<Node>, node:Node):Int {
		final r = Slices.BinarySearchFuncInline(nodes, node, (a, b) -> CompareNodePositions(a, b)) /* PORT: perf */;
		if (r.ok) {
			return r.value;
		}
		return -1;
	}

	public static function CompareNodePositions(n1:Node, n2:Node):Int {
		return Core.CompareTextRanges(n1.Loc, n2.Loc);
	}

	public static function IsUnterminatedLiteral(node:Node):Bool {
		return IsLiteralKind(node.Kind) && node.LiteralLikeData().TokenFlags & TokenFlagsUnterminated != 0
			|| IsTemplateLiteralKind(node.Kind) && node.TemplateLiteralLikeData().TemplateFlags & TokenFlagsUnterminated != 0;
	}

	// Gets a value indicating whether a class element is either a static or an instance property declaration with an initializer.
	public static function IsInitializedProperty(member:ClassElement):Bool {
		return member.Kind == KindPropertyDeclaration && member.Initializer() != null;
	}

	public static function IsTrivia(token:Kind):Bool {
		return KindFirstTriviaToken <= token && token <= KindLastTriviaToken;
	}

	public static function HasDecorators(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsDecorator);
	}

	// type hasFileNameImpl → class HasFileNameImpl in Utilities.hx (with its FileName()/Path() methods).

	public static function NewHasFileName(fileName:String, path:Path):HasFileName {
		final h = new HasFileNameImpl();
		h.fileName = fileName;
		h.path = path;
		return h;
	}

	public static function GetSemanticJsxChildren(children:Array<JsxChild>):Array<JsxChild> {
		return Core.Filter(children, function(i:JsxChild):Bool {
			switch (i.Kind) {
				case KindJsxExpression:
					return i.Expression() != null;
				case KindJsxText:
					return !i.AsJsxText().ContainsOnlyTriviaWhiteSpaces;
				default:
					return true;
			}
		});
	}

	// Returns true if the node kind has a comment property.
	static function hasComment(kind:Kind):Bool {
		switch (kind) {
			case KindJSDoc | KindJSDocUnknownTag | KindJSDocAugmentsTag | KindJSDocImplementsTag | KindJSDocDeprecatedTag | KindJSDocPublicTag |
				KindJSDocPrivateTag | KindJSDocProtectedTag | KindJSDocReadonlyTag | KindJSDocOverrideTag | KindJSDocCallbackTag |
				KindJSDocOverloadTag | KindJSDocParameterTag | KindJSDocPropertyTag | KindJSDocReturnTag | KindJSDocThisTag | KindJSDocTypeTag |
				KindJSDocTemplateTag | KindJSDocTypedefTag | KindJSDocSeeTag | KindJSDocThrowsTag | KindJSDocSatisfiesTag | KindJSDocImportTag:
				return true;
			default:
				return false;
		}
	}

	public static function IsAssignmentPattern(node:Node):Bool {
		return node.Kind == KindArrayLiteralExpression || node.Kind == KindObjectLiteralExpression;
	}

	public static function GetElementsOfBindingOrAssignmentPattern(name:Node):Array<Node> {
		switch (name.Kind) {
			case KindObjectBindingPattern | KindArrayBindingPattern | KindArrayLiteralExpression:
				// `a` in `{a}`
				// `a` in `[a]`
				return name.Elements();
			case KindObjectLiteralExpression:
				// `a` in `{a}`
				return name.Properties();
			default:
		}
		return null;
	}

	public static function IsDeclarationBindingElement(bindingElement:Node):Bool {
		switch (bindingElement.Kind) {
			case KindVariableDeclaration | KindParameter | KindBindingElement:
				return true;
			default:
				return false;
		}
	}

	public static function GetTargetOfBindingOrAssignmentElement(bindingElement:Node):Node {
		if (IsDeclarationBindingElement(bindingElement)) {
			// `a` in `let { a } = ...`
			// `a` in `let { a = 1 } = ...`
			// `b` in `let { a: b } = ...`
			// `b` in `let { a: b = 1 } = ...`
			// `a` in `let { ...a } = ...`
			// `{b}` in `let { a: {b} } = ...`
			// `{b}` in `let { a: {b} = 1 } = ...`
			// `[b]` in `let { a: [b] } = ...`
			// `[b]` in `let { a: [b] = 1 } = ...`
			// `a` in `let [a] = ...`
			// `a` in `let [a = 1] = ...`
			// `a` in `let [...a] = ...`
			// `{a}` in `let [{a}] = ...`
			// `{a}` in `let [{a} = 1] = ...`
			// `[a]` in `let [[a]] = ...`
			// `[a]` in `let [[a] = 1] = ...`
			return bindingElement.Name();
		}

		if (IsObjectLiteralElement(bindingElement)) {
			switch (bindingElement.Kind) {
				case KindPropertyAssignment:
					// `b` in `({ a: b } = ...)`
					// `b` in `({ a: b = 1 } = ...)`
					// `{b}` in `({ a: {b} } = ...)`
					// `{b}` in `({ a: {b} = 1 } = ...)`
					// `[b]` in `({ a: [b] } = ...)`
					// `[b]` in `({ a: [b] = 1 } = ...)`
					// `b.c` in `({ a: b.c } = ...)`
					// `b.c` in `({ a: b.c = 1 } = ...)`
					// `b[0]` in `({ a: b[0] } = ...)`
					// `b[0]` in `({ a: b[0] = 1 } = ...)`
					return GetTargetOfBindingOrAssignmentElement(bindingElement.Initializer());
				case KindShorthandPropertyAssignment:
					// `a` in `({ a } = ...)`
					// `a` in `({ a = 1 } = ...)`
					return bindingElement.Name();
				case KindSpreadAssignment:
					// `a` in `({ ...a } = ...)`
					return GetTargetOfBindingOrAssignmentElement(bindingElement.Expression());
				default:
			}

			// no target
			return null;
		}

		if (IsAssignmentExpression(bindingElement /*excludeCompoundAssignment*/, true)) {
			// `a` in `[a = 1] = ...`
			// `{a}` in `[{a} = 1] = ...`
			// `[a]` in `[[a] = 1] = ...`
			// `a.b` in `[a.b = 1] = ...`
			// `a[0]` in `[a[0] = 1] = ...`
			return GetTargetOfBindingOrAssignmentElement(bindingElement.AsBinaryExpression().Left);
		}

		if (IsSpreadElement(bindingElement)) {
			// `a` in `[...a] = ...`
			return GetTargetOfBindingOrAssignmentElement(bindingElement.Expression());
		}

		// `a` in `[a] = ...`
		// `{a}` in `[{a}] = ...`
		// `[a]` in `[[a]] = ...`
		// `a.b` in `[a.b] = ...`
		// `a[0]` in `[a[0]] = ...`
		return bindingElement;
	}


	public static function TryGetPropertyNameOfBindingOrAssignmentElement(bindingElement:Node):Node {
		switch (bindingElement.Kind) {
			case KindBindingElement:
				// `a` in `let { a: b } = ...`
				// `[a]` in `let { [a]: b } = ...`
				// `"a"` in `let { "a": b } = ...`
				// `1` in `let { 1: b } = ...`
				if (bindingElement.PropertyName() != null) {
					final propertyName = bindingElement.PropertyName();
					// if IsPrivateIdentifier(propertyName) {
					// 	return Debug.failBadSyntaxKind(propertyName) // !!!
					// }
					if (IsComputedPropertyName(propertyName) && IsStringOrNumericLiteralLike(propertyName.Expression())) {
						return propertyName.Expression();
					}
					return propertyName;
				}
			case KindPropertyAssignment:
				// `a` in `({ a: b } = ...)`
				// `[a]` in `({ [a]: b } = ...)`
				// `"a"` in `({ "a": b } = ...)`
				// `1` in `({ 1: b } = ...)`
				if (bindingElement.Name() != null) {
					final propertyName = bindingElement.Name();
					// if IsPrivateIdentifier(propertyName) {
					// 	return Debug.failBadSyntaxKind(propertyName) // !!!
					// }
					if (IsComputedPropertyName(propertyName) && IsStringOrNumericLiteralLike(propertyName.Expression())) {
						return propertyName.Expression();
					}
					return propertyName;
				}
			case KindSpreadAssignment:
				// `a` in `({ ...a } = ...)`
				// if IsPrivateIdentifier(bindingElement.Name()) {
				// 	return Debug.failBadSyntaxKind(bindingElement.Name()) // !!!
				// }
				return bindingElement.Name();
			default:
		}

		final target = GetTargetOfBindingOrAssignmentElement(bindingElement);
		if (target != null && IsPropertyName(target)) {
			return target;
		}
		return null;
	}

	public static function ContainsObjectRestOrSpread(node:Node):Bool {
		if (node.SubtreeFacts() & SubtreeContainsObjectRestOrSpread != 0) {
			return true;
		}
		if (node.SubtreeFacts() & SubtreeContainsESObjectRestOrSpread != 0) {
			// check for nested spread assignments, otherwise '{ x: { a, ...b } = foo } = c'
			// will not be correctly interpreted by the rest/spread transformer
			final elements = GetElementsOfBindingOrAssignmentPattern(node);
			if (elements != null) {
				for (element in elements) {
					final target = GetTargetOfBindingOrAssignmentElement(element);
					if (target != null && IsAssignmentPattern(target)) {
						if (target.SubtreeFacts() & SubtreeContainsObjectRestOrSpread != 0) {
							return true;
						}
						if (target.SubtreeFacts() & SubtreeContainsESObjectRestOrSpread != 0) {
							if (ContainsObjectRestOrSpread(target)) {
								return true;
							}
						}
					}
				}
			}
		}
		return false;
	}


	public static function IsEmptyObjectLiteral(expression:Node):Bool {
		return IsObjectLiteralExpression(expression) && Core.len(expression.Properties()) == 0;
	}

	public static function IsEmptyArrayLiteral(expression:Node):Bool {
		return IsArrayLiteralExpression(expression) && Core.len(expression.Elements()) == 0;
	}

	public static function GetRestIndicatorOfBindingOrAssignmentElement(bindingElement:Node):Node {
		switch (bindingElement.Kind) {
			case KindParameter:
				return bindingElement.AsParameterDeclaration().DotDotDotToken;
			case KindBindingElement:
				return bindingElement.AsBindingElement().DotDotDotToken;
			case KindSpreadElement | KindSpreadAssignment:
				return bindingElement;
			default:
		}
		return null;
	}

	public static function IsJSDocNameReferenceContext(node:Node):Bool {
		return node.Flags & NodeFlagsJSDoc != 0 && FindAncestor(node, function(node:Node):Bool {
			return IsJSDocNameReference(node) || IsJSDocLinkLike(node);
		}) != null;
	}

	// GetJSDocRoot returns the containing JSDoc node for a node inside a JSDoc comment.
	public static function GetJSDocRoot(node:Node):Node {
		return FindAncestor(node.Parent, function(n:Node):Bool {
			return n.Kind == KindJSDoc;
		});
	}

	// GetJSDocHost returns the declaration that the JSDoc comment containing the given node is attached to.
	public static function GetJSDocHost(node:Node):Node {
		final jsDoc = GetJSDocRoot(node);
		if (jsDoc == null) {
			return null;
		}
		return jsDoc.Parent;
	}

	// GetHostSignatureFromJSDoc returns the function-like declaration that hosts the JSDoc comment
	// containing the given node. This is used to resolve @link references to parameters.
	public static function GetHostSignatureFromJSDoc(node:Node):Node {
		final host = GetJSDocHost(node);
		if (host == null) {
			return null;
		}
		// !!! Strada's getEffectiveJSDocHost applies JS assignment pattern transforms (getSourceOfAssignment, getSourceOfDefaultedAssignment, etc.) not yet ported
		if (IsPropertySignatureDeclaration(host) && host.Type() != null && IsFunctionLike(host.Type())) {
			return host.Type();
		}
		if (IsFunctionLike(host)) {
			return host;
		}
		return null;
	}

	// Finds the declaration that owns the JSDoc for a function-like node.
	// Keep these hosts aligned with JSDoc parameter reparsing so unmatched @param diagnostics use the same attachment rules.
	// Keep in sync with getNextJSDocCommentLocation in the API's src/ast/jsdoc.ts
	public static function GetNextJSDocCommentLocation(node:Node):Node {
		final parent = node.Parent;
		if (parent != null) {
			switch (parent.Kind) {
				case KindPropertyAssignment | KindExportAssignment | KindPropertyDeclaration | KindVariableDeclaration | KindSatisfiesExpression |
					KindReturnStatement | KindVariableStatement | KindExpressionStatement:
					return parent;
				case KindVariableDeclarationList:
					if (parent.AsVariableDeclarationList().Declarations.Nodes[0] == node) {
						return parent;
					}
				default:
			}
		}
		return null;
	}

	public static function IsImportOrImportEqualsDeclaration(node:Node):Bool {
		return IsImportDeclaration(node) || IsImportEqualsDeclaration(node);
	}

	public static function IsPrimitiveLiteralValue(node:Node, includeBigInt:Bool):Bool {
		switch (node.Kind) {
			case KindTrueKeyword | KindFalseKeyword | KindNumericLiteral | KindStringLiteral | KindNoSubstitutionTemplateLiteral:
				return true;
			case KindBigIntLiteral:
				return includeBigInt;
			case KindPrefixUnaryExpression:
				if (node.AsPrefixUnaryExpression().Operator == KindMinusToken) {
					return IsNumericLiteral(node.AsPrefixUnaryExpression().Operand)
						|| (includeBigInt && IsBigIntLiteral(node.AsPrefixUnaryExpression().Operand));
				}
				if (node.AsPrefixUnaryExpression().Operator == KindPlusToken) {
					return IsNumericLiteral(node.AsPrefixUnaryExpression().Operand);
				}
				return false;
			default:
				return false;
		}
	}

	public static function HasInferredType(node:Node):Bool {
		// Debug.type<HasInferredType>(node); // !!!
		switch (node.Kind) {
			case KindParameter | KindPropertySignature | KindPropertyDeclaration | KindBindingElement | KindPropertyAccessExpression |
				KindElementAccessExpression | KindBinaryExpression | KindCallExpression | KindVariableDeclaration | KindExportAssignment |
				KindPropertyAssignment | KindShorthandPropertyAssignment | KindJSDocParameterTag | KindJSDocPropertyTag:
				return true;
			default:
				// assertType<never>(node); // !!!
				return false;
		}
	}

	public static function IsKeyword(token:Kind):Bool {
		return KindFirstKeyword <= token && token <= KindLastKeyword;
	}

	public static function IsNonContextualKeyword(token:Kind):Bool {
		return IsKeyword(token) && !IsContextualKeyword(token);
	}

	public static function HasModifier(node:Node, flags:ModifierFlags):Bool {
		return node.ModifierFlags() & flags != 0;
	}

	public static function IsExpandoInitializer(declaration:Node, initializer:Node):Bool {
		if (initializer == null) {
			return false;
		}
		if (IsFunctionExpressionOrArrowFunction(initializer)) {
			return true;
		}
		if (IsInJSFile(initializer)) {
			return IsClassExpression(initializer)
				|| (IsObjectLiteralExpression(initializer) && Core.len(initializer.Properties()) == 0 && declaration.Type() == null);
		}
		return false;
	}

	public static function GetContainingFunction(node:Node):Node {
		return FindAncestor(node.Parent, IsFunctionLike);
	}

	public static function ImportFromModuleSpecifier(node:Node):Node {
		final result = TryGetImportFromModuleSpecifier(node);
		if (result != null) {
			return result;
		}
		final parent = node.Parent;
		// PORT: Debug.FailBadSyntaxKind takes a structure with KindString(); Node's methods live on an abstract.
		Debug.FailBadSyntaxKind({KindString: () -> parent.KindString()});
		return null;
	}

	public static function TryGetImportFromModuleSpecifier(node:StringLiteralLike):Node {
		switch (node.Parent.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration | KindExportDeclaration:
				return node.Parent;
			case KindExternalModuleReference:
				return node.Parent.Parent;
			case KindCallExpression:
				if (IsImportCall(node.Parent) || IsRequireCall(node.Parent, false /*requireStringLiteralLikeArgument*/)) {
					return node.Parent;
				}
				return null;
			case KindLiteralType:
				if (!IsStringLiteral(node)) {
					return null;
				}
				if (IsImportTypeNode(node.Parent.Parent)) {
					return node.Parent.Parent;
				}
				return null;
			default:
		}
		return null;
	}

	public static function IsImplicitlyExportedJSDocDeclaration(node:Node):Bool {
		if (!IsSourceFile(node.Parent) || !IsExternalOrCommonJSModule(node.Parent.AsSourceFile())) {
			return false;
		}
		if (IsJSTypeAliasDeclaration(node)) {
			return true;
		}
		// A reparsed ModuleDeclaration synthesized from a JSDoc @typedef/@callback
		// dotted name should also be treated as implicitly exported in modules.
		return IsModuleDeclaration(node) && node.Flags & NodeFlagsReparsed != 0;
	}

	public static function HasContextSensitiveParameters(node:Node):Bool {
		// Functions with type parameters are not context sensitive.
		if (node.TypeParameters() == null) {
			// Functions with any parameters that lack type annotations are context sensitive.
			if (Core.Some(node.Parameters(), function(p:Node):Bool {
				return p.Type() == null;
			})) {
				return true;
			}
			if (!IsArrowFunction(node)) {
				// If the first parameter is not an explicit 'this' parameter, then the function has
				// an implicit 'this' parameter which is subject to contextual typing.
				final parameter = Core.FirstOrNil(node.Parameters());
				if (parameter == null || !IsThisParameter(parameter)) {
					return node.Flags & NodeFlagsContainsThis != 0;
				}
			}
		}
		return false;
	}

	public static function IsInfinityOrNaNString(name:String):Bool {
		return name == "Infinity" || name == "-Infinity" || name == "NaN";
	}

	public static function GetFirstConstructorWithBody(node:Node):Node {
		final members = node.Members();
		if (members != null) {
			for (member in members) {
				if (IsConstructorDeclaration(member) && NodeIsPresent(member.Body())) {
					return member;
				}
			}
		}
		return null;
	}

	// Returns true for nodes that are considered executable for the purposes of unreachable code detection.
	public static function IsPotentiallyExecutableNode(node:Node):Bool {
		if (KindFirstStatement <= node.Kind && node.Kind <= KindLastStatement) {
			if (IsVariableStatement(node)) {
				final declarationList = node.AsVariableStatement().DeclarationList;
				if (GetCombinedNodeFlags(declarationList) & NodeFlagsBlockScoped != 0) {
					return true;
				}
				final declarations = declarationList.AsVariableDeclarationList().Declarations.Nodes;
				return Core.Some(declarations, function(d:Node):Bool {
					return d.Initializer() != null;
				});
			}
			return true;
		}
		return IsClassDeclaration(node) || IsEnumDeclaration(node) || IsModuleDeclaration(node);
	}

	public static function HasAbstractModifier(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsAbstract);
	}

	public static function HasAmbientModifier(node:Node):Bool {
		return HasSyntacticModifier(node, ModifierFlagsAmbient);
	}

	public static function NodeCanBeDecorated(useLegacyDecorators:Bool, node:Node, parent:Node, grandparent:Node):Bool {
		// private names cannot be used with decorators yet
		if (useLegacyDecorators && node.Name() != null && IsPrivateIdentifier(node.Name())) {
			return false;
		}
		switch (node.Kind) {
			case KindClassDeclaration:
				// class declarations are valid targets
				return true;
			case KindClassExpression:
				// class expressions are valid targets for native decorators
				return !useLegacyDecorators;
			case KindPropertyDeclaration:
				// property declarations are valid if their parent is a class declaration.
				return parent != null
					&& (useLegacyDecorators && IsClassDeclaration(parent)
						|| !useLegacyDecorators && IsClassLike(parent) && !HasAbstractModifier(node) && !HasAmbientModifier(node));
			case KindGetAccessor | KindSetAccessor | KindMethodDeclaration:
				// if this method has a body and its parent is a class declaration, this is a valid target.
				return parent != null
					&& node.Body() != null
					&& (useLegacyDecorators && IsClassDeclaration(parent) || !useLegacyDecorators && IsClassLike(parent));
			case KindParameter:
				// TODO(rbuckton): ParameterDeclaration decorator support for ES decorators must wait until it is standardized
				if (!useLegacyDecorators) {
					return false;
				}
				// if the parameter's parent has a body and its grandparent is a class declaration, this is a valid target.
				return parent != null
					&& parent.Body() != null
					&& (parent.Kind == KindConstructor || parent.Kind == KindMethodDeclaration || parent.Kind == KindSetAccessor)
					&& GetThisParameter(parent) != node
					&& grandparent != null
					&& grandparent.Kind == KindClassDeclaration;
			default:
		}

		return false;
	}

	public static function ClassOrConstructorParameterIsDecorated(useLegacyDecorators:Bool, node:Node):Bool {
		if (NodeIsDecorated(useLegacyDecorators, node, null, null)) {
			return true;
		}
		final constructor = GetFirstConstructorWithBody(node);
		return constructor != null && ChildIsDecorated(useLegacyDecorators, constructor, node);
	}

	public static function ClassElementOrClassElementParameterIsDecorated(useLegacyDecorators:Bool, node:Node, parent:Node):Bool {
		var parameters:NodeList = null;
		if (IsAccessor(node)) {
			final decls = GetAllAccessorDeclarations(parent.Members(), node);
			var firstAccessorWithDecorators:Node = null;
			if (HasDecorators(decls.FirstAccessor)) {
				firstAccessorWithDecorators = decls.FirstAccessor;
			} else if (decls.SecondAccessor != null && HasDecorators(decls.SecondAccessor)) {
				firstAccessorWithDecorators = decls.SecondAccessor;
			}
			if (firstAccessorWithDecorators == null || node != firstAccessorWithDecorators) {
				return false;
			}
			if (decls.SetAccessor != null) {
				parameters = decls.SetAccessor.Parameters;
			}
		} else if (IsMethodDeclaration(node)) {
			parameters = node.ParameterList();
		}
		if (NodeIsDecorated(useLegacyDecorators, node, parent, null)) {
			return true;
		}
		if (parameters != null && Core.len(parameters.Nodes) > 0) {
			for (parameter in parameters.Nodes) {
				if (IsThisParameter(parameter)) {
					continue;
				}
				if (NodeIsDecorated(useLegacyDecorators, parameter, node, parent)) {
					return true;
				}
			}
		}
		return false;
	}

	public static function NodeIsDecorated(useLegacyDecorators:Bool, node:Node, parent:Node, grandparent:Node):Bool {
		return HasDecorators(node) && NodeCanBeDecorated(useLegacyDecorators, node, parent, grandparent);
	}

	public static function NodeOrChildIsDecorated(useLegacyDecorators:Bool, node:Node, parent:Node, grandparent:Node):Bool {
		return NodeIsDecorated(useLegacyDecorators, node, parent, grandparent) || ChildIsDecorated(useLegacyDecorators, node, parent);
	}

	public static function ChildIsDecorated(useLegacyDecorators:Bool, node:Node, parent:Node):Bool {
		switch (node.Kind) {
			case KindClassDeclaration | KindClassExpression:
				return Core.Some(node.Members(), function(m:Node):Bool {
					return NodeOrChildIsDecorated(useLegacyDecorators, m, node, parent);
				});
			case KindMethodDeclaration | KindSetAccessor | KindConstructor:
				return Core.Some(node.Parameters(), function(p:Node):Bool {
					return NodeIsDecorated(useLegacyDecorators, p, node, parent);
				});
			default:
				return false;
		}
	}

	// type AllAccessorDeclarations → class AllAccessorDeclarations in Utilities.hx.

	public static function GetAllAccessorDeclarationsForDeclaration(accessor:AccessorDeclaration, declarationsOfSymbol:Array<Node>):AllAccessorDeclarations {
		var otherKind:Kind = KindUnknown;
		if (accessor.Kind == KindSetAccessor) {
			otherKind = KindGetAccessor;
		} else if (accessor.Kind == KindGetAccessor) {
			otherKind = KindSetAccessor;
		} else {
			throw 'Unexpected node kind "' + accessor.Kind.String() + '"';
		}
		// otherAccessor := GetDeclarationOfKind(c.getSymbolOfDeclaration(accessor), otherKind)
		var otherAccessor:AccessorDeclaration = null;
		if (declarationsOfSymbol != null) {
			for (d in declarationsOfSymbol) {
				if (d.Kind == otherKind) {
					otherAccessor = d;
					break;
				}
			}
		}

		var firstAccessor:AccessorDeclaration = null;
		var secondAccessor:AccessorDeclaration = null;
		if (otherAccessor != null && (otherAccessor.Pos() < accessor.Pos())) {
			firstAccessor = otherAccessor;
			secondAccessor = accessor;
		} else {
			firstAccessor = accessor;
			secondAccessor = otherAccessor;
		}

		var setAccessor:SetAccessorDeclaration = null;
		var getAccessor:GetAccessorDeclaration = null;
		if (accessor.Kind == KindSetAccessor) {
			setAccessor = accessor.AsSetAccessorDeclaration();
			if (otherAccessor != null) {
				getAccessor = otherAccessor.AsGetAccessorDeclaration();
			}
		} else {
			getAccessor = accessor.AsGetAccessorDeclaration();
			if (otherAccessor != null) {
				setAccessor = otherAccessor.AsSetAccessorDeclaration();
			}
		}

		final result = new AllAccessorDeclarations();
		result.FirstAccessor = firstAccessor;
		result.SecondAccessor = secondAccessor;
		result.SetAccessor = setAccessor;
		result.GetAccessor = getAccessor;
		return result;
	}

	public static function GetAllAccessorDeclarations(parentDeclarations:Array<Node>, accessor:AccessorDeclaration):AllAccessorDeclarations {
		if (HasDynamicName(accessor)) {
			// dynamic names can only be match up via checker symbol lookup, just return an object with just this accessor
			return GetAllAccessorDeclarationsForDeclaration(accessor, [accessor]);
		}

		final accessorName = GetPropertyNameForPropertyNameNode(accessor.Name());
		final accessorStatic = IsStatic(accessor);
		var matches:Array<Node> = null;
		if (parentDeclarations != null) {
			for (member in parentDeclarations) {
				if (!IsAccessor(member) || IsStatic(member) != accessorStatic) {
					continue;
				}
				final memberName = GetPropertyNameForPropertyNameNode(member.Name());
				if (memberName == accessorName) {
					if (matches == null) {
						matches = [];
					}
					matches.push(member);
				}
			}
		}
		return GetAllAccessorDeclarationsForDeclaration(accessor, matches);
	}

	public static function IsAsyncFunction(node:Node):Bool {
		switch (node.Kind) {
			case KindFunctionDeclaration | KindFunctionExpression | KindArrowFunction | KindMethodDeclaration:
				final data = node.BodyData();
				return data.Body != null && data.AsteriskToken == null && HasSyntacticModifier(node, ModifierFlagsAsync);
			default:
		}
		return false;
	}

	/**
	 * Gets the most likely element type for a TypeNode. This is not an exhaustive test
	 * as it assumes a rest argument can only be an array type (either T[], or Array<T>).
	 *
	 * @param node The type node.
	 *
	 * @internal
	 */
	public static function GetRestParameterElementType(node:ParameterDeclarationNode):Node {
		if (node == null) {
			return node;
		}
		if (node.Kind == KindArrayType) {
			return node.AsArrayTypeNode().ElementType;
		}
		if (node.Kind == KindTypeReference && node.AsTypeReferenceNode().TypeArguments != null) {
			return Core.FirstOrNil(node.AsTypeReferenceNode().TypeArguments.Nodes);
		}
		return null;
	}

	public static function TagNamesAreEquivalent(lhs:Expression, rhs:Expression):Bool {
		if (lhs.Kind != rhs.Kind) {
			return false;
		}
		switch (lhs.Kind) {
			case KindIdentifier:
				return lhs.Text() == rhs.Text();
			case KindThisKeyword:
				return true;
			case KindJsxNamespacedName:
				return lhs.AsJsxNamespacedName().Namespace.Text() == rhs.AsJsxNamespacedName().Namespace.Text()
					&& lhs.AsJsxNamespacedName().Name().Text() == rhs.AsJsxNamespacedName().Name().Text();
			case KindPropertyAccessExpression:
				return lhs.AsPropertyAccessExpression().Name().Text() == rhs.AsPropertyAccessExpression().Name().Text()
					&& TagNamesAreEquivalent(lhs.Expression(), rhs.Expression());
			default:
		}
		throw "Unhandled case in TagNamesAreEquivalent";
	}

	public static function IsTagName(node:Node):Bool {
		return node.Parent != null && IsJSDocTag(node.Parent) && node.Parent.TagName() == node;
	}

	// We want to store any numbers/strings if they were a name that could be
	// related to a declaration.  So, if we have 'import x = require("something")'
	// then we want 'something' to be in the name table.  Similarly, if we have
	// "a['propname']" then we want to store "propname" in the name table.
	static function literalIsName(node:Node):Bool {
		return IsDeclarationName(node)
			|| node.Parent.Kind == KindExternalModuleReference
			|| isArgumentOfElementAccessExpression(node)
			|| IsLiteralComputedPropertyDeclarationName(node);
	}

	static function isArgumentOfElementAccessExpression(node:Node):Bool {
		return node != null
			&& node.Parent != null
			&& node.Parent.Kind == KindElementAccessExpression
			&& node.Parent.AsElementAccessExpression().ArgumentExpression == node;
	}


	// If the given node is part of a subtree of JSDoc nodes that have been cloned into a reparsed construct,
	// return the corresponding reparsed clone in the subtree. Otherwise, just return the node.
	public static function GetReparsedNodeForNode(node:Node):Node {
		if (node != null && node.Flags & NodeFlagsJSDoc != 0 && node.Flags & NodeFlagsReparsed == 0) {
			final file = GetSourceFileOfNode(node);
			if (file != null && Core.len(file.ReparsedClones) != 0) {
				final r = Slices.BinarySearchFunc(file.ReparsedClones, node, CompareNodePositions);
				var pos = r.value;
				if (!r.ok && pos > 0) {
					pos--;
				}
				final candidate = file.ReparsedClones[pos];
				if (node.Loc.ContainedBy(candidate.Loc)) {
					final reparsed = findCloneInNode(candidate, node);
					if (reparsed != null) {
						return reparsed;
					}
				}
			}
		}
		return node;
	}

	static function findCloneInNode(node:Node, original:Node):Node {
		while (true) {
			// PORT: Go struct equality `node.Loc == original.Loc` → TextRange.Equals.
			if (node.Kind == original.Kind && node.Loc.Equals(original.Loc)) {
				return node;
			}
			final foundContainingChild = node.ForEachChild(function(n:Node):Bool {
				if (original.Loc.ContainedBy(n.Loc)) {
					node = n;
					return true;
				}
				return false;
			});
			if (!foundContainingChild) {
				return null;
			}
		}
	}

	public static function IsExpandoPropertyDeclaration(node:Node):Bool {
		return node != null && IsBinaryExpression(node);
	}

	// IsSuperProperty checks if a node is super.x or super[x].
	public static function IsSuperProperty(node:Node):Bool {
		return (IsPropertyAccessExpression(node) || IsElementAccessExpression(node)) && node.Expression().Kind == KindSuperKeyword;
	}

	// Indicates whether a node is a potential source of an assigned name for a class, function, or arrow function.
	public static function IsNamedEvaluationSource(node:Node):Bool {
		switch (node.Kind) {
			case KindPropertyAssignment:
				return !IsProtoSetter(node.AsPropertyAssignment().Name());
			case KindShorthandPropertyAssignment:
				return node.AsShorthandPropertyAssignment().ObjectAssignmentInitializer != null;
			case KindVariableDeclaration:
				return IsIdentifier(node.AsVariableDeclaration().Name()) && node.Initializer() != null;
			case KindParameter:
				return IsIdentifier(node.AsParameterDeclaration().Name())
					&& node.Initializer() != null
					&& node.AsParameterDeclaration().DotDotDotToken == null;
			case KindBindingElement:
				return IsIdentifier(node.AsBindingElement().Name()) && node.Initializer() != null && node.AsBindingElement().DotDotDotToken == null;
			case KindPropertyDeclaration:
				return node.Initializer() != null;
			case KindBinaryExpression:
				switch (node.AsBinaryExpression().OperatorToken.Kind) {
					case KindEqualsToken | KindAmpersandAmpersandEqualsToken | KindBarBarEqualsToken | KindQuestionQuestionEqualsToken:
						return IsIdentifier(node.AsBinaryExpression().Left);
					default:
				}
			case KindExportAssignment:
				return true;
			default:
		}
		return false;
	}

	// Indicates whether a property name is the special `__proto__` property.
	// Per the ECMA-262 spec, this only matters for property assignments whose name is
	// the Identifier `__proto__`, or the string literal `"__proto__"`, but not for
	// computed property names.
	public static function IsProtoSetter(node:Node):Bool {
		return (IsIdentifier(node) || IsStringLiteral(node)) && node.Text() == "__proto__";
	}

	// --- visitor.go ---

	public static function NewNodeVisitor(visit:(node:Node) -> Node, factory:NodeFactory, hooks:NodeVisitorHooks):NodeVisitor {
		if (factory == null) {
			factory = new NodeFactory();
		}
		final v = new NodeVisitor();
		v.Visit = visit;
		v.Factory = factory;
		v.Hooks = hooks;
		return v;
	}
}

// Visitor

typedef Visitor = (node:Node) -> Bool;

class NodeFactoryHooks {
	public var OnCreate:(node:Node) -> Void = null; // Hooks the creation of a node.
	public var OnUpdate:(node:Node, original:Node) -> Void = null; // Hooks the updating of a node.
	public var OnClone:(node:Node, original:Node) -> Void = null; // Hooks the cloning of a node.

	public function new() {}
}

interface NodeFactoryCoercible {
	function AsNodeFactory():NodeFactory;
}

// NodeFactory
// PORT: arena — Go allocates nodes from per-kind arenas (core.Arena); here every node is a plain
// `new X()` (one allocation per node either way). The struct is in ast_generated.go upstream; the
// New*/Update* methods are generated into the region below.
@:allow(ts.ast)
class NodeFactory implements NodeFactoryCoercible {
	var hooks:NodeFactoryHooks = new NodeFactoryHooks();

	var nodeCount:Int = 0;
	var textCount:Int = 0;

	public function new() {}

	function newNode(kind:Kind, data:NodeDefault):Node {
		nodeCount++;
		return Ast.newNode(kind, data, hooks);
	}

	public function NodeCount():Int {
		return nodeCount;
	}

	public function TextCount():Int {
		return textCount;
	}

	public function AsNodeFactory():NodeFactory {
		return this;
	}

	public function NewNodeList(nodes:Array<Node>):NodeList {
		final list = new NodeList();
		list.Loc = Core.UndefinedTextRange();
		list.Nodes = nodes;
		return list;
	}

	public function NewModifierList(nodes:Array<Node>):ModifierList {
		final list = new ModifierList();
		list.Loc = Core.UndefinedTextRange();
		list.Nodes = nodes;
		list.ModifierFlags = Ast.ModifiersToFlags(nodes);
		return list;
	}

	public function NewModifier(kind:Kind):Node {
		return NewToken(kind);
	}

	public function NewSourceFile(opts:SourceFileParseOptions, text:String, statements:NodeList, endOfFileToken:TokenNode):Node {
		if (Tspath.GetEncodedRootLength(opts.FileName) == 0 || opts.FileName != Tspath.NormalizePath(opts.FileName)) {
			throw 'fileName should be normalized and absolute: "${opts.FileName}"';
		}
		final data = new SourceFile();
		data.fileName = opts.FileName;
		data.parseOptions = opts;
		data.text = text;
		data.ContainsNonASCII = Stringutil.ContainsNonASCII(text);
		data.Statements = statements;
		data.EndOfFileToken = endOfFileToken;
		return newNode(KindSourceFile, data);
	}

	public function UpdateSourceFile(node:SourceFile, statements:StatementList, endOfFileToken:TokenNode):Node {
		if (statements != node.Statements || endOfFileToken != node.EndOfFileToken) {
			final updated = NewSourceFile(node.parseOptions, node.text, statements, endOfFileToken).AsSourceFile();
			updated.copyFrom(node);
			return Ast.updateNode(updated.AsNode(), node.AsNode(), hooks);
		}
		return node.AsNode();
	}

	public function NewCommentRange(kind:Kind, pos:Int, end:Int, hasTrailingNewLine:Bool):CommentRange {
		return new CommentRange(Core.NewTextRange(pos, end), kind, hasTrailingNewLine);
	}

	// PORT: arena — there are no arenas to release; Go keeps hooks and counts.
	public function ReleaseArenas():Void {}

	// BEGIN GENERATED (tools/gen/ast) — do not edit: factory
	// --- ast_generated.go: New*() / Update*() factory methods ---

	public function NewToken(kind:TokenSyntaxKind):Node {
		final data = new Token();
		return this.newNode(kind, data);
	}

	public function NewIdentifier(text:String):Node {
		final data = new Identifier();
		data.Text = text;
		this.textCount++;
		return this.newNode(KindIdentifier, data);
	}

	public function NewPrivateIdentifier(text:String):Node {
		final data = new PrivateIdentifier();
		data.Text = text;
		this.textCount++;
		return this.newNode(KindPrivateIdentifier, data);
	}

	public function NewQualifiedName(left:EntityName, right:IdentifierNode):Node {
		final data = new QualifiedName();
		data.Left = left;
		data.Right = right;
		return this.newNode(KindQualifiedName, data);
	}

	public function UpdateQualifiedName(node:QualifiedName, left:EntityName, right:IdentifierNode):Node {
		if (left != node.Left || right != node.Right) {
			return Ast.updateNode(this.NewQualifiedName(left, right), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewComputedPropertyName(expression:Expression):Node {
		final data = new ComputedPropertyName();
		data.Expression = expression;
		return this.newNode(KindComputedPropertyName, data);
	}

	public function UpdateComputedPropertyName(node:ComputedPropertyName, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewComputedPropertyName(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewDecorator(expression:LeftHandSideExpression):Node {
		final data = new Decorator();
		data.Expression = expression;
		return this.newNode(KindDecorator, data);
	}

	public function UpdateDecorator(node:Decorator, expression:LeftHandSideExpression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewDecorator(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewEmptyStatement():Node {
		final data = new EmptyStatement();
		return this.newNode(KindEmptyStatement, data);
	}

	public function NewIfStatement(expression:Expression, thenStatement:Statement, elseStatement:Statement):Node {
		final data = new IfStatement();
		data.Expression = expression;
		data.ThenStatement = thenStatement;
		data.ElseStatement = elseStatement;
		return this.newNode(KindIfStatement, data);
	}

	public function UpdateIfStatement(node:IfStatement, expression:Expression, thenStatement:Statement, elseStatement:Statement):Node {
		if (expression != node.Expression || thenStatement != node.ThenStatement || elseStatement != node.ElseStatement) {
			return Ast.updateNode(this.NewIfStatement(expression, thenStatement, elseStatement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewDoStatement(statement:Statement, expression:Expression):Node {
		final data = new DoStatement();
		data.Statement = statement;
		data.Expression = expression;
		return this.newNode(KindDoStatement, data);
	}

	public function UpdateDoStatement(node:DoStatement, statement:Statement, expression:Expression):Node {
		if (statement != node.Statement || expression != node.Expression) {
			return Ast.updateNode(this.NewDoStatement(statement, expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewWhileStatement(expression:Expression, statement:Statement):Node {
		final data = new WhileStatement();
		data.Expression = expression;
		data.Statement = statement;
		return this.newNode(KindWhileStatement, data);
	}

	public function UpdateWhileStatement(node:WhileStatement, expression:Expression, statement:Statement):Node {
		if (expression != node.Expression || statement != node.Statement) {
			return Ast.updateNode(this.NewWhileStatement(expression, statement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewForStatement(initializer:ForInitializer, condition:Expression, incrementor:Expression, statement:Statement):Node {
		final data = new ForStatement();
		data.Initializer = initializer;
		data.Condition = condition;
		data.Incrementor = incrementor;
		data.Statement = statement;
		return this.newNode(KindForStatement, data);
	}

	public function UpdateForStatement(node:ForStatement, initializer:ForInitializer, condition:Expression, incrementor:Expression, statement:Statement):Node {
		if (initializer != node.Initializer || condition != node.Condition || incrementor != node.Incrementor || statement != node.Statement) {
			return Ast.updateNode(this.NewForStatement(initializer, condition, incrementor, statement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewForInOrOfStatement(kind:Kind, awaitModifier:AwaitKeyword, initializer:ForInitializer, expression:Expression, statement:Statement):Node {
		final data = new ForInOrOfStatement();
		data.AwaitModifier = awaitModifier;
		data.Initializer = initializer;
		data.Expression = expression;
		data.Statement = statement;
		return this.newNode(kind, data);
	}

	public function UpdateForInOrOfStatement(node:ForInOrOfStatement, awaitModifier:AwaitKeyword, initializer:ForInitializer, expression:Expression, statement:Statement):Node {
		if (awaitModifier != node.AwaitModifier || initializer != node.Initializer || expression != node.Expression || statement != node.Statement) {
			return Ast.updateNode(this.NewForInOrOfStatement(node.Kind, awaitModifier, initializer, expression, statement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewBreakStatement(label:IdentifierNode):Node {
		final data = new BreakStatement();
		data.Label = label;
		return this.newNode(KindBreakStatement, data);
	}

	public function UpdateBreakStatement(node:BreakStatement, label:IdentifierNode):Node {
		if (label != node.Label) {
			return Ast.updateNode(this.NewBreakStatement(label), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewContinueStatement(label:IdentifierNode):Node {
		final data = new ContinueStatement();
		data.Label = label;
		return this.newNode(KindContinueStatement, data);
	}

	public function UpdateContinueStatement(node:ContinueStatement, label:IdentifierNode):Node {
		if (label != node.Label) {
			return Ast.updateNode(this.NewContinueStatement(label), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewReturnStatement(expression:Expression):Node {
		final data = new ReturnStatement();
		data.Expression = expression;
		return this.newNode(KindReturnStatement, data);
	}

	public function UpdateReturnStatement(node:ReturnStatement, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewReturnStatement(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewWithStatement(expression:Expression, statement:Statement):Node {
		final data = new WithStatement();
		data.Expression = expression;
		data.Statement = statement;
		return this.newNode(KindWithStatement, data);
	}

	public function UpdateWithStatement(node:WithStatement, expression:Expression, statement:Statement):Node {
		if (expression != node.Expression || statement != node.Statement) {
			return Ast.updateNode(this.NewWithStatement(expression, statement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSwitchStatement(expression:Expression, caseBlock:CaseBlockNode):Node {
		final data = new SwitchStatement();
		data.Expression = expression;
		data.CaseBlock = caseBlock;
		return this.newNode(KindSwitchStatement, data);
	}

	public function UpdateSwitchStatement(node:SwitchStatement, expression:Expression, caseBlock:CaseBlockNode):Node {
		if (expression != node.Expression || caseBlock != node.CaseBlock) {
			return Ast.updateNode(this.NewSwitchStatement(expression, caseBlock), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewCaseBlock(clauses:CaseClausesList):Node {
		final data = new CaseBlock();
		data.Clauses = clauses;
		return this.newNode(KindCaseBlock, data);
	}

	public function UpdateCaseBlock(node:CaseBlock, clauses:CaseClausesList):Node {
		if (clauses != node.Clauses) {
			return Ast.updateNode(this.NewCaseBlock(clauses), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewCaseOrDefaultClause(kind:Kind, expression:Expression, statements:StatementList):Node {
		final data = new CaseOrDefaultClause();
		data.Expression = expression;
		data.Statements = statements;
		return this.newNode(kind, data);
	}

	public function UpdateCaseOrDefaultClause(node:CaseOrDefaultClause, expression:Expression, statements:StatementList):Node {
		if (expression != node.Expression || statements != node.Statements) {
			return Ast.updateNode(this.NewCaseOrDefaultClause(node.Kind, expression, statements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewThrowStatement(expression:Expression):Node {
		final data = new ThrowStatement();
		data.Expression = expression;
		return this.newNode(KindThrowStatement, data);
	}

	public function UpdateThrowStatement(node:ThrowStatement, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewThrowStatement(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTryStatement(tryBlock:BlockNode, catchClause:CatchClauseNode, finallyBlock:BlockNode):Node {
		final data = new TryStatement();
		data.TryBlock = tryBlock;
		data.CatchClause = catchClause;
		data.FinallyBlock = finallyBlock;
		return this.newNode(KindTryStatement, data);
	}

	public function UpdateTryStatement(node:TryStatement, tryBlock:BlockNode, catchClause:CatchClauseNode, finallyBlock:BlockNode):Node {
		if (tryBlock != node.TryBlock || catchClause != node.CatchClause || finallyBlock != node.FinallyBlock) {
			return Ast.updateNode(this.NewTryStatement(tryBlock, catchClause, finallyBlock), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewCatchClause(variableDeclaration:VariableDeclarationNode, block:BlockNode):Node {
		final data = new CatchClause();
		data.VariableDeclaration = variableDeclaration;
		data.Block = block;
		return this.newNode(KindCatchClause, data);
	}

	public function UpdateCatchClause(node:CatchClause, variableDeclaration:VariableDeclarationNode, block:BlockNode):Node {
		if (variableDeclaration != node.VariableDeclaration || block != node.Block) {
			return Ast.updateNode(this.NewCatchClause(variableDeclaration, block), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewDebuggerStatement():Node {
		final data = new DebuggerStatement();
		return this.newNode(KindDebuggerStatement, data);
	}

	public function NewLabeledStatement(label:IdentifierNode, statement:Statement):Node {
		final data = new LabeledStatement();
		data.Label = label;
		data.Statement = statement;
		return this.newNode(KindLabeledStatement, data);
	}

	public function UpdateLabeledStatement(node:LabeledStatement, label:IdentifierNode, statement:Statement):Node {
		if (label != node.Label || statement != node.Statement) {
			return Ast.updateNode(this.NewLabeledStatement(label, statement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewExpressionStatement(expression:Expression):Node {
		final data = new ExpressionStatement();
		data.Expression = expression;
		return this.newNode(KindExpressionStatement, data);
	}

	public function UpdateExpressionStatement(node:ExpressionStatement, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewExpressionStatement(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewBlock(statements:StatementList, multiLine:Bool):Node {
		final data = new Block();
		data.Statements = statements;
		data.MultiLine = multiLine;
		return this.newNode(KindBlock, data);
	}

	public function UpdateBlock(node:Block, statements:StatementList, multiLine:Bool):Node {
		if (statements != node.Statements || multiLine != node.MultiLine) {
			return Ast.updateNode(this.NewBlock(statements, multiLine), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewVariableStatement(modifiers:ModifierList, declarationList:VariableDeclarationListNode):Node {
		final data = new VariableStatement();
		data.modifiers = modifiers;
		data.DeclarationList = declarationList;
		return this.newNode(KindVariableStatement, data);
	}

	public function UpdateVariableStatement(node:VariableStatement, modifiers:ModifierList, declarationList:VariableDeclarationListNode):Node {
		if (modifiers != node.modifiers || declarationList != node.DeclarationList) {
			return Ast.updateNode(this.NewVariableStatement(modifiers, declarationList), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewVariableDeclaration(name:BindingName, exclamationToken:ExclamationToken, typeNode:TypeNode, initializer:Expression):Node {
		final data = new VariableDeclaration();
		data.name = name;
		data.ExclamationToken = exclamationToken;
		data.Type = typeNode;
		data.Initializer = initializer;
		return this.newNode(KindVariableDeclaration, data);
	}

	public function UpdateVariableDeclaration(node:VariableDeclaration, name:BindingName, exclamationToken:ExclamationToken, typeNode:TypeNode, initializer:Expression):Node {
		if (name != node.name || exclamationToken != node.ExclamationToken || typeNode != node.Type || initializer != node.Initializer) {
			return Ast.updateNode(this.NewVariableDeclaration(name, exclamationToken, typeNode, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewVariableDeclarationList(declarations:VariableDeclarationNodeList, flags:NodeFlags):Node {
		final data = new VariableDeclarationList();
		data.Declarations = declarations;
		final node = this.newNode(KindVariableDeclarationList, data);
		node.Flags = flags;
		return node;
	}

	public function UpdateVariableDeclarationList(node:VariableDeclarationList, declarations:VariableDeclarationNodeList, flags:NodeFlags):Node {
		if (declarations != node.Declarations || flags != node.Flags) {
			return Ast.updateNode(this.NewVariableDeclarationList(declarations, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewBindingPattern(kind:Kind, elements:BindingElementList):Node {
		final data = new BindingPattern();
		data.Elements = elements;
		return this.newNode(kind, data);
	}

	public function UpdateBindingPattern(node:BindingPattern, elements:BindingElementList):Node {
		if (elements != node.Elements) {
			return Ast.updateNode(this.NewBindingPattern(node.Kind, elements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewParameterDeclaration(modifiers:ModifierList, dotDotDotToken:DotDotDotToken, name:BindingName, questionToken:QuestionToken, typeNode:TypeNode, initializer:Expression):Node {
		final data = new ParameterDeclaration();
		data.modifiers = modifiers;
		data.DotDotDotToken = dotDotDotToken;
		data.name = name;
		data.QuestionToken = questionToken;
		data.Type = typeNode;
		data.Initializer = initializer;
		return this.newNode(KindParameter, data);
	}

	public function UpdateParameterDeclaration(node:ParameterDeclaration, modifiers:ModifierList, dotDotDotToken:DotDotDotToken, name:BindingName, questionToken:QuestionToken, typeNode:TypeNode, initializer:Expression):Node {
		if (modifiers != node.modifiers || dotDotDotToken != node.DotDotDotToken || name != node.name || questionToken != node.QuestionToken || typeNode != node.Type || initializer != node.Initializer) {
			return Ast.updateNode(this.NewParameterDeclaration(modifiers, dotDotDotToken, name, questionToken, typeNode, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewBindingElement(dotDotDotToken:DotDotDotToken, propertyName:PropertyName, name:BindingName, initializer:Expression):Node {
		final data = new BindingElement();
		data.DotDotDotToken = dotDotDotToken;
		data.PropertyName = propertyName;
		data.name = name;
		data.Initializer = initializer;
		return this.newNode(KindBindingElement, data);
	}

	public function UpdateBindingElement(node:BindingElement, dotDotDotToken:DotDotDotToken, propertyName:PropertyName, name:BindingName, initializer:Expression):Node {
		if (dotDotDotToken != node.DotDotDotToken || propertyName != node.PropertyName || name != node.name || initializer != node.Initializer) {
			return Ast.updateNode(this.NewBindingElement(dotDotDotToken, propertyName, name, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewMissingDeclaration(modifiers:ModifierList):Node {
		final data = new MissingDeclaration();
		data.modifiers = modifiers;
		return this.newNode(KindMissingDeclaration, data);
	}

	public function UpdateMissingDeclaration(node:MissingDeclaration, modifiers:ModifierList):Node {
		if (modifiers != node.modifiers) {
			return Ast.updateNode(this.NewMissingDeclaration(modifiers), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewFunctionDeclaration(modifiers:ModifierList, asteriskToken:AsteriskToken, name:IdentifierNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new FunctionDeclaration();
		data.modifiers = modifiers;
		data.AsteriskToken = asteriskToken;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindFunctionDeclaration, data);
	}

	public function UpdateFunctionDeclaration(node:FunctionDeclaration, modifiers:ModifierList, asteriskToken:AsteriskToken, name:IdentifierNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || asteriskToken != node.AsteriskToken || name != node.name || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewFunctionDeclaration(modifiers, asteriskToken, name, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewClassDeclaration(modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:ClassElementList):Node {
		final data = new ClassDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.HeritageClauses = heritageClauses;
		data.Members = members;
		return this.newNode(KindClassDeclaration, data);
	}

	public function UpdateClassDeclaration(node:ClassDeclaration, modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:ClassElementList):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || heritageClauses != node.HeritageClauses || members != node.Members) {
			return Ast.updateNode(this.NewClassDeclaration(modifiers, name, typeParameters, heritageClauses, members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewClassExpression(modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:ClassElementList):Node {
		final data = new ClassExpression();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.HeritageClauses = heritageClauses;
		data.Members = members;
		return this.newNode(KindClassExpression, data);
	}

	public function UpdateClassExpression(node:ClassExpression, modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:ClassElementList):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || heritageClauses != node.HeritageClauses || members != node.Members) {
			return Ast.updateNode(this.NewClassExpression(modifiers, name, typeParameters, heritageClauses, members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewHeritageClause(token:Kind, types:ExpressionWithTypeArgumentsList):Node {
		final data = new HeritageClause();
		data.Token = token;
		data.Types = types;
		return this.newNode(KindHeritageClause, data);
	}

	public function UpdateHeritageClause(node:HeritageClause, token:Kind, types:ExpressionWithTypeArgumentsList):Node {
		if (token != node.Token || types != node.Types) {
			return Ast.updateNode(this.NewHeritageClause(token, types), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewInterfaceDeclaration(modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:TypeElementList):Node {
		final data = new InterfaceDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.HeritageClauses = heritageClauses;
		data.Members = members;
		return this.newNode(KindInterfaceDeclaration, data);
	}

	public function UpdateInterfaceDeclaration(node:InterfaceDeclaration, modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, heritageClauses:HeritageClauseList, members:TypeElementList):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || heritageClauses != node.HeritageClauses || members != node.Members) {
			return Ast.updateNode(this.NewInterfaceDeclaration(modifiers, name, typeParameters, heritageClauses, members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeAliasDeclaration(modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, typeNode:TypeNode):Node {
		final data = new TypeAliasDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Type = typeNode;
		return this.newNode(KindTypeAliasDeclaration, data);
	}

	public function NewJSTypeAliasDeclaration(modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, typeNode:TypeNode):Node {
		final data = new TypeAliasDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Type = typeNode;
		return this.newNode(KindJSTypeAliasDeclaration, data);
	}

	public function UpdateTypeAliasDeclaration(node:TypeAliasDeclaration, modifiers:ModifierList, name:IdentifierNode, typeParameters:TypeParameterList, typeNode:TypeNode):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || typeNode != node.Type) {
			switch (node.Kind) {
				case KindTypeAliasDeclaration:
					return Ast.updateNode(this.NewTypeAliasDeclaration(modifiers, name, typeParameters, typeNode), node.AsNode(), this.hooks);
				case KindJSTypeAliasDeclaration:
					return Ast.updateNode(this.NewJSTypeAliasDeclaration(modifiers, name, typeParameters, typeNode), node.AsNode(), this.hooks);
				default:
					throw "unexpected kind in UpdateTypeAliasDeclaration: " + node.Kind.String();
			}
		}
		return node.AsNode();
	}

	public function NewEnumMember(name:PropertyName, initializer:Expression):Node {
		final data = new EnumMember();
		data.name = name;
		data.Initializer = initializer;
		return this.newNode(KindEnumMember, data);
	}

	public function UpdateEnumMember(node:EnumMember, name:PropertyName, initializer:Expression):Node {
		if (name != node.name || initializer != node.Initializer) {
			return Ast.updateNode(this.NewEnumMember(name, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewEnumDeclaration(modifiers:ModifierList, name:IdentifierNode, members:EnumMemberList):Node {
		final data = new EnumDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.Members = members;
		return this.newNode(KindEnumDeclaration, data);
	}

	public function UpdateEnumDeclaration(node:EnumDeclaration, modifiers:ModifierList, name:IdentifierNode, members:EnumMemberList):Node {
		if (modifiers != node.modifiers || name != node.name || members != node.Members) {
			return Ast.updateNode(this.NewEnumDeclaration(modifiers, name, members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewModuleBlock(statements:StatementList):Node {
		final data = new ModuleBlock();
		data.Statements = statements;
		return this.newNode(KindModuleBlock, data);
	}

	public function UpdateModuleBlock(node:ModuleBlock, statements:StatementList):Node {
		if (statements != node.Statements) {
			return Ast.updateNode(this.NewModuleBlock(statements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNotEmittedStatement():Node {
		final data = new NotEmittedStatement();
		return this.newNode(KindNotEmittedStatement, data);
	}

	public function NewNotEmittedTypeElement():Node {
		final data = new NotEmittedTypeElement();
		return this.newNode(KindNotEmittedTypeElement, data);
	}

	public function NewImportDeclaration(modifiers:ModifierList, importClause:ImportClauseNode, moduleSpecifier:Expression, attributes:ImportAttributesNode):Node {
		final data = new ImportDeclaration();
		data.modifiers = modifiers;
		data.ImportClause = importClause;
		data.ModuleSpecifier = moduleSpecifier;
		data.Attributes = attributes;
		return this.newNode(KindImportDeclaration, data);
	}

	public function NewJSImportDeclaration(modifiers:ModifierList, importClause:ImportClauseNode, moduleSpecifier:Expression, attributes:ImportAttributesNode):Node {
		final data = new ImportDeclaration();
		data.modifiers = modifiers;
		data.ImportClause = importClause;
		data.ModuleSpecifier = moduleSpecifier;
		data.Attributes = attributes;
		return this.newNode(KindJSImportDeclaration, data);
	}

	public function UpdateImportDeclaration(node:ImportDeclaration, modifiers:ModifierList, importClause:ImportClauseNode, moduleSpecifier:Expression, attributes:ImportAttributesNode):Node {
		if (modifiers != node.modifiers || importClause != node.ImportClause || moduleSpecifier != node.ModuleSpecifier || attributes != node.Attributes) {
			switch (node.Kind) {
				case KindImportDeclaration:
					return Ast.updateNode(this.NewImportDeclaration(modifiers, importClause, moduleSpecifier, attributes), node.AsNode(), this.hooks);
				case KindJSImportDeclaration:
					return Ast.updateNode(this.NewJSImportDeclaration(modifiers, importClause, moduleSpecifier, attributes), node.AsNode(), this.hooks);
				default:
					throw "unexpected kind in UpdateImportDeclaration: " + node.Kind.String();
			}
		}
		return node.AsNode();
	}

	public function NewExternalModuleReference(expression:Expression):Node {
		final data = new ExternalModuleReference();
		data.Expression = expression;
		return this.newNode(KindExternalModuleReference, data);
	}

	public function UpdateExternalModuleReference(node:ExternalModuleReference, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewExternalModuleReference(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamespaceImport(name:IdentifierNode):Node {
		final data = new NamespaceImport();
		data.name = name;
		return this.newNode(KindNamespaceImport, data);
	}

	public function UpdateNamespaceImport(node:NamespaceImport, name:IdentifierNode):Node {
		if (name != node.name) {
			return Ast.updateNode(this.NewNamespaceImport(name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamedImports(elements:ImportSpecifierList):Node {
		final data = new NamedImports();
		data.Elements = elements;
		return this.newNode(KindNamedImports, data);
	}

	public function UpdateNamedImports(node:NamedImports, elements:ImportSpecifierList):Node {
		if (elements != node.Elements) {
			return Ast.updateNode(this.NewNamedImports(elements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewExportAssignment(modifiers:ModifierList, isExportEquals:Bool, typeNode:TypeNode, expression:Expression):Node {
		final data = new ExportAssignment();
		data.modifiers = modifiers;
		data.IsExportEquals = isExportEquals;
		data.Type = typeNode;
		data.Expression = expression;
		return this.newNode(KindExportAssignment, data);
	}

	public function UpdateExportAssignment(node:ExportAssignment, modifiers:ModifierList, isExportEquals:Bool, typeNode:TypeNode, expression:Expression):Node {
		if (modifiers != node.modifiers || isExportEquals != node.IsExportEquals || typeNode != node.Type || expression != node.Expression) {
			return Ast.updateNode(this.NewExportAssignment(modifiers, isExportEquals, typeNode, expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamespaceExportDeclaration(modifiers:ModifierList, name:IdentifierNode):Node {
		final data = new NamespaceExportDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		return this.newNode(KindNamespaceExportDeclaration, data);
	}

	public function UpdateNamespaceExportDeclaration(node:NamespaceExportDeclaration, modifiers:ModifierList, name:IdentifierNode):Node {
		if (modifiers != node.modifiers || name != node.name) {
			return Ast.updateNode(this.NewNamespaceExportDeclaration(modifiers, name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamespaceExport(name:ModuleExportName):Node {
		final data = new NamespaceExport();
		data.name = name;
		return this.newNode(KindNamespaceExport, data);
	}

	public function UpdateNamespaceExport(node:NamespaceExport, name:ModuleExportName):Node {
		if (name != node.name) {
			return Ast.updateNode(this.NewNamespaceExport(name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamedExports(elements:ExportSpecifierList):Node {
		final data = new NamedExports();
		data.Elements = elements;
		return this.newNode(KindNamedExports, data);
	}

	public function UpdateNamedExports(node:NamedExports, elements:ExportSpecifierList):Node {
		if (elements != node.Elements) {
			return Ast.updateNode(this.NewNamedExports(elements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewExportSpecifier(isTypeOnly:Bool, propertyName:ModuleExportName, name:ModuleExportName):Node {
		final data = new ExportSpecifier();
		data.IsTypeOnly = isTypeOnly;
		data.PropertyName = propertyName;
		data.name = name;
		return this.newNode(KindExportSpecifier, data);
	}

	public function UpdateExportSpecifier(node:ExportSpecifier, isTypeOnly:Bool, propertyName:ModuleExportName, name:ModuleExportName):Node {
		if (isTypeOnly != node.IsTypeOnly || propertyName != node.PropertyName || name != node.name) {
			return Ast.updateNode(this.NewExportSpecifier(isTypeOnly, propertyName, name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewCallSignatureDeclaration(typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new CallSignatureDeclaration();
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindCallSignature, data);
	}

	public function UpdateCallSignatureDeclaration(node:CallSignatureDeclaration, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewCallSignatureDeclaration(typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewConstructSignatureDeclaration(typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new ConstructSignatureDeclaration();
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindConstructSignature, data);
	}

	public function UpdateConstructSignatureDeclaration(node:ConstructSignatureDeclaration, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewConstructSignatureDeclaration(typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewConstructorDeclaration(modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new ConstructorDeclaration();
		data.modifiers = modifiers;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindConstructor, data);
	}

	public function UpdateConstructorDeclaration(node:ConstructorDeclaration, modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewConstructorDeclaration(modifiers, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewGetAccessorDeclaration(modifiers:ModifierList, name:PropertyName, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new GetAccessorDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindGetAccessor, data);
	}

	public function UpdateGetAccessorDeclaration(node:GetAccessorDeclaration, modifiers:ModifierList, name:PropertyName, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewGetAccessorDeclaration(modifiers, name, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSetAccessorDeclaration(modifiers:ModifierList, name:PropertyName, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new SetAccessorDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindSetAccessor, data);
	}

	public function UpdateSetAccessorDeclaration(node:SetAccessorDeclaration, modifiers:ModifierList, name:PropertyName, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || name != node.name || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewSetAccessorDeclaration(modifiers, name, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewIndexSignatureDeclaration(modifiers:ModifierList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new IndexSignatureDeclaration();
		data.modifiers = modifiers;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindIndexSignature, data);
	}

	public function UpdateIndexSignatureDeclaration(node:IndexSignatureDeclaration, modifiers:ModifierList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (modifiers != node.modifiers || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewIndexSignatureDeclaration(modifiers, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewMethodSignatureDeclaration(modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new MethodSignatureDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindMethodSignature, data);
	}

	public function UpdateMethodSignatureDeclaration(node:MethodSignatureDeclaration, modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (modifiers != node.modifiers || name != node.name || postfixToken != node.PostfixToken || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewMethodSignatureDeclaration(modifiers, name, postfixToken, typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewMethodDeclaration(modifiers:ModifierList, asteriskToken:AsteriskToken, name:PropertyName, postfixToken:TokenNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new MethodDeclaration();
		data.modifiers = modifiers;
		data.AsteriskToken = asteriskToken;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindMethodDeclaration, data);
	}

	public function UpdateMethodDeclaration(node:MethodDeclaration, modifiers:ModifierList, asteriskToken:AsteriskToken, name:PropertyName, postfixToken:TokenNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || asteriskToken != node.AsteriskToken || name != node.name || postfixToken != node.PostfixToken || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewMethodDeclaration(modifiers, asteriskToken, name, postfixToken, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPropertySignatureDeclaration(modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		final data = new PropertySignatureDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.Type = typeNode;
		data.Initializer = initializer;
		return this.newNode(KindPropertySignature, data);
	}

	public function UpdatePropertySignatureDeclaration(node:PropertySignatureDeclaration, modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		if (modifiers != node.modifiers || name != node.name || postfixToken != node.PostfixToken || typeNode != node.Type || initializer != node.Initializer) {
			return Ast.updateNode(this.NewPropertySignatureDeclaration(modifiers, name, postfixToken, typeNode, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPropertyDeclaration(modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		final data = new PropertyDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.Type = typeNode;
		data.Initializer = initializer;
		return this.newNode(KindPropertyDeclaration, data);
	}

	public function UpdatePropertyDeclaration(node:PropertyDeclaration, modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		if (modifiers != node.modifiers || name != node.name || postfixToken != node.PostfixToken || typeNode != node.Type || initializer != node.Initializer) {
			return Ast.updateNode(this.NewPropertyDeclaration(modifiers, name, postfixToken, typeNode, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSemicolonClassElement():Node {
		final data = new SemicolonClassElement();
		return this.newNode(KindSemicolonClassElement, data);
	}

	public function NewClassStaticBlockDeclaration(modifiers:ModifierList, body:BlockNode):Node {
		final data = new ClassStaticBlockDeclaration();
		data.modifiers = modifiers;
		data.Body = body;
		return this.newNode(KindClassStaticBlockDeclaration, data);
	}

	public function UpdateClassStaticBlockDeclaration(node:ClassStaticBlockDeclaration, modifiers:ModifierList, body:BlockNode):Node {
		if (modifiers != node.modifiers || body != node.Body) {
			return Ast.updateNode(this.NewClassStaticBlockDeclaration(modifiers, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewOmittedExpression():Node {
		final data = new OmittedExpression();
		return this.newNode(KindOmittedExpression, data);
	}

	public function NewKeywordExpression(kind:KeywordExpressionSyntaxKind):Node {
		final data = new KeywordExpression();
		return this.newNode(kind, data);
	}

	public function NewStringLiteral(text:String, tokenFlags:TokenFlags):Node {
		final data = new StringLiteral();
		data.Text = text;
		data.TokenFlags = tokenFlags & TokenFlagsStringLiteralFlags;
		this.textCount++;
		return this.newNode(KindStringLiteral, data);
	}

	public function NewNumericLiteral(text:String, tokenFlags:TokenFlags):Node {
		final data = new NumericLiteral();
		data.Text = text;
		data.TokenFlags = tokenFlags & TokenFlagsNumericLiteralFlags;
		this.textCount++;
		return this.newNode(KindNumericLiteral, data);
	}

	public function NewBigIntLiteral(text:String, tokenFlags:TokenFlags):Node {
		final data = new BigIntLiteral();
		data.Text = text;
		data.TokenFlags = tokenFlags & TokenFlagsNumericLiteralFlags;
		this.textCount++;
		return this.newNode(KindBigIntLiteral, data);
	}

	public function NewRegularExpressionLiteral(text:String, tokenFlags:TokenFlags):Node {
		final data = new RegularExpressionLiteral();
		data.Text = text;
		data.TokenFlags = tokenFlags & TokenFlagsRegularExpressionLiteralFlags;
		this.textCount++;
		return this.newNode(KindRegularExpressionLiteral, data);
	}

	public function NewNoSubstitutionTemplateLiteral(text:String, templateFlags:TokenFlags):Node {
		final data = new NoSubstitutionTemplateLiteral();
		data.Text = text;
		data.TemplateFlags = templateFlags & TokenFlagsTemplateLiteralLikeFlags;
		this.textCount++;
		return this.newNode(KindNoSubstitutionTemplateLiteral, data);
	}

	public function NewBinaryExpression(modifiers:ModifierList, left:Expression, typeNode:TypeNode, operatorToken:BinaryOperatorToken, right:Expression):Node {
		final data = new BinaryExpression();
		data.modifiers = modifiers;
		data.Left = left;
		data.Type = typeNode;
		data.OperatorToken = operatorToken;
		data.Right = right;
		return this.newNode(KindBinaryExpression, data);
	}

	public function UpdateBinaryExpression(node:BinaryExpression, modifiers:ModifierList, left:Expression, typeNode:TypeNode, operatorToken:BinaryOperatorToken, right:Expression):Node {
		if (modifiers != node.modifiers || left != node.Left || typeNode != node.Type || operatorToken != node.OperatorToken || right != node.Right) {
			return Ast.updateNode(this.NewBinaryExpression(modifiers, left, typeNode, operatorToken, right), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPrefixUnaryExpression(operator_:Kind, operand:Expression):Node {
		final data = new PrefixUnaryExpression();
		data.Operator = operator_;
		data.Operand = operand;
		return this.newNode(KindPrefixUnaryExpression, data);
	}

	public function UpdatePrefixUnaryExpression(node:PrefixUnaryExpression, operator_:Kind, operand:Expression):Node {
		if (operator_ != node.Operator || operand != node.Operand) {
			return Ast.updateNode(this.NewPrefixUnaryExpression(operator_, operand), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPostfixUnaryExpression(operand:Expression, operator_:Kind):Node {
		final data = new PostfixUnaryExpression();
		data.Operand = operand;
		data.Operator = operator_;
		return this.newNode(KindPostfixUnaryExpression, data);
	}

	public function UpdatePostfixUnaryExpression(node:PostfixUnaryExpression, operand:Expression, operator_:Kind):Node {
		if (operand != node.Operand || operator_ != node.Operator) {
			return Ast.updateNode(this.NewPostfixUnaryExpression(operand, operator_), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewYieldExpression(asteriskToken:AsteriskToken, expression:Expression):Node {
		final data = new YieldExpression();
		data.AsteriskToken = asteriskToken;
		data.Expression = expression;
		return this.newNode(KindYieldExpression, data);
	}

	public function UpdateYieldExpression(node:YieldExpression, asteriskToken:AsteriskToken, expression:Expression):Node {
		if (asteriskToken != node.AsteriskToken || expression != node.Expression) {
			return Ast.updateNode(this.NewYieldExpression(asteriskToken, expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewArrowFunction(modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, equalsGreaterThanToken:EqualsGreaterThanToken, body:ConciseBody):Node {
		final data = new ArrowFunction();
		data.modifiers = modifiers;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.EqualsGreaterThanToken = equalsGreaterThanToken;
		data.Body = body;
		return this.newNode(KindArrowFunction, data);
	}

	public function UpdateArrowFunction(node:ArrowFunction, modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, equalsGreaterThanToken:EqualsGreaterThanToken, body:ConciseBody):Node {
		if (modifiers != node.modifiers || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || equalsGreaterThanToken != node.EqualsGreaterThanToken || body != node.Body) {
			return Ast.updateNode(this.NewArrowFunction(modifiers, typeParameters, parameters, typeNode, fullSignature, equalsGreaterThanToken, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewFunctionExpression(modifiers:ModifierList, asteriskToken:AsteriskToken, name:IdentifierNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		final data = new FunctionExpression();
		data.modifiers = modifiers;
		data.AsteriskToken = asteriskToken;
		data.name = name;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		data.FullSignature = fullSignature;
		data.Body = body;
		return this.newNode(KindFunctionExpression, data);
	}

	public function UpdateFunctionExpression(node:FunctionExpression, modifiers:ModifierList, asteriskToken:AsteriskToken, name:IdentifierNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode, fullSignature:TypeNode, body:FunctionBody):Node {
		if (modifiers != node.modifiers || asteriskToken != node.AsteriskToken || name != node.name || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type || fullSignature != node.FullSignature || body != node.Body) {
			return Ast.updateNode(this.NewFunctionExpression(modifiers, asteriskToken, name, typeParameters, parameters, typeNode, fullSignature, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewAsExpression(expression:Expression, typeNode:TypeNode):Node {
		final data = new AsExpression();
		data.Expression = expression;
		data.Type = typeNode;
		return this.newNode(KindAsExpression, data);
	}

	public function UpdateAsExpression(node:AsExpression, expression:Expression, typeNode:TypeNode):Node {
		if (expression != node.Expression || typeNode != node.Type) {
			return Ast.updateNode(this.NewAsExpression(expression, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSatisfiesExpression(expression:Expression, typeNode:TypeNode):Node {
		final data = new SatisfiesExpression();
		data.Expression = expression;
		data.Type = typeNode;
		return this.newNode(KindSatisfiesExpression, data);
	}

	public function UpdateSatisfiesExpression(node:SatisfiesExpression, expression:Expression, typeNode:TypeNode):Node {
		if (expression != node.Expression || typeNode != node.Type) {
			return Ast.updateNode(this.NewSatisfiesExpression(expression, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewConditionalExpression(condition:Expression, questionToken:QuestionToken, whenTrue:Expression, colonToken:ColonToken, whenFalse:Expression):Node {
		final data = new ConditionalExpression();
		data.Condition = condition;
		data.QuestionToken = questionToken;
		data.WhenTrue = whenTrue;
		data.ColonToken = colonToken;
		data.WhenFalse = whenFalse;
		return this.newNode(KindConditionalExpression, data);
	}

	public function UpdateConditionalExpression(node:ConditionalExpression, condition:Expression, questionToken:QuestionToken, whenTrue:Expression, colonToken:ColonToken, whenFalse:Expression):Node {
		if (condition != node.Condition || questionToken != node.QuestionToken || whenTrue != node.WhenTrue || colonToken != node.ColonToken || whenFalse != node.WhenFalse) {
			return Ast.updateNode(this.NewConditionalExpression(condition, questionToken, whenTrue, colonToken, whenFalse), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPropertyAccessExpression(expression:Expression, questionDotToken:QuestionDotToken, name:MemberName, flags:NodeFlags):Node {
		final data = new PropertyAccessExpression();
		data.Expression = expression;
		data.QuestionDotToken = questionDotToken;
		data.name = name;
		final node = this.newNode(KindPropertyAccessExpression, data);
		node.Flags |= flags & NodeFlagsOptionalChain;
		return node;
	}

	public function UpdatePropertyAccessExpression(node:PropertyAccessExpression, expression:Expression, questionDotToken:QuestionDotToken, name:MemberName, flags:NodeFlags):Node {
		if (expression != node.Expression || questionDotToken != node.QuestionDotToken || name != node.name || flags != node.Flags) {
			return Ast.updateNode(this.NewPropertyAccessExpression(expression, questionDotToken, name, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewElementAccessExpression(expression:Expression, questionDotToken:QuestionDotToken, argumentExpression:Expression, flags:NodeFlags):Node {
		final data = new ElementAccessExpression();
		data.Expression = expression;
		data.QuestionDotToken = questionDotToken;
		data.ArgumentExpression = argumentExpression;
		final node = this.newNode(KindElementAccessExpression, data);
		node.Flags |= flags & NodeFlagsOptionalChain;
		return node;
	}

	public function UpdateElementAccessExpression(node:ElementAccessExpression, expression:Expression, questionDotToken:QuestionDotToken, argumentExpression:Expression, flags:NodeFlags):Node {
		if (expression != node.Expression || questionDotToken != node.QuestionDotToken || argumentExpression != node.ArgumentExpression || flags != node.Flags) {
			return Ast.updateNode(this.NewElementAccessExpression(expression, questionDotToken, argumentExpression, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewCallExpression(expression:Expression, questionDotToken:QuestionDotToken, typeArguments:TypeList, arguments:ElementList, flags:NodeFlags):Node {
		final data = new CallExpression();
		data.Expression = expression;
		data.QuestionDotToken = questionDotToken;
		data.TypeArguments = typeArguments;
		data.Arguments = arguments;
		final node = this.newNode(KindCallExpression, data);
		node.Flags |= flags & NodeFlagsOptionalChain;
		return node;
	}

	public function UpdateCallExpression(node:CallExpression, expression:Expression, questionDotToken:QuestionDotToken, typeArguments:TypeList, arguments:ElementList, flags:NodeFlags):Node {
		if (expression != node.Expression || questionDotToken != node.QuestionDotToken || typeArguments != node.TypeArguments || arguments != node.Arguments || flags != node.Flags) {
			return Ast.updateNode(this.NewCallExpression(expression, questionDotToken, typeArguments, arguments, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNewExpression(expression:Expression, typeArguments:TypeList, arguments:ElementList):Node {
		final data = new NewExpression();
		data.Expression = expression;
		data.TypeArguments = typeArguments;
		data.Arguments = arguments;
		return this.newNode(KindNewExpression, data);
	}

	public function UpdateNewExpression(node:NewExpression, expression:Expression, typeArguments:TypeList, arguments:ElementList):Node {
		if (expression != node.Expression || typeArguments != node.TypeArguments || arguments != node.Arguments) {
			return Ast.updateNode(this.NewNewExpression(expression, typeArguments, arguments), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewMetaProperty(keywordToken:Kind, name:IdentifierNode):Node {
		final data = new MetaProperty();
		data.KeywordToken = keywordToken;
		data.name = name;
		return this.newNode(KindMetaProperty, data);
	}

	public function UpdateMetaProperty(node:MetaProperty, keywordToken:Kind, name:IdentifierNode):Node {
		if (keywordToken != node.KeywordToken || name != node.name) {
			return Ast.updateNode(this.NewMetaProperty(keywordToken, name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNonNullExpression(expression:Expression, flags:NodeFlags):Node {
		final data = new NonNullExpression();
		data.Expression = expression;
		final node = this.newNode(KindNonNullExpression, data);
		node.Flags |= flags & NodeFlagsOptionalChain;
		return node;
	}

	public function UpdateNonNullExpression(node:NonNullExpression, expression:Expression, flags:NodeFlags):Node {
		if (expression != node.Expression || flags != node.Flags) {
			return Ast.updateNode(this.NewNonNullExpression(expression, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSpreadElement(expression:Expression):Node {
		final data = new SpreadElement();
		data.Expression = expression;
		return this.newNode(KindSpreadElement, data);
	}

	public function UpdateSpreadElement(node:SpreadElement, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewSpreadElement(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTemplateExpression(head:TemplateHeadNode, templateSpans:TemplateSpanList):Node {
		final data = new TemplateExpression();
		data.Head = head;
		data.TemplateSpans = templateSpans;
		return this.newNode(KindTemplateExpression, data);
	}

	public function UpdateTemplateExpression(node:TemplateExpression, head:TemplateHeadNode, templateSpans:TemplateSpanList):Node {
		if (head != node.Head || templateSpans != node.TemplateSpans) {
			return Ast.updateNode(this.NewTemplateExpression(head, templateSpans), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTemplateSpan(expression:Expression, literal:TemplateMiddleOrTail):Node {
		final data = new TemplateSpan();
		data.Expression = expression;
		data.Literal = literal;
		return this.newNode(KindTemplateSpan, data);
	}

	public function UpdateTemplateSpan(node:TemplateSpan, expression:Expression, literal:TemplateMiddleOrTail):Node {
		if (expression != node.Expression || literal != node.Literal) {
			return Ast.updateNode(this.NewTemplateSpan(expression, literal), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTaggedTemplateExpression(tag:Expression, questionDotToken:QuestionDotToken, typeArguments:TypeList, template:TemplateLiteral, flags:NodeFlags):Node {
		final data = new TaggedTemplateExpression();
		data.Tag = tag;
		data.QuestionDotToken = questionDotToken;
		data.TypeArguments = typeArguments;
		data.Template = template;
		final node = this.newNode(KindTaggedTemplateExpression, data);
		node.Flags |= flags & NodeFlagsOptionalChain;
		return node;
	}

	public function UpdateTaggedTemplateExpression(node:TaggedTemplateExpression, tag:Expression, questionDotToken:QuestionDotToken, typeArguments:TypeList, template:TemplateLiteral, flags:NodeFlags):Node {
		if (tag != node.Tag || questionDotToken != node.QuestionDotToken || typeArguments != node.TypeArguments || template != node.Template || flags != node.Flags) {
			return Ast.updateNode(this.NewTaggedTemplateExpression(tag, questionDotToken, typeArguments, template, flags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewParenthesizedExpression(expression:Expression):Node {
		final data = new ParenthesizedExpression();
		data.Expression = expression;
		return this.newNode(KindParenthesizedExpression, data);
	}

	public function UpdateParenthesizedExpression(node:ParenthesizedExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewParenthesizedExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewArrayLiteralExpression(elements:ElementList, multiLine:Bool):Node {
		final data = new ArrayLiteralExpression();
		data.Elements = elements;
		data.MultiLine = multiLine;
		return this.newNode(KindArrayLiteralExpression, data);
	}

	public function UpdateArrayLiteralExpression(node:ArrayLiteralExpression, elements:ElementList, multiLine:Bool):Node {
		if (elements != node.Elements || multiLine != node.MultiLine) {
			return Ast.updateNode(this.NewArrayLiteralExpression(elements, multiLine), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewObjectLiteralExpression(properties:NodeList, multiLine:Bool):Node {
		final data = new ObjectLiteralExpression();
		data.Properties = properties;
		data.MultiLine = multiLine;
		return this.newNode(KindObjectLiteralExpression, data);
	}

	public function UpdateObjectLiteralExpression(node:ObjectLiteralExpression, properties:NodeList, multiLine:Bool):Node {
		if (properties != node.Properties || multiLine != node.MultiLine) {
			return Ast.updateNode(this.NewObjectLiteralExpression(properties, multiLine), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSpreadAssignment(expression:Expression):Node {
		final data = new SpreadAssignment();
		data.Expression = expression;
		return this.newNode(KindSpreadAssignment, data);
	}

	public function UpdateSpreadAssignment(node:SpreadAssignment, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewSpreadAssignment(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPropertyAssignment(modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		final data = new PropertyAssignment();
		data.modifiers = modifiers;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.Type = typeNode;
		data.Initializer = initializer;
		return this.newNode(KindPropertyAssignment, data);
	}

	public function UpdatePropertyAssignment(node:PropertyAssignment, modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, initializer:Expression):Node {
		if (modifiers != node.modifiers || name != node.name || postfixToken != node.PostfixToken || typeNode != node.Type || initializer != node.Initializer) {
			return Ast.updateNode(this.NewPropertyAssignment(modifiers, name, postfixToken, typeNode, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewShorthandPropertyAssignment(modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, equalsToken:EqualsToken, objectAssignmentInitializer:Expression):Node {
		final data = new ShorthandPropertyAssignment();
		data.modifiers = modifiers;
		data.name = name;
		data.PostfixToken = postfixToken;
		data.Type = typeNode;
		data.EqualsToken = equalsToken;
		data.ObjectAssignmentInitializer = objectAssignmentInitializer;
		return this.newNode(KindShorthandPropertyAssignment, data);
	}

	public function UpdateShorthandPropertyAssignment(node:ShorthandPropertyAssignment, modifiers:ModifierList, name:PropertyName, postfixToken:TokenNode, typeNode:TypeNode, equalsToken:EqualsToken, objectAssignmentInitializer:Expression):Node {
		if (modifiers != node.modifiers || name != node.name || postfixToken != node.PostfixToken || typeNode != node.Type || equalsToken != node.EqualsToken || objectAssignmentInitializer != node.ObjectAssignmentInitializer) {
			return Ast.updateNode(this.NewShorthandPropertyAssignment(modifiers, name, postfixToken, typeNode, equalsToken, objectAssignmentInitializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewDeleteExpression(expression:Expression):Node {
		final data = new DeleteExpression();
		data.Expression = expression;
		return this.newNode(KindDeleteExpression, data);
	}

	public function UpdateDeleteExpression(node:DeleteExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewDeleteExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeOfExpression(expression:Expression):Node {
		final data = new TypeOfExpression();
		data.Expression = expression;
		return this.newNode(KindTypeOfExpression, data);
	}

	public function UpdateTypeOfExpression(node:TypeOfExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewTypeOfExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewVoidExpression(expression:Expression):Node {
		final data = new VoidExpression();
		data.Expression = expression;
		return this.newNode(KindVoidExpression, data);
	}

	public function UpdateVoidExpression(node:VoidExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewVoidExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewAwaitExpression(expression:Expression):Node {
		final data = new AwaitExpression();
		data.Expression = expression;
		return this.newNode(KindAwaitExpression, data);
	}

	public function UpdateAwaitExpression(node:AwaitExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewAwaitExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeAssertion(typeNode:TypeNode, expression:Expression):Node {
		final data = new TypeAssertion();
		data.Type = typeNode;
		data.Expression = expression;
		return this.newNode(KindTypeAssertionExpression, data);
	}

	public function UpdateTypeAssertion(node:TypeAssertion, typeNode:TypeNode, expression:Expression):Node {
		if (typeNode != node.Type || expression != node.Expression) {
			return Ast.updateNode(this.NewTypeAssertion(typeNode, expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewKeywordTypeNode(kind:KeywordTypeSyntaxKind):Node {
		final data = new KeywordTypeNode();
		return this.newNode(kind, data);
	}

	public function NewUnionTypeNode(types:TypeList):Node {
		final data = new UnionTypeNode();
		data.Types = types;
		return this.newNode(KindUnionType, data);
	}

	public function UpdateUnionTypeNode(node:UnionTypeNode, types:TypeList):Node {
		if (types != node.Types) {
			return Ast.updateNode(this.NewUnionTypeNode(types), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewIntersectionTypeNode(types:TypeList):Node {
		final data = new IntersectionTypeNode();
		data.Types = types;
		return this.newNode(KindIntersectionType, data);
	}

	public function UpdateIntersectionTypeNode(node:IntersectionTypeNode, types:TypeList):Node {
		if (types != node.Types) {
			return Ast.updateNode(this.NewIntersectionTypeNode(types), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewConditionalTypeNode(checkType:TypeNode, extendsType:TypeNode, trueType:TypeNode, falseType:TypeNode):Node {
		final data = new ConditionalTypeNode();
		data.CheckType = checkType;
		data.ExtendsType = extendsType;
		data.TrueType = trueType;
		data.FalseType = falseType;
		return this.newNode(KindConditionalType, data);
	}

	public function UpdateConditionalTypeNode(node:ConditionalTypeNode, checkType:TypeNode, extendsType:TypeNode, trueType:TypeNode, falseType:TypeNode):Node {
		if (checkType != node.CheckType || extendsType != node.ExtendsType || trueType != node.TrueType || falseType != node.FalseType) {
			return Ast.updateNode(this.NewConditionalTypeNode(checkType, extendsType, trueType, falseType), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeOperatorNode(operator_:Kind, typeNode:TypeNode):Node {
		final data = new TypeOperatorNode();
		data.Operator = operator_;
		data.Type = typeNode;
		return this.newNode(KindTypeOperator, data);
	}

	public function UpdateTypeOperatorNode(node:TypeOperatorNode, operator_:Kind, typeNode:TypeNode):Node {
		if (operator_ != node.Operator || typeNode != node.Type) {
			return Ast.updateNode(this.NewTypeOperatorNode(operator_, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewInferTypeNode(typeParameter:TypeParameterDeclarationNode):Node {
		final data = new InferTypeNode();
		data.TypeParameter = typeParameter;
		return this.newNode(KindInferType, data);
	}

	public function UpdateInferTypeNode(node:InferTypeNode, typeParameter:TypeParameterDeclarationNode):Node {
		if (typeParameter != node.TypeParameter) {
			return Ast.updateNode(this.NewInferTypeNode(typeParameter), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewArrayTypeNode(elementType:TypeNode):Node {
		final data = new ArrayTypeNode();
		data.ElementType = elementType;
		return this.newNode(KindArrayType, data);
	}

	public function UpdateArrayTypeNode(node:ArrayTypeNode, elementType:TypeNode):Node {
		if (elementType != node.ElementType) {
			return Ast.updateNode(this.NewArrayTypeNode(elementType), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewIndexedAccessTypeNode(objectType:TypeNode, indexType:TypeNode):Node {
		final data = new IndexedAccessTypeNode();
		data.ObjectType = objectType;
		data.IndexType = indexType;
		return this.newNode(KindIndexedAccessType, data);
	}

	public function UpdateIndexedAccessTypeNode(node:IndexedAccessTypeNode, objectType:TypeNode, indexType:TypeNode):Node {
		if (objectType != node.ObjectType || indexType != node.IndexType) {
			return Ast.updateNode(this.NewIndexedAccessTypeNode(objectType, indexType), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeReferenceNode(typeName:EntityName, typeArguments:TypeList):Node {
		final data = new TypeReferenceNode();
		data.TypeName = typeName;
		data.TypeArguments = typeArguments;
		return this.newNode(KindTypeReference, data);
	}

	public function UpdateTypeReferenceNode(node:TypeReferenceNode, typeName:EntityName, typeArguments:TypeList):Node {
		if (typeName != node.TypeName || typeArguments != node.TypeArguments) {
			return Ast.updateNode(this.NewTypeReferenceNode(typeName, typeArguments), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewExpressionWithTypeArguments(expression:Expression, typeArguments:TypeList):Node {
		final data = new ExpressionWithTypeArguments();
		data.Expression = expression;
		data.TypeArguments = typeArguments;
		return this.newNode(KindExpressionWithTypeArguments, data);
	}

	public function UpdateExpressionWithTypeArguments(node:ExpressionWithTypeArguments, expression:Expression, typeArguments:TypeList):Node {
		if (expression != node.Expression || typeArguments != node.TypeArguments) {
			return Ast.updateNode(this.NewExpressionWithTypeArguments(expression, typeArguments), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewLiteralTypeNode(literal:Node):Node {
		final data = new LiteralTypeNode();
		data.Literal = literal;
		return this.newNode(KindLiteralType, data);
	}

	public function UpdateLiteralTypeNode(node:LiteralTypeNode, literal:Node):Node {
		if (literal != node.Literal) {
			return Ast.updateNode(this.NewLiteralTypeNode(literal), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewThisTypeNode():Node {
		final data = new ThisTypeNode();
		return this.newNode(KindThisType, data);
	}

	public function NewTypePredicateNode(assertsModifier:AssertsKeyword, parameterName:TypePredicateParameterName, typeNode:TypeNode):Node {
		final data = new TypePredicateNode();
		data.AssertsModifier = assertsModifier;
		data.ParameterName = parameterName;
		data.Type = typeNode;
		return this.newNode(KindTypePredicate, data);
	}

	public function UpdateTypePredicateNode(node:TypePredicateNode, assertsModifier:AssertsKeyword, parameterName:TypePredicateParameterName, typeNode:TypeNode):Node {
		if (assertsModifier != node.AssertsModifier || parameterName != node.ParameterName || typeNode != node.Type) {
			return Ast.updateNode(this.NewTypePredicateNode(assertsModifier, parameterName, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportAttribute(name:ImportAttributeName, value:Expression):Node {
		final data = new ImportAttribute();
		data.name = name;
		data.Value = value;
		return this.newNode(KindImportAttribute, data);
	}

	public function UpdateImportAttribute(node:ImportAttribute, name:ImportAttributeName, value:Expression):Node {
		if (name != node.name || value != node.Value) {
			return Ast.updateNode(this.NewImportAttribute(name, value), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportAttributes(token:Kind, attributes:ImportAttributeList, multiLine:Bool):Node {
		final data = new ImportAttributes();
		data.Token = token;
		data.Attributes = attributes;
		data.MultiLine = multiLine;
		return this.newNode(KindImportAttributes, data);
	}

	public function UpdateImportAttributes(node:ImportAttributes, token:Kind, attributes:ImportAttributeList, multiLine:Bool):Node {
		if (token != node.Token || attributes != node.Attributes || multiLine != node.MultiLine) {
			return Ast.updateNode(this.NewImportAttributes(token, attributes, multiLine), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeQueryNode(exprName:EntityName, typeArguments:TypeList):Node {
		final data = new TypeQueryNode();
		data.ExprName = exprName;
		data.TypeArguments = typeArguments;
		return this.newNode(KindTypeQuery, data);
	}

	public function UpdateTypeQueryNode(node:TypeQueryNode, exprName:EntityName, typeArguments:TypeList):Node {
		if (exprName != node.ExprName || typeArguments != node.TypeArguments) {
			return Ast.updateNode(this.NewTypeQueryNode(exprName, typeArguments), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewMappedTypeNode(readonlyToken:TokenNode, typeParameter:TypeParameterDeclarationNode, nameType:TypeNode, questionToken:TokenNode, typeNode:TypeNode, members:TypeElementList):Node {
		final data = new MappedTypeNode();
		data.ReadonlyToken = readonlyToken;
		data.TypeParameter = typeParameter;
		data.NameType = nameType;
		data.QuestionToken = questionToken;
		data.Type = typeNode;
		data.Members = members;
		return this.newNode(KindMappedType, data);
	}

	public function UpdateMappedTypeNode(node:MappedTypeNode, readonlyToken:TokenNode, typeParameter:TypeParameterDeclarationNode, nameType:TypeNode, questionToken:TokenNode, typeNode:TypeNode, members:TypeElementList):Node {
		if (readonlyToken != node.ReadonlyToken || typeParameter != node.TypeParameter || nameType != node.NameType || questionToken != node.QuestionToken || typeNode != node.Type || members != node.Members) {
			return Ast.updateNode(this.NewMappedTypeNode(readonlyToken, typeParameter, nameType, questionToken, typeNode, members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeLiteralNode(members:TypeElementList):Node {
		final data = new TypeLiteralNode();
		data.Members = members;
		return this.newNode(KindTypeLiteral, data);
	}

	public function UpdateTypeLiteralNode(node:TypeLiteralNode, members:TypeElementList):Node {
		if (members != node.Members) {
			return Ast.updateNode(this.NewTypeLiteralNode(members), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTupleTypeNode(elements:TypeList):Node {
		final data = new TupleTypeNode();
		data.Elements = elements;
		return this.newNode(KindTupleType, data);
	}

	public function UpdateTupleTypeNode(node:TupleTypeNode, elements:TypeList):Node {
		if (elements != node.Elements) {
			return Ast.updateNode(this.NewTupleTypeNode(elements), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewNamedTupleMember(dotDotDotToken:DotDotDotToken, name:IdentifierNode, questionToken:QuestionToken, typeNode:TypeNode):Node {
		final data = new NamedTupleMember();
		data.DotDotDotToken = dotDotDotToken;
		data.name = name;
		data.QuestionToken = questionToken;
		data.Type = typeNode;
		return this.newNode(KindNamedTupleMember, data);
	}

	public function UpdateNamedTupleMember(node:NamedTupleMember, dotDotDotToken:DotDotDotToken, name:IdentifierNode, questionToken:QuestionToken, typeNode:TypeNode):Node {
		if (dotDotDotToken != node.DotDotDotToken || name != node.name || questionToken != node.QuestionToken || typeNode != node.Type) {
			return Ast.updateNode(this.NewNamedTupleMember(dotDotDotToken, name, questionToken, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewOptionalTypeNode(typeNode:TypeNode):Node {
		final data = new OptionalTypeNode();
		data.Type = typeNode;
		return this.newNode(KindOptionalType, data);
	}

	public function UpdateOptionalTypeNode(node:OptionalTypeNode, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewOptionalTypeNode(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewRestTypeNode(typeNode:TypeNode):Node {
		final data = new RestTypeNode();
		data.Type = typeNode;
		return this.newNode(KindRestType, data);
	}

	public function UpdateRestTypeNode(node:RestTypeNode, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewRestTypeNode(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewParenthesizedTypeNode(typeNode:TypeNode):Node {
		final data = new ParenthesizedTypeNode();
		data.Type = typeNode;
		return this.newNode(KindParenthesizedType, data);
	}

	public function UpdateParenthesizedTypeNode(node:ParenthesizedTypeNode, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewParenthesizedTypeNode(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewFunctionTypeNode(typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new FunctionTypeNode();
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindFunctionType, data);
	}

	public function UpdateFunctionTypeNode(node:FunctionTypeNode, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewFunctionTypeNode(typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewConstructorTypeNode(modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new ConstructorTypeNode();
		data.modifiers = modifiers;
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindConstructorType, data);
	}

	public function UpdateConstructorTypeNode(node:ConstructorTypeNode, modifiers:ModifierList, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (modifiers != node.modifiers || typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewConstructorTypeNode(modifiers, typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTemplateHead(text:String, rawText:String, templateFlags:TokenFlags):Node {
		final data = new TemplateHead();
		data.Text = text;
		data.RawText = rawText;
		data.TemplateFlags = templateFlags & TokenFlagsTemplateLiteralLikeFlags;
		this.textCount++;
		return this.newNode(KindTemplateHead, data);
	}

	public function NewTemplateMiddle(text:String, rawText:String, templateFlags:TokenFlags):Node {
		final data = new TemplateMiddle();
		data.Text = text;
		data.RawText = rawText;
		data.TemplateFlags = templateFlags & TokenFlagsTemplateLiteralLikeFlags;
		this.textCount++;
		return this.newNode(KindTemplateMiddle, data);
	}

	public function NewTemplateTail(text:String, rawText:String, templateFlags:TokenFlags):Node {
		final data = new TemplateTail();
		data.Text = text;
		data.RawText = rawText;
		data.TemplateFlags = templateFlags & TokenFlagsTemplateLiteralLikeFlags;
		this.textCount++;
		return this.newNode(KindTemplateTail, data);
	}

	public function NewTemplateLiteralTypeNode(head:TemplateHeadNode, templateSpans:TemplateLiteralTypeSpanList):Node {
		final data = new TemplateLiteralTypeNode();
		data.Head = head;
		data.TemplateSpans = templateSpans;
		return this.newNode(KindTemplateLiteralType, data);
	}

	public function UpdateTemplateLiteralTypeNode(node:TemplateLiteralTypeNode, head:TemplateHeadNode, templateSpans:TemplateLiteralTypeSpanList):Node {
		if (head != node.Head || templateSpans != node.TemplateSpans) {
			return Ast.updateNode(this.NewTemplateLiteralTypeNode(head, templateSpans), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTemplateLiteralTypeSpan(typeNode:TypeNode, literal:TemplateMiddleOrTail):Node {
		final data = new TemplateLiteralTypeSpan();
		data.Type = typeNode;
		data.Literal = literal;
		return this.newNode(KindTemplateLiteralTypeSpan, data);
	}

	public function UpdateTemplateLiteralTypeSpan(node:TemplateLiteralTypeSpan, typeNode:TypeNode, literal:TemplateMiddleOrTail):Node {
		if (typeNode != node.Type || literal != node.Literal) {
			return Ast.updateNode(this.NewTemplateLiteralTypeSpan(typeNode, literal), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSyntheticExpression(typeNode:Any, isSpread:Bool, tupleNameSource:Node):Node {
		final data = new SyntheticExpression();
		data.Type = typeNode;
		data.IsSpread = isSpread;
		data.TupleNameSource = tupleNameSource;
		return this.newNode(KindSyntheticExpression, data);
	}

	public function UpdateSyntheticExpression(node:SyntheticExpression, typeNode:Any, isSpread:Bool, tupleNameSource:Node):Node {
		if (typeNode != node.Type || isSpread != node.IsSpread || tupleNameSource != node.TupleNameSource) {
			return Ast.updateNode(this.NewSyntheticExpression(typeNode, isSpread, tupleNameSource), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewPartiallyEmittedExpression(expression:Expression):Node {
		final data = new PartiallyEmittedExpression();
		data.Expression = expression;
		return this.newNode(KindPartiallyEmittedExpression, data);
	}

	public function UpdatePartiallyEmittedExpression(node:PartiallyEmittedExpression, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewPartiallyEmittedExpression(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxElement(openingElement:JsxOpeningElementNode, children:JsxChildList, closingElement:JsxClosingElementNode):Node {
		final data = new JsxElement();
		data.OpeningElement = openingElement;
		data.Children = children;
		data.ClosingElement = closingElement;
		return this.newNode(KindJsxElement, data);
	}

	public function UpdateJsxElement(node:JsxElement, openingElement:JsxOpeningElementNode, children:JsxChildList, closingElement:JsxClosingElementNode):Node {
		if (openingElement != node.OpeningElement || children != node.Children || closingElement != node.ClosingElement) {
			return Ast.updateNode(this.NewJsxElement(openingElement, children, closingElement), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxAttributes(properties:JsxAttributeList):Node {
		final data = new JsxAttributes();
		data.Properties = properties;
		return this.newNode(KindJsxAttributes, data);
	}

	public function UpdateJsxAttributes(node:JsxAttributes, properties:JsxAttributeList):Node {
		if (properties != node.Properties) {
			return Ast.updateNode(this.NewJsxAttributes(properties), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxNamespacedName(namespace:IdentifierNode, name:IdentifierNode):Node {
		final data = new JsxNamespacedName();
		data.Namespace = namespace;
		data.name = name;
		return this.newNode(KindJsxNamespacedName, data);
	}

	public function UpdateJsxNamespacedName(node:JsxNamespacedName, namespace:IdentifierNode, name:IdentifierNode):Node {
		if (namespace != node.Namespace || name != node.name) {
			return Ast.updateNode(this.NewJsxNamespacedName(namespace, name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxOpeningElement(tagName:JsxTagNameExpression, typeArguments:TypeList, attributes:JsxAttributesNode):Node {
		final data = new JsxOpeningElement();
		data.TagName = tagName;
		data.TypeArguments = typeArguments;
		data.Attributes = attributes;
		return this.newNode(KindJsxOpeningElement, data);
	}

	public function UpdateJsxOpeningElement(node:JsxOpeningElement, tagName:JsxTagNameExpression, typeArguments:TypeList, attributes:JsxAttributesNode):Node {
		if (tagName != node.TagName || typeArguments != node.TypeArguments || attributes != node.Attributes) {
			return Ast.updateNode(this.NewJsxOpeningElement(tagName, typeArguments, attributes), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxSelfClosingElement(tagName:JsxTagNameExpression, typeArguments:TypeList, attributes:JsxAttributesNode):Node {
		final data = new JsxSelfClosingElement();
		data.TagName = tagName;
		data.TypeArguments = typeArguments;
		data.Attributes = attributes;
		return this.newNode(KindJsxSelfClosingElement, data);
	}

	public function UpdateJsxSelfClosingElement(node:JsxSelfClosingElement, tagName:JsxTagNameExpression, typeArguments:TypeList, attributes:JsxAttributesNode):Node {
		if (tagName != node.TagName || typeArguments != node.TypeArguments || attributes != node.Attributes) {
			return Ast.updateNode(this.NewJsxSelfClosingElement(tagName, typeArguments, attributes), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxFragment(openingFragment:JsxOpeningFragmentNode, children:JsxChildList, closingFragment:JsxClosingFragmentNode):Node {
		final data = new JsxFragment();
		data.OpeningFragment = openingFragment;
		data.Children = children;
		data.ClosingFragment = closingFragment;
		return this.newNode(KindJsxFragment, data);
	}

	public function UpdateJsxFragment(node:JsxFragment, openingFragment:JsxOpeningFragmentNode, children:JsxChildList, closingFragment:JsxClosingFragmentNode):Node {
		if (openingFragment != node.OpeningFragment || children != node.Children || closingFragment != node.ClosingFragment) {
			return Ast.updateNode(this.NewJsxFragment(openingFragment, children, closingFragment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxOpeningFragment():Node {
		final data = new JsxOpeningFragment();
		return this.newNode(KindJsxOpeningFragment, data);
	}

	public function NewJsxClosingFragment():Node {
		final data = new JsxClosingFragment();
		return this.newNode(KindJsxClosingFragment, data);
	}

	public function NewJsxAttribute(name:JsxAttributeName, initializer:JsxAttributeValue):Node {
		final data = new JsxAttribute();
		data.name = name;
		data.Initializer = initializer;
		return this.newNode(KindJsxAttribute, data);
	}

	public function UpdateJsxAttribute(node:JsxAttribute, name:JsxAttributeName, initializer:JsxAttributeValue):Node {
		if (name != node.name || initializer != node.Initializer) {
			return Ast.updateNode(this.NewJsxAttribute(name, initializer), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxSpreadAttribute(expression:Expression):Node {
		final data = new JsxSpreadAttribute();
		data.Expression = expression;
		return this.newNode(KindJsxSpreadAttribute, data);
	}

	public function UpdateJsxSpreadAttribute(node:JsxSpreadAttribute, expression:Expression):Node {
		if (expression != node.Expression) {
			return Ast.updateNode(this.NewJsxSpreadAttribute(expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxClosingElement(tagName:JsxTagNameExpression):Node {
		final data = new JsxClosingElement();
		data.TagName = tagName;
		return this.newNode(KindJsxClosingElement, data);
	}

	public function UpdateJsxClosingElement(node:JsxClosingElement, tagName:JsxTagNameExpression):Node {
		if (tagName != node.TagName) {
			return Ast.updateNode(this.NewJsxClosingElement(tagName), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxExpression(dotDotDotToken:DotDotDotToken, expression:Expression):Node {
		final data = new JsxExpression();
		data.DotDotDotToken = dotDotDotToken;
		data.Expression = expression;
		return this.newNode(KindJsxExpression, data);
	}

	public function UpdateJsxExpression(node:JsxExpression, dotDotDotToken:DotDotDotToken, expression:Expression):Node {
		if (dotDotDotToken != node.DotDotDotToken || expression != node.Expression) {
			return Ast.updateNode(this.NewJsxExpression(dotDotDotToken, expression), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJsxText(text:String, containsOnlyTriviaWhiteSpaces:Bool):Node {
		final data = new JsxText();
		data.Text = text;
		data.ContainsOnlyTriviaWhiteSpaces = containsOnlyTriviaWhiteSpaces;
		this.textCount++;
		return this.newNode(KindJsxText, data);
	}

	public function NewSyntaxList(children:Array<Node>):Node {
		final data = new SyntaxList();
		data.Children = children;
		return this.newNode(KindSyntaxList, data);
	}

	public function UpdateSyntaxList(node:SyntaxList, children:Array<Node>):Node {
		if (!Core.Same(children, node.Children)) {
			return Ast.updateNode(this.NewSyntaxList(children), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDoc(comment:NodeList, tags:NodeList):Node {
		final data = new JSDoc();
		data.Comment = comment;
		data.Tags = tags;
		return this.newNode(KindJSDoc, data);
	}

	public function UpdateJSDoc(node:JSDoc, comment:NodeList, tags:NodeList):Node {
		if (comment != node.Comment || tags != node.Tags) {
			return Ast.updateNode(this.NewJSDoc(comment, tags), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocTypeExpression(typeNode:TypeNode):Node {
		final data = new JSDocTypeExpression();
		data.Type = typeNode;
		return this.newNode(KindJSDocTypeExpression, data);
	}

	public function UpdateJSDocTypeExpression(node:JSDocTypeExpression, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocTypeExpression(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocNonNullableType(typeNode:TypeNode):Node {
		final data = new JSDocNonNullableType();
		data.Type = typeNode;
		return this.newNode(KindJSDocNonNullableType, data);
	}

	public function UpdateJSDocNonNullableType(node:JSDocNonNullableType, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocNonNullableType(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocNullableType(typeNode:TypeNode):Node {
		final data = new JSDocNullableType();
		data.Type = typeNode;
		return this.newNode(KindJSDocNullableType, data);
	}

	public function UpdateJSDocNullableType(node:JSDocNullableType, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocNullableType(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocAllType():Node {
		final data = new JSDocAllType();
		return this.newNode(KindJSDocAllType, data);
	}

	public function NewJSDocVariadicType(typeNode:TypeNode):Node {
		final data = new JSDocVariadicType();
		data.Type = typeNode;
		return this.newNode(KindJSDocVariadicType, data);
	}

	public function UpdateJSDocVariadicType(node:JSDocVariadicType, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocVariadicType(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocOptionalType(typeNode:TypeNode):Node {
		final data = new JSDocOptionalType();
		data.Type = typeNode;
		return this.newNode(KindJSDocOptionalType, data);
	}

	public function UpdateJSDocOptionalType(node:JSDocOptionalType, typeNode:TypeNode):Node {
		if (typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocOptionalType(typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocTypeTag(tagName:IdentifierNode, typeExpression:Node, comment:NodeList):Node {
		final data = new JSDocTypeTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocTypeTag, data);
	}

	public function UpdateJSDocTypeTag(node:JSDocTypeTag, tagName:IdentifierNode, typeExpression:Node, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocTypeTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocUnknownTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocUnknownTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocUnknownTag, data);
	}

	public function UpdateJSDocUnknownTag(node:JSDocUnknownTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocUnknownTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocTemplateTag(tagName:IdentifierNode, constraint:Node, typeParameters:TypeParameterList, comment:NodeList):Node {
		final data = new JSDocTemplateTag();
		data.TagName = tagName;
		data.Constraint = constraint;
		data.TypeParameters = typeParameters;
		data.Comment = comment;
		return this.newNode(KindJSDocTemplateTag, data);
	}

	public function UpdateJSDocTemplateTag(node:JSDocTemplateTag, tagName:IdentifierNode, constraint:Node, typeParameters:TypeParameterList, comment:NodeList):Node {
		if (tagName != node.TagName || constraint != node.Constraint || typeParameters != node.TypeParameters || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocTemplateTag(tagName, constraint, typeParameters, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocReturnTag(tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocReturnTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocReturnTag, data);
	}

	public function UpdateJSDocReturnTag(node:JSDocReturnTag, tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocReturnTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocPublicTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocPublicTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocPublicTag, data);
	}

	public function UpdateJSDocPublicTag(node:JSDocPublicTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocPublicTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocPrivateTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocPrivateTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocPrivateTag, data);
	}

	public function UpdateJSDocPrivateTag(node:JSDocPrivateTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocPrivateTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocProtectedTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocProtectedTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocProtectedTag, data);
	}

	public function UpdateJSDocProtectedTag(node:JSDocProtectedTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocProtectedTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocReadonlyTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocReadonlyTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocReadonlyTag, data);
	}

	public function UpdateJSDocReadonlyTag(node:JSDocReadonlyTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocReadonlyTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocOverrideTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocOverrideTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocOverrideTag, data);
	}

	public function UpdateJSDocOverrideTag(node:JSDocOverrideTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocOverrideTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocDeprecatedTag(tagName:IdentifierNode, comment:NodeList):Node {
		final data = new JSDocDeprecatedTag();
		data.TagName = tagName;
		data.Comment = comment;
		return this.newNode(KindJSDocDeprecatedTag, data);
	}

	public function UpdateJSDocDeprecatedTag(node:JSDocDeprecatedTag, tagName:IdentifierNode, comment:NodeList):Node {
		if (tagName != node.TagName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocDeprecatedTag(tagName, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocSeeTag(tagName:IdentifierNode, nameExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocSeeTag();
		data.TagName = tagName;
		data.NameExpression = nameExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocSeeTag, data);
	}

	public function UpdateJSDocSeeTag(node:JSDocSeeTag, tagName:IdentifierNode, nameExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || nameExpression != node.NameExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocSeeTag(tagName, nameExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocImplementsTag(tagName:IdentifierNode, className:ExpressionWithTypeArgumentsNode, comment:NodeList):Node {
		final data = new JSDocImplementsTag();
		data.TagName = tagName;
		data.ClassName = className;
		data.Comment = comment;
		return this.newNode(KindJSDocImplementsTag, data);
	}

	public function UpdateJSDocImplementsTag(node:JSDocImplementsTag, tagName:IdentifierNode, className:ExpressionWithTypeArgumentsNode, comment:NodeList):Node {
		if (tagName != node.TagName || className != node.ClassName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocImplementsTag(tagName, className, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocAugmentsTag(tagName:IdentifierNode, className:ExpressionWithTypeArgumentsNode, comment:NodeList):Node {
		final data = new JSDocAugmentsTag();
		data.TagName = tagName;
		data.ClassName = className;
		data.Comment = comment;
		return this.newNode(KindJSDocAugmentsTag, data);
	}

	public function UpdateJSDocAugmentsTag(node:JSDocAugmentsTag, tagName:IdentifierNode, className:ExpressionWithTypeArgumentsNode, comment:NodeList):Node {
		if (tagName != node.TagName || className != node.ClassName || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocAugmentsTag(tagName, className, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocSatisfiesTag(tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocSatisfiesTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocSatisfiesTag, data);
	}

	public function UpdateJSDocSatisfiesTag(node:JSDocSatisfiesTag, tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocSatisfiesTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocThrowsTag(tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocThrowsTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocThrowsTag, data);
	}

	public function UpdateJSDocThrowsTag(node:JSDocThrowsTag, tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocThrowsTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocThisTag(tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocThisTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocThisTag, data);
	}

	public function UpdateJSDocThisTag(node:JSDocThisTag, tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocThisTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocImportTag(tagName:IdentifierNode, importClause:ImportClauseNode, moduleSpecifier:Expression, attributes:ImportAttributesNode, comment:NodeList):Node {
		final data = new JSDocImportTag();
		data.TagName = tagName;
		data.ImportClause = importClause;
		data.ModuleSpecifier = moduleSpecifier;
		data.Attributes = attributes;
		data.Comment = comment;
		return this.newNode(KindJSDocImportTag, data);
	}

	public function UpdateJSDocImportTag(node:JSDocImportTag, tagName:IdentifierNode, importClause:ImportClauseNode, moduleSpecifier:Expression, attributes:ImportAttributesNode, comment:NodeList):Node {
		if (tagName != node.TagName || importClause != node.ImportClause || moduleSpecifier != node.ModuleSpecifier || attributes != node.Attributes || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocImportTag(tagName, importClause, moduleSpecifier, attributes, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocCallbackTag(tagName:IdentifierNode, typeExpression:TypeNode, name:JSDocFullName, comment:NodeList):Node {
		final data = new JSDocCallbackTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.name = name;
		data.Comment = comment;
		return this.newNode(KindJSDocCallbackTag, data);
	}

	public function UpdateJSDocCallbackTag(node:JSDocCallbackTag, tagName:IdentifierNode, typeExpression:TypeNode, name:JSDocFullName, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || name != node.name || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocCallbackTag(tagName, typeExpression, name, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocOverloadTag(tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		final data = new JSDocOverloadTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.Comment = comment;
		return this.newNode(KindJSDocOverloadTag, data);
	}

	public function UpdateJSDocOverloadTag(node:JSDocOverloadTag, tagName:IdentifierNode, typeExpression:TypeNode, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocOverloadTag(tagName, typeExpression, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocTypedefTag(tagName:IdentifierNode, typeExpression:Node, name:JSDocFullName, comment:NodeList):Node {
		final data = new JSDocTypedefTag();
		data.TagName = tagName;
		data.TypeExpression = typeExpression;
		data.name = name;
		data.Comment = comment;
		return this.newNode(KindJSDocTypedefTag, data);
	}

	public function UpdateJSDocTypedefTag(node:JSDocTypedefTag, tagName:IdentifierNode, typeExpression:Node, name:JSDocFullName, comment:NodeList):Node {
		if (tagName != node.TagName || typeExpression != node.TypeExpression || name != node.name || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocTypedefTag(tagName, typeExpression, name, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocSignature(typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		final data = new JSDocSignature();
		data.TypeParameters = typeParameters;
		data.Parameters = parameters;
		data.Type = typeNode;
		return this.newNode(KindJSDocSignature, data);
	}

	public function UpdateJSDocSignature(node:JSDocSignature, typeParameters:TypeParameterList, parameters:ParameterList, typeNode:TypeNode):Node {
		if (typeParameters != node.TypeParameters || parameters != node.Parameters || typeNode != node.Type) {
			return Ast.updateNode(this.NewJSDocSignature(typeParameters, parameters, typeNode), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocNameReference(name:EntityName):Node {
		final data = new JSDocNameReference();
		data.name = name;
		return this.newNode(KindJSDocNameReference, data);
	}

	public function UpdateJSDocNameReference(node:JSDocNameReference, name:EntityName):Node {
		if (name != node.name) {
			return Ast.updateNode(this.NewJSDocNameReference(name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewModuleDeclaration(modifiers:ModifierList, keyword:Kind, name:ModuleName, body:ModuleBody):Node {
		final data = new ModuleDeclaration();
		data.modifiers = modifiers;
		data.Keyword = keyword;
		data.name = name;
		data.Body = body;
		return this.newNode(KindModuleDeclaration, data);
	}

	public function UpdateModuleDeclaration(node:ModuleDeclaration, modifiers:ModifierList, keyword:Kind, name:ModuleName, body:ModuleBody):Node {
		if (modifiers != node.modifiers || keyword != node.Keyword || name != node.name || body != node.Body) {
			return Ast.updateNode(this.NewModuleDeclaration(modifiers, keyword, name, body), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportEqualsDeclaration(modifiers:ModifierList, isTypeOnly:Bool, name:IdentifierNode, moduleReference:ModuleReference):Node {
		final data = new ImportEqualsDeclaration();
		data.modifiers = modifiers;
		data.IsTypeOnly = isTypeOnly;
		data.name = name;
		data.ModuleReference = moduleReference;
		return this.newNode(KindImportEqualsDeclaration, data);
	}

	public function UpdateImportEqualsDeclaration(node:ImportEqualsDeclaration, modifiers:ModifierList, isTypeOnly:Bool, name:IdentifierNode, moduleReference:ModuleReference):Node {
		if (modifiers != node.modifiers || isTypeOnly != node.IsTypeOnly || name != node.name || moduleReference != node.ModuleReference) {
			return Ast.updateNode(this.NewImportEqualsDeclaration(modifiers, isTypeOnly, name, moduleReference), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewExportDeclaration(modifiers:ModifierList, isTypeOnly:Bool, exportClause:NamedExportBindings, moduleSpecifier:Expression, attributes:ImportAttributesNode):Node {
		final data = new ExportDeclaration();
		data.modifiers = modifiers;
		data.IsTypeOnly = isTypeOnly;
		data.ExportClause = exportClause;
		data.ModuleSpecifier = moduleSpecifier;
		data.Attributes = attributes;
		return this.newNode(KindExportDeclaration, data);
	}

	public function UpdateExportDeclaration(node:ExportDeclaration, modifiers:ModifierList, isTypeOnly:Bool, exportClause:NamedExportBindings, moduleSpecifier:Expression, attributes:ImportAttributesNode):Node {
		if (modifiers != node.modifiers || isTypeOnly != node.IsTypeOnly || exportClause != node.ExportClause || moduleSpecifier != node.ModuleSpecifier || attributes != node.Attributes) {
			return Ast.updateNode(this.NewExportDeclaration(modifiers, isTypeOnly, exportClause, moduleSpecifier, attributes), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportTypeNode(isTypeOf:Bool, argument:TypeNode, attributes:ImportAttributesNode, qualifier:EntityName, typeArguments:TypeList):Node {
		final data = new ImportTypeNode();
		data.IsTypeOf = isTypeOf;
		data.Argument = argument;
		data.Attributes = attributes;
		data.Qualifier = qualifier;
		data.TypeArguments = typeArguments;
		return this.newNode(KindImportType, data);
	}

	public function UpdateImportTypeNode(node:ImportTypeNode, isTypeOf:Bool, argument:TypeNode, attributes:ImportAttributesNode, qualifier:EntityName, typeArguments:TypeList):Node {
		if (isTypeOf != node.IsTypeOf || argument != node.Argument || attributes != node.Attributes || qualifier != node.Qualifier || typeArguments != node.TypeArguments) {
			return Ast.updateNode(this.NewImportTypeNode(isTypeOf, argument, attributes, qualifier, typeArguments), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportClause(phaseModifier:ImportPhaseModifierSyntaxKind, name:IdentifierNode, namedBindings:NamedImportBindings):Node {
		final data = new ImportClause();
		data.PhaseModifier = phaseModifier;
		data.name = name;
		data.NamedBindings = namedBindings;
		return this.newNode(KindImportClause, data);
	}

	public function UpdateImportClause(node:ImportClause, phaseModifier:ImportPhaseModifierSyntaxKind, name:IdentifierNode, namedBindings:NamedImportBindings):Node {
		if (phaseModifier != node.PhaseModifier || name != node.name || namedBindings != node.NamedBindings) {
			return Ast.updateNode(this.NewImportClause(phaseModifier, name, namedBindings), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewImportSpecifier(isTypeOnly:Bool, propertyName:ModuleExportName, name:IdentifierNode):Node {
		final data = new ImportSpecifier();
		data.IsTypeOnly = isTypeOnly;
		data.PropertyName = propertyName;
		data.name = name;
		return this.newNode(KindImportSpecifier, data);
	}

	public function UpdateImportSpecifier(node:ImportSpecifier, isTypeOnly:Bool, propertyName:ModuleExportName, name:IdentifierNode):Node {
		if (isTypeOnly != node.IsTypeOnly || propertyName != node.PropertyName || name != node.name) {
			return Ast.updateNode(this.NewImportSpecifier(isTypeOnly, propertyName, name), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocText(text:Array<String>):Node {
		final data = new JSDocText();
		data.text = text;
		this.textCount++;
		return this.newNode(KindJSDocText, data);
	}

	public function NewJSDocLink(name:EntityName, text:Array<String>):Node {
		final data = new JSDocLink();
		data.name = name;
		data.text = text;
		this.textCount++;
		return this.newNode(KindJSDocLink, data);
	}

	public function UpdateJSDocLink(node:JSDocLink, name:EntityName, text:Array<String>):Node {
		if (name != node.name || !Core.Same(text, node.text)) {
			return Ast.updateNode(this.NewJSDocLink(name, text), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocLinkPlain(name:EntityName, text:Array<String>):Node {
		final data = new JSDocLinkPlain();
		data.name = name;
		data.text = text;
		this.textCount++;
		return this.newNode(KindJSDocLinkPlain, data);
	}

	public function UpdateJSDocLinkPlain(node:JSDocLinkPlain, name:EntityName, text:Array<String>):Node {
		if (name != node.name || !Core.Same(text, node.text)) {
			return Ast.updateNode(this.NewJSDocLinkPlain(name, text), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocLinkCode(name:EntityName, text:Array<String>):Node {
		final data = new JSDocLinkCode();
		data.name = name;
		data.text = text;
		this.textCount++;
		return this.newNode(KindJSDocLinkCode, data);
	}

	public function UpdateJSDocLinkCode(node:JSDocLinkCode, name:EntityName, text:Array<String>):Node {
		if (name != node.name || !Core.Same(text, node.text)) {
			return Ast.updateNode(this.NewJSDocLinkCode(name, text), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewTypeParameterDeclaration(modifiers:ModifierList, name:IdentifierNode, constraint:TypeNode, expression:Expression, defaultType:TypeNode):Node {
		final data = new TypeParameterDeclaration();
		data.modifiers = modifiers;
		data.name = name;
		data.Constraint = constraint;
		data.Expression = expression;
		data.DefaultType = defaultType;
		return this.newNode(KindTypeParameter, data);
	}

	public function UpdateTypeParameterDeclaration(node:TypeParameterDeclaration, modifiers:ModifierList, name:IdentifierNode, constraint:TypeNode, expression:Expression, defaultType:TypeNode):Node {
		if (modifiers != node.modifiers || name != node.name || constraint != node.Constraint || expression != node.Expression || defaultType != node.DefaultType) {
			return Ast.updateNode(this.NewTypeParameterDeclaration(modifiers, name, constraint, expression, defaultType), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewSyntheticReferenceExpression(expression:Expression, thisArg:Expression):Node {
		final data = new SyntheticReferenceExpression();
		data.Expression = expression;
		data.ThisArg = thisArg;
		return this.newNode(KindSyntheticReferenceExpression, data);
	}

	public function UpdateSyntheticReferenceExpression(node:SyntheticReferenceExpression, expression:Expression, thisArg:Expression):Node {
		if (expression != node.Expression || thisArg != node.ThisArg) {
			return Ast.updateNode(this.NewSyntheticReferenceExpression(expression, thisArg), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocTypeLiteral(jsdocPropertyTags:Array<Node>, isArrayType:Bool):Node {
		final data = new JSDocTypeLiteral();
		data.JSDocPropertyTags = jsdocPropertyTags;
		data.IsArrayType = isArrayType;
		return this.newNode(KindJSDocTypeLiteral, data);
	}

	public function UpdateJSDocTypeLiteral(node:JSDocTypeLiteral, jsdocPropertyTags:Array<Node>, isArrayType:Bool):Node {
		if (!Core.Same(jsdocPropertyTags, node.JSDocPropertyTags) || isArrayType != node.IsArrayType) {
			return Ast.updateNode(this.NewJSDocTypeLiteral(jsdocPropertyTags, isArrayType), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}

	public function NewJSDocParameterOrPropertyTag(kind:Kind, tagName:IdentifierNode, name:EntityName, isBracketed:Bool, typeExpression:TypeNode, isNameFirst:Bool, comment:NodeList):Node {
		final data = new JSDocParameterOrPropertyTag();
		data.TagName = tagName;
		data.name = name;
		data.IsBracketed = isBracketed;
		data.TypeExpression = typeExpression;
		data.IsNameFirst = isNameFirst;
		data.Comment = comment;
		return this.newNode(kind, data);
	}

	public function UpdateJSDocParameterOrPropertyTag(node:JSDocParameterOrPropertyTag, tagName:IdentifierNode, name:EntityName, isBracketed:Bool, typeExpression:TypeNode, isNameFirst:Bool, comment:NodeList):Node {
		if (tagName != node.TagName || name != node.name || isBracketed != node.IsBracketed || typeExpression != node.TypeExpression || isNameFirst != node.IsNameFirst || comment != node.Comment) {
			return Ast.updateNode(this.NewJSDocParameterOrPropertyTag(node.Kind, tagName, name, isBracketed, typeExpression, isNameFirst, comment), node.AsNode(), this.hooks);
		}
		return node.AsNode();
	}
	// END GENERATED: factory
}

// NodeList
class NodeList {
	// PORT: Go `Loc core.TextRange` → two Int fields with an inline Loc property (no allocation).
	public var pos:Int = 0;
	public var end:Int = 0;
	public var Loc(get, set):TextRange;
	public var Nodes:Array<Node> = null;

	public function new() {}

	inline function get_Loc():TextRange {
		return new TextRange(pos, end);
	}

	inline function set_Loc(v:TextRange):TextRange {
		pos = v.Pos();
		end = v.End();
		return v;
	}

	public inline function Pos():Int {
		return pos;
	}

	public inline function End():Int {
		return end;
	}

	public function HasTrailingComma():Bool {
		if (Core.len(Nodes) == 0) {
			return false;
		}
		final last = Nodes[Nodes.length - 1];
		return last.End() < End();
	}

	public function Clone(f:NodeFactoryCoercible):NodeList {
		final result = f.AsNodeFactory().NewNodeList(Nodes);
		result.Loc = Loc;
		return result;
	}
}

// ModifierList
// PORT: Go embeds NodeList; here ModifierList extends NodeList (`&list.NodeList` is the list itself).
class ModifierList extends NodeList {
	public var ModifierFlags:ModifierFlags = 0;

	public function new() {
		super();
	}

	// PORT: Go's ModifierList.Clone takes *NodeFactory and shadows NodeList.Clone; a Haxe override
	// keeps the parameter type of NodeList.Clone (NodeFactory implements NodeFactoryCoercible).
	override public function Clone(f:NodeFactoryCoercible):ModifierList {
		final res = new ModifierList();
		res.Loc = Loc;
		res.Nodes = Nodes;
		res.ModifierFlags = ModifierFlags;
		return res;
	}
}

// AST Node
// Interface values stored in AST nodes are never typed nil values. Construction code must ensure that
// interface valued properties either store a true nil or a reference to a non-nil struct.
//
// PORT: Go `*Node`. The object is a NodeDefault (or a subclass: the node data). See the header of
// this module. Node accessors. Some accessors are implemented as methods on NodeData, others are
// implemented though type switches (Kind switches here, as in Go).
@:forward
abstract Node(NodeDefault) from NodeDefault to NodeDefault {
	// PORT: Go returns iter.Seq; here an Iterator over the children (collected first; a Go
	// consumer that stops early observes the same children). PORT: perf — concrete ArrayIterator
	// type (see Scanner.iterateCommentRanges).
	public function IterChildren():haxe.iterators.ArrayIterator<Node> {
		final children = new Array<Node>();
		this.ForEachChild(function(child:Node):Bool {
			children.push(child);
			return false;
		});
		return children.iterator();
	}

	public function ParameterList():ParameterList {
		return this.FunctionLikeData().Parameters;
	}

	public function Parameters():Array<ParameterDeclarationNode> {
		return abstract.ParameterList().Nodes;
	}

	public function KindString():String {
		return this.Kind.String();
	}

	public inline function KindValue():Int {
		return this.Kind;
	}

	public function Decorators():Array<Node> {
		if (this.Modifiers() == null) {
			return null;
		}
		return Core.Filter(this.Modifiers().Nodes, Ast.IsDecorator);
	}

	public inline function AsMutable():MutableNode {
		return cast this;
	}

	public function Symbol():Symbol {
		final data = this.DeclarationData();
		if (data != null) {
			return data.Symbol;
		}
		return null;
	}

	public function LocalSymbol():Symbol {
		final data = this.ExportableData();
		if (data != null) {
			return data.LocalSymbol;
		}
		return null;
	}

	public function Locals():SymbolTable {
		final data = this.LocalsContainerData();
		if (data != null) {
			return data.Locals;
		}
		return null;
	}

	public function Body():Node {
		final data = this.BodyData();
		if (data != null) {
			return data.Body;
		}
		return null;
	}

	public function Text():String {
		switch (this.Kind) {
			case KindIdentifier:
				return abstract.AsIdentifier().Text;
			case KindPrivateIdentifier:
				return abstract.AsPrivateIdentifier().Text;
			case KindStringLiteral:
				return abstract.AsStringLiteral().Text;
			case KindNumericLiteral:
				return abstract.AsNumericLiteral().Text;
			case KindBigIntLiteral:
				return abstract.AsBigIntLiteral().Text;
			case KindMetaProperty:
				return abstract.AsMetaProperty().Name().Text();
			case KindNoSubstitutionTemplateLiteral:
				return abstract.AsNoSubstitutionTemplateLiteral().Text;
			case KindTemplateHead:
				return abstract.AsTemplateHead().Text;
			case KindTemplateMiddle:
				return abstract.AsTemplateMiddle().Text;
			case KindTemplateTail:
				return abstract.AsTemplateTail().Text;
			case KindJsxNamespacedName:
				return abstract.AsJsxNamespacedName().Namespace.Text() + ":" + abstract.AsJsxNamespacedName().name.Text();
			case KindRegularExpressionLiteral:
				return abstract.AsRegularExpressionLiteral().Text;
			case KindJSDocText:
				return abstract.AsJSDocText().text.join("");
			case KindJSDocLink:
				return abstract.AsJSDocLink().text.join("");
			case KindJSDocLinkCode:
				return abstract.AsJSDocLinkCode().text.join("");
			case KindJSDocLinkPlain:
				return abstract.AsJSDocLinkPlain().text.join("");
			default:
		}
		// PORT: Go prints the data type with %T; here the kind.
		throw "Unhandled case in Node.Text: " + this.Kind.String();
	}

	public function Expression():Node {
		switch (this.Kind) {
			case KindPropertyAccessExpression:
				return abstract.AsPropertyAccessExpression().Expression;
			case KindElementAccessExpression:
				return abstract.AsElementAccessExpression().Expression;
			case KindParenthesizedExpression:
				return abstract.AsParenthesizedExpression().Expression;
			case KindCallExpression:
				return abstract.AsCallExpression().Expression;
			case KindNewExpression:
				return abstract.AsNewExpression().Expression;
			case KindExpressionWithTypeArguments:
				return abstract.AsExpressionWithTypeArguments().Expression;
			case KindComputedPropertyName:
				return abstract.AsComputedPropertyName().Expression;
			case KindNonNullExpression:
				return abstract.AsNonNullExpression().Expression;
			case KindTypeAssertionExpression:
				return abstract.AsTypeAssertion().Expression;
			case KindAsExpression:
				return abstract.AsAsExpression().Expression;
			case KindSatisfiesExpression:
				return abstract.AsSatisfiesExpression().Expression;
			case KindTypeOfExpression:
				return abstract.AsTypeOfExpression().Expression;
			case KindSpreadAssignment:
				return abstract.AsSpreadAssignment().Expression;
			case KindSpreadElement:
				return abstract.AsSpreadElement().Expression;
			case KindTemplateSpan:
				return abstract.AsTemplateSpan().Expression;
			case KindDeleteExpression:
				return abstract.AsDeleteExpression().Expression;
			case KindVoidExpression:
				return abstract.AsVoidExpression().Expression;
			case KindAwaitExpression:
				return abstract.AsAwaitExpression().Expression;
			case KindYieldExpression:
				return abstract.AsYieldExpression().Expression;
			case KindPartiallyEmittedExpression:
				return abstract.AsPartiallyEmittedExpression().Expression;
			case KindIfStatement:
				return abstract.AsIfStatement().Expression;
			case KindDoStatement:
				return abstract.AsDoStatement().Expression;
			case KindWhileStatement:
				return abstract.AsWhileStatement().Expression;
			case KindWithStatement:
				return abstract.AsWithStatement().Expression;
			case KindForInStatement | KindForOfStatement:
				return abstract.AsForInOrOfStatement().Expression;
			case KindSwitchStatement:
				return abstract.AsSwitchStatement().Expression;
			case KindCaseClause:
				return abstract.AsCaseOrDefaultClause().Expression;
			case KindExpressionStatement:
				return abstract.AsExpressionStatement().Expression;
			case KindReturnStatement:
				return abstract.AsReturnStatement().Expression;
			case KindThrowStatement:
				return abstract.AsThrowStatement().Expression;
			case KindExternalModuleReference:
				return abstract.AsExternalModuleReference().Expression;
			case KindExportAssignment:
				return abstract.AsExportAssignment().Expression;
			case KindDecorator:
				return abstract.AsDecorator().Expression;
			case KindJsxExpression:
				return abstract.AsJsxExpression().Expression;
			case KindJsxSpreadAttribute:
				return abstract.AsJsxSpreadAttribute().Expression;
			default:
		}
		throw "Unhandled case in Node.Expression: " + this.Kind.String();
	}

	public function RawText():String {
		switch (this.Kind) {
			case KindTemplateHead:
				return abstract.AsTemplateHead().RawText;
			case KindTemplateMiddle:
				return abstract.AsTemplateMiddle().RawText;
			case KindTemplateTail:
				return abstract.AsTemplateTail().RawText;
			default:
		}
		throw "Unhandled case in Node.RawText: " + this.Kind.String();
	}

	public function ArgumentList():NodeList {
		switch (this.Kind) {
			case KindCallExpression:
				return abstract.AsCallExpression().Arguments;
			case KindNewExpression:
				return abstract.AsNewExpression().Arguments;
			default:
		}
		throw "Unhandled case in Node.Arguments: " + this.Kind.String();
	}

	public function Arguments():Array<Node> {
		final list = abstract.ArgumentList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function TypeArgumentList():NodeList {
		switch (this.Kind) {
			case KindCallExpression:
				return abstract.AsCallExpression().TypeArguments;
			case KindNewExpression:
				return abstract.AsNewExpression().TypeArguments;
			case KindTaggedTemplateExpression:
				return abstract.AsTaggedTemplateExpression().TypeArguments;
			case KindTypeReference:
				return abstract.AsTypeReferenceNode().TypeArguments;
			case KindExpressionWithTypeArguments:
				return abstract.AsExpressionWithTypeArguments().TypeArguments;
			case KindImportType:
				return abstract.AsImportTypeNode().TypeArguments;
			case KindTypeQuery:
				return abstract.AsTypeQueryNode().TypeArguments;
			case KindJsxOpeningElement:
				return abstract.AsJsxOpeningElement().TypeArguments;
			case KindJsxSelfClosingElement:
				return abstract.AsJsxSelfClosingElement().TypeArguments;
			default:
		}
		throw "Unhandled case in Node.TypeArguments";
	}

	public function TypeArguments():Array<Node> {
		final list = abstract.TypeArgumentList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function TypeParameterList():NodeList {
		switch (this.Kind) {
			case KindClassDeclaration:
				return abstract.AsClassDeclaration().TypeParameters;
			case KindClassExpression:
				return abstract.AsClassExpression().TypeParameters;
			case KindInterfaceDeclaration:
				return abstract.AsInterfaceDeclaration().TypeParameters;
			case KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				return abstract.AsTypeAliasDeclaration().TypeParameters;
			case KindJSDocTemplateTag:
				return abstract.AsJSDocTemplateTag().TypeParameters;
			default:
				final funcLike = this.FunctionLikeData();
				if (funcLike != null) {
					return funcLike.TypeParameters;
				}
		}
		throw "Unhandled case in Node.TypeParameterList";
	}

	public function TypeParameters():Array<Node> {
		final list = abstract.TypeParameterList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function MemberList():NodeList {
		switch (this.Kind) {
			case KindClassDeclaration:
				return abstract.AsClassDeclaration().Members;
			case KindClassExpression:
				return abstract.AsClassExpression().Members;
			case KindInterfaceDeclaration:
				return abstract.AsInterfaceDeclaration().Members;
			case KindEnumDeclaration:
				return abstract.AsEnumDeclaration().Members;
			case KindTypeLiteral:
				return abstract.AsTypeLiteralNode().Members;
			case KindMappedType:
				return abstract.AsMappedTypeNode().Members;
			default:
		}
		throw "Unhandled case in Node.MemberList: " + this.Kind.String();
	}

	public function Members():Array<Node> {
		final list = abstract.MemberList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function StatementList():NodeList {
		switch (this.Kind) {
			case KindSourceFile:
				return abstract.AsSourceFile().Statements;
			case KindBlock:
				return abstract.AsBlock().Statements;
			case KindModuleBlock:
				return abstract.AsModuleBlock().Statements;
			case KindCaseClause | KindDefaultClause:
				return abstract.AsCaseOrDefaultClause().Statements;
			default:
		}
		throw "Unhandled case in Node.StatementList: " + this.Kind.String();
	}

	public function Statements():Array<Node> {
		final list = abstract.StatementList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function CanHaveStatements():Bool {
		switch (this.Kind) {
			case KindSourceFile | KindBlock | KindModuleBlock | KindCaseClause | KindDefaultClause:
				return true;
			default:
				return false;
		}
	}

	public function ModifierFlags():ModifierFlags {
		final modifiers = this.Modifiers();
		if (modifiers != null) {
			return modifiers.ModifierFlags;
		}
		return ModifierFlagsNone;
	}

	public function ModifierNodes():Array<Node> {
		final modifiers = this.Modifiers();
		if (modifiers != null) {
			return modifiers.Nodes;
		}
		return null;
	}

	public function Type():Node {
		switch (this.Kind) {
			case KindVariableDeclaration:
				return abstract.AsVariableDeclaration().Type;
			case KindParameter:
				return abstract.AsParameterDeclaration().Type;
			case KindPropertySignature:
				return abstract.AsPropertySignatureDeclaration().Type;
			case KindPropertyDeclaration:
				return abstract.AsPropertyDeclaration().Type;
			case KindPropertyAssignment:
				return abstract.AsPropertyAssignment().Type;
			case KindShorthandPropertyAssignment:
				return abstract.AsShorthandPropertyAssignment().Type;
			case KindTypePredicate:
				return abstract.AsTypePredicateNode().Type;
			case KindParenthesizedType:
				return abstract.AsParenthesizedTypeNode().Type;
			case KindTypeOperator:
				return abstract.AsTypeOperatorNode().Type;
			case KindMappedType:
				return abstract.AsMappedTypeNode().Type;
			case KindTypeAssertionExpression:
				return abstract.AsTypeAssertion().Type;
			case KindAsExpression:
				return abstract.AsAsExpression().Type;
			case KindSatisfiesExpression:
				return abstract.AsSatisfiesExpression().Type;
			case KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				return abstract.AsTypeAliasDeclaration().Type;
			case KindNamedTupleMember:
				return abstract.AsNamedTupleMember().Type;
			case KindOptionalType:
				return abstract.AsOptionalTypeNode().Type;
			case KindRestType:
				return abstract.AsRestTypeNode().Type;
			case KindTemplateLiteralTypeSpan:
				return abstract.AsTemplateLiteralTypeSpan().Type;
			case KindJSDocTypeExpression:
				return abstract.AsJSDocTypeExpression().Type;
			case KindJSDocParameterTag | KindJSDocPropertyTag:
				return abstract.AsJSDocParameterOrPropertyTag().TypeExpression;
			case KindJSDocNullableType:
				return abstract.AsJSDocNullableType().Type;
			case KindJSDocNonNullableType:
				return abstract.AsJSDocNonNullableType().Type;
			case KindJSDocOptionalType:
				return abstract.AsJSDocOptionalType().Type;
			case KindExportAssignment:
				return abstract.AsExportAssignment().Type;
			case KindBinaryExpression:
				return abstract.AsBinaryExpression().Type;
			default:
				final funcLike = this.FunctionLikeData();
				if (funcLike != null) {
					return funcLike.Type;
				}
		}
		return null;
	}

	public function Initializer():Node {
		switch (this.Kind) {
			case KindVariableDeclaration:
				return abstract.AsVariableDeclaration().Initializer;
			case KindParameter:
				return abstract.AsParameterDeclaration().Initializer;
			case KindBindingElement:
				return abstract.AsBindingElement().Initializer;
			case KindPropertyDeclaration:
				return abstract.AsPropertyDeclaration().Initializer;
			case KindPropertySignature:
				return abstract.AsPropertySignatureDeclaration().Initializer;
			case KindPropertyAssignment:
				return abstract.AsPropertyAssignment().Initializer;
			case KindEnumMember:
				return abstract.AsEnumMember().Initializer;
			case KindForStatement:
				return abstract.AsForStatement().Initializer;
			case KindForInStatement | KindForOfStatement:
				return abstract.AsForInOrOfStatement().Initializer;
			case KindJsxAttribute:
				return abstract.AsJsxAttribute().Initializer;
			default:
		}
		throw "Unhandled case in Node.Initializer";
	}

	public function TagName():Node {
		switch (this.Kind) {
			case KindJsxOpeningElement:
				return abstract.AsJsxOpeningElement().TagName;
			case KindJsxClosingElement:
				return abstract.AsJsxClosingElement().TagName;
			case KindJsxSelfClosingElement:
				return abstract.AsJsxSelfClosingElement().TagName;
			case KindJSDocUnknownTag:
				return abstract.AsJSDocUnknownTag().TagName;
			case KindJSDocAugmentsTag:
				return abstract.AsJSDocAugmentsTag().TagName;
			case KindJSDocImplementsTag:
				return abstract.AsJSDocImplementsTag().TagName;
			case KindJSDocDeprecatedTag:
				return abstract.AsJSDocDeprecatedTag().TagName;
			case KindJSDocPublicTag:
				return abstract.AsJSDocPublicTag().TagName;
			case KindJSDocPrivateTag:
				return abstract.AsJSDocPrivateTag().TagName;
			case KindJSDocProtectedTag:
				return abstract.AsJSDocProtectedTag().TagName;
			case KindJSDocReadonlyTag:
				return abstract.AsJSDocReadonlyTag().TagName;
			case KindJSDocOverrideTag:
				return abstract.AsJSDocOverrideTag().TagName;
			case KindJSDocCallbackTag:
				return abstract.AsJSDocCallbackTag().TagName;
			case KindJSDocOverloadTag:
				return abstract.AsJSDocOverloadTag().TagName;
			case KindJSDocParameterTag | KindJSDocPropertyTag:
				return abstract.AsJSDocParameterOrPropertyTag().TagName;
			case KindJSDocReturnTag:
				return abstract.AsJSDocReturnTag().TagName;
			case KindJSDocThisTag:
				return abstract.AsJSDocThisTag().TagName;
			case KindJSDocTypeTag:
				return abstract.AsJSDocTypeTag().TagName;
			case KindJSDocTemplateTag:
				return abstract.AsJSDocTemplateTag().TagName;
			case KindJSDocTypedefTag:
				return abstract.AsJSDocTypedefTag().TagName;
			case KindJSDocSeeTag:
				return abstract.AsJSDocSeeTag().TagName;
			case KindJSDocSatisfiesTag:
				return abstract.AsJSDocSatisfiesTag().TagName;
			case KindJSDocThrowsTag:
				return abstract.AsJSDocThrowsTag().TagName;
			case KindJSDocImportTag:
				return abstract.AsJSDocImportTag().TagName;
			default:
		}
		throw "Unhandled case in Node.TagName: " + this.Kind.String();
	}

	public function PropertyName():Node {
		switch (this.Kind) {
			case KindImportSpecifier:
				return abstract.AsImportSpecifier().PropertyName;
			case KindExportSpecifier:
				return abstract.AsExportSpecifier().PropertyName;
			case KindBindingElement:
				return abstract.AsBindingElement().PropertyName;
			default:
		}
		return null;
	}

	public function PropertyNameOrName():Node {
		var name = abstract.PropertyName();
		if (name == null) {
			name = this.Name();
		}
		return name;
	}

	public function IsTypeOnly():Bool {
		switch (this.Kind) {
			case KindImportEqualsDeclaration:
				return abstract.AsImportEqualsDeclaration().IsTypeOnly;
			case KindImportSpecifier:
				return abstract.AsImportSpecifier().IsTypeOnly;
			case KindImportClause:
				return abstract.AsImportClause().PhaseModifier == KindTypeKeyword;
			case KindExportDeclaration:
				return abstract.AsExportDeclaration().IsTypeOnly;
			case KindExportSpecifier:
				return abstract.AsExportSpecifier().IsTypeOnly;
			default:
		}
		return false;
	}

	// If updating this function, also update `hasComment`.
	public function CommentList():NodeList {
		switch (this.Kind) {
			case KindJSDoc:
				return abstract.AsJSDoc().Comment;
			case KindJSDocUnknownTag:
				return abstract.AsJSDocUnknownTag().Comment;
			case KindJSDocAugmentsTag:
				return abstract.AsJSDocAugmentsTag().Comment;
			case KindJSDocImplementsTag:
				return abstract.AsJSDocImplementsTag().Comment;
			case KindJSDocDeprecatedTag:
				return abstract.AsJSDocDeprecatedTag().Comment;
			case KindJSDocPublicTag:
				return abstract.AsJSDocPublicTag().Comment;
			case KindJSDocPrivateTag:
				return abstract.AsJSDocPrivateTag().Comment;
			case KindJSDocProtectedTag:
				return abstract.AsJSDocProtectedTag().Comment;
			case KindJSDocReadonlyTag:
				return abstract.AsJSDocReadonlyTag().Comment;
			case KindJSDocOverrideTag:
				return abstract.AsJSDocOverrideTag().Comment;
			case KindJSDocCallbackTag:
				return abstract.AsJSDocCallbackTag().Comment;
			case KindJSDocOverloadTag:
				return abstract.AsJSDocOverloadTag().Comment;
			case KindJSDocParameterTag | KindJSDocPropertyTag:
				return abstract.AsJSDocParameterOrPropertyTag().Comment;
			case KindJSDocReturnTag:
				return abstract.AsJSDocReturnTag().Comment;
			case KindJSDocThisTag:
				return abstract.AsJSDocThisTag().Comment;
			case KindJSDocTypeTag:
				return abstract.AsJSDocTypeTag().Comment;
			case KindJSDocTemplateTag:
				return abstract.AsJSDocTemplateTag().Comment;
			case KindJSDocTypedefTag:
				return abstract.AsJSDocTypedefTag().Comment;
			case KindJSDocSeeTag:
				return abstract.AsJSDocSeeTag().Comment;
			case KindJSDocSatisfiesTag:
				return abstract.AsJSDocSatisfiesTag().Comment;
			case KindJSDocThrowsTag:
				return abstract.AsJSDocThrowsTag().Comment;
			case KindJSDocImportTag:
				return abstract.AsJSDocImportTag().Comment;
			default:
		}
		throw "Unhandled case in Node.CommentList: " + this.Kind.String();
	}

	public function Comments():Array<Node> {
		final list = abstract.CommentList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function Label():Node {
		switch (this.Kind) {
			case KindLabeledStatement:
				return abstract.AsLabeledStatement().Label;
			case KindBreakStatement:
				return abstract.AsBreakStatement().Label;
			case KindContinueStatement:
				return abstract.AsContinueStatement().Label;
			default:
		}
		throw "Unhandled case in Node.Label: " + this.Kind.String();
	}

	public function Attributes():Node {
		switch (this.Kind) {
			case KindJsxOpeningElement:
				return abstract.AsJsxOpeningElement().Attributes;
			case KindJsxSelfClosingElement:
				return abstract.AsJsxSelfClosingElement().Attributes;
			default:
		}
		throw "Unhandled case in Node.Attributes: " + this.Kind.String();
	}

	public function Children():NodeList {
		switch (this.Kind) {
			case KindJsxElement:
				return abstract.AsJsxElement().Children;
			case KindJsxFragment:
				return abstract.AsJsxFragment().Children;
			default:
		}
		throw "Unhandled case in Node.Children: " + this.Kind.String();
	}

	public function ModuleSpecifier():Expression {
		switch (this.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				return abstract.AsImportDeclaration().ModuleSpecifier;
			case KindExportDeclaration:
				return abstract.AsExportDeclaration().ModuleSpecifier;
			case KindJSDocImportTag:
				return abstract.AsJSDocImportTag().ModuleSpecifier;
			default:
		}
		throw "Unhandled case in Node.ModuleSpecifier: " + this.Kind.String();
	}

	public function ImportClause():Node {
		switch (this.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				return abstract.AsImportDeclaration().ImportClause;
			case KindJSDocImportTag:
				return abstract.AsJSDocImportTag().ImportClause;
			default:
		}
		throw "Unhandled case in Node.ImportClause: " + this.Kind.String();
	}

	public function Statement():Statement {
		switch (this.Kind) {
			case KindDoStatement:
				return abstract.AsDoStatement().Statement;
			case KindWhileStatement:
				return abstract.AsWhileStatement().Statement;
			case KindForStatement:
				return abstract.AsForStatement().Statement;
			case KindForInStatement | KindForOfStatement:
				return abstract.AsForInOrOfStatement().Statement;
			case KindWithStatement:
				return abstract.AsWithStatement().Statement;
			case KindLabeledStatement:
				return abstract.AsLabeledStatement().Statement;
			default:
		}
		throw "Unhandled case in Node.Statement: " + this.Kind.String();
	}

	public function PropertyList():NodeList {
		switch (this.Kind) {
			case KindObjectLiteralExpression:
				return abstract.AsObjectLiteralExpression().Properties;
			case KindJsxAttributes:
				return abstract.AsJsxAttributes().Properties;
			default:
		}
		throw "Unhandled case in Node.PropertyList: " + this.Kind.String();
	}

	public function Properties():Array<Node> {
		final list = abstract.PropertyList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function ElementList():NodeList {
		switch (this.Kind) {
			case KindNamedImports:
				return abstract.AsNamedImports().Elements;
			case KindNamedExports:
				return abstract.AsNamedExports().Elements;
			case KindObjectBindingPattern | KindArrayBindingPattern:
				return abstract.AsBindingPattern().Elements;
			case KindArrayLiteralExpression:
				return abstract.AsArrayLiteralExpression().Elements;
			case KindTupleType:
				return abstract.AsTupleTypeNode().Elements;
			default:
		}
		throw "Unhandled case in Node.ElementList: " + this.Kind.String();
	}

	public function Elements():Array<Node> {
		final list = abstract.ElementList();
		if (list != null) {
			return list.Nodes;
		}
		return null;
	}

	public function PostfixToken():Node {
		switch (this.Kind) {
			case KindMethodDeclaration:
				return abstract.AsMethodDeclaration().PostfixToken;
			case KindShorthandPropertyAssignment:
				return abstract.AsShorthandPropertyAssignment().PostfixToken;
			case KindMethodSignature:
				return abstract.AsMethodSignatureDeclaration().PostfixToken;
			case KindPropertySignature:
				return abstract.AsPropertySignatureDeclaration().PostfixToken;
			case KindPropertyAssignment:
				return abstract.AsPropertyAssignment().PostfixToken;
			case KindPropertyDeclaration:
				return abstract.AsPropertyDeclaration().PostfixToken;
			case KindEnumMember:
				return abstract.AsEnumMember().PostfixToken;
			case KindGetAccessor:
				return abstract.AsGetAccessorDeclaration().PostfixToken;
			case KindSetAccessor:
				return abstract.AsSetAccessorDeclaration().PostfixToken;
			default:
		}
		return null;
	}

	public function QuestionToken():TokenNode {
		switch (this.Kind) {
			case KindParameter:
				return abstract.AsParameterDeclaration().QuestionToken;
			case KindConditionalExpression:
				return abstract.AsConditionalExpression().QuestionToken;
			case KindMappedType:
				return abstract.AsMappedTypeNode().QuestionToken;
			case KindNamedTupleMember:
				return abstract.AsNamedTupleMember().QuestionToken;
			default:
		}
		final postfix = abstract.PostfixToken();
		if (postfix != null && postfix.Kind == KindQuestionToken) {
			return postfix;
		}
		return null;
	}

	public function QuestionDotToken():Node {
		switch (this.Kind) {
			case KindElementAccessExpression:
				return abstract.AsElementAccessExpression().QuestionDotToken;
			case KindPropertyAccessExpression:
				return abstract.AsPropertyAccessExpression().QuestionDotToken;
			case KindCallExpression:
				return abstract.AsCallExpression().QuestionDotToken;
			case KindTaggedTemplateExpression:
				return abstract.AsTaggedTemplateExpression().QuestionDotToken;
			default:
		}
		throw "Unhandled case in Node.QuestionDotToken: " + this.Kind.String();
	}

	public function TypeExpression():Node {
		switch (this.Kind) {
			case KindJSDocParameterTag | KindJSDocPropertyTag:
				return abstract.AsJSDocParameterOrPropertyTag().TypeExpression;
			case KindJSDocReturnTag:
				return abstract.AsJSDocReturnTag().TypeExpression;
			case KindJSDocTypeTag:
				return abstract.AsJSDocTypeTag().TypeExpression;
			case KindJSDocTypedefTag:
				return abstract.AsJSDocTypedefTag().TypeExpression;
			case KindJSDocCallbackTag:
				return abstract.AsJSDocCallbackTag().TypeExpression;
			case KindJSDocSatisfiesTag:
				return abstract.AsJSDocSatisfiesTag().TypeExpression;
			case KindJSDocThrowsTag:
				return abstract.AsJSDocThrowsTag().TypeExpression;
			default:
		}
		throw "Unhandled case in Node.TypeExpression: " + this.Kind.String();
	}

	public function ClassName():Node {
		switch (this.Kind) {
			case KindJSDocAugmentsTag:
				return abstract.AsJSDocAugmentsTag().ClassName;
			case KindJSDocImplementsTag:
				return abstract.AsJSDocImplementsTag().ClassName;
			default:
		}
		throw "Unhandled case in Node.ClassName: " + this.Kind.String();
	}

	// Determines if `n` contains `descendant` by walking up the `Parent` pointers from `descendant`. This method panics if
	// `descendant` or one of its ancestors is not parented except when that node is a `SourceFile`.
	public function Contains(descendant:Node):Bool {
		while (descendant != null) {
			if (descendant == abstract) {
				return true;
			}
			final parent = descendant.Parent;
			if (parent == null && !Ast.IsSourceFile(descendant)) {
				throw "descendant is not parented";
			}
			descendant = parent;
		}
		return false;
	}

	// Node casts

	public inline function AsFlowSwitchClauseData():FlowSwitchClauseData {
		return cast this;
	}

	public inline function AsFlowReduceLabelData():FlowReduceLabelData {
		return cast this;
	}

	// if you provide nil for file, this code will walk to the root of the tree to find the file
	public function JSDoc(file:SourceFile):Array<Node> {
		if (this.Flags & NodeFlagsHasJSDoc == 0) {
			return null;
		}
		if (file == null) {
			file = Ast.GetSourceFileOfNode(abstract);
			if (file == null) {
				return null;
			}
		}
		if (file.hasLazyJSDoc) {
			return file.resolveJSDoc(abstract);
		}
		return file.jsdocCache == null ? null : file.jsdocCache.get(abstract);
	}

	// EagerJSDoc returns JSDoc nodes that have already been parsed and cached,
	// without triggering lazy JSDoc parsing.
	public function EagerJSDoc(file:SourceFile):Array<Node> {
		if (this.Flags & NodeFlagsHasJSDoc == 0) {
			return null;
		}
		if (file == null) {
			file = Ast.GetSourceFileOfNode(abstract);
			if (file == null) {
				return null;
			}
		}
		// PORT: the RLock path of Go reads the same cache.
		return file.jsdocCache == null ? null : file.jsdocCache.get(abstract);
	}

	// JSDoc

	public function IsJSDoc():Bool {
		return this.Kind == KindJSDoc;
	}

	// PORT: Go method on *ImportAttributesNode (= *Node). (core.ResolutionMode, bool) → ValueOk.
	public function GetResolutionModeOverride():ValueOk<ResolutionMode> {
		if (abstract == null) {
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}

		final attributes = abstract.AsImportAttributes().Attributes;

		if (attributes.Nodes.length != 1) {
			// !!!
			// grammarErrorOnNode?.(
			//     node,
			//     node.token === SyntaxKind.WithKeyword
			//         ? Diagnostics.Type_import_attributes_should_have_exactly_one_key_resolution_mode_with_value_import_or_require
			//         : Diagnostics.Type_import_assertions_should_have_exactly_one_key_resolution_mode_with_value_import_or_require,
			// );
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}

		final elem = attributes.Nodes[0].AsImportAttribute();
		if (!Ast.IsStringLiteralLike(elem.Name())) {
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}
		if (elem.Name().Text() != "resolution-mode") {
			// !!!
			// grammarErrorOnNode?.(
			//     elem.name,
			//     node.token === SyntaxKind.WithKeyword
			//         ? Diagnostics.resolution_mode_is_the_only_valid_key_for_type_import_attributes
			//         : Diagnostics.resolution_mode_is_the_only_valid_key_for_type_import_assertions,
			// );
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}
		if (!Ast.IsStringLiteralLike(elem.Value)) {
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}
		if (elem.Value.Text() != "import" && elem.Value.Text() != "require") {
			// !!!
			// grammarErrorOnNode?.(elem.value, Diagnostics.resolution_mode_should_be_either_require_or_import);
			return new ValueOk<ResolutionMode>(Core.ResolutionModeNone, false);
		}
		if (elem.Value.Text() == "import") {
			return new ValueOk<ResolutionMode>(Core.ResolutionModeESM, true);
		} else {
			return new ValueOk<ResolutionMode>(ModuleKindCommonJS, true);
		}
	}

	// BEGIN GENERATED (tools/gen/ast) — do not edit: as
	// --- ast_generated.go: As*() cast methods ---
	// PORT: Go `n.data.(*X)` → unchecked cast (the node object is the data object).

	public inline function AsToken():Token {
		return cast this;
	}

	public inline function AsIdentifier():Identifier {
		return cast this;
	}

	public inline function AsPrivateIdentifier():PrivateIdentifier {
		return cast this;
	}

	public inline function AsQualifiedName():QualifiedName {
		return cast this;
	}

	public inline function AsComputedPropertyName():ComputedPropertyName {
		return cast this;
	}

	public inline function AsDecorator():Decorator {
		return cast this;
	}

	public inline function AsEmptyStatement():EmptyStatement {
		return cast this;
	}

	public inline function AsIfStatement():IfStatement {
		return cast this;
	}

	public inline function AsDoStatement():DoStatement {
		return cast this;
	}

	public inline function AsWhileStatement():WhileStatement {
		return cast this;
	}

	public inline function AsForStatement():ForStatement {
		return cast this;
	}

	public inline function AsForInOrOfStatement():ForInOrOfStatement {
		return cast this;
	}

	public inline function AsBreakStatement():BreakStatement {
		return cast this;
	}

	public inline function AsContinueStatement():ContinueStatement {
		return cast this;
	}

	public inline function AsReturnStatement():ReturnStatement {
		return cast this;
	}

	public inline function AsWithStatement():WithStatement {
		return cast this;
	}

	public inline function AsSwitchStatement():SwitchStatement {
		return cast this;
	}

	public inline function AsCaseBlock():CaseBlock {
		return cast this;
	}

	public inline function AsCaseOrDefaultClause():CaseOrDefaultClause {
		return cast this;
	}

	public inline function AsThrowStatement():ThrowStatement {
		return cast this;
	}

	public inline function AsTryStatement():TryStatement {
		return cast this;
	}

	public inline function AsCatchClause():CatchClause {
		return cast this;
	}

	public inline function AsDebuggerStatement():DebuggerStatement {
		return cast this;
	}

	public inline function AsLabeledStatement():LabeledStatement {
		return cast this;
	}

	public inline function AsExpressionStatement():ExpressionStatement {
		return cast this;
	}

	public inline function AsBlock():Block {
		return cast this;
	}

	public inline function AsVariableStatement():VariableStatement {
		return cast this;
	}

	public inline function AsVariableDeclaration():VariableDeclaration {
		return cast this;
	}

	public inline function AsVariableDeclarationList():VariableDeclarationList {
		return cast this;
	}

	public inline function AsBindingPattern():BindingPattern {
		return cast this;
	}

	public inline function AsParameterDeclaration():ParameterDeclaration {
		return cast this;
	}

	public inline function AsBindingElement():BindingElement {
		return cast this;
	}

	public inline function AsMissingDeclaration():MissingDeclaration {
		return cast this;
	}

	public inline function AsFunctionDeclaration():FunctionDeclaration {
		return cast this;
	}

	public inline function AsClassDeclaration():ClassDeclaration {
		return cast this;
	}

	public inline function AsClassExpression():ClassExpression {
		return cast this;
	}

	public inline function AsHeritageClause():HeritageClause {
		return cast this;
	}

	public inline function AsInterfaceDeclaration():InterfaceDeclaration {
		return cast this;
	}

	public inline function AsTypeAliasDeclaration():TypeAliasDeclaration {
		return cast this;
	}

	public inline function AsEnumMember():EnumMember {
		return cast this;
	}

	public inline function AsEnumDeclaration():EnumDeclaration {
		return cast this;
	}

	public inline function AsModuleBlock():ModuleBlock {
		return cast this;
	}

	public inline function AsNotEmittedStatement():NotEmittedStatement {
		return cast this;
	}

	public inline function AsNotEmittedTypeElement():NotEmittedTypeElement {
		return cast this;
	}

	public inline function AsImportDeclaration():ImportDeclaration {
		return cast this;
	}

	public inline function AsExternalModuleReference():ExternalModuleReference {
		return cast this;
	}

	public inline function AsNamespaceImport():NamespaceImport {
		return cast this;
	}

	public inline function AsNamedImports():NamedImports {
		return cast this;
	}

	public inline function AsExportAssignment():ExportAssignment {
		return cast this;
	}

	public inline function AsNamespaceExportDeclaration():NamespaceExportDeclaration {
		return cast this;
	}

	public inline function AsNamespaceExport():NamespaceExport {
		return cast this;
	}

	public inline function AsNamedExports():NamedExports {
		return cast this;
	}

	public inline function AsExportSpecifier():ExportSpecifier {
		return cast this;
	}

	public inline function AsCallSignatureDeclaration():CallSignatureDeclaration {
		return cast this;
	}

	public inline function AsConstructSignatureDeclaration():ConstructSignatureDeclaration {
		return cast this;
	}

	public inline function AsConstructorDeclaration():ConstructorDeclaration {
		return cast this;
	}

	public inline function AsGetAccessorDeclaration():GetAccessorDeclaration {
		return cast this;
	}

	public inline function AsSetAccessorDeclaration():SetAccessorDeclaration {
		return cast this;
	}

	public inline function AsIndexSignatureDeclaration():IndexSignatureDeclaration {
		return cast this;
	}

	public inline function AsMethodSignatureDeclaration():MethodSignatureDeclaration {
		return cast this;
	}

	public inline function AsMethodDeclaration():MethodDeclaration {
		return cast this;
	}

	public inline function AsPropertySignatureDeclaration():PropertySignatureDeclaration {
		return cast this;
	}

	public inline function AsPropertyDeclaration():PropertyDeclaration {
		return cast this;
	}

	public inline function AsSemicolonClassElement():SemicolonClassElement {
		return cast this;
	}

	public inline function AsClassStaticBlockDeclaration():ClassStaticBlockDeclaration {
		return cast this;
	}

	public inline function AsOmittedExpression():OmittedExpression {
		return cast this;
	}

	public inline function AsKeywordExpression():KeywordExpression {
		return cast this;
	}

	public inline function AsStringLiteral():StringLiteral {
		return cast this;
	}

	public inline function AsNumericLiteral():NumericLiteral {
		return cast this;
	}

	public inline function AsBigIntLiteral():BigIntLiteral {
		return cast this;
	}

	public inline function AsRegularExpressionLiteral():RegularExpressionLiteral {
		return cast this;
	}

	public inline function AsNoSubstitutionTemplateLiteral():NoSubstitutionTemplateLiteral {
		return cast this;
	}

	public inline function AsBinaryExpression():BinaryExpression {
		return cast this;
	}

	public inline function AsPrefixUnaryExpression():PrefixUnaryExpression {
		return cast this;
	}

	public inline function AsPostfixUnaryExpression():PostfixUnaryExpression {
		return cast this;
	}

	public inline function AsYieldExpression():YieldExpression {
		return cast this;
	}

	public inline function AsArrowFunction():ArrowFunction {
		return cast this;
	}

	public inline function AsFunctionExpression():FunctionExpression {
		return cast this;
	}

	public inline function AsAsExpression():AsExpression {
		return cast this;
	}

	public inline function AsSatisfiesExpression():SatisfiesExpression {
		return cast this;
	}

	public inline function AsConditionalExpression():ConditionalExpression {
		return cast this;
	}

	public inline function AsPropertyAccessExpression():PropertyAccessExpression {
		return cast this;
	}

	public inline function AsElementAccessExpression():ElementAccessExpression {
		return cast this;
	}

	public inline function AsCallExpression():CallExpression {
		return cast this;
	}

	public inline function AsNewExpression():NewExpression {
		return cast this;
	}

	public inline function AsMetaProperty():MetaProperty {
		return cast this;
	}

	public inline function AsNonNullExpression():NonNullExpression {
		return cast this;
	}

	public inline function AsSpreadElement():SpreadElement {
		return cast this;
	}

	public inline function AsTemplateExpression():TemplateExpression {
		return cast this;
	}

	public inline function AsTemplateSpan():TemplateSpan {
		return cast this;
	}

	public inline function AsTaggedTemplateExpression():TaggedTemplateExpression {
		return cast this;
	}

	public inline function AsParenthesizedExpression():ParenthesizedExpression {
		return cast this;
	}

	public inline function AsArrayLiteralExpression():ArrayLiteralExpression {
		return cast this;
	}

	public inline function AsObjectLiteralExpression():ObjectLiteralExpression {
		return cast this;
	}

	public inline function AsSpreadAssignment():SpreadAssignment {
		return cast this;
	}

	public inline function AsPropertyAssignment():PropertyAssignment {
		return cast this;
	}

	public inline function AsShorthandPropertyAssignment():ShorthandPropertyAssignment {
		return cast this;
	}

	public inline function AsDeleteExpression():DeleteExpression {
		return cast this;
	}

	public inline function AsTypeOfExpression():TypeOfExpression {
		return cast this;
	}

	public inline function AsVoidExpression():VoidExpression {
		return cast this;
	}

	public inline function AsAwaitExpression():AwaitExpression {
		return cast this;
	}

	public inline function AsTypeAssertion():TypeAssertion {
		return cast this;
	}

	public inline function AsKeywordTypeNode():KeywordTypeNode {
		return cast this;
	}

	public inline function AsUnionTypeNode():UnionTypeNode {
		return cast this;
	}

	public inline function AsIntersectionTypeNode():IntersectionTypeNode {
		return cast this;
	}

	public inline function AsConditionalTypeNode():ConditionalTypeNode {
		return cast this;
	}

	public inline function AsTypeOperatorNode():TypeOperatorNode {
		return cast this;
	}

	public inline function AsInferTypeNode():InferTypeNode {
		return cast this;
	}

	public inline function AsArrayTypeNode():ArrayTypeNode {
		return cast this;
	}

	public inline function AsIndexedAccessTypeNode():IndexedAccessTypeNode {
		return cast this;
	}

	public inline function AsTypeReferenceNode():TypeReferenceNode {
		return cast this;
	}

	public inline function AsExpressionWithTypeArguments():ExpressionWithTypeArguments {
		return cast this;
	}

	public inline function AsLiteralTypeNode():LiteralTypeNode {
		return cast this;
	}

	public inline function AsThisTypeNode():ThisTypeNode {
		return cast this;
	}

	public inline function AsTypePredicateNode():TypePredicateNode {
		return cast this;
	}

	public inline function AsImportAttribute():ImportAttribute {
		return cast this;
	}

	public inline function AsImportAttributes():ImportAttributes {
		return cast this;
	}

	public inline function AsTypeQueryNode():TypeQueryNode {
		return cast this;
	}

	public inline function AsMappedTypeNode():MappedTypeNode {
		return cast this;
	}

	public inline function AsTypeLiteralNode():TypeLiteralNode {
		return cast this;
	}

	public inline function AsTupleTypeNode():TupleTypeNode {
		return cast this;
	}

	public inline function AsNamedTupleMember():NamedTupleMember {
		return cast this;
	}

	public inline function AsOptionalTypeNode():OptionalTypeNode {
		return cast this;
	}

	public inline function AsRestTypeNode():RestTypeNode {
		return cast this;
	}

	public inline function AsParenthesizedTypeNode():ParenthesizedTypeNode {
		return cast this;
	}

	public inline function AsFunctionTypeNode():FunctionTypeNode {
		return cast this;
	}

	public inline function AsConstructorTypeNode():ConstructorTypeNode {
		return cast this;
	}

	public inline function AsTemplateHead():TemplateHead {
		return cast this;
	}

	public inline function AsTemplateMiddle():TemplateMiddle {
		return cast this;
	}

	public inline function AsTemplateTail():TemplateTail {
		return cast this;
	}

	public inline function AsTemplateLiteralTypeNode():TemplateLiteralTypeNode {
		return cast this;
	}

	public inline function AsTemplateLiteralTypeSpan():TemplateLiteralTypeSpan {
		return cast this;
	}

	public inline function AsSyntheticExpression():SyntheticExpression {
		return cast this;
	}

	public inline function AsPartiallyEmittedExpression():PartiallyEmittedExpression {
		return cast this;
	}

	public inline function AsJsxElement():JsxElement {
		return cast this;
	}

	public inline function AsJsxAttributes():JsxAttributes {
		return cast this;
	}

	public inline function AsJsxNamespacedName():JsxNamespacedName {
		return cast this;
	}

	public inline function AsJsxOpeningElement():JsxOpeningElement {
		return cast this;
	}

	public inline function AsJsxSelfClosingElement():JsxSelfClosingElement {
		return cast this;
	}

	public inline function AsJsxFragment():JsxFragment {
		return cast this;
	}

	public inline function AsJsxOpeningFragment():JsxOpeningFragment {
		return cast this;
	}

	public inline function AsJsxClosingFragment():JsxClosingFragment {
		return cast this;
	}

	public inline function AsJsxAttribute():JsxAttribute {
		return cast this;
	}

	public inline function AsJsxSpreadAttribute():JsxSpreadAttribute {
		return cast this;
	}

	public inline function AsJsxClosingElement():JsxClosingElement {
		return cast this;
	}

	public inline function AsJsxExpression():JsxExpression {
		return cast this;
	}

	public inline function AsJsxText():JsxText {
		return cast this;
	}

	public inline function AsSyntaxList():SyntaxList {
		return cast this;
	}

	public inline function AsJSDoc():JSDoc {
		return cast this;
	}

	public inline function AsJSDocTypeExpression():JSDocTypeExpression {
		return cast this;
	}

	public inline function AsJSDocNonNullableType():JSDocNonNullableType {
		return cast this;
	}

	public inline function AsJSDocNullableType():JSDocNullableType {
		return cast this;
	}

	public inline function AsJSDocAllType():JSDocAllType {
		return cast this;
	}

	public inline function AsJSDocVariadicType():JSDocVariadicType {
		return cast this;
	}

	public inline function AsJSDocOptionalType():JSDocOptionalType {
		return cast this;
	}

	public inline function AsJSDocTypeTag():JSDocTypeTag {
		return cast this;
	}

	public inline function AsJSDocUnknownTag():JSDocUnknownTag {
		return cast this;
	}

	public inline function AsJSDocTemplateTag():JSDocTemplateTag {
		return cast this;
	}

	public inline function AsJSDocReturnTag():JSDocReturnTag {
		return cast this;
	}

	public inline function AsJSDocPublicTag():JSDocPublicTag {
		return cast this;
	}

	public inline function AsJSDocPrivateTag():JSDocPrivateTag {
		return cast this;
	}

	public inline function AsJSDocProtectedTag():JSDocProtectedTag {
		return cast this;
	}

	public inline function AsJSDocReadonlyTag():JSDocReadonlyTag {
		return cast this;
	}

	public inline function AsJSDocOverrideTag():JSDocOverrideTag {
		return cast this;
	}

	public inline function AsJSDocDeprecatedTag():JSDocDeprecatedTag {
		return cast this;
	}

	public inline function AsJSDocSeeTag():JSDocSeeTag {
		return cast this;
	}

	public inline function AsJSDocImplementsTag():JSDocImplementsTag {
		return cast this;
	}

	public inline function AsJSDocAugmentsTag():JSDocAugmentsTag {
		return cast this;
	}

	public inline function AsJSDocSatisfiesTag():JSDocSatisfiesTag {
		return cast this;
	}

	public inline function AsJSDocThrowsTag():JSDocThrowsTag {
		return cast this;
	}

	public inline function AsJSDocThisTag():JSDocThisTag {
		return cast this;
	}

	public inline function AsJSDocImportTag():JSDocImportTag {
		return cast this;
	}

	public inline function AsJSDocCallbackTag():JSDocCallbackTag {
		return cast this;
	}

	public inline function AsJSDocOverloadTag():JSDocOverloadTag {
		return cast this;
	}

	public inline function AsJSDocTypedefTag():JSDocTypedefTag {
		return cast this;
	}

	public inline function AsJSDocSignature():JSDocSignature {
		return cast this;
	}

	public inline function AsJSDocNameReference():JSDocNameReference {
		return cast this;
	}

	public inline function AsSourceFile():SourceFile {
		return cast this;
	}

	public inline function AsModuleDeclaration():ModuleDeclaration {
		return cast this;
	}

	public inline function AsImportEqualsDeclaration():ImportEqualsDeclaration {
		return cast this;
	}

	public inline function AsExportDeclaration():ExportDeclaration {
		return cast this;
	}

	public inline function AsImportTypeNode():ImportTypeNode {
		return cast this;
	}

	public inline function AsImportClause():ImportClause {
		return cast this;
	}

	public inline function AsImportSpecifier():ImportSpecifier {
		return cast this;
	}

	public inline function AsJSDocText():JSDocText {
		return cast this;
	}

	public inline function AsJSDocLink():JSDocLink {
		return cast this;
	}

	public inline function AsJSDocLinkPlain():JSDocLinkPlain {
		return cast this;
	}

	public inline function AsJSDocLinkCode():JSDocLinkCode {
		return cast this;
	}

	public inline function AsTypeParameterDeclaration():TypeParameterDeclaration {
		return cast this;
	}

	public inline function AsSyntheticReferenceExpression():SyntheticReferenceExpression {
		return cast this;
	}

	public inline function AsJSDocTypeLiteral():JSDocTypeLiteral {
		return cast this;
	}

	public inline function AsJSDocParameterOrPropertyTag():JSDocParameterOrPropertyTag {
		return cast this;
	}
	// END GENERATED: as
}

// PORT: Go `type MutableNode Node` (same object, other method set).
abstract MutableNode(NodeDefault) from NodeDefault to NodeDefault {
	public function SetModifiers(modifiers:ModifierList):Void {
		this.setModifiers(modifiers);
	}

	public function SetExpression(expr:Node):Void {
		final n:Node = this;
		switch (n.Kind) {
			case KindPropertyAccessExpression:
				n.AsPropertyAccessExpression().Expression = expr;
			case KindElementAccessExpression:
				n.AsElementAccessExpression().Expression = expr;
			case KindParenthesizedExpression:
				n.AsParenthesizedExpression().Expression = expr;
			case KindCallExpression:
				n.AsCallExpression().Expression = expr;
			case KindNewExpression:
				n.AsNewExpression().Expression = expr;
			case KindExpressionWithTypeArguments:
				n.AsExpressionWithTypeArguments().Expression = expr;
			case KindComputedPropertyName:
				n.AsComputedPropertyName().Expression = expr;
			case KindNonNullExpression:
				n.AsNonNullExpression().Expression = expr;
			case KindTypeAssertionExpression:
				n.AsTypeAssertion().Expression = expr;
			case KindAsExpression:
				n.AsAsExpression().Expression = expr;
			case KindSatisfiesExpression:
				n.AsSatisfiesExpression().Expression = expr;
			case KindTypeOfExpression:
				n.AsTypeOfExpression().Expression = expr;
			case KindSpreadAssignment:
				n.AsSpreadAssignment().Expression = expr;
			case KindSpreadElement:
				n.AsSpreadElement().Expression = expr;
			case KindTemplateSpan:
				n.AsTemplateSpan().Expression = expr;
			case KindDeleteExpression:
				n.AsDeleteExpression().Expression = expr;
			case KindVoidExpression:
				n.AsVoidExpression().Expression = expr;
			case KindAwaitExpression:
				n.AsAwaitExpression().Expression = expr;
			case KindYieldExpression:
				n.AsYieldExpression().Expression = expr;
			case KindPartiallyEmittedExpression:
				n.AsPartiallyEmittedExpression().Expression = expr;
			case KindIfStatement:
				n.AsIfStatement().Expression = expr;
			case KindDoStatement:
				n.AsDoStatement().Expression = expr;
			case KindWhileStatement:
				n.AsWhileStatement().Expression = expr;
			case KindWithStatement:
				n.AsWithStatement().Expression = expr;
			case KindForInStatement | KindForOfStatement:
				n.AsForInOrOfStatement().Expression = expr;
			case KindSwitchStatement:
				n.AsSwitchStatement().Expression = expr;
			case KindCaseClause:
				n.AsCaseOrDefaultClause().Expression = expr;
			case KindExpressionStatement:
				n.AsExpressionStatement().Expression = expr;
			case KindReturnStatement:
				n.AsReturnStatement().Expression = expr;
			case KindThrowStatement:
				n.AsThrowStatement().Expression = expr;
			case KindExternalModuleReference:
				n.AsExternalModuleReference().Expression = expr;
			case KindExportAssignment:
				n.AsExportAssignment().Expression = expr;
			case KindDecorator:
				n.AsDecorator().Expression = expr;
			case KindJsxExpression:
				n.AsJsxExpression().Expression = expr;
			case KindJsxSpreadAttribute:
				n.AsJsxSpreadAttribute().Expression = expr;
			default:
				throw "Unhandled case in mutableNode.SetExpression: " + n.Kind.String();
		}
	}

	public function SetType(t:Node):Void {
		final n:Node = this;
		switch (n.Kind) {
			case KindVariableDeclaration:
				n.AsVariableDeclaration().Type = t;
			case KindParameter:
				n.AsParameterDeclaration().Type = t;
			case KindPropertySignature:
				n.AsPropertySignatureDeclaration().Type = t;
			case KindPropertyDeclaration:
				n.AsPropertyDeclaration().Type = t;
			case KindPropertyAssignment:
				n.AsPropertyAssignment().Type = t;
			case KindShorthandPropertyAssignment:
				n.AsShorthandPropertyAssignment().Type = t;
			case KindTypePredicate:
				n.AsTypePredicateNode().Type = t;
			case KindParenthesizedType:
				n.AsParenthesizedTypeNode().Type = t;
			case KindTypeOperator:
				n.AsTypeOperatorNode().Type = t;
			case KindMappedType:
				n.AsMappedTypeNode().Type = t;
			case KindTypeAssertionExpression:
				n.AsTypeAssertion().Type = t;
			case KindAsExpression:
				n.AsAsExpression().Type = t;
			case KindSatisfiesExpression:
				n.AsSatisfiesExpression().Type = t;
			case KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				n.AsTypeAliasDeclaration().Type = t;
			case KindNamedTupleMember:
				n.AsNamedTupleMember().Type = t;
			case KindOptionalType:
				n.AsOptionalTypeNode().Type = t;
			case KindRestType:
				n.AsRestTypeNode().Type = t;
			case KindTemplateLiteralTypeSpan:
				n.AsTemplateLiteralTypeSpan().Type = t;
			case KindJSDocTypeExpression:
				n.AsJSDocTypeExpression().Type = t;
			case KindJSDocParameterTag | KindJSDocPropertyTag:
				n.AsJSDocParameterOrPropertyTag().TypeExpression = t;
			case KindJSDocNullableType:
				n.AsJSDocNullableType().Type = t;
			case KindJSDocNonNullableType:
				n.AsJSDocNonNullableType().Type = t;
			case KindJSDocOptionalType:
				n.AsJSDocOptionalType().Type = t;
			case KindExportAssignment:
				n.AsExportAssignment().Type = t;
			case KindBinaryExpression:
				n.AsBinaryExpression().Type = t;
			default:
				final funcLike = n.FunctionLikeData();
				if (funcLike != null) {
					funcLike.Type = t;
				} else {
					throw "Unhandled case in mutableNode.SetType: " + n.Kind.String();
				}
		}
	}

	public function SetInitializer(initializer:Node):Void {
		final n:Node = this;
		switch (n.Kind) {
			case KindVariableDeclaration:
				n.AsVariableDeclaration().Initializer = initializer;
			case KindParameter:
				n.AsParameterDeclaration().Initializer = initializer;
			case KindBindingElement:
				n.AsBindingElement().Initializer = initializer;
			case KindPropertyDeclaration:
				n.AsPropertyDeclaration().Initializer = initializer;
			case KindPropertySignature:
				n.AsPropertySignatureDeclaration().Initializer = initializer;
			case KindPropertyAssignment:
				n.AsPropertyAssignment().Initializer = initializer;
			case KindEnumMember:
				n.AsEnumMember().Initializer = initializer;
			case KindForStatement:
				n.AsForStatement().Initializer = initializer;
			case KindForInStatement | KindForOfStatement:
				n.AsForInOrOfStatement().Initializer = initializer;
			case KindJsxAttribute:
				n.AsJsxAttribute().Initializer = initializer;
			default:
				throw "Unhandled case in mutableNode.SetInitializer";
		}
	}
}

// NodeDefault
// PORT: Go `NodeDefault` (embedded through NodeBase in every node data struct) + the fields of
// Go `Node`. The public non-inline methods are the nodeData interface: tools/gen/ast reads this
// class to decide which promoted methods are overrides.
// PORT: implements TypeSystemEntity (Go `any`, see Symbol.hx).
// PORT: perf — extends core.LinkHolder (the links of the checker's LinkStores, see there).
class NodeDefault extends ts.core.Linkstore.LinkHolder implements ts.ast.Symbol.TypeSystemEntity {
	public var Kind:Kind = 0;
	public var Flags:NodeFlags = 0;
	// PORT: Go `Loc core.TextRange` → two Int fields with an inline Loc property (no allocation).
	public var pos:Int = 0;
	public var end:Int = 0;
	public var Loc(get, set):TextRange;
	public var id:Int = 0; // PORT: atomic.Uint64 → Int (single-threaded; ids fit in 32 bits)
	public var Parent:Node = null;

	public function new() {
		super();
	}

	inline function get_Loc():TextRange {
		return new TextRange(pos, end);
	}

	inline function set_Loc(v:TextRange):TextRange {
		pos = v.Pos();
		end = v.End();
		return v;
	}

	public inline function AsNode():Node {
		return this;
	}

	// Go `(n *Node) Pos()` / `End()` (promoted into every node data struct).
	public inline function Pos():Int {
		return pos;
	}

	public inline function End():Int {
		return end;
	}

	public function ForEachChild(v:Visitor):Bool {
		return false;
	}

	public function VisitEachChild(v:NodeVisitor):Node {
		return AsNode();
	}

	public function Clone(v:NodeFactoryCoercible):Node {
		return null;
	}

	public function Name():DeclarationName {
		return null;
	}

	public function Modifiers():ModifierList {
		return null;
	}

	public function setModifiers(modifiers:ModifierList):Void {}

	public function FlowNodeData():FlowNodeBase {
		return null;
	}

	public function DeclarationData():DeclarationBase {
		return null;
	}

	public function ExportableData():ExportableBase {
		return null;
	}

	public function LocalsContainerData():LocalsContainerBase {
		return null;
	}

	public function FunctionLikeData():FunctionLikeBase {
		return null;
	}

	public function ClassLikeData():ClassLikeBase {
		return null;
	}

	public function BodyData():BodyBase {
		return null;
	}

	public function LiteralLikeData():LiteralLikeNodeBase {
		return null;
	}

	public function TemplateLiteralLikeData():TemplateLiteralLikeNodeBase {
		return null;
	}

	public function SubtreeFacts():SubtreeFacts {
		return subtreeFactsWorker(this);
	}

	public function subtreeFactsWorker(self:Node):SubtreeFacts {
		// To avoid excessive conditional checks, the default implementation of subtreeFactsWorker directly invokes
		// computeSubtreeFacts. More complex nodes should implement CompositeNodeBase, which overrides this
		// method to cache the result. `self` is passed along to ensure we lookup `computeSubtreeFacts` on the
		// correct type, as `CompositeNodeBase` does not, itself, inherit from `Node`.
		return self.computeSubtreeFacts();
	}

	public function computeSubtreeFacts():SubtreeFacts {
		return SubtreeFactsNone;
	}

	public function propagateSubtreeFacts():SubtreeFacts {
		return SubtreeFacts() & ~SubtreeExclusionsNode;
	}
}

// NodeBase: Go `type NodeBase struct { NodeDefault }` → NodeDefault (no extra members).

// Aliases for Node unions not covered by ast_generated.go

typedef NamedMember = Node; // Node with NamedMemberBase
typedef AnyValidImportOrReExport = Node; // (ImportDeclaration | ExportDeclaration | JSDocImportTag) & { moduleSpecifier: StringLiteral } | ImportEqualsDeclaration & { moduleReference: ExternalModuleReference & { expression: StringLiteral }} | RequireOrImportCall | ValidImportTypeNode
typedef ValidImportTypeNode = Node; // ImportType & { argument: LiteralTypeNode & { literal: StringLiteral } }
typedef TypeOnlyImportDeclaration = Node; // ImportClause | ImportEqualsDeclaration | ImportSpecifier | NamespaceImport with isTypeOnly: true
typedef StringLiteralLike = Node; // StringLiteral | NoSubstitutionTemplateLiteral
typedef ObjectLiteralLike = Node; // ObjectLiteralExpression | ObjectBindingPattern
typedef AnyImportOrRequireStatement = Node; // AnyImportSyntax | RequireVariableStatement

enum abstract AccessKind(Int) from Int to Int {
	var AccessKindRead = 0; // Only reads from a variable
	var AccessKindWrite = 1; // Only writes to a variable without ever reading it. E.g.: `x=1;`.
	var AccessKindReadWrite = 2; // Reads from and writes to a variable. E.g.: `f(x++);`, `x/=1`.
}

// PatternAmbientModule

class PatternAmbientModule {
	public var Pattern:Pattern = null;
	public var Symbol:Symbol = null;

	public function new() {}
}

enum abstract CommentDirectiveKind(Int) from Int to Int {
	var CommentDirectiveKindUnknown = 0;
	var CommentDirectiveKindExpectError = 1;
	var CommentDirectiveKindIgnore = 2;
}

class CommentDirective {
	public var Loc:TextRange = new TextRange(0, 0);
	public var Kind:CommentDirectiveKind = CommentDirectiveKindUnknown;

	public function new() {}
}

// SourceFile

class SourceFileMetaData {
	public var PackageJsonType:String = "";
	public var PackageJsonDirectory:String = "";
	public var ImpliedNodeFormat:ResolutionMode = ModuleKindNone;

	public function new() {}

	// PORT: Go value struct; copy before mutating a copy (PORTING.md §3).
	public function copy():SourceFileMetaData {
		final r = new SourceFileMetaData();
		r.PackageJsonType = PackageJsonType;
		r.PackageJsonDirectory = PackageJsonDirectory;
		r.ImpliedNodeFormat = ImpliedNodeFormat;
		return r;
	}
}

// SourceFileDataKey identifies lazily-computed data attached to a SourceFile by
// another package. Prefer regular SourceFile fields for ast-owned data.
@:allow(ts.ast)
class SourceFileDataKey<T> {
	final key:Int;

	function new(key:Int) {
		this.key = key;
	}
}

// PORT: sync.Once → `done` flag.
class SourceFileDataCell<T> {
	public var done:Bool = false;
	public var value:Null<T> = null;

	public function new() {}
}

class CheckJsDirective {
	public var Enabled:Bool = false;
	public var Range:CommentRange = null;

	public function new() {}
}

interface HasFileName {
	function FileName():String;
	function Path():Path;
}

class TokenCacheKey {
	public final parent:Node;
	public final loc:TextRange;

	public function new(parent:Node, loc:TextRange) {
		this.parent = parent;
		this.loc = loc;
	}
}

// PORT: Go embeds NodeBase, DeclarationBase, LocalsContainerBase and CompositeBase; flattened
// like the generated node classes (SourceFile is hand-written upstream too). sync.* fields are
// dropped (single-threaded); sync.Once → flags.
@:allow(ts.ast)
class SourceFile extends NodeDefault implements DeclarationBase implements LocalsContainerBase implements CompositeBase implements SourceFileLike {
	@:isVar public var Symbol(get, set):Symbol = null;
	@:isVar public var Locals(get, set):SymbolTable = null;
	@:isVar public var NextContainer(get, set):Node = null;
	@:isVar public var facts(get, set):Int = 0;

	inline function get_Symbol():Symbol
		return Symbol;

	inline function set_Symbol(v:Symbol):Symbol
		return Symbol = v;

	inline function get_Locals():SymbolTable
		return Locals;

	inline function set_Locals(v:SymbolTable):SymbolTable
		return Locals = v;

	inline function get_NextContainer():Node
		return NextContainer;

	inline function set_NextContainer(v:Node):Node
		return NextContainer = v;

	inline function get_facts():Int
		return facts;

	inline function set_facts(v:Int):Int
		return facts = v;

	// Fields set by NewSourceFile
	var fileName:String = ""; // For debugging convenience
	var parseOptions:SourceFileParseOptions = new SourceFileParseOptions();
	var text:String = "";

	public var Statements:NodeList = null; // NodeList[*Statement]
	public var EndOfFileToken:TokenNode = null; // TokenNode[*EndOfFileToken]

	// Fields for lazily-computed data owned by packages outside ast.
	var data:IntMap<Any> = null;

	// Fields set by parser
	var diagnostics:Array<Diagnostic> = null;
	var jsDiagnostics:Array<Diagnostic> = null;
	var jsdocDiagnostics:Array<Diagnostic> = null;

	public var LanguageVariant:LanguageVariant = 0;
	public var ScriptKind:ScriptKind = ScriptKindUnknown;
	public var IsDeclarationFile:Bool = false;
	public var ContainsNonASCII:Bool = false;
	public var UsesUriStyleNodeCoreModules:Tristate = TSUnknown;
	public var Identifiers:StringMap<String> = null;
	public var IdentifierCount:Int = 0;

	var imports:Array<LiteralLikeNode> = null; // []LiteralLikeNode

	public var ModuleAugmentations:Array<ModuleName> = null; // []ModuleName
	public var AmbientModuleNames:Array<String> = null;
	public var CommentDirectives:Array<CommentDirective> = null;

	var jsdocCache:IdentityMap<Node, Array<Node>> = null;
	var hasLazyJSDoc:Bool = false;

	public var ReparsedClones:Array<Node> = null;
	public var Pragmas:Array<Pragma> = null;
	public var ReferencedFiles:Array<FileReference> = null;
	public var TypeReferenceDirectives:Array<FileReference> = null;
	public var LibReferenceDirectives:Array<FileReference> = null;
	public var CheckJsDirective:CheckJsDirective = null;
	public var NodeCount:Int = 0;
	public var TextCount:Int = 0;
	public var CommonJSModuleIndicator:Node = null;
	// If this is the SourceFile itself, then this module was "forced"
	// to be an external module (previously "true").
	public var ExternalModuleIndicator:Node = null;

	// Fields set by binder

	var isBound:Bool = false;
	var bindOnceDone:Bool = false; // PORT: sync.Once

	var bindDiagnostics:Array<Diagnostic> = null;

	public var BindSuggestionDiagnostics:Array<Diagnostic> = null;
	public var EndFlowNode:FlowNode = null;
	public var SymbolCount:Int = 0;
	public var ClassifiableNames:Set<String> = new Set<String>();
	public var PatternAmbientModules:Array<PatternAmbientModule> = null;
	public var GlobalExports:SymbolTable = null;

	// Fields set by ECMALineMap

	var ecmaLineMap:Array<TextPos> = null;

	// Fields set by language service

	// PORT: `Hash xxh3.Uint128` is not ported yet (language service; package xxh3).
	// PORT: Go `map[TokenCacheKey]*Node` (struct key) → parent → "pos:end" → token.
	var tokenCache:IdentityMap<Node, StringMap<Node>> = null;
	var tokenFactory:NodeFactory = null;
	var declarationMap:StringMap<Array<Node>> = null;
	var nameTableDone:Bool = false; // PORT: sync.Once
	var nameTable:StringMap<Int> = null;

	// Fields for UTF-8 to UTF-16 position mapping

	var positionMapDone:Bool = false; // PORT: sync.Once
	var positionMap:PositionMap = null;

	public function new() {
		super();
	}

	public function ParseOptions():SourceFileParseOptions {
		return parseOptions;
	}

	public function Text():String {
		return text;
	}

	public function FileName():String {
		return parseOptions.FileName;
	}

	public function Path():Path {
		return parseOptions.Path;
	}

	public function Imports():Array<LiteralLikeNode> {
		return imports;
	}

	public function Diagnostics():Array<Diagnostic> {
		return diagnostics;
	}

	public function SetDiagnostics(diags:Array<Diagnostic>):Void {
		diagnostics = diags;
	}

	public function JSDiagnostics():Array<Diagnostic> {
		return jsDiagnostics;
	}

	public function SetJSDiagnostics(diags:Array<Diagnostic>):Void {
		jsDiagnostics = diags;
	}

	public function JSDocDiagnostics():Array<Diagnostic> {
		return jsdocDiagnostics;
	}

	public function SetJSDocDiagnostics(diags:Array<Diagnostic>):Void {
		jsdocDiagnostics = diags;
	}

	public function SetJSDocCache(cache:IdentityMap<Node, Array<Node>>):Void {
		jsdocCache = cache;
	}

	public function SetHasLazyJSDoc(lazy:Bool):Void {
		hasLazyJSDoc = lazy;
	}

	function resolveJSDoc(n:Node):Array<Node> {
		if (Ast.parseJSDocForNode == null) {
			throw "resolveJSDoc called but parseJSDocForNode is not registered; ensure the parser package is imported";
		}
		// Fast path: check cache under read lock
		if (jsdocCache != null && jsdocCache.exists(n)) {
			return jsdocCache.get(n);
		}

		// Slow path: parse and cache under write lock
		final jsdocs = Ast.parseJSDocForNode(this, n);
		if (jsdocCache == null) {
			jsdocCache = new IdentityMap<Node, Array<Node>>();
		}
		jsdocCache.set(n, jsdocs);
		return jsdocs;
	}

	public function BindDiagnostics():Array<Diagnostic> {
		return bindDiagnostics;
	}

	public function SetBindDiagnostics(diags:Array<Diagnostic>):Void {
		bindDiagnostics = diags;
	}

	override public function ForEachChild(v:Visitor):Bool {
		return Ast.visitNodeList(v, Statements) || Ast.visit(v, EndOfFileToken);
	}

	override public function VisitEachChild(v:NodeVisitor):Node {
		return v.Factory.UpdateSourceFile(this, v.visitTopLevelStatements(Statements), v.visitToken(EndOfFileToken));
	}

	public function IsJS():Bool {
		return Ast.IsSourceFileJS(this);
	}

	function copyFrom(other:SourceFile):Void {
		// Do not copy fields set by NewSourceFile (Text, FileName, Path, or Statements)
		LanguageVariant = other.LanguageVariant;
		ScriptKind = other.ScriptKind;
		IsDeclarationFile = other.IsDeclarationFile;
		ContainsNonASCII = other.ContainsNonASCII;
		UsesUriStyleNodeCoreModules = other.UsesUriStyleNodeCoreModules;
		Identifiers = other.Identifiers;
		imports = other.imports;
		ModuleAugmentations = other.ModuleAugmentations;
		AmbientModuleNames = other.AmbientModuleNames;
		CommentDirectives = other.CommentDirectives;
		Pragmas = other.Pragmas;
		ReferencedFiles = other.ReferencedFiles;
		TypeReferenceDirectives = other.TypeReferenceDirectives;
		LibReferenceDirectives = other.LibReferenceDirectives;
		CommonJSModuleIndicator = other.CommonJSModuleIndicator;
		ExternalModuleIndicator = other.ExternalModuleIndicator;
		Flags |= other.Flags;
	}

	override public function Clone(f:NodeFactoryCoercible):Node {
		final updated = f.AsNodeFactory().NewSourceFile(parseOptions, text, Statements, EndOfFileToken);
		final newFile = updated.AsSourceFile();
		newFile.copyFrom(this);
		return Ast.cloneNode(updated, AsNode(), f.AsNodeFactory().hooks);
	}

	override public function computeSubtreeFacts():SubtreeFacts {
		return Ast.propagateNodeListSubtreeFacts(Statements, Ast.propagateSubtreeFactsFunc);
	}

	// Promoted from the embedded bases (Go method promotion; see tools/gen/ast).

	override public function DeclarationData():DeclarationBase {
		return Ast.DeclarationBase_DeclarationData(this);
	}

	override public function LocalsContainerData():LocalsContainerBase {
		return Ast.LocalsContainerBase_LocalsContainerData(this);
	}

	override public function subtreeFactsWorker(self:Node):SubtreeFacts {
		return Ast.CompositeBase_subtreeFactsWorker(this, self);
	}

	// PORT: the RWMutex double-checked locking of Go collapses to one check (single-threaded).
	public function ECMALineMap():Array<TextPos> {
		var lineMap = ecmaLineMap;
		if (lineMap == null) {
			lineMap = Core.ComputeECMALineStarts(Text());
			ecmaLineMap = lineMap;
		}
		return lineMap;
	}

	// GetNameTable returns a map of all names in the file to their positions.
	// If the name appears more than once, the value is -1.
	public function GetNameTable():StringMap<Int> {
		if (!nameTableDone) {
			nameTableDone = true;
			final nameTable = new StringMap<Int>();

			var walk:(node:Node) -> Bool = null;
			walk = function(node:Node):Bool {
				if (Ast.IsIdentifier(node) && !Ast.IsTagName(node) && node.Text() != ""
					|| Ast.IsStringOrNumericLiteralLike(node) && Ast.literalIsName(node)
					|| Ast.IsPrivateIdentifier(node)) {
					final text = node.Text();
					if (nameTable.exists(text)) {
						nameTable.set(text, -1);
					} else {
						nameTable.set(text, node.Pos());
					}
				}

				node.ForEachChild(walk);
				final jsdocNodes = node.JSDoc(this);
				if (jsdocNodes != null) {
					for (jsdoc in jsdocNodes) {
						jsdoc.ForEachChild(walk);
					}
				}
				return false;
			};
			ForEachChild(walk);

			this.nameTable = nameTable;
		}
		return nameTable;
	}

	public function IsBound():Bool {
		return isBound;
	}

	// GetPositionMap returns the PositionMap for this source file, computing it lazily.
	public function GetPositionMap():PositionMap {
		if (!positionMapDone) {
			positionMapDone = true;
			if (!ContainsNonASCII) {
				final pm = new PositionMap();
				pm.asciiOnly = true;
				positionMap = pm;
			} else {
				positionMap = Ast.ComputePositionMap(Text());
			}
		}
		return positionMap;
	}

	public function BindOnce(bind:() -> Void):Void {
		if (!bindOnceDone) {
			bindOnceDone = true;
			bind();
			isBound = true;
		}
	}

	// Gets a token from the file's token cache, or creates it if it does not already exist.
	// This function should NOT be used for creating synthetic tokens that are not in the file in the first place.
	public function GetOrCreateToken(kind:Kind, pos:Int, end:Int, parent:Node, flags:TokenFlags):TokenNode {
		final loc = Core.NewTextRange(pos, end);
		final locKey = pos + ":" + end;
		final byLoc = tokenCache == null ? null : tokenCache.get(parent);
		if (byLoc != null && byLoc.exists(locKey)) {
			final token = byLoc.get(locKey);
			if (token.Kind != kind) {
				throw 'Token cache mismatch: ${token.Kind.String()} != ${kind.String()}';
			}
			return token;
		}
		if (parent.Flags & NodeFlagsReparsed != 0) {
			throw 'Cannot create token from reparsed node of kind ${parent.Kind.String()}';
		}
		if (tokenCache == null) {
			tokenCache = new IdentityMap<Node, StringMap<Node>>();
		}
		final token = Ast.createToken(kind, this, pos, end, flags);
		token.Loc = loc;
		token.Parent = parent;
		var m = tokenCache.get(parent);
		if (m == null) {
			m = new StringMap<Node>();
			tokenCache.set(parent, m);
		}
		m.set(locKey, token);
		return token;
	}

	public function GetDeclarationMap():StringMap<Array<Node>> {
		if (declarationMap == null) {
			declarationMap = computeDeclarationMap();
		}
		return declarationMap;
	}

	function computeDeclarationMap():StringMap<Array<Node>> {
		final result = new StringMap<Array<Node>>();

		final addDeclaration = function(declaration:Node):Void {
			final name = Ast.GetDeclarationName(declaration);
			if (name != "") {
				var list = result.get(name);
				if (list == null) {
					list = [];
					result.set(name, list);
				}
				list.push(declaration);
			}
		};

		var visit:(node:Node) -> Bool = null;
		visit = function(node:Node):Bool {
			// PORT: `fallthrough` from KindParameter into the variable case → local function.
			function variableCase():Void {
				final name = node.Name();
				if (name != null) {
					if (Ast.IsBindingPattern(name)) {
						node.Name().ForEachChild(visit);
					} else {
						if (node.Initializer() != null) {
							visit(node.Initializer());
						}
						addDeclaration(node);
					}
				}
			}
			switch (node.Kind) {
				case KindFunctionDeclaration | KindFunctionExpression | KindMethodDeclaration | KindMethodSignature:
					final declarationName = Ast.GetDeclarationName(node);
					if (declarationName != "") {
						final declarations = result.get(declarationName);
						var lastDeclaration:Node = null;
						if (Core.len(declarations) != 0) {
							lastDeclaration = declarations[declarations.length - 1];
						}
						// Check whether this declaration belongs to an "overload group".
						if (lastDeclaration != null && node.Parent == lastDeclaration.Parent && node.Symbol() == lastDeclaration.Symbol()) {
							// Overwrite the last declaration if it was an overload and this one is an implementation.
							if (node.Body() != null && lastDeclaration.Body() == null) {
								declarations[declarations.length - 1] = node;
							}
						} else {
							var list = result.get(declarationName);
							if (list == null) {
								list = [];
								result.set(declarationName, list);
							}
							list.push(node);
						}
					}
					node.ForEachChild(visit);
				case KindClassDeclaration | KindClassExpression | KindInterfaceDeclaration | KindTypeAliasDeclaration | KindEnumDeclaration |
					KindModuleDeclaration | KindImportEqualsDeclaration | KindImportClause | KindNamespaceImport | KindGetAccessor | KindSetAccessor |
					KindTypeLiteral:
					addDeclaration(node);
					node.ForEachChild(visit);
				case KindImportSpecifier | KindExportSpecifier:
					if (node.PropertyName() != null) {
						addDeclaration(node);
					}
				case KindParameter:
					// Only consider parameter properties
					if (Ast.HasSyntacticModifier(node, ModifierFlagsParameterPropertyModifier)) {
						variableCase();
					}
				case KindVariableDeclaration | KindBindingElement:
					variableCase();
				case KindEnumMember | KindPropertyDeclaration | KindPropertySignature:
					addDeclaration(node);
				case KindExportDeclaration:
					// Handle named exports case e.g.:
					//    export {a, b as B} from "mod";
					final exportClause = node.AsExportDeclaration().ExportClause;
					if (exportClause != null) {
						if (Ast.IsNamedExports(exportClause)) {
							for (element in exportClause.Elements()) {
								visit(element);
							}
						} else {
							visit(exportClause.AsNamespaceExport().Name());
						}
					}
				case KindImportDeclaration:
					final importClause = node.AsImportDeclaration().ImportClause;
					if (importClause != null) {
						// Handle default import case e.g.:
						//    import d from "mod";
						if (importClause.Name() != null) {
							addDeclaration(importClause.Name());
						}
						// Handle named bindings in imports e.g.:
						//    import * as NS from "mod";
						//    import {a, b as B} from "mod";
						final namedBindings = importClause.AsImportClause().NamedBindings;
						if (namedBindings != null) {
							if (namedBindings.Kind == KindNamespaceImport) {
								addDeclaration(namedBindings);
							} else {
								for (element in namedBindings.Elements()) {
									visit(element);
								}
							}
						}
					}
				case KindBinaryExpression:
					switch (Ast.GetAssignmentDeclarationKind(node)) {
						case JSDeclarationKindExportsProperty | JSDeclarationKindThisProperty | JSDeclarationKindProperty:
							addDeclaration(node);
						default:
					}
					node.ForEachChild(visit);
				default:
					node.ForEachChild(visit);
			}
			return false;
		};
		ForEachChild(visit);
		return result;
	}
}

interface SourceFileLike {
	function Text():String;
	function ECMALineMap():Array<TextPos>;
}

// PORT: Go embeds core.TextRange (a value): composition field `TextRange` (PORTING.md §3) plus the
// promoted Pos()/End() methods. Value struct: copy() before mutating a copy.
class CommentRange {
	public var TextRange:TextRange;
	public var Kind:Kind;
	public var HasTrailingNewLine:Bool;

	public function new(textRange:TextRange, kind:Kind, hasTrailingNewLine:Bool) {
		this.TextRange = textRange;
		this.Kind = kind;
		this.HasTrailingNewLine = hasTrailingNewLine;
	}

	public inline function Pos():Int {
		return TextRange.Pos();
	}

	public inline function End():Int {
		return TextRange.End();
	}

	public function copy():CommentRange {
		return new CommentRange(TextRange, Kind, HasTrailingNewLine);
	}
}

// PORT: embedded core.TextRange → composition field + promoted Pos()/End() (see CommentRange).
class FileReference {
	public var TextRange:TextRange = new TextRange(0, 0);
	public var FileName:String = "";
	public var ResolutionMode:ResolutionMode = ModuleKindNone;
	public var Preserve:Bool = false;

	public function new() {}

	public inline function Pos():Int {
		return TextRange.Pos();
	}

	public inline function End():Int {
		return TextRange.End();
	}

	public function copy():FileReference {
		final r = new FileReference();
		r.TextRange = TextRange;
		r.FileName = FileName;
		r.ResolutionMode = ResolutionMode;
		r.Preserve = Preserve;
		return r;
	}
}

// PORT: embedded core.TextRange → composition field + promoted Pos()/End() (see CommentRange).
class PragmaArgument {
	public var TextRange:TextRange = new TextRange(0, 0);
	public var Name:String = "";
	public var Value:String = "";

	public function new() {}

	public inline function Pos():Int {
		return TextRange.Pos();
	}

	public inline function End():Int {
		return TextRange.End();
	}

	public function copy():PragmaArgument {
		final r = new PragmaArgument();
		r.TextRange = TextRange;
		r.Name = Name;
		r.Value = Value;
		return r;
	}
}

// PORT: embedded CommentRange → composition field (PORTING.md §3).
class Pragma {
	public var CommentRange:CommentRange = new CommentRange(new TextRange(0, 0), KindUnknown, false);
	public var Name:String = "";
	public var Args:StringMap<PragmaArgument> = null;

	public function new() {}
}

// PORT: Go `type PragmaKindFlags = uint8` → Int (the constants are statics of Ast).
typedef PragmaKindFlags = Int;


class PragmaArgumentSpecification {
	public var Name:String = "";
	public var Optional:Bool = false;
	public var CaptureSpan:Bool = false;

	public function new() {}
}

class PragmaSpecification {
	public var Args:Array<PragmaArgumentSpecification> = null;
	public var Kind:PragmaKindFlags = 0;

	public function new() {}

	public function IsTripleSlash():Bool {
		return (Kind & Ast.PragmaKindTripleSlashXML) > 0;
	}
}
