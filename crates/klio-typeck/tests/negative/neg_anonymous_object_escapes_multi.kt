open class Base
interface I

fun leak() = object : Base(), I {}

fun main() {
    leak()
}
