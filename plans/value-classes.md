# Value classes without allocation

A value of a value class is a heap object in klio: `Dp(4f)`, `Offset(x, y)`,
`Color(argb)`, `NodeKind(mask)` each allocate, register with the collector
and are swept, and reading the value inside is a field load. On the JVM a
value class is its underlying value wherever its static type is the class
itself, and is boxed only where it meets `Any`, an interface, a type
parameter or a nullable type. The JVM interpreter makes and reads one in 36
ns where klio takes 79 (`bench/interp/programs/mb_ops.kt`), and the Compose
scenes allocate tens of thousands per frame (the 300 changing texts: about
36,000, most of them `NodeKind`, `ObjectParameter`, `WriteScope`, `Dp`,
`IntOffset`, `Constraints`, `IntSize`, `ReaderKind`).

## Decision

**Scope.** A final value class with one property whose type is `Boolean`,
`Char`, `Byte`, `Short`, `Int`, `Long`, `Float`, `Double` or an unsigned
type, declared outside `kotlin.*` (the unsigned types are host numbers
already; `Duration` and the other stdlib ones follow once the natives that
read them are audited), and implementing no interface `by` a delegate (the
instance keeps the delegate beside the number: `value class D(val x: Int) :
Comparable<Int> by x`). Such a class is *scalar*.

**Representation.** A value's representation is decided by the static type
of the place that holds it. Where that type is exactly a scalar class `V`
(not nullable, not a type parameter), the value is the underlying number.
Anywhere else it is the boxed instance, as today.

**One invariant.** A bare number is never the value of an expression whose
static type (sema's `exprType`) is not its class. A value whose static type
is the class may be in either form, since both conversions are the value
itself when it is in the target form already. So a box is needed where a
value widens from the class to another type, and an unbox (for speed) where
it enters a place typed as the class:

- reads: a local, a parameter, `this`, a property or field, a call's result
  (the callee's declared return type, not the substituted one), a lambda
  parameter, a catch parameter, a `for` element, a destructured entry, a
  delegate's `getValue`;
- writes: a call argument (the callee's declared parameter type, not the
  substituted one; a vararg element is boxed), a receiver, an assignment
  or initializer of a local or property, a `return` and an expression body,
  a lambda's result (function types are generic: boxed), a branch of `if`,
  `when`, `try` or `?:` into the whole expression's type, a string
  template's part, a collection or array literal element;
- casts that change the static type without a call: a smart cast, `as`,
  `as?`, `!!`, `is`.

A conversion from `V` to anything else boxes; from anything else to `V`
unboxes. `lower/sema/coerce.zig` holds the one helper every site calls.

**Instructions.** `BoxValue { dst, src, class, slot }` makes the instance over the
number without running an init block (construction does that, not boxing);
`UnboxValue { dst, src, class, slot }` reads the number. Both are idempotent: an
instance boxes to itself and a number unboxes to itself, so a site that
cannot tell which it holds may apply either.

**Construction.** `V(x)` calls V's constructor body over the number, which
runs the init blocks and answers the number; nothing is allocated. A value
class extending another (`FullValueClasses`) is no scalar class: its
superclass initializes too.

**Signatures.** A parameter or result of a scalar class's type is the
number in every declaration of a function's override family when the
family's root declares that class there, as the JVM gives an override its
root's signature; a generic root (`Comparable<T>.compareTo(other: T)`) or
roots that disagree hold it boxed, and so does a function literal's, which
is called through its generic function type. So a `Color` passed to
`DrawScope.drawCircle`, an interface method, stays a number.

**Members.** V's members take `this` as the number and unbox it as they
start, so dispatch on a box reaches them too. A constructor that only
answers its value is not called: `V(x)` is `x`, after a load of the
class's companion when it has one, which initializes the companion the
first time.

**Synthesized members.** V's `equals` compares numbers (no identity
shortcut: a number is no object); a data class's `toString` renders a
scalar property boxed, by the class's own `toString`; its `equals` and
`hashCode` compare and hash the numbers, which answer as the class's do.

**Compose.** A composable's change check on a scalar class's parameter
compares the number, by `Composer.changed`'s overload for its primitive,
as the Compose compiler does.

## Status

Done: the instructions and their stream ops, the image format, the
coercion helper (`lower/sema/coerce.zig`), every site above, construction,
members, synthesized members, Compose's change checks.
`tests/fixtures/parity_corpus/value_class_flows.kt` and
`value_class_members.kt` send scalar classes through each site, pinned
with kotlinc's output; `value_class_boxed_edges.kt` the places that box
that the box corpus found missed: a call through the defaults bridge an
override inherits (`I.f$default` takes the instance, as the declaration it
belongs to does), a class's `by` delegate slot, a value class delegating
`by` its own value. A vararg parameter of a scalar class holds the array
of instances, so its read is never unboxed (the box corpus's
`fullValueClasses/vararg`).

Left: the stdlib's value classes (`Duration`, `Result` is no scalar class),
once the natives that read them are audited; a `toString` or `hashCode` of
a scalar class called straight on the number rather than boxing for the
dispatch; a string template's part the same; a value class over a
reference type (Compose's `WriteScope` over `Operations`, made 66,000
times in a recompose run), which needs a box that can tell an instance of
the class from the reference it wraps.

## Risk

A missed box lets a bare number reach `Any`, where `is V`, `toString`,
`equals` and hashing answer for the number. The fixture covers each site
kind; the Compose examples send `Dp`, `Offset` and `Constraints` through
generic and nullable places everywhere.
