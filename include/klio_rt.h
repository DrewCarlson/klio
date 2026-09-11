/* klio_rt — the C ABI of the klio Kotlin runtime: program bootstrap plus
 * the per-op helpers transpiled C calls (`klio transpile`). Link against
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

/* Runs the Kotlin program at `path` against the pre-baked dependency base
 * at `base_image`, exactly as `klio run-image` would. Transpiled programs
 * use this entry: their emitted ids are only meaningful against the module
 * assembled from that exact artifact. */
int klio_rt_run_image(const char *base_image, const char *path);

/* Run a whole-program image (`klio transpile` writes one beside the C file):
 * the module is complete, so the process neither parses nor lowers — the same
 * boot a bundled program gets. This is what an emitted `main` calls. */
int klio_rt_run_program_image(const char *program_image);

/* The hot-view layout descriptor: Value byte offsets measured against
 * the running library at startup, so generated inline scalar ops are
 * correct by construction. `usable == 0` means the process reclaim mode
 * requires the per-op helpers instead. */
typedef struct {
  uint32_t value_size, tag_off, tag_size, int_off, long_off, bool_off;
  uint64_t tag_int, tag_long, tag_bool, tag_unit;
  uint8_t usable;
  /* Frame cur_span (?Span) layout for the inlined trace store;
   * span_usable == 0 keeps traces on the klio_op_trace helper. */
  uint8_t span_usable;
  uint32_t span_file_off, span_start_off, span_end_off, span_tag_off;
  uint8_t span_tag_set;
  /* Char payload location + tag, for fused loops over Char scalars. */
  uint32_t char_off;
  uint64_t tag_char;
  /* Object view: enough of the Instance layout for an inline stored-field
     read behind a class guard. obj_usable == 0 keeps field reads on the
     escape helper. */
  uint8_t obj_usable;
  uint64_t tag_instance;
  uint32_t inst_ptr_off;
  uint32_t cell_data_off;
  uint32_t inst_class_off;
  uint32_t inst_fields_off;
  uint32_t fields_ptr_off;
  uint32_t fields_len_off;
  uint32_t field_stride;
  uint32_t field_value_off;
  /* Array view: an IntArray element read. arr_prim_int_word is the probed
     byte pattern that means "primitive Int storage". */
  uint64_t tag_array;
  uint32_t arr_cell_off;
  uint32_t arr_prim_off;
  uint64_t arr_prim_int_word;
  uint32_t primbuf_ptr_off;
  uint32_t primbuf_len_off;
} klio_hot_layout;
void klio_rt_hot_layout(klio_hot_layout *out);

/* The frame flag/counter addresses the emitted C polls to inline the
 * fused edge guard; fetched per activation entry (threadlocal state).
 * klio_op_edge_rare runs the guard's slow work for the fired triggers:
 * bit0 counter cadence, bit1 abandon, bit2 gc pending, bit3 stress,
 * bit4 idle cadence. */
typedef struct {
  uint64_t *counter;
  uint64_t *idle;
  const uint8_t *abandonable;
  const uint8_t *rb_abandon;
  const uint8_t *abandon_req;
  const uint8_t *gc_pending;
  uint8_t gc_on;
  uint8_t always;
  /* Rare-trigger handler for THIS view's context: the transpiled
   * program's views route to klio_op_edge_rare over its NativeCtx;
   * the interpreter's leaf gate installs a ctx-free handler that
   * bails the leaf on persistent conditions. Emitted kv_edge calls
   * through this pointer, never the export directly. */
  int32_t (*rare)(void *ctx, uint32_t reasons);
  /* Field-read route resolver for leaf bodies (genre-8 instance
   * handles): resolves (receiver cell, field name) to the class
   * identity (low 48 bits) plus the PLAIN STORED slot index, exactly
   * the interpreter's own single-fill site claim. Returns 0 when the
   * field is not a plain stored slot (getter, delegate, outer-hop) —
   * the leaf bails. May be null (view built by a non-leaf path). */
  void *route_ctx;
  int32_t (*field_route)(void *route_ctx, void *recv_cell, const char *name, uint64_t *cls48_out, int32_t *slot_out);
  /* Instance-of verdict for leaf genre-8 handles: 1 = yes, 2 = no,
   * 0 = miss (bail). NULL outside the leaf gates. */
  int32_t (*type_route)(void *route_ctx, void *recv_cell, const char *name);
  /* Static-member read for leaf genre-9 class handles (enum entries
   * only): fills (value, genre) and returns 1, or 0 to bail. */
  int32_t (*statics_route)(void *route_ctx, const char *owner, const char *name, int64_t *out_v, int32_t *out_g);
} klio_edge_view;
void klio_op_edge_view(void *ctx, klio_edge_view *out);
int32_t klio_op_edge_rare(void *ctx, uint32_t reasons);

