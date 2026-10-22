package ts.binder;

// Port of internal/binder (binder.go, nameresolver.go, referenceresolver.go).
//
// Module layout (PORTING.md §1/§2):
//   Binder.hx             class Binder: the Go Binder struct and the methods of binder.go, plus
//                         all package-level funcs of the package (Go file order,
//                         `// --- file.go ---`). The other types of binder.go.
//   Nameresolver.hx       type NameResolver of nameresolver.go with its methods.
//   Referenceresolver.hx  types of referenceresolver.go with their methods.
//
// PORT: method values. Go passes method expressions `(*Binder).bind`,
// `(*Binder).bindOptionalChainRest`, `(*ActiveLabel).BreakTarget` and
// `(*ActiveLabel).ContinueTarget` (no allocation); here each one is a static final function
// value `fn_<name>` created once, so no function value is created per call (PORTING.md §7a).
// Non-capturing Go func literals are static finals too (`fl_*`).
enum abstract ContainerFlags(Int) from Int to Int {
	@:op(A | B) static function or(a:ContainerFlags, b:ContainerFlags):ContainerFlags;
	@:op(A & B) static function and(a:ContainerFlags, b:ContainerFlags):ContainerFlags;
	@:op(~A) static function not(a:ContainerFlags):ContainerFlags;

	// The current node is not a container, and no container manipulation should happen before
	// recursing into it.
	var ContainerFlagsNone = 0;
	// The current node is a container.  It should be set as the current container (and block-
	// container) before recursing into it.  The current node does not have locals.  Examples:
	//
	//      Classes, ObjectLiterals, TypeLiterals, Interfaces...
	var ContainerFlagsIsContainer = 1 << 0;
	// The current node is a block-scoped-container.  It should be set as the current block-
	// container before recursing into it.  Examples:
	//
	//      Blocks (when not parented by functions), Catch clauses, For/For-in/For-of statements...
	var ContainerFlagsIsBlockScopedContainer = 1 << 1;
	// The current node is the container of a control flow path. The current control flow should
	// be saved and restored, and a new control flow initialized within the container.
	var ContainerFlagsIsControlFlowContainer = 1 << 2;
	var ContainerFlagsIsFunctionLike = 1 << 3;
	var ContainerFlagsIsFunctionExpression = 1 << 4;
	var ContainerFlagsHasLocals = 1 << 5;
	var ContainerFlagsIsInterface = 1 << 6;
	var ContainerFlagsIsObjectLiteralOrClassExpressionMethodOrAccessor = 1 << 7;
	var ContainerFlagsIsThisContainer = 1 << 8;
	var ContainerFlagsPropagatesThisKeyword = 1 << 9;
}

class ExpandoAssignmentInfo {
	public var node:Node = null;
	public var container:Node = null;
	public var blockScopeContainer:Node = null;

	public function new(node:Node, container:Node, blockScopeContainer:Node) {
		this.node = node;
		this.container = container;
		this.blockScopeContainer = blockScopeContainer;
	}
}

class ActiveLabel {
	public var next:ActiveLabel = null;
	public var breakTarget:FlowLabel = null;
	public var continueTarget:FlowLabel = null;
	public var name:String = "";
	public var referenced:Bool = false;

	public function new() {}

	public function BreakTarget():FlowNode {
		return breakTarget;
	}

	public function ContinueTarget():FlowNode {
		return continueTarget;
	}
}

@:allow(ts.binder)
class Binder {
	// --- binder.go ---

	var file:SourceFile = null;
	var bindFunc:(node:Node) -> Bool = null;
	var unreachableFlow:FlowNode = null;

	var container:Node = null;
	var thisContainer:Node = null;
	var blockScopeContainer:Node = null;
	var lastContainer:Node = null;
	var currentFlow:FlowNode = null;
	var currentBreakTarget:FlowLabel = null;
	var currentContinueTarget:FlowLabel = null;
	var currentReturnTarget:FlowLabel = null;
	var currentTrueTarget:FlowLabel = null;
	var currentFalseTarget:FlowLabel = null;
	var currentExceptionTarget:FlowLabel = null;
	var preSwitchCaseFlow:FlowNode = null;
	var activeLabelList:ActiveLabel = null;
	var emitFlags:NodeFlags = NodeFlagsNone;
	var seenThisKeyword:Bool = false;
	var hasExplicitReturn:Bool = false;
	var hasFlowEffects:Bool = false;
	var inAssignmentPattern:Bool = false;
	var seenParseError:Bool = false;
	var symbolCount:Int = 0;
	var classifiableNames:Set<String> = new Set<String>();
	var notConstEnumOnlyModules:Set<Symbol> = new Set<Symbol>();
	var symbolArena:Arena<Symbol> = new Arena<Symbol>(() -> new Symbol());
	var flowNodeArena:Arena<FlowNode> = new Arena<FlowNode>(() -> new FlowNode());
	var flowListArena:Arena<FlowList> = new Arena<FlowList>(() -> new FlowList());
	var singleDeclarationsArena:Arena<Node> = new Arena<Node>(() -> null);
	var expandoAssignments:Array<ExpandoAssignmentInfo> = null;

	function new() {}

	// PORT: method values (see the module header).
	static final fn_bind:(b:Binder, node:Node) -> Bool = (b, node) -> b.bind(node);
	static final fn_bindOptionalChainRest:(b:Binder, node:Node) -> Bool = (b, node) -> b.bindOptionalChainRest(node);
	static final fn_BreakTarget:(label:ActiveLabel) -> FlowNode = label -> label.BreakTarget();
	static final fn_ContinueTarget:(label:ActiveLabel) -> FlowNode = label -> label.ContinueTarget();

	public static function BindSourceFile(file:SourceFile):Void {
		// This is constructed this way to make the compiler "out-line" the function,
		// avoiding most work in the common case where the file has already been bound.
		if (!file.IsBound()) {
			bindSourceFile(file);
		}
	}

	// PORT: sync.Pool → a plain free list (single-threaded).
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — a free list per thread (go.Par.slot)
	static final binderPools:Array<Array<Binder>> = [for (_ in 0...go.Par.SLOTS) []];
	static var binderPool(get, never):Array<Binder>;

	static inline function get_binderPool()
		return binderPools[go.Par.slot];
	#else
	static final binderPool:Array<Binder> = [];
	#end

	static function newPooledBinder():Binder {
		final b = new Binder();
		b.bindFunc = b.bind; // Allocate closure once
		return b;
	}

	static function getBinder():Binder {
		if (binderPool.length > 0) {
			return binderPool.pop();
		}
		return newPooledBinder();
	}

	static function putBinder(b:Binder):Void {
		// *b = Binder{bindFunc: b.bindFunc}
		b.reset();
		binderPool.push(b);
	}

	// PORT: Go `*b = Binder{bindFunc: b.bindFunc}`: every other field gets its zero value.
	function reset():Void {
		file = null;
		unreachableFlow = null;
		container = null;
		thisContainer = null;
		blockScopeContainer = null;
		lastContainer = null;
		currentFlow = null;
		currentBreakTarget = null;
		currentContinueTarget = null;
		currentReturnTarget = null;
		currentTrueTarget = null;
		currentFalseTarget = null;
		currentExceptionTarget = null;
		preSwitchCaseFlow = null;
		activeLabelList = null;
		emitFlags = NodeFlagsNone;
		seenThisKeyword = false;
		hasExplicitReturn = false;
		hasFlowEffects = false;
		inAssignmentPattern = false;
		seenParseError = false;
		symbolCount = 0;
		classifiableNames = new Set<String>();
		notConstEnumOnlyModules = new Set<Symbol>();
		// PORT: the arenas only hold a factory (no backing storage); they need no reset.
		expandoAssignments = null;
	}

	static function bindSourceFile(file:SourceFile):Void {
		file.BindOnce(function() {
			final b = getBinder();
			// PORT: defer putBinder(b)
			try {
				b.file = file;
				b.unreachableFlow = b.newFlowNode(FlowFlagsUnreachable);
				b.bind(file.AsNode());
				b.bindDeferredExpandoAssignments();
				file.SymbolCount = b.symbolCount;
				file.ClassifiableNames = b.classifiableNames;
			} catch (e:Dynamic) {
				putBinder(b);
				throw e;
			}
			putBinder(b);
		});
	}

	function newSymbol(flags:SymbolFlags, name:std.String):Symbol {
		symbolCount++;
		final result = symbolArena.New();
		result.Flags = flags;
		result.Name = name;
		return result;
	}

	/**
	 * Declares a Symbol for the node and adds it to symbols. Reports errors for conflicting identifier names.
	 * @param symbolTable - The symbol table which node will be added to.
	 * @param parent - node's parent declaration.
	 * @param node - The declaration to be added to the symbol table
	 * @param includes - The SymbolFlags that node has in addition to its declaration type (eg: export, ambient, etc.)
	 * @param excludes - The flags which node cannot be declared alongside in a symbol table. Used to report forbidden declarations.
	 */
	function declareSymbol(symbolTable:SymbolTable, parent:Symbol, node:Node, includes:SymbolFlags, excludes:SymbolFlags):Symbol {
		return declareSymbolEx(symbolTable, parent, node, includes, excludes, false /*isReplaceableByMethod*/, false /*isComputedName*/);
	}

	function declareSymbolEx(symbolTable:SymbolTable, parent:Symbol, node:Node, includes:SymbolFlags, excludes:SymbolFlags, isReplaceableByMethod:Bool,
			isComputedName:Bool):Symbol {
		Debug.Assert(isComputedName || !Ast.HasDynamicName(node));
		final isDefaultExport = Ast.HasSyntacticModifier(node, ModifierFlagsDefault)
			|| Ast.IsExportSpecifier(node) && Ast.ModuleExportNameIsDefault(node.AsExportSpecifier().Name());
		// The exported symbol for an export default function/class node is always named "default"
		var name:std.String;
		if (isComputedName) {
			name = Ast.InternalSymbolNameComputed;
		} else if (isDefaultExport && parent != null) {
			name = Ast.InternalSymbolNameDefault;
		} else {
			name = getDeclarationName(node);
		}
		var symbol:Symbol = null;
		if (name == Ast.InternalSymbolNameMissing) {
			symbol = newSymbol(SymbolFlagsNone, Ast.InternalSymbolNameMissing);
		} else {
			// Check and see if the symbol table already has a symbol with this name.  If not,
			// create a new symbol with this name and add it to the table.  Note that we don't
			// give the new symbol any flags *yet*.  This ensures that it will not conflict
			// with the 'excludes' flags we pass in.
			//
			// If we do get an existing symbol, see if it conflicts with the new symbol we're
			// creating.  For example, a 'var' symbol and a 'class' symbol will conflict within
			// the same symbol table.  If we have a conflict, report the issue on each
			// declaration we have for this symbol, and then create a new symbol for this
			// declaration.
			//
			// Note that when properties declared in Javascript constructors
			// (marked by isReplaceableByMethod) conflict with another symbol, the property loses.
			// Always. This allows the common Javascript pattern of overwriting a prototype method
			// with an bound instance method of the same type: `this.method = this.method.bind(this)`
			//
			// If we created a new symbol, either because we didn't have a symbol with this name
			// in the symbol table, or we conflicted with an existing symbol, then just add this
			// node as the sole declaration of the new symbol.
			//
			// Otherwise, we'll be merging into a compatible existing symbol (for example when
			// you have multiple 'vars' with the same name in the same container).  In this case
			// just add this node into the declarations list of the symbol.
			symbol = symbolTable.get(name);
			if (includes & SymbolFlagsClassifiable != 0) {
				classifiableNames.Add(name);
			}
			if (symbol == null) {
				symbol = newSymbol(SymbolFlagsNone, name);
				symbolTable.set(name, symbol);
				if (isReplaceableByMethod) {
					symbol.Flags |= SymbolFlagsReplaceableByMethod;
				}
			} else if (isReplaceableByMethod && symbol.Flags & SymbolFlagsReplaceableByMethod == 0) {
				// A symbol already exists, so don't add this as a declaration.
				return symbol;
			} else if (symbol.Flags & excludes != 0) {
				if (symbol.Flags & SymbolFlagsReplaceableByMethod != 0) {
					// Javascript constructor-declared symbols can be discarded in favor of
					// prototype symbols like methods.
					symbol = newSymbol(SymbolFlagsNone, name);
					symbolTable.set(name, symbol);
				} else if (!(includes & SymbolFlagsVariable != 0 && symbol.Flags & SymbolFlagsAssignment != 0
					|| includes & SymbolFlagsAssignment != 0 && symbol.Flags & SymbolFlagsVariable != 0)) {
					// Assignment declarations are allowed to merge with variables, no matter what other flags they have.
					// Report errors every position with duplicate declaration
					// Report errors on previous encountered declarations
					var message:Message;
					if (symbol.Flags & SymbolFlagsBlockScopedVariable != 0) {
						message = Diagnostics.Cannot_redeclare_block_scoped_variable_0;
					} else {
						message = Diagnostics.Duplicate_identifier_0;
					}
					var messageNeedsName = true;
					if (symbol.Flags & SymbolFlagsEnum != 0 || includes & SymbolFlagsEnum != 0) {
						message = Diagnostics.Enum_declarations_can_only_merge_with_namespace_or_other_enum_declarations;
						messageNeedsName = false;
					}
					var multipleDefaultExports = false;
					if (Core.len(symbol.Declarations) != 0) {
						// If the current node is a default export of some sort, then check if
						// there are any other default exports that we need to error on.
						// We'll know whether we have other default exports depending on if `symbol` already has a declaration list set.
						if (isDefaultExport) {
							message = Diagnostics.A_module_cannot_have_multiple_default_exports;
							messageNeedsName = false;
							multipleDefaultExports = true;
						} else {
							// This is to properly report an error in the case "export default { }" is after export default of class declaration or function declaration.
							// Error on multiple export default in the following case:
							// 1. multiple export default of class declaration or function declaration by checking NodeFlags.Default
							// 2. multiple export default of export assignment. This one doesn't have NodeFlags.Default on (as export default doesn't considered as modifiers)
							if (Core.len(symbol.Declarations) != 0 && Ast.IsExportAssignment(node) && !node.AsExportAssignment().IsExportEquals) {
								message = Diagnostics.A_module_cannot_have_multiple_default_exports;
								messageNeedsName = false;
								multipleDefaultExports = true;
							}
						}
					}
					var declarationName:Node = Ast.GetNameOfDeclaration(node);
					if (declarationName == null) {
						declarationName = node;
					}
					var diag:Diagnostic;
					if (messageNeedsName) {
						diag = createDiagnosticForNode(declarationName, message, getDisplayName(node));
					} else {
						diag = createDiagnosticForNode(declarationName, message);
					}
					if (Ast.IsTypeAliasDeclaration(node) && Ast.NodeIsMissing(node.Type()) && Ast.HasSyntacticModifier(node, ModifierFlagsExport)
						&& symbol.Flags & (SymbolFlagsAlias | SymbolFlagsType | SymbolFlagsNamespace) != 0) {
						// export type T; - may have meant export type { T }?
						diag.AddRelatedInfo(createDiagnosticForNode(node, Diagnostics.Did_you_mean_0,
							"export type { " + node.AsTypeAliasDeclaration().Name().Text() + " }"));
					}
					if (symbol.Declarations != null) {
						for (index in 0...symbol.Declarations.length) {
							final declaration = symbol.Declarations[index];
							var decl:Node = Ast.GetNameOfDeclaration(declaration);
							if (decl == null) {
								decl = declaration;
							}
							var d:Diagnostic;
							if (messageNeedsName) {
								d = createDiagnosticForNode(decl, message, getDisplayName(declaration));
							} else {
								d = createDiagnosticForNode(decl, message);
							}
							if (multipleDefaultExports) {
								d.AddRelatedInfo(createDiagnosticForNode(declarationName,
									Core.IfElse(index == 0, Diagnostics.Another_export_default_is_here, Diagnostics.X_and_here)));
							}
							addDiagnostic(d);
							if (multipleDefaultExports) {
								diag.AddRelatedInfo(createDiagnosticForNode(decl, Diagnostics.The_first_export_default_is_here));
							}
						}
					}
					addDiagnostic(diag);
					// When get or set accessor conflicts with a non-accessor or an accessor of a different kind, we mark
					// the symbol as a full accessor such that all subsequent declarations are considered conflicting. This
					// for example ensures that a get accessor followed by a non-accessor followed by a set accessor with the
					// same name are all marked as duplicates.
					if (symbol.Flags & SymbolFlagsAccessor != 0 && (symbol.Flags & SymbolFlagsAccessor : Int) != (includes & SymbolFlagsAccessor : Int)) {
						symbol.Flags |= SymbolFlagsAccessor;
					}
					symbol = newSymbol(SymbolFlagsNone, name);
				}
			}
		}
		addDeclarationToSymbol(symbol, node, includes);
		if (symbol.Parent == null) {
			symbol.Parent = parent;
		} else if (symbol.Parent != parent) {
			throw "Existing symbol parent should match new one";
		}
		return symbol;
	}

