package ts.compiler;

import ts.diagnostics.Diagnostics.Message;

// Package compiler implements the TypeScript compiler.
// Port of package internal/compiler: the package-level functions, vars and consts of all files
// (Go file order). The types and methods are in the module of their Go file.
@:allow(ts.compiler)
class Compiler {
	// --- checkerpool.go ---

	static function newCheckerPool(program:Program):CheckerPool_ {
		return newCheckerPoolWithTracing(program, null);
	}

	static function newCheckerPoolWithTracing(program:Program, tr:Tracing):CheckerPool_ {
		var checkerCount = 4;
		if (program.SingleThreaded()) {
			checkerCount = 1;
		} else {
			final c = program.Options().Checkers;
			if (c != null) {
				checkerCount = c;
			}
		}

		checkerCount = std.Math.round(std.Math.max(std.Math.min(std.Math.min(checkerCount, program.files.length), 256), 1));

		final pool = new CheckerPool_();
		pool.program = program;
		pool.checkers = [for (_ in 0...checkerCount) null];
		pool.locks = [for (_ in 0...checkerCount) null];
		pool.tracing = tr;

		return pool;
	}

	static function noop():Void {}

	// --- emitHost.go ---

	// PORT: (*emitHost, func()) → Pair
	static function newEmitHost(ctx:Context, program:Program, file:SourceFile):Pair<EmitHost_, () -> Void> {
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — Go locks the checker in each EmitResolver call (checkerMu, dropped
		// in this port); here the file holds its checker while it is emitted
		final r = program.GetTypeCheckerForFileExclusive(ctx, file);
		#else
		final r = program.GetTypeCheckerForFile(ctx, file);
		#end
		final checker = r.a, done = r.b;
		final host = new EmitHost_();
		host.program = program;
		host.emitResolver = checker.GetEmitResolver();
		return new Pair(host, done);
	}

	// --- emitter.go ---

	static function getModuleTransformer(opts:TransformOptions):Transformer {
		switch (opts.CompilerOptions.GetEmitModuleKind()) {
			case ModuleKindPreserve:
				// `ESModuleTransformer` contains logic for preserving CJS input syntax in `--module preserve`
				return Moduletransforms.NewESModuleTransformer(opts);

			case ModuleKindESNext | ModuleKindES2022 | ModuleKindES2020 | ModuleKindES2015 | ModuleKindNode20 | ModuleKindNode18 | ModuleKindNode16 |
				ModuleKindNodeNext | ModuleKindCommonJS:
				return Moduletransforms.NewImpliedModuleTransformer(opts);

			default:
				return Moduletransforms.NewCommonJSModuleTransformer(opts);
		}
	}

	static function getScriptTransformers(emitContext:EmitContext, host:ts.printer.Emithost.EmitHost, sourceFile:SourceFile):Array<Transformer> {
		final tx:Array<Transformer> = [];
		final options = host.Options();

		// JS files don't use reference calculations as they don't do import elision, no need to calculate it
		final importElisionEnabled = !options.VerbatimModuleSyntax.IsTrue() && !Ast.IsInJSFile(sourceFile.AsNode());
		final jsxTransformEnabled = options.GetJSXTransformEnabled() && sourceFile.LanguageVariant == LanguageVariantJSX;

		final emitResolver = host.GetEmitResolver();

		var referenceResolver:ReferenceResolver;
		if (importElisionEnabled || jsxTransformEnabled || !options.GetIsolatedModules() || options.EmitDecoratorMetadata.IsTrue()) {
			referenceResolver = emitResolver;
		} else {
			referenceResolver = Binder.NewReferenceResolver(options, new ReferenceResolverHooks());
		}

		final opts = new TransformOptions();
		opts.Context = emitContext;
		opts.CompilerOptions = options;
		opts.Resolver = referenceResolver;
		opts.EmitResolver = emitResolver;
		opts.GetEmitModuleFormatOfFile = host.GetEmitModuleFormatOfFile;

		// transform TypeScript syntax
		{
			// use type nodes to add metadata decorators
			if (options.EmitDecoratorMetadata.IsTrue()) {
				tx.push(Tstransforms.NewMetadataTransformer(opts));
			}

			// erase types
			tx.push(Tstransforms.NewTypeEraserTransformer(opts));

			// elide imports
			if (importElisionEnabled) {
				tx.push(Tstransforms.NewImportElisionTransformer(opts));
			}

			// transform `enum`, `namespace`, and parameter properties
			tx.push(Tstransforms.NewRuntimeSyntaxTransformer(opts));

			if (options.ExperimentalDecorators.IsTrue()) {
				tx.push(Tstransforms.NewLegacyDecoratorsTransformer(opts));
			}
		}

		if (jsxTransformEnabled) {
			tx.push(Jsxtransforms.NewJSXTransformer(opts));
		}

		final downleveler = Estransforms.GetESTransformer(opts);
		if (downleveler != null) {
			tx.push(downleveler);
		}

		tx.push(Estransforms.NewUseStrictTransformer(opts));

		// transform module syntax
		tx.push(getModuleTransformer(opts));

		// inlining (formerly done via substitutions)
		if (!options.GetIsolatedModules()) {
			tx.push(Inliners.NewConstEnumInliningTransformer(opts));
		}
		return tx;
	}

	static function shouldEmitSourceMaps(mapOptions:CompilerOptions, sourceFile:SourceFile):Bool {
		return (mapOptions.SourceMap.IsTrue() || mapOptions.InlineSourceMap.IsTrue()) && !Tspath.FileExtensionIs(sourceFile.FileName(), Tspath.ExtensionJson);
	}

	static function getSourceRoot(mapOptions:CompilerOptions):std.String {
		// Normalize source root and make sure it has trailing "/" so that it can be used to combine paths with the
		// relative paths of the sources list in the sourcemap
		var sourceRoot = Tspath.NormalizeSlashes(mapOptions.SourceRoot);
		if (sourceRoot.length > 0) {
			sourceRoot = Tspath.EnsureTrailingDirectorySeparator(sourceRoot);
		}
		return sourceRoot;
	}

	static function sourceFileMayBeEmitted(sourceFile:SourceFile, host:SourceFileMayBeEmittedHost, forceDtsEmit:Bool):Bool {
		// TODO: move this to outputpaths?

		final options = host.Options();
		// Js files are emitted only if option is enabled
		if (options.NoEmitForJsFiles.IsTrue() && Ast.IsSourceFileJS(sourceFile)) {
			return false;
		}

		// Declaration files are not emitted
		if (sourceFile.IsDeclarationFile) {
			return false;
		}

		// Source file from node_modules are not emitted
		if (host.IsSourceFileFromExternalLibrary(sourceFile)) {
			return false;
		}

		// forcing dts emit => file needs to be emitted
		if (forceDtsEmit) {
			return true;
		}

		// Check other conditions for file emit
		// Source files from referenced projects are not emitted
		if (host.GetProjectReferenceFromSource(sourceFile.Path()) != null) {
			return false;
		}

		// Any non json file should be emitted
		if (!Ast.IsJsonSourceFile(sourceFile)) {
			return true;
		}

		// Json file is not emitted if outDir is not specified
		if (options.OutDir == "") {
			return false;
		}

		// Otherwise, if rootDir is specified or a config file exists, we know the common source directory and can check if the file would be emitted in the same location
		if (options.RootDir != "" || options.ConfigFilePath != "") {
			final commonDir = Tspath.GetNormalizedAbsolutePath(Outputpaths.GetCommonSourceDirectory(options, function() return null, host.GetCurrentDirectory(),
				host.UseCaseSensitiveFileNames(), null), host.GetCurrentDirectory());
			final outputPath = Outputpaths.GetSourceFilePathInNewDirWorker(sourceFile.FileName(), options.OutDir, host.GetCurrentDirectory(), commonDir,
				host.UseCaseSensitiveFileNames());
			if (Tspath.ComparePaths(sourceFile.FileName(), outputPath, new ComparePathsOptions(host.UseCaseSensitiveFileNames(), host.GetCurrentDirectory())) == 0) {
				return false;
			}
		}

		return true;
	}

	static function getSourceFilesToEmit(host:SourceFileMayBeEmittedHost, targetSourceFile:SourceFile, forceDtsEmit:Bool):Array<SourceFile> {
		var sourceFiles:Array<SourceFile>;
		if (targetSourceFile != null) {
			sourceFiles = [targetSourceFile];
		} else {
			sourceFiles = host.SourceFiles();
		}
		return Core.Filter(sourceFiles, function(sourceFile:SourceFile):Bool {
			return sourceFileMayBeEmitted(sourceFile, host, forceDtsEmit);
		});
	}

	static function isSourceFileNotJson(file:SourceFile):Bool {
		return !Ast.IsJsonSourceFile(file);
	}

	static function getDeclarationDiagnostics(host:EmitHost, file:SourceFile):Array<Diagnostic> {
		// TODO: use p.getSourceFilesToEmit cache
		final fullFiles = Core.Filter(getSourceFilesToEmit(host, file, false), isSourceFileNotJson);
		if (!Core.Some(fullFiles, function(f:SourceFile) return f == file)) {
			return [];
		}
		final options = host.Options();
		final transform = Declarations.NewDeclarationTransformer(host, null, options, "", "");
		transform.Transformer.TransformSourceFile(file);
		return transform.GetDiagnostics();
	}

	// --- fileloader.go ---

	static function processAllProgramFiles(opts:ProgramOptions, singleThreaded:Bool):ProcessedFiles {
		final compilerOptions = opts.Config.CompilerOptions();
		final rootFiles = opts.Config.FileNames();
		final supportedExtensions = Tsoptions.GetSupportedExtensions(compilerOptions, null /*extraFileExtensions*/);
		final supportedExtensionsWithJsonIfResolveJsonModule = Tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(compilerOptions,
			supportedExtensions);
		var maxNodeModuleJsDepth = 0;
		final p = opts.Config.CompilerOptions().MaxNodeModuleJsDepth;
		if (p != null) {
			maxNodeModuleJsDepth = p;
		}
		final loader = new FileLoader();
		loader.opts = opts;
		loader.defaultLibraryPath = Tspath.GetNormalizedAbsolutePath(opts.Host.DefaultLibraryPath(), opts.Host.GetCurrentDirectory());
		loader.comparePathsOptions = new ComparePathsOptions(opts.Host.FS().UseCaseSensitiveFileNames(), opts.Host.GetCurrentDirectory());
		loader.filesParser = new FilesParser();
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — the files are loaded and parsed on threads, as in Go
		loader.filesParser.wg = singleThreaded ? Core.NewWorkGroup(true) : new ParallelWorkGroup();
		#else
		loader.filesParser.wg = Core.NewWorkGroup(singleThreaded);
		#end
		loader.filesParser.maxDepth = maxNodeModuleJsDepth;
		loader.rootTasks = [];
		loader.supportedExtensions = supportedExtensions;
		loader.supportedExtensionsWithJsonIfResolveJsonModule = supportedExtensionsWithJsonIfResolveJsonModule;
		loader.addProjectReferenceTasks(singleThreaded);
		loader.resolver = Module.NewResolver(loader.projectReferenceFileMapper.host, compilerOptions, opts.TypingsLocation, opts.ProjectName);
		var done:() -> Void = null;
		if (opts.Tracing != null) {
			final args = new StringMap<Any>();
			args.set("count", Core.len(rootFiles));
			done = opts.Tracing.Push(PhaseProgram, "processRootFiles", args, false);
		}
		try {
			if (rootFiles != null) {
				for (index in 0...rootFiles.length) {
					loader.addRootFileTask(rootFiles[index], null, new FileIncludeReason(fileIncludeKindRootFile, index));
				}
			}
			if (Core.len(rootFiles) > 0 && compilerOptions.NoLib.IsFalseOrUnknown()) {
				if (compilerOptions.Lib == null) {
					final name = Tsoptions.GetDefaultLibFileName(compilerOptions);
					final libFile = loader.pathForLibFile(name);
					loader.addRootTask(libFile.path, libFile, new FileIncludeReason(fileIncludeKindLibFile));
				} else {
					for (index in 0...compilerOptions.Lib.length) {
						final lib = compilerOptions.Lib[index];
						final n = Tsoptions.GetLibFileName(lib);
						if (n.ok) {
							final libFile = loader.pathForLibFile(n.value);
							loader.addRootTask(libFile.path, libFile, new FileIncludeReason(fileIncludeKindLibFile, index));
						}
						// !!! error on unknown name
					}
				}
			}

			if (Core.len(rootFiles) > 0) {
				loader.addAutomaticTypeDirectiveTasks();
			}

			loader.filesParser.parse(loader, loader.rootTasks);

			// Clear out loader and host to ensure its not used post program creation
			loader.projectReferenceFileMapper.loader = null;
			loader.projectReferenceFileMapper.host = null;

			final result = loader.filesParser.getProcessedFiles(loader);
			if (done != null)
				done();
			return result;
		} catch (e:Dynamic) {
			if (done != null)
				done();
			throw e;
		}
	}

	static function getLibraryNameFromLibFileName(libFileName:std.String):std.String {
		// Support resolving to lib.dom.d.ts -> @typescript/lib-dom, and
		//                      lib.dom.iterable.d.ts -> @typescript/lib-dom/iterable
		//                      lib.es2015.symbol.wellknown.d.ts -> @typescript/lib-es2015/symbol-wellknown
		final components = libFileName.split(".");
		final path = new StringBuf();
		path.add("@typescript/lib-");
		if (components.length > 1) {
			path.add(components[1]);
		}
		var i = 2;
		while (i < components.length && components[i] != "" && components[i] != "d") {
			if (i == 2) {
				path.add("/");
			} else {
				path.add("-");
			}
			path.add(components[i]);
			i++;
		}
		return path.toString();
	}

	static function getInferredLibraryNameResolveFrom(options:CompilerOptions, currentDirectory:std.String, libFileName:std.String):std.String {
		var containingDirectory:std.String;
		if (options.ConfigFilePath != "") {
			containingDirectory = Tspath.GetDirectoryPath(options.ConfigFilePath);
		} else {
			containingDirectory = currentDirectory;
		}
		return Tspath.CombinePaths(containingDirectory, "__lib_node_modules_lookup_" + libFileName + "__.ts");
	}

	static function getModeForTypeReferenceDirectiveInFile(ref:FileReference, file:SourceFile, meta:SourceFileMetaData, options:CompilerOptions):ResolutionMode {
		if (ref.ResolutionMode != Core.ResolutionModeNone) {
			return ref.ResolutionMode;
		} else {
			return getDefaultResolutionModeForFile(file.FileName(), meta, options);
		}
	}

	static function getDefaultResolutionModeForFile(fileName:std.String, meta:SourceFileMetaData, options:CompilerOptions):ResolutionMode {
		if (importSyntaxAffectsModuleResolution(options)) {
			return Ast.GetImpliedNodeFormatForEmitWorker(fileName, options.GetEmitModuleKind(), meta);
		} else {
			return Core.ResolutionModeNone;
		}
	}

	static function getModeForUsageLocation(fileName:std.String, meta:SourceFileMetaData, usage:StringLiteralLike, options:CompilerOptions):ResolutionMode {
		if (Ast.IsImportDeclaration(usage.Parent)
			|| usage.Parent.Kind == KindJSImportDeclaration
			|| Ast.IsExportDeclaration(usage.Parent)
			|| Ast.IsJSDocImportTag(usage.Parent)) {
			final isTypeOnly = Ast.IsExclusivelyTypeOnlyImportOrExport(usage.Parent);
			if (isTypeOnly) {
				var r:ValueOk<ResolutionMode> = new ValueOk(Core.ResolutionModeNone, false);
				switch (usage.Parent.Kind) {
					case KindImportDeclaration | KindJSImportDeclaration:
						r = getResolutionModeOverrideOf(usage.Parent.AsImportDeclaration().Attributes);
					case KindExportDeclaration:
						r = getResolutionModeOverrideOf(usage.Parent.AsExportDeclaration().Attributes);
					case KindJSDocImportTag:
						r = getResolutionModeOverrideOf(usage.Parent.AsJSDocImportTag().Attributes);
					default:
				}
				if (r.ok) {
					return r.value;
				}
			}
		}
		if (Ast.IsLiteralTypeNode(usage.Parent) && Ast.IsImportTypeNode(usage.Parent.Parent)) {
			final r = getResolutionModeOverrideOf(usage.Parent.Parent.AsImportTypeNode().Attributes);
			if (r.ok) {
				return r.value;
			}
		}

		if (options != null && importSyntaxAffectsModuleResolution(options)) {
			return getEmitSyntaxForUsageLocationWorker(fileName, meta, usage, options);
		}

		return Core.ResolutionModeNone;
	}

	// PORT: Go calls the method `(*ImportAttributesNode).GetResolutionModeOverride` on a possibly-nil node.
	static inline function getResolutionModeOverrideOf(attributes:Node):ValueOk<ResolutionMode> {
		return attributes.GetResolutionModeOverride();
	}

	static function importSyntaxAffectsModuleResolution(options:CompilerOptions):Bool {
		final moduleResolution = options.GetModuleResolutionKind();
		return (ModuleResolutionKindNode16 : Int) <= (moduleResolution : Int) && (moduleResolution : Int) <= (ModuleResolutionKindNodeNext : Int)
			|| options.GetResolvePackageJsonExports()
			|| options.GetResolvePackageJsonImports();
	}

	static function getEmitSyntaxForUsageLocationWorker(fileName:std.String, meta:SourceFileMetaData, usage:Node, options:CompilerOptions):ResolutionMode {
		if (Ast.IsRequireCall(usage.Parent, false /*requireStringLiteralLikeArgument*/)
			|| Ast.IsExternalModuleReference(usage.Parent) && Ast.IsImportEqualsDeclaration(usage.Parent.Parent)) {
			return ModuleKindCommonJS;
		}
		final fileEmitMode = Ast.GetEmitModuleFormatOfFileWorker(fileName, options, meta);
		if (Ast.IsImportCall(Ast.WalkUpParenthesizedExpressions(usage.Parent))) {
			if (Ast.ShouldTransformImportCall(fileName, options, fileEmitMode)) {
				return ModuleKindCommonJS;
			} else {
				return ModuleKindESNext;
			}
		}
		// If we're in --module preserve on an input file, we know that an import
		// is an import. But if this is a declaration file, we'd prefer to use the
		// impliedNodeFormat. Since we want things to be consistent between the two,
		// we need to issue errors when the user writes ESM syntax in a definitely-CJS
		// file, until/unless declaration emit can indicate a true ESM import. On the
		// other hand, writing CJS syntax in a definitely-ESM file is fine, since declaration
		// emit preserves the CJS syntax.
		if (fileEmitMode == ModuleKindCommonJS) {
			return ModuleKindCommonJS;
		} else {
			if (fileEmitMode.IsNonNodeESM() || fileEmitMode == ModuleKindPreserve) {
				return ModuleKindESNext;
			}
		}
		return ModuleKindNone;
	}

	static inline final externalHelpersModuleNameText = "tslib"; // TODO(jakebailey): dedupe

	// --- filesparser.go ---

	// PORT: sync.Pool parseTaskDataPool → a new parseTaskData per call.
	static function getParseTaskData(task:ParseTask):ParseTaskData {
		final td = new ParseTaskData();
		td.tasks.set(task.normalizedFilePath, task);
		td.lowestDepth = 0x7FFFFFFF; // math.MaxInt
		return td;
	}

	static function putParseTaskData(td:ParseTaskData):Void {
		td.tasks.clear();
	}

	// --- includeprocessor.go ---

	static function updateFileIncludeProcessor(p:Program):Void {
		final ip = new IncludeProcessor();
		ip.fileIncludeReasons = p.includeProcessor.fileIncludeReasons;
		ip.processingDiagnostics = p.includeProcessor.processingDiagnostics;
		p.includeProcessor = ip;
	}

	// --- program.go ---

	public static function NewProgram(opts:ProgramOptions):Program {
		final p = new Program();
		p.opts = opts;
		var done:() -> Void = null;
		if (p.opts.Tracing != null) {
			final args = new StringMap<Any>();
			args.set("configFilePath", opts.Config.CompilerOptions().ConfigFilePath);
			done = p.opts.Tracing.Push(PhaseProgram, "createProgram", args, true);
		}
		try {
			p.processedFiles = processAllProgramFiles(p.opts, p.SingleThreaded());
			p.initCheckerPool();
			p.verifyCompilerOptions();
		} catch (e:Dynamic) {
			if (done != null)
				done();
			throw e;
		}
		if (done != null)
			done();
		return p;
	}

	static function canReplaceFileInProgram(file1:SourceFile, file2:SourceFile):Bool {
		return file2 != null
			&& parseOptionsEqual(file1.ParseOptions(), file2.ParseOptions())
			&& file1.UsesUriStyleNodeCoreModules == file2.UsesUriStyleNodeCoreModules
			&& Slices.EqualFunc(file1.Imports(), file2.Imports(), equalModuleSpecifiers)
			&& Slices.EqualFunc(file1.ModuleAugmentations, file2.ModuleAugmentations, equalModuleAugmentationNames)
			&& Slices.Equal(file1.AmbientModuleNames, file2.AmbientModuleNames)
			&& Slices.EqualFunc(file1.ReferencedFiles, file2.ReferencedFiles, equalFileReferences)
			&& Slices.EqualFunc(file1.TypeReferenceDirectives, file2.TypeReferenceDirectives, equalFileReferences)
			&& Slices.EqualFunc(file1.LibReferenceDirectives, file2.LibReferenceDirectives, equalFileReferences)
			&& equalCheckJSDirectives(file1.CheckJsDirective, file2.CheckJsDirective);
	}

	// PORT: Go `==` on the ast.SourceFileParseOptions struct.
	static function parseOptionsEqual(a:SourceFileParseOptions, b:SourceFileParseOptions):Bool {
		return a.FileName == b.FileName
			&& a.Path == b.Path
			&& a.ExternalModuleIndicatorOptions.JSX == b.ExternalModuleIndicatorOptions.JSX
			&& a.ExternalModuleIndicatorOptions.Force == b.ExternalModuleIndicatorOptions.Force;
	}

	static function equalModuleSpecifiers(n1:Node, n2:Node):Bool {
		return n1.Kind == n2.Kind && (!Ast.IsStringLiteral(n1) || n1.Text() == n2.Text());
	}

	static function equalModuleAugmentationNames(n1:Node, n2:Node):Bool {
		return n1.Kind == n2.Kind && n1.Text() == n2.Text();
	}

	static function equalFileReferences(f1:FileReference, f2:FileReference):Bool {
		return f1.FileName == f2.FileName && f1.ResolutionMode == f2.ResolutionMode && f1.Preserve == f2.Preserve;
	}

	static function equalCheckJSDirectives(d1:CheckJsDirective, d2:CheckJsDirective):Bool {
		return d1 == null && d2 == null || d1 != null && d2 != null && d1.Enabled == d2.Enabled;
	}

	// getAdditionalJSSyntacticDiagnostics produces option-dependent syntactic diagnostics for JS files
	// that aren't covered by the parser or the checker. In Strada, the equivalent logic lives in
	// getJSSyntacticDiagnosticsForFile in program.ts. In Corsa, most of that function's checks were
	// moved into the parser (checkJSSyntax/checkJSDecoratorSyntax), but checks that depend on compiler
	// options can't live in the parser and must remain here. The checker handles these for checked files,
	// but doesn't run on unchecked JS files (no checkJs/ts-check).
	static function getAdditionalJSSyntacticDiagnostics(file:SourceFile, options:CompilerOptions):Array<Diagnostic> {
		if (options.ExperimentalDecorators.IsTrue()) {
			return null;
		}
		var diags:Array<Diagnostic> = null;
		// Parameter decorators are only valid with experimentalDecorators. Without it,
		// the checker would report this, but the checker doesn't run on unchecked JS files.
		var walk:Visitor = null;
		walk = function(node:Node):Bool {
			if ((node.SubtreeFacts() & SubtreeContainsDecorators) == 0) {
				return false;
			}
			if (node.Kind == KindParameter && Ast.HasDecorators(node)) {
				final decorator = Core.Find(node.ModifierNodes(), Ast.IsDecorator);
				if (decorator != null) {
					if (diags == null)
						diags = [];
					diags.push(Ast.NewDiagnostic(file, decorator.Loc, Diagnostics.Decorators_are_not_valid_here));
				}
			}
			node.ForEachChild(walk);
			return false;
		};
		file.AsNode().ForEachChild(walk);
		return diags;
	}

	static function hasZeroOrOneAsteriskCharacter(str:std.String):Bool {
		var seenAsterisk = false;
		for (i in 0...str.length) {
			final ch = StringTools.fastCodeAt(str, i);
			if (ch == "*".code) {
				if (!seenAsterisk) {
					seenAsterisk = true;
				} else {
					// have already seen asterisk
					return false;
				}
			}
		}
		return true;
	}

	static function moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution:ModuleResolutionKind):Bool {
		return (moduleResolution : Int) >= (ModuleResolutionKindNode16 : Int) && (moduleResolution : Int) <= (ModuleResolutionKindNodeNext : Int)
			|| moduleResolution == ModuleResolutionKindBundler;
	}

