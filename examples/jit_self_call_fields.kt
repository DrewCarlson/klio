// A method calling sibling methods that read and write the same receiver's
// `this`-fields: a mutator taking an argument, a `Unit` counter increment,
// and a method computing a result from the current field values.
class Grid(var w: Int, var h: Int) {
    var touched = 0
    fun area(): Int = w * h
    fun widen(k: Int) { w = w + k }
    fun note() { touched = touched + 1 }
    fun step(k: Int): Int {
        widen(k)
        note()
        return area()
    }
}

fun main() {
    val g = Grid(2, 3)
    var i = 0
    var t = 0
    while (i < 120_000) {
        t = (t + g.step(if (i % 1000 == 0) 1 else 0)) % 1000003
        i += 1
    }
    println("t=" + t + " w=" + g.w + " touched=" + g.touched)
}
