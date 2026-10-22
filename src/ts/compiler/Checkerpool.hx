package ts.compiler;

// Port of checkerpool.go (types and methods; newCheckerPool, newCheckerPoolWithTracing and noop are in Compiler.hx).
// PORT: single-threaded port (PORTING.md §4): the mutexes are kept as opaque values and never locked;
// the release functions are no-ops. The number of checkers and the file→checker assignment are
// those of Go (in the single-threaded mode used by the test harness there is exactly one checker).

// CheckerPool is implemented by the project system to provide checkers with
// request-scoped lifetime and reclamation. It returns a checker and a release
// function that must be called when the caller is done with the checker.
// The returned checker must not be accessed concurrently; each acquisition is exclusive.
// If file is non-nil, the pool may use it as an affinity hint to return the same
// checker for the same file across calls.
interface CheckerPool {
	// PORT: (*checker.Checker, func()) → Pair
	function GetChecker(ctx:Context, file:SourceFile):Pair<Checker, () -> Void>;
}

// Go type checkerPool (the exported name CheckerPool is the interface).
@:allow(ts.compiler)
class CheckerPool_ implements CheckerPool {
	var program:Program = null;
	var tracing:Tracing = null;

	var createCheckersOnce:Bool = false; // PORT: sync.Once → flag
	var checkers:Array<Checker> = null;
	var locks:Array<Any> = null; // PORT: []*sync.Mutex → opaque values, never locked
	var fileAssociations:IdentityMap<SourceFile, Checker> = null;

	public function new() {}

	// GetChecker implements CheckerPool. When file is non-nil, returns the checker
	// associated with that file; otherwise returns the first checker.
	public function GetChecker(ctx:Context, file:SourceFile):Pair<Checker, () -> Void> {
		if (file != null) {
			return this.getCheckerForFileExclusive(ctx, file);
		}
		this.createCheckers();
		final c = this.checkers[0];
		// p.locks[0].Lock(); release: sync.OnceFunc(unlock)
		#if tshx_parallel
		return new Pair<Checker, () -> Void>(c, this.lock(0));
		#else
		return new Pair<Checker, () -> Void>(c, Compiler.noop);
		#end
	}

	// getCheckerForFileNonExclusive returns the checker for the given file without locking.
	// This is only safe when the caller guarantees no concurrent access to the same checker,
	// e.g. for read-only operations like obtaining an emit resolver.
	function getCheckerForFileNonExclusive(file:SourceFile):Pair<Checker, () -> Void> {
		this.createCheckers();
		return new Pair<Checker, () -> Void>(this.fileAssociations.get(file), Compiler.noop);
	}

	function getCheckerForFileExclusive(ctx:Context, file:SourceFile):Pair<Checker, () -> Void> {
		this.createCheckers();
		final c = this.fileAssociations.get(file);
		// idx := slices.Index(p.checkers, c); p.locks[idx].Lock()
		#if tshx_parallel
		return new Pair<Checker, () -> Void>(c, this.lock(this.checkers.indexOf(c)));
		#else
		return new Pair<Checker, () -> Void>(c, Compiler.noop);
		#end
	}

	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — p.locks[idx].Lock(), and its release as sync.OnceFunc(Unlock)
	function lock(idx:Int):() -> Void {
		final m:sys.thread.Mutex = cast this.locks[idx];
		m.acquire();
		var released = false;
		return function() {
			if (!released) {
				released = true;
				m.release();
			}
		};
	}
	#end

	// getCheckerNonExclusive returns the first checker without locking.
	function getCheckerNonExclusive():Pair<Checker, () -> Void> {
		this.createCheckers();
		return new Pair<Checker, () -> Void>(this.checkers[0], Compiler.noop);
	}

	function createCheckers():Void {
		if (this.createCheckersOnce)
			return;
		this.createCheckersOnce = true;
		final checkerCount = this.checkers.length;
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — the checkers are created on threads, as in Go
		final wg:WorkGroup = this.program.SingleThreaded() ? Core.NewWorkGroup(true) : new ParallelWorkGroup();
		#else
		final wg = Core.NewWorkGroup(this.program.SingleThreaded());
		#end
		for (i in 0...checkerCount) {
			wg.Queue(function() {
				var tracer:ts.checker.Tracer = null;
				if (this.tracing != null) {
					tracer = Checker.NewTracer(this.tracing, i);
				}
				final r = Checker.NewChecker(this.program, tracer);
				this.checkers[i] = r.a;
				#if tshx_parallel
				this.locks[i] = new sys.thread.Mutex(); // PORT: hxmc (-D tshx-parallel) — the checker's mutex
				#else
				this.locks[i] = r.b;
				#end
			});
		}

		wg.RunAndWait();

		this.fileAssociations = new IdentityMap();
		final files = this.program.processedFiles.files;
		for (i in 0...files.length) {
			this.fileAssociations.set(files[i], this.checkers[i % checkerCount]);
		}
	}

	// Runs `cb` for each checker in the pool concurrently, locking and unlocking checker mutexes as it goes,
	// making it safe to call `forEachCheckerParallel` from many threads simultaneously.
	function forEachCheckerParallel(cb:(idx:Int, c:Checker) -> Void):Void {
		this.createCheckers();
		final wg = Core.NewWorkGroup(this.program.SingleThreaded());
		for (idx in 0...this.checkers.length) {
			final checker = this.checkers[idx];
			wg.Queue(function() {
				#if tshx_parallel
				final release = this.lock(idx);
				cb(idx, checker);
				release();
				#else
				cb(idx, checker);
				#end
			});
		}
		wg.RunAndWait();
	}

	public function GetGlobalDiagnostics():Array<Diagnostic> {
		this.createCheckers();
		final globalDiagnostics:Array<Array<Diagnostic>> = [for (_ in 0...this.checkers.length) null];
		this.forEachCheckerParallel(function(idx:Int, checker:Checker) {
			globalDiagnostics[idx] = checker.GetGlobalDiagnostics();
		});
		return Compiler.SortAndDeduplicateDiagnostics(Slices.Concat(...globalDiagnostics));
	}

	// forEachCheckerGroupDo runs one task per checker in parallel. Each task iterates
	// the provided files, processing only those assigned to its checker. Within each
	// checker's set, files are visited in their original order.
	function forEachCheckerGroupDo(ctx:Context, files:Array<SourceFile>, singleThreaded:Bool, cb:(c:Checker, fileIndex:Int, file:SourceFile) -> Void):Void {
		this.createCheckers();

		final checkerCount = this.checkers.length;
		#if tshx_parallel
		// PORT: hxmc (-D tshx-parallel) — the checkers run on threads, as in Go
		final wg:WorkGroup = singleThreaded ? Core.NewWorkGroup(true) : new ParallelWorkGroup();
		#else
		final wg = Core.NewWorkGroup(singleThreaded);
		#end
		for (checkerIdx in 0...checkerCount) {
			wg.Queue(function() {
				#if tshx_parallel
				final release = this.lock(checkerIdx);
				final t0 = haxe.Timer.stamp();
				#end
				for (i in 0...files.length) {
					final file = files[i];
					final checker = this.checkers[checkerIdx];
					if (checker == this.fileAssociations.get(file)) {
						cb(checker, i, file);
					}
				}
				#if tshx_parallel
				if (Sys.getEnv("TSHX_DEBUG") != null)
					Sys.stderr().writeString("checker " + checkerIdx + " on slot " + go.Par.slot + ": " + Std.int((haxe.Timer.stamp() - t0) * 1000) + " ms\n");
				release();
				#end
			});
		}
		wg.RunAndWait();
	}
}
