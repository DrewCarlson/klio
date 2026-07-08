// Regression: a package-qualified reference to an `object` in value position
// resolves to the one singleton, identical to the bare/imported name — not a
// separate class classifier. (`androidx…drawscope.Fill` used to become the
// class Fill, scrambling DrawScope draws.)
package demo

object Config {
    val name = "klio"
    var count = 0
}

fun main() {
    val bare = Config
    val qualified = demo.Config
    println("bare.name=${bare.name}")
    println("qualified.name=${qualified.name}")
    println("same=${bare === qualified}")
    qualified.count = 7
    println("bare.count=${bare.count}")
}
