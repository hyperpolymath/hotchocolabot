#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# repo-metadata.sh — single source of truth for this repository's GitHub
# description and topics.
#
# The About section of a GitHub repository lives in repository *settings*, not in
# the tree, which is exactly why it drifts: nothing in CI can see it, and nothing
# in a clone carries it. This script closes that gap. It reads the declared
# values from .github/repository-topics.json and either reports them, compares them
# against what GitHub currently has, or pushes them to GitHub.
#
#   scripts/repo-metadata.sh show   [REPO]
#   scripts/repo-metadata.sh audit  [REPO]     # read-only; exits 1 on drift
#   scripts/repo-metadata.sh apply  [REPO]     # needs admin on REPO
#
# REPO defaults to hyperpolymath/hotchocolabot; override with $REPO or $2.
#
# Every sibling repository in hyperpolymath/* can use this unchanged: point it at
# its own .github/repository-topics.json via the META environment variable, or copy
# the file in. The rationale for every value is in docs/REPO_METADATA.adoc.
#
# Requires: bash, jq, gh (authenticated).

set -euo pipefail

META="${META:-.github/repository-topics.json}"
DEFAULT_REPO="${DEFAULT_REPO:-hyperpolymath/hotchocolabot}"

die() {
    echo "error: $*" >&2
    exit 1
}

# Codepoint length, not bytes: the description carries an en dash and an em
# dash, and GitHub counts characters. jq's `length` is the portable way to get
# that regardless of the caller's locale.
description_text() {
    jq -r '.description_text' "$META"
}

description_chars() {
    jq -r '.description_text | length' "$META"
}

usage() {
    sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
}

# --- preflight ---------------------------------------------------------------

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

check_declaration() {
    [ -f "$META" ] || die "metadata file not found: $META"
    jq -e . "$META" >/dev/null 2>&1 || die "metadata file is not valid JSON: $META"

    local desc topics
    desc="$(description_text)"
    topics="$(jq -r '(.topics // []) | length' "$META")"

    [ -n "$desc" ] || die "metadata declares an empty description"
    [ "$(description_chars)" -le 350 ] ||
        die "description is $(description_chars) characters; GitHub's limit is 350"

    [ "$topics" -le 20 ] || die "$topics topics declared; GitHub's limit is 20"
    [ "$topics" -gt 0 ] || die "no topics declared"

    local bad
    bad="$(jq -r '(.topics // [])[] | select((test("^[a-z0-9-]+$") or (length > 50)) | not)' "$META")"
    [ -z "$bad" ] || die "invalid topic(s) — must be lowercase alphanumerics/hyphens, max 50 chars: $bad"

    # The grouped view exists for humans; make sure it cannot drift from the flat
    # list that actually gets sent to GitHub.
    if jq -e 'has("topic_groups")' "$META" >/dev/null 2>&1; then
        local grouped
        grouped="$(jq -r '[.topic_groups[]] | flatten | unique | join(" ")' "$META")"
        local flat
        flat="$(jq -r '.topics | unique | join(" ")' "$META")"
        [ "$grouped" = "$flat" ] ||
            die "topic_groups and topics disagree — they must contain the same set"
    fi

    # selection_rationale is the estate's why-is-this-tagged view (bot / human /
    # domain). A topic may appear in more than one bucket, but never in a bucket
    # without also being a real topic.
    if jq -e 'has("selection_rationale")' "$META" >/dev/null 2>&1; then
        local orphans
        orphans="$(jq -r '
            (.topics) as $all
            | [.selection_rationale[] | .[] | select(. as $t | ($all | index($t)) == null)]
            | unique | join(" ")' "$META")"
        [ -z "$orphans" ] ||
            die "selection_rationale mentions topic(s) not in topics: $orphans"
    fi
}

# --- modes -------------------------------------------------------------------

mode_show() {
    check_declaration
    echo "=== Canonical repository metadata ($META) ==="
    echo
    description_text
    echo
    printf 'topics (%s/20):\n' "$(jq -r '.topics | length' "$META")"
    jq -r '.topic_groups // {} | to_entries[] | "  \(.key):\n" + (.value | map("    - " + .) | join("\n"))' "$META"
    echo
    echo "description chars: $(description_chars) / 350"
    echo
    echo "Rationale for every value: docs/REPO_METADATA.adoc"
    echo "Apply with:              just repo-metadata-apply"
}

mode_audit() {
    check_declaration
    need gh

    local repo="$1"
    local live live_topics want_description want_topics
    live="$(gh api "repos/${repo}")" ||
        die "could not read repos/${repo} — is the repo name right and 'gh' authenticated?"

    live_topics="$(printf '%s' "$live" | jq -r '(.topics // []) | sort | join(" ")')"
    want_description="$(description_text)"
    want_topics="$(jq -r '.topics | sort | join(" ")' "$META")"

    local live_description
    live_description="$(printf '%s' "$live" | jq -r '.description // ""')"

    echo "=== $repo ==="
    echo "live description: ${live_description:-(empty)}"
    echo "  declared:       $want_description"
    if [ "$live_description" = "$want_description" ]; then
        echo "  status:         ✓ match"
    else
        echo "  status:         ✗ DRIFT"
    fi

    echo
    echo "live topics: ${live_topics:-(none)}"
    echo "  declared: $want_topics"
    if [ "$live_topics" = "$want_topics" ]; then
        echo "  status:   ✓ match"
    else
        echo "  status:   ✗ DRIFT"
        comm -23 \
            <(printf '%s\n' "$live_topics" | tr ' ' '\n' | sed '/^$/d' | sort) \
            <(printf '%s\n' "$want_topics" | tr ' ' '\n' | sed '/^$/d' | sort) |
            sed 's/^/    only live:      /'
        comm -13 \
            <(printf '%s\n' "$live_topics" | tr ' ' '\n' | sed '/^$/d' | sort) \
            <(printf '%s\n' "$want_topics" | tr ' ' '\n' | sed '/^$/d' | sort) |
            sed 's/^/    only declared:  /'
    fi

    if [ "$live_description" = "$want_description" ] && [ "$live_topics" = "$want_topics" ]; then
        echo
        echo "no drift."
        return 0
    fi

    echo
    echo "Fix with: just repo-metadata-apply REPO=${repo}"
    return 1
}

mode_apply() {
    check_declaration
    need gh

    local repo="$1"
    echo "Applying declared description + topics to ${repo}..."

    # PATCH with a topics *array* replaces the whole set, so this cannot leave
    # stale topics behind the way repeated --add-topic would.
    if ! jq '{description: .description_text, topics: .topics}' "$META" |
        gh api -X PATCH "repos/${repo}" --input - --silent >/dev/null; then
        die "GitHub refused the update. Applying repository settings needs admin on ${repo}."
    fi

    echo "done. verifying..."
    mode_audit "$repo" || die "update reported success but verification failed"
}

# --- entry point -------------------------------------------------------------

main() {
    local cmd="${1:-show}"
    local repo="${2:-${REPO:-$DEFAULT_REPO}}"

    case "$cmd" in
        show | audit | apply) ;;
        -h | --help | help)
            usage
            return 0
            ;;
        *)
            usage >&2
            die "unknown mode '$cmd' (expected show, audit or apply)"
            ;;
    esac

    case "$cmd" in
        show) mode_show ;;
        audit) mode_audit "$repo" ;;
        apply) mode_apply "$repo" ;;
    esac
}

main "$@"
