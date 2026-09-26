// Kotlin/Native's weak references and cleaners: a weak reference answers
// its referent while something else keeps it alive and null once a
// collection frees it, and a cleaner runs its action on the cleaner thread
// after its owner is collected.
@file:OptIn(
    kotlin.experimental.ExperimentalNativeApi::class,
    kotlin.native.runtime.NativeRuntimeApi::class,
    kotlin.concurrent.atomics.ExperimentalAtomicApi::class,
)

import kotlin.concurrent.atomics.AtomicInt
import kotlin.native.ref.WeakReference
import kotlin.native.ref.createCleaner
import kotlin.native.runtime.GC

class Image(val name: String)

// A cache that holds its images weakly: an image nobody else uses is dropped.
class ImageCache {
    private val entries = HashMap<String, WeakReference<Image>>()

    fun get(name: String): Image? = entries[name]?.get()

    fun put(image: Image) {
        entries[image.name] = WeakReference(image)
    }

    fun live(): List<String> = entries.filterValues { it.get() != null }.keys.sorted()
}

// A native buffer's stand-in: the cleaner frees it when its owner goes.
class Buffer(val size: Int, freed: AtomicInt) {
    private val cleaner = createCleaner(size) { freed.addAndFetch(it) }
}

fun fill(cache: ImageCache): Image {
    val kept = Image("logo")
    cache.put(kept)
    cache.put(Image("splash"))
    cache.put(Image("banner"))
    return kept
}

fun allocate(freed: AtomicInt) {
    Buffer(64, freed)
    Buffer(128, freed)
}

fun main() {
    val cache = ImageCache()
    val logo = fill(cache)
    println("before: ${cache.live()}")
    GC.collect()
    println("after: ${cache.live()}")
    println("logo: ${cache.get("logo")?.name}")
    println("splash: ${cache.get("splash")?.name}")

    val ref = WeakReference(logo)
    println("value: ${ref.value?.name}")
    ref.clear()
    println("cleared: ${ref.value}")

    val freed = AtomicInt(0)
    allocate(freed)
    GC.collect()
    var tries = 0
    while (freed.load() < 192 && tries < 500) {
        Thread.sleep(10)
        tries++
    }
    println("freed bytes: ${freed.load()}")
    println(logo.name)
}
