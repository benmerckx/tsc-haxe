package ts.core;

import haxe.ds.StringMap;

// Port of internal/core: package-level funcs, vars and consts of all files (Go file order).
// Types are in one module per Go file.
//
// PORT: generic helpers are plain static functions (not @:generic, PORTING.md §3/§4a); small
// ones are `inline`. A Go nil slice is `null`, an empty slice `[]`; every helper keeps Go's
// nil-vs-empty result (e.g. Map(nil) = nil, Map([]) = [], MapNonNil with no hits = nil).
//
// PORT: Go zero value `*new(T)` for a type parameter: Haxe cannot produce it (no run-time types
// on JS). Helpers that RETURN the zero value (Find, FindLast, FirstOrNil, LastOrNil,
// ElementOrNil, FirstOrNilSeq, FirstNonNil, FindBestPatternMatch, GetSpellingSuggestion) take
// an optional trailing `zero` argument that defaults to null (the Go zero value of pointers,
// slices, maps, funcs and `any`); pass "" / 0 / false when T is a string / number / bool.
// Helpers that COMPARE against the zero value (MapNonNil, FirstNonNil, FirstNonZero, OrElse)
// use isZero(), which recognizes null, "", 0 (also enum abstracts over Int) and false at run time.
//
// PORT: Go `iter.Seq[T]` → Haxe Iterator<T> (like src/ts/collections); `iter.Seq2[int, T]` →
// a key-value iterator (`for (i => v in Core.Enumerate(seq))`).
//
// PORT: Go `append(s, x)` inside a helper whose result the caller assigns back
// (AppendIfUnique, InsertSorted, DeduplicateSorted) mutates the argument array in place.
// Go may also write into the argument's backing array, but the caller's old slice header keeps
// its length; in Haxe the caller's old reference sees the new length too.
@:allow(ts.core)
class Core {
	// PORT: len() of a possibly-nil slice (PORTING.md §3).
	public static inline function len<T>(s:Null<Array<T>>):Int {
		return s == null ? 0 : s.length;
	}

	// PORT: `v == *new(T)` for a comparable T (see header).
	static function isZero<T>(v:T):Bool {
		final d:Dynamic = v;
		if (d == null)
			return true;
		if (Std.isOfType(d, String))
			return (d : String).length == 0;
		if (Std.isOfType(d, Int))
			return (d : Int) == 0;
		if (Std.isOfType(d, Float))
			return (d : Float) == 0;
		if (Std.isOfType(d, Bool))
			return (d : Bool) == false;
		return false;
	}

	// Go builtins min/max.
	static inline function max(a:Int, b:Int):Int {
		return a > b ? a : b;
	}

	static inline function min(a:Int, b:Int):Int {
		return a < b ? a : b;
	}

	// --- arena.go ---

	static function nextArenaSize(size:Int):Int {
		// This compiles down branch-free.
		size = max(size, 1);
		size = min(size * 2, 256);
		return size;
	}

	// --- bfs.go ---

	// BreadthFirstSearchParallel performs a breadth-first search on a graph
	// starting from the given node. It processes nodes in parallel and returns the path
	// from the first node that satisfies the `visit` function back to the start node.
	// PORT: visit returns Go (isResult bool, stop bool) as Pair (a = isResult, b = stop).
	public static function BreadthFirstSearchParallel<N>(start:N, neighbors:(N) -> Null<Array<N>>,
			visit:(node:N) -> Pair<Bool, Bool>):BreadthFirstSearchResult<N> {
		return BreadthFirstSearchParallelEx(start, neighbors, visit, new BreadthFirstSearchOptions<N, N>(), Identity);
	}

	// BreadthFirstSearchParallelEx is an extension of BreadthFirstSearchParallel that allows
	// the caller to pass a pre-seeded set of already-visited nodes and a preprocessing function
	// that can be used to remove nodes from each level before parallel processing.
	// PORT: single-threaded (PORTING.md §4): the jobs of a level run one after another in index
	// order. The result is the one Go computes (lowest index wins); jobs after the lowest goal
	// index are skipped, which Go only does when the goal was found before they started.
	public static function BreadthFirstSearchParallelEx<K, N>(start:N, neighbors:(N) -> Null<Array<N>>, visit:(node:N) -> Pair<Bool, Bool>,
			options:BreadthFirstSearchOptions<K, N>, getKey:(N) -> K):BreadthFirstSearchResult<N> {
		var visited = options.Visited;
		if (visited == null) {
			visited = new SyncSet<K>();
		}

		var fallback:Null<BreadthFirstSearchJob<N>> = null;
		// processLevel processes each node at the current level in parallel.
		// It produces either a list of jobs to be processed in the next level,
		// or a result if the visit function returns true for any node.
		final processLevel = function(index:Int, jobs:OrderedMap<K, BreadthFirstSearchJob<N>>):BreadthFirstSearchParallelExResult<K, N> {
			// PORT: atomic.Int64 → Int; math.MaxInt64 → MaxInt32 (indices fit in 32 bits).
			final maxInt = 2147483647;
			var lowestFallback = maxInt;
			var lowestGoal = maxInt;
			var nextJobCount = 0;
			if (options.PreprocessLevel != null) {
				options.PreprocessLevel(new BreadthFirstSearchLevel<K, N>(jobs));
			}
			final next = new Array<Null<Array<BreadthFirstSearchJob<N>>>>();
			next.resize(jobs.Size());
			var i = 0;
			for (j in jobs.Values()) {
				// PORT: goroutine body → local function (early returns); runs synchronously.
				final work = function(i:Int, j:BreadthFirstSearchJob<N>):Void {
					if (i >= lowestGoal) {
						return; // Stop processing if we already found a lower result
					}

					// If we have already visited this node, skip it.
					if (!visited.AddIfAbsent(getKey(j.node))) {
						// Note that if we are here, we already visited this node at a
						// previous *level*, which means `visit` must have returned false,
						// so we don't need to update our result indices. This holds true
						// because we deduplicated jobs before queuing the level.
						return;
					}

					final r = visit(j.node);
					final isResult = r.a, stop = r.b;
					if (isResult) {
						// We found a result, so we will stop at this level, but an
						// earlier job may still find a true result at a lower index.
						if (stop) {
							if (i < lowestGoal) // updateMin(&lowestGoal, int64(i))
								lowestGoal = i;
							return;
						}
						if (fallback == null) {
							if (i < lowestFallback) // updateMin(&lowestFallback, int64(i))
								lowestFallback = i;
						}
					}

					if (i >= lowestGoal) {
						// If `visit` is expensive, it's likely that by the time we get here,
						// a different job has already found a lower index result, so we
						// don't even need to collect the next jobs.
						return;
					}
					// Add the next level jobs
					final neighborNodes = neighbors(j.node);
					if (len(neighborNodes) > 0) {
						nextJobCount += neighborNodes.length;
						next[i] = Map(neighborNodes, function(child:N):BreadthFirstSearchJob<N> {
							return new BreadthFirstSearchJob<N>(child, j);
						});
					}
				};
				work(i, j);
				i++;
			}
			{
				final index = lowestGoal;
				if (index != maxInt) {
					// If we found a result, return it immediately.
					final job = jobs.EntryAt(index).b;
					return new BreadthFirstSearchParallelExResult<K, N>(true, job, null);
				}
			}
			if (fallback == null) {
				final index = lowestFallback;
				if (index != maxInt) {
					fallback = jobs.EntryAt(index).b;
				}
			}
			final nextJobs:OrderedMap<K, BreadthFirstSearchJob<N>> = Collections.NewOrderedMapWithSizeHint(nextJobCount);
			for (jobs in next) {
				if (jobs == null)
					continue;
				for (j in jobs) {
					if (!nextJobs.Has(getKey(j.node))) {
						// Deduplicate synchronously to avoid messy locks and spawning
						// unnecessary goroutines.
						nextJobs.Set(getKey(j.node), j);
					}
				}
			}
			return new BreadthFirstSearchParallelExResult<K, N>(false, null, nextJobs);
		};

		final createPath = function(job:Null<BreadthFirstSearchJob<N>>):Null<Array<N>> {
			var path:Null<Array<N>> = null;
			while (job != null) {
				if (path == null)
					path = [];
				path.push(job.node);
				job = job.parent;
			}
			return path;
		};

		var levelIndex = 0;
		var level:OrderedMap<K, BreadthFirstSearchJob<N>> = Collections.NewOrderedMapFromList([
			new MapEntry<K, BreadthFirstSearchJob<N>>(getKey(start), new BreadthFirstSearchJob<N>(start))
		]);
		while (level.Size() > 0) {
			final result = processLevel(levelIndex, level);
			if (result.stop) {
				return new BreadthFirstSearchResult<N>(true, createPath(result.job));
			} else if (result.job != null && fallback == null) {
				fallback = result.job;
			}
			level = result.next;
			levelIndex++;
		}
		return new BreadthFirstSearchResult<N>(false, createPath(fallback));
	}

