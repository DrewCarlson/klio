// klio `actual` for the ktor-util pipeline `DISABLE_SFG` expect.
//
// Upstream's posix actual reads the `KTOR_INTERNAL_DISABLE_SFG` env var via
// `getenv`. klio fixes it to `true`: the pipeline always runs through
// `DebugPipelineContext` (a plain proceed-nested suspend loop), the execution
// shape klio's cooperative coroutine driver supports natively. The
// `SuspendFunctionGun` path is never taken.

package io.ktor.util.pipeline

internal actual val DISABLE_SFG: Boolean = true
