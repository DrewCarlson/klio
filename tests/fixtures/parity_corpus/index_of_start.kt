fun main() {
    val u = "http://localhost:8080/path?q=1"
    println(u.indexOf('/'))
    println(u.indexOf('/', 7))
    println(u.indexOf("o"))
    println(u.indexOf("o", 9))
    println(u.indexOf('/', 22))
    println(u.indexOf("LOCAL", 0, ignoreCase = true))
    println("aXbXc".indexOf('X', 2))
    println("abc".indexOf('z', 0))
}
