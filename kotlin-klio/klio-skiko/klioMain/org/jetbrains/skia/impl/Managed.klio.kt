// skiko's managed and reference-counted peers on klio. The finalizer is the
// C glue's delete for the peer's type; close() runs it, as the desktop's does.
// The collector does not run finalizers, so a peer that is never closed keeps
// its native object.
package org.jetbrains.skia.impl

import org.jetbrains.skia.ExternalSymbolName

actual class NativePointerArray actual constructor(size: Int) {
    internal val backing = LongArray(size)

    actual operator fun get(index: Int): NativePointer = backing[index]

    actual operator fun set(index: Int, value: NativePointer) {
        backing[index] = value
    }

    actual val size: Int get() = backing.size
}

actual abstract class Managed actual constructor(
    ptr: NativePointer,
    private val finalizer: NativePointer,
    private val managed: Boolean,
) : Native(ptr) {
    actual open fun close() {
        if (_ptr == NullPointer) {
            throw RuntimeException("Object already closed: ${this::class.simpleName}, _ptr=$_ptr")
        }
        if (!managed) {
            throw RuntimeException("Object is not managed, can't close(): ${this::class.simpleName}, _ptr=$_ptr")
        }
        Managed_invokeFinalizer(finalizer, _ptr)
        _ptr = NullPointer
    }

    actual open val isClosed: Boolean get() = _ptr == NullPointer
}

actual abstract class RefCnt : Managed {
    protected actual constructor(ptr: NativePointer) : super(ptr, FinalizerHolder.PTR, true)

    protected actual constructor(ptr: NativePointer, allowClose: Boolean) : super(ptr, FinalizerHolder.PTR, allowClose)

    actual val refCount: Int
        get() = try {
            Stats.onNativeCall()
            RefCnt_nGetRefCount(_ptr)
        } finally {
            reachabilityBarrier(this)
        }

    override fun toString(): String = refCntToString(super.toString(), NullPointer)

    private object FinalizerHolder {
        val PTR = RefCnt_nGetFinalizer()
    }
}

actual class Library {
    actual companion object {
        /** The glue is in the Skia shim, which loads with the first native call. */
        actual fun staticLoad() {}
    }
}

actual object Stats {
    actual fun onNativeCall() {}
    actual fun onAllocated(className: String) {}
    actual fun onDeallocated(className: String) {}
}

internal actual fun RefCnt_nGetFinalizer(): NativePointer = RefCnt_getFinalizer()

@ExternalSymbolName("org_jetbrains_skia_impl_RefCnt__getFinalizer")
private external fun RefCnt_getFinalizer(): NativePointer

@ExternalSymbolName("org_jetbrains_skia_impl_RefCnt__getRefCount")
private external fun RefCnt_nGetRefCount(ptr: NativePointer): Int

@ExternalSymbolName("org_jetbrains_skia_impl_Managed__invokeFinalizer")
private external fun Managed_invokeFinalizer(finalizer: NativePointer, ptr: NativePointer)
