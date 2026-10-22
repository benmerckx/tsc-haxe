package ts.parser;

import go.IdentityMap;
import haxe.ds.StringMap;

// Port of internal/parser (parser.go, jsdoc.go, reparser.go, references.go, utilities.go, types.go).
//
// Module layout (PORTING.md §1/§2):
//   Parser.hx    class Parser: the Go Parser struct and the methods of parser.go, plus all
//                package-level funcs/vars of the package (Go file order, `// --- file.go ---`).
//                The types of parser.go and types.go (ParsingContext, ParseFlags, ...).
//   Jsdoc.hx     methods of jsdoc.go (static extension `using ts.parser.Jsdoc`).
//   Reparser.hx  methods of reparser.go (static extension `using ts.parser.Reparser`).
//
// PORT: method values. Go passes method expressions `(*Parser).parseX` (no allocation) to
// parseList / parseDelimitedList / lookAhead / doInContext. Here each one is a static final
// function value `fn_<name>` created once (see the end of class Parser), so no function value is
// created per call (PORTING.md §7a). Non-capturing Go func literals passed to lookAhead are
// static finals too (`fl_*`); capturing ones stay local closures like in Go.
//
// PORT: arena — Go allocates node slices from p.nodeSliceArena / p.stringSliceArena; here
// `cloneNodes` / `cloneStrings` give Go's Arena.Clone result (nil for an empty slice, else a
// slice the caller owns). A freshly built list is handed over without a copy.
enum abstract ParsingContext(Int) from Int to Int {
	var PCSourceElements = 0; // Elements in source file
	var PCBlockStatements = 1; // Statements in block
	var PCSwitchClauses = 2; // Clauses in switch statement
	var PCSwitchClauseStatements = 3; // Statements in switch clause
	var PCTypeMembers = 4; // Members in interface or type literal
	var PCClassMembers = 5; // Members in class declaration
	var PCEnumMembers = 6; // Members in enum declaration
	var PCHeritageClauseElement = 7; // Elements in a heritage clause
	var PCVariableDeclarations = 8; // Variable declarations in variable statement
	var PCObjectBindingElements = 9; // Binding elements in object binding list
	var PCArrayBindingElements = 10; // Binding elements in array binding list
	var PCArgumentExpressions = 11; // Expressions in argument list
	var PCObjectLiteralMembers = 12; // Members in object literal
	var PCJsxAttributes = 13; // Attributes in jsx element
	var PCJsxChildren = 14; // Things between opening and closing JSX tags
	var PCArrayLiteralMembers = 15; // Members in array literal
	var PCParameters = 16; // Parameters in parameter list
	var PCJSDocParameters = 17; // JSDoc parameters in parameter list of JSDoc function type
	var PCRestProperties = 18; // Property names in a rest type list
	var PCTypeParameters = 19; // Type parameters in type parameter list
	var PCTypeArguments = 20; // Type arguments in type argument list
	var PCTupleElementTypes = 21; // Element types in tuple element type list
	var PCHeritageClauses = 22; // Heritage clauses for a class or interface declaration.
	var PCImportOrExportSpecifiers = 23; // Named import clause's import specifier list
	var PCImportAttributes = 24; // Import attributes
	var PCJSDocComment = 25; // Parsing via JSDocParser
	var PCCount = 26; // Number of parsing contexts
}

typedef ParsingContexts = Int;

class JSDocInfo {
	public var parent:Node = null;
	public var jsDocs:Array<Node> = null;

	public function new(parent:Node, jsDocs:Array<Node>) {
		this.parent = parent;
		this.jsDocs = jsDocs;
	}
}

enum abstract JsdocScannerInfo(Int) from Int to Int {
	@:op(A | B) static function or(a:JsdocScannerInfo, b:JsdocScannerInfo):JsdocScannerInfo;
	@:op(A & B) static function and(a:JsdocScannerInfo, b:JsdocScannerInfo):JsdocScannerInfo;
	@:op(~A) static function not(a:JsdocScannerInfo):JsdocScannerInfo;

	var jsdocScannerInfoHasJSDoc = 1 << 0;
	var jsdocScannerInfoHasDeprecated = 1 << 1;
	var jsdocScannerInfoHasSeeOrLink = 1 << 2;
}

	// --- types.go ---

	// ParseFlags
enum abstract ParseFlags(Int) from Int to Int {
	@:op(A | B) static function or(a:ParseFlags, b:ParseFlags):ParseFlags;
	@:op(A & B) static function and(a:ParseFlags, b:ParseFlags):ParseFlags;
	@:op(~A) static function not(a:ParseFlags):ParseFlags;

	var ParseFlagsNone = 0;
	var ParseFlagsYield = 1 << 0;
	var ParseFlagsAwait = 1 << 1;
	var ParseFlagsType = 1 << 2;
	var ParseFlagsIgnoreMissingOpenBrace = 1 << 4;
	var ParseFlagsJSDoc = 1 << 5;
}

	// PORT: Go value struct (mark() creates one, rewind() reads it; reparseTopLevelAwait mutates its
	// own copy only).
class ParserState {
	public var scannerState:ScannerState = null;
	public var contextFlags:NodeFlags = NodeFlagsNone;
	public var diagnosticsLen:Int = 0;
	public var jsDiagnosticsLen:Int = 0;
	public var jsdocInfosLen:Int = 0;
	public var reparsedClonesLen:Int = 0;
	public var statementHasAwaitIdentifier:Bool = false;
	public var hasParseError:Bool = false;

	public function new() {}
}

@:allow(ts.parser)
class Parser {
	// --- parser.go ---

	var scanner:Scanner = null;
	var factory:NodeFactory = new NodeFactory();

	var opts:SourceFileParseOptions = new SourceFileParseOptions();
	// PORT: perf — Go's p.sourceText may be a slice (parseJSDocComment's p.sourceText[:end-2]): the
	// longer string and the length (setSourceTextPrefix); the prefix is made only when read.
	var sourceText(get, set):String;
	var sourceTextFull:String = "";
	var sourceTextLen:Int = 0;
	var sourceTextPrefix:String = null;

	function get_sourceText():String {
		if (sourceTextLen == sourceTextFull.length)
			return sourceTextFull;
		if (sourceTextPrefix == null)
			sourceTextPrefix = go.Strings.Prefix(sourceTextFull, sourceTextLen);
		return sourceTextPrefix;
	}

	function set_sourceText(v:String):String {
		sourceTextFull = v;
		sourceTextLen = v.length;
		sourceTextPrefix = null;
		return v;
	}

	// p.sourceText = text[:n]
	function setSourceTextPrefix(text:String, n:Int):Void {
		sourceTextFull = text;
		sourceTextLen = n;
		sourceTextPrefix = null;
	}

	var scriptKind:ScriptKind = ScriptKindUnknown;
	var languageVariant:LanguageVariant = LanguageVariantStandard;
	var diagnostics:Array<Diagnostic> = null;
	var jsDiagnostics:Array<Diagnostic> = null;
	var jsdocDiagnostics:Array<Diagnostic> = null;

	var token:Kind = KindUnknown;
	var sourceFlags:NodeFlags = NodeFlagsNone;
	var contextFlags:NodeFlags = NodeFlagsNone;
	var parsingContexts:ParsingContexts = 0;
	var statementHasAwaitIdentifier:Bool = false;
	var hasDeprecatedTag:Bool = false;
	var hasParseError:Bool = false;

	var identifiers:StringMap<String> = null;
	var identifierCount:Int = 0;
	var notParenthesizedArrow:Set<Int> = new Set<Int>();
	// PORT: arena — nodeSliceArena / stringSliceArena: see cloneNodes / cloneStrings.
	var jsdocInfos:Array<JSDocInfo> = null;
	var possibleAwaitSpans:Array<Int> = null;
	var jsdocCommentsSpace:Array<String> = null;
	var jsdocCommentRangesSpace:Array<CommentRange> = null;
	var jsdocTagCommentsSpace:Array<String> = null;
	var jsdocTagCommentsPartsSpace:Array<Node> = null;
	var reparseList:Array<Node> = null;
	var commonJSModuleIndicator:Node = null;

	var currentParent:Node = null;
	var setParentFromContext:Visitor = null;
	var reparsedClones:Array<Node> = null;

	function new() {}

	static function newParser():Parser {
		final res = new Parser();
		res.initializeClosures();
		return res;
	}

	// PORT: static init order (PORTING.md §7a) — lazy getter.
	static var viableKeywordSuggestions(get, never):Array<String>;
	static var viableKeywordSuggestionsValue:Array<String> = null;

	static function get_viableKeywordSuggestions():Array<String> {
		if (viableKeywordSuggestionsValue == null) {
			viableKeywordSuggestionsValue = Scanner.GetViableKeywordSuggestions();
		}
		return viableKeywordSuggestionsValue;
	}

	// missingListNodes is a sentinel backing array used to distinguish "missing" node lists
	// (where the expected opening token was not found) from ordinary empty node lists.
	// PORT: Go compares the backing array; here the array identity. Nothing appends to it.
	static final missingListNodes:Array<Node> = [];

	static function isMissingNodeList(list:NodeList):Bool {
		return list != null && list.Nodes == missingListNodes;
	}

	// PORT: sync.Pool → a plain free list (single-threaded).
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — a free list per thread (go.Par.slot): the checkers parse JSDoc lazily
	static final parserPools:Array<Array<Parser>> = [for (_ in 0...go.Par.SLOTS) []];
	static var parserPool(get, never):Array<Parser>;

	static inline function get_parserPool()
		return parserPools[go.Par.slot];
	#else
	static final parserPool:Array<Parser> = [];
	#end

	static function getParser():Parser {
		if (parserPool.length > 0) {
			return parserPool.pop();
		}
		return newParser();
	}

	static function putParser(p:Parser):Void {
		// *p = Parser{scanner: p.scanner, setParentFromContext: p.setParentFromContext}
		p.reset();
		parserPool.push(p);
	}

	// PORT: Go `*p = Parser{scanner: p.scanner, setParentFromContext: p.setParentFromContext}`:
	// every other field gets its zero value.
	function reset():Void {
		factory = new NodeFactory();
		opts = new SourceFileParseOptions();
		sourceText = "";
		scriptKind = ScriptKindUnknown;
		languageVariant = LanguageVariantStandard;
		diagnostics = null;
		jsDiagnostics = null;
		jsdocDiagnostics = null;
		token = KindUnknown;
		sourceFlags = NodeFlagsNone;
		contextFlags = NodeFlagsNone;
		parsingContexts = 0;
		statementHasAwaitIdentifier = false;
		hasDeprecatedTag = false;
		hasParseError = false;
		identifiers = null;
		identifierCount = 0;
		notParenthesizedArrow = new Set<Int>();
		jsdocInfos = null;
		possibleAwaitSpans = null;
		jsdocCommentsSpace = null;
		jsdocCommentRangesSpace = null;
		jsdocTagCommentsSpace = null;
		jsdocTagCommentsPartsSpace = null;
		reparseList = null;
		commonJSModuleIndicator = null;
		currentParent = null;
		reparsedClones = null;
		// PORT: port-only fields (out results and the parseList element function).
		listElement = null;
		specifierIsTypeOnly = false;
		specifierPropertyName = null;
		moduleExportNameOk = false;
		bracketNameIsBracketed = false;
	}

	public static function ParseSourceFile(opts:SourceFileParseOptions, sourceText:String, scriptKind:ScriptKind):SourceFile {
		init(); // PORT: Go package init (see init)
		final p = getParser();
		// PORT: defer putParser(p)
		final r = try {
			p.initializeState(opts, sourceText, scriptKind);
			p.nextToken();
			if (p.scriptKind == ScriptKindJSON) {
				p.parseJSONText();
			} else {
				p.parseSourceFileWorker();
			}
		} catch (e:Dynamic) {
			putParser(p);
			throw e;
		}
		putParser(p);
		return r;
	}

	function initializeClosures():Void {
		setParentFromContext = function(n:Node):Bool {
			n.Parent = currentParent;
			return false;
		};
	}

	// PORT: Go slice helpers (PORTING.md §3). The parser owns all slices it appends to.

	// Go `append(s, v)` on a slice the caller owns (nil → new slice).
	static inline function append<T>(s:Null<Array<T>>, v:T):Array<T> {
		if (s == null) {
			return [v];
		}
		s.push(v);
		return s;
	}

	// Go `append(s, other...)` on a slice the caller owns.
	static function appendAll<T>(s:Null<Array<T>>, other:Null<Array<T>>):Null<Array<T>> {
		if (other == null || other.length == 0) {
			return s;
		}
		if (s == null) {
			return other.copy();
		}
		for (v in other) {
			s.push(v);
		}
		return s;
	}

	// Go `s = s[0:n]` (n <= len(s)); a nil slice stays nil.
	static inline function truncate<T>(s:Null<Array<T>>, n:Int):Null<Array<T>> {
		if (s != null) {
			s.resize(n);
		}
		return s;
	}

	// Go builtin min(a, b) for ints.
	static inline function minInt(a:Int, b:Int):Int {
		return a < b ? a : b;
	}

	// Go `for _, x := range s` over a possibly-nil slice of nodes.
	static final emptyNodes:Array<Node> = [];

	static inline function nodesOf(s:Null<Array<Node>>):Array<Node> {
		return s != null ? s : emptyNodes;
	}

	// PORT: arena — Go `p.nodeSliceArena.Clone(list)` where `list` is a fresh slice that is not
	// used afterwards: nil when empty, else the slice itself (no copy needed).
	static inline function cloneNodes(list:Null<Array<Node>>):Array<Node> {
		return list == null || list.length == 0 ? null : list;
	}

	// PORT: arena — Go `p.stringSliceArena.Clone(s)` (s is reused by the caller): a copy, nil when empty.
	static inline function cloneStrings(s:Null<Array<String>>):Array<String> {
		return s == null || s.length == 0 ? null : s.copy();
	}

	function isJavaScript():Bool {
		return scriptKind == ScriptKindJS || scriptKind == ScriptKindJSX;
	}

	function parseJSONText():SourceFile {
		var pos = nodePos();
		var statements:NodeList = null;
		var eof:TokenNode = null;

		if (token == KindEndOfFile) {
			statements = newNodeList(Core.NewTextRange(pos, nodePos()), null);
			eof = parseTokenNode();
		} else {
			// PORT: Go `var expressions any // []*ast.Expression | *ast.Expression` → two locals.
			var expressionsList:Array<Expression> = null;
			var expressionsSingle:Expression = null;

			while (token != KindEndOfFile) {
				var expression:Expression = null;
				switch (token) {
					case KindOpenBracketToken:
						expression = parseArrayLiteralExpression();
					case KindTrueKeyword | KindFalseKeyword | KindNullKeyword:
						expression = parseTokenNode();
					case KindMinusToken:
						if (lookAhead(fl_jsonMinusNumber)) {
							expression = parsePrefixUnaryExpression();
						} else {
							expression = parseObjectLiteralExpression();
						}
					case KindNumericLiteral | KindStringLiteral:
						// PORT: `break` out of the case, else `fallthrough` into default.
						if (lookAhead(fl_jsonNextIsNotColon)) {
							expression = parseLiteralExpression(false /*intern*/);
						} else {
							expression = parseObjectLiteralExpression();
						}
					default:
						expression = parseObjectLiteralExpression();
				}

				// Error recovery: collect multiple top-level expressions
				if (expressionsList != null || expressionsSingle != null) {
					if (expressionsList != null) {
						expressionsList.push(expression);
					} else {
						expressionsList = [expressionsSingle, expression];
						expressionsSingle = null;
					}
				} else {
					expressionsSingle = expression;
					if (token != KindEndOfFile) {
						parseErrorAtCurrentToken(Diagnostics.Unexpected_token);
					}
				}
			}

			var expression:Expression = null;
			if (expressionsList != null) {
				expression = finishNode(factory.NewArrayLiteralExpression(newNodeList(Core.NewTextRange(pos, nodePos()), expressionsList), false), pos);
			} else {
				expression = expressionsSingle;
			}
			var statement = finishNode(factory.NewExpressionStatement(expression), pos);
			statements = newNodeList(Core.NewTextRange(pos, nodePos()), [statement]);
			eof = parseExpectedToken(KindEndOfFile);
		}
		var node = finishNode(factory.NewSourceFile(opts, sourceText, statements, eof), pos);
		var result = node.AsSourceFile();
		if (Core.len(result.Statements.Nodes) > 0) {
			validateJsonValue(result, result.Statements.Nodes[0].Expression());
		}
		finishSourceFile(result, false);
		return result;
	}

