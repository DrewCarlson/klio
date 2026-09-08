// A top-level `const val` with an unsigned literal keeps its unsigned type
// when materialized as a global, so a member call whose receiver reads it
// (`oneVal.plus(twoVal)`) computes in the unsigned domain like kotlinc.
const val zeroVal = 0u
const val oneVal = 1u
const val twoVal = 2u
const val bigUInt = 4_000_000_000u
const val oneUL = 1uL
const val twoUL = 2uL

const val sumUInt = oneVal.plus(twoVal)
const val prodUInt = twoVal.times(twoVal)
const val sumUL = oneUL.plus(twoUL)
const val wrap = bigUInt.plus(bigUInt)

fun main() {
    println(sumUInt)
    println(prodUInt)
    println(sumUL)
    println(wrap)
    println(oneVal.plus(twoVal))
    println(twoVal.minus(oneVal))
    println(oneVal < twoVal)
    println(zeroVal.compareTo(oneVal))
}
