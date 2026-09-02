package kotlinx.serialization.json.internal

import kotlinx.serialization.InternalSerializationApi

@InternalSerializationApi
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY_GETTER,
    AnnotationTarget.PROPERTY_SETTER,
    AnnotationTarget.FIELD,
    AnnotationTarget.VALUE_PARAMETER,
    AnnotationTarget.LOCAL_VARIABLE,
    AnnotationTarget.ANNOTATION_CLASS
)
public actual annotation class FormatLanguage(
    public actual val value: String,
    public actual val prefix: String,
    public actual val suffix: String,
)
