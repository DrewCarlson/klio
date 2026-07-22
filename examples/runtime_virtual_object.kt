interface RuntimeValueSource {
    fun value(): Int = 42
}

interface RuntimeOtherSource {
    fun other(): Int = 7
}

interface RuntimeNamedSource {
    fun combine(left: Int = 10, right: Int = 20): Int
}

fun inheritedRuntimeSource(): RuntimeValueSource =
    object : RuntimeOtherSource, RuntimeValueSource {}

fun overriddenRuntimeSource(): RuntimeValueSource = object : RuntimeValueSource {
    override fun value(): Int = 99
}

fun namedRuntimeSource(): RuntimeNamedSource = object : RuntimeNamedSource {
    override fun combine(left: Int, right: Int): Int = left + right
}

fun main() {
    val inherited: RuntimeValueSource = inheritedRuntimeSource()
    val overridden: RuntimeValueSource = overriddenRuntimeSource()
    val named: RuntimeNamedSource = namedRuntimeSource()
    println(inherited.value())
    println(overridden.value())
    println(named.combine(right = 5))
}