	static final fl_jsonMinusNumber:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextToken() == KindNumericLiteral && p.nextToken() != KindColonToken;
	};

	static final fl_jsonNextIsNotColon:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextToken() != KindColonToken;
	};

	static function getErrorSpanForNode(sourceText:String, node:Node):TextRange {
		var pos = Scanner.SkipTrivia(sourceText, node.Pos());
		return Core.NewTextRange(pos, node.End());
	}

	function validateJsonValue(sourceFile:SourceFile, valueExpression:Expression):Void {
		if (valueExpression == null) {
			return;
		}
		switch (valueExpression.Kind) {
		case KindTrueKeyword | KindFalseKeyword | KindNullKeyword | KindNumericLiteral:
			return;
		case KindStringLiteral:
			if (!isDoubleQuotedString(valueExpression)) {
				diagnostics = append(diagnostics, Ast.NewDiagnostic(sourceFile, getErrorSpanForNode(sourceText, valueExpression), Diagnostics.String_literal_with_double_quotes_expected));
			}
			return;
		case KindPrefixUnaryExpression:
			// PORT: Go `break` (not valid JSON syntax) → fall to the diagnostic below.
			if (!(valueExpression.AsPrefixUnaryExpression().Operator != KindMinusToken || valueExpression.AsPrefixUnaryExpression().Operand.Kind != KindNumericLiteral)) {
				return;
			}
		case KindObjectLiteralExpression:
			validateJsonObjectLiteral(sourceFile, valueExpression.AsObjectLiteralExpression());
			return;
		case KindArrayLiteralExpression:
			for (element in nodesOf(valueExpression.Elements())) {
				validateJsonValue(sourceFile, element);
			}
			return;
		default:
		}
		diagnostics = append(diagnostics, Ast.NewDiagnostic(sourceFile, getErrorSpanForNode(sourceText, valueExpression), Diagnostics.Property_value_can_only_be_string_literal_numeric_literal_true_false_null_object_literal_or_array_literal));
	}

	static function isDoubleQuotedString(node:Node):Bool {
		return Ast.IsStringLiteral(node) && node.AsStringLiteral().TokenFlags&TokenFlagsSingleQuote == 0;
	}

	// validateJsonObjectLiteral validates properties of a JSON object literal.
	function validateJsonObjectLiteral(sourceFile:SourceFile, node:ObjectLiteralExpression):Void {
		for (element in nodesOf(node.Properties.Nodes)) {
			if (element.Kind != KindPropertyAssignment) {
				diagnostics = append(diagnostics, Ast.NewDiagnostic(sourceFile, getErrorSpanForNode(sourceText, element), Diagnostics.Property_assignment_expected));
				continue;
			}
			if (element.Name() != null && !isDoubleQuotedString(element.Name())) {
				diagnostics = append(diagnostics, Ast.NewDiagnostic(sourceFile, getErrorSpanForNode(sourceText, element.Name()), Diagnostics.String_literal_with_double_quotes_expected));
			}
			validateJsonValue(sourceFile, element.AsPropertyAssignment().Initializer);
		}
	}

	public static function ParseIsolatedEntityName(text:String):EntityName {
		init(); // PORT: Go package init (see init)
		final p = getParser();
		// PORT: defer putParser(p)
		final r = try {
			p.initializeState(new SourceFileParseOptions(), text, ScriptKindJS);
			p.nextToken();
			var entityName = p.parseEntityName(true, null);
			(p.token == KindEndOfFile && Core.len(p.diagnostics) == 0 ? entityName : null);
		} catch (e:Dynamic) {
			putParser(p);
			throw e;
		}
		putParser(p);
		return r;
	}

	function initializeState(opts:SourceFileParseOptions, sourceText:String, scriptKind:ScriptKind):Void {
		if (scriptKind == ScriptKindUnknown) {
			throw "ScriptKind must be specified when parsing source file: " + opts.FileName;
		}

		if (scanner == null) {
			scanner = Scanner.NewScanner();
		} else {
			scanner.Reset();
		}
		this.opts = opts;
		this.sourceText = sourceText;
		this.scriptKind = scriptKind;
		languageVariant = getLanguageVariant(this.scriptKind);
		switch (this.scriptKind) {
		case ScriptKindJS | ScriptKindJSX:
			contextFlags = NodeFlagsJavaScriptFile;
		case ScriptKindJSON:
			contextFlags = NodeFlagsJavaScriptFile | NodeFlagsJsonFile;
		default:
			contextFlags = NodeFlagsNone;
		}
		scanner.SetText(this.sourceText);
		scanner.SetOnError(scanError);
		scanner.SetLanguageVariant(languageVariant);
	}

	function scanError(message:Message, pos:Int, length:Int, ...args:Any):Void {
		parseErrorAtRange(Core.NewTextRange(pos, pos+length), message, ...args);
	}

	function parseErrorAt(pos:Int, end:Int, message:Message, ...args:Any):Diagnostic {
		return parseErrorAtRange(Core.NewTextRange(pos, end), message, ...args);
	}

	function parseErrorAtCurrentToken(message:Message, ...args:Any):Diagnostic {
		return parseErrorAtRange(scanner.TokenRange(), message, ...args);
	}

	function parseErrorAtRange(loc:TextRange, message:Message, ...args:Any):Diagnostic {
		// Don't report another error if it would just be at the same location as the last error
		var result:Diagnostic = null;
		if (Core.len(diagnostics) == 0 || diagnostics[Core.len(diagnostics)-1].Pos() != loc.Pos()) {
			result = Ast.NewDiagnostic(null, loc, message, ...args);
			diagnostics = append(diagnostics, result);
		}
		hasParseError = true;
		return result;
	}

	function mark():ParserState {
		final state = new ParserState();
		state.scannerState = scanner.Mark();
		state.contextFlags = contextFlags;
		state.diagnosticsLen = Core.len(diagnostics);
		state.jsDiagnosticsLen = Core.len(jsDiagnostics);
		state.jsdocInfosLen = Core.len(jsdocInfos);
		state.reparsedClonesLen = Core.len(reparsedClones);
		state.statementHasAwaitIdentifier = statementHasAwaitIdentifier;
		state.hasParseError = hasParseError;
		return state;
	}

	function rewind(state:ParserState):Void {
		scanner.Rewind(state.scannerState);
		token = scanner.Token();
		contextFlags = state.contextFlags;
		diagnostics = truncate(diagnostics, state.diagnosticsLen);
		jsDiagnostics = truncate(jsDiagnostics, state.jsDiagnosticsLen);
		jsdocInfos = truncate(jsdocInfos, state.jsdocInfosLen);
		reparsedClones = truncate(reparsedClones, state.reparsedClonesLen);
		statementHasAwaitIdentifier = state.statementHasAwaitIdentifier;
		hasParseError = state.hasParseError;
	}

	function lookAhead(callback:(p:Parser) -> Bool):Bool {
		var state = mark();
		var result = callback(this);
		rewind(state);
		return result;
	}

	function nextToken():Kind {
		// if the keyword had an escape
		if (Ast.IsKeyword(token) && (scanner.HasUnicodeEscape() || scanner.HasExtendedUnicodeEscape())) {
			// issue a parse error for the escape
			parseErrorAtCurrentToken(Diagnostics.Keywords_cannot_contain_escape_characters);
		}
		token = scanner.Scan();
		return token;
	}

	function nextTokenWithoutCheck():Kind {
		token = scanner.Scan();
		return token;
	}

	function nextTokenJSDoc():Kind {
		token = scanner.ScanJSDocToken();
		return token;
	}

	function nextJSDocCommentTextToken(inBackticks:Bool):Kind {
		token = scanner.ScanJSDocCommentTextToken(inBackticks);
		return token;
	}

	function nodePos():Int {
		return scanner.TokenFullStart();
	}

	function hasPrecedingLineBreak():Bool {
		return scanner.HasPrecedingLineBreak();
	}

	function jsdocScannerInfo():JsdocScannerInfo {
		if (!scanner.HasPrecedingJSDocComment()) {
			return 0;
		}
		var info = jsdocScannerInfoHasJSDoc;
		if (scanner.HasPrecedingJSDocWithDeprecatedTag()) {
			info |= jsdocScannerInfoHasDeprecated;
		}
		if (scanner.HasPrecedingJSDocWithSeeOrLink()) {
			info |= jsdocScannerInfoHasSeeOrLink;
		}
		return info;
	}

	function parseSourceFileWorker():SourceFile {
		var isDeclarationFile = Tspath.IsDeclarationFileName(opts.FileName);
		if (isDeclarationFile) {
			contextFlags |= NodeFlagsAmbient;
		}
		var pos = nodePos();
		var statements = parseListIndex(PCSourceElements, fn_parseToplevelStatement);
		var end = nodePos();
		var endJSDoc = jsdocScannerInfo();
		var eof = parseTokenNode();
		this.withJSDoc(eof, endJSDoc);
		if (eof.Kind != KindEndOfFile) {
			throw "Expected end of file token from scanner.";
		}
		if (Core.len(reparseList) != 0) {
			statements = appendAll(statements, reparseList);
			reparseList = null;
		}
		var node = finishNode(factory.NewSourceFile(opts, sourceText, newNodeList(Core.NewTextRange(pos, end), statements), eof), pos);
		var result = node.AsSourceFile();
		finishSourceFile(result, isDeclarationFile);
		if (!result.IsDeclarationFile && result.ExternalModuleIndicator != null && Core.len(possibleAwaitSpans) > 0) {
			var reparse = finishNode(reparseTopLevelAwait(result), pos);
			if (node != reparse) {
				result = reparse.AsSourceFile();
				finishSourceFile(result, isDeclarationFile);
			}
		}
		collectExternalModuleReferences(result);
		if (Ast.IsInJSFile(node)) {
			result.SetJSDiagnostics(attachFileToDiagnostics(jsDiagnostics, result));
		}
		return result;
	}

	function finishSourceFile(result:SourceFile, isDeclarationFile:Bool):Void {
		result.CommentDirectives = scanner.CommentDirectives();
		result.Pragmas = getCommentPragmas(factory, sourceText);
		processPragmasIntoFields(result);
		result.SetDiagnostics(attachFileToDiagnostics(diagnostics, result));
		result.SetJSDocDiagnostics(attachFileToDiagnostics(jsdocDiagnostics, result));
		result.CommonJSModuleIndicator = commonJSModuleIndicator;
		result.IsDeclarationFile = isDeclarationFile;
		result.LanguageVariant = languageVariant;
		result.ScriptKind = scriptKind;
		result.Flags |= sourceFlags;
		result.Identifiers = identifiers;
		result.NodeCount = factory.NodeCount();
		result.TextCount = factory.TextCount();
		result.IdentifierCount = identifierCount;
		result.SetJSDocCache(createJSDocCache());
		// For non-JS files, enable lazy JSDoc parsing on demand
		if (!isJavaScript()) {
			result.SetHasLazyJSDoc(true);
		}
		if (reparsedClones != null) {
			go.Slices.SortFunc(reparsedClones, Ast.CompareNodePositions);
		}
		result.ReparsedClones = reparsedClones == null ? null : reparsedClones.copy();
		Ast.SetExternalModuleIndicator(result, opts.ExternalModuleIndicatorOptions);
	}

	function createJSDocCache():IdentityMap<Node, Array<Node>> {
		if (Core.len(jsdocInfos) == 0) {
			return null;
		}
		var result = new IdentityMap<Node, Array<Node>>();
		for (info in jsdocInfos) {
			result.set(info.parent, info.jsDocs);
		}
		return result;
	}

	function parseToplevelStatement(i:Int):Node {
		statementHasAwaitIdentifier = false;
		var statement = parseStatement();
		// Reparsed nodes (e.g. JSDoc @typedef) produced while parsing this statement are inserted
		// into the statement list before this statement, so account for them when recording the
		// statement's index for possibleAwaitSpans.
		i += Core.len(reparseList);
		if (statementHasAwaitIdentifier && statement.Flags&NodeFlagsAwaitContext == 0) {
			if (Core.len(possibleAwaitSpans) == 0 || possibleAwaitSpans[Core.len(possibleAwaitSpans)-1] != i) {
				possibleAwaitSpans = append(append(possibleAwaitSpans, i), i+1);
			} else {
				possibleAwaitSpans[Core.len(possibleAwaitSpans)-1] = i + 1;
			}
		}
		return statement;
	}

	function reparseTopLevelAwait(sourceFile:SourceFile):Node {
		if (Core.len(possibleAwaitSpans) % 2 == 1) {
			throw "possibleAwaitSpans malformed: odd number of indices, not paired into spans.";
		}
		var statements:Array<Statement> = [];
		var savedParseDiagnostics = diagnostics;
		diagnostics = [];

		var afterAwaitStatement = 0;
		var i = 0;
		// PORT: Go `for i := 0; i < len(p.possibleAwaitSpans); i += 2` (the body has no `continue`).
		while (i < Core.len(possibleAwaitSpans)) {
			var nextAwaitStatement = possibleAwaitSpans[i];
			// append all non-await statements between afterAwaitStatement and nextAwaitStatement
			var prevStatement = sourceFile.Statements.Nodes[afterAwaitStatement];
			var nextStatement = sourceFile.Statements.Nodes[nextAwaitStatement];
			statements = appendAll(statements, sourceFile.Statements.Nodes.slice(afterAwaitStatement, nextAwaitStatement));

			// append all diagnostics associated with the copied range
			var diagnosticStart = Core.FindIndex(savedParseDiagnostics, function(diagnostic:Diagnostic):Bool {
				return diagnostic.Pos() >= prevStatement.Pos();
			});
			var diagnosticEnd:Int = 0;
			if (diagnosticStart >= 0) {
				diagnosticEnd = Core.FindIndex(savedParseDiagnostics.slice(diagnosticStart), function(diagnostic:Diagnostic):Bool {
					return diagnostic.Pos() >= nextStatement.Pos();
				});
			} else {
				diagnosticEnd = -1;
			}
			if (diagnosticStart >= 0) {
				var slice:Array<Diagnostic> = null;
				if (diagnosticEnd >= 0) {
					slice = savedParseDiagnostics.slice(diagnosticStart, diagnosticStart + diagnosticEnd);
				} else {
					slice = savedParseDiagnostics.slice(diagnosticStart);
				}
				diagnostics = appendAll(diagnostics, slice);
			}

			var state = mark();
			// reparse all statements between start and pos. We skip existing diagnostics for the same range and allow the parser to generate new ones.
			contextFlags |= NodeFlagsAwaitContext;
			scanner.ResetPos(nextStatement.Pos());
			nextToken();

			afterAwaitStatement = possibleAwaitSpans[i+1];
			while (token != KindEndOfFile) {
				var startPos = scanner.TokenFullStart();
				var statement = parseStatement();
				statements = append(statements, statement);
				if (startPos == scanner.TokenFullStart()) {
					nextToken();
				}
				if (afterAwaitStatement < Core.len(sourceFile.Statements.Nodes)) {
					var lastAwaitStatement = sourceFile.Statements.Nodes[afterAwaitStatement-1];
					if (statement.End() == lastAwaitStatement.End()) {
						// done reparsing this section
						break;
					}
					if (statement.End() > lastAwaitStatement.End()) {
						// we ate into the next statement, so we must continue reparsing the next span
						i += 2;
						if (i < Core.len(possibleAwaitSpans)) {
							afterAwaitStatement = possibleAwaitSpans[i+1];
						} else {
							afterAwaitStatement = Core.len(sourceFile.Statements.Nodes);
						}
					}
				}
			}

			// Keep diagnostics from the reparse
			state.diagnosticsLen = Core.len(diagnostics);
			rewind(state);
			i += 2;
		}

		// append all statements between pos and the end of the list
		if (afterAwaitStatement < Core.len(sourceFile.Statements.Nodes)) {
			var prevStatement = sourceFile.Statements.Nodes[afterAwaitStatement];
			statements = appendAll(statements, sourceFile.Statements.Nodes.slice(afterAwaitStatement));

			// append all diagnostics associated with the copied range
			var diagnosticStart = Core.FindIndex(savedParseDiagnostics, function(diagnostic:Diagnostic):Bool {
				return diagnostic.Pos() >= prevStatement.Pos();
			});
			if (diagnosticStart >= 0) {
				diagnostics = appendAll(diagnostics, savedParseDiagnostics.slice(diagnosticStart));
			}
		}

		var result = factory.NewSourceFile(sourceFile.ParseOptions(), sourceText, newNodeList(sourceFile.Statements.Loc, statements), sourceFile.EndOfFileToken);
		for (s in statements) {
			s.Parent = result.AsNode(); // force (re)set parent to reparsed source file
		}
		return result;
	}

	function parseListIndex(kind:ParsingContext, parseElement:(p:Parser, index:Int) -> Node):Array<Node> {
		var saveParsingContexts = parsingContexts;
		parsingContexts |= 1 << kind;
		var outerReparseList = reparseList;
		reparseList = null;
		var list:Array<Node> = null; // PORT: arena — Go uses a stack temp + arena Clone; allocated on first append
		// PORT: Go `for i := 0; !p.isListTerminator(kind); i++` (i is unused).
		while (!isListTerminator(kind)) {
			if (isListElement(kind, false /*inErrorRecovery*/)) {
				var elt = parseElement(this, Core.len(list));
				if (Core.len(reparseList) != 0) {
					for (e in reparseList) {
						// Propagate @typedef type alias declarations outwards to a context that permits them.
						if ((Ast.IsJSTypeAliasDeclaration(e) || Ast.IsJSImportDeclaration(e)) && kind != PCSourceElements && kind != PCBlockStatements) {
							outerReparseList = append(outerReparseList, e);
						} else {
							list = append(list, e);
						}
					}
					reparseList = null;
				}
				list = append(list, elt);
				continue;
			}
			if (abortParsingListOrMoveToNextToken(kind)) {
				break;
			}
		}
		reparseList = outerReparseList;
		parsingContexts = saveParsingContexts;
		return cloneNodes(list);
	}

	function parseList(kind:ParsingContext, parseElement:(p:Parser) -> Node):NodeList {
		var pos = nodePos();
		// PORT: Go wraps parseElement in a closure (stack-allocated in Go). Here the element
		// function goes through the field listElement (saved/restored around nested lists) and the
		// wrapper fl_parseListElement is created once.
		final saveListElement = listElement;
		listElement = parseElement;
		var nodes = parseListIndex(kind, fl_parseListElement);
		listElement = saveListElement;
		return newNodeList(Core.NewTextRange(pos, nodePos()), nodes);
	}

	var listElement:(p:Parser) -> Node = null;

	static final fl_parseListElement:(p:Parser, index:Int) -> Node = function(p:Parser, _:Int):Node {
		return p.listElement(p);
	};

	// Return a non-nil (but possibly empty) slice if parsing was successful, or nil if parseElement returned nil
	function parseDelimitedList(kind:ParsingContext, parseElement:(p:Parser) -> Node):NodeList {
		var pos = nodePos();
		var saveParsingContexts = parsingContexts;
		parsingContexts |= 1 << kind;
		var list:Array<Node> = null; // PORT: arena — Go uses a stack temp + arena Clone; allocated on first append
		while (true) {
			if (isListElement(kind, false /*inErrorRecovery*/)) {
				var startPos = nodePos();
				var element = parseElement(this);
				if (element == null) {
					parsingContexts = saveParsingContexts;
					// Return nil to indicate parseElement failed
					return null;
				}
				list = append(list, element);
				if (parseOptional(KindCommaToken)) {
					// No need to check for a zero length node since we know we parsed a comma
					continue;
				}
				if (isListTerminator(kind)) {
					break;
				}
				// We didn't get a comma, and the list wasn't terminated, explicitly parse
				// out a comma so we give a good error message.
				if (token != KindCommaToken && kind == PCEnumMembers) {
					parseErrorAtCurrentToken(Diagnostics.An_enum_member_name_must_be_followed_by_a_or);
				} else {
					parseExpected(KindCommaToken);
				}
				// If the token was a semicolon, and the caller allows that, then skip it and
				// continue.  This ensures we get back on track and don't result in tons of
				// parse errors.  For example, this can happen when people do things like use
				// a semicolon to delimit object literal members.   Note: we'll have already
				// reported an error when we called parseExpected above.
				if ((kind == PCObjectLiteralMembers || kind == PCImportAttributes) && token == KindSemicolonToken && !hasPrecedingLineBreak()) {
					nextToken();
				}
				if (startPos == nodePos()) {
					// What we're parsing isn't actually remotely recognizable as a element and we've consumed no tokens whatsoever
					// Consume a token to advance the parser in some way and avoid an infinite loop
					// This can happen when we're speculatively parsing parenthesized expressions which we think may be arrow functions,
					// or when a modifier keyword which is disallowed as a parameter name (ie, `static` in strict mode) is supplied
					nextToken();
				}
				continue;
			}
			if (isListTerminator(kind)) {
				break;
			}
			if (abortParsingListOrMoveToNextToken(kind)) {
				break;
			}
		}
		parsingContexts = saveParsingContexts;
		return newNodeList(Core.NewTextRange(pos, nodePos()), cloneNodes(list));
	}

	// Return a non-nil (but possibly empty) NodeList if parsing was successful, a missing NodeList if the opening
	// token wasn't found, or nil if parseElement returned nil.
	function parseBracketedList(kind:ParsingContext, parseElement:(p:Parser) -> Node, opening:Kind, closing:Kind):NodeList {
		if (parseExpected(opening)) {
			var result = parseDelimitedList(kind, parseElement);
			parseExpected(closing);
			return result;
		}
		return createMissingList();
	}

	function parseEmptyNodeList():NodeList {
		return newNodeList(Core.NewTextRange(nodePos(), nodePos()), null);
	}

	function createMissingList():NodeList {
		var result = parseEmptyNodeList();
		result.Nodes = missingListNodes;
		return result;
	}

	// Returns true if we should abort parsing.
	function abortParsingListOrMoveToNextToken(kind:ParsingContext):Bool {
		parsingContextErrors(kind);
		if (isInSomeParsingContext()) {
			return true;
		}
		nextToken();
		return false;
	}

	// True if positioned at element or terminator of the current list or any enclosing list
	function isInSomeParsingContext():Bool {
		// We should be in at least one parsing context, be it SourceElements while parsing
		// a SourceFile, or JSDocComment when lazily parsing JSDoc.
		Debug.Assert(parsingContexts != 0, "Missing parsing context");
		for (kind in 0...PCCount) {
			if (parsingContexts & (1 << kind) != 0) {
				if (isListElement(kind, true /*inErrorRecovery*/) || isListTerminator(kind)) {
					return true;
				}
			}
		}
		return false;
	}

	function parsingContextErrors(context:ParsingContext):Void {
		switch (context) {
		case PCSourceElements:
			if (token == KindDefaultKeyword) {
				parseErrorAtCurrentToken(Diagnostics.X_0_expected, "export");
			} else {
				parseErrorAtCurrentToken(Diagnostics.Declaration_or_statement_expected);
			}
		case PCBlockStatements:
			parseErrorAtCurrentToken(Diagnostics.Declaration_or_statement_expected);
		case PCSwitchClauses:
			parseErrorAtCurrentToken(Diagnostics.X_case_or_default_expected);
		case PCSwitchClauseStatements:
			parseErrorAtCurrentToken(Diagnostics.Statement_expected);
		case PCRestProperties | PCTypeMembers:
			parseErrorAtCurrentToken(Diagnostics.Property_or_signature_expected);
		case PCClassMembers:
			parseErrorAtCurrentToken(Diagnostics.Unexpected_token_A_constructor_method_accessor_or_property_was_expected);
		case PCEnumMembers:
			parseErrorAtCurrentToken(Diagnostics.Enum_member_expected);
		case PCHeritageClauseElement:
			parseErrorAtCurrentToken(Diagnostics.Expression_expected);
		case PCVariableDeclarations:
			if (Ast.IsKeyword(token)) {
				parseErrorAtCurrentToken(Diagnostics.X_0_is_not_allowed_as_a_variable_declaration_name, Scanner.TokenToString(token));
			} else {
				parseErrorAtCurrentToken(Diagnostics.Variable_declaration_expected);
			}
		case PCObjectBindingElements:
			parseErrorAtCurrentToken(Diagnostics.Property_destructuring_pattern_expected);
		case PCArrayBindingElements:
			parseErrorAtCurrentToken(Diagnostics.Array_element_destructuring_pattern_expected);
		case PCArgumentExpressions:
			parseErrorAtCurrentToken(Diagnostics.Argument_expression_expected);
		case PCObjectLiteralMembers:
			parseErrorAtCurrentToken(Diagnostics.Property_assignment_expected);
		case PCArrayLiteralMembers:
			parseErrorAtCurrentToken(Diagnostics.Expression_or_comma_expected);
		case PCJSDocParameters:
			parseErrorAtCurrentToken(Diagnostics.Parameter_declaration_expected);
		case PCParameters:
			if (Ast.IsKeyword(token)) {
				parseErrorAtCurrentToken(Diagnostics.X_0_is_not_allowed_as_a_parameter_name, Scanner.TokenToString(token));
			} else {
				parseErrorAtCurrentToken(Diagnostics.Parameter_declaration_expected);
			}
		case PCTypeParameters:
			parseErrorAtCurrentToken(Diagnostics.Type_parameter_declaration_expected);
		case PCTypeArguments:
			parseErrorAtCurrentToken(Diagnostics.Type_argument_expected);
		case PCTupleElementTypes:
			parseErrorAtCurrentToken(Diagnostics.Type_expected);
		case PCHeritageClauses:
			parseErrorAtCurrentToken(Diagnostics.Unexpected_token_expected);
		case PCImportOrExportSpecifiers:
			if (token == KindFromKeyword) {
				parseErrorAtCurrentToken(Diagnostics.X_0_expected, "}");
			} else {
				parseErrorAtCurrentToken(Diagnostics.Identifier_expected);
			}
		case PCJsxAttributes | PCJsxChildren | PCJSDocComment:
			parseErrorAtCurrentToken(Diagnostics.Identifier_expected);
		case PCImportAttributes:
			parseErrorAtCurrentToken(Diagnostics.Identifier_or_string_literal_expected);
		default:
			throw "Unhandled case in parsingContextErrors";
		}
	}

	function isListElement(parsingContext:ParsingContext, inErrorRecovery:Bool):Bool {
		switch (parsingContext) {
		case PCSourceElements | PCBlockStatements | PCSwitchClauseStatements:
			// If we're in error recovery, then we don't want to treat ';' as an empty statement.
			// The problem is that ';' can show up in far too many contexts, and if we see one
			// and assume it's a statement, then we may bail out inappropriately from whatever
			// we're parsing.  For example, if we have a semicolon in the middle of a class, then
			// we really don't want to assume the class is over and we're on a statement in the
			// outer module.  We just want to consume and move on.
			return !(token == KindSemicolonToken && inErrorRecovery) && isStartOfStatement();
		case PCSwitchClauses:
			return token == KindCaseKeyword || token == KindDefaultKeyword;
		case PCTypeMembers:
			return lookAhead(fn_scanTypeMemberStart);
		case PCClassMembers:
			// We allow semicolons as class elements (as specified by ES6) as long as we're
			// not in error recovery.  If we're in error recovery, we don't want an errant
			// semicolon to be treated as a class member (since they're almost always used
			// for statements.
			return lookAhead(fn_scanClassMemberStart) || token == KindSemicolonToken && !inErrorRecovery;
		case PCEnumMembers:
			// Include open bracket computed properties. This technically also lets in indexers,
			// which would be a candidate for improved error reporting.
			return token == KindOpenBracketToken || isLiteralPropertyName();
		case PCObjectLiteralMembers:
			switch (token) {
			case KindOpenBracketToken | KindAsteriskToken | KindDotDotDotToken | KindDotToken: // Not an object literal member, but don't want to close the object (see `tests/cases/fourslash/completionsDotInObjectLiteral.ts`)
				return true;
			default:
				return isLiteralPropertyName();
			}
		case PCRestProperties:
			return isLiteralPropertyName();
		case PCObjectBindingElements:
			return token == KindOpenBracketToken || token == KindDotDotDotToken || isLiteralPropertyName();
		case PCImportAttributes:
			return isImportAttributeName();
		case PCHeritageClauseElement:
			// If we see `{ ... }` then only consume it as an expression if it is followed by `,` or `{`
			// That way we won't consume the body of a class in its heritage clause.
			if (token == KindOpenBraceToken) {
				return isValidHeritageClauseObjectLiteral();
			}
			if (!inErrorRecovery) {
				return isStartOfLeftHandSideExpression() && !isHeritageClauseExtendsOrImplementsKeyword();
			}
			// If we're in error recovery we tighten up what we're willing to match.
			// That way we don't treat something like "this" as a valid heritage clause
			// element during recovery.
			return isIdentifier() && !isHeritageClauseExtendsOrImplementsKeyword();
		case PCVariableDeclarations:
			return isBindingIdentifierOrPrivateIdentifierOrPattern();
		case PCArrayBindingElements:
			return token == KindCommaToken || token == KindDotDotDotToken || isBindingIdentifierOrPrivateIdentifierOrPattern();
		case PCTypeParameters:
			return token == KindInKeyword || token == KindConstKeyword || isIdentifier();
		case PCArrayLiteralMembers:
			// Not an array literal member, but don't want to close the array (see `tests/cases/fourslash/completionsDotInArrayLiteralInObjectLiteral.ts`)
			if (token == KindCommaToken || token == KindDotToken) {
				return true;
			}
			// PORT: fallthrough into PCArgumentExpressions.
			return token == KindDotDotDotToken || isStartOfExpression();
		case PCArgumentExpressions:
			return token == KindDotDotDotToken || isStartOfExpression();
		case PCParameters:
			return isStartOfParameter(false /*isJSDocParameter*/);
		case PCJSDocParameters:
			return isStartOfParameter(true /*isJSDocParameter*/);
		case PCTypeArguments | PCTupleElementTypes:
			return token == KindCommaToken || isStartOfType(false /*inStartOfParameter*/);
		case PCHeritageClauses:
			return isHeritageClause();
		case PCImportOrExportSpecifiers:
			// bail out if the next token is [FromKeyword StringLiteral].
			// That means we're in something like `import { from "mod"`. Stop here can give better error message.
			if (token == KindFromKeyword && lookAhead(fn_nextTokenIsTokenStringLiteral)) {
				return false;
			}
			if (token == KindStringLiteral) {
				return true; // For "arbitrary module namespace identifiers"
			}
			return tokenIsIdentifierOrKeyword(token);
		case PCJsxAttributes:
			return tokenIsIdentifierOrKeyword(token) || token == KindOpenBraceToken;
		case PCJsxChildren:
			return true;
		case PCJSDocComment:
			return true;
		default:
		}
		throw "Unhandled case in isListElement";
	}

	function isListTerminator(kind:ParsingContext):Bool {
		if (token == KindEndOfFile) {
			return true;
		}
		switch (kind) {
		case PCBlockStatements | PCSwitchClauses | PCTypeMembers | PCClassMembers | PCEnumMembers | PCObjectLiteralMembers | PCObjectBindingElements | PCImportOrExportSpecifiers | PCImportAttributes:
			return token == KindCloseBraceToken;
		case PCSwitchClauseStatements:
			return token == KindCloseBraceToken || token == KindCaseKeyword || token == KindDefaultKeyword;
		case PCHeritageClauseElement:
			return token == KindOpenBraceToken || token == KindExtendsKeyword || token == KindImplementsKeyword;
		case PCVariableDeclarations:
			// If we can consume a semicolon (either explicitly, or with ASI), then consider us done
			// with parsing the list of variable declarators.
			// In the case where we're parsing the variable declarator of a 'for-in' statement, we
			// are done if we see an 'in' keyword in front of us. Same with for-of
			// ERROR RECOVERY TWEAK:
			// For better error recovery, if we see an '=>' then we just stop immediately.  We've got an
			// arrow function here and it's going to be very unlikely that we'll resynchronize and get
			// another variable declaration.
			return canParseSemicolon() || token == KindInKeyword || token == KindOfKeyword || token == KindEqualsGreaterThanToken;
		case PCTypeParameters:
			// Tokens other than '>' are here for better error recovery
			return token == KindGreaterThanToken || token == KindOpenParenToken || token == KindOpenBraceToken || token == KindExtendsKeyword || token == KindImplementsKeyword;
		case PCArgumentExpressions:
			// Tokens other than ')' are here for better error recovery
			return token == KindCloseParenToken || token == KindSemicolonToken;
		case PCArrayLiteralMembers | PCTupleElementTypes | PCArrayBindingElements:
			return token == KindCloseBracketToken;
		case PCJSDocParameters | PCParameters | PCRestProperties:
			// Tokens other than ')' and ']' (the latter for index signatures) are here for better error recovery
			return token == KindCloseParenToken || token == KindCloseBracketToken /*|| token == KindOpenBraceToken*/;
		case PCTypeArguments:
			// All other tokens should cause the type-argument to terminate except comma token
			return token != KindCommaToken;
		case PCHeritageClauses:
			return token == KindOpenBraceToken || token == KindCloseBraceToken;
		case PCJsxAttributes:
			return token == KindGreaterThanToken || token == KindSlashToken;
		case PCJsxChildren:
			return token == KindLessThanToken && lookAhead(fn_nextTokenIsSlash);
		default:
		}
		return false;
	}

	function parseExpectedJSDoc(kind:Kind):Bool {
		if (token == kind) {
			nextTokenJSDoc();
			return true;
		}
		if (!isKeywordOrPunctuation(kind)) {
			throw "Invalid JSDoc kind: expected keyword or punctuation";
		}
		parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(kind));
		return false;
	}

	function parseExpectedMatchingBrackets(openKind:Kind, closeKind:Kind, openParsed:Bool, openPosition:Int):Void {
		if (token == closeKind) {
			nextToken();
			return;
		}
		var lastError = parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(closeKind));
		if (!openParsed) {
			return;
		}
		if (lastError != null) {
			var related = Ast.NewDiagnostic(null, Core.NewTextRange(openPosition, openPosition), Diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, Scanner.TokenToString(openKind), Scanner.TokenToString(closeKind));
			lastError.AddRelatedInfo(related);
		}
	}

	function parseOptional(token:Kind):Bool {
		if (this.token == token) {
			nextToken();
			return true;
		}
		return false;
	}

	function parseExpected(kind:Kind):Bool {
		return parseExpectedWithDiagnostic(kind, null, true);
	}

	function parseExpectedWithoutAdvancing(kind:Kind):Bool {
		return parseExpectedWithDiagnostic(kind, null, false);
	}

	function parseExpectedWithDiagnostic(kind:Kind, message:Message, shouldAdvance:Bool):Bool {
		if (token == kind) {
			if (shouldAdvance) {
				nextToken();
			}
			return true;
		}
		// Report specific message if provided with one.  Otherwise, report generic fallback message.
		if (message != null) {
			parseErrorAtCurrentToken(message);
		} else {
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(kind));
		}
		return false;
	}

	function parseTokenNode():Node {
		var pos = nodePos();
		var kind = token;
		nextToken();
		return finishNode(factory.NewToken(kind), pos);
	}

	function parseExpectedToken(kind:Kind):Node {
		var token = parseOptionalToken(kind);
		if (token == null) {
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(kind));
			token = finishNode(factory.NewToken(kind), nodePos());
		}
		return token;
	}

	function parseOptionalToken(kind:Kind):Node {
		if (token == kind) {
			return parseTokenNode();
		}
		return null;
	}

	function parseExpectedTokenJSDoc(kind:Kind):Node {
		var optional = parseOptionalTokenJSDoc(kind);
		if (optional == null) {
			if (!isKeywordOrPunctuation(kind)) {
				throw "expected keyword or punctuation";
			}
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(kind));
			optional = finishNode(factory.NewToken(kind), nodePos());
		}
		return optional;
	}

	function parseOptionalTokenJSDoc(kind:Kind):Node {
		if (token == kind) {
			return parseTokenNode();
		}
		return null;
	}

	function parseStatement():Statement {
		switch (token) {
		case KindSemicolonToken:
			return parseEmptyStatement();
		case KindOpenBraceToken:
			return parseBlock(false /*ignoreMissingOpenBrace*/, null);
		case KindVarKeyword:
			return parseVariableStatement(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
		case KindLetKeyword:
			if (isLetDeclaration()) {
				return parseVariableStatement(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
			}
		case KindAwaitKeyword:
			if (isAwaitUsingDeclaration()) {
				return parseVariableStatement(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
			}
		case KindUsingKeyword:
			if (isUsingDeclaration()) {
				return parseVariableStatement(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
			}
		case KindFunctionKeyword:
			return parseFunctionDeclaration(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
		case KindClassKeyword:
			return parseClassDeclaration(nodePos(), jsdocScannerInfo(), null /*modifiers*/);
		case KindIfKeyword:
			return parseIfStatement();
		case KindDoKeyword:
			return parseDoStatement();
		case KindWhileKeyword:
			return parseWhileStatement();
		case KindForKeyword:
			return parseForOrForInOrForOfStatement();
		case KindContinueKeyword:
			return parseContinueStatement();
		case KindBreakKeyword:
			return parseBreakStatement();
		case KindReturnKeyword:
			return parseReturnStatement();
		case KindWithKeyword:
			return parseWithStatement();
		case KindSwitchKeyword:
			return parseSwitchStatement();
		case KindThrowKeyword:
			return parseThrowStatement();
		case KindTryKeyword | KindCatchKeyword | KindFinallyKeyword:
			return parseTryStatement();
		case KindDebuggerKeyword:
			return parseDebuggerStatement();
		case KindAtToken:
			return parseDeclaration();
		case KindAsyncKeyword | KindInterfaceKeyword | KindTypeKeyword | KindModuleKeyword | KindNamespaceKeyword | KindDeclareKeyword | KindConstKeyword | KindEnumKeyword | KindExportKeyword | KindImportKeyword | KindPrivateKeyword | KindProtectedKeyword | KindPublicKeyword | KindAbstractKeyword | KindAccessorKeyword | KindStaticKeyword | KindReadonlyKeyword | KindGlobalKeyword:
			if (isStartOfDeclaration()) {
				return parseDeclaration();
			}
		default:
		}
		return parseExpressionOrLabeledStatement();
	}

	function parseDeclaration():Statement {
		// `parseListElement` attempted to get the reused node at this position,
		// but the ambient context flag was not yet set, so the node appeared
		// not reusable in that context.
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiersEx( /*allowDecorators*/ true, false /*permitConstAsModifier*/, false /*stopOnStartOfClassStaticBlock*/);
		var isAmbient = modifiers != null && Core.Some(modifiers.Nodes, isDeclareModifier);
		if (isAmbient) {
			// !!! incremental parsing
			// node := p.tryReuseAmbientDeclaration(pos)
			// if node {
			// 	return node
			// }
			for (m in nodesOf(modifiers.Nodes)) {
				m.Flags |= NodeFlagsAmbient;
			}
			var saveContextFlags = contextFlags;
			setContextFlags(NodeFlagsAmbient, true);
			var result = parseDeclarationWorker(pos, jsdoc, modifiers);
			contextFlags = saveContextFlags;
			return result;
		} else {
			return parseDeclarationWorker(pos, jsdoc, modifiers);
		}
	}

	function parseDeclarationWorker(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Statement {
		switch (token) {
		case KindVarKeyword | KindLetKeyword | KindConstKeyword | KindUsingKeyword:
			return parseVariableStatement(pos, jsdoc, modifiers);
		case KindAwaitKeyword:
			if (isAwaitUsingDeclaration()) {
				return parseVariableStatement(pos, jsdoc, modifiers);
			}
		case KindFunctionKeyword:
			return parseFunctionDeclaration(pos, jsdoc, modifiers);
		case KindClassKeyword:
			return parseClassDeclaration(pos, jsdoc, modifiers);
		case KindInterfaceKeyword:
			return parseInterfaceDeclaration(pos, jsdoc, modifiers);
		case KindTypeKeyword:
			return parseTypeAliasDeclaration(pos, jsdoc, modifiers);
		case KindEnumKeyword:
			return parseEnumDeclaration(pos, jsdoc, modifiers);
		case KindGlobalKeyword | KindModuleKeyword | KindNamespaceKeyword:
			return parseModuleDeclaration(pos, jsdoc, modifiers);
		case KindImportKeyword:
			return parseImportDeclarationOrImportEqualsDeclaration(pos, jsdoc, modifiers);
		case KindExportKeyword:
			nextToken();
			switch (token) {
			case KindDefaultKeyword | KindEqualsToken:
				return parseExportAssignment(pos, jsdoc, modifiers);
			case KindAsKeyword:
				return parseNamespaceExportDeclaration(pos, jsdoc, modifiers);
			default:
				return parseExportDeclaration(pos, jsdoc, modifiers);
			}
		default:
		}
		if (modifiers != null) {
			// We reached this point because we encountered decorators and/or modifiers and assumed a declaration
			// would follow. For recovery and error reporting purposes, return an incomplete declaration.
			parseErrorAt(nodePos(), nodePos(), Diagnostics.Declaration_expected);
			return finishNode(factory.NewMissingDeclaration(modifiers), pos);
		}
		throw "Unhandled case in parseDeclarationWorker";
	}

	// PORT: passed as a function value (core.Some) → a function value created once (PORTING.md §7a).
	static final isDeclareModifier:(modifier:Node) -> Bool = function(modifier:Node):Bool {
		return modifier.Kind == KindDeclareKeyword;
	};

	function isLetDeclaration():Bool {
		// In ES6 'let' always starts a lexical declaration if followed by an identifier or {
		// or [.
		return lookAhead(fn_nextTokenIsBindingIdentifierOrStartOfDestructuring);
	}

	function nextTokenIsBindingIdentifierOrStartOfDestructuring():Bool {
		nextToken();
		return isBindingIdentifier() || token == KindOpenBraceToken || token == KindOpenBracketToken;
	}

	function parseBlock(ignoreMissingOpenBrace:Bool, diagnosticMessage:Message):Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var openBracePosition = scanner.TokenStart();
		var openBraceParsed = parseExpectedWithDiagnostic(KindOpenBraceToken, diagnosticMessage, true /*shouldAdvance*/);
		var multiline = false;
		if (openBraceParsed || ignoreMissingOpenBrace) {
			multiline = hasPrecedingLineBreak();
			var statements = parseList(PCBlockStatements, fn_parseStatement);
			parseExpectedMatchingBrackets(KindOpenBraceToken, KindCloseBraceToken, openBraceParsed, openBracePosition);
			var result = finishNode(factory.NewBlock(statements, multiline), pos);
			this.withJSDoc(result, jsdoc);
			if (token == KindEqualsToken) {
				parseErrorAtCurrentToken(Diagnostics.Declaration_or_statement_expected_This_follows_a_block_of_statements_so_if_you_intended_to_write_a_destructuring_assignment_you_might_need_to_wrap_the_whole_assignment_in_parentheses);
				nextToken();
			}
			return result;
		}
		var result = finishNode(factory.NewBlock(createMissingList(), multiline), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseEmptyStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindSemicolonToken);
		var result = finishNode(factory.NewEmptyStatement(), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseIfStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindIfKeyword);
		var openParenPosition = scanner.TokenStart();
		var openParenParsed = parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpectedMatchingBrackets(KindOpenParenToken, KindCloseParenToken, openParenParsed, openParenPosition);
		var thenStatement = parseStatement();
		var elseStatement:Statement = null;
		if (parseOptional(KindElseKeyword)) {
			elseStatement = parseStatement();
		}
		var result = finishNode(factory.NewIfStatement(expression, thenStatement, elseStatement), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseDoStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindDoKeyword);
		var statement = parseStatement();
		parseExpected(KindWhileKeyword);
		var openParenPosition = scanner.TokenStart();
		var openParenParsed = parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpectedMatchingBrackets(KindOpenParenToken, KindCloseParenToken, openParenParsed, openParenPosition);
		// From: https://mail.mozilla.org/pipermail/es-discuss/2011-August/016188.html
		// 157 min --- All allen at wirfs-brock.com CONF --- "do{;}while(false)false" prohibited in
		// spec but allowed in consensus reality. Approved -- this is the de-facto standard whereby
		//  do;while(0)x will have a semicolon inserted before x.
		parseOptional(KindSemicolonToken);
		var result = finishNode(factory.NewDoStatement(statement, expression), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseWhileStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindWhileKeyword);
		var openParenPosition = scanner.TokenStart();
		var openParenParsed = parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpectedMatchingBrackets(KindOpenParenToken, KindCloseParenToken, openParenParsed, openParenPosition);
		var statement = parseStatement();
		var result = finishNode(factory.NewWhileStatement(expression, statement), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseForOrForInOrForOfStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindForKeyword);
		var awaitToken = parseOptionalToken(KindAwaitKeyword);
		parseExpected(KindOpenParenToken);
		var initializer:ForInitializer = null;
		if (token != KindSemicolonToken) {
			if (token == KindVarKeyword || token == KindLetKeyword || token == KindConstKeyword ||
				token == KindUsingKeyword && lookAhead(fn_nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf) ||
				// this one is meant to allow of
				token == KindAwaitKeyword && lookAhead(fn_nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine)) {
				initializer = parseVariableDeclarationList(true /*inForStatementInitializer*/);
			} else {
				initializer = doInContext(this, NodeFlagsDisallowInContext, true, fn_parseExpression);
			}
		}
		var result:Statement = null;
		// PORT: tagless switch → if/else chain.
		if (awaitToken != null && parseExpected(KindOfKeyword) || awaitToken == null && parseOptional(KindOfKeyword)) {
			var expression = doInContext(this, NodeFlagsDisallowInContext, false, fn_parseAssignmentExpressionOrHigher);
			parseExpected(KindCloseParenToken);
			result = factory.NewForInOrOfStatement(KindForOfStatement, awaitToken, initializer, expression, parseStatement());
		} else if (parseOptional(KindInKeyword)) {
			var expression = parseExpressionAllowIn();
			parseExpected(KindCloseParenToken);
			result = factory.NewForInOrOfStatement(KindForInStatement, null /*awaitToken*/, initializer, expression, parseStatement());
		} else {
			parseExpected(KindSemicolonToken);
			var condition:Expression = null;
			if (token != KindSemicolonToken && token != KindCloseParenToken) {
				condition = parseExpressionAllowIn();
			}
			parseExpected(KindSemicolonToken);
			var incrementor:Expression = null;
			if (token != KindCloseParenToken) {
				incrementor = parseExpressionAllowIn();
			}
			parseExpected(KindCloseParenToken);
			result = factory.NewForStatement(initializer, condition, incrementor, parseStatement());
		}
		finishNode(result, pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseBreakStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindBreakKeyword);
		var label = parseIdentifierUnlessAtSemicolon();
		parseSemicolon();
		var result = finishNode(factory.NewBreakStatement(label), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseContinueStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindContinueKeyword);
		var label = parseIdentifierUnlessAtSemicolon();
		parseSemicolon();
		var result = finishNode(factory.NewContinueStatement(label), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseIdentifierUnlessAtSemicolon():Node {
		if (!canParseSemicolon()) {
			return parseIdentifier();
		}
		return null;
	}

	function parseReturnStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindReturnKeyword);
		var expression:Expression = null;
		if (!canParseSemicolon()) {
			expression = parseExpressionAllowIn();
		}
		parseSemicolon();
		var result = finishNode(factory.NewReturnStatement(expression), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseWithStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindWithKeyword);
		var openParenPosition = scanner.TokenStart();
		var openParenParsed = parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpectedMatchingBrackets(KindOpenParenToken, KindCloseParenToken, openParenParsed, openParenPosition);
		var statement = doInContext(this, NodeFlagsInWithStatement, true, fn_parseStatement);
		var result = finishNode(factory.NewWithStatement(expression, statement), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseCaseClause():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindCaseKeyword);
		var expression = parseExpressionAllowIn();
		parseExpected(KindColonToken);
		var statements = parseList(PCSwitchClauseStatements, fn_parseStatement);
		var result = finishNode(factory.NewCaseOrDefaultClause(KindCaseClause, expression, statements), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseDefaultClause():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindDefaultKeyword);
		parseExpected(KindColonToken);
		var statements = parseList(PCSwitchClauseStatements, fn_parseStatement);
		var result = finishNode(factory.NewCaseOrDefaultClause(KindDefaultClause, null /*expression*/, statements), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseCaseOrDefaultClause():Node {
		if (token == KindCaseKeyword) {
			return parseCaseClause();
		}
		return parseDefaultClause();
	}

	function parseCaseBlock():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindOpenBraceToken);
		var clauses = parseList(PCSwitchClauses, fn_parseCaseOrDefaultClause);
		parseExpected(KindCloseBraceToken);
		var result = finishNode(factory.NewCaseBlock(clauses), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseSwitchStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindSwitchKeyword);
		parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpected(KindCloseParenToken);
		var caseBlock = parseCaseBlock();
		var result = finishNode(factory.NewSwitchStatement(expression, caseBlock), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseThrowStatement():Node {
		// ThrowStatement[Yield] :
		//      throw [no LineTerminator here]Expression[In, ?Yield];
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindThrowKeyword);
		// Because of automatic semicolon insertion, we need to report error if this
		// throw could be terminated with a semicolon.  Note: we can't call 'parseExpression'
		// directly as that might consume an expression on the following line.
		// Instead, we create a "missing" identifier, but don't report an error. The actual error
		// will be reported in the grammar walker.
		var expression:Expression = null;
		if (!hasPrecedingLineBreak()) {
			expression = parseExpressionAllowIn();
		} else {
			expression = createMissingIdentifier();
		}
		if (!tryParseSemicolon()) {
			parseErrorForMissingSemicolonAfter(expression);
		}
		var result = finishNode(factory.NewThrowStatement(expression), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	// TODO: Review for error recovery
	function parseTryStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindTryKeyword);
		var tryBlock = parseBlock(false /*ignoreMissingOpenBrace*/, null);
		var catchClause:Node = null;
		if (token == KindCatchKeyword) {
			catchClause = parseCatchClause();
		}
		// If we don't have a catch clause, then we must have a finally clause.  Try to parse
		// one out no matter what.
		var finallyBlock:Node = null;
		if (catchClause == null || token == KindFinallyKeyword) {
			parseExpectedWithDiagnostic(KindFinallyKeyword, Diagnostics.X_catch_or_finally_expected, true /*shouldAdvance*/);
			finallyBlock = parseBlock(false /*ignoreMissingOpenBrace*/, null);
		}
		var result = finishNode(factory.NewTryStatement(tryBlock, catchClause, finallyBlock), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseCatchClause():Node {
		var pos = nodePos();
		parseExpected(KindCatchKeyword);
		var variableDeclaration:Node = null;
		if (parseOptional(KindOpenParenToken)) {
			variableDeclaration = parseVariableDeclaration();
			parseExpected(KindCloseParenToken);
		}
		var block = parseBlock(false /*ignoreMissingOpenBrace*/, null);
		var result = finishNode(factory.NewCatchClause(variableDeclaration, block), pos);
		return result;
	}

	function parseDebuggerStatement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindDebuggerKeyword);
		parseSemicolon();
		var result = finishNode(factory.NewDebuggerStatement(), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseExpressionOrLabeledStatement():Statement {
		// Avoiding having to do the lookahead for a labeled statement by just trying to parse
		// out an expression, seeing if it is identifier and then seeing if it is followed by
		// a colon.
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var hasParen = token == KindOpenParenToken;
		var expression = parseExpression();

		if (expression.Kind == KindIdentifier && parseOptional(KindColonToken)) {
			var result = finishNode(factory.NewLabeledStatement(expression, parseStatement()), pos);
			this.withJSDoc(result, jsdoc);
			return result;
		}

		if (!tryParseSemicolon()) {
			parseErrorForMissingSemicolonAfter(expression);
		}
		var result = finishNode(factory.NewExpressionStatement(expression), pos);
		if (hasParen) {
			jsdoc &= ~(jsdocScannerInfoHasJSDoc);
		}
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseVariableStatement(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var declarationList = parseVariableDeclarationList(false /*inForStatementInitializer*/);
		parseSemicolon();
		var result = finishNode(factory.NewVariableStatement(modifiers, declarationList), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseVariableDeclarationList(inForStatementInitializer:Bool):Node {
		var pos = nodePos();
		var flags:NodeFlags = NodeFlagsNone;
		switch (token) {
		case KindVarKeyword:
			flags = NodeFlagsNone;
		case KindLetKeyword:
			flags = NodeFlagsLet;
		case KindConstKeyword:
			flags = NodeFlagsConst;
		case KindUsingKeyword:
			flags = NodeFlagsUsing;
		case KindAwaitKeyword:
			// PORT: Go `break` out of the switch when not `await using`.
			if (isAwaitUsingDeclaration()) {
				flags = NodeFlagsAwaitUsing;
				nextToken();
			}
		default:
			throw "Unhandled case in parseVariableDeclarationList";
		}
		nextToken();
		// The user may have written the following:
		//
		//    for (let of X) { }
		//
		// In this case, we want to parse an empty declaration list, and then parse 'of'
		// as a keyword. The reason this is not automatic is that 'of' is a valid identifier.
		// So we need to look ahead to determine if 'of' should be treated as a keyword in
		// this context.
		// The checker will then give an error that there is an empty declaration list.
		var declarations:NodeList = null;
		if (token == KindOfKeyword && lookAhead(fn_nextIsIdentifierAndCloseParen)) {
			declarations = createMissingList();
		} else {
			var saveContextFlags = contextFlags;
			setContextFlags(NodeFlagsDisallowInContext, inForStatementInitializer);
			declarations = parseDelimitedList(PCVariableDeclarations, (inForStatementInitializer ? fn_parseVariableDeclaration : fn_parseVariableDeclarationAllowExclamation));
			contextFlags = saveContextFlags;
		}
		var result = finishNode(factory.NewVariableDeclarationList(declarations, flags), pos);
		return result;
	}

	function nextIsIdentifierAndCloseParen():Bool {
		return nextTokenIsIdentifier() && nextToken() == KindCloseParenToken;
	}

	function nextTokenIsIdentifier():Bool {
		nextToken();
		return isIdentifier();
	}

	function parseVariableDeclaration():Node {
		return parseVariableDeclarationWorker(false /*allowExclamation*/);
	}

	function parseVariableDeclarationAllowExclamation():Node {
		return parseVariableDeclarationWorker(true /*allowExclamation*/);
	}

	function parseVariableDeclarationWorker(allowExclamation:Bool):Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var name = parseIdentifierOrPatternWithDiagnostic(Diagnostics.Private_identifiers_are_not_allowed_in_variable_declarations);
		var exclamationToken:Node = null;
		if (allowExclamation && name.Kind == KindIdentifier && token == KindExclamationToken && !hasPrecedingLineBreak()) {
			exclamationToken = parseTokenNode();
		}
		var typeNode = parseTypeAnnotation();
		var initializer:Expression = null;
		if (token != KindInKeyword && token != KindOfKeyword) {
			initializer = parseInitializer();
		}
		var result = finishNode(factory.NewVariableDeclaration(name, exclamationToken, typeNode, initializer), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseIdentifierOrPattern():Node {
		return parseIdentifierOrPatternWithDiagnostic(null);
	}

	function parseIdentifierOrPatternWithDiagnostic(privateIdentifierDiagnosticMessage:Message):Node {
		if (token == KindOpenBracketToken) {
			return parseArrayBindingPattern();
		}
		if (token == KindOpenBraceToken) {
			return parseObjectBindingPattern();
		}
		return parseBindingIdentifierWithDiagnostic(privateIdentifierDiagnosticMessage);
	}

	function parseArrayBindingPattern():Node {
		var pos = nodePos();
		parseExpected(KindOpenBracketToken);
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsDisallowInContext, false);
		var elements = parseDelimitedList(PCArrayBindingElements, fn_parseArrayBindingElement);
		contextFlags = saveContextFlags;
		parseExpected(KindCloseBracketToken);
		return finishNode(factory.NewBindingPattern(KindArrayBindingPattern, elements), pos);
	}

	function parseArrayBindingElement():Node {
		var pos = nodePos();
		var dotDotDotToken:Node = null;
		var name:Node = null;
		var initializer:Expression = null;
		if (token != KindCommaToken) {
			// These are all nil for a missing element
			dotDotDotToken = parseOptionalToken(KindDotDotDotToken);
			name = parseIdentifierOrPattern();
			initializer = parseInitializer();
		}
		return finishNode(factory.NewBindingElement(dotDotDotToken, null /*propertyName*/, name, initializer), pos);
	}

	function parseObjectBindingPattern():Node {
		var pos = nodePos();
		parseExpected(KindOpenBraceToken);
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsDisallowInContext, false);
		var elements = parseDelimitedList(PCObjectBindingElements, fn_parseObjectBindingElement);
		contextFlags = saveContextFlags;
		parseExpected(KindCloseBraceToken);
		return finishNode(factory.NewBindingPattern(KindObjectBindingPattern, elements), pos);
	}

	function parseObjectBindingElement():Node {
		var pos = nodePos();
		var dotDotDotToken = parseOptionalToken(KindDotDotDotToken);
		var tokenIsIdentifier = isBindingIdentifier();
		var propertyName = parsePropertyName();
		var name:Node = null;
		if (tokenIsIdentifier && token != KindColonToken) {
			name = propertyName;
			propertyName = null;
		} else {
			parseExpected(KindColonToken);
			name = parseIdentifierOrPattern();
		}
		var initializer = parseInitializer();
		return finishNode(factory.NewBindingElement(dotDotDotToken, propertyName, name, initializer), pos);
	}

	function parseInitializer():Expression {
		if (parseOptional(KindEqualsToken)) {
			return parseAssignmentExpressionOrHigher();
		}
		return null;
	}

	function parseTypeAnnotation():TypeNode {
		if (parseOptional(KindColonToken)) {
			return parseType();
		}
		return null;
	}

	function parseFunctionDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		parseExpected(KindFunctionKeyword);
		var asteriskToken = parseOptionalToken(KindAsteriskToken);
		// We don't parse the name here in await context, instead we will report a grammar error in the checker.
		var name:Node = null;
		if (modifiers == null || modifiers.ModifierFlags&ModifierFlagsDefault == 0 || isBindingIdentifier()) {
			name = parseBindingIdentifier();
		}
		var signatureFlags = (asteriskToken != null ? ParseFlagsYield : ParseFlagsNone) | (modifiers != null && modifiers.ModifierFlags & ModifierFlagsAsync != 0 ? ParseFlagsAwait : ParseFlagsNone);
		var typeParameters = parseTypeParameters();
		var saveContextFlags = contextFlags;
		if (modifiers != null && modifiers.ModifierFlags&ModifierFlagsExport != 0) {
			setContextFlags(NodeFlagsAwaitContext, true);
		}
		var parameters = parseParameters(signatureFlags);
		var returnType = parseReturnType(KindColonToken, false /*isType*/);
		var body = parseFunctionBlockOrSemicolon(signatureFlags, Diagnostics.X_or_expected);
		contextFlags = saveContextFlags;
		var result = finishNode(factory.NewFunctionDeclaration(modifiers, asteriskToken, name, typeParameters, parameters, returnType, null /*fullSignature*/, body), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseClassDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		return parseClassDeclarationOrExpression(pos, jsdoc, modifiers, KindClassDeclaration);
	}

	function parseClassExpression():Node {
		return parseClassDeclarationOrExpression(nodePos(), jsdocScannerInfo(), null /*modifiers*/, KindClassExpression);
	}

	function parseClassDeclarationOrExpression(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, kind:Kind):Node {
		var saveContextFlags = contextFlags;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		parseExpected(KindClassKeyword);
		// We don't parse the name here in await context, instead we will report a grammar error in the checker.
		var name = parseNameOfClassDeclarationOrExpression();
		var typeParameters = parseTypeParameters();
		if (modifiers != null && Core.Some(modifiers.Nodes, isExportModifier)) {
			setContextFlags(NodeFlagsAwaitContext, true /*value*/);
		}
		var heritageClauses = parseHeritageClauses();
		var members:NodeList = null;
		if (parseExpected(KindOpenBraceToken)) {
			// ClassTail[Yield,Await] : (Modified) See 14.5
			//      ClassHeritage[?Yield,?Await]opt { ClassBody[?Yield,?Await]opt }
			members = parseList(PCClassMembers, fn_parseClassElement);
			parseExpected(KindCloseBraceToken);
		} else {
			members = createMissingList();
		}
		contextFlags = saveContextFlags;
		var result:Node = null;
		if (modifiers != null && Ast.ModifiersToFlags(modifiers.Nodes)&ModifierFlagsAmbient != 0) {
			statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		}
		if (kind == KindClassDeclaration) {
			result = factory.NewClassDeclaration(modifiers, name, typeParameters, heritageClauses, members);
		} else {
			result = factory.NewClassExpression(modifiers, name, typeParameters, heritageClauses, members);
		}
		finishNode(result, pos);
		this.withJSDoc(result, jsdoc);
		if (result.Flags&NodeFlagsJavaScriptFile != 0) {
			checkJSSyntax(result);
			if (heritageClauses != null) {
				for (clause in nodesOf(heritageClauses.Nodes)) {
					if (clause.AsHeritageClause().Token == KindExtendsKeyword) {
						for (expr in nodesOf(clause.AsHeritageClause().Types.Nodes)) {
							checkJSSyntax(expr);
						}
					}
				}
			}
		}
		return result;
	}

	function parseNameOfClassDeclarationOrExpression():Node {
		// implements is a future reserved word so
		// 'class implements' might mean either
		// - class expression with omitted name, 'implements' starts heritage clause
		// - class with name 'implements'
		// 'isImplementsClause' helps to disambiguate between these two cases
		if (isBindingIdentifier() && !isImplementsClause()) {
			var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
			var id = createIdentifier(isBindingIdentifier());
			statementHasAwaitIdentifier = saveHasAwaitIdentifier;
			return id;
		}
		return null;
	}

	function isImplementsClause():Bool {
		return token == KindImplementsKeyword && lookAhead(fn_nextTokenIsIdentifierOrKeyword);
	}

	// PORT: passed as a function value (core.Some) → a function value created once (PORTING.md §7a).
	static final isExportModifier:(modifier:Node) -> Bool = function(modifier:Node):Bool {
		return modifier.Kind == KindExportKeyword;
	};

	// PORT: passed as a function value (core.Some) → a function value created once (PORTING.md §7a).
	static final isAsyncModifier:(modifier:Node) -> Bool = function(modifier:Node):Bool {
		return modifier.Kind == KindAsyncKeyword;
	};

	function parseHeritageClauses():NodeList {
		// ClassTail[Yield,Await] : (Modified) See 14.5
		//      ClassHeritage[?Yield,?Await]opt { ClassBody[?Yield,?Await]opt }
		if (isHeritageClause()) {
			return parseList(PCHeritageClauses, fn_parseHeritageClause);
		}
		return null;
	}

	function parseHeritageClause():Node {
		var pos = nodePos();
		var kind = token;
		nextToken();
		var types = parseDelimitedList(PCHeritageClauseElement, fn_parseExpressionWithTypeArguments);
		return checkJSSyntax(finishNode(factory.NewHeritageClause(kind, types), pos));
	}

	function parseExpressionWithTypeArguments():Node {
		var pos = nodePos();
		var expression = parseLeftHandSideExpressionOrHigher();
		if (Ast.IsExpressionWithTypeArguments(expression)) {
			return expression;
		}
		var typeArguments = parseTypeArguments();
		return finishNode(factory.NewExpressionWithTypeArguments(expression, typeArguments), pos);
	}

	function parseClassElement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		if (token == KindSemicolonToken) {
			nextToken();
			var result = finishNode(factory.NewSemicolonClassElement(), pos);
			this.withJSDoc(result, jsdoc);
			return result;
		}
		var modifiers = parseModifiersEx(true /*allowDecorators*/, true /*permitConstAsModifier*/, true /*stopOnStartOfClassStaticBlock*/);
		if (token == KindStaticKeyword && lookAhead(fn_nextTokenIsOpenBrace)) {
			return parseClassStaticBlockDeclaration(pos, jsdoc, modifiers);
		}
		if (parseContextualModifier(KindGetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindGetAccessor, ParseFlagsNone);
		}
		if (parseContextualModifier(KindSetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindSetAccessor, ParseFlagsNone);
		}
		if (token == KindConstructorKeyword || token == KindStringLiteral) {
			var constructorDeclaration = tryParseConstructorDeclaration(pos, jsdoc, modifiers);
			if (constructorDeclaration != null) {
				return constructorDeclaration;
			}
		}
		if (isIndexSignature()) {
			return checkJSSyntax(parseIndexSignatureDeclaration(pos, jsdoc, modifiers));
		}
		// It is very important that we check this *after* checking indexers because
		// the [ token can start an index signature or a computed property name
		if (tokenIsIdentifierOrKeyword(token) || token == KindStringLiteral || token == KindNumericLiteral || token == KindBigIntLiteral || token == KindAsteriskToken || token == KindOpenBracketToken) {
			var isAmbient = modifiers != null && Core.Some(modifiers.Nodes, isDeclareModifier);
			if (isAmbient) {
				for (m in nodesOf(modifiers.Nodes)) {
					m.Flags |= NodeFlagsAmbient;
				}
				var saveContextFlags = contextFlags;
				setContextFlags(NodeFlagsAmbient, true);
				var result = parsePropertyOrMethodDeclaration(pos, jsdoc, modifiers);
				contextFlags = saveContextFlags;
				return result;
			} else {
				return parsePropertyOrMethodDeclaration(pos, jsdoc, modifiers);
			}
		}
		if (modifiers != null) {
			// treat this as a property declaration with a missing name.
			parseErrorAt(nodePos(), nodePos(), Diagnostics.Declaration_expected);
			var name = createMissingIdentifier();
			return parsePropertyDeclaration(pos, jsdoc, modifiers, name, null /*questionToken*/);
		}
		// 'isClassMemberStart' should have hinted not to attempt parsing.
		throw "Should not have attempted to parse class member declaration.";
	}

	function parseClassStaticBlockDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		parseExpectedToken(KindStaticKeyword);
		var body = parseClassStaticBlockBody();
		var result = finishNode(factory.NewClassStaticBlockDeclaration(modifiers, body), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseClassStaticBlockBody():Node {
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsYieldContext, false);
		setContextFlags(NodeFlagsAwaitContext, true);
		var body = parseBlock(false /*ignoreMissingOpenBrace*/, null /*diagnosticMessage*/);
		contextFlags = saveContextFlags;
		return body;
	}

	function tryParseConstructorDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var state = mark();
		if (token == KindConstructorKeyword || token == KindStringLiteral && scanner.TokenValue() == "constructor" && lookAhead(fn_nextTokenIsOpenParen)) {
			nextToken();
			var typeParameters = parseTypeParameters();
			var parameters = parseParameters(ParseFlagsNone);
			var returnType = parseReturnType(KindColonToken, false /*isType*/);
			var body = parseFunctionBlockOrSemicolon(ParseFlagsNone, Diagnostics.X_or_expected);
			var result = finishNode(factory.NewConstructorDeclaration(modifiers, typeParameters, parameters, returnType, null /*fullSignature*/, body), pos);
			this.withJSDoc(result, jsdoc);
			checkJSSyntax(result);
			return result;
		}
		rewind(state);
		return null;
	}

	function nextTokenIsOpenParen():Bool {
		return nextToken() == KindOpenParenToken;
	}

	function parsePropertyOrMethodDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var asteriskToken = parseOptionalToken(KindAsteriskToken);
		var name = parsePropertyName();
		// Note: this is not legal as per the grammar.  But we allow it in the parser and
		// report an error in the grammar checker.
		var questionToken = parseOptionalToken(KindQuestionToken);
		if (asteriskToken != null || token == KindOpenParenToken || token == KindLessThanToken) {
			return parseMethodDeclaration(pos, jsdoc, modifiers, asteriskToken, name, questionToken, Diagnostics.X_or_expected);
		}
		return parsePropertyDeclaration(pos, jsdoc, modifiers, name, questionToken);
	}

	function parseMethodDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, asteriskToken:Node, name:Node, questionToken:Node, diagnosticMessage:Message):Node {
		var signatureFlags = (asteriskToken != null ? ParseFlagsYield : ParseFlagsNone) | (modifierListHasAsync(modifiers) ? ParseFlagsAwait : ParseFlagsNone);
		var typeParameters = parseTypeParameters();
		var parameters = parseParameters(signatureFlags);
		var typeNode = parseReturnType(KindColonToken, false /*isType*/);
		var body = parseFunctionBlockOrSemicolon(signatureFlags, diagnosticMessage);
		var result = finishNode(factory.NewMethodDeclaration(modifiers, asteriskToken, name, questionToken, typeParameters, parameters, typeNode, null /*fullSignature*/, body), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	static function modifierListHasAsync(modifiers:ModifierList):Bool {
		return modifiers != null && Core.Some(modifiers.Nodes, isAsyncModifier);
	}

	function parsePropertyDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, name:Node, questionToken:Node):Node {
		var postfixToken = questionToken;
		if (postfixToken == null && !hasPrecedingLineBreak()) {
			postfixToken = parseOptionalToken(KindExclamationToken);
		}
		var typeNode = parseTypeAnnotation();
		var initializer = doInContext(this, NodeFlagsYieldContext|NodeFlagsAwaitContext|NodeFlagsDisallowInContext, false, fn_parseInitializer);
		parseSemicolonAfterPropertyName(name, typeNode, initializer);
		var result = finishNode(factory.NewPropertyDeclaration(modifiers, name, postfixToken, typeNode, initializer), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseSemicolonAfterPropertyName(name:Node, typeNode:TypeNode, initializer:Expression):Void {
		if (token == KindAtToken && !hasPrecedingLineBreak()) {
			parseErrorAtCurrentToken(Diagnostics.Decorators_must_precede_the_name_and_all_keywords_of_property_declarations);
			return;
		}
		if (token == KindOpenParenToken) {
			parseErrorAtCurrentToken(Diagnostics.Cannot_start_a_function_call_in_a_type_annotation);
			nextToken();
			return;
		}
		if (typeNode != null && !canParseSemicolon()) {
			if (initializer != null) {
				parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindSemicolonToken));
			} else {
				parseErrorAtCurrentToken(Diagnostics.Expected_for_property_initializer);
			}
			return;
		}
		if (tryParseSemicolon()) {
			return;
		}
		if (initializer != null) {
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindSemicolonToken));
			return;
		}
		parseErrorForMissingSemicolonAfter(name);
	}

	function parseErrorForMissingSemicolonAfter(node:Node):Void {
		// Tagged template literals are sometimes used in places where only simple strings are allowed, i.e.:
		//   module `M1` {
		//   ^^^^^^^^^^^ This block is parsed as a template literal like module`M1`.
		if (node.Kind == KindTaggedTemplateExpression) {
			parseErrorAtRange(skipRangeTrivia(node.AsTaggedTemplateExpression().Template.Loc), Diagnostics.Module_declaration_names_may_only_use_or_quoted_strings);
			return;
		}
		// Otherwise, if this isn't a well-known keyword-like identifier, give the generic fallback message.
		var expressionText:String = "";
		if (node.Kind == KindIdentifier) {
			expressionText = node.Text();
		}
		if (expressionText == "") {
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindSemicolonToken));
			return;
		}
		var pos = Scanner.SkipTrivia(sourceText, node.Pos());
		// Some known keywords are likely signs of syntax being used improperly.
		switch (expressionText) {
		case "const" | "let" | "var":
			parseErrorAt(pos, node.End(), Diagnostics.Variable_declaration_not_allowed_at_this_location);
			return;
		case "declare":
			// If a declared node failed to parse, it would have emitted a diagnostic already.
			return;
		case "interface":
			parseErrorForInvalidName(Diagnostics.Interface_name_cannot_be_0, Diagnostics.Interface_must_be_given_a_name, KindOpenBraceToken);
			return;
		case "is":
			parseErrorAt(pos, scanner.TokenStart(), Diagnostics.A_type_predicate_is_only_allowed_in_return_type_position_for_functions_and_methods);
			return;
		case "module" | "namespace":
			parseErrorForInvalidName(Diagnostics.Namespace_name_cannot_be_0, Diagnostics.Namespace_must_be_given_a_name, KindOpenBraceToken);
			return;
		case "type":
			parseErrorForInvalidName(Diagnostics.Type_alias_name_cannot_be_0, Diagnostics.Type_alias_must_be_given_a_name, KindEqualsToken);
			return;
		default:
		}
		// The user alternatively might have misspelled or forgotten to add a space after a common keyword.
		var suggestion = Core.GetSpellingSuggestionForStrings(expressionText, viableKeywordSuggestions.iterator());
		if (suggestion == "") {
			suggestion = getSpaceSuggestion(expressionText);
		}
		if (suggestion != "") {
			parseErrorAt(pos, node.End(), Diagnostics.Unknown_keyword_or_identifier_Did_you_mean_0, suggestion);
			return;
		}
		// Unknown tokens are handled with their own errors in the scanner
		if (token == KindUnknown) {
			return;
		}
		// Otherwise, we know this some kind of unknown word, not just a missing expected semicolon.
		parseErrorAt(pos, node.End(), Diagnostics.Unexpected_keyword_or_identifier);
	}

	static function getSpaceSuggestion(expressionText:String):String {
		for (keyword in viableKeywordSuggestions) {
			if (expressionText.length > keyword.length + 2 && StringTools.startsWith(expressionText, keyword)) {
				return keyword + " " + expressionText.substring(keyword.length);
			}
		}
		return "";
	}

	function parseErrorForInvalidName(nameDiagnostic:Message, blankDiagnostic:Message, tokenIfBlankName:Kind):Void {
		if (token == tokenIfBlankName) {
			parseErrorAtCurrentToken(blankDiagnostic);
		} else {
			parseErrorAtCurrentToken(nameDiagnostic, scanner.TokenValue());
		}
	}

	function parseInterfaceDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		parseExpected(KindInterfaceKeyword);
		var name = parseIdentifier();
		var typeParameters = parseTypeParameters();
		var heritageClauses = parseHeritageClauses();
		var members = parseObjectTypeMembers();
		var result = finishNode(factory.NewInterfaceDeclaration(modifiers, name, typeParameters, heritageClauses, members), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseTypeAliasDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		parseExpected(KindTypeKeyword);
		if (hasPrecedingLineBreak()) {
			parseErrorAtCurrentToken(Diagnostics.Line_break_not_permitted_here);
		}
		var name = parseIdentifier();
		var typeParameters = parseTypeParameters();
		parseExpected(KindEqualsToken);
		var typeNode:TypeNode = null;
		if (token == KindIntrinsicKeyword && lookAhead(fn_nextIsNotDot)) {
			typeNode = parseKeywordTypeNode();
		} else {
			typeNode = parseType();
		}
		parseSemicolon();
		var result = finishNode(factory.NewTypeAliasDeclaration(modifiers, name, typeParameters, typeNode), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function nextIsNotDot():Bool {
		return nextToken() != KindDotToken;
	}

	// In an ambient declaration, the grammar only allows integer literals as initializers.
	// In a non-ambient declaration, the grammar allows uninitialized members only in a
	// ConstantEnumMemberSection, which starts at the beginning of an enum declaration
	// or any time an integer literal initializer is encountered.
	function parseEnumMember():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var name = parsePropertyName();
		var initializer = doInContext(this, NodeFlagsDisallowInContext, false, fn_parseInitializer);
		var result = finishNode(factory.NewEnumMember(name, initializer), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseEnumDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		parseExpected(KindEnumKeyword);
		var name = parseIdentifier();
		var members:NodeList = null;
		if (parseExpected(KindOpenBraceToken)) {
			var saveContextFlags = contextFlags;
			setContextFlags(NodeFlagsYieldContext|NodeFlagsAwaitContext, false);
			members = parseDelimitedList(PCEnumMembers, fn_parseEnumMember);
			contextFlags = saveContextFlags;
			parseExpected(KindCloseBraceToken);
		} else {
			members = createMissingList();
		}
		var result = finishNode(factory.NewEnumDeclaration(modifiers, name, members), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return result;
	}

	function parseModuleDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Statement {
		var keyword = KindModuleKeyword;
		if (token == KindGlobalKeyword) {
			// global augmentation
			return parseAmbientExternalModuleDeclaration(pos, jsdoc, modifiers);
		} else if (parseOptional(KindNamespaceKeyword)) {
			keyword = KindNamespaceKeyword;
		} else {
			parseExpected(KindModuleKeyword);
			if (token == KindStringLiteral) {
				return parseAmbientExternalModuleDeclaration(pos, jsdoc, modifiers);
			}
		}
		return parseModuleOrNamespaceDeclaration(pos, jsdoc, modifiers, false /*nested*/, keyword);
	}

	function parseAmbientExternalModuleDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var name:Node = null;
		var keyword = KindModuleKeyword;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		if (token == KindGlobalKeyword) {
			// parse 'global' as name of global scope augmentation
			name = parseIdentifier();
			keyword = KindGlobalKeyword;
		} else {
			// parse string literal
			name = parseLiteralExpression(true /*intern*/);
		}
		var body:Node = null;
		if (token == KindOpenBraceToken) {
			body = parseModuleBlock();
		} else {
			parseSemicolon();
		}
		var result = finishNode(factory.NewModuleDeclaration(modifiers, keyword, name, body), pos);
		this.withJSDoc(result, jsdoc);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return result;
	}

	function parseModuleBlock():Node {
		var pos = nodePos();
		var statements:NodeList = null;
		if (parseExpected(KindOpenBraceToken)) {
			statements = parseList(PCBlockStatements, fn_parseStatement);
			parseExpected(KindCloseBraceToken);
		} else {
			statements = createMissingList();
		}
		return finishNode(factory.NewModuleBlock(statements), pos);
	}

	function parseModuleOrNamespaceDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, nested:Bool, keyword:Kind):Node {
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var name:Node = null;
		if (nested) {
			name = parseIdentifierName();
		} else {
			name = parseIdentifier();
		}
		var body:Node = null;
		if (parseOptional(KindDotToken)) {
			var implicitExport = factory.NewModifier(KindExportKeyword);
			implicitExport.Loc = Core.NewTextRange(nodePos(), nodePos());
			implicitExport.Flags = NodeFlagsReparsed;
			var implicitModifiers = newModifierList(implicitExport.Loc, [implicitExport] /* PORT: arena — Go NewSlice1 */);
			body = parseModuleOrNamespaceDeclaration(nodePos(), 0 /*jsdoc*/, implicitModifiers, true /*nested*/, keyword);
		} else {
			body = parseModuleBlock();
		}
		var result = finishNode(factory.NewModuleDeclaration(modifiers, keyword, name, body), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return result;
	}

	function parseImportDeclarationOrImportEqualsDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Statement {
		parseExpected(KindImportKeyword);
		var afterImportPos = nodePos();
		// We don't parse the identifier here in await context, instead we will report a grammar error in the checker.
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var identifier:Node = null;
		if (isIdentifier()) {
			identifier = parseIdentifier();
		}
		var phaseModifier = KindUnknown;
		if (identifier != null && identifier.Text() == "type" &&
			(token != KindFromKeyword || isIdentifier() && lookAhead(fn_nextTokenIsFromKeywordOrEqualsToken)) &&
			(isIdentifier() || tokenAfterImportDefinitelyProducesImportDeclaration())) {
			phaseModifier = KindTypeKeyword;
			identifier = null;
			if (isIdentifier()) {
				identifier = parseIdentifier();
			}
		} else if (identifier != null && identifier.Text() == "defer") {
			var shouldParseAsDeferModifier:Bool = false;
			if (token == KindFromKeyword) {
				shouldParseAsDeferModifier = !lookAhead(fn_nextTokenIsTokenStringLiteral);
			} else {
				shouldParseAsDeferModifier = token != KindCommaToken && token != KindEqualsToken;
			}
			if (shouldParseAsDeferModifier) {
				phaseModifier = KindDeferKeyword;
				identifier = null;
				if (isIdentifier()) {
					identifier = parseIdentifier();
				}
			}
		}
		if (identifier != null && !tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration() && phaseModifier != KindDeferKeyword) {
			var importEquals = checkJSSyntax(parseImportEqualsDeclaration(pos, jsdoc, modifiers, identifier, phaseModifier == KindTypeKeyword));
			statementHasAwaitIdentifier = saveHasAwaitIdentifier; // Import= declaration is always parsed in an Await context, no need to reparse
			return importEquals;
		}
		var importClause = tryParseImportClause(identifier, afterImportPos, phaseModifier, false /*skipJSDocLeadingAsterisks*/);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier; // import clause is always parsed in an Await context
		var moduleSpecifier = parseModuleSpecifier();
		var attributes = tryParseImportAttributes();
		parseSemicolon();
		var result = finishNode(factory.NewImportDeclaration(modifiers, importClause, moduleSpecifier, attributes), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function nextTokenIsFromKeywordOrEqualsToken():Bool {
		nextToken();
		return token == KindFromKeyword || token == KindEqualsToken;
	}

	function tokenAfterImportDefinitelyProducesImportDeclaration():Bool {
		return token == KindAsteriskToken || token == KindOpenBraceToken;
	}

	function tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration():Bool {
		// In `import id ___`, the current token decides whether to produce
		// an ImportDeclaration or ImportEqualsDeclaration.
		return token == KindCommaToken || token == KindFromKeyword;
	}

	function parseImportEqualsDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, identifier:Node, isTypeOnly:Bool):Node {
		parseExpected(KindEqualsToken);
		var moduleReference = parseModuleReference();
		parseSemicolon();
		var result = finishNode(factory.NewImportEqualsDeclaration(modifiers, isTypeOnly, identifier, moduleReference), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseModuleReference():Node {
		if (token == KindRequireKeyword && lookAhead(fn_nextTokenIsOpenParen)) {
			return parseExternalModuleReference();
		}
		return parseEntityName(false /*allowReservedWords*/, null /*diagnosticMessage*/);
	}

	function parseExternalModuleReference():Node {
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var pos = nodePos();
		parseExpected(KindRequireKeyword);
		parseExpected(KindOpenParenToken);
		var expression = parseModuleSpecifier();
		parseExpected(KindCloseParenToken);
		var result = finishNode(factory.NewExternalModuleReference(expression), pos);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return result;
	}

	function parseModuleSpecifier():Expression {
		if (token == KindStringLiteral) {
			var result = parseLiteralExpression(true /*intern*/);
			return result;
		}
		// We allow arbitrary expressions here, even though the grammar only allows string
		// literals.  We check to ensure that it is only a string literal later in the grammar
		// check pass.
		return parseExpression();
	}

	function tryParseImportClause(identifier:Node, pos:Int, phaseModifier:Kind, skipJSDocLeadingAsterisks:Bool):Node {
		// ImportDeclaration:
		//  import ImportClause from ModuleSpecifier ;
		//  import ModuleSpecifier;
		if (identifier != null || token == KindAsteriskToken || token == KindOpenBraceToken) {
			var importClause = parseImportClause(identifier, pos, phaseModifier, skipJSDocLeadingAsterisks);
			parseExpected(KindFromKeyword);
			return importClause;
		}
		return null;
	}

	function parseImportClause(identifier:Node, pos:Int, phaseModifier:Kind, skipJSDocLeadingAsterisks:Bool):Node {
		// ImportClause:
		//  ImportedDefaultBinding
		//  NameSpaceImport
		//  NamedImports
		//  ImportedDefaultBinding, NameSpaceImport
		//  ImportedDefaultBinding, NamedImports
		// If there was no default import or if there is comma token after default import
		// parse namespace or named imports
		var namedBindings:Node = null;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		if (identifier == null || parseOptional(KindCommaToken)) {
			if (skipJSDocLeadingAsterisks) {
				scanner.SetSkipJSDocLeadingAsterisks(true);
			}
			if (token == KindAsteriskToken) {
				namedBindings = parseNamespaceImport();
			} else {
				namedBindings = parseNamedImports();
			}
			if (skipJSDocLeadingAsterisks) {
				scanner.SetSkipJSDocLeadingAsterisks(false);
			}
		}
		var result = finishNode(factory.NewImportClause(phaseModifier, identifier, namedBindings), pos);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return result;
	}

	function parseNamespaceImport():Node {
		// NameSpaceImport:
		//  * as ImportedBinding
		var pos = nodePos();
		parseExpected(KindAsteriskToken);
		parseExpected(KindAsKeyword);
		var name = parseIdentifier();
		return finishNode(factory.NewNamespaceImport(name), pos);
	}

	function parseNamedImports():Node {
		var pos = nodePos();
		// NamedImports:
		//  { }
		//  { ImportsList }
		//  { ImportsList, }
		var imports = parseBracketedList(PCImportOrExportSpecifiers, fn_parseImportSpecifier, KindOpenBraceToken, KindCloseBraceToken);
		return finishNode(factory.NewNamedImports(imports), pos);
	}

	function parseImportSpecifier():Node {
		var pos = nodePos();
		var name = parseImportOrExportSpecifier(KindImportSpecifier);
		var isTypeOnly = specifierIsTypeOnly;
		var propertyName = specifierPropertyName;
		var identifierName:Node = null;
		if (name.Kind == KindIdentifier) {
			identifierName = name;
		} else {
			parseErrorAtRange(skipRangeTrivia(name.Loc), Diagnostics.Identifier_expected);
			identifierName = newIdentifier("");
			finishNode(identifierName, name.Pos());
		}
		var result = checkJSSyntax(finishNode(factory.NewImportSpecifier(isTypeOnly, propertyName, identifierName), pos));
		return result;
	}

	// PORT: Go returns (isTypeOnly, propertyName, name); here name is returned and the other two
	// results are the out fields specifierIsTypeOnly / specifierPropertyName (no object per call).
	var specifierIsTypeOnly:Bool = false;
	var specifierPropertyName:Node = null;

	function parseImportOrExportSpecifier(kind:Kind):Node {
		// ImportSpecifier:
		//   BindingIdentifier
		//   ModuleExportName as BindingIdentifier
		// ExportSpecifier:
		//   ModuleExportName
		//   ModuleExportName as ModuleExportName
		// let checkIdentifierIsKeyword = isKeyword(token()) && !isIdentifier();
		// let checkIdentifierStart = scanner.getTokenStart();
		// let checkIdentifierEnd = scanner.getTokenEnd();
		var isTypeOnly = false;
		var propertyName:Node = null;
		var name:Node = null;
		var canParseAsKeyword = true;
		var disallowKeywords = kind == KindImportSpecifier;
		var nameOk:Bool = false;
		name = parseModuleExportName(disallowKeywords);
		nameOk = moduleExportNameOk;
		if (name.Kind == KindIdentifier && name.Text() == "type") {
			// If the first token of an import specifier is 'type', there are a lot of possibilities,
			// especially if we see 'as' afterwards:
			//
			// import { type } from "mod";          - isTypeOnly: false,   name: type
			// import { type as } from "mod";       - isTypeOnly: true,    name: as
			// import { type as as } from "mod";    - isTypeOnly: false,   name: as,    propertyName: type
			// import { type as as as } from "mod"; - isTypeOnly: true,    name: as,    propertyName: as
			if (token == KindAsKeyword) {
				// { type as ...? }
				var firstAs = parseIdentifierName();
				if (token == KindAsKeyword) {
					// { type as as ...? }
					var secondAs = parseIdentifierName();
					if (canParseModuleExportName()) {
						// { type as as something }
						// { type as as "something" }
						isTypeOnly = true;
						propertyName = firstAs;
						name = parseModuleExportName(disallowKeywords);
						nameOk = moduleExportNameOk;
						canParseAsKeyword = false;
					} else {
						// { type as as }
						propertyName = name;
						name = secondAs;
						canParseAsKeyword = false;
					}
				} else if (canParseModuleExportName()) {
					// { type as something }
					// { type as "something" }
					propertyName = name;
					canParseAsKeyword = false;
					name = parseModuleExportName(disallowKeywords);
					nameOk = moduleExportNameOk;
				} else {
					// { type as }
					isTypeOnly = true;
					name = firstAs;
				}
			} else if (canParseModuleExportName()) {
				// { type something ...? }
				// { type "something" ...? }
				isTypeOnly = true;
				name = parseModuleExportName(disallowKeywords);
				nameOk = moduleExportNameOk;
			}
		}
		if (canParseAsKeyword && token == KindAsKeyword) {
			propertyName = name;
			parseExpected(KindAsKeyword);
			name = parseModuleExportName(disallowKeywords);
			nameOk = moduleExportNameOk;
		}

		if (!nameOk) {
			parseErrorAtRange(skipRangeTrivia(name.Loc), Diagnostics.Identifier_expected);
		}

		specifierIsTypeOnly = isTypeOnly;
		specifierPropertyName = propertyName;
		return name;
	}

	function canParseModuleExportName():Bool {
		return tokenIsIdentifierOrKeyword(token) || token == KindStringLiteral;
	}

	// PORT: Go returns (node, nameOk); nameOk is the out field moduleExportNameOk.
	var moduleExportNameOk:Bool = false;

	function parseModuleExportName(disallowKeywords:Bool):Node {
		var nameOk = true;

		if (token == KindStringLiteral) {
			moduleExportNameOk = nameOk;
			return parseLiteralExpression(false /*intern*/);
		}
		if (disallowKeywords && Ast.IsKeyword(token) && !isIdentifier()) {
			nameOk = false;
		}
		final node = parseIdentifierName();
		moduleExportNameOk = nameOk;
		return node;
	}

	function tryParseImportAttributes():Node {
		if (token == KindWithKeyword || (token == KindAssertKeyword && !hasPrecedingLineBreak())) {
			if (token == KindAssertKeyword) {
				parseErrorAtCurrentToken(Diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert);
			}
			return parseImportAttributes(token, false /*skipKeyword*/);
		}
		return null;
	}

	function parseExportAssignment(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var saveContextFlags = contextFlags;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		setContextFlags(NodeFlagsAwaitContext, true);
		var isExportEquals = false;
		if (parseOptional(KindEqualsToken)) {
			isExportEquals = true;
		} else {
			parseExpected(KindDefaultKeyword);
		}
		var expression = parseAssignmentExpressionOrHigher();
		parseSemicolon();
		contextFlags = saveContextFlags;
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		var result = finishNode(factory.NewExportAssignment(modifiers, isExportEquals, null /*typeNode*/, expression), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseNamespaceExportDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		parseExpected(KindAsKeyword);
		parseExpected(KindNamespaceKeyword);
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var name = parseIdentifier();
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		parseSemicolon();
		// NamespaceExportDeclaration nodes cannot have decorators or modifiers, we attach them here so we can report them in the grammar checker
		var result = finishNode(factory.NewNamespaceExportDeclaration(modifiers, name), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseExportDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var saveContextFlags = contextFlags;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		setContextFlags(NodeFlagsAwaitContext, true);
		var exportClause:Node = null;
		var moduleSpecifier:Expression = null;
		var attributes:Node = null;
		var isTypeOnly = parseOptional(KindTypeKeyword);
		var namespaceExportPos = nodePos();
		if (parseOptional(KindAsteriskToken)) {
			if (parseOptional(KindAsKeyword)) {
				exportClause = parseNamespaceExport(namespaceExportPos);
			}
			parseExpected(KindFromKeyword);
			moduleSpecifier = parseModuleSpecifier();
		} else {
			exportClause = parseNamedExports();
			// It is not uncommon to accidentally omit the 'from' keyword. Additionally, in editing scenarios,
			// the 'from' keyword can be parsed as a named export when the export clause is unterminated (i.e. `export { from "moduleName";`)
			// If we don't have a 'from' keyword, see if we have a string literal such that ASI won't take effect.
			if (token == KindFromKeyword || (token == KindStringLiteral && !hasPrecedingLineBreak())) {
				parseExpected(KindFromKeyword);
				moduleSpecifier = parseModuleSpecifier();
			}
		}
		if (moduleSpecifier != null && (token == KindWithKeyword || token == KindAssertKeyword) && !hasPrecedingLineBreak()) {
			if (token == KindAssertKeyword) {
				parseErrorAtCurrentToken(Diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert);
			}
			attributes = parseImportAttributes(token, false /*skipKeyword*/);
		}
		parseSemicolon();
		contextFlags = saveContextFlags;
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		var result = finishNode(factory.NewExportDeclaration(modifiers, isTypeOnly, exportClause, moduleSpecifier, attributes), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseNamespaceExport(pos:Int):Node {
		var exportName = parseModuleExportName(false /*disallowKeywords*/);
		return finishNode(factory.NewNamespaceExport(exportName), pos);
	}

	function parseNamedExports():Node {
		var pos = nodePos();
		// NamedImports:
		//  { }
		//  { ImportsList }
		//  { ImportsList, }
		var exports = parseBracketedList(PCImportOrExportSpecifiers, fn_parseExportSpecifier, KindOpenBraceToken, KindCloseBraceToken);
		return finishNode(factory.NewNamedExports(exports), pos);
	}

	function parseExportSpecifier():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var name = parseImportOrExportSpecifier(KindExportSpecifier);
		var isTypeOnly = specifierIsTypeOnly;
		var propertyName = specifierPropertyName;
		var result = finishNode(factory.NewExportSpecifier(isTypeOnly, propertyName, name), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	// TYPES

	function parseType():TypeNode {
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsTypeExcludesFlags, false);
		var typeNode:TypeNode = null;
		if (isStartOfFunctionTypeOrConstructorType()) {
			typeNode = parseFunctionOrConstructorType();
		} else {
			var pos = nodePos();
			typeNode = parseUnionTypeOrHigher();
			if (!inDisallowConditionalTypesContext() && !hasPrecedingLineBreak() && parseOptional(KindExtendsKeyword)) {
				// The type following 'extends' is not permitted to be another conditional type
				var extendsType = doInContext(this, NodeFlagsDisallowConditionalTypesContext, true, fn_parseType);
				parseExpected(KindQuestionToken);
				var trueType = doInContext(this, NodeFlagsDisallowConditionalTypesContext, false, fn_parseType);
				parseExpected(KindColonToken);
				var falseType = doInContext(this, NodeFlagsDisallowConditionalTypesContext, false, fn_parseType);
				var conditionalType = factory.NewConditionalTypeNode(typeNode, extendsType, trueType, falseType);
				finishNode(conditionalType, pos);
				typeNode = conditionalType;
			}
		}
		contextFlags = saveContextFlags;
		return typeNode;
	}

	function parseUnionTypeOrHigher():TypeNode {
		return parseUnionOrIntersectionType(KindBarToken, fn_parseIntersectionTypeOrHigher);
	}

	function parseIntersectionTypeOrHigher():TypeNode {
		return parseUnionOrIntersectionType(KindAmpersandToken, fn_parseTypeOperatorOrHigher);
	}

	function parseUnionOrIntersectionType(operator_:Kind, parseConstituentType:(p:Parser) -> TypeNode):TypeNode {
		var pos = nodePos();
		var isUnionType = operator_ == KindBarToken;
		var hasLeadingOperator = parseOptional(operator_);
		var typeNode:TypeNode = null;
		if (hasLeadingOperator) {
			typeNode = parseFunctionOrConstructorTypeToError(isUnionType, parseConstituentType);
		} else {
			typeNode = parseConstituentType(this);
		}
		if (token == operator_ || hasLeadingOperator) {
			var types:Array<Node> = [typeNode];
			while (parseOptional(operator_)) {
				types = append(types, parseFunctionOrConstructorTypeToError(isUnionType, parseConstituentType));
			}
			typeNode = createUnionOrIntersectionTypeNode(operator_, newNodeList(Core.NewTextRange(pos, nodePos()), cloneNodes(types)));
			finishNode(typeNode, pos);
		}
		return typeNode;
	}

	function createUnionOrIntersectionTypeNode(operator_:Kind, types:NodeList):Node {
		switch (operator_) {
		case KindBarToken:
			return factory.NewUnionTypeNode(types);
		case KindAmpersandToken:
			return factory.NewIntersectionTypeNode(types);
		default:
			throw "Unhandled case in createUnionOrIntersectionType";
		}
	}

	function parseTypeOperatorOrHigher():TypeNode {
		var operator_ = token;
		switch (operator_) {
		case KindKeyOfKeyword | KindUniqueKeyword | KindReadonlyKeyword:
			return parseTypeOperator(operator_);
		case KindInferKeyword:
			return parseInferType();
		default:
		}
		return doInContext(this, NodeFlagsDisallowConditionalTypesContext, false, fn_parsePostfixTypeOrHigher);
	}

	function parseTypeOperator(operator_:Kind):Node {
		var pos = nodePos();
		parseExpected(operator_);
		return finishNode(factory.NewTypeOperatorNode(operator_, parseTypeOperatorOrHigher()), pos);
	}

	function parseInferType():Node {
		var pos = nodePos();
		parseExpected(KindInferKeyword);
		return finishNode(factory.NewInferTypeNode(parseTypeParameterOfInferType()), pos);
	}

	function parseTypeParameterOfInferType():Node {
		var pos = nodePos();
		var name = parseIdentifier();
		var constraint = tryParseConstraintOfInferType();
		return finishNode(factory.NewTypeParameterDeclaration(null /*modifiers*/, name, constraint, null /*expression*/, null /*defaultType*/), pos);
	}

	function tryParseConstraintOfInferType():Node {
		var state = mark();
		if (parseOptional(KindExtendsKeyword)) {
			var constraint = doInContext(this, NodeFlagsDisallowConditionalTypesContext, true, fn_parseType);
			if (inDisallowConditionalTypesContext() || token != KindQuestionToken) {
				return constraint;
			}
		}
		rewind(state);
		return null;
	}

	function parsePostfixTypeOrHigher():Node {
		var pos = nodePos();
		var typeNode = parseNonArrayType();
		while (!hasPrecedingLineBreak()) {
			switch (token) {
			case KindExclamationToken:
				nextToken();
				typeNode = finishNode(factory.NewJSDocNonNullableType(typeNode), pos);
			case KindQuestionToken:
				// If next token is start of a type we have a conditional type
				if (lookAhead(fn_nextIsStartOfType)) {
					return typeNode;
				}
				nextToken();
				typeNode = finishNode(factory.NewJSDocNullableType(typeNode), pos);
			case KindOpenBracketToken:
				parseExpected(KindOpenBracketToken);
				if (isStartOfType(false /*isStartOfParameter*/)) {
					var indexType = parseType();
					parseExpected(KindCloseBracketToken);
					typeNode = finishNode(factory.NewIndexedAccessTypeNode(typeNode, indexType), pos);
				} else {
					parseExpected(KindCloseBracketToken);
					typeNode = finishNode(factory.NewArrayTypeNode(typeNode), pos);
				}
			default:
				return typeNode;
			}
		}
		return typeNode;
	}

	function nextIsStartOfType():Bool {
		nextToken();
		return isStartOfType(false /*inStartOfParameter*/);
	}

	function parseNonArrayType():Node {
		switch (token) {
		case KindAnyKeyword | KindUnknownKeyword | KindStringKeyword | KindNumberKeyword | KindBigIntKeyword | KindSymbolKeyword | KindBooleanKeyword | KindUndefinedKeyword | KindNeverKeyword | KindObjectKeyword:
			var state = mark();
			var keywordTypeNode = parseKeywordTypeNode();
			// If these are followed by a dot then parse these out as a dotted type reference instead
			if (token != KindDotToken) {
				return keywordTypeNode;
			}
			rewind(state);
			return parseTypeReference();
		case KindAsteriskEqualsToken:
			// If there is '*=', treat it as * followed by postfix =
			scanner.ReScanAsteriskEqualsToken();
			// PORT: fallthrough
			return parseJSDocAllType();
		case KindAsteriskToken:
			return parseJSDocAllType();
		case KindQuestionQuestionToken:
			// If there is '??', treat it as prefix-'?' in JSDoc type.
			scanner.ReScanQuestionToken();
			// PORT: fallthrough
			return parseJSDocNullableType();
		case KindQuestionToken:
			return parseJSDocNullableType();
		case KindExclamationToken:
			return parseJSDocNonNullableType();
		case KindNoSubstitutionTemplateLiteral | KindStringLiteral | KindNumericLiteral | KindBigIntLiteral | KindTrueKeyword | KindFalseKeyword | KindNullKeyword:
			return parseLiteralTypeNode(false /*negative*/);
		case KindMinusToken:
			if (lookAhead(fn_nextTokenIsNumericOrBigIntLiteral)) {
				return parseLiteralTypeNode(true /*negative*/);
			}
			return parseTypeReference();
		case KindVoidKeyword:
			return parseKeywordTypeNode();
		case KindThisKeyword:
			var thisKeyword = parseThisTypeNode();
			if (token == KindIsKeyword && !hasPrecedingLineBreak()) {
				return parseThisTypePredicate(thisKeyword);
			}
			return thisKeyword;
		case KindTypeOfKeyword:
			if (lookAhead(fn_nextIsStartOfTypeOfImportType)) {
				return parseImportType();
			}
			return parseTypeQuery();
		case KindOpenBraceToken:
			if (lookAhead(fn_nextIsStartOfMappedType)) {
				return parseMappedType();
			}
			return parseTypeLiteral();
		case KindOpenBracketToken:
			return parseTupleType();
		case KindOpenParenToken:
			return parseParenthesizedType();
		case KindImportKeyword:
			return parseImportType();
		case KindAssertsKeyword:
			if (lookAhead(fn_nextTokenIsIdentifierOrKeywordOnSameLine)) {
				return parseAssertsTypePredicate();
			}
			return parseTypeReference();
		case KindTemplateHead:
			return parseTemplateType();
		default:
			return parseTypeReference();
		}
	}

	function parseKeywordTypeNode():Node {
		var pos = nodePos();
		var result = factory.NewKeywordTypeNode(token);
		nextToken();
		return finishNode(result, pos);
	}

	function parseThisTypeNode():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewThisTypeNode(), pos);
	}

	function parseThisTypePredicate(lhs:Node):Node {
		nextToken();
		return finishNode(factory.NewTypePredicateNode(null /*assertsModifier*/, lhs, parseType()), lhs.Pos());
	}

	function parseJSDocAllType():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewJSDocAllType(), pos);
	}

	function parseJSDocNonNullableType():TypeNode {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewJSDocNonNullableType(parseTypeOperatorOrHigher()), pos);
	}

	function parseJSDocNullableType():Node {
		var pos = nodePos();
		// skip the ?
		nextToken();
		return finishNode(factory.NewJSDocNullableType(parseTypeOperatorOrHigher()), pos);
	}

	function parseJSDocType():TypeNode {
		scanner.SetSkipJSDocLeadingAsterisks(true);
		var pos = nodePos();

		var hasDotDotDot = parseOptional(KindDotDotDotToken);
		var t = parseTypeOrTypePredicate();
		scanner.SetSkipJSDocLeadingAsterisks(false);
		if (hasDotDotDot) {
			t = finishNode(factory.NewJSDocVariadicType(t), pos);
		}
		if (token == KindEqualsToken) {
			nextToken();
			return finishNode(factory.NewJSDocOptionalType(t), pos);
		}
		return t;
	}

	function parseLiteralTypeNode(negative:Bool):Node {
		var pos = nodePos();
		if (negative) {
			nextToken();
		}
		var expression:Expression = null;
		if (token == KindTrueKeyword || token == KindFalseKeyword || token == KindNullKeyword) {
			expression = parseKeywordExpression();
		} else {
			expression = parseLiteralExpression(false /*intern*/);
		}
		if (negative) {
			expression = finishNode(factory.NewPrefixUnaryExpression(KindMinusToken, expression), pos);
		}
		return finishNode(factory.NewLiteralTypeNode(expression), pos);
	}

	function parseTypeReference():Node {
		var pos = nodePos();
		return finishNode(factory.NewTypeReferenceNode(parseEntityNameOfTypeReference(), parseTypeArgumentsOfTypeReference()), pos);
	}

	function parseEntityNameOfTypeReference():Node {
		return parseEntityName(true /*allowReservedWords*/, Diagnostics.Type_expected);
	}

	function parseEntityName(allowReservedWords:Bool, diagnosticMessage:Message):Node {
		var pos = nodePos();
		var entity:Node = null;
		if (allowReservedWords) {
			entity = parseIdentifierNameWithDiagnostic(diagnosticMessage);
		} else {
			entity = parseIdentifierWithDiagnostic(diagnosticMessage, null);
		}
		while (parseOptional(KindDotToken)) {
			if (token == KindLessThanToken) {
				// The entity is part of a JSDoc-style generic. We will use the gap between `typeName` and
				// `typeArguments` to report it as a grammar error in the checker.
				break;
			}
			entity = finishNode(factory.NewQualifiedName(entity, parseRightSideOfDot(allowReservedWords, false /*allowPrivateIdentifiers*/, true /*allowUnicodeEscapeSequenceInIdentifierName*/)), pos);
		}
		return entity;
	}

	function parseRightSideOfDot(allowIdentifierNames:Bool, allowPrivateIdentifiers:Bool, allowUnicodeEscapeSequenceInIdentifierName:Bool):Node {
		// Technically a keyword is valid here as all identifiers and keywords are identifier names.
		// However, often we'll encounter this in error situations when the identifier or keyword
		// is actually starting another valid construct.
		//
		// So, we check for the following specific case:
		//
		//      name.
		//      identifierOrKeyword identifierNameOrKeyword
		//
		// Note: the newlines are important here.  For example, if that above code
		// were rewritten into:
		//
		//      name.identifierOrKeyword
		//      identifierNameOrKeyword
		//
		// Then we would consider it valid.  That's because ASI would take effect and
		// the code would be implicitly: "name.identifierOrKeyword; identifierNameOrKeyword".
		// In the first case though, ASI will not take effect because there is not a
		// line terminator after the identifier or keyword.
		if (hasPrecedingLineBreak() && tokenIsIdentifierOrKeyword(token) && lookAhead(fn_nextTokenIsIdentifierOrKeywordOnSameLine)) {
			// Report that we need an identifier.  However, report it right after the dot,
			// and not on the next token.  This is because the next token might actually
			// be an identifier and the error would be quite confusing.
			parseErrorAt(nodePos(), nodePos(), Diagnostics.Identifier_expected);
			return createMissingIdentifier();
		}
		if (token == KindPrivateIdentifier) {
			var node = parsePrivateIdentifier();
			if (allowPrivateIdentifiers) {
				return node;
			}
			parseErrorAt(nodePos(), nodePos(), Diagnostics.Identifier_expected);
			return createMissingIdentifier();
		}
		if (allowIdentifierNames) {
			if (allowUnicodeEscapeSequenceInIdentifierName) {
				return parseIdentifierName();
			}
			return parseIdentifierNameErrorOnUnicodeEscapeSequence();
		}
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var id = parseIdentifier();
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return id;
	}

	function newIdentifier(text:String):Node {
		identifierCount++;
		var id = factory.NewIdentifier(text);
		if (text == "await") {
			statementHasAwaitIdentifier = true;
		}
		return id;
	}

	function createMissingIdentifier():Node {
		return finishNode(newIdentifier(""), nodePos());
	}

	function parsePrivateIdentifier():Node {
		var pos = nodePos();
		var text = scanner.TokenValue();
		nextToken();
		return finishNode(factory.NewPrivateIdentifier(internIdentifier(text)), pos);
	}

	function reScanLessThanToken():Kind {
		token = scanner.ReScanLessThanToken();
		return token;
	}

	function reScanGreaterThanToken():Kind {
		token = scanner.ReScanGreaterThanToken();
		return token;
	}

	function reScanSlashToken():Kind {
		token = scanner.ReScanSlashToken();
		return token;
	}

	function reScanTemplateToken(isTaggedTemplate:Bool):Kind {
		token = scanner.ReScanTemplateToken(isTaggedTemplate);
		return token;
	}

	function parseTypeArgumentsOfTypeReference():NodeList {
		if (!hasPrecedingLineBreak() && reScanLessThanToken() == KindLessThanToken) {
			return parseTypeArguments();
		}
		return null;
	}

	function parseTypeArguments():NodeList {
		if (token == KindLessThanToken) {
			return parseBracketedList(PCTypeArguments, fn_parseType, KindLessThanToken, KindGreaterThanToken);
		}
		return null;
	}

	function nextIsStartOfTypeOfImportType():Bool {
		nextToken();
		return token == KindImportKeyword;
	}

	function parseImportType():Node {
		sourceFlags |= NodeFlagsPossiblyContainsDynamicImport;
		var pos = nodePos();
		var isTypeOf = parseOptional(KindTypeOfKeyword);
		parseExpected(KindImportKeyword);
		parseExpected(KindOpenParenToken);
		var typeNode = parseType();
		var attributes:Node = null;
		if (parseOptional(KindCommaToken)) {
			var openBracePosition = scanner.TokenStart();
			parseExpected(KindOpenBraceToken);
			var currentToken = token;
			if (currentToken == KindWithKeyword || currentToken == KindAssertKeyword) {
				if (currentToken == KindAssertKeyword) {
					parseErrorAtCurrentToken(Diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert);
				}
				nextToken();
			} else {
				parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindWithKeyword));
			}
			parseExpected(KindColonToken);
			attributes = parseImportAttributes(currentToken, true /*skipKeyword*/);
			parseOptional(KindCommaToken);
			if (!parseExpected(KindCloseBraceToken)) {
				if (Core.len(diagnostics) != 0) {
					var lastDiagnostic = diagnostics[Core.len(diagnostics)-1];
					if (lastDiagnostic.Code() == Diagnostics.X_0_expected.Code()) {
						var related = Ast.NewDiagnostic(null, Core.NewTextRange(openBracePosition, openBracePosition), Diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, "{", "}");
						lastDiagnostic.AddRelatedInfo(related);
					}
				}
			}
		}
		parseExpected(KindCloseParenToken);
		var qualifier:Node = null;
		if (parseOptional(KindDotToken)) {
			qualifier = parseEntityNameOfTypeReference();
		}
		var typeArguments = parseTypeArgumentsOfTypeReference();
		return finishNode(factory.NewImportTypeNode(isTypeOf, typeNode, attributes, qualifier, typeArguments), pos);
	}

	function parseImportAttribute():Node {
		var pos = nodePos();
		var name:Node = null;
		if (tokenIsIdentifierOrKeyword(token)) {
			name = parseIdentifierName();
		} else if (token == KindStringLiteral) {
			name = parseLiteralExpression(false /*intern*/);
		}
		if (name != null) {
			parseExpected(KindColonToken);
		} else {
			parseErrorAtCurrentToken(Diagnostics.Identifier_or_string_literal_expected);
		}
		var value = parseAssignmentExpressionOrHigher();
		return finishNode(factory.NewImportAttribute(name, value), pos);
	}

	function parseImportAttributes(token:Kind, skipKeyword:Bool):Node {
		var pos = nodePos();
		if (!skipKeyword) {
			parseExpected(token);
		}
		var elements:NodeList = null;
		var multiLine:Bool = false;
		var openBracePosition = scanner.TokenStart();
		if (parseExpected(KindOpenBraceToken)) {
			multiLine = hasPrecedingLineBreak();
			elements = parseDelimitedList(PCImportAttributes, fn_parseImportAttribute);
			if (!parseExpected(KindCloseBraceToken)) {
				if (Core.len(diagnostics) != 0) {
					var lastDiagnostic = diagnostics[Core.len(diagnostics)-1];
					if (lastDiagnostic.Code() == Diagnostics.X_0_expected.Code()) {
						var related = Ast.NewDiagnostic(null, Core.NewTextRange(openBracePosition, openBracePosition), Diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, "{", "}");
						lastDiagnostic.AddRelatedInfo(related);
					}
				}
			}
		} else {
			elements = parseEmptyNodeList();
		}
		return finishNode(factory.NewImportAttributes(token, elements, multiLine), pos);
	}

	function parseTypeQuery():Node {
		var pos = nodePos();
		parseExpected(KindTypeOfKeyword);
		var entityName = parseEntityName(true /*allowReservedWords*/, null);
		// Make sure we perform ASI to prevent parsing the next line's type arguments as part of an instantiation expression
		var typeArguments:NodeList = null;
		if (!hasPrecedingLineBreak()) {
			typeArguments = parseTypeArguments();
		}
		return finishNode(factory.NewTypeQueryNode(entityName, typeArguments), pos);
	}

	function nextIsStartOfMappedType():Bool {
		nextToken();
		if (token == KindPlusToken || token == KindMinusToken) {
			return nextToken() == KindReadonlyKeyword;
		}
		if (token == KindReadonlyKeyword) {
			nextToken();
		}
		return token == KindOpenBracketToken && nextTokenIsIdentifier() && nextToken() == KindInKeyword;
	}

	function parseMappedType():Node {
		var pos = nodePos();
		parseExpected(KindOpenBraceToken);
		var readonlyToken:Node = null; // ReadonlyKeyword | PlusToken | MinusToken
		if (token == KindReadonlyKeyword || token == KindPlusToken || token == KindMinusToken) {
			readonlyToken = parseTokenNode();
			if (readonlyToken.Kind != KindReadonlyKeyword) {
				parseExpected(KindReadonlyKeyword);
			}
		}
		parseExpected(KindOpenBracketToken);
		var typeParameter = parseMappedTypeParameter();
		var nameType:TypeNode = null;
		if (parseOptional(KindAsKeyword)) {
			nameType = parseType();
		}
		parseExpected(KindCloseBracketToken);
		var questionToken:Node = null; // QuestionToken | PlusToken | MinusToken
		if (token == KindQuestionToken || token == KindPlusToken || token == KindMinusToken) {
			questionToken = parseTokenNode();
			if (questionToken.Kind != KindQuestionToken) {
				parseExpected(KindQuestionToken);
			}
		}
		var typeNode = parseTypeAnnotation();
		parseSemicolon();
		var members = parseList(PCTypeMembers, fn_parseTypeMember);
		parseExpected(KindCloseBraceToken);
		return finishNode(factory.NewMappedTypeNode(readonlyToken, typeParameter, nameType, questionToken, typeNode, members), pos);
	}

	function parseMappedTypeParameter():Node {
		var pos = nodePos();
		var name = parseIdentifierName();
		parseExpected(KindInKeyword);
		var typeNode = parseType();
		return finishNode(factory.NewTypeParameterDeclaration(null /*modifiers*/, name, typeNode, null /*expression*/, null /*defaultType*/), pos);
	}

	function parseTypeMember():Node {
		if (token == KindOpenParenToken || token == KindLessThanToken) {
			return parseSignatureMember(KindCallSignature);
		}
		if (token == KindNewKeyword && lookAhead(fn_nextTokenIsOpenParenOrLessThan)) {
			return parseSignatureMember(KindConstructSignature);
		}
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiers();
		if (parseContextualModifier(KindGetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindGetAccessor, ParseFlagsType);
		}
		if (parseContextualModifier(KindSetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindSetAccessor, ParseFlagsType);
		}
		if (isIndexSignature()) {
			return parseIndexSignatureDeclaration(pos, jsdoc, modifiers);
		}
		return parsePropertyOrMethodSignature(pos, jsdoc, modifiers);
	}

	function nextTokenIsOpenParenOrLessThan():Bool {
		nextToken();
		return token == KindOpenParenToken || token == KindLessThanToken;
	}

	function parseSignatureMember(kind:Kind):Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		if (kind == KindConstructSignature) {
			parseExpected(KindNewKeyword);
		}
		var typeParameters = parseTypeParameters();
		var parameters = parseParameters(ParseFlagsType);
		var typeNode = parseReturnType(KindColonToken /*isType*/, true);
		parseTypeMemberSemicolon();
		var result:Node = null;
		if (kind == KindCallSignature) {
			result = factory.NewCallSignatureDeclaration(typeParameters, parameters, typeNode);
		} else {
			result = factory.NewConstructSignatureDeclaration(typeParameters, parameters, typeNode);
		}
		finishNode(result, pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseTypeParameters():NodeList {
		if (token == KindLessThanToken) {
			return parseBracketedList(PCTypeParameters, fn_parseTypeParameter, KindLessThanToken, KindGreaterThanToken);
		}
		return null;
	}

	function parseTypeParameter():Node {
		var pos = nodePos();
		var modifiers = parseModifiersEx(false /*allowDecorators*/, true /*permitConstAsModifier*/, false /*stopOnStartOfClassStaticBlock*/);
		var name = parseIdentifier();
		var constraint:TypeNode = null;
		var expression:Expression = null;
		if (parseOptional(KindExtendsKeyword)) {
			// It's not uncommon for people to write improper constraints to a generic.  If the
			// user writes a constraint that is an expression and not an actual type, then parse
			// it out as an expression (so we can recover well), but report that a type is needed
			// instead.
			if (isStartOfType(false /*inStartOfParameter*/) || !isStartOfExpression()) {
				constraint = parseType();
			} else {
				// It was not a type, and it looked like an expression.  Parse out an expression
				// here so we recover well.  Note: it is important that we call parseUnaryExpression
				// and not parseExpression here.  If the user has:
				//
				//      <T extends "">
				//
				// We do *not* want to consume the `>` as we're consuming the expression for "".
				expression = parseUnaryExpressionOrHigher();
			}
		}
		var defaultType:TypeNode = null;
		if (parseOptional(KindEqualsToken)) {
			defaultType = parseType();
		}
		var result = factory.NewTypeParameterDeclaration(modifiers, name, constraint, expression, defaultType);
		return finishNode(result, pos);
	}

	function parseParameters(flags:ParseFlags):NodeList {
		// FormalParameters [Yield,Await]: (modified)
		//      [empty]
		//      FormalParameterList[?Yield,Await]
		//
		// FormalParameter[Yield,Await]: (modified)
		//      BindingElement[?Yield,Await]
		//
		// BindingElement [Yield,Await]: (modified)
		//      SingleNameBinding[?Yield,?Await]
		//      BindingPattern[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
		//
		// SingleNameBinding [Yield,Await]:
		//      BindingIdentifier[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
		if (parseExpected(KindOpenParenToken)) {
			var parameters = parseParametersWorker(flags, true /*allowAmbiguity*/);
			parseExpected(KindCloseParenToken);
			return parameters;
		}
		return createMissingList();
	}

	function parseParametersWorker(flags:ParseFlags, allowAmbiguity:Bool):NodeList {
		// FormalParameters [Yield,Await]: (modified)
		//      [empty]
		//      FormalParameterList[?Yield,Await]
		//
		// FormalParameter[Yield,Await]: (modified)
		//      BindingElement[?Yield,Await]
		//
		// BindingElement [Yield,Await]: (modified)
		//      SingleNameBinding[?Yield,?Await]
		//      BindingPattern[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
		//
		// SingleNameBinding [Yield,Await]:
		//      BindingIdentifier[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
		var inAwaitContext = contextFlags&NodeFlagsAwaitContext != 0;
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsYieldContext, flags&ParseFlagsYield != 0);
		setContextFlags(NodeFlagsAwaitContext, flags&ParseFlagsAwait != 0);
		var parameters = parseDelimitedList(PCParameters, function(p:Parser):Node {
			var parameter = p.parseParameterEx(inAwaitContext, allowAmbiguity);
			if (parameter != null && flags & ParseFlagsType == 0) {
				p.checkJSSyntax(parameter);
			}
			return parameter;
		});
		contextFlags = saveContextFlags;
		return parameters;
	}

	function parseParameter():Node {
		return parseParameterEx(false /*inOuterAwaitContext*/, true /*allowAmbiguity*/);
	}

	function parseParameterEx(inOuterAwaitContext:Bool, allowAmbiguity:Bool):Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		// FormalParameter [Yield,Await]:
		//      BindingElement[?Yield,?Await]
		// Decorators are parsed in the outer [Await] context, the rest of the parameter is parsed in the function's [Await] context.
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsAwaitContext, inOuterAwaitContext);
		var modifiers = parseModifiersEx(true /*allowDecorators*/, false /*permitConstAsModifier*/, false /*stopOnStartOfClassStaticBlock*/);
		contextFlags = saveContextFlags;
		if (token == KindThisKeyword) {
			var result = factory.NewParameterDeclaration(
				modifiers,
				null, /*dotDotDotToken*/
				createIdentifier(true /*isIdentifier*/),
				null, /*questionToken*/
				parseTypeAnnotation(),
				null /*initializer*/
			);
			if (modifiers != null) {
				parseErrorAtRange(modifiers.Nodes[0].Loc, Diagnostics.Neither_decorators_nor_modifiers_may_be_applied_to_this_parameters);
			}
			this.withJSDoc(finishNode(result, pos), jsdoc);
			return result;
		}
		var dotDotDotToken = parseOptionalToken(KindDotDotDotToken);
		if (!allowAmbiguity && !isParameterNameStart()) {
			return null;
		}
		var result = factory.NewParameterDeclaration(
			modifiers,
			dotDotDotToken,
			parseNameOfParameter(modifiers),
			parseOptionalToken(KindQuestionToken),
			parseTypeAnnotation(),
			parseInitializer()
		);
		this.withJSDoc(finishNode(result, pos), jsdoc);
		return result;
	}

	function isParameterNameStart():Bool {
		// Be permissive about await and yield by calling isBindingIdentifier instead of isIdentifier; disallowing
		// them during a speculative parse leads to many more follow-on errors than allowing the function to parse then later
		// complaining about the use of the keywords.
		return isBindingIdentifier() || token == KindOpenBracketToken || token == KindOpenBraceToken;
	}

	function parseNameOfParameter(modifiers:ModifierList):Node {
		// FormalParameter [Yield,Await]:
		//      BindingElement[?Yield,?Await]
		var name = parseIdentifierOrPatternWithDiagnostic(Diagnostics.Private_identifiers_cannot_be_used_as_parameters);
		if (name.Loc.Len() == 0 && modifiers == null && Ast.IsModifierKind(token)) {
			// in cases like
			// 'use strict'
			// function foo(static)
			// isParameter('static') == true, because of isModifier('static')
			// however 'static' is not a legal identifier in a strict mode.
			// so result of this function will be Parameter (flags = 0, name = missing, type = undefined, initializer = undefined)
			// and current token will not change => parsing of the enclosing parameter list will last till the end of time (or OOM)
			// to avoid this we'll advance cursor to the next token.
			nextToken();
		}
		return name;
	}

	function parseReturnType(returnToken:Kind, isType:Bool):TypeNode {
		if (shouldParseReturnType(returnToken, isType)) {
			return doInContext(this, NodeFlagsDisallowConditionalTypesContext, false, fn_parseTypeOrTypePredicate);
		}
		return null;
	}

	function shouldParseReturnType(returnToken:Kind, isType:Bool):Bool {
		if (returnToken == KindEqualsGreaterThanToken) {
			parseExpected(returnToken);
			return true;
		} else if (parseOptional(KindColonToken)) {
			return true;
		} else if (isType && token == KindEqualsGreaterThanToken) {
			// This is easy to get backward, especially in type contexts, so parse the type anyway
			parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindColonToken));
			nextToken();
			return true;
		}
		return false;
	}

	function parseTypeOrTypePredicate():TypeNode {
		if (isIdentifier()) {
			var state = mark();
			var pos = nodePos();
			var id = parseIdentifier();
			if (token == KindIsKeyword && !hasPrecedingLineBreak()) {
				nextToken();
				return finishNode(factory.NewTypePredicateNode(null /*assertsModifier*/, id, parseType()), pos);
			}
			rewind(state);
		}
		return parseType();
	}

	function parseTypeMemberSemicolon():Void {
		// We allow type members to be separated by commas or (possibly ASI) semicolons.
		// First check if it was a comma.  If so, we're done with the member.
		if (parseOptional(KindCommaToken)) {
			return;
		}
		// Didn't have a comma.  We must have a (possible ASI) semicolon.
		parseSemicolon();
	}

	function parseAccessorDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList, kind:Kind, flags:ParseFlags):Node {
		var name = parsePropertyName();
		var typeParameters = parseTypeParameters();
		var parameters = parseParameters(ParseFlagsNone);
		var returnType = parseReturnType(KindColonToken, false /*isType*/);
		var body = parseFunctionBlockOrSemicolon(flags, null /*diagnosticMessage*/);
		var result:Node = null;
		// Keep track of `typeParameters` (for both) and `type` (for setters) if they were parsed those indicate grammar errors
		if (kind == KindGetAccessor) {
			result = factory.NewGetAccessorDeclaration(modifiers, name, typeParameters, parameters, returnType, null /*fullSignature*/, body);
		} else {
			result = factory.NewSetAccessorDeclaration(modifiers, name, typeParameters, parameters, returnType, null /*fullSignature*/, body);
		}
		this.withJSDoc(finishNode(result, pos), jsdoc);
		if (flags&ParseFlagsType == 0) {
			checkJSSyntax(result);
		}
		return result;
	}

	function parsePropertyName():Node {
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var prop = parsePropertyNameWorker(true /*allowComputedPropertyNames*/);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return prop;
	}

	function parsePropertyNameWorker(allowComputedPropertyNames:Bool):Node {
		if (token == KindStringLiteral || token == KindNumericLiteral || token == KindBigIntLiteral) {
			var literal = parseLiteralExpression(true /*intern*/);
			return literal;
		}
		if (allowComputedPropertyNames && token == KindOpenBracketToken) {
			return parseComputedPropertyName();
		}
		if (token == KindPrivateIdentifier) {
			return parsePrivateIdentifier();
		}
		return parseIdentifierName();
	}

	function parseComputedPropertyName():Node {
		// PropertyName [Yield]:
		//      LiteralPropertyName
		//      ComputedPropertyName[?Yield]
		var pos = nodePos();
		parseExpected(KindOpenBracketToken);
		// We parse any expression (including a comma expression). But the grammar
		// says that only an assignment expression is allowed, so the grammar checker
		// will error if it sees a comma expression.
		var expression = parseExpressionAllowIn();
		parseExpected(KindCloseBracketToken);
		return finishNode(factory.NewComputedPropertyName(expression), pos);
	}

	function parseFunctionBlockOrSemicolon(flags:ParseFlags, diagnosticMessage:Message):Node {
		if (token != KindOpenBraceToken) {
			if (flags&ParseFlagsType != 0) {
				parseTypeMemberSemicolon();
				return null;
			}
			if (canParseSemicolon()) {
				parseSemicolon();
				return null;
			}
		}
		return parseFunctionBlock(flags, diagnosticMessage);
	}

	function parseFunctionBlock(flags:ParseFlags, diagnosticMessage:Message):Node {
		var saveContextFlags = contextFlags;
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		setContextFlags(NodeFlagsYieldContext, flags&ParseFlagsYield != 0);
		setContextFlags(NodeFlagsAwaitContext, flags&ParseFlagsAwait != 0);
		// We may be in a [Decorator] context when parsing a function expression or
		// arrow function. The body of the function is not in [Decorator] context.
		setContextFlags(NodeFlagsDecoratorContext, false);
		var block = parseBlock(flags&ParseFlagsIgnoreMissingOpenBrace != 0, diagnosticMessage);
		contextFlags = saveContextFlags;
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return block;
	}

	function isIndexSignature():Bool {
		return token == KindOpenBracketToken && lookAhead(fn_nextIsUnambiguouslyIndexSignature);
	}

	function nextIsUnambiguouslyIndexSignature():Bool {
		// The only allowed sequence is:
		//
		//   [id:
		//
		// However, for error recovery, we also check the following cases:
		//
		//   [...
		//   [id,
		//   [id?,
		//   [id?:
		//   [id?]
		//   [public id
		//   [private id
		//   [protected id
		//   []
		//
		nextToken();
		if (token == KindDotDotDotToken || token == KindCloseBracketToken) {
			return true;
		}
		if (Ast.IsModifierKind(token)) {
			nextToken();
			if (isIdentifier()) {
				return true;
			}
		} else if (!isIdentifier()) {
			return false;
		} else {
			// Skip the identifier
			nextToken();
		}
		// A colon signifies a well formed indexer
		// A comma should be a badly formed indexer because comma expressions are not allowed
		// in computed properties.
		if (token == KindColonToken || token == KindCommaToken) {
			return true;
		}
		// Question mark could be an indexer with an optional property,
		// or it could be a conditional expression in a computed property.
		if (token != KindQuestionToken) {
			return false;
		}
		// If any of the following tokens are after the question mark, it cannot
		// be a conditional expression, so treat it as an indexer.
		nextToken();
		return token == KindColonToken || token == KindCommaToken || token == KindCloseBracketToken;
	}

	function parseIndexSignatureDeclaration(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var parameters = parseBracketedList(PCParameters, fn_parseParameter, KindOpenBracketToken, KindCloseBracketToken);
		var typeNode = parseTypeAnnotation();
		parseTypeMemberSemicolon();
		var result = finishNode(factory.NewIndexSignatureDeclaration(modifiers, parameters, typeNode), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parsePropertyOrMethodSignature(pos:Int, jsdoc:JsdocScannerInfo, modifiers:ModifierList):Node {
		var name = parsePropertyName();
		var questionToken = parseOptionalToken(KindQuestionToken);
		var result:Node = null;
		if (token == KindOpenParenToken || token == KindLessThanToken) {
			// Method signatures don't exist in expression contexts.  So they have neither
			// [Yield] nor [Await]
			var typeParameters = parseTypeParameters();
			var parameters = parseParameters(ParseFlagsType);
			var returnType = parseReturnType(KindColonToken /*isType*/, true);
			result = factory.NewMethodSignatureDeclaration(modifiers, name, questionToken, typeParameters, parameters, returnType);
		} else {
			var typeNode = parseTypeAnnotation();
			// Although type literal properties cannot not have initializers, we attempt
			// to parse an initializer so we can report in the checker that an interface
			// property or type literal property cannot have an initializer.
			var initializer:Expression = null;
			if (token == KindEqualsToken) {
				initializer = parseInitializer();
			}
			result = factory.NewPropertySignatureDeclaration(modifiers, name, questionToken, typeNode, initializer);
		}
		parseTypeMemberSemicolon();
		this.withJSDoc(finishNode(result, pos), jsdoc);
		return result;
	}

	function parseTypeLiteral():Node {
		var pos = nodePos();
		var result = finishNode(factory.NewTypeLiteralNode(parseObjectTypeMembers()), pos);
		return result;
	}

	function parseObjectTypeMembers():NodeList {
		if (parseExpected(KindOpenBraceToken)) {
			var members = parseList(PCTypeMembers, fn_parseTypeMember);
			parseExpected(KindCloseBraceToken);
			return members;
		}
		return createMissingList();
	}

	function parseTupleType():Node {
		var pos = nodePos();
		return finishNode(factory.NewTupleTypeNode(parseBracketedList(PCTupleElementTypes, fn_parseTupleElementNameOrTupleElementType, KindOpenBracketToken, KindCloseBracketToken)), pos);
	}

	function parseTupleElementNameOrTupleElementType():Node {
		if (lookAhead(fn_scanStartOfNamedTupleElement)) {
			var pos = nodePos();
			var jsdoc = jsdocScannerInfo();
			var dotDotDotToken = parseOptionalToken(KindDotDotDotToken);
			var name = parseIdentifierName();
			var questionToken = parseOptionalToken(KindQuestionToken);
			parseExpected(KindColonToken);
			var typeNode = parseTupleElementType();
			var result = finishNode(factory.NewNamedTupleMember(dotDotDotToken, name, questionToken, typeNode), pos);
			this.withJSDoc(result, jsdoc);
			return result;
		}
		return parseTupleElementType();
	}

	function scanStartOfNamedTupleElement():Bool {
		if (token == KindDotDotDotToken) {
			return tokenIsIdentifierOrKeyword(nextToken()) && nextTokenIsColonOrQuestionColon();
		}
		return tokenIsIdentifierOrKeyword(token) && nextTokenIsColonOrQuestionColon();
	}

	function nextTokenIsColonOrQuestionColon():Bool {
		return nextToken() == KindColonToken || token == KindQuestionToken && nextToken() == KindColonToken;
	}

	function parseTupleElementType():TypeNode {
		var pos = nodePos();
		if (parseOptional(KindDotDotDotToken)) {
			return finishNode(factory.NewRestTypeNode(parseType()), pos);
		}
		var typeNode = parseType();
		if (Ast.IsJSDocNullableType(typeNode) && typeNode.Pos() == typeNode.Type().Pos()) {
			var node = factory.NewOptionalTypeNode(typeNode.Type());
			node.Flags = typeNode.Flags;
			node.Loc = typeNode.Loc;
			typeNode.Type().Parent = node;
			return node;
		}
		return typeNode;
	}

	function parseParenthesizedType():Node {
		var pos = nodePos();
		parseExpected(KindOpenParenToken);
		var typeNode = parseType();
		parseExpected(KindCloseParenToken);
		return finishNode(factory.NewParenthesizedTypeNode(typeNode), pos);
	}

	function parseAssertsTypePredicate():TypeNode {
		var pos = nodePos();
		var assertsModifier = parseExpectedToken(KindAssertsKeyword);
		var parameterName:Node = null;
		if (token == KindThisKeyword) {
			parameterName = parseThisTypeNode();
		} else {
			parameterName = parseIdentifier();
		}
		var typeNode:TypeNode = null;
		if (parseOptional(KindIsKeyword)) {
			typeNode = parseType();
		}
		return finishNode(factory.NewTypePredicateNode(assertsModifier, parameterName, typeNode), pos);
	}

	function parseTemplateType():Node {
		var pos = nodePos();
		return finishNode(factory.NewTemplateLiteralTypeNode(parseTemplateHead(false /*isTaggedTemplate*/), parseTemplateTypeSpans()), pos);
	}

	function parseTemplateHead(isTaggedTemplate:Bool):Node {
		if (!isTaggedTemplate && scanner.TokenFlags()&TokenFlagsIsInvalid != 0) {
			reScanTemplateToken(false /*isTaggedTemplate*/);
		}
		var pos = nodePos();
		var result = factory.NewTemplateHead(scanner.TokenValue(), getTemplateLiteralRawText(2 /*endLength*/), scanner.TokenFlags());
		nextToken();
		return finishNode(result, pos);
	}

	function getTemplateLiteralRawText(endLength:Int):String {
		var tokenText = scanner.TokenText();
		if (scanner.TokenFlags()&TokenFlagsUnterminated != 0) {
			endLength = 0;
		}
		return tokenText.substring(1, tokenText.length - endLength);
	}

	function parseTemplateTypeSpans():NodeList {
		var pos = nodePos();
		var list:Array<Node> = null;
		while (true) {
			var span = parseTemplateTypeSpan();
			list = append(list, span);
			if (span.AsTemplateLiteralTypeSpan().Literal.Kind != KindTemplateMiddle) {
				break;
			}
		}
		return newNodeList(Core.NewTextRange(pos, nodePos()), list);
	}

	function parseTemplateTypeSpan():Node {
		var pos = nodePos();
		return finishNode(factory.NewTemplateLiteralTypeSpan(parseType(), parseLiteralOfTemplateSpan(false /*isTaggedTemplate*/)), pos);
	}

	function parseLiteralOfTemplateSpan(isTaggedTemplate:Bool):Node {
		if (token == KindCloseBraceToken) {
			reScanTemplateToken(isTaggedTemplate);
			return parseTemplateMiddleOrTail();
		}
		parseErrorAtCurrentToken(Diagnostics.X_0_expected, Scanner.TokenToString(KindCloseBraceToken));
		return finishNode(factory.NewTemplateTail("", "", TokenFlagsNone), nodePos());
	}

	function parseTemplateMiddleOrTail():Node {
		var pos = nodePos();
		var result:Node = null;
		if (token == KindTemplateMiddle) {
			result = factory.NewTemplateMiddle(scanner.TokenValue(), getTemplateLiteralRawText(2 /*endLength*/), scanner.TokenFlags());
		} else {
			result = factory.NewTemplateTail(scanner.TokenValue(), getTemplateLiteralRawText(1 /*endLength*/), scanner.TokenFlags());
		}
		nextToken();
		return finishNode(result, pos);
	}

	function parseFunctionOrConstructorTypeToError(isInUnionType:Bool, parseConstituentType:(p:Parser) -> TypeNode):TypeNode {
		// the function type and constructor type shorthand notation
		// are not allowed directly in unions and intersections, but we'll
		// try to parse them gracefully and issue a helpful message.
		if (isStartOfFunctionTypeOrConstructorType()) {
			var typeNode = parseFunctionOrConstructorType();
			var diagnostic:Message = null;
			if (typeNode.Kind == KindFunctionType) {
				diagnostic = isInUnionType ? Diagnostics.Function_type_notation_must_be_parenthesized_when_used_in_a_union_type : Diagnostics.Function_type_notation_must_be_parenthesized_when_used_in_an_intersection_type;
			} else {
				diagnostic = isInUnionType ? Diagnostics.Constructor_type_notation_must_be_parenthesized_when_used_in_a_union_type : Diagnostics.Constructor_type_notation_must_be_parenthesized_when_used_in_an_intersection_type;
			}
			parseErrorAtRange(typeNode.Loc, diagnostic);
			return typeNode;
		}
		return parseConstituentType(this);
	}

	function isStartOfFunctionTypeOrConstructorType():Bool {
		return token == KindLessThanToken ||
			token == KindOpenParenToken && lookAhead(fn_nextIsUnambiguouslyStartOfFunctionType) ||
			token == KindNewKeyword ||
			token == KindAbstractKeyword && lookAhead(fn_nextTokenIsNewKeyword);
	}

	function parseFunctionOrConstructorType():TypeNode {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiersForConstructorType();
		var isConstructorType = parseOptional(KindNewKeyword);
		Debug.Assert(modifiers == null || isConstructorType, "Per isStartOfFunctionOrConstructorType, a function type cannot have modifiers.");
		var typeParameters = parseTypeParameters();
		var parameters = parseParameters(ParseFlagsType);
		var returnType = parseReturnType(KindEqualsGreaterThanToken, false /*isType*/);
		var result:TypeNode = null;
		if (isConstructorType) {
			result = factory.NewConstructorTypeNode(modifiers, typeParameters, parameters, returnType);
		} else {
			result = factory.NewFunctionTypeNode(typeParameters, parameters, returnType);
		}
		finishNode(result, pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseModifiersForConstructorType():ModifierList {
		if (token == KindAbstractKeyword) {
			var pos = nodePos();
			var modifier = factory.NewModifier(token);
			nextToken();
			finishNode(modifier, pos);
			return newModifierList(modifier.Loc, [modifier] /* PORT: arena — Go NewSlice1 */);
		}
		return null;
	}

	function nextTokenIsNewKeyword():Bool {
		return nextToken() == KindNewKeyword;
	}

	function nextIsUnambiguouslyStartOfFunctionType():Bool {
		nextToken();
		if (token == KindCloseParenToken || token == KindDotDotDotToken) {
			// ( )
			// ( ...
			return true;
		}
		if (skipParameterStart()) {
			// We successfully skipped modifiers (if any) and an identifier or binding pattern,
			// now see if we have something that indicates a parameter declaration
			if (token == KindColonToken || token == KindCommaToken || token == KindQuestionToken || token == KindEqualsToken) {
				// ( xxx :
				// ( xxx ,
				// ( xxx ?
				// ( xxx =
				return true;
			}
			if (token == KindCloseParenToken && nextToken() == KindEqualsGreaterThanToken) {
				// ( xxx ) =>
				return true;
			}
		}
		return false;
	}

	function skipParameterStart():Bool {
		if (Ast.IsModifierKind(token)) {
			// Skip modifiers
			parseModifiers();
		}
		parseOptional(KindDotDotDotToken);
		if (isIdentifier() || token == KindThisKeyword) {
			nextToken();
			return true;
		}
		if (token == KindOpenBracketToken || token == KindOpenBraceToken) {
			// Return true if we can parse an array or object binding pattern with no errors
			var previousErrorCount = Core.len(diagnostics);
			parseIdentifierOrPattern();
			return previousErrorCount == Core.len(diagnostics);
		}
		return false;
	}

	function parseModifiers():ModifierList {
		return parseModifiersEx(false, false, false);
	}

	function parseModifiersEx(allowDecorators:Bool, permitConstAsModifier:Bool, stopOnStartOfClassStaticBlock:Bool):ModifierList {
		var hasLeadingModifier:Bool = false;
		var hasTrailingDecorator:Bool = false;
		var hasTrailingModifier:Bool = false;
		var hasStaticModifier:Bool = false;
		// Decorators should be contiguous in a list of modifiers but can potentially appear in two places (i.e., `[...leadingDecorators, ...leadingModifiers, ...trailingDecorators, ...trailingModifiers]`).
		// The leading modifiers *should* only contain `export` and `default` when trailingDecorators are present, but we'll handle errors for any other leading modifiers in the checker.
		// It is illegal to have both leadingDecorators and trailingDecorators, but we will report that as a grammar check in the checker.
		// parse leading decorators
		var pos = nodePos();
		var list:Array<Node> = null; // PORT: arena — Go uses a stack temp + arena Clone; allocated on first append
		while (true) {
			if (allowDecorators && token == KindAtToken && !hasTrailingModifier) {
				var decorator = parseDecorator();
				list = append(list, decorator);
				if (hasLeadingModifier) {
					hasTrailingDecorator = true;
				}
			} else {
				var modifier = tryParseModifier(hasStaticModifier, permitConstAsModifier, stopOnStartOfClassStaticBlock);
				if (modifier == null) {
					break;
				}
				if (modifier.Kind == KindStaticKeyword) {
					hasStaticModifier = true;
				}
				list = append(list, modifier);
				if (hasTrailingDecorator) {
					hasTrailingModifier = true;
				} else {
					hasLeadingModifier = true;
				}
			}
		}
		if (Core.len(list) != 0) {
			return newModifierList(Core.NewTextRange(pos, nodePos()), cloneNodes(list));
		}
		return null;
	}

	function parseDecorator():Node {
		var pos = nodePos();
		parseExpected(KindAtToken);
		var expression = doInContext(this, NodeFlagsDecoratorContext, true, fn_parseDecoratorExpression);
		return finishNode(factory.NewDecorator(expression), pos);
	}

	function parseDecoratorExpression():Expression {
		if (inAwaitContext() && token == KindAwaitKeyword) {
			// `@await` is disallowed in an [Await] context, but can cause parsing to go off the rails
			// This simply parses the missing identifier and moves on.
			var pos = nodePos();
			var awaitExpression = parseIdentifierWithDiagnostic(Diagnostics.Expression_expected, null);
			nextToken();
			var memberExpression = parseMemberExpressionRest(pos, awaitExpression /*allowOptionalChain*/, true);
			return parseCallExpressionRest(pos, memberExpression);
		}
		return parseLeftHandSideExpressionOrHigher();
	}

	function tryParseModifier(hasSeenStaticModifier:Bool, permitConstAsModifier:Bool, stopOnStartOfClassStaticBlock:Bool):Node {
		var pos = nodePos();
		var kind = token;
		if (token == KindConstKeyword && permitConstAsModifier) {
			// We need to ensure that any subsequent modifiers appear on the same line
			// so that when 'const' is a standalone declaration, we don't issue an error.
			if (!lookAhead(fn_nextTokenIsOnSameLineAndCanFollowModifier)) {
				return null;
			} else {
				nextToken();
			}
		} else if (stopOnStartOfClassStaticBlock && token == KindStaticKeyword && lookAhead(fn_nextTokenIsOpenBrace)) {
			return null;
		} else if (hasSeenStaticModifier && token == KindStaticKeyword) {
			return null;
		} else {
			if (!parseAnyContextualModifier()) {
				return null;
			}
		}
		return finishNode(factory.NewModifier(kind), pos);
	}

	function parseContextualModifier(t:Kind):Bool {
		var state = mark();
		if (token == t && nextTokenCanFollowModifier()) {
			return true;
		}
		rewind(state);
		return false;
	}

	function parseAnyContextualModifier():Bool {
		var state = mark();
		if (Ast.IsModifierKind(token) && nextTokenCanFollowModifier()) {
			return true;
		}
		rewind(state);
		return false;
	}

	function nextTokenCanFollowModifier():Bool {
		switch (token) {
		case KindConstKeyword:
			// 'const' is only a modifier if followed by 'enum'.
			return nextToken() == KindEnumKeyword;
		case KindExportKeyword:
			nextToken();
			if (token == KindDefaultKeyword) {
				return lookAhead(fn_nextTokenCanFollowDefaultKeyword);
			}
			if (token == KindTypeKeyword) {
				return lookAhead(fn_nextTokenCanFollowExportModifier);
			}
			return canFollowExportModifier();
		case KindDefaultKeyword:
			return nextTokenCanFollowDefaultKeyword();
		case KindStaticKeyword:
			nextToken();
			return canFollowModifier();
		case KindGetKeyword | KindSetKeyword:
			nextToken();
			return canFollowGetOrSetKeyword();
		default:
			return nextTokenIsOnSameLineAndCanFollowModifier();
		}
	}

	function nextTokenCanFollowDefaultKeyword():Bool {
		switch (nextToken()) {
		case KindClassKeyword | KindFunctionKeyword | KindInterfaceKeyword | KindAtToken:
			return true;
		case KindAbstractKeyword:
			return lookAhead(fn_nextTokenIsClassKeywordOnSameLine);
		case KindAsyncKeyword:
			return lookAhead(fn_nextTokenIsFunctionKeywordOnSameLine);
		default:
		}
		return false;
	}

	function nextTokenIsIdentifierOrKeyword():Bool {
		return tokenIsIdentifierOrKeyword(nextToken());
	}

	function nextTokenIsIdentifierOrKeywordOrGreaterThan():Bool {
		return tokenIsIdentifierOrKeywordOrGreaterThan(nextToken());
	}

	function nextTokenIsIdentifierOrKeywordOnSameLine():Bool {
		return nextTokenIsIdentifierOrKeyword() && !hasPrecedingLineBreak();
	}

	function nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine():Bool {
		return (nextTokenIsIdentifierOrKeyword() || token == KindNumericLiteral || token == KindBigIntLiteral || token == KindStringLiteral) && !hasPrecedingLineBreak();
	}

	function nextTokenIsClassKeywordOnSameLine():Bool {
		return nextToken() == KindClassKeyword && !hasPrecedingLineBreak();
	}

	function nextTokenIsFunctionKeywordOnSameLine():Bool {
		return nextToken() == KindFunctionKeyword && !hasPrecedingLineBreak();
	}

	function nextTokenCanFollowExportModifier():Bool {
		nextToken();
		return canFollowExportModifier();
	}

	function canFollowExportModifier():Bool {
		return token == KindAtToken || token != KindAsteriskToken && token != KindAsKeyword && token != KindOpenBraceToken && canFollowModifier();
	}

	function canFollowModifier():Bool {
		return token == KindOpenBracketToken || token == KindOpenBraceToken || token == KindAsteriskToken || token == KindDotDotDotToken || isLiteralPropertyName();
	}

	function canFollowGetOrSetKeyword():Bool {
		return token == KindOpenBracketToken || isLiteralPropertyName();
	}

	function nextTokenIsOnSameLineAndCanFollowModifier():Bool {
		nextToken();
		if (hasPrecedingLineBreak()) {
			return false;
		}
		return canFollowModifier();
	}

	function nextTokenIsOpenBrace():Bool {
		return nextToken() == KindOpenBraceToken;
	}

	function parseExpression():Expression {
		// Expression[in]:
		//      AssignmentExpression[in]
		//      Expression[in] , AssignmentExpression[in]

		// clear the decorator context when parsing Expression, as it should be unambiguous when parsing a decorator
		var saveContextFlags = contextFlags;
		contextFlags &= ~(NodeFlagsDecoratorContext);
		var pos = nodePos();
		var expr = parseAssignmentExpressionOrHigher();
		while (true) {
			var operatorToken = parseOptionalToken(KindCommaToken);
			if (operatorToken == null) {
				break;
			}
			expr = makeBinaryExpression(expr, operatorToken, parseAssignmentExpressionOrHigher(), pos);
		}
		contextFlags = saveContextFlags;
		return expr;
	}

	function parseExpressionAllowIn():Expression {
		return doInContext(this, NodeFlagsDisallowInContext, false, fn_parseExpression);
	}

	function parseAssignmentExpressionOrHigher():Expression {
		return parseAssignmentExpressionOrHigherWorker(true /*allowReturnTypeInArrowFunction*/);
	}

	function parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction:Bool):Expression {
		//  AssignmentExpression[in,yield]:
		//      1) ConditionalExpression[?in,?yield]
		//      2) LeftHandSideExpression = AssignmentExpression[?in,?yield]
		//      3) LeftHandSideExpression AssignmentOperator AssignmentExpression[?in,?yield]
		//      4) ArrowFunctionExpression[?in,?yield]
		//      5) AsyncArrowFunctionExpression[in,yield,await]
		//      6) [+Yield] YieldExpression[?In]
		//
		// Note: for ease of implementation we treat productions '2' and '3' as the same thing.
		// (i.e. they're both BinaryExpressions with an assignment operator in it).
		// First, do the simple check if we have a YieldExpression (production '6').
		if (isYieldExpression()) {
			return parseYieldExpression();
		}
		// Then, check if we have an arrow function (production '4' and '5') that starts with a parenthesized
		// parameter list or is an async arrow function.
		// AsyncArrowFunctionExpression:
		//      1) async[no LineTerminator here]AsyncArrowBindingIdentifier[?Yield][no LineTerminator here]=>AsyncConciseBody[?In]
		//      2) CoverCallExpressionAndAsyncArrowHead[?Yield, ?Await][no LineTerminator here]=>AsyncConciseBody[?In]
		// Production (1) of AsyncArrowFunctionExpression is parsed in "tryParseAsyncSimpleArrowFunctionExpression".
		// And production (2) is parsed in "tryParseParenthesizedArrowFunctionExpression".
		//
		// If we do successfully parse arrow-function, we must *not* recurse for productions 1, 2 or 3. An ArrowFunction is
		// not a LeftHandSideExpression, nor does it start a ConditionalExpression.  So we are done
		// with AssignmentExpression if we see one.
		var arrowExpression = tryParseParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction);
		if (arrowExpression != null) {
			return arrowExpression;
		}
		arrowExpression = tryParseAsyncSimpleArrowFunctionExpression(allowReturnTypeInArrowFunction);
		if (arrowExpression != null) {
			return arrowExpression;
		}
		// arrowExpression2 := p.tryParseAsyncSimpleArrowFunctionExpression(allowReturnTypeInArrowFunction)
		// if arrowExpression2 != nil {
		// 	return arrowExpression2
		// }
		// Now try to see if we're in production '1', '2' or '3'.  A conditional expression can
		// start with a LogicalOrExpression, while the assignment productions can only start with
		// LeftHandSideExpressions.
		//
		// So, first, we try to just parse out a BinaryExpression.  If we get something that is a
		// LeftHandSide or higher, then we can try to parse out the assignment expression part.
		// Otherwise, we try to parse out the conditional expression bit.  We want to allow any
		// binary expression here, so we pass in the 'lowest' precedence here so that it matches
		// and consumes anything.
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var expr = parseBinaryExpressionOrHigher(OperatorPrecedenceLowest);
		// To avoid a look-ahead, we did not handle the case of an arrow function with a single un-parenthesized
		// parameter ('x => ...') above. We handle it here by checking if the parsed expression was a single
		// identifier and the current token is an arrow.
		if (expr.Kind == KindIdentifier && token == KindEqualsGreaterThanToken) {
			return parseSimpleArrowFunctionExpression(pos, expr, allowReturnTypeInArrowFunction, jsdoc, null /*asyncModifier*/);
		}
		// Now see if we might be in cases '2' or '3'.
		// If the expression was a LHS expression, and we have an assignment operator, then
		// we're in '2' or '3'. Consume the assignment and return.
		//
		// Note: we call reScanGreaterToken so that we get an appropriately merged token
		// for cases like `> > =` becoming `>>=`
		if (Ast.IsLeftHandSideExpression(expr) && Ast.IsAssignmentOperator(reScanGreaterThanToken())) {
			return makeBinaryExpression(expr, parseTokenNode(), parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction), pos);
		}
		// It wasn't an assignment or a lambda.  This is a conditional expression:
		return parseConditionalExpressionRest(expr, pos, allowReturnTypeInArrowFunction);
	}

	function isYieldExpression():Bool {
		if (token == KindYieldKeyword) {
			// If we have a 'yield' keyword, and this is a context where yield expressions are
			// allowed, then definitely parse out a yield expression.
			if (inYieldContext()) {
				return true;
			}

			// We're in a context where 'yield expr' is not allowed.  However, if we can
			// definitely tell that the user was trying to parse a 'yield expr' and not
			// just a normal expr that start with a 'yield' identifier, then parse out
			// a 'yield expr'.  We can then report an error later that they are only
			// allowed in generator expressions.
			//
			// for example, if we see 'yield(foo)', then we'll have to treat that as an
			// invocation expression of something called 'yield'.  However, if we have
			// 'yield foo' then that is not legal as a normal expression, so we can
			// definitely recognize this as a yield expression.
			//
			// for now we just check if the next token is an identifier.  More heuristics
			// can be added here later as necessary.  We just need to make sure that we
			// don't accidentally consume something legal.
			return lookAhead(fn_nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine);
		}
		return false;
	}

	function parseYieldExpression():Node {
		var pos = nodePos();
		// YieldExpression[In] :
		//      yield
		//      yield [no LineTerminator here] [Lexical goal InputElementRegExp]AssignmentExpression[?In, Yield]
		//      yield [no LineTerminator here] * [Lexical goal InputElementRegExp]AssignmentExpression[?In, Yield]
		nextToken();
		var result:Node = null;
		if (!hasPrecedingLineBreak() && (token == KindAsteriskToken || isStartOfExpression())) {
			result = factory.NewYieldExpression(parseOptionalToken(KindAsteriskToken), parseAssignmentExpressionOrHigher());
		} else {
			// if the next token is not on the same line as yield.  or we don't have an '*' or
			// the start of an expression, then this is just a simple "yield" expression.
			result = factory.NewYieldExpression(null /*asteriskToken*/, null /*expression*/);
		}
		return finishNode(result, pos);
	}

	function isParenthesizedArrowFunctionExpression():Tristate {
		if (token == KindOpenParenToken || token == KindLessThanToken || token == KindAsyncKeyword) {
			var state = mark();
			var result = nextIsParenthesizedArrowFunctionExpression();
			rewind(state);
			return result;
		}
		if (token == KindEqualsGreaterThanToken) {
			// ERROR RECOVERY TWEAK:
			// If we see a standalone => try to parse it as an arrow function expression as that's
			// likely what the user intended to write.
			return TSTrue;
		}
		// Definitely not a parenthesized arrow function.
		return TSFalse;
	}

	function nextIsParenthesizedArrowFunctionExpression():Tristate {
		if (token == KindAsyncKeyword) {
			nextToken();
			if (hasPrecedingLineBreak()) {
				return TSFalse;
			}
			if (token != KindOpenParenToken && token != KindLessThanToken) {
				return TSFalse;
			}
		}
		var first = token;
		var second = nextToken();
		if (first == KindOpenParenToken) {
			if (second == KindCloseParenToken) {
				// Simple cases: "() =>", "(): ", and "() {".
				// This is an arrow function with no parameters.
				// The last one is not actually an arrow function,
				// but this is probably what the user intended.
				var third = nextToken();
				switch (third) {
				case KindEqualsGreaterThanToken | KindColonToken | KindOpenBraceToken:
					return TSTrue;
				default:
				}
				return TSFalse;
			}
			// If encounter "([" or "({", this could be the start of a binding pattern.
			// Examples:
			//      ([ x ]) => { }
			//      ({ x }) => { }
			//      ([ x ])
			//      ({ x })
			if (second == KindOpenBracketToken || second == KindOpenBraceToken) {
				return TSUnknown;
			}
			// Simple case: "(..."
			// This is an arrow function with a rest parameter.
			if (second == KindDotDotDotToken) {
				return TSTrue;
			}
			// Check for "(xxx yyy", where xxx is a modifier and yyy is an identifier. This
			// isn't actually allowed, but we want to treat it as a lambda so we can provide
			// a good error message.
			if (Ast.IsModifierKind(second) && second != KindAsyncKeyword && lookAhead(fn_nextTokenIsIdentifier)) {
				if (nextToken() == KindAsKeyword) {
					// https://github.com/microsoft/TypeScript/issues/44466
					return TSFalse;
				}
				return TSTrue;
			}
			// If we had "(" followed by something that's not an identifier,
			// then this definitely doesn't look like a lambda.  "this" is not
			// valid, but we want to parse it and then give a semantic error.
			if (!isIdentifier() && second != KindThisKeyword) {
				return TSFalse;
			}
			switch (nextToken()) {
			case KindColonToken:
				// If we have something like "(a:", then we must have a
				// type-annotated parameter in an arrow function expression.
				return TSTrue;
			case KindQuestionToken:
				nextToken();
				// If we have "(a?:" or "(a?," or "(a?=" or "(a?)" then it is definitely a lambda.
				if (token == KindColonToken || token == KindCommaToken || token == KindEqualsToken || token == KindCloseParenToken) {
					return TSTrue;
				}
				// Otherwise it is definitely not a lambda.
				return TSFalse;
			case KindCommaToken | KindEqualsToken | KindCloseParenToken:
				// If we have "(a," or "(a=" or "(a)" this *could* be an arrow function
				return TSUnknown;
			default:
			}
			// It is definitely not an arrow function
			return TSFalse;
		} else {
			Debug.Assert(first == KindLessThanToken);
			// If we have "<" not followed by an identifier,
			// then this definitely is not an arrow function.
			if (!isIdentifier() && token != KindConstKeyword) {
				return TSFalse;
			}
			// JSX overrides
			if (languageVariant == LanguageVariantJSX) {
				var isArrowFunctionInJsx = lookAhead(fl_isArrowFunctionInJsx);
				if (isArrowFunctionInJsx) {
					return TSTrue;
				}
				return TSFalse;
			}
			// This *could* be a parenthesized arrow function.
			return TSUnknown;
		}
	}

	// PORT: Go func literal without captures (isParenthesizedArrowFunctionExpressionWorker) → created once.
	static final fl_isArrowFunctionInJsx:(p:Parser) -> Bool = function(p:Parser):Bool {
		p.parseOptional(KindConstKeyword);
		var third = p.nextToken();
		if (third == KindExtendsKeyword) {
			var fourth = p.nextToken();
			switch (fourth) {
				case KindEqualsToken | KindGreaterThanToken | KindSlashToken:
					return false;
				default:
			}
			return true;
		} else if (third == KindCommaToken || third == KindEqualsToken) {
			return true;
		}
		return false;
	};

	function tryParseParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction:Bool):Node {
		var tristate = isParenthesizedArrowFunctionExpression();
		if (tristate == TSFalse) {
			// It's definitely not a parenthesized arrow function expression.
			return null;
		}
		// If we definitely have an arrow function, then we can just parse one, not requiring a
		// following => or { token. Otherwise, we *might* have an arrow function.  Try to parse
		// it out, but don't allow any ambiguity, and return 'undefined' if this could be an
		// expression instead.
		if (tristate == TSTrue) {
			return parseParenthesizedArrowFunctionExpression(true /*allowAmbiguity*/, true /*allowReturnTypeInArrowFunction*/);
		}
		var state = mark();
		var result = parsePossibleParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction);
		if (result == null) {
			rewind(state);
		}
		return result;
	}

	function parseParenthesizedArrowFunctionExpression(allowAmbiguity:Bool, allowReturnTypeInArrowFunction:Bool):Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiersForArrowFunction();
		var isAsync = modifierListHasAsync(modifiers);
		var signatureFlags = (isAsync ? ParseFlagsAwait : ParseFlagsNone);
		// Arrow functions are never generators.
		//
		// If we're speculatively parsing a signature for a parenthesized arrow function, then
		// we have to have a complete parameter list.  Otherwise we might see something like
		// a => (b => c)
		// And think that "(b =>" was actually a parenthesized arrow function with a missing
		// close paren.
		var typeParameters = parseTypeParameters();
		var parameters:NodeList = null;
		if (!parseExpected(KindOpenParenToken)) {
			if (!allowAmbiguity) {
				return null;
			}
			parameters = createMissingList();
		} else {
			if (!allowAmbiguity) {
				var maybeParameters = parseParametersWorker(signatureFlags, allowAmbiguity);
				if (maybeParameters == null) {
					return null;
				}
				parameters = maybeParameters;
			} else {
				parameters = parseParametersWorker(signatureFlags, allowAmbiguity);
			}
			if (!parseExpected(KindCloseParenToken) && !allowAmbiguity) {
				return null;
			}
		}
		var hasReturnColon = token == KindColonToken;
		var returnType = parseReturnType(KindColonToken /*isType*/, false);
		if (returnType != null && !allowAmbiguity && typeHasArrowFunctionBlockingParseError(returnType)) {
			return null;
		}
		// Parsing a signature isn't enough.
		// Parenthesized arrow signatures often look like other valid expressions.
		// For instance:
		//  - "(x = 10)" is an assignment expression parsed as a signature with a default parameter value.
		//  - "(x,y)" is a comma expression parsed as a signature with two parameters.
		//  - "a ? (b): c" will have "(b):" parsed as a signature with a return type annotation.
		//  - "a ? (b): function() {}" will too, since function() is a valid JSDoc function type.
		//  - "a ? (b): (function() {})" as well, but inside of a parenthesized type with an arbitrary amount of nesting.
		//
		// So we need just a bit of lookahead to ensure that it can only be a signature.
		var unwrappedType = returnType;
		while (unwrappedType != null && unwrappedType.Kind == KindParenthesizedType) {
			unwrappedType = unwrappedType.Type(); // Skip parens if need be
		}
		if (!allowAmbiguity && token != KindEqualsGreaterThanToken && token != KindOpenBraceToken) {
			// Returning undefined here will cause our caller to rewind to where we started from.
			return null;
		}
		// If we have an arrow, then try to parse the body. Even if not, try to parse if we
		// have an opening brace, just in case we're in an error state.
		var lastToken = token;
		var equalsGreaterThanToken = parseExpectedToken(KindEqualsGreaterThanToken);
		var body:Node = null;
		if (lastToken == KindEqualsGreaterThanToken || lastToken == KindOpenBraceToken) {
			body = parseArrowFunctionExpressionBody(isAsync, allowReturnTypeInArrowFunction);
		} else {
			body = parseIdentifier();
		}
		// Given:
		//     x ? y => ({ y }) : z => ({ z })
		// We try to parse the body of the first arrow function by looking at:
		//     ({ y }) : z => ({ z })
		// This is a valid arrow function with "z" as the return type.
		//
		// But, if we're in the true side of a conditional expression, this colon
		// terminates the expression, so we cannot allow a return type if we aren't
		// certain whether or not the preceding text was parsed as a parameter list.
		//
		// For example,
		//     a() ? (b: number, c?: string): void => d() : e
		// is determined by isParenthesizedArrowFunctionExpression to unambiguously
		// be an arrow expression, so we allow a return type.
		if (!allowReturnTypeInArrowFunction && hasReturnColon) {
			// However, if the arrow function we were able to parse is followed by another colon
			// as in:
			//     a ? (x): string => x : null
			// Then allow the arrow function, and treat the second colon as terminating
			// the conditional expression. It's okay to do this because this code would
			// be a syntax error in JavaScript (as the second colon shouldn't be there).
			if (token != KindColonToken) {
				return null;
			}
		}
		var result = finishNode(factory.NewArrowFunction(modifiers, typeParameters, parameters, returnType, null /*fullSignature*/, equalsGreaterThanToken, body), pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseModifiersForArrowFunction():ModifierList {
		if (token == KindAsyncKeyword) {
			var pos = nodePos();
			nextToken();
			var modifier = finishNode(factory.NewModifier(KindAsyncKeyword), pos);
			return newModifierList(modifier.Loc, [modifier] /* PORT: arena — Go NewSlice1 */);
		}
		return null;
	}

	// If true, we should abort parsing an error function.
	static function typeHasArrowFunctionBlockingParseError(node:TypeNode):Bool {
		switch (node.Kind) {
		case KindTypeReference:
			return Ast.NodeIsMissing(node.AsTypeReferenceNode().TypeName);
		case KindFunctionType | KindConstructorType:
			return isMissingNodeList(node.FunctionLikeData().Parameters) || typeHasArrowFunctionBlockingParseError(node.Type());
		case KindParenthesizedType:
			return typeHasArrowFunctionBlockingParseError(node.Type());
		default:
		}
		return false;
	}

	function parseArrowFunctionExpressionBody(isAsync:Bool, allowReturnTypeInArrowFunction:Bool):Node {
		if (token == KindOpenBraceToken) {
			return parseFunctionBlock((isAsync ? ParseFlagsAwait : ParseFlagsNone), null /*diagnosticMessage*/);
		}
		if (token != KindSemicolonToken && token != KindFunctionKeyword && token != KindClassKeyword && isStartOfStatement() && !isStartOfExpressionStatement()) {
			// Check if we got a plain statement (i.e. no expression-statements, no function/class expressions/declarations)
			//
			// Here we try to recover from a potential error situation in the case where the
			// user meant to supply a block. For example, if the user wrote:
			//
			//  a =>
			//      let v = 0;
			//  }
			//
			// they may be missing an open brace.  Check to see if that's the case so we can
			// try to recover better.  If we don't do this, then the next close curly we see may end
			// up preemptively closing the containing construct.
			//
			// Note: even when 'IgnoreMissingOpenBrace' is passed, parseBody will still error.
			return parseFunctionBlock(ParseFlagsIgnoreMissingOpenBrace|(isAsync ? ParseFlagsAwait : ParseFlagsNone), null /*diagnosticMessage*/);
		}
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsAwaitContext, isAsync);
		setContextFlags(NodeFlagsYieldContext, false);
		var node = parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction);
		contextFlags = saveContextFlags;
		return node;
	}

	function isStartOfExpressionStatement():Bool {
		// As per the grammar, none of '{' or 'function' or 'class' can start an expression statement.
		return token != KindOpenBraceToken && token != KindFunctionKeyword && token != KindClassKeyword && token != KindAtToken && isStartOfExpression();
	}

	function parsePossibleParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction:Bool):Node {
		var tokenPos = scanner.TokenStart();
		if (notParenthesizedArrow.Has(tokenPos)) {
			return null;
		}
		var result = parseParenthesizedArrowFunctionExpression(false /*allowAmbiguity*/, allowReturnTypeInArrowFunction);
		if (result == null) {
			notParenthesizedArrow.Add(tokenPos);
		}
		return result;
	}

	function tryParseAsyncSimpleArrowFunctionExpression(allowReturnTypeInArrowFunction:Bool):Node {
		// We do a check here so that we won't be doing unnecessarily call to "lookAhead"
		if (token == KindAsyncKeyword && lookAhead(fn_nextIsUnParenthesizedAsyncArrowFunction)) {
			var pos = nodePos();
			var jsdoc = jsdocScannerInfo();
			var asyncModifier = parseModifiersForArrowFunction();
			var expr = parseBinaryExpressionOrHigher(OperatorPrecedenceLowest);
			return parseSimpleArrowFunctionExpression(pos, expr, allowReturnTypeInArrowFunction, jsdoc, asyncModifier);
		}
		return null;
	}

	function nextIsUnParenthesizedAsyncArrowFunction():Bool {
		// AsyncArrowFunctionExpression:
		//      1) async[no LineTerminator here]AsyncArrowBindingIdentifier[?Yield][no LineTerminator here]=>AsyncConciseBody[?In]
		//      2) CoverCallExpressionAndAsyncArrowHead[?Yield, ?Await][no LineTerminator here]=>AsyncConciseBody[?In]
		if (token == KindAsyncKeyword) {
			nextToken();
			// If the "async" is followed by "=>" token then it is not a beginning of an async arrow-function
			// but instead a simple arrow-function which will be parsed inside "parseAssignmentExpressionOrHigher"
			if (hasPrecedingLineBreak() || token == KindEqualsGreaterThanToken) {
				return false;
			}
			// Check for un-parenthesized AsyncArrowFunction
			var expr = parseBinaryExpressionOrHigher(OperatorPrecedenceLowest);
			if (!hasPrecedingLineBreak() && expr.Kind == KindIdentifier && token == KindEqualsGreaterThanToken) {
				return true;
			}
		}
		return false;
	}

	function parseSimpleArrowFunctionExpression(pos:Int, identifier:Node, allowReturnTypeInArrowFunction:Bool, jsdoc:JsdocScannerInfo, asyncModifier:ModifierList):Node {
		Debug.Assert(token == KindEqualsGreaterThanToken, "parseSimpleArrowFunctionExpression should only have been called if we had a =>");
		var parameter = finishNode(factory.NewParameterDeclaration(null /*modifiers*/, null /*dotDotDotToken*/, identifier, null /*questionToken*/, null /*typeNode*/, null /*initializer*/), identifier.Pos());
		var parameters = newNodeList(parameter.Loc, [parameter]); // PORT: arena — Go p.nodeSliceArena.NewSlice1
		var equalsGreaterThanToken = parseExpectedToken(KindEqualsGreaterThanToken);
		var body = parseArrowFunctionExpressionBody(asyncModifier != null /*isAsync*/, allowReturnTypeInArrowFunction);
		var result = finishNode(factory.NewArrowFunction(asyncModifier, null /*typeParameters*/, parameters, null /*returnType*/, null /*fullSignature*/, equalsGreaterThanToken, body), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseConditionalExpressionRest(leftOperand:Expression, pos:Int, allowReturnTypeInArrowFunction:Bool):Expression {
		// Note: we are passed in an expression which was produced from parseBinaryExpressionOrHigher.
		var questionToken = parseOptionalToken(KindQuestionToken);
		if (questionToken == null) {
			return leftOperand;
		}
		// Note: we explicitly 'allowIn' in the whenTrue part of the condition expression, and
		// we do not that for the 'whenFalse' part.
		var saveContextFlags = contextFlags;
		setContextFlags(NodeFlagsDisallowInContext, false);
		var trueExpression = parseAssignmentExpressionOrHigherWorker(false /*allowReturnTypeInArrowFunction*/);
		contextFlags = saveContextFlags;
		var colonToken = parseExpectedToken(KindColonToken);
		var falseExpression:Expression = null;
		if (Ast.NodeIsPresent(colonToken)) {
			falseExpression = parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction);
		} else {
			falseExpression = createMissingIdentifier();
		}
		return finishNode(factory.NewConditionalExpression(leftOperand, questionToken, trueExpression, colonToken, falseExpression), pos);
	}

	function parseBinaryExpressionOrHigher(precedence:OperatorPrecedence):Expression {
		var pos = nodePos();
		var leftOperand = parseUnaryExpressionOrHigher();
		return parseBinaryExpressionRest(precedence, leftOperand, pos);
	}

	function parseBinaryExpressionRest(precedence:OperatorPrecedence, leftOperand:Expression, pos:Int):Expression {
		var lastOperand = leftOperand;
		while (true) {
			// We either have a binary operator here, or we're finished.  We call
			// reScanGreaterToken so that we merge token sequences like > and = into >=
			var operator_ = reScanGreaterThanToken();
			var newPrecedence = Ast.GetBinaryOperatorPrecedence(operator_);
			// Check the precedence to see if we should "take" this operator
			// - For left associative operator (all operator but **), consume the operator,
			//   recursively call the function below, and parse binaryExpression as a rightOperand
			//   of the caller if the new precedence of the operator is greater then or equal to the current precedence.
			//   For example:
			//      a - b - c;
			//            ^token; leftOperand = b. Return b to the caller as a rightOperand
			//      a * b - c
			//            ^token; leftOperand = b. Return b to the caller as a rightOperand
			//      a - b * c;
			//            ^token; leftOperand = b. Return b * c to the caller as a rightOperand
			// - For right associative operator (**), consume the operator, recursively call the function
			//   and parse binaryExpression as a rightOperand of the caller if the new precedence of
			//   the operator is strictly grater than the current precedence
			//   For example:
			//      a ** b ** c;
			//             ^^token; leftOperand = b. Return b ** c to the caller as a rightOperand
			//      a - b ** c;
			//            ^^token; leftOperand = b. Return b ** c to the caller as a rightOperand
			//      a ** b - c
			//             ^token; leftOperand = b. Return b to the caller as a rightOperand
			var consumeCurrentOperator:Bool = false;
			if (operator_ == KindAsteriskAsteriskToken) {
				consumeCurrentOperator = (newPrecedence : Int) >= (precedence : Int);
			} else {
				consumeCurrentOperator = (newPrecedence : Int) > (precedence : Int);
			}
			if (!consumeCurrentOperator) {
				break;
			}
			if (operator_ == KindInKeyword && inDisallowInContext()) {
				break;
			}
			if (operator_ == KindAsKeyword || operator_ == KindSatisfiesKeyword) {
				// Make sure we *do* perform ASI for constructs like this:
				//    var x = foo
				//    as (Bar)
				// This should be parsed as an initialized variable, followed
				// by a function call to 'as' with the argument 'Bar'
				if (hasPrecedingLineBreak()) {
					break;
				} else {
					nextToken();
					// When we have 'a ## b as SomeType' or 'a ## b satisfies SomeType', where ## is some binary
					// operator, we want to stop parsing on any following operator with a higher precedence than ##
					// because continuing would make it impossible to erase the `as` or `satisfies` without changing
					// the meaning of the expression. See https://github.com/microsoft/TypeScript/issues/63527.
					var lastPrecedence = OperatorPrecedenceHighest;
					if (Ast.IsBinaryExpression(lastOperand)) {
						lastPrecedence = Ast.GetBinaryOperatorPrecedence(lastOperand.AsBinaryExpression().OperatorToken.Kind);
					}
					if (operator_ == KindSatisfiesKeyword) {
						leftOperand = makeSatisfiesExpression(leftOperand, parseType());
					} else {
						leftOperand = makeAsExpression(leftOperand, parseType());
					}
					// Stop if the precedence of the next operator is too high.
					if ((Ast.GetBinaryOperatorPrecedence(reScanGreaterThanToken()) : Int) > (lastPrecedence : Int)) {
						break;
					}
				}
			} else {
				leftOperand = makeBinaryExpression(leftOperand, parseTokenNode(), parseBinaryExpressionOrHigher(newPrecedence), pos);
				lastOperand = leftOperand;
			}
		}
		return leftOperand;
	}

	function makeSatisfiesExpression(expression:Expression, typeNode:TypeNode):Node {
		return checkJSSyntax(finishNode(factory.NewSatisfiesExpression(expression, typeNode), expression.Pos()));
	}

	function makeAsExpression(left:Expression, right:TypeNode):Node {
		return checkJSSyntax(finishNode(factory.NewAsExpression(left, right), left.Pos()));
	}

	function makeBinaryExpression(left:Expression, operatorToken:Node, right:Expression, pos:Int):Node {
		return finishNode(factory.NewBinaryExpression(null /*modifiers*/, left, null /*typeNode*/, operatorToken, right), pos);
	}

	function parseUnaryExpressionOrHigher():Expression {
		// ES7 UpdateExpression:
		//      1) LeftHandSideExpression[?Yield]
		//      2) LeftHandSideExpression[?Yield][no LineTerminator here]++
		//      3) LeftHandSideExpression[?Yield][no LineTerminator here]--
		//      4) ++UnaryExpression[?Yield]
		//      5) --UnaryExpression[?Yield]
		if (isUpdateExpression()) {
			var pos = nodePos();
			var updateExpression = parseUpdateExpression();
			if (token == KindAsteriskAsteriskToken) {
				return parseBinaryExpressionRest(Ast.GetBinaryOperatorPrecedence(token), updateExpression, pos);
			}
			return updateExpression;
		}
		// ES7 UnaryExpression:
		//      1) UpdateExpression[?yield]
		//      2) delete UpdateExpression[?yield]
		//      3) void UpdateExpression[?yield]
		//      4) typeof UpdateExpression[?yield]
		//      5) + UpdateExpression[?yield]
		//      6) - UpdateExpression[?yield]
		//      7) ~ UpdateExpression[?yield]
		//      8) ! UpdateExpression[?yield]
		var unaryOperator = token;
		var simpleUnaryExpression = parseSimpleUnaryExpression();
		if (token == KindAsteriskAsteriskToken) {
			var pos = Scanner.SkipTrivia(sourceText, simpleUnaryExpression.Pos());
			var end = simpleUnaryExpression.End();
			if (simpleUnaryExpression.Kind == KindTypeAssertionExpression) {
				parseErrorAt(pos, end, Diagnostics.A_type_assertion_expression_is_not_allowed_in_the_left_hand_side_of_an_exponentiation_expression_Consider_enclosing_the_expression_in_parentheses);
			} else {
				Debug.Assert(isKeywordOrPunctuation(unaryOperator));
				parseErrorAt(pos, end, Diagnostics.An_unary_expression_with_the_0_operator_is_not_allowed_in_the_left_hand_side_of_an_exponentiation_expression_Consider_enclosing_the_expression_in_parentheses, Scanner.TokenToString(unaryOperator));
			}
		}
		return simpleUnaryExpression;
	}

	function isUpdateExpression():Bool {
		switch (token) {
		case KindPlusToken | KindMinusToken | KindTildeToken | KindExclamationToken | KindDeleteKeyword | KindTypeOfKeyword | KindVoidKeyword | KindAwaitKeyword:
			return false;
		case KindLessThanToken:
			return languageVariant == LanguageVariantJSX;
		default:
		}
		return true;
	}

	function parseUpdateExpression():Expression {
		var pos = nodePos();
		if (token == KindPlusPlusToken || token == KindMinusMinusToken) {
			var operator_ = token;
			nextToken();
			return finishNode(factory.NewPrefixUnaryExpression(operator_, parseLeftHandSideExpressionOrHigher()), pos);
		} else if (languageVariant == LanguageVariantJSX && token == KindLessThanToken && lookAhead(fn_nextTokenIsIdentifierOrKeywordOrGreaterThan)) {
			// JSXElement is part of primaryExpression
			return parseJsxElementOrSelfClosingElementOrFragment(true /*inExpressionContext*/, -1 /*topInvalidNodePosition*/, null /*openingTag*/, false /*mustBeUnary*/);
		}
		var expression = parseLeftHandSideExpressionOrHigher();
		if ((token == KindPlusPlusToken || token == KindMinusMinusToken) && !hasPrecedingLineBreak()) {
			var operator_ = token;
			nextToken();
			return finishNode(factory.NewPostfixUnaryExpression(expression, operator_), pos);
		}
		return expression;
	}

	function parseJsxElementOrSelfClosingElementOrFragment(inExpressionContext:Bool, topInvalidNodePosition:Int, openingTag:Node, mustBeUnary:Bool):Expression {
		var pos = nodePos();
		var opening = parseJsxOpeningOrSelfClosingElementOrOpeningFragment(inExpressionContext);
		var result:Expression = null;
		switch (opening.Kind) {
		case KindJsxOpeningElement:
			var children = parseJsxChildren(opening);
			var closingElement:Node = null;
			var lastChild = Core.LastOrNil(children.Nodes);
			if (lastChild != null && lastChild.Kind == KindJsxElement &&
				!Ast.TagNamesAreEquivalent(lastChild.AsJsxElement().OpeningElement.TagName(), lastChild.AsJsxElement().ClosingElement.TagName()) &&
				Ast.TagNamesAreEquivalent(opening.TagName(), lastChild.AsJsxElement().ClosingElement.TagName())) {
				// when an unclosed JsxOpeningElement incorrectly parses its parent's JsxClosingElement,
				// restructure (<div>(...<span>...</div>)) --> (<div>(...<span>...</>)</div>)
				// (no need to error; the parent will error)
				var end = lastChild.Children().End();
				var missingIdentifier = finishNodeWithEnd(newIdentifier(""), end, end);
				var newClosingElement = finishNodeWithEnd(factory.NewJsxClosingElement(missingIdentifier), end, end);
				var newLast = finishNodeWithEnd(
					factory.NewJsxElement(lastChild.AsJsxElement().OpeningElement, lastChild.Children(), newClosingElement),
					lastChild.AsJsxElement().OpeningElement.Pos(),
					end
				);
				// force reset parent pointers from discarded parse result
				if (lastChild.AsJsxElement().OpeningElement != null) {
					lastChild.AsJsxElement().OpeningElement.Parent = newLast;
				}
				if (lastChild.Children() != null) {
					for (c in nodesOf(lastChild.Children().Nodes)) {
						c.Parent = newLast;
					}
				}
				newClosingElement.Parent = newLast;
				// PORT: Go `append(children.Nodes[:len-1], newLast)` writes into the same backing array.
				final childNodes = children.Nodes;
				childNodes[childNodes.length - 1] = newLast;
				children = newNodeList(Core.NewTextRange(children.Pos(), newLast.End()), childNodes);
				closingElement = lastChild.AsJsxElement().ClosingElement;
			} else {
				closingElement = parseJsxClosingElement(opening, inExpressionContext);
				if (!Ast.TagNamesAreEquivalent(opening.TagName(), closingElement.TagName())) {
					if (openingTag != null && Ast.IsJsxOpeningElement(openingTag) && Ast.TagNamesAreEquivalent(closingElement.TagName(), openingTag.TagName())) {
						// opening incorrectly matched with its parent's closing -- put error on opening
						parseErrorAtRange(opening.TagName().Loc, Diagnostics.JSX_element_0_has_no_corresponding_closing_tag, Scanner.GetTextOfNodeFromSourceText(sourceText, opening.TagName(), false /*includeTrivia*/));
					} else {
						// other opening/closing mismatches -- put error on closing
						parseErrorAtRange(closingElement.TagName().Loc, Diagnostics.Expected_corresponding_JSX_closing_tag_for_0, Scanner.GetTextOfNodeFromSourceText(sourceText, opening.TagName(), false /*includeTrivia*/));
					}
				}
			}
			result = finishNode(factory.NewJsxElement(opening, children, closingElement), pos);
			closingElement.Parent = result; // force reset parent pointers from possibly discarded parse result
		case KindJsxOpeningFragment:
			result = finishNode(factory.NewJsxFragment(opening, parseJsxChildren(opening), parseJsxClosingFragment(inExpressionContext)), pos);
		case KindJsxSelfClosingElement:
			// Nothing else to do for self-closing elements
			result = opening;
		default:
			throw "Unhandled case in parseJsxElementOrSelfClosingElementOrFragment";
		}
		// If the user writes the invalid code '<div></div><div></div>' in an expression context (i.e. not wrapped in
		// an enclosing tag), we'll naively try to parse   ^ this as a 'less than' operator and the remainder of the tag
		// as garbage, which will cause the formatter to badly mangle the JSX. Perform a speculative parse of a JSX
		// element if we see a < token so that we can wrap it in a synthetic binary expression so the formatter
		// does less damage and we can report a better error.
		// Since JSX elements are invalid < operands anyway, this lookahead parse will only occur in error scenarios
		// of one sort or another.
		// If we are in a unary context, we can't do this recovery; the binary expression we return here is not
		// a valid UnaryExpression and will cause problems later.
		if (!mustBeUnary && inExpressionContext && token == KindLessThanToken) {
			var topBadPos = topInvalidNodePosition;
			if (topBadPos < 0) {
				topBadPos = result.Pos();
			}
			var invalidElement = parseJsxElementOrSelfClosingElementOrFragment( /*inExpressionContext*/ true, topBadPos, null, false);
			var operatorToken = factory.NewToken(KindCommaToken);
			operatorToken.Loc = Core.NewTextRange(invalidElement.Pos(), invalidElement.Pos());
			parseErrorAt(Scanner.SkipTrivia(sourceText, topBadPos), invalidElement.End(), Diagnostics.JSX_expressions_must_have_one_parent_element);
			result = finishNode(factory.NewBinaryExpression(null /*modifiers*/, result, null /*typeNode*/, operatorToken, invalidElement), pos);
		}
		return result;
	}

	function parseJsxChildren(openingTag:Expression):NodeList {
		var pos = nodePos();
		var saveParsingContexts = parsingContexts;
		parsingContexts |= 1 << PCJsxChildren;
		var list:Array<Node> = null;
		while (true) {
			var currentToken = scanner.ReScanJsxToken(true /*allowMultilineJsxText*/);
			var child = parseJsxChild(openingTag, currentToken);
			if (child == null) {
				break;
			}
			list = append(list, child);
			if (Ast.IsJsxOpeningElement(openingTag) && child.Kind == KindJsxElement &&
				!Ast.TagNamesAreEquivalent(child.AsJsxElement().OpeningElement.TagName(), child.AsJsxElement().ClosingElement.TagName()) &&
				Ast.TagNamesAreEquivalent(openingTag.TagName(), child.AsJsxElement().ClosingElement.TagName())) {
				// stop after parsing a mismatched child like <div>...(<span></div>) in order to reattach the </div> higher
				break;
			}
		}
		parsingContexts = saveParsingContexts;
		return newNodeList(Core.NewTextRange(pos, nodePos()), list);
	}

	function parseJsxChild(openingTag:Node, token:Kind):Expression {
		switch (token) {
		case KindEndOfFile:
			// If we hit EOF, issue the error at the tag that lacks the closing element
			// rather than at the end of the file (which is useless)
			if (Ast.IsJsxOpeningFragment(openingTag)) {
				parseErrorAtRange(openingTag.Loc, Diagnostics.JSX_fragment_has_no_corresponding_closing_tag);
			} else {
				// We want the error span to cover only 'Foo.Bar' in < Foo.Bar >
				// or to cover only 'Foo' in < Foo >
				var tag = openingTag.TagName();
				var start = minInt(Scanner.SkipTrivia(sourceText, tag.Pos()), tag.End()); // Go builtin min
				parseErrorAt(start, tag.End(), Diagnostics.JSX_element_0_has_no_corresponding_closing_tag,
					Scanner.GetTextOfNodeFromSourceText(sourceText, openingTag.TagName(), false /*includeTrivia*/));
			}
			return null;
		case KindLessThanSlashToken | KindConflictMarkerTrivia:
			return null;
		case KindJsxText | KindJsxTextAllWhiteSpaces:
			return parseJsxText();
		case KindOpenBraceToken:
			return parseJsxExpression(false /*inExpressionContext*/);
		case KindLessThanToken:
			return parseJsxElementOrSelfClosingElementOrFragment(false /*inExpressionContext*/, -1 /*topInvalidNodePosition*/, openingTag, false);
		default:
		}
		throw "Unhandled case in parseJsxChild";
	}

	function parseJsxText():Node {
		var pos = nodePos();
		var result = factory.NewJsxText(scanner.TokenValue(), token == KindJsxTextAllWhiteSpaces);
		scanJsxText();
		return finishNode(result, pos);
	}

	function parseJsxExpression(inExpressionContext:Bool):Node {
		var pos = nodePos();
		if (!parseExpected(KindOpenBraceToken)) {
			return null;
		}
		var dotDotDotToken:Node = null;
		var expression:Expression = null;
		if (token != KindCloseBraceToken) {
			if (!inExpressionContext) {
				dotDotDotToken = parseOptionalToken(KindDotDotDotToken);
			}
			// Only an AssignmentExpression is valid here per the JSX spec,
			// but we can unambiguously parse a comma sequence and provide
			// a better error message in grammar checking.
			expression = parseExpression();
		}
		if (inExpressionContext) {
			parseExpected(KindCloseBraceToken);
		} else if (parseExpectedWithoutAdvancing(KindCloseBraceToken)) {
			scanJsxText();
		}
		return finishNode(factory.NewJsxExpression(dotDotDotToken, expression), pos);
	}

	function scanJsxText():Kind {
		token = scanner.ScanJsxToken();
		return token;
	}

	function scanJsxIdentifier():Kind {
		token = scanner.ScanJsxIdentifier();
		return token;
	}

	function scanJsxAttributeValue():Kind {
		token = scanner.ScanJsxAttributeValue();
		return token;
	}

	function parseJsxClosingElement(open:Node, inExpressionContext:Bool):Node {
		var pos = nodePos();
		parseExpected(KindLessThanSlashToken);
		var tagName = parseJsxElementName();
		if (parseExpectedWithDiagnostic(KindGreaterThanToken, null /*diagnosticMessage*/, false /*shouldAdvance*/)) {
			// manually advance the scanner in order to look for jsx text inside jsx
			if (inExpressionContext || !Ast.TagNamesAreEquivalent(open.TagName(), tagName)) {
				nextToken();
			} else {
				scanJsxText();
			}
		}
		return finishNode(factory.NewJsxClosingElement(tagName), pos);
	}

	function parseJsxOpeningOrSelfClosingElementOrOpeningFragment(inExpressionContext:Bool):Expression {
		var pos = nodePos();
		parseExpected(KindLessThanToken);
		if (token == KindGreaterThanToken) {
			// See below for explanation of scanJsxText
			scanJsxText();
			return finishNode(factory.NewJsxOpeningFragment(), pos);
		}
		var tagName = parseJsxElementName();
		var typeArguments:NodeList = null;
		if (contextFlags&NodeFlagsJavaScriptFile == 0) {
			typeArguments = parseTypeArguments();
		}
		var attributes = parseJsxAttributes();
		var result:Expression = null;
		if (token == KindGreaterThanToken) {
			// Closing tag, so scan the immediately-following text with the JSX scanning instead
			// of regular scanning to avoid treating illegal characters (e.g. '#') as immediate
			// scanning errors
			scanJsxText();
			result = factory.NewJsxOpeningElement(tagName, typeArguments, attributes);
		} else {
			parseExpected(KindSlashToken);
			if (parseExpectedWithoutAdvancing(KindGreaterThanToken)) {
				if (inExpressionContext) {
					nextToken();
				} else {
					scanJsxText();
				}
			}
			result = factory.NewJsxSelfClosingElement(tagName, typeArguments, attributes);
		}
		return finishNode(result, pos);
	}

	function parseJsxElementName():Expression {
		var pos = nodePos();
		// JsxElement can have name in the form of
		//      propertyAccessExpression
		//      primaryExpression in the form of an identifier and "this" keyword
		// We can't just simply use parseLeftHandSideExpressionOrHigher because then we will start consider class,function etc as a keyword
		// We only want to consider "this" as a primaryExpression
		var initialExpression = parseJsxTagName();
		if (Ast.IsJsxNamespacedName(initialExpression)) {
			return initialExpression; // `a:b.c` is invalid syntax, don't even look for the `.` if we parse `a:b`, and let `parseAttribute` report "unexpected :" instead.
		}
		var expression = initialExpression;
		while (parseOptional(KindDotToken)) {
			expression = finishNode(factory.NewPropertyAccessExpression(expression, null, parseRightSideOfDot(true /*allowIdentifierNames*/, false /*allowPrivateIdentifiers*/, false /*allowUnicodeEscapeSequenceInIdentifierName*/), NodeFlagsNone), pos);
		}
		return expression;
	}

	function parseJsxTagName():Expression {
		var pos = nodePos();
		scanJsxIdentifier();
		var isThis = token == KindThisKeyword;
		var tagName = parseIdentifierNameErrorOnUnicodeEscapeSequence();
		if (parseOptional(KindColonToken)) {
			scanJsxIdentifier();
			return finishNode(factory.NewJsxNamespacedName(tagName, parseIdentifierNameErrorOnUnicodeEscapeSequence()), pos);
		}
		if (isThis) {
			var result = factory.NewKeywordExpression(KindThisKeyword);
			return finishNode(result, pos);
		}
		return tagName;
	}

	function parseJsxAttributes():Node {
		var pos = nodePos();
		return finishNode(factory.NewJsxAttributes(parseList(PCJsxAttributes, fn_parseJsxAttribute)), pos);
	}

	function parseJsxAttribute():Node {
		if (token == KindOpenBraceToken) {
			return parseJsxSpreadAttribute();
		}
		var pos = nodePos();
		return finishNode(factory.NewJsxAttribute(parseJsxAttributeName(), parseJsxAttributeValue()), pos);
	}

	function parseJsxSpreadAttribute():Node {
		var pos = nodePos();
		parseExpected(KindOpenBraceToken);
		parseExpected(KindDotDotDotToken);
		var expression = parseExpression();
		parseExpected(KindCloseBraceToken);
		return finishNode(factory.NewJsxSpreadAttribute(expression), pos);
	}

	function parseJsxAttributeName():Node {
		var pos = nodePos();
		scanJsxIdentifier();
		var attrName = parseIdentifierNameErrorOnUnicodeEscapeSequence();
		if (parseOptional(KindColonToken)) {
			scanJsxIdentifier();
			return finishNode(factory.NewJsxNamespacedName(attrName, parseIdentifierNameErrorOnUnicodeEscapeSequence()), pos);
		}
		return attrName;
	}

	function parseJsxAttributeValue():Expression {
		if (token == KindEqualsToken) {
			if (scanJsxAttributeValue() == KindStringLiteral) {
				return parseLiteralExpression(false /*intern*/);
			}
			if (token == KindOpenBraceToken) {
				return parseJsxExpression( /*inExpressionContext*/ true);
			}
			if (token == KindLessThanToken) {
				return parseJsxElementOrSelfClosingElementOrFragment(true /*inExpressionContext*/, -1, null, false);
			}
			parseErrorAtCurrentToken(Diagnostics.X_or_JSX_element_expected);
		}
		return null;
	}

	function parseJsxClosingFragment(inExpressionContext:Bool):Node {
		var pos = nodePos();
		parseExpected(KindLessThanSlashToken);
		if (parseExpectedWithDiagnostic(KindGreaterThanToken, Diagnostics.Expected_corresponding_closing_tag_for_JSX_fragment, false /*shouldAdvance*/)) {
			// manually advance the scanner in order to look for jsx text inside jsx
			if (inExpressionContext) {
				nextToken();
			} else {
				scanJsxText();
			}
		}
		return finishNode(factory.NewJsxClosingFragment(), pos);
	}

	function parseSimpleUnaryExpression():Expression {
		switch (token) {
		case KindPlusToken | KindMinusToken | KindTildeToken | KindExclamationToken:
			return parsePrefixUnaryExpression();
		case KindDeleteKeyword:
			return parseDeleteExpression();
		case KindTypeOfKeyword:
			return parseTypeOfExpression();
		case KindVoidKeyword:
			return parseVoidExpression();
		case KindLessThanToken:
			// Just like in parseUpdateExpression, we need to avoid parsing type assertions when
			// in JSX and we see an expression like "+ <foo> bar".
			if (languageVariant == LanguageVariantJSX) {
				return parseJsxElementOrSelfClosingElementOrFragment(true /*inExpressionContext*/, -1 /*topInvalidNodePosition*/, null /*openingTag*/, true /*mustBeUnary*/);
			}
			// // This is modified UnaryExpression grammar in TypeScript
			// //  UnaryExpression (modified):
			// //      < type > UnaryExpression
			return parseTypeAssertion();
		case KindAwaitKeyword:
			if (isAwaitExpression()) {
				return parseAwaitExpression();
			}
			// PORT: fallthrough
			return parseUpdateExpression();
		default:
			return parseUpdateExpression();
		}
	}

	function parsePrefixUnaryExpression():Node {
		var pos = nodePos();
		var operator_ = token;
		nextToken();
		return finishNode(factory.NewPrefixUnaryExpression(operator_, parseSimpleUnaryExpression()), pos);
	}

	function parseDeleteExpression():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewDeleteExpression(parseSimpleUnaryExpression()), pos);
	}

	function parseTypeOfExpression():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewTypeOfExpression(parseSimpleUnaryExpression()), pos);
	}

	function parseVoidExpression():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewVoidExpression(parseSimpleUnaryExpression()), pos);
	}

	function isAwaitExpression():Bool {
		if (token == KindAwaitKeyword) {
			if (inAwaitContext()) {
				return true;
			}
			// here we are using similar heuristics as 'isYieldExpression'
			return lookAhead(fn_nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine);
		}
		return false;
	}

	function parseAwaitExpression():Node {
		var pos = nodePos();
		nextToken();
		return finishNode(factory.NewAwaitExpression(parseSimpleUnaryExpression()), pos);
	}

	function parseTypeAssertion():Node {
		Debug.Assert(languageVariant != LanguageVariantJSX, "Type assertions should never be parsed in JSX; they should be parsed as comparisons or JSX elements/fragments.");
		var pos = nodePos();
		parseExpected(KindLessThanToken);
		var typeNode = parseType();
		parseExpected(KindGreaterThanToken);
		var expression = parseSimpleUnaryExpression();
		return finishNode(factory.NewTypeAssertion(typeNode, expression), pos);
	}

	function parseLeftHandSideExpressionOrHigher():Expression {
		// Original Ecma:
		// LeftHandSideExpression: See 11.2
		//      NewExpression
		//      CallExpression
		//
		// Our simplification:
		//
		// LeftHandSideExpression: See 11.2
		//      MemberExpression
		//      CallExpression
		//
		// See comment in parseMemberExpressionOrHigher on how we replaced NewExpression with
		// MemberExpression to make our lives easier.
		//
		// to best understand the below code, it's important to see how CallExpression expands
		// out into its own productions:
		//
		// CallExpression:
		//      MemberExpression Arguments
		//      CallExpression Arguments
		//      CallExpression[Expression]
		//      CallExpression.IdentifierName
		//      import (AssignmentExpression)
		//      super Arguments
		//      super.IdentifierName
		//
		// Because of the recursion in these calls, we need to bottom out first. There are three
		// bottom out states we can run into: 1) We see 'super' which must start either of
		// the last two CallExpression productions. 2) We see 'import' which must start import call.
		// 3)we have a MemberExpression which either completes the LeftHandSideExpression,
		// or starts the beginning of the first four CallExpression productions.
		var pos = nodePos();
		var expression:Expression = null;
		if (token == KindImportKeyword) {
			if (lookAhead(fn_nextTokenIsOpenParenOrLessThan)) {
				// We don't want to eagerly consume all import keyword as import call expression so we look ahead to find "("
				// For example:
				//      var foo3 = require("subfolder
				//      import * as foo1 from "module-from-node
				// We want this import to be a statement rather than import call expression
				sourceFlags |= NodeFlagsPossiblyContainsDynamicImport;
				expression = parseKeywordExpression();
			} else if (lookAhead(fn_nextTokenIsDot)) {
				// This is an 'import.*' metaproperty (i.e. 'import.meta')
				nextToken(); // advance past the 'import'
				nextToken(); // advance past the dot
				expression = finishNode(factory.NewMetaProperty(KindImportKeyword, parseIdentifierName()), pos);
				if (expression.Text() == "defer") {
					if (token == KindOpenParenToken || token == KindLessThanToken) {
						sourceFlags |= NodeFlagsPossiblyContainsDynamicImport;
					}
				} else {
					sourceFlags |= NodeFlagsPossiblyContainsImportMeta;
				}
			} else {
				expression = parseMemberExpressionOrHigher();
			}
		} else if (token == KindSuperKeyword) {
			expression = parseSuperExpression();
		} else {
			expression = parseMemberExpressionOrHigher();
		}
		// Now, we *may* be complete.  However, we might have consumed the start of a
		// CallExpression or OptionalExpression.  As such, we need to consume the rest
		// of it here to be complete.
		return parseCallExpressionRest(pos, expression);
	}

	function nextTokenIsDot():Bool {
		return nextToken() == KindDotToken;
	}

	function parseSuperExpression():Expression {
		var pos = nodePos();
		var expression = parseKeywordExpression();
		if (token == KindLessThanToken) {
			var startPos = nodePos();
			var typeArguments = tryParseTypeArgumentsInExpression();
			if (typeArguments != null) {
				parseErrorAt(startPos, nodePos(), Diagnostics.X_super_may_not_use_type_arguments);
				if (!isTemplateStartOfTaggedTemplate()) {
					expression = finishNode(factory.NewExpressionWithTypeArguments(expression, typeArguments), pos);
				}
			}
		}
		if (token == KindOpenParenToken || token == KindDotToken || token == KindOpenBracketToken) {
			return expression;
		}
		// If we have seen "super" it must be followed by '(' or '.'.
		// If it wasn't then just try to parse out a '.' and report an error.
		parseErrorAtCurrentToken(Diagnostics.X_super_must_be_followed_by_an_argument_list_or_member_access);
		// private names will never work with `super` (`super.#foo`), but that's a semantic error, not syntactic
		return finishNode(factory.NewPropertyAccessExpression(expression, null /*questionDotToken*/, parseRightSideOfDot(true /*allowIdentifierNames*/, true /*allowPrivateIdentifiers*/, true /*allowUnicodeEscapeSequenceInIdentifierName*/), NodeFlagsNone), pos);
	}

	function isTemplateStartOfTaggedTemplate():Bool {
		return token == KindNoSubstitutionTemplateLiteral || token == KindTemplateHead;
	}

	function tryParseTypeArgumentsInExpression():NodeList {
		// TypeArguments must not be parsed in JavaScript files to avoid ambiguity with binary operators.
		// Check the cheap preconditions before saving the parser state: unless the current token is `<`
		// (or `<<`, which reScanLessThanToken would split), there is nothing to speculatively parse and
		// the mark/rewind would be a no-op.
		if (contextFlags&NodeFlagsJavaScriptFile != 0 || (token != KindLessThanToken && token != KindLessThanLessThanToken)) {
			return null;
		}
		var state = mark();
		if (reScanLessThanToken() == KindLessThanToken) {
			nextToken();
			var typeArguments = parseDelimitedList(PCTypeArguments, fn_parseType);
			// If it doesn't have the closing `>` then it's definitely not an type argument list.
			if (reScanGreaterThanToken() == KindGreaterThanToken) {
				nextToken();
				// We successfully parsed a type argument list. The next token determines whether we want to
				// treat it as such. If the type argument list is followed by `(` or a template literal, as in
				// `f<number>(42)`, we favor the type argument interpretation even though JavaScript would view
				// it as a relational expression.
				if (canFollowTypeArgumentsInExpression()) {
					return typeArguments;
				}
			}
		}
		rewind(state);
		return null;
	}

	function canFollowTypeArgumentsInExpression():Bool {
		switch (token) {
		// These tokens can follow a type argument list in a call expression:
		// foo<x>(
		// foo<T> `...`
		// foo<T> `...${100}...`
		case KindOpenParenToken | KindNoSubstitutionTemplateLiteral | KindTemplateHead:
			return true;
		// A type argument list followed by `<` never makes sense, and a type argument list followed
		// by `>` is ambiguous with a (re-scanned) `>>` operator, so we disqualify both. Also, in
		// this context, `+` and `-` are unary operators, not binary operators.
		case KindLessThanToken | KindGreaterThanToken | KindPlusToken | KindMinusToken:
			return false;
		default:
		}
		// We favor the type argument list interpretation when it is immediately followed by
		// a line break, a binary operator, or something that can't start an expression.
		return hasPrecedingLineBreak() || isBinaryOperator() || !isStartOfExpression();
	}

	function parseMemberExpressionOrHigher():Node {
		// Note: to make our lives simpler, we decompose the NewExpression productions and
		// place ObjectCreationExpression and FunctionExpression into PrimaryExpression.
		// like so:
		//
		//   PrimaryExpression : See 11.1
		//      this
		//      Identifier
		//      Literal
		//      ArrayLiteral
		//      ObjectLiteral
		//      (Expression)
		//      FunctionExpression
		//      new MemberExpression Arguments?
		//
		//   MemberExpression : See 11.2
		//      PrimaryExpression
		//      MemberExpression[Expression]
		//      MemberExpression.IdentifierName
		//
		//   CallExpression : See 11.2
		//      MemberExpression
		//      CallExpression Arguments
		//      CallExpression[Expression]
		//      CallExpression.IdentifierName
		//
		// Technically this is ambiguous.  i.e. CallExpression defines:
		//
		//   CallExpression:
		//      CallExpression Arguments
		//
		// If you see: "new Foo()"
		//
		// Then that could be treated as a single ObjectCreationExpression, or it could be
		// treated as the invocation of "new Foo".  We disambiguate that in code (to match
		// the original grammar) by making sure that if we see an ObjectCreationExpression
		// we always consume arguments if they are there. So we treat "new Foo()" as an
		// object creation only, and not at all as an invocation.  Another way to think
		// about this is that for every "new" that we see, we will consume an argument list if
		// it is there as part of the *associated* object creation node.  Any additional
		// argument lists we see, will become invocation expressions.
		//
		// Because there are no other places in the grammar now that refer to FunctionExpression
		// or ObjectCreationExpression, it is safe to push down into the PrimaryExpression
		// production.
		//
		// Because CallExpression and MemberExpression are left recursive, we need to bottom out
		// of the recursion immediately.  So we parse out a primary expression to start with.
		var pos = nodePos();
		var expression = parsePrimaryExpression();
		return parseMemberExpressionRest(pos, expression, true /*allowOptionalChain*/);
	}

	function parseMemberExpressionRest(pos:Int, expression:Expression, allowOptionalChain:Bool):Expression {
		while (true) {
			var questionDotToken:Node = null;
			var isPropertyAccess = false;
			if (allowOptionalChain && isStartOfOptionalPropertyOrElementAccessChain()) {
				questionDotToken = parseExpectedToken(KindQuestionDotToken);
				isPropertyAccess = tokenIsIdentifierOrKeyword(token);
			} else {
				isPropertyAccess = parseOptional(KindDotToken);
			}
			if (isPropertyAccess) {
				expression = parsePropertyAccessExpressionRest(pos, expression, questionDotToken);
				continue;
			}
			// when in the [Decorator] context, we do not parse ElementAccess as it could be part of a ComputedPropertyName
			if ((questionDotToken != null || !inDecoratorContext()) && parseOptional(KindOpenBracketToken)) {
				expression = parseElementAccessExpressionRest(pos, expression, questionDotToken);
				continue;
			}
			if (isTemplateStartOfTaggedTemplate()) {
				// Absorb type arguments into TemplateExpression when preceding expression is ExpressionWithTypeArguments
				if (questionDotToken == null && Ast.IsExpressionWithTypeArguments(expression)) {
					var original = expression.AsExpressionWithTypeArguments();
					expression = parseTaggedTemplateRest(pos, original.Expression, questionDotToken, original.TypeArguments);
					unparseExpressionWithTypeArguments(original.Expression, original.TypeArguments, expression);
				} else {
					expression = parseTaggedTemplateRest(pos, expression, questionDotToken, null /*typeArguments*/);
				}
				continue;
			}
			if (questionDotToken == null) {
				if (token == KindExclamationToken && !hasPrecedingLineBreak()) {
					nextToken();
					expression = checkJSSyntax(finishNode(factory.NewNonNullExpression(expression, NodeFlagsNone), pos));
					continue;
				}
				var typeArguments = tryParseTypeArgumentsInExpression();
				if (typeArguments != null) {
					expression = finishNode(factory.NewExpressionWithTypeArguments(expression, typeArguments), pos);
					continue;
				}
			}
			return expression;
		}
	}

	function isStartOfOptionalPropertyOrElementAccessChain():Bool {
		return token == KindQuestionDotToken && lookAhead(fn_nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate);
	}

	function nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate():Bool {
		nextToken();
		return tokenIsIdentifierOrKeyword(token) || token == KindOpenBracketToken || isTemplateStartOfTaggedTemplate();
	}

	function parsePropertyAccessExpressionRest(pos:Int, expression:Expression, questionDotToken:Node):Node {
		var name = parseRightSideOfDot(true /*allowIdentifierNames*/, true /*allowPrivateIdentifiers*/, true /*allowUnicodeEscapeSequenceInIdentifierName*/);
		var isOptionalChain = questionDotToken != null || tryReparseOptionalChain(expression);
		var propertyAccess = factory.NewPropertyAccessExpression(expression, questionDotToken, name, (isOptionalChain ? NodeFlagsOptionalChain : NodeFlagsNone));
		if (isOptionalChain && Ast.IsPrivateIdentifier(name)) {
			parseErrorAtRange(skipRangeTrivia(name.Loc), Diagnostics.An_optional_chain_cannot_contain_private_identifiers);
		}
		if (Ast.IsExpressionWithTypeArguments(expression)) {
			var typeArguments = expression.TypeArgumentList();
			if (typeArguments != null) {
				var loc = Core.NewTextRange(typeArguments.Pos()-1, Scanner.SkipTrivia(sourceText, typeArguments.End())+1);
				parseErrorAtRange(loc, Diagnostics.An_instantiation_expression_cannot_be_followed_by_a_property_access);
			}
		}
		return finishNode(propertyAccess, pos);
	}

	function tryReparseOptionalChain(node:Expression):Bool {
		if (node.Flags&NodeFlagsOptionalChain != 0) {
			return true;
		}
		// check for an optional chain in a non-null expression
		if (Ast.IsNonNullExpression(node)) {
			var expr = node.Expression();
			while (Ast.IsNonNullExpression(expr) && expr.Flags&NodeFlagsOptionalChain == 0) {
				expr = expr.Expression();
			}
			if (expr.Flags&NodeFlagsOptionalChain != 0) {
				// this is part of an optional chain. Walk down from `node` to `expression` and set the flag.
				while (Ast.IsNonNullExpression(node)) {
					node.Flags |= NodeFlagsOptionalChain;
					node = node.Expression();
				}
				return true;
			}
		}
		return false;
	}

	function parseElementAccessExpressionRest(pos:Int, expression:Expression, questionDotToken:Node):Node {
		var argumentExpression:Expression = null;
		if (token == KindCloseBracketToken) {
			parseErrorAt(nodePos(), nodePos(), Diagnostics.An_element_access_expression_should_take_an_argument);
			argumentExpression = createMissingIdentifier();
		} else {
			var argument = parseExpressionAllowIn();
			switch (argument.Kind) {
			case KindStringLiteral:
				argument.AsStringLiteral().Text = internIdentifier(argument.Text());
			case KindNoSubstitutionTemplateLiteral:
				argument.AsNoSubstitutionTemplateLiteral().Text = internIdentifier(argument.Text());
			case KindNumericLiteral:
				argument.AsNumericLiteral().Text = internIdentifier(argument.Text());
			default:
			}
			argumentExpression = argument;
		}
		parseExpected(KindCloseBracketToken);
		var isOptionalChain = questionDotToken != null || tryReparseOptionalChain(expression);
		return finishNode(factory.NewElementAccessExpression(expression, questionDotToken, argumentExpression, (isOptionalChain ? NodeFlagsOptionalChain : NodeFlagsNone)), pos);
	}

	function parseCallExpressionRest(pos:Int, expression:Expression):Expression {
		while (true) {
			expression = parseMemberExpressionRest(pos, expression /*allowOptionalChain*/, true);
			var typeArguments:NodeList = null;
			var questionDotToken = parseOptionalToken(KindQuestionDotToken);
			if (questionDotToken != null) {
				typeArguments = tryParseTypeArgumentsInExpression();
				if (isTemplateStartOfTaggedTemplate()) {
					expression = parseTaggedTemplateRest(pos, expression, questionDotToken, typeArguments);
					continue;
				}
			}
			if (typeArguments != null || token == KindOpenParenToken) {
				// Absorb type arguments into CallExpression when preceding expression is ExpressionWithTypeArguments
				if (questionDotToken == null && expression.Kind == KindExpressionWithTypeArguments) {
					typeArguments = expression.TypeArgumentList();
					expression = expression.AsExpressionWithTypeArguments().Expression;
				}
				var inner = expression;
				var argumentList = parseArgumentList();
				var isOptionalChain = questionDotToken != null || tryReparseOptionalChain(expression);
				expression = checkJSSyntax(finishNode(factory.NewCallExpression(expression, questionDotToken, typeArguments, argumentList, (isOptionalChain ? NodeFlagsOptionalChain : NodeFlagsNone)), pos));
				unparseExpressionWithTypeArguments(inner, typeArguments, expression);
				continue;
			}
			if (questionDotToken != null) {
				// We parsed `?.` but then failed to parse anything, so report a missing identifier here.
				parseErrorAtCurrentToken(Diagnostics.Identifier_expected);
				var name = createMissingIdentifier();
				expression = finishNode(factory.NewPropertyAccessExpression(expression, questionDotToken, name, NodeFlagsOptionalChain), pos);
			}
			break;
		}
		return expression;
	}

	function parseArgumentList():NodeList {
		parseExpected(KindOpenParenToken);
		var result = parseDelimitedList(PCArgumentExpressions, fn_parseArgumentExpression);
		parseExpected(KindCloseParenToken);
		return result;
	}

	function parseArgumentExpression():Expression {
		return doInContext(this, NodeFlagsDisallowInContext|NodeFlagsDecoratorContext, false, fn_parseArgumentOrArrayLiteralElement);
	}

	function parseArgumentOrArrayLiteralElement():Expression {
		switch (token) {
		case KindDotDotDotToken:
			return parseSpreadElement();
		case KindCommaToken:
			return finishNode(factory.NewOmittedExpression(), nodePos());
		default:
		}
		return parseAssignmentExpressionOrHigher();
	}

	function parseSpreadElement():Node {
		var pos = nodePos();
		parseExpected(KindDotDotDotToken);
		var expression = parseAssignmentExpressionOrHigher();
		return finishNode(factory.NewSpreadElement(expression), pos);
	}

	function parseTaggedTemplateRest(pos:Int, tag:Expression, questionDotToken:Node, typeArguments:NodeList):Node {
		var template:Expression = null;
		if (token == KindNoSubstitutionTemplateLiteral) {
			reScanTemplateToken(true /*isTaggedTemplate*/);
			template = parseLiteralExpression(false /*intern*/);
		} else {
			template = parseTemplateExpression(true /*isTaggedTemplate*/);
		}
		var isOptionalChain = questionDotToken != null || tag.Flags&NodeFlagsOptionalChain != 0;
		return checkJSSyntax(finishNode(factory.NewTaggedTemplateExpression(tag, questionDotToken, typeArguments, template, (isOptionalChain ? NodeFlagsOptionalChain : NodeFlagsNone)), pos));
	}

	function parseTemplateExpression(isTaggedTemplate:Bool):Expression {
		var pos = nodePos();
		return finishNode(factory.NewTemplateExpression(parseTemplateHead(isTaggedTemplate), parseTemplateSpans(isTaggedTemplate)), pos);
	}

	function parseTemplateSpans(isTaggedTemplate:Bool):NodeList {
		var pos = nodePos();
		var list:Array<Node> = null;
		while (true) {
			var span = parseTemplateSpan(isTaggedTemplate);
			list = append(list, span);
			if (span.AsTemplateSpan().Literal.Kind != KindTemplateMiddle) {
				break;
			}
		}
		return newNodeList(Core.NewTextRange(pos, nodePos()), list);
	}

	function parseTemplateSpan(isTaggedTemplate:Bool):Node {
		var pos = nodePos();
		var expression = parseExpressionAllowIn();
		var literal = parseLiteralOfTemplateSpan(isTaggedTemplate);
		return finishNode(factory.NewTemplateSpan(expression, literal), pos);
	}

	function parsePrimaryExpression():Expression {
		switch (token) {
		case KindNoSubstitutionTemplateLiteral:
			if (scanner.TokenFlags() & TokenFlagsIsInvalid != 0) {
				reScanTemplateToken(false /*isTaggedTemplate*/);
			}
			// PORT: fallthrough
			return parseLiteralExpression(false /*intern*/);
		case KindNumericLiteral | KindBigIntLiteral | KindStringLiteral:
			return parseLiteralExpression(false /*intern*/);
		case KindThisKeyword | KindSuperKeyword | KindNullKeyword | KindTrueKeyword | KindFalseKeyword:
			return parseKeywordExpression();
		case KindOpenParenToken:
			return parseParenthesizedExpression();
		case KindOpenBracketToken:
			return parseArrayLiteralExpression();
		case KindOpenBraceToken:
			return parseObjectLiteralExpression();
		case KindAsyncKeyword:
			// Async arrow functions are parsed earlier in parseAssignmentExpressionOrHigher.
			// If we encounter `async [no LineTerminator here] function` then this is an async
			// function; otherwise, its an identifier.
			// PORT: Go `break` out of the switch unless `async function` follows.
			if (lookAhead(fn_nextTokenIsFunctionKeywordOnSameLine)) {
				return parseFunctionExpression();
			}
		case KindAtToken:
			return parseDecoratedExpression();
		case KindClassKeyword:
			return parseClassExpression();
		case KindFunctionKeyword:
			return parseFunctionExpression();
		case KindNewKeyword:
			return parseNewExpressionOrNewDotTarget();
		case KindSlashToken | KindSlashEqualsToken:
			if (reScanSlashToken() == KindRegularExpressionLiteral) {
				return parseLiteralExpression(false /*intern*/);
			}
		case KindTemplateHead:
			return parseTemplateExpression(false /*isTaggedTemplate*/);
		case KindPrivateIdentifier:
			return parsePrivateIdentifier();
		default:
		}
		return parseIdentifierWithDiagnostic(Diagnostics.Expression_expected, null);
	}

	function parseParenthesizedExpression():Expression {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		parseExpected(KindOpenParenToken);
		var expression = parseExpressionAllowIn();
		parseExpected(KindCloseParenToken);
		var result = finishNode(factory.NewParenthesizedExpression(expression), pos);
		this.withJSDoc(result, jsdoc);
		return result;
	}

	function parseArrayLiteralExpression():Expression {
		var pos = nodePos();
		var openBracketPosition = scanner.TokenStart();
		var openBracketParsed = parseExpected(KindOpenBracketToken);
		var multiLine = hasPrecedingLineBreak();
		var elements = parseDelimitedList(PCArrayLiteralMembers, fn_parseArgumentOrArrayLiteralElement);
		parseExpectedMatchingBrackets(KindOpenBracketToken, KindCloseBracketToken, openBracketParsed, openBracketPosition);
		return finishNode(factory.NewArrayLiteralExpression(elements, multiLine), pos);
	}

	function parseObjectLiteralExpression():Expression {
		var pos = nodePos();
		var openBracePosition = scanner.TokenStart();
		var openBraceParsed = parseExpected(KindOpenBraceToken);
		var multiLine = hasPrecedingLineBreak();
		var properties = parseDelimitedList(PCObjectLiteralMembers, fn_parseObjectLiteralElement);
		parseExpectedMatchingBrackets(KindOpenBraceToken, KindCloseBraceToken, openBraceParsed, openBracePosition);
		return finishNode(factory.NewObjectLiteralExpression(properties, multiLine), pos);
	}

	function parseObjectLiteralElement():Node {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		if (parseOptional(KindDotDotDotToken)) {
			var expression = parseAssignmentExpressionOrHigher();
			var result = finishNode(factory.NewSpreadAssignment(expression), pos);
			this.withJSDoc(result, jsdoc);
			return result;
		}
		var modifiers = parseModifiersEx(true /*allowDecorators*/, false /*permitConstAsModifier*/, false /*stopOnStartOfClassStaticBlock*/);
		if (parseContextualModifier(KindGetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindGetAccessor, ParseFlagsNone);
		}
		if (parseContextualModifier(KindSetKeyword)) {
			return parseAccessorDeclaration(pos, jsdoc, modifiers, KindSetAccessor, ParseFlagsNone);
		}
		var asteriskToken = parseOptionalToken(KindAsteriskToken);
		var tokenIsIdentifier = isIdentifier();
		var name = parsePropertyName();
		// Disallowing of optional property assignments and definite assignment assertion happens in the grammar checker.
		var postfixToken = parseOptionalToken(KindQuestionToken);
		// Decorators, Modifiers, questionToken, and exclamationToken are not supported by property assignments and are reported in the grammar checker
		if (postfixToken == null) {
			postfixToken = parseOptionalToken(KindExclamationToken);
		}
		if (asteriskToken != null || token == KindOpenParenToken || token == KindLessThanToken) {
			return parseMethodDeclaration(pos, jsdoc, modifiers, asteriskToken, name, postfixToken, null /*diagnosticMessage*/);
		}
		// check if it is short-hand property assignment or normal property assignment
		// NOTE: if token is EqualsToken it is interpreted as CoverInitializedName production
		// CoverInitializedName[Yield] :
		//     IdentifierReference[?Yield] Initializer[In, ?Yield]
		// this is necessary because ObjectLiteral productions are also used to cover grammar for ObjectAssignmentPattern
		var node:Node = null;
		var isShorthandPropertyAssignment = tokenIsIdentifier && token != KindColonToken;
		if (isShorthandPropertyAssignment) {
			var equalsToken = parseOptionalToken(KindEqualsToken);
			var initializer:Expression = null;
			if (equalsToken != null) {
				initializer = doInContext(this, NodeFlagsDisallowInContext, false, fn_parseAssignmentExpressionOrHigher);
			}
			node = factory.NewShorthandPropertyAssignment(modifiers, name, postfixToken, null /*typeNode*/, equalsToken, initializer);
		} else {
			parseExpected(KindColonToken);
			var initializer = doInContext(this, NodeFlagsDisallowInContext, false, fn_parseAssignmentExpressionOrHigher);
			node = factory.NewPropertyAssignment(modifiers, name, postfixToken, null /*typeNode*/, initializer);
		}
		finishNode(node, pos);
		this.withJSDoc(node, jsdoc);
		return node;
	}

	function parseFunctionExpression():Expression {
		// GeneratorExpression:
		//      function* BindingIdentifier [Yield][opt](FormalParameters[Yield]){ GeneratorBody }
		//
		// FunctionExpression:
		//      function BindingIdentifier[opt](FormalParameters){ FunctionBody }
		var saveContexFlags = contextFlags;
		setContextFlags(NodeFlagsDecoratorContext, false);
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiers();
		parseExpected(KindFunctionKeyword);
		var asteriskToken = parseOptionalToken(KindAsteriskToken);
		var isGenerator = asteriskToken != null;
		var isAsync = modifierListHasAsync(modifiers);
		var signatureFlags = (isGenerator ? ParseFlagsYield : ParseFlagsNone) | (isAsync ? ParseFlagsAwait : ParseFlagsNone);
		var name:Node = null;
		// PORT: tagless switch → if/else chain.
		if (isGenerator && isAsync) {
			name = doInContext(this, NodeFlagsYieldContext | NodeFlagsAwaitContext, true, fn_parseOptionalBindingIdentifier);
		} else if (isGenerator) {
			name = doInContext(this, NodeFlagsYieldContext, true, fn_parseOptionalBindingIdentifier);
		} else if (isAsync) {
			name = doInContext(this, NodeFlagsAwaitContext, true, fn_parseOptionalBindingIdentifier);
		} else {
			name = parseOptionalBindingIdentifier();
		}
		var typeParameters = parseTypeParameters();
		var parameters = parseParameters(signatureFlags);
		var returnType = parseReturnType(KindColonToken, false /*isType*/);
		var body = parseFunctionBlock(signatureFlags, null /*diagnosticMessage*/);
		contextFlags = saveContexFlags;
		var result = factory.NewFunctionExpression(modifiers, asteriskToken, name, typeParameters, parameters, returnType, null /*fullSignature*/, body);
		finishNode(result, pos);
		this.withJSDoc(result, jsdoc);
		checkJSSyntax(result);
		return result;
	}

	function parseOptionalBindingIdentifier():Node {
		if (isBindingIdentifier()) {
			return parseBindingIdentifier();
		}
		return null;
	}

	function parseDecoratedExpression():Expression {
		var pos = nodePos();
		var jsdoc = jsdocScannerInfo();
		var modifiers = parseModifiersEx(true /*allowDecorators*/, false /*permitConstAsModifier*/, false /*stopOnStartOfClassStaticBlock*/);
		if (token == KindClassKeyword) {
			return parseClassDeclarationOrExpression(pos, jsdoc, modifiers, KindClassExpression);
		}
		parseErrorAt(nodePos(), nodePos(), Diagnostics.Expression_expected);
		return finishNode(factory.NewMissingDeclaration(modifiers), pos);
	}

	function unparseExpressionWithTypeArguments(expression:Node, typeArguments:NodeList, result:Node):Void {
		// force overwrite the `.Parent` of the expression and type arguments to erase the fact that they may have originally been parsed as an ExpressionWithTypeArguments and be parented to such
		if (expression != null) {
			expression.Parent = result;
		}
		if (typeArguments != null) {
			for (a in nodesOf(typeArguments.Nodes)) {
				a.Parent = result;
			}
		}
	}

	function parseNewExpressionOrNewDotTarget():Node {
		var pos = nodePos();
		parseExpected(KindNewKeyword);
		if (parseOptional(KindDotToken)) {
			var name = parseIdentifierName();
			return finishNode(factory.NewMetaProperty(KindNewKeyword, name), pos);
		}
		var expressionPos = nodePos();
		var expression = parseMemberExpressionRest(expressionPos, parsePrimaryExpression(), false /*allowOptionalChain*/);
		var typeArguments:NodeList = null;
		// Absorb type arguments into NewExpression when preceding expression is ExpressionWithTypeArguments
		if (expression.Kind == KindExpressionWithTypeArguments) {
			typeArguments = expression.TypeArgumentList();
			expression = expression.AsExpressionWithTypeArguments().Expression;
		}
		if (token == KindQuestionDotToken) {
			parseErrorAtCurrentToken(Diagnostics.Invalid_optional_chain_from_new_expression_Did_you_mean_to_call_0, Scanner.GetTextOfNodeFromSourceText(sourceText, expression, false /*includeTrivia*/));
		}
		var argumentList:NodeList = null;
		if (token == KindOpenParenToken) {
			argumentList = parseArgumentList();
		}
		var result = checkJSSyntax(finishNode(factory.NewNewExpression(expression, typeArguments, argumentList), pos));
		unparseExpressionWithTypeArguments(expression, typeArguments, result);
		return result;
	}

	function parseKeywordExpression():Node {
		var pos = nodePos();
		var result = factory.NewKeywordExpression(token);
		nextToken();
		return finishNode(result, pos);
	}

	function parseLiteralExpression(intern:Bool):Node {
		var pos = nodePos();
		var text = scanner.TokenValue();
		if (intern) {
			text = internIdentifier(text);
		}
		var tokenFlags = scanner.TokenFlags();
		var result:Node = null;
		switch (token) {
		case KindStringLiteral:
			result = factory.NewStringLiteral(text, tokenFlags);
		case KindNumericLiteral:
			result = factory.NewNumericLiteral(text, tokenFlags);
		case KindBigIntLiteral:
			result = factory.NewBigIntLiteral(text, tokenFlags);
		case KindRegularExpressionLiteral:
			result = factory.NewRegularExpressionLiteral(text, tokenFlags);
		case KindNoSubstitutionTemplateLiteral:
			result = factory.NewNoSubstitutionTemplateLiteral(text, tokenFlags);
		default:
			throw "Unhandled case in parseLiteralExpression";
		}
		nextToken();
		return finishNode(result, pos);
	}

	function parseIdentifierNameErrorOnUnicodeEscapeSequence():Node {
		if (scanner.HasUnicodeEscape() || scanner.HasExtendedUnicodeEscape()) {
			parseErrorAtCurrentToken(Diagnostics.Unicode_escape_sequence_cannot_appear_here);
		}
		return createIdentifier(tokenIsIdentifierOrKeyword(token));
	}

	function parseBindingIdentifier():Node {
		return parseBindingIdentifierWithDiagnostic(null);
	}

	function parseBindingIdentifierWithDiagnostic(privateIdentifierDiagnosticMessage:Message):Node {
		var saveHasAwaitIdentifier = statementHasAwaitIdentifier;
		var id = createIdentifierWithDiagnostic(isBindingIdentifier(), null /*diagnosticMessage*/, privateIdentifierDiagnosticMessage);
		statementHasAwaitIdentifier = saveHasAwaitIdentifier;
		return id;
	}

	function parseIdentifierName():Node {
		return parseIdentifierNameWithDiagnostic(null);
	}

	function parseIdentifierNameWithDiagnostic(diagnosticMessage:Message):Node {
		return createIdentifierWithDiagnostic(tokenIsIdentifierOrKeyword(token), diagnosticMessage, null);
	}

	function parseIdentifier():Node {
		return parseIdentifierWithDiagnostic(null, null);
	}

	function parseIdentifierWithDiagnostic(diagnosticMessage:Message, privateIdentifierDiagnosticMessage:Message):Node {
		return createIdentifierWithDiagnostic(isIdentifier(), diagnosticMessage, privateIdentifierDiagnosticMessage);
	}

	function createIdentifier(isIdentifier:Bool):Node {
		return createIdentifierWithDiagnostic(isIdentifier, null, null);
	}

	function createIdentifierWithDiagnostic(isIdentifier:Bool, diagnosticMessage:Message, privateIdentifierDiagnosticMessage:Message):Node {
		if (isIdentifier) {
			var pos:Int = 0;
			if (scanner.HasPrecedingJSDocLeadingAsterisks()) {
				pos = scanner.TokenStart();
			} else {
				pos = nodePos();
			}
			var text = scanner.TokenValue();
			nextTokenWithoutCheck();
			return finishNode(newIdentifier(internIdentifier(text)), pos);
		}
		if (token == KindPrivateIdentifier) {
			if (privateIdentifierDiagnosticMessage != null) {
				parseErrorAtCurrentToken(privateIdentifierDiagnosticMessage);
			} else {
				parseErrorAtCurrentToken(Diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies);
			}
			return createIdentifier(true /*isIdentifier*/);
		}
		// Only for end of file because the error gets reported incorrectly on embedded script tags.
		var reportAtCurrentPosition = token == KindEndOfFile;
		if (diagnosticMessage != null) {
			if (reportAtCurrentPosition) {
				var pos = scanner.TokenFullStart();
				parseErrorAt(pos, pos, diagnosticMessage);
			} else {
				parseErrorAtCurrentToken(diagnosticMessage);
			}
		} else if (isReservedWord(token)) {
			if (reportAtCurrentPosition) {
				var pos = scanner.TokenFullStart();
				parseErrorAt(pos, pos, Diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, scanner.TokenText());
			} else {
				parseErrorAtCurrentToken(Diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, scanner.TokenText());
			}
		} else {
			if (reportAtCurrentPosition) {
				var pos = scanner.TokenFullStart();
				parseErrorAt(pos, pos, Diagnostics.Identifier_expected);
			} else {
				parseErrorAtCurrentToken(Diagnostics.Identifier_expected);
			}
		}
		return createMissingIdentifier();
	}

	function internIdentifier(text:String):String {
		if (identifiers != null) {
			final identifier = identifiers.get(text);
			if (identifier != null) {
				return identifier;
			}
		}
		var identifier = Strings.Intern(text); // PORT: perf — hash computed once (symbol table lookups)
		if (identifiers == null) {
			identifiers = new StringMap<String>();
		}
		identifiers.set(identifier, identifier);
		return identifier;
	}

	// PORT: inline so the TextRange argument (a Go value) is not allocated.
	inline function newNodeList(loc:TextRange, nodes:Array<Node>):NodeList {
		var list = factory.NewNodeList(nodes);
		list.Loc = loc;
		return list;
	}

	// PORT: inline so the TextRange argument (a Go value) is not allocated.
	inline function newModifierList(loc:TextRange, nodes:Array<Node>):ModifierList {
		var list = factory.NewModifierList(nodes);
		list.Loc = loc;
		return list;
	}

	function finishNode(node:Node, pos:Int):Node {
		return finishNodeWithEnd(node, pos, nodePos());
	}

	function finishNodeWithEnd(node:Node, pos:Int, end:Int):Node {
		node.Loc = Core.NewTextRange(pos, end);
		node.Flags |= contextFlags;
		if (hasParseError) {
			node.Flags |= NodeFlagsThisNodeHasError;
			hasParseError = false;
		}
		overrideParentInImmediateChildren(node);
		return node;
	}

	function overrideParentInImmediateChildren(node:Node):Void {
		currentParent = node;
		node.ForEachChild(setParentFromContext);
		currentParent = null;
	}

	function nextTokenIsSlash():Bool {
		return nextToken() == KindSlashToken;
	}

	function scanTypeMemberStart():Bool {
		// Return true if we have the start of a signature member
		if (token == KindOpenParenToken || token == KindLessThanToken || token == KindGetKeyword || token == KindSetKeyword) {
			return true;
		}
		var idToken = false;
		// Eat up all modifiers, but hold on to the last one in case it is actually an identifier
		while (Ast.IsModifierKind(token)) {
			idToken = true;
			nextToken();
		}
		// Index signatures and computed property names are type members
		if (token == KindOpenBracketToken) {
			return true;
		}
		// Try to get the first property-like token following all modifiers
		if (isLiteralPropertyName()) {
			idToken = true;
			nextToken();
		}
		// If we were able to get any potential identifier, check that it is
		// the start of a member declaration
		if (idToken) {
			return token == KindOpenParenToken || token == KindLessThanToken || token == KindQuestionToken || token == KindColonToken || token == KindCommaToken || canParseSemicolon();
		}
		return false;
	}

	function scanClassMemberStart():Bool {
		var idToken = KindUnknown;
		if (token == KindAtToken) {
			return true;
		}
		// Eat up all modifiers, but hold on to the last one in case it is actually an identifier.
		while (Ast.IsModifierKind(token)) {
			idToken = token;
			// If the idToken is a class modifier (protected, private, public, and static), it is
			// certain that we are starting to parse class member. This allows better error recovery
			// Example:
			//      public foo() ...     // true
			//      public @dec blah ... // true; we will then report an error later
			//      export public ...    // true; we will then report an error later
			if (Ast.IsClassMemberModifier(idToken)) {
				return true;
			}
			nextToken();
		}
		if (token == KindAsteriskToken) {
			return true;
		}
		// Try to get the first property-like token following all modifiers.
		// This can either be an identifier or the 'get' or 'set' keywords.
		if (isLiteralPropertyName()) {
			idToken = token;
			nextToken();
		}
		// Index signatures and computed properties are class members; we can parse.
		if (token == KindOpenBracketToken) {
			return true;
		}
		// If we were able to get any potential identifier...
		if (idToken != KindUnknown) {
			// If we have a non-keyword identifier, or if we have an accessor, then it's safe to parse.
			if (!Ast.IsKeyword(idToken) || idToken == KindSetKeyword || idToken == KindGetKeyword) {
				return true;
			}
			// If it *is* a keyword, but not an accessor, check a little farther along
			// to see if it should actually be parsed as a class member.
			switch (token) {
			case KindOpenParenToken // Method declaration
				| KindLessThanToken // Generic Method declaration
				| KindExclamationToken // Non-null assertion on property name
				| KindColonToken // Type Annotation for declaration
				| KindEqualsToken // Initializer for declaration
				| KindQuestionToken: // Not valid, but permitted so that it gets caught later on.
				return true;
			default:
			}
			// Covers
			//  - Semicolons     (declaration termination)
			//  - Closing braces (end-of-class, must be declaration)
			//  - End-of-files   (not valid, but permitted so that it gets caught later on)
			//  - Line-breaks    (enabling *automatic semicolon insertion*)
			return canParseSemicolon();
		}
		return false;
	}

	function canParseSemicolon():Bool {
		// If there's a real semicolon, then we can always parse it out.
		// We can parse out an optional semicolon in ASI cases in the following cases.
		return token == KindSemicolonToken || token == KindCloseBraceToken || token == KindEndOfFile || hasPrecedingLineBreak();
	}

	function tryParseSemicolon():Bool {
		if (!canParseSemicolon()) {
			return false;
		}
		if (token == KindSemicolonToken) {
			// consume the semicolon if it was explicitly provided.
			nextToken();
		}
		return true;
	}

	function parseSemicolon():Bool {
		return tryParseSemicolon() || parseExpected(KindSemicolonToken);
	}

	function isLiteralPropertyName():Bool {
		return tokenIsIdentifierOrKeyword(token) || token == KindStringLiteral || token == KindNumericLiteral || token == KindBigIntLiteral;
	}

	function isStartOfStatement():Bool {
		switch (token) {
		// 'catch' and 'finally' do not actually indicate that the code is part of a statement,
		// however, we say they are here so that we may gracefully parse them and error later.
		case KindAtToken | KindSemicolonToken | KindOpenBraceToken | KindVarKeyword | KindLetKeyword | KindUsingKeyword | KindFunctionKeyword | KindClassKeyword | KindEnumKeyword | KindIfKeyword | KindDoKeyword | KindWhileKeyword | KindForKeyword | KindContinueKeyword | KindBreakKeyword | KindReturnKeyword | KindWithKeyword | KindSwitchKeyword | KindThrowKeyword | KindTryKeyword | KindDebuggerKeyword | KindCatchKeyword | KindFinallyKeyword:
			return true;
		case KindImportKeyword:
			return isStartOfDeclaration() || isNextTokenOpenParenOrLessThanOrDot();
		case KindConstKeyword | KindExportKeyword:
			return isStartOfDeclaration();
		case KindAsyncKeyword | KindDeclareKeyword | KindInterfaceKeyword | KindModuleKeyword | KindNamespaceKeyword | KindTypeKeyword | KindGlobalKeyword | KindDeferKeyword:
			// When these don't start a declaration, they're an identifier in an expression statement
			return true;
		case KindAccessorKeyword | KindPublicKeyword | KindPrivateKeyword | KindProtectedKeyword | KindStaticKeyword | KindReadonlyKeyword:
			// When these don't start a declaration, they may be the start of a class member if an identifier
			// immediately follows. Otherwise they're an identifier in an expression statement.
			return isStartOfDeclaration() || !lookAhead(fn_nextTokenIsIdentifierOrKeywordOnSameLine);

		default:
			return isStartOfExpression();
		}
	}

	function isStartOfDeclaration():Bool {
		return lookAhead(fn_scanStartOfDeclaration);
	}

	function scanStartOfDeclaration():Bool {
		while (true) {
			switch (token) {
			case KindVarKeyword | KindLetKeyword | KindConstKeyword | KindFunctionKeyword | KindClassKeyword | KindEnumKeyword:
				return true;
			case KindUsingKeyword:
				return isUsingDeclaration();
			case KindAwaitKeyword:
				return isAwaitUsingDeclaration();
			// 'declare', 'module', 'namespace', 'interface'* and 'type' are all legal JavaScript identifiers;
			// however, an identifier cannot be followed by another identifier on the same line. This is what we
			// count on to parse out the respective declarations. For instance, we exploit this to say that
			//
			//    namespace n
			//
			// can be none other than the beginning of a namespace declaration, but need to respect that JavaScript sees
			//
			//    namespace
			//    n
			//
			// as the identifier 'namespace' on one line followed by the identifier 'n' on another.
			// We need to look one token ahead to see if it permissible to try parsing a declaration.
			//
			// *Note*: 'interface' is actually a strict mode reserved word. So while
			//
			//   "use strict"
			//   interface
			//   I {}
			//
			// could be legal, it would add complexity for very little gain.
			case KindInterfaceKeyword | KindTypeKeyword | KindDeferKeyword:
				return nextTokenIsIdentifierOnSameLine();
			case KindModuleKeyword | KindNamespaceKeyword:
				return nextTokenIsIdentifierOrStringLiteralOnSameLine();
			case KindAbstractKeyword | KindAccessorKeyword | KindAsyncKeyword | KindDeclareKeyword | KindPrivateKeyword | KindProtectedKeyword | KindPublicKeyword | KindReadonlyKeyword:
				var previousToken = token;
				nextToken();
				// ASI takes effect for this modifier.
				if (hasPrecedingLineBreak()) {
					return false;
				}
				if (previousToken == KindDeclareKeyword && token == KindTypeKeyword) {
					// If we see 'declare type', then commit to parsing a type alias. parseTypeAliasDeclaration will
					// report Line_break_not_permitted_here if needed.
					return true;
				}
				continue;
			case KindGlobalKeyword:
				nextToken();
				return token == KindOpenBraceToken || token == KindIdentifier || token == KindExportKeyword;
			case KindImportKeyword:
				nextToken();
				return token == KindDeferKeyword || token == KindStringLiteral || token == KindAsteriskToken || token == KindOpenBraceToken || tokenIsIdentifierOrKeyword(token);
			case KindExportKeyword:
				nextToken();
				if (token == KindEqualsToken || token == KindAsteriskToken || token == KindOpenBraceToken ||
					token == KindDefaultKeyword || token == KindAsKeyword || token == KindAtToken) {
					return true;
				}
				if (token == KindTypeKeyword) {
					nextToken();
					return token == KindAsteriskToken || token == KindOpenBraceToken || isIdentifier() && !hasPrecedingLineBreak();
				}
				continue;
			case KindStaticKeyword:
				nextToken();
				continue;
			default:
			}
			return false;
		}
	}

	function isStartOfExpression():Bool {
		if (isStartOfLeftHandSideExpression()) {
			return true;
		}
		switch (token) {
		case KindPlusToken | KindMinusToken | KindTildeToken | KindExclamationToken | KindDeleteKeyword | KindTypeOfKeyword | KindVoidKeyword | KindPlusPlusToken | KindMinusMinusToken | KindLessThanToken | KindAwaitKeyword | KindYieldKeyword | KindPrivateIdentifier | KindAtToken:
			// Yield/await always starts an expression.  Either it is an identifier (in which case
			// it is definitely an expression).  Or it's a keyword (either because we're in
			// a generator or async function, or in strict mode (or both)) and it started a yield or await expression.
			return true;
		default:
		}
		// Error tolerance.  If we see the start of some binary operator, we consider
		// that the start of an expression.  That way we'll parse out a missing identifier,
		// give a good message about an identifier being missing, and then consume the
		// rest of the binary expression.
		if (isBinaryOperator()) {
			return true;
		}
		return isIdentifier();
	}

	function isStartOfLeftHandSideExpression():Bool {
		switch (token) {
		case KindThisKeyword | KindSuperKeyword | KindNullKeyword | KindTrueKeyword | KindFalseKeyword | KindNumericLiteral | KindBigIntLiteral | KindStringLiteral | KindNoSubstitutionTemplateLiteral | KindTemplateHead | KindOpenParenToken | KindOpenBracketToken | KindOpenBraceToken | KindFunctionKeyword | KindClassKeyword | KindNewKeyword | KindSlashToken | KindSlashEqualsToken | KindIdentifier:
			return true;
		case KindImportKeyword:
			return isNextTokenOpenParenOrLessThanOrDot();
		default:
		}
		return isIdentifier();
	}

	function isStartOfType(inStartOfParameter:Bool):Bool {
		switch (token) {
		case KindAnyKeyword | KindUnknownKeyword | KindStringKeyword | KindNumberKeyword | KindBigIntKeyword | KindBooleanKeyword | KindReadonlyKeyword | KindSymbolKeyword | KindUniqueKeyword | KindVoidKeyword | KindUndefinedKeyword | KindNullKeyword | KindThisKeyword | KindTypeOfKeyword | KindNeverKeyword | KindOpenBraceToken | KindOpenBracketToken | KindLessThanToken | KindBarToken | KindAmpersandToken | KindNewKeyword | KindStringLiteral | KindNumericLiteral | KindBigIntLiteral | KindTrueKeyword | KindFalseKeyword | KindObjectKeyword | KindAsteriskToken | KindQuestionToken | KindExclamationToken | KindDotDotDotToken | KindInferKeyword | KindImportKeyword | KindAssertsKeyword | KindNoSubstitutionTemplateLiteral | KindTemplateHead:
			return true;
		case KindFunctionKeyword:
			return !inStartOfParameter;
		case KindMinusToken:
			return !inStartOfParameter && lookAhead(fn_nextTokenIsNumericOrBigIntLiteral);
		case KindOpenParenToken:
			// Only consider '(' the start of a type if followed by ')', '...', an identifier, a modifier,
			// or something that starts a type. We don't want to consider things like '(1)' a type.
			return !inStartOfParameter && lookAhead(fn_nextIsParenthesizedOrFunctionType);
		default:
		}
		return isIdentifier();
	}

	function nextTokenIsNumericOrBigIntLiteral():Bool {
		nextToken();
		return token == KindNumericLiteral || token == KindBigIntLiteral;
	}

	function nextIsParenthesizedOrFunctionType():Bool {
		nextToken();
		return token == KindCloseParenToken || isStartOfParameter(false /*isJSDocParameter*/) || isStartOfType(false /*inStartOfParameter*/);
	}

	function isStartOfParameter(isJSDocParameter:Bool):Bool {
		return token == KindDotDotDotToken ||
			isBindingIdentifierOrPrivateIdentifierOrPattern() ||
			Ast.IsModifierKind(token) ||
			token == KindAtToken ||
			isStartOfType(!isJSDocParameter /*inStartOfParameter*/);
	}

	function isBindingIdentifierOrPrivateIdentifierOrPattern():Bool {
		return token == KindOpenBraceToken || token == KindOpenBracketToken || token == KindPrivateIdentifier || isBindingIdentifier();
	}

	function isNextTokenOpenParenOrLessThanOrDot():Bool {
		return lookAhead(fn_nextTokenIsOpenParenOrLessThanOrDot);
	}

	function nextTokenIsOpenParenOrLessThanOrDot():Bool {
		switch (nextToken()) {
		case KindOpenParenToken | KindLessThanToken | KindDotToken:
			return true;
		default:
		}
		return false;
	}

	function nextTokenIsIdentifierOnSameLine():Bool {
		nextToken();
		return isIdentifier() && !hasPrecedingLineBreak();
	}

	function nextTokenIsIdentifierOrStringLiteralOnSameLine():Bool {
		nextToken();
		return (isIdentifier() || token == KindStringLiteral) && !hasPrecedingLineBreak();
	}

	// Ignore strict mode flag because we will report an error in type checker instead.
	function isIdentifier():Bool {
		if (token == KindIdentifier) {
			return true;
		}
		// If we have a 'yield' keyword, and we're in the [yield] context, then 'yield' is
		// considered a keyword and is not an identifier.
		// If we have a 'await' keyword, and we're in the [Await] context, then 'await' is
		// considered a keyword and is not an identifier.
		if (token == KindYieldKeyword && inYieldContext() || token == KindAwaitKeyword && inAwaitContext()) {
			return false;
		}
		return token > KindLastReservedWord;
	}

	function isBindingIdentifier():Bool {
		// `let await`/`let yield` in [Yield] or [Await] are allowed here and disallowed in the binder.
		return token == KindIdentifier || token > KindLastReservedWord;
	}

	function isImportAttributeName():Bool {
		return tokenIsIdentifierOrKeyword(token) || token == KindStringLiteral;
	}

	function isBinaryOperator():Bool {
		if (inDisallowInContext() && token == KindInKeyword) {
			return false;
		}
		return Ast.GetBinaryOperatorPrecedence(token) != OperatorPrecedenceInvalid;
	}

	function isValidHeritageClauseObjectLiteral():Bool {
		return lookAhead(fn_nextIsValidHeritageClauseObjectLiteral);
	}

	function nextIsValidHeritageClauseObjectLiteral():Bool {
		if (nextToken() == KindCloseBraceToken) {
			// if we see "extends {}" then only treat the {} as what we're extending (and not
			// the class body) if we have:
			//
			//      extends {} {
			//      extends {},
			//      extends {} extends
			//      extends {} implements
			var next = nextToken();
			return next == KindCommaToken || next == KindOpenBraceToken || next == KindExtendsKeyword || next == KindImplementsKeyword;
		}
		return true;
	}

	function isHeritageClause():Bool {
		return token == KindExtendsKeyword || token == KindImplementsKeyword;
	}

	function isHeritageClauseExtendsOrImplementsKeyword():Bool {
		return isHeritageClause() && lookAhead(fn_nextIsStartOfExpression);
	}

	function nextIsStartOfExpression():Bool {
		nextToken();
		return isStartOfExpression();
	}

	function isUsingDeclaration():Bool {
		// 'using' always starts a lexical declaration if followed by an identifier. We also eagerly parse
		// |ObjectBindingPattern| so that we can report a grammar error during check. We don't parse out
		// |ArrayBindingPattern| since it potentially conflicts with element access (i.e., `using[x]`).
		return lookAhead(fl_isUsingDeclaration);
	}

	// PORT: Go func literal without captures → created once.
	static final fl_isUsingDeclaration:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine( /*disallowOf*/ false);
	};

	function nextTokenIsEqualsOrSemicolonOrColonToken():Bool {
		nextToken();
		return token == KindEqualsToken || token == KindSemicolonToken || token == KindColonToken;
	}

	function nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine(disallowOf:Bool):Bool {
		nextToken();
		if (disallowOf && token == KindOfKeyword) {
			return lookAhead(fn_nextTokenIsEqualsOrSemicolonOrColonToken);
		}
		return (isBindingIdentifier() || token == KindOpenBraceToken) && !hasPrecedingLineBreak();
	}

	function nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf():Bool {
		return nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine( /*disallowOf*/ true);
	}

	function isAwaitUsingDeclaration():Bool {
		return lookAhead(fn_nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine);
	}

	function nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine():Bool {
		return nextToken() == KindUsingKeyword && nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine( /*disallowOf*/ false);
	}

	function nextTokenIsTokenStringLiteral():Bool {
		return nextToken() == KindStringLiteral;
	}

	function setContextFlags(flags:NodeFlags, value:Bool):Void {
		if (value) {
			contextFlags |= flags;
		} else {
			contextFlags &= ~(flags);
		}
	}

	static function doInContext<T>(p:Parser, flags:NodeFlags, value:Bool, f:(p:Parser) -> T):T {
		var saveContextFlags = p.contextFlags;
		p.setContextFlags(flags, value);
		var result = f(p);
		p.contextFlags = saveContextFlags;
		return result;
	}

	function inYieldContext():Bool {
		return contextFlags&NodeFlagsYieldContext != 0;
	}

	function inDisallowInContext():Bool {
		return contextFlags&NodeFlagsDisallowInContext != 0;
	}

	function inDisallowConditionalTypesContext():Bool {
		return contextFlags&NodeFlagsDisallowConditionalTypesContext != 0;
	}

	function inDecoratorContext():Bool {
		return contextFlags&NodeFlagsDecoratorContext != 0;
	}

	function inAwaitContext():Bool {
		return contextFlags&NodeFlagsAwaitContext != 0;
	}

	function skipRangeTrivia(textRange:TextRange):TextRange {
		return Core.NewTextRange(Scanner.SkipTrivia(sourceText, textRange.Pos()), textRange.End());
	}

	static function isReservedWord(token:Kind):Bool {
		return KindFirstReservedWord <= token && token <= KindLastReservedWord;
	}

	static function attachFileToDiagnostics(diagnostics:Array<Diagnostic>, file:SourceFile):Array<Diagnostic> {
		if (diagnostics != null) {
			for (d in diagnostics) {
				d.SetFile(file);
				final related = d.RelatedInformation();
				if (related != null) {
					for (r in related) {
						r.SetFile(file);
					}
				}
			}
		}
		return diagnostics;
	}

	static function getCommentPragmas(f:NodeFactory, sourceText:String):Array<Pragma> {
		var pragmas:Array<Pragma> = null;
		for (commentRange in Scanner.GetLeadingCommentRanges(f, sourceText, 0)) {
			var comment = sourceText.substring(commentRange.Pos(), commentRange.End());
			pragmas = appendAll(pragmas, extractPragmas(commentRange, comment));
		}
		return pragmas;
	}

	static function extractPragmas(commentRange:CommentRange, text:String):Array<Pragma> {
		if (commentRange.Kind == KindSingleLineCommentTrivia) {
			var pos = 2;
			var tripleSlash = match(text, pos, "/");
			if (tripleSlash) {
				pos++;
			}
			pos = skipBlanks(text, pos);
			if (tripleSlash && match(text, pos, "<")) {
				var tagName = extractName(text, pos + 1);
				if (tagName != "reference") {
					return null;
				}
				pos += 10;
				var args = new StringMap<PragmaArgument>();
				while (true) {
					pos = skipBlanks(text, pos);
					if (match(text, pos, "/>")) {
						break;
					}
					var argName = extractName(text, pos);
					if (argName == "") {
						break;
					}
					pos = skipBlanks(text, pos + argName.length);
					if (!match(text, pos, "=")) {
						break;
					}
					pos = skipBlanks(text, pos + 1);
					var value = extractQuotedString(text, pos);
					if (value == null) {
						break;
					}
					final arg = new PragmaArgument();
					arg.Name = argName;
					arg.Value = value;
					arg.TextRange = Core.NewTextRange(commentRange.Pos() + pos + 1, commentRange.Pos() + pos + 1 + value.length);
					args.set(argName, arg);
					pos += value.length + 2;
				}
				final pragma = new Pragma();
				pragma.CommentRange = commentRange;
				pragma.Name = "reference";
				pragma.Args = args;
				return [pragma];
			}
			if (match(text, pos, "@")) {
				pos++;
				var pragmaName = extractName(text, pos);
				if (!(pragmaName == "ts-check" || pragmaName == "ts-nocheck")) {
					return null;
				}
				final pragma = new Pragma();
				pragma.CommentRange = commentRange;
				pragma.Name = pragmaName;
				return [pragma];
			}
		}
		if (commentRange.Kind == KindMultiLineCommentTrivia) {
			text = Strings.TrimSuffix(text, "*/");
			var pos = 2;
			var pragmas:Array<Pragma> = null;
			while (true) {
				if ((pos = skipTo(text, pos, "@")) < 0) {
					break;
				}
				// Mirrors the /@(\S+)(\s+(?:\S.*)?)?$/gm pragma regex used by TypeScript: the '@'
				// must be immediately followed by a non-whitespace pragma name, and the remainder
				// of the line is consumed as that pragma's arguments. As a consequence, only the
				// first '@'-token on a line is considered, so an unrelated '@token' earlier on the
				// line (e.g. an email address) prevents a later '@jsx' on the same line from being
				// treated as a pragma.
				var namePos = pos + 1;
				var nameEnd = skipNonBlanks(text, namePos);
				if (nameEnd == namePos) {
					pos++;
					continue;
				}
				var lineEnd = lineEndPos(text, pos);
				var pragmaName = Strings.ToLower(text.substring(namePos, nameEnd));
				if (pragmaName == "jsx" || pragmaName == "jsxfrag" || pragmaName == "jsximportsource" || pragmaName == "jsxruntime") {
					var start = skipBlanks(text, nameEnd);
					var argEnd = skipNonBlanks(text, start);
					if (argEnd != start) {
						var args = new StringMap<PragmaArgument>();
						final arg = new PragmaArgument();
						arg.Name = "factory";
						arg.Value = text.substring(start, argEnd);
						arg.TextRange = Core.NewTextRange(commentRange.Pos() + start, commentRange.Pos() + argEnd);
						args.set("factory", arg);
						final pragma = new Pragma();
						pragma.CommentRange = commentRange;
						pragma.Name = pragmaName;
						pragma.Args = args;
						pragmas = append(pragmas, pragma);
					}
				}
				pos = lineEnd;
			}
			return pragmas;
		}
		return null;
	}

	static function match(text:String, pos:Int, s:String):Bool {
		// PORT: strings.HasPrefix(text[pos:], s) without the slice.
		if (text.length - pos < s.length) {
			return false;
		}
		for (i in 0...s.length) {
			if (StringTools.fastCodeAt(text, pos + i) != StringTools.fastCodeAt(s, i)) {
				return false;
			}
		}
		return true;
	}

	static function skipBlanks(text:String, pos:Int):Int {
		while (pos < text.length && (StringTools.fastCodeAt(text, pos) == " ".code || StringTools.fastCodeAt(text, pos) == "\t".code)) {
			pos++;
		}
		return pos;
	}

	static function skipNonBlanks(text:String, pos:Int):Int {
		while (pos < text.length
			&& (StringTools.fastCodeAt(text, pos) != " ".code
				&& StringTools.fastCodeAt(text, pos) != "\t".code
				&& StringTools.fastCodeAt(text, pos) != "\r".code
				&& StringTools.fastCodeAt(text, pos) != "\n".code)) {
			pos++;
		}
		return pos;
	}

	static function skipTo(text:String, pos:Int, s:String):Int {
		if (pos >= text.length) {
			return -1;
		}
		var i = text.indexOf(s, pos);
		if (i < 0) {
			return -1;
		}
		return i;
	}

	static function lineEndPos(text:String, pos:Int):Int {
		while (pos < text.length) {
			// PORT: utf16 — decode one code point (PORTING.md §5).
			var ch = Utf16.DecodeRuneInString(text, pos);
			if (Stringutil.IsLineBreak(ch)) {
				return pos;
			}
			pos += Utf16.RuneLen(ch);
		}
		return text.length;
	}

	static function extractName(text:String, pos:Int):String {
		var start = pos;
		while (pos < text.length && isNameChar(StringTools.fastCodeAt(text, pos))) {
			pos++;
		}
		return Strings.ToLower(text.substring(start, pos));
	}

	static inline function isNameChar(c:Int):Bool {
		return c >= "A".code && c <= "Z".code || c >= "a".code && c <= "z".code || c == "-".code;
	}

	// PORT: Go returns (string, bool); here null stands for `false`.
	static function extractQuotedString(text:String, pos:Int):Null<String> {
		if (pos == text.length) {
			return null;
		}
		var quote = StringTools.fastCodeAt(text, pos);
		if (quote != "'".code && quote != '"'.code) {
			return null;
		}
		pos++;
		var start = pos;
		while (pos < text.length && StringTools.fastCodeAt(text, pos) != quote) {
			pos++;
		}
		if (pos == text.length) {
			return null;
		}
		return text.substring(start, pos);
	}

	function processPragmasIntoFields(context:SourceFile):Void {
		context.CheckJsDirective = null;
		context.ReferencedFiles = null;
		context.TypeReferenceDirectives = null;
		context.LibReferenceDirectives = null;
		// context.AmdDependencies = nil
		if (context.Pragmas == null) {
			return;
		}
		for (pragma in context.Pragmas) {
			switch (pragma.Name) {
				case "reference":
					// PORT: Go `v, ok := pragma.Args[k]` → get() (null when absent).
					var types = pragma.Args.get("types");
					var lib = pragma.Args.get("lib");
					var path = pragma.Args.get("path");
					var resolutionMode = pragma.Args.get("resolution-mode");
					var preserve = pragma.Args.get("preserve");
					var noDefaultLib = pragma.Args.get("no-default-lib");
					// PORT: tagless switch → if/else chain.
					if (noDefaultLib != null && noDefaultLib.Value == "true") {
						// Ignored.
					} else if (types != null) {
						var parsed:ResolutionMode = ModuleKindNone;
						if (resolutionMode != null) {
							parsed = parseResolutionMode(resolutionMode.Value, resolutionMode.Pos(), resolutionMode.End());
						}
						final ref = new FileReference();
						ref.TextRange = types.TextRange;
						ref.FileName = types.Value;
						ref.ResolutionMode = parsed;
						ref.Preserve = preserve != null && preserve.Value == "true";
						context.TypeReferenceDirectives = append(context.TypeReferenceDirectives, ref);
					} else if (lib != null) {
						final ref = new FileReference();
						ref.TextRange = lib.TextRange;
						ref.FileName = lib.Value;
						ref.Preserve = preserve != null && preserve.Value == "true";
						context.LibReferenceDirectives = append(context.LibReferenceDirectives, ref);
					} else if (path != null) {
						final ref = new FileReference();
						ref.TextRange = path.TextRange;
						ref.FileName = path.Value;
						ref.Preserve = preserve != null && preserve.Value == "true";
						context.ReferencedFiles = append(context.ReferencedFiles, ref);
					} else {
						parseErrorAtRange(pragma.CommentRange.TextRange, Diagnostics.Invalid_reference_directive_syntax);
					}
				case "ts-check" | "ts-nocheck":
					// _last_ of either nocheck or check in a file is the "winner"
					if (context.CheckJsDirective == null || pragma.CommentRange.Pos() > context.CheckJsDirective.Range.Pos()) {
						final directive = new CheckJsDirective();
						directive.Enabled = pragma.Name == "ts-check";
						directive.Range = pragma.CommentRange;
						context.CheckJsDirective = directive;
					}
				case "jsx" | "jsxfrag" | "jsximportsource" | "jsxruntime":
					// Nothing to do here
				default:
					throw "Unhandled pragma kind: " + pragma.Name;
			}
		}
	}

	function parseResolutionMode(mode:String, pos:Int, end:Int):ResolutionMode {
		var resolutionKind:ResolutionMode = ModuleKindNone;
		if (mode == "import") {
			resolutionKind = ModuleKindESNext;
			return resolutionKind;
		}
		if (mode == "require") {
			resolutionKind = ModuleKindCommonJS;
			return resolutionKind;
		}
		parseErrorAt(pos, end, Diagnostics.X_resolution_mode_should_be_either_require_or_import);
		return resolutionKind;
	}

	function jsErrorAtRange(loc:TextRange, message:Message, ...args:Any):Void {
		jsDiagnostics = append(jsDiagnostics, Ast.NewDiagnostic(null, Core.NewTextRange(Scanner.SkipTrivia(sourceText, loc.Pos()), loc.End()), message, ...args));
	}

	function checkJSDecoratorSyntax(node:Node):Void {
		var modifiers = node.ModifierNodes();
		if (Core.len(modifiers) == 0) {
			return;
		}

		if (Ast.CanHaveIllegalDecorators(node)) {
			for (modifier in modifiers) {
				if (Ast.IsDecorator(modifier)) {
					jsErrorAtRange(modifier.Loc, Diagnostics.Decorators_are_not_valid_here);
					break;
				}
			}
		} else if (Ast.CanHaveDecorators(node)) {
			var decoratorIndex = Core.FindIndex(modifiers, Ast.IsDecorator);
			if (decoratorIndex >= 0) {
				if (Ast.IsClassDeclaration(node)) {
					var exportIndex = Core.FindIndex(modifiers, isExportModifier);
					if (exportIndex >= 0) {
						var defaultIndex = Core.FindIndex(modifiers, function(m:Node):Bool {
							return m.Kind == KindDefaultKeyword;
						});
						if (decoratorIndex > exportIndex && defaultIndex >= 0 && decoratorIndex < defaultIndex) {
							// Decorator between `export` and `default`
							jsErrorAtRange(modifiers[decoratorIndex].Loc, Diagnostics.Decorators_are_not_valid_here);
						} else if (decoratorIndex < exportIndex) {
							// Find a trailing decorator after the export keyword
							var trailingDecoratorIndex = -1;
							for (i in exportIndex...modifiers.length) {
								if (Ast.IsDecorator(modifiers[i])) {
									trailingDecoratorIndex = i;
									break;
								}
							}
							if (trailingDecoratorIndex >= 0) {
								var diag = Ast.NewDiagnostic(
									null,
									Core.NewTextRange(Scanner.SkipTrivia(sourceText, modifiers[trailingDecoratorIndex].Loc.Pos()), modifiers[trailingDecoratorIndex].Loc.End()),
									Diagnostics.Decorators_may_not_appear_after_export_or_export_default_if_they_also_appear_before_export
								);
								diag.AddRelatedInfo(Ast.NewDiagnostic(
									null,
									Core.NewTextRange(Scanner.SkipTrivia(sourceText, modifiers[decoratorIndex].Loc.Pos()), modifiers[decoratorIndex].Loc.End()),
									Diagnostics.Decorator_used_before_export_here
								));
								jsDiagnostics = append(jsDiagnostics, diag);
							}
						}
					}
				}
			}
		}
	}

	function checkJSSyntax(node:Node):Node {
		if (node.Flags & NodeFlagsJavaScriptFile == 0 || node.Flags & (NodeFlagsJSDoc | NodeFlagsReparsed) != 0) {
			return node;
		}
		// PORT: `fallthrough` from the Parameter/Property/Method case → local function.
		inline function signatureCase():Void {
			if (Ast.IsFunctionLike(node) && node.Body() == null) {
				jsErrorAtRange(node.Loc, Diagnostics.Signature_declarations_can_only_be_used_in_TypeScript_files);
			} else {
				final t = node.Type();
				if (t != null && t.Flags & NodeFlagsReparsed == 0) {
					jsErrorAtRange(t.Loc, Diagnostics.Type_annotations_can_only_be_used_in_TypeScript_files);
				}
			}
		}
		switch (node.Kind) {
			case KindParameter | KindPropertyDeclaration | KindMethodDeclaration:
				final token = node.QuestionToken();
				if (token != null && token.Flags & NodeFlagsReparsed == 0 && Ast.IsQuestionToken(token)) {
					jsErrorAtRange(token.Loc, Diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, "?");
				}
				signatureCase();
			case KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor | KindFunctionExpression | KindFunctionDeclaration |
				KindArrowFunction | KindVariableDeclaration | KindIndexSignature:
				signatureCase();
			case KindImportDeclaration:
				final clause = node.ImportClause();
				if (clause != null && clause.IsTypeOnly()) {
					jsErrorAtRange(node.Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "import type");
				}
			case KindExportDeclaration:
				if (node.IsTypeOnly()) {
					jsErrorAtRange(node.Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "export type");
				}
			case KindImportSpecifier:
				if (node.IsTypeOnly()) {
					jsErrorAtRange(node.Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "import...type");
				}
			case KindExportSpecifier:
				if (node.IsTypeOnly()) {
					jsErrorAtRange(node.Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "export...type");
				}
			case KindImportEqualsDeclaration:
				jsErrorAtRange(node.Loc, Diagnostics.X_import_can_only_be_used_in_TypeScript_files);
			case KindExportAssignment:
				if (node.AsExportAssignment().IsExportEquals) {
					jsErrorAtRange(node.Loc, Diagnostics.X_export_can_only_be_used_in_TypeScript_files);
				}
			case KindHeritageClause:
				if (node.AsHeritageClause().Token == KindImplementsKeyword) {
					jsErrorAtRange(node.Loc, Diagnostics.X_implements_clauses_can_only_be_used_in_TypeScript_files);
				}
			case KindInterfaceDeclaration:
				jsErrorAtRange(node.Name().Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "interface");
			case KindModuleDeclaration:
				jsErrorAtRange(node.Name().Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, Scanner.TokenToString(node.AsModuleDeclaration().Keyword));
			case KindTypeAliasDeclaration:
				jsErrorAtRange(node.Name().Loc, Diagnostics.Type_aliases_can_only_be_used_in_TypeScript_files);
			case KindEnumDeclaration:
				jsErrorAtRange(node.Name().Loc, Diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "enum");
			case KindNonNullExpression:
				jsErrorAtRange(node.Loc, Diagnostics.Non_null_assertions_can_only_be_used_in_TypeScript_files);
			case KindAsExpression:
				jsErrorAtRange(node.Type().Loc, Diagnostics.Type_assertion_expressions_can_only_be_used_in_TypeScript_files);
			case KindSatisfiesExpression:
				jsErrorAtRange(node.Type().Loc, Diagnostics.Type_satisfaction_expressions_can_only_be_used_in_TypeScript_files);
			default:
		}
		// Check decorator placement in JS files
		checkJSDecoratorSyntax(node);
		// Check absence of type parameters, type arguments and non-JavaScript modifiers
		// PORT: `fallthrough` from the class/function case into the modifier check → local function.
		inline function modifiersCase():Void {
			final modifierNodes = node.ModifierNodes();
			if (modifierNodes != null) {
				for (modifier in modifierNodes) {
					if (modifier.Flags & NodeFlagsReparsed == 0 && modifier.Kind != KindDecorator && Ast.ModifierToFlag(modifier.Kind) & ModifierFlagsJavaScript == 0) {
						jsErrorAtRange(modifier.Loc, Diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, Scanner.TokenToString(modifier.Kind));
					}
				}
			}
		}
		switch (node.Kind) {
			case KindClassDeclaration | KindClassExpression | KindMethodDeclaration | KindConstructor | KindGetAccessor | KindSetAccessor |
				KindFunctionExpression | KindFunctionDeclaration | KindArrowFunction:
				final list = node.TypeParameterList();
				if (list != null && Core.Some(list.Nodes, isNotReparsed)) {
					jsErrorAtRange(list.Loc, Diagnostics.Type_parameter_declarations_can_only_be_used_in_TypeScript_files);
				}
				modifiersCase();
			case KindVariableStatement | KindPropertyDeclaration:
				modifiersCase();
			case KindParameter:
				if (Core.Some(node.ModifierNodes(), isModifierFn)) {
					jsErrorAtRange(node.Modifiers().Loc, Diagnostics.Parameter_modifiers_can_only_be_used_in_TypeScript_files);
				}
			case KindCallExpression | KindNewExpression | KindExpressionWithTypeArguments | KindJsxSelfClosingElement | KindJsxOpeningElement |
				KindTaggedTemplateExpression:
				final list = node.TypeArgumentList();
				if (list != null && Core.Some(list.Nodes, isNotReparsed)) {
					jsErrorAtRange(list.Loc, Diagnostics.Type_arguments_can_only_be_used_in_TypeScript_files);
				}
			default:
		}
		return node;
	}

	// PORT: Go func literal `func(n *ast.Node) bool { return n.Flags&ast.NodeFlagsReparsed == 0 }`
	// (no captures) → created once.
	static final isNotReparsed:(n:Node) -> Bool = function(n:Node):Bool {
		return n.Flags & NodeFlagsReparsed == 0;
	};

	// PORT: function value of ast.IsModifier, created once.
	static final isModifierFn:(n:Node) -> Bool = function(n:Node):Bool {
		return Ast.IsModifier(n);
	};

	// --- jsdoc.go ---

	// PORT: Go `func init()` registers the lazy JSDoc parser with package ast. Haxe has no package
	// init order (PORTING.md §7a); it is registered on first use of the parser instead.
	static var initDone:Bool = false;

	static function init():Void {
		if (!initDone) {
			initDone = true;
			Ast.SetParseJSDocForNode(parseJSDocForNode);
		}
	}

	// parseJSDocForNode lazily parses JSDoc for a node in a TS file.
	// Called on first access to Node.JSDoc() for non-JS source files.
	static function parseJSDocForNode(sourceFile:SourceFile, node:Node):Array<Node> {
		final p = getParser();
		// PORT: defer putParser(p)
		final r = try {
			parseJSDocForNodeWorker(p, sourceFile, node);
		} catch (e:Dynamic) {
			putParser(p);
			throw e;
		}
		putParser(p);
		return r;
	}

	// PORT: body of parseJSDocForNode (split off for the deferred putParser).
	static function parseJSDocForNodeWorker(p:Parser, sourceFile:SourceFile, node:Node):Array<Node> {
		p.initializeState(sourceFile.ParseOptions(), sourceFile.Text(), sourceFile.ScriptKind);
		var ranges = GetJSDocCommentRanges(p.factory, null, node, sourceFile.Text());
		if (Core.len(ranges) == 0) {
			return null;
		}
		var jsdoc:Array<Node> = [];
		var pos = node.Pos();
		for (comment in ranges) {
			final parsed = p.parseJSDocComment(node, comment.Pos(), comment.End(), pos);
			if (parsed != null) {
				parsed.Parent = node;
				jsdoc.push(parsed);
				pos = parsed.End();
			}
		}
		return jsdoc;
	}

	// PORT: out result of Jsdoc.parseBracketNameInPropertyAndParamTag (Go returns (name, isBracketed)).
	var bracketNameIsBracketed:Bool = false;

	// PORT: strings.LastIndex(text[:end], "\n") without the slice.
	static function lastIndexOfNewLine(text:String, end:Int):Int {
		var i = end - 1;
		while (i >= 0) {
			if (StringTools.fastCodeAt(text, i) == "\n".code) {
				return i;
			}
			i--;
		}
		return -1;
	}

	// PORT: function values created once (PORTING.md §7a).
	static final unicodeIsSpace:(r:Int) -> Bool = function(r:Int):Bool {
		return Unicode.IsSpace(r);
	};

	static final isJSDocReturnTagFn:(n:Node) -> Bool = function(n:Node):Bool {
		return Ast.IsJSDocReturnTag(n);
	};

	static final isJSDocTypeTagFn:(n:Node) -> Bool = function(n:Node):Bool {
		return Ast.IsJSDocTypeTag(n);
	};

	static function removeLeadingNewlines(comments:Array<String>):Array<String> {
		var i = 0;
		while (i < comments.length && Strings.TrimLeft(comments[i], "\r\n") == "") {
			i++;
		}
		// PORT: Go returns comments[i:]; the caller owns the slice, so it is shortened in place.
		if (i > 0) {
			comments.splice(0, i);
		}
		return comments;
	}

	static function trimEnd(s:String):String {
		return Strings.TrimRightFunc(s, isWhiteSpaceLikeFn);
	}

	static final isWhiteSpaceLikeFn:(ch:Int) -> Bool = function(ch:Int):Bool {
		return Stringutil.IsWhiteSpaceLike(ch);
	};

	static function removeTrailingWhitespace(comments:Array<String>):Array<String> {
		var end = comments.length;
		var i = comments.length - 1;
		while (i >= 0) {
			var trimmed = trimEnd(comments[i]);
			if (trimmed == "") {
				end = i;
			} else {
				comments[i] = trimmed;
				break;
			}
			i--;
		}
		// PORT: Go returns comments[:end] (the caller owns the slice).
		comments.resize(end);
		return comments;
	}

	static function isJSDocLinkTag(kind:String):Bool {
		return kind == "link" || kind == "linkcode" || kind == "linkplain";
	}

	static function isObjectOrObjectArrayTypeReference(node:TypeNode):Bool {
		switch (node.Kind) {
			case KindObjectKeyword:
				return true;
			case KindArrayType:
				return isObjectOrObjectArrayTypeReference(node.AsArrayTypeNode().ElementType);
			default:
				if (Ast.IsTypeReferenceNode(node)) {
					var ref = node.AsTypeReferenceNode();
					return Ast.IsIdentifier(ref.TypeName) && ref.TypeName.Text() == "Object" && ref.TypeArguments == null;
				}
				return false;
		}
	}

	static function textsEqual(a:EntityName, b:EntityName):Bool {
		while (!Ast.IsIdentifier(a) || !Ast.IsIdentifier(b)) {
			if (!Ast.IsIdentifier(a) && !Ast.IsIdentifier(b) && a.AsQualifiedName().Right.Text() == b.AsQualifiedName().Right.Text()) {
				a = a.AsQualifiedName().Left;
				b = b.AsQualifiedName().Left;
			} else {
				return false;
			}
		}
		return a.Text() == b.Text();
	}

	// --- reparser.go ---

	// PORT: Go returns (*ast.ParameterDeclaration, bool); null stands for `false`.
	static function findMatchingParameter(fun:Node, parameterTag:JSDocParameterOrPropertyTag, jsDoc:Node):ParameterDeclaration {
		var tagIndex = -1;
		var paramCount = -1;
		for (tag in nodesOf(jsDoc.AsJSDoc().Tags.Nodes)) {
			if (tag.Kind == KindJSDocParameterTag) {
				paramCount++;
				if (tag.AsJSDocParameterOrPropertyTag() == parameterTag) {
					tagIndex = paramCount;
					break;
				}
			}
		}
		final parameters = fun.Parameters();
		for (parameterIndex in 0...Core.len(parameters)) {
			final parameter = parameters[parameterIndex];
			if (parameter.Name().Kind == KindIdentifier) {
				if (parameterTag.Name().Kind == KindIdentifier
					&& ((parameter.Name().Text() == parameterTag.Name().Text())
						|| (parameterIndex == tagIndex && parameterTag.Name().Text().length == 0))) {
					return parameter.AsParameterDeclaration();
				}
			} else if (parameterIndex == tagIndex) {
				return parameter.AsParameterDeclaration();
			}
		}
		return null;
	}

	static function skipSatisfiesExpressions(node:Node):Node {
		while (node != null && node.Kind == KindSatisfiesExpression) {
			node = node.Expression();
		}
		return node;
	}

	static function getFunctionLikeHost(host:Node):Node {
		var fun = host;
		switch (host.Kind) {
			case KindVariableStatement:
				final nodes = host.AsVariableStatement().DeclarationList.AsVariableDeclarationList().Declarations.Nodes;
				if (Core.len(nodes) != 0) {
					fun = nodes[0].Initializer();
				}
			case KindPropertyAssignment | KindPropertyDeclaration:
				fun = host.Initializer();
			case KindExportAssignment | KindReturnStatement:
				fun = host.Expression();
			case KindExpressionStatement:
				fun = Ast.GetRightMostAssignedExpression(host.Expression());
			default:
		}
		fun = skipSatisfiesExpressions(fun);
		if (Ast.IsFunctionLike(fun)) {
			return fun;
		}
		return null;
	}

	static function getClassLikeData(parent:Node):ClassLikeBase {
		var class_:ClassLikeBase = null;
		switch (parent.Kind) {
			case KindClassDeclaration:
				class_ = parent.AsClassDeclaration().ClassLikeData();
			case KindClassExpression:
				class_ = parent.AsClassExpression().ClassLikeData();
			default:
		}
		return class_;
	}

	// PORT: Go func literals in reparseHosted without captures → function values created once.
	static final paramHasNoType:(param:Node) -> Bool = function(param:Node):Bool {
		return param.Type() == null;
	};

	static final isImplementsClauseFn:(node:Node) -> Bool = function(node:Node):Bool {
		return node.AsHeritageClause().Token == KindImplementsKeyword;
	};

	static final isExtendsClauseFn:(node:Node) -> Bool = function(node:Node):Bool {
		return node.AsHeritageClause().Token == KindExtendsKeyword;
	};

	// --- references.go ---

	static function collectExternalModuleReferences(file:SourceFile):Void {
		for (node in nodesOf(file.Statements.Nodes)) {
			collectModuleReferences(file, node, false /*inAmbientModule*/);
		}

		if (file.Flags & NodeFlagsPossiblyContainsDynamicImport != 0 || Ast.IsInJSFile(file.AsNode())) {
			Ast.ForEachDynamicImportOrRequireCall(file /*includeTypeSpaceImports*/, true /*requireStringLiteralLikeArgument*/, true,
				function(node:Node, moduleSpecifier:Expression):Bool {
					Ast.SetImportsOfSourceFile(file, append(file.Imports(), moduleSpecifier));
					return false;
				});
		}
	}

	static function collectModuleReferences(file:SourceFile, node:Statement, inAmbientModule:Bool):Void {
		if (Ast.IsAnyImportOrReExport(node)) {
			var moduleNameExpr = Ast.GetExternalModuleName(node);
			// TypeScript 1.0 spec (April 2014): 12.1.6
			// An ExternalImportDeclaration in an AmbientExternalModuleDeclaration may reference other external modules
			// only through top - level external module names. Relative external module names are not permitted.
			if (moduleNameExpr != null && Ast.IsStringLiteral(moduleNameExpr)) {
				var moduleName = moduleNameExpr.Text();
				if (moduleName != "" && (!inAmbientModule || !Tspath.IsExternalModuleNameRelative(moduleName))) {
					Ast.SetImportsOfSourceFile(file, append(file.Imports(), moduleNameExpr));
					// !!! removed `&& p.currentNodeModulesDepth == 0`
					if (file.UsesUriStyleNodeCoreModules != TSTrue && !file.IsDeclarationFile) {
						if (StringTools.startsWith(moduleName, "node:") && !Core.ExclusivelyPrefixedNodeCoreModules.exists(moduleName)) {
							// Presence of `node:` prefix takes precedence over unprefixed node core modules
							file.UsesUriStyleNodeCoreModules = TSTrue;
						} else if (file.UsesUriStyleNodeCoreModules == TSUnknown && Core.UnprefixedNodeCoreModules.exists(moduleName)) {
							// Avoid `unprefixedNodeCoreModules.has` for every import
							file.UsesUriStyleNodeCoreModules = TSFalse;
						}
					}
				}
			}
			return;
		}
		if (Ast.IsModuleDeclaration(node) && Ast.IsAmbientModule(node) && (inAmbientModule || Ast.HasSyntacticModifier(node, ModifierFlagsAmbient) || file.IsDeclarationFile)) {
			var nameText = node.AsModuleDeclaration().Name().Text();
			// Ambient module declarations can be interpreted as augmentations for some existing external modules.
			// This will happen in two cases:
			// - if current file is external module then module augmentation is a ambient module declaration defined in the top level scope
			// - if current file is not external module then module augmentation is an ambient module declaration with non-relative module name
			//   immediately nested in top level ambient module declaration .
			if (Ast.IsExternalModule(file) || (inAmbientModule && !Tspath.IsExternalModuleNameRelative(nameText))) {
				file.ModuleAugmentations = append(file.ModuleAugmentations, node.AsModuleDeclaration().Name());
			} else if (!inAmbientModule) {
				file.AmbientModuleNames = append(file.AmbientModuleNames, nameText);
				// An AmbientExternalModuleDeclaration declares an external module.
				// This type of declaration is permitted only in the global module.
				// The StringLiteral must specify a top - level external module name.
				// Relative external module names are not permitted
				// NOTE: body of ambient module is always a module block, if it exists
				if (node.Body() != null) {
					for (statement in nodesOf(node.Body().Statements())) {
						collectModuleReferences(file, statement, true /*inAmbientModule*/);
					}
				}
			}
		}
	}

	// --- utilities.go ---

	static function getLanguageVariant(scriptKind:ScriptKind):LanguageVariant {
		switch (scriptKind) {
			case ScriptKindTSX | ScriptKindJSX | ScriptKindJS | ScriptKindJSON:
				// .tsx and .jsx files are treated as jsx language variant.
				return LanguageVariantJSX;
			default:
		}
		return LanguageVariantStandard;
	}

	static inline function tokenIsIdentifierOrKeyword(token:Kind):Bool {
		return token >= KindIdentifier;
	}

	static inline function tokenIsIdentifierOrKeywordOrGreaterThan(token:Kind):Bool {
		return token == KindGreaterThanToken || tokenIsIdentifierOrKeyword(token);
	}

	public static function GetJSDocCommentRanges(f:NodeFactory, commentRanges:Array<CommentRange>, node:Node, text:String):Array<CommentRange> {
		if (commentRanges == null) {
			commentRanges = [];
		}
		switch (node.Kind) {
			case KindParameter | KindTypeParameter | KindFunctionExpression | KindArrowFunction | KindParenthesizedExpression | KindVariableDeclaration |
				KindExportSpecifier:
				for (commentRange in Scanner.GetTrailingCommentRanges(f, text, node.Pos())) {
					commentRanges.push(commentRange);
				}
				for (commentRange in Scanner.GetLeadingCommentRanges(f, text, node.Pos())) {
					commentRanges.push(commentRange);
				}
			default:
				for (commentRange in Scanner.GetLeadingCommentRanges(f, text, node.Pos())) {
					commentRanges.push(commentRange);
				}
		}
		// Keep if the comment starts with '/**' but not if it is '/**/'
		// PORT: slices.DeleteFunc → in-place filter.
		var j = 0;
		for (i in 0...commentRanges.length) {
			final comment = commentRanges[i];
			final commentStart = comment.Pos();
			final commentLen = comment.End() - commentStart;
			final remove = comment.End() > node.End() || commentLen < 4 || StringTools.fastCodeAt(text, commentStart + 1) != "*".code
				|| StringTools.fastCodeAt(text, commentStart + 2) != "*".code || StringTools.fastCodeAt(text, commentStart + 3) == "/".code;
			if (!remove) {
				commentRanges[j++] = comment;
			}
		}
		commentRanges.resize(j);
		return commentRanges;
	}

	static function isKeywordOrPunctuation(token:Kind):Bool {
		return Ast.IsKeywordKind(token) || Ast.IsPunctuationKind(token);
	}

	static function isJSDocLikeText(text:String):Bool {
		return text.length >= 4 && StringTools.fastCodeAt(text, 1) == "*".code && StringTools.fastCodeAt(text, 2) == "*".code
			&& StringTools.fastCodeAt(text, 3) != "/".code;
	}

	// PORT: isJSDocLikeText(text[start:]) without the slice.
	static function isJSDocLikeTextAt(text:String, start:Int):Bool {
		return text.length - start >= 4 && StringTools.fastCodeAt(text, start + 1) == "*".code && StringTools.fastCodeAt(text, start + 2) == "*".code
			&& StringTools.fastCodeAt(text, start + 3) != "/".code;
	}

	// BEGIN fn_ (generated from the uses; PORT: Go method expressions `(*Parser).x`, created once)
	static final fn_isNextNonwhitespaceTokenEndOfFile:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.isNextNonwhitespaceTokenEndOfFile();
	};

	static final fn_nextIsIdentifierAndCloseParen:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsIdentifierAndCloseParen();
	};

	static final fn_nextIsNotDot:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsNotDot();
	};

	static final fn_nextIsParenthesizedOrFunctionType:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsParenthesizedOrFunctionType();
	};

	static final fn_nextIsStartOfExpression:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsStartOfExpression();
	};

	static final fn_nextIsStartOfMappedType:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsStartOfMappedType();
	};

	static final fn_nextIsStartOfType:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsStartOfType();
	};

	static final fn_nextIsStartOfTypeOfImportType:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsStartOfTypeOfImportType();
	};

	static final fn_nextIsUnParenthesizedAsyncArrowFunction:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsUnParenthesizedAsyncArrowFunction();
	};

	static final fn_nextIsUnambiguouslyIndexSignature:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsUnambiguouslyIndexSignature();
	};

	static final fn_nextIsUnambiguouslyStartOfFunctionType:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsUnambiguouslyStartOfFunctionType();
	};

	static final fn_nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine();
	};

	static final fn_nextIsValidHeritageClauseObjectLiteral:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextIsValidHeritageClauseObjectLiteral();
	};

	static final fn_nextTokenCanFollowDefaultKeyword:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenCanFollowDefaultKeyword();
	};

	static final fn_nextTokenCanFollowExportModifier:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenCanFollowExportModifier();
	};

	static final fn_nextTokenIsBindingIdentifierOrStartOfDestructuring:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsBindingIdentifierOrStartOfDestructuring();
	};

	static final fn_nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf();
	};

	static final fn_nextTokenIsClassKeywordOnSameLine:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsClassKeywordOnSameLine();
	};

	static final fn_nextTokenIsDot:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsDot();
	};

	static final fn_nextTokenIsEqualsOrSemicolonOrColonToken:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsEqualsOrSemicolonOrColonToken();
	};

	static final fn_nextTokenIsFromKeywordOrEqualsToken:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsFromKeywordOrEqualsToken();
	};

	static final fn_nextTokenIsFunctionKeywordOnSameLine:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsFunctionKeywordOnSameLine();
	};

	static final fn_nextTokenIsIdentifier:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifier();
	};

	static final fn_nextTokenIsIdentifierOrKeyword:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifierOrKeyword();
	};

	static final fn_nextTokenIsIdentifierOrKeywordOnSameLine:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifierOrKeywordOnSameLine();
	};

	static final fn_nextTokenIsIdentifierOrKeywordOrGreaterThan:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifierOrKeywordOrGreaterThan();
	};

	static final fn_nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine();
	};

	static final fn_nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate();
	};

	static final fn_nextTokenIsNewKeyword:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsNewKeyword();
	};

	static final fn_nextTokenIsNumericOrBigIntLiteral:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsNumericOrBigIntLiteral();
	};

	static final fn_nextTokenIsOnSameLineAndCanFollowModifier:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsOnSameLineAndCanFollowModifier();
	};

	static final fn_nextTokenIsOpenBrace:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsOpenBrace();
	};

	static final fn_nextTokenIsOpenParen:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsOpenParen();
	};

	static final fn_nextTokenIsOpenParenOrLessThan:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsOpenParenOrLessThan();
	};

	static final fn_nextTokenIsOpenParenOrLessThanOrDot:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsOpenParenOrLessThanOrDot();
	};

	static final fn_nextTokenIsSlash:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsSlash();
	};

	static final fn_nextTokenIsTokenStringLiteral:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.nextTokenIsTokenStringLiteral();
	};

	static final fn_parseArgumentExpression:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseArgumentExpression();
	};

	static final fn_parseArgumentOrArrayLiteralElement:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseArgumentOrArrayLiteralElement();
	};

	static final fn_parseArrayBindingElement:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseArrayBindingElement();
	};

	static final fn_parseAssignmentExpressionOrHigher:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseAssignmentExpressionOrHigher();
	};

	static final fn_parseCaseOrDefaultClause:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseCaseOrDefaultClause();
	};

	static final fn_parseClassElement:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseClassElement();
	};

	static final fn_parseDecoratorExpression:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseDecoratorExpression();
	};

	static final fn_parseEnumMember:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseEnumMember();
	};

	static final fn_parseExportSpecifier:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseExportSpecifier();
	};

	static final fn_parseExpression:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseExpression();
	};

	static final fn_parseExpressionWithTypeArguments:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseExpressionWithTypeArguments();
	};

	static final fn_parseHeritageClause:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseHeritageClause();
	};

	static final fn_parseImportAttribute:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseImportAttribute();
	};

	static final fn_parseImportSpecifier:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseImportSpecifier();
	};

	static final fn_parseInitializer:(p:Parser) -> Expression = function(p:Parser):Expression {
		return p.parseInitializer();
	};

	static final fn_parseIntersectionTypeOrHigher:(p:Parser) -> TypeNode = function(p:Parser):TypeNode {
		return p.parseIntersectionTypeOrHigher();
	};

	static final fn_parseJsxAttribute:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseJsxAttribute();
	};

	static final fn_parseObjectBindingElement:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseObjectBindingElement();
	};

	static final fn_parseObjectLiteralElement:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseObjectLiteralElement();
	};

	static final fn_parseOptionalBindingIdentifier:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseOptionalBindingIdentifier();
	};

	static final fn_parseParameter:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseParameter();
	};

	static final fn_parsePostfixTypeOrHigher:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parsePostfixTypeOrHigher();
	};

	static final fn_parseStatement:(p:Parser) -> Statement = function(p:Parser):Statement {
		return p.parseStatement();
	};

	static final fn_parseToplevelStatement:(p:Parser, i:Int) -> Node = function(p:Parser, i:Int):Node {
		return p.parseToplevelStatement(i);
	};

	static final fn_parseTupleElementNameOrTupleElementType:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseTupleElementNameOrTupleElementType();
	};

	static final fn_parseType:(p:Parser) -> TypeNode = function(p:Parser):TypeNode {
		return p.parseType();
	};

	static final fn_parseTypeMember:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseTypeMember();
	};

	static final fn_parseTypeOperatorOrHigher:(p:Parser) -> TypeNode = function(p:Parser):TypeNode {
		return p.parseTypeOperatorOrHigher();
	};

	static final fn_parseTypeOrTypePredicate:(p:Parser) -> TypeNode = function(p:Parser):TypeNode {
		return p.parseTypeOrTypePredicate();
	};

	static final fn_parseTypeParameter:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseTypeParameter();
	};

	static final fn_parseVariableDeclaration:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseVariableDeclaration();
	};

	static final fn_parseVariableDeclarationAllowExclamation:(p:Parser) -> Node = function(p:Parser):Node {
		return p.parseVariableDeclarationAllowExclamation();
	};

	static final fn_scanClassMemberStart:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.scanClassMemberStart();
	};

	static final fn_scanStartOfDeclaration:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.scanStartOfDeclaration();
	};

	static final fn_scanStartOfNamedTupleElement:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.scanStartOfNamedTupleElement();
	};

	static final fn_scanTypeMemberStart:(p:Parser) -> Bool = function(p:Parser):Bool {
		return p.scanTypeMemberStart();
	};
	// END fn_
}
