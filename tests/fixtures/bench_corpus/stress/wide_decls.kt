class V0(val x: Int)
class V1(val x: Int)
class V2(val x: Int)
class V3(val x: Int)
class V4(val x: Int)
class V5(val x: Int)
class V6(val x: Int)
class V7(val x: Int)
class V8(val x: Int)
class V9(val x: Int)

fun f0(x: Int) = x + 0
fun f1(x: Int) = x + 1
fun f2(x: Int) = x + 2
fun f3(x: Int) = x + 3
fun f4(x: Int) = x + 4
fun f5(x: Int) = x + 5
fun f6(x: Int) = x + 6
fun f7(x: Int) = x + 7
fun f8(x: Int) = x + 8
fun f9(x: Int) = x + 9

fun main() {
    var s = 0
    s += f0(1) + f1(1) + f2(1) + f3(1) + f4(1)
    s += f5(1) + f6(1) + f7(1) + f8(1) + f9(1)
    s += V0(1).x + V1(1).x + V2(1).x + V3(1).x + V4(1).x
    s += V5(1).x + V6(1).x + V7(1).x + V8(1).x + V9(1).x
    println(s)
}
