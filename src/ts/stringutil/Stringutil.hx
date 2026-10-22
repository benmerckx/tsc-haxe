package ts.stringutil;

// Go `type Comparison = int`
typedef Comparison = Int;

// Port of internal/stringutil.
// Package stringutil Exports common rune utilities for parsing and emitting javascript
class Stringutil {
	// --- compare.go ---

	public static function EquateStringCaseInsensitive(a:String, b:String):Bool {
		// !!!
		// return a == b || strings.ToUpper(a) == strings.ToUpper(b)
		return Strings.EqualFold(a, b);
	}

	public static function EquateStringCaseSensitive(a:String, b:String):Bool {
		return a == b;
	}

	public static function GetStringEqualityComparer(ignoreCase:Bool):(a:String, b:String) -> Bool {
		if (ignoreCase) {
			return EquateStringCaseInsensitive;
		}
		return EquateStringCaseSensitive;
	}

	public static inline final ComparisonLessThan:Comparison = -1;
	public static inline final ComparisonEqual:Comparison = 0;
	public static inline final ComparisonGreaterThan:Comparison = 1;

	public static function CompareStringsCaseInsensitive(a:String, b:String):Comparison {
		if (a == b) {
			return ComparisonEqual;
		}
		// PORT: utf16 — Go slices a/b after each rune; here ia/ib are UTF-16 offsets.
		var ia = 0;
		var ib = 0;
		while (true) {
			if (ia >= a.length) {
				if (ib >= b.length) {
					return ComparisonEqual;
				}
				return ComparisonLessThan;
			}
			if (ib >= b.length) {
				return ComparisonGreaterThan;
			}
			final ca = Utf16.DecodeRuneInString(a, ia);
			final cb = Utf16.DecodeRuneInString(b, ib);
			final lca = Unicode.ToLower(ca);
			final lcb = Unicode.ToLower(cb);
			if (lca != lcb) {
				if (lca < lcb) {
					return ComparisonLessThan;
				}
				return ComparisonGreaterThan;
			}
			ia += Utf16.RuneLen(ca);
			ib += Utf16.RuneLen(cb);
		}
	}

	public static function CompareStringsCaseSensitive(a:String, b:String):Comparison {
		return Strings.Compare(a, b);
	}

	public static function GetStringComparer(ignoreCase:Bool):(a:String, b:String) -> Comparison {
		if (ignoreCase) {
			return CompareStringsCaseInsensitive;
		}
		return CompareStringsCaseSensitive;
	}

	// PORT: utf16 — lengths and the slice are UTF-16 code units, not bytes.
	public static function HasPrefix(s:String, prefix:String, caseSensitive:Bool):Bool {
		if (caseSensitive) {
			return StringTools.startsWith(s, prefix);
		}
		if (prefix.length > s.length) {
			return false;
		}
		return Strings.EqualFold(s.substring(0, prefix.length), prefix);
	}

	// PORT: utf16 — lengths and the slice are UTF-16 code units, not bytes.
	public static function HasSuffix(s:String, suffix:String, caseSensitive:Bool):Bool {
		if (caseSensitive) {
			return StringTools.endsWith(s, suffix);
		}
		if (suffix.length > s.length) {
			return false;
		}
		return Strings.EqualFold(s.substring(s.length - suffix.length), suffix);
	}

	// PORT: utf16 — lengths are UTF-16 code units, not bytes.
	public static function HasPrefixAndSuffixWithoutOverlap(s:String, prefix:String, suffix:String, caseSensitive:Bool):Bool {
		if (prefix.length + suffix.length > s.length) {
			return false;
		}

		return HasPrefix(s, prefix, caseSensitive) && HasSuffix(s, suffix, caseSensitive);
	}

	public static function CompareStringsCaseInsensitiveThenSensitive(a:String, b:String):Comparison {
		final cmp = CompareStringsCaseInsensitive(a, b);
		if (cmp != ComparisonEqual) {
			return cmp;
		}
		return CompareStringsCaseSensitive(a, b);
	}

