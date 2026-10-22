package go;

import go.Errors.Error;
import go.Fs;
import go.Time;
import go.Tuple.ValueError;
import haxe.io.Bytes;

// Shim for the parts of Go package os used by the port (vfs/osvfs, nativepath, bundled, tests).
// File contents go through haxe.io.Bytes; native calls (stat/lstat, mkdir, unlink, rmdir,
// realpath, utimes, symlink) are implemented per target in class OsNative below:
//   JS (hxnodejs): require('fs') *Sync functions; the error is the Node error code ("ENOENT").
//   hxcpp: POSIX calls through untyped __cpp__; errno is mapped to the same code names.
//   C#:    the same POSIX calls through P/Invoke into libc (Linux only; see OsNative).
//   JVM: java.nio.file; Python: module os (OSError.errno → code name).
// PORT: POSIX semantics only (Linux, macOS). Windows paths/APIs are not implemented.
// PORT: errors are *PathError{Op, Path, Err} like Go; Err is an Errno with Go's message text for
// the common errno values. ModTime has millisecond precision on JS.
class Os {
	public static inline final O_RDONLY = 0x0;
	public static inline final O_WRONLY = 0x1;
	public static inline final O_RDWR = 0x2;
	public static inline final O_CREATE = 0x40;
	public static inline final O_EXCL = 0x80;
	public static inline final O_TRUNC = 0x200;
	public static inline final O_APPEND = 0x400;

	public static inline final PathSeparator = '/'.code;

	// Go syscall mode bits (S_IFMT etc.), identical on Linux and macOS.
	static inline final S_IFMT = 0xF000;
	static inline final S_IFBLK = 0x6000;
	static inline final S_IFCHR = 0x2000;
	static inline final S_IFDIR = 0x4000;
	static inline final S_IFIFO = 0x1000;
	static inline final S_IFLNK = 0xA000;
	static inline final S_IFREG = 0x8000;
	static inline final S_IFSOCK = 0xC000;
	static inline final S_ISUID = 0x800;
	static inline final S_ISGID = 0x400;
	static inline final S_ISVTX = 0x200;

	// os.fillFileStatFromSys: st_mode → FileMode.
	static function modeFromSys(m:Int):FileMode {
		var mode:FileMode = m & 511;
		switch (m & S_IFMT) {
			case S_IFBLK:
				mode = mode | ModeDevice;
			case S_IFCHR:
				mode = mode | ModeDevice | ModeCharDevice;
			case S_IFDIR:
				mode = mode | ModeDir;
			case S_IFIFO:
				mode = mode | ModeNamedPipe;
			case S_IFLNK:
				mode = mode | ModeSymlink;
			case S_IFREG:
			// nothing to do
			case S_IFSOCK:
				mode = mode | ModeSocket;
		}
		if (m & S_ISGID != 0) {
			mode = mode | ModeSetgid;
		}
		if (m & S_ISUID != 0) {
			mode = mode | ModeSetuid;
		}
		if (m & S_ISVTX != 0) {
			mode = mode | ModeSticky;
		}
		return mode;
	}

	static function basename(name:String):String {
		var i = name.length - 1;
		// Remove trailing slashes
		while (i > 0 && StringTools.fastCodeAt(name, i) == '/'.code) {
			name = name.substring(0, i);
			i--;
		}
		// Remove leading directory name
		i--;
		while (i >= 0) {
			if (StringTools.fastCodeAt(name, i) == '/'.code) {
				name = name.substring(i + 1);
				break;
			}
			i--;
		}
		return name;
	}

	static function stat(op:String, name:String, follow:Bool):ValueError<FileInfo> {
		final st = OsNative.stat(name, follow);
		if (st.err != null) {
			return new ValueError<FileInfo>(null, new PathError(op, name, Errno.of(st.err)));
		}
		return new ValueError<FileInfo>(new FileStat(basename(name), st.size, modeFromSys(st.mode),
			Time.Unix(haxe.Int64.fromFloat(st.mtimeSec), haxe.Int64.ofInt(st.mtimeNsec))), null);
	}

	// os.Stat
	public static function Stat(name:String):ValueError<FileInfo> {
		return stat("stat", name, true);
	}

	// os.Lstat
	public static function Lstat(name:String):ValueError<FileInfo> {
		return stat("lstat", name, false);
	}

	// Errno for a failed operation on name whose native error is unknown (hxcpp sys API).
	static function errnoFor(name:String, isDirOk:Bool):Errno {
		final st = OsNative.stat(name, true);
		if (st.err != null) {
			return Errno.of(st.err);
		}
		if (!isDirOk && (st.mode & S_IFMT) == S_IFDIR) {
			return Errno.of("EISDIR");
		}
		return Errno.of("EIO");
	}

	// os.ReadFile
	public static function ReadFile(name:String):ValueError<Bytes> {
		final st = OsNative.stat(name, true);
		if (st.err != null) {
			return new ValueError<Bytes>(null, new PathError("open", name, Errno.of(st.err)));
		}
		if ((st.mode & S_IFMT) == S_IFDIR) {
			return new ValueError<Bytes>(null, new PathError("read", name, Errno.of("EISDIR")));
		}
		try {
			return new ValueError<Bytes>(sys.io.File.getBytes(name), null);
		} catch (e:Dynamic) {
			return new ValueError<Bytes>(null, new PathError("open", name, errnoFor(name, false)));
		}
	}

	// os.WriteFile
	public static function WriteFile(name:String, data:Bytes, perm:FileMode):Null<Error> {
		final f = OpenFile(name, O_WRONLY | O_CREATE | O_TRUNC, perm);
		if (f.err != null) {
			return f.err;
		}
		final w = f.value.Write(data);
		final err1 = f.value.Close();
		if (w.err == null && err1 != null) {
			return err1;
		}
		return w.err;
	}

