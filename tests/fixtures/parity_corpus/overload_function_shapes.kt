// Runtime overload dispatch over a function-shape pair: the lambda's
// declared parameter type selects the overload. kotlinc-jvm rejects this
// pair under JVM erasure (platform declaration clash); kotlinc-native
// 2.3.10 accepts it and resolves by the full declared type, so the native
// compiler is the oracle here.
fun call(f: (Int) -> Int): String = "call((Int)->Int)"
fun call(f: (String) -> String): String = "call((String)->String)"

fun main() {
    println(call({ s: String -> s + "!" }))
    println(call({ n: Int -> n + 1 }))
}
