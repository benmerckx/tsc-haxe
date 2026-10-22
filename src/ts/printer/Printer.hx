package ts.printer;

import go.IdentityMap;
import haxe.ds.StringMap;

// Port of internal/printer.
//
// Module layout (PORTING.md §1/§2):
//   Printer.hx    class Printer: the Go Printer struct and the methods of printer.go, plus all
//                 package-level funcs/vars of the package (Go file order, `// --- file.go ---`).
//                 The types of printer.go (PrinterOptions, PrintHandlers, ListFormat, ...).
//   <file>.hx     types and methods of the other Go files (Emitcontext.hx, Factory.hx, ...). Every
//                 Go method lives in the file of its receiver type, so no `using` extensions.
//
// PORT: method values. Go passes method expressions `(*Printer).emitX` to emitList/emitListRange/
// emitListItems. Here each one is a static final function value `fn_<name>` created once (see the
// end of class Printer), so no function value is created per call (PORTING.md §7a).
//
// PORT: multiple results on hot paths (enterToken, emitCommentsBeforeToken,
// getBinaryExpressionPrecedence) return the first value and store the second in an out field
// (`out*`) that the caller reads right after the call (PORTING.md §3).
@:allow(ts.printer)
class Printer {
	// --- printer.go ---

	// PORT: flattened — Go embeds PrintHandlers by value (copied in NewPrinter); its fields are
	// fields of Printer here.
	// A hook used by the Printer when generating unique names to avoid collisions with
	// globally defined names that exist outside of the current source file.
	public var HasGlobalName:(name:std.String) -> Bool = null;
	public var OnBeforeEmitNode:(nodeOpt:Node) -> Void = null;
	public var OnAfterEmitNode:(nodeOpt:Node) -> Void = null;
	public var OnBeforeEmitNodeList:(nodesOpt:NodeList) -> Void = null;
	public var OnAfterEmitNodeList:(nodesOpt:NodeList) -> Void = null;
	public var OnBeforeEmitToken:(nodeOpt:TokenNode) -> Void = null;
	public var OnAfterEmitToken:(nodeOpt:TokenNode) -> Void = null;

	public var Options:PrinterOptions = new PrinterOptions();
	var emitContext:EmitContext = null;
	var currentSourceFile:SourceFile = null;
	var uniqueHelperNames:StringMap<IdentifierNode> = null;
	var externalHelpersModuleName:IdentifierNode = null;
	var nextListElementPos:Int = 0;
	var writer:EmitTextWriter = null;
	var ownWriter:EmitTextWriter = null;
	var writeKind:WriteKind = WriteKindNone;
	var sourceMapsDisabled:Bool = false;
	var sourceMapGenerator:Generator = null;
	var sourceMapSource:Source = null;
	var sourceMapSourceIndex:SourceIndex = 0;
	var sourceMapSourceIsJson:Bool = false;
	var sourceMapLineCharCache:LineCharacterCache = null;
	var mostRecentSourceMapSource:Source = null;
	var mostRecentSourceMapSourceIndex:SourceIndex = 0;
	var containerPos:Int = 0;
	var containerEnd:Int = 0;
	var declarationListContainerEnd:Int = 0;
	var detachedCommentsInfo:Stack<DetachedCommentsInfo> = new Stack<DetachedCommentsInfo>();
	var commentsDisabled:Bool = false;
	var inExtends:Bool = false; // whether we are emitting the `extends` clause of a ConditionalTypeNode or InferTypeNode
	var nameGenerator:NameGenerator = new NameGenerator();
	var makeFileLevelOptimisticUniqueName:(std.String) -> std.String = null;
	// PORT: arena — commentStateArena / sourceMapStateArena: one `new` per state (see header of core.Arena).
	public var IdToSymbol:IdentityMap<Node, Symbol> = null;

	// PORT: out fields for second results (see header).
	var outPos:Int = 0;
	var outRightPrec:OperatorPrecedence = OperatorPrecedenceComma;

	// PORT: sourcemap.Source adapters for SourceFile (Go: *ast.SourceFile satisfies the interface
	// structurally). Cached per SourceFile so that identity comparisons of sources hold.
	var sourceFileSources:IdentityMap<SourceFile, SourceFileSource> = null;

	function new() {}

	public static function NewPrinter(options:PrinterOptions, handlers:PrintHandlers, emitContext:EmitContext):Printer {
		final printer = new Printer();
		printer.HasGlobalName = handlers.HasGlobalName;
		printer.OnBeforeEmitNode = handlers.OnBeforeEmitNode;
		printer.OnAfterEmitNode = handlers.OnAfterEmitNode;
		printer.OnBeforeEmitNodeList = handlers.OnBeforeEmitNodeList;
		printer.OnAfterEmitNodeList = handlers.OnAfterEmitNodeList;
		printer.OnBeforeEmitToken = handlers.OnBeforeEmitToken;
		printer.OnAfterEmitToken = handlers.OnAfterEmitToken;
		printer.Options = options;
		printer.emitContext = emitContext;
		// wire up name generator
		if (printer.emitContext == null) {
			printer.emitContext = NewEmitContext();
		}
		printer.nameGenerator.Context = printer.emitContext;
		printer.nameGenerator.GetTextOfNode = function(node:Node):std.String {
			return printer.getTextOfNode(node, false);
		};
		printer.nameGenerator.IsFileLevelUniqueNameInCurrentFile = printer.isFileLevelUniqueNameInCurrentFile;
		printer.makeFileLevelOptimisticUniqueName = function(name:std.String):std.String {
			return printer.nameGenerator.MakeFileLevelOptimisticUniqueName(name);
		};
		printer.containerPos = -1;
		printer.containerEnd = -1;
		printer.declarationListContainerEnd = -1;
		printer.commentsDisabled = options.RemoveComments;
		return printer;
	}

	function getLiteralTextOfNode(node:LiteralLikeNode, sourceFile:SourceFile, flags:GetLiteralTextFlags):std.String {
		if (Ast.IsStringLiteral(node)) {
			final textSourceNode = emitContext.textSource == null ? null : emitContext.textSource.get(node);
			if (textSourceNode != null) {
				var text = "";
				switch (textSourceNode.Kind) {
					case KindNumericLiteral:
						text = textSourceNode.Text();
					case KindIdentifier | KindPrivateIdentifier | KindJsxNamespacedName:
						text = getTextOfNode(textSourceNode, false);
					default:
						return getLiteralTextOfNode(textSourceNode, Ast.GetSourceFileOfNode(textSourceNode), flags);
				}

				if (flags & getLiteralTextFlagsJsxAttributeEscape != 0) {
					return "\"" + escapeJsxAttributeString(text, QuoteCharDoubleQuote) + "\"";
				} else if (flags & getLiteralTextFlagsNeverAsciiEscape != 0 || emitContext.EmitFlags(node) & EFNoAsciiEscaping != 0) {
					return "\"" + EscapeString(text, QuoteCharDoubleQuote) + "\"";
				} else {
					return "\"" + escapeNonAsciiString(text, QuoteCharDoubleQuote) + "\"";
				}
			}
		}
		// !!! Printer option to control whether to terminate unterminated literals
		if (emitContext.EmitFlags(node) & EFNoAsciiEscaping != 0) {
			flags |= getLiteralTextFlagsNeverAsciiEscape;
		}
		if (Options.Target >= ScriptTargetES2021) {
			flags |= getLiteralTextFlagsAllowNumericSeparator;
		}
		return getLiteralText(node, Core.Coalesce(sourceFile, currentSourceFile), flags);
	}

	// `node` must be one of Identifier | PrivateIdentifier | LiteralExpression | JsxNamespacedName
	function getTextOfNode(node:Node, includeTrivia:Bool):std.String {
		if (Ast.IsMemberName(node) && emitContext.autoGenerate != null && emitContext.autoGenerate.get(node) != null) {
			return nameGenerator.GenerateName(node);
		}

		if (Ast.IsStringLiteral(node)) {
			final textSourceNode = emitContext.textSource == null ? null : emitContext.textSource.get(node);
			if (textSourceNode != null) {
				return getTextOfNode(textSourceNode, includeTrivia);
			}
		}

		final canUseSourceFile = currentSourceFile != null && node.Parent != null && !Ast.NodeIsSynthesized(node);

		switch (node.Kind) {
			case KindIdentifier | KindPrivateIdentifier | KindJsxNamespacedName:
				if (!canUseSourceFile || Ast.GetSourceFileOfNode(node) != emitContext.MostOriginal(currentSourceFile.AsNode()).AsSourceFile()) {
					return node.Text();
				}
			case KindStringLiteral | KindNumericLiteral | KindBigIntLiteral | KindNoSubstitutionTemplateLiteral | KindTemplateHead | KindTemplateMiddle |
				KindTemplateTail:
				return getLiteralTextOfNode(node, null /*sourceFile*/, getLiteralTextFlagsNone);
			default:
				throw 'unexpected node: ${node.Kind.String()}';
		}
		return Scanner.GetSourceTextOfNodeFromSourceFile(currentSourceFile, node, includeTrivia);
	}

	//
	// Low-level writing
	//

	function writeAs(text:std.String, writeKind:WriteKind):Void {
		switch (writeKind) {
			case WriteKindNone:
				writer.Write(text);
			case WriteKindParameter:
				writeParameter(text);
			case WriteKindKeyword:
				writeKeyword(text);
			case WriteKindOperator:
				writeOperator(text);
			case WriteKindProperty:
				writeProperty(text);
			case WriteKindPunctuation:
				writePunctuation(text);
			case WriteKindStringLiteral:
				writer.WriteStringLiteral(text);
			case WriteKindComment:
				writeComment(text);
			case WriteKindLiteral:
				writeLiteral(text);
			default:
				throw 'unexpected printer.WriteKind: ${(writeKind : Int)}';
		}
	}

	function write(text:std.String):Void {
		writeAs(text, writeKind);
	}

	function setWriteKind(kind:WriteKind):WriteKind {
		final previous = writeKind;
		writeKind = kind;
		return previous;
	}

	function writeSymbol(text:std.String, optSymbol:Symbol):Void {
		if (optSymbol == null) {
			write(text);
		} else {
			writer.WriteSymbol(text, optSymbol);
		}
	}

	function writeLiteral(text:std.String):Void {
		writer.WriteLiteral(text);
	}

	function writePunctuation(text:std.String):Void {
		writer.WritePunctuation(text);
	}

	function writeOperator(text:std.String):Void {
		writer.WriteOperator(text);
	}

	function writeKeyword(text:std.String):Void {
		writer.WriteKeyword(text);
	}

	function writeProperty(text:std.String):Void {
		writer.WriteProperty(text);
	}

	function writeParameter(text:std.String):Void {
		writer.WriteParameter(text);
	}

	function writeComment(text:std.String):Void {
		writer.WriteComment(text);
	}

	function writeSpace():Void {
		writer.WriteSpace(" ");
	}

	function writeLine():Void {
		writer.WriteLine();
	}

	function writeLineRepeat(count:Int):Void {
		for (_ in 0...count) {
			writeLine();
		}
	}

	function writeLines(text:std.String):Void {
		final lines = Stringutil.SplitLines(text);
		final indentation = Stringutil.GuessIndentation(lines);
		for (line in lines) {
			if (indentation > 0) {
				line = line.substring(indentation);
			}
			if (line.length > 0) {
				writeLine();
				write(line);
			}
		}
	}

	function writeTrailingSemicolon():Void {
		writer.WriteTrailingSemicolon(";");
	}

	function increaseIndent():Void {
		writer.IncreaseIndent();
	}

	function decreaseIndent():Void {
		writer.DecreaseIndent();
	}

	function increaseIndentIf(indentRequested:Bool):Void {
		if (indentRequested) {
			increaseIndent();
		}
	}

	function decreaseIndentIf(indentRequested:Bool):Void {
		if (indentRequested) {
			decreaseIndent();
		}
	}

	function writeLineOrSpace(parentNode:Node, prevChildNode:Node, nextChildNode:Node):Void {
		if (shouldEmitOnSingleLine(parentNode)) {
			writeSpace();
		} else if (Options.PreserveSourceNewlines) {
			final lines = getLinesBetweenNodes(parentNode, prevChildNode, nextChildNode);
			if (lines > 0) {
				writeLineRepeat(lines);
			} else {
				writeSpace();
			}
		} else {
			writeLine();
		}
	}

	function writeLinesAndIndent(lineCount:Int, writeSpaceIfNotIndenting:Bool):Void {
		if (lineCount > 0) {
			increaseIndent();
			writeLineRepeat(lineCount);
		} else if (writeSpaceIfNotIndenting) {
			writeSpace();
		}
	}

	function writeLineSeparatorsAndIndentBefore(node:Node, parent:Node):Bool {
		if (Options.PreserveSourceNewlines) {
			final leadingNewlines = getLeadingLineTerminatorCount(parent, node, LFNone);
			if (leadingNewlines > 0) {
				writeLinesAndIndent(leadingNewlines /*writeSpaceIfNotIndenting*/, false);
				return true;
			}
		}
		return false;
	}

	function writeLineSeparatorsAfter(node:Node, parent:Node):Void {
		if (Options.PreserveSourceNewlines) {
			final trailingNewlines = getClosingLineTerminatorCount(parent, node, LFNone, Core.NewTextRange(-1, -1) /*childrenTextRange*/);
			if (trailingNewlines > 0) {
				writeLineRepeat(trailingNewlines);
			}
		}
	}

	function getLinesBetweenNodes(parent:Node, node1:Node, node2:Node):Int {
		if (shouldElideIndentation(parent)) {
			return 0;
		}

		parent = skipSynthesizedParentheses(parent);
		node1 = skipSynthesizedParentheses(node1);
		node2 = skipSynthesizedParentheses(node2);

		// Always use a newline for synthesized code if the synthesizer desires it.
		if (shouldEmitOnNewLine(node2, LFNone)) {
			return 1;
		}

		if (currentSourceFile != null && !Ast.NodeIsSynthesized(parent) && !Ast.NodeIsSynthesized(node1) && !Ast.NodeIsSynthesized(node2)) {
			if (Options.PreserveSourceNewlines) {
				final n1 = node1;
				final n2 = node2;
				return getEffectiveLines(function(includeComments:Bool):Int {
					return getLinesBetweenRangeEndAndRangeStart(n1.Loc, n2.Loc, currentSourceFile, includeComments);
				});
			}
			return Core.IfElse(rangeEndIsOnSameLineAsRangeStart(node1.Loc, node2.Loc, currentSourceFile), 0, 1);
		}

		return 0;
	}

	function getEffectiveLines(getLineDifference:(includeComments:Bool) -> Int):Int {
		// If 'preserveSourceNewlines' is disabled, we should never call this function
		// because it could be more expensive than alternative approximations.
		if (!Options.PreserveSourceNewlines) {
			throw "Should not be called when preserveSourceNewlines is false";
		}
		// We start by measuring the line difference from a position to its adjacent comments,
		// so that this is counted as a one-line difference, not two:
		//
		//   node1;
		//   // NODE2 COMMENT
		//   node2;
		final lines = getLineDifference(/*includeComments*/ true);
		if (lines == 0) {
			// However, if the line difference considering comments was 0, we might have this:
			//
			//   node1; // NODE2 COMMENT
			//   node2;
			//
			// in which case we should be ignoring node2's comment, so this too is counted as
			// a one-line difference, not zero.
			return getLineDifference(/*includeComments*/ false);
		}
		return lines;
	}

	function getLeadingLineTerminatorCount(parentNode:Node, firstChild:Node, format:ListFormat):Int {
		if (format & LFPreserveLines != 0 || Options.PreserveSourceNewlines) {
			if (format & LFPreferNewLine != 0) {
				return 1;
			}

			if (firstChild == null) {
				return Core.IfElse(parentNode == null || currentSourceFile != null && RangeIsOnSingleLine(parentNode.Loc, currentSourceFile), 0, 1);
			}
			if (nextListElementPos > 0 && firstChild.Pos() == nextListElementPos) {
				// If this child starts at the beginning of a list item in a parent list, its leading
				// line terminators have already been written as the separating line terminators of the
				// parent list. Example:
				//
				// class Foo {
				//   constructor() {}
				//   public foo() {}
				// }
				//
				// The outer list is the list of class members, with one line terminator between the
				// constructor and the method. The constructor is written, the separating line terminator
				// is written, and then we start emitting the method. Its modifiers ([public]) constitute an inner
				// list, so we look for its leading line terminators. If we didn't know that we had already
				// written a newline as part of the parent list, it would appear that we need to write a
				// leading newline to start the modifiers.
				return 0;
			}
			if (firstChild.Kind == KindJsxText) {
				// JsxText will be written with its leading whitespace, so don't add more manually.
				return 0;
			}
			if (currentSourceFile != null
				&& parentNode != null
				&& !Ast.PositionIsSynthesized(parentNode.Pos())
				&& !Ast.NodeIsSynthesized(firstChild)
				&& (firstChild.Parent == null /*|| getOriginalNode(firstChild.Parent) == getOriginalNode(parentNode)*/)) {
				if (Options.PreserveSourceNewlines) {
					return getEffectiveLines(function(includeComments:Bool):Int {
						return getLinesBetweenPositionAndPrecedingNonWhitespaceCharacter(firstChild.Pos(), parentNode.Pos(), currentSourceFile,
							includeComments);
					});
				}
				return Core.IfElse(RangeStartPositionsAreOnSameLine(parentNode.Loc, firstChild.Loc, currentSourceFile), 0, 1);
			}
			if (shouldEmitOnNewLine(firstChild, format)) {
				return 1;
			}
		}
		return Core.IfElse(format & LFMultiLine != 0, 1, 0);
	}

	function getSeparatingLineTerminatorCount(previousNode:Node, nextNode:Node, format:ListFormat):Int {
		if (format & LFPreserveLines != 0 || Options.PreserveSourceNewlines) {
			if (previousNode == null || nextNode == null) {
				return 0;
			}
			if (nextNode.Kind == KindJsxText) {
				// JsxText will be written with its leading whitespace, so don't add more manually.
				return 0;
			} else if (currentSourceFile != null && !Ast.NodeIsSynthesized(previousNode) && !Ast.NodeIsSynthesized(nextNode)) {
				if (Options.PreserveSourceNewlines && siblingNodePositionsAreComparable(emitContext, previousNode, nextNode)) {
					return getEffectiveLines(function(includeComments:Bool):Int {
						return getLinesBetweenRangeEndAndRangeStart(previousNode.Loc, nextNode.Loc, currentSourceFile, includeComments);
					});
				} else if (!Options.PreserveSourceNewlines && originalNodesHaveSameParent(emitContext, previousNode, nextNode)) {
					// If `preserveSourceNewlines` is `false` we do not intend to preserve the effective lines between the
					// previous and next node. Instead we naively check whether nodes are on separate lines within the
					// same node parent. If so, we intend to preserve a single line terminator. This is less precise and
					// expensive than checking with `preserveSourceNewlines` as above, but the goal is not to preserve the
					// effective source lines between two sibling nodes.
					return Core.IfElse(rangeEndIsOnSameLineAsRangeStart(previousNode.Loc, nextNode.Loc, currentSourceFile), 0, 1);
				}
				// If the two nodes are not comparable, add a line terminator based on the format that can indicate
				// whether new lines are preferred or not.
				return Core.IfElse(format & LFPreferNewLine != 0, 1, 0);
			} else if (shouldEmitOnNewLine(previousNode, format) || shouldEmitOnNewLine(nextNode, format)) {
				return 1;
			}
		} else if (shouldEmitOnNewLine(nextNode, LFNone)) {
			return 1;
		}
		return Core.IfElse(format & LFMultiLine != 0, 1, 0);
	}

	function getClosingLineTerminatorCount(parentNode:Node, lastChild:Node, format:ListFormat, childrenTextRange:TextRange):Int {
		if (format & LFPreserveLines != 0 || Options.PreserveSourceNewlines) {
			if (format & LFPreferNewLine != 0) {
				return 1;
			}
			if (lastChild == null) {
				return Core.IfElse(parentNode == null || currentSourceFile != null && RangeIsOnSingleLine(parentNode.Loc, currentSourceFile), 0, 1);
			}
			if (currentSourceFile != null
				&& parentNode != null
				&& !Ast.PositionIsSynthesized(parentNode.Pos())
				&& !Ast.NodeIsSynthesized(lastChild)
				&& (lastChild.Parent == null || lastChild.Parent == parentNode)) {
				if (Options.PreserveSourceNewlines) {
					final end = greatestEnd(lastChild.End(), childrenTextRange);
					return getEffectiveLines(function(includeComments:Bool):Int {
						return getLinesBetweenPositionAndNextNonWhitespaceCharacter(end, parentNode.End(), currentSourceFile, includeComments);
					});
				}
				return Core.IfElse(rangeEndPositionsAreOnSameLine(parentNode.Loc, lastChild.Loc, currentSourceFile), 0, 1);
			}
			if (shouldEmitOnNewLine(lastChild, format)) {
				return 1;
			}
		}
		if (format & LFMultiLine != 0 && format & LFNoTrailingNewLine == 0) {
			return 1;
		}
		return 0;
	}

	function writeCommentRange(comment:CommentRange):Void {
		if (currentSourceFile == null) {
			return;
		}

		final text = currentSourceFile.Text();
		final lineMap = currentSourceFile.ECMALineMap();
		writeCommentRangeWorker(text, lineMap, comment.Kind, comment.TextRange);
	}

	function writeCommentRangeWorker(text:std.String, lineMap:Array<TextPos>, kind:Kind, loc:TextRange):Void {
		if (kind == KindMultiLineCommentTrivia) {
			final indentSize = GetDefaultIndentSize();
			final firstLine = Scanner.ComputeLineOfPosition(lineMap, loc.Pos());
			final lineCount = lineMap.length;
			var firstCommentLineIndent = -1;
			var pos = loc.Pos();
			var currentLine = firstLine;
			while (pos < loc.End()) {
				var nextLineStart:Int;
				if (currentLine + 1 == lineCount) {
					nextLineStart = text.length + 1;
				} else {
					nextLineStart = lineMap[currentLine + 1];
				}

				if (pos != loc.Pos()) {
					// If we are not emitting first line, we need to write the spaces to adjust the alignment
					if (firstCommentLineIndent == -1) {
						firstCommentLineIndent = calculateIndent(text, lineMap[firstLine], loc.Pos());
					}

					// These are number of spaces writer is going to write at current indent
					final currentWriterIndentSpacing = writer.GetIndent() * indentSize;

					// Number of spaces we want to be writing
					// eg: Assume writer indent
					// module m {
					//         /* starts at character 9 this is line 1
					//    * starts at character pos 4 line                        --1  = 8 - 8 + 3
					//   More left indented comment */                            --2  = 8 - 8 + 2
					//     class c { }
					// }
					// module m {
					//     /* this is line 1 -- Assume current writer indent 8
					//      * line                                                --3 = 8 - 4 + 5
					//            More right indented comment */                  --4 = 8 - 4 + 11
					//     class c { }
					// }
					final spacesToEmit = currentWriterIndentSpacing - firstCommentLineIndent + calculateIndent(text, pos, nextLineStart);
					if (spacesToEmit > 0) {
						var numberOfSingleSpacesToEmit = spacesToEmit % indentSize;
						final indentSizeSpaceString = getIndentString(Std.int((spacesToEmit - numberOfSingleSpacesToEmit) / indentSize), indentSize);

						// Write indent size string ( in eg 1: = "", 2: "" , 3: string with 8 spaces 4: string with 12 spaces
						writer.RawWrite(indentSizeSpaceString);

						// Emit the single spaces (in eg: 1: 3 spaces, 2: 2 spaces, 3: 1 space, 4: 3 spaces)
						while (numberOfSingleSpacesToEmit > 0) {
							writer.RawWrite(" ");
							numberOfSingleSpacesToEmit--;
						}
					} else {
						// No spaces to emit write empty string
						writer.RawWrite("");
					}
				}

				// Write the comment line text
				// PORT: Go `min(loc.End(), nextLineStart)`; nextLineStart may be len(text)+1.
				var end = loc.End() < nextLineStart ? loc.End() : nextLineStart;
				var scan = pos;
				while (scan < end) {
					final ch = Utf16.DecodeRuneInString(text, scan);
					if (Stringutil.IsLineBreak(ch)) {
						end = scan;
						break;
					}
					scan += Utf16.RuneLen(ch);
				}
				final currentLineText = Strings.TrimSpace(text.substring(pos, end));
				if (currentLineText.length > 0) {
					writeComment(currentLineText);
					if (end != loc.End()) {
						writeLine();
					}
				} else {
					// Empty string - make sure we write empty line
					writer.WriteLineForce(true);
				}

				pos = nextLineStart;
				currentLine++;
			}
		} else {
			// Single line comment of style //....
			writeComment(text.substring(loc.Pos(), loc.End()));
		}
	}

	//
	// Custom emit behavior stubs (i.e., from `EmitNode`, `EmitFlags`, etc.)
	//

	function shouldEmitComments(node:Node):Bool {
		return !commentsDisabled && currentSourceFile != null && !Ast.IsSourceFile(node);
	}

	function shouldWriteComment(comment:CommentRange):Bool {
		return !Options.OnlyPrintJSDocStyle
			|| currentSourceFile != null && isJSDocLikeText(currentSourceFile.Text(), comment)
			|| currentSourceFile != null && IsPinnedComment(currentSourceFile.Text(), comment);
	}

	function shouldEmitIndented(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFIndented != 0;
	}

	function shouldElideIndentation(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFNoIndentation != 0;
	}

	function shouldEmitOnSingleLine(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFSingleLine != 0;
	}

	function shouldEmitOnMultipleLines(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFMultiLine != 0;
	}

	function shouldEmitBlockFunctionBodyOnSingleLine(body:Block):Bool {
		// We must emit a function body as a single-line body in the following case:
		// * The body has NodeEmitFlags.SingleLine specified.

		// We must emit a function body as a multi-line body in the following cases:
		// * The body is explicitly marked as multi-line.
		// * A non-synthesized body's start and end position are on different lines.
		// * Any statement in the body starts on a new line.

		if (shouldEmitOnSingleLine(body.AsNode())) {
			return true;
		}

		if (body.MultiLine) {
			return false;
		}

		if (!Ast.NodeIsSynthesized(body.AsNode()) && currentSourceFile != null && !RangeIsOnSingleLine(body.Loc, currentSourceFile)) {
			return false;
		}

		if (getLeadingLineTerminatorCount(body.AsNode(), Core.FirstOrNil(body.Statements.Nodes), LFPreserveLines) > 0
			|| getClosingLineTerminatorCount(body.AsNode(), Core.LastOrNil(body.Statements.Nodes), LFPreserveLines, body.Statements.Loc) > 0) {
			return false;
		}

		var previousStatement:Statement = null;
		if (body.Statements.Nodes != null) {
			for (statement in body.Statements.Nodes) {
				if (getSeparatingLineTerminatorCount(previousStatement, statement, LFPreserveLines) > 0) {
					return false;
				}

				previousStatement = statement;
			}
		}

		return true;
	}

	function shouldEmitOnNewLine(node:Node, format:ListFormat):Bool {
		if (emitContext.EmitFlags(node) & EFStartOnNewLine != 0) {
			return true;
		}
		return format & LFPreferNewLine != 0;
	}

	function shouldEmitSourceMaps(node:Node):Bool {
		return !sourceMapsDisabled && sourceMapSource != null && !Ast.IsSourceFile(node) && !Ast.IsInJsonFile(node);
	}

	function shouldEmitTokenSourceMaps(token:Kind, pos:Int, contextNode:Node, flags:TokenEmitFlags):Bool {
		// We don't emit source positions for most tokens as it tends to be quite noisy, however
		// we need to emit source positions for open and close braces so that tools like istanbul
		// can map branches for code coverage. However, we still omit brace source positions when
		// the output is a declaration file.
		return flags & tefNoSourceMaps == 0
			&& shouldEmitSourceMaps(contextNode)
			&& !Options.OmitBraceSourceMapPositions
			&& (token == KindOpenBraceToken || token == KindCloseBraceToken);
	}

	function shouldEmitLeadingComments(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFNoLeadingComments == 0;
	}

	function shouldEmitTrailingComments(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFNoTrailingComments == 0;
	}

	function shouldEmitNestedComments(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFNoNestedComments == 0;
	}

	function shouldEmitDetachedComments(node:Node):Bool {
		if (!Ast.IsSourceFile(node)) {
			return true;
		}

		final file = node.AsSourceFile();

		// Emit detached comment if there are no prologue directives or if the first node is synthesized.
		// The synthesized node will have no leading comment so some comments may be missed.
		return Core.len(file.Statements.Nodes) == 0
			|| !Ast.IsPrologueDirective(file.Statements.Nodes[0])
			|| Ast.NodeIsSynthesized(file.Statements.Nodes[0]);
	}

