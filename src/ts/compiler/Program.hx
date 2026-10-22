package ts.compiler;

import ts.diagnostics.Diagnostics.Message;

// Port of program.go (types and methods; the package-level funcs are in Compiler.hx).

class ProgramOptions {
	public var Host:CompilerHost = null;
	public var Config:ParsedCommandLine = null;
	public var UseSourceOfProjectReference:Bool = false;
	public var SingleThreaded:Tristate = TSUnknown;
	public var CreateCheckerPool:(Program) -> CheckerPool = null;
	public var TypingsLocation:std.String = "";
	public var ProjectName:std.String = "";
	public var Tracing:Tracing = null;

	public function new() {}

	// PORT: Go value struct; copy before mutating a copy (PORTING.md §3).
	public function copy():ProgramOptions {
		final r = new ProgramOptions();
		r.Host = Host;
		r.Config = Config;
		r.UseSourceOfProjectReference = UseSourceOfProjectReference;
		r.SingleThreaded = SingleThreaded;
		r.CreateCheckerPool = CreateCheckerPool;
		r.TypingsLocation = TypingsLocation;
		r.ProjectName = ProjectName;
		r.Tracing = Tracing;
		return r;
	}

	@:allow(ts.compiler)
	function canUseProjectReferenceSource():Bool {
		return this.UseSourceOfProjectReference && !this.Config.CompilerOptions().DisableSourceOfProjectReferenceRedirect.IsTrue();
	}
}

// Go type lazyValue[T].
// PORT: sync.Once and atomic.Bool → plain fields (single-threaded).
@:allow(ts.compiler)
class LazyValue<T> {
	var value:T = null;
	var once:Bool = false;
	var initialized:Bool = false;

	public function new() {}

	function getValue(compute:() -> T):T {
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!this.once) {
			this.once = true;
			if (this.value == null) {
				this.value = compute();
			}
			this.initialized = true;
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return this.value;
	}

	function tryReuse(from:LazyValue<T>):Void {
		if (from.initialized) {
			this.value = from.value;
			this.initialized = true;
		}
	}
}

@:allow(ts.compiler)
class PackageNamesInfo {
	var resolved:Set<std.String> = null;
	var unresolved:Set<std.String> = null;
	var deepImportPackages:Set<std.String> = null;

	public function new(resolved:Set<std.String>, unresolved:Set<std.String>, deepImportPackages:Set<std.String>) {
		this.resolved = resolved;
		this.unresolved = unresolved;
		this.deepImportPackages = deepImportPackages;
	}
}

@:allow(ts.compiler)
class Program implements ts.checker.Checker.Program implements ProgramLike implements SourceFileMayBeEmittedHost implements OutputPathsHost {
	var opts:ProgramOptions = null;
	var checkerPool:CheckerPool = null; // always set; used as fallback for project system pools

	// compilerCheckerPool is set only when the built-in compiler checker pool is in use
	// (i.e. CreateCheckerPool was not provided). It enables grouped parallel iteration,
	// non-exclusive access for emit, and direct global diagnostics collection.
	var compilerCheckerPool:CheckerPool_ = null;

	var comparePathsOptions:ComparePathsOptions = new ComparePathsOptions();

	// PORT: embedded struct processedFiles → composition field; the promoted fields are forwarded below.
	var processedFiles:ProcessedFiles = new ProcessedFiles();

	var usesUriStyleNodeCoreModules:Tristate = TSUnknown;

	var commonSourceDirectory:std.String = "";
	var commonSourceDirectoryOnce:Bool = false; // PORT: sync.Once → flag

	var declarationDiagnosticCache:IdentityMap<SourceFile, Array<Diagnostic>> = new IdentityMap(); // PORT: SyncMap → IdentityMap

	var programDiagnostics:Array<Diagnostic> = null;
	var hasEmitBlockingDiagnostics:Set<Path> = new Set<Path>();

	var sourceFilesToEmitOnce:Bool = false; // PORT: sync.Once → flag
	var sourceFilesToEmit:Array<SourceFile> = null;

	// Cached unresolved imports for ATA
	var unresolvedImports:LazyValue<Set<std.String>> = new LazyValue();
	var knownSymlinks:LazyValue<KnownSymlinks> = new LazyValue();

	// Used by auto-imports
	var packageNames:LazyValue<PackageNamesInfo> = new LazyValue();

	// Used by workspace/symbol
	var hasTSFileOnce:Bool = false;
	var hasTSFile:Bool = false;

	// Cached map of package names to whether they bundle types
	var packagesMapOnce:Bool = false;
	var packagesMap:StringMap<Bool> = null;

	public function new() {}

	// --- forwarding properties for the embedded processedFiles ---
	var resolver(get, never):Resolver;

	inline function get_resolver()
		return processedFiles.resolver;

	var files(get, set):Array<SourceFile>;

	inline function get_files()
		return processedFiles.files;

	inline function set_files(v)
		return processedFiles.files = v;

	var duplicateSourceFiles(get, never):Array<DuplicateSourceFile>;

	inline function get_duplicateSourceFiles()
		return processedFiles.duplicateSourceFiles;

	var filesByPath(get, set):StringMap<SourceFile>;

	inline function get_filesByPath()
		return processedFiles.filesByPath;

	inline function set_filesByPath(v)
		return processedFiles.filesByPath = v;

	var projectReferenceFileMapper(get, never):ProjectReferenceFileMapper;

	inline function get_projectReferenceFileMapper()
		return processedFiles.projectReferenceFileMapper;

	var missingFiles(get, never):Array<std.String>;

	inline function get_missingFiles()
		return processedFiles.missingFiles;

	var resolvedModules(get, never):StringMap<ModeAwareCache<ResolvedModule>>;

	inline function get_resolvedModules()
		return processedFiles.resolvedModules;

	var typeResolutionsInFile(get, never):StringMap<ModeAwareCache<ResolvedTypeReferenceDirective>>;

	inline function get_typeResolutionsInFile()
		return processedFiles.typeResolutionsInFile;

	var sourceFileMetaDatas(get, never):StringMap<SourceFileMetaData>;

	inline function get_sourceFileMetaDatas()
		return processedFiles.sourceFileMetaDatas;

	var jsxRuntimeImportSpecifiers(get, never):StringMap<JsxRuntimeImportSpecifier>;

	inline function get_jsxRuntimeImportSpecifiers()
		return processedFiles.jsxRuntimeImportSpecifiers;

	var importHelpersImportSpecifiers(get, never):StringMap<Node>;

	inline function get_importHelpersImportSpecifiers()
		return processedFiles.importHelpersImportSpecifiers;

	var libFiles(get, never):StringMap<LibFile>;

	inline function get_libFiles()
		return processedFiles.libFiles;

	var sourceFilesFoundSearchingNodeModules(get, never):Set<Path>;

	inline function get_sourceFilesFoundSearchingNodeModules()
		return processedFiles.sourceFilesFoundSearchingNodeModules;

	var includeProcessor(get, set):IncludeProcessor;

	inline function get_includeProcessor()
		return processedFiles.includeProcessor;

	inline function set_includeProcessor(v)
		return processedFiles.includeProcessor = v;

	var outputFileToProjectReferenceSource(get, never):StringMap<std.String>;

	inline function get_outputFileToProjectReferenceSource()
		return processedFiles.outputFileToProjectReferenceSource;

	var redirectTargetsMap(get, never):StringMap<Array<std.String>>;

	inline function get_redirectTargetsMap()
		return processedFiles.redirectTargetsMap;

	var redirectFilesByPath(get, never):StringMap<RedirectsFile>;

	inline function get_redirectFilesByPath()
		return processedFiles.redirectFilesByPath;

	var finishedProcessing(get, never):Bool;

	inline function get_finishedProcessing()
		return processedFiles.finishedProcessing;

	// --- end forwarding properties ---

	// FileExists implements checker.Program.
	public function FileExists(path:std.String):Bool {
		return this.Host().FS().FileExists(path);
	}

	// GetCurrentDirectory implements checker.Program.
	public function GetCurrentDirectory():std.String {
		return this.Host().GetCurrentDirectory();
	}

	// GetGlobalTypingsCacheLocation implements checker.Program.
	public function GetGlobalTypingsCacheLocation():std.String {
		return this.opts.TypingsLocation;
	}

	// GetNearestAncestorDirectoryWithPackageJson implements checker.Program.
	public function GetNearestAncestorDirectoryWithPackageJson(dirname:std.String):std.String {
		final scoped = this.resolver.GetPackageScopeForPath(dirname);
		if (scoped != null && scoped.Exists()) {
			return scoped.PackageDirectory;
		}
		return "";
	}

	// GetPackageJsonInfo implements checker.Program.
	public function GetPackageJsonInfo(pkgJsonPath:std.String):InfoCacheEntry {
		final directory = Tspath.GetDirectoryPath(pkgJsonPath);
		final scoped = this.resolver.GetPackageScopeForPath(directory);
		if (scoped != null && scoped.Exists() && scoped.PackageDirectory == directory) {
			return scoped;
		}
		return null;
	}

	// PackageJsonCacheEntries iterates on all package json cache entries.
	public function PackageJsonCacheEntries(f:(key:Path, value:InfoCacheEntry) -> Bool):Void {
		this.resolver.PackageJsonCacheEntries(f);
	}

	// GetRedirectTargets returns the list of file paths that redirect to the given path.
	// These are files from the same package (same name@version) installed in different locations.
	public function GetRedirectTargets(path:Path):Array<std.String> {
		return this.redirectTargetsMap == null ? null : this.redirectTargetsMap.get(path);
	}

	// gets the original file that was included in program
	// this returns original source file name when including output of project reference
	// otherwise same name
	// Equivalent to originalFileName on SourceFile in Strada
	public function GetSourceOfProjectReferenceIfOutputIncluded(file:HasFileName):std.String {
		if (this.outputFileToProjectReferenceSource != null && this.outputFileToProjectReferenceSource.exists(file.Path())) {
			return this.outputFileToProjectReferenceSource.get(file.Path());
		}
		return file.FileName();
	}

	// GetProjectReferenceFromSource implements checker.Program.
	public function GetProjectReferenceFromSource(path:Path):SourceOutputAndProjectReference {
		return this.projectReferenceFileMapper.getProjectReferenceFromSource(path);
	}

	// IsSourceFromProjectReference implements checker.Program.
	public function IsSourceFromProjectReference(path:Path):Bool {
		return this.projectReferenceFileMapper.isSourceFromProjectReference(path);
	}

	public function GetProjectReferenceFromOutputDts(path:Path):SourceOutputAndProjectReference {
		return this.projectReferenceFileMapper.getProjectReferenceFromOutputDts(path);
	}

	// PORT: (*tsoptions.ParsedCommandLine, bool) → ValueOk
	public function GetResolvedProjectReferenceFor(path:Path):ValueOk<ParsedCommandLine> {
		return this.projectReferenceFileMapper.getResolvedReferenceFor(path);
	}

	public function GetRedirectForResolution(file:HasFileName):ParsedCommandLine {
		final redirect = this.projectReferenceFileMapper.getRedirectForResolution(file).a;
		return redirect;
	}

	public function GetParseFileRedirect(fileName:std.String):std.String {
		return this.projectReferenceFileMapper.getParseFileRedirect(Ast.NewHasFileName(fileName, this.toPath(fileName)));
	}

	public function GetResolvedProjectReferences():Array<ParsedCommandLine> {
		return this.projectReferenceFileMapper.getResolvedProjectReferences();
	}

	public function RangeResolvedProjectReference(f:(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int) -> Bool):Bool {
		return this.projectReferenceFileMapper.rangeResolvedProjectReference(f);
	}

