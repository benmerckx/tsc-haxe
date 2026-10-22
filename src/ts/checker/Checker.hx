package ts.checker;

// GENERATED SKELETON by tools/gen/skeleton from internal/checker/checker.go (upstream v7.0.2).
// Types, fields and signatures only: port the bodies by hand (docs/PORTING.md).

enum abstract CheckMode(Int) from Int to Int {
	@:op(A | B) static function or(a:CheckMode, b:CheckMode):CheckMode;
	@:op(A & B) static function and(a:CheckMode, b:CheckMode):CheckMode;
	@:op(~A) static function not(a:CheckMode):CheckMode;

	var CheckModeNormal = 0; // Normal type checking
	var CheckModeContextual = 1 << 0; // Explicitly assigned contextual type, therefore not cacheable
	var CheckModeInferential = 1 << 1; // Inferential typing
	var CheckModeSkipContextSensitive = 1 << 2; // Skip context sensitive function expressions
	var CheckModeSkipGenericFunctions = 1 << 3; // Skip single signature generic functions
	var CheckModeIsForSignatureHelp = 1 << 4; // Call resolution for purposes of signature help
	var CheckModeRestBindingElement = 1 << 5; // Checking a type that is going to be used to determine the type of a rest binding element
	//   e.g. in `const { a, ...rest } = foo`, when checking the type of `foo` to determine the type of `rest`,
	//   we need to preserve generic types instead of substituting them for constraints
	var CheckModeTypeOnly = 1 << 6; // Called from getTypeOfExpression, diagnostics may be omitted
	var CheckModeForceTuple = 1 << 7;
}

typedef TypeSystemEntity = ts.ast.Symbol.TypeSystemEntity; // PORT: Go `any`, see ts/ast/Symbol.hx

enum abstract TypeSystemPropertyName(Int) from Int to Int {
	var TypeSystemPropertyNameType = 0;
	var TypeSystemPropertyNameResolvedBaseConstructorType = 1;
	var TypeSystemPropertyNameDeclaredType = 2;
	var TypeSystemPropertyNameResolvedReturnType = 3;
	var TypeSystemPropertyNameResolvedBaseConstraint = 4;
	var TypeSystemPropertyNameResolvedTypeArguments = 5;
	var TypeSystemPropertyNameResolvedBaseTypes = 6;
	var TypeSystemPropertyNameWriteType = 7;
	var TypeSystemPropertyNameInitializerIsUndefined = 8;
	var TypeSystemPropertyNameAliasTarget = 9;
}

@:allow(ts.checker)
class TypeResolution {
	var target:TypeSystemEntity = null;
	var propertyName:TypeSystemPropertyName = 0;
	var result:Bool = false;

	public function new() {}
}

@:allow(ts.checker)
class ContextualInfo {
	var node:Node = null;
	var t:Type = null;
	var isCache:Bool = false;

	public function new() {}
}

@:allow(ts.checker)
class InferenceContextInfo {
	var node:Node = null;
	var context:InferenceContext = null;

	public function new() {}
}

enum abstract WideningKind(Int) from Int to Int {
	var WideningKindNormal = 0;
	var WideningKindFunctionReturn = 1;
	var WideningKindGeneratorNext = 2;
	var WideningKindGeneratorYield = 3;
}

// PORT: struct map keys (PORTING.md §4a). Every struct key type has a static `keyOf(...)` that encodes
// the fields as a String (the map key) and an instance `Key()` that encodes its own fields. Pointer
// fields are encoded by Type.id / Signature.id where Go assigns those at creation; other pointers
// (Symbol, Node, FlowNode) by a checker-local identity number (`Checker.identityKeyOf`), because
// assigning ast symbol/node ids earlier than Go would change id-based orderings.
@:allow(ts.checker)
class EnumLiteralKey {
	var enumSymbol:Symbol = null;
	var value:Any = null;

	public function new() {}

	// value is a string or a jsnum.Number (NaN is cached separately by the caller, as in Go).
	public static function keyOf(c:Checker, enumSymbol:Symbol, value:Any):std.String {
		final v = Std.isOfType(value, std.String) ? "s" + (value : std.String) : "n" + Checker.numberLiteralKey((value : Float));
		return go.MapKey.i1s(Checker.identityKeyOf(c, enumSymbol), v);
	}

	public function Key(c:Checker):std.String {
		return keyOf(c, enumSymbol, value);
	}
}

@:allow(ts.checker)
class EnumRelationKey {
	var sourceId:SymbolId = 0;
	var targetId:SymbolId = 0;

	public function new() {}

	public static inline function keyOf(sourceId:SymbolId, targetId:SymbolId):std.String {
		return go.MapKey.i2(sourceId, targetId);
	}

	public function Key():std.String {
		return keyOf(sourceId, targetId);
	}
}

enum abstract CachedTypeKind(Int) from Int to Int {
	var CachedTypeKindLiteralUnionBaseType = 0;
	var CachedTypeKindIndexType = 1;
	var CachedTypeKindStringIndexType = 2;
	var CachedTypeKindEquivalentBaseType = 3;
	var CachedTypeKindApparentType = 4;
	var CachedTypeKindAwaitedType = 5;
	var CachedTypeKindEvolvingArrayType = 6;
	var CachedTypeKindArrayLiteralType = 7;
	var CachedTypeKindPermissiveInstantiation = 8;
	var CachedTypeKindRestrictiveInstantiation = 9;
	var CachedTypeKindRestrictiveTypeParameter = 10;
	var CachedTypeKindIndexedAccessForReading = 11;
	var CachedTypeKindIndexedAccessForWriting = 12;
	var CachedTypeKindWidened = 13;
	var CachedTypeKindRegularObjectLiteral = 14;
	var CachedTypeKindPromisedTypeOfPromise = 15;
	var CachedTypeKindDefaultOnlyType = 16;
	var CachedTypeKindSyntheticType = 17;
	var CachedTypeKindDecoratorContext = 18;
	var CachedTypeKindDecoratorContextStatic = 19;
	var CachedTypeKindDecoratorContextPrivate = 20;
	var CachedTypeKindDecoratorContextPrivateStatic = 21;
}

@:allow(ts.checker)
class CachedTypeKey {
	var kind:CachedTypeKind = 0;
	var typeId:TypeId = 0;

	public function new() {}

	public static inline function keyOf(kind:CachedTypeKind, typeId:TypeId):std.String {
		return go.MapKey.i2((kind : Int), typeId);
	}

	public function Key():std.String {
		return keyOf(kind, typeId);
	}
}

@:allow(ts.checker)
class NarrowedTypeKey {
	var t:Type = null;
	var candidate:Type = null;
	var assumeTrue:Bool = false;
	var checkDerived:Bool = false;

	public function new() {}

	public static function keyOf(t:Type, candidate:Type, assumeTrue:Bool, checkDerived:Bool):std.String {
		return go.MapKey.i3(Checker.typeKeyOf(t), Checker.typeKeyOf(candidate), (assumeTrue ? 10 : 0) + (checkDerived ? 1 : 0));
	}

	public function Key():std.String {
		return keyOf(t, candidate, assumeTrue, checkDerived);
	}
}

@:allow(ts.checker)
class UnionOfUnionKey {
	var id1:TypeId = 0;
	var id2:TypeId = 0;
	var r:UnionReduction = 0;
	var a:CacheHashKey = new CacheHashKey();

	public function new() {}

	public static function keyOf(id1:TypeId, id2:TypeId, r:UnionReduction, a:CacheHashKey):std.String {
		return go.MapKey.i3s(id1, id2, (r : Int), a.Key());
	}

	public function Key():std.String {
		return keyOf(id1, id2, r, a);
	}
}

@:allow(ts.checker)
class CachedSignatureKey {
	var sig:Signature = null;
	var key:CacheHashKey = new CacheHashKey(); // Type list key or one of the special keys below

	public function new() {}

	public static function keyOf(sig:Signature, key:CacheHashKey):std.String {
		return go.MapKey.i1s(sig == null ? 0 : sig.id, key.Key());
	}

	public function Key():std.String {
		return keyOf(sig, key);
	}
}

@:allow(ts.checker)
class StringMappingKey {
	var s:Symbol = null;
	var t:Type = null;

	public function new() {}

	public static function keyOf(c:Checker, s:Symbol, t:Type):std.String {
		return go.MapKey.i2(Checker.identityKeyOf(c, s), Checker.typeKeyOf(t));
	}

	public function Key(c:Checker):std.String {
		return keyOf(c, s, t);
	}
}

@:allow(ts.checker)
class AssignmentReducedKey {
	var id1:TypeId = 0;
	var id2:TypeId = 0;

	public function new() {}

	public static inline function keyOf(id1:TypeId, id2:TypeId):std.String {
		return go.MapKey.i2(id1, id2);
	}

	public function Key():std.String {
		return keyOf(id1, id2);
	}
}

@:allow(ts.checker)
class DiscriminatedContextualTypeKey {
	var nodeId:NodeId = 0;
	var typeId:TypeId = 0;

	public function new() {}

	public static inline function keyOf(nodeId:NodeId, typeId:TypeId):std.String {
		return go.MapKey.i2(nodeId, typeId);
	}

	public function Key():std.String {
		return keyOf(nodeId, typeId);
	}
}

@:allow(ts.checker)
class InstantiationExpressionKey {
	var nodeId:NodeId = 0;
	var typeId:TypeId = 0;

	public function new() {}

	public static inline function keyOf(nodeId:NodeId, typeId:TypeId):std.String {
		return go.MapKey.i2(nodeId, typeId);
	}

	public function Key():std.String {
		return keyOf(nodeId, typeId);
	}
}

@:allow(ts.checker)
class SubstitutionTypeKey {
	var baseId:TypeId = 0;
	var constraintId:TypeId = 0;

	public function new() {}

	public static inline function keyOf(baseId:TypeId, constraintId:TypeId):std.String {
		return go.MapKey.i2(baseId, constraintId);
	}

	public function Key():std.String {
		return keyOf(baseId, constraintId);
	}
}

@:allow(ts.checker)
class ReverseMappedTypeKey {
	var sourceId:TypeId = 0;
	var targetId:TypeId = 0;
	var constraintId:TypeId = 0;

	public function new() {}

	public static inline function keyOf(sourceId:TypeId, targetId:TypeId, constraintId:TypeId):std.String {
		return go.MapKey.i3(sourceId, targetId, constraintId);
	}

	public function Key():std.String {
		return keyOf(sourceId, targetId, constraintId);
	}
}

@:allow(ts.checker)
class IterationTypesKey {
	var typeId:TypeId = 0;
	var use:IterationUse = 0;

	public function new() {}

	public static inline function keyOf(typeId:TypeId, use:IterationUse):std.String {
		return go.MapKey.i2(typeId, (use : Int));
	}

	public function Key():std.String {
		return keyOf(typeId, use);
	}
}

@:allow(ts.checker)
class PropertiesTypesKey {
	var typeId:TypeId = 0;
	var include:TypeFlags = 0;
	var includeOrigin:Bool = false;
	var unresolvedMembers:Bool = false;

	public function new() {}

	public static function keyOf(typeId:TypeId, include:TypeFlags, includeOrigin:Bool, unresolvedMembers:Bool):std.String {
		return go.MapKey.i3(typeId, (include : Int), (includeOrigin ? 10 : 0) + (unresolvedMembers ? 1 : 0));
	}

	public function Key():std.String {
		return keyOf(typeId, include, includeOrigin, unresolvedMembers);
	}
}

@:allow(ts.checker)
class NonExistentPropertyKey {
	var propNode:Node = null;
	var containingType:Type = null;
	var isUncheckedJS:Bool = false;

	public function new() {}

	public static function keyOf(c:Checker, propNode:Node, containingType:Type, isUncheckedJS:Bool):std.String {
		return go.MapKey.i3(Checker.identityKeyOf(c, propNode), Checker.typeKeyOf(containingType), isUncheckedJS ? 1 : 0);
	}

	public function Key(c:Checker):std.String {
		return keyOf(c, propNode, containingType, isUncheckedJS);
	}
}

@:allow(ts.checker)
class FlowLoopKey {
	var flowNode:FlowNode = null;
	var refKey:CacheHashKey = new CacheHashKey();

	public function new() {}

	public static function keyOf(c:Checker, flowNode:FlowNode, refKey:CacheHashKey):std.String {
		return go.MapKey.i1s(Checker.identityKeyOf(c, flowNode), refKey.Key());
	}

	public function Key(c:Checker):std.String {
		return keyOf(c, flowNode, refKey);
	}
}

@:allow(ts.checker)
class FlowLoopInfo {
	var key:FlowLoopKey = new FlowLoopKey();
	var types:Array<Type> = null;

	public function new() {}
}

enum abstract InferenceFlags(Int) from Int to Int {
	@:op(A | B) static function or(a:InferenceFlags, b:InferenceFlags):InferenceFlags;
	@:op(A & B) static function and(a:InferenceFlags, b:InferenceFlags):InferenceFlags;
	@:op(~A) static function not(a:InferenceFlags):InferenceFlags;

	var InferenceFlagsNone = 0; // No special inference behaviors
	var InferenceFlagsNoDefault = 1 << 0; // Infer silentNeverType for no inferences (otherwise anyType or unknownType)
	var InferenceFlagsAnyDefault = 1 << 1; // Infer anyType (in JS files) for no inferences (otherwise unknownType)
	var InferenceFlagsSkippedGenericFunction = 1 << 2; // A generic function was skipped during inference
}

@:allow(ts.checker)
class InferenceContext {
	var inferences:Array<InferenceInfo> = null; // Inferences made for each type parameter
	var signature:Signature = null; // Generic signature for which inferences are made (if any)
	var flags:InferenceFlags = 0; // Inference flags
	var compareTypes:TypeComparer = null; // Type comparer function
	var mapper:TypeMapper = null; // Mapper that fixes inferences
	var nonFixingMapper:TypeMapper = null; // Mapper that doesn't fix inferences
	var returnMapper:TypeMapper = null; // Type mapper for inferences from return types (if any)
	var outerReturnMapper:TypeMapper = null; // Type mapper for inferences from return types of outer function (if any)
	var inferredTypeParameters:Array<Type> = null; // Inferred type parameters for function result
	var intraExpressionInferenceSites:Array<IntraExpressionInferenceSite> = null;

	public function new() {}
}

@:allow(ts.checker)
class InferenceInfo {
	var typeParameter:Type = null; // Type parameter for which inferences are being made
	var candidates:Array<Type> = null; // Candidates in covariant positions in decreasing depth order
	var candidateDepths:Array<Int> = null; // Type argument depths of covariant inferences
	var contraCandidates:Array<Type> = null; // Candidates in contravariant positions
	var inferredType:Type = null; // Cache for resolved inferred type
	var priority:InferencePriority = 0; // Priority of current inference set
	var topLevel:Bool = false; // True if all inferences are to top level occurrences
	var isFixed:Bool = false; // True if inferences are fixed
	var impliedArity:Int = 0; // Implied arity (or -1)

	public function new() {}
}

enum abstract InferencePriority(Int) from Int to Int {
	@:op(A | B) static function or(a:InferencePriority, b:InferencePriority):InferencePriority;
	@:op(A & B) static function and(a:InferencePriority, b:InferencePriority):InferencePriority;
	@:op(~A) static function not(a:InferencePriority):InferencePriority;

	var InferencePriorityNone = 0;
	var InferencePriorityNakedTypeVariable = 1 << 0; // Naked type variable in union or intersection type
	var InferencePrioritySpeculativeTuple = 1 << 1; // Speculative tuple inference
	var InferencePrioritySubstituteSource = 1 << 2; // Source of inference originated within a substitution type's substitute
	var InferencePriorityHomomorphicMappedType = 1 << 3; // Reverse inference for homomorphic mapped type
	var InferencePriorityPartialHomomorphicMappedType = 1 << 4; // Partial reverse inference for homomorphic mapped type
	var InferencePriorityMappedTypeConstraint = 1 << 5; // Reverse inference for mapped type
	var InferencePriorityContravariantConditional = 1 << 6; // Conditional type in contravariant position
	var InferencePriorityReturnType = 1 << 7; // Inference made from return type of generic function
	var InferencePriorityLiteralKeyof = 1 << 8; // Inference made from a string literal to a keyof T
	var InferencePriorityNoConstraints = 1 << 9; // Don't infer from constraints of instantiable types
	var InferencePriorityAlwaysStrict = 1 << 10; // Always use strict rules for contravariant inferences
	var InferencePriorityMaxValue = 1 << 11; // Seed for inference priority tracking
	var InferencePriorityCircularity = -1; // Inference circularity (value less than all other priorities)
	var InferencePriorityPriorityImpliesCombination = 416; // These priorities imply that the resulting type should be a combination of all candidates
}

@:allow(ts.checker)
class IntraExpressionInferenceSite {
	var node:Node = null;
	var t:Type = null;

	public function new() {}
}

enum abstract DeclarationMeaning(Int) from Int to Int {
	@:op(A | B) static function or(a:DeclarationMeaning, b:DeclarationMeaning):DeclarationMeaning;
	@:op(A & B) static function and(a:DeclarationMeaning, b:DeclarationMeaning):DeclarationMeaning;
	@:op(~A) static function not(a:DeclarationMeaning):DeclarationMeaning;

	var DeclarationMeaningGetAccessor = 1 << 0;
	var DeclarationMeaningSetAccessor = 1 << 1;
	var DeclarationMeaningPropertyAssignment = 1 << 2;
	var DeclarationMeaningMethod = 1 << 3;
	var DeclarationMeaningPrivateStatic = 1 << 4;
	var DeclarationMeaningGetOrSetAccessor = 3;
	var DeclarationMeaningPropertyAssignmentOrMethod = 12;
}

enum abstract DeclarationSpaces(Int) from Int to Int {
	@:op(A | B) static function or(a:DeclarationSpaces, b:DeclarationSpaces):DeclarationSpaces;
	@:op(A & B) static function and(a:DeclarationSpaces, b:DeclarationSpaces):DeclarationSpaces;
	@:op(~A) static function not(a:DeclarationSpaces):DeclarationSpaces;

	var DeclarationSpacesNone = 0;
	var DeclarationSpacesExportValue = 1 << 0;
	var DeclarationSpacesExportType = 1 << 1;
	var DeclarationSpacesExportNamespace = 1 << 2;
}

enum abstract IntrinsicTypeKind(Int) from Int to Int {
	var IntrinsicTypeKindUnknown = 0;
	var IntrinsicTypeKindUppercase = 1;
	var IntrinsicTypeKindLowercase = 2;
	var IntrinsicTypeKindCapitalize = 3;
	var IntrinsicTypeKindUncapitalize = 4;
	var IntrinsicTypeKindNoInfer = 5;
}

enum abstract MappedTypeModifiers(Int) from Int to Int {
	@:op(A | B) static function or(a:MappedTypeModifiers, b:MappedTypeModifiers):MappedTypeModifiers;
	@:op(A & B) static function and(a:MappedTypeModifiers, b:MappedTypeModifiers):MappedTypeModifiers;
	@:op(~A) static function not(a:MappedTypeModifiers):MappedTypeModifiers;

	var MappedTypeModifiersIncludeReadonly = 1 << 0;
	var MappedTypeModifiersExcludeReadonly = 1 << 1;
	var MappedTypeModifiersIncludeOptional = 1 << 2;
	var MappedTypeModifiersExcludeOptional = 1 << 3;
}

enum abstract MappedTypeNameTypeKind(Int) from Int to Int {
	var MappedTypeNameTypeKindNone = 0;
	var MappedTypeNameTypeKindFiltering = 1;
	var MappedTypeNameTypeKindRemapping = 2;
}

enum abstract ReferenceHint(Int) from Int to Int {
	var ReferenceHintUnspecified = 0;
	var ReferenceHintIdentifier = 1;
	var ReferenceHintProperty = 2;
	var ReferenceHintExportAssignment = 3;
	var ReferenceHintJsx = 4;
	var ReferenceHintExportImportEquals = 5;
	var ReferenceHintExportSpecifier = 6;
	var ReferenceHintDecorator = 7;
}

enum abstract TypeFacts(Int) from Int to Int {
	@:op(A | B) static function or(a:TypeFacts, b:TypeFacts):TypeFacts;
	@:op(A & B) static function and(a:TypeFacts, b:TypeFacts):TypeFacts;
	@:op(~A) static function not(a:TypeFacts):TypeFacts;

	var TypeFactsNone = 0;
	var TypeFactsTypeofEQString = 1 << 0;
	var TypeFactsTypeofEQNumber = 1 << 1;
	var TypeFactsTypeofEQBigInt = 1 << 2;
	var TypeFactsTypeofEQBoolean = 1 << 3;
	var TypeFactsTypeofEQSymbol = 1 << 4;
	var TypeFactsTypeofEQObject = 1 << 5;
	var TypeFactsTypeofEQFunction = 1 << 6;
	var TypeFactsTypeofEQHostObject = 1 << 7;
	var TypeFactsTypeofNEString = 1 << 8;
	var TypeFactsTypeofNENumber = 1 << 9;
	var TypeFactsTypeofNEBigInt = 1 << 10;
	var TypeFactsTypeofNEBoolean = 1 << 11;
	var TypeFactsTypeofNESymbol = 1 << 12;
	var TypeFactsTypeofNEObject = 1 << 13;
	var TypeFactsTypeofNEFunction = 1 << 14;
	var TypeFactsTypeofNEHostObject = 1 << 15;
	var TypeFactsEQUndefined = 1 << 16;
	var TypeFactsEQNull = 1 << 17;
	var TypeFactsEQUndefinedOrNull = 1 << 18;
	var TypeFactsNEUndefined = 1 << 19;
	var TypeFactsNENull = 1 << 20;
	var TypeFactsNEUndefinedOrNull = 1 << 21;
	var TypeFactsTruthy = 1 << 22;
	var TypeFactsFalsy = 1 << 23;
	var TypeFactsIsUndefined = 1 << 24;
	var TypeFactsIsNull = 1 << 25;
	var TypeFactsIsUndefinedOrNull = 50331648;
	var TypeFactsAll = 134217727;
	// The following members encode facts about particular kinds of types for use in the getTypeFacts function.
	// The presence of a particular fact means that the given test is true for some (and possibly all) values
	// of that kind of type.
	var TypeFactsBaseStringStrictFacts = 3735041;
	var TypeFactsBaseStringFacts = 12582401;
	var TypeFactsStringStrictFacts = 16317953;
	var TypeFactsStringFacts = 16776705;
	var TypeFactsEmptyStringStrictFacts = 12123649;
	var TypeFactsEmptyStringFacts = 12582401;
	var TypeFactsNonEmptyStringStrictFacts = 7929345;
	var TypeFactsNonEmptyStringFacts = 16776705;
	var TypeFactsBaseNumberStrictFacts = 3734786;
	var TypeFactsBaseNumberFacts = 12582146;
	var TypeFactsNumberStrictFacts = 16317698;
	var TypeFactsNumberFacts = 16776450;
	var TypeFactsZeroNumberStrictFacts = 12123394;
	var TypeFactsZeroNumberFacts = 12582146;
	var TypeFactsNonZeroNumberStrictFacts = 7929090;
	var TypeFactsNonZeroNumberFacts = 16776450;
	var TypeFactsBaseBigIntStrictFacts = 3734276;
	var TypeFactsBaseBigIntFacts = 12581636;
	var TypeFactsBigIntStrictFacts = 16317188;
	var TypeFactsBigIntFacts = 16775940;
	var TypeFactsZeroBigIntStrictFacts = 12122884;
	var TypeFactsZeroBigIntFacts = 12581636;
	var TypeFactsNonZeroBigIntStrictFacts = 7928580;
	var TypeFactsNonZeroBigIntFacts = 16775940;
	var TypeFactsBaseBooleanStrictFacts = 3733256;
	var TypeFactsBaseBooleanFacts = 12580616;
	var TypeFactsBooleanStrictFacts = 16316168;
	var TypeFactsBooleanFacts = 16774920;
	var TypeFactsFalseStrictFacts = 12121864;
	var TypeFactsFalseFacts = 12580616;
	var TypeFactsTrueStrictFacts = 7927560;
	var TypeFactsTrueFacts = 16774920;
	var TypeFactsSymbolStrictFacts = 7925520;
	var TypeFactsSymbolFacts = 16772880;
	var TypeFactsObjectStrictFacts = 7888800;
	var TypeFactsObjectFacts = 16736160;
	var TypeFactsFunctionStrictFacts = 7880640;
	var TypeFactsFunctionFacts = 16728000;
	var TypeFactsVoidFacts = 9830144;
	var TypeFactsUndefinedFacts = 26607360;
	var TypeFactsNullFacts = 42917664;
	var TypeFactsEmptyObjectStrictFacts = 83427327;
	var TypeFactsEmptyObjectFacts = 83886079;
	var TypeFactsUnknownFacts = 83886079;
	var TypeFactsAllTypeofNE = 556800;
	// Masks
	var TypeFactsOrFactsMask = 8256;
	var TypeFactsAndFactsMask = 134209471;
}

enum abstract IterationUse(Int) from Int to Int {
	@:op(A | B) static function or(a:IterationUse, b:IterationUse):IterationUse;
	@:op(A & B) static function and(a:IterationUse, b:IterationUse):IterationUse;
	@:op(~A) static function not(a:IterationUse):IterationUse;

	var IterationUseAllowsSyncIterablesFlag = 1 << 0;
	var IterationUseAllowsAsyncIterablesFlag = 1 << 1;
	var IterationUseAllowsStringInputFlag = 1 << 2;
	var IterationUseForOfFlag = 1 << 3;
	var IterationUseYieldStarFlag = 1 << 4;
	var IterationUseSpreadFlag = 1 << 5;
	var IterationUseDestructuringFlag = 1 << 6;
	var IterationUsePossiblyOutOfBounds = 1 << 7;
	// Spread, Destructuring, Array element assignment
	var IterationUseElement = 1 << 0;
	var IterationUseSpread = 33;
	var IterationUseDestructuring = 65;
	var IterationUseForOf = 13;
	var IterationUseForAwaitOf = 15;
	var IterationUseYieldStar = 17;
	var IterationUseAsyncYieldStar = 19;
	var IterationUseGeneratorReturnType = 1 << 0;
	var IterationUseAsyncGeneratorReturnType = 1 << 1;
	var IterationUseCacheFlags = 11;
}

@:allow(ts.checker)
class IterationTypes {
	var yieldType:Type = null;
	var returnType:Type = null;
	var nextType:Type = null;

	public function new() {}

	function hasTypes():Bool {
		return this.yieldType != null || this.returnType != null || this.nextType != null;
	}

	function getType(typeKind:IterationTypeKind):Type {
		switch (typeKind) {
			case IterationTypeKindYield:
				return this.yieldType;
			case IterationTypeKindReturn:
				return this.returnType;
			case IterationTypeKindNext:
				return this.nextType;
			default:
		}
		throw "Unhandled case in getType(IterationTypeKind)";
	}
}

enum abstract IterationTypeKind(Int) from Int to Int {
	var IterationTypeKindYield = 0;
	var IterationTypeKindReturn = 1;
	var IterationTypeKindNext = 2;
}

@:allow(ts.checker)
class IterationTypesResolver {
	var iteratorSymbolName:std.String = "";
	var getGlobalIteratorType:() -> Type = null;
	var getGlobalIterableType:() -> Type = null;
	var getGlobalIterableTypeChecked:() -> Type = null;
	var getGlobalIterableIteratorType:() -> Type = null;
	var getGlobalIterableIteratorTypeChecked:() -> Type = null;
	var getGlobalIteratorObjectType:() -> Type = null;
	var getGlobalGeneratorType:() -> Type = null;
	var getGlobalBuiltinIteratorTypes:() -> Array<Type> = null;
	var resolveIterationType:(t:Type, errorNode:Node) -> Type = null;
	var mustHaveANextMethodDiagnostic:Message = null;
	var mustBeAMethodDiagnostic:Message = null;
	var mustHaveAValueDiagnostic:Message = null;

	public function new() {}

	function getResolvedIterationTypes(yieldType:Type, returnType:Type, nextType:Type):IterationTypes {
		final result = new IterationTypes();
		result.yieldType = Core.OrElse(this.resolveIterationType(yieldType, null /*errorNode*/), yieldType);
		result.returnType = Core.OrElse(this.resolveIterationType(returnType, null /*errorNode*/), returnType);
		result.nextType = nextType;
		return result;
	}
}

@:allow(ts.checker)
class WideningContext {
	var parent:WideningContext = null; // Parent context
	var propertyName:std.String = ""; // Name of property in parent
	var siblings:Array<Type> = null; // Types of siblings
	var resolvedProperties:Array<Symbol> = null; // Properties occurring in sibling object literals
	var childContexts:StringMap<WideningContext> = null;
	var widenedTypes:IdentityMap<Type, Type> = null;

	public function new() {}

	function getChildContext(propertyName:std.String):WideningContext {
		final cached = this.childContexts == null ? null : this.childContexts.get(propertyName);
		if (cached != null) {
			return cached;
		}
		final result = new WideningContext();
		result.parent = this;
		result.propertyName = propertyName;
		if (this.childContexts == null) {
			this.childContexts = new StringMap<WideningContext>();
		}
		this.childContexts.set(propertyName, result);
		return result;
	}
}

interface Program extends Host {
	function BindSourceFiles():Void;
	function CommonSourceDirectory():std.String;
	function FileExists(fileName:std.String):Bool;
	function GetEmitModuleFormatOfFile(sourceFile:HasFileName):ModuleKind;
	function GetEmitSyntaxForUsageLocation(sourceFile:HasFileName, usageLocation:StringLiteralLike):ResolutionMode;
	function GetImpliedNodeFormatForEmit(sourceFile:HasFileName):ModuleKind;
	function GetImportHelpersImportSpecifier(path:Path):Node;
	function GetJSXRuntimeImportSpecifier(path:Path):Pair<std.String, Node>;
	function GetPackagesMap():StringMap<Bool>;
	function GetProjectReferenceFromOutputDts(path:Path):SourceOutputAndProjectReference;
	function GetRedirectForResolution(file:HasFileName):ParsedCommandLine;
	function GetResolvedModule(currentSourceFile:HasFileName, moduleReference:std.String, mode:ResolutionMode):ResolvedModule;
	function GetResolvedModules():StringMap<ModeAwareCache<ResolvedModule>>;
	function GetSourceFile(fileName:std.String):SourceFile;
	function GetSourceFileForResolvedModule(fileName:std.String):SourceFile;
	function GetSourceFileMetaData(path:Path):SourceFileMetaData;
	function IsSourceFileDefaultLibrary(path:Path):Bool;
	function Options():CompilerOptions;
	function SourceFileMayBeEmitted(sourceFile:SourceFile, forceDtsEmit:Bool):Bool;
	function SourceFiles():Array<SourceFile>;
}

interface Host {
	function CommonSourceDirectory():std.String;
	function FileExists(path:std.String):Bool;
	function GetCurrentDirectory():std.String;
	function GetDefaultResolutionModeForFile(file:HasFileName):ResolutionMode;
	function GetGlobalTypingsCacheLocation():std.String;
	function GetModeForUsageLocation(file:HasFileName, moduleSpecifier:StringLiteralLike):ResolutionMode;
	function GetNearestAncestorDirectoryWithPackageJson(dirname:std.String):std.String;
	function GetPackageJsonInfo(pkgJsonPath:std.String):InfoCacheEntry;
	function GetProjectReferenceFromSource(path:Path):SourceOutputAndProjectReference;
	function GetRedirectTargets(path:Path):Array<std.String>;
	function GetResolvedModuleFromModuleSpecifier(file:HasFileName, moduleSpecifier:StringLiteralLike):ResolvedModule;
	function GetSourceOfProjectReferenceIfOutputIncluded(file:HasFileName):std.String;
	function GetSymlinkCache():KnownSymlinks;
	function UseCaseSensitiveFileNames():Bool;
}

@:allow(ts.checker)
class InheritanceInfo {
	var prop:Symbol = null;
	var containingType:Type = null;

	public function new() {}
}

enum abstract UnusedKind(Int) from Int to Int {
	var UnusedKindLocal = 0;
	var UnusedKindParameter = 1;
}

@:allow(ts.checker)
class CallState {
	var node:Node = null;
	var typeArguments:Array<Node> = null;
	var args:Array<Node> = null;
	var candidates:Array<Signature> = null;
	var argCheckMode:CheckMode = 0;
	var isSingleNonGenericCandidate:Bool = false;
	var signatureHelpTrailingComma:Bool = false;
	var candidatesForArgumentError:Array<Signature> = null;
	var candidateForArgumentArityError:Signature = null;
	var candidateForTypeArgumentError:Signature = null;

	public function new() {}
}

enum abstract PredicateSemantics(Int) from Int to Int {
	@:op(A | B) static function or(a:PredicateSemantics, b:PredicateSemantics):PredicateSemantics;
	@:op(A & B) static function and(a:PredicateSemantics, b:PredicateSemantics):PredicateSemantics;
	@:op(~A) static function not(a:PredicateSemantics):PredicateSemantics;

	var PredicateSemanticsNone = 0;
	var PredicateSemanticsAlways = 1 << 0;
	var PredicateSemanticsNever = 1 << 1;
	var PredicateSemanticsSometimes = 3;
}

@:allow(ts.checker)
class ExportCollision {
	var specifierText:std.String = "";
	var exportsWithDuplicate:Array<Node> = null;

	public function new() {}
}

typedef ExportCollisionTable = StringMap<ExportCollision>;

// PORT: Go `type CacheHashKey xxh3.Uint128` is a 128-bit xxh3 hash of the bytes a keyBuilder wrote.
// The go.Xxh3 shim has no 128-bit hash; the key holds the written bytes themselves (packed into a
// string by KeyHasher.Sum), so equal bytes give an equal key and different bytes a different key (in
// Go up to hash collisions). The Go zero value CacheHashKey{} has s == null. `Key()` is the map-key
// encoding of a CacheHashKey (StringMap<…> /* key: checker.CacheHashKey */).
// PORT: perf — an abstract over the string (Go's value type, no object per key).
abstract CacheHashKey(Null<std.String>) {
	public inline function new(?s:std.String) {
		this = s;
	}

	public var s(get, never):Null<std.String>;

	inline function get_s():Null<std.String> {
		return this;
	}

	public inline function IsZero():Bool {
		return this == null;
	}

	public inline function Key():std.String {
		return this == null ? "" : this;
	}

	// PORT: CacheHashKey(xxh3.HashString128(s)): the key of the UTF-8 bytes of s.
	public static function OfString(s:std.String):CacheHashKey {
		final b = new KeyBuilder();
		b.writeString(s);
		return b.hash();
	}
}

// PORT: perf — stands for Go's xxh3.Hasher inside keyBuilder. It collects the written bytes; Sum()
// returns them packed 7 bits per character into one ASCII string (one narrow string on hxcpp, short
// to hash; the former one-char-per-byte StringBuf allocated a buffer per key and made most keys
// UTF-16). The packing is injective: the character count ceil(8n/7) grows strictly with the byte
// count n. Hashers are pooled: a KeyBuilder takes one when created and gives it back in hash(); a
// builder that is dropped without hash() just leaves its hasher to the GC.
@:allow(ts.checker)
class KeyHasher {
	var buf:haxe.io.Bytes = haxe.io.Bytes.alloc(64);
	var n:Int = 0;

	function new() {}

	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — a pool and a packing buffer per thread (go.Par.slot)
	static final pools:Array<Array<KeyHasher>> = [for (_ in 0...go.Par.SLOTS) []];
	static final packeds:Array<haxe.io.Bytes> = [for (_ in 0...go.Par.SLOTS) null];
	static var pool(get, never):Array<KeyHasher>;
	static var packed(get, set):haxe.io.Bytes;

	static inline function get_pool()
		return pools[go.Par.slot];

	static inline function get_packed()
		return packeds[go.Par.slot];

	static inline function set_packed(b:haxe.io.Bytes)
		return packeds[go.Par.slot] = b;