	function hasCommentsAtPosition(pos:Int):Bool {
		if (currentSourceFile == null) {
			return false;
		}

		if (Scanner.GetTrailingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pos + 1).hasNext()) {
			return true;
		}
		if (Scanner.GetLeadingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pos + 1).hasNext()) {
			return true;
		}
		return false;
	}

	function shouldEmitIndirectCall(node:Node):Bool {
		return emitContext.EmitFlags(node) & EFIndirectCall != 0;
	}

	function shouldAllowTrailingComma(node:Node, list:NodeList):Bool {
		if (currentSourceFile == null || currentSourceFile.ScriptKind == ScriptKindJSON) {
			return false;
		}

		switch (node.Kind) {
			case KindObjectLiteralExpression:
				return true;
			case KindArrayLiteralExpression | KindArrowFunction | KindConstructor | KindGetAccessor | KindSetAccessor | KindTypeAliasDeclaration |
				KindJSTypeAliasDeclaration | KindFunctionType | KindConstructorType | KindCallSignature | KindConstructSignature |
				KindTaggedTemplateExpression | KindObjectBindingPattern | KindArrayBindingPattern | KindNamedImports | KindNamedExports | KindImportAttributes:
				return true;
			case KindClassExpression | KindClassDeclaration | KindInterfaceDeclaration:
				return list == node.TypeParameterList();
			case KindFunctionDeclaration | KindFunctionExpression | KindMethodDeclaration:
				return true;
			case KindCallExpression:
				return true;
			case KindNewExpression:
				return true;
			default:
		}

		return false;
	}

	//
	// Tokens/Keywords
	//

	function writeTokenText(token:Kind, writeKind:WriteKind, pos:Int):Int {
		// !!! emit leading and trailing comments
		// !!! emit leading and trailing source maps
		final tokenString = Scanner.TokenToString(token);
		writeAs(tokenString, writeKind);
		if (Ast.PositionIsSynthesized(pos)) {
			return pos;
		} else {
			return pos + tokenString.length;
		}
	}

	function emitToken(token:Kind, pos:Int, writeKind:WriteKind, contextNode:Node):Int {
		return emitTokenEx(token, pos, writeKind, contextNode, tefNone);
	}

	function emitTokenEx(token:Kind, pos:Int, writeKind:WriteKind, contextNode:Node, flags:TokenEmitFlags):Int {
		final state = enterToken(token, pos, contextNode, flags);
		pos = outPos;
		pos = writeTokenText(token, writeKind, pos);
		exitToken(token, pos, contextNode, state);
		return pos;
	}

	function emitKeywordNode(node:TokenNode):Void {
		emitKeywordNodeEx(node, tefNone);
	}

	function emitKeywordNodeEx(node:TokenNode, flags:TokenEmitFlags):Void {
		if (node == null) {
			return;
		}

		final state = enterTokenNode(node, flags);
		writeTokenText(node.Kind, WriteKindKeyword, node.Pos());
		exitTokenNode(node, state);
	}

	function emitPunctuationNode(node:TokenNode):Void {
		emitPunctuationNodeEx(node, tefNone);
	}

	function emitPunctuationNodeEx(node:TokenNode, flags:TokenEmitFlags):Void {
		if (node == null) {
			return;
		}

		final state = enterTokenNode(node, flags);
		writeTokenText(node.Kind, WriteKindPunctuation, node.Pos());
		exitTokenNode(node, state);
	}

	function emitTokenNode(node:TokenNode):Void {
		emitTokenNodeEx(node, tefNone);
	}

	function emitTokenNodeEx(node:TokenNode, flags:TokenEmitFlags):Void {
		if (node == null) {
			return;
		}

		if (Ast.IsKeywordKind(node.Kind)) {
			emitKeywordNodeEx(node, flags);
		} else if (Ast.IsPunctuationKind(node.Kind)) {
			emitPunctuationNodeEx(node, flags);
		} else {
			throw 'unexpected TokenNode: ${node.Kind.String()}';
		}
	}

	//
	// Literals
	//

	// Emits literals of the following kinds
	//
	//	SyntaxKindNumericLiteral
	//	SyntaxKindBigIntLiteral
	//	SyntaxKindStringLiteral
	//	SyntaxKindNoSubstitutionTemplateLiteral
	//	SyntaxKindRegularExpressionLiteral
	//	SyntaxKindTemplateHead
	//	SyntaxKindTemplateMiddle
	//	SyntaxKindTemplateTail
	function emitLiteral(node:LiteralLikeNode, flags:GetLiteralTextFlags):Void {
		// Add NeverAsciiEscape flag if the printer option is set
		if (Options.NeverAsciiEscape) {
			flags |= getLiteralTextFlagsNeverAsciiEscape;
		}
		if (Options.TerminateUnterminatedLiterals) {
			flags |= getLiteralTextFlagsTerminateUnterminatedLiterals;
		}

		final text = getLiteralTextOfNode(node, null /*sourceFile*/, flags);

		// !!! Printer option to control source map emit, which causes us to use a different write method on the
		// emit text writer:

		////if (
		////	(printerOptions.sourceMap || printerOptions.inlineSourceMap)
		////	&& (node.kind === SyntaxKindStringLiteral || isTemplateLiteralKind(node.kind))
		////) {
		////	writeLiteral(text);
		////} else {

		// Quick info expects all literals to be called with writeStringLiteral, as there's no specific type for
		// numberLiterals
		writer.WriteStringLiteral(text);

		// }
	}

	function emitNumericLiteral(node:NumericLiteral):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitBigIntLiteral(node:BigIntLiteral):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone); // TODO: Preserve numeric literal separators after Strada migration
		exitNode(node.AsNode(), state);
	}

	function emitStringLiteral(node:StringLiteral):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitNoSubstitutionTemplateLiteral(node:NoSubstitutionTemplateLiteral):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitRegularExpressionLiteral(node:RegularExpressionLiteral):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	//
	// Pseudo-literals
	//

	function emitTemplateHead(node:TemplateHead):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateMiddle(node:TemplateMiddle):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateTail(node:TemplateTail):Void {
		final state = enterNode(node.AsNode());
		emitLiteral(node.AsNode(), getLiteralTextFlagsNone);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateMiddleTail(node:TemplateMiddleOrTail):Void {
		switch (node.Kind) {
			case KindTemplateMiddle:
				emitTemplateMiddle(node.AsTemplateMiddle());
			case KindTemplateTail:
				emitTemplateTail(node.AsTemplateTail());
			default:
		}
	}

	//
	// Snippet Elements
	//

	// !!! Snippet elements

	//
	// Names
	//

	function emitIdentifierText(node:Identifier):Void {
		final f = Ast.GetSourceFileOfNode(node.AsNode());
		Debug.Assert(f == null || currentSourceFile == null || f.FileName() == currentSourceFile.FileName());
		final text = getTextOfNode(node.AsNode(), false /*includeTrivia*/);

		if (IdToSymbol != null) {
			if (IdToSymbol.exists(node.AsNode())) {
				writeSymbol(text, IdToSymbol.get(node.AsNode()));
				return;
			}
		}
		write(text);
	}

	function emitIdentifierName(node:Identifier):Void {
		final state = enterNode(node.AsNode());
		emitIdentifierText(node);
		exitNode(node.AsNode(), state);
	}

	function emitIdentifierNameNode(node:IdentifierNode):Void {
		if (node == null) {
			return;
		}
		emitIdentifierName(node.AsIdentifier());
	}

	function getUniqueHelperName(name:std.String):IdentifierNode {
		final helperName = uniqueHelperNames.get(name);
		if (helperName == null) {
			final helperName = emitContext.Factory.NewUniqueNameEx(name,
				new AutoGenerateOptions(GeneratedIdentifierFlagsFileLevel | GeneratedIdentifierFlagsOptimistic));
			generateName(helperName);
			uniqueHelperNames.set(name, helperName);
			return helperName;
		}
		return helperName.Clone(emitContext.Factory);
	}

	function emitIdentifierReference(node:Identifier):Void {
		if ((externalHelpersModuleName != null || uniqueHelperNames != null) && emitContext.EmitFlags(node.AsNode()) & EFHelperName != 0) {
			if (externalHelpersModuleName != null) {
				// Substitute `__helper` with `tslib_1.__helper`
				final helper = emitContext.Factory.NewPropertyAccessExpression(externalHelpersModuleName.Clone(emitContext.Factory), null, /*questionDotToken*/
					node.AsNode().Clone(emitContext.Factory), NodeFlagsNone);
				emitContext.AssignCommentAndSourceMapRanges(helper, node.AsNode());
				emitPropertyAccessExpression(helper.AsPropertyAccessExpression());
				return;
			}
			if (uniqueHelperNames != null) {
				// Substitute `__helper` with `__helper_1` if there is a conflict in an ES module.
				final helperName = getUniqueHelperName(node.Text);
				emitContext.AssignCommentAndSourceMapRanges(helperName, node.AsNode());
				node = helperName.AsIdentifier();
			}
		}

		final state = enterNode(node.AsNode());
		emitIdentifierText(node);
		exitNode(node.AsNode(), state);
	}

	function emitBindingIdentifier(node:Identifier):Void {
		if (uniqueHelperNames != null && emitContext.EmitFlags(node.AsNode()) & EFHelperName != 0) {
			// Substitute `__helper` with `__helper_1` if there is a conflict in an ES module.
			final helperName = getUniqueHelperName(node.Text);
			emitContext.AssignCommentAndSourceMapRanges(helperName, node.AsNode());
			node = helperName.AsIdentifier();
		}

		final state = enterNode(node.AsNode());
		emitIdentifierText(node);
		exitNode(node.AsNode(), state);
	}

	function emitLabelIdentifier(node:Identifier):Void {
		final state = enterNode(node.AsNode());
		emitIdentifierText(node);
		exitNode(node.AsNode(), state);
	}

	function emitPrivateIdentifier(node:PrivateIdentifier):Void {
		final state = enterNode(node.AsNode());
		write(getTextOfNode(node.AsNode(), false /*includeTrivia*/));
		exitNode(node.AsNode(), state);
	}

	function emitQualifiedName(node:QualifiedName):Void {
		final state = enterNode(node.AsNode());
		emitEntityName(node.Left);
		writePunctuation(".");
		emitIdentifierName(node.Right.AsIdentifier());
		exitNode(node.AsNode(), state);
	}

	function emitComputedPropertyName(node:ComputedPropertyName):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("[");
		emitExpression(node.Expression, OperatorPrecedenceDisallowComma);
		writePunctuation("]");
		exitNode(node.AsNode(), state);
	}

	function emitEntityName(node:EntityName):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierReference(node.AsIdentifier());
			case KindQualifiedName:
				emitQualifiedName(node.AsQualifiedName());
			case KindPropertyAccessExpression:
				// TypeQuery nodes may have PropertyAccessExpression as exprName (e.g. typeof foo.x).
				// TS's emitter handles this via generic emit(); we dispatch to expression emitter here.
				emitExpression(node, OperatorPrecedenceDisallowComma);
			default:
				throw 'unexpected EntityName: ${node.Kind.String()}';
		}
	}

	function emitBindingName(node:BindingName):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindIdentifier:
				emitBindingIdentifier(node.AsIdentifier());
			case KindObjectBindingPattern:
				emitObjectBindingPattern(node.AsBindingPattern());
			case KindArrayBindingPattern:
				emitArrayBindingPattern(node.AsBindingPattern());
			default:
				throw 'unexpected BindingName: ${node.Kind.String()}';
		}
	}

	function emitPropertyName(node:PropertyName):Void {
		if (node == null) {
			return;
		}

		final savedWriteKind = writeKind;
		writeKind = WriteKindProperty;

		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindPrivateIdentifier:
				emitPrivateIdentifier(node.AsPrivateIdentifier());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			case KindNoSubstitutionTemplateLiteral:
				emitNoSubstitutionTemplateLiteral(node.AsNoSubstitutionTemplateLiteral());
			case KindNumericLiteral:
				emitNumericLiteral(node.AsNumericLiteral());
			case KindBigIntLiteral:
				emitBigIntLiteral(node.AsBigIntLiteral());
			case KindComputedPropertyName:
				emitComputedPropertyName(node.AsComputedPropertyName());
			default:
				throw 'unexpected PropertyName: ${node.Kind.String()}';
		}

		writeKind = savedWriteKind;
	}

	function emitMemberName(node:MemberName):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindPrivateIdentifier:
				emitPrivateIdentifier(node.AsPrivateIdentifier());
			default:
				throw 'unexpected MemberName: ${node.Kind.String()}';
		}
	}

	function emitModuleName(node:ModuleName):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindIdentifier:
				emitBindingIdentifier(node.AsIdentifier());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			default:
				throw 'unexpected ModuleName: ${node.Kind.String()}';
		}
	}

	function emitModuleExportName(node:ModuleExportName):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			default:
				throw 'unexpected ModuleExportName: ${node.Kind.String()}';
		}
	}

	function emitImportAttributeName(node:ImportAttributeName):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			default:
				throw 'unexpected ImportAttributeName: ${node.Kind.String()}';
		}
	}

	function emitNestedModuleName(node:ModuleName):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			default:
				throw 'unexpected ModuleName: ${node.Kind.String()}';
		}
	}

	//
	// Signature elements
	//

	function emitModifierList(parentNode:Node, modifiers:ModifierList, allowDecorators:Bool):Int {
		if (modifiers == null || Core.len(modifiers.Nodes) == 0) {
			return parentNode.Pos();
		}

		if (Core.Every(modifiers.Nodes, fn_IsModifier)) {
			// if all modifier-likes are `Modifier`, simply emit the list as modifiers.
			emitList(fn_emitKeywordNode, parentNode, modifiers, LFModifiers);
		} else if (Core.Every(modifiers.Nodes, fn_IsDecorator)) {
			if (!allowDecorators) {
				return parentNode.Pos();
			}

			// if all modifier-likes are `Decorator`, simply emit the list as decorators.
			emitList(fn_emitModifierLike, parentNode, modifiers, LFDecorators);
		} else {
			if (OnBeforeEmitNodeList != null) {
				OnBeforeEmitNodeList(modifiers);
			}

			// partition modifiers into contiguous chunks of `Modifier` or `Decorator` so as to
			// use consistent formatting for each chunk
			// PORT: local Go type `Mode` → Int constants.
			final ModeNone = 0;
			final ModeModifiers = 1;
			final ModeDecorators = 2;

			var lastMode = ModeNone;
			var mode = ModeNone;
			var start = 0;
			var pos = 0;

			var lastModifier:ModifierLike = null;
			while (start < modifiers.Nodes.length) {
				while (pos < modifiers.Nodes.length) {
					lastModifier = modifiers.Nodes[pos];
					if (Ast.IsDecorator(lastModifier)) {
						mode = ModeDecorators;
					} else {
						mode = ModeModifiers;
					}
					if (lastMode == ModeNone) {
						lastMode = mode;
					} else if (mode != lastMode) {
						break;
					}
					pos++;
				}

				var textRange = Core.NewTextRange(-1, -1);
				if (start == 0) {
					textRange = Core.NewTextRange(modifiers.Pos(), textRange.End());
				}
				if (pos == modifiers.Nodes.length - 1) {
					textRange = Core.NewTextRange(textRange.Pos(), modifiers.End());
				}
				if (allowDecorators || lastMode == ModeModifiers) {
					emitListItems(fn_emitModifierLike, parentNode, modifiers.Nodes.slice(start, pos), Core.IfElse(lastMode == ModeModifiers, LFModifiers,
						LFDecorators), false, /*hasTrailingComma*/ textRange);
				}
				start = pos;
				lastMode = mode;
				pos++;
			}

			if (OnAfterEmitNodeList != null) {
				OnAfterEmitNodeList(modifiers);
			}
		}

		return greatestEnd(parentNode.Pos(), Core.LastOrNil(modifiers.Nodes));
	}

	function emitTypeParameter(node:TypeParameterDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		if (node.Constraint != null) {
			writeSpace();
			writeKeyword("extends");
			writeSpace();
			emitTypeNodeOutsideExtends(node.Constraint);
		}
		if (node.DefaultType != null) {
			writeSpace();
			writeOperator("=");
			writeSpace();
			emitTypeNodeOutsideExtends(node.DefaultType);
		}
		exitNode(node.AsNode(), state);
	}

	function emitTypeParameterDeclarationNode(node:TypeParameterDeclarationNode):Void {
		// NOTE: QuickInfo uses TypeFormatFlagsWriteTypeArgumentsOfSignature to instruct the NodeBuilder to store type arguments
		// (i.e. type nodes) instead of type parameter declarations in the type parameter list.
		if (Ast.IsTypeParameterDeclaration(node)) {
			emitTypeParameter(node.AsTypeParameterDeclaration());
		} else {
			emitTypeArgument(node);
		}
	}

	function emitParameterName(node:BindingName):Void {
		final savedWriteKind = writeKind;
		writeKind = WriteKindParameter;
		emitBindingName(node);
		writeKind = savedWriteKind;
	}

	function emitParameter(node:ParameterDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), true /*allowDecorators*/);
		emitTokenNode(node.DotDotDotToken);
		emitParameterName(node.AsNode().Name());
		emitTokenNode(node.QuestionToken);

		emitTypeAnnotation(node.Type);

		// The comment position has to fallback to any present node within the parameter declaration because as it turns
		// out, the parser can make parameter declarations with _just_ an initializer.
		emitInitializer(node.Initializer, greatestEnd(node.Pos(), node.Type, node.QuestionToken, node.AsNode().Name(), node.AsNode().Modifiers()),
			node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitParameterDeclarationNode(node:ParameterDeclarationNode):Void {
		emitParameter(node.AsParameterDeclaration());
	}

	function emitDecorator(node:Decorator):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("@");
		emitExpression(node.Expression, OperatorPrecedenceLeftHandSide);
		exitNode(node.AsNode(), state);
	}

	function emitModifierLike(node:ModifierLike):Void {
		if (Ast.IsDecorator(node)) {
			emitDecorator(node.AsDecorator());
		} else if (Ast.IsModifier(node)) {
			emitKeywordNode(node);
		} else {
			throw 'unhandled ModifierLike: ${node.Kind.String()}';
		}
	}

	function emitTypeParameters(parentNode:Node, nodes:TypeParameterList):Void {
		if (nodes == null) {
			return;
		}
		emitList(fn_emitTypeParameterDeclarationNode, parentNode, nodes,
			LFTypeParameters | Core.IfElse(Ast.IsArrowFunction(parentNode) /*p.shouldAllowTrailingComma(parentNode, nodes)*/, LFAllowTrailingComma,
				LFNone)); // TODO: preserve trailing comma after Strada migration
	}

	function emitTypeAnnotation(node:TypeNode):Void {
		if (node == null) {
			return;
		}

		writePunctuation(":");
		writeSpace();
		emitTypeNodeOutsideExtends(node);
	}

	function emitInitializer(node:Expression, equalTokenPos:Int, contextNode:Node):Void {
		if (node == null) {
			return;
		}

		writeSpace();
		emitToken(KindEqualsToken, equalTokenPos, WriteKindOperator, contextNode);
		writeSpace();
		emitExpression(node, OperatorPrecedenceDisallowComma);
	}

	function emitParameters(parentNode:Node, parameters:ParameterList):Void {
		generateAllNames(parameters);
		emitList(fn_emitParameterDeclarationNode, parentNode, parameters,
			LFParameters /*|core.IfElse(p.shouldAllowTrailingComma(parentNode, parameters), LFAllowTrailingComma, LFNone)*/); // TODO: preserve trailing comma after Strada migration
	}

	static function canEmitSimpleArrowHead(parentNode:Node, parameters:ParameterList):Bool {
		// only arrow functions with a single parameter may have simple arrow head
		if (!Ast.IsArrowFunction(parentNode) || Core.len(parameters.Nodes) != 1) {
			return false;
		}

		final parent = parentNode.AsArrowFunction();
		final parameter = parameters.Nodes[0].AsParameterDeclaration();

		return parameter.Pos() == parent.Pos() // may not have parsed tokens between start of parent and parameter
			&& parent.TypeParameters == null // parent may not have type parameters
			&& parent.Type == null // parent may not have return type annotation
			&& (parent.AsNode().Modifiers() == null || Core.len(parent.AsNode().Modifiers().Nodes) == 0) // parent may not have modifiers
			&& !parameters.HasTrailingComma() // parameters may not have a trailing comma
			&& parameter.AsNode().Modifiers() == null // parameter may not have decorators or modifiers
			&& parameter.DotDotDotToken == null // parameter may not be rest
			&& parameter.QuestionToken == null // parameter may not be optional
			&& parameter.Type == null // parameter may not have a type annotation
			&& parameter.Initializer == null // parameter may not have an initializer
			&& Ast.IsIdentifier(parameter.AsNode().Name()); // parameter name must be identifier
	}

	function emitParametersForArrow(parentNode:Node /*FunctionType | ConstructorType | ArrowFunction*/, parameters:ParameterList):Void {
		if (canEmitSimpleArrowHead(parentNode, parameters)) {
			generateAllNames(parameters);
			emitList(fn_emitParameterDeclarationNode, parentNode, parameters, LFSingleArrowParameter);
		} else {
			emitParameters(parentNode, parameters);
		}
	}

	function emitParametersForIndexSignature(parentNode:Node, parameters:ParameterList):Void {
		generateAllNames(parameters);
		emitList(fn_emitParameterDeclarationNode, parentNode, parameters, LFIndexSignatureParameters);
	}

	function emitSignature(node:Node):Void {
		final n = node.FunctionLikeData();

		// !!! In old emitter, quickinfo used type arguments in place of type parameters on instantiated signatures
		////if n.TypeArguments != nil {
		////	p.emitTypeArguments(node, n.TypeArguments)
		////} else {
		emitTypeParameters(node, n.TypeParameters);
		////}

		emitParameters(node, n.Parameters);
		emitTypeAnnotation(n.Type);
	}

	function emitFunctionBody(body:Block):Void {
		emitContext.AddEmitFlags(body.AsNode(), EFNoSourceMap);

		// Use only notification hooks for the body block, not the full comment pipeline.
		// Without this, trailing comments from the original method declaration
		// (e.g., "// Error") leak into synthesized comma expressions when methods
		// are hoisted into pending expressions.
		if (OnBeforeEmitNode != null) {
			OnBeforeEmitNode(body.AsNode());
		}

		generateNames(body.AsNode());

		// !!! Emit with comment after Strada migration
		////p.emitTokenWithComment(ast.KindOpenBraceToken, body.Pos(), WriteKindPunctuation, body.AsNode())
		writePunctuation("{");

		increaseIndent();
		final detachedState = emitDetachedCommentsBeforeStatementList(body.AsNode(), body.Statements.Loc);
		final statementOffset = emitPrologueDirectives(body.Statements);
		final pos = writer.GetTextPos();
		emitHelpers(body.AsNode());

		if (shouldEmitBlockFunctionBodyOnSingleLine(body) && statementOffset == 0 && pos == writer.GetTextPos()) {
			decreaseIndent();
			emitListRange(fn_emitStatement, body.AsNode(), body.Statements, LFSingleLineFunctionBodyStatements, statementOffset, -1);
			increaseIndent();
		} else {
			emitListRange(fn_emitStatement, body.AsNode(), body.Statements, LFMultiLineFunctionBodyStatements, statementOffset, -1);
		}

		emitDetachedCommentsAfterStatementList(body.AsNode(), body.Statements.Loc, detachedState);
		decreaseIndent();

		// !!! Emit comment after Strada migration
		////p.emitTokenEx(ast.KindCloseBraceToken, body.Statements.End(), WriteKindPunctuation, body.AsNode(), tefNone)
		emitTokenEx(KindCloseBraceToken, body.Statements.End(), WriteKindPunctuation, body.AsNode(), tefNoComments);

		if (OnAfterEmitNode != null) {
			OnAfterEmitNode(body.AsNode());
		}
	}

	function emitFunctionBodyNode(node:BlockNode):Void {
		if (node == null) {
			writeTrailingSemicolon();
			return;
		}

		writeSpace();
		emitFunctionBody(node.AsBlock());
	}

	//
	// Type Members
	//

	function emitPropertySignature(node:PropertySignatureDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		emitPropertyName(node.AsNode().Name());
		emitTokenNode(node.PostfixToken);
		emitTypeAnnotation(node.Type);
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitPropertyDeclaration(node:PropertyDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), true /*allowDecorators*/);
		emitPropertyName(node.AsNode().Name());
		emitTokenNode(node.PostfixToken);
		emitTypeAnnotation(node.Type);
		emitInitializer(node.Initializer, greatestEnd(node.AsNode().Name().End(), node.Type, node.PostfixToken), node.AsNode());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitMethodSignature(node:MethodSignatureDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		emitPropertyName(node.AsNode().Name());
		emitTokenNode(node.PostfixToken);
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		writeTrailingSemicolon();
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitMethodDeclaration(node:MethodDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), true /*allowDecorators*/);
		emitTokenNode(node.AsteriskToken);
		emitPropertyName(node.AsNode().Name());
		emitTokenNode(node.PostfixToken);
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		emitFunctionBodyNode(node.Body);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitClassStaticBlockDeclaration(node:ClassStaticBlockDeclaration):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("static");
		pushNameGenerationScope(node.AsNode());
		emitFunctionBodyNode(node.Body);
		popNameGenerationScope(node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitConstructor(node:ConstructorDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("constructor");
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		emitFunctionBodyNode(node.Body);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	// PORT: Go takes *ast.AccessorDeclarationBase (&node.AccessorDeclarationBase); here the node.
	function emitAccessorDeclaration(token:Kind, node:Node):Void {
		final state = enterNode(node.AsNode());
		final pos = emitModifierList(node.AsNode(), node.Modifiers(), true /*allowDecorators*/);
		emitToken(token, pos, WriteKindKeyword, node.AsNode());
		writeSpace();
		emitPropertyName(node.Name());
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		emitFunctionBodyNode(node.Body());
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitGetAccessorDeclaration(node:GetAccessorDeclaration):Void {
		emitAccessorDeclaration(KindGetKeyword, node.AsNode());
	}

	function emitSetAccessorDeclaration(node:SetAccessorDeclaration):Void {
		emitAccessorDeclaration(KindSetKeyword, node.AsNode());
	}

	function emitCallSignature(node:CallSignatureDeclaration):Void {
		final state = enterNode(node.AsNode());
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		writeTrailingSemicolon();
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitConstructSignature(node:ConstructSignatureDeclaration):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("new");
		writeSpace();
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		writeTrailingSemicolon();
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitIndexSignature(node:IndexSignatureDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitParametersForIndexSignature(node.AsNode(), node.Parameters);
		emitTypeAnnotation(node.Type);
		writeTrailingSemicolon();
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitClassElement(node:ClassElement):Void {
		switch (node.Kind) {
			case KindPropertyDeclaration:
				emitPropertyDeclaration(node.AsPropertyDeclaration());
			case KindMethodDeclaration:
				emitMethodDeclaration(node.AsMethodDeclaration());
			case KindClassStaticBlockDeclaration:
				emitClassStaticBlockDeclaration(node.AsClassStaticBlockDeclaration());
			case KindConstructor:
				emitConstructor(node.AsConstructorDeclaration());
			case KindGetAccessor:
				emitGetAccessorDeclaration(node.AsGetAccessorDeclaration());
			case KindSetAccessor:
				emitSetAccessorDeclaration(node.AsSetAccessorDeclaration());
			case KindIndexSignature:
				emitIndexSignature(node.AsIndexSignatureDeclaration());
			case KindSemicolonClassElement:
				emitSemicolonClassElement(node.AsSemicolonClassElement());
			case KindNotEmittedStatement:
				emitNotEmittedStatement(node.AsNotEmittedStatement());
			case KindJSTypeAliasDeclaration:
				emitTypeAliasDeclaration(node.AsTypeAliasDeclaration());
			default:
				throw 'unexpected ClassElement: ${node.Kind.String()}';
		}
	}

	function emitTypeElement(node:TypeElement):Void {
		switch (node.Kind) {
			case KindPropertySignature:
				emitPropertySignature(node.AsPropertySignatureDeclaration());
			case KindMethodSignature:
				emitMethodSignature(node.AsMethodSignatureDeclaration());
			case KindCallSignature:
				emitCallSignature(node.AsCallSignatureDeclaration());
			case KindConstructSignature:
				emitConstructSignature(node.AsConstructSignatureDeclaration());
			case KindGetAccessor:
				emitGetAccessorDeclaration(node.AsGetAccessorDeclaration());
			case KindSetAccessor:
				emitSetAccessorDeclaration(node.AsSetAccessorDeclaration());
			case KindIndexSignature:
				emitIndexSignature(node.AsIndexSignatureDeclaration());
			case KindNotEmittedTypeElement:
				emitNotEmittedTypeElement(node.AsNotEmittedTypeElement());
			default:
				throw 'unexpected TypeElement: ${node.Kind.String()}';
		}
	}

	function emitObjectLiteralElement(node:ObjectLiteralElement):Void {
		switch (node.Kind) {
			case KindPropertyAssignment:
				emitPropertyAssignment(node.AsPropertyAssignment());
			case KindShorthandPropertyAssignment:
				emitShorthandPropertyAssignment(node.AsShorthandPropertyAssignment());
			case KindSpreadAssignment:
				emitSpreadAssignment(node.AsSpreadAssignment());
			case KindMethodDeclaration:
				emitMethodDeclaration(node.AsMethodDeclaration());
			case KindGetAccessor:
				emitGetAccessorDeclaration(node.AsGetAccessorDeclaration());
			case KindSetAccessor:
				emitSetAccessorDeclaration(node.AsSetAccessorDeclaration());
			default:
				throw 'unhandled ObjectLiteralElement: ${node.Kind.String()}';
		}
	}

	//
	// Types
	//

	function emitKeywordTypeNode(node:KeywordTypeNode):Void {
		emitKeywordNode(node.AsNode());
	}

	function emitTypePredicateParameterName(node:TypePredicateParameterName):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierReference(node.AsIdentifier());
			case KindThisType:
				emitThisType(node.AsThisTypeNode());
			default:
				throw 'unexpected TypePredicateParameterName: ${node.Kind.String()}';
		}
	}

	function emitTypePredicate(node:TypePredicateNode):Void {
		final state = enterNode(node.AsNode());
		if (node.AssertsModifier != null) {
			emitTokenNode(node.AssertsModifier);
			writeSpace();
		}
		emitTypePredicateParameterName(node.ParameterName);
		if (node.Type != null) {
			writeSpace();
			writeKeyword("is");
			writeSpace();
			emitTypeNodeOutsideExtends(node.Type);
		}
		exitNode(node.AsNode(), state);
	}

	function emitTypeArgument(node:TypeNode):Void {
		emitTypeNodeOutsideExtends(node);
	}

	function emitTypeArguments(parentNode:Node, nodes:TypeArgumentList):Void {
		if (nodes == null) {
			return;
		}
		emitList(fn_emitTypeParameterDeclarationNode, parentNode, nodes,
			LFTypeArguments /*|core.IfElse(p.shouldAllowTrailingComma(parentNode, nodes), LFAllowTrailingComma, LFNone)*/); // TODO: preserve trailing comma after Strada migration
	}

	function emitTypeReference(node:TypeReferenceNode):Void {
		final state = enterNode(node.AsNode());
		emitEntityName(node.TypeName);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		exitNode(node.AsNode(), state);
	}

	// Emits the return type of a FunctionTypeNode or ConstructorTypeNode, including the arrow (`=>`)
	function emitReturnType(node:TypeNode):Void {
		if (node == null) {
			return;
		}
		writePunctuation("=>");
		writeSpace();
		if (inExtends && node.Kind == KindInferType && node.AsInferTypeNode().TypeParameter.AsTypeParameterDeclaration().Constraint != null) {
			// if the parent FunctionTypeNode or ConstructorTypeNode is in the `extends` clause of a ConditionalTypeNode,
			// we must parenthesize `infer ... extends ...` so as not to result in an ambiguous parse.
			//
			// `T extends () => infer U extends V ? W : X` would parse the `? W : X` as part of a ConditionalTypeNode in the
			// return type of the FunctionTypeNode, thus we must emit as `T extends () => (infer U extends V) ? W : X`
			emitTypeNodePreservingExtends(node, TypePrecedenceHighest);
		} else {
			emitTypeNodePreservingExtends(node, TypePrecedenceLowest);
		}
	}

	function emitFunctionType(node:FunctionTypeNode):Void {
		final state = enterNode(node.AsNode());
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		// !!! in the old emitter, quickinfo uses type arguments in place of type parameters for instantiated signatures
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitParameters(node.AsNode(), node.Parameters);
		writeSpace();
		emitReturnType(node.Type);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitConstructorType(node:ConstructorTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("new");
		writeSpace();
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		// !!! in the old emitter, quickinfo uses type arguments in place of type parameters for instantiated signatures
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitParameters(node.AsNode(), node.Parameters);
		writeSpace();
		emitReturnType(node.Type);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitTypeQuery(node:TypeQueryNode):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("typeof");
		writeSpace();
		emitEntityName(node.ExprName);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		exitNode(node.AsNode(), state);
	}

	function emitTypeLiteral(node:TypeLiteralNode):Void {
		final state = enterNode(node.AsNode());
		pushNameGenerationScope(node.AsNode());
		generateAllMemberNames(node.Members);
		writePunctuation("{");
		final flags = Core.IfElse(shouldEmitOnSingleLine(node.AsNode()), LFSingleLineTypeLiteralMembers, LFMultiLineTypeLiteralMembers);
		emitList(fn_emitTypeElement, node.AsNode(), node.Members, flags | LFNoSpaceIfEmpty);
		writePunctuation("}");
		popNameGenerationScope(node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitArrayType(node:ArrayTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitPostfixTypeOperand(node.ElementType, node.AsNode());
		writePunctuation("[");
		writePunctuation("]");
		exitNode(node.AsNode(), state);
	}

	// emitPostfixTypeOperand emits the operand of a postfix type (ArrayType, IndexedAccessType,
	// OptionalType). It is equivalent to `emitTypeNode(operand, TypePrecedencePostfix)` except
	// that it preserves a parsed `typeof X` operand without adding parentheses (e.g.,
	// `typeof C[K]` instead of `(typeof C)[K]`). TypeScript's `parenthesizeNonArrayTypeOfPostfixType`
	// factory rule wraps `TypeQuery` in `ParenthesizedType` only when a postfix type is constructed
	// via the factory, so parsed postfix types preserve the source as written during round-trip
	// emit while synthesized postfix types (e.g., from declaration emit) still get the parentheses.
	function emitPostfixTypeOperand(operand:TypeNode, parent:Node):Void {
		if (Ast.IsParseTreeNode(parent) && operand.Kind == KindTypeQuery) {
			emitTypeNode(operand, TypePrecedenceTypeOperator);
			return;
		}
		emitTypeNode(operand, TypePrecedencePostfix);
	}

	function emitTupleElementType(node:Node):Void {
		emitTypeNodeOutsideExtends(node);
	}

	function emitTupleType(node:TupleTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindOpenBracketToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		final flags = Core.IfElse(shouldEmitOnSingleLine(node.AsNode()), LFSingleLineTupleTypeElements, LFMultiLineTupleTypeElements);
		emitList(fn_emitTupleElementType, node.AsNode(), node.Elements, flags | LFNoSpaceIfEmpty);
		emitToken(KindCloseBracketToken, node.Elements.End(), WriteKindPunctuation, node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitRestType(node:RestTypeNode):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("...");
		emitTypeNodeOutsideExtends(node.Type);
		exitNode(node.AsNode(), state);
	}

	function emitOptionalType(node:OptionalTypeNode):Void {
		final state = enterNode(node.AsNode());
		// !!! May need extra parenthesization if we also have JSDocNullableType
		emitPostfixTypeOperand(node.Type, node.AsNode());
		writePunctuation("?");
		exitNode(node.AsNode(), state);
	}

	function emitNamedTupleMember(node:NamedTupleMember):Void {
		final state = enterNode(node.AsNode());
		emitPunctuationNode(node.DotDotDotToken);
		emitIdentifierName(node.AsNode().Name().AsIdentifier());
		emitPunctuationNode(node.QuestionToken);
		emitToken(KindColonToken, greatestEnd(node.AsNode().Name().End(), node.QuestionToken), WriteKindPunctuation, node.AsNode());
		writeSpace();
		emitTypeNodeOutsideExtends(node.Type);
		exitNode(node.AsNode(), state);
	}

	function emitUnionTypeConstituent(node:TypeNode):Void {
		emitTypeNode(node, TypePrecedenceTypeOperator);
	}

	function emitUnionType(node:UnionTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitList(fn_emitUnionTypeConstituent, node.AsNode(), node.Types, LFUnionTypeConstituents);
		exitNode(node.AsNode(), state);
	}

	function emitIntersectionTypeConstituent(node:TypeNode):Void {
		emitTypeNode(node, TypePrecedenceTypeOperator);
	}

	function emitIntersectionType(node:IntersectionTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitList(fn_emitIntersectionTypeConstituent, node.AsNode(), node.Types,
			LFIntersectionTypeConstituents /*, parenthesizer.parenthesizeConstituentTypeOfIntersectionType*/); // !!!
		exitNode(node.AsNode(), state);
	}

	function emitConditionalType(node:ConditionalTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitTypeNode(node.CheckType, TypePrecedenceUnion);
		writeSpace();
		writeKeyword("extends");
		writeSpace();
		emitTypeNodeInExtends(node.ExtendsType);
		writeSpace();
		writePunctuation("?");
		writeSpace();
		emitTypeNodeOutsideExtends(node.TrueType);
		writeSpace();
		writePunctuation(":");
		writeSpace();
		emitTypeNodeOutsideExtends(node.FalseType);
		exitNode(node.AsNode(), state);
	}

	function emitInferTypeParameter(node:TypeParameterDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		if (node.Constraint != null) {
			writeSpace();
			writeKeyword("extends");
			writeSpace();
			emitTypeNodeInExtends(node.Constraint);
		}
		exitNode(node.AsNode(), state);
	}

	function emitInferType(node:InferTypeNode):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("infer");
		writeSpace();
		emitInferTypeParameter(node.TypeParameter.AsTypeParameterDeclaration());
		exitNode(node.AsNode(), state);
	}

	function emitParenthesizedType(node:ParenthesizedTypeNode):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("(");
		emitTypeNodeOutsideExtends(node.Type);
		writePunctuation(")");
		exitNode(node.AsNode(), state);
	}

	function emitThisType(node:ThisTypeNode):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("this");
		exitNode(node.AsNode(), state);
	}

	function emitTypeOperator(node:TypeOperatorNode):Void {
		final state = enterNode(node.AsNode());
		emitToken(node.Operator, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitTypeNode(node.Type, Core.IfElse(node.Operator == KindReadonlyKeyword, TypePrecedencePostfix, TypePrecedenceTypeOperator));
		exitNode(node.AsNode(), state);
	}

	function emitIndexedAccessType(node:IndexedAccessTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitPostfixTypeOperand(node.ObjectType, node.AsNode());
		writePunctuation("[");
		emitTypeNodeOutsideExtends(node.IndexType);
		writePunctuation("]");
		exitNode(node.AsNode(), state);
	}

	function emitMappedTypeParameter(node:TypeParameterDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		writeSpace();
		writeKeyword("in");
		writeSpace();
		emitTypeNodeOutsideExtends(node.Constraint);
		exitNode(node.AsNode(), state);
	}

	function emitMappedType(node:MappedTypeNode):Void {
		final state = enterNode(node.AsNode());
		final singleLine = shouldEmitOnSingleLine(node.AsNode());
		writePunctuation("{");
		if (singleLine) {
			writeSpace();
		} else {
			writeLine();
			increaseIndent();
		}
		if (node.ReadonlyToken != null) {
			emitTokenNode(node.ReadonlyToken);
			if (node.ReadonlyToken.Kind != KindReadonlyKeyword) {
				writeKeyword("readonly");
			}
			writeSpace();
		}
		writePunctuation("[");
		emitMappedTypeParameter(node.TypeParameter.AsTypeParameterDeclaration());
		if (node.NameType != null) {
			writeSpace();
			writeKeyword("as");
			writeSpace();
			emitTypeNodeOutsideExtends(node.NameType);
		}
		writePunctuation("]");
		if (node.QuestionToken != null) {
			emitPunctuationNode(node.QuestionToken);
			if (node.QuestionToken.Kind != KindQuestionToken) {
				writePunctuation("?");
			}
		}
		writePunctuation(":");
		writeSpace();
		emitTypeNodeOutsideExtends(node.Type);
		writeTrailingSemicolon();
		if (node.Members != null) {
			if (Core.len(node.Members.Nodes) > 0) {
				if (singleLine) {
					writeSpace();
				} else {
					writeLine();
				}
				emitList(fn_emitTypeElement, node.AsNode(), node.Members, LFPreserveLines);
			}
		}
		if (singleLine) {
			writeSpace();
		} else {
			writeLine();
			decreaseIndent();
		}
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitLiteralType(node:LiteralTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Literal, OperatorPrecedenceComma);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateTypeSpan(node:TemplateLiteralTypeSpan):Void {
		final state = enterNode(node.AsNode());
		emitTypeNodeOutsideExtends(node.Type);
		emitTemplateMiddleTail(node.Literal);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateTypeSpanNode(node:TemplateLiteralTypeSpanNode):Void {
		emitTemplateTypeSpan(node.AsTemplateLiteralTypeSpan());
	}

	function emitTemplateType(node:TemplateLiteralTypeNode):Void {
		final state = enterNode(node.AsNode());
		emitTemplateHead(node.Head.AsTemplateHead());
		emitList(fn_emitTemplateTypeSpanNode, node.AsNode(), node.TemplateSpans, LFTemplateExpressionSpans);
		exitNode(node.AsNode(), state);
	}

	function emitImportTypeNodeAttributes(node:ImportAttributes):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("{");
		writeSpace();
		writeKeyword(Core.IfElse(node.Token == KindAssertKeyword, "assert", "with"));
		writePunctuation(":");
		writeSpace();
		emitList(fn_emitImportAttributeNode, node.AsNode(), node.Attributes, LFImportAttributes);
		writeSpace();
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitImportTypeNode(node:ImportTypeNode):Void {
		final state = enterNode(node.AsNode());
		if (node.IsTypeOf) {
			writeKeyword("typeof");
			writeSpace();
		}
		writeKeyword("import");
		writePunctuation("(");
		emitTypeNodeOutsideExtends(node.Argument);
		if (node.Attributes != null) {
			writePunctuation(",");
			writeSpace();
			emitImportTypeNodeAttributes(node.Attributes.AsImportAttributes());
		}
		writePunctuation(")");
		if (node.Qualifier != null) {
			writePunctuation(".");
			emitEntityName(node.Qualifier);
		}
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		exitNode(node.AsNode(), state);
	}

	// emits a Type node in the `extends` clause of a ConditionalType
	function emitTypeNodeInExtends(node:TypeNode):Void {
		final savedInExtends = inExtends;
		inExtends = true;
		emitTypeNodePreservingExtends(node, TypePrecedenceLowest);
		inExtends = savedInExtends;
	}

	// emits a Type node not in the `extends` clause of a ConditionalType or InferType
	function emitTypeNodeOutsideExtends(node:TypeNode):Void {
		final savedInExtends = inExtends;
		inExtends = false;
		emitTypeNodePreservingExtends(node, TypePrecedenceLowest);
		inExtends = savedInExtends;
	}

	// emits a Type node preserving whether or not we are currently in the `extends` clause of a ConditionalType or InferType
	function emitTypeNodePreservingExtends(node:TypeNode, precedence:TypePrecedence):Void {
		emitTypeNode(node, precedence);
	}

	function emitTypeNode(node:TypeNode, precedence:TypePrecedence):Void {
		if (inExtends && (precedence : Int) <= (TypePrecedenceConditional : Int)) {
			// in the `extends` clause of a ConditionalType or InferType, a ConditionalType must be parenthesized
			precedence = TypePrecedenceFunction;
		}

		final savedInExtends = inExtends;
		final parens = (Ast.GetTypeNodePrecedence(node) : Int) < (precedence : Int);
		if (parens) {
			inExtends = false;
			writePunctuation("(");
		}

		switch (node.Kind) {
			// Keyword Types
			case KindAnyKeyword | KindUnknownKeyword | KindNumberKeyword | KindBigIntKeyword | KindObjectKeyword | KindBooleanKeyword | KindStringKeyword |
				KindSymbolKeyword | KindVoidKeyword | KindUndefinedKeyword | KindNeverKeyword | KindIntrinsicKeyword:
				emitKeywordTypeNode(node.AsKeywordTypeNode());

			// Types
			case KindTypePredicate:
				emitTypePredicate(node.AsTypePredicateNode());
			case KindTypeReference:
				emitTypeReference(node.AsTypeReferenceNode());
			case KindFunctionType:
				emitFunctionType(node.AsFunctionTypeNode());
			case KindConstructorType:
				emitConstructorType(node.AsConstructorTypeNode());
			case KindTypeQuery:
				emitTypeQuery(node.AsTypeQueryNode());
			case KindTypeLiteral:
				emitTypeLiteral(node.AsTypeLiteralNode());
			case KindArrayType:
				emitArrayType(node.AsArrayTypeNode());
			case KindTupleType:
				emitTupleType(node.AsTupleTypeNode());
			case KindOptionalType:
				emitOptionalType(node.AsOptionalTypeNode());
			case KindRestType:
				emitRestType(node.AsRestTypeNode());
			case KindUnionType:
				emitUnionType(node.AsUnionTypeNode());
			case KindIntersectionType:
				emitIntersectionType(node.AsIntersectionTypeNode());
			case KindConditionalType:
				emitConditionalType(node.AsConditionalTypeNode());
			case KindInferType:
				emitInferType(node.AsInferTypeNode());
			case KindParenthesizedType:
				emitParenthesizedType(node.AsParenthesizedTypeNode());
			case KindThisType:
				emitThisType(node.AsThisTypeNode());
			case KindTypeOperator:
				emitTypeOperator(node.AsTypeOperatorNode());
			case KindIndexedAccessType:
				emitIndexedAccessType(node.AsIndexedAccessTypeNode());
			case KindMappedType:
				emitMappedType(node.AsMappedTypeNode());
			case KindLiteralType:
				emitLiteralType(node.AsLiteralTypeNode());
			case KindNamedTupleMember:
				emitNamedTupleMember(node.AsNamedTupleMember());
			case KindTemplateLiteralType:
				emitTemplateType(node.AsTemplateLiteralTypeNode());
			case KindTemplateLiteralTypeSpan:
				emitTemplateTypeSpan(node.AsTemplateLiteralTypeSpan());
			case KindImportType:
				emitImportTypeNode(node.AsImportTypeNode());

			case KindPropertyAccessExpression:
				// Occurs in pseudo-types such as `f<T>.C`, where `f` is a generic function and `C` is a local type
				emitPropertyAccessExpression(node.AsPropertyAccessExpression());
			case KindExpressionWithTypeArguments:
				// !!! Should this actually be considered a type?
				emitExpressionWithTypeArguments(node.AsExpressionWithTypeArguments());

			case KindJSDocAllType:
				emitJSDocAllType(node);
			case KindJSDocNonNullableType:
				emitJSDocNonNullableType(node.AsJSDocNonNullableType());
			case KindJSDocNullableType:
				emitJSDocNullableType(node.AsJSDocNullableType());
			case KindJSDocOptionalType:
				emitJSDocOptionalType(node.AsJSDocOptionalType());
			case KindJSDocVariadicType:
				emitJSDocVariadicType(node.AsJSDocVariadicType());

			default:
				throw 'unhandled TypeNode: ${node.Kind.String()}';
		}

		if (parens) {
			writePunctuation(")");
		}

		inExtends = savedInExtends;
	}

	//
	// Binding patterns
	//

	function emitObjectBindingPattern(node:BindingPattern):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("{");
		emitList(fn_emitBindingElementNode, node.AsNode(), node.Elements, LFObjectBindingPatternElements);
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitArrayBindingPattern(node:BindingPattern):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("[");
		emitList(fn_emitBindingElementNode, node.AsNode(), node.Elements, LFArrayBindingPatternElements);
		writePunctuation("]");
		exitNode(node.AsNode(), state);
	}

	function emitBindingElement(node:BindingElement):Void {
		final state = enterNode(node.AsNode());
		emitTokenNode(node.DotDotDotToken);
		if (node.PropertyName != null) {
			emitPropertyName(node.PropertyName);
			writePunctuation(":");
			writeSpace();
		}
		// Old parser used `OmittedExpression` as a substitute for `Elision`. New parser uses a `BindingElement` with nil members
		final name = node.AsNode().Name();
		if (name != null) {
			emitBindingName(name);
			emitInitializer(node.Initializer, node.AsNode().Name().End(), node.AsNode());
		}
		exitNode(node.AsNode(), state);
	}

	function emitBindingElementNode(node:BindingElementNode):Void {
		emitBindingElement(node.AsBindingElement());
	}

	function emitJSDocAllType(node:Node):Void {
		emitKeywordNode(node);
	}

	function emitJSDocNonNullableType(node:JSDocNonNullableType):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("!");
		emitTypeNode(node.Type, TypePrecedenceNonArray);
		exitNode(node.AsNode(), state);
	}

	function emitJSDocNullableType(node:JSDocNullableType):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("?");
		emitTypeNode(node.Type, TypePrecedenceNonArray);
		exitNode(node.AsNode(), state);
	}

	function emitJSDocOptionalType(node:JSDocOptionalType):Void {
		final state = enterNode(node.AsNode());
		emitTypeNode(node.Type, TypePrecedenceJSDoc);
		writePunctuation("=");
		exitNode(node.AsNode(), state);
	}

	function emitJSDocVariadicType(node:JSDocVariadicType):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("...");
		emitTypeNode(node.Type, TypePrecedenceJSDoc);
		exitNode(node.AsNode(), state);
	}

	//
	// Expressions
	//

	function emitKeywordExpression(node:KeywordExpression):Void {
		emitKeywordNode(node.AsNode());
	}

	function emitArrayLiteralExpressionElement(node:Expression):Void {
		emitExpression(node, OperatorPrecedenceSpread);
	}

	function emitArrayLiteralExpression(node:ArrayLiteralExpression):Void {
		final state = enterNode(node.AsNode());
		emitList(fn_emitArrayLiteralExpressionElement, node.AsNode(), node.Elements,
			LFArrayLiteralExpressionElements | Core.IfElse(node.MultiLine, LFPreferNewLine, LFNone));
		exitNode(node.AsNode(), state);
	}

	function emitObjectLiteralExpression(node:ObjectLiteralExpression):Void {
		final state = enterNode(node.AsNode());
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		generateAllMemberNames(node.Properties);
		emitList(fn_emitObjectLiteralElement, node.AsNode(), node.Properties,
			LFObjectLiteralExpressionProperties | Core.IfElse(node.MultiLine, LFPreferNewLine,
				LFNone) | Core.IfElse(shouldAllowTrailingComma(node.AsNode(), node.Properties), LFAllowTrailingComma, LFNone));
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	// 1..toString is a valid property access, emit a dot after the literal
	// Also emit a dot if expression is a integer const enum value - it will appear in generated code as numeric literal
	function mayNeedDotDotForPropertyAccess(expression:Expression):Bool {
		expression = Ast.SkipPartiallyEmittedExpressions(expression);
		if (Ast.IsNumericLiteral(expression)) {
			// check if numeric literal is a decimal literal that was originally written with a dot
			final text = getLiteralTextOfNode(expression /*sourceFile*/, null, getLiteralTextFlagsNeverAsciiEscape);
			// If the number will be printed verbatim and it doesn't already contain a dot or an exponent indicator, add one
			// if the expression doesn't have any comments that will be emitted.
			return expression.AsNumericLiteral().TokenFlags & TokenFlagsWithSpecifier == 0
				&& text.indexOf(Scanner.TokenToString(KindDotToken)) < 0
				&& text.indexOf("E") < 0
				&& text.indexOf("e") < 0;
		}
		return false;
	}

	function emitPropertyAccessExpression(node:PropertyAccessExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, Core.IfElse(Ast.IsOptionalChain(node.AsNode()), OperatorPrecedenceOptionalChain, OperatorPrecedenceMember));
		var token = node.QuestionDotToken;
		if (token == null) {
			token = emitContext.Factory.NewToken(KindDotToken);
			token.Loc = Core.NewTextRange(node.Expression.End(), node.AsNode().Name().Pos());
			emitContext.AddEmitFlags(token, EFNoSourceMap);
		}
		final linesBeforeDot = getLinesBetweenNodes(node.AsNode(), node.Expression, token);
		writeLineRepeat(linesBeforeDot);
		increaseIndentIf(linesBeforeDot > 0);
		final shouldEmitDotDot = token.Kind != KindQuestionDotToken
			&& mayNeedDotDotForPropertyAccess(node.Expression)
			&& !writer.HasTrailingComment()
			&& !writer.HasTrailingWhitespace();
		if (shouldEmitDotDot) {
			writePunctuation(".");
		}
		if (node.QuestionDotToken != null) {
			emitTokenNode(token);
		} else {
			emitToken(KindDotToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		}
		final linesAfterDot = getLinesBetweenNodes(node.AsNode(), token, node.AsNode().Name());
		writeLineRepeat(linesAfterDot);
		increaseIndentIf(linesAfterDot > 0);
		emitMemberName(node.AsNode().Name());
		decreaseIndentIf(linesAfterDot > 0);
		decreaseIndentIf(linesBeforeDot > 0);
		exitNode(node.AsNode(), state);
	}

	function emitElementAccessExpression(node:ElementAccessExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, Core.IfElse(Ast.IsOptionalChain(node.AsNode()), OperatorPrecedenceOptionalChain, OperatorPrecedenceMember));
		emitTokenNode(node.QuestionDotToken);
		emitToken(KindOpenBracketToken, greatestEnd(-1, node.Expression, node.QuestionDotToken), WriteKindPunctuation, node.AsNode());
		emitExpression(node.ArgumentExpression, OperatorPrecedenceComma);
		emitToken(KindCloseBracketToken, node.ArgumentExpression.End(), WriteKindPunctuation, node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitArgument(node:Expression):Void {
		emitExpression(node, OperatorPrecedenceSpread);
	}

	function emitCallee(callee:Expression, parentNode:Node):Void {
		if (shouldEmitIndirectCall(parentNode)) {
			writePunctuation("(");
			writeLiteral("0");
			writePunctuation(",");
			writeSpace();
			emitExpression(callee, OperatorPrecedenceComma);
			writePunctuation(")");
		} else if (parentNode.Kind == KindCallExpression && isNewExpressionWithoutArguments(Ast.SkipPartiallyEmittedExpressions(callee))) {
			// Parenthesize `new C` inside of a CallExpression so it is treated as `(new C)()` and not `new C()`
			emitExpression(callee, OperatorPrecedenceParentheses);
		} else {
			emitExpression(callee, Core.IfElse(Ast.IsOptionalChain(parentNode), OperatorPrecedenceOptionalChain, OperatorPrecedenceMember));
		}
	}

	function emitCallExpression(node:CallExpression):Void {
		final state = enterNode(node.AsNode());
		emitCallee(node.Expression, node.AsNode());
		emitTokenNode(node.QuestionDotToken);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		emitList(fn_emitArgument, node.AsNode(), node.Arguments, LFCallExpressionArguments);
		exitNode(node.AsNode(), state);
	}

	function emitNewExpression(node:NewExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindNewKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (Ast.SkipPartiallyEmittedExpressions(node.Expression).Kind == KindCallExpression) {
			// Parenthesize `C()` inside of a NewExpression so it is treated as `new (C())` and not `new C()`
			emitExpression(node.Expression, OperatorPrecedenceParentheses);
		} else {
			emitExpression(node.Expression, OperatorPrecedenceMember);
		}
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		emitList(fn_emitArgument, node.AsNode(), node.Arguments, LFNewExpressionArguments);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateLiteral(node:TemplateLiteral):Void {
		switch (node.Kind) {
			case KindNoSubstitutionTemplateLiteral:
				emitNoSubstitutionTemplateLiteral(node.AsNoSubstitutionTemplateLiteral());
			case KindTemplateExpression:
				emitTemplateExpression(node.AsTemplateExpression());
			default:
				throw 'unhandled TemplateLiteral: ${node.Kind.String()}';
		}
	}

	function emitTaggedTemplateExpression(node:TaggedTemplateExpression):Void {
		final state = enterNode(node.AsNode());
		emitCallee(node.Tag, node.AsNode());
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		writeSpace();
		emitTemplateLiteral(node.Template);
		exitNode(node.AsNode(), state);
	}

	function emitTypeAssertionExpression(node:TypeAssertion):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("<");
		emitTypeNodeOutsideExtends(node.Type);
		writePunctuation(">");
		emitExpression(node.Expression, OperatorPrecedenceUpdate);
		exitNode(node.AsNode(), state);
	}

	function emitParenthesizedExpression(node:ParenthesizedExpression):Void {
		final state = enterNode(node.AsNode());
		final openParenPos = emitToken(KindOpenParenToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		final indented = writeLineSeparatorsAndIndentBefore(node.Expression, node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceComma);
		writeLineSeparatorsAfter(node.Expression, node.AsNode());
		decreaseIndentIf(indented);
		var closeParenPos = openParenPos;
		if (node.Expression != null) {
			closeParenPos = node.Expression.End();
		}
		emitToken(KindCloseParenToken, closeParenPos, WriteKindPunctuation, node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitFunctionExpression(node:FunctionExpression):Void {
		final state = enterNode(node.AsNode());
		generateNameIfNeeded(node.AsNode().Name());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("function");
		emitTokenNode(node.AsteriskToken);
		writeSpace();
		emitIdentifierNameNode(node.AsNode().Name());
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		emitFunctionBodyNode(node.Body);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitConciseBody(node:BlockOrExpression):Void {
		if (Ast.IsBlock(node)) {
			emitFunctionBody(node.AsBlock());
		} else if (Ast.IsObjectLiteralExpression(Ast.GetLeftmostExpression(node, false /*stopAtCallExpressions*/))) {
			// Wrap in ParenthesizedExpression to ensure parens are emitted after any leading
			// PartiallyEmittedExpression comments, matching TypeScript's factory-time wrapping
			// via parenthesizeConciseBodyOfArrowFunction.
			final paren = emitContext.Factory.NewParenthesizedExpression(node);
			paren.Loc = node.Loc;
			emitExpression(paren, OperatorPrecedenceLowest);
		} else if (Ast.IsExpression(node)) {
			emitExpression(node, OperatorPrecedenceYield);
		} else {
			throw 'unexpected ConciseBody: ${node.Kind.String()}';
		}
	}

	function emitArrowFunction(node:ArrowFunction):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitParametersForArrow(node.AsNode(), node.Parameters);
		emitTypeAnnotation(node.Type);
		writeSpace();
		emitTokenNode(node.EqualsGreaterThanToken);
		writeSpace();
		emitConciseBody(node.Body);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitDeleteExpression(node:DeleteExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindDeleteKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceUnary);
		exitNode(node.AsNode(), state);
	}

	function emitTypeOfExpression(node:TypeOfExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindTypeOfKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceUnary);
		exitNode(node.AsNode(), state);
	}

	function emitVoidExpression(node:VoidExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindVoidKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceUnary);
		exitNode(node.AsNode(), state);
	}

	function emitAwaitExpression(node:AwaitExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindAwaitKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceUnary);
		exitNode(node.AsNode(), state);
	}

	function emitPrefixUnaryExpression(node:PrefixUnaryExpression):Void {
		final state = enterNode(node.AsNode());
		final operator_ = node.Operator;
		final operand = node.Operand;
		emitToken(operator_, node.Pos(), WriteKindOperator, node.AsNode());

		// In some cases, we need to emit a space between the operator and the operand. One obvious case
		// is when the operator is an identifier, like delete or typeof. We also need to do this for plus
		// and minus expressions in certain cases. Specifically, consider the following two cases (parens
		// are just for clarity of exposition, and not part of the source code):
		//
		//  (+(+1))
		//  (+(++1))
		//
		// We need to emit a space in both cases. In the first case, the absence of a space will make
		// the resulting expression a prefix increment operation. And in the second, it will make the resulting
		// expression a prefix increment whose operand is a plus expression - (++(+x))
		// The same is true of minus of course.
		if (operand.Kind == KindPrefixUnaryExpression) {
			final inner = operand.AsPrefixUnaryExpression().Operator;
			if ((operator_ == KindPlusToken && (inner == KindPlusToken || inner == KindPlusPlusToken))
				|| (operator_ == KindMinusToken && (inner == KindMinusToken || inner == KindMinusMinusToken))) {
				writeSpace();
			}
		}

		emitExpression(node.Operand, OperatorPrecedenceUnary);
		exitNode(node.AsNode(), state);
	}

	function emitPostfixUnaryExpression(node:PostfixUnaryExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Operand, OperatorPrecedenceLeftHandSide);
		emitToken(node.Operator, node.Operand.End(), WriteKindOperator, node.AsNode());
		exitNode(node.AsNode(), state);
	}

	// This function determines whether an expression consists of a homogeneous set of
	// literal expressions or binary plus expressions that all share the same literal kind.
	// It is used to determine whether the right-hand operand of a binary plus expression can be
	// emitted without parentheses.
	function getLiteralKindOfBinaryPlusOperand(node:Expression):Kind {
		node = Ast.SkipPartiallyEmittedExpressions(node);

		if (Ast.IsLiteralKind(node.Kind)) {
			return node.Kind;
		}

		if (node.Kind == KindBinaryExpression) {
			final n = node.AsBinaryExpression();
			if (n.OperatorToken.Kind == KindPlusToken) {
				// !!! Determine if caching this is worthwhile over recomputing
				////if n.cachedLiteralKind != KindUnknown {
				////	return n.cachedLiteralKind;
				////}

				final leftKind = getLiteralKindOfBinaryPlusOperand(n.Left);
				var literalKind = KindUnknown;
				if (Ast.IsLiteralKind(leftKind) && leftKind == getLiteralKindOfBinaryPlusOperand(n.Right)) {
					literalKind = leftKind;
				}

				////n.cachedLiteralKind = literalKind;
				return literalKind;
			}
		}

		return KindUnknown;
	}

	// PORT: Go returns (leftPrec, rightPrec) → returns leftPrec, rightPrec in outRightPrec.
	function getBinaryExpressionPrecedence(node:BinaryExpression):OperatorPrecedence {
		final precedence = Ast.GetExpressionPrecedence(node.AsNode());
		var leftPrec = precedence;
		var rightPrec = precedence;
		switch (precedence) {
			case OperatorPrecedenceComma:
				// No need to parenthesize the right operand when the binary operator and
				// operand are both ,:
				//  x,(a,b)     => x,a,b
			case OperatorPrecedenceAssignment:
				// assignment is right-associative
				leftPrec = OperatorPrecedenceConditional;
				rightPrec = OperatorPrecedenceYield;
			case OperatorPrecedenceLogicalOR:
				rightPrec = OperatorPrecedenceLogicalAND;
			case OperatorPrecedenceLogicalAND:
				rightPrec = OperatorPrecedenceBitwiseOR;
			case OperatorPrecedenceBitwiseOR:
				// No need to parenthesize the right operand when the binary operator and
				// operand are both | due to the associative property of mathematics:
				//  x|(a|b)     => x|a|b
			case OperatorPrecedenceBitwiseXOR:
				// No need to parenthesize the right operand when the binary operator and
				// operand are both ^ due to the associative property of mathematics:
				//  x^(a^b)     => x^a^b
			case OperatorPrecedenceBitwiseAND:
				// No need to parenthesize the right operand when the binary operator and
				// operand are both & due to the associative property of mathematics:
				//  x&(a&b)     => x&a&b
			case OperatorPrecedenceEquality:
				rightPrec = OperatorPrecedenceRelational;
			case OperatorPrecedenceRelational:
				rightPrec = OperatorPrecedenceShift;
			case OperatorPrecedenceShift:
				rightPrec = OperatorPrecedenceAdditive;
			case OperatorPrecedenceAdditive:
				// PORT: Go `break` out of the switch → a flag (PORTING.md §4).
				var done = false;
				if (node.OperatorToken.Kind == KindPlusToken && isBinaryOperation(node.Right, KindPlusToken)) {
					final leftKind = getLiteralKindOfBinaryPlusOperand(node.Left);
					if (Ast.IsLiteralKind(leftKind) && leftKind == getLiteralKindOfBinaryPlusOperand(node.Right)) {
						// No need to parenthesize the right operand when the binary operator
						// is plus (+) if both the left and right operands consist solely of either
						// literals of the same kind or binary plus (+) expressions for literals of
						// the same kind (recursively).
						//  "a"+(1+2)       => "a"+(1+2)
						//  "a"+("b"+"c")   => "a"+"b"+"c"
						done = true;
					}
				}
				if (!done) {
					rightPrec = OperatorPrecedenceMultiplicative;
				}
			case OperatorPrecedenceMultiplicative:
				if (node.OperatorToken.Kind == KindAsteriskToken && isBinaryOperation(node.Right, KindAsteriskToken)) {
					// No need to parenthesize the right operand when the binary operator and
					// operand are both * due to the associative property of mathematics:
					//  x*(a*b)     => x*a*b
				} else {
					rightPrec = OperatorPrecedenceExponentiation;
				}
			case OperatorPrecedenceExponentiation:
				// exponentiation is right-associative
				leftPrec = OperatorPrecedenceUpdate;
			default:
				throw 'unhandled precedence: ${(precedence : Int)}';
		}
		outRightPrec = rightPrec;
		return leftPrec;
	}

	function emitBinaryExpression(node:BinaryExpression):Void {
		var leftPrec = getBinaryExpressionPrecedence(node);
		var rightPrec = outRightPrec;
		final emittedLeft = Ast.SkipPartiallyEmittedExpressions(node.Left);
		if (Ast.NodeIsSynthesized(emittedLeft)
			&& emittedLeft.Kind == KindBinaryExpression
			&& mixingBinaryOperatorsRequiresParentheses(node.OperatorToken.Kind, emittedLeft.AsBinaryExpression().OperatorToken.Kind)) {
			leftPrec = OperatorPrecedenceHighest;
		}
		final emittedRight = Ast.SkipPartiallyEmittedExpressions(node.Right);
		if (Ast.NodeIsSynthesized(emittedRight)
			&& emittedRight.Kind == KindBinaryExpression
			&& mixingBinaryOperatorsRequiresParentheses(node.OperatorToken.Kind, emittedRight.AsBinaryExpression().OperatorToken.Kind)) {
			rightPrec = OperatorPrecedenceHighest;
		}
		final state = enterNode(node.AsNode());
		emitExpression(node.Left, leftPrec);
		final linesBeforeOperator = getLinesBetweenNodes(node.AsNode(), node.Left, node.OperatorToken);
		final linesAfterOperator = getLinesBetweenNodes(node.AsNode(), node.OperatorToken, node.Right);
		writeLinesAndIndent(linesBeforeOperator, node.OperatorToken.Kind != KindCommaToken /*writeSpaceIfNotIndenting*/);
		emitTokenNodeEx(node.OperatorToken, tefNoSourceMaps);
		writeLinesAndIndent(linesAfterOperator, true /*writeSpaceIfNotIndenting*/); // Binary operators should have a space before the comment starts
		emitExpression(node.Right, rightPrec);
		decreaseIndentIf(linesAfterOperator > 0);
		decreaseIndentIf(linesBeforeOperator > 0);
		exitNode(node.AsNode(), state);
	}

	function emitShortCircuitExpression(node:Expression):Void {
		if (isBinaryOperation(Ast.SkipPartiallyEmittedExpressions(node), KindQuestionQuestionToken)) {
			emitExpression(node, OperatorPrecedenceCoalesce);
		} else {
			emitExpression(node, OperatorPrecedenceLogicalOR);
		}
	}

	function emitConditionalExpression(node:ConditionalExpression):Void {
		final state = enterNode(node.AsNode());
		final linesBeforeQuestion = getLinesBetweenNodes(node.AsNode(), node.Condition, node.QuestionToken);
		final linesAfterQuestion = getLinesBetweenNodes(node.AsNode(), node.QuestionToken, node.WhenTrue);
		final linesBeforeColon = getLinesBetweenNodes(node.AsNode(), node.WhenTrue, node.ColonToken);
		final linesAfterColon = getLinesBetweenNodes(node.AsNode(), node.ColonToken, node.WhenFalse);
		emitShortCircuitExpression(node.Condition);
		writeLinesAndIndent(linesBeforeQuestion /*writeSpaceIfNotIndenting*/, true);
		emitPunctuationNode(node.QuestionToken);
		writeLinesAndIndent(linesAfterQuestion /*writeSpaceIfNotIndenting*/, true);
		emitExpression(node.WhenTrue, OperatorPrecedenceYield);
		decreaseIndentIf(linesAfterQuestion > 0);
		decreaseIndentIf(linesBeforeQuestion > 0);
		writeLinesAndIndent(linesBeforeColon /*writeSpaceIfNotIndenting*/, true);
		emitPunctuationNode(node.ColonToken);
		writeLinesAndIndent(linesAfterColon /*writeSpaceIfNotIndenting*/, true);
		emitExpression(node.WhenFalse, OperatorPrecedenceYield);
		decreaseIndentIf(linesAfterColon > 0);
		decreaseIndentIf(linesBeforeColon > 0);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateExpression(node:TemplateExpression):Void {
		final state = enterNode(node.AsNode());
		emitTemplateHead(node.Head.AsTemplateHead());
		emitList(fn_emitTemplateSpanNode, node.AsNode(), node.TemplateSpans, LFTemplateExpressionSpans);
		exitNode(node.AsNode(), state);
	}

	function emitYieldExpression(node:YieldExpression):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindYieldKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		emitPunctuationNode(node.AsteriskToken);
		if (node.Expression != null) {
			writeSpace();
			emitExpressionNoASI(node.Expression, OperatorPrecedenceDisallowComma);
		}
		exitNode(node.AsNode(), state);
	}

	function emitSpreadElement(node:SpreadElement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindDotDotDotToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceDisallowComma);
		exitNode(node.AsNode(), state);
	}

	function emitClassExpression(node:ClassExpression):Void {
		final state = enterNode(node.AsNode());
		generateNameIfNeeded(node.AsNode().Name());

		final pos = emitModifierList(node.AsNode(), node.AsNode().Modifiers(), true /*allowDecorators*/);
		emitToken(KindClassKeyword, pos, WriteKindKeyword, node.AsNode());

		if (node.AsNode().Name() != null) {
			writeSpace();
			emitIdentifierName(node.AsNode().Name().AsIdentifier());
		}

		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);

		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitList(fn_emitHeritageClauseNode, node.AsNode(), node.HeritageClauses, LFClassHeritageClauses);
		writeSpace();
		writePunctuation("{");
		pushNameGenerationScope(node.AsNode());
		generateAllMemberNames(node.Members);
		emitList(fn_emitClassElement, node.AsNode(), node.Members, LFClassMembers);
		popNameGenerationScope(node.AsNode());
		writePunctuation("}");

		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitOmittedExpression(node:Node):Void {
		exitNode(node, enterNode(node));
	}

	function emitExpressionWithTypeArguments(node:ExpressionWithTypeArguments):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceMember);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		exitNode(node.AsNode(), state);
	}

	function emitExpressionWithTypeArgumentsNode(node:ExpressionWithTypeArgumentsNode):Void {
		emitExpressionWithTypeArguments(node.AsExpressionWithTypeArguments());
	}

	function emitAsExpression(node:AsExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceRelational);
		writeSpace();
		writeKeyword("as");
		writeSpace();
		emitTypeNodeOutsideExtends(node.Type);
		exitNode(node.AsNode(), state);
	}

	function emitSatisfiesExpression(node:SatisfiesExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceRelational);
		writeSpace();
		writeKeyword("satisfies");
		writeSpace();
		emitTypeNodeOutsideExtends(node.Type);
		exitNode(node.AsNode(), state);
	}

	function emitNonNullExpression(node:NonNullExpression):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceMember);
		writeOperator("!");
		exitNode(node.AsNode(), state);
	}

	function emitMetaProperty(node:MetaProperty):Void {
		final state = enterNode(node.AsNode());
		emitToken(node.KeywordToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		writePunctuation(".");
		emitIdentifierName(node.AsNode().Name().AsIdentifier());
		exitNode(node.AsNode(), state);
	}

	function emitPartiallyEmittedExpression(node:PartiallyEmittedExpression):Void {
		// avoid reprinting parens for nested partially emitted expressions
		// PORT: local Go type `entry` + core.Stack[entry] → two parallel arrays used as a stack.
		final stackNodes:Array<PartiallyEmittedExpression> = [];
		final stackStates:Array<PrinterState> = [];
		while (true) {
			final state = enterNode(node.AsNode());
			final emitFlags = emitContext.EmitFlags(node.AsNode());
			if (emitFlags & EFNoLeadingComments == 0 && node.Pos() != node.Expression.Pos()) {
				emitTrailingCommentsOfPosition(node.Expression.Pos(), false /*prefixSpace*/, false /*forceNoNewline*/);
			}
			stackNodes.push(node);
			stackStates.push(state);
			if (!Ast.IsPartiallyEmittedExpression(node.Expression)) {
				break;
			}
			node = node.Expression.AsPartiallyEmittedExpression();
		}

		emitExpression(node.Expression, OperatorPrecedenceLowest);

		// unwind stack
		while (stackNodes.length > 0) {
			final entryNode = stackNodes.pop();
			final entryState = stackStates.pop();
			final emitFlags = emitContext.EmitFlags(node.AsNode());
			if (emitFlags & EFNoTrailingComments == 0 && node.End() != node.Expression.End()) {
				emitLeadingCommentsOfPosition(node.Expression.End());
			}
			exitNode(node.AsNode(), entryState);
			node = entryNode;
		}
	}

	function commentWillEmitNewLine(comment:CommentRange):Bool {
		return comment.Kind == KindSingleLineCommentTrivia || comment.HasTrailingNewLine;
	}

	function syntheticCommentWillEmitNewLine(comment:SynthesizedComment):Bool {
		return comment.Kind == KindSingleLineCommentTrivia || comment.HasTrailingNewLine;
	}

	function willEmitLeadingNewLine(node:Expression):Bool {
		if (currentSourceFile == null) {
			return false;
		}
		var hasLeadingCommentRanges = false;
		var hasNewLineComment = false;
		for (comment in Scanner.GetLeadingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), node.Pos())) {
			hasLeadingCommentRanges = true;
			if (commentWillEmitNewLine(comment)) {
				hasNewLineComment = true;
			}
		}
		if (hasLeadingCommentRanges) {
			final parseNode = emitContext.ParseNode(node);
			if (parseNode != null && Ast.IsParenthesizedExpression(parseNode.Parent)) {
				return true;
			}
		}
		if (hasNewLineComment) {
			return true;
		}
		final synth = emitContext.GetSyntheticLeadingComments(node);
		if (synth != null) {
			for (c in synth) {
				if (syntheticCommentWillEmitNewLine(c)) {
					return true;
				}
			}
		}
		if (Ast.IsPartiallyEmittedExpression(node)) {
			final pee = node.AsPartiallyEmittedExpression();
			if (node.Pos() != pee.Expression.Pos()) {
				for (comment in Scanner.GetTrailingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pee.Expression.Pos())) {
					if (commentWillEmitNewLine(comment)) {
						return true;
					}
				}
			}
			return willEmitLeadingNewLine(pee.Expression);
		}
		return false;
	}

	// parenthesizeExpressionForNoAsi wraps an expression in parens if we would emit a leading comment
	// that would introduce a line separator between the node and its parent.
	function parenthesizeExpressionForNoAsi(node:Expression):Expression {
		if (!commentsDisabled) {
			switch (node.Kind) {
				case KindPartiallyEmittedExpression:
					if (willEmitLeadingNewLine(node)) {
						final pee = node.AsPartiallyEmittedExpression();
						final parseNode = emitContext.ParseNode(node);
						if (parseNode != null && Ast.IsParenthesizedExpression(parseNode)) {
							// If the original node was a parenthesized expression, restore it to preserve comment and source map emit
							final parens = emitContext.Factory.NewParenthesizedExpression(pee.Expression);
							emitContext.SetOriginal(parens, node);
							parens.Loc = parseNode.Loc;
							return parens;
						}
						return emitContext.Factory.NewParenthesizedExpression(node);
					}
					final pee = node.AsPartiallyEmittedExpression();
					return emitContext.Factory.UpdatePartiallyEmittedExpression(pee, parenthesizeExpressionForNoAsi(pee.Expression));
				case KindPropertyAccessExpression:
					final pae = node.AsPropertyAccessExpression();
					return emitContext.Factory.UpdatePropertyAccessExpression(pae, parenthesizeExpressionForNoAsi(pae.Expression), pae.QuestionDotToken,
						pae.AsNode().Name(), pae.AsNode().Flags);
				case KindElementAccessExpression:
					final eae = node.AsElementAccessExpression();
					return emitContext.Factory.UpdateElementAccessExpression(eae, parenthesizeExpressionForNoAsi(eae.Expression), eae.QuestionDotToken,
						eae.ArgumentExpression, eae.AsNode().Flags);
				case KindCallExpression:
					final ce = node.AsCallExpression();
					return emitContext.Factory.UpdateCallExpression(ce, parenthesizeExpressionForNoAsi(ce.Expression), ce.QuestionDotToken, ce.TypeArguments,
						ce.Arguments, ce.AsNode().Flags);
				case KindTaggedTemplateExpression:
					final tte = node.AsTaggedTemplateExpression();
					return emitContext.Factory.UpdateTaggedTemplateExpression(tte, parenthesizeExpressionForNoAsi(tte.Tag), tte.QuestionDotToken,
						tte.TypeArguments, tte.Template, tte.AsNode().Flags);
				case KindPostfixUnaryExpression:
					final pue = node.AsPostfixUnaryExpression();
					return emitContext.Factory.UpdatePostfixUnaryExpression(pue, parenthesizeExpressionForNoAsi(pue.Operand), pue.Operator);
				case KindBinaryExpression:
					final be = node.AsBinaryExpression();
					return emitContext.Factory.UpdateBinaryExpression(be, be.AsNode().Modifiers(), parenthesizeExpressionForNoAsi(be.Left), be.Type,
						be.OperatorToken, be.Right);
				case KindConditionalExpression:
					final ce = node.AsConditionalExpression();
					return emitContext.Factory.UpdateConditionalExpression(ce, parenthesizeExpressionForNoAsi(ce.Condition), ce.QuestionToken, ce.WhenTrue,
						ce.ColonToken, ce.WhenFalse);
				case KindAsExpression:
					final ae = node.AsAsExpression();
					return emitContext.Factory.UpdateAsExpression(ae, parenthesizeExpressionForNoAsi(ae.Expression), ae.Type);
				case KindSatisfiesExpression:
					final se = node.AsSatisfiesExpression();
					return emitContext.Factory.UpdateSatisfiesExpression(se, parenthesizeExpressionForNoAsi(se.Expression), se.Type);
				case KindNonNullExpression:
					final nne = node.AsNonNullExpression();
					return emitContext.Factory.UpdateNonNullExpression(nne, parenthesizeExpressionForNoAsi(nne.Expression), nne.AsNode().Flags);
				default:
			}
		}
		return node;
	}

	function emitExpressionNoASI(node:Expression, precedence:OperatorPrecedence):Void {
		node = parenthesizeExpressionForNoAsi(node);
		emitExpression(node, precedence);
	}

	function emitExpression(node:Expression, precedence:OperatorPrecedence):Void {
		final parens = (Ast.GetExpressionPrecedence(Ast.SkipPartiallyEmittedExpressions(node)) : Int) < (precedence : Int);
		if (parens) {
			writePunctuation("(");
		}

		switch (node.Kind) {
			// Keywords
			case KindTrueKeyword | KindFalseKeyword | KindNullKeyword:
				emitTokenNode(node);
			case KindThisKeyword | KindSuperKeyword | KindImportKeyword:
				emitKeywordExpression(node.AsKeywordExpression());

			// Literals
			case KindNumericLiteral:
				emitNumericLiteral(node.AsNumericLiteral());
			case KindBigIntLiteral:
				emitBigIntLiteral(node.AsBigIntLiteral());
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			case KindRegularExpressionLiteral:
				emitRegularExpressionLiteral(node.AsRegularExpressionLiteral());
			case KindNoSubstitutionTemplateLiteral:
				emitNoSubstitutionTemplateLiteral(node.AsNoSubstitutionTemplateLiteral());

			// Identifiers
			case KindIdentifier:
				emitIdentifierReference(node.AsIdentifier());
			case KindPrivateIdentifier:
				emitPrivateIdentifier(node.AsPrivateIdentifier());

			// Expressions
			case KindArrayLiteralExpression:
				emitArrayLiteralExpression(node.AsArrayLiteralExpression());
			case KindObjectLiteralExpression:
				emitObjectLiteralExpression(node.AsObjectLiteralExpression());
			case KindPropertyAccessExpression:
				emitPropertyAccessExpression(node.AsPropertyAccessExpression());
			case KindElementAccessExpression:
				emitElementAccessExpression(node.AsElementAccessExpression());
			case KindCallExpression:
				emitCallExpression(node.AsCallExpression());
			case KindNewExpression:
				emitNewExpression(node.AsNewExpression());
			case KindTaggedTemplateExpression:
				emitTaggedTemplateExpression(node.AsTaggedTemplateExpression());
			case KindTypeAssertionExpression:
				emitTypeAssertionExpression(node.AsTypeAssertion());
			case KindParenthesizedExpression:
				emitParenthesizedExpression(node.AsParenthesizedExpression());
			case KindFunctionExpression:
				emitFunctionExpression(node.AsFunctionExpression());
			case KindArrowFunction:
				emitArrowFunction(node.AsArrowFunction());
			case KindDeleteExpression:
				emitDeleteExpression(node.AsDeleteExpression());
			case KindTypeOfExpression:
				emitTypeOfExpression(node.AsTypeOfExpression());
			case KindVoidExpression:
				emitVoidExpression(node.AsVoidExpression());
			case KindAwaitExpression:
				emitAwaitExpression(node.AsAwaitExpression());
			case KindPrefixUnaryExpression:
				emitPrefixUnaryExpression(node.AsPrefixUnaryExpression());
			case KindPostfixUnaryExpression:
				emitPostfixUnaryExpression(node.AsPostfixUnaryExpression());
			case KindBinaryExpression:
				emitBinaryExpression(node.AsBinaryExpression());
			case KindConditionalExpression:
				emitConditionalExpression(node.AsConditionalExpression());
			case KindTemplateExpression:
				emitTemplateExpression(node.AsTemplateExpression());
			case KindYieldExpression:
				emitYieldExpression(node.AsYieldExpression());
			case KindSpreadElement:
				emitSpreadElement(node.AsSpreadElement());
			case KindClassExpression:
				emitClassExpression(node.AsClassExpression());
			case KindOmittedExpression:
				emitOmittedExpression(node);
			case KindAsExpression:
				emitAsExpression(node.AsAsExpression());
			case KindNonNullExpression:
				emitNonNullExpression(node.AsNonNullExpression());
			case KindExpressionWithTypeArguments:
				emitExpressionWithTypeArguments(node.AsExpressionWithTypeArguments());
			case KindSatisfiesExpression:
				emitSatisfiesExpression(node.AsSatisfiesExpression());
			case KindMetaProperty:
				emitMetaProperty(node.AsMetaProperty());
			case KindSyntheticExpression:
				throw "SyntheticExpression should never be printed.";
			case KindMissingDeclaration:

			// JSX
			case KindJsxElement:
				emitJsxElement(node.AsJsxElement());
			case KindJsxSelfClosingElement:
				emitJsxSelfClosingElement(node.AsJsxSelfClosingElement());
			case KindJsxFragment:
				emitJsxFragment(node.AsJsxFragment());

			// Synthesized list
			case KindSyntaxList:
				throw "SyntaxList should not be printed";

			// Transformation nodes
			case KindNotEmittedStatement:
				return;
			case KindPartiallyEmittedExpression:
				emitPartiallyEmittedExpression(node.AsPartiallyEmittedExpression());
			case KindSyntheticReferenceExpression:
				throw "SyntheticReferenceExpression should not be printed";

			default:
				throw 'unexpected Expression: ${node.Kind.String()}';
		}

		if (parens) {
			writePunctuation(")");
		}
	}

	//
	// Misc
	//

	function emitTemplateSpan(node:TemplateSpan):Void {
		final state = enterNode(node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceComma);
		emitTemplateMiddleTail(node.Literal);
		exitNode(node.AsNode(), state);
	}

	function emitTemplateSpanNode(node:TemplateSpanNode):Void {
		emitTemplateSpan(node.AsTemplateSpan());
	}

	function emitSemicolonClassElement(node:SemicolonClassElement):Void {
		final state = enterNode(node.AsNode());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	//
	// Statements
	//

	function isEmptyBlock(block:Node, statements:StatementList):Bool {
		return Core.len(statements.Nodes) == 0
			&& (currentSourceFile == null || rangeEndIsOnSameLineAsRangeStart(block.Loc, block.Loc, currentSourceFile));
	}

	function emitBlock(node:Block):Void {
		final state = enterNode(node.AsNode());
		generateNames(node.AsNode());
		emitToken(KindOpenBraceToken, node.Pos(), WriteKindPunctuation, node.AsNode());

		final format = Core.IfElse(!node.MultiLine && isEmptyBlock(node.AsNode(), node.Statements) || shouldEmitOnSingleLine(node.AsNode()),
			LFSingleLineBlockStatements, LFMultiLineBlockStatements);
		emitList(fn_emitStatement, node.AsNode(), node.Statements, format);

		emitTokenEx(KindCloseBraceToken, node.Statements.End(), WriteKindPunctuation, node.AsNode(),
			Core.IfElse(format & LFMultiLine != 0, tefIndentLeadingComments, tefNone));
		exitNode(node.AsNode(), state);
	}

	function emitVariableStatement(node:VariableStatement):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		emitVariableDeclarationList(node.DeclarationList.AsVariableDeclarationList());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitEmptyStatement(node:EmptyStatement, isEmbeddedStatement:Bool):Void {
		final state = enterNode(node.AsNode());

		// While most trailing semicolons are possibly insignificant, an embedded "empty"
		// statement is significant and cannot be elided by a trailing-semicolon-omitting writer.
		if (isEmbeddedStatement) {
			writePunctuation(";");
		} else {
			writeTrailingSemicolon();
		}
		exitNode(node.AsNode(), state);
	}

	function emitExpressionStatement(node:ExpressionStatement):Void {
		final state = enterNode(node.AsNode());

		if (currentSourceFile != null && currentSourceFile.ScriptKind == ScriptKindJSON) {
			// !!! In strada, this was handled by an undefined parenthesizerRule, so this is a hack.
			emitExpression(node.Expression, OperatorPrecedenceComma);
		} else if (isImmediatelyInvokedFunctionExpressionOrArrowFunction(node.Expression)) {
			// For IIFEs, parenthesize just the callee (not the whole call), matching TypeScript's
			// parenthesizeExpressionOfExpressionStatement which wraps the function/arrow in parens:
			//   (function() { })()  -- not (function() { }())
			emitIIFEWithParenthesizedCallee(node.Expression);
		} else {
			switch (Ast.GetLeftmostExpression(node.Expression, false /*stopAtCallExpression*/).Kind) {
				case KindFunctionExpression | KindObjectLiteralExpression:
					emitExpression(node.Expression, OperatorPrecedenceParentheses);
				default:
					emitExpression(node.Expression, OperatorPrecedenceComma);
			}
		}

		// Emit semicolon in non json files
		// or if json file that created synthesized expression(eg.define expression statement when --out and amd code generation)
		if (currentSourceFile == null || currentSourceFile.ScriptKind != ScriptKindJSON || Ast.NodeIsSynthesized(node.Expression)) {
			writeTrailingSemicolon();
		}

		exitNode(node.AsNode(), state);
	}

	// emitIIFEWithParenthesizedCallee emits a call expression that is an IIFE,
	// wrapping just the callee in parens rather than the entire call expression.
	// This matches TypeScript's parenthesizeExpressionOfExpressionStatement behavior:
	//
	//	(function() { })()   -- parens around callee only
	//
	// instead of:
	//
	//	(function() { }())   -- parens around entire call
	function emitIIFEWithParenthesizedCallee(node:Expression):Void {
		// Walk through PartiallyEmittedExpression wrappers to find the call
		final call = Ast.SkipPartiallyEmittedExpressions(node).AsCallExpression();
		final state = enterNode(call.AsNode());
		// Emit the callee wrapped in parens
		writePunctuation("(");
		emitExpression(call.Expression, OperatorPrecedenceLowest);
		writePunctuation(")");
		emitTokenNode(call.QuestionDotToken);
		emitTypeArguments(call.AsNode(), call.TypeArguments);
		emitList(fn_emitArgument, call.AsNode(), call.Arguments, LFCallExpressionArguments);
		exitNode(call.AsNode(), state);
	}

	function emitIfStatement(node:IfStatement):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindIfKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.ThenStatement);
		if (node.ElseStatement != null) {
			writeLineOrSpace(node.AsNode(), node.ThenStatement, node.ElseStatement);
			emitToken(KindElseKeyword, node.ThenStatement.End(), WriteKindKeyword, node.AsNode());
			if (node.ElseStatement.Kind == KindIfStatement) {
				writeSpace();
				emitIfStatement(node.ElseStatement.AsIfStatement());
			} else {
				emitEmbeddedStatement(node.AsNode(), node.ElseStatement);
			}
		}
		exitNode(node.AsNode(), state);
	}

	function emitWhileClause(node:Node, expression:Expression, startPos:Int):Void {
		final pos = emitToken(KindWhileKeyword, startPos, WriteKindKeyword, node);
		writeSpace();
		emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node);
		emitExpression(expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, expression.End(), WriteKindPunctuation, node);
	}

	function emitDoStatement(node:DoStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindDoKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		if (Ast.IsBlock(node.Statement) && !Options.PreserveSourceNewlines) {
			writeSpace();
		} else {
			writeLineOrSpace(node.AsNode(), node.Statement, node.Expression);
		}

		emitWhileClause(node.AsNode(), node.Expression, node.Statement.End());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitWhileStatement(node:WhileStatement):Void {
		final state = enterNode(node.AsNode());
		emitWhileClause(node.AsNode(), node.Expression, node.Pos());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		exitNode(node.AsNode(), state);
	}

	function emitForInitializer(node:ForInitializer):Void {
		if (node.Kind == KindVariableDeclarationList) {
			emitVariableDeclarationList(node.AsVariableDeclarationList());
		} else {
			emitExpression(node, OperatorPrecedenceLowest);
		}
	}

	function emitForStatement(node:ForStatement):Void {
		final state = enterNode(node.AsNode());
		var pos = emitToken(KindForKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		pos = emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node.AsNode());
		if (node.Initializer != null) {
			emitForInitializer(node.Initializer);
			pos = node.Initializer.End();
		}
		pos = emitToken(KindSemicolonToken, pos, WriteKindPunctuation, node.AsNode());
		if (node.Condition != null) {
			writeSpace();
			emitExpression(node.Condition, OperatorPrecedenceLowest);
			pos = node.Condition.End();
		}
		pos = emitToken(KindSemicolonToken, pos, WriteKindPunctuation, node.AsNode());
		if (node.Incrementor != null) {
			writeSpace();
			emitExpression(node.Incrementor, OperatorPrecedenceLowest);
			pos = node.Incrementor.End();
		}
		emitToken(KindCloseParenToken, pos, WriteKindPunctuation, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		exitNode(node.AsNode(), state);
	}

	function emitForInStatement(node:ForInOrOfStatement):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindForKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node.AsNode());
		emitForInitializer(node.Initializer);
		writeSpace();
		emitToken(KindInKeyword, node.Initializer.End(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		exitNode(node.AsNode(), state);
	}

	function emitForOfStatement(node:ForInOrOfStatement):Void {
		final state = enterNode(node.AsNode());
		final openParenPos = emitToken(KindForKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (node.AwaitModifier != null) {
			emitKeywordNode(node.AwaitModifier);
			writeSpace();
		}
		emitToken(KindOpenParenToken, openParenPos, WriteKindPunctuation, node.AsNode());
		emitForInitializer(node.Initializer);
		writeSpace();
		emitToken(KindOfKeyword, node.Initializer.End(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		exitNode(node.AsNode(), state);
	}

	function emitContinueStatement(node:ContinueStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindContinueKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		if (node.Label != null) {
			writeSpace();
			emitLabelIdentifier(node.Label.AsIdentifier());
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitBreakStatement(node:BreakStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindBreakKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		if (node.Label != null) {
			writeSpace();
			emitLabelIdentifier(node.Label.AsIdentifier());
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitReturnStatement(node:ReturnStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindReturnKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		if (node.Expression != null) {
			writeSpace();
			emitExpressionNoASI(node.Expression, OperatorPrecedenceLowest);
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitWithStatement(node:WithStatement):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindWithKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		emitEmbeddedStatement(node.AsNode(), node.Statement);
		exitNode(node.AsNode(), state);
	}

	function emitSwitchStatement(node:SwitchStatement):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindSwitchKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitToken(KindOpenParenToken, pos, WriteKindPunctuation, node.AsNode());
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitToken(KindCloseParenToken, node.Expression.End(), WriteKindPunctuation, node.AsNode());
		writeSpace();
		emitCaseBlock(node.CaseBlock.AsCaseBlock());
		exitNode(node.AsNode(), state);
	}

	function emitLabeledStatement(node:LabeledStatement):Void {
		final state = enterNode(node.AsNode());
		emitLabelIdentifier(node.Label.AsIdentifier());
		emitToken(KindColonToken, node.Label.End(), WriteKindPunctuation, node.AsNode());

		// TODO: use emitEmbeddedStatement rather than writeSpace/emitStatement here after Strada migration as it is
		//       more consistent with similar emit elsewhere. writeSpace/emitStatement is used here to reduce spurious
		//       diffs when testing the Strada migration.
		////p.emitEmbeddedStatement(node.AsNode(), node.Statement)

		writeSpace();
		emitStatement(node.Statement);

		exitNode(node.AsNode(), state);
	}

	function emitThrowStatement(node:ThrowStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindThrowKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpressionNoASI(node.Expression, OperatorPrecedenceLowest);
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitTryStatement(node:TryStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindTryKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitBlock(node.TryBlock.AsBlock());
		if (node.CatchClause != null) {
			writeLineOrSpace(node.AsNode(), node.TryBlock, node.CatchClause);
			emitCatchClause(node.CatchClause.AsCatchClause());
		}
		if (node.FinallyBlock != null) {
			writeLineOrSpace(node.AsNode(), Core.Coalesce(node.CatchClause, node.TryBlock), node.FinallyBlock);
			emitToken(KindFinallyKeyword, Core.Coalesce(node.CatchClause, node.TryBlock).End(), WriteKindKeyword, node.AsNode());
			writeSpace();
			emitBlock(node.FinallyBlock.AsBlock());
		}
		exitNode(node.AsNode(), state);
	}

	function emitDebuggerStatement(node:DebuggerStatement):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindDebuggerKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitNotEmittedStatement(node:NotEmittedStatement):Void {
		exitNode(node.AsNode(), enterNode(node.AsNode()));
	}

	function emitNotEmittedTypeElement(node:NotEmittedTypeElement):Void {
		exitNode(node.AsNode(), enterNode(node.AsNode()));
	}

	//
	// Declarations
	//

	function emitVariableDeclaration(node:VariableDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitBindingName(node.AsNode().Name());
		emitPunctuationNode(node.ExclamationToken);
		emitTypeAnnotation(node.Type);
		emitInitializer(node.Initializer, greatestEnd(node.AsNode().Name().End(), node.Type, emitContext.GetTypeNode(node.AsNode().Name())),
			node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitVariableDeclarationNode(node:VariableDeclarationNode):Void {
		emitVariableDeclaration(node.AsVariableDeclaration());
	}

	function emitVariableDeclarationList(node:VariableDeclarationList):Void {
		final state = enterNode(node.AsNode());
		if (Ast.IsVarLet(node.AsNode())) {
			writeKeyword("let");
		} else if (Ast.IsVarConst(node.AsNode())) {
			writeKeyword("const");
		} else if (Ast.IsVarUsing(node.AsNode())) {
			writeKeyword("using");
		} else if (Ast.IsVarAwaitUsing(node.AsNode())) {
			writeKeyword("await");
			writeSpace();
			writeKeyword("using");
		} else {
			writeKeyword("var");
		}
		writeSpace();
		emitList(fn_emitVariableDeclarationNode, node.AsNode(), node.Declarations, LFVariableDeclarationList);
		exitNode(node.AsNode(), state);
	}

	function emitFunctionDeclaration(node:FunctionDeclaration):Void {
		final state = enterNode(node.AsNode());
		generateNameIfNeeded(node.AsNode().Name());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("function");
		emitTokenNode(node.AsteriskToken);
		writeSpace();
		final name = node.AsNode().Name();
		if (name != null) {
			emitIdentifierName(name.AsIdentifier());
		}
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		pushNameGenerationScope(node.AsNode());
		emitSignature(node.AsNode());
		emitFunctionBodyNode(node.Body);
		popNameGenerationScope(node.AsNode());
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitClassDeclaration(node:ClassDeclaration):Void {
		final state = enterNode(node.AsNode());
		generateNameIfNeeded(node.AsNode().Name());
		final pos = emitModifierList(node.AsNode(), node.AsNode().Modifiers(), true /*allowDecorators*/);
		emitToken(KindClassKeyword, pos, WriteKindKeyword, node.AsNode());
		if (node.AsNode().Name() != null) {
			writeSpace();
			emitIdentifierName(node.AsNode().Name().AsIdentifier());
		}
		final indented = shouldEmitIndented(node.AsNode());
		increaseIndentIf(indented);
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitList(fn_emitHeritageClauseNode, node.AsNode(), node.HeritageClauses, LFClassHeritageClauses);
		writeSpace();
		writePunctuation("{");
		pushNameGenerationScope(node.AsNode());
		generateAllMemberNames(node.Members);
		emitList(fn_emitClassElement, node.AsNode(), node.Members, LFClassMembers);
		popNameGenerationScope(node.AsNode());
		writePunctuation("}");
		decreaseIndentIf(indented);
		exitNode(node.AsNode(), state);
	}

	function emitInterfaceDeclaration(node:InterfaceDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("interface");
		writeSpace();
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		emitList(fn_emitHeritageClauseNode, node.AsNode(), node.HeritageClauses, LFHeritageClauses);
		writeSpace();
		writePunctuation("{");
		pushNameGenerationScope(node.AsNode());
		generateAllMemberNames(node.Members);
		emitList(fn_emitTypeElement, node.AsNode(), node.Members, LFInterfaceMembers);
		popNameGenerationScope(node.AsNode());
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitTypeAliasDeclaration(node:TypeAliasDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("type");
		writeSpace();
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		emitTypeParameters(node.AsNode(), node.TypeParameters);
		writeSpace();
		writePunctuation("=");
		writeSpace();
		emitTypeNodeOutsideExtends(node.Type);
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitEnumDeclaration(node:EnumDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		writeKeyword("enum");
		writeSpace();
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		writeSpace();
		writePunctuation("{");
		emitList(fn_emitEnumMemberNode, node.AsNode(), node.Members, LFEnumMembers);
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitModuleDeclaration(node:ModuleDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		if (node.Keyword != KindGlobalKeyword) {
			writeKeyword(Core.IfElse(node.Keyword == KindNamespaceKeyword, "namespace", "module"));
			writeSpace();
		}
		emitModuleName(node.AsNode().Name());
		var body = node.Body;
		while (body != null && Ast.IsModuleDeclaration(body)) {
			final module = body.AsModuleDeclaration();
			writePunctuation(".");
			emitNestedModuleName(module.AsNode().Name());
			body = module.Body;
		}
		if (body == null) {
			writeTrailingSemicolon();
		} else {
			writeSpace();
			emitModuleBlock(body.AsModuleBlock());
		}
		exitNode(node.AsNode(), state);
	}

	function emitModuleBlock(node:ModuleBlock):Void {
		final state = enterNode(node.AsNode());
		generateNames(node.AsNode());
		emitToken(KindOpenBraceToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		final format = Core.IfElse(isEmptyBlock(node.AsNode(), node.Statements) || shouldEmitOnSingleLine(node.AsNode()), LFSingleLineBlockStatements,
			LFMultiLineBlockStatements);
		emitList(fn_emitStatement, node.AsNode(), node.Statements, format);
		emitTokenEx(KindCloseBraceToken, node.Statements.End(), WriteKindPunctuation, node.AsNode(),
			Core.IfElse(format & LFMultiLine != 0, tefIndentLeadingComments, tefNone));
		exitNode(node.AsNode(), state);
	}

	function emitCaseBlock(node:CaseBlock):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindOpenBraceToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		emitList(fn_emitCaseOrDefaultClauseNode, node.AsNode(), node.Clauses, LFCaseBlockClauses);
		emitTokenEx(KindCloseBraceToken, node.Clauses.End(), WriteKindPunctuation, node.AsNode(), tefIndentLeadingComments);
		exitNode(node.AsNode(), state);
	}

	function emitImportEqualsDeclaration(node:ImportEqualsDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		final pos = emitToken(KindImportKeyword, greatestEnd(node.Pos(), node.AsNode().Modifiers()), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (node.IsTypeOnly) {
			emitToken(KindTypeKeyword, pos, WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		writeSpace();
		emitToken(KindEqualsToken, node.AsNode().Name().End(), WriteKindPunctuation, node.AsNode());
		writeSpace();
		emitModuleReference(node.ModuleReference);
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitModuleReference(node:ModuleReference):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierReference(node.AsIdentifier());
			case KindQualifiedName:
				emitQualifiedName(node.AsQualifiedName());
			case KindExternalModuleReference:
				emitExternalModuleReference(node.AsExternalModuleReference());
			default:
				throw 'unhandled ModuleReference: ${node.Kind.String()}';
		}
	}

	function emitImportDeclaration(node:ImportDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		emitToken(KindImportKeyword, greatestEnd(node.Pos(), node.AsNode().Modifiers()), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (node.ImportClause != null) {
			emitImportClause(node.ImportClause.AsImportClause());
			writeSpace();
			emitToken(KindFromKeyword, node.ImportClause.End(), WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		emitExpression(node.ModuleSpecifier, OperatorPrecedenceLowest);
		if (node.Attributes != null) {
			writeSpace();
			emitImportAttributes(node.Attributes.AsImportAttributes());
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitImportClause(node:ImportClause):Void {
		final state = enterNode(node.AsNode());
		if (node.PhaseModifier != KindUnknown) {
			emitToken(node.PhaseModifier, node.Pos(), WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		final name = node.AsNode().Name();
		if (name != null) {
			emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
			if (node.NamedBindings != null) {
				emitToken(KindCommaToken, name.End(), WriteKindPunctuation, node.AsNode());
				writeSpace();
			}
		}
		emitNamedImportBindings(node.NamedBindings);
		exitNode(node.AsNode(), state);
	}

	function emitNamespaceImport(node:NamespaceImport):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindAsteriskToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		writeSpace();
		emitToken(KindAsKeyword, pos, WriteKindKeyword, node.AsNode());
		writeSpace();
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		exitNode(node.AsNode(), state);
	}

	function emitNamedImports(node:NamedImports):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("{");
		emitList(fn_emitImportSpecifierNode, node.AsNode(), node.Elements, LFNamedImportsOrExportsElements);
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitNamedImportBindings(node:NamedImportBindings):Void {
		if (node == null) {
			return;
		}
		switch (node.Kind) {
			case KindNamespaceImport:
				emitNamespaceImport(node.AsNamespaceImport());
			case KindNamedImports:
				emitNamedImports(node.AsNamedImports());
			default:
				throw 'unhandled NamedImportBindings: ${node.Kind.String()}';
		}
	}

	function emitImportSpecifier(node:ImportSpecifier):Void {
		final state = enterNode(node.AsNode());
		if (node.IsTypeOnly) {
			writeKeyword("type");
			writeSpace();
		}
		if (node.PropertyName != null) {
			emitModuleExportName(node.PropertyName);
			writeSpace();
			emitToken(KindAsKeyword, node.PropertyName.End(), WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		exitNode(node.AsNode(), state);
	}

	function emitImportSpecifierNode(node:ImportSpecifierNode):Void {
		emitImportSpecifier(node.AsImportSpecifier());
	}

	function emitExportAssignment(node:ExportAssignment):Void {
		final state = enterNode(node.AsNode());
		final nextPos = emitToken(KindExportKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (node.IsExportEquals) {
			emitToken(KindEqualsToken, nextPos, WriteKindOperator, node.AsNode());
		} else {
			emitToken(KindDefaultKeyword, nextPos, WriteKindKeyword, node.AsNode());
		}
		writeSpace();
		if (node.IsExportEquals) {
			emitExpression(node.Expression, OperatorPrecedenceAssignment);
		} else {
			// parenthesize `class` and `function` expressions so as not to conflict with exported `class` and `function` declarations
			final expr = Ast.GetLeftmostExpression(node.Expression, false /*stopAtCallExpressions*/);
			if (Ast.IsClassExpression(expr) || Ast.IsFunctionExpression(expr)) {
				emitExpression(node.Expression, OperatorPrecedenceParentheses);
			} else {
				emitExpression(node.Expression, OperatorPrecedenceAssignment);
			}
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitExportDeclaration(node:ExportDeclaration):Void {
		final state = enterNode(node.AsNode());
		emitModifierList(node.AsNode(), node.AsNode().Modifiers(), false /*allowDecorators*/);
		var pos = emitToken(KindExportKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		if (node.IsTypeOnly) {
			pos = emitToken(KindTypeKeyword, pos, WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		if (node.ExportClause != null) {
			emitNamedExportBindings(node.ExportClause);
		} else {
			pos = emitToken(KindAsteriskToken, pos, WriteKindPunctuation, node.AsNode());
		}
		if (node.ModuleSpecifier != null) {
			writeSpace();
			emitToken(KindFromKeyword, greatestEnd(pos, node.ExportClause), WriteKindKeyword, node.AsNode());
			writeSpace();
			emitExpression(node.ModuleSpecifier, OperatorPrecedenceLowest);
		}
		if (node.Attributes != null) {
			writeSpace();
			emitImportAttributes(node.Attributes.AsImportAttributes());
		}
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitImportAttributes(node:ImportAttributes):Void {
		final state = enterNode(node.AsNode());
		emitToken(node.Token, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitList(fn_emitImportAttributeNode, node.AsNode(), node.Attributes, LFImportAttributes);
		exitNode(node.AsNode(), state);
	}

	function emitImportAttribute(node:ImportAttribute):Void {
		final state = enterNode(node.AsNode());
		emitImportAttributeName(node.AsNode().Name());
		writePunctuation(":");
		writeSpace();
		final value = node.Value;
		if (emitContext.EmitFlags(node.Value) & EFNoLeadingComments == 0) {
			final commentRange = emitContext.CommentRange(value);
			emitTrailingComments(commentRange.Pos(), commentSeparatorAfter);
		}
		emitExpression(value, OperatorPrecedenceDisallowComma);
		exitNode(node.AsNode(), state);
	}

	function emitImportAttributeNode(node:ImportAttributeNode):Void {
		emitImportAttribute(node.AsImportAttribute());
	}

	function emitNamespaceExportDeclaration(node:NamespaceExportDeclaration):Void {
		final state = enterNode(node.AsNode());
		var pos = emitToken(KindExportKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		pos = emitToken(KindAsKeyword, pos, WriteKindKeyword, node.AsNode());
		writeSpace();
		emitToken(KindNamespaceKeyword, pos, WriteKindKeyword, node.AsNode());
		writeSpace();
		emitBindingIdentifier(node.AsNode().Name().AsIdentifier());
		writeTrailingSemicolon();
		exitNode(node.AsNode(), state);
	}

	function emitNamespaceExport(node:NamespaceExport):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindAsteriskToken, node.Pos(), WriteKindPunctuation, node.AsNode());
		writeSpace();
		emitToken(KindAsKeyword, pos, WriteKindKeyword, node.AsNode());
		writeSpace();
		emitModuleExportName(node.AsNode().Name());
		exitNode(node.AsNode(), state);
	}

	function emitNamedExports(node:NamedExports):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("{");
		emitList(fn_emitExportSpecifierNode, node.AsNode(), node.Elements, LFNamedImportsOrExportsElements);
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitNamedExportBindings(node:NamedExportBindings):Void {
		switch (node.Kind) {
			case KindNamespaceExport:
				emitNamespaceExport(node.AsNamespaceExport());
			case KindNamedExports:
				emitNamedExports(node.AsNamedExports());
			default:
				throw 'unhandled NamedExportBindings: ${node.Kind.String()}';
		}
	}

	function emitExportSpecifier(node:ExportSpecifier):Void {
		final state = enterNode(node.AsNode());
		if (node.IsTypeOnly) {
			writeKeyword("type");
			writeSpace();
		}
		if (node.PropertyName != null) {
			emitModuleExportName(node.PropertyName);
			writeSpace();
			emitToken(KindAsKeyword, node.PropertyName.End(), WriteKindKeyword, node.AsNode());
			writeSpace();
		}
		emitModuleExportName(node.AsNode().Name());
		exitNode(node.AsNode(), state);
	}

	function emitExportSpecifierNode(node:ExportSpecifierNode):Void {
		emitExportSpecifier(node.AsExportSpecifier());
	}

	function emitEmbeddedStatement(parentNode:Node, node:Statement):Void {
		if (Ast.IsBlock(node)
			|| shouldEmitOnSingleLine(parentNode)
			|| Options.PreserveSourceNewlines && getLeadingLineTerminatorCount(parentNode, node, LFNone) == 0) {
			writeSpace();
			emitStatement(node);
		} else {
			writeLine();
			increaseIndent();
			if (node.Kind == KindEmptyStatement) {
				emitEmptyStatement(node.AsEmptyStatement(), true /*isEmbeddedStatement*/);
			} else {
				emitStatement(node);
			}
			decreaseIndent();
		}
	}

	function emitStatement(node:Statement):Void {
		switch (node.Kind) {
			// Statements
			case KindBlock:
				emitBlock(node.AsBlock());
			case KindEmptyStatement:
				emitEmptyStatement(node.AsEmptyStatement(), false /*isEmbeddedStatement*/);
			case KindVariableStatement:
				emitVariableStatement(node.AsVariableStatement());
			case KindExpressionStatement:
				emitExpressionStatement(node.AsExpressionStatement());
			case KindIfStatement:
				emitIfStatement(node.AsIfStatement());
			case KindDoStatement:
				emitDoStatement(node.AsDoStatement());
			case KindWhileStatement:
				emitWhileStatement(node.AsWhileStatement());
			case KindForStatement:
				emitForStatement(node.AsForStatement());
			case KindForInStatement:
				emitForInStatement(node.AsForInOrOfStatement());
			case KindForOfStatement:
				emitForOfStatement(node.AsForInOrOfStatement());
			case KindContinueStatement:
				emitContinueStatement(node.AsContinueStatement());
			case KindBreakStatement:
				emitBreakStatement(node.AsBreakStatement());
			case KindReturnStatement:
				emitReturnStatement(node.AsReturnStatement());
			case KindWithStatement:
				emitWithStatement(node.AsWithStatement());
			case KindSwitchStatement:
				emitSwitchStatement(node.AsSwitchStatement());
			case KindLabeledStatement:
				emitLabeledStatement(node.AsLabeledStatement());
			case KindThrowStatement:
				emitThrowStatement(node.AsThrowStatement());
			case KindTryStatement:
				emitTryStatement(node.AsTryStatement());
			case KindDebuggerStatement:
				emitDebuggerStatement(node.AsDebuggerStatement());
			case KindNotEmittedStatement:
				emitNotEmittedStatement(node.AsNotEmittedStatement());

			// Declaration Statements
			case KindFunctionDeclaration:
				emitFunctionDeclaration(node.AsFunctionDeclaration());
			case KindClassDeclaration:
				emitClassDeclaration(node.AsClassDeclaration());
			case KindInterfaceDeclaration:
				emitInterfaceDeclaration(node.AsInterfaceDeclaration());
			case KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				emitTypeAliasDeclaration(node.AsTypeAliasDeclaration());
			case KindEnumDeclaration:
				emitEnumDeclaration(node.AsEnumDeclaration());
			case KindModuleDeclaration:
				emitModuleDeclaration(node.AsModuleDeclaration());
			case KindMissingDeclaration:

			// Import/Export Statements
			case KindNamespaceExportDeclaration:
				emitNamespaceExportDeclaration(node.AsNamespaceExportDeclaration());
			case KindImportEqualsDeclaration:
				emitImportEqualsDeclaration(node.AsImportEqualsDeclaration());
			case KindImportDeclaration:
				emitImportDeclaration(node.AsImportDeclaration());
			case KindExportAssignment:
				emitExportAssignment(node.AsExportAssignment());
			case KindExportDeclaration:
				emitExportDeclaration(node.AsExportDeclaration());

			default:
				throw 'unhandled statement: ${node.Kind.String()}';
		}
	}

	//
	// Module references
	//

	function emitExternalModuleReference(node:ExternalModuleReference):Void {
		final state = enterNode(node.AsNode());
		writeKeyword("require");
		writePunctuation("(");
		emitExpression(node.Expression, OperatorPrecedenceDisallowComma);
		writePunctuation(")");
		exitNode(node.AsNode(), state);
	}

	//
	// JSX
	//

	function emitJsxElement(node:JsxElement):Void {
		final state = enterNode(node.AsNode());
		emitJsxOpeningElement(node.OpeningElement.AsJsxOpeningElement());
		emitList(fn_emitJsxChild, node.AsNode(), node.Children, LFJsxElementOrFragmentChildren);
		emitJsxClosingElement(node.ClosingElement.AsJsxClosingElement());
		exitNode(node.AsNode(), state);
	}

	function emitJsxSelfClosingElement(node:JsxSelfClosingElement):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("<");
		emitJsxTagName(node.TagName);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		writeSpace();
		emitJsxAttributes(node.Attributes.AsJsxAttributes());
		writePunctuation("/>");
		exitNode(node.AsNode(), state);
	}

	function emitJsxFragment(node:JsxFragment):Void {
		final state = enterNode(node.AsNode());
		emitJsxOpeningFragment(node.OpeningFragment.AsJsxOpeningFragment());
		emitList(fn_emitJsxChild, node.AsNode(), node.Children, LFJsxElementOrFragmentChildren);
		emitJsxClosingFragment(node.ClosingFragment.AsJsxClosingFragment());
		exitNode(node.AsNode(), state);
	}

	function emitJsxOpeningElement(node:JsxOpeningElement):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("<");
		final indented = writeLineSeparatorsAndIndentBefore(node.TagName, node.AsNode());
		emitJsxTagName(node.TagName);
		emitTypeArguments(node.AsNode(), node.TypeArguments);
		if (Core.len(node.Attributes.Properties()) > 0) {
			writeSpace();
		}
		emitJsxAttributes(node.Attributes.AsJsxAttributes());
		writeLineSeparatorsAfter(node.Attributes, node.AsNode());
		decreaseIndentIf(indented);
		writePunctuation(">");
		exitNode(node.AsNode(), state);
	}

	function emitJsxClosingElement(node:JsxClosingElement):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("</");
		emitJsxTagName(node.TagName);
		writePunctuation(">");
		exitNode(node.AsNode(), state);
	}

	function emitJsxOpeningFragment(node:JsxOpeningFragment):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("<");
		writePunctuation(">");
		exitNode(node.AsNode(), state);
	}

	function emitJsxClosingFragment(node:JsxClosingFragment):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("</");
		writePunctuation(">");
		exitNode(node.AsNode(), state);
	}

	function emitJsxText(node:JsxText):Void {
		final state = enterNode(node.AsNode());
		// TODO(rbuckton): Should this be using `getLiteralTextOfNode` instead?
		writeLiteral(node.Text);
		exitNode(node.AsNode(), state);
	}

	function emitJsxAttributes(node:JsxAttributes):Void {
		final state = enterNode(node.AsNode());
		emitList(fn_emitJsxAttributeLike, node.AsNode(), node.Properties, LFJsxElementAttributes);
		exitNode(node.AsNode(), state);
	}

	function emitJsxAttribute(node:JsxAttribute):Void {
		final state = enterNode(node.AsNode());
		emitJsxAttributeName(node.AsNode().Name());
		if (node.Initializer != null) {
			writePunctuation("=");
			emitJsxAttributeValue(node.Initializer);
		}
		exitNode(node.AsNode(), state);
	}

	function emitJsxSpreadAttribute(node:JsxSpreadAttribute):Void {
		final state = enterNode(node.AsNode());
		writePunctuation("{...");
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		writePunctuation("}");
		exitNode(node.AsNode(), state);
	}

	function emitJsxAttributeLike(node:JsxAttributeLike):Void {
		switch (node.Kind) {
			case KindJsxAttribute:
				emitJsxAttribute(node.AsJsxAttribute());
			case KindJsxSpreadAttribute:
				emitJsxSpreadAttribute(node.AsJsxSpreadAttribute());
			default:
				throw 'unhandled JsxAttributeLike: ${node.Kind.String()}';
		}
	}

	function emitJsxExpression(node:JsxExpression):Void {
		final state = enterNode(node.AsNode());
		if (node.Expression != null || !commentsDisabled && !Ast.NodeIsSynthesized(node.AsNode()) && hasCommentsAtPosition(node.Pos())) { // preserve empty expressions if they contain comments!
			final indented = currentSourceFile != null && !Ast.NodeIsSynthesized(node.AsNode()) && GetLinesBetweenPositions(currentSourceFile, node.Pos(),
				node.End()) != 0;
			increaseIndentIf(indented);
			final end = emitToken(KindOpenBraceToken, node.Pos(), WriteKindPunctuation, node.AsNode());
			emitTokenNode(node.DotDotDotToken);
			if (node.Expression != null) {
				emitExpression(node.Expression, OperatorPrecedenceDisallowComma);
			}
			emitToken(KindCloseBraceToken, greatestEnd(end, node.Expression, node.DotDotDotToken), WriteKindPunctuation, node.AsNode());
			decreaseIndentIf(indented);
		}
		exitNode(node.AsNode(), state);
	}

	function emitJsxNamespacedName(node:JsxNamespacedName):Void {
		final state = enterNode(node.AsNode());
		emitIdentifierName(node.Namespace.AsIdentifier());
		writePunctuation(":");
		emitIdentifierName(node.AsNode().Name().AsIdentifier());
		exitNode(node.AsNode(), state);
	}

	function emitJsxChild(node:JsxChild):Void {
		switch (node.Kind) {
			case KindJsxText:
				emitJsxText(node.AsJsxText());
			case KindJsxExpression:
				emitJsxExpression(node.AsJsxExpression());
			case KindJsxElement:
				emitJsxElement(node.AsJsxElement());
			case KindJsxSelfClosingElement:
				emitJsxSelfClosingElement(node.AsJsxSelfClosingElement());
			case KindJsxFragment:
				emitJsxFragment(node.AsJsxFragment());
			default:
				throw 'unhandled JsxChild: ${node.Kind.String()}';
		}
	}

	function emitJsxTagName(node:JsxTagNameExpression):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierReference(node.AsIdentifier());
			case KindThisKeyword:
				emitKeywordExpression(node.AsKeywordExpression());
			case KindJsxNamespacedName:
				emitJsxNamespacedName(node.AsJsxNamespacedName());
			case KindPropertyAccessExpression:
				emitPropertyAccessExpression(node.AsPropertyAccessExpression());
			default:
				throw 'unhandled JsxTagName: ${node.Kind.String()}';
		}
	}

	function emitJsxAttributeName(node:JsxAttributeName):Void {
		switch (node.Kind) {
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());
			case KindJsxNamespacedName:
				emitJsxNamespacedName(node.AsJsxNamespacedName());
			default:
				throw 'unhandled JsxAttributeName: ${node.Kind.String()}';
		}
	}

	function emitJsxAttributeValue(node:JsxAttributeValue):Void {
		switch (node.Kind) {
			case KindStringLiteral:
				emitStringLiteral(node.AsStringLiteral());
			case KindJsxExpression:
				emitJsxExpression(node.AsJsxExpression());
			case KindJsxElement:
				emitJsxElement(node.AsJsxElement());
			case KindJsxSelfClosingElement:
				emitJsxSelfClosingElement(node.AsJsxSelfClosingElement());
			case KindJsxFragment:
				emitJsxFragment(node.AsJsxFragment());
			default:
				emitExpression(node, OperatorPrecedenceLowest);
		}
	}

	//
	// Clauses
	//

	function emitCaseOrDefaultClauseStatements(node:CaseOrDefaultClause, colonPos:Int):Void {
		final emitAsSingleStatement = Core.len(node.Statements.Nodes) == 1 && // treat synthesized nodes as located on the same line for emit purposes
			(currentSourceFile == null
				|| Ast.NodeIsSynthesized(node.AsNode())
				|| Ast.NodeIsSynthesized(node.Statements.Nodes[0])
				|| RangeStartPositionsAreOnSameLine(node.Loc, node.Statements.Nodes[0].Loc, currentSourceFile));

		var format = LFCaseOrDefaultClauseStatements;
		if (emitAsSingleStatement) {
			// When emitting as a single statement, use writeToken (no comments) for the colon
			// to avoid duplicating trailing comments that will be picked up by the statement list.
			writeTokenText(KindColonToken, WriteKindPunctuation, colonPos);
			writeSpace();
			format = format & ~(LFMultiLine | LFIndented);
		} else {
			emitToken(KindColonToken, colonPos, WriteKindPunctuation, node.AsNode());
		}

		emitList(fn_emitStatement, node.AsNode(), node.Statements, format);
	}

	function emitCaseClause(node:CaseOrDefaultClause):Void {
		final state = enterNode(node.AsNode());
		emitToken(KindCaseKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitExpression(node.Expression, OperatorPrecedenceLowest);
		emitCaseOrDefaultClauseStatements(node, node.Expression.End());
		exitNode(node.AsNode(), state);
	}

	function emitDefaultClause(node:CaseOrDefaultClause):Void {
		final state = enterNode(node.AsNode());
		final pos = emitToken(KindDefaultKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		emitCaseOrDefaultClauseStatements(node, pos);
		exitNode(node.AsNode(), state);
	}

	function emitCaseOrDefaultClauseNode(node:CaseOrDefaultClauseNode):Void {
		switch (node.Kind) {
			case KindCaseClause:
				emitCaseClause(node.AsCaseOrDefaultClause());
			case KindDefaultClause:
				emitDefaultClause(node.AsCaseOrDefaultClause());
			default:
				throw 'unhandled CaseOrDefaultClause: ${node.Kind.String()}';
		}
	}

	function emitHeritageClause(node:HeritageClause):Void {
		final state = enterNode(node.AsNode());
		writeSpace();
		emitToken(node.Token, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();
		emitList(fn_emitExpressionWithTypeArgumentsNode, node.AsNode(), node.Types, LFHeritageClauseTypes);
		exitNode(node.AsNode(), state);
	}

	function emitHeritageClauseNode(node:HeritageClauseNode):Void {
		emitHeritageClause(node.AsHeritageClause());
	}

	function emitCatchClause(node:CatchClause):Void {
		final state = enterNode(node.AsNode());
		final openParenPos = emitToken(KindCatchKeyword, node.Pos(), WriteKindKeyword, node.AsNode());
		writeSpace();

		if (node.VariableDeclaration != null) {
			emitToken(KindOpenParenToken, openParenPos, WriteKindPunctuation, node.AsNode());
			emitVariableDeclaration(node.VariableDeclaration.AsVariableDeclaration());
			emitToken(KindCloseParenToken, node.VariableDeclaration.End(), WriteKindPunctuation, node.AsNode());
			writeSpace();
		}

		emitBlock(node.Block.AsBlock());
		exitNode(node.AsNode(), state);
	}

	//
	// Property assignments
	//

	function emitPropertyAssignment(node:PropertyAssignment):Void {
		final state = enterNode(node.AsNode());
		emitPropertyName(node.AsNode().Name());
		writePunctuation(":");
		writeSpace();
		// This is to ensure that we emit comment in the following case:
		//      For example:
		//          obj = {
		//              id: /*comment1*/ ()=>void
		//          }
		// "comment1" is not considered to be leading comment for node.initializer
		// but rather a trailing comment on the previous node.
		final initializer = node.Initializer;
		if (emitContext.EmitFlags(initializer) & EFNoLeadingComments == 0) {
			final commentRange = emitContext.CommentRange(initializer);
			emitTrailingComments(commentRange.Pos(), commentSeparatorAfter);
		}
		emitExpression(initializer, OperatorPrecedenceDisallowComma);
		exitNode(node.AsNode(), state);
	}

	function emitShorthandPropertyAssignment(node:ShorthandPropertyAssignment):Void {
		final state = enterNode(node.AsNode());
		emitPropertyName(node.AsNode().Name());
		if (node.ObjectAssignmentInitializer != null) {
			writeSpace();
			writePunctuation("=");
			writeSpace();
			emitExpression(node.ObjectAssignmentInitializer, OperatorPrecedenceDisallowComma);
		}
		exitNode(node.AsNode(), state);
	}

	function emitSpreadAssignment(node:SpreadAssignment):Void {
		final state = enterNode(node.AsNode());
		if (node.Expression != null) {
			emitToken(KindDotDotDotToken, node.Pos(), WriteKindPunctuation, node.AsNode());
			emitExpression(node.Expression, OperatorPrecedenceDisallowComma);
		}
		exitNode(node.AsNode(), state);
	}

	//
	// Enum
	//

	function emitEnumMember(node:EnumMember):Void {
		final state = enterNode(node.AsNode());
		emitPropertyName(node.AsNode().Name());
		emitInitializer(node.Initializer, node.AsNode().Name().End(), node.AsNode());
		exitNode(node.AsNode(), state);
	}

	function emitEnumMemberNode(node:EnumMemberNode):Void {
		emitEnumMember(node.AsEnumMember());
	}

	//
	// JSDoc
	//

	function emitJSDocNode(node:Node):Void {
		// !!!
		throw "not implemented";
	}

	//
	// Top-level nodes
	//

	function emitShebangIfNeeded(node:SourceFile):Void {
		if (Ast.NodeIsSynthesized(node.AsNode())) {
			return;
		}
		final shebang = Scanner.GetShebang(node.Text());
		if (shebang != "") {
			writeComment(shebang);
			writeLine();
		}
	}

	function emitPrologueDirectives(statements:StatementList):Int {
		final nodes = statements.Nodes;
		if (nodes != null) {
			for (i in 0...nodes.length) {
				final statement = nodes[i];
				if (Ast.IsPrologueDirective(statement)) {
					writeLine();
					emitStatement(statement);
				} else {
					return i;
				}
			}
		}
		return Core.len(nodes);
	}

	function emitHelpers(node:Node):Bool {
		var helpersEmitted = false;
		final sourceFile = currentSourceFile;
		final shouldSkip = Options.NoEmitHelpers || (sourceFile != null && emitContext.HasRecordedExternalHelpers(sourceFile));
		final h = emitContext.GetEmitHelpers(node);
		final helpers = h == null ? null : h.copy();
		if (Core.len(helpers) > 0) {
			Slices.SortStableFunc(helpers, compareEmitHelpers);
			for (helper in helpers) {
				if (!helper.Scoped) {
					// Skip the helper if it can be skipped and the noEmitHelpers compiler
					// option is set, or if it can be imported and the importHelpers compiler
					// option is set.
					if (shouldSkip) {
						continue;
					}
				}
				if (helper.TextCallback != null) {
					writeLines(helper.TextCallback(makeFileLevelOptimisticUniqueName));
				} else {
					writeLines(helper.Text);
				}
				helpersEmitted = true;
			}
		}

		return helpersEmitted;
	}

	function emitSourceFile(node:SourceFile):Void {
		final savedCurrentSourceFile = currentSourceFile;
		final savedCommentsDisabled = commentsDisabled;
		currentSourceFile = node;

		writeLine();

		pushNameGenerationScope(node.AsNode());
		generateAllNames(node.Statements);

		var index = 0;
		var state:CommentState = null;
		if (node.ScriptKind != ScriptKindJSON) {
			emitShebangIfNeeded(node);
			index = emitPrologueDirectives(node.Statements);
			if (!writer.IsAtStartOfLine()) {
				writeLine();
			}
			state = emitDetachedCommentsBeforeStatementList(node.AsNode(), node.Statements.Loc);
			emitHelpers(node.AsNode());
			if (node.IsDeclarationFile) {
				emitTripleSlashDirectives(node);
			}
		} else {
			state = emitDetachedCommentsBeforeStatementList(node.AsNode(), node.Statements.Loc);
		}

		// !!! Emit triple-slash directives
		emitListRange(fn_emitStatement, node.AsNode(), node.Statements, LFMultiLine, index, -1 /*count*/);
		popNameGenerationScope(node.AsNode());
		emitDetachedCommentsAfterStatementList(node.AsNode(), node.Statements.Loc, state);
		currentSourceFile = savedCurrentSourceFile;
		commentsDisabled = savedCommentsDisabled;
	}

	function emitTripleSlashDirectives(node:SourceFile):Void {
		emitDirective("path", node.ReferencedFiles);
		emitDirective("types", node.TypeReferenceDirectives);
		emitDirective("lib", node.LibReferenceDirectives);
	}

	function emitDirective(kind:std.String, refs:Array<FileReference>):Void {
		if (refs == null) {
			return;
		}
		for (ref in refs) {
			var resolutionMode = "";
			if (ref.ResolutionMode != Core.ResolutionModeNone) {
				resolutionMode = 'resolution-mode="${Core.IfElse(ref.ResolutionMode == Core.ResolutionModeESM, "import", "require")}" ';
			}
			writeComment("/// <reference " + kind + "=\"" + ref.FileName + "\" " + resolutionMode + Core.IfElse(ref.Preserve, "preserve=\"true\" ", "") + "/>");
			writeLine();
		}
	}

	//
	// Lists
	//

	function emitList(emit:(p:Printer, node:Node) -> Void, parentNode:Node, children:NodeList, format:ListFormat):Void {
		if (shouldEmitOnMultipleLines(parentNode)) {
			format |= LFPreferNewLine | LFIndented;
		}

		emitListRange(emit, parentNode, children, format, -1 /*start*/, -1 /*count*/);
	}

	function emitListRange(emit:(p:Printer, node:Node) -> Void, parentNode:Node, children:NodeList, format:ListFormat, start:Int, count:Int):Void {
		final isNil = children == null;

		var length = 0;
		if (!isNil) {
			length = Core.len(children.Nodes);
		}

		if (start < 0) {
			start = 0;
		}

		if (count < 0) {
			count = length - start;
		}

		if (isNil && format & LFOptionalIfNil != 0) {
			return;
		}

		final isEmpty = isNil || start >= length || count <= 0;
		if (isEmpty && format & LFOptionalIfEmpty != 0) {
			if (OnBeforeEmitNodeList != null) {
				OnBeforeEmitNodeList(children);
			}
			if (OnAfterEmitNodeList != null) {
				OnAfterEmitNodeList(children);
			}
			return;
		}

		if (format & LFBracketsMask != 0) {
			writePunctuation(getOpeningBracket(format));
			if (isEmpty && !isNil) {
				emitTrailingComments(children.Pos(), commentSeparatorBefore); // Emit comments within empty lists
			}
		}

		if (OnBeforeEmitNodeList != null) {
			OnBeforeEmitNodeList(children);
		}

		if (isEmpty) {
			// Write a line terminator if the parent node was multi-line
			if (format & LFMultiLine != 0
				&& !(Options.PreserveSourceNewlines
					&& (parentNode == null || currentSourceFile != null && RangeIsOnSingleLine(parentNode.Loc, currentSourceFile)))) {
				writeLine();
			} else if (format & LFSpaceBetweenBraces != 0 && format & LFNoSpaceIfEmpty == 0) {
				writeSpace();
			}
		} else {
			final end = start + count < length ? start + count : length;

			// PORT: Go `children.Nodes[start:end]` (no copy); the whole list is passed without a copy.
			final items = start == 0 && end == length ? children.Nodes : children.Nodes.slice(start, end);
			emitListItems(emit, parentNode, items, format, hasTrailingComma(parentNode, children), children.Loc);
		}

		if (OnAfterEmitNodeList != null) {
			OnAfterEmitNodeList(children);
		}

		if (format & LFBracketsMask != 0) {
			if (isEmpty && !isNil) {
				emitLeadingComments(children.End(), false /*elided*/); // Emit comments within empty lists
			}
			writePunctuation(getClosingBracket(format));
		}
	}

	function hasTrailingComma(parentNode:Node, children:NodeList):Bool {
		// NodeList.HasTrailingComma() is unreliable on transformed nodes as some nodes may have been removed. In the event
		// we believe we may need to emit a trailing comma, we must first look to the respective node list on the original
		// node first.
		if (!children.HasTrailingComma()) {
			return false;
		}

		final originalParent = emitContext.MostOriginal(parentNode);
		if (originalParent == parentNode) {
			// if this node is the original node, we can trust the result
			return true;
		}

		if (originalParent.Kind != parentNode.Kind) {
			// if the original node is some other kind of node, we cannot correlate the list
			return false;
		}

		// find the respective node list on the original parent
		var originalList = children;
		switch (originalParent.Kind) {
			case KindObjectLiteralExpression:
				originalList = originalParent.PropertyList();
			case KindArrayLiteralExpression:
				originalList = originalParent.ElementList();
			case KindCallExpression | KindNewExpression:
				if (children == parentNode.TypeArgumentList()) {
					originalList = originalParent.TypeArgumentList();
				} else if (children == parentNode.ArgumentList()) {
					originalList = originalParent.ArgumentList();
				}
			case KindConstructor | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindFunctionDeclaration | KindFunctionExpression |
				KindArrowFunction | KindFunctionType | KindConstructorType | KindCallSignature | KindConstructSignature:
				if (children == parentNode.TypeParameterList()) {
					originalList = originalParent.TypeParameterList();
				} else if (children == parentNode.ParameterList()) {
					originalList = originalParent.ParameterList();
				}
			case KindClassDeclaration | KindClassExpression | KindInterfaceDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				if (children == parentNode.TypeParameterList()) {
					originalList = originalParent.TypeParameterList();
				}
			case KindObjectBindingPattern | KindArrayBindingPattern:
				if (children == parentNode.ElementList()) {
					originalList = originalParent.ElementList();
				}
			case KindNamedImports | KindNamedExports:
				originalList = originalParent.ElementList();
			case KindImportAttributes:
				originalList = originalParent.AsImportAttributes().Attributes;
			default:
		}

		// if we have the original list, we can use it's result.
		if (originalList != null) {
			return originalList.HasTrailingComma();
		}

		return false;
	}

	function writeDelimiter(format:ListFormat):Void {
		switch (format & LFDelimitersMask) {
			case LFNone:
			case LFCommaDelimited:
				writePunctuation(",");
			case LFBarDelimited:
				writeSpace();
				writePunctuation("|");
			case LFAsteriskDelimited:
				writeSpace();
				writePunctuation("*");
				writeSpace();
			case LFAmpersandDelimited:
				writeSpace();
				writePunctuation("&");
			default:
		}
	}

	// Emits a list without brackets or raising events.
	//
	// NOTE: You probably don't want to call this directly and should be using `emitList` instead.
	function emitListItems(emit:(p:Printer, node:Node) -> Void, parentNode:Node, children:Array<Node>, format:ListFormat, hasTrailingComma:Bool,
			childrenTextRange:TextRange):Void {
		// Write the opening line terminator or leading whitespace.
		final mayEmitInterveningComments = format & LFNoInterveningComments == 0;
		var shouldEmitInterveningComments = mayEmitInterveningComments;

		var leadingLineTerminatorCount = 0;
		if (Core.len(children) > 0) {
			leadingLineTerminatorCount = getLeadingLineTerminatorCount(parentNode, children[0], format);
		}
		if (leadingLineTerminatorCount > 0) {
			for (_ in 0...leadingLineTerminatorCount) {
				writeLine();
			}
			shouldEmitInterveningComments = false;
		} else if (format & LFSpaceBetweenBraces != 0) {
			writeSpace();
		}

		// Increase the indent, if requested.
		if (format & LFIndented != 0) {
			increaseIndent();
		}

		final parentEnd = greatestEnd(-1, parentNode);

		// Emit each child.
		var previousSibling:Node = null;
		var shouldDecreaseIndentAfterEmit = false;
		if (children != null) {
			for (child in children) {
				// Write the delimiter if this is not the first node.
				if (format & LFAsteriskDelimited != 0) {
					// always write JSDoc in the format "\n *"
					writeLine();
					writeDelimiter(format);
				} else if (previousSibling != null) {
					// i.e
					//      function commentedParameters(
					//          /* Parameter a */
					//          a
					//          /* End of parameter a */ -> this comment isn't considered to be trailing comment of parameter "a" due to newline
					//          ,
					if (format & LFDelimitersMask != 0 && previousSibling.End() != parentEnd) {
						if (!commentsDisabled && shouldEmitTrailingComments(previousSibling)) {
							emitLeadingComments(previousSibling.End(), false /*elided*/);
						}
					}

					writeDelimiter(format);

					// Write either a line terminator or whitespace to separate the elements.
					final separatingLineTerminatorCount = getSeparatingLineTerminatorCount(previousSibling, child, format);
					if (separatingLineTerminatorCount > 0) {
						// If a synthesized node in a single-line list starts on a new
						// line, we should increase the indent.
						if (format & (LFLinesMask | LFIndented) == LFSingleLine) {
							increaseIndent();
							shouldDecreaseIndentAfterEmit = true;
						}

						if (shouldEmitInterveningComments
							&& format & LFDelimitersMask != 0
							&& !Ast.PositionIsSynthesized(child.Pos())
							&& shouldEmitLeadingComments(child)) {
							final commentRange = emitContext.CommentRange(child);
							emitTrailingCommentsOfPosition(commentRange.Pos(), format & LFSpaceBetweenSiblings != 0, true /*forceNoNewline*/);
						}

						for (_ in 0...separatingLineTerminatorCount) {
							writeLine();
						}

						shouldEmitInterveningComments = false;
					} else if (format & LFSpaceBetweenSiblings != 0) {
						writeSpace();
					}
				}

				// Emit this child.
				if (shouldEmitInterveningComments && shouldEmitLeadingComments(child)) {
					final commentRange = emitContext.CommentRange(child);
					emitTrailingCommentsOfPosition(commentRange.Pos(), false /*prefixSpace*/, false /*forceNoNewline*/);
				} else {
					shouldEmitInterveningComments = mayEmitInterveningComments;
				}

				nextListElementPos = child.Pos();
				emit(this, child);

				if (shouldDecreaseIndentAfterEmit) {
					decreaseIndent();
					shouldDecreaseIndentAfterEmit = false;
				}

				previousSibling = child;
			}
		}

		// Write a trailing comma, if requested.
		final skipTrailingComments = commentsDisabled || !shouldEmitTrailingComments(previousSibling);
		final emitTrailingComma = hasTrailingComma && format & LFAllowTrailingComma != 0 && format & LFCommaDelimited != 0;
		if (emitTrailingComma) {
			if (previousSibling != null && !skipTrailingComments) {
				emitToken(KindCommaToken, previousSibling.End(), WriteKindPunctuation, previousSibling);
			} else {
				writePunctuation(",");
			}
		}

		// Emit any trailing comment of the last element in the list
		// i.e
		//       var array = [...
		//          2
		//          /* end of element 2 */
		//       ];
		if (previousSibling != null && parentEnd != previousSibling.End() && format & LFDelimitersMask != 0 && !skipTrailingComments) {
			var commentsPos:Int;
			if (emitTrailingComma && childrenTextRange.End() > 0) {
				commentsPos = childrenTextRange.End();
			} else {
				commentsPos = previousSibling.End();
			}
			emitLeadingComments(commentsPos, false /*elided*/);
		}

		// Decrease the indent, if requested.
		if (format & LFIndented != 0) {
			decreaseIndent();
		}

		// Write the closing line terminator or closing whitespace.
		final closingLineTerminatorCount = getClosingLineTerminatorCount(parentNode, Core.LastOrNil(children), format, childrenTextRange);
		if (closingLineTerminatorCount > 0) {
			for (_ in 0...closingLineTerminatorCount) {
				writeLine();
			}
		} else if (format & (LFSpaceAfterList | LFSpaceBetweenBraces) != 0) {
			writeSpace();
		}
	}

	//
	// General
	//

	public function Emit(node:Node, sourceFile:SourceFile):std.String {
		// ensure a reusable writer
		if (ownWriter == null) {
			ownWriter = NewTextWriter(Options.NewLine.GetNewLineCharacter(), 0);
		}

		Write(node, sourceFile, ownWriter, null /*sourceMapGenerator*/);
		final text = ownWriter.String();

		ownWriter.Clear();
		return text;
	}

	public function EmitSourceFile(sourceFile:SourceFile):std.String {
		return Emit(sourceFile.AsNode(), sourceFile);
	}

	function setSourceFile(sourceFile:SourceFile):Void {
		currentSourceFile = sourceFile;
		uniqueHelperNames = null;
		externalHelpersModuleName = null;
		if (sourceFile != null) {
			if (emitContext.EmitFlags(emitContext.MostOriginal(sourceFile.AsNode())) & EFExternalHelpers != 0) {
				uniqueHelperNames = new StringMap<IdentifierNode>();
			}
			externalHelpersModuleName = emitContext.GetExternalHelpersModuleName(sourceFile);
			setSourceMapSource(sourceFileSource(sourceFile));
		}

		// !!!
	}

	// PORT: the cached sourcemap.Source adapter of a SourceFile (see the field sourceFileSources).
	function sourceFileSource(sourceFile:SourceFile):Source {
		if (sourceFileSources == null) {
			sourceFileSources = new IdentityMap<SourceFile, SourceFileSource>();
		}
		var s = sourceFileSources.get(sourceFile);
		if (s == null) {
			s = new SourceFileSource(sourceFile);
			sourceFileSources.set(sourceFile, s);
		}
		return s;
	}

	public function Write(node:Node, sourceFile:SourceFile, writer:EmitTextWriter, sourceMapGenerator:Generator):Void {
		final savedCurrentSourceFile = currentSourceFile;
		final savedWriter = this.writer;
		final savedUniqueHelperNames = uniqueHelperNames;
		final savedSourceMapsDisabled = sourceMapsDisabled;
		final savedSourceMapGenerator = this.sourceMapGenerator;
		final savedSourceMapSource = sourceMapSource;
		final savedSourceMapSourceIndex = sourceMapSourceIndex;
		final savedSourceMapLineCharCache = sourceMapLineCharCache;

		sourceMapsDisabled = sourceMapGenerator == null;
		this.sourceMapGenerator = sourceMapGenerator;
		sourceMapSource = null;
		sourceMapSourceIndex = -1;
		sourceMapLineCharCache = null;

		setSourceFile(sourceFile);
		this.writer = writer;
		this.writer.Clear();
		if (sourceFile != null) {
			if (Std.isOfType(this.writer, Grower)) {
				final grower:Grower = cast this.writer;
				grower.Grow(sourceFile.Text().length);
			}
		}

		switch (node.Kind) {
			// Pseudo-literals
			case KindTemplateHead:
				emitTemplateHead(node.AsTemplateHead());
			case KindTemplateMiddle:
				emitTemplateMiddle(node.AsTemplateMiddle());
			case KindTemplateTail:
				emitTemplateTail(node.AsTemplateTail());

			// Identifiers
			case KindIdentifier:
				emitIdentifierName(node.AsIdentifier());

			// PrivateIdentifiers
			case KindPrivateIdentifier:
				emitPrivateIdentifier(node.AsPrivateIdentifier());

			// Parse tree nodes
			// Names
			case KindQualifiedName:
				emitQualifiedName(node.AsQualifiedName());
			case KindComputedPropertyName:
				emitComputedPropertyName(node.AsComputedPropertyName());

			// Signature elements
			case KindTypeParameter:
				emitTypeParameter(node.AsTypeParameterDeclaration());
			case KindParameter:
				emitParameter(node.AsParameterDeclaration());
			case KindDecorator:
				emitDecorator(node.AsDecorator());

			// Type members
			case KindPropertySignature:
				emitPropertySignature(node.AsPropertySignatureDeclaration());
			case KindPropertyDeclaration:
				emitPropertyDeclaration(node.AsPropertyDeclaration());
			case KindMethodSignature:
				emitMethodSignature(node.AsMethodSignatureDeclaration());
			case KindMethodDeclaration:
				emitMethodDeclaration(node.AsMethodDeclaration());
			case KindClassStaticBlockDeclaration:
				emitClassStaticBlockDeclaration(node.AsClassStaticBlockDeclaration());
			case KindConstructor:
				emitConstructor(node.AsConstructorDeclaration());
			case KindGetAccessor:
				emitGetAccessorDeclaration(node.AsGetAccessorDeclaration());
			case KindSetAccessor:
				emitSetAccessorDeclaration(node.AsSetAccessorDeclaration());
			case KindCallSignature:
				emitCallSignature(node.AsCallSignatureDeclaration());
			case KindConstructSignature:
				emitConstructSignature(node.AsConstructSignatureDeclaration());
			case KindIndexSignature:
				emitIndexSignature(node.AsIndexSignatureDeclaration());

			// Binding patterns
			case KindObjectBindingPattern:
				emitObjectBindingPattern(node.AsBindingPattern());
			case KindArrayBindingPattern:
				emitArrayBindingPattern(node.AsBindingPattern());
			case KindBindingElement:
				emitBindingElement(node.AsBindingElement());

			// Misc
			case KindTemplateSpan:
				emitTemplateSpan(node.AsTemplateSpan());
			case KindSemicolonClassElement:
				emitSemicolonClassElement(node.AsSemicolonClassElement());

			// Declarations (non-statement)
			case KindVariableDeclaration:
				emitVariableDeclaration(node.AsVariableDeclaration());
			case KindVariableDeclarationList:
				emitVariableDeclarationList(node.AsVariableDeclarationList());
			case KindModuleBlock:
				emitModuleBlock(node.AsModuleBlock());
			case KindCaseBlock:
				emitCaseBlock(node.AsCaseBlock());
			case KindImportClause:
				emitImportClause(node.AsImportClause());
			case KindNamespaceImport:
				emitNamespaceImport(node.AsNamespaceImport());
			case KindNamespaceExport:
				emitNamespaceExport(node.AsNamespaceExport());
			case KindNamedImports:
				emitNamedImports(node.AsNamedImports());
			case KindImportSpecifier:
				emitImportSpecifier(node.AsImportSpecifier());
			case KindNamedExports:
				emitNamedExports(node.AsNamedExports());
			case KindExportSpecifier:
				emitExportSpecifier(node.AsExportSpecifier());
			case KindImportAttributes:
				emitImportAttributes(node.AsImportAttributes());
			case KindImportAttribute:
				emitImportAttribute(node.AsImportAttribute());

			// Module references
			case KindExternalModuleReference:
				emitExternalModuleReference(node.AsExternalModuleReference());

			// JSX (non-expression)
			case KindJsxText:
				emitJsxText(node.AsJsxText());
			case KindJsxOpeningElement:
				emitJsxOpeningElement(node.AsJsxOpeningElement());
			case KindJsxOpeningFragment:
				emitJsxOpeningFragment(node.AsJsxOpeningFragment());
			case KindJsxClosingElement:
				emitJsxClosingElement(node.AsJsxClosingElement());
			case KindJsxClosingFragment:
				emitJsxClosingFragment(node.AsJsxClosingFragment());
			case KindJsxAttribute:
				emitJsxAttribute(node.AsJsxAttribute());
			case KindJsxAttributes:
				emitJsxAttributes(node.AsJsxAttributes());
			case KindJsxSpreadAttribute:
				emitJsxSpreadAttribute(node.AsJsxSpreadAttribute());
			case KindJsxExpression:
				emitJsxExpression(node.AsJsxExpression());
			case KindJsxNamespacedName:
				emitJsxNamespacedName(node.AsJsxNamespacedName());

			// Clauses
			case KindCaseClause:
				emitCaseClause(node.AsCaseOrDefaultClause());
			case KindDefaultClause:
				emitDefaultClause(node.AsCaseOrDefaultClause());
			case KindHeritageClause:
				emitHeritageClause(node.AsHeritageClause());
			case KindCatchClause:
				emitCatchClause(node.AsCatchClause());

			// Property assignments
			case KindPropertyAssignment:
				emitPropertyAssignment(node.AsPropertyAssignment());
			case KindShorthandPropertyAssignment:
				emitShorthandPropertyAssignment(node.AsShorthandPropertyAssignment());
			case KindSpreadAssignment:
				emitSpreadAssignment(node.AsSpreadAssignment());

			// Enum
			case KindEnumMember:
				emitEnumMember(node.AsEnumMember());

			// Top-level nodes
			case KindSourceFile:
				emitSourceFile(node.AsSourceFile());

			// Transformation nodes
			case KindNotEmittedTypeElement:
				emitNotEmittedTypeElement(node.AsNotEmittedTypeElement());

			default:
				if (Ast.IsTypeNode(node)) {
					emitTypeNodeOutsideExtends(node);
				} else if (Ast.IsStatement(node)) {
					emitStatement(node);
				} else if (Ast.IsExpression(node)) {
					emitExpression(node, OperatorPrecedenceLowest);
				} else if (Ast.IsKeywordKind(node.Kind)) {
					emitKeywordNode(node);
				} else if (Ast.IsPunctuationKind(node.Kind)) {
					emitPunctuationNode(node);
				} else if (Ast.IsJSDocKind(node.Kind)) {
					emitJSDocNode(node);
				} else {
					throw 'unhandled Node: ${node.Kind.String()}';
				}
		}

		currentSourceFile = savedCurrentSourceFile;
		this.writer = savedWriter;
		uniqueHelperNames = savedUniqueHelperNames;
		sourceMapsDisabled = savedSourceMapsDisabled;
		this.sourceMapGenerator = savedSourceMapGenerator;
		sourceMapSource = savedSourceMapSource;
		sourceMapSourceIndex = savedSourceMapSourceIndex;
		sourceMapLineCharCache = savedSourceMapLineCharCache;
	}

	//
	// Comments
	//

	function emitCommentsBeforeNode(node:Node):CommentState {
		if (!shouldEmitComments(node)) {
			return null;
		}

		final emitFlags = emitContext.EmitFlags(node);
		final commentRange = emitContext.CommentRange(node);
		final containerPos = this.containerPos;
		final containerEnd = this.containerEnd;
		final declarationListContainerEnd = this.declarationListContainerEnd;

		// Emit leading comments
		emitLeadingCommentsOfNode(node, emitFlags, commentRange);
		emitLeadingSyntheticCommentsOfNode(node, emitFlags);
		if (emitFlags & EFNoNestedComments != 0) {
			commentsDisabled = true;
		}

		return new CommentState(emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd);
	}

	function emitCommentsAfterNode(node:Node, state:CommentState):Void {
		if (state == null) {
			return;
		}

		final emitFlags = state.emitFlags;
		final commentRange = state.commentRange;
		final containerPos = state.containerPos;
		final containerEnd = state.containerEnd;
		final declarationListContainerEnd = state.declarationListContainerEnd;

		// Emit trailing comments
		if (emitFlags & EFNoNestedComments != 0) {
			commentsDisabled = false;
		}

		emitTrailingSyntheticCommentsOfNode(node, emitFlags);
		emitTrailingCommentsOfNode(node, emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd);

		// Preserve comments from erased type annotation
		final typeNode = emitContext.GetTypeNode(node);
		if (typeNode != null) {
			emitTrailingCommentsOfNode(node, emitFlags, typeNode.Loc, containerPos, containerEnd, declarationListContainerEnd);
		}
	}

	// PORT: Go returns (*commentState, int) → returns the state, the position in outPos.
	function emitCommentsBeforeToken(token:Kind, pos:Int, contextNode:Node, flags:TokenEmitFlags):CommentState {
		if (flags & tefNoComments != 0 || commentsDisabled) {
			// Still skip trivia so that the returned pos correctly identifies the token position.
			// This is needed for trailing source map positions (writeTokenText advances pos by token length).
			if (currentSourceFile != null && !Ast.PositionIsSynthesized(pos)) {
				pos = Scanner.SkipTrivia(currentSourceFile.Text(), pos);
			}
			outPos = pos;
			return null;
		}

		final startPos = pos;
		if (currentSourceFile != null) {
			pos = Scanner.SkipTrivia(currentSourceFile.Text(), startPos);
		}

		final node = emitContext.ParseNode(contextNode);
		final isSimilarNode = node != null && node.Kind == contextNode.Kind;
		if (!isSimilarNode) {
			outPos = pos;
			return null;
		}

		if (contextNode.Pos() != startPos) {
			final indentLeading = flags & tefIndentLeadingComments != 0;
			final needsIndent = indentLeading && currentSourceFile != null && !PositionsAreOnSameLine(startPos, pos, currentSourceFile);
			increaseIndentIf(needsIndent);
			emitLeadingComments(startPos, false /*elided*/);
			decreaseIndentIf(needsIndent);
		}

		outPos = pos;
		return new CommentState(EFNone, new TextRange(0, 0), 0, 0, 0);
	}

	function emitCommentsAfterToken(token:Kind, pos:Int, contextNode:Node, state:CommentState):Void {
		if (state == null) {
			return;
		}

		if (contextNode.End() != pos) {
			final isJsxExprContext = contextNode.Kind == KindJsxExpression;
			emitTrailingComments(pos, Core.IfElse(isJsxExprContext, commentSeparatorNone, commentSeparatorBefore));
		}
	}

	function emitDetachedCommentsBeforeStatementList(node:Node, detachedRange:TextRange):CommentState {
		if (!shouldEmitDetachedComments(node)) {
			return null;
		}

		final emitFlags = emitContext.EmitFlags(node);
		final containerPos = this.containerPos;
		final containerEnd = this.containerEnd;
		final declarationListContainerEnd = this.declarationListContainerEnd;
		final skipLeadingComments = Ast.PositionIsSynthesized(detachedRange.Pos()) || emitFlags & EFNoLeadingComments != 0;

		if (!skipLeadingComments) {
			emitDetachedCommentsAndUpdateCommentsInfo(detachedRange);
		}

		if (emitFlags & EFNoNestedComments != 0) {
			commentsDisabled = true;
		}

		return new CommentState(emitFlags, detachedRange, containerPos, containerEnd, declarationListContainerEnd);
	}

	function emitDetachedCommentsAfterStatementList(node:Node, detachedRange:TextRange, state:CommentState):Void {
		if (state == null) {
			return;
		}

		final emitFlags = state.emitFlags;
		final skipTrailingComments = commentsDisabled || Ast.PositionIsSynthesized(detachedRange.End()) || emitFlags & EFNoTrailingComments != 0;

		if (!skipTrailingComments) {
			final hasWrittenComment = emitLeadingComments(detachedRange.End(), false /*elided*/);
			if (hasWrittenComment && !writer.IsAtStartOfLine()) {
				writeLine();
			}
		}
	}

	function emitLeadingCommentsOfNode(node:Node, emitFlags:EmitFlags, commentRange:TextRange):Void {
		final pos = commentRange.Pos();
		final end = commentRange.End();

		// Save current container state on the stack.
		if ((!Ast.PositionIsSynthesized(pos) || !Ast.PositionIsSynthesized(end)) && pos != end) {
			// We have to explicitly check that the node is JsxText because if the compilerOptions.jsx is "preserve" we will not do any transformation.
			// It is expensive to walk entire tree just to set one kind of node to have no comments.
			final skipLeadingComments = Ast.PositionIsSynthesized(pos) || emitFlags & EFNoLeadingComments != 0 || node.Kind == KindJsxText;
			final skipTrailingComments = Ast.PositionIsSynthesized(end) || emitFlags & EFNoTrailingComments != 0 || node.Kind == KindJsxText;

			// Emit leading comments if the position is not synthesized and the node
			// has not opted out from emitting leading comments.
			if (!skipLeadingComments) {
				emitLeadingComments(pos, node.Kind == KindNotEmittedStatement /*elided*/);
			}

			if (!skipLeadingComments || (pos >= 0 && (emitFlags & EFNoLeadingComments) != 0)) {
				// Advance the container position if comments get emitted or if they've been disabled explicitly using NoLeadingComments.
				containerPos = pos;
			}

			if (!skipTrailingComments || (end >= 0 && (emitFlags & EFNoTrailingComments) != 0)) {
				// Advance the container end if comments get emitted or if they've been disabled explicitly using NoTrailingComments.
				containerEnd = end;

				// To avoid invalid comment emit in a down-level binding pattern, we
				// keep track of the last declaration list container's end
				if (node.Kind == KindVariableDeclarationList) {
					declarationListContainerEnd = end;
				}
			}
		}
	}

	function emitTrailingCommentsOfNode(node:Node, emitFlags:EmitFlags, commentRange:TextRange, containerPos:Int, containerEnd:Int,
			declarationListContainerEnd:Int):Void {
		final pos = commentRange.Pos();
		final end = commentRange.End();
		final skipTrailingComments = end < 0 || (emitFlags & EFNoTrailingComments) != 0 || node.Kind == KindJsxText;
		if ((!Ast.PositionIsSynthesized(pos) || !Ast.PositionIsSynthesized(end)) && pos != end) {
			// Restore previous container state.
			this.containerPos = containerPos;
			this.containerEnd = containerEnd;
			this.declarationListContainerEnd = declarationListContainerEnd;

			// Emit trailing comments if the position is not synthesized and the node
			// has not opted out from emitting leading comments and is an emitted node.
			if (!skipTrailingComments && node.Kind != KindNotEmittedStatement) {
				emitTrailingComments(end, commentSeparatorBefore);
			}
		}
	}

	function emitLeadingSyntheticCommentsOfNode(node:Node, emitFlags:EmitFlags):Void {
		if (emitFlags & EFNoLeadingComments != 0) {
			return;
		}
		final synth = emitContext.GetSyntheticLeadingComments(node);
		if (synth != null) {
			for (c in synth) {
				emitLeadingSynthesizedComment(c);
			}
		}
	}

	function emitLeadingSynthesizedComment(comment:SynthesizedComment):Void {
		if (comment.HasLeadingNewLine || comment.Kind == KindSingleLineCommentTrivia) {
			writer.WriteLine();
		}
		writeSynthesizedComment(comment);
		if (comment.HasTrailingNewLine || comment.Kind == KindSingleLineCommentTrivia) {
			writer.WriteLine();
		} else {
			writer.WriteSpace(" ");
		}
	}

	function emitTrailingSyntheticCommentsOfNode(node:Node, emitFlags:EmitFlags):Void {
		if (emitFlags & EFNoTrailingComments != 0) {
			return;
		}
		final synth = emitContext.GetSyntheticTrailingComments(node);
		if (synth != null) {
			for (c in synth) {
				emitTrailingSynthesizedComment(c);
			}
		}
	}

	function emitTrailingSynthesizedComment(comment:SynthesizedComment):Void {
		if (!writer.IsAtStartOfLine()) {
			writer.WriteSpace(" ");
		}
		writeSynthesizedComment(comment);
		if (comment.HasTrailingNewLine) {
			writer.WriteLine();
		}
	}

	function writeSynthesizedComment(comment:SynthesizedComment):Void {
		final text = formatSynthesizedComment(comment);
		var lineMap:Array<TextPos> = null;
		if (comment.Kind == KindMultiLineCommentTrivia) {
			lineMap = Core.ComputeECMALineStarts(text);
		}
		writeCommentRangeWorker(text, lineMap, comment.Kind, Core.NewTextRange(0, text.length));
	}

	function emitLeadingComments(pos:Int, elided:Bool):Bool {
		// Emit the leading comments only if the container's pos doesn't match because the container should take care of emitting these comments
		if (commentsDisabled || currentSourceFile == null || Ast.PositionIsSynthesized(pos) || pos == containerPos) {
			return false;
		}

		var tripleSlash = TSUnknown;
		if (!elided) {
			if (pos == 0 && currentSourceFile != null && currentSourceFile.IsDeclarationFile) {
				tripleSlash = TSFalse;
			}
		} else if (pos == 0) {
			// If the node will not be emitted in JS, remove all the comments(normal, pinned and ///) associated with the node,
			// unless it is a triple slash comment at the top of the file.
			// For Example:
			//      /// <reference-path ...>
			//      declare var x;
			//      /// <reference-path ...>
			//      interface F {}
			//  The first /// will NOT be removed while the second one will be removed even though both node will not be emitted
			tripleSlash = TSTrue;
		} else {
			return false;
		}

		// skip detached comments
		if (detachedCommentsInfo.Len() > 0) {
			final info = detachedCommentsInfo.Peek();
			if (info.nodePos == pos) {
				pos = detachedCommentsInfo.Pop().detachedCommentEndPos;
			}
		}

		var comments:Array<CommentRange> = null;
		for (comment in Scanner.GetLeadingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pos)) {
			if (shouldWriteComment(comment) && shouldEmitCommentIfTripleSlash(comment, tripleSlash)) {
				if (comments == null) {
					comments = [];
				}
				comments.push(comment);
			}
		}

		if (Core.len(comments) > 0 && shouldEmitNewLineBeforeLeadingCommentOfPosition(pos, comments[0].Pos())) {
			writeLine();
		}

		// Leading comments are emitted as /*leading comment1*/space/*leading comment*/space
		return emitComments(comments, commentSeparatorAfter);
	}

	function shouldEmitCommentIfTripleSlash(comment:CommentRange, tripleSlash:Tristate):Bool {
		switch (tripleSlash) {
			case TSTrue:
				return isTripleSlashComment(comment);
			case TSFalse:
				return !isTripleSlashComment(comment);
			default:
				return true;
		}
	}

	function shouldEmitNewLineBeforeLeadingCommentOfPosition(pos:Int, commentPos:Int):Bool {
		// If the leading comments start on different line than the start of node, write new line
		return currentSourceFile != null
			&& pos != commentPos
			&& Scanner.ComputeLineOfPosition(currentSourceFile.ECMALineMap(), pos) != Scanner.ComputeLineOfPosition(currentSourceFile.ECMALineMap(),
				commentPos);
	}

	function emitLeadingCommentsOfPosition(pos:Int):Void {
		if (commentsDisabled || pos == -1) {
			return;
		}

		emitLeadingComments(pos, false /*elided*/);
	}

	function emitTrailingComments(pos:Int, commentSeparator:CommentSeparator):Void {
		if (commentsDisabled) {
			return;
		}
		// Emit the trailing comments only if the container's end doesn't match because the container should take care of emitting these comments
		if (commentsDisabled || currentSourceFile == null || containerEnd != -1 && (pos == containerEnd || pos == declarationListContainerEnd)) {
			return;
		}

		var comments:Array<CommentRange> = null;
		for (comment in Scanner.GetTrailingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pos)) {
			if (shouldWriteComment(comment)) {
				if (comments == null) {
					comments = [];
				}
				comments.push(comment);
			}
		}

		// trailing comments are normally emitted as space/*trailing comment1*/space/*trailing comment2*/
		emitComments(comments, commentSeparator);
	}

	function emitTrailingCommentsOfPosition(pos:Int, prefixSpace:Bool, forceNoNewline:Bool):Void {
		if (commentsDisabled || currentSourceFile == null) {
			return;
		}
		if (containerEnd != -1 && (pos == containerEnd || pos == declarationListContainerEnd)) {
			return;
		}

		var comments:Array<CommentRange> = null;
		for (comment in Scanner.GetTrailingCommentRanges(emitContext.Factory.AsNodeFactory(), currentSourceFile.Text(), pos)) {
			if (comments == null) {
				comments = [];
			}
			comments.push(comment);
		}
		if (Core.len(comments) == 0) {
			return;
		}

		for (comment in comments) {
			if (prefixSpace) {
				if (!shouldWriteComment(comment)) {
					continue;
				}
				if (!writer.IsAtStartOfLine()) {
					writeSpace();
				}
				emitComment(comment);
				if (comment.HasTrailingNewLine) {
					writeLine();
				}
				continue;
			}

			emitComment(comment);
			if (forceNoNewline) {
				if (comment.Kind == KindSingleLineCommentTrivia) {
					writeLine();
				}
			} else if (comment.HasTrailingNewLine) {
				writeLine();
			} else {
				writeSpace();
			}
		}
	}

	function emitDetachedCommentsAndUpdateCommentsInfo(textRange:TextRange):Void {
		if (currentSourceFile == null) {
			return;
		}
		final currentDetachedCommentInfo = emitDetachedComments(textRange);
		if (currentDetachedCommentInfo != null) {
			detachedCommentsInfo.Push(currentDetachedCommentInfo);
		}
	}

	// PORT: Go returns (result detachedCommentsInfo, hasResult bool) → the result or null.
	function emitDetachedComments(textRange:TextRange):DetachedCommentsInfo {
		if (currentSourceFile == null) {
			return null;
		}

		final text = currentSourceFile.Text();
		final lineMap = currentSourceFile.ECMALineMap();

		var leadingComments:Array<CommentRange> = null;
		if (commentsDisabled) {
			// removeComments is true, only reserve pinned comment at the top of file
			// For example:
			//      /*! Pinned Comment */
			//
			//      var x = 10;
			if (textRange.Pos() == 0) {
				for (comment in Scanner.GetLeadingCommentRanges(emitContext.Factory.AsNodeFactory(), text, textRange.Pos())) {
					if (IsPinnedComment(text, comment)) {
						if (leadingComments == null) {
							leadingComments = [];
						}
						leadingComments.push(comment);
					}
				}
			}
		} else {
			// removeComments is false, just get detached as normal and bypass the process to filter comment
			for (comment in Scanner.GetLeadingCommentRanges(emitContext.Factory.AsNodeFactory(), text, textRange.Pos())) {
				if (leadingComments == null) {
					leadingComments = [];
				}
				leadingComments.push(comment);
			}
		}

		var result:DetachedCommentsInfo = null;
		if (Core.len(leadingComments) > 0) {
			var detachedComments:Array<CommentRange> = null;
			var lastComment:CommentRange = null;
			for (i in 0...leadingComments.length) {
				final comment = leadingComments[i];
				if (i > 0) {
					final lastCommentLine = Scanner.ComputeLineOfPosition(lineMap, lastComment.End());
					final commentLine = Scanner.ComputeLineOfPosition(lineMap, comment.Pos());

					if (commentLine >= lastCommentLine + 2) {
						// There was a blank line between the last comment and this comment.  This
						// comment is not part of the copyright comments.  Return what we have so
						// far.
						break;
					}
				}

				if (detachedComments == null) {
					detachedComments = [];
				}
				detachedComments.push(comment);
				lastComment = comment;
			}

			if (Core.len(detachedComments) > 0) {
				// All comments look like they could have been part of the copyright header.  Make
				// sure there is at least one blank line between it and the node.  If not, it's not
				// a copyright header.
				final lastCommentLine = Scanner.ComputeLineOfPosition(lineMap, Core.LastOrNil(detachedComments).End());
				final nodeLine = Scanner.ComputeLineOfPosition(lineMap, Scanner.SkipTrivia(text, textRange.Pos()));
				if (nodeLine >= lastCommentLine + 2) {
					// Valid detachedComments

					// Filter to only comments that should be written (e.g., JSDoc-style in declaration emit)
					var commentsToEmit:Array<CommentRange> = null;
					for (comment in detachedComments) {
						if (shouldWriteComment(comment)) {
							if (commentsToEmit == null) {
								commentsToEmit = [];
							}
							commentsToEmit.push(comment);
						}
					}

					if (Core.len(commentsToEmit) > 0) {
						if (shouldEmitNewLineBeforeLeadingCommentOfPosition(textRange.Pos(), commentsToEmit[0].Pos())) {
							writeLine();
						}

						emitComments(commentsToEmit, commentSeparatorAfter);
					}
					result = new DetachedCommentsInfo(textRange.Pos(), Core.LastOrNil(detachedComments).End());
				}
			}
		}
		return result;
	}

	function emitComments(comments:Array<CommentRange>, commentSeparator:CommentSeparator):Bool {
		var interveningSeparator = false;
		if (Core.len(comments) == 0) {
			return false;
		}

		if (commentSeparator == commentSeparatorBefore) {
			writeSpace();
		}

		for (comment in comments) {
			if (interveningSeparator) {
				writeSpace();
				interveningSeparator = false;
			}

			emitComment(comment);

			if (comment.Kind == KindSingleLineCommentTrivia || comment.HasTrailingNewLine && commentSeparator != commentSeparatorNone) {
				writeLine();
			} else {
				interveningSeparator = commentSeparator != commentSeparatorNone;
			}
		}

		if (interveningSeparator && commentSeparator == commentSeparatorAfter) {
			writeSpace();
		}

		return true;
	}

	function emitComment(comment:CommentRange):Void {
		emitPos(comment.Pos());
		writeCommentRange(comment);
		emitPos(comment.End());
	}

	function isTripleSlashComment(comment:CommentRange):Bool {
		return currentSourceFile != null && IsRecognizedTripleSlashComment(currentSourceFile.Text(), comment);
	}

	//
	// Source Maps
	//

	function setSourceMapSource(source:Source):Void {
		if (sourceMapsDisabled) {
			return;
		}

		sourceMapSource = source;
		sourceMapLineCharCache = newLineCharacterCache(source);
		if (mostRecentSourceMapSource == source) {
			sourceMapSourceIndex = mostRecentSourceMapSourceIndex;
			return;
		}

		sourceMapSourceIsJson = Tspath.FileExtensionIs(source.FileName(), Tspath.ExtensionJson);
		if (sourceMapSourceIsJson) {
			return;
		}

		sourceMapSourceIndex = sourceMapGenerator.AddSource(source.FileName());
		if (Options.InlineSources) {
			final err = sourceMapGenerator.SetSourceContent(sourceMapSourceIndex, source.Text());
			if (err != null) {
				throw err;
			}
		}

		mostRecentSourceMapSource = source;
		mostRecentSourceMapSourceIndex = sourceMapSourceIndex;
	}

	function emitPos(pos:Int):Void {
		if (sourceMapsDisabled || sourceMapSource == null || sourceMapGenerator == null || sourceMapSourceIsJson || Ast.PositionIsSynthesized(pos)) {
			return;
		}

		final line = sourceMapLineCharCache.getLineAndCharacter(pos);
		final character = sourceMapLineCharCache.lastCharacter; // PORT: perf (second result of getLineAndCharacter)
		final err = sourceMapGenerator.AddSourceMapping(writer.GetLine(), writer.GetColumn(), sourceMapSourceIndex, line, character);
		if (err != null) {
			throw err;
		}
	}

	// TODO: Support emitting nameIndex for source maps
	////func (p *Printer) emitPosName(pos int, name string) {
	////	...
	////}

	function emitSourcePos(source:Source, pos:Int):Void {
		if (source != sourceMapSource) {
			final savedSourceMapSource = sourceMapSource;
			final savedSourceMapSourceIndex = sourceMapSourceIndex;
			final savedSourceMapLineCharCache = sourceMapLineCharCache;
			setSourceMapSource(source);
			emitPos(pos);
			sourceMapSource = savedSourceMapSource;
			sourceMapSourceIndex = savedSourceMapSourceIndex;
			sourceMapLineCharCache = savedSourceMapLineCharCache;
		} else {
			emitPos(pos);
		}
	}

	// TODO: Support emitting nameIndex for source maps
	////func (p *Printer) emitSourcePosName(source sourcemap.Source, pos int, name string) {
	////	...
	////}

	function emitSourceMapsBeforeNode(node:Node):SourceMapState {
		if (!shouldEmitSourceMaps(node)) {
			return null;
		}

		final emitFlags = emitContext.EmitFlags(node);
		final loc = emitContext.SourceMapRange(node);

		if (!Ast.IsNotEmittedStatement(node) && emitFlags & EFNoLeadingSourceMap == 0 && currentSourceFile != null && !Ast.PositionIsSynthesized(loc.Pos())) {
			emitSourcePos(sourceMapSource, Scanner.SkipTrivia(currentSourceFile.Text(), loc.Pos()));
		}

		if (emitFlags & EFNoNestedSourceMaps != 0) {
			sourceMapsDisabled = true;
		}

		return new SourceMapState(emitFlags, loc, false);
	}

	function emitSourceMapsAfterNode(node:Node, previousState:SourceMapState):Void {
		if (previousState == null) {
			return;
		}

		final emitFlags = previousState.emitFlags;
		final loc = previousState.sourceMapRange;

		if (emitFlags & EFNoNestedSourceMaps != 0) {
			sourceMapsDisabled = false;
		}

		if (!Ast.IsNotEmittedStatement(node) && emitFlags & EFNoTrailingSourceMap == 0 && !Ast.PositionIsSynthesized(loc.End())) {
			emitSourcePos(sourceMapSource, loc.End());
		}
	}

	function emitSourceMapsBeforeToken(token:Kind, pos:Int, contextNode:Node, flags:TokenEmitFlags):SourceMapState {
		if (!shouldEmitTokenSourceMaps(token, pos, contextNode, flags)) {
			return null;
		}

		final emitFlags = emitContext.EmitFlags(contextNode);
		final loc = emitContext.TokenSourceMapRange(contextNode, token);
		final hasLoc = loc != null; // PORT: perf (null for Go's ok == false); loc is read only when hasLoc
		if (hasLoc) {
			pos = loc.Pos();
		}
		if (pos >= 0 && currentSourceFile != null) {
			pos = Scanner.SkipTrivia(currentSourceFile.Text(), pos);
		}
		if (emitFlags & EFNoTokenLeadingSourceMaps == 0 && pos >= 0) {
			emitSourcePos(sourceMapSource, pos);
		}

		return new SourceMapState(emitFlags, loc, hasLoc);
	}

	function emitSourceMapsAfterToken(token:Kind, pos:Int, contextNode:Node, previousState:SourceMapState):Void {
		if (previousState == null) {
			return;
		}

		final emitFlags = previousState.emitFlags;
		final loc = previousState.sourceMapRange;
		final hasLoc = previousState.hasTokenSourceMapRange;
		if (emitFlags & EFNoTokenTrailingSourceMaps == 0) {
			if (hasLoc) {
				pos = loc.End();
			}
			if (pos >= 0) {
				emitSourcePos(sourceMapSource, pos);
			}
		}
	}

	//
	// Name Generation
	//

	function shouldReuseTempVariableScope(node:Node):Bool {
		return node != null && emitContext.EmitFlags(node) & EFReuseTempVariableScope != 0;
	}

	function pushNameGenerationScope(node:Node):Void {
		nameGenerator.PushScope(shouldReuseTempVariableScope(node));
	}

	function popNameGenerationScope(node:Node):Void {
		nameGenerator.PopScope(shouldReuseTempVariableScope(node));
	}

	function generateAllNames(nodes:NodeList):Void {
		if (nodes == null || nodes.Nodes == null) {
			return;
		}
		for (node in nodes.Nodes) {
			generateNames(node);
		}
	}

	function generateNames(node:Node):Void {
		if (node == null) {
			return;
		}

		switch (node.Kind) {
			case KindBlock | KindCaseClause | KindDefaultClause:
				generateAllNames(node.StatementList());
			case KindLabeledStatement | KindWithStatement | KindDoStatement | KindWhileStatement:
				generateNames(node.Statement());
			case KindIfStatement:
				generateNames(node.AsIfStatement().ThenStatement);
				generateNames(node.AsIfStatement().ElseStatement);
			case KindForStatement | KindForOfStatement | KindForInStatement:
				generateNames(node.Initializer());
				generateNames(node.Statement());
			case KindSwitchStatement:
				generateNames(node.AsSwitchStatement().CaseBlock);
			case KindCaseBlock:
				generateAllNames(node.AsCaseBlock().Clauses);
			case KindTryStatement:
				generateNames(node.AsTryStatement().TryBlock);
				generateNames(node.AsTryStatement().CatchClause);
				generateNames(node.AsTryStatement().FinallyBlock);
			case KindCatchClause:
				generateNames(node.AsCatchClause().VariableDeclaration);
				generateNames(node.AsCatchClause().Block);
			case KindVariableStatement:
				generateNames(node.AsVariableStatement().DeclarationList);
			case KindVariableDeclarationList:
				generateAllNames(node.AsVariableDeclarationList().Declarations);
			case KindVariableDeclaration | KindParameter | KindBindingElement | KindClassDeclaration:
				generateNameIfNeeded(node.Name());
			case KindFunctionDeclaration:
				generateNameIfNeeded(node.Name());
				if (shouldReuseTempVariableScope(node)) {
					generateAllNames(node.AsFunctionDeclaration().Parameters);
					generateNames(node.AsFunctionDeclaration().Body);
				}
			case KindObjectBindingPattern | KindArrayBindingPattern:
				generateAllNames(node.ElementList());
			case KindImportDeclaration | KindJSImportDeclaration:
				generateNames(node.AsImportDeclaration().ImportClause);
			case KindImportClause:
				generateNameIfNeeded(node.AsImportClause().AsNode().Name());
				generateNames(node.AsImportClause().NamedBindings);
			case KindNamespaceImport | KindNamespaceExport:
				generateNameIfNeeded(node.Name());
			case KindNamedImports:
				generateAllNames(node.ElementList());
			case KindImportSpecifier:
				final n = node.AsImportSpecifier();
				if (n.PropertyName != null) {
					generateNameIfNeeded(n.PropertyName);
				} else {
					generateNameIfNeeded(n.AsNode().Name());
				}
			default:
		}
	}

	function generateAllMemberNames(nodes:NodeList):Void {
		if (nodes == null || nodes.Nodes == null) {
			return;
		}
		for (node in nodes.Nodes) {
			generateMemberNames(node);
		}
	}

	function generateMemberNames(node:Node):Void {
		if (node == null) {
			return;
		}
		switch (node.Kind) {
			case KindPropertyAssignment | KindShorthandPropertyAssignment | KindPropertyDeclaration | KindPropertySignature | KindMethodDeclaration |
				KindMethodSignature | KindGetAccessor | KindSetAccessor:
				generateNameIfNeeded(node.Name());
			default:
		}
	}

	function generateNameIfNeeded(name:DeclarationName):Void {
		if (name != null) {
			if (Ast.IsMemberName(name)) {
				generateName(name);
			} else if (Ast.IsBindingPattern(name)) {
				generateNames(name);
			}
		}
	}

	// Generate the text for a generated identifier or private identifier
	function generateName(name:MemberName):Void {
		nameGenerator.GenerateName(name);
	}

	// Returns a value indicating whether a name is unique globally or within the current file.
	function isFileLevelUniqueNameInCurrentFile(name:std.String, _:Bool):Bool {
		if (currentSourceFile != null) {
			return IsFileLevelUniqueName(currentSourceFile, name, HasGlobalName);
		} else {
			return true;
		}
	}

	//
	// Scoped operations
	//

	function enterNode(node:Node):PrinterState {
		final state = new PrinterState();

		if (OnBeforeEmitNode != null) {
			OnBeforeEmitNode(node);
		}

		state.commentState = emitCommentsBeforeNode(node);
		state.sourceMapState = emitSourceMapsBeforeNode(node);
		return state;
	}

	function exitNode(node:Node, previousState:PrinterState):Void {
		emitSourceMapsAfterNode(node, previousState.sourceMapState);
		emitCommentsAfterNode(node, previousState.commentState);

		if (OnAfterEmitNode != null) {
			OnAfterEmitNode(node);
		}
	}

	function enterTokenNode(node:Node, flags:TokenEmitFlags):PrinterState {
		final state = new PrinterState();

		if (OnBeforeEmitToken != null) {
			OnBeforeEmitToken(node);
		}

		if (flags & tefNoComments == 0) {
			state.commentState = emitCommentsBeforeNode(node);
		}
		if (flags & tefNoSourceMaps == 0) {
			state.sourceMapState = emitSourceMapsBeforeNode(node);
		}
		return state;
	}

	function exitTokenNode(node:Node, previousState:PrinterState):Void {
		emitSourceMapsAfterNode(node, previousState.sourceMapState);
		emitCommentsAfterNode(node, previousState.commentState);

		if (OnAfterEmitToken != null) {
			OnAfterEmitToken(node);
		}
	}

	// PORT: Go returns (printerState, int) → returns the state, the position in outPos.
	function enterToken(token:Kind, pos:Int, contextNode:Node, flags:TokenEmitFlags):PrinterState {
		final state = new PrinterState();
		state.commentState = emitCommentsBeforeToken(token, pos, contextNode, flags);
		pos = outPos;
		state.sourceMapState = emitSourceMapsBeforeToken(token, pos, contextNode, flags);
		outPos = pos;
		return state;
	}

	function exitToken(token:Kind, pos:Int, contextNode:Node, previousState:PrinterState):Void {
		emitSourceMapsAfterToken(token, pos, contextNode, previousState.sourceMapState);
		emitCommentsAfterToken(token, pos, contextNode, previousState.commentState);
	}

	static function getOpeningBracket(format:ListFormat):std.String {
		switch (format & LFBracketsMask) {
			case LFBraces:
				return "{";
			case LFParenthesis:
				return "(";
			case LFAngleBrackets:
				return "<";
			case LFSquareBrackets:
				return "[";
			default:
				throw 'Unexpected bracket: ${(format & LFBracketsMask : Int)}';
		}
	}

	static function getClosingBracket(format:ListFormat):std.String {
		switch (format & LFBracketsMask) {
			case LFBraces:
				return "}";
			case LFParenthesis:
				return ")";
			case LFAngleBrackets:
				return ">";
			case LFSquareBrackets:
				return "]";
			default:
				throw 'Unexpected bracket: ${(format & LFBracketsMask : Int)}';
		}
	}

	// PORT: method values (see header).
	static final fn_emitKeywordNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitKeywordNode(node);
	static final fn_emitModifierLike:(p:Printer, node:Node) -> Void = (p, node) -> p.emitModifierLike(node);
	static final fn_emitTypeParameterDeclarationNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitTypeParameterDeclarationNode(node);
	static final fn_emitParameterDeclarationNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitParameterDeclarationNode(node);
	static final fn_emitStatement:(p:Printer, node:Node) -> Void = (p, node) -> p.emitStatement(node);
	static final fn_emitTypeElement:(p:Printer, node:Node) -> Void = (p, node) -> p.emitTypeElement(node);
	static final fn_emitTupleElementType:(p:Printer, node:Node) -> Void = (p, node) -> p.emitTupleElementType(node);
	static final fn_emitUnionTypeConstituent:(p:Printer, node:Node) -> Void = (p, node) -> p.emitUnionTypeConstituent(node);
	static final fn_emitIntersectionTypeConstituent:(p:Printer, node:Node) -> Void = (p, node) -> p.emitIntersectionTypeConstituent(node);
	static final fn_emitTemplateTypeSpanNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitTemplateTypeSpanNode(node);
	static final fn_emitImportAttributeNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitImportAttributeNode(node);
	static final fn_emitBindingElementNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitBindingElementNode(node);
	static final fn_emitArrayLiteralExpressionElement:(p:Printer, node:Node) -> Void = (p, node) -> p.emitArrayLiteralExpressionElement(node);
	static final fn_emitObjectLiteralElement:(p:Printer, node:Node) -> Void = (p, node) -> p.emitObjectLiteralElement(node);
	static final fn_emitArgument:(p:Printer, node:Node) -> Void = (p, node) -> p.emitArgument(node);
	static final fn_emitTemplateSpanNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitTemplateSpanNode(node);
	static final fn_emitHeritageClauseNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitHeritageClauseNode(node);
	static final fn_emitClassElement:(p:Printer, node:Node) -> Void = (p, node) -> p.emitClassElement(node);
	static final fn_emitVariableDeclarationNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitVariableDeclarationNode(node);
	static final fn_emitEnumMemberNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitEnumMemberNode(node);
	static final fn_emitCaseOrDefaultClauseNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitCaseOrDefaultClauseNode(node);
	static final fn_emitImportSpecifierNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitImportSpecifierNode(node);
	static final fn_emitExportSpecifierNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitExportSpecifierNode(node);
	static final fn_emitJsxChild:(p:Printer, node:Node) -> Void = (p, node) -> p.emitJsxChild(node);
	static final fn_emitJsxAttributeLike:(p:Printer, node:Node) -> Void = (p, node) -> p.emitJsxAttributeLike(node);
	static final fn_emitExpressionWithTypeArgumentsNode:(p:Printer, node:Node) -> Void = (p, node) -> p.emitExpressionWithTypeArgumentsNode(node);
	static final fn_IsModifier:(node:Node) -> Bool = node -> Ast.IsModifier(node);
	static final fn_IsDecorator:(node:Node) -> Bool = node -> Ast.IsDecorator(node);

	// --- changetrackerwriter.go ---

	public static function NewChangeTrackerWriter(newline:std.String, indentSize:Int):ChangeTrackerWriter {
		// TODO: Callers passing -1 should pass actual indent options once indent-related formatting is ported.
		if (indentSize < 0) {
			indentSize = defaultIndentSize;
		}
		final ctw = new ChangeTrackerWriter();
		ctw.textWriter.newLine = newline;
		ctw.textWriter.indentSize = indentSize;
		ctw.lastNonTriviaPosition = 0;
		ctw.pos = new IdentityMap<{}, Int>();
		ctw.end = new IdentityMap<{}, Int>();
		ctw.textWriter.Clear();
		return ctw;
	}

	// --- emitcontext.go ---

	public static function NewEmitContext():EmitContext {
		final c = new EmitContext();
		c.Factory = NewNodeFactory(c);
		return c;
	}

	// PORT: Go keeps EmitContexts in a sync.Pool; single-threaded, a new context is created and the
	// release function resets it (as Go does before returning it to the pool).
	// Go returns (*EmitContext, func()) → Pair.
	public static function GetEmitContext():Pair<EmitContext, () -> Void> {
		final c = NewEmitContext();
		return new Pair<EmitContext, () -> Void>(c, function() {
			c.Reset();
		});
	}

	static function isHoistedVariable(node:VariableDeclarationNode):Bool {
		return Ast.IsIdentifier(node.Name()) && node.Initializer() == null;
	}

	// PORT: atomic.Uint32 → plain Int (single-threaded).
	static var nextAutoGenerateId:Int = 0;
	#if tshx_parallel
	static final autoGenerateIds = new haxe.atomic.AtomicInt(0); // PORT: hxmc (-D tshx-parallel)
	#end

	public static inline function NextAutoGenerateId():Int {
		#if tshx_parallel
		return autoGenerateIds.add(1) + 1;
		#else
		return ++nextAutoGenerateId;
		#end
	}

	// --- factory.go ---

	public static function NewNodeFactory(context:EmitContext):NodeFactory {
		final f = new NodeFactory();
		f.init(context);
		return f;
	}

	static function flattenCommaElement(node:Expression, expressions:Array<Expression>):Array<Expression> {
		if (Ast.IsBinaryExpression(node) && Ast.NodeIsSynthesized(node) && node.AsBinaryExpression().OperatorToken.Kind == KindCommaToken) {
			expressions = flattenCommaElement(node.AsBinaryExpression().Left, expressions);
			expressions = flattenCommaElement(node.AsBinaryExpression().Right, expressions);
		} else {
			expressions = appendNode(expressions, node);
		}
		return expressions;
	}

	static function flattenCommaElements(expressions:Array<Expression>):Array<Expression> {
		var result:Array<Expression> = null;
		for (expression in expressions) {
			result = flattenCommaElement(expression, result);
		}
		return result;
	}

	// PORT: Go `append(s, x)` on a slice the caller owns (nil → new array).
	static inline function appendNode(s:Array<Node>, x:Node):Array<Node> {
		if (s == null) {
			return [x];
		}
		s.push(x);
		return s;
	}

	// --- helpers.go ---

	static function compareEmitHelpers(x:EmitHelper, y:EmitHelper):Int {
		if (x == y) {
			return 0;
		}
		if (x.Priority == y.Priority) {
			return 0;
		}
		if (x.Priority == null) {
			return 1;
		}
		if (y.Priority == null) {
			return -1;
		}
		return x.Priority.Value - y.Priority.Value;
	}

	// TypeScript Helpers

	static final decorateHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:decorate";
		h.ImportName = "__decorate";
		h.Scoped = false;
		h.Priority = new Priority(2);
		h.Text = "var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {\n"
			+ "    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;\n"
			+ "    if (typeof Reflect === \"object\" && typeof Reflect.decorate === \"function\") r = Reflect.decorate(decorators, target, key, desc);\n"
			+ "    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;\n"
			+ "    return c > 3 && r && Object.defineProperty(target, key, r), r;\n"
			+ "};";
		h;
	};

	static final metadataHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:metadata";
		h.ImportName = "__metadata";
		h.Scoped = false;
		h.Priority = new Priority(3);
		h.Text = "var __metadata = (this && this.__metadata) || function (k, v) {\n"
			+ "    if (typeof Reflect === \"object\" && typeof Reflect.metadata === \"function\") return Reflect.metadata(k, v);\n"
			+ "};";
		h;
	};

	static final paramHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:param";
		h.ImportName = "__param";
		h.Scoped = false;
		h.Priority = new Priority(4);
		h.Text = "var __param = (this && this.__param) || function (paramIndex, decorator) {\n"
			+ "    return function (target, key) { decorator(target, key, paramIndex); }\n"
			+ "};";
		h;
	};

	// ESNext Helpers

	static final addDisposableResourceHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:addDisposableResource";
		h.ImportName = "__addDisposableResource";
		h.Scoped = false;
		h.Text = "var __addDisposableResource = (this && this.__addDisposableResource) || function (env, value, async) {\n"
			+ "    if (value !== null && value !== void 0) {\n"
			+ "        if (typeof value !== \"object\" && typeof value !== \"function\") throw new TypeError(\"Object expected.\");\n"
			+ "        var dispose, inner;\n"
			+ "        if (async) {\n"
			+ "            if (!Symbol.asyncDispose) throw new TypeError(\"Symbol.asyncDispose is not defined.\");\n"
			+ "            dispose = value[Symbol.asyncDispose];\n"
			+ "        }\n"
			+ "        if (dispose === void 0) {\n"
			+ "            if (!Symbol.dispose) throw new TypeError(\"Symbol.dispose is not defined.\");\n"
			+ "            dispose = value[Symbol.dispose];\n"
			+ "            if (async) inner = dispose;\n"
			+ "        }\n"
			+ "        if (typeof dispose !== \"function\") throw new TypeError(\"Object not disposable.\");\n"
			+ "        if (inner) dispose = function() { try { inner.call(this); } catch (e) { return Promise.reject(e); } };\n"
			+ "        env.stack.push({ value: value, dispose: dispose, async: async });\n"
			+ "    }\n"
			+ "    else if (async) {\n"
			+ "        env.stack.push({ async: true });\n"
			+ "    }\n"
			+ "    return value;\n"
			+ "};";
		h;
	};

	static final disposeResourcesHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:disposeResources";
		h.ImportName = "__disposeResources";
		h.Scoped = false;
		h.Text = "var __disposeResources = (this && this.__disposeResources) || (function (SuppressedError) {\n"
			+ "    return function (env) {\n"
			+ "        function fail(e) {\n"
			+ "            env.error = env.hasError ? new SuppressedError(e, env.error, \"An error was suppressed during disposal.\") : e;\n"
			+ "            env.hasError = true;\n"
			+ "        }\n"
			+ "        var r, s = 0;\n"
			+ "        function next() {\n"
			+ "            while (r = env.stack.pop()) {\n"
			+ "                try {\n"
			+ "                    if (!r.async && s === 1) return s = 0, env.stack.push(r), Promise.resolve().then(next);\n"
			+ "                    if (r.dispose) {\n"
			+ "                        var result = r.dispose.call(r.value);\n"
			+ "                        if (r.async) return s |= 2, Promise.resolve(result).then(next, function(e) { fail(e); return next(); });\n"
			+ "                    }\n"
			+ "                    else s |= 1;\n"
			+ "                }\n"
			+ "                catch (e) {\n"
			+ "                    fail(e);\n"
			+ "                }\n"
			+ "            }\n"
			+ "            if (s === 1) return env.hasError ? Promise.reject(env.error) : Promise.resolve();\n"
			+ "            if (env.hasError) throw env.error;\n"
			+ "        }\n"
			+ "        return next();\n"
			+ "    };\n"
			+ "})(typeof SuppressedError === \"function\" ? SuppressedError : function (error, suppressed, message) {\n"
			+ "    var e = new Error(message);\n"
			+ "    return e.name = \"SuppressedError\", e.error = error, e.suppressed = suppressed, e;\n"
			+ "});";
		h;
	};

	// Class Fields Helpers

	/**
	 * Parameters:
	 *  @param receiver — The object from which the private member will be read.
	 *  @param state — One of the following:
	 *      - A WeakMap used to read a private instance field.
	 *      - A WeakSet used as an instance brand for private instance methods and accessors.
	 *      - A function value that should be the undecorated class constructor used to brand check private static fields, methods, and accessors.
	 *  @param kind — (optional pre TS 4.3, required for TS 4.3+) One of the following values:
	 *      - undefined — Indicates a private instance field (pre TS 4.3).
	 *      - "f" — Indicates a private field (instance or static).
	 *      - "m" — Indicates a private method (instance or static).
	 *      - "a" — Indicates a private accessor (instance or static).
	 *  @param f — (optional pre TS 4.3) Depends on the arguments for state and kind:
	 *      - If kind is "m", this should be the function corresponding to the static or instance method.
	 *      - If kind is "a", this should be the function corresponding to the getter method, or undefined if the getter was not defined.
	 *      - If kind is "f" and state is a function, this should be an object holding the value of a static field, or undefined if the static field declaration has not yet been evaluated.
	 * Usage:
	 * This helper will only ever be used by the compiler in the following ways:
	 *
	 * Reading from a private instance field (pre TS 4.3):
	 *      __classPrivateFieldGet(<any>, <WeakMap>)
	 *
	 * Reading from a private instance field (TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <WeakMap>, "f")
	 *
	 * Reading from a private instance get accessor (when defined, TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <WeakSet>, "a", <function>)
	 *
	 * Reading from a private instance get accessor (when not defined, TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <WeakSet>, "a", void 0)
	 *      NOTE: This always results in a runtime error.
	 *
	 * Reading from a private instance method (TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <WeakSet>, "m", <function>)
	 *
	 * Reading from a private static field (TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <constructor>, "f", <{ value: any }>)
	 *
	 * Reading from a private static get accessor (when defined, TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <constructor>, "a", <function>)
	 *
	 * Reading from a private static get accessor (when not defined, TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <constructor>, "a", void 0)
	 *      NOTE: This always results in a runtime error.
	 *
	 * Reading from a private static method (TS 4.3+):
	 *      __classPrivateFieldGet(<any>, <constructor>, "m", <function>)
	 */
	static final classPrivateFieldGetHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:classPrivateFieldGet";
		h.ImportName = "__classPrivateFieldGet";
		h.Scoped = false;
		h.Text = "var __classPrivateFieldGet = (this && this.__classPrivateFieldGet) || function (receiver, state, kind, f) {\n"
			+ "    if (kind === \"a\" && !f) throw new TypeError(\"Private accessor was defined without a getter\");\n"
			+ "    if (typeof state === \"function\" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError(\"Cannot read private member from an object whose class did not declare it\");\n"
			+ "    return kind === \"m\" ? f : kind === \"a\" ? f.call(receiver) : f ? f.value : state.get(receiver);\n"
			+ "};";
		h;
	};

	/**
	 * Parameters:
	 *  @param receiver — The object on which the private member will be set.
	 *  @param state — One of the following:
	 *      - A WeakMap used to store a private instance field.
	 *      - A WeakSet used as an instance brand for private instance methods and accessors.
	 *      - A function value that should be the undecorated class constructor used to brand check private static fields, methods, and accessors.
	 *  @param value — The value to set.
	 *  @param kind — (optional pre TS 4.3, required for TS 4.3+) One of the following values:
	 *       - undefined — Indicates a private instance field (pre TS 4.3).
	 *       - "f" — Indicates a private field (instance or static).
	 *       - "m" — Indicates a private method (instance or static).
	 *       - "a" — Indicates a private accessor (instance or static).
	 *   @param f — (optional pre TS 4.3) Depends on the arguments for state and kind:
	 *       - If kind is "m", this should be the function corresponding to the static or instance method.
	 *       - If kind is "a", this should be the function corresponding to the setter method, or undefined if the setter was not defined.
	 *       - If kind is "f" and state is a function, this should be an object holding the value of a static field, or undefined if the static field declaration has not yet been evaluated.
	 * Usage:
	 * This helper will only ever be used by the compiler in the following ways:
	 *
	 * Writing to a private instance field (pre TS 4.3):
	 *      __classPrivateFieldSet(<any>, <WeakMap>, <any>)
	 *
	 * Writing to a private instance field (TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <WeakMap>, <any>, "f")
	 *
	 * Writing to a private instance set accessor (when defined, TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "a", <function>)
	 *
	 * Writing to a private instance set accessor (when not defined, TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "a", void 0)
	 *      NOTE: This always results in a runtime error.
	 *
	 * Writing to a private instance method (TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "m", <function>)
	 *      NOTE: This always results in a runtime error.
	 *
	 * Writing to a private static field (TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <constructor>, <any>, "f", <{ value: any }>)
	 *
	 * Writing to a private static set accessor (when defined, TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <constructor>, <any>, "a", <function>)
	 *
	 * Writing to a private static set accessor (when not defined, TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <constructor>, <any>, "a", void 0)
	 *      NOTE: This always results in a runtime error.
	 *
	 * Writing to a private static method (TS 4.3+):
	 *      __classPrivateFieldSet(<any>, <constructor>, <any>, "m", <function>)
	 *      NOTE: This always results in a runtime error.
	 */
	static final classPrivateFieldSetHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:classPrivateFieldSet";
		h.ImportName = "__classPrivateFieldSet";
		h.Scoped = false;
		h.Text = "var __classPrivateFieldSet = (this && this.__classPrivateFieldSet) || function (receiver, state, value, kind, f) {\n"
			+ "    if (kind === \"m\") throw new TypeError(\"Private method is not writable\");\n"
			+ "    if (kind === \"a\" && !f) throw new TypeError(\"Private accessor was defined without a setter\");\n"
			+ "    if (typeof state === \"function\" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError(\"Cannot write private member to an object whose class did not declare it\");\n"
			+ "    return (kind === \"a\" ? f.call(receiver, value) : f ? f.value = value : state.set(receiver, value)), value;\n"
			+ "};";
		h;
	};

	/**
	 * Parameters:
	 *  @param state — One of the following:
	 *      - A WeakMap when the member is a private instance field.
	 *      - A WeakSet when the member is a private instance method or accessor.
	 *      - A function value that should be the undecorated class constructor when the member is a private static field, method, or accessor.
	 *  @param receiver — The object being checked if it has the private member.
	 *
	 * Usage:
	 * This helper is used to transform `#field in expression` to
	 *      `__classPrivateFieldIn(<weakMap/weakSet/constructor>, expression)`
	 */
	static final classPrivateFieldInHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:classPrivateFieldIn";
		h.ImportName = "__classPrivateFieldIn";
		h.Scoped = false;
		h.Text = "var __classPrivateFieldIn = (this && this.__classPrivateFieldIn) || function(state, receiver) {\n"
			+ "    if (receiver === null || (typeof receiver !== \"object\" && typeof receiver !== \"function\")) throw new TypeError(\"Cannot use 'in' operator on non-object\");\n"
			+ "    return typeof state === \"function\" ? receiver === state : state.has(receiver);\n"
			+ "};";
		h;
	};

	// ES2018 Helpers

	static final awaitHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:await";
		h.ImportName = "__await";
		h.Scoped = false;
		h.Text = "var __await = (this && this.__await) || function (v) { return this instanceof __await ? (this.v = v, this) : new __await(v); }";
		h;
	};

	static final asyncGeneratorHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:asyncGenerator";
		h.ImportName = "__asyncGenerator";
		h.Scoped = false;
		h.Dependencies = [awaitHelper];
		h.Text = "var __asyncGenerator = (this && this.__asyncGenerator) || function (thisArg, _arguments, generator) {\n"
			+ "    if (!Symbol.asyncIterator) throw new TypeError(\"Symbol.asyncIterator is not defined.\");\n"
			+ "    var g = generator.apply(thisArg, _arguments || []), i, q = [];\n"
			+ "    return i = Object.create((typeof AsyncIterator === \"function\" ? AsyncIterator : Object).prototype), verb(\"next\"), verb(\"throw\"), verb(\"return\", awaitReturn), i[Symbol.asyncIterator] = function () { return this; }, i;\n"
			+ "    function awaitReturn(f) { return function (v) { return Promise.resolve(v).then(f, reject); }; }\n"
			+ "    function verb(n, f) { if (g[n]) { i[n] = function (v) { return new Promise(function (a, b) { q.push([n, v, a, b]) > 1 || resume(n, v); }); }; if (f) i[n] = f(i[n]); } }\n"
			+ "    function resume(n, v) { try { step(g[n](v)); } catch (e) { settle(q[0][3], e); } }\n"
			+ "    function step(r) { r.value instanceof __await ? Promise.resolve(r.value.v).then(fulfill, reject) : settle(q[0][2], r); }\n"
			+ "    function fulfill(value) { resume(\"next\", value); }\n"
			+ "    function reject(value) { resume(\"throw\", value); }\n"
			+ "    function settle(f, v) { if (f(v), q.shift(), q.length) resume(q[0][0], q[0][1]); }\n"
			+ "};";
		h;
	};

	static final asyncDelegatorHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:asyncDelegator";
		h.ImportName = "__asyncDelegator";
		h.Scoped = false;
		h.Dependencies = [awaitHelper];
		h.Text = "var __asyncDelegator = (this && this.__asyncDelegator) || function (o) {\n"
			+ "    var i, p;\n"
			+ "    return i = {}, verb(\"next\"), verb(\"throw\", function (e) { throw e; }), verb(\"return\"), i[Symbol.iterator] = function () { return this; }, i;\n"
			+ "    function verb(n, f) { i[n] = o[n] ? function (v) { return (p = !p) ? { value: __await(o[n](v)), done: false } : f ? f(v) : v; } : f; }\n"
			+ "};";
		h;
	};

	static final asyncValuesHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:asyncValues";
		h.ImportName = "__asyncValues";
		h.Scoped = false;
		h.Text = "var __asyncValues = (this && this.__asyncValues) || function (o) {\n"
			+ "    if (!Symbol.asyncIterator) throw new TypeError(\"Symbol.asyncIterator is not defined.\");\n"
			+ "    var m = o[Symbol.asyncIterator], i;\n"
			+ "    return m ? m.call(o) : (o = typeof __values === \"function\" ? __values(o) : o[Symbol.iterator](), i = {}, verb(\"next\"), verb(\"throw\"), verb(\"return\"), i[Symbol.asyncIterator] = function () { return this; }, i);\n"
			+ "    function verb(n) { i[n] = o[n] && function (v) { return new Promise(function (resolve, reject) { v = o[n](v), settle(resolve, reject, v.done, v.value); }); }; }\n"
			+ "    function settle(resolve, reject, d, v) { Promise.resolve(v).then(function(v) { resolve({ value: v, done: d }); }, reject); }\n"
			+ "};";
		h;
	};

	// ES2018 Destructuring Helpers
	static final restHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:rest";
		h.ImportName = "__rest";
		h.Scoped = false;
		h.Text = "var __rest = (this && this.__rest) || function (s, e) {\n"
			+ "    var t = {};\n"
			+ "    for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0)\n"
			+ "        t[p] = s[p];\n"
			+ "    if (s != null && typeof Object.getOwnPropertySymbols === \"function\")\n"
			+ "        for (var i = 0, p = Object.getOwnPropertySymbols(s); i < p.length; i++) {\n"
			+ "            if (e.indexOf(p[i]) < 0 && Object.prototype.propertyIsEnumerable.call(s, p[i]))\n"
			+ "                t[p[i]] = s[p[i]];\n"
			+ "        }\n"
			+ "    return t;\n"
			+ "};";
		h;
	};

	static final awaiterHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:awaiter";
		h.ImportName = "__awaiter";
		h.Scoped = false;
		h.Priority = new Priority(5);
		h.Text = "var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {\n"
			+ "    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }\n"
			+ "    return new (P || (P = Promise))(function (resolve, reject) {\n"
			+ "        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }\n"
			+ "        function rejected(value) { try { step(generator[\"throw\"](value)); } catch (e) { reject(e); } }\n"
			+ "        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }\n"
			+ "        step((generator = generator.apply(thisArg, _arguments || [])).next());\n"
			+ "    });\n"
			+ "};";
		h;
	};

	// PORT: the Go func literal of TextCallback is a static function value (created once).
	static final fn_AsyncSuperHelper_TextCallback:(makeUniqueName:(std.String) -> std.String) -> std.String = function(makeUniqueName) {
		return "\nconst " + makeUniqueName("_superIndex") + " = name => super[name];";
	};

	public static final AsyncSuperHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:async-super";
		h.Scoped = true;
		h.TextCallback = fn_AsyncSuperHelper_TextCallback;
		h;
	};

	// PORT: the Go func literal of TextCallback is a static function value (created once).
	static final fn_AdvancedAsyncSuperHelper_TextCallback:(makeUniqueName:(std.String) -> std.String) -> std.String = function(makeUniqueName) {
		return "\nconst " + makeUniqueName("_superIndex") + " = (function (geti, seti) {\n"
			+ "    const cache = Object.create(null);\n"
			+ "    return name => cache[name] || (cache[name] = { get value() { return geti(name); }, set value(v) { seti(name, v); } });\n"
			+ "})(name => super[name], (name, value) => super[name] = value);";
	};

	public static final AdvancedAsyncSuperHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:advanced-async-super";
		h.Scoped = true;
		h.TextCallback = fn_AdvancedAsyncSuperHelper_TextCallback;
		h;
	};

	// ES Decorator Helpers

	static final esDecorateHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:esDecorate";
		h.ImportName = "__esDecorate";
		h.Scoped = false;
		h.Priority = new Priority(2);
		h.Text = "var __esDecorate = (this && this.__esDecorate) || function (ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers) {\n"
			+ "    function accept(f) { if (f !== void 0 && typeof f !== \"function\") throw new TypeError(\"Function expected\"); return f; }\n"
			+ "    var kind = contextIn.kind, key = kind === \"getter\" ? \"get\" : kind === \"setter\" ? \"set\" : \"value\";\n"
			+ "    var target = !descriptorIn && ctor ? contextIn[\"static\"] ? ctor : ctor.prototype : null;\n"
			+ "    var descriptor = descriptorIn || (target ? Object.getOwnPropertyDescriptor(target, contextIn.name) : {});\n"
			+ "    var _, done = false;\n"
			+ "    for (var i = decorators.length - 1; i >= 0; i--) {\n"
			+ "        var context = {};\n"
			+ "        for (var p in contextIn) context[p] = p === \"access\" ? {} : contextIn[p];\n"
			+ "        for (var p in contextIn.access) context.access[p] = contextIn.access[p];\n"
			+ "        context.addInitializer = function (f) { if (done) throw new TypeError(\"Cannot add initializers after decoration has completed\"); extraInitializers.push(accept(f || null)); };\n"
			+ "        var result = (0, decorators[i])(kind === \"accessor\" ? { get: descriptor.get, set: descriptor.set } : descriptor[key], context);\n"
			+ "        if (kind === \"accessor\") {\n"
			+ "            if (result === void 0) continue;\n"
			+ "            if (result === null || typeof result !== \"object\") throw new TypeError(\"Object expected\");\n"
			+ "            if (_ = accept(result.get)) descriptor.get = _;\n"
			+ "            if (_ = accept(result.set)) descriptor.set = _;\n"
			+ "            if (_ = accept(result.init)) initializers.unshift(_);\n"
			+ "        }\n"
			+ "        else if (_ = accept(result)) {\n"
			+ "            if (kind === \"field\") initializers.unshift(_);\n"
			+ "            else descriptor[key] = _;\n"
			+ "        }\n"
			+ "    }\n"
			+ "    if (target) Object.defineProperty(target, contextIn.name, descriptor);\n"
			+ "    done = true;\n"
			+ "};";
		h;
	};

	static final runInitializersHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:runInitializers";
		h.ImportName = "__runInitializers";
		h.Scoped = false;
		h.Priority = new Priority(2);
		h.Text = "var __runInitializers = (this && this.__runInitializers) || function (thisArg, initializers, value) {\n"
			+ "    var useValue = arguments.length > 2;\n"
			+ "    for (var i = 0; i < initializers.length; i++) {\n"
			+ "        value = useValue ? initializers[i].call(thisArg, value) : initializers[i].call(thisArg);\n"
			+ "    }\n"
			+ "    return useValue ? value : void 0;\n"
			+ "};";
		h;
	};

	// ES2015 Helpers

	static final makeTemplateObjectHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:makeTemplateObject";
		h.ImportName = "__makeTemplateObject";
		h.Scoped = false;
		h.Priority = new Priority(0);
		h.Text = "var __makeTemplateObject = (this && this.__makeTemplateObject) || function (cooked, raw) {\n"
			+ "    if (Object.defineProperty) { Object.defineProperty(cooked, \"raw\", { value: raw }); } else { cooked.raw = raw; }\n"
			+ "    return cooked;\n"
			+ "};";
		h;
	};

	static final propKeyHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:propKey";
		h.ImportName = "__propKey";
		h.Scoped = false;
		h.Text = "var __propKey = (this && this.__propKey) || function (x) {\n"
			+ "    return typeof x === \"symbol\" ? x : \"\".concat(x);\n"
			+ "};";
		h;
	};

	// https://tc39.es/ecma262/#sec-setfunctionname
	static final setFunctionNameHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:setFunctionName";
		h.ImportName = "__setFunctionName";
		h.Scoped = false;
		h.Text = "var __setFunctionName = (this && this.__setFunctionName) || function (f, name, prefix) {\n"
			+ "    if (typeof name === \"symbol\") name = name.description ? \"[\".concat(name.description, \"]\") : \"\";\n"
			+ "    return Object.defineProperty(f, \"name\", { configurable: true, value: prefix ? \"\".concat(prefix, \" \", name) : name });\n"
			+ "};";
		h;
	};

	// ES Module Helpers

	static final createBindingHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:commonjscreatebinding";
		h.ImportName = "__createBinding";
		h.Scoped = false;
		h.Priority = new Priority(1);
		h.Text = "var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {\n"
			+ "    if (k2 === undefined) k2 = k;\n"
			+ "    var desc = Object.getOwnPropertyDescriptor(m, k);\n"
			+ "    if (!desc || (\"get\" in desc ? !m.__esModule : desc.writable || desc.configurable)) {\n"
			+ "      desc = { enumerable: true, get: function() { return m[k]; } };\n"
			+ "    }\n"
			+ "    Object.defineProperty(o, k2, desc);\n"
			+ "}) : (function(o, m, k, k2) {\n"
			+ "    if (k2 === undefined) k2 = k;\n"
			+ "    o[k2] = m[k];\n"
			+ "}));";
		h;
	};

	static final setModuleDefaultHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:commonjscreatevalue";
		h.ImportName = "__setModuleDefault";
		h.Scoped = false;
		h.Priority = new Priority(1);
		h.Text = "var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {\n"
			+ "    Object.defineProperty(o, \"default\", { enumerable: true, value: v });\n"
			+ "}) : function(o, v) {\n"
			+ "    o[\"default\"] = v;\n"
			+ "});";
		h;
	};

	static final importStarHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:commonjsimportstar";
		h.ImportName = "__importStar";
		h.Scoped = false;
		h.Dependencies = [createBindingHelper, setModuleDefaultHelper];
		h.Priority = new Priority(2);
		h.Text = "var __importStar = (this && this.__importStar) || (function () {\n"
			+ "    var ownKeys = function(o) {\n"
			+ "        ownKeys = Object.getOwnPropertyNames || function (o) {\n"
			+ "            var ar = [];\n"
			+ "            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;\n"
			+ "            return ar;\n"
			+ "        };\n"
			+ "        return ownKeys(o);\n"
			+ "    };\n"
			+ "    return function (mod) {\n"
			+ "        if (mod && mod.__esModule) return mod;\n"
			+ "        var result = {};\n"
			+ "        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== \"default\") __createBinding(result, mod, k[i]);\n"
			+ "        __setModuleDefault(result, mod);\n"
			+ "        return result;\n"
			+ "    };\n"
			+ "})();";
		h;
	};

	static final importDefaultHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:commonjsimportdefault";
		h.ImportName = "__importDefault";
		h.Scoped = false;
		h.Text = "var __importDefault = (this && this.__importDefault) || function (mod) {\n"
			+ "    return (mod && mod.__esModule) ? mod : { \"default\": mod };\n"
			+ "};";
		h;
	};

	static final exportStarHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:export-star";
		h.ImportName = "__exportStar";
		h.Scoped = false;
		h.Dependencies = [createBindingHelper];
		h.Priority = new Priority(2);
		h.Text = "var __exportStar = (this && this.__exportStar) || function(m, exports) {\n"
			+ "    for (var p in m) if (p !== \"default\" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);\n"
			+ "};";
		h;
	};

	static final rewriteRelativeImportExtensionsHelper:EmitHelper = {
		final h = new EmitHelper();
		h.Name = "typescript:rewriteRelativeImportExtensions";
		h.ImportName = "__rewriteRelativeImportExtension";
		h.Scoped = false;
		h.Text = "var __rewriteRelativeImportExtension = (this && this.__rewriteRelativeImportExtension) || function (path, preserveJsx) {\n"
			+ "    if (typeof path === \"string\" && /^\\.\\.?\\//.test(path)) {\n"
			+ "        return path.replace(/\\.(tsx)$|((?:\\.d)?)((?:\\.[^./]+?)?)\\.([cm]?)ts$/i, function (m, tsx, d, ext, cm) {\n"
			+ "            return tsx ? preserveJsx ? \".jsx\" : \".js\" : d && (!ext || !cm) ? m : (d + ext + \".\" + cm.toLowerCase() + \"js\");\n"
			+ "        });\n"
			+ "    }\n"
			+ "    return path;\n"
			+ "};";
		h;
	};


	// --- namegenerator.go ---

	static function nextContainer(node:Node):Node {
		final data = node.LocalsContainerData();
		if (data != null) {
			return data.NextContainer;
		}
		return null;
	}

	static function isUniqueLocalName(name:std.String, container:Node):Bool {
		var node = container;
		while (node != null && Ast.IsNodeDescendantOf(node, container) && node.LocalsContainerData() != null) {
			final locals = node.Locals();
			if (locals != null) {
				// We conservatively include alias symbols to cover cases where they're emitted as locals
				final local = locals.get(name);
				if (local != null && local.Flags & (SymbolFlagsValue | SymbolFlagsExportValue | SymbolFlagsAlias) != 0) {
					return false;
				}
			}
			node = nextContainer(node);
		}
		return true;
	}

	// --- singlelinestringwriter.go ---

	// PORT: Go keeps the writers in a sync.Pool; single-threaded, a new writer is created and the
	// release function does nothing. Go returns (EmitTextWriter, func()) → Pair.
	public static function GetSingleLineStringWriter():Pair<EmitTextWriter, () -> Void> {
		final w = new SingleLineStringWriter();
		w.Clear();
		return new Pair<EmitTextWriter, () -> Void>(w, function() {});
	}

	// --- textwriter.go ---

	static inline final defaultIndentSize = 4;

	// GetDefaultIndentSize returns the default indent size (4 spaces) used when no specific indent size is configured.
	public static function GetDefaultIndentSize():Int {
		return defaultIndentSize;
	}

	// PORT: one shared string of spaces, sliced (Go strings.Repeat allocates each time).
	static var spaces:std.String = "    ";

	static function getIndentString(indent:Int, indentSize:Int):std.String {
		if (indent == 0) {
			return "";
		}
		// TODO: This is cached in tsc - should it be cached here?
		final n = indent * indentSize;
		while (spaces.length < n) {
			spaces += spaces;
		}
		return spaces.substring(0, n);
	}

	public static function NewTextWriter(newLine:std.String, indentSize:Int):EmitTextWriter {
		if (indentSize <= 0) {
			indentSize = 4;
		}
		final w = new TextWriter();
		w.newLine = newLine;
		w.indentSize = indentSize;
		w.Clear();
		return w;
	}

	// --- utilities.go ---

	// PORT: Go `jsxEscapedCharsMap` / `escapedCharsMap` (map[rune]string) → lookup functions (null = absent).
	static function jsxEscapedCharsMap(ch:Int):Null<std.String> {
		switch (ch) {
			case '"'.code:
				return "&quot;";
			case "'".code:
				return "&apos;";
			default:
				return null;
		}
	}

	static function escapedCharsMap(ch:Int):Null<std.String> {
		switch (ch) {
			case "\t".code:
				return "\\t";
			case 0x0B:
				return "\\v";
			case 0x0C:
				return "\\f";
			case 0x08:
				return "\\b";
			case "\r".code:
				return "\\r";
			case "\n".code:
				return "\\n";
			case "\\".code:
				return "\\\\";
			case '"'.code:
				return "\\\"";
			case "'".code:
				return "\\'";
			case "`".code:
				return "\\`";
			case "$".code:
				return "\\$"; // when quoteChar == '`'
			case 0x2028:
				return "\\u2028"; // lineSeparator
			case 0x2029:
				return "\\u2029"; // paragraphSeparator
			case 0x0085:
				return "\\u0085"; // nextLine
			default:
				return null;
		}
	}

	static function encodeJsxCharacterEntity(b:StringBuf, charCode:Int):Void {
		final hexCharCode = StringTools.hex(charCode).toUpperCase();
		b.add("&#x");
		b.add(hexCharCode);
		b.addChar(";".code);
	}

	static function encodeUtf16EscapeSequence(b:StringBuf, charCode:Int):Void {
		final hexCharCode = StringTools.hex(charCode).toUpperCase();
		b.add("\\u");
		for (_ in hexCharCode.length...4) {
			b.addChar("0".code);
		}
		b.add(hexCharCode);
	}

	// Based heavily on the abstract 'Quote'/'QuoteJSONString' operation from ECMA-262 (24.3.2.2),
	// but augmented for a few select characters (e.g. lineSeparator, paragraphSeparator, nextLine)
	// Note that this doesn't actually wrap the input in double quotes.
	// PORT: utf16 — Go decodes UTF-8 with DecodeJSStringRune (a lone surrogate sentinel decodes to the
	// surrogate); here the string is UTF-16 (a lone surrogate is one code unit). Go's extra check for a
	// stray invalid UTF-8 byte (`ch == utf8.RuneError && size == 1`): the only such byte the port can
	// carry is Go's 0xFE (ast.InternalSymbolNamePrefix), stored as U+FFFE (PORTING §5); it decodes
	// to utf8.RuneError like in Go.
	static function escapeStringWorker(s:std.String, quoteChar:QuoteChar, flags:GetLiteralTextFlags, b:StringBuf):Void {
		var pos = 0;
		var i = 0;
		while (i < s.length) {
			var ch = Stringutil.DecodeJSStringRune(s, i);
			var size = Utf16.RuneLen(ch);

			var escape = false;
			if (ch >= 0xD800 && ch <= 0xDFFF) {
				escape = true;
			} else if (ch == 0xFFFE) {
				// A stray byte that is not valid UTF-8 (for example, a fragment of a
				// surrogate sentinel left behind by code that sliced the string by
				// byte). Escape it as the Unicode replacement character so the output
				// is always well-formed rather than containing raw invalid bytes.
				ch = 0xFFFD; // PORT: Go utf8.RuneError for the byte 0xFE (U+FFFE here)
				escape = true;
			}

			// This consists of the first 19 unprintable ASCII characters, canonical escapes, lineSeparator,
			// paragraphSeparator, and nextLine. The latter three are just desirable to suppress new lines in
			// the language service. These characters should be escaped when printing, and if any characters are added,
			// `escapedCharsMap` and/or `jsxEscapedCharsMap` must be updated. Note that this *does not* include the 'delete'
			// character. There is no reason for this other than that JSON.stringify does not handle it either.
			// PORT: Go switch with the non-constant case `rune(quoteChar)` → if/else chain in Go case order.
			if (ch == "\\".code) {
				if (flags & getLiteralTextFlagsJsxAttributeEscape == 0) {
					escape = true;
				}
			} else if (ch == "$".code) {
				if (quoteChar == QuoteCharBacktick && i + 1 < s.length && StringTools.fastCodeAt(s, i + 1) == "{".code) {
					escape = true;
				}
			} else if (ch == (quoteChar : Int) || ch == 0x2028 || ch == 0x2029 || ch == 0x0085 || ch == "\r".code) {
				escape = true;
			} else if (ch == "\n".code) {
				if (quoteChar != QuoteCharBacktick) {
					// Template strings preserve simple LF newlines, still encode CRLF (or CR).
					escape = true;
				}
			} else {
				if (ch <= 0x1f || flags & getLiteralTextFlagsNeverAsciiEscape == 0 && ch > 0x7f) {
					escape = true;
				}
			}

			if (escape) {
				if (pos < i) {
					// Write string up to this point
					b.add(s.substring(pos, i));
				}

				if (flags & getLiteralTextFlagsJsxAttributeEscape != 0) {
					if (ch == 0) {
						b.add("&#0;");
					} else {
						final match = jsxEscapedCharsMap(ch);
						if (match != null) {
							b.add(match);
						} else {
							encodeJsxCharacterEntity(b, ch);
						}
					}
				} else {
					if (ch == "\r".code && quoteChar == QuoteCharBacktick && i + 1 < s.length && StringTools.fastCodeAt(s, i + 1) == "\n".code) {
						// Template strings preserve simple LF newlines, but still must escape CRLF. Left alone, the
						// above cases for `\r` and `\n` would inadvertently escape CRLF as two independent characters.
						size++;
						b.add("\\r\\n");
					} else if (ch > 0xffff) {
						// encode as surrogate pair
						ch -= 0x10000;
						encodeUtf16EscapeSequence(b, ((ch & 0xFFC00) >> 10) + 0xD800);
						encodeUtf16EscapeSequence(b, (ch & 0x3FF) + 0xDC00);
					} else if (ch >= 0xD800 && ch <= 0xDFFF) {
						encodeUtf16EscapeSequence(b, ch);
					} else if (ch == 0) {
						if (i + 1 < s.length && Stringutil.IsDigit(StringTools.fastCodeAt(s, i + 1))) {
							// If the null character is followed by digits, print as a hex escape to prevent the result from
							// parsing as an octal (which is forbidden in strict mode)
							b.add("\\x00");
						} else {
							// Otherwise, keep printing a literal \0 for the null character
							b.add("\\0");
						}
					} else {
						final match = escapedCharsMap(ch);
						if (match != null) {
							b.add(match);
						} else {
							encodeUtf16EscapeSequence(b, ch);
						}
					}
				}
				pos = i + size;
			}

			i += size;
		}

		if (pos < i) {
			b.add(s.substring(pos));
		}
	}

	public static function EscapeString(s:std.String, quoteChar:QuoteChar):std.String {
		final b = new StringBuf();
		escapeStringWorker(s, quoteChar, getLiteralTextFlagsNeverAsciiEscape, b);
		return b.toString();
	}

	static function escapeNonAsciiString(s:std.String, quoteChar:QuoteChar):std.String {
		final b = new StringBuf();
		escapeStringWorker(s, quoteChar, getLiteralTextFlagsNone, b);
		return b.toString();
	}

	static function escapeJsxAttributeString(s:std.String, quoteChar:QuoteChar):std.String {
		final b = new StringBuf();
		escapeStringWorker(s, quoteChar, getLiteralTextFlagsJsxAttributeEscape | getLiteralTextFlagsNeverAsciiEscape, b);
		return b.toString();
	}

	static function canUseOriginalText(node:LiteralLikeNode, flags:GetLiteralTextFlags):Bool {
		// A synthetic node has no original text, nor does a node without a parent as we would be unable to find the
		// containing SourceFile. We also cannot use the original text if the literal was unterminated and the caller has
		// requested proper termination of unterminated literals
		if (Ast.NodeIsSynthesized(node)
			|| node.Parent == null
			|| flags & getLiteralTextFlagsTerminateUnterminatedLiterals != 0 && Ast.IsUnterminatedLiteral(node)) {
			return false;
		}

		if (node.Kind == KindNumericLiteral) {
			final tokenFlags = node.AsNumericLiteral().TokenFlags;
			// For a numeric literal, we cannot use the original text if the original text was an invalid literal
			if (tokenFlags & TokenFlagsIsInvalid != 0) {
				return false;
			}
			// We also cannot use the original text if the literal contains numeric separators, but numeric separators
			// are not permitted
			if (tokenFlags & TokenFlagsContainsSeparator != 0) {
				return flags & getLiteralTextFlagsAllowNumericSeparator != 0;
			}
		}

		// Finally, we do not use the original text of a BigInt literal
		// TODO(rbuckton): The reason as to why we do not use the original text for bigints is not mentioned in the
		// original compiler source. It could be that this is no longer necessary, in which case bigint literals should
		// use the same code path as numeric literals, above
		return node.Kind != KindBigIntLiteral;
	}

	static function getLiteralText(node:LiteralLikeNode, sourceFile:SourceFile, flags:GetLiteralTextFlags):std.String {
		// If we don't need to downlevel and we can reach the original source text using
		// the node's parent reference, then simply get the text as it was originally written.
		if (sourceFile != null && canUseOriginalText(node, flags)) {
			return Scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node, false /*includeTrivia*/);
		}

		// If we can't reach the original source text, use the canonical form if it's a number,
		// or a (possibly escaped) quoted form of the original text if it's string-like.
		switch (node.Kind) {
			case KindStringLiteral:
				final b = new StringBuf();
				var quoteChar:QuoteChar;
				if (node.AsStringLiteral().TokenFlags & TokenFlagsSingleQuote != 0) {
					quoteChar = QuoteCharSingleQuote;
				} else {
					quoteChar = QuoteCharDoubleQuote;
				}

				final text = node.Text();

				// Write leading quote character
				b.addChar(quoteChar);

				// Write text
				escapeStringWorker(text, quoteChar, flags, b);

				// Write trailing quote character
				b.addChar(quoteChar);
				return b.toString();

			case KindNoSubstitutionTemplateLiteral | KindTemplateHead | KindTemplateMiddle | KindTemplateTail:
				// If a NoSubstitutionTemplateLiteral appears to have a substitution in it, the original text
				// had to include a backslash: `not \${a} substitution`.
				final b = new StringBuf();
				final text = node.Text();
				final rawText = node.TemplateLiteralLikeData().RawText;

				// Write leading quote character
				switch (node.Kind) {
					case KindNoSubstitutionTemplateLiteral:
						b.addChar("`".code);
					case KindTemplateHead:
						b.addChar("`".code);
					case KindTemplateMiddle:
						b.addChar("}".code);
					case KindTemplateTail:
						b.addChar("}".code);
					default:
				}

				// Write text
				if (rawText.length > 0 || text.length == 0) {
					// If rawText is set, it is expected to be valid.
					b.add(rawText);
				} else {
					escapeStringWorker(text, QuoteCharBacktick, flags, b);
				}

				// Write trailing quote character
				switch (node.Kind) {
					case KindNoSubstitutionTemplateLiteral:
						b.addChar("`".code);
					case KindTemplateHead:
						b.add("${");
					case KindTemplateMiddle:
						b.add("${");
					case KindTemplateTail:
						b.addChar("`".code);
					default:
				}
				return b.toString();

			case KindNumericLiteral | KindBigIntLiteral:
				return node.Text();

			case KindRegularExpressionLiteral:
				if (flags & getLiteralTextFlagsTerminateUnterminatedLiterals != 0 && Ast.IsUnterminatedLiteral(node)) {
					final text = node.Text();
					if (text.length > 0 && StringTools.fastCodeAt(text, text.length - 1) == "\\".code) {
						return text + " /";
					} else {
						return text + "/";
					}
				}
				return node.Text();

			default:
				throw "Unsupported LiteralLikeNode";
		}
	}

	static function isNotPrologueDirective(node:Node):Bool {
		return !Ast.IsPrologueDirective(node);
	}

	public static function RangeIsOnSingleLine(r:TextRange, sourceFile:SourceFile):Bool {
		return rangeStartIsOnSameLineAsRangeEnd(r, r, sourceFile);
	}

	public static function RangeStartPositionsAreOnSameLine(range1:TextRange, range2:TextRange, sourceFile:SourceFile):Bool {
		return PositionsAreOnSameLine(getStartPositionOfRange(range1, sourceFile, false /*includeComments*/),
			getStartPositionOfRange(range2, sourceFile, false /*includeComments*/), sourceFile);
	}

	static function rangeEndPositionsAreOnSameLine(range1:TextRange, range2:TextRange, sourceFile:SourceFile):Bool {
		return PositionsAreOnSameLine(range1.End(), range2.End(), sourceFile);
	}

	static function rangeStartIsOnSameLineAsRangeEnd(range1:TextRange, range2:TextRange, sourceFile:SourceFile):Bool {
		return PositionsAreOnSameLine(getStartPositionOfRange(range1, sourceFile, false /*includeComments*/), range2.End(), sourceFile);
	}

	static function rangeEndIsOnSameLineAsRangeStart(range1:TextRange, range2:TextRange, sourceFile:SourceFile):Bool {
		return PositionsAreOnSameLine(range1.End(), getStartPositionOfRange(range2, sourceFile, false /*includeComments*/), sourceFile);
	}

	// PORT: Go allocates `&scanner.SkipTriviaOptions{StopAtComments: includeComments}` per call; here
	// two shared immutable option objects.
	static var skipTriviaStopAtComments:SkipTriviaOptions = null;
	static var skipTriviaNoStop:SkipTriviaOptions = null;

	static function skipTriviaOptions(stopAtComments:Bool):SkipTriviaOptions {
		if (skipTriviaStopAtComments == null) {
			// (both complete before the one tested is set: another thread may be here too)
			final stop = new SkipTriviaOptions();
			stop.StopAtComments = true;
			final noStop = new SkipTriviaOptions();
			noStop.StopAtComments = false;
			skipTriviaNoStop = noStop;
			skipTriviaStopAtComments = stop;
		}
		return stopAtComments ? skipTriviaStopAtComments : skipTriviaNoStop;
	}

	static function getStartPositionOfRange(r:TextRange, sourceFile:SourceFile, includeComments:Bool):Int {
		if (Ast.PositionIsSynthesized(r.Pos())) {
			return -1;
		}
		return Scanner.SkipTriviaEx(sourceFile.Text(), r.Pos(), skipTriviaOptions(includeComments));
	}

	public static function PositionsAreOnSameLine(pos1:Int, pos2:Int, sourceFile:SourceFile):Bool {
		return GetLinesBetweenPositions(sourceFile, pos1, pos2) == 0;
	}

	public static function GetLinesBetweenPositions(sourceFile:SourceFile, pos1:Int, pos2:Int):Int {
		if (pos1 == pos2) {
			return 0;
		}
		final lineStarts = Scanner.GetECMALineStarts(sourceFile);
		final lower = Core.IfElse(pos1 < pos2, pos1, pos2);
		final isNegative = lower == pos2;
		final upper = Core.IfElse(isNegative, pos1, pos2);
		final lowerLine = Scanner.ComputeLineOfPosition(lineStarts, lower);
		final upperLine = lowerLine + computeLineOfPositionFrom(lineStarts, lowerLine, upper);
		if (isNegative) {
			return lowerLine - upperLine;
		} else {
			return upperLine - lowerLine;
		}
	}

	// PORT: Go `scanner.ComputeLineOfPosition(lineStarts[from:], pos)` without the slice copy (same
	// binary search over the sub-slice; the result is relative to `from`).
	static function computeLineOfPositionFrom(lineStarts:Array<TextPos>, from:Int, pos:Int):Int {
		var low = 0;
		var high = lineStarts.length - from - 1;
		while (low <= high) {
			final middle = low + ((high - low) >> 1);
			final value:Int = lineStarts[from + middle];
			if (value < pos) {
				low = middle + 1;
			} else if (value > pos) {
				high = middle - 1;
			} else {
				return middle;
			}
		}
		return low - 1;
	}

	static function getLinesBetweenRangeEndAndRangeStart(range1:TextRange, range2:TextRange, sourceFile:SourceFile, includeSecondRangeComments:Bool):Int {
		final range2Start = getStartPositionOfRange(range2, sourceFile, includeSecondRangeComments);
		return GetLinesBetweenPositions(sourceFile, range1.End(), range2Start);
	}

	static function getLinesBetweenPositionAndPrecedingNonWhitespaceCharacter(pos:Int, stopPos:Int, sourceFile:SourceFile, includeComments:Bool):Int {
		final startPos = Scanner.SkipTriviaEx(sourceFile.Text(), pos, skipTriviaOptions(includeComments));
		final prevPos = getPreviousNonWhitespacePosition(startPos, stopPos, sourceFile);
		return GetLinesBetweenPositions(sourceFile, Core.IfElse(prevPos >= 0, prevPos, stopPos), startPos);
	}

	static function getLinesBetweenPositionAndNextNonWhitespaceCharacter(pos:Int, stopPos:Int, sourceFile:SourceFile, includeComments:Bool):Int {
		final nextPos = Scanner.SkipTriviaEx(sourceFile.Text(), pos, skipTriviaOptions(includeComments));
		return GetLinesBetweenPositions(sourceFile, pos, Core.IfElse(stopPos < nextPos, stopPos, nextPos));
	}

	static function getPreviousNonWhitespacePosition(pos:Int, stopPos:Int, sourceFile:SourceFile):Int {
		while (pos >= stopPos) {
			// PORT: byte — Go reads one byte; here one UTF-16 code unit.
			if (!Stringutil.IsWhiteSpaceLike(StringTools.fastCodeAt(sourceFile.Text(), pos))) {
				return pos;
			}
			pos--;
		}
		return -1;
	}

	static function siblingNodePositionsAreComparable(emitContext:EmitContext, previousNode:Node, nextNode:Node):Bool {
		if (nextNode.Pos() < previousNode.End()) {
			return false;
		}

		previousNode = emitContext.MostOriginal(previousNode);
		nextNode = emitContext.MostOriginal(nextNode);
		final parent = previousNode.Parent;
		if (parent == null || parent != nextNode.Parent) {
			return false;
		}

		final parentNodeArray = getContainingNodeArray(previousNode);
		if (parentNodeArray != null) {
			final prevNodeIndex = Slices.Index(parentNodeArray.Nodes, previousNode);
			return prevNodeIndex >= 0 && Slices.Index(parentNodeArray.Nodes, nextNode) == prevNodeIndex + 1;
		}

		return false;
	}

	static function getContainingNodeArray(node:Node):NodeList {
		final parent = node.Parent;
		if (parent == null) {
			return null;
		}

		switch (node.Kind) {
			case KindTypeParameter:
				if (Ast.IsFunctionLike(parent) || Ast.IsClassLike(parent) || Ast.IsInterfaceDeclaration(parent) || Ast.IsTypeOrJSTypeAliasDeclaration(parent)) {
					return parent.TypeParameterList();
				} else if (Ast.IsInferTypeNode(parent)) {
					// break
				} else {
					throw 'Unexpected TypeParameter parent: ${parent.Kind.String()}';
				}

			case KindParameter:
				return node.Parent.FunctionLikeData().Parameters;
			case KindTemplateLiteralTypeSpan:
				return node.Parent.AsTemplateLiteralTypeNode().TemplateSpans;
			case KindTemplateSpan:
				return node.Parent.AsTemplateExpression().TemplateSpans;
			case KindDecorator:
				if (canHaveDecorators(node.Parent)) {
					final modifiers = node.Parent.Modifiers();
					if (modifiers != null) {
						return modifiers;
					}
				}
				return null;
			case KindHeritageClause:
				if (Ast.IsClassLike(node.Parent)) {
					return node.Parent.ClassLikeData().HeritageClauses;
				} else {
					return node.Parent.AsInterfaceDeclaration().HeritageClauses;
				}
			default:
		}

		// TODO(rbuckton)
		// if ast.IsJSDocTag(node) {
		//     if ast.IsJSDocTypeLiteral(node.parent) {
		// 		return nil
		// 	 }
		// 	 return node.parent.tags
		// }

		switch (parent.Kind) {
			case KindTypeLiteral | KindInterfaceDeclaration:
				if (Ast.IsTypeElement(node)) {
					return parent.MemberList();
				}
			case KindUnionType:
				return parent.AsUnionTypeNode().Types;
			case KindIntersectionType:
				return parent.AsIntersectionTypeNode().Types;
			case KindArrayLiteralExpression | KindTupleType | KindNamedImports | KindNamedExports:
				return parent.ElementList();
			case KindObjectLiteralExpression | KindJsxAttributes:
				return parent.PropertyList();
			case KindCallExpression:
				final p = parent.AsCallExpression();
				if (Ast.IsTypeNode(node)) {
					return p.TypeArguments;
				} else if (node != p.Expression) {
					return p.Arguments;
				}
			case KindNewExpression:
				final p = parent.AsNewExpression();
				if (Ast.IsTypeNode(node)) {
					return p.TypeArguments;
				} else if (node != p.Expression) {
					return p.Arguments;
				}
			case KindJsxElement | KindJsxFragment:
				if (Ast.IsJsxChild(node)) {
					return parent.Children();
				}
			case KindJsxOpeningElement | KindJsxSelfClosingElement:
				if (Ast.IsTypeNode(node)) {
					return parent.TypeArgumentList();
				}
			case KindBlock | KindModuleBlock | KindCaseClause | KindDefaultClause:
				return parent.StatementList();
			case KindCaseBlock:
				return parent.AsCaseBlock().Clauses;
			case KindClassDeclaration | KindClassExpression:
				if (Ast.IsClassElement(node)) {
					return parent.MemberList();
				}
			case KindEnumDeclaration:
				if (Ast.IsEnumMember(node)) {
					return parent.MemberList();
				}
			case KindSourceFile:
				if (Ast.IsStatement(node)) {
					return parent.StatementList();
				}
			default:
		}

		if (Ast.IsModifier(node)) {
			final modifiers = parent.Modifiers();
			if (modifiers != null) {
				return modifiers;
			}
		}

		return null;
	}

	static function canHaveDecorators(node:Node):Bool {
		switch (node.Kind) {
			case KindParameter | KindPropertyDeclaration | KindMethodDeclaration | KindGetAccessor | KindSetAccessor | KindClassExpression |
				KindClassDeclaration:
				return true;
			default:
		}
		return false;
	}

	static function originalNodesHaveSameParent(emitContext:EmitContext, nodeA:Node, nodeB:Node):Bool {
		nodeA = emitContext.MostOriginal(nodeA);
		if (nodeA.Parent != null) {
			// For performance, do not call `MostOriginal` for `nodeB` if `nodeA` doesn't even
			// have a parent node.
			nodeB = emitContext.MostOriginal(nodeB);
			return nodeA.Parent == nodeB.Parent;
		}
		return false;
	}

	// PORT: Go `tryGetEnd(node interface{ End() int }) (int, bool)` + variadic `greatestEnd`: the
	// argument types (*ast.Node, *ast.NodeList, *ast.ModifierList, core.TextRange) convert to EndOf
	// (see below), which holds End() or a sentinel below every position for a nil value.
	static function greatestEnd(end:Int, ...nodes:EndOf):Int {
		var i = nodes.length - 1;
		while (i >= 0) {
			final nodeEnd:Int = nodes[i];
			if (nodeEnd != EndOf.NIL && end < nodeEnd) {
				end = nodeEnd;
			}
			i--;
		}
		return end;
	}

	static function skipSynthesizedParentheses(node:Node):Node {
		while (node.Kind == KindParenthesizedExpression && Ast.NodeIsSynthesized(node)) {
			node = node.Expression();
		}
		return node;
	}

	static function isNewExpressionWithoutArguments(node:Node):Bool {
		return node.Kind == KindNewExpression && node.ArgumentList() == null;
	}

	static function isBinaryOperation(node:Node, token:Kind):Bool {
		node = Ast.SkipPartiallyEmittedExpressions(node);
		return node.Kind == KindBinaryExpression && node.AsBinaryExpression().OperatorToken.Kind == token;
	}

	static function mixingBinaryOperatorsRequiresParentheses(a:Kind, b:Kind):Bool {
		if (a == KindQuestionQuestionToken) {
			return b == KindAmpersandAmpersandToken || b == KindBarBarToken;
		}
		if (b == KindQuestionQuestionToken) {
			return a == KindAmpersandAmpersandToken || a == KindBarBarToken;
		}
		return false;
	}

	static function isImmediatelyInvokedFunctionExpressionOrArrowFunction(node:Expression):Bool {
		node = Ast.SkipPartiallyEmittedExpressions(node);
		if (!Ast.IsCallExpression(node)) {
			return false;
		}
		node = Ast.SkipPartiallyEmittedExpressions(node.Expression());
		return Ast.IsFunctionExpression(node) || Ast.IsArrowFunction(node);
	}

	public static function IsFileLevelUniqueName(sourceFile:SourceFile, name:std.String, hasGlobalName:(std.String) -> Bool):Bool {
		if (hasGlobalName != null && hasGlobalName(name)) {
			return false;
		}
		return sourceFile.Identifiers == null || !sourceFile.Identifiers.exists(name);
	}

	static function hasLeadingHash(text:std.String):Bool {
		return text.length > 0 && StringTools.fastCodeAt(text, 0) == "#".code;
	}

	static function removeLeadingHash(text:std.String):std.String {
		if (hasLeadingHash(text)) {
			return text.substring(1);
		} else {
			return text;
		}
	}

	static function ensureLeadingHash(text:std.String):std.String {
		if (hasLeadingHash(text)) {
			return text;
		} else {
			return "#" + text;
		}
	}

	public static function FormatGeneratedName(privateName:Bool, prefix:std.String, base:std.String, suffix:std.String):std.String {
		final name = removeLeadingHash(prefix) + removeLeadingHash(base) + removeLeadingHash(suffix);
		if (privateName) {
			return ensureLeadingHash(name);
		}
		return name;
	}

	static function isASCIIWordCharacter(ch:Int):Bool {
		return Stringutil.IsASCIILetter(ch) || Stringutil.IsDigit(ch) || ch == "_".code;
	}

	// PORT: byte — Go iterates the UTF-8 bytes of moduleName and writes one '_' per non-word byte;
	// here a non-ASCII code point writes one '_' per byte of its UTF-8 encoding (same result).
	static function makeIdentifierFromModuleName(moduleName:std.String):std.String {
		moduleName = Tspath.GetBaseFileName(moduleName);
		final builder = new StringBuf();
		var start = 0;
		var pos = 0;
		while (pos < moduleName.length) {
			final ch = StringTools.fastCodeAt(moduleName, pos);
			if (pos == 0 && Stringutil.IsDigit(ch)) {
				builder.addChar("_".code);
			} else if (!isASCIIWordCharacter(ch)) {
				if (start < pos) {
					builder.add(moduleName.substring(start, pos));
				}
				final r = Utf16.CodePointAt(moduleName, pos);
				final units = Utf16.RuneLen(r);
				final bytes = r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;
				for (_ in 0...bytes) {
					builder.addChar("_".code);
				}
				pos += units - 1;
				start = pos + 1;
			}
			pos++;
		}
		if (start < pos) {
			builder.add(moduleName.substring(start, pos));
		}
		return builder.toString();
	}

	static function findSpanEndWithEmitContext<T>(c:EmitContext, array:Array<T>, test:(c:EmitContext, value:T) -> Bool, start:Int):Int {
		var i = start;
		while (i < Core.len(array) && test(c, array[i])) {
			i++;
		}
		return i;
	}

	static function findSpanEnd<T>(array:Array<T>, test:(value:T) -> Bool, start:Int):Int {
		var i = start;
		while (i < Core.len(array) && test(array[i])) {
			i++;
		}
		return i;
	}

	// PORT: pointer — Go `pos *int` → IntRef holder.
	static function skipWhiteSpaceSingleLine(text:std.String, pos:IntRef):Void {
		while (pos.v < text.length) {
			final ch = Utf16.DecodeRuneInString(text, pos.v);
			if (!Stringutil.IsWhiteSpaceSingleLine(ch)) {
				break;
			}
			pos.v += Utf16.RuneLen(ch);
		}
	}

	static function matchWhiteSpaceSingleLine(text:std.String, pos:IntRef):Bool {
		final startPos = pos.v;
		skipWhiteSpaceSingleLine(text, pos);
		return pos.v != startPos;
	}

	static function matchRune(text:std.String, pos:IntRef, expected:Int):Bool {
		final ch = Utf16.DecodeRuneInString(text, pos.v);
		if (ch == expected) {
			pos.v += Utf16.RuneLen(ch);
			return true;
		}
		return false;
	}

	static function matchString(text:std.String, pos:IntRef, expected:std.String):Bool {
		final textPos = new IntRef(pos.v);
		var expectedPos = 0;
		while (expectedPos < expected.length) {
			if (textPos.v >= text.length) {
				return false;
			}

			final expectedRune = Utf16.DecodeRuneInString(expected, expectedPos);
			if (!matchRune(text, textPos, expectedRune)) {
				return false;
			}

			expectedPos += Utf16.RuneLen(expectedRune);
		}

		pos.v = textPos.v;
		return true;
	}

	static function matchQuotedString(text:std.String, pos:IntRef):Bool {
		final textPos = new IntRef(pos.v);
		var quoteChar:Int;
		if (matchRune(text, textPos, "'".code)) {
			quoteChar = "'".code;
		} else if (matchRune(text, textPos, '"'.code)) {
			quoteChar = '"'.code;
		} else {
			return false;
		}
		while (textPos.v < text.length) {
			final ch = Utf16.DecodeRuneInString(text, textPos.v);
			textPos.v += Utf16.RuneLen(ch);
			if (ch == quoteChar) {
				pos.v = textPos.v;
				return true;
			}
		}
		return false;
	}

	// /// <reference path="..." />
	// /// <reference types="..." />
	// /// <reference lib="..." />
	// /// <reference no-default-lib="..." />
	// /// <amd-dependency path="..." />
	// /// <amd-module />
	public static function IsRecognizedTripleSlashComment(text:std.String, commentRange:CommentRange):Bool {
		if (commentRange.Kind == KindSingleLineCommentTrivia
			&& commentRange.TextRange.Len() > 2
			&& StringTools.fastCodeAt(text, commentRange.Pos() + 1) == "/".code
			&& StringTools.fastCodeAt(text, commentRange.Pos() + 2) == "/".code) {
			text = text.substring(commentRange.Pos() + 3, commentRange.End());
			final pos = new IntRef(0);
			skipWhiteSpaceSingleLine(text, pos);
			if (!matchRune(text, pos, "<".code)) {
				return false;
			}
			if (matchString(text, pos, "reference")) {
				if (!matchWhiteSpaceSingleLine(text, pos)) {
					return false;
				}
				if (!matchString(text, pos, "path") && !matchString(text, pos, "types") && !matchString(text, pos, "lib")
					&& !matchString(text, pos, "no-default-lib")) {
					return false;
				}
				skipWhiteSpaceSingleLine(text, pos);
				if (!matchRune(text, pos, "=".code)) {
					return false;
				}
				skipWhiteSpaceSingleLine(text, pos);
				if (!matchQuotedString(text, pos)) {
					return false;
				}
			} else if (matchString(text, pos, "amd-dependency")) {
				if (!matchWhiteSpaceSingleLine(text, pos)) {
					return false;
				}
				if (!matchString(text, pos, "path")) {
					return false;
				}
				skipWhiteSpaceSingleLine(text, pos);
				if (!matchRune(text, pos, "=".code)) {
					return false;
				}
				skipWhiteSpaceSingleLine(text, pos);
				if (!matchQuotedString(text, pos)) {
					return false;
				}
			} else if (matchString(text, pos, "amd-module")) {
				skipWhiteSpaceSingleLine(text, pos);
			} else {
				return false;
			}
			final index = text.substring(pos.v).indexOf("/>");
			return index != -1;
		}

		return false;
	}

	static function isJSDocLikeText(text:std.String, comment:CommentRange):Bool {
		return comment.Kind == KindMultiLineCommentTrivia
			&& comment.TextRange.Len() >= 5
			&& StringTools.fastCodeAt(text, comment.Pos() + 2) == "*".code
			&& StringTools.fastCodeAt(text, comment.Pos() + 3) != "/".code;
	}

	public static function IsPinnedComment(text:std.String, comment:CommentRange):Bool {
		return comment.Kind == KindMultiLineCommentTrivia && comment.TextRange.Len() > 5 && StringTools.fastCodeAt(text, comment.Pos() + 2) == "!".code;
	}

	static function calculateIndent(text:std.String, pos:Int, end:Int):Int {
		var currentLineIndent = 0;
		final indentSize = GetDefaultIndentSize();
		while (pos < end) {
			final ch = Utf16.DecodeRuneInString(text, pos);
			if (!Stringutil.IsWhiteSpaceSingleLine(ch)) {
				break;
			}
			if (ch == "\t".code) {
				// Tabs = TabSize = indent size and go to next tabStop
				currentLineIndent += indentSize - (currentLineIndent % indentSize);
			} else {
				// Single space
				currentLineIndent++;
			}
			pos += Utf16.RuneLen(ch);
		}

		return currentLineIndent;
	}

	static function newLineCharacterCache(source:Source):LineCharacterCache {
		final c = new LineCharacterCache();
		c.lineMap = source.ECMALineMap();
		c.text = source.Text();
		return c;
	}

	static function formatSynthesizedComment(comment:SynthesizedComment):std.String {
		if (comment.Kind == KindMultiLineCommentTrivia) {
			return "/*" + comment.Text + "*/";
		}
		return "//" + comment.Text;
	}
}

