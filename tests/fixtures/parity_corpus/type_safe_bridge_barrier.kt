// kotlinc's type-safe bridge: a generic collection member called through an
// erased signature checks the argument against the class type parameter's
// bound and answers the barrier default for a foreign value (indexOf -> -1,
// contains -> false) instead of running the body against a representation
// the value does not have. EnumEntriesList.indexOf reads element.ordinal,
// so a foreign element must never enter it.
enum class Color { RED, GREEN }

fun main() {
    val list = Color.entries
    val foreign = object {}
    val erased = list as List<Any?>
    println(erased.indexOf(foreign))
    println(erased.lastIndexOf(foreign))
    println(erased.contains(foreign))
    println(erased.indexOf(null))
    println(list.indexOf(Color.GREEN))
    println(list.lastIndexOf(Color.RED))
    println(list.contains(Color.RED))
}
