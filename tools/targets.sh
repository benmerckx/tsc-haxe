# Build and run one Haxe main on one target. Sourced by the gate scripts, the Makefile recipes,
# the launchers and tools/matrix.sh; the caller sets ROOT (repository root) and is in $ROOT.
#
# Targets and output paths for a main class M and an output base B (e.g. bin/scanner/dump):
#   js   B-js.js            node --stack-size=7000 $HX_NODE_OPTS B-js.js
#   cpp  B-cpp/<M>          native binary (hxcpp)
#   jvm  B-jvm.jar          $JAVA $JAVA_OPTS -jar B-jvm.jar
#   cs   B-cs/bin/<M>.dll   $DOTNET B-cs/bin/<M>.dll (hxcs sources in B-cs/src; dotnet build)
#   py   B-py.py            $PYTHON B-py.py (main() runs in a big-stack thread, see go.PyTarget)
#   hxmc B-hxmc             native binary (hxmc, Linux x86-64; HXMC_HOME: an hxmc checkout with bin/hxmc built)
#   hxmc-wasm B-hxmc.wasm   node --stack-size=7000 $HXMC_HOME/hxmc/bootstrap/wasi.mjs B-hxmc.wasm (hxmc, wasm32-wasi)
#   hxmc-par B-hxmc-par     native binary as hxmc, with -D tshx-parallel (go.Par's threads: TSHX_THREADS, default 4)
#   hxmc-wasmgc B-hxmc-gc.wasm  node --stack-size=7000 $HXMC_HOME/hxmc/bootstrap/wasmgc.mjs B-hxmc-gc.wasm (hxmc,
#                           -D hxmc.wasm-gc: the engine's collector; go.OsGc)
#
# hx_build <target> <main> <base> [haxe args...]   builds (quiet); exit status of the build
# hx_cmd <target> <main> <base>                    prints the command line that runs the build
# hx_targets_check <list>                          exits with a message on an unknown target name
. "$ROOT/tools/env.sh"

HX_ALL_TARGETS="js cpp jvm cs py hxmc hxmc-wasm hxmc-par hxmc-wasmgc"