// --- types of printer.go ---

class PrinterOptions {
	public var RemoveComments:Bool = false;
	public var NewLine:NewLineKind = NewLineKindNone;
	// OmitTrailingSemicolon         bool
	public var NoEmitHelpers:Bool = false;
	// Module                        core.ModuleKind
	// ModuleResolution              core.ModuleResolutionKind
	public var Target:ScriptTarget = ScriptTargetNone;
	public var SourceMap:Bool = false;
	public var InlineSourceMap:Bool = false;
	public var InlineSources:Bool = false;
	public var OmitBraceSourceMapPositions:Bool = false;
	// ExtendedDiagnostics           bool
	public var OnlyPrintJSDocStyle:Bool = false;
	public var NeverAsciiEscape:Bool = false;
	// StripInternal                 bool
	public var PreserveSourceNewlines:Bool = false;
	public var TerminateUnterminatedLiterals:Bool = false; // !!!

	public function new() {}
}

class PrintHandlers {
	// A hook used by the Printer when generating unique names to avoid collisions with
	// globally defined names that exist outside of the current source file.
	public var HasGlobalName:(name:std.String) -> Bool = null;

	// !!! OnEmitNode, IsEmitNotificationEnabled, SubstituteNode, OnEmitSourceMapOf* (see printer.go)

