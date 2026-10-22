package ts.module;

// Port of resolver.go (types and methods; package-level funcs are in Module.hx).

// Go unexported type `resolved`.
class Resolved {
	public var path:String = "";
	public var extension:String = "";
	public var packageId:PackageId = new PackageId();
	public var originalPath:String = "";
	public var resolvedUsingTsExtension:Bool = false;

	public function new(path:String = "", extension:String = "", ?packageId:PackageId, originalPath:String = "",
			resolvedUsingTsExtension:Bool = false) {
		this.path = path;
		this.extension = extension;
		if (packageId != null)
			this.packageId = packageId;
		this.originalPath = originalPath;
		this.resolvedUsingTsExtension = resolvedUsingTsExtension;
	}

	// PORT: nil receiver — inline so a null result works like Go's nil *resolved.
	public inline function shouldContinueSearching():Bool {
		return this == null;
	}

	public inline function isResolved():Bool {
		return this != null && this.path != "";
	}
}

typedef ResolutionKindSpecificLoader = (extensions:Extensions, candidate:String) -> Null<Resolved>;

// Go unexported type `tracer`.
class Tracer {
	var traces:Null<Array<DiagAndArgs>> = null;

	public function new() {}

	// PORT: Go `write(diag, args ...any)` is nil-safe; every call site here checks for nil first.
	public function write(diag:Message, ...args:Any):Void {
		final a = args.toArray();
		writeArgs(diag, a.length == 0 ? null : a); // Go: no variadic args → nil slice
	}

	// PORT: `t.write` as a `func(m *diagnostics.Message, args ...any)` value (see getTraceFunc).
	public function writeArgs(diag:Message, args:Array<Any>):Void {
		if (this.traces == null)
			this.traces = [];
		this.traces.push(new DiagAndArgs(diag, args));
	}

	// PORT: nil receiver — inline so a null tracer returns nil like Go.
	public inline function getTraces():Null<Array<DiagAndArgs>> {
		return this != null ? this.traces : null;
	}

	public function traceResolutionUsingProjectReference(redirectedReference:Null<ResolvedProjectReference>):Void {
		if (redirectedReference != null && redirectedReference.CompilerOptions() != null) {
			this.write(Diagnostics.Using_compiler_options_of_project_reference_redirect_0, redirectedReference.ConfigName());
		}
	}

	public function traceTypeReferenceDirectiveResult(typeReferenceDirectiveName:String, result:ResolvedTypeReferenceDirective):Void {
		if (!result.IsResolved()) {
			this.write(Diagnostics.Type_reference_directive_0_was_not_resolved, typeReferenceDirectiveName);
		} else if (result.PackageId.Name != "") {
			this.write(Diagnostics.Type_reference_directive_0_was_successfully_resolved_to_1_with_Package_ID_2_primary_Colon_3,
				typeReferenceDirectiveName, result.ResolvedFileName, result.PackageId.String(), result.Primary);
		} else {
			this.write(Diagnostics.Type_reference_directive_0_was_successfully_resolved_to_1_primary_Colon_2, typeReferenceDirectiveName,
				result.ResolvedFileName, result.Primary);
		}
	}
}

class DiagAndArgs {
	public var Message:Message;
	public var Args:Null<Array<Any>>;

	public function new(Message:Message, Args:Null<Array<Any>>) {
		this.Message = Message;
		this.Args = Args;
	}
}

// Go unexported type `resolutionState`.
@:allow(ts.module)
class ResolutionState {
	var resolver:Resolver = null;
	var tracer:Null<Tracer> = null;

	// request fields
	var name:String = "";
	var containingDirectory:String = "";
	var isConfigLookup:Bool = false;
	var features:NodeResolutionFeatures = NodeResolutionFeaturesNone;
	var esmMode:Bool = false;
	var conditions:Null<Array<String>> = null;
	var extensions:Extensions = 0;
	var compilerOptions:CompilerOptions = null;
	var resolvePackageDirectoryOnly:Bool = false;

	// state fields
	// candidateEndingIsFromConfig is set when the candidate file extension originated from
	// configuration (package.json fields, tsconfig.json paths entries, or wildcard substitutions)
	// rather than from the module specifier written in source code. When true, resolvedUsingTsExtension
	// is suppressed so the checker does not attempt to extract a TS extension from the original specifier.
	var candidateEndingIsFromConfig:Bool = false;
	var resolvedPackageDirectory:Bool = false;
	var diagnostics:Null<Array<Diagnostic>> = null;

	// Similar to whats on resolver but only done if compilerOptions are for project reference redirect
	// Cached representation for `core.CompilerOptions.paths`.
	// Doesn't handle other path patterns like in `typesVersions`.
	// PORT: sync.Once → flag.
	var parsedPatternsForPathsOnce:Bool = false;
	var parsedPatternsForPaths:Null<ParsedPatterns> = null;

	public function new() {}

