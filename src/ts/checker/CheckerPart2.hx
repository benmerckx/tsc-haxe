package ts.checker;

// GENERATED SKELETON by tools/gen/skeleton from internal/checker/checker.go (upstream v7.0.2).
// Types, fields and signatures only: port the bodies by hand (docs/PORTING.md).

// Part of checker.go, Go lines 3971-7979 (4009 lines): the Checker methods of this range as static extension
// (receiver first, PORTING.md §2; `using ts.checker.CheckerPart2` in import.hx). Inside class Checker call them as `this.m(...)`.
@:allow(ts.checker)
class CheckerPart2 {


	static function checkForInStatement(c:Checker, node:Node):Void {
		final data = node.AsForInOrOfStatement();
		c.checkGrammarForInOrForOfStatement(data);
		final rightType = c.getNonNullableTypeIfNeeded(c.checkExpression(data.Expression));
		// TypeScript 1.0 spec (April 2014): 5.4
		// In a 'for-in' statement of the form
		// for (let VarDecl in Expr) Statement
		//   VarDecl must be a variable declaration without a type annotation that declares a variable of type Any,
		//   and Expr must be an expression of type Any, an object type, or a type parameter type.
		if (Ast.IsVariableDeclarationList(data.Initializer)) {
			final declarations = data.Initializer.AsVariableDeclarationList().Declarations.Nodes;
			if (declarations.length != 0 && Ast.IsBindingPattern(declarations[0].Name())) {
				c.error(declarations[0].Name(), Diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_a_destructuring_pattern);
			}
			c.checkVariableDeclarationList(data.Initializer);
		} else {
			// In a 'for-in' statement of the form
			// for (Var in Expr) Statement
			//   Var must be an expression classified as a reference of type Any or the String primitive type,
			//   and Expr must be an expression of type Any, an object type, or a type parameter type.
			final varExpr = data.Initializer;
			final leftType = c.checkExpression(varExpr);
			if (Ast.IsArrayLiteralExpression(varExpr) || Ast.IsObjectLiteralExpression(varExpr)) {
				c.error(varExpr, Diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_a_destructuring_pattern);
			} else if (!c.isTypeAssignableTo(c.getIndexTypeOrString(rightType), leftType)) {
				c.error(varExpr, Diagnostics.The_left_hand_side_of_a_for_in_statement_must_be_of_type_string_or_any);
			} else {
				// run check only former check succeeded to avoid cascading errors
				c.checkReferenceExpression(varExpr, Diagnostics.The_left_hand_side_of_a_for_in_statement_must_be_a_variable_or_a_property_access,
					Diagnostics.The_left_hand_side_of_a_for_in_statement_may_not_be_an_optional_property_access);
			}
		}
		// unknownType is returned i.e. if node.expression is identifier whose name cannot be resolved
		// in this case error about missing name is already reported - do not report extra one
		if (rightType == c.neverType || !c.isTypeAssignableToKind(rightType, TypeFlagsNonPrimitive | TypeFlagsInstantiableNonPrimitive)) {
			c.error(data.Expression,
				Diagnostics.The_right_hand_side_of_a_for_in_statement_must_be_of_type_any_an_object_type_or_a_type_parameter_but_here_has_type_0,
				c.TypeToString(rightType));
		}
		c.checkSourceElement(data.Statement);
		if (node.Locals() != null) {
			c.registerForUnusedIdentifiersCheck(node);
		}
	}

	static function getIndexTypeOrString(c:Checker, t:Type):Type {
		final indexType = c.getExtractStringType(c.getIndexType(t));
		return Core.IfElse((indexType.flags & TypeFlagsNever) != 0, c.stringType, indexType);
	}

	static function checkForOfStatement(c:Checker, node:Node):Void {
		final data = node.AsForInOrOfStatement();
		c.checkGrammarForInOrForOfStatement(data);
		final container = Checker.getContainingFunctionOrClassStaticBlock(node);
		if (data.AwaitModifier != null) {
			if (container != null && Ast.IsClassStaticBlockDeclaration(container)) {
				c.grammarErrorOnNode(data.AwaitModifier, Diagnostics.X_for_await_loops_cannot_be_used_inside_a_class_static_block);
			} else {
				final functionFlags = Ast.GetFunctionFlags(container);
				if ((functionFlags & (FunctionFlagsInvalid | FunctionFlagsAsync)) == FunctionFlagsAsync
					&& (c.languageVersion : Int) < (Checker.LanguageFeatureMinimumTarget.ForAwaitOf : Int)) {
					// for..await..of in an async function or async generator function prior to ESNext requires the __asyncValues helper
					c.checkExternalEmitHelpers(node, ExternalEmitHelpersForAwaitOfIncludes);
				}
			}
		} // Check the LHS and RHS
		// If the LHS is a declaration, just check it as a variable declaration, which will in turn check the RHS
		// via checkRightHandSideOfForOf.
		// If the LHS is an expression, check the LHS, as a destructuring assignment or as a reference.
		// Then check that the RHS is assignable to it.
		if (Ast.IsVariableDeclarationList(data.Initializer)) {
			c.checkVariableDeclarationList(data.Initializer);
		} else {
			final varExpr = data.Initializer;
			final iteratedType = c.checkRightHandSideOfForOf(node);
			// There may be a destructuring assignment on the left side
			if (Ast.IsArrayLiteralExpression(varExpr) || Ast.IsObjectLiteralExpression(varExpr)) {
				// iteratedType may be undefined. In this case, we still want to check the structure of
				// varExpr, in particular making sure it's a valid LeftHandSideExpression. But we'd like
				// to short circuit the type relation checking as much as possible, so we pass the unknownType.
				c.checkDestructuringAssignment(varExpr, Core.OrElse(iteratedType, c.errorType), CheckModeNormal, false);
			} else {
				final leftType = c.checkExpression(varExpr);
				c.checkReferenceExpression(varExpr, Diagnostics.The_left_hand_side_of_a_for_of_statement_must_be_a_variable_or_a_property_access,
					Diagnostics.The_left_hand_side_of_a_for_of_statement_may_not_be_an_optional_property_access);
				// iteratedType will be undefined if the rightType was missing properties/signatures
				// required to get its iteratedType (like [Symbol.iterator] or next). This may be
				// because we accessed properties from anyType, or it may have led to an error inside
				// getElementTypeOfIterable.
				if (iteratedType != null) {
					c.checkTypeAssignableToAndOptionallyElaborate(iteratedType, leftType, varExpr, data.Expression, null, null);
				}
			}
		}
		c.checkSourceElement(data.Statement);
		if (node.Locals() != null) {
			c.registerForUnusedIdentifiersCheck(node);
		}
	}

	static function checkBreakOrContinueStatement(c:Checker, node:Node):Void {
		if (!c.checkGrammarStatementInAmbientContext(node)) {
			c.checkGrammarBreakOrContinueStatement(node);
		}
	}

	static function checkReturnStatement(c:Checker, node:Node):Void {
		if (c.checkGrammarStatementInAmbientContext(node)) {
			return;
		}
		final container = Checker.getContainingFunctionOrClassStaticBlock(node);
		if (container != null && Ast.IsClassStaticBlockDeclaration(container)) {
			c.grammarErrorOnFirstToken(node, Diagnostics.A_return_statement_cannot_be_used_inside_a_class_static_block);
			return;
		}
		if (container == null) {
			c.grammarErrorOnFirstToken(node, Diagnostics.A_return_statement_can_only_be_used_within_a_function_body);
			return;
		}
		final signature = c.getSignatureFromDeclaration(container);
		final returnType = c.getReturnTypeOfSignature(signature);
		final functionFlags = Ast.GetFunctionFlags(container);
		final exprNode = node.Expression();
		if (c.strictNullChecks || exprNode != null || (returnType.flags & TypeFlagsNever) != 0) {
			var exprType = c.undefinedType;
			if (exprNode != null) {
				exprType = c.checkExpressionCached(exprNode);
			}
			if (Ast.IsSetAccessorDeclaration(container)) {
				if (exprNode != null) {
					c.error(node, Diagnostics.Setters_cannot_return_a_value);
				}
			} else if (Ast.IsConstructorDeclaration(container)) {
				if (exprNode != null && !c.checkTypeAssignableToAndOptionallyElaborate(exprType, returnType, node, exprNode, null, null)) {
					c.error(node, Diagnostics.Return_type_of_constructor_signature_must_be_assignable_to_the_instance_type_of_the_class);
				}
			} else if (c.getReturnTypeFromAnnotation(container) != null) {
				final unwrappedReturnType = Core.OrElse(c.unwrapReturnType(returnType, functionFlags), returnType);
				c.checkReturnExpression(container, unwrappedReturnType, node, node.Expression(), exprType, false);
			}
		} else if (!Ast.IsConstructorDeclaration(container) && c.compilerOptions.NoImplicitReturns.IsTrue()
			&& !c.isUnwrappedReturnTypeUndefinedVoidOrAny(container, returnType)) {
			// The function has a return type, but the return statement doesn't have an expression.
			c.error(node, Diagnostics.Not_all_code_paths_return_a_value);
		}
	}

	// When checking an arrow expression such as `(x) => exp`, then `node` is the expression `exp`.
	// Otherwise, `node` is a return statement.
	static function checkReturnExpression(c:Checker, container:Node, unwrappedReturnType:Type, node:Node, expr:Node, exprType:Type, inConditionalExpression:Bool):Void {
		var unwrappedExprType = exprType;
		final functionFlags = Ast.GetFunctionFlags(container);
		if (expr != null) {
			final unwrappedExpr = Ast.SkipParentheses(expr);
			if (Ast.IsConditionalExpression(unwrappedExpr)) {
				final whenTrue = unwrappedExpr.AsConditionalExpression().WhenTrue;
				final whenFalse = unwrappedExpr.AsConditionalExpression().WhenFalse;
				c.checkReturnExpression(container, unwrappedReturnType, node, whenTrue, c.checkExpression(whenTrue), true /*inConditionalExpression*/);
				c.checkReturnExpression(container, unwrappedReturnType, node, whenFalse, c.checkExpression(whenFalse), true /*inConditionalExpression*/);
				return;
			}
		}
		final inReturnStatement = node.Kind == KindReturnStatement;
		if ((functionFlags & FunctionFlagsAsync) != 0) {
			unwrappedExprType = c.checkAwaitedType(exprType, false /*withAlias*/, node,
				Diagnostics.The_return_type_of_an_async_function_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member);
		}
		var effectiveExpr = expr; // The effective expression for diagnostics purposes.
		if (expr != null) {
			effectiveExpr = c.getEffectiveCheckNode(expr);
		}
		final errorNode = Core.IfElse(inReturnStatement && !inConditionalExpression, node, effectiveExpr);
		c.checkTypeAssignableToAndOptionallyElaborate(unwrappedExprType, unwrappedReturnType, errorNode, effectiveExpr, null, null);
	}

	static function checkWithStatement(c:Checker, node:Node):Void {
		if (!c.checkGrammarStatementInAmbientContext(node)) {
			if ((node.Flags & NodeFlagsAwaitContext) != 0) {
				c.grammarErrorOnFirstToken(node, Diagnostics.X_with_statements_are_not_allowed_in_an_async_function_block);
			}
		}
		c.checkExpression(node.Expression());
		final sourceFile = Ast.GetSourceFileOfNode(node);
		if (!c.hasParseDiagnostics(sourceFile)) {
			final start = Scanner.SkipTrivia(sourceFile.Text(), node.Pos());
			final end = node.Statement().Pos();
			c.grammarErrorAtPos(sourceFile.AsNode(), start, end - start,
				Diagnostics.The_with_statement_is_not_supported_All_symbols_in_a_with_block_will_have_type_any);
		}
	}

	static function checkSwitchStatement(c:Checker, node:Node):Void {
		// Grammar checking
		c.checkGrammarStatementInAmbientContext(node);
		var firstDefaultClause:Node = null;
		var hasDuplicateDefaultClause = false;
		final expressionType = c.checkExpression(node.Expression());
		final caseBlock = node.AsSwitchStatement().CaseBlock;
		for (clause in caseBlock.AsCaseBlock().Clauses.Nodes) {
			// Grammar check for duplicate default clauses, skip if we already report duplicate default clause
			if (Ast.IsDefaultClause(clause) && !hasDuplicateDefaultClause) {
				if (firstDefaultClause == null) {
					firstDefaultClause = clause;
				} else {
					c.grammarErrorOnNode(clause, Diagnostics.A_default_clause_cannot_appear_more_than_once_in_a_switch_statement);
					hasDuplicateDefaultClause = true;
				}
			}
			if (Ast.IsCaseClause(clause)) {
				final caseType = c.checkExpression(clause.Expression());
				if (!c.isTypeEqualityComparableTo(expressionType, caseType)) {
					// expressionType is not comparable to caseType, try the reversed check and report errors if it fails
					c.checkTypeComparableTo(caseType, expressionType, clause.Expression(), null /*headMessage*/);
				}
			}
			c.checkSourceElements(clause.Statements());
			if (c.compilerOptions.NoFallthroughCasesInSwitch.IsTrue()) {
				final flowNode = clause.AsCaseOrDefaultClause().FallthroughFlowNode;
				if (flowNode != null && c.isReachableFlowNode(flowNode)) {
					c.error(clause, Diagnostics.Fallthrough_case_in_switch);
				}
			}
		}
		if (caseBlock.Locals() != null) {
			c.registerForUnusedIdentifiersCheck(caseBlock);
		}
	}

	static function checkLabeledStatement(c:Checker, node:Node):Void {
		final labeledStatement = node.AsLabeledStatement();
		final labelNode = labeledStatement.Label;
		final labelText = labelNode.Text();
		if (!c.checkGrammarStatementInAmbientContext(node)) {
			var current = node.Parent;
			while (current != null && !Ast.IsFunctionLike(current)) {
				if (Ast.IsLabeledStatement(current) && current.Label().Text() == labelText) {
					c.grammarErrorOnNode(labelNode, Diagnostics.Duplicate_label_0, labelText);
					break;
				}
				current = current.Parent;
			}
		}
		if ((labelNode.Flags & NodeFlagsUnreachable) != 0 && c.compilerOptions.AllowUnusedLabels != TSTrue) {
			c.errorOrSuggestion(c.compilerOptions.AllowUnusedLabels == TSFalse, labelNode, Diagnostics.Unused_label);
		}
		c.checkSourceElement(labeledStatement.Statement);
	}

	static function checkThrowStatement(c:Checker, node:Node):Void {
		final throwExpr = node.Expression();
		if (!c.checkGrammarStatementInAmbientContext(node)) {
			if (Ast.IsIdentifier(throwExpr) && throwExpr.Text().length == 0) {
				c.grammarErrorAtPos(node, throwExpr.Pos(), 0 /*length*/, Diagnostics.Line_break_not_permitted_here);
			}
		}
		c.checkExpression(throwExpr);
	}

	static function checkTryStatement(c:Checker, node:Node):Void {
		c.checkGrammarStatementInAmbientContext(node);
		final data = node.AsTryStatement();
		c.checkBlock(data.TryBlock);
		if (data.CatchClause != null) {
			c.checkCatchClause(data.CatchClause);
		}
		if (data.FinallyBlock != null) {
			c.checkBlock(data.FinallyBlock);
		}
	}

	static function checkCatchClause(c:Checker, node:Node):Void {
		final declaration = node.AsCatchClause().VariableDeclaration;
		if (declaration != null) {
			c.checkVariableLikeDeclaration(declaration);
			final typeNode = declaration.Type();
			if (typeNode != null) {
				final t = c.getTypeFromTypeNode(typeNode);
				if (t != null && (t.flags & TypeFlagsAnyOrUnknown) == 0) {
					c.grammarErrorOnFirstToken(typeNode, Diagnostics.Catch_clause_variable_type_annotation_must_be_any_or_unknown_if_specified);
				}
			} else if (declaration.Initializer() != null) {
				c.grammarErrorOnFirstToken(declaration.Initializer(), Diagnostics.Catch_clause_variable_cannot_have_an_initializer);
			} else {
				final blockLocals = node.AsCatchClause().Block.Locals();
				if (blockLocals != null) {
					final locals = node.Locals();
					if (locals != null) {
						for (caughtName in locals.keys()) {
							final blockLocal = blockLocals.get(caughtName);
							if (blockLocal != null && blockLocal.ValueDeclaration != null && (blockLocal.Flags & SymbolFlagsBlockScopedVariable) != 0) {
								c.grammarErrorOnNode(blockLocal.ValueDeclaration, Diagnostics.Cannot_redeclare_identifier_0_in_catch_clause, caughtName);
							}
						}
					}
				}
			}
		}
		c.checkBlock(node.AsCatchClause().Block);
	}

	static function checkBindingElement(c:Checker, node:Node):Void {
		c.checkGrammarBindingElement(node.AsBindingElement());
		c.checkVariableLikeDeclaration(node);
	}

	static function checkClassDeclaration(c:Checker, node:Node):Void {
		final firstDecorator = Core.Find(node.ModifierNodes(), Ast.IsDecorator);
		if (c.legacyDecorators && firstDecorator != null && Core.Some(node.Members(), function(p:Node):Bool {
			return Ast.HasStaticModifier(p) && Ast.IsPrivateIdentifierClassElementDeclaration(p);
		})) {
			c.grammarErrorOnNode(firstDecorator,
				Diagnostics.Class_decorators_can_t_be_used_with_static_private_identifier_Consider_removing_the_experimental_decorator);
		}
		if (node.Name() == null && !Ast.HasSyntacticModifier(node, ModifierFlagsDefault)) {
			c.grammarErrorOnFirstToken(node, Diagnostics.A_class_declaration_without_the_default_modifier_must_have_a_name);
		}
		c.checkClassLikeDeclaration(node);
		c.checkSourceElements(node.Members());
		c.registerForUnusedIdentifiersCheck(node);
	}

	static function checkClassLikeDeclaration(c:Checker, node:Node):Void {
		c.checkGrammarClassLikeDeclaration(node);
		c.checkDecorators(node);
		c.checkCollisionsForDeclarationName(node, node.Name());
		c.checkTypeParameters(node.TypeParameters());
		c.checkExportsOnMergedDeclarations(node);
		final symbol = c.getSymbolOfDeclaration(node);
		final classType = c.getDeclaredTypeOfSymbol(symbol);
		final classTypeData = classType.AsInterfaceType();
		final typeWithThis = c.getTypeWithThisArgument(classType, null, false);
		final staticType = c.getTypeOfSymbol(symbol);
		c.checkTypeParameterListsIdentical(symbol);
		c.checkFunctionOrConstructorSymbol(symbol);
		c.checkObjectTypeForDuplicateDeclarations(node, true /*checkPrivateNames*/);

		// Only check for reserved static identifiers on non-ambient context.
		final nodeInAmbientContext = (node.Flags & NodeFlagsAmbient) != 0;
		if (!nodeInAmbientContext) {
			c.checkClassForStaticPropertyNameConflicts(node);
		}

		final baseTypeNode = Ast.GetExtendsHeritageClauseElement(node);
		if (baseTypeNode != null) {
			c.checkSourceElements(baseTypeNode.TypeArguments());
			final baseTypes = c.getBaseTypes(classType);
			if (Core.len(baseTypes) != 0) {
				final baseType = baseTypes[0];
				final baseConstructorType = c.getBaseConstructorTypeOfClass(classType);
				final staticBaseType = c.getApparentType(baseConstructorType);
				c.checkBaseTypeAccessibility(staticBaseType, baseTypeNode);
				c.checkSourceElement(baseTypeNode.Expression());
				if (Core.len(baseTypeNode.TypeArguments()) != 0) {
					c.checkSourceElements(baseTypeNode.TypeArguments());
					final constructors = c.getConstructorsForTypeArguments(staticBaseType, baseTypeNode.TypeArguments(), baseTypeNode);
					if (constructors != null) {
						for (constructor in constructors) {
							if (!c.checkTypeArgumentConstraints(baseTypeNode, constructor.typeParameters)) {
								break;
							}
						}
					}
				}
				final baseWithThis = c.getTypeWithThisArgument(baseType, classTypeData.thisType, false);
				if (!c.checkTypeAssignableTo(typeWithThis, baseWithThis, null, null)) {
					c.issueMemberSpecificError(node, typeWithThis, baseWithThis, Diagnostics.Class_0_incorrectly_extends_base_class_1);
				} else {
					// Report static side error only when instance type is assignable
					c.checkTypeAssignableTo(staticType, c.getTypeWithoutSignatures(staticBaseType), Core.OrElse(node.Name(), node),
						Diagnostics.Class_static_side_0_incorrectly_extends_base_class_static_side_1);
				}
				if ((baseConstructorType.flags & TypeFlagsTypeVariable) != 0) {
					if (!c.isMixinConstructorType(staticType)) {
						c.error(Core.OrElse(node.Name(), node), Diagnostics.A_mixin_class_must_have_a_constructor_with_a_single_rest_parameter_of_type_any);
					} else {
						final constructSignatures = c.getSignaturesOfType(baseConstructorType, SignatureKindConstruct);
						if (Core.Some(constructSignatures, function(signature:Signature):Bool {
							return (signature.flags & SignatureFlagsAbstract) != 0;
						}) && !Ast.HasSyntacticModifier(node, ModifierFlagsAbstract)) {
							c.error(Core.OrElse(node.Name(), node),
								Diagnostics.A_mixin_class_that_extends_from_a_type_variable_containing_an_abstract_construct_signature_must_also_be_declared_abstract);
						}
					}
				}
				if (!(staticBaseType.symbol != null && (staticBaseType.symbol.Flags & SymbolFlagsClass) != 0)
					&& (baseConstructorType.flags & TypeFlagsTypeVariable) == 0) {
					// When the static base type is a "class-like" constructor function (but not actually a class), we verify
					// that all instantiated base constructor signatures return the same type.
					final constructors = c.getInstantiatedConstructorsForTypeArguments(staticBaseType, baseTypeNode.TypeArguments(), baseTypeNode);
					if (!Core.Every(constructors, function(sig:Signature):Bool {
						return c.isTypeIdenticalTo(c.getReturnTypeOfSignature(sig), baseType);
					})) {
						c.error(baseTypeNode.Expression(), Diagnostics.Base_constructors_must_all_have_the_same_return_type);
					}
				}
				c.checkKindsOfPropertyMemberOverrides(classType, baseType);
			}
		}
		c.checkMembersForOverrideModifier(node, classType, typeWithThis, staticType);
		final implementedTypeNodes = Ast.GetImplementsHeritageClauseElements(node);
		if (implementedTypeNodes != null) {
			for (typeRefNode in implementedTypeNodes) {
				final expr = typeRefNode.Expression();
				if (!Ast.IsEntityNameExpression(expr) || Ast.IsOptionalChain(expr)) {
					c.error(expr, Diagnostics.A_class_can_only_implement_an_identifier_Slashqualified_name_with_optional_type_arguments);
				}
				c.checkTypeReferenceNode(typeRefNode);
				final t = c.getReducedType(c.getTypeFromTypeNode(typeRefNode));
				if (!c.isErrorType(t)) {
					if (c.isValidBaseType(t)) {
						final genericDiag = Core.IfElse(t.symbol != null && (t.symbol.Flags & SymbolFlagsClass) != 0,
							Diagnostics.Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1_and_inherit_its_members_as_a_subclass,
							Diagnostics.Class_0_incorrectly_implements_interface_1);
						final baseWithThis = c.getTypeWithThisArgument(t, classType.AsInterfaceType().thisType, false);
						if (!c.checkTypeAssignableTo(typeWithThis, baseWithThis, null, null)) {
							c.issueMemberSpecificError(node, typeWithThis, baseWithThis, genericDiag);
						}
					} else {
						c.error(typeRefNode,
							Diagnostics.A_class_can_only_implement_an_object_type_or_intersection_of_object_types_with_statically_known_members);
					}
				}
			}
		}
		c.checkIndexConstraints(classType, symbol, false /*isStaticIndex*/);
		c.checkIndexConstraints(staticType, symbol, true /*isStaticIndex*/);
		c.checkClassOrInterfaceForDuplicateIndexSignatures(node);
		c.checkPropertyInitialization(node);
	}

	static function checkClassForStaticPropertyNameConflicts(c:Checker, node:Node):Void {
		if (c.compilerOptions.GetUseDefineForClassFields()) {
			return;
		}
		for (member in node.Members()) {
			final memberNameNode = member.Name();
			final isStaticMember = Ast.IsStatic(member);
			if (isStaticMember && memberNameNode != null) {
				final memberName = c.getEffectivePropertyNameForPropertyNameNode(memberNameNode).value;
				switch (memberName) {
					case "name" | "length" | "caller" | "arguments":
						c.error(memberNameNode, Diagnostics.Static_property_0_conflicts_with_built_in_property_Function_0_of_constructor_function_1,
							memberName, c.symbolToString(c.getSymbolOfDeclaration(node)));
					default:
				}
			}
		}
	}

	// Check that type parameter lists are identical across multiple declarations
	static function checkTypeParameterListsIdentical(c:Checker, symbol:Symbol):Void {
		if (Core.len(symbol.Declarations) == 1) {
			return;
		}
		final links = c.declaredTypeLinks.Get(symbol);
		if (!links.typeParametersChecked) {
			links.typeParametersChecked = true;
			final declarations = c.getClassOrInterfaceDeclarationsOfSymbol(symbol);
			if (Core.len(declarations) <= 1) {
				return;
			}
			final t = c.getDeclaredTypeOfSymbol(symbol);
			if (!c.areTypeParametersIdentical(declarations, t.AsInterfaceType().LocalTypeParameters(), n -> n.TypeParameters())) {
				// Report an error on every conflicting declaration.
				final name = c.symbolToString(symbol);
				for (declaration in declarations) {
					c.error(declaration.Name(), Diagnostics.All_declarations_of_0_must_have_identical_type_parameters, name);
				}
			}
		}
	}

	static function getClassOrInterfaceDeclarationsOfSymbol(c:Checker, symbol:Symbol):Array<Node> {
		return Core.Filter(symbol.Declarations, function(d:Node):Bool {
			return Ast.IsClassDeclaration(d) || Ast.IsInterfaceDeclaration(d);
		});
	}

	static function areTypeParametersIdentical(c:Checker, declarations:Array<Node>, targetParameters:Array<Type>, getTypeParameterDeclarations:(node:Node) -> Array<Node>):Bool {
		final maxTypeArgumentCount = Core.len(targetParameters);
		final minTypeArgumentCount = c.getMinTypeArgumentCount(targetParameters);
		for (declaration in declarations) {
			// If this declaration has too few or too many type parameters, we report an error
			final sourceParameters = getTypeParameterDeclarations(declaration);
			if (Core.len(sourceParameters) < minTypeArgumentCount || Core.len(sourceParameters) > maxTypeArgumentCount) {
				return false;
			}
			if (sourceParameters != null) {
				for (i in 0...sourceParameters.length) {
					final source = sourceParameters[i];
					final target = targetParameters[i];
					// If the type parameter node does not have the same name as the resolved type
					// parameter at this position, we report an error.
					if (source.Name().Text() != target.symbol.Name) {
						return false;
					}
					// If the type parameter node does not have an identical constraintNode as the resolved
					// type parameter at this position, we report an error.
					final constraintNode = source.AsTypeParameterDeclaration().Constraint;
					final targetConstraint = c.getConstraintOfTypeParameter(target);
					// relax check if later interface augmentation has no constraint, it's more broad and is OK to merge with
					// a more constrained interface (this could be generalized to a full hierarchy check, but that's maybe overkill)
					if (constraintNode != null && targetConstraint != null && !c.isTypeIdenticalTo(c.getTypeFromTypeNode(constraintNode), targetConstraint)) {
						return false;
					}
					// If the type parameter node has a default and it is not identical to the default
					// for the type parameter at this position, we report an error.
					final defaultNode = source.AsTypeParameterDeclaration().DefaultType;
					final targetDefault = c.getDefaultFromTypeParameter(target);
					if (defaultNode != null && targetDefault != null && !c.isTypeIdenticalTo(c.getTypeFromTypeNode(defaultNode), targetDefault)) {
						return false;
					}
				}
			}
		}
		return true;
	}

