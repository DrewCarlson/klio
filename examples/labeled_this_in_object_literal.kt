// Kotlin's implicit receivers stack. Inside an object literal written in a
// receiver lambda, `this@build` names the LAMBDA's receiver (not the object),
// and a bare name the object does not own resolves against it too.

class Report(val title: String) {
    fun render(): String = "report(" + title + ")"
}

class Builder(val report: Report)

interface Named {
    val name: String
    fun describe(): String
}

fun build(block: Builder.() -> Unit) = Builder(Report("quarterly")).block()

fun main() {
    build {
        val named = object : Named {
            override val name: String
                get() = this@build.report.title
            override fun describe(): String = report.render()
        }
        println("name=" + named.name)
        println("describe=" + named.describe())
    }
}
