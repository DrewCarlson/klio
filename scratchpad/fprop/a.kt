private val secret: String = "A-secret"
private const val CODE: Int = 1
class UserA { fun read(): String = secret + "/" + CODE }