	static function emitModuleKindIsNonNodeESM(moduleKind:ModuleKind):Bool {
		return (moduleKind : Int) >= (ModuleKindES2015 : Int) && (moduleKind : Int) <= (ModuleKindESNext : Int);
	}

	public static function FilterNoEmitSemanticDiagnostics(diagnostics:Array<Diagnostic>, options:CompilerOptions):Array<Diagnostic> {
		if (!options.NoEmit.IsTrue()) {
			return diagnostics;
		}
		return Core.Filter(diagnostics, function(d:Diagnostic):Bool {
			return !d.SkippedOnNoEmit();
		});
	}

	static function isCommentOrBlankLine(text:std.String, pos:Int):Bool {
		while (pos < text.length && (StringTools.fastCodeAt(text, pos) == " ".code || StringTools.fastCodeAt(text, pos) == "\t".code)) {
			pos++;
		}
		return pos == text.length
			|| pos < text.length && (StringTools.fastCodeAt(text, pos) == "\r".code || StringTools.fastCodeAt(text, pos) == "\n".code)
			|| pos + 1 < text.length && StringTools.fastCodeAt(text, pos) == "/".code && StringTools.fastCodeAt(text, pos + 1) == "/".code;
	}

	public static function SortAndDeduplicateDiagnostics(diagnostics:Array<Diagnostic>):Array<Diagnostic> {
		diagnostics = Slices.Clone(diagnostics);
		Slices.SortFunc(diagnostics, Ast.CompareDiagnostics);
		return compactAndMergeRelatedInfos(diagnostics);
	}