	// PORT: updateMin(a *atomic.Int64, candidate int64) is inlined at its two call sites above.

	// --- binarysearch.go ---

	// BinarySearchUniqueFunc works like [slices.BinarySearchFunc], but avoids extra
	// invocations of the comparison function by assuming that only one element
	// in the slice could match the target. Also, unlike [slices.BinarySearchFunc],
	// the comparison function is passed the current index of the element being
	// compared, instead of the target element.
	// PORT: (int, bool) → ValueOk (value = index, ok = found).
	public static function BinarySearchUniqueFunc<E>(x:Null<Array<E>>, cmp:(Int, E) -> Int):ValueOk<Int> {
		final n = len(x);
		if (n == 0) {
			return new ValueOk<Int>(0, false);
		}
		var low = 0, high = n - 1;
		while (low <= high) {
			final middle = low + ((high - low) >> 1);
			final value = cmp(middle, x[middle]);
			if (value < 0) {
				low = middle + 1;
			} else if (value > 0) {
				high = middle - 1;
			} else {
				return new ValueOk<Int>(middle, true);
			}
		}
		return new ValueOk<Int>(low, false);
	}

	// --- compileroptions.go ---

	public static final EmptyCompilerOptions:CompilerOptions = new CompilerOptions();

	// PORT: `optionsType = reflect.TypeFor[CompilerOptions]()` is not needed: Clone copies fields explicitly.

	public static inline final ResolutionModeNone:ResolutionMode = ModuleKindNone;
	public static inline final ResolutionModeCommonJS:ResolutionMode = ModuleKindCommonJS;
	public static inline final ResolutionModeESM:ResolutionMode = ModuleKindESNext;

	// PORT: Go map[ModuleKind]ModuleResolutionKind → IntMap.
	public static final ModuleKindToModuleResolutionKind:haxe.ds.IntMap<ModuleResolutionKind> = {
		final m = new haxe.ds.IntMap<ModuleResolutionKind>();
		m.set(ModuleKindNode16, ModuleResolutionKindNode16);
		m.set(ModuleKindNodeNext, ModuleResolutionKindNodeNext);
		m;
	};

	public static function GetNewLineKind(s:String):NewLineKind {
		switch (s) {
			case "\r\n":
				return NewLineKindCRLF;
			case "\n":
				return NewLineKindLF;
			default:
				return NewLineKindNone;
		}
	}

	// --- context.go ---

	static final requestIDKey = new Key(0);
	static final checkerLifetimeKey = new Key(1);

	public static function WithRequestID(ctx:Context, id:String):Context {
		return Context.WithValue(ctx, requestIDKey, id);
	}

	public static function GetRequestID(ctx:Context):String {
		final id:Any = ctx.Value(requestIDKey);
		if (Std.isOfType(id, String)) {
			return id;
		}
		return "";
	}

	public static function WithCheckerLifetime(ctx:Context, lifetime:CheckerLifetime):Context {
		return Context.WithValue(ctx, checkerLifetimeKey, lifetime);
	}

	// PORT: the Go type assertion `.(CheckerLifetime)` becomes an Int check (enum abstracts
	// have no run-time type); only CheckerLifetime values are stored under this private key.
	public static function GetCheckerLifetime(ctx:Context):CheckerLifetime {
		final lifetime:Any = ctx.Value(checkerLifetimeKey);
		if (Std.isOfType(lifetime, Int)) {
			return (lifetime : Int);
		}
		return CheckerLifetimeTemporary;
	}

	// --- core.go ---

	// PORT: runtime/debug.SetMaxStack has no Haxe equivalent: the variable is read and validated,
	// but nothing is set.
	public static function ApplyDebugStackLimit():Void {
		final v = Sys.getEnv("TS_GO_DEBUG_STACK_LIMIT");
		if (v == null || v == "") {
			return;
		}
		final n = Std.parseInt(v); // strconv.Atoi
		if (n == null || n <= 0 || Std.string(n) != StringTools.trim(v)) {
			return;
		}
		// rtdebug.SetMaxStack(n)
	}

	// PORT: perf — Filter, Map, Some, Every, Find and FindIndex are `inline` (single exit): at a call
	// site with a lambda literal the lambda is inlined too (no closure allocation, no by-value calls),
	// and the body is typed with the caller's element type (on hxcpp a non-inline generic function
	// takes the array as a cpp.VirtualArray and boxes the elements as Dynamic).
	public static inline function Filter<T>(slice:Null<Array<T>>, f:(T) -> Bool):Null<Array<T>> {
		var result = slice;
		if (slice != null) {
			final n = slice.length;
			var i = 0;
			while (i < n && f(slice[i]))
				i++;
			if (i < n) {
				final r = slice.slice(0, i);
				var k = i + 1;
				while (k < n) {
					final value = slice[k];
					if (f(value)) {
						r.push(value);
					}
					k++;
				}
				result = r;
			}
		}
		return result;
	}

