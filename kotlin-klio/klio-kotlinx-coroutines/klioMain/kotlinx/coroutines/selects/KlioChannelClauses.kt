// Native-channel select clauses.
//
// klio's `Channel` is a native FIFO (a synthesised `KlioChannel`
// instance), not the upstream `BufferedChannel`, so it does not carry the
// upstream `onReceive` / `onSend` / `onReceiveCatching` select clauses.
// These extensions supply them, bridging the upstream
// `SelectImplementation` to the native channel through host intrinsics that
// poll the channel and register/remove the select instance as a waiter. A
// send/receive/close on the native channel offers the rendezvous to a
// registered select by calling its `trySelect`.

package kotlinx.coroutines.selects

import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.ChannelResult
import kotlinx.coroutines.internal.callUndeliveredElement

// Host intrinsics implemented in `src/kotlinx_coroutines`.
internal fun __kxco_chanSelectAddReceiver(channel: Any, select: Any) {}
internal fun __kxco_chanSelectRemoveReceiver(channel: Any, select: Any) {}
internal fun __kxco_chanSelectAddSender(channel: Any, select: Any) {}
// Returns whether a STILL-PARKED waiter was removed — its element was never
// sent, so the caller reports it to `onUndeliveredElement`.
internal fun __kxco_chanSelectRemoveSender(channel: Any, select: Any): Boolean = false
internal fun __kxco_chanUndeliveredHandler(channel: Any): Any? = null
// Returns 0 = took a value (written into holder.__value__),
// 1 = closed, 2 = not ready.
internal fun __kxco_chanSelectPollReceive(channel: Any, holder: KlioClauseHolder): Int = 2
// Returns 0 = sent, 1 = closed, 2 = full.
internal fun __kxco_chanSelectPollSend(channel: Any, value: Any?): Int = 2
internal fun __kxco_chanCloseCause(channel: Any): Throwable? = null

// A tiny mutable cell the receive poll writes the taken value into (the
// value may be `null`, so a return value cannot signal "got" by itself).
internal class KlioClauseHolder {
    @JvmField var value: Any? = null
}

// Closed sentinel handed to `trySelect` by the native close path; the
// process functions below re-poll the channel and observe the close.
private val KLIO_CLOSED = Any()

// ---- onReceive -------------------------------------------------------

public val <E> ReceiveChannel<E>.onReceive: SelectClause1<E>
    get() = SelectClause1Impl(
        clauseObject = this,
        regFunc = ::klioRegReceive as RegistrationFunction,
        processResFunc = ::klioProcessReceive as ProcessResultFunction,
        onCancellationConstructor = klioReceiveCancellationConstructor(this)
    )

@Suppress("UNUSED_PARAMETER")
private fun klioRegReceive(clauseObject: Any, select: SelectInstance<*>, ignored: Any?) {
    val holder = KlioClauseHolder()
    when (__kxco_chanSelectPollReceive(clauseObject, holder)) {
        0 -> select.selectInRegistrationPhase(holder)
        1 -> select.selectInRegistrationPhase(KLIO_CLOSED)
        else -> {
            __kxco_chanSelectAddReceiver(clauseObject, select)
            select.disposeOnCompletion(DisposableHandle {
                __kxco_chanSelectRemoveReceiver(clauseObject, select)
            })
        }
    }
}

@Suppress("UNCHECKED_CAST")
private fun klioProcessReceive(clauseObject: Any, ignored: Any?, result: Any?): Any? {
    // A registration-phase poll passes the value in a holder; an offering send
    // that woke this parked select passes the value itself as the trySelect
    // result (a rendezvous hands the value straight through, so it is not in
    // the channel to re-poll).
    if (result is KlioClauseHolder) return result.value
    if (result === KLIO_CLOSED) throw closedReceiveException(clauseObject)
    // The native close path wakes a parked select with a null marker; a real
    // received value is never null on a still-open channel, so a null result
    // on a closed-for-receive channel is the close, not a value.
    if (result == null && (clauseObject as ReceiveChannel<*>).isClosedForReceive)
        throw closedReceiveException(clauseObject)
    return result
}

// ---- onReceiveCatching ----------------------------------------------

