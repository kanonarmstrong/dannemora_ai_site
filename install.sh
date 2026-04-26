#!/usr/bin/env bash
# dannemora installer — public entry point.
#
# Usage:
#   curl -fsSL https://dannemora.ai/install.sh | bash
#
# This script is the ONE piece of source code that is intentionally public.
# Its job is to:
#   1. Pre-flight (Docker, dialog, curl, bash version).
#   2. Run the 9-step COLLECT-PHASE wizard (AF-123 — this PR) into an
#      in-memory associative array. Validate each input against live APIs.
#   3. (Future, AF-TBD): exchange the license for a GHCR pull token,
#      docker pull + cosign verify, hand off to the install phase inside
#      the image.
#
# Nothing proprietary lives in this file. All product logic is inside
# the compiled image at ghcr.io/dannemoraai/dannemora.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env for testing).
# ---------------------------------------------------------------------------
DANNEMORA_API_BASE="${DANNEMORA_API_BASE:-https://api.dannemora.ai}"
DANNEMORA_REGISTRY="${DANNEMORA_REGISTRY:-ghcr.io/dannemoraai/dannemora}"
DANNEMORA_IMAGE_TAG="${DANNEMORA_IMAGE_TAG:-latest}"
DANNEMORA_COSIGN_IDENTITY="${DANNEMORA_COSIGN_IDENTITY:-https://github.com/dannemoraai/dannemora/.github/workflows/release.yml@refs/heads/main}"
DANNEMORA_COSIGN_ISSUER="${DANNEMORA_COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

# When DANNEMORA_OFFLINE=1, skip live API validators (license, GitHub
# repo/scope checks). Useful for development/CI before api.dannemora.ai
# is fully deployed; not intended for customers.
DANNEMORA_OFFLINE="${DANNEMORA_OFFLINE:-0}"

# AF-133 rollback configuration.
#
# DANNEMORA_INSTALL_STATE_FILE  — JSON ledger of install-phase steps and
#                                  the artifacts each one created.
# DANNEMORA_INSTALL_DEBUG_LOG   — written when DANNEMORA_KEEP_ON_FAILURE=1
#                                  to help operators inspect a wedged install.
# DANNEMORA_INSTALL_LOG         — logs that survive rollback (operator keeps
#                                  this for the bug-report workflow).
# DANNEMORA_KEEP_ON_FAILURE     — set to "1" in env to disable automatic
#                                  rollback on ERR/INT/TERM. Use only for
#                                  debugging a stuck install.
DANNEMORA_INSTALL_STATE_FILE="${DANNEMORA_INSTALL_STATE_FILE:-/tmp/dannemora-install-state.json}"
DANNEMORA_INSTALL_DEBUG_LOG="${DANNEMORA_INSTALL_DEBUG_LOG:-/tmp/dannemora-install-debug.log}"
DANNEMORA_INSTALL_LOG="${DANNEMORA_INSTALL_LOG:-/var/log/dannemora-install.log}"
DANNEMORA_KEEP_ON_FAILURE="${DANNEMORA_KEEP_ON_FAILURE:-0}"

# Default models per agent role (per the schema).
readonly DEFAULT_MODEL_TL="claude-sonnet-4-6"
readonly DEFAULT_MODEL_DEV="claude-opus-4-7"
readonly DEFAULT_MODEL_QA="claude-sonnet-4-6"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
die() {
    echo "[dannemora] error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Pre-flight checks live inside preflight() rather than at source time
# so tests can source this file without tripping require_cmd dialog
# (the test sandbox usually doesn't have dialog or docker installed).
preflight() {
    # Bash 4+ required for associative arrays.
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        die "bash 4 or later required (got ${BASH_VERSION})"
    fi
    require_cmd curl
    require_cmd dialog
    # Docker required for the eventual install phase. The wizard itself
    # does not need it; we check early so the customer fails fast
    # instead of after 15 minutes of input.
    require_cmd docker
    docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and re-run."
    # cosign required to verify the image signature in Step 10b before
    # any container code is run.
    require_cmd cosign

    # AF-133: ensure rollback state paths are writable and free of stale state
    # from a prior aborted run.
    preflight_rollback_paths
}

# AF-133 helper: verify rollback's tmp paths are writable and warn / offer
# cleanup if a previous install left stale state behind. Called from preflight.
preflight_rollback_paths() {
    local tmpdir="${TMPDIR:-/tmp}"
    if [ ! -d "$tmpdir" ] || [ ! -w "$tmpdir" ]; then
        die "$tmpdir not writable — cannot stage installer state"
    fi
    if [ -e "$DANNEMORA_INSTALL_STATE_FILE" ]; then
        echo "[dannemora] warning: stale installer state found at ${DANNEMORA_INSTALL_STATE_FILE}" >&2
        echo "[dannemora] this means a previous install crashed or was killed before rollback completed." >&2
        if [ -t 0 ] && [ "${DANNEMORA_KEEP_ON_FAILURE:-0}" != "1" ]; then
            local reply=""
            read -r -p "[dannemora] remove stale state and continue? [y/N] " reply || reply=""
            case "$reply" in
                y|Y|yes|YES)
                    rm -f "$DANNEMORA_INSTALL_STATE_FILE" "$DANNEMORA_INSTALL_DEBUG_LOG"
                    echo "[dannemora] stale state cleared." >&2
                    ;;
                *)
                    die "refusing to start with stale state present; remove ${DANNEMORA_INSTALL_STATE_FILE} manually or re-run with answer 'y'"
                    ;;
            esac
        else
            # Non-interactive (curl|bash with no tty, or KEEP_ON_FAILURE set):
            # do not auto-delete; tell the operator how to recover.
            die "stale install state at ${DANNEMORA_INSTALL_STATE_FILE}; remove it (or run with DANNEMORA_KEEP_ON_FAILURE=1 if you are intentionally inspecting it) before re-running"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 10b: cosign-verify the pulled image against the embedded public key.
# ---------------------------------------------------------------------------
# This is the trust anchor: install.sh is served over HTTPS from
# dannemora.ai, the public key is embedded directly in this script (no
# secondary download), and any image not signed by Kanon's private key
# is rejected before docker run.
#
# The key below is filled in by the operator after running
# `cosign generate-key-pair` on a trusted machine. See
# docs/cosign-keypair.md for the full runbook.
#
# IMPORTANT: the heredoc terminator is quoted ('EOF'), so every line
# inside is preserved verbatim including leading whitespace. Do not
# indent the BEGIN/END/key-body lines or cosign will refuse to parse
# the public key.

DANNEMORA_COSIGN_PUBKEY=$(cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEsAsatmz8jVZ3OCJ2HcvtAiNaj8x
rVTiO3pl5aXId6WMf1Ci3LRrDovzNB09VE0DrON8ZLQaXa1xVmsKc3OhTg==
-----END PUBLIC KEY-----
EOF
)
readonly DANNEMORA_COSIGN_PUBKEY

verify_image_signature() {
    local image_ref="$1"
    require_cmd cosign

    # Write the embedded pubkey to a tempfile so cosign can read it.
    local pubkey_file
    pubkey_file="$(mktemp)"
    # shellcheck disable=SC2064  # expand now so $pubkey_file is captured
    trap "rm -f '$pubkey_file'" RETURN
    chmod 600 "$pubkey_file"
    printf '%s' "$DANNEMORA_COSIGN_PUBKEY" > "$pubkey_file"

    if ! cosign verify --key "$pubkey_file" "$image_ref" >/dev/null 2>&1; then
        die "Image signature verification failed for $image_ref. Refusing to run untrusted code."
    fi
    echo "[dannemora] image signature OK"
}

# ---------------------------------------------------------------------------
# Wizard state — single associative array, in-memory only until commit.
# ---------------------------------------------------------------------------
declare -A WIZARD=()

# Temp file used ONLY at commit time (last step). Created by mktemp,
# chmod 600.
#
# Cleanup semantics: the EXIT trap removes the temp file UNLESS
# WIZARD_COMMITTED=1 has been set (meaning we successfully reached the
# end of the wizard and the install phase is responsible for the file).
# This is what implements the ticket's requirement that 'nothing is
# written to disk if the customer cancels mid-wizard' — cancel paths
# never set the committed flag, so the trap always wins.
WIZARD_TEMP_FILE="${WIZARD_TEMP_FILE:-}"
WIZARD_COMMITTED="${WIZARD_COMMITTED:-0}"
cleanup() {
    if [ "${WIZARD_COMMITTED:-0}" != "1" ] && [ -n "${WIZARD_TEMP_FILE:-}" ] && [ -f "${WIZARD_TEMP_FILE}" ]; then
        rm -f "${WIZARD_TEMP_FILE}"
    fi
    # dialog leaves the terminal in a weird state if killed mid-screen.
    # Skip 'clear' when there's no TERM (test envs / CI / non-interactive).
    if [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Step return codes used by step functions.
readonly STEP_OK=0
readonly STEP_BACK=2
readonly STEP_CANCEL=3

# Common dialog dimensions.
readonly DIALOG_HEIGHT=18
readonly DIALOG_WIDTH=72

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
#
# Each validator returns 0 on success, non-zero on failure. Validators
# do NOT emit dialog screens themselves — they return a status code and
# write any human message to stderr; the calling step decides how to
# surface it (typically a --msgbox on the same screen).

validate_license_key() {
    local key="$1"
    # Format check first (cheap).
    if [[ ! "$key" =~ ^[A-Z0-9_-]{8,128}$ ]]; then
        echo "License key format invalid (expected 8-128 chars, A-Z 0-9 _ -)" >&2
        return 1
    fi
    if [ "${DANNEMORA_OFFLINE}" = "1" ]; then
        echo "OFFLINE mode: skipped live license validation" >&2
        return 0
    fi
    # Live check.
    local status
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -H 'Content-Type: application/json' \
        -d "{\"license_key\":\"${key}\"}" \
        "${DANNEMORA_API_BASE}/v1/license/validate" 2>/dev/null)" || {
        echo "Could not reach ${DANNEMORA_API_BASE} to validate license" >&2
        return 2
    }
    if [ "$status" = "200" ]; then
        return 0
    fi
    echo "License API returned HTTP ${status}" >&2
    return 3
}

