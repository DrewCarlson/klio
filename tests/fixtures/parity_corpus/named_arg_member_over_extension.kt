// A named-argument call must pick the overload whose parameter types fit the
// arguments. A class member and a same-named top-level extension differing in
// their first parameter type previously mis-resolved with named args: the
// extension was chosen even when a positional argument could not bind its
// parameter. Now the type-incompatible candidate is rejected so the member
// wins (and a named first argument still selects the extension when it fits).
class Sink {
    fun write(data: IntArray, startIndex: Int = 0, endIndex: Int = data.size): String =
        "ints[${endIndex - startIndex}]"
}

fun Sink.write(text: String, startIndex: Int = 0, endIndex: Int = text.length): String =
    "text[${text.substring(startIndex, endIndex)}]"

fun main() {
    val s = Sink()
    println(s.write(intArrayOf(1, 2, 3, 4), startIndex = 0, endIndex = 3))
    println(s.write(intArrayOf(9, 8), endIndex = 2))
    println(s.write(text = "hello", startIndex = 1, endIndex = 4))
}