	// os.OpenFile (write modes only: O_WRONLY|O_CREATE with O_TRUNC or O_APPEND).
	public static function OpenFile(name:String, flag:Int, perm:FileMode):ValueError<OsFile> {
		final append = flag & O_APPEND != 0;
		#if js
		try {
			final fd:Int = js.Syntax.code("require('fs').openSync({0}, {1}, {2})", name, append ? "a" : "w", (perm : Int));
			return new ValueError<OsFile>(new OsFile(name, fd), null);
		} catch (e:Dynamic) {
			return new ValueError<OsFile>(null, new PathError("open", name, Errno.of(OsNative.jsCode(e))));
		}
		#else
		try {
			final out = append ? sys.io.File.append(name, true) : sys.io.File.write(name, true);
			return new ValueError<OsFile>(new OsFile(name, out), null);
		} catch (e:Dynamic) {
			// Find the reason: a missing or non-directory parent, or a directory at name.
			final st = OsNative.stat(name, true);
			var err:Errno;
			if (st.err == null && (st.mode & S_IFMT) == S_IFDIR) {
				err = Errno.of("EISDIR");
			} else {
				final dir = Path.Dir(name);
				final pst = OsNative.stat(dir, true);
				if (pst.err != null) {
					err = Errno.of(pst.err);
				} else if ((pst.mode & S_IFMT) != S_IFDIR) {
					err = Errno.of("ENOTDIR");
				} else {
					err = Errno.of("EACCES");
				}
			}
			return new ValueError<OsFile>(null, new PathError("open", name, err));
		}
		#end
	}

	// os.ReadDir: entries sorted by filename.
	public static function ReadDir(name:String):ValueError<Array<DirEntry>> {
		final st = OsNative.stat(name, true);
		if (st.err != null) {
			return new ValueError<Array<DirEntry>>(null, new PathError("open", name, Errno.of(st.err)));
		}
		if ((st.mode & S_IFMT) != S_IFDIR) {
			return new ValueError<Array<DirEntry>>(null, new PathError("readdirent", name, Errno.of("ENOTDIR")));
		}
		var names:Array<String>;
		try {
			names = sys.FileSystem.readDirectory(name);
		} catch (e:Dynamic) {
			return new ValueError<Array<DirEntry>>(null, new PathError("open", name, errnoFor(name, true)));
		}
		names.sort(Strings.Compare);
		final dirname = StringTools.endsWith(name, "/") ? name : name + "/";
		final entries:Array<DirEntry> = [];
		for (n in names) {
			final full = dirname + n;
			final lst = OsNative.stat(full, false);
			if (lst.err != null) {
				// File disappeared between readdir and lstat: Go skips it.
				continue;
			}
			entries.push(new OsDirEntry(full, n, modeFromSys(lst.mode).Type()));
		}
		return new ValueError<Array<DirEntry>>(entries, null);
	}

	// os.Mkdir
	public static function Mkdir(name:String, perm:FileMode):Null<Error> {
		final e = OsNative.mkdir(name, perm.Perm());
		if (e != null) {
			return new PathError("mkdir", name, Errno.of(e));
		}
		return null;
	}

	// os.MkdirAll
	public static function MkdirAll(path:String, perm:FileMode):Null<Error> {
		// Fast path: if we can tell whether path is a directory or file, stop with success or error.
		final dir = Stat(path);
		if (dir.err == null) {
			if (dir.value.IsDir()) {
				return null;
			}
			return new PathError("mkdir", path, Errno.of("ENOTDIR"));
		}

		// Slow path: make sure parent exists and then call Mkdir for path.
		var i = path.length;
		while (i > 0 && StringTools.fastCodeAt(path, i - 1) == '/'.code) { // Skip trailing path separator.
			i--;
		}
		var j = i;
		while (j > 0 && StringTools.fastCodeAt(path, j - 1) != '/'.code) { // Scan backward over element.
			j--;
		}
		if (j > 1) {
			// Create parent.
			final err = MkdirAll(path.substring(0, j - 1), perm);
			if (err != null) {
				return err;
			}
		}

		// Parent now exists; invoke Mkdir and use its result.
		final err = Mkdir(path, perm);
		if (err != null) {
			// Handle arguments like "foo/." by
			// double-checking that directory doesn't exist.
			final dir1 = Lstat(path);
			if (dir1.err == null && dir1.value.IsDir()) {
				return null;
			}
			return err;
		}
		return null;
	}

	// os.RemoveAll (does not follow symlinks; a missing path is not an error).
	public static function RemoveAll(path:String):Null<Error> {
		if (path == "" || path == "." || StringTools.endsWith(path, "/.")) {
			return new PathError("RemoveAll", path, Errno.of("EINVAL"));
		}
		final st = OsNative.stat(path, false);
		if (st.err != null) {
			if (st.err == "ENOENT") {
				return null;
			}
			return new PathError("lstat", path, Errno.of(st.err));
		}
		if ((st.mode & S_IFMT) != S_IFDIR) {
			final e = OsNative.unlink(path);
			if (e != null && e != "ENOENT") {
				return new PathError("unlinkat", path, Errno.of(e));
			}
			return null;
		}
		var names:Array<String> = [];
		try {
			names = sys.FileSystem.readDirectory(path);
		} catch (e:Dynamic) {}
		var firstErr:Null<Error> = null;
		for (n in names) {
			final err = RemoveAll(path + "/" + n);
			if (err != null && firstErr == null) {
				firstErr = err;
			}
		}
		final e = OsNative.rmdir(path);
		if (e != null && e != "ENOENT") {
			if (firstErr == null) {
				firstErr = new PathError("unlinkat", path, Errno.of(e));
			}
		}
		return firstErr;
	}