	public static function FilterSeq<T>(slice:Null<Array<T>>, f:(T) -> Bool):Iterator<T> {
		return new FilterSeqIterator<T>(slice, f);
	}

	public static function FilterIndex<T>(slice:Null<Array<T>>, f:(T, Int, Null<Array<T>>) -> Bool):Null<Array<T>> {
		if (slice == null)
			return null;
		for (i in 0...slice.length) {
			if (!f(slice[i], i, slice)) {
				final result = slice.slice(0, i);
				for (k in i + 1...slice.length) {
					final value = slice[k];
					if (f(value, k, slice)) {
						result.push(value);
					}
				}
				return result;
			}
		}
		return slice;
	}

	public static inline function Map<T, U>(slice:Null<Array<T>>, f:(T) -> U):Null<Array<U>> {
		var result:Null<Array<U>> = null;
		if (slice != null) {
			final r = new Array<U>();
			r.resize(slice.length);
			for (i in 0...slice.length) {
				r[i] = f(slice[i]);
			}
			result = r;
		}
		return result;
	}

	// PORT: f returns (U, error) as ValueError; the result ([]U, error) is a ValueError too.
	public static function TryMap<T, U>(slice:Null<Array<T>>, f:(T) -> ValueError<U>):ValueError<Null<Array<U>>> {
		if (len(slice) == 0) {
			return new ValueError<Null<Array<U>>>(null, null);
		}
		final result = new Array<U>();
		result.resize(slice.length);
		for (i in 0...slice.length) {
			final r = f(slice[i]);
			if (r.err != null) {
				return new ValueError<Null<Array<U>>>(null, r.err);
			}
			result[i] = r.value;
		}
		return new ValueError<Null<Array<U>>>(result, null);
	}

	public static function MapIndex<T, U>(slice:Null<Array<T>>, f:(T, Int) -> U):Null<Array<U>> {
		if (slice == null) {
			return null;
		}
		final result = new Array<U>();
		result.resize(slice.length);
		for (i in 0...slice.length) {
			result[i] = f(slice[i], i);
		}
		return result;
	}

	public static function MapNonNil<T, U>(slice:Null<Array<T>>, f:(T) -> U):Null<Array<U>> {
		var result:Null<Array<U>> = null;
		if (slice != null) {
			for (value in slice) {
				final mapped = f(value);
				if (!isZero(mapped)) {
					if (result == null)
						result = [];
					result.push(mapped);
				}
			}
		}
		return result;
	}

	// PORT: f returns (U, bool) as ValueOk.
	public static function MapFiltered<T, U>(slice:Null<Array<T>>, f:(T) -> ValueOk<U>):Null<Array<U>> {
		var result:Null<Array<U>> = null;
		if (slice != null) {
			for (value in slice) {
				final r = f(value);
				if (!r.ok) {
					continue;
				}
				if (result == null)
					result = [];
				result.push(r.value);
			}
		}
		return result;
	}

	public static function FlatMap<T, U>(slice:Null<Array<T>>, f:(T) -> Null<Array<U>>):Null<Array<U>> {
		var result:Null<Array<U>> = null;
		if (slice != null) {
			for (value in slice) {
				final mapped = f(value);
				if (len(mapped) != 0) {
					if (result == null)
						result = [];
					for (m in mapped)
						result.push(m);
				}
			}
		}
		return result;
	}

	public static function SameMap<T>(slice:Null<Array<T>>, f:(T) -> T):Null<Array<T>> {
		if (slice == null)
			return null;
		for (i in 0...slice.length) {
			final value = slice[i];
			final mapped = f(value);
			if (mapped != value) {
				final result = new Array<T>();
				result.resize(slice.length);
				for (k in 0...i)
					result[k] = slice[k];
				result[i] = mapped;
				for (j in i + 1...slice.length) {
					result[j] = f(slice[j]);
				}
				return result;
			}
		}
		return slice;
	}

	public static function SameMapIndex<T>(slice:Null<Array<T>>, f:(T, Int) -> T):Null<Array<T>> {
		if (slice == null)
			return null;
		for (i in 0...slice.length) {
			final value = slice[i];
			final mapped = f(value, i);
			if (mapped != value) {
				final result = new Array<T>();
				result.resize(slice.length);
				for (k in 0...i)
					result[k] = slice[k];
				result[i] = mapped;
				for (j in i + 1...slice.length) {
					result[j] = f(slice[j], j);
				}
				return result;
			}
		}
		return slice;
	}

	// PORT: Go compares the address of the first elements (same backing array and offset).
	// Haxe arrays cannot share storage, so "same" is array identity.
	// Must stay `inline`: on hxcpp a generic function sees arrays as cpp.VirtualArray wrappers,
	// and a non-inline `s1 == s2` compares wrappers (false for the same array). Tested on cpp.
	public static inline function Same<T>(s1:Null<Array<T>>, s2:Null<Array<T>>):Bool {
		return len(s1) == len(s2) ? (len(s1) == 0 || s1 == s2) : false;
	}

	public static inline function Some<T>(slice:Null<Array<T>>, f:(T) -> Bool):Bool {
		var found = false;
		if (slice != null) {
			final n = slice.length;
			var i = 0;
			while (i < n) {
				if (f(slice[i])) {
					found = true;
					break;
				}
				i++;
			}
		}
		return found;
	}

	public static inline function Every<T>(slice:Null<Array<T>>, f:(T) -> Bool):Bool {
		var all = true;
		if (slice != null) {
			final n = slice.length;
			var i = 0;
			while (i < n) {
				if (!f(slice[i])) {
					all = false;
					break;
				}
				i++;
			}
		}
		return all;
	}

	public static function Or<T>(...funcs:(T) -> Bool):(T) -> Bool {
		final funcs = funcs.toArray();
		return function(input:T):Bool {
			for (f in funcs) {
				if (f(input)) {
					return true;
				}
			}
			return false;
		};
	}

	public static inline function Find<T>(slice:Null<Array<T>>, f:(T) -> Bool, ?zero:T):T {
		var result = zero;
		if (slice != null) {
			final n = slice.length;
			var i = 0;
			while (i < n) {
				final value = slice[i];
				if (f(value)) {
					result = value;
					break;
				}
				i++;
			}
		}
		return result;
	}

	public static function FindLast<T>(slice:Null<Array<T>>, f:(T) -> Bool, ?zero:T):T {
		var i = len(slice) - 1;
		while (i >= 0) {
			final value = slice[i];
			if (f(value)) {
				return value;
			}
			i--;
		}
		return zero;
	}

