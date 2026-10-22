package ts.modulespecifiers;

import ts.ast.Ast.HasFileName;
import ts.ast.Ast.SourceFile;
import ts.ast.Ast.StringLiteralLike;
import ts.ast.Ast.Node;
import ts.outputpaths.Outputpaths.OutputPathsHost;
import ts.symlinks.Knownsymlinks.KnownSymlinks;
import ts.module.Types.ResolvedModule;

// Port of types.go.

// PORT: Go's structural interface includes Path()/FileName(), i.e. ast.HasFileName; declared as
// `extends HasFileName` so values can be passed where Go converts them to ast.HasFileName.
interface SourceFileForSpecifierGeneration extends HasFileName {
	function Imports():Array<StringLiteralLike>;
	function IsJS():Bool;
}

// PORT: *ast.SourceFile satisfies SourceFileForSpecifierGeneration (and ast.HasFileName)
// structurally in Go; Haxe needs an adapter (PORTING.md §3), cached per SourceFile.
class SourceFileAdapter implements SourceFileForSpecifierGeneration {
	public final File:SourceFile;

	function new(file:SourceFile) {
		this.File = file;
	}

	static final cache = new IdentityMap<SourceFile, SourceFileAdapter>();
	#if tshx_parallel
	static final cacheMutex = new sys.thread.Mutex();
	#end

	public static function Of(file:SourceFile):SourceFileAdapter {
		if (file == null) {
			return null;
		}
		#if tshx_parallel
		cacheMutex.acquire(); // PORT: hxmc (-D tshx-parallel)
		#end
		var a = cache.get(file);
		if (a == null) {
			a = new SourceFileAdapter(file);
			cache.set(file, a);
		}
		#if tshx_parallel
		cacheMutex.release();
		#end
		return a;
	}

	public function FileName():String {
		return File.FileName();
	}

	public function Path():ts.tspath.Path {
		return File.Path();
	}

	public function Imports():Array<StringLiteralLike> {
		return File.Imports();
	}

	public function IsJS():Bool {
		return File.IsJS();
	}
}

interface CheckerShape {
	function GetSymbolAtLocation(node:Node):ts.ast.Symbol;
	function GetAliasedSymbol(symbol:ts.ast.Symbol):ts.ast.Symbol;
}

enum abstract ResultKind(Int) from Int to Int {
	var ResultKindNone = 0;
	var ResultKindNodeModules = 1;
	var ResultKindPaths = 2;
	var ResultKindRedirect = 3;
	var ResultKindRelative = 4;
	var ResultKindAmbient = 5;
}

// PORT: Go value struct, never mutated after construction → immutable class.
class ModulePath {
	public final FileName:String;
	public final IsInNodeModules:Bool;
	public final IsRedirect:Bool;

	public function new(FileName:String = "", IsInNodeModules:Bool = false, IsRedirect:Bool = false) {
		this.FileName = FileName;
		this.IsInNodeModules = IsInNodeModules;
		this.IsRedirect = IsRedirect;
	}
}

// PORT: Go's interface lists CommonSourceDirectory/GetCurrentDirectory/UseCaseSensitiveFileNames and
// is passed to outputpaths as an OutputPathsHost; declared as `extends OutputPathsHost`.
interface ModuleSpecifierGenerationHost extends OutputPathsHost {
	// GetModuleResolutionCache() any // !!! TODO: adapt new resolution cache model
	function GetSymlinkCache():KnownSymlinks;
	// GetFileIncludeReasons() any // !!! TODO: adapt new resolution cache model
	function GetGlobalTypingsCacheLocation():String;

	function GetProjectReferenceFromSource(path:ts.tspath.Path):ts.tsoptions.Parsedcommandline.SourceOutputAndProjectReference;
	function GetRedirectTargets(path:ts.tspath.Path):Array<String>;
	function GetSourceOfProjectReferenceIfOutputIncluded(file:HasFileName):String;

	function FileExists(path:String):Bool;

	function GetNearestAncestorDirectoryWithPackageJson(dirname:String):String;
	function GetPackageJsonInfo(pkgJsonPath:String):ts.packagejson.Cache.InfoCacheEntry;
	function GetDefaultResolutionModeForFile(file:HasFileName):ResolutionMode;
	function GetResolvedModuleFromModuleSpecifier(file:HasFileName, moduleSpecifier:StringLiteralLike):ResolvedModule;
	function GetModeForUsageLocation(file:HasFileName, moduleSpecifier:StringLiteralLike):ResolutionMode;
}

enum abstract ImportModuleSpecifierPreference(String) from String to String {
	var ImportModuleSpecifierPreferenceNone = ""; // !!!
	var ImportModuleSpecifierPreferenceShortest = "shortest";
	var ImportModuleSpecifierPreferenceProjectRelative = "project-relative";
	var ImportModuleSpecifierPreferenceRelative = "relative";
	var ImportModuleSpecifierPreferenceNonRelative = "non-relative";
}

enum abstract ImportModuleSpecifierEndingPreference(String) from String to String {
	var ImportModuleSpecifierEndingPreferenceNone = ""; // !!!
	var ImportModuleSpecifierEndingPreferenceAuto = "auto";
	var ImportModuleSpecifierEndingPreferenceMinimal = "minimal";
	var ImportModuleSpecifierEndingPreferenceIndex = "index";
	var ImportModuleSpecifierEndingPreferenceJs = "js";
}

// PORT: Go value struct passed by value and never mutated → plain class.
class UserPreferences {
	public var ImportModuleSpecifierPreference:ImportModuleSpecifierPreference = ImportModuleSpecifierPreferenceNone;
	public var ImportModuleSpecifierEnding:ImportModuleSpecifierEndingPreference = ImportModuleSpecifierEndingPreferenceNone;
	public var AutoImportSpecifierExcludeRegexes:Null<Array<String>> = null;

	public function new() {}
}

class ModuleSpecifierOptions {
	public var OverrideImportMode:ResolutionMode = ModuleKindNone;

	public function new(OverrideImportMode:ResolutionMode = ModuleKindNone) {
		this.OverrideImportMode = OverrideImportMode;
	}
}

enum abstract RelativePreferenceKind(Int) from Int to Int {
	var RelativePreferenceRelative = 0;
	var RelativePreferenceNonRelative = 1;
	var RelativePreferenceShortest = 2;
	var RelativePreferenceExternalNonRelative = 3;
}

enum abstract ModuleSpecifierEnding(Int) from Int to Int {
	var ModuleSpecifierEndingMinimal = 0;
	var ModuleSpecifierEndingIndex = 1;
	var ModuleSpecifierEndingJsExtension = 2;
	var ModuleSpecifierEndingTsExtension = 3;
}

enum abstract MatchingMode(Int) from Int to Int {
	var MatchingModeExact = 0;
	var MatchingModeDirectory = 1;
	var MatchingModePattern = 2;
}
