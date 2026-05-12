val plain = "hello\n\tworld"
val short = "hi $name"
val full = "sum=${a + b}!"
val nested = "outer ${ if (b) "yes ${x}" else "no" }"
val raw = """line one
line two with $name and ${1 + 1}"""
val empty = ""
val dollar = "price: \$5"