	function resolveTypeReferenceDirective(typeRoots:Null<Array<String>>, fromConfig:Bool,
			fromInferredTypesContainingFile:Bool):ResolvedTypeReferenceDirective {
		final r = this;
		// Primary lookup
		if (typeRoots != null && typeRoots.length > 0) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Resolving_with_primary_search_path_0, typeRoots.join(", "));
			}
			for (typeRoot in typeRoots) {
				final candidate = r.getCandidateFromTypeRoot(typeRoot);
				final directoryExists = r.resolver.host.FS().DirectoryExists(typeRoot);
				if (!directoryExists) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, typeRoot);
					}
					continue;
				}
				if (fromConfig) {
					// Custom typeRoots resolve as file or directory just like we do modules
					final resolvedFromFile = r.loadModuleFromFile(extensionsDeclaration, candidate);
					if (!resolvedFromFile.shouldContinueSearching()) {
						final packageDirectory = Module.ParseNodeModuleFromPath(resolvedFromFile.path, false);
						if (packageDirectory != "") {
							resolvedFromFile.packageId = r.getPackageId(resolvedFromFile.path, r.getPackageJsonInfo(packageDirectory));
						}
						return r.createResolvedTypeReferenceDirective(resolvedFromFile, true /*primary*/);
					}
				}
				final resolvedFromDirectory = r.loadNodeModuleFromDirectory(extensionsDeclaration, candidate, true /*considerPackageJson*/);
				if (!resolvedFromDirectory.shouldContinueSearching()) {
					return r.createResolvedTypeReferenceDirective(resolvedFromDirectory, true /*primary*/);
				}
			}
		} else if (r.tracer != null) {
			r.tracer.write(Diagnostics.Root_directory_cannot_be_determined_skipping_primary_search_paths);
		}

		// Secondary lookup
		var resolved:Null<Resolved> = null;
		if (!fromConfig || !fromInferredTypesContainingFile) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Looking_up_in_node_modules_folder_initial_location_0, r.containingDirectory);
			}
			if (!Tspath.IsExternalModuleNameRelative(r.name)) {
				resolved = r.loadModuleFromNearestNodeModulesDirectory(false /*typesScopeOnly*/);
			} else {
				final candidate = Module.normalizePathForCJSResolution(r.containingDirectory, r.name);
				resolved = r.nodeLoadModuleByRelativeName(extensionsDeclaration, candidate, true /*considerPackageJson*/);
			}
		} else if (r.tracer != null) {
			r.tracer.write(Diagnostics.Resolving_type_reference_directive_for_program_that_specifies_custom_typeRoots_skipping_lookup_in_node_modules_folder);
		}
		return r.createResolvedTypeReferenceDirective(resolved, false /*primary*/);
	}

	function getCandidateFromTypeRoot(typeRoot:String):String {
		final r = this;
		var nameForLookup = r.name;
		if (StringTools.endsWith(typeRoot, "/node_modules/@types") || StringTools.endsWith(typeRoot, "/node_modules/@types/")) {
			nameForLookup = r.mangleScopedPackageName(r.name);
		}
		return Tspath.CombinePaths(typeRoot, nameForLookup);
	}

	function mangleScopedPackageName(name:String):String {
		final r = this;
		final mangled = Module.MangleScopedPackageName(name);
		if (r.tracer != null && mangled != name) {
			r.tracer.write(Diagnostics.Scoped_package_detected_looking_in_0, mangled);
		}
		return mangled;
	}

	// resolveFromTypeRoot tries to resolve a module name from the configured typeRoots.
	// This is used as a fallback after node_modules resolution fails, for declaration file lookups.
	// Returns nil if typeRoots is not configured or if no matching module is found in any typeRoot directory.
	function resolveFromTypeRoot():Null<Resolved> {
		final r = this;
		if (r.compilerOptions.TypeRoots == null) {
			return null;
		}
		for (typeRoot in r.compilerOptions.TypeRoots) {
			final candidate = r.getCandidateFromTypeRoot(typeRoot);
			final directoryExists = r.resolver.host.FS().DirectoryExists(typeRoot);
			if (!directoryExists) {
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, typeRoot);
				}
				continue;
			}
			final resolvedFromFile = r.loadModuleFromFile(extensionsDeclaration, candidate);
			if (!resolvedFromFile.shouldContinueSearching()) {
				final packageDirectory = Module.ParseNodeModuleFromPath(resolvedFromFile.path, false);
				if (packageDirectory != "") {
					resolvedFromFile.packageId = r.getPackageId(resolvedFromFile.path, r.getPackageJsonInfo(packageDirectory));
				}
				return resolvedFromFile;
			}
			final resolved = r.loadNodeModuleFromDirectory(extensionsDeclaration, candidate, true /*considerPackageJson*/);
			if (!resolved.shouldContinueSearching()) {
				return resolved;
			}
		}
		return null;
	}

	function getPackageScopeForPath(directory:String):Null<InfoCacheEntry> {
		final r = this;
		final result = Tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(r.resolver.typingsLocation, directory,
			function(directory:String):ValueOk<InfoCacheEntry> {
				final result = r.getPackageJsonInfo(directory);
				if (result != null) {
					return new ValueOk<InfoCacheEntry>(result, true);
				}
				return new ValueOk<InfoCacheEntry>(null, false);
			});
		return result;
	}

	function resolveNodeLike():ResolvedModule {
		final r = this;
		if (r.tracer != null) {
			final conditions = Core.Map(r.conditions, function(c:String):String {
				return "'" + c + "'";
			});
			final conditionsText = conditions == null ? "" : conditions.join(", ");
			if (r.esmMode) {
				r.tracer.write(Diagnostics.Resolving_in_0_mode_with_conditions_1, "ESM", conditionsText);
			} else {
				r.tracer.write(Diagnostics.Resolving_in_0_mode_with_conditions_1, "CJS", conditionsText);
			}
		}
		final result = r.resolveNodeLikeWorker();
		if (r.resolvedPackageDirectory
			&& !r.isConfigLookup
			&& (r.features & NodeResolutionFeaturesExports) != 0
			&& (r.extensions & (extensionsTypeScript | extensionsDeclaration)) != 0
			&& !Tspath.IsExternalModuleNameRelative(r.name)
			&& result.IsResolved()
			&& result.IsExternalLibraryImport
			&& !Module.extensionIsOk(extensionsTypeScript | extensionsDeclaration, result.Extension)
			&& Slices.Contains(r.conditions, "import")) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Resolution_of_non_relative_name_failed_trying_with_modern_Node_resolution_features_disabled_to_see_if_npm_library_needs_configuration_update);
			}
			r.features = r.features & ~NodeResolutionFeaturesExports;
			r.extensions = r.extensions & (extensionsTypeScript | extensionsDeclaration);
			final diagnosticsCount = len(r.diagnostics);
			final diagnosticResult = r.resolveNodeLikeWorker();
			if (diagnosticResult.IsResolved() && diagnosticResult.IsExternalLibraryImport) {
				result.AlternateResult = diagnosticResult.ResolvedFileName;
			}
			// PORT: Go reslices; a new array keeps earlier results' slices unchanged.
			r.diagnostics = r.diagnostics == null ? null : r.diagnostics.slice(0, diagnosticsCount);
		}
		return result;
	}

	function resolveNodeLikeWorker():ResolvedModule {
		final r = this;
		{
			final resolved = r.tryLoadModuleUsingOptionalResolutionSettings();
			if (!resolved.shouldContinueSearching()) {
				return r.createResolvedModuleHandlingSymlink(resolved);
			}
		}

		if (!Tspath.IsExternalModuleNameRelative(r.name)) {
			if ((r.features & NodeResolutionFeaturesImports) != 0 && StringTools.startsWith(r.name, "#")) {
				final resolved = r.loadModuleFromImports();
				if (!resolved.shouldContinueSearching()) {
					return r.createResolvedModuleHandlingSymlink(resolved);
				}
			}
			if ((r.features & NodeResolutionFeaturesSelfName) != 0) {
				final resolved = r.loadModuleFromSelfNameReference();
				if (!resolved.shouldContinueSearching()) {
					return r.createResolvedModuleHandlingSymlink(resolved);
				}
			}
			if (r.name.indexOf(":") >= 0) {
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Skipping_module_0_that_looks_like_an_absolute_URI_target_file_types_Colon_1, r.name, r.extensions.String());
				}
				return r.createResolvedModule(null, false);
			}
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Loading_module_0_from_node_modules_folder_target_file_types_Colon_1, r.name, r.extensions.String());
			}
			{
				final resolved = r.loadModuleFromNearestNodeModulesDirectory(false /*typesScopeOnly*/);
				if (!resolved.shouldContinueSearching()) {
					return r.createResolvedModuleHandlingSymlink(resolved);
				}
			}
			if ((r.extensions & extensionsDeclaration) != 0) {
				final resolved = r.resolveFromTypeRoot();
				if (!resolved.shouldContinueSearching()) {
					return r.createResolvedModuleHandlingSymlink(resolved);
				}
			}
		} else {
			final candidate = Module.normalizePathForCJSResolution(r.containingDirectory, r.name);
			final resolved = r.nodeLoadModuleByRelativeName(r.extensions, candidate, true);
			return r.createResolvedModule(resolved, resolved != null && resolved.path.indexOf("/node_modules/") >= 0);
		}
		return r.createResolvedModule(null, false);
	}

	function loadModuleFromSelfNameReference():Null<Resolved> {
		final r = this;
		final directoryPath = Tspath.GetNormalizedAbsolutePath(r.containingDirectory, r.resolver.host.GetCurrentDirectory());
		final scope = r.getPackageScopeForPath(directoryPath);
		if (!scope.Exists() || scope.Contents.Exports.IsFalsy()) {
			// !!! falsy check seems wrong?
			return Module.continueSearching();
		}
		final nameOk = scope.Contents.Name.GetValue();
		final name = nameOk.value;
		if (!nameOk.ok) {
			return Module.continueSearching();
		}
		final parts = Tspath.GetPathComponents(r.name, "");
		final nameParts = Tspath.GetPathComponents(name, "");
		if (parts.length < nameParts.length || !Slices.Equal(nameParts, parts.slice(0, nameParts.length))) {
			return Module.continueSearching();
		}
		final trailingParts = parts.slice(nameParts.length);
		var subpath:String;
		if (trailingParts.length > 0) {
			subpath = Tspath.CombinePaths(".", ...trailingParts);
		} else {
			subpath = ".";
		}
		// Maybe TODO: splitting extensions into two priorities should be unnecessary, except
		// https://github.com/microsoft/TypeScript/issues/50762 makes the behavior different.
		// As long as that bug exists, we need to do two passes here in self-name loading
		// in order to be consistent with (non-self) library-name loading in
		// `loadModuleFromNearestNodeModulesDirectoryWorker`, which uses two passes in order
		// to prioritize `@types` packages higher up the directory tree over untyped
		// implementation packages. See the selfNameModuleAugmentation.ts test for why this
		// matters.
		//
		// However, there's an exception. If the user has `allowJs` and `declaration`, we need
		// to ensure that self-name imports of their own package can resolve back to their
		// input JS files via `tryLoadInputFileForPath` at a higher priority than their output
		// declaration files, so we need to do a single pass with all extensions for that case.
		if (r.compilerOptions.GetAllowJS() && r.containingDirectory.indexOf("/node_modules/") < 0) {
			return r.loadModuleFromExports(scope, r.extensions, subpath);
		}
		final priorityExtensions = r.extensions & (extensionsTypeScript | extensionsDeclaration);
		final secondaryExtensions = r.extensions & ~(extensionsTypeScript | extensionsDeclaration);
		final resolved = r.loadModuleFromExports(scope, priorityExtensions, subpath);
		if (!resolved.shouldContinueSearching()) {
			return resolved;
		}
		return r.loadModuleFromExports(scope, secondaryExtensions, subpath);
	}

	function loadModuleFromImports():Null<Resolved> {
		final r = this;
		if (r.name == "#" || (StringTools.startsWith(r.name, "#/") && (r.features & NodeResolutionFeaturesImportsPatternRoot) == 0)) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Invalid_import_specifier_0_has_no_possible_resolutions, r.name);
			}
			return Module.continueSearching();
		}
		final directoryPath = Tspath.GetNormalizedAbsolutePath(r.containingDirectory, r.resolver.host.GetCurrentDirectory());
		final scope = r.getPackageScopeForPath(directoryPath);
		if (!scope.Exists()) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Directory_0_has_no_containing_package_json_scope_Imports_will_not_resolve, directoryPath);
			}
			return Module.continueSearching();
		}
		if (scope.Contents.Imports.Type != JSONValueTypeObject) {
			// !!! Old compiler only checks for undefined, but then assumes `imports` is an object if present.
			// Maybe should have a new diagnostic for imports of an invalid type. Also, array should be handled?
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.X_package_json_scope_0_has_no_imports_defined, scope.PackageDirectory);
			}
			return Module.continueSearching();
		}

		final result = r.loadModuleFromExportsOrImports(r.extensions, r.name, scope.Contents.Imports.AsObject(), scope /*isImports*/, true);
		if (!result.shouldContinueSearching()) {
			return result;
		}

		if (r.tracer != null) {
			r.tracer.write(Diagnostics.Import_specifier_0_does_not_exist_in_package_json_scope_at_path_1, r.name, scope.PackageDirectory);
		}
		return Module.continueSearching();
	}

	function loadModuleFromExports(packageInfo:Null<InfoCacheEntry>, ext:Extensions, subpath:String):Null<Resolved> {
		final r = this;
		// !!! This is ported exactly, but the falsy check seems wrong
		if (!packageInfo.Exists() || packageInfo.Contents.Exports.IsFalsy()) {
			return Module.continueSearching();
		}

		if (subpath == ".") {
			var mainExport = new ExportsOrImports();
			switch (packageInfo.Contents.Exports.Type) {
				case JSONValueTypeString | JSONValueTypeArray:
					mainExport = packageInfo.Contents.Exports;
				case JSONValueTypeObject:
					if (packageInfo.Contents.Exports.IsConditions()) {
						mainExport = packageInfo.Contents.Exports;
					} else {
						final dot = packageInfo.Contents.Exports.AsObject().Get(".");
						if (dot.ok) {
							mainExport = dot.value;
						}
					}
				default:
			}
			if (mainExport.Type != JSONValueTypeNotPresent) {
				return r.loadModuleFromTargetExportOrImport(ext, subpath, packageInfo, false /*isImports*/, mainExport, "", false /*isPattern*/, ".");
			}
		} else if (packageInfo.Contents.Exports.Type == JSONValueTypeObject && packageInfo.Contents.Exports.IsSubpaths()) {
			final result = r.loadModuleFromExportsOrImports(ext, subpath, packageInfo.Contents.Exports.AsObject(), packageInfo, false /*isImports*/);
			if (!result.shouldContinueSearching()) {
				return result;
			}
		}

		if (r.tracer != null) {
			r.tracer.write(Diagnostics.Export_specifier_0_does_not_exist_in_package_json_scope_at_path_1, subpath, packageInfo.PackageDirectory);
		}
		return Module.continueSearching();
	}

	function loadModuleFromExportsOrImports(extensions:Extensions, moduleName:String, lookupTable:OrderedMap<String, ExportsOrImports>,
			scope:InfoCacheEntry, isImports:Bool):Null<Resolved> {
		final r = this;
		if (!StringTools.endsWith(moduleName, "/") && moduleName.indexOf("*") < 0) {
			final target = lookupTable.Get(moduleName);
			if (target.ok) {
				return r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target.value, "", false /*isPattern*/, moduleName);
			}
		}

		final expandingKeys:Array<String> = [];
		for (key in lookupTable.Keys()) {
			if (Strings.Count(key, "*") == 1 || StringTools.endsWith(key, "/")) {
				expandingKeys.push(key);
			}
		}
		Slices.SortFunc(expandingKeys, Module.ComparePatternKeys);

		for (potentialTarget in expandingKeys) {
			if ((r.features & NodeResolutionFeaturesExportsPatternTrailers) != 0 && Module.matchesPatternWithTrailer(potentialTarget, moduleName)) {
				final target = lookupTable.Get(potentialTarget).value;
				final starPos = potentialTarget.indexOf("*");
				final subpath = moduleName.substring(potentialTarget.substring(0, starPos).length,
					moduleName.length - (potentialTarget.length - 1 - starPos));
				return r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, true, potentialTarget);
			} else if (StringTools.endsWith(potentialTarget, "*")
				&& StringTools.startsWith(moduleName, potentialTarget.substring(0, potentialTarget.length - 1))) {
				final target = lookupTable.Get(potentialTarget).value;
				final subpath = moduleName.substring(potentialTarget.length - 1);
				return r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, true, potentialTarget);
			} else if (StringTools.startsWith(moduleName, potentialTarget)) {
				final target = lookupTable.Get(potentialTarget).value;
				final subpath = moduleName.substring(potentialTarget.length);
				return r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, target, subpath, false, potentialTarget);
			}
		}

		return Module.continueSearching();
	}

	function loadModuleFromTargetExportOrImport(extensions:Extensions, moduleName:String, scope:InfoCacheEntry, isImports:Bool,
			target:ExportsOrImports, subpath:String, isPattern:Bool, key:String):Null<Resolved> {
		final r = this;
		switch (target.Type) {
			case JSONValueTypeString:
				final targetString:String = target.Value;
				if (!isPattern && subpath.length > 0 && !StringTools.endsWith(targetString, "/")) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
					}
					return Module.continueSearching();
				}
				if (!StringTools.startsWith(targetString, "./")) {
					if (isImports
						&& !StringTools.startsWith(targetString, "../")
						&& !StringTools.startsWith(targetString, "/")
						&& !Tspath.IsRootedDiskPath(targetString)) {
						var combinedLookup = targetString + subpath;
						if (isPattern) {
							combinedLookup = Strings.ReplaceAll(targetString, "*", subpath);
						}
						final scopeContainingDirectory = Tspath.EnsureTrailingDirectorySeparator(scope.PackageDirectory);
						if (r.tracer != null) {
							r.tracer.write(Diagnostics.Using_0_subpath_1_with_target_2, "imports", key, combinedLookup);
							r.tracer.write(Diagnostics.Resolving_module_0_from_1, combinedLookup, scopeContainingDirectory);
						}
						final name = r.name, containingDirectory = r.containingDirectory;
						r.name = combinedLookup;
						r.containingDirectory = scopeContainingDirectory;
						// PORT: defer restores name/containingDirectory; done at each return.
						final result = r.resolveNodeLike();
						if (result.IsResolved()) {
							r.name = name;
							r.containingDirectory = containingDirectory;
							return new Resolved(result.ResolvedFileName, result.Extension, result.PackageId, result.OriginalPath,
								result.ResolvedUsingTsExtension);
						}
						r.name = name;
						r.containingDirectory = containingDirectory;
						return Module.continueSearching();
					}
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
					}
					return Module.continueSearching();
				}
				var parts:Array<String>;
				if (Tspath.PathIsRelative(targetString)) {
					parts = Tspath.GetPathComponents(targetString, "").slice(1);
				} else {
					parts = Tspath.GetPathComponents(targetString, "");
				}
				final partsAfterFirst = parts.slice(1);
				if (Slices.Contains(partsAfterFirst, "..") || Slices.Contains(partsAfterFirst, ".") || Slices.Contains(partsAfterFirst, "node_modules")) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
					}
					return Module.continueSearching();
				}
				final resolvedTarget = Tspath.CombinePaths(scope.PackageDirectory, targetString);
				// TODO: Assert that `resolvedTarget` is actually within the package directory? That's what the spec says.... but I'm not sure we need
				// to be in the business of validating everyone's import and export map correctness.
				final subpathParts = Tspath.GetPathComponents(subpath, "");
				if (Slices.Contains(subpathParts, "..") || Slices.Contains(subpathParts, ".") || Slices.Contains(subpathParts, "node_modules")) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
					}
					return Module.continueSearching();
				}

				if (r.tracer != null) {
					var messageTarget:String;
					if (isPattern) {
						messageTarget = Strings.ReplaceAll(targetString, "*", subpath);
					} else {
						messageTarget = targetString + subpath;
					}
					r.tracer.write(Diagnostics.Using_0_subpath_1_with_target_2, Core.IfElse(isImports, "imports", "exports"), key, messageTarget);
				}
				var finalPath:String;
				if (isPattern) {
					finalPath = Tspath.GetNormalizedAbsolutePath(Strings.ReplaceAll(resolvedTarget, "*", subpath), r.resolver.host.GetCurrentDirectory());
				} else {
					finalPath = Tspath.GetNormalizedAbsolutePath(resolvedTarget + subpath, r.resolver.host.GetCurrentDirectory());
				}
				final inputLink = r.tryLoadInputFileForPath(finalPath, subpath, Tspath.CombinePaths(scope.PackageDirectory, "package.json"), isImports);
				if (!inputLink.shouldContinueSearching()) {
					inputLink.packageId = r.getPackageId(inputLink.path, scope);
					return inputLink;
				}
				final result = r.loadFileNameFromPackageJSONField(extensions, finalPath, targetString);
				if (!result.shouldContinueSearching()) {
					result.packageId = r.getPackageId(result.path, scope);
					return result;
				}
				return Module.continueSearching();

			case JSONValueTypeObject:
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Entering_conditional_exports);
				}
				for (condition in target.AsObject().Keys()) {
					if (r.conditionMatches(condition)) {
						if (r.tracer != null) {
							r.tracer.write(Diagnostics.Matched_0_condition_1, Core.IfElse(isImports, "imports", "exports"), condition);
						}
						final subTarget = target.AsObject().Get(condition).value;
						final result = r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, subTarget, subpath, isPattern, key);
						if (!result.shouldContinueSearching()) {
							if (result.isResolved() && r.tracer != null) {
								r.tracer.write(Diagnostics.Resolved_under_condition_0, condition);
							}
							if (r.tracer != null) {
								r.tracer.write(Diagnostics.Exiting_conditional_exports);
							}
							return result;
						} else if (r.tracer != null) {
							r.tracer.write(Diagnostics.Failed_to_resolve_under_condition_0, condition);
						}
					} else {
						if (r.tracer != null) {
							r.tracer.write(Diagnostics.Saw_non_matching_condition_0, condition);
						}
					}
				}
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Exiting_conditional_exports);
				}
				return Module.continueSearching();
			case JSONValueTypeArray:
				if (target.AsArray().length == 0) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
					}
					return Module.continueSearching();
				}
				for (elem in target.AsArray()) {
					final result = r.loadModuleFromTargetExportOrImport(extensions, moduleName, scope, isImports, elem, subpath, isPattern, key);
					if (!result.shouldContinueSearching()) {
						return result;
					}
				}

			case JSONValueTypeNull:
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.X_package_json_scope_0_explicitly_maps_specifier_1_to_null, scope.PackageDirectory, moduleName);
				}
				return Module.unresolved();
			default:
		}

		if (r.tracer != null) {
			r.tracer.write(Diagnostics.X_package_json_scope_0_has_invalid_type_for_target_of_specifier_1, scope.PackageDirectory, moduleName);
		}
		return Module.continueSearching();
	}

	function tryLoadInputFileForPath(finalPath:String, entry:String, packagePath:String, isImports:Bool):Null<Resolved> {
		final r = this;
		// Replace any references to outputs for files in the program with the input files to support package self-names used with outDir
		if (!r.isConfigLookup
			&& (r.compilerOptions.DeclarationDir != "" || r.compilerOptions.OutDir != "")
			&& finalPath.indexOf("/node_modules/") < 0
			&& (r.compilerOptions.ConfigFilePath == ""
				|| Tspath.ContainsPath(Tspath.GetDirectoryPath(packagePath), r.compilerOptions.ConfigFilePath,
					new ComparePathsOptions(r.resolver.host.FS().UseCaseSensitiveFileNames(), r.resolver.host.GetCurrentDirectory())))) {
			// Note: this differs from Strada's tryLoadInputFileForPath in that it
			// does not attempt to perform "guesses", instead requring a clear root indicator.

			var rootDir:String;
			if (r.compilerOptions.RootDir != "") {
				// A `rootDir` compiler option strongly indicates the root location
				rootDir = r.compilerOptions.RootDir;
			} else if (r.compilerOptions.ConfigFilePath != "") {
				// When no explicit rootDir is set, treat the config file's directory as the project root, which establishes the common source directory, so no other locations need to be checked.
				rootDir = Tspath.GetDirectoryPath(r.compilerOptions.ConfigFilePath);
			} else {
				final diagnostic = Ast.NewDiagnostic(null, new TextRange(0, 0),
					Core.IfElse(isImports,
						Diagnostics.The_project_root_is_ambiguous_but_is_required_to_resolve_import_map_entry_0_in_file_1_Supply_the_rootDir_compiler_option_to_disambiguate,
						Diagnostics.The_project_root_is_ambiguous_but_is_required_to_resolve_export_map_entry_0_in_file_1_Supply_the_rootDir_compiler_option_to_disambiguate),
					Core.IfElse(entry == "", ".", entry), // replace empty string with `.` - the reverse of the operation done when entries are built - so main entrypoint errors don't look weird
					packagePath);
				// PORT: Go append may not be visible through earlier results' slices; copy first.
				r.diagnostics = r.diagnostics == null ? [] : r.diagnostics.copy();
				r.diagnostics.push(diagnostic);
				return Module.unresolved();
			}

			final candidateDirectories = r.getOutputDirectoriesForBaseDirectory(rootDir);
			if (candidateDirectories != null) {
				for (candidateDir in candidateDirectories) {
					if (Tspath.ContainsPath(candidateDir, finalPath,
						new ComparePathsOptions(r.resolver.host.FS().UseCaseSensitiveFileNames(), r.resolver.host.GetCurrentDirectory()))) {
						// The matched export is looking up something in either the out declaration or js dir, now map the written path back into the source dir and source extension
						var pathFragment = "";
						if (finalPath.length > candidateDir.length) {
							pathFragment = finalPath.substring(candidateDir.length + 1); // +1 to also remove directory separator
						}
						final possibleInputBase = Tspath.CombinePaths(rootDir, pathFragment);
						final jsAndDtsExtensions = [
							Tspath.ExtensionMjs,
							Tspath.ExtensionCjs,
							Tspath.ExtensionJs,
							Tspath.ExtensionJson,
							Tspath.ExtensionDmts,
							Tspath.ExtensionDcts,
							Tspath.ExtensionDts
						];
						for (ext in jsAndDtsExtensions) {
							if (Tspath.FileExtensionIs(possibleInputBase, ext)) {
								final inputExts = Tspath.GetPossibleOriginalInputExtensionForExtension(possibleInputBase);
								for (possibleExt in inputExts) {
									if (!Module.extensionIsOk(r.extensions, possibleExt)) {
										continue;
									}
									final possibleInputWithInputExtension = Tspath.ChangeExtension(possibleInputBase, possibleExt);
									if (r.resolver.host.FS().FileExists(possibleInputWithInputExtension)) {
										final resolved = r.loadFileNameFromPackageJSONField(r.extensions, possibleInputWithInputExtension, "");
										if (!resolved.shouldContinueSearching()) {
											return resolved;
										}
									}
								}
							}
						}
					}
				}
			}
		}
		return Module.continueSearching();
	}

	function getOutputDirectoriesForBaseDirectory(commonSourceDirGuess:String):Null<Array<String>> {
		final r = this;
		// Config file output paths are processed to be relative to the host's current directory, while
		// otherwise the paths are resolved relative to the common source dir the compiler puts together
		final currentDir = Core.IfElse(r.compilerOptions.ConfigFilePath != "", r.resolver.host.GetCurrentDirectory(), commonSourceDirGuess);
		var candidateDirectories:Null<Array<String>> = null;
		if (r.compilerOptions.DeclarationDir != "") {
			if (candidateDirectories == null)
				candidateDirectories = [];
			candidateDirectories.push(Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(currentDir, r.compilerOptions.DeclarationDir),
				r.resolver.host.GetCurrentDirectory()));
		}
		if (r.compilerOptions.OutDir != "" && r.compilerOptions.OutDir != r.compilerOptions.DeclarationDir) {
			if (candidateDirectories == null)
				candidateDirectories = [];
			candidateDirectories.push(Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(currentDir, r.compilerOptions.OutDir),
				r.resolver.host.GetCurrentDirectory()));
		}
		return candidateDirectories;
	}

	function loadModuleFromNearestNodeModulesDirectory(typesScopeOnly:Bool):Null<Resolved> {
		final r = this;
		var mode = Core.ResolutionModeCommonJS;
		if (r.esmMode || r.conditionMatches("import")) {
			mode = Core.ResolutionModeESM;
		}
		// Do (up to) two passes through node_modules:
		//   1. For each ancestor node_modules directory, try to find:
		//      i.  TS/DTS files in the implementation package
		//      ii. DTS files in the @types package
		//   2. For each ancestor node_modules directory, try to find:
		//      i.  JS files in the implementation package
		final priorityExtensions = r.extensions & (extensionsTypeScript | extensionsDeclaration);
		final secondaryExtensions = r.extensions & ~(extensionsTypeScript | extensionsDeclaration);
		// (1)
		if (priorityExtensions != 0) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Searching_all_ancestor_node_modules_directories_for_preferred_extensions_Colon_0, priorityExtensions.String());
			}
			final result = r.loadModuleFromNearestNodeModulesDirectoryWorker(priorityExtensions, mode, typesScopeOnly);
			if (!result.shouldContinueSearching()) {
				return result;
			}
		}
		// (2)
		if (secondaryExtensions != 0 && !typesScopeOnly) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Searching_all_ancestor_node_modules_directories_for_fallback_extensions_Colon_0, secondaryExtensions.String());
			}
			return r.loadModuleFromNearestNodeModulesDirectoryWorker(secondaryExtensions, mode, typesScopeOnly);
		}
		return Module.continueSearching();
	}

	function loadModuleFromNearestNodeModulesDirectoryWorker(ext:Extensions, mode:ResolutionMode, typesScopeOnly:Bool):Null<Resolved> {
		final r = this;
		final result = Tspath.ForEachAncestorDirectory(r.containingDirectory, function(directory:String):ValueOk<Resolved> {
			// !!! stop at global cache
			if (Tspath.GetBaseFileName(directory) != "node_modules") {
				final result = r.loadModuleFromImmediateNodeModulesDirectory(ext, directory, typesScopeOnly);
				return new ValueOk<Resolved>(result, !result.shouldContinueSearching());
			}
			return new ValueOk<Resolved>(Module.continueSearching(), false);
		});
		return result.value;
	}

	function loadModuleFromImmediateNodeModulesDirectory(extensions:Extensions, directory:String, typesScopeOnly:Bool):Null<Resolved> {
		final r = this;
		final nodeModulesFolder = Tspath.CombinePaths(directory, "node_modules");
		if (!r.resolver.host.FS().DirectoryExists(nodeModulesFolder)) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, nodeModulesFolder);
			}
			return Module.continueSearching();
		}

		if (!typesScopeOnly) {
			final packageResult = r.loadModuleFromSpecificNodeModulesDirectory(extensions, r.name, nodeModulesFolder);
			if (!packageResult.shouldContinueSearching()) {
				return packageResult;
			}
		}

		if ((extensions & extensionsDeclaration) != 0) {
			final nodeModulesAtTypes = Tspath.CombinePaths(nodeModulesFolder, "@types");
			if (!r.resolver.host.FS().DirectoryExists(nodeModulesAtTypes)) {
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, nodeModulesAtTypes);
				}
				return Module.continueSearching();
			}
			return r.loadModuleFromSpecificNodeModulesDirectory(extensionsDeclaration, r.mangleScopedPackageName(r.name), nodeModulesAtTypes);
		}

		return Module.continueSearching();
	}

	function loadModuleFromSpecificNodeModulesDirectory(ext:Extensions, moduleName:String, nodeModulesDirectory:String):Null<Resolved> {
		final r = this;
		// Strip any trailing directory separator so that imports like `pkg/` and `pkg`
		// produce identical `candidate` and `packageDirectory` strings. Otherwise the
		// `package.json` info cache (which is keyed by normalized path but stores the
		// caller's `PackageDirectory` verbatim) can hand back, under concurrent
		// inserts, an entry whose `PackageDirectory` doesn't match `candidate`,
		// causing `loadNodeModuleFromDirectoryWorker`'s `ComparePaths(candidate, ...)`
		// check to fail and skip loading the package's `main`/`types` entry.
		// https://github.com/microsoft/typescript-go/issues/3526
		final candidate = Tspath.RemoveTrailingDirectorySeparator(Tspath.NormalizePath(Tspath.CombinePaths(nodeModulesDirectory, moduleName)));
		final pr = Module.ParsePackageName(moduleName);
		final packageName = pr.a, rest = pr.b;
		var packageDirectory = Tspath.CombinePaths(nodeModulesDirectory, packageName);
		if (packageName == "") {
			packageDirectory = candidate;
		}

		if (r.resolvePackageDirectoryOnly) {
			if (r.resolver.host.FS().DirectoryExists(packageDirectory)) {
				return new Resolved(packageDirectory);
			}
			return Module.continueSearching();
		}

		var rootPackageInfo:Null<InfoCacheEntry> = null;
		// First look for a nested package.json, as in `node_modules/foo/bar/package.json`
		var packageInfo = r.getPackageJsonInfo(candidate);
		// But only if we're not respecting export maps (if we are, we might redirect around this location)
		if (rest != "" && packageInfo.Exists()) {
			if ((r.features & NodeResolutionFeaturesExports) != 0) {
				rootPackageInfo = r.getPackageJsonInfo(packageDirectory);
			}
			if (!rootPackageInfo.Exists() || rootPackageInfo.Contents.Exports.Type == JSONValueTypeNotPresent) {
				final fromFile = r.loadModuleFromFile(ext, candidate);
				if (!fromFile.shouldContinueSearching()) {
					return fromFile;
				}

				final fromDirectory = r.loadNodeModuleFromDirectoryWorker(ext, candidate, packageInfo);
				if (!fromDirectory.shouldContinueSearching()) {
					fromDirectory.packageId = r.getPackageId(fromDirectory.path, packageInfo);
					return fromDirectory;
				}
			}
		}

		// PORT: the Go closure captures the variable `packageInfo`, which is reassigned below.
		final loader = function(extensions:Extensions, candidate:String):Null<Resolved> {
			if (rest != "" || !r.esmMode) {
				final fromFile = r.loadModuleFromFile(extensions, candidate);
				if (!fromFile.shouldContinueSearching()) {
					fromFile.packageId = r.getPackageId(fromFile.path, packageInfo);
					return fromFile;
				}
			}
			final fromDirectory = r.loadNodeModuleFromDirectoryWorker(extensions, candidate, packageInfo);
			if (!fromDirectory.shouldContinueSearching()) {
				fromDirectory.packageId = r.getPackageId(fromDirectory.path, packageInfo);
				return fromDirectory;
			}
			if (rest == ""
				&& packageInfo.Exists()
				&& (packageInfo.Contents.Exports.Type == JSONValueTypeNotPresent || packageInfo.Contents.Exports.Type == JSONValueTypeNull)
				&& r.esmMode) {
				// EsmMode disables index lookup in `loadNodeModuleFromDirectoryWorker` generally, however non-relative package resolutions still assume
				// a default `index.js` entrypoint if no `main` or `exports` are present
				final indexResult = r.loadModuleFromFile(extensions, Tspath.CombinePaths(candidate, "index.js"));
				if (!indexResult.shouldContinueSearching()) {
					indexResult.packageId = r.getPackageId(indexResult.path, packageInfo);
					return indexResult;
				}
			}
			return Module.continueSearching();
		};

		if (rest != "") {
			packageInfo = rootPackageInfo;
			if (packageInfo == null) {
				// Previous `packageInfo` may have been from a nested package.json; ensure we have the one from the package root now.
				packageInfo = r.getPackageJsonInfo(packageDirectory);
			}
		}
		if (packageInfo != null) {
			r.resolvedPackageDirectory = true;
			if ((r.features & NodeResolutionFeaturesExports) != 0 && packageInfo.Exists() && !packageInfo.Contents.Exports.IsFalsy()) {
				// package exports are higher priority than file/directory/typesVersions lookups and (and, if there's exports present*, blocks them)
				// *Well, weirdly enough a top-level `"exports": null` does NOT block fallback resolution.
				// https://github.com/microsoft/TypeScript/pull/49327
				return r.loadModuleFromExports(packageInfo, ext, Tspath.CombinePaths(".", rest));
			}
			if (rest != "" && packageInfo.Exists()) {
				final versionPaths = packageInfo.Contents.GetVersionPaths(r.getTraceFunc());
				if (versionPaths.Exists()) {
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.X_package_json_has_a_typesVersions_entry_0_that_matches_compiler_version_1_looking_for_a_pattern_to_match_module_name_2,
							versionPaths.Version, Core.Version(), rest);
					}
					final pathPatterns = Module.TryParsePatterns(versionPaths.GetPaths());
					final fromPaths = r.tryLoadModuleUsingPaths(ext, rest, packageDirectory, versionPaths.GetPaths(), pathPatterns, loader);
					if (!fromPaths.shouldContinueSearching()) {
						return fromPaths;
					}
				}
			}
		}
		return loader(ext, candidate);
	}

	function createResolvedModuleHandlingSymlink(resolved:Null<Resolved>):ResolvedModule {
		final r = this;
		final isExternalLibraryImport = resolved != null && resolved.path.indexOf("/node_modules/") >= 0;
		if (r.compilerOptions.PreserveSymlinks != TSTrue
			&& isExternalLibraryImport
			&& resolved.originalPath == ""
			&& !Tspath.IsExternalModuleNameRelative(r.name)) {
			final p = r.getOriginalAndResolvedFileName(resolved.path);
			final originalPath = p.a, resolvedFileName = p.b;
			if (originalPath != "") {
				resolved.path = resolvedFileName;
				resolved.originalPath = originalPath;
			}
		}
		return r.createResolvedModule(resolved, isExternalLibraryImport);
	}

	function createResolvedModule(resolved:Null<Resolved>, isExternalLibraryImport:Bool):ResolvedModule {
		final r = this;
		final resolvedModule = new ResolvedModule();
		resolvedModule.ResolutionDiagnostics = r.diagnostics;

		if (resolved != null) {
			resolvedModule.ResolvedFileName = resolved.path;
			resolvedModule.OriginalPath = resolved.originalPath;
			resolvedModule.IsExternalLibraryImport = isExternalLibraryImport;
			resolvedModule.ResolvedUsingTsExtension = resolved.resolvedUsingTsExtension;
			resolvedModule.Extension = resolved.extension;
			resolvedModule.PackageId = resolved.packageId;
		}
		return resolvedModule;
	}

	function createResolvedTypeReferenceDirective(resolved:Null<Resolved>, primary:Bool):ResolvedTypeReferenceDirective {
		final r = this;
		final resolvedTypeReferenceDirective = new ResolvedTypeReferenceDirective();
		resolvedTypeReferenceDirective.ResolutionDiagnostics = r.diagnostics;

		if (resolved.isResolved()) {
			if (!Tspath.ExtensionIsTs(resolved.extension)) {
				throw "expected a TypeScript file extension";
			}
			resolvedTypeReferenceDirective.ResolvedFileName = resolved.path;
			resolvedTypeReferenceDirective.Primary = primary;
			resolvedTypeReferenceDirective.PackageId = resolved.packageId;
			resolvedTypeReferenceDirective.IsExternalLibraryImport = resolved.path.indexOf("/node_modules/") >= 0;

			if (r.compilerOptions.PreserveSymlinks != TSTrue) {
				final p = r.getOriginalAndResolvedFileName(resolved.path);
				final originalPath = p.a, resolvedFileName = p.b;
				if (originalPath != "") {
					resolvedTypeReferenceDirective.ResolvedFileName = resolvedFileName;
					resolvedTypeReferenceDirective.OriginalPath = originalPath;
				}
			}
		}
		return resolvedTypeReferenceDirective;
	}

	// PORT: (string, string) → Pair(a = originalPath, b = resolvedFileName).
	function getOriginalAndResolvedFileName(fileName:String):Pair<String, String> {
		final r = this;
		final resolvedFileName = r.realPath(fileName);
		final comparePathsOptions = new ComparePathsOptions(r.resolver.host.FS().UseCaseSensitiveFileNames(), r.resolver.host.GetCurrentDirectory());
		if (Tspath.ComparePaths(fileName, resolvedFileName, comparePathsOptions) == 0) {
			// If the fileName and realpath are differing only in casing, prefer fileName
			// so that we can issue correct errors for casing under forceConsistentCasingInFileNames
			return new Pair("", fileName);
		}
		return new Pair(fileName, resolvedFileName);
	}

	function tryLoadModuleUsingOptionalResolutionSettings():Null<Resolved> {
		final r = this;
		final resolved = r.tryLoadModuleUsingPathsIfEligible();
		if (!resolved.shouldContinueSearching()) {
			return resolved;
		}

		if (!Tspath.IsExternalModuleNameRelative(r.name)) {
			// No more tryLoadModuleUsingBaseUrl.
			return Module.continueSearching();
		} else {
			return r.tryLoadModuleUsingRootDirs();
		}
	}

	function getParsedPatternsForPaths():ParsedPatterns {
		final r = this;
		if (r.compilerOptions == r.resolver.compilerOptions) {
			return r.resolver.getParsedPatternsForPaths();
		}
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!r.parsedPatternsForPathsOnce) {
			r.parsedPatternsForPathsOnce = true;
			r.parsedPatternsForPaths = Module.TryParsePatterns(r.compilerOptions.Paths);
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return r.parsedPatternsForPaths;
	}

	function tryLoadModuleUsingPathsIfEligible():Null<Resolved> {
		final r = this;
		if (r.compilerOptions.Paths.Size() > 0 && !Tspath.PathIsRelative(r.name)) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.X_paths_option_is_specified_looking_for_a_pattern_to_match_module_name_0, r.name);
			}
		} else {
			return Module.continueSearching();
		}
		final baseDirectory = r.compilerOptions.GetPathsBasePath(r.resolver.host.GetCurrentDirectory());
		final pathPatterns = r.getParsedPatternsForPaths();
		return r.tryLoadModuleUsingPaths(r.extensions, r.name, baseDirectory, r.compilerOptions.Paths, pathPatterns,
			function(extensions:Extensions, candidate:String):Null<Resolved> {
				return r.nodeLoadModuleByRelativeName(extensions, candidate, true /*considerPackageJson*/);
			});
	}

	function tryLoadModuleUsingPaths(extensions:Extensions, moduleName:String, containingDirectory:String,
			paths:Null<OrderedMap<String, Array<String>>>, pathPatterns:ParsedPatterns, loader:ResolutionKindSpecificLoader):Null<Resolved> {
		final r = this;
		final matchedPattern = Module.MatchPatternOrExact(pathPatterns, moduleName);
		if (matchedPattern.IsValid()) {
			final matchedStar = matchedPattern.MatchedText(moduleName);
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Module_name_0_matched_pattern_1, moduleName, matchedPattern.Text);
			}
			final substs = paths.GetOrZero(matchedPattern.Text);
			if (substs != null) {
				for (subst in substs) {
					final path = replaceFirst(subst, "*", matchedStar);
					final candidate = Tspath.NormalizePath(Tspath.CombinePaths(containingDirectory, path));
					if (r.tracer != null) {
						r.tracer.write(Diagnostics.Trying_substitution_0_candidate_module_location_Colon_1, subst, path);
					}
					// A path mapping may have an extension
					final extensionFromSubst = Tspath.TryGetExtensionFromPath(subst);
					if (extensionFromSubst != "") {
						final f = r.tryFile(candidate);
						if (f.ok) {
							return new Resolved(f.value, extensionFromSubst);
						}
					}
					// When the substitution path has an explicit extension, the extension came from the
					// paths config, not the module specifier. Suppress resolvedUsingTsExtension in that case.
					final saveCandidateEndingIsFromConfig = r.candidateEndingIsFromConfig;
					if (extensionFromSubst != "") {
						r.candidateEndingIsFromConfig = true;
					}
					final resolved = loader(extensions, candidate);
					r.candidateEndingIsFromConfig = saveCandidateEndingIsFromConfig;
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
			}
		}
		return Module.continueSearching();
	}

	// PORT: strings.Replace(s, old, new, 1).
	static function replaceFirst(s:String, old:String, new_:String):String {
		final i = s.indexOf(old);
		if (i < 0)
			return s;
		return s.substring(0, i) + new_ + s.substring(i + old.length);
	}

	function tryLoadModuleUsingRootDirs():Null<Resolved> {
		final r = this;
		if (r.compilerOptions.RootDirs == null || r.compilerOptions.RootDirs.length == 0) {
			return Module.continueSearching();
		}

		if (r.tracer != null) {
			r.tracer.write(Diagnostics.X_rootDirs_option_is_set_using_it_to_resolve_relative_module_name_0, r.name);
		}

		final candidate = Tspath.NormalizePath(Tspath.CombinePaths(r.containingDirectory, r.name));

		var matchedRootDir = "";
		var matchedNormalizedPrefix = "";
		for (rootDir in r.compilerOptions.RootDirs) {
			// rootDirs are expected to be absolute
			// in case of tsconfig.json this will happen automatically - compiler will expand relative names
			// using location of tsconfig.json as base location
			var normalizedRoot = Tspath.NormalizePath(rootDir);
			if (!StringTools.endsWith(normalizedRoot, "/")) {
				normalizedRoot += "/";
			}
			final isLongestMatchingPrefix = StringTools.startsWith(candidate, normalizedRoot)
				&& (matchedNormalizedPrefix == "" || matchedNormalizedPrefix.length < normalizedRoot.length);

			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Checking_if_0_is_the_longest_matching_prefix_for_1_2, normalizedRoot, candidate, isLongestMatchingPrefix);
			}

			if (isLongestMatchingPrefix) {
				matchedNormalizedPrefix = normalizedRoot;
				matchedRootDir = rootDir;
			}
		}

		if (matchedNormalizedPrefix != "") {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Longest_matching_prefix_for_0_is_1, candidate, matchedNormalizedPrefix);
			}
			final suffix = candidate.substring(matchedNormalizedPrefix.length);

			// first - try to load from a initial location
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Loading_0_from_the_root_dir_1_candidate_location_2, suffix, matchedNormalizedPrefix, candidate);
			}
			final loader = function(extensions:Extensions, candidate:String):Null<Resolved> {
				return r.nodeLoadModuleByRelativeName(extensions, candidate, true /*considerPackageJson*/);
			};
			{
				final resolvedFileName = loader(r.extensions, candidate);
				if (!resolvedFileName.shouldContinueSearching()) {
					return resolvedFileName;
				}
			}

			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Trying_other_entries_in_rootDirs);
			}
			// then try to resolve using remaining entries in rootDirs
			for (rootDir in r.compilerOptions.RootDirs) {
				if (rootDir == matchedRootDir) {
					// skip the initially matched entry
					continue;
				}
				final candidate = Tspath.CombinePaths(Tspath.NormalizePath(rootDir), suffix);
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Loading_0_from_the_root_dir_1_candidate_location_2, suffix, rootDir, candidate);
				}
				final resolvedFileName = loader(r.extensions, candidate);
				if (!resolvedFileName.shouldContinueSearching()) {
					return resolvedFileName;
				}
			}
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Module_resolution_using_rootDirs_has_failed);
			}
		}
		return Module.continueSearching();
	}

	function nodeLoadModuleByRelativeName(extensions:Extensions, candidate:String, considerPackageJson:Bool):Null<Resolved> {
		final r = this;
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.Loading_module_as_file_Slash_folder_candidate_module_location_0_target_file_types_Colon_1, candidate,
				extensions.String());
		}
		if (!Tspath.HasTrailingDirectorySeparator(candidate)) {
			final parentOfCandidate = Tspath.GetDirectoryPath(candidate);
			if (!r.resolver.host.FS().DirectoryExists(parentOfCandidate)) {
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, parentOfCandidate);
				}
				return Module.continueSearching();
			}
			final resolvedFromFile = r.loadModuleFromFile(extensions, candidate);
			if (resolvedFromFile != null) {
				if (considerPackageJson) {
					final packageDirectory = Module.ParseNodeModuleFromPath(resolvedFromFile.path /*isFolder*/, false);
					if (packageDirectory != "") {
						resolvedFromFile.packageId = r.getPackageId(resolvedFromFile.path, r.getPackageJsonInfo(packageDirectory));
					}
				}
				return resolvedFromFile;
			}
		}
		if (!r.resolver.host.FS().DirectoryExists(candidate)) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Directory_0_does_not_exist_skipping_all_lookups_in_it, candidate);
			}
			return Module.continueSearching();
		}
		// esm mode relative imports shouldn't do any directory lookups (either inside `package.json`
		// files or implicit `index.js`es). This is a notable departure from cjs norms, where `./foo/pkg`
		// could have been redirected by `./foo/pkg/package.json` to an arbitrary location!
		if (!r.esmMode) {
			return r.loadNodeModuleFromDirectory(extensions, candidate, considerPackageJson);
		}
		return Module.continueSearching();
	}

	function loadModuleFromFile(extensions:Extensions, candidate:String):Null<Resolved> {
		final r = this;
		// ./foo.js -> ./foo.ts
		final resolvedByReplacingExtension = r.loadModuleFromFileNoImplicitExtensions(extensions, candidate);
		if (resolvedByReplacingExtension != null) {
			return resolvedByReplacingExtension;
		}

		// ./foo -> ./foo.ts
		if (!r.esmMode) {
			return r.tryAddingExtensions(candidate, extensions, "");
		}

		return Module.continueSearching();
	}

	function loadModuleFromFileNoImplicitExtensions(extensions:Extensions, candidate:String):Null<Resolved> {
		final r = this;
		final base = Tspath.GetBaseFileName(candidate);
		if (base.indexOf(".") < 0) {
			return Module.continueSearching(); // extensionless import, no lookups performed, since we don't support extensionless files
		}
		var extensionless = Tspath.RemoveFileExtension(candidate);
		if (extensionless == candidate) {
			// Once TS native extensions are handled, handle arbitrary extensions for declaration file mapping
			extensionless = candidate.substring(0, candidate.lastIndexOf("."));
		}

		final extension = candidate.substring(extensionless.length);
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.File_name_0_has_a_1_extension_stripping_it, candidate, extension);
		}
		return r.tryAddingExtensions(extensionless, extensions, extension);
	}

	function tryAddingExtensions(extensionless:String, extensions:Extensions, originalExtension:String):Null<Resolved> {
		final r = this;
		final directory = Tspath.GetDirectoryPath(extensionless);
		if (directory != "" && !r.resolver.host.FS().DirectoryExists(directory)) {
			return Module.continueSearching();
		}

		switch (originalExtension) {
			case Tspath.ExtensionMjs | Tspath.ExtensionMts | Tspath.ExtensionDmts:
				if ((extensions & extensionsTypeScript) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionMts, extensionless,
						originalExtension == Tspath.ExtensionMts || originalExtension == Tspath.ExtensionDmts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsDeclaration) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionDmts, extensionless,
						originalExtension == Tspath.ExtensionMts || originalExtension == Tspath.ExtensionDmts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsJavaScript) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionMjs, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
			case Tspath.ExtensionCjs | Tspath.ExtensionCts | Tspath.ExtensionDcts:
				if ((extensions & extensionsTypeScript) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionCts, extensionless,
						originalExtension == Tspath.ExtensionCts || originalExtension == Tspath.ExtensionDcts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsDeclaration) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionDcts, extensionless,
						originalExtension == Tspath.ExtensionCts || originalExtension == Tspath.ExtensionDcts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsJavaScript) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionCjs, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
			case Tspath.ExtensionJson:
				if ((extensions & extensionsDeclaration) != 0) {
					final resolved = r.tryExtension(".d.json.ts", extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsJson) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionJson, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
			case Tspath.ExtensionTsx | Tspath.ExtensionJsx:
				// basically idendical to the ts/js case below, but prefers matching tsx and jsx files exactly before falling back to the ts or js file path
				// (historically, we disallow having both a a.ts and a.tsx file in the same compilation, since their outputs clash)
				// TODO: We should probably error if `"./a.tsx"` resolved to `"./a.ts"`, right?
				if ((extensions & extensionsTypeScript) != 0) {
					{
						final resolved = r.tryExtension(Tspath.ExtensionTsx, extensionless, originalExtension == Tspath.ExtensionTsx);
						if (!resolved.shouldContinueSearching()) {
							return resolved;
						}
					}
					final resolved = r.tryExtension(Tspath.ExtensionTs, extensionless, originalExtension == Tspath.ExtensionTsx);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsDeclaration) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionDts, extensionless, originalExtension == Tspath.ExtensionTsx);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsJavaScript) != 0) {
					{
						final resolved = r.tryExtension(Tspath.ExtensionJsx, extensionless, false);
						if (!resolved.shouldContinueSearching()) {
							return resolved;
						}
					}
					final resolved = r.tryExtension(Tspath.ExtensionJs, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
			case Tspath.ExtensionTs | Tspath.ExtensionDts | Tspath.ExtensionJs | "":
				if ((extensions & extensionsTypeScript) != 0) {
					{
						final resolved = r.tryExtension(Tspath.ExtensionTs, extensionless,
							originalExtension == Tspath.ExtensionTs || originalExtension == Tspath.ExtensionDts);
						if (!resolved.shouldContinueSearching()) {
							return resolved;
						}
					}
					final resolved = r.tryExtension(Tspath.ExtensionTsx, extensionless,
						originalExtension == Tspath.ExtensionTs || originalExtension == Tspath.ExtensionDts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsDeclaration) != 0) {
					final resolved = r.tryExtension(Tspath.ExtensionDts, extensionless,
						originalExtension == Tspath.ExtensionTs || originalExtension == Tspath.ExtensionDts);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if ((extensions & extensionsJavaScript) != 0) {
					{
						final resolved = r.tryExtension(Tspath.ExtensionJs, extensionless, false);
						if (!resolved.shouldContinueSearching()) {
							return resolved;
						}
					}
					final resolved = r.tryExtension(Tspath.ExtensionJsx, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				if (r.isConfigLookup) {
					final resolved = r.tryExtension(Tspath.ExtensionJson, extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
			default:
				if ((extensions & extensionsDeclaration) != 0 && !Tspath.IsDeclarationFileName(extensionless + originalExtension)) {
					final resolved = r.tryExtension(".d" + originalExtension + ".ts", extensionless, false);
					if (!resolved.shouldContinueSearching()) {
						return resolved;
					}
				}
				return Module.continueSearching();
		}
	}

	function tryExtension(extension:String, extensionless:String, resolvedUsingTsExtension:Bool):Null<Resolved> {
		final r = this;
		final fileName = extensionless + extension;
		final f = r.tryFile(fileName);
		if (f.ok) {
			return new Resolved(f.value, extension, null, "", !r.candidateEndingIsFromConfig && resolvedUsingTsExtension);
		}
		return Module.continueSearching();
	}

	// PORT: (string, bool) → ValueOk.
	function tryFile(fileName:String):ValueOk<String> {
		final r = this;
		if (r.compilerOptions.ModuleSuffixes == null || r.compilerOptions.ModuleSuffixes.length == 0) {
			return new ValueOk(fileName, r.tryFileLookup(fileName));
		}

		final ext = Tspath.TryGetExtensionFromPath(fileName);
		final fileNameNoExtension = Tspath.RemoveExtension(fileName, ext);
		for (suffix in r.compilerOptions.ModuleSuffixes) {
			final path = fileNameNoExtension + suffix + ext;
			if (r.tryFileLookup(path)) {
				return new ValueOk(path, true);
			}
		}
		return new ValueOk(fileName, false);
	}

	function tryFileLookup(fileName:String):Bool {
		final r = this;
		if (r.resolver.host.FS().FileExists(fileName)) {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.File_0_exists_use_it_as_a_name_resolution_result, fileName);
			}
			return true;
		} else if (r.tracer != null) {
			r.tracer.write(Diagnostics.File_0_does_not_exist, fileName);
		}
		return false;
	}

	function loadNodeModuleFromDirectory(extensions:Extensions, candidate:String, considerPackageJson:Bool):Null<Resolved> {
		final r = this;
		var packageInfo:Null<InfoCacheEntry> = null;
		if (considerPackageJson) {
			packageInfo = r.getPackageJsonInfo(candidate);
		}

		return r.loadNodeModuleFromDirectoryWorker(extensions, candidate, packageInfo);
	}

	function loadNodeModuleFromDirectoryWorker(ext:Extensions, candidate:String, packageInfo:Null<InfoCacheEntry>):Null<Resolved> {
		final r = this;
		var packageFile = "";
		var versionPaths = new VersionPaths();
		if (packageInfo.Exists()) {
			versionPaths = packageInfo.Contents.GetVersionPaths(r.getTraceFunc());
			if (Tspath.ComparePaths(candidate, packageInfo.PackageDirectory, new ComparePathsOptions(r.resolver.host.FS().UseCaseSensitiveFileNames())) == 0) {
				final file = r.getPackageFile(ext, packageInfo);
				if (file.ok) {
					packageFile = file.value;
				}
			}
		}

		final loader = function(extensions:Extensions, candidate:String):Null<Resolved> {
			final fromFile = r.loadFileNameFromPackageJSONField(extensions, candidate, packageFile);
			if (!fromFile.shouldContinueSearching()) {
				return fromFile;
			}

			// Even if `extensions == extensionsDeclaration`, we can still look up a .ts file as a result of package.json "types"
			// !!! should we not set this before the filename lookup above?
			var expandedExtensions = extensions;
			if (extensions == extensionsDeclaration) {
				expandedExtensions = extensionsTypeScript | extensionsDeclaration;
			}

			// Disable `esmMode` for the resolution of the package path for CJS-mode packages (so the `main` field can omit extensions)
			final saveESMMode = r.esmMode;
			final saveCandidateEndingIsFromConfig = r.candidateEndingIsFromConfig;
			r.candidateEndingIsFromConfig = true;
			if (packageInfo.Exists() && packageInfo.Contents.Type.Value != "module") {
				r.esmMode = false;
			}
			final result = r.nodeLoadModuleByRelativeName(expandedExtensions, candidate, false /*considerPackageJson*/);
			r.esmMode = saveESMMode;
			r.candidateEndingIsFromConfig = saveCandidateEndingIsFromConfig;
			return result;
		};

		var indexPath:String;
		if (r.isConfigLookup) {
			indexPath = Tspath.CombinePaths(candidate, "tsconfig");
		} else {
			indexPath = Tspath.CombinePaths(candidate, "index");
		}

		if (versionPaths.Exists() && (packageFile == "" || Tspath.ContainsPath(candidate, packageFile, new ComparePathsOptions()))) {
			var moduleName:String;
			if (packageFile != "") {
				moduleName = Tspath.GetRelativePathFromDirectory(candidate, packageFile, new ComparePathsOptions());
			} else {
				moduleName = Tspath.GetRelativePathFromDirectory(candidate, indexPath, new ComparePathsOptions());
			}
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.X_package_json_has_a_typesVersions_entry_0_that_matches_compiler_version_1_looking_for_a_pattern_to_match_module_name_2,
					versionPaths.Version, Core.Version(), moduleName);
			}
			final pathPatterns = Module.TryParsePatterns(versionPaths.GetPaths());
			final result = r.tryLoadModuleUsingPaths(ext, moduleName, candidate, versionPaths.GetPaths(), pathPatterns, loader);
			if (!result.shouldContinueSearching()) {
				if (result.packageId.Name != "") {
					// !!! are these asserts really necessary?
					throw "expected packageId to be empty";
				}
				return result;
			}
		}

		if (packageFile != "") {
			final packageFileResult = loader(ext, packageFile);
			if (!packageFileResult.shouldContinueSearching()) {
				if (packageFileResult.packageId.Name != "") {
					// !!! are these asserts really necessary?
					throw "expected packageId to be empty";
				}
				return packageFileResult;
			}
		}

		// ESM mode resolutions don't do package 'index' lookups
		if (!r.esmMode) {
			if (!r.resolver.host.FS().DirectoryExists(candidate)) {
				return Module.continueSearching();
			}
			return r.loadModuleFromFile(ext, indexPath);
		}
		return Module.continueSearching();
	}

	// This function is only ever called with paths written in package.json files - never
	// module specifiers written in source files - and so it always allows the
	// candidate to end with a TS extension (but will also try substituting a JS extension for a TS extension).
	function loadFileNameFromPackageJSONField(extensions:Extensions, candidate:String, packageJSONValue:String):Null<Resolved> {
		final r = this;
		if (((extensions & extensionsTypeScript) != 0 && Tspath.HasImplementationTSFileExtension(candidate))
			|| ((extensions & extensionsDeclaration) != 0 && Tspath.IsDeclarationFileName(candidate))) {
			final f = r.tryFile(candidate);
			if (f.ok) {
				final path = f.value;
				final extension = Tspath.TryExtractTSExtension(path);
				// resolvedUsingTsExtension should be true when the pattern ends with * and the
				// candidate file ends in a TS extension. This means the * matched a TS extension
				// from the module specifier. For example:
				// - import "pkg/foo.ts" with pattern "./*" -> true
				// - import "pkg/foo.ts.omg" with pattern "./*.omg" -> true (star matched .ts)
				// - import "pkg/foo" with pattern "./*.ts" -> false (extension in pattern, not specifier)
				final resolvedUsingTsExtension = StringTools.endsWith(packageJSONValue, "*") && extension != "";
				return new Resolved(path, extension, null, "", resolvedUsingTsExtension);
			}
			return Module.continueSearching();
		}

		if (r.isConfigLookup && (extensions & extensionsJson) != 0 && Tspath.FileExtensionIs(candidate, Tspath.ExtensionJson)) {
			final f = r.tryFile(candidate);
			if (f.ok) {
				return new Resolved(f.value, Tspath.ExtensionJson);
			}
		}

		return r.loadModuleFromFileNoImplicitExtensions(extensions, candidate);
	}

	// PORT: (string, bool) → ValueOk.
	function getPackageFile(extensions:Extensions, packageInfo:Null<InfoCacheEntry>):ValueOk<String> {
		final r = this;
		if (!packageInfo.Exists()) {
			return new ValueOk("", false);
		}
		if (r.isConfigLookup) {
			return r.getPackageJSONPathField("tsconfig", packageInfo.Contents.TSConfig, packageInfo.PackageDirectory);
		}
		if ((extensions & extensionsDeclaration) != 0) {
			{
				final packageFile = r.getPackageJSONPathField("typings", packageInfo.Contents.Typings, packageInfo.PackageDirectory);
				if (packageFile.ok) {
					return packageFile;
				}
			}
			final packageFile = r.getPackageJSONPathField("types", packageInfo.Contents.Types, packageInfo.PackageDirectory);
			if (packageFile.ok) {
				return packageFile;
			}
		}
		if ((extensions & (extensionsImplementationFiles | extensionsDeclaration)) != 0) {
			return r.getPackageJSONPathField("main", packageInfo.Contents.Main, packageInfo.PackageDirectory);
		}
		return new ValueOk("", false);
	}

	function getPackageJsonInfo(packageDirectory:String):Null<InfoCacheEntry> {
		final r = this;
		final packageJsonPath = Tspath.CombinePaths(packageDirectory, "package.json");

		final existing = r.resolver.caches.packageJsonInfoCache.Get(packageJsonPath);
		if (existing != null) {
			if (existing.Contents != null) {
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.File_0_exists_according_to_earlier_cached_lookups, packageJsonPath);
				}
				return existing.WithPackageDirectory(packageDirectory);
			} else {
				if (existing.DirectoryExists && r.tracer != null) {
					r.tracer.write(Diagnostics.File_0_does_not_exist_according_to_earlier_cached_lookups, packageJsonPath);
				}
				return null;
			}
		}

		final directoryExists = r.resolver.host.FS().DirectoryExists(packageDirectory);
		if (directoryExists && r.resolver.host.FS().FileExists(packageJsonPath)) {
			// Ignore error
			final contents = r.resolver.host.FS().ReadFile(packageJsonPath).value;
			final parsed = Packagejson.Parse(contents);
			final packageJsonContent = parsed.value, err = parsed.err;
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Found_package_json_at_0, packageJsonPath);
			}
			final contentsJson = new PackageJson();
			contentsJson.Fields = packageJsonContent;
			contentsJson.Parseable = err == null;
			var result = new InfoCacheEntry(packageDirectory, true, contentsJson);
			result = r.resolver.caches.packageJsonInfoCache.Set(packageJsonPath, result);
			return result.WithPackageDirectory(packageDirectory);
		} else {
			if (directoryExists && r.tracer != null) {
				r.tracer.write(Diagnostics.File_0_does_not_exist, packageJsonPath);
			}
			r.resolver.caches.packageJsonInfoCache.Set(packageJsonPath, new InfoCacheEntry(packageDirectory, directoryExists));
		}
		return null;
	}

	function getPackageId(resolvedFileName:String, packageInfo:Null<InfoCacheEntry>):PackageId {
		final r = this;
		if (packageInfo.Exists()) {
			final packageJsonContent = packageInfo.Contents;
			final name = packageJsonContent.Name.GetValue();
			if (name.ok) {
				final version = packageJsonContent.Version.GetValue();
				if (version.ok) {
					var subModuleName = "";
					if (resolvedFileName.length > packageInfo.PackageDirectory.length) {
						subModuleName = resolvedFileName.substring(packageInfo.PackageDirectory.length + 1);
					}
					return new PackageId(name.value, subModuleName, version.value, r.readPackageJsonPeerDependencies(packageInfo));
				}
			}
		}
		return new PackageId();
	}

	function readPackageJsonPeerDependencies(packageJsonInfo:InfoCacheEntry):String {
		final r = this;
		final peerDependencies = packageJsonInfo.Contents.PeerDependencies;
		final ok = r.validatePackageJSONField("peerDependencies", peerDependencies);
		if (!ok || mapLen(peerDependencies.Value) == 0) {
			return "";
		}
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.X_package_json_has_a_peerDependencies_field);
		}
		final packageDirectory = r.realPath(packageJsonInfo.PackageDirectory);
		final nodeModulesIndex = packageDirectory.lastIndexOf("/node_modules");
		if (nodeModulesIndex == -1) {
			return "";
		}
		final nodeModules = packageDirectory.substring(0, nodeModulesIndex + "/node_modules".length) + "/";
		final names = [for (k in peerDependencies.Value.keys()) k];
		Slices.SortFunc(names, Strings.Compare);
		final builder = new StringBuf();
		for (name in names) {
			final peerPackageJson = r.getPackageJsonInfo(nodeModules + name);
			if (peerPackageJson.Exists()) {
				final version = peerPackageJson.Contents.Version.Value;
				builder.add("+");
				builder.add(name);
				builder.add("@");
				builder.add(version);
				if (r.tracer != null) {
					r.tracer.write(Diagnostics.Found_peerDependency_0_with_1_version, name, version);
				}
			} else if (r.tracer != null) {
				r.tracer.write(Diagnostics.Failed_to_find_peerDependency_0, name);
			}
		}
		return builder.toString();
	}

	// PORT: len() of a possibly-nil map.
	static function mapLen(m:Null<haxe.ds.StringMap<String>>):Int {
		if (m == null)
			return 0;
		var n = 0;
		for (_ in m.keys())
			n++;
		return n;
	}

	function realPath(path:String):String {
		final r = this;
		final rp = Tspath.NormalizePath(r.resolver.host.FS().Realpath(path));
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.Resolving_real_path_for_0_result_1, path, rp);
		}
		return rp;
	}

	function validatePackageJSONField(fieldName:String, field:TypeValidatedField):Bool {
		final r = this;
		if (field.IsPresent()) {
			if (field.IsValid()) {
				return true;
			}
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.Expected_type_of_0_field_in_package_json_to_be_1_got_2, fieldName, field.ExpectedJSONType(),
					field.ActualJSONType());
			}
		}
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.X_package_json_does_not_have_a_0_field, fieldName);
		}
		return false;
	}

	// PORT: (string, bool) → ValueOk.
	function getPackageJSONPathField(fieldName:String, field:Expected<String>, directory:String):ValueOk<String> {
		final r = this;
		if (!r.validatePackageJSONField(fieldName, field)) {
			return new ValueOk("", false);
		}
		if (field.Value == "") {
			if (r.tracer != null) {
				r.tracer.write(Diagnostics.X_package_json_had_a_falsy_0_field, fieldName);
			}
			return new ValueOk("", false);
		}
		final path = Tspath.NormalizePath(Tspath.CombinePaths(directory, field.Value));
		if (r.tracer != null) {
			r.tracer.write(Diagnostics.X_package_json_has_0_field_1_that_references_2, fieldName, field.Value, path);
		}
		return new ValueOk(path, true);
	}

	function conditionMatches(condition:String):Bool {
		final r = this;
		if (condition == "default" || Slices.Contains(r.conditions, condition)) {
			return true;
		}
		if (!Slices.Contains(r.conditions, "types")) {
			return false; // only apply versioned types conditions if the types condition is applied
		}
		return Module.IsApplicableVersionedTypesKey(condition);
	}

	// PORT: Go returns the method value `r.tracer.write` (variadic); here `writeArgs`.
	function getTraceFunc():Null<(m:Message, args:Array<Any>) -> Void> {
		final r = this;
		if (r.tracer != null) {
			return r.tracer.writeArgs;
		}
		return null;
	}

	function loadEntrypointsFromExportMap(packageJson:InfoCacheEntry, packageName:String, exports:ExportsOrImports):Null<Array<ResolvedEntrypoint>> {
		final r = this;
		var loadEntrypointsFromTargetExports:(subpath:String, includeConditions:Null<Set<String>>, excludeConditions:Null<Set<String>>,
			exports:ExportsOrImports) -> Void = null;
		var entrypoints:Null<Array<ResolvedEntrypoint>> = null;

		loadEntrypointsFromTargetExports = function(subpath:String, includeConditions:Null<Set<String>>, excludeConditions:Null<Set<String>>,
				exports:ExportsOrImports):Void {
			if (exports.Type == JSONValueTypeString && StringTools.startsWith(exports.AsString(), "./")) {
				if (exports.AsString().indexOf("*") >= 0) {
					if (exports.AsString().indexOf("*") != exports.AsString().lastIndexOf("*")) {
						return;
					}
					final patternPath = Tspath.ResolvePath(packageJson.PackageDirectory, exports.AsString());
					final starIndex = patternPath.indexOf("*");
					final leadingSlice = starIndex < 0 ? patternPath : patternPath.substring(0, starIndex);
					final trailingSlice = starIndex < 0 ? "" : patternPath.substring(starIndex + 1);
					final caseSensitive = r.resolver.host.FS().UseCaseSensitiveFileNames();
					final files = Vfsmatch.ReadDirectory(r.resolver.host.FS(), r.resolver.host.GetCurrentDirectory(), packageJson.PackageDirectory,
						r.extensions.Array(), null, [Tspath.ChangeFullExtension(replaceFirst(exports.AsString(), "*", "**/*"), ".*")],
						Vfsmatch.UnlimitedDepth);
					if (files != null) {
						for (file in files) {
							final m = r.getMatchedStarForPatternEntrypoint(file, leadingSlice, trailingSlice, caseSensitive);
							if (!m.ok) {
								continue;
							}
							final matchedStar = m.value;
							final moduleSpecifier = Tspath.ResolvePath(packageName, replaceFirst(subpath, "*", matchedStar));
							if (entrypoints == null)
								entrypoints = [];
							entrypoints.push(r.resolver.createResolvedEntrypointHandlingSymlink(file, moduleSpecifier, includeConditions, excludeConditions,
								Core.IfElse(StringTools.endsWith(exports.AsString(), "*"), EndingExtensionChangeable, EndingFixed)));
						}
					}
				} else {
					final partsAfterFirst = Tspath.GetPathComponents(exports.AsString(), "").slice(2);
					if (Slices.Contains(partsAfterFirst, "..") || Slices.Contains(partsAfterFirst, ".") || Slices.Contains(partsAfterFirst, "node_modules")) {
						return;
					}
					final resolvedTarget = Tspath.ResolvePath(packageJson.PackageDirectory, exports.AsString());
					final result = r.loadFileNameFromPackageJSONField(r.extensions, resolvedTarget, exports.AsString());
					if (result.isResolved()) {
						if (entrypoints == null)
							entrypoints = [];
						entrypoints.push(r.resolver.createResolvedEntrypointHandlingSymlink(result.path, Tspath.ResolvePath(packageName, subpath),
							includeConditions, excludeConditions, Core.IfElse(StringTools.endsWith(exports.AsString(), "*"), EndingExtensionChangeable, EndingFixed)));
					}
				}
			} else if (exports.Type == JSONValueTypeArray) {
				for (element in exports.AsArray()) {
					loadEntrypointsFromTargetExports(subpath, includeConditions, excludeConditions, element);
				}
			} else if (exports.Type == JSONValueTypeObject) {
				var prevConditions:Null<Array<String>> = null;
				for (condition => export in exports.AsObject().Entries()) {
					if (excludeConditions != null && excludeConditions.Has(condition)) {
						continue;
					}

					final conditionAlwaysMatches = condition == "default" || condition == "types" || Module.IsApplicableVersionedTypesKey(condition);
					var newIncludeConditions = includeConditions;
					if (!conditionAlwaysMatches) {
						newIncludeConditions = includeConditions.Clone();
						excludeConditions = excludeConditions.Clone();
						if (newIncludeConditions == null) {
							newIncludeConditions = new Set<String>();
						}
						newIncludeConditions.Add(condition);
						if (prevConditions != null) {
							for (prevCondition in prevConditions) {
								if (excludeConditions == null) {
									excludeConditions = new Set<String>();
								}
								excludeConditions.Add(prevCondition);
							}
						}
					}

					if (prevConditions == null)
						prevConditions = [];
					prevConditions.push(condition);
					loadEntrypointsFromTargetExports(subpath, newIncludeConditions, excludeConditions, export);
					if (conditionAlwaysMatches) {
						break;
					}
				}
			}
		};

		switch (exports.Type) {
			case JSONValueTypeArray:
				for (element in exports.AsArray()) {
					loadEntrypointsFromTargetExports(".", null, null, element);
				}
			case JSONValueTypeObject:
				if (exports.IsSubpaths()) {
					for (subpath => export in exports.AsObject().Entries()) {
						loadEntrypointsFromTargetExports(subpath, null, null, export);
					}
				} else {
					loadEntrypointsFromTargetExports(".", null, null, exports);
				}
			default:
				loadEntrypointsFromTargetExports(".", null, null, exports);
		}

		return entrypoints;
	}

	// PORT: (string, bool) → ValueOk.
	function getMatchedStarForPatternEntrypoint(file:String, leadingSlice:String, trailingSlice:String, caseSensitive:Bool):ValueOk<String> {
		final r = this;
		if (Stringutil.HasPrefixAndSuffixWithoutOverlap(file, leadingSlice, trailingSlice, caseSensitive)) {
			return new ValueOk(file.substring(leadingSlice.length, file.length - trailingSlice.length), true);
		}

		final jsExtension = Module.TryGetJSExtensionForFile(file, r.compilerOptions);
		if (jsExtension.length > 0) {
			final swapped = Tspath.ChangeFullExtension(file, jsExtension);
			if (Stringutil.HasPrefixAndSuffixWithoutOverlap(swapped, leadingSlice, trailingSlice, caseSensitive)) {
				return new ValueOk(swapped.substring(leadingSlice.length, swapped.length - trailingSlice.length), true);
			}
		}

		return new ValueOk("", false);
	}

	// PORT: len() of a possibly-nil slice.
	static inline function len<T>(s:Null<Array<T>>):Int {
		return s == null ? 0 : s.length;
	}
}