	public static inline function FindIndex<T>(slice:Null<Array<T>>, f:(T) -> Bool):Int {
		var result = -1;
		if (slice != null) {
			final n = slice.length;
			var i = 0;
			while (i < n) {
				if (f(slice[i])) {
					result = i;
					break;
				}
				i++;
			}
		}
		return result;
	}

	public static function FindLastIndex<T>(slice:Null<Array<T>>, f:(T) -> Bool):Int {
		var i = len(slice) - 1;
		while (i >= 0) {
			final value = slice[i];
			if (f(value)) {
				return i;
			}
			i--;
		}
		return -1;
	}

	public static inline function FirstOrNil<T>(slice:Null<Array<T>>, ?zero:T):T {
		return len(slice) != 0 ? slice[0] : zero;
	}

	public static inline function LastOrNil<T>(slice:Null<Array<T>>, ?zero:T):T {
		return len(slice) != 0 ? slice[slice.length - 1] : zero;
	}

	public static inline function ElementOrNil<T>(slice:Null<Array<T>>, index:Int, ?zero:T):T {
		// PORT: Go panics for a negative index; Haxe returns null/zero for slice[-1] on JS, so it is left as is.
		return index < len(slice) ? slice[index] : zero;
	}

	public static function FirstOrNilSeq<T>(seq:Null<Iterator<T>>, ?zero:T):T {
		if (seq != null) {
			for (value in seq) {
				return value;
			}
		}
		return zero;
	}

	public static function FirstNonNil<T, U>(slice:Null<Array<T>>, f:(T) -> U, ?zero:U):U {
		if (slice != null) {
			for (value in slice) {
				final mapped = f(value);
				if (!isZero(mapped)) {
					return mapped;
				}
			}
		}
		return zero;
	}

	// PORT: the zero value returned when all values are zero is the last value if there is one
	// (it is zero, so it equals Go's zero), else null.
	public static function FirstNonZero<T>(...values:T):T {
		var zero:T = null;
		for (value in values) {
			if (!isZero(value)) {
				return value;
			}
			zero = value;
		}
		return zero;
	}

	public static function Concatenate<T>(s1:Null<Array<T>>, s2:Null<Array<T>>):Null<Array<T>> {
		if (len(s2) == 0) {
			return s1;
		}
		if (len(s1) == 0) {
			return s2;
		}
		return s1.concat(s2);
	}

	// slices.Concat of up to three slices: a new slice, or nil when the total length is 0.
	static function concat3<T>(a:Null<Array<T>>, b:Null<Array<T>>, c:Null<Array<T>>):Null<Array<T>> {
		if (len(a) + len(b) + len(c) == 0)
			return null;
		final result = new Array<T>();
		if (a != null)
			for (x in a)
				result.push(x);
		if (b != null)
			for (x in b)
				result.push(x);
		if (c != null)
			for (x in c)
				result.push(x);
		return result;
	}

	public static function Splice<T>(s1:Null<Array<T>>, start:Int, deleteCount:Int, ...items:T):Null<Array<T>> {
		if (start < 0) {
			start = len(s1) + start;
		}
		if (start < 0) {
			start = 0;
		}
		if (start > len(s1)) {
			start = len(s1);
		}
		if (deleteCount < 0) {
			deleteCount = 0;
		}
		final end = min(start + max(deleteCount, 0), len(s1));
		if (start == end && items.length == 0) {
			return s1;
		}
		return concat3(s1 == null ? null : s1.slice(0, start), items.toArray(), s1 == null ? null : s1.slice(end));
	}

	public static function CountWhere<T>(slice:Null<Array<T>>, f:(T) -> Bool):Int {
		var count = 0;
		if (slice != null) {
			for (value in slice) {
				if (f(value)) {
					count++;
				}
			}
		}
		return count;
	}

	public static function ReplaceElement<T>(slice:Null<Array<T>>, i:Int, t:T):Array<T> {
		if (slice == null || i < 0 || i >= slice.length)
			throw "index out of range"; // Go: slices.Clone(nil) = nil, then result[i] panics
		final result = slice.copy();
		result[i] = t;
		return result;
	}

	// PORT: slices.Insert in place (see header).
	public static function InsertSorted<T>(slice:Null<Array<T>>, element:T, cmp:(T, T) -> Int):Array<T> {
		final i = Slices.BinarySearchFunc(slice, element, cmp).value;
		if (slice == null)
			return [element];
		slice.insert(i, element);
		return slice;
	}

	// MinAllFunc returns all minimum elements from xs according to the comparison function cmp.
	public static function MinAllFunc<T>(xs:Null<Array<T>>, cmp:(a:T, b:T) -> Int):Null<Array<T>> {
		if (len(xs) == 0) {
			return null;
		}

		var m = xs[0];
		var mins = [m];

		for (k in 1...xs.length) {
			final x = xs[k];
			final c = cmp(x, m);
			if (c < 0) {
				m = x;
				mins = [x]; // mins = mins[:0]; mins = append(mins, x)
			} else if (c == 0) {
				mins.push(x);
			}
		}

		return mins;
	}

	// PORT: append in place (see header).
	public static function AppendIfUnique<T>(slice:Null<Array<T>>, element:T):Array<T> {
		if (Slices.Contains(slice, element)) {
			return slice;
		}
		if (slice == null)
			return [element];
		slice.push(element);
		return slice;
	}

	public static function Memoize<T>(create:Null<() -> T>):() -> T {
		var value:T = null;
		return function():T {
			if (create != null) {
				value = create();
				create = null;
			}
			return value;
		};
	}

	// Returns whenTrue if b is true; otherwise, returns whenFalse. IfElse should only be used when branches are either
	// constant or precomputed as both branches will be evaluated regardless as to the value of b.
	public static inline function IfElse<T>(b:Bool, whenTrue:T, whenFalse:T):T {
		return b ? whenTrue : whenFalse;
	}

	// Returns value if value is not the zero value of T; Otherwise, returns defaultValue. OrElse should only be used when
	// defaultValue is constant or precomputed as its argument will be evaluated regardless as to the content of value.
	public static inline function OrElse<T>(value:T, defaultValue:T):T {
		return !isZero(value) ? value : defaultValue;
	}

	// Returns `a` if `a` is not `nil`; Otherwise, returns `b`. Coalesce is roughly analogous to `??` in JS, except that it
	// non-shortcutting, so it is advised to only use a constant or precomputed value for `b`
	public static inline function Coalesce<T>(a:Null<T>, b:Null<T>):Null<T> {
		return a == null ? b : a;
	}

	public static function ComputeECMALineStarts(text:String):ECMALineStarts {
		final result = new Array<TextPos>(); // make([]TextPos, 0, strings.Count(text, "\n")+1)
		for (p in ComputeECMALineStartsSeq(text))
			result.push(p);
		return result;
	}

