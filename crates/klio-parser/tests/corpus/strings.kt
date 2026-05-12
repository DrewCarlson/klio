fun main() {
    val name = "world"
    val greeting = "hello $name, today is ${1 + 1}"
    val raw = """multi
line $name end"""
    println(greeting)
    println(raw)
}
