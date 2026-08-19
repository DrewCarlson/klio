// Extension properties whose receiver is a companion object, declared as
// members of another class.
//
// A class-scoped extension is in scope only where its owner is a dispatch
// receiver, and a `private` one registers under that owner alone. The receiver
// also reaches the interpreter under the companion's mangled runtime class
// name, while the declaration is written against the source form
// (`Target.Companion`), so resolving one of these means matching the two.
//
// Run with: klio run examples/companion_member_extension.kt

class Target {
    companion object {
        val tag = "T"
    }
}

// Top-level, for contrast: same receiver, different scope.
val Target.Companion.viaTopLevel: String
    get() = "top:" + tag

class Holder {
    private val Target.Companion.viaPrivateMember: String
        get() = "private-member:" + tag

    val Target.Companion.viaPublicMember: String
        get() = "public-member:" + tag

    // The same shape on a builtin's companion, which is how
    // androidx.compose's FloatingPointEqualityTest writes its negative zero.
    private val Float.Companion.negativeZero: Float
        get() = Float.fromBits(0b1 shl 31)

    private fun Float.Companion.makeNegativeZero(): Float = -0.0f

    fun report() {
        println(Target.viaPrivateMember)
        println(Target.viaPublicMember)
        println("negativeZero=${Float.negativeZero}")
        println("bits=0x" + Float.negativeZero.toBits().toUInt().toString(16).padStart(8, '0'))
        // IEEE comparison: negative and positive zero compare equal.
        println("equalsPositiveZero=${Float.negativeZero == 0f}")
        println("equalsItself=${Float.negativeZero == Float.negativeZero}")
        println("viaFunction=${Float.makeNegativeZero()}")
    }
}

fun main() {
    println(Target.viaTopLevel)
    Holder().report()
}