	// PORT: positions are UTF-16 offsets (PORTING.md §5): non-ASCII characters are decoded from
	// UTF-16; a lone surrogate decodes to RuneError (not a line break) and advances 1 unit.
	// PORT: perf — returns the concrete iterator class: through the `Iterator<T>` structure type hxcpp
	// calls hasNext/next by name (a closure allocation per call).
	public static function ComputeECMALineStartsSeq(text:String):ECMALineStartsSeqIterator {
		return new ECMALineStartsSeqIterator(text);
	}

	// PositionToLineAndByteOffset returns the 0-based line and byte offset from the
	// start of that line for the given byte position, using the provided line starts.
	// The byte offset is a raw UTF-8 byte offset from the line start, not a UTF-16 code unit count.
	// PORT: positions are UTF-16 offsets here, so the "byte offset" is a UTF-16 offset too.
	// (line int, byteOffset int) → Pair (a = line, b = byteOffset).
	public static function PositionToLineAndByteOffset(position:Int, lineStarts:Null<Array<TextPos>>):Pair<Int, Int> {
		// sort.Search(len(lineStarts), func(i int) bool { return int(lineStarts[i]) > position })
		var lo = 0, hi = len(lineStarts);
		while (lo < hi) {
			final h = (lo + hi) >>> 1;
			if (!((lineStarts[h] : Int) > position)) {
				lo = h + 1;
			} else {
				hi = h;
			}
		}
		final line = max(lo - 1, 0);
		return new Pair<Int, Int>(line, position - (lineStarts[line] : Int));
	}

	// UTF16Len returns the number of UTF-16 code units needed to
	// represent the given UTF-8 encoded string.
	// PORT: Haxe strings are UTF-16 (PORTING.md §5).
	public static inline function UTF16Len(s:String):UTF16Offset {
		return s.length;
	}

	public static function Flatten<T>(array:Null<Array<Null<Array<T>>>>):Null<Array<T>> {
		var result:Null<Array<T>> = null;
		if (array != null) {
			for (subArray in array) {
				if (len(subArray) != 0) {
					if (result == null)
						result = [];
					for (x in subArray)
						result.push(x);
				}
			}
		}
		return result;
	}

	public static function Must<T>(v:T, err:Null<Error>):T {
		if (err != null) {
			throw err;
		}
		return v;
	}

	// Extracts the first value of a multi-value return.
	public static inline function FirstResult<T1>(t1:T1, ..._:Any):T1 {
		return t1;
	}

	// PORT: (string, error) → ValueError. ts.json.Json throws where Go returns an error.
	public static function StringifyJson(input:Any, prefix:String, indent:String):ValueError<String> {
		try {
			final output = Json.MarshalIndent(input, prefix, indent);
			return new ValueError<String>(output, null);
		} catch (e:Dynamic) {
			return new ValueError<String>("", Errors.New(Std.string(e)));
		}
	}

	public static function GetScriptKindFromFileName(fileName:String):ScriptKind {
		final dotPos = fileName.lastIndexOf(".");
		if (dotPos >= 0) {
			switch (Strings.ToLower(fileName.substring(dotPos))) {
				case Tspath.ExtensionJs, Tspath.ExtensionCjs, Tspath.ExtensionMjs:
					return ScriptKindJS;
				case Tspath.ExtensionJsx:
					return ScriptKindJSX;
				case Tspath.ExtensionTs, Tspath.ExtensionCts, Tspath.ExtensionMts:
					return ScriptKindTS;
				case Tspath.ExtensionTsx:
					return ScriptKindTSX;
				case Tspath.ExtensionJson:
					return ScriptKindJSON;
				default:
			}
		}
		return ScriptKindUnknown;
	}

	// Given a name and a list of names that are *not* equal to the name, return a spelling suggestion if there is one that is close enough.
	// Names less than length 3 only check for case-insensitive equality.
	//
	// find the candidate with the smallest Levenshtein distance,
	//
	//	except for candidates:
	//	  * With no name
	//	  * Whose length differs from the target name by more than 0.34 of the length of the name.
	//	  * Whose levenshtein distance is more than 0.4 of the length of the name
	//	    (0.4 allows 1 substitution/transposition for every 5 characters,
	//	     and 1 insertion/deletion at 3 characters)
	//
	// @internal
	// PORT: Go `len(candidateName)` is a UTF-8 byte length (compared with the rune count of name,
	// as upstream does): computed with utf8Len. `[]rune(s)` decodes UTF-16; a lone surrogate
	// becomes one RuneError (Go: invalid UTF-8 bytes give one RuneError per byte).
	public static function GetSpellingSuggestion<T>(name:String, candidates:Iterator<T>, getName:(T) -> String, compare:(T, T) -> Int,
			?zero:T):T {
		final runeName = runes(name);
		final maximumLengthDifference = max(2, Std.int(runeName.length * 0.34));
		var bestDistance = Math.Floor(runeName.length * 0.4) + 0.9; // If the best result is worse than this, don't bother.
		final buffers = levenshteinBuffersPoolGet();
		var bestCandidate:T = zero;
		var hasBest = false;
		for (candidate in candidates) {
			final candidateName = getName(candidate);
			final candidateLen = utf8Len(candidateName);
			final maxLen = max(candidateLen, runeName.length);
			final minLen = min(candidateLen, runeName.length);
			if (candidateName != "" && maxLen - minLen <= maximumLengthDifference) {
				if (candidateName == name) {
					continue;
				}
				// Only consider candidates less than 3 characters long when they differ by case.
				// Otherwise, don't bother, since a user would usually notice differences of a 2-character name.
				if (candidateLen < 3 && !Strings.EqualFold(candidateName, name)) {
					continue;
				}
				final distance = levenshteinWithMax(buffers, runeName, runes(candidateName), bestDistance);
				if (distance < 0) {
					continue;
				}
				Debug.Assert(distance <= bestDistance); // Else `levenshteinWithMax` should return undefined
				if (distance < bestDistance) {
					bestDistance = distance;
					bestCandidate = candidate;
					hasBest = true;
				} else if (!hasBest || compare(candidate, bestCandidate) < 0) {
					bestCandidate = candidate;
					hasBest = true;
				}
			}
		}
		// PORT: `defer levenshteinBuffersPool.Put(buffers)`; a panic only loses a pooled buffer.
		levenshteinBuffersPoolPut(buffers);
		return bestCandidate;
	}

	public static function GetSpellingSuggestionForStrings(name:String, candidates:Iterator<String>):String {
		return GetSpellingSuggestion(name, candidates, Identity, Strings.Compare, "");
	}

	// PORT: Go []rune(s) on a UTF-16 string.
	static function runes(s:String):Array<Int> {
		final result = new Array<Int>();
		var i = 0;
		while (i < s.length) {
			final r = Utf16.DecodeRuneInString(s, i);
			result.push(r);
			i += Utf16.RuneLen(r);
		}
		return result;
	}