	// Remove duplicate diagnostics and, for sequences of diagnostics that differ only by related information,
	// create a single diagnostic with sorted and deduplicated related information.
	static function compactAndMergeRelatedInfos(diagnostics:Array<Diagnostic>):Array<Diagnostic> {
		if (Core.len(diagnostics) < 2) {
			return diagnostics;
		}
		var i = 0;
		var j = 0;
		while (i < diagnostics.length) {
			var d = diagnostics[i];
			var n = 1;
			while (i + n < diagnostics.length && Ast.EqualDiagnosticsNoRelatedInfo(d, diagnostics[i + n])) {
				n++;
			}
			if (n > 1) {
				var relatedInfos:Array<Diagnostic> = null;
				for (k in 0...n) {
					final ri = diagnostics[i + k].RelatedInformation();
					if (ri != null && ri.length > 0) {
						if (relatedInfos == null)
							relatedInfos = [];
						for (x in ri)
							relatedInfos.push(x);
					}
				}
				if (relatedInfos != null) {
					Slices.SortFunc(relatedInfos, Ast.CompareDiagnostics);
					relatedInfos = Slices.CompactFunc(relatedInfos, Ast.EqualDiagnostics);
					d = d.Clone().SetRelatedInfo(relatedInfos);
				}
			}
			diagnostics[j] = d;
			i += n;
			j++;
		}
		diagnostics.resize(j);
		return diagnostics;
	}

