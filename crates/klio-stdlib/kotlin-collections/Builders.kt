// klio commonMain shipment of kotlin.collections list builders.
//
// These are the exact upstream Kotlin definitions of the
// size+initializer factories `List` and `MutableList` from
// kotlin/libraries/stdlib/src/kotlin/collections/Collections.kt.
// They live here as a focused excerpt so the embedded stdlib pack
// can ship the real common-Kotlin builder code without dragging in
// every transitive declaration of the full file.

package kotlin.collections

public inline fun <T> List(size: Int, init: (index: Int) -> T): List<T> = MutableList(size, init)

public inline fun <T> MutableList(size: Int, init: (index: Int) -> T): MutableList<T> {
    val list = ArrayList<T>(size)
    repeat(size) { index -> list.add(init(index)) }
    return list
}