	public function RangeResolvedProjectReferenceInChildConfig(childConfig:ParsedCommandLine,
			f:(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int) -> Bool):Bool {
		return this.projectReferenceFileMapper.rangeResolvedProjectReferenceInChildConfig(childConfig, f);
	}

	// UseCaseSensitiveFileNames implements checker.Program.
	public function UseCaseSensitiveFileNames():Bool {
		return this.Host().FS().UseCaseSensitiveFileNames();
	}

	public function UsesUriStyleNodeCoreModules():Tristate {
		return this.usesUriStyleNodeCoreModules;
	}

	/** This should have similar behavior to 'processSourceFile' without diagnostics or mutation. */
	public function GetSourceFileFromReference(origin:SourceFile, ref:FileReference):SourceFile {
		// TODO: The module loader in corsa is fairly different than strada, it should probably be able to expose this functionality at some point,
		// rather than redoing the logic approximately here, since most of the related logic now lives in module.Resolver
		// Still, without the failed lookup reporting that only the loader does, this isn't terribly complicated

		final fileName = Tspath.ResolvePath(Tspath.GetDirectoryPath(origin.FileName()), ref.FileName);
		final supportedExtensionsBase = Tsoptions.GetSupportedExtensions(this.Options(), null /*extraFileExtensions*/);
		final supportedExtensions = Tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(this.Options(), supportedExtensionsBase);
		final allowNonTsExtensions = this.Options().AllowNonTsExtensions.IsTrue();
		if (Tspath.HasExtension(fileName)) {
			if (!allowNonTsExtensions) {
				final canonicalFileName = Tspath.GetCanonicalFileName(fileName, this.UseCaseSensitiveFileNames());
				var supported = false;
				for (group in supportedExtensions) {
					if (Tspath.FileExtensionIsOneOf(canonicalFileName, group)) {
						supported = true;
						break;
					}
				}
				if (!supported) {
					return null; // unsupported extensions are forced to fail
				}
			}

			return this.GetSourceFileForResolvedModule(fileName);
		}
		if (allowNonTsExtensions) {
			final extensionless = this.GetSourceFileForResolvedModule(fileName);
			if (extensionless != null) {
				return extensionless;
			}
		}

		// Only try adding extensions from the first supported group (which should be .ts/.tsx/.d.ts)
		for (ext in supportedExtensions[0]) {
			final result = this.GetSourceFileForResolvedModule(fileName + ext);
			if (result != null) {
				return result;
			}
		}
		return null;
	}

	// Return an updated program for which it is known that only the file with the given path has changed.
	// In addition to a new program, return a boolean indicating whether the data of the old program was reused.
	// createCheckerPool, if non-nil, overrides the CreateCheckerPool stored in the old program's options,
	// ensuring each caller uses a fresh closure and avoiding data races on captured variables.
	// The returned *ast.SourceFile is the changed file as acquired through newHost; it is nil
	// only if the host cannot locate the file (e.g. it was deleted). Callers that manage
	// host-side parse caches must release this exact pointer when the old program could not be
	// reused, since it was acquired speculatively before that decision was made.
	// PORT: (*Program, *ast.SourceFile, bool) → Triple
	public function UpdateProgram(changedFilePath:Path, newHost:CompilerHost, createCheckerPool:(Program) -> CheckerPool):Triple<Program, SourceFile, Bool> {
		final newOpts = this.opts.copy();
		newOpts.Host = newHost;
		if (createCheckerPool != null) {
			newOpts.CreateCheckerPool = createCheckerPool;
		}

		final oldFile = this.filesByPath.get(changedFilePath);
		final newFile = newHost.GetSourceFile(oldFile.ParseOptions());

		// If this file is part of a package redirect group (same package installed in multiple
		// node_modules locations), we need to rebuild the program because the redirect targets
		// might need recalculation.
		final inRedirectFiles = this.redirectFilesByPath != null && this.redirectFilesByPath.exists(changedFilePath);
		final isRedirectTarget = this.redirectTargetsMap != null && this.redirectTargetsMap.exists(changedFilePath);
		if (inRedirectFiles || isRedirectTarget) {
			return new Triple(Compiler.NewProgram(newOpts), newFile, false);
		}

		if (!Compiler.canReplaceFileInProgram(oldFile, newFile)) {
			return new Triple(Compiler.NewProgram(newOpts), newFile, false);
		}
		final oldNeedsImportHelpers = this.importHelpersImportSpecifiers != null && this.importHelpersImportSpecifiers.get(oldFile.Path()) != null;
		if (oldNeedsImportHelpers != this.needsImportHelpersImportSpecifier(newFile)) {
			return new Triple(Compiler.NewProgram(newOpts), newFile, false);
		}
		// TODO: reverify compiler options when config has changed?
		final result = new Program();
		result.opts = newOpts;
		result.comparePathsOptions = this.comparePathsOptions;
		result.processedFiles = this.processedFiles.copy();
		result.usesUriStyleNodeCoreModules = this.usesUriStyleNodeCoreModules;
		result.programDiagnostics = this.programDiagnostics;
		result.hasEmitBlockingDiagnostics = this.hasEmitBlockingDiagnostics;
		result.unresolvedImports.tryReuse(this.unresolvedImports);
		result.knownSymlinks.tryReuse(this.knownSymlinks);
		result.packageNames.tryReuse(this.packageNames);
		result.initCheckerPool();
		final index = Core.FindIndex(result.files, function(file:SourceFile) return file.Path() == newFile.Path());
		result.files = Slices.Clone(result.files);
		result.files[index] = newFile;
		result.filesByPath = result.filesByPath.copy();
		result.filesByPath.set(newFile.Path(), newFile);
		Compiler.updateFileIncludeProcessor(result);
		return new Triple(result, newFile, true);
	}

	function initCheckerPool():Void {
		if (!this.finishedProcessing) {
			throw "Program must finish processing files before initializing checker pool";
		}

		if (this.opts.CreateCheckerPool != null) {
			this.checkerPool = this.opts.CreateCheckerPool(this);
		} else {
			final pool = Compiler.newCheckerPoolWithTracing(this, this.opts.Tracing);
			this.checkerPool = pool;
			this.compilerCheckerPool = pool;
		}
	}

	// GetCheckerPool returns the checker pool associated with this program.
	public function GetCheckerPool():CheckerPool {
		return this.checkerPool;
	}

	function needsImportHelpersImportSpecifier(file:SourceFile):Bool {
		final redirect = this.projectReferenceFileMapper.getRedirectForResolution(ts.modulespecifiers.Types.SourceFileAdapter.Of(file)).a;
		final optionsForFile = Module.GetCompilerOptionsWithRedirect(this.opts.Config.CompilerOptions(), redirect);
		if (!optionsForFile.ImportHelpers.IsTrue()) {
			return false;
		}
		final isJavaScriptFile = Ast.IsSourceFileJS(file);
		final isExternalModuleFile = Ast.IsExternalModule(file);
		if (!isJavaScriptFile && (file.IsDeclarationFile || (!optionsForFile.GetIsolatedModules() && !isExternalModuleFile))) {
			return false;
		}
		return true;
	}

	public function SourceFiles():Array<SourceFile> {
		return this.files;
	}

	public function DuplicateSourceFiles():Array<DuplicateSourceFile> {
		return this.duplicateSourceFiles;
	}

	public function Options():CompilerOptions {
		return this.opts.Config.CompilerOptions();
	}

	public function CommandLine():ParsedCommandLine {
		return this.opts.Config;
	}

	public function Host():CompilerHost {
		return this.opts.Host;
	}

	public function Tracing():Tracing {
		return this.opts.Tracing;
	}

	// PORT: slices.Clip (callers append to the result) → a copy (Haxe push would modify the shared array).
	public function GetConfigFileParsingDiagnostics():Array<Diagnostic> {
		return Slices.Clone(this.opts.Config.GetConfigFileParsingDiagnostics());
	}

	// GetUnresolvedImports returns the unresolved imports for this program.
	// The result is cached and computed only once.
	public function GetUnresolvedImports():Set<std.String> {
		return this.unresolvedImports.getValue(this.extractUnresolvedImports);
	}

	function extractUnresolvedImports():Set<std.String> {
		final unresolvedSet = new Set<std.String>();

		for (sourceFile in this.files) {
			final unresolvedImports = this.extractUnresolvedImportsFromSourceFile(sourceFile);
			if (unresolvedImports != null) {
				for (imp in unresolvedImports) {
					unresolvedSet.Add(imp);
				}
			}
		}

		return unresolvedSet;
	}

	function extractUnresolvedImportsFromSourceFile(file:SourceFile):Array<std.String> {
		var unresolvedImports:Array<std.String> = null;

		final resolvedModules = this.resolvedModules.get(file.Path());
		if (resolvedModules != null) {
			for (key => resolution in resolvedModules) {
				final cacheKey = ModeAwareCacheKey.ModeAwareCacheKeyFromKey(key);
				final resolved = resolution.IsResolved();
				if ((!resolved || !Tspath.ExtensionIsOneOf(resolution.Extension, Tspath.SupportedTSExtensionsWithJsonFlat))
					&& !Tspath.IsExternalModuleNameRelative(cacheKey.Name)) {
					if (unresolvedImports == null)
						unresolvedImports = [];
					unresolvedImports.push(cacheKey.Name);
				}
			}
		}

		return unresolvedImports;
	}

	public function SingleThreaded():Bool {
		return this.opts.SingleThreaded.DefaultIfUnknown(this.Options().SingleThreaded).IsTrue();
	}

	public function BindSourceFiles():Void {
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — the files are bound on threads, as in Go
		final wg:WorkGroup = this.SingleThreaded() ? Core.NewWorkGroup(true) : new ParallelWorkGroup();
		#else
		final wg = Core.NewWorkGroup(this.SingleThreaded());
		#end
		for (file in this.files) {
			if (!file.IsBound()) {
				wg.Queue(function() {
					var done:() -> Void = null;
					if (this.opts.Tracing != null) {
						final args = new StringMap<Any>();
						args.set("path", (file.Path() : std.String));
						done = this.opts.Tracing.Push(PhaseBind, "bindSourceFile", args, true);
					}
					try {
						Binder.BindSourceFile(file);
					} catch (e:Dynamic) {
						if (done != null)
							done();
						throw e;
					}
					if (done != null)
						done();
				});
			}
		}
		wg.RunAndWait();
	}

	// Return the type checker associated with the program.
	// PORT: (*checker.Checker, func()) → Pair
	public function GetTypeChecker(ctx:Context):Pair<Checker, () -> Void> {
		if (this.compilerCheckerPool != null) {
			return this.compilerCheckerPool.getCheckerNonExclusive();
		}
		return this.checkerPool.GetChecker(ctx, null);
	}

	public function ForEachCheckerParallel(cb:(idx:Int, c:Checker) -> Void):Void {
		if (this.compilerCheckerPool != null) {
			this.compilerCheckerPool.forEachCheckerParallel(cb);
		}
	}

	// Return a checker for the given file. We may have multiple checkers in concurrent scenarios and this
	// method returns the checker that was tasked with checking the file. Note that it isn't possible to mix
	// types obtained from different checkers, so only non-type data (such as diagnostics or string
	// representations of types) should be obtained from checkers returned by this method.
	public function GetTypeCheckerForFile(ctx:Context, file:SourceFile):Pair<Checker, () -> Void> {
		if (this.compilerCheckerPool != null) {
			return this.compilerCheckerPool.getCheckerForFileNonExclusive(file);
		}
		return this.checkerPool.GetChecker(ctx, file);
	}

