package ts.modulespecifiers;

import ts.ast.Ast.HasFileName;
import ts.ast.Ast.SourceFile;
import ts.ast.Ast.Node;
import ts.ast.Ast.StringLiteralLike;
import ts.ast.Symbol;
import ts.packagejson.Cache.VersionPaths;
import ts.packagejson.Exportsorimports.ExportsOrImports;
import ts.module.Resolver.ResolvedEntrypoint;
import ts.tspath.Path.ComparePathsOptions;

// Port of internal/modulespecifiers: package-level funcs and vars of all files (Go file order).
@:allow(ts.modulespecifiers)
class Modulespecifiers {
	// --- compare.go ---

	public static function CountPathComponents(path:String):Int {
		var initial = 0;
		if (StringTools.startsWith(path, "./")) {
			initial = 2;
		}
		return Strings.Count(path.substring(initial), "/");
	}

	// --- preferences.go ---

	// Program errors validate that `noEmit` or `emitDeclarationOnly` is also set,
	// so this function doesn't check them to avoid propagating errors.
	static function shouldAllowImportingTsExtension(compilerOptions:CompilerOptions, fromFileName:String):Bool {
		return compilerOptions.GetAllowImportingTsExtensions() || fromFileName.length > 0 && Tspath.IsDeclarationFileName(fromFileName);
	}

	static function usesExtensionsOnImports(file:SourceFileForSpecifierGeneration):Bool {
		final imports = file.Imports();
		if (imports != null) {
			for (ref in imports) {
				final text = ref.Text();
				if (Tspath.PathIsRelative(text) && !Tspath.FileExtensionIsOneOf(text, Tspath.ExtensionsNotSupportingExtensionlessResolution)) {
					return Tspath.HasTSFileExtension(text) || Tspath.HasJSFileExtension(text);
				}
			}
		}
		return false;
	}

	static function inferPreference(resolutionMode:ResolutionMode, sourceFile:SourceFileForSpecifierGeneration,
			moduleResolutionIsNodeNext:Bool):ModuleSpecifierEnding {
		var usesJsExtensions = false;
		var specifiers:Array<Node> = null;
		if (sourceFile != null && Core.len(sourceFile.Imports()) > 0) {
			specifiers = sourceFile.Imports();
		} else if (sourceFile != null && sourceFile.IsJS()) {
			// !!! TODO: JS support
			// specifiers = core.Map(getRequiresAtTopOfFile(sourceFile), func(d *ast.Node) *ast.Node { return d.arguments[0] })
		}

		if (specifiers != null) {
			for (specifier in specifiers) {
				final path = specifier.Text();
				if (Tspath.PathIsRelative(path)) {
					// !!! TODO: proper resolutionMode support
					if (moduleResolutionIsNodeNext
						&& resolutionMode == Core.ResolutionModeCommonJS /* && getModeForUsageLocation(sourceFile!, specifier, compilerOptions) === ModuleKind.ESNext */) {
						// We're trying to decide a preference for a CommonJS module specifier, but looking at an ESM import.
						continue;
					}
					if (Tspath.FileExtensionIsOneOf(path, Tspath.ExtensionsNotSupportingExtensionlessResolution)) {
						// These extensions are not optional, so do not indicate a preference.
						continue;
					}
					if (Tspath.HasTSFileExtension(path)) {
						return ModuleSpecifierEndingTsExtension;
					}
					if (Tspath.HasJSFileExtension(path)) {
						usesJsExtensions = true;
					}
				}
			}
		}

		if (usesJsExtensions) {
			return ModuleSpecifierEndingJsExtension;
		}
		return ModuleSpecifierEndingMinimal;
	}

	static function getModuleSpecifierEndingPreference(pref:ImportModuleSpecifierEndingPreference, resolutionMode:ResolutionMode,
			compilerOptions:CompilerOptions, sourceFile:SourceFileForSpecifierGeneration):ModuleSpecifierEnding {
		final moduleResolution = compilerOptions.GetModuleResolutionKind();
		final moduleResolutionIsNodeNext = ModuleResolutionKindNode16 <= moduleResolution && moduleResolution <= ModuleResolutionKindNodeNext;

		if (pref == ImportModuleSpecifierEndingPreferenceJs || resolutionMode == Core.ResolutionModeESM && moduleResolutionIsNodeNext) {
			// Extensions are explicitly requested or required. Now choose between .js and .ts.
			if (!shouldAllowImportingTsExtension(compilerOptions, "")) {
				return ModuleSpecifierEndingJsExtension;
			}
			// `allowImportingTsExtensions` is a strong signal, so use .ts unless the file
			// already uses .js extensions and no .ts extensions.
			if (inferPreference(resolutionMode, sourceFile, moduleResolutionIsNodeNext) != ModuleSpecifierEndingJsExtension) {
				return ModuleSpecifierEndingTsExtension;
			}
			return ModuleSpecifierEndingJsExtension;
		}

		if (pref == ImportModuleSpecifierEndingPreferenceMinimal) {
			return ModuleSpecifierEndingMinimal;
		}

		if (pref == ImportModuleSpecifierEndingPreferenceIndex) {
			return ModuleSpecifierEndingIndex;
		}

		// No preference was specified.
		// Look at imports and/or requires to guess whether .js, .ts, or extensionless imports are preferred.
		// N.B. that `Index` detection is not supported since it would require file system probing to do
		// accurately, and more importantly, literally nobody wants `Index` and its existence is a mystery.
		if (!shouldAllowImportingTsExtension(compilerOptions, "")) {
			// If .ts imports are not valid, we only need to see one .js import to go with that.
			if (sourceFile != null && usesExtensionsOnImports(sourceFile)) {
				return ModuleSpecifierEndingJsExtension;
			}
			return ModuleSpecifierEndingMinimal;
		}

		return inferPreference(resolutionMode, sourceFile, moduleResolutionIsNodeNext);
	}

	static function getPreferredEnding(prefs:UserPreferences, host:ModuleSpecifierGenerationHost, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, oldImportSpecifier:String, resolutionMode:ResolutionMode):ModuleSpecifierEnding {
		if (oldImportSpecifier.length > 0) {
			if (Tspath.HasJSFileExtension(oldImportSpecifier)) {
				return ModuleSpecifierEndingJsExtension;
			}
			if (StringTools.endsWith(oldImportSpecifier, "/index")) {
				return ModuleSpecifierEndingIndex;
			}
		}
		if (resolutionMode == Core.ResolutionModeNone) {
			resolutionMode = host.GetDefaultResolutionModeForFile(importingSourceFile);
		}
		return getModuleSpecifierEndingPreference(prefs.ImportModuleSpecifierEnding, resolutionMode, compilerOptions, importingSourceFile);
	}

	public static function GetAllowedEndingsInPreferredOrder(prefs:UserPreferences, host:ModuleSpecifierGenerationHost, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, oldImportSpecifier:String,
			syntaxImpliedNodeFormat:ResolutionMode):Array<ModuleSpecifierEnding> {
		var preferredEnding = getPreferredEnding(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier, Core.ResolutionModeNone);
		final resolutionMode = host.GetDefaultResolutionModeForFile(importingSourceFile);
		if (resolutionMode != syntaxImpliedNodeFormat) {
			preferredEnding = getPreferredEnding(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier, syntaxImpliedNodeFormat);
		}
		final moduleResolution = compilerOptions.GetModuleResolutionKind();
		final moduleResolutionIsNodeNext = ModuleResolutionKindNode16 <= moduleResolution && moduleResolution <= ModuleResolutionKindNodeNext;
		final allowImportingTsExtension = shouldAllowImportingTsExtension(compilerOptions, importingSourceFile.FileName());
		if (syntaxImpliedNodeFormat == Core.ResolutionModeESM && moduleResolutionIsNodeNext) {
			if (allowImportingTsExtension) {
				return [ModuleSpecifierEndingTsExtension, ModuleSpecifierEndingJsExtension];
			}
			return [ModuleSpecifierEndingJsExtension];
		}
		switch (preferredEnding) {
			case ModuleSpecifierEndingJsExtension:
				if (allowImportingTsExtension) {
					return [
						ModuleSpecifierEndingJsExtension,
						ModuleSpecifierEndingTsExtension,
						ModuleSpecifierEndingMinimal,
						ModuleSpecifierEndingIndex
					];
				}
				return [ModuleSpecifierEndingJsExtension, ModuleSpecifierEndingMinimal, ModuleSpecifierEndingIndex];
			case ModuleSpecifierEndingTsExtension:
				return [
					ModuleSpecifierEndingTsExtension,
					ModuleSpecifierEndingMinimal,
					ModuleSpecifierEndingJsExtension,
					ModuleSpecifierEndingIndex
				];
			case ModuleSpecifierEndingIndex:
				if (allowImportingTsExtension) {
					return [
						ModuleSpecifierEndingIndex,
						ModuleSpecifierEndingMinimal,
						ModuleSpecifierEndingTsExtension,
						ModuleSpecifierEndingJsExtension
					];
				}
				return [ModuleSpecifierEndingIndex, ModuleSpecifierEndingMinimal, ModuleSpecifierEndingJsExtension];
			case ModuleSpecifierEndingMinimal:
				if (allowImportingTsExtension) {
					return [
						ModuleSpecifierEndingMinimal,
						ModuleSpecifierEndingIndex,
						ModuleSpecifierEndingTsExtension,
						ModuleSpecifierEndingJsExtension
					];
				}
				return [ModuleSpecifierEndingMinimal, ModuleSpecifierEndingIndex, ModuleSpecifierEndingJsExtension];
			default:
				Debug.AssertNever(preferredEnding);
		}
		return [ModuleSpecifierEndingMinimal];
	}

	static function getModuleSpecifierPreferences(prefs:UserPreferences, host:ModuleSpecifierGenerationHost, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, oldImportSpecifier:String):ModuleSpecifierPreferences {
		final excludes = prefs.AutoImportSpecifierExcludeRegexes;
		var relativePreference = RelativePreferenceShortest;
		if (oldImportSpecifier.length > 0) {
			if (Tspath.IsExternalModuleNameRelative(oldImportSpecifier)) {
				relativePreference = RelativePreferenceRelative;
			} else {
				relativePreference = RelativePreferenceNonRelative;
			}
		} else {
			switch (prefs.ImportModuleSpecifierPreference) {
				case ImportModuleSpecifierPreferenceRelative:
					relativePreference = RelativePreferenceRelative;
				case ImportModuleSpecifierPreferenceNonRelative:
					relativePreference = RelativePreferenceNonRelative;
				case ImportModuleSpecifierPreferenceProjectRelative:
					relativePreference = RelativePreferenceExternalNonRelative;
				// all others are shortest
				default:
			}
		}

		final getAllowedEndingsInPreferredOrder = function(syntaxImpliedNodeFormat:ResolutionMode):Array<ModuleSpecifierEnding> {
			return GetAllowedEndingsInPreferredOrder(prefs, host, compilerOptions, importingSourceFile, oldImportSpecifier, syntaxImpliedNodeFormat);
		};

		final result = new ModuleSpecifierPreferences();
		result.excludeRegexes = excludes;
		result.relativePreference = relativePreference;
		result.getAllowedEndingsInPreferredOrder = getAllowedEndingsInPreferredOrder;
		return result;
	}

