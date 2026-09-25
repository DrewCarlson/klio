/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copy of ktor-io's posix `PosixException` (errors/PosixErrors.kt).
// Upstream reads the errno constants, `errno` and `strerror` through
// cinterop; here the host supplies them (`src/ktor_client/net.zig`), so each
// constant holds this platform's value. The hierarchy and the messages are
// upstream's.

package io.ktor.utils.io.errors

internal fun __kkio_errno_value(name: String): Int = -1

internal fun __kkio_strerror(errno: Int): String = "Unknown error code: $errno"

internal fun __kkio_last_errno(): Int = 0

private val EBADF = __kkio_errno_value("EBADF")
private val EWOULDBLOCK = __kkio_errno_value("EWOULDBLOCK")
private val EAGAIN = __kkio_errno_value("EAGAIN")
private val EBADMSG = __kkio_errno_value("EBADMSG")
private val EINTR = __kkio_errno_value("EINTR")
private val EINVAL = __kkio_errno_value("EINVAL")
private val EIO = __kkio_errno_value("EIO")
private val ECONNREFUSED = __kkio_errno_value("ECONNREFUSED")
private val ECONNABORTED = __kkio_errno_value("ECONNABORTED")
private val ECONNRESET = __kkio_errno_value("ECONNRESET")
private val ENOTCONN = __kkio_errno_value("ENOTCONN")
private val ETIMEDOUT = __kkio_errno_value("ETIMEDOUT")
private val EOVERFLOW = __kkio_errno_value("EOVERFLOW")
private val ENOMEM = __kkio_errno_value("ENOMEM")
private val ENOTSOCK = __kkio_errno_value("ENOTSOCK")
private val EADDRINUSE = __kkio_errno_value("EADDRINUSE")
private val ENOENT = __kkio_errno_value("ENOENT")

private val KnownPosixErrors = mapOf(
    EBADF to "EBADF",
    EWOULDBLOCK to "EWOULDBLOCK",
    EAGAIN to "EAGAIN",
    EBADMSG to "EBADMSG",
    EINTR to "EINTR",
    EINVAL to "EINVAL",
    EIO to "EIO",
    ECONNREFUSED to "ECONNREFUSED",
    ECONNABORTED to "ECONNABORTED",
    ECONNRESET to "ECONNRESET",
    ENOTCONN to "ENOTCONN",
    ETIMEDOUT to "ETIMEDOUT",
    EOVERFLOW to "EOVERFLOW",
    ENOMEM to "ENOMEM",
    ENOTSOCK to "ENOTSOCK",
    EADDRINUSE to "EADDRINUSE",
    ENOENT to "ENOENT"
)

/**
 * Represents a POSIX error. Could be thrown when a POSIX function returns error code.
 *
 * @property errno error code that caused this exception
 * @property message error text
 */
public sealed class PosixException(public val errno: Int, message: String) : Exception(message) {
    public class BadFileDescriptorException(message: String) : PosixException(EBADF, message)

    public class TryAgainException(errno: Int = EAGAIN, message: String) : PosixException(errno, message)

    public class BadMessageException(message: String) : PosixException(EBADMSG, message)

    public class InterruptedException(message: String) : PosixException(EINTR, message)

    public class InvalidArgumentException(message: String) : PosixException(EINVAL, message)

    public class ConnectionResetException(message: String) : PosixException(ECONNRESET, message)

    public class ConnectionRefusedException(message: String) : PosixException(ECONNREFUSED, message)

    public class ConnectionAbortedException(message: String) : PosixException(ECONNABORTED, message)

    public class NotConnectedException(message: String) : PosixException(ENOTCONN, message)

    public class TimeoutIOException(message: String) : PosixException(ETIMEDOUT, message)

    public class NotSocketException(message: String) : PosixException(ENOTSOCK, message)

    public class AddressAlreadyInUseException(message: String) : PosixException(EADDRINUSE, message)

    public class NoSuchFileException(message: String) : PosixException(ENOENT, message)

    public class OverflowException(message: String) : PosixException(EOVERFLOW, message)

    public class NoMemoryException(message: String) : PosixException(ENOMEM, message)

    public class PosixErrnoException(errno: Int, message: String) : PosixException(errno, "$message ($errno)")

    public companion object {
        /**
         * Create the corresponding instance of PosixException
         * with error message provided by the underlying POSIX implementation.
         *
         * @param errno error code, by default the last one a socket call on this thread recorded
         * @param posixFunctionName optional function name to be included to the exception message
         * @return an instance of [PosixException] or it's subtype
         */
        public fun forErrno(
            errno: Int = __kkio_last_errno(),
            posixFunctionName: String? = null
        ): PosixException {
            val posixConstantName = KnownPosixErrors[errno]
            val posixErrorCodeMessage = when {
                posixConstantName == null -> "POSIX error $errno"
                else -> "$posixConstantName ($errno)"
            }

            val message = when {
                posixFunctionName.isNullOrBlank() -> posixErrorCodeMessage + ": " + posixErrorToString(errno)
                else -> "$posixFunctionName failed, $posixErrorCodeMessage: ${posixErrorToString(errno)}"
            }

            return when (errno) {
                EBADF -> BadFileDescriptorException(message)

                EWOULDBLOCK, EAGAIN -> TryAgainException(errno, message)

                EBADMSG -> BadMessageException(message)

                EINTR -> InterruptedException(message)

                EINVAL -> InvalidArgumentException(message)

                ECONNREFUSED -> ConnectionRefusedException(message)

                ECONNABORTED -> ConnectionAbortedException(message)

                ECONNRESET -> ConnectionResetException(message)

                ENOTCONN -> NotConnectedException(message)

                ETIMEDOUT -> TimeoutIOException(message)

                EOVERFLOW -> OverflowException(message)

                ENOMEM -> NoMemoryException(message)

                ENOTSOCK -> NotSocketException(message)

                EADDRINUSE -> AddressAlreadyInUseException(message)

                ENOENT -> NoSuchFileException(message)

                else -> PosixErrnoException(errno, message)
            }
        }
    }
}

internal fun PosixException.wrapIO(): kotlinx.io.IOException =
    kotlinx.io.IOException("I/O operation failed due to posix error code $errno", this)

private fun posixErrorToString(errno: Int): String = __kkio_strerror(errno)
