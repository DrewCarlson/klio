// A trailing-lambda call whose block mutates a captured variable must still
// bind the overload that hosts the lambda. Here `slot(key) { ... }` is a
// receiver extension on `Table` taking a `() -> Unit`, while the same name
// also denotes a top-level `slot(data, index)` that cannot host a lambda.
// When the block writes the captured `total`, the call routes through the
// closure-writeback lowering path; that path must apply the same
// trailing-lambda-hosting preference as the ordinary path, or the lambda
// lands on the scalar `index` parameter of the wrong overload.

class Table {
    val base: Int = 10
    fun open(key: Int): Int = base + key
}

fun slot(data: IntArray, index: Int): Int = data[index]

inline fun Table.slot(key: Int, block: () -> Unit) {
    block()
}

fun main() {
    var total = 0
    with(Table()) {
        slot(1) {
            slot(2) {
                total = open(3)
            }
        }
    }
    println(total)

    // The top-level overload still resolves for a non-lambda call.
    val data = intArrayOf(5, 6, 7)
    println(slot(data, 2))
}
