// Reading a `var` declared without an initializer before any write on the
// reaching path. Expect T0020.

fun main() {
    var x: Int
    println(x)
    x = 1
}
