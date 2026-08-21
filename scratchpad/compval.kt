class Box(val n: Int) {
    companion object {
        val ZERO: Box = Box(0)
        fun makeBare(): Box = ZERO
        fun makeQualified(): Box = Box.ZERO
        fun makeThis(): Box = this.ZERO
    }
}

object Holder {
    val ONE: Box = Box(1)
    fun bare(): Box = ONE
}

fun main() {
    println("qualified stable = " + (Box.ZERO === Box.ZERO))
    println("bare from companion = " + (Box.makeBare() === Box.ZERO))
    println("qualified from companion = " + (Box.makeQualified() === Box.ZERO))
    println("this. from companion = " + (Box.makeThis() === Box.ZERO))
    println("object bare = " + (Holder.bare() === Holder.ONE))
}
