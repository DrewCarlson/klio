fun main() {
    val ok = Result.success(42)
    val err = Result.failure<Int>(IllegalStateException("boom"))
    println(ok.isSuccess)
    println(ok.isFailure)
    println(err.isSuccess)
    println(err.isFailure)
    println(ok.getOrNull())
    println(err.getOrNull())
    println(ok.exceptionOrNull())
    println(err.exceptionOrNull()?.message)
    println(ok.getOrDefault(0))
    println(err.getOrDefault(99))
}
