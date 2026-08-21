private val secret: String = "B-secret"
private const val CODE: Int = 2
class UserB { fun read(): String = secret + "/" + CODE }
