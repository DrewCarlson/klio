class Vec(val x: Int) {
    operator fun unaryMinus(): Vec = Vec(-x)
    operator fun unaryPlus(): Vec = Vec(+x)
    override fun toString(): String = "Vec($x)"
}

class Flag(val on: Boolean) {
    operator fun not(): Flag = Flag(!on)
    override fun toString(): String = "Flag($on)"
}

fun main() {
    println(-Vec(5))
    println(+Vec(-3))
    println(!Flag(true))
    println(!Flag(false))
}