class Resolver {
	// PORT: embedded `caches` → composition field.
	public var caches:Caches = new Caches();
	public var host:ResolutionHost = null;
	public var compilerOptions:CompilerOptions = null;
	public var typingsLocation:String = "";
	public var projectName:String = "";

	// reportDiagnostic: DiagnosticReporter

	public function new() {}

	function newTraceBuilder():Null<Tracer> {
		if (this.compilerOptions.TraceResolution == TSTrue) {
			return new Tracer();
		}
		return null;
	}

	public function GetPackageScopeForPath(directory:String):Null<InfoCacheEntry> {
		final state = new ResolutionState();
		state.compilerOptions = this.compilerOptions;
		state.resolver = this;
		return state.getPackageScopeForPath(directory);
	}

	public function PackageJsonCacheEntries(f:(key:Path, value:InfoCacheEntry) -> Bool):Void {
		this.caches.packageJsonInfoCache.Range(f);
	}

	// PORT: (*ResolvedTypeReferenceDirective, []DiagAndArgs) → Pair.
	public function ResolveTypeReferenceDirective(typeReferenceDirectiveName:String, containingFile:String, resolutionMode:ResolutionMode,
			redirectedReference:Null<ResolvedProjectReference>):Pair<ResolvedTypeReferenceDirective, Null<Array<DiagAndArgs>>> {
		final r = this;
		final containingDirectory = Tspath.GetDirectoryPath(containingFile);
		final traceBuilder = r.newTraceBuilder();

		final fromInferredTypesContainingFile = StringTools.endsWith(containingFile, Module.InferredTypesContainingFile);

		final cacheKey = new TypeRefDirectiveResolutionCacheKey(containingDirectory, typeReferenceDirectiveName, resolutionMode,
			Module.getRedirectConfigName(redirectedReference), fromInferredTypesContainingFile);

		if (traceBuilder == null) {
			final cached = r.caches.typeRefDirectiveResolutionCache.Get(cacheKey);
			if (cached.ok) {
				return new Pair(cached.value, null);
			}
		}

		final compilerOptions = Module.GetCompilerOptionsWithRedirect(r.compilerOptions, redirectedReference);

		final tr = compilerOptions.GetEffectiveTypeRoots(r.host.GetCurrentDirectory());
		final typeRoots = tr.value, fromConfig = tr.ok;
		if (traceBuilder != null) {
			traceBuilder.write(Diagnostics.Resolving_type_reference_directive_0_containing_file_1_root_directory_2, typeReferenceDirectiveName,
				containingFile, typeRoots == null ? "" : typeRoots.join(","));
			traceBuilder.traceResolutionUsingProjectReference(redirectedReference);
		}

		final state = Module.newResolutionState(typeReferenceDirectiveName, containingDirectory, true /*isTypeReferenceDirective*/, resolutionMode,
			compilerOptions, redirectedReference, r, traceBuilder);
		final result = state.resolveTypeReferenceDirective(typeRoots, fromConfig, fromInferredTypesContainingFile);

		if (traceBuilder != null) {
			traceBuilder.traceTypeReferenceDirectiveResult(typeReferenceDirectiveName, result);
		}

		r.caches.typeRefDirectiveResolutionCache.Set(cacheKey, result);

		return new Pair(result, traceBuilder.getTraces());
	}