	static function checkBaseTypeAccessibility(c:Checker, t:Type, node:Node):Void {
		final signatures = c.getSignaturesOfType(t, SignatureKindConstruct);
		if (Core.len(signatures) != 0) {
			final declaration = signatures[0].declaration;
			if (declaration != null && Ast.HasModifier(declaration, ModifierFlagsPrivate)) {
				final typeClassDeclaration = Ast.GetClassLikeDeclarationOfSymbol(t.symbol);
				if (!c.isNodeWithinClass(node, typeClassDeclaration)) {
					c.error(node, Diagnostics.Cannot_extend_a_class_0_Class_constructor_is_marked_as_private, c.getFullyQualifiedName(t.symbol, null));
				}
			}
		}
	}

	static function issueMemberSpecificError(c:Checker, node:Node, typeWithThis:Type, baseWithThis:Type, broadDiag:Message):Void {
		// iterate over all implemented properties and issue errors on each one which isn't compatible, rather than the class as a whole, if possible
		var issuedMemberError = false;
		for (member in node.Members()) {
			if (Ast.IsStatic(member)) {
				continue;
			}
			final declaredProp = c.getSymbolOfDeclaration(member);
			if (declaredProp != null && declaredProp.Name != Ast.InternalSymbolNameComputed) {
				final prop = c.getPropertyOfType(typeWithThis, declaredProp.Name);
				final baseProp = c.getPropertyOfType(baseWithThis, declaredProp.Name);
				if (prop != null && baseProp != null) {
					final diags:Array<Diagnostic> = [];
					if (!c.checkTypeAssignableToEx(c.getTypeOfSymbol(prop), c.getTypeOfSymbol(baseProp), Core.OrElse(member.Name(), member), null /*headMessage*/,
						diags)) {
						c.addDiagnostic(Ast.NewDiagnosticChain(diags[0], Diagnostics.Property_0_in_type_1_is_not_assignable_to_the_same_property_in_base_type_2,
							c.symbolToString(declaredProp), c.TypeToString(typeWithThis), c.TypeToString(baseWithThis)));
						issuedMemberError = true;
					}
				}
			}
		}
		if (!issuedMemberError) {
			// check again with diagnostics to generate a less-specific error
			c.checkTypeAssignableTo(typeWithThis, baseWithThis, Core.OrElse(node.Name(), node), broadDiag);
		}
	}

	static function getTypeWithoutSignatures(c:Checker, t:Type):Type {
		if ((t.flags & TypeFlagsObject) != 0) {
			final resolved = c.resolveStructuredTypeMembers(t);
			if (Core.len(resolved.signatures) != 0) {
				final result = c.newObjectType(ObjectFlagsAnonymous, t.symbol);
				result.objectFlags |= ObjectFlagsMembersResolved;
				result.AsObjectType().members = resolved.members;
				result.AsObjectType().properties = resolved.properties;
				return result;
			}
		} else if ((t.flags & TypeFlagsIntersection) != 0) {
			return c.getIntersectionType(Core.Map(t.AsIntersectionType().types, t -> c.getTypeWithoutSignatures(t)));
		}
		return t;
	}

	static function checkKindsOfPropertyMemberOverrides(c:Checker, t:Type, baseType:Type):Void {
		// TypeScript 1.0 spec (April 2014): 8.2.3
		// A derived class inherits all members from its base class it doesn't override.
		// Inheritance means that a derived class implicitly contains all non - overridden members of the base class.
		// Both public and private property members are inherited, but only public property members can be overridden.
		// A property member in a derived class is said to override a property member in a base class
		// when the derived class property member has the same name and kind(instance or static)
		// as the base class property member.
		// The type of an overriding property member must be assignable(section 3.8.4)
		// to the type of the overridden property member, or otherwise a compile - time error occurs.
		// Base class instance member functions can be overridden by derived class instance member functions,
		// but not by other kinds of members.
		// Base class instance member variables and accessors can be overridden by
		// derived class instance member variables and accessors, but not by other kinds of members.
		// NOTE: assignability is checked in checkClassDeclaration
		// PORT: nil map key: Go `map[*ast.Node]MemberInfo` may hold a nil key (derivedClassDecl == nil); kept as
		// parallel arrays with a linear lookup. Go iterates the map in random order; diagnostics are sorted later.
		var notImplementedKeys:Array<Node> = null;
		var notImplementedInfo:Array<MemberInfo> = null;
		for (baseProperty in rangeOf(c.getPropertiesOfType(baseType))) {
			final base = c.getTargetSymbol(baseProperty);
			if ((base.Flags & SymbolFlagsPrototype) != 0) {
				continue;
			}
			final baseSymbol = c.getPropertyOfObjectType(t, base.Name);
			if (baseSymbol == null) {
				continue;
			}
			final derived = c.getTargetSymbol(baseSymbol);
			final baseDeclarationFlags = Checker.getDeclarationModifierFlagsFromSymbol(base);
			// In order to resolve whether the inherited method was overridden in the base class or not,
			// we compare the Symbols obtained. Since getTargetSymbol returns the symbol on the *uninstantiated*
			// type declaration, derived and base resolve to the same symbol even in the case of generic classes.
			if (derived == base) {
				// derived class inherits base without override/redeclaration.
				if ((baseDeclarationFlags & ModifierFlagsAbstract) != 0) {
					// It is an error to inherit an abstract member without implementing it or being declared abstract.
					// If there is no declaration for the derived class (as in the case of class expressions),
					// then the class cannot be declared abstract.
					final derivedClassDecl = Ast.GetClassLikeDeclarationOfSymbol(t.symbol);
					if (derivedClassDecl == null || !Ast.HasSyntacticModifier(derivedClassDecl, ModifierFlagsAbstract)) {
						// Searches other base types for a declaration that would satisfy the inherited abstract member.
						// (The class may have more than one base type via declaration merging with an interface with the
						// same name.)
						var continueBasePropertyCheck = false; // PORT: label
						final otherBaseTypes = c.getBaseTypes(t);
						if (otherBaseTypes != null) {
							for (otherBaseType in otherBaseTypes) {
								if (otherBaseType == baseType) {
									continue;
								}
								final baseSymbol = c.getPropertyOfObjectType(otherBaseType, base.Name);
								if (baseSymbol != null && base != c.getTargetSymbol(baseSymbol)) {
									// Derived property exists elsewhere.
									continueBasePropertyCheck = true;
									break;
								}
							}
						}
						if (continueBasePropertyCheck) {
							continue;
						}
						final baseTypeName = c.TypeToString(baseType);
						final typeName = c.TypeToString(t);
						var index = notImplementedKeys == null ? -1 : notImplementedKeys.indexOf(derivedClassDecl);
						var missedProperties = index >= 0 ? notImplementedInfo[index].missedProperties.copy() : [];
						missedProperties.push(c.symbolToString(baseProperty));
						if (notImplementedKeys == null) {
							notImplementedKeys = [];
							notImplementedInfo = [];
						}
						final info = new MemberInfo();
						info.baseTypeName = baseTypeName;
						info.typeName = typeName;
						info.missedProperties = missedProperties;
						if (index >= 0) {
							notImplementedInfo[index] = info;
						} else {
							notImplementedKeys.push(derivedClassDecl);
							notImplementedInfo.push(info);
						}
					}
				}
			} else {
				// derived overrides base.
				final derivedDeclarationFlags = Checker.getDeclarationModifierFlagsFromSymbol(derived);
				if ((baseDeclarationFlags & ModifierFlagsPrivate) != 0 || (derivedDeclarationFlags & ModifierFlagsPrivate) != 0) {
					// either base or derived property is private - not override, skip it
					continue;
				}
				var errorMessage:Message = null;
				final basePropertyFlags = base.Flags & SymbolFlagsPropertyOrAccessor;
				final derivedPropertyFlags = derived.Flags & SymbolFlagsPropertyOrAccessor;
				if (basePropertyFlags != 0 && derivedPropertyFlags != 0) {
					// property/accessor is overridden with property/accessor
					if ((base.CheckFlags & CheckFlagsMapped) != 0
						|| derived.ValueDeclaration != null && Ast.IsBinaryExpression(derived.ValueDeclaration)
						|| c.arePropertiesAbstractOrInterface(base, baseDeclarationFlags)) {
						// when the base property is abstract or from an interface, base/derived flags don't need to match
						// for intersection properties, this must be true of *any* of the declarations, for others it must be true of *all*
						// same when the derived property is from an assignment
						continue;
					}
					final overriddenInstanceProperty = basePropertyFlags != SymbolFlagsProperty && derivedPropertyFlags == SymbolFlagsProperty;
					final overriddenInstanceAccessor = basePropertyFlags == SymbolFlagsProperty && derivedPropertyFlags != SymbolFlagsProperty;
					if (overriddenInstanceProperty || overriddenInstanceAccessor) {
						final errorMessage = Core.IfElse(overriddenInstanceProperty,
							Diagnostics.X_0_is_defined_as_an_accessor_in_class_1_but_is_overridden_here_in_2_as_an_instance_property,
							Diagnostics.X_0_is_defined_as_a_property_in_class_1_but_is_overridden_here_in_2_as_an_accessor);
						c.error(Core.OrElse(Ast.GetNameOfDeclaration(derived.ValueDeclaration), derived.ValueDeclaration), errorMessage, c.symbolToString(base),
							c.TypeToString(baseType), c.TypeToString(t));
					} else if (c.compilerOptions.GetUseDefineForClassFields()) {
						final uninitialized = Core.Find(derived.Declarations, function(d:Node):Bool {
							return Ast.IsPropertyDeclaration(d) && d.Initializer() == null;
						});
						if (uninitialized != null
							&& (derived.Flags & SymbolFlagsTransient) == 0
							&& (baseDeclarationFlags & ModifierFlagsAbstract) == 0
							&& (derivedDeclarationFlags & ModifierFlagsAbstract) == 0
							&& !Core.Some(derived.Declarations, function(d:Node):Bool {
								return (d.Flags & NodeFlagsAmbient) != 0;
							})) {
							final constructor = Ast.FindConstructorDeclaration(Ast.GetClassLikeDeclarationOfSymbol(t.symbol));
							final propName = uninitialized.Name();
							if (Checker.isExclamationToken(uninitialized.PostfixToken()) || constructor == null || !Ast.IsIdentifier(propName)
								|| !c.strictNullChecks || !c.isPropertyInitializedInConstructor(propName, t, constructor)) {
								final errorMessage = Diagnostics.Property_0_will_overwrite_the_base_property_in_1_If_this_is_intentional_add_an_initializer_Otherwise_add_a_declare_modifier_or_remove_the_redundant_declaration;
								c.error(Core.OrElse(Ast.GetNameOfDeclaration(derived.ValueDeclaration), derived.ValueDeclaration), errorMessage, c.symbolToString(base),
									c.TypeToString(baseType));
							}
						}
					}
					// correct case
					continue;
				} else if (Checker.isPrototypeProperty(base)) {
					if (Checker.isPrototypeProperty(derived) || (derived.Flags & SymbolFlagsProperty) != 0) {
						// method is overridden with method or property -- correct case
						continue;
					} else {
						errorMessage = Diagnostics.Class_0_defines_instance_member_function_1_but_extended_class_2_defines_it_as_instance_member_accessor;
					}
				} else if ((base.Flags & SymbolFlagsAccessor) != 0) {
					errorMessage = Diagnostics.Class_0_defines_instance_member_accessor_1_but_extended_class_2_defines_it_as_instance_member_function;
				} else {
					errorMessage = Diagnostics.Class_0_defines_instance_member_property_1_but_extended_class_2_defines_it_as_instance_member_function;
				}
				c.error(Core.OrElse(Ast.GetNameOfDeclaration(derived.ValueDeclaration), derived.ValueDeclaration), errorMessage, c.TypeToString(baseType),
					c.symbolToString(base), c.TypeToString(t));
			}
		}
		if (notImplementedKeys != null) {
			for (i in 0...notImplementedKeys.length) {
				final errorNode = notImplementedKeys[i];
				final memberInfo = notImplementedInfo[i];
				if (memberInfo.missedProperties.length == 1) {
					final missedProperty = memberInfo.missedProperties[0];
					if (Ast.IsClassExpression(errorNode)) {
						c.error(errorNode, Diagnostics.Non_abstract_class_expression_does_not_implement_inherited_abstract_member_0_from_class_1, missedProperty,
							memberInfo.baseTypeName);
					} else {
						c.error(errorNode, Diagnostics.Non_abstract_class_0_does_not_implement_inherited_abstract_member_1_from_class_2, memberInfo.typeName,
							missedProperty, memberInfo.baseTypeName);
					}
				} else if (memberInfo.missedProperties.length > 5) {
					final missedProperties = Core.Map(memberInfo.missedProperties.slice(0, 4), function(prop:std.String):std.String {
						return "'" + prop + "'";
					}).join(", ");
					final remainingMissedProperties = memberInfo.missedProperties.length - 4;
					if (Ast.IsClassExpression(errorNode)) {
						c.error(errorNode, Diagnostics.Non_abstract_class_expression_is_missing_implementations_for_the_following_members_of_0_Colon_1_and_2_more,
							memberInfo.baseTypeName, missedProperties, remainingMissedProperties);
					} else {
						c.error(errorNode, Diagnostics.Non_abstract_class_0_is_missing_implementations_for_the_following_members_of_1_Colon_2_and_3_more,
							memberInfo.typeName, memberInfo.baseTypeName, missedProperties, remainingMissedProperties);
					}
				} else {
					final missedProperties = Core.Map(memberInfo.missedProperties, function(prop:std.String):std.String {
						return "'" + prop + "'";
					}).join(", ");
					if (Ast.IsClassExpression(errorNode)) {
						c.error(errorNode, Diagnostics.Non_abstract_class_expression_is_missing_implementations_for_the_following_members_of_0_Colon_1,
							memberInfo.baseTypeName, missedProperties);
					} else {
						c.error(errorNode, Diagnostics.Non_abstract_class_0_is_missing_implementations_for_the_following_members_of_1_Colon_2, memberInfo.typeName,
							memberInfo.baseTypeName, missedProperties);
					}
				}
			}
		}
	}

	static function arePropertiesAbstractOrInterface(c:Checker, base:Symbol, baseDeclarationFlags:ModifierFlags):Bool {
		if ((base.CheckFlags & CheckFlagsSynthetic) != 0) {
			return Core.Some(base.Declarations, d -> c.isPropertyAbstractOrInterface(d, baseDeclarationFlags));
		}
		return Core.Every(base.Declarations, d -> c.isPropertyAbstractOrInterface(d, baseDeclarationFlags));
	}

	static function isPropertyAbstractOrInterface(c:Checker, declaration:Node, baseDeclarationFlags:ModifierFlags):Bool {
		return Ast.IsInterfaceDeclaration(declaration.Parent)
			|| (baseDeclarationFlags & ModifierFlagsAbstract) != 0 && (!Ast.IsPropertyDeclaration(declaration) || declaration.Initializer() == null);
	}

	static function checkMembersForOverrideModifier(c:Checker, node:Node, t:Type, typeWithThis:Type, staticType:Type):Void {
		var baseWithThis:Type = null;
		final baseTypeNode = Ast.GetExtendsHeritageClauseElement(node);
		if (baseTypeNode != null) {
			final baseTypes = c.getBaseTypes(t);
			if (Core.len(baseTypes) > 0) {
				baseWithThis = c.getTypeWithThisArgument(Core.FirstOrNil(baseTypes), t.AsInterfaceType().thisType, false);
			}
		}
		final baseStaticType = c.getBaseConstructorTypeOfClass(t);
		final members = node.Members();
		if (members == null) return;
		for (member in members) {
			if (!Ast.HasAmbientModifier(member)) {
				if (Ast.IsConstructorDeclaration(member)) {
					for (param in (member.Parameters() == null ? [] : member.Parameters())) {
						if (Ast.IsParameterPropertyDeclaration(param, member)) {
							c.checkMemberForOverrideModifier(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, param);
						}
					}
				} else {
					c.checkMemberForOverrideModifier(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, member);
				}
			}
		}
	}

	static function checkMemberForOverrideModifier(c:Checker, node:Node, staticType:Type, baseStaticType:Type, baseWithThis:Type, t:Type, typeWithThis:Type, member:Node):Void {
		final isJs = Ast.IsInJSFile(node);
		final memberHasOverrideModifier = Checker.hasOverrideModifier(member);
		if (baseWithThis == null) {
			if (memberHasOverrideModifier) {
				c.error(member,
					Core.IfElse(isJs,
						Diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_its_containing_class_0_does_not_extend_another_class,
						Diagnostics.This_member_cannot_have_an_override_modifier_because_its_containing_class_0_does_not_extend_another_class),
					c.TypeToString(t));
			}
			return;
		}
		final sym = member.Symbol();
		if (memberHasOverrideModifier && sym != null && sym.ValueDeclaration != null && Ast.IsClassElement(member) && member.Name() != null
			&& c.isNonBindableDynamicName(member.Name())) {
			c.error(member,
				Core.IfElse(isJs, Diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_its_name_is_dynamic,
					Diagnostics.This_member_cannot_have_an_override_modifier_because_its_name_is_dynamic));
			return;
		}
		if (!memberHasOverrideModifier && !c.compilerOptions.NoImplicitOverride.IsTrue()) {
			return;
		}
		// Here we have a base class and also an override modifier or no override modifier in noImplicitOverride mode
		final symbol = c.getSymbolOfDeclaration(member);
		if (symbol == null) {
			return;
		}
		final memberIsStatic = Ast.IsStatic(member);
		final thisType = Core.IfElse(memberIsStatic, staticType, typeWithThis);
		final prop = c.getPropertyOfType(thisType, symbol.Name);
		if (prop == null) {
			return;
		}
		final baseType = Core.IfElse(memberIsStatic, baseStaticType, baseWithThis);
		final baseProp = c.getPropertyOfType(baseType, symbol.Name);
		if (baseProp == null && memberHasOverrideModifier) {
			final suggestion = c.getSuggestedSymbolForNonexistentClassMember(Ast.SymbolName(symbol), baseType);
			if (suggestion != null) {
				c.error(member,
					Core.IfElse(isJs,
						Diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_it_is_not_declared_in_the_base_class_0_Did_you_mean_1,
						Diagnostics.This_member_cannot_have_an_override_modifier_because_it_is_not_declared_in_the_base_class_0_Did_you_mean_1),
					c.TypeToString(baseWithThis), c.symbolToString(suggestion));
				return;
			}
			c.error(member,
				Core.IfElse(isJs,
					Diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_it_is_not_declared_in_the_base_class_0,
					Diagnostics.This_member_cannot_have_an_override_modifier_because_it_is_not_declared_in_the_base_class_0),
				c.TypeToString(baseWithThis));
			return;
		}
		if (baseProp != null && Core.len(baseProp.Declarations) != 0 && !memberHasOverrideModifier && c.compilerOptions.NoImplicitOverride.IsTrue()
			&& (node.Flags & NodeFlagsAmbient) == 0) {
			final baseHasAbstract = Core.Some(baseProp.Declarations, Ast.HasAbstractModifier);
			if (!baseHasAbstract) {
				final message = Core.IfElse(Ast.IsParameterDeclaration(member),
					Core.IfElse(isJs,
						Diagnostics.This_parameter_property_must_have_a_JSDoc_comment_with_an_override_tag_because_it_overrides_a_member_in_the_base_class_0,
						Diagnostics.This_parameter_property_must_have_an_override_modifier_because_it_overrides_a_member_in_base_class_0),
					Core.IfElse(isJs,
						Diagnostics.This_member_must_have_a_JSDoc_comment_with_an_override_tag_because_it_overrides_a_member_in_the_base_class_0,
						Diagnostics.This_member_must_have_an_override_modifier_because_it_overrides_a_member_in_the_base_class_0));
				c.error(member, message, c.TypeToString(baseWithThis));
				return;
			}
			if (Ast.HasAbstractModifier(member) && baseHasAbstract) {
				c.error(member,
					Diagnostics.This_member_must_have_an_override_modifier_because_it_overrides_an_abstract_method_that_is_declared_in_the_base_class_0,
					c.TypeToString(baseWithThis));
			}
		}
	}

	static function getSuggestedSymbolForNonexistentClassMember(c:Checker, name:std.String, baseType:Type):Symbol {
		return c.getSpellingSuggestionForName(name, valuesOf(c.getPropertiesOfType(baseType)), SymbolFlagsClassMember);
	}

	static function checkIndexConstraints(c:Checker, t:Type, symbol:Symbol, isStaticIndex:Bool):Void {
		final indexInfos = c.getIndexInfosOfType(t);
		if (Core.len(indexInfos) == 0) {
			return;
		}
		for (prop in rangeOf(c.getPropertiesOfObjectType(t))) {
			if (!(isStaticIndex && (prop.Flags & SymbolFlagsPrototype) != 0)) {
				c.checkIndexConstraintForProperty(t, prop, c.getLiteralTypeFromProperty(prop, TypeFlagsStringOrNumberLiteralOrUnique, true /*includeNonPublic*/),
					c.getNonMissingTypeOfSymbol(prop));
			}
		}
		final typeDeclaration = symbol.ValueDeclaration;
		if (typeDeclaration != null && Ast.IsClassLike(typeDeclaration)) {
			for (member in typeDeclaration.Members()) {
				// Only process instance properties against instance index signatures and static properties against static index signatures
				if (Ast.IsStatic(member) == isStaticIndex && !c.hasBindableName(member)) {
					final symbol = c.getSymbolOfDeclaration(member);
					c.checkIndexConstraintForProperty(t, symbol, c.getTypeOfExpression(member.Name().Expression()), c.getNonMissingTypeOfSymbol(symbol));
				}
			}
		}
		if (indexInfos.length > 1) {
			for (info in indexInfos) {
				c.checkIndexConstraintForIndexSignature(t, info);
			}
		}
	}

	static function checkIndexConstraintForProperty(c:Checker, t:Type, prop:Symbol, propNameType:Type, propType:Type):Void {
		final declaration = prop.ValueDeclaration;
		final name = Ast.GetNameOfDeclaration(declaration);
		if (name != null && Ast.IsPrivateIdentifier(name)) {
			return;
		}
		final indexInfos = c.getApplicableIndexInfos(t, propNameType);
		if (Core.len(indexInfos) == 0) {
			return;
		}
		var interfaceDeclaration:Node = null;
		if ((t.objectFlags & ObjectFlagsInterface) != 0) {
			interfaceDeclaration = Ast.GetDeclarationOfKind(t.symbol, KindInterfaceDeclaration);
		}
		var propDeclaration:Node = null;
		if (declaration != null && Ast.IsBinaryExpression(declaration) || name != null && Ast.IsComputedPropertyName(name)) {
			propDeclaration = declaration;
		}
		var localPropDeclaration:Node = null;
		if (c.getParentOfSymbol(prop) == t.symbol) {
			localPropDeclaration = declaration;
		}
		for (info in indexInfos) {
			var localIndexDeclaration:Node = null;
			if (info.declaration != null && c.getParentOfSymbol(c.getSymbolOfDeclaration(info.declaration)) == t.symbol) {
				localIndexDeclaration = info.declaration;
			}
			// We check only when (a) the property is declared in the containing type, or (b) the applicable index signature is declared
			// in the containing type, or (c) the containing type is an interface and no base interface contains both the property and
			// the index signature (i.e. property and index signature are declared in separate inherited interfaces).
			var errorNode = Core.OrElse(localPropDeclaration, localIndexDeclaration);
			if (errorNode == null && interfaceDeclaration != null && !Core.Some(c.getBaseTypes(t), function(base:Type):Bool {
				return c.getPropertyOfObjectType(base, prop.Name) != null && c.getIndexTypeOfType(base, info.keyType) != null;
			})) {
				errorNode = interfaceDeclaration;
			}
			if (errorNode != null && !c.isTypeAssignableTo(propType, info.valueType)) {
				final diagnostic = Checker.NewDiagnosticForNode(errorNode, Diagnostics.Property_0_of_type_1_is_not_assignable_to_2_index_type_3,
					c.symbolToString(prop), c.TypeToString(propType), c.TypeToString(info.keyType), c.TypeToString(info.valueType));
				if (propDeclaration != null && errorNode != propDeclaration) {
					diagnostic.AddRelatedInfo(Checker.NewDiagnosticForNode(propDeclaration, Diagnostics.X_0_is_declared_here, c.symbolToString(prop)));
				}
				c.addDiagnostic(diagnostic);
			}
		}
	}

	static function checkIndexConstraintForIndexSignature(c:Checker, t:Type, checkInfo:IndexInfo):Void {
		final declaration = checkInfo.declaration;
		final indexInfos = c.getApplicableIndexInfos(t, checkInfo.keyType);
		if (Core.len(indexInfos) == 0) {
			return;
		}
		var interfaceDeclaration:Node = null;
		if ((t.objectFlags & ObjectFlagsInterface) != 0) {
			interfaceDeclaration = Ast.GetDeclarationOfKind(t.symbol, KindInterfaceDeclaration);
		}
		var localCheckDeclaration:Node = null;
		if (declaration != null && c.getParentOfSymbol(c.getSymbolOfDeclaration(declaration)) == t.symbol) {
			localCheckDeclaration = declaration;
		}
		for (info in indexInfos) {
			if (info == checkInfo) {
				continue;
			}
			var localIndexDeclaration:Node = null;
			if (info.declaration != null && c.getParentOfSymbol(c.getSymbolOfDeclaration(info.declaration)) == t.symbol) {
				localIndexDeclaration = info.declaration;
			}
			// We check only when (a) the check index signature is declared in the containing type, or (b) the applicable index
			// signature is declared in the containing type, or (c) the containing type is an interface and no base interface contains
			// both index signatures (i.e. the index signatures are declared in separate inherited interfaces).
			var errorNode = Core.OrElse(localCheckDeclaration, localIndexDeclaration);
			if (errorNode == null && interfaceDeclaration != null && !Core.Some(c.getBaseTypes(t), function(base:Type):Bool {
				return c.getIndexInfoOfType(base, checkInfo.keyType) != null && c.getIndexTypeOfType(base, info.keyType) != null;
			})) {
				errorNode = interfaceDeclaration;
			}
			if (errorNode != null && !c.isTypeAssignableTo(checkInfo.valueType, info.valueType)) {
				c.error(errorNode, Diagnostics.X_0_index_type_1_is_not_assignable_to_2_index_type_3, c.TypeToString(checkInfo.keyType),
					c.TypeToString(checkInfo.valueType), c.TypeToString(info.keyType), c.TypeToString(info.valueType));
			}
		}
	}

	static function checkClassOrInterfaceForDuplicateIndexSignatures(c:Checker, node:Node):Void {
		// Only check the type once
		final links = c.declaredTypeLinks.Get(c.getSymbolOfDeclaration(node));
		if (!links.indexSignaturesChecked) {
			links.indexSignaturesChecked = true;
			c.checkTypeForDuplicateIndexSignatures(node);
		}
	}

	static function checkTypeForDuplicateIndexSignatures(c:Checker, node:Node):Void {
		// TypeScript 1.0 spec (April 2014)
		// 3.7.4: An object type can contain at most one string index signature and one numeric index signature.
		// 8.5: A class declaration can have at most one string index member declaration and one numeric index member declaration
		final indexSymbol = c.getIndexSymbol(c.getSymbolOfDeclaration(node));
		if (indexSymbol == null || Core.len(indexSymbol.Declarations) <= 1) {
			return;
		}
		final indexSignatureMap = new IdentityMap<Type, Array<Node>>();
		for (declaration in indexSymbol.Declarations) {
			if (Ast.IsIndexSignatureDeclaration(declaration)) {
				final parameters = declaration.Parameters();
				if (Core.len(parameters) == 1 && parameters[0].Type() != null) {
					for (t in rangeOf(c.getTypeFromTypeNode(parameters[0].Type()).Distributed())) {
						var list = indexSignatureMap.get(t);
						if (list == null) {
							list = [];
							indexSignatureMap.set(t, list);
						}
						list.push(declaration);
					}
				}
			}
			// Do nothing for late-bound index signatures: allow these to duplicate one another and explicit indexes
		}
		for (t => declarations in indexSignatureMap) {
			if (declarations.length > 1) {
				for (declaration in declarations) {
					c.error(declaration, Diagnostics.Duplicate_index_signature_for_type_0, c.TypeToString(t));
				}
			}
		}
	}

