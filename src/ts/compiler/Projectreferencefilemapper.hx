package ts.compiler;

// Port of projectreferencefilemapper.go.

@:allow(ts.compiler)
class ProjectReferenceFileMapper {
	var opts:ProgramOptions = null;
	var host:ResolutionHost = null;
	var loader:FileLoader = null; // Only present during populating the mapper and parsing, released after that

	var configToProjectReference:StringMap<ParsedCommandLine> = null; // All the resolved references needed
	var referencesInConfigFile:StringMap<Array<Path>> = null; // Map of config file to its references
	var sourceToProjectReference:StringMap<SourceOutputAndProjectReference> = null;
	var outputDtsToProjectReference:StringMap<SourceOutputAndProjectReference> = null;

	// Store all the realpath from dts in node_modules to source file from project reference needed during parsing so it can be used later
	var realpathDtsToSource:StringMap<SourceOutputAndProjectReference> = new StringMap(); // PORT: SyncMap → StringMap
	#if tshx_parallel
	final realpathMutex = new sys.thread.Mutex(); // PORT: hxmc (-D tshx-parallel)
	#end

	public function new() {}

	function getParseFileRedirect(file:HasFileName):std.String {
		if (this.opts.canUseProjectReferenceSource()) {
			// Map to source file from project reference
			var source = this.getProjectReferenceFromOutputDts(file.Path());
			if (source == null) {
				source = this.getSourceToDtsIfSymlink(file);
			}
			if (source != null) {
				return source.Source;
			}
		} else {
			// Map to dts file from project reference
			final output = this.getProjectReferenceFromSource(file.Path());
			if (output != null && output.OutputDts != "") {
				return output.OutputDts;
			}
		}
		return "";
	}

	function getResolvedProjectReferences():Array<ParsedCommandLine> {
		if (this.opts.Config.ConfigFile == null) {
			return null;
		}
		final refs = this.referencesInConfigFile == null ? null : this.referencesInConfigFile.get(this.opts.Config.ConfigFile.SourceFile.Path());
		final ok = this.referencesInConfigFile != null && this.referencesInConfigFile.exists(this.opts.Config.ConfigFile.SourceFile.Path());
		var result:Array<ParsedCommandLine> = null;
		if (ok) {
			result = [];
			if (refs != null) {
				for (refPath in refs) {
					final refConfig = this.configToProjectReference.get(refPath);
					result.push(refConfig);
				}
			}
		}
		return result;
	}

	function getProjectReferenceFromSource(path:Path):SourceOutputAndProjectReference {
		return this.sourceToProjectReference == null ? null : this.sourceToProjectReference.get(path);
	}

	function getProjectReferenceFromOutputDts(path:Path):SourceOutputAndProjectReference {
		return this.outputDtsToProjectReference == null ? null : this.outputDtsToProjectReference.get(path);
	}

	function isSourceFromProjectReference(path:Path):Bool {
		return this.opts.canUseProjectReferenceSource() && this.getProjectReferenceFromSource(path) != null;
	}

	function getCompilerOptionsForFile(file:HasFileName):CompilerOptions {
		final redirect = this.getRedirectParsedCommandLineForResolution(file);
		return Module.GetCompilerOptionsWithRedirect(this.opts.Config.CompilerOptions(), redirect);
	}

	function getRedirectParsedCommandLineForResolution(file:HasFileName):ParsedCommandLine {
		final redirect = this.getRedirectForResolution(file).a;
		return redirect;
	}

	// PORT: (*tsoptions.ParsedCommandLine, string) → Pair
	function getRedirectForResolution(file:HasFileName):Pair<ParsedCommandLine, std.String> {
		final path = file.Path();
		// Check if outputdts of source file from project reference
		final output = this.getProjectReferenceFromSource(path);
		if (output != null) {
			return new Pair(output.Resolved, output.Source);
		}

		// Source file from project reference
		final resultFromDts = this.getProjectReferenceFromOutputDts(path);
		if (resultFromDts != null) {
			return new Pair(resultFromDts.Resolved, resultFromDts.Source);
		}

		final realpathDtsToSource = this.getSourceToDtsIfSymlink(file);
		if (realpathDtsToSource != null) {
			return new Pair(realpathDtsToSource.Resolved, realpathDtsToSource.Source);
		}
		return new Pair(null, file.FileName());
	}