validate_api_key_format() {
    local provider="$1" key="$2"
    case "$provider" in
        anthropic)
            [[ "$key" =~ ^sk-ant- ]] || {
                echo "Anthropic key must start with 'sk-ant-'" >&2
                return 1
            }
            ;;
        openai)
            [[ "$key" =~ ^sk- ]] || {
                echo "OpenAI key must start with 'sk-'" >&2
                return 1
            }
            ;;
        custom)
            # Custom endpoint: accept anything non-empty, length >= 8.
            [ "${#key}" -ge 8 ] || {
                echo "Key must be at least 8 characters" >&2
                return 1
            }
            ;;
        *)
            echo "Unknown provider: $provider" >&2
            return 1
            ;;
    esac
    return 0
}

validate_github_token() {
    # Returns 0 if the token has BOTH 'repo' and 'workflow' scopes.
    local token="$1"
    if [ "${DANNEMORA_OFFLINE}" = "1" ]; then
        echo "OFFLINE mode: skipped GitHub token scope check" >&2
        return 0
    fi
    local headers
    headers="$(curl -sS -I --max-time 10 \
        -H "Authorization: Bearer ${token}" \
        https://api.github.com/user 2>/dev/null)" || {
        echo "Could not reach api.github.com to validate token" >&2
        return 2
    }
    if ! echo "$headers" | grep -qi '^HTTP.* 200'; then
        echo "GitHub returned non-200 — token may be invalid" >&2
        return 3
    fi
    local scopes
    scopes="$(echo "$headers" | grep -i '^x-oauth-scopes:' | tr -d '\r' | cut -d: -f2-)"
    if ! echo "$scopes" | grep -qw 'repo'; then
        echo "Token missing 'repo' scope (got:${scopes})" >&2
        return 4
    fi
    if ! echo "$scopes" | grep -qw 'workflow'; then
        echo "Token missing 'workflow' scope (got:${scopes})" >&2
        return 5
    fi
    return 0
}

validate_github_repo_access() {
    # Verify the repo URL is reachable with the supplied token.
    # Accepts URLs like:
    #   https://github.com/owner/repo
    #   https://github.com/owner/repo.git
    #   git@github.com:owner/repo.git
    local url="$1" token="$2"
    if [ "${DANNEMORA_OFFLINE}" = "1" ]; then
        echo "OFFLINE mode: skipped GitHub repo access check" >&2
        return 0
    fi
    local owner repo
    if [[ "$url" =~ github\.com[/:]([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
    else
        echo "Could not parse GitHub URL (expected github.com/owner/repo)" >&2
        return 1
    fi
    local status
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer ${token}" \
        "https://api.github.com/repos/${owner}/${repo}" 2>/dev/null)" || {
        echo "Could not reach api.github.com to check repo access" >&2
        return 2
    }
    if [ "$status" = "200" ]; then
        return 0
    fi
    if [ "$status" = "404" ]; then
        echo "Repo ${owner}/${repo} not found, or token lacks access" >&2
        return 3
    fi
    echo "GitHub returned HTTP ${status} for ${owner}/${repo}" >&2
    return 4
}

validate_email_format() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Step helpers — keep the per-step logic readable.
# ---------------------------------------------------------------------------

# Show a one-line error in a small dialog and return so the caller can
# re-prompt. Prevents the wizard from advancing on bad input.
err_msg() {
    local msg="$1"
    dialog --backtitle "dannemora installer" \
        --title "Validation failed" \
        --msgbox "$msg" 8 60
}

# Read a value; pre-fill from WIZARD[$key] for back-nav. Cancel button
# returns STEP_BACK (== "go back one step"); ESC also goes back.
prompt_input() {
    local title="$1" body="$2" key="$3"
    local default="${WIZARD[$key]:-}"
    local out_file
    out_file="$(mktemp)"
    # shellcheck disable=SC2064  # expand now; out_file value, not name
    trap "rm -f '$out_file'" RETURN
    local rc=0
    dialog --backtitle "dannemora installer" \
        --title "$title" \
        --cancel-label "Back" \
        --inputbox "$body" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$default" \
        2>"$out_file" || rc=$?
    case $rc in
        0)
            WIZARD[$key]="$(cat "$out_file")"
            return $STEP_OK
            ;;
        1) return $STEP_BACK ;;       # Back / Cancel button
        255) return $STEP_BACK ;;     # ESC pressed
    esac
    return $STEP_CANCEL
}

# Same as prompt_input but the value is hidden (passwords / tokens / API keys).
prompt_password() {
    local title="$1" body="$2" key="$3"
    local default="${WIZARD[$key]:-}"
    local out_file
    out_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$out_file'" RETURN
    local rc=0
    dialog --backtitle "dannemora installer" \
        --title "$title" \
        --cancel-label "Back" \
        --insecure \
        --passwordbox "$body" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$default" \
        2>"$out_file" || rc=$?
    case $rc in
        0)
            WIZARD[$key]="$(cat "$out_file")"
            return $STEP_OK
            ;;
        1) return $STEP_BACK ;;
        255) return $STEP_BACK ;;
    esac
    return $STEP_CANCEL
}

# Single-choice menu. Items passed as alternating tag/desc pairs.
# Result lands in WIZARD[$key].
prompt_menu() {
    local title="$1" body="$2" key="$3"
    shift 3
    local out_file
    out_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$out_file'" RETURN
    local rc=0
    dialog --backtitle "dannemora installer" \
        --title "$title" \
        --cancel-label "Back" \
        --default-item "${WIZARD[$key]:-}" \
        --menu "$body" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 6 \
        "$@" \
        2>"$out_file" || rc=$?
    case $rc in
        0)
            WIZARD[$key]="$(cat "$out_file")"
            return $STEP_OK
            ;;
        1) return $STEP_BACK ;;
        255) return $STEP_BACK ;;
    esac
    return $STEP_CANCEL
}

# ---------------------------------------------------------------------------
# Step 0 — Prerequisites screen (AF-159)
#
# Renders BEFORE step 1. Lists everything the customer needs to have
# ready (license, AI key, ticket-system creds, GitHub PAT, optional
# Telegram bot) so they don't get stuck partway through the wizard
# hunting down a token.
#
# Step 0 is intentionally NOT counted in the "Step N of 9" labels —
# every other step keeps its existing 1..9 numbering.
#
# Two paths:
#   Yes → return $STEP_OK; wizard proceeds to step 1.
#   No  → print the prereq text to stdout (so the customer can scroll
#         back and copy the URLs) and exit 0. NOTHING is created on
#         the host: no infra, no rollback ledger, no Infisical, no
#         containers. This is a clean abort, not a cancel.
# ---------------------------------------------------------------------------

# Single source of truth for the prereq text — used by both the dialog
# screen and the stdout fallback on the No path. Keep this in sync with
# docs/prerequisites.md.
_dannemora_prereq_text() {
    cat <<'PREREQ_EOF'
Before continuing, you'll need:

1. SERVER (this one is fine): Ubuntu 22.04+ with Docker installed and running, 8GB+ RAM
2. DANNEMORA LICENSE: from dannemora.ai (you should have it from purchase)
3. AI PROVIDER — Anthropic OR OpenAI API key (paid account):
   - Anthropic: https://console.anthropic.com/settings/keys
   - OpenAI:    https://platform.openai.com/api-keys
4. TICKET SYSTEM (one of):
   - Linear API key:   https://linear.app/{your-workspace}/settings/api
   - Jira URL + email + API token: https://id.atlassian.com/manage-profile/security/api-tokens
   - GitHub Issues:    same as #5 below (no separate token needed)
5. GITHUB ACCESS: GitHub PAT with repo + workflow scopes
   - Classic:        https://github.com/settings/tokens (Classic, repo + workflow)
   - Fine-grained:   https://github.com/settings/personal-access-tokens/new
6. CHAT (optional): Telegram bot via @BotFather — https://core.telegram.org/bots#botfather

Have all of these ready before continuing. The installer prompts for them in order.
PREREQ_EOF
}

