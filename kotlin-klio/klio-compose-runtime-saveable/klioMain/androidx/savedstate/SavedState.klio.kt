/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.savedstate

import androidx.lifecycle.LifecycleOwner

/**
 * The slice of androidx.savedstate that SaveableStateRegistryWrapper bridges
 * to: an in-memory key/value state container plus the registry/controller/
 * owner contract. klio keeps everything in process memory — the wrapper's
 * save/restore round-trip works, there is just no OS bundle behind it.
 */
public class SavedState internal constructor(
    internal val map: MutableMap<String, Any?> = mutableMapOf(),
)

public class SavedStateReader internal constructor(private val state: SavedState) {
    public fun isEmpty(): Boolean = state.map.isEmpty()
}

public fun <T> SavedState.read(block: SavedStateReader.() -> T): T = SavedStateReader(this).block()

public fun savedState(): SavedState = SavedState()

public class SavedStateRegistry internal constructor() {
    private val providers = LinkedHashMap<String, () -> SavedState?>()
    private var restored: SavedState? = null

    public val isRestored: Boolean
        get() = restored != null

    public fun registerSavedStateProvider(key: String, provider: () -> SavedState?) {
        providers[key] = provider
    }

    public fun unregisterSavedStateProvider(key: String) {
        providers.remove(key)
    }

    public fun consumeRestoredStateForKey(key: String): SavedState? {
        val r = restored ?: return null
        return r.map.remove(key) as? SavedState
    }

    internal fun performRestore(state: SavedState?) {
        restored = state
    }

    internal fun performSave(outBundle: SavedState) {
        for ((k, p) in providers) {
            val v = p()
            if (v != null) outBundle.map[k] = v
        }
    }
}

public interface SavedStateRegistryOwner : LifecycleOwner {
    public val savedStateRegistry: SavedStateRegistry
}

public class SavedStateRegistryController private constructor(
    @Suppress("unused") private val owner: SavedStateRegistryOwner,
) {
    public val savedStateRegistry: SavedStateRegistry = SavedStateRegistry()

    public fun performRestore(savedState: SavedState?) {
        savedStateRegistry.performRestore(savedState)
    }

    public fun performSave(outBundle: SavedState) {
        savedStateRegistry.performSave(outBundle)
    }

    public companion object {
        public fun create(owner: SavedStateRegistryOwner): SavedStateRegistryController =
            SavedStateRegistryController(owner)
    }
}
