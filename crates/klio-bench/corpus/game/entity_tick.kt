class Entity(var x: Double, var y: Double, var vx: Double, var vy: Double, var hp: Int)

fun tick(es: List<Entity>, dt: Double) {
    for (e in es) {
        e.x += e.vx * dt
        e.y += e.vy * dt
        if (e.x < 0.0 || e.x > 100.0) e.vx = -e.vx
        if (e.y < 0.0 || e.y > 100.0) e.vy = -e.vy
        if (e.hp > 0) e.hp -= 1
    }
}

fun main() {
    val ents = (0 until 2000).map {
        Entity(
            (it % 100).toDouble(),
            ((it * 7) % 100).toDouble(),
            1.0 + (it % 3).toDouble(),
            1.0 + (it % 5).toDouble(),
            100,
        )
    }
    var frame = 0
    while (frame < 60) { tick(ents, 0.016); frame += 1 }
    var alive = 0
    for (e in ents) if (e.hp > 0) alive += 1
    println(alive)
}
