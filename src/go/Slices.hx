package go;

// Shims for Go package slices. A nil slice is `null` and behaves like an empty one.
class Slices {
	// slices.CompareFunc
	public static function CompareFunc<E1, E2>(s1:Null<Array<E1>>, s2:Null<Array<E2>>, cmp:(E1, E2) -> Int):Int {
		final len1 = s1 == null ? 0 : s1.length;
		final len2 = s2 == null ? 0 : s2.length;
		for (i in 0...len1) {
			if (i >= len2)
				return 1;
			final c = cmp(s1[i], s2[i]);
			if (c != 0)
				return c;
		}
		if (len1 < len2)
			return -1;
		return 0;
	}

	// slices.Contains (== equality; for String this is value equality on every target).
	// PORT: perf — Contains, ContainsFunc and IndexFunc are `inline` (single exit): typed with the
	// caller's element type (a generic hxcpp function boxes Int elements and takes a VirtualArray), and
	// a lambda literal argument is inlined.
	public static inline function Contains<E>(s:Null<Array<E>>, v:E):Bool {
		var found = false;
		if (s != null) {
			final n = s.length;
			var i = 0;
			while (i < n) {
				if (s[i] == v) {
					found = true;
					break;
				}
				i++;
			}
		}
		return found;
	}

	// slices.Collect: Go `iter.Seq` → Haxe Iterator. Like Go, an empty sequence gives a nil slice (null).
	public static function Collect<E>(seq:Iterator<E>):Null<Array<E>> {
		var s:Null<Array<E>> = null;
		for (v in seq) {
			if (s == null)
				s = [];
			s.push(v);
		}
		return s;
	}

	// slices.Equal: same length and elements equal with ==. A nil and an empty slice are equal.
	public static function Equal<E>(s1:Null<Array<E>>, s2:Null<Array<E>>):Bool {
		final len1 = s1 == null ? 0 : s1.length;
		final len2 = s2 == null ? 0 : s2.length;
		if (len1 != len2)
			return false;
		for (i in 0...len1)
			if (s1[i] != s2[i])
				return false;
		return true;
	}

	// slices.BinarySearchFunc: (position, found) → ValueOk (value = position, ok = found).
	public static function BinarySearchFunc<E, T>(x:Null<Array<E>>, target:T, cmp:(E, T) -> Int):go.Tuple.ValueOk<Int> {
		final n = x == null ? 0 : x.length;
		// Define cmp(x[-1], target) < 0 and cmp(x[n], target) >= 0 .
		// Invariant: cmp(x[i - 1], target) < 0, cmp(x[j], target) >= 0.
		var i = 0, j = n;
		while (i < j) {
			final h = (i + j) >>> 1; // avoid overflow when computing h
			// i ≤ h < j
			if (cmp(x[h], target) < 0) {
				i = h + 1; // preserves cmp(x[i - 1], target) < 0
			} else {
				j = h; // preserves cmp(x[j], target) >= 0
			}
		}
		// i == j, cmp(x[i-1], target) < 0, and cmp(x[j], target) (= cmp(x[i], target)) >= 0  =>  answer is i.
		return new go.Tuple.ValueOk<Int>(i, i < n && cmp(x[i], target) == 0);
	}

	// slices.BinarySearchFunc for hot call sites. PORT: perf — inline, so a lambda literal `cmp` is
	// inlined too: no function value call, which on hxcpp boxes every Int result outside -1..255.
	public static inline function BinarySearchFuncInline<E, T>(x:Null<Array<E>>, target:T, cmp:(E, T) -> Int):go.Tuple.ValueOk<Int> {
		final n = x == null ? 0 : x.length;
		var i = 0, j = n;
		while (i < j) {
			final h = (i + j) >>> 1;
			if (cmp(x[h], target) < 0) {
				i = h + 1;
			} else {
				j = h;
			}
		}
		return new go.Tuple.ValueOk<Int>(i, i < n && cmp(x[i], target) == 0);
	}

	// slices.Clone: a nil slice stays nil; otherwise a new array with the same elements.
	public static function Clone<E>(s:Null<Array<E>>):Null<Array<E>> {
		return s == null ? null : s.copy();
	}

