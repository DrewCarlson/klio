package androidx.annotation

/**
 * Marks a declaration whose visibility is relaxed so tests can reach it.
 * [otherwise] names the visibility it would have without the tests.
 */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
public annotation class VisibleForTesting(val otherwise: Int = PRIVATE) {
    public companion object {
        public const val PRIVATE: Int = 2
        public const val PACKAGE_PRIVATE: Int = 3
        public const val PROTECTED: Int = 4
        public const val NONE: Int = 5
    }
}