	// PORT: (*ResolvedModule, []DiagAndArgs) → Pair.
	public function ResolveModuleName(moduleName:String, containingFile:String, resolutionMode:ResolutionMode,
			redirectedReference:Null<ResolvedProjectReference>):Pair<ResolvedModule, Null<Array<DiagAndArgs>>> {
		final r = this;
		final containingDirectory = Tspath.GetDirectoryPath(containingFile);
		final traceBuilder = r.newTraceBuilder();

		final cacheKey = new ModuleResolutionCacheKey(containingDirectory, moduleName, resolutionMode, Module.getRedirectConfigName(redirectedReference));

		if (traceBuilder == null) {
			final cached = r.caches.moduleResolutionCache.Get(cacheKey);
			if (cached.ok) {
				return new Pair(cached.value, null);
			}
		}

		final compilerOptions = Module.GetCompilerOptionsWithRedirect(r.compilerOptions, redirectedReference);
		if (traceBuilder != null) {
			traceBuilder.write(Diagnostics.Resolving_module_0_from_1, moduleName, containingFile);
			traceBuilder.traceResolutionUsingProjectReference(redirectedReference);
		}

		final moduleResolution = compilerOptions.GetModuleResolutionKind();
		if (compilerOptions.ModuleResolution != moduleResolution) {
			if (traceBuilder != null) {
				traceBuilder.write(Diagnostics.Module_resolution_kind_is_not_specified_using_0, moduleResolution.String());
			}
		} else {
			if (traceBuilder != null) {
				traceBuilder.write(Diagnostics.Explicitly_specified_module_resolution_kind_Colon_0, moduleResolution.String());
			}
		}

		var result:ResolvedModule;
		switch (moduleResolution) {
			case ModuleResolutionKindNode16 | ModuleResolutionKindNodeNext | ModuleResolutionKindBundler:
				final state = Module.newResolutionState(moduleName, containingDirectory, false /*isTypeReferenceDirective*/, resolutionMode,
					compilerOptions, redirectedReference, r, traceBuilder);
				result = state.resolveNodeLike();
			default:
				throw "Unexpected moduleResolution: " + (moduleResolution : Int);
		}

		if (traceBuilder != null) {
			if (result.IsResolved()) {
				if (result.PackageId.Name != "") {
					traceBuilder.write(Diagnostics.Module_name_0_was_successfully_resolved_to_1_with_Package_ID_2, moduleName, result.ResolvedFileName,
						result.PackageId.String());
				} else {
					traceBuilder.write(Diagnostics.Module_name_0_was_successfully_resolved_to_1, moduleName, result.ResolvedFileName);
				}
			} else {
				traceBuilder.write(Diagnostics.Module_name_0_was_not_resolved, moduleName);
			}
		}

		final finalResult = r.tryResolveFromTypingsLocation(moduleName, containingDirectory, result, traceBuilder);
		r.caches.moduleResolutionCache.Set(cacheKey, finalResult);

		return new Pair(finalResult, traceBuilder.getTraces());
	}

