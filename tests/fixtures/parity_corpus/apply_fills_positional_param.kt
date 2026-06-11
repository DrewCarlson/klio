class Scope(val label: String)

class Plugin(val key: String) {
    fun install(data: String, scope: Scope?) {
        println("install " + data + " on " + (scope?.label ?: "NULL"))
    }
}

class Holder {
    val plugins = mutableMapOf<String, (Scope) -> Unit>()

    fun installPlugin(plugin: Plugin) {
        plugins[plugin.key] = { scope ->
            plugin.install("data", scope)
        }
    }

    fun install(client: Scope) {
        plugins.values.forEach { client.apply(it) }
    }
}

fun main() {
    val f: (Scope) -> Unit = { scope ->
        println(scope.label)
        val copy = scope
        println(copy.label)
    }
    Scope("direct").apply(f)
    val h = Holder()
    h.installPlugin(Plugin("k1"))
    h.install(Scope("s1"))
}
