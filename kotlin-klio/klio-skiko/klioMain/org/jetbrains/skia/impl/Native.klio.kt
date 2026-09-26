// skiko's native peers and interop on klio: a pointer is a Long, and an array
// or string passes to the C glue through native memory an InteropScope
// allocates and frees.
package org.jetbrains.skia.impl

actual typealias NativePointer = Long

actual typealias InteropPointer = Long

actual abstract class Native actual constructor(ptr: NativePointer) {
    internal actual var _ptr: NativePointer = ptr

    init {
        if (ptr == NullPointer) throw RuntimeException("Can't wrap nullptr")
    }

    internal actual open fun nativeEquals(other: Native?): Boolean = false

    actual override fun toString(): String =
        (this::class.simpleName ?: "Native") + "(_ptr=0x" + _ptr.toString(16) + ")"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Native) return false
        return _ptr == other._ptr || nativeEquals(other)
    }

    override fun hashCode(): Int = _ptr.hashCode()

    actual companion object {
        actual val NullPointer: NativePointer = 0L
    }
}

/** The collector keeps an object alive while it is referenced; nothing to do. */
internal actual fun reachabilityBarrier(obj: Any?) {}

@OptIn(org.jetbrains.skiko.InternalSkikoApi::class)
actual class InteropScope actual constructor() {
    private val allocations = ArrayList<Long>()

    private fun alloc(bytes: Int): InteropPointer {
        val ptr = __skiko_malloc(bytes.toLong())
        if (ptr == 0L) throw OutOfMemoryError("no native memory for $bytes bytes")
        allocations.add(ptr)
        return ptr
    }

    private fun copyIn(array: Any, bytes: Int): InteropPointer {
        val ptr = alloc(bytes)
        __skiko_copyIn(ptr, array)
        return ptr
    }

    actual fun toInterop(string: String?): InteropPointer {
        if (string == null) return 0L
        val ptr = __skiko_cstring(string)
        if (ptr == 0L) throw OutOfMemoryError("no native memory for a string")
        allocations.add(ptr)
        return ptr
    }

    actual fun toInterop(array: ByteArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size)
    actual fun toInteropForResult(array: ByteArray?): InteropPointer = if (array == null) 0L else alloc(array.size)
    actual fun InteropPointer.fromInterop(result: ByteArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: ShortArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size * 2)
    actual fun toInteropForResult(array: ShortArray?): InteropPointer = if (array == null) 0L else alloc(array.size * 2)
    actual fun InteropPointer.fromInterop(result: ShortArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: IntArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size * 4)
    actual fun toInteropForResult(array: IntArray?): InteropPointer = if (array == null) 0L else alloc(array.size * 4)
    actual fun InteropPointer.fromInterop(result: IntArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: LongArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size * 8)
    actual fun InteropPointer.fromInterop(result: LongArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: FloatArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size * 4)
    actual fun toInteropForResult(array: FloatArray?): InteropPointer = if (array == null) 0L else alloc(array.size * 4)
    actual fun InteropPointer.fromInterop(result: FloatArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: DoubleArray?): InteropPointer = if (array == null) 0L else copyIn(array, array.size * 8)
    actual fun toInteropForResult(array: DoubleArray?): InteropPointer = if (array == null) 0L else alloc(array.size * 8)
    actual fun InteropPointer.fromInterop(result: DoubleArray) = __skiko_copyOut(this, result)

    actual fun toInterop(array: NativePointerArray?): InteropPointer = toInterop(array?.backing)
    actual fun toInteropForResult(array: NativePointerArray?): InteropPointer =
        if (array == null) 0L else alloc(array.size * 8)
    actual fun InteropPointer.fromInterop(result: NativePointerArray) = __skiko_copyOut(this, result.backing)

    actual fun toInterop(stringArray: Array<String>?): InteropPointer {
        if (stringArray == null) return 0L
        return toInterop(LongArray(stringArray.size) { toInterop(stringArray[it]) })
    }

    actual fun InteropPointer.fromInteropNativePointerArray(): NativePointerArray =
        throw UnsupportedOperationException("a native pointer array of unknown size cannot be read")

    actual inline fun <reified T> InteropPointer.fromInterop(decoder: ArrayInteropDecoder<T>): Array<T> {
        val array = this
        val result = Array(decoder.getArraySize(array)) { decoder.getArrayElement(array, it) }
        decoder.disposeArray(array)
        return result
    }

    actual fun toInteropForArraysOfPointers(interopPointers: Array<InteropPointer>): InteropPointer =
        toInterop(interopPointers.toLongArray())

    actual fun callback(callback: (() -> Unit)?): InteropPointer = noCallback(callback)
    actual fun intCallback(callback: (() -> Int)?): InteropPointer = noCallback(callback)
    actual fun nativePointerCallback(callback: (() -> NativePointer)?): InteropPointer = noCallback(callback)
    actual fun interopPointerCallback(callback: (() -> InteropPointer)?): InteropPointer = noCallback(callback)
    actual fun booleanCallback(callback: (() -> Boolean)?): InteropPointer = noCallback(callback)

    actual fun virtual(method: () -> Unit): InteropPointer = noCallback(method)
    actual fun virtualInt(method: () -> Int): InteropPointer = noCallback(method)
    actual fun virtualNativePointer(method: () -> NativePointer): InteropPointer = noCallback(method)
    actual fun virtualInteropPointer(method: () -> InteropPointer): InteropPointer = noCallback(method)
    actual fun virtualBoolean(method: () -> Boolean): InteropPointer = noCallback(method)

    private fun noCallback(callback: Any?): InteropPointer {
        if (callback == null) return 0L
        throw UnsupportedOperationException(NO_CALLBACKS)
    }

    actual fun release() {
        for (ptr in allocations) __skiko_free(ptr)
        allocations.clear()
    }
}

internal const val NO_CALLBACKS = "Skia calling back into Kotlin is not supported on klio"

internal actual inline fun <T> interopScope(block: InteropScope.() -> T): T {
    val scope = InteropScope()
    try {
        return scope.block()
    } finally {
        scope.release()
    }
}

internal fun __skiko_malloc(size: Long): Long = error("intrinsic org.jetbrains.skia.impl.__skiko_malloc is not installed")
internal fun __skiko_free(ptr: Long): Unit = error("intrinsic org.jetbrains.skia.impl.__skiko_free is not installed")
internal fun __skiko_copyIn(ptr: Long, array: Any): Unit = error("intrinsic org.jetbrains.skia.impl.__skiko_copyIn is not installed")
internal fun __skiko_copyOut(ptr: Long, array: Any): Unit = error("intrinsic org.jetbrains.skia.impl.__skiko_copyOut is not installed")
internal fun __skiko_cstring(s: String): Long = error("intrinsic org.jetbrains.skia.impl.__skiko_cstring is not installed")
