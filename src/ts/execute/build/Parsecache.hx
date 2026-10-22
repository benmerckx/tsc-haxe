package ts.execute.build;

// Port of parseCache.go.
// PORT: single-threaded port: the per-entry sync.Mutex is dropped.
// PORT: hxmc (-D tshx-parallel) — files are parsed on threads: the entries' map under a mutex (Go's SyncMap)
// and the per-entry mutex as in Go, held while the entry's value is parsed, so that a second caller of the
// same key waits for that value instead of parsing it again (a second SourceFile) or reading it unset.
class ParseCacheEntry<V> {
	public var value:Null<V> = null;
	#if tshx_parallel
	public final mu = new sys.thread.Mutex();
	#end

	public function new() {}
}

// PORT: Go `parseCache[K comparable, V comparable]` with a SyncMap keyed by K. K is a tspath.Path or
// an ast.SourceFileParseOptions struct; struct keys are encoded as a String (PORTING.md §4a), so the
// cache takes a `keyOf` function that maps K to its map key.
class ParseCache<K, V> {
	var entries:StringMap<ParseCacheEntry<V>> = new StringMap();
	final keyOf:(K) -> std.String;
	#if tshx_parallel
	final entriesMutex = new sys.thread.Mutex();
	#end

	public function new(keyOf:(K) -> std.String) {
		this.keyOf = keyOf;
	}

	public function loadOrStore(key:K, parse:(K) -> V, allowZero:Bool):V {
		#if tshx_parallel
		final newEntry = new ParseCacheEntry<V>();
		newEntry.mu.acquire();
		final k = this.keyOf(key);
		this.entriesMutex.acquire();
		final entry = this.entries.get(k);
		if (entry == null)
			this.entries.set(k, newEntry);
		this.entriesMutex.release();
		var target = newEntry;
		if (entry != null) {
			newEntry.mu.release(); // (not stored)
			entry.mu.acquire();
			if (allowZero || entry.value != null) {
				final v = entry.value;
				entry.mu.release();
				return v;
			}
			target = entry;
		}
		final v = try parse(key) catch (e:Dynamic) {
			target.mu.release();
			throw e;
		}
		target.value = v;
		target.mu.release();
		return v;
		#else
		var newEntry = new ParseCacheEntry<V>();
		final k = this.keyOf(key);
		final entry = this.entries.get(k);
		if (entry != null) {
			if (allowZero || entry.value != null) {
				return entry.value;
			}
			newEntry = entry;
		} else {
			this.entries.set(k, newEntry);
		}
		newEntry.value = parse(key);
		return newEntry.value;
		#end
	}

	public function store(key:K, value:V):Void {
		final e = new ParseCacheEntry<V>();
		e.value = value;
		#if tshx_parallel
		this.entriesMutex.acquire();
		#end
		this.entries.set(this.keyOf(key), e);
		#if tshx_parallel
		this.entriesMutex.release();
		#end
	}

	public function delete(key:K):Void {
		#if tshx_parallel
		this.entriesMutex.acquire();
		#end
		this.entries.remove(this.keyOf(key));
		#if tshx_parallel
		this.entriesMutex.release();
		#end
	}

	public function reset():Void {
		#if tshx_parallel
		this.entriesMutex.acquire();
		#end
		this.entries = new StringMap();
		#if tshx_parallel
		this.entriesMutex.release();
		#end
	}
}
