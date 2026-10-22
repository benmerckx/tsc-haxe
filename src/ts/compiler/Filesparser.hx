package ts.compiler;

// Port of filesparser.go (types and methods; the package-level funcs are in Compiler.hx).

@:allow(ts.compiler)
class ParseTask implements HasFileName {
	var normalizedFilePath:std.String = "";
	var path:Path = "";
	var file:SourceFile = null;
	var libFile:LibFile = null;
	var redirectedParseTask:ParseTask = null;
	var subTasks:Array<ParseTask> = null;
	var loaded:Bool = false;
	var startedSubTasks:Bool = false;
	var isForAutomaticTypeDirective:Bool = false;
	var includeReason:FileIncludeReason = null;
	var packageId:PackageId = new PackageId();

	var metadata:SourceFileMetaData = new SourceFileMetaData();
	var resolutionsInFile:ModeAwareCache<ResolvedModule> = null;
	var resolutionsTrace:Array<DiagAndArgs> = null;
	var typeResolutionsInFile:ModeAwareCache<ResolvedTypeReferenceDirective> = null;
	var typeResolutionsTrace:Array<DiagAndArgs> = null;
	var resolutionDiagnostics:Array<Diagnostic> = null;
	var processingDiagnostics:Array<ProcessingDiagnostic> = null;
	var importHelpersImportSpecifier:Node = null;
	var jsxRuntimeImportSpecifier:JsxRuntimeImportSpecifier = null;

	var increaseDepth:Bool = false;
	var elideOnDepth:Bool = false;

	var loadedTask:ParseTask = null;
	var allIncludeReasons:Array<FileIncludeReason> = null;

	public function new() {}

	public function FileName():std.String {
		return this.normalizedFilePath;
	}

	public function Path():Path {
		return this.path;
	}

	function load(loader:FileLoader):Void {
		this.loaded = true;
		if (this.isForAutomaticTypeDirective) {
			this.loadAutomaticTypeDirectives(loader);
			return;
		}
		var done:() -> Void = null;
		if (loader.opts.Tracing != null) {
			final args = new StringMap<Any>();
			args.set("fileName", this.normalizedFilePath);
			done = loader.opts.Tracing.Push(PhaseProgram, "findSourceFile", args, false);
		}
		try {
			this.loadWorker(loader);
		} catch (e:Dynamic) {
			if (done != null)
				done();
			throw e;
		}
		if (done != null)
			done();
	}

