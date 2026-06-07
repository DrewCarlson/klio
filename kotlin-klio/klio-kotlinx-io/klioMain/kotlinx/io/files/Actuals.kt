// klio platform actuals for kotlinx-io's `files` package.
//
// The upstream commonMain (files/Paths.kt, files/FileSystem.kt) declares
// the `expect` surface and the platform-independent path helpers. The
// actuals here back the filesystem with the host's `std::fs` via the
// `__kxio_*` host bindings declared in `src/lib.rs`. Path math and the
// exception policy live in Kotlin so thrown exceptions are ordinary,
// catchable `kotlinx.io` types; the host bindings are thin I/O
// primitives.

package kotlinx.io.files

import kotlinx.io.Buffer
import kotlinx.io.IOException
import kotlinx.io.RawSink
import kotlinx.io.RawSource

// A path is a wrapper around its string form. The constructor is
// `private` so the only same-named (String)-callable is the
// `Path(path: String)` factory below — a 2-arg constructor would
// otherwise be chosen by arity over the common `Path(base: String,
// vararg parts: String)` builder for a `Path(base, *parts)` call,
// dropping the parts. The companion builds normalized instances.
public actual class Path private constructor(internal val pathString: String) {
    public actual val name: String
        get() {
            if (pathString.isEmpty()) return ""
            val idx = pathString.lastIndexOf(SystemPathSeparator)
            return if (idx < 0) pathString else pathString.substring(idx + 1)
        }

    public actual val parent: Path?
        get() {
            val idx = pathString.lastIndexOf(SystemPathSeparator)
            if (idx < 0) return null
            if (idx == 0) return if (pathString.length > 1) Path.of("$SystemPathSeparator") else null
            val head = removeTrailingSeparators(pathString.substring(0, idx))
            return if (head.isEmpty()) null else Path.of(head)
        }

    public actual val isAbsolute: Boolean
        get() = pathString.startsWith(SystemPathSeparator)

    public actual override fun toString(): String = pathString

    public actual override fun equals(other: Any?): Boolean =
        other is Path && other.pathString == pathString

    public actual override fun hashCode(): Int = pathString.hashCode()

    internal companion object {
        // Builds a Path from an already-normalized path string.
        internal fun of(normalized: String): Path = Path(normalized)
    }
}

public actual val SystemPathSeparator: Char = '/'

public actual fun Path(path: String): Path = Path.of(removeTrailingSeparators(path))

public actual class FileNotFoundException actual constructor(message: String?) :
    IOException(message)

// ---- host-backed filesystem primitives (shadowed by src/lib.rs) ----

internal fun __kxio_readAllBytes(path: String): ByteArray =
    throw NotImplementedError("__kxio_readAllBytes: host binding not installed")

internal fun __kxio_writeBytes(path: String, data: ByteArray, append: Boolean): Unit =
    throw NotImplementedError("__kxio_writeBytes: host binding not installed")

internal fun __kxio_exists(path: String): Boolean =
    throw NotImplementedError("__kxio_exists: host binding not installed")

internal fun __kxio_delete(path: String): Boolean =
    throw NotImplementedError("__kxio_delete: host binding not installed")

internal fun __kxio_createDirectories(path: String): Int =
    throw NotImplementedError("__kxio_createDirectories: host binding not installed")

internal fun __kxio_atomicMove(source: String, destination: String): Boolean =
    throw NotImplementedError("__kxio_atomicMove: host binding not installed")

internal fun __kxio_metadata(path: String): LongArray =
    throw NotImplementedError("__kxio_metadata: host binding not installed")

internal fun __kxio_resolve(path: String): String =
    throw NotImplementedError("__kxio_resolve: host binding not installed")

internal fun __kxio_list(path: String): List<String> =
    throw NotImplementedError("__kxio_list: host binding not installed")

internal fun __kxio_tempDir(): String =
    throw NotImplementedError("__kxio_tempDir: host binding not installed")

// ---- RawSource / RawSink adapters ----