	static function Get():KeyHasher {
		final pool = pool;
		return pool.length > 0 ? pool.pop() : new KeyHasher();
	}
	#else
	static var pool:Array<KeyHasher> = null;
	static var packed:haxe.io.Bytes = null;

	static function Get():KeyHasher {
		if (pool == null)
			pool = [];
		return pool.length > 0 ? pool.pop() : new KeyHasher();
	}
	#end

	inline function WriteByte(c:Int):Void {
		if (n == buf.length)
			grow();
		buf.set(n++, c);
	}

	// room for k more bytes (then Put writes them without a test)
	inline function Reserve(k:Int):Void {
		if (n + k > buf.length)
			grow();
	}

	inline function Put(c:Int):Void {
		buf.set(n++, c);
	}

	function grow():Void {
		final b = haxe.io.Bytes.alloc(buf.length * 2);
		b.blit(0, buf, 0, n);
		buf = b;
	}

	// The packed bytes; the hasher goes back to the pool.
	function Sum():std.String {
		#if (target.name == "hxmc")
		// PORT: perf — hxmc's strings are 16-bit units that need not be valid UTF-16: two bytes per
		// unit and a last unit holding n's parity (injective too), no packing and no UTF-8 decoding.
		final m = (n + 1) >> 1;
		final s = hxmc.rt.Str.make(m + 1);
		final d = hxmc.rt.Str.chars(s);
		final b = buf;
		// PORT: perf — the string's hash as hxmc's StringMap computes it (FNV-1a of the units, 0 → 1), stored in
		// the string while its units are written: the key's map lookup does not hash it again
		var x = 0x811C9DC5;
		var i = 0;
		while (i + 1 < n) {
			final u = b.get(i) | (b.get(i + 1) << 8);
			d.set(i >> 1, u);
			x = (x ^ u) * 16777619;
			i += 2;
		}
		if (i < n) {
			final u = b.get(i);
			d.set(i >> 1, u);
			x = (x ^ u) * 16777619;
		}
		d.set(m, n & 1);
		x = (x ^ (n & 1)) * 16777619;
		hxmc.rt.Repr.storeHash(s, x == 0 ? 1 : x);
		n = 0;
		pool.push(this);
		return s;
		#end
		final m = Std.int((n * 8 + 6) / 7);
		if (packed == null || packed.length < m)
			packed = haxe.io.Bytes.alloc(m < 256 ? 256 : m * 2);
		final p = packed;
		var acc = 0;
		var bits = 0;
		var j = 0;
		for (i in 0...n) {
			acc = ((acc << 8) | buf.get(i)) & 0x7FFF; // at most 6 pending bits + 8 new ones
			bits += 8;
			while (bits >= 7) {
				bits -= 7;
				p.set(j++, (acc >> bits) & 0x7F);
			}
		}
		if (bits > 0)
			p.set(j++, (acc << (7 - bits)) & 0x7F);
		n = 0;
		pool.push(this);
		return Strings.FromASCIIBytes(p, j);
	}
}

@:allow(ts.checker)
// PORT: `h` is a pooled KeyHasher (see there) instead of an xxh3.Hasher; see CacheHashKey.
// Go `var b keyBuilder` → `final b = new KeyBuilder()`. PORT: perf — an abstract over its hasher
// (Go's keyBuilder is a stack value; no object per key). hash() gives the hasher back to the pool:
// the builder must not be used after it.
abstract KeyBuilder(KeyHasher) {
	public inline function new() {
		this = KeyHasher.Get();
	}

	var h(get, never):KeyHasher;

	inline function get_h():KeyHasher {
		return this;
	}

	function hash():CacheHashKey {
		return new CacheHashKey(this.Sum());
	}

	function writeByte(c:Int):Void {
		this.WriteByte(c & 0xFF);
	}

	// Go writes the UTF-8 bytes of s; U+FFFE stands for Go's byte 0xFE (PORTING §5); a lone surrogate
	// is written as its 3-byte WTF-8 form.
	function writeString(s:std.String):Void {
		var i = 0;
		while (i < s.length) {
			var r = go.Utf16.CodePointAt(s, i);
			i += go.Utf16.RuneLen(r);
			if (r < 0x80) {
				this.WriteByte(r);
			} else if (r == 0xFFFE) {
				this.WriteByte(0xFE);
			} else {
				if (r < 0x800) {
					this.WriteByte(0xC0 | (r >> 6));
				} else {
					if (r < 0x10000) {
						this.WriteByte(0xE0 | (r >> 12));
					} else {
						this.WriteByte(0xF0 | (r >> 18));
						this.WriteByte(0x80 | ((r >> 12) & 0x3F));
					}
					this.WriteByte(0x80 | ((r >> 6) & 0x3F));
				}
				this.WriteByte(0x80 | (r & 0x3F));
			}
		}
	}

	function writeInt(value:Int):Void {
		Checker.hashWrite64(this, value);
	}

	function writeSymbol(s:Symbol):Void {
		Checker.hashWrite64(this, Ast.GetSymbolId(s));
	}

	function writeType(t:Type):Void {
		Checker.hashWrite32(this, t.id);
	}

	function writeTypes(types:Array<Type>):Void {
		writeInt(Core.len(types));
		if (types != null) {
			for (t in types) {
				writeType(t);
			}
		}
	}

	function writeAlias(alias:TypeAlias):Void {
		if (alias != null) {
			writeByte(1);
			writeSymbol(alias.symbol);
			writeTypes(alias.typeArguments);
		} else {
			writeByte(0);
		}
	}

	function writeGenericTypeReferences(source:Type, target:Type, ignoreConstraints:Bool):Bool {
		var constrained = false;
		final typeParameters:Array<Type> = [];
		var writeTypeReference:(ref:Type, depth:Int) -> Void = null;
		writeTypeReference = (ref:Type, depth:Int) -> {
			writeType(ref.Target());
			final args = ref.AsTypeReference().resolvedTypeArguments;
			if (args != null) {
				for (t in args) {
					if (t.flags & TypeFlagsTypeParameter != 0) {
						if (ignoreConstraints || t.checker.getConstraintOfTypeParameter(t) == null) {
							var index = typeParameters.indexOf(t);
							if (index < 0) {
								index = typeParameters.length;
								typeParameters.push(t);
							}
							writeByte('='.code);
							writeInt(index);
							continue;
						}
						constrained = true;
					} else if (depth < 4 && Checker.isTypeReferenceWithGenericArguments(t)) {
						writeByte('<'.code);
						writeTypeReference(t, depth + 1);
						writeByte('>'.code);
						continue;
					}
					writeByte('-'.code);
					writeType(t);
				}
			}
		};
		writeTypeReference(source, 0);
		writeByte(','.code);
		writeTypeReference(target, 0);
		return constrained;
	}

	function writeNodeId(id:NodeId):Void {
		Checker.hashWrite64(this, id);
	}

	function writeNode(node:Node):Void {
		if (node != null) {
			writeNodeId(Ast.GetNodeId(node));
		}
	}
}

enum abstract ThisAssignmentDeclarationKind(Int) from Int to Int {
	var thisAssignmentDeclarationNone = 0; // not (all) this.property assignments
	var thisAssignmentDeclarationTyped = 1; // typed; use the type annotation
	var thisAssignmentDeclarationConstructor = 2; // at least one in the constructor; use control flow
	var thisAssignmentDeclarationMethod = 3; // methods only; look in base first, and if not found, union all declaration types plus undefined
}

@:allow(ts.checker)
class TupleNormalizer {
	var c:Checker = null;
	var types:Array<Type> = null;
	var infos:Array<TupleElementInfo> = null;
	var lastRequiredIndex:Int = 0;
	var firstRestIndex:Int = 0;
	var lastOptionalOrRestIndex:Int = 0;

	public function new() {}

	function normalize(c:Checker, elementTypes:Array<Type>, elementInfos:Array<TupleElementInfo>):Bool {
		this.c = c;
		this.lastRequiredIndex = -1;
		this.firstRestIndex = -1;
		this.lastOptionalOrRestIndex = -1;
		if (elementTypes != null) {
			for (i in 0...elementTypes.length) {
				final t = elementTypes[i];
				final info = elementInfos[i];
				if (info.flags & ElementFlagsVariadic != 0) {
					if (t.flags & TypeFlagsAny != 0) {
						this.add(t, newTupleElementInfo(ElementFlagsRest, info.labeledDeclaration));
					} else if (t.flags & TypeFlagsInstantiableNonPrimitive != 0 || c.isGenericMappedType(t)) {
						// Generic variadic elements stay as they are.
						this.add(t, info);
					} else if (Checker.isTupleType(t)) {
						final spreadTypes = c.getElementTypes(t);
						if (Core.len(spreadTypes) + Core.len(this.types) >= 10000) {
							final message = Core.IfElse(Ast.IsPartOfTypeNode(c.currentNode),
								Diagnostics.Type_produces_a_tuple_type_that_is_too_large_to_represent,
								Diagnostics.Expression_produces_a_tuple_type_that_is_too_large_to_represent);
							c.error(c.currentNode, message);
							return false;
						}
						// Spread variadic elements with tuple types into the resulting tuple.
						final spreadInfos = t.TargetTupleType().elementInfos;
						if (spreadTypes != null) {
							for (j in 0...spreadTypes.length) {
								this.add(spreadTypes[j], spreadInfos[j]);
							}
						}
					} else {
						// Treat everything else as an array type and create a rest element.
						var s:Type = null;
						if (c.isArrayLikeType(t)) {
							s = c.getIndexTypeOfType(t, c.numberType);
						}
						if (s == null) {
							s = c.errorType;
						}
						this.add(s, newTupleElementInfo(ElementFlagsRest, info.labeledDeclaration));
					}
				} else {
					// Copy other element kinds with no change.
					this.add(t, info);
				}
			}
		}
		// Turn optional elements preceding the last required element into required elements
		for (i in 0...this.lastRequiredIndex) {
			if (this.infos[i].flags & ElementFlagsOptional != 0) {
				this.infos[i].flags = ElementFlagsRequired;
			}
		}
		if (this.firstRestIndex >= 0 && this.firstRestIndex < this.lastOptionalOrRestIndex) {
			// Turn elements between first rest and last optional/rest into a single rest element
			var types:Array<Type> = null;
			var i = this.firstRestIndex;
			while (i <= this.lastOptionalOrRestIndex) {
				var t = this.types[i];
				if (this.infos[i].flags & ElementFlagsVariadic != 0) {
					t = c.getIndexedAccessType(t, c.numberType);
				}
				if (types == null) {
					types = [];
				}
				types.push(t);
				i++;
			}
			this.types[this.firstRestIndex] = c.getUnionType(types);
			this.types.splice(this.firstRestIndex + 1, this.lastOptionalOrRestIndex - this.firstRestIndex);
			this.infos.splice(this.firstRestIndex + 1, this.lastOptionalOrRestIndex - this.firstRestIndex);
		}
		return true;
	}

	// PORT: TupleElementInfo is a Go value type; `n.infos` holds copies, because normalize mutates them.
	static function newTupleElementInfo(flags:ElementFlags, labeledDeclaration:Node):TupleElementInfo {
		final info = new TupleElementInfo();
		info.flags = flags;
		info.labeledDeclaration = labeledDeclaration;
		return info;
	}

	function add(t:Type, info:TupleElementInfo):Void {
		if (info.flags & ElementFlagsRequired != 0) {
			this.lastRequiredIndex = Core.len(this.types);
		}
		if (info.flags & ElementFlagsRest != 0 && this.firstRestIndex < 0) {
			this.firstRestIndex = Core.len(this.types);
		}
		if (info.flags & (ElementFlagsOptional | ElementFlagsRest) != 0) {
			this.lastOptionalOrRestIndex = Core.len(this.types);
		}
		if (this.types == null) {
			this.types = [];
		}
		if (this.infos == null) {
			this.infos = [];
		}
		this.types.push(this.c.addOptionalityEx(t, true /*isProperty*/, info.flags & ElementFlagsOptional != 0));
		this.infos.push(newTupleElementInfo(info.flags, info.labeledDeclaration));
	}
}

enum abstract UnionReduction(Int) from Int to Int {
	var UnionReductionNone = 0;
	var UnionReductionLiteral = 1;
	var UnionReductionSubtype = 2;
}

enum abstract IntersectionFlags(Int) from Int to Int {
	@:op(A | B) static function or(a:IntersectionFlags, b:IntersectionFlags):IntersectionFlags;
	@:op(A & B) static function and(a:IntersectionFlags, b:IntersectionFlags):IntersectionFlags;
	@:op(~A) static function not(a:IntersectionFlags):IntersectionFlags;

	var IntersectionFlagsNone = 0;
	var IntersectionFlagsNoSupertypeReduction = 1 << 0;
	var IntersectionFlagsNoConstraintReduction = 1 << 1;
}

@:allow(ts.checker)
class ObjectLiteralDiscriminator implements Discriminator {
	var c:Checker = null;
	var props:Array<Node> = null;
	var members:Array<Symbol> = null;

	public function new() {}

	public function len():Int {
		return Core.len(this.props) + Core.len(this.members);
	}

	public function name(index:Int):std.String {
		if (index < Core.len(this.props)) {
			return this.props[index].Symbol().Name;
		}
		return this.members[index - Core.len(this.props)].Name;
	}

	public function matches(index:Int, t:Type):Bool {
		var propType:Type = null;
		if (index < Core.len(this.props)) {
			final prop = this.props[index];
			if (Ast.IsPropertyAssignment(prop) || Ast.IsJsxAttribute(prop)) {
				final initializer = prop.Initializer();
				if (initializer != null) {
					propType = this.c.getContextFreeTypeOfExpression(prop.Initializer());
				} else {
					propType = this.c.trueType; // JsxAttribute without initializer is always true
				}
			} else {
				propType = this.c.getContextFreeTypeOfExpression(prop.Name());
			}
		} else {
			propType = this.c.undefinedType;
		}
		for (s in propType.Distributed()) {
			if (this.c.isTypeAssignableTo(s, t)) {
				return true;
			}
		}
		return false;
	}
}

@:allow(ts.checker)
class Checker {
	// --- checker.go ---

	var id:Int = 0;
	var program:Program = null;
	var compilerOptions:CompilerOptions = null;
	var files:Array<SourceFile> = null;
	var fileIndexMap:IdentityMap<SourceFile, Int> = null;
	var compareSymbols:(Symbol, Symbol) -> Int = null;
	var compareSymbolChains:(Array<Symbol>, Array<Symbol>) -> Int = null;
	public var TypeCount:Int = 0;
	public var SymbolCount:Int = 0;
	public var SignatureCount:Int = 0;
	public var TotalInstantiationCount:Int = 0;
	var instantiationCount:Int = 0;
	var instantiationDepth:Int = 0;
	var conditionalConstraintDepth:Int = 0;
	var inlineLevel:Int = 0;
	var serializationLevel:Int = 0;
	var currentNode:Node = null;
	var varianceTypeParameter:Type = null;
	var languageVersion:ScriptTarget = 0;
	var moduleKind:ModuleKind = 0;
	var moduleResolutionKind:ModuleResolutionKind = 0;
	var isInferencePartiallyBlocked:Bool = false;
	var legacyDecorators:Bool = false;
	var emitStandardClassFields:Bool = false;
	var strictNullChecks:Bool = false;
	var strictFunctionTypes:Bool = false;
	var strictBindCallApply:Bool = false;
	var strictPropertyInitialization:Bool = false;
	var strictBuiltinIteratorReturn:Bool = false;
	var noImplicitAny:Bool = false;
	var noImplicitThis:Bool = false;
	var useUnknownInCatchVariables:Bool = false;
	var exactOptionalPropertyTypes:Bool = false;
	var canCollectSymbolAliasAccessibilityData:Bool = false;
	var wasCanceled:Bool = false;
	var saveDeferredDiagnostics:Bool = false;
	var arrayVariances:Array<VarianceFlags> = null;
	var globals:SymbolTable = null;
	var evaluate:Evaluator_ = null; // PORT: Go evaluator.Evaluator is the func type Evaluator_
	var stringLiteralTypes:StringMap<Type> = null;
	var numberLiteralTypes:StringMap<Type> /* key: Checker.numberLiteralKey(jsnum.Number) */ = null;
	var nanType:Type = null;
	var bigintLiteralTypes:StringMap<Type> /* key: jsnum.PseudoBigInt, encoded by PseudoBigInt.String() */ = null;
	var enumLiteralTypes:StringMap<Type> /* key: checker.EnumLiteralKey */ = null;
	var enumNaNLiteralTypes:IdentityMap<Symbol, Type> = null;
	var indexedAccessTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var templateLiteralTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var stringMappingTypes:StringMap<Type> /* key: checker.StringMappingKey */ = null;
	var uniqueESSymbolTypes:IdentityMap<Symbol, Type> = null;
	var thisExpandoKinds:IdentityMap<Symbol, ThisAssignmentDeclarationKind> = null;
	var thisExpandoLocations:IdentityMap<Symbol, Node> = null;
	var subtypeReductionCache:StringMap<Array<Type>> /* key: checker.CacheHashKey */ = null;
	var cachedTypes:StringMap<Type> /* key: checker.CachedTypeKey */ = null;
	var cachedSignatures:StringMap<Signature> /* key: checker.CachedSignatureKey */ = null;
	var undefinedProperties:StringMap<Symbol> = null;
	var narrowedTypes:StringMap<Type> /* key: checker.NarrowedTypeKey */ = null;
	var assignmentReducedTypes:StringMap<Type> /* key: checker.AssignmentReducedKey */ = null;
	var discriminatedContextualTypes:StringMap<Type> /* key: checker.DiscriminatedContextualTypeKey */ = null;
	var instantiationExpressionTypes:StringMap<Type> /* key: checker.InstantiationExpressionKey */ = null;
	var substitutionTypes:StringMap<Type> /* key: checker.SubstitutionTypeKey */ = null;
	var reverseMappedCache:StringMap<Type> /* key: checker.ReverseMappedTypeKey */ = null;
	var reverseHomomorphicMappedCache:StringMap<Type> /* key: checker.ReverseMappedTypeKey */ = null;
	var iterationTypesCache:StringMap<IterationTypes> /* key: checker.IterationTypesKey */ = null;
	var markerTypes:Set<Type> = new Set<Type>();
	var undefinedSymbol:Symbol = null;
	var argumentsSymbol:Symbol = null;
	var requireSymbol:Symbol = null;
	var unknownSymbol:Symbol = null;
	var unresolvedSymbols:StringMap<Symbol> = null;
	var errorTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var moduleSymbols:IdentityMap<Node, Symbol> = null;
	var globalThisSymbol:Symbol = null;
	var symbolTableAliasCache:IntMap<Array<Symbol>> = null;
	var classExpressionNameTables:IntMap<SymbolTable> = null;
	// PORT: perf — second result (includes) of addTypesToUnion/addTypeToUnion, read by the caller right after the call.
	var addTypesToUnionIncludes:TypeFlags = 0;
	// PORT: perf — second result (location) of isConstructorDeclaredThisProperty, read by the caller right after the call.
	var isConstructorDeclaredThisPropertyLocation:Node = null;
	// PORT: perf (typed resolver hooks instead of Go func fields): Go's func fields resolveName and
	// resolveNameForSymbolSuggestion (= the Resolve method values) are direct calls on the two resolvers. A function value
	// with six arguments packs them into an Array per call on hxcpp.
	var nameResolver:NameResolver = null;
	var suggestionNameResolver:NameResolver = null;

	inline function resolveName(location:Node, name:std.String, meaning:SymbolFlags, nameNotFoundMessage:Message, isUse:Bool, excludeGlobals:Bool):Symbol {
		return nameResolver.Resolve(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals);
	}

	inline function resolveNameForSymbolSuggestion(location:Node, name:std.String, meaning:SymbolFlags, nameNotFoundMessage:Message, isUse:Bool,
			excludeGlobals:Bool):Symbol {
		return suggestionNameResolver.Resolve(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals);
	}

	var tupleTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var unionTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var unionOfUnionTypes:StringMap<Type> /* key: checker.UnionOfUnionKey */ = null;
	var intersectionTypes:StringMap<Type> /* key: checker.CacheHashKey */ = null;
	var propertiesTypes:StringMap<Type> /* key: checker.PropertiesTypesKey */ = null;
	var diagnostics:DiagnosticsCollection = new DiagnosticsCollection();
	var suggestionDiagnostics:DiagnosticsCollection = new DiagnosticsCollection();
	var symbolArena:Arena<Symbol> = new Arena<Symbol>(() -> new Symbol());
	var signatureArena:Arena<Signature> = new Arena<Signature>(() -> new Signature());
	var indexInfoArena:Arena<IndexInfo> = new Arena<IndexInfo>(() -> new IndexInfo());
	var mergedSymbols:IdentityMap<Symbol, Symbol> = null;
	var factory:NodeFactory = new NodeFactory();
	var nodeLinks:LinkStore<Node, NodeLinks> = new LinkStore<Node, NodeLinks>(() -> new NodeLinks());
	var signatureLinks:LinkStore<Node, SignatureLinks> = new LinkStore<Node, SignatureLinks>(() -> new SignatureLinks());
	var symbolNodeLinks:LinkStore<Node, SymbolNodeLinks> = new LinkStore<Node, SymbolNodeLinks>(() -> new SymbolNodeLinks());
	var typeNodeLinks:LinkStore<Node, TypeNodeLinks> = new LinkStore<Node, TypeNodeLinks>(() -> new TypeNodeLinks());
	var enumMemberLinks:LinkStore<Node, EnumMemberLinks> = new LinkStore<Node, EnumMemberLinks>(() -> new EnumMemberLinks());
	var assertionLinks:LinkStore<Node, AssertionLinks> = new LinkStore<Node, AssertionLinks>(() -> new AssertionLinks());
	var arrayLiteralLinks:LinkStore<Node, ArrayLiteralLinks> = new LinkStore<Node, ArrayLiteralLinks>(() -> new ArrayLiteralLinks());
	var switchStatementLinks:LinkStore<Node, SwitchStatementLinks> = new LinkStore<Node, SwitchStatementLinks>(() -> new SwitchStatementLinks());
	var jsxElementLinks:LinkStore<Node, JsxElementLinks> = new LinkStore<Node, JsxElementLinks>(() -> new JsxElementLinks());
	var symbolReferenceLinks:LinkStore<Symbol, SymbolReferenceLinks> = new LinkStore<Symbol, SymbolReferenceLinks>(() -> new SymbolReferenceLinks());
	var valueSymbolLinks:LinkStore<Symbol, ValueSymbolLinks> = new LinkStore<Symbol, ValueSymbolLinks>(() -> new ValueSymbolLinks());
	var mappedSymbolLinks:LinkStore<Symbol, MappedSymbolLinks> = new LinkStore<Symbol, MappedSymbolLinks>(() -> new MappedSymbolLinks());
	var deferredSymbolLinks:LinkStore<Symbol, DeferredSymbolLinks> = new LinkStore<Symbol, DeferredSymbolLinks>(() -> new DeferredSymbolLinks());
	var aliasSymbolLinks:LinkStore<Symbol, AliasSymbolLinks> = new LinkStore<Symbol, AliasSymbolLinks>(() -> new AliasSymbolLinks());
	var moduleSymbolLinks:LinkStore<Symbol, ModuleSymbolLinks> = new LinkStore<Symbol, ModuleSymbolLinks>(() -> new ModuleSymbolLinks());
	var lateBoundLinks:LinkStore<Symbol, LateBoundLinks> = new LinkStore<Symbol, LateBoundLinks>(() -> new LateBoundLinks());
	var exportTypeLinks:LinkStore<Symbol, ExportTypeLinks> = new LinkStore<Symbol, ExportTypeLinks>(() -> new ExportTypeLinks());
	var membersAndExportsLinks:LinkStore<Symbol, MembersAndExportsLinks> = new LinkStore<Symbol, MembersAndExportsLinks>(() -> [for (_ in 0...2) null]);
	var typeAliasLinks:LinkStore<Symbol, TypeAliasLinks> = new LinkStore<Symbol, TypeAliasLinks>(() -> new TypeAliasLinks());
	var declaredTypeLinks:LinkStore<Symbol, DeclaredTypeLinks> = new LinkStore<Symbol, DeclaredTypeLinks>(() -> new DeclaredTypeLinks());
	var spreadLinks:LinkStore<Symbol, SpreadLinks> = new LinkStore<Symbol, SpreadLinks>(() -> new SpreadLinks());
	var varianceLinks:LinkStore<Symbol, VarianceLinks> = new LinkStore<Symbol, VarianceLinks>(() -> new VarianceLinks());
	public var ReverseMappedSymbolLinks:LinkStore<Symbol, ReverseMappedSymbolLinks> = new LinkStore<Symbol, ReverseMappedSymbolLinks>(() -> new ReverseMappedSymbolLinks());
	var markedAssignmentSymbolLinks:LinkStore<Symbol, MarkedAssignmentSymbolLinks> = new LinkStore<Symbol, MarkedAssignmentSymbolLinks>(() -> new MarkedAssignmentSymbolLinks());
	var symbolContainerLinks:LinkStore<Symbol, ContainingSymbolLinks> = new LinkStore<Symbol, ContainingSymbolLinks>(() -> new ContainingSymbolLinks());
	var sourceFileLinks:LinkStore<SourceFile, SourceFileLinks> = new LinkStore<SourceFile, SourceFileLinks>(() -> new SourceFileLinks());
	var regExpScanner:Scanner = null;
	var patternForType:IdentityMap<Type, Node> = null;
	var contextFreeTypes:IdentityMap<Node, Type> = null;
	var anyType:Type = null;
	var autoType:Type = null;
	var wildcardType:Type = null;
	var blockedStringType:Type = null;
	var errorType:Type = null;
	var unresolvedType:Type = null;
	var nonInferrableAnyType:Type = null;
	var intrinsicMarkerType:Type = null;
	var unknownType:Type = null;
	var undefinedType:Type = null;
	var undefinedWideningType:Type = null;
	var missingType:Type = null;
	var undefinedOrMissingType:Type = null;
	var optionalType:Type = null;
	var nullType:Type = null;
	var nullWideningType:Type = null;
	var stringType:Type = null;
	var numberType:Type = null;
	var bigintType:Type = null;
	var regularFalseType:Type = null;
	var falseType:Type = null;
	var regularTrueType:Type = null;
	var trueType:Type = null;
	var booleanType:Type = null;
	var esSymbolType:Type = null;
	var voidType:Type = null;
	var neverType:Type = null;
	var silentNeverType:Type = null;
	var implicitNeverType:Type = null;
	var unreachableNeverType:Type = null;
	var nonPrimitiveType:Type = null;
	var stringOrNumberType:Type = null;
	var stringNumberSymbolType:Type = null;
	var numberOrBigIntType:Type = null;
	var templateConstraintType:Type = null;
	var numericStringType:Type = null;
	var uniqueLiteralType:Type = null;
	var uniqueLiteralMapper:TypeMapper = null;
	var reliabilityFlags:RelationComparisonResult = 0;
	var reportUnreliableMapper:TypeMapper = null;
	var reportUnmeasurableMapper:TypeMapper = null;
	var restrictiveMapper:TypeMapper = null;
	var permissiveMapper:TypeMapper = null;
	var emptyObjectType:Type = null;
	var emptyJsxObjectType:Type = null;
	var emptyFreshJsxObjectType:Type = null;
	var emptyTypeLiteralType:Type = null;
	var unknownEmptyObjectType:Type = null;
	var unknownUnionType:Type = null;
	var emptyGenericType:Type = null;
	var anyFunctionType:Type = null;
	var noConstraintType:Type = null;
	var circularConstraintType:Type = null;
	var resolvingDefaultType:Type = null;
	var markerSuperType:Type = null;
	var markerSubType:Type = null;
	var markerOtherType:Type = null;
	var markerSuperTypeForCheck:Type = null;
	var markerSubTypeForCheck:Type = null;
	var noTypePredicate:TypePredicate = null;
	var anySignature:Signature = null;
	var unknownSignature:Signature = null;
	var resolvingSignature:Signature = null;
	var silentNeverSignature:Signature = null;
	var cachedArgumentsReferenced:IdentityMap<Node, Bool> = null;
	var enumNumberIndexInfo:IndexInfo = null;
	var anyBaseTypeIndexInfo:IndexInfo = null;
	var patternAmbientModules:Array<PatternAmbientModule> = null;
	var patternAmbientModuleAugmentations:SymbolTable = null;
	var globalObjectType:Type = null;
	var globalFunctionType:Type = null;
	var globalCallableFunctionType:Type = null;
	var globalNewableFunctionType:Type = null;
	var globalArrayType:Type = null;
	var globalReadonlyArrayType:Type = null;
	var globalStringType:Type = null;
	var globalNumberType:Type = null;
	var globalBooleanType:Type = null;
	var globalRegExpType:Type = null;
	var globalThisType:Type = null;
	var anyArrayType:Type = null;
	var autoArrayType:Type = null;
	var anyReadonlyArrayType:Type = null;
	var deferredGlobalImportMetaExpressionType:Type = null;
	var contextualBindingPatterns:Array<Node> = null;
	var emptyStringType:Type = null;
	var zeroType:Type = null;
	var zeroBigIntType:Type = null;
	var typeofType:Type = null;
	var typeResolutions:Array<TypeResolution> = null;
	var resolutionStart:Int = 0;
	var inVarianceComputation:Bool = false;
	var apparentArgumentCount:Null<Int> /* PORT: pointer */ = null;
	var lastGetCombinedNodeFlagsNode:Node = null;
	var lastGetCombinedNodeFlagsResult:NodeFlags = 0;
	var lastGetCombinedModifierFlagsNode:Node = null;
	var lastGetCombinedModifierFlagsResult:ModifierFlags = 0;
	var freeinferenceState:InferenceState = null;
	var freeFlowState:FlowState = null;
	var flowLoopCache:StringMap<Type> /* key: checker.FlowLoopKey */ = null;
	var flowLoopStack:Array<FlowLoopInfo> = null;
	var sharedFlows:Array<SharedFlow> = null;
	var sharedFlowsLen:Int = 0; // PORT: perf — len(c.sharedFlows); the array keeps its objects past it (see Flow)
	var antecedentTypes:Array<Type> = null;
	var flowAnalysisDisabled:Bool = false;
	var flowInvocationCount:Int = 0;
	var flowTypeCache:IdentityMap<Node, Type> = null;
	var lastFlowNode:FlowNode = null;
	var lastFlowNodeReachable:Bool = false;
	var flowNodeReachable:IdentityMap<FlowNode, Bool> = null;
	var flowNodePostSuper:IdentityMap<FlowNode, Bool> = null;
	var renamedBindingElementsInTypes:Array<Node> = null;
	var contextualInfos:Array<ContextualInfo> = null;
	var inferenceContextInfos:Array<InferenceContextInfo> = null;
	var awaitedTypeStack:Array<Type> = null;
	var reverseMappedSourceStack:Array<Type> = null;
	var reverseMappedTargetStack:Array<Type> = null;
	var reverseExpandingFlags:ExpandingFlags = 0;
	var freeRelater:Relater = null;
	var subtypeRelation:Relation = null;
	var strictSubtypeRelation:Relation = null;
	var assignableRelation:Relation = null;
	var comparableRelation:Relation = null;
	var identityRelation:Relation = null;
	var enumRelation:StringMap<RelationComparisonResult> /* key: checker.EnumRelationKey */ = null;
	var getGlobalESSymbolType:() -> Type = null;
	var getGlobalBigIntType:() -> Type = null;
	var getGlobalImportMetaType:() -> Type = null;
	var getGlobalImportAttributesType:() -> Type = null;
	var getGlobalImportAttributesTypeChecked:() -> Type = null;
	var getGlobalNonNullableTypeAliasOrNil:() -> Symbol = null;
	var getGlobalExtractSymbol:() -> Symbol = null;
	var getGlobalDisposableType:() -> Type = null;
	var getGlobalAsyncDisposableType:() -> Type = null;
	var getGlobalAwaitedSymbol:() -> Symbol = null;
	var getGlobalAwaitedSymbolOrNil:() -> Symbol = null;
	var getGlobalNaNSymbolOrNil:() -> Symbol = null;
	var getGlobalRecordSymbol:() -> Symbol = null;
	var getGlobalTemplateStringsArrayType:() -> Type = null;
	var getGlobalESSymbolConstructorSymbolOrNil:() -> Symbol = null;
	var getGlobalESSymbolConstructorTypeSymbolOrNil:() -> Symbol = null;
	var getGlobalImportCallOptionsType:() -> Type = null;
	var getGlobalImportCallOptionsTypeChecked:() -> Type = null;
	var getGlobalPromiseType:() -> Type = null;
	var getGlobalPromiseTypeChecked:() -> Type = null;
	var getGlobalPromiseLikeType:() -> Type = null;
	var getGlobalPromiseConstructorSymbol:() -> Symbol = null;
	var getGlobalPromiseConstructorSymbolOrNil:() -> Symbol = null;
	var getGlobalOmitSymbol:() -> Symbol = null;
	var getGlobalNoInferSymbolOrNil:() -> Symbol = null;
	var getGlobalIteratorType:() -> Type = null;
	var getGlobalIterableType:() -> Type = null;
	var getGlobalIterableTypeChecked:() -> Type = null;
	var getGlobalIterableIteratorType:() -> Type = null;
	var getGlobalIterableIteratorTypeChecked:() -> Type = null;
	var getGlobalIteratorObjectType:() -> Type = null;
	var getGlobalGeneratorType:() -> Type = null;
	var getGlobalAsyncIteratorType:() -> Type = null;
	var getGlobalAsyncIterableType:() -> Type = null;
	var getGlobalAsyncIterableTypeChecked:() -> Type = null;
	var getGlobalAsyncIterableIteratorType:() -> Type = null;
	var getGlobalAsyncIterableIteratorTypeChecked:() -> Type = null;
	var getGlobalAsyncIteratorObjectType:() -> Type = null;
	var getGlobalAsyncGeneratorType:() -> Type = null;
	var getGlobalIteratorYieldResultType:() -> Type = null;
	var getGlobalIteratorReturnResultType:() -> Type = null;
	var getGlobalTypedPropertyDescriptorType:() -> Type = null;
	var getGlobalClassDecoratorContextType:() -> Type = null;
	var getGlobalClassMethodDecoratorContextType:() -> Type = null;
	var getGlobalClassGetterDecoratorContextType:() -> Type = null;
	var getGlobalClassSetterDecoratorContextType:() -> Type = null;
	var getGlobalClassAccessorDecoratorContxtType:() -> Type = null;
	var getGlobalClassAccessorDecoratorContextType:() -> Type = null;
	var getGlobalClassAccessorDecoratorTargetType:() -> Type = null;
	var getGlobalClassAccessorDecoratorResultType:() -> Type = null;
	var getGlobalClassFieldDecoratorContextType:() -> Type = null;
	var syncIterationTypesResolver:IterationTypesResolver = null;
	var asyncIterationTypesResolver:IterationTypesResolver = null;
	var isPrimitiveOrObjectOrEmptyType:(Type) -> Bool = null;
	var containsMissingType:(Type) -> Bool = null;
	var couldContainTypeVariables:(Type) -> Bool = null;
	var isStringIndexSignatureOnlyType:(Type) -> Bool = null;
	var markNodeAssignments:(Node) -> Bool = null;
	var compareTypesAssignable:TypeComparer = null;
	var emitResolver:EmitResolver = null;
	var emitResolverOnce:Any /* sync.Once */ = null /* PORT: Go zero struct */;
	var _jsxNamespace:std.String = "";
	var _jsxFactoryEntity:Node = null;
	var skipDirectInferenceNodes:Set<Node> = new Set<Node>();
	var ctx:Context = null;
	var packagesMap:StringMap<Bool> = null;
	var activeMappers:Array<TypeMapper> = null;
	var activeTypeMappersCaches:Array<StringMap<Type> /* key: checker.CacheHashKey */> = null;
	var ambientModulesOnce:Any /* sync.Once */ = null /* PORT: Go zero struct */;
	var ambientModules:Array<Symbol> = null;
	var withinUnreachableCode:Bool = false;
	var reportedUnreachableNodes:Set<Node> = new Set<Node>();
	var nonExistentProperties:Set<std.String> /* key: NonExistentPropertyKey.keyOf */ = new Set<std.String>();
	var deferredDiagnosticCallbacks:Array<() -> Void> = null;
	var typeToStringNodebuilder:NodeBuilder = null;
	var mu:Any /* sync.Mutex */ = null /* PORT: Go zero struct */;
	var tracer:Tracer = null; // Optional tracer for trace events and type recording (for --generateTrace)
	// PORT: identity numbers for pointer fields of struct map keys (see EnumLiteralKey); not in Go.
	var identityKeys:IdentityMap<{}, Int> = new IdentityMap<{}, Int>();
	var identityKeyCount:Int = 0;

