# tsc-haxe on hxmc: performance log

Goal: tsc-haxe built by [hxmc](https://github.com/benmerckx/hxmc) (native Linux x86-64) at least as fast
as Go's tsgo `--singleThreaded` at parsing and type-checking the TypeScript 6 compiler sources.

Build: `tools/targets.sh` target `hxmc` (`HXMC_HOME`: an hxmc checkout with `make hxmc` done; hxmc
changes are on its branch `tsc-perf`). Output stays byte-identical to Go (stdout, exit code, every
output file) in every mode.

Workload: ts6-compiler as `tools/gate/realworld.sh` sets it up (tsconfig extending
`upstream/src/tsconfig-base.json` with `"types": []`):

- **decl**: as configured (declarations only),
- **check**: `--noEmit` (parse, bind, check),
- **full**: `--emitDeclarationOnly false --sourceMap`.

Measurement: a noisy 4-core VM (about 3x slower than the machine of UPSTREAM.md's table; a run varies
by up to 15%): wall time median (min) of 5-7 runs interleaved with Go `--singleThreaded` (go1), user
CPU, peak RSS; ratio = hxmc / go1 median wall of the same series. Instructions: callgrind, check
mode (deterministic). Go default (multithreaded) on the same machine: decl 2.09 s, full 2.95 s.

| Step | Commits (tsc-haxe / hxmc) | decl wall (min), RSS | check wall (min), RSS | full | check instr. | ratio decl / check |
|---|---|---|---|---|---|---|
| start: Go `--singleThreaded` | | 3.37-3.99 s, 407 MB | 3.6-3.8 s, 394 MB | 5.1-6.0 s, 527 MB | | |
| 0. hxmc as found (local patches) | e4b7a69 / objectmap | 5.39-5.87 s, 889 MB | 6.49 s (1 run), 892 MB | 7.58 s | 25.38 G (after 1) | 1.5 / 1.7 |
| 1. go.IdentityMap = ObjectMap on hxmc | 6cf0f03 | 5.35 s (5.03), 543 MB | 5.05 s (5.01), 539 MB | | 25.38 G | 1.44 / 1.32 |
| 2. branch threading of &&/\|\| chains, TESTI | / 760ac71 | 5.34 s (4.97), 543 MB | 5.03 s (4.89), 538 MB | | 23.57 G (-7.1%) | 1.34 / 1.37 |
| 3. JSDoc text prefix without a copy (allocation 2.1 -> 1.05 GB) | 4f6c63e | 5.20 s (4.75), 485 MB | 5.20 s (4.89), 485 MB | 7.14 s, 510 MB | 22.33 G | (noise) |
| 4. old space's first limit 512 MB (no major collection) | 9430753 / 5f0941c | 4.64 s (4.39), 394 MB | 4.34 s (4.16), 390 MB | 6.79 s, 879 MB | | 1.21 / 1.16 |
| 5. KeyHasher keys as 16-bit units on hxmc | 5ff37be | | | | 20.30 G | |
| 6. dynEq fast paths; FlowType per type; diagnostic-context stack (no closure per node) | c88429f, 520bff0 / 80ab8ba | | | | 20.34 G | |
| 7. spilled values kept for the next instruction, TESTI for shared bit tests | 0611581 / e2730a5 | | | | 19.94 G | |
| 8. LinkStore links on the key objects (no identity map per store) | f5a0c18 | 4.00 s (3.88), 348 MB | 3.55 s (3.42), 344 MB | | 19.64 G | 1.14 / 0.97 |
| 9. LinkStore reference compare, line starts in locals | 91b6650 | 3.98 s (3.51), 349 MB | 3.88 s (3.53), 344 MB | | 19.36 G | 1.02 / 1.06 |
| 10. write barrier tests the stored value first | / 83dbd92 | 3.87 s (3.57), 349 MB | 3.66 s (3.32), 345 MB | 5.43 s (5.13), 477 MB | 19.21 G | 1.09 / 1.01 (full 0.92) |
| 11. SharedFlow reuse, map snapshots at size, go.MapKey struct keys, NodeKindIs, KeyHasher capacity, ContainsNonASCII; hxmc: 4-byte UTF-8 decoding | 7ed1fe1..c5b8b6c / eeb91a2 | | | | 18.64 G | |
| 12. hxmc: gc-prefault helper thread; shrink-wrapped frames (-D hxmc.shrink-wrap); &&/\|\| chains as values threaded | 5622ad2, this commit / 3cb00e9, 84688b3, d9ea1f1 | **3.07 s (2.94), 356 MB** | **3.01 s (2.80), 350 MB** | **4.57 s (4.40), 490 MB** | 18.03 G (with the helper thread) | **0.90 / 0.92 (full 0.90)** |

Final (step 12), median of 5 runs interleaved with Go `--singleThreaded` on the same machine: Go decl
3.40 s / 406 MB, check 3.26 s / 395 MB, full 5.07 s / 520 MB; user CPU hxmc 2.95 / 2.93 / 4.31 s
against Go's 3.63 / 3.55 / 5.54 s. Every project of `tools/gate/realworld.sh --targets hxmc`
(ts6-compiler, ts6-solution in its three modes and four steps, native-preview, tsc-extension) is
byte-identical to Go. Peak memory is below Go's on ts6-compiler; on ts6-solution (several programs in
one process) it is about 1 GB against Go's 540-720 MB (the old space's copying major collection holds
both copies at its peak).