	// slices.EqualFunc
	public static function EqualFunc<E1, E2>(s1:Null<Array<E1>>, s2:Null<Array<E2>>, eq:(E1, E2) -> Bool):Bool {
		final len1 = s1 == null ? 0 : s1.length;
		final len2 = s2 == null ? 0 : s2.length;
		if (len1 != len2)
			return false;
		for (i in 0...len1)
			if (!eq(s1[i], s2[i]))
				return false;
		return true;
	}

	// slices.Compare for []string (cmp.Compare on strings = Go byte order = code-point order).
	// PORT: specialised to String: Haxe cannot compare a generic E.
	public static function Compare(s1:Null<Array<String>>, s2:Null<Array<String>>):Int {
		return CompareFunc(s1, s2, Strings.Compare);
	}

	// slices.SortFunc: Go's pdqsort (unstable but deterministic), ported exactly from
	// go1.26.9 src/slices/zsortanyfunc.go so that elements comparing equal end up in Go's order.
	public static function SortFunc<E>(x:Null<Array<E>>, cmp:(E, E) -> Int):Void {
		if (x == null)
			return;
		final n = x.length;
		pdqsortCmpFunc(x, 0, n, bitsLen(n), cmp);
	}

	// slices.SortStableFunc: Go's insertion-sort blocks + SymMerge (stableCmpFunc), ported exactly.
	public static function SortStableFunc<E>(x:Null<Array<E>>, cmp:(E, E) -> Int):Void {
		if (x == null)
			return;
		stableCmpFunc(x, x.length, cmp);
	}

	// slices.Sort / sort.Strings for []string (Go byte order = code-point order).
	// PORT: specialised by element type: Haxe cannot compare a generic E. Go's zsortordered.go is the
	// same algorithm as zsortanyfunc.go with cmpLess(a, b) in place of cmp(a, b) < 0.
	public static function SortStrings(x:Null<Array<String>>):Void {
		SortFunc(x, Strings.Compare);
	}

	// slices.Sort / sort.Ints for []int.
	public static function SortInts(x:Null<Array<Int>>):Void {
		SortFunc(x, compareInt);
	}

	// slices.Sort / sort.Float64s for []float64: NaNs are ordered before other values (cmp.Less).
	// PORT: hxcpp loses the sign of -0.0 in a generic Array<E> (PORTING.md §7a), so this sorts an
	// index permutation with the same algorithm (same swaps) and then applies it to the typed array.
	public static function SortFloats(x:Null<Array<Float>>):Void {
		if (x == null)
			return;
		final f = x.copy();
		final idx = [for (i in 0...f.length) i];
		SortFunc(idx, (a, b) -> compareFloat(f[a], f[b]));
		for (i in 0...idx.length)
			x[i] = f[idx[i]];
	}

	static function compareInt(a:Int, b:Int):Int {
		return a < b ? -1 : (a > b ? 1 : 0);
	}

	// cmp.Compare for floats: cmp(a, b) < 0 exactly when Go's cmpLess(a, b) holds.
	static function compareFloat(a:Float, b:Float):Int {
		final an = a != a, bn = b != b;
		if (an)
			return bn ? 0 : -1;
		if (bn)
			return 1;
		return a < b ? -1 : (a > b ? 1 : 0);
	}

	// ---- pdqsort (go1.26.9 src/slices/zsortanyfunc.go + sort.go) ----

	// bits.Len(uint(n)) for n >= 0.
	static function bitsLen(n:Int):Int {
		var l = 0;
		while (n != 0) {
			n = n >>> 1;
			l++;
		}
		return l;
	}

	static inline final unknownHint = 0;
	static inline final increasingHint = 1;
	static inline final decreasingHint = 2;

	// Second results of choosePivot / partition (Go multiple returns). Read right after the call;
	// choosePivot saves and restores `swaps`, so a comparator that sorts again is still safe.
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — per thread
	@:hxmc.threadLocal static var pivotHint:Int;
	@:hxmc.threadLocal static var wasAlreadyPartitioned:Bool;
	@:hxmc.threadLocal static var swaps:Int;
	#else
	static var pivotHint = 0;
	static var wasAlreadyPartitioned = false;
	static var swaps = 0;
	#end

	// insertionSortCmpFunc sorts data[a:b] using insertion sort.
	static function insertionSortCmpFunc<E>(data:Array<E>, a:Int, b:Int, cmp:(E, E) -> Int):Void {
		for (i in a + 1...b) {
			var j = i;
			while (j > a && cmp(data[j], data[j - 1]) < 0) {
				final t = data[j];
				data[j] = data[j - 1];
				data[j - 1] = t;
				j--;
			}
		}
	}