	public function ResolvePackageDirectory(moduleName:String, containingFile:String, resolutionMode:ResolutionMode,
			redirectedReference:Null<ResolvedProjectReference>):Null<ResolvedModule> {
		final r = this;
		final compilerOptions = Module.GetCompilerOptionsWithRedirect(r.compilerOptions, redirectedReference);
		final containingDirectory = Tspath.GetDirectoryPath(containingFile);
		final state = Module.newResolutionState(moduleName, containingDirectory, false /*isTypeReferenceDirective*/, resolutionMode, compilerOptions,
			redirectedReference, r, null);
		state.resolvePackageDirectoryOnly = true;
		final result = state.loadModuleFromNearestNodeModulesDirectory(false /*typesScopeOnly*/);
		if (result != null && result.path != "") {
			return state.createResolvedModuleHandlingSymlink(result);
		}
		return null;
	}

	function tryResolveFromTypingsLocation(moduleName:String, containingDirectory:String, originalResult:ResolvedModule,
			traceBuilder:Null<Tracer>):ResolvedModule {
		final r = this;
		if (r.typingsLocation == ""
			|| Tspath.IsExternalModuleNameRelative(moduleName)
			|| (originalResult.ResolvedFileName != "" && Tspath.ExtensionIsOneOf(originalResult.Extension, Tspath.SupportedTSExtensionsWithJsonFlat))) {
			return originalResult;
		}

		final state = Module.newResolutionState(moduleName, containingDirectory, false, /*isTypeReferenceDirective*/
			ModuleKindNone, // resolutionMode,
			r.compilerOptions, null, // redirectedReference,
			r, traceBuilder);
		if (traceBuilder != null) {
			traceBuilder.write(Diagnostics.Auto_discovery_for_typings_is_enabled_in_project_0_Running_extra_resolution_pass_for_module_1_using_cache_location_2,
				r.projectName, moduleName, r.typingsLocation);
		}
		final globalResolved = state.loadModuleFromImmediateNodeModulesDirectory(extensionsDeclaration, r.typingsLocation, false);
		if (globalResolved == null) {
			return originalResult;
		}
		final result = state.createResolvedModule(globalResolved, true);
		// PORT: append(a, b...) — a new array when b is not empty.
		if (result.ResolutionDiagnostics != null && result.ResolutionDiagnostics.length > 0) {
			result.ResolutionDiagnostics = (originalResult.ResolutionDiagnostics == null ? [] : originalResult.ResolutionDiagnostics)
				.concat(result.ResolutionDiagnostics);
		} else {
			result.ResolutionDiagnostics = originalResult.ResolutionDiagnostics;
		}
		return result;
	}