	// os.Remove
	public static function Remove(name:String):Null<Error> {
		var e = OsNative.unlink(name);
		if (e == null) {
			return null;
		}
		final e1 = OsNative.rmdir(name);
		if (e1 == null) {
			return null;
		}
		if (e1 != "ENOTDIR") {
			e = e1;
		}
		return new PathError("remove", name, Errno.of(e));
	}

	// os.Chtimes
	public static function Chtimes(name:String, atime:Time, mtime:Time):Null<Error> {
		final e = OsNative.utimes(name, atime.UnixFloat(), mtime.UnixFloat());
		if (e != null) {
			return new PathError("chtimes", name, Errno.of(e));
		}
		return null;
	}

	// os.Symlink
	public static function Symlink(oldname:String, newname:String):Null<Error> {
		final e = OsNative.symlink(oldname, newname);
		if (e != null) {
			return new LinkError("symlink", oldname, newname, Errno.of(e));
		}
		return null;
	}

	// os.DirFS
	public static function DirFS(dir:String):FS {
		return new OsDirFS(dir);
	}

	// os.Executable
	// PORT: Sys.programPath() — the JS script on Node, the executable on hxcpp.
	public static function Executable():ValueError<String> {
		try {
			final p = Sys.programPath();
			if (p == null) {
				return new ValueError<String>("", Errors.New("Executable not implemented"));
			}
			return new ValueError<String>(sys.FileSystem.absolutePath(p), null);
		} catch (e:Dynamic) {
			return new ValueError<String>("", Errors.New("Executable not implemented"));
		}
	}

	// os.Getwd
	public static function Getwd():ValueError<String> {
		var wd = Sys.getCwd();
		// Sys.getCwd() ends with a separator; Go's does not (except for "/").
		while (wd.length > 1 && (StringTools.endsWith(wd, "/") || StringTools.endsWith(wd, "\\"))) {
			wd = wd.substring(0, wd.length - 1);
		}
		return new ValueError<String>(wd, null);
	}

	// os.Getenv
	public static function Getenv(key:String):String {
		final v = Sys.getEnv(key);
		return v == null ? "" : v;
	}

	// os.UserHomeDir (Unix)
	public static function UserHomeDir():ValueError<String> {
		final v = Getenv("HOME");
		if (v == "") {
			return new ValueError<String>("", Errors.New("$HOME is not defined"));
		}
		return new ValueError<String>(v, null);
	}

	// os.UserCacheDir (Linux/other Unix and macOS)
	public static function UserCacheDir():ValueError<String> {
		if (Sys.systemName() == "Mac") {
			final dir = Getenv("HOME");
			if (dir == "") {
				return new ValueError<String>("", Errors.New("$HOME is not defined"));
			}
			return new ValueError<String>(dir + "/Library/Caches", null);
		}
		var dir = Getenv("XDG_CACHE_HOME");
		if (dir == "") {
			dir = Getenv("HOME");
			if (dir == "") {
				return new ValueError<String>("", Errors.New("neither $XDG_CACHE_HOME nor $HOME are defined"));
			}
			dir += "/.cache";
		} else if (!Path.IsAbs(dir)) {
			return new ValueError<String>("", Errors.New("path in $XDG_CACHE_HOME is relative"));
		}
		return new ValueError<String>(dir, null);
	}

	// os.TempDir (Unix)
	public static function TempDir():String {
		var dir = Getenv("TMPDIR");
		if (dir == "") {
			dir = "/tmp";
		}
		return dir;
	}

	// os.IsNotExist
	public static function IsNotExist(err:Null<Error>):Bool {
		return underlyingErrorIs(err, Fs.ErrNotExist);
	}

	// os.IsExist
	public static function IsExist(err:Null<Error>):Bool {
		return underlyingErrorIs(err, Fs.ErrExist);
	}

	static function underlyingErrorIs(err:Null<Error>, target:Error):Bool {
		if (Std.isOfType(err, PathError)) {
			err = (cast err : PathError).Err;
		} else if (Std.isOfType(err, LinkError)) {
			err = (cast err : LinkError).Err;
		}
		if (err == target) {
			return true;
		}
		return Std.isOfType(err, Errno) && (cast err : Errno).Is(target);
	}
}

// syscall.Errno: the error code name ("ENOENT") and Go's message.
class Errno implements Error {
	public final code:String;

	function new(code:String) {
		this.code = code;
	}

	public static function of(code:String):Errno {
		return new Errno(code);
	}

	public function Error():String {
		return switch (code) {
			case "ENOENT": "no such file or directory";
			case "EEXIST": "file exists";
			case "ENOTDIR": "not a directory";
			case "EISDIR": "is a directory";
			case "EACCES": "permission denied";
			case "EPERM": "operation not permitted";
			case "ENOTEMPTY": "directory not empty";
			case "ELOOP": "too many levels of symbolic links";
			case "EINVAL": "invalid argument";
			case "EIO": "input/output error";
			case "ENAMETOOLONG": "file name too long";
			case "EBUSY": "device or resource busy";
			case "EROFS": "read-only file system";
			case "EXDEV": "invalid cross-device link";
			default: "errno " + code;
		}
	}

	// syscall.Errno.Is
	public function Is(target:Error):Bool {
		if (target == Fs.ErrPermission) {
			return code == "EACCES" || code == "EPERM";
		}
		if (target == Fs.ErrExist) {
			return code == "EEXIST" || code == "ENOTEMPTY";
		}
		if (target == Fs.ErrNotExist) {
			return code == "ENOENT";
		}
		return false;
	}

	public function toString():String {
		return Error();
	}
}

// os.LinkError
class LinkError implements Error implements go.Errors.Wrapper {
	public var Op:String;
	public var Old:String;
	public var New:String;
	public var Err:Error;

	public function new(op:String, old:String, new_:String, err:Error) {
		this.Op = op;
		this.Old = old;
		this.New = new_;
		this.Err = err;
	}

