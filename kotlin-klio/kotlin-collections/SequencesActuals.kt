// klio actual for the `internal expect class ConstrainedOnceSequence`
// declared in upstream commonMain `kotlin/SequencesH.kt`. Single-threaded
// interpreter: the plain nulling ref matches the JS/Wasm actuals.

package kotlin.sequences

internal actual class ConstrainedOnceSequence<T>(sequence: Sequence<T>) : Sequence<T> {
    private var sequenceRef: Sequence<T>? = sequence

    actual override fun iterator(): Iterator<T> {
        val sequence = sequenceRef ?: throw IllegalStateException("This sequence can be consumed only once.")
        sequenceRef = null
        return sequence.iterator()
    }
}