	// Should not be called on a declaration with a computed property name,
	// unless it is a well known Symbol.
	function getDeclarationName(node:Node):std.String {
		if (Ast.IsExportAssignment(node)) {
			return Core.IfElse(node.AsExportAssignment().IsExportEquals, Ast.InternalSymbolNameExportEquals, Ast.InternalSymbolNameDefault);
		}
		final name = Ast.GetNameOfDeclaration(node);
		if (name != null) {
			if (Ast.IsAmbientModule(node)) {
				final moduleName = name.Text();
				if (Ast.IsGlobalScopeAugmentation(node)) {
					return Ast.InternalSymbolNameGlobal;
				}
				return "\"" + moduleName + "\"";
			}
			if (Ast.IsPrivateIdentifier(name)) {
				// containingClass exists because private names only allowed inside classes
				final containingClass = Ast.GetContainingClass(node);
				if (containingClass == null) {
					// we can get here in cases where there is already a parse error.
					return Ast.InternalSymbolNameMissing;
				}
				return GetSymbolNameForPrivateIdentifier(containingClass.Symbol(), name.Text());
			}
			if (Ast.IsPropertyNameLiteral(name) || Ast.IsJsxNamespacedName(name)) {
				return name.Text();
			}
			if (Ast.IsComputedPropertyName(name)) {
				final nameExpression = name.Expression();
				// treat computed property names where expression is string/numeric literal as just string/numeric literal
				if (Ast.IsStringOrNumericLiteralLike(nameExpression)) {
					return nameExpression.Text();
				}
				if (Ast.IsSignedNumericLiteral(nameExpression)) {
					final unaryExpression = nameExpression.AsPrefixUnaryExpression();
					return Scanner.TokenToString(unaryExpression.Operator) + unaryExpression.Operand.Text();
				}
				throw "Only computed properties with literal names have declaration names";
			}
			return Ast.InternalSymbolNameMissing;
		}
		switch (node.Kind) {
			case KindConstructor:
				return Ast.InternalSymbolNameConstructor;
			case KindFunctionType | KindCallSignature:
				return Ast.InternalSymbolNameCall;
			case KindConstructorType | KindConstructSignature:
				return Ast.InternalSymbolNameNew;
			case KindIndexSignature:
				return Ast.InternalSymbolNameIndex;
			case KindExportDeclaration:
				return Ast.InternalSymbolNameExportStar;
			case KindSourceFile | KindBinaryExpression:
				return Ast.InternalSymbolNameExportEquals;
			default:
		}
		return Ast.InternalSymbolNameMissing;
	}

	function getDisplayName(node:Node):std.String {
		final nameNode = node.Name();
		if (nameNode != null) {
			return Scanner.DeclarationNameToString(nameNode);
		}
		final name = getDeclarationName(node);
		if (name != Ast.InternalSymbolNameMissing) {
			return name;
		}
		return "(Missing)";
	}

	public static function GetSymbolNameForPrivateIdentifier(containingClassSymbol:Symbol, description:std.String):std.String {
		return Ast.InternalSymbolNamePrefix + "#" + Std.string((Ast.GetSymbolId(containingClassSymbol) : Int)) + "@" + description;
	}

	function declareModuleMember(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Symbol {
		final container = this.container;
		final hasExportModifier = Ast.GetCombinedModifierFlags(node) & ModifierFlagsExport != 0 || Ast.IsImplicitlyExportedJSDocDeclaration(node);
		if (symbolFlags & SymbolFlagsAlias != 0) {
			if (node.Kind == KindExportSpecifier || (node.Kind == KindImportEqualsDeclaration && hasExportModifier)) {
				return declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
			}
			return declareSymbol(Ast.GetLocals(container), null /*parent*/, node, symbolFlags, symbolExcludes);
		}
		// Exported module members are given 2 symbols: A local symbol that is classified with an ExportValue flag,
		// and an associated export symbol with all the correct flags set on it. There are 2 main reasons:
		//
		//   1. We treat locals and exports of the same name as mutually exclusive within a container.
		//      That means the binder will issue a Duplicate Identifier error if you mix locals and exports
		//      with the same name in the same container.
		//      TODO: Make this a more specific error and decouple it from the exclusion logic.
		//   2. When we checkIdentifier in the checker, we set its resolved symbol to the local symbol,
		//      but return the export symbol (by calling getExportSymbolOfValueSymbolIfExported). That way
		//      when the emitter comes back to it, it knows not to qualify the name if it was found in a containing scope.
		//
		// NOTE: Nested ambient modules always should go to to 'locals' table to prevent their automatic merge
		//       during global merging in the checker. Why? The only case when ambient module is permitted inside another module is module augmentation
		//       and this case is specially handled. Module augmentations should only be merged with original module definition
		//       and should never be merged directly with other augmentation, and the latter case would be possible if automatic merge is allowed.
		if (!Ast.IsAmbientModule(node) && (hasExportModifier || container.Flags & NodeFlagsExportContext != 0)) {
			if (!Ast.IsLocalsContainer(container) || (Ast.HasSyntacticModifier(node, ModifierFlagsDefault) && getDeclarationName(node) == Ast.InternalSymbolNameMissing)) {
				return declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
				// No local symbol for an unnamed default!
			}
			var exportKind = SymbolFlagsNone;
			if (symbolFlags & SymbolFlagsValue != 0) {
				exportKind = SymbolFlagsExportValue;
			}
			final local = declareSymbol(Ast.GetLocals(container), null /*parent*/, node, exportKind, symbolExcludes);
			local.ExportSymbol = declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
			node.ExportableData().LocalSymbol = local;
			return local;
		}
		return declareSymbol(Ast.GetLocals(container), null /*parent*/, node, symbolFlags, symbolExcludes);
	}

	function declareClassMember(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Symbol {
		if (Ast.IsStatic(node)) {
			return declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
		}
		return declareSymbol(Ast.GetMembers(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
	}

	function declareSourceFileMember(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Symbol {
		if (Ast.IsExternalModule(file)) {
			return declareModuleMember(node, symbolFlags, symbolExcludes);
		}
		return declareSymbol(Ast.GetLocals(file.AsNode()), null /*parent*/, node, symbolFlags, symbolExcludes);
	}

	function declareSymbolAndAddToSymbolTable(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Symbol {
		switch (container.Kind) {
			case KindModuleDeclaration:
				return declareModuleMember(node, symbolFlags, symbolExcludes);
			case KindSourceFile:
				return declareSourceFileMember(node, symbolFlags, symbolExcludes);
			case KindClassExpression | KindClassDeclaration:
				return declareClassMember(node, symbolFlags, symbolExcludes);
			case KindEnumDeclaration:
				return declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
			case KindTypeLiteral | KindObjectLiteralExpression | KindInterfaceDeclaration | KindJsxAttributes:
				return declareSymbol(Ast.GetMembers(container.Symbol()), container.Symbol(), node, symbolFlags, symbolExcludes);
			case KindFunctionType | KindConstructorType | KindCallSignature | KindConstructSignature | KindIndexSignature | KindMethodDeclaration |
				KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor | KindFunctionDeclaration | KindFunctionExpression |
				KindArrowFunction | KindClassStaticBlockDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindMappedType:
				return declareSymbol(Ast.GetLocals(container), null /*parent*/, node, symbolFlags, symbolExcludes);
			default:
		}
		throw "Unhandled case in declareSymbolAndAddToSymbolTable";
	}

	function newFlowNode(flags:FlowFlags):FlowNode {
		final result = flowNodeArena.New();
		result.Flags = flags;
		return result;
	}

	function newFlowNodeEx(flags:FlowFlags, node:Node, antecedent:FlowNode):FlowNode {
		final result = newFlowNode(flags);
		result.Node = node;
		result.Antecedent = antecedent;
		return result;
	}

	function createLoopLabel():FlowLabel {
		return newFlowNode(FlowFlagsLoopLabel);
	}

	function createBranchLabel():FlowLabel {
		return newFlowNode(FlowFlagsBranchLabel);
	}

	function createReduceLabel(target:FlowLabel, antecedents:FlowList, antecedent:FlowNode):FlowNode {
		return newFlowNodeEx(FlowFlagsReduceLabel, Ast.NewFlowReduceLabelData(target, antecedents), antecedent);
	}

	function createFlowCondition(flags:FlowFlags, antecedent:FlowNode, expression:Node):FlowNode {
		if (antecedent.Flags & FlowFlagsUnreachable != 0) {
			return antecedent;
		}
		if (expression == null) {
			if (flags & FlowFlagsTrueCondition != 0) {
				return antecedent;
			}
			return unreachableFlow;
		}
		if ((expression.Kind == KindTrueKeyword && flags & FlowFlagsFalseCondition != 0
			|| expression.Kind == KindFalseKeyword && flags & FlowFlagsTrueCondition != 0)
			&& !Ast.IsExpressionOfOptionalChainRoot(expression)
			&& !Ast.IsNullishCoalesce(expression.Parent)) {
			return unreachableFlow;
		}
		if (!isNarrowingExpression(expression)) {
			return antecedent;
		}
		setFlowNodeReferenced(antecedent);
		return newFlowNodeEx(flags, expression, antecedent);
	}

	function createFlowMutation(flags:FlowFlags, antecedent:FlowNode, node:Node):FlowNode {
		setFlowNodeReferenced(antecedent);
		hasFlowEffects = true;
		final result = newFlowNodeEx(flags, node, antecedent);
		if (currentExceptionTarget != null) {
			addAntecedent(currentExceptionTarget, result);
		}
		return result;
	}

	function createFlowSwitchClause(antecedent:FlowNode, switchStatement:Node, clauseStart:Int, clauseEnd:Int):FlowNode {
		setFlowNodeReferenced(antecedent);
		return newFlowNodeEx(FlowFlagsSwitchClause, Ast.NewFlowSwitchClauseData(switchStatement, clauseStart, clauseEnd), antecedent);
	}

	function createFlowCall(antecedent:FlowNode, node:Node):FlowNode {
		setFlowNodeReferenced(antecedent);
		hasFlowEffects = true;
		return newFlowNodeEx(FlowFlagsCall, node, antecedent);
	}

	function newFlowList(head:FlowNode, tail:FlowList):FlowList {
		final result = flowListArena.New();
		result.Flow = head;
		result.Next = tail;
		return result;
	}

	function combineFlowLists(head:FlowList, tail:FlowList):FlowList {
		if (head == null) {
			return tail;
		}
		return newFlowList(head.Flow, combineFlowLists(head.Next, tail));
	}

	function newSingleDeclaration(declaration:Node):Array<Node> {
		return singleDeclarationsArena.NewSlice1(declaration);
	}

	static function setFlowNodeReferenced(flow:FlowNode):Void {
		// On first reference we set the Referenced flag, thereafter we set the Shared flag
		if (flow.Flags & FlowFlagsReferenced == 0) {
			flow.Flags |= FlowFlagsReferenced;
		} else {
			flow.Flags |= FlowFlagsShared;
		}
	}

	function addAntecedent(label:FlowLabel, antecedent:FlowNode):Void {
		if (antecedent.Flags & FlowFlagsUnreachable != 0) {
			return;
		}
		// If antecedent isn't already on the Antecedents list, add it to the end of the list
		var last:FlowList = null;
		var list = label.Antecedents;
		while (list != null) {
			if (list.Flow == antecedent) {
				return;
			}
			last = list;
			list = list.Next;
		}
		if (last == null) {
			label.Antecedents = newFlowList(antecedent, null);
		} else {
			last.Next = newFlowList(antecedent, null);
		}
		setFlowNodeReferenced(antecedent);
	}

	function finishFlowLabel(label:FlowLabel):FlowNode {
		if (label.Antecedents == null) {
			return unreachableFlow;
		}
		if (label.Antecedents.Next == null) {
			return label.Antecedents.Flow;
		}
		return label;
	}

	function bind(node:Node):Bool {
		if (node == null) {
			return false;
		}
		// Even though in the AST the jsdoc @typedef node belongs to the current node,
		// its symbol might be in the same scope with the current node's symbol. Consider:
		//
		//     /** @typedef {string | number} MyType */
		//     function foo();
		//
		// Here the current node is "foo", which is a container, but the scope of "MyType" should
		// not be inside "foo". Therefore we always bind @typedef before bind the parent node,
		// and skip binding this tag later when binding all the other jsdoc tags.

		// First we bind declaration nodes to a symbol if possible. We'll both create a symbol
		// and then potentially add the symbol to an appropriate symbol table. Possible
		// destination symbol tables are:
		//
		//  1) The 'exports' table of the current container's symbol.
		//  2) The 'members' table of the current container's symbol.
		//  3) The 'locals' table of the current container.
		//
		// However, not all symbols will end up in any of these tables. 'Anonymous' symbols
		// (like TypeLiterals for example) will not be put in any table.
		switch (node.Kind) {
			case KindIdentifier:
				node.AsIdentifier().FlowNode = currentFlow;
				checkContextualIdentifier(node);
			case KindThisKeyword | KindSuperKeyword:
				if (node.Kind == KindThisKeyword) {
					seenThisKeyword = true;
				}
				node.AsKeywordExpression().FlowNode = currentFlow;
			case KindQualifiedName:
				if (currentFlow != null && Ast.IsPartOfTypeQuery(node)) {
					node.AsQualifiedName().FlowNode = currentFlow;
				}
			case KindMetaProperty:
				node.AsMetaProperty().FlowNode = currentFlow;
			case KindPrivateIdentifier:
				checkPrivateIdentifier(node);
			case KindPropertyAccessExpression | KindElementAccessExpression:
				if (currentFlow != null && isNarrowableReference(node)) {
					setFlowNode(node, currentFlow);
				}
			case KindBinaryExpression:
				switch (Ast.GetAssignmentDeclarationKind(node)) {
					case JSDeclarationKindModuleExports:
						bindModuleExportsAssignment(node);
					case JSDeclarationKindExportsProperty:
						bindExportsOrObjectDefineProperty(node);
					case JSDeclarationKindProperty:
						bindExpandoPropertyAssignment(node);
					case JSDeclarationKindThisProperty:
						bindThisPropertyAssignment(node);
					default:
				}
				checkStrictModeBinaryExpression(node);
			case KindCatchClause:
				checkStrictModeCatchClause(node);
			case KindDeleteExpression:
				checkStrictModeDeleteExpression(node);
			case KindPostfixUnaryExpression:
				checkStrictModePostfixUnaryExpression(node);
			case KindPrefixUnaryExpression:
				checkStrictModePrefixUnaryExpression(node);
			case KindWithStatement:
				checkStrictModeWithStatement(node);
			case KindLabeledStatement:
				checkStrictModeLabeledStatement(node);
			case KindThisType:
				seenThisKeyword = true;
			case KindTypeParameter:
				bindTypeParameter(node);
			case KindParameter:
				bindParameter(node);
			case KindVariableDeclaration:
				bindVariableDeclarationOrBindingElement(node);
			case KindBindingElement:
				node.AsBindingElement().FlowNode = currentFlow;
				bindVariableDeclarationOrBindingElement(node);
			case KindPropertyDeclaration | KindPropertySignature:
				bindPropertyWorker(node);
			case KindPropertyAssignment | KindShorthandPropertyAssignment:
				bindPropertyOrMethodOrAccessor(node, SymbolFlagsProperty, SymbolFlagsPropertyExcludes);
			case KindEnumMember:
				bindPropertyOrMethodOrAccessor(node, SymbolFlagsEnumMember, SymbolFlagsEnumMemberExcludes);
			case KindCallSignature | KindConstructSignature | KindIndexSignature:
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsSignature, SymbolFlagsNone);
			case KindMethodDeclaration | KindMethodSignature:
				bindPropertyOrMethodOrAccessor(node, SymbolFlagsMethod | getOptionalSymbolFlagForNode(node),
					Core.IfElse(Ast.IsObjectLiteralMethod(node), SymbolFlagsValue, SymbolFlagsMethodExcludes));
			case KindFunctionDeclaration:
				bindFunctionDeclaration(node);
			case KindConstructor:
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsConstructor, SymbolFlagsNone);
			case KindGetAccessor:
				bindPropertyOrMethodOrAccessor(node, SymbolFlagsGetAccessor, SymbolFlagsGetAccessorExcludes);
			case KindSetAccessor:
				bindPropertyOrMethodOrAccessor(node, SymbolFlagsSetAccessor, SymbolFlagsSetAccessorExcludes);
			case KindFunctionType | KindConstructorType:
				bindFunctionOrConstructorType(node);
			case KindTypeLiteral | KindMappedType:
				bindAnonymousDeclaration(node, SymbolFlagsTypeLiteral, Ast.InternalSymbolNameType);
			case KindObjectLiteralExpression:
				bindAnonymousDeclaration(node, SymbolFlagsObjectLiteral, Ast.InternalSymbolNameObject);
			case KindFunctionExpression | KindArrowFunction:
				bindFunctionExpression(node);
			case KindClassExpression | KindClassDeclaration:
				bindClassLikeDeclaration(node);
			case KindInterfaceDeclaration:
				bindBlockScopedDeclaration(node, SymbolFlagsInterface, SymbolFlagsInterfaceExcludes);
			case KindCallExpression:
				switch (Ast.GetAssignmentDeclarationKind(node)) {
					case JSDeclarationKindObjectDefinePropertyValue:
						bindExpandoPropertyAssignment(node);
					case JSDeclarationKindObjectDefinePropertyExports:
						bindExportsOrObjectDefineProperty(node);
					default:
				}
				if (Ast.IsInJSFile(node)) {
					bindCallExpression(node);
				}
			case KindTypeAliasDeclaration:
				bindBlockScopedDeclaration(node, SymbolFlagsTypeAlias, SymbolFlagsTypeAliasExcludes);
			case KindJSTypeAliasDeclaration:
				// Top-level JSTypeAliasDeclaration nodes are processed in bindContainer
				if (!Ast.IsSourceFile(blockScopeContainer)) {
					bindBlockScopedDeclaration(node, SymbolFlagsTypeAlias, SymbolFlagsTypeAliasExcludes);
				}
			case KindEnumDeclaration:
				bindEnumDeclaration(node);
			case KindModuleDeclaration:
				bindModuleDeclaration(node);
			case KindImportEqualsDeclaration | KindNamespaceImport | KindImportSpecifier | KindExportSpecifier:
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsAlias, SymbolFlagsAliasExcludes);
			case KindNamespaceExportDeclaration:
				bindNamespaceExportDeclaration(node);
			case KindImportClause:
				bindImportClause(node);
			case KindExportDeclaration:
				bindExportDeclaration(node);
			case KindExportAssignment:
				bindExportAssignment(node);
			case KindSourceFile:
				bindSourceFileIfExternalModule();
			case KindJsxAttributes:
				bindJsxAttributes(node);
			case KindJsxAttribute:
				bindJsxAttribute(node, SymbolFlagsProperty, SymbolFlagsPropertyExcludes);
			default:
		}
		// Then we recurse into the children of the node to bind them as well. For certain
		// symbols we do specialized work when we recurse. For example, we'll keep track of
		// the current 'container' node when it changes. This helps us know which symbol table
		// a local should go into for example. Since terminal nodes are known not to have
		// children, as an optimization we don't process those.
		var thisNodeOrAnySubnodesHasError = node.Flags & NodeFlagsThisNodeHasError != 0;
		if (node.Kind > KindLastToken) {
			final saveSeenParseError = seenParseError;
			seenParseError = false;
			final containerFlags = GetContainerFlags(node);
			if (containerFlags == ContainerFlagsNone) {
				bindChildren(node);
			} else {
				bindContainer(node, containerFlags);
			}
			if (seenParseError) {
				thisNodeOrAnySubnodesHasError = true;
			}
			seenParseError = saveSeenParseError;
		}
		if (thisNodeOrAnySubnodesHasError) {
			node.Flags |= NodeFlagsThisNodeOrAnySubNodesHasError;
			seenParseError = true;
		}
		return false;
	}

	function bindPropertyWorker(node:Node):Void {
		final isAutoAccessor = Ast.IsAutoAccessorPropertyDeclaration(node);
		final includes = Core.IfElse(isAutoAccessor, SymbolFlagsAccessor, SymbolFlagsProperty);
		final excludes = Core.IfElse(isAutoAccessor, SymbolFlagsAccessorExcludes, SymbolFlagsPropertyExcludes);
		bindPropertyOrMethodOrAccessor(node, includes | getOptionalSymbolFlagForNode(node), excludes);
	}

	function bindSourceFileIfExternalModule():Void {
		setExportContextFlag(file.AsNode());
		if (Ast.IsExternalOrCommonJSModule(file)) {
			bindSourceFileAsExternalModule();
		} else if (Ast.IsJsonSourceFile(file)) {
			bindSourceFileAsExternalModule();
			// Create symbol equivalent for the module.exports = {}
			final originalSymbol = file.Symbol;
			declareSymbol(Ast.GetExports(file.Symbol), file.Symbol, file.AsNode(), SymbolFlagsProperty, SymbolFlagsAll);
			file.Symbol = originalSymbol;
		}
	}

	function bindSourceFileAsExternalModule():Void {
		bindAnonymousDeclaration(file.AsNode(), SymbolFlagsValueModule, "\"" + Tspath.RemoveFileExtension(file.FileName()) + "\"");
	}

	function bindModuleDeclaration(node:Node):Void {
		setExportContextFlag(node);
		if (Ast.IsAmbientModule(node)) {
			if (Ast.HasSyntacticModifier(node, ModifierFlagsExport)) {
				errorOnFirstToken(node, Diagnostics.X_export_modifier_cannot_be_applied_to_ambient_modules_and_module_augmentations_since_they_are_always_visible);
			}
			if (Ast.IsModuleAugmentationExternal(node)) {
				declareModuleSymbol(node);
			} else {
				final name = node.AsModuleDeclaration().Name();
				final symbol = declareSymbolAndAddToSymbolTable(node, SymbolFlagsValueModule, SymbolFlagsValueModuleExcludes);

				if (Ast.IsStringLiteral(name)) {
					final pattern = Core.TryParsePattern(name.Text());
					if (!pattern.IsValid()) {
						// An invalid pattern - must have multiple wildcards.
						errorOnFirstToken(name, Diagnostics.Pattern_0_can_have_at_most_one_Asterisk_character, name.Text());
					} else if (pattern.StarIndex >= 0) {
						final m = new PatternAmbientModule();
						m.Pattern = pattern;
						m.Symbol = symbol;
						if (file.PatternAmbientModules == null) {
							file.PatternAmbientModules = [];
						}
						file.PatternAmbientModules.push(m);
					}
				}
			}
		} else {
			final state = declareModuleSymbol(node);
			if (state != ModuleInstanceStateNonInstantiated) {
				final symbol = node.Symbol();
				// if module was already merged with some function, class or non-const enum, treat it as non-const-enum-only
				final constEnumOnlyModule = (symbol.Flags & (SymbolFlagsFunction | SymbolFlagsClass | SymbolFlagsRegularEnum) == 0)
					// Current must be `const enum` only
					&& state == ModuleInstanceStateConstEnumOnly
					// Can't have been set to 'false' in a previous merged symbol. ('undefined' OK)
					&& !notConstEnumOnlyModules.Has(symbol);
				if (constEnumOnlyModule) {
					symbol.Flags |= SymbolFlagsConstEnumOnlyModule;
				} else {
					symbol.Flags = symbol.Flags & ~SymbolFlagsConstEnumOnlyModule;
					notConstEnumOnlyModules.Add(symbol);
				}
			}
		}
	}

	function declareModuleSymbol(node:Node):ModuleInstanceState {
		final state = Ast.GetModuleInstanceState(node);
		final instantiated = state != ModuleInstanceStateNonInstantiated;
		declareSymbolAndAddToSymbolTable(node, Core.IfElse(instantiated, SymbolFlagsValueModule, SymbolFlagsNamespaceModule),
			Core.IfElse(instantiated, SymbolFlagsValueModuleExcludes, SymbolFlagsNamespaceModuleExcludes));
		return state;
	}

	function bindNamespaceExportDeclaration(node:Node):Void {
		if (node.Modifiers() != null) {
			errorOnNode(node, Diagnostics.Modifiers_cannot_appear_here);
		}
		if (!Ast.IsSourceFile(node.Parent)) {
			errorOnNode(node, Diagnostics.Global_module_exports_may_only_appear_at_top_level);
		} else if (!Ast.IsExternalModule(node.Parent.AsSourceFile())) {
			errorOnNode(node, Diagnostics.Global_module_exports_may_only_appear_in_module_files);
		} else if (!node.Parent.AsSourceFile().IsDeclarationFile) {
			errorOnNode(node, Diagnostics.Global_module_exports_may_only_appear_in_declaration_files);
		} else {
			final f = file;
			declareSymbol(Ast.GetSymbolTable(() -> f.GlobalExports, t -> f.GlobalExports = t), file.Symbol, node, SymbolFlagsAlias, SymbolFlagsAliasExcludes);
		}
	}

	function bindImportClause(node:Node):Void {
		if (node.AsImportClause().Name() != null) {
			declareSymbolAndAddToSymbolTable(node, SymbolFlagsAlias, SymbolFlagsAliasExcludes);
		}
	}

	function bindExportDeclaration(node:Node):Void {
		final decl = node.AsExportDeclaration();
		if (container.Symbol() == null) {
			// Export * in some sort of block construct
			bindAnonymousDeclaration(node, SymbolFlagsExportStar, getDeclarationName(node));
		} else if (decl.ExportClause == null) {
			// All export * declarations are collected in an __export symbol
			declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, SymbolFlagsExportStar, SymbolFlagsNone);
		} else if (Ast.IsNamespaceExport(decl.ExportClause)) {
			declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), decl.ExportClause, SymbolFlagsAlias, SymbolFlagsAliasExcludes);
		}
	}