	// siftDownCmpFunc implements the heap property on data[lo:hi].
	// first is an offset into the array where the root of the heap lies.
	static function siftDownCmpFunc<E>(data:Array<E>, lo:Int, hi:Int, first:Int, cmp:(E, E) -> Int):Void {
		var root = lo;
		while (true) {
			var child = 2 * root + 1;
			if (child >= hi)
				break;
			if (child + 1 < hi && cmp(data[first + child], data[first + child + 1]) < 0)
				child++;
			if (!(cmp(data[first + root], data[first + child]) < 0))
				return;
			final t = data[first + root];
			data[first + root] = data[first + child];
			data[first + child] = t;
			root = child;
		}
	}

	static function heapSortCmpFunc<E>(data:Array<E>, a:Int, b:Int, cmp:(E, E) -> Int):Void {
		final first = a;
		final lo = 0;
		final hi = b - a;
		// Build heap with greatest element at top.
		var i = Std.int((hi - 1) / 2);
		while (i >= 0) {
			siftDownCmpFunc(data, i, hi, first, cmp);
			i--;
		}
		// Pop elements, largest first, into end of data.
		i = hi - 1;
		while (i >= 0) {
			final t = data[first];
			data[first] = data[first + i];
			data[first + i] = t;
			siftDownCmpFunc(data, lo, i, first, cmp);
			i--;
		}
	}

	// pdqsortCmpFunc sorts data[a:b]. limit is the number of allowed bad (very unbalanced) pivots
	// before falling back to heapsort.
	static function pdqsortCmpFunc<E>(data:Array<E>, a:Int, b:Int, limit:Int, cmp:(E, E) -> Int):Void {
		final maxInsertion = 12;
		var wasBalanced = true; // whether the last partitioning was reasonably balanced
		var wasPartitioned = true; // whether the slice was already partitioned
		while (true) {
			final length = b - a;
			if (length <= maxInsertion) {
				insertionSortCmpFunc(data, a, b, cmp);
				return;
			}
			// Fall back to heapsort if too many bad choices were made.
			if (limit == 0) {
				heapSortCmpFunc(data, a, b, cmp);
				return;
			}
			// If the last partitioning was imbalanced, we need to breaking patterns.
			if (!wasBalanced) {
				breakPatternsCmpFunc(data, a, b, cmp);
				limit--;
			}
			var pivot = choosePivotCmpFunc(data, a, b, cmp);
			var hint = pivotHint;
			if (hint == decreasingHint) {
				reverseRangeCmpFunc(data, a, b);
				// The chosen pivot was pivot-a elements after the start of the array.
				// After reversing it is pivot-a elements before the end of the array.
				pivot = (b - 1) - (pivot - a);
				hint = increasingHint;
			}
			// The slice is likely already sorted.
			if (wasBalanced && wasPartitioned && hint == increasingHint) {
				if (partialInsertionSortCmpFunc(data, a, b, cmp))
					return;
			}
			// Probably the slice contains many duplicate elements, partition the slice into
			// elements equal to and elements greater than the pivot.
			if (a > 0 && !(cmp(data[a - 1], data[pivot]) < 0)) {
				final mid = partitionEqualCmpFunc(data, a, b, pivot, cmp);
				a = mid;
				continue;
			}
			final mid = partitionCmpFunc(data, a, b, pivot, cmp);
			wasPartitioned = wasAlreadyPartitioned;
			final leftLen = mid - a, rightLen = b - mid;
			final balanceThreshold = Std.int(length / 8);
			if (leftLen < rightLen) {
				wasBalanced = leftLen >= balanceThreshold;
				pdqsortCmpFunc(data, a, mid, limit, cmp);
				a = mid + 1;
			} else {
				wasBalanced = rightLen >= balanceThreshold;
				pdqsortCmpFunc(data, mid + 1, b, limit, cmp);
				b = mid;
			}
		}
	}