	static function checkPropertyInitialization(c:Checker, node:Node):Void {
		if (!c.strictNullChecks || !c.strictPropertyInitialization || (node.Flags & NodeFlagsAmbient) != 0) {
			return;
		}
		final constructor = Ast.FindConstructorDeclaration(node);
		final members = node.Members();
		if (members == null) return;
		for (member in members) {
			if ((member.ModifierFlags() & ModifierFlagsAmbient) != 0) {
				continue;
			}
			if (!Ast.IsStatic(member) && c.isPropertyWithoutInitializer(member)) {
				final propName = member.Name();
				if (Ast.IsIdentifier(propName) || Ast.IsPrivateIdentifier(propName) || Ast.IsComputedPropertyName(propName)) {
					final t = c.getTypeOfSymbol(c.getSymbolOfDeclaration(member));
					if (!((t.flags & TypeFlagsAnyOrUnknown) != 0 || c.containsUndefinedType(t))) {
						if (constructor == null || !c.isPropertyInitializedInConstructor(propName, t, constructor)) {
							c.error(member.Name(), Diagnostics.Property_0_has_no_initializer_and_is_not_definitely_assigned_in_the_constructor,
								Scanner.DeclarationNameToString(propName));
						}
					}
				}
			}
		}
	}

	static function isPropertyWithoutInitializer(c:Checker, node:Node):Bool {
		return Ast.IsPropertyDeclaration(node) && !Ast.HasAbstractModifier(node) && !Checker.isExclamationToken(node.PostfixToken())
			&& node.Initializer() == null;
	}

	static function isPropertyInitializedInStaticBlocks(c:Checker, propName:Node, propType:Type, staticBlocks:Array<Node>, startPos:Int, endPos:Int):Bool {
		for (staticBlock in rangeOf(staticBlocks)) {
			// static block must be within the provided range as they are evaluated in document order (unlike constructors)
			if (staticBlock.Pos() >= startPos && staticBlock.Pos() <= endPos) {
				final reference = c.factory.NewPropertyAccessExpression(c.factory.NewKeywordExpression(KindThisKeyword), null, propName, NodeFlagsNone);
				reference.Expression().Parent = reference;
				reference.Parent = staticBlock;
				reference.FlowNodeData().FlowNode = staticBlock.AsClassStaticBlockDeclaration().ReturnFlowNode;
				final flowType = c.getFlowTypeOfReferenceEx(reference, propType, c.getOptionalType(propType, false), null, null);
				if (!c.containsUndefinedType(flowType)) {
					return true;
				}
			}
		}
		return false;
	}

	static function isPropertyInitializedInConstructor(c:Checker, propName:Node, propType:Type, constructor:Node):Bool {
		var reference:Node = null;
		if (Ast.IsComputedPropertyName(propName)) {
			reference = c.factory.NewElementAccessExpression(c.factory.NewKeywordExpression(KindThisKeyword), null, propName.Expression(), NodeFlagsNone);
		} else {
			reference = c.factory.NewPropertyAccessExpression(c.factory.NewKeywordExpression(KindThisKeyword), null, propName, NodeFlagsNone);
		}
		reference.Expression().Parent = reference;
		reference.Parent = constructor;
		reference.FlowNodeData().FlowNode = constructor.AsConstructorDeclaration().ReturnFlowNode;
		final flowType = c.getFlowTypeOfReferenceEx(reference, propType, c.getOptionalType(propType, false), null, null);
		return !c.containsUndefinedType(flowType);
	}

	static function checkInterfaceDeclaration(c:Checker, node:Node):Void {
		if (!c.checkGrammarModifiers(node)) {
			c.checkGrammarInterfaceDeclaration(node.AsInterfaceDeclaration());
		}
		if (!c.containerAllowsBlockScopedVariable(node.Parent)) {
			c.grammarErrorOnNode(node, Diagnostics.X_0_declarations_can_only_be_declared_inside_a_block, "interface");
		}
		c.checkTypeParameters(node.TypeParameters());
		c.checkTypeNameIsReserved(node.Name(), Diagnostics.Interface_name_cannot_be_0);
		c.checkExportsOnMergedDeclarations(node);
		final symbol = c.getSymbolOfDeclaration(node);
		c.checkTypeParameterListsIdentical(symbol);
		// Only check this symbol once
		final links = c.declaredTypeLinks.Get(symbol);
		if (!links.interfaceChecked) {
			links.interfaceChecked = true;
			final t = c.getDeclaredTypeOfSymbol(symbol);
			final typeWithThis = c.getTypeWithThisArgument(t, null, false);
			// run subsequent checks only if first set succeeded
			if (c.checkInheritedPropertiesAreIdentical(t, node.Name())) {
				for (baseType in rangeOf(c.getBaseTypes(t))) {
					c.checkTypeAssignableTo(typeWithThis, c.getTypeWithThisArgument(baseType, t.AsInterfaceType().thisType, false), node.Name(),
						Diagnostics.Interface_0_incorrectly_extends_interface_1);
				}
				c.checkIndexConstraints(t, symbol /*isStaticIndex*/, false);
			}
		}
		c.checkObjectTypeForDuplicateDeclarations(node, false /*checkPrivateNames*/);
		for (heritageElement in rangeOf(Ast.GetExtendsHeritageClauseElements(node))) {
			final expr = heritageElement.Expression();
			if (!Ast.IsEntityNameExpression(expr) || Ast.IsOptionalChain(expr)) {
				c.error(expr, Diagnostics.An_interface_can_only_extend_an_identifier_Slashqualified_name_with_optional_type_arguments);
			}
			c.checkTypeReferenceNode(heritageElement);
		}
		c.checkSourceElements(node.Members());
		c.checkClassOrInterfaceForDuplicateIndexSignatures(node);
		c.registerForUnusedIdentifiersCheck(node);
	}

	static function checkInheritedPropertiesAreIdentical(c:Checker, t:Type, typeNode:Node):Bool {
		final baseTypes = c.getBaseTypes(t);
		if (Core.len(baseTypes) < 2) {
			return true;
		}
		final seen = new StringMap<InheritanceInfo>();
		final declaredMembers = c.resolveDeclaredMembers(t).declaredMembers;
		if (declaredMembers != null) {
			for (id => p in declaredMembers) {
				if (c.isNamedMember(p, id)) {
					final info = new InheritanceInfo();
					info.prop = p;
					info.containingType = t;
					seen.set(p.Name, info);
				}
			}
		}
		var identical = true;
		for (base in baseTypes) {
			final properties = c.getPropertiesOfType(c.getTypeWithThisArgument(base, t.AsInterfaceType().thisType, false));
			for (prop in rangeOf(properties)) {
				final existing = seen.get(prop.Name);
				if (existing == null) {
					final info = new InheritanceInfo();
					info.prop = prop;
					info.containingType = base;
					seen.set(prop.Name, info);
				} else {
					final isInheritedProperty = existing.containingType != t;
					if (isInheritedProperty && !c.isPropertyIdenticalTo(existing.prop, prop)) {
						identical = false;
						final typeName1 = c.TypeToString(existing.containingType);
						final typeName2 = c.TypeToString(base);
						final errorInfo = Checker.NewDiagnosticForNode(typeNode, Diagnostics.Named_property_0_of_types_1_and_2_are_not_identical,
							c.symbolToString(prop), typeName1, typeName2);
						c.addDiagnostic(Ast.NewDiagnosticChain(errorInfo, Diagnostics.Interface_0_cannot_simultaneously_extend_types_1_and_2, c.TypeToString(t),
							typeName1, typeName2));
					}
				}
			}
		}
		return identical;
	}

	static function isPropertyIdenticalTo(c:Checker, sourceProp:Symbol, targetProp:Symbol):Bool {
		return c.compareProperties(sourceProp, targetProp, (s, t) -> c.compareTypesIdentical(s, t)) != TernaryFalse;
	}

	static function checkEnumDeclaration(c:Checker, node:Node):Void {
		c.checkGrammarModifiers(node);
		c.checkCollisionsForDeclarationName(node, node.Name());
		c.checkExportsOnMergedDeclarations(node);
		c.checkSourceElements(node.Members());

		if (c.shouldCheckErasableSyntax(node) && (node.Flags & NodeFlagsAmbient) == 0) {
			c.error(node, Diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled);
		}

		c.computeEnumMemberValues(node);
		// Spec 2014 - Section 9.3:
		// It isn't possible for one enum declaration to continue the automatic numbering sequence of another,
		// and when an enum type has multiple declarations, only one declaration is permitted to omit a value
		// for the first member.
		//
		// Only perform this check once per symbol
		final enumSymbol = c.getSymbolOfDeclaration(node);
		final links = c.declaredTypeLinks.Get(enumSymbol);
		if (!links.enumChecked) {
			links.enumChecked = true;
			if (Core.len(enumSymbol.Declarations) > 1) {
				final enumIsConst = Ast.IsEnumConst(node);
				// check that const is placed\omitted on all enum declarations
				for (decl in enumSymbol.Declarations) {
					if (Ast.IsEnumDeclaration(decl) && Ast.IsEnumConst(decl) != enumIsConst) {
						c.error(Ast.GetNameOfDeclaration(decl), Diagnostics.Enum_declarations_must_all_be_const_or_non_const);
					}
				}
			}
			var seenEnumMissingInitialInitializer = false;
			for (declaration in rangeOf(enumSymbol.Declarations)) {
				// return true if we hit a violation of the rule, false otherwise
				if (declaration.Kind != KindEnumDeclaration) {
					continue;
				}
				final members = declaration.Members();
				if (Core.len(members) == 0) {
					continue;
				}
				final firstEnumMember = members[0];
				if (firstEnumMember.Initializer() == null) {
					if (seenEnumMissingInitialInitializer) {
						c.error(firstEnumMember.Name(),
							Diagnostics.In_an_enum_with_multiple_declarations_only_one_declaration_can_omit_an_initializer_for_its_first_enum_element);
					} else {
						seenEnumMissingInitialInitializer = true;
					}
				}
			}
		}
	}

	static function checkEnumMember(c:Checker, node:Node):Void {
		if (Ast.IsPrivateIdentifier(node.Name())) {
			c.error(node, Diagnostics.An_enum_member_cannot_be_named_with_a_private_identifier);
		}
		if (node.Initializer() != null) {
			c.checkExpression(node.Initializer());
		}
	}

	static function checkModuleDeclaration(c:Checker, node:Node):Void {
		final body = node.Body();
		if (body != null) {
			c.checkSourceElement(body);
			if (!Ast.IsGlobalScopeAugmentation(node)) {
				c.registerForUnusedIdentifiersCheck(node);
			}
		}
		final isGlobalAugmentation = Ast.IsGlobalScopeAugmentation(node);
		final inAmbientContext = (node.Flags & NodeFlagsAmbient) != 0;
		if (isGlobalAugmentation && !inAmbientContext) {
			c.error(node.Name(), Diagnostics.Augmentations_for_the_global_scope_should_have_declare_modifier_unless_they_appear_in_already_ambient_context);
		}
		final isAmbientExternalModule = Ast.IsAmbientModule(node);
		final contextErrorMessage = Core.IfElse(isAmbientExternalModule,
			Diagnostics.An_ambient_module_declaration_is_only_allowed_at_the_top_level_in_a_file,
			Diagnostics.A_namespace_declaration_is_only_allowed_at_the_top_level_of_a_namespace_or_module);
		if (c.checkGrammarModuleElementContext(node, contextErrorMessage)) {
			// If we hit a module declaration in an illegal context, just bail out to avoid cascading errors.
			return;
		}
		if (!c.checkGrammarModifiers(node)) {
			if (!inAmbientContext && Ast.IsStringLiteral(node.Name())) {
				c.grammarErrorOnNode(node.Name(), Diagnostics.Only_ambient_modules_can_use_quoted_names);
			}
		}
		if (Ast.IsIdentifier(node.Name())) {
			c.checkCollisionsForDeclarationName(node, node.Name());
			if (node.AsModuleDeclaration().Keyword == KindModuleKeyword) {
				c.error(node.Name(),
					Diagnostics.A_namespace_declaration_should_not_be_declared_using_the_module_keyword_Please_use_the_namespace_keyword_instead);
			}
		}
		c.checkExportsOnMergedDeclarations(node);
		final symbol = c.getSymbolOfDeclaration(node);
		// The following checks only apply on a non-ambient instantiated module declaration.
		if ((symbol.Flags & SymbolFlagsValueModule) != 0 && !inAmbientContext
			&& Checker.isInstantiatedModule(node, c.compilerOptions.ShouldPreserveConstEnums())) {
			if (c.shouldCheckErasableSyntax(node)) {
				c.error(node, Diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled);
			}
			if (c.compilerOptions.GetIsolatedModules() && Ast.GetSourceFileOfNode(node).ExternalModuleIndicator == null) {
				// This could be loosened a little if needed. The only problem we are trying to avoid is unqualified
				// references to namespace members declared in other files. But use of namespaces is discouraged anyway,
				// so for now we will just not allow them in scripts, which is the only place they can merge cross-file.
				c.error(node.Name(),
					Diagnostics.Namespaces_are_not_allowed_in_global_script_files_when_0_is_enabled_If_this_file_is_not_intended_to_be_a_global_script_set_moduleDetection_to_force_or_add_an_empty_export_statement,
					c.getIsolatedModulesLikeFlagName());
			}
			if (Core.len(symbol.Declarations) > 1) {
				final firstNonAmbientClassOrFunc = Checker.getFirstNonAmbientClassOrFunctionDeclaration(symbol);
				if (firstNonAmbientClassOrFunc != null) {
					if (Ast.GetSourceFileOfNode(node) != Ast.GetSourceFileOfNode(firstNonAmbientClassOrFunc)) {
						c.error(node.Name(),
							Diagnostics.A_namespace_declaration_cannot_be_in_a_different_file_from_a_class_or_function_with_which_it_is_merged);
					} else if (node.Pos() < firstNonAmbientClassOrFunc.Pos()) {
						c.error(node.Name(), Diagnostics.A_namespace_declaration_cannot_be_located_prior_to_a_class_or_function_with_which_it_is_merged);
					}
				}
			}
			if (c.compilerOptions.VerbatimModuleSyntax.IsTrue() && Ast.IsSourceFile(node.Parent) && (node.ModifierFlags() & ModifierFlagsExport) != 0
				&& c.program.GetEmitModuleFormatOfFile(hasFileName(node.Parent.AsSourceFile())) == ModuleKindCommonJS) {
				final exportModifier = Core.Find(node.ModifierNodes(), m -> m.Kind == KindExportKeyword);
				c.error(exportModifier,
					Diagnostics.A_top_level_export_modifier_cannot_be_used_on_value_declarations_in_a_CommonJS_module_when_verbatimModuleSyntax_is_enabled);
			}
		}
		if (isAmbientExternalModule) {
			if (Ast.IsExternalModuleAugmentation(node)) {
				// body of the augmentation should be checked for consistency only if augmentation was applied to its target (either global scope or module)
				// otherwise we'll be swamped in cascading errors.
				// We can detect if augmentation was applied using following rules:
				// - augmentation for a global scope is always applied
				// - augmentation for some external module is applied if symbol for augmentation is merged (it was combined with target module).
				final checkBody = isGlobalAugmentation || (c.getSymbolOfDeclaration(node).Flags & SymbolFlagsTransient) != 0;
				if (checkBody && node.Body() != null) {
					for (statement in rangeOf(node.Body().Statements())) {
						c.checkModuleAugmentationElement(statement);
					}
				}
			} else if (Ast.IsGlobalSourceFile(node.Parent)) {
				if (isGlobalAugmentation) {
					c.error(node.Name(),
						Diagnostics.Augmentations_for_the_global_scope_can_only_be_directly_nested_in_external_modules_or_ambient_module_declarations);
				} else if (Tspath.IsExternalModuleNameRelative(node.Name().Text())) {
					c.error(node.Name(), Diagnostics.Ambient_module_declaration_cannot_specify_relative_module_name);
				}
			} else {
				if (isGlobalAugmentation) {
					c.error(node.Name(),
						Diagnostics.Augmentations_for_the_global_scope_can_only_be_directly_nested_in_external_modules_or_ambient_module_declarations);
				} else {
					// Node is not an augmentation and is not located on the script level.
					// This means that this is declaration of ambient module that is located in other module or namespace which is prohibited.
					c.error(node.Name(), Diagnostics.Ambient_modules_cannot_be_nested_in_other_modules_or_namespaces);
				}
			}
		}
	}

	static function getIsolatedModulesLikeFlagName(c:Checker):std.String {
		return Core.IfElse(c.compilerOptions.VerbatimModuleSyntax.IsTrue(), "verbatimModuleSyntax", "isolatedModules");
	}

	static function checkModuleAugmentationElement(c:Checker, node:Node):Void {
		switch (node.Kind) {
			case KindVariableStatement:
				// error each individual name in variable statement instead of marking the entire variable statement
				for (decl in node.AsVariableStatement().DeclarationList.AsVariableDeclarationList().Declarations.Nodes) {
					c.checkModuleAugmentationElement(decl);
				}
			case KindExportAssignment | KindExportDeclaration:
				c.grammarErrorOnFirstToken(node, Diagnostics.Exports_and_export_assignments_are_not_permitted_in_module_augmentations);
			case KindImportEqualsDeclaration:
				// import a = e.x; in module augmentation is ok, but not import a = require('fs)
				// PORT: Go `break` out of the switch, else `fallthrough` into the import case.
				if (!Ast.IsInternalModuleImportEqualsDeclaration(node)) {
					c.grammarErrorOnFirstToken(node,
						Diagnostics.Imports_are_not_permitted_in_module_augmentations_Consider_moving_them_to_the_enclosing_external_module);
				}
			case KindImportDeclaration | KindJSImportDeclaration:
				c.grammarErrorOnFirstToken(node,
					Diagnostics.Imports_are_not_permitted_in_module_augmentations_Consider_moving_them_to_the_enclosing_external_module);
			case KindBindingElement | KindVariableDeclaration:
				final name = node.Name();
				if (Ast.IsBindingPattern(name)) {
					for (el in name.Elements()) {
						// mark individual names in binding pattern
						c.checkModuleAugmentationElement(el);
					}
				}
			default:
		}
	}

	static function checkImportDeclaration(c:Checker, node:ImportDeclarationNode):Void {
		// Grammar checking
		var diagnostic:Message = null;
		if (Ast.IsInJSFile(node)) {
			diagnostic = Diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module;
		} else {
			diagnostic = Diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module;
		}
		if (c.checkGrammarModuleElementContext(node, diagnostic)) {
			// If we hit an import declaration in an illegal context, just bail out to avoid cascading errors.
			return;
		}
		if (!c.checkGrammarModifiers(node) && node.Modifiers() != null) {
			c.grammarErrorOnFirstToken(node, Diagnostics.An_import_declaration_cannot_have_modifiers);
		}
		if (c.checkExternalImportOrExportDeclaration(node)) {
			var resolvedModule:Symbol = null;
			final importClause = node.ImportClause();
			final moduleSpecifier = node.ModuleSpecifier();
			if (importClause != null && !c.checkGrammarImportClause(importClause.AsImportClause())) {
				if (importClause.Name() != null) {
					c.checkImportBinding(importClause);
				}
				var needsImportStar = false;
				final namedBindings = importClause.AsImportClause().NamedBindings;
				if (namedBindings != null) {
					if (Ast.IsNamespaceImport(namedBindings)) {
						c.checkImportBinding(namedBindings);
						if (c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
							// import * as ns from "foo";
							needsImportStar = true;
							c.checkExternalEmitHelpers(node, ExternalEmitHelpersImportStar);
						}
					} else {
						resolvedModule = c.resolveExternalModuleName(node, node.ModuleSpecifier(), false);
						if (resolvedModule != null) {
							for (binding in namedBindings.Elements()) {
								c.checkImportBinding(binding);
							}
						}
					}
				}
				if (importClause.Name() != null && !needsImportStar
					&& c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
					// import d from "foo";
					c.checkExternalEmitHelpers(node, ExternalEmitHelpersImportDefault);
				}

				if (!importClause.IsTypeOnly()
					&& (ModuleKindNode18 : Int) <= (c.moduleKind : Int) && (c.moduleKind : Int) <= (ModuleKindNodeNext : Int)
					&& c.isOnlyImportableAsDefault(moduleSpecifier, resolvedModule)
					&& !Checker.hasTypeJsonImportAttribute(node)) {
					c.error(moduleSpecifier,
						Diagnostics.Importing_a_JSON_file_into_an_ECMAScript_module_requires_a_type_Colon_json_import_attribute_when_module_is_set_to_0,
						c.moduleKind.String());
				}
			} else if (c.compilerOptions.NoUncheckedSideEffectImports.IsTrueOrUnknown() && importClause == null) {
				final ignoreErrors = c.compilerOptions.NoCheck.IsTrue();
				var errorMessage:Message = null;
				if (!ignoreErrors) {
					errorMessage = Diagnostics.Cannot_find_module_or_type_declarations_for_side_effect_import_of_0;
				}
				c.resolveExternalModuleNameWorker(node, moduleSpecifier, errorMessage, ignoreErrors, false /*isForAugmentation*/);
			}
		}
		c.checkImportAttributes(node);
	}

	static function checkExternalImportOrExportDeclaration(c:Checker, node:Node):Bool {
		final moduleName = Ast.GetExternalModuleName(node);
		if (moduleName == null || Ast.NodeIsMissing(moduleName)) {
			// Should be a parse error.
			return false;
		}
		if (!Ast.IsStringLiteral(moduleName)) {
			c.error(moduleName, Diagnostics.String_literal_expected);
			return false;
		}
		final inAmbientExternalModule = Ast.IsModuleBlock(node.Parent) && Ast.IsAmbientModule(node.Parent.Parent);
		if (!Ast.IsSourceFile(node.Parent) && !inAmbientExternalModule) {
			c.error(moduleName,
				Core.IfElse(Ast.IsExportDeclaration(node), Diagnostics.Export_declarations_are_not_permitted_in_a_namespace,
					Diagnostics.Import_declarations_in_a_namespace_cannot_reference_a_module));
			return false;
		}
		if (inAmbientExternalModule && Tspath.IsExternalModuleNameRelative(moduleName.Text())) {
			// we have already reported errors on top level imports/exports in external module augmentations in checkModuleDeclaration
			// no need to do this again.
			if (!Checker.isTopLevelInExternalModuleAugmentation(node)) {
				// TypeScript 1.0 spec (April 2013): 12.1.6
				// An ExternalImportDeclaration in an AmbientExternalModuleDeclaration may reference
				// other external modules only through top - level external module names.
				// Relative external module names are not permitted.
				c.error(node, Diagnostics.Import_or_export_declaration_in_an_ambient_module_declaration_cannot_reference_module_through_relative_module_name);
				return false;
			}
		}
		if (!Ast.IsImportEqualsDeclaration(node)) {
			final attributes = Ast.GetImportAttributes(node);
			if (attributes != null) {
				var hasError = false;
				for (attr in attributes.AsImportAttributes().Attributes.Nodes) {
					if (!Ast.IsStringLiteral(attr.AsImportAttribute().Value)) {
						hasError = true;
						c.error(attr.AsImportAttribute().Value, Diagnostics.Import_attribute_values_must_be_string_literal_expressions);
					}
				}
				return !hasError;
			}
		}
		return true;
	}

	static function checkImportBinding(c:Checker, node:Node):Void {
		c.checkCollisionsForDeclarationName(node, node.Name());
		c.checkAliasSymbol(node);
		if (Ast.IsImportSpecifier(node)) {
			c.checkModuleExportName(node.PropertyName(), true /*allowStringLiteral*/);
			if (Ast.ModuleExportNameIsDefault(node.PropertyNameOrName())
				&& c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
				c.checkExternalEmitHelpers(node, ExternalEmitHelpersImportDefault);
			}
		}
	}

	static function checkModuleExportName(c:Checker, name:Node, allowStringLiteral:Bool):Void {
		if (name == null || name.Kind != KindStringLiteral) {
			return;
		}
		if (!allowStringLiteral) {
			c.grammarErrorOnNode(name, Diagnostics.Identifier_expected);
		} else if (c.moduleKind == ModuleKindES2015 || c.moduleKind == ModuleKindES2020) {
			if (!Ast.GetSourceFileOfNode(name).IsDeclarationFile) {
				c.grammarErrorOnNode(name,
					Diagnostics.String_literal_import_and_export_names_are_not_supported_when_the_module_flag_is_set_to_es2015_or_es2020);
			}
		}
	}

	static function checkImportAttributes(c:Checker, declaration:Node):Void {
		final node = Ast.GetImportAttributes(declaration);
		if (node == null) {
			return;
		}
		final importAttributesType = c.getGlobalImportAttributesTypeChecked();
		if (importAttributesType != c.emptyObjectType) {
			c.checkTypeAssignableTo(c.getTypeFromImportAttributes(node), c.getNullableType(importAttributesType, TypeFlagsUndefined), node, null);
		}
		final isTypeOnly = Ast.IsExclusivelyTypeOnlyImportOrExport(declaration);
		final override_ = c.getResolutionModeOverride(node.AsImportAttributes(), isTypeOnly);
		if (isTypeOnly && override_ != Core.ResolutionModeNone) {
			return; // Other grammar checks do not apply to type-only imports with resolution mode attributes
		}

		if (!c.moduleKind.SupportsImportAttributes()) {
			c.grammarErrorOnNode(node,
				Diagnostics.Import_attributes_are_only_supported_when_the_module_option_is_set_to_esnext_node18_node20_nodenext_or_preserve);
			return;
		}

		final moduleSpecifier = Checker.getModuleSpecifierFromNode(declaration);
		if (moduleSpecifier != null) {
			if (c.getEmitSyntaxForModuleSpecifierExpression(moduleSpecifier) == ModuleKindCommonJS) {
				c.grammarErrorOnNode(node, Diagnostics.Import_attributes_are_not_allowed_on_statements_that_compile_to_CommonJS_require_calls);
				return;
			}
		}

		if (isTypeOnly) {
			c.grammarErrorOnNode(node, Diagnostics.Import_attributes_cannot_be_used_with_type_only_imports_or_exports);
			return;
		}
		if (override_ != Core.ResolutionModeNone) {
			c.grammarErrorOnNode(node, Diagnostics.X_resolution_mode_can_only_be_set_for_type_only_imports);
		}
	}

	static function getTypeFromImportAttributes(c:Checker, node:Node):Type {
		final links = c.typeNodeLinks.Get(node);
		if (links.resolvedType == null) {
			final symbol = c.newSymbol(SymbolFlagsObjectLiteral, Ast.InternalSymbolNameImportAttributes);
			final members:SymbolTable = new StringMap<Symbol>();
			for (attr in node.AsImportAttributes().Attributes.Nodes) {
				final member = c.newSymbol(SymbolFlagsProperty, attr.Name().Text());
				c.valueSymbolLinks.Get(member).resolvedType = c.getRegularTypeOfLiteralType(c.checkExpression(attr.AsImportAttribute().Value));
				members.set(member.Name, member);
			}
			final t = c.newAnonymousType(symbol, members, null, null, null);
			t.objectFlags |= ObjectFlagsObjectLiteral | ObjectFlagsNonInferrableType;
			links.resolvedType = t;
		}
		return links.resolvedType;
	}

