/* klio_rt — the C ABI of the klio Kotlin runtime: booting a program through
 * the interpreter (the launcher `klio transpile` writes), and the runtime a
 * program `klio transpile --native` compiled calls. Link against
 * libklio_rt.a (zig build klio-rt). */
#ifndef KLIO_RT_H
#define KLIO_RT_H

#include <stdint.h>
#include <stddef.h>

/* A call that never comes back. Spelled per toolchain so the generated C
 * compiles warning-clean wherever it is built. */
#if defined(_MSC_VER)
#define KLIO_NORETURN __declspec(noreturn)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define KLIO_NORETURN _Noreturn
#elif defined(__GNUC__) || defined(__clang__)
#define KLIO_NORETURN __attribute__((noreturn))
#else
#define KLIO_NORETURN
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Runs the Kotlin program at `path` exactly as `klio run <path>` would.
 * Returns the process exit code (0 success, nonzero on diagnostics or a
 * runtime error). */
int klio_rt_run_file(const char *path);

/* Runs the program made of the source files `paths`, with the pack features
 * `features` (each `<pack>/<feature>`) selected, as `klio run` would. */
int klio_rt_run_sources(const char *const *paths, uint32_t n_paths,
                        const char *const *features, uint32_t n_features);

/* Runs the programs `paths` over the sema image `image` (`image_len` bytes),
 * or, when `image` is null, the one in the file `image_path`, with
 * `main(args)`. `texts`, when not null, are the programs' sources, so the
 * files need not exist where the binary runs. Nothing is read from the data
 * home. `klio transpile` writes a `main` that calls this. */
int klio_rt_run_image(const uint8_t *image, size_t image_len, const char *image_path,
                      const char *const *paths, const char *const *texts, uint32_t n_paths,
                      const char *const *args, uint32_t n_args);

/* The library's ABI version (this header describes version 7). */
int klio_rt_abi_version(void);

/* ------------------------------------------------------------------ */
/* The native object ABI: what a COMPILED program calls.                */
/*                                                                      */
/* A compiled program IS the program. Its values are the runtime's own, */
/* so a compiled object traces, prints and flows into collections       */
/* exactly as an interpreted one does.                                  */

/* A Value as C sees it. Opaque: pass it back, never read inside. */
typedef struct { uint64_t lo, hi; } klio_value;

/* Install the collector's view of compiled frames. Call before main. */
void klio_nat_init(uint32_t reserved);

/* The collector is precisely rooted and never scans the native stack, so a
 * compiled frame publishes its OBJECT slots for the duration of the call.
 * Scalars stay in C locals: nothing on the heap depends on them. */
typedef struct klio_nat_frame {
  struct klio_nat_frame *prev;
  uint32_t n;
  klio_value *slots;
} klio_nat_frame;
void klio_nat_enter(klio_nat_frame *f);
void klio_nat_leave(klio_nat_frame *f);
/* A `longjmp` to a handler skips the `klio_nat_leave` of every frame between
 * the throw and the catch, so the landing pad restores the chain itself. */
klio_nat_frame *klio_nat_frame_mark(void);
void klio_nat_frame_restore(klio_nat_frame *mark);
/* Ends the program-lifetime allocation phase: call after registering classes
 * and before the program body, or nothing the body allocates is collectable. */
void klio_nat_begin(void);
/* The safe point: compiled code polls at function entry and loop back edges. */
void klio_nat_safepoint(void);

klio_value klio_nat_string(const char *bytes, size_t len);
klio_value klio_nat_null(void);
int32_t    klio_nat_is_null(klio_value v);

/* A `var` captured by a lambda: a shared box, so both sides see writes. */
klio_value klio_nat_cell(klio_value v);
klio_value klio_nat_cell_get(klio_value c);
void       klio_nat_cell_set(klio_value c, klio_value v);

/* Boxes carry their kind: a Char prints as a character, Short and Byte render
 * as themselves, and Kotlin's unsigned integers are value classes over the
 * signed widths, so their bits are the same and only the kind differs.
 * Unboxing a box of another kind is a fault in the compiler. */