	// CompareStringsCaseInsensitiveEslintCompatible performs a case-insensitive comparison
	// using toLowerCase() instead of toUpperCase() for ESLint compatibility.
	//
	// `CompareStringsCaseInsensitive` transforms letters to uppercase for unicode reasons,
	// while eslint's `sort-imports` rule transforms letters to lowercase. Which one you choose
	// affects the relative order of letters and ASCII characters 91-96, of which `_` is a
	// valid character in an identifier. So if we used `CompareStringsCaseInsensitive` for
	// import sorting, TypeScript and eslint would disagree about the correct case-insensitive
	// sort order for `__String` and `Foo`. Since eslint's whole job is to create consistency
	// by enforcing nitpicky details like this, it makes way more sense for us to just adopt
	// their convention so users can have auto-imports without making eslint angry.
	public static function CompareStringsCaseInsensitiveEslintCompatible(a:String, b:String):Comparison {
		if (a == b) {
			return ComparisonEqual;
		}
		a = Strings.ToLower(a);
		b = Strings.ToLower(b);
		return Strings.Compare(a, b);
	}

	// --- identifier.go ---

	// IsUnicodeIdentifierStart reports whether ch may begin an ECMAScript
	// identifier, i.e. whether it has the Unicode ID_Start (or Other_ID_Start)
	// property. The range table is generated; see generate-unicode-data.mts.
	public static function IsUnicodeIdentifierStart(ch:Int):Bool {
		return Unicode.Is(IdentifierPartsGenerated.unicodeESNextIdentifierStart, ch);
	}

	// IsUnicodeIdentifierPart reports whether ch may appear after the first
	// character of an ECMAScript identifier, i.e. whether it has the Unicode
	// ID_Continue (or Other_ID_Continue) property, which also includes ID_Start.
	public static function IsUnicodeIdentifierPart(ch:Int):Bool {
		return Unicode.Is(IdentifierPartsGenerated.unicodeESNextIdentifierPart, ch);
	}

	// --- js_case.go ---

	public static function ToLowerJS(str:String):String {
		final ascii = toLowerASCII(str);
		if (ascii != null) {
			return ascii;
		}

		final builder = new StringBuf();
		final specialCasingMappings = JsCaseGenerated.specialCasingMappings();
		// casedBefore tracks whether the most recent non-Case_Ignorable code point is
		// "cased", which is the backward half of the Final_Sigma context. We
		// accumulate it as we stream so we never have to scan (or decode) backwards.
		var casedBefore = false;
		var i = 0;
		while (i < str.length) {
			// PORT: utf16 — i is a UTF-16 offset.
			final r = DecodeJSStringRune(str, i);
			final size = Utf16.RuneLen(r);
			i += size;
			if (IsSurrogate(r)) {
				// A lone surrogate has no case mapping; preserve it verbatim, matching
				// String.prototype.toLowerCase. EncodeJSStringRune restores the sentinel
				// bytes because WriteRune would re-encode the surrogate as U+FFFD.
				builder.add(EncodeJSStringRune(r));
			} else {
				final mapping = specialCasingMappings.get(r);
				if (mapping != null) {
					if (mapping.condition == SpecialCasingCondition.specialCasingConditionFinalSigma && isFinalSigmaContext(casedBefore, str, i)) {
						builder.add(mapping.conditionalLower);
					} else {
						builder.add(mapping.lower);
					}
				} else {
					Utf16.WriteRune(builder, r);
				}
			}
			if (!isUnicodeCaseIgnorable(r)) {
				casedBefore = isSigmaCased(r);
			}
		}
		return builder.toString();
	}

