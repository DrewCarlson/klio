// `Nothing?` is the null literal's type and the bottom of the lattice, so it
// constrains only nullability: `listOf(null, "foo")` is `List<String?>`, and
// the element type has to survive for members on the result to bind.
class Holder {
    fun run() {
        val source = listOf(null, "foo", "bar")
        println(source.flatMap { it.orEmpty().asSequence() })
        println(source.filterNotNull())
        println(source.size)

        val trailing = listOf("a", null)
        println(trailing.filterNotNull())

        val onlyNull = listOf(null, null)
        println(onlyNull.size)

        val mixed = listOf('a', "b", null, 'e')
        println(mixed.filterIsInstance<String>())

        val nested = listOf(listOf(1), null)
        println(nested.filterNotNull().flatten())

        println(mapOf("k" to null, "j" to 2).size)
        println(arrayOf(null, "x").size)
    }
}
fun main() { Holder().run() }
