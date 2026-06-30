// A capitalized top-level extension function is an ordinary function —
// Kotlin has no capitalization rule at call sites. A bare call to it inside
// another extension on the same receiver dispatches through the implicit
// receiver, exactly as a lowercase name would (ktor's DSL-style
// `HttpResponseValidator { ... }` inside `addDefaultResponseValidation`).
class Config<T> {
    var expectSuccess: Boolean = true
}

class ValidatorConfig {
    var expectSuccess: Boolean = false
}

fun Config<*>.Validator(block: ValidatorConfig.() -> Unit) {
    val cfg = ValidatorConfig()
    cfg.block()
    println("validator installed expectSuccess=" + cfg.expectSuccess)
}

fun Config<*>.addDefault() {
    Validator {
        expectSuccess = this@addDefault.expectSuccess
    }
}

fun main() {
    Config<Int>().addDefault()
}