	// partitionCmpFunc does one quicksort partition. Returns newpivot; alreadyPartitioned goes to
	// wasAlreadyPartitioned.
	static function partitionCmpFunc<E>(data:Array<E>, a:Int, b:Int, pivot:Int, cmp:(E, E) -> Int):Int {
		var t = data[a];
		data[a] = data[pivot];
		data[pivot] = t;
		var i = a + 1, j = b - 1; // i and j are inclusive of the elements remaining to be partitioned
		while (i <= j && cmp(data[i], data[a]) < 0)
			i++;
		while (i <= j && !(cmp(data[j], data[a]) < 0))
			j--;
		if (i > j) {
			t = data[j];
			data[j] = data[a];
			data[a] = t;
			wasAlreadyPartitioned = true;
			return j;
		}
		t = data[i];
		data[i] = data[j];
		data[j] = t;
		i++;
		j--;
		while (true) {
			while (i <= j && cmp(data[i], data[a]) < 0)
				i++;
			while (i <= j && !(cmp(data[j], data[a]) < 0))
				j--;
			if (i > j)
				break;
			t = data[i];
			data[i] = data[j];
			data[j] = t;
			i++;
			j--;
		}
		t = data[j];
		data[j] = data[a];
		data[a] = t;
		wasAlreadyPartitioned = false;
		return j;
	}

	// partitionEqualCmpFunc partitions data[a:b] into elements equal to data[pivot] followed by
	// elements greater than data[pivot]. It assumes data[a:b] has no elements smaller than data[pivot].
	static function partitionEqualCmpFunc<E>(data:Array<E>, a:Int, b:Int, pivot:Int, cmp:(E, E) -> Int):Int {
		var t = data[a];
		data[a] = data[pivot];
		data[pivot] = t;
		var i = a + 1, j = b - 1;
		while (true) {
			while (i <= j && !(cmp(data[a], data[i]) < 0))
				i++;
			while (i <= j && cmp(data[a], data[j]) < 0)
				j--;
			if (i > j)
				break;
			t = data[i];
			data[i] = data[j];
			data[j] = t;
			i++;
			j--;
		}
		return i;
	}

	// partialInsertionSortCmpFunc partially sorts a slice, returns true if the slice is sorted at the end.
	static function partialInsertionSortCmpFunc<E>(data:Array<E>, a:Int, b:Int, cmp:(E, E) -> Int):Bool {
		final maxSteps = 5; // maximum number of adjacent out-of-order pairs that will get shifted
		final shortestShifting = 50; // don't shift any elements on short arrays
		var i = a + 1;
		for (_ in 0...maxSteps) {
			while (i < b && !(cmp(data[i], data[i - 1]) < 0))
				i++;
			if (i == b)
				return true;
			if (b - a < shortestShifting)
				return false;
			var t = data[i];
			data[i] = data[i - 1];
			data[i - 1] = t;
			// Shift the smaller one to the left.
			if (i - a >= 2) {
				var j = i - 1;
				while (j >= 1) { // Go: `j >= 1`, not `j > a`
					if (!(cmp(data[j], data[j - 1]) < 0))
						break;
					t = data[j];
					data[j] = data[j - 1];
					data[j - 1] = t;
					j--;
				}
			}
			// Shift the greater one to the right.
			if (b - i >= 2) {
				var j = i + 1;
				while (j < b) {
					if (!(cmp(data[j], data[j - 1]) < 0))
						break;
					t = data[j];
					data[j] = data[j - 1];
					data[j - 1] = t;
					j++;
				}
			}
		}
		return false;
	}

	// breakPatternsCmpFunc scatters some elements around in an attempt to break some patterns
	// that might cause imbalanced partitions in quicksort.
	static function breakPatternsCmpFunc<E>(data:Array<E>, a:Int, b:Int, cmp:(E, E) -> Int):Void {
		final length = b - a;
		if (length >= 8) {
			// xorshift(length) as a uint64 in two 32-bit halves; only the low half is used below.
			var hi = 0, lo = length;
			final mask = (1 << bitsLen(length)) - 1; // nextPowerOfTwo(length) - 1
			final base = a + Std.int(length / 4) * 2;
			for (idx in base - 1...base + 2) {
				// r ^= r << 13 (PORT: python — Math.Shl wraps to 32 bits; plain `<<` elsewhere)
				hi = hi ^ (Math.Shl(hi, 13) | (lo >>> 19));
				lo = lo ^ Math.Shl(lo, 13);
				// r ^= r >> 7
				lo = lo ^ ((lo >>> 7) | Math.Shl(hi, 25));
				hi = hi ^ (hi >>> 7);
				// r ^= r << 17
				hi = hi ^ (Math.Shl(hi, 17) | (lo >>> 15));
				lo = lo ^ Math.Shl(lo, 17);
				var other = lo & mask;
				if (other >= length)
					other -= length;
				final t = data[idx];
				data[idx] = data[a + other];
				data[a + other] = t;
			}
		}
	}

