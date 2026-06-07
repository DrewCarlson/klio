// numeric fidelity: conversion methods carry semantic meaning, not
// no-ops. Saturating float-to-int for out-of-range, NaN-to-0.

fun main() {
    val i = 5
    println(i.toLong())
    println(i.toDouble())
    println(i.toFloat())
    println(i.toByte().toInt())
    println(i.toShort().toInt())

    val l = 5000000000L
    println(l.toInt())
    println(l.toDouble())
    println(l.toFloat())
    println(l.toShort().toInt())

    val d = 1.7
    println(d.toInt())
    println(d.toLong())
    println(d.toFloat())

    val f = 2.7f
    println(f.toInt())
    println(f.toLong())
    println(f.toDouble())

    // Truncation for negative values: -1.7.toInt() == -1
    val neg = -1.7
    println(neg.toInt())

    // Byte/Short wraparound on narrowing.
    println(257.toByte().toInt())
    println(128.toByte().toInt())
    println(40000.toShort().toInt())
}
