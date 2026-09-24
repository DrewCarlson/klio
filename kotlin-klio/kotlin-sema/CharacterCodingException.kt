// klio `actual` the sema pipeline uses for the exception the host's UTF-8
// codec raises; see Exceptions.kt. The non-JVM stdlib's shape.

package kotlin.text

public actual open class CharacterCodingException(message: String?) : Exception(message) {
    public actual constructor() : this(null)
}
