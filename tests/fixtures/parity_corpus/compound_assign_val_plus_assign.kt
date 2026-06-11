class Config {
    val plugins = mutableListOf<String>()
    var redirects: Boolean = true

    operator fun plusAssign(other: Config) {
        redirects = other.redirects
        plugins += other.plugins
    }
}

class Client {
    internal val config = Config()

    fun merge(user: Config) {
        with(user) {
            config.plugins.add("base")
            config += this
            config.plugins.add("tail")
        }
    }
}

fun main() {
    val user = Config()
    user.redirects = false
    user.plugins.add("user")
    val c = Client()
    c.merge(user)
    println(c.config.plugins)
    println(c.config.redirects)
}
