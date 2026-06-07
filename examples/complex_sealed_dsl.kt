// Sealed interface hierarchy + generics + deeply nested lambdas +
// operator overloading + data-class destructuring + extension
// functions + a small expression-evaluator DSL.

sealed interface Expr {
    data class Lit(val value: Int) : Expr
    data class Var(val name: String) : Expr
    data class Bin(val op: Char, val lhs: Expr, val rhs: Expr) : Expr
    data class Let(val name: String, val bound: Expr, val body: Expr) : Expr
}

class Env private constructor(private val vars: Map<String, Int>) {
    operator fun get(name: String): Int =
        vars[name] ?: throw IllegalStateException("unbound: $name")

    operator fun plus(pair: Pair<String, Int>): Env =
        Env(vars + pair)

    companion object {
        val EMPTY = Env(emptyMap())
    }
}

fun Expr.eval(env: Env): Int = when (this) {
    is Expr.Lit -> value
    is Expr.Var -> env[name]
    is Expr.Let -> body.eval(env + (name to bound.eval(env)))
    is Expr.Bin -> {
        val a = lhs.eval(env)
        val b = rhs.eval(env)
        when (op) {
            '+' -> a + b
            '-' -> a - b
            '*' -> a * b
            '/' -> a / b
            else -> error("bad op $op")
        }
    }
}

// Tiny builder DSL with a receiver lambda nested inside another.
class ProgramBuilder {
    private val steps = mutableListOf<Pair<String, Expr>>()
    fun let(name: String, build: () -> Expr) {
        steps.add(name to build())
    }
    fun run(): List<Pair<String, Int>> {
        var env = Env.EMPTY
        val out = mutableListOf<Pair<String, Int>>()
        for ((n, e) in steps) {
            val v = e.eval(env)
            env += n to v
            out.add(n to v)
        }
        return out
    }
}

fun program(block: ProgramBuilder.() -> Unit): ProgramBuilder =
    ProgramBuilder().apply(block)

fun main() {
    val lit = Expr::Lit
    val p = program {
        let("x") { Expr.Bin('+', lit(20), lit(22)) }
        let("y") {
            Expr.Let("t", Expr.Var("x"),
                Expr.Bin('*', Expr.Var("t"), Expr.Lit(2)))
        }
        let("z") {
            // Deeply nested lambdas: a fold over a generated list,
            // each step itself building an Expr via a closure.
            val terms = (1..4).map { i -> { acc: Expr -> Expr.Bin('+', acc, Expr.Lit(i)) } }
            terms.fold(Expr.Var("y") as Expr) { acc, step -> step(acc) }
        }
    }
    for ((name, value) in p.run()) {
        println("$name = $value")
    }

    // Nested generic transform: List<Pair<Int, List<Int>>> ->
    // flattened, filtered, summed via chained higher-order calls.
    val data = listOf(1 to listOf(1, 2, 3), 2 to listOf(4, 5), 3 to listOf(6))
    val total = data
        .flatMap { (k, vs) -> vs.map { it * k } }
        .filter { it % 2 == 0 }
        .sum()
    println("total = $total")

    // Smart-cast chain through a sealed when, returning from a lambda.
    val exprs: List<Expr> = listOf(
        Expr.Lit(7),
        Expr.Bin('-', Expr.Lit(10), Expr.Lit(3)),
        Expr.Let("a", Expr.Lit(5), Expr.Bin('*', Expr.Var("a"), Expr.Var("a")))
    )
    val described = exprs.joinToString(separator = "; ") { e ->
        when (e) {
            is Expr.Lit -> "lit(${e.value})"
            is Expr.Var -> "var(${e.name})"
            is Expr.Bin -> "bin(${e.op})=${e.eval(Env.EMPTY)}"
            is Expr.Let -> "let(${e.name})=${e.eval(Env.EMPTY)}"
        }
    }
    println(described)
}