step_0_prerequisites() {
    local body
    body="$(_dannemora_prereq_text)"
    body+=$'\n\nReady to continue?'

    # Single --yesno keeps the flow tight; the body is ~22 lines + 2
    # trailing lines, which fits in a 26x76 dialog. We size this one
    # screen larger than the wizard default (DIALOG_HEIGHT=18) because
    # truncating the prereq URLs would defeat the purpose of the screen.
    local rc=0
    dialog --backtitle "dannemora installer" \
        --title "Before you start — prerequisites" \
        --yes-label "I have everything" \
        --no-label "I need to gather these first" \
        --yesno "$body" 26 76 || rc=$?

    case $rc in
        0)
            return $STEP_OK
            ;;
        *)
            # Customer doesn't have everything yet. Print the prereq
            # text to stdout (scrollable in the terminal) and exit 0
            # cleanly — NOT $STEP_CANCEL, because the wizard wasn't
            # cancelled mid-flight; the customer is just deferring.
            # Critically: nothing has been created on the host yet, so
            # there's nothing to roll back.
            if [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
                clear 2>/dev/null || true
            fi
            echo
            echo "[dannemora] No problem — here's what to gather before re-running"
            echo "[dannemora] curl -fsSL https://dannemora.ai/install.sh | bash:"
            echo
            _dannemora_prereq_text
            echo
            echo "[dannemora] When you're ready, re-run the install command above."
            exit 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 1 — License key
# ---------------------------------------------------------------------------
step_1_license() {
    while true; do
        prompt_input "Step 1 of 9 — License key" \
            "Enter your dannemora license key.\n\nFind it on the success page after checkout, or in the email we sent." \
            license_key
        local rc=$?
        [ $rc -eq $STEP_OK ] || return $rc

        local err
        err="$(validate_license_key "${WIZARD[license_key]}" 2>&1)" && return $STEP_OK
        err_msg "License key did not validate.\n\n${err}\n\nTry again or press Back."
    done
}

# ---------------------------------------------------------------------------
# Step 2 — API provider
# ---------------------------------------------------------------------------
step_2_provider() {
    prompt_menu "Step 2 of 9 — API provider" \
        "Which model provider's API key will the agents use?" \
        api_provider \
        "anthropic" "Anthropic (Claude) — recommended default" \
        "openai"    "OpenAI (GPT / Codex)" \
        "custom"    "Custom OpenAI-compatible endpoint"
    return $?
}

# ---------------------------------------------------------------------------
# Step 3 — API key
# ---------------------------------------------------------------------------
step_3_api_key() {
    while true; do
        prompt_password "Step 3 of 9 — API key" \
            "Paste your ${WIZARD[api_provider]} API key.\n\nIt's never written to disk in plaintext — installer seeds it directly into Infisical." \
            api_key
        local rc=$?
        [ $rc -eq $STEP_OK ] || return $rc

        local err
        err="$(validate_api_key_format "${WIZARD[api_provider]}" "${WIZARD[api_key]}" 2>&1)" && return $STEP_OK
        err_msg "API key format invalid.\n\n${err}"
    done
}

# ---------------------------------------------------------------------------
# Step 4 — Model per agent
# ---------------------------------------------------------------------------
step_4_models() {
    # Pre-fill defaults the first time through.
    : "${WIZARD[model_tl]:=$DEFAULT_MODEL_TL}"
    : "${WIZARD[model_dev]:=$DEFAULT_MODEL_DEV}"
    : "${WIZARD[model_qa]:=$DEFAULT_MODEL_QA}"

    local out_file
    out_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$out_file'" RETURN

    local rc=0
    dialog --backtitle "dannemora installer" \
        --title "Step 4 of 9 — Models per agent" \
        --cancel-label "Back" \
        --form "Override only if you have a strong reason. Defaults are tuned." \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 3 \
        "Tech Lead model:" 1 1 "${WIZARD[model_tl]}"  1 22 40 0 \
        "Developer model:" 2 1 "${WIZARD[model_dev]}" 2 22 40 0 \
        "QA model:"        3 1 "${WIZARD[model_qa]}"  3 22 40 0 \
        2>"$out_file" || rc=$?

    case $rc in
        0) ;;
        1) return $STEP_BACK ;;
        255) return $STEP_BACK ;;
        *) return $STEP_CANCEL ;;
    esac

    # dialog --form writes one value per line.
    local lines
    mapfile -t lines <"$out_file"
    WIZARD[model_tl]="${lines[0]:-$DEFAULT_MODEL_TL}"
    WIZARD[model_dev]="${lines[1]:-$DEFAULT_MODEL_DEV}"
    WIZARD[model_qa]="${lines[2]:-$DEFAULT_MODEL_QA}"
    return $STEP_OK
}

# ---------------------------------------------------------------------------
# Step 5 — Ticket system + conditional credentials
# ---------------------------------------------------------------------------
step_5_ticket_system() {
    prompt_menu "Step 5 of 9 — Ticket system" \
        "Where do your tickets live?" \
        ticket_system \
        "linear" "Linear" \
        "jira"   "Jira" \
        "github" "GitHub Issues" \
        "none"   "None — start without a ticket integration"
    local rc=$?
    [ $rc -eq $STEP_OK ] || return $rc

    case "${WIZARD[ticket_system]}" in
        linear)
            prompt_password "Step 5 of 9 — Linear API key" \
                "Paste your Linear API key.\n\nGenerate at https://linear.app/settings/api" \
                linear_api_key
            return $?
            ;;
        jira)
            prompt_input "Step 5 of 9 — Jira URL" \
                "Your Jira base URL (e.g. https://acme.atlassian.net)" \
                jira_url
            local r1=$?
            [ $r1 -eq $STEP_OK ] || return $r1

            prompt_input "Step 5 of 9 — Jira email" \
                "Email associated with your Jira account" \
                jira_email
            local r2=$?
            [ $r2 -eq $STEP_OK ] || return $r2

            prompt_password "Step 5 of 9 — Jira API token" \
                "Generate at https://id.atlassian.com/manage-profile/security/api-tokens" \
                jira_api_token
            return $?
            ;;
        github|none)
            # No additional creds: github uses step 8's PAT; none = no auth.
            return $STEP_OK
            ;;
    esac
    return $STEP_OK
}

# ---------------------------------------------------------------------------
# Step 6 — Chat channel
# ---------------------------------------------------------------------------
step_6_chat() {
    prompt_menu "Step 6 of 9 — Chat channel" \
        "How should you talk to the agents day-to-day?" \
        notification_channel \
        "dashboard" "Browser dashboard at http://{server-ip}/dashboard (default)" \
        "telegram"  "Telegram (requires 3 bot tokens — one per agent)"
    local rc=$?
    [ $rc -eq $STEP_OK ] || return $rc

    if [ "${WIZARD[notification_channel]}" = "telegram" ]; then
        prompt_password "Step 6 of 9 — Tech Lead bot token" \
            "Paste the Telegram bot token for the Tech Lead.\n\nCreate via @BotFather; treat as a password." \
            telegram_bot_token_tl
        local r1=$?; [ $r1 -eq $STEP_OK ] || return $r1

        prompt_password "Step 6 of 9 — Developer bot token" \
            "Paste the Telegram bot token for the Developer." \
            telegram_bot_token_dev
        local r2=$?; [ $r2 -eq $STEP_OK ] || return $r2

        prompt_password "Step 6 of 9 — QA bot token" \
            "Paste the Telegram bot token for the QA agent." \
            telegram_bot_token_qa
        return $?
    fi
    return $STEP_OK
}

# ---------------------------------------------------------------------------
# Step 7 — Target repository
# ---------------------------------------------------------------------------
step_7_repo() {
    while true; do
        prompt_input "Step 7 of 9 — Target repository" \
            "GitHub URL of the repo your agents will work on.\n\nExample: https://github.com/acme/my-product" \
            target_repo_url
        local rc=$?
        [ $rc -eq $STEP_OK ] || return $rc
        # Re-validation against GH happens in step 8 (after we have a token).
        # Here we just sanity-check format.
        if [[ "${WIZARD[target_repo_url]}" =~ github\.com[/:][^/]+/[^/.]+(\.git)?/?$ ]]; then
            return $STEP_OK
        fi
        err_msg "Doesn't look like a GitHub repo URL.\n\nExpected: https://github.com/owner/repo"
    done
}

# ---------------------------------------------------------------------------
# Step 8 — GitHub token (validates scope + repo access in one screen)
# ---------------------------------------------------------------------------
step_8_github_token() {
    while true; do
        prompt_password "Step 8 of 9 — GitHub token" \
            "Personal access token for the agents.\n\nClassic token: needs 'repo' + 'workflow' scopes.\nFine-grained: needs Contents RW + Actions RW + Metadata R on the target repo." \
            github_token
        local rc=$?
        [ $rc -eq $STEP_OK ] || return $rc

        local err
        err="$(validate_github_token "${WIZARD[github_token]}" 2>&1)" || {
            err_msg "GitHub token validation failed.\n\n${err}"
            continue
        }
        err="$(validate_github_repo_access "${WIZARD[target_repo_url]}" "${WIZARD[github_token]}" 2>&1)" || {
            err_msg "Repo access check failed.\n\n${err}\n\nThe token doesn't appear to have access to the repo from step 7."
            continue
        }
        return $STEP_OK
    done
}

# ---------------------------------------------------------------------------
# Step 9 — Customer info
# ---------------------------------------------------------------------------
step_9_customer() {
    prompt_input "Step 9 of 9 — Your name" \
        "Your name (for the workspace USER.md)." \
        customer_name
    local r1=$?; [ $r1 -eq $STEP_OK ] || return $r1

    while true; do
        prompt_input "Step 9 of 9 — Your email" \
            "Email associated with your dannemora license." \
            customer_email
        local r2=$?; [ $r2 -eq $STEP_OK ] || return $r2
        if validate_email_format "${WIZARD[customer_email]}"; then
            return $STEP_OK
        fi
        err_msg "Email format invalid."
    done
}

# ---------------------------------------------------------------------------
# Final review screen
# ---------------------------------------------------------------------------
show_review() {
    local lines=()
    lines+=("License: ${WIZARD[license_key]:0:8}…")
    lines+=("API provider: ${WIZARD[api_provider]}")
    lines+=("Models:")
    lines+=("  Tech Lead: ${WIZARD[model_tl]}")
    lines+=("  Developer: ${WIZARD[model_dev]}")
    lines+=("  QA:        ${WIZARD[model_qa]}")
    lines+=("Ticket system: ${WIZARD[ticket_system]}")
    lines+=("Chat channel:  ${WIZARD[notification_channel]}")
    lines+=("Target repo:   ${WIZARD[target_repo_url]}")
    lines+=("Customer:      ${WIZARD[customer_name]} <${WIZARD[customer_email]}>")

    local body
    body="$(printf '%s\n' "${lines[@]}")"
    body+=$'\n\nProceed with install?\n(Yes = continue to install phase. No = back to step 9.)'

    dialog --backtitle "dannemora installer" \
        --title "Review your answers" \
        --yes-label "Install" \
        --no-label "Back" \
        --yesno "$body" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    return $?
}

# ---------------------------------------------------------------------------
# Commit phase: write the wizard state to a temp JSON file ONLY at the
# very end. Earlier commits would defeat the trap-on-cancel guarantee.
# ---------------------------------------------------------------------------
commit_wizard_state() {
    WIZARD_TEMP_FILE="$(mktemp -t dannemora-wizard.XXXXXXXX.json)"
    chmod 600 "$WIZARD_TEMP_FILE"

    # Write a deterministic JSON object. We intentionally avoid jq here
    # so the script has the same dep set as the rest of the installer.
    local k
    {
        printf '{\n'
        local first=1
        for k in "${!WIZARD[@]}"; do
            local v="${WIZARD[$k]}"
            # Naive JSON-escape: backslash, double-quote, newlines, tabs.
            v="${v//\\/\\\\}"
            v="${v//\"/\\\"}"
            v="${v//$'\n'/\\n}"
            v="${v//$'\t'/\\t}"
            if [ $first -eq 1 ]; then first=0; else printf ',\n'; fi
            printf '  "%s": "%s"' "$k" "$v"
        done
        printf '\n}\n'
    } >"$WIZARD_TEMP_FILE"
}