// Yields the contents of an in-memory ByteArray (the whole file read
// up front). `RealSource` drives it via repeated readAtMostTo until -1.
internal class ByteArrayBackedSource(private val data: ByteArray) : RawSource {
    private var pos = 0
    private var closed = false

    override fun readAtMostTo(sink: Buffer, byteCount: Long): Long {
        check(!closed) { "source is closed" }
        if (pos >= data.size) return -1L
        if (byteCount <= 0L) return 0L
        val toCopy = minOf(byteCount, (data.size - pos).toLong()).toInt()
        sink.write(data, pos, pos + toCopy)
        pos += toCopy
        return toCopy.toLong()
    }

    override fun close() {
        closed = true
    }
}

// Accumulates written bytes and appends them to the file on each flush.
// The file is created/truncated when the sink is opened (see
// `SystemFileSystem.sink`), so every flush here appends the new bytes.
internal class FileSink(private val path: String) : RawSink {
    private val acc = Buffer()
    private var closed = false

    override fun write(source: Buffer, byteCount: Long) {
        check(!closed) { "sink is closed" }
        acc.write(source, byteCount)
    }

    override fun flush() {
        if (acc.size == 0L) return
        __kxio_writeBytes(path, acc.readByteArray(), true)
    }

    override fun close() {
        if (closed) return
        flush()
        closed = true
    }
}

// ---- SystemFileSystem ----

public actual val SystemFileSystem: FileSystem = object : SystemFileSystemImpl() {
    override fun exists(path: Path): Boolean = __kxio_exists(path.toString())

    override fun delete(path: Path, mustExist: Boolean) {
        if (!__kxio_exists(path.toString())) {
            if (mustExist) throw FileNotFoundException("File does not exist: $path")
            return
        }
        if (!__kxio_delete(path.toString())) {
            throw IOException("Failed to delete $path")
        }
    }

    override fun createDirectories(path: Path, mustCreate: Boolean) {
        when (__kxio_createDirectories(path.toString())) {
            2 -> throw IOException("Path already exists and it's a file: $path")
            1 -> if (mustCreate) throw IOException("Path already exists: $path")
            3 -> throw IOException("Failed to create directories: $path")
        }
    }

    override fun atomicMove(source: Path, destination: Path) {
        if (!__kxio_exists(source.toString())) {
            throw FileNotFoundException("Source does not exist: $source")
        }
        if (!__kxio_atomicMove(source.toString(), destination.toString())) {
            throw IOException("Move failed: $source -> $destination")
        }
    }

    override fun source(path: Path): RawSource {
        if (!__kxio_exists(path.toString())) {
            throw FileNotFoundException("File does not exist: $path")
        }
        return ByteArrayBackedSource(__kxio_readAllBytes(path.toString()))
    }

    override fun sink(path: Path, append: Boolean): RawSink {
        if (!append) {
            // Create/truncate up front, matching FileOutputStream(path, false).
            __kxio_writeBytes(path.toString(), byteArrayOf(), false)
        }
        return FileSink(path.toString())
    }

    override fun metadataOrNull(path: Path): FileMetadata? {
        val m = __kxio_metadata(path.toString())
        val kind = m[0]
        if (kind == 0L) return null
        return FileMetadata(
            isRegularFile = kind == 1L,
            isDirectory = kind == 2L,
            size = if (kind == 1L) m[1] else -1L,
        )
    }

    override fun resolve(path: Path): Path {
        if (!__kxio_exists(path.toString())) {
            throw FileNotFoundException("File does not exist: $path")
        }
        return Path(__kxio_resolve(path.toString()))
    }

    override fun list(directory: Path): Collection<Path> {
        val m = __kxio_metadata(directory.toString())
        if (m[0] == 0L) throw FileNotFoundException("Directory does not exist: $directory")
        if (m[0] != 2L) throw IOException("Not a directory: $directory")
        val base = directory.toString()
        return __kxio_list(base).map { Path(base, it) }
    }
}

// A getter (not an eager initializer) so module load does not perform a
// host filesystem call — the temp dir is resolved on first access.
public actual val SystemTemporaryDirectory: Path
    get() = Path(__kxio_tempDir())
