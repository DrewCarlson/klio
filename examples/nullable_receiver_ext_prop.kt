// An extension property on a nullable receiver dispatches for a null
// receiver too — the Row/Column `parentData.weight` pattern.
class ParentData(val w: Float)

val ParentData?.weight: Float
    get() = this?.w ?: 0f

val ParentData?.fill: Boolean
    get() = this != null

fun main() {
    val a: ParentData? = ParentData(2.5f)
    val b: ParentData? = null
    println("a.weight=${a.weight} b.weight=${b.weight}")
    println("a.fill=${a.fill} b.fill=${b.fill}")
}
