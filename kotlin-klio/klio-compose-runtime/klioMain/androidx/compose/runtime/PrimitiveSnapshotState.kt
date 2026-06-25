// Primitive specializations of mutable state — same observer-backed model as
// mutableStateOf, but exposing an unboxed accessor (intValue/longValue/…). The
// generic `by` delegation operators (from SnapshotState.kt) apply since each is a
// MutableState of its boxed type.

package androidx.compose.runtime

// ----- Int -----

public interface IntState : State<Int> {
    public val intValue: Int
    override val value: Int get() = intValue
}

public interface MutableIntState : IntState, MutableState<Int> {
    public override var intValue: Int
    override var value: Int
}

internal class MutableIntStateImpl(value: Int) : MutableIntState {
    private var backing: Int = value
    override var intValue: Int
        get() { StateObservation.notifyRead(this); return backing }
        set(v) { if (backing != v) { backing = v; StateObservation.notifyWrite(this) } }
    override var value: Int
        get() = intValue
        set(v) { intValue = v }
    override fun component1(): Int = intValue
    override fun component2(): (Int) -> Unit = { intValue = it }
    override fun toString(): String = "MutableIntState(value=$backing)"
}

public fun mutableIntStateOf(value: Int): MutableIntState = MutableIntStateImpl(value)

// ----- Long -----

public interface LongState : State<Long> {
    public val longValue: Long
    override val value: Long get() = longValue
}

public interface MutableLongState : LongState, MutableState<Long> {
    public override var longValue: Long
    override var value: Long
}

internal class MutableLongStateImpl(value: Long) : MutableLongState {
    private var backing: Long = value
    override var longValue: Long
        get() { StateObservation.notifyRead(this); return backing }
        set(v) { if (backing != v) { backing = v; StateObservation.notifyWrite(this) } }
    override var value: Long
        get() = longValue
        set(v) { longValue = v }
    override fun component1(): Long = longValue
    override fun component2(): (Long) -> Unit = { longValue = it }
    override fun toString(): String = "MutableLongState(value=$backing)"
}

public fun mutableLongStateOf(value: Long): MutableLongState = MutableLongStateImpl(value)

// ----- Float -----

public interface FloatState : State<Float> {
    public val floatValue: Float
    override val value: Float get() = floatValue
}

public interface MutableFloatState : FloatState, MutableState<Float> {
    public override var floatValue: Float
    override var value: Float
}

internal class MutableFloatStateImpl(value: Float) : MutableFloatState {
    private var backing: Float = value
    override var floatValue: Float
        get() { StateObservation.notifyRead(this); return backing }
        set(v) { if (backing != v) { backing = v; StateObservation.notifyWrite(this) } }
    override var value: Float
        get() = floatValue
        set(v) { floatValue = v }
    override fun component1(): Float = floatValue
    override fun component2(): (Float) -> Unit = { floatValue = it }
    override fun toString(): String = "MutableFloatState(value=$backing)"
}

public fun mutableFloatStateOf(value: Float): MutableFloatState = MutableFloatStateImpl(value)

// ----- Double -----

public interface DoubleState : State<Double> {
    public val doubleValue: Double
    override val value: Double get() = doubleValue
}

public interface MutableDoubleState : DoubleState, MutableState<Double> {
    public override var doubleValue: Double
    override var value: Double
}

internal class MutableDoubleStateImpl(value: Double) : MutableDoubleState {
    private var backing: Double = value
    override var doubleValue: Double
        get() { StateObservation.notifyRead(this); return backing }
        set(v) { if (backing != v) { backing = v; StateObservation.notifyWrite(this) } }
    override var value: Double
        get() = doubleValue
        set(v) { doubleValue = v }
    override fun component1(): Double = doubleValue
    override fun component2(): (Double) -> Unit = { doubleValue = it }
    override fun toString(): String = "MutableDoubleState(value=$backing)"
}

public fun mutableDoubleStateOf(value: Double): MutableDoubleState = MutableDoubleStateImpl(value)