	public static function ToUpperJS(str:String):String {
		final ascii = toUpperASCII(str);
		if (ascii != null) {
			return ascii;
		}

		final builder = new StringBuf();
		final specialCasingMappings = JsCaseGenerated.specialCasingMappings();
		var i = 0;
		while (i < str.length) {
			// PORT: utf16 — i is a UTF-16 offset.
			final r = DecodeJSStringRune(str, i);
			final size = Utf16.RuneLen(r);
			if (IsSurrogate(r)) {
				// A lone surrogate has no case mapping; preserve it verbatim, matching
				// String.prototype.toUpperCase. Copy the sentinel bytes directly because
				// WriteRune would re-encode the surrogate as U+FFFD.
				// PORT: utf16 — Go copies str[i:i+size]; hxcpp's substring would turn a lone surrogate
				// at the slice edge into U+FFFD, so the code unit is written directly.
				builder.add(Utf16.CodeUnitString(r));
			} else {
				final mapping = specialCasingMappings.get(r);
				if (mapping != null) {
					builder.add(mapping.upper);
				} else {
					Utf16.WriteRune(builder, r);
				}
			}
			i += size;
		}

		return builder.toString();
	}

	// PORT: Go returns (string, bool); here null means "not ASCII" (false).
	static function toLowerASCII(str:String):Null<String> {
		var needsMapping = false;
		for (i in 0...str.length) {
			final ch = StringTools.fastCodeAt(str, i);
			if (ch >= Utf16.RuneSelf) {
				return null;
			}
			needsMapping = needsMapping || ('A'.code <= ch && ch <= 'Z'.code);
		}
		if (!needsMapping) {
			return str;
		}

		final buf = new StringBuf();
		for (i in 0...str.length) {
			var ch = StringTools.fastCodeAt(str, i);
			if ('A'.code <= ch && ch <= 'Z'.code) {
				ch = ch + ('a'.code - 'A'.code);
			}
			buf.addChar(ch);
		}
		return buf.toString();
	}

	// PORT: Go returns (string, bool); here null means "not ASCII" (false).
	static function toUpperASCII(str:String):Null<String> {
		var needsMapping = false;
		for (i in 0...str.length) {
			final ch = StringTools.fastCodeAt(str, i);
			if (ch >= Utf16.RuneSelf) {
				return null;
			}
			needsMapping = needsMapping || ('a'.code <= ch && ch <= 'z'.code);
		}
		if (!needsMapping) {
			return str;
		}

		final buf = new StringBuf();
		for (i in 0...str.length) {
			var ch = StringTools.fastCodeAt(str, i);
			if ('a'.code <= ch && ch <= 'z'.code) {
				ch = ch - ('a'.code - 'A'.code);
			}
			buf.addChar(ch);
		}
		return buf.toString();
	}

	// isFinalSigmaContext reports whether a sigma at the current position is in
	// Final_Sigma context: it is preceded by a cased code point and not followed by
	// one. casedBefore carries the backward half (tracked incrementally by the
	// caller so we never scan backwards); afterOffset is the byte offset just past
	// the sigma, from which we scan forward.
	//
	// ECMAScript points at Unicode Default Case Conversion for toLowerCase, and
	// modern V8 reaches that behavior through Intl::ConvertToLower, which uses
	// ICU root-locale lowercasing for non-Latin1 strings like Greek sigma.
	// We intentionally do not delegate this to golang.org/x/text/cases: x/text
	// is a general Unicode casing library, but its root-locale behavior is not
	// an exact match for the JS semantics exercised by String.prototype
	// .toLowerCase(), especially around Final_Sigma context. TypeScript needs the
	// JS behavior itself here, so we keep the context-sensitive part explicit.
	// SpiderMonkey models Final_Sigma with a more explicit context walk, while
	// Unicode Table 3-17 describes it in terms of Cased and Case_Ignorable.
	// We model the exposed V8/ICU behavior directly here: skip Case_Ignorable code
	// points and then look for a Cased code point, exactly as Unicode Table 3-17
	// defines the Final_Sigma condition. The Cased property already subsumes
	// lowercase, uppercase, and titlecase letters, including the
	// DerivedCoreProperties Lowercase/Uppercase extras such as ª, º, and Roman
	// numerals.
	// PORT: utf16 — afterOffset is a UTF-16 offset.
	static function isFinalSigmaContext(casedBefore:Bool, str:String, afterOffset:Int):Bool {
		return casedBefore && !hasSigmaCasedAfter(str, afterOffset);
	}

