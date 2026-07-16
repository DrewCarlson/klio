// A captured outer `var` incremented inside an anonymous object's method
// and inside a LOCAL class's method writes through to the declaration
// site, exactly like a lambda capture.
package p

interface Obs {
    fun begin()

    fun end()
}

fun drive(o: Obs) {
    o.begin()
    o.end()
    o.begin()
}

fun main() {
    var beginCount = 0
    var endCount = 0
    val observer = object : Obs {
        override fun begin() { beginCount++ }

        override fun end() { endCount++ }
    }
    drive(observer)
    println("$beginCount $endCount")

    var bumps = 0
    class Bumper {
        fun bump() { bumps++ }
    }
    val b = Bumper()
    b.bump()
    b.bump()
    println(bumps)
}
