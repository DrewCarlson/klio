/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

// Host intrinsics backed by the Skia shim (src/compose_ui). Registered by the
// compose_ui module's host bindings, which are installed for every pack program.

// Combines two serialized path command buffers with a boolean op (op: 0
// difference, 1 intersect, 2 union, 3 xor, 4 reverse-difference — matching
// PathOperation). Returns the result command buffer, or null on failure / when
// no Skia backend is present.
internal fun __skia_path_op(a: String, b: String, op: Int): String? =
    error("intrinsic androidx.compose.ui.graphics.__skia_path_op not installed")
