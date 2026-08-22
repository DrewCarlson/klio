// `ReceiveChannel.toList()` is `buildList { consumeEach(::add) }` — an
// inline builder whose lambda SUSPENDS (each element is received from the
// channel). The inline chain (buildList -> buildListInternal ->
// ArrayList().apply) must run the builder in the caller's coroutine so
// the suspensions park and resume normally; routing the lambda through a
// native host builder dropped the activation at the non-suspending
// boundary ("coroutine suspended across a non-suspending boundary").
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*

fun main() = runTest {
    val channel = produce {
        (1..10).forEach { send(it) }
    }
    val flow = channel.consumeAsFlow().buffer()
    val result = flow.produceIn(this)
    while (!channel.isClosedForReceive) yield()
    println("fused channel is distinct: " + (result !== channel))
    println("collected = " + result.toList())
}