	public static function CombineEmitResults(results:Array<EmitResult>):EmitResult {
		final result = new EmitResult();
		if (results == null)
			return result;
		for (emitResult in results) {
			if (emitResult == null) {
				continue; // Skip nil results
			}
			if (emitResult.EmitSkipped) {
				result.EmitSkipped = true;
			}
			result.Diagnostics = appendAll(result.Diagnostics, emitResult.Diagnostics);
			result.EmittedFiles = appendAll(result.EmittedFiles, emitResult.EmittedFiles);
			if (emitResult.SourceMaps != null) {
				result.SourceMaps = appendAll(result.SourceMaps, emitResult.SourceMaps);
			}
		}
		return result;
	}

	// PORT: Go `append(s, other...)` where s is owned by the caller; nil stays nil when nothing is added.
	static function appendAll<T>(s:Array<T>, other:Array<T>):Array<T> {
		if (other == null || other.length == 0)
			return s;
		if (s == null)
			s = [];
		for (x in other)
			s.push(x);
		return s;
	}

	public static function HandleNoEmitOnError(ctx:Context, program:ProgramLike, file:SourceFile):EmitResult {
		if (!program.Options().NoEmitOnError.IsTrue()) {
			return null; // No emit on error is not set, so we can proceed with emitting
		}

		final diagnostics = GetDiagnosticsOfAnyProgram(ctx, program, file, true, program.GetBindDiagnostics, program.GetSemanticDiagnostics);
		if (Core.len(diagnostics) == 0) {
			return null; // No diagnostics, so we can proceed with emitting
		}
		final r = new EmitResult();
		r.Diagnostics = diagnostics;
		r.EmitSkipped = true;
		return r;
	}

