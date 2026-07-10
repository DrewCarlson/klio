// Top-level `const val`s inline at reference sites (Kotlin compile-time
// constants) — including inside function bodies and under unary minus.
const val GroupWidth = 8
const val AllEmpty = -0x7f7f7f7f_7f7f7f80L
const val Sentinel: Long = 0b11111111L
const val Name = "klio"
const val Enabled = true

fun describe(): String {
    val mask = AllEmpty and (0xffL shl ((GroupWidth - 1) * 8))
    return "$Name width=$GroupWidth sentinel=$Sentinel enabled=$Enabled mask=0x${mask.toULong().toString(16)}"
}

fun main() {
    println(describe())
}