	// choosePivotCmpFunc chooses a pivot in data[a:b]; the sortedHint goes to pivotHint.
	// [0,8): static pivot. [8,shortestNinther): median-of-three. [shortestNinther,∞): Tukey ninther.
	static function choosePivotCmpFunc<E>(data:Array<E>, a:Int, b:Int, cmp:(E, E) -> Int):Int {
		final shortestNinther = 50;
		final maxSwaps = 4 * 3;
		final l = b - a;
		final q = Std.int(l / 4);
		var i = a + q * 1;
		var j = a + q * 2;
		var k = a + q * 3;
		final saved = swaps;
		swaps = 0;
		if (l >= 8) {
			if (l >= shortestNinther) {
				// Tukey ninther method, the idea came from Rust's implementation.
				i = medianCmpFunc(data, i - 1, i, i + 1, cmp);
				j = medianCmpFunc(data, j - 1, j, j + 1, cmp);
				k = medianCmpFunc(data, k - 1, k, k + 1, cmp);
			}
			// Find the median among i, j, k and stores it into j.
			j = medianCmpFunc(data, i, j, k, cmp);
		}
		final n = swaps;
		swaps = saved;
		pivotHint = n == 0 ? increasingHint : (n == maxSwaps ? decreasingHint : unknownHint);
		return j;
	}

	// medianCmpFunc returns x where data[x] is the median of data[a],data[b],data[c] (order2 inlined).
	static function medianCmpFunc<E>(data:Array<E>, a:Int, b:Int, c:Int, cmp:(E, E) -> Int):Int {
		var t;
		if (cmp(data[b], data[a]) < 0) {
			swaps++;
			t = a;
			a = b;
			b = t;
		}
		if (cmp(data[c], data[b]) < 0) {
			swaps++;
			t = b;
			b = c;
			c = t;
		}
		if (cmp(data[b], data[a]) < 0) {
			swaps++;
			t = a;
			a = b;
			b = t;
		}
		return b;
	}

	static function reverseRangeCmpFunc<E>(data:Array<E>, a:Int, b:Int):Void {
		var i = a;
		var j = b - 1;
		while (i < j) {
			final t = data[i];
			data[i] = data[j];
			data[j] = t;
			i++;
			j--;
		}
	}

	static function swapRangeCmpFunc<E>(data:Array<E>, a:Int, b:Int, n:Int):Void {
		for (i in 0...n) {
			final t = data[a + i];
			data[a + i] = data[b + i];
			data[b + i] = t;
		}
	}

	static function stableCmpFunc<E>(data:Array<E>, n:Int, cmp:(E, E) -> Int):Void {
		var blockSize = 20; // must be > 0
		var a = 0, b = blockSize;
		while (b <= n) {
			insertionSortCmpFunc(data, a, b, cmp);
			a = b;
			b += blockSize;
		}
		insertionSortCmpFunc(data, a, n, cmp);
		while (blockSize < n) {
			a = 0;
			b = 2 * blockSize;
			while (b <= n) {
				symMergeCmpFunc(data, a, a + blockSize, b, cmp);
				a = b;
				b += 2 * blockSize;
			}
			final m = a + blockSize;
			if (m < n)
				symMergeCmpFunc(data, a, m, n, cmp);
			blockSize *= 2;
		}
	}