# ---------------------------------------------------------------------------
# Main wizard driver — state machine over the 9 steps with back-nav.
# ---------------------------------------------------------------------------
run_wizard() {
    # AF-159: step_0_prerequisites runs BEFORE the numbered steps. It
    # has no back-nav (nothing comes before it) and no STEP_CANCEL
    # path — No simply prints the prereq list and exits 0. So we call
    # it directly here rather than putting it in the steps[] state
    # machine, which would otherwise force us to invent special-case
    # behaviour for STEP_BACK at index -1.
    step_0_prerequisites
    local steps=(
        step_1_license
        step_2_provider
        step_3_api_key
        step_4_models
        step_5_ticket_system
        step_6_chat
        step_7_repo
        step_8_github_token
        step_9_customer
    )
    local i=0
    local n=${#steps[@]}
    while [ "$i" -lt "$n" ]; do
        local fn="${steps[$i]}"
        $fn
        local rc=$?
        # shellcheck disable=SC2254  # constants are safe to use unquoted in case
        case $rc in
            "$STEP_OK")
                i=$((i + 1))
                ;;
            "$STEP_BACK")
                if [ "$i" -eq 0 ]; then
                    # Already at step 1 — confirm cancel.
                    if dialog --backtitle "dannemora installer" \
                        --title "Cancel installer?" \
                        --yesno "Cancel and exit?" 7 50; then
                        return "$STEP_CANCEL"
                    fi
                else
                    i=$((i - 1))
                fi
                ;;
            "$STEP_CANCEL")
                return "$STEP_CANCEL"
                ;;
        esac
    done
    # Review loop: if user picks "Back" on review, drop into step 9 again.
    while true; do
        if show_review; then
            return $STEP_OK
        fi
        # User said Back → re-run step 9 then loop.
        step_9_customer || return $?
    done
}

# ===========================================================================
# AF-133 — INSTALL-PHASE ROLLBACK MACHINERY
# ===========================================================================
#
# The wizard (above) is in-memory and trivially cancellable. The install
# phase (below, future) actually mutates the host: builds images, starts
# containers, writes config files, drops nginx vhosts, etc. If any of those
# steps fails partway through, the customer's machine ends up in a
# half-installed state. AF-133 fixes that.
#
# How it works
# ------------
#   1. enable_install_rollback   — called once at the start of the install
#                                   phase. Initializes the state ledger and
#                                   installs the ERR/INT/TERM trap.
#   2. register_step "name" "a,b" — called by every install-phase step at
#                                   its top. Records the step name and a
#                                   comma-separated list of artifacts the
#                                   step is about to create. Status starts
#                                   as "started".
#   3. mark_step_ok               — called at the bottom of a successful
#                                   step. Flips status to "ok".
#                                   (mark_step_failed is also available,
#                                   though most failures come through the
#                                   ERR trap and don't need an explicit call.)
#   4. dannemora_rollback         — fired by the trap (or manually). Walks
#                                   the ledger in reverse, undoing artifacts
#                                   from completed and in-flight steps. Each
#                                   undo is idempotent (checks existence
#                                   first), so re-running the trap on a
#                                   partial rollback is safe.
#
# Artifact format
# ---------------
# Each step's artifact list is a comma-separated string of "type:value"
# tuples. Supported types:
#   file:/abs/path                  — unlinked on rollback
#   dir:/abs/path                   — rm -rf on rollback (allowlist-gated)
#   container:NAME                  — docker stop && docker rm
#   image:REF                       — docker rmi
#   network:NAME                    — no-op (left for infra rollback)
#   systemd:UNIT                    — stop + disable + remove unit file
#   nginx:dannemora-NAME            — remove vhost from sites-{enabled,available} + reload
#   infisical:SECRET                — NOT undone; logged as skipped
#   process:NAME                    — SIGTERM (then SIGKILL after 2s) any
#                                     process whose command line matches NAME
#                                     (pgrep -f). Used for AF-134's host-side
#                                     metrics API.
#
# Anything outside that allowlist is logged and skipped — never silently
# rm -rf'd. The same goes for paths: dir: targets must match an explicit
# safe-prefix list. "never rm -rf $HOME" is enforced by
# _rollback_path_is_safe() below.
# ---------------------------------------------------------------------------

# Module-scoped state. INSTALL_ROLLBACK_ARMED gates the trap so that
# wizard-only invocations don't accidentally rollback nothing.
# INSTALL_ROLLBACK_ARMED is informational — set to 1 by enable_install_rollback
# so external callers / tests can introspect whether the trap is armed.
# shellcheck disable=SC2034
INSTALL_ROLLBACK_ARMED=0
INSTALL_ROLLBACK_IN_PROGRESS=0
INSTALL_LAST_ERROR=""

# Allowlist of path prefixes the rollback is permitted to delete (file or
# dir). Customer $HOME, /, /etc (other than /etc/dannemora), /usr, /var
# (other than /var/log/dannemora-* and /var/lib/dannemora) are NEVER touched
# even if a corrupted state file claims they were our artifact.
readonly _DANNEMORA_SAFE_PREFIXES=(
    "/tmp/dannemora-"
    "/tmp/dannemora."
    "/var/lib/dannemora"
    "/var/log/dannemora-"
    "/etc/dannemora"
    "/opt/dannemora"
)

# Allowlist for nginx vhost names — must start with "dannemora-" and contain
# only [a-z0-9-]. Matched against both sites-available and sites-enabled.
readonly _DANNEMORA_NGINX_PREFIX="dannemora-"

# JSON-escape a string (matches commit_wizard_state's escaping). Used to
# serialize step names and artifact lists into the state file without jq.
_json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\t'/\\t}"
    printf '%s' "$v"
}

# Initialize a fresh state ledger. Idempotent within a run: a second call
# truncates the file, which is what you want if rollback is re-armed by a
# higher-level retry.
_init_state_file() {
    : >"$DANNEMORA_INSTALL_STATE_FILE"
    chmod 600 "$DANNEMORA_INSTALL_STATE_FILE"
    # Write the array open/close on their own lines so _append_step_row
    # can splice new entries before the closing bracket using a simple
    # line-by-line rewrite (no jq).
    printf '{\n  "version": 1,\n  "steps": [\n  ]\n}\n' >"$DANNEMORA_INSTALL_STATE_FILE"
}

# Append a step row. Does not use jq — we maintain the JSON by hand. The
# file always ends with `]\n}\n`; we splice the new entry in just before
# the closing bracket. For the very first entry there is no leading comma.
_append_step_row() {
    local step="$1" status="$2" started="$3" completed="$4" artifacts_csv="$5"
    local tmp
    tmp="$(mktemp -t dannemora-state.XXXXXXXX.json)" || return 1
    chmod 600 "$tmp"

    # Build the artifacts JSON array from the CSV. Empty CSV → [].
    local artifacts_json="[]"
    if [ -n "$artifacts_csv" ]; then
        local IFS=','
        # shellcheck disable=SC2206  # word-split is exactly what we want here
        local parts=( $artifacts_csv )
        unset IFS
        artifacts_json="["
        local first=1 a esc
        for a in "${parts[@]}"; do
            # Trim leading/trailing whitespace.
            a="${a#"${a%%[![:space:]]*}"}"
            a="${a%"${a##*[![:space:]]}"}"
            [ -z "$a" ] && continue
            esc="$(_json_escape "$a")"
            if [ $first -eq 1 ]; then first=0; else artifacts_json+=", "; fi
            artifacts_json+="\"${esc}\""
        done
        artifacts_json+="]"
    fi

    local step_esc status_esc
    step_esc="$(_json_escape "$step")"
    status_esc="$(_json_escape "$status")"

    # Detect whether the steps array already has entries so we know whether
    # to prefix the new row with a comma. We look for any line containing
    # `"step":` (only step rows have it).
    local has_existing=0
    if grep -q '"step":' "$DANNEMORA_INSTALL_STATE_FILE"; then
        has_existing=1
    fi

    # Rewrite by reading line-by-line. The state file is small (<= one entry
    # per install step, ~20 max) so this is cheap.
    {
        local line emitted=0
        while IFS= read -r line; do
            if [ $emitted -eq 0 ] && [[ "$line" =~ ^[[:space:]]*\]$ ]]; then
                if [ $has_existing -eq 1 ]; then
                    printf ',\n'
                fi
                printf '    {"step": "%s", "status": "%s", "started_at": "%s", "completed_at": "%s", "artifacts": %s}\n' \
                    "$step_esc" "$status_esc" "$started" "$completed" "$artifacts_json"
                printf '%s\n' "$line"
                emitted=1
            else
                printf '%s\n' "$line"
            fi
        done <"$DANNEMORA_INSTALL_STATE_FILE"
    } >"$tmp"
    mv "$tmp" "$DANNEMORA_INSTALL_STATE_FILE"
    chmod 600 "$DANNEMORA_INSTALL_STATE_FILE"
}