public val <E> ReceiveChannel<E>.onReceiveCatching: SelectClause1<ChannelResult<E>>
    get() = SelectClause1Impl(
        clauseObject = this,
        regFunc = ::klioRegReceive as RegistrationFunction,
        processResFunc = ::klioProcessReceiveCatching as ProcessResultFunction,
        onCancellationConstructor = klioReceiveCancellationConstructor(this)
    )

@Suppress("UNCHECKED_CAST")
private fun klioProcessReceiveCatching(clauseObject: Any, ignored: Any?, result: Any?): Any? {
    if (result is KlioClauseHolder) return ChannelResult.success(result.value as Any?)
    if (result === KLIO_CLOSED) return ChannelResult.closed<Any?>(__kxco_chanCloseCause(clauseObject))
    if (result == null && (clauseObject as ReceiveChannel<*>).isClosedForReceive)
        return ChannelResult.closed<Any?>(__kxco_chanCloseCause(clauseObject))
    return ChannelResult.success(result)
}

// ---- onSend ----------------------------------------------------------

public val <E> SendChannel<E>.onSend: SelectClause2<E, SendChannel<E>>
    get() = SelectClause2Impl(
        clauseObject = this,
        regFunc = ::klioRegSend as RegistrationFunction,
        processResFunc = ::klioProcessSend as ProcessResultFunction
    )

@Suppress("UNUSED_PARAMETER", "UNCHECKED_CAST")
private fun klioRegSend(clauseObject: Any, select: SelectInstance<*>, param: Any?) {
    when (__kxco_chanSelectPollSend(clauseObject, param)) {
        0 -> select.selectInRegistrationPhase(Unit)
        1 -> select.selectInRegistrationPhase(KLIO_CLOSED)
        else -> {
            __kxco_chanSelectAddSender(clauseObject, select)
            val context = select.context
            select.disposeOnCompletion(DisposableHandle {
                // A waiter still parked at disposal never sent its element
                // (the select was cancelled, or another clause won): report
                // it undelivered, exactly as the channel's own sender-queue
                // cancellation does.
                if (__kxco_chanSelectRemoveSender(clauseObject, select)) {
                    val h = __kxco_chanUndeliveredHandler(clauseObject)
                    if (h != null) {
                        (h as (Any?) -> Unit).callUndeliveredElement(param, context)
                    }
                }
            })
        }
    }
}

@Suppress("UNUSED_PARAMETER")
private fun klioProcessSend(clauseObject: Any, param: Any?, result: Any?): Any? {
    if (result === KLIO_CLOSED) throw closedSendException(clauseObject)
    // Either selected during registration (the value was already placed) or
    // woken by a receive freeing a slot: place the value now.
    if (result !== Unit) {
        when (__kxco_chanSelectPollSend(clauseObject, param)) {
            1 -> throw closedSendException(clauseObject)
            else -> {}
        }
    }
    return clauseObject
}

// The action a delivered-then-cancelled `onReceive` runs: the value already
// handed to the select is undelivered when its coroutine is cancelled before
// dispatch. Mirrors `BufferedChannel.onUndeliveredElementReceiveCancellationConstructor`.
@Suppress("UNCHECKED_CAST")
private fun klioReceiveCancellationConstructor(channel: Any): OnCancellationConstructor? {
    val h = __kxco_chanUndeliveredHandler(channel) ?: return null
    return { select: SelectInstance<*>, _: Any?, internalResult: Any? ->
        { _, _, _ ->
            val element: Any? = if (internalResult is KlioClauseHolder) internalResult.value else internalResult
            if (internalResult !== KLIO_CLOSED) {
                (h as (Any?) -> Unit).callUndeliveredElement(element, select.context)
            }
        }
    }
}

private fun closedReceiveException(channel: Any): Throwable =
    __kxco_chanCloseCause(channel)
        ?: kotlinx.coroutines.channels.ClosedReceiveChannelException("Channel was closed")

private fun closedSendException(channel: Any): Throwable =
    __kxco_chanCloseCause(channel)
        ?: kotlinx.coroutines.channels.ClosedSendChannelException("Channel was closed")
