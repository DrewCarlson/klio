// A bare-name write inside an inline extension's receiver lambda (`apply`,
// `run`) targets the lambda RECEIVER's property. The receiver of a spliced
// inline body lives in an ordinary register rather than a capture slot, so a
// write that only consulted the capture walk found no receiver and landed on a
// same-named global instead — silently, while reading the same name worked.
class Box {
    var tag: String = "init"
    val label: String = "lbl"
}

var tag: String = "global"

fun main() {
    val a = Box().apply { tag = "applied" }
    println(a.tag)

    val b = Box()
    b.run { tag = "ran" }
    println(b.tag)

    // The receiver's own members are readable in the same body.
    val c = Box().apply { tag = label + "!" }
    println(c.tag)

    // with() binds the receiver as an argument and always worked.
    val d = Box()
    with(d) { tag = "withed" }
    println(d.tag)

    // Explicit and it-form spellings agree with the bare one.
    val e = Box().apply { this.tag = "explicit" }
    println(e.tag)
    val f = Box().also { it.tag = "also" }
    println(f.tag)

    // The file-scope `tag` is untouched by any of the above.
    println(tag)
}
