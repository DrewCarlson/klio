open class Base {
    var x: Int = 1
    fun setBase(v: Int) { x = v }   // writes Base.x
    fun getBase(): Int = x          // reads Base.x
}
class Sub : Base() {
    var x: Int = 2                  // shadows Base.x (separate storage)
    fun setSub(v: Int) { x = v }    // writes Sub.x
    fun getSub(): Int = x           // reads Sub.x
}
fun main() {
    val s = Sub()
    s.setBase(100)   // Base.x = 100
    s.setSub(200)    // Sub.x  = 200
    println("getBase=" + s.getBase())  // expected 100
    println("getSub="  + s.getSub())   // expected 200
}
