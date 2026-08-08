// A statically bound slot on a host collection reaches its intrinsic without
// a member-name walk. The container variants take the receiver as it stands;
// exercise the members that walked before, plus the mutation and iteration
// order that a wrong binding would disturb.
fun main() {
    val ml = mutableListOf(3, 1, 2)
    ml.add(4)
    ml.add(0, 9)
    ml[1] = 7
    ml.removeAt(0)
    println(ml)
    println(ml.size)
    println(ml.isEmpty())
    println(ml.contains(7))
    println(ml.indexOf(2))
    println(ml.subList(0, 2))
    ml.addAll(listOf(5, 6))
    println(ml)
    ml.remove(5)
    println(ml)

    val s = mutableSetOf("b", "a")
    s.add("c")
    s.remove("b")
    println(s.sorted())
    println(s.isEmpty())
    println(s.size)

    val m = mutableMapOf("x" to 1)
    m["y"] = 2
    m.remove("x")
    println(m)
    println(m.size)
    println(m.isEmpty())
    println(m.containsKey("y"))

    val ro: List<Int> = listOf(1, 2, 3)
    var sum = 0
    for (v in ro) sum += v
    println(sum)
    println(ro.iterator().next())
    val li = ro.listIterator(1)
    println(li.previous())
    println(li.hasPrevious())
}