/* The frame's cur_span storage for the inlined trace store. */
uint8_t *klio_op_span_slot(void *ctx);

/* Registers the generated code's layout globals; the run entries fill
 * them after the performance profile (hence the reclaim mode, hence
 * `usable`) is chosen. Call before klio_rt_run_*. */
void klio_rt_register_hot_layout(klio_hot_layout *slot);

/* Registers the generated file's EMIT-TIME copy of the layout, whose
 * values its inline fast paths carry as compile-time constants. The run
 * entries verify it against the live fill; on any mismatch the whole hot
 * view is disabled (usable/obj_usable/span_usable forced 0) so the
 * generated code falls back to the exported helpers instead of reading
 * through wrong offsets. Call before klio_rt_run_*. */
void klio_rt_register_hot_frozen(const klio_hot_layout *frozen);

/* The library's ABI version (this header describes version 5). */
int klio_rt_abi_version(void);

/* A transpiled function body: runs the function's blocks starting at
 * `entry_block` against the opaque activation context. Generated by
 * `klio transpile`; not meant to be hand-written. */
typedef void (*klio_native_fn)(void *ctx, uint32_t entry_block);

/* Registers a transpiled body for the function id `fid`; the interpreter
 * then runs it in place of its bytecode. Call before klio_rt_run_file —
 * the table is read-only once the program runs. `fqn` (the function's
 * fully qualified name, as emitted) guards the fid: a mismatched entry is
 * ignored, falling back to interpretation rather than running the wrong
 * body. */
void klio_rt_register_native(uint32_t fid, klio_native_fn f, const char *fqn);

/* Declares the func/const table sizes of the module the emitter walked;
 * a frame whose module disagrees runs interpreted (the emitted ids index
 * these tables and mean nothing against any other module). Generated
 * code calls this before registering function bodies. */
void klio_rt_register_module_check(uint64_t n_funcs, uint64_t n_consts);

/* Per-op helpers — the interpreter's own op bodies behind the C ABI.
 * `ctx` is the opaque activation context a native fn was invoked with.
 * Helpers returning int32_t follow one contract: 0 = continue in the
 * emitted code; nonzero = the emitted function must return immediately
 * (the outcome has been recorded on the context). The branch helpers
 * (klio_op_br / klio_op_cmp_br) instead return 1 = take the true edge,
 * 0 = take the false edge, 2 = return immediately. */
/* The activation's register file for the generated inline scalar ops
 * (stable for the whole activation). */
uint8_t *klio_op_regs(void *ctx);
void    klio_op_trace(void *ctx, uint32_t file, uint32_t start, uint32_t end);
int32_t klio_op_const_load(void *ctx, uint32_t dst, uint32_t const_id);
void    klio_op_const_int(void *ctx, uint32_t dst, int32_t payload);
void    klio_op_move(void *ctx, uint32_t dst, uint32_t src);
void    klio_op_load_param(void *ctx, uint32_t dst, uint32_t idx);
void    klio_op_cell_get(void *ctx, uint32_t dst, uint32_t cell);
int32_t klio_op_bin(void *ctx, uint32_t block, uint32_t inst_idx, uint32_t kind, uint32_t dst, uint32_t lhs, uint32_t rhs);
int32_t klio_op_escape(void *ctx, uint32_t block, uint32_t inst_idx);
/* Resolve a GetField site to (class identity, stored slot) for the receiver
   currently in its register. 0 means the site is not a plain stored read. */
/* GC write barrier for a cell about to receive a Value store. */
void klio_rt_write_barrier(void *cell);
int32_t klio_op_field_route(void *ctx, uint32_t block, uint32_t inst_idx,
                            uint64_t *cls_out, int32_t *slot_out);