	public function Error():String {
		return Op + " " + Old + " " + New + ": " + Err.Error();
	}

	public function Unwrap():Null<Error> {
		return Err;
	}
}

// *os.File, write side only.
class OsFile {
	final name:String;

	#if js
	var fd:Int;

	public function new(name:String, fd:Int) {
		this.name = name;
		this.fd = fd;
	}
	#else
	var out:sys.io.FileOutput;

	public function new(name:String, out:sys.io.FileOutput) {
		this.name = name;
		this.out = out;
	}
	#end

	public function Write(b:Bytes):ValueError<Int> {
		#if js
		try {
			js.Syntax.code("require('fs').writeSync({0}, {1})", fd, js.node.Buffer.hxFromBytes(b));
		} catch (e:Dynamic) {
			return new ValueError<Int>(0, new PathError("write", name, Errno.of(OsNative.jsCode(e))));
		}
		#else
		try {
			out.writeFullBytes(b, 0, b.length);
		} catch (e:Dynamic) {
			return new ValueError<Int>(0, new PathError("write", name, Errno.of("EIO")));
		}
		#end
		return new ValueError<Int>(b.length, null);
	}

	public function WriteString(s:String):ValueError<Int> {
		return Write(Utf8.StringToBytes(s));
	}

	public function Close():Null<Error> {
		#if js
		try {
			js.Syntax.code("require('fs').closeSync({0})", fd);
		} catch (e:Dynamic) {
			return new PathError("close", name, Errno.of(OsNative.jsCode(e)));
		}
		#else
		try {
			out.close();
		} catch (e:Dynamic) {
			return new PathError("close", name, Errno.of("EIO"));
		}
		#end
		return null;
	}
}

// os.fileStat
private class FileStat implements FileInfo {
	final name:String;
	final size:Int;
	final mode:FileMode;
	final modTime:Time;

	public function new(name:String, size:Int, mode:FileMode, modTime:Time) {
		this.name = name;
		this.size = size;
		this.mode = mode;
		this.modTime = modTime;
	}

	public function Name():String {
		return name;
	}

	public function Size():Int {
		return size;
	}

	public function Mode():FileMode {
		return mode;
	}

	public function ModTime():Time {
		return modTime;
	}

	public function IsDir():Bool {
		return mode.IsDir();
	}

	public function Sys():Any {
		return null;
	}
}

// os.unixDirent
private class OsDirEntry implements DirEntry {
	final parent:String;
	final name:String;
	final typ:FileMode;

	public function new(path:String, name:String, typ:FileMode) {
		this.parent = path;
		this.name = name;
		this.typ = typ;
	}

	public function Name():String {
		return name;
	}

	public function IsDir():Bool {
		return typ.IsDir();
	}

	public function Type():FileMode {
		return typ;
	}

	public function Info():ValueError<FileInfo> {
		return Os.Lstat(parent);
	}
}

// os.dirFS
private class OsDirFS implements StatFS implements ReadFileFS implements ReadDirFS {
	final dir:String;

	public function new(dir:String) {
		this.dir = dir;
	}

	function join(name:String):ValueError<String> {
		if (dir == "") {
			return new ValueError<String>("", Errors.New("os: DirFS with empty root"));
		}
		if (!Fs.ValidPath(name)) {
			return new ValueError<String>("", Fs.ErrInvalid);
		}
		if (StringTools.fastCodeAt(dir, dir.length - 1) == '/'.code) {
			return new ValueError<String>(dir + name, null);
		}
		return new ValueError<String>(dir + "/" + name, null);
	}

	static function fixPath(err:Null<Error>, name:String):Null<Error> {
		if (Std.isOfType(err, PathError)) {
			(cast err : PathError).Path = name;
		}
		return err;
	}

	public function Open(name:String):ValueError<File> {
		final full = join(name);
		if (full.err != null) {
			return new ValueError<File>(null, new PathError("open", name, full.err));
		}
		final st = Os.Stat(full.value);
		if (st.err != null) {
			return new ValueError<File>(null, fixPath(st.err, name));
		}
		if (st.value.IsDir()) {
			return new ValueError<File>(new OsDirFile(full.value, st.value), null);
		}
		final data = Os.ReadFile(full.value);
		if (data.err != null) {
			return new ValueError<File>(null, fixPath(data.err, name));
		}
		return new ValueError<File>(new OsReadFile(full.value, st.value, data.value), null);
	}

	public function ReadFile(name:String):ValueError<Bytes> {
		final full = join(name);
		if (full.err != null) {
			return new ValueError<Bytes>(null, new PathError("readfile", name, full.err));
		}
		final b = Os.ReadFile(full.value);
		return new ValueError<Bytes>(b.value, fixPath(b.err, name));
	}

	public function ReadDir(name:String):ValueError<Array<DirEntry>> {
		final full = join(name);
		if (full.err != null) {
			return new ValueError<Array<DirEntry>>(null, new PathError("readdir", name, full.err));
		}
		final entries = Os.ReadDir(full.value);
		return new ValueError<Array<DirEntry>>(entries.value, fixPath(entries.err, name));
	}

	public function Stat(name:String):ValueError<FileInfo> {
		final full = join(name);
		if (full.err != null) {
			return new ValueError<FileInfo>(null, new PathError("stat", name, full.err));
		}
		final f = Os.Stat(full.value);
		if (f.err != null) {
			return new ValueError<FileInfo>(null, fixPath(f.err, name));
		}
		return f;
	}
}

// A regular file opened through os.DirFS (contents read at Open).
private class OsReadFile implements File {
	final path:String;
	final info:FileInfo;
	final data:Bytes;
	var offset = 0;

	public function new(path:String, info:FileInfo, data:Bytes) {
		this.path = path;
		this.info = info;
		this.data = data;
	}

