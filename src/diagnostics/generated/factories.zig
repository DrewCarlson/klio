//! Auto-generated diagnostic factories mined from the upstream Kotlin compiler.
//! Do not edit by hand.

const diag = @import("../diagnostics.zig");
const DiagnosticFactory = diag.DiagnosticFactory;
const Severity = diag.Severity;

pub const ABBREVIATED_NOTHING_PROPERTY_TYPE = DiagnosticFactory{
    .name = "ABBREVIATED_NOTHING_PROPERTY_TYPE",
    .default_severity = .Error,
    .message_template = "'Nothing' property type cannot be specified with type alias.",
};
pub const ABBREVIATED_NOTHING_RETURN_TYPE = DiagnosticFactory{
    .name = "ABBREVIATED_NOTHING_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "'Nothing' return type cannot be specified with type alias.",
};
pub const ABSENCE_OF_PRIMARY_CONSTRUCTOR_FOR_VALUE_CLASS = DiagnosticFactory{
    .name = "ABSENCE_OF_PRIMARY_CONSTRUCTOR_FOR_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "Primary constructor is required for value classes.",
};
pub const ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED = DiagnosticFactory{
    .name = "ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED",
    .default_severity = .Error,
    .message_template = "ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED",
};
pub const ABSTRACT_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "ABSTRACT_DELEGATED_PROPERTY",
    .default_severity = .Error,
    .message_template = "Delegated property cannot be abstract.",
};
pub const ABSTRACT_FUNCTION_IN_NON_ABSTRACT_CLASS = DiagnosticFactory{
    .name = "ABSTRACT_FUNCTION_IN_NON_ABSTRACT_CLASS",
    .default_severity = .Error,
    .message_template = "ABSTRACT_FUNCTION_IN_NON_ABSTRACT_CLASS",
};
pub const ABSTRACT_FUNCTION_WITH_BODY = DiagnosticFactory{
    .name = "ABSTRACT_FUNCTION_WITH_BODY",
    .default_severity = .Error,
    .message_template = "Function ''{0}'' with a body cannot be abstract.",
};
pub const ABSTRACT_MEMBER_NOT_IMPLEMENTED = DiagnosticFactory{
    .name = "ABSTRACT_MEMBER_NOT_IMPLEMENTED",
    .default_severity = .Error,
    .message_template = "ABSTRACT_MEMBER_NOT_IMPLEMENTED",
};
pub const ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY = DiagnosticFactory{
    .name = "ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY",
    .default_severity = .Error,
    .message_template = "ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY",
};
pub const ABSTRACT_PROPERTY_IN_NON_ABSTRACT_CLASS = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_IN_NON_ABSTRACT_CLASS",
    .default_severity = .Error,
    .message_template = "ABSTRACT_PROPERTY_IN_NON_ABSTRACT_CLASS",
};
pub const ABSTRACT_PROPERTY_IN_PRIMARY_CONSTRUCTOR_PARAMETERS = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_IN_PRIMARY_CONSTRUCTOR_PARAMETERS",
    .default_severity = .Error,
    .message_template = "Property in primary constructor cannot be declared as abstract.",
};
pub const ABSTRACT_PROPERTY_WITHOUT_TYPE = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_WITHOUT_TYPE",
    .default_severity = .Error,
    .message_template = "ABSTRACT_PROPERTY_WITHOUT_TYPE",
};
pub const ABSTRACT_PROPERTY_WITH_GETTER = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_WITH_GETTER",
    .default_severity = .Error,
    .message_template = "Property with getter implementation cannot be abstract.",
};
pub const ABSTRACT_PROPERTY_WITH_INITIALIZER = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_WITH_INITIALIZER",
    .default_severity = .Error,
    .message_template = "Property with initializer cannot be abstract.",
};
pub const ABSTRACT_PROPERTY_WITH_SETTER = DiagnosticFactory{
    .name = "ABSTRACT_PROPERTY_WITH_SETTER",
    .default_severity = .Error,
    .message_template = "Property with setter implementation cannot be abstract.",
};
pub const ABSTRACT_SUPER_CALL = DiagnosticFactory{
    .name = "ABSTRACT_SUPER_CALL",
    .default_severity = .Error,
    .message_template = "Abstract member cannot be accessed directly.",
};
pub const ABSTRACT_SUPER_CALL_WARNING = DiagnosticFactory{
    .name = "ABSTRACT_SUPER_CALL_WARNING",
    .default_severity = .Warning,
    .message_template = "ABSTRACT_SUPER_CALL_WARNING",
};
pub const ACCESSOR_FOR_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "ACCESSOR_FOR_DELEGATED_PROPERTY",
    .default_severity = .Error,
    .message_template = "Delegated property cannot have accessors with non-default implementations.",
};
pub const ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT = DiagnosticFactory{
    .name = "ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT",
    .default_severity = .Warning,
    .message_template = "ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT",
};
pub const ACTUAL_FUNCTION_WITH_DEFAULT_ARGUMENTS = DiagnosticFactory{
    .name = "ACTUAL_FUNCTION_WITH_DEFAULT_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "ACTUAL_FUNCTION_WITH_DEFAULT_ARGUMENTS",
};
pub const ACTUAL_IGNORABILITY_NOT_MATCH_EXPECT = DiagnosticFactory{
    .name = "ACTUAL_IGNORABILITY_NOT_MATCH_EXPECT",
    .default_severity = .Warning,
    .message_template = "ACTUAL_IGNORABILITY_NOT_MATCH_EXPECT",
};
pub const ACTUAL_MISSING = DiagnosticFactory{
    .name = "ACTUAL_MISSING",
    .default_severity = .Error,
    .message_template = "Declaration must be marked with 'actual'.",
};
pub const ACTUAL_TYPEALIAS_TO_SPECIAL_ANNOTATION = DiagnosticFactory{
    .name = "ACTUAL_TYPEALIAS_TO_SPECIAL_ANNOTATION",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPEALIAS_TO_SPECIAL_ANNOTATION",
};
pub const ACTUAL_TYPE_ALIAS_NOT_TO_CLASS = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_NOT_TO_CLASS",
    .default_severity = .Error,
    .message_template = "Right-hand side of actual type alias must be a class, not another type alias.",
};
pub const ACTUAL_TYPE_ALIAS_TO_CLASS_WITH_DECLARATION_SITE_VARIANCE = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_TO_CLASS_WITH_DECLARATION_SITE_VARIANCE",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPE_ALIAS_TO_CLASS_WITH_DECLARATION_SITE_VARIANCE",
};
pub const ACTUAL_TYPE_ALIAS_TO_NOTHING = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_TO_NOTHING",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPE_ALIAS_TO_NOTHING",
};
pub const ACTUAL_TYPE_ALIAS_TO_NULLABLE_TYPE = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_TO_NULLABLE_TYPE",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPE_ALIAS_TO_NULLABLE_TYPE",
};
pub const ACTUAL_TYPE_ALIAS_WITH_COMPLEX_SUBSTITUTION = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_WITH_COMPLEX_SUBSTITUTION",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPE_ALIAS_WITH_COMPLEX_SUBSTITUTION",
};
pub const ACTUAL_TYPE_ALIAS_WITH_USE_SITE_VARIANCE = DiagnosticFactory{
    .name = "ACTUAL_TYPE_ALIAS_WITH_USE_SITE_VARIANCE",
    .default_severity = .Error,
    .message_template = "ACTUAL_TYPE_ALIAS_WITH_USE_SITE_VARIANCE",
};
pub const ACTUAL_WITHOUT_EXPECT = DiagnosticFactory{
    .name = "ACTUAL_WITHOUT_EXPECT",
    .default_severity = .Error,
    .message_template = "ACTUAL_WITHOUT_EXPECT",
};
pub const ADAPTED_CALLABLE_REFERENCE_AGAINST_REFLECTION_TYPE = DiagnosticFactory{
    .name = "ADAPTED_CALLABLE_REFERENCE_AGAINST_REFLECTION_TYPE",
    .default_severity = .Error,
    .message_template = "ADAPTED_CALLABLE_REFERENCE_AGAINST_REFLECTION_TYPE",
};
pub const AMBIGUOUS_ALTERED_ASSIGN = DiagnosticFactory{
    .name = "AMBIGUOUS_ALTERED_ASSIGN",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_ALTERED_ASSIGN",
};
pub const AMBIGUOUS_ANNOTATION_ARGUMENT = DiagnosticFactory{
    .name = "AMBIGUOUS_ANNOTATION_ARGUMENT",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_ANNOTATION_ARGUMENT",
};
pub const AMBIGUOUS_ANONYMOUS_TYPE_INFERRED = DiagnosticFactory{
    .name = "AMBIGUOUS_ANONYMOUS_TYPE_INFERRED",
    .default_severity = .Error,
    .message_template = "Right-hand side has an anonymous type. Specify the type explicitly.",
};
pub const AMBIGUOUS_CALL_WITH_IMPLICIT_CONTEXT_RECEIVER = DiagnosticFactory{
    .name = "AMBIGUOUS_CALL_WITH_IMPLICIT_CONTEXT_RECEIVER",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_CALL_WITH_IMPLICIT_CONTEXT_RECEIVER",
};
pub const AMBIGUOUS_CONTEXT_ARGUMENT = DiagnosticFactory{
    .name = "AMBIGUOUS_CONTEXT_ARGUMENT",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_CONTEXT_ARGUMENT",
};
pub const AMBIGUOUS_EXPECTS = DiagnosticFactory{
    .name = "AMBIGUOUS_EXPECTS",
    .default_severity = .Error,
    .message_template = "''{0}'' has several compatible expect declarations in modules {1}.",
};
pub const AMBIGUOUS_FUNCTION_TYPE_KIND = DiagnosticFactory{
    .name = "AMBIGUOUS_FUNCTION_TYPE_KIND",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_FUNCTION_TYPE_KIND",
};
pub const AMBIGUOUS_LABEL = DiagnosticFactory{
    .name = "AMBIGUOUS_LABEL",
    .default_severity = .Error,
    .message_template = "Ambiguous label.",
};
pub const AMBIGUOUS_SUPER = DiagnosticFactory{
    .name = "AMBIGUOUS_SUPER",
    .default_severity = .Error,
    .message_template = "AMBIGUOUS_SUPER",
};
pub const ANNOTATIONS_ON_BLOCK_LEVEL_EXPRESSION_ON_THE_SAME_LINE = DiagnosticFactory{
    .name = "ANNOTATIONS_ON_BLOCK_LEVEL_EXPRESSION_ON_THE_SAME_LINE",
    .default_severity = .Warning,
    .message_template = "ANNOTATIONS_ON_BLOCK_LEVEL_EXPRESSION_ON_THE_SAME_LINE",
};
pub const ANNOTATION_ARGUMENT_KCLASS_LITERAL_OF_TYPE_PARAMETER_ERROR = DiagnosticFactory{
    .name = "ANNOTATION_ARGUMENT_KCLASS_LITERAL_OF_TYPE_PARAMETER_ERROR",
    .default_severity = .Error,
    .message_template = "ANNOTATION_ARGUMENT_KCLASS_LITERAL_OF_TYPE_PARAMETER_ERROR",
};
pub const ANNOTATION_ARGUMENT_MUST_BE_CONST = DiagnosticFactory{
    .name = "ANNOTATION_ARGUMENT_MUST_BE_CONST",
    .default_severity = .Error,
    .message_template = "Annotation argument must be a compile-time constant.",
};
pub const ANNOTATION_ARGUMENT_MUST_BE_ENUM_CONST = DiagnosticFactory{
    .name = "ANNOTATION_ARGUMENT_MUST_BE_ENUM_CONST",
    .default_severity = .Error,
    .message_template = "Enum annotation argument must be an enum constant.",
};
pub const ANNOTATION_ARGUMENT_MUST_BE_KCLASS_LITERAL = DiagnosticFactory{
    .name = "ANNOTATION_ARGUMENT_MUST_BE_KCLASS_LITERAL",
    .default_severity = .Error,
    .message_template = "Annotation argument must be class literal (T::class).",
};
pub const ANNOTATION_CLASS_CONSTRUCTOR_CALL = DiagnosticFactory{
    .name = "ANNOTATION_CLASS_CONSTRUCTOR_CALL",
    .default_severity = .Error,
    .message_template = "Annotation class cannot be instantiated.",
};
pub const ANNOTATION_CLASS_MEMBER = DiagnosticFactory{
    .name = "ANNOTATION_CLASS_MEMBER",
    .default_severity = .Error,
    .message_template = "Members are prohibited in annotation classes.",
};
pub const ANNOTATION_IN_CONTRACT_ERROR = DiagnosticFactory{
    .name = "ANNOTATION_IN_CONTRACT_ERROR",
    .default_severity = .Error,
    .message_template = "ANNOTATION_IN_CONTRACT_ERROR",
};
pub const ANNOTATION_IN_WHERE_CLAUSE_ERROR = DiagnosticFactory{
    .name = "ANNOTATION_IN_WHERE_CLAUSE_ERROR",
    .default_severity = .Error,
    .message_template = "ANNOTATION_IN_WHERE_CLAUSE_ERROR",
};
pub const ANNOTATION_ON_ANNOTATION_ARGUMENT = DiagnosticFactory{
    .name = "ANNOTATION_ON_ANNOTATION_ARGUMENT",
    .default_severity = .Error,
    .message_template = "Annotations on annotation arguments are prohibited.",
};
pub const ANNOTATION_ON_ILLEGAL_MULTI_FIELD_VALUE_CLASS_TYPED_TARGET = DiagnosticFactory{
    .name = "ANNOTATION_ON_ILLEGAL_MULTI_FIELD_VALUE_CLASS_TYPED_TARGET",
    .default_severity = .Error,
    .message_template = "ANNOTATION_ON_ILLEGAL_MULTI_FIELD_VALUE_CLASS_TYPED_TARGET",
};
pub const ANNOTATION_ON_SUPERCLASS_ERROR = DiagnosticFactory{
    .name = "ANNOTATION_ON_SUPERCLASS_ERROR",
    .default_severity = .Error,
    .message_template = "Annotations on superclasses are meaningless.",
};
pub const ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT = DiagnosticFactory{
    .name = "ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT",
    .default_severity = .Error,
    .message_template = "ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT",
};
pub const ANNOTATION_USED_AS_ANNOTATION_ARGUMENT = DiagnosticFactory{
    .name = "ANNOTATION_USED_AS_ANNOTATION_ARGUMENT",
    .default_severity = .Error,
    .message_template = "Annotations cannot be used as annotation arguments.",
};
pub const ANNOTATION_WILL_BE_APPLIED_ALSO_TO_PROPERTY_OR_FIELD = DiagnosticFactory{
    .name = "ANNOTATION_WILL_BE_APPLIED_ALSO_TO_PROPERTY_OR_FIELD",
    .default_severity = .Warning,
    .message_template = "ANNOTATION_WILL_BE_APPLIED_ALSO_TO_PROPERTY_OR_FIELD",
};
pub const ANONYMOUS_FUNCTION_PARAMETER_WITH_DEFAULT_VALUE = DiagnosticFactory{
    .name = "ANONYMOUS_FUNCTION_PARAMETER_WITH_DEFAULT_VALUE",
    .default_severity = .Error,
    .message_template = "ANONYMOUS_FUNCTION_PARAMETER_WITH_DEFAULT_VALUE",
};
pub const ANONYMOUS_FUNCTION_WITH_NAME = DiagnosticFactory{
    .name = "ANONYMOUS_FUNCTION_WITH_NAME",
    .default_severity = .Error,
    .message_template = "Anonymous functions with names are prohibited.",
};
pub const ANONYMOUS_INITIALIZER_IN_INTERFACE = DiagnosticFactory{
    .name = "ANONYMOUS_INITIALIZER_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Anonymous initializers in interfaces are prohibited.",
};
pub const ANONYMOUS_SUSPEND_FUNCTION = DiagnosticFactory{
    .name = "ANONYMOUS_SUSPEND_FUNCTION",
    .default_severity = .Error,
    .message_template = "Anonymous suspend functions are prohibited.",
};
pub const API_NOT_AVAILABLE = DiagnosticFactory{
    .name = "API_NOT_AVAILABLE",
    .default_severity = .Error,
    .message_template = "API_NOT_AVAILABLE",
};
pub const ARGUMENT_PASSED_TWICE = DiagnosticFactory{
    .name = "ARGUMENT_PASSED_TWICE",
    .default_severity = .Error,
    .message_template = "Argument already passed for this parameter.",
};
pub const ARGUMENT_TYPE_MISMATCH = DiagnosticFactory{
    .name = "ARGUMENT_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "ARGUMENT_TYPE_MISMATCH",
};
pub const ARRAY_EQUALITY_OPERATOR_CAN_BE_REPLACED_WITH_CONTENT_EQUALS = DiagnosticFactory{
    .name = "ARRAY_EQUALITY_OPERATOR_CAN_BE_REPLACED_WITH_CONTENT_EQUALS",
    .default_severity = .Warning,
    .message_template = "'==' on arrays compares only references. Replace '==' with 'contentEquals' to compare the arrays' contents or use `===` to remove the warning.",
};
pub const ASSIGNED_VALUE_IS_NEVER_READ = DiagnosticFactory{
    .name = "ASSIGNED_VALUE_IS_NEVER_READ",
    .default_severity = .Warning,
    .message_template = "Assigned value is never read.",
};
pub const ASSIGNMENT_IN_EXPRESSION_CONTEXT = DiagnosticFactory{
    .name = "ASSIGNMENT_IN_EXPRESSION_CONTEXT",
    .default_severity = .Error,
    .message_template = "Only expressions are allowed in this context.",
};
pub const ASSIGNMENT_OPERATOR_SHOULD_RETURN_UNIT = DiagnosticFactory{
    .name = "ASSIGNMENT_OPERATOR_SHOULD_RETURN_UNIT",
    .default_severity = .Error,
    .message_template = "ASSIGNMENT_OPERATOR_SHOULD_RETURN_UNIT",
};
pub const ASSIGNMENT_TYPE_MISMATCH = DiagnosticFactory{
    .name = "ASSIGNMENT_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "ASSIGNMENT_TYPE_MISMATCH",
};
pub const ASSIGN_OPERATOR_AMBIGUITY = DiagnosticFactory{
    .name = "ASSIGN_OPERATOR_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "ASSIGN_OPERATOR_AMBIGUITY",
};
pub const ATOMIC_REF_CALL_ARGUMENT_WITHOUT_CONSISTENT_IDENTITY = DiagnosticFactory{
    .name = "ATOMIC_REF_CALL_ARGUMENT_WITHOUT_CONSISTENT_IDENTITY",
    .default_severity = .Warning,
    .message_template = "ATOMIC_REF_CALL_ARGUMENT_WITHOUT_CONSISTENT_IDENTITY",
};
pub const ATOMIC_REF_WITHOUT_CONSISTENT_IDENTITY = DiagnosticFactory{
    .name = "ATOMIC_REF_WITHOUT_CONSISTENT_IDENTITY",
    .default_severity = .Warning,
    .message_template = "ATOMIC_REF_WITHOUT_CONSISTENT_IDENTITY",
};
pub const BACKING_FIELD_FOR_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "BACKING_FIELD_FOR_DELEGATED_PROPERTY",
    .default_severity = .Error,
    .message_template = "BACKING_FIELD_FOR_DELEGATED_PROPERTY",
};
pub const BACKING_FIELD_IN_INTERFACE = DiagnosticFactory{
    .name = "BACKING_FIELD_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Property in interface cannot have a backing field.",
};
pub const BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER = DiagnosticFactory{
    .name = "BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER",
    .default_severity = .Error,
    .message_template = "BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER",
};
pub const BOUND_ON_TYPE_ALIAS_PARAMETER_NOT_ALLOWED = DiagnosticFactory{
    .name = "BOUND_ON_TYPE_ALIAS_PARAMETER_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Bounds on type alias parameters are prohibited.",
};
pub const BREAK_OR_CONTINUE_JUMPS_ACROSS_FUNCTION_BOUNDARY = DiagnosticFactory{
    .name = "BREAK_OR_CONTINUE_JUMPS_ACROSS_FUNCTION_BOUNDARY",
    .default_severity = .Error,
    .message_template = "'break' or 'continue' crosses a function or class boundary.",
};
pub const BREAK_OR_CONTINUE_OUTSIDE_A_LOOP = DiagnosticFactory{
    .name = "BREAK_OR_CONTINUE_OUTSIDE_A_LOOP",
    .default_severity = .Error,
    .message_template = "'break' and 'continue' are only allowed inside loops.",
};
pub const BUILDER_INFERENCE_MULTI_LAMBDA_RESTRICTION = DiagnosticFactory{
    .name = "BUILDER_INFERENCE_MULTI_LAMBDA_RESTRICTION",
    .default_severity = .Error,
    .message_template = "BUILDER_INFERENCE_MULTI_LAMBDA_RESTRICTION",
};
pub const BUILDER_INFERENCE_STUB_RECEIVER = DiagnosticFactory{
    .name = "BUILDER_INFERENCE_STUB_RECEIVER",
    .default_severity = .Error,
    .message_template = "BUILDER_INFERENCE_STUB_RECEIVER",
};
pub const CALLABLE_REFERENCE_LHS_NOT_A_CLASS = DiagnosticFactory{
    .name = "CALLABLE_REFERENCE_LHS_NOT_A_CLASS",
    .default_severity = .Error,
    .message_template = "Left-hand side of callable reference cannot be a type parameter.",
};
pub const CALLABLE_REFERENCE_TO_ANNOTATION_CONSTRUCTOR = DiagnosticFactory{
    .name = "CALLABLE_REFERENCE_TO_ANNOTATION_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Annotation class cannot be instantiated.",
};
pub const CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION = DiagnosticFactory{
    .name = "CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION",
    .default_severity = .Error,
    .message_template = "CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION",
};
pub const CANNOT_ALL_UNDER_IMPORT_FROM_SINGLETON = DiagnosticFactory{
    .name = "CANNOT_ALL_UNDER_IMPORT_FROM_SINGLETON",
    .default_severity = .Error,
    .message_template = "CANNOT_ALL_UNDER_IMPORT_FROM_SINGLETON",
};
pub const CANNOT_BE_IMPORTED = DiagnosticFactory{
    .name = "CANNOT_BE_IMPORTED",
    .default_severity = .Error,
    .message_template = "CANNOT_BE_IMPORTED",
};
pub const CANNOT_CHANGE_ACCESS_PRIVILEGE = DiagnosticFactory{
    .name = "CANNOT_CHANGE_ACCESS_PRIVILEGE",
    .default_severity = .Error,
    .message_template = "CANNOT_CHANGE_ACCESS_PRIVILEGE",
};
pub const CANNOT_CHANGE_ACCESS_PRIVILEGE_WARNING = DiagnosticFactory{
    .name = "CANNOT_CHANGE_ACCESS_PRIVILEGE_WARNING",
    .default_severity = .Warning,
    .message_template = "CANNOT_CHANGE_ACCESS_PRIVILEGE_WARNING",
};
pub const CANNOT_CHECK_FOR_ERASED = DiagnosticFactory{
    .name = "CANNOT_CHECK_FOR_ERASED",
    .default_severity = .Error,
    .message_template = "Cannot check for instance of erased type ''{0}''.",
};
pub const CANNOT_INFER_IT_PARAMETER_TYPE = DiagnosticFactory{
    .name = "CANNOT_INFER_IT_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "Cannot infer type for implicit value parameter 'it'. Specify it explicitly.",
};
pub const CANNOT_INFER_PARAMETER_TYPE = DiagnosticFactory{
    .name = "CANNOT_INFER_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "Cannot infer type for type parameter ''{0}''. Specify it explicitly.",
};
pub const CANNOT_INFER_RECEIVER_PARAMETER_TYPE = DiagnosticFactory{
    .name = "CANNOT_INFER_RECEIVER_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "Cannot infer type for receiver parameter. Specify it explicitly.",
};
pub const CANNOT_INFER_VALUE_PARAMETER_TYPE = DiagnosticFactory{
    .name = "CANNOT_INFER_VALUE_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "CANNOT_INFER_VALUE_PARAMETER_TYPE",
};
pub const CANNOT_INFER_VISIBILITY = DiagnosticFactory{
    .name = "CANNOT_INFER_VISIBILITY",
    .default_severity = .Error,
    .message_template = "CANNOT_INFER_VISIBILITY",
};
pub const CANNOT_INFER_VISIBILITY_WARNING = DiagnosticFactory{
    .name = "CANNOT_INFER_VISIBILITY_WARNING",
    .default_severity = .Warning,
    .message_template = "CANNOT_INFER_VISIBILITY_WARNING",
};
pub const CANNOT_OVERRIDE_INVISIBLE_MEMBER = DiagnosticFactory{
    .name = "CANNOT_OVERRIDE_INVISIBLE_MEMBER",
    .default_severity = .Error,
    .message_template = "CANNOT_OVERRIDE_INVISIBLE_MEMBER",
};
pub const CANNOT_WEAKEN_ACCESS_PRIVILEGE = DiagnosticFactory{
    .name = "CANNOT_WEAKEN_ACCESS_PRIVILEGE",
    .default_severity = .Error,
    .message_template = "CANNOT_WEAKEN_ACCESS_PRIVILEGE",
};
pub const CANNOT_WEAKEN_ACCESS_PRIVILEGE_WARNING = DiagnosticFactory{
    .name = "CANNOT_WEAKEN_ACCESS_PRIVILEGE_WARNING",
    .default_severity = .Warning,
    .message_template = "CANNOT_WEAKEN_ACCESS_PRIVILEGE_WARNING",
};
pub const CAN_BE_VAL = DiagnosticFactory{
    .name = "CAN_BE_VAL",
    .default_severity = .Warning,
    .message_template = "This 'var' property is never written to, it can be declared as 'val'.",
};
pub const CAN_BE_VAL_DELAYED_INITIALIZATION = DiagnosticFactory{
    .name = "CAN_BE_VAL_DELAYED_INITIALIZATION",
    .default_severity = .Warning,
    .message_template = "This 'var' property is not written to more than once, it can be declared as 'val'.",
};
pub const CAN_BE_VAL_LATEINIT = DiagnosticFactory{
    .name = "CAN_BE_VAL_LATEINIT",
    .default_severity = .Warning,
    .message_template = "This 'lateinit var' property is not written to more than once, it can be declared as nullable 'val'.",
};
pub const CAPTURED_MEMBER_VAL_INITIALIZATION = DiagnosticFactory{
    .name = "CAPTURED_MEMBER_VAL_INITIALIZATION",
    .default_severity = .Error,
    .message_template = "CAPTURED_MEMBER_VAL_INITIALIZATION",
};
pub const CAPTURED_VAL_INITIALIZATION = DiagnosticFactory{
    .name = "CAPTURED_VAL_INITIALIZATION",
    .default_severity = .Error,
    .message_template = "CAPTURED_VAL_INITIALIZATION",
};
pub const CAST_NEVER_SUCCEEDS = DiagnosticFactory{
    .name = "CAST_NEVER_SUCCEEDS",
    .default_severity = .Warning,
    .message_template = "This cast can never succeed.",
};
pub const CATCH_PARAMETER_WITH_DEFAULT_VALUE = DiagnosticFactory{
    .name = "CATCH_PARAMETER_WITH_DEFAULT_VALUE",
    .default_severity = .Error,
    .message_template = "Catch clause parameter cannot have a default value.",
};
pub const CLASSIFIER_REDECLARATION = DiagnosticFactory{
    .name = "CLASSIFIER_REDECLARATION",
    .default_severity = .Error,
    .message_template = "Redeclaration:{0}",
};
pub const CLASS_CANNOT_BE_EXTENDED_DIRECTLY = DiagnosticFactory{
    .name = "CLASS_CANNOT_BE_EXTENDED_DIRECTLY",
    .default_severity = .Error,
    .message_template = "Class ''{0}'' cannot be extended directly.",
};
pub const CLASS_INHERITS_JAVA_SEALED_CLASS = DiagnosticFactory{
    .name = "CLASS_INHERITS_JAVA_SEALED_CLASS",
    .default_severity = .Error,
    .message_template = "Extending Java sealed classes is prohibited.",
};
pub const CLASS_IN_SUPERTYPE_FOR_ENUM = DiagnosticFactory{
    .name = "CLASS_IN_SUPERTYPE_FOR_ENUM",
    .default_severity = .Error,
    .message_template = "Enum classes cannot extend classes.",
};
pub const CLASS_LITERAL_LHS_NOT_A_CLASS = DiagnosticFactory{
    .name = "CLASS_LITERAL_LHS_NOT_A_CLASS",
    .default_severity = .Error,
    .message_template = "Only classes are allowed on the left-hand side of a class literal.",
};
pub const COMMA_IN_WHEN_CONDITION_WITHOUT_ARGUMENT = DiagnosticFactory{
    .name = "COMMA_IN_WHEN_CONDITION_WITHOUT_ARGUMENT",
    .default_severity = .Error,
    .message_template = "COMMA_IN_WHEN_CONDITION_WITHOUT_ARGUMENT",
};
pub const COMMA_IN_WHEN_CONDITION_WITH_WHEN_GUARD = DiagnosticFactory{
    .name = "COMMA_IN_WHEN_CONDITION_WITH_WHEN_GUARD",
    .default_severity = .Error,
    .message_template = "COMMA_IN_WHEN_CONDITION_WITH_WHEN_GUARD",
};
pub const COMPARE_TO_TYPE_MISMATCH = DiagnosticFactory{
    .name = "COMPARE_TO_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "COMPARE_TO_TYPE_MISMATCH",
};
pub const COMPILER_REQUIRED_ANNOTATION_AMBIGUITY = DiagnosticFactory{
    .name = "COMPILER_REQUIRED_ANNOTATION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "COMPILER_REQUIRED_ANNOTATION_AMBIGUITY",
};
pub const COMPONENT_FUNCTION_AMBIGUITY = DiagnosticFactory{
    .name = "COMPONENT_FUNCTION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "COMPONENT_FUNCTION_AMBIGUITY",
};
pub const COMPONENT_FUNCTION_MISSING = DiagnosticFactory{
    .name = "COMPONENT_FUNCTION_MISSING",
    .default_severity = .Error,
    .message_template = "COMPONENT_FUNCTION_MISSING",
};
pub const COMPONENT_FUNCTION_ON_NULLABLE = DiagnosticFactory{
    .name = "COMPONENT_FUNCTION_ON_NULLABLE",
    .default_severity = .Error,
    .message_template = "COMPONENT_FUNCTION_ON_NULLABLE",
};
pub const COMPONENT_FUNCTION_RETURN_TYPE_MISMATCH = DiagnosticFactory{
    .name = "COMPONENT_FUNCTION_RETURN_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "COMPONENT_FUNCTION_RETURN_TYPE_MISMATCH",
};
pub const CONDITION_TYPE_MISMATCH = DiagnosticFactory{
    .name = "CONDITION_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "CONDITION_TYPE_MISMATCH",
};
pub const CONFLICTING_IMPORT = DiagnosticFactory{
    .name = "CONFLICTING_IMPORT",
    .default_severity = .Error,
    .message_template = "CONFLICTING_IMPORT",
};
pub const CONFLICTING_INHERITED_MEMBERS = DiagnosticFactory{
    .name = "CONFLICTING_INHERITED_MEMBERS",
    .default_severity = .Error,
    .message_template = "CONFLICTING_INHERITED_MEMBERS",
};
pub const CONFLICTING_OVERLOADS = DiagnosticFactory{
    .name = "CONFLICTING_OVERLOADS",
    .default_severity = .Error,
    .message_template = "Conflicting overloads:{0}",
};
pub const CONFLICTING_PROJECTION = DiagnosticFactory{
    .name = "CONFLICTING_PROJECTION",
    .default_severity = .Error,
    .message_template = "CONFLICTING_PROJECTION",
};
pub const CONFLICTING_PROJECTION_IN_TYPEALIAS_EXPANSION = DiagnosticFactory{
    .name = "CONFLICTING_PROJECTION_IN_TYPEALIAS_EXPANSION",
    .default_severity = .Error,
    .message_template = "CONFLICTING_PROJECTION_IN_TYPEALIAS_EXPANSION",
};
pub const CONFLICTING_UPPER_BOUNDS = DiagnosticFactory{
    .name = "CONFLICTING_UPPER_BOUNDS",
    .default_severity = .Error,
    .message_template = "CONFLICTING_UPPER_BOUNDS",
};
pub const CONFUSING_BRANCH_CONDITION_ERROR = DiagnosticFactory{
    .name = "CONFUSING_BRANCH_CONDITION_ERROR",
    .default_severity = .Error,
    .message_template = "CONFUSING_BRANCH_CONDITION_ERROR",
};
pub const CONSTRUCTOR_IN_INTERFACE = DiagnosticFactory{
    .name = "CONSTRUCTOR_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Interfaces cannot have constructors.",
};
pub const CONSTRUCTOR_IN_OBJECT = DiagnosticFactory{
    .name = "CONSTRUCTOR_IN_OBJECT",
    .default_severity = .Error,
    .message_template = "Objects cannot have constructors.",
};
pub const CONST_VAL_NOT_TOP_LEVEL_OR_OBJECT = DiagnosticFactory{
    .name = "CONST_VAL_NOT_TOP_LEVEL_OR_OBJECT",
    .default_severity = .Error,
    .message_template = "Const 'val' is only allowed on top level, in named objects, or in companion objects.",
};
pub const CONST_VAL_WITHOUT_INITIALIZER = DiagnosticFactory{
    .name = "CONST_VAL_WITHOUT_INITIALIZER",
    .default_severity = .Error,
    .message_template = "Const 'val' must have an initializer.",
};
pub const CONST_VAL_WITH_DELEGATE = DiagnosticFactory{
    .name = "CONST_VAL_WITH_DELEGATE",
    .default_severity = .Error,
    .message_template = "Const 'val' cannot have a delegate.",
};
pub const CONST_VAL_WITH_GETTER = DiagnosticFactory{
    .name = "CONST_VAL_WITH_GETTER",
    .default_severity = .Error,
    .message_template = "Const 'val' cannot have a getter.",
};
pub const CONST_VAL_WITH_NON_CONST_INITIALIZER = DiagnosticFactory{
    .name = "CONST_VAL_WITH_NON_CONST_INITIALIZER",
    .default_severity = .Error,
    .message_template = "Const 'val' initializer must be a constant value.",
};
pub const CONTEXTUAL_OVERLOAD_SHADOWED = DiagnosticFactory{
    .name = "CONTEXTUAL_OVERLOAD_SHADOWED",
    .default_severity = .Warning,
    .message_template = "CONTEXTUAL_OVERLOAD_SHADOWED",
};
pub const CONTEXT_CLASS_OR_CONSTRUCTOR = DiagnosticFactory{
    .name = "CONTEXT_CLASS_OR_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "CONTEXT_CLASS_OR_CONSTRUCTOR",
};
pub const CONTEXT_PARAMETERS_WITH_BACKING_FIELD = DiagnosticFactory{
    .name = "CONTEXT_PARAMETERS_WITH_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "CONTEXT_PARAMETERS_WITH_BACKING_FIELD",
};
pub const CONTEXT_PARAMETER_MUST_BE_NOINLINE = DiagnosticFactory{
    .name = "CONTEXT_PARAMETER_MUST_BE_NOINLINE",
    .default_severity = .Error,
    .message_template = "CONTEXT_PARAMETER_MUST_BE_NOINLINE",
};
pub const CONTEXT_PARAMETER_WITHOUT_NAME = DiagnosticFactory{
    .name = "CONTEXT_PARAMETER_WITHOUT_NAME",
    .default_severity = .Error,
    .message_template = "CONTEXT_PARAMETER_WITHOUT_NAME",
};
pub const CONTEXT_PARAMETER_WITH_DEFAULT = DiagnosticFactory{
    .name = "CONTEXT_PARAMETER_WITH_DEFAULT",
    .default_severity = .Error,
    .message_template = "CONTEXT_PARAMETER_WITH_DEFAULT",
};
pub const CONTEXT_RECEIVERS_DEPRECATED = DiagnosticFactory{
    .name = "CONTEXT_RECEIVERS_DEPRECATED",
    .default_severity = .Error,
    .message_template = "{0}",
};
pub const CONTEXT_SENSITIVE_RESOLUTION_AMBIGUITY = DiagnosticFactory{
    .name = "CONTEXT_SENSITIVE_RESOLUTION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "CONTEXT_SENSITIVE_RESOLUTION_AMBIGUITY",
};
pub const CONTRACT_NOT_ALLOWED = DiagnosticFactory{
    .name = "CONTRACT_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "{0}",
};
pub const CREATING_AN_INSTANCE_OF_ABSTRACT_CLASS = DiagnosticFactory{
    .name = "CREATING_AN_INSTANCE_OF_ABSTRACT_CLASS",
    .default_severity = .Error,
    .message_template = "Cannot create an instance of an abstract class.",
};
pub const CYCLIC_CONSTRUCTOR_DELEGATION_CALL = DiagnosticFactory{
    .name = "CYCLIC_CONSTRUCTOR_DELEGATION_CALL",
    .default_severity = .Error,
    .message_template = "There's a cycle in the delegation calls chain.",
};
pub const CYCLIC_GENERIC_UPPER_BOUND = DiagnosticFactory{
    .name = "CYCLIC_GENERIC_UPPER_BOUND",
    .default_severity = .Error,
    .message_template = "Type parameter has cyclic upper bounds: {0}.",
};
pub const CYCLIC_INHERITANCE_HIERARCHY = DiagnosticFactory{
    .name = "CYCLIC_INHERITANCE_HIERARCHY",
    .default_severity = .Error,
    .message_template = "Cycle in supertypes and/or containing declarations detected.",
};
pub const DATA_CLASS_CONSISTENT_COPY_AND_EXPOSED_COPY_ARE_INCOMPATIBLE_ANNOTATIONS = DiagnosticFactory{
    .name = "DATA_CLASS_CONSISTENT_COPY_AND_EXPOSED_COPY_ARE_INCOMPATIBLE_ANNOTATIONS",
    .default_severity = .Error,
    .message_template = "DATA_CLASS_CONSISTENT_COPY_AND_EXPOSED_COPY_ARE_INCOMPATIBLE_ANNOTATIONS",
};
pub const DATA_CLASS_CONSISTENT_COPY_WRONG_ANNOTATION_TARGET = DiagnosticFactory{
    .name = "DATA_CLASS_CONSISTENT_COPY_WRONG_ANNOTATION_TARGET",
    .default_severity = .Error,
    .message_template = "DATA_CLASS_CONSISTENT_COPY_WRONG_ANNOTATION_TARGET",
};
pub const DATA_CLASS_NOT_PROPERTY_PARAMETER = DiagnosticFactory{
    .name = "DATA_CLASS_NOT_PROPERTY_PARAMETER",
    .default_severity = .Error,
    .message_template = "Primary constructor of data class must only have property ('val' / 'var') parameters.",
};
pub const DATA_CLASS_OVERRIDE_CONFLICT = DiagnosticFactory{
    .name = "DATA_CLASS_OVERRIDE_CONFLICT",
    .default_severity = .Error,
    .message_template = "DATA_CLASS_OVERRIDE_CONFLICT",
};
pub const DATA_CLASS_OVERRIDE_DEFAULT_VALUES = DiagnosticFactory{
    .name = "DATA_CLASS_OVERRIDE_DEFAULT_VALUES",
    .default_severity = .Error,
    .message_template = "DATA_CLASS_OVERRIDE_DEFAULT_VALUES",
};
pub const DATA_CLASS_VARARG_PARAMETER = DiagnosticFactory{
    .name = "DATA_CLASS_VARARG_PARAMETER",
    .default_severity = .Error,
    .message_template = "Primary constructor vararg parameters are prohibited for data classes.",
};
pub const DATA_CLASS_WITHOUT_PARAMETERS = DiagnosticFactory{
    .name = "DATA_CLASS_WITHOUT_PARAMETERS",
    .default_severity = .Error,
    .message_template = "Data class must have at least one primary constructor parameter.",
};
pub const DATA_OBJECT_CUSTOM_EQUALS_OR_HASH_CODE = DiagnosticFactory{
    .name = "DATA_OBJECT_CUSTOM_EQUALS_OR_HASH_CODE",
    .default_severity = .Error,
    .message_template = "Data object cannot have a custom implementation of 'equals' or 'hashCode'.",
};
pub const DECLARATION_CANT_BE_INLINED = DiagnosticFactory{
    .name = "DECLARATION_CANT_BE_INLINED",
    .default_severity = .Error,
    .message_template = "DECLARATION_CANT_BE_INLINED",
};
pub const DEFAULT_ARGUMENTS_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE = DiagnosticFactory{
    .name = "DEFAULT_ARGUMENTS_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE",
    .default_severity = .Error,
    .message_template = "DEFAULT_ARGUMENTS_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE",
};
pub const DEFAULT_ARGUMENTS_IN_EXPECT_WITH_ACTUAL_TYPEALIAS = DiagnosticFactory{
    .name = "DEFAULT_ARGUMENTS_IN_EXPECT_WITH_ACTUAL_TYPEALIAS",
    .default_severity = .Error,
    .message_template = "DEFAULT_ARGUMENTS_IN_EXPECT_WITH_ACTUAL_TYPEALIAS",
};
pub const DEFAULT_VALUE_NOT_ALLOWED_IN_OVERRIDE = DiagnosticFactory{
    .name = "DEFAULT_VALUE_NOT_ALLOWED_IN_OVERRIDE",
    .default_severity = .Error,
    .message_template = "An overriding function is not allowed to specify default values for its parameters.",
};
pub const DEFINITELY_NON_NULLABLE_AS_REIFIED = DiagnosticFactory{
    .name = "DEFINITELY_NON_NULLABLE_AS_REIFIED",
    .default_severity = .Error,
    .message_template = "DEFINITELY_NON_NULLABLE_AS_REIFIED",
};
pub const DELEGATED_MEMBER_HIDES_SUPERTYPE_OVERRIDE = DiagnosticFactory{
    .name = "DELEGATED_MEMBER_HIDES_SUPERTYPE_OVERRIDE",
    .default_severity = .Warning,
    .message_template = "DELEGATED_MEMBER_HIDES_SUPERTYPE_OVERRIDE",
};
pub const DELEGATED_PROPERTY_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "DELEGATED_PROPERTY_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "Value class cannot have delegated properties.",
};
pub const DELEGATED_PROPERTY_IN_INTERFACE = DiagnosticFactory{
    .name = "DELEGATED_PROPERTY_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Delegated properties in interfaces are prohibited.",
};
pub const DELEGATE_SPECIAL_FUNCTION_AMBIGUITY = DiagnosticFactory{
    .name = "DELEGATE_SPECIAL_FUNCTION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "DELEGATE_SPECIAL_FUNCTION_AMBIGUITY",
};
pub const DELEGATE_SPECIAL_FUNCTION_MISSING = DiagnosticFactory{
    .name = "DELEGATE_SPECIAL_FUNCTION_MISSING",
    .default_severity = .Error,
    .message_template = "DELEGATE_SPECIAL_FUNCTION_MISSING",
};
pub const DELEGATE_SPECIAL_FUNCTION_NONE_APPLICABLE = DiagnosticFactory{
    .name = "DELEGATE_SPECIAL_FUNCTION_NONE_APPLICABLE",
    .default_severity = .Error,
    .message_template = "DELEGATE_SPECIAL_FUNCTION_NONE_APPLICABLE",
};
pub const DELEGATE_SPECIAL_FUNCTION_RETURN_TYPE_MISMATCH = DiagnosticFactory{
    .name = "DELEGATE_SPECIAL_FUNCTION_RETURN_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "DELEGATE_SPECIAL_FUNCTION_RETURN_TYPE_MISMATCH",
};
pub const DELEGATE_USES_EXTENSION_PROPERTY_TYPE_PARAMETER_ERROR = DiagnosticFactory{
    .name = "DELEGATE_USES_EXTENSION_PROPERTY_TYPE_PARAMETER_ERROR",
    .default_severity = .Error,
    .message_template = "DELEGATE_USES_EXTENSION_PROPERTY_TYPE_PARAMETER_ERROR",
};
pub const DELEGATION_IN_INTERFACE = DiagnosticFactory{
    .name = "DELEGATION_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Delegation cannot be used in interfaces.",
};
pub const DELEGATION_NOT_TO_INTERFACE = DiagnosticFactory{
    .name = "DELEGATION_NOT_TO_INTERFACE",
    .default_severity = .Error,
    .message_template = "Delegation is supported only for interfaces.",
};
pub const DELEGATION_SUPER_CALL_IN_ENUM_CONSTRUCTOR = DiagnosticFactory{
    .name = "DELEGATION_SUPER_CALL_IN_ENUM_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Calls to super in enum constructors are prohibited.",
};
pub const DEPRECATED_ACCESS_TO_ENTRIES_AS_QUALIFIER = DiagnosticFactory{
    .name = "DEPRECATED_ACCESS_TO_ENTRIES_AS_QUALIFIER",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_ACCESS_TO_ENTRIES_AS_QUALIFIER",
};
pub const DEPRECATED_ACCESS_TO_ENTRIES_PROPERTY = DiagnosticFactory{
    .name = "DEPRECATED_ACCESS_TO_ENTRIES_PROPERTY",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_ACCESS_TO_ENTRIES_PROPERTY",
};
pub const DEPRECATED_ACCESS_TO_ENTRY_PROPERTY_FROM_ENUM = DiagnosticFactory{
    .name = "DEPRECATED_ACCESS_TO_ENTRY_PROPERTY_FROM_ENUM",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_ACCESS_TO_ENTRY_PROPERTY_FROM_ENUM",
};
pub const DEPRECATED_ACCESS_TO_ENUM_ENTRY_COMPANION_PROPERTY = DiagnosticFactory{
    .name = "DEPRECATED_ACCESS_TO_ENUM_ENTRY_COMPANION_PROPERTY",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_ACCESS_TO_ENUM_ENTRY_COMPANION_PROPERTY",
};
pub const DEPRECATED_ACCESS_TO_ENUM_ENTRY_PROPERTY_AS_REFERENCE = DiagnosticFactory{
    .name = "DEPRECATED_ACCESS_TO_ENUM_ENTRY_PROPERTY_AS_REFERENCE",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_ACCESS_TO_ENUM_ENTRY_PROPERTY_AS_REFERENCE",
};
pub const DEPRECATED_IDENTITY_EQUALS = DiagnosticFactory{
    .name = "DEPRECATED_IDENTITY_EQUALS",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_IDENTITY_EQUALS",
};
pub const DEPRECATED_MODIFIER = DiagnosticFactory{
    .name = "DEPRECATED_MODIFIER",
    .default_severity = .Error,
    .message_template = "Modifier ''{0}'' is deprecated; use ''{1}'' instead.",
};
pub const DEPRECATED_MODIFIER_CONTAINING_DECLARATION = DiagnosticFactory{
    .name = "DEPRECATED_MODIFIER_CONTAINING_DECLARATION",
    .default_severity = .Warning,
    .message_template = "Modifier ''{0}'' is deprecated inside ''{1}''.",
};
pub const DEPRECATED_MODIFIER_FOR_TARGET = DiagnosticFactory{
    .name = "DEPRECATED_MODIFIER_FOR_TARGET",
    .default_severity = .Warning,
    .message_template = "Modifier ''{0}'' is deprecated for ''{1}''.",
};
pub const DEPRECATED_MODIFIER_PAIR = DiagnosticFactory{
    .name = "DEPRECATED_MODIFIER_PAIR",
    .default_severity = .Warning,
    .message_template = "Modifier ''{0}'' is deprecated in presence of ''{1}''.",
};
pub const DEPRECATED_SINCE_KOTLIN_OUTSIDE_KOTLIN_SUBPACKAGE = DiagnosticFactory{
    .name = "DEPRECATED_SINCE_KOTLIN_OUTSIDE_KOTLIN_SUBPACKAGE",
    .default_severity = .Error,
    .message_template = "DEPRECATED_SINCE_KOTLIN_OUTSIDE_KOTLIN_SUBPACKAGE",
};
pub const DEPRECATED_SINCE_KOTLIN_WITHOUT_ARGUMENTS = DiagnosticFactory{
    .name = "DEPRECATED_SINCE_KOTLIN_WITHOUT_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "DEPRECATED_SINCE_KOTLIN_WITHOUT_ARGUMENTS",
};
pub const DEPRECATED_SINCE_KOTLIN_WITHOUT_DEPRECATED = DiagnosticFactory{
    .name = "DEPRECATED_SINCE_KOTLIN_WITHOUT_DEPRECATED",
    .default_severity = .Error,
    .message_template = "DEPRECATED_SINCE_KOTLIN_WITHOUT_DEPRECATED",
};
pub const DEPRECATED_SINCE_KOTLIN_WITH_DEPRECATED_LEVEL = DiagnosticFactory{
    .name = "DEPRECATED_SINCE_KOTLIN_WITH_DEPRECATED_LEVEL",
    .default_severity = .Error,
    .message_template = "DEPRECATED_SINCE_KOTLIN_WITH_DEPRECATED_LEVEL",
};
pub const DEPRECATED_SINCE_KOTLIN_WITH_UNORDERED_VERSIONS = DiagnosticFactory{
    .name = "DEPRECATED_SINCE_KOTLIN_WITH_UNORDERED_VERSIONS",
    .default_severity = .Error,
    .message_template = "DEPRECATED_SINCE_KOTLIN_WITH_UNORDERED_VERSIONS",
};
pub const DEPRECATED_SMARTCAST_ON_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "DEPRECATED_SMARTCAST_ON_DELEGATED_PROPERTY",
    .default_severity = .Warning,
    .message_template = "DEPRECATED_SMARTCAST_ON_DELEGATED_PROPERTY",
};
pub const DEPRECATED_TYPE_PARAMETER_SYNTAX = DiagnosticFactory{
    .name = "DEPRECATED_TYPE_PARAMETER_SYNTAX",
    .default_severity = .Error,
    .message_template = "Type parameters must be placed before function name.",
};
pub const DEPRECATION = DiagnosticFactory{
    .name = "DEPRECATION",
    .default_severity = .Warning,
    .message_template = "''{0}'' is deprecated.{1}",
};
pub const DEPRECATION_ERROR = DiagnosticFactory{
    .name = "DEPRECATION_ERROR",
    .default_severity = .Error,
    .message_template = "''{0}'' is deprecated.{1}",
};
pub const DESERIALIZATION_ERROR = DiagnosticFactory{
    .name = "DESERIALIZATION_ERROR",
    .default_severity = .Error,
    .message_template = "Deserialization error.",
};
pub const DESTRUCTURING_SHORT_FORM_NAME_MISMATCH = DiagnosticFactory{
    .name = "DESTRUCTURING_SHORT_FORM_NAME_MISMATCH",
    .default_severity = .Warning,
    .message_template = "DESTRUCTURING_SHORT_FORM_NAME_MISMATCH",
};
pub const DESTRUCTURING_SHORT_FORM_OF_NON_DATA_CLASS = DiagnosticFactory{
    .name = "DESTRUCTURING_SHORT_FORM_OF_NON_DATA_CLASS",
    .default_severity = .Warning,
    .message_template = "DESTRUCTURING_SHORT_FORM_OF_NON_DATA_CLASS",
};
pub const DESTRUCTURING_SHORT_FORM_UNDERSCORE = DiagnosticFactory{
    .name = "DESTRUCTURING_SHORT_FORM_UNDERSCORE",
    .default_severity = .Warning,
    .message_template = "DESTRUCTURING_SHORT_FORM_UNDERSCORE",
};
pub const DIFFERENT_NAMES_FOR_THE_SAME_PARAMETER_IN_SUPERTYPES = DiagnosticFactory{
    .name = "DIFFERENT_NAMES_FOR_THE_SAME_PARAMETER_IN_SUPERTYPES",
    .default_severity = .Warning,
    .message_template = "DIFFERENT_NAMES_FOR_THE_SAME_PARAMETER_IN_SUPERTYPES",
};
pub const DIVISION_BY_ZERO = DiagnosticFactory{
    .name = "DIVISION_BY_ZERO",
    .default_severity = .Warning,
    .message_template = "Division by zero.",
};
pub const DSL_MARKER_APPLIED_TO_WRONG_TARGET = DiagnosticFactory{
    .name = "DSL_MARKER_APPLIED_TO_WRONG_TARGET",
    .default_severity = .Warning,
    .message_template = "DSL_MARKER_APPLIED_TO_WRONG_TARGET",
};
pub const DSL_MARKER_PROPAGATES_TO_MANY = DiagnosticFactory{
    .name = "DSL_MARKER_PROPAGATES_TO_MANY",
    .default_severity = .Warning,
    .message_template = "DSL_MARKER_PROPAGATES_TO_MANY",
};
pub const DSL_SCOPE_VIOLATION = DiagnosticFactory{
    .name = "DSL_SCOPE_VIOLATION",
    .default_severity = .Error,
    .message_template = "DSL_SCOPE_VIOLATION",
};
pub const DUPLICATE_BRANCH_CONDITION_IN_WHEN = DiagnosticFactory{
    .name = "DUPLICATE_BRANCH_CONDITION_IN_WHEN",
    .default_severity = .Warning,
    .message_template = "Duplicate branch condition in 'when'.",
};
pub const DUPLICATE_PARAMETER_NAME_IN_FUNCTION_TYPE = DiagnosticFactory{
    .name = "DUPLICATE_PARAMETER_NAME_IN_FUNCTION_TYPE",
    .default_severity = .Error,
    .message_template = "Duplicate parameter name in a function type.",
};
pub const DYNAMIC_NOT_ALLOWED = DiagnosticFactory{
    .name = "DYNAMIC_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Dynamic types are not allowed in this position.",
};
pub const DYNAMIC_RECEIVER_EXPECTED_BUT_WAS_NON_DYNAMIC = DiagnosticFactory{
    .name = "DYNAMIC_RECEIVER_EXPECTED_BUT_WAS_NON_DYNAMIC",
    .default_severity = .Error,
    .message_template = "DYNAMIC_RECEIVER_EXPECTED_BUT_WAS_NON_DYNAMIC",
};
pub const DYNAMIC_RECEIVER_NOT_ALLOWED = DiagnosticFactory{
    .name = "DYNAMIC_RECEIVER_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Dynamic receivers are prohibited.",
};
pub const DYNAMIC_SUPERTYPE = DiagnosticFactory{
    .name = "DYNAMIC_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "Supertypes cannot be dynamic.",
};
pub const DYNAMIC_UPPER_BOUND = DiagnosticFactory{
    .name = "DYNAMIC_UPPER_BOUND",
    .default_severity = .Error,
    .message_template = "Dynamic type cannot be used as an upper bound.",
};
pub const ELSE_MISPLACED_IN_WHEN = DiagnosticFactory{
    .name = "ELSE_MISPLACED_IN_WHEN",
    .default_severity = .Error,
    .message_template = "'else' entry must be the last one in a 'when' expression.",
};
pub const EMPTY_CHARACTER_LITERAL = DiagnosticFactory{
    .name = "EMPTY_CHARACTER_LITERAL",
    .default_severity = .Error,
    .message_template = "Empty character literal.",
};
pub const EMPTY_RANGE = DiagnosticFactory{
    .name = "EMPTY_RANGE",
    .default_severity = .Warning,
    .message_template = "Range is empty.",
};
pub const ENUM_CLASS_CONSTRUCTOR_CALL = DiagnosticFactory{
    .name = "ENUM_CLASS_CONSTRUCTOR_CALL",
    .default_severity = .Error,
    .message_template = "Enum types cannot be instantiated.",
};
pub const ENUM_ENTRY_AS_TYPE = DiagnosticFactory{
    .name = "ENUM_ENTRY_AS_TYPE",
    .default_severity = .Error,
    .message_template = "Use of enum entry names as types is prohibited. Use enum type instead.",
};
pub const EQUALITY_NOT_APPLICABLE = DiagnosticFactory{
    .name = "EQUALITY_NOT_APPLICABLE",
    .default_severity = .Error,
    .message_template = "EQUALITY_NOT_APPLICABLE",
};
pub const EQUALITY_NOT_APPLICABLE_WARNING = DiagnosticFactory{
    .name = "EQUALITY_NOT_APPLICABLE_WARNING",
    .default_severity = .Warning,
    .message_template = "EQUALITY_NOT_APPLICABLE_WARNING",
};
pub const ERROR_FROM_JAVA_RESOLUTION = DiagnosticFactory{
    .name = "ERROR_FROM_JAVA_RESOLUTION",
    .default_severity = .Error,
    .message_template = "Java resolution error.",
};
pub const ERROR_IN_CONTRACT_DESCRIPTION = DiagnosticFactory{
    .name = "ERROR_IN_CONTRACT_DESCRIPTION",
    .default_severity = .Error,
    .message_template = "Error in contract description: {0}.",
};
pub const ERROR_SUPPRESSION = DiagnosticFactory{
    .name = "ERROR_SUPPRESSION",
    .default_severity = .Warning,
    .message_template = "ERROR_SUPPRESSION",
};
pub const EXPANSIVE_INHERITANCE = DiagnosticFactory{
    .name = "EXPANSIVE_INHERITANCE",
    .default_severity = .Error,
    .message_template = "This type parameter violates the Non-Expansive Inheritance Restriction.",
};
pub const EXPANSIVE_INHERITANCE_IN_JAVA = DiagnosticFactory{
    .name = "EXPANSIVE_INHERITANCE_IN_JAVA",
    .default_severity = .Warning,
    .message_template = "EXPANSIVE_INHERITANCE_IN_JAVA",
};
pub const EXPECTED_CLASS_CONSTRUCTOR_DELEGATION_CALL = DiagnosticFactory{
    .name = "EXPECTED_CLASS_CONSTRUCTOR_DELEGATION_CALL",
    .default_severity = .Error,
    .message_template = "Explicit delegation call for constructor of expected class is prohibited.",
};
pub const EXPECTED_CLASS_CONSTRUCTOR_PROPERTY_PARAMETER = DiagnosticFactory{
    .name = "EXPECTED_CLASS_CONSTRUCTOR_PROPERTY_PARAMETER",
    .default_severity = .Error,
    .message_template = "Expected class constructor cannot have a property parameter.",
};
pub const EXPECTED_CONDITION = DiagnosticFactory{
    .name = "EXPECTED_CONDITION",
    .default_severity = .Error,
    .message_template = "Condition of type 'Boolean' expected.",
};
pub const EXPECTED_DECLARATION_WITH_BODY = DiagnosticFactory{
    .name = "EXPECTED_DECLARATION_WITH_BODY",
    .default_severity = .Error,
    .message_template = "Expected declaration cannot have a body.",
};
pub const EXPECTED_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "EXPECTED_DELEGATED_PROPERTY",
    .default_severity = .Error,
    .message_template = "Expected property cannot be delegated.",
};
pub const EXPECTED_ENUM_CONSTRUCTOR = DiagnosticFactory{
    .name = "EXPECTED_ENUM_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Expected enum class cannot have a constructor.",
};
pub const EXPECTED_ENUM_ENTRY_WITH_BODY = DiagnosticFactory{
    .name = "EXPECTED_ENUM_ENTRY_WITH_BODY",
    .default_severity = .Error,
    .message_template = "Expected enum entry cannot have a body.",
};
pub const EXPECTED_EXTERNAL_DECLARATION = DiagnosticFactory{
    .name = "EXPECTED_EXTERNAL_DECLARATION",
    .default_severity = .Error,
    .message_template = "Expected declaration cannot be external.",
};
pub const EXPECTED_FUNCTION_SOURCE_WITH_DEFAULT_ARGUMENTS_NOT_FOUND = DiagnosticFactory{
    .name = "EXPECTED_FUNCTION_SOURCE_WITH_DEFAULT_ARGUMENTS_NOT_FOUND",
    .default_severity = .Error,
    .message_template = "EXPECTED_FUNCTION_SOURCE_WITH_DEFAULT_ARGUMENTS_NOT_FOUND",
};
pub const EXPECTED_LATEINIT_PROPERTY = DiagnosticFactory{
    .name = "EXPECTED_LATEINIT_PROPERTY",
    .default_severity = .Error,
    .message_template = "Expected property cannot be 'lateinit'.",
};
pub const EXPECTED_PRIVATE_DECLARATION = DiagnosticFactory{
    .name = "EXPECTED_PRIVATE_DECLARATION",
    .default_severity = .Error,
    .message_template = "Expected declaration cannot be private.",
};
pub const EXPECTED_PROPERTY_INITIALIZER = DiagnosticFactory{
    .name = "EXPECTED_PROPERTY_INITIALIZER",
    .default_severity = .Error,
    .message_template = "Expected property cannot have an initializer.",
};
pub const EXPECTED_TAILREC_FUNCTION = DiagnosticFactory{
    .name = "EXPECTED_TAILREC_FUNCTION",
    .default_severity = .Error,
    .message_template = "Expected function cannot have 'tailrec' modifier.",
};
pub const EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING",
    .default_severity = .Warning,
    .message_template = "EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CLASS_KIND = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_KIND",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_KIND",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CLASS_MODIFIERS = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_MODIFIERS",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_MODIFIERS",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CLASS_SCOPE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_SCOPE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_SCOPE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_COUNT = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_COUNT",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_COUNT",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_UPPER_BOUNDS = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_UPPER_BOUNDS",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_UPPER_BOUNDS",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_ENUM_ENTRIES = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_ENUM_ENTRIES",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_ENUM_ENTRIES",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_FUN_INTERFACE_MODIFIER = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_FUN_INTERFACE_MODIFIER",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_FUN_INTERFACE_MODIFIER",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_ILLEGAL_REQUIRES_OPT_IN = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_ILLEGAL_REQUIRES_OPT_IN",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_ILLEGAL_REQUIRES_OPT_IN",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_MODALITY = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_MODALITY",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_MODALITY",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_NESTED_TYPE_ALIAS = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_NESTED_TYPE_ALIAS",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_NESTED_TYPE_ALIAS",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PARAMETERS_WITH_DEFAULT_VALUES_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PARAMETERS_WITH_DEFAULT_VALUES_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PARAMETERS_WITH_DEFAULT_VALUES_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PARAMETER_NAMES = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PARAMETER_NAMES",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PARAMETER_NAMES",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_CONST_MODIFIER = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_CONST_MODIFIER",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_CONST_MODIFIER",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_KIND = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_KIND",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_KIND",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_LATEINIT_MODIFIER = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_LATEINIT_MODIFIER",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_LATEINIT_MODIFIER",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_SETTER_VISIBILITY = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_SETTER_VISIBILITY",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_SETTER_VISIBILITY",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_RETURN_TYPE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_RETURN_TYPE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_SUPERTYPES = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_SUPERTYPES",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_SUPERTYPES",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_NAMES = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_NAMES",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_NAMES",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_REIFIED = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_REIFIED",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_REIFIED",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_VARIANCE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_VARIANCE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_VARIANCE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_CROSSINLINE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_CROSSINLINE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_CROSSINLINE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_NOINLINE = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_NOINLINE",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_NOINLINE",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_VARARG = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_VARARG",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_VARARG",
};
pub const EXPECT_ACTUAL_INCOMPATIBLE_VISIBILITY = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_INCOMPATIBLE_VISIBILITY",
    .default_severity = .Error,
    .message_template = "EXPECT_ACTUAL_INCOMPATIBLE_VISIBILITY",
};
pub const EXPECT_ACTUAL_OPT_IN_ANNOTATION = DiagnosticFactory{
    .name = "EXPECT_ACTUAL_OPT_IN_ANNOTATION",
    .default_severity = .Error,
    .message_template = "Opt-in annotations are prohibited to be 'expect' or 'actual'. Instead, declare annotation once in common sources.",
};
pub const EXPECT_AND_ACTUAL_IN_THE_SAME_MODULE = DiagnosticFactory{
    .name = "EXPECT_AND_ACTUAL_IN_THE_SAME_MODULE",
    .default_severity = .Error,
    .message_template = "{0}: expect and corresponding actual are declared in the same module.",
};
pub const EXPECT_CLASS_AS_FUNCTION = DiagnosticFactory{
    .name = "EXPECT_CLASS_AS_FUNCTION",
    .default_severity = .Error,
    .message_template = "Expected class ''{0}'' does not have default constructor.",
};
pub const EXPECT_PROPERTY_WITH_EXPLICIT_BACKING_FIELD = DiagnosticFactory{
    .name = "EXPECT_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "EXPECT_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
};
pub const EXPECT_REFINEMENT_ANNOTATION_MISSING = DiagnosticFactory{
    .name = "EXPECT_REFINEMENT_ANNOTATION_MISSING",
    .default_severity = .Error,
    .message_template = "EXPECT_REFINEMENT_ANNOTATION_MISSING",
};
pub const EXPECT_REFINEMENT_ANNOTATION_WRONG_TARGET = DiagnosticFactory{
    .name = "EXPECT_REFINEMENT_ANNOTATION_WRONG_TARGET",
    .default_severity = .Error,
    .message_template = "EXPECT_REFINEMENT_ANNOTATION_WRONG_TARGET",
};
pub const EXPLICIT_BACKING_FIELD_IN_ABSTRACT_PROPERTY = DiagnosticFactory{
    .name = "EXPLICIT_BACKING_FIELD_IN_ABSTRACT_PROPERTY",
    .default_severity = .Error,
    .message_template = "EXPLICIT_BACKING_FIELD_IN_ABSTRACT_PROPERTY",
};
pub const EXPLICIT_BACKING_FIELD_IN_EXTENSION = DiagnosticFactory{
    .name = "EXPLICIT_BACKING_FIELD_IN_EXTENSION",
    .default_severity = .Error,
    .message_template = "EXPLICIT_BACKING_FIELD_IN_EXTENSION",
};
pub const EXPLICIT_BACKING_FIELD_IN_INTERFACE = DiagnosticFactory{
    .name = "EXPLICIT_BACKING_FIELD_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "EXPLICIT_BACKING_FIELD_IN_INTERFACE",
};
pub const EXPLICIT_DELEGATION_CALL_REQUIRED = DiagnosticFactory{
    .name = "EXPLICIT_DELEGATION_CALL_REQUIRED",
    .default_severity = .Error,
    .message_template = "EXPLICIT_DELEGATION_CALL_REQUIRED",
};
pub const EXPLICIT_FIELD_MUST_BE_INITIALIZED = DiagnosticFactory{
    .name = "EXPLICIT_FIELD_MUST_BE_INITIALIZED",
    .default_severity = .Error,
    .message_template = "EXPLICIT_FIELD_MUST_BE_INITIALIZED",
};
pub const EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE = DiagnosticFactory{
    .name = "EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE",
    .default_severity = .Error,
    .message_template = "EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE",
};
pub const EXPLICIT_TYPE_ARGUMENTS_IN_PROPERTY_ACCESS = DiagnosticFactory{
    .name = "EXPLICIT_TYPE_ARGUMENTS_IN_PROPERTY_ACCESS",
    .default_severity = .Error,
    .message_template = "{0} access cannot have explicit type arguments.",
};
pub const EXPOSED_FUNCTION_RETURN_TYPE = DiagnosticFactory{
    .name = "EXPOSED_FUNCTION_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "EXPOSED_FUNCTION_RETURN_TYPE",
};
pub const EXPOSED_PACKAGE_PRIVATE_TYPE_FROM_INTERNAL_WARNING = DiagnosticFactory{
    .name = "EXPOSED_PACKAGE_PRIVATE_TYPE_FROM_INTERNAL_WARNING",
    .default_severity = .Warning,
    .message_template = "EXPOSED_PACKAGE_PRIVATE_TYPE_FROM_INTERNAL_WARNING",
};
pub const EXPOSED_PARAMETER_TYPE = DiagnosticFactory{
    .name = "EXPOSED_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "EXPOSED_PARAMETER_TYPE",
};
pub const EXPOSED_PROPERTY_TYPE = DiagnosticFactory{
    .name = "EXPOSED_PROPERTY_TYPE",
    .default_severity = .Error,
    .message_template = "EXPOSED_PROPERTY_TYPE",
};
pub const EXPOSED_PROPERTY_TYPE_IN_CONSTRUCTOR_ERROR = DiagnosticFactory{
    .name = "EXPOSED_PROPERTY_TYPE_IN_CONSTRUCTOR_ERROR",
    .default_severity = .Error,
    .message_template = "EXPOSED_PROPERTY_TYPE_IN_CONSTRUCTOR_ERROR",
};
pub const EXPOSED_RECEIVER_TYPE = DiagnosticFactory{
    .name = "EXPOSED_RECEIVER_TYPE",
    .default_severity = .Error,
    .message_template = "EXPOSED_RECEIVER_TYPE",
};
pub const EXPOSED_SUPER_CLASS = DiagnosticFactory{
    .name = "EXPOSED_SUPER_CLASS",
    .default_severity = .Error,
    .message_template = "EXPOSED_SUPER_CLASS",
};
pub const EXPOSED_SUPER_INTERFACE = DiagnosticFactory{
    .name = "EXPOSED_SUPER_INTERFACE",
    .default_severity = .Error,
    .message_template = "EXPOSED_SUPER_INTERFACE",
};
pub const EXPOSED_TYPEALIAS_EXPANDED_TYPE = DiagnosticFactory{
    .name = "EXPOSED_TYPEALIAS_EXPANDED_TYPE",
    .default_severity = .Error,
    .message_template = "EXPOSED_TYPEALIAS_EXPANDED_TYPE",
};
pub const EXPOSED_TYPE_PARAMETER_BOUND = DiagnosticFactory{
    .name = "EXPOSED_TYPE_PARAMETER_BOUND",
    .default_severity = .Error,
    .message_template = "EXPOSED_TYPE_PARAMETER_BOUND",
};
pub const EXPOSED_TYPE_PARAMETER_BOUND_DEPRECATION_WARNING = DiagnosticFactory{
    .name = "EXPOSED_TYPE_PARAMETER_BOUND_DEPRECATION_WARNING",
    .default_severity = .Warning,
    .message_template = "EXPOSED_TYPE_PARAMETER_BOUND_DEPRECATION_WARNING",
};
pub const EXPRESSION_EXPECTED = DiagnosticFactory{
    .name = "EXPRESSION_EXPECTED",
    .default_severity = .Error,
    .message_template = "Only expressions are allowed here.",
};
pub const EXPRESSION_EXPECTED_PACKAGE_FOUND = DiagnosticFactory{
    .name = "EXPRESSION_EXPECTED_PACKAGE_FOUND",
    .default_severity = .Error,
    .message_template = "Expression expected, but package name found.",
};
pub const EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS = DiagnosticFactory{
    .name = "EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS",
    .default_severity = .Error,
    .message_template = "EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS",
};
pub const EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS_WARNING = DiagnosticFactory{
    .name = "EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS_WARNING",
    .default_severity = .Warning,
    .message_template = "EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS_WARNING",
};
pub const EXTENSION_FUNCTION_SHADOWED_BY_MEMBER_PROPERTY_WITH_INVOKE = DiagnosticFactory{
    .name = "EXTENSION_FUNCTION_SHADOWED_BY_MEMBER_PROPERTY_WITH_INVOKE",
    .default_severity = .Warning,
    .message_template = "EXTENSION_FUNCTION_SHADOWED_BY_MEMBER_PROPERTY_WITH_INVOKE",
};
pub const EXTENSION_IN_CLASS_REFERENCE_NOT_ALLOWED = DiagnosticFactory{
    .name = "EXTENSION_IN_CLASS_REFERENCE_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "EXTENSION_IN_CLASS_REFERENCE_NOT_ALLOWED",
};
pub const EXTENSION_PROPERTY_MUST_HAVE_ACCESSORS_OR_BE_ABSTRACT = DiagnosticFactory{
    .name = "EXTENSION_PROPERTY_MUST_HAVE_ACCESSORS_OR_BE_ABSTRACT",
    .default_severity = .Error,
    .message_template = "Extension property must have accessors or be abstract.",
};
pub const EXTENSION_PROPERTY_WITH_BACKING_FIELD = DiagnosticFactory{
    .name = "EXTENSION_PROPERTY_WITH_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "Extension property cannot be initialized because it has no backing field.",
};
pub const EXTENSION_SHADOWED_BY_MEMBER = DiagnosticFactory{
    .name = "EXTENSION_SHADOWED_BY_MEMBER",
    .default_severity = .Warning,
    .message_template = "This extension is shadowed by a member: {0}.",
};
pub const FIELD_INITIALIZER_TYPE_MISMATCH = DiagnosticFactory{
    .name = "FIELD_INITIALIZER_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "FIELD_INITIALIZER_TYPE_MISMATCH",
};
pub const FINAL_SUPERTYPE = DiagnosticFactory{
    .name = "FINAL_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "This type is final, so it cannot be extended.",
};
pub const FINAL_UPPER_BOUND = DiagnosticFactory{
    .name = "FINAL_UPPER_BOUND",
    .default_severity = .Warning,
    .message_template = "FINAL_UPPER_BOUND",
};
pub const FINITE_BOUNDS_VIOLATION = DiagnosticFactory{
    .name = "FINITE_BOUNDS_VIOLATION",
    .default_severity = .Error,
    .message_template = "This type parameter violates the Finite Bound Restriction.",
};
pub const FINITE_BOUNDS_VIOLATION_IN_JAVA = DiagnosticFactory{
    .name = "FINITE_BOUNDS_VIOLATION_IN_JAVA",
    .default_severity = .Warning,
    .message_template = "FINITE_BOUNDS_VIOLATION_IN_JAVA",
};
pub const FLOAT_LITERAL_OUT_OF_RANGE = DiagnosticFactory{
    .name = "FLOAT_LITERAL_OUT_OF_RANGE",
    .default_severity = .Error,
    .message_template = "Value out of range.",
};
pub const FORBIDDEN_IDENTITY_EQUALS = DiagnosticFactory{
    .name = "FORBIDDEN_IDENTITY_EQUALS",
    .default_severity = .Error,
    .message_template = "FORBIDDEN_IDENTITY_EQUALS",
};
pub const FORBIDDEN_IDENTITY_EQUALS_WARNING = DiagnosticFactory{
    .name = "FORBIDDEN_IDENTITY_EQUALS_WARNING",
    .default_severity = .Warning,
    .message_template = "FORBIDDEN_IDENTITY_EQUALS_WARNING",
};
pub const FORBIDDEN_VARARG_PARAMETER_TYPE = DiagnosticFactory{
    .name = "FORBIDDEN_VARARG_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "Prohibited vararg parameter type ''{0}''.",
};
pub const FUNCTION_CALL_EXPECTED = DiagnosticFactory{
    .name = "FUNCTION_CALL_EXPECTED",
    .default_severity = .Error,
    .message_template = "Function invocation ''{0}({1})'' expected.",
};
pub const FUNCTION_DECLARATION_WITH_NO_NAME = DiagnosticFactory{
    .name = "FUNCTION_DECLARATION_WITH_NO_NAME",
    .default_severity = .Error,
    .message_template = "Function declaration must have a name.",
};
pub const FUNCTION_EXPECTED = DiagnosticFactory{
    .name = "FUNCTION_EXPECTED",
    .default_severity = .Error,
    .message_template = "FUNCTION_EXPECTED",
};
pub const FUNCTION_TYPE_OF_TOO_LARGE_ARITY = DiagnosticFactory{
    .name = "FUNCTION_TYPE_OF_TOO_LARGE_ARITY",
    .default_severity = .Error,
    .message_template = "FUNCTION_TYPE_OF_TOO_LARGE_ARITY",
};
pub const FUN_INTERFACE_ABSTRACT_METHOD_WITH_DEFAULT_VALUE = DiagnosticFactory{
    .name = "FUN_INTERFACE_ABSTRACT_METHOD_WITH_DEFAULT_VALUE",
    .default_severity = .Error,
    .message_template = "Functional interface abstract method cannot have a default value.",
};
pub const FUN_INTERFACE_ABSTRACT_METHOD_WITH_TYPE_PARAMETERS = DiagnosticFactory{
    .name = "FUN_INTERFACE_ABSTRACT_METHOD_WITH_TYPE_PARAMETERS",
    .default_severity = .Error,
    .message_template = "Functional interface cannot have an abstract method with type parameters.",
};
pub const FUN_INTERFACE_CANNOT_HAVE_ABSTRACT_PROPERTIES = DiagnosticFactory{
    .name = "FUN_INTERFACE_CANNOT_HAVE_ABSTRACT_PROPERTIES",
    .default_severity = .Error,
    .message_template = "Functional interface cannot have abstract properties.",
};
pub const FUN_INTERFACE_WITH_SUSPEND_FUNCTION = DiagnosticFactory{
    .name = "FUN_INTERFACE_WITH_SUSPEND_FUNCTION",
    .default_severity = .Error,
    .message_template = "Functional interface abstract method cannot have a suspend modifier.",
};
pub const FUN_INTERFACE_WRONG_COUNT_OF_ABSTRACT_MEMBERS = DiagnosticFactory{
    .name = "FUN_INTERFACE_WRONG_COUNT_OF_ABSTRACT_MEMBERS",
    .default_severity = .Error,
    .message_template = "FUN_INTERFACE_WRONG_COUNT_OF_ABSTRACT_MEMBERS",
};
pub const GENERIC_THROWABLE_SUBCLASS = DiagnosticFactory{
    .name = "GENERIC_THROWABLE_SUBCLASS",
    .default_severity = .Error,
    .message_template = "GENERIC_THROWABLE_SUBCLASS",
};
pub const GETTER_VISIBILITY_DIFFERS_FROM_PROPERTY_VISIBILITY = DiagnosticFactory{
    .name = "GETTER_VISIBILITY_DIFFERS_FROM_PROPERTY_VISIBILITY",
    .default_severity = .Error,
    .message_template = "Getter visibility must be the same as property visibility.",
};
pub const HAS_NEXT_FUNCTION_AMBIGUITY = DiagnosticFactory{
    .name = "HAS_NEXT_FUNCTION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "HAS_NEXT_FUNCTION_AMBIGUITY",
};
pub const HAS_NEXT_FUNCTION_NONE_APPLICABLE = DiagnosticFactory{
    .name = "HAS_NEXT_FUNCTION_NONE_APPLICABLE",
    .default_severity = .Error,
    .message_template = "None of the ''hasNext()'' functions is applicable for this expression. Candidates are:{0}",
};
pub const HAS_NEXT_FUNCTION_TYPE_MISMATCH = DiagnosticFactory{
    .name = "HAS_NEXT_FUNCTION_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "HAS_NEXT_FUNCTION_TYPE_MISMATCH",
};
pub const HAS_NEXT_MISSING = DiagnosticFactory{
    .name = "HAS_NEXT_MISSING",
    .default_severity = .Error,
    .message_template = "'hasNext()' cannot be called on 'iterator()'.",
};
pub const IGNORABILITY_ANNOTATIONS_WITH_CHECKER_DISABLED = DiagnosticFactory{
    .name = "IGNORABILITY_ANNOTATIONS_WITH_CHECKER_DISABLED",
    .default_severity = .Error,
    .message_template = "IGNORABILITY_ANNOTATIONS_WITH_CHECKER_DISABLED",
};
pub const ILLEGAL_CONST_EXPRESSION = DiagnosticFactory{
    .name = "ILLEGAL_CONST_EXPRESSION",
    .default_severity = .Error,
    .message_template = "Incorrect const expression.",
};
pub const ILLEGAL_DECLARATION_IN_WHEN_SUBJECT = DiagnosticFactory{
    .name = "ILLEGAL_DECLARATION_IN_WHEN_SUBJECT",
    .default_severity = .Error,
    .message_template = "ILLEGAL_DECLARATION_IN_WHEN_SUBJECT",
};
pub const ILLEGAL_ESCAPE = DiagnosticFactory{
    .name = "ILLEGAL_ESCAPE",
    .default_severity = .Error,
    .message_template = "Unsupported escape sequence.",
};
pub const ILLEGAL_INLINE_PARAMETER_MODIFIER = DiagnosticFactory{
    .name = "ILLEGAL_INLINE_PARAMETER_MODIFIER",
    .default_severity = .Error,
    .message_template = "Modifier is only allowed for function parameters of an inline function.",
};
pub const ILLEGAL_KOTLIN_VERSION_STRING_VALUE = DiagnosticFactory{
    .name = "ILLEGAL_KOTLIN_VERSION_STRING_VALUE",
    .default_severity = .Error,
    .message_template = "ILLEGAL_KOTLIN_VERSION_STRING_VALUE",
};
pub const ILLEGAL_PROJECTION_USAGE = DiagnosticFactory{
    .name = "ILLEGAL_PROJECTION_USAGE",
    .default_severity = .Error,
    .message_template = "Illegal projection usage.",
};
pub const ILLEGAL_RESTRICTED_SUSPENDING_FUNCTION_CALL = DiagnosticFactory{
    .name = "ILLEGAL_RESTRICTED_SUSPENDING_FUNCTION_CALL",
    .default_severity = .Error,
    .message_template = "ILLEGAL_RESTRICTED_SUSPENDING_FUNCTION_CALL",
};
pub const ILLEGAL_SELECTOR = DiagnosticFactory{
    .name = "ILLEGAL_SELECTOR",
    .default_severity = .Error,
    .message_template = "The expression cannot be a selector (cannot occur after a dot).",
};
pub const ILLEGAL_SUSPEND_FUNCTION_CALL = DiagnosticFactory{
    .name = "ILLEGAL_SUSPEND_FUNCTION_CALL",
    .default_severity = .Error,
    .message_template = "ILLEGAL_SUSPEND_FUNCTION_CALL",
};
pub const ILLEGAL_SUSPEND_PROPERTY_ACCESS = DiagnosticFactory{
    .name = "ILLEGAL_SUSPEND_PROPERTY_ACCESS",
    .default_severity = .Error,
    .message_template = "ILLEGAL_SUSPEND_PROPERTY_ACCESS",
};
pub const ILLEGAL_TYPE_ARGUMENT_FOR_VARARG_PARAMETER_WARNING = DiagnosticFactory{
    .name = "ILLEGAL_TYPE_ARGUMENT_FOR_VARARG_PARAMETER_WARNING",
    .default_severity = .Warning,
    .message_template = "ILLEGAL_TYPE_ARGUMENT_FOR_VARARG_PARAMETER_WARNING",
};
pub const ILLEGAL_UNDERSCORE = DiagnosticFactory{
    .name = "ILLEGAL_UNDERSCORE",
    .default_severity = .Error,
    .message_template = "Incorrect usage of underscore in numeric literal.",
};
pub const IMPLEMENTATION_BY_DELEGATION_IN_EXPECT_CLASS = DiagnosticFactory{
    .name = "IMPLEMENTATION_BY_DELEGATION_IN_EXPECT_CLASS",
    .default_severity = .Error,
    .message_template = "Implementation by delegation in expected classes is prohibited.",
};
pub const IMPLICIT_BOXING_IN_IDENTITY_EQUALS = DiagnosticFactory{
    .name = "IMPLICIT_BOXING_IN_IDENTITY_EQUALS",
    .default_severity = .Warning,
    .message_template = "IMPLICIT_BOXING_IN_IDENTITY_EQUALS",
};
pub const IMPLICIT_NOTHING_PROPERTY_TYPE = DiagnosticFactory{
    .name = "IMPLICIT_NOTHING_PROPERTY_TYPE",
    .default_severity = .Error,
    .message_template = "Property type 'Nothing' needs to be specified explicitly.",
};
pub const IMPLICIT_NOTHING_RETURN_TYPE = DiagnosticFactory{
    .name = "IMPLICIT_NOTHING_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "Return type 'Nothing' needs to be specified explicitly.",
};
pub const IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT = DiagnosticFactory{
    .name = "IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT",
    .default_severity = .Warning,
    .message_template = "IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT",
};
pub const IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT_ERROR = DiagnosticFactory{
    .name = "IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT_ERROR",
    .default_severity = .Error,
    .message_template = "IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT_ERROR",
};
pub const INACCESSIBLE_OUTER_CLASS_RECEIVER = DiagnosticFactory{
    .name = "INACCESSIBLE_OUTER_CLASS_RECEIVER",
    .default_severity = .Error,
    .message_template = "INACCESSIBLE_OUTER_CLASS_RECEIVER",
};
pub const INAPPLICABLE_ALL_TARGET = DiagnosticFactory{
    .name = "INAPPLICABLE_ALL_TARGET",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_ALL_TARGET",
};
pub const INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION = DiagnosticFactory{
    .name = "INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION",
};
pub const INAPPLICABLE_CANDIDATE = DiagnosticFactory{
    .name = "INAPPLICABLE_CANDIDATE",
    .default_severity = .Error,
    .message_template = "Inapplicable candidate(s): {0}",
};
pub const INAPPLICABLE_FILE_TARGET = DiagnosticFactory{
    .name = "INAPPLICABLE_FILE_TARGET",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_FILE_TARGET",
};
pub const INAPPLICABLE_INFIX_MODIFIER = DiagnosticFactory{
    .name = "INAPPLICABLE_INFIX_MODIFIER",
    .default_severity = .Error,
    .message_template = "'infix' modifier is inapplicable to this function.",
};
pub const INAPPLICABLE_LATEINIT_MODIFIER = DiagnosticFactory{
    .name = "INAPPLICABLE_LATEINIT_MODIFIER",
    .default_severity = .Error,
    .message_template = "''lateinit'' modifier {0}.",
};
pub const INAPPLICABLE_OPERATOR_MODIFIER = DiagnosticFactory{
    .name = "INAPPLICABLE_OPERATOR_MODIFIER",
    .default_severity = .Error,
    .message_template = "''operator'' modifier is not applicable to function: {0}.",
};
pub const INAPPLICABLE_OPERATOR_MODIFIER_WARNING = DiagnosticFactory{
    .name = "INAPPLICABLE_OPERATOR_MODIFIER_WARNING",
    .default_severity = .Warning,
    .message_template = "INAPPLICABLE_OPERATOR_MODIFIER_WARNING",
};
pub const INAPPLICABLE_PARAM_TARGET = DiagnosticFactory{
    .name = "INAPPLICABLE_PARAM_TARGET",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_PARAM_TARGET",
};
pub const INAPPLICABLE_TARGET_ON_PROPERTY = DiagnosticFactory{
    .name = "INAPPLICABLE_TARGET_ON_PROPERTY",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_TARGET_ON_PROPERTY",
};
pub const INAPPLICABLE_TARGET_ON_PROPERTY_WARNING = DiagnosticFactory{
    .name = "INAPPLICABLE_TARGET_ON_PROPERTY_WARNING",
    .default_severity = .Warning,
    .message_template = "INAPPLICABLE_TARGET_ON_PROPERTY_WARNING",
};
pub const INAPPLICABLE_TARGET_PROPERTY_HAS_NO_BACKING_FIELD = DiagnosticFactory{
    .name = "INAPPLICABLE_TARGET_PROPERTY_HAS_NO_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_TARGET_PROPERTY_HAS_NO_BACKING_FIELD",
};
pub const INAPPLICABLE_TARGET_PROPERTY_HAS_NO_DELEGATE = DiagnosticFactory{
    .name = "INAPPLICABLE_TARGET_PROPERTY_HAS_NO_DELEGATE",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_TARGET_PROPERTY_HAS_NO_DELEGATE",
};
pub const INAPPLICABLE_TARGET_PROPERTY_IMMUTABLE = DiagnosticFactory{
    .name = "INAPPLICABLE_TARGET_PROPERTY_IMMUTABLE",
    .default_severity = .Error,
    .message_template = "INAPPLICABLE_TARGET_PROPERTY_IMMUTABLE",
};
pub const INCOMPATIBLE_CLASS = DiagnosticFactory{
    .name = "INCOMPATIBLE_CLASS",
    .default_severity = .Error,
    .message_template = "INCOMPATIBLE_CLASS",
};
pub const INCOMPATIBLE_ENUM_COMPARISON = DiagnosticFactory{
    .name = "INCOMPATIBLE_ENUM_COMPARISON",
    .default_severity = .Warning,
    .message_template = "INCOMPATIBLE_ENUM_COMPARISON",
};
pub const INCOMPATIBLE_ENUM_COMPARISON_ERROR = DiagnosticFactory{
    .name = "INCOMPATIBLE_ENUM_COMPARISON_ERROR",
    .default_severity = .Error,
    .message_template = "INCOMPATIBLE_ENUM_COMPARISON_ERROR",
};
pub const INCOMPATIBLE_MODIFIERS = DiagnosticFactory{
    .name = "INCOMPATIBLE_MODIFIERS",
    .default_severity = .Error,
    .message_template = "Modifier ''{0}'' is incompatible with ''{1}''.",
};
pub const INCOMPATIBLE_TYPES = DiagnosticFactory{
    .name = "INCOMPATIBLE_TYPES",
    .default_severity = .Error,
    .message_template = "Incompatible types ''{0}'' and ''{1}''.",
};
pub const INCOMPATIBLE_TYPES_WARNING = DiagnosticFactory{
    .name = "INCOMPATIBLE_TYPES_WARNING",
    .default_severity = .Warning,
    .message_template = "Potentially incompatible types ''{0}'' and ''{1}''.",
};
pub const INCONSISTENT_BACKING_FIELD_TYPE = DiagnosticFactory{
    .name = "INCONSISTENT_BACKING_FIELD_TYPE",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_BACKING_FIELD_TYPE",
};
pub const INCONSISTENT_PARAMETER_TYPES_IN_OF_OVERLOADS = DiagnosticFactory{
    .name = "INCONSISTENT_PARAMETER_TYPES_IN_OF_OVERLOADS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_PARAMETER_TYPES_IN_OF_OVERLOADS",
};
pub const INCONSISTENT_RETURN_TYPES_IN_OF_OVERLOADS = DiagnosticFactory{
    .name = "INCONSISTENT_RETURN_TYPES_IN_OF_OVERLOADS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_RETURN_TYPES_IN_OF_OVERLOADS",
};
pub const INCONSISTENT_SUSPEND_IN_OF_OVERLOADS = DiagnosticFactory{
    .name = "INCONSISTENT_SUSPEND_IN_OF_OVERLOADS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_SUSPEND_IN_OF_OVERLOADS",
};
pub const INCONSISTENT_TYPE_PARAMETERS_IN_OF_OVERLOADS = DiagnosticFactory{
    .name = "INCONSISTENT_TYPE_PARAMETERS_IN_OF_OVERLOADS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_TYPE_PARAMETERS_IN_OF_OVERLOADS",
};
pub const INCONSISTENT_TYPE_PARAMETER_BOUNDS = DiagnosticFactory{
    .name = "INCONSISTENT_TYPE_PARAMETER_BOUNDS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_TYPE_PARAMETER_BOUNDS",
};
pub const INCONSISTENT_TYPE_PARAMETER_VALUES = DiagnosticFactory{
    .name = "INCONSISTENT_TYPE_PARAMETER_VALUES",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_TYPE_PARAMETER_VALUES",
};
pub const INCONSISTENT_VISIBILITY_IN_OF_OVERLOADS = DiagnosticFactory{
    .name = "INCONSISTENT_VISIBILITY_IN_OF_OVERLOADS",
    .default_severity = .Error,
    .message_template = "INCONSISTENT_VISIBILITY_IN_OF_OVERLOADS",
};
pub const INCORRECT_CHARACTER_LITERAL = DiagnosticFactory{
    .name = "INCORRECT_CHARACTER_LITERAL",
    .default_severity = .Error,
    .message_template = "Incorrect character literal.",
};
pub const INCORRECT_LEFT_COMPONENT_OF_INTERSECTION = DiagnosticFactory{
    .name = "INCORRECT_LEFT_COMPONENT_OF_INTERSECTION",
    .default_severity = .Error,
    .message_template = "INCORRECT_LEFT_COMPONENT_OF_INTERSECTION",
};
pub const INCORRECT_RIGHT_COMPONENT_OF_INTERSECTION = DiagnosticFactory{
    .name = "INCORRECT_RIGHT_COMPONENT_OF_INTERSECTION",
    .default_severity = .Error,
    .message_template = "INCORRECT_RIGHT_COMPONENT_OF_INTERSECTION",
};
pub const INCORRECT_TYPE_PARAMETER_OF_PROPERTY = DiagnosticFactory{
    .name = "INCORRECT_TYPE_PARAMETER_OF_PROPERTY",
    .default_severity = .Error,
    .message_template = "Type parameter of a property must be used in its receiver type or context parameters.",
};
pub const INC_DEC_SHOULD_NOT_RETURN_UNIT = DiagnosticFactory{
    .name = "INC_DEC_SHOULD_NOT_RETURN_UNIT",
    .default_severity = .Error,
    .message_template = "INC_DEC_SHOULD_NOT_RETURN_UNIT",
};
pub const INEFFICIENT_EQUALS_OVERRIDING_IN_VALUE_CLASS = DiagnosticFactory{
    .name = "INEFFICIENT_EQUALS_OVERRIDING_IN_VALUE_CLASS",
    .default_severity = .Warning,
    .message_template = "INEFFICIENT_EQUALS_OVERRIDING_IN_VALUE_CLASS",
};
pub const INFERENCE_ERROR = DiagnosticFactory{
    .name = "INFERENCE_ERROR",
    .default_severity = .Error,
    .message_template = "Inference error.",
};
pub const INFERRED_TYPE_VARIABLE_INTO_POSSIBLE_EMPTY_INTERSECTION = DiagnosticFactory{
    .name = "INFERRED_TYPE_VARIABLE_INTO_POSSIBLE_EMPTY_INTERSECTION",
    .default_severity = .Warning,
    .message_template = "INFERRED_TYPE_VARIABLE_INTO_POSSIBLE_EMPTY_INTERSECTION",
};
pub const INFIX_MODIFIER_REQUIRED = DiagnosticFactory{
    .name = "INFIX_MODIFIER_REQUIRED",
    .default_severity = .Error,
    .message_template = "''infix'' modifier is required on ''{0}''.",
};
pub const INITIALIZATION_BEFORE_DECLARATION = DiagnosticFactory{
    .name = "INITIALIZATION_BEFORE_DECLARATION",
    .default_severity = .Error,
    .message_template = "Variable cannot be initialized before declaration.",
};
pub const INITIALIZATION_BEFORE_DECLARATION_WARNING = DiagnosticFactory{
    .name = "INITIALIZATION_BEFORE_DECLARATION_WARNING",
    .default_severity = .Warning,
    .message_template = "INITIALIZATION_BEFORE_DECLARATION_WARNING",
};
pub const INITIALIZER_REQUIRED_FOR_DESTRUCTURING_DECLARATION = DiagnosticFactory{
    .name = "INITIALIZER_REQUIRED_FOR_DESTRUCTURING_DECLARATION",
    .default_severity = .Error,
    .message_template = "INITIALIZER_REQUIRED_FOR_DESTRUCTURING_DECLARATION",
};
pub const INITIALIZER_TYPE_MISMATCH = DiagnosticFactory{
    .name = "INITIALIZER_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "INITIALIZER_TYPE_MISMATCH",
};
pub const INLINE_CLASS_CONSTRUCTOR_WRONG_PARAMETERS_SIZE = DiagnosticFactory{
    .name = "INLINE_CLASS_CONSTRUCTOR_WRONG_PARAMETERS_SIZE",
    .default_severity = .Error,
    .message_template = "Inline class must have exactly one primary constructor parameter.",
};
pub const INLINE_CLASS_DEPRECATED = DiagnosticFactory{
    .name = "INLINE_CLASS_DEPRECATED",
    .default_severity = .Warning,
    .message_template = "INLINE_CLASS_DEPRECATED",
};
pub const INLINE_PROPERTY_WITH_BACKING_FIELD = DiagnosticFactory{
    .name = "INLINE_PROPERTY_WITH_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "Inline property cannot have a backing field.",
};
pub const INLINE_SUSPEND_FUNCTION_TYPE_UNSUPPORTED = DiagnosticFactory{
    .name = "INLINE_SUSPEND_FUNCTION_TYPE_UNSUPPORTED",
    .default_severity = .Error,
    .message_template = "INLINE_SUSPEND_FUNCTION_TYPE_UNSUPPORTED",
};
pub const INNER_CLASS_CONSTRUCTOR_NO_RECEIVER = DiagnosticFactory{
    .name = "INNER_CLASS_CONSTRUCTOR_NO_RECEIVER",
    .default_severity = .Error,
    .message_template = "INNER_CLASS_CONSTRUCTOR_NO_RECEIVER",
};
pub const INNER_CLASS_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "INNER_CLASS_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "Value class cannot have inner classes.",
};
pub const INNER_CLASS_OF_GENERIC_THROWABLE_SUBCLASS = DiagnosticFactory{
    .name = "INNER_CLASS_OF_GENERIC_THROWABLE_SUBCLASS",
    .default_severity = .Error,
    .message_template = "INNER_CLASS_OF_GENERIC_THROWABLE_SUBCLASS",
};
pub const INSTANCE_ACCESS_BEFORE_SUPER_CALL = DiagnosticFactory{
    .name = "INSTANCE_ACCESS_BEFORE_SUPER_CALL",
    .default_severity = .Error,
    .message_template = "INSTANCE_ACCESS_BEFORE_SUPER_CALL",
};
pub const INTERFACE_AS_FUNCTION = DiagnosticFactory{
    .name = "INTERFACE_AS_FUNCTION",
    .default_severity = .Error,
    .message_template = "Interface ''{0}'' does not have constructors.",
};
pub const INTERFACE_WITH_SUPERCLASS = DiagnosticFactory{
    .name = "INTERFACE_WITH_SUPERCLASS",
    .default_severity = .Error,
    .message_template = "An interface cannot extend a class.",
};
pub const INT_LITERAL_OUT_OF_RANGE = DiagnosticFactory{
    .name = "INT_LITERAL_OUT_OF_RANGE",
    .default_severity = .Error,
    .message_template = "Value out of range.",
};
pub const INT_LITERAL_WITH_LEADING_ZEROS = DiagnosticFactory{
    .name = "INT_LITERAL_WITH_LEADING_ZEROS",
    .default_severity = .Error,
    .message_template = "INT_LITERAL_WITH_LEADING_ZEROS",
};
pub const INVALID_CHARACTERS = DiagnosticFactory{
    .name = "INVALID_CHARACTERS",
    .default_severity = .Error,
    .message_template = "INVALID_CHARACTERS",
};
pub const INVALID_DEFAULT_FUNCTIONAL_PARAMETER_FOR_INLINE = DiagnosticFactory{
    .name = "INVALID_DEFAULT_FUNCTIONAL_PARAMETER_FOR_INLINE",
    .default_severity = .Error,
    .message_template = "INVALID_DEFAULT_FUNCTIONAL_PARAMETER_FOR_INLINE",
};
pub const INVALID_DEFAULT_VALUE_DEPENDENCY = DiagnosticFactory{
    .name = "INVALID_DEFAULT_VALUE_DEPENDENCY",
    .default_severity = .Error,
    .message_template = "INVALID_DEFAULT_VALUE_DEPENDENCY",
};
pub const INVALID_IF_AS_EXPRESSION = DiagnosticFactory{
    .name = "INVALID_IF_AS_EXPRESSION",
    .default_severity = .Error,
    .message_template = "'if' must have both main and 'else' branches when used as an expression.",
};
pub const INVALID_NON_OPTIONAL_PARAMETER_POSITION = DiagnosticFactory{
    .name = "INVALID_NON_OPTIONAL_PARAMETER_POSITION",
    .default_severity = .Error,
    .message_template = "INVALID_NON_OPTIONAL_PARAMETER_POSITION",
};
pub const INVALID_TYPE_OF_ANNOTATION_MEMBER = DiagnosticFactory{
    .name = "INVALID_TYPE_OF_ANNOTATION_MEMBER",
    .default_severity = .Error,
    .message_template = "Invalid type of annotation member.",
};
pub const INVALID_VERSIONING_ON_ANNOTATION_CLASS = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_ANNOTATION_CLASS",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_ANNOTATION_CLASS",
};
pub const INVALID_VERSIONING_ON_LOCAL_FUNCTION = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_LOCAL_FUNCTION",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_LOCAL_FUNCTION",
};
pub const INVALID_VERSIONING_ON_NONFINAL_CLASS = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_NONFINAL_CLASS",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_NONFINAL_CLASS",
};
pub const INVALID_VERSIONING_ON_NONFINAL_FUNCTION = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_NONFINAL_FUNCTION",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_NONFINAL_FUNCTION",
};
pub const INVALID_VERSIONING_ON_NON_OPTIONAL = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_NON_OPTIONAL",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_NON_OPTIONAL",
};
pub const INVALID_VERSIONING_ON_RECEIVER_OR_CONTEXT_PARAMETER_POSITION = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_RECEIVER_OR_CONTEXT_PARAMETER_POSITION",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_RECEIVER_OR_CONTEXT_PARAMETER_POSITION",
};
pub const INVALID_VERSIONING_ON_VALUE_CLASS_PARAMETER = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_VALUE_CLASS_PARAMETER",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_VALUE_CLASS_PARAMETER",
};
pub const INVALID_VERSIONING_ON_VARARG = DiagnosticFactory{
    .name = "INVALID_VERSIONING_ON_VARARG",
    .default_severity = .Error,
    .message_template = "INVALID_VERSIONING_ON_VARARG",
};
pub const INVISIBLE_ABSTRACT_MEMBER_FROM_SUPER_ERROR = DiagnosticFactory{
    .name = "INVISIBLE_ABSTRACT_MEMBER_FROM_SUPER_ERROR",
    .default_severity = .Error,
    .message_template = "INVISIBLE_ABSTRACT_MEMBER_FROM_SUPER_ERROR",
};
pub const INVISIBLE_REFERENCE = DiagnosticFactory{
    .name = "INVISIBLE_REFERENCE",
    .default_severity = .Error,
    .message_template = "INVISIBLE_REFERENCE",
};
pub const INVISIBLE_REFERENCE_WARNING = DiagnosticFactory{
    .name = "INVISIBLE_REFERENCE_WARNING",
    .default_severity = .Warning,
    .message_template = "INVISIBLE_REFERENCE_WARNING",
};
pub const INVISIBLE_SETTER = DiagnosticFactory{
    .name = "INVISIBLE_SETTER",
    .default_severity = .Error,
    .message_template = "INVISIBLE_SETTER",
};
pub const IR_WITH_UNSTABLE_ABI_COMPILED_CLASS = DiagnosticFactory{
    .name = "IR_WITH_UNSTABLE_ABI_COMPILED_CLASS",
    .default_severity = .Error,
    .message_template = "IR_WITH_UNSTABLE_ABI_COMPILED_CLASS",
};
pub const IS_ENUM_ENTRY = DiagnosticFactory{
    .name = "IS_ENUM_ENTRY",
    .default_severity = .Error,
    .message_template = "'is' over enum entry is prohibited. Use comparison instead.",
};
pub const ITERATOR_AMBIGUITY = DiagnosticFactory{
    .name = "ITERATOR_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "ITERATOR_AMBIGUITY",
};
pub const ITERATOR_MISSING = DiagnosticFactory{
    .name = "ITERATOR_MISSING",
    .default_severity = .Error,
    .message_template = "For-loop range must have an 'iterator()' method.",
};
pub const ITERATOR_ON_NULLABLE = DiagnosticFactory{
    .name = "ITERATOR_ON_NULLABLE",
    .default_severity = .Error,
    .message_template = "ITERATOR_ON_NULLABLE",
};
pub const KCLASS_WITH_NULLABLE_TYPE_PARAMETER_IN_SIGNATURE = DiagnosticFactory{
    .name = "KCLASS_WITH_NULLABLE_TYPE_PARAMETER_IN_SIGNATURE",
    .default_severity = .Error,
    .message_template = "KCLASS_WITH_NULLABLE_TYPE_PARAMETER_IN_SIGNATURE",
};
pub const KOTLIN_ACTUAL_ANNOTATION_HAS_NO_EFFECT_IN_KOTLIN = DiagnosticFactory{
    .name = "KOTLIN_ACTUAL_ANNOTATION_HAS_NO_EFFECT_IN_KOTLIN",
    .default_severity = .Error,
    .message_template = "KOTLIN_ACTUAL_ANNOTATION_HAS_NO_EFFECT_IN_KOTLIN",
};
pub const K_SUSPEND_FUNCTION_TYPE_OF_DANGEROUSLY_LARGE_ARITY = DiagnosticFactory{
    .name = "K_SUSPEND_FUNCTION_TYPE_OF_DANGEROUSLY_LARGE_ARITY",
    .default_severity = .Warning,
    .message_template = "K_SUSPEND_FUNCTION_TYPE_OF_DANGEROUSLY_LARGE_ARITY",
};
pub const LABEL_NAME_CLASH = DiagnosticFactory{
    .name = "LABEL_NAME_CLASH",
    .default_severity = .Warning,
    .message_template = "There is more than one label with such a name in this scope.",
};
pub const LATEINIT_FIELD_IN_VAL_PROPERTY = DiagnosticFactory{
    .name = "LATEINIT_FIELD_IN_VAL_PROPERTY",
    .default_severity = .Error,
    .message_template = "LATEINIT_FIELD_IN_VAL_PROPERTY",
};
pub const LATEINIT_INTRINSIC_CALL_IN_INLINE_FUNCTION = DiagnosticFactory{
    .name = "LATEINIT_INTRINSIC_CALL_IN_INLINE_FUNCTION",
    .default_severity = .Error,
    .message_template = "This declaration cannot be used inside an inline function.",
};
pub const LATEINIT_INTRINSIC_CALL_ON_NON_ACCESSIBLE_PROPERTY = DiagnosticFactory{
    .name = "LATEINIT_INTRINSIC_CALL_ON_NON_ACCESSIBLE_PROPERTY",
    .default_severity = .Error,
    .message_template = "Backing field of ''{0}'' is not accessible at this point.",
};
pub const LATEINIT_INTRINSIC_CALL_ON_NON_LATEINIT = DiagnosticFactory{
    .name = "LATEINIT_INTRINSIC_CALL_ON_NON_LATEINIT",
    .default_severity = .Error,
    .message_template = "This declaration can only be called on a reference to a 'lateinit' property.",
};
pub const LATEINIT_INTRINSIC_CALL_ON_NON_LITERAL = DiagnosticFactory{
    .name = "LATEINIT_INTRINSIC_CALL_ON_NON_LITERAL",
    .default_severity = .Error,
    .message_template = "This declaration can only be called on a property literal (e.g. 'Foo::bar').",
};
pub const LATEINIT_NULLABLE_BACKING_FIELD = DiagnosticFactory{
    .name = "LATEINIT_NULLABLE_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "LATEINIT_NULLABLE_BACKING_FIELD",
};
pub const LATEINIT_PROPERTY_FIELD_DECLARATION_WITH_INITIALIZER = DiagnosticFactory{
    .name = "LATEINIT_PROPERTY_FIELD_DECLARATION_WITH_INITIALIZER",
    .default_severity = .Error,
    .message_template = "LATEINIT_PROPERTY_FIELD_DECLARATION_WITH_INITIALIZER",
};
pub const LATEINIT_PROPERTY_WITHOUT_TYPE = DiagnosticFactory{
    .name = "LATEINIT_PROPERTY_WITHOUT_TYPE",
    .default_severity = .Error,
    .message_template = "LATEINIT_PROPERTY_WITHOUT_TYPE",
};
pub const LEAKED_IN_PLACE_LAMBDA = DiagnosticFactory{
    .name = "LEAKED_IN_PLACE_LAMBDA",
    .default_severity = .Warning,
    .message_template = "Leaked in-place lambda ''{0}''.",
};
pub const LOCAL_ANNOTATION_CLASS_ERROR = DiagnosticFactory{
    .name = "LOCAL_ANNOTATION_CLASS_ERROR",
    .default_severity = .Error,
    .message_template = "Annotation class cannot be local.",
};
pub const LOCAL_EXTENSION_PROPERTY = DiagnosticFactory{
    .name = "LOCAL_EXTENSION_PROPERTY",
    .default_severity = .Error,
    .message_template = "Local extension properties are prohibited.",
};
pub const LOCAL_INTERFACE_NOT_ALLOWED = DiagnosticFactory{
    .name = "LOCAL_INTERFACE_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "LOCAL_INTERFACE_NOT_ALLOWED",
};
pub const LOCAL_OBJECT_NOT_ALLOWED = DiagnosticFactory{
    .name = "LOCAL_OBJECT_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "LOCAL_OBJECT_NOT_ALLOWED",
};
pub const LOCAL_VARIABLE_WITH_TYPE_PARAMETERS = DiagnosticFactory{
    .name = "LOCAL_VARIABLE_WITH_TYPE_PARAMETERS",
    .default_severity = .Error,
    .message_template = "Local variables cannot have type parameters.",
};
pub const LOCAL_VARIABLE_WITH_TYPE_PARAMETERS_WARNING = DiagnosticFactory{
    .name = "LOCAL_VARIABLE_WITH_TYPE_PARAMETERS_WARNING",
    .default_severity = .Warning,
    .message_template = "Type parameters for local variables are deprecated.",
};
pub const MANY_CLASSES_IN_SUPERTYPE_LIST = DiagnosticFactory{
    .name = "MANY_CLASSES_IN_SUPERTYPE_LIST",
    .default_severity = .Error,
    .message_template = "Only one class can appear in a supertype list.",
};
pub const MANY_COMPANION_OBJECTS = DiagnosticFactory{
    .name = "MANY_COMPANION_OBJECTS",
    .default_severity = .Error,
    .message_template = "Only one companion object is allowed per class.",
};
pub const MANY_IMPL_MEMBER_NOT_IMPLEMENTED = DiagnosticFactory{
    .name = "MANY_IMPL_MEMBER_NOT_IMPLEMENTED",
    .default_severity = .Error,
    .message_template = "MANY_IMPL_MEMBER_NOT_IMPLEMENTED",
};
pub const MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED = DiagnosticFactory{
    .name = "MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED",
    .default_severity = .Error,
    .message_template = "MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED",
};
pub const MANY_LAMBDA_EXPRESSION_ARGUMENTS = DiagnosticFactory{
    .name = "MANY_LAMBDA_EXPRESSION_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "Only one lambda expression is allowed outside a parenthesized argument list.",
};
pub const MEMBER_PROJECTED_OUT = DiagnosticFactory{
    .name = "MEMBER_PROJECTED_OUT",
    .default_severity = .Error,
    .message_template = "MEMBER_PROJECTED_OUT",
};
pub const METHOD_OF_ANY_IMPLEMENTED_IN_INTERFACE = DiagnosticFactory{
    .name = "METHOD_OF_ANY_IMPLEMENTED_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Interfaces cannot implement a method of 'Any'.",
};
pub const MISPLACED_TYPE_PARAMETER_CONSTRAINTS = DiagnosticFactory{
    .name = "MISPLACED_TYPE_PARAMETER_CONSTRAINTS",
    .default_severity = .Warning,
    .message_template = "MISPLACED_TYPE_PARAMETER_CONSTRAINTS",
};
pub const MISSING_BRANCH_FOR_NON_ABSTRACT_SEALED_CLASS = DiagnosticFactory{
    .name = "MISSING_BRANCH_FOR_NON_ABSTRACT_SEALED_CLASS",
    .default_severity = .Warning,
    .message_template = "MISSING_BRANCH_FOR_NON_ABSTRACT_SEALED_CLASS",
};
pub const MISSING_CONSTRUCTOR_KEYWORD = DiagnosticFactory{
    .name = "MISSING_CONSTRUCTOR_KEYWORD",
    .default_severity = .Error,
    .message_template = "Use the 'constructor' keyword after the modifiers of the primary constructor.",
};
pub const MISSING_DEPENDENCY_CLASS = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_CLASS",
    .default_severity = .Error,
    .message_template = "MISSING_DEPENDENCY_CLASS",
};
pub const MISSING_DEPENDENCY_CLASS_IN_EXPRESSION_TYPE = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_CLASS_IN_EXPRESSION_TYPE",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_CLASS_IN_EXPRESSION_TYPE",
};
pub const MISSING_DEPENDENCY_CLASS_IN_LAMBDA_PARAMETER = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_CLASS_IN_LAMBDA_PARAMETER",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_CLASS_IN_LAMBDA_PARAMETER",
};
pub const MISSING_DEPENDENCY_CLASS_IN_LAMBDA_RECEIVER = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_CLASS_IN_LAMBDA_RECEIVER",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_CLASS_IN_LAMBDA_RECEIVER",
};
pub const MISSING_DEPENDENCY_CLASS_IN_TYPEALIAS = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_CLASS_IN_TYPEALIAS",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_CLASS_IN_TYPEALIAS",
};
pub const MISSING_DEPENDENCY_SUPERCLASS = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_SUPERCLASS",
    .default_severity = .Error,
    .message_template = "MISSING_DEPENDENCY_SUPERCLASS",
};
pub const MISSING_DEPENDENCY_SUPERCLASS_IN_TYPE_ARGUMENT = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_SUPERCLASS_IN_TYPE_ARGUMENT",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_SUPERCLASS_IN_TYPE_ARGUMENT",
};
pub const MISSING_DEPENDENCY_SUPERCLASS_WARNING = DiagnosticFactory{
    .name = "MISSING_DEPENDENCY_SUPERCLASS_WARNING",
    .default_severity = .Warning,
    .message_template = "MISSING_DEPENDENCY_SUPERCLASS_WARNING",
};
pub const MISSING_STDLIB_CLASS = DiagnosticFactory{
    .name = "MISSING_STDLIB_CLASS",
    .default_severity = .Error,
    .message_template = "Missing stdlib class.",
};
pub const MISSING_VAL_ON_ANNOTATION_PARAMETER = DiagnosticFactory{
    .name = "MISSING_VAL_ON_ANNOTATION_PARAMETER",
    .default_severity = .Error,
    .message_template = "'val' keyword is missing in annotation parameter.",
};
pub const MIXING_FUNCTIONAL_KINDS_IN_SUPERTYPES = DiagnosticFactory{
    .name = "MIXING_FUNCTIONAL_KINDS_IN_SUPERTYPES",
    .default_severity = .Error,
    .message_template = "MIXING_FUNCTIONAL_KINDS_IN_SUPERTYPES",
};
pub const MIXING_NAMED_AND_POSITIONAL_ARGUMENTS = DiagnosticFactory{
    .name = "MIXING_NAMED_AND_POSITIONAL_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "MIXING_NAMED_AND_POSITIONAL_ARGUMENTS",
};
pub const MIXING_SUSPEND_AND_NON_SUSPEND_SUPERTYPES = DiagnosticFactory{
    .name = "MIXING_SUSPEND_AND_NON_SUSPEND_SUPERTYPES",
    .default_severity = .Error,
    .message_template = "Mixing suspend and non-suspend supertypes is not allowed.",
};
pub const MODIFIER_FORM_FOR_NON_BUILT_IN_SUSPEND = DiagnosticFactory{
    .name = "MODIFIER_FORM_FOR_NON_BUILT_IN_SUSPEND",
    .default_severity = .Error,
    .message_template = "MODIFIER_FORM_FOR_NON_BUILT_IN_SUSPEND",
};
pub const MULTIPLE_CONTEXT_LISTS = DiagnosticFactory{
    .name = "MULTIPLE_CONTEXT_LISTS",
    .default_severity = .Error,
    .message_template = "MULTIPLE_CONTEXT_LISTS",
};
pub const MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES = DiagnosticFactory{
    .name = "MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES",
    .default_severity = .Error,
    .message_template = "MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES",
};
pub const MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES_WHEN_NO_EXPLICIT_OVERRIDE = DiagnosticFactory{
    .name = "MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES_WHEN_NO_EXPLICIT_OVERRIDE",
    .default_severity = .Error,
    .message_template = "MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES_WHEN_NO_EXPLICIT_OVERRIDE",
};
pub const MULTIPLE_LABELS_ARE_FORBIDDEN = DiagnosticFactory{
    .name = "MULTIPLE_LABELS_ARE_FORBIDDEN",
    .default_severity = .Error,
    .message_template = "Multiple labels per statement are forbidden.",
};
pub const MULTIPLE_VARARG_OVERLOADS_OF_OPERATOR_OF = DiagnosticFactory{
    .name = "MULTIPLE_VARARG_OVERLOADS_OF_OPERATOR_OF",
    .default_severity = .Error,
    .message_template = "Only one overload of operator 'of' is allowed to have 'vararg' parameters.",
};
pub const MULTIPLE_VARARG_PARAMETERS = DiagnosticFactory{
    .name = "MULTIPLE_VARARG_PARAMETERS",
    .default_severity = .Error,
    .message_template = "Multiple vararg parameters are prohibited.",
};
pub const MULTI_FIELD_VALUE_CLASS_PRIMARY_CONSTRUCTOR_DEFAULT_PARAMETER = DiagnosticFactory{
    .name = "MULTI_FIELD_VALUE_CLASS_PRIMARY_CONSTRUCTOR_DEFAULT_PARAMETER",
    .default_severity = .Error,
    .message_template = "MULTI_FIELD_VALUE_CLASS_PRIMARY_CONSTRUCTOR_DEFAULT_PARAMETER",
};
pub const MUST_BE_INITIALIZED = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED",
    .default_severity = .Error,
    .message_template = "Property must be initialized.",
};
pub const MUST_BE_INITIALIZED_OR_BE_ABSTRACT = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_BE_ABSTRACT",
    .default_severity = .Error,
    .message_template = "Property must be initialized or be abstract.",
};
pub const MUST_BE_INITIALIZED_OR_BE_ABSTRACT_WARNING = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_BE_ABSTRACT_WARNING",
    .default_severity = .Warning,
    .message_template = "MUST_BE_INITIALIZED_OR_BE_ABSTRACT_WARNING",
};
pub const MUST_BE_INITIALIZED_OR_BE_FINAL = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_BE_FINAL",
    .default_severity = .Error,
    .message_template = "Property must be initialized or be final.",
};
pub const MUST_BE_INITIALIZED_OR_BE_FINAL_WARNING = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_BE_FINAL_WARNING",
    .default_severity = .Warning,
    .message_template = "MUST_BE_INITIALIZED_OR_BE_FINAL_WARNING",
};
pub const MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT",
    .default_severity = .Error,
    .message_template = "Property must be initialized, be final, or be abstract.",
};
pub const MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT_WARNING = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT_WARNING",
    .default_severity = .Warning,
    .message_template = "MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT_WARNING",
};
pub const MUST_BE_INITIALIZED_WARNING = DiagnosticFactory{
    .name = "MUST_BE_INITIALIZED_WARNING",
    .default_severity = .Warning,
    .message_template = "MUST_BE_INITIALIZED_WARNING",
};
pub const MUTABLE_PROPERTY_WITH_CAPTURED_TYPE = DiagnosticFactory{
    .name = "MUTABLE_PROPERTY_WITH_CAPTURED_TYPE",
    .default_severity = .Warning,
    .message_template = "Captured type in mutable property reference. Usages of 'set' may lead to cast exceptions.",
};
pub const NAMED_ARGUMENTS_NOT_ALLOWED = DiagnosticFactory{
    .name = "NAMED_ARGUMENTS_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Named arguments are prohibited for {0}.",
};
pub const NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE = DiagnosticFactory{
    .name = "NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE",
    .default_severity = .Error,
    .message_template = "NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE",
};
pub const NAMED_PARAMETER_NOT_FOUND = DiagnosticFactory{
    .name = "NAMED_PARAMETER_NOT_FOUND",
    .default_severity = .Error,
    .message_template = "No parameter with name ''{0}'' found.",
};
pub const NAME_BASED_DESTRUCTURING_UNDERSCORE_WITHOUT_RENAMING = DiagnosticFactory{
    .name = "NAME_BASED_DESTRUCTURING_UNDERSCORE_WITHOUT_RENAMING",
    .default_severity = .Error,
    .message_template = "Underscore in name-based destructuring without renaming is forbidden.",
};
pub const NAME_FOR_AMBIGUOUS_PARAMETER = DiagnosticFactory{
    .name = "NAME_FOR_AMBIGUOUS_PARAMETER",
    .default_severity = .Error,
    .message_template = "Named argument is prohibited for parameter with an ambiguous name.",
};
pub const NAME_IN_CONSTRAINT_IS_NOT_A_TYPE_PARAMETER = DiagnosticFactory{
    .name = "NAME_IN_CONSTRAINT_IS_NOT_A_TYPE_PARAMETER",
    .default_severity = .Error,
    .message_template = "NAME_IN_CONSTRAINT_IS_NOT_A_TYPE_PARAMETER",
};
pub const NESTED_CLASS_ACCESSED_VIA_INSTANCE_REFERENCE = DiagnosticFactory{
    .name = "NESTED_CLASS_ACCESSED_VIA_INSTANCE_REFERENCE",
    .default_severity = .Error,
    .message_template = "NESTED_CLASS_ACCESSED_VIA_INSTANCE_REFERENCE",
};
pub const NESTED_CLASS_NOT_ALLOWED = DiagnosticFactory{
    .name = "NESTED_CLASS_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "''{0}'' is prohibited here.",
};
pub const NEWER_VERSION_IN_SINCE_KOTLIN = DiagnosticFactory{
    .name = "NEWER_VERSION_IN_SINCE_KOTLIN",
    .default_severity = .Warning,
    .message_template = "The version is greater than the specified API version {0}.",
};
pub const NEW_INFERENCE_ERROR = DiagnosticFactory{
    .name = "NEW_INFERENCE_ERROR",
    .default_severity = .Error,
    .message_template = "New inference error [{0}].",
};
pub const NEXT_AMBIGUITY = DiagnosticFactory{
    .name = "NEXT_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "NEXT_AMBIGUITY",
};
pub const NEXT_MISSING = DiagnosticFactory{
    .name = "NEXT_MISSING",
    .default_severity = .Error,
    .message_template = "Method 'next()' cannot be called on 'iterator()'.",
};
pub const NEXT_NONE_APPLICABLE = DiagnosticFactory{
    .name = "NEXT_NONE_APPLICABLE",
    .default_severity = .Error,
    .message_template = "None of the ''next()'' functions is applicable for this expression. Candidates are:{0}",
};
pub const NONE_APPLICABLE = DiagnosticFactory{
    .name = "NONE_APPLICABLE",
    .default_severity = .Error,
    .message_template = "None of the following candidates is applicable:\\n\\n{0}",
};
pub const NON_ABSTRACT_FUNCTION_WITH_NO_BODY = DiagnosticFactory{
    .name = "NON_ABSTRACT_FUNCTION_WITH_NO_BODY",
    .default_severity = .Error,
    .message_template = "Function ''{0}'' without a body must be abstract.",
};
pub const NON_ASCENDING_VERSION_ANNOTATION = DiagnosticFactory{
    .name = "NON_ASCENDING_VERSION_ANNOTATION",
    .default_severity = .Error,
    .message_template = "NON_ASCENDING_VERSION_ANNOTATION",
};
pub const NON_CONST_VAL_USED_IN_CONSTANT_EXPRESSION = DiagnosticFactory{
    .name = "NON_CONST_VAL_USED_IN_CONSTANT_EXPRESSION",
    .default_severity = .Error,
    .message_template = "Only 'const val' can be used in constant expressions.",
};
pub const NON_FINAL_MEMBER_IN_FINAL_CLASS = DiagnosticFactory{
    .name = "NON_FINAL_MEMBER_IN_FINAL_CLASS",
    .default_severity = .Warning,
    .message_template = "'open' has no effect on a final class.",
};
pub const NON_FINAL_MEMBER_IN_OBJECT = DiagnosticFactory{
    .name = "NON_FINAL_MEMBER_IN_OBJECT",
    .default_severity = .Warning,
    .message_template = "'open' has no effect on object.",
};
pub const NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD = DiagnosticFactory{
    .name = "NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
};
pub const NON_INLINE_MEMBER_VAL_INITIALIZATION = DiagnosticFactory{
    .name = "NON_INLINE_MEMBER_VAL_INITIALIZATION",
    .default_severity = .Error,
    .message_template = "NON_INLINE_MEMBER_VAL_INITIALIZATION",
};
pub const NON_INTERNAL_PUBLISHED_API = DiagnosticFactory{
    .name = "NON_INTERNAL_PUBLISHED_API",
    .default_severity = .Error,
    .message_template = "'@PublishedApi' annotation is only applicable to internal declaration.",
};
pub const NON_LOCAL_RETURN_NOT_ALLOWED = DiagnosticFactory{
    .name = "NON_LOCAL_RETURN_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "NON_LOCAL_RETURN_NOT_ALLOWED",
};
pub const NON_LOCAL_SUSPENSION_POINT = DiagnosticFactory{
    .name = "NON_LOCAL_SUSPENSION_POINT",
    .default_severity = .Error,
    .message_template = "Suspension functions can only be called within coroutine body.",
};
pub const NON_MEMBER_FUNCTION_NO_BODY = DiagnosticFactory{
    .name = "NON_MEMBER_FUNCTION_NO_BODY",
    .default_severity = .Error,
    .message_template = "Function ''{0}'' must have a body.",
};
pub const NON_MODIFIER_FORM_FOR_BUILT_IN_SUSPEND = DiagnosticFactory{
    .name = "NON_MODIFIER_FORM_FOR_BUILT_IN_SUSPEND",
    .default_severity = .Error,
    .message_template = "NON_MODIFIER_FORM_FOR_BUILT_IN_SUSPEND",
};
pub const NON_PRIVATE_CONSTRUCTOR_IN_ENUM = DiagnosticFactory{
    .name = "NON_PRIVATE_CONSTRUCTOR_IN_ENUM",
    .default_severity = .Error,
    .message_template = "Constructor must be private in enum class.",
};
pub const NON_PRIVATE_OR_PROTECTED_CONSTRUCTOR_IN_SEALED = DiagnosticFactory{
    .name = "NON_PRIVATE_OR_PROTECTED_CONSTRUCTOR_IN_SEALED",
    .default_severity = .Error,
    .message_template = "Constructor must be private or protected in sealed class.",
};
pub const NON_PUBLIC_CALL_FROM_PUBLIC_INLINE = DiagnosticFactory{
    .name = "NON_PUBLIC_CALL_FROM_PUBLIC_INLINE",
    .default_severity = .Error,
    .message_template = "NON_PUBLIC_CALL_FROM_PUBLIC_INLINE",
};
pub const NON_PUBLIC_CALL_FROM_PUBLIC_INLINE_DEPRECATION = DiagnosticFactory{
    .name = "NON_PUBLIC_CALL_FROM_PUBLIC_INLINE_DEPRECATION",
    .default_severity = .Warning,
    .message_template = "NON_PUBLIC_CALL_FROM_PUBLIC_INLINE_DEPRECATION",
};
pub const NON_PUBLIC_INLINE_CALL_FROM_PUBLIC_INLINE = DiagnosticFactory{
    .name = "NON_PUBLIC_INLINE_CALL_FROM_PUBLIC_INLINE",
    .default_severity = .Error,
    .message_template = "NON_PUBLIC_INLINE_CALL_FROM_PUBLIC_INLINE",
};
pub const NON_SOURCE_ANNOTATION_ON_INLINED_LAMBDA_EXPRESSION = DiagnosticFactory{
    .name = "NON_SOURCE_ANNOTATION_ON_INLINED_LAMBDA_EXPRESSION",
    .default_severity = .Error,
    .message_template = "NON_SOURCE_ANNOTATION_ON_INLINED_LAMBDA_EXPRESSION",
};
pub const NON_SUSPEND_OVERRIDDEN_BY_SUSPEND = DiagnosticFactory{
    .name = "NON_SUSPEND_OVERRIDDEN_BY_SUSPEND",
    .default_severity = .Error,
    .message_template = "NON_SUSPEND_OVERRIDDEN_BY_SUSPEND",
};
pub const NON_TAIL_RECURSIVE_CALL = DiagnosticFactory{
    .name = "NON_TAIL_RECURSIVE_CALL",
    .default_severity = .Warning,
    .message_template = "Recursive call is not a tail call.",
};
pub const NON_VARARG_SPREAD = DiagnosticFactory{
    .name = "NON_VARARG_SPREAD",
    .default_severity = .Error,
    .message_template = "The spread operator (*foo) can only be applied in a vararg position.",
};
pub const NOTHING_TO_INLINE = DiagnosticFactory{
    .name = "NOTHING_TO_INLINE",
    .default_severity = .Warning,
    .message_template = "NOTHING_TO_INLINE",
};
pub const NOTHING_TO_OVERRIDE = DiagnosticFactory{
    .name = "NOTHING_TO_OVERRIDE",
    .default_severity = .Error,
    .message_template = "NOTHING_TO_OVERRIDE",
};
pub const NOT_AN_ANNOTATION_CLASS = DiagnosticFactory{
    .name = "NOT_AN_ANNOTATION_CLASS",
    .default_severity = .Error,
    .message_template = "Illegal annotation class ''{0}''.",
};
pub const NOT_A_CLASS = DiagnosticFactory{
    .name = "NOT_A_CLASS",
    .default_severity = .Error,
    .message_template = "Not a class.",
};
pub const NOT_A_FUNCTION_LABEL = DiagnosticFactory{
    .name = "NOT_A_FUNCTION_LABEL",
    .default_severity = .Error,
    .message_template = "Target label does not denote a function.",
};
pub const NOT_A_LOOP_LABEL = DiagnosticFactory{
    .name = "NOT_A_LOOP_LABEL",
    .default_severity = .Error,
    .message_template = "Label does not denote a reachable loop.",
};
pub const NOT_A_MULTIPLATFORM_COMPILATION = DiagnosticFactory{
    .name = "NOT_A_MULTIPLATFORM_COMPILATION",
    .default_severity = .Error,
    .message_template = "'expect' and 'actual' declarations can be used only in multiplatform projects. Learn more about Kotlin Multiplatform: https://kotl.in/multiplatform-setup",
};
pub const NOT_A_SUPERTYPE = DiagnosticFactory{
    .name = "NOT_A_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "Not an immediate supertype.",
};
pub const NOT_FUNCTION_AS_OPERATOR = DiagnosticFactory{
    .name = "NOT_FUNCTION_AS_OPERATOR",
    .default_severity = .Error,
    .message_template = "NOT_FUNCTION_AS_OPERATOR",
};
pub const NOT_NULL_ASSERTION_ON_CALLABLE_REFERENCE = DiagnosticFactory{
    .name = "NOT_NULL_ASSERTION_ON_CALLABLE_REFERENCE",
    .default_severity = .Warning,
    .message_template = "Non-null assertion (!!) called on a callable reference expression.",
};
pub const NOT_NULL_ASSERTION_ON_LAMBDA_EXPRESSION = DiagnosticFactory{
    .name = "NOT_NULL_ASSERTION_ON_LAMBDA_EXPRESSION",
    .default_severity = .Warning,
    .message_template = "Non-null assertion (!!) called on a lambda expression.",
};
pub const NOT_SUPPORTED_INLINE_PARAMETER_IN_INLINE_PARAMETER_DEFAULT_VALUE = DiagnosticFactory{
    .name = "NOT_SUPPORTED_INLINE_PARAMETER_IN_INLINE_PARAMETER_DEFAULT_VALUE",
    .default_severity = .Error,
    .message_template = "NOT_SUPPORTED_INLINE_PARAMETER_IN_INLINE_PARAMETER_DEFAULT_VALUE",
};
pub const NOT_YET_SUPPORTED_IN_INLINE = DiagnosticFactory{
    .name = "NOT_YET_SUPPORTED_IN_INLINE",
    .default_severity = .Error,
    .message_template = "{0} are not yet supported in inline functions.",
};
pub const NOT_YET_SUPPORTED_IN_INLINE_WARNING = DiagnosticFactory{
    .name = "NOT_YET_SUPPORTED_IN_INLINE_WARNING",
    .default_severity = .Warning,
    .message_template = "NOT_YET_SUPPORTED_IN_INLINE_WARNING",
};
pub const NO_ACTUAL_CLASS_MEMBER_FOR_EXPECTED_CLASS = DiagnosticFactory{
    .name = "NO_ACTUAL_CLASS_MEMBER_FOR_EXPECTED_CLASS",
    .default_severity = .Error,
    .message_template = "NO_ACTUAL_CLASS_MEMBER_FOR_EXPECTED_CLASS",
};
pub const NO_COMPANION_OBJECT = DiagnosticFactory{
    .name = "NO_COMPANION_OBJECT",
    .default_severity = .Error,
    .message_template = "NO_COMPANION_OBJECT",
};
pub const NO_CONSTRUCTOR = DiagnosticFactory{
    .name = "NO_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "This type does not have a constructor.",
};
pub const NO_CONTEXT_ARGUMENT = DiagnosticFactory{
    .name = "NO_CONTEXT_ARGUMENT",
    .default_severity = .Error,
    .message_template = "NO_CONTEXT_ARGUMENT",
};
pub const NO_ELSE_IN_WHEN = DiagnosticFactory{
    .name = "NO_ELSE_IN_WHEN",
    .default_severity = .Error,
    .message_template = "''when'' expression must be exhaustive. Add {0}{1}.",
};
pub const NO_EXPLICIT_RETURN_TYPE_IN_API_MODE = DiagnosticFactory{
    .name = "NO_EXPLICIT_RETURN_TYPE_IN_API_MODE",
    .default_severity = .Error,
    .message_template = "Return type must be specified in explicit API mode.",
};
pub const NO_EXPLICIT_RETURN_TYPE_IN_API_MODE_WARNING = DiagnosticFactory{
    .name = "NO_EXPLICIT_RETURN_TYPE_IN_API_MODE_WARNING",
    .default_severity = .Warning,
    .message_template = "Return type must be specified in explicit API mode.",
};
pub const NO_EXPLICIT_VISIBILITY_IN_API_MODE = DiagnosticFactory{
    .name = "NO_EXPLICIT_VISIBILITY_IN_API_MODE",
    .default_severity = .Error,
    .message_template = "Visibility must be specified in explicit API mode.",
};
pub const NO_EXPLICIT_VISIBILITY_IN_API_MODE_WARNING = DiagnosticFactory{
    .name = "NO_EXPLICIT_VISIBILITY_IN_API_MODE_WARNING",
    .default_severity = .Warning,
    .message_template = "Visibility must be specified in explicit API mode.",
};
pub const NO_GET_METHOD = DiagnosticFactory{
    .name = "NO_GET_METHOD",
    .default_severity = .Error,
    .message_template = "No 'get' operator method providing array access.",
};
pub const NO_IMPLICIT_DEFAULT_CONSTRUCTOR_ON_EXPECT_CLASS = DiagnosticFactory{
    .name = "NO_IMPLICIT_DEFAULT_CONSTRUCTOR_ON_EXPECT_CLASS",
    .default_severity = .Error,
    .message_template = "NO_IMPLICIT_DEFAULT_CONSTRUCTOR_ON_EXPECT_CLASS",
};
pub const NO_RECEIVER_ALLOWED = DiagnosticFactory{
    .name = "NO_RECEIVER_ALLOWED",
    .default_severity = .Error,
    .message_template = "No receiver can be passed to this function or property.",
};
pub const NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY = DiagnosticFactory{
    .name = "NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY",
    .default_severity = .Error,
    .message_template = "Missing return statement.",
};
pub const NO_SET_METHOD = DiagnosticFactory{
    .name = "NO_SET_METHOD",
    .default_severity = .Error,
    .message_template = "No 'set' operator method providing array access.",
};
pub const NO_TAIL_CALLS_FOUND = DiagnosticFactory{
    .name = "NO_TAIL_CALLS_FOUND",
    .default_severity = .Warning,
    .message_template = "A function is marked as tail-recursive but no tail calls are found.",
};
pub const NO_THIS = DiagnosticFactory{
    .name = "NO_THIS",
    .default_severity = .Error,
    .message_template = "'this' is not defined in this context.",
};
pub const NO_TYPE_ARGUMENTS_ON_RHS = DiagnosticFactory{
    .name = "NO_TYPE_ARGUMENTS_ON_RHS",
    .default_severity = .Error,
    .message_template = "NO_TYPE_ARGUMENTS_ON_RHS",
};
pub const NO_VALUE_FOR_PARAMETER = DiagnosticFactory{
    .name = "NO_VALUE_FOR_PARAMETER",
    .default_severity = .Error,
    .message_template = "No value passed for parameter ''{0}''.",
};
pub const NO_VARARG_OVERLOAD_OF_OPERATOR_OF = DiagnosticFactory{
    .name = "NO_VARARG_OVERLOAD_OF_OPERATOR_OF",
    .default_severity = .Error,
    .message_template = "One of the overloads of operator 'of' must have a single 'vararg' parameter.",
};
pub const NULLABLE_INLINE_PARAMETER = DiagnosticFactory{
    .name = "NULLABLE_INLINE_PARAMETER",
    .default_severity = .Error,
    .message_template = "NULLABLE_INLINE_PARAMETER",
};
pub const NULLABLE_ON_DEFINITELY_NOT_NULLABLE = DiagnosticFactory{
    .name = "NULLABLE_ON_DEFINITELY_NOT_NULLABLE",
    .default_severity = .Error,
    .message_template = "NULLABLE_ON_DEFINITELY_NOT_NULLABLE",
};
pub const NULLABLE_RETURN_TYPE_OF_OPERATOR_OF = DiagnosticFactory{
    .name = "NULLABLE_RETURN_TYPE_OF_OPERATOR_OF",
    .default_severity = .Error,
    .message_template = "Return type of 'operator fun of' cannot be nullable.",
};
pub const NULLABLE_SUPERTYPE = DiagnosticFactory{
    .name = "NULLABLE_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "Supertypes cannot be nullable.",
};
pub const NULLABLE_TYPE_IN_CLASS_LITERAL_LHS = DiagnosticFactory{
    .name = "NULLABLE_TYPE_IN_CLASS_LITERAL_LHS",
    .default_severity = .Error,
    .message_template = "Type in a class literal cannot be nullable.",
};
pub const NULLABLE_TYPE_OF_ANNOTATION_MEMBER = DiagnosticFactory{
    .name = "NULLABLE_TYPE_OF_ANNOTATION_MEMBER",
    .default_severity = .Error,
    .message_template = "Annotation parameters cannot be nullable.",
};
pub const NULL_FOR_NONNULL_TYPE = DiagnosticFactory{
    .name = "NULL_FOR_NONNULL_TYPE",
    .default_severity = .Error,
    .message_template = "NULL_FOR_NONNULL_TYPE",
};
pub const ONLY_ONE_CLASS_BOUND_ALLOWED = DiagnosticFactory{
    .name = "ONLY_ONE_CLASS_BOUND_ALLOWED",
    .default_severity = .Error,
    .message_template = "Only one of the upper bounds can be a class.",
};
pub const OPERATOR_CALL_ON_CONSTRUCTOR = DiagnosticFactory{
    .name = "OPERATOR_CALL_ON_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Constructor of ''{0}'' cannot be used as an operator.",
};
pub const OPERATOR_MODIFIER_REQUIRED = DiagnosticFactory{
    .name = "OPERATOR_MODIFIER_REQUIRED",
    .default_severity = .Error,
    .message_template = "''operator'' modifier is required on {0}.",
};
pub const OPERATOR_RENAMED_ON_IMPORT = DiagnosticFactory{
    .name = "OPERATOR_RENAMED_ON_IMPORT",
    .default_severity = .Error,
    .message_template = "Operator renamed to a different operator on import.",
};
pub const OPTIONAL_DECLARATION_OUTSIDE_OF_ANNOTATION_ENTRY = DiagnosticFactory{
    .name = "OPTIONAL_DECLARATION_OUTSIDE_OF_ANNOTATION_ENTRY",
    .default_severity = .Error,
    .message_template = "OPTIONAL_DECLARATION_OUTSIDE_OF_ANNOTATION_ENTRY",
};
pub const OPTIONAL_DECLARATION_USAGE_IN_NON_COMMON_SOURCE = DiagnosticFactory{
    .name = "OPTIONAL_DECLARATION_USAGE_IN_NON_COMMON_SOURCE",
    .default_severity = .Error,
    .message_template = "OPTIONAL_DECLARATION_USAGE_IN_NON_COMMON_SOURCE",
};
pub const OPTIONAL_EXPECTATION_NOT_ON_EXPECTED = DiagnosticFactory{
    .name = "OPTIONAL_EXPECTATION_NOT_ON_EXPECTED",
    .default_severity = .Error,
    .message_template = "OPTIONAL_EXPECTATION_NOT_ON_EXPECTED",
};
pub const OPT_IN_ARGUMENT_IS_NOT_MARKER = DiagnosticFactory{
    .name = "OPT_IN_ARGUMENT_IS_NOT_MARKER",
    .default_severity = .Warning,
    .message_template = "OPT_IN_ARGUMENT_IS_NOT_MARKER",
};
pub const OPT_IN_CAN_ONLY_BE_USED_AS_ANNOTATION = DiagnosticFactory{
    .name = "OPT_IN_CAN_ONLY_BE_USED_AS_ANNOTATION",
    .default_severity = .Error,
    .message_template = "This class can only be used as an annotation.",
};
pub const OPT_IN_MARKER_CAN_ONLY_BE_USED_AS_ANNOTATION_OR_ARGUMENT_IN_OPT_IN = DiagnosticFactory{
    .name = "OPT_IN_MARKER_CAN_ONLY_BE_USED_AS_ANNOTATION_OR_ARGUMENT_IN_OPT_IN",
    .default_severity = .Error,
    .message_template = "OPT_IN_MARKER_CAN_ONLY_BE_USED_AS_ANNOTATION_OR_ARGUMENT_IN_OPT_IN",
};
pub const OPT_IN_MARKER_ON_OVERRIDE = DiagnosticFactory{
    .name = "OPT_IN_MARKER_ON_OVERRIDE",
    .default_severity = .Error,
    .message_template = "OPT_IN_MARKER_ON_OVERRIDE",
};
pub const OPT_IN_MARKER_ON_OVERRIDE_WARNING = DiagnosticFactory{
    .name = "OPT_IN_MARKER_ON_OVERRIDE_WARNING",
    .default_severity = .Warning,
    .message_template = "OPT_IN_MARKER_ON_OVERRIDE_WARNING",
};
pub const OPT_IN_MARKER_ON_WRONG_TARGET = DiagnosticFactory{
    .name = "OPT_IN_MARKER_ON_WRONG_TARGET",
    .default_severity = .Error,
    .message_template = "Opt-in requirement marker annotation cannot be used on {0}.",
};
pub const OPT_IN_MARKER_WITH_WRONG_RETENTION = DiagnosticFactory{
    .name = "OPT_IN_MARKER_WITH_WRONG_RETENTION",
    .default_severity = .Error,
    .message_template = "OPT_IN_MARKER_WITH_WRONG_RETENTION",
};
pub const OPT_IN_MARKER_WITH_WRONG_TARGET = DiagnosticFactory{
    .name = "OPT_IN_MARKER_WITH_WRONG_TARGET",
    .default_severity = .Error,
    .message_template = "OPT_IN_MARKER_WITH_WRONG_TARGET",
};
pub const OPT_IN_OVERRIDE = DiagnosticFactory{
    .name = "OPT_IN_OVERRIDE",
    .default_severity = .Warning,
    .message_template = "{1}",
};
pub const OPT_IN_OVERRIDE_ERROR = DiagnosticFactory{
    .name = "OPT_IN_OVERRIDE_ERROR",
    .default_severity = .Error,
    .message_template = "{1}",
};
pub const OPT_IN_TO_INHERITANCE = DiagnosticFactory{
    .name = "OPT_IN_TO_INHERITANCE",
    .default_severity = .Warning,
    .message_template = "{1}",
};
pub const OPT_IN_TO_INHERITANCE_ERROR = DiagnosticFactory{
    .name = "OPT_IN_TO_INHERITANCE_ERROR",
    .default_severity = .Error,
    .message_template = "{1}",
};
pub const OPT_IN_USAGE = DiagnosticFactory{
    .name = "OPT_IN_USAGE",
    .default_severity = .Warning,
    .message_template = "{1}",
};
pub const OPT_IN_USAGE_ERROR = DiagnosticFactory{
    .name = "OPT_IN_USAGE_ERROR",
    .default_severity = .Error,
    .message_template = "{1}",
};
pub const OPT_IN_WITHOUT_ARGUMENTS = DiagnosticFactory{
    .name = "OPT_IN_WITHOUT_ARGUMENTS",
    .default_severity = .Warning,
    .message_template = "'@OptIn' without any arguments has no effect.",
};
pub const OTHER_ERROR = DiagnosticFactory{
    .name = "OTHER_ERROR",
    .default_severity = .Error,
    .message_template = "Unknown error.",
};
pub const OTHER_ERROR_WITH_REASON = DiagnosticFactory{
    .name = "OTHER_ERROR_WITH_REASON",
    .default_severity = .Error,
    .message_template = "Unknown error: {0}.",
};
pub const OUTER_CLASS_ARGUMENTS_REQUIRED = DiagnosticFactory{
    .name = "OUTER_CLASS_ARGUMENTS_REQUIRED",
    .default_severity = .Error,
    .message_template = "OUTER_CLASS_ARGUMENTS_REQUIRED",
};
pub const OVERLOAD_RESOLUTION_AMBIGUITY = DiagnosticFactory{
    .name = "OVERLOAD_RESOLUTION_AMBIGUITY",
    .default_severity = .Error,
    .message_template = "OVERLOAD_RESOLUTION_AMBIGUITY",
};
pub const OVERRIDE_BY_INLINE = DiagnosticFactory{
    .name = "OVERRIDE_BY_INLINE",
    .default_severity = .Warning,
    .message_template = "Override by an inline function.",
};
pub const OVERRIDE_DEPRECATION = DiagnosticFactory{
    .name = "OVERRIDE_DEPRECATION",
    .default_severity = .Warning,
    .message_template = "OVERRIDE_DEPRECATION",
};
pub const OVERRIDING_FINAL_MEMBER = DiagnosticFactory{
    .name = "OVERRIDING_FINAL_MEMBER",
    .default_severity = .Error,
    .message_template = "''{0}'' in ''{1}'' is final and cannot be overridden.",
};
pub const OVERRIDING_FINAL_MEMBER_BY_DELEGATION = DiagnosticFactory{
    .name = "OVERRIDING_FINAL_MEMBER_BY_DELEGATION",
    .default_severity = .Error,
    .message_template = "OVERRIDING_FINAL_MEMBER_BY_DELEGATION",
};
pub const OVERRIDING_IGNORABLE_WITH_MUST_USE = DiagnosticFactory{
    .name = "OVERRIDING_IGNORABLE_WITH_MUST_USE",
    .default_severity = .Warning,
    .message_template = "OVERRIDING_IGNORABLE_WITH_MUST_USE",
};
pub const PACKAGE_CANNOT_BE_IMPORTED = DiagnosticFactory{
    .name = "PACKAGE_CANNOT_BE_IMPORTED",
    .default_severity = .Error,
    .message_template = "Packages cannot be imported.",
};
pub const PACKAGE_CONFLICTS_WITH_CLASSIFIER = DiagnosticFactory{
    .name = "PACKAGE_CONFLICTS_WITH_CLASSIFIER",
    .default_severity = .Error,
    .message_template = "Package conflicts with classifier {0}",
};
pub const PARAMETER_NAME_CHANGED_ON_OVERRIDE = DiagnosticFactory{
    .name = "PARAMETER_NAME_CHANGED_ON_OVERRIDE",
    .default_severity = .Warning,
    .message_template = "PARAMETER_NAME_CHANGED_ON_OVERRIDE",
};
pub const PLACEHOLDER_PROJECTION_IN_QUALIFIER = DiagnosticFactory{
    .name = "PLACEHOLDER_PROJECTION_IN_QUALIFIER",
    .default_severity = .Error,
    .message_template = "Type argument inference is not supported in qualifiers.",
};
pub const PLATFORM_CLASS_MAPPED_TO_KOTLIN = DiagnosticFactory{
    .name = "PLATFORM_CLASS_MAPPED_TO_KOTLIN",
    .default_severity = .Warning,
    .message_template = "PLATFORM_CLASS_MAPPED_TO_KOTLIN",
};
pub const PLUGIN_AMBIGUOUS_INTERCEPTED_SYMBOL = DiagnosticFactory{
    .name = "PLUGIN_AMBIGUOUS_INTERCEPTED_SYMBOL",
    .default_severity = .Error,
    .message_template = "PLUGIN_AMBIGUOUS_INTERCEPTED_SYMBOL",
};
pub const POTENTIALLY_NON_REPORTED_ANNOTATION = DiagnosticFactory{
    .name = "POTENTIALLY_NON_REPORTED_ANNOTATION",
    .default_severity = .Warning,
    .message_template = "POTENTIALLY_NON_REPORTED_ANNOTATION",
};
pub const POTENTIALLY_NULLABLE_RETURN_TYPE_OF_OPERATOR_OF = DiagnosticFactory{
    .name = "POTENTIALLY_NULLABLE_RETURN_TYPE_OF_OPERATOR_OF",
    .default_severity = .Error,
    .message_template = "POTENTIALLY_NULLABLE_RETURN_TYPE_OF_OPERATOR_OF",
};
pub const PRE_RELEASE_CLASS = DiagnosticFactory{
    .name = "PRE_RELEASE_CLASS",
    .default_severity = .Error,
    .message_template = "PRE_RELEASE_CLASS",
};
pub const PRIMARY_CONSTRUCTOR_DELEGATION_CALL_EXPECTED = DiagnosticFactory{
    .name = "PRIMARY_CONSTRUCTOR_DELEGATION_CALL_EXPECTED",
    .default_severity = .Error,
    .message_template = "Primary constructor call expected.",
};
pub const PRIVATE_CLASS_MEMBER_FROM_INLINE = DiagnosticFactory{
    .name = "PRIVATE_CLASS_MEMBER_FROM_INLINE",
    .default_severity = .Error,
    .message_template = "PRIVATE_CLASS_MEMBER_FROM_INLINE",
};
pub const PRIVATE_FUNCTION_WITH_NO_BODY = DiagnosticFactory{
    .name = "PRIVATE_FUNCTION_WITH_NO_BODY",
    .default_severity = .Error,
    .message_template = "Function ''{0}'' without a body cannot be private.",
};
pub const PRIVATE_PROPERTY_IN_INTERFACE = DiagnosticFactory{
    .name = "PRIVATE_PROPERTY_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Abstract property in interface cannot be private.",
};
pub const PRIVATE_SETTER_FOR_ABSTRACT_PROPERTY = DiagnosticFactory{
    .name = "PRIVATE_SETTER_FOR_ABSTRACT_PROPERTY",
    .default_severity = .Error,
    .message_template = "Private setters for abstract properties are prohibited.",
};
pub const PRIVATE_SETTER_FOR_OPEN_PROPERTY = DiagnosticFactory{
    .name = "PRIVATE_SETTER_FOR_OPEN_PROPERTY",
    .default_severity = .Error,
    .message_template = "Private setters for open properties are prohibited.",
};
pub const PROJECTION_IN_IMMEDIATE_ARGUMENT_TO_SUPERTYPE = DiagnosticFactory{
    .name = "PROJECTION_IN_IMMEDIATE_ARGUMENT_TO_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "Projections for immediate arguments of a supertype are prohibited.",
};
pub const PROJECTION_ON_NON_CLASS_TYPE_ARGUMENT = DiagnosticFactory{
    .name = "PROJECTION_ON_NON_CLASS_TYPE_ARGUMENT",
    .default_severity = .Error,
    .message_template = "Projections are not allowed on type arguments of functions calls.",
};
pub const PROPERTY_FIELD_DECLARATION_MISSING_INITIALIZER = DiagnosticFactory{
    .name = "PROPERTY_FIELD_DECLARATION_MISSING_INITIALIZER",
    .default_severity = .Error,
    .message_template = "PROPERTY_FIELD_DECLARATION_MISSING_INITIALIZER",
};
pub const PROPERTY_INITIALIZER_IN_INTERFACE = DiagnosticFactory{
    .name = "PROPERTY_INITIALIZER_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Property initializers in interfaces are prohibited.",
};
pub const PROPERTY_INITIALIZER_NO_BACKING_FIELD = DiagnosticFactory{
    .name = "PROPERTY_INITIALIZER_NO_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "Initializer is prohibited here because this property has no backing field.",
};
pub const PROPERTY_INITIALIZER_WITH_EXPLICIT_FIELD_DECLARATION = DiagnosticFactory{
    .name = "PROPERTY_INITIALIZER_WITH_EXPLICIT_FIELD_DECLARATION",
    .default_severity = .Error,
    .message_template = "PROPERTY_INITIALIZER_WITH_EXPLICIT_FIELD_DECLARATION",
};
pub const PROPERTY_TYPE_MISMATCH_BY_DELEGATION = DiagnosticFactory{
    .name = "PROPERTY_TYPE_MISMATCH_BY_DELEGATION",
    .default_severity = .Error,
    .message_template = "PROPERTY_TYPE_MISMATCH_BY_DELEGATION",
};
pub const PROPERTY_TYPE_MISMATCH_ON_INHERITANCE = DiagnosticFactory{
    .name = "PROPERTY_TYPE_MISMATCH_ON_INHERITANCE",
    .default_severity = .Error,
    .message_template = "PROPERTY_TYPE_MISMATCH_ON_INHERITANCE",
};
pub const PROPERTY_TYPE_MISMATCH_ON_OVERRIDE = DiagnosticFactory{
    .name = "PROPERTY_TYPE_MISMATCH_ON_OVERRIDE",
    .default_severity = .Error,
    .message_template = "PROPERTY_TYPE_MISMATCH_ON_OVERRIDE",
};
pub const PROPERTY_WITH_BACKING_FIELD_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "PROPERTY_WITH_BACKING_FIELD_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "Value class cannot have properties with backing fields.",
};
pub const PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS = DiagnosticFactory{
    .name = "PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS",
    .default_severity = .Error,
    .message_template = "PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS",
};
pub const PROPERTY_WITH_NO_TYPE_NO_INITIALIZER = DiagnosticFactory{
    .name = "PROPERTY_WITH_NO_TYPE_NO_INITIALIZER",
    .default_severity = .Error,
    .message_template = "PROPERTY_WITH_NO_TYPE_NO_INITIALIZER",
};
pub const PROTECTED_CALL_FROM_PUBLIC_INLINE_ERROR = DiagnosticFactory{
    .name = "PROTECTED_CALL_FROM_PUBLIC_INLINE_ERROR",
    .default_severity = .Error,
    .message_template = "PROTECTED_CALL_FROM_PUBLIC_INLINE_ERROR",
};
pub const PROTECTED_CONSTRUCTOR_CALL_FROM_PUBLIC_INLINE = DiagnosticFactory{
    .name = "PROTECTED_CONSTRUCTOR_CALL_FROM_PUBLIC_INLINE",
    .default_severity = .Error,
    .message_template = "PROTECTED_CONSTRUCTOR_CALL_FROM_PUBLIC_INLINE",
};
pub const PROTECTED_CONSTRUCTOR_NOT_IN_SUPER_CALL = DiagnosticFactory{
    .name = "PROTECTED_CONSTRUCTOR_NOT_IN_SUPER_CALL",
    .default_severity = .Error,
    .message_template = "Protected constructor ''{0}'' from other classes can only be used in super-call.",
};
pub const RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER = DiagnosticFactory{
    .name = "RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER",
    .default_severity = .Error,
    .message_template = "RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER",
};
pub const RECURSION_IN_IMPLICIT_TYPES = DiagnosticFactory{
    .name = "RECURSION_IN_IMPLICIT_TYPES",
    .default_severity = .Error,
    .message_template = "Recursion in implicit types.",
};
pub const RECURSION_IN_INLINE = DiagnosticFactory{
    .name = "RECURSION_IN_INLINE",
    .default_severity = .Error,
    .message_template = "Inline function ''{0}'' cannot be recursive.",
};
pub const RECURSIVE_TYPEALIAS_EXPANSION = DiagnosticFactory{
    .name = "RECURSIVE_TYPEALIAS_EXPANSION",
    .default_severity = .Error,
    .message_template = "Recursive type alias in expansion.",
};
pub const REDECLARATION = DiagnosticFactory{
    .name = "REDECLARATION",
    .default_severity = .Error,
    .message_template = "Conflicting declarations:{0}",
};
pub const REDUNDANT_ANNOTATION = DiagnosticFactory{
    .name = "REDUNDANT_ANNOTATION",
    .default_severity = .Warning,
    .message_template = "Annotation ''{0}'' is redundant.",
};
pub const REDUNDANT_ANNOTATION_TARGET = DiagnosticFactory{
    .name = "REDUNDANT_ANNOTATION_TARGET",
    .default_severity = .Warning,
    .message_template = "Redundant annotation target ''{0}''.",
};
pub const REDUNDANT_CALL_OF_CONVERSION_METHOD = DiagnosticFactory{
    .name = "REDUNDANT_CALL_OF_CONVERSION_METHOD",
    .default_severity = .Warning,
    .message_template = "Redundant call of conversion method.",
};
pub const REDUNDANT_ELSE_IN_WHEN = DiagnosticFactory{
    .name = "REDUNDANT_ELSE_IN_WHEN",
    .default_severity = .Warning,
    .message_template = "'when' is exhaustive so 'else' is redundant here.",
};
pub const REDUNDANT_EXPLICIT_BACKING_FIELD = DiagnosticFactory{
    .name = "REDUNDANT_EXPLICIT_BACKING_FIELD",
    .default_severity = .Warning,
    .message_template = "REDUNDANT_EXPLICIT_BACKING_FIELD",
};
pub const REDUNDANT_INTERPOLATION_PREFIX = DiagnosticFactory{
    .name = "REDUNDANT_INTERPOLATION_PREFIX",
    .default_severity = .Warning,
    .message_template = "Redundant interpolation prefix.",
};
pub const REDUNDANT_LABEL_WARNING = DiagnosticFactory{
    .name = "REDUNDANT_LABEL_WARNING",
    .default_severity = .Warning,
    .message_template = "REDUNDANT_LABEL_WARNING",
};
pub const REDUNDANT_MODALITY_MODIFIER = DiagnosticFactory{
    .name = "REDUNDANT_MODALITY_MODIFIER",
    .default_severity = .Warning,
    .message_template = "Redundant modality modifier.",
};
pub const REDUNDANT_MODIFIER = DiagnosticFactory{
    .name = "REDUNDANT_MODIFIER",
    .default_severity = .Warning,
    .message_template = "Modifier ''{0}'' is redundant in presence of ''{1}''.",
};
pub const REDUNDANT_MODIFIER_FOR_TARGET = DiagnosticFactory{
    .name = "REDUNDANT_MODIFIER_FOR_TARGET",
    .default_severity = .Warning,
    .message_template = "Modifier ''{0}'' is redundant for ''{1}''.",
};
pub const REDUNDANT_NULLABLE = DiagnosticFactory{
    .name = "REDUNDANT_NULLABLE",
    .default_severity = .Warning,
    .message_template = "REDUNDANT_NULLABLE",
};
pub const REDUNDANT_OPEN_IN_INTERFACE = DiagnosticFactory{
    .name = "REDUNDANT_OPEN_IN_INTERFACE",
    .default_severity = .Warning,
    .message_template = "Modifier 'open' is redundant for abstract interface members.",
};
pub const REDUNDANT_PROJECTION = DiagnosticFactory{
    .name = "REDUNDANT_PROJECTION",
    .default_severity = .Warning,
    .message_template = "REDUNDANT_PROJECTION",
};
pub const REDUNDANT_RETURN = DiagnosticFactory{
    .name = "REDUNDANT_RETURN",
    .default_severity = .Warning,
    .message_template = "Return is redundant when used as expression body.",
};
pub const REDUNDANT_RETURN_UNIT_TYPE = DiagnosticFactory{
    .name = "REDUNDANT_RETURN_UNIT_TYPE",
    .default_severity = .Warning,
    .message_template = "Redundant return 'Unit' type.",
};
pub const REDUNDANT_SETTER_PARAMETER_TYPE = DiagnosticFactory{
    .name = "REDUNDANT_SETTER_PARAMETER_TYPE",
    .default_severity = .Warning,
    .message_template = "Redundant setter parameter type.",
};
pub const REDUNDANT_SINGLE_EXPRESSION_STRING_TEMPLATE = DiagnosticFactory{
    .name = "REDUNDANT_SINGLE_EXPRESSION_STRING_TEMPLATE",
    .default_severity = .Warning,
    .message_template = "Redundant string template.",
};
pub const REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_ANNOTATION = DiagnosticFactory{
    .name = "REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_ANNOTATION",
    .default_severity = .Warning,
    .message_template = "Redundant spread (*) operator.",
};
pub const REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_FUNCTION = DiagnosticFactory{
    .name = "REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_FUNCTION",
    .default_severity = .Warning,
    .message_template = "Redundant spread (*) operator.",
};
pub const REDUNDANT_VISIBILITY_MODIFIER = DiagnosticFactory{
    .name = "REDUNDANT_VISIBILITY_MODIFIER",
    .default_severity = .Warning,
    .message_template = "Redundant visibility modifier.",
};
pub const REIFIED_TYPE_FORBIDDEN_SUBSTITUTION = DiagnosticFactory{
    .name = "REIFIED_TYPE_FORBIDDEN_SUBSTITUTION",
    .default_severity = .Error,
    .message_template = "REIFIED_TYPE_FORBIDDEN_SUBSTITUTION",
};
pub const REIFIED_TYPE_PARAMETER_IN_OVERRIDE = DiagnosticFactory{
    .name = "REIFIED_TYPE_PARAMETER_IN_OVERRIDE",
    .default_severity = .Error,
    .message_template = "Override by a function with reified type parameter.",
};
pub const REIFIED_TYPE_PARAMETER_NO_INLINE = DiagnosticFactory{
    .name = "REIFIED_TYPE_PARAMETER_NO_INLINE",
    .default_severity = .Error,
    .message_template = "Only type parameters of inline functions can be reified.",
};
pub const REPEATED_ANNOTATION = DiagnosticFactory{
    .name = "REPEATED_ANNOTATION",
    .default_severity = .Error,
    .message_template = "This annotation is not repeatable.",
};
pub const REPEATED_ANNOTATION_WARNING = DiagnosticFactory{
    .name = "REPEATED_ANNOTATION_WARNING",
    .default_severity = .Warning,
    .message_template = "This annotation is not repeatable.",
};
pub const REPEATED_BOUND = DiagnosticFactory{
    .name = "REPEATED_BOUND",
    .default_severity = .Error,
    .message_template = "Type parameter already has this bound.",
};
pub const REPEATED_MODIFIER = DiagnosticFactory{
    .name = "REPEATED_MODIFIER",
    .default_severity = .Error,
    .message_template = "Repeated ''{0}''.",
};
pub const RESERVED_MEMBER_FROM_INTERFACE_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "RESERVED_MEMBER_FROM_INTERFACE_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "RESERVED_MEMBER_FROM_INTERFACE_INSIDE_VALUE_CLASS",
};
pub const RESERVED_MEMBER_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "RESERVED_MEMBER_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "Member name ''{0}'' is reserved for future releases.",
};
pub const RESOLUTION_TO_CLASSIFIER = DiagnosticFactory{
    .name = "RESOLUTION_TO_CLASSIFIER",
    .default_severity = .Error,
    .message_template = "Resolution to the classifier ''{0}'' is not appropriate here.",
};
pub const RESOLVED_TO_UNDERSCORE_NAMED_CATCH_PARAMETER = DiagnosticFactory{
    .name = "RESOLVED_TO_UNDERSCORE_NAMED_CATCH_PARAMETER",
    .default_severity = .Warning,
    .message_template = "RESOLVED_TO_UNDERSCORE_NAMED_CATCH_PARAMETER",
};
pub const RESTRICTED_RETENTION_FOR_EXPRESSION_ANNOTATION_ERROR = DiagnosticFactory{
    .name = "RESTRICTED_RETENTION_FOR_EXPRESSION_ANNOTATION_ERROR",
    .default_severity = .Error,
    .message_template = "Expression annotations with retention other than SOURCE are prohibited.",
};
pub const RESULT_TYPE_MISMATCH = DiagnosticFactory{
    .name = "RESULT_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "RESULT_TYPE_MISMATCH",
};
pub const RETURN_FOR_BUILT_IN_SUSPEND = DiagnosticFactory{
    .name = "RETURN_FOR_BUILT_IN_SUSPEND",
    .default_severity = .Error,
    .message_template = "Using implicit label for this lambda is prohibited.",
};
pub const RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY = DiagnosticFactory{
    .name = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY",
    .default_severity = .Error,
    .message_template = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY",
};
pub const RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_AND_IMPLICIT_TYPE = DiagnosticFactory{
    .name = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_AND_IMPLICIT_TYPE",
    .default_severity = .Error,
    .message_template = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_AND_IMPLICIT_TYPE",
};
pub const RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_WARNING = DiagnosticFactory{
    .name = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_WARNING",
    .default_severity = .Warning,
    .message_template = "RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_WARNING",
};
pub const RETURN_NOT_ALLOWED = DiagnosticFactory{
    .name = "RETURN_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "'return' is prohibited here.",
};
pub const RETURN_TYPE_MISMATCH = DiagnosticFactory{
    .name = "RETURN_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "RETURN_TYPE_MISMATCH",
};
pub const RETURN_TYPE_MISMATCH_BY_DELEGATION = DiagnosticFactory{
    .name = "RETURN_TYPE_MISMATCH_BY_DELEGATION",
    .default_severity = .Error,
    .message_template = "RETURN_TYPE_MISMATCH_BY_DELEGATION",
};
pub const RETURN_TYPE_MISMATCH_OF_OPERATOR_OF = DiagnosticFactory{
    .name = "RETURN_TYPE_MISMATCH_OF_OPERATOR_OF",
    .default_severity = .Error,
    .message_template = "RETURN_TYPE_MISMATCH_OF_OPERATOR_OF",
};
pub const RETURN_TYPE_MISMATCH_ON_INHERITANCE = DiagnosticFactory{
    .name = "RETURN_TYPE_MISMATCH_ON_INHERITANCE",
    .default_severity = .Error,
    .message_template = "RETURN_TYPE_MISMATCH_ON_INHERITANCE",
};
pub const RETURN_TYPE_MISMATCH_ON_OVERRIDE = DiagnosticFactory{
    .name = "RETURN_TYPE_MISMATCH_ON_OVERRIDE",
    .default_severity = .Error,
    .message_template = "RETURN_TYPE_MISMATCH_ON_OVERRIDE",
};
pub const RETURN_VALUE_NOT_USED = DiagnosticFactory{
    .name = "RETURN_VALUE_NOT_USED",
    .default_severity = .Warning,
    .message_template = "Unused return value{0}.",
};
pub const RETURN_VALUE_NOT_USED_COERCION = DiagnosticFactory{
    .name = "RETURN_VALUE_NOT_USED_COERCION",
    .default_severity = .Warning,
    .message_template = "RETURN_VALUE_NOT_USED_COERCION",
};
pub const ROOT_IDE_PACKAGE_DEPRECATED = DiagnosticFactory{
    .name = "ROOT_IDE_PACKAGE_DEPRECATED",
    .default_severity = .Warning,
    .message_template = "ROOT_IDE_PACKAGE_DEPRECATED",
};
pub const SAFE_CALLABLE_REFERENCE_CALL = DiagnosticFactory{
    .name = "SAFE_CALLABLE_REFERENCE_CALL",
    .default_severity = .Error,
    .message_template = "This syntax is reserved for future releases.",
};
pub const SEALED_CLASS_CONSTRUCTOR_CALL = DiagnosticFactory{
    .name = "SEALED_CLASS_CONSTRUCTOR_CALL",
    .default_severity = .Error,
    .message_template = "Sealed types cannot be instantiated.",
};
pub const SEALED_INHERITOR_IN_DIFFERENT_MODULE = DiagnosticFactory{
    .name = "SEALED_INHERITOR_IN_DIFFERENT_MODULE",
    .default_severity = .Error,
    .message_template = "Extending sealed classes or interfaces from a different module is prohibited.",
};
pub const SEALED_INHERITOR_IN_DIFFERENT_PACKAGE = DiagnosticFactory{
    .name = "SEALED_INHERITOR_IN_DIFFERENT_PACKAGE",
    .default_severity = .Error,
    .message_template = "SEALED_INHERITOR_IN_DIFFERENT_PACKAGE",
};
pub const SEALED_SUPERTYPE = DiagnosticFactory{
    .name = "SEALED_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "This type is sealed. It can only be extended by classes or objects in the same package.",
};
pub const SEALED_SUPERTYPE_IN_LOCAL_CLASS = DiagnosticFactory{
    .name = "SEALED_SUPERTYPE_IN_LOCAL_CLASS",
    .default_severity = .Error,
    .message_template = "{0} cannot extend a sealed {1}.",
};
pub const SECONDARY_CONSTRUCTOR_WITH_BODY_INSIDE_VALUE_CLASS = DiagnosticFactory{
    .name = "SECONDARY_CONSTRUCTOR_WITH_BODY_INSIDE_VALUE_CLASS",
    .default_severity = .Error,
    .message_template = "SECONDARY_CONSTRUCTOR_WITH_BODY_INSIDE_VALUE_CLASS",
};
pub const SELF_CALL_IN_NESTED_OBJECT_CONSTRUCTOR_ERROR = DiagnosticFactory{
    .name = "SELF_CALL_IN_NESTED_OBJECT_CONSTRUCTOR_ERROR",
    .default_severity = .Error,
    .message_template = "SELF_CALL_IN_NESTED_OBJECT_CONSTRUCTOR_ERROR",
};
pub const SENSELESS_COMPARISON = DiagnosticFactory{
    .name = "SENSELESS_COMPARISON",
    .default_severity = .Warning,
    .message_template = "Condition is always ''{0}''.",
};
pub const SENSELESS_NULL_IN_WHEN = DiagnosticFactory{
    .name = "SENSELESS_NULL_IN_WHEN",
    .default_severity = .Warning,
    .message_template = "Expression under 'when' is never equal to null.",
};
pub const SETTER_PROJECTED_OUT = DiagnosticFactory{
    .name = "SETTER_PROJECTED_OUT",
    .default_severity = .Error,
    .message_template = "SETTER_PROJECTED_OUT",
};
pub const SETTER_VISIBILITY_INCONSISTENT_WITH_PROPERTY_VISIBILITY = DiagnosticFactory{
    .name = "SETTER_VISIBILITY_INCONSISTENT_WITH_PROPERTY_VISIBILITY",
    .default_severity = .Error,
    .message_template = "SETTER_VISIBILITY_INCONSISTENT_WITH_PROPERTY_VISIBILITY",
};
pub const SINGLETON_IN_SUPERTYPE = DiagnosticFactory{
    .name = "SINGLETON_IN_SUPERTYPE",
    .default_severity = .Error,
    .message_template = "Cannot extend an object.",
};
pub const SMARTCAST_IMPOSSIBLE = DiagnosticFactory{
    .name = "SMARTCAST_IMPOSSIBLE",
    .default_severity = .Error,
    .message_template = "SMARTCAST_IMPOSSIBLE",
};
pub const SMARTCAST_IMPOSSIBLE_ON_IMPLICIT_INVOKE_RECEIVER = DiagnosticFactory{
    .name = "SMARTCAST_IMPOSSIBLE_ON_IMPLICIT_INVOKE_RECEIVER",
    .default_severity = .Error,
    .message_template = "SMARTCAST_IMPOSSIBLE_ON_IMPLICIT_INVOKE_RECEIVER",
};
pub const SPREAD_OF_NULLABLE = DiagnosticFactory{
    .name = "SPREAD_OF_NULLABLE",
    .default_severity = .Error,
    .message_template = "The spread operator (*foo) cannot be applied to an argument of nullable type.",
};
pub const SUBCLASS_OPT_IN_ARGUMENT_IS_NOT_MARKER = DiagnosticFactory{
    .name = "SUBCLASS_OPT_IN_ARGUMENT_IS_NOT_MARKER",
    .default_severity = .Error,
    .message_template = "SUBCLASS_OPT_IN_ARGUMENT_IS_NOT_MARKER",
};
pub const SUBCLASS_OPT_IN_INAPPLICABLE = DiagnosticFactory{
    .name = "SUBCLASS_OPT_IN_INAPPLICABLE",
    .default_severity = .Error,
    .message_template = "''@SubclassOptInRequired'' is not applicable to ''{0}''.",
};
pub const SUBTYPING_BETWEEN_CONTEXT_RECEIVERS = DiagnosticFactory{
    .name = "SUBTYPING_BETWEEN_CONTEXT_RECEIVERS",
    .default_severity = .Error,
    .message_template = "SUBTYPING_BETWEEN_CONTEXT_RECEIVERS",
};
pub const SUPERCLASS_NOT_ACCESSIBLE_FROM_INTERFACE = DiagnosticFactory{
    .name = "SUPERCLASS_NOT_ACCESSIBLE_FROM_INTERFACE",
    .default_severity = .Error,
    .message_template = "Superclass is not accessible from interface.",
};
pub const SUPERTYPES_FOR_ANNOTATION_CLASS = DiagnosticFactory{
    .name = "SUPERTYPES_FOR_ANNOTATION_CLASS",
    .default_severity = .Error,
    .message_template = "Annotation class cannot have supertypes.",
};
pub const SUPERTYPE_APPEARS_TWICE = DiagnosticFactory{
    .name = "SUPERTYPE_APPEARS_TWICE",
    .default_severity = .Error,
    .message_template = "A supertype appears twice.",
};
pub const SUPERTYPE_INITIALIZED_IN_EXPECTED_CLASS = DiagnosticFactory{
    .name = "SUPERTYPE_INITIALIZED_IN_EXPECTED_CLASS",
    .default_severity = .Error,
    .message_template = "Expected classes cannot initialize supertypes.",
};
pub const SUPERTYPE_INITIALIZED_IN_INTERFACE = DiagnosticFactory{
    .name = "SUPERTYPE_INITIALIZED_IN_INTERFACE",
    .default_severity = .Error,
    .message_template = "Interfaces cannot initialize supertypes.",
};
pub const SUPERTYPE_INITIALIZED_WITHOUT_PRIMARY_CONSTRUCTOR = DiagnosticFactory{
    .name = "SUPERTYPE_INITIALIZED_WITHOUT_PRIMARY_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Supertype initialization is impossible without a primary constructor.",
};
pub const SUPERTYPE_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE = DiagnosticFactory{
    .name = "SUPERTYPE_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE",
    .default_severity = .Error,
    .message_template = "Extension or contextual function type is not allowed as a supertype.",
};
pub const SUPERTYPE_NOT_A_CLASS_OR_INTERFACE = DiagnosticFactory{
    .name = "SUPERTYPE_NOT_A_CLASS_OR_INTERFACE",
    .default_severity = .Error,
    .message_template = "Supertype is not a class or interface.",
};
pub const SUPERTYPE_NOT_INITIALIZED = DiagnosticFactory{
    .name = "SUPERTYPE_NOT_INITIALIZED",
    .default_severity = .Error,
    .message_template = "This type has a constructor, so it must be initialized here.",
};
pub const SUPER_CALL_FROM_PUBLIC_INLINE = DiagnosticFactory{
    .name = "SUPER_CALL_FROM_PUBLIC_INLINE",
    .default_severity = .Error,
    .message_template = "Accessing super members from public-API inline {0} is deprecated.",
};
pub const SUPER_CALL_WITH_DEFAULT_PARAMETERS = DiagnosticFactory{
    .name = "SUPER_CALL_WITH_DEFAULT_PARAMETERS",
    .default_severity = .Error,
    .message_template = "SUPER_CALL_WITH_DEFAULT_PARAMETERS",
};
pub const SUPER_IS_NOT_AN_EXPRESSION = DiagnosticFactory{
    .name = "SUPER_IS_NOT_AN_EXPRESSION",
    .default_severity = .Error,
    .message_template = "'super' cannot be a callee.",
};
pub const SUPER_NOT_AVAILABLE = DiagnosticFactory{
    .name = "SUPER_NOT_AVAILABLE",
    .default_severity = .Error,
    .message_template = "No supertypes are accessible in this context.",
};
pub const SUSPEND_OVERRIDDEN_BY_NON_SUSPEND = DiagnosticFactory{
    .name = "SUSPEND_OVERRIDDEN_BY_NON_SUSPEND",
    .default_severity = .Error,
    .message_template = "SUSPEND_OVERRIDDEN_BY_NON_SUSPEND",
};
pub const TAILREC_ON_VIRTUAL_MEMBER_ERROR = DiagnosticFactory{
    .name = "TAILREC_ON_VIRTUAL_MEMBER_ERROR",
    .default_severity = .Error,
    .message_template = "Tailrec is prohibited on open members.",
};
pub const TAIL_RECURSION_IN_TRY_IS_NOT_SUPPORTED = DiagnosticFactory{
    .name = "TAIL_RECURSION_IN_TRY_IS_NOT_SUPPORTED",
    .default_severity = .Warning,
    .message_template = "Tail recursion optimization inside try/catch/finally is not supported.",
};
pub const THROWABLE_TYPE_MISMATCH = DiagnosticFactory{
    .name = "THROWABLE_TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "THROWABLE_TYPE_MISMATCH",
};
pub const TOO_MANY_ARGUMENTS = DiagnosticFactory{
    .name = "TOO_MANY_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "Too many arguments for ''{0}''.",
};
pub const TOO_MANY_CHARACTERS_IN_CHARACTER_LITERAL = DiagnosticFactory{
    .name = "TOO_MANY_CHARACTERS_IN_CHARACTER_LITERAL",
    .default_severity = .Error,
    .message_template = "Too many characters in a character literal.",
};
pub const TRIM_MARGIN_BLANK_PREFIX = DiagnosticFactory{
    .name = "TRIM_MARGIN_BLANK_PREFIX",
    .default_severity = .Warning,
    .message_template = "Prefix for trimMargin cannot be blank.",
};
pub const TYPEALIAS_EXPANDS_TO_ARRAY_OF_NOTHINGS = DiagnosticFactory{
    .name = "TYPEALIAS_EXPANDS_TO_ARRAY_OF_NOTHINGS",
    .default_severity = .Error,
    .message_template = "Type alias expanded to malformed type ''{0}''.",
};
pub const TYPEALIAS_EXPANSION_CAPTURES_OUTER_TYPE_PARAMETERS = DiagnosticFactory{
    .name = "TYPEALIAS_EXPANSION_CAPTURES_OUTER_TYPE_PARAMETERS",
    .default_severity = .Error,
    .message_template = "TYPEALIAS_EXPANSION_CAPTURES_OUTER_TYPE_PARAMETERS",
};
pub const TYPEALIAS_EXPANSION_DEPRECATION = DiagnosticFactory{
    .name = "TYPEALIAS_EXPANSION_DEPRECATION",
    .default_severity = .Warning,
    .message_template = "''{0}'' uses ''{1}'', which is deprecated. {2}.",
};
pub const TYPEALIAS_EXPANSION_DEPRECATION_ERROR = DiagnosticFactory{
    .name = "TYPEALIAS_EXPANSION_DEPRECATION_ERROR",
    .default_severity = .Error,
    .message_template = "''{0}'' uses ''{1}'', which is an error. {2}.",
};
pub const TYPEALIAS_SHOULD_EXPAND_TO_CLASS = DiagnosticFactory{
    .name = "TYPEALIAS_SHOULD_EXPAND_TO_CLASS",
    .default_severity = .Error,
    .message_template = "TYPEALIAS_SHOULD_EXPAND_TO_CLASS",
};
pub const TYPECHECKER_HAS_RUN_INTO_RECURSIVE_PROBLEM = DiagnosticFactory{
    .name = "TYPECHECKER_HAS_RUN_INTO_RECURSIVE_PROBLEM",
    .default_severity = .Error,
    .message_template = "Type checking has run into a recursive problem. Easiest workaround: specify the types of your declarations explicitly.",
};
pub const TYPE_ARGUMENTS_FOR_OUTER_CLASS_WHEN_NESTED_REFERENCED = DiagnosticFactory{
    .name = "TYPE_ARGUMENTS_FOR_OUTER_CLASS_WHEN_NESTED_REFERENCED",
    .default_severity = .Error,
    .message_template = "Type arguments for outer class are redundant when nested class is referenced.",
};
pub const TYPE_ARGUMENTS_NOT_ALLOWED = DiagnosticFactory{
    .name = "TYPE_ARGUMENTS_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Type arguments are not allowed {0}.",
};
pub const TYPE_ARGUMENTS_REDUNDANT_IN_SUPER_QUALIFIER = DiagnosticFactory{
    .name = "TYPE_ARGUMENTS_REDUNDANT_IN_SUPER_QUALIFIER",
    .default_severity = .Warning,
    .message_template = "Type arguments do not need to be specified in a 'super' qualifier.",
};
pub const TYPE_ARGUMENT_ON_TYPED_VALUE_CLASS_EQUALS = DiagnosticFactory{
    .name = "TYPE_ARGUMENT_ON_TYPED_VALUE_CLASS_EQUALS",
    .default_severity = .Error,
    .message_template = "Type arguments for typed value class equals must all be star projections.",
};
pub const TYPE_CANT_BE_USED_FOR_CONST_VAL = DiagnosticFactory{
    .name = "TYPE_CANT_BE_USED_FOR_CONST_VAL",
    .default_severity = .Error,
    .message_template = "Const ''val'' has type ''{0}''. Only primitive types and ''String'' are allowed.",
};
pub const TYPE_INFERENCE_ONLY_INPUT_TYPES_ERROR = DiagnosticFactory{
    .name = "TYPE_INFERENCE_ONLY_INPUT_TYPES_ERROR",
    .default_severity = .Error,
    .message_template = "TYPE_INFERENCE_ONLY_INPUT_TYPES_ERROR",
};
pub const TYPE_MISMATCH = DiagnosticFactory{
    .name = "TYPE_MISMATCH",
    .default_severity = .Error,
    .message_template = "TYPE_MISMATCH",
};
pub const TYPE_PARAMETERS_IN_ANONYMOUS_OBJECT = DiagnosticFactory{
    .name = "TYPE_PARAMETERS_IN_ANONYMOUS_OBJECT",
    .default_severity = .Error,
    .message_template = "Type parameters for anonymous objects are deprecated.",
};
pub const TYPE_PARAMETERS_IN_ENUM = DiagnosticFactory{
    .name = "TYPE_PARAMETERS_IN_ENUM",
    .default_severity = .Error,
    .message_template = "Enum class cannot have type parameters.",
};
pub const TYPE_PARAMETERS_IN_OBJECT = DiagnosticFactory{
    .name = "TYPE_PARAMETERS_IN_OBJECT",
    .default_severity = .Error,
    .message_template = "Type parameters are prohibited for objects.",
};
pub const TYPE_PARAMETERS_NOT_ALLOWED = DiagnosticFactory{
    .name = "TYPE_PARAMETERS_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "Type parameters are prohibited here.",
};
pub const TYPE_PARAMETER_AS_REIFIED = DiagnosticFactory{
    .name = "TYPE_PARAMETER_AS_REIFIED",
    .default_severity = .Error,
    .message_template = "Cannot use ''{0}'' as reified type parameter. Use a class instead.",
};
pub const TYPE_PARAMETER_AS_REIFIED_ARRAY_ERROR = DiagnosticFactory{
    .name = "TYPE_PARAMETER_AS_REIFIED_ARRAY_ERROR",
    .default_severity = .Error,
    .message_template = "TYPE_PARAMETER_AS_REIFIED_ARRAY_ERROR",
};
pub const TYPE_PARAMETER_IN_CATCH_CLAUSE = DiagnosticFactory{
    .name = "TYPE_PARAMETER_IN_CATCH_CLAUSE",
    .default_severity = .Error,
    .message_template = "Non-reified type parameters cannot be used by catch parameters.",
};
pub const TYPE_PARAMETER_IS_NOT_AN_EXPRESSION = DiagnosticFactory{
    .name = "TYPE_PARAMETER_IS_NOT_AN_EXPRESSION",
    .default_severity = .Error,
    .message_template = "Type parameter ''{0}'' is not an expression.",
};
pub const TYPE_PARAMETER_ON_LHS_OF_DOT = DiagnosticFactory{
    .name = "TYPE_PARAMETER_ON_LHS_OF_DOT",
    .default_severity = .Error,
    .message_template = "TYPE_PARAMETER_ON_LHS_OF_DOT",
};
pub const TYPE_VARIANCE_CONFLICT_ERROR = DiagnosticFactory{
    .name = "TYPE_VARIANCE_CONFLICT_ERROR",
    .default_severity = .Error,
    .message_template = "TYPE_VARIANCE_CONFLICT_ERROR",
};
pub const TYPE_VARIANCE_CONFLICT_IN_EXPANDED_TYPE = DiagnosticFactory{
    .name = "TYPE_VARIANCE_CONFLICT_IN_EXPANDED_TYPE",
    .default_severity = .Error,
    .message_template = "TYPE_VARIANCE_CONFLICT_IN_EXPANDED_TYPE",
};
pub const UNCHECKED_CAST = DiagnosticFactory{
    .name = "UNCHECKED_CAST",
    .default_severity = .Warning,
    .message_template = "Unchecked cast of ''{0}'' to ''{1}''.",
};
pub const UNDERSCORE_IS_RESERVED = DiagnosticFactory{
    .name = "UNDERSCORE_IS_RESERVED",
    .default_severity = .Error,
    .message_template = "UNDERSCORE_IS_RESERVED",
};
pub const UNDERSCORE_USAGE_WITHOUT_BACKTICKS = DiagnosticFactory{
    .name = "UNDERSCORE_USAGE_WITHOUT_BACKTICKS",
    .default_severity = .Error,
    .message_template = "UNDERSCORE_USAGE_WITHOUT_BACKTICKS",
};
pub const UNEXPECTED_SAFE_CALL = DiagnosticFactory{
    .name = "UNEXPECTED_SAFE_CALL",
    .default_severity = .Error,
    .message_template = "Safe call is prohibited here.",
};
pub const UNEXPECTED_TRAILING_LAMBDA_ON_A_NEW_LINE = DiagnosticFactory{
    .name = "UNEXPECTED_TRAILING_LAMBDA_ON_A_NEW_LINE",
    .default_severity = .Error,
    .message_template = "Expression is treated as a trailing lambda argument; consider separating it from the call with semicolon.",
};
pub const UNINITIALIZED_ENUM_COMPANION = DiagnosticFactory{
    .name = "UNINITIALIZED_ENUM_COMPANION",
    .default_severity = .Error,
    .message_template = "Companion object of enum class ''{0}'' is uninitialized here.",
};
pub const UNINITIALIZED_ENUM_ENTRY = DiagnosticFactory{
    .name = "UNINITIALIZED_ENUM_ENTRY",
    .default_severity = .Error,
    .message_template = "Enum entry ''{0}'' is uninitialized here.",
};
pub const UNINITIALIZED_PARAMETER = DiagnosticFactory{
    .name = "UNINITIALIZED_PARAMETER",
    .default_severity = .Error,
    .message_template = "Parameter ''{0}'' is uninitialized here.",
};
pub const UNINITIALIZED_VARIABLE = DiagnosticFactory{
    .name = "UNINITIALIZED_VARIABLE",
    .default_severity = .Error,
    .message_template = "Variable ''{0}'' must be initialized.",
};
pub const UNNAMED_DELEGATED_PROPERTY = DiagnosticFactory{
    .name = "UNNAMED_DELEGATED_PROPERTY",
    .default_severity = .Error,
    .message_template = "Delegated properties require a name.",
};
pub const UNNAMED_VAR_PROPERTY = DiagnosticFactory{
    .name = "UNNAMED_VAR_PROPERTY",
    .default_severity = .Error,
    .message_template = "'var' properties require a name.",
};
pub const UNNECESSARY_LATEINIT = DiagnosticFactory{
    .name = "UNNECESSARY_LATEINIT",
    .default_severity = .Warning,
    .message_template = "'lateinit' is unnecessary: definitely initialized in constructors.",
};
pub const UNNECESSARY_NOT_NULL_ASSERTION = DiagnosticFactory{
    .name = "UNNECESSARY_NOT_NULL_ASSERTION",
    .default_severity = .Warning,
    .message_template = "Unnecessary non-null assertion (!!) on a non-null receiver of type ''{0}''.",
};
pub const UNNECESSARY_SAFE_CALL = DiagnosticFactory{
    .name = "UNNECESSARY_SAFE_CALL",
    .default_severity = .Warning,
    .message_template = "Unnecessary safe call on a non-null receiver of type ''{0}''.",
};
pub const UNREACHABLE_CODE = DiagnosticFactory{
    .name = "UNREACHABLE_CODE",
    .default_severity = .Warning,
    .message_template = "Unreachable code.",
};
pub const UNRESOLVED_IMPORT = DiagnosticFactory{
    .name = "UNRESOLVED_IMPORT",
    .default_severity = .Error,
    .message_template = "UNRESOLVED_IMPORT",
};
pub const UNRESOLVED_LABEL = DiagnosticFactory{
    .name = "UNRESOLVED_LABEL",
    .default_severity = .Error,
    .message_template = "Unresolved label.",
};
pub const UNRESOLVED_REFERENCE = DiagnosticFactory{
    .name = "UNRESOLVED_REFERENCE",
    .default_severity = .Error,
    .message_template = "UNRESOLVED_REFERENCE",
};
pub const UNRESOLVED_REFERENCE_WRONG_RECEIVER = DiagnosticFactory{
    .name = "UNRESOLVED_REFERENCE_WRONG_RECEIVER",
    .default_severity = .Error,
    .message_template = "UNRESOLVED_REFERENCE_WRONG_RECEIVER",
};
pub const UNSAFE_CALL = DiagnosticFactory{
    .name = "UNSAFE_CALL",
    .default_severity = .Error,
    .message_template = "UNSAFE_CALL",
};
pub const UNSAFE_CALLABLE_REFERENCE = DiagnosticFactory{
    .name = "UNSAFE_CALLABLE_REFERENCE",
    .default_severity = .Error,
    .message_template = "UNSAFE_CALLABLE_REFERENCE",
};
pub const UNSAFE_IMPLICIT_INVOKE_CALL = DiagnosticFactory{
    .name = "UNSAFE_IMPLICIT_INVOKE_CALL",
    .default_severity = .Error,
    .message_template = "UNSAFE_IMPLICIT_INVOKE_CALL",
};
pub const UNSAFE_INFIX_CALL = DiagnosticFactory{
    .name = "UNSAFE_INFIX_CALL",
    .default_severity = .Error,
    .message_template = "UNSAFE_INFIX_CALL",
};
pub const UNSAFE_OPERATOR_CALL = DiagnosticFactory{
    .name = "UNSAFE_OPERATOR_CALL",
    .default_severity = .Error,
    .message_template = "UNSAFE_OPERATOR_CALL",
};
pub const UNSIGNED_LITERAL_WITHOUT_DECLARATIONS_ON_CLASSPATH = DiagnosticFactory{
    .name = "UNSIGNED_LITERAL_WITHOUT_DECLARATIONS_ON_CLASSPATH",
    .default_severity = .Error,
    .message_template = "UNSIGNED_LITERAL_WITHOUT_DECLARATIONS_ON_CLASSPATH",
};
pub const UNSUPPORTED = DiagnosticFactory{
    .name = "UNSUPPORTED",
    .default_severity = .Error,
    .message_template = "{0}",
};
pub const UNSUPPORTED_CLASS_LITERALS_WITH_EMPTY_LHS = DiagnosticFactory{
    .name = "UNSUPPORTED_CLASS_LITERALS_WITH_EMPTY_LHS",
    .default_severity = .Error,
    .message_template = "Class literals with empty left hand side are unsupported.",
};
pub const UNSUPPORTED_COLLECTION_LITERAL_TYPE = DiagnosticFactory{
    .name = "UNSUPPORTED_COLLECTION_LITERAL_TYPE",
    .default_severity = .Error,
    .message_template = "UNSUPPORTED_COLLECTION_LITERAL_TYPE",
};
pub const UNSUPPORTED_CONTEXTUAL_DECLARATION_CALL = DiagnosticFactory{
    .name = "UNSUPPORTED_CONTEXTUAL_DECLARATION_CALL",
    .default_severity = .Error,
    .message_template = "UNSUPPORTED_CONTEXTUAL_DECLARATION_CALL",
};
pub const UNSUPPORTED_FEATURE = DiagnosticFactory{
    .name = "UNSUPPORTED_FEATURE",
    .default_severity = .Error,
    .message_template = "{0}",
};
pub const UNSUPPORTED_INHERITANCE_FROM_JAVA_MEMBER_REFERENCING_KOTLIN_FUNCTION = DiagnosticFactory{
    .name = "UNSUPPORTED_INHERITANCE_FROM_JAVA_MEMBER_REFERENCING_KOTLIN_FUNCTION",
    .default_severity = .Error,
    .message_template = "UNSUPPORTED_INHERITANCE_FROM_JAVA_MEMBER_REFERENCING_KOTLIN_FUNCTION",
};
pub const UNSUPPORTED_SEALED_FUN_INTERFACE = DiagnosticFactory{
    .name = "UNSUPPORTED_SEALED_FUN_INTERFACE",
    .default_severity = .Error,
    .message_template = "'sealed fun interface' is unsupported.",
};
pub const UNSUPPORTED_SUSPEND_TEST = DiagnosticFactory{
    .name = "UNSUPPORTED_SUSPEND_TEST",
    .default_severity = .Error,
    .message_template = "'suspend' functions annotated with '@kotlin.test.Test' are unsupported.",
};
pub const UNUSED_ANONYMOUS_PARAMETER = DiagnosticFactory{
    .name = "UNUSED_ANONYMOUS_PARAMETER",
    .default_severity = .Warning,
    .message_template = "Parameter ''{0}'' is never used, consider renaming it to ''_''.",
};
pub const UNUSED_EXPRESSION = DiagnosticFactory{
    .name = "UNUSED_EXPRESSION",
    .default_severity = .Warning,
    .message_template = "Expression is unused.",
};
pub const UNUSED_LAMBDA_EXPRESSION = DiagnosticFactory{
    .name = "UNUSED_LAMBDA_EXPRESSION",
    .default_severity = .Warning,
    .message_template = "Lambda expression is never invoked. To create a scoped block, use 'run { ... }'.",
};
pub const UNUSED_VARIABLE = DiagnosticFactory{
    .name = "UNUSED_VARIABLE",
    .default_severity = .Warning,
    .message_template = "Variable is unused.",
};
pub const UPPER_BOUND_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE = DiagnosticFactory{
    .name = "UPPER_BOUND_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE",
    .default_severity = .Error,
    .message_template = "UPPER_BOUND_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE",
};
pub const UPPER_BOUND_VIOLATED = DiagnosticFactory{
    .name = "UPPER_BOUND_VIOLATED",
    .default_severity = .Error,
    .message_template = "UPPER_BOUND_VIOLATED",
};
pub const UPPER_BOUND_VIOLATED_DEPRECATION_WARNING = DiagnosticFactory{
    .name = "UPPER_BOUND_VIOLATED_DEPRECATION_WARNING",
    .default_severity = .Warning,
    .message_template = "UPPER_BOUND_VIOLATED_DEPRECATION_WARNING",
};
pub const UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION = DiagnosticFactory{
    .name = "UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION",
    .default_severity = .Error,
    .message_template = "UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION",
};
pub const UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION_DEPRECATION_WARNING = DiagnosticFactory{
    .name = "UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION_DEPRECATION_WARNING",
    .default_severity = .Warning,
    .message_template = "UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION_DEPRECATION_WARNING",
};
pub const USAGE_IS_NOT_INLINABLE = DiagnosticFactory{
    .name = "USAGE_IS_NOT_INLINABLE",
    .default_severity = .Error,
    .message_template = "USAGE_IS_NOT_INLINABLE",
};
pub const USELESS_CALL_ON_NOT_NULL = DiagnosticFactory{
    .name = "USELESS_CALL_ON_NOT_NULL",
    .default_severity = .Warning,
    .message_template = "Unnecessary call on a non-null value.",
};
pub const USELESS_CAST = DiagnosticFactory{
    .name = "USELESS_CAST",
    .default_severity = .Warning,
    .message_template = "No cast needed.",
};
pub const USELESS_ELVIS = DiagnosticFactory{
    .name = "USELESS_ELVIS",
    .default_severity = .Warning,
    .message_template = "Elvis operator (?:) always returns the left operand of non-nullable type ''{0}''.",
};
pub const USELESS_ELVIS_LEFT_IS_NULL = DiagnosticFactory{
    .name = "USELESS_ELVIS_LEFT_IS_NULL",
    .default_severity = .Warning,
    .message_template = "Elvis operator (?:) is useless if the left operand is null.",
};
pub const USELESS_ELVIS_RIGHT_IS_NULL = DiagnosticFactory{
    .name = "USELESS_ELVIS_RIGHT_IS_NULL",
    .default_severity = .Warning,
    .message_template = "Right operand of elvis operator (?:) is useless if it is null.",
};
pub const USELESS_IS_CHECK = DiagnosticFactory{
    .name = "USELESS_IS_CHECK",
    .default_severity = .Warning,
    .message_template = "Check for instance is always ''{0}''.",
};
pub const USELESS_VARARG_ON_PARAMETER = DiagnosticFactory{
    .name = "USELESS_VARARG_ON_PARAMETER",
    .default_severity = .Warning,
    .message_template = "Vararg on this parameter is useless.",
};
pub const VALUE_CLASS_CANNOT_BE_CLONEABLE = DiagnosticFactory{
    .name = "VALUE_CLASS_CANNOT_BE_CLONEABLE",
    .default_severity = .Error,
    .message_template = "Value class cannot be 'Cloneable'.",
};
pub const VALUE_CLASS_CANNOT_BE_RECURSIVE = DiagnosticFactory{
    .name = "VALUE_CLASS_CANNOT_BE_RECURSIVE",
    .default_severity = .Error,
    .message_template = "Value class cannot be recursive.",
};
pub const VALUE_CLASS_CANNOT_EXTEND_CLASSES = DiagnosticFactory{
    .name = "VALUE_CLASS_CANNOT_EXTEND_CLASSES",
    .default_severity = .Error,
    .message_template = "Value class cannot extend classes.",
};
pub const VALUE_CLASS_CANNOT_HAVE_CONTEXT_RECEIVERS = DiagnosticFactory{
    .name = "VALUE_CLASS_CANNOT_HAVE_CONTEXT_RECEIVERS",
    .default_severity = .Error,
    .message_template = "Value classes cannot have context receivers.",
};
pub const VALUE_CLASS_CANNOT_IMPLEMENT_INTERFACE_BY_DELEGATION = DiagnosticFactory{
    .name = "VALUE_CLASS_CANNOT_IMPLEMENT_INTERFACE_BY_DELEGATION",
    .default_severity = .Error,
    .message_template = "Value class cannot implement an interface by delegation.",
};
pub const VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER = DiagnosticFactory{
    .name = "VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER",
    .default_severity = .Error,
    .message_template = "VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER",
};
pub const VALUE_CLASS_EMPTY_CONSTRUCTOR = DiagnosticFactory{
    .name = "VALUE_CLASS_EMPTY_CONSTRUCTOR",
    .default_severity = .Error,
    .message_template = "Value class must have at least one primary constructor parameter.",
};
pub const VALUE_CLASS_HAS_INAPPLICABLE_PARAMETER_TYPE = DiagnosticFactory{
    .name = "VALUE_CLASS_HAS_INAPPLICABLE_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "Value class cannot have value parameter of type ''{0}''.",
};
pub const VALUE_CLASS_NOT_FINAL = DiagnosticFactory{
    .name = "VALUE_CLASS_NOT_FINAL",
    .default_severity = .Error,
    .message_template = "Value class can be only final.",
};
pub const VALUE_CLASS_NOT_TOP_LEVEL = DiagnosticFactory{
    .name = "VALUE_CLASS_NOT_TOP_LEVEL",
    .default_severity = .Error,
    .message_template = "Value class cannot be local or inner.",
};
pub const VALUE_PARAMETER_WITHOUT_EXPLICIT_TYPE = DiagnosticFactory{
    .name = "VALUE_PARAMETER_WITHOUT_EXPLICIT_TYPE",
    .default_severity = .Error,
    .message_template = "An explicit type is required on a value parameter.",
};
pub const VAL_OR_VAR_ON_CATCH_PARAMETER = DiagnosticFactory{
    .name = "VAL_OR_VAR_ON_CATCH_PARAMETER",
    .default_severity = .Error,
    .message_template = "''{0}'' on catch parameter is prohibited.",
};
pub const VAL_OR_VAR_ON_FUN_PARAMETER = DiagnosticFactory{
    .name = "VAL_OR_VAR_ON_FUN_PARAMETER",
    .default_severity = .Error,
    .message_template = "''{0}'' on function parameter is prohibited.",
};
pub const VAL_OR_VAR_ON_LOOP_PARAMETER = DiagnosticFactory{
    .name = "VAL_OR_VAR_ON_LOOP_PARAMETER",
    .default_severity = .Error,
    .message_template = "''{0}'' on loop parameter is prohibited.",
};
pub const VAL_OR_VAR_ON_SECONDARY_CONSTRUCTOR_PARAMETER = DiagnosticFactory{
    .name = "VAL_OR_VAR_ON_SECONDARY_CONSTRUCTOR_PARAMETER",
    .default_severity = .Error,
    .message_template = "''{0}'' on secondary constructor parameter is prohibited.",
};
pub const VAL_REASSIGNMENT = DiagnosticFactory{
    .name = "VAL_REASSIGNMENT",
    .default_severity = .Error,
    .message_template = "''val'' cannot be reassigned.",
};
pub const VAL_REASSIGNMENT_VIA_BACKING_FIELD_ERROR = DiagnosticFactory{
    .name = "VAL_REASSIGNMENT_VIA_BACKING_FIELD_ERROR",
    .default_severity = .Error,
    .message_template = "Reassignment of read-only property via backing field.",
};
pub const VAL_WITH_SETTER = DiagnosticFactory{
    .name = "VAL_WITH_SETTER",
    .default_severity = .Error,
    .message_template = "A 'val' property cannot have a setter.",
};
pub const VARARG_OUTSIDE_PARENTHESES = DiagnosticFactory{
    .name = "VARARG_OUTSIDE_PARENTHESES",
    .default_severity = .Error,
    .message_template = "Passing value as a vararg is allowed only inside a parenthesized argument list.",
};
pub const VARIABLE_EXPECTED = DiagnosticFactory{
    .name = "VARIABLE_EXPECTED",
    .default_severity = .Error,
    .message_template = "Variable expected.",
};
pub const VARIABLE_INITIALIZER_IS_REDUNDANT = DiagnosticFactory{
    .name = "VARIABLE_INITIALIZER_IS_REDUNDANT",
    .default_severity = .Warning,
    .message_template = "Initializer is redundant.",
};
pub const VARIABLE_NEVER_READ = DiagnosticFactory{
    .name = "VARIABLE_NEVER_READ",
    .default_severity = .Warning,
    .message_template = "Variable is never read.",
};
pub const VARIABLE_WITH_NO_TYPE_NO_INITIALIZER = DiagnosticFactory{
    .name = "VARIABLE_WITH_NO_TYPE_NO_INITIALIZER",
    .default_severity = .Error,
    .message_template = "This variable must either have an explicit type or be initialized.",
};
pub const VARIANCE_ON_TYPE_PARAMETER_NOT_ALLOWED = DiagnosticFactory{
    .name = "VARIANCE_ON_TYPE_PARAMETER_NOT_ALLOWED",
    .default_severity = .Error,
    .message_template = "VARIANCE_ON_TYPE_PARAMETER_NOT_ALLOWED",
};
pub const VAR_ANNOTATION_PARAMETER = DiagnosticFactory{
    .name = "VAR_ANNOTATION_PARAMETER",
    .default_severity = .Error,
    .message_template = "An annotation parameter cannot be 'var'.",
};
pub const VAR_OVERRIDDEN_BY_VAL = DiagnosticFactory{
    .name = "VAR_OVERRIDDEN_BY_VAL",
    .default_severity = .Error,
    .message_template = "VAR_OVERRIDDEN_BY_VAL",
};
pub const VAR_OVERRIDDEN_BY_VAL_BY_DELEGATION = DiagnosticFactory{
    .name = "VAR_OVERRIDDEN_BY_VAL_BY_DELEGATION",
    .default_severity = .Error,
    .message_template = "VAR_OVERRIDDEN_BY_VAL_BY_DELEGATION",
};
pub const VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD = DiagnosticFactory{
    .name = "VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
    .default_severity = .Error,
    .message_template = "VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD",
};
pub const VAR_TYPE_MISMATCH_ON_INHERITANCE = DiagnosticFactory{
    .name = "VAR_TYPE_MISMATCH_ON_INHERITANCE",
    .default_severity = .Error,
    .message_template = "VAR_TYPE_MISMATCH_ON_INHERITANCE",
};
pub const VAR_TYPE_MISMATCH_ON_OVERRIDE = DiagnosticFactory{
    .name = "VAR_TYPE_MISMATCH_ON_OVERRIDE",
    .default_severity = .Error,
    .message_template = "VAR_TYPE_MISMATCH_ON_OVERRIDE",
};
pub const VERSION_OVERLOADS_TOO_COMPLEX_EXPRESSION = DiagnosticFactory{
    .name = "VERSION_OVERLOADS_TOO_COMPLEX_EXPRESSION",
    .default_severity = .Error,
    .message_template = "VERSION_OVERLOADS_TOO_COMPLEX_EXPRESSION",
};
pub const VERSION_REQUIREMENT_DEPRECATION = DiagnosticFactory{
    .name = "VERSION_REQUIREMENT_DEPRECATION",
    .default_severity = .Warning,
    .message_template = "''{0}''{1} should not be used in Kotlin {2}.{3}",
};
pub const VERSION_REQUIREMENT_DEPRECATION_ERROR = DiagnosticFactory{
    .name = "VERSION_REQUIREMENT_DEPRECATION_ERROR",
    .default_severity = .Error,
    .message_template = "''{0}''{1} cannot be used in Kotlin {2}.{3}",
};
pub const VIRTUAL_MEMBER_HIDDEN = DiagnosticFactory{
    .name = "VIRTUAL_MEMBER_HIDDEN",
    .default_severity = .Error,
    .message_template = "VIRTUAL_MEMBER_HIDDEN",
};
pub const VOLATILE_ON_DELEGATE = DiagnosticFactory{
    .name = "VOLATILE_ON_DELEGATE",
    .default_severity = .Error,
    .message_template = "'@Volatile' annotation cannot be used on delegated properties.",
};
pub const VOLATILE_ON_VALUE = DiagnosticFactory{
    .name = "VOLATILE_ON_VALUE",
    .default_severity = .Error,
    .message_template = "'@Volatile' annotation cannot be used on immutable properties.",
};
pub const WHEN_GUARD_WITHOUT_SUBJECT = DiagnosticFactory{
    .name = "WHEN_GUARD_WITHOUT_SUBJECT",
    .default_severity = .Error,
    .message_template = "WHEN_GUARD_WITHOUT_SUBJECT",
};
pub const WRONG_ANNOTATION_TARGET = DiagnosticFactory{
    .name = "WRONG_ANNOTATION_TARGET",
    .default_severity = .Error,
    .message_template = "WRONG_ANNOTATION_TARGET",
};
pub const WRONG_ANNOTATION_TARGET_WARNING = DiagnosticFactory{
    .name = "WRONG_ANNOTATION_TARGET_WARNING",
    .default_severity = .Warning,
    .message_template = "WRONG_ANNOTATION_TARGET_WARNING",
};
pub const WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET = DiagnosticFactory{
    .name = "WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET",
    .default_severity = .Error,
    .message_template = "WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET",
};
pub const WRONG_CONDITION_SUGGEST_GUARD = DiagnosticFactory{
    .name = "WRONG_CONDITION_SUGGEST_GUARD",
    .default_severity = .Error,
    .message_template = "WRONG_CONDITION_SUGGEST_GUARD",
};
pub const WRONG_EXTENSION_FUNCTION_TYPE = DiagnosticFactory{
    .name = "WRONG_EXTENSION_FUNCTION_TYPE",
    .default_severity = .Error,
    .message_template = "WRONG_EXTENSION_FUNCTION_TYPE",
};
pub const WRONG_EXTENSION_FUNCTION_TYPE_WARNING = DiagnosticFactory{
    .name = "WRONG_EXTENSION_FUNCTION_TYPE_WARNING",
    .default_severity = .Warning,
    .message_template = "WRONG_EXTENSION_FUNCTION_TYPE_WARNING",
};
pub const WRONG_GETTER_RETURN_TYPE = DiagnosticFactory{
    .name = "WRONG_GETTER_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "WRONG_GETTER_RETURN_TYPE",
};
pub const WRONG_INVOCATION_KIND = DiagnosticFactory{
    .name = "WRONG_INVOCATION_KIND",
    .default_severity = .Warning,
    .message_template = "WRONG_INVOCATION_KIND",
};
pub const WRONG_LONG_SUFFIX = DiagnosticFactory{
    .name = "WRONG_LONG_SUFFIX",
    .default_severity = .Error,
    .message_template = "Use 'L' instead of 'l'.",
};
pub const WRONG_MODIFIER_CONTAINING_DECLARATION = DiagnosticFactory{
    .name = "WRONG_MODIFIER_CONTAINING_DECLARATION",
    .default_severity = .Error,
    .message_template = "Modifier ''{0}'' is not applicable inside ''{1}''.",
};
pub const WRONG_MODIFIER_TARGET = DiagnosticFactory{
    .name = "WRONG_MODIFIER_TARGET",
    .default_severity = .Error,
    .message_template = "Modifier ''{0}'' is not applicable to ''{1}''.",
};
pub const WRONG_NUMBER_OF_TYPE_ARGUMENTS = DiagnosticFactory{
    .name = "WRONG_NUMBER_OF_TYPE_ARGUMENTS",
    .default_severity = .Error,
    .message_template = "WRONG_NUMBER_OF_TYPE_ARGUMENTS",
};
pub const WRONG_SETTER_PARAMETER_TYPE = DiagnosticFactory{
    .name = "WRONG_SETTER_PARAMETER_TYPE",
    .default_severity = .Error,
    .message_template = "WRONG_SETTER_PARAMETER_TYPE",
};
pub const WRONG_SETTER_RETURN_TYPE = DiagnosticFactory{
    .name = "WRONG_SETTER_RETURN_TYPE",
    .default_severity = .Error,
    .message_template = "WRONG_SETTER_RETURN_TYPE",
};