	// PORT: Go len(s) (UTF-8 byte length) of a UTF-16 string. A lone surrogate counts 3 bytes
	// (its WTF-8 encoding).
	static function utf8Len(s:String):Int {
		var n = 0;
		var i = 0;
		while (i < s.length) {
			final c = StringTools.fastCodeAt(s, i);
			if (c < 0x80) {
				n += 1;
			} else if (c < 0x800) {
				n += 2;
			} else if (c >= 0xD800 && c < 0xDC00 && i + 1 < s.length && StringTools.fastCodeAt(s, i + 1) >= 0xDC00
				&& StringTools.fastCodeAt(s, i + 1) < 0xE000) {
				n += 4;
				i++;
			} else {
				n += 3;
			}
			i++;
		}
		return n;
	}

	// PORT: sync.Pool → a free list (single-threaded).
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — a free list per thread (go.Par.slot)
	static final levenshteinBuffersPools:Array<Array<LevenshteinBuffers>> = [for (_ in 0...go.Par.SLOTS) []];
	static var levenshteinBuffersPool(get, never):Array<LevenshteinBuffers>;

	static inline function get_levenshteinBuffersPool()
		return levenshteinBuffersPools[go.Par.slot];
	#else
	static final levenshteinBuffersPool:Array<LevenshteinBuffers> = [];
	#end

	static function levenshteinBuffersPoolGet():LevenshteinBuffers {
		final b = levenshteinBuffersPool.pop();
		return b != null ? b : new LevenshteinBuffers();
	}

	static function levenshteinBuffersPoolPut(b:LevenshteinBuffers):Void {
		levenshteinBuffersPool.push(b);
	}

	static function levenshteinWithMax(buffers:LevenshteinBuffers, s1:Array<Int>, s2:Array<Int>, maxValue:Float):Float {
		final bufferSize = s2.length + 1;
		buffers.previous.resize(bufferSize);
		buffers.current.resize(bufferSize);

		var previous = buffers.previous;
		var current = buffers.current;

		final big = maxValue + 0.01;
		for (i in 0...previous.length) {
			previous[i] = i;
		}
		for (i in 1...s1.length + 1) {
			final c1 = s1[i - 1];
			final minJ = max(Std.int(Math.Ceil(i - maxValue)), 1);
			final maxJ = min(Std.int(Math.Floor(maxValue + i)), s2.length);
			var colMin:Float = i;
			current[0] = colMin;
			for (j in 1...minJ) {
				current[j] = big;
			}
			for (j in minJ...maxJ + 1) {
				var substitutionDistance:Float, dist:Float;
				if (Unicode.ToLower(s1[i - 1]) == Unicode.ToLower(s2[j - 1])) {
					substitutionDistance = previous[j - 1] + 0.1;
				} else {
					substitutionDistance = previous[j - 1] + 2;
				}
				if (c1 == s2[j - 1]) {
					dist = previous[j - 1];
				} else {
					dist = Math.Min(previous[j] + 1, Math.Min(current[j - 1] + 1, substitutionDistance));
				}
				current[j] = dist;
				colMin = Math.Min(colMin, dist);
			}
			for (j in maxJ + 1...s2.length + 1) {
				current[j] = big;
			}
			if (colMin > maxValue) {
				// Give up -- everything in this column is > max and it can't get better in future columns.
				return -1;
			}
			final tmp = previous;
			previous = current;
			current = tmp;
		}
		final res = previous[s2.length];
		if (res > maxValue) {
			return -1;
		}
		return res;
	}

	public static function Identity<T>(t:T):T {
		return t;
	}

	public static function CheckEachDefined<S>(s:Null<Array<S>>, msg:String):Null<Array<S>> {
		if (s != null) {
			for (value in s) {
				if (value == null) {
					throw msg;
				}
			}
		}
		return s;
	}

	public static function IndexAfter(s:String, pattern:String, startIndex:Int):Int {
		final matched = s.substring(startIndex).indexOf(pattern);
		if (matched == -1) {
			return -1;
		} else {
			return matched + startIndex;
		}
	}

	public static function ShouldRewriteModuleSpecifier(specifier:String, compilerOptions:CompilerOptions):Bool {
		return compilerOptions.RewriteRelativeImportExtensions.IsTrue() && Tspath.PathIsRelative(specifier)
			&& !Tspath.IsDeclarationFileName(specifier) && Tspath.HasTSFileExtension(specifier);
	}

	public static inline function SingleElementSlice<T>(element:Null<T>):Null<Array<T>> {
		return element == null ? null : [element];
	}

	public static function ConcatenateSeq<T>(...seqs:Null<Iterator<T>>):Iterator<T> {
		return new ConcatenateSeqIterator<T>(seqs.toArray());
	}

	// Enumerate returns a sequence of (index, value) pairs from the input sequence.
	public static function Enumerate<T>(seq:Iterator<T>):EnumerateIterator<T> {
		return new EnumerateIterator<T>(seq);
	}

	static function comparableValuesEqual<T>(a:T, b:T):Bool {
		return a == b;
	}

	// DiffMaps compares two maps m1 and m2 and calls the provided callbacks for added, removed, and changed entries.
	// onAdded is called for each key-value pair that is in m2 but not in m1.
	// onRemoved is called for each key-value pair that is in m1 but not in m2.
	// onChanged is called for each key where the value in m1 differs from the value in m2.
	public static function DiffMaps<K, V>(m1:Null<GoMap<K, V>>, m2:Null<GoMap<K, V>>, onAdded:Null<(K, V) -> Void>, onRemoved:Null<(K, V) -> Void>,
			onChanged:Null<(K, V, V) -> Void>):Void {
		DiffMapsFunc(m1, m2, comparableValuesEqual, onAdded, onRemoved, onChanged);
	}

	// DiffMapsFunc compares two maps m1 and m2 and calls the provided callbacks for added, removed, and changed entries.
	// onAdded is called for each key-value pair that is in m2 but not in m1.
	// onRemoved is called for each key-value pair that is in m1 but not in m2.
	// onChanged is called for each key where the value in m1 differs from the value in m2.
	public static function DiffMapsFunc<K, V1, V2>(m1:Null<GoMap<K, V1>>, m2:Null<GoMap<K, V2>>, equalValues:(V1, V2) -> Bool,
			onAdded:Null<(K, V2) -> Void>, onRemoved:Null<(K, V1) -> Void>, onChanged:Null<(K, V1, V2) -> Void>):Void {
		if (onAdded != null && m2 != null) {
			for (k in m2.keys()) {
				final v2 = m2.get(k);
				if (m1 == null || !m1.exists(k)) {
					onAdded(k, v2);
				}
			}
		}
		if (onChanged == null && onRemoved == null) {
			return;
		}
		if (m1 != null) {
			for (k in m1.keys()) {
				final v1 = m1.get(k);
				if (m2 != null && m2.exists(k)) {
					final v2 = m2.get(k);
					if (onChanged != null && !equalValues(v1, v2)) {
						onChanged(k, v1, v2);
					}
				} else {
					onRemoved(k, v1);
				}
			}
		}
	}

