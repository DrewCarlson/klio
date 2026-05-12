val Int.cubed: Int get() = this * this * this
val Int.cubedPlusOne: Int get() = this.cubed + 1

fun main() {
    println(3.cubedPlusOne)
    println(0.cubedPlusOne)
    println(2.cubedPlusOne)
}
