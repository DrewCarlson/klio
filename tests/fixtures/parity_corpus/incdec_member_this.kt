class C { var x = 0; fun bump() { this.x++ } }
fun main() { val c = C(); c.bump(); c.bump(); println(c.x) }