	public var OnBeforeEmitNode:(nodeOpt:Node) -> Void = null;
	public var OnAfterEmitNode:(nodeOpt:Node) -> Void = null;
	public var OnBeforeEmitNodeList:(nodesOpt:NodeList) -> Void = null;
	public var OnAfterEmitNodeList:(nodesOpt:NodeList) -> Void = null;
	public var OnBeforeEmitToken:(nodeOpt:TokenNode) -> Void = null;
	public var OnAfterEmitToken:(nodeOpt:TokenNode) -> Void = null;

	public function new() {}
}

// PORT: unexported Go type `detachedCommentsInfo` → DetachedCommentsInfo (PORTING.md §1).
class DetachedCommentsInfo {
	public final nodePos:Int;
	public final detachedCommentEndPos:Int;

	public function new(nodePos:Int, detachedCommentEndPos:Int) {
		this.nodePos = nodePos;
		this.detachedCommentEndPos = detachedCommentEndPos;
	}
}

// PORT: unexported Go type `commentState` → CommentState (PORTING.md §1).
class CommentState {
	public final emitFlags:EmitFlags; // holds the emit flags for the current node
	public final commentRange:TextRange; // holds the comment range calculated for the current node
	public final containerPos:Int; // captures the value of containerPos prior to entering an node
	public final containerEnd:Int; // captures the value of containerEnd prior to entering an node
	public final declarationListContainerEnd:Int; // captures the value of declarationListContainerEnd prior to entering an node

