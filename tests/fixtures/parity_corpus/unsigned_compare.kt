fun main() {
 val a = 1u
 val b = 5u
 println(a < b)
 println(a <= b)
 println(a > b)
 println(a >= b)
 println(maxOf(1u, 5u))
 println(minOf(1u, 5u))
 println(maxOf(3u, 2u))
 val x = 10uL
 val y = 3uL
 println(x > y)
 println(maxOf(10uL, 3uL))
 println(minOf(10uL, 3uL))
 println(listOf(3u, 1u, 4u, 1u, 5u).sorted())
 println(listOf(3u, 1u, 4u).maxOrNull())
}
