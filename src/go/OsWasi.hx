package go;

#if (target.name == "hxmc" && hxmc.target == "wasm32-wasi" && !hxmc.wasm_gc)
import hxmc.I64;
import hxmc.rt.wasm.Heap;
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.WasiApi;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// PORT: hxmc on wasm32-wasi — OsHxmc's functions over WASI's path calls, as wasi-libc makes them: a path is made
// absolute and resolved against its preopened directory by hxmc's runtime (hxmc.rt.wasm.Wasi; hxmc's node runner
// preopens "/"). The results are WASI's errno values (wasi-libc's errno). WASI has no permissions (the mode is the
// file type's with rwxr-xr-x / rw-r--r--, as hxmc's sys.FileSystem.stat) and no realpath (resolved here, a component
// at a time).
@:hxmc.c @:hxmc.fast @:hxmc.lib("wasi_snapshot_preview1") private extern class Preview1 {
	static function path_readlink(fd:Int, path:Int, len:Int, buf:Int, bufLen:Int, used:Int):Int;
	static function path_symlink(old:Int, oldLen:Int, fd:Int, path:Int, len:Int):Int;
	static function path_filestat_set_times(fd:Int, flags:Int, path:Int, len:Int, atim:I64, mtim:I64, fstFlags:Int):Int;
}

class OsWasi {
	static inline final ENOENT = 44;
	static inline final ELOOP = 32;

	static inline function cstr(s:String):Ptr
		return @:privateAccess hxmc.rt.Str.toUtf8(s);

	public static function errname(e:Int):String {
		return switch e {
			case 44: "ENOENT";
			case 20: "EEXIST";
			case 54: "ENOTDIR";
			case 31: "EISDIR";
			case 2: "EACCES";
			case 63: "EPERM";
			case 55: "ENOTEMPTY";
			case 32: "ELOOP";
			case 28: "EINVAL";
			case 29: "EIO";
			case 37: "ENAMETOOLONG";
			case 10: "EBUSY";
			case 69: "EROFS";
			case 75: "EXDEV";
			case _: Std.string(e);
		}
	}

	// an operation on path: 0 stat into buf, 1 lstat into buf, 2 mkdir, 3 unlink, 4 rmdir, 5 readlink into buf
	// (n bytes, the length read at x), 6 symlink to the n bytes at x; the errno (ENOENT without a preopen)
	static function pathOp(path:String, op:Int, buf:Ptr, n:Int, x:Ptr):Int {
		final p = cstr(path);
		final a = Wasi.absolute(p);
		Heap.free(p);
		final relp = Mem.stack(8);
		final dir = Wasi.resolve(a, relp);
		var r = ENOENT;
		if (dir >= 0) {
			final rp = Mem.getPtr(relp, 0);
			final len = Heap.strlen(rp).toInt();
			r = switch op {
				case 0: WasiApi.path_filestat_get(dir, 1, Wasi.a32(rp), len, Wasi.a32(buf));
				case 1: WasiApi.path_filestat_get(dir, 0, Wasi.a32(rp), len, Wasi.a32(buf));
				case 2: WasiApi.path_create_directory(dir, Wasi.a32(rp), len);
				case 3: WasiApi.path_unlink_file(dir, Wasi.a32(rp), len);
				case 4: WasiApi.path_remove_directory(dir, Wasi.a32(rp), len);
				case 5: Preview1.path_readlink(dir, Wasi.a32(rp), len, Wasi.a32(buf), n, Wasi.a32(x));
				case _: Preview1.path_symlink(Wasi.a32(x), n, dir, Wasi.a32(rp), len);
			}
		}
		Heap.free(a);
		return r;
	}

	// [errno] or [0, mode, size, mtime sec, mtime nsec]
	// (filestat: dev 0, ino 8, filetype 16, nlink 24, size 32, atim 40, mtim 48, ctim 56)
	public static function stat(path:String, follow:Bool):Array<Float> {
		final st = Mem.stack(64);
		final r = pathOp(path, follow ? 0 : 1, st, 0, Ptr.nil());
		if (r != 0)
			return [r];
		final mode = switch Mem.getU8(st, 16) {
			case 1: 0x61A4; // block device
			case 2: 0x21A4; // character device
			case 3: 0x41ED; // directory
			case 4: 0x81A4; // regular file
			case 5 | 6: 0xC1A4; // socket
			case 7: 0xA1FF; // symbolic link
			case _: 0;
		}
		final size:Float = cast Mem.getI64(st, 32);
		final mtim = Mem.getI64(st, 48);
		final sec = mtim / 1000000000;
		final secF:Float = cast sec;
		final nsecF:Float = cast(mtim - sec * 1000000000);
		return [0, mode, size, secF, nsecF];
	}

