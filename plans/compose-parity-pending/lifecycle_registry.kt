// androidx.lifecycle outside a composition, as Compose Desktop's lifecycle
// libraries run it: a LifecycleRegistry moves its observers through every
// event between two states, an observer added late catches up, and the
// registry's state is a StateFlow. The registry lives on the main
// dispatcher's thread: a call from a Dispatchers.Default thread throws. A
// ViewModel closes its closeables and cancels its viewModelScope when its
// store is cleared.
// Run with: klio run --feature androidx.lifecycle/viewmodel examples/lifecycle_registry.kt
// Pending: moves to examples/, with lifecycle_registry.out (Compose Desktop
// 1.12.0's output, from compose-oracle) as its expected output, once both
// Main dispatcher fixes land (main_immediate_launch.kt, main_from_worker.kt).
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class Screen : LifecycleOwner {
    val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry
}

class Counter : ViewModel() {
    var job: Job? = null

    init {
        addCloseable("resource", AutoCloseable { println("  closeable closed") })
        job = viewModelScope.launch {
            try {
                awaitCancellation()
            } finally {
                println("  viewModelScope cancelled")
            }
        }
    }

    override fun onCleared() {
        println("  onCleared")
    }
}

fun main() = runBlocking(Dispatchers.Main) {
    val screen = Screen()
    screen.lifecycle.addObserver(LifecycleEventObserver { _, event -> println("first: $event") })
    println("state: " + screen.lifecycle.currentState)

    screen.registry.currentState = Lifecycle.State.RESUMED
    println("state: " + screen.lifecycle.currentStateFlow.value)

    screen.lifecycle.addObserver(LifecycleEventObserver { _, event -> println("late: $event") })

    screen.registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
    println("at least STARTED: " + screen.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))

    val offMain = withContext(Dispatchers.Default) {
        try {
            screen.registry.currentState = Lifecycle.State.CREATED
            "no error"
        } catch (e: IllegalStateException) {
            e.message
        }
    }
    println("from another thread: $offMain")
    screen.registry.currentState = Lifecycle.State.CREATED

    screen.registry.currentState = Lifecycle.State.DESTROYED
    println("state: " + screen.lifecycle.currentState)

    val store = ViewModelStore()
    val counter = Counter()
    store.put("counter", counter)
    yieldToScope()
    println("keys: " + store.keys())
    println("clearing the store")
    store.clear()
    yieldToScope()
    println("job cancelled: " + counter.job?.isCancelled)
}

suspend fun yieldToScope() = kotlinx.coroutines.yield()
