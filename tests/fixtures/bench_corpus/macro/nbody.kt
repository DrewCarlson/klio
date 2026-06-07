class Body(var x: Double, var y: Double, var vx: Double, var vy: Double, val m: Double)

fun step(bodies: List<Body>, dt: Double) {
    val n = bodies.size
    for (i in 0 until n) {
        val a = bodies[i]
        for (j in (i + 1) until n) {
            val b = bodies[j]
            val dx = b.x - a.x
            val dy = b.y - a.y
            val d2 = dx * dx + dy * dy + 1e-3
            val f = 1.0 / (d2 * kotlin.math.sqrt(d2))
            a.vx += dx * f * b.m
            a.vy += dy * f * b.m
            b.vx -= dx * f * a.m
            b.vy -= dy * f * a.m
        }
    }
    for (b in bodies) {
        b.x += b.vx * dt
        b.y += b.vy * dt
    }
}

fun main() {
    val bodies = (0 until 30).map {
        Body(it.toDouble(), (it % 7).toDouble(), 0.0, 0.0, 1.0 + (it % 5).toDouble())
    }
    var i = 0
    while (i < 200) { step(bodies, 0.01); i += 1 }
    var s = 0.0
    for (b in bodies) s += b.x + b.y
    println((s * 100).toInt())
}
