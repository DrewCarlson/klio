fun main() {
    val f: (Int) -> Int = { x -> x + 1 }
    val g: () -> String = { -> "hi" }
    println(f is Function1<Int, Int>)
    println(g is Function0<String>)
    println(f is Function<Int>)
    println(g is Function<String>)
    println(f is Any)
}
