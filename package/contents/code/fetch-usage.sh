#!/usr/bin/env bash
# fetch-usage.sh
# Reads Claude Code OAuth token from ~/.claude/.credentials.json
# and queries Anthropic's /api/oauth/usage endpoint.
# On 401, attempts a single OAuth refresh against platform.claude.com,
# atomically rewrites the credentials file, and retries once.
# Always exits 0 with a JSON object on stdout — errors are reported as
# {"error": "..."} so the QML side has a single parse path.

set -uo pipefail

CREDS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
LOCK_FILE="${CREDS_FILE}.lock"
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
# Public Claude Code OAuth client ID (extracted from the official binary).
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
# Match Claude Code's own User-Agent. Anthropic's edge appears to apply a
# stricter rate limit to unrecognized UAs on the oauth/usage endpoint.
USER_AGENT="claude-code/2.1.119"

emit_error() {
    printf '{"error":"%s"}\n' "$1"
    exit 0
}

if [ ! -f "$CREDS_FILE" ]; then
    emit_error "no_credentials"
fi

if ! command -v jq >/dev/null 2>&1; then
    emit_error "missing_jq"
fi

if ! command -v curl >/dev/null 2>&1; then
    emit_error "missing_curl"
fi

if ! command -v flock >/dev/null 2>&1; then
    emit_error "missing_flock"
fi