klio_value klio_nat_box_int(int32_t v);
klio_value klio_nat_box_long(int64_t v);
klio_value klio_nat_box_double(double v);
klio_value klio_nat_box_float(float v);
klio_value klio_nat_box_bool(int32_t v);
klio_value klio_nat_box_unit(void);
klio_value klio_nat_box_char(uint16_t v);
klio_value klio_nat_box_short(int16_t v);
klio_value klio_nat_box_byte(int8_t v);
klio_value klio_nat_box_uint(uint32_t v);
klio_value klio_nat_box_ulong(uint64_t v);
klio_value klio_nat_box_ushort(uint16_t v);
klio_value klio_nat_box_ubyte(uint8_t v);
int32_t  klio_nat_int(klio_value v);
int64_t  klio_nat_long(klio_value v);
double   klio_nat_double(klio_value v);
float    klio_nat_float(klio_value v);
int32_t  klio_nat_bool(klio_value v);
uint16_t klio_nat_char(klio_value v);
int16_t  klio_nat_short(klio_value v);
int8_t   klio_nat_byte(klio_value v);
uint32_t klio_nat_uint(klio_value v);
uint64_t klio_nat_ulong(klio_value v);
uint16_t klio_nat_ushort(klio_value v);
uint8_t  klio_nat_ubyte(klio_value v);

/* ------------------------------------------------------------------ */
/* Programs compiled from sema's lowering (`klio transpile --native`).  */
/*                                                                      */
/* The program describes itself by the ids the compiler allocated: its  */
/* classes, the natives it calls, the host value kinds' classes, and    */
/* the functions the host may call back (a class's `toString` when a    */
/* native prints an instance, an exception's constructor when a native  */
/* throws). The runtime builds its module from that and runs the        */
/* program inside it, so every host interaction runs the interpreter's  */
/* own code. Nothing is found by name at run time.                      */

/* The ordinals program and runtime share; checked before anything else. */
uint64_t klio_r_abi(void);

typedef struct klio_r_class {
  uint32_t id;
  const char *name;
  const char *fqn;
  uint32_t flags;
  uint32_t n_slots;
  const char *const *slot_names;
  const uint8_t *seeds;             /* each slot's zero before construction */
  uint32_t n_ancestors;
  const uint32_t *ancestors;        /* every supertype, transitively */
  uint32_t n_ancestor_names;
  const char *const *ancestor_names;
  uint32_t n_primary;               /* a data class's constructor properties */
  const char *const *primary;
  const uint8_t *primary_mutable;   /* 0 not a property, 1 val, 2 var */
  uint32_t host_slot;               /* 0xFFFFFFFF: the class holds no host value */
} klio_r_class;

/* A compiled function the host calls: 0 with its result in `*out`, 1 with a
 * throwable in `*out`. */
typedef int32_t (*klio_r_fn)(const klio_value *argv, uint32_t argc, klio_value *out);
/* A function the host may call: a compiled one, or (`function` null) a native. */
typedef struct klio_r_function { klio_r_fn function; uint32_t native; uint32_t arity; } klio_r_function;
/* Class `cls`'s implementation of `slot` is function `function`. */
typedef struct klio_r_dispatch { uint32_t cls; uint32_t slot; uint32_t function; } klio_r_dispatch;
typedef struct klio_r_native {
  const char *name;
  uint32_t table;        /* the binding's table: 0 natives, 1 constructors,
                            2 the members the VM implements, 3 none */
  const char *key;
  uint32_t flags;        /* 1 static, 2 takes a receiver */
  uint32_t reified;
  int32_t  vararg_back;  /* -1 when it takes no vararg */
  uint32_t op;
} klio_r_native;
/* An exception the host raises, and the function that constructs it. */
typedef struct klio_r_raised { const char *fqn; uint32_t cls; uint32_t function; } klio_r_raised;
typedef struct klio_r_program {
  const klio_r_class *classes; uint32_t n_classes;
  const klio_r_function *functions; uint32_t n_functions;
  const klio_r_dispatch *dispatch; uint32_t n_dispatch;
  const klio_r_native *natives; uint32_t n_natives;
  /* The slot of each base member a native calls back through, in the
   * runtime's order (0xFFFFFFFF: the base declares none). */
  const uint32_t *well_known; uint32_t n_well_known;
  /* One per exception the runtime raises itself (`klio_r_raise` order);
   * cls 0xFFFFFFFF where the program builds none. */
  const klio_r_raised *raised; uint32_t n_raised;
  /* The host exceptions, by name, the program builds. */
  const klio_r_raised *by_fqn; uint32_t n_by_fqn;
  /* The class of each host value kind (0xFFFFFFFF: none): `scalars` in the
   * order Unit, Boolean, Char, Byte, Short, Int, Long, Float, Double, UByte,
   * UShort, UInt, ULong, String, Array; then by value kind, by primitive
   * array kind, by range kind and by function arity; and the root slot of
   * `invoke` by arity. */
  const uint32_t *scalars;
  const uint32_t *by_tag; uint32_t n_tags;
  const uint32_t *prim_array; uint32_t n_prim;
  const uint32_t *range; const uint32_t *progression; uint32_t n_range;
  const uint32_t *function; uint32_t n_function;
  const uint32_t *invoke_slot; uint32_t n_invoke;
  /* The root slots of `equals`, `hashCode` and `toString` (0xFFFFFFFF: none). */
  uint32_t equals_slot, hash_code_slot, to_string_slot;
  /* The base's `KlioMatchGroups` and its constructor, which a regex match's
   * `groups` is (cls 0xFFFFFFFF where the program builds none). */
  klio_r_raised match_groups;
  /* Throws a throwable into the program; never returns. */
  void (*throw_value)(klio_value v);
} klio_r_program;

