// A lambda's captured name referenced on BOTH branches of an elvis loads
// from the closure's capture slot on whichever branch runs. The first
// reference sits in the not-taken `?.apply` arm here; the `also` arm must
// still see the captured list and the captured `this`.

class Parent {
    var modified: MutableList<Int>? = null
}

inline fun <T> locked(block: () -> T): T = block()

class Nested {
    var modified: MutableList<Int>? = mutableListOf(7)
    val parent = Parent()

    fun applyIt() {
        val m = modified
        locked {
            if (m == null || m.size == 0) {
                println("empty")
            } else {
                parent.modified?.apply { addAll(m) }
                    ?: m.also {
                        parent.modified = it
                        this.modified = null
                    }
            }
        }
        println("parent=" + parent.modified + " own=" + modified)
        parent.modified?.apply { addAll(listOf(9)) } ?: println("no parent list")
        println("parent2=" + parent.modified)
    }
}

fun main() {
    Nested().applyIt()
}
