import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking

fun make(): Flow<Int> {
    val flow = flowOf(9)          // no coroutine receiver in scope here
    return flow { emit(1); emit(2) }
}

fun main() = runBlocking { println(make().toList()) }