	public function new(emitFlags:EmitFlags, commentRange:TextRange, containerPos:Int, containerEnd:Int, declarationListContainerEnd:Int) {
		this.emitFlags = emitFlags;
		this.commentRange = commentRange;
		this.containerPos = containerPos;
		this.containerEnd = containerEnd;
		this.declarationListContainerEnd = declarationListContainerEnd;
	}
}

// PORT: unexported Go type `sourceMapState` → SourceMapState (PORTING.md §1).
class SourceMapState {
	public final emitFlags:EmitFlags; // holds the emit flags for the current node
	public final sourceMapRange:TextRange; // holds the source map range calculated for the current node
	public final hasTokenSourceMapRange:Bool; // captures whether the source map range was set for the current node

	public function new(emitFlags:EmitFlags, sourceMapRange:TextRange, hasTokenSourceMapRange:Bool) {
		this.emitFlags = emitFlags;
		this.sourceMapRange = sourceMapRange;
		this.hasTokenSourceMapRange = hasTokenSourceMapRange;
	}
}

// PORT: unexported Go type `printerState` (a value struct) → PrinterState.
class PrinterState {
	public var commentState:CommentState = null;
	public var sourceMapState:SourceMapState = null;

	public function new() {}
}

enum abstract WriteKind(Int) from Int to Int {
	var WriteKindNone = 0;
	var WriteKindKeyword = 1;
	var WriteKindOperator = 2;
	var WriteKindPunctuation = 3;
	var WriteKindStringLiteral = 4;
	var WriteKindParameter = 5;
	var WriteKindProperty = 6;
	var WriteKindComment = 7;
	var WriteKindLiteral = 8;
}