	// Return a checker for the given file, locked to the current thread to prevent data races from multiple threads
	// accessing the same checker. The lock will be released when the `done` function is called.
	public function GetTypeCheckerForFileExclusive(ctx:Context, file:SourceFile):Pair<Checker, () -> Void> {
		if (this.compilerCheckerPool != null) {
			return this.compilerCheckerPool.getCheckerForFileExclusive(ctx, file);
		}
		return this.checkerPool.GetChecker(ctx, file);
	}

	public function GetResolvedModule(file:HasFileName, moduleReference:std.String, mode:ResolutionMode):ResolvedModule {
		final resolutions = this.resolvedModules.get(file.Path());
		if (resolutions != null) {
			final key = new ModeAwareCacheKey(moduleReference, mode).Key();
			if (resolutions.exists(key)) {
				return resolutions.get(key);
			}
		}
		return null;
	}

	public function GetResolvedModuleFromModuleSpecifier(file:HasFileName, moduleSpecifier:StringLiteralLike):ResolvedModule {
		if (!Ast.IsStringLiteralLike(moduleSpecifier)) {
			throw "moduleSpecifier must be a StringLiteralLike";
		}
		final mode = this.GetModeForUsageLocation(file, moduleSpecifier);
		return this.GetResolvedModule(file, moduleSpecifier.Text(), mode);
	}

	public function GetResolvedModules():StringMap<ModeAwareCache<ResolvedModule>> {
		return this.resolvedModules;
	}

	// GetPackagesMap returns a lazily-cached map of package names to whether they bundle types.
	// This is used by incremental diagnostic repopulation.
	public function GetPackagesMap():StringMap<Bool> {
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!this.packagesMapOnce) {
			this.packagesMapOnce = true;
			this.packagesMap = new StringMap();
			for (resolvedModulesInFile in this.resolvedModules) {
				if (resolvedModulesInFile == null)
					continue;
				for (mod in resolvedModulesInFile) {
					if (mod.PackageId.Name != "") {
						final prev = this.packagesMap.get(mod.PackageId.Name);
						this.packagesMap.set(mod.PackageId.Name, (prev != null && prev) || mod.Extension == Tspath.ExtensionDts);
					}
				}
			}
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return this.packagesMap;
	}

	// collectDiagnostics collects diagnostics from a single file or all files.
	// If sourceFile is non-nil, returns diagnostics for just that file.
	// If sourceFile is nil, returns diagnostics for all files in the program.
	function collectDiagnostics(ctx:Context, sourceFile:SourceFile, concurrent:Bool, collect:(Context, SourceFile) -> Array<Diagnostic>):Array<Diagnostic> {
		var result:Array<Diagnostic>;
		if (sourceFile != null) {
			result = collect(ctx, sourceFile);
		} else {
			final diagnostics = this.collectDiagnosticsFromFiles(ctx, this.files, concurrent, collect);
			result = Slices.Concat(...diagnostics);
		}
		return Compiler.SortAndDeduplicateDiagnostics(result);
	}

	function collectDiagnosticsFromFiles(ctx:Context, sourceFiles:Array<SourceFile>, concurrent:Bool,
			collect:(Context, SourceFile) -> Array<Diagnostic>):Array<Array<Diagnostic>> {
		final diagnostics:Array<Array<Diagnostic>> = [for (_ in 0...sourceFiles.length) null];
		final wg = Core.NewWorkGroup(!concurrent || this.SingleThreaded());
		for (i in 0...sourceFiles.length) {
			final file = sourceFiles[i];
			wg.Queue(function() {
				diagnostics[i] = collect(ctx, file);
			});
		}
		wg.RunAndWait();
		return diagnostics;
	}

	// collectCheckerDiagnostics collects diagnostics from a single file or all files,
	// using a callback that receives the checker for each file. When the checker pool
	// supports grouped iteration (compiler pool), files are grouped by checker and
	// processed in parallel with one task per checker, reducing contention and improving
	// cache locality. Otherwise, falls back to per-file concurrent collection.
	function collectCheckerDiagnostics(ctx:Context, sourceFile:SourceFile, collect:(Context, Checker, SourceFile) -> Array<Diagnostic>):Array<Diagnostic> {
		if (sourceFile != null) {
			if (this.SkipTypeChecking(sourceFile, false)) {
				return null;
			}
			final r = this.GetTypeCheckerForFileExclusive(ctx, sourceFile);
			final c = r.a, done = r.b;
			final result = collect(ctx, c, sourceFile);
			done();
			return Compiler.SortAndDeduplicateDiagnostics(result);
		}
		return Compiler.SortAndDeduplicateDiagnostics(Slices.Concat(...this.collectCheckerDiagnosticsFromFiles(ctx, this.files, collect)));
	}

	// collectCheckerDiagnosticsFromFiles collects checker diagnostics for a list of files.
	function collectCheckerDiagnosticsFromFiles(ctx:Context, sourceFiles:Array<SourceFile>,
			collect:(Context, Checker, SourceFile) -> Array<Diagnostic>):Array<Array<Diagnostic>> {
		final diagnostics:Array<Array<Diagnostic>> = [for (_ in 0...sourceFiles.length) null];
		if (this.compilerCheckerPool != null) {
			this.compilerCheckerPool.forEachCheckerGroupDo(ctx, sourceFiles, this.SingleThreaded(), function(c:Checker, fileIndex:Int, file:SourceFile) {
				diagnostics[fileIndex] = collect(ctx, c, file);
			});
		} else {
			final wg = Core.NewWorkGroup(this.SingleThreaded());
			for (i in 0...sourceFiles.length) {
				final file = sourceFiles[i];
				if (this.SkipTypeChecking(file, false)) {
					continue;
				}
				wg.Queue(function() {
					final r = this.checkerPool.GetChecker(ctx, file);
					diagnostics[i] = collect(ctx, r.a, file);
					r.b();
				});
			}
			wg.RunAndWait();
		}
		return diagnostics;
	}

	public function GetSyntacticDiagnostics(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		return this.collectDiagnostics(ctx, sourceFile, false /*concurrent*/, function(_:Context, file:SourceFile):Array<Diagnostic> {
			var diags = Core.Concatenate(file.Diagnostics(), file.JSDiagnostics());
			// For JS files that won't be checked by the checker (no checkJs/ts-check), we need
			// program-level syntactic checks that require compiler options. This mirrors Strada's
			// getJSSyntacticDiagnosticsForFile in program.ts.
			if (Ast.IsSourceFileJS(file) && !Ast.IsCheckJSEnabledForFile(file, this.Options())) {
				final extra = Compiler.getAdditionalJSSyntacticDiagnostics(file, this.Options());
				if (extra != null && extra.length > 0) {
					// PORT: append may write into the parser's array (Concatenate can return it): copy first.
					diags = diags == null ? [] : diags.copy();
					for (d in extra)
						diags.push(d);
				}
			}
			return diags;
		});
	}

	public function GetBindDiagnostics(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		if (sourceFile != null) {
			Binder.BindSourceFile(sourceFile);
		} else {
			this.BindSourceFiles();
		}
		return this.collectDiagnostics(ctx, sourceFile, false /*concurrent*/, function(_:Context, file:SourceFile):Array<Diagnostic> {
			return file.BindDiagnostics();
		});
	}

	public function GetSemanticDiagnostics(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		return this.collectCheckerDiagnostics(ctx, sourceFile, this.getSemanticDiagnosticsWithChecker);
	}

	public function GetSemanticDiagnosticsWithoutNoEmitFiltering(ctx:Context, sourceFiles:Array<SourceFile>):IdentityMap<SourceFile, Array<Diagnostic>> {
		final allDiags = this.collectCheckerDiagnosticsFromFiles(ctx, sourceFiles, this.getBindAndCheckDiagnosticsWithChecker);
		final result = new IdentityMap<SourceFile, Array<Diagnostic>>();
		for (i in 0...allDiags.length) {
			result.set(sourceFiles[i], Compiler.SortAndDeduplicateDiagnostics(allDiags[i]));
		}
		return result;
	}

	public function GetSuggestionDiagnostics(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		return this.collectCheckerDiagnostics(ctx, sourceFile, this.getSuggestionDiagnosticsWithChecker);
	}

	public function GetProgramDiagnostics():Array<Diagnostic> {
		return Compiler.SortAndDeduplicateDiagnostics(Core.Concatenate(this.programDiagnostics, this.includeProcessor.getDiagnostics(this).GetGlobalDiagnostics()));
	}

	public function GetIncludeProcessorDiagnostics(sourceFile:SourceFile):Array<Diagnostic> {
		if (this.SkipTypeChecking(sourceFile, false)) {
			return null;
		}
		final filtered = this.getDiagnosticsWithPrecedingDirectives(sourceFile, this.includeProcessor.getDiagnostics(this).GetDiagnosticsForFile(sourceFile.FileName())).a;
		return filtered;
	}

	public function SkipTypeChecking(sourceFile:SourceFile, ignoreNoCheck:Bool):Bool {
		return (!ignoreNoCheck && this.Options().NoCheck.IsTrue())
			|| this.Options().SkipLibCheck.IsTrue() && sourceFile.IsDeclarationFile
			|| this.Options().SkipDefaultLibCheck.IsTrue() && this.IsSourceFileDefaultLibrary(sourceFile.Path())
			|| this.IsSourceFromProjectReference(sourceFile.Path())
			|| !this.canIncludeBindAndCheckDiagnostics(sourceFile);
	}

	function canIncludeBindAndCheckDiagnostics(sourceFile:SourceFile):Bool {
		if (sourceFile.CheckJsDirective != null && !sourceFile.CheckJsDirective.Enabled) {
			return false;
		}

		if (sourceFile.ScriptKind == ScriptKindTS || sourceFile.ScriptKind == ScriptKindTSX || sourceFile.ScriptKind == ScriptKindExternal) {
			return true;
		}

		final isJS = sourceFile.ScriptKind == ScriptKindJS || sourceFile.ScriptKind == ScriptKindJSX;
		final isCheckJS = isJS && Ast.IsCheckJSEnabledForFile(sourceFile, this.Options());
		final isPlainJS = Ast.IsPlainJSFile(sourceFile, this.Options().CheckJs);

		// By default, only type-check .ts, .tsx, Deferred, plain JS, checked JS and External
		// - plain JS: .js files with no // ts-check and checkJs: undefined
		// - check JS: .js files with either // ts-check or checkJs: true
		// - external: files that are added by plugins
		return isPlainJS || isCheckJS || sourceFile.ScriptKind == ScriptKindDeferred;
	}

	function getSourceFilesToEmit(targetSourceFile:SourceFile, forceDtsEmit:Bool):Array<SourceFile> {
		if (targetSourceFile == null && !forceDtsEmit) {
			#if tshx_parallel
			go.Par.onceMutex.acquire();
			#end
			if (!this.sourceFilesToEmitOnce) {
				this.sourceFilesToEmitOnce = true;
				this.sourceFilesToEmit = Compiler.getSourceFilesToEmit(this, null, false);
			}
			#if tshx_parallel
			go.Par.onceMutex.release();
			#end
			return this.sourceFilesToEmit;
		}
		return Compiler.getSourceFilesToEmit(this, targetSourceFile, forceDtsEmit);
	}

