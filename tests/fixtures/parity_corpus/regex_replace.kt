fun main() {
    println("a1b2c3".replace(Regex("[0-9]")) { "<${it.value}>" })
    println("a1b2".replaceFirst(Regex("[0-9]"), "X"))
    println("hello world".replace(Regex("o"), "0"))
    println("2023-01-15".replace(Regex("(\\d+)-(\\d+)-(\\d+)"), "$3/$2/$1"))
    println(Regex("[aeiou]").replace("banana") { it.value.uppercase() })
    println("foo bar baz".replaceFirst(Regex("ba(.)"), "X$1"))
    println(Regex("\\d+").replace("a1b22c333") { (it.value.toInt() * 2).toString() })
    println("CamelCase".replace(Regex("([A-Z])"), " $1").trim())
}