	static function hasSigmaCasedAfter(str:String, start:Int):Bool {
		var i = start;
		while (i < str.length) {
			final r = DecodeJSStringRune(str, i);
			i += Utf16.RuneLen(r);
			if (isUnicodeCaseIgnorable(r)) {
				continue;
			}
			return isSigmaCased(r);
		}
		return false;
	}

	static function isSigmaCased(r:Int):Bool {
		return Unicode.Is(JsCaseGenerated.unicodeCasedRanges, r);
	}

	static function isUnicodeCaseIgnorable(r:Int):Bool {
		return Unicode.Is(JsCaseGenerated.unicodeCaseIgnorableRanges, r);
	}

	// --- util.go ---

	public static function IsWhiteSpaceLike(ch:Int):Bool {
		return IsWhiteSpaceSingleLine(ch) || IsLineBreak(ch);
	}

	public static function IsWhiteSpaceSingleLine(ch:Int):Bool {
		// Note: nextLine is in the Zs space, and should be considered to be a whitespace.
		// It is explicitly not a line-break as it isn't in the exact set specified by EcmaScript.
		switch (ch) {
			case ' '.code, // space
				'\t'.code, // tab
				0x0B, // verticalTab
				0x0C, // formFeed
				0x0085, // nextLine
				0x00A0, // nonBreakingSpace
				0x1680, // ogham
				0x2000, // enQuad
				0x2001, // emQuad
				0x2002, // enSpace
				0x2003, // emSpace
				0x2004, // threePerEmSpace
				0x2005, // fourPerEmSpace
				0x2006, // sixPerEmSpace
				0x2007, // figureSpace
				0x2008, // punctuationEmSpace
				0x2009, // thinSpace
				0x200A, // hairSpace
				0x200B, // zeroWidthSpace
				0x202F, // narrowNoBreakSpace
				0x205F, // mathematicalSpace
				0x3000, // ideographicSpace
				0xFEFF: // byteOrderMark
				return true;
		}
		return false;
	}

	public static function IsLineBreak(ch:Int):Bool {
		// ES5 7.3:
		// The ECMAScript line terminator characters are listed in Table 3.
		//     Table 3: Line Terminator Characters
		//     Code Unit Value     Name                    Formal Name
		//     \u000A              Line Feed               <LF>
		//     \u000D              Carriage Return         <CR>
		//                    Line separator          <LS>
		//                    Paragraph separator     <PS>
		// Only the characters in Table 3 are treated as line terminators. Other new line or line
		// breaking characters are treated as white space but not as line terminators.
		switch (ch) {
			case '\n'.code, // lineFeed
				'\r'.code, // carriageReturn
				0x2028, // lineSeparator
				0x2029: // paragraphSeparator
				return true;
		}
		return false;
	}

	public static inline function IsDigit(ch:Int):Bool {
		return ch >= '0'.code && ch <= '9'.code;
	}

	public static inline function IsOctalDigit(ch:Int):Bool {
		return ch >= '0'.code && ch <= '7'.code;
	}

	public static inline function IsHexDigit(ch:Int):Bool {
		return ch >= '0'.code && ch <= '9'.code || ch >= 'A'.code && ch <= 'F'.code || ch >= 'a'.code && ch <= 'f'.code;
	}

	public static inline function IsASCIILetter(ch:Int):Bool {
		return ch >= 'A'.code && ch <= 'Z'.code || ch >= 'a'.code && ch <= 'z'.code;
	}