	function verifyCompilerOptions():Void {
		final options = this.Options();

		final sourceFile = Core.Memoize(function():SourceFile {
			final configFile = this.opts.Config.ConfigFile;
			if (configFile == null) {
				return null;
			}
			return configFile.SourceFile;
		});

		final configFilePath = Core.Memoize(function():std.String {
			final file = sourceFile();
			if (file != null) {
				return file.FileName();
			}
			return "";
		});

		final getCompilerOptionsPropertySyntax = Core.Memoize(function():PropertyAssignment {
			return Tsoptions.ForEachTsConfigPropArray(sourceFile(), "compilerOptions", Core.Identity);
		});

		final getCompilerOptionsObjectLiteralSyntax = Core.Memoize(function():ObjectLiteralExpression {
			final compilerOptionsProperty = getCompilerOptionsPropertySyntax();
			if (compilerOptionsProperty != null
				&& compilerOptionsProperty.Initializer != null
				&& Ast.IsObjectLiteralExpression(compilerOptionsProperty.Initializer)) {
				return compilerOptionsProperty.Initializer.AsObjectLiteralExpression();
			}
			return null;
		});

		final createOptionDiagnosticInObjectLiteralSyntax = function(objectLiteral:ObjectLiteralExpression, onKey:Bool, key1:std.String, key2:std.String,
				message:Message, args:Array<Any>):Diagnostic {
			final diag = Tsoptions.ForEachPropertyAssignment(objectLiteral, key1, function(property:PropertyAssignment):Diagnostic {
				return Tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), Core.IfElse(onKey, property.Name(), property.Initializer), message, ...args);
			}, key2);
			if (diag != null) {
				this.appendProgramDiagnostic(diag);
			}
			return diag;
		};

		final createCompilerOptionsDiagnostic = function(message:Message, args:Array<Any>):Diagnostic {
			final compilerOptionsProperty = getCompilerOptionsPropertySyntax();
			var diag:Diagnostic;
			if (compilerOptionsProperty != null) {
				diag = Tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), compilerOptionsProperty.Name(), message, ...args);
			} else {
				diag = Ast.NewCompilerDiagnostic(message, ...args);
			}
			this.appendProgramDiagnostic(diag);
			return diag;
		};

		final createDiagnosticForOption = function(onKey:Bool, option1:std.String, option2:std.String, message:Message, args:Array<Any>):Diagnostic {
			var diag = createOptionDiagnosticInObjectLiteralSyntax(getCompilerOptionsObjectLiteralSyntax(), onKey, option1, option2, message, args);
			if (diag == null) {
				diag = createCompilerOptionsDiagnostic(message, args);
			}
			return diag;
		};

		final createDiagnosticForOptionName = function(message:Message, option1:std.String, option2:std.String, args:Array<Any>) {
			final newArgs:Array<Any> = [option1, option2];
			for (a in args)
				newArgs.push(a);
			createDiagnosticForOption(true /*onKey*/, option1, option2, message, newArgs);
		};

		final createOptionValueDiagnostic = function(option1:std.String, message:Message, args:Array<Any>) {
			createDiagnosticForOption(false /*onKey*/, option1, "", message, args);
		};

		final createRemovedOptionDiagnostic = function(name:std.String, value:std.String, useInstead:std.String) {
			var message:Message;
			var args:Array<Any>;
			if (value == "") {
				message = Diagnostics.Option_0_has_been_removed_Please_remove_it_from_your_configuration;
				args = [name];
			} else {
				message = Diagnostics.Option_0_1_has_been_removed_Please_remove_it_from_your_configuration;
				args = [name, value];
			}

			final diag = createDiagnosticForOption(value == "", name, "", message, args);
			if (useInstead != "") {
				diag.AddMessageChain(Ast.NewCompilerDiagnostic(Diagnostics.Use_0_instead, useInstead));
			}
		};

		// Removed in TS7

		if (options.BaseUrl != "") {
			// BaseUrl will have been turned absolute by this point.
			var useInstead = "";
			if (configFilePath() != "") {
				var relative = Tspath.GetRelativePathFromFile(configFilePath(), options.BaseUrl, this.comparePathsOptions);
				if (!(StringTools.startsWith(relative, "./") || StringTools.startsWith(relative, "../"))) {
					relative = "./" + relative;
				}
				final suggestion = Tspath.CombinePaths(relative, "*");
				useInstead = Fmt.Sprintf("\"paths\": {\"*\": [%s]}", [Compiler.jsonMarshalString(suggestion)]);
			}
			createRemovedOptionDiagnostic("baseUrl", "", useInstead);
		}

		if (options.OutFile != "") {
			createRemovedOptionDiagnostic("outFile", "", "");
		}

		if (options.Target == ScriptTargetES5) {
			createRemovedOptionDiagnostic("target", "ES5", "");
		}

		if (options.Module == ModuleKindAMD) {
			createRemovedOptionDiagnostic("module", "AMD", "");
		}
		if (options.Module == ModuleKindSystem) {
			createRemovedOptionDiagnostic("module", "System", "");
		}
		if (options.Module == ModuleKindUMD) {
			createRemovedOptionDiagnostic("module", "UMD", "");
		}

		if (options.ModuleResolution == ModuleResolutionKindClassic) {
			createRemovedOptionDiagnostic("moduleResolution", "Classic", "");
		}

		if (options.AlwaysStrict.IsFalse()) {
			createRemovedOptionDiagnostic("alwaysStrict", "false", "");
		}

		if (options.ESModuleInterop.IsFalse()) {
			createRemovedOptionDiagnostic("esModuleInterop", "false", "");
		}

		if (options.AllowSyntheticDefaultImports.IsFalse()) {
			createRemovedOptionDiagnostic("allowSyntheticDefaultImports", "false", "");
		}

		if (options.ModuleResolution == ModuleResolutionKindNode10) {
			createRemovedOptionDiagnostic("moduleResolution", "node10", "");
		}

		if (!options.DownlevelIteration.IsUnknown()) {
			createRemovedOptionDiagnostic("downlevelIteration", "", "");
		}

		if (options.StrictPropertyInitialization.IsTrue() && !options.GetStrictOptionValue(options.StrictNullChecks)) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "strictPropertyInitialization",
				"strictNullChecks", []);
		}
		if (options.ExactOptionalPropertyTypes.IsTrue() && !options.GetStrictOptionValue(options.StrictNullChecks)) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "exactOptionalPropertyTypes", "strictNullChecks",
				[]);
		}

		if (options.IsolatedDeclarations.IsTrue()) {
			if (options.GetAllowJS()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_with_option_1, "allowJs", "isolatedDeclarations", []);
			}
			if (!options.GetEmitDeclarations()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "isolatedDeclarations",
					"declaration", ["composite"]);
			}
		}

		if (options.InlineSourceMap.IsTrue()) {
			if (options.SourceMap.IsTrue()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_with_option_1, "sourceMap", "inlineSourceMap", []);
			}
			if (options.MapRoot != "") {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_with_option_1, "mapRoot", "inlineSourceMap", []);
			}
		}

		if (options.Composite.IsTrue()) {
			if (options.Declaration.IsFalse()) {
				createDiagnosticForOptionName(Diagnostics.Composite_projects_may_not_disable_declaration_emit, "declaration", "", []);
			}
			if (options.Incremental.IsFalse()) {
				createDiagnosticForOptionName(Diagnostics.Composite_projects_may_not_disable_incremental_compilation, "declaration", "", []);
			}
		}

		if (options.TsBuildInfoFile == "" && options.Incremental.IsTrue() && options.ConfigFilePath == "") {
			createCompilerOptionsDiagnostic(Diagnostics.Option_incremental_is_only_valid_with_a_known_configuration_file_like_tsconfig_json_or_when_tsBuildInfoFile_is_explicitly_provided,
				[]);
		}

		this.verifyProjectReferences();

		if (options.Composite.IsTrue()) {
			final rootPaths = new Set<Path>();
			final fileNames = this.opts.Config.FileNames();
			if (fileNames != null) {
				for (fileName in fileNames) {
					rootPaths.Add(this.toPath(fileName));
				}
			}

			for (file in this.files) {
				if (Compiler.sourceFileMayBeEmitted(file, this, false) && !rootPaths.Has(file.Path())) {
					this.includeProcessor.addProcessingDiagnostic(new ProcessingDiagnostic(processingDiagnosticKindExplainingFileInclude,
						new IncludeExplainingDiagnostic(file.Path(), null,
							Diagnostics.File_0_is_not_listed_within_the_file_list_of_project_1_Projects_must_list_all_files_or_use_an_include_pattern,
							[file.FileName(), configFilePath()])));
				}
			}
		}

		final forEachOptionPathsSyntax = function(callback:(PropertyAssignment) -> Diagnostic):Diagnostic {
			return Tsoptions.ForEachPropertyAssignment(getCompilerOptionsObjectLiteralSyntax(), "paths", callback);
		};

		final createDiagnosticForOptionPaths = function(onKey:Bool, key:std.String, message:Message, args:Array<Any>):Diagnostic {
			var diag = forEachOptionPathsSyntax(function(pathProp:PropertyAssignment):Diagnostic {
				if (Ast.IsObjectLiteralExpression(pathProp.Initializer)) {
					return createOptionDiagnosticInObjectLiteralSyntax(pathProp.Initializer.AsObjectLiteralExpression(), onKey, key, "", message, args);
				}
				return null;
			});
			if (diag == null) {
				diag = createCompilerOptionsDiagnostic(message, args);
			}
			return diag;
		};

		final createDiagnosticForOptionPathKeyValue = function(key:std.String, valueIndex:Int, message:Message, args:Array<Any>):Diagnostic {
			var diag = forEachOptionPathsSyntax(function(pathProp:PropertyAssignment):Diagnostic {
				if (Ast.IsObjectLiteralExpression(pathProp.Initializer)) {
					return Tsoptions.ForEachPropertyAssignment(pathProp.Initializer.AsObjectLiteralExpression(), key, function(keyProps:PropertyAssignment):Diagnostic {
						final initializer = keyProps.Initializer;
						if (Ast.IsArrayLiteralExpression(initializer)) {
							final elements = initializer.ElementList();
							if (elements != null && elements.Nodes.length > valueIndex) {
								final diag = Tsoptions.CreateDiagnosticForNodeInSourceFile(sourceFile(), elements.Nodes[valueIndex], message, ...args);
								this.appendProgramDiagnostic(diag);
								return diag;
							}
						}
						return null;
					});
				}
				return null;
			});
			if (diag == null) {
				diag = createCompilerOptionsDiagnostic(message, args);
			}
			return diag;
		};

		if (options.Paths != null) {
			for (e in options.Paths.Entries()) {
				final key = e.key, value = e.value;
				// !!! This code does not handle cases where where the path mappings have the wrong types,
				// as that information is mostly lost during the parsing process.
				if (!Compiler.hasZeroOrOneAsteriskCharacter(key)) {
					createDiagnosticForOptionPaths(true /*onKey*/, key, Diagnostics.Pattern_0_can_have_at_most_one_Asterisk_character, [key]);
				}
				if (value == null) {
					createDiagnosticForOptionPaths(false /*onKey*/, key, Diagnostics.Substitutions_for_pattern_0_should_be_an_array, [key]);
				} else if (value.length == 0) {
					createDiagnosticForOptionPaths(false /*onKey*/, key, Diagnostics.Substitutions_for_pattern_0_shouldn_t_be_an_empty_array, [key]);
				}
				if (value != null) {
					for (i in 0...value.length) {
						final subst = value[i];
						if (!Compiler.hasZeroOrOneAsteriskCharacter(subst)) {
							createDiagnosticForOptionPathKeyValue(key, i, Diagnostics.Substitution_0_in_pattern_1_can_have_at_most_one_Asterisk_character, [subst, key]);
						}
						if (!Tspath.PathIsRelative(subst) && !Tspath.PathIsAbsolute(subst)) {
							createDiagnosticForOptionPathKeyValue(key, i, Diagnostics.Non_relative_paths_are_not_allowed_Did_you_forget_a_leading_Slash, []);
						}
					}
				}
			}
		}

		if (options.SourceMap.IsFalseOrUnknown() && options.InlineSourceMap.IsFalseOrUnknown()) {
			if (options.InlineSources.IsTrue()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_can_only_be_used_when_either_option_inlineSourceMap_or_option_sourceMap_is_provided,
					"inlineSources", "", []);
			}
			if (options.SourceRoot != "") {
				createDiagnosticForOptionName(Diagnostics.Option_0_can_only_be_used_when_either_option_inlineSourceMap_or_option_sourceMap_is_provided,
					"sourceRoot", "", []);
			}
		}

		if (options.MapRoot != "" && !(options.SourceMap.IsTrue() || options.DeclarationMap.IsTrue())) {
			// Error to specify --mapRoot without --sourcemap
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "mapRoot", "sourceMap",
				["declarationMap"]);
		}

		if (options.DeclarationDir != "") {
			if (!options.GetEmitDeclarations()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "declarationDir", "declaration",
					["composite"]);
			}
		}

		if (options.DeclarationMap.IsTrue() && !options.GetEmitDeclarations()) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "declarationMap", "declaration",
				["composite"]);
		}

		if (options.Lib != null && options.NoLib.IsTrue()) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_with_option_1, "lib", "noLib", []);
		}

		if (options.IsolatedModules.IsTrue() || options.VerbatimModuleSyntax.IsTrue()) {
			if (options.PreserveConstEnums.IsFalse()) {
				createDiagnosticForOptionName(Diagnostics.Option_preserveConstEnums_cannot_be_disabled_when_0_is_enabled,
					Core.IfElse(options.VerbatimModuleSyntax.IsTrue(), "verbatimModuleSyntax", "isolatedModules"), "preserveConstEnums", []);
			}
		}

		if (options.OutDir != ""
			|| options.RootDir != ""
			|| options.SourceRoot != ""
			|| options.MapRoot != ""
			|| (options.GetEmitDeclarations() && options.DeclarationDir != "")) {
			// !!! sheetal checkSourceFilesBelongToPath - for root Dir and configFile - explaining why file is in the program
			final dir = this.CommonSourceDirectory();
			if (options.OutDir != "" && dir == "" && Core.Some(this.files, function(f:SourceFile) return Tspath.GetRootLength(f.FileName()) > 1)) {
				createDiagnosticForOptionName(Diagnostics.Cannot_find_the_common_subdirectory_path_for_the_input_files, "outDir", "", []);
			}
		}

		if (!options.NoEmit.IsTrue()
			&& !options.Composite.IsTrue()
			&& options.RootDir == ""
			&& options.ConfigFilePath != ""
			&& (options.OutDir != "" || (options.GetEmitDeclarations() && options.DeclarationDir != "") || options.OutFile != "")) {
			// Check if rootDir inferred changed and issue diagnostic
			final dir = this.CommonSourceDirectory();
			var emittedFiles:Array<std.String> = null;
			for (file in this.files) {
				if (!file.IsDeclarationFile && Compiler.sourceFileMayBeEmitted(file, this, false)) {
					if (emittedFiles == null)
						emittedFiles = [];
					emittedFiles.push(file.FileName());
				}
			}
			final dir59 = Outputpaths.GetComputedCommonSourceDirectory(emittedFiles, this.GetCurrentDirectory(), this.UseCaseSensitiveFileNames());
			if (dir59 != ""
				&& Tspath.GetCanonicalFileName(dir, this.UseCaseSensitiveFileNames()) != Tspath.GetCanonicalFileName(dir59, this.UseCaseSensitiveFileNames())) {
				// change in layout
				var option1:std.String;
				if (options.OutFile != "") {
					option1 = "outFile";
				} else if (options.OutDir != "") {
					option1 = "outDir";
				} else {
					option1 = "declarationDir";
				}
				var option2 = "";
				if (options.OutFile == "" && options.OutDir != "") {
					option2 = "declarationDir";
				}
				final diag = createDiagnosticForOption(true, /*onKey*/ option1, option2,
					Diagnostics.The_common_source_directory_of_0_is_1_The_rootDir_setting_must_be_explicitly_set_to_this_or_another_path_to_adjust_your_output_s_file_layout,
					[
						Tspath.GetBaseFileName(options.ConfigFilePath),
						Tspath.GetRelativePathFromFile(options.ConfigFilePath, dir59, this.comparePathsOptions)
					]);
				diag.AddMessageChain(Ast.NewCompilerDiagnostic(Diagnostics.Visit_https_Colon_Slash_Slashaka_ms_Slashts6_for_migration_information));
			}
		}

		if (options.CheckJs.IsTrue() && !options.GetAllowJS()) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "checkJs", "allowJs", []);
		}

		if (options.EmitDeclarationOnly.IsTrue()) {
			if (!options.GetEmitDeclarations()) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1_or_option_2, "emitDeclarationOnly",
					"declaration", ["composite"]);
			}
		}

		if (options.EmitDecoratorMetadata.IsTrue() && options.ExperimentalDecorators.IsFalseOrUnknown()) {
			createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "emitDecoratorMetadata", "experimentalDecorators",
				[]);
		}

		if (options.JsxFactory != "") {
			if (options.ReactNamespace != "") {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_with_option_1, "reactNamespace", "jsxFactory", []);
			}
			if (options.Jsx == JsxEmitReactJSX || options.Jsx == JsxEmitReactJSXDev) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxFactory", options.Jsx.String(), []);
			}
			if (Parser.ParseIsolatedEntityName(options.JsxFactory) == null) {
				createOptionValueDiagnostic("jsxFactory", Diagnostics.Invalid_value_for_jsxFactory_0_is_not_a_valid_identifier_or_qualified_name, [options.JsxFactory]);
			}
		} else if (options.ReactNamespace != "" && !Scanner.IsIdentifierText(options.ReactNamespace, LanguageVariantStandard)) {
			createOptionValueDiagnostic("reactNamespace", Diagnostics.Invalid_value_for_reactNamespace_0_is_not_a_valid_identifier, [options.ReactNamespace]);
		}

		if (options.JsxFragmentFactory != "") {
			if (options.JsxFactory == "") {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_without_specifying_option_1, "jsxFragmentFactory", "jsxFactory", []);
			}
			if (options.Jsx == JsxEmitReactJSX || options.Jsx == JsxEmitReactJSXDev) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxFragmentFactory", options.Jsx.String(), []);
			}
			if (Parser.ParseIsolatedEntityName(options.JsxFragmentFactory) == null) {
				createOptionValueDiagnostic("jsxFragmentFactory", Diagnostics.Invalid_value_for_jsxFragmentFactory_0_is_not_a_valid_identifier_or_qualified_name,
					[options.JsxFragmentFactory]);
			}
		}

		if (options.ReactNamespace != "") {
			if (options.Jsx == JsxEmitReactJSX || options.Jsx == JsxEmitReactJSXDev) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "reactNamespace", options.Jsx.String(), []);
			}
		}

		if (options.JsxImportSource != "") {
			if (options.Jsx == JsxEmitReact) {
				createDiagnosticForOptionName(Diagnostics.Option_0_cannot_be_specified_when_option_jsx_is_1, "jsxImportSource", options.Jsx.String(), []);
			}
		}

		final moduleKind = options.GetEmitModuleKind();

		if (options.AllowImportingTsExtensions.IsTrue()
			&& !(options.NoEmit.IsTrue() || options.EmitDeclarationOnly.IsTrue() || options.RewriteRelativeImportExtensions.IsTrue())) {
			createOptionValueDiagnostic("allowImportingTsExtensions",
				Diagnostics.Option_allowImportingTsExtensions_can_only_be_used_when_one_of_noEmit_emitDeclarationOnly_or_rewriteRelativeImportExtensions_is_set,
				[]);
		}

		final moduleResolution = options.GetModuleResolutionKind();
		if (options.ResolvePackageJsonExports.IsTrue() && !Compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution)) {
			createDiagnosticForOptionName(Diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler,
				"resolvePackageJsonExports", "", []);
		}
		if (options.ResolvePackageJsonImports.IsTrue() && !Compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution)) {
			createDiagnosticForOptionName(Diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler,
				"resolvePackageJsonImports", "", []);
		}
		if (options.CustomConditions != null && !Compiler.moduleResolutionSupportsPackageJsonExportsAndImports(moduleResolution)) {
			createDiagnosticForOptionName(Diagnostics.Option_0_can_only_be_used_when_moduleResolution_is_set_to_node16_nodenext_or_bundler,
				"customConditions", "", []);
		}

		if (moduleResolution == ModuleResolutionKindBundler
			&& !Compiler.emitModuleKindIsNonNodeESM(moduleKind)
			&& moduleKind != ModuleKindPreserve
			&& moduleKind != ModuleKindCommonJS) {
			createOptionValueDiagnostic("moduleResolution",
				Diagnostics.Option_0_can_only_be_used_when_module_is_set_to_preserve_commonjs_or_es2015_or_later, ["bundler"]);
		}

		if ((ModuleKindNode16 : Int) <= (moduleKind : Int)
			&& (moduleKind : Int) <= (ModuleKindNodeNext : Int)
			&& !((ModuleResolutionKindNode16 : Int) <= (moduleResolution : Int) && (moduleResolution : Int) <= (ModuleResolutionKindNodeNext : Int))) {
			final moduleKindName = moduleKind.String();
			var moduleResolutionName:std.String;
			if (Core.ModuleKindToModuleResolutionKind.exists(moduleKind)) {
				moduleResolutionName = Core.ModuleKindToModuleResolutionKind.get(moduleKind).String();
			} else {
				moduleResolutionName = "Node16";
			}
			createOptionValueDiagnostic("moduleResolution",
				Diagnostics.Option_moduleResolution_must_be_set_to_0_or_left_unspecified_when_option_module_is_set_to_1, [moduleResolutionName, moduleKindName]);
		} else if ((ModuleResolutionKindNode16 : Int) <= (moduleResolution : Int)
			&& (moduleResolution : Int) <= (ModuleResolutionKindNodeNext : Int)
			&& !((ModuleKindNode16 : Int) <= (moduleKind : Int) && (moduleKind : Int) <= (ModuleKindNodeNext : Int))) {
			final moduleResolutionName = moduleResolution.String();
			createOptionValueDiagnostic("module", Diagnostics.Option_module_must_be_set_to_0_when_option_moduleResolution_is_set_to_1,
				[moduleResolutionName, moduleResolutionName]);
		}

		// !!! The below needs filesByName, which is not equivalent to p.filesByPath.

		// If the emit is enabled make sure that every output file is unique and not overwriting any of the input files
		if (!options.NoEmit.IsTrue() && !options.SuppressOutputPathCheck.IsTrue()) {
			final emitFilesSeen = new Set<std.String>();

			// Verify that all the emit files are unique and don't overwrite input files
			final verifyEmitFilePath = function(emitFileName:std.String) {
				if (emitFileName != "") {
					final emitFilePath = this.toPath(emitFileName);
					// Report error if the output overwrites input file
					if (this.filesByPath.exists(emitFilePath)) {
						final diag = Ast.NewCompilerDiagnostic(Diagnostics.Cannot_write_file_0_because_it_would_overwrite_input_file, emitFileName);
						if (configFilePath() == "") {
							// The program is from either an inferred project or an external project
							diag.AddMessageChain(Ast.NewCompilerDiagnostic(Diagnostics.Adding_a_tsconfig_json_file_will_help_organize_projects_that_contain_both_TypeScript_and_JavaScript_files_Learn_more_at_https_Colon_Slash_Slashaka_ms_Slashtsconfig));
						}
						this.blockEmittingOfFile(emitFileName, diag);
					}

					var emitFileKey:std.String;
					if (!this.Host().FS().UseCaseSensitiveFileNames()) {
						emitFileKey = Tspath.ToFileNameLowerCase(emitFilePath);
					} else {
						emitFileKey = emitFilePath;
					}

					// Report error if multiple files write into same file
					if (emitFilesSeen.Has(emitFileKey)) {
						// Already seen the same emit file - report error
						this.blockEmittingOfFile(emitFileName,
							Ast.NewCompilerDiagnostic(Diagnostics.Cannot_write_file_0_because_it_would_be_overwritten_by_multiple_input_files, emitFileName));
					} else {
						emitFilesSeen.Add(emitFileKey);
					}
				}
			};

			Outputpaths.ForEachEmittedFile(this, options, function(emitFileNames:ts.outputpaths.Outputpaths.OutputPaths, sourceFile:SourceFile):Bool {
				verifyEmitFilePath(emitFileNames.JsFilePath());
				verifyEmitFilePath(emitFileNames.SourceMapFilePath());
				verifyEmitFilePath(emitFileNames.DeclarationFilePath());
				verifyEmitFilePath(emitFileNames.DeclarationMapPath());
				return false;
			}, this.getSourceFilesToEmit(null, false), false);
			verifyEmitFilePath(this.opts.Config.GetBuildInfoFileName());
		}
	}

	// PORT: `p.programDiagnostics = append(p.programDiagnostics, diag)`.
	function appendProgramDiagnostic(diag:Diagnostic):Void {
		if (this.programDiagnostics == null)
			this.programDiagnostics = [];
		this.programDiagnostics.push(diag);
	}

	function blockEmittingOfFile(emitFileName:std.String, diag:Diagnostic):Void {
		this.hasEmitBlockingDiagnostics.Add(this.toPath(emitFileName));
		this.appendProgramDiagnostic(diag);
	}

	public function IsEmitBlocked(emitFileName:std.String):Bool {
		return this.hasEmitBlockingDiagnostics.Has(this.toPath(emitFileName));
	}

	function verifyProjectReferences():Void {
		final buildInfoFileName = Core.IfElse(!this.Options().SuppressOutputPathCheck.IsTrue(), this.opts.Config.GetBuildInfoFileName(), "");
		final createDiagnosticForReference = function(config:ParsedCommandLine, index:Int, message:Message, args:Array<Any>) {
			var diag = Tsoptions.CreateDiagnosticAtReferenceSyntax(config, index, message, ...args);
			if (diag == null) {
				diag = Ast.NewCompilerDiagnostic(message, ...args);
			}
			this.appendProgramDiagnostic(diag);
		};

		this.RangeResolvedProjectReference(function(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int):Bool {
			final ref = parent.ProjectReferences()[index];
			// !!! Deprecated in 5.0 and removed since 5.5
			// verifyRemovedProjectReference(ref, parent, index);
			if (config == null) {
				createDiagnosticForReference(parent, index, Diagnostics.File_0_not_found, [ref.Path]);
				return true;
			}
			final refOptions = config.CompilerOptions();
			if (!refOptions.Composite.IsTrue() || refOptions.NoEmit.IsTrue()) {
				if (Core.len(parent.FileNames()) > 0) {
					if (!refOptions.Composite.IsTrue()) {
						createDiagnosticForReference(parent, index, Diagnostics.Referenced_project_0_must_have_setting_composite_Colon_true, [ref.Path]);
					}
					if (refOptions.NoEmit.IsTrue()) {
						createDiagnosticForReference(parent, index, Diagnostics.Referenced_project_0_may_not_disable_emit, [ref.Path]);
					}
				}
			}
			if (buildInfoFileName != "" && buildInfoFileName == config.GetBuildInfoFileName()) {
				createDiagnosticForReference(parent, index, Diagnostics.Cannot_write_file_0_because_it_will_overwrite_tsbuildinfo_file_generated_by_referenced_project_1,
					[buildInfoFileName, ref.Path]);
				this.hasEmitBlockingDiagnostics.Add(this.toPath(buildInfoFileName));
			}
			return true;
		});
	}

	public function GetGlobalDiagnostics(ctx:Context):Array<Diagnostic> {
		if (this.files.length == 0) {
			return null;
		}
		if (this.compilerCheckerPool != null) {
			return this.compilerCheckerPool.GetGlobalDiagnostics();
		}
		// For external pools (project system), global diagnostics are collected
		// incrementally as checkers are used, not via a bulk query.
		return null;
	}

	public function GetDeclarationDiagnostics(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		return this.collectDiagnostics(ctx, sourceFile, true /*concurrent*/, this.getDeclarationDiagnosticsForFile);
	}

	function getSemanticDiagnosticsWithChecker(ctx:Context, c:Checker, sourceFile:SourceFile):Array<Diagnostic> {
		return Core.Concatenate(Compiler.FilterNoEmitSemanticDiagnostics(this.getBindAndCheckDiagnosticsWithChecker(ctx, c, sourceFile), this.Options()),
			this.GetIncludeProcessorDiagnostics(sourceFile));
	}

	// getBindAndCheckDiagnosticsWithChecker gets semantic diagnostics for a single file using a
	// caller-provided checker, including bind diagnostics, checker diagnostics, and handling
	// of @ts-ignore/@ts-expect-error directives.
	function getBindAndCheckDiagnosticsWithChecker(ctx:Context, fileChecker:Checker, sourceFile:SourceFile):Array<Diagnostic> {
		final compilerOptions = this.Options();
		if (this.SkipTypeChecking(sourceFile, false)) {
			return null;
		}

		// Checker creation forces binding, so bind diagnostics will be populated.
		// PORT: slices.Clip + append → copy then push
		var diags:Array<Diagnostic> = Slices.Clone(sourceFile.BindDiagnostics());
		final checkDiags = fileChecker.GetDiagnostics(ctx, sourceFile);
		if (checkDiags != null && checkDiags.length > 0) {
			if (diags == null)
				diags = [];
			for (d in checkDiags)
				diags.push(d);
		}

		final isPlainJS = Ast.IsPlainJSFile(sourceFile, compilerOptions.CheckJs);
		if (isPlainJS) {
			return Core.Filter(diags, function(d:Diagnostic) return Compiler.plainJSErrors.Has(d.Code()));
		}

		final isJS = sourceFile.ScriptKind == ScriptKindJS || sourceFile.ScriptKind == ScriptKindJSX;
		final isCheckJS = isJS && Ast.IsCheckJSEnabledForFile(sourceFile, compilerOptions);
		if (isCheckJS) {
			final jsdocDiags = sourceFile.JSDocDiagnostics();
			if (jsdocDiags != null && jsdocDiags.length > 0) {
				if (diags == null)
					diags = [];
				for (d in jsdocDiags)
					diags.push(d);
			}
		}

		final r = this.getDiagnosticsWithPrecedingDirectives(sourceFile, diags);
		var filtered = r.a;
		final directivesByLine = r.b;
		if (directivesByLine != null) {
			// PORT: Go map iteration order is random; callers sort the result.
			for (directive in directivesByLine) {
				// Above we changed all used directive kinds to @ts-ignore, so any @ts-expect-error directives that
				// remain are unused and thus errors.
				if (directive.Kind == CommentDirectiveKindExpectError) {
					if (filtered == null)
						filtered = [];
					filtered.push(Ast.NewDiagnostic(sourceFile, directive.Loc, Diagnostics.Unused_ts_expect_error_directive));
				}
			}
		}
		return filtered;
	}

	// PORT: ([]*ast.Diagnostic, map[int]ast.CommentDirective) → Pair. The map holds copies of the
	// directives (Go value semantics), so changing their Kind does not touch the source file.
	function getDiagnosticsWithPrecedingDirectives(sourceFile:SourceFile, diags:Array<Diagnostic>):Pair<Array<Diagnostic>, IntMap<CommentDirective>> {
		if (Core.len(sourceFile.CommentDirectives) == 0) {
			return new Pair(diags, null);
		}
		// Build map of directives by line number
		final directivesByLine = new IntMap<CommentDirective>();
		for (directive in sourceFile.CommentDirectives) {
			final line = Scanner.GetECMALineOfPosition(sourceFile, directive.Loc.Pos());
			final copy = new CommentDirective();
			copy.Loc = directive.Loc;
			copy.Kind = directive.Kind;
			directivesByLine.set(line, copy);
		}
		final lineStarts = Scanner.GetECMALineStarts(sourceFile);
		final filtered:Array<Diagnostic> = [];
		if (diags != null) {
			for (diagnostic in diags) {
				var ignoreDiagnostic = false;
				var line = Scanner.ComputeLineOfPosition(lineStarts, diagnostic.Pos()) - 1;
				while (line >= 0) {
					// If line contains a @ts-ignore or @ts-expect-error directive, ignore this diagnostic and change
					// the directive kind to @ts-ignore to indicate it was used.
					final directive = directivesByLine.get(line);
					if (directive != null) {
						ignoreDiagnostic = true;
						directive.Kind = CommentDirectiveKindIgnore;
						break;
					}
					// Stop searching backwards when we encounter a line that isn't blank or a comment.
					if (!Compiler.isCommentOrBlankLine(sourceFile.Text(), (lineStarts[line] : Int))) {
						break;
					}
					line--;
				}
				if (!ignoreDiagnostic) {
					filtered.push(diagnostic);
				}
			}
		}
		return new Pair(filtered, directivesByLine);
	}

	function getDeclarationDiagnosticsForFile(ctx:Context, sourceFile:SourceFile):Array<Diagnostic> {
		if (sourceFile.IsDeclarationFile) {
			return [];
		}

		if (this.declarationDiagnosticCache.exists(sourceFile)) {
			return this.declarationDiagnosticCache.get(sourceFile);
		}

		final h = Compiler.newEmitHost(ctx, this, sourceFile);
		final host = h.a, done = h.b;
		var diagnostics = try Compiler.getDeclarationDiagnostics(host, sourceFile) catch (e:Dynamic) {
			done();
			throw e;
		}
		// diagnostics, _ = p.declarationDiagnosticCache.LoadOrStore(sourceFile, diagnostics)
		this.declarationDiagnosticCache.set(sourceFile, diagnostics);
		done();
		return diagnostics;
	}

	function getSuggestionDiagnosticsWithChecker(ctx:Context, fileChecker:Checker, sourceFile:SourceFile):Array<Diagnostic> {
		if (this.SkipTypeChecking(sourceFile, false)) {
			return null;
		}

		// Checker creation forces binding, so bind suggestion diagnostics will be populated.
		var diags:Array<Diagnostic> = Slices.Clone(sourceFile.BindSuggestionDiagnostics);
		final s = fileChecker.GetSuggestionDiagnostics(ctx, sourceFile);
		if (s != null && s.length > 0) {
			if (diags == null)
				diags = [];
			for (d in s)
				diags.push(d);
		}

		return diags;
	}

	public function LineCount():Int {
		var count = 0;
		for (file in this.files) {
			count += file.ECMALineMap().length;
		}
		return count;
	}

	public function IdentifierCount():Int {
		var count = 0;
		for (file in this.files) {
			count += file.IdentifierCount;
		}
		return count;
	}

	public function SymbolCount():Int {
		var count = 0;
		for (file in this.files) {
			count += file.SymbolCount;
		}
		var val = count;
		this.ForEachCheckerParallel(function(_:Int, c:Checker) {
			val += c.SymbolCount;
		});
		return val;
	}

	public function TypeCount():Int {
		var val = 0;
		this.ForEachCheckerParallel(function(_:Int, c:Checker) {
			val += c.TypeCount;
		});
		return val;
	}

	public function InstantiationCount():Int {
		var val = 0;
		this.ForEachCheckerParallel(function(_:Int, c:Checker) {
			val += c.TotalInstantiationCount;
		});
		return val;
	}

	public function Program():Program {
		return this;
	}

	public function GetSourceFileMetaData(path:Path):SourceFileMetaData {
		final m = this.sourceFileMetaDatas.get(path);
		return m == null ? new SourceFileMetaData() : m; // Go zero value for a missing key
	}

	public function GetEmitModuleFormatOfFile(sourceFile:HasFileName):ModuleKind {
		return Ast.GetEmitModuleFormatOfFileWorker(sourceFile.FileName(), this.projectReferenceFileMapper.getCompilerOptionsForFile(sourceFile),
			this.GetSourceFileMetaData(sourceFile.Path()));
	}

	public function GetEmitSyntaxForUsageLocation(sourceFile:HasFileName, location:StringLiteralLike):ResolutionMode {
		return Compiler.getEmitSyntaxForUsageLocationWorker(sourceFile.FileName(), this.GetSourceFileMetaData(sourceFile.Path()), location,
			this.projectReferenceFileMapper.getCompilerOptionsForFile(sourceFile));
	}

	public function GetImpliedNodeFormatForEmit(sourceFile:HasFileName):ResolutionMode {
		return Ast.GetImpliedNodeFormatForEmitWorker(sourceFile.FileName(), this.projectReferenceFileMapper.getCompilerOptionsForFile(sourceFile)
			.GetEmitModuleKind(), this.GetSourceFileMetaData(sourceFile.Path()));
	}

	public function GetModeForUsageLocation(sourceFile:HasFileName, location:StringLiteralLike):ResolutionMode {
		return Compiler.getModeForUsageLocation(sourceFile.FileName(), this.GetSourceFileMetaData(sourceFile.Path()), location,
			this.projectReferenceFileMapper.getCompilerOptionsForFile(sourceFile));
	}

	public function GetDefaultResolutionModeForFile(sourceFile:HasFileName):ResolutionMode {
		return Compiler.getDefaultResolutionModeForFile(sourceFile.FileName(), this.GetSourceFileMetaData(sourceFile.Path()),
			this.projectReferenceFileMapper.getCompilerOptionsForFile(sourceFile));
	}

	public function IsSourceFileDefaultLibrary(path:Path):Bool {
		return this.libFiles.exists(path);
	}

	public function IsGlobalTypingsFile(fileName:std.String):Bool {
		if (!Tspath.IsDeclarationFileName(fileName)) {
			return false;
		}
		return Tspath.ContainsPath(this.GetGlobalTypingsCacheLocation(), fileName, this.comparePathsOptions);
	}

	public function GetDefaultLibFile(path:Path):LibFile {
		final libFile = this.libFiles.get(path);
		if (libFile != null) {
			return libFile;
		}
		return null;
	}

	public function CommonSourceDirectory():std.String {
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!this.commonSourceDirectoryOnce) {
			this.commonSourceDirectoryOnce = true;
			final files = function():Array<std.String> {
				return Core.MapFiltered(this.files, function(file:SourceFile):ValueOk<std.String> {
					return new ValueOk(file.FileName(), Compiler.sourceFileMayBeEmitted(file, this, false /*forceDtsEmit*/) && !file.IsDeclarationFile);
				});
			};
			this.commonSourceDirectory = Outputpaths.GetCommonSourceDirectory(this.Options(), files, this.GetCurrentDirectory(), this.UseCaseSensitiveFileNames(),
				this.checkSourceFilesBelongToPath);
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return this.commonSourceDirectory;
	}

	function checkSourceFilesBelongToPath(sourceFiles:Array<std.String>, rootDirectory:std.String):Bool {
		var allFilesBelongToPath = true;
		if (sourceFiles != null) {
			for (file in sourceFiles) {
				final absoluteSourceFilePath = Tspath.GetCanonicalFileName(Tspath.GetNormalizedAbsolutePath(file, this.GetCurrentDirectory()),
					this.UseCaseSensitiveFileNames());
				if (!Tspath.ContainsPath(rootDirectory, file, this.comparePathsOptions)) {
					this.includeProcessor.addProcessingDiagnostic(new ProcessingDiagnostic(processingDiagnosticKindExplainingFileInclude,
						new IncludeExplainingDiagnostic(absoluteSourceFilePath, null,
							Diagnostics.File_0_is_not_under_rootDir_1_rootDir_is_expected_to_contain_all_source_files, [file, rootDirectory])));
					allFilesBelongToPath = false;
				}
			}
		}

		return allFilesBelongToPath;
	}

	public function Emit(ctx:Context, options:EmitOptions):EmitResult {
		var done:() -> Void = null;
		final tr = this.opts.Tracing;
		if (tr != null) {
			done = tr.Push(PhaseEmit, "emit", null, true);
		}
		final r = try this.emitWorker(ctx, options) catch (e:Dynamic) {
			if (done != null)
				done();
			throw e;
		}
		if (done != null)
			done();
		return r;
	}

	// PORT: body of Emit after the tracing defer.
	function emitWorker(ctx:Context, options:EmitOptions):EmitResult {
		if (options.EmitOnly != EmitOnlyForcedDts) {
			final result = Compiler.HandleNoEmitOnError(ctx, this, options.TargetSourceFile);
			if (result != null || ctx.Err() != null) {
				return result;
			}
		}

		final newLine = this.Options().NewLine.GetNewLineCharacter();
		// PORT: sync.Pool of writers → a new writer per file (Go clears a pooled writer before use).
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — the files are emitted on threads, as in Go
		final wg:WorkGroup = this.SingleThreaded() ? Core.NewWorkGroup(true) : new ParallelWorkGroup();
		#else
		final wg = Core.NewWorkGroup(this.SingleThreaded());
		#end
		final emitters:Array<Emitter> = [];
		final sourceFiles = this.getSourceFilesToEmit(options.TargetSourceFile, options.EmitOnly == EmitOnlyForcedDts);

		if (sourceFiles != null) {
			for (sourceFile in sourceFiles) {
				final emitter = new Emitter();
				emitter.writer = null;
				emitter.sourceFile = sourceFile;
				emitter.emitOnly = options.EmitOnly;
				emitter.writeFile = options.WriteFile;
				emitter.tr = this.opts.Tracing;
				emitters.push(emitter);
				wg.Queue(function() {
					final h = Compiler.newEmitHost(ctx, this, sourceFile);
					final host = h.a, hostDone = h.b;
					try {
						emitter.host = host;

						// take an unused writer
						final writer = Printer.NewTextWriter(newLine, 0);
						writer.Clear();

						// attach writer and perform emit
						emitter.writer = writer;
						emitter.paths = Outputpaths.GetOutputPathsFor(sourceFile, host.Options(), host, options.EmitOnly == EmitOnlyForcedDts);
						emitter.emit();
						emitter.writer = null;

						// put the writer back in the pool
					} catch (e:Dynamic) {
						hostDone();
						throw e;
					}
					hostDone();
				});
			}
		}

		// wait for emit to complete
		wg.RunAndWait();

		// collect results from emit, preserving input order
		return Compiler.CombineEmitResults(Core.Map(emitters, function(e:Emitter) return e.emitResult));
	}

	function toPath(filename:std.String):Path {
		return Tspath.ToPath(filename, this.GetCurrentDirectory(), this.UseCaseSensitiveFileNames());
	}

	public function GetSourceFile(filename:std.String):SourceFile {
		final path = this.toPath(filename);
		return this.GetSourceFileByPath(path);
	}

	public function GetSourceFileForResolvedModule(fileName:std.String):SourceFile {
		final file = this.GetSourceFile(fileName);
		if (file == null) {
			final filename = this.GetParseFileRedirect(fileName);
			if (filename != "") {
				return this.GetSourceFile(filename);
			}
		}
		return file;
	}

	public function FilesByPath():StringMap<SourceFile> {
		return this.filesByPath;
	}

	public function GetSourceFileByPath(path:Path):SourceFile {
		return this.filesByPath.get(path);
	}

	public function HasSameFileNames(other:Program):Bool {
		return Compiler.stringMapEqualFunc(this.filesByPath, other.filesByPath, function(a:SourceFile, b:SourceFile) {
			// checks for casing differences on case-insensitive file systems
			return a.FileName() == b.FileName();
		}) && Compiler.stringMapEqualFunc(this.redirectFilesByPath, other.redirectFilesByPath, function(a:RedirectsFile, b:RedirectsFile) {
			return a.FileName() == b.FileName();
		});
	}

	public function GetSourceFiles():Array<SourceFile> {
		return this.files;
	}

	// Testing only
	public function GetIncludeReasons():StringMap<Array<FileIncludeReason>> {
		return this.includeProcessor.fileIncludeReasons;
	}

	// Testing only
	public function IsMissingPath(path:Path):Bool {
		return Slices.ContainsFunc(this.missingFiles, function(missingPath:std.String) {
			return this.toPath(missingPath) == path;
		});
	}

	public function ExplainFiles(w:go.Io.Writer, locale:Locale):Void {
		final toRelativeFileName = function(fileName:std.String):std.String {
			return Tspath.GetRelativePathFromDirectory(this.GetCurrentDirectory(), fileName, this.comparePathsOptions);
		};
		var filesExplained = 0;
		final explainFile = function(file:HasFileName) {
			Fmt.Fprint(w, [toRelativeFileName(file.FileName()) + "\n"]);
			final reasons = this.includeProcessor.fileIncludeReasons.get(file.Path());
			if (reasons != null) {
				for (reason in reasons) {
					Fmt.Fprint(w, ["   " + reason.toDiagnostic(this, true).Localize(locale) + "\n"]);
				}
			}
			final explained = this.includeProcessor.explainRedirectAndImpliedFormat(this, file.Path(), toRelativeFileName);
			if (explained != null) {
				for (diag in explained) {
					Fmt.Fprint(w, ["   " + diag.Localize(locale) + "\n"]);
				}
			}
			filesExplained++;
		};

		final redirectFiles:Array<RedirectsFile> = this.redirectFilesByPath == null ? [] : [for (v in this.redirectFilesByPath) v];
		Slices.SortFunc(redirectFiles, function(a:RedirectsFile, b:RedirectsFile) return a.index - b.index);

		final files = this.GetSourceFiles();
		var sourceFileIndex = 0;
		final explainSourceFiles = function(endIndex:Int) {
			while (filesExplained < endIndex) {
				explainFile(ts.modulespecifiers.Types.SourceFileAdapter.Of(files[sourceFileIndex]));
				sourceFileIndex++;
			}
		};

		for (redirectFile in redirectFiles) {
			// Explain all sourceFiles till we reach this redirectFile index
			explainSourceFiles(redirectFile.index);
			explainFile(redirectFile);
		}

		// Explain any remaining sourceFiles
		explainSourceFiles(files.length + redirectFiles.length);
	}

	public function GetLibFileFromReference(ref:FileReference):SourceFile {
		final r = Tsoptions.GetLibFileName(ref.FileName);
		if (!r.ok) {
			return null;
		}
		final sourceFile = this.filesByPath.get(r.value);
		if (sourceFile != null) {
			return sourceFile;
		}
		return null;
	}

	public function GetResolvedTypeReferenceDirectiveFromTypeReferenceDirective(typeRef:FileReference, sourceFile:SourceFile):ResolvedTypeReferenceDirective {
		final resolutions = this.typeResolutionsInFile.get(sourceFile.Path());
		if (resolutions != null) {
			final key = new ModeAwareCacheKey(typeRef.FileName, this.getModeForTypeReferenceDirectiveInFile(typeRef, sourceFile)).Key();
			if (resolutions.exists(key)) {
				return resolutions.get(key);
			}
		}
		return null;
	}

	public function GetResolvedTypeReferenceDirectives():StringMap<ModeAwareCache<ResolvedTypeReferenceDirective>> {
		return this.typeResolutionsInFile;
	}

	function getModeForTypeReferenceDirectiveInFile(ref:FileReference, sourceFile:SourceFile):ResolutionMode {
		if (ref.ResolutionMode != Core.ResolutionModeNone) {
			return ref.ResolutionMode;
		}
		return this.GetDefaultResolutionModeForFile(ts.modulespecifiers.Types.SourceFileAdapter.Of(sourceFile));
	}

	public function IsSourceFileFromExternalLibrary(file:SourceFile):Bool {
		return this.sourceFilesFoundSearchingNodeModules.Has(file.Path());
	}

	// PORT: (moduleReference string, specifier *ast.Node) → Pair
	public function GetJSXRuntimeImportSpecifier(path:Path):Pair<std.String, Node> {
		final result = this.jsxRuntimeImportSpecifiers == null ? null : this.jsxRuntimeImportSpecifiers.get(path);
		if (result != null) {
			return new Pair(result.moduleReference, result.specifier);
		}
		return new Pair("", null);
	}

	public function GetImportHelpersImportSpecifier(path:Path):Node {
		return this.importHelpersImportSpecifiers == null ? null : this.importHelpersImportSpecifiers.get(path);
	}

	public function SourceFileMayBeEmitted(sourceFile:SourceFile, forceDtsEmit:Bool):Bool {
		return Compiler.sourceFileMayBeEmitted(sourceFile, this, forceDtsEmit);
	}

	public function ResolvedPackageNames():Set<std.String> {
		return this.collectPackageNames().resolved;
	}

	public function UnresolvedPackageNames():Set<std.String> {
		return this.collectPackageNames().unresolved;
	}

	public function DeepImportPackageNames():Set<std.String> {
		return this.collectPackageNames().deepImportPackages;
	}

	function collectPackageNames():PackageNamesInfo {
		return this.packageNames.getValue(function():PackageNamesInfo {
			final packageNames = new PackageNamesInfo(new Set<std.String>(), new Set<std.String>(), new Set<std.String>());
			for (file in this.files) {
				if (this.IsSourceFileDefaultLibrary(file.Path()) || this.IsSourceFileFromExternalLibrary(file) || file.FileName().indexOf("/node_modules/") >= 0) {
					// Checking for /node_modules/ is a little imprecise, but ATA treats locally installed typings
					// as root files, which would not pass IsSourceFileFromExternalLibrary.
					continue;
				}
				if (file.Imports() == null)
					continue;
				for (imp in file.Imports()) {
					if (Tspath.IsExternalModuleNameRelative(imp.Text())) {
						continue;
					}
					final resolvedModules = this.resolvedModules.get(file.Path());
					if (resolvedModules != null) {
						final key = new ModeAwareCacheKey(imp.Text(), this.GetModeForUsageLocation(ts.modulespecifiers.Types.SourceFileAdapter.Of(file), imp)).Key();
						final resolvedModule = resolvedModules.get(key);
						if (resolvedModules.exists(key) && resolvedModule.IsResolved()) {
							if (!resolvedModule.IsExternalLibraryImport) {
								continue;
							}
							// Priority order for getting package name:
							// 1. PackageId.Name (requires both name and version in package.json)
							var name = resolvedModule.PackageId.Name;
							if (name == "") {
								// 2. GetPackageScopeForPath - get name from package.json in the package directory
								final packageScope = this.resolver.GetPackageScopeForPath(resolvedModule.ResolvedFileName);
								if (packageScope != null && packageScope.Exists()) {
									final v = packageScope.Contents.Name.GetValue();
									if (v.ok) {
										name = v.value;
									}
								}
							}
							if (name == "") {
								// 3. GetPackageNameFromDirectory - extract from node_modules path
								name = Modulespecifiers.GetPackageNameFromDirectory(resolvedModule.ResolvedFileName);
							}
							// 4. If all fail, don't add empty string
							if (name != "") {
								packageNames.resolved.Add(name);
								// Detect deep imports: subpath imports in packages without exports.
								// These are imports like "lodash/fp" where the package has no exports
								// map, so auto-import can only find them via recursive directory search.
								final rest = Module.ParsePackageName(imp.Text()).b;
								if (rest != "") {
									final scope = this.resolver.GetPackageScopeForPath(resolvedModule.ResolvedFileName);
									if (scope != null && scope.Exists() && !scope.Contents.Exports.IsPresent()) {
										packageNames.deepImportPackages.Add(Module.GetPackageNameFromTypesPackageName(name));
									}
								}
							}
							continue;
						}
					}
					packageNames.unresolved.Add(imp.Text());
				}
			}
			return packageNames;
		});
	}

	public function IsLibFile(sourceFile:SourceFile):Bool {
		return this.libFiles.exists(sourceFile.Path());
	}

	public function HasTSFile():Bool {
		#if tshx_parallel
		go.Par.onceMutex.acquire();
		#end
		if (!this.hasTSFileOnce) {
			this.hasTSFileOnce = true;
			for (file in this.files) {
				if (Tspath.HasImplementationTSFileExtension(file.FileName())) {
					this.hasTSFile = true;
					break;
				}
			}
		}
		#if tshx_parallel
		go.Par.onceMutex.release();
		#end
		return this.hasTSFile;
	}

	public function GetSymlinkCache():KnownSymlinks {
		return this.knownSymlinks.getValue(function():KnownSymlinks {
			final knownSymlinks = Symlinks.NewKnownSymlink(this.GetCurrentDirectory(), this.UseCaseSensitiveFileNames());

			// Resolved modules store realpath information when they're resolved inside node_modules
			if (Lambda.count(this.resolvedModules) > 0 || Lambda.count(this.typeResolutionsInFile) > 0) {
				knownSymlinks.SetSymlinksFromResolutions(this.ForEachResolvedModule, this.ForEachResolvedTypeReferenceDirective);
			}

			// Check other dependencies for symlinks
			final seenPackageJsons = new Set<Path>();
			for (filePath => meta in this.sourceFileMetaDatas) {
				if (meta.PackageJsonDirectory == ""
					|| !this.SourceFileMayBeEmitted(this.GetSourceFileByPath(filePath), false)
					|| !seenPackageJsons.AddIfAbsent(this.toPath(meta.PackageJsonDirectory))) {
					continue;
				}
				final packageJsonName = Tspath.CombinePaths(meta.PackageJsonDirectory, "package.json");
				final info = this.GetPackageJsonInfo(packageJsonName);
				if (info.GetContents() == null) {
					continue;
				}

				for (dep in info.GetContents().GetRuntimeDependencyNames().Keys().keys()) {
					// Skip work in common case: we already saved a symlink for this package directory
					// in the node_modules adjacent to this package.json
					final possibleDirectoryPath = this.toPath(Tspath.CombinePaths(meta.PackageJsonDirectory, "node_modules", dep));
					if (knownSymlinks.HasDirectory(possibleDirectoryPath)) {
						continue;
					}
					if (!StringTools.startsWith(dep, "@types")) {
						final possibleTypesDirectoryPath = this.toPath(Tspath.CombinePaths(meta.PackageJsonDirectory, "node_modules", Module.GetTypesPackageName(dep)));
						if (knownSymlinks.HasDirectory(possibleTypesDirectoryPath)) {
							continue;
						}
					}

					final packageResolution = this.resolver.ResolvePackageDirectory(dep, packageJsonName, Core.ResolutionModeCommonJS, null);
					if (packageResolution.IsResolved()) {
						knownSymlinks.ProcessResolution(Tspath.CombinePaths(packageResolution.OriginalPath, "package.json"),
							Tspath.CombinePaths(packageResolution.ResolvedFileName, "package.json"));
					}
				}
			}
			return knownSymlinks;
		});
	}

	public function ResolveModuleName(moduleName:std.String, containingFile:std.String, resolutionMode:ResolutionMode):ResolvedModule {
		final resolved = this.resolver.ResolveModuleName(moduleName, containingFile, resolutionMode, null).a;
		return resolved;
	}

	public function ForEachResolvedModule(callback:(resolution:ResolvedModule, moduleName:std.String, mode:ResolutionMode, filePath:Path) -> Void,
			file:SourceFile):Void {
		Compiler.forEachResolution(this.resolvedModules, callback, file);
	}

	public function ForEachResolvedTypeReferenceDirective(callback:(resolution:ResolvedTypeReferenceDirective, moduleName:std.String, mode:ResolutionMode,
		filePath:Path) -> Void, file:SourceFile):Void {
		Compiler.forEachResolution(this.typeResolutionsInFile, callback, file);
	}
}

