// MM4 — val/immutable safe publication (threaded). Reduction: a
// fully constructed object's `val` fields are observable after
// construction completes. The threaded form publishes `cfg` to
// another thread; the reduction observes it on the same thread,
// asserting construction-before-use ordering.
//> 7
//> ready
class Config(val limit: Int) { val label = "ready" }
fun main() {
    val cfg = Config(7)
    println(cfg.limit)
    println(cfg.label)
}