pub const FACTORIES = [_]*const DiagnosticFactory{
    &ABBREVIATED_NOTHING_PROPERTY_TYPE,
    &ABBREVIATED_NOTHING_RETURN_TYPE,
    &ABSENCE_OF_PRIMARY_CONSTRUCTOR_FOR_VALUE_CLASS,
    &ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED,
    &ABSTRACT_DELEGATED_PROPERTY,
    &ABSTRACT_FUNCTION_IN_NON_ABSTRACT_CLASS,
    &ABSTRACT_FUNCTION_WITH_BODY,
    &ABSTRACT_MEMBER_NOT_IMPLEMENTED,
    &ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY,
    &ABSTRACT_PROPERTY_IN_NON_ABSTRACT_CLASS,
    &ABSTRACT_PROPERTY_IN_PRIMARY_CONSTRUCTOR_PARAMETERS,
    &ABSTRACT_PROPERTY_WITHOUT_TYPE,
    &ABSTRACT_PROPERTY_WITH_GETTER,
    &ABSTRACT_PROPERTY_WITH_INITIALIZER,
    &ABSTRACT_PROPERTY_WITH_SETTER,
    &ABSTRACT_SUPER_CALL,
    &ABSTRACT_SUPER_CALL_WARNING,
    &ACCESSOR_FOR_DELEGATED_PROPERTY,
    &ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT,
    &ACTUAL_FUNCTION_WITH_DEFAULT_ARGUMENTS,
    &ACTUAL_IGNORABILITY_NOT_MATCH_EXPECT,
    &ACTUAL_MISSING,
    &ACTUAL_TYPEALIAS_TO_SPECIAL_ANNOTATION,
    &ACTUAL_TYPE_ALIAS_NOT_TO_CLASS,
    &ACTUAL_TYPE_ALIAS_TO_CLASS_WITH_DECLARATION_SITE_VARIANCE,
    &ACTUAL_TYPE_ALIAS_TO_NOTHING,
    &ACTUAL_TYPE_ALIAS_TO_NULLABLE_TYPE,
    &ACTUAL_TYPE_ALIAS_WITH_COMPLEX_SUBSTITUTION,
    &ACTUAL_TYPE_ALIAS_WITH_USE_SITE_VARIANCE,
    &ACTUAL_WITHOUT_EXPECT,
    &ADAPTED_CALLABLE_REFERENCE_AGAINST_REFLECTION_TYPE,
    &AMBIGUOUS_ALTERED_ASSIGN,
    &AMBIGUOUS_ANNOTATION_ARGUMENT,
    &AMBIGUOUS_ANONYMOUS_TYPE_INFERRED,
    &AMBIGUOUS_CALL_WITH_IMPLICIT_CONTEXT_RECEIVER,
    &AMBIGUOUS_CONTEXT_ARGUMENT,
    &AMBIGUOUS_EXPECTS,
    &AMBIGUOUS_FUNCTION_TYPE_KIND,
    &AMBIGUOUS_LABEL,
    &AMBIGUOUS_SUPER,
    &ANNOTATIONS_ON_BLOCK_LEVEL_EXPRESSION_ON_THE_SAME_LINE,
    &ANNOTATION_ARGUMENT_KCLASS_LITERAL_OF_TYPE_PARAMETER_ERROR,
    &ANNOTATION_ARGUMENT_MUST_BE_CONST,
    &ANNOTATION_ARGUMENT_MUST_BE_ENUM_CONST,
    &ANNOTATION_ARGUMENT_MUST_BE_KCLASS_LITERAL,
    &ANNOTATION_CLASS_CONSTRUCTOR_CALL,
    &ANNOTATION_CLASS_MEMBER,
    &ANNOTATION_IN_CONTRACT_ERROR,
    &ANNOTATION_IN_WHERE_CLAUSE_ERROR,
    &ANNOTATION_ON_ANNOTATION_ARGUMENT,
    &ANNOTATION_ON_ILLEGAL_MULTI_FIELD_VALUE_CLASS_TYPED_TARGET,
    &ANNOTATION_ON_SUPERCLASS_ERROR,
    &ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT,
    &ANNOTATION_USED_AS_ANNOTATION_ARGUMENT,
    &ANNOTATION_WILL_BE_APPLIED_ALSO_TO_PROPERTY_OR_FIELD,
    &ANONYMOUS_FUNCTION_PARAMETER_WITH_DEFAULT_VALUE,
    &ANONYMOUS_FUNCTION_WITH_NAME,
    &ANONYMOUS_INITIALIZER_IN_INTERFACE,
    &ANONYMOUS_SUSPEND_FUNCTION,
    &API_NOT_AVAILABLE,
    &ARGUMENT_PASSED_TWICE,
    &ARGUMENT_TYPE_MISMATCH,
    &ARRAY_EQUALITY_OPERATOR_CAN_BE_REPLACED_WITH_CONTENT_EQUALS,
    &ASSIGNED_VALUE_IS_NEVER_READ,
    &ASSIGNMENT_IN_EXPRESSION_CONTEXT,
    &ASSIGNMENT_OPERATOR_SHOULD_RETURN_UNIT,
    &ASSIGNMENT_TYPE_MISMATCH,
    &ASSIGN_OPERATOR_AMBIGUITY,
    &ATOMIC_REF_CALL_ARGUMENT_WITHOUT_CONSISTENT_IDENTITY,
    &ATOMIC_REF_WITHOUT_CONSISTENT_IDENTITY,
    &BACKING_FIELD_FOR_DELEGATED_PROPERTY,
    &BACKING_FIELD_IN_INTERFACE,
    &BOUNDS_NOT_ALLOWED_IF_BOUNDED_BY_TYPE_PARAMETER,
    &BOUND_ON_TYPE_ALIAS_PARAMETER_NOT_ALLOWED,
    &BREAK_OR_CONTINUE_JUMPS_ACROSS_FUNCTION_BOUNDARY,
    &BREAK_OR_CONTINUE_OUTSIDE_A_LOOP,
    &BUILDER_INFERENCE_MULTI_LAMBDA_RESTRICTION,
    &BUILDER_INFERENCE_STUB_RECEIVER,
    &CALLABLE_REFERENCE_LHS_NOT_A_CLASS,
    &CALLABLE_REFERENCE_TO_ANNOTATION_CONSTRUCTOR,
    &CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION,
    &CANNOT_ALL_UNDER_IMPORT_FROM_SINGLETON,
    &CANNOT_BE_IMPORTED,
    &CANNOT_CHANGE_ACCESS_PRIVILEGE,
    &CANNOT_CHANGE_ACCESS_PRIVILEGE_WARNING,
    &CANNOT_CHECK_FOR_ERASED,
    &CANNOT_INFER_IT_PARAMETER_TYPE,
    &CANNOT_INFER_PARAMETER_TYPE,
    &CANNOT_INFER_RECEIVER_PARAMETER_TYPE,
    &CANNOT_INFER_VALUE_PARAMETER_TYPE,
    &CANNOT_INFER_VISIBILITY,
    &CANNOT_INFER_VISIBILITY_WARNING,
    &CANNOT_OVERRIDE_INVISIBLE_MEMBER,
    &CANNOT_WEAKEN_ACCESS_PRIVILEGE,
    &CANNOT_WEAKEN_ACCESS_PRIVILEGE_WARNING,
    &CAN_BE_VAL,
    &CAN_BE_VAL_DELAYED_INITIALIZATION,
    &CAN_BE_VAL_LATEINIT,
    &CAPTURED_MEMBER_VAL_INITIALIZATION,
    &CAPTURED_VAL_INITIALIZATION,
    &CAST_NEVER_SUCCEEDS,
    &CATCH_PARAMETER_WITH_DEFAULT_VALUE,
    &CLASSIFIER_REDECLARATION,
    &CLASS_CANNOT_BE_EXTENDED_DIRECTLY,
    &CLASS_INHERITS_JAVA_SEALED_CLASS,
    &CLASS_IN_SUPERTYPE_FOR_ENUM,
    &CLASS_LITERAL_LHS_NOT_A_CLASS,
    &COMMA_IN_WHEN_CONDITION_WITHOUT_ARGUMENT,
    &COMMA_IN_WHEN_CONDITION_WITH_WHEN_GUARD,
    &COMPARE_TO_TYPE_MISMATCH,
    &COMPILER_REQUIRED_ANNOTATION_AMBIGUITY,
    &COMPONENT_FUNCTION_AMBIGUITY,
    &COMPONENT_FUNCTION_MISSING,
    &COMPONENT_FUNCTION_ON_NULLABLE,
    &COMPONENT_FUNCTION_RETURN_TYPE_MISMATCH,
    &CONDITION_TYPE_MISMATCH,
    &CONFLICTING_IMPORT,
    &CONFLICTING_INHERITED_MEMBERS,
    &CONFLICTING_OVERLOADS,
    &CONFLICTING_PROJECTION,
    &CONFLICTING_PROJECTION_IN_TYPEALIAS_EXPANSION,
    &CONFLICTING_UPPER_BOUNDS,
    &CONFUSING_BRANCH_CONDITION_ERROR,
    &CONSTRUCTOR_IN_INTERFACE,
    &CONSTRUCTOR_IN_OBJECT,
    &CONST_VAL_NOT_TOP_LEVEL_OR_OBJECT,
    &CONST_VAL_WITHOUT_INITIALIZER,
    &CONST_VAL_WITH_DELEGATE,
    &CONST_VAL_WITH_GETTER,
    &CONST_VAL_WITH_NON_CONST_INITIALIZER,
    &CONTEXTUAL_OVERLOAD_SHADOWED,
    &CONTEXT_CLASS_OR_CONSTRUCTOR,
    &CONTEXT_PARAMETERS_WITH_BACKING_FIELD,
    &CONTEXT_PARAMETER_MUST_BE_NOINLINE,
    &CONTEXT_PARAMETER_WITHOUT_NAME,
    &CONTEXT_PARAMETER_WITH_DEFAULT,
    &CONTEXT_RECEIVERS_DEPRECATED,
    &CONTEXT_SENSITIVE_RESOLUTION_AMBIGUITY,
    &CONTRACT_NOT_ALLOWED,
    &CREATING_AN_INSTANCE_OF_ABSTRACT_CLASS,
    &CYCLIC_CONSTRUCTOR_DELEGATION_CALL,
    &CYCLIC_GENERIC_UPPER_BOUND,
    &CYCLIC_INHERITANCE_HIERARCHY,
    &DATA_CLASS_CONSISTENT_COPY_AND_EXPOSED_COPY_ARE_INCOMPATIBLE_ANNOTATIONS,
    &DATA_CLASS_CONSISTENT_COPY_WRONG_ANNOTATION_TARGET,
    &DATA_CLASS_NOT_PROPERTY_PARAMETER,
    &DATA_CLASS_OVERRIDE_CONFLICT,
    &DATA_CLASS_OVERRIDE_DEFAULT_VALUES,
    &DATA_CLASS_VARARG_PARAMETER,
    &DATA_CLASS_WITHOUT_PARAMETERS,
    &DATA_OBJECT_CUSTOM_EQUALS_OR_HASH_CODE,
    &DECLARATION_CANT_BE_INLINED,
    &DEFAULT_ARGUMENTS_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE,
    &DEFAULT_ARGUMENTS_IN_EXPECT_WITH_ACTUAL_TYPEALIAS,
    &DEFAULT_VALUE_NOT_ALLOWED_IN_OVERRIDE,
    &DEFINITELY_NON_NULLABLE_AS_REIFIED,
    &DELEGATED_MEMBER_HIDES_SUPERTYPE_OVERRIDE,
    &DELEGATED_PROPERTY_INSIDE_VALUE_CLASS,
    &DELEGATED_PROPERTY_IN_INTERFACE,
    &DELEGATE_SPECIAL_FUNCTION_AMBIGUITY,
    &DELEGATE_SPECIAL_FUNCTION_MISSING,
    &DELEGATE_SPECIAL_FUNCTION_NONE_APPLICABLE,
    &DELEGATE_SPECIAL_FUNCTION_RETURN_TYPE_MISMATCH,
    &DELEGATE_USES_EXTENSION_PROPERTY_TYPE_PARAMETER_ERROR,
    &DELEGATION_IN_INTERFACE,
    &DELEGATION_NOT_TO_INTERFACE,
    &DELEGATION_SUPER_CALL_IN_ENUM_CONSTRUCTOR,
    &DEPRECATED_ACCESS_TO_ENTRIES_AS_QUALIFIER,
    &DEPRECATED_ACCESS_TO_ENTRIES_PROPERTY,
    &DEPRECATED_ACCESS_TO_ENTRY_PROPERTY_FROM_ENUM,
    &DEPRECATED_ACCESS_TO_ENUM_ENTRY_COMPANION_PROPERTY,
    &DEPRECATED_ACCESS_TO_ENUM_ENTRY_PROPERTY_AS_REFERENCE,
    &DEPRECATED_IDENTITY_EQUALS,
    &DEPRECATED_MODIFIER,
    &DEPRECATED_MODIFIER_CONTAINING_DECLARATION,
    &DEPRECATED_MODIFIER_FOR_TARGET,
    &DEPRECATED_MODIFIER_PAIR,
    &DEPRECATED_SINCE_KOTLIN_OUTSIDE_KOTLIN_SUBPACKAGE,
    &DEPRECATED_SINCE_KOTLIN_WITHOUT_ARGUMENTS,
    &DEPRECATED_SINCE_KOTLIN_WITHOUT_DEPRECATED,
    &DEPRECATED_SINCE_KOTLIN_WITH_DEPRECATED_LEVEL,
    &DEPRECATED_SINCE_KOTLIN_WITH_UNORDERED_VERSIONS,
    &DEPRECATED_SMARTCAST_ON_DELEGATED_PROPERTY,
    &DEPRECATED_TYPE_PARAMETER_SYNTAX,
    &DEPRECATION,
    &DEPRECATION_ERROR,
    &DESERIALIZATION_ERROR,
    &DESTRUCTURING_SHORT_FORM_NAME_MISMATCH,
    &DESTRUCTURING_SHORT_FORM_OF_NON_DATA_CLASS,
    &DESTRUCTURING_SHORT_FORM_UNDERSCORE,
    &DIFFERENT_NAMES_FOR_THE_SAME_PARAMETER_IN_SUPERTYPES,
    &DIVISION_BY_ZERO,
    &DSL_MARKER_APPLIED_TO_WRONG_TARGET,
    &DSL_MARKER_PROPAGATES_TO_MANY,
    &DSL_SCOPE_VIOLATION,
    &DUPLICATE_BRANCH_CONDITION_IN_WHEN,
    &DUPLICATE_PARAMETER_NAME_IN_FUNCTION_TYPE,
    &DYNAMIC_NOT_ALLOWED,
    &DYNAMIC_RECEIVER_EXPECTED_BUT_WAS_NON_DYNAMIC,
    &DYNAMIC_RECEIVER_NOT_ALLOWED,
    &DYNAMIC_SUPERTYPE,
    &DYNAMIC_UPPER_BOUND,
    &ELSE_MISPLACED_IN_WHEN,
    &EMPTY_CHARACTER_LITERAL,
    &EMPTY_RANGE,
    &ENUM_CLASS_CONSTRUCTOR_CALL,
    &ENUM_ENTRY_AS_TYPE,
    &EQUALITY_NOT_APPLICABLE,
    &EQUALITY_NOT_APPLICABLE_WARNING,
    &ERROR_FROM_JAVA_RESOLUTION,
    &ERROR_IN_CONTRACT_DESCRIPTION,
    &ERROR_SUPPRESSION,
    &EXPANSIVE_INHERITANCE,
    &EXPANSIVE_INHERITANCE_IN_JAVA,
    &EXPECTED_CLASS_CONSTRUCTOR_DELEGATION_CALL,
    &EXPECTED_CLASS_CONSTRUCTOR_PROPERTY_PARAMETER,
    &EXPECTED_CONDITION,
    &EXPECTED_DECLARATION_WITH_BODY,
    &EXPECTED_DELEGATED_PROPERTY,
    &EXPECTED_ENUM_CONSTRUCTOR,
    &EXPECTED_ENUM_ENTRY_WITH_BODY,
    &EXPECTED_EXTERNAL_DECLARATION,
    &EXPECTED_FUNCTION_SOURCE_WITH_DEFAULT_ARGUMENTS_NOT_FOUND,
    &EXPECTED_LATEINIT_PROPERTY,
    &EXPECTED_PRIVATE_DECLARATION,
    &EXPECTED_PROPERTY_INITIALIZER,
    &EXPECTED_TAILREC_FUNCTION,
    &EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING,
    &EXPECT_ACTUAL_INCOMPATIBLE_CLASS_KIND,
    &EXPECT_ACTUAL_INCOMPATIBLE_CLASS_MODIFIERS,
    &EXPECT_ACTUAL_INCOMPATIBLE_CLASS_SCOPE,
    &EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_COUNT,
    &EXPECT_ACTUAL_INCOMPATIBLE_CLASS_TYPE_PARAMETER_UPPER_BOUNDS,
    &EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES,
    &EXPECT_ACTUAL_INCOMPATIBLE_ENUM_ENTRIES,
    &EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT,
    &EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET,
    &EXPECT_ACTUAL_INCOMPATIBLE_FUN_INTERFACE_MODIFIER,
    &EXPECT_ACTUAL_INCOMPATIBLE_ILLEGAL_REQUIRES_OPT_IN,
    &EXPECT_ACTUAL_INCOMPATIBLE_MODALITY,
    &EXPECT_ACTUAL_INCOMPATIBLE_NESTED_TYPE_ALIAS,
    &EXPECT_ACTUAL_INCOMPATIBLE_PARAMETERS_WITH_DEFAULT_VALUES_IN_EXPECT_ACTUALIZED_BY_FAKE_OVERRIDE,
    &EXPECT_ACTUAL_INCOMPATIBLE_PARAMETER_NAMES,
    &EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_CONST_MODIFIER,
    &EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_KIND,
    &EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_LATEINIT_MODIFIER,
    &EXPECT_ACTUAL_INCOMPATIBLE_PROPERTY_SETTER_VISIBILITY,
    &EXPECT_ACTUAL_INCOMPATIBLE_RETURN_TYPE,
    &EXPECT_ACTUAL_INCOMPATIBLE_SUPERTYPES,
    &EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_NAMES,
    &EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_REIFIED,
    &EXPECT_ACTUAL_INCOMPATIBLE_TYPE_PARAMETER_VARIANCE,
    &EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_CROSSINLINE,
    &EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_NOINLINE,
    &EXPECT_ACTUAL_INCOMPATIBLE_VALUE_PARAMETER_VARARG,
    &EXPECT_ACTUAL_INCOMPATIBLE_VISIBILITY,
    &EXPECT_ACTUAL_OPT_IN_ANNOTATION,
    &EXPECT_AND_ACTUAL_IN_THE_SAME_MODULE,
    &EXPECT_CLASS_AS_FUNCTION,
    &EXPECT_PROPERTY_WITH_EXPLICIT_BACKING_FIELD,
    &EXPECT_REFINEMENT_ANNOTATION_MISSING,
    &EXPECT_REFINEMENT_ANNOTATION_WRONG_TARGET,
    &EXPLICIT_BACKING_FIELD_IN_ABSTRACT_PROPERTY,
    &EXPLICIT_BACKING_FIELD_IN_EXTENSION,
    &EXPLICIT_BACKING_FIELD_IN_INTERFACE,
    &EXPLICIT_DELEGATION_CALL_REQUIRED,
    &EXPLICIT_FIELD_MUST_BE_INITIALIZED,
    &EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE,
    &EXPLICIT_TYPE_ARGUMENTS_IN_PROPERTY_ACCESS,
    &EXPOSED_FUNCTION_RETURN_TYPE,
    &EXPOSED_PACKAGE_PRIVATE_TYPE_FROM_INTERNAL_WARNING,
    &EXPOSED_PARAMETER_TYPE,
    &EXPOSED_PROPERTY_TYPE,
    &EXPOSED_PROPERTY_TYPE_IN_CONSTRUCTOR_ERROR,
    &EXPOSED_RECEIVER_TYPE,
    &EXPOSED_SUPER_CLASS,
    &EXPOSED_SUPER_INTERFACE,
    &EXPOSED_TYPEALIAS_EXPANDED_TYPE,
    &EXPOSED_TYPE_PARAMETER_BOUND,
    &EXPOSED_TYPE_PARAMETER_BOUND_DEPRECATION_WARNING,
    &EXPRESSION_EXPECTED,
    &EXPRESSION_EXPECTED_PACKAGE_FOUND,
    &EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS,
    &EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS_WARNING,
    &EXTENSION_FUNCTION_SHADOWED_BY_MEMBER_PROPERTY_WITH_INVOKE,
    &EXTENSION_IN_CLASS_REFERENCE_NOT_ALLOWED,
    &EXTENSION_PROPERTY_MUST_HAVE_ACCESSORS_OR_BE_ABSTRACT,
    &EXTENSION_PROPERTY_WITH_BACKING_FIELD,
    &EXTENSION_SHADOWED_BY_MEMBER,
    &FIELD_INITIALIZER_TYPE_MISMATCH,
    &FINAL_SUPERTYPE,
    &FINAL_UPPER_BOUND,
    &FINITE_BOUNDS_VIOLATION,
    &FINITE_BOUNDS_VIOLATION_IN_JAVA,
    &FLOAT_LITERAL_OUT_OF_RANGE,
    &FORBIDDEN_IDENTITY_EQUALS,
    &FORBIDDEN_IDENTITY_EQUALS_WARNING,
    &FORBIDDEN_VARARG_PARAMETER_TYPE,
    &FUNCTION_CALL_EXPECTED,
    &FUNCTION_DECLARATION_WITH_NO_NAME,
    &FUNCTION_EXPECTED,
    &FUNCTION_TYPE_OF_TOO_LARGE_ARITY,
    &FUN_INTERFACE_ABSTRACT_METHOD_WITH_DEFAULT_VALUE,
    &FUN_INTERFACE_ABSTRACT_METHOD_WITH_TYPE_PARAMETERS,
    &FUN_INTERFACE_CANNOT_HAVE_ABSTRACT_PROPERTIES,
    &FUN_INTERFACE_WITH_SUSPEND_FUNCTION,
    &FUN_INTERFACE_WRONG_COUNT_OF_ABSTRACT_MEMBERS,
    &GENERIC_THROWABLE_SUBCLASS,
    &GETTER_VISIBILITY_DIFFERS_FROM_PROPERTY_VISIBILITY,
    &HAS_NEXT_FUNCTION_AMBIGUITY,
    &HAS_NEXT_FUNCTION_NONE_APPLICABLE,
    &HAS_NEXT_FUNCTION_TYPE_MISMATCH,
    &HAS_NEXT_MISSING,
    &IGNORABILITY_ANNOTATIONS_WITH_CHECKER_DISABLED,
    &ILLEGAL_CONST_EXPRESSION,
    &ILLEGAL_DECLARATION_IN_WHEN_SUBJECT,
    &ILLEGAL_ESCAPE,
    &ILLEGAL_INLINE_PARAMETER_MODIFIER,
    &ILLEGAL_KOTLIN_VERSION_STRING_VALUE,
    &ILLEGAL_PROJECTION_USAGE,
    &ILLEGAL_RESTRICTED_SUSPENDING_FUNCTION_CALL,
    &ILLEGAL_SELECTOR,
    &ILLEGAL_SUSPEND_FUNCTION_CALL,
    &ILLEGAL_SUSPEND_PROPERTY_ACCESS,
    &ILLEGAL_TYPE_ARGUMENT_FOR_VARARG_PARAMETER_WARNING,
    &ILLEGAL_UNDERSCORE,
    &IMPLEMENTATION_BY_DELEGATION_IN_EXPECT_CLASS,
    &IMPLICIT_BOXING_IN_IDENTITY_EQUALS,
    &IMPLICIT_NOTHING_PROPERTY_TYPE,
    &IMPLICIT_NOTHING_RETURN_TYPE,
    &IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT,
    &IMPLICIT_PROPERTY_TYPE_MAKES_BEHAVIOR_ORDER_DEPENDANT_ERROR,
    &INACCESSIBLE_OUTER_CLASS_RECEIVER,
    &INAPPLICABLE_ALL_TARGET,
    &INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION,
    &INAPPLICABLE_CANDIDATE,
    &INAPPLICABLE_FILE_TARGET,
    &INAPPLICABLE_INFIX_MODIFIER,
    &INAPPLICABLE_LATEINIT_MODIFIER,
    &INAPPLICABLE_OPERATOR_MODIFIER,
    &INAPPLICABLE_OPERATOR_MODIFIER_WARNING,
    &INAPPLICABLE_PARAM_TARGET,
    &INAPPLICABLE_TARGET_ON_PROPERTY,
    &INAPPLICABLE_TARGET_ON_PROPERTY_WARNING,
    &INAPPLICABLE_TARGET_PROPERTY_HAS_NO_BACKING_FIELD,
    &INAPPLICABLE_TARGET_PROPERTY_HAS_NO_DELEGATE,
    &INAPPLICABLE_TARGET_PROPERTY_IMMUTABLE,
    &INCOMPATIBLE_CLASS,
    &INCOMPATIBLE_ENUM_COMPARISON,
    &INCOMPATIBLE_ENUM_COMPARISON_ERROR,
    &INCOMPATIBLE_MODIFIERS,
    &INCOMPATIBLE_TYPES,
    &INCOMPATIBLE_TYPES_WARNING,
    &INCONSISTENT_BACKING_FIELD_TYPE,
    &INCONSISTENT_PARAMETER_TYPES_IN_OF_OVERLOADS,
    &INCONSISTENT_RETURN_TYPES_IN_OF_OVERLOADS,
    &INCONSISTENT_SUSPEND_IN_OF_OVERLOADS,
    &INCONSISTENT_TYPE_PARAMETERS_IN_OF_OVERLOADS,
    &INCONSISTENT_TYPE_PARAMETER_BOUNDS,
    &INCONSISTENT_TYPE_PARAMETER_VALUES,
    &INCONSISTENT_VISIBILITY_IN_OF_OVERLOADS,
    &INCORRECT_CHARACTER_LITERAL,
    &INCORRECT_LEFT_COMPONENT_OF_INTERSECTION,
    &INCORRECT_RIGHT_COMPONENT_OF_INTERSECTION,
    &INCORRECT_TYPE_PARAMETER_OF_PROPERTY,
    &INC_DEC_SHOULD_NOT_RETURN_UNIT,
    &INEFFICIENT_EQUALS_OVERRIDING_IN_VALUE_CLASS,
    &INFERENCE_ERROR,
    &INFERRED_TYPE_VARIABLE_INTO_POSSIBLE_EMPTY_INTERSECTION,
    &INFIX_MODIFIER_REQUIRED,
    &INITIALIZATION_BEFORE_DECLARATION,
    &INITIALIZATION_BEFORE_DECLARATION_WARNING,
    &INITIALIZER_REQUIRED_FOR_DESTRUCTURING_DECLARATION,
    &INITIALIZER_TYPE_MISMATCH,
    &INLINE_CLASS_CONSTRUCTOR_WRONG_PARAMETERS_SIZE,
    &INLINE_CLASS_DEPRECATED,
    &INLINE_PROPERTY_WITH_BACKING_FIELD,
    &INLINE_SUSPEND_FUNCTION_TYPE_UNSUPPORTED,
    &INNER_CLASS_CONSTRUCTOR_NO_RECEIVER,
    &INNER_CLASS_INSIDE_VALUE_CLASS,
    &INNER_CLASS_OF_GENERIC_THROWABLE_SUBCLASS,
    &INSTANCE_ACCESS_BEFORE_SUPER_CALL,
    &INTERFACE_AS_FUNCTION,
    &INTERFACE_WITH_SUPERCLASS,
    &INT_LITERAL_OUT_OF_RANGE,
    &INT_LITERAL_WITH_LEADING_ZEROS,
    &INVALID_CHARACTERS,
    &INVALID_DEFAULT_FUNCTIONAL_PARAMETER_FOR_INLINE,
    &INVALID_DEFAULT_VALUE_DEPENDENCY,
    &INVALID_IF_AS_EXPRESSION,
    &INVALID_NON_OPTIONAL_PARAMETER_POSITION,
    &INVALID_TYPE_OF_ANNOTATION_MEMBER,
    &INVALID_VERSIONING_ON_ANNOTATION_CLASS,
    &INVALID_VERSIONING_ON_LOCAL_FUNCTION,
    &INVALID_VERSIONING_ON_NONFINAL_CLASS,
    &INVALID_VERSIONING_ON_NONFINAL_FUNCTION,
    &INVALID_VERSIONING_ON_NON_OPTIONAL,
    &INVALID_VERSIONING_ON_RECEIVER_OR_CONTEXT_PARAMETER_POSITION,
    &INVALID_VERSIONING_ON_VALUE_CLASS_PARAMETER,
    &INVALID_VERSIONING_ON_VARARG,
    &INVISIBLE_ABSTRACT_MEMBER_FROM_SUPER_ERROR,
    &INVISIBLE_REFERENCE,
    &INVISIBLE_REFERENCE_WARNING,
    &INVISIBLE_SETTER,
    &IR_WITH_UNSTABLE_ABI_COMPILED_CLASS,
    &IS_ENUM_ENTRY,
    &ITERATOR_AMBIGUITY,
    &ITERATOR_MISSING,
    &ITERATOR_ON_NULLABLE,
    &KCLASS_WITH_NULLABLE_TYPE_PARAMETER_IN_SIGNATURE,
    &KOTLIN_ACTUAL_ANNOTATION_HAS_NO_EFFECT_IN_KOTLIN,
    &K_SUSPEND_FUNCTION_TYPE_OF_DANGEROUSLY_LARGE_ARITY,
    &LABEL_NAME_CLASH,
    &LATEINIT_FIELD_IN_VAL_PROPERTY,
    &LATEINIT_INTRINSIC_CALL_IN_INLINE_FUNCTION,
    &LATEINIT_INTRINSIC_CALL_ON_NON_ACCESSIBLE_PROPERTY,
    &LATEINIT_INTRINSIC_CALL_ON_NON_LATEINIT,
    &LATEINIT_INTRINSIC_CALL_ON_NON_LITERAL,
    &LATEINIT_NULLABLE_BACKING_FIELD,
    &LATEINIT_PROPERTY_FIELD_DECLARATION_WITH_INITIALIZER,
    &LATEINIT_PROPERTY_WITHOUT_TYPE,
    &LEAKED_IN_PLACE_LAMBDA,
    &LOCAL_ANNOTATION_CLASS_ERROR,
    &LOCAL_EXTENSION_PROPERTY,
    &LOCAL_INTERFACE_NOT_ALLOWED,
    &LOCAL_OBJECT_NOT_ALLOWED,
    &LOCAL_VARIABLE_WITH_TYPE_PARAMETERS,
    &LOCAL_VARIABLE_WITH_TYPE_PARAMETERS_WARNING,
    &MANY_CLASSES_IN_SUPERTYPE_LIST,
    &MANY_COMPANION_OBJECTS,
    &MANY_IMPL_MEMBER_NOT_IMPLEMENTED,
    &MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED,
    &MANY_LAMBDA_EXPRESSION_ARGUMENTS,
    &MEMBER_PROJECTED_OUT,
    &METHOD_OF_ANY_IMPLEMENTED_IN_INTERFACE,
    &MISPLACED_TYPE_PARAMETER_CONSTRAINTS,
    &MISSING_BRANCH_FOR_NON_ABSTRACT_SEALED_CLASS,
    &MISSING_CONSTRUCTOR_KEYWORD,
    &MISSING_DEPENDENCY_CLASS,
    &MISSING_DEPENDENCY_CLASS_IN_EXPRESSION_TYPE,
    &MISSING_DEPENDENCY_CLASS_IN_LAMBDA_PARAMETER,
    &MISSING_DEPENDENCY_CLASS_IN_LAMBDA_RECEIVER,
    &MISSING_DEPENDENCY_CLASS_IN_TYPEALIAS,
    &MISSING_DEPENDENCY_SUPERCLASS,
    &MISSING_DEPENDENCY_SUPERCLASS_IN_TYPE_ARGUMENT,
    &MISSING_DEPENDENCY_SUPERCLASS_WARNING,
    &MISSING_STDLIB_CLASS,
    &MISSING_VAL_ON_ANNOTATION_PARAMETER,
    &MIXING_FUNCTIONAL_KINDS_IN_SUPERTYPES,
    &MIXING_NAMED_AND_POSITIONAL_ARGUMENTS,
    &MIXING_SUSPEND_AND_NON_SUSPEND_SUPERTYPES,
    &MODIFIER_FORM_FOR_NON_BUILT_IN_SUSPEND,
    &MULTIPLE_CONTEXT_LISTS,
    &MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES,
    &MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES_WHEN_NO_EXPLICIT_OVERRIDE,
    &MULTIPLE_LABELS_ARE_FORBIDDEN,
    &MULTIPLE_VARARG_OVERLOADS_OF_OPERATOR_OF,
    &MULTIPLE_VARARG_PARAMETERS,
    &MULTI_FIELD_VALUE_CLASS_PRIMARY_CONSTRUCTOR_DEFAULT_PARAMETER,
    &MUST_BE_INITIALIZED,
    &MUST_BE_INITIALIZED_OR_BE_ABSTRACT,
    &MUST_BE_INITIALIZED_OR_BE_ABSTRACT_WARNING,
    &MUST_BE_INITIALIZED_OR_BE_FINAL,
    &MUST_BE_INITIALIZED_OR_BE_FINAL_WARNING,
    &MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT,
    &MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT_WARNING,
    &MUST_BE_INITIALIZED_WARNING,
    &MUTABLE_PROPERTY_WITH_CAPTURED_TYPE,
    &NAMED_ARGUMENTS_NOT_ALLOWED,
    &NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE,
    &NAMED_PARAMETER_NOT_FOUND,
    &NAME_BASED_DESTRUCTURING_UNDERSCORE_WITHOUT_RENAMING,
    &NAME_FOR_AMBIGUOUS_PARAMETER,
    &NAME_IN_CONSTRAINT_IS_NOT_A_TYPE_PARAMETER,
    &NESTED_CLASS_ACCESSED_VIA_INSTANCE_REFERENCE,
    &NESTED_CLASS_NOT_ALLOWED,
    &NEWER_VERSION_IN_SINCE_KOTLIN,
    &NEW_INFERENCE_ERROR,
    &NEXT_AMBIGUITY,
    &NEXT_MISSING,
    &NEXT_NONE_APPLICABLE,
    &NONE_APPLICABLE,
    &NON_ABSTRACT_FUNCTION_WITH_NO_BODY,
    &NON_ASCENDING_VERSION_ANNOTATION,
    &NON_CONST_VAL_USED_IN_CONSTANT_EXPRESSION,
    &NON_FINAL_MEMBER_IN_FINAL_CLASS,
    &NON_FINAL_MEMBER_IN_OBJECT,
    &NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD,
    &NON_INLINE_MEMBER_VAL_INITIALIZATION,
    &NON_INTERNAL_PUBLISHED_API,
    &NON_LOCAL_RETURN_NOT_ALLOWED,
    &NON_LOCAL_SUSPENSION_POINT,
    &NON_MEMBER_FUNCTION_NO_BODY,
    &NON_MODIFIER_FORM_FOR_BUILT_IN_SUSPEND,
    &NON_PRIVATE_CONSTRUCTOR_IN_ENUM,
    &NON_PRIVATE_OR_PROTECTED_CONSTRUCTOR_IN_SEALED,
    &NON_PUBLIC_CALL_FROM_PUBLIC_INLINE,
    &NON_PUBLIC_CALL_FROM_PUBLIC_INLINE_DEPRECATION,
    &NON_PUBLIC_INLINE_CALL_FROM_PUBLIC_INLINE,
    &NON_SOURCE_ANNOTATION_ON_INLINED_LAMBDA_EXPRESSION,
    &NON_SUSPEND_OVERRIDDEN_BY_SUSPEND,
    &NON_TAIL_RECURSIVE_CALL,
    &NON_VARARG_SPREAD,
    &NOTHING_TO_INLINE,
    &NOTHING_TO_OVERRIDE,
    &NOT_AN_ANNOTATION_CLASS,
    &NOT_A_CLASS,
    &NOT_A_FUNCTION_LABEL,
    &NOT_A_LOOP_LABEL,
    &NOT_A_MULTIPLATFORM_COMPILATION,
    &NOT_A_SUPERTYPE,
    &NOT_FUNCTION_AS_OPERATOR,
    &NOT_NULL_ASSERTION_ON_CALLABLE_REFERENCE,
    &NOT_NULL_ASSERTION_ON_LAMBDA_EXPRESSION,
    &NOT_SUPPORTED_INLINE_PARAMETER_IN_INLINE_PARAMETER_DEFAULT_VALUE,
    &NOT_YET_SUPPORTED_IN_INLINE,
    &NOT_YET_SUPPORTED_IN_INLINE_WARNING,
    &NO_ACTUAL_CLASS_MEMBER_FOR_EXPECTED_CLASS,
    &NO_COMPANION_OBJECT,
    &NO_CONSTRUCTOR,
    &NO_CONTEXT_ARGUMENT,
    &NO_ELSE_IN_WHEN,
    &NO_EXPLICIT_RETURN_TYPE_IN_API_MODE,
    &NO_EXPLICIT_RETURN_TYPE_IN_API_MODE_WARNING,
    &NO_EXPLICIT_VISIBILITY_IN_API_MODE,
    &NO_EXPLICIT_VISIBILITY_IN_API_MODE_WARNING,
    &NO_GET_METHOD,
    &NO_IMPLICIT_DEFAULT_CONSTRUCTOR_ON_EXPECT_CLASS,
    &NO_RECEIVER_ALLOWED,
    &NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY,
    &NO_SET_METHOD,
    &NO_TAIL_CALLS_FOUND,
    &NO_THIS,
    &NO_TYPE_ARGUMENTS_ON_RHS,
    &NO_VALUE_FOR_PARAMETER,
    &NO_VARARG_OVERLOAD_OF_OPERATOR_OF,
    &NULLABLE_INLINE_PARAMETER,
    &NULLABLE_ON_DEFINITELY_NOT_NULLABLE,
    &NULLABLE_RETURN_TYPE_OF_OPERATOR_OF,
    &NULLABLE_SUPERTYPE,
    &NULLABLE_TYPE_IN_CLASS_LITERAL_LHS,
    &NULLABLE_TYPE_OF_ANNOTATION_MEMBER,
    &NULL_FOR_NONNULL_TYPE,
    &ONLY_ONE_CLASS_BOUND_ALLOWED,
    &OPERATOR_CALL_ON_CONSTRUCTOR,
    &OPERATOR_MODIFIER_REQUIRED,
    &OPERATOR_RENAMED_ON_IMPORT,
    &OPTIONAL_DECLARATION_OUTSIDE_OF_ANNOTATION_ENTRY,
    &OPTIONAL_DECLARATION_USAGE_IN_NON_COMMON_SOURCE,
    &OPTIONAL_EXPECTATION_NOT_ON_EXPECTED,
    &OPT_IN_ARGUMENT_IS_NOT_MARKER,
    &OPT_IN_CAN_ONLY_BE_USED_AS_ANNOTATION,
    &OPT_IN_MARKER_CAN_ONLY_BE_USED_AS_ANNOTATION_OR_ARGUMENT_IN_OPT_IN,
    &OPT_IN_MARKER_ON_OVERRIDE,
    &OPT_IN_MARKER_ON_OVERRIDE_WARNING,
    &OPT_IN_MARKER_ON_WRONG_TARGET,
    &OPT_IN_MARKER_WITH_WRONG_RETENTION,
    &OPT_IN_MARKER_WITH_WRONG_TARGET,
    &OPT_IN_OVERRIDE,
    &OPT_IN_OVERRIDE_ERROR,
    &OPT_IN_TO_INHERITANCE,
    &OPT_IN_TO_INHERITANCE_ERROR,
    &OPT_IN_USAGE,
    &OPT_IN_USAGE_ERROR,
    &OPT_IN_WITHOUT_ARGUMENTS,
    &OTHER_ERROR,
    &OTHER_ERROR_WITH_REASON,
    &OUTER_CLASS_ARGUMENTS_REQUIRED,
    &OVERLOAD_RESOLUTION_AMBIGUITY,
    &OVERRIDE_BY_INLINE,
    &OVERRIDE_DEPRECATION,
    &OVERRIDING_FINAL_MEMBER,
    &OVERRIDING_FINAL_MEMBER_BY_DELEGATION,
    &OVERRIDING_IGNORABLE_WITH_MUST_USE,
    &PACKAGE_CANNOT_BE_IMPORTED,
    &PACKAGE_CONFLICTS_WITH_CLASSIFIER,
    &PARAMETER_NAME_CHANGED_ON_OVERRIDE,
    &PLACEHOLDER_PROJECTION_IN_QUALIFIER,
    &PLATFORM_CLASS_MAPPED_TO_KOTLIN,
    &PLUGIN_AMBIGUOUS_INTERCEPTED_SYMBOL,
    &POTENTIALLY_NON_REPORTED_ANNOTATION,
    &POTENTIALLY_NULLABLE_RETURN_TYPE_OF_OPERATOR_OF,
    &PRE_RELEASE_CLASS,
    &PRIMARY_CONSTRUCTOR_DELEGATION_CALL_EXPECTED,
    &PRIVATE_CLASS_MEMBER_FROM_INLINE,
    &PRIVATE_FUNCTION_WITH_NO_BODY,
    &PRIVATE_PROPERTY_IN_INTERFACE,
    &PRIVATE_SETTER_FOR_ABSTRACT_PROPERTY,
    &PRIVATE_SETTER_FOR_OPEN_PROPERTY,
    &PROJECTION_IN_IMMEDIATE_ARGUMENT_TO_SUPERTYPE,
    &PROJECTION_ON_NON_CLASS_TYPE_ARGUMENT,
    &PROPERTY_FIELD_DECLARATION_MISSING_INITIALIZER,
    &PROPERTY_INITIALIZER_IN_INTERFACE,
    &PROPERTY_INITIALIZER_NO_BACKING_FIELD,
    &PROPERTY_INITIALIZER_WITH_EXPLICIT_FIELD_DECLARATION,
    &PROPERTY_TYPE_MISMATCH_BY_DELEGATION,
    &PROPERTY_TYPE_MISMATCH_ON_INHERITANCE,
    &PROPERTY_TYPE_MISMATCH_ON_OVERRIDE,
    &PROPERTY_WITH_BACKING_FIELD_INSIDE_VALUE_CLASS,
    &PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS,
    &PROPERTY_WITH_NO_TYPE_NO_INITIALIZER,
    &PROTECTED_CALL_FROM_PUBLIC_INLINE_ERROR,
    &PROTECTED_CONSTRUCTOR_CALL_FROM_PUBLIC_INLINE,
    &PROTECTED_CONSTRUCTOR_NOT_IN_SUPER_CALL,
    &RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER,
    &RECURSION_IN_IMPLICIT_TYPES,
    &RECURSION_IN_INLINE,
    &RECURSIVE_TYPEALIAS_EXPANSION,
    &REDECLARATION,
    &REDUNDANT_ANNOTATION,
    &REDUNDANT_ANNOTATION_TARGET,
    &REDUNDANT_CALL_OF_CONVERSION_METHOD,
    &REDUNDANT_ELSE_IN_WHEN,
    &REDUNDANT_EXPLICIT_BACKING_FIELD,
    &REDUNDANT_INTERPOLATION_PREFIX,
    &REDUNDANT_LABEL_WARNING,
    &REDUNDANT_MODALITY_MODIFIER,
    &REDUNDANT_MODIFIER,
    &REDUNDANT_MODIFIER_FOR_TARGET,
    &REDUNDANT_NULLABLE,
    &REDUNDANT_OPEN_IN_INTERFACE,
    &REDUNDANT_PROJECTION,
    &REDUNDANT_RETURN,
    &REDUNDANT_RETURN_UNIT_TYPE,
    &REDUNDANT_SETTER_PARAMETER_TYPE,
    &REDUNDANT_SINGLE_EXPRESSION_STRING_TEMPLATE,
    &REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_ANNOTATION,
    &REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_FUNCTION,
    &REDUNDANT_VISIBILITY_MODIFIER,
    &REIFIED_TYPE_FORBIDDEN_SUBSTITUTION,
    &REIFIED_TYPE_PARAMETER_IN_OVERRIDE,
    &REIFIED_TYPE_PARAMETER_NO_INLINE,
    &REPEATED_ANNOTATION,
    &REPEATED_ANNOTATION_WARNING,
    &REPEATED_BOUND,
    &REPEATED_MODIFIER,
    &RESERVED_MEMBER_FROM_INTERFACE_INSIDE_VALUE_CLASS,
    &RESERVED_MEMBER_INSIDE_VALUE_CLASS,
    &RESOLUTION_TO_CLASSIFIER,
    &RESOLVED_TO_UNDERSCORE_NAMED_CATCH_PARAMETER,
    &RESTRICTED_RETENTION_FOR_EXPRESSION_ANNOTATION_ERROR,
    &RESULT_TYPE_MISMATCH,
    &RETURN_FOR_BUILT_IN_SUSPEND,
    &RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY,
    &RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_AND_IMPLICIT_TYPE,
    &RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_WARNING,
    &RETURN_NOT_ALLOWED,
    &RETURN_TYPE_MISMATCH,
    &RETURN_TYPE_MISMATCH_BY_DELEGATION,
    &RETURN_TYPE_MISMATCH_OF_OPERATOR_OF,
    &RETURN_TYPE_MISMATCH_ON_INHERITANCE,
    &RETURN_TYPE_MISMATCH_ON_OVERRIDE,
    &RETURN_VALUE_NOT_USED,
    &RETURN_VALUE_NOT_USED_COERCION,
    &ROOT_IDE_PACKAGE_DEPRECATED,
    &SAFE_CALLABLE_REFERENCE_CALL,
    &SEALED_CLASS_CONSTRUCTOR_CALL,
    &SEALED_INHERITOR_IN_DIFFERENT_MODULE,
    &SEALED_INHERITOR_IN_DIFFERENT_PACKAGE,
    &SEALED_SUPERTYPE,
    &SEALED_SUPERTYPE_IN_LOCAL_CLASS,
    &SECONDARY_CONSTRUCTOR_WITH_BODY_INSIDE_VALUE_CLASS,
    &SELF_CALL_IN_NESTED_OBJECT_CONSTRUCTOR_ERROR,
    &SENSELESS_COMPARISON,
    &SENSELESS_NULL_IN_WHEN,
    &SETTER_PROJECTED_OUT,
    &SETTER_VISIBILITY_INCONSISTENT_WITH_PROPERTY_VISIBILITY,
    &SINGLETON_IN_SUPERTYPE,
    &SMARTCAST_IMPOSSIBLE,
    &SMARTCAST_IMPOSSIBLE_ON_IMPLICIT_INVOKE_RECEIVER,
    &SPREAD_OF_NULLABLE,
    &SUBCLASS_OPT_IN_ARGUMENT_IS_NOT_MARKER,
    &SUBCLASS_OPT_IN_INAPPLICABLE,
    &SUBTYPING_BETWEEN_CONTEXT_RECEIVERS,
    &SUPERCLASS_NOT_ACCESSIBLE_FROM_INTERFACE,
    &SUPERTYPES_FOR_ANNOTATION_CLASS,
    &SUPERTYPE_APPEARS_TWICE,
    &SUPERTYPE_INITIALIZED_IN_EXPECTED_CLASS,
    &SUPERTYPE_INITIALIZED_IN_INTERFACE,
    &SUPERTYPE_INITIALIZED_WITHOUT_PRIMARY_CONSTRUCTOR,
    &SUPERTYPE_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE,
    &SUPERTYPE_NOT_A_CLASS_OR_INTERFACE,
    &SUPERTYPE_NOT_INITIALIZED,
    &SUPER_CALL_FROM_PUBLIC_INLINE,
    &SUPER_CALL_WITH_DEFAULT_PARAMETERS,
    &SUPER_IS_NOT_AN_EXPRESSION,
    &SUPER_NOT_AVAILABLE,
    &SUSPEND_OVERRIDDEN_BY_NON_SUSPEND,
    &TAILREC_ON_VIRTUAL_MEMBER_ERROR,
    &TAIL_RECURSION_IN_TRY_IS_NOT_SUPPORTED,
    &THROWABLE_TYPE_MISMATCH,
    &TOO_MANY_ARGUMENTS,
    &TOO_MANY_CHARACTERS_IN_CHARACTER_LITERAL,
    &TRIM_MARGIN_BLANK_PREFIX,
    &TYPEALIAS_EXPANDS_TO_ARRAY_OF_NOTHINGS,
    &TYPEALIAS_EXPANSION_CAPTURES_OUTER_TYPE_PARAMETERS,
    &TYPEALIAS_EXPANSION_DEPRECATION,
    &TYPEALIAS_EXPANSION_DEPRECATION_ERROR,
    &TYPEALIAS_SHOULD_EXPAND_TO_CLASS,
    &TYPECHECKER_HAS_RUN_INTO_RECURSIVE_PROBLEM,
    &TYPE_ARGUMENTS_FOR_OUTER_CLASS_WHEN_NESTED_REFERENCED,
    &TYPE_ARGUMENTS_NOT_ALLOWED,
    &TYPE_ARGUMENTS_REDUNDANT_IN_SUPER_QUALIFIER,
    &TYPE_ARGUMENT_ON_TYPED_VALUE_CLASS_EQUALS,
    &TYPE_CANT_BE_USED_FOR_CONST_VAL,
    &TYPE_INFERENCE_ONLY_INPUT_TYPES_ERROR,
    &TYPE_MISMATCH,
    &TYPE_PARAMETERS_IN_ANONYMOUS_OBJECT,
    &TYPE_PARAMETERS_IN_ENUM,
    &TYPE_PARAMETERS_IN_OBJECT,
    &TYPE_PARAMETERS_NOT_ALLOWED,
    &TYPE_PARAMETER_AS_REIFIED,
    &TYPE_PARAMETER_AS_REIFIED_ARRAY_ERROR,
    &TYPE_PARAMETER_IN_CATCH_CLAUSE,
    &TYPE_PARAMETER_IS_NOT_AN_EXPRESSION,
    &TYPE_PARAMETER_ON_LHS_OF_DOT,
    &TYPE_VARIANCE_CONFLICT_ERROR,
    &TYPE_VARIANCE_CONFLICT_IN_EXPANDED_TYPE,
    &UNCHECKED_CAST,
    &UNDERSCORE_IS_RESERVED,
    &UNDERSCORE_USAGE_WITHOUT_BACKTICKS,
    &UNEXPECTED_SAFE_CALL,
    &UNEXPECTED_TRAILING_LAMBDA_ON_A_NEW_LINE,
    &UNINITIALIZED_ENUM_COMPANION,
    &UNINITIALIZED_ENUM_ENTRY,
    &UNINITIALIZED_PARAMETER,
    &UNINITIALIZED_VARIABLE,
    &UNNAMED_DELEGATED_PROPERTY,
    &UNNAMED_VAR_PROPERTY,
    &UNNECESSARY_LATEINIT,
    &UNNECESSARY_NOT_NULL_ASSERTION,
    &UNNECESSARY_SAFE_CALL,
    &UNREACHABLE_CODE,
    &UNRESOLVED_IMPORT,
    &UNRESOLVED_LABEL,
    &UNRESOLVED_REFERENCE,
    &UNRESOLVED_REFERENCE_WRONG_RECEIVER,
    &UNSAFE_CALL,
    &UNSAFE_CALLABLE_REFERENCE,
    &UNSAFE_IMPLICIT_INVOKE_CALL,
    &UNSAFE_INFIX_CALL,
    &UNSAFE_OPERATOR_CALL,
    &UNSIGNED_LITERAL_WITHOUT_DECLARATIONS_ON_CLASSPATH,
    &UNSUPPORTED,
    &UNSUPPORTED_CLASS_LITERALS_WITH_EMPTY_LHS,
    &UNSUPPORTED_COLLECTION_LITERAL_TYPE,
    &UNSUPPORTED_CONTEXTUAL_DECLARATION_CALL,
    &UNSUPPORTED_FEATURE,
    &UNSUPPORTED_INHERITANCE_FROM_JAVA_MEMBER_REFERENCING_KOTLIN_FUNCTION,
    &UNSUPPORTED_SEALED_FUN_INTERFACE,
    &UNSUPPORTED_SUSPEND_TEST,
    &UNUSED_ANONYMOUS_PARAMETER,
    &UNUSED_EXPRESSION,
    &UNUSED_LAMBDA_EXPRESSION,
    &UNUSED_VARIABLE,
    &UPPER_BOUND_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE,
    &UPPER_BOUND_VIOLATED,
    &UPPER_BOUND_VIOLATED_DEPRECATION_WARNING,
    &UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION,
    &UPPER_BOUND_VIOLATED_IN_TYPEALIAS_EXPANSION_DEPRECATION_WARNING,
    &USAGE_IS_NOT_INLINABLE,
    &USELESS_CALL_ON_NOT_NULL,
    &USELESS_CAST,
    &USELESS_ELVIS,
    &USELESS_ELVIS_LEFT_IS_NULL,
    &USELESS_ELVIS_RIGHT_IS_NULL,
    &USELESS_IS_CHECK,
    &USELESS_VARARG_ON_PARAMETER,
    &VALUE_CLASS_CANNOT_BE_CLONEABLE,
    &VALUE_CLASS_CANNOT_BE_RECURSIVE,
    &VALUE_CLASS_CANNOT_EXTEND_CLASSES,
    &VALUE_CLASS_CANNOT_HAVE_CONTEXT_RECEIVERS,
    &VALUE_CLASS_CANNOT_IMPLEMENT_INTERFACE_BY_DELEGATION,
    &VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER,
    &VALUE_CLASS_EMPTY_CONSTRUCTOR,
    &VALUE_CLASS_HAS_INAPPLICABLE_PARAMETER_TYPE,
    &VALUE_CLASS_NOT_FINAL,
    &VALUE_CLASS_NOT_TOP_LEVEL,
    &VALUE_PARAMETER_WITHOUT_EXPLICIT_TYPE,
    &VAL_OR_VAR_ON_CATCH_PARAMETER,
    &VAL_OR_VAR_ON_FUN_PARAMETER,
    &VAL_OR_VAR_ON_LOOP_PARAMETER,
    &VAL_OR_VAR_ON_SECONDARY_CONSTRUCTOR_PARAMETER,
    &VAL_REASSIGNMENT,
    &VAL_REASSIGNMENT_VIA_BACKING_FIELD_ERROR,
    &VAL_WITH_SETTER,
    &VARARG_OUTSIDE_PARENTHESES,
    &VARIABLE_EXPECTED,
    &VARIABLE_INITIALIZER_IS_REDUNDANT,
    &VARIABLE_NEVER_READ,
    &VARIABLE_WITH_NO_TYPE_NO_INITIALIZER,
    &VARIANCE_ON_TYPE_PARAMETER_NOT_ALLOWED,
    &VAR_ANNOTATION_PARAMETER,
    &VAR_OVERRIDDEN_BY_VAL,
    &VAR_OVERRIDDEN_BY_VAL_BY_DELEGATION,
    &VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD,
    &VAR_TYPE_MISMATCH_ON_INHERITANCE,
    &VAR_TYPE_MISMATCH_ON_OVERRIDE,
    &VERSION_OVERLOADS_TOO_COMPLEX_EXPRESSION,
    &VERSION_REQUIREMENT_DEPRECATION,
    &VERSION_REQUIREMENT_DEPRECATION_ERROR,
    &VIRTUAL_MEMBER_HIDDEN,
    &VOLATILE_ON_DELEGATE,
    &VOLATILE_ON_VALUE,
    &WHEN_GUARD_WITHOUT_SUBJECT,
    &WRONG_ANNOTATION_TARGET,
    &WRONG_ANNOTATION_TARGET_WARNING,
    &WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET,
    &WRONG_CONDITION_SUGGEST_GUARD,
    &WRONG_EXTENSION_FUNCTION_TYPE,
    &WRONG_EXTENSION_FUNCTION_TYPE_WARNING,
    &WRONG_GETTER_RETURN_TYPE,
    &WRONG_INVOCATION_KIND,
    &WRONG_LONG_SUFFIX,
    &WRONG_MODIFIER_CONTAINING_DECLARATION,
    &WRONG_MODIFIER_TARGET,
    &WRONG_NUMBER_OF_TYPE_ARGUMENTS,
    &WRONG_SETTER_PARAMETER_TYPE,
    &WRONG_SETTER_RETURN_TYPE,
};