	@:allow(ts.module)
	function resolveConfig(moduleName:String, containingFile:String):ResolvedModule {
		final r = this;
		final containingDirectory = Tspath.GetDirectoryPath(containingFile);
		final state = Module.newResolutionState(moduleName, containingDirectory, false /*isTypeReferenceDirective*/, ModuleKindCommonJS,
			r.compilerOptions, null, r, null);
		state.isConfigLookup = true;
		state.extensions = extensionsJson;
		return state.resolveNodeLike();
	}

	@:allow(ts.module)
	function getParsedPatternsForPaths():ParsedPatterns {
		final r = this;
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!r.caches.parsedPatternsForPathsOnce) {
			r.caches.parsedPatternsForPathsOnce = true;
			r.caches.parsedPatternsForPaths = Module.TryParsePatterns(r.compilerOptions.Paths);
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return r.caches.parsedPatternsForPaths;
	}

	public function GetEntrypointsFromPackageJsonInfo(packageJson:InfoCacheEntry, packageName:String,
			enableDirectorySearch:Bool):Null<Array<ResolvedEntrypoint>> {
		final r = this;
		final extensions = extensionsTypeScript | extensionsDeclaration;
		final features = NodeResolutionFeaturesAll;
		final state = new ResolutionState();
		state.resolver = r;
		state.extensions = extensions;
		state.features = features;
		state.compilerOptions = r.compilerOptions;
		if (packageJson.Exists() && packageJson.Contents.Exports.IsPresent()) {
			final entrypoints = state.loadEntrypointsFromExportMap(packageJson, packageName, packageJson.Contents.Exports);
			return entrypoints;
		}

		var result:Null<Array<ResolvedEntrypoint>> = null;
		final mainResolution = state.loadNodeModuleFromDirectoryWorker(extensions, packageJson.PackageDirectory, packageJson);

		if (mainResolution.isResolved()) {
			result = [r.createResolvedEntrypointHandlingSymlink(mainResolution.path, packageName, null, null, EndingFixed)];
		}

		if (enableDirectorySearch) {
			final otherFiles = Vfsmatch.ReadDirectory(r.host.FS(), r.host.GetCurrentDirectory(), packageJson.PackageDirectory, extensions.Array(),
				["node_modules"], ["**/*"], Vfsmatch.UnlimitedDepth);

			final comparePathsOptions = new ComparePathsOptions(r.host.FS().UseCaseSensitiveFileNames());
			if (otherFiles != null) {
				for (file in otherFiles) {
					if (mainResolution.isResolved() && Tspath.ComparePaths(file, mainResolution.path, comparePathsOptions) == 0) {
						continue;
					}

					if (result == null)
						result = [];
					result.push(r.createResolvedEntrypointHandlingSymlink(file,
						Tspath.ResolvePath(packageName, Tspath.GetRelativePathFromDirectory(packageJson.PackageDirectory, file, comparePathsOptions)), null,
						null, EndingChangeable));
				}
			}
		}

		if (result != null && result.length > 0) {
			return result;
		}
		return null;
	}

