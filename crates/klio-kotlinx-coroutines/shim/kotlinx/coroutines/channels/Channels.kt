// kotlinx.coroutines.channels — the channels subpackage. Upstream
// places Channel and its companions here; the klio shim implements
// them in kotlinx.coroutines, so this file re-exports that surface
// so `import kotlinx.coroutines.channels.Channel` resolves while
// `import kotlinx.coroutines.*` keeps working too.

package kotlinx.coroutines.channels

import kotlinx.coroutines.Channel as CoChannel
import kotlinx.coroutines.ChannelIterator as CoChannelIterator
import kotlinx.coroutines.ClosedReceiveChannelException as CoClosedReceive
import kotlinx.coroutines.ClosedSendChannelException as CoClosedSend

typealias Channel<T> = CoChannel<T>
typealias ChannelIterator<T> = CoChannelIterator<T>
typealias ClosedReceiveChannelException = CoClosedReceive
typealias ClosedSendChannelException = CoClosedSend

fun <T> Channel(): CoChannel<T> = kotlinx.coroutines.Channel()
fun <T> Channel(capacity: Int): CoChannel<T> = kotlinx.coroutines.Channel(capacity)