	// --- specifiers.go ---

	public static function GetModuleSpecifiers(moduleSymbol:Symbol, checker:CheckerShape, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, host:ModuleSpecifierGenerationHost, userPreferences:UserPreferences,
			options:ModuleSpecifierOptions, forAutoImports:Bool):Array<String> {
		final result = GetModuleSpecifiersWithInfo(moduleSymbol, checker, compilerOptions, importingSourceFile, host, userPreferences, options,
			forAutoImports);
		return result.a;
	}

	// PORT: ([]string, ResultKind) → Pair.
	public static function GetModuleSpecifiersWithInfo(moduleSymbol:Symbol, checker:CheckerShape, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, host:ModuleSpecifierGenerationHost, userPreferences:UserPreferences,
			options:ModuleSpecifierOptions, forAutoImports:Bool):Pair<Array<String>, ResultKind> {
		final ambient = tryGetModuleNameFromAmbientModule(moduleSymbol, checker);
		if (ambient.length > 0) {
			if (forAutoImports && IsExcludedByRegex(ambient, userPreferences.AutoImportSpecifierExcludeRegexes)) {
				return new Pair<Array<String>, ResultKind>(null, ResultKindAmbient);
			}
			return new Pair<Array<String>, ResultKind>([ambient], ResultKindAmbient);
		}

		final moduleSourceFile = Ast.GetSourceFileOfModule(moduleSymbol);
		if (moduleSourceFile == null) {
			return new Pair<Array<String>, ResultKind>(null, ResultKindNone);
		}

		// Use original source file name when file is from project reference output
		final moduleFileName = host.GetSourceOfProjectReferenceIfOutputIncluded(SourceFileAdapter.Of(moduleSourceFile));

		return GetModuleSpecifiersForFileWithInfo(importingSourceFile, moduleFileName, compilerOptions, host, userPreferences, options, forAutoImports);
	}

	public static function GetModuleSpecifiersForFileWithInfo(importingSourceFile:SourceFileForSpecifierGeneration, moduleFileName:String,
			compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost, userPreferences:UserPreferences, options:ModuleSpecifierOptions,
			forAutoImports:Bool):Pair<Array<String>, ResultKind> {
		final modulePaths = getAllModulePathsWorker(getInfo(host.GetSourceOfProjectReferenceIfOutputIncluded(importingSourceFile), host), moduleFileName,
			host, compilerOptions, options);

		return computeModuleSpecifiers(modulePaths, compilerOptions, importingSourceFile, host, userPreferences, options, forAutoImports);
	}

	static function tryGetModuleNameFromAmbientModule(moduleSymbol:Symbol, checker:CheckerShape):String {
		if (moduleSymbol.Declarations != null) {
			for (decl in moduleSymbol.Declarations) {
				if (Ast.IsModuleWithStringLiteralName(decl)
					&& (!Ast.IsModuleAugmentationExternal(decl) || !Tspath.IsExternalModuleNameRelative(decl.Name().Text()))) {
					return decl.Name().Text();
				}
			}
		}

		// the module could be a namespace, which is export through "export=" from an ambient module.
		/**
		 * declare module "m" {
		 *     namespace ns {
		 *         class c {}
		 *     }
		 *     export = ns;
		 * }
		 */
		// `import {c} from "m";` is valid, in which case, `moduleSymbol` is "ns", but the module name should be "m"
		if (moduleSymbol.Declarations != null) {
			for (d in moduleSymbol.Declarations) {
				if (!Ast.IsModuleDeclaration(d)) {
					continue;
				}

				final possibleContainer = Ast.FindAncestor(d, Ast.IsModuleWithStringLiteralName);
				if (possibleContainer == null || possibleContainer.Parent == null || !Ast.IsSourceFile(possibleContainer.Parent)) {
					continue;
				}

				final exports = possibleContainer.Symbol().Exports;
				final sym = exports == null ? null : exports.get(Ast.InternalSymbolNameExportEquals);
				if (sym == null) {
					continue;
				}
				final exportAssignmentDecl = sym.ValueDeclaration;
				if (exportAssignmentDecl == null || exportAssignmentDecl.Kind != Kind.KindExportAssignment) {
					continue;
				}
				var exportSymbol = checker.GetSymbolAtLocation(exportAssignmentDecl.Expression());
				if (exportSymbol == null) {
					continue;
				}
				if ((exportSymbol.Flags & SymbolFlagsAlias) != 0) {
					exportSymbol = checker.GetAliasedSymbol(exportSymbol);
				}
				// TODO: Possible strada bug - isn't this insufficient in the presence of merge symbols?
				if (exportSymbol == d.Symbol()) {
					return possibleContainer.Name().Text();
				}
			}
		}
		return "";
	}

	static function getInfo(importingSourceFileName:String, host:ModuleSpecifierGenerationHost):Info {
		final sourceDirectory = Tspath.GetDirectoryPath(importingSourceFileName);
		return new Info(host.UseCaseSensitiveFileNames(), importingSourceFileName, sourceDirectory);
	}

	static function getAllModulePaths(info:Info, importedFileName:String, host:ModuleSpecifierGenerationHost, compilerOptions:CompilerOptions,
			preferences:UserPreferences, options:ModuleSpecifierOptions):Array<ModulePath> {
		// !!! use new cache model
		// importingFilePath := tspath.ToPath(info.ImportingSourceFileName, host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
		// importedFilePath := tspath.ToPath(importedFileName, host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
		// cache := host.getModuleSpecifierCache();
		// if (cache != nil) {
		//     cached := cache.get(importingFilePath, importedFilePath, preferences, options);
		//     if (cached.modulePaths) {return cached.modulePaths;}
		// }
		final modulePaths = getAllModulePathsWorker(info, importedFileName, host, compilerOptions, options);
		// if (cache != nil) {
		//     cache.setModulePaths(importingFilePath, importedFilePath, preferences, options, modulePaths);
		// }
		return modulePaths;
	}

	static function getAllModulePathsWorker(info:Info, importedFileName:String, host:ModuleSpecifierGenerationHost, compilerOptions:CompilerOptions,
			options:ModuleSpecifierOptions):Array<ModulePath> {
		// PORT: Go map (random iteration order) → StringMap + key list; each group is sorted below,
		// so the result does not depend on the iteration order (as in Go).
		final allFileNames = new StringMap<ModulePath>();
		final allFileNameKeys:Array<String> = [];
		final paths = GetEachFileNameOfModule(info.ImportingSourceFileName, importedFileName, host, true);
		for (p in paths) {
			if (!allFileNames.exists(p.FileName))
				allFileNameKeys.push(p.FileName);
			allFileNames.set(p.FileName, p);
		}

		final useCaseSensitiveFileNames = info.UseCaseSensitiveFileNames;
		final comparePaths = function(a:ModulePath, b:ModulePath):Int {
			return comparePathsByRedirect(a, b, useCaseSensitiveFileNames);
		};

		// Sort by paths closest to importing file Name directory
		final sortedPaths:Array<ModulePath> = [];
		var directory = info.SourceDirectory;
		while (allFileNameKeys.length != 0) {
			final directoryStart = Tspath.EnsureTrailingDirectorySeparator(directory);
			var pathsInDirectory:Array<ModulePath> = null;
			var i = 0;
			while (i < allFileNameKeys.length) {
				final fileName = allFileNameKeys[i];
				if (StringTools.startsWith(fileName, directoryStart)) {
					if (pathsInDirectory == null)
						pathsInDirectory = [];
					pathsInDirectory.push(allFileNames.get(fileName));
					allFileNames.remove(fileName);
					allFileNameKeys.splice(i, 1);
				} else {
					i++;
				}
			}
			if (Core.len(pathsInDirectory) > 0) {
				Slices.SortFunc(pathsInDirectory, comparePaths);
				for (p in pathsInDirectory)
					sortedPaths.push(p);
			}
			final newDirectory = Tspath.GetDirectoryPath(directory);
			if (newDirectory == directory) {
				break;
			}
			directory = newDirectory;
		}
		if (allFileNameKeys.length > 0) {
			final remainingPaths = [for (k in allFileNameKeys) allFileNames.get(k)];
			Slices.SortFunc(remainingPaths, comparePaths);
			for (p in remainingPaths)
				sortedPaths.push(p);
		}
		return sortedPaths;
	}

	// containsIgnoredPath checks if a path contains patterns that should be ignored.
	// This is a local helper that duplicates tspath.ContainsIgnoredPath for performance.
	static function containsIgnoredPath(s:String):Bool {
		return s.indexOf("/node_modules/.") >= 0 || s.indexOf("/.git") >= 0 || s.indexOf(".#") >= 0;
	}

	// ContainsNodeModules checks if a path contains the node_modules directory.
	public static function ContainsNodeModules(s:String):Bool {
		return s.indexOf("/node_modules/") >= 0;
	}

	// GetEachFileNameOfModule returns all possible file paths for a module, including symlink alternatives.
	// This function handles symlink resolution and provides multiple path options for module resolution.
	public static function GetEachFileNameOfModule(importingFileName:String, importedFileName:String, host:ModuleSpecifierGenerationHost,
			preferSymlinks:Bool):Array<ModulePath> {
		final cwd = host.GetCurrentDirectory();
		final importedPath = Tspath.ToPath(importedFileName, cwd, host.UseCaseSensitiveFileNames());
		var referenceRedirect = "";
		final outputAndReference = host.GetProjectReferenceFromSource(importedPath);
		if (outputAndReference != null && outputAndReference.OutputDts != "") {
			referenceRedirect = outputAndReference.OutputDts;
		}

		final redirects = host.GetRedirectTargets(importedPath);
		final importedFileNames:Array<String> = [];
		if (referenceRedirect.length > 0) {
			importedFileNames.push(referenceRedirect);
		}
		importedFileNames.push(importedFileName);
		if (redirects != null) {
			for (r in redirects)
				importedFileNames.push(r);
		}
		final targets = Core.Map(importedFileNames, function(f:String):String return Tspath.GetNormalizedAbsolutePath(f, cwd));
		var shouldFilterIgnoredPaths = !Core.Every(targets, containsIgnoredPath);

		final results:Array<ModulePath> = [];
		if (!preferSymlinks) {
			for (p in targets) {
				if (!(shouldFilterIgnoredPaths && containsIgnoredPath(p))) {
					results.push(new ModulePath(p, ContainsNodeModules(p), referenceRedirect == p));
				}
			}
		}

		final symlinkCache = host.GetSymlinkCache();
		final fullImportedFileName = Tspath.GetNormalizedAbsolutePath(importedFileName, cwd);
		if (symlinkCache != null) {
			Tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(host.GetGlobalTypingsCacheLocation(), Tspath.GetDirectoryPath(fullImportedFileName),
				function(realPathDirectory:String):ValueOk<Bool> {
					final loaded = symlinkCache.DirectoriesByRealpath()
						.Load(Tspath.ToPath(realPathDirectory, cwd, host.UseCaseSensitiveFileNames()).EnsureTrailingDirectorySeparator());
					if (!loaded.ok) {
						return new ValueOk<Bool>(false, false);
					} // Continue to ancestor directory
					final symlinkSet = loaded.value;

					// Don't want to a package to globally import from itself (importNameCodeFix_symlink_own_package.ts)
					if (Tspath.StartsWithDirectory(importingFileName, realPathDirectory, host.UseCaseSensitiveFileNames())) {
						return new ValueOk<Bool>(false, true); // Stop search, each ancestor directory will also hit this condition
					}

					for (target in targets) {
						if (!Tspath.StartsWithDirectory(target, realPathDirectory, host.UseCaseSensitiveFileNames())) {
							continue;
						}

						final relative = Tspath.GetRelativePathFromDirectory(realPathDirectory, target,
							new ComparePathsOptions(host.UseCaseSensitiveFileNames(), cwd));
						symlinkSet.Range(function(symlinkDirectory:String):Bool {
							final option = Tspath.ResolvePath(symlinkDirectory, relative);
							results.push(new ModulePath(option, ContainsNodeModules(option), target == referenceRedirect));
							shouldFilterIgnoredPaths = true; // We found a non-ignored path in symlinks, so we can reject ignored-path realpaths
							return true;
						});
					}

					return new ValueOk<Bool>(false, false);
				});
		}

		if (preferSymlinks) {
			for (p in targets) {
				if (!(shouldFilterIgnoredPaths && containsIgnoredPath(p))) {
					results.push(new ModulePath(p, ContainsNodeModules(p), referenceRedirect == p));
				}
			}
		}

		return results;
	}

