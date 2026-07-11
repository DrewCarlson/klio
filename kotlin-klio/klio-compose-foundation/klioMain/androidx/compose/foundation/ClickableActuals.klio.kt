/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation

import androidx.compose.ui.node.DelegatableNode

/**
 * klio actual (desktop semantics): a mouse click does not move focus to
 * the clickable — desktop Compose keeps click-focus off and moves focus
 * through keyboard navigation.
 */
internal actual fun isRequestFocusOnClickEnabled(): Boolean = false

/**
 * klio actual: no indication delay — the desktop shows press feedback
 * immediately (the Android delay exists to await scroll disambiguation).
 */
internal actual val TapIndicationDelay: Long = 0L

/** klio actual: the desktop root is never a scrollable container. */
internal actual fun DelegatableNode.isComposeRootInScrollableContainer(): Boolean = false
