// `yield()` reschedules through the coroutine's DISPATCHER, so a task already
// queued runs before the yielding coroutine resumes. klio bound `yield` to a
// native intrinsic that rescheduled on its own pump instead, which is not the
// dispatcher: the yielding body ran on ahead of the tasks it was yielding TO.
//
// A property REFERENCE is a `(T) -> R` — `compareValuesBy` took only lambdas,
// which is how the test scheduler's event heap failed to sort.

import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

class Event(val time: Long, val count: Long)

fun main() = runBlocking {
    val order = mutableListOf<String>()

    val child = launch { order.add("child") }
    order.add("parent-before-yield")
    yield()
    order.add("parent-after-yield")

    println(order.joinToString(","))
    println("child completed at resume: ${child.isCompleted}")

    // Key selectors as property references, the shape the scheduler orders by.
    println("byTime:  " + compareValuesBy(Event(1, 9), Event(2, 0), Event::time))
    println("byCount: " + compareValuesBy(Event(1, 5), Event(1, 5), Event::time, Event::count))
}