	static function computeModuleSpecifiers(modulePaths:Array<ModulePath>, compilerOptions:CompilerOptions,
			importingSourceFile:SourceFileForSpecifierGeneration, host:ModuleSpecifierGenerationHost, userPreferences:UserPreferences,
			options:ModuleSpecifierOptions, forAutoImport:Bool):Pair<Array<String>, ResultKind> {
		final info = getInfo(importingSourceFile.FileName(), host);
		final preferences = getModuleSpecifierPreferences(userPreferences, host, compilerOptions, importingSourceFile, "");

		var existingSpecifier = "";
		for (modulePath in modulePaths) {
			final targetPath = Tspath.ToPath(modulePath.FileName, host.GetCurrentDirectory(), info.UseCaseSensitiveFileNames);
			var existingImport:StringLiteralLike = null;
			final imports = importingSourceFile.Imports();
			if (imports != null) {
				for (importSpecifier in imports) {
					final resolvedModule = host.GetResolvedModuleFromModuleSpecifier(importingSourceFile, importSpecifier);
					if (resolvedModule.IsResolved()
						&& Tspath.ToPath(resolvedModule.ResolvedFileName, host.GetCurrentDirectory(), info.UseCaseSensitiveFileNames) == targetPath) {
						existingImport = importSpecifier;
						break;
					}
				}
			}
			if (existingImport != null) {
				if (preferences.relativePreference == RelativePreferenceNonRelative && Tspath.PathIsRelative(existingImport.Text())) {
					// If the preference is for non-relative and the module specifier is relative, ignore it
					continue;
				}
				final existingMode = host.GetModeForUsageLocation(importingSourceFile, existingImport);
				var targetMode = options.OverrideImportMode;
				if (targetMode == Core.ResolutionModeNone) {
					targetMode = host.GetDefaultResolutionModeForFile(importingSourceFile);
				}
				if (existingMode != targetMode && existingMode != Core.ResolutionModeNone && targetMode != Core.ResolutionModeNone) {
					// If the candidate import mode doesn't match the mode we're generating for, don't consider it
					continue;
				}
				existingSpecifier = existingImport.Text();
				break;
			}
		}

		if (existingSpecifier != "") {
			return new Pair<Array<String>, ResultKind>([existingSpecifier], ResultKindNone);
		}

		final importedFileIsInNodeModules = Core.Some(modulePaths, function(p:ModulePath):Bool return p.IsInNodeModules);

		// Module specifier priority:
		//   1. "Bare package specifiers" (e.g. "@foo/bar") resulting from a path through node_modules to a package.json's "types" entry
		//   2. Specifiers generated using "paths" from tsconfig
		//   3. Non-relative specfiers resulting from a path through node_modules (e.g. "@foo/bar/path/to/file")
		//   4. Relative paths
		var pathsSpecifiers:Array<String> = null;
		var redirectPathsSpecifiers:Array<String> = null;
		var nodeModulesSpecifiers:Array<String> = null;
		var relativeSpecifiers:Array<String> = null;

		for (modulePath in modulePaths) {
			var specifier = "";
			if (modulePath.IsInNodeModules) {
				specifier = tryGetModuleNameAsNodeModule(modulePath, info, importingSourceFile, host, compilerOptions, userPreferences /*packageNameOnly*/,
					false, options.OverrideImportMode);
			}
			if (specifier.length > 0 && !(forAutoImport && IsExcludedByRegex(specifier, preferences.excludeRegexes))) {
				if (nodeModulesSpecifiers == null)
					nodeModulesSpecifiers = [];
				nodeModulesSpecifiers.push(specifier);
				if (modulePath.IsRedirect) {
					// If we got a specifier for a redirect, it was a bare package specifier (e.g. "@foo/bar",
					// not "@foo/bar/path/to/file"). No other specifier will be this good, so stop looking.
					return new Pair<Array<String>, ResultKind>(nodeModulesSpecifiers, ResultKindNodeModules);
				}
			}

			var importMode = options.OverrideImportMode;
			if (importMode == Core.ResolutionModeNone) {
				importMode = host.GetDefaultResolutionModeForFile(importingSourceFile);
			}
			final local = getLocalModuleSpecifier(modulePath.FileName, info, compilerOptions, host, importMode, preferences,
				/*pathsOnly*/ modulePath.IsRedirect || specifier.length > 0);
			if (local.length == 0 || forAutoImport && IsExcludedByRegex(local, preferences.excludeRegexes)) {
				continue;
			}
			if (modulePath.IsRedirect) {
				if (redirectPathsSpecifiers == null)
					redirectPathsSpecifiers = [];
				redirectPathsSpecifiers.push(local);
			} else if (PathIsBareSpecifier(local)) {
				if (ContainsNodeModules(local)) {
					// We could be in this branch due to inappropriate use of `baseUrl`, not intentional `paths`
					// usage. It's impossible to reason about where to prioritize baseUrl-generated module
					// specifiers, but if they contain `/node_modules/`, they're going to trigger a portability
					// error, so *at least* don't prioritize those.
					if (relativeSpecifiers == null)
						relativeSpecifiers = [];
					relativeSpecifiers.push(local);
				} else {
					if (pathsSpecifiers == null)
						pathsSpecifiers = [];
					pathsSpecifiers.push(local);
				}
			} else if (forAutoImport || !importedFileIsInNodeModules || modulePath.IsInNodeModules) {
				// Why this extra conditional, not just an `else`? If some path to the file contained
				// 'node_modules', but we can't create a non-relative specifier (e.g. "@foo/bar/path/to/file"),
				// that means we had to go through a *sibling's* node_modules, not one we can access directly.
				// If some path to the file was in node_modules but another was not, this likely indicates that
				// we have a monorepo structure with symlinks. In this case, the non-nodeModules path is
				// probably the realpath, e.g. "../bar/path/to/file", but a relative path to another package
				// in a monorepo is probably not portable. So, the module specifier we actually go with will be
				// the relative path through node_modules, so that the declaration emitter can produce a
				// portability error. (See declarationEmitReexportedSymlinkReference3)
				if (relativeSpecifiers == null)
					relativeSpecifiers = [];
				relativeSpecifiers.push(local);
			}
		}

		if (Core.len(pathsSpecifiers) > 0) {
			return new Pair<Array<String>, ResultKind>(pathsSpecifiers, ResultKindPaths);
		}
		if (Core.len(redirectPathsSpecifiers) > 0) {
			return new Pair<Array<String>, ResultKind>(redirectPathsSpecifiers, ResultKindRedirect);
		}
		if (Core.len(nodeModulesSpecifiers) > 0) {
			return new Pair<Array<String>, ResultKind>(nodeModulesSpecifiers, ResultKindNodeModules);
		}
		return new Pair<Array<String>, ResultKind>(relativeSpecifiers, ResultKindRelative);
	}

	static function getLocalModuleSpecifier(moduleFileName:String, info:Info, compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost,
			importMode:ResolutionMode, preferences:ModuleSpecifierPreferences, pathsOnly:Bool):String {
		final paths = compilerOptions.Paths;
		final rootDirs = compilerOptions.RootDirs;

		if (pathsOnly && paths == null) {
			return "";
		}

		final sourceDirectory = info.SourceDirectory;

		final allowedEndings = preferences.getAllowedEndingsInPreferredOrder(importMode);
		var relativePath = "";
		if (Core.len(rootDirs) > 0) {
			relativePath = tryGetModuleNameFromRootDirs(rootDirs, moduleFileName, sourceDirectory, allowedEndings, compilerOptions, host);
		}
		if (relativePath.length == 0) {
			relativePath = processEnding(ensurePathIsNonModuleName(Tspath.GetRelativePathFromDirectory(sourceDirectory, moduleFileName,
				new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory()))),
				allowedEndings, compilerOptions, host);
		}

		if ((paths == null && !compilerOptions.GetResolvePackageJsonImports()) || preferences.relativePreference == RelativePreferenceRelative) {
			if (pathsOnly) {
				return "";
			}
			return relativePath;
		}

		final root = compilerOptions.GetPathsBasePath(host.GetCurrentDirectory());
		final baseDirectory = Tspath.GetNormalizedAbsolutePath(root, host.GetCurrentDirectory());
		final relativeToBaseUrl = getRelativePathIfInSameVolume(moduleFileName, baseDirectory, host.UseCaseSensitiveFileNames());
		if (relativeToBaseUrl.length == 0) {
			if (pathsOnly) {
				return "";
			}
			return relativePath;
		}

		var fromPackageJsonImports = "";
		if (!pathsOnly) {
			fromPackageJsonImports = tryGetModuleNameFromPackageJsonImports(moduleFileName, sourceDirectory, compilerOptions, host, importMode,
				prefersTsExtension(allowedEndings));
		}

		var fromPaths = "";
		if ((pathsOnly || fromPackageJsonImports.length == 0) && paths != null) {
			fromPaths = tryGetModuleNameFromPaths(relativeToBaseUrl, paths, allowedEndings, baseDirectory, host, compilerOptions);
		}

		if (pathsOnly) {
			return fromPaths;
		}

		var maybeNonRelative:String;
		if (fromPackageJsonImports.length > 0) {
			maybeNonRelative = fromPackageJsonImports;
		} else {
			maybeNonRelative = fromPaths;
		}
		if (maybeNonRelative.length == 0) {
			return relativePath;
		}

		final relativeIsExcluded = IsExcludedByRegex(relativePath, preferences.excludeRegexes);
		final nonRelativeIsExcluded = IsExcludedByRegex(maybeNonRelative, preferences.excludeRegexes);
		if (!relativeIsExcluded && nonRelativeIsExcluded) {
			return relativePath;
		}
		if (relativeIsExcluded && !nonRelativeIsExcluded) {
			return maybeNonRelative;
		}

		if (preferences.relativePreference == RelativePreferenceNonRelative && !Tspath.PathIsRelative(maybeNonRelative)) {
			return maybeNonRelative;
		}

