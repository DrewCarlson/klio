// Kotlin/Native's kotlin.native.Platform: what the program runs on, over the
// host klio runs on. Also the identity hash Kotlin/Native gives every object.

package kotlin.native

import kotlin.experimental.ExperimentalNativeApi

@ExperimentalNativeApi
public enum class OsFamily {
    UNKNOWN,
    MACOSX,
    IOS,
    LINUX,
    WINDOWS,
    ANDROID,
    WASM,
    TVOS,
    WATCHOS
}

@ExperimentalNativeApi
public enum class CpuArchitecture(public val bitness: Int) {
    UNKNOWN(-1),
    ARM32(32),
    ARM64(64),
    X86(32),
    X64(64),
    MIPS32(32),
    MIPSEL32(32),
    WASM32(32);
}

@ExperimentalNativeApi
@Deprecated("The only possible value returned in runtime is MemoryModel.EXPERIMENTAL now. The usages of this enum can be safely removed.")
public enum class MemoryModel {
    STRICT,
    RELAXED,
    EXPERIMENTAL,
}

/** The platform the program runs on. */
@ExperimentalNativeApi
public object Platform {
    public val canAccessUnaligned: Boolean
        get() = true

    public val isLittleEndian: Boolean
        get() = true

    public val osFamily: OsFamily
        get() = OsFamily.values()[__klio_osFamily()]

    public val cpuArchitecture: CpuArchitecture
        get() = CpuArchitecture.values()[__klio_cpuArchitecture()]

    @Deprecated("This property always returns MemoryModel.EXPERIMENTAL, its usages can be safely removed.", ReplaceWith("MemoryModel.EXPERIMENTAL"))
    @Suppress("DEPRECATION")
    public val memoryModel: MemoryModel
        get() = MemoryModel.EXPERIMENTAL

    public val isDebugBinary: Boolean
        get() = false

    @Deprecated("Support for the legacy memory manager has been completely removed. Consequently, this property is always `false`.", ReplaceWith("false"))
    @DeprecatedSinceKotlin(errorSince = "2.1")
    public val isFreezingEnabled: Boolean
        get() = false

    /** The program's name, which klio does not know: null. */
    public val programName: String?
        get() = null

    @Deprecated("Memory leak checking is deprecated")
    public var isMemoryLeakCheckerActive: Boolean = false

    @Deprecated("Cleaners leak checking is deprecated and should not be relied upon anymore")
    public var isCleanersLeakCheckerActive: Boolean = false

    public fun getAvailableProcessors(): Int = __klio_availableProcessors()
}

@ExperimentalStdlibApi
@Deprecated("This property always returns true, its usages can be safely removed.", ReplaceWith("true"))
public fun isExperimentalMM(): Boolean = true

internal external fun __klio_osFamily(): Int
internal external fun __klio_cpuArchitecture(): Int
internal external fun __klio_availableProcessors(): Int

/**
 * Computes a hash code of an object's identity: the same for the object's
 * whole life, and independent of its [Any.hashCode].
 */
@ExperimentalNativeApi
public fun Any?.identityHashCode(): Int = __klio_identityHashCode(this)

internal fun __klio_identityHashCode(value: Any?): Int =
    error("intrinsic kotlin.native.__klio_identityHashCode is not installed")