# Update the most-recently-appended step's status + completed_at. We rewrite
# the last `"status": "..."` and `"completed_at": "..."` fields to keep this
# jq-free.
_update_last_step() {
    local new_status="$1" completed="$2"
    local tmp
    tmp="$(mktemp -t dannemora-state.XXXXXXXX.json)" || return 1
    chmod 600 "$tmp"

    # Read all lines, find the last one that looks like a step row, rewrite
    # its status + completed_at, leave everything else untouched.
    local -a lines=()
    local line
    while IFS= read -r line; do
        lines+=("$line")
    done <"$DANNEMORA_INSTALL_STATE_FILE"

    local i last_idx=-1
    for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
        if [[ "${lines[$i]}" =~ \"step\":[[:space:]]*\" ]]; then
            last_idx=$i
            break
        fi
    done
    if [ $last_idx -lt 0 ]; then
        rm -f "$tmp"
        return 1
    fi

    # Rewrite status and completed_at on that line.
    local row="${lines[$last_idx]}"
    row="$(printf '%s' "$row" | sed -E "s/(\"status\": \")[^\"]*(\")/\\1${new_status}\\2/")"
    row="$(printf '%s' "$row" | sed -E "s/(\"completed_at\": \")[^\"]*(\")/\\1${completed}\\2/")"
    lines[last_idx]="$row"

    printf '%s\n' "${lines[@]}" >"$tmp"
    mv "$tmp" "$DANNEMORA_INSTALL_STATE_FILE"
    chmod 600 "$DANNEMORA_INSTALL_STATE_FILE"
}

# ISO-8601 UTC timestamp; matches what most operators expect to see in logs.
_iso_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Public API: arm the rollback trap and create the state ledger. Call this
# at the top of the install phase, *after* the wizard has committed.
enable_install_rollback() {
    _init_state_file
    # shellcheck disable=SC2034  # informational flag for tests / introspection
    INSTALL_ROLLBACK_ARMED=1
    # Capture the failing command's stderr-ish info for the failure UX.
    trap '_install_rollback_trap ERR $? "$BASH_COMMAND" "${BASH_LINENO[0]:-?}"' ERR
    trap '_install_rollback_trap INT 130 "interrupted by user (SIGINT)" "-"' INT
    trap '_install_rollback_trap TERM 143 "terminated (SIGTERM)" "-"' TERM
}

# Public API: register a step at its top with a comma-separated artifact
# list. One line at the top of each install-phase function:
#   register_step "build_image" "image:dannemora:local"
register_step() {
    local name="$1" artifacts="${2:-}"
    if [ -z "$name" ]; then
        echo "[dannemora] register_step: missing step name" >&2
        return 1
    fi
    local started
    started="$(_iso_now)"
    _append_step_row "$name" "started" "$started" "" "$artifacts"
}

# Public API: flip the most recent step from "started" to "ok".
mark_step_ok() {
    local completed
    completed="$(_iso_now)"
    _update_last_step "ok" "$completed"
}

# Public API: flip the most recent step from "started" to "failed". Useful
# if a step catches its own error and wants to record the failure before
# re-raising.
mark_step_failed() {
    local completed
    completed="$(_iso_now)"
    _update_last_step "failed" "$completed"
    INSTALL_LAST_ERROR="${1:-${INSTALL_LAST_ERROR}}"
}

# --- Safety guards --------------------------------------------------------

# Returns 0 if a path is on our allowlist of safe prefixes, 1 otherwise.
# Used to gate every filesystem deletion in the rollback path.
_rollback_path_is_safe() {
    local p="$1"
    # Reject empty, root, single-char, or paths containing traversal.
    if [ -z "$p" ] || [ "$p" = "/" ] || [ "${#p}" -lt 8 ]; then
        return 1
    fi
    case "$p" in
        *..*|*$'\n'*|*$'\t'*) return 1 ;;
        "$HOME"|"$HOME/") return 1 ;;
    esac
    local prefix
    for prefix in "${_DANNEMORA_SAFE_PREFIXES[@]}"; do
        case "$p" in
            "$prefix"*) return 0 ;;
        esac
    done
    return 1
}

# --- Per-artifact undoers -------------------------------------------------

_undo_file() {
    local p="$1"
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
        echo "  - file already gone: $p"
        return 0
    fi
    if ! _rollback_path_is_safe "$p"; then
        echo "  ! refusing to unlink (outside safe prefixes): $p" >&2
        return 0
    fi
    if rm -f -- "$p"; then
        echo "  - removed file: $p"
    else
        echo "  ! failed to remove file: $p" >&2
    fi
}

_undo_dir() {
    local p="$1"
    if [ ! -d "$p" ]; then
        echo "  - dir already gone: $p"
        return 0
    fi
    if ! _rollback_path_is_safe "$p"; then
        echo "  ! refusing to remove directory (outside safe prefixes): $p" >&2
        return 0
    fi
    # Final paranoid sanity check: never recurse-delete root or $HOME.
    case "$p" in
        "/"|"$HOME"|"$HOME/") echo "  ! refusing to rm -rf $p" >&2; return 0 ;;
    esac
    if rm -rf -- "$p"; then
        echo "  - removed dir:  $p"
    else
        echo "  ! failed to remove dir: $p" >&2
    fi
}

_undo_container() {
    local name="$1"
    if ! command -v docker >/dev/null 2>&1; then
        echo "  ! docker not available; cannot stop container $name" >&2
        return 0
    fi
    if docker inspect "$name" >/dev/null 2>&1; then
        docker stop "$name" >/dev/null 2>&1 || true
        if docker rm "$name" >/dev/null 2>&1; then
            echo "  - removed container: $name"
        else
            echo "  ! failed to remove container: $name" >&2
        fi
    else
        echo "  - container already gone: $name"
    fi
}

_undo_image() {
    local ref="$1"
    if ! command -v docker >/dev/null 2>&1; then
        echo "  ! docker not available; cannot remove image $ref" >&2
        return 0
    fi
    if docker image inspect "$ref" >/dev/null 2>&1; then
        if docker rmi "$ref" >/dev/null 2>&1; then
            echo "  - removed image: $ref"
        else
            echo "  ! failed to remove image (in use?): $ref" >&2
        fi
    else
        echo "  - image already gone: $ref"
    fi
}

_undo_network() {
    # Per spec: network deletion is handled by infra rollback if it's the
    # last container leaving. We just log and move on.
    local name="$1"
    echo "  - network not removed (handled by infra rollback): $name"
}

_undo_systemd() {
    local unit="$1"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "  ! systemctl not available; cannot remove $unit" >&2
        return 0
    fi
    # Unit name allowlist: must start with "dannemora" to avoid stopping
    # unrelated services if state is corrupted.
    case "$unit" in
        dannemora*) ;;
        *) echo "  ! refusing to touch non-dannemora unit: $unit" >&2; return 0 ;;
    esac
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    local f
    for f in "/etc/systemd/system/${unit}.service" "/etc/systemd/system/${unit}"; do
        if [ -f "$f" ]; then
            rm -f -- "$f" && echo "  - removed unit file: $f"
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "  - systemd unit cleaned: $unit"
}

_undo_nginx() {
    local name="$1"
    case "$name" in
        "$_DANNEMORA_NGINX_PREFIX"*) ;;
        *) echo "  ! refusing to touch non-dannemora nginx vhost: $name" >&2; return 0 ;;
    esac
    local removed=0
    local f
    for f in "/etc/nginx/sites-enabled/${name}" "/etc/nginx/sites-available/${name}"; do
        if [ -f "$f" ] || [ -L "$f" ]; then
            rm -f -- "$f" && removed=1
        fi
    done
    if [ $removed -eq 1 ]; then
        if command -v nginx >/dev/null 2>&1; then
            nginx -s reload >/dev/null 2>&1 || true
        fi
        echo "  - removed nginx vhost: $name"
    else
        echo "  - nginx vhost already gone: $name"
    fi
}

_undo_infisical() {
    local secret="$1"
    echo "  - skipped Infisical secret (data-loss risk): $secret"
    echo "    → if needed, remove it manually from your Infisical project."
}

# Stop a host-side background process by name (matched against the full
# command line via pgrep -f). Used for AF-134's host-side metrics API:
# we don't track a PID file, so rollback walks pgrep results and signals
# them. SIGTERM first; if the process survives 2s, SIGKILL.
_undo_process() {
    local name="$1"
    if ! command -v pgrep >/dev/null 2>&1; then
        echo "  ! pgrep not available; cannot stop process $name" >&2
        return 0
    fi
    local pids
    pids="$(pgrep -f -- "$name" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        echo "  - process already gone: $name"
        return 0
    fi
    # SIGTERM each PID. We avoid `kill $pids` to keep word-splitting
    # explicit and shellcheck-clean.
    local pid
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    # Anything still alive after the grace period gets SIGKILL.
    pids="$(pgrep -f -- "$name" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -KILL "$pid" 2>/dev/null || true
        done
        echo "  - killed process (SIGKILL fallback): $name"
    else
        echo "  - stopped process: $name"
    fi
}

# Dispatch a single "type:value" artifact to the appropriate undoer.
_undo_artifact() {
    local artifact="$1"
    local type="${artifact%%:*}"
    local val="${artifact#*:}"
    if [ "$type" = "$artifact" ] || [ -z "$type" ]; then
        echo "  ! malformed artifact (expected type:value): $artifact" >&2
        return 0
    fi
    case "$type" in
        file)       _undo_file "$val" ;;
        dir)        _undo_dir "$val" ;;
        container)  _undo_container "$val" ;;
        image)      _undo_image "$val" ;;
        network)    _undo_network "$val" ;;
        systemd)    _undo_systemd "$val" ;;
        nginx)      _undo_nginx "$val" ;;
        infisical)  _undo_infisical "$val" ;;
        process)    _undo_process "$val" ;;
        *)
            echo "  ! unknown artifact type: $type (value=$val)" >&2
            ;;
    esac
}

# Read steps in reverse order from the state file. We want every step that
# got at least as far as "started" — even partial steps may have created
# artifacts. This is a deliberately tolerant parser: it pulls step name and
# artifact array from each `"step": "...", ... "artifacts": [...]` row.
_read_steps_reverse() {
    awk '
        /"step":/ {
            step=""; status=""; arts="";
            n=split($0, _, "\"step\":");
            if (n>=2) { s=_[2]; sub(/^[ \t]*"/, "", s); sub(/".*/, "", s); step=s }
            n=split($0, _, "\"status\":");
            if (n>=2) { s=_[2]; sub(/^[ \t]*"/, "", s); sub(/".*/, "", s); status=s }
            n=split($0, _, "\"artifacts\":");
            if (n>=2) {
                a=_[2];
                sub(/^[ \t]*\[/, "", a);
                sub(/\][^]]*$/, "", a);
                # Strip surrounding quotes from each element, join with comma.
                gsub(/"/, "", a);
                gsub(/[ \t]+/, " ", a);
                arts=a;
            }
            print step "\t" status "\t" arts;
        }
    ' "$DANNEMORA_INSTALL_STATE_FILE" | tac
}

# Mark the whole state file as rolled_back. Used so a subsequent rollback
# call (idempotency test) still finds the file with the right marker.
_mark_state_rolled_back() {
    if [ ! -f "$DANNEMORA_INSTALL_STATE_FILE" ]; then
        return 0
    fi
    # Append a top-level field. Cheaper than reparsing: just rewrite the
    # closing brace.
    local tmp
    tmp="$(mktemp -t dannemora-state.XXXXXXXX.json)" || return 1
    chmod 600 "$tmp"
    awk -v ts="$(_iso_now)" '
        /^\}[[:space:]]*$/ && !done {
            print "  ,\"rollback\": {\"status\": \"rolled_back\", \"at\": \"" ts "\"}";
            print $0;
            done=1; next;
        }
        { print }
    ' "$DANNEMORA_INSTALL_STATE_FILE" >"$tmp"
    mv "$tmp" "$DANNEMORA_INSTALL_STATE_FILE"
    chmod 600 "$DANNEMORA_INSTALL_STATE_FILE"
}