	// PORT: utf16 — checks UTF-16 code units; a code unit >= 0x80 exactly when a UTF-8 byte >= 0x80.
	public static function ContainsNonASCII(s:String):Bool {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		// PORT: perf — four UTF-16 units at a time (a whole source file's text per call)
		final n = s.length;
		final p = hxmc.rt.Str.unitsAddr(s);
		var i = 0;
		while (i + 4 <= n) {
			if ((hxmc.unsafe.Mem.getI32(p, 2 * i) | hxmc.unsafe.Mem.getI32(p, 2 * i + 4)) & 0xFF80FF80 != 0)
				break;
			i += 4;
		}
		for (j in i...n) {
			if (StringTools.fastCodeAt(s, j) >= Utf16.RuneSelf) {
				return true;
			}
		}
		return false;
		#end
		for (i in 0...s.length) {
			if (StringTools.fastCodeAt(s, i) >= Utf16.RuneSelf) {
				return true;
			}
		}
		return false;
	}

	public static function SplitLines(text:String):Array<String> {
		final lines:Array<String> = [];
		var start = 0;
		var pos = 0;
		while (pos < text.length) {
			switch (StringTools.fastCodeAt(text, pos)) {
				case '\r'.code:
					if (pos + 1 < text.length && StringTools.fastCodeAt(text, pos + 1) == '\n'.code) {
						lines.push(text.substring(start, pos));
						pos += 2;
						start = pos;
						continue;
					}
					// fallthrough
					lines.push(text.substring(start, pos));
					pos++;
					start = pos;
					continue;
				case '\n'.code:
					lines.push(text.substring(start, pos));
					pos++;
					start = pos;
					continue;
			}
			pos++;
		}
		if (start < text.length) {
			lines.push(text.substring(start));
		}
		return lines;
	}

	// PORT: utf16 — the result is a UTF-16 length (Go: bytes).
	public static function GuessIndentation(lines:Array<String>):Int {
		final MAX_SMI_X86 = 0x3fffffff;
		var indentation = MAX_SMI_X86;
		for (line in lines) {
			if (line.length == 0) {
				continue;
			}
			var i = 0;
			while (i < line.length && i < indentation) {
				final ch = Utf16.DecodeRuneInString(line, i);
				if (!IsWhiteSpaceLike(ch)) {
					break;
				}
				i += Utf16.RuneLen(ch);
			}
			if (i < indentation) {
				indentation = i;
			}
			if (indentation == 0) {
				return 0;
			}
		}
		if (indentation == MAX_SMI_X86) {
			return 0;
		}
		return indentation;
	}

	// https://tc39.es/ecma262/multipage/global-object.html#sec-encodeuri-uri
	// PORT: utf16 — Go walks the UTF-8 bytes. Here each code point is encoded to UTF-8 first
	// (a lone surrogate to its 3-byte WTF-8 form, as Go stores it); every byte >= 0x80 is escaped.
	public static function EncodeURI(s:String):String {
		final builder = new StringBuf();
		var i = 0;
		while (i < s.length) {
			final r = Utf16.CodePointAt(s, i);
			i += Utf16.RuneLen(r);
			if (r < Utf16.RuneSelf) {
				if (!shouldEscapeForEncodeURI(r)) {
					builder.addChar(r);
					continue;
				}
				writeEscapedByte(builder, r);
			} else if (r < 0x800) {
				writeEscapedByte(builder, 0xC0 | (r >> 6));
				writeEscapedByte(builder, 0x80 | (r & 0x3F));
			} else if (r < 0x10000) {
				writeEscapedByte(builder, 0xE0 | (r >> 12));
				writeEscapedByte(builder, 0x80 | ((r >> 6) & 0x3F));
				writeEscapedByte(builder, 0x80 | (r & 0x3F));
			} else {
				writeEscapedByte(builder, 0xF0 | (r >> 18));
				writeEscapedByte(builder, 0x80 | ((r >> 12) & 0x3F));
				writeEscapedByte(builder, 0x80 | ((r >> 6) & 0x3F));
				writeEscapedByte(builder, 0x80 | (r & 0x3F));
			}
		}
		return builder.toString();
	}