	public function Stat():ValueError<FileInfo> {
		return new ValueError<FileInfo>(info, null);
	}

	public function Read(b:Bytes, pos:Int, len:Int):ValueError<Int> {
		if (offset >= data.length) {
			return new ValueError<Int>(0, Io.EOF);
		}
		var n = data.length - offset;
		if (n > len)
			n = len;
		b.blit(pos, data, offset, n);
		offset += n;
		return new ValueError<Int>(n, null);
	}

	public function Close():Null<Error> {
		return null;
	}
}

// A directory opened through os.DirFS.
private class OsDirFile implements ReadDirFile {
	final path:String;
	final info:FileInfo;
	var entries:Null<Array<DirEntry>> = null;
	var offset = 0;

	public function new(path:String, info:FileInfo) {
		this.path = path;
		this.info = info;
	}

	public function Stat():ValueError<FileInfo> {
		return new ValueError<FileInfo>(info, null);
	}

	public function Read(b:Bytes, pos:Int, len:Int):ValueError<Int> {
		return new ValueError<Int>(0, new PathError("read", path, Errno.of("EISDIR")));
	}

	public function ReadDir(n:Int):ValueError<Array<DirEntry>> {
		if (entries == null) {
			final r = Os.ReadDir(path);
			if (r.err != null) {
				return new ValueError<Array<DirEntry>>(null, r.err);
			}
			entries = r.value;
		}
		var count = entries.length - offset;
		if (count == 0 && n > 0) {
			return new ValueError<Array<DirEntry>>(null, Io.EOF);
		}
		if (n > 0 && count > n) {
			count = n;
		}
		final list = entries.slice(offset, offset + count);
		offset += count;
		return new ValueError<Array<DirEntry>>(list, null);
	}

	public function Close():Null<Error> {
		return null;
	}
}

// Result of a native stat/lstat call.
class NativeStat {
	public var err:Null<String> = null; // error code name, null on success
	public var mode:Int = 0; // st_mode
	public var size:Int = 0;
	public var mtimeSec:Float = 0.0;
	public var mtimeNsec:Int = 0;

	public function new() {}
}

// Per-target native calls. Every function returns the error code name ("ENOENT"), or null.
#if cpp
@:cppFileCode('
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>

static ::String go_os_errname(int e) {
	switch (e) {
		case ENOENT: return HX_CSTRING("ENOENT");
		case EEXIST: return HX_CSTRING("EEXIST");
		case ENOTDIR: return HX_CSTRING("ENOTDIR");
		case EISDIR: return HX_CSTRING("EISDIR");
		case EACCES: return HX_CSTRING("EACCES");
		case EPERM: return HX_CSTRING("EPERM");
		case ENOTEMPTY: return HX_CSTRING("ENOTEMPTY");
		case ELOOP: return HX_CSTRING("ELOOP");
		case EINVAL: return HX_CSTRING("EINVAL");
		case EIO: return HX_CSTRING("EIO");
		case ENAMETOOLONG: return HX_CSTRING("ENAMETOOLONG");
		case EBUSY: return HX_CSTRING("EBUSY");
		case EROFS: return HX_CSTRING("EROFS");
		case EXDEV: return HX_CSTRING("EXDEV");
	}
	return ::String(e);
}

static ::Array<Float> go_os_stat(::String path, bool follow) {
	struct stat st;
	int r = follow ? ::stat(path.utf8_str(), &st) : ::lstat(path.utf8_str(), &st);
	::Array<Float> a = ::Array_obj<Float>::__new(0, 5);
	if (r != 0) {
		a->push((Float)errno);
		return a;
	}
	a->push(0);
	a->push((Float)st.st_mode);
	a->push((Float)st.st_size);
#ifdef __APPLE__
	a->push((Float)st.st_mtimespec.tv_sec);
	a->push((Float)st.st_mtimespec.tv_nsec);
#else
	a->push((Float)st.st_mtim.tv_sec);
	a->push((Float)st.st_mtim.tv_nsec);
#endif
	return a;
}

static int go_os_realpath_errno = 0;

static ::String go_os_realpath(::String path) {
	char *r = ::realpath(path.utf8_str(), NULL);
	if (r == NULL) {
		go_os_realpath_errno = errno;
		return ::String();
	}
	::String s = ::String::create(r);
	free(r);
	go_os_realpath_errno = 0;
	return s;
}

static int go_os_utimes(::String path, double atime, double mtime) {
	struct timeval tv[2];
	tv[0].tv_sec = (time_t)atime;
	tv[0].tv_usec = (suseconds_t)((atime - (double)tv[0].tv_sec) * 1e6);
	tv[1].tv_sec = (time_t)mtime;
	tv[1].tv_usec = (suseconds_t)((mtime - (double)tv[1].tv_sec) * 1e6);
	return ::utimes(path.utf8_str(), tv) == 0 ? 0 : errno;
}
')
#elseif cs
// PORT: cs — the same POSIX calls as on cpp, through P/Invoke into libc (.NET has no lstat/st_mode
// API). stat/lstat use statx(2): its struct layout is the same on every Linux architecture
// (PORT: cs supports Linux only). errno becomes the error code name through its strerror text.
@:classCode('
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "statx", SetLastError = true)]
	static extern unsafe int go_statx(int dirfd, string path, int flags, uint mask, byte* buf);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "mkdir", SetLastError = true)]
	static extern int go_mkdir(string path, uint mode);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "unlink", SetLastError = true)]
	static extern int go_unlink(string path);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "rmdir", SetLastError = true)]
	static extern int go_rmdir(string path);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "symlink", SetLastError = true)]
	static extern int go_symlink(string target, string path);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "realpath", SetLastError = true)]
	static extern System.IntPtr go_realpath(string path, System.IntPtr resolved);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "free")]
	static extern void go_free(System.IntPtr p);
	[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "utimes", SetLastError = true)]
	static extern unsafe int go_utimes(string path, long* tv);

	static int go_errno() {
		return System.Runtime.InteropServices.Marshal.GetLastPInvokeError();
	}

	// [errno] or [0, st_mode, st_size, mtime sec, mtime nsec]
	static unsafe double[] go_os_stat(string path, bool follow) {
		byte* buf = stackalloc byte[256];
		// AT_FDCWD, AT_SYMLINK_NOFOLLOW, STATX_BASIC_STATS
		if (go_statx(-100, path, follow ? 0 : 0x100, 0x7ff, buf) != 0)
			return new double[] { go_errno() };
		return new double[] { 0, *(ushort*)(buf + 28), (double)*(ulong*)(buf + 40), *(long*)(buf + 112), *(uint*)(buf + 120) };
	}

	static int go_os_realpath_errno = 0;

	static string go_os_realpath(string path) {
		System.IntPtr r = go_realpath(path, System.IntPtr.Zero);
		if (r == System.IntPtr.Zero) {
			go_os_realpath_errno = go_errno();
			return null;
		}
		string s = System.Runtime.InteropServices.Marshal.PtrToStringUTF8(r);
		go_free(r);
		return s;
	}

	static unsafe int go_os_utimes(string path, double atime, double mtime) {
		long* tv = stackalloc long[4];
		tv[0] = (long)atime;
		tv[1] = (long)((atime - (double)tv[0]) * 1e6);
		tv[2] = (long)mtime;
		tv[3] = (long)((mtime - (double)tv[2]) * 1e6);
		return go_utimes(path, tv) == 0 ? 0 : go_errno();
	}
