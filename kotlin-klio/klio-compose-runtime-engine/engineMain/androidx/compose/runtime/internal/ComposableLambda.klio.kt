package androidx.compose.runtime.internal

import androidx.compose.runtime.ComposeCompilerApi
import androidx.compose.runtime.Composer
import androidx.compose.runtime.Stable

// A composable lambda is a function value of every arity the compiler
// invokes one with: a `@Composable (P1, ..., Pn) -> R` takes its
// parameters, the composer and the change bits, one Int for up to nine
// parameters and two from ten, the lambda itself taking the slot after them.
@ComposeCompilerApi
@Stable
public actual interface ComposableLambda :
    Function2<Composer, Int, Any?>,
    Function3<Any?, Composer, Int, Any?>,
    Function4<Any?, Any?, Composer, Int, Any?>,
    Function5<Any?, Any?, Any?, Composer, Int, Any?>,
    Function6<Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function7<Any?, Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function8<Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function9<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function10<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function11<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Any?>,
    Function13<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function14<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function15<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function16<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function17<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function18<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function19<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function20<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>,
    Function21<Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Any?, Composer, Int, Int, Any?>
