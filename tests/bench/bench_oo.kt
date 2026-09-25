// bench_oo: virtual calls on a small class hierarchy, property reads and a
// field accumulator. Measured for user CPU by scripts/measure-row.py.
abstract class Shape { abstract fun area(): Int }
class Sq(val s: Int) : Shape() { override fun area(): Int = s * s }
class Rect(val w: Int, val h: Int) : Shape() { override fun area(): Int = w * h }
class Acc { var total = 0L; fun add(x: Int) { total += x } }
fun main() {
    val shapes = ArrayList<Shape>()
    for (i in 0 until 1000) shapes.add(if (i % 2 == 0) Sq(i % 13) else Rect(i % 7, i % 5))
    val acc = Acc()
    for (r in 0 until 2000) {
        for (sh in shapes) acc.add(sh.area())
    }
    println(acc.total)
}
