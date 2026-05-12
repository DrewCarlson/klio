class Outer(val tag: String) {
    fun build(v: Int): String {
        class Local {
            val mark = "L"
            fun show(): String = "${this@Outer.tag}:$v:$mark"
        }
        return Local().show()
    }

    inner class Inner {
        fun show(): String = "${this@Outer.tag}/${this.toString().length > 0}"
    }

    fun self(): String = "${this@Outer.tag}-self"
}

fun main() {
    val o = Outer("T")
    println(o.build(7))
    println(o.Inner().show())
    println(o.self())

    val q = Outer("Q")
    class Top {
        fun show(): String = q.build(3)
    }
    println(Top().show())
}