	static function checkImportEqualsDeclaration(c:Checker, node:Node):Void {
		final diagnostic = Core.IfElse(Ast.IsInJSFile(node),
			Diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module,
			Diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module);
		if (c.checkGrammarModuleElementContext(node, diagnostic)) {
			return; // If we hit an import declaration in an illegal context, just bail out to avoid cascading errors.
		}
		c.checkGrammarModifiers(node);
		if (c.shouldCheckErasableSyntax(node) && (node.Flags & NodeFlagsAmbient) == 0) {
			c.error(node, Diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled);
		}
		if (Ast.IsInternalModuleImportEqualsDeclaration(node) || c.checkExternalImportOrExportDeclaration(node)) {
			c.checkImportBinding(node);
			c.markLinkedReferences(node, ReferenceHintExportImportEquals, null, null);
			final moduleReference = node.AsImportEqualsDeclaration().ModuleReference;
			if (!Ast.IsExternalModuleReference(moduleReference)) {
				final target = c.resolveAlias(c.getSymbolOfDeclaration(node));
				if (target != c.unknownSymbol) {
					final targetFlags = c.getSymbolFlags(target);
					if ((targetFlags & SymbolFlagsValue) != 0) {
						// Target is a value symbol, check that it is not hidden by a local declaration with the same name
						final moduleName = Ast.GetFirstIdentifier(moduleReference);
						if ((c.resolveEntityName(moduleName, SymbolFlagsValue | SymbolFlagsNamespace, false, false, null).Flags & SymbolFlagsNamespace) == 0) {
							c.error(moduleName, Diagnostics.Module_0_is_hidden_by_a_local_declaration_with_the_same_name, Scanner.DeclarationNameToString(moduleName));
						}
					}
					if ((targetFlags & SymbolFlagsType) != 0) {
						c.checkTypeNameIsReserved(node.Name(), Diagnostics.Import_name_cannot_be_0);
					}
				}
				if (node.IsTypeOnly()) {
					c.grammarErrorOnNode(node, Diagnostics.An_import_alias_cannot_use_import_type);
				}
			} else {
				if ((ModuleKindES2015 : Int) <= (c.moduleKind : Int) && (c.moduleKind : Int) <= (ModuleKindESNext : Int) && !node.IsTypeOnly()
					&& (node.Flags & NodeFlagsAmbient) == 0) {
					// Import equals declaration cannot be emitted as ESM
					c.grammarErrorOnNode(node,
						Diagnostics.Import_assignment_cannot_be_used_when_targeting_ECMAScript_modules_Consider_using_import_Asterisk_as_ns_from_mod_import_a_from_mod_import_d_from_mod_or_another_module_format_instead);
				}
			}
		}
	}

	static function checkExportDeclaration(c:Checker, node:ExportDeclarationNode):Void {
		final diagnostic = Core.IfElse(Ast.IsInJSFile(node),
			Diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_module,
			Diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module);
		if (c.checkGrammarModuleElementContext(node, diagnostic)) {
			return; // If we hit an export in an illegal context, just bail out to avoid cascading errors.
		}
		final exportDecl = node.AsExportDeclaration();
		if (!c.checkGrammarModifiers(node) && exportDecl.AsNode().Modifiers() != null) {
			c.grammarErrorOnFirstToken(node, Diagnostics.An_export_declaration_cannot_have_modifiers);
		}
		c.checkGrammarExportDeclaration(exportDecl);
		if (exportDecl.ModuleSpecifier == null || c.checkExternalImportOrExportDeclaration(node)) {
			if (exportDecl.ExportClause != null && !Ast.IsNamespaceExport(exportDecl.ExportClause)) {
				// export { x, y }
				// export { x, y } from "foo"
				for (binding in exportDecl.ExportClause.Elements()) {
					c.checkExportSpecifier(binding);
				}
				final inAmbientExternalModule = Ast.IsModuleBlock(node.Parent) && Ast.IsAmbientModule(node.Parent.Parent);
				final inAmbientNamespaceDeclaration = !inAmbientExternalModule && Ast.IsModuleBlock(node.Parent) && exportDecl.ModuleSpecifier == null
					&& (node.Flags & NodeFlagsAmbient) != 0;
				if (!Ast.IsSourceFile(node.Parent) && !inAmbientExternalModule && !inAmbientNamespaceDeclaration) {
					c.error(node, Diagnostics.Export_declarations_are_not_permitted_in_a_namespace);
				}
			} else {
				// export * from "foo"
				// export * as ns from "foo";
				final moduleSymbol = c.resolveExternalModuleName(node, exportDecl.ModuleSpecifier, false);
				if (moduleSymbol != null && Checker.hasExportAssignmentSymbol(moduleSymbol)) {
					c.error(exportDecl.ModuleSpecifier, Diagnostics.Module_0_uses_export_and_cannot_be_used_with_export_Asterisk, c.symbolToString(moduleSymbol));
				} else if (exportDecl.ExportClause != null) {
					c.checkAliasSymbol(exportDecl.ExportClause);
					c.checkModuleExportName(exportDecl.ExportClause.Name(), true /*allowStringLiteral*/);
				}
				if (c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
					if (node.AsExportDeclaration().ExportClause != null) {
						// export * as ns from "foo";
						c.checkExternalEmitHelpers(node, ExternalEmitHelpersImportStar);
					} else {
						// export * from "foo"
						c.checkExternalEmitHelpers(node, ExternalEmitHelpersExportStar);
					}
				}
			}
		}
		c.checkImportAttributes(node);
	}

	static function checkExportSpecifier(c:Checker, node:ExportSpecifierNode):Void {
		c.checkAliasSymbol(node);
		final hasModuleSpecifier = node.Parent.Parent.ModuleSpecifier() != null;
		c.checkModuleExportName(node.PropertyName(), hasModuleSpecifier);
		c.checkModuleExportName(node.Name(), true /*allowStringLiteral*/);

		if (!hasModuleSpecifier) {
			final exportedName = node.PropertyNameOrName();
			if (exportedName.Kind == KindStringLiteral) {
				return; // Skip for invalid syntax like this: export { "x" }
			}
			// find immediate value referenced by exported name (SymbolFlags.Alias is set so we don't chase down aliases)
			final symbol = c.resolveName(exportedName, exportedName.Text(), SymbolFlagsValue | SymbolFlagsType | SymbolFlagsNamespace | SymbolFlagsAlias,
				null /*nameNotFoundMessage*/, true /*isUse*/, false);
			if (symbol != null && (symbol == c.undefinedSymbol || symbol == c.globalThisSymbol
				|| symbol.Declarations != null && Ast.IsGlobalSourceFile(Ast.GetDeclarationContainer(symbol.Declarations[0])))) {
				c.error(exportedName, Diagnostics.Cannot_export_0_Only_local_declarations_can_be_exported_from_a_module, exportedName.Text());
			} else {
				c.markLinkedReferences(node, ReferenceHintExportSpecifier, null /*propSymbol*/, null /*parentType*/);
			}
		} else if (c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS
			&& Ast.ModuleExportNameIsDefault(node.PropertyNameOrName())) {
			c.checkExternalEmitHelpers(node, ExternalEmitHelpersImportDefault);
		}
	}

