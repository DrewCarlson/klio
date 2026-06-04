fun main() {
    println("42".toShort())
    println("-7".toByte())
    println("100".toShort() + 1)
    println("3.5".toFloat())
    println("3.5".toFloat() + 0.5f)
    println("1e3".toFloat())
    println("x".toFloatOrNull())
    println("2.25".toFloatOrNull())

    println('\n'.isISOControl())
    println(' '.isISOControl())
    println('a'.isISOControl())
    println('\u007F'.isISOControl())
    println('\u0085'.isISOControl())
}