	public static function GetDiagnosticsOfAnyProgram(ctx:Context, program:ProgramLike, file:SourceFile, skipNoEmitCheckForDtsDiagnostics:Bool,
			getBindDiagnostics:(Context, SourceFile) -> Array<Diagnostic>, getSemanticDiagnostics:(Context, SourceFile) -> Array<Diagnostic>):Array<Diagnostic> {
		var allDiagnostics = Slices.Clone(program.GetConfigFileParsingDiagnostics());
		final configFileParsingDiagnosticsLength = Core.len(allDiagnostics);

		allDiagnostics = appendAll(allDiagnostics, program.GetSyntacticDiagnostics(ctx, file));

		// If we didn't have any syntactic errors, then also try getting the program (options),
		// global and semantic errors.
		if (Core.len(allDiagnostics) == configFileParsingDiagnosticsLength) {
			allDiagnostics = appendAll(allDiagnostics, program.GetProgramDiagnostics());

			// Do binding early so we can track the time.
			getBindDiagnostics(ctx, file);

			if (program.Options().ListFilesOnly.IsFalseOrUnknown()) {
				allDiagnostics = appendAll(allDiagnostics, program.GetGlobalDiagnostics(ctx));

				if (Core.len(allDiagnostics) == configFileParsingDiagnosticsLength) {
					allDiagnostics = appendAll(allDiagnostics, getSemanticDiagnostics(ctx, file));
					// Ask for the global diagnostics again (they were empty above); we may have found new during checking, e.g. missing globals.
					allDiagnostics = appendAll(allDiagnostics, program.GetGlobalDiagnostics(ctx));
				}

				if ((skipNoEmitCheckForDtsDiagnostics || program.Options().NoEmit.IsTrue())
					&& program.Options().GetEmitDeclarations()
					&& Core.len(allDiagnostics) == configFileParsingDiagnosticsLength) {
					allDiagnostics = appendAll(allDiagnostics, program.GetDeclarationDiagnostics(ctx, file));
				}
			}
		}
		return allDiagnostics;
	}