	function bindExportAssignment(node:Node):Void {
		final container = this.container;
		if (container.Symbol() == null && Ast.IsExportAssignment(node)) {
			// Incorrect export assignment in some sort of block construct
			bindAnonymousDeclaration(node, SymbolFlagsValue, getDeclarationName(node));
		} else {
			// If there is an `export default x;` alias declaration, can't `export default` anything else.
			// (In contrast, you can still have `export default function f() {}` and `export default interface I {}`.)
			final flags = Core.IfElse(Ast.ExpressionIsAlias(node.Expression()), SymbolFlagsAlias, SymbolFlagsProperty);
			final symbol = declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, flags, SymbolFlagsAll);
			if (node.AsExportAssignment().IsExportEquals) {
				// Ensure export assignments have a ValueDeclaration set.
				SetValueDeclaration(symbol, node);
			}
		}
	}

	function bindJsxAttributes(node:Node):Void {
		bindAnonymousDeclaration(node, SymbolFlagsObjectLiteral, Ast.InternalSymbolNameJSXAttributes);
	}

	function bindJsxAttribute(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Void {
		declareSymbolAndAddToSymbolTable(node, symbolFlags, symbolExcludes);
	}

	function setExportContextFlag(node:Node):Void {
		// A declaration source file or ambient module declaration that contains no export declarations (but possibly regular
		// declarations with export modifiers) is an export context in which declarations are implicitly exported.
		if (node.Flags & NodeFlagsAmbient != 0 && !hasExportDeclarations(node)) {
			node.Flags |= NodeFlagsExportContext;
		} else {
			node.Flags = node.Flags & ~NodeFlagsExportContext;
		}
	}

	static final fl_isExportDeclarationOrAssignment:(s:Node) -> Bool = s -> Ast.IsExportDeclaration(s) || Ast.IsExportAssignment(s);

	function hasExportDeclarations(node:Node):Bool {
		var statements:Array<Node> = null;
		switch (node.Kind) {
			case KindSourceFile:
				statements = node.Statements();
			case KindModuleDeclaration:
				final body = node.Body();
				if (body != null && Ast.IsModuleBlock(body)) {
					statements = body.Statements();
				}
			default:
		}
		return Core.Some(statements, fl_isExportDeclarationOrAssignment);
	}

	function bindFunctionExpression(node:Node):Void {
		if (!file.IsDeclarationFile && node.Flags & NodeFlagsAmbient == 0 && Ast.IsAsyncFunction(node)) {
			emitFlags |= NodeFlagsHasAsyncFunctions;
		}
		setFlowNode(node, currentFlow);
		var bindingName = Ast.InternalSymbolNameFunction;
		if (Ast.IsFunctionExpression(node) && node.AsFunctionExpression().Name() != null) {
			checkStrictModeFunctionName(node);
			bindingName = node.AsFunctionExpression().Name().Text();
		}
		bindAnonymousDeclaration(node, SymbolFlagsFunction, bindingName);
	}

	function bindCallExpression(node:Node):Void {
		// We're only inspecting call expressions to detect CommonJS modules, so we can skip
		// this check if we've already seen the module indicator
		if (file.CommonJSModuleIndicator == null && Ast.IsRequireCall(node, false /*requireStringLiteralLikeArgument*/)) {
			setCommonJSModuleIndicator(node);
		}
	}

	function setCommonJSModuleIndicator(node:Node):Bool {
		if (file.ExternalModuleIndicator != null && file.ExternalModuleIndicator != file.AsNode()) {
			return false;
		}
		if (file.CommonJSModuleIndicator == null) {
			file.CommonJSModuleIndicator = node;
			if (file.ExternalModuleIndicator == null) {
				bindSourceFileAsExternalModule();
			}
		}
		return true;
	}

	function bindClassLikeDeclaration(node:Node):Void {
		final name = node.Name();
		switch (node.Kind) {
			case KindClassDeclaration:
				bindBlockScopedDeclaration(node, SymbolFlagsClass, SymbolFlagsClassExcludes);
			case KindClassExpression:
				var nameText = Ast.InternalSymbolNameClass;
				if (name != null) {
					nameText = name.Text();
					classifiableNames.Add(nameText);
				}
				bindAnonymousDeclaration(node, SymbolFlagsClass, nameText);
			default:
		}
		final symbol = node.Symbol();
		// TypeScript 1.0 spec (April 2014): 8.4
		// Every class automatically contains a static property member named 'prototype', the
		// type of which is an instantiation of the class type with type Any supplied as a type
		// argument for each type parameter. It is an error to explicitly declare a static
		// property member with the name 'prototype'.
		//
		// Note: we check for this here because this class may be merging into a module.  The
		// module might have an exported variable called 'prototype'.  We can't allow that as
		// that would clash with the built-in 'prototype' for the class.
		final prototypeSymbol = newSymbol(SymbolFlagsProperty | SymbolFlagsPrototype, "prototype");
		final symbolExport = Ast.GetExports(symbol).get(prototypeSymbol.Name);
		if (symbolExport != null) {
			errorOnNode(symbolExport.Declarations[0], Diagnostics.Duplicate_identifier_0, Ast.SymbolName(prototypeSymbol));
		}
		Ast.GetExports(symbol).set(prototypeSymbol.Name, prototypeSymbol);
		prototypeSymbol.Parent = symbol;
	}

	function bindPropertyOrMethodOrAccessor(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Void {
		if (!file.IsDeclarationFile && node.Flags & NodeFlagsAmbient == 0 && Ast.IsAsyncFunction(node)) {
			emitFlags |= NodeFlagsHasAsyncFunctions;
		}
		if (currentFlow != null && Ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(node)) {
			setFlowNode(node, currentFlow);
		}
		if (Ast.HasDynamicName(node)) {
			bindAnonymousDeclaration(node, symbolFlags, Ast.InternalSymbolNameComputed);
		} else {
			declareSymbolAndAddToSymbolTable(node, symbolFlags, symbolExcludes);
		}
	}

	function bindFunctionOrConstructorType(node:Node):Void {
		// For a given function symbol "<...>(...) => T" we want to generate a symbol identical
		// to the one we would get for: { <...>(...): T }
		//
		// We do that by making an anonymous type literal symbol, and then setting the function
		// symbol as its sole member. To the rest of the system, this symbol will be indistinguishable
		// from an actual type literal symbol you would have gotten had you used the long form.
		final symbol = newSymbol(SymbolFlagsSignature, getDeclarationName(node));
		addDeclarationToSymbol(symbol, node, SymbolFlagsSignature);
		final typeLiteralSymbol = newSymbol(SymbolFlagsTypeLiteral, Ast.InternalSymbolNameType);
		addDeclarationToSymbol(typeLiteralSymbol, node, SymbolFlagsTypeLiteral);
		typeLiteralSymbol.Members = new SymbolTable();
		typeLiteralSymbol.Members.set(symbol.Name, symbol);
	}

	function addLateBoundAssignmentDeclarationToSymbol(node:Node, symbol:Symbol):Void {
		final exports = Ast.GetExports(symbol);
		var assignmentSymbol = exports.get(Ast.InternalSymbolNameAssignmentDeclaration);
		if (assignmentSymbol == null) {
			assignmentSymbol = newSymbol(SymbolFlagsNone, Ast.InternalSymbolNameAssignmentDeclaration);
			exports.set(Ast.InternalSymbolNameAssignmentDeclaration, assignmentSymbol);
		}
		if (assignmentSymbol.Declarations == null) {
			assignmentSymbol.Declarations = [];
		}
		assignmentSymbol.Declarations.push(node);
	}

	function bindModuleExportsAssignment(node:Node):Void {
		if (setCommonJSModuleIndicator(node)) {
			final container = file.AsNode();
			final flags = Core.IfElse(Ast.ExpressionIsAlias(node.AsBinaryExpression().Right), SymbolFlagsAlias, SymbolFlagsProperty);
			final symbol = declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, flags, 0);
			SetValueDeclaration(symbol, node);
		}
	}

	function bindExpandoPropertyAssignment(node:Node):Void {
		if (expandoAssignments == null) {
			expandoAssignments = [];
		}
		expandoAssignments.push(new ExpandoAssignmentInfo(node, container, blockScopeContainer));
	}

	function bindDeferredExpandoAssignments():Void {
		if (expandoAssignments == null) {
			return;
		}
		for (info in expandoAssignments) {
			container = info.container;
			blockScopeContainer = info.blockScopeContainer;
			bindDeferredExpandoAssignment(info.node);
		}
	}

	// If the given module symbol has an export= symbol, promote exports with a type or namespace meaning
	// from the module symbol onto the export= symbol and, if any such exports exist, mark the export=
	// symbol as a namespace module.
	function bindCommonJSTypeExports(moduleSymbol:Symbol):Void {
		final moduleExports = moduleSymbol.Exports;
		final exportEquals = moduleExports == null ? null : moduleExports.get(Ast.InternalSymbolNameExportEquals);
		if (exportEquals != null) {
			// PORT: Go map iteration order is random; the result does not depend on it (each
			// name is stored once into exportEquals' exports and only flags are OR-ed).
			for (symbol in moduleExports) {
				if (symbol.Name != Ast.InternalSymbolNameExportEquals && symbol.Flags & (SymbolFlagsType | SymbolFlagsNamespace) != 0) {
					Ast.GetExports(exportEquals).set(symbol.Name, symbol);
					exportEquals.Flags |= SymbolFlagsNamespaceModule;
				}
			}
		}
	}

	function bindDeferredExpandoAssignment(node:Node):Void {
		final parent = getParentOfPropertyAssignment(node);
		var symbol = lookupEntity(parent, blockScopeContainer);
		if (symbol == null) {
			symbol = lookupEntity(parent, container);
		}
		if ((symbol = getInitializerSymbol(symbol)) != null) {
			if (Ast.HasDynamicName(node)) {
				bindAnonymousDeclaration(node, SymbolFlagsProperty | SymbolFlagsAssignment, Ast.InternalSymbolNameComputed);
				addLateBoundAssignmentDeclarationToSymbol(node, symbol);
			} else {
				// We declare expandos only when there are no non-expando declarations for that name.
				final exports = Ast.GetExports(symbol);
				final existing = exports.get(getDeclarationName(node));
				if (existing == null || existing.Flags & SymbolFlagsAssignment != 0) {
					declareSymbol(exports, symbol, node, SymbolFlagsProperty | SymbolFlagsAssignment, SymbolFlagsPropertyExcludes);
				}
			}
		}
	}

	static function getParentOfPropertyAssignment(node:Node):Node {
		switch (node.Kind) {
			case KindBinaryExpression:
				return node.AsBinaryExpression().Left.Expression();
			case KindCallExpression:
				return node.Arguments()[0];
			default:
		}
		throw "Unhandled case in getParentOfPropertyAssignment";
	}

	function bindExportsOrObjectDefineProperty(node:Node):Void {
		if (setCommonJSModuleIndicator(node)) {
			final container = file.AsNode();
			final flags = Core.IfElse(Ast.IsBinaryExpression(node) && Ast.ExpressionIsAlias(node.AsBinaryExpression().Right), SymbolFlagsAlias,
				SymbolFlagsFunctionScopedVariable);
			declareSymbol(Ast.GetExports(container.Symbol()), container.Symbol(), node, flags, SymbolFlagsFunctionScopedVariableExcludes);
		}
	}

	static function getInitializerSymbol(symbol:Symbol):Symbol {
		if (symbol == null || symbol.ValueDeclaration == null) {
			return null;
		}
		final declaration = symbol.ValueDeclaration;
		// For an assignment 'fn.xxx = ...', where 'fn' is a previously declared function or a previously
		// declared const variable initialized with a function expression or arrow function, we add expando
		// property declarations to the function's symbol. This also applies to class expressions in JS files,
		// and empty object literals in JS files when the declaration doesn't have a type annotation.
		if (Ast.IsFunctionDeclaration(declaration) || Ast.IsInJSFile(declaration) && Ast.IsClassDeclaration(declaration)) {
			return symbol;
		} else if (Ast.IsVariableDeclaration(declaration) && (declaration.Parent.Flags & NodeFlagsConst != 0 || Ast.IsInJSFile(declaration))) {
			final initializer = declaration.Initializer();
			if (Ast.IsExpandoInitializer(declaration, initializer)) {
				return initializer.Symbol();
			}
		} else if (Ast.IsBinaryExpression(declaration) && Ast.IsInJSFile(declaration)) {
			final initializer = declaration.AsBinaryExpression().Right;
			if (Ast.IsExpandoInitializer(declaration, initializer)) {
				return initializer.Symbol();
			}
		}
		return null;
	}

	function bindThisPropertyAssignment(node:Node):Void {
		if (!Ast.IsInJSFile(node)) {
			return;
		}
		final bin = node.AsBinaryExpression();
		if (Ast.IsPropertyAccessExpression(bin.Left) && Ast.IsPrivateIdentifier(bin.Left.AsPropertyAccessExpression().Name()) || thisContainer == null) {
			return;
		}
		final classAndTable = getThisClassAndSymbolTable();
		final classSymbol = classAndTable.a;
		final symbolTable = classAndTable.b;
		if (symbolTable != null) {
			if (Ast.HasDynamicName(node)) {
				declareSymbolEx(symbolTable, classSymbol, node, SymbolFlagsProperty, SymbolFlagsNone, true /*isReplaceableByMethod*/, true /*isComputedName*/);
				addLateBoundAssignmentDeclarationToSymbol(node, classSymbol);
			} else {
				declareSymbolEx(symbolTable, classSymbol, node, SymbolFlagsProperty | SymbolFlagsAssignment, SymbolFlagsNone, true /*isReplaceableByMethod*/,
					false /*isComputedName*/);
			}
		} else if (thisContainer.Kind != KindFunctionDeclaration && thisContainer.Kind != KindFunctionExpression) {
			// !!! constructor functions
			throw "Unhandled case in bindThisPropertyAssignment: " + thisContainer.Kind.String();
		}
	}

	// PORT: Go returns (classSymbol, symbolTable) → Pair.
	function getThisClassAndSymbolTable():Pair<Symbol, SymbolTable> {
		var classSymbol:Symbol = null;
		var symbolTable:SymbolTable = null;
		if (thisContainer == null) {
			return new Pair(null, null);
		}
		switch (thisContainer.Kind) {
			case KindFunctionDeclaration | KindFunctionExpression:
			// !!! constructor functions
			case KindConstructor | KindPropertyDeclaration | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindClassStaticBlockDeclaration:
				// this.property assignment in class member -- bind to the containing class
				classSymbol = thisContainer.Parent.Symbol();
				if (Ast.IsStatic(thisContainer)) {
					symbolTable = Ast.GetExports(classSymbol);
				} else {
					symbolTable = Ast.GetMembers(classSymbol);
				}
			default:
		}
		return new Pair(classSymbol, symbolTable);
	}

	function bindEnumDeclaration(node:Node):Void {
		if (Ast.IsEnumConst(node)) {
			bindBlockScopedDeclaration(node, SymbolFlagsConstEnum, SymbolFlagsConstEnumExcludes);
		} else {
			bindBlockScopedDeclaration(node, SymbolFlagsRegularEnum, SymbolFlagsRegularEnumExcludes);
		}
	}

	function bindVariableDeclarationOrBindingElement(node:Node):Void {
		checkStrictModeEvalOrArguments(node, node.Name());
		final name = node.Name();
		if (name != null && !Ast.IsBindingPattern(name)) {
			if (Ast.IsVariableDeclarationInitializedToRequire(node)) {
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsAlias, SymbolFlagsAliasExcludes);
			} else if (Ast.IsBlockOrCatchScoped(node)) {
				bindBlockScopedDeclaration(node, SymbolFlagsBlockScopedVariable, SymbolFlagsBlockScopedVariableExcludes);
			} else if (Ast.IsPartOfParameterDeclaration(node)) {
				// It is safe to walk up parent chain to find whether the node is a destructuring parameter declaration
				// because its parent chain has already been set up, since parents are set before descending into children.
				//
				// If node is a binding element in parameter declaration, we need to use ParameterExcludes.
				// Using ParameterExcludes flag allows the compiler to report an error on duplicate identifiers in Parameter Declaration
				// For example:
				//      function foo([a,a]) {} // Duplicate Identifier error
				//      function bar(a,a) {}   // Duplicate Identifier error, parameter declaration in this case is handled in bindParameter
				//                             // which correctly set excluded symbols
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsFunctionScopedVariable, SymbolFlagsParameterExcludes);
			} else {
				declareSymbolAndAddToSymbolTable(node, SymbolFlagsFunctionScopedVariable, SymbolFlagsFunctionScopedVariableExcludes);
			}
		}
	}

	function bindParameter(node:Node):Void {
		final decl = node.AsParameterDeclaration();
		if (node.Flags & NodeFlagsAmbient == 0) {
			// It is a SyntaxError if the identifier eval or arguments appears within a FormalParameterList of a
			// strict mode FunctionLikeDeclaration or FunctionExpression(13.1)
			checkStrictModeEvalOrArguments(node, decl.Name());
		}
		if (Ast.IsBindingPattern(decl.Name())) {
			final index = node.Parent.Parameters().indexOf(node);
			bindAnonymousDeclaration(node, SymbolFlagsFunctionScopedVariable, "__" + Std.string(index));
		} else {
			declareSymbolAndAddToSymbolTable(node, SymbolFlagsFunctionScopedVariable, SymbolFlagsParameterExcludes);
		}
		// If this is a property-parameter, then also declare the property symbol into the
		// containing class.
		if (Ast.IsParameterPropertyDeclaration(node, node.Parent)) {
			final classDeclaration = node.Parent.Parent;
			final flags = SymbolFlagsProperty | Core.IfElse(decl.QuestionToken != null, SymbolFlagsOptional, SymbolFlagsNone);
			declareSymbol(Ast.GetMembers(classDeclaration.Symbol()), classDeclaration.Symbol(), node, flags, SymbolFlagsPropertyExcludes);
		}
	}

	function bindFunctionDeclaration(node:Node):Void {
		if (!file.IsDeclarationFile && node.Flags & NodeFlagsAmbient == 0 && Ast.IsAsyncFunction(node)) {
			emitFlags |= NodeFlagsHasAsyncFunctions;
		}
		checkStrictModeFunctionName(node);
		bindBlockScopedDeclaration(node, SymbolFlagsFunction, SymbolFlagsFunctionExcludes);
	}

	static final fl_isExtendsTypeOfConditionalType:(n:Node) -> Bool = function(n:Node):Bool {
		final parent = n.Parent;
		return parent != null && Ast.IsConditionalTypeNode(parent) && parent.AsConditionalTypeNode().ExtendsType == n;
	};

	function getInferTypeContainer(node:Node):Node {
		final extendsType = Ast.FindAncestor(node, fl_isExtendsTypeOfConditionalType);
		if (extendsType != null) {
			return extendsType.Parent;
		}
		return null;
	}

	function bindAnonymousDeclaration(node:Node, symbolFlags:SymbolFlags, name:std.String):Void {
		final symbol = newSymbol(symbolFlags, name);
		if (symbolFlags & (SymbolFlagsEnumMember | SymbolFlagsClassMember) != 0) {
			symbol.Parent = container.Symbol();
		}
		addDeclarationToSymbol(symbol, node, symbolFlags);
	}

	function bindBlockScopedDeclaration(node:Node, symbolFlags:SymbolFlags, symbolExcludes:SymbolFlags):Void {
		switch (blockScopeContainer.Kind) {
			case KindModuleDeclaration:
				declareModuleMember(node, symbolFlags, symbolExcludes);
			case KindSourceFile:
				// PORT: `break` / `fallthrough` → if/else.
				if (Ast.IsExternalOrCommonJSModule(container.AsSourceFile())) {
					declareModuleMember(node, symbolFlags, symbolExcludes);
				} else {
					declareSymbol(Ast.GetLocals(blockScopeContainer), null /*parent*/, node, symbolFlags, symbolExcludes);
				}
			default:
				declareSymbol(Ast.GetLocals(blockScopeContainer), null /*parent*/, node, symbolFlags, symbolExcludes);
		}
	}

	function bindTypeParameter(node:Node):Void {
		if (node.Parent.Kind == KindInferType) {
			final container = getInferTypeContainer(node.Parent);
			if (container != null) {
				declareSymbol(Ast.GetLocals(container), null /*parent*/, node, SymbolFlagsTypeParameter, SymbolFlagsTypeParameterExcludes);
			} else {
				bindAnonymousDeclaration(node, SymbolFlagsTypeParameter, getDeclarationName(node));
			}
		} else {
			declareSymbolAndAddToSymbolTable(node, SymbolFlagsTypeParameter, SymbolFlagsTypeParameterExcludes);
		}
	}

	function lookupEntity(node:Node, container:Node):Symbol {
		if (Ast.IsIdentifier(node)) {
			return lookupName(node.Text(), container);
		}
		if (node.Expression().Kind == KindThisKeyword) {
			final symbolTable = getThisClassAndSymbolTable().b;
			if (symbolTable != null) {
				final name = Ast.GetElementOrPropertyAccessName(node);
				if (name != null) {
					return symbolTable.get(name.Text());
				}
			}
			return null;
		}
		final symbol = getInitializerSymbol(lookupEntity(node.Expression(), container));
		if (symbol != null && symbol.Exports != null) {
			final name = Ast.GetElementOrPropertyAccessName(node);
			if (name != null) {
				return symbol.Exports.get(name.Text());
			}
		}
		return null;
	}

	function lookupName(name:std.String, container:Node):Symbol {
		final localsContainer = container.LocalsContainerData();
		if (localsContainer != null) {
			final local = localsContainer.Locals == null ? null : localsContainer.Locals.get(name);
			if (local != null) {
				return Core.OrElse(local.ExportSymbol, local);
			}
		}
		final declaration = container.DeclarationData();
		if (declaration != null && declaration.Symbol != null) {
			final exports = declaration.Symbol.Exports;
			return exports == null ? null : exports.get(name);
		}
		return null;
	}

	// The binder visits every node in the syntax tree so it is a convenient place to perform a single localized
	// check for reserved words used as identifiers in strict mode code, as well as `yield` or `await` in
	// [Yield] or [Await] contexts, respectively.
	function checkContextualIdentifier(node:Node):Void {
		// Report error only if there are no parse errors in file
		if (Core.len(file.Diagnostics()) == 0 && node.Flags & NodeFlagsAmbient == 0 && node.Flags & NodeFlagsJSDoc == 0 && !Ast.IsIdentifierName(node)) {
			// strict mode identifiers
			final originalKeywordKind = Scanner.GetIdentifierToken(node.Text());
			if (originalKeywordKind == KindIdentifier) {
				return;
			}
			if (originalKeywordKind >= KindFirstFutureReservedWord && originalKeywordKind <= KindLastFutureReservedWord) {
				errorOnNode(node, getStrictModeIdentifierMessage(node), Scanner.DeclarationNameToString(node));
			} else if (originalKeywordKind == KindAwaitKeyword) {
				if (Ast.IsExternalModule(file) && Ast.IsInTopLevelContext(node)) {
					errorOnNode(node, Diagnostics.Identifier_expected_0_is_a_reserved_word_at_the_top_level_of_a_module, Scanner.DeclarationNameToString(node));
				} else if (node.Flags & NodeFlagsAwaitContext != 0) {
					errorOnNode(node, Diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, Scanner.DeclarationNameToString(node));
				}
			} else if (originalKeywordKind == KindYieldKeyword && node.Flags & NodeFlagsYieldContext != 0) {
				errorOnNode(node, Diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, Scanner.DeclarationNameToString(node));
			}
		}
	}

	function checkPrivateIdentifier(node:Node):Void {
		if (node.Text() == "#constructor") {
			// Report error only if there are no parse errors in file
			if (Core.len(file.Diagnostics()) == 0) {
				errorOnNode(node, Diagnostics.X_constructor_is_a_reserved_word, Scanner.DeclarationNameToString(node));
			}
		}
	}

	function getStrictModeIdentifierMessage(node:Node):Message {
		// Provide specialized messages to help the user understand why we think they're in
		// strict mode.
		if (Ast.GetContainingClass(node) != null) {
			return Diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Class_definitions_are_automatically_in_strict_mode;
		}
		if (file.ExternalModuleIndicator != null) {
			return Diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Modules_are_automatically_in_strict_mode;
		}
		return Diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode;
	}

	// Should be called only on prologue directives (ast.IsPrologueDirective(node) should be true)
	static function isUseStrictPrologueDirective(sourceFile:SourceFile, node:Node):Bool {
		final nodeText = Scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node.Expression(), false /*includeTrivia*/);
		// Note: the node text must be exactly "use strict" or 'use strict'.  It is not ok for the
		// string to contain unicode escapes (as per ES5).
		return nodeText == "\"use strict\"" || nodeText == "'use strict'";
	}

	public static function FindUseStrictPrologue(sourceFile:SourceFile, statements:Array<Node>):Node {
		if (statements != null) {
			for (statement in statements) {
				if (Ast.IsPrologueDirective(statement)) {
					if (isUseStrictPrologueDirective(sourceFile, statement)) {
						return statement;
					}
				} else {
					return null;
				}
			}
		}

		return null;
	}

	function checkStrictModeFunctionName(node:Node):Void {
		if (node.Flags & NodeFlagsAmbient == 0) {
			// It is a SyntaxError if the identifier eval or arguments appears within a FormalParameterList of a strict mode FunctionDeclaration or FunctionExpression (13.1))
			checkStrictModeEvalOrArguments(node, node.Name());
		}
	}

	function getStrictModeBlockScopeFunctionDeclarationMessage(node:Node):Message {
		// Provide specialized messages to help the user understand why we think they're in strict mode.
		if (Ast.GetContainingClass(node) != null) {
			return Diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5_Class_definitions_are_automatically_in_strict_mode;
		}
		if (file.ExternalModuleIndicator != null) {
			return Diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5_Modules_are_automatically_in_strict_mode;
		}
		return Diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5;
	}

	function checkStrictModeBinaryExpression(node:Node):Void {
		final expr = node.AsBinaryExpression();
		if (Ast.IsLeftHandSideExpression(expr.Left) && Ast.IsAssignmentOperator(expr.OperatorToken.Kind)) {
			// ECMA 262 (Annex C) The identifier eval or arguments may not appear as the LeftHandSideExpression of an
			// Assignment operator(11.13) or of a PostfixExpression(11.3)
			checkStrictModeEvalOrArguments(node, expr.Left);
		}
	}

	function checkStrictModeCatchClause(node:Node):Void {
		// It is a SyntaxError if a TryStatement with a Catch occurs within strict code and the Identifier of the
		// Catch production is eval or arguments
		final clause = node.AsCatchClause();
		if (clause.VariableDeclaration != null) {
			checkStrictModeEvalOrArguments(node, clause.VariableDeclaration.AsVariableDeclaration().Name());
		}
	}

	function checkStrictModeDeleteExpression(node:Node):Void {
		// Grammar checking
		final expr = node.AsDeleteExpression();
		if (expr.Expression.Kind == KindIdentifier) {
			// When a delete operator occurs within strict mode code, a SyntaxError is thrown if its
			// UnaryExpression is a direct reference to a variable, function argument, or function name
			errorOnNode(expr.Expression, Diagnostics.X_delete_cannot_be_called_on_an_identifier_in_strict_mode);
		}
	}

	function checkStrictModePostfixUnaryExpression(node:Node):Void {
		// Grammar checking
		// The identifier eval or arguments may not appear as the LeftHandSideExpression of an
		// Assignment operator(11.13) or of a PostfixExpression(11.3) or as the UnaryExpression
		// operated upon by a Prefix Increment(11.4.4) or a Prefix Decrement(11.4.5) operator.
		checkStrictModeEvalOrArguments(node, node.AsPostfixUnaryExpression().Operand);
	}

	function checkStrictModePrefixUnaryExpression(node:Node):Void {
		// Grammar checking
		final expr = node.AsPrefixUnaryExpression();
		if (expr.Operator == KindPlusPlusToken || expr.Operator == KindMinusMinusToken) {
			checkStrictModeEvalOrArguments(node, expr.Operand);
		}
	}

	function checkStrictModeWithStatement(node:Node):Void {
		// Grammar checking for withStatement
		errorOnFirstToken(node, Diagnostics.X_with_statements_are_not_allowed_in_strict_mode);
	}

	function checkStrictModeLabeledStatement(node:Node):Void {
		// Grammar checking for labeledStatement
		final data = node.AsLabeledStatement();
		if (Ast.IsDeclarationStatement(data.Statement) || Ast.IsVariableStatement(data.Statement)) {
			errorOnFirstToken(data.Label, Diagnostics.A_label_is_not_allowed_here);
		}
	}

	static function isEvalOrArgumentsIdentifier(node:Node):Bool {
		if (Ast.IsIdentifier(node)) {
			final text = node.Text();
			return text == "eval" || text == "arguments";
		}
		return false;
	}

	function checkStrictModeEvalOrArguments(contextNode:Node, name:Node):Void {
		if (name != null && isEvalOrArgumentsIdentifier(name)) {
			// We check first if the name is inside class declaration or class expression; if so give explicit message
			// otherwise report generic error message.
			errorOnNode(name, getStrictModeEvalOrArgumentsMessage(contextNode), name.Text());
		}
	}

	function getStrictModeEvalOrArgumentsMessage(node:Node):Message {
		// Provide specialized messages to help the user understand why we think they're in strict mode
		if (Ast.GetContainingClass(node) != null) {
			return Diagnostics.Code_contained_in_a_class_is_evaluated_in_JavaScript_s_strict_mode_which_does_not_allow_this_use_of_0_For_more_information_see_https_Colon_Slash_Slashdeveloper_mozilla_org_Slashen_US_Slashdocs_SlashWeb_SlashJavaScript_SlashReference_SlashStrict_mode;
		}
		if (file.ExternalModuleIndicator != null) {
			return Diagnostics.Invalid_use_of_0_Modules_are_automatically_in_strict_mode;
		}
		return Diagnostics.Invalid_use_of_0_in_strict_mode;
	}

	// All container nodes are kept on a linked list in declaration order. This list is used by
	// the getLocalNameOfContainer function in the type checker to validate that the local name
	// used for a container is unique.
	function bindContainer(node:Node, containerFlags:ContainerFlags):Void {
		// Before we recurse into a node's children, we first save the existing parent, container
		// and block-container.  Then after we pop out of processing the children, we restore
		// these saved values.
		final saveContainer = container;
		final saveThisContainer = thisContainer;
		final savedBlockScopeContainer = blockScopeContainer;
		// Depending on what kind of node this is, we may have to adjust the current container
		// and block-container.   If the current node is a container, then it is automatically
		// considered the current block-container as well.  Also, for containers that we know
		// may contain locals, we eagerly initialize the .locals field. We do this because
		// it's highly likely that the .locals will be needed to place some child in (for example,
		// a parameter, or variable declaration).
		//
		// However, we do not proactively create the .locals for block-containers because it's
		// totally normal and common for block-containers to never actually have a block-scoped
		// variable in them.  We don't want to end up allocating an object for every 'block' we
		// run into when most of them won't be necessary.
		//
		// Finally, if this is a block-container, then we clear out any existing .locals object
		// it may contain within it.  This happens in incremental scenarios.  Because we can be
		// reusing a node from a previous compilation, that node may have had 'locals' created
		// for it.  We must clear this so we don't accidentally move any stale data forward from
		// a previous compilation.
		if (containerFlags & ContainerFlagsIsContainer != 0) {
			container = node;
			blockScopeContainer = node;
			if (containerFlags & ContainerFlagsHasLocals != 0) {
				// localsContainer := node
				// localsContainer.LocalsContainerData().locals = make(SymbolTable)
				addToContainerChain(node);
			}
		} else if (containerFlags & ContainerFlagsIsBlockScopedContainer != 0) {
			blockScopeContainer = node;
			addToContainerChain(node);
		}
		if (containerFlags & ContainerFlagsIsThisContainer != 0) {
			thisContainer = node;
		}
		if (containerFlags & ContainerFlagsIsControlFlowContainer != 0) {
			final saveCurrentFlow = currentFlow;
			final saveBreakTarget = currentBreakTarget;
			final saveContinueTarget = currentContinueTarget;
			final saveReturnTarget = currentReturnTarget;
			final saveExceptionTarget = currentExceptionTarget;
			final saveActiveLabelList = activeLabelList;
			final saveHasExplicitReturn = hasExplicitReturn;
			final saveSeenThisKeyword = seenThisKeyword;
			final isImmediatelyInvoked = (containerFlags & ContainerFlagsIsFunctionExpression != 0
				&& !Ast.HasSyntacticModifier(node, ModifierFlagsAsync)
				&& !isGeneratorFunctionExpression(node)
				&& Ast.GetImmediatelyInvokedFunctionExpression(node) != null)
				|| node.Kind == KindClassStaticBlockDeclaration;
			// A non-async, non-generator IIFE is considered part of the containing control flow. Return statements behave
			// similarly to break statements that exit to a label just past the statement body.
			if (!isImmediatelyInvoked) {
				final flowStart = newFlowNode(FlowFlagsStart);
				currentFlow = flowStart;
				if (containerFlags & (ContainerFlagsIsFunctionExpression | ContainerFlagsIsObjectLiteralOrClassExpressionMethodOrAccessor) != 0) {
					flowStart.Node = node;
				}
			}
			// We create a return control flow graph for IIFEs and constructors. For constructors
			// we use the return control flow graph in strict property initialization checks.
			if (isImmediatelyInvoked || node.Kind == KindConstructor) {
				currentReturnTarget = newFlowNode(FlowFlagsBranchLabel);
			} else {
				currentReturnTarget = null;
			}
			currentExceptionTarget = null;
			currentBreakTarget = null;
			currentContinueTarget = null;
			activeLabelList = null;
			hasExplicitReturn = false;
			seenThisKeyword = false;
			bindChildren(node);
			// Reset flags (for incremental scenarios)
			node.Flags = node.Flags & ~(NodeFlagsReachabilityAndEmitFlags | NodeFlagsContainsThis);
			if (currentFlow.Flags & FlowFlagsUnreachable == 0 && containerFlags & ContainerFlagsIsFunctionLike != 0) {
				final bodyData = node.BodyData();
				if (bodyData != null && Ast.NodeIsPresent(bodyData.Body)) {
					node.Flags |= NodeFlagsHasImplicitReturn;
					if (hasExplicitReturn) {
						node.Flags |= NodeFlagsHasExplicitReturn;
					}
					bodyData.EndFlowNode = currentFlow;
				}
			}
			if (seenThisKeyword) {
				node.Flags |= NodeFlagsContainsThis;
			}
			if (node.Kind == KindSourceFile) {
				node.Flags |= emitFlags;
				node.AsSourceFile().EndFlowNode = currentFlow;
			}
			if (currentReturnTarget != null) {
				addAntecedent(currentReturnTarget, currentFlow);
				currentFlow = finishFlowLabel(currentReturnTarget);
				if (node.Kind == KindConstructor || node.Kind == KindClassStaticBlockDeclaration) {
					setReturnFlowNode(node, currentFlow);
				}
			}
			if (!isImmediatelyInvoked) {
				currentFlow = saveCurrentFlow;
			}
			currentBreakTarget = saveBreakTarget;
			currentContinueTarget = saveContinueTarget;
			currentReturnTarget = saveReturnTarget;
			currentExceptionTarget = saveExceptionTarget;
			activeLabelList = saveActiveLabelList;
			hasExplicitReturn = saveHasExplicitReturn;
			if (containerFlags & ContainerFlagsPropagatesThisKeyword != 0) {
				seenThisKeyword = saveSeenThisKeyword || seenThisKeyword;
			} else {
				seenThisKeyword = saveSeenThisKeyword;
			}
		} else if (containerFlags & ContainerFlagsIsInterface != 0) {
			final saveSeenThisKeyword = seenThisKeyword;
			seenThisKeyword = false;
			bindChildren(node);
			// ContainsThis cannot overlap with HasExtendedUnicodeEscape on Identifier
			if (seenThisKeyword) {
				node.Flags |= NodeFlagsContainsThis;
			} else {
				node.Flags = node.Flags & ~NodeFlagsContainsThis;
			}
			seenThisKeyword = saveSeenThisKeyword;
		} else {
			bindChildren(node);
		}
		if (Ast.IsSourceFile(node) && Ast.IsInJSFile(node)) {
			// Binding of top-level JSTypeAliasDeclaration nodes is deferred to ensure CommonJS module
			// indicators, if any, are processed first.
			final statements = node.Statements();
			if (statements != null) {
				for (statement in statements) {
					if (Ast.IsJSTypeAliasDeclaration(statement)) {
						bindBlockScopedDeclaration(statement, SymbolFlagsTypeAlias, SymbolFlagsTypeAliasExcludes);
					}
				}
			}
			if (file.CommonJSModuleIndicator != null) {
				declareCommonJSVariable("module");
				declareCommonJSVariable("exports");
			}
		}
		if (Ast.IsSourceFile(node) && Ast.IsExternalOrCommonJSModule(node.AsSourceFile()) || Ast.IsAmbientModule(node)) {
			bindCommonJSTypeExports(node.Symbol());
		}
		container = saveContainer;
		thisContainer = saveThisContainer;
		blockScopeContainer = savedBlockScopeContainer;
	}

	function declareCommonJSVariable(name:std.String):Void {
		final locals = Ast.GetLocals(file.AsNode());
		if (locals.get(name) == null) {
			final symbol = newSymbol(SymbolFlagsFunctionScopedVariable | SymbolFlagsModuleExports, name);
			symbol.Declarations = newSingleDeclaration(file.AsNode());
			symbol.ValueDeclaration = symbol.Declarations[0];
			if (name == "module") {
				final exportsProperty = newSymbol(SymbolFlagsModuleExports | SymbolFlagsProperty, "exports");
				// PORT: shares the slice like Go; nothing appends to it afterwards.
				exportsProperty.Declarations = symbol.Declarations;
				exportsProperty.ValueDeclaration = symbol.ValueDeclaration;
				exportsProperty.Parent = symbol;
				symbol.Members = new SymbolTable();
				symbol.Members.set("exports", exportsProperty);
			}
			locals.set(name, symbol);
		}
	}

	function bindChildren(node:Node):Void {
		final saveInAssignmentPattern = inAssignmentPattern;
		// Most nodes aren't valid in an assignment pattern, so we clear the value here
		// and set it before we descend into nodes that could actually be part of an assignment pattern.
		inAssignmentPattern = false;

		if (currentFlow == unreachableFlow) {
			final flowNodeData = node.FlowNodeData();
			if (flowNodeData != null) {
				flowNodeData.FlowNode = null;
			}
			if (Ast.IsPotentiallyExecutableNode(node)) {
				node.Flags |= NodeFlagsUnreachable;
			}
			bindEachChild(node);
			inAssignmentPattern = saveInAssignmentPattern;
			return;
		}

		if (KindFirstStatement <= node.Kind && node.Kind <= KindLastStatement) {
			final flowNodeData = node.FlowNodeData();
			if (flowNodeData != null) {
				flowNodeData.FlowNode = currentFlow;
			}
		}

		switch (node.Kind) {
			case KindWhileStatement:
				bindWhileStatement(node);
			case KindDoStatement:
				bindDoStatement(node);
			case KindForStatement:
				bindForStatement(node);
			case KindForInStatement | KindForOfStatement:
				bindForInOrForOfStatement(node);
			case KindIfStatement:
				bindIfStatement(node);
			case KindReturnStatement:
				bindReturnStatement(node);
			case KindThrowStatement:
				bindThrowStatement(node);
			case KindBreakStatement:
				bindBreakStatement(node);
			case KindContinueStatement:
				bindContinueStatement(node);
			case KindTryStatement:
				bindTryStatement(node);
			case KindSwitchStatement:
				bindSwitchStatement(node);
			case KindCaseBlock:
				bindCaseBlock(node);
			case KindCaseClause | KindDefaultClause:
				bindCaseOrDefaultClause(node);
			case KindExpressionStatement:
				bindExpressionStatement(node);
			case KindLabeledStatement:
				bindLabeledStatement(node);
			case KindPrefixUnaryExpression:
				bindPrefixUnaryExpressionFlow(node);
			case KindPostfixUnaryExpression:
				bindPostfixUnaryExpressionFlow(node);
			case KindBinaryExpression:
				if (Ast.IsDestructuringAssignment(node)) {
					// Carry over whether we are in an assignment pattern to
					// binary expressions that could actually be an initializer
					inAssignmentPattern = saveInAssignmentPattern;
					bindDestructuringAssignmentFlow(node);
					return;
				}
				bindBinaryExpressionFlow(node);
			case KindDeleteExpression:
				bindDeleteExpressionFlow(node);
			case KindConditionalExpression:
				bindConditionalExpressionFlow(node);
			case KindVariableDeclaration:
				bindVariableDeclarationFlow(node);
			case KindPropertyAccessExpression | KindElementAccessExpression:
				bindAccessExpressionFlow(node);
			case KindCallExpression:
				bindCallExpressionFlow(node);
			case KindNonNullExpression:
				bindNonNullExpressionFlow(node);
			case KindSourceFile:
				final sourceFile = node.AsSourceFile();
				bindEachStatementFunctionsFirst(sourceFile.Statements);
				bind(sourceFile.EndOfFileToken);
			case KindBlock | KindModuleBlock:
				bindEachStatementFunctionsFirst(node.StatementList());
			case KindBindingElement:
				bindBindingElementFlow(node);
			case KindParameter:
				bindParameterFlow(node);
			case KindObjectLiteralExpression | KindArrayLiteralExpression | KindPropertyAssignment | KindSpreadElement:
				inAssignmentPattern = saveInAssignmentPattern;
				bindEachChild(node);
			default:
				bindEachChild(node);
		}
		inAssignmentPattern = saveInAssignmentPattern;
	}

	function bindEachChild(node:Node):Void {
		node.ForEachChild(bindFunc);
	}

	function bindEach(nodes:Array<Node>):Void {
		if (nodes != null) {
			for (node in nodes) {
				bind(node);
			}
		}
	}

	function bindNodeList(nodeList:NodeList):Void {
		if (nodeList != null) {
			bindEach(nodeList.Nodes);
		}
	}

	function bindModifiers(modifiers:ModifierList):Void {
		if (modifiers != null) {
			bindEach(modifiers.Nodes);
		}
	}

	function bindEachStatementFunctionsFirst(statements:NodeList):Void {
		final nodes = statements.Nodes;
		if (nodes == null) {
			return;
		}
		for (node in nodes) {
			if (node.Kind == KindFunctionDeclaration) {
				bind(node);
			}
		}
		for (node in nodes) {
			if (node.Kind != KindFunctionDeclaration) {
				bind(node);
			}
		}
	}

	function setContinueTarget(node:Node, target:FlowLabel):FlowLabel {
		var label = activeLabelList;
		while (label != null && node.Parent.Kind == KindLabeledStatement) {
			label.continueTarget = target;
			label = label.next;
			node = node.Parent;
		}
		return target;
	}

	function doWithConditionalBranches(action:(b:Binder, value:Node) -> Bool, value:Node, trueTarget:FlowLabel, falseTarget:FlowLabel):Void {
		final savedTrueTarget = currentTrueTarget;
		final savedFalseTarget = currentFalseTarget;
		currentTrueTarget = trueTarget;
		currentFalseTarget = falseTarget;
		action(this, value);
		currentTrueTarget = savedTrueTarget;
		currentFalseTarget = savedFalseTarget;
	}

	function bindCondition(node:Node, trueTarget:FlowLabel, falseTarget:FlowLabel):Void {
		doWithConditionalBranches(fn_bind, node, trueTarget, falseTarget);
		if (node == null
			|| !isLogicalAssignmentExpression(node) && !Ast.IsLogicalExpression(node) && !(Ast.IsOptionalChain(node) && Ast.IsOutermostOptionalChain(node))) {
			addAntecedent(trueTarget, createFlowCondition(FlowFlagsTrueCondition, currentFlow, node));
			addAntecedent(falseTarget, createFlowCondition(FlowFlagsFalseCondition, currentFlow, node));
		}
	}

	function bindIterativeStatement(node:Node, breakTarget:FlowLabel, continueTarget:FlowLabel):Void {
		final saveBreakTarget = currentBreakTarget;
		final saveContinueTarget = currentContinueTarget;
		currentBreakTarget = breakTarget;
		currentContinueTarget = continueTarget;
		bind(node);
		currentBreakTarget = saveBreakTarget;
		currentContinueTarget = saveContinueTarget;
	}

	static function isLogicalAssignmentExpression(node:Node):Bool {
		return Ast.IsLogicalOrCoalescingAssignmentExpression(Ast.SkipParentheses(node));
	}

	function bindAssignmentTargetFlow(node:Node):Void {
		switch (node.Kind) {
			case KindArrayLiteralExpression:
				final elements = node.Elements();
				if (elements != null) {
					for (e in elements) {
						if (e.Kind == KindSpreadElement) {
							bindAssignmentTargetFlow(e.Expression());
						} else {
							bindDestructuringTargetFlow(e);
						}
					}
				}
			case KindObjectLiteralExpression:
				final properties = node.Properties();
				if (properties != null) {
					for (p in properties) {
						switch (p.Kind) {
							case KindPropertyAssignment:
								bindDestructuringTargetFlow(p.Initializer());
							case KindShorthandPropertyAssignment:
								bindAssignmentTargetFlow(p.AsShorthandPropertyAssignment().Name());
							case KindSpreadAssignment:
								bindAssignmentTargetFlow(p.Expression());
							default:
						}
					}
				}
			default:
				if (isNarrowableReference(node)) {
					currentFlow = createFlowMutation(FlowFlagsAssignment, currentFlow, node);
				}
		}
	}

	function bindDestructuringTargetFlow(node:Node):Void {
		if (Ast.IsBinaryExpression(node) && node.AsBinaryExpression().OperatorToken.Kind == KindEqualsToken) {
			bindAssignmentTargetFlow(node.AsBinaryExpression().Left);
		} else {
			bindAssignmentTargetFlow(node);
		}
	}

	function bindWhileStatement(node:Node):Void {
		final stmt = node.AsWhileStatement();
		final preWhileLabel = setContinueTarget(node, createLoopLabel());
		final preBodyLabel = createBranchLabel();
		final postWhileLabel = createBranchLabel();
		addAntecedent(preWhileLabel, currentFlow);
		currentFlow = preWhileLabel;
		bindCondition(stmt.Expression, preBodyLabel, postWhileLabel);
		currentFlow = finishFlowLabel(preBodyLabel);
		bindIterativeStatement(stmt.Statement, postWhileLabel, preWhileLabel);
		addAntecedent(preWhileLabel, currentFlow);
		currentFlow = finishFlowLabel(postWhileLabel);
	}

	function bindDoStatement(node:Node):Void {
		final stmt = node.AsDoStatement();
		final preDoLabel = createLoopLabel();
		final preConditionLabel = setContinueTarget(node, createBranchLabel());
		final postDoLabel = createBranchLabel();
		addAntecedent(preDoLabel, currentFlow);
		currentFlow = preDoLabel;
		bindIterativeStatement(stmt.Statement, postDoLabel, preConditionLabel);
		addAntecedent(preConditionLabel, currentFlow);
		currentFlow = finishFlowLabel(preConditionLabel);
		bindCondition(stmt.Expression, preDoLabel, postDoLabel);
		currentFlow = finishFlowLabel(postDoLabel);
	}

	function bindForStatement(node:Node):Void {
		final stmt = node.AsForStatement();
		final preLoopLabel = setContinueTarget(node, createLoopLabel());
		final preBodyLabel = createBranchLabel();
		final preIncrementorLabel = createBranchLabel();
		final postLoopLabel = createBranchLabel();
		bind(stmt.Initializer);
		addAntecedent(preLoopLabel, currentFlow);
		currentFlow = preLoopLabel;
		bindCondition(stmt.Condition, preBodyLabel, postLoopLabel);
		currentFlow = finishFlowLabel(preBodyLabel);
		bindIterativeStatement(stmt.Statement, postLoopLabel, preIncrementorLabel);
		addAntecedent(preIncrementorLabel, currentFlow);
		currentFlow = finishFlowLabel(preIncrementorLabel);
		bind(stmt.Incrementor);
		addAntecedent(preLoopLabel, currentFlow);
		currentFlow = finishFlowLabel(postLoopLabel);
	}

	function bindForInOrForOfStatement(node:Node):Void {
		final stmt = node.AsForInOrOfStatement();
		final preLoopLabel = setContinueTarget(node, createLoopLabel());
		final postLoopLabel = createBranchLabel();
		bind(stmt.Expression);
		addAntecedent(preLoopLabel, currentFlow);
		currentFlow = preLoopLabel;
		if (node.Kind == KindForOfStatement) {
			bind(stmt.AwaitModifier);
		}
		addAntecedent(postLoopLabel, currentFlow);
		bind(stmt.Initializer);
		if (stmt.Initializer.Kind != KindVariableDeclarationList) {
			bindAssignmentTargetFlow(stmt.Initializer);
		}
		bindIterativeStatement(stmt.Statement, postLoopLabel, preLoopLabel);
		addAntecedent(preLoopLabel, currentFlow);
		currentFlow = finishFlowLabel(postLoopLabel);
	}

	function bindIfStatement(node:Node):Void {
		final stmt = node.AsIfStatement();
		final thenLabel = createBranchLabel();
		final elseLabel = createBranchLabel();
		final postIfLabel = createBranchLabel();
		bindCondition(stmt.Expression, thenLabel, elseLabel);
		currentFlow = finishFlowLabel(thenLabel);
		bind(stmt.ThenStatement);
		addAntecedent(postIfLabel, currentFlow);
		currentFlow = finishFlowLabel(elseLabel);
		bind(stmt.ElseStatement);
		addAntecedent(postIfLabel, currentFlow);
		currentFlow = finishFlowLabel(postIfLabel);
	}

	function bindReturnStatement(node:Node):Void {
		bind(node.Expression());
		if (currentReturnTarget != null) {
			addAntecedent(currentReturnTarget, currentFlow);
		}
		currentFlow = unreachableFlow;
		hasExplicitReturn = true;
		hasFlowEffects = true;
	}

	function bindThrowStatement(node:Node):Void {
		bind(node.Expression());
		currentFlow = unreachableFlow;
		hasFlowEffects = true;
	}

	function bindBreakStatement(node:Node):Void {
		bindBreakOrContinueStatement(node.Label(), currentBreakTarget, fn_BreakTarget);
	}

	function bindContinueStatement(node:Node):Void {
		bindBreakOrContinueStatement(node.Label(), currentContinueTarget, fn_ContinueTarget);
	}

	function bindBreakOrContinueStatement(label:Node, currentTarget:FlowNode, getTarget:(label:ActiveLabel) -> FlowNode):Void {
		bind(label);
		if (label != null) {
			final activeLabel = findActiveLabel(label.Text());
			if (activeLabel != null) {
				activeLabel.referenced = true;
				bindBreakOrContinueFlow(getTarget(activeLabel));
			}
		} else {
			bindBreakOrContinueFlow(currentTarget);
		}
	}

	function findActiveLabel(name:std.String):ActiveLabel {
		var label = activeLabelList;
		while (label != null) {
			if (label.name == name) {
				return label;
			}
			label = label.next;
		}
		return null;
	}

	function bindBreakOrContinueFlow(flowLabel:FlowLabel):Void {
		if (flowLabel != null) {
			addAntecedent(flowLabel, currentFlow);
			currentFlow = unreachableFlow;
			hasFlowEffects = true;
		}
	}

	function bindTryStatement(node:Node):Void {
		// We conservatively assume that *any* code in the try block can cause an exception, but we only need
		// to track code that causes mutations (because only mutations widen the possible control flow type of
		// a variable). The exceptionLabel is the target label for control flows that result from exceptions.
		// We add all mutation flow nodes as antecedents of this label such that we can analyze them as possible
		// antecedents of the start of catch or finally blocks. Furthermore, we add the current control flow to
		// represent exceptions that occur before any mutations.
		final stmt = node.AsTryStatement();
		final saveReturnTarget = currentReturnTarget;
		final saveExceptionTarget = currentExceptionTarget;
		final normalExitLabel = createBranchLabel();
		final returnLabel = createBranchLabel();
		var exceptionLabel = createBranchLabel();
		if (stmt.FinallyBlock != null) {
			currentReturnTarget = returnLabel;
		}
		addAntecedent(exceptionLabel, currentFlow);
		currentExceptionTarget = exceptionLabel;
		bind(stmt.TryBlock);
		addAntecedent(normalExitLabel, currentFlow);
		if (stmt.CatchClause != null) {
			// Start of catch clause is the target of exceptions from try block.
			currentFlow = finishFlowLabel(exceptionLabel);
			// The currentExceptionTarget now represents control flows from exceptions in the catch clause.
			// Effectively, in a try-catch-finally, if an exception occurs in the try block, the catch block
			// acts like a second try block.
			exceptionLabel = createBranchLabel();
			addAntecedent(exceptionLabel, currentFlow);
			currentExceptionTarget = exceptionLabel;
			bind(stmt.CatchClause);
			addAntecedent(normalExitLabel, currentFlow);
		}
		currentReturnTarget = saveReturnTarget;
		currentExceptionTarget = saveExceptionTarget;
		if (stmt.FinallyBlock != null) {
			// Possible ways control can reach the finally block:
			// 1) Normal completion of try block of a try-finally or try-catch-finally
			// 2) Normal completion of catch block (following exception in try block) of a try-catch-finally
			// 3) Return in try or catch block of a try-finally or try-catch-finally
			// 4) Exception in try block of a try-finally
			// 5) Exception in catch block of a try-catch-finally
			// When analyzing a control flow graph that starts inside a finally block we want to consider all
			// five possibilities above. However, when analyzing a control flow graph that starts outside (past)
			// the finally block, we only want to consider the first two (if we're past a finally block then it
			// must have completed normally). Likewise, when analyzing a control flow graph from return statements
			// in try or catch blocks in an IIFE, we only want to consider the third. To make this possible, we
			// inject a ReduceLabel node into the control flow graph. This node contains an alternate reduced
			// set of antecedents for the pre-finally label. As control flow analysis passes by a ReduceLabel
			// node, the pre-finally label is temporarily switched to the reduced antecedent set.
			final finallyLabel = createBranchLabel();
			finallyLabel.Antecedents = combineFlowLists(normalExitLabel.Antecedents, combineFlowLists(exceptionLabel.Antecedents, returnLabel.Antecedents));
			currentFlow = finallyLabel;
			bind(stmt.FinallyBlock);
			if (currentFlow.Flags & FlowFlagsUnreachable != 0) {
				// If the end of the finally block is unreachable, the end of the entire try statement is unreachable.
				currentFlow = unreachableFlow;
			} else {
				// If we have an IIFE return target and return statements in the try or catch blocks, add a control
				// flow that goes back through the finally block and back through only the return statements.
				if (currentReturnTarget != null && returnLabel.Antecedents != null) {
					addAntecedent(currentReturnTarget, createReduceLabel(finallyLabel, returnLabel.Antecedents, currentFlow));
				}
				// If we have an outer exception target (i.e. a containing try-finally or try-catch-finally), add a
				// control flow that goes back through the finally block and back through each possible exception source.
				if (currentExceptionTarget != null && exceptionLabel.Antecedents != null) {
					addAntecedent(currentExceptionTarget, createReduceLabel(finallyLabel, exceptionLabel.Antecedents, currentFlow));
				}
				// If the end of the finally block is reachable, but the end of the try and catch blocks are not,
				// convert the current flow to unreachable. For example, 'try { return 1; } finally { ... }' should
				// result in an unreachable current control flow.
				if (normalExitLabel.Antecedents != null) {
					currentFlow = createReduceLabel(finallyLabel, normalExitLabel.Antecedents, currentFlow);
				} else {
					currentFlow = unreachableFlow;
				}
			}
		} else {
			currentFlow = finishFlowLabel(normalExitLabel);
		}
	}

	static final fl_isDefaultClause:(c:Node) -> Bool = c -> c.Kind == KindDefaultClause;

	function bindSwitchStatement(node:Node):Void {
		final stmt = node.AsSwitchStatement();
		final postSwitchLabel = createBranchLabel();
		bind(stmt.Expression);
		final saveBreakTarget = currentBreakTarget;
		final savePreSwitchCaseFlow = preSwitchCaseFlow;
		currentBreakTarget = postSwitchLabel;
		preSwitchCaseFlow = currentFlow;
		bind(stmt.CaseBlock);
		addAntecedent(postSwitchLabel, currentFlow);
		final hasDefault = Core.Some(stmt.CaseBlock.AsCaseBlock().Clauses.Nodes, fl_isDefaultClause);
		if (!hasDefault) {
			addAntecedent(postSwitchLabel, createFlowSwitchClause(preSwitchCaseFlow, node, 0, 0));
		}
		currentBreakTarget = saveBreakTarget;
		preSwitchCaseFlow = savePreSwitchCaseFlow;
		currentFlow = finishFlowLabel(postSwitchLabel);
	}

	function bindCaseBlock(node:Node):Void {
		final switchStatement = node.Parent;
		final clauses = node.AsCaseBlock().Clauses.Nodes;
		final isNarrowingSwitch = switchStatement.Expression().Kind == KindTrueKeyword || isNarrowingExpression(switchStatement.Expression());
		var fallthroughFlow:FlowNode = unreachableFlow;
		var i = 0;
		while (i < Core.len(clauses)) {
			final clauseStart = i;
			while (Core.len(clauses[i].Statements()) == 0 && i + 1 < clauses.length) {
				if (fallthroughFlow == unreachableFlow) {
					currentFlow = preSwitchCaseFlow;
				}
				bind(clauses[i]);
				i++;
			}
			final preCaseLabel = createBranchLabel();
			var preCaseFlow = preSwitchCaseFlow;
			if (isNarrowingSwitch) {
				preCaseFlow = createFlowSwitchClause(preSwitchCaseFlow, switchStatement, clauseStart, i + 1);
			}
			addAntecedent(preCaseLabel, preCaseFlow);
			addAntecedent(preCaseLabel, fallthroughFlow);
			currentFlow = finishFlowLabel(preCaseLabel);
			final clause = clauses[i];
			bind(clause);
			fallthroughFlow = currentFlow;
			if (currentFlow.Flags & FlowFlagsUnreachable == 0 && i != clauses.length - 1) {
				clause.AsCaseOrDefaultClause().FallthroughFlowNode = currentFlow;
			}
			i++;
		}
	}

	function bindCaseOrDefaultClause(node:Node):Void {
		final clause = node.AsCaseOrDefaultClause();
		if (clause.Expression != null) {
			final saveCurrentFlow = currentFlow;
			currentFlow = preSwitchCaseFlow;
			bind(clause.Expression);
			currentFlow = saveCurrentFlow;
		}
		bindEach(clause.Statements.Nodes);
	}

	function bindExpressionStatement(node:Node):Void {
		final stmt = node.AsExpressionStatement();
		bind(stmt.Expression);
		maybeBindExpressionFlowIfCall(stmt.Expression);
	}

	function maybeBindExpressionFlowIfCall(node:Node):Void {
		// A top level or comma expression call expression with a dotted function name and at least one argument
		// is potentially an assertion and is therefore included in the control flow.
		if (Ast.IsCallExpression(node)) {
			if (node.Expression().Kind != KindSuperKeyword && Ast.IsDottedName(node.Expression())) {
				currentFlow = createFlowCall(currentFlow, node);
			}
		}
	}

	function bindLabeledStatement(node:Node):Void {
		final stmt = node.AsLabeledStatement();
		final postStatementLabel = createBranchLabel();
		final label = new ActiveLabel();
		label.next = activeLabelList;
		label.name = stmt.Label.Text();
		label.breakTarget = postStatementLabel;
		label.continueTarget = null;
		label.referenced = false;
		activeLabelList = label;
		bind(stmt.Label);
		bind(stmt.Statement);
		if (!activeLabelList.referenced) {
			// Mark the label as unused; the checker will decide whether to report it
			stmt.Label.Flags |= NodeFlagsUnreachable;
		}
		activeLabelList = activeLabelList.next;
		addAntecedent(postStatementLabel, currentFlow);
		currentFlow = finishFlowLabel(postStatementLabel);
	}

	function bindPrefixUnaryExpressionFlow(node:Node):Void {
		final expr = node.AsPrefixUnaryExpression();
		if (expr.Operator == KindExclamationToken) {
			final saveTrueTarget = currentTrueTarget;
			currentTrueTarget = currentFalseTarget;
			currentFalseTarget = saveTrueTarget;
			bindEachChild(node);
			currentFalseTarget = currentTrueTarget;
			currentTrueTarget = saveTrueTarget;
		} else {
			bindEachChild(node);
			if (expr.Operator == KindPlusPlusToken || expr.Operator == KindMinusMinusToken) {
				bindAssignmentTargetFlow(expr.Operand);
			}
		}
	}

	function bindPostfixUnaryExpressionFlow(node:Node):Void {
		final expr = node.AsPostfixUnaryExpression();
		bindEachChild(node);
		if (expr.Operator == KindPlusPlusToken || expr.Operator == KindMinusMinusToken) {
			bindAssignmentTargetFlow(expr.Operand);
		}
	}

	function bindDestructuringAssignmentFlow(node:Node):Void {
		final expr = node.AsBinaryExpression();
		if (inAssignmentPattern) {
			inAssignmentPattern = false;
			bind(expr.OperatorToken);
			bind(expr.Right);
			inAssignmentPattern = true;
			bind(expr.Left);
			bind(expr.Type);
		} else {
			inAssignmentPattern = true;
			bind(expr.Left);
			bind(expr.Type);
			inAssignmentPattern = false;
			bind(expr.OperatorToken);
			bind(expr.Right);
		}
		bindAssignmentTargetFlow(expr.Left);
	}

	function bindBinaryExpressionFlow(node:Node):Void {
		final expr = node.AsBinaryExpression();
		final operator_ = expr.OperatorToken.Kind;
		if (Ast.IsLogicalOrCoalescingBinaryOperator(operator_) || Ast.IsLogicalOrCoalescingAssignmentOperator(operator_)) {
			if (isTopLevelLogicalExpression(node)) {
				final postExpressionLabel = createBranchLabel();
				final saveCurrentFlow = currentFlow;
				final saveHasFlowEffects = hasFlowEffects;
				hasFlowEffects = false;
				bindLogicalLikeExpression(node, postExpressionLabel, postExpressionLabel);
				if (hasFlowEffects) {
					currentFlow = finishFlowLabel(postExpressionLabel);
				} else {
					currentFlow = saveCurrentFlow;
				}
				hasFlowEffects = hasFlowEffects || saveHasFlowEffects;
			} else {
				bindLogicalLikeExpression(node, currentTrueTarget, currentFalseTarget);
			}
		} else {
			bind(expr.Left);
			bind(expr.Type);
			if (operator_ == KindCommaToken) {
				maybeBindExpressionFlowIfCall(expr.Left);
			}
			bind(expr.OperatorToken);
			bind(expr.Right);
			if (operator_ == KindCommaToken) {
				maybeBindExpressionFlowIfCall(expr.Right);
			}
			if (Ast.IsAssignmentOperator(operator_) && !Ast.IsAssignmentTarget(node)) {
				bindAssignmentTargetFlow(expr.Left);
				if (operator_ == KindEqualsToken && expr.Left.Kind == KindElementAccessExpression) {
					final elementAccess = expr.Left.AsElementAccessExpression();
					if (isNarrowableOperand(elementAccess.Expression)) {
						currentFlow = createFlowMutation(FlowFlagsArrayMutation, currentFlow, node);
					}
				}
			}
		}
	}

	function bindLogicalLikeExpression(node:Node, trueTarget:FlowLabel, falseTarget:FlowLabel):Void {
		final expr = node.AsBinaryExpression();
		final preRightLabel = createBranchLabel();
		if (expr.OperatorToken.Kind == KindAmpersandAmpersandToken || expr.OperatorToken.Kind == KindAmpersandAmpersandEqualsToken) {
			bindCondition(expr.Left, preRightLabel, falseTarget);
		} else {
			bindCondition(expr.Left, trueTarget, preRightLabel);
		}
		currentFlow = finishFlowLabel(preRightLabel);
		bind(expr.OperatorToken);
		if (Ast.IsLogicalOrCoalescingAssignmentOperator(expr.OperatorToken.Kind)) {
			doWithConditionalBranches(fn_bind, expr.Right, trueTarget, falseTarget);
			bindAssignmentTargetFlow(expr.Left);
			addAntecedent(trueTarget, createFlowCondition(FlowFlagsTrueCondition, currentFlow, node));
			addAntecedent(falseTarget, createFlowCondition(FlowFlagsFalseCondition, currentFlow, node));
		} else {
			bindCondition(expr.Right, trueTarget, falseTarget);
		}
	}

	function bindDeleteExpressionFlow(node:Node):Void {
		final expr = node.AsDeleteExpression();
		bindEachChild(node);
		if (expr.Expression.Kind == KindPropertyAccessExpression) {
			bindAssignmentTargetFlow(expr.Expression);
		}
	}

	function bindConditionalExpressionFlow(node:Node):Void {
		final expr = node.AsConditionalExpression();
		final trueLabel = createBranchLabel();
		final falseLabel = createBranchLabel();
		final postExpressionLabel = createBranchLabel();
		final saveCurrentFlow = currentFlow;
		final saveHasFlowEffects = hasFlowEffects;
		hasFlowEffects = false;
		bindCondition(expr.Condition, trueLabel, falseLabel);
		currentFlow = finishFlowLabel(trueLabel);
		bind(expr.QuestionToken);
		bind(expr.WhenTrue);
		addAntecedent(postExpressionLabel, currentFlow);
		currentFlow = finishFlowLabel(falseLabel);
		bind(expr.ColonToken);
		bind(expr.WhenFalse);
		addAntecedent(postExpressionLabel, currentFlow);
		if (hasFlowEffects) {
			currentFlow = finishFlowLabel(postExpressionLabel);
		} else {
			currentFlow = saveCurrentFlow;
		}
		hasFlowEffects = hasFlowEffects || saveHasFlowEffects;
	}

	function bindVariableDeclarationFlow(node:Node):Void {
		bindEachChild(node);
		if (node.Initializer() != null || Ast.IsForInOrOfStatement(node.Parent.Parent)) {
			bindInitializedVariableFlow(node);
		}
	}

	function bindInitializedVariableFlow(node:Node):Void {
		var name:Node = null;
		switch (node.Kind) {
			case KindVariableDeclaration:
				name = node.AsVariableDeclaration().Name();
			case KindBindingElement:
				name = node.AsBindingElement().Name();
			default:
		}
		if (name != null && Ast.IsBindingPattern(name)) {
			final elements = name.Elements();
			if (elements != null) {
				for (child in elements) {
					bindInitializedVariableFlow(child);
				}
			}
		} else {
			currentFlow = createFlowMutation(FlowFlagsAssignment, currentFlow, node);
		}
	}

	function bindAccessExpressionFlow(node:Node):Void {
		if (Ast.IsOptionalChain(node)) {
			bindOptionalChainFlow(node);
		} else {
			bindEachChild(node);
		}
	}

	function bindOptionalChainFlow(node:Node):Void {
		if (isTopLevelLogicalExpression(node)) {
			final postExpressionLabel = createBranchLabel();
			final saveCurrentFlow = currentFlow;
			final saveHasFlowEffects = hasFlowEffects;
			bindOptionalChain(node, postExpressionLabel, postExpressionLabel);
			if (hasFlowEffects) {
				currentFlow = finishFlowLabel(postExpressionLabel);
			} else {
				currentFlow = saveCurrentFlow;
			}
			hasFlowEffects = hasFlowEffects || saveHasFlowEffects;
		} else {
			bindOptionalChain(node, currentTrueTarget, currentFalseTarget);
		}
	}

	function bindOptionalChain(node:Node, trueTarget:FlowLabel, falseTarget:FlowLabel):Void {
		// For an optional chain, we emulate the behavior of a logical expression:
		//
		// a?.b         -> a && a.b
		// a?.b.c       -> a && a.b.c
		// a?.b?.c      -> a && a.b && a.b.c
		// a?.[x = 1]   -> a && a[x = 1]
		//
		// To do this we descend through the chain until we reach the root of a chain (the expression with a `?.`)
		// and build it's CFA graph as if it were the first condition (`a && ...`). Then we bind the rest
		// of the node as part of the "true" branch, and continue to do so as we ascend back up to the outermost
		// chain node. We then treat the entire node as the right side of the expression.
		var preChainLabel:FlowLabel = null;
		if (Ast.IsOptionalChainRoot(node)) {
			preChainLabel = createBranchLabel();
		}
		bindOptionalExpression(node.Expression(), Core.IfElse(preChainLabel != null, preChainLabel, trueTarget), falseTarget);
		if (preChainLabel != null) {
			currentFlow = finishFlowLabel(preChainLabel);
		}
		doWithConditionalBranches(fn_bindOptionalChainRest, node, trueTarget, falseTarget);
		if (Ast.IsOutermostOptionalChain(node)) {
			addAntecedent(trueTarget, createFlowCondition(FlowFlagsTrueCondition, currentFlow, node));
			addAntecedent(falseTarget, createFlowCondition(FlowFlagsFalseCondition, currentFlow, node));
		}
	}

	function bindOptionalExpression(node:Node, trueTarget:FlowLabel, falseTarget:FlowLabel):Void {
		doWithConditionalBranches(fn_bind, node, trueTarget, falseTarget);
		if (!Ast.IsOptionalChain(node) || Ast.IsOutermostOptionalChain(node)) {
			addAntecedent(trueTarget, createFlowCondition(FlowFlagsTrueCondition, currentFlow, node));
			addAntecedent(falseTarget, createFlowCondition(FlowFlagsFalseCondition, currentFlow, node));
		}
	}

	function bindOptionalChainRest(node:Node):Bool {
		switch (node.Kind) {
			case KindPropertyAccessExpression:
				bind(node.QuestionDotToken());
				bind(node.Name());
			case KindElementAccessExpression:
				bind(node.QuestionDotToken());
				bind(node.AsElementAccessExpression().ArgumentExpression);
			case KindCallExpression:
				bind(node.QuestionDotToken());
				bindNodeList(node.TypeArgumentList());
				bindEach(node.Arguments());
			default:
		}
		return false;
	}

	function bindCallExpressionFlow(node:Node):Void {
		final call = node.AsCallExpression();
		if (Ast.IsOptionalChain(node)) {
			bindOptionalChainFlow(node);
		} else {
			// If the target of the call expression is a function expression or arrow function we have
			// an immediately invoked function expression (IIFE). Initialize the flowNode property to
			// the current control flow (which includes evaluation of the IIFE arguments).
			final expr = Ast.SkipParentheses(call.Expression);
			if (expr.Kind == KindFunctionExpression || expr.Kind == KindArrowFunction) {
				bindNodeList(call.TypeArguments);
				bindEach(call.Arguments.Nodes);
				bind(call.Expression);
			} else {
				bindEachChild(node);
				if (call.Expression.Kind == KindSuperKeyword) {
					currentFlow = createFlowCall(currentFlow, node);
				}
			}
		}
		if (Ast.IsPropertyAccessExpression(call.Expression)) {
			final access = call.Expression.AsPropertyAccessExpression();
			if (Ast.IsIdentifier(access.Name()) && isNarrowableOperand(access.Expression) && Ast.IsPushOrUnshiftIdentifier(access.Name())) {
				currentFlow = createFlowMutation(FlowFlagsArrayMutation, currentFlow, node);
			}
		}
	}

	function bindNonNullExpressionFlow(node:Node):Void {
		if (Ast.IsOptionalChain(node)) {
			bindOptionalChainFlow(node);
		} else {
			bindEachChild(node);
		}
	}

	function bindBindingElementFlow(node:Node):Void {
		// When evaluating a binding pattern, the initializer is evaluated before the binding pattern, per:
		// - https://tc39.es/ecma262/#sec-destructuring-binding-patterns-runtime-semantics-iteratorbindinginitialization
		//   - `BindingElement: BindingPattern Initializer?`
		// - https://tc39.es/ecma262/#sec-runtime-semantics-keyedbindinginitialization
		//   - `BindingElement: BindingPattern Initializer?`
		final elem = node.AsBindingElement();
		bind(elem.DotDotDotToken);
		bind(elem.PropertyName);
		bindInitializer(elem.Initializer);
		bind(elem.Name());
	}

	function bindParameterFlow(node:Node):Void {
		final param = node.AsParameterDeclaration();
		bindModifiers(param.Modifiers());
		bind(param.DotDotDotToken);
		bind(param.QuestionToken);
		bind(param.Type);
		bindInitializer(param.Initializer);
		bind(param.Name());
	}

	// a BindingElement/Parameter does not have side effects if initializers are not evaluated and used. (see GH#49759)
	function bindInitializer(node:Node):Void {
		if (node == null) {
			return;
		}
		final entryFlow = currentFlow;
		bind(node);
		if (entryFlow == unreachableFlow || entryFlow == currentFlow) {
			return;
		}
		final exitFlow = createBranchLabel();
		addAntecedent(exitFlow, entryFlow);
		addAntecedent(exitFlow, currentFlow);
		currentFlow = finishFlowLabel(exitFlow);
	}

	static function setFlowNode(node:Node, flowNode:FlowNode):Void {
		final data = node.FlowNodeData();
		if (data != null) {
			data.FlowNode = flowNode;
		}
	}

	static function setReturnFlowNode(node:Node, returnFlowNode:FlowNode):Void {
		switch (node.Kind) {
			case KindConstructor:
				node.AsConstructorDeclaration().ReturnFlowNode = returnFlowNode;
			case KindFunctionDeclaration:
				node.AsFunctionDeclaration().ReturnFlowNode = returnFlowNode;
			case KindFunctionExpression:
				node.AsFunctionExpression().ReturnFlowNode = returnFlowNode;
			case KindClassStaticBlockDeclaration:
				node.AsClassStaticBlockDeclaration().ReturnFlowNode = returnFlowNode;
			default:
		}
	}

	static function isGeneratorFunctionExpression(node:Node):Bool {
		return Ast.IsFunctionExpression(node) && node.AsFunctionExpression().AsteriskToken != null;
	}

	function addToContainerChain(next:Node):Void {
		if (lastContainer != null) {
			lastContainer.LocalsContainerData().NextContainer = next;
		}
		lastContainer = next;
	}

	function addDeclarationToSymbol(symbol:Symbol, node:Node, symbolFlags:SymbolFlags):Void {
		symbol.Flags |= symbolFlags;
		node.DeclarationData().Symbol = symbol;
		if (symbol.Declarations == null) {
			symbol.Declarations = newSingleDeclaration(node);
		} else {
			symbol.Declarations = Core.AppendIfUnique(symbol.Declarations, node);
		}
		// On merge of const enum module with class or function, reset const enum only flag (namespaces will already recalculate)
		if (symbol.Flags & SymbolFlagsConstEnumOnlyModule != 0 && symbol.Flags & (SymbolFlagsFunction | SymbolFlagsClass | SymbolFlagsRegularEnum) != 0) {
			symbol.Flags = symbol.Flags & ~SymbolFlagsConstEnumOnlyModule;
			notConstEnumOnlyModules.Add(symbol);
		}
		if (symbolFlags & SymbolFlagsValue != 0) {
			SetValueDeclaration(symbol, node);
		}
	}

	public static function SetValueDeclaration(symbol:Symbol, node:Node):Void {
		final valueDeclaration = symbol.ValueDeclaration;
		if (valueDeclaration == null
			|| isAssignmentDeclaration(valueDeclaration) && !isAssignmentDeclaration(node)
			|| valueDeclaration.Kind != node.Kind && isEffectiveModuleDeclaration(valueDeclaration)) {
			// Non-assignment declarations take precedence over assignment declarations and
			// non-namespace declarations take precedence over namespace declarations.
			symbol.ValueDeclaration = node;
		}
	}

	/**
	 * Declares a Symbol for the node and adds it to symbols. Reports errors for conflicting identifier names.
	 * @param symbolTable - The symbol table which node will be added to.
	 * @param parent - node's parent declaration.
	 * @param node - The declaration to be added to the symbol table
	 * @param includes - The SymbolFlags that node has in addition to its declaration type (eg: export, ambient, etc.)
	 * @param excludes - The flags which node cannot be declared alongside in a symbol table. Used to report forbidden declarations.
	 */
	public static function GetContainerFlags(node:Node):ContainerFlags {
		switch (node.Kind) {
			case KindClassExpression | KindClassDeclaration | KindEnumDeclaration | KindObjectLiteralExpression | KindTypeLiteral | KindJsxAttributes:
				return ContainerFlagsIsContainer;
			case KindInterfaceDeclaration:
				return ContainerFlagsIsContainer | ContainerFlagsIsInterface;
			case KindModuleDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindMappedType | KindIndexSignature:
				return ContainerFlagsIsContainer | ContainerFlagsHasLocals;
			case KindSourceFile:
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals;
			case KindGetAccessor | KindSetAccessor | KindMethodDeclaration:
				if (Ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(node)) {
					return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
						| ContainerFlagsIsObjectLiteralOrClassExpressionMethodOrAccessor | ContainerFlagsIsThisContainer;
				}
				// PORT: fallthrough → duplicated case body.
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
					| ContainerFlagsIsThisContainer;
			case KindConstructor | KindFunctionDeclaration | KindClassStaticBlockDeclaration:
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
					| ContainerFlagsIsThisContainer;
			case KindMethodSignature | KindCallSignature | KindFunctionType | KindConstructSignature | KindConstructorType:
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
					| ContainerFlagsPropagatesThisKeyword;
			case KindFunctionExpression:
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
					| ContainerFlagsIsFunctionExpression | ContainerFlagsIsThisContainer;
			case KindArrowFunction:
				return ContainerFlagsIsContainer | ContainerFlagsIsControlFlowContainer | ContainerFlagsHasLocals | ContainerFlagsIsFunctionLike
					| ContainerFlagsIsFunctionExpression | ContainerFlagsPropagatesThisKeyword;
			case KindModuleBlock:
				return ContainerFlagsIsControlFlowContainer;
			case KindPropertyDeclaration:
				if (node.Initializer() != null) {
					return ContainerFlagsIsControlFlowContainer | ContainerFlagsIsThisContainer;
				} else {
					return ContainerFlagsNone;
				}
			case KindCatchClause | KindForStatement | KindForInStatement | KindForOfStatement | KindCaseBlock:
				return ContainerFlagsIsBlockScopedContainer | ContainerFlagsHasLocals;
			case KindBlock:
				if (Ast.IsFunctionLike(node.Parent) || Ast.IsClassStaticBlockDeclaration(node.Parent)) {
					return ContainerFlagsNone;
				} else {
					return ContainerFlagsIsBlockScopedContainer | ContainerFlagsHasLocals;
				}
			default:
		}
		return ContainerFlagsNone;
	}

	static function isNarrowingExpression(expr:Node):Bool {
		switch (expr.Kind) {
			case KindIdentifier | KindThisKeyword:
				return true;
			case KindPropertyAccessExpression | KindElementAccessExpression:
				return containsNarrowableReference(expr);
			case KindCallExpression:
				return hasNarrowableArgument(expr);
			case KindParenthesizedExpression | KindNonNullExpression | KindTypeOfExpression:
				return isNarrowingExpression(expr.Expression());
			case KindBinaryExpression:
				return isNarrowingBinaryExpression(expr.AsBinaryExpression());
			case KindPrefixUnaryExpression:
				return expr.AsPrefixUnaryExpression().Operator == KindExclamationToken && isNarrowingExpression(expr.AsPrefixUnaryExpression().Operand);
			default:
		}
		return false;
	}

	static function containsNarrowableReference(expr:Node):Bool {
		if (isNarrowableReference(expr)) {
			return true;
		}
		if (expr.Flags & NodeFlagsOptionalChain != 0) {
			switch (expr.Kind) {
				case KindPropertyAccessExpression | KindElementAccessExpression | KindCallExpression | KindNonNullExpression:
					return containsNarrowableReference(expr.Expression());
				default:
			}
		}
		return false;
	}

	static function isNarrowableReference(node:Node):Bool {
		switch (node.Kind) {
			case KindIdentifier | KindThisKeyword | KindSuperKeyword | KindMetaProperty:
				return true;
			case KindPropertyAccessExpression | KindParenthesizedExpression | KindNonNullExpression:
				return isNarrowableReference(node.Expression());
			case KindElementAccessExpression:
				final expr = node.AsElementAccessExpression();
				return Ast.IsStringOrNumericLiteralLike(expr.ArgumentExpression)
					|| Ast.IsEntityNameExpression(expr.ArgumentExpression) && isNarrowableReference(expr.Expression);
			case KindBinaryExpression:
				final expr = node.AsBinaryExpression();
				return expr.OperatorToken.Kind == KindCommaToken && isNarrowableReference(expr.Right)
					|| Ast.IsAssignmentOperator(expr.OperatorToken.Kind) && Ast.IsLeftHandSideExpression(expr.Left);
			default:
		}
		return false;
	}

	static function hasNarrowableArgument(expr:Node):Bool {
		final call = expr.AsCallExpression();
		if (call.Arguments.Nodes != null) {
			for (argument in call.Arguments.Nodes) {
				if (containsNarrowableReference(argument)) {
					return true;
				}
			}
		}
		if (Ast.IsPropertyAccessExpression(call.Expression)) {
			if (containsNarrowableReference(call.Expression.Expression())) {
				return true;
			}
		}
		return false;
	}

	static function isNarrowingBinaryExpression(expr:BinaryExpression):Bool {
		switch (expr.OperatorToken.Kind) {
			case KindEqualsToken | KindBarBarEqualsToken | KindAmpersandAmpersandEqualsToken | KindQuestionQuestionEqualsToken:
				return containsNarrowableReference(expr.Left);
			case KindEqualsEqualsToken | KindExclamationEqualsToken | KindEqualsEqualsEqualsToken | KindExclamationEqualsEqualsToken:
				final left = Ast.SkipParentheses(expr.Left);
				final right = Ast.SkipParentheses(expr.Right);
				return isNarrowableOperand(left)
					|| isNarrowableOperand(right)
					|| isNarrowingTypeOfOperands(right, left)
					|| isNarrowingTypeOfOperands(left, right)
					|| (Ast.IsBooleanLiteral(right) && isNarrowingExpression(left) || Ast.IsBooleanLiteral(left) && isNarrowingExpression(right));
			case KindInstanceOfKeyword:
				return isNarrowableOperand(expr.Left);
			case KindInKeyword:
				return isNarrowingExpression(expr.Right);
			case KindCommaToken:
				return isNarrowingExpression(expr.Right);
			default:
		}
		return false;
	}

	static function isNarrowableOperand(expr:Node):Bool {
		switch (expr.Kind) {
			case KindParenthesizedExpression:
				return isNarrowableOperand(expr.Expression());
			case KindBinaryExpression:
				final binary = expr.AsBinaryExpression();
				switch (binary.OperatorToken.Kind) {
					case KindEqualsToken:
						return isNarrowableOperand(binary.Left);
					case KindCommaToken:
						return isNarrowableOperand(binary.Right);
					default:
				}
			default:
		}
		return containsNarrowableReference(expr);
	}

	static function isNarrowingTypeOfOperands(expr1:Node, expr2:Node):Bool {
		return Ast.IsTypeOfExpression(expr1) && isNarrowableOperand(expr1.Expression()) && Ast.IsStringLiteralLike(expr2);
	}

	function errorOnNode(node:Node, message:Message, ...args:Any):Void {
		addDiagnostic(createDiagnosticForNode(node, message, ...args));
	}

	function errorOnFirstToken(node:Node, message:Message, ...args:Any):Void {
		final span = Scanner.GetRangeOfTokenAtPosition(file, node.Pos());
		addDiagnostic(Ast.NewDiagnostic(file, span, message, ...args));
	}

	function errorOrSuggestionOnNode(isError:Bool, node:Node, message:Message):Void {
		errorOrSuggestionOnRange(isError, node, node, message);
	}

	function errorOrSuggestionOnRange(isError:Bool, startNode:Node, endNode:Node, message:Message):Void {
		final textRange = Core.NewTextRange(Scanner.GetRangeOfTokenAtPosition(file, startNode.Pos()).Pos(), endNode.End());
		final diagnostic = Ast.NewDiagnostic(file, textRange, message);
		if (isError) {
			addDiagnostic(diagnostic);
		} else {
			diagnostic.SetCategory(CategorySuggestion);
			if (file.BindSuggestionDiagnostics == null) {
				file.BindSuggestionDiagnostics = [];
			}
			file.BindSuggestionDiagnostics.push(diagnostic);
		}
	}

	// Inside the binder, we may create a diagnostic for an as-yet unbound node (with potentially no parent pointers, implying no accessible source file)
	// If so, the node _must_ be in the current file (as that's the only way anything could have traversed to it to yield it as the error node)
	// This version of `createDiagnosticForNode` uses the binder's context to account for this, and always yields correct diagnostics even in these situations.
	function createDiagnosticForNode(node:Node, message:Message, ...args:Any):Diagnostic {
		return Ast.NewDiagnostic(file, Scanner.GetErrorRangeForNode(file, node), message, ...args);
	}

	function addDiagnostic(diagnostic:Diagnostic):Void {
		var diags = file.BindDiagnostics();
		if (diags == null) {
			diags = [];
		}
		diags.push(diagnostic);
		file.SetBindDiagnostics(diags);
	}

	static function isSignedNumericLiteral(node:Node):Bool {
		if (node.Kind == KindPrefixUnaryExpression) {
			final node = node.AsPrefixUnaryExpression();
			return (node.Operator == KindPlusToken || node.Operator == KindMinusToken) && Ast.IsNumericLiteral(node.Operand);
		}
		return false;
	}

	static function getOptionalSymbolFlagForNode(node:Node):SymbolFlags {
		final postfixToken = node.PostfixToken();
		return Core.IfElse(postfixToken != null && postfixToken.Kind == KindQuestionToken, SymbolFlagsOptional, SymbolFlagsNone);
	}

	static function isFunctionSymbol(symbol:Symbol):Bool {
		final d = symbol.ValueDeclaration;
		if (d != null) {
			if (Ast.IsFunctionDeclaration(d)) {
				return true;
			}
			if (Ast.IsVariableDeclaration(d)) {
				final varDecl = d.AsVariableDeclaration();
				if (varDecl.Initializer != null) {
					return Ast.IsFunctionLike(varDecl.Initializer);
				}
			}
		}
		return false;
	}

	static function isStatementCondition(node:Node):Bool {
		switch (node.Parent.Kind) {
			case KindIfStatement | KindWhileStatement | KindDoStatement:
				return node.Parent.Expression() == node;
			case KindForStatement:
				return node.Parent.AsForStatement().Condition == node;
			case KindConditionalExpression:
				return node.Parent.AsConditionalExpression().Condition == node;
			default:
		}
		return false;
	}

	static function isTopLevelLogicalExpression(node:Node):Bool {
		while (Ast.IsParenthesizedExpression(node.Parent)
			|| Ast.IsPrefixUnaryExpression(node.Parent) && node.Parent.AsPrefixUnaryExpression().Operator == KindExclamationToken) {
			node = node.Parent;
		}
		return !isStatementCondition(node) && !Ast.IsLogicalExpression(node.Parent) && !(Ast.IsOptionalChain(node.Parent) && node.Parent.Expression() == node);
	}

	static function isAssignmentDeclaration(decl:Node):Bool {
		return Ast.IsBinaryExpression(decl) || Ast.IsAccessExpression(decl) || Ast.IsIdentifier(decl) || Ast.IsCallExpression(decl);
	}

	static function isEffectiveModuleDeclaration(node:Node):Bool {
		return Ast.IsModuleDeclaration(node) || Ast.IsIdentifier(node);
	}

	// --- nameresolver.go ---

	public static function GetLocalSymbolForExportDefault(symbol:Symbol):Symbol {
		if (!isExportDefaultSymbol(symbol) || Core.len(symbol.Declarations) == 0) {
			return null;
		}
		for (decl in symbol.Declarations) {
			final localSymbol = decl.LocalSymbol();
			if (localSymbol != null) {
				return localSymbol;
			}
		}
		return null;
	}

	static function isExportDefaultSymbol(symbol:Symbol):Bool {
		return symbol != null && Core.len(symbol.Declarations) > 0 && Ast.HasSyntacticModifier(symbol.Declarations[0], ModifierFlagsDefault);
	}

	static function getIsDeferredContext(location:Node, lastLocation:Node):Bool {
		if (location.Kind != KindArrowFunction && location.Kind != KindFunctionExpression) {
			// initializers in instance property declaration of class like entities are executed in constructor and thus deferred
			// A name is evaluated within the enclosing scope - so it shouldn't count as deferred
			return Ast.IsTypeQueryNode(location)
				|| (Ast.IsFunctionLikeDeclaration(location) || location.Kind == KindPropertyDeclaration && !Ast.IsStatic(location))
				&& (lastLocation == null || lastLocation != location.Name());
		}
		if (lastLocation != null && lastLocation == location.Name()) {
			return false;
		}
		// generator functions and async functions are not inlined in control flow when immediately invoked
		if (location.BodyData().AsteriskToken != null || Ast.HasSyntacticModifier(location, ModifierFlagsAsync)) {
			return true;
		}
		return Ast.GetImmediatelyInvokedFunctionExpression(location) == null;
	}

	static function isTypeParameterSymbolDeclaredInContainer(symbol:Symbol, container:Node):Bool {
		if (symbol.Declarations != null) {
			for (decl in symbol.Declarations) {
				if (decl.Kind == KindTypeParameter) {
					final parent = decl.Parent;
					if (parent == container) {
						return true;
					}
				}
			}
		}
		return false;
	}

	static function isSelfReferenceLocation(node:Node, lastLocation:Node):Bool {
		switch (node.Kind) {
			case KindParameter:
				return lastLocation != null && lastLocation == node.Name();
			case KindFunctionDeclaration | KindClassDeclaration | KindInterfaceDeclaration | KindEnumDeclaration | KindTypeAliasDeclaration |
				KindJSTypeAliasDeclaration | KindModuleDeclaration: // For `namespace N { N; }`
				return true;
			default:
		}
		return false;
	}

	// --- referenceresolver.go ---

	public static function NewReferenceResolver(options:CompilerOptions, hooks:ReferenceResolverHooks):ReferenceResolver {
		final r = new ReferenceResolver_();
		r.options = options;
		r.hooks = hooks;
		return r;
	}
}