/* The same verdict for a SetField site (from the interpreter's write memo). */
int32_t klio_op_field_write_route(void *ctx, uint32_t block, uint32_t inst_idx,
                                  uint64_t *cls_out, int32_t *slot_out);
int32_t klio_op_call(void *ctx, uint32_t block, uint32_t inst_idx);

/* Scalar-replay leaf body: the whole function over (int64 value, genre)
 * pairs — genres 0 Int, 1 Long, 2 Bool, 3 Unit, 4 Char. Nonzero = result
 * in (*ret, *retg); zero = pure bail, the runtime re-runs the call.
 * *retg == 200 is a ctor-tail: *ret is the address of the site's
 * klio_ctor_site and aux/auxg carry the constructor's scalar
 * arguments; the runtime constructs once through the host. */
typedef int32_t (*klio_leaf_fn)(void *ctx, klio_edge_view *ev,
                                const int64_t *argv, const int32_t *argg,
                                int64_t *ret, int32_t *retg, uint32_t depth,
                                int64_t *aux, int32_t *auxg);
/* One static descriptor per ctor-tail site; *ret carries its address.
 * `memo` caches the runtime-resolved owner FuncId + 1 (bakes are not
 * cross-process id-stable, so the C names the site by fqn). */
typedef struct {
  const char *fqn;
  uint32_t block;
  uint32_t inst;
  uint64_t memo;
} klio_ctor_site;
void klio_rt_register_native_leaf(uint32_t fid, klio_leaf_fn f, const char *fqn);
int32_t klio_op_edge(void *ctx);
int32_t klio_op_br(void *ctx, uint32_t block, uint32_t cond);
int32_t klio_op_cmp_br(void *ctx, uint32_t block, uint32_t inst_idx, uint32_t kind, uint32_t dst, uint32_t lhs, uint32_t rhs);
void    klio_op_ret(void *ctx, uint32_t has_val, uint32_t reg);
void    klio_op_term(void *ctx, uint32_t block);
void    klio_op_goto_exit(void *ctx, uint32_t block);

/* ------------------------------------------------------------------ */
/* The native object ABI: what a COMPILED program calls.                */
/*                                                                      */
/* A compiled program IS the program — there is no module to look a     */
/* class up in — so classes arrive as emitted descriptors registered    */
/* before main, and a field is addressed by the index the emitter       */
/* resolved. Instances are the runtime's ordinary instances, so a       */
/* compiled object traces, prints and flows into collections exactly as */
/* an interpreted one does.                                             */

/* A Value as C sees it. Opaque: pass it back, never read inside. */
typedef struct { uint64_t lo, hi; } klio_value;

/* Install the collector's view of compiled frames. Call before main. */
void klio_nat_init(uint32_t reserved);

/* Register an emitted class; the handle is what allocations name. */
uint32_t klio_nat_class(const char *name, uint32_t n_fields,
                        const char *const *field_names);

/* A fresh instance with every field Unit; the compiled constructor fills it. */
klio_value klio_nat_alloc_instance(uint32_t cls);
klio_value klio_nat_get(klio_value recv, uint32_t idx);
void       klio_nat_set(klio_value recv, uint32_t idx, klio_value val);

/* The collector is precisely rooted and never scans the native stack, so a
 * compiled frame publishes its OBJECT slots for the duration of the call.
 * Scalars stay in C locals: nothing on the heap depends on them. */
typedef struct klio_nat_frame {
  struct klio_nat_frame *prev;
  uint32_t n;
  klio_value *slots;
} klio_nat_frame;
void klio_nat_enter(klio_nat_frame *f);
/* A `longjmp` to a handler skips the `klio_nat_leave` of every frame between
 * the throw and the catch, so the landing pad restores the chain itself. */
klio_nat_frame *klio_nat_frame_mark(void);
void klio_nat_frame_restore(klio_nat_frame *mark);
/* Ends the program-lifetime allocation phase: call after registering classes
 * and before the program body, or nothing the body allocates is collectable. */
void klio_nat_begin(void);
/* The safe point: compiled code polls at loop back edges. */
void klio_nat_safepoint(void);
void klio_nat_leave(klio_nat_frame *f);

/* Strings and rendering. `klio_nat_println` renders through the interpreter's
 * own renderer, so compiled output cannot drift from interpreted output. */