	public function new() {}

	// PORT: struct map keys — checker-local identity number of a pointer (0 for nil); see EnumLiteralKey.
	public static function identityKeyOf(c:Checker, o:{}):Int {
		if (o == null) {
			return 0;
		}
		var id = c.identityKeys.get(o);
		if (id == null) {
			id = 0;
		}
		if (id == 0) {
			id = ++c.identityKeyCount;
			c.identityKeys.set(o, id);
		}
		return id;
	}

	// PORT: struct map keys — a *Type field is encoded by its id (0 for nil).
	public static inline function typeKeyOf(t:Type):Int {
		return t == null ? 0 : t.id;
	}

	// PORT: map[jsnum.Number] key: the JS string of the number (+0 and -0 are one key, as in Go;
	// NaN never reaches the map, callers cache it separately).
	public static function numberLiteralKey(n:Number):std.String {
		return ts.jsnum.String_.String(n);
	}

	// PORT: method values created once (PORTING.md §7a).
	static final fn_nodeImmediatelyReferencesSuperOrThis:(Node) -> Bool = n -> nodeImmediatelyReferencesSuperOrThis(n);
	static final fn_isThislessType:(Node) -> Bool = n -> isThislessType(n);
	static final fn_isThislessVariableLikeDeclaration:(Node) -> Bool = n -> isThislessVariableLikeDeclaration(n);
	static final fn_isThislessTypeParameter:(Node) -> Bool = n -> isThislessTypeParameter(n);
	static final fn_isTypeAlias:(Node) -> Bool = n -> isTypeAlias(n);
	static final fn_isUnitType:(Type) -> Bool = t -> isUnitType(t);
	static final fn_GetTextOfNode:(Node) -> std.String = n -> Scanner.GetTextOfNode(n);
	static final fn_IsImportDeclaration:(Node) -> Bool = n -> Ast.IsImportDeclaration(n);
	static final fn_IsSetAccessorDeclaration:(Node) -> Bool = n -> Ast.IsSetAccessorDeclaration(n);
	static final fn_IsGetAccessorDeclaration:(Node) -> Bool = n -> Ast.IsGetAccessorDeclaration(n);
	static final fn_IsFunctionLikeOrClassStaticBlockDeclaration:(Node) -> Bool = n -> Ast.IsFunctionLikeOrClassStaticBlockDeclaration(n);
	static final fn_markAsSynthetic:(Node) -> Bool = n -> markAsSynthetic(n);
	static final fn_IsClassLike:(Node) -> Bool = n -> Ast.IsClassLike(n);
	static final fn_isExcessPropertyCheckTarget:(Type) -> Bool = t -> isExcessPropertyCheckTarget(t);
	static final fn_IsCallLikeExpression:(Node) -> Bool = n -> Ast.IsCallLikeExpression(n);
	static final fn_IsCallLikeOrFunctionLikeExpression:(Node) -> Bool = n -> Ast.IsCallLikeOrFunctionLikeExpression(n);

	// PORT: Go symbolTableID is a uint64 `kind<<61 | id`; Haxe Int is 32 bits. The ID is encoded as
	// `id << 3 | kind` with the SymbolTableID kind constants 0..4 (Symbolaccessibility.hx); stKindMask = 4
	// reproduces Go's mask, which keeps only the top kind bit.
	static inline function symbolTableIDOf(kind:SymbolTableID, id:Int):SymbolTableID {
		return (id << 3) | (kind : Int);
	}

	// cmp.Compare for jsnum.Number (float64): NaN sorts before every other value.
	static function compareNumbers(x:Float, y:Float):Int {
		final xNaN = std.Math.isNaN(x);
		final yNaN = std.Math.isNaN(y);
		if (xNaN) {
			return yNaN ? 0 : -1;
		}
		if (yNaN) {
			return 1;
		}
		return x < y ? -1 : (x > y ? 1 : 0);
	}

	// PORT: Go composite literal DiagnosticDetails{Message, Args}.
	static function newDiagnosticDetails(message:Message, args:Array<Any>):DiagnosticDetails {
		final d = new DiagnosticDetails();
		d.Message = message;
		d.Args = args;
		return d;
	}

	// PORT: CacheHashKey(xxh3.HashString128(s)) → CacheHashKey.OfString(s) (see CacheHashKey).
	public static final SignatureKeyErased:CacheHashKey = CacheHashKey.OfString("-");

	public static final SignatureKeyCanonical:CacheHashKey = CacheHashKey.OfString("*");

	public static final SignatureKeyBase:CacheHashKey = CacheHashKey.OfString("#");

	public static final SignatureKeyInner:CacheHashKey = CacheHashKey.OfString("<");

	public static final SignatureKeyOuter:CacheHashKey = CacheHashKey.OfString(">");

	static var intrinsicTypeKinds:StringMap<IntrinsicTypeKind> = {
		final m = new StringMap<IntrinsicTypeKind>();
		m.set("Uppercase", IntrinsicTypeKindUppercase);
		m.set("Lowercase", IntrinsicTypeKindLowercase);
		m.set("Capitalize", IntrinsicTypeKindCapitalize);
		m.set("Uncapitalize", IntrinsicTypeKindUncapitalize);
		m.set("NoInfer", IntrinsicTypeKindNoInfer);
		m;
	};

	static inline final maxSerializationLevel:Int = 2;

	static var nextCheckerID:Int = 0; // PORT: atomic.Uint32 → Int (single-threaded)
	#if tshx_parallel
	static final checkerIDs = new haxe.atomic.AtomicInt(0);
	#end