	// PORT: body of load after the tracing defer (split off for the defer).
	function loadWorker(loader:FileLoader):Void {
		final redirect = loader.projectReferenceFileMapper.getParseFileRedirect(this);
		if (redirect != "") {
			this.redirect(loader, redirect);
			return;
		}

		if (Tspath.HasExtension(this.normalizedFilePath)) {
			final compilerOptions = loader.opts.Config.CompilerOptions();
			final allowNonTsExtensions = compilerOptions.AllowNonTsExtensions.IsTrue();
			if (!allowNonTsExtensions) {
				final canonicalFileName = Tspath.GetCanonicalFileName(this.normalizedFilePath, loader.opts.Host.FS().UseCaseSensitiveFileNames());
				if (!loader.isSupportedExtension(canonicalFileName)) {
					if (this.processingDiagnostics == null)
						this.processingDiagnostics = [];
					if (Tspath.HasJSFileExtension(canonicalFileName)) {
						this.processingDiagnostics.push(new ProcessingDiagnostic(processingDiagnosticKindExplainingFileInclude,
							new IncludeExplainingDiagnostic("", this.includeReason, Diagnostics.File_0_is_a_JavaScript_file_Did_you_mean_to_enable_the_allowJs_option,
								[this.normalizedFilePath])));
					} else {
						this.processingDiagnostics.push(new ProcessingDiagnostic(processingDiagnosticKindExplainingFileInclude,
							new IncludeExplainingDiagnostic("", this.includeReason,
								Diagnostics.File_0_has_an_unsupported_extension_The_only_supported_extensions_are_1,
								[this.normalizedFilePath, "'" + Core.Flatten(loader.supportedExtensions).join("', '") + "'"])));
					}
					return;
				}
			}
		}

		#if tshx_parallel
		loader.countMutex.acquire(); // PORT: hxmc (-D tshx-parallel) — atomic.Int32.Add
		loader.totalFileCount += 1;
		if (this.libFile != null)
			loader.libFileCount += 1;
		loader.countMutex.release();
		#else
		loader.totalFileCount += 1;
		#end
		if (this.libFile != null) {
			#if !tshx_parallel
			loader.libFileCount += 1;
			#end
			// Default lib files are all scripts; we can safely skip looking up their package.json
			// to avoid adding spurious lookups to file watcher tracking.
			final m = new SourceFileMetaData();
			m.ImpliedNodeFormat = ModuleKindCommonJS;
			this.metadata = m;
		} else {
			this.metadata = loader.loadSourceFileMetaData(this.normalizedFilePath);
		}

		final file = loader.parseSourceFile(this);
		if (file == null) {
			return;
		}

		this.file = file;
		this.subTasks = [];

		final compilerOptions = loader.opts.Config.CompilerOptions();
		if (!compilerOptions.NoResolve.IsTrue()) {
			if (file.ReferencedFiles != null) {
				for (index in 0...file.ReferencedFiles.length) {
					final ref = file.ReferencedFiles[index];
					final r = loader.resolveTripleslashPathReference(ref.FileName, file.FileName(), index);
					final resolvedRef = r.a, processingDiagnostic = r.b;
					if (processingDiagnostic != null) {
						if (this.processingDiagnostics == null)
							this.processingDiagnostics = [];
						this.processingDiagnostics.push(processingDiagnostic);
						continue;
					}
					this.addSubTask(resolvedRef, null);
				}
			}

			loader.resolveTypeReferenceDirectives(this);
		}

		if (compilerOptions.NoLib != TSTrue) {
			if (file.LibReferenceDirectives != null) {
				for (index in 0...file.LibReferenceDirectives.length) {
					final lib = file.LibReferenceDirectives[index];
					final includeReason = new FileIncludeReason(fileIncludeKindLibReferenceDirective, new ReferencedFileData(this.path, index));
					final n = Tsoptions.GetLibFileName(lib.FileName);
					if (n.ok) {
						final libFile = loader.pathForLibFile(n.value);
						final r = new ResolvedRef();
						r.fileName = libFile.path;
						r.includeReason = includeReason;
						this.addSubTask(r, libFile);
					} else {
						if (this.processingDiagnostics == null)
							this.processingDiagnostics = [];
						this.processingDiagnostics.push(new ProcessingDiagnostic(processingDiagnosticKindUnknownReference, includeReason));
					}
				}
			}
		}

		loader.resolveImportsAndModuleAugmentations(this);
	}

	function redirect(loader:FileLoader, fileName:std.String):Void {
		this.redirectedParseTask = new ParseTask();
		this.redirectedParseTask.normalizedFilePath = Tspath.NormalizePath(fileName);
		this.redirectedParseTask.libFile = this.libFile;
		this.redirectedParseTask.includeReason = this.includeReason;
		// increaseDepth and elideOnDepth are not copied to redirects, otherwise their depth would be double counted.
		this.subTasks = [this.redirectedParseTask];
	}

	function loadAutomaticTypeDirectives(loader:FileLoader):Void {
		var done:() -> Void = null;
		if (loader.opts.Tracing != null) {
			done = loader.opts.Tracing.Push(PhaseProgram, "processTypeReferences", null, false);
		}
		try {
			final r = loader.resolveAutomaticTypeDirectives(this.normalizedFilePath);
			this.typeResolutionsInFile = r.typeResolutionsInFile;
			this.typeResolutionsTrace = r.typeResolutionsTrace;
			if (r.pDiagnostics != null) {
				if (this.processingDiagnostics == null)
					this.processingDiagnostics = [];
				for (d in r.pDiagnostics)
					this.processingDiagnostics.push(d);
			}
			if (r.toParse != null) {
				for (typeResolution in r.toParse) {
					this.addSubTask(typeResolution, null);
				}
			}
		} catch (e:Dynamic) {
			if (done != null)
				done();
			throw e;
		}
		if (done != null)
			done();
	}

	function addSubTask(ref:ResolvedRef, libFile:LibFile):Void {
		final normalizedFilePath = Tspath.NormalizePath(ref.fileName);
		final subTask = new ParseTask();
		subTask.normalizedFilePath = normalizedFilePath;
		subTask.libFile = libFile;
		subTask.increaseDepth = ref.increaseDepth;
		subTask.elideOnDepth = ref.elideOnDepth;
		subTask.includeReason = ref.includeReason;
		subTask.packageId = ref.packageId;
		if (this.subTasks == null)
			this.subTasks = [];
		this.subTasks.push(subTask);
	}
}

