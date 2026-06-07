fun main() {
    val ok = Result.success(10)
    val err = Result.failure<Int>(IllegalArgumentException("bad"))

    val a = ok.fold(
        onSuccess = { v -> "ok=$v" },
        onFailure = { e -> "err=${e.message}" }
    )
    println(a)

    val b = err.fold(
        onSuccess = { v -> "ok=$v" },
        onFailure = { e -> "err=${e.message}" }
    )
    println(b)

    val c = err.getOrElse { 42 }
    println(c)

    val d = ok.getOrElse { 0 }
    println(d)
}