Notes per step:

1. `go.IdentityMap` had a generic branch (arrays plus an ObjectMap index); hxmc's ObjectMap is already
   insertion-ordered and hashed by address.
2. hxmc codegen: `a && b && c` materialized each intermediate boolean (setcc/movzx/test) because the
   join's phi was used twice; Opt.simplifyCfg now threads in rounds and Opt.condProp knows values
   branched on; `x & k != 0` is `test reg, k`.
3. Go slices `p.sourceText[:end-2]` per JSDoc comment; hxmc (like JVM, C#, Python) copied the file's
   text up to each comment. The scanner keeps the longer string and Go's `len(s.text)` (`textLen`).
4. The first major collection (at 256 MB) copied a live set still growing; with 512 MB the type
   check ends before any major collection. Full emit still runs one (later, so a higher peak).
5. KeyHasher built 7-bit packed ASCII through haxe.io.Bytes.getString (UTF-8 decoding); hxmc's
   strings take any 16-bit units.
8. Go's LinkStore is a map per store; the lookups missed the cache twice (index, entry). The links
   now hang off the key (`LinkHolder.links`), which the caller has just read. Peak memory also
   dropped (no identity maps).
10. hxmc's field barrier called the runtime for every store into an old object; now only for a
   young value stored into an old object.

11-12. hxmc's builds of tsc-haxe pass `-D hxmc.gc-prefault` (a helper thread faults in the old
   space's pages, as Go's GC workers run beside its single compiler thread) and `-D
   hxmc.shrink-wrap` (opt-in in hxmc: it costs the HaxeBenchmarks' nbody 8%).

Tried and dropped: pretenuring the parsed files into the old space (fewer minor collections, but
the copying collector lays the trees out depth-first, which the later passes over them need:
slower overall); interning identifiers process-wide on hxmc (no measurable change); a smaller
first StringMap table (2 MB less allocation).

## wasm32-wasi

`tools/targets.sh` target `hxmc-wasm`: the same build with `-D hxmc.target=wasm32-wasi`, run under
node by hxmc's WASI runner (`$HXMC_HOME/hxmc/bootstrap/wasi.mjs`, which preopens `/`). `go.Os` there is
`go.OsWasi` (WASI's path calls, WASI's errno values, realpath a component at a time over lstat and
readlink). The real-project gate passes on it as on `hxmc` (`tools/gate/realworld.sh --targets
hxmc,hxmc-wasm`: every project, mode and step). Unit tests: as `hxmc`, plus `TestSymlinkRealpath` and
`TestGetAccessibleEntries`, whose absolute symlink targets WASI refuses (EPERM under node; Go's own
wasip1 `os.Symlink` passes them on the same way).

ts6-compiler under node v24.21.0 against the unofficial `tsgo-wasm` 7.0.2 (Go's wasm build, 49 MB) and
the native `typescript@7.0.2` (npm; both from typescript-go 2bd066d8). Medians (min) of 7 interleaved
runs, wall time and peak RSS; Intel Xeon E-2356G @ 3.20 GHz (6 cores / 12 threads), 62 GB RAM, Linux
6.1, load average mostly 1.5-3.4:

| | decl | check | full |
|---|---|---|---|
| tsc7 native `--singleThreaded` | 1.70 s (1.69), 422 MB | 1.66 s (1.64), 402 MB | 2.73 s (2.57), 539 MB |
| tsgo-wasm | 12.72 s (12.29), 686 MB | 12.14 s (12.02), 674 MB | 17.29 s (16.53), 866 MB |
| hxmc wasm32-wasi (21.9 MB, hxmc `tsc-perf`) | 3.49 s (3.42), 792 MB | 3.38 s (3.32), 791 MB | 4.92 s (4.59), 875 MB |

## Threads (-D tshx-parallel)

`tools/targets.sh` target `hxmc-par`: the `hxmc` build with `-D tshx-parallel`, which runs Go's parallel work
groups on threads (`go.Par`: a pool of `TSHX_THREADS` threads, default 4, Go's default number of checkers;
`ts.core.ParallelWorkGroup`): file loading and parsing, binding, the checkers (one task per checker, each with
its files, as in Go), checker creation and emit (a task per file, holding its file's checker: Go locks the
checker in each EmitResolver call, which this port dropped). Without the define nothing changes.

What the threads share is made safe as Go makes it: node, symbol and checker ids (Go's atomics, here a
lock), `LinkStore`'s lists on the keys (prepended under a lock), `SourceFile`'s lazy fields (name table,
position map, bind, tokens, lazy JSDoc, data: a mutex per file), the program's `sync.Once`s, `SyncMap`, the
files parser's per-path mutex and `LoadOrStore`, the loader's counters and lib caches, `tsc -b`'s parse
cache (Go's per-entry mutex: without it a project could lose its lib files), `LimitedSemaphore` (a counting
semaphore). The port's pools and scratch state are per thread (`go.Par.slot`: parsers, binders, KeyHashers,
Levenshtein buffers, the module specifiers' and diagnostics' regexes, which keep their last match) or
thread-local (`@:hxmc.threadLocal`: the sort's and `getRelationKey`'s results).

Checked: the real-project gate on `hxmc-par` (every project, mode, step and stdout identical to Go), and a stress
test of 30 ts6-compiler declaration builds, 20 full emits and 10 ts6-solution builds at 2-8 threads against
Go's output, twice without a failure.

ts6-compiler, medians (min) of 7 interleaved runs (full emit: 4), Intel Xeon E-2356G (6 cores / 12
threads), Linux 6.1, load average 1.1-2.4; tsc7 is npm `typescript@7.0.2`:

| | decl | check | full |
|---|---|---|---|
| tsc7 `--singleThreaded` | 1.72 s (1.71) | 1.66 s (1.65) | 2.58 s (2.56) |
| tsc7 (multithreaded, its default) | 0.96 s (0.95) | 0.94 s (0.91) | 1.37 s (1.34) |
| `hxmc` `--singleThreaded` | 1.76 s (1.76) | 1.71 s (1.70) | 2.54 s (2.51) |
| `hxmc-par`, 4 threads | 1.10 s (1.08) | 1.07 s (1.06) | 1.60 s (1.58) |

(`hxmc-par` before binding and checker creation ran on threads, which took decl to 1.04 s.) The check is
bounded by one file: the checker that gets `checker.ts` (50k lines) takes about 0.85 s, the others 0.2-0.4 s,
with 4 checkers or 8 (`TSHX_DEBUG=1` prints each checker's time); Go has the same split. tsc7 uses about
40% more CPU time for its multithreaded run (3.4 s against 2.2 s on decl).

## WasmGC (-D hxmc.wasm-gc)

`tools/targets.sh` target `hxmc-wasmgc`: the wasm32-wasi build with `-D hxmc.wasm-gc` (Haxe's objects in the
engine's collector), run by hxmc's `wasmgc.mjs` under node. There is no linear memory, so `go.Os` is
`go.OsGc`, over `sys.FileSystem`: stat follows symbolic links either way, the mode is the file type's,
`symlink` and `utimes` are unsupported. It needs benmerckx/hxmc#36 (array literals of more than 10000
elements, `ObjectMap`'s 16-bit hashes spread, `FPHelper.i64ToDouble`'s low word).

ts6-compiler under node v24.21.0, single runs, same machine; output identical to Go: declarations 4.1 s,
full emit 6.0 s (67 s before hxmc#36's `ObjectMap` fix), `tsc -b` of the ts6 solution 8.6 s; tsgo-wasm
12.4 / 16.3 / 27.0 s.

Real-project gate: every output file of every project, mode and step identical to Go. The stdout of the
`--verbose` rebuilds (ts6-solution b2/b3, native-preview b2) is not: hxmc's WasmGC host gives `stat` times in
whole seconds (`sys.FileSystem.stat`), so inputs written in the same second tie and "is up to date because
newest input ..." can name another file; for the same reason an input changed in the second its output was
written could be taken as up to date. Go's are nanoseconds: an exact mtime needs a host call with
`mtimeNs` in hxmc's `wasmgc.mjs`.