// PORT: unexported Go type `commentSeparator` → CommentSeparator (PORTING.md §1).
enum abstract CommentSeparator(Int) from Int to Int {
	var commentSeparatorNone = 0;
	var commentSeparatorBefore = 1;
	var commentSeparatorAfter = 2;
}

// PORT: unexported Go type `tokenEmitFlags` → TokenEmitFlags (PORTING.md §1).
enum abstract TokenEmitFlags(Int) from Int to Int {
	@:op(A | B) static function or(a:TokenEmitFlags, b:TokenEmitFlags):TokenEmitFlags;
	@:op(A & B) static function and(a:TokenEmitFlags, b:TokenEmitFlags):TokenEmitFlags;

	var tefNoComments = 1 << 0;
	var tefIndentLeadingComments = 1 << 1;
	var tefNoSourceMaps = 1 << 2;

	var tefNone = 0;
}

enum abstract ListFormat(Int) from Int to Int {
	@:op(A | B) static function or(a:ListFormat, b:ListFormat):ListFormat;
	@:op(A & B) static function and(a:ListFormat, b:ListFormat):ListFormat;
	@:op(~A) static function not(a:ListFormat):ListFormat;

	var LFNone = 0;

	// Line separators
	var LFSingleLine = 0; // Prints the list on a single line (default).
	var LFMultiLine = 1 << 0; // Prints the list on multiple lines.
	var LFPreserveLines = 1 << 1; // Prints the list using line preservation if possible.
	var LFLinesMask = LFSingleLine | LFMultiLine | LFPreserveLines;

