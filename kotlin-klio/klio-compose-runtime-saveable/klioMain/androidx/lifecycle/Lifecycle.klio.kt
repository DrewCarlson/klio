/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.lifecycle

/**
 * The slice of androidx.lifecycle that androidx.savedstate's owner contract
 * needs. klio has no Android lifecycle; a registry starts INITIALIZED and
 * moves only through explicit [LifecycleRegistry.handleLifecycleEvent] calls.
 */
public abstract class Lifecycle {
    public enum class State { DESTROYED, INITIALIZED, CREATED, STARTED, RESUMED }

    public enum class Event {
        ON_CREATE, ON_START, ON_RESUME, ON_PAUSE, ON_STOP, ON_DESTROY;

        public fun getTargetState(): State =
            when (this) {
                ON_CREATE, ON_STOP -> State.CREATED
                ON_START, ON_PAUSE -> State.STARTED
                ON_RESUME -> State.RESUMED
                ON_DESTROY -> State.DESTROYED
            }
    }

    public abstract val currentState: State
}

public interface LifecycleOwner {
    public val lifecycle: Lifecycle
}

public class LifecycleRegistry private constructor(
    @Suppress("unused") private val owner: LifecycleOwner,
) : Lifecycle() {
    override var currentState: State = State.INITIALIZED

    public fun handleLifecycleEvent(event: Event) {
        currentState = event.getTargetState()
    }

    public companion object {
        public fun createUnsafe(owner: LifecycleOwner): LifecycleRegistry = LifecycleRegistry(owner)
    }
}
