// skiko's managed and reference-counted peers on klio. The finalizer is the
// C glue's delete for the peer's type; it runs once, by close() or after a
// collection frees the peer, as skiko's native target has it. Native skiko
// frees through a cleaner; klio registers the finalizer with the runtime
// directly, which frees the object on the sweeper thread with no Kotlin code.
package org.jetbrains.skia.impl

import klio.ref.registerNativeFinalizer
import klio.ref.runNativeFinalizer
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
    finalizer: NativePointer,
    managed: Boolean,
) : Native(ptr) {
    private val finalization: Long = if (managed) {
        require(ptr != NullPointer) { "Managed ptr is nullptr" }
        require(finalizer != NullPointer) { "Managed finalizer is nullptr" }
        registerNativeFinalizer(this, finalizer, ptr)
    } else 0L

    actual open fun close() {
        require(_ptr != NullPointer) {
            "Object already closed: ${this::class.simpleName}, _ptr=$_ptr"
        }
        require(finalization != 0L) {
            "Object is not managed in K/N runtime, can't close(): ${this::class.simpleName}, _ptr=$_ptr"
        }
        val ran = runNativeFinalizer(finalization)
        require(ran) {
            "Object is closed already, can't close(): ${this::class.simpleName}, _ptr=$_ptr"
        }
        _ptr = NullPointer
    }

    actual open val isClosed: Boolean
        get() = _ptr == NullPointer
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