klio_value klio_nat_string(const char *bytes, size_t len);
klio_value klio_nat_concat(klio_value a, klio_value b);
int32_t    klio_nat_str_length(klio_value v);
void       klio_nat_println(klio_value v);
/* `print`: the same renderer, without the newline. */
void       klio_nat_print(klio_value v);

/* Lists. Data-structure work on the runtime's own types: no dispatch. */
klio_value klio_nat_list(const klio_value *argv, uint32_t argc);
klio_value klio_nat_mutable_list(const klio_value *argv, uint32_t argc);
int32_t    klio_nat_list_size(klio_value v);
klio_value klio_nat_list_get(klio_value v, int32_t idx);
void       klio_nat_list_set(klio_value v, int32_t idx, klio_value x);
void       klio_nat_list_add(klio_value v, klio_value x);

/* Arrays. A primitive array is a packed scalar buffer, so `kind` names the
 * element kind: 0 Int, 1 Long, 2 Double, 3 Float, 4 Short, 5 Byte, 6 Boolean,
 * 7 Char. A reference `Array<T>` holds boxed values. */
klio_value klio_nat_prim_array(uint32_t kind, int32_t n);
klio_value klio_nat_prim_array_of(uint32_t kind, const klio_value *v, uint32_t n);
klio_value klio_nat_ref_array(const klio_value *v, uint32_t n);
klio_value klio_nat_ref_array_sized(int32_t n);
int32_t    klio_nat_array_size(klio_value a);
klio_value klio_nat_array_get(klio_value a, int32_t i);
void       klio_nat_array_set(klio_value a, int32_t i, klio_value v);

/* Null and reference comparison. A field access on a null receiver raises the
 * same NullPointerException the interpreter would. */
klio_value klio_nat_null(void);
int32_t    klio_nat_is_null(klio_value v);
int32_t    klio_nat_value_eq(klio_value a, klio_value b);

/* Char prints as a character, and Short/Byte render as themselves, so the box
 * carries the kind rather than widening them all to Int. */
/* The registered class handle of an instance: what a compiled dispatcher
 * switches on. maxint means "not an instance of a class this program knows". */
uint32_t klio_nat_class_of(klio_value v);
/* A virtual call that reached a receiver no arm handles. */
KLIO_NORETURN void klio_nat_no_method(const char *name);

/* A `var` captured by a lambda: a shared box, so both sides see writes. */
/* An uncaught throw: a program the backend accepts has no catch handler, so a
 * throw always leaves it. */
KLIO_NORETURN void klio_nat_throw(klio_value v);
/* A throwable of the named type: exception classes are the runtime's own, not
 * shapes the emitter lays out. `type_id` is the type's preorder number in the
 * program's throwable hierarchy. */
klio_value klio_nat_exception(const char *fqn, klio_value message, uint32_t type_id);
/* Whether a thrown value is caught by a handler for the type spanning
 * [lo, hi). The hierarchy is numbered in preorder, so a type's subtree is one
 * contiguous interval and the test is two comparisons. */
int32_t klio_nat_catches(klio_value v, uint32_t lo, uint32_t hi);

klio_value klio_nat_cell(klio_value v);
klio_value klio_nat_cell_get(klio_value c);
void       klio_nat_cell_set(klio_value c, klio_value v);

klio_value klio_nat_box_char(uint16_t v);
klio_value klio_nat_box_short(int16_t v);
klio_value klio_nat_box_byte(int8_t v);
uint16_t klio_nat_char(klio_value v);
int16_t  klio_nat_short(klio_value v);
int8_t   klio_nat_byte(klio_value v);

klio_value klio_nat_box_int(int32_t v);
klio_value klio_nat_box_long(int64_t v);
klio_value klio_nat_box_double(double v);
klio_value klio_nat_box_float(float v);
klio_value klio_nat_box_bool(int32_t v);
klio_value klio_nat_box_unit(void);
int32_t klio_nat_int(klio_value v);
int64_t klio_nat_long(klio_value v);
double  klio_nat_double(klio_value v);
float   klio_nat_float(klio_value v);
int32_t klio_nat_bool(klio_value v);

#ifdef __cplusplus
}
#endif

#endif /* KLIO_RT_H */