	// Delimiters
	var LFNotDelimited = 0; // There is no delimiter between list items (default).
	var LFBarDelimited = 1 << 2; // Each list item is space-and-bar (" |") delimited.
	var LFAmpersandDelimited = 1 << 3; // Each list item is space-and-ampersand (" &") delimited.
	var LFCommaDelimited = 1 << 4; // Each list item is comma (",") delimited.
	var LFAsteriskDelimited = 1 << 5; // Each list item is asterisk ("\n *") delimited, used with JSDoc.
	var LFDelimitersMask = LFBarDelimited | LFAmpersandDelimited | LFCommaDelimited | LFAsteriskDelimited;

	var LFAllowTrailingComma = 1 << 6; // Write a trailing comma (",") if present.

	// Whitespace
	var LFIndented = 1 << 7; // The list should be indented.
	var LFSpaceBetweenBraces = 1 << 8; // Inserts a space after the opening brace and before the closing brace.
	var LFSpaceBetweenSiblings = 1 << 9; // Inserts a space between each sibling node.

	// Brackets/Braces
	var LFBraces = 1 << 10; // The list is surrounded by "{" and "}".
	var LFParenthesis = 1 << 11; // The list is surrounded by "(" and ")".
	var LFAngleBrackets = 1 << 12; // The list is surrounded by "<" and ">".
	var LFSquareBrackets = 1 << 13; // The list is surrounded by "[" and "]".
	var LFBracketsMask = LFBraces | LFParenthesis | LFAngleBrackets | LFSquareBrackets;