class WriteFileData {
	public var SourceMapUrlPos:Int = 0;
	public var BuildInfo:Any = null;
	public var Diagnostics:Array<Diagnostic> = null;
	public var SkippedDtsWrite:Bool = false;

	public function new() {}
}

typedef WriteFile = (fileName:std.String, text:std.String, data:WriteFileData) -> Null<Error>;

class EmitOptions {
	public var TargetSourceFile:SourceFile = null; // Single file to emit. If `nil`, emits all files
	public var EmitOnly:EmitOnly = EmitAll;
	public var WriteFile:WriteFile = null;

	public function new() {}
}

class EmitResult {
	public var EmitSkipped:Bool = false;
	public var Diagnostics:Array<Diagnostic> = null; // Contains declaration emit diagnostics
	public var EmittedFiles:Array<std.String> = null; // Array of files the compiler wrote to disk
	public var SourceMaps:Array<SourceMapEmitResult> = null; // Array of sourceMapData if compiler emitted sourcemaps

	public function new() {}
}

class SourceMapEmitResult {
	public var InputSourceFileNames:Array<std.String> = null; // Input source file (which one can use on program to get the file), 1:1 mapping with the sourceMap.sources list
	public var SourceMap:RawSourceMap = null;
	public var GeneratedFile:std.String = "";

	public function new() {}
}

interface ProgramLike {
	function Options():CompilerOptions;
	function GetSourceFile(path:std.String):SourceFile;
	function GetSourceFiles():Array<SourceFile>;
	function GetConfigFileParsingDiagnostics():Array<Diagnostic>;
	function GetSyntacticDiagnostics(ctx:Context, file:SourceFile):Array<Diagnostic>;
	function GetBindDiagnostics(ctx:Context, file:SourceFile):Array<Diagnostic>;
	function GetProgramDiagnostics():Array<Diagnostic>;
	function GetGlobalDiagnostics(ctx:Context):Array<Diagnostic>;
	function GetSemanticDiagnostics(ctx:Context, file:SourceFile):Array<Diagnostic>;
	function GetDeclarationDiagnostics(ctx:Context, file:SourceFile):Array<Diagnostic>;
	function GetSuggestionDiagnostics(ctx:Context, file:SourceFile):Array<Diagnostic>;
	function Emit(ctx:Context, options:EmitOptions):EmitResult;
	function CommonSourceDirectory():std.String;
	function IsSourceFileDefaultLibrary(path:Path):Bool;
	function Program():Program;
}
