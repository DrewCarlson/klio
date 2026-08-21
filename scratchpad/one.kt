import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking { println(flowOf(1,2,3).take(2).toList()) }