@:allow(ts.compiler)
class ResolvedRef {
	var fileName:std.String = "";
	var increaseDepth:Bool = false;
	var elideOnDepth:Bool = false;
	var includeReason:FileIncludeReason = null;
	var packageId:PackageId = new PackageId();

	public function new() {}
}

@:allow(ts.compiler)
class FilesParser {
	var wg:WorkGroup = null;
	var taskDataByPath:StringMap<ParseTaskData> = new StringMap(); // PORT: SyncMap[tspath.Path, *parseTaskData] → StringMap
	#if tshx_parallel
	final taskDataMutex = new sys.thread.Mutex();
	#end
	var maxDepth:Int = 0;

	public function new() {}

	function parse(loader:FileLoader, tasks:Array<ParseTask>):Void {
		this.start(loader, tasks, 0);
		this.wg.RunAndWait();
	}

	function start(loader:FileLoader, tasks:Array<ParseTask>, depth:Int):Void {
		if (tasks == null)
			return;
		for (i in 0...tasks.length) {
			final task = tasks[i];
			task.path = loader.toPath(task.normalizedFilePath);
			final candidate = Compiler.getParseTaskData(task);
			#if tshx_parallel
			this.taskDataMutex.acquire(); // PORT: hxmc (-D tshx-parallel) — SyncMap.LoadOrStore
			#end
			var data = this.taskDataByPath.get(task.path);
			final loaded = data != null;
			if (loaded) {
				Compiler.putParseTaskData(candidate);
			} else {
				data = candidate;
				this.taskDataByPath.set(task.path, data);
			}
			#if tshx_parallel
			this.taskDataMutex.release();
			#end

			final run = function() {
				// PORT: data.mu dropped (single-threaded)
				var startSubtasks = false;
				if (loaded) {
					final existingTask = data.tasks.get(task.normalizedFilePath);
					if (existingTask != null) {
						tasks[i].loadedTask = existingTask;
					} else {
						data.tasks.set(task.normalizedFilePath, task);
						// This is new task for file name - so load subtasks if there was loading for any other casing
						startSubtasks = data.startedSubTasks;
					}
				}

				// Propagate packageId to data if we have one and data doesn't yet
				if (data.packageId.Name == "" && task.packageId.Name != "") {
					data.packageId = task.packageId;
				}

				final currentDepth = Core.IfElse(task.increaseDepth, depth + 1, depth);
				if (currentDepth < data.lowestDepth) {
					// If we're seeing this task at a lower depth than before,
					// reprocess its subtasks to ensure they are loaded.
					data.lowestDepth = currentDepth;
					startSubtasks = true;
					data.startedSubTasks = true;
				}

				if (task.elideOnDepth && currentDepth > this.maxDepth) {
					return;
				}

				// PORT: Go map iteration order is random; StringMap order is used.
				for (taskByFileName in data.tasks) {
					var loadSubTasks = startSubtasks;
					if (!taskByFileName.loaded) {
						taskByFileName.load(loader);
						if (taskByFileName.redirectedParseTask != null) {
							// Always load redirected task
							loadSubTasks = true;
							data.startedSubTasks = true;
						}
					}
					if (!taskByFileName.startedSubTasks && loadSubTasks) {
						taskByFileName.startedSubTasks = true;
						this.start(loader, taskByFileName.subTasks, data.lowestDepth);
					}
				}
			};
			this.wg.Queue(function() {
				#if tshx_parallel
				data.mu.acquire(); // PORT: hxmc (-D tshx-parallel) — data.mu.Lock(); defer data.mu.Unlock()
				#end
				#if tshx_parallel
				try {
					run();
				} catch (e:Dynamic) {
					data.mu.release();
					throw e;
				}
				data.mu.release();
				#else
				run();
				#end
			});
		}
	}