		if (preferences.relativePreference == RelativePreferenceExternalNonRelative && !Tspath.PathIsRelative(maybeNonRelative)) {
			var projectDirectory:Path;
			if (compilerOptions.ConfigFilePath.length > 0) {
				projectDirectory = Tspath.ToPath(Tspath.GetDirectoryPath(compilerOptions.ConfigFilePath), host.GetCurrentDirectory(),
					host.UseCaseSensitiveFileNames());
			} else {
				projectDirectory = Tspath.ToPath(host.GetCurrentDirectory(), host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
			}
			final canonicalSourceDirectory = Tspath.ToPath(sourceDirectory, host.GetCurrentDirectory(), host.UseCaseSensitiveFileNames());
			final modulePath = Tspath.ToPath(moduleFileName, (projectDirectory : String), host.UseCaseSensitiveFileNames());

			final sourceIsInternal = projectDirectory.ContainsPath(canonicalSourceDirectory);
			final targetIsInternal = projectDirectory.ContainsPath(modulePath);
			if (sourceIsInternal && !targetIsInternal || !sourceIsInternal && targetIsInternal) {
				// 1. The import path crosses the boundary of the tsconfig.json-containing directory.
				//
				//      src/
				//        tsconfig.json
				//        index.ts -------
				//      lib/              | (path crosses tsconfig.json)
				//        imported.ts <---
				//
				return maybeNonRelative;
			}

			final nearestTargetPackageJson = host.GetNearestAncestorDirectoryWithPackageJson(Tspath.GetDirectoryPath((modulePath : String)));
			final nearestSourcePackageJson = host.GetNearestAncestorDirectoryWithPackageJson(sourceDirectory);

			if (!packageJsonPathsAreEqual(nearestTargetPackageJson, nearestSourcePackageJson,
				new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory()))) {
				// 2. The importing and imported files are part of different packages.
				//
				//      packages/a/
				//        package.json
				//        index.ts --------
				//      packages/b/        | (path crosses package.json)
				//        package.json     |
				//        component.ts <---
				//
				return maybeNonRelative;
			}

			return relativePath;
		}

