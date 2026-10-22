package go;

#if tshx_parallel
import haxe.atomic.AtomicInt;
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;

// PORT: hxmc (-D tshx-parallel) — the goroutines of Go's parallel work groups: a pool of threads that
// run queued functions (ts.core.ParallelWorkGroup), and the running thread's slot, which indexes the
// per-thread state that Go keeps in sync.Pools or on the stack (pooled hashers, buffers, binders).
class Par {
	// 0 on the main thread, 1..threads() on the pool's workers (a copy per thread, zero in a new one)
	@:hxmc.threadLocal public static var slot:Int;
	// slots for the per-thread state: the main thread and at most SLOTS - 1 workers
	public static inline final SLOTS = 64;

	// the lazily computed fields of shared objects (Go's sync.Onces of the program)
	public static final onceMutex = new Mutex();

	static final tasks = new Deque<() -> Void>();
	static final startMutex = new Mutex();
	static final started = new AtomicInt(0);
	static var count = 0;

	// the pool's size: TSHX_THREADS, else 4 (Go's default number of checkers)
	public static function threads():Int {
		if (count == 0) {
			final v = Sys.getEnv("TSHX_THREADS");
			final n = v == null ? 4 : Std.parseInt(v);
			count = n == null || n < 1 ? 1 : n >= SLOTS ? SLOTS - 1 : n;
		}
		return count;
	}

	// runs fn on a worker
	public static function submit(fn:() -> Void):Void {
		if (started.load() == 0)
			start();
		tasks.add(fn);
	}

	// runs one queued function on this thread, if there is one (a thread waiting for its group helps)
	public static function tryRun():Bool {
		final fn = tasks.pop(false);
		if (fn == null)
			return false;
		fn();
		return true;
	}

	static function start():Void {
		startMutex.acquire();
		if (started.load() == 0) {
			for (i in 1...threads() + 1)
				Thread.create(() -> {
					slot = i;
					while (true)
						tasks.pop(true)();
				});
			started.store(1);
		}
		startMutex.release();
	}
}
#end