')
#end
class OsNative {
	#if js
	public static function jsCode(e:Dynamic):String {
		final code:Null<String> = e == null ? null : e.code;
		return code == null ? "EIO" : code;
	}
	#end

	public static function stat(path:String, follow:Bool):NativeStat {
		final r = new NativeStat();
		#if js
		try {
			final s:Dynamic = follow ? js.Syntax.code("require('fs').statSync({0})", path) : js.Syntax.code("require('fs').lstatSync({0})", path);
			r.mode = s.mode;
			r.size = Std.int(s.size);
			final ms:Float = s.mtimeMs;
			final sec = std.Math.ffloor(ms / 1000);
			r.mtimeSec = sec;
			r.mtimeNsec = Std.int(std.Math.ffloor((ms - sec * 1000) * 1000000));
		} catch (e:Dynamic) {
			r.err = jsCode(e);
		}
		#elseif cpp
		final a:Array<Float> = untyped __cpp__("go_os_stat({0}, {1})", path, follow);
		if (a[0] != 0) {
			r.err = errname(Std.int(a[0]));
		} else {
			r.mode = Std.int(a[1]);
			r.size = Std.int(a[2]);
			r.mtimeSec = a[3];
			r.mtimeNsec = Std.int(a[4]);
		}
		#elseif cs
		final a:cs.NativeArray<Float> = cs.Syntax.code("go_os_stat({0}, {1})", path, follow);
		if (a[0] != 0) {
			r.err = errname(Std.int(a[0]));
		} else {
			r.mode = Std.int(a[1]);
			r.size = Std.int(a[2]);
			r.mtimeSec = a[3];
			r.mtimeNsec = Std.int(a[4]);
		}
		#elseif jvm
		try {
			final m = if (follow) java.nio.file.Files.readAttributes(jpath(path),
				"unix:mode,size,lastModifiedTime") else java.nio.file.Files.readAttributes(jpath(path), "unix:mode,size,lastModifiedTime",
					java.nio.file.LinkOption.NOFOLLOW_LINKS);
			r.mode = (cast m.get("mode") : Int);
			r.size = haxe.Int64.toInt((cast m.get("size") : haxe.Int64));
			final t:java.nio.file.attribute.FileTime = cast m.get("lastModifiedTime");
			final i = t.toInstant();
			r.mtimeSec = haxe.Int64.toInt(i.getEpochSecond());
			r.mtimeNsec = i.getNano();
		} catch (e:Dynamic) {
			r.err = jvmCode(e);
		}
		#elseif python
		try {
			final st:Dynamic = python.Syntax.code("__import__('os').stat({0}, follow_symlinks={1})", pyPath(path), follow);
			r.mode = st.st_mode;
			r.size = st.st_size;
			r.mtimeSec = python.Syntax.code("{0}.st_mtime_ns // 1000000000", st);
			r.mtimeNsec = python.Syntax.code("{0}.st_mtime_ns % 1000000000", st);
		} catch (e:Dynamic) {
			r.err = pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final a = OsHxmc.stat(path, follow);
		if (a[0] != 0) {
			r.err = OsHxmc.errname(Std.int(a[0]));
		} else {
			r.mode = Std.int(a[1]);
			r.size = Std.int(a[2]);
			r.mtimeSec = a[3];
			r.mtimeNsec = Std.int(a[4]);
		}
		#else
		throw "go.Os: unsupported target";
		#end
		return r;
	}

	#if jvm
	// PORT: jvm — java.nio.file; the exception becomes the POSIX error code name.
	static function jpath(path:String):java.nio.file.Path {
		return java.nio.file.Paths.get(path);
	}

	public static function jvmCode(e:Dynamic):String {
		if (Std.isOfType(e, java.nio.file.NoSuchFileException))
			return "ENOENT";
		if (Std.isOfType(e, java.nio.file.FileAlreadyExistsException))
			return "EEXIST";
		if (Std.isOfType(e, java.nio.file.DirectoryNotEmptyException))
			return "ENOTEMPTY";
		if (Std.isOfType(e, java.nio.file.NotDirectoryException))
			return "ENOTDIR";
		if (Std.isOfType(e, java.nio.file.AccessDeniedException))
			return "EACCES";
		if (Std.isOfType(e, java.nio.file.FileSystemLoopException))
			return "ELOOP";
		if (Std.isOfType(e, java.nio.file.FileSystemException)) {
			final reason:Null<String> = (cast e : java.nio.file.FileSystemException).getReason();
			switch reason {
				case "Not a directory": return "ENOTDIR";
				case "Is a directory": return "EISDIR";
				case "Too many levels of symbolic links": return "ELOOP";
				case "File name too long": return "ENAMETOOLONG";
				case "Permission denied": return "EACCES";
				case "Operation not permitted": return "EPERM";
				case "Read-only file system": return "EROFS";
				case "Invalid argument": return "EINVAL";
				case _:
			}
		}
		return "EIO";
	}

	static function isDir(path:String):Bool {
		return java.nio.file.Files.isDirectory(jpath(path), java.nio.file.LinkOption.NOFOLLOW_LINKS);
	}
	#end

	#if python
	// PORT: python — os module; OSError.errno becomes the POSIX error code name. Paths go to the OS
	// as native str (python.U16: strings are in UTF-16 form inside the port).
	static inline function pyPath(path:String):String {
		return python.U16.fromU16(path);
	}

	public static function pyCode(e:Dynamic):String {
		final code:Null<String> = python.Syntax.code("__import__('errno').errorcode.get(getattr({0}, 'errno', None) or -1)", e);
		return code == null ? "EIO" : code;
	}
	#end

	#if cpp
	static function errname(e:Int):String {
		return untyped __cpp__("go_os_errname({0})", e);
	}
	#end

	#if cs
	// PORT: cs — errno → code name through the C library's message (the numbers differ per OS).
	static function errname(e:Int):String {
		final msg:String = cs.Syntax.code("System.Runtime.InteropServices.Marshal.GetPInvokeErrorMessage({0})", e);
		return switch msg {
			case "No such file or directory": "ENOENT";
			case "File exists": "EEXIST";
			case "Not a directory": "ENOTDIR";
			case "Is a directory": "EISDIR";
			case "Permission denied": "EACCES";
			case "Operation not permitted": "EPERM";
			case "Directory not empty": "ENOTEMPTY";
			case "Too many levels of symbolic links": "ELOOP";
			case "Invalid argument": "EINVAL";
			case "Input/output error": "EIO";
			case "File name too long": "ENAMETOOLONG";
			case "Device or resource busy": "EBUSY";
			case "Read-only file system": "EROFS";
			case "Invalid cross-device link": "EXDEV";
			case _: Std.string(e);
		}
	}
	#end

	public static function mkdir(path:String, perm:Int):Null<String> {
		#if js
		try {
			js.Syntax.code("require('fs').mkdirSync({0}, {1})", path, perm);
			return null;
		} catch (e:Dynamic) {
			return jsCode(e);
		}
		#elseif cpp
		final e:Int = untyped __cpp__("(::mkdir({0}.utf8_str(), (mode_t){1}) == 0 ? 0 : errno)", path, perm);
		return e == 0 ? null : errname(e);
		#elseif cs
		final e:Int = cs.Syntax.code("(go_mkdir({0}, (uint){1}) == 0 ? 0 : go_errno())", path, perm);
		return e == 0 ? null : errname(e);
		#elseif jvm
		try {
			final b = new StringBuf();
			for (i in 0...9)
				b.add((perm & (1 << (8 - i))) != 0 ? "rwx".charAt(i % 3) : "-");
			java.nio.file.Files.createDirectory(jpath(path),
				java.nio.file.attribute.PosixFilePermissions.asFileAttribute(java.nio.file.attribute.PosixFilePermissions.fromString(b.toString())));
			return null;
		} catch (e:Dynamic) {
			return jvmCode(e);
		}
		#elseif python
		try {
			python.Syntax.code("__import__('os').mkdir({0}, {1})", pyPath(path), perm);
			return null;
		} catch (e:Dynamic) {
			return pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final e = OsHxmc.mkdir(path, perm);
		return e == 0 ? null : OsHxmc.errname(e);
		#else
		throw "go.Os: unsupported target";
		#end
	}

	public static function unlink(path:String):Null<String> {
		#if js
		try {
			js.Syntax.code("require('fs').unlinkSync({0})", path);
			return null;
		} catch (e:Dynamic) {
			return jsCode(e);
		}
		#elseif cpp
		final e:Int = untyped __cpp__("(::unlink({0}.utf8_str()) == 0 ? 0 : errno)", path);
		return e == 0 ? null : errname(e);
		#elseif cs
		final e:Int = cs.Syntax.code("(go_unlink({0}) == 0 ? 0 : go_errno())", path);
		return e == 0 ? null : errname(e);
		#elseif jvm
		try {
			if (isDir(path))
				return "EISDIR"; // Files.delete would remove an empty directory
			java.nio.file.Files.delete(jpath(path));
			return null;
		} catch (e:Dynamic) {
			return jvmCode(e);
		}
		#elseif python
		try {
			python.Syntax.code("__import__('os').unlink({0})", pyPath(path));
			return null;
		} catch (e:Dynamic) {
			return pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final e = OsHxmc.unlink(path);
		return e == 0 ? null : OsHxmc.errname(e);
		#else
		throw "go.Os: unsupported target";
		#end
	}

	public static function rmdir(path:String):Null<String> {
		#if js
		try {
			js.Syntax.code("require('fs').rmdirSync({0})", path);
			return null;
		} catch (e:Dynamic) {
			return jsCode(e);
		}
		#elseif cpp
		final e:Int = untyped __cpp__("(::rmdir({0}.utf8_str()) == 0 ? 0 : errno)", path);
		return e == 0 ? null : errname(e);
		#elseif cs
		final e:Int = cs.Syntax.code("(go_rmdir({0}) == 0 ? 0 : go_errno())", path);
		return e == 0 ? null : errname(e);
		#elseif jvm
		try {
			if (!isDir(path)) {
				final st = stat(path, false);
				return st.err != null ? st.err : "ENOTDIR";
			}
			java.nio.file.Files.delete(jpath(path));
			return null;
		} catch (e:Dynamic) {
			return jvmCode(e);
		}
		#elseif python
		try {
			python.Syntax.code("__import__('os').rmdir({0})", pyPath(path));
			return null;
		} catch (e:Dynamic) {
			return pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final e = OsHxmc.rmdir(path);
		return e == 0 ? null : OsHxmc.errname(e);
		#else
		throw "go.Os: unsupported target";
		#end
	}

	public static function symlink(target:String, path:String):Null<String> {
		#if js
		try {
			js.Syntax.code("require('fs').symlinkSync({0}, {1})", target, path);
			return null;
		} catch (e:Dynamic) {
			return jsCode(e);
		}
		#elseif cpp
		final e:Int = untyped __cpp__("(::symlink({0}.utf8_str(), {1}.utf8_str()) == 0 ? 0 : errno)", target, path);
		return e == 0 ? null : errname(e);
		#elseif cs
		final e:Int = cs.Syntax.code("(go_symlink({0}, {1}) == 0 ? 0 : go_errno())", target, path);
		return e == 0 ? null : errname(e);
		#elseif jvm
		try {
			java.nio.file.Files.createSymbolicLink(jpath(path), jpath(target));
			return null;
		} catch (e:Dynamic) {
			return jvmCode(e);
		}
		#elseif python
		try {
			python.Syntax.code("__import__('os').symlink({0}, {1})", pyPath(target), pyPath(path));
			return null;
		} catch (e:Dynamic) {
			return pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final e = OsHxmc.symlink(target, path);
		return e == 0 ? null : OsHxmc.errname(e);
		#else
		throw "go.Os: unsupported target";
		#end
	}

	public static function utimes(path:String, atime:Float, mtime:Float):Null<String> {
		#if js
		try {
			js.Syntax.code("require('fs').utimesSync({0}, {1}, {2})", path, atime, mtime);
			return null;
		} catch (e:Dynamic) {
			return jsCode(e);
		}
		#elseif cpp
		final e:Int = untyped __cpp__("go_os_utimes({0}, {1}, {2})", path, atime, mtime);
		return e == 0 ? null : errname(e);
		#elseif cs
		final e:Int = cs.Syntax.code("go_os_utimes({0}, {1}, {2})", path, atime, mtime);
		return e == 0 ? null : errname(e);
		#elseif jvm
		try {
			final view:java.nio.file.attribute.BasicFileAttributeView = cast java.nio.file.Files.getFileAttributeView(jpath(path),
				java.lang.Class.forName("java.nio.file.attribute.BasicFileAttributeView"));
			final us = (t:Float) -> java.nio.file.attribute.FileTime.from(haxe.Int64.fromFloat(std.Math.ffloor(t * 1e6)),
				java.util.concurrent.TimeUnit.MICROSECONDS);
			view.setTimes(us(mtime), us(atime), null);
			return null;
		} catch (e:Dynamic) {
			return jvmCode(e);
		}
		#elseif python
		try {
			// Microsecond precision like the cpp branch (utimes(2)).
			python.Syntax.code("__import__('os').utime({0}, ns=(int({1} * 1e6) * 1000, int({2} * 1e6) * 1000))", pyPath(path), atime, mtime);
			return null;
		} catch (e:Dynamic) {
			return pyCode(e);
		}
		#elseif (target.name == "hxmc")
		final e = OsHxmc.utimes(path, atime, mtime);
		return e == 0 ? null : OsHxmc.errname(e);
		#else
		throw "go.Os: unsupported target";
		#end
	}

	// realpath(3): the result path, or null with the error code in `realpathErr`.
	#if tshx_parallel
	// PORT: hxmc (-D tshx-parallel) — per thread (go.Par.slot)
	static final realpathErrs:Array<String> = [for (_ in 0...go.Par.SLOTS) ""];
	public static var realpathErr(get, set):String;

	static inline function get_realpathErr()
		return realpathErrs[go.Par.slot];

	static inline function set_realpathErr(v:String)
		return realpathErrs[go.Par.slot] = v;
	#else
	public static var realpathErr:String = "";
	#end

	public static function realpath(path:String):Null<String> {
		#if js
		try {
			return js.Syntax.code("require('fs').realpathSync.native({0})", path);
		} catch (e:Dynamic) {
			realpathErr = jsCode(e);
			return null;
		}
		#elseif cpp
		final s:String = untyped __cpp__("go_os_realpath({0})", path);
		if (s == null) {
			realpathErr = errname(untyped __cpp__("go_os_realpath_errno"));
			return null;
		}
		return s;
		#elseif cs
		final s:String = cs.Syntax.code("go_os_realpath({0})", path);
		if (s == null) {
			realpathErr = errname(cs.Syntax.code("go_os_realpath_errno"));
			return null;
		}
		return s;
		#elseif jvm
		try {
			return jpath(path).toRealPath().toString();
		} catch (e:Dynamic) {
			realpathErr = jvmCode(e);
			return null;
		}
		#elseif python
		try {
			return python.U16.toU16(python.Syntax.code("__import__('os').path.realpath({0}, strict=True)", pyPath(path)));
		} catch (e:Dynamic) {
			realpathErr = pyCode(e);
			return null;
		}
		#elseif (target.name == "hxmc")
		final s = OsHxmc.realpath(path);
		if (s == null) {
			realpathErr = OsHxmc.errname(OsHxmc.realpathErrno);
			return null;
		}
		return s;
		#else
		throw "go.Os: unsupported target";
		#end
	}
}
