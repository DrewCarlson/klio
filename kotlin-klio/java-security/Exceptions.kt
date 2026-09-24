/*
 * The `java.security` exceptions a message digest raises: asking for an
 * algorithm the platform does not provide is a `NoSuchAlgorithmException`.
 */
package java.security

public open class GeneralSecurityException : Exception {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class NoSuchAlgorithmException : GeneralSecurityException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}
