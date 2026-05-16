// MM4 — val/immutable safe publication, genuinely concurrent. The
// main thread fully constructs `cfg`, then publishes it by handing
// it to a spawned OS thread. The spawned thread observes the
// reference only after publication, so the constructor's writes to
// the `val` fields are visible to it (final-field safe publication).
// Deterministic: only the child prints, then main joins.
//> 7
//> ready
import kotlin.concurrent.thread
class Config(val limit: Int) { val label = "ready" }
fun main() {
    val cfg = Config(7)
    val t = thread {
        println(cfg.limit)
        println(cfg.label)
    }
    t.join()
}