	// PORT: utf16 — body of Go's inner `for _, escaped := range []byte(...)` loop.
	static inline function writeEscapedByte(builder:StringBuf, escaped:Int):Void {
		builder.addChar('%'.code);
		builder.addChar(StringTools.fastCodeAt(upperhex, escaped >> 4));
		builder.addChar(StringTools.fastCodeAt(upperhex, escaped & 0x0f));
	}

	static inline final upperhex = "0123456789ABCDEF";

	static function shouldEscapeForEncodeURI(b:Int):Bool {
		if (b >= 'A'.code && b <= 'Z'.code) {
			return false;
		} else if (b >= 'a'.code && b <= 'z'.code) {
			return false;
		} else if (b >= '0'.code && b <= '9'.code) {
			return false;
		}

		switch (b) {
			case ';'.code, '/'.code, '?'.code, ':'.code, '@'.code, '&'.code, '='.code, '+'.code, '$'.code, ','.code, '#'.code, '-'.code, '_'.code,
				'.'.code, '!'.code, '~'.code, '*'.code, "'".code, '('.code, ')'.code:
				return false;
			default:
				return true;
		}
	}

	// PORT: utf16 — Go checks the raw UTF-8 / UTF-16 BOM bytes. Haxe text is decoded, so a BOM is
	// the single code unit U+FEFF (length 1); the raw UTF-16 BOM byte forms cannot occur.
	static function getByteOrderMarkLength(text:String):Int {
		if (text.length >= 1) {
			final ch0 = StringTools.fastCodeAt(text, 0);
			if (ch0 == 0xfeff) {
				return 1; // utf8
			}
		}
		return 0;
	}

	public static function RemoveByteOrderMark(text:String):String {
		final length = getByteOrderMarkLength(text);
		if (length > 0) {
			return text.substring(length);
		}
		return text;
	}

	// PORT: utf16 — Go prepends the bytes EF BB BF; the UTF-16 form is U+FEFF.
	public static function AddUTF8ByteOrderMark(text:String):String {
		if (getByteOrderMarkLength(text) == 0) {
			return "\u{FEFF}" + text;
		}
		return text;
	}

	public static function StripQuotes(name:String):String {
		if (name.length < 2) {
			return name;
		}
		final firstChar = Utf16.DecodeRuneInString(name, 0);
		final lastChar = Utf16.DecodeLastRuneInString(name);
		if (firstChar == lastChar && (firstChar == "'".code || firstChar == '"'.code || firstChar == '`'.code)) {
			return name.substring(1, name.length - 1);
		}
		return name;
	}

	// PORT: Go uses regexp `\\.` with ReplaceAllStringFunc(in => in[1:]). A Haxe EReg `.` differs
	// per target (JS also excludes \r, U+2028, U+2029; PCRE rejects lone surrogates), so the same
	// replacement is written as a loop: drop each backslash that is followed by a non-'\n' character.
	public static function UnquoteString(str:String):String {
		// strconv.Unquote is insufficient as that only handles a single character inside single quotes, as those are character literals in go
		final inner = StripQuotes(str);
		// In strada we do str.replace(/\\./g, s => s.substring(1)) - which is to say, replace all backslash-something with just something
		// That's replicated here faithfully, but it seems wrong! This should probably be an actual unquote operation?
		if (inner.indexOf("\\") < 0) {
			return inner;
		}
		final b = new StringBuf();
		var i = 0;
		while (i < inner.length) {
			final c = StringTools.fastCodeAt(inner, i);
			if (c == '\\'.code && i + 1 < inner.length && StringTools.fastCodeAt(inner, i + 1) != '\n'.code) {
				b.addChar(StringTools.fastCodeAt(inner, i + 1));
				i += 2;
				continue;
			}
			b.addChar(c);
			i++;
		}
		return b.toString();
	}

