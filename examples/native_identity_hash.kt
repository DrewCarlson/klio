// Kotlin/Native's identityHashCode: an object's identity hash holds for its
// whole life and does not follow equality, so two equal objects keep
// hashing apart by identity while their hashCode agrees. Null's is 0.
@file:OptIn(kotlin.experimental.ExperimentalNativeApi::class)

import kotlin.native.identityHashCode

data class Point(val x: Int, val y: Int)

fun main() {
    val a = Point(1, 2)
    val b = Point(1, 2)
    println("equal: ${a == b}, same hashCode: ${a.hashCode() == b.hashCode()}")
    println("stable: ${a.identityHashCode() == a.identityHashCode()}")
    println("apart: ${a.identityHashCode() != b.identityHashCode()}")
    println("non-negative: ${a.identityHashCode() >= 0 && b.identityHashCode() >= 0}")
    val none: Any? = null
    println("null: ${none.identityHashCode()}")
}