	// symMergeCmpFunc merges the two sorted subsequences data[a:m] and data[m:b] using SymMerge
	// (Kim & Kutzner, ESA 2004). Assumes a < m && m < b.
	static function symMergeCmpFunc<E>(data:Array<E>, a:Int, m:Int, b:Int, cmp:(E, E) -> Int):Void {
		if (m - a == 1) {
			// Lowest index i such that data[i] >= data[a] for m <= i < b (i == b if none).
			var i = m;
			var j = b;
			while (i < j) {
				final h = (i + j) >>> 1;
				if (cmp(data[h], data[a]) < 0)
					i = h + 1;
				else
					j = h;
			}
			// Swap values until data[a] reaches the position before i.
			var k = a;
			while (k < i - 1) {
				final t = data[k];
				data[k] = data[k + 1];
				data[k + 1] = t;
				k++;
			}
			return;
		}
		if (b - m == 1) {
			// Lowest index i such that data[i] > data[m] for a <= i < m (i == m if none).
			var i = a;
			var j = m;
			while (i < j) {
				final h = (i + j) >>> 1;
				if (!(cmp(data[m], data[h]) < 0))
					i = h + 1;
				else
					j = h;
			}
			// Swap values until data[m] reaches the position i.
			var k = m;
			while (k > i) {
				final t = data[k];
				data[k] = data[k - 1];
				data[k - 1] = t;
				k--;
			}
			return;
		}
		final mid = (a + b) >>> 1;
		final n = mid + m;
		var start, r;
		if (m > mid) {
			start = n - b;
			r = mid;
		} else {
			start = a;
			r = m;
		}
		final p = n - 1;
		while (start < r) {
			final c = (start + r) >>> 1;
			if (!(cmp(data[p - c], data[c]) < 0))
				start = c + 1;
			else
				r = c;
		}
		final end = n - start;
		if (start < m && m < end)
			rotateCmpFunc(data, start, m, end);
		if (a < start && start < mid)
			symMergeCmpFunc(data, a, start, mid, cmp);
		if (mid < end && end < b)
			symMergeCmpFunc(data, mid, end, b, cmp);
	}

	// rotateCmpFunc rotates two consecutive blocks u = data[a:m] and v = data[m:b]: 'x u v y' → 'x v u y'.
	static function rotateCmpFunc<E>(data:Array<E>, a:Int, m:Int, b:Int):Void {
		var i = m - a;
		var j = b - m;
		while (i != j) {
			if (i > j) {
				swapRangeCmpFunc(data, m - i, m, j);
				i -= j;
			} else {
				swapRangeCmpFunc(data, m - i, m + j - i, i);
				j -= i;
			}
		}
		swapRangeCmpFunc(data, m - i, m, i);
	}

	// slices.Index (== equality): index of the first v in s, or -1.
	public static inline function Index<E>(s:Null<Array<E>>, v:E):Int { // PORT: perf (see Contains)
		var result = -1;
		if (s != null) {
			final n = s.length;
			var i = 0;
			while (i < n) {
				if (s[i] == v) {
					result = i;
					break;
				}
				i++;
			}
		}
		return result;
	}

	// slices.Concat: a new slice with the elements of all slices. Like Go, an empty result is
	// a nil slice (null).
	public static function Concat<E>(...slices:Null<Array<E>>):Null<Array<E>> {
		var result:Null<Array<E>> = null;
		for (s in slices) {
			if (s == null || s.length == 0)
				continue;
			if (result == null)
				result = [];
			for (x in s)
				result.push(x);
		}
		return result;
	}

	// slices.ContainsFunc: whether some element of s satisfies f.
	public static inline function ContainsFunc<E>(s:Null<Array<E>>, f:(E) -> Bool):Bool {
		return IndexFunc(s, f) >= 0;
	}

	// slices.IndexFunc: index of the first element of s that satisfies f, or -1.
	public static inline function IndexFunc<E>(s:Null<Array<E>>, f:(E) -> Bool):Int {
		var result = -1;
		if (s != null) {
			final n = s.length;
			var i = 0;
			while (i < n) {
				if (f(s[i])) {
					result = i;
					break;
				}
				i++;
			}
		}
		return result;
	}

	// slices.Reverse: reverses s in place.
	public static function Reverse<E>(s:Null<Array<E>>):Void {
		if (s == null)
			return;
		var i = 0;
		var j = s.length - 1;
		while (i < j) {
			final t = s[i];
			s[i] = s[j];
			s[j] = t;
			i++;
			j--;
		}
	}

	// slices.CompactFunc: replaces runs of elements for which eq(previous kept, x) is true by the first
	// element of the run; returns the shortened slice. Like Go, it modifies s in place (the result
	// shares the array; the tail is truncated).
	public static function CompactFunc<E>(s:Null<Array<E>>, eq:(E, E) -> Bool):Null<Array<E>> {
		if (s == null || s.length < 2)
			return s;
		var i = 1;
		for (k in 1...s.length) {
			if (!eq(s[k], s[k - 1])) {
				if (i != k)
					s[i] = s[k];
				i++;
			}
		}
		s.resize(i);
		return s;
	}
}
