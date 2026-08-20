// A lambda literal that ANNOTATES its parameters states their types, and those
// types decide which candidate a bare call reaches.
//
// `forEachIndexed` names both a member of the enclosing class and a stdlib
// extension on CharSequence. Inside `buildString { ... }` the innermost
// receiver is a StringBuilder, so the extension looks applicable — but the
// literal declares `element: Long`, and the CharSequence one yields a Char.
// The member is what the call means. (Binding the extension would iterate the
// builder the body is appending to, which never terminates.)
//
// Run with: klio run examples/lambda_param_types_pick_overload.kt

class Row(val id: Long)

class Table {
    private val rows = mutableListOf(1L, 2L, 3L)

    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        var i = 0
        while (i < rows.size) {
            block(i, rows[i])
            i = i + 1
        }
    }

    // The annotated literal picks the member over CharSequence's extension.
    fun render(): String = buildString {
        append('[')
        forEachIndexed { index: Int, element: Long ->
            if (index != 0) append(", ")
            append(element)
        }
        append(']')
    }

    // A class-typed parameter decides it the same way.
    inline fun forEachRow(block: (index: Int, row: Row) -> Unit) {
        var i = 0
        while (i < rows.size) {
            block(i, Row(rows[i]))
            i = i + 1
        }
    }

    fun renderRows(): String = buildString {
        forEachRow { _: Int, row: Row -> append(row.id) }
    }
}

fun main() {
    println("render     = " + Table().render())
    println("renderRows = " + Table().renderRows())

    // The stdlib extension still binds where it genuinely applies.
    val sb = StringBuilder("abc")
    val chars = StringBuilder()
    sb.forEachIndexed { _: Int, c: Char -> chars.append(c) }
    println("charSeq    = " + chars)
}