	function getProcessedFiles(loader:FileLoader):ProcessedFiles {
		final totalFileCount = loader.totalFileCount;
		final libFileCount = loader.libFileCount;

		var missingFiles:Array<std.String> = null;
		var duplicateSourceFiles:Array<DuplicateSourceFile> = null;
		final files:Array<SourceFile> = [];
		final libFiles:Array<SourceFile> = []; // totalFileCount here since we append files to it later to construct the final list

		final filesByPath = new StringMap<SourceFile>();
		// stores 'filename -> file association' ignoring case
		// used to track cases when two file names differ only in casing
		var tasksSeenByNameIgnoreCase:StringMap<ParseTask> = null;
		if (loader.comparePathsOptions.UseCaseSensitiveFileNames) {
			tasksSeenByNameIgnoreCase = new StringMap();
		}

		final includeProcessor = new IncludeProcessor();
		includeProcessor.fileIncludeReasons = new StringMap();
		var outputFileToProjectReferenceSource:StringMap<std.String> = null;
		if (!loader.opts.canUseProjectReferenceSource()) {
			outputFileToProjectReferenceSource = new StringMap();
		}
		final resolvedModules = new StringMap<ModeAwareCache<ResolvedModule>>();
		final typeResolutionsInFile = new StringMap<ModeAwareCache<ResolvedTypeReferenceDirective>>();
		final sourceFileMetaDatas = new StringMap<SourceFileMetaData>();
		var jsxRuntimeImportSpecifiers:StringMap<JsxRuntimeImportSpecifier> = null;
		var importHelpersImportSpecifiers:StringMap<Node> = null;
		final sourceFilesFoundSearchingNodeModules = new Set<Path>();
		final libFilesMap = new StringMap<LibFile>();

		var redirectTargetsMap:StringMap<Array<std.String>> = null;
		var redirectFilesByPath:StringMap<RedirectsFile> = null;
		var redirectFilesCount = 0; // PORT: len(redirectFilesByPath)
		var packageIdToSourceFile:StringMap<SourceFile> = null; // PORT: map[module.PackageId] → key Compiler.packageIdKey
		if (!loader.opts.Config.CompilerOptions().DeduplicatePackages.IsFalse()) {
			redirectTargetsMap = new StringMap();
			packageIdToSourceFile = new StringMap();
		}

		// recordedDuplicates tracks, per task data, the set of file-name casings that
		// have already been recorded in duplicateSourceFiles. A file that is reached
		// from multiple import sites is walked once per site, but each distinct casing
		// is only parsed and acquired in the parse cache once. Recording the same casing
		// as a duplicate more than once would cause it to be released more times than it
		// was acquired when the snapshot is disposed, leaving a dangling cache entry that
		// panics the next time it is referenced.
		var recordedDuplicates:IdentityMap<ParseTaskData, Set<std.String>> = null;
		var collectFiles:(tasks:Array<ParseTask>, seen:IdentityMap<ParseTaskData, std.String>) -> Void = null;
		collectFiles = function(tasks:Array<ParseTask>, seen:IdentityMap<ParseTaskData, std.String>) {
			for (task0 in tasks) {
				var task = task0;
				final includeReason = task.includeReason;
				// Exclude automatic type directive tasks from include reason processing,
				// as these are internal implementation details and should not contribute
				// to the reasons for including files.
				if (task.redirectedParseTask == null && !task.isForAutomaticTypeDirective) {
					if (task.loadedTask != null) {
						task = task.loadedTask;
					}
					this.addIncludeReason(includeProcessor, task, includeReason);
				}
				final data = this.taskDataByPath.get(task.path);
				if (!task.loaded) {
					continue;
				}

				// ensure we only walk each task once
				if (seen.exists(data)) {
					final checkedName = seen.get(data);
					if (task.file != null && checkedName != task.normalizedFilePath) {
						if (recordedDuplicates == null) {
							recordedDuplicates = new IdentityMap();
						}
						var dups = recordedDuplicates.get(data);
						if (dups == null) {
							dups = new Set<std.String>();
							recordedDuplicates.set(data, dups);
						}
						if (dups.AddIfAbsent(task.normalizedFilePath)) {
							final d = new DuplicateSourceFile();
							d.ParseOptions = task.file.ParseOptions();
							d.ScriptKind = task.file.ScriptKind;
							if (duplicateSourceFiles == null)
								duplicateSourceFiles = [];
							duplicateSourceFiles.push(d);
						}
					}
					if (!loader.opts.Config.CompilerOptions().ForceConsistentCasingInFileNames.IsFalse()) {
						// Check if it differs only in drive letters its ok to ignore that error:
						final checkedAbsolutePath = Tspath.GetNormalizedAbsolutePathWithoutRoot(checkedName, loader.comparePathsOptions.CurrentDirectory);
						final inputAbsolutePath = Tspath.GetNormalizedAbsolutePathWithoutRoot(task.normalizedFilePath, loader.comparePathsOptions.CurrentDirectory);
						if (checkedAbsolutePath != inputAbsolutePath) {
							includeProcessor.addProcessingDiagnosticsForFileCasing(task.path, checkedName, task.normalizedFilePath, includeReason);
						}
					}
					continue;
				} else {
					seen.set(data, task.normalizedFilePath);
				}

				if (tasksSeenByNameIgnoreCase != null) {
					final pathLowerCase = Tspath.ToFileNameLowerCase(task.path);
					final taskByIgnoreCase = tasksSeenByNameIgnoreCase.get(pathLowerCase);
					if (taskByIgnoreCase != null) {
						includeProcessor.addProcessingDiagnosticsForFileCasing(taskByIgnoreCase.path, taskByIgnoreCase.normalizedFilePath,
							task.normalizedFilePath, includeReason);
					} else {
						tasksSeenByNameIgnoreCase.set(pathLowerCase, task);
					}
				}

				if (task.typeResolutionsTrace != null) {
					for (trace in task.typeResolutionsTrace) {
						loader.opts.Host.Trace(trace.Message, ...(trace.Args == null ? [] : trace.Args));
					}
				}
				if (task.resolutionsTrace != null) {
					for (trace in task.resolutionsTrace) {
						loader.opts.Host.Trace(trace.Message, ...(trace.Args == null ? [] : trace.Args));
					}
				}

				final file = task.file;
				if (packageIdToSourceFile != null && data.packageId.Name != "") {
					final pkey = Compiler.packageIdKey(data.packageId);
					final packageIdFile = packageIdToSourceFile.get(pkey);
					if (packageIdToSourceFile.exists(pkey)) {
						if (file != null) {
							// Package deduplication keeps the first package instance in the
							// program, but we still parsed this file and acquired it through
							// the host, so snapshot disposal must release that extra owner.
							final d = new DuplicateSourceFile();
							d.ParseOptions = file.ParseOptions();
							d.ScriptKind = file.ScriptKind;
							if (duplicateSourceFiles == null)
								duplicateSourceFiles = [];
							duplicateSourceFiles.push(d);
						}
						var targets = redirectTargetsMap.get(packageIdFile.Path());
						if (targets == null) {
							targets = [];
							redirectTargetsMap.set(packageIdFile.Path(), targets);
						}
						targets.push(task.normalizedFilePath);
						if (redirectFilesByPath == null) {
							redirectFilesByPath = new StringMap();
						}
						final rf = new RedirectsFile();
						rf.index = files.length + redirectFilesCount;
						rf.fileName = task.normalizedFilePath;
						rf.path = task.path;
						rf.target = packageIdFile.Path();
						if (!redirectFilesByPath.exists(task.path))
							redirectFilesCount++;
						redirectFilesByPath.set(task.path, rf);
						filesByPath.set(task.path, packageIdFile);
						if (data.lowestDepth > 0) {
							sourceFilesFoundSearchingNodeModules.Add(task.path);
						}
						continue;
					} else if (file != null) {
						packageIdToSourceFile.set(pkey, file);
					}
				}

				final subTasks = task.subTasks;
				if (Core.len(subTasks) > 0) {
					collectFiles(subTasks, seen);
				}

				// Exclude automatic type directive tasks from include reason processing,
				// as these are internal implementation details and should not contribute
				// to the reasons for including files.
				if (task.redirectedParseTask != null) {
					if (!loader.opts.canUseProjectReferenceSource()) {
						outputFileToProjectReferenceSource.set(task.redirectedParseTask.path, task.FileName());
					}
					continue;
				}

				if (task.isForAutomaticTypeDirective) {
					typeResolutionsInFile.set(task.path, task.typeResolutionsInFile);
					if (Core.len(task.processingDiagnostics) > 0) {
						includeProcessor.addProcessingDiagnostic(...task.processingDiagnostics);
					}
					continue;
				}

				final path = task.path;

				if (Core.len(task.processingDiagnostics) > 0) {
					includeProcessor.addProcessingDiagnostic(...task.processingDiagnostics);
				}

				if (file == null) {
					if (missingFiles == null)
						missingFiles = [];
					missingFiles.push(task.normalizedFilePath);
					continue;
				}

				if (task.libFile != null) {
					libFiles.push(file);
					libFilesMap.set(path, task.libFile);
				} else {
					files.push(file);
				}
				filesByPath.set(path, file);
				resolvedModules.set(path, task.resolutionsInFile);
				typeResolutionsInFile.set(path, task.typeResolutionsInFile);
				sourceFileMetaDatas.set(path, task.metadata);

				if (task.jsxRuntimeImportSpecifier != null) {
					if (jsxRuntimeImportSpecifiers == null) {
						jsxRuntimeImportSpecifiers = new StringMap();
					}
					jsxRuntimeImportSpecifiers.set(path, task.jsxRuntimeImportSpecifier);
				}
				if (task.importHelpersImportSpecifier != null) {
					if (importHelpersImportSpecifiers == null) {
						importHelpersImportSpecifiers = new StringMap();
					}
					importHelpersImportSpecifiers.set(path, task.importHelpersImportSpecifier);
				}
				if (data.lowestDepth > 0) {
					sourceFilesFoundSearchingNodeModules.Add(path);
				}
			}
		};

		collectFiles(loader.rootTasks, new IdentityMap());
		loader.sortLibs(libFiles);

		final allFiles = libFiles.concat(files);
		if (redirectFilesByPath != null) {
			for (redirectFile in redirectFilesByPath) {
				redirectFile.index += libFiles.length;
			}
		}

		final keys:Array<std.String> = [for (k in loader.pathForLibFileResolutions.keys()) k];
		Slices.SortFunc(keys, Strings.Compare);
		for (key in keys) {
			final value = loader.pathForLibFileResolutions.get(key);
			final cache = new ModeAwareCache<ResolvedModule>();
			cache.set(new ModeAwareCacheKey(value.libraryName, ModuleKindCommonJS).Key(), value.resolution);
			resolvedModules.set(key, cache);
			if (value.trace != null) {
				for (trace in value.trace) {
					loader.opts.Host.Trace(trace.Message, ...(trace.Args == null ? [] : trace.Args));
				}
			}
		}

		final r = new ProcessedFiles();
		r.finishedProcessing = true;
		r.resolver = loader.resolver;
		r.files = allFiles;
		r.duplicateSourceFiles = duplicateSourceFiles;
		r.filesByPath = filesByPath;
		r.projectReferenceFileMapper = loader.projectReferenceFileMapper;
		r.resolvedModules = resolvedModules;
		r.typeResolutionsInFile = typeResolutionsInFile;
		r.sourceFileMetaDatas = sourceFileMetaDatas;
		r.jsxRuntimeImportSpecifiers = jsxRuntimeImportSpecifiers;
		r.importHelpersImportSpecifiers = importHelpersImportSpecifiers;
		r.sourceFilesFoundSearchingNodeModules = sourceFilesFoundSearchingNodeModules;
		r.libFiles = libFilesMap;
		r.missingFiles = missingFiles;
		r.includeProcessor = includeProcessor;
		r.outputFileToProjectReferenceSource = outputFileToProjectReferenceSource;
		r.redirectTargetsMap = redirectTargetsMap;
		r.redirectFilesByPath = redirectFilesByPath;
		return r;
	}

	function addIncludeReason(includeProcessor:IncludeProcessor, task:ParseTask, reason:FileIncludeReason):Void {
		if (task.redirectedParseTask != null) {
			this.addIncludeReason(includeProcessor, task.redirectedParseTask, reason);
		} else if (task.loaded) {
			final existing = includeProcessor.fileIncludeReasons.get(task.path);
			if (existing != null) {
				existing.push(reason);
			} else {
				includeProcessor.fileIncludeReasons.set(task.path, [reason]);
			}
		}
	}
}

@:allow(ts.compiler)
class ParseTaskData {
	// map of tasks by file casing
	var tasks:StringMap<ParseTask> = new StringMap();
	// PORT: mu sync.Mutex dropped (single-threaded)
	#if tshx_parallel
	final mu = new sys.thread.Mutex(); // PORT: hxmc (-D tshx-parallel)
	#end
	var lowestDepth:Int = 0;
	var startedSubTasks:Bool = false;
	var packageId:PackageId = new PackageId();

	public function new() {}
}