hx_build() {
	_t=$1 _m=$2 _b=$3
	shift 3
	case $_t in
	js) "$ROOT/tools/haxe" -cp src -cp test -D analyzer-optimize -main "$_m" "$@" -lib hxnodejs -js "$_b-js.js" ;;
	cpp) "$ROOT/tools/haxe" -cp src -cp test -D analyzer-optimize -main "$_m" "$@" -cpp "$_b-cpp" -D HXCPP_QUIET >/dev/null ;;
	jvm) "$ROOT/tools/haxe" -cp src -cp test -D analyzer-optimize -main "$_m" "$@" --jvm "$_b-jvm.jar" ;;
	# py: std-py/ holds std overrides that keep strings in UTF-16 form (see std-py/python/U16.hx).
	py) "$ROOT/tools/haxe" -cp "$ROOT/std-py" -cp src -cp test -D analyzer-optimize -main "$_m" "$@" --python "$_b-py.py" ;;
	# hxmc: tools/haxe's flags with hxmc's tool in place of haxe (its std after src; the upstream std of
	# its checkout). -D hxmc.symbols: a symbol table for profilers (no change to the code).
	# -D hxmc.gc-prefault: a helper thread faults in the old space's pages ahead of the minor
	# collections (as hxmc's own compilers are built; like Go's background GC workers, it runs
	# beside the single compiler thread: ts6-compiler check -3% wall time). -D hxmc.shrink-wrap:
	# shadow-stack frames pushed after a function's early exits (check -2%).
	hxmc)
		ulimit -s unlimited 2>/dev/null || :
		HAXE_STD_PATH="$HXMC_HOME/haxe/upstream/std" "$HXMC_HOME/bin/hxmc/hxmc" "$_b-hxmc" -D HXCPP_CPP17 -D HXCPP_SINGLE_THREADED_APP \
			-D HXCPP_GC_BIG_BLOCKS -cp "$ROOT/src" --macro 'go.NilRange.apply()' go.GcInit -cp src -cp test -D analyzer-optimize \
			-main "$_m" -D hxmc.symbols -D hxmc.gc-prefault -D hxmc.shrink-wrap "$@" -cp "$HXMC_HOME/bin/hxmc/std" --custom-target hxmc >/dev/null
		;;
	# hxmc-wasm: the same for wasm32-wasi (go.OsWasi), run under node by hxmc's WASI runner, which
	# preopens "/" (-D hxmc.symbols: a name section).
	hxmc-wasm)
		ulimit -s unlimited 2>/dev/null || :
		HAXE_STD_PATH="$HXMC_HOME/haxe/upstream/std" "$HXMC_HOME/bin/hxmc/hxmc" "$_b-hxmc.wasm" -cp "$ROOT/src" \
			--macro 'go.NilRange.apply()' go.GcInit -cp src -cp test -D analyzer-optimize -main "$_m" -D hxmc.target=wasm32-wasi \
			-D hxmc.symbols "$@" -cp "$HXMC_HOME/bin/hxmc/std" --custom-target hxmc >/dev/null
		;;
	# hxmc-par: hxmc's build with the checkers, parsing, binding and emit on threads (-D tshx-parallel)
	hxmc-par)
		_pb=$_b # (hx_build sets _b)
		hx_build hxmc "$_m" "$_pb-par.tmp" -D tshx-parallel "$@" && mv "$_pb-par.tmp-hxmc" "$_pb-hxmc-par"
		;;
	# hxmc-wasmgc: the wasm32-wasi build with -D hxmc.wasm-gc (no linear memory: go.Os is go.OsGc)
	hxmc-wasmgc)
		ulimit -s unlimited 2>/dev/null || :
		HAXE_STD_PATH="$HXMC_HOME/haxe/upstream/std" "$HXMC_HOME/bin/hxmc/hxmc" "$_b-hxmc-gc.wasm" -cp "$ROOT/src" \
			--macro 'go.NilRange.apply()' go.GcInit -cp src -cp test -D analyzer-optimize -main "$_m" -D hxmc.target=wasm32-wasi \
			-D hxmc.wasm-gc -D hxmc.symbols "$@" -cp "$HXMC_HOME/bin/hxmc/std" --custom-target hxmc >/dev/null
		;;
	cs)
		# Haxe writes the C# sources (hxcs: -D no-compilation); the project file and the launcher come
		# from hx_cs_project; dotnet build is incremental (no work when no source changed).
		# -D erase-generics: with real C# generics hxcs copies an object on a cast between two
		# instantiations (GoMap<object, object> to GoMap<string, object>), so the aliases diverge.
		# The filtered warning: hxcs's constructor overload search does not match a closure argument
		# to a function-typed parameter and keeps the call as written (C# binds it; checked).
		mkdir -p "$_b-cs"
		HAXELIB_PATH="$HAXELIB_CS" "$ROOT/tools/haxe" -cp src -cp test -D analyzer-optimize -main "$_m" "$@" --cs "$_b-cs" \
			-D no-compilation -D net-ver=45 -D erase-generics >"$_b-cs/haxe.log" 2>&1 && _rc=0 || _rc=$?
		grep -v ': Warning : No overload found for this constructor call$' "$_b-cs/haxe.log" >&2 || :
		[ $_rc = 0 ] || return 1
		hx_cs_project "$_m" "$_b-cs"
		"$DOTNET" build "$_b-cs/${_m##*.}.csproj" -c Release -nologo -v q -clp:'NoSummary;ErrorsOnly' >"$_b-cs/build.log" 2>&1 || {
			grep -m 20 'error' "$_b-cs/build.log" >&2
			return 1
		}
		;;
	*)
		echo "hx_build: unknown target $_t" >&2
		return 2
		;;
	esac
}

hx_cmd() {
	_t=$1 _m=$2 _b=$3
	case $_t in
	js) echo "$NODE --stack-size=7000 ${HX_NODE_OPTS:-} $_b-js.js" ;;
	cpp) echo "$_b-cpp/${_m##*.}" ;;
	jvm) echo "$JAVA $JAVA_OPTS -jar $_b-jvm.jar" ;;
	py) echo "$PYTHON $_b-py.py" ;;
	cs) echo "$DOTNET $_b-cs/bin/${_m##*.}.dll" ;;
	hxmc) echo "$_b-hxmc" ;;
	hxmc-wasm) echo "$NODE --stack-size=7000 ${HX_NODE_OPTS:-} $HXMC_HOME/hxmc/bootstrap/wasi.mjs $_b-hxmc.wasm" ;;
	hxmc-par) echo "$_b-hxmc-par" ;;
	hxmc-wasmgc) echo "$NODE --stack-size=7000 ${HX_NODE_OPTS:-} $HXMC_HOME/hxmc/bootstrap/wasmgc.mjs $_b-hxmc-gc.wasm" ;;
	*) echo "false unknown-target-$_t" ;;
	esac
}

