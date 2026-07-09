/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.platform

import androidx.compose.runtime.AbstractApplier
import androidx.compose.ui.klio.KlioUiApplier
import androidx.compose.ui.node.LayoutNode

// The applier used by subcompositions (subcompose layouts such as Lazy* and
// BoxWithConstraints) to build their LayoutNode subtrees.
internal actual fun createApplier(container: LayoutNode): AbstractApplier<LayoutNode> =
    KlioUiApplier(container)