	// PORT: (*tsoptions.ParsedCommandLine, bool) → ValueOk
	function getResolvedReferenceFor(path:Path):ValueOk<ParsedCommandLine> {
		if (this.configToProjectReference == null || !this.configToProjectReference.exists(path))
			return new ValueOk(null, false);
		return new ValueOk(this.configToProjectReference.get(path), true);
	}

	function rangeResolvedProjectReference(f:(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int) -> Bool):Bool {
		if (this.opts.Config.ConfigFile == null) {
			return false;
		}
		final seenRef = new Set<Path>();
		seenRef.Add(this.opts.Config.ConfigFile.SourceFile.Path());
		final refs = this.referencesInConfigFile == null ? null : this.referencesInConfigFile.get(this.opts.Config.ConfigFile.SourceFile.Path());
		return this.rangeResolvedReferenceWorker(refs, f, this.opts.Config, seenRef);
	}

	function rangeResolvedReferenceWorker(references:Array<Path>, f:(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int) -> Bool,
			parent:ParsedCommandLine, seenRef:Set<Path>):Bool {
		if (references == null)
			return true;
		for (index in 0...references.length) {
			final path = references[index];
			if (!seenRef.AddIfAbsent(path)) {
				continue;
			}
			final config = this.configToProjectReference.get(path);
			if (!f(path, config, parent, index)) {
				return false;
			}
			if (!this.rangeResolvedReferenceWorker(this.referencesInConfigFile.get(path), f, config, seenRef)) {
				return false;
			}
		}
		return true;
	}

	function rangeResolvedProjectReferenceInChildConfig(childConfig:ParsedCommandLine,
			f:(path:Path, config:ParsedCommandLine, parent:ParsedCommandLine, index:Int) -> Bool):Bool {
		if (childConfig == null || childConfig.ConfigFile == null) {
			return false;
		}
		final seenRef = new Set<Path>();
		seenRef.Add(childConfig.ConfigFile.SourceFile.Path());
		final refs = this.referencesInConfigFile == null ? null : this.referencesInConfigFile.get(childConfig.ConfigFile.SourceFile.Path());
		return this.rangeResolvedReferenceWorker(refs, f, this.opts.Config, seenRef);
	}

	function getSourceToDtsIfSymlink(file:HasFileName):SourceOutputAndProjectReference {
		#if tshx_parallel
		realpathMutex.acquire();
		final r = getSourceToDtsIfSymlinkLocked(file);
		realpathMutex.release();
		return r;
	}

	function getSourceToDtsIfSymlinkLocked(file:HasFileName):SourceOutputAndProjectReference {
		#end
		// If preserveSymlinks is true, module resolution wont jump the symlink
		// but the resolved real path may be the .d.ts from project reference
		// Note:: Currently we try the real path only if the
		// file is from node_modules to avoid having to run real path on all file paths
		final path = file.Path();
		if (this.realpathDtsToSource.exists(path)) {
			return this.realpathDtsToSource.get(path);
		}
		if (this.loader != null && this.opts.Config.CompilerOptions().PreserveSymlinks == TSTrue) {
			final fileName = file.FileName();
			if (fileName.indexOf("/node_modules/") < 0) {
				this.realpathDtsToSource.set(path, null);
			} else {
				final realDeclarationPath = this.loader.toPath(this.host.FS().Realpath(fileName));
				if (realDeclarationPath == path) {
					this.realpathDtsToSource.set(path, null);
				} else {
					final realpathDtsToSource = this.getProjectReferenceFromOutputDts(realDeclarationPath);
					if (realpathDtsToSource != null) {
						this.realpathDtsToSource.set(path, realpathDtsToSource);
						return realpathDtsToSource;
					}
					this.realpathDtsToSource.set(path, null);
				}
			}
		}
		return null;
	}
}
