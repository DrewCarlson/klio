import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    print("drop: ")
    flowOf(1, 2, 3, 4).drop(2).collect { print("$it ") }
    println()

    print("dropWhile: ")
    flowOf(1, 2, 3, 1).dropWhile { it < 3 }.collect { print("$it ") }
    println()

    print("buffer: ")
    flowOf(1, 2, 3).buffer().collect { print("$it ") }
    println()

    print("flowOn: ")
    flowOf(10, 20, 30).flowOn(Dispatchers.Default).collect { print("$it ") }
    println()

    print("onCompletion: ")
    flowOf(1, 2).onCompletion { print("done") }.collect { print("$it ") }
    println()
}
