package ts.core;

// Port of semaphore.go.
// PORT: single-threaded port (PORTING.md §4). `(release func(), acquired bool)` → ValueOk
// (value = release, ok = acquired). A Go channel send that would block forever (all slots
// taken and nobody can release them in a single thread) throws instead of deadlocking.
interface Semaphore {
	function Acquire():() -> Void;
	function TryAcquire(ctx:Context):ValueOk<() -> Void>;
}

class UnlimitedSemaphore implements Semaphore {
	public function new() {}

	public function Acquire():() -> Void {
		return () -> {};
	}

	public function TryAcquire(ctx:Context):ValueOk<() -> Void> {
		return new ValueOk<() -> Void>(() -> {}, true);
	}
}

class LimitedSemaphore implements Semaphore {
	// PORT: `ch chan struct{}` (buffered, cap maxConcurrency) → slot counter.
	var used:Int = 0;
	final capacity:Int;
	@:allow(ts.core)
	var release:() -> Void = null;

	@:allow(ts.core)
	function new(capacity:Int) {
		this.capacity = capacity;
		#if tshx_parallel
		this.slots = new sys.thread.Semaphore(capacity);
		#end
	}

	public function Acquire():() -> Void {
		send();
		return this.release;
	}

	public function TryAcquire(ctx:Context):ValueOk<() -> Void> {
		// PORT: Go waits until a slot frees up or ctx is done. Nothing can free a slot while this
		// single thread waits and go.Context is never done, so a full semaphore throws (Go: deadlock).
		send();
		return new ValueOk<() -> Void>(this.release, true);
	}

	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — the channel as a counting semaphore: a full one blocks, as in Go
	final slots:sys.thread.Semaphore;

	function send():Void
		slots.acquire();

	@:allow(ts.core)
	function receive():Void
		slots.release();
	#else
	// s.ch <- struct{}{}
	function send():Void {
		if (used >= capacity)
			throw "LimitedSemaphore: all slots taken (would block forever)";
		used++;
	}

	// <-s.ch
	@:allow(ts.core)
	function receive():Void {
		if (used == 0)
			throw "LimitedSemaphore: release without acquire (would block forever)";
		used--;
	}
	#end
}
