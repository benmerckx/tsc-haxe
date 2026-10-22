package go;

#if (target.name == "hxmc" && hxmc.wasm_gc)
typedef OsHxmc = OsGc;
#elseif (target.name == "hxmc" && hxmc.target == "wasm32-wasi")
typedef OsHxmc = OsWasi;
#elseif (target.name == "hxmc")
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// PORT: hxmc — the C library calls of OsNative (as the cpp branch's go_os_* helpers), Linux x86-64
// layouts (struct stat: st_mode at 24, st_size at 48, st_mtim at 88; struct timespec: 16 bytes, utimensat for utimes).
@:hxmc.c @:hxmc.fast private extern class C {
	static function stat(path:Ptr, st:Ptr):Int;
	static function lstat(path:Ptr, st:Ptr):Int;
	static function mkdir(path:Ptr, mode:Int):Int;
	static function unlink(path:Ptr):Int;
	static function rmdir(path:Ptr):Int;
	static function symlink(target:Ptr, path:Ptr):Int;
	static function utimensat(dirfd:Int, path:Ptr, ts:Ptr, flags:Int):Int;
	static function realpath(path:Ptr, buf:Ptr):Ptr;
	static function __errno_location():Ptr;
}

class OsHxmc {
	static inline function cstr(s:String):Ptr
		return @:privateAccess hxmc.rt.Str.toUtf8(s);

	static function errno():Int
		return Mem.getI32(C.__errno_location(), 0);

	public static function errname(e:Int):String {
		return switch e {
			case 2: "ENOENT";
			case 17: "EEXIST";
			case 20: "ENOTDIR";
			case 21: "EISDIR";
			case 13: "EACCES";
			case 1: "EPERM";
			case 39: "ENOTEMPTY";
			case 40: "ELOOP";
			case 22: "EINVAL";
			case 5: "EIO";
			case 36: "ENAMETOOLONG";
			case 16: "EBUSY";
			case 30: "EROFS";
			case 18: "EXDEV";
			case _: Std.string(e);
		}
	}

	// [errno] or [0, mode, size, mtime sec, mtime nsec]
	public static function stat(path:String, follow:Bool):Array<Float> {
		final p = cstr(path);
		final st = Mem.stack(256);
		final r = follow ? C.stat(p, st) : C.lstat(p, st);
		final e = r != 0 ? errno() : 0;
		LibC.free(p);
		if (r != 0)
			return [e];
		final size:Float = cast Mem.getI64(st, 48);
		final sec:Float = cast Mem.getI64(st, 88);
		final nsec:Float = cast Mem.getI64(st, 96);
		return [0, Mem.getI32(st, 24), size, sec, nsec];
	}

	public static function mkdir(path:String, perm:Int):Int {
		final p = cstr(path);
		final e = C.mkdir(p, perm) == 0 ? 0 : errno();
		LibC.free(p);
		return e;
	}

	public static function unlink(path:String):Int {
		final p = cstr(path);
		final e = C.unlink(p) == 0 ? 0 : errno();
		LibC.free(p);
		return e;
	}

	public static function rmdir(path:String):Int {
		final p = cstr(path);
		final e = C.rmdir(p) == 0 ? 0 : errno();
		LibC.free(p);
		return e;
	}

	public static function symlink(target:String, path:String):Int {
		final t = cstr(target), p = cstr(path);
		final e = C.symlink(t, p) == 0 ? 0 : errno();
		LibC.free(t);
		LibC.free(p);
		return e;
	}

	public static function utimes(path:String, atime:Float, mtime:Float):Int {
		final p = cstr(path);
		final tv = Mem.stack(32);
		final as = Std.int(std.Math.ffloor(atime)), ms = Std.int(std.Math.ffloor(mtime));
		Mem.setI64(tv, 0, as);
		Mem.setI64(tv, 8, Std.int((atime - as) * 1e6) * 1000); // microseconds, as the cpp branch's utimes
		Mem.setI64(tv, 16, ms);
		Mem.setI64(tv, 24, Std.int((mtime - ms) * 1e6) * 1000);
		final e = C.utimensat(-100, p, tv, 0) == 0 ? 0 : errno();
		LibC.free(p);
		return e;
	}

	#if tshx_parallel
	@:hxmc.threadLocal public static var realpathErrno:Int; // PORT: hxmc (-D tshx-parallel) — per thread
	#else
	public static var realpathErrno = 0;
	#end

	public static function realpath(path:String):Null<String> {
		final p = cstr(path);
		final buf = Mem.stack(4104);
		final r = C.realpath(p, buf);
		realpathErrno = r.isNull() ? errno() : 0;
		LibC.free(p);
		if (r.isNull())
			return null;
		return hxmc.rt.Str.ofUtf8(buf, LibC.strlen(buf).toInt());
	}
}
#end