	public static function LowerFirstChar(str:String):String {
		if (str.length > 0) {
			final char = Utf16.DecodeRuneInString(str, 0);
			final size = Utf16.RuneLen(char);
			return Utf16.RuneString(Unicode.ToLower(char)) + str.substring(size);
		}
		return str;
	}

	// PORT: utf16 — the length check and the cut index are UTF-16 code units (Go: bytes);
	// runes are code points (a lone surrogate counts as one, like an invalid byte in Go).
	public static function TruncateByRunes(str:String, maxLength:Int):String {
		if (str.length < maxLength) {
			return str;
		}
		if (maxLength <= 0) {
			return "";
		}
		var runeCount = 0;
		var i = 0;
		while (i < str.length) {
			runeCount++;
			if (runeCount > maxLength) {
				return str.substring(0, i);
			}
			i += Utf16.RuneLen(Utf16.CodePointAt(str, i));
		}
		return str;
	}

	// SurrogateLowStart is the boundary between the high and low halves of the
	// UTF-16 surrogate range. unicode/utf16 only exposes IsSurrogate for the
	// whole range, so this split point is defined here to distinguish the two.
	public static inline final SurrogateLowStart = 0xDC00;

	public static inline function IsHighSurrogate(ch:Int):Bool {
		return Utf16.IsSurrogate(ch) && ch < SurrogateLowStart;
	}

	public static inline function IsLowSurrogate(ch:Int):Bool {
		return Utf16.IsSurrogate(ch) && ch >= SurrogateLowStart;
	}

	public static inline function IsSurrogate(ch:Int):Bool {
		return Utf16.IsSurrogate(ch);
	}

	public static function SurrogatePairToCodePoint(high:Int, low:Int):Int {
		return Utf16.DecodeRune(high, low);
	}

	// PORT: Go returns (high, low rune); here a RunePair (r1 = high, r2 = low).
	public static function CodePointToSurrogatePair(ch:Int):RunePair {
		return Utf16.EncodeRune(ch);
	}

	// PORT: utf16 — the CESU-8/WTF-8 sentinel constants (surrogateUTF8Lead etc.) are not needed:
	// a Haxe (UTF-16) string holds a lone surrogate as a single code unit, like a JS string.

	// PORT: utf16 — a lone surrogate is returned as its single UTF-16 code unit (Go: 3 sentinel bytes).
	public static function EncodeJSStringRune(ch:Int):String {
		if (IsSurrogate(ch)) {
			return Utf16.CodeUnitString(ch);
		}
		return Utf16.RuneString(ch);
	}

	// PORT: utf16 — Go `DecodeJSStringRune(s[pos:]) (rune, int)`. Takes the UTF-16 offset instead
	// of a slice and returns only the rune: a valid surrogate pair is combined, a lone surrogate is
	// returned as is. The size is Utf16.RuneLen(r) (2 for r >= 0x10000, else 1). At the end of
	// the string it returns utf8.RuneError (Go: size 0; callers check the offset first).
	public static inline function DecodeJSStringRune(s:String, pos:Int):Int {
		return Utf16.CodePointAt(s, pos);
	}

	// CombineSurrogatePairs canonicalizes a JS-string value produced by
	// concatenation, merging any adjacent high+low surrogate sentinel pair (as
	// written by EncodeJSStringRune) into the single supplementary code point they
	// represent. This mirrors how concatenating two UTF-16 code units forms a
	// surrogate pair in a JavaScript string. It must be applied wherever separately
	// scanned string values are joined, since each half is only a lone surrogate
	// until it meets its partner. Strings without a lone-surrogate sentinel (the
	// common case) are returned unchanged.
	// PORT: utf16 — in a UTF-16 string adjacent high+low surrogates already form the pair, so
	// there is nothing to combine; Go's loop is the identity here.
	public static function CombineSurrogatePairs(s:String):String {
		return s;
	}
}