# Public API: walk the ledger in reverse and undo every artifact. Idempotent.
dannemora_rollback() {
    if [ "${INSTALL_ROLLBACK_IN_PROGRESS}" = "1" ]; then
        # Re-entrant call (e.g., trap fired during rollback). Bail.
        return 0
    fi
    INSTALL_ROLLBACK_IN_PROGRESS=1

    if [ ! -f "$DANNEMORA_INSTALL_STATE_FILE" ]; then
        echo "[dannemora] rollback: no state file at ${DANNEMORA_INSTALL_STATE_FILE} — nothing to undo."
        INSTALL_ROLLBACK_IN_PROGRESS=0
        return 0
    fi

    echo ""
    echo "=============================================================="
    echo "[dannemora] rolling back install — undoing completed steps..."
    echo "=============================================================="

    local rolled_back_count=0
    local -a rolled_back_names=()

    # Read each step row in reverse.
    while IFS=$'\t' read -r step status arts; do
        [ -z "$step" ] && continue
        # Only undo steps that started ("started" or "ok" or "failed");
        # an entry with status "rolled_back" is already done.
        case "$status" in
            ok|started|failed) ;;
            rolled_back|"") continue ;;
            *) ;;
        esac
        echo ""
        echo "[$((rolled_back_count + 1))] step: ${step}  (status: ${status})"
        if [ -z "$arts" ]; then
            echo "  - no artifacts recorded"
        else
            local IFS_save="$IFS"
            IFS=','
            # shellcheck disable=SC2206
            local parts=( $arts )
            IFS="$IFS_save"
            local a
            for a in "${parts[@]}"; do
                a="${a#"${a%%[![:space:]]*}"}"
                a="${a%"${a##*[![:space:]]}"}"
                [ -z "$a" ] && continue
                _undo_artifact "$a"
            done
        fi
        rolled_back_count=$((rolled_back_count + 1))
        rolled_back_names+=("$step")
    done < <(_read_steps_reverse)

    _mark_state_rolled_back

    echo ""
    echo "=============================================================="
    echo "[dannemora] rollback complete"
    echo "=============================================================="
    echo "Rolled back ${rolled_back_count} step(s):"
    local i=1
    local n
    for n in "${rolled_back_names[@]}"; do
        echo "  ${i}. ${n}"
        i=$((i + 1))
    done
    echo ""
    echo "Kept (for your records):"
    echo "  - install log:        ${DANNEMORA_INSTALL_LOG}  (if your run was logged)"
    echo "  - rollback ledger:    ${DANNEMORA_INSTALL_STATE_FILE}"
    if [ -n "${INSTALL_LAST_ERROR}" ]; then
        echo ""
        echo "Original error:"
        echo "  ${INSTALL_LAST_ERROR}"
    fi
    echo ""
    echo "To file a bug report, please share:"
    echo "  cat ${DANNEMORA_INSTALL_STATE_FILE}"
    echo ""
    echo "Or with one command:"
    echo "  curl -F 'state=@${DANNEMORA_INSTALL_STATE_FILE}' \\"
    echo "       -F 'log=@${DANNEMORA_INSTALL_LOG}' \\"
    echo "       https://api.dannemora.ai/v1/install/bug-report"
    echo ""

    INSTALL_ROLLBACK_IN_PROGRESS=0
    return 0
}

# Internal: trap handler. Captures the failure context, then either runs
# the rollback or, if DANNEMORA_KEEP_ON_FAILURE=1, dumps a debug summary
# and tells the operator how to clean up by hand.
_install_rollback_trap() {
    local kind="$1" rc="$2" cmd="$3" lineno="$4"
    # Disarm before doing any work to avoid recursion if our handler errors.
    trap - ERR INT TERM

    INSTALL_LAST_ERROR="${kind} (rc=${rc}) at line ${lineno}: ${cmd}"

    if [ "${DANNEMORA_KEEP_ON_FAILURE:-0}" = "1" ]; then
        _write_debug_log
        echo ""
        echo "=============================================================="
        echo "[dannemora] DANNEMORA_KEEP_ON_FAILURE=1 — rollback skipped"
        echo "=============================================================="
        echo "Failure: ${INSTALL_LAST_ERROR}"
        echo ""
        echo "Debug summary written to:"
        echo "  ${DANNEMORA_INSTALL_DEBUG_LOG}"
        echo "State ledger preserved at:"
        echo "  ${DANNEMORA_INSTALL_STATE_FILE}"
        echo ""
        echo "Manual cleanup once you've inspected things:"
        echo "  unset DANNEMORA_KEEP_ON_FAILURE"
        echo "  bash $0 --rollback   # (or rerun the installer; it'll detect stale state and offer cleanup)"
        exit "$rc"
    fi

    dannemora_rollback || true
    exit "$rc"
}

# Internal: write a human-readable debug log when keep-on-failure is set.
_write_debug_log() {
    {
        echo "# dannemora install debug log"
        echo "# generated: $(_iso_now)"
        echo "# error:     ${INSTALL_LAST_ERROR}"
        echo ""
        echo "## Environment"
        echo "DANNEMORA_OFFLINE=${DANNEMORA_OFFLINE}"
        echo "DANNEMORA_KEEP_ON_FAILURE=${DANNEMORA_KEEP_ON_FAILURE}"
        echo "DANNEMORA_INSTALL_STATE_FILE=${DANNEMORA_INSTALL_STATE_FILE}"
        echo ""
        echo "## Step ledger"
        if [ -f "$DANNEMORA_INSTALL_STATE_FILE" ]; then
            cat "$DANNEMORA_INSTALL_STATE_FILE"
        else
            echo "(no state file)"
        fi
        echo ""
        echo "## Docker state (best-effort)"
        if command -v docker >/dev/null 2>&1; then
            docker ps -a --filter name=dannemora 2>&1 || true
            echo ""
            docker images dannemora 2>&1 || true
        else
            echo "(docker not available)"
        fi
    } >"$DANNEMORA_INSTALL_DEBUG_LOG" 2>&1
    chmod 600 "$DANNEMORA_INSTALL_DEBUG_LOG" 2>/dev/null || true
}

# ===========================================================================
# end AF-133 rollback module
# ===========================================================================

# ---------------------------------------------------------------------------
# Step 11 — Config writer (AF-125)
#
# Sourced lazily so the wizard sourcing tests don't pull in the writer.
# The writer is a stand-alone script that defines write_all_configs.
# ---------------------------------------------------------------------------
_dannemora_install_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DANNEMORA_CONFIG_WRITER="${DANNEMORA_CONFIG_WRITER:-${_dannemora_install_dir}/installer/config_writer.sh}"
DANNEMORA_INFISICAL_SEED="${DANNEMORA_INFISICAL_SEED:-${_dannemora_install_dir}/installer/infisical_seed.sh}"

run_step_11_write_configs() {
    if [ ! -f "$DANNEMORA_CONFIG_WRITER" ]; then
        die "config writer not found at: $DANNEMORA_CONFIG_WRITER"
    fi
    # shellcheck disable=SC1090
    source "$DANNEMORA_CONFIG_WRITER"
    write_all_configs "${WIZARD_TEMP_FILE}" "${HOME}"
}

# ---------------------------------------------------------------------------
# Step 12 — Infrastructure startup (AF-126)
#
# Invokes the already-placed ~/dannemora-infra/setup.sh, which:
#   * generates per-host secrets into ~/dannemora-infra/.env (idempotent)
#   * creates the dannemora-net Docker network
#   * brings up the shared infra stack (redis / mongo / minio / postgres /
#     infisical) via docker compose
#
# The setup.sh template itself is shipped by AF-125 and placed at install
# time by run_step_11_write_configs, so this step's job is purely to
# invoke it and surface the result.
# ---------------------------------------------------------------------------
DANNEMORA_INFRA_DIR="${DANNEMORA_INFRA_DIR:-${HOME}/dannemora-infra}"

run_step_12_start_infra() {
    # Rollback artifacts: the .env file (containing freshly-generated
    # passwords) and the dannemora-net network. The infra containers
    # themselves are owned by the compose stack, which the operator can
    # tear down via `docker compose down` in the same directory.
    register_step "step_12_infra" "file:${DANNEMORA_INFRA_DIR}/.env,network:dannemora-net"

    require_cmd docker

    local setup_script="${DANNEMORA_INFRA_DIR}/setup.sh"
    if [ ! -x "$setup_script" ]; then
        if [ -f "$setup_script" ]; then
            chmod +x "$setup_script"
        else
            die "infrastructure setup script not found at: $setup_script (Step 11 should have placed it)"
        fi
    fi

    echo "[dannemora] Step 12 — starting shared infrastructure..."
    # The setup script is verbose by design; its output is the user-facing
    # progress (Starting Redis... OK, etc.) per the AF-126 acceptance
    # criteria.
    if ! "$setup_script"; then
        die "infrastructure setup failed (see output above)"
    fi

    mark_step_ok
    echo "[dannemora] Step 12 done."
}

# ---------------------------------------------------------------------------
# Step 13 — Agent compose stacks (AF-126)
#
# For each role in (techlead, developer, qa):
#   1. cd into ~/openclaw-${role}/ and `docker compose up -d`
#   2. Poll `docker inspect` for the gateway container's health status,
#      hard-fail after 60s if it never reports healthy.
#
# Bus listeners start automatically via the agent container's entrypoint;
# we do NOT invoke ~/dannemora-infra/start-bus-listeners.sh here. That
# script is for manual recovery only (per the AF-126 ticket).
# ---------------------------------------------------------------------------
DANNEMORA_AGENT_HEALTH_TIMEOUT_SECS="${DANNEMORA_AGENT_HEALTH_TIMEOUT_SECS:-60}"
DANNEMORA_AGENT_HEALTH_POLL_INTERVAL="${DANNEMORA_AGENT_HEALTH_POLL_INTERVAL:-2}"
readonly DANNEMORA_AGENT_ROLES=(techlead developer qa)

_agent_role_dir() {
    local role="$1"
    printf '%s/openclaw-%s' "$HOME" "$role"
}