/* Describes the program; call after klio_nat_init, before klio_r_run. */
void klio_r_describe(const klio_r_program *program);
/* Runs `main` inside the runtime's VM, on a large stack. */
int klio_r_run(void (*main)(void));

klio_value klio_r_new(uint32_t cls);
uint32_t   klio_r_class_of(klio_value v);
int32_t    klio_r_is_a(klio_value v, uint32_t cls, int32_t nullable);
klio_value klio_r_cast(klio_value v, uint32_t cls, int32_t nullable, int32_t safe);
klio_value klio_r_get(klio_value obj, uint32_t slot);
void       klio_r_set(klio_value obj, uint32_t slot, klio_value v);
klio_value klio_r_box_value(klio_value v, uint32_t cls, uint32_t slot);
klio_value klio_r_unbox_value(klio_value v, uint32_t cls, uint32_t slot);
klio_value klio_r_kclass(uint32_t cls);
klio_value klio_r_class_value(klio_value v);

/* Native `n` as the program numbers them, over the argument run. */
klio_value klio_r_native_call(uint32_t n, const klio_value *argv, uint32_t argc);

klio_value klio_r_binop(uint32_t op, klio_value a, klio_value b);
klio_value klio_r_unop(uint32_t op, klio_value v);
klio_value klio_r_concat(klio_value a, klio_value b);
klio_value klio_r_to_string(klio_value v);
/* `u == v` through `u`'s `equals`, as a captured value compares. */
int32_t    klio_r_equals(klio_value u, klio_value v);
int32_t    klio_r_hash_code(klio_value v);
int32_t    klio_r_identity_hash(klio_value v);
/* A lambda's text: its class as the JVM names it, then its hash. */
klio_value klio_r_lambda_text(const char *stem, klio_value v);
klio_value klio_r_array_get(klio_value a, int32_t index);
void       klio_r_array_set(klio_value a, int32_t index, klio_value v);
klio_value klio_r_new_array(uint32_t cls, const klio_value *argv, uint32_t argc);
/* A `for` loop by position over a list, set, array or string: the stamp (null for any
 * other value), whether position `idx` has an element, and the element. */
klio_value klio_r_iter_open(klio_value src);
int32_t    klio_r_iter_has(klio_value src, int32_t idx, klio_value stamp);
klio_value klio_r_iter_get(klio_value src, int32_t idx, klio_value stamp);

/* Raises the exception of kind `which` with `message` (a String or null). */
KLIO_NORETURN void klio_r_raise(uint32_t which, klio_value message);
/* The initializer of the JVM class `name` threw `cause`, null on a later use. */
KLIO_NORETURN void klio_r_init_failed(klio_value cause, const char *name);
KLIO_NORETURN void klio_r_uncaught(klio_value v);
KLIO_NORETURN void klio_r_no_method(const char *name);
KLIO_NORETURN void klio_r_unreachable(void);

#ifdef __cplusplus
}
#endif

#endif /* KLIO_RT_H */
