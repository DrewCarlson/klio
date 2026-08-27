// A long chain of infix calls: every resolution arm asks for the left
// operand's type, so without a query-scoped memo this is exponential in
// the chain length and never finishes lowering.
fun wide(a: Int): Int {
    var acc = a
    val t0 = acc + 0
    val t1 = acc + 1
    val t2 = acc + 2
    val t3 = acc + 3
    val t4 = acc + 4
    val t5 = acc + 5
    val t6 = acc + 6
    val t7 = acc + 7
    val t8 = acc + 8
    val t9 = acc + 9
    val t10 = acc + 10
    val t11 = acc + 11
    val t12 = acc + 12
    val t13 = acc + 13
    val t14 = acc + 14
    val t15 = acc + 15
    val t16 = acc + 16
    val t17 = acc + 17
    val t18 = acc + 18
    val t19 = acc + 19
    val t20 = acc + 20
    val t21 = acc + 21
    val t22 = acc + 22
    val t23 = acc + 23
    val t24 = acc + 24
    val t25 = acc + 25
    val t26 = acc + 26
    val t27 = acc + 27
    val t28 = acc + 28
    val t29 = acc + 29
    val t30 = acc + 30
    val t31 = acc + 31
    val t32 = acc + 32
    val t33 = acc + 33
    val t34 = acc + 34
    val t35 = acc + 35
    val t36 = acc + 36
    val t37 = acc + 37
    val t38 = acc + 38
    val t39 = acc + 39
    return (t0 and 1) + (t1 and 1) + (t2 and 1) + (t3 and 1) + (t4 and 1) + (t5 and 1) + (t6 and 1) + (t7 and 1) + (t8 and 1) + (t9 and 1) + (t10 and 1) + (t11 and 1) + (t12 and 1) + (t13 and 1) + (t14 and 1) + (t15 and 1) + (t16 and 1) + (t17 and 1) + (t18 and 1) + (t19 and 1) + (t20 and 1) + (t21 and 1) + (t22 and 1) + (t23 and 1) + (t24 and 1) + (t25 and 1) + (t26 and 1) + (t27 and 1) + (t28 and 1) + (t29 and 1) + (t30 and 1) + (t31 and 1) + (t32 and 1) + (t33 and 1) + (t34 and 1) + (t35 and 1) + (t36 and 1) + (t37 and 1) + (t38 and 1) + (t39 and 1)
}

fun main() {
    println("wide=" + wide(3))
    println("wide=" + wide(4))
}
