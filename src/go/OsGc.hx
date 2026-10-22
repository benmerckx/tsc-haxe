package go;

#if (target.name == "hxmc" && hxmc.wasm_gc)
// PORT: hxmc -D hxmc.wasm-gc — OsHxmc's functions over sys.FileSystem (hxmc's WasmGC host: node's fs). An
// approximation, enough to compile a project: stat follows symbolic links either way (no lstat), the mode is
// the file type's (rwxr-xr-x / rw-r--r--), a missing path is ENOENT (also where a C library would say
// ENOTDIR), symlink and utimes are unsupported (EPERM), realpath resolves no symbolic links.
class OsGc {
	static inline final ENOENT = 2;
	static inline final EPERM = 1;
	static inline final EEXIST = 17;

	public static function errname(e:Int):String {
		return switch e {
			case 2: "ENOENT";
			case 1: "EPERM";
			case 17: "EEXIST";
			case _: Std.string(e);
		}
	}

	// [errno] or [0, mode, size, mtime sec, mtime nsec]
	public static function stat(path:String, follow:Bool):Array<Float> {
		if (!sys.FileSystem.exists(path))
			return [ENOENT];
		final st = sys.FileSystem.stat(path);
		final ms = st.mtime.getTime();
		final sec = std.Math.ffloor(ms / 1000);
		return [0, sys.FileSystem.isDirectory(path) ? 0x41ED : 0x81A4, st.size, sec, std.Math.ffloor((ms - sec * 1000) * 1000000)];
	}

	public static function mkdir(path:String, perm:Int):Int {
		if (sys.FileSystem.exists(path))
			return EEXIST;
		sys.FileSystem.createDirectory(path);
		return sys.FileSystem.isDirectory(path) ? 0 : ENOENT;
	}

	public static function unlink(path:String):Int {
		if (!sys.FileSystem.exists(path))
			return ENOENT;
		sys.FileSystem.deleteFile(path);
		return 0;
	}

	public static function rmdir(path:String):Int {
		if (!sys.FileSystem.exists(path))
			return ENOENT;
		sys.FileSystem.deleteDirectory(path);
		return 0;
	}

	public static function symlink(target:String, path:String):Int
		return EPERM;

	public static function utimes(path:String, atime:Float, mtime:Float):Int
		return EPERM;

	public static var realpathErrno = 0;

	public static function realpath(path:String):Null<String> {
		if (!sys.FileSystem.exists(path)) {
			realpathErrno = ENOENT;
			return null;
		}
		realpathErrno = 0;
		return sys.FileSystem.fullPath(path);
	}
}
#end
