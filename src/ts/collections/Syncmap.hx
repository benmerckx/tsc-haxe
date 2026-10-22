package ts.collections;

// Port of syncmap.go.
// PORT: single-threaded port (PORTING.md §4): sync.Map → GoMap. Go zero value →
// `new SyncMap<K, V>(zero)`; `zero` is the Go zero value of V (default null, see OrderedMap.hx).
// Range order is the GoMap order (Go: unspecified).
// PORT: hxmc (-D tshx-parallel) — every operation under a mutex; Range and Keys go over a copy taken
// under it (sync.Map's Range holds no lock while f runs, which may use the map).
class SyncMap<K, V> {
	var m:GoMap<K, V> = new GoMap<K, V>();

	// PORT: Go zero value of V.
	final zero:Null<V>;

	#if tshx_parallel
	final mutex = new sys.thread.Mutex();
	#end

	inline function lock():Void {
		#if tshx_parallel
		mutex.acquire();
		#end
	}

	inline function unlock():Void {
		#if tshx_parallel
		mutex.release();
		#end
	}

	public function new(?zero:V) {
		this.zero = zero;
	}

	public function Load(key:K):ValueOk<V> {
		lock();
		final ok = m.exists(key);
		final val = m.get(key);
		unlock();
		if (!ok || val == null) {
			return new ValueOk<V>(zero, ok);
		}
		return new ValueOk<V>(val, true);
	}

	public function Store(key:K, value:V):Void {
		lock();
		m.set(key, value);
		unlock();
	}

	// PORT: (actual V, loaded bool) → ValueOk: value = actual, ok = loaded.
	public function LoadOrStore(key:K, value:V):ValueOk<V> {
		lock();
		final loaded = m.exists(key);
		final actualAny = loaded ? m.get(key) : value;
		if (!loaded)
			m.set(key, value);
		unlock();
		if (actualAny == null) {
			return new ValueOk<V>(zero, loaded);
		}

		return new ValueOk<V>(actualAny, loaded);
	}

	public function Delete(key:K):Void {
		lock();
		m.remove(key);
		unlock();
	}

	public function Clear():Void {
		lock();
		m.clear();
		unlock();
	}

	public function Range(f:(key:K, value:V) -> Bool):Void {
		#if tshx_parallel
		final m = ToMap();
		#end
		for (key in m.keys()) {
			final value = m.get(key);
			var v:V = zero;
			if (value != null) {
				v = value;
			}

			if (!f(key, v))
				break;
		}
	}

	// Size returns the approximate number of items in the map.
	// Note that this is not a precise count, as the map may be modified
	// concurrently while this method is running.
	public function Size():Int {
		// PORT: Go counts with Range; the count is exact here.
		lock();
		final n = m.length();
		unlock();
		return n;
	}

	public function ToMap():GoMap<K, V> {
		lock();
		final c = m.copy();
		unlock();
		return c;
	}

	public function Keys():Iterator<K> {
		#if tshx_parallel
		return ToMap().keys();
		#else
		return m.keys();
		#end
	}

	public function Clone():SyncMap<K, V> {
		final clone = new SyncMap<K, V>(zero);
		clone.m = ToMap();
		return clone;
	}
}
