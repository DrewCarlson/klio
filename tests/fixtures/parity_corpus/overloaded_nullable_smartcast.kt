private class Record(val id: Long)

private fun valid(current: Long, candidate: Long, ignored: Int): Boolean =
    candidate <= current

private fun valid(data: Record, snapshot: Long, ignored: Int): Boolean =
    data.id <= snapshot

fun main() {
    var current: Record? = Record(1L)
    while (current != null) {
        println(valid(current, 2L, 0))
        current = null
    }

    val record: Record? = Record(2L)
    if (record != null) println(valid(record, 3L, 0))
    if (record == null) println("missing") else println(valid(record, 4L, 0))
}