_agent_gateway_container() {
    local role="$1"
    printf 'openclaw-%s-openclaw-gateway-1' "$role"
}

# Poll a container's health status. Returns 0 on healthy, 1 on timeout.
# stdout is unused — caller is expected to print progress.
_wait_for_container_healthy() {
    local container="$1" timeout="$2" interval="$3"
    local elapsed=0
    local status=""
    while [ "$elapsed" -lt "$timeout" ]; do
        status="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
        if [ "$status" = "healthy" ]; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

run_step_13_start_agents() {
    require_cmd docker

    local role role_dir container artifacts
    for role in "${DANNEMORA_AGENT_ROLES[@]}"; do
        role_dir="$(_agent_role_dir "$role")"
        container="$(_agent_gateway_container "$role")"

        # Each role gets its own rollback step so partial failures only
        # tear down what was actually brought up.
        artifacts="container:${container}"
        register_step "step_13_agent_${role}" "$artifacts"

        if [ ! -d "$role_dir" ]; then
            die "agent compose dir missing: $role_dir (Step 11 should have created it)"
        fi
        if [ ! -f "$role_dir/docker-compose.yml" ]; then
            die "agent compose file missing: $role_dir/docker-compose.yml"
        fi

        printf '[dannemora] Step 13 — starting %s agent...' "$role"
        if ! ( cd "$role_dir" && docker compose up -d ) >/dev/null 2>&1; then
            echo " FAILED"
            die "docker compose up -d failed for role: $role (dir: $role_dir)"
        fi

        if ! _wait_for_container_healthy "$container" \
                "$DANNEMORA_AGENT_HEALTH_TIMEOUT_SECS" \
                "$DANNEMORA_AGENT_HEALTH_POLL_INTERVAL"; then
            echo " FAILED"
            die "agent container did not report healthy within ${DANNEMORA_AGENT_HEALTH_TIMEOUT_SECS}s: $container"
        fi
        echo " OK"

        mark_step_ok
    done
    echo "[dannemora] Step 13 done — all 3 agents healthy."
}

# ---------------------------------------------------------------------------
# Step 14 — Connect each agent gateway to dannemora-net (AF-126)
#
# The agent compose files declare dannemora-net as an external network and
# the gateway service is attached to it on `up`, so in the happy path this
# step is a no-op. We still run it idempotently to handle the case where
# operators bring agents up by hand against an older compose file, or where
# the network was attached but is missing for some reason.
# ---------------------------------------------------------------------------
run_step_14_connect_network() {
    require_cmd docker

    register_step "step_14_network_connect" ""

    local role container connected_already
    for role in "${DANNEMORA_AGENT_ROLES[@]}"; do
        container="$(_agent_gateway_container "$role")"

        if ! docker inspect "$container" >/dev/null 2>&1; then
            die "cannot connect missing container to dannemora-net: $container"
        fi

        # Idempotency: check if already on the network.
        connected_already=0
        if docker inspect "$container" \
                --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
                2>/dev/null | grep -qw 'dannemora-net'; then
            connected_already=1
        fi

        if [ "$connected_already" -eq 1 ]; then
            echo "[dannemora] Step 14 — $container already on dannemora-net"
            continue
        fi

        if ! docker network connect dannemora-net "$container" >/dev/null 2>&1; then
            # Race condition: docker may have just connected it. Re-check.
            if docker inspect "$container" \
                    --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
                    2>/dev/null | grep -qw 'dannemora-net'; then
                echo "[dannemora] Step 14 — $container connected to dannemora-net (race)"
                continue
            fi
            die "failed to connect $container to dannemora-net"
        fi
        echo "[dannemora] Step 14 — connected $container to dannemora-net"
    done

    mark_step_ok
    echo "[dannemora] Step 14 done."
}

# ---------------------------------------------------------------------------
# Step 16 — Verify baked-in product files (AF-128)
#
# After agents are running (post-Step 13/14), exec into each agent gateway
# and assert that the baked-in product files copied correctly from the
# `dannemora:local` image into /home/node/.openclaw/{workspace,skills}.
# This is a read-only sanity check — the upstream image build (AF-124 /
# AF-143) is responsible for putting these files there. If anything is
# missing, this step hard-fails so the operator hears about a broken
# image build at install time, not when an agent silently misbehaves.
#
# Filename reconciliation:
#   The original ticket text used a hyphenated, uncompiled filename for
#   the bus listener. The actual file in the repo is
#   `image/bin/dannemora_bus_listener.py` (underscore), and the
#   entrypoint.sh that boots the agent looks for
#   `dannemora_bus_listener.pyc` (underscore). Underscore is canonical.
#   We verify the underscore .pyc form and DO NOT verify the hyphen form.
#
# AF-133 rollback:
#   Verification is read-only and creates no state. We register the step
#   so it shows up in the rollback ledger, but with empty artifacts and
#   nothing to undo. mark_step_ok on success.
# ---------------------------------------------------------------------------

# Expected files lists — surfaced as constants so QA can audit the
# checklist without grepping function bodies. If you add a baked file in
# the image build (AF-124/AF-143), add it here too.
#
# These are the smallest provably-baked subsets. The image build copies
# more than this; we only assert what every role is guaranteed to have.
readonly DANNEMORA_VERIFY_BIN_FILES=(
    linear_api.pyc
    prompt_guard.pyc
    dannemora_secrets_client.pyc
    dannemora_bus_listener.pyc
)

readonly DANNEMORA_VERIFY_WORKSPACE_FILES=(
    IDENTITY.md
    SOUL.md
    DANNEMORA.md
    USER.md
    AGENTS.md
)

# Per-role skill names. Each role bakes a different skill tree (see
# image/skills/<role>/), so this is intentionally not a single shared list.
readonly DANNEMORA_VERIFY_SKILLS_TECHLEAD=(
    manage-ticket
    ticket-monitor
    orchestrate-dev-qa
)
readonly DANNEMORA_VERIFY_SKILLS_DEVELOPER=(
    phase-3-implementation
    phase-4-delivery
    cross-review
    ticket-cleanup
)
readonly DANNEMORA_VERIFY_SKILLS_QA=(
    qa-flow
    qa-phase0
    qa-phase1
    qa-report
)

_verify_skills_for_role() {
    # Echo the space-separated skill list for the given role.
    local role="$1"
    case "$role" in
        techlead)  printf '%s ' "${DANNEMORA_VERIFY_SKILLS_TECHLEAD[@]}" ;;
        developer) printf '%s ' "${DANNEMORA_VERIFY_SKILLS_DEVELOPER[@]}" ;;
        qa)        printf '%s ' "${DANNEMORA_VERIFY_SKILLS_QA[@]}" ;;
        *)         die "unknown agent role: $role" ;;
    esac
}

_verify_files_in_container() {
    # Run all baked-file assertions inside one container. Hard-fails (via
    # die) the moment anything is missing — does not collect errors.
    local container="$1" role="$2"

    local workspace_bin="/home/node/.openclaw/workspace/bin"
    local workspace_dir="/home/node/.openclaw/workspace"
    local skills_dir="/home/node/.openclaw/skills"

    local f

    # 1. API wrappers (.pyc) exist in workspace/bin.
    for f in "${DANNEMORA_VERIFY_BIN_FILES[@]}"; do
        if ! docker exec "$container" test -f "${workspace_bin}/${f}" >/dev/null 2>&1; then
            die "baked file missing in $container ($role): ${workspace_bin}/${f} — image build is broken (see AF-124 / AF-143)"
        fi
    done

    # 2. Per-role SKILL.md files exist.
    local skill
    for skill in $(_verify_skills_for_role "$role"); do
        if ! docker exec "$container" test -f "${skills_dir}/${skill}/SKILL.md" >/dev/null 2>&1; then
            die "baked skill missing in $container ($role): ${skills_dir}/${skill}/SKILL.md — image build is broken (see AF-124 / AF-143)"
        fi
    done

    # 3. Workspace files exist.
    for f in "${DANNEMORA_VERIFY_WORKSPACE_FILES[@]}"; do
        if ! docker exec "$container" test -f "${workspace_dir}/${f}" >/dev/null 2>&1; then
            die "baked workspace file missing in $container ($role): ${workspace_dir}/${f} — image build is broken (see AF-124 / AF-143)"
        fi
    done

    # 4. NO .py files in the bin dir — only compiled .pyc. If a .py
    # leaked, the source-protection guarantee in the image build is
    # broken. Fail loudly.
    local leaked_py
    leaked_py="$(docker exec "$container" sh -c "find ${workspace_bin} -maxdepth 1 -name '*.py' -print 2>/dev/null" 2>/dev/null || true)"
    if [ -n "$leaked_py" ]; then
        die "source leaked: .py file(s) found in $container ($role) at ${workspace_bin}: ${leaked_py} — image build is broken (see AF-124 / AF-143)"
    fi
}

run_step_16_verify_baked_files() {
    require_cmd docker

    # Verification is read-only and creates no state. Register with empty
    # artifacts so the rollback engine has nothing to undo.
    register_step "step_16_verify_files" ""

    local role container
    for role in "${DANNEMORA_AGENT_ROLES[@]}"; do
        container="$(_agent_gateway_container "$role")"

        if ! docker inspect "$container" >/dev/null 2>&1; then
            die "cannot verify baked files in missing container: $container"
        fi

        printf '[dannemora] Step 16 — verifying baked files in %s...' "$container"
        _verify_files_in_container "$container" "$role"
        echo " OK"
    done

    mark_step_ok
    echo "[dannemora] Step 16 done — baked product files verified in all 3 agents."
}