	@:allow(ts.module)
	function createResolvedEntrypointHandlingSymlink(fileName:String, moduleSpecifier:String, includeConditions:Null<Set<String>>,
			excludeConditions:Null<Set<String>>, ending:Ending):ResolvedEntrypoint {
		var originalFileName = "";
		var resolvedFileName = fileName;
		final realPath = this.host.FS().Realpath(fileName);
		if (realPath != fileName) {
			originalFileName = fileName;
			resolvedFileName = realPath;
		}
		final e = new ResolvedEntrypoint();
		e.OriginalFileName = originalFileName;
		e.ResolvedFileName = resolvedFileName;
		e.ModuleSpecifier = moduleSpecifier;
		e.IncludeConditions = includeConditions;
		e.ExcludeConditions = excludeConditions;
		e.Ending = ending;
		return e;
	}
}

class ResolverOptions {
	public var PackageJsonCache:Null<InfoCache> = null;

	public function new(?PackageJsonCache:InfoCache) {
		this.PackageJsonCache = PackageJsonCache;
	}
}

class ParsedPatterns {
	public var matchableStringSet:Set<String>;
	public var patterns:Null<Array<Pattern>>;

	public function new(matchableStringSet:Set<String>, patterns:Null<Array<Pattern>>) {
		this.matchableStringSet = matchableStringSet;
		this.patterns = patterns;
	}
}

