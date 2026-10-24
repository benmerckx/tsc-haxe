package ts.compiler;

import ts.vfs.vfstest.Vfstest;
import ts.compiler.Program.ProgramOptions;
import ts.bundled.Bundled;
import ts.tsoptions.Parsedcommandline.ParsedCommandLine;
import ts.core.Parsedoptions.ParsedOptions;
import ts.core.Compileroptions.CompilerOptions;
import ts.core.Compileroptions.ScriptTarget;
import ts.core.Tristate.Tristate;

class EmptyClassTest {
	public static function run() {
        T.run("TestEmptyJSSubtreeLists", () -> {
            final options = new CompilerOptions();
            options.AllowJs = Tristate.TSTrue;
            options.CheckJs = Tristate.TSFalse;
            final fs = Bundled.WrapFS(Vfstest.FromMap(["/input.js" => "f([], {}, function () {});"], true));
            final config = new ParsedCommandLine();
            config.ParsedConfig = new ParsedOptions();
            config.ParsedConfig.FileNames = ["/input.js"];
            config.ParsedConfig.CompilerOptions = options;
            final po = new ProgramOptions();
            po.Config = config;
            po.SingleThreaded = Tristate.TSTrue;
            po.Host = Compiler.NewCompilerHost("/", fs, Bundled.LibPath(), null, null);
            final program = Compiler.NewProgram(po);
            var file:ts.ast.Ast.SourceFile = null;
            for (sf in program.GetSourceFiles()) if (sf.FileName() == "/input.js") file = sf;
            final diagnostics = program.GetSyntacticDiagnostics(go.Context.Background(), file);
            T.eq(0, diagnostics == null ? 0 : diagnostics.length);
        });

		for (source in ["class Empty {}", "class Empty { constructor() {} }"]) {
			T.run("TestEmptyClassOverrideMembers/" + source, () -> {
				final fs = Bundled.WrapFS(Vfstest.FromMap(["/input.ts" => source], true));
				final options = new CompilerOptions();
				options.Target = ScriptTarget.ScriptTargetESNext;
				options.Strict = Tristate.TSTrue;
				final config = new ParsedCommandLine();
				config.ParsedConfig = new ParsedOptions();
				config.ParsedConfig.FileNames = ["/input.ts"];
				config.ParsedConfig.CompilerOptions = options;
				final po = new ProgramOptions();
				po.Config = config;
				po.SingleThreaded = Tristate.TSTrue;
				po.Host = Compiler.NewCompilerHost("/", fs, Bundled.LibPath(), null, null);
				final program = Compiler.NewProgram(po);
				var file:ts.ast.Ast.SourceFile = null;
				for (sf in program.GetSourceFiles()) if (sf.FileName() == "/input.ts") file = sf;
				final diagnostics = program.GetSemanticDiagnostics(go.Context.Background(), file);
				T.eq(0, diagnostics == null ? 0 : diagnostics.length);
			});
		}
	}

	static function main() {
		run();
		Sys.println(T.checks + " checks, " + T.failures + " failures");
		if (T.failures > 0) Sys.exit(1);
	}
}
