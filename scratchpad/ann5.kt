class T {
    sealed class Result { class OK(val s: String): Result() }
    abstract class AbstractResult
    object ObjectResult
    class HolderA(val r: Result)
}
fun main() {
    println(T.Result::class.qualifiedName)
    println(T.HolderA::class.qualifiedName)
    println(T.AbstractResult::class.qualifiedName)
    println(T.ObjectResult::class.qualifiedName)
}
