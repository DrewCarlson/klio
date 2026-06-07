// An explicit argument cast (`x as T`) selects the overload whose
// parameter type is `T`, even when a more-derived overload would match
// the argument's runtime type. The deprecation-delegation pattern — a
// narrow overload forwarding to the general one via `as` — must reach
// the general overload, not re-select itself and recurse. This mirrors
// kotlinx.coroutines' deprecated `async(context: Job, …) =
// async(context as CoroutineContext, …)`.

interface Ctx
class JobImpl : Ctx

fun f(c: Ctx): String = "ctx"
fun f(j: JobImpl): String = f(j as Ctx)

// Three-arg shape mirroring `async(context, start, block)`: the narrow
// `JobImpl` overload delegates to the `Ctx` overload through the cast.
fun g(c: Ctx, n: Int, tag: String): String = "g($n,$tag)"
fun g(j: JobImpl, n: Int, tag: String): String = g(j as Ctx, n, tag)

// Extension-receiver form: `Holder.h` is an extension (the shape the
// real `async` takes — a member-looking call on the receiver scope).
class Holder
fun Holder.h(c: Ctx): String = "ext-ctx"
fun Holder.h(j: JobImpl): String = h(j as Ctx)

fun main() {
    println(f(JobImpl()))
    println(g(JobImpl(), 7, "x"))
    println(Holder().h(JobImpl()))
}