	public static function NewChecker(program:Program, tracer:Tracer):Pair<Checker, Any /* sync.Mutex */> {
		program.BindSourceFiles();

		final c = new Checker();
		#if tshx_parallel
		c.id = checkerIDs.add(1) + 1; // PORT: hxmc (-D tshx-parallel) — atomic.Uint32.Add
		#else
		c.id = ++nextCheckerID;
		#end
		c.tracer = tracer;
		c.program = program;
		c.compilerOptions = program.Options();
		c.files = program.SourceFiles();
		c.fileIndexMap = createFileIndexMap(c.files);
		// Closure optimization. PORT: perf — every caller uses only the sign; a result in -1..1 is
		// returned unboxed by an hxcpp function value (larger Ints are allocated per call).
		c.compareSymbols = (s1, s2) -> {
			final r = c.compareSymbolsWorker(s1, s2);
			r < 0 ? -1 : (r > 0 ? 1 : 0);
		};
		c.compareSymbolChains = (a, b) -> c.compareSymbolChainsWorker(a, b); // Closure optimization
		c.languageVersion = c.compilerOptions.GetEmitScriptTarget();
		c.moduleKind = c.compilerOptions.GetEmitModuleKind();
		c.moduleResolutionKind = c.compilerOptions.GetModuleResolutionKind();
		c.legacyDecorators = c.compilerOptions.ExperimentalDecorators == TSTrue;
		c.emitStandardClassFields = c.compilerOptions.GetEmitStandardClassFields();
		c.strictNullChecks = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.StrictNullChecks);
		c.strictFunctionTypes = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.StrictFunctionTypes);
		c.strictBindCallApply = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.StrictBindCallApply);
		c.strictPropertyInitialization = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.StrictPropertyInitialization);
		c.strictBuiltinIteratorReturn = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.StrictBuiltinIteratorReturn);
		c.noImplicitAny = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.NoImplicitAny);
		c.noImplicitThis = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.NoImplicitThis);
		c.useUnknownInCatchVariables = c.compilerOptions.GetStrictOptionValue(c.compilerOptions.UseUnknownInCatchVariables);
		c.exactOptionalPropertyTypes = c.compilerOptions.ExactOptionalPropertyTypes == TSTrue;
		c.canCollectSymbolAliasAccessibilityData = c.compilerOptions.VerbatimModuleSyntax.IsFalseOrUnknown();
		c.arrayVariances = [VarianceFlagsCovariant];
		// PORT: Go passes countGlobalSymbols(c.files) as a map capacity hint only.
		c.globals = new SymbolTable();
		c.evaluate = Evaluator.NewEvaluator((expr, location) -> c.evaluateEntity(expr, location), OEKParentheses);
		c.stringLiteralTypes = new StringMap<Type>();
		c.numberLiteralTypes = new StringMap<Type>();
		c.bigintLiteralTypes = new StringMap<Type>();
		c.enumLiteralTypes = new StringMap<Type>();
		c.enumNaNLiteralTypes = new IdentityMap<Symbol, Type>();
		c.indexedAccessTypes = new StringMap<Type>();
		c.templateLiteralTypes = new StringMap<Type>();
		c.stringMappingTypes = new StringMap<Type>();
		c.uniqueESSymbolTypes = new IdentityMap<Symbol, Type>();
		c.thisExpandoKinds = new IdentityMap<Symbol, ThisAssignmentDeclarationKind>();
		c.thisExpandoLocations = new IdentityMap<Symbol, Node>();
		c.subtypeReductionCache = new StringMap<Array<Type>>();
		c.cachedTypes = new StringMap<Type>();
		c.cachedSignatures = new StringMap<Signature>();
		c.undefinedProperties = new StringMap<Symbol>();
		c.narrowedTypes = new StringMap<Type>();
		c.assignmentReducedTypes = new StringMap<Type>();
		c.discriminatedContextualTypes = new StringMap<Type>();
		c.instantiationExpressionTypes = new StringMap<Type>();
		c.substitutionTypes = new StringMap<Type>();
		c.reverseMappedCache = new StringMap<Type>();
		c.reverseHomomorphicMappedCache = new StringMap<Type>();
		c.iterationTypesCache = new StringMap<IterationTypes>();
		c.undefinedSymbol = c.newSymbol(SymbolFlagsProperty, "undefined");
		c.argumentsSymbol = c.newSymbol(SymbolFlagsProperty, "arguments");
		c.requireSymbol = c.newSymbol(SymbolFlagsProperty, "require");
		c.unknownSymbol = c.newSymbol(SymbolFlagsProperty, "unknown");
		c.unresolvedSymbols = new StringMap<Symbol>();
		c.errorTypes = new StringMap<Type>();
		c.moduleSymbols = new IdentityMap<Node, Symbol>();
		c.globalThisSymbol = c.newSymbolEx(SymbolFlagsModule, "globalThis", CheckFlagsReadonly);
		c.globalThisSymbol.Exports = c.globals;
		c.globals.set(c.globalThisSymbol.Name, c.globalThisSymbol);
		c.nameResolver = c.createNameResolver(); // PORT: perf (typed resolver hooks), see resolveName
		c.suggestionNameResolver = c.createNameResolverForSuggestion();
		c.tupleTypes = new StringMap<Type>();
		c.unionTypes = new StringMap<Type>();
		c.unionOfUnionTypes = new StringMap<Type>();
		c.intersectionTypes = new StringMap<Type>();
		c.propertiesTypes = new StringMap<Type>();
		c.mergedSymbols = new IdentityMap<Symbol, Symbol>();
		c.patternForType = new IdentityMap<Type, Node>();
		c.contextFreeTypes = new IdentityMap<Node, Type>();
		c.anyType = c.newIntrinsicType(TypeFlagsAny, "any");
		c.autoType = c.newIntrinsicTypeEx(TypeFlagsAny, "any", ObjectFlagsNonInferrableType);
		c.wildcardType = c.newIntrinsicType(TypeFlagsAny, "any");
		c.blockedStringType = c.newIntrinsicType(TypeFlagsAny, "any");
		c.errorType = c.newIntrinsicType(TypeFlagsAny, "error");
		c.unresolvedType = c.newIntrinsicType(TypeFlagsAny, "unresolved");
		c.nonInferrableAnyType = c.newIntrinsicTypeEx(TypeFlagsAny, "any", ObjectFlagsContainsWideningType);
		c.intrinsicMarkerType = c.newIntrinsicType(TypeFlagsAny, "intrinsic");
		c.unknownType = c.newIntrinsicType(TypeFlagsUnknown, "unknown");
		c.undefinedType = c.newIntrinsicType(TypeFlagsUndefined, "undefined");
		c.undefinedWideningType = c.createWideningType(c.undefinedType);
		c.missingType = c.newIntrinsicType(TypeFlagsUndefined, "undefined");
		c.undefinedOrMissingType = Core.IfElse(c.exactOptionalPropertyTypes, c.missingType, c.undefinedType);
		c.optionalType = c.newIntrinsicType(TypeFlagsUndefined, "undefined");
		c.nullType = c.newIntrinsicType(TypeFlagsNull, "null");
		c.nullWideningType = c.createWideningType(c.nullType);
		c.stringType = c.newIntrinsicType(TypeFlagsString, "string");
		c.numberType = c.newIntrinsicType(TypeFlagsNumber, "number");
		c.bigintType = c.newIntrinsicType(TypeFlagsBigInt, "bigint");
		c.regularFalseType = c.newLiteralType(TypeFlagsBooleanLiteral, false, null);
		c.falseType = c.newLiteralType(TypeFlagsBooleanLiteral, false, c.regularFalseType);
		c.regularFalseType.AsLiteralType().freshType = c.falseType;
		c.falseType.AsLiteralType().freshType = c.falseType;
		c.regularTrueType = c.newLiteralType(TypeFlagsBooleanLiteral, true, null);
		c.trueType = c.newLiteralType(TypeFlagsBooleanLiteral, true, c.regularTrueType);
		c.regularTrueType.AsLiteralType().freshType = c.trueType;
		c.trueType.AsLiteralType().freshType = c.trueType;
		c.booleanType = c.getUnionType([c.regularFalseType, c.regularTrueType]);
		c.esSymbolType = c.newIntrinsicType(TypeFlagsESSymbol, "symbol");
		c.voidType = c.newIntrinsicType(TypeFlagsVoid, "void");
		c.neverType = c.newIntrinsicType(TypeFlagsNever, "never");
		c.silentNeverType = c.newIntrinsicTypeEx(TypeFlagsNever, "never", ObjectFlagsNonInferrableType);
		c.implicitNeverType = c.newIntrinsicType(TypeFlagsNever, "never");
		c.unreachableNeverType = c.newIntrinsicType(TypeFlagsNever, "never");
		c.nonPrimitiveType = c.newIntrinsicType(TypeFlagsNonPrimitive, "object");
		c.stringOrNumberType = c.getUnionType([c.stringType, c.numberType]);
		c.stringNumberSymbolType = c.getUnionType([c.stringType, c.numberType, c.esSymbolType]);
		c.numberOrBigIntType = c.getUnionType([c.numberType, c.bigintType]);
		c.numericStringType = c.getTemplateLiteralType(["", ""], [c.numberType]); // The `${number}` type
		c.templateConstraintType = c.getUnionType([c.stringType, c.numberType, c.booleanType, c.bigintType, c.nullType, c.undefinedType]);
		c.uniqueLiteralType = c.newIntrinsicType(TypeFlagsNever, "never"); // Special `never` flagged by union reduction to behave as a literal
		c.uniqueLiteralMapper = newFunctionTypeMapper(t -> c.getUniqueLiteralTypeForTypeParameter(t));
		c.reportUnreliableMapper = newFunctionTypeMapper(t -> c.reportUnreliableWorker(t));
		c.reportUnmeasurableMapper = newFunctionTypeMapper(t -> c.reportUnmeasurableWorker(t));
		c.restrictiveMapper = newFunctionTypeMapper(t -> c.restrictiveMapperWorker(t));
		c.permissiveMapper = newFunctionTypeMapper(t -> c.permissiveMapperWorker(t));
		c.emptyObjectType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.emptyJsxObjectType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.emptyFreshJsxObjectType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.emptyTypeLiteralType = c.newAnonymousType(c.newSymbol(SymbolFlagsTypeLiteral, Ast.InternalSymbolNameType), null, null, null, null);
		c.unknownEmptyObjectType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.unknownUnionType = c.createUnknownUnionType();
		c.emptyGenericType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.emptyGenericType.AsObjectType().instantiations = new StringMap<Type>();
		c.anyFunctionType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.anyFunctionType.objectFlags |= ObjectFlagsNonInferrableType;
		c.noConstraintType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.circularConstraintType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.resolvingDefaultType = c.newAnonymousType(null /*symbol*/, null, null, null, null);
		c.markerSuperType = c.newTypeParameter(null);
		c.markerSubType = c.newTypeParameter(null);
		c.markerSubType.AsTypeParameter().constraint = c.markerSuperType;
		c.markerOtherType = c.newTypeParameter(null);
		c.markerSuperTypeForCheck = c.newTypeParameter(null);
		c.markerSubTypeForCheck = c.newTypeParameter(null);
		c.markerSubTypeForCheck.AsTypeParameter().constraint = c.markerSuperTypeForCheck;
		c.noTypePredicate = new TypePredicate();
		c.noTypePredicate.kind = TypePredicateKindIdentifier;
		c.noTypePredicate.parameterIndex = 0;
		c.noTypePredicate.parameterName = "<<unresolved>>";
		c.noTypePredicate.t = c.anyType;
		c.anySignature = c.newSignature(SignatureFlagsNone, null, null, null, null, c.anyType, null, 0);
		c.unknownSignature = c.newSignature(SignatureFlagsNone, null, null, null, null, c.errorType, null, 0);
		c.resolvingSignature = c.newSignature(SignatureFlagsNone, null, null, null, null, c.anyType, null, 0);
		c.silentNeverSignature = c.newSignature(SignatureFlagsNone, null, null, null, null, c.silentNeverType, null, 0);
		c.cachedArgumentsReferenced = new IdentityMap<Node, Bool>();
		c.enumNumberIndexInfo = new IndexInfo();
		c.enumNumberIndexInfo.keyType = c.numberType;
		c.enumNumberIndexInfo.valueType = c.stringType;
		c.enumNumberIndexInfo.isReadonly = true;
		c.anyBaseTypeIndexInfo = new IndexInfo();
		c.anyBaseTypeIndexInfo.keyType = c.stringType;
		c.anyBaseTypeIndexInfo.valueType = c.anyType;
		c.anyBaseTypeIndexInfo.isReadonly = false;
		c.emptyStringType = c.getStringLiteralType("");
		c.zeroType = c.getNumberLiteralType(0);
		c.zeroBigIntType = c.getBigIntLiteralType(new PseudoBigInt());
		final typeofNames = [for (k in typeofNEFacts.keys()) k];
		typeofNames.sort(Strings.Compare);
		c.typeofType = c.getUnionType(Core.Map(typeofNames, s -> c.getStringLiteralType(s)));
		c.flowLoopCache = new StringMap<Type>();
		c.flowNodeReachable = new IdentityMap<FlowNode, Bool>();
		c.flowNodePostSuper = new IdentityMap<FlowNode, Bool>();
		c.subtypeRelation = new Relation();
		c.strictSubtypeRelation = new Relation();
		c.assignableRelation = new Relation();
		c.comparableRelation = new Relation();
		c.identityRelation = new Relation();
		c.enumRelation = new StringMap<RelationComparisonResult>();
		c.getGlobalESSymbolType = c.getGlobalTypeResolver("Symbol", 0 /*arity*/, false /*reportErrors*/);
		c.getGlobalBigIntType = c.getGlobalTypeResolver("BigInt", 0 /*arity*/, false /*reportErrors*/);
		c.getGlobalImportMetaType = c.getGlobalTypeResolver("ImportMeta", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalImportAttributesType = c.getGlobalTypeResolver("ImportAttributes", 0 /*arity*/, false /*reportErrors*/);
		c.getGlobalImportAttributesTypeChecked = c.getGlobalTypeResolver("ImportAttributes", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalNonNullableTypeAliasOrNil = c.getGlobalTypeAliasResolver("NonNullable", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalExtractSymbol = c.getGlobalTypeAliasResolver("Extract", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalDisposableType = c.getGlobalTypeResolver("Disposable", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalAsyncDisposableType = c.getGlobalTypeResolver("AsyncDisposable", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalAwaitedSymbol = c.getGlobalTypeAliasResolver("Awaited", 1 /*arity*/, true /*reportErrors*/);
		c.getGlobalAwaitedSymbolOrNil = c.getGlobalTypeAliasResolver("Awaited", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalNaNSymbolOrNil = c.getGlobalValueSymbolResolver("NaN", false /*reportErrors*/);
		c.getGlobalRecordSymbol = c.getGlobalTypeAliasResolver("Record", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalTemplateStringsArrayType = c.getGlobalTypeResolver("TemplateStringsArray", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalESSymbolConstructorSymbolOrNil = c.getGlobalValueSymbolResolver("Symbol", false /*reportErrors*/);
		c.getGlobalESSymbolConstructorTypeSymbolOrNil = c.getGlobalTypeSymbolResolver("SymbolConstructor", false /*reportErrors*/);
		c.getGlobalImportCallOptionsType = c.getGlobalTypeResolver("ImportCallOptions", 0 /*arity*/, false /*reportErrors*/);
		c.getGlobalImportCallOptionsTypeChecked = c.getGlobalTypeResolver("ImportCallOptions", 0 /*arity*/, true /*reportErrors*/);
		c.getGlobalPromiseType = c.getGlobalTypeResolver("Promise", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalPromiseTypeChecked = c.getGlobalTypeResolver("Promise", 1 /*arity*/, true /*reportErrors*/);
		c.getGlobalPromiseLikeType = c.getGlobalTypeResolver("PromiseLike", 1 /*arity*/, true /*reportErrors*/);
		c.getGlobalPromiseConstructorSymbol = c.getGlobalValueSymbolResolver("Promise", true /*reportErrors*/);
		c.getGlobalPromiseConstructorSymbolOrNil = c.getGlobalValueSymbolResolver("Promise", false /*reportErrors*/);
		c.getGlobalOmitSymbol = c.getGlobalTypeAliasResolver("Omit", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalNoInferSymbolOrNil = c.getGlobalTypeAliasResolver("NoInfer", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalIteratorType = c.getGlobalTypeResolver("Iterator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalIterableType = c.getGlobalTypeResolver("Iterable", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalIterableTypeChecked = c.getGlobalTypeResolver("Iterable", 3 /*arity*/, true /*reportErrors*/);
		c.getGlobalIterableIteratorType = c.getGlobalTypeResolver("IterableIterator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalIterableIteratorTypeChecked = c.getGlobalTypeResolver("IterableIterator", 3 /*arity*/, true /*reportErrors*/);
		c.getGlobalIteratorObjectType = c.getGlobalTypeResolver("IteratorObject", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalGeneratorType = c.getGlobalTypeResolver("Generator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalAsyncIteratorType = c.getGlobalTypeResolver("AsyncIterator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalAsyncIterableType = c.getGlobalTypeResolver("AsyncIterable", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalAsyncIterableTypeChecked = c.getGlobalTypeResolver("AsyncIterable", 3 /*arity*/, true /*reportErrors*/);
		c.getGlobalAsyncIterableIteratorType = c.getGlobalTypeResolver("AsyncIterableIterator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalAsyncIterableIteratorTypeChecked = c.getGlobalTypeResolver("AsyncIterableIterator", 3 /*arity*/, true /*reportErrors*/);
		c.getGlobalAsyncIteratorObjectType = c.getGlobalTypeResolver("AsyncIteratorObject", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalAsyncGeneratorType = c.getGlobalTypeResolver("AsyncGenerator", 3 /*arity*/, false /*reportErrors*/);
		c.getGlobalIteratorYieldResultType = c.getGlobalTypeResolver("IteratorYieldResult", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalIteratorReturnResultType = c.getGlobalTypeResolver("IteratorReturnResult", 1 /*arity*/, false /*reportErrors*/);
		c.getGlobalTypedPropertyDescriptorType = c.getGlobalTypeResolver("TypedPropertyDescriptor", 1 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassDecoratorContextType = c.getGlobalTypeResolver("ClassDecoratorContext", 1 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassMethodDecoratorContextType = c.getGlobalTypeResolver("ClassMethodDecoratorContext", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassGetterDecoratorContextType = c.getGlobalTypeResolver("ClassGetterDecoratorContext", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassSetterDecoratorContextType = c.getGlobalTypeResolver("ClassSetterDecoratorContext", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassAccessorDecoratorContextType = c.getGlobalTypeResolver("ClassAccessorDecoratorContext", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassAccessorDecoratorTargetType = c.getGlobalTypeResolver("ClassAccessorDecoratorTarget", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassAccessorDecoratorResultType = c.getGlobalTypeResolver("ClassAccessorDecoratorResult", 2 /*arity*/, true /*reportErrors*/);
		c.getGlobalClassFieldDecoratorContextType = c.getGlobalTypeResolver("ClassFieldDecoratorContext", 2 /*arity*/, true /*reportErrors*/);
		c.initializeClosures();
		c.initializeIterationResolvers();
		c.initializeChecker();
		return new Pair<Checker, Any>(c, c.mu);
	}

	static function createFileIndexMap(files:Array<SourceFile>):IdentityMap<SourceFile, Int> {
		final result = new IdentityMap<SourceFile, Int>();
		if (files != null) {
			for (i in 0...files.length) {
				result.set(files[i], i);
			}
		}
		return result;
	}

	static function countGlobalSymbols(files:Array<SourceFile>):Int {
		var count = 0;
		if (files != null) {
			for (file in files) {
				if (!Ast.IsExternalOrCommonJSModule(file)) {
					if (file.Locals != null) {
						for (_ in file.Locals) {
							count++;
						}
					}
				}
			}
		}
		return count;
	}

	static function getGlobalTypeDeclaration(symbol:Symbol):Declaration {
		if (symbol.Declarations != null) {
			for (declaration in symbol.Declarations) {
				switch (declaration.Kind) {
					case KindClassDeclaration | KindInterfaceDeclaration | KindEnumDeclaration | KindTypeAliasDeclaration:
						return declaration;
					default:
				}
			}
		}
		return null;
	}

	static function isPrimitiveTypeName(s:std.String):Bool {
		return s == "any" || s == "string" || s == "number" || s == "boolean" || s == "never" || s == "unknown";
	}

	static function isES2015OrLaterConstructorName(s:std.String):Bool {
		return s == "Promise" || s == "Symbol" || s == "Map" || s == "WeakMap" || s == "Set" || s == "WeakSet";
	}

	// PORT: sync.OnceValue → a lazy static.
	static var primitiveTypeAliasSuggestions_:StringMap<Symbol> = null;

	static var primitiveTypeAliasSuggestions:() -> StringMap<Symbol> = () -> {
		if (primitiveTypeAliasSuggestions_ == null) {
			final result = new StringMap<Symbol>();
			for (e in [["string", "String"], ["number", "Number"], ["boolean", "Boolean"], ["object", "Object"], ["bigint", "BigInt"], ["symbol", "Symbol"]]) {
				final sym = new Symbol();
				sym.Flags = SymbolFlagsTypeAlias | SymbolFlagsTransient;
				sym.Name = e[0];
				result.set(e[1], sym);
			}
			primitiveTypeAliasSuggestions_ = result;
		}
		return primitiveTypeAliasSuggestions_;
	};

	static function getPrimitiveTypeAliasSuggestions(symbols:SymbolTable):(yield:(Symbol) -> Bool) -> Void {
		return (yield:(Symbol) -> Bool) -> {
			final suggestions = primitiveTypeAliasSuggestions();
			for (builtinName in suggestions.keys()) {
				if (symbols != null && symbols.exists(builtinName)) {
					if (!yield(suggestions.get(builtinName))) {
						return;
					}
				}
			}
		};
	}

	static function isImmediatelyUsedInInitializerOfBlockScopedVariable(declaration:Node, usage:Node, declContainer:Node):Bool {
		switch (declaration.Parent.Parent.Kind) {
			case KindVariableStatement | KindForStatement | KindForOfStatement:
				// variable statement/for/for-of statement case,
				// use site should not be inside variable declaration (initializer of declaration or binding element)
				if (isSameScopeDescendentOf(usage, declaration, declContainer)) {
					return true;
				}
			default:
		}
		// ForIn/ForOf case - use site should not be used in expression part
		final grandparent = declaration.Parent.Parent;
		return Ast.IsForInOrOfStatement(grandparent) && isSameScopeDescendentOf(usage, grandparent.Expression(), declContainer);
	}

	// Starting from 'initial' node walk up the parent chain until 'stopAt' node is reached.
	// If at any point current node is equal to 'parent' node - return true.
	// If current node is an IIFE, continue walking up.
	// Return false if 'stopAt' node is reached or isFunctionLike(current) === true.
	static function isSameScopeDescendentOf(initial:Node, parent:Node, stopAt:Node):Bool {
		if (parent == null) {
			return false;
		}
		var n = initial;
		while (n != null) {
			if (n == parent) {
				return true;
			}
			if (n == stopAt
				|| Ast.IsFunctionLike(n) && (Ast.GetImmediatelyInvokedFunctionExpression(n) == null || (Ast.GetFunctionFlags(n) & FunctionFlagsAsyncGenerator != 0))) {
				return false;
			}
			n = n.Parent;
		}
		return false;
	}

	// isPropertyImmediatelyReferencedWithinDeclaration is used for detecting ES-standard class field use-before-def errors
	static function isPropertyImmediatelyReferencedWithinDeclaration(declaration:Node, usage:Node, stopAtAnyPropertyDeclaration:Bool):Bool {
		// always legal if usage is after declaration
		if (usage.End() > declaration.End()) {
			return false;
		}
		// still might be legal if usage is deferred (e.g. x: any = () => this.x)
		// otherwise illegal if immediately referenced within the declaration (e.g. x: any = this.x)
		var node = usage;
		while (node != null && node != declaration) {
			switch (node.Kind) {
				case KindArrowFunction:
					return false;
				case KindPropertyDeclaration:
					// even when stopping at any property declaration, they need to come from the same class
					return stopAtAnyPropertyDeclaration
						&& ((Ast.IsPropertyDeclaration(declaration) && node.Parent == declaration.Parent)
							|| (Ast.IsParameterPropertyDeclaration(declaration, declaration.Parent) && node.Parent == declaration.Parent.Parent));
				case KindBlock:
					switch (node.Parent.Kind) {
						case KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
							return false;
						default:
					}
				default:
			}
			node = node.Parent;
		}
		return true;
	}

	static function isInstancePropertyWithInitializerOrPrivateIdentifierProperty(n:Node):Bool {
		return Ast.IsPrivateIdentifierClassElementDeclaration(n) || Ast.IsPropertyDeclaration(n) && !Ast.IsStatic(n) && n.Initializer() != null;
	}

	static function superCallIsRootLevelInConstructor(superCall:Node, body:Node):Bool {
		final superCallParent = Ast.WalkUpParenthesizedExpressions(superCall.Parent);
		return Ast.IsExpressionStatement(superCallParent) && superCallParent.Parent == body;
	}

	static function nodeImmediatelyReferencesSuperOrThis(node:Node):Bool {
		switch (node.Kind) {
			case KindSuperKeyword | KindThisKeyword:
				return true;
			case KindArrowFunction | KindFunctionDeclaration | KindFunctionExpression | KindPropertyDeclaration:
				return false;
			case KindBlock:
				switch (node.Parent.Kind) {
					case KindConstructor | KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
						return false;
					default:
				}
			default:
		}
		return node.ForEachChild(fn_nodeImmediatelyReferencesSuperOrThis);
	}

	static function isInstantiatedModule(node:Node, preserveConstEnums:Bool):Bool {
		final moduleState = Ast.GetModuleInstanceState(node);
		return moduleState == ModuleInstanceStateInstantiated || preserveConstEnums && moduleState == ModuleInstanceStateConstEnumOnly;
	}

	static function getFirstNonAmbientClassOrFunctionDeclaration(symbol:Symbol):Node {
		if (symbol.Declarations != null) {
			for (declaration in symbol.Declarations) {
				if ((Ast.IsClassDeclaration(declaration) || Ast.IsFunctionDeclaration(declaration) && Ast.NodeIsPresent(declaration.Body()))
					&& declaration.Flags & NodeFlagsAmbient == 0) {
					return declaration;
				}
			}
		}
		return null;
	}

	static function hasTypeJsonImportAttribute(node:Node):Bool {
		final attributes = node.AsImportDeclaration().Attributes;
		return attributes != null && Core.Some(attributes.AsImportAttributes().Attributes.Nodes, (attr:Node) -> {
			return attr.Name().Text() == "type" && Ast.IsStringLiteralLike(attr.AsImportAttribute().Value) && attr.AsImportAttribute().Value.Text() == "json";
		});
	}

	static function getVerbatimModuleSyntaxErrorMessage(node:Node):Message {
		final sourceFile = Ast.GetSourceFileOfNode(node);
		final fileName = sourceFile.FileName();

		// Check if the file is .cts or .cjs (CommonJS-specific extensions)
		if (Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionCts, Tspath.ExtensionCjs])) {
			return Diagnostics.ECMAScript_imports_and_exports_cannot_be_written_in_a_CommonJS_file_under_verbatimModuleSyntax;
		}
		// For .ts, .tsx, .js, etc.
		return Diagnostics.ECMAScript_imports_and_exports_cannot_be_written_in_a_CommonJS_file_under_verbatimModuleSyntax_Adjust_the_type_field_in_the_nearest_package_json_to_make_this_file_an_ECMAScript_module_or_adjust_your_verbatimModuleSyntax_module_and_moduleResolution_settings_in_TypeScript;
	}

	static function isNotOverload(node:Node):Bool {
		return !Ast.IsFunctionDeclaration(node) && !Ast.IsMethodDeclaration(node) || node.Body() != null;
	}

	static function isES2015OrLaterIterable(n:std.String):Bool {
		switch (n) {
			case "Float32Array" | "Float64Array" | "Int16Array" | "Int32Array" | "Int8Array" | "NodeList" | "Uint16Array" | "Uint32Array" | "Uint8Array" | "Uint8ClampedArray":
				return true;
			default:
		}
		return false;
	}

	static function isIdentifierThatStartsWithUnderscore(node:Node):Bool {
		return Ast.IsIdentifier(node) && node.Text() != "" && StringTools.fastCodeAt(node.Text(), 0) == '_'.code;
	}

	static function importClauseFromImported(node:Node):Node {
		switch (node.Kind) {
			case KindImportClause:
				return node;
			case KindNamespaceImport:
				return node.Parent;
			default:
				return node.Parent.Parent;
		}
	}

	static function hasTypeParameterByName(typeParameters:Array<Type>, name:std.String):Bool {
		return Core.Some(typeParameters, (tp:Type) -> {
			return tp.symbol.Name == name;
		});
	}

	static function getUniqueTypeParameterName(typeParameters:Array<Type>, baseName:std.String):std.String {
		while (baseName.length > 1 && StringTools.fastCodeAt(baseName, baseName.length - 1) >= '0'.code
			&& StringTools.fastCodeAt(baseName, baseName.length - 1) <= '9'.code) {
			baseName = baseName.substring(0, baseName.length - 1);
		}
		var index = 1;
		while (true) {
			final augmentedName = baseName + Std.string(index);
			if (!hasTypeParameterByName(typeParameters, augmentedName)) {
				return augmentedName;
			}
			index++;
		}
	}

	static function isSpreadIntoCallOrNew(node:Node):Bool {
		final parent = Ast.WalkUpParenthesizedExpressions(node.Parent);
		return Ast.IsSpreadElement(parent) && Ast.IsCallOrNewExpression(parent.Parent);
	}

	static function someSignature(signatures:Array<Signature>, f:(s:Signature) -> Bool):Bool {
		if (signatures != null) {
			for (sig in signatures) {
				if (sig.composite != null && sig.composite.isUnion && Core.Some(sig.composite.signatures, f) || sig.composite == null && f(sig)) {
					return true;
				}
			}
		}
		return false;
	}

	static function signatureHasLiteralTypes(s:Signature):Bool {
		return s.flags & SignatureFlagsHasLiteralTypes != 0;
	}

	static function acceptsVoid(t:Type):Bool {
		return t.flags & TypeFlagsVoid != 0;
	}

	static function getErrorNodeForCallNode(node:Node):Node {
		if (Ast.IsCallExpression(node)) {
			node = node.Expression();
			if (Ast.IsPropertyAccessExpression(node)) {
				node = node.Name();
			}
		}
		return node;
	}

	static function hasCommonDomTypeName(t:Type):Bool {
		if (t.symbol == null) {
			return false;
		}
		final name = t.symbol.Name;
		return name == "EventTarget" || name == "Node" || name == "Element" || StringTools.startsWith(name, "HTML") && StringTools.endsWith(name, "Element");
	}

	static function getThisParameterFromNodeContext(node:Node):Node {
		final thisContainer = Ast.GetThisContainer(node, false /*includeArrowFunctions*/, false /*includeClassComputedPropertyName*/);
		if (thisContainer != null && Ast.IsFunctionLike(thisContainer)) {
			return Ast.GetThisParameter(thisContainer);
		}
		return null;
	}

	static function createDiagnosticForNode(node:Node, message:Message, ...args:Any):Diagnostic {
		return NewDiagnosticForNode(node, message, ...args);
	}

	static function getAdjustedNodeForError(node:Node):Node {
		final name = Ast.GetNameOfDeclaration(node);
		if (name != null) {
			return name;
		}
		return node;
	}

	static function getFirstDeclaration(symbol:Symbol):Node {
		if (Core.len(symbol.Declarations) > 0) {
			return symbol.Declarations[0];
		}
		return null;
	}

	static function getExcludedSymbolFlags(flags:SymbolFlags):SymbolFlags {
		var result:SymbolFlags = SymbolFlagsNone;
		if (flags & SymbolFlagsBlockScopedVariable != 0) {
			result |= SymbolFlagsBlockScopedVariableExcludes;
		}
		if (flags & SymbolFlagsFunctionScopedVariable != 0) {
			result |= SymbolFlagsFunctionScopedVariableExcludes;
		}
		if (flags & SymbolFlagsProperty != 0) {
			result |= SymbolFlagsPropertyExcludes;
		}
		if (flags & SymbolFlagsEnumMember != 0) {
			result |= SymbolFlagsEnumMemberExcludes;
		}
		if (flags & SymbolFlagsFunction != 0) {
			result |= SymbolFlagsFunctionExcludes;
		}
		if (flags & SymbolFlagsClass != 0) {
			result |= SymbolFlagsClassExcludes;
		}
		if (flags & SymbolFlagsInterface != 0) {
			result |= SymbolFlagsInterfaceExcludes;
		}
		if (flags & SymbolFlagsRegularEnum != 0) {
			result |= SymbolFlagsRegularEnumExcludes;
		}
		if (flags & SymbolFlagsConstEnum != 0) {
			result |= SymbolFlagsConstEnumExcludes;
		}
		if (flags & SymbolFlagsValueModule != 0) {
			result |= SymbolFlagsValueModuleExcludes;
		}
		if (flags & SymbolFlagsMethod != 0) {
			result |= SymbolFlagsMethodExcludes;
		}
		if (flags & SymbolFlagsGetAccessor != 0) {
			result |= SymbolFlagsGetAccessorExcludes;
		}
		if (flags & SymbolFlagsSetAccessor != 0) {
			result |= SymbolFlagsSetAccessorExcludes;
		}
		if (flags & SymbolFlagsTypeParameter != 0) {
			result |= SymbolFlagsTypeParameterExcludes;
		}
		if (flags & SymbolFlagsTypeAlias != 0) {
			result |= SymbolFlagsTypeAliasExcludes;
		}
		if (flags & SymbolFlagsAlias != 0) {
			result |= SymbolFlagsAliasExcludes;
		}
		if (flags & SymbolFlagsReplaceableByMethod != 0) {
			result &= ~SymbolFlagsMethod;
		}
		return result;
	}

	static function getModuleSpecifierFromNode(node:Node):Node {
		switch (node.Kind) {
			case KindImportDeclaration | KindJSImportDeclaration:
				return node.ModuleSpecifier();
			case KindExportDeclaration:
				return node.ModuleSpecifier();
			default:
		}
		throw "Unhandled case in getModuleSpecifierFromNode";
	}

	static function resolutionExtensionIsTSOrJson(ext:std.String):Bool {
		return Tspath.ExtensionIsTs(ext) || ext == Tspath.ExtensionJson;
	}

	static function isESMFormatImportImportingCommonjsFormatFile(usageMode:ResolutionMode, targetMode:ResolutionMode):Bool {
		return usageMode == ModuleKindESNext && targetMode == ModuleKindCommonJS;
	}

	static function isNotReplacableByMethod(decl:Node):Bool {
		return decl.Symbol().Flags & SymbolFlagsReplaceableByMethod == 0;
	}

	static function signatureHasRestParameter(sig:Signature):Bool {
		return sig.flags & SignatureFlagsHasRestParameter != 0;
	}

	// PORT: h is the keyBuilder's KeyHasher (see CacheHashKey); T is any 32-bit integer type.
	static function hashWrite32(h:KeyHasher, value:Int):Void {
		final v = value;
		h.Reserve(4); // PORT: perf — one capacity test for the four bytes
		h.Put(v & 0xFF);
		h.Put((v >>> 8) & 0xFF);
		h.Put((v >>> 16) & 0xFF);
		h.Put((v >>> 24) & 0xFF);
	}

	// PORT: h is the keyBuilder's KeyHasher (see CacheHashKey); T is any integer type (Int here).
	static function hashWrite64(h:KeyHasher, value:Int):Void {
		// PORT: the Haxe Int is 32 bits; Go's uint64 conversion sign-extends it.
		final v = value;
		final hi = v < 0 ? 0xFF : 0;
		h.Reserve(8); // PORT: perf — one capacity test for the eight bytes
		h.Put(v & 0xFF);
		h.Put((v >>> 8) & 0xFF);
		h.Put((v >>> 16) & 0xFF);
		h.Put((v >>> 24) & 0xFF);
		h.Put(hi);
		h.Put(hi);
		h.Put(hi);
		h.Put(hi);
	}

	static function getTypeListKey(types:Array<Type>):CacheHashKey {
		final b = new KeyBuilder();
		b.writeTypes(types);
		return b.hash();
	}

	static function getAliasKey(alias:TypeAlias):CacheHashKey {
		final b = new KeyBuilder();
		b.writeAlias(alias);
		return b.hash();
	}

	static function getUnionKey(types:Array<Type>, origin:Type, alias:TypeAlias):CacheHashKey {
		final b = new KeyBuilder();
		if (origin == null) {
			b.writeTypes(types);
		} else if (origin.flags & TypeFlagsUnion != 0) {
			b.writeByte('|'.code);
			b.writeTypes(origin.Types());
		} else if (origin.flags & TypeFlagsIntersection != 0) {
			b.writeByte('&'.code);
			b.writeTypes(origin.Types());
		} else if (origin.flags & TypeFlagsIndex != 0) {
			// origin type id alone is insufficient, as `keyof x` may resolve to multiple WIP values while `x` is still resolving
			b.writeByte('#'.code);
			b.writeType(origin);
			b.writeByte('|'.code);
			b.writeTypes(types);
		} else {
			throw "Unhandled case in getUnionKey";
		}
		b.writeAlias(alias);
		return b.hash();
	}

	static function getIntersectionKey(types:Array<Type>, flags:IntersectionFlags, alias:TypeAlias):CacheHashKey {
		final b = new KeyBuilder();
		b.writeTypes(types);
		if (flags & IntersectionFlagsNoConstraintReduction == 0) {
			b.writeAlias(alias);
		} else {
			b.writeByte('*'.code);
		}
		return b.hash();
	}

	static function getTupleKey(elementInfos:Array<TupleElementInfo>, readonly:Bool):CacheHashKey {
		final b = new KeyBuilder();
		if (elementInfos != null) {
			for (e in elementInfos) {
				if (e.flags & ElementFlagsRequired != 0) {
					b.writeByte('#'.code);
				} else if (e.flags & ElementFlagsOptional != 0) {
					b.writeByte('?'.code);
				} else if (e.flags & ElementFlagsRest != 0) {
					b.writeByte('.'.code);
				} else {
					b.writeByte('*'.code);
				}
				if (e.labeledDeclaration != null) {
					b.writeNode(e.labeledDeclaration);
				}
			}
		}
		if (readonly) {
			b.writeByte('!'.code);
		}
		return b.hash();
	}

	static function getTypeAliasInstantiationKey(typeArguments:Array<Type>, alias:TypeAlias):CacheHashKey {
		return getTypeInstantiationKey(typeArguments, alias, false);
	}

	static function getTypeInstantiationKey(typeArguments:Array<Type>, alias:TypeAlias, singleSignature:Bool):CacheHashKey {
		final b = new KeyBuilder();
		b.writeTypes(typeArguments);
		b.writeAlias(alias);
		if (singleSignature) {
			b.writeByte('!'.code);
		}
		return b.hash();
	}

	static function getIndexedAccessKey(objectType:Type, indexType:Type, accessFlags:AccessFlags, alias:TypeAlias):CacheHashKey {
		final b = new KeyBuilder();
		b.writeType(objectType);
		b.writeType(indexType);
		hashWrite32(b.h, accessFlags);
		b.writeAlias(alias);
		return b.hash();
	}

	static function getTemplateTypeKey(texts:Array<std.String>, types:Array<Type>):CacheHashKey {
		final b = new KeyBuilder();
		b.writeTypes(types);
		b.writeByte('|'.code);
		if (texts != null) {
			for (s in texts) {
				b.writeInt(Utf8.ByteLen(s)); // PORT: byte (Go len(s))
			}
		}
		b.writeByte('|'.code);
		if (texts != null) {
			for (s in texts) {
				b.writeString(s);
			}
		}
		return b.hash();
	}

	static function getConditionalTypeKey(typeArguments:Array<Type>, alias:TypeAlias, forConstraint:Bool):CacheHashKey {
		final b = new KeyBuilder();
		b.writeTypes(typeArguments);
		b.writeAlias(alias);
		if (forConstraint) {
			b.writeByte('!'.code);
		}
		return b.hash();
	}

	// PORT: perf — Go returns (CacheHashKey, bool); the bool (constrained) is left in
	// getRelationKeyConstrained, read by the caller right after the call (no result object per check).
	#if tshx_parallel
	@:hxmc.threadLocal static var getRelationKeyConstrained:Bool; // PORT: hxmc (-D tshx-parallel) — per thread
	#else
	static var getRelationKeyConstrained:Bool = false;
	#end

	static function getRelationKey(source:Type, target:Type, intersectionState:IntersectionState, isIdentity:Bool, ignoreConstraints:Bool):CacheHashKey {
		if (isIdentity && source.id > target.id) {
			final tmp = source;
			source = target;
			target = tmp;
		}
		final b = new KeyBuilder();
		var constrained = false;
		if (isTypeReferenceWithGenericArguments(source) && isTypeReferenceWithGenericArguments(target)) {
			b.writeByte('g'.code);
			constrained = b.writeGenericTypeReferences(source, target, ignoreConstraints);
		} else {
			b.writeByte('s'.code);
			b.writeType(source);
			b.writeType(target);
		}
		hashWrite32(b.h, intersectionState);
		getRelationKeyConstrained = constrained;
		return b.hash();
	}

	static function getNodeListKey(nodes:Array<Node>):CacheHashKey {
		final b = new KeyBuilder();
		b.writeInt(Core.len(nodes));
		if (nodes != null) {
			for (n in nodes) {
				b.writeNode(n);
			}
		}
		return b.hash();
	}

	static function isTypeReferenceWithGenericArguments(t:Type):Bool {
		return isNonDeferredTypeReference(t) && Core.Some(t.checker.getTypeArguments(t), (t:Type) -> {
			return t.flags & TypeFlagsTypeParameter != 0 || isTypeReferenceWithGenericArguments(t);
		});
	}

	static function isNonDeferredTypeReference(t:Type):Bool {
		return t.objectFlags & ObjectFlagsReference != 0 && t.AsTypeReference().node == null;
	}

	// Return true if type parameter originates in an unconstrained declaration in a type parameter list
	static function isUnconstrainedTypeParameter(tp:Type):Bool {
		var target = tp.Target();
		if (target == null) {
			target = tp;
		}
		if (target.symbol == null) {
			return false;
		}
		if (target.symbol.Declarations != null) {
			for (d in target.symbol.Declarations) {
				if (Ast.IsTypeParameterDeclaration(d)
					&& (d.AsTypeParameterDeclaration().Constraint != null || Ast.IsMappedTypeNode(d.Parent) || Ast.IsInferTypeNode(d.Parent))) {
					return false;
				}
			}
		}
		return true;
	}

	static function findIndexInfo(indexInfos:Array<IndexInfo>, keyType:Type):IndexInfo {
		if (indexInfos != null) {
			for (info in indexInfos) {
				if (info.keyType == keyType) {
					return info;
				}
			}
		}
		return null;
	}

	static function getBaseTypeNodeOfClass(t:Type):Node {
		final decl = Ast.GetClassLikeDeclarationOfSymbol(t.symbol);
		if (decl != null) {
			return Ast.GetExtendsHeritageClauseElement(decl);
		}
		return null;
	}

	static function getTargetType(t:Type):Type {
		if (t.objectFlags & ObjectFlagsReference != 0) {
			return t.Target();
		}
		return t;
	}

	static function isLateBindableAST(node:Node):Bool {
		var expr:Node = null;
		if (Ast.IsComputedPropertyName(node)) {
			expr = node.Expression();
		} else if (Ast.IsElementAccessExpression(node)) {
			expr = node.AsElementAccessExpression().ArgumentExpression;
		}
		return expr != null && Ast.IsEntityNameExpression(expr);
	}

	static function getEffectiveSetAccessorTypeAnnotationNode(node:Node):Node {
		final param = GetSetAccessorValueParameter(node);
		if (param != null) {
			return param.Type();
		}
		return null;
	}

	static function mayReturnNever(fn:Node):Bool {
		switch (fn.Kind) {
			case KindFunctionExpression | KindArrowFunction:
				return true;
			case KindMethodDeclaration:
				return Ast.IsObjectLiteralExpression(fn.Parent);
			default:
		}
		return false;
	}

	// Returns true if the parameter or class/interface member given by the symbol is free of "this" references. The
	// function may return false for symbols that are actually free of "this" references because it is not
	// feasible to perform a complete analysis in all cases. In particular, property members with types
	// inferred from their initializers and function members with inferred return types are conservatively
	// assumed not to be free of "this" references.
	static function isThisless(symbol:Symbol):Bool {
		if (Core.len(symbol.Declarations) == 1) {
			final declaration = symbol.Declarations[0];
			if (declaration != null) {
				switch (declaration.Kind) {
					case KindParameter:
						return isThislessVariableLikeDeclaration(declaration);
					case KindPropertyDeclaration | KindPropertySignature:
						return isThislessVariableLikeDeclaration(declaration);
					case KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor:
						return isThislessFunctionLikeDeclaration(declaration);
					default:
				}
			}
		}
		return false;
	}

	// A variable-like declaration is free of this references if it has a type annotation
	// that is thisless, or if it has no type annotation and no initializer (and is thus of type any).
	static function isThislessVariableLikeDeclaration(node:Node):Bool {
		final typeNode = node.Type();
		if (typeNode != null) {
			return isThislessType(typeNode);
		}
		return node.Initializer() == null;
	}

	// A type is free of this references if it's the any, string, number, boolean, symbol, or void keyword, a string
	// literal type, an array with an element type that is free of this references, or a type reference that is
	// free of this references.
	static function isThislessType(node:Node):Bool {
		switch (node.Kind) {
			case KindAnyKeyword | KindUnknownKeyword | KindStringKeyword | KindNumberKeyword | KindBigIntKeyword | KindBooleanKeyword | KindSymbolKeyword |
				KindObjectKeyword | KindVoidKeyword | KindUndefinedKeyword | KindNeverKeyword | KindLiteralType:
				return true;
			case KindArrayType:
				return isThislessType(node.AsArrayTypeNode().ElementType);
			case KindTypeReference:
				return Core.Every(node.TypeArguments(), fn_isThislessType);
			default:
		}
		return false;
	}

	// A function-like declaration is considered free of `this` references if it has a return type
	// annotation that is free of this references and if each parameter is thisless and if
	// each type parameter (if present) is thisless.
	static function isThislessFunctionLikeDeclaration(node:Node):Bool {
		final returnType = node.Type();
		return (Ast.IsConstructorDeclaration(node) || returnType != null && isThislessType(returnType))
			&& Core.Every(node.Parameters(), fn_isThislessVariableLikeDeclaration)
			&& Core.Every(node.TypeParameters(), fn_isThislessTypeParameter);
	}

	// A type parameter is thisless if its constraint is thisless, or if it has no constraint. */
	static function isThislessTypeParameter(node:Node):Bool {
		final constraint = node.AsTypeParameterDeclaration().Constraint;
		return constraint == null || isThislessType(constraint);
	}

	/**
	 * Return whether this symbol is a member of a prototype somewhere
	 * Note that this is not tracked well within the compiler, so the answer may be incorrect.
	 */
	static function isPrototypeProperty(symbol:Symbol):Bool {
		return symbol.Flags & SymbolFlagsMethod != 0 || symbol.CheckFlags & CheckFlagsSyntheticMethod != 0;
	}

	static function isConflictingPrivateProperty(prop:Symbol):Bool {
		// Return true for a synthetic property with multiple declarations, at least one of which is private.
		return prop.ValueDeclaration == null && prop.CheckFlags & CheckFlagsContainsPrivate != 0;
	}

	static function getModifiedReadonlyState(state:Bool, modifiers:MappedTypeModifiers):Bool {
		if (modifiers & MappedTypeModifiersIncludeReadonly != 0) {
			return true;
		} else if (modifiers & MappedTypeModifiersExcludeReadonly != 0) {
			return false;
		}
		return state;
	}

	static function instantiateList<T>(c:Checker, values:Array<T>, m:TypeMapper, instantiator:(c:Checker, value:T, m:TypeMapper) -> T):Array<T> {
		if (values == null) {
			return values;
		}
		for (i in 0...values.length) {
			final value = values[i];
			final mapped = instantiator(c, value, m);
			if (mapped != value) {
				final result = values.slice(0, i);
				result.push(mapped);
				for (j in (i + 1)...values.length) {
					result.push(instantiator(c, values[j], m));
				}
				return result;
			}
		}
		return values;
	}

	static function getSymbolPath(symbol:Symbol):std.String {
		if (symbol.Parent != null) {
			return getSymbolPath(symbol.Parent) + "." + symbol.Name;
		}
		return symbol.Name;
	}

	// Return count of starting consecutive tuple elements of the given kind(s)
	static function getStartElementCount(t:TupleType, flags:ElementFlags):Int {
		final infos = t.elementInfos;
		for (i in 0...Core.len(infos)) {
			if (infos[i].flags & flags == 0) {
				return i;
			}
		}
		return Core.len(infos);
	}

	// Return count of ending consecutive tuple elements of the given kind(s)
	static function getEndElementCount(t:TupleType, flags:ElementFlags):Int {
		final infos = t.elementInfos;
		var i = Core.len(infos);
		while (i > 0) {
			if (infos[i - 1].flags & flags == 0) {
				return infos.length - i;
			}
			i--;
		}
		return Core.len(infos);
	}

	static function getTotalFixedElementCount(t:TupleType):Int {
		return t.fixedLength + getEndElementCount(t, ElementFlagsFixed);
	}

	static function isTupleType(t:Type):Bool {
		return t.objectFlags & ObjectFlagsReference != 0 && t.Target().objectFlags & ObjectFlagsTuple != 0;
	}

	static function isMutableTupleType(t:Type):Bool {
		return isTupleType(t) && !t.TargetTupleType().readonly;
	}

	static function isGenericTupleType(t:Type):Bool {
		return isTupleType(t) && t.TargetTupleType().combinedFlags & ElementFlagsVariadic != 0;
	}

	static function isSingleElementGenericTupleType(t:Type):Bool {
		return isGenericTupleType(t) && Core.len(t.TargetTupleType().elementInfos) == 1;
	}

	static function isLocalTypeAlias(symbol:Symbol):Bool {
		final declaration = Core.Find(symbol.Declarations, fn_isTypeAlias);
		return declaration != null && Ast.GetContainingFunction(declaration) != null;
	}

	static function getTypeReferenceName(node:Node):Node {
		switch (node.Kind) {
			case KindTypeReference:
				return node.AsTypeReferenceNode().TypeName;
			case KindExpressionWithTypeArguments:
				// We only support expressions that are simple qualified names. For other
				// expressions this produces nil
				final expr = node.Expression();
				if (Ast.IsEntityNameExpression(expr)) {
					return expr;
				}
			default:
		}
		return null;
	}

	static function isUnaryTupleTypeNode(node:Node):Bool {
		return Ast.IsTupleTypeNode(node) && Core.len(node.Elements()) == 1;
	}

	static function isFreshLiteralType(t:Type):Bool {
		return t.flags & TypeFlagsFreshable != 0 && t.AsLiteralType().freshType == t;
	}

	static function getStringLiteralValue(t:Type):std.String {
		return (t.AsLiteralType().value : std.String);
	}

	static function getNumberLiteralValue(t:Type):Number {
		return (t.AsLiteralType().value : Float);
	}

	static function getBigIntLiteralValue(t:Type):PseudoBigInt {
		return (t.AsLiteralType().value : PseudoBigInt);
	}

	static function getBooleanLiteralValue(t:Type):Bool {
		return (t.AsLiteralType().value : Bool);
	}

	static function isLiteralType(t:Type):Bool {
		if (t.flags & TypeFlagsBoolean != 0) {
			return true;
		}
		if (t.flags & TypeFlagsUnion != 0) {
			if (t.flags & TypeFlagsEnumLiteral != 0) {
				return true;
			}
			return Core.Every(t.Types(), fn_isUnitType);
		}
		return isUnitType(t);
	}

	static function isNeitherUnitTypeNorNever(t:Type):Bool {
		return t.flags & (TypeFlagsUnit | TypeFlagsNever) == 0;
	}

	static function isUnitType(t:Type):Bool {
		return t.flags & TypeFlagsUnit != 0;
	}

	static function isUnionWithUndefined(t:Type):Bool {
		return t.flags & TypeFlagsUnion != 0 && t.Types()[0].flags & TypeFlagsUndefined != 0;
	}

	static function isUnionWithNull(t:Type):Bool {
		return t.flags & TypeFlagsUnion != 0 && (t.Types()[0].flags & TypeFlagsNull != 0 || t.Types()[1].flags & TypeFlagsNull != 0);
	}

	static function isIntersectionType(t:Type):Bool {
		return t.flags & TypeFlagsIntersection != 0;
	}

	static function isPrimitiveUnion(t:Type):Bool {
		return t.objectFlags & ObjectFlagsPrimitiveUnion != 0;
	}

	static function isNotUndefinedType(t:Type):Bool {
		return t.flags & TypeFlagsUndefined == 0;
	}

	static function isNotNullType(t:Type):Bool {
		return t.flags & TypeFlagsNull == 0;
	}

	static function getConstituentCount(t:Type):Int {
		if (t.flags & TypeFlagsUnionOrIntersection == 0 || t.alias != null) {
			return 1;
		} else if (t.flags & TypeFlagsUnion != 0 && t.AsUnionType().origin != null) {
			return getConstituentCount(t.AsUnionType().origin);
		}
		return getConstituentCountOfTypes(t.Types());
	}

	static function getConstituentCountOfTypes(types:Array<Type>):Int {
		var n = 0;
		if (types != null) {
			for (t in types) {
				n += getConstituentCount(t);
			}
		}
		return n;
	}

	static function forEachType(t:Type, f:(t:Type) -> Void):Void {
		if (t.flags & TypeFlagsUnion != 0) {
			for (u in t.Types()) {
				f(u);
			}
		} else {
			f(t);
		}
	}

	static function someType(t:Type, f:(Type) -> Bool):Bool {
		if (t.flags & TypeFlagsUnion != 0) {
			return Core.Some(t.Types(), f);
		}
		return f(t);
	}

	static function everyType(t:Type, f:(Type) -> Bool):Bool {
		if (t.flags & TypeFlagsUnion != 0) {
			return Core.Every(t.Types(), f);
		}
		return f(t);
	}

	static function everyContainedType(t:Type, f:(Type) -> Bool):Bool {
		if (t.flags & TypeFlagsUnionOrIntersection != 0) {
			return Core.Every(t.Types(), f);
		}
		return f(t);
	}

	static function containsType(types:Array<Type>, t:Type):Bool {
		return Slices.BinarySearchFuncInline(types, t, (a, b) -> CompareTypes(a, b)) /* PORT: perf */.ok;
	}

	static function insertType(types:Array<Type>, t:Type):ValueOk<Array<Type>> {
		final r = Slices.BinarySearchFuncInline(types, t, (a, b) -> CompareTypes(a, b)) /* PORT: perf */;
		if (!r.ok) {
			// PORT: slices.Insert may reuse the backing array; insert into a copy so the caller's slice is unchanged.
			final result = types == null ? [] : types.copy();
			result.insert(r.value, t);
			return new ValueOk<Array<Type>>(result, true);
		}
		return new ValueOk<Array<Type>>(types, false);
	}

	static function countTypes(t:Type):Int {
		if (t.flags & TypeFlagsUnion != 0) {
			return Core.len(t.Types());
		} else if (t.flags & TypeFlagsNever != 0) {
			return 0;
		}
		return 1;
	}

	static function compareTypeIds(t1:Type, t2:Type):Int {
		return t1.id - t2.id;
	}

	static function getIndexNodeForAccessExpression(accessNode:Node):Node {
		switch (accessNode.Kind) {
			case KindElementAccessExpression:
				return accessNode.AsElementAccessExpression().ArgumentExpression;
			case KindIndexedAccessType:
				return accessNode.AsIndexedAccessTypeNode().IndexType;
			case KindComputedPropertyName:
				return accessNode.Expression();
			default:
		}
		return accessNode;
	}

	static function indexTypeLessThan(indexType:Type, limit:Int):Bool {
		return everyType(indexType, (t:Type) -> {
			if (t.flags & TypeFlagsStringOrNumberLiteral != 0) {
				final propName = getPropertyNameFromType(t);
				if (isNumericLiteralName(propName)) {
					final index:Number = Jsnum.FromString(propName);
					return index >= 0 && index < (limit : Number);
				}
			}
			return false;
		});
	}

	static function isConstEnumObjectType(t:Type):Bool {
		return t.objectFlags & ObjectFlagsAnonymous != 0 && t.symbol != null && isConstEnumSymbol(t.symbol);
	}

	static function isConstEnumSymbol(symbol:Symbol):Bool {
		return symbol.Flags & SymbolFlagsConstEnum != 0;
	}

	static function compareTypesEqual(s:Type, t:Type):Ternary {
		if (s == t) {
			return TernaryTrue;
		}
		return TernaryFalse;
	}

	static function hasRestParameter(signature:Node):Bool {
		final last = Core.LastOrNil(signature.Parameters());
		return last != null && isRestParameter(last);
	}

	static function isRestParameter(param:Node):Bool {
		return param.AsParameterDeclaration().DotDotDotToken != null;
	}

	static function getNameFromIndexInfo(info:IndexInfo):std.String {
		if (info.declaration != null) {
			return Scanner.DeclarationNameToString(info.declaration.Parameters()[0].Name());
		}
		return "x";
	}

	static function isExportOrExportExpression(location:Node):Bool {
		return Ast.FindAncestor(location, (n:Node) -> {
			final parent = n.Parent;
			if (parent != null) {
				if (Ast.IsAnyExportAssignment(parent)) {
					return parent.Expression() == n && Ast.IsEntityNameExpression(n);
				}
				if (Ast.IsExportSpecifier(parent)) {
					return parent.AsExportSpecifier().Name() == n || parent.PropertyName() == n;
				}
			}
			return false;
		}) != null;
	}

	static function shouldMarkIdentifierAliasReferenced(node:IdentifierNode):Bool {
		final parent = node.Parent;
		if (parent != null) {
			// A property access expression LHS? checkPropertyAccessExpression will handle that.
			if (Ast.IsPropertyAccessExpression(parent) && parent.Expression() == node) {
				return false;
			}
			// Next two check for an identifier inside a type only export.
			if (Ast.IsExportSpecifier(parent) && parent.IsTypeOnly()) {
				return false;
			}
			if (parent.Parent != null) {
				final greatGrandparent = parent.Parent.Parent;
				if (greatGrandparent != null && Ast.IsExportDeclaration(greatGrandparent) && greatGrandparent.IsTypeOnly()) {
					return false;
				}
			}
		}
		return true;
	}

	static function isInternalModuleImportEqualsDeclaration(node:Node):Bool {
		return node.Kind == KindImportEqualsDeclaration && node.AsImportEqualsDeclaration().ModuleReference.Kind != KindExternalModuleReference;
	}

	static function isPartOfImportEqualsModuleReference(location:Node):Bool {
		final importEquals = Ast.FindAncestorKind(location, KindImportEqualsDeclaration);
		if (importEquals == null) {
			return false;
		}
		var node = location;
		while (node != null && node != importEquals) {
			if (node == importEquals.AsImportEqualsDeclaration().ModuleReference) {
				return true;
			}
			node = node.Parent;
		}
		return false;
	}

	static function getEntityNameFromTypeNode(node:TypeNode):Node {
		switch (node.Kind) {
			case KindTypeReference:
				return node.AsTypeReferenceNode().TypeName;

			case KindExpressionWithTypeArguments:
				if (Ast.IsEntityNameExpression(node.Expression())) {
					return node.Expression();
				}
				return null;

			// These aren't valid TypeNodes, but we treat them as such because of `isPartOfTypeNode`, which returns `true` for things that aren't `TypeNode`s.
			case KindIdentifier | KindQualifiedName:
				return node;
			default:
		}

		return null;
	}

	static function getMappedTypeModifiers(t:Type):MappedTypeModifiers {
		final declaration = t.AsMappedType().declaration;
		var modifiers:MappedTypeModifiers = 0;
		if (declaration.ReadonlyToken != null) {
			modifiers |= Core.IfElse(declaration.ReadonlyToken.Kind == KindMinusToken, MappedTypeModifiersExcludeReadonly, MappedTypeModifiersIncludeReadonly);
		}
		if (declaration.QuestionToken != null) {
			modifiers |= Core.IfElse(declaration.QuestionToken.Kind == KindMinusToken, MappedTypeModifiersExcludeOptional, MappedTypeModifiersIncludeOptional);
		}
		return modifiers;
	}

	// Return -1, 0, or 1, where -1 means optionality is stripped (i.e. -?), 0 means optionality is unchanged, and 1 means
	// optionality is added (i.e. +?).
	static function getMappedTypeOptionality(t:Type):Int {
		final modifiers = getMappedTypeModifiers(t);
		if (modifiers & MappedTypeModifiersExcludeOptional != 0) {
			return -1;
		} else if (modifiers & MappedTypeModifiersIncludeOptional != 0) {
			return 1;
		}
		return 0;
	}

	static function isPartialMappedType(t:Type):Bool {
		return t.objectFlags & ObjectFlagsMapped != 0 && getMappedTypeModifiers(t) & MappedTypeModifiersIncludeOptional != 0;
	}

	static function applyStringMapping(symbol:Symbol, str:std.String):std.String {
		final kind:IntrinsicTypeKind = intrinsicTypeKinds.exists(symbol.Name) ? intrinsicTypeKinds.get(symbol.Name) : IntrinsicTypeKindUnknown;
		switch (kind) {
			case IntrinsicTypeKindUppercase:
				return Stringutil.ToUpperJS(str);
			case IntrinsicTypeKindLowercase:
				return Stringutil.ToLowerJS(str);
			case IntrinsicTypeKindCapitalize:
				final size = str.length == 0 ? 0 : go.Utf16.RuneLen(Stringutil.DecodeJSStringRune(str, 0));
				return Stringutil.ToUpperJS(str.substring(0, size)) + str.substring(size);
			case IntrinsicTypeKindUncapitalize:
				final size = str.length == 0 ? 0 : go.Utf16.RuneLen(Stringutil.DecodeJSStringRune(str, 0));
				return Stringutil.ToLowerJS(str.substring(0, size)) + str.substring(size);
			default:
		}
		return str;
	}

	static function isSpreadArgument(arg:Node):Bool {
		return Ast.IsSpreadElement(arg) || Ast.IsSyntheticExpression(arg) && arg.AsSyntheticExpression().IsSpread;
	}

	static function isZeroBigInt(t:Type):Bool {
		final v = getBigIntLiteralValue(t);
		return v.Negative == false && v.Base10Value == "";
	}

	// --- emitresolver.go ---

	static function newEmitResolver(checker:Checker):EmitResolver {
		final e = new EmitResolver();
		e.checker = checker;
		e.isValueAliasDeclaration = node -> e.isValueAliasDeclarationWorker(node);
		e.aliasMarkingVisitor = node -> e.aliasMarkingVisitorWorker(node);
		e.checkerMu = checker.mu;
		return e;
	}

	static function isCommonJSModuleExports(node:Node):Bool {
		if (Ast.IsBinaryExpression(node) && Ast.IsExpressionStatement(node.Parent) && Ast.IsSourceFile(node.Parent.Parent)
			&& node.Parent.Parent.AsSourceFile().CommonJSModuleIndicator != null) {
			switch (Ast.GetAssignmentDeclarationKind(node)) {
				case JSDeclarationKindModuleExports | JSDeclarationKindExportsProperty:
					return true;
				default:
			}
		}
		return false;
	}

	static function getMeaningOfEntityNameReference(entityName:Node):SymbolFlags {
		// get symbol of the first identifier of the entityName
		if (entityName.Parent.Kind == KindTypeQuery
			|| entityName.Parent.Kind == KindExpressionWithTypeArguments && !Ast.IsPartOfTypeNode(entityName.Parent)
			|| entityName.Parent.Kind == KindComputedPropertyName
			|| entityName.Parent.Kind == KindTypePredicate && entityName.Parent.AsTypePredicateNode().ParameterName == entityName
			|| entityName.Parent.Kind == KindBinaryExpression) {
			// Typeof value
			return SymbolFlagsValue | SymbolFlagsExportValue;
		}
		if (entityName.Kind == KindQualifiedName || entityName.Kind == KindPropertyAccessExpression
			|| entityName.Parent.Kind == KindImportEqualsDeclaration
			|| (entityName.Parent.Kind == KindQualifiedName && entityName.Parent.AsQualifiedName().Left == entityName)
			|| (entityName.Parent.Kind == KindPropertyAccessExpression && entityName.Parent.Expression() == entityName)
			|| (entityName.Parent.Kind == KindElementAccessExpression && entityName.Parent.Expression() == entityName)) {
			// Left identifier from type reference or TypeAlias
			// Entity name of the import declaration
			return SymbolFlagsNamespace;
		}
		// Type Reference or TypeAlias entity = Identifier
		return SymbolFlagsType;
	}

	static function noopAddVisibleAlias(declaration:Node, aliasingStatement:Node):Void {

	}

	static function isConstEnumOrConstEnumOnlyModule(s:Symbol):Bool {
		return isConstEnumSymbol(s) || s.Flags & SymbolFlagsConstEnumOnlyModule != 0;
	}

	// --- exports.go ---

	public static function IsTypeUsableAsPropertyName(t:Type):Bool {
		return isTypeUsableAsPropertyName(t);
	}

	public static function GetPropertyNameFromType(t:Type):std.String {
		return getPropertyNameFromType(t);
	}

	public static function GetDeclarationModifierFlagsFromSymbol(s:Symbol):ModifierFlags {
		return getDeclarationModifierFlagsFromSymbol(s);
	}

	public static function IsTupleType(t:Type):Bool {
		return isTupleType(t);
	}

	// --- flow.go ---

	static function getFlowNodeOfNode(node:Node):FlowNode {
		final flowNodeData = node.FlowNodeData();
		if (flowNodeData != null) {
			return flowNodeData.FlowNode;
		}
		return null;
	}

	static function getBranchLabelAntecedents(flow:FlowNode, reduceLabels:Array<FlowReduceLabelData>):FlowList {
		var i = Core.len(reduceLabels);
		while (i != 0) {
			i--;
			final data = reduceLabels[i];
			if (data.Target == flow) {
				return data.Antecedents;
			}
		}
		return flow.Antecedents;
	}

	static var typeofNEFacts:StringMap<TypeFacts> = {
		final m = new StringMap<TypeFacts>();
		m.set("string", TypeFactsTypeofNEString);
		m.set("number", TypeFactsTypeofNENumber);
		m.set("bigint", TypeFactsTypeofNEBigInt);
		m.set("boolean", TypeFactsTypeofNEBoolean);
		m.set("symbol", TypeFactsTypeofNESymbol);
		m.set("undefined", TypeFactsNEUndefined);
		m.set("object", TypeFactsTypeofNEObject);
		m.set("function", TypeFactsTypeofNEFunction);
		m;
	};

	static function getCandidateVariableDeclarationInitializer(node:Node):Node {
		if (Ast.IsVariableDeclaration(node) && node.Type() == null) {
			final initializer = node.Initializer();
			if (initializer != null) {
				return Ast.SkipParentheses(initializer);
			}
		}
		return null;
	}

	static function isEvolvingArrayTypeList(types:Array<Type>):Bool {
		var hasEvolvingArrayType = false;
		if (types != null) {
			for (t in types) {
				if (t.flags & TypeFlagsNever == 0) {
					if (t.objectFlags & ObjectFlagsEvolvingArray == 0) {
						return false;
					}
					hasEvolvingArrayType = true;
				}
			}
		}
		return hasEvolvingArrayType;
	}

	static final nonDottedNameCacheKey:CacheHashKey = CacheHashKey.OfString("?"); // PORT: CacheHashKey(xxh3.HashString128("?"))

	static function tryGetNameFromType(t:Type):ValueOk<std.String> {
		if (t.flags & TypeFlagsUniqueESSymbol != 0) {
			return new ValueOk<std.String>(t.AsUniqueESSymbolType().name, true);
		} else if (t.flags & TypeFlagsStringOrNumberLiteral != 0) {
			return new ValueOk<std.String>(Evaluator.AnyToString(t.AsLiteralType().value), true);
		}
		return new ValueOk<std.String>("", false);
	}

	static function isCoercibleUnderDoubleEquals(source:Type, target:Type):Bool {
		return source.flags & (TypeFlagsNumber | TypeFlagsString | TypeFlagsBooleanLiteral) != 0
			&& target.flags & (TypeFlagsNumber | TypeFlagsString | TypeFlagsBoolean) != 0;
	}

	// --- grammarchecks.go ---

	static function getIdentifierFromEntityNameExpression(node:Node):Node {
		switch (node.Kind) {
			case KindIdentifier:
				return node;
			case KindPropertyAccessExpression:
				return node.AsPropertyAccessExpression().Name();
			default:
				return null;
		}
	}

	static function isInitializerStringOrNumberLiteralExpression(expr:Expression):Bool {
		return Ast.IsStringOrNumericLiteralLike(expr)
			|| expr.Kind == KindPrefixUnaryExpression && expr.AsPrefixUnaryExpression().Operator == KindMinusToken
			&& expr.AsPrefixUnaryExpression().Operand.Kind == KindNumericLiteral;
	}

	static function isInitializerBigIntLiteralExpression(expr:Expression):Bool {
		if (expr.Kind == KindBigIntLiteral) {
			return true;
		}

		if (expr.Kind == KindPrefixUnaryExpression) {
			final unaryExpr = expr.AsPrefixUnaryExpression();
			return unaryExpr.Operator == KindMinusToken && unaryExpr.Operand.Kind == KindBigIntLiteral;
		}

		return false;
	}

	// --- inference.go ---

	static function getSingleTypeVariableFromIntersectionTypes(n:InferenceState, types:Array<Type>):Type {
		var typeVariable:Type = null;
		if (types != null) {
			for (t in types) {
				if (t.flags & TypeFlagsIntersection == 0) {
					return null;
				}
				final v = Core.Find(t.Types(), (t:Type) -> getInferenceInfoForType(n, t) != null);
				if (v == null || typeVariable != null && v != typeVariable) {
					return null;
				}
				typeVariable = v;
			}
		}
		return typeVariable;
	}

	static function tupleTypesDefinitelyUnrelated(source:Type, target:Type):Bool {
		final s = source.TargetTupleType();
		final t = target.TargetTupleType();
		return t.combinedFlags & ElementFlagsVariadic == 0 && t.minLength > s.minLength
			|| t.combinedFlags & ElementFlagsVariable == 0 && (s.combinedFlags & ElementFlagsVariable != 0 || t.fixedLength < s.fixedLength);
	}

	static function getInferenceInfoForType(n:InferenceState, t:Type):InferenceInfo {
		if (t.flags & TypeFlagsTypeVariable != 0) {
			if (n.inferences != null) {
				for (inference in n.inferences) {
					if (t == inference.typeParameter) {
						return inference;
					}
				}
			}
		}
		return null;
	}

	static function newInferenceInfo(typeParameter:Type):InferenceInfo {
		final info = new InferenceInfo();
		info.typeParameter = typeParameter;
		info.priority = InferencePriorityMaxValue;
		info.topLevel = true;
		info.impliedArity = -1;
		return info;
	}

	static function cloneInferenceInfo(info:InferenceInfo):InferenceInfo {
		final result = new InferenceInfo();
		result.typeParameter = info.typeParameter;
		result.candidates = Slices.Clone(info.candidates);
		result.candidateDepths = Slices.Clone(info.candidateDepths);
		result.contraCandidates = Slices.Clone(info.contraCandidates);
		result.inferredType = info.inferredType;
		result.priority = info.priority;
		result.topLevel = info.topLevel;
		result.isFixed = info.isFixed;
		result.impliedArity = info.impliedArity;
		return result;
	}

	static function clearCachedInferences(inferences:Array<InferenceInfo>):Void {
		if (inferences != null) {
			for (inference in inferences) {
				if (!inference.isFixed) {
					inference.inferredType = null;
				}
			}
		}
	}

	static function hasInferenceCandidates(info:InferenceInfo):Bool {
		return Core.len(info.candidates) != 0 || Core.len(info.contraCandidates) != 0;
	}

	static function hasInferenceCandidatesOrDefault(info:InferenceInfo):Bool {
		return hasInferenceCandidates(info) || hasTypeParameterDefault(info.typeParameter);
	}

	static function hasTypeParameterDefault(tp:Type):Bool {
		if (tp.symbol != null && tp.symbol.Declarations != null) {
			for (d in tp.symbol.Declarations) {
				if (Ast.IsTypeParameterDeclaration(d) && d.AsTypeParameterDeclaration().DefaultType != null) {
					return true;
				}
			}
		}
		return false;
	}

	static function hasOverlappingInferences(a:Array<InferenceInfo>, b:Array<InferenceInfo>):Bool {
		for (i in 0...Core.len(a)) {
			if (hasInferenceCandidates(a[i]) && hasInferenceCandidates(b[i])) {
				return true;
			}
		}
		return false;
	}

	// --- jsdoc.go ---

	static function getAllJSDocTags(node:Node):Array<Node> {
		if (node.Flags & NodeFlagsJSDoc == 0) {
			var current = node;
			while (current != null) {
				final jsdocs = current.JSDoc(null);
				if (Core.len(jsdocs) != 0) {
					final lastJSDoc = jsdocs[jsdocs.length - 1].AsJSDoc();
					if (lastJSDoc.Tags != null) {
						return lastJSDoc.Tags.Nodes;
					}
				}
				current = Ast.GetNextJSDocCommentLocation(current);
			}
		}
		return null;
	}

	// --- jsx.go ---

	public static var JsxNames:JsxNamesStruct = {
		final n = new JsxNamesStruct();
		n.JSX = "JSX";
		n.IntrinsicElements = "IntrinsicElements";
		n.ElementClass = "ElementClass";
		n.ElementAttributesPropertyNameContainer = "ElementAttributesProperty";
		n.ElementChildrenAttributeNameContainer = "ElementChildrenAttribute";
		n.Element = "Element";
		n.ElementType = "ElementType";
		n.IntrinsicAttributes = "IntrinsicAttributes";
		n.IntrinsicClassAttributes = "IntrinsicClassAttributes";
		n.LibraryManagedAttributes = "LibraryManagedAttributes";
		n;
	};

	public static var ReactNames:ReactNamesStruct = {
		final n = new ReactNamesStruct();
		n.Fragment = "Fragment";
		n;
	};

	static function markAsSynthetic(node:Node):Bool {
		node.Loc = new TextRange(-1, -1);
		node.ForEachChild(fn_markAsSynthetic);
		return false;
	}

	// --- mapper.go ---

	static function newTypeMapper(sources:Array<Type>, targets:Array<Type>):TypeMapper {
		if (Core.len(sources) == 1) {
			return newSimpleTypeMapper(sources[0], targets[0]);
		}
		return newArrayTypeMapper(sources, targets);
	}

	static function mergeTypeMappers(m1:TypeMapper, m2:TypeMapper):TypeMapper {
		if (m1 != null) {
			return newMergedTypeMapper(m1, m2);
		}
		return m2;
	}

	static function prependTypeMapping(source:Type, target:Type, mapper:TypeMapper):TypeMapper {
		if (mapper == null) {
			return newSimpleTypeMapper(source, target);
		}
		return newMergedTypeMapper(newSimpleTypeMapper(source, target), mapper);
	}

	static function appendTypeMapping(mapper:TypeMapper, source:Type, target:Type):TypeMapper {
		if (mapper == null) {
			return newSimpleTypeMapper(source, target);
		}
		return newMergedTypeMapper(mapper, newSimpleTypeMapper(source, target));
	}

	static function newSimpleTypeMapper(source:Type, target:Type):TypeMapper {
		final m = new SimpleTypeMapper();
		m.data = m;
		m.source = source;
		m.target = target;
		return m;
	}

	static function newArrayTypeMapper(sources:Array<Type>, targets:Array<Type>):TypeMapper {
		final m = new ArrayTypeMapper();
		m.data = m;
		m.sources = sources;
		m.targets = targets;
		return m;
	}

	static function newArrayToSingleTypeMapper(sources:Array<Type>, target:Type):TypeMapper {
		final m = new ArrayToSingleTypeMapper();
		m.data = m;
		m.sources = sources;
		m.target = target;
		return m;
	}

	static function newDeferredTypeMapper(sources:Array<Type>, targets:Array<() -> Type>):TypeMapper {
		final m = new DeferredTypeMapper();
		m.data = m;
		m.sources = sources;
		m.targets = targets;
		return m;
	}

	static function newFunctionTypeMapper(fn:(Type) -> Type):TypeMapper {
		final m = new FunctionTypeMapper();
		m.data = m;
		m.fn = fn;
		return m;
	}

	static function newMergedTypeMapper(m1:TypeMapper, m2:TypeMapper):TypeMapper {
		final m = new MergedTypeMapper();
		m.data = m;
		m.m1 = m1;
		m.m2 = m2;
		return m;
	}

	static function newCompositeTypeMapper(c:Checker, m1:TypeMapper, m2:TypeMapper):TypeMapper {
		final m = new CompositeTypeMapper();
		m.data = m;
		m.c = c;
		m.m1 = m1;
		m.m2 = m2;
		return m;
	}

	// --- nodebuilder.go ---

	static function simplifyClassDeclaration(f:NodeFactory, classDecl:Node, symbol:Symbol):Node {
		final classDeclarations = Core.Filter(symbol.Declarations, fn_IsClassLike);
		var originalClassDecl:Node = null;
		if (Core.len(classDeclarations) > 0) {
			originalClassDecl = classDeclarations[0];
		} else {
			originalClassDecl = classDecl;
		}
		final modifiers = originalClassDecl.ModifierFlags() & ~(ModifierFlagsExport | ModifierFlagsAmbient);
		final isAnonymous = Ast.IsClassExpression(originalClassDecl);
		if (isAnonymous) {
			final cd = classDecl.AsClassDeclaration();
			classDecl = f.UpdateClassDeclaration(cd, classDecl.Modifiers(), null, cd.TypeParameters, cd.HeritageClauses, cd.Members);
		}
		return Ast.ReplaceModifiers(f, classDecl, f.NewModifierList(Ast.CreateModifiersFromModifierFlags(modifiers, kind -> f.NewModifier(kind))));
	}

	static function simplifyModifiers(f:NodeFactory, newDecl:Node, isDeclKind:(Node) -> Bool, symbol:Symbol):Node {
		final decls = Core.Filter(symbol.Declarations, isDeclKind);
		var declWithModifiers:Node = null;
		if (Core.len(decls) > 0) {
			declWithModifiers = decls[0];
		} else {
			declWithModifiers = newDecl;
		}
		final modifiers = declWithModifiers.ModifierFlags() & ~(ModifierFlagsExport | ModifierFlagsAmbient);
		return Ast.ReplaceModifiers(f, newDecl, f.NewModifierList(Ast.CreateModifiersFromModifierFlags(modifiers, kind -> f.NewModifier(kind))));
	}

	public static function NewNodeBuilder(ch:Checker, e:EmitContext):NodeBuilder {
		return NewNodeBuilderEx(ch, e, null /*idToSymbol*/);
	}

	public static function NewNodeBuilderEx(ch:Checker, e:EmitContext, idToSymbol:IdentityMap<IdentifierNode, Symbol>):NodeBuilder {
		final impl = newNodeBuilderImpl(ch, e, idToSymbol);
		final b = new NodeBuilder();
		b.impl = impl;
		b.ctxStack = [];
		b.host = ch.program;
		return b;
	}

	// --- nodebuilder_hover.go ---

	// isExpanding returns whether the node builder context is operating in hover-expansion mode.
	static function isExpanding(ctx:NodeBuilderContext):Bool {
		return ctx.maxExpansionDepth != -1;
	}

	// typeElementsToClassElements converts TypeElement nodes (PropertySignature, MethodSignature)
	// to their ClassElement equivalents (PropertyDeclaration, MethodDeclaration) so they can be
	// used as members of a ClassDeclaration. Nodes that are already ClassElements pass through unchanged.
	static function typeElementsToClassElements(f:NodeFactory, members:Array<Node>):Array<Node> {
		if (members != null) {
			for (i in 0...members.length) {
				final m = members[i];
				switch (m.Kind) {
					case KindPropertySignature:
						final ps = m.AsPropertySignatureDeclaration();
						members[i] = f.NewPropertyDeclaration(m.Modifiers(), ps.Name(), ps.AsNode().QuestionToken(), ps.Type, null);
					case KindMethodSignature:
						final ms = m.AsMethodSignatureDeclaration();
						members[i] = f.NewMethodDeclaration(m.Modifiers(), null, ms.Name(), ms.AsNode().QuestionToken(), ms.TypeParameters, ms.Parameters, ms.Type, null, null);
					default:
				}
			}
		}
		return members;
	}

	static function isHashPrivate(s:Symbol):Bool {
		return s.ValueDeclaration != null && s.ValueDeclaration.Name() != null && Ast.IsPrivateIdentifier(s.ValueDeclaration.Name());
	}

	// --- nodebuilderimpl.go ---

	static inline final defaultMaximumTruncationLength:Int = 160;

	static inline final noTruncationMaximumTruncationLength:Int = 1000000;

	static function newNodeBuilderImpl(ch:Checker, e:EmitContext, idToSymbol:IdentityMap<IdentifierNode, Symbol>):NodeBuilderImpl {
		if (idToSymbol == null) {
			idToSymbol = new IdentityMap<IdentifierNode, Symbol>();
		}
		final b = new NodeBuilderImpl();
		b.f = e.Factory.AsNodeFactory();
		b.ch = ch;
		b.e = e;
		b.idToSymbol = idToSymbol;
		b.pc = Pseudochecker.NewPseudoChecker(ch.strictNullChecks, ch.exactOptionalPropertyTypes);
		b.cloneBindingNameVisitor = Ast.NewNodeVisitor(node -> b.cloneBindingName(node), b.f, new NodeVisitorHooks());
		return b;
	}

	static function getAccessStack(ref:Node):Array<Node> {
		var state:Node = ref.AsTypeReferenceNode().TypeName;
		final ids:Array<Node> = [];
		while (!Ast.IsIdentifier(state)) {
			final entity = state.AsQualifiedName();
			ids.unshift(entity.Right);
			state = entity.Left;
		}
		ids.unshift(state);
		return ids;
	}

	static function isClassInstanceSide(c:Checker, t:Type):Bool {
		return t.symbol != null && t.symbol.Flags & SymbolFlagsClass != 0
			&& (t == c.getDeclaredTypeOfClassOrInterface(t.symbol) || (t.flags & TypeFlagsObject != 0 && t.objectFlags & ObjectFlagsIsClassInstanceClone != 0));
	}

	static function isIdentifierTypeReference(node:Node):Bool {
		return Ast.IsTypeReferenceNode(node) && Ast.IsIdentifier(node.AsTypeReferenceNode().TypeName);
	}

	static function arrayIsHomogeneous<T>(array:Array<T>, comparer:(a:T, B:T) -> Bool):Bool {
		if (Core.len(array) < 2) {
			return true;
		}
		final first = array[0];
		for (i in 1...array.length) {
			final target = array[i];
			if (!comparer(first, target)) {
				return false;
			}
		}
		return true;
	}

	static function typesAreSameReference(a:Type, b:Type):Bool {
		return a == b || a.symbol != null && a.symbol == b.symbol || a.alias != null && a.alias == b.alias;
	}

	static function getTopmostIndexedAccessType(node:IndexedAccessTypeNode):IndexedAccessTypeNode {
		if (Ast.IsIndexedAccessTypeNode(node.ObjectType)) {
			return getTopmostIndexedAccessType(node.ObjectType.AsIndexedAccessTypeNode());
		}
		return node;
	}

	static function canUsePropertyAccess(name:std.String):Bool {
		if (name.length == 0) {
			return false;
		}
		// TODO: in strada, this only used `isIdentifierStart` on the first character, while this checks the whole string for validity
		// - possible strada bug?
		if (StringTools.startsWith(name, "#")) {
			return name.length > 1 && Scanner.IsIdentifierText(name.substring(1), LanguageVariantStandard);
		}
		return Scanner.IsIdentifierText(name, LanguageVariantStandard);
	}

	static function startsWithSingleOrDoubleQuote(str:std.String):Bool {
		return StringTools.startsWith(str, "'") || StringTools.startsWith(str, "\"");
	}

	static function startsWithSquareBracket(str:std.String):Bool {
		return StringTools.startsWith(str, "[");
	}

	static function isDefaultBindingContext(location:Node):Bool {
		return location.Kind == KindSourceFile || Ast.IsAmbientModule(location);
	}

	static function canHaveModuleSpecifier(node:Node):Bool {
		if (node == null) {
			return false;
		}
		switch (node.Kind) {
			case KindVariableDeclaration | KindBindingElement | KindImportDeclaration | KindExportDeclaration | KindImportEqualsDeclaration | KindImportClause |
				KindNamespaceExport | KindNamespaceImport | KindExportSpecifier | KindImportSpecifier | KindImportType:
				return true;
			default:
		}
		return false;
	}

	public static function TryGetModuleSpecifierFromDeclaration(node:Node):Node {
		final res = tryGetModuleSpecifierFromDeclarationWorker(node);
		if (res == null || !Ast.IsStringLiteral(res)) {
			return null;
		}
		return res;
	}

	static function tryGetModuleSpecifierFromDeclarationWorker(node:Node):Node {
		switch (node.Kind) {
			case KindVariableDeclaration | KindBindingElement:
				final requireCall = Ast.FindAncestor(node.Initializer(), (node:Node) -> {
					return Ast.IsRequireCall(node, true /*requireStringLiteralLikeArgument*/);
				});
				if (requireCall == null) {
					return null;
				}
				return requireCall.Arguments()[0];
			case KindImportDeclaration | KindExportDeclaration | KindJSDocImportTag:
				return node.ModuleSpecifier();
			case KindImportEqualsDeclaration:
				final ref = node.AsImportEqualsDeclaration().ModuleReference;
				if (ref.Kind != KindExternalModuleReference) {
					return null;
				}
				return ref.Expression();
			case KindImportClause:
				if (Ast.IsImportDeclaration(node.Parent)) {
					return node.Parent.ModuleSpecifier();
				}
				return node.Parent.ModuleSpecifier();
			case KindNamespaceExport:
				return node.Parent.ModuleSpecifier();
			case KindNamespaceImport:
				if (Ast.IsImportDeclaration(node.Parent.Parent)) {
					return node.Parent.Parent.ModuleSpecifier();
				}
				return node.Parent.Parent.ModuleSpecifier();
			case KindExportSpecifier:
				return node.Parent.Parent.ModuleSpecifier();
			case KindImportSpecifier:
				if (Ast.IsImportDeclaration(node.Parent.Parent.Parent)) {
					return node.Parent.Parent.Parent.ModuleSpecifier();
				}
				return node.Parent.Parent.Parent.ModuleSpecifier();
			case KindImportType:
				if (Ast.IsLiteralImportTypeNode(node)) {
					return node.AsImportTypeNode().Argument.AsLiteralTypeNode().Literal;
				}
				return null;
			default:
				Debug.AssertNever(node);
				return null;
		}
	}

	static function getEffectiveParameterDeclaration(symbol:Symbol):Node {
		final parameterDeclaration = Ast.GetDeclarationOfKind(symbol, KindParameter);
		if (parameterDeclaration != null) {
			return parameterDeclaration;
		}
		if (symbol.Flags & SymbolFlagsTransient == 0) {
			return Ast.GetDeclarationOfKind(symbol, KindJSDocParameterTag);
		}
		return null;
	}

	static function hasTypeAnnotation(declaration:Declaration):Bool {
		return declaration != null && declaration.Type() != null;
	}

	public static inline final MAX_REVERSE_MAPPED_NESTING_INSPECTION_DEPTH:Int = 3;

	static function classifyPropertyName(name:std.String, stringNamed:Bool, isMethod:Bool):PropertyNameNodeKind {
		if (isMethod && name == "new") {
			return propertyNameNodeKindStringLiteral;
		}
		if (Scanner.IsIdentifierText(name, LanguageVariantStandard)) {
			return propertyNameNodeKindIdentifier;
		}
		return Core.IfElse(!stringNamed && isNumericLiteralName(name) && Jsnum.FromString(name) >= 0, propertyNameNodeKindNumericLiteral,
			propertyNameNodeKindStringLiteral);
	}

	static function getTypeAliasForTypeLiteral(c:Checker, t:Type):Symbol {
		if (t.symbol != null && t.symbol.Flags & SymbolFlagsTypeLiteral != 0 && t.symbol.Declarations != null) {
			final node = Ast.WalkUpParenthesizedTypes(t.symbol.Declarations[0].Parent);
			if (Ast.IsTypeAliasDeclaration(node)) {
				return c.getSymbolOfDeclaration(node);
			}
		}
		return null;
	}

	// --- nodebuilderscopes.go ---

	static function cloneNodeBuilderContext(context:NodeBuilderContext):() -> Void {
		// Make type parameters created within this context not consume the name outside this context
		// The symbol serializer ends up creating many sibling scopes that all need "separate" contexts when
		// it comes to naming things - within a normal `typeToTypeNode` call, the node builder only ever descends
		// through the type tree, so the only cases where we could have used distinct sibling scopes was when there
		// were multiple generic overloads with similar generated type parameter names
		// The effect:
		// When we write out
		// export const x: <T>(x: T) => T
		// export const y: <T>(x: T) => T
		// we write it out like that, rather than as
		// export const x: <T>(x: T) => T
		// export const y: <T_1>(x: T_1) => T_1
		final restoreNames = context.typeParameterNames.EnterScope();
		final restoreNamesByText = context.typeParameterNamesByText.EnterScope();
		final restoreNamesByTextNextNameCount = context.typeParameterNamesByTextNextNameCount.EnterScope();
		final restoreSymbolList = context.typeParameterSymbolList.EnterScope();
		return () -> {
			restoreNames();
			restoreNamesByText();
			restoreNamesByTextNextNameCount();
			restoreSymbolList();
		};
	}

	// --- nodecopy.go ---

	static function newWrappingTracker(inner:SymbolTracker, bound:RecoveryBoundary):WrappingTracker {
		final t = new WrappingTracker();
		t.wrapped = inner;
		t.bound = bound;
		return t;
	}

	static function getExistingNodeTreeVisitor(b:NodeBuilderImpl, bound:RecoveryBoundary):NodeVisitor {
		// TODO: wrap all these closures into methods on an object so we can guarantee we reuse the same memory on each invocation by reusing/resetting the object
		// instead of re-closing-over all of these each time we need a visitor. In theory the compiler could handle this, but in practice closure inlining hasn't been reliable
		var visitor:NodeVisitor = null;
		// note: also handles renaming type parameters renamed within the current context
		final attachSymbolToLeftmostIdentifier = (leftmost:Node, node:Node, sym:Symbol) -> {
			var vis:NodeVisitor = null;
			var visitorFunc:(Node) -> Node = null;
			visitorFunc = (node:Node) -> {
				if (node == leftmost) {
					var type_:Type = null;
					var name:Node = null;
					if (sym != null) {
						type_ = b.ch.getDeclaredTypeOfSymbol(sym);
						if (sym.Flags & SymbolFlagsTypeParameter != 0) {
							name = b.typeParameterToName(type_).AsNode();
						}
					}
					if (name == null) {
						name = b.newIdentifier(node.Text(), sym);
					}
					name = b.setTextRange(name, node);
					b.e.AddEmitFlags(name, EFNoAsciiEscaping);
					return name;
				}
				return b.setTextRange(node.VisitEachChild(vis), node);
			};
			vis = Ast.NewNodeVisitor(visitorFunc, b.f, new NodeVisitorHooks());
			return visitorFunc(node);
		};
		// PORT: Go (bool, *ast.Node, *ast.Symbol) → Triple.
		final trackExistingEntityName = (node:Node, overrideEnclosing:Node) -> {
			var enclosingDeclaration = b.ctx.enclosingDeclaration;
			if (overrideEnclosing != null) {
				enclosingDeclaration = overrideEnclosing;
			}
			var introducesError = false;
			final leftmost = Ast.GetFirstIdentifier(node);
			if (Ast.IsInJSFile(node)
				&& (Ast.IsExportsIdentifier(leftmost) || Ast.IsModuleExportsAccessExpression(leftmost.Parent)
					|| (Ast.IsQualifiedName(leftmost.Parent) && Ast.IsModuleIdentifier(leftmost.Parent.AsQualifiedName().Left)
						&& Ast.IsExportsIdentifier(leftmost.Parent.AsQualifiedName().Right)))) {
				introducesError = true;
				return new Triple<Bool, Node, Symbol>(introducesError, b.setTextRange(ts.ast.Deepclone.DeepCloneNode(b.f, node) /* PORT: import.hx has no `using ts.ast.Deepclone` */, node), null);
			}
			final meaning = getMeaningOfEntityNameReference(node);
			var sym:Symbol = null;
			if (Ast.IsThisIdentifier(leftmost)) {
				// `this` isn't a bindable identifier - skip resolution, find a relevant `this` symbol directly and avoid exhaustive scope traversal
				sym = b.ch.getSymbolOfDeclaration(b.ch.getThisContainer(leftmost, false, false));
				if (b.ch.IsSymbolAccessible(sym, leftmost, meaning, false).Accessibility != SymbolAccessibilityAccessible) {
					introducesError = true;
					b.ctx.tracker.ReportInaccessibleThisError();
				}
				return new Triple<Bool, Node, Symbol>(introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), null);
			}
			sym = b.ch.resolveEntityName(leftmost, meaning, true, true, null);
			if (b.ctx.enclosingDeclaration != null && !(sym != null && sym.Flags & SymbolFlagsTypeParameter != 0)) {
				sym = b.ch.getExportSymbolOfValueSymbolIfExported(sym);
				// Some declarations may be transplanted to a new location.
				// When this happens we need to make sure that the name has the same meaning at both locations
				// We also check for the unknownSymbol because when we create a fake scope some parameters may actually not be usable
				// either because they are the expanded rest parameter,
				// or because they are the newly added parameters from the tuple, which might have different meanings in the original context
				final symAtLocation = b.ch.resolveEntityName(leftmost, meaning, true, true, b.ctx.enclosingDeclaration);
				if (
					// Check for unusable parameters symbols
					symAtLocation == b.ch.unknownSymbol
					// If the symbol is not found, but was not found in the original scope either we probably have an error, don't reuse the node
					|| (symAtLocation == null && sym != null)
					// If the symbol is found both in declaration scope and in current scope then it should point to the same reference
					|| (symAtLocation != null && sym != null
						&& b.ch.getSymbolIfSameReference(b.ch.getExportSymbolOfValueSymbolIfExported(symAtLocation), sym) == null)) {
					// In isolated declaration we will not do rest parameter expansion so there is no need to report on these.
					if (symAtLocation != b.ch.unknownSymbol) {
						b.ctx.tracker.ReportInferenceFallback(node);
					}
					introducesError = true;
					return new Triple<Bool, Node, Symbol>(introducesError, b.setTextRange(ts.ast.Deepclone.DeepCloneNode(b.f, node) /* PORT: import.hx has no `using ts.ast.Deepclone` */, node), sym);
				} else {
					sym = symAtLocation;
				}
			}

			if (sym != null) {
				// If a parameter is resolvable in the current context it is also visible, so no need to go to symbol accesibility
				if (sym.Flags & SymbolFlagsFunctionScopedVariable != 0 && sym.ValueDeclaration != null) {
					if (Ast.IsPartOfParameterDeclaration(sym.ValueDeclaration) || Ast.IsJSDocParameterTag(sym.ValueDeclaration)) {
						return new Triple<Bool, Node, Symbol>(introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), null);
					}
				}
				if (sym.Flags & SymbolFlagsTypeParameter == 0 /* Type parameters are visible in the current context if they are are resolvable */
					&& !Ast.IsDeclarationName(node)
					&& b.ch.IsSymbolAccessible(sym, enclosingDeclaration, meaning, false).Accessibility != SymbolAccessibilityAccessible) {
					b.ctx.tracker.ReportInferenceFallback(node);
					introducesError = true;
				} else {
					b.ctx.tracker.TrackSymbol(sym, enclosingDeclaration, meaning);
				}
				return new Triple<Bool, Node, Symbol>(introducesError, attachSymbolToLeftmostIdentifier(leftmost, node, sym), null);
			}
			return new Triple<Bool, Node, Symbol>(introducesError, b.setTextRange(ts.ast.Deepclone.DeepCloneNode(b.f, node) /* PORT: import.hx has no `using ts.ast.Deepclone` */, node), null);
		};
		var tryVisitSimpleTypeNode:(node:Node) -> Node = null;
		final tryVisitIndexedAccess = (node:Node) -> {
			final resultObjectType = tryVisitSimpleTypeNode(node.AsIndexedAccessTypeNode().ObjectType);
			if (resultObjectType == null) {
				return null;
			}
			return b.setTextRange(b.f.UpdateIndexedAccessTypeNode(node.AsIndexedAccessTypeNode(), resultObjectType,
				visitor.VisitNode(node.AsIndexedAccessTypeNode().IndexType)), node);
		};
		final tryVisitKeyOf = (node:Node) -> {
			final to = node.AsTypeOperatorNode();
			final t = tryVisitSimpleTypeNode(to.Type);
			if (t == null) {
				return null;
			}
			return b.setTextRange(b.f.UpdateTypeOperatorNode(to, to.Operator, t), node);
		};
		final tryVisitTypeQuery = (node:Node) -> {
			final r = trackExistingEntityName(node.AsTypeQueryNode().ExprName, null);
			final introducesError = r.a;
			final exprName = r.b;
			if (!introducesError) {
				return b.setTextRange(b.f.UpdateTypeQueryNode(node.AsTypeQueryNode(), exprName, visitor.VisitNodes(node.AsTypeQueryNode().TypeArguments)), node);
			}

			final serializedName = b.serializeTypeName(node.AsTypeQueryNode().ExprName, true, visitor.VisitNodes(node.AsTypeQueryNode().TypeArguments));
			if (serializedName != null) {
				return b.setTextRange(serializedName, node.AsTypeQueryNode().ExprName);
			}
			return null;
		};
		final tryVisitTypeReference = (node:Node) -> {
			if (Ast.IsConstTypeReference(node)) {
				return null;
			}
			final s = b.tryGetResolvedSymbolFromTypeNode(node);
			if (s == null) {
				return null; // ???
			}
			if (s.Flags & SymbolFlagsTypeParameter != 0) {
				final declaredType = b.ch.getDeclaredTypeOfSymbol(s);
				if (b.ctx.mapper != null && b.ctx.mapper.Map(declaredType) != declaredType) {
					return null; // refers to type parameter remapped by context (TODO improvement: just return the remapped param name?)
				}
			}
			if (!b.canReuseExistingJSTypeNode(node, b.getTypeFromTypeNode(node, false))) {
				// fallback to serialization for jsdoc types that have insufficient or incomplete type args, or are remapped by the checker in only jsdoc contexts
				// TODO: remappings like `promise` -> `Promise<any>` are static, we *could* statically remap the nodes, too. But that only matters for `isolatedDeclarations`
				// in JS, should we enable that.
				return null;
			}
			final r = trackExistingEntityName(node.AsTypeReferenceNode().TypeName, null);
			final introducesError = r.a;
			final newName = r.b;
			if (!introducesError) {
				final typeArguments = visitor.VisitNodes(node.AsTypeReferenceNode().TypeArguments);
				return b.setTextRange(b.f.UpdateTypeReferenceNode(node.AsTypeReferenceNode(), newName, typeArguments), node);
			} else {
				final serializedName = b.serializeTypeName(node.AsTypeReferenceNode().TypeName, false, visitor.VisitNodes(node.AsTypeReferenceNode().TypeArguments));
				if (serializedName != null) {
					return b.setTextRange(serializedName, node.AsTypeReferenceNode().TypeName);
				}
				return null;
			}
		};
		tryVisitSimpleTypeNode = (node:Node) -> {
			final innerNode = Ast.SkipParentheses(node);
			switch (innerNode.Kind) {
				case KindTypeReference:
					return tryVisitTypeReference(innerNode);
				case KindTypeQuery:
					return tryVisitTypeQuery(innerNode);
				case KindIndexedAccessType:
					return tryVisitIndexedAccess(innerNode);
				case KindTypeOperator:
					if (innerNode.AsTypeOperatorNode().Operator == KindKeyOfKeyword) {
						return tryVisitKeyOf(innerNode);
					}
				default:
			}
			return visitor.VisitNode(node);
		};
		final visitExistingNodeTreeSymbolsWorker = (node:Node) -> {
			final factory = b.f;
			// !!! TODO: the reparser *should* make all the jsdoc remapping logic here redundant,
			// assuming we only ever try to preserve reparsed nodes and never walk back to the jsdoc "originals"
			// accidentally.
			// Still, what can be ported of the logic is here, just in case.
			// Begin JSDoc handling
			if (node.Kind == KindJSDocTypeExpression) {
				// Unwrap JSDocTypeExpressions
				return visitor.VisitNode(node.AsJSDocTypeExpression().Type);
			}
			// !!! TODO: We don't _actually_ support jsdoc namepath types, emit `any` instead; verify we handle as gracefully as strada
			if (node.Kind == KindJSDocAllType /* || node.Kind == ast.JSDocNamepathType */) {
				return factory.NewKeywordTypeNode(KindAnyKeyword);
			}
			if (node.Kind == KindJSDocNullableType) {
				final unionMembers:Array<Node> = [
					visitor.VisitNode(node.AsJSDocNullableType().Type),
					factory.NewLiteralTypeNode(factory.NewKeywordExpression(KindNullKeyword))
				];
				return factory.NewUnionTypeNode(factory.NewNodeList(unionMembers));
			}
			if (node.Kind == KindJSDocOptionalType) {
				final unionMembers:Array<Node> = [
					visitor.VisitNode(node.AsJSDocOptionalType().Type),
					factory.NewKeywordTypeNode(KindUndefinedKeyword)
				];
				return factory.NewUnionTypeNode(factory.NewNodeList(unionMembers));
			}
			if (node.Kind == KindJSDocNonNullableType) {
				// Unwrap
				return visitor.VisitNode(node.AsJSDocNonNullableType().Type);
			}
			if (node.Kind == KindJSDocVariadicType) { // !!! TODO: verify this matches how jsdoc variadics are actually handled now?
				return factory.NewArrayTypeNode(visitor.VisitNode(node.AsJSDocVariadicType().Type));
			}
			if (node.Kind == KindJSDocTypeLiteral) {
				var members:Array<Node> = null;
				final tags = node.AsJSDocTypeLiteral().JSDocPropertyTags;
				if (tags != null) {
					for (t in tags) {
						if (t.Kind != KindJSDocPropertyTag && t.Kind != KindJSDocParameterTag) {
							continue;
						}
						final n = t.Name();
						var targetName:Node = null;
						if (Ast.IsIdentifier(n)) {
							targetName = n;
						} else {
							targetName = n.AsQualifiedName().Right; // !!! TODO: without typesystem backup, doing this cast unguarded seems really suspect, even though it is what strada does
						}
						final name = visitor.VisitNode(targetName);
						final shouldBeOptional = t.AsJSDocParameterOrPropertyTag().IsBracketed
							|| (t.TypeExpression() != null && t.TypeExpression().Kind == KindJSDocOptionalType);
						var question:Node = null;
						if (shouldBeOptional) {
							question = factory.NewToken(KindQuestionToken);
						}
						final ty = visitor.VisitNode(t.TypeExpression()); // !!! TODO: alternate lookup locations for the type? serialize on demand if it doesn't serialze? strada does something funky here.

						if (members == null) {
							members = [];
						}
						members.push(factory.NewPropertySignatureDeclaration(null, name, question, ty, null));
					}
				}
				return factory.NewTypeLiteralNode(factory.NewNodeList(members));
			}
			// End JSDoc handling

			if (Ast.IsTypeReferenceNode(node) && Ast.IsIdentifier(node.AsTypeReferenceNode().TypeName)
				&& node.AsTypeReferenceNode().TypeName.AsIdentifier().Text == "") {
				final replacement = factory.NewKeywordTypeNode(KindAnyKeyword);
				b.e.SetOriginal(replacement, node);
				return replacement;
			}
			if (Ast.IsThisTypeNode(node)) {
				// TODO: strada never marks `this` type nodes as an error - it calls `canReuseTypeNode` on it, but that function always returns `true` for `this`
				// type nodes, which in turn fails to verify that the `this` context is the same between the source and target locations. The conservative thing is to
				// _never_ copy a `this`. We could improve this, but strada is *definitely* wrong and overbroad here. (note that we're inling uses of `canReuseTypeNode`
				// in corsa because of the unfurled host structure meaning we don't need to defer to a host object for functionality it needs)
				// bound.markError(nil) // conservative approach
				return node;
			}
			if (Ast.IsTypeParameterDeclaration(node)) {
				final newName = trackExistingEntityName(node.Name(), null).b;
				return factory.UpdateTypeParameterDeclaration(node.AsTypeParameterDeclaration(), visitor.VisitModifiers(node.Modifiers()), newName,
					visitor.VisitNode(node.AsTypeParameterDeclaration().Constraint), visitor.VisitNode(node.AsTypeParameterDeclaration().Expression),
					visitor.VisitNode(node.AsTypeParameterDeclaration().DefaultType));
			}
			if (Ast.IsIndexedAccessTypeNode(node)) {
				final result = tryVisitIndexedAccess(node);
				if (result != null) {
					return result;
				}
				bound.markError(null);
				return node;
			}
			if (Ast.IsTypeReferenceNode(node)) {
				final result = tryVisitTypeReference(node);
				if (result != null) {
					return result;
				}
				bound.markError(null);
				return node;
			}
			if (Ast.IsTypeQueryNode(node)) {
				final result = tryVisitTypeQuery(node);
				if (result != null) {
					return result;
				}
				bound.markError(null);
				return node;
			}
			if (Ast.IsTypeOperatorNode(node)) {
				if (node.AsTypeOperatorNode().Operator == KindUniqueKeyword && node.AsTypeOperatorNode().Type.Kind == KindSymbolKeyword) {
					final nonFakeEnclosing = b.getEnclosingDeclarationIgnoringFakeScope();
					final sameScope = Ast.FindAncestor(node, (a:Node) -> {
						return a == nonFakeEnclosing;
					});
					if (sameScope == null) {
						bound.markError(null);
						return node;
					}
				} else if (node.AsTypeOperatorNode().Operator == KindKeyOfKeyword) {
					final result = tryVisitKeyOf(node);
					if (result != null) {
						return result;
					}
					bound.markError(null);
					return node;
				}
			}
			if (Ast.IsLiteralImportTypeNode(node)) {
				// assert keyword in imported attributes is deprecated, so we don't reuse types that contain it
				// Ex: import("pkg", { assert: {} }
				if (node.AsImportTypeNode().Attributes != null && node.AsImportTypeNode().Attributes.AsImportAttributes().Token == KindAssertKeyword) {
					bound.markError(null);
					return node;
				}
				final t = b.getTypeFromTypeNode(node, true);
				if (t == null) {
					bound.markError(null);
					return node;
				}
				if (Ast.IsInJSFile(node)) {
					// !!! TODO: invalidate node reuse if js fallback logic used in type param list/typeof lookup (but isn't this logic gone?)
					// s := b.ch.symbolNodeLinks.Get(node).resolvedSymbol
				}
				final originalSpec = node.AsImportTypeNode().Argument.AsLiteralTypeNode().Literal;
				var specifier = b.rewriteModuleSpecifier(node, originalSpec);
				if (originalSpec == specifier) {
					specifier = visitor.VisitNode(specifier); // visit node if not replaced
				}
				var arg = node.AsImportTypeNode().Argument;
				if (specifier != originalSpec) {
					arg = factory.NewLiteralTypeNode(specifier);
				}
				return factory.UpdateImportTypeNode(node.AsImportTypeNode(), node.AsImportTypeNode().IsTypeOf, arg,
					visitor.VisitNode(node.AsImportTypeNode().Attributes), visitor.VisitNode(node.AsImportTypeNode().Qualifier),
					visitor.VisitNodes(node.AsImportTypeNode().TypeArguments));
			}
			if (node.Name() != null && node.Name().Kind == KindComputedPropertyName && !b.ch.hasLateBindableName(node)) {
				if (!Ast.HasDynamicName(node)) {
					// !!! TODO: This matches strada, but rather than recursing, this should probably fall down to later cases.
					// Take a `["field"]` property declaration - it still needs a `: any` appended to it
					return visitor.VisitEachChild(node);
				}
				// !!! TODO: this condition matches strada, but it just seems wrong? Or at the very least extraordinarily approximate, and doesn't flag a builder error...
				final shouldRemoveDeclaration = !((b.ctx.internalFlags & InternalFlagsAllowUnresolvedNames != 0)
					&& Ast.IsEntityNameExpression(node.Name().AsComputedPropertyName().Expression)
					&& (b.ch.checkComputedPropertyName(node.Name()).flags & TypeFlagsAny != 0));
				if (shouldRemoveDeclaration) {
					return null;
				}
			}
			if ((Ast.IsFunctionLike(node) && node.Type() == null)
				|| (Ast.IsPropertyDeclaration(node) && node.Type() == null && node.Initializer() == null)
				|| (Ast.IsPropertySignatureDeclaration(node) && node.Type() == null && node.Initializer() == null)
				|| (Ast.IsParameterDeclaration(node) && node.Type() == null && node.Initializer() == null)) {
				var visited = visitor.VisitEachChild(node);
				if (visited == node) {
					visited = b.setTextRange(node.Clone(factory), node);
				}
				node = visited;
				final newType = factory.NewKeywordTypeNode(KindAnyKeyword);
				switch (node.Kind) {
					case KindPropertyDeclaration:
						return factory.UpdatePropertyDeclaration(node.AsPropertyDeclaration(), node.Modifiers(), node.Name(), node.PostfixToken(), newType, null);
					case KindPropertySignature:
						return factory.UpdatePropertySignatureDeclaration(node.AsPropertySignatureDeclaration(), node.Modifiers(), node.Name(), node.PostfixToken(),
							newType, null);
					case KindParameter:
						return factory.UpdateParameterDeclaration(node.AsParameterDeclaration(), null, node.AsParameterDeclaration().DotDotDotToken, node.Name(),
							node.AsParameterDeclaration().QuestionToken, newType, null);
					case KindMethodSignature:
						return factory.UpdateMethodSignatureDeclaration(node.AsMethodSignatureDeclaration(), node.Modifiers(), node.Name(),
							node.AsMethodSignatureDeclaration().PostfixToken, node.AsMethodSignatureDeclaration().TypeParameters,
							node.AsMethodSignatureDeclaration().Parameters, newType);
					case KindCallSignature:
						return factory.UpdateCallSignatureDeclaration(node.AsCallSignatureDeclaration(), node.AsCallSignatureDeclaration().TypeParameters,
							node.AsCallSignatureDeclaration().Parameters, newType);
					case KindJSDocSignature:
						return factory.UpdateJSDocSignature(node.AsJSDocSignature(), node.AsJSDocSignature().TypeParameters, node.AsJSDocSignature().Parameters,
							newType);
					case KindConstructSignature:
						return factory.UpdateConstructSignatureDeclaration(node.AsConstructSignatureDeclaration(),
							node.AsConstructSignatureDeclaration().TypeParameters, node.AsConstructSignatureDeclaration().Parameters, newType);
					case KindIndexSignature:
						return factory.UpdateIndexSignatureDeclaration(node.AsIndexSignatureDeclaration(), node.Modifiers(),
							node.AsIndexSignatureDeclaration().Parameters, newType);
					case KindFunctionType:
						return factory.UpdateFunctionTypeNode(node.AsFunctionTypeNode(), node.AsFunctionTypeNode().TypeParameters,
							node.AsFunctionTypeNode().Parameters, newType);
					case KindConstructorType:
						return factory.UpdateConstructorTypeNode(node.AsConstructorTypeNode(), node.Modifiers(), node.AsConstructorTypeNode().TypeParameters,
							node.AsConstructorTypeNode().Parameters, newType);
					default:
				}
			}
			if (Ast.IsComputedPropertyName(node) && Ast.IsEntityNameExpression(node.AsComputedPropertyName().Expression)) {
				final r = trackExistingEntityName(node.AsComputedPropertyName().Expression, null);
				if (!r.a) {
					return factory.UpdateComputedPropertyName(node.AsComputedPropertyName(), r.b);
				} else {
					// !!! TODO: rewriting computed names based on evaluator/typecheck results?
					// strada's behavior seems hard to justify vs marking an error and moving on
					bound.markError(null);
					return visitor.VisitEachChild(node);
				}
			}
			if (Ast.IsTypePredicateNode(node)) {
				var parameterName:Node = null;
				if (Ast.IsIdentifier(node.AsTypePredicateNode().ParameterName)) {
					final r = trackExistingEntityName(node.AsTypePredicateNode().ParameterName, null);
					// Should not usually happen the only case is when a type predicate comes from a JSDoc type annotation with it's own parameter symbol definition.
					// /** @type {(v: unknown) => v is undefined} */
					// const isUndef = v => v === undefined;
					if (r.a) {
						bound.markError(null);
					}
					parameterName = r.b;
				} else {
					parameterName = node.AsTypePredicateNode().ParameterName.Clone(factory);
				}
				return factory.UpdateTypePredicateNode(node.AsTypePredicateNode(), visitor.VisitNode(node.AsTypePredicateNode().AssertsModifier), parameterName,
					visitor.VisitNode(node.AsTypePredicateNode().Type));
			}
			if (Ast.IsConditionalTypeNode(node)) {
				final checkType = visitor.VisitNode(node.AsConditionalTypeNode().CheckType);
				final dispose = b.enterNewScope(node, null, b.ch.getInferTypeParameters(node), null, null);
				final extendsType = visitor.VisitNode(node.AsConditionalTypeNode().ExtendsType);
				final trueType = visitor.VisitNode(node.AsConditionalTypeNode().TrueType);
				dispose();
				final falseType = visitor.VisitNode(node.AsConditionalTypeNode().FalseType);
				return factory.UpdateConditionalTypeNode(node.AsConditionalTypeNode(), checkType, extendsType, trueType, falseType);
			}

			// style applications
			if (Ast.IsTupleTypeNode(node) || (b.ctx.flags & FlagsMultilineObjectLiterals == 0 && Ast.IsTypeLiteralNode(node)) || Ast.IsMappedTypeNode(node)) {
				// make tuples/types/mappedtypes single line
				var res = visitor.VisitEachChild(node);
				if (res == node) {
					res = res.Clone(factory);
					res = b.setTextRange(res, node);
				}
				b.e.AddEmitFlags(res, EFSingleLine);
				return res;
			}

			if (Ast.IsStringLiteralLike(node)) {
				// Preserve the original characters of the literal (e.g. emojis) in declaration emit
				// rather than escaping them as ASCII Unicode escapes. Mirrors TypeScript's behavior
				// for synthesized string literal types in the node builder (checker.ts:6853).
				final c = node.Clone(b.f);
				if (Ast.IsStringLiteral(node) && b.ctx.flags & FlagsUseSingleQuotesForStringLiteralType != 0
					&& node.AsStringLiteral().TokenFlags & TokenFlagsSingleQuote == 0) {
					// set single quote on string literals
					c.AsStringLiteral().TokenFlags = (c.AsStringLiteral().TokenFlags : Int) ^ (TokenFlagsSingleQuote : Int);
				}
				b.e.AddEmitFlags(c, EFNoAsciiEscaping);
				return c;
			}

			return visitor.VisitEachChild(node);
		};
		var nonLocalNode = true;
		final hooks = new NodeVisitorHooks();
		hooks.VisitNodes = (nodes:NodeList, v:NodeVisitor) -> {
			var res = v.VisitNodes(nodes);
			if (nonLocalNode && res != null) {
				// Remove position data from node lists originating in other files
				if (res == nodes) {
					res = nodes.Clone(b.f);
				}
				res.Loc = new TextRange(-1, -1);
			}
			return res;
		};
		hooks.VisitNode = (node:Node, v:NodeVisitor) -> {
			// Capture if the current node is in the current file so node lists knoww if they can keep positions or not
			final oldNonLocalNode = nonLocalNode;
			nonLocalNode = b.ctx.enclosingFile == null || b.ctx.enclosingFile != Ast.GetSourceFileOfNode(b.e.MostOriginal(node));
			final res = v.VisitNode(node);
			nonLocalNode = oldNonLocalNode;
			return res;
		};
		visitor = Ast.NewNodeVisitor((node:Node) -> {
			// If there was an error in a sibling node bail early, the result will be discarded anyway
			if (bound.hadError) {
				return node;
			}
			final recover_ = bound.startRecoveryScope();
			final introducesNewScope = Ast.IsFunctionLike(node) || Ast.IsMappedTypeNode(node);
			var exit:() -> Void = null;
			if (introducesNewScope) {
				var params:Array<Symbol> = null;
				var typeParams:Array<Type> = null;
				if (Ast.IsFunctionLike(node)) {
					final sig = b.ch.getSignatureFromDeclaration(node);
					params = sig.parameters;
					typeParams = sig.typeParameters;
				} else if (Ast.IsConditionalTypeNode(node)) { // !!! TODO: impossible in combination with the scope start check???
					typeParams = b.ch.getInferTypeParameters(node);
				} else if (Ast.IsMappedTypeNode(node)) {
					typeParams = [b.ch.getDeclaredTypeOfTypeParameter(b.ch.getSymbolOfDeclaration(node.AsMappedTypeNode().TypeParameter))];
				}
				exit = b.enterNewScope(node, params, typeParams, null, null);
			}
			var result = visitExistingNodeTreeSymbolsWorker(node);
			if (exit != null) {
				exit();
			}

			if (result == node && !Ast.NodeIsSynthesized(node)) {
				result = ts.ast.Deepclone.DeepCloneNode(b.f, node) /* PORT: import.hx has no `using ts.ast.Deepclone` */; // always clone a new node
			}

			// We want to clone the subtree, so when we mark it up with __pos and __end in quickfixes,
			//  we don't get odd behavior because of reused nodes. We also need to clone to _remove_
			//  the position information if the node comes from a different file than the one the node builder
			//  is set to build for (even though we are reusing the node structure, the position information
			//  would make the printer print invalid spans for literals and identifiers, and the formatter would
			//  choke on the mismatched positonal spans between a parent and an injected child from another file).
			result = b.setTextRange(result, node);

			if (bound.hadError) {
				if (Ast.IsTypeNode(node) && !Ast.IsTypePredicateNode(node)) {
					bound.endRecoveryScope(recover_);
					// TODO: this fallback matches strada behavior, but it lacks any verification that the type from `node` actually matches
					// the type we'd expect at this traversal position within the parent type.
					final t = b.getTypeFromTypeNode(node, false);
					return b.typeToTypeNode(t);
				}
				return b.setTextRange(node.Clone(b.f), node);
			}

			return result;
		}, b.f, hooks);
		return visitor;
	}

	// --- printer.go ---

	// TODO: Memoize once per checker to retain threadsafety
	static function createPrinterWithDefaults(emitContext:EmitContext):Printer {
		return Printer.NewPrinter(new PrinterOptions(), new PrintHandlers(), emitContext);
	}

	static function createPrinterWithRemoveComments(emitContext:EmitContext):Printer {
		final options = new PrinterOptions();
		options.RemoveComments = true;
		return Printer.NewPrinter(options, new PrintHandlers(), emitContext);
	}

	static function createPrinterWithRemoveCommentsOmitTrailingSemicolonNeverAsciiEscape(emitContext:EmitContext):Printer {
		// TODO: OmitTrailingSemicolon support
		final options = new PrinterOptions();
		options.RemoveComments = true;
		options.NeverAsciiEscape = true;
		return Printer.NewPrinter(options, new PrintHandlers(), emitContext);
	}

	static function createPrinterWithRemoveCommentsNeverAsciiEscape(emitContext:EmitContext):Printer {
		final options = new PrinterOptions();
		options.RemoveComments = true;
		options.NeverAsciiEscape = true;
		return Printer.NewPrinter(options, new PrintHandlers(), emitContext);
	}

	static function getTrailingSemicolonDeferringWriter(writer:EmitTextWriter):EmitTextWriter {
		final w = new SemicolonRemoverWriter();
		w.hasPendingSemicolon = false;
		w.inner = writer;
		return w;
	}

	static function toNodeBuilderFlags(flags:TypeFormatFlags):Flags {
		return (flags & TypeFormatFlagsNodeBuilderFlagsMask : Int);
	}

	// --- pseudotypenodebuilder.go ---

	static function isStructuralPseudoType(t:PseudoType):Bool {
		switch (t.Kind) {
			case PseudoTypeKindObjectLiteral | PseudoTypeKindTuple | PseudoTypeKindSingleCallSignature:
				return true;
			case PseudoTypeKindMaybeConstLocation:
				final d = t.AsPseudoTypeMaybeConstLocation();
				return isStructuralPseudoType(d.ConstType) || isStructuralPseudoType(d.RegularType);
			default:
		}
		return false;
	}

	// --- relater.go ---

	// This function exists to constrain the types of values that can be used as recursion IDs.
	static function asRecursionId<T>(value:T):RecursionId {
		final r = new RecursionId();
		r.value = value;
		return r;
	}

	static function createDiagnosticChainFromErrorChain(chain:ErrorChain, errorNode:Node, relatedInfo:Array<Diagnostic>):Diagnostic {
		while (chain != null && chain.message.ElidedInCompatibilityPyramid()) {
			chain = chain.next;
		}
		if (chain == null) {
			return null;
		}
		final next = createDiagnosticChainFromErrorChain(chain.next, errorNode, relatedInfo);
		final args:Array<Any> = chain.args == null ? [] : chain.args;
		if (next == null) {
			return NewDiagnosticForNode(errorNode, chain.message, ...args).SetRelatedInfo(relatedInfo);
		}
		return Ast.NewDiagnosticChain(next, chain.message, ...args);
	}

	static function isHyphenatedJsxName(name:std.String):Bool {
		return name.indexOf("-") >= 0;
	}

	static function isExcessPropertyCheckTarget(t:Type):Bool {
		return t.flags & TypeFlagsObject != 0 && t.objectFlags & ObjectFlagsObjectLiteralPatternWithComputedProperties == 0
			|| t.flags & TypeFlagsNonPrimitive != 0
			|| t.flags & TypeFlagsSubstitution != 0 && isExcessPropertyCheckTarget(t.AsSubstitutionType().baseType)
			|| t.flags & TypeFlagsUnion != 0 && Core.Some(t.Types(), fn_isExcessPropertyCheckTarget)
			|| t.flags & TypeFlagsIntersection != 0 && Core.Every(t.Types(), fn_isExcessPropertyCheckTarget);
	}

	// The recursion identity of a type is an object identity that is shared among multiple instantiations of the type.
	// We track recursion identities in order to identify deeply nested and possibly infinite type instantiations with
	// the same origin. For example, when type parameters are in scope in an object type such as { x: T }, all
	// instantiations of that type have the same recursion identity. The default recursion identity is the object
	// identity of the type, meaning that every type is unique. Generally, types with constituents that could circularly
	// reference the type have a recursion identity that differs from the object identity.
	static function getRecursionIdentity(t:Type):RecursionId {
		// Object and array literals are known not to contain recursive references and don't need a recursion identity.
		if (t.flags & TypeFlagsObject != 0 && !isObjectOrArrayLiteralType(t)) {
			if (t.objectFlags & ObjectFlagsReference != 0 && t.AsTypeReference().node != null) {
				// Deferred type references are tracked through their associated AST node. This gives us finer
				// granularity than using their associated target because each manifest type reference has a
				// unique AST node.
				return asRecursionId(t.AsTypeReference().node);
			}
			if (t.symbol != null && !(t.objectFlags & ObjectFlagsAnonymous != 0 && t.symbol.Flags & SymbolFlagsClass != 0)
				&& t.objectFlags & ObjectFlagsFromTypeNode == 0) {
				// We track object types that have a symbol by that symbol (representing the origin of the type), but
				// exclude the static sides of classes (since they share their symbols with the instance sides) and type
				// references that originate in resolution of AST type nodes (since such type nodes cannot be the source
				// of generative recursion without first being instantiated).
				return asRecursionId(t.symbol);
			}
			if (isTupleType(t) && t.objectFlags & ObjectFlagsFromTypeNode == 0) {
				return asRecursionId(t.Target());
			}
		}
		if (t.flags & TypeFlagsTypeParameter != 0 && t.symbol != null) {
			// We use the symbol of the type parameter such that all "fresh" instantiations of that type parameter
			// have the same recursion identity.
			return asRecursionId(t.symbol);
		}
		if (t.flags & TypeFlagsIndexedAccess != 0) {
			// Identity is the leftmost object type in a chain of indexed accesses, eg, in A[P1][P2][P3] it is A.
			t = t.AsIndexedAccessType().objectType;
			while (t.flags & TypeFlagsIndexedAccess != 0) {
				t = t.AsIndexedAccessType().objectType;
			}
			return asRecursionId(t);
		}
		if (t.flags & TypeFlagsConditional != 0) {
			// The root object represents the origin of the conditional type
			return asRecursionId(t.AsConditionalType().root.node.AsNode());
		}
		return asRecursionId(t);
	}

	static function excludeProperties(properties:Array<Symbol>, excludedProperties:Set<std.String>):Array<Symbol> {
		if (excludedProperties.Len() == 0 || Core.len(properties) == 0) {
			return properties;
		}
		var reduced:Array<Symbol> = null;
		var excluded = false;
		for (i in 0...properties.length) {
			final prop = properties[i];
			if (!excludedProperties.Has(prop.Name)) {
				if (excluded) {
					reduced.push(prop);
				}
			} else if (!excluded) {
				// PORT: slices.Clip(properties[:i]) — a fresh array, so appends never touch properties.
				reduced = properties.slice(0, i);
				excluded = true;
			}
		}
		if (excluded) {
			return reduced;
		}
		return properties;
	}

	static function isObjectOrInstantiableNonPrimitive(t:Type):Bool {
		return t.flags & (TypeFlagsObject | TypeFlagsInstantiableNonPrimitive) != 0;
	}

	static function isNonPrimitiveType(t:Type):Bool {
		return t.flags & TypeFlagsPrimitive == 0;
	}

	static function visibilityToString(flags:ModifierFlags):std.String {
		if (flags == ModifierFlagsPrivate) {
			return "private";
		}
		if (flags == ModifierFlagsProtected) {
			return "protected";
		}
		return "public";
	}

	static function shouldCheckAsExcessProperty(prop:Symbol, container:Symbol):Bool {
		return prop.ValueDeclaration != null && container.ValueDeclaration != null && prop.ValueDeclaration.Parent == container.ValueDeclaration;
	}

	static function isIgnoredJsxProperty(source:Type, sourceProp:Symbol):Bool {
		return source.objectFlags & ObjectFlagsJsxAttributes != 0 && isHyphenatedJsxName(sourceProp.Name);
	}

	static function addToDottedName(head:std.String, tail:std.String):std.String {
		if (StringTools.startsWith(head, "new ")) {
			head = "(" + head + ")";
		}
		var pos = 0;
		while (true) {
			if (StringTools.startsWith(tail.substring(pos), "(")) {
				pos++;
			} else if (StringTools.startsWith(tail.substring(pos), "new ")) {
				pos += 4;
			} else {
				break;
			}
		}
		final prefix = tail.substring(0, pos);
		final suffix = tail.substring(pos);
		if (StringTools.startsWith(suffix, "[")) {
			return prefix + head + suffix;
		}
		return prefix + head + "." + suffix;
	}

	static function getPropertyNameArg(arg:Any):std.String {
		final s:std.String = arg;
		if (s.length != 0 && (StringTools.fastCodeAt(s, 0) == '"'.code || StringTools.fastCodeAt(s, 0) == "'".code || StringTools.fastCodeAt(s, 0) == '`'.code)) {
			return "[" + s + "]";
		}
		return s;
	}

	static function isConversionOrInterfaceImplementationMessage(message:Message):Bool {
		return message == Diagnostics.Class_0_incorrectly_implements_interface_1
			|| message == Diagnostics.Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1_and_inherit_its_members_as_a_subclass
			|| message == Diagnostics.Conversion_of_type_0_to_type_1_may_be_a_mistake_because_neither_type_sufficiently_overlaps_with_the_other_If_this_was_intentional_convert_the_expression_to_unknown_first
			|| message == Diagnostics.Its_instance_type_0_is_not_a_valid_JSX_element
			|| message == Diagnostics.Its_return_type_0_is_not_a_valid_JSX_element
			|| message == Diagnostics.Its_element_type_0_is_not_a_valid_JSX_element;
	}

	static function chainDepth(chain:ErrorChain):Int {
		var depth = 0;
		while (chain != null) {
			depth++;
			chain = chain.next;
		}
		return depth;
	}

	// --- services.go ---

	static function runWithInferenceBlockedFromSourceNode<T>(c:Checker, node:Node, fn:() -> T):T {
		final containingCall = Ast.FindAncestor(node, fn_IsCallLikeExpression);
		if (containingCall != null) {
			var toMarkSkip = node;
			while (true) {
				c.skipDirectInferenceNodes.Add(toMarkSkip);
				toMarkSkip = toMarkSkip.Parent;
				if (toMarkSkip == null || toMarkSkip == containingCall) {
					break;
				}
			}
		}

		c.isInferencePartiallyBlocked = true;
		final result = runWithoutResolvedSignatureCaching(c, node, fn);
		c.isInferencePartiallyBlocked = false;

		c.skipDirectInferenceNodes.Clear();
		return result;
	}

	public static function GetResolvedSignatureForSignatureHelp(node:Node, argumentCount:Int, c:Checker):Pair<Signature, Array<Signature>> {
		final res = runWithoutResolvedSignatureCaching(c, node, () -> {
			return c.getResolvedSignatureWorker(node, CheckModeIsForSignatureHelp, argumentCount);
		});
		return res;
	}

	static function runWithoutResolvedSignatureCaching<T>(c:Checker, node:Node, fn:() -> T):T {
		var ancestorNode = Ast.FindAncestor(node, fn_IsCallLikeOrFunctionLikeExpression);
		if (ancestorNode != null) {
			final cachedResolvedSignatures = new IdentityMap<SignatureLinks, Signature>();
			final cachedTypes = new IdentityMap<ValueSymbolLinks, Type>();
			while (ancestorNode != null) {
				final signatureLinks = c.signatureLinks.Get(ancestorNode);
				cachedResolvedSignatures.set(signatureLinks, signatureLinks.resolvedSignature);
				signatureLinks.resolvedSignature = null;
				if (Ast.IsFunctionExpressionOrArrowFunction(ancestorNode)) {
					final symbolLinks = c.valueSymbolLinks.Get(c.getSymbolOfDeclaration(ancestorNode));
					final resolvedType = symbolLinks.resolvedType;
					cachedTypes.set(symbolLinks, resolvedType);
					symbolLinks.resolvedType = null;
				}
				ancestorNode = Ast.FindAncestor(ancestorNode.Parent, fn_IsCallLikeOrFunctionLikeExpression);
			}
			final result = fn();
			for (signatureLinks => resolvedSignature in cachedResolvedSignatures) {
				signatureLinks.resolvedSignature = resolvedSignature;
			}
			for (symbolLinks => resolvedType in cachedTypes) {
				symbolLinks.resolvedType = resolvedType;
			}
			return result;
		}
		return fn();
	}

	static function isExportSpecifierAlias(referenceLocation:Identifier, exportSpecifier:ExportSpecifier):Bool {
		Debug.Assert(exportSpecifier.PropertyName == referenceLocation.AsNode() || exportSpecifier.Name() == referenceLocation.AsNode(),
			"referenceLocation is not export specifier name or property name");
		final propertyName = exportSpecifier.PropertyName;
		if (propertyName != null) {
			// Given `export { foo as bar } [from "someModule"]`: It's an alias at `foo`, but at `bar` it's a new symbol.
			return propertyName == referenceLocation.AsNode();
		} else {
			// `export { foo } from "foo"` is a re-export.
			// `export { foo };` is not a re-export, it creates an alias for the local variable `foo`.
			return exportSpecifier.Parent.Parent.ModuleSpecifier() == null;
		}
	}

	static function getPossibleSymbolReferenceNodes(sourceFile:SourceFile, symbolName:std.String, container:Node):Array<Node> {
		return Core.MapNonNil(getPossibleSymbolReferencePositions(sourceFile, symbolName, container), (pos:Int) -> {
			final referenceLocation = Astnav.GetTouchingPropertyName(sourceFile, pos);
			if (referenceLocation != sourceFile.AsNode()) {
				return referenceLocation;
			}
			return null;
		});
	}

	static function getPossibleSymbolReferencePositions(sourceFile:SourceFile, symbolName:std.String, container:Node):Array<Int> {
		final positions:Array<Int> = [];

		// TODO: Cache symbol existence for files to save text search
		// Also, need to make this work for unicode escapes.

		// Be resilient in the face of a symbol with no name or zero length name
		if (symbolName == "") {
			return positions;
		}

		final text = sourceFile.Text();
		final sourceLength = text.length;
		final symbolNameLength = symbolName.length;

		if (container == null) {
			container = sourceFile.AsNode();
		}

		// Go: strings.Index(text[container.Pos():], symbolName) — the index is relative to container.Pos().
		var position = text.substring(container.Pos()).indexOf(symbolName);
		final endPos = container.End();
		while (position >= 0 && position < endPos) {
			// We found a match.  Make sure it's not part of a larger word (i.e. the char
			// before and after it have to be a non-identifier char).
			final endPosition = position + symbolNameLength;

			// PORT: byte — Go tests the UTF-8 byte; here the UTF-16 code unit.
			if ((position == 0 || !Scanner.IsIdentifierPart(StringTools.fastCodeAt(text, position - 1)))
				&& (endPosition == sourceLength || !Scanner.IsIdentifierPart(StringTools.fastCodeAt(text, endPosition)))) {
				// Found a real match.  Keep searching.
				positions.push(position);
			}
			final startIndex = position + symbolNameLength + 1;
			if (startIndex > text.length) {
				break;
			}
			final foundIndex = text.substring(startIndex).indexOf(symbolName);
			if (foundIndex != -1) {
				position = startIndex + foundIndex;
			} else {
				break;
			}
		}

		return positions;
	}

	static var knownGenericTypeNames:StringMap<Bool> = {
		final m = new StringMap<Bool>();
		for (name in ["Array", "ArrayLike", "ReadonlyArray", "Promise", "PromiseLike", "Iterable", "IterableIterator", "AsyncIterable", "Set", "WeakSet",
			"ReadonlySet", "Map", "WeakMap", "ReadonlyMap", "Partial", "Required", "Readonly", "Pick", "Omit", "NonNullable"]) {
			m.set(name, true);
		}
		m;
	};

	static function isKnownGenericTypeName(name:std.String):Bool {
		return knownGenericTypeNames.exists(name);
	}

	// --- stringer_generated.go ---

	static inline final _SignatureKind_name:std.String = "SignatureKindCallSignatureKindConstruct";

	static var _SignatureKind_index:Array<Int> = [0, 17, 39];

	// --- symbolaccessibility.go ---

	static function hasNonGlobalAugmentationExternalModuleSymbol(declaration:Node):Bool {
		return Ast.IsModuleWithStringLiteralName(declaration) || (declaration.Kind == KindSourceFile && Ast.IsExternalOrCommonJSModule(declaration.AsSourceFile()));
	}

	static function getQualifiedLeftMeaning(rightMeaning:SymbolFlags):SymbolFlags {
		// If we are looking in value space, the parent meaning is value, other wise it is namespace
		if (rightMeaning == SymbolFlagsValue) {
			return SymbolFlagsValue;
		}
		return SymbolFlagsNamespace;
	}

	static function hasExternalModuleSymbol(declaration:Node):Bool {
		return Ast.IsAmbientModule(declaration) || (declaration.Kind == KindSourceFile && Ast.IsExternalOrCommonJSModule(declaration.AsSourceFile()));
	}

	static inline final stKindShift:Int = 61;

	static function symbolTableIDFromLocals(node:Node):SymbolTableID {
		return symbolTableIDOf(stKindLocals, Ast.GetNodeId(node));
	}

	static function symbolTableIDFromExports(sym:Symbol):SymbolTableID {
		return symbolTableIDOf(stKindExports, Ast.GetSymbolId(sym));
	}

	// symbolTableIDFromResolvedExports returns an ID for resolved/derived export tables
	// (e.g. from getExportsOfSymbol/getExportsOfModule which may include export * resolution
	// and late-bound members). This is distinct from symbolTableIDFromExports to prevent
	// cache collisions with raw sym.Exports tables passed by someSymbolTableInScope.
	static function symbolTableIDFromResolvedExports(sym:Symbol):SymbolTableID {
		return symbolTableIDOf(stKindResolvedExports, Ast.GetSymbolId(sym));
	}

	static function symbolTableIDFromMembers(sym:Symbol):SymbolTableID {
		return symbolTableIDOf(stKindMembers, Ast.GetSymbolId(sym));
	}

	static function symbolTableIDFromGlobals():SymbolTableID {
		return stKindGlobals;
	}

	static function isUMDExportSymbol(symbol:Symbol):Bool {
		return symbol != null && Core.len(symbol.Declarations) > 0 && symbol.Declarations[0] != null && Ast.IsNamespaceExportDeclaration(symbol.Declarations[0]);
	}

	static function isNamespaceReexportDeclaration(node:Node):Bool {
		return Ast.IsNamespaceExport(node) && node.Parent.ModuleSpecifier() != null;
	}

	static function isPropertyOrMethodDeclarationSymbol(symbol:Symbol):Bool {
		if (Core.len(symbol.Declarations) > 0) {
			for (declaration in symbol.Declarations) {
				switch (declaration.Kind) {
					case KindPropertyDeclaration | KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
						continue;
					default:
						return false;
				}
			}
			return true;
		}
		return false;
	}

	// --- symboltracker.go ---

	public static function NewSymbolTrackerImpl(context:NodeBuilderContext, tracker:SymbolTracker):SymbolTrackerImpl {
		if (tracker != null) {
			while (true) {
				final t = Std.downcast(tracker, SymbolTrackerImpl);
				if (t == null) {
					break;
				}
				tracker = t.inner;
			}
		}

		final result = new SymbolTrackerImpl();
		result.context = context;
		result.inner = tracker;
		result.DisableTrackSymbol = false;
		return result;
	}

	// --- tracer.go ---

	// NewTracer creates a Tracer for the given checker index that records both
	// type-creation events and trace events through the provided tracing session.
	public static function NewTracer(tr:ts.tracing.Tracing, checkerIndex:Int):Tracer {
		final t = new Tracer();
		t.tracing = tr;
		t.recorder = tr.NewTypeTracer(checkerIndex);
		t.checkerIndex = checkerIndex;
		return t;
	}

	static function wrapType(t:Type):TracedType {
		if (t == null) {
			return null;
		}
		final a = new TracedTypeAdapter();
		a.t = t;
		a.checker = t.checker;
		return a;
	}

	static function wrapTypes(types:Array<Type>):Array<TracedType> {
		if (Core.len(types) == 0) {
			return null;
		}
		final result:Array<TracedType> = [];
		for (t in types) {
			result.push(wrapType(t));
		}
		return result;
	}

	// --- types.go ---

	static inline final externalHelpersModuleNameText:std.String = "tslib";

	static var typeFlagNames:Array<TypeFlagNamesStruct> = {
		final flags:Array<TypeFlags> = [TypeFlagsAny, TypeFlagsUnknown, TypeFlagsUndefined, TypeFlagsNull, TypeFlagsVoid, TypeFlagsString, TypeFlagsNumber,
			TypeFlagsBigInt, TypeFlagsBoolean, TypeFlagsESSymbol, TypeFlagsStringLiteral, TypeFlagsNumberLiteral, TypeFlagsBigIntLiteral, TypeFlagsBooleanLiteral,
			TypeFlagsUniqueESSymbol, TypeFlagsEnumLiteral, TypeFlagsEnum, TypeFlagsNonPrimitive, TypeFlagsNever, TypeFlagsTypeParameter, TypeFlagsObject,
			TypeFlagsIndex, TypeFlagsTemplateLiteral, TypeFlagsStringMapping, TypeFlagsSubstitution, TypeFlagsIndexedAccess, TypeFlagsConditional,
			TypeFlagsUnion, TypeFlagsIntersection];
		final names = ["Any", "Unknown", "Undefined", "Null", "Void", "String", "Number", "BigInt", "Boolean", "ESSymbol", "StringLiteral", "NumberLiteral",
			"BigIntLiteral", "BooleanLiteral", "UniqueESSymbol", "EnumLiteral", "Enum", "NonPrimitive", "Never", "TypeParameter", "Object", "Index",
			"TemplateLiteral", "StringMapping", "Substitution", "IndexedAccess", "Conditional", "Union", "Intersection"];
		final result:Array<TypeFlagNamesStruct> = [];
		for (i in 0...flags.length) {
			final e = new TypeFlagNamesStruct();
			e.flag = flags[i];
			e.name = names[i];
			result.push(e);
		}
		result;
	};

	// FormatTypeFlags returns the individual flag names as a slice of strings.
	public static function FormatTypeFlags(flags:TypeFlags):Array<std.String> {
		final result:Array<std.String> = [];
		for (fn in typeFlagNames) {
			if (flags & fn.flag != 0) {
				result.push(fn.name);
			}
		}
		if (result.length == 0) {
			result.push("None");
		}
		return result;
	}

	// Flags that require TypeFlags.Object
	public static inline final ObjectFlagsContainsSpread:Int = 4194304; // Object literal contains spread operation

	public static inline final ObjectFlagsObjectRestType:Int = 8388608; // Originates in object rest declaration

	public static inline final ObjectFlagsInstantiationExpressionType:Int = 16777216; // Originates in instantiation expression

	public static inline final ObjectFlagsSingleSignatureType:Int = 33554432; // A single signature type extracted from a potentially broader type

	public static inline final ObjectFlagsIsClassInstanceClone:Int = 67108864; // Type is a clone of a class instance type

	// Flags that require TypeFlags.Object and ObjectFlags.Reference
	public static inline final ObjectFlagsIdenticalBaseTypeCalculated:Int = 134217728; // has had `getSingleBaseForNonAugmentingSubtype` invoked on it already

	public static inline final ObjectFlagsIdenticalBaseTypeExists:Int = 268435456; // has a defined cachedEquivalentBaseType member

	public static inline final ObjectFlagsUnresolvedMembers:Int = 536870912; // Member resolution in process

	public static inline final ObjectFlagsFromTypeNode:Int = 1073741824; // Originates in resolution of AST type node

	// Flags that require TypeFlags.UnionOrIntersection or TypeFlags.Substitution
	public static inline final ObjectFlagsIsGenericTypeComputed:Int = 4194304; // IsGenericObjectType flag has been computed

	public static inline final ObjectFlagsIsGenericObjectType:Int = 8388608; // Union or intersection contains generic object type

	public static inline final ObjectFlagsIsGenericIndexType:Int = 16777216; // Union or intersection contains generic index type

	public static inline final ObjectFlagsIsGenericType:Int = 25165824;

	// Flags that require TypeFlags.Union
	public static inline final ObjectFlagsContainsIntersections:Int = 33554432; // Union contains intersections

	public static inline final ObjectFlagsIsUnknownLikeUnionComputed:Int = 67108864; // IsUnknownLikeUnion flag has been computed

	public static inline final ObjectFlagsIsUnknownLikeUnion:Int = 134217728; // Union of null, undefined, and empty object type

	// Flags that require TypeFlags.Intersection
	public static inline final ObjectFlagsIsNeverIntersectionComputed:Int = 33554432; // IsNeverLike flag has been computed

	public static inline final ObjectFlagsIsNeverIntersection:Int = 67108864; // Intersection reduces to never

	public static inline final ObjectFlagsIsConstrainedTypeVariable:Int = 134217728; // T & C, where T's constraint and C are primitives, object, or {}

	public static var LanguageFeatureMinimumTarget:LanguageFeatureMinimumTargetMap = {
		final m = new LanguageFeatureMinimumTargetMap();
		m.Exponentiation = ScriptTargetES2016;
		m.AsyncFunctions = ScriptTargetES2017;
		m.ForAwaitOf = ScriptTargetES2018;
		m.AsyncGenerators = ScriptTargetES2018;
		m.AsyncIteration = ScriptTargetES2018;
		m.ObjectSpreadRest = ScriptTargetES2018;
		m.RegularExpressionFlagsDotAll = ScriptTargetES2018;
		m.BindinglessCatch = ScriptTargetES2019;
		m.BigInt = ScriptTargetES2020;
		m.NullishCoalesce = ScriptTargetES2020;
		m.OptionalChaining = ScriptTargetES2020;
		m.LogicalAssignment = ScriptTargetES2021;
		m.TopLevelAwait = ScriptTargetES2022;
		m.ClassFields = ScriptTargetES2022;
		m.PrivateNamesAndClassStaticBlocks = ScriptTargetES2022;
		m.RegularExpressionFlagsHasIndices = ScriptTargetES2022;
		m.ShebangComments = ScriptTargetESNext;
		m.UsingAndAwaitUsing = ScriptTargetESNext;
		m.ClassAndClassElementDecorators = ScriptTargetESNext;
		m.RegularExpressionFlagsUnicodeSets = ScriptTargetESNext;
		m;
	};

	// --- utilities.go ---

	public static function NewDiagnosticForNode(node:Node, message:Message, ...args:Any):Diagnostic {
		var file:SourceFile = null;
		var loc = new TextRange(0, 0);
		if (node != null) {
			file = Ast.GetSourceFileOfNode(node);
			loc = Scanner.GetErrorRangeForNode(file, node);
		}
		return Ast.NewDiagnostic(file, loc, message, ...args);
	}

	public static function NewDiagnosticChainForNode(chain:Diagnostic, node:Node, message:Message, ...args:Any):Diagnostic {
		if (chain != null) {
			return Ast.NewDiagnosticChain(chain, message, ...args);
		}
		return NewDiagnosticForNode(node, message, ...args);
	}

	static function findInMap<K, V>(m:GoMap<K, V>, predicate:(V) -> Bool):V {
		if (m != null) {
			for (value in m) {
				if (predicate(value)) {
					return value;
				}
			}
		}
		return null;
	}

	static function tokenIsIdentifierOrKeyword(token:Kind):Bool {
		return (token : Int) >= (KindIdentifier : Int);
	}

	static function tokenIsIdentifierOrKeywordOrGreaterThan(token:Kind):Bool {
		return token == KindGreaterThanToken || tokenIsIdentifierOrKeyword(token);
	}

	static function hasOverrideModifier(node:Node):Bool {
		return Ast.HasSyntacticModifier(node, ModifierFlagsOverride);
	}

	static function hasAsyncModifier(node:Node):Bool {
		return Ast.HasSyntacticModifier(node, ModifierFlagsAsync);
	}

	static function getSelectedModifierFlags(node:Node, flags:ModifierFlags):ModifierFlags {
		return node.ModifierFlags() & flags;
	}

	static function hasReadonlyModifier(node:Node):Bool {
		return Ast.HasModifier(node, ModifierFlagsReadonly);
	}

	static function isStaticPrivateIdentifierProperty(s:Symbol):Bool {
		return s.ValueDeclaration != null && Ast.IsPrivateIdentifierClassElementDeclaration(s.ValueDeclaration) && Ast.IsStatic(s.ValueDeclaration);
	}

	static function isEmptyObjectLiteral(expression:Node):Bool {
		return Ast.IsObjectLiteralExpression(expression) && Core.len(expression.Properties()) == 0;
	}

	static function getAssignmentTargetKind(node:Node):AssignmentKind {
		final target = Ast.GetAssignmentTarget(node);
		if (target == null) {
			return AssignmentKindNone;
		}
		switch (target.Kind) {
			case KindBinaryExpression:
				final binaryOperator = target.AsBinaryExpression().OperatorToken.Kind;
				if (binaryOperator == KindEqualsToken || Ast.IsLogicalOrCoalescingAssignmentOperator(binaryOperator)) {
					return AssignmentKindDefinite;
				}
				return AssignmentKindCompound;
			case KindPrefixUnaryExpression | KindPostfixUnaryExpression:
				return AssignmentKindCompound;
			case KindForInStatement | KindForOfStatement:
				return AssignmentKindDefinite;
			default:
		}
		throw "Unhandled case in getAssignmentTargetKind";
	}

	static function isDeleteTarget(node:Node):Bool {
		if (!Ast.IsAccessExpression(node)) {
			return false;
		}
		node = Ast.WalkUpParenthesizedExpressions(node.Parent);
		return node != null && node.Kind == KindDeleteExpression;
	}

	static function isInCompoundLikeAssignment(node:Node):Bool {
		final target = Ast.GetAssignmentTarget(node);
		return target != null && Ast.IsAssignmentExpression(target /*excludeCompoundAssignment*/, true) && isCompoundLikeAssignment(target);
	}

	static function isCompoundLikeAssignment(assignment:Node):Bool {
		final right = Ast.SkipParentheses(assignment.AsBinaryExpression().Right);
		return right.Kind == KindBinaryExpression && isShiftOperatorOrHigher(right.AsBinaryExpression().OperatorToken.Kind);
	}

	static function isConstTypeReference(node:Node):Bool {
		return Ast.IsTypeReferenceNode(node) && Core.len(node.TypeArguments()) == 0 && Ast.IsIdentifier(node.AsTypeReferenceNode().TypeName)
			&& node.AsTypeReferenceNode().TypeName.Text() == "const";
	}

	public static function GetSingleVariableOfVariableStatement(node:Node):Node {
		if (!Ast.IsVariableStatement(node)) {
			return null;
		}
		return Core.FirstOrNil(node.AsVariableStatement().DeclarationList.AsVariableDeclarationList().Declarations.Nodes);
	}

	static function isTypeReferenceIdentifier(node:Node):Bool {
		while (node.Parent.Kind == KindQualifiedName) {
			node = node.Parent;
		}
		return Ast.IsTypeReferenceNode(node.Parent);
	}

	public static function IsInTypeQuery(node:Node):Bool {
		// TypeScript 1.0 spec (April 2014): 3.6.3
		// A type query consists of the keyword typeof followed by an expression.
		// The expression is restricted to a single identifier or a sequence of identifiers separated by periods
		return Ast.FindAncestorOrQuit(node, (n:Node) -> {
			switch (n.Kind) {
				case KindTypeQuery:
					return FindAncestorTrue;
				case KindIdentifier | KindQualifiedName:
					return FindAncestorFalse;
				default:
			}
			return FindAncestorQuit;
		}) != null;
	}

	static function canHaveLocals(node:Node):Bool {
		switch (node.Kind) {
			case KindArrowFunction | KindBlock | KindCallSignature | KindCaseBlock | KindCatchClause | KindClassStaticBlockDeclaration | KindConditionalType |
				KindConstructor | KindConstructorType | KindConstructSignature | KindForStatement | KindForInStatement | KindForOfStatement |
				KindFunctionDeclaration | KindFunctionExpression | KindFunctionType | KindGetAccessor | KindIndexSignature | KindJSDocSignature |
				KindMappedType | KindMethodDeclaration | KindMethodSignature | KindModuleDeclaration | KindSetAccessor | KindSourceFile |
				KindTypeAliasDeclaration | KindJSTypeAliasDeclaration:
				return true;
			default:
		}
		return false;
	}

	static function isShorthandAmbientModuleSymbol(moduleSymbol:Symbol):Bool {
		return isShorthandAmbientModule(moduleSymbol.ValueDeclaration);
	}

	static function isShorthandAmbientModule(node:Node):Bool {
		// The only kind of module that can be missing a body is a shorthand ambient module.
		return node != null && node.Kind == KindModuleDeclaration && node.Body() == null;
	}

	static function getAliasDeclarationFromName(node:Node):Node {
		switch (node.Parent.Kind) {
			case KindImportClause | KindImportSpecifier | KindNamespaceImport | KindExportSpecifier | KindExportAssignment | KindImportEqualsDeclaration |
				KindNamespaceExport:
				return node.Parent;
			case KindQualifiedName:
				return getAliasDeclarationFromName(node.Parent);
			default:
		}
		return null;
	}

	static function entityNameToString(name:Node):std.String {
		return Ast.EntityNameToString(name, fn_GetTextOfNode);
	}

	static function getContainingQualifiedNameNode(node:Node):Node {
		while (Ast.IsQualifiedName(node.Parent)) {
			node = node.Parent;
		}
		return node;
	}

	static function isSideEffectImport(node:Node):Bool {
		final ancestor = Ast.FindAncestor(node, fn_IsImportDeclaration);
		return ancestor != null && ancestor.ImportClause() == null;
	}

	static function getExternalModuleRequireArgument(node:Node):Node {
		if (Ast.IsVariableDeclarationInitializedToRequire(node)) {
			return node.Initializer().Arguments()[0];
		}
		return null;
	}

	static function isRightSideOfAccessExpression(node:Node):Bool {
		return node.Parent != null
			&& (Ast.IsPropertyAccessExpression(node.Parent) && node.Parent.Name() == node
				|| Ast.IsElementAccessExpression(node.Parent) && node.Parent.AsElementAccessExpression().ArgumentExpression == node);
	}

	static function isTopLevelInExternalModuleAugmentation(node:Node):Bool {
		return node != null && node.Parent != null && Ast.IsModuleBlock(node.Parent) && Ast.IsExternalModuleAugmentation(node.Parent.Parent);
	}

	static function isSyntacticDefault(node:Node):Bool {
		return (Ast.IsExportAssignment(node) && !node.AsExportAssignment().IsExportEquals)
			|| Ast.HasSyntacticModifier(node, ModifierFlagsDefault)
			|| Ast.IsExportSpecifier(node)
			|| Ast.IsNamespaceExport(node);
	}

	static function hasExportAssignmentSymbol(moduleSymbol:Symbol):Bool {
		return moduleSymbol.Exports != null && moduleSymbol.Exports.get(Ast.InternalSymbolNameExportEquals) != null;
	}

	static function isTypeAlias(node:Node):Bool {
		return Ast.IsTypeOrJSTypeAliasDeclaration(node);
	}

	static function hasOnlyExpressionInitializer(node:Node):Bool {
		switch (node.Kind) {
			case KindVariableDeclaration | KindParameter | KindBindingElement | KindPropertyDeclaration | KindPropertyAssignment | KindEnumMember:
				return true;
			default:
		}
		return false;
	}

	static function hasDotDotDotToken(node:Node):Bool {
		switch (node.Kind) {
			case KindParameter:
				return node.AsParameterDeclaration().DotDotDotToken != null;
			case KindBindingElement:
				return node.AsBindingElement().DotDotDotToken != null;
			case KindNamedTupleMember:
				return node.AsNamedTupleMember().DotDotDotToken != null;
			case KindJsxExpression:
				return node.AsJsxExpression().DotDotDotToken != null;
			default:
		}
		return false;
	}

	public static function IsTypeAny(t:Type):Bool {
		return t != null && t.flags & TypeFlagsAny != 0;
	}

	static function isJSDocOptionalParameter(node:ParameterDeclaration):Bool {
		return false; // !!!
	}

	static function isExclamationToken(node:Node):Bool {
		return node != null && node.Kind == KindExclamationToken;
	}

	static function isOptionalDeclaration(declaration:Node):Bool {
		return Ast.HasQuestionToken(declaration);
	}

	static function isEmptyArrayLiteral(expression:Node):Bool {
		return Ast.IsArrayLiteralExpression(expression) && Core.len(expression.Elements()) == 0;
	}

	static function declarationBelongsToPrivateAmbientMember(declaration:Node):Bool {
		final root = Ast.GetRootDeclaration(declaration);
		var memberDeclaration = root;
		if (root.Kind == KindParameter) {
			memberDeclaration = root.Parent;
		}
		return isPrivateWithinAmbient(memberDeclaration);
	}

	static function isPrivateWithinAmbient(node:Node):Bool {
		return (Ast.HasModifier(node, ModifierFlagsPrivate) || Ast.IsPrivateIdentifierClassElementDeclaration(node)) && node.Flags & NodeFlagsAmbient != 0;
	}

	static function isTypeAssertion(node:Node):Bool {
		return Ast.IsAssertionExpression(Ast.SkipParentheses(node));
	}

	static function createSymbolTable(symbols:Array<Symbol>):SymbolTable {
		if (Core.len(symbols) == 0) {
			return null;
		}
		final result = new SymbolTable();
		for (symbol in symbols) {
			result.set(symbol.Name, symbol);
		}
		return result;
	}

	public static function CompareTypes(t1:Type, t2:Type):Int {
		if (t1 == t2) {
			return 0;
		}
		if (t1 == null) {
			return -1;
		}
		if (t2 == null) {
			return 1;
		}
		if (t1.checker != t2.checker) {
			throw "Cannot compare types from different checkers";
		}
		// First sort in order of increasing type flags values.
		var c = getSortOrderFlags(t1) - getSortOrderFlags(t2);
		if (c != 0) {
			return c;
		}
		// Order named types by name and, in the case of aliased types, by alias type arguments.
		c = compareTypeNames(t1, t2);
		if (c != 0) {
			return c;
		}
		// We have unnamed types or types with identical names. Now sort by data specific to the type.
		if (t1.flags & (TypeFlagsAny | TypeFlagsUnknown | TypeFlagsString | TypeFlagsNumber | TypeFlagsBoolean | TypeFlagsBigInt | TypeFlagsESSymbol | TypeFlagsVoid | TypeFlagsUndefined | TypeFlagsNull | TypeFlagsNever | TypeFlagsNonPrimitive) != 0) {
			// Only distinguished by type IDs, handled below.
		} else if (t1.flags & TypeFlagsObject != 0) {
			// Order unnamed or identically named object types by symbol.
			c = t1.checker.compareSymbols(t1.symbol, t2.symbol);
			if (c != 0) {
				return c;
			}
			// When object types have the same or no symbol, order by kind. We order type references before other kinds.
			if (t1.objectFlags & ObjectFlagsReference != 0 && t2.objectFlags & ObjectFlagsReference != 0) {
				final r1 = t1.AsTypeReference();
				final r2 = t2.AsTypeReference();
				if (r1.target.objectFlags & ObjectFlagsTuple != 0 && r2.target.objectFlags & ObjectFlagsTuple != 0) {
					// Tuple types have no associated symbol, instead we order by tuple element information.
					c = compareTupleTypes(r1.target.AsTupleType(), r2.target.AsTupleType());
					if (c != 0) {
						return c;
					}
				}
				// Here we know we have references to instantiations of the same type because we have matching targets.
				if (r1.node == null && r2.node == null) {
					// Non-deferred type references with the same target are sorted by their type argument lists.
					c = compareTypeLists(t1.AsTypeReference().resolvedTypeArguments, t2.AsTypeReference().resolvedTypeArguments);
					if (c != 0) {
						return c;
					}
				} else {
					// Deferred type references with the same target are ordered by the source location of the reference.
					c = t1.checker.compareNodes(r1.node, r2.node);
					if (c != 0) {
						return c;
					}
					// Instantiations of the same deferred type reference are ordered by their associated type mappers
					// (which reflect the mapping of in-scope type parameters to type arguments).
					c = compareTypeMappers(t1.AsObjectType().mapper, t2.AsObjectType().mapper);
					if (c != 0) {
						return c;
					}
				}
			} else if (t1.objectFlags & ObjectFlagsReference != 0) {
				return -1;
			} else if (t2.objectFlags & ObjectFlagsReference != 0) {
				return 1;
			} else {
				// Order unnamed non-reference object types by kind associated type mappers. Reverse mapped types have
				// neither symbols nor mappers so they're ultimately ordered by unstable type IDs, but given their rarity
				// this should be fine.
				c = ((t1.objectFlags & ObjectFlagsObjectTypeKindMask) : Int) - ((t2.objectFlags & ObjectFlagsObjectTypeKindMask) : Int);
				if (c != 0) {
					return c;
				}
				c = compareTypeMappers(t1.AsObjectType().mapper, t2.AsObjectType().mapper);
				if (c != 0) {
					return c;
				}
			}
		} else if (t1.flags & TypeFlagsUnion != 0) {
			// Unions are ordered by origin and then constituent type lists.
			final o1 = t1.AsUnionType().origin;
			final o2 = t2.AsUnionType().origin;
			if (o1 == null && o2 == null) {
				c = compareTypeLists(t1.Types(), t2.Types());
				if (c != 0) {
					return c;
				}
			} else if (o1 == null) {
				return 1;
			} else if (o2 == null) {
				return -1;
			} else {
				c = CompareTypes(o1, o2);
				if (c != 0) {
					return c;
				}
			}
		} else if (t1.flags & TypeFlagsIntersection != 0) {
			// Intersections are ordered by their constituent type lists.
			c = compareTypeLists(t1.Types(), t2.Types());
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & (TypeFlagsEnum | TypeFlagsEnumLiteral | TypeFlagsUniqueESSymbol) != 0) {
			// Enum members are ordered by their symbol (and thus their declaration order).
			c = t1.checker.compareSymbols(t1.symbol, t2.symbol);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsStringLiteral != 0) {
			// String literal types are ordered by their values.
			c = Strings.Compare((t1.AsLiteralType().value : std.String), (t2.AsLiteralType().value : std.String));
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsNumberLiteral != 0) {
			// Numeric literal types are ordered by their values.
			c = compareNumbers((t1.AsLiteralType().value : Float), (t2.AsLiteralType().value : Float));
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsBooleanLiteral != 0) {
			final b1:Bool = t1.AsLiteralType().value;
			final b2:Bool = t2.AsLiteralType().value;
			if (b1 != b2) {
				if (b1) {
					return 1;
				}
				return -1;
			}
		} else if (t1.flags & TypeFlagsTypeParameter != 0) {
			c = t1.checker.compareSymbols(t1.symbol, t2.symbol);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsIndex != 0) {
			c = CompareTypes(t1.AsIndexType().target, t2.AsIndexType().target);
			if (c != 0) {
				return c;
			}
			c = (t1.AsIndexType().indexFlags : Int) - (t2.AsIndexType().indexFlags : Int);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsIndexedAccess != 0) {
			c = CompareTypes(t1.AsIndexedAccessType().objectType, t2.AsIndexedAccessType().objectType);
			if (c != 0) {
				return c;
			}
			c = CompareTypes(t1.AsIndexedAccessType().indexType, t2.AsIndexedAccessType().indexType);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsConditional != 0) {
			c = t1.checker.compareNodes(t1.AsConditionalType().root.node.AsNode(), t2.AsConditionalType().root.node.AsNode());
			if (c != 0) {
				return c;
			}
			c = compareTypeMappers(t1.AsConditionalType().mapper, t2.AsConditionalType().mapper);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsSubstitution != 0) {
			c = CompareTypes(t1.AsSubstitutionType().baseType, t2.AsSubstitutionType().baseType);
			if (c != 0) {
				return c;
			}
			c = CompareTypes(t1.AsSubstitutionType().constraint, t2.AsSubstitutionType().constraint);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsTemplateLiteral != 0) {
			c = Slices.Compare(t1.AsTemplateLiteralType().texts, t2.AsTemplateLiteralType().texts);
			if (c != 0) {
				return c;
			}
			c = compareTypeLists(t1.AsTemplateLiteralType().types, t2.AsTemplateLiteralType().types);
			if (c != 0) {
				return c;
			}
		} else if (t1.flags & TypeFlagsStringMapping != 0) {
			c = CompareTypes(t1.AsStringMappingType().target, t2.AsStringMappingType().target);
			if (c != 0) {
				return c;
			}
		}
		// Fall back to type IDs. This results in type creation order for built-in types.
		return t1.id - t2.id;
	}

	static function getSortOrderFlags(t:Type):Int {
		// Return TypeFlagsEnum for all enum-like unit types (they'll be sorted by their symbols)
		if (t.flags & (TypeFlagsEnumLiteral | TypeFlagsEnum) != 0 && t.flags & TypeFlagsUnion == 0) {
			return (TypeFlagsEnum : Int);
		}
		// PORT: Go int(uint32) is never negative; TypeFlags bit 31 (Reserved3) is not set on types.
		return (t.flags : Int);
	}

	static function compareTypeNames(t1:Type, t2:Type):Int {
		final s1 = getTypeNameSymbol(t1);
		final s2 = getTypeNameSymbol(t2);
		if (s1 == s2) {
			if (t1.alias != null) {
				return compareTypeLists(t1.alias.typeArguments, t2.alias.typeArguments);
			}
			return 0;
		}
		if (s1 == null) {
			return 1;
		}
		if (s2 == null) {
			return -1;
		}
		return Strings.Compare(s1.Name, s2.Name);
	}

	static function getTypeNameSymbol(t:Type):Symbol {
		if (t.alias != null) {
			return t.alias.symbol;
		}
		if (t.flags & (TypeFlagsTypeParameter | TypeFlagsStringMapping) != 0 || t.objectFlags & (ObjectFlagsClassOrInterface | ObjectFlagsReference) != 0) {
			return t.symbol;
		}
		return null;
	}

	static function getObjectTypeName(t:Type):Symbol {
		if (t.objectFlags & (ObjectFlagsClassOrInterface | ObjectFlagsReference) != 0) {
			return t.symbol;
		}
		return null;
	}

	static function compareTupleTypes(t1:TupleType, t2:TupleType):Int {
		if (t1 == t2) {
			return 0;
		}
		if (t1.readonly != t2.readonly) {
			return Core.IfElse(t1.readonly, 1, -1);
		}
		if (Core.len(t1.elementInfos) != Core.len(t2.elementInfos)) {
			return Core.len(t1.elementInfos) - Core.len(t2.elementInfos);
		}
		for (i in 0...Core.len(t1.elementInfos)) {
			final c = (t1.elementInfos[i].flags : Int) - (t2.elementInfos[i].flags : Int);
			if (c != 0) {
				return c;
			}
		}
		for (i in 0...Core.len(t1.elementInfos)) {
			final c = compareElementLabels(t1.elementInfos[i].labeledDeclaration, t2.elementInfos[i].labeledDeclaration);
			if (c != 0) {
				return c;
			}
		}
		return 0;
	}

	static function compareElementLabels(n1:Node, n2:Node):Int {
		if (n1 == n2) {
			return 0;
		}
		if (n1 == null) {
			return -1;
		}
		if (n2 == null) {
			return 1;
		}
		return Strings.Compare(n1.Name().Text(), n2.Name().Text());
	}

	static function compareTypeLists(s1:Array<Type>, s2:Array<Type>):Int {
		if (Core.len(s1) != Core.len(s2)) {
			return Core.len(s1) - Core.len(s2);
		}
		for (i in 0...Core.len(s1)) {
			final c = CompareTypes(s1[i], s2[i]);
			if (c != 0) {
				return c;
			}
		}
		return 0;
	}

	static function compareTypeMappers(m1:TypeMapper, m2:TypeMapper):Int {
		if (m1 == m2) {
			return 0;
		}
		if (m1 == null) {
			return 1;
		}
		if (m2 == null) {
			return -1;
		}
		final kind1 = m1.Kind();
		final kind2 = m2.Kind();
		if (kind1 != kind2) {
			return (kind1 : Int) - (kind2 : Int);
		}
		switch (kind1) {
			case TypeMapperKindSimple:
				final m1:SimpleTypeMapper = cast m1.data;
				final m2:SimpleTypeMapper = cast m2.data;
				final c = CompareTypes(m1.source, m2.source);
				if (c != 0) {
					return c;
				}
				return CompareTypes(m1.target, m2.target);
			case TypeMapperKindArray:
				final m1:ArrayTypeMapper = cast m1.data;
				final m2:ArrayTypeMapper = cast m2.data;
				final c = compareTypeLists(m1.sources, m2.sources);
				if (c != 0) {
					return c;
				}
				return compareTypeLists(m1.targets, m2.targets);
			case TypeMapperKindMerged:
				final m1:MergedTypeMapper = cast m1.data;
				final m2:MergedTypeMapper = cast m2.data;
				final c = compareTypeMappers(m1.m1, m2.m1);
				if (c != 0) {
					return c;
				}
				return compareTypeMappers(m1.m2, m2.m2);
			default:
		}
		return 0;
	}

	static function getDeclarationModifierFlagsFromSymbol(s:Symbol):ModifierFlags {
		return getDeclarationModifierFlagsFromSymbolEx(s, false /*isWrite*/);
	}

	static function getDeclarationModifierFlagsFromSymbolEx(s:Symbol, isWrite:Bool):ModifierFlags {
		if (s.ValueDeclaration != null) {
			var declaration:Node = null;
			if (isWrite) {
				declaration = Core.Find(s.Declarations, fn_IsSetAccessorDeclaration);
			}
			if (declaration == null && s.Flags & SymbolFlagsGetAccessor != 0) {
				declaration = Core.Find(s.Declarations, fn_IsGetAccessorDeclaration);
			}
			if (declaration == null) {
				declaration = s.ValueDeclaration;
			}
			final flags = Ast.GetCombinedModifierFlags(declaration);
			if (s.Parent != null && s.Parent.Flags & SymbolFlagsClass != 0) {
				return flags;
			}
			return flags & ~ModifierFlagsAccessibilityModifier;
		}
		if (s.CheckFlags & CheckFlagsSynthetic != 0) {
			var accessModifier:ModifierFlags = ModifierFlagsNone;
			if (s.CheckFlags & CheckFlagsContainsPrivate != 0) {
				accessModifier = ModifierFlagsPrivate;
			} else if (s.CheckFlags & CheckFlagsContainsPublic != 0) {
				accessModifier = ModifierFlagsPublic;
			} else {
				accessModifier = ModifierFlagsProtected;
			}
			var staticModifier:ModifierFlags = ModifierFlagsNone;
			if (s.CheckFlags & CheckFlagsContainsStatic != 0) {
				staticModifier = ModifierFlagsStatic;
			}
			return accessModifier | staticModifier;
		}
		if (s.Flags & SymbolFlagsPrototype != 0) {
			return ModifierFlagsPublic | ModifierFlagsStatic;
		}
		return ModifierFlagsNone;
	}

	static function isExponentiationOperator(kind:Kind):Bool {
		return kind == KindAsteriskAsteriskToken;
	}

	static function isMultiplicativeOperator(kind:Kind):Bool {
		return kind == KindAsteriskToken || kind == KindSlashToken || kind == KindPercentToken;
	}

	static function isMultiplicativeOperatorOrHigher(kind:Kind):Bool {
		return isExponentiationOperator(kind) || isMultiplicativeOperator(kind);
	}

	static function isAdditiveOperator(kind:Kind):Bool {
		return kind == KindPlusToken || kind == KindMinusToken;
	}

	static function isAdditiveOperatorOrHigher(kind:Kind):Bool {
		return isAdditiveOperator(kind) || isMultiplicativeOperatorOrHigher(kind);
	}

	static function isShiftOperator(kind:Kind):Bool {
		return kind == KindLessThanLessThanToken || kind == KindGreaterThanGreaterThanToken || kind == KindGreaterThanGreaterThanGreaterThanToken;
	}

	static function isShiftOperatorOrHigher(kind:Kind):Bool {
		return isShiftOperator(kind) || isAdditiveOperatorOrHigher(kind);
	}

	static function isRelationalOperator(kind:Kind):Bool {
		return kind == KindLessThanToken || kind == KindLessThanEqualsToken || kind == KindGreaterThanToken || kind == KindGreaterThanEqualsToken
			|| kind == KindInstanceOfKeyword || kind == KindInKeyword;
	}

	static function isRelationalOperatorOrHigher(kind:Kind):Bool {
		return isRelationalOperator(kind) || isShiftOperatorOrHigher(kind);
	}

	static function isEqualityOperator(kind:Kind):Bool {
		return kind == KindEqualsEqualsToken || kind == KindEqualsEqualsEqualsToken || kind == KindExclamationEqualsToken
			|| kind == KindExclamationEqualsEqualsToken;
	}

	static function isEqualityOperatorOrHigher(kind:Kind):Bool {
		return isEqualityOperator(kind) || isRelationalOperatorOrHigher(kind);
	}

	static function isBitwiseOperator(kind:Kind):Bool {
		return kind == KindAmpersandToken || kind == KindBarToken || kind == KindCaretToken;
	}

	static function isBitwiseOperatorOrHigher(kind:Kind):Bool {
		return isBitwiseOperator(kind) || isEqualityOperatorOrHigher(kind);
	}

	static function isLogicalOperatorOrHigher(kind:Kind):Bool {
		return Ast.IsLogicalBinaryOperator(kind) || isBitwiseOperatorOrHigher(kind);
	}

	static function isAssignmentOperatorOrHigher(kind:Kind):Bool {
		return kind == KindQuestionQuestionToken || isLogicalOperatorOrHigher(kind) || Ast.IsAssignmentOperator(kind);
	}

	static function isBinaryOperator(kind:Kind):Bool {
		return isAssignmentOperatorOrHigher(kind) || kind == KindCommaToken;
	}

	static function isObjectLiteralType(t:Type):Bool {
		return t.objectFlags & ObjectFlagsObjectLiteral != 0;
	}

	static function isDeclarationReadonly(declaration:Node):Bool {
		return Ast.GetCombinedModifierFlags(declaration) & ModifierFlagsReadonly != 0 && !Ast.IsParameterPropertyDeclaration(declaration, declaration.Parent);
	}

	// orderedSetMapThreshold is the size at which an orderedSet materializes its dedup map.
	// Below this, contains() scans the values slice.
	static inline final orderedSetMapThreshold:Int = 16;

	static function getContainingFunctionOrClassStaticBlock(node:Node):Node {
		return Ast.FindAncestor(node.Parent, fn_IsFunctionLikeOrClassStaticBlockDeclaration);
	}

	static function isNodeDescendantOf(node:Node, ancestor:Node):Bool {
		while (node != null) {
			if (node == ancestor) {
				return true;
			}
			node = node.Parent;
		}
		return false;
	}

	static function isTypeUsableAsPropertyName(t:Type):Bool {
		return t.flags & TypeFlagsStringOrNumberLiteralOrUnique != 0;
	}

	/**
	 * Gets the symbolic name for a member from its type.
	 */
	static function getPropertyNameFromType(t:Type):std.String {
		if (t.flags & TypeFlagsStringLiteral != 0) {
			return (t.AsLiteralType().value : std.String);
		} else if (t.flags & TypeFlagsNumberLiteral != 0) {
			return ts.jsnum.String_.String((t.AsLiteralType().value : Float));
		} else if (t.flags & TypeFlagsUniqueESSymbol != 0) {
			return t.AsUniqueESSymbolType().name;
		}
		throw "Unhandled case in getPropertyNameFromType";
	}

	static function isNumericLiteralName(name:std.String):Bool {
		// The intent of numeric names is that
		//     - they are names with text in a numeric form, and that
		//     - setting properties/indexing with them is always equivalent to doing so with the numeric literal 'numLit',
		//         acquired by applying the abstract 'ToNumber' operation on the name's text.
		//
		// The subtlety is in the latter portion, as we cannot reliably say that anything that looks like a numeric literal is a numeric name.
		// In fact, it is the case that the text of the name must be equal to 'ToString(numLit)' for this to hold.
		//
		// Consider the property name '"0xF00D"'. When one indexes with '0xF00D', they are actually indexing with the value of 'ToString(0xF00D)'
		// according to the ECMAScript specification, so it is actually as if the user indexed with the string '"61453"'.
		// Thus, the text of all numeric literals equivalent to '61543' such as '0xF00D', '0xf00D', '0170015', etc. are not valid numeric names
		// because their 'ToString' representation is not equal to their original text.
		// This is motivated by ECMA-262 sections 9.3.1, 9.8.1, 11.1.5, and 11.2.1.
		//
		// Here, we test whether 'ToString(ToNumber(name))' is exactly equal to 'name'.
		// The '+' prefix operator is equivalent here to applying the abstract ToNumber operation.
		// Applying the 'toString()' method on a number gives us the abstract ToString operation on a number.
		//
		// Note that this accepts the values 'Infinity', '-Infinity', and 'NaN', and that this is intentional.
		// This is desired behavior, because when indexing with them as numeric entities, you are indexing
		// with the strings '"Infinity"', '"-Infinity"', and '"NaN"' respectively.
		return ts.jsnum.String_.String(Jsnum.FromString(name)) == name;
	}

	static function isThisProperty(node:Node):Bool {
		return (Ast.IsPropertyAccessExpression(node) || Ast.IsElementAccessExpression(node)) && node.Expression().Kind == KindThisKeyword;
	}

	static function isValidNumberString(s:std.String, roundTripOnly:Bool):Bool {
		if (s == "") {
			return false;
		}
		final n = Jsnum.FromString(s);
		return !n.IsNaN() && !n.IsInf() && (!roundTripOnly || ts.jsnum.String_.String(n) == s);
	}

	static function isValidBigIntString(s:std.String, roundTripOnly:Bool):Bool {
		if (s == "") {
			return false;
		}
		final scanner = Scanner.NewScanner();
		scanner.SetSkipTrivia(false);
		var success = true;
		scanner.SetOnError((diagnostic:Message, start:Int, length:Int, ...args:Any) -> {
			success = false;
		});
		scanner.SetText(s + "n");
		var result = scanner.Scan();
		final negative = result == KindMinusToken;
		if (negative) {
			result = scanner.Scan();
		}
		final flags = scanner.TokenFlags();
		// validate that
		// * scanning proceeded without error
		// * a bigint can be scanned, and that when it is scanned, it is
		// * the full length of the input string (so the scanner is one character beyond the augmented input length)
		// * it does not contain a numeric separator (the `BigInt` constructor does not accept a numeric separator in its input)
		return success && result == KindBigIntLiteral && scanner.TokenEnd() == s.length + 1 && flags & TokenFlagsContainsSeparator == 0
			&& (!roundTripOnly || s == pseudoBigIntToString(Jsnum.NewPseudoBigInt(Jsnum.ParsePseudoBigInt(scanner.TokenValue()), negative)));
	}

	static function isValidESSymbolDeclaration(node:Node):Bool {
		if (Ast.IsVariableDeclaration(node)) {
			return Ast.IsVarConst(node) && Ast.IsIdentifier(node.AsVariableDeclaration().Name()) && isVariableDeclarationInVariableStatement(node);
		}
		if (Ast.IsPropertyDeclaration(node)) {
			return hasReadonlyModifier(node) && Ast.HasStaticModifier(node);
		}
		return Ast.IsPropertySignatureDeclaration(node) && hasReadonlyModifier(node);
	}

	static function isVariableDeclarationInVariableStatement(node:Node):Bool {
		return Ast.IsVariableDeclarationList(node.Parent) && Ast.IsVariableStatement(node.Parent.Parent);
	}

	public static function IsKnownSymbol(symbol:Symbol):Bool {
		return isLateBoundName(symbol.Name);
	}

	public static function IsPrivateIdentifierSymbol(symbol:Symbol):Bool {
		if (symbol == null) {
			return false;
		}
		return StringTools.startsWith(symbol.Name, Ast.InternalSymbolNamePrefix + "#");
	}

	static function isLateBoundName(name:std.String):Bool {
		// PORT: Go byte 0xFE is U+FFFE here (Ast.InternalSymbolNamePrefix).
		return name.length >= 2 && StringTools.fastCodeAt(name, 0) == 0xFFFE && StringTools.fastCodeAt(name, 1) == '@'.code;
	}

	static function isObjectOrArrayLiteralType(t:Type):Bool {
		return t.objectFlags & (ObjectFlagsObjectLiteral | ObjectFlagsArrayLiteral) != 0;
	}

	static function getContainingClassExcludingClassDecorators(node:Node):ClassLikeDeclaration {
		final decorator = Ast.FindAncestorOrQuit(node.Parent, (n:Node) -> {
			if (Ast.IsClassLike(n)) {
				return FindAncestorQuit;
			}
			if (Ast.IsDecorator(n)) {
				return FindAncestorTrue;
			}
			return FindAncestorFalse;
		});
		if (decorator != null && Ast.IsClassLike(decorator.Parent)) {
			return Ast.GetContainingClass(decorator.Parent);
		}
		if (decorator != null) {
			return Ast.GetContainingClass(decorator);
		}
		return Ast.GetContainingClass(node);
	}

	static function isThisTypeParameter(t:Type):Bool {
		return t.flags & TypeFlagsTypeParameter != 0 && t.AsTypeParameter().isThisType;
	}

	static function isClassInstanceProperty(node:Node):Bool {
		if (Ast.IsInJSFile(node) && Ast.IsExpandoPropertyDeclaration(node)) {
			final left = node.AsBinaryExpression().Left;
			return (!Ast.IsBindableStaticAccessExpression(left, false /*excludeThisKeyword*/) || !Ast.IsPrototypeAccess(left.Expression()))
				&& !Ast.IsBindableStaticNameExpression(left, true /*excludeThisKeyword*/);
		}
		return node.Parent != null && Ast.IsClassLike(node.Parent) && Ast.IsPropertyDeclaration(node) && !Ast.HasAccessorModifier(node);
	}

	static function isThisInitializedObjectBindingExpression(node:Node):Bool {
		return node != null && (Ast.IsShorthandPropertyAssignment(node) || Ast.IsPropertyAssignment(node)) && Ast.IsBinaryExpression(node.Parent.Parent)
			&& node.Parent.Parent.AsBinaryExpression().OperatorToken.Kind == KindEqualsToken
			&& node.Parent.Parent.AsBinaryExpression().Right.Kind == KindThisKeyword;
	}

	static function isThisInitializedDeclaration(node:Node):Bool {
		return node != null && Ast.IsVariableDeclaration(node) && node.Initializer() != null && node.Initializer().Kind == KindThisKeyword;
	}

	static function isInfinityOrNaNString(name:std.String):Bool {
		return name == "Infinity" || name == "-Infinity" || name == "NaN";
	}

	static function isInAmbientOrTypeNode(node:Node):Bool {
		return node.Flags & NodeFlagsAmbient != 0 || Ast.FindAncestor(node, (n:Node) -> {
			return Ast.IsInterfaceDeclaration(n) || Ast.IsTypeOrJSTypeAliasDeclaration(n) || Ast.IsTypeLiteralNode(n);
		}) != null;
	}

	static function isLiteralExpressionOfObject(node:Node):Bool {
		switch (node.Kind) {
			case KindObjectLiteralExpression | KindArrayLiteralExpression | KindRegularExpressionLiteral | KindFunctionExpression | KindClassExpression:
				return true;
			default:
		}
		return false;
	}

	static function canHaveFlowNode(node:Node):Bool {
		return node.FlowNodeData() != null;
	}

	static function isNonNullAccess(node:Node):Bool {
		return Ast.IsAccessExpression(node) && Ast.IsNonNullExpression(node.Expression());
	}

	static function getBindingElementPropertyName(node:Node):Node {
		return node.PropertyNameOrName();
	}

	static function isCallChain(node:Node):Bool {
		return Ast.IsCallExpression(node) && node.Flags & NodeFlagsOptionalChain != 0;
	}

	static function isSuperCall(n:Node):Bool {
		return Ast.IsCallExpression(n) && n.Expression().Kind == KindSuperKeyword;
	}

	static function getMembersOfDeclaration(node:Node):Array<Node> {
		switch (node.Kind) {
			case KindInterfaceDeclaration | KindClassDeclaration | KindClassExpression | KindTypeLiteral:
				return node.Members();
			case KindObjectLiteralExpression:
				return node.Properties();
			default:
		}
		return null;
	}

	static function isInRightSideOfImportOrExportAssignment(node:EntityName):Bool {
		while (node.Parent.Kind == KindQualifiedName) {
			node = node.Parent;
		}

		return node.Parent.Kind == KindImportEqualsDeclaration && node.Parent.AsImportEqualsDeclaration().ModuleReference == node
			|| node.Parent.Kind == KindExportAssignment && node.Parent.Expression() == node;
	}

	static function isJsxIntrinsicTagName(tagName:Node):Bool {
		return Ast.IsIdentifier(tagName) && Scanner.IsIntrinsicJsxName(tagName.Text()) || Ast.IsJsxNamespacedName(tagName);
	}

	static function getContainingObjectLiteral(f:SignatureDeclaration):Node {
		if ((f.Kind == KindMethodDeclaration || f.Kind == KindGetAccessor || f.Kind == KindSetAccessor) && f.Parent.Kind == KindObjectLiteralExpression) {
			return f.Parent;
		} else if (f.Kind == KindFunctionExpression && f.Parent.Kind == KindPropertyAssignment) {
			return f.Parent.Parent;
		}
		return null;
	}

	static function isImportTypeQualifierPart(node:Node):Node {
		var parent = node.Parent;
		while (Ast.IsQualifiedName(parent)) {
			node = parent;
			parent = parent.Parent;
		}

		if (parent != null && parent.Kind == KindImportType && parent.AsImportTypeNode().Qualifier == node) {
			return parent;
		}

		return null;
	}

	static function isInNameOfExpressionWithTypeArguments(node:Node):Bool {
		while (node.Parent.Kind == KindPropertyAccessExpression) {
			node = node.Parent;
		}

		return node.Parent.Kind == KindExpressionWithTypeArguments;
	}

	static function getIndexSymbolFromSymbolTable(symbolTable:SymbolTable):Symbol {
		return symbolTable == null ? null : symbolTable.get(Ast.InternalSymbolNameIndex);
	}

	// Indicates whether the result of an `Expression` will be unused.
	// NOTE: This requires a node with a valid `parent` pointer.
	static function expressionResultIsUnused(node:Node):Bool {
		while (true) {
			final parent = node.Parent;
			// walk up parenthesized expressions, but keep a pointer to the top-most parenthesized expression
			if (Ast.IsParenthesizedExpression(parent)) {
				node = parent;
				continue;
			}
			// result is unused in an expression statement, `void` expression, or the initializer or incrementer of a `for` loop
			if (Ast.IsExpressionStatement(parent) || Ast.IsVoidExpression(parent)
				|| Ast.IsForStatement(parent) && (parent.Initializer() == node || parent.AsForStatement().Incrementor == node)) {
				return true;
			}
			if (Ast.IsBinaryExpression(parent) && parent.AsBinaryExpression().OperatorToken.Kind == KindCommaToken) {
				// left side of comma is always unused
				if (node == parent.AsBinaryExpression().Left) {
					return true;
				}
				// right side of comma is unused if parent is unused
				node = parent;
				continue;
			}
			return false;
		}
	}

	static function pseudoBigIntToString(value:PseudoBigInt):std.String {
		return value.String();
	}

	static function getSuperContainer(node:Node, stopOnFunctions:Bool):Node {
		while (true) {
			node = node.Parent;
			if (node == null) {
				return null;
			}
			switch (node.Kind) {
				case KindComputedPropertyName:
					node = node.Parent;
				case KindFunctionDeclaration | KindFunctionExpression | KindArrowFunction:
					if (!stopOnFunctions) {
						continue;
					}
					// fallthrough
					return node;
				case KindPropertyDeclaration | KindPropertySignature | KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor |
					KindSetAccessor | KindClassStaticBlockDeclaration:
					return node;
				case KindDecorator:
					// Decorators are always applied outside of the body of a class or method.
					if (Ast.IsParameterDeclaration(node.Parent) && Ast.IsClassElement(node.Parent.Parent)) {
						// If the decorator's parent is a Parameter, we resolve the this container from
						// the grandparent class declaration.
						node = node.Parent.Parent;
					} else if (Ast.IsClassElement(node.Parent)) {
						// If the decorator's parent is a class element, we resolve the 'this' container
						// from the parent class declaration.
						node = node.Parent;
					}
				default:
			}
		}
	}

	static function forEachYieldExpression(body:Node, visitor:(expr:Node) -> Bool):Bool {
		var traverse:(Node) -> Bool = null;
		traverse = (node:Node) -> {
			switch (node.Kind) {
				case KindYieldExpression:
					if (visitor(node)) {
						return true;
					}
					final operand = node.Expression();
					if (operand == null) {
						return false;
					}
					return traverse(operand);
				case KindEnumDeclaration | KindInterfaceDeclaration | KindModuleDeclaration | KindTypeAliasDeclaration:
					// These are not allowed inside a generator now, but eventually they may be allowed
					// as local types. Regardless, skip them to avoid the work.
				default:
					if (Ast.IsFunctionLike(node)) {
						if (node.Name() != null && Ast.IsComputedPropertyName(node.Name())) {
							// Note that we will not include methods/accessors of a class because they would require
							// first descending into the class. This is by design.
							return traverse(node.Name().Expression());
						}
					} else if (!Ast.IsPartOfTypeNode(node)) {
						// This is the general case, which should include mostly expressions and statements.
						// Also includes NodeArrays.
						return node.ForEachChild(traverse);
					}
			}
			return false;
		};
		return traverse(body);
	}

	static function getEnclosingContainer(node:Node):Node {
		return Ast.FindAncestor(node.Parent, (n:Node) -> {
			return Binder.GetContainerFlags(n) & ContainerFlagsIsContainer != 0;
		});
	}

	static function getDeclarationsOfKind(symbol:Symbol, kind:Kind):Array<Node> {
		return Core.Filter(symbol.Declarations, (d:Node) -> d.Kind == kind);
	}

	static function hasType(node:Node):Bool {
		return node.Type() != null;
	}

	static function getNonRestParameterCount(sig:Signature):Int {
		return Core.len(sig.parameters) - Core.IfElse(signatureHasRestParameter(sig), 1, 0);
	}

	static function minAndMax<T>(slice:Array<T>, getValue:(value:T) -> Int):Pair<Int, Int> {
		var minValue = 0;
		var maxValue = 0;
		if (slice != null) {
			for (i in 0...slice.length) {
				final value = getValue(slice[i]);
				if (i == 0) {
					minValue = value;
					maxValue = value;
				} else {
					minValue = minValue < value ? minValue : value;
					maxValue = maxValue > value ? maxValue : value;
				}
			}
		}
		return new Pair<Int, Int>(minValue, maxValue);
	}

	// PORT: sync.OnceValue → a lazy static.
	static var featureMap_:StringMap<Array<FeatureMapEntry>> = null;

	static var getFeatureMap:() -> StringMap<Array<FeatureMapEntry>> = () -> {
		if (featureMap_ == null) {
			final m = new StringMap<Array<FeatureMapEntry>>();
			function add(name:std.String, lib:std.String, props:Array<std.String>) {
				var list = m.get(name);
				if (list == null) {
					list = [];
					m.set(name, list);
				}
				final e = new FeatureMapEntry();
				e.lib = lib;
				e.props = props;
				list.push(e);
			}
			add("Array", "es2015", ["find", "findIndex", "fill", "copyWithin", "entries", "keys", "values"]);
			add("Array", "es2016", ["includes"]);
			add("Array", "es2019", ["flat", "flatMap"]);
			add("Array", "es2022", ["at"]);
			add("Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Iterator", "es2015", []);
			add("AsyncIterator", "es2015", []);
			add("ArrayBuffer", "es2024", ["maxByteLength", "resizable", "resize", "detached", "transfer", "transferToFixedLength"]);
			add("Atomics", "es2017", ["add", "and", "compareExchange", "exchange", "isLockFree", "load", "or", "store", "sub", "wait", "notify", "xor"]);
			add("Atomics", "es2024", ["waitAsync"]);
			add("SharedArrayBuffer", "es2017", ["byteLength", "slice"]);
			add("SharedArrayBuffer", "es2024", ["growable", "maxByteLength", "grow"]);
			add("AsyncIterable", "es2018", []);
			add("AsyncIterableIterator", "es2018", []);
			add("AsyncGenerator", "es2018", []);
			add("AsyncGeneratorFunction", "es2018", []);
			add("RegExp", "es2015", ["flags", "sticky", "unicode"]);
			add("RegExp", "es2018", ["dotAll"]);
			add("RegExp", "es2024", ["unicodeSets"]);
			add("RegExpConstructor", "es2025", ["escape"]);
			add("Reflect", "es2015", ["apply", "construct", "defineProperty", "deleteProperty", "get", "getOwnPropertyDescriptor", "getPrototypeOf", "has", "isExtensible", "ownKeys", "preventExtensions", "set", "setPrototypeOf"]);
			add("ArrayConstructor", "es2015", ["from", "of"]);
			add("ArrayConstructor", "esnext", ["fromAsync"]);
			add("ObjectConstructor", "es2015", ["assign", "getOwnPropertySymbols", "keys", "is", "setPrototypeOf"]);
			add("ObjectConstructor", "es2017", ["values", "entries", "getOwnPropertyDescriptors"]);
			add("ObjectConstructor", "es2019", ["fromEntries"]);
			add("ObjectConstructor", "es2022", ["hasOwn"]);
			add("ObjectConstructor", "es2024", ["groupBy"]);
			add("NumberConstructor", "es2015", ["isFinite", "isInteger", "isNaN", "isSafeInteger", "parseFloat", "parseInt"]);
			add("Math", "es2015", ["clz32", "imul", "sign", "log10", "log2", "log1p", "expm1", "cosh", "sinh", "tanh", "acosh", "asinh", "atanh", "hypot", "trunc", "fround", "cbrt"]);
			add("Math", "es2025", ["f16round"]);
			add("Map", "es2015", ["entries", "keys", "values"]);
			add("Map", "esnext", ["getOrInsert", "getOrInsertComputed"]);
			add("MapConstructor", "es2024", ["groupBy"]);
			add("Set", "es2015", ["entries", "keys", "values"]);
			add("Set", "es2025", ["union", "intersection", "difference", "symmetricDifference", "isSubsetOf", "isSupersetOf", "isDisjointFrom"]);
			add("PromiseConstructor", "es2015", ["all", "race", "reject", "resolve"]);
			add("PromiseConstructor", "es2020", ["allSettled"]);
			add("PromiseConstructor", "es2021", ["any"]);
			add("PromiseConstructor", "es2024", ["withResolvers"]);
			add("PromiseConstructor", "es2025", ["try"]);
			add("Symbol", "es2015", ["for", "keyFor"]);
			add("Symbol", "es2019", ["description"]);
			add("WeakMap", "es2015", []);
			add("WeakMap", "esnext", ["getOrInsert", "getOrInsertComputed"]);
			add("WeakSet", "es2015", []);
			add("String", "es2015", ["codePointAt", "includes", "endsWith", "normalize", "repeat", "startsWith", "anchor", "big", "blink", "bold", "fixed", "fontcolor", "fontsize", "italics", "link", "small", "strike", "sub", "sup"]);
			add("String", "es2017", ["padStart", "padEnd"]);
			add("String", "es2019", ["trimStart", "trimEnd", "trimLeft", "trimRight"]);
			add("String", "es2020", ["matchAll"]);
			add("String", "es2021", ["replaceAll"]);
			add("String", "es2022", ["at"]);
			add("String", "es2024", ["isWellFormed", "toWellFormed"]);
			add("StringConstructor", "es2015", ["fromCodePoint", "raw"]);
			add("DateTimeFormat", "es2017", ["formatToParts"]);
			add("Promise", "es2015", []);
			add("Promise", "es2018", ["finally"]);
			add("RegExpMatchArray", "es2018", ["groups"]);
			add("RegExpExecArray", "es2018", ["groups"]);
			add("Intl", "es2018", ["PluralRules"]);
			add("Intl", "es2020", ["RelativeTimeFormat", "Locale", "DisplayNames"]);
			add("Intl", "es2021", ["ListFormat", "DateTimeFormat"]);
			add("Intl", "es2022", ["Segmenter"]);
			add("Intl", "es2025", ["DurationFormat"]);
			add("NumberFormat", "es2018", ["formatToParts"]);
			add("SymbolConstructor", "es2020", ["matchAll"]);
			add("SymbolConstructor", "esnext", ["metadata", "dispose", "asyncDispose"]);
			add("DataView", "es2020", ["setBigInt64", "setBigUint64", "getBigInt64", "getBigUint64"]);
			add("DataView", "es2025", ["setFloat16", "getFloat16"]);
			add("BigInt", "es2020", []);
			add("RelativeTimeFormat", "es2020", ["format", "formatToParts", "resolvedOptions"]);
			add("Int8Array", "es2022", ["at"]);
			add("Int8Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Uint8Array", "es2022", ["at"]);
			add("Uint8Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Uint8ClampedArray", "es2022", ["at"]);
			add("Uint8ClampedArray", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Int16Array", "es2022", ["at"]);
			add("Int16Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Uint16Array", "es2022", ["at"]);
			add("Uint16Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Int32Array", "es2022", ["at"]);
			add("Int32Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Uint32Array", "es2022", ["at"]);
			add("Uint32Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Float16Array", "es2025", []);
			add("Float32Array", "es2022", ["at"]);
			add("Float32Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Float64Array", "es2022", ["at"]);
			add("Float64Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("BigInt64Array", "es2020", []);
			add("BigInt64Array", "es2022", ["at"]);
			add("BigInt64Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("BigUint64Array", "es2020", []);
			add("BigUint64Array", "es2022", ["at"]);
			add("BigUint64Array", "es2023", ["findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with"]);
			add("Error", "es2022", ["cause"]);
			add("ErrorConstructor", "esnext", ["isError"]);
			add("Uint8ArrayConstructor", "esnext", ["fromBase64", "fromHex"]);
			add("DisposableStack", "esnext", []);
			add("AsyncDisposableStack", "esnext", []);
			add("Date", "esnext", ["toTemporalInstant"]);
			featureMap_ = m;
		}
		return featureMap_;
	};

	static function rangeOfTypeParameters(sourceFile:SourceFile, typeParameters:NodeList):TextRange {
		final end = Scanner.SkipTrivia(sourceFile.Text(), typeParameters.End()) + 1;
		return new TextRange(typeParameters.Pos() - 1, sourceFile.Text().length < end ? sourceFile.Text().length : end);
	}

	static function tryGetPropertyAccessOrIdentifierToString(expr:Node):std.String {
		if (Ast.IsPropertyAccessExpression(expr)) {
			final baseStr = tryGetPropertyAccessOrIdentifierToString(expr.Expression());
			if (baseStr != "") {
				return baseStr + "." + entityNameToString(expr.Name());
			}
		} else if (Ast.IsElementAccessExpression(expr)) {
			final baseStr = tryGetPropertyAccessOrIdentifierToString(expr.Expression());
			if (baseStr != "" && Ast.IsPropertyName(expr.AsElementAccessExpression().ArgumentExpression)) {
				return baseStr + "." + Ast.GetPropertyNameForPropertyNameNode(expr.AsElementAccessExpression().ArgumentExpression);
			}
		} else if (Ast.IsIdentifier(expr)) {
			return expr.Text();
		} else if (Ast.IsJsxNamespacedName(expr)) {
			return entityNameToString(expr);
		}
		return "";
	}

	static function allDeclarationsInSameSourceFile(symbol:Symbol):Bool {
		if (Core.len(symbol.Declarations) > 1) {
			var sourceFile:SourceFile = null;
			for (i in 0...symbol.Declarations.length) {
				final d = symbol.Declarations[i];
				if (i == 0) {
					sourceFile = Ast.GetSourceFileOfNode(d);
				} else if (Ast.GetSourceFileOfNode(d) != sourceFile) {
					return false;
				}
			}
		}
		return true;
	}

	static function containsNonMissingUndefinedType(c:Checker, t:Type):Bool {
		var candidate:Type = null;
		if (t.flags & TypeFlagsUnion != 0) {
			candidate = t.AsUnionType().types[0];
		} else {
			candidate = t;
		}
		return candidate.flags & TypeFlagsUndefined != 0 && candidate != c.missingType;
	}

	static function getAnyImportSyntax(node:Node):Node {
		var importNode:Node = null;
		switch (node.Kind) {
			case KindImportEqualsDeclaration:
				importNode = node;
			case KindImportClause:
				importNode = node.Parent;
			case KindNamespaceImport:
				importNode = node.Parent.Parent;
			case KindImportSpecifier:
				importNode = node.Parent.Parent.Parent;
			default:
				return null;
		}
		return importNode;
	}

	// A reserved member name consists of the byte 0xFE (which is an invalid UTF-8 encoding) followed by one or more
	// characters where the first character is not '@' or '#'. The '@' character indicates that the name is denoted by
	// a well known ES Symbol instance and the '#' character indicates that the name is a PrivateIdentifier.
	static function isReservedMemberName(name:std.String):Bool {
		// PORT: Go byte 0xFE is U+FFFE here (Ast.InternalSymbolNamePrefix).
		return name.length >= 2 && StringTools.fastCodeAt(name, 0) == 0xFFFE && StringTools.fastCodeAt(name, 1) != '@'.code
			&& StringTools.fastCodeAt(name, 1) != '#'.code;
	}

	static function introducesArgumentsExoticObject(node:Node):Bool {
		switch (node.Kind) {
			case KindMethodDeclaration | KindMethodSignature | KindConstructor | KindGetAccessor | KindSetAccessor | KindFunctionDeclaration |
				KindFunctionExpression:
				return true;
			default:
		}
		return false;
	}

	static function symbolsToArray(symbols:SymbolTable):Array<Symbol> {
		var result:Array<Symbol> = null;
		if (symbols != null) {
			for (id => symbol in symbols) {
				if (!isReservedMemberName(id)) {
					if (result == null) {
						result = [];
					}
					result.push(symbol);
				}
			}
		}
		return result;
	}

	public static function SkipAlias(symbol:Symbol, checker:Checker):Symbol {
		if (symbol.Flags & SymbolFlagsAlias != 0) {
			return checker.GetAliasedSymbol(symbol);
		}
		return symbol;
	}

	// True if the symbol is for an external module, as opposed to a namespace.
	public static function IsExternalModuleSymbol(moduleSymbol:Symbol):Bool {
		final name = moduleSymbol.Name;
		final firstRune = name.length == 0 ? go.Utf16.RuneError : go.Utf16.CodePointAt(name, 0);
		return moduleSymbol.Flags & SymbolFlagsModule != 0 && firstRune == '"'.code;
	}

	public static function ValueToString(value:Any):std.String {
		if (Std.isOfType(value, std.String)) {
			return "\"" + Printer.EscapeString((value : std.String), '"'.code) + "\"";
		} else if (Std.isOfType(value, Float)) {
			return ts.jsnum.String_.String((value : Float));
		} else if (Std.isOfType(value, Bool)) {
			return Core.IfElse((value : Bool), "true", "false");
		} else if (Std.isOfType(value, PseudoBigInt)) {
			return (value : PseudoBigInt).String() + "n";
		}
		throw "unhandled value type in valueToString";
	}

	static function nodeStartsNewLexicalEnvironment(node:Node):Bool {
		switch (node.Kind) {
			case KindConstructor | KindFunctionExpression | KindFunctionDeclaration | KindArrowFunction | KindMethodDeclaration | KindGetAccessor |
				KindSetAccessor | KindModuleDeclaration | KindSourceFile:
				return true;
			default:
		}
		return false;
	}

	// CreateModuleNotFoundChain computes the diagnostic message and arguments for a module-not-found
	// error chain entry. This is shared between the checker (initial diagnostic creation) and the
	// incremental builder (repopulation of cached diagnostics).
	// Mirrors createModuleNotFoundChain in the TypeScript compiler's utilities.ts.
	public static function CreateModuleNotFoundChain(program:Program, file:SourceFile, moduleReference:std.String, mode:ResolutionMode, packageName:std.String):DiagnosticDetails {
		// PORT: *ast.SourceFile as ast.HasFileName → the shared adapter (modulespecifiers SourceFileAdapter).
		final resolvedModule = program.GetResolvedModule(ts.modulespecifiers.Types.SourceFileAdapter.Of(file), moduleReference, mode);

		if (resolvedModule != null && resolvedModule.AlternateResult != "") {
			if (resolvedModule.AlternateResult.indexOf("/node_modules/@types/") >= 0) {
				packageName = "@types/" + Module.MangleScopedPackageName(packageName);
			}
			return newDiagnosticDetails(Diagnostics.There_are_types_at_0_but_this_result_could_not_be_resolved_when_respecting_package_json_exports_The_1_library_may_need_to_update_its_package_json_or_typings,
				[resolvedModule.AlternateResult, packageName]);
		}

		final packagesMap = program.GetPackagesMap();
		if (packagesMap != null && packagesMap.exists(Module.GetTypesPackageName(packageName))) {
			return newDiagnosticDetails(Diagnostics.If_the_0_package_actually_exposes_this_module_consider_sending_a_pull_request_to_amend_https_Colon_Slash_Slashgithub_com_SlashDefinitelyTyped_SlashDefinitelyTyped_Slashtree_Slashmaster_Slashtypes_Slash_1,
				[packageName, Module.MangleScopedPackageName(packageName)]);
		}
		if (packagesMap != null && packagesMap.get(packageName) == true) {
			return newDiagnosticDetails(Diagnostics.If_the_0_package_actually_exposes_this_module_try_adding_a_new_declaration_d_ts_file_containing_declare_module_1,
				[packageName, moduleReference]);
		}
		return newDiagnosticDetails(Diagnostics.Try_npm_i_save_dev_types_Slash_1_if_it_exists_or_add_a_new_declaration_d_ts_file_containing_declare_module_0,
			[moduleReference, Module.MangleScopedPackageName(packageName)]);
	}

	// CreateModeMismatchDetails computes the diagnostic message and arguments for a mode-mismatch
	// error chain entry. This is shared between the checker (initial diagnostic creation) and the
	// incremental builder (repopulation of cached diagnostics).
	// Mirrors createModeMismatchDetails in the TypeScript compiler's utilities.ts.
	public static function CreateModeMismatchDetails(program:Program, file:SourceFile):DiagnosticDetails {
		final ext = Tspath.TryGetExtensionFromPath(file.FileName());
		final targetExt = Core.IfElse(ext == Tspath.ExtensionTs, Tspath.ExtensionMts, Core.IfElse(ext == Tspath.ExtensionJs, Tspath.ExtensionMjs, ""));
		final meta = program.GetSourceFileMetaData(file.Path());
		final packageJsonType = meta.PackageJsonType;
		final packageJsonDirectory = meta.PackageJsonDirectory;

		if (packageJsonDirectory != "" && packageJsonType == "") {
			if (targetExt != "") {
				return newDiagnosticDetails(Diagnostics.To_convert_this_file_to_an_ECMAScript_module_change_its_file_extension_to_0_or_add_the_field_type_Colon_module_to_1,
					[targetExt, Tspath.CombinePaths(packageJsonDirectory, "package.json")]);
			}
			return newDiagnosticDetails(Diagnostics.To_convert_this_file_to_an_ECMAScript_module_add_the_field_type_Colon_module_to_0,
				[Tspath.CombinePaths(packageJsonDirectory, "package.json")]);
		}
		if (targetExt != "") {
			return newDiagnosticDetails(Diagnostics.To_convert_this_file_to_an_ECMAScript_module_change_its_file_extension_to_0_or_create_a_local_package_json_file_with_type_Colon_module,
				[targetExt]);
		}
		return newDiagnosticDetails(Diagnostics.To_convert_this_file_to_an_ECMAScript_module_create_a_local_package_json_file_with_type_Colon_module, null);
	}

	static function walkUpOuterExpressions(node:Node):Node {
		var parent = node.Parent;
		while (parent != null && Ast.IsOuterExpression(parent, OEKAll)) {
			parent = parent.Parent;
		}
		return parent;
	}

	public static function GetSetAccessorValueParameter(accessor:Node):Node {
		final parameters = accessor.Parameters();
		if (Core.len(parameters) > 0) {
			final hasThis = parameters.length == 2 && Ast.IsThisParameter(parameters[0]);
			return parameters[Core.IfElse(hasThis, 1, 0)];
		}
		return null;
	}
}

// Go: anonymous struct type
class JsxNamesStruct {
	public var JSX:std.String = "";
	public var IntrinsicElements:std.String = "";
	public var ElementClass:std.String = "";
	public var ElementAttributesPropertyNameContainer:std.String = "";
	public var ElementChildrenAttributeNameContainer:std.String = "";
	public var Element:std.String = "";
	public var ElementType:std.String = "";
	public var IntrinsicAttributes:std.String = "";
	public var IntrinsicClassAttributes:std.String = "";
	public var LibraryManagedAttributes:std.String = "";

	public function new() {}
}

// Go: anonymous struct type
class ReactNamesStruct {
	public var Fragment:std.String = "";

	public function new() {}
}

// Go: anonymous struct type
class TypeFlagNamesStruct {
	public var flag:TypeFlags = 0;
	public var name:std.String = "";

	public function new() {}
}
