open class StateRecord(var id: Int) {
    var next: StateRecord? = null
}

class MapRecord(id: Int, var map: String) : StateRecord(id)

fun <T : StateRecord> current(r: T): T = r

inline fun <T : StateRecord, R> T.withCurrent(block: (r: T) -> R): R = block(current(this))

class SnapshotMap {
    val firstStateRecord: StateRecord = MapRecord(1, "payload")

    @Suppress("UNCHECKED_CAST")
    private inline fun <R> withCurrent(block: MapRecord.() -> R): R =
        (firstStateRecord as MapRecord).withCurrent(block)

    fun mutate(): String {
        var oldMap: String? = null
        run {
            val current = withCurrent { this }
            oldMap = current.map
        }
        return oldMap!!
    }
}

fun main() {
    println(SnapshotMap().mutate())
}