enum abstract Ending(Int) from Int to Int {
	// EndingFixed indicates that the module specifier cannot be changed without changing its resolution.
	var EndingFixed = 0;
	// EndingExtensionChangeable indicates that the module specifier's extension portion was inferred from a
	// file on disk, so an interchangeable one could be used instead (e.g. replacing .d.ts with .js).
	var EndingExtensionChangeable = 1;
	// EndingChangeable indicates that the module specifier's file name and extension portion were inferred
	// from a file on disk without being matched as part of an 'exports' pattern, so can be changed according
	// to the importer's module resolution rules (e.g. an /index.d.ts may be dropped entirely in CommonJS settings).
	var EndingChangeable = 2;
}

class ResolvedEntrypoint {
	// OriginalFileName is the symlink path if the entrypoint was discovered at a symlink. Empty otherwise.
	public var OriginalFileName:String = "";
	// ResolvedFileName is the real path to the entrypoint file.
	public var ResolvedFileName:String = "";
	public var ModuleSpecifier:String = "";
	// Ending indicates whether the file name and extension portion of ModuleSpecifier is fixed or can be changed.
	public var Ending:Ending = EndingFixed;
	// IncludeConditions are the conditions that a resolver must have to reach this entrypoint.
	public var IncludeConditions:Null<Set<String>> = null;
	// ExcludeConditions are the conditions that a resolver must not have to reach this entrypoint.
	public var ExcludeConditions:Null<Set<String>> = null;

	public function new() {}

	public function SymlinkOrRealpath():String {
		if (this.OriginalFileName != "") {
			return this.OriginalFileName;
		}
		return this.ResolvedFileName;
	}
}
