// klio actuals for the snapshot-id expects. A snapshot id is a Long here, as it
// is on the JVM (the type exists because JavaScript has no efficient Long); an
// id array is a LongArray.

package androidx.compose.runtime.snapshots

public actual typealias SnapshotId = Long

internal actual val SnapshotIdZero: SnapshotId = 0L
internal actual val SnapshotIdMax: SnapshotId = Long.MAX_VALUE
internal actual val SnapshotIdInvalidValue: SnapshotId = -1L
internal actual val SnapshotIdSize: Int = Long.SIZE_BITS

internal actual inline operator fun SnapshotId.compareTo(other: SnapshotId): Int =
    this.compareTo(other)

internal actual inline operator fun SnapshotId.compareTo(other: Int): Int =
    this.compareTo(other.toLong())

internal actual inline operator fun SnapshotId.plus(other: Int): SnapshotId = this + other.toLong()

internal actual inline operator fun SnapshotId.minus(other: SnapshotId): SnapshotId = this - other

internal actual inline operator fun SnapshotId.minus(other: Int): SnapshotId = this - other.toLong()

internal actual inline operator fun SnapshotId.div(other: Int): SnapshotId = this / other.toLong()

internal actual inline operator fun SnapshotId.times(other: Int): SnapshotId = this * other.toLong()

public actual inline fun SnapshotId.toInt(): Int = this.toInt()

public actual inline fun SnapshotId.toLong(): Long = this

public actual typealias SnapshotIdArray = LongArray

internal actual fun snapshotIdArrayWithCapacity(capacity: Int): SnapshotIdArray = LongArray(capacity)

internal actual fun snapshotIdArrayOf(id: SnapshotId): SnapshotIdArray = longArrayOf(id)

internal actual inline operator fun SnapshotIdArray.get(index: Int): SnapshotId = this[index]

internal actual inline operator fun SnapshotIdArray.set(index: Int, value: SnapshotId) {
    this[index] = value
}

internal actual inline val SnapshotIdArray.size: Int
    get() = this.size

internal actual inline fun SnapshotIdArray.copyInto(other: SnapshotIdArray) {
    this.copyInto(other, 0)
}

internal actual inline fun SnapshotIdArray.first(): SnapshotId = this[0]

internal actual inline fun SnapshotIdArray.forEach(block: (SnapshotId) -> Unit) {
    for (value in this) block(value)
}

internal actual fun SnapshotIdArray.binarySearch(id: SnapshotId): Int {
    var low = 0
    var high = size - 1
    while (low <= high) {
        val mid = (low + high).ushr(1)
        val midVal = this[mid]
        if (midVal < id) low = mid + 1 else if (midVal > id) high = mid - 1 else return mid
    }
    return -(low + 1)
}

internal actual fun SnapshotIdArray.withIdInsertedAt(index: Int, id: SnapshotId): SnapshotIdArray {
    val newSize = size + 1
    val new = LongArray(newSize)
    this.copyInto(destination = new, destinationOffset = 0, startIndex = 0, endIndex = index)
    this.copyInto(
        destination = new,
        destinationOffset = index + 1,
        startIndex = index,
        endIndex = newSize - 1,
    )
    new[index] = id
    return new
}

internal actual fun SnapshotIdArray.withIdRemovedAt(index: Int): SnapshotIdArray? {
    val newSize = size - 1
    if (newSize == 0) return null
    val new = LongArray(newSize)
    if (index > 0) {
        this.copyInto(destination = new, destinationOffset = 0, startIndex = 0, endIndex = index)
    }
    if (index < newSize) {
        this.copyInto(
            destination = new,
            destinationOffset = index,
            startIndex = index + 1,
            endIndex = size,
        )
    }
    return new
}

internal actual class SnapshotIdArrayBuilder actual constructor(array: SnapshotIdArray?) {
    private val list = ArrayList<Long>(array?.size ?: 0)

    init {
        if (array != null) for (id in array) list.add(id)
    }

    actual fun add(id: SnapshotId) {
        list.add(id)
    }

    actual fun toArray(): SnapshotIdArray? {
        val size = list.size
        if (size == 0) return null
        val out = LongArray(size)
        for (i in 0 until size) out[i] = list[i]
        return out
    }
}

internal actual fun Int.toSnapshotId(): SnapshotId = this.toLong()

internal actual fun Long.toSnapshotId(): SnapshotId = this
