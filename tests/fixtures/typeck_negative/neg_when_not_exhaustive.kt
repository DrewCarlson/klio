// `when` over a sealed-class subject without `else` is non-exhaustive when
// not every subclass is covered by an `is` branch. Expect T0019.

sealed class Shape
class Circle: Shape()
class Square: Shape()
class Rect: Shape()

fun area(s: Shape): Int = when (s) {
    is Circle -> 1
    is Square -> 2
}
