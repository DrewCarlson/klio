// Implicit-receiver precedence for bare names, reads and writes alike:
// receivers are searched innermost-first; within one receiver a member
// outranks an applicable extension; a member of any receiver outranks a
// same-named top-level binding; and a dispatch receiver brings its
// class-nesting tower (`this@Owner`) into scope while a `with` subject
// brings only itself.

class Screen {
    var title: String = "untitled"

    fun describe(): String = "screen:$title"
}

class Widget {
    var width: Int = 0
}

fun Widget.describe(): String = "widget:$width"

var title: String = "top-level"

class Owner {
    var status: String = "idle"

    inner class Job {
        fun run() {
            listOf("go").forEach { status = "ran-$it" }
        }
    }
}

fun main() {
    val s = Screen()
    with(s) {
        with(Widget()) {
            // Write: Widget has no `title`, so the bare write reaches the
            // outer Screen receiver, not the top-level var.
            title = "from-widget"
            width = 42
            // Call: the extension applies to the inner Widget receiver and
            // outranks Screen's same-named member.
            println(describe())
        }
        // Call: with only the Screen receiver in scope, its member binds.
        println(describe())
    }
    println(s.title)
    println(title)

    // Innermost receiver wins when both own the member.
    val a = Screen()
    val b = Screen()
    with(a) {
        with(b) {
            title = "inner-write"
        }
    }
    println(a.title + "/" + b.title)

    // The dispatch receiver's nesting tower takes bare writes too.
    val owner = Owner()
    owner.Job().run()
    println(owner.status)
}
