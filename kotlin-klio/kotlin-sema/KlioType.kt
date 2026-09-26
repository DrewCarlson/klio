// klio's KType: the type a reified type parameter stands for at run time,
// which `typeOf<T>()` returns. Code lowered from sema builds one for each
// reified type argument through `__klio_type` and `__klio_projection`.

package kotlin.reflect

@PublishedApi
internal class KlioType(
    override val classifier: KClassifier?,
    override val arguments: List<KTypeProjection>,
    override val isMarkedNullable: Boolean,
) : KType {
    override fun equals(other: Any?): Boolean =
        other is KlioType && classifier == other.classifier && arguments == other.arguments &&
            isMarkedNullable == other.isMarkedNullable

    override fun hashCode(): Int =
        ((classifier?.hashCode() ?: 0) * 31 + arguments.hashCode()) * 31 + isMarkedNullable.hashCode()

    override fun toString(): String {
        val head = (classifier as? KClass<*>)?.qualifiedName ?: classifier.toString()
        val args = if (arguments.isEmpty()) "" else arguments.joinToString(", ", "<", ">")
        return head + args + (if (isMarkedNullable) "?" else "")
    }
}

@PublishedApi
internal fun __klio_type(classifier: KClassifier?, nullable: Boolean, vararg arguments: KTypeProjection): KType =
    KlioType(classifier, arguments.asList(), nullable)

// A projection of `type`: `variance` 0 is invariant, 1 `in`, 2 `out`, and
// anything else a star.
@PublishedApi
internal fun __klio_projection(variance: Int, type: KType?): KTypeProjection = when (variance) {
    0 -> KTypeProjection.invariant(type!!)
    1 -> KTypeProjection.contravariant(type!!)
    2 -> KTypeProjection.covariant(type!!)
    else -> KTypeProjection.STAR
}

// The class a reified type parameter's run-time type names (`T::class`).
@PublishedApi
internal fun __klio_typeClass(type: KType): KClass<*> = type.classifier as KClass<*>

// `type` marked nullable: what `T?` stands for when `T` is `type`.
@PublishedApi
internal fun __klio_typeNullable(type: KType): KType =
    if (type.isMarkedNullable) type else KlioType(type.classifier, type.arguments, true)