	static function forEachResolution<T>(resolutionCache:StringMap<ModeAwareCache<T>>,
			callback:(resolution:T, moduleName:std.String, mode:ResolutionMode, filePath:Path) -> Void, file:SourceFile):Void {
		if (file != null) {
			final resolutions = resolutionCache.get(file.Path());
			if (resolutions != null) {
				for (key => resolution in resolutions) {
					final k = ModeAwareCacheKey.ModeAwareCacheKeyFromKey(key);
					callback(resolution, k.Name, k.Mode, file.Path());
				}
			}
		} else {
			for (filePath => resolutions in resolutionCache) {
				if (resolutions == null)
					continue;
				for (key => resolution in resolutions) {
					final k = ModeAwareCacheKey.ModeAwareCacheKeyFromKey(key);
					callback(resolution, k.Name, k.Mode, filePath);
				}
			}
		}
	}

	static var plainJSErrors(get, never):Set<Int>;
	static var _plainJSErrors:Set<Int> = null;

	static function get_plainJSErrors():Set<Int> {
		if (_plainJSErrors == null) {
			// PORT: direct arguments as in Go (a spread of an Array<Int> into a generic rest parameter fails JVM verification)
			_plainJSErrors = Collections.NewSetFromItems(
				// binder errors
				Diagnostics.Cannot_redeclare_block_scoped_variable_0.Code(),
				Diagnostics.A_module_cannot_have_multiple_default_exports.Code(),
				Diagnostics.Another_export_default_is_here.Code(),
				Diagnostics.The_first_export_default_is_here.Code(),
				Diagnostics.Identifier_expected_0_is_a_reserved_word_at_the_top_level_of_a_module.Code(),
				Diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Modules_are_automatically_in_strict_mode.Code(),
				Diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here.Code(),
				Diagnostics.X_constructor_is_a_reserved_word.Code(),
				Diagnostics.X_delete_cannot_be_called_on_an_identifier_in_strict_mode.Code(),
				Diagnostics.Code_contained_in_a_class_is_evaluated_in_JavaScript_s_strict_mode_which_does_not_allow_this_use_of_0_For_more_information_see_https_Colon_Slash_Slashdeveloper_mozilla_org_Slashen_US_Slashdocs_SlashWeb_SlashJavaScript_SlashReference_SlashStrict_mode.Code(),
				Diagnostics.Invalid_use_of_0_Modules_are_automatically_in_strict_mode.Code(),
				Diagnostics.Invalid_use_of_0_in_strict_mode.Code(),
				Diagnostics.A_label_is_not_allowed_here.Code(),
				Diagnostics.X_with_statements_are_not_allowed_in_strict_mode.Code(),
				// grammar errors
				Diagnostics.A_break_statement_can_only_be_used_within_an_enclosing_iteration_or_switch_statement.Code(),
				Diagnostics.A_break_statement_can_only_jump_to_a_label_of_an_enclosing_statement.Code(),
				Diagnostics.A_class_declaration_without_the_default_modifier_must_have_a_name.Code(),
				Diagnostics.A_class_member_cannot_have_the_0_keyword.Code(),
				Diagnostics.A_comma_expression_is_not_allowed_in_a_computed_property_name.Code(),
				Diagnostics.A_continue_statement_can_only_be_used_within_an_enclosing_iteration_statement.Code(),
				Diagnostics.A_continue_statement_can_only_jump_to_a_label_of_an_enclosing_iteration_statement.Code(),
				Diagnostics.A_default_clause_cannot_appear_more_than_once_in_a_switch_statement.Code(),
				Diagnostics.A_default_export_must_be_at_the_top_level_of_a_file_or_module_declaration.Code(),
				Diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context.Code(),
				Diagnostics.A_destructuring_declaration_must_have_an_initializer.Code(),
				Diagnostics.A_get_accessor_cannot_have_parameters.Code(),
				Diagnostics.A_rest_element_cannot_contain_a_binding_pattern.Code(),
				Diagnostics.A_rest_element_cannot_have_a_property_name.Code(),
				Diagnostics.A_rest_element_cannot_have_an_initializer.Code(),
				Diagnostics.A_rest_element_must_be_last_in_a_destructuring_pattern.Code(),
				Diagnostics.A_rest_parameter_cannot_have_an_initializer.Code(),
				Diagnostics.A_rest_parameter_must_be_last_in_a_parameter_list.Code(),
				Diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma.Code(),
				Diagnostics.A_return_statement_cannot_be_used_inside_a_class_static_block.Code(),
				Diagnostics.A_set_accessor_cannot_have_rest_parameter.Code(),
				Diagnostics.A_set_accessor_must_have_exactly_one_parameter.Code(),
				Diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_module.Code(),
				Diagnostics.An_export_declaration_cannot_have_modifiers.Code(),
				Diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module.Code(),
				Diagnostics.An_import_declaration_cannot_have_modifiers.Code(),
				Diagnostics.An_object_member_cannot_be_declared_optional.Code(),
				Diagnostics.Argument_of_dynamic_import_cannot_be_spread_element.Code(),
				Diagnostics.Cannot_assign_to_private_method_0_Private_methods_are_not_writable.Code(),
				Diagnostics.Cannot_redeclare_identifier_0_in_catch_clause.Code(),
				Diagnostics.Catch_clause_variable_cannot_have_an_initializer.Code(),
				Diagnostics.Class_decorators_can_t_be_used_with_static_private_identifier_Consider_removing_the_experimental_decorator.Code(),
				Diagnostics.Classes_can_only_extend_a_single_class.Code(),
				Diagnostics.Classes_may_not_have_a_field_named_constructor.Code(),
				Diagnostics.Did_you_mean_to_use_a_Colon_An_can_only_follow_a_property_name_when_the_containing_object_literal_is_part_of_a_destructuring_pattern.Code(),
				Diagnostics.Duplicate_label_0.Code(),
				Diagnostics.Dynamic_imports_can_only_accept_a_module_specifier_and_an_optional_set_of_attributes_as_arguments.Code(),
				Diagnostics.X_for_await_loops_cannot_be_used_inside_a_class_static_block.Code(),
				Diagnostics.JSX_attributes_must_only_be_assigned_a_non_empty_expression.Code(),
				Diagnostics.JSX_elements_cannot_have_multiple_attributes_with_the_same_name.Code(),
				Diagnostics.JSX_expressions_may_not_use_the_comma_operator_Did_you_mean_to_write_an_array.Code(),
				Diagnostics.JSX_property_access_expressions_cannot_include_JSX_namespace_names.Code(),
				Diagnostics.Jump_target_cannot_cross_function_boundary.Code(),
				Diagnostics.Line_terminator_not_permitted_before_arrow.Code(),
				Diagnostics.Modifiers_cannot_appear_here.Code(),
				Diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_in_statement.Code(),
				Diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_of_statement.Code(),
				Diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies.Code(),
				Diagnostics.Private_identifiers_are_only_allowed_in_class_bodies_and_may_only_be_used_as_part_of_a_class_member_declaration_property_access_or_on_the_left_hand_side_of_an_in_expression.Code(),
				Diagnostics.Property_0_is_not_accessible_outside_class_1_because_it_has_a_private_identifier.Code(),
				Diagnostics.Tagged_template_expressions_are_not_permitted_in_an_optional_chain.Code(),
				Diagnostics.The_left_hand_side_of_a_for_of_statement_may_not_be_async.Code(),
				Diagnostics.The_variable_declaration_of_a_for_in_statement_cannot_have_an_initializer.Code(),
				Diagnostics.The_variable_declaration_of_a_for_of_statement_cannot_have_an_initializer.Code(),
				Diagnostics.Trailing_comma_not_allowed.Code(),
				Diagnostics.Variable_declaration_list_cannot_be_empty.Code(),
				Diagnostics.X_0_and_1_operations_cannot_be_mixed_without_parentheses.Code(),
				Diagnostics.X_0_expected.Code(),
				Diagnostics.X_0_is_not_a_valid_meta_property_for_keyword_1_Did_you_mean_2.Code(),
				Diagnostics.X_0_list_cannot_be_empty.Code(),
				Diagnostics.X_0_modifier_already_seen.Code(),
				Diagnostics.X_0_modifier_cannot_appear_on_a_constructor_declaration.Code(),
				Diagnostics.X_0_modifier_cannot_appear_on_a_module_or_namespace_element.Code(),
				Diagnostics.X_0_modifier_cannot_appear_on_a_parameter.Code(),
				Diagnostics.X_0_modifier_cannot_appear_on_class_elements_of_this_kind.Code(),
				Diagnostics.X_0_modifier_cannot_be_used_here.Code(),
				Diagnostics.X_0_modifier_must_precede_1_modifier.Code(),
				Diagnostics.X_0_declarations_can_only_be_declared_inside_a_block.Code(),
				Diagnostics.X_0_declarations_must_be_initialized.Code(),
				Diagnostics.X_extends_clause_already_seen.Code(),
				Diagnostics.X_let_is_not_allowed_to_be_used_as_a_name_in_let_or_const_declarations.Code(),
				Diagnostics.Class_constructor_may_not_be_a_generator.Code(),
				Diagnostics.Class_constructor_may_not_be_an_accessor.Code(),
				Diagnostics.X_await_expressions_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules.Code(),
				Diagnostics.X_await_using_statements_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules.Code(),
				Diagnostics.Private_field_0_must_be_declared_in_an_enclosing_class.Code(),
				// Type errors
				Diagnostics.This_condition_will_always_return_0_since_JavaScript_compares_objects_by_reference_not_value.Code()
			);
		}
		return _plainJSErrors;
	}