	var LFOptionalIfNil = 1 << 14; // Do not emit brackets if the list is nil.
	var LFOptionalIfEmpty = 1 << 15; // Do not emit brackets if the list is empty.
	var LFOptional = LFOptionalIfNil | LFOptionalIfEmpty;

	// Other
	var LFPreferNewLine = 1 << 16; // Prefer adding a LineTerminator between synthesized nodes.
	var LFNoTrailingNewLine = 1 << 17; // Do not emit a trailing NewLine for a MultiLine list.
	var LFNoInterveningComments = 1 << 18; // Do not emit comments between each node
	var LFNoSpaceIfEmpty = 1 << 19; // If the literal is empty, do not add spaces between braces.
	var LFSingleElement = 1 << 20;
	var LFSpaceAfterList = 1 << 21; // Add space after list

	// Precomputed Formats
	var LFModifiers = LFSingleLine | LFSpaceBetweenSiblings | LFNoInterveningComments | LFSpaceAfterList;
	var LFHeritageClauses = LFSingleLine | LFSpaceBetweenSiblings;
	var LFSingleLineTypeLiteralMembers = LFSingleLine | LFSpaceBetweenBraces | LFSpaceBetweenSiblings;
	var LFMultiLineTypeLiteralMembers = LFMultiLine | LFIndented | LFOptionalIfEmpty;

	var LFSingleLineTupleTypeElements = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFMultiLineTupleTypeElements = LFCommaDelimited | LFIndented | LFSpaceBetweenSiblings | LFMultiLine;
	var LFUnionTypeConstituents = LFBarDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFIntersectionTypeConstituents = LFAmpersandDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFObjectBindingPatternElements = LFSingleLine | LFAllowTrailingComma | LFSpaceBetweenBraces | LFCommaDelimited | LFSpaceBetweenSiblings | LFNoSpaceIfEmpty;
	var LFArrayBindingPatternElements = LFSingleLine | LFAllowTrailingComma | LFCommaDelimited | LFSpaceBetweenSiblings | LFNoSpaceIfEmpty;
	var LFObjectLiteralExpressionProperties = LFPreserveLines | LFCommaDelimited | LFSpaceBetweenSiblings | LFSpaceBetweenBraces | LFIndented | LFBraces | LFNoSpaceIfEmpty;
	var LFImportAttributes = LFPreserveLines | LFCommaDelimited | LFSpaceBetweenSiblings | LFSpaceBetweenBraces | LFIndented | LFBraces | LFNoSpaceIfEmpty;
	var LFArrayLiteralExpressionElements = LFPreserveLines | LFCommaDelimited | LFSpaceBetweenSiblings | LFAllowTrailingComma | LFIndented | LFSquareBrackets;
	var LFCommaListElements = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFCallExpressionArguments = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFParenthesis;
	var LFNewExpressionArguments = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFParenthesis | LFOptionalIfNil;
	var LFTemplateExpressionSpans = LFSingleLine | LFNoInterveningComments;
	var LFSingleLineBlockStatements = LFSpaceBetweenBraces | LFSpaceBetweenSiblings | LFSingleLine;
	var LFMultiLineBlockStatements = LFIndented | LFMultiLine;
	var LFVariableDeclarationList = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFSingleLineFunctionBodyStatements = LFSingleLine | LFSpaceBetweenSiblings | LFSpaceBetweenBraces;
	var LFMultiLineFunctionBodyStatements = LFMultiLine;
	var LFClassHeritageClauses = LFSingleLine;
	var LFClassMembers = LFIndented | LFMultiLine;
	var LFInterfaceMembers = LFIndented | LFMultiLine;
	var LFEnumMembers = LFCommaDelimited | LFIndented | LFMultiLine;
	var LFCaseBlockClauses = LFIndented | LFMultiLine;
	var LFNamedImportsOrExportsElements = LFCommaDelimited | LFSpaceBetweenSiblings | LFAllowTrailingComma | LFSingleLine | LFSpaceBetweenBraces | LFNoSpaceIfEmpty;
	var LFJsxElementOrFragmentChildren = LFSingleLine | LFNoInterveningComments;
	var LFJsxElementAttributes = LFSingleLine | LFSpaceBetweenSiblings | LFNoInterveningComments;
	var LFCaseOrDefaultClauseStatements = LFIndented | LFMultiLine | LFNoTrailingNewLine | LFOptionalIfEmpty;
	var LFHeritageClauseTypes = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFSourceFileStatements = LFMultiLine | LFNoTrailingNewLine;
	var LFDecorators = LFMultiLine | LFOptional | LFSpaceAfterList;
	var LFTypeArguments = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFAngleBrackets | LFOptional;
	var LFTypeParameters = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFAngleBrackets | LFOptional;
	var LFParameters = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFParenthesis;
	var LFSingleArrowParameter = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine;
	var LFIndexSignatureParameters = LFCommaDelimited | LFSpaceBetweenSiblings | LFSingleLine | LFIndented | LFSquareBrackets;
	var LFJSDocComment = LFMultiLine | LFAsteriskDelimited;
	var LFImportClauseEntries = LFImportAttributes; // Deprecated: Use LFImportAttributes
}

// --- port helpers (not in Go) ---

// PORT: the End() of a greatestEnd argument (see Printer.greatestEnd); NIL for a nil node/list.
abstract EndOf(Int) to Int {
	public static inline final NIL:Int = -2147483648;

	inline function new(v:Int) {
		this = v;
	}

	@:from static inline function fromNode(n:Node):EndOf {
		return new EndOf(n == null ? NIL : n.End());
	}

	@:from static inline function fromNodeList(l:NodeList):EndOf {
		return new EndOf(l == null ? NIL : l.End());
	}

	@:from static inline function fromTextRange(r:TextRange):EndOf {
		return new EndOf(r.End());
	}
}

// PORT: pointer — Go `*int` (utilities.go match* helpers).
class IntRef {
	public var v:Int;

	public function new(v:Int) {
		this.v = v;
	}
}

// PORT: *ast.SourceFile satisfies sourcemap.Source structurally in Go; adapter (PORTING.md §3).
class SourceFileSource implements Source {
	final file:SourceFile;

	public function new(file:SourceFile) {
		this.file = file;
	}

	public function Text():std.String {
		return file.Text();
	}

	public function FileName():std.String {
		return file.FileName();
	}

	public function ECMALineMap():Array<TextPos> {
		return file.ECMALineMap();
	}
}
