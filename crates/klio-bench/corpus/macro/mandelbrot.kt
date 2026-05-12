fun main() {
    val w = 60
    val h = 30
    val maxIter = 50
    var count = 0
    for (py in 0 until h) {
        for (px in 0 until w) {
            val x0 = (px.toDouble() / w) * 3.5 - 2.5
            val y0 = (py.toDouble() / h) * 2.0 - 1.0
            var x = 0.0
            var y = 0.0
            var i = 0
            while (x * x + y * y <= 4.0 && i < maxIter) {
                val xt = x * x - y * y + x0
                y = 2.0 * x * y + y0
                x = xt
                i += 1
            }
            if (i == maxIter) count += 1
        }
    }
    println(count)
}
