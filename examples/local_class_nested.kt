// A class declared inside a LOCAL class — one declared in a function body.
//
// Kotlin allows a local class to nest further declarations, `inner` or plain,
// and declaration order inside the body does not matter. kotlinx-io's own
// rawSourceSample does this: a decrypting source declared inside a test
// function, holding an `inner class` for its cipher key.
//
// Run with: klio run examples/local_class_nested.kt

interface Source {
    fun readOne(): Int
}

fun buildSource(seed: String): String {
    class Decrypting(private val name: String, key: String) : Source {
        // Constructs a class declared LATER in this same body.
        private val key = CipherKey(key)

        override fun readOne(): Int = key.label.length

        fun tag(): String = name + ":" + key.label

        private inner class CipherKey(k: String) {
            val label = "k(" + k + ")"
        }

        // A plain nested class, for contrast with the `inner` one. Reached
        // from inside the local class; qualified access from outside
        // (`Decrypting.Marker()`) is a separate gap and not shown here.
        private class Marker {
            val name = "marker"
        }

        fun marker(): String = Marker().name
    }

    val d = Decrypting("down", seed)
    return d.tag() + ":" + d.readOne() + ":" + d.marker()
}

fun main() {
    println(buildSource("secret"))
}