	static function checkExportAssignment(c:Checker, node:Node):Void {
		final isExportEquals = node.AsExportAssignment().IsExportEquals;
		final illegalContextMessage = Core.IfElse(isExportEquals,
			Diagnostics.An_export_assignment_must_be_at_the_top_level_of_a_file_or_module_declaration,
			Diagnostics.A_default_export_must_be_at_the_top_level_of_a_file_or_module_declaration);
		if (c.checkGrammarModuleElementContext(node, illegalContextMessage)) {
			return; // If we hit an export assignment in an illegal context, just bail out to avoid cascading errors.
		}
		if (c.shouldCheckErasableSyntax(node) && node.AsExportAssignment().IsExportEquals && (node.Flags & NodeFlagsAmbient) == 0) {
			c.error(node, Diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled);
		}
		var container = node.Parent;
		if (!Ast.IsSourceFile(container)) {
			container = container.Parent;
		}
		if (Ast.IsModuleDeclaration(container) && !Ast.IsAmbientModule(container)) {
			// TODO(danielr): should these be grammar errors?
			if (isExportEquals) {
				c.error(node, Diagnostics.An_export_assignment_cannot_be_used_in_a_namespace);
			} else {
				c.error(node, Diagnostics.A_default_export_can_only_be_used_in_an_ECMAScript_style_module);
			}
			return;
		}
		if (!c.checkGrammarModifiers(node) && Ast.IsExportAssignment(node) && node.AsExportAssignment().AsNode().Modifiers() != null) {
			c.grammarErrorOnFirstToken(node, Diagnostics.An_export_assignment_cannot_have_modifiers);
		}
		final isIllegalExportDefaultInCJS = !isExportEquals && (node.Flags & NodeFlagsAmbient) == 0 && c.compilerOptions.VerbatimModuleSyntax.IsTrue()
			&& c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS;
		if (Ast.IsIdentifier(node.Expression())) {
			final id = node.Expression();
			final sym = c.getExportSymbolOfValueSymbolIfExported(c.resolveEntityName(id, SymbolFlagsAll, true /*ignoreErrors*/, true /*dontResolveAlias*/, node));
			if (sym != null) {
				c.markLinkedReferences(node, ReferenceHintExportAssignment, null, null);
				final typeOnlyDeclaration = c.getTypeOnlyAliasDeclarationEx(sym, SymbolFlagsValue);
				// If not a value, we're interpreting the identifier as a type export, along the lines of (`export { Id as default }`)
				if ((c.getSymbolFlags(sym) & SymbolFlagsValue) != 0) {
					// However if it is a value, we need to check it's being used correctly
					c.checkExpressionCached(id);
					if (!isIllegalExportDefaultInCJS && (node.Flags & NodeFlagsAmbient) == 0 && c.compilerOptions.VerbatimModuleSyntax.IsTrue()
						&& typeOnlyDeclaration != null) {
						final message = Core.IfElse(isExportEquals,
							Diagnostics.An_export_declaration_must_reference_a_real_value_when_verbatimModuleSyntax_is_enabled_but_0_resolves_to_a_type_only_declaration,
							Diagnostics.An_export_default_must_reference_a_real_value_when_verbatimModuleSyntax_is_enabled_but_0_resolves_to_a_type_only_declaration);
						c.error(id, message, id.Text());
					}
				} else if (!isIllegalExportDefaultInCJS && (node.Flags & NodeFlagsAmbient) == 0 && c.compilerOptions.VerbatimModuleSyntax.IsTrue()) {
					final message = Core.IfElse(isExportEquals,
						Diagnostics.An_export_declaration_must_reference_a_value_when_verbatimModuleSyntax_is_enabled_but_0_only_refers_to_a_type,
						Diagnostics.An_export_default_must_reference_a_value_when_verbatimModuleSyntax_is_enabled_but_0_only_refers_to_a_type);
					c.error(id, message, id.Text());
				}
				if (!isIllegalExportDefaultInCJS && (node.Flags & NodeFlagsAmbient) == 0 && c.compilerOptions.GetIsolatedModules()
					&& (sym.Flags & SymbolFlagsValue) == 0) {
					final nonLocalMeanings = c.getSymbolFlagsEx(sym, false /*excludeTypeOnlyMeanings*/, true /*excludeLocalMeanings*/);
					if ((sym.Flags & SymbolFlagsAlias) != 0 && (nonLocalMeanings & SymbolFlagsType) != 0 && (nonLocalMeanings & SymbolFlagsValue) == 0
						&& (typeOnlyDeclaration == null || Ast.GetSourceFileOfNode(typeOnlyDeclaration) != Ast.GetSourceFileOfNode(node))) {
						// import { SomeType } from "./someModule";
						// export default SomeType; OR
						// export = SomeType;
						final message = Core.IfElse(isExportEquals,
							Diagnostics.X_0_resolves_to_a_type_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_import_type_where_0_is_imported,
							Diagnostics.X_0_resolves_to_a_type_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_export_type_0_as_default);
						c.error(id, message, id.Text(), c.getIsolatedModulesLikeFlagName());
					} else if (typeOnlyDeclaration != null && Ast.GetSourceFileOfNode(typeOnlyDeclaration) != Ast.GetSourceFileOfNode(node)) {
						// import { SomeTypeOnlyValue } from "./someModule";
						// export default SomeTypeOnlyValue; OR
						// export = SomeTypeOnlyValue;
						final message = Core.IfElse(isExportEquals,
							Diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_import_type_where_0_is_imported,
							Diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_export_type_0_as_default);
						c.addTypeOnlyDeclarationRelatedInfo(c.error(id, message, id.Text(), c.getIsolatedModulesLikeFlagName()), typeOnlyDeclaration, id.Text());
					}
				}
			} else {
				c.checkExpressionCached(id);
				// doesn't resolve, check as expression to mark as error
			}
		} else {
			c.checkExpressionCached(node.Expression());
		}
		if (isIllegalExportDefaultInCJS) {
			c.error(node, Checker.getVerbatimModuleSyntaxErrorMessage(node));
		}
		c.checkExternalModuleExports(container);
		final typeNode = node.Type();
		if (typeNode != null && node.Kind == KindExportAssignment) {
			final t = c.getTypeFromTypeNode(typeNode);
			final initializerType = c.checkExpressionCached(node.Expression());
			c.checkTypeAssignableToAndOptionallyElaborate(initializerType, t, node.Expression(), node.Expression(), null /*headMessage*/, null);
		}
		if (((node.Flags & NodeFlagsAmbient) != 0) && !Ast.IsEntityNameExpression(node.Expression())) {
			c.grammarErrorOnNode(node.Expression(),
				Diagnostics.The_expression_of_an_export_assignment_must_be_an_identifier_or_qualified_name_in_an_ambient_context);
		}
		if (isExportEquals) {
			// Forbid export= in esm implementation files, and esm mode declaration files
			if ((c.moduleKind : Int) >= (ModuleKindES2015 : Int) && c.moduleKind != ModuleKindPreserve
				&& (((node.Flags & NodeFlagsAmbient) != 0
					&& c.program.GetImpliedNodeFormatForEmit(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindESNext)
					|| ((node.Flags & NodeFlagsAmbient) == 0
						&& c.program.GetImpliedNodeFormatForEmit(hasFileName(Ast.GetSourceFileOfNode(node))) != ModuleKindCommonJS))) {
				// export assignment is not supported in es6 modules
				c.grammarErrorOnNode(node,
					Diagnostics.Export_assignment_cannot_be_used_when_targeting_ECMAScript_modules_Consider_using_export_default_or_another_module_format_instead);
			} else if (c.moduleKind == ModuleKindSystem && (node.Flags & NodeFlagsAmbient) == 0) {
				// system modules does not support export assignment
				c.grammarErrorOnNode(node, Diagnostics.Export_assignment_is_not_supported_when_module_flag_is_system);
			}
		}
	}

	static function checkExternalModuleExports(c:Checker, node:Node):Void {
		final moduleSymbol = c.getSymbolOfDeclaration(node);
		final links = c.moduleSymbolLinks.Get(moduleSymbol);
		if (!links.exportsChecked) {
			final exportEqualsSymbol = moduleSymbol.Exports != null ? moduleSymbol.Exports.get(Ast.InternalSymbolNameExportEquals) : null;
			// An export assignment is in error if (a) the module exports value members or (b) if the module exports type or
			// namespace members and the exported entity also exports type or namespace members.
			if (exportEqualsSymbol != null && (c.hasExportedMembersOfKind(moduleSymbol, SymbolFlagsValue) || c.hasShadowedNamespace(exportEqualsSymbol))) {
				final declaration = Core.OrElse(c.getDeclarationOfAliasSymbol(exportEqualsSymbol), exportEqualsSymbol.ValueDeclaration);
				if (declaration != null && !Checker.isTopLevelInExternalModuleAugmentation(declaration)) {
					c.error(declaration, Diagnostics.An_export_assignment_cannot_be_used_in_a_module_with_other_exported_elements);
				}
			}
			// Checks for export * conflicts
			final exports = c.getExportsOfModule(moduleSymbol);
			if (exports != null) {
				for (id => symbol in exports) {
					if (id == Ast.InternalSymbolNameExportStar) {
						continue;
					}
					// ECMA262: 15.2.1.1 It is a Syntax Error if the ExportedNames of ModuleItemList contains any duplicate entries.
					// (TS Exceptions: namespaces, function overloads, enums, and interfaces)
					if ((symbol.Flags & (SymbolFlagsNamespace | SymbolFlagsEnum)) != 0) {
						continue;
					}
					final exportedDeclarationsCount = Core.CountWhere(symbol.Declarations, function(d:Node):Bool {
						return Checker.isNotOverload(d) && !Ast.IsAccessor(d) && !Ast.IsInterfaceDeclaration(d);
					});
					if ((symbol.Flags & SymbolFlagsTypeAlias) != 0 && exportedDeclarationsCount <= 2) {
						// it is legal to merge type alias with other values
						// so count should be either 1 (just type alias) or 2 (type alias + merged value)
						continue;
					}
					if (exportedDeclarationsCount > 1 && !Core.Every(symbol.Declarations, function(node:Node):Bool {
						return Ast.GetAssignmentDeclarationKind(node) == JSDeclarationKindExportsProperty;
					})) {
						for (declaration in symbol.Declarations) {
							if (Checker.isNotOverload(declaration)) {
								c.error(declaration, Diagnostics.Cannot_redeclare_exported_variable_0, id);
							}
						}
					}
				}
			}
			links.exportsChecked = true;
		}
	}

	static function hasExportedMembersOfKind(c:Checker, moduleSymbol:Symbol, kind:SymbolFlags):Bool {
		if (moduleSymbol.Exports != null) {
			for (symbol in moduleSymbol.Exports) {
				if (symbol.Name != Ast.InternalSymbolNameExportEquals && (c.getSymbolFlags(symbol) & kind) != 0) {
					return true;
				}
			}
		}
		return false;
	}

	static function hasShadowedNamespace(c:Checker, symbol:Symbol):Bool {
		if ((symbol.Flags & SymbolFlagsNamespaceModule) != 0 && (symbol.Flags & SymbolFlagsAlias) != 0) {
			final target = c.resolveAlias(symbol);
			if ((target.Flags & SymbolFlagsNamespace) != 0 && c.hasExportedMembersOfKind(target, SymbolFlagsType | SymbolFlagsNamespace)) {
				return true;
			}
		}
		return false;
	}

	static function checkMissingDeclaration(c:Checker, node:Node):Void {
		c.checkDecorators(node);
	}

	static function checkVariableStatement(c:Checker, node:Node):Void {
		final varStatement = node.AsVariableStatement();
		final declarationList = varStatement.DeclarationList;
		if (!c.checkGrammarModifiers(node) && !c.checkGrammarVariableDeclarationList(declarationList.AsVariableDeclarationList())) {
			c.checkGrammarForDisallowedBlockScopedVariableStatement(varStatement);
		}
		c.checkVariableDeclarationList(declarationList);
	}

	static function checkVariableDeclarationList(c:Checker, node:Node):Void {
		final blockScopeKind = Ast.GetCombinedNodeFlags(node) & NodeFlagsBlockScoped;
		if ((blockScopeKind == NodeFlagsUsing || blockScopeKind == NodeFlagsAwaitUsing)
			&& (c.languageVersion : Int) < (Checker.LanguageFeatureMinimumTarget.UsingAndAwaitUsing : Int)) {
			c.checkExternalEmitHelpers(node, ExternalEmitHelpersAddDisposableResourceAndDisposeResources);
		}
		c.checkSourceElements(node.AsVariableDeclarationList().Declarations.Nodes);
	}

	static function checkVariableDeclaration(c:Checker, node:Node):Void {
		// PORT: Go `defer tr.Push(...)()`: the returned func runs on return and on panic.
		var pop:() -> Void = null;
		final tr = c.tracer;
		if (tr != null) {
			final args = new StringMap<Any>();
			args.set("kind", node.Kind);
			args.set("pos", node.Pos());
			args.set("end", node.End());
			args.set("path", Ast.GetSourceFileOfNode(node).FileName());
			pop = tr.Push(PhaseCheck, "checkVariableDeclaration", args, false);
		}
		try {
			c.checkGrammarVariableDeclaration(node.AsVariableDeclaration());
			c.checkVariableLikeDeclaration(node);
		} catch (e:Dynamic) {
			if (pop != null) {
				pop();
			}
			throw e;
		}
		if (pop != null) {
			pop();
		}
	}

	// Check variable, parameter, or property declaration
	static function checkVariableLikeDeclaration(c:Checker, node:Node):Void {
		c.checkDecorators(node);
		final name = node.Name();
		if (name == null) {
			return; // Missing array binding elements have no name
		}
		final typeNode = node.Type();
		final initializer = node.Initializer();
		if (!Ast.IsBindingElement(node)) {
			c.checkSourceElement(typeNode);
		}
		// For a computed property, just check the initializer and exit
		// Do not use hasDynamicName here, because that returns false for well known symbols.
		// We want to perform checkComputedPropertyName for all computed properties, including
		// well known symbols.
		if (Ast.IsComputedPropertyName(name)) {
			c.checkComputedPropertyName(name);
			if (initializer != null) {
				c.checkExpressionCached(initializer);
			}
		}
		if (Ast.IsBindingElement(node)) {
			final propName = node.PropertyName();
			if (propName != null && Ast.IsIdentifier(node.Name()) && Ast.IsPartOfParameterDeclaration(node)
				&& Ast.NodeIsMissing(Ast.GetContainingFunction(node).Body())) {
				// type F = ({a: string}) => void;
				//               ^^^^^^
				// variable renaming in function type notation is confusing,
				// so we forbid it even if noUnusedLocals is not enabled
				if (c.renamedBindingElementsInTypes == null) {
					c.renamedBindingElementsInTypes = [];
				}
				c.renamedBindingElementsInTypes.push(node);
				return;
			}
			if (Ast.IsObjectBindingPattern(node.Parent) && Checker.hasDotDotDotToken(node)
				&& (c.languageVersion : Int) < (Checker.LanguageFeatureMinimumTarget.ObjectSpreadRest : Int)) {
				c.checkExternalEmitHelpers(node, ExternalEmitHelpersRest);
			}
			// check computed properties inside property names of binding elements
			if (propName != null && Ast.IsComputedPropertyName(propName)) {
				c.checkComputedPropertyName(propName);
			}
			// check private/protected variable access
			final parent = node.Parent.Parent;
			final parentCheckMode = Core.IfElse(Checker.hasDotDotDotToken(node), CheckModeRestBindingElement, CheckModeNormal);
			final parentType = c.getTypeForBindingElementParent(parent, parentCheckMode);
			final propNameName = node.PropertyNameOrName();
			if (parentType != null && !Ast.IsBindingPattern(propNameName)) {
				final exprType = c.getLiteralTypeFromPropertyName(propNameName);
				if (Checker.isTypeUsableAsPropertyName(exprType)) {
					final nameText = Checker.getPropertyNameFromType(exprType);
					final property = c.getPropertyOfType(parentType, nameText);
					if (property != null) {
						c.markPropertyAsReferenced(property, null /*nodeForCheckWriteOnly*/, false /*isSelfTypeAccess*/);
						// A destructuring is never a write-only reference.
						c.checkPropertyAccessibility(node, parent.Initializer() != null && parent.Initializer().Kind == KindSuperKeyword, false /*writing*/,
							parentType, property);
					}
				}
			}
		}
		// For a binding pattern, check contained binding elements
		if (Ast.IsBindingPattern(name)) {
			c.checkSourceElements(name.Elements());
		}
		// For a parameter declaration with an initializer, error and exit if the containing function doesn't have a body
		if (initializer != null && Ast.IsPartOfParameterDeclaration(node) && Ast.NodeIsMissing(Ast.GetContainingFunction(node).Body())) {
			c.error(node, Diagnostics.A_parameter_initializer_is_only_allowed_in_a_function_or_constructor_implementation);
			return;
		}
		// For a binding pattern, validate the initializer and exit
		if (Ast.IsBindingPattern(name)) {
			if (Checker.isInAmbientOrTypeNode(node)) {
				return;
			}
			final needCheckInitializer = initializer != null && node.Parent.Parent.Kind != KindForInStatement;
			final needCheckWidenedType = !Core.Some(name.Elements(), n -> n.Name() != null);
			if (needCheckInitializer || needCheckWidenedType) {
				// Don't validate for-in initializer as it is already an error
				final widenedType = c.getWidenedTypeForVariableLikeDeclaration(node, false /*reportErrors*/);
				if (needCheckInitializer) {
					final initializerType = c.checkExpressionCached(initializer);
					if (c.strictNullChecks && needCheckWidenedType) {
						c.checkNonNullNonVoidType(initializerType, node);
					} else {
						c.checkTypeAssignableToAndOptionallyElaborate(initializerType, c.getWidenedTypeForVariableLikeDeclaration(node, false), node, initializer,
							null, null);
					}
				}
				// check the binding pattern with empty elements
				if (needCheckWidenedType) {
					if (Ast.IsArrayBindingPattern(name)) {
						c.checkIteratedTypeOrElementType(IterationUseDestructuring, widenedType, c.undefinedType, node);
					} else if (c.strictNullChecks) {
						c.checkNonNullNonVoidType(widenedType, node);
					}
				}
			}
			return;
		}
		// For a commonjs `const x = require`, validate the alias and exit
		final symbol = c.getSymbolOfDeclaration(node);
		if ((symbol.Flags & SymbolFlagsAlias) != 0 && Ast.IsVariableDeclarationInitializedToRequire(node)) {
			c.checkAliasSymbol(node);
			return;
		}
		if (Ast.IsBigIntLiteral(name)) {
			c.error(name, Diagnostics.A_bigint_literal_cannot_be_used_as_a_property_name);
		}
		final t = c.convertAutoToAny(c.getTypeOfSymbol(symbol));
		if (node == symbol.ValueDeclaration) {
			// Node is the primary declaration of the symbol, just validate the initializer
			// Don't validate for-in initializer as it is already an error
			if (initializer != null && !Ast.IsForInStatement(node.Parent.Parent)) {
				final initializerType = c.checkExpressionCached(initializer);
				c.checkTypeAssignableToAndOptionallyElaborate(initializerType, t, node, initializer, null /*headMessage*/, null);
				final blockScopeKind = c.getCombinedNodeFlagsCached(node) & NodeFlagsBlockScoped;
				if (blockScopeKind == NodeFlagsAwaitUsing) {
					final globalAsyncDisposableType = c.getGlobalAsyncDisposableType();
					final globalDisposableType = c.getGlobalDisposableType();
					if (globalAsyncDisposableType != c.emptyObjectType && globalDisposableType != c.emptyObjectType) {
						final optionalDisposableType = c.getUnionType([globalAsyncDisposableType, globalDisposableType, c.nullType, c.undefinedType]);
						c.checkTypeAssignableTo(c.widenTypeForVariableLikeDeclaration(initializerType, node, false), optionalDisposableType, initializer,
							Diagnostics.The_initializer_of_an_await_using_declaration_must_be_either_an_object_with_a_Symbol_asyncDispose_or_Symbol_dispose_method_or_be_null_or_undefined);
					}
				} else if (blockScopeKind == NodeFlagsUsing) {
					final globalDisposableType = c.getGlobalDisposableType();
					if (globalDisposableType != c.emptyObjectType) {
						final optionalDisposableType = c.getUnionType([globalDisposableType, c.nullType, c.undefinedType]);
						c.checkTypeAssignableTo(c.widenTypeForVariableLikeDeclaration(initializerType, node, false), optionalDisposableType, initializer,
							Diagnostics.The_initializer_of_a_using_declaration_must_be_either_an_object_with_a_Symbol_dispose_method_or_be_null_or_undefined);
					}
				}
			}
			if (Core.len(symbol.Declarations) > 1) {
				if (Core.Some(symbol.Declarations, function(d:Declaration):Bool {
					return d != node && Ast.IsVariableLike(d) && !c.areDeclarationFlagsIdentical(d, node);
				})) {
					c.error(name, Diagnostics.All_declarations_of_0_must_have_identical_modifiers, Scanner.DeclarationNameToString(name));
				}
			}
		} else {
			// Node is a secondary declaration, check that type is identical to primary declaration and check that
			// initializer is consistent with type associated with the node
			final declarationType = c.convertAutoToAny(c.getWidenedTypeForVariableLikeDeclaration(node, false));
			if (!c.isErrorType(t) && !c.isErrorType(declarationType) && !c.isTypeIdenticalTo(t, declarationType)
				&& (symbol.Flags & SymbolFlagsAssignment) == 0) {
				c.errorNextVariableOrPropertyDeclarationMustHaveSameType(symbol.ValueDeclaration, t, node, declarationType);
			}
			if (initializer != null) {
				c.checkTypeAssignableToAndOptionallyElaborate(c.checkExpressionCached(initializer), declarationType, node, initializer, null /*headMessage*/, null);
			}
			if (symbol.ValueDeclaration != null && !c.areDeclarationFlagsIdentical(node, symbol.ValueDeclaration)) {
				c.error(name, Diagnostics.All_declarations_of_0_must_have_identical_modifiers, Scanner.DeclarationNameToString(name));
			}
		}
		if (!Ast.IsPropertyDeclaration(node) && !Ast.IsPropertySignatureDeclaration(node)) {
			// We know we don't have a binding pattern or computed name here
			c.checkExportsOnMergedDeclarations(node);
			if (Ast.IsVariableDeclaration(node) || Ast.IsBindingElement(node)) {
				c.checkVarDeclaredNamesNotShadowed(node);
			}
			c.checkCollisionsForDeclarationName(node, node.Name());
		}
	}

	static function errorNextVariableOrPropertyDeclarationMustHaveSameType(c:Checker, firstDeclaration:Declaration, firstType:Type, nextDeclaration:Declaration, nextType:Type):Void {
		final nextDeclarationName = Ast.GetNameOfDeclaration(nextDeclaration);
		final message = Core.IfElse(Ast.IsPropertyDeclaration(nextDeclaration) || Ast.IsPropertySignatureDeclaration(nextDeclaration),
			Diagnostics.Subsequent_property_declarations_must_have_the_same_type_Property_0_must_be_of_type_1_but_here_has_type_2,
			Diagnostics.Subsequent_variable_declarations_must_have_the_same_type_Variable_0_must_be_of_type_1_but_here_has_type_2);
		final declName = Scanner.DeclarationNameToString(nextDeclarationName);
		final err = c.error(nextDeclarationName, message, declName, c.TypeToString(firstType), c.TypeToString(nextType));
		if (firstDeclaration != null) {
			err.AddRelatedInfo(Checker.createDiagnosticForNode(firstDeclaration, Diagnostics.X_0_was_also_declared_here, declName));
		}
	}

	static function checkVarDeclaredNamesNotShadowed(c:Checker, node:Node):Void {
		// - ScriptBody : StatementList
		// It is a Syntax Error if any element of the LexicallyDeclaredNames of StatementList
		// also occurs in the VarDeclaredNames of StatementList.

		// - Block : { StatementList }
		// It is a Syntax Error if any element of the LexicallyDeclaredNames of StatementList
		// also occurs in the VarDeclaredNames of StatementList.

		// Variable declarations are hoisted to the top of their function scope. They can shadow
		// block scoped declarations, which bind tighter. this will not be flagged as duplicate definition
		// by the binder as the declaration scope is different.
		// A non-initialized declaration is a no-op as the block declaration will resolve before the var
		// declaration. the problem is if the declaration has an initializer. this will act as a write to the
		// block declared value. this is fine for let, but not const.
		// Only consider declarations with initializers, uninitialized const declarations will not
		// step on a let/const variable.
		// Do not consider const and const declarations, as duplicate block-scoped declarations
		// are handled by the binder.
		// We are only looking for const declarations that step on let\const declarations from a
		// different scope. e.g.:
		//      {
		//          const x = 0; // localDeclarationSymbol obtained after name resolution will correspond to this declaration
		//          const x = 0; // symbol for this declaration will be 'symbol'
		//      }

		// skip block-scoped variables and parameters
		if ((c.getCombinedNodeFlagsCached(node) & NodeFlagsBlockScoped) != 0 || Ast.IsPartOfParameterDeclaration(node)) {
			return;
		}
		// NOTE: in ES6 spec initializer is required in variable declarations where name is binding pattern
		// so we'll always treat binding elements as initialized
		final symbol = c.getSymbolOfDeclaration(node);
		final name = node.Name();
		if ((symbol.Flags & SymbolFlagsFunctionScopedVariable) != 0) {
			if (!Ast.IsIdentifier(name)) {
				throw "Identifier expected";
			}
			final localDeclarationSymbol = c.resolveName(node, name.Text(), SymbolFlagsVariable, null /*nameNotFoundMessage*/, false /*isUse*/, false);
			if (localDeclarationSymbol != null && localDeclarationSymbol != symbol && (localDeclarationSymbol.Flags & SymbolFlagsBlockScopedVariable) != 0) {
				if ((c.getDeclarationNodeFlagsFromSymbol(localDeclarationSymbol) & NodeFlagsBlockScoped) != 0) {
					final varDeclList = Ast.FindAncestorKind(localDeclarationSymbol.ValueDeclaration, KindVariableDeclarationList);
					var container:Node = null;
					if (Ast.IsVariableStatement(varDeclList.Parent) && varDeclList.Parent.Parent != null) {
						container = varDeclList.Parent.Parent;
					}
					// names of block-scoped and function scoped variables can collide only
					// if block scoped variable is defined in the function\module\source file scope (because of variable hoisting)
					final namesShareScope = container != null
						&& (Ast.IsBlock(container) && Ast.IsFunctionLike(container.Parent) || Ast.IsModuleBlock(container) || Ast.IsModuleDeclaration(container)
							|| Ast.IsSourceFile(container));
					// here we know that function scoped variable is "shadowed" by block scoped one
					// a var declaration can't hoist past a lexical declaration and it results in a SyntaxError at runtime
					if (!namesShareScope) {
						final name = c.symbolToString(localDeclarationSymbol);
						c.error(node, Diagnostics.Cannot_initialize_outer_scoped_variable_0_in_the_same_scope_as_block_scoped_declaration_1, name, name);
					}
				}
			}
		}
	}

	static function checkDecorators(c:Checker, node:Node):Void {
		// skip this check for nodes that cannot have decorators. These should have already had an error reported by
		// checkGrammarModifiers.
		if (!Ast.CanHaveDecorators(node) || !Ast.HasDecorators(node) || !Ast.NodeCanBeDecorated(c.legacyDecorators, node, node.Parent, node.Parent.Parent)) {
			return;
		}
		final firstDecorator = Core.Find(node.ModifierNodes(), Ast.IsDecorator);
		if (firstDecorator == null) {
			return;
		}
		if (c.legacyDecorators) {
			c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersDecorate);
			if (Ast.IsParameterDeclaration(node)) {
				c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersParam);
			}
		} else if ((c.languageVersion : Int) < (Checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators : Int)) {
			c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersESDecorateAndRunInitializers);
			if (Ast.IsClassDeclaration(node)) {
				if (node.Name() == null || c.getFirstTransformableStaticClassElement(node) != null) {
					c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersSetFunctionName);
				}
			} else if (!Ast.IsClassExpression(node)) {
				final name = node.Name();
				if (Ast.IsPrivateIdentifier(name) && (Ast.IsMethodDeclaration(node) || Ast.IsAccessor(node) || Ast.IsAutoAccessorPropertyDeclaration(node))) {
					c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersSetFunctionName);
				}
				if (Ast.IsComputedPropertyName(name)) {
					c.checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpersPropKey);
				}
			}
		}
		c.markLinkedReferences(node, ReferenceHintDecorator, null, null);
		for (modifier in rangeOf(node.ModifierNodes())) {
			if (Ast.IsDecorator(modifier)) {
				c.checkDecorator(modifier);
			}
		}
	}

	static function checkDecorator(c:Checker, node:Node):Void {
		c.checkGrammarDecorator(node.AsDecorator());
		final signature = c.getResolvedSignature(node, null, CheckModeNormal);
		c.checkDeprecatedSignature(signature, node);
		final returnType = c.getReturnTypeOfSignature(signature);
		if ((returnType.flags & TypeFlagsAny) != 0) {
			return;
		}
		// if we fail to get a signature and return type here, we will have already reported a grammar error in `checkDecorators`.
		final decoratorSignature = c.getDecoratorCallSignature(node);
		if (decoratorSignature == null || decoratorSignature.resolvedReturnType == null) {
			return;
		}
		var headMessage:Message = null;
		final expectedReturnType = decoratorSignature.resolvedReturnType;
		switch (node.Parent.Kind) {
			case KindClassDeclaration | KindClassExpression:
				headMessage = Diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1;
			case KindPropertyDeclaration:
				// PORT: Go `break` out of the switch, else `fallthrough` into the parameter case.
				if (!c.legacyDecorators) {
					headMessage = Diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1;
				} else {
					headMessage = Diagnostics.Decorator_function_return_type_is_0_but_is_expected_to_be_void_or_any;
				}
			case KindParameter:
				headMessage = Diagnostics.Decorator_function_return_type_is_0_but_is_expected_to_be_void_or_any;
			case KindMethodDeclaration | KindGetAccessor | KindSetAccessor:
				headMessage = Diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1;
			default:
				throw "Unhandled case in checkDecorator";
		}
		c.checkTypeAssignableTo(returnType, expectedReturnType, node.Expression(), headMessage);
	}

	static function checkIteratedTypeOrElementType(c:Checker, use:IterationUse, inputType:Type, sentType:Type, errorNode:Node):Type {
		if (Checker.IsTypeAny(inputType)) {
			return inputType;
		}
		final t = c.getIteratedTypeOrElementType(use, inputType, sentType, errorNode, true /*checkAssignability*/);
		if (t != null) {
			return t;
		}
		return c.anyType;
	}

	static function getIteratedTypeOrElementType(c:Checker, use:IterationUse, inputType:Type, sentType:Type, errorNode:Node, checkAssignability:Bool):Type {
		final allowAsyncIterables = (use & IterationUseAllowsAsyncIterablesFlag) != 0;
		if (inputType == c.neverType) {
			if (errorNode != null) {
				c.reportTypeNotIterableError(errorNode, inputType, allowAsyncIterables);
			}
			return null;
		}
		final iterableExists = c.getGlobalIterableType() != c.emptyGenericType;
		final possibleOutOfBounds = c.compilerOptions.NoUncheckedIndexedAccess == TSTrue && (use & IterationUsePossiblyOutOfBounds) != 0;
		if (iterableExists || allowAsyncIterables) {
			final iterationTypes = c.getIterationTypesOfIterable(inputType, use, Core.IfElse(iterableExists, errorNode, null));
			if (checkAssignability) {
				if (iterationTypes.nextType != null) {
					var diagnostic:Message = null;
					if ((use & IterationUseForOfFlag) != 0) {
						diagnostic = Diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_for_of_will_always_send_0;
					} else if ((use & IterationUseSpreadFlag) != 0) {
						diagnostic = Diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_array_spread_will_always_send_0;
					} else if ((use & IterationUseDestructuringFlag) != 0) {
						diagnostic = Diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_array_destructuring_will_always_send_0;
					} else if ((use & IterationUseYieldStarFlag) != 0) {
						diagnostic = Diagnostics.Cannot_delegate_iteration_to_value_because_the_next_method_of_its_iterator_expects_type_1_but_the_containing_generator_will_always_send_0;
					}
					if (diagnostic != null) {
						c.checkTypeAssignableTo(sentType, iterationTypes.nextType, errorNode, diagnostic);
					}
				}
			}
			if (iterationTypes.yieldType != null || iterableExists) {
				if (iterationTypes.yieldType == null) {
					return null;
				}
				if (possibleOutOfBounds) {
					return c.includeUndefinedInIndexSignature(iterationTypes.yieldType);
				}
				return iterationTypes.yieldType;
			}
		}
		var arrayType = inputType;
		var hasStringConstituent = false;
		// If strings are permitted, remove any string-like constituents from the array type.
		// This allows us to find other non-string element types from an array unioned with
		// a string.
		if ((use & IterationUseAllowsStringInputFlag) != 0) {
			if ((arrayType.flags & TypeFlagsUnion) != 0) {
				// After we remove all types that are StringLike, we will know if there was a string constituent
				// based on whether the result of filter is a new array.
				final arrayTypes = inputType.Types();
				final filteredTypes = Core.Filter(arrayTypes, t -> (t.flags & TypeFlagsStringLike) == 0);
				if (!Core.Same(filteredTypes, arrayTypes)) {
					arrayType = c.getUnionTypeEx(filteredTypes, UnionReductionSubtype, null, null);
				}
			} else if ((arrayType.flags & TypeFlagsStringLike) != 0) {
				arrayType = c.neverType;
			}
			hasStringConstituent = arrayType != inputType;
			if (hasStringConstituent) {
				// Now that we've removed all the StringLike types, if no constituents remain, then the entire
				// arrayOrStringType was a string.
				if ((arrayType.flags & TypeFlagsNever) != 0) {
					if (possibleOutOfBounds) {
						return c.includeUndefinedInIndexSignature(c.stringType);
					}
					return c.stringType;
				}
			}
		}
		if (!c.isArrayLikeType(arrayType)) {
			if (errorNode != null) {
				// Which error we report depends on whether we allow strings or if there was a
				// string constituent. For example, if the input type is number | string, we
				// want to say that number is not an array type. But if the input was just
				// number and string input is allowed, we want to say that number is not an
				// array type or a string type.
				final allowsStrings = (use & IterationUseAllowsStringInputFlag) != 0 && !hasStringConstituent;
				final details = c.getIterationDiagnosticDetails(use, inputType, allowsStrings);
				final defaultDiagnostic = details.value;
				final maybeMissingAwait = details.ok;
				c.errorAndMaybeSuggestAwait(errorNode, maybeMissingAwait && c.getAwaitedTypeOfPromise(arrayType) != null, defaultDiagnostic,
					c.TypeToString(arrayType));
			}
			if (hasStringConstituent) {
				if (possibleOutOfBounds) {
					return c.includeUndefinedInIndexSignature(c.stringType);
				}
				return c.stringType;
			}
			return null;
		}
		final arrayElementType = c.getIndexTypeOfType(arrayType, c.numberType);
		if (hasStringConstituent && arrayElementType != null) {
			// This is just an optimization for the case where arrayOrStringType is string | string[]
			if ((arrayElementType.flags & TypeFlagsStringLike) != 0 && c.compilerOptions.NoUncheckedIndexedAccess != TSTrue) {
				return c.stringType;
			}
			if (possibleOutOfBounds) {
				return c.getUnionTypeEx([arrayElementType, c.stringType, c.undefinedType], UnionReductionSubtype, null, null);
			}
			return c.getUnionTypeEx([arrayElementType, c.stringType], UnionReductionSubtype, null, null);
		}
		if ((use & IterationUsePossiblyOutOfBounds) != 0) {
			return c.includeUndefinedInIndexSignature(arrayElementType);
		}
		return arrayElementType;
	}

	// Gets the requested "iteration type" from a type that is either `Iterable`-like, `Iterator`-like,
	// `IterableIterator`-like, or `Generator`-like (for a non-async generator); or `AsyncIterable`-like,
	// `AsyncIterator`-like, `AsyncIterableIterator`-like, or `AsyncGenerator`-like (for an async generator).
	static function getIterationTypeOfGeneratorFunctionReturnType(c:Checker, typeKind:IterationTypeKind, returnType:Type, isAsyncGenerator:Bool):Type {
		if (Checker.IsTypeAny(returnType)) {
			return null;
		}
		final iterationTypes = c.getIterationTypesOfGeneratorFunctionReturnType(returnType, isAsyncGenerator);
		return iterationTypes.getType(typeKind);
	}

	static function getIterationTypesOfGeneratorFunctionReturnType(c:Checker, t:Type, isAsyncGenerator:Bool):IterationTypes {
		if (Checker.IsTypeAny(t)) {
			return newIterationTypes(c.anyType, c.anyType, c.anyType);
		}
		final use = Core.IfElse(isAsyncGenerator, IterationUseAsyncGeneratorReturnType, IterationUseGeneratorReturnType);
		final resolver = Core.IfElse(isAsyncGenerator, c.asyncIterationTypesResolver, c.syncIterationTypesResolver);
		final result = c.getIterationTypesOfIterable(t, use, null /*errorNode*/);
		if (result.hasTypes()) {
			return result;
		}
		return c.getIterationTypesOfIterator(t, resolver, null /*errorNode*/, null /*diagnosticOutput*/);
	}

	// Gets the requested "iteration type" from an `Iterable`-like or `AsyncIterable`-like type.
	static function getIterationTypeOfIterable(c:Checker, use:IterationUse, typeKind:IterationTypeKind, inputType:Type, errorNode:Node):Type {
		if (Checker.IsTypeAny(inputType)) {
			return null;
		}
		final iterationTypes = c.getIterationTypesOfIterable(inputType, use, errorNode);
		return iterationTypes.getType(typeKind);
	}

	// Gets the *yield*, *return*, and *next* types from an `Iterable`-like or `AsyncIterable`-like type.
	//
	// At every level that involves analyzing return types of signatures, we union the return types of all the signatures.
	//
	// Another thing to note is that at any step of this process, we could run into a dead end,
	// meaning either the property is missing, or we run into the anyType. If either of these things
	// happens, we return a default `IterationTypes{}` to signal that we could not find the iteration type.
	// If a property is missing, and the previous step did not result in `any`, then we also give an error
	// if the caller requested it. Then the caller can decide what to do in the case where there is no
	// iterated type.
	//
	// For a **for-of** statement, `yield*` (in a normal generator), spread, array
	// destructuring, or normal generator we will only ever look for a `[Symbol.iterator]()`
	// method.
	//
	// For an async generator we will only ever look at the `[Symbol.asyncIterator]()` method.
	//
	// For a **for-await-of** statement or a `yield*` in an async generator we will look for
	// the `[Symbol.asyncIterator]()` method first, and then the `[Symbol.iterator]()` method.
	static function getIterationTypesOfIterable(c:Checker, t:Type, use:IterationUse, errorNode:Node):IterationTypes {
		t = c.getReducedType(t);
		if (Checker.IsTypeAny(t)) {
			return newIterationTypes(c.anyType, c.anyType, c.anyType);
		}
		final key = IterationTypesKey.keyOf(t.id, use & IterationUseCacheFlags);
		// If we are reporting errors and encounter a cached `noIterationTypes`, we should ignore the cached value and continue as if nothing was cached.
		// In addition, we should not cache any new results for this call.
		var noCache = false;
		final cached = c.iterationTypesCache.get(key);
		if (cached != null) {
			if (errorNode == null || cached.hasTypes()) {
				return cached;
			}
			noCache = true;
		}
		final result = c.getIterationTypesOfIterableWorker(t, use, errorNode, noCache);
		if (!noCache) {
			c.iterationTypesCache.set(key, result);
		}
		return result;
	}

	static function getIterationTypesOfIterableWorker(c:Checker, t:Type, use:IterationUse, errorNode:Node, noCache:Bool):IterationTypes {
		if ((t.flags & TypeFlagsUnion) != 0) {
			final allIterationTypes:Array<IterationTypes> = [];
			for (constituent in t.Types()) {
				final iterationTypes = c.getIterationTypesOfIterableWorker(constituent, use, null, noCache);
				if (!iterationTypes.hasTypes()) {
					if (errorNode != null) {
						c.addDeferredDiagnostic(function() {
							c.reportTypeNotIterableError(errorNode, t, (use & IterationUseAllowsAsyncIterablesFlag) != 0);
						});
					}
					return new IterationTypes();
				}
				allIterationTypes.push(iterationTypes);
			}
			return c.combineIterationTypes(allIterationTypes);
		}
		final diags:Array<Diagnostic> = [];
		if ((use & IterationUseAllowsAsyncIterablesFlag) != 0) {
			var iterationTypes = c.getIterationTypesOfIterableFast(t, c.asyncIterationTypesResolver);
			if (iterationTypes.hasTypes()) {
				if ((use & IterationUseForOfFlag) != 0) {
					return c.getAsyncFromSyncIterationTypes(iterationTypes, errorNode);
				}
				return iterationTypes;
			}
			iterationTypes = c.getIterationTypesOfIterableSlow(t, c.asyncIterationTypesResolver, errorNode, diags);
			if (iterationTypes.hasTypes()) {
				if (diags.length != 0) {
					for (d in diags) {
						c.addDiagnostic(d);
					}
				}
				return iterationTypes;
			}
		}
		if ((use & IterationUseAllowsSyncIterablesFlag) != 0) {
			var iterationTypes = c.getIterationTypesOfIterableFast(t, c.syncIterationTypesResolver);
			if (iterationTypes.hasTypes()) {
				if ((use & IterationUseAllowsAsyncIterablesFlag) != 0) {
					return c.getAsyncFromSyncIterationTypes(iterationTypes, errorNode);
				}
				return iterationTypes;
			}
			iterationTypes = c.getIterationTypesOfIterableSlow(t, c.syncIterationTypesResolver, errorNode, diags);
			if (iterationTypes.hasTypes()) {
				if (diags.length != 0) {
					for (d in diags) {
						c.addDiagnostic(d);
					}
				}
				if ((use & IterationUseAllowsAsyncIterablesFlag) != 0) {
					return c.getAsyncFromSyncIterationTypes(iterationTypes, errorNode);
				}
				return iterationTypes;
			}
		}
		if (errorNode != null) {
			// We defer the diagnostic because TypeToString may attempt to resolve symbols that are already being
			// resolved, possibly causing circularities.
			c.addDeferredDiagnostic(function() {
				final diagnostic = c.reportTypeNotIterableError(errorNode, t, (use & IterationUseAllowsAsyncIterablesFlag) != 0);
				for (d in diags) {
					diagnostic.AddRelatedInfo(d);
				}
			});
		}
		return new IterationTypes();
	}

	static function getIterationTypesOfIterableFast(c:Checker, t:Type, r:IterationTypesResolver):IterationTypes {
		// As an optimization, if the type is an instantiation of the following global type, then
		// just grab its related type arguments:
		// - `Iterable<T, TReturn, TNext>` or `AsyncIterable<T, TReturn, TNext>`
		// - `IteratorObject<T, TReturn, TNext>` or `AsyncIteratorObject<T, TReturn, TNext>`
		// - `IterableIterator<T, TReturn, TNext>` or `AsyncIterableIterator<T, TReturn, TNext>`
		// - `Generator<T, TReturn, TNext>` or `AsyncGenerator<T, TReturn, TNext>`
		if (c.isReferenceToType(t, r.getGlobalIterableType())
			|| c.isReferenceToType(t, r.getGlobalIteratorObjectType())
			|| c.isReferenceToType(t, r.getGlobalIterableIteratorType())
			|| c.isReferenceToType(t, r.getGlobalGeneratorType())) {
			final typeArguments = c.getTypeArguments(t);
			return r.getResolvedIterationTypes(typeArguments[0], typeArguments[1], typeArguments[2]);
		}
		// As an optimization, if the type is an instantiation of one of the following global types, then
		// just grab the related type argument:
		// - `ArrayIterator<T>`
		// - `MapIterator<T>`
		// - `SetIterator<T>`
		// - `StringIterator<T>`
		// - `ReadableStreamAsyncIterator<T>`
		if (c.isReferenceToSomeType(t, r.getGlobalBuiltinIteratorTypes())) {
			return r.getResolvedIterationTypes(c.getTypeArguments(t)[0], c.getBuiltinIteratorReturnType(), c.unknownType);
		}
		return new IterationTypes();
	}

	static function isReferenceToType(c:Checker, t:Type, target:Type):Bool {
		return t != null && (t.objectFlags & ObjectFlagsReference) != 0 && t.Target() == target;
	}

	static function isReferenceToSomeType(c:Checker, t:Type, targets:Array<Type>):Bool {
		return t != null && (t.objectFlags & ObjectFlagsReference) != 0 && targets != null && targets.indexOf(t.Target()) >= 0;
	}

	static function getBuiltinIteratorReturnType(c:Checker):Type {
		return Core.IfElse(c.strictBuiltinIteratorReturn, c.undefinedType, c.anyType);
	}

	static function combineIterationTypes(c:Checker, iterationTypes:Array<IterationTypes>):IterationTypes {
		return newIterationTypes(c.getIterationTypeUnion(iterationTypes, t -> t.yieldType), c.getIterationTypeUnion(iterationTypes, t -> t.returnType),
			c.getIterationTypeUnion(iterationTypes, t -> t.nextType));
	}

	static function getIterationTypeUnion(c:Checker, iterationTypes:Array<IterationTypes>, f:(IterationTypes) -> Type):Type {
		final types = Core.MapNonNil(iterationTypes, f);
		if (Core.len(types) == 0) {
			return null;
		}
		return c.getUnionType(types);
	}

	static function getAsyncFromSyncIterationTypes(c:Checker, iterationTypes:IterationTypes, errorNode:Node):IterationTypes {
		if (!iterationTypes.hasTypes()
			|| iterationTypes.yieldType == c.anyType && iterationTypes.returnType == c.anyType && iterationTypes.nextType == c.anyType) {
			return iterationTypes;
		}
		// if we're requesting diagnostics, report errors for a missing `Awaited<T>`.
		if (errorNode != null) {
			c.getGlobalAwaitedSymbol();
		}
		return newIterationTypes(Core.OrElse(c.getAwaitedTypeEx(iterationTypes.yieldType, errorNode, null), c.anyType),
			Core.OrElse(c.getAwaitedTypeEx(iterationTypes.returnType, errorNode, null), c.anyType), iterationTypes.nextType);
	}

	// Gets the *yield*, *return*, and *next* types of an `Iterable`-like or `AsyncIterable`-like
	// type from its members.
	//
	// If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
	// members is returned. Otherwise, a default `IterationTypes{}` is returned.
	//
	// NOTE: You probably don't want to call this directly and should be calling
	// `getIterationTypesOfIterable` instead.
	static function getIterationTypesOfIterableSlow(c:Checker, t:Type, r:IterationTypesResolver, errorNode:Node, diagnosticOutput:Array<Diagnostic>):IterationTypes {
		final method = c.getPropertyOfType(t, c.getPropertyNameForKnownSymbolName(r.iteratorSymbolName));
		if (method != null && (method.Flags & SymbolFlagsOptional) == 0) {
			final methodType = c.getTypeOfSymbol(method);
			if (Checker.IsTypeAny(methodType)) {
				return newIterationTypes(c.anyType, c.anyType, c.anyType);
			}
			final allSignatures = c.getSignaturesOfType(methodType, SignatureKindCall);
			final validSignatures = Core.Filter(allSignatures, sig -> c.getMinArgumentCount(sig) == 0);
			if (Core.len(validSignatures) != 0) {
				final iteratorType = c.getIntersectionType(Core.Map(validSignatures, s -> c.getReturnTypeOfSignature(s)));
				return c.getIterationTypesOfIteratorWorker(iteratorType, r, errorNode, diagnosticOutput);
			}
			if (errorNode != null && Core.len(allSignatures) != 0) {
				c.checkTypeAssignableToEx(t, r.getGlobalIterableTypeChecked(), errorNode, null, diagnosticOutput);
			}
		}
		return new IterationTypes();
	}

	// Gets the *yield*, *return*, and *next* types from an `Iterator`-like or `AsyncIterator`-like type.
	//
	// If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
	// members is returned. Otherwise, a default `IterationTypes{}` is returned.
	static function getIterationTypesOfIterator(c:Checker, t:Type, r:IterationTypesResolver, errorNode:Node, diagnosticOutput:Array<Diagnostic>):IterationTypes {
		return c.getIterationTypesOfIteratorWorker(t, r, errorNode, diagnosticOutput);
	}

	// Gets the *yield*, *return*, and *next* types from an `Iterator`-like or `AsyncIterator`-like type.
	//
	// If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
	// members is returned. Otherwise, a default `IterationTypes{}` is returned.
	//
	// NOTE: You probably don't want to call this directly and should be calling `getIterationTypesOfIterator` instead.
	static function getIterationTypesOfIteratorWorker(c:Checker, t:Type, r:IterationTypesResolver, errorNode:Node, diagnosticOutput:Array<Diagnostic>):IterationTypes {
		if (Checker.IsTypeAny(t)) {
			return newIterationTypes(c.anyType, c.anyType, c.anyType);
		}
		final iterationTypes = c.getIterationTypesOfIteratorFast(t, r);
		if (iterationTypes.hasTypes()) {
			return iterationTypes;
		}
		return c.getIterationTypesOfIteratorSlow(t, r, errorNode, diagnosticOutput);
	}

	static function getIterationTypesOfIteratorFast(c:Checker, t:Type, r:IterationTypesResolver):IterationTypes {
		// As an optimization, if the type is an instantiation of the following global type, then
		// just grab its related type arguments:
		// - `Iterable<T, TReturn, TNext>` or `AsyncIterable<T, TReturn, TNext>`
		// - `IteratorObject<T, TReturn, TNext>` or `AsyncIteratorObject<T, TReturn, TNext>`
		// - `IterableIterator<T, TReturn, TNext>` or `AsyncIterableIterator<T, TReturn, TNext>`
		// - `Generator<T, TReturn, TNext>` or `AsyncGenerator<T, TReturn, TNext>`
		if (c.isReferenceToType(t, r.getGlobalIteratorType())
			|| c.isReferenceToType(t, r.getGlobalIteratorObjectType())
			|| c.isReferenceToType(t, r.getGlobalIterableIteratorType())
			|| c.isReferenceToType(t, r.getGlobalGeneratorType())) {
			final typeArguments = c.getTypeArguments(t);
			return r.getResolvedIterationTypes(typeArguments[0], typeArguments[1], typeArguments[2]);
		}
		// As an optimization, if the type is an instantiation of one of the following global types, then
		// just grab the related type argument:
		// - `ArrayIterator<T>`
		// - `MapIterator<T>`
		// - `SetIterator<T>`
		// - `StringIterator<T>`
		// - `ReadableStreamAsyncIterator<T>`
		if (c.isReferenceToSomeType(t, r.getGlobalBuiltinIteratorTypes())) {
			return r.getResolvedIterationTypes(c.getTypeArguments(t)[0], c.getBuiltinIteratorReturnType(), c.unknownType);
		}
		return new IterationTypes();
	}

	static function getIterationTypesOfIteratorSlow(c:Checker, t:Type, r:IterationTypesResolver, errorNode:Node, diagnosticOutput:Array<Diagnostic>):IterationTypes {
		return c.combineIterationTypes([
			c.getIterationTypesOfMethod(t, r, "next", errorNode, diagnosticOutput),
			c.getIterationTypesOfMethod(t, r, "return", errorNode, diagnosticOutput),
			c.getIterationTypesOfMethod(t, r, "throw", errorNode, diagnosticOutput)
		]);
	}

	static function getIterationTypesOfMethod(c:Checker, t:Type, resolver:IterationTypesResolver, methodName:std.String, errorNode:Node, diagnosticOutput:Array<Diagnostic>):IterationTypes {
		final method = c.getPropertyOfType(t, methodName);
		// Ignore 'return' or 'throw' if they are missing.
		if (method == null && methodName != "next") {
			return new IterationTypes();
		}
		var methodType:Type = null;
		if (method != null && !(methodName == "next" && (method.Flags & SymbolFlagsOptional) != 0)) {
			if (methodName == "next") {
				methodType = c.getTypeOfSymbol(method);
			} else {
				methodType = c.getTypeWithFacts(c.getTypeOfSymbol(method), TypeFactsNEUndefinedOrNull);
			}
		}
		if (Checker.IsTypeAny(methodType)) {
			return newIterationTypes(c.anyType, c.anyType, c.anyType);
		}
		// Both async and non-async iterators *must* have a `next` method.
		var methodSignatures:Array<Signature> = null;
		if (methodType != null) {
			methodSignatures = c.getSignaturesOfType(methodType, SignatureKindCall);
		}
		if (Core.len(methodSignatures) == 0) {
			if (errorNode != null) {
				final diagnostic = Core.IfElse(methodName == "next", resolver.mustHaveANextMethodDiagnostic, resolver.mustBeAMethodDiagnostic);
				c.reportDiagnostic(Checker.NewDiagnosticForNode(errorNode, diagnostic, methodName), diagnosticOutput);
			}
			return new IterationTypes();
		}
		// If the method signature comes exclusively from the global iterator or generator type,
		// create iteration types from its type arguments like `getIterationTypesOfIteratorFast`
		// does (so as to remove `undefined` from the next and return types). We arrive here when
		// a contextual type for a generator was not a direct reference to one of those global types,
		// but looking up `methodType` referred to one of them (and nothing else). E.g., in
		// `interface SpecialIterator extends Iterator<number> {}`, `SpecialIterator` is not a
		// reference to `Iterator`, but its `next` member derives exclusively from `Iterator`.
		if (methodSignatures.length == 1 && methodType.symbol != null) {
			final globalGeneratorType = resolver.getGlobalGeneratorType();
			final globalIteratorType = resolver.getGlobalIteratorType();
			final isGeneratorMethod = globalGeneratorType.symbol != null && symbolTableGet(globalGeneratorType.symbol.Members, methodName) == methodType.symbol;
			final isIteratorMethod = !isGeneratorMethod && globalIteratorType.symbol != null
				&& symbolTableGet(globalIteratorType.symbol.Members, methodName) == methodType.symbol;
			if (isGeneratorMethod || isIteratorMethod) {
				final typeParameters = Core.IfElse(isGeneratorMethod, globalGeneratorType, globalIteratorType).AsInterfaceType().TypeParameters();
				final mapper = methodType.Mapper();
				var nextType:Type = null;
				if (methodName == "next") {
					nextType = mapper.Map(typeParameters[2]);
				}
				return newIterationTypes(mapper.Map(typeParameters[0]), mapper.Map(typeParameters[1]), nextType);
			}
		}
		// Extract the first parameter and return type of each signature.
		var methodParameterTypes:Array<Type> = null;
		var methodReturnTypes:Array<Type> = null;
		for (signature in methodSignatures) {
			if (methodName != "throw" && Core.len(signature.parameters) != 0) {
				if (methodParameterTypes == null) {
					methodParameterTypes = [];
				}
				methodParameterTypes.push(c.getTypeAtPosition(signature, 0));
			}
			if (methodReturnTypes == null) {
				methodReturnTypes = [];
			}
			methodReturnTypes.push(c.getReturnTypeOfSignature(signature));
		}
		// Resolve the *next* or *return* type from the first parameter of a `next()` or
		// `return()` method, respectively.
		var returnTypes:Array<Type> = null;
		var nextType:Type = null;
		if (methodName != "throw") {
			var methodParameterType:Type = null;
			if (methodParameterTypes != null) {
				methodParameterType = c.getUnionType(methodParameterTypes);
			} else {
				methodParameterType = c.unknownType;
			}
			if (methodName == "next") {
				// The value of `next(value)` is *not* awaited by async generators
				nextType = methodParameterType;
			} else if (methodName == "return") {
				// The value of `return(value)` *is* awaited by async generators
				final resolvedMethodParameterType = Core.OrElse(resolver.resolveIterationType(methodParameterType, errorNode), c.anyType);
				if (returnTypes == null) {
					returnTypes = [];
				}
				returnTypes.push(resolvedMethodParameterType);
			}
		}
		// Resolve the *yield* and *return* types from the return type of the method (i.e. `IteratorResult`)
		var yieldType:Type = null;
		var methodReturnType:Type = null;
		if (methodReturnTypes != null) {
			methodReturnType = c.getIntersectionType(methodReturnTypes);
		} else {
			methodReturnType = c.neverType;
		}
		final resolvedMethodReturnType = Core.OrElse(resolver.resolveIterationType(methodReturnType, errorNode), c.anyType);
		final iterationTypes = c.getIterationTypesOfIteratorResult(resolvedMethodReturnType);
		if (returnTypes == null) {
			returnTypes = [];
		}
		if (!iterationTypes.hasTypes()) {
			if (errorNode != null) {
				c.reportDiagnostic(Checker.NewDiagnosticForNode(errorNode, resolver.mustHaveAValueDiagnostic, methodName), diagnosticOutput);
			}
			yieldType = c.anyType;
			returnTypes.push(c.anyType);
		} else {
			yieldType = iterationTypes.yieldType;
			returnTypes.push(iterationTypes.returnType);
		}
		return newIterationTypes(yieldType, c.getUnionType(returnTypes), nextType);
	}

	// Gets the *yield* and *return* types of an `IteratorResult`-like type.
	//
	// If we are unable to determine a *yield* or a *return* type, `noIterationTypes` is
	// returned to indicate to the caller that it should handle the error. Otherwise, an
	// `IterationTypes` record is returned.
	static function getIterationTypesOfIteratorResult(c:Checker, t:Type):IterationTypes {
		if (Checker.IsTypeAny(t)) {
			return newIterationTypes(c.anyType, c.anyType, c.anyType);
		}
		// As an optimization, if the type is an instantiation of one of the global `IteratorYieldResult<T>`
		// or `IteratorReturnResult<TReturn>` types, then just grab its type argument.
		if (c.isReferenceToType(t, c.getGlobalIteratorYieldResultType())) {
			return newIterationTypes(c.getTypeArguments(t)[0], null, null);
		}
		if (c.isReferenceToType(t, c.getGlobalIteratorReturnResultType())) {
			return newIterationTypes(null, c.getTypeArguments(t)[0], null);
		}
		// Choose any constituents that can produce the requested iteration type.
		final yieldIteratorResult = c.filterType(t, t -> c.isYieldIteratorResult(t));
		var yieldType:Type = null;
		if (yieldIteratorResult != c.neverType) {
			yieldType = c.getTypeOfPropertyOfType(yieldIteratorResult, "value" /* as __String */);
		}
		final returnIteratorResult = c.filterType(t, t -> c.isReturnIteratorResult(t));
		var returnType:Type = null;
		if (returnIteratorResult != c.neverType) {
			returnType = c.getTypeOfPropertyOfType(returnIteratorResult, "value" /* as __String */);
		}
		if (yieldType == null && returnType == null) {
			return new IterationTypes();
		}
		// From https://tc39.github.io/ecma262/#sec-iteratorresult-interface
		// > ... If the iterator does not have a return value, `value` is `undefined`. In that case, the
		// > `value` property may be absent from the conforming object if it does not inherit an explicit
		// > `value` property.
		return newIterationTypes(yieldType, Core.OrElse(returnType, c.voidType), null);
	}

	static function isYieldIteratorResult(c:Checker, t:Type):Bool {
		return c.isIteratorResult(t, IterationTypeKindYield);
	}

	static function isReturnIteratorResult(c:Checker, t:Type):Bool {
		return c.isIteratorResult(t, IterationTypeKindReturn);
	}

	static function isIteratorResult(c:Checker, t:Type, kind:IterationTypeKind):Bool {
		// From https://tc39.github.io/ecma262/#sec-iteratorresult-interface:
		// > [done] is the result status of an iterator `next` method call. If the end of the iterator was reached `done` is `true`.
		// > If the end was not reached `done` is `false` and a value is available.
		// > If a `done` property (either own or inherited) does not exist, it is consider to have the value `false`.
		final doneType = Core.OrElse(c.getTypeOfPropertyOfType(t, "done"), c.falseType);
		return c.isTypeAssignableTo(Core.IfElse(kind == IterationTypeKindYield, c.falseType, c.trueType), doneType);
	}

	static function reportTypeNotIterableError(c:Checker, errorNode:Node, t:Type, allowAsyncIterables:Bool):Diagnostic {
		var message:Message = null;
		if (allowAsyncIterables) {
			message = Diagnostics.Type_0_must_have_a_Symbol_asyncIterator_method_that_returns_an_async_iterator;
		} else {
			message = Diagnostics.Type_0_must_have_a_Symbol_iterator_method_that_returns_an_iterator;
		}
		final suggestAwait = c.getAwaitedTypeOfPromise(t) != null
			|| (!allowAsyncIterables
				&& Ast.IsForOfStatement(errorNode.Parent)
				&& errorNode.Parent.Expression() == errorNode
				&& c.getGlobalAsyncIterableType() != c.emptyGenericType
				&& c.isTypeAssignableTo(t, c.createTypeFromGenericGlobalType(c.getGlobalAsyncIterableType(), [c.anyType, c.anyType, c.anyType])));
		return c.errorAndMaybeSuggestAwait(errorNode, suggestAwait, message, c.TypeToString(t));
	}

	static function getIterationDiagnosticDetails(c:Checker, use:IterationUse, inputType:Type, allowsStrings:Bool):ValueOk<Message> {
		final yieldType = c.getIterationTypeOfIterable(use, IterationTypeKindYield, inputType, null /*errorNode*/);
		if (yieldType != null) {
			return new ValueOk(Diagnostics.Type_0_can_only_be_iterated_through_when_using_the_downlevelIteration_flag_or_with_a_target_of_es2015_or_higher,
				false);
		}
		if (inputType.symbol != null && Checker.isES2015OrLaterIterable(inputType.symbol.Name)) {
			return new ValueOk(Diagnostics.Type_0_can_only_be_iterated_through_when_using_the_downlevelIteration_flag_or_with_a_target_of_es2015_or_higher,
				true);
		}
		if (allowsStrings) {
			return new ValueOk(Diagnostics.Type_0_is_not_an_array_type_or_a_string_type, true);
		}
		return new ValueOk(Diagnostics.Type_0_is_not_an_array_type, true);
	}

	static function checkAliasSymbol(c:Checker, node:Node):Void {
		var symbol = c.getSymbolOfDeclaration(node);
		final target = c.resolveAlias(symbol);
		if (target == c.unknownSymbol) {
			return;
		}
		// For external modules, `symbol` represents the local symbol for an alias.
		// This local symbol will merge any other local declarations (excluding other aliases)
		// and symbol.flags will contains combined representation for all merged declaration.
		// Based on symbol.flags we can compute a set of excluded meanings (meaning that resolved alias should not have,
		// otherwise it will conflict with some local declaration). Note that in addition to normal flags we include matching SymbolFlags.Export*
		// in order to prevent collisions with declarations that were exported from the current module (they still contribute to local names).
		symbol = c.getMergedSymbol(Core.OrElse(symbol.ExportSymbol, symbol));
		final targetFlags = c.getSymbolFlags(target);
		// A type-only import/export will already have a grammar error in a JS file, so no need to issue more errors within
		if (Ast.IsInJSFile(node) && (targetFlags & SymbolFlagsValue) == 0 && !Ast.IsTypeOnlyImportOrExportDeclaration(node)) {
			final errorNode = Core.OrElse(node.PropertyNameOrName(), node);
			Debug.Assert(node.Kind != KindNamespaceExport);
			if (Ast.IsExportSpecifier(node)) {
				final diag = c.error(errorNode, Diagnostics.Types_cannot_appear_in_export_declarations_in_JavaScript_files);
				final sourceSymbol = Ast.GetSourceFileOfNode(node).AsNode().Symbol();
				if (sourceSymbol != null) {
					final alreadyExportedSymbol = symbolTableGet(sourceSymbol.Exports, node.PropertyNameOrName().Text());
					if (alreadyExportedSymbol == target) {
						final exportingDeclaration = Core.Find(alreadyExportedSymbol.Declarations, Ast.IsJSTypeAliasDeclaration);
						if (exportingDeclaration != null) {
							diag.AddRelatedInfo(Checker.NewDiagnosticForNode(exportingDeclaration, Diagnostics.X_0_is_automatically_exported_here,
								alreadyExportedSymbol.Name));
						}
					}
				}
			} else {
				var identifierText = symbol.Name;
				if (Ast.IsIdentifier(errorNode)) {
					identifierText = errorNode.Text();
				}
				var specifierText = "...";
				final importDeclaration = Ast.FindAncestor(node, function(n:Node):Bool {
					return Ast.IsImportOrImportEqualsDeclaration(n) || Ast.IsVariableDeclaration(n);
				});
				if (importDeclaration != null) {
					final moduleSpecifier = Checker.TryGetModuleSpecifierFromDeclaration(importDeclaration);
					if (moduleSpecifier != null) {
						specifierText = moduleSpecifier.Text();
					}
				}
				var importText = "import(\"" + specifierText + "\")";
				if (Ast.IsImportSpecifier(node)) {
					importText = importText + "." + identifierText;
				}
				c.error(errorNode, Diagnostics.X_0_is_a_type_and_cannot_be_imported_in_JavaScript_files_Use_1_in_a_JSDoc_type_annotation, identifierText,
					importText);
			}
			return;
		}
		final excludedMeanings:SymbolFlags = Core.IfElse((symbol.Flags & (SymbolFlagsValue | SymbolFlagsExportValue)) != 0, SymbolFlagsValue, (0 : SymbolFlags))
			| Core.IfElse((symbol.Flags & SymbolFlagsType) != 0, SymbolFlagsType, (0 : SymbolFlags))
			| Core.IfElse((symbol.Flags & SymbolFlagsNamespace) != 0, SymbolFlagsNamespace, (0 : SymbolFlags));
		if ((targetFlags & excludedMeanings) != 0) {
			final message = Core.IfElse(Ast.IsExportSpecifier(node), Diagnostics.Export_declaration_conflicts_with_exported_declaration_of_0,
				Diagnostics.Import_declaration_conflicts_with_local_declaration_of_0);
			c.error(node, message, c.symbolToString(symbol));
		} else if (!Ast.IsExportSpecifier(node)) {
			// Look at 'compilerOptions.isolatedModules' and not 'getIsolatedModules(...)' (which considers 'verbatimModuleSyntax')
			// here because 'verbatimModuleSyntax' will already have an error for importing a type without 'import type'.
			final appearsValueyToTranspiler = c.compilerOptions.IsolatedModules.IsTrue()
				&& Ast.FindAncestor(node, Ast.IsTypeOnlyImportOrExportDeclaration) == null;
			if (appearsValueyToTranspiler && (symbol.Flags & (SymbolFlagsValue | SymbolFlagsExportValue)) != 0) {
				c.error(node, Diagnostics.Import_0_conflicts_with_local_value_so_must_be_declared_with_a_type_only_import_when_isolatedModules_is_enabled,
					c.symbolToString(symbol), c.getIsolatedModulesLikeFlagName());
			}
		}
		if (c.compilerOptions.GetIsolatedModules() && !Ast.IsTypeOnlyImportOrExportDeclaration(node) && (node.Flags & NodeFlagsAmbient) == 0) {
			final typeOnlyAlias = c.getTypeOnlyAliasDeclaration(symbol);
			final isType = (targetFlags & SymbolFlagsValue) == 0;
			if (isType || typeOnlyAlias != null) {
				switch (node.Kind) {
					case KindImportClause | KindImportSpecifier | KindImportEqualsDeclaration:
						if (c.compilerOptions.VerbatimModuleSyntax.IsTrue()) {
							Debug.Assert(node.Name() != null, "An ImportClause with a symbol should have a name");
							var message:Message = null;
							if (c.compilerOptions.VerbatimModuleSyntax.IsTrue() && Ast.IsInternalModuleImportEqualsDeclaration(node)) {
								message = Diagnostics.An_import_alias_cannot_resolve_to_a_type_or_type_only_declaration_when_verbatimModuleSyntax_is_enabled;
							} else if (isType) {
								message = Diagnostics.X_0_is_a_type_and_must_be_imported_using_a_type_only_import_when_verbatimModuleSyntax_is_enabled;
							} else {
								message = Diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_imported_using_a_type_only_import_when_verbatimModuleSyntax_is_enabled;
							}
							final name = node.PropertyNameOrName().Text();
							c.addTypeOnlyDeclarationRelatedInfo(c.error(node, message, name), Core.IfElse(isType, null, typeOnlyAlias), name);
						}
						if (isType && node.Kind == KindImportEqualsDeclaration && Ast.HasModifier(node, ModifierFlagsExport)) {
							c.error(node, Diagnostics.Cannot_use_export_import_on_a_type_or_type_only_namespace_when_0_is_enabled, c.getIsolatedModulesLikeFlagName());
						}
					case KindExportSpecifier:
						// Don't allow re-exporting an export that will be elided when `--isolatedModules` is set.
						// The exception is that `import type { A } from './a'; export { A }` is allowed
						// because single-file analysis can determine that the export should be dropped.
						if (c.compilerOptions.VerbatimModuleSyntax.IsTrue() || Ast.GetSourceFileOfNode(typeOnlyAlias) != Ast.GetSourceFileOfNode(node)) {
							final name = node.PropertyNameOrName().Text();
							var diagnostic:Diagnostic = null;
							if (isType) {
								diagnostic = c.error(node, Diagnostics.Re_exporting_a_type_when_0_is_enabled_requires_using_export_type, c.getIsolatedModulesLikeFlagName());
							} else {
								diagnostic = c.error(node,
									Diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_re_exported_using_a_type_only_re_export_when_1_is_enabled, name,
									c.getIsolatedModulesLikeFlagName());
							}
							c.addTypeOnlyDeclarationRelatedInfo(diagnostic, Core.IfElse(isType, null, typeOnlyAlias), name);
						}
					default:
				}
			}
			if (c.compilerOptions.VerbatimModuleSyntax.IsTrue() && !Ast.IsImportEqualsDeclaration(node) && !Ast.IsInJSFile(node)
				&& c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
				c.error(node, Checker.getVerbatimModuleSyntaxErrorMessage(node));
			} else if (c.moduleKind == ModuleKindPreserve && !Ast.IsImportEqualsDeclaration(node) && !Ast.IsVariableDeclaration(node)
				&& c.program.GetEmitModuleFormatOfFile(hasFileName(Ast.GetSourceFileOfNode(node))) == ModuleKindCommonJS) {
				// In `--module preserve`, ESM input syntax emits ESM output syntax, but there will be times
				// when we look at the `impliedNodeFormat` of this file and decide it's CommonJS (i.e., currently,
				// only if the file extension is .cjs/.cts). To avoid that inconsistency, we disallow ESM syntax
				// in files that are unambiguously CommonJS in this mode.
				c.error(node, Diagnostics.ECMAScript_module_syntax_is_not_allowed_in_a_CommonJS_module_when_module_is_set_to_preserve);
			}
			if (c.compilerOptions.VerbatimModuleSyntax.IsTrue() && !Ast.IsTypeOnlyImportOrExportDeclaration(node) && (node.Flags & NodeFlagsAmbient) == 0
				&& (targetFlags & SymbolFlagsConstEnum) != 0) {
				final constEnumDeclaration = target.ValueDeclaration;
				final redirect = c.program.GetProjectReferenceFromOutputDts(Ast.GetSourceFileOfNode(constEnumDeclaration).Path());
				if ((constEnumDeclaration.Flags & NodeFlagsAmbient) != 0 && (redirect == null || !redirect.Resolved.CompilerOptions().ShouldPreserveConstEnums())) {
					c.error(node, Diagnostics.Cannot_access_ambient_const_enums_when_0_is_enabled, c.getIsolatedModulesLikeFlagName());
				}
			}
		}
		if (Ast.IsImportSpecifier(node)) {
			final targetSymbol = c.resolveAliasWithDeprecationCheck(symbol, node);
			if (c.isDeprecatedSymbol(targetSymbol) && targetSymbol.Declarations != null) {
				c.addDeprecatedSuggestion(node, targetSymbol.Declarations, targetSymbol.Name);
			}
		}
	}

	static function areDeclarationFlagsIdentical(c:Checker, left:Declaration, right:Declaration):Bool {
		if (Ast.IsParameterDeclaration(left) && Ast.IsVariableDeclaration(right) || Ast.IsVariableDeclaration(left) && Ast.IsParameterDeclaration(right)) {
			// Differences in optionality between parameters and variables are allowed.
			return true;
		}
		if (Checker.isOptionalDeclaration(left) != Checker.isOptionalDeclaration(right)) {
			return false;
		}
		final interestingFlags = ModifierFlagsPrivate | ModifierFlagsProtected | ModifierFlagsAsync | ModifierFlagsAbstract | ModifierFlagsReadonly
			| ModifierFlagsStatic;
		return Checker.getSelectedModifierFlags(left, interestingFlags) == Checker.getSelectedModifierFlags(right, interestingFlags);
	}

	static function checkTypeAliasDeclaration(c:Checker, node:Node):Void {
		// Grammar checking
		c.checkGrammarModifiers(node);
		c.checkTypeNameIsReserved(node.Name(), Diagnostics.Type_alias_name_cannot_be_0);
		if (!c.containerAllowsBlockScopedVariable(node.Parent)) {
			c.grammarErrorOnNode(node, Diagnostics.X_0_declarations_can_only_be_declared_inside_a_block, "type");
		}
		c.checkExportsOnMergedDeclarations(node);

		final typeNode = node.Type();
		final typeParameters = node.TypeParameters();
		c.checkTypeParameters(typeParameters);
		if (typeNode != null && typeNode.Kind == KindIntrinsicKeyword) {
			if (!(Core.len(typeParameters) == 0 && node.Name().Text() == "BuiltinIteratorReturn"
				|| Core.len(typeParameters) == 1 && intrinsicTypeKindOf(node.Name().Text()) != IntrinsicTypeKindUnknown)) {
				c.error(typeNode, Diagnostics.The_intrinsic_keyword_can_only_be_used_to_declare_compiler_provided_intrinsic_types);
			}
			return;
		}
		c.checkSourceElement(typeNode);
		c.registerForUnusedIdentifiersCheck(node);
	}

	static function checkTypeNameIsReserved(c:Checker, name:Node, message:Message):Void {
		// TS 1.0 spec (April 2014): 3.6.1
		// The predefined type keywords are reserved and cannot be used as names of user defined types.
		switch (name.Text()) {
			case "any" | "unknown" | "never" | "number" | "bigint" | "boolean" | "string" | "symbol" | "void" | "object" | "undefined":
				c.error(name, message, name.Text());
			default:
		}
	}

	static function checkExportsOnMergedDeclarations(c:Checker, node:Node):Void {
		// If localSymbol is defined on node then node itself is exported - check is required.
		var symbol = node.LocalSymbol();
		if (symbol == null) {
			// Local symbol is undefined => this declaration is non-exported.
			// However, symbol might contain other declarations that are exported.
			symbol = c.getSymbolOfDeclaration(node);
			if (symbol.ExportSymbol == null) {
				// This is a pure local symbol (all declarations are non-exported) - no need to check anything.
				return;
			}
		}
		// Run the check only for the first declaration in the list.
		if (Ast.GetDeclarationOfKind(symbol, node.Kind) != node) {
			return;
		}
		var exportedDeclarationSpaces = DeclarationSpacesNone;
		var nonExportedDeclarationSpaces = DeclarationSpacesNone;
		var defaultExportedDeclarationSpaces = DeclarationSpacesNone;
		for (d in rangeOf(symbol.Declarations)) {
			final declarationSpaces = c.getDeclarationSpaces(d);
			final effectiveDeclarationFlags = c.getEffectiveDeclarationFlags(d, ModifierFlagsExport | ModifierFlagsDefault);
			if ((effectiveDeclarationFlags & ModifierFlagsExport) != 0) {
				if ((effectiveDeclarationFlags & ModifierFlagsDefault) != 0) {
					defaultExportedDeclarationSpaces |= declarationSpaces;
				} else {
					exportedDeclarationSpaces |= declarationSpaces;
				}
			} else {
				nonExportedDeclarationSpaces |= declarationSpaces;
			}
		}
		// Spaces for anything not declared a 'default export'.
		final nonDefaultExportedDeclarationSpaces = exportedDeclarationSpaces | nonExportedDeclarationSpaces;
		final commonDeclarationSpacesForExportsAndLocals = exportedDeclarationSpaces & nonExportedDeclarationSpaces;
		final commonDeclarationSpacesForDefaultAndNonDefault = defaultExportedDeclarationSpaces & nonDefaultExportedDeclarationSpaces;
		if (commonDeclarationSpacesForExportsAndLocals != 0 || commonDeclarationSpacesForDefaultAndNonDefault != 0) {
			// declaration spaces for exported and non-exported declarations intersect
			for (d in symbol.Declarations) {
				final declarationSpaces = c.getDeclarationSpaces(d);
				final name = Ast.GetNameOfDeclaration(d);
				// Only error on the declarations that contributed to the intersecting spaces.
				if ((declarationSpaces & commonDeclarationSpacesForDefaultAndNonDefault) != 0) {
					c.error(name,
						Diagnostics.Merged_declaration_0_cannot_include_a_default_export_declaration_Consider_adding_a_separate_export_default_0_declaration_instead,
						Scanner.DeclarationNameToString(name));
				} else if ((declarationSpaces & commonDeclarationSpacesForExportsAndLocals) != 0) {
					c.error(name, Diagnostics.Individual_declarations_in_merged_declaration_0_must_be_all_exported_or_all_local,
						Scanner.DeclarationNameToString(name));
				}
			}
		}
	}

	static function getDeclarationSpaces(c:Checker, node:Declaration):DeclarationSpaces {
		// PORT: Go `fallthrough` from the export-assignment case into the alias case.
		function aliasCase():DeclarationSpaces {
			var result = DeclarationSpacesNone;
			final target = c.resolveAlias(c.getSymbolOfDeclaration(node));
			for (d in rangeOf(target.Declarations)) {
				result |= c.getDeclarationSpaces(d);
			}
			return result;
		}
		switch (node.Kind) {
			case KindInterfaceDeclaration | KindTypeAliasDeclaration | KindJSTypeAliasDeclaration | KindJSDocTypedefTag | KindJSDocCallbackTag:
				return DeclarationSpacesExportType;
			case KindModuleDeclaration:
				if (Ast.IsAmbientModule(node) || Ast.GetModuleInstanceState(node) != ModuleInstanceStateNonInstantiated) {
					return DeclarationSpacesExportNamespace | DeclarationSpacesExportValue;
				}
				return DeclarationSpacesExportNamespace;
			case KindClassDeclaration | KindEnumDeclaration | KindEnumMember:
				return DeclarationSpacesExportType | DeclarationSpacesExportValue;
			case KindSourceFile:
				return DeclarationSpacesExportType | DeclarationSpacesExportValue | DeclarationSpacesExportNamespace;
			case KindExportAssignment | KindBinaryExpression:
				var expression:Node = null;
				if (Ast.IsExportAssignment(node)) {
					expression = node.Expression();
				} else {
					expression = node.AsBinaryExpression().Right;
				}
				// Export assigned entity name expressions act as aliases and should fall through, otherwise they export values.
				if (!Ast.IsEntityNameExpression(expression) || (c.getSymbolOfDeclaration(node).Flags & SymbolFlagsAlias) == 0) {
					return DeclarationSpacesExportValue;
				}
				// The below options all declare an Alias, which is allowed to merge with other values within the importing module.
				return aliasCase();
			case KindImportEqualsDeclaration | KindNamespaceImport | KindImportClause:
				return aliasCase();
			case KindVariableDeclaration | KindBindingElement | KindFunctionDeclaration | KindImportSpecifier:
				return DeclarationSpacesExportValue;
			case KindMethodSignature | KindPropertySignature:
				return DeclarationSpacesExportType;
			default:
		}
		throw "Unhandled case in getDeclarationSpaces: " + node.Kind.String();
	}

	static function checkTypeParameters(c:Checker, typeParameterDeclarations:Array<Node>):Void {
		var seenDefault = false;
		if (typeParameterDeclarations == null) {
			return;
		}
		for (i in 0...typeParameterDeclarations.length) {
			final node = typeParameterDeclarations[i];
			c.checkTypeParameter(node);
			final defaultTypeNode = node.AsTypeParameterDeclaration().DefaultType;
			if (defaultTypeNode != null) {
				seenDefault = true;
				c.checkTypeParametersNotReferenced(defaultTypeNode, typeParameterDeclarations, i);
			} else if (seenDefault) {
				c.error(node, Diagnostics.Required_type_parameters_may_not_follow_optional_type_parameters);
			}
			for (j in 0...i) {
				if (typeParameterDeclarations[j].Symbol() == node.Symbol()) {
					c.error(node.Name(), Diagnostics.Duplicate_identifier_0, Scanner.DeclarationNameToString(node.Name()));
				}
			}
		}
	}

	// Check that type parameter defaults only reference previously declared type parameters */
	static function checkTypeParametersNotReferenced(c:Checker, root:Node, typeParameters:Array<Node>, index:Int):Void {
		var visit:(Node) -> Bool = null;
		visit = function(node:Node):Bool {
			if (Ast.IsTypeReferenceNode(node)) {
				final t = c.getTypeFromTypeReference(node);
				if ((t.flags & TypeFlagsTypeParameter) != 0) {
					for (i in index...Core.len(typeParameters)) {
						if (t.symbol == c.getSymbolOfDeclaration(typeParameters[i])) {
							c.error(node, Diagnostics.Type_parameter_defaults_can_only_reference_previously_declared_type_parameters);
						}
					}
				}
			}
			return node.ForEachChild(visit);
		};
		visit(root);
	}

	static function registerForUnusedIdentifiersCheck(c:Checker, node:Node):Void {
		final sourceFile = Ast.GetSourceFileOfNode(node);
		final links = c.sourceFileLinks.Get(sourceFile);
		if (links.identifierCheckNodes == null) {
			links.identifierCheckNodes = [];
		}
		links.identifierCheckNodes.push(node);
	}

	static function checkUnusedIdentifiers(c:Checker, potentiallyUnusedIdentifiers:Array<Node>):Void {
		for (node in rangeOf(potentiallyUnusedIdentifiers)) {
			switch (node.Kind) {
				case KindClassDeclaration | KindClassExpression:
					c.checkUnusedClassMembers(node);
					c.checkUnusedTypeParameters(node);
				case KindSourceFile | KindModuleDeclaration | KindBlock | KindCaseBlock | KindForStatement | KindForInStatement | KindForOfStatement:
					c.checkUnusedLocalsAndParameters(node);
				case KindConstructor | KindFunctionExpression | KindFunctionDeclaration | KindArrowFunction | KindMethodDeclaration | KindGetAccessor |
					KindSetAccessor:
					// Only report unused parameters on the implementation, not overloads.
					if (node.Body() != null) {
						c.checkUnusedLocalsAndParameters(node);
					}
					c.checkUnusedTypeParameters(node);
				case KindMethodSignature | KindCallSignature | KindConstructSignature | KindFunctionType | KindConstructorType | KindTypeAliasDeclaration |
					KindJSTypeAliasDeclaration | KindInterfaceDeclaration:
					c.checkUnusedTypeParameters(node);
				case KindInferType:
					c.checkUnusedInferTypeParameter(node);
				default:
					throw "Unhandled case in checkUnusedIdentifiers";
			}
		}
	}

	static function isReferenced(c:Checker, symbol:Symbol):Bool {
		return c.symbolReferenceLinks.Get(symbol).referenceKinds != 0;
	}

	static function reportUnusedVariable(c:Checker, location:Node, diagnostic:Diagnostic):Void {
		while (Ast.IsBindingElement(location) || Ast.IsBindingPattern(location)) {
			location = location.Parent;
		}
		c.reportUnused(location, Core.IfElse(Ast.IsParameterDeclaration(location), UnusedKindParameter, UnusedKindLocal), diagnostic);
	}

	static function reportUnused(c:Checker, location:Node, kind:UnusedKind, diagnostic:Diagnostic):Void {
		if ((location.Flags & (NodeFlagsAmbient | NodeFlagsThisNodeOrAnySubNodesHasError)) == 0) {
			final isError = c.unusedIsError(kind);
			if (isError) {
				c.addDiagnostic(diagnostic);
			} else {
				final suggestion = diagnostic.Clone();
				suggestion.SetCategory(CategorySuggestion);
				c.addSuggestionDiagnostic(suggestion);
			}
		}
	}

	static function unusedIsError(c:Checker, kind:UnusedKind):Bool {
		switch (kind) {
			case UnusedKindLocal:
				return c.compilerOptions.NoUnusedLocals.IsTrue();
			case UnusedKindParameter:
				return c.compilerOptions.NoUnusedParameters.IsTrue();
			default:
				throw "Unhandled case in unusedIsError";
		}
	}

	static function checkUnusedClassMembers(c:Checker, node:Node):Void {
		for (member in node.Members()) {
			switch (member.Kind) {
				case KindMethodDeclaration | KindPropertyDeclaration | KindGetAccessor | KindSetAccessor:
					// PORT: Go `break` out of the switch.
					if (Ast.IsSetAccessorDeclaration(member) && (member.Symbol().Flags & SymbolFlagsGetAccessor) != 0) {
						// Already would have reported an error on the getter.
					} else {
						final symbol = c.getSymbolOfDeclaration(member);
						if (!c.isReferenced(symbol)
							&& (Ast.HasModifier(member, ModifierFlagsPrivate) || member.Name() != null && Ast.IsPrivateIdentifier(member.Name()))
							&& (member.Flags & NodeFlagsAmbient) == 0) {
							c.reportUnused(member, UnusedKindLocal,
								Checker.NewDiagnosticForNode(member.Name(), Diagnostics.X_0_is_declared_but_its_value_is_never_read, c.symbolToString(symbol)));
						}
					}
				case KindConstructor:
					for (parameter in member.AsConstructorDeclaration().Parameters.Nodes) {
						if (!c.isReferenced(parameter.Symbol()) && Ast.HasSyntacticModifier(parameter, ModifierFlagsPrivate)) {
							c.reportUnused(parameter, UnusedKindLocal,
								Checker.NewDiagnosticForNode(parameter.Name(), Diagnostics.Property_0_is_declared_but_its_value_is_never_read,
									Ast.SymbolName(parameter.Symbol())));
						}
					}
				case KindIndexSignature | KindSemicolonClassElement | KindClassStaticBlockDeclaration | KindJSTypeAliasDeclaration:
					// Can't be private
				default:
					throw "Unhandled case in checkUnusedClassMembers";
			}
		}
	}

	static function checkUnusedLocalsAndParameters(c:Checker, node:Node):Void {
		final variableParents = new Set<Node>();
		var importClauses:IdentityMap<Node, Array<Node>> = null;
		final locals = node.Locals();
		if (locals != null) {
			for (local in locals) {
				final referenceKinds = c.symbolReferenceLinks.Get(local).referenceKinds;
				if ((local.Flags & SymbolFlagsTypeParameter) != 0 && ((local.Flags & SymbolFlagsVariable) == 0 || (referenceKinds & SymbolFlagsVariable) != 0)
					|| (local.Flags & SymbolFlagsTypeParameter) == 0
					&& (referenceKinds != 0 || local.ExportSymbol != null || (local.Flags & SymbolFlagsModuleExports) != 0)) {
					continue;
				}
				for (declaration in rangeOf(local.Declarations)) {
					if (Ast.IsVariableDeclaration(declaration) || Ast.IsParameterDeclaration(declaration) || Ast.IsBindingElement(declaration)) {
						variableParents.Add(Ast.GetRootDeclaration(declaration).Parent);
					} else if (Ast.IsImportClause(declaration) || Ast.IsImportSpecifier(declaration) || Ast.IsNamespaceImport(declaration)) {
						if (!Checker.isIdentifierThatStartsWithUnderscore(declaration.Name())) {
							if (importClauses == null) {
								importClauses = new IdentityMap<Node, Array<Node>>();
							}
							final importClause = Checker.importClauseFromImported(declaration);
							var list = importClauses.get(importClause);
							if (list == null) {
								list = [];
								importClauses.set(importClause, list);
							}
							list.push(declaration);
						}
					} else {
						if (!Ast.IsTypeParameterDeclaration(declaration) && !Ast.IsAmbientModule(declaration)) {
							c.reportUnusedLocal(declaration, Ast.SymbolName(local));
						}
					}
				}
			}
		}
		for (declaration in variableParents.Keys().keys()) {
			if (Ast.IsVariableDeclarationList(declaration)) {
				c.reportUnusedVariables(declaration);
			} else {
				c.reportUnusedParameters(declaration);
			}
		}
		if (importClauses != null) {
			for (declaration => unuseds in importClauses) {
				c.reportUnusedImports(declaration, unuseds);
			}
		}
	}

	static function reportUnusedLocal(c:Checker, node:Node, name:std.String):Void {
		final message = Core.IfElse(Ast.IsTypeDeclaration(node), Diagnostics.X_0_is_declared_but_never_used,
			Diagnostics.X_0_is_declared_but_its_value_is_never_read);
		c.reportUnused(node, UnusedKindLocal, Checker.NewDiagnosticForNode(Core.OrElse(node.Name(), node), message, name));
	}

	static function reportUnusedVariables(c:Checker, node:Node):Void {
		final declarations = node.AsVariableDeclarationList().Declarations.Nodes;
		if (Core.len(declarations) > 1 && Core.Every(declarations, d -> c.isUnreferencedVariableDeclaration(d))) {
			c.reportUnusedVariable(node, Checker.NewDiagnosticForNode(node, Diagnostics.All_variables_are_unused));
		} else {
			c.reportUnusedVariableDeclarations(declarations);
		}
	}

	static function reportUnusedParameters(c:Checker, node:Node):Void {
		c.reportUnusedVariableDeclarations(node.Parameters());
	}

	static function reportUnusedBindingElements(c:Checker, node:Node):Void {
		final declarations = node.Elements();
		if (Core.len(declarations) > 1 && Core.Every(declarations, d -> c.isUnreferencedVariableDeclaration(d))) {
			c.reportUnusedVariable(node, Checker.NewDiagnosticForNode(node, Diagnostics.All_destructured_elements_are_unused));
		} else {
			c.reportUnusedVariableDeclarations(declarations);
		}
	}

	static function reportUnusedVariableDeclarations(c:Checker, declarations:Array<Node>):Void {
		for (declaration in rangeOf(declarations)) {
			final name = declaration.Name();
			if (name != null && !Ast.IsParameterPropertyDeclaration(declaration, declaration.Parent) && !Ast.IsThisParameter(declaration)) {
				if (Ast.IsBindingPattern(name)) {
					c.reportUnusedBindingElements(name);
				} else if (c.isUnreferencedVariableDeclaration(declaration)) {
					c.reportUnusedVariable(declaration, Checker.NewDiagnosticForNode(name, Diagnostics.X_0_is_declared_but_its_value_is_never_read, name.Text()));
				}
			}
		}
	}

	static function isUnreferencedVariableDeclaration(c:Checker, node:Node):Bool {
		final name = node.Name();
		if (name == null) {
			return true;
		}
		if (Ast.IsBindingPattern(name)) {
			return Core.Every(node.Name().Elements(), n -> c.isUnreferencedVariableDeclaration(n));
		}
		if ((c.symbolReferenceLinks.Get(c.getSymbolOfDeclaration(node)).referenceKinds & SymbolFlagsVariable) != 0) {
			return false;
		}
		if (Ast.IsBindingElement(node) && Ast.IsObjectBindingPattern(node.Parent)) {
			// In `{ a, ...b }, `a` is considered used since it removes a property from `b`. `b` may still be unused though.
			final lastElement = Core.LastOrNil(node.Parent.Elements());
			if (node != lastElement && Checker.hasDotDotDotToken(lastElement)) {
				return false;
			}
		}
		if ((Ast.IsParameterDeclaration(node)
			|| Ast.IsVariableDeclaration(node)
			&& (Ast.IsForInOrOfStatement(node.Parent.Parent) || (c.getCombinedNodeFlagsCached(node) & NodeFlagsUsing) != 0)
			|| Ast.IsBindingElement(node) && !(Ast.IsObjectBindingPattern(node.Parent) && node.PropertyName() == null))
			&& Checker.isIdentifierThatStartsWithUnderscore(name)) {
			return false;
		}
		return true;
	}

	static function reportUnusedImports(c:Checker, node:Node, unuseds:Array<Node>):Void {
		var declarationCount = Core.IfElse(node.Name() != null, 1, 0);
		final namedBindings = node.AsImportClause().NamedBindings;
		if (namedBindings != null) {
			if (Ast.IsNamespaceImport(namedBindings)) {
				declarationCount++;
			} else {
				declarationCount += Core.len(namedBindings.Elements());
			}
		}
		if (declarationCount > 1 && declarationCount == Core.len(unuseds)) {
			c.reportUnused(node, UnusedKindLocal, Checker.NewDiagnosticForNode(node.Parent, Diagnostics.All_imports_in_import_declaration_are_unused));
		} else {
			for (unused in rangeOf(unuseds)) {
				c.reportUnusedLocal(unused, unused.Name().Text());
			}
		}
	}

	static function checkUnusedInferTypeParameter(c:Checker, node:Node):Void {
		final typeParameter = node.AsInferTypeNode().TypeParameter;
		if (c.isUnreferencedTypeParameter(typeParameter)) {
			c.reportUnused(node, UnusedKindParameter,
				Checker.NewDiagnosticForNode(typeParameter.Name(), Diagnostics.X_0_is_declared_but_never_used, typeParameter.Name().Text()));
		}
	}

	static function checkUnusedTypeParameters(c:Checker, node:Node):Void {
		if (!Checker.allDeclarationsInSameSourceFile(c.getSymbolOfDeclaration(node))) {
			return;
		}
		final typeParameterList = node.TypeParameterList();
		if (typeParameterList == null) {
			return;
		}
		if (typeParameterList.Nodes.length > 1 && Core.Every(typeParameterList.Nodes, n -> c.isUnreferencedTypeParameter(n))) {
			final file = Ast.GetSourceFileOfNode(node);
			final loc = Checker.rangeOfTypeParameters(file, typeParameterList);
			c.reportUnused(node, UnusedKindParameter, Ast.NewDiagnostic(file, loc, Diagnostics.All_type_parameters_are_unused));
		} else {
			for (typeParameter in typeParameterList.Nodes) {
				if (c.isUnreferencedTypeParameter(typeParameter)) {
					c.reportUnused(node, UnusedKindParameter,
						Checker.NewDiagnosticForNode(typeParameter, Diagnostics.X_0_is_declared_but_never_used, typeParameter.Name().Text()));
				}
			}
		}
	}

	static function isUnreferencedTypeParameter(c:Checker, typeParameter:Node):Bool {
		return (c.symbolReferenceLinks.Get(c.getMergedSymbol(typeParameter.Symbol())).referenceKinds & SymbolFlagsTypeParameter) == 0
			&& !Checker.isIdentifierThatStartsWithUnderscore(typeParameter.Name());
	}

	static function checkUnusedRenamedBindingElements(c:Checker):Void {
		for (node in rangeOf(c.renamedBindingElementsInTypes)) {
			if (c.symbolReferenceLinks.Get(c.getSymbolOfDeclaration(node)).referenceKinds == 0) {
				final wrappingDeclaration = Ast.WalkUpBindingElementsAndPatterns(node);
				Debug.Assert(Ast.IsPartOfParameterDeclaration(wrappingDeclaration), "Only parameter declaration should be checked here");
				final diagnostic = Checker.NewDiagnosticForNode(node.Name(),
					Diagnostics.X_0_is_an_unused_renaming_of_1_Did_you_intend_to_use_it_as_a_type_annotation, Scanner.DeclarationNameToString(node.Name()),
					Scanner.DeclarationNameToString(node.PropertyName()));
				if (wrappingDeclaration.Type() == null) {
					// entire parameter does not have type annotation, suggest adding an annotation
					diagnostic.AddRelatedInfo(Ast.NewDiagnostic(Ast.GetSourceFileOfNode(wrappingDeclaration),
						Core.NewTextRange(wrappingDeclaration.End(), wrappingDeclaration.End()),
						Diagnostics.We_can_only_write_a_type_for_0_by_adding_a_type_for_the_entire_parameter_here,
						Scanner.DeclarationNameToString(node.PropertyName())));
				}
				c.addDiagnostic(diagnostic);
			}
		}
	}

	static function checkExpressionStatement(c:Checker, node:Node):Void {
		// Grammar checking
		c.checkGrammarStatementInAmbientContext(node);
		c.checkExpression(node.Expression());
	}

	// Returns the type of an expression. Unlike checkExpression, this function is simply concerned
	// with computing the type and may not fully check all contained sub-expressions for errors.
	static function getTypeOfExpression(c:Checker, node:Node):Type {
		// Don't bother caching types that require no flow analysis and are quick to compute.
		final quickType = c.getQuickTypeOfExpression(node);
		if (quickType != null) {
			return quickType;
		}
		// If a type has been cached for the node, return it.
		final cachedType = c.flowTypeCache != null ? c.flowTypeCache.get(node) : null;
		if (cachedType != null) {
			return cachedType;
		}
		final startInvocationCount = c.flowInvocationCount;
		final t = c.checkExpressionEx(node, CheckModeTypeOnly);
		// If control flow analysis was required to determine the type, it is worth caching.
		if (c.flowInvocationCount != startInvocationCount) {
			if (c.flowTypeCache == null) {
				c.flowTypeCache = new IdentityMap<Node, Type>();
			}
			c.flowTypeCache.set(node, t);
		}
		return t;
	}

	// Returns the type of an expression. Unlike checkExpression, this function is simply concerned
	// with computing the type and may not fully check all contained sub-expressions for errors.
	static function getQuickTypeOfExpression(c:Checker, node:Node):Type {
		final expr = Ast.SkipParentheses(node);
		if (Ast.IsAwaitExpression(expr)) {
			final t = c.getQuickTypeOfExpression(expr.Expression());
			if (t != null) {
				return c.getAwaitedType(t);
			}
			return null;
			// Optimize for the common case of a call to a function with a single non-generic call
			// signature where we can just fetch the return type without checking the arguments.
		} else if (Ast.IsCallExpression(expr) && expr.Expression().Kind != KindSuperKeyword && !Ast.IsRequireCall(expr, true /*requireStringLiteralLikeArgument*/)
			&& !c.isSymbolOrSymbolForCall(expr) && !Ast.IsImportCall(expr)) {
			if (Checker.isCallChain(expr)) {
				return c.getReturnTypeOfSingleNonGenericSignatureOfCallChain(expr);
			}
			return c.getReturnTypeOfSingleNonGenericSignature(c.checkNonNullExpression(expr.Expression()), SignatureKindCall);
		} else if (Ast.IsNewExpression(expr)) {
			return c.getReturnTypeOfSingleNonGenericSignature(c.checkNonNullExpression(expr.Expression()), SignatureKindConstruct);
		} else if (Ast.IsAssertionExpression(expr) && !Ast.IsConstTypeReference(expr.Type())) {
			return c.getTypeFromTypeNode(expr.Type());
		} else if (Ast.IsLiteralExpression(node) || Ast.IsBooleanLiteral(node)) {
			return c.checkExpression(node);
		}
		return null;
	}

	static function getReturnTypeOfSingleNonGenericSignature(c:Checker, funcType:Type, kind:SignatureKind):Type {
		final signature = c.getSingleSignature(funcType, kind, true /*allowMembers*/);
		if (signature != null && Core.len(signature.typeParameters) == 0) {
			return c.getReturnTypeOfSignature(signature);
		}
		return null;
	}

	static function getReturnTypeOfSingleNonGenericSignatureOfCallChain(c:Checker, expr:Node):Type {
		final funcType = c.checkExpression(expr.Expression());
		final nonOptionalType = c.getOptionalExpressionType(funcType, expr.Expression());
		final returnType = c.getReturnTypeOfSingleNonGenericSignature(funcType, SignatureKindCall);
		if (returnType != null) {
			return c.propagateOptionalTypeMarker(returnType, expr, nonOptionalType != funcType);
		}
		return null;
	}

	static function checkNonNullExpression(c:Checker, node:Node):Type {
		return c.checkNonNullType(c.checkExpression(node), node);
	}

	static function checkNonNullType(c:Checker, t:Type, node:Node):Type {
		return c.checkNonNullTypeWithReporter(t, node, reportObjectPossiblyNullOrUndefinedErrorFn);
	}

	// PORT: Go method expression `(*Checker).reportObjectPossiblyNullOrUndefinedError`, created once (PORTING.md §7a).
	static final reportObjectPossiblyNullOrUndefinedErrorFn:(c:Checker, node:Node, facts:TypeFacts) -> Void = (c, node, facts) ->
		reportObjectPossiblyNullOrUndefinedError(c, node, facts);

	static function checkNonNullTypeWithReporter(c:Checker, t:Type, node:Node, reportError:(c:Checker, node:Node, facts:TypeFacts) -> Void):Type {
		if (c.strictNullChecks && (t.flags & TypeFlagsUnknown) != 0) {
			if (Ast.IsEntityNameExpression(node)) {
				final nodeText = Checker.entityNameToString(node);
				if (nodeText.length < 100) {
					c.error(node, Diagnostics.X_0_is_of_type_unknown, nodeText);
					return c.errorType;
				}
			}
			c.error(node, Diagnostics.Object_is_of_type_unknown);
			return c.errorType;
		}
		final facts = c.getTypeFacts(t, TypeFactsIsUndefinedOrNull);
		if ((facts & TypeFactsIsUndefinedOrNull) != 0) {
			reportError(c, node, facts);
			final nonNullable = c.GetNonNullableType(t);
			if ((nonNullable.flags & (TypeFlagsNullable | TypeFlagsNever)) != 0) {
				return c.errorType;
			}
			return nonNullable;
		}
		return t;
	}

	static function checkNonNullNonVoidType(c:Checker, t:Type, node:Node):Type {
		final nonNullType = c.checkNonNullType(t, node);
		if ((nonNullType.flags & TypeFlagsVoid) != 0) {
			if (Ast.IsEntityNameExpression(node)) {
				final nodeText = Checker.entityNameToString(node);
				if (Ast.IsIdentifier(node) && nodeText == "undefined") {
					c.error(node, Diagnostics.The_value_0_cannot_be_used_here, nodeText);
					return nonNullType;
				}
				if (nodeText.length < 100) {
					c.error(node, Diagnostics.X_0_is_possibly_undefined, nodeText);
					return nonNullType;
				}
			}
			c.error(node, Diagnostics.Object_is_possibly_undefined);
		}
		return nonNullType;
	}

	static function reportObjectPossiblyNullOrUndefinedError(c:Checker, node:Node, facts:TypeFacts):Void {
		var nodeText = "";
		if (Ast.IsEntityNameExpression(node)) {
			nodeText = Checker.entityNameToString(node);
		}
		if (node.Kind == KindNullKeyword) {
			c.error(node, Diagnostics.The_value_0_cannot_be_used_here, "null");
			return;
		}
		if (nodeText != "" && nodeText.length < 100) {
			if (Ast.IsIdentifier(node) && nodeText == "undefined") {
				c.error(node, Diagnostics.The_value_0_cannot_be_used_here, "undefined");
				return;
			}
			c.error(node,
				Core.IfElse((facts & TypeFactsIsUndefined) != 0,
					Core.IfElse((facts & TypeFactsIsNull) != 0, Diagnostics.X_0_is_possibly_null_or_undefined, Diagnostics.X_0_is_possibly_undefined),
					Diagnostics.X_0_is_possibly_null),
				nodeText);
		} else {
			c.error(node,
				Core.IfElse((facts & TypeFactsIsUndefined) != 0,
					Core.IfElse((facts & TypeFactsIsNull) != 0, Diagnostics.Object_is_possibly_null_or_undefined, Diagnostics.Object_is_possibly_undefined),
					Diagnostics.Object_is_possibly_null));
		}
	}

	static function checkExpressionWithContextualType(c:Checker, node:Node, contextualType:Type, inferenceContext:InferenceContext, checkMode:CheckMode):Type {
		final contextNode = c.getContextNode(node);
		c.pushContextualType(contextNode, contextualType, false /*isCache*/);
		c.pushInferenceContext(contextNode, inferenceContext);
		var t = c.checkExpressionEx(node, checkMode | CheckModeContextual | Core.IfElse(inferenceContext != null, CheckModeInferential, (0 : CheckMode)));
		// In CheckMode.Inferential we collect intra-expression inference sites to process before fixing any type
		// parameters. This information is no longer needed after the call to checkExpression.
		if (inferenceContext != null && inferenceContext.intraExpressionInferenceSites != null) {
			inferenceContext.intraExpressionInferenceSites = null;
		}
		// We strip literal freshness when an appropriate contextual type is present such that contextually typed
		// literals always preserve their literal types (otherwise they might widen during type inference). An alternative
		// here would be to not mark contextually typed literals as fresh in the first place.
		if (c.maybeTypeOfKind(t, TypeFlagsLiteral) && c.isLiteralOfContextualType(t, c.instantiateContextualType(contextualType, node, ContextFlagsNone))) {
			t = c.getRegularTypeOfLiteralType(t);
		}
		c.popInferenceContext();
		c.popContextualType();
		return t;
	}

	static function getContextNode(c:Checker, node:Node):Node {
		if (Ast.IsJsxAttributes(node) && !Ast.IsJsxSelfClosingElement(node.Parent)) {
			// Needs to be the root JsxElement, so it encompasses the attributes _and_ the children (which are essentially part of the attributes)
			return node.Parent.Parent;
		}
		return node;
	}

	static function checkExpressionCached(c:Checker, node:Node):Type {
		return c.checkExpressionCachedEx(node, CheckModeNormal);
	}

	static function checkExpressionCachedEx(c:Checker, node:Node, checkMode:CheckMode):Type {
		if (checkMode != CheckModeNormal) {
			return c.checkExpressionEx(node, checkMode);
		}
		final links = c.typeNodeLinks.Get(node);
		if (links.resolvedType == null) {
			// When computing a type that we're going to cache, we need to ignore any ongoing control flow
			// analysis because variables may have transient types in indeterminable states. Moving flowLoopStart
			// to the top of the stack ensures all transient types are computed from a known point.
			final saveFlowLoopStack = c.flowLoopStack;
			final saveFlowTypeCache = c.flowTypeCache;
			c.flowLoopStack = null;
			c.flowTypeCache = null;
			links.resolvedType = c.checkExpressionEx(node, checkMode);
			c.flowTypeCache = saveFlowTypeCache;
			c.flowLoopStack = saveFlowLoopStack;
		}
		return links.resolvedType;
	}

	// Returns the type of an expression. Unlike checkExpression, this function is simply concerned
	// with computing the type and may not fully check all contained sub-expressions for errors.
	// It is intended for uses where you know there is no contextual type,
	// and requesting the contextual type might cause a circularity or other bad behaviour.
	// It sets the contextual type of the node to any before calling getTypeOfExpression.
	static function getContextFreeTypeOfExpression(c:Checker, node:Node):Type {
		final cached = c.contextFreeTypes.get(node);
		if (cached != null) {
			return cached;
		}
		c.pushContextualType(node, c.anyType, false /*isCache*/);
		final t = c.checkExpressionEx(node, CheckModeSkipContextSensitive);
		c.contextFreeTypes.set(node, t);
		c.popContextualType();
		return t;
	}

	static function checkExpression(c:Checker, node:Node):Type {
		return c.checkExpressionEx(node, CheckModeNormal);
	}

	static function checkExpressionEx(c:Checker, node:Node, checkMode:CheckMode):Type {
		// PORT: Go `defer tr.Push(...)()`: the returned func runs on return and on panic.
		var pop:() -> Void = null;
		final tr = c.tracer;
		if (tr != null) {
			final args = new StringMap<Any>();
			args.set("kind", node.Kind);
			args.set("pos", node.Pos());
			args.set("end", node.End());
			args.set("path", Ast.GetSourceFileOfNode(node).FileName());
			pop = tr.Push(PhaseCheck, "checkExpression", args, false);
		}
		var t:Type = null;
		try {
			final saveCurrentNode = c.currentNode;
			c.currentNode = node;
			c.instantiationCount = 0;
			final uninstantiatedType = c.checkExpressionWorker(node, checkMode);
			t = c.instantiateTypeWithSingleGenericCallSignature(node, uninstantiatedType, checkMode);
			if (Checker.isConstEnumObjectType(t)) {
				c.checkConstEnumAccess(node, t);
			}
			c.currentNode = saveCurrentNode;
		} catch (e:Dynamic) {
			if (pop != null) {
				pop();
			}
			throw e;
		}
		if (pop != null) {
			pop();
		}
		return t;
	}

	static function checkConstEnumAccess(c:Checker, node:Node, t:Type):Void {
		// enum object type for const enums are only permitted in:
		// - 'left' in property access
		// - 'object' in indexed access
		// - target in rhs of import statement
		final ok = Ast.IsPropertyAccessExpression(node.Parent) && node.Parent.Expression() == node
			|| Ast.IsElementAccessExpression(node.Parent) && node.Parent.Expression() == node
			|| ((Ast.IsIdentifier(node) || Ast.IsQualifiedName(node)) && Checker.isInRightSideOfImportOrExportAssignment(node)
				|| Ast.IsTypeQueryNode(node.Parent) && node.Parent.AsTypeQueryNode().ExprName == node)
			|| Ast.IsExportSpecifier(node.Parent); // We allow reexporting const enums
		if (!ok) {
			c.error(node,
				Diagnostics.X_const_enums_can_only_be_used_in_property_or_index_access_expressions_or_the_right_hand_side_of_an_import_declaration_or_export_assignment_or_type_query);
		}
		// --verbatimModuleSyntax only gets checked here when the enum usage does not
		// resolve to an import, because imports of ambient const enums get checked
		// separately in `checkAliasSymbol`.
		if (c.compilerOptions.IsolatedModules.IsTrue()
			|| c.compilerOptions.VerbatimModuleSyntax.IsTrue() && ok
			&& c.resolveName(node, Ast.GetFirstIdentifier(node).Text(), SymbolFlagsAlias, null, false, true) == null) {
			Debug.Assert((t.symbol.Flags & SymbolFlagsConstEnum) != 0);
			final constEnumDeclaration = t.symbol.ValueDeclaration;
			final redirect = c.program.GetProjectReferenceFromOutputDts(Ast.GetSourceFileOfNode(constEnumDeclaration).Path());
			if ((constEnumDeclaration.Flags & NodeFlagsAmbient) != 0 && !Ast.IsValidTypeOnlyAliasUseSite(node)
				&& (redirect == null || !redirect.Resolved.CompilerOptions().ShouldPreserveConstEnums())) {
				c.error(node, Diagnostics.Cannot_access_ambient_const_enums_when_0_is_enabled, c.getIsolatedModulesLikeFlagName());
			}
		}
	}

	static function instantiateTypeWithSingleGenericCallSignature(c:Checker, node:Node, t:Type, checkMode:CheckMode):Type {
		if ((checkMode & (CheckModeInferential | CheckModeSkipGenericFunctions)) == 0) {
			return t;
		}
		final callSignature = c.getSingleSignature(t, SignatureKindCall, true /*allowMembers*/);
		final constructSignature = c.getSingleSignature(t, SignatureKindConstruct, true /*allowMembers*/);
		final signature = Core.OrElse(callSignature, constructSignature);
		if (signature == null || Core.len(signature.typeParameters) == 0) {
			return t;
		}
		final contextualType = c.getApparentTypeOfContextualType(node, ContextFlagsNoConstraints);
		if (contextualType == null) {
			return t;
		}
		final contextualSignature = c.getSingleSignature(c.GetNonNullableType(contextualType),
			Core.IfElse(callSignature != null, SignatureKindCall, SignatureKindConstruct), false /*allowMembers*/);
		if (contextualSignature == null || Core.len(contextualSignature.typeParameters) != 0) {
			return t;
		}
		if ((checkMode & CheckModeSkipGenericFunctions) != 0) {
			c.skippedGenericFunction(node, checkMode);
			return c.anyFunctionType;
		}
		final context = c.getInferenceContext(node);
		// We have an expression that is an argument of a generic function for which we are performing
		// type argument inference. The expression is of a function type with a single generic call
		// signature and a contextual function type with a single non-generic call signature. Now check
		// if the outer function returns a function type with a single non-generic call signature and
		// if some of the outer function type parameters have no inferences so far. If so, we can
		// potentially add inferred type parameters to the outer function return type.
		var returnSignature:Signature = null;
		if (context.signature != null) {
			final returnType = c.getReturnTypeOfSignature(context.signature);
			if (returnType != null) {
				returnSignature = c.getSingleCallOrConstructSignature(returnType);
			}
		}
		if (returnSignature != null && Core.len(returnSignature.typeParameters) == 0 && !Core.Every(context.inferences, Checker.hasInferenceCandidates)) {
			// Instantiate the signature with its own type parameters as type arguments, possibly
			// renaming the type parameters to ensure they have unique names.
			final uniqueTypeParameters = c.getUniqueTypeParameters(context, signature.typeParameters);
			final instantiatedSignature = c.getSignatureInstantiationWithoutFillingInTypeArguments(signature, uniqueTypeParameters);
			// Infer from the parameters of the instantiated signature to the parameters of the
			// contextual signature starting with an empty set of inference candidates.
			final inferences = Core.Map(context.inferences, info -> Checker.newInferenceInfo(info.typeParameter));
			c.applyToParameterTypes(instantiatedSignature, contextualSignature, function(source:Type, target:Type):Void {
				c.inferTypes(inferences, source, target, InferencePriorityNone, true /*contravariant*/);
			});
			if (Core.Some(inferences, Checker.hasInferenceCandidates)) {
				// We have inference candidates, indicating that one or more type parameters are referenced
				// in the parameter types of the contextual signature. Now also infer from the return type.
				c.applyToReturnTypes(instantiatedSignature, contextualSignature, function(source:Type, target:Type):Void {
					c.inferTypes(inferences, source, target, InferencePriorityNone, false);
				});
				// If the type parameters for which we produced candidates do not have any inferences yet,
				// we adopt the new inference candidates and add the type parameters of the expression type
				// to the set of inferred type parameters for the outer function return type.
				if (!Checker.hasOverlappingInferences(context.inferences, inferences)) {
					c.mergeInferences(context.inferences, inferences);
					context.inferredTypeParameters = Core.Concatenate(context.inferredTypeParameters, uniqueTypeParameters);
					return c.getOrCreateTypeFromSignature(instantiatedSignature);
				}
			}
		}
		// TODO: The signature may reference any outer inference contexts, but we map pop off and then apply new inference contexts,
		// and thus get different inferred types. That this is cached on the *first* such attempt is not currently an issue, since expression
		// types *also* get cached on the first pass. If we ever properly speculate, though, the cached "isolatedSignatureType" signature
		// field absolutely needs to be included in the list of speculative caches.
		return c.getOrCreateTypeFromSignature(c.instantiateSignatureInContextOf(signature, contextualSignature, context, null));
	}

	static function getOuterInferenceTypeParameters(c:Checker):Array<Type> {
		var result:Array<Type> = null;
		for (i in 0...Core.len(c.inferenceContextInfos)) {
			final context = c.inferenceContextInfos[i].context;
			if (context != null) {
				for (info in rangeOf(context.inferences)) {
					if (result == null) {
						result = [];
					}
					result.push(info.typeParameter);
				}
			}
		}
		return result;
	}

	static function getUniqueTypeParameters(c:Checker, context:InferenceContext, typeParameters:Array<Type>):Array<Type> {
		var oldTypeParameters:Array<Type> = null;
		var newTypeParameters:Array<Type> = null;
		final result:Array<Type> = [];
		for (tp in rangeOf(typeParameters)) {
			final name = tp.symbol.Name;
			if (Checker.hasTypeParameterByName(context.inferredTypeParameters, name) || Checker.hasTypeParameterByName(result, name)) {
				final newName = Checker.getUniqueTypeParameterName(Core.Concatenate(context.inferredTypeParameters, result), name);
				final symbol = c.newSymbol(SymbolFlagsTypeParameter, newName);
				final newTypeParameter = c.newTypeParameter(symbol);
				newTypeParameter.AsTypeParameter().target = tp;
				if (oldTypeParameters == null) {
					oldTypeParameters = [];
					newTypeParameters = [];
				}
				oldTypeParameters.push(tp);
				newTypeParameters.push(newTypeParameter);
				result.push(newTypeParameter);
			} else {
				result.push(tp);
			}
		}
		if (Core.len(newTypeParameters) != 0) {
			final mapper = Checker.newTypeMapper(oldTypeParameters, newTypeParameters);
			for (tp in newTypeParameters) {
				tp.AsTypeParameter().mapper = mapper;
			}
		}
		return result;
	}

	static function checkExpressionWorker(c:Checker, node:Node, checkMode:CheckMode):Type {
		switch (node.Kind) {
			case KindIdentifier:
				return c.checkIdentifier(node, checkMode);
			case KindPrivateIdentifier:
				return c.checkPrivateIdentifierExpression(node);
			case KindThisKeyword:
				return c.checkThisExpression(node);
			case KindSuperKeyword:
				return c.checkSuperExpression(node);
			case KindNullKeyword:
				return c.nullWideningType;
			case KindStringLiteral | KindNoSubstitutionTemplateLiteral:
				if (c.isSkipDirectInferenceNode(node)) {
					return c.blockedStringType;
				}
				return c.getFreshTypeOfLiteralType(c.getStringLiteralType(node.Text()));
			case KindNumericLiteral:
				c.checkGrammarNumericLiteral(node.AsNumericLiteral());
				return c.getFreshTypeOfLiteralType(c.getNumberLiteralType(Jsnum.FromString(node.Text())));
			case KindBigIntLiteral:
				c.checkGrammarBigIntLiteral(node.AsBigIntLiteral());
				return c.getFreshTypeOfLiteralType(c.getBigIntLiteralType(Jsnum.NewPseudoBigInt(Jsnum.ParsePseudoBigInt(node.Text()), false /*negative*/)));
			case KindTrueKeyword:
				return c.trueType;
			case KindFalseKeyword:
				return c.falseType;
			case KindTemplateExpression:
				return c.checkTemplateExpression(node);
			case KindRegularExpressionLiteral:
				return c.checkRegularExpressionLiteral(node);
			case KindArrayLiteralExpression:
				return c.checkArrayLiteral(node, checkMode);
			case KindObjectLiteralExpression:
				return c.checkObjectLiteral(node, checkMode);
			case KindPropertyAccessExpression:
				return c.checkPropertyAccessExpression(node, checkMode, false /*writeOnly*/);
			case KindQualifiedName:
				return c.checkQualifiedName(node, checkMode);
			case KindElementAccessExpression:
				return c.checkIndexedAccess(node, checkMode);
			case KindCallExpression:
				if (Ast.IsImportCall(node)) {
					return c.checkImportCallExpression(node);
				}
				return c.checkCallExpression(node, checkMode);
			case KindNewExpression:
				return c.checkCallExpression(node, checkMode);
			case KindTaggedTemplateExpression:
				return c.checkTaggedTemplateExpression(node);
			case KindParenthesizedExpression:
				return c.checkParenthesizedExpression(node, checkMode);
			case KindClassExpression:
				return c.checkClassExpression(node);
			case KindFunctionExpression | KindArrowFunction:
				return c.checkFunctionExpressionOrObjectLiteralMethod(node, checkMode);
			case KindTypeAssertionExpression | KindAsExpression:
				return c.checkAssertion(node, checkMode);
			case KindTypeOfExpression:
				return c.checkTypeOfExpression(node);
			case KindNonNullExpression:
				return c.checkNonNullAssertion(node);
			case KindExpressionWithTypeArguments:
				return c.checkExpressionWithTypeArguments(node);
			case KindSatisfiesExpression:
				return c.checkSatisfiesExpression(node);
			case KindMetaProperty:
				return c.checkMetaProperty(node);
			case KindDeleteExpression:
				return c.checkDeleteExpression(node);
			case KindVoidExpression:
				return c.checkVoidExpression(node);
			case KindAwaitExpression:
				return c.checkAwaitExpression(node);
			case KindPrefixUnaryExpression:
				return c.checkPrefixUnaryExpression(node);
			case KindPostfixUnaryExpression:
				return c.checkPostfixUnaryExpression(node);
			case KindBinaryExpression:
				return c.checkBinaryExpression(node, checkMode);
			case KindConditionalExpression:
				return c.checkConditionalExpression(node, checkMode);
			case KindSpreadElement:
				return c.checkSpreadExpression(node, checkMode);
			case KindOmittedExpression:
				return c.undefinedWideningType;
			case KindYieldExpression:
				return c.checkYieldExpression(node);
			case KindSyntheticExpression:
				return c.checkSyntheticExpression(node);
			case KindJsxExpression:
				return c.checkJsxExpression(node, checkMode);
			case KindJsxElement:
				return c.checkJsxElement(node, checkMode);
			case KindJsxSelfClosingElement:
				return c.checkJsxSelfClosingElement(node, checkMode);
			case KindJsxFragment:
				return c.checkJsxFragment(node);
			case KindJsxAttributes:
				return c.checkJsxAttributes(node, checkMode);
			case KindJsxOpeningElement:
				throw "Should never directly check a JsxOpeningElement";
			default:
		}
		return c.errorType;
	}

	static function checkPrivateIdentifierExpression(c:Checker, node:Node):Type {
		c.checkGrammarPrivateIdentifierExpression(node.AsPrivateIdentifier());
		final symbol = c.getSymbolForPrivateIdentifierExpression(node);
		if (symbol != null) {
			c.markPropertyAsReferenced(symbol, null /*nodeForCheckWriteOnly*/, false /*isSelfTypeAccess*/);
		}
		return c.anyType;
	}

	static function getSymbolForPrivateIdentifierExpression(c:Checker, node:Node):Symbol {
		final links = c.symbolNodeLinks.Get(node);
		if (links.resolvedSymbol == null) {
			links.resolvedSymbol = c.lookupSymbolForPrivateIdentifierDeclaration(node.Text(), node);
		}
		return links.resolvedSymbol;
	}

	static function checkSuperExpression(c:Checker, node:Node):Type {
		final isCallExpression = Ast.IsCallExpression(node.Parent) && node.Parent.Expression() == node;
		final immediateContainer = Checker.getSuperContainer(node, true /*stopOnFunctions*/);
		var container = immediateContainer;

		// adjust the container reference in case if super is used inside arrow functions with arbitrarily deep nesting
		if (!isCallExpression) {
			while (container != null && Ast.IsArrowFunction(container)) {
				container = Checker.getSuperContainer(container, true /*stopOnFunctions*/);
			}
		}

		final isLegalUsageOfSuperExpression = function():Bool {
			if (isCallExpression) {
				// TS 1.0 SPEC (April 2014): 4.8.1
				// Super calls are only permitted in constructors of derived classes
				return Ast.IsConstructorDeclaration(container);
			}
			// TS 1.0 SPEC (April 2014)
			// 'super' property access is allowed
			// - In a constructor, instance member function, instance member accessor, or instance member variable initializer where this references a derived class instance
			// - In a static member function or static member accessor

			// topmost container must be something that is directly nested in the class declaration\object literal expression
			if (Ast.IsClassLike(container.Parent) || Ast.IsObjectLiteralExpression(container.Parent)) {
				if (Ast.IsStatic(container)) {
					return Ast.NodeKindIs(container, KindMethodDeclaration, KindMethodSignature, KindGetAccessor, KindSetAccessor, KindPropertyDeclaration,
						KindClassStaticBlockDeclaration);
				}
				return Ast.NodeKindIs(container, KindMethodDeclaration, KindMethodSignature, KindGetAccessor, KindSetAccessor, KindPropertyDeclaration,
					KindPropertySignature, KindConstructor);
			}
			return false;
		};

		if (container == null || !isLegalUsageOfSuperExpression()) {
			// issue more specific error if super is used in computed property name
			// class A { foo() { return "1" }}
			// class B {
			//     [super.foo()]() {}
			// }
			final current = Ast.FindAncestorOrQuit(node, function(n:Node):ts.ast.Utilities.FindAncestorResult {
				if (n == container) {
					return FindAncestorQuit;
				}
				if (Ast.IsComputedPropertyName(n)) {
					return FindAncestorTrue;
				}
				return FindAncestorFalse;
			});
			if (current != null && Ast.IsComputedPropertyName(current)) {
				c.error(node, Diagnostics.X_super_cannot_be_referenced_in_a_computed_property_name);
			} else if (isCallExpression) {
				c.error(node, Diagnostics.Super_calls_are_not_permitted_outside_constructors_or_in_nested_functions_inside_constructors);
			} else if (container == null || container.Parent == null || !(Ast.IsClassLike(container.Parent) || Ast.IsObjectLiteralExpression(container.Parent))) {
				c.error(node, Diagnostics.X_super_can_only_be_referenced_in_members_of_derived_classes_or_object_literal_expressions);
			} else {
				c.error(node, Diagnostics.X_super_property_access_is_permitted_only_in_a_constructor_member_function_or_member_accessor_of_a_derived_class);
			}
			return c.errorType;
		}
		if (!isCallExpression && Ast.IsConstructorDeclaration(immediateContainer)) {
			c.checkThisBeforeSuper(node, container, Diagnostics.X_super_must_be_called_before_accessing_a_property_of_super_in_the_constructor_of_a_derived_class);
		}
		if (container.Parent.Kind == KindObjectLiteralExpression) {
			// for object literal assume that type of 'super' is 'any'
			return c.anyType;
		}
		// at this point the only legal case for parent is ClassLikeDeclaration
		final classLikeDeclaration = container.Parent;
		if (Ast.GetExtendsHeritageClauseElement(classLikeDeclaration) == null) {
			c.error(node, Diagnostics.X_super_can_only_be_referenced_in_a_derived_class);
			return c.errorType;
		}
		if (c.classDeclarationExtendsNull(classLikeDeclaration)) {
			if (isCallExpression) {
				return c.errorType;
			}
			return c.nullWideningType;
		}
		final classType = c.getDeclaredTypeOfSymbol(c.getSymbolOfDeclaration(classLikeDeclaration));
		var baseClassType:Type = null;
		if (classType != null) {
			baseClassType = Core.FirstOrNil(c.getBaseTypes(classType));
		}
		if (baseClassType == null) {
			return c.errorType;
		}
		if (Ast.IsConstructorDeclaration(container) && c.isInConstructorArgumentInitializer(node, container)) {
			// issue custom error message for super property access in constructor arguments (to be aligned with old compiler)
			c.error(node, Diagnostics.X_super_cannot_be_referenced_in_constructor_arguments);
			return c.errorType;
		}
		if (Ast.IsStatic(container) || isCallExpression) {
			if (!isCallExpression && (c.languageVersion : Int) <= (ScriptTargetES2021 : Int)
				&& (Ast.IsPropertyDeclaration(container) || Ast.IsClassStaticBlockDeclaration(container))) {
				// for `super.x` or `super[x]` in a static initializer, mark all enclosing
				// block scope containers so that we can report potential collisions with
				// `Reflect`.
				var current = Ast.GetEnclosingBlockScopeContainer(node.Parent);
				while (current != null) {
					if (!Ast.IsSourceFile(current) || Ast.IsExternalOrCommonJSModule(current.AsSourceFile())) {
						c.nodeLinks.Get(current).flags |= NodeCheckFlagsContainsSuperPropertyInStaticInitializer;
					}
					current = Ast.GetEnclosingBlockScopeContainer(current);
				}
			}
			return c.getBaseConstructorTypeOfClass(classType);
		}
		return c.getTypeWithThisArgument(baseClassType, classType.AsInterfaceType().thisType, false);
	}

	static function isInConstructorArgumentInitializer(c:Checker, node:Node, constructorDecl:Node):Bool {
		return Ast.FindAncestorOrQuit(node, function(n:Node):ts.ast.Utilities.FindAncestorResult {
			if (Ast.IsFunctionLikeDeclaration(n)) {
				return FindAncestorQuit;
			}
			if (Ast.IsParameterDeclaration(n) && n.Parent == constructorDecl) {
				return FindAncestorTrue;
			}
			return FindAncestorFalse;
		}) != null;
	}

	static function checkTemplateExpression(c:Checker, node:Node):Type {
		final expr = node.AsTemplateExpression();
		final length = expr.TemplateSpans.Nodes.length;
		final texts:Array<std.String> = [for (_ in 0...length + 1) ""];
		final types:Array<Type> = [for (_ in 0...length) null];
		texts[0] = expr.Head.Text();
		for (i in 0...length) {
			final span = expr.TemplateSpans.Nodes[i];
			final t = c.checkExpression(span.Expression());
			if (c.maybeTypeOfKindConsideringBaseConstraint(t, TypeFlagsESSymbolLike)) {
				c.error(span.Expression(),
					Diagnostics.Implicit_conversion_of_a_symbol_to_a_string_will_fail_at_runtime_Consider_wrapping_this_expression_in_String);
			}
			texts[i + 1] = span.AsTemplateSpan().Literal.Text();
			types[i] = Core.IfElse(c.isTypeAssignableTo(t, c.templateConstraintType), t, c.stringType);
		}
		var evaluated:Any = null;
		if (!Ast.IsTaggedTemplateExpression(node.Parent)) {
			evaluated = c.evaluate(node, node).Value;
		}
		if (evaluated != null) {
			return c.getFreshTypeOfLiteralType(c.getStringLiteralType((evaluated : std.String)));
		}
		if (c.isConstContext(node) || c.isTemplateLiteralContext(node)
			|| Checker.someType(Core.OrElse(c.getContextualType(node, ContextFlagsNone), c.unknownType), t -> c.isTemplateLiteralContextualType(t))) {
			return c.getTemplateLiteralType(texts, types);
		}
		return c.stringType;
	}

	// PORT: Go `range` over a possibly-nil slice (PORTING.md §3): a nil slice iterates zero times.
	static inline function rangeOf<T>(a:Null<Array<T>>):Array<T> {
		return a != null ? a : [];
	}

	// PORT: Go `slices.Values(s)` as the checker's iter.Seq form `(yield) -> Void`.
	static function valuesOf<T>(s:Null<Array<T>>):(yield:(T) -> Bool) -> Void {
		return function(yield_:(T) -> Bool):Void {
			if (s != null) {
				for (v in s) {
					if (!yield_(v)) {
						return;
					}
				}
			}
		};
	}

	// PORT: Go positional composite literal `IterationTypes{yieldType, returnType, nextType}`.
	static function newIterationTypes(yieldType:Type, returnType:Type, nextType:Type):IterationTypes {
		final r = new IterationTypes();
		r.yieldType = yieldType;
		r.returnType = returnType;
		r.nextType = nextType;
		return r;
	}

	// PORT: Go map lookup `table[name]` on a possibly-nil ast.SymbolTable (nil map reads as empty).
	static inline function symbolTableGet(table:SymbolTable, name:std.String):Symbol {
		return table != null ? table.get(name) : null;
	}

	// PORT: Go `intrinsicTypeKinds[name]`: a missing key reads as the zero value IntrinsicTypeKindUnknown.
	static function intrinsicTypeKindOf(name:std.String):IntrinsicTypeKind {
		final k = Checker.intrinsicTypeKinds.get(name);
		return k == null ? IntrinsicTypeKindUnknown : k;
	}

	// PORT: *ast.SourceFile passed where Go converts it to ast.HasFileName (structural interface);
	// Haxe uses the cached adapter of modulespecifiers.
	static inline function hasFileName(file:SourceFile):HasFileName {
		return ts.modulespecifiers.Types.SourceFileAdapter.Of(file);
	}
}

// Go: local type `MemberInfo` in checkKindsOfPropertyMemberOverrides.
private class MemberInfo {
	public var missedProperties:Array<std.String> = null;
	public var baseTypeName:std.String = "";
	public var typeName:std.String = "";

	public function new() {}
}
