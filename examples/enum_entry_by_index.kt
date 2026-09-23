// `EnumClass.Entry` is a reference Kotlin settles where it is written, so
// lowering carries the entry's index and the read indexes the table instead of
// comparing the name against every entry. The runtime still proves the name at
// that index before serving it, so anything that is not a settled classifier
// read keeps the by-name walk: a local shadowing the enum's spelling, an entry
// reached through a value, an entry named bare inside the enum's own members.
//
// A renamed import of an entry binds the QUALIFIED path: `Dir.East` is a member
// of a class and is not loadable by its bare name.
//
// Run with: klio run examples/enum_entry_by_index.kt

import Dir.East as Sunrise

enum class Dir(val dx: Int, val dy: Int) {
    North(0, -1),
    South(0, 1),
    East(1, 0),
    West(-1, 0);

    // Bare inside the enum's own members, the entries need no qualifier.
    fun opposite(): Dir = when (this) {
        North -> South
        South -> North
        East -> West
        West -> East
    }
}

enum class Empty

fun show(d: Dir): String = "${d.name}(${d.dx},${d.dy})"

fun main() {
    println(show(Dir.North))
    println(show(Dir.West.opposite()))
    println(show(Dir.East) + " " + show(Sunrise))
    println(Dir.valueOf("South").dy)
    println(Dir.entries.size.toString() + " " + Empty.entries.size)
    // A local of the enum's spelling is the value, not the classifier.
    val Dir = "shadowed"
    println(Dir.length)
}