		// Prefer a relative import over a baseUrl import if it has fewer components.
		if (isPathRelativeToParent(maybeNonRelative) || CountPathComponents(relativePath) < CountPathComponents(maybeNonRelative)) {
			return relativePath;
		}
		return maybeNonRelative;
	}

	static function processEnding(fileName:String, allowedEndings:Array<ModuleSpecifierEnding>, options:CompilerOptions,
			host:ModuleSpecifierGenerationHost):String {
		if (Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionJson, Tspath.ExtensionMjs, Tspath.ExtensionCjs])) {
			return fileName;
		}

		final noExtension = Tspath.RemoveFileExtension(fileName);
		if (fileName == noExtension) {
			return fileName;
		}

		final jsPriority = Slices.Index(allowedEndings, ModuleSpecifierEndingJsExtension);
		final tsPriority = Slices.Index(allowedEndings, ModuleSpecifierEndingTsExtension);
		if (Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionMts, Tspath.ExtensionCts]) && tsPriority != -1 && tsPriority < jsPriority) {
			return fileName;
		}
		if (Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionDmts, Tspath.ExtensionDcts])) {
			final inputExt = Tspath.GetDeclarationFileExtension(fileName);
			final ext = GetJSExtensionForDeclarationFileExtension(inputExt);
			return Tspath.RemoveExtension(fileName, inputExt) + ext;
		}
		if (Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionMts, Tspath.ExtensionCts])) {
			return noExtension + getJSExtensionForFile(fileName, options);
		}
		if (!Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionDts])
			&& Tspath.FileExtensionIsOneOf(fileName, [Tspath.ExtensionTs])
			&& fileName.indexOf(".d.") >= 0) {
			// `foo.d.json.ts` and the like - remap back to `foo.json`
			final result = TryGetRealFileNameForNonJSDeclarationFileName(fileName);
			if (result != "") {
				return result;
			}
		}

		switch (allowedEndings[0]) {
			case ModuleSpecifierEndingMinimal:
				final withoutIndex = trimSuffix(noExtension, "/index");
				if (host != null && withoutIndex != noExtension && tryGetAnyFileFromPath(host, withoutIndex)) {
					// Can't remove index if there's a file by the same name as the directory.
					// Probably more callers should pass `host` so we can determine this?
					return noExtension;
				}
				return withoutIndex;
			case ModuleSpecifierEndingIndex:
				return noExtension;
			case ModuleSpecifierEndingJsExtension:
				return noExtension + getJSExtensionForFile(fileName, options);
			case ModuleSpecifierEndingTsExtension:
				// For now, we don't know if this import is going to be type-only, which means we don't
				// know if a .d.ts extension is valid, so use no extension or a .js extension
				if (Tspath.IsDeclarationFileName(fileName)) {
					var extensionlessPriority = -1;
					for (i in 0...allowedEndings.length) {
						final e = allowedEndings[i];
						if (e == ModuleSpecifierEndingMinimal || e == ModuleSpecifierEndingIndex) {
							extensionlessPriority = i;
							break;
						}
					}
					if (extensionlessPriority != -1 && extensionlessPriority < jsPriority) {
						return noExtension;
					}
					return noExtension + getJSExtensionForFile(fileName, options);
				}
				return fileName;
			default:
				Debug.AssertNever(allowedEndings[0]);
				return "";
		}
	}

	static function tryGetModuleNameFromRootDirs(rootDirs:Array<String>, moduleFileName:String, sourceDirectory:String,
			allowedEndings:Array<ModuleSpecifierEnding>, compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost):String {
		final normalizedTargetPaths = getPathsRelativeToRootDirs(moduleFileName, rootDirs, host.UseCaseSensitiveFileNames());
		if (Core.len(normalizedTargetPaths) == 0) {
			return "";
		}

		final normalizedSourcePaths = getPathsRelativeToRootDirs(sourceDirectory, rootDirs, host.UseCaseSensitiveFileNames());
		var shortest = "";
		var shortestSepCount = 0;
		if (normalizedSourcePaths != null) {
			for (sourcePath in normalizedSourcePaths) {
				for (targetPath in normalizedTargetPaths) {
					final candidate = ensurePathIsNonModuleName(Tspath.GetRelativePathFromDirectory(sourcePath, targetPath,
						new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory())));
					final candidateSepCount = Strings.Count(candidate, "/");
					if (shortest.length == 0 || candidateSepCount < shortestSepCount) {
						shortest = candidate;
						shortestSepCount = candidateSepCount;
					}
				}
			}
		}

		if (shortest.length == 0) {
			return "";
		}
		return processEnding(shortest, allowedEndings, compilerOptions, host);
	}

	static function tryGetModuleNameAsNodeModule(pathObj:ModulePath, info:Info, importingSourceFile:SourceFileForSpecifierGeneration,
			host:ModuleSpecifierGenerationHost, options:CompilerOptions, userPreferences:UserPreferences, packageNameOnly:Bool,
			overrideMode:ResolutionMode):String {
		final parts = GetNodeModulePathParts(pathObj.FileName);
		if (parts == null) {
			return "";
		}

		// Simplify the full file path to something that can be resolved by Node.
		final preferences = getModuleSpecifierPreferences(userPreferences, host, options, importingSourceFile, "");
		final allowedEndings = preferences.getAllowedEndingsInPreferredOrder(Core.ResolutionModeNone);

		final caseSensitive = host.UseCaseSensitiveFileNames();
		var moduleSpecifier = pathObj.FileName;
		var isPackageRootPath = false;
		if (!packageNameOnly) {
			var packageRootIndex = parts.PackageRootIndex;
			var moduleFileName = "";
			while (true) {
				// If the module could be imported by a directory name, use that directory's name
				final pkgJsonResults = tryDirectoryWithPackageJson(parts, pathObj, importingSourceFile, host, overrideMode, options, allowedEndings);
				final moduleFileToTry = pkgJsonResults.moduleFileToTry;
				final packageRootPath = pkgJsonResults.packageRootPath;
				final blockedByExports = pkgJsonResults.blockedByExports;
				final verbatimFromExports = pkgJsonResults.verbatimFromExports;
				if (blockedByExports) {
					return ""; // File is under this package.json, but is not publicly exported - there's no way to name it via `node_modules` resolution
				}
				if (verbatimFromExports) {
					return moduleFileToTry;
				}
				//}
				if (packageRootPath.length > 0) {
					moduleSpecifier = packageRootPath;
					isPackageRootPath = true;
					break;
				}
				if (moduleFileName.length == 0) {
					moduleFileName = moduleFileToTry;
				}
				// try with next level of directory
				packageRootIndex = Core.IndexAfter(pathObj.FileName, "/", packageRootIndex + 1);
				if (packageRootIndex == -1) {
					moduleSpecifier = processEnding(moduleFileName, allowedEndings, options, host);
					break;
				}
			}
		}

		if (pathObj.IsRedirect && !isPackageRootPath) {
			return "";
		}

		final globalTypingsCacheLocation = host.GetGlobalTypingsCacheLocation();
		// Get a path that's relative to node_modules or the importing file's path
		// if node_modules folder is in this folder or any of its parent folders, no need to keep it.
		final pathToTopLevelNodeModules = moduleSpecifier.substring(0, parts.TopLevelNodeModulesIndex);

		if (!Stringutil.HasPrefix(info.SourceDirectory, pathToTopLevelNodeModules, caseSensitive)
			|| globalTypingsCacheLocation.length > 0
			&& Stringutil.HasPrefix(globalTypingsCacheLocation, pathToTopLevelNodeModules, caseSensitive)) {
			return "";
		}

		// If the module was found in @types, get the actual Node package name
		final nodeModulesDirectoryName = moduleSpecifier.substring(parts.TopLevelPackageNameIndex + 1);
		return Module.GetPackageNameFromTypesPackageName(nodeModulesDirectoryName);
	}

	static function tryDirectoryWithPackageJson(parts:NodeModulePathParts, pathObj:ModulePath, importingSourceFile:SourceFileForSpecifierGeneration,
			host:ModuleSpecifierGenerationHost, overrideMode:ResolutionMode, options:CompilerOptions,
			allowedEndings:Array<ModuleSpecifierEnding>):PkgJsonDirAttemptResult {
		var rootIdx = parts.PackageRootIndex;
		if (rootIdx == -1) {
			rootIdx = pathObj.FileName.length; // TODO: possible strada bug? -1 in js slice removes characters from the end, in go it panics - js behavior seems unwanted here?
		}
		final packageRootPath = pathObj.FileName.substring(0, rootIdx);
		final packageJsonPath = Tspath.CombinePaths(packageRootPath, "package.json");
		var moduleFileToTry = pathObj.FileName;
		var maybeBlockedByTypesVersions = false;
		final packageJson = host.GetPackageJsonInfo(packageJsonPath);
		if (packageJson == null) {
			// No package.json exists; an index.js will still resolve as the package name
			final fileName = moduleFileToTry.substring(parts.PackageRootIndex + 1);
			if (fileName == "index.d.ts" || fileName == "index.js" || fileName == "index.ts" || fileName == "index.tsx") {
				return new PkgJsonDirAttemptResult(moduleFileToTry, packageRootPath);
			} else {
				return new PkgJsonDirAttemptResult(moduleFileToTry);
			}
		}

		var importMode = overrideMode;
		if (importMode == Core.ResolutionModeNone) {
			importMode = host.GetDefaultResolutionModeForFile(importingSourceFile);
		}

		final packageJsonContent = packageJson.GetContents();
		if (options.GetResolvePackageJsonExports()) {
			// The package name that we found in node_modules could be different from the package
			// name in the package.json content via url/filepath dependency specifiers. We need to
			// use the actual directory name, so don't look at `packageJsonContent.name` here.
			final nodeModulesDirectoryName = packageRootPath.substring(parts.TopLevelPackageNameIndex + 1);
			final packageName = Module.GetPackageNameFromTypesPackageName(nodeModulesDirectoryName);

			// Determine resolution mode for package.json exports condition matching.
			// TypeScript's tryDirectoryWithPackageJson uses the importing file's mode (moduleSpecifiers.ts:1257),
			// but this causes incorrect exports resolution. We fix this by checking the target file's extension
			// using the logic from getImpliedNodeFormatForEmitWorker (program.ts:4827-4838).
			// .cjs/.cts/.d.cts → CommonJS → "require" condition
			// .mjs/.mts/.d.mts → ESM → "import" condition
			if (Tspath.FileExtensionIsOneOf(pathObj.FileName, [Tspath.ExtensionCjs, Tspath.ExtensionCts, Tspath.ExtensionDcts])) {
				importMode = Core.ResolutionModeCommonJS;
			} else if (Tspath.FileExtensionIsOneOf(pathObj.FileName, [Tspath.ExtensionMjs, Tspath.ExtensionMts, Tspath.ExtensionDmts])) {
				importMode = Core.ResolutionModeESM;
			}

			final conditions = Module.GetConditions(options, importMode);

			var fromExports = "";
			if (packageJsonContent != null && packageJsonContent.Fields.Exports.Type != JSONValueTypeNotPresent) {
				fromExports = tryGetModuleNameFromExports(options, host, pathObj.FileName, packageRootPath, packageName, packageJsonContent.Fields.Exports,
					conditions);
			}
			if (fromExports.length > 0) {
				return new PkgJsonDirAttemptResult(fromExports, "", false, true);
			}
			if (packageJsonContent != null && packageJsonContent.Fields.Exports.Type != JSONValueTypeNotPresent) {
				return new PkgJsonDirAttemptResult(pathObj.FileName, "", true);
			}
		}

		var versionPaths = new VersionPaths();
		if (packageJsonContent != null && packageJsonContent.TypesVersions.Type == JSONValueTypeObject) {
			versionPaths = packageJsonContent.GetVersionPaths(null);
		}
		if (versionPaths.GetPaths() != null) {
			final subModuleName = pathObj.FileName.substring(packageRootPath.length + 1);
			final fromPaths = tryGetModuleNameFromPaths(subModuleName, versionPaths.GetPaths(), allowedEndings, packageRootPath, host, options);
			if (fromPaths.length == 0) {
				maybeBlockedByTypesVersions = true;
			} else {
				moduleFileToTry = Tspath.CombinePaths(packageRootPath, fromPaths);
			}
		}
		// If the file is the main module, it can be imported by the package name
		var mainFileRelative = "index.js";
		if (packageJsonContent != null) {
			if (packageJsonContent.Typings.Valid) {
				mainFileRelative = packageJsonContent.Typings.Value;
			} else if (packageJsonContent.Types.Valid) {
				mainFileRelative = packageJsonContent.Types.Value;
			} else if (packageJsonContent.Main.Valid) {
				mainFileRelative = packageJsonContent.Main.Value;
			}
		}

		if (mainFileRelative.length > 0
			&& !(maybeBlockedByTypesVersions
				&& !Module.MatchPatternOrExact(Module.TryParsePatterns(versionPaths.GetPaths()), mainFileRelative).Equals(new Pattern()))) {
			// The 'main' file is also subject to mapping through typesVersions, and we couldn't come up with a path
			// explicitly through typesVersions, so if it matches a key in typesVersions now, it's not reachable.
			// (The only way this can happen is if some file in a package that's not resolvable from outside the
			// package got pulled into the program anyway, e.g. transitively through a file that *is* reachable. It
			// happens very easily in fourslash tests though, since every test file listed gets included. See
			// importNameCodeFix_typesVersions.ts for an example.)
			final mainExportFile = Tspath.ToPath(mainFileRelative, packageRootPath, host.UseCaseSensitiveFileNames());
			final compareOpt = new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory());
			if (Tspath.ComparePaths(Tspath.RemoveFileExtension((mainExportFile : String)), Tspath.RemoveFileExtension(moduleFileToTry), compareOpt) == 0) {
				// ^ An arbitrary removal of file extension for this comparison is almost certainly wrong
				return new PkgJsonDirAttemptResult(moduleFileToTry, packageRootPath);
			} else if (packageJsonContent == null
				|| packageJsonContent.Type.Value != "module"
				&& !Tspath.FileExtensionIsOneOf(moduleFileToTry, Tspath.ExtensionsNotSupportingExtensionlessResolution)
				&& Stringutil.HasPrefix(moduleFileToTry, (mainExportFile : String), host.UseCaseSensitiveFileNames())
				&& Tspath.ComparePaths(Tspath.GetDirectoryPath(moduleFileToTry), Tspath.RemoveTrailingDirectorySeparator((mainExportFile : String)),
					compareOpt) == 0
				&& Tspath.RemoveFileExtension(Tspath.GetBaseFileName(moduleFileToTry)) == "index") {
				// if mainExportFile is a directory, which contains moduleFileToTry, we just try index file
				// example mainExportFile: `pkg/lib` and moduleFileToTry: `pkg/lib/index`, we can use packageRootPath
				// but this behavior is deprecated for packages with "type": "module", so we only do this for packages without "type": "module"
				// and make sure that the extension on index.{???} is something that supports omitting the extension
				return new PkgJsonDirAttemptResult(moduleFileToTry, packageRootPath);
			}
		}

		return new PkgJsonDirAttemptResult(moduleFileToTry);
	}

	static function tryGetModuleNameFromExports(options:CompilerOptions, host:ModuleSpecifierGenerationHost, targetFilePath:String,
			packageDirectory:String, packageName:String, exports:ExportsOrImports, conditions:Array<String>):String {
		if (exports.IsSubpaths()) {
			// sub-mappings
			// 3 cases:
			// * directory mappings (legacyish, key ends with / (technically allows index/extension resolution under cjs mode))
			// * pattern mappings (contains a *)
			// * exact mappings (no *, does not end with /)
			for (k => subk in exports.AsObject().Entries()) {
				final subPackageName = Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(packageName, k), "");
				var mode = MatchingModeExact;
				if (StringTools.endsWith(k, "/")) {
					mode = MatchingModeDirectory;
				} else if (k.indexOf("*") >= 0) {
					mode = MatchingModePattern;
				}
				final result = tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, subPackageName, subk, conditions,
					mode /*isImports*/, false /*preferTsExtension*/, false);
				if (result.length > 0) {
					return result;
				}
			}
		}
		return tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, exports, conditions,
			MatchingModeExact,
			/*isImports*/ false,
			/*preferTsExtension*/ false);
	}

	static function tryGetModuleNameFromPackageJsonImports(moduleFileName:String, sourceDirectory:String, options:CompilerOptions,
			host:ModuleSpecifierGenerationHost, importMode:ResolutionMode, preferTsExtension:Bool):String {
		if (!options.GetResolvePackageJsonImports()) {
			return "";
		}

		final ancestorDirectoryWithPackageJson = host.GetNearestAncestorDirectoryWithPackageJson(sourceDirectory);
		if (ancestorDirectoryWithPackageJson.length == 0) {
			return "";
		}
		final packageJsonPath = Tspath.CombinePaths(ancestorDirectoryWithPackageJson, "package.json");

		final info = host.GetPackageJsonInfo(packageJsonPath);
		if (info == null) {
			return "";
		}

		final imports = info.GetContents().Fields.Imports;
		switch (imports.Type) {
			case JSONValueTypeNotPresent, JSONValueTypeArray, JSONValueTypeString:
				return ""; // not present or invalid for imports
			case JSONValueTypeObject:
				final conditions = Module.GetConditions(options, importMode);
				final top = imports.AsObject();
				for (k => value in top.Entries()) {
					if (k == "#" || k == "#/" || !StringTools.startsWith(k, "#")) {
						continue; // invalid imports entry
					}
					if (StringTools.startsWith(k, "#/")
						&& options.GetModuleResolutionKind() != ModuleResolutionKindNodeNext
						&& options.GetModuleResolutionKind() != ModuleResolutionKindBundler) {
						continue; // "#/" imports keys are only valid in nodenext/bundler
					}
					var mode = MatchingModeExact;
					if (StringTools.endsWith(k, "/")) {
						mode = MatchingModeDirectory;
					} else if (k.indexOf("*") >= 0) {
						mode = MatchingModePattern;
					}
					final result = tryGetModuleNameFromExportsOrImports(options, host, moduleFileName, ancestorDirectoryWithPackageJson, k, value,
						conditions, mode, true, preferTsExtension);
					if (result.length > 0) {
						return result;
					}
				}
			default:
		}

		return "";
	}

	static function tryGetModuleNameFromPaths(relativeToBaseUrl:String, paths:OrderedMap<String, Array<String>>,
			allowedEndings:Array<ModuleSpecifierEnding>, baseDirectory:String, host:ModuleSpecifierGenerationHost,
			compilerOptions:CompilerOptions):String {
		final caseSensitive = host.UseCaseSensitiveFileNames();
		for (key => values in paths.Entries()) {
			if (values == null)
				continue;
			for (patternText in values) {
				final normalized = Tspath.NormalizePath(patternText);
				var pattern = getRelativePathIfInSameVolume(normalized, baseDirectory, caseSensitive);
				if (pattern.length == 0) {
					pattern = normalized;
				}
				// PORT: strings.Cut(pattern, "*").
				final starIndex = pattern.indexOf("*");
				final ok = starIndex >= 0;
				final prefix = ok ? pattern.substring(0, starIndex) : pattern;
				final suffix = ok ? pattern.substring(starIndex + 1) : "";

				// In module resolution, if `pattern` itself has an extension, a file with that extension is looked up directly,
				// meaning a '.ts' or '.d.ts' extension is allowed to resolve. This is distinct from the case where a '*' substitution
				// causes a module specifier to have an extension, i.e. the extension comes from the module specifier in a JS/TS file
				// and matches the '*'. For example:
				//
				// Module Specifier      | Path Mapping (key: [pattern]) | Interpolation       | Resolution Action
				// ---------------------->------------------------------->--------------------->---------------------------------------------------------------
				// import "@app/foo"    -> "@app/*": ["./src/app/*.ts"] -> "./src/app/foo.ts" -> tryFile("./src/app/foo.ts") || [continue resolution algorithm]
				// import "@app/foo.ts" -> "@app/*": ["./src/app/*"]    -> "./src/app/foo.ts" -> [continue resolution algorithm]
				//
				// (https://github.com/microsoft/TypeScript/blob/ad4ded80e1d58f0bf36ac16bea71bc10d9f09895/src/compiler/moduleNameResolver.ts#L2509-L2516)
				//
				// The interpolation produced by both scenarios is identical, but only in the former, where the extension is encoded in
				// the path mapping rather than in the module specifier, will we prioritize a file lookup on the interpolation result.
				// (In fact, currently, the latter scenario will necessarily fail since no resolution mode recognizes '.ts' as a valid
				// extension for a module specifier.)
				//
				// Here, this means we need to be careful about whether we generate a match from the target filename (typically with a
				// .ts extension) or the possible relative module specifiers representing that file:
				//
				// Filename            | Relative Module Specifier Candidates         | Path Mapping                 | Filename Result    | Module Specifier Results
				// --------------------<----------------------------------------------<------------------------------<-------------------||----------------------------
				// dist/haha.d.ts      <- dist/haha, dist/haha.js                     <- "@app/*": ["./dist/*.d.ts"] <- @app/haha        || (none)
				// dist/haha.d.ts      <- dist/haha, dist/haha.js                     <- "@app/*": ["./dist/*"]      <- (none)           || @app/haha, @app/haha.js
				// dist/foo/index.d.ts <- dist/foo, dist/foo/index, dist/foo/index.js <- "@app/*": ["./dist/*.d.ts"] <- @app/foo/index   || (none)
				// dist/foo/index.d.ts <- dist/foo, dist/foo/index, dist/foo/index.js <- "@app/*": ["./dist/*"]      <- (none)           || @app/foo, @app/foo/index, @app/foo/index.js
				// dist/wow.js.js      <- dist/wow.js, dist/wow.js.js                 <- "@app/*": ["./dist/*.js"]   <- @app/wow.js      || @app/wow, @app/wow.js
				//
				// The "Filename Result" can be generated only if `pattern` has an extension. Care must be taken that the list of
				// relative module specifiers to run the interpolation (a) is actually valid for the module resolution mode, (b) takes
				// into account the existence of other files (e.g. 'dist/wow.js' cannot refer to 'dist/wow.js.js' if 'dist/wow.js'
				// exists) and (c) that they are ordered by preference. The last row shows that the filename result and module
				// specifier results are not mutually exclusive. Note that the filename result is a higher priority in module
				// resolution, but as long criteria (b) above is met, I don't think its result needs to be the highest priority result
				// in module specifier generation. I have included it last, as it's difficult to tell exactly where it should be
				// sorted among the others for a particular value of `importModuleSpecifierEnding`.

				final candidates:Array<SpecPair> = [];
				if (allowedEndings != null) {
					for (ending in allowedEndings) {
						final result = processEnding(relativeToBaseUrl, [ending], compilerOptions, host);
						candidates.push(new SpecPair(ending, result));
					}
				}
				if (Tspath.TryGetExtensionFromPath(pattern).length > 0) {
					candidates.push(new SpecPair(ModuleSpecifierEndingJsExtension, relativeToBaseUrl));
				}

				if (ok) {
					for (c in candidates) {
						final value = c.value;
						if (value.length >= prefix.length + suffix.length
							&& Stringutil.HasPrefix(value, prefix, caseSensitive) // TODO: possible strada bug: these are not case-switched in strada
							&& Stringutil.HasSuffix(value, suffix, caseSensitive)
							&& validateEnding(c, relativeToBaseUrl, compilerOptions, host)) {
							final matchedStar = value.substring(prefix.length, value.length - suffix.length);
							if (!Tspath.PathIsRelative(matchedStar)) {
								return replaceFirstStar(key, matchedStar);
							}
						}
					}
				} else if (Core.Some(candidates, function(c:SpecPair):Bool return c.ending != ModuleSpecifierEndingMinimal && pattern == c.value)
					|| Core.Some(candidates, function(c:SpecPair):Bool {
						return c.ending == ModuleSpecifierEndingMinimal && pattern == c.value && validateEnding(c, relativeToBaseUrl, compilerOptions, host);
					})) {
					return key;
				}
			}
		}
		return "";
	}

	static function validateEnding(c:SpecPair, relativeToBaseUrl:String, compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost):Bool {
		// Optimization: `removeExtensionAndIndexPostFix` can query the file system (a good bit) if `ending` is `Minimal`, the basename
		// is 'index', and a `host` is provided. To avoid that until it's unavoidable, we ran the function with no `host` above. Only
		// here, after we've checked that the minimal ending is indeed a match (via the length and prefix/suffix checks / `some` calls),
		// do we check that the host-validated result is consistent with the answer we got before. If it's not, it falls back to the
		// `ModuleSpecifierEnding.Index` result, which should already be in the list of candidates if `Minimal` was. (Note: the assumption here is
		// that every module resolution mode that supports dropping extensions also supports dropping `/index`. Like literally
		// everything else in this file, this logic needs to be updated if that's not true in some future module resolution mode.)
		return c.ending != ModuleSpecifierEndingMinimal || c.value == processEnding(relativeToBaseUrl, [c.ending], compilerOptions, host);
	}

	static function tryGetModuleNameFromExportsOrImports(options:CompilerOptions, host:ModuleSpecifierGenerationHost, targetFilePath:String,
			packageDirectory:String, packageName:String, exports:ExportsOrImports, conditions:Array<String>, mode:MatchingMode, isImports:Bool,
			preferTsExtension:Bool):String {
		switch (exports.Type) {
			case JSONValueTypeNotPresent:
				return "";
			case JSONValueTypeString:
				final strValue:String = exports.Value;

				// possible strada bug? Always uses compilerOptions of the host project, not those applicable to the targeted package.json!
				var outputFile = "";
				var declarationFile = "";
				if (isImports) {
					outputFile = Outputpaths.GetOutputJSFileNameWorker(targetFilePath, options, host);
					declarationFile = Outputpaths.GetOutputDeclarationFileNameWorker(targetFilePath, options, host);
				}

				final pathOrPattern = Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(packageDirectory, strValue), "");
				var extensionSwappedTarget = "";
				if (Tspath.HasTSFileExtension(targetFilePath)) {
					extensionSwappedTarget = Tspath.RemoveFileExtension(targetFilePath) + Module.TryGetJSExtensionForFile(targetFilePath, options);
				}
				final canTryTsExtension = preferTsExtension && Tspath.HasImplementationTSFileExtension(targetFilePath);

				final compareOpts = new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory());

				switch (mode) {
					case MatchingModeExact:
						if (extensionSwappedTarget.length > 0 && Tspath.ComparePaths(extensionSwappedTarget, pathOrPattern, compareOpts) == 0
							|| Tspath.ComparePaths(targetFilePath, pathOrPattern, compareOpts) == 0
							|| outputFile.length > 0 && Tspath.ComparePaths(outputFile, pathOrPattern, compareOpts) == 0
							|| declarationFile.length > 0 && Tspath.ComparePaths(declarationFile, pathOrPattern, compareOpts) == 0) {
							return packageName;
						}
					case MatchingModeDirectory:
						if (canTryTsExtension && Tspath.ContainsPath(targetFilePath, pathOrPattern, compareOpts)) {
							final fragment = Tspath.GetRelativePathFromDirectory(pathOrPattern, targetFilePath, compareOpts);
							return Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(Tspath.CombinePaths(packageName, strValue), fragment), "");
						}
						if (extensionSwappedTarget.length > 0 && Tspath.ContainsPath(pathOrPattern, extensionSwappedTarget, compareOpts)) {
							final fragment = Tspath.GetRelativePathFromDirectory(pathOrPattern, extensionSwappedTarget, compareOpts);
							return Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(Tspath.CombinePaths(packageName, strValue), fragment), "");
						}
						if (!canTryTsExtension && Tspath.ContainsPath(pathOrPattern, targetFilePath, compareOpts)) {
							final fragment = Tspath.GetRelativePathFromDirectory(pathOrPattern, targetFilePath, compareOpts);
							return Tspath.GetNormalizedAbsolutePath(Tspath.CombinePaths(Tspath.CombinePaths(packageName, strValue), fragment), "");
						}
						if (outputFile.length > 0 && Tspath.ContainsPath(pathOrPattern, outputFile, compareOpts)) {
							final fragment = Tspath.GetRelativePathFromDirectory(pathOrPattern, outputFile, compareOpts);
							return Tspath.CombinePaths(packageName, fragment);
						}
						if (declarationFile.length > 0 && Tspath.ContainsPath(pathOrPattern, declarationFile, compareOpts)) {
							final fragment = Tspath.GetRelativePathFromDirectory(pathOrPattern, declarationFile, compareOpts);
							final jsExtension = getJSExtensionForFile(declarationFile, options);
							final fragmentWithJsExtension = Tspath.ChangeExtension(fragment, jsExtension);
							return Tspath.CombinePaths(packageName, fragmentWithJsExtension);
						}
					case MatchingModePattern:
						// PORT: strings.Cut(pathOrPattern, "*").
						final starIndex = pathOrPattern.indexOf("*");
						final leadingSlice = starIndex >= 0 ? pathOrPattern.substring(0, starIndex) : pathOrPattern;
						final trailingSlice = starIndex >= 0 ? pathOrPattern.substring(starIndex + 1) : "";
						final caseSensitive = host.UseCaseSensitiveFileNames();
						if (canTryTsExtension && Stringutil.HasPrefixAndSuffixWithoutOverlap(targetFilePath, leadingSlice, trailingSlice, caseSensitive)) {
							final starReplacement = targetFilePath.substring(leadingSlice.length, targetFilePath.length - trailingSlice.length);
							return replaceFirstStar(packageName, starReplacement);
						}
						if (extensionSwappedTarget.length > 0
							&& Stringutil.HasPrefixAndSuffixWithoutOverlap(extensionSwappedTarget, leadingSlice, trailingSlice, caseSensitive)) {
							final starReplacement = extensionSwappedTarget.substring(leadingSlice.length, extensionSwappedTarget.length - trailingSlice.length);
							return replaceFirstStar(packageName, starReplacement);
						}
						if (!canTryTsExtension && Stringutil.HasPrefixAndSuffixWithoutOverlap(targetFilePath, leadingSlice, trailingSlice, caseSensitive)) {
							final starReplacement = targetFilePath.substring(leadingSlice.length, targetFilePath.length - trailingSlice.length);
							return replaceFirstStar(packageName, starReplacement);
						}
						if (outputFile.length > 0 && Stringutil.HasPrefixAndSuffixWithoutOverlap(outputFile, leadingSlice, trailingSlice, caseSensitive)) {
							final starReplacement = outputFile.substring(leadingSlice.length, outputFile.length - trailingSlice.length);
							return replaceFirstStar(packageName, starReplacement);
						}
						if (declarationFile.length > 0
							&& Stringutil.HasPrefixAndSuffixWithoutOverlap(declarationFile, leadingSlice, trailingSlice, caseSensitive)) {
							final starReplacement = declarationFile.substring(leadingSlice.length, declarationFile.length - trailingSlice.length);
							final substituted = replaceFirstStar(packageName, starReplacement);
							final jsExtension = Module.TryGetJSExtensionForFile(declarationFile, options);
							if (jsExtension.length > 0) {
								return Tspath.ChangeFullExtension(substituted, jsExtension);
							}
						}
					default:
				}
				return "";
			case JSONValueTypeArray:
				final arr = exports.AsArray();
				for (e in arr) {
					final result = tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, e, conditions, mode,
						isImports, preferTsExtension);
					if (result.length > 0) {
						return result;
					}
				}
			case JSONValueTypeObject:
				// conditional mapping
				final obj = exports.AsObject();
				for (key => value in obj.Entries()) {
					if (key == "default"
						|| Slices.Contains(conditions, key)
						|| Slices.Contains(conditions, "types") && Module.IsApplicableVersionedTypesKey(key)) {
						final result = tryGetModuleNameFromExportsOrImports(options, host, targetFilePath, packageDirectory, packageName, value, conditions,
							mode, isImports, preferTsExtension);
						if (result.length > 0) {
							return result;
						}
					}
				}
			case JSONValueTypeNull:
				return "";
			default:
		}
		return "";
	}

	// `importingSourceFile` and `importingSourceFileName`? Why not just use `importingSourceFile.path`?
	// Because when this is called by the declaration emitter, `importingSourceFile` is the implementation
	// file, but `importingSourceFileName` and `toFileName` refer to declaration files (the former to the
	// one currently being produced; the latter to the one being imported). We need an implementation file
	// just to get its `impliedNodeFormat` and to detect certain preferences from existing import module
	// specifiers.
	public static function GetModuleSpecifier(compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost,
			importingSourceFile:SourceFile, // !!! | FutureSourceFile
			importingSourceFileName:String, oldImportSpecifier:String, // used only in updatingModuleSpecifier
			toFileName:String, options:ModuleSpecifierOptions):String {
		return getModuleSpecifierWithPreferences(compilerOptions, host, importingSourceFile, importingSourceFileName, oldImportSpecifier, toFileName,
			new UserPreferences(), options);
	}

	public static function UpdateModuleSpecifier(compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost, importingSourceFile:SourceFile,
			importingSourceFileName:String, oldImportSpecifier:String, toFileName:String, userPreferences:UserPreferences,
			options:ModuleSpecifierOptions):String {
		return getModuleSpecifierWithPreferences(compilerOptions, host, importingSourceFile, importingSourceFileName, oldImportSpecifier, toFileName,
			userPreferences, options);
	}

	static function getModuleSpecifierWithPreferences(compilerOptions:CompilerOptions, host:ModuleSpecifierGenerationHost,
			importingSourceFile:SourceFile, // !!! | FutureSourceFile
			importingSourceFileName:String, oldImportSpecifier:String, // used only in updatingModuleSpecifier
			toFileName:String, userPreferences:UserPreferences, options:ModuleSpecifierOptions):String {
		// PORT: *ast.SourceFile as SourceFileForSpecifierGeneration / ast.HasFileName → adapter.
		final importingFile = SourceFileAdapter.Of(importingSourceFile);
		final info = getInfo(importingSourceFileName, host);
		final modulePaths = getAllModulePaths(info, toFileName, host, compilerOptions, userPreferences, options);
		final preferences = getModuleSpecifierPreferences(userPreferences, host, compilerOptions, importingFile, oldImportSpecifier);

		var resolutionMode = options.OverrideImportMode;
		if (resolutionMode == Core.ResolutionModeNone) {
			resolutionMode = host.GetDefaultResolutionModeForFile(importingFile);
		}

		for (modulePath in modulePaths) {
			final firstDefined = tryGetModuleNameAsNodeModule(modulePath, info, importingFile, host, compilerOptions, userPreferences,
				false /*packageNameOnly*/, options.OverrideImportMode);
			if (firstDefined.length > 0) {
				return firstDefined;
			}
		}

		return getLocalModuleSpecifier(toFileName, info, compilerOptions, host, resolutionMode, preferences, false);
	}

	// --- util.go ---

	// PORT: map[regexPatternCacheKey]*regexp.Regexp → StringMap keyed by "<0|1>" + pattern (struct key
	// encoded as a String). The RWMutex is dropped (single-threaded port).
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — a cache per thread (go.Par.slot): an EReg keeps its last match
	static final regexPatternCaches:Array<StringMap<Null<EReg>>> = [for (_ in 0...go.Par.SLOTS) new StringMap()];
	static final regexPatternCacheSizes:Array<Int> = [for (_ in 0...go.Par.SLOTS) 0];
	static var regexPatternCache(get, never):StringMap<Null<EReg>>;
	static var regexPatternCacheSize(get, set):Int;

	static inline function get_regexPatternCache()
		return regexPatternCaches[go.Par.slot];

	static inline function get_regexPatternCacheSize()
		return regexPatternCacheSizes[go.Par.slot];

	static inline function set_regexPatternCacheSize(v:Int)
		return regexPatternCacheSizes[go.Par.slot] = v;
	#else
	static final regexPatternCache = new StringMap<Null<EReg>>();
	static var regexPatternCacheSize = 0;
	#end

	static function comparePathsByRedirect(a:ModulePath, b:ModulePath, useCaseSensitiveFileNames:Bool):Int {
		// Redirects sort first, matching Strada's compareBooleans(b.isRedirect, a.isRedirect).
		final c1 = Core.CompareBooleans(b.IsRedirect, a.IsRedirect);
		if (c1 != 0) {
			return c1;
		}
		final c2 = Tspath.CompareNumberOfDirectorySeparators(a.FileName, b.FileName);
		if (c2 != 0) {
			return c2;
		}
		// Strada relies on Map insertion order to break remaining ties deterministically;
		// Go maps are unordered, so compare paths to keep the ordering stable.
		return Tspath.ComparePaths(a.FileName, b.FileName, new ComparePathsOptions(useCaseSensitiveFileNames));
	}

	public static function PathIsBareSpecifier(path:String):Bool {
		return !Tspath.PathIsAbsolute(path) && !Tspath.PathIsRelative(path);
	}

	public static function IsExcludedByRegex(moduleSpecifier:String, excludes:Null<Array<String>>):Bool {
		if (excludes == null)
			return false;
		for (pattern in excludes) {
			final re = stringToRegex(pattern);
			if (re == null) {
				continue;
			}
			if (re.match(moduleSpecifier)) {
				return true;
			}
		}
		return false;
	}

	// PORT: Go compiles the pattern with RE2 (regexp.Compile) and wraps it in `(?i:...)` when
	// case-insensitive. User patterns cannot be rewritten for the EReg backends (PORTING.md §7),
	// so the pattern is passed to EReg as is (JS RegExp / PCRE2 syntax) and the `i` flag is used.
	// A pattern that does not compile is cached as null, like Go.
	static function stringToRegex(pattern:String):Null<EReg> {
		var caseInsensitive = false;

		if (pattern.length > 2 && StringTools.fastCodeAt(pattern, 0) == "/".code) {
			final lastSlash = pattern.lastIndexOf("/");
			if (lastSlash > 0) {
				var hasUnescapedMiddleSlash = false;
				for (i in 1...lastSlash) {
					if (StringTools.fastCodeAt(pattern, i) == "/".code && (i == 0 || StringTools.fastCodeAt(pattern, i - 1) != "\\".code)) {
						hasUnescapedMiddleSlash = true;
						break;
					}
				}

				if (!hasUnescapedMiddleSlash) {
					final flags = pattern.substring(lastSlash + 1);
					pattern = pattern.substring(1, lastSlash);

					for (i in 0...flags.length) {
						switch (StringTools.fastCodeAt(flags, i)) {
							case "i".code:
								caseInsensitive = true;
							default:
						}
					}
				}
			}
		}
		final key = (caseInsensitive ? "1" : "0") + pattern;

		if (regexPatternCache.exists(key)) {
			return regexPatternCache.get(key);
		}

		if (regexPatternCacheSize > 1000) {
			regexPatternCache.clear();
			regexPatternCacheSize = 0;
		}

		var compiled:Null<EReg> = null;
		try {
			compiled = new EReg(pattern, caseInsensitive ? "i" : "");
		} catch (e:Dynamic) {
			compiled = null;
		}
		regexPatternCache.set(key, compiled);
		regexPatternCacheSize++;
		return compiled;
	}

	/**
	 * Ensures a path is either absolute (prefixed with `/` or `c:`) or dot-relative (prefixed
	 * with `./` or `../`) so as not to be confused with an unprefixed module name.
	 *
	 * ```ts
	 * ensurePathIsNonModuleName("/path/to/file.ext") === "/path/to/file.ext"
	 * ensurePathIsNonModuleName("./path/to/file.ext") === "./path/to/file.ext"
	 * ensurePathIsNonModuleName("../path/to/file.ext") === "../path/to/file.ext"
	 * ensurePathIsNonModuleName("path/to/file.ext") === "./path/to/file.ext"
	 * ```
	 *
	 */
	static function ensurePathIsNonModuleName(path:String):String {
		if (PathIsBareSpecifier(path)) {
			return "./" + path;
		}
		return path;
	}

	public static function GetJSExtensionForDeclarationFileExtension(ext:String):String {
		switch (ext) {
			case Tspath.ExtensionDts:
				return Tspath.ExtensionJs;
			case Tspath.ExtensionDmts:
				return Tspath.ExtensionMjs;
			case Tspath.ExtensionDcts:
				return Tspath.ExtensionCjs;
			default:
				// .d.json.ts and the like
				return ext.substring(".d".length, ext.length - Tspath.ExtensionTs.length);
		}
	}

	// TryGetRealFileNameForNonJSDeclarationFileName remaps files like `foo.d.json.ts` or
	// `foo.module.d.css.ts` back to their real non-JS names.
	public static function TryGetRealFileNameForNonJSDeclarationFileName(fileName:String):String {
		final baseName = Tspath.GetBaseFileName(fileName);
		// Ends with .ts, contains ".d.", and is NOT a standard .d.ts file
		if (!StringTools.endsWith(fileName, Tspath.ExtensionTs) || baseName.indexOf(".d.") < 0 || StringTools.endsWith(baseName, Tspath.ExtensionDts)) {
			return "";
		}
		final noExtension = Tspath.RemoveExtension(fileName, Tspath.ExtensionTs);
		final lastDotIndex = noExtension.lastIndexOf(".");
		final ext = noExtension.substring(lastDotIndex);
		// PORT: strings.Cut(noExtension, ".d.") — `before` is the text before the first ".d." (or all of it).
		final cut = noExtension.indexOf(".d.");
		final before = cut >= 0 ? noExtension.substring(0, cut) : noExtension;
		return before + ext;
	}

	static function getJSExtensionForFile(fileName:String, options:CompilerOptions):String {
		final result = Module.TryGetJSExtensionForFile(fileName, options);
		if (result.length == 0) {
			throw 'Extension ${extensionFromPath(fileName)} is unsupported:: FileName:: $fileName';
		}
		return result;
	}

	/**
	 * Gets the extension from a path.
	 * Path must have a valid extension.
	 */
	static function extensionFromPath(path:String):String {
		final ext = Tspath.TryGetExtensionFromPath(path);
		if (ext.length == 0) {
			throw 'File $path has unknown extension.';
		}
		return ext;
	}

	static function tryGetAnyFileFromPath(host:ModuleSpecifierGenerationHost, path:String):Bool {
		// !!! TODO: shouldn't this use readdir instead of fileexists for perf?
		// We check all js, `node` and `json` extensions in addition to TS, since node module resolution would also choose those over the directory
		final allowJsOptions = new CompilerOptions();
		allowJsOptions.AllowJs = TSTrue;
		final extGroups = Tsoptions.GetSupportedExtensions(allowJsOptions, [
			new FileExtensionInfo("node", false, ScriptKindExternal),
			new FileExtensionInfo("json", false, ScriptKindJSON)
		]);
		for (exts in extGroups) {
			for (e in exts) {
				final fullPath = path + e;
				if (host.FileExists(Tspath.GetNormalizedAbsolutePath(fullPath, host.GetCurrentDirectory()))) {
					return true;
				}
			}
		}
		return false;
	}

	static function getPathsRelativeToRootDirs(path:String, rootDirs:Array<String>, useCaseSensitiveFileNames:Bool):Null<Array<String>> {
		var results:Null<Array<String>> = null;
		for (rootDir in rootDirs) {
			final relativePath = getRelativePathIfInSameVolume(path, rootDir, useCaseSensitiveFileNames);
			if (!isPathRelativeToParent(relativePath)) {
				if (results == null)
					results = [];
				results.push(relativePath);
			}
		}
		return results;
	}

	static function isPathRelativeToParent(path:String):Bool {
		return StringTools.startsWith(path, "..");
	}

	static function getRelativePathIfInSameVolume(path:String, directoryPath:String, useCaseSensitiveFileNames:Bool):String {
		final relativePath = Tspath.GetRelativePathToDirectoryOrUrl(directoryPath, path, false,
			new ComparePathsOptions(useCaseSensitiveFileNames, directoryPath));
		if (Tspath.IsRootedDiskPath(relativePath)) {
			return "";
		}
		return relativePath;
	}

	static function packageJsonPathsAreEqual(a:String, b:String, options:ComparePathsOptions):Bool {
		if (a == b) {
			return true;
		}
		if (a.length == 0 || b.length == 0) {
			return false;
		}
		return Tspath.ComparePaths(a, b, options) == 0;
	}

	static function prefersTsExtension(allowedEndings:Array<ModuleSpecifierEnding>):Bool {
		final jsPriority = Slices.Index(allowedEndings, ModuleSpecifierEndingJsExtension);
		final tsPriority = Slices.Index(allowedEndings, ModuleSpecifierEndingTsExtension);
		if (tsPriority > -1) {
			return tsPriority < jsPriority;
		}
		return false;
	}

	static function replaceFirstStar(s:String, replacement:String):String {
		// PORT: strings.Replace(s, "*", replacement, 1).
		final i = s.indexOf("*");
		if (i < 0)
			return s;
		return s.substring(0, i) + replacement + s.substring(i + 1);
	}

	// PORT: strings.TrimSuffix.
	static inline function trimSuffix(s:String, suffix:String):String {
		return StringTools.endsWith(s, suffix) ? s.substring(0, s.length - suffix.length) : s;
	}

	public static function GetNodeModulePathParts(fullPath:String):Null<NodeModulePathParts> {
		// If fullPath can't be valid module file within node_modules, returns undefined.
		// Example of expected pattern: /base/path/node_modules/[@scope/otherpackage/@otherscope/node_modules/]package/[subdirectory/]file.js
		// Returns indices:                       ^            ^                                                      ^             ^

		var topLevelNodeModulesIndex = 0;
		var topLevelPackageNameIndex = 0;
		var packageRootIndex = 0;
		var fileNameIndex = 0;

		var partStart = 0;
		var partEnd = 0;
		var state = nodeModulesPathParseStateBeforeNodeModules;

		while (partEnd >= 0) {
			partStart = partEnd;
			partEnd = Core.IndexAfter(fullPath, "/", partStart + 1);
			switch (state) {
				case nodeModulesPathParseStateBeforeNodeModules:
					if (fullPath.substring(partStart).indexOf("/node_modules/") == 0) {
						topLevelNodeModulesIndex = partStart;
						topLevelPackageNameIndex = partEnd;
						state = nodeModulesPathParseStateNodeModules;
					}
				case nodeModulesPathParseStateNodeModules, nodeModulesPathParseStateScope:
					if (state == nodeModulesPathParseStateNodeModules && StringTools.fastCodeAt(fullPath, partStart + 1) == "@".code) {
						state = nodeModulesPathParseStateScope;
					} else {
						packageRootIndex = partEnd;
						state = nodeModulesPathParseStatePackageContent;
					}
				case nodeModulesPathParseStatePackageContent:
					if (fullPath.substring(partStart).indexOf("/node_modules/") == 0) {
						state = nodeModulesPathParseStateNodeModules;
					} else {
						state = nodeModulesPathParseStatePackageContent;
					}
				default:
			}
		}

		fileNameIndex = partStart;

		if (state > nodeModulesPathParseStateNodeModules) {
			return new NodeModulePathParts(topLevelNodeModulesIndex, topLevelPackageNameIndex, packageRootIndex, fileNameIndex);
		}
		return null;
	}

	public static function GetNodeModulesPackageName(compilerOptions:CompilerOptions, importingSourceFile:SourceFile, // !!! | FutureSourceFile
			nodeModulesFileName:String, host:ModuleSpecifierGenerationHost, preferences:UserPreferences, options:ModuleSpecifierOptions):String {
		final info = getInfo(importingSourceFile.FileName(), host);
		final modulePaths = getAllModulePaths(info, nodeModulesFileName, host, compilerOptions, preferences, options);
		for (modulePath in modulePaths) {
			final result = tryGetModuleNameAsNodeModule(modulePath, info, SourceFileAdapter.Of(importingSourceFile), host, compilerOptions, preferences,
				true /*packageNameOnly*/, options.OverrideImportMode);
			if (result.length > 0) {
				return result;
			}
		}
		return "";
	}

	static function allKeysStartWithDot(obj:OrderedMap<String, ExportsOrImports>):Bool {
		for (k in obj.Keys()) {
			if (!StringTools.startsWith(k, ".")) {
				return false;
			}
		}
		return true;
	}

	public static function GetPackageNameFromDirectory(fileOrDirectoryPath:String):String {
		final idx = fileOrDirectoryPath.lastIndexOf("/node_modules/");
		if (idx == -1) {
			return "";
		}

		final basename = fileOrDirectoryPath.substring(idx + "/node_modules/".length);
		if (StringTools.fastCodeAt(basename, 0) == ".".code) {
			return "";
		}

		final nextSlash = basename.indexOf("/");
		if (nextSlash == -1) {
			return basename;
		}

		if (StringTools.fastCodeAt(basename, 0) != "@".code || nextSlash == basename.length - 1) {
			return basename.substring(0, nextSlash);
		}

		final secondSlash = basename.substring(nextSlash + 1).indexOf("/");
		if (secondSlash == -1) {
			return basename;
		}

		return basename.substring(0, nextSlash + 1 + secondSlash);
	}

	// ProcessEntrypointEnding processes a pre-computed module specifier from a package.json exports
	// entrypoint according to the entrypoint's Ending type and the user's preferred endings.
	public static function ProcessEntrypointEnding(entrypoint:ResolvedEntrypoint, prefs:UserPreferences, host:ModuleSpecifierGenerationHost,
			options:CompilerOptions, importingSourceFile:SourceFileForSpecifierGeneration, allowedEndings:Null<Array<ModuleSpecifierEnding>>):String {
		var specifier = entrypoint.ModuleSpecifier;
		if (entrypoint.Ending == EndingFixed) {
			return specifier;
		}

		if (Core.len(allowedEndings) == 0) {
			allowedEndings = GetAllowedEndingsInPreferredOrder(prefs, host, options, importingSourceFile, "",
				host.GetDefaultResolutionModeForFile(importingSourceFile));
		}

		final preferredEnding = allowedEndings[0];

		// Handle declaration file extensions
		final dtsExtension = Tspath.GetDeclarationFileExtension(specifier);
		if (dtsExtension != "") {
			switch (preferredEnding) {
				case ModuleSpecifierEndingTsExtension, ModuleSpecifierEndingJsExtension:
					// Map .d.ts -> .js, .d.mts -> .mjs, .d.cts -> .cjs
					final jsExtension = GetJSExtensionForDeclarationFileExtension(dtsExtension);
					return Tspath.ChangeAnyExtension(specifier, jsExtension, [dtsExtension], false);
				case ModuleSpecifierEndingMinimal, ModuleSpecifierEndingIndex:
					if (entrypoint.Ending == EndingChangeable) {
						// .d.mts/.d.cts must keep an extension; rewrite to .mjs/.cjs instead of dropping
						if (dtsExtension == Tspath.ExtensionDts) {
							specifier = Tspath.RemoveExtension(specifier, dtsExtension);
							if (preferredEnding == ModuleSpecifierEndingMinimal) {
								specifier = trimSuffix(specifier, "/index");
							}
							return specifier;
						}
						final jsExtension = GetJSExtensionForDeclarationFileExtension(dtsExtension);
						return Tspath.ChangeAnyExtension(specifier, jsExtension, [dtsExtension], false);
					}
					// EndingExtensionChangeable - can only change extension, not remove it
					final jsExtension = GetJSExtensionForDeclarationFileExtension(dtsExtension);
					return Tspath.ChangeAnyExtension(specifier, jsExtension, [dtsExtension], false);
				default:
			}
			return specifier;
		}

		// Handle .ts/.tsx/.mts/.cts extensions
		if (Tspath.FileExtensionIsOneOf(specifier, [Tspath.ExtensionTs, Tspath.ExtensionTsx, Tspath.ExtensionMts, Tspath.ExtensionCts])) {
			switch (preferredEnding) {
				case ModuleSpecifierEndingTsExtension:
					return specifier;
				case ModuleSpecifierEndingJsExtension:
					final jsExtension = Module.TryGetJSExtensionForFile(specifier, options);
					if (jsExtension != "") {
						return Tspath.RemoveFileExtension(specifier) + jsExtension;
					}
					return specifier;
				case ModuleSpecifierEndingMinimal, ModuleSpecifierEndingIndex:
					if (entrypoint.Ending == EndingChangeable) {
						specifier = Tspath.RemoveFileExtension(specifier);
						if (preferredEnding == ModuleSpecifierEndingMinimal) {
							specifier = trimSuffix(specifier, "/index");
						}
						return specifier;
					}
					// EndingExtensionChangeable - can only change extension, not remove it
					final jsExtension = Module.TryGetJSExtensionForFile(specifier, options);
					if (jsExtension != "") {
						return Tspath.RemoveFileExtension(specifier) + jsExtension;
					}
					return specifier;
				default:
			}
			return specifier;
		}

		// Handle .js/.jsx/.mjs/.cjs extensions
		if (Tspath.FileExtensionIsOneOf(specifier, [Tspath.ExtensionJs, Tspath.ExtensionJsx, Tspath.ExtensionMjs, Tspath.ExtensionCjs])) {
			switch (preferredEnding) {
				case ModuleSpecifierEndingTsExtension, ModuleSpecifierEndingJsExtension:
					return specifier;
				case ModuleSpecifierEndingMinimal, ModuleSpecifierEndingIndex:
					if (entrypoint.Ending == EndingChangeable) {
						specifier = Tspath.RemoveFileExtension(specifier);
						if (preferredEnding == ModuleSpecifierEndingMinimal) {
							specifier = trimSuffix(specifier, "/index");
						}
						return specifier;
					}
					// EndingExtensionChangeable - keep the extension
					return specifier;
				default:
			}
			return specifier;
		}

		// For other extensions (like .json), return as-is
		return specifier;
	}
}