	// CopyMapInto is maps.Copy, unless dst is nil, in which case it clones and returns src.
	// Use CopyMapInto anywhere you would use maps.Copy preceded by a nil check and map initialization.
	public static function CopyMapInto<K, V>(dst:Null<GoMap<K, V>>, src:Null<GoMap<K, V>>):Null<GoMap<K, V>> {
		if (dst == null) {
			return Maps.Clone(src);
		}
		Maps.Copy(dst, src);
		return dst;
	}

	// UnorderedEqual returns true if s1 and s2 contain the same elements, regardless of order.
	public static function UnorderedEqual<T>(s1:Null<Array<T>>, s2:Null<Array<T>>):Bool {
		if (len(s1) != len(s2)) {
			return false;
		}
		final counts = new GoMap<T, Int>();
		if (s1 != null) {
			for (v in s1) {
				final c:Null<Int> = counts.get(v);
				counts.set(v, (c == null ? 0 : c) + 1);
			}
		}
		if (s2 != null) {
			for (v in s2) {
				final c:Null<Int> = counts.get(v);
				final n = (c == null ? 0 : c) - 1;
				counts.set(v, n);
				if (n < 0) {
					return false;
				}
			}
		}
		return true;
	}

	// slices.Contains(slice[:n], value)
	static function containsPrefix<T>(slice:Array<T>, n:Int, value:T):Bool {
		for (i in 0...n)
			if (slice[i] == value)
				return true;
		return false;
	}

	public static function Deduplicate<T>(slice:Null<Array<T>>):Null<Array<T>> {
		if (len(slice) > 1) {
			for (i in 0...slice.length) {
				if (containsPrefix(slice, i, slice[i])) {
					final result = slice.slice(0, i);
					for (k in i + 1...slice.length) {
						final value = slice[k];
						if (!Slices.Contains(result, value)) {
							result.push(value);
						}
					}
					return result;
				}
			}
		}
		return slice;
	}

	// PORT: Go compacts into the argument's backing array and returns slice[:n]; here the argument
	// array is compacted and truncated in place, and returned (see header).
	public static function DeduplicateSorted<T>(slice:Null<Array<T>>, isEqual:(a:T, b:T) -> Bool):Null<Array<T>> {
		if (len(slice) == 0) {
			return slice;
		}
		var last = slice[0];
		var n = 1; // deduplicated := slice[:1]
		for (i in 1...slice.length) {
			final next = slice[i];
			if (isEqual(last, next)) {
				continue;
			}

			slice[n++] = next; // deduplicated = append(deduplicated, next)
			last = next;
		}

		slice.resize(n);
		return slice;
	}

	// CompareBooleans treats true as greater than false.
	public static inline function CompareBooleans(a:Bool, b:Bool):Int {
		return (a && !b) ? 1 : ((!a && b) ? -1 : 0);
	}

	// --- nodemodules.go ---

	// require('module').builtinModules.filter(x => !x.match(/^(?:_|node:)/))
	public static final UnprefixedNodeCoreModules:StringMap<Bool> = boolSet([
		"assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram",
		"diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises", "http", "http2", "https", "inspector",
		"inspector/promises", "module", "net", "os", "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring",
		"readline", "readline/promises", "repl", "stream", "stream/consumers", "stream/promises", "stream/web", "string_decoder", "sys",
		"timers", "timers/promises", "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib",
	]);

	// require('module').builtinModules.filter(x => x.startsWith('node:'))
	public static final ExclusivelyPrefixedNodeCoreModules:StringMap<Bool> = boolSet([
		"node:quic", "node:sea", "node:sqlite", "node:test", "node:test/reporters",
	]);

	// PORT: Go map literal `map[string]bool{"x": true, ...}`.
	static function boolSet(keys:Array<String>):StringMap<Bool> {
		final m = new StringMap<Bool>();
		for (k in keys)
			m.set(k, true);
		return m;
	}

	// PORT: sync.OnceValue → lazy static.
	static var nodeCoreModulesValue:Null<StringMap<Bool>> = null;

	public static function NodeCoreModules():StringMap<Bool> {
		if (nodeCoreModulesValue == null) {
			final nodeCoreModules = new StringMap<Bool>();
			for (unprefixed in UnprefixedNodeCoreModules.keys()) {
				nodeCoreModules.set(unprefixed, true);
				nodeCoreModules.set("node:" + unprefixed, true);
			}
			for (k in ExclusivelyPrefixedNodeCoreModules.keys()) // maps.Copy
				nodeCoreModules.set(k, ExclusivelyPrefixedNodeCoreModules.get(k));
			nodeCoreModulesValue = nodeCoreModules;
		}
		return nodeCoreModulesValue;
	}

	public static function NonRelativeModuleNameForTypingCache(moduleName:String):String {
		if (NodeCoreModules().get(moduleName) == true) {
			return "node";
		}
		return moduleName;
	}

	// --- pattern.go ---

	public static function TryParsePattern(pattern:String):Pattern {
		final starIndex = pattern.indexOf("*");
		if (starIndex == -1 || pattern.substring(starIndex + 1).indexOf("*") < 0) {
			return new Pattern(pattern, starIndex);
		}
		return new Pattern();
	}

	public static function FindBestPatternMatch<T>(values:Null<Array<T>>, getPattern:(v:T) -> Pattern, candidate:String, ?zero:T):T {
		var bestPattern:T = zero;
		var longestMatchPrefixLength = -1;
		if (values != null) {
			for (value in values) {
				final pattern = getPattern(value);
				if ((pattern.StarIndex == -1 || pattern.StarIndex > longestMatchPrefixLength) && pattern.Matches(candidate)) {
					bestPattern = value;
					longestMatchPrefixLength = pattern.StarIndex;
				}
			}
		}
		return bestPattern;
	}

	// --- projectreference.go ---

	public static function ResolveProjectReferencePath(ref:ProjectReference):String {
		return ResolveConfigFileNameOfProjectReference(ref.Path);
	}

	public static function ResolveConfigFileNameOfProjectReference(path:String):String {
		if (Tspath.FileExtensionIs(path, Tspath.ExtensionJson)) {
			return path;
		}
		return Tspath.CombinePaths(path, "tsconfig.json");
	}

	// --- semaphore.go ---

	public static function NewLimitedSemaphore(maxConcurrency:Int):LimitedSemaphore {
		if (maxConcurrency <= 0) {
			throw "maxConcurrency must be positive";
		}
		final s = new LimitedSemaphore(maxConcurrency);
		s.release = function() {
			s.receive();
		};
		return s;
	}