	// --- projectreferencedtsfakinghost.go ---

	static function newProjectReferenceDtsFakingHost(loader:FileLoader):ResolutionHost {
		// Create a new host that will fake the dts files
		final host = new ProjectReferenceDtsFakingHost();
		host.host = loader.opts.Host;
		final vfs = new ProjectReferenceDtsFakingVfs();
		vfs.projectReferenceFileMapper = loader.projectReferenceFileMapper;
		vfs.dtsDirectories = loader.dtsDirectories;
		vfs.knownSymlinks = new KnownSymlinks();
		host.fs = Cachedvfs.From(vfs);
		return host;
	}

	// --- projectreferenceparser.go ---

	static function createProjectReferenceParseTasks(projectReferences:Array<std.String>):Array<ProjectReferenceParseTask> {
		return Core.Map(projectReferences, function(configName:std.String):ProjectReferenceParseTask {
			final t = new ProjectReferenceParseTask();
			t.configName = configName;
			return t;
		});
	}

	// --- host.go ---

	public static function NewCachedFSCompilerHost(currentDirectory:std.String, fs:FS, defaultLibraryPath:std.String, extendedConfigCache:ExtendedConfigCache,
			trace:TraceFunc):CompilerHost {
		return NewCompilerHost(currentDirectory, Cachedvfs.From(fs), defaultLibraryPath, extendedConfigCache, trace);
	}