	public static function mkdir(path:String, perm:Int):Int
		return pathOp(path, 2, Ptr.nil(), 0, Ptr.nil());

	public static function unlink(path:String):Int
		return pathOp(path, 3, Ptr.nil(), 0, Ptr.nil());

	public static function rmdir(path:String):Int
		return pathOp(path, 4, Ptr.nil(), 0, Ptr.nil());

	// (an absolute target is refused by WASI runtimes, EPERM under node: a link stays inside the preopened
	// directories; Go's own wasip1 os.Symlink passes the target on unchanged, with the same result)
	public static function symlink(target:String, path:String):Int {
		final t = cstr(target);
		final r = pathOp(path, 6, Ptr.nil(), Heap.strlen(t).toInt(), t);
		Heap.free(t);
		return r;
	}

	// seconds as nanoseconds, to the microsecond (as the native branch's utimensat)
	static function ns(t:Float):I64 {
		final s = Std.int(std.Math.ffloor(t));
		return (s : I64) * 1000000000 + ((Std.int((t - s) * 1e6) * 1000 : Int) : I64);
	}

	public static function utimes(path:String, atime:Float, mtime:Float):Int {
		final p = cstr(path);
		final a = Wasi.absolute(p);
		Heap.free(p);
		final relp = Mem.stack(8);
		final dir = Wasi.resolve(a, relp);
		var r = ENOENT;
		if (dir >= 0) {
			final rp = Mem.getPtr(relp, 0);
			// (lookupflags SYMLINK_FOLLOW; fstflags ATIM | MTIM)
			r = Preview1.path_filestat_set_times(dir, 1, Wasi.a32(rp), Heap.strlen(rp).toInt(), ns(atime), ns(mtime), 1 | 4);
		}
		Heap.free(a);
		return r;
	}

	public static var realpathErrno = 0;

	// a symbolic link's target, or null with realpathErrno set
	static function readlink(path:String):Null<String> {
		var cap = 256;
		final used = Mem.stack(8);
		while (true) {
			final buf = Heap.malloc(cap);
			final r = pathOp(path, 5, buf, cap, used);
			if (r != 0) {
				Heap.free(buf);
				realpathErrno = r;
				return null;
			}
			final n = Mem.getI32(used, 0);
			if (n < cap) {
				final s = hxmc.rt.Str.ofUtf8(buf, n);
				Heap.free(buf);
				return s;
			}
			Heap.free(buf);
			cap *= 2;
		}
	}

	// realpath(3): the absolute path's components in turn, each symbolic link replaced by its target (at most 40,
	// then ELOOP); a component that is missing or not a directory fails as lstat does on it
	public static function realpath(path:String):Null<String> {
		var todo = path.split("/");
		if (!StringTools.startsWith(path, "/"))
			todo = Sys.getCwd().split("/").concat(todo);
		final done:Array<String> = [];
		final st = Mem.stack(64);
		var links = 0;
		var i = 0;
		while (i < todo.length) {
			final c = todo[i++];
			if (c == "" || c == ".")
				continue;
			if (c == "..") {
				done.pop();
				continue;
			}
			done.push(c);
			final p = "/" + done.join("/");
			final r = pathOp(p, 1, st, 0, Ptr.nil());
			if (r != 0) {
				realpathErrno = r;
				return null;
			}
			if (Mem.getU8(st, 16) == 7) {
				if (++links > 40) {
					realpathErrno = ELOOP;
					return null;
				}
				final t = readlink(p);
				if (t == null)
					return null;
				done.pop();
				if (StringTools.startsWith(t, "/"))
					done.resize(0);
				todo = t.split("/").concat(todo.slice(i));
				i = 0;
			}
		}
		realpathErrno = 0;
		return "/" + done.join("/");
	}
}
#end