	// --- text.go ---

	public static inline function NewTextRange(pos:Int, end:Int):TextRange {
		return new TextRange(pos, end);
	}

	public static inline function UndefinedTextRange():TextRange {
		return new TextRange(-1, -1);
	}

	public static inline function CompareTextRanges(r1:TextRange, r2:TextRange):Int {
		final c = r1.pos - r2.pos;
		return c != 0 ? c : r1.end - r2.end;
	}

	// --- textchange.go ---

	public static function ApplyBulkEdits(text:String, edits:Null<Array<TextChange>>):String {
		final b = new StringBuf();
		var lastEnd = 0;
		if (edits != null) {
			for (e in edits) {
				final start = e.TextRange.Pos();
				if (start != lastEnd) {
					b.add(text.substring(lastEnd, e.TextRange.Pos()));
				}
				b.add(e.NewText);

				lastEnd = e.TextRange.End();
			}
		}
		b.add(text.substring(lastEnd));

		return b.toString();
	}

	// --- tristate.go ---

	public static inline function BoolToTristate(b:Bool):Tristate {
		return b ? TSTrue : TSFalse;
	}

	// --- version.go ---

	// This is a var so it can be overridden by ldflags.
	static var version = "7.0.2";

	public static function Version():String {
		return version;
	}

	static final versionMajorMinor:String = {
		var seenMajor = false;
		// strings.IndexFunc(version, ...)
		var i = -1;
		for (k in 0...version.length) {
			final r = StringTools.fastCodeAt(version, k);
			if (r == ".".code) {
				if (seenMajor) {
					i = k;
					break;
				}
				seenMajor = true;
			}
		}
		if (i == -1) {
			throw "invalid version string: " + version;
		}
		version.substring(0, i);
	};

	public static function VersionMajorMinor():String {
		return versionMajorMinor;
	}

	// --- workgroup.go ---

	// PORT: single-threaded (see Workgroup.hx): always a singleThreadedWorkGroup.
	public static function NewWorkGroup(singleThreaded:Bool):WorkGroup {
		return new SingleThreadedWorkGroup();
	}

	// NewThrottleGroup creates a new ThrottleGroup with the given context and semaphore for concurrency limiting.
	// PORT: Go `chan struct{}` → Any (unused, see Workgroup.hx); errgroup.WithContext's derived
	// context is not needed (no cancellation).
	public static function NewThrottleGroup(ctx:Context, semaphore:Any):ThrottleGroup {
		return new ThrottleGroup(semaphore);
	}
}

// ECMALineStarts
typedef ECMALineStarts = Array<TextPos>;

// UTF16Offset represents a character offset measured in UTF-16 code units.
typedef UTF16Offset = Int;

// Go unexported levenshteinBuffers.
class LevenshteinBuffers {
	public var previous:Array<Float> = [];
	public var current:Array<Float> = [];

	public function new() {}
}

// PORT: iter.Seq returned by FilterSeq.
class FilterSeqIterator<T> {
	final slice:Null<Array<T>>;
	final f:(T) -> Bool;
	var i:Int = 0;

	public function new(slice:Null<Array<T>>, f:(T) -> Bool) {
		this.slice = slice;
		this.f = f;
	}

	public function hasNext():Bool {
		if (slice == null)
			return false;
		while (i < slice.length) {
			if (f(slice[i]))
				return true;
			i++;
		}
		return false;
	}

	public function next():T {
		return slice[i++];
	}
}

// PORT: iter.Seq returned by ComputeECMALineStartsSeq (the Go generator as a state machine).
class ECMALineStartsSeqIterator {
	var text:String;
	var textLen:TextPos;
	var pos:TextPos = 0;
	var lineStart:TextPos = 0;
	var finished:Bool = false;
	var hasValue:Bool = false;
	var value:TextPos = 0;

	public function new(text:String) {
		this.text = text;
		this.textLen = text.length;
	}

	// PORT: perf — starts the sequence again over another text, so that a hot caller (TextWriter, per written string)
	// reuses one iterator instead of one allocation per call.
	public function reset(text:String):ECMALineStartsSeqIterator {
		this.text = text;
		this.textLen = text.length;
		pos = 0;
		lineStart = 0;
		finished = false;
		hasValue = false;
		value = 0;
		return this;
	}

	// Runs the generator until the next yield.
	// PORT: perf — the position in a local while scanning (fields are memory on every target).
	function advance():Void {
		final text = this.text, textLen = this.textLen;
		var pos = this.pos;
		while (pos < textLen) {
			final b = StringTools.fastCodeAt(text, pos);
			if (b < Utf16.RuneSelf) {
				pos++;
				if (b == "\r".code || b == "\n".code) {
					if (b == "\r".code) {
						if (pos < textLen && StringTools.fastCodeAt(text, pos) == "\n".code) {
							pos++;
						}
					}
					// fallthrough
					this.pos = pos;
					value = lineStart;
					hasValue = true;
					lineStart = pos;
					return;
				}
			} else {
				final ch = Utf16.DecodeRuneInString(text, pos);
				pos += Utf16.RuneLen(ch);
				if (Stringutil.IsLineBreak(ch)) {
					this.pos = pos;
					value = lineStart;
					hasValue = true;
					lineStart = pos;
					return;
				}
			}
		}
		this.pos = pos;
		value = lineStart;
		hasValue = true;
		finished = true;
	}

	public function hasNext():Bool {
		if (!hasValue && !finished)
			advance();
		return hasValue;
	}

	public function next():TextPos {
		hasNext();
		hasValue = false;
		return value;
	}
}

// PORT: iter.Seq returned by ConcatenateSeq.
class ConcatenateSeqIterator<T> {
	final seqs:Array<Null<Iterator<T>>>;
	var i:Int = 0;

	public function new(seqs:Array<Null<Iterator<T>>>) {
		this.seqs = seqs;
	}

	public function hasNext():Bool {
		while (i < seqs.length) {
			final seq = seqs[i];
			if (seq != null && seq.hasNext())
				return true;
			i++;
		}
		return false;
	}

	public function next():T {
		hasNext();
		return seqs[i].next();
	}
}

// PORT: iter.Seq2[int, T] returned by Enumerate. Use `for (i => v in Core.Enumerate(seq))`.
// next() returns the iterator itself with `key` / `value` set (no allocation per entry).
class EnumerateIterator<T> {
	final seq:Iterator<T>;
	var i:Int = 0;

	public var key:Int = 0;
	public var value:T;

	public function new(seq:Iterator<T>) {
		this.seq = seq;
	}

	public function hasNext():Bool {
		return seq.hasNext();
	}

	public function next():EnumerateIterator<T> {
		key = i++;
		value = seq.next();
		return this;
	}
}