	public static function NewCompilerHost(currentDirectory:std.String, fs:FS, defaultLibraryPath:std.String, extendedConfigCache:ExtendedConfigCache,
			trace:TraceFunc):CompilerHost {
		if (trace == null) {
			trace = function(msg:Message, args:Array<Any>) {};
		}
		final h = new CompilerHost_();
		@:privateAccess {
			h.currentDirectory = currentDirectory;
			h.fs = fs;
			h.defaultLibraryPath = defaultLibraryPath;
			h.extendedConfigCache = extendedConfigCache;
			h.trace = trace;
		}
		return h;
	}

	// --- port helpers ---

	// PORT: module.PackageId used as a Go map key → String key.
	static function packageIdKey(id:PackageId):std.String {
		return id.Name + "\x00" + id.SubModuleName + "\x00" + id.Version + "\x00" + id.PeerDependencies;
	}

	// PORT: maps.EqualFunc for StringMap (nil and empty are equal, like Go).
	static function stringMapEqualFunc<V>(m1:StringMap<V>, m2:StringMap<V>, eq:(V, V) -> Bool):Bool {
		final n1 = m1 == null ? 0 : Lambda.count(m1);
		final n2 = m2 == null ? 0 : Lambda.count(m2);
		if (n1 != n2)
			return false;
		if (m1 == null)
			return true;
		for (k => v1 in m1) {
			if (!m2.exists(k))
				return false;
			if (!eq(v1, m2.get(k)))
				return false;
		}
		return true;
	}

	// PORT: json.Marshal of a Go string: Go quoting plus the default HTML escaping of <, >, & and U+2028/U+2029.
	static function jsonMarshalString(s:std.String):std.String {
		final q = ts.json.Json.Quote(s);
		final b = new StringBuf();
		var start = 0;
		for (i in 0...q.length) {
			final c = StringTools.fastCodeAt(q, i);
			final rep = switch (c) {
				case "<".code: "\\u003c";
				case ">".code: "\\u003e";
				case "&".code: "\\u0026";
				case 0x2028: "\\u2028";
				case 0x2029: "\\u2029";
				default: null;
			}
			if (rep != null) {
				b.add(q.substring(start, i));
				b.add(rep);
				start = i + 1;
			}
		}
		b.add(q.substring(start));
		return b.toString();
	}
}
