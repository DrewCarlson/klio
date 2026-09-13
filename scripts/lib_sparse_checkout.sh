#!/usr/bin/env bash
# Shared helper for the `update = none` sparse submodule init scripts.
#
# These submodules (kotlin, compose-multiplatform-core, androidx.collection) are
# huge, so each is populated as a shallow, filtered, cone-sparse checkout of just
# the source sets klio consumes. The catch: the desired sparse set grows over
# time as klio consumes more of a library, and a checkout left on disk by an
# older version of a caller keeps its old, narrower set. A plain "already
# present, nothing to do" guard then skips the widen, and packs whose manifests
# reference the newly-needed files build incomplete (missing-source) packs.
#
# reconcile_sparse_submodule brings the on-disk checkout into line with the
# caller every time it runs: it moves the checkout to the ref pinned in
# .gitmodules (fetching that tag when the shallow clone lacks it) and widens the
# sparse set to the caller's current list. Re-running an init script, or
# bootstrap.sh, repairs a stale pin or a narrow checkout instead of skipping it.
#
# Must be called with the repo root as the working directory.

# reconcile_sparse_submodule <path> <url> <ref> <clone-filter> <sparse-path>...
#   path         submodule path, relative to repo root
#   url, ref     remote + pinned tag (from .gitmodules)
#   clone-filter partial-clone filter for a fresh clone, e.g. --filter=tree:0
#   sparse-path  one or more cone-mode directories to check out
reconcile_sparse_submodule() {
    local path="$1" url="$2" ref="$3" filter="$4"
    shift 4
    local want=("$@")

    # An unpopulated submodule placeholder is an empty dir with no `.git` of its
    # own, so `git -C "$path" ...` walks up to the PARENT repo and every query
    # answers about it — `rev-parse --is-inside-work-tree` says true, and the
    # widen path below then runs `git checkout <ref>` against the parent, which
    # tries to fetch the submodule's tag from the parent's remote and hangs.
    # Require the submodule to have its own gitdir before treating it as present.
    if [ -e "$path/.git" ] && git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Existing checkout: reconcile its ref and its sparse set.
        local current desired at want_commit
        # A worktree left non-sparse by a manual checkout makes this exit 128;
        # treat that as "no sparse set" and fall through to the widen below.
        current="$(git -C "$path" sparse-checkout list 2>/dev/null | LC_ALL=C sort || true)"
        desired="$(printf '%s\n' "${want[@]}" | LC_ALL=C sort)"
        # Reconcile the pinned ref first: a bump in .gitmodules has to move the
        # checkout, and the tag may not be in this shallow clone yet.
        at="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
        want_commit="$(git -C "$path" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null || true)"
        if [ -z "$want_commit" ]; then
            echo "${path}: fetching ${ref} ..."
            # shellcheck disable=SC2086 # filter is a single intentional token
            git -C "$path" fetch $filter --depth 1 origin tag "$ref"
            want_commit="$(git -C "$path" rev-parse -q --verify "${ref}^{commit}")"
        fi
        if [ "$at" != "$want_commit" ]; then
            echo "${path}: moving checkout to ${ref} ..."
            git -C "$path" checkout --detach "$ref"
            current=""
        fi
        if [ "$current" = "$desired" ]; then
            echo "${path}: sparse checkout up to date (${ref})."
            return 0
        fi
        echo "${path}: widening sparse checkout to the current source set (${ref}) ..."
        git -C "$path" sparse-checkout init --cone
        git -C "$path" sparse-checkout set "${want[@]}"
        # Materialize newly-included paths; the partial clone fetches their
        # trees/blobs from the promisor remote on demand.
        git -C "$path" checkout "$ref" >/dev/null 2>&1 || git -C "$path" checkout >/dev/null 2>&1 || true
        echo "${path}: sparse checkout updated."
        return 0
    fi

    # Fresh checkout. A klio clone leaves an empty submodule placeholder that
    # would block the clone below; clear it (the gitlink in the index and the
    # .gitmodules entry remain, so absorbgitdirs re-links it afterward).
    rm -rf "$path"
    # shellcheck disable=SC2086 # filter is a single intentional token
    git clone $filter --no-checkout --depth 1 --branch "$ref" "$url" "$path"
    git -C "$path" sparse-checkout init --cone
    git -C "$path" sparse-checkout set "${want[@]}"
    git -C "$path" checkout "$ref"
    # Move the submodule's .git under .git/modules so it is a proper submodule.
    git submodule absorbgitdirs "$path"
    echo "${path}: populated at ${ref}."
}