# hx_cs_project <main> <dir>: <dir>/<Name>.csproj and <dir>/HxLauncher.cs for the hxcs sources in
# <dir>/src (written only when the text changes, so that dotnet build stays incremental).
# HxLauncher runs main() in a thread with a 1 GB stack (deep recursion; the main thread has the
# ulimit stack). Resources: hxcs escapes the names on disk; Haxe's cs Resource looks up the manifest
# name "src.Resources.<escaped path>". InvariantGlobalization: no ICU; culture-neutral number
# formatting, and StartsWith/EndsWith/Compare are ordinal. TieredPGO off: ts6-compiler decl
# 7.5 s -> 5.5 s (the instrumented tier costs more than it gains in one compiler run; measured).
hx_cs_project() {
	_n=${1##*.}
	_d=$2
	_t=$(mktemp)
	cat >"$_t" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>$_n</AssemblyName>
    <RootNamespace></RootNamespace>
    <StartupObject>HxLauncher</StartupObject>
    <OutputPath>bin/</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <Optimize>true</Optimize>
    <DebugType>portable</DebugType>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <WarningLevel>0</WarningLevel>
    <NoWarn>\$(NoWarn);CS0108;CS0109;CS0114;CS0162;CS0168;CS0169;CS0219;CS0414;CS0429;CS0472;CS0649;CS0659;CS0660;CS0661;CS0665;CS1717;CS8981;SYSLIB0011;SYSLIB0014</NoWarn>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <InvariantGlobalization>true</InvariantGlobalization>
    <ServerGarbageCollection>false</ServerGarbageCollection>
    <ConcurrentGarbageCollection>false</ConcurrentGarbageCollection>
    <TieredPGO>false</TieredPGO>
    <SatelliteResourceLanguages>en</SatelliteResourceLanguages>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
    <EnableDefaultItems>false</EnableDefaultItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="src/**/*.cs;HxLauncher.cs" />
    <EmbeddedResource Include="src/Resources/**" LogicalName="src.Resources.%(RecursiveDir)%(Filename)%(Extension)" />
  </ItemGroup>
</Project>
EOF
	cmp -s "$_t" "$_d/$_n.csproj" || cp "$_t" "$_d/$_n.csproj"
	cat >"$_t" <<EOF
// Generated by tools/targets.sh (hx_cs_project).
public static class HxLauncher {
	public static void Main() {
		// Debug aid: HXCS_FIRST_CHANCE=1 prints every .NET exception with its stack when it is thrown
		// (a Haxe rethrow keeps only the stack of the rethrow).
		if (System.Environment.GetEnvironmentVariable("HXCS_FIRST_CHANCE") != null)
			System.AppDomain.CurrentDomain.FirstChanceException += (s, e) => System.Console.Error.WriteLine("first chance: " + e.Exception);
		var t = new System.Threading.Thread(() => global::$1.Main(), 1 << 30);
		t.Start();
		t.Join();
	}
}
EOF
	cmp -s "$_t" "$_d/HxLauncher.cs" || cp "$_t" "$_d/HxLauncher.cs"
	rm -f "$_t"
	# MSBuild compiles only one of two files whose paths differ only in case (class Pseudochecker and
	# class PseudoChecker): rename the second one (C# does not care about file names).
	find "$_d/src" -name '*.cs' ! -name '*.case.cs' | LC_ALL=C sort | awk '{ l = tolower($0); if (l in seen) print; seen[l] = 1 }' |
		while read -r _f; do mv "$_f" "${_f%.cs}.case.cs"; done
}

hx_targets_check() {
	for _t in $1; do
		case " $HX_ALL_TARGETS " in
		*" $_t "*) ;;
		*)
			echo "unknown target '$_t' (known: $HX_ALL_TARGETS)" >&2
			exit 2
			;;
		esac
	done
}

# hx_sample <n> <in> <out>: every n-th line of <in> (lines 1, 1+n, 1+2n, ...) into <out>.
# n = 1 copies all lines. Deterministic: the corpus lists are sorted.
hx_sample() {
	awk -v n="$1" '(NR - 1) % n == 0' "$2" >"$3"
}

# hx_list <comma or space separated list>: prints the space separated list (checked).
hx_list() {
	_l=$(echo "$1" | tr ',' ' ')
	hx_targets_check "$_l"
	echo $_l
}