# ---------------------------------------------------------------------------
# Step 18 — nginx reverse proxy for the dashboard (AF-130)
#
# Configures an HTTP-only nginx vhost on port 80 that proxies
# /dashboard → http://localhost:9090, protected by HTTP basic auth.
# Generates fresh credentials on first install (idempotent on re-runs)
# and stashes them at ~/dannemora-infra/.dashboard-info for the
# completion screen (AF-132) to surface to the operator.
#
# HTTPS / certbot: deferred to v2 per ticket. Documented as a manual
# upgrade path in docs/operator-runbook.md. TODO(AF-130-v2): wire certbot
# into the auto-install flow when a customer-provided domain is
# available in the wizard JSON.
# ---------------------------------------------------------------------------
DANNEMORA_NGINX_SETUP_SCRIPT="${DANNEMORA_NGINX_SETUP_SCRIPT:-${_dannemora_install_dir}/installer/nginx_setup.sh}"
DANNEMORA_DASHBOARD_DEPLOY_SCRIPT="${DANNEMORA_DASHBOARD_DEPLOY_SCRIPT:-${_dannemora_install_dir}/installer/dashboard_deploy.sh}"
DANNEMORA_SMOKE_TEST_SCRIPT="${DANNEMORA_SMOKE_TEST_SCRIPT:-${_dannemora_install_dir}/installer/smoke_test.sh}"
DANNEMORA_COMPLETION_SCREEN_SCRIPT="${DANNEMORA_COMPLETION_SCREEN_SCRIPT:-${_dannemora_install_dir}/installer/completion_screen.sh}"

# ---------------------------------------------------------------------------
# Step 18b — dashboard deploy (AF-134)
#
# Auditable constants for the dashboard surface. Override via env for
# tests; production install uses the defaults.
# ---------------------------------------------------------------------------
DANNEMORA_DASHBOARD_PORT="${DANNEMORA_DASHBOARD_PORT:-9090}"
DANNEMORA_DASHBOARD_HOST_DIR="${DANNEMORA_DASHBOARD_HOST_DIR:-${HOME}/dannemora-dashboard}"
DANNEMORA_DASHBOARD_LOG_FILE="${DANNEMORA_DASHBOARD_LOG_FILE:-/tmp/dannemora-metrics-api.log}"

run_step_18_setup_nginx() {
    # Rollback artifacts:
    #   * nginx:dannemora-dashboard — disables the site + reloads nginx
    #   * file:/etc/nginx/.dannemora-htpasswd — removes the credentials file
    #   * file:~/dannemora-infra/.dashboard-info — removes the stash
    register_step "step_18_setup_nginx" "nginx:${DANNEMORA_NGINX_SITE_NAME:-dannemora-dashboard},file:${DANNEMORA_NGINX_HTPASSWD_PATH:-/etc/nginx/.dannemora-htpasswd},file:${DANNEMORA_DASHBOARD_INFO_FILE:-${DANNEMORA_INFRA_DIR}/.dashboard-info}"

    if [ ! -f "$DANNEMORA_NGINX_SETUP_SCRIPT" ]; then
        die "nginx setup helper not found at: $DANNEMORA_NGINX_SETUP_SCRIPT"
    fi
    # shellcheck disable=SC1090
    source "$DANNEMORA_NGINX_SETUP_SCRIPT"

    echo "[dannemora] Step 18 — configuring nginx reverse proxy for the dashboard..."
    dannemora_nginx_install_if_missing
    dannemora_nginx_load_or_generate_credentials
    dannemora_nginx_write_htpasswd
    dannemora_nginx_render_site_config
    dannemora_nginx_enable_site
    dannemora_nginx_disable_default_if_conflicting
    dannemora_nginx_validate_and_reload
    dannemora_nginx_stash_dashboard_info

    mark_step_ok
    echo "[dannemora] Step 18 done — dashboard reachable at /dashboard (basic auth)."
}

# ---------------------------------------------------------------------------
# Step 18b — dashboard deploy (AF-134)
#
# Copies the dashboard files (metrics API + HTML) out of any running
# gateway container to ~/dannemora-dashboard/ on the host, starts the
# host-side metrics API on 127.0.0.1:${DANNEMORA_DASHBOARD_PORT}, and
# verifies /health returns 200. AF-130's nginx already proxies
# /dashboard → localhost:${DANNEMORA_DASHBOARD_PORT}, so this step is
# what actually makes that proxy resolve to a live backend.
#
# AF-133 rollback artifacts:
#   process:dannemora-metrics-api — pgrep + kill the host-side process
#   file:${DANNEMORA_DASHBOARD_HOST_DIR} — remove the host install dir
# ---------------------------------------------------------------------------
run_step_18b_deploy_dashboard() {
    register_step "step_18b_deploy_dashboard" "process:dannemora-metrics-api,file:${DANNEMORA_DASHBOARD_HOST_DIR}"

    if [ ! -f "$DANNEMORA_DASHBOARD_DEPLOY_SCRIPT" ]; then
        die "dashboard deploy helper not found at: $DANNEMORA_DASHBOARD_DEPLOY_SCRIPT"
    fi
    # shellcheck disable=SC1090
    source "$DANNEMORA_DASHBOARD_DEPLOY_SCRIPT"

    echo "[dannemora] Step 18b — deploying dashboard (port=${DANNEMORA_DASHBOARD_PORT}, dir=${DANNEMORA_DASHBOARD_HOST_DIR})..."
    dannemora_dashboard_pick_source_container
    dannemora_dashboard_copy_files
    dannemora_dashboard_start_metrics_api
    dannemora_dashboard_verify_health

    mark_step_ok
    echo "[dannemora] Step 18b done — metrics API live on 127.0.0.1:${DANNEMORA_DASHBOARD_PORT}; nginx /dashboard now backed."
}

# ---------------------------------------------------------------------------
# Step 19 — post-install smoke test (AF-131)
#
# After every other install step has run, verify the live system
# end-to-end before showing the completion screen (AF-132). Six checks
# (containers / bus listeners / Redis / Infisical / metrics API / nginx
# proxy), each with a per-check timeout (≤10s) and a clear PASS/FAIL
# label. On the FIRST failure we hard-stop the install with a per-check
# troubleshooting hint and do NOT proceed to AF-132.
#
# AF-133 rollback:
#   Smoke testing is read-only. The step row has empty artifacts and
#   nothing for the rollback engine to undo. We mark_step_ok only on
#   all-pass; on any failure the helper `die`s and the rollback trap
#   surfaces the failure. We DO NOT mark_step_ok on partial pass.
# ---------------------------------------------------------------------------
run_step_19_smoke_test() {
    require_cmd docker
    require_cmd curl

    # Read-only step — empty artifacts.
    register_step "step_19_smoke_test" ""

    if [ ! -f "$DANNEMORA_SMOKE_TEST_SCRIPT" ]; then
        die "smoke test helper not found at: $DANNEMORA_SMOKE_TEST_SCRIPT"
    fi
    # shellcheck disable=SC1090
    source "$DANNEMORA_SMOKE_TEST_SCRIPT"

    echo "[dannemora] Step 19 — running post-install smoke test (${#DANNEMORA_SMOKE_CHECKS[@]} checks)..."

    # Order matters: containers first (cheapest, broadest signal), then
    # in-container probes, then host-side HTTP. Each check `die`s on
    # failure with its own troubleshooting hint, so we never reach the
    # next check on a fail.
    dannemora_smoke_check_containers
    dannemora_smoke_check_bus_listeners
    dannemora_smoke_check_redis_reachable
    dannemora_smoke_check_infisical_retrieval
    dannemora_smoke_check_metrics_api
    dannemora_smoke_check_nginx_proxy

    mark_step_ok
    echo "[dannemora] Step 19 done — all 6 smoke-test checks passed."
}

# ---------------------------------------------------------------------------
# Step 20 — completion screen (AF-132)
#
# Final screen the customer sees after `curl | bash` completes. This is
# the LAST installer step: every prior step has already succeeded and
# AF-131's smoke test has confirmed the live system is healthy.
#
# Presentation-only — creates no state. The AF-133 rollback row is
# registered with empty artifacts and the helper marks the step OK
# immediately after rendering. If a required input is missing
# (.dashboard-info, agent containers gone) the helper dies with a
# pointer at the upstream step rather than rendering a misleading
# screen.
# ---------------------------------------------------------------------------
run_step_20_completion_screen() {
    require_cmd docker

    # Read-only step — empty artifacts.
    register_step "step_20_completion_screen" ""

    if [ ! -f "$DANNEMORA_COMPLETION_SCREEN_SCRIPT" ]; then
        die "completion screen helper not found at: $DANNEMORA_COMPLETION_SCREEN_SCRIPT"
    fi
    # shellcheck disable=SC1090
    source "$DANNEMORA_COMPLETION_SCREEN_SCRIPT"

    dannemora_render_completion_screen

    mark_step_ok
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    echo "[dannemora] installer starting..."
    preflight
    if ! run_wizard; then
        echo "[dannemora] installer cancelled."
        exit 0
    fi
    commit_wizard_state
    WIZARD_COMMITTED=1  # tell the cleanup trap to leave the temp file alone
    if [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
    echo "[dannemora] wizard complete. Inputs staged at: ${WIZARD_TEMP_FILE}"
    echo "[dannemora] running Step 11 (config writer)..."
    run_step_11_write_configs
    echo "[dannemora] Step 11 done."
    enable_install_rollback
    run_step_12_start_infra
    run_step_13_start_agents
    run_step_14_connect_network
    echo "[dannemora] Steps 12–14 done. Infrastructure is up and agents are healthy."
    if [ -f "$DANNEMORA_INFISICAL_SEED" ]; then
        # shellcheck disable=SC1090,SC1091
        source "$DANNEMORA_INFISICAL_SEED"
    else
        die "Infisical seed script not found at: $DANNEMORA_INFISICAL_SEED"
    fi
    run_step_15_seed_infisical
    echo "[dannemora] Step 15 done. Infisical project seeded; agents restarted with INFISICAL_TOKEN."
    run_step_16_verify_baked_files
    echo "[dannemora] Step 16 done. Baked-in product files verified in every agent."
    # Step 17 (bus listener) auto-starts via container entrypoint per AF-124.
    run_step_18_setup_nginx
    echo "[dannemora] Step 18 done. Dashboard nginx configured."
    run_step_18b_deploy_dashboard
    echo "[dannemora] Step 18b done. Dashboard files deployed and metrics API live."
    run_step_19_smoke_test
    echo "[dannemora] Step 19 done. Post-install smoke test passed."
    run_step_20_completion_screen
    # The cleanup trap leaves the wizard temp file in place because
    # WIZARD_COMMITTED=1. The follow-up install-phase tickets take
    # ownership of it (AF-126/AF-127).
}

# Only auto-run when executed directly. When this file is sourced for
# testing, BASH_SOURCE[0] != $0 and main is called explicitly by the
# test harness.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
