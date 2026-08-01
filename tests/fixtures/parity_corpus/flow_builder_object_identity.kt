// flowOf/asFlow build their Flow as an anonymous object; a bare
// `collect {}` inside an operator's flow-lambda must reach it through
// the implicit-receiver walk — the collector closure never swallows the
// call, because the object serves `collect` via its interface chain.
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    flowOf(1, 2, 3, 4).drop(2).collect { println("d$it") }
    flowOf(9, 8, 7, 1).dropWhile { it > 7 }.collect { println("w$it") }
    listOf(5, 6).asFlow().collect { println("a$it") }
}