# Read access/refresh/scopes as a single TSV line so we don't fork jq three times.
read_creds_tsv() {
    jq -r '
      .claudeAiOauth as $c |
      [ $c.accessToken // ""
      , $c.refreshToken // ""
      , ($c.scopes // [] | join(" "))
      ] | @tsv
    ' "$CREDS_FILE" 2>/dev/null
}

CREDS_TSV=$(read_creds_tsv) || emit_error "no_token"
IFS=$'\t' read -r ORIG_ACCESS_TOKEN REFRESH_TOKEN SCOPES <<<"$CREDS_TSV"
if [ -z "$ORIG_ACCESS_TOKEN" ]; then
    emit_error "no_token"
fi

HDRS_FILE=$(mktemp 2>/dev/null) || emit_error "tmp_error"
trap 'rm -f "$HDRS_FILE"' EXIT

# Hit the usage endpoint with a given bearer token. Sets HTTP_CODE / BODY /
# RETRY_AFTER as side effects. Returns 1 on transport failure.
call_usage() {
    local token="$1"
    : > "$HDRS_FILE"
    local resp
    resp=$(curl -sS --max-time 10 -w $'\n%{http_code}' \
        -D "$HDRS_FILE" \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: ${USER_AGENT}" \
        "$USAGE_URL" 2>/dev/null) || return 1

    HTTP_CODE=$(printf '%s' "$resp" | tail -n1)
    BODY=$(printf '%s' "$resp" | sed '$d')
    RETRY_AFTER=$(grep -i '^retry-after:' "$HDRS_FILE" 2>/dev/null \
        | tail -n1 | awk '{print $2}' | tr -d '\r\n ')
    return 0
}

# Refresh the access token and rewrite .credentials.json atomically.
# On success: prints the new access token on stdout, returns 0.
# On failure: prints nothing, returns nonzero.
#
# Concurrency: a flock on .credentials.json.lock serialises refreshes
# between this script and any siblings. Claude Code itself does not
# participate in the lock, but it does re-read the file on a 401 — so
# our writes will be picked up by `claude` on its next request without
# needing it to know about us. After acquiring the lock we re-read the
# file: if a sibling already rotated, we use their token instead of
# burning another single-use refresh_token.
do_refresh() {
    # Create the lock file with 0600 permissions on first use; subsequent
    # opens just append (no truncation, so concurrent holders are fine).
    ( umask 077 && : >> "$LOCK_FILE" ) 2>/dev/null || return 1
    exec 9>>"$LOCK_FILE" || return 1
    if ! flock -w 10 9; then
        exec 9>&-
        return 1
    fi

    local tsv cur_access cur_refresh cur_scopes
    tsv=$(read_creds_tsv) || { exec 9>&-; return 1; }
    IFS=$'\t' read -r cur_access cur_refresh cur_scopes <<<"$tsv"

    if [ -n "$cur_access" ] && [ "$cur_access" != "$ORIG_ACCESS_TOKEN" ]; then
        printf '%s' "$cur_access"
        exec 9>&-
        return 0
    fi

    if [ -z "$cur_refresh" ]; then
        exec 9>&-
        return 1
    fi

    local body
    body=$(jq -nc \
        --arg rt  "$cur_refresh" \
        --arg cid "$CLIENT_ID" \
        --arg sc  "$cur_scopes" \
        '{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid, scope:$sc}'
    ) || { exec 9>&-; return 1; }

    local resp http rbody
    resp=$(curl -sS --max-time 15 -w $'\n%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H "User-Agent: ${USER_AGENT}" \
        -d "$body" \
        "$TOKEN_URL" 2>/dev/null) || { exec 9>&-; return 1; }

    http=$(printf '%s' "$resp" | tail -n1)
    rbody=$(printf '%s' "$resp" | sed '$d')

    if [ "$http" != "200" ]; then
        exec 9>&-
        return 1
    fi

    local new_access new_refresh expires_in
    new_access=$(printf '%s' "$rbody" | jq -r '.access_token // empty' 2>/dev/null)
    new_refresh=$(printf '%s' "$rbody" | jq -r '.refresh_token // empty' 2>/dev/null)
    expires_in=$(printf '%s' "$rbody" | jq -r '.expires_in // empty' 2>/dev/null)

    if [ -z "$new_access" ] || ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
        exec 9>&-
        return 1
    fi
    # Spec allows the response to omit refresh_token; keep ours if so.
    [ -z "$new_refresh" ] && new_refresh="$cur_refresh"

    # expiresAt is stored as ms-since-epoch (matches Claude Code's format).
    local now_ms expires_at_ms
    now_ms=$(date +%s%3N 2>/dev/null)
    if ! [[ "$now_ms" =~ ^[0-9]+$ ]]; then
        now_ms=$(( $(date +%s) * 1000 ))
    fi
    expires_at_ms=$(( now_ms + expires_in * 1000 ))

    local tmpfile
    tmpfile=$(mktemp "${CREDS_FILE}.tmp.XXXXXX") || { exec 9>&-; return 1; }
    if ! jq \
        --arg at "$new_access" \
        --arg rt "$new_refresh" \
        --argjson ea "$expires_at_ms" \
        '.claudeAiOauth.accessToken = $at
         | .claudeAiOauth.refreshToken = $rt
         | .claudeAiOauth.expiresAt = $ea' \
        "$CREDS_FILE" > "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        exec 9>&-
        return 1
    fi
    chmod 600 "$tmpfile" 2>/dev/null
    if ! mv "$tmpfile" "$CREDS_FILE" 2>/dev/null; then
        rm -f "$tmpfile"
        exec 9>&-
        return 1
    fi

    exec 9>&-
    printf '%s' "$new_access"
    return 0
}

call_usage "$ORIG_ACCESS_TOKEN" || emit_error "network_error"

# 401/403 → try one refresh+retry cycle. Anything else falls through to the
# normal status-code switch below.
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    if NEW_TOKEN=$(do_refresh) && [ -n "$NEW_TOKEN" ]; then
        call_usage "$NEW_TOKEN" || emit_error "network_error"
    else
        emit_error "auth_expired"
    fi
fi

case "$HTTP_CODE" in
    200)
        # Verify it's valid JSON before passing through.
        if printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; then
            printf '%s\n' "$BODY"
        else
            emit_error "parse_error"
        fi
        ;;
    401|403)
        emit_error "auth_expired"
        ;;
    429)
        if [[ "$RETRY_AFTER" =~ ^[0-9]+$ ]]; then
            printf '{"error":"http_429","retry_after":%s}\n' "$RETRY_AFTER"
        else
            printf '{"error":"http_429"}\n'
        fi
        ;;
    "")
        emit_error "network_error"
        ;;
    *)
        emit_error "http_${HTTP_CODE}"
        ;;
esac
