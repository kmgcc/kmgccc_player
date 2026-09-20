#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$REPO_ROOT/Dependencies/PlayerAutomation"
SMOKE_SCRATCH="${PLAYER_AUTOMATION_SMOKE_SCRATCH:-${TMPDIR:-/tmp}/kmgccc-player-automation-mcp-smoke}"
MCP_TIMEOUT="${PLAYER_AUTOMATION_MCP_TIMEOUT:-15}"
MCP_BIN="${PLAYER_AUTOMATION_BIN:-$SMOKE_SCRATCH/arm64-apple-macosx/debug/player-automation}"

if [[ ! -x "$MCP_BIN" ]]; then
    swift build --package-path "$PACKAGE_ROOT" --scratch-path "$SMOKE_SCRATCH" -c debug >/dev/stderr
    MCP_BIN="$SMOKE_SCRATCH/arm64-apple-macosx/debug/player-automation"
fi

mcp_args=(mcp-stdio --no-launch --timeout "$MCP_TIMEOUT")

request() {
    local payload="$1"
    printf '%s\n' "$payload" | "$MCP_BIN" "${mcp_args[@]}"
}

assert_jq() {
    local label="$1"
    local payload="$2"
    local expression="$3"
    if ! jq -e "$expression" >/dev/null <<<"$payload"; then
        printf 'MCP smoke failed: %s\n%s\n' "$label" "$payload" >&2
        exit 1
    fi
    printf 'pass: %s\n' "$label"
}

modern_meta='{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}'
modern_discover="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":$modern_meta}"
modern_tools="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":$modern_meta}"
modern_resources="{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\",\"params\":$modern_meta}"
modern_call="{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"},\"name\":\"system.info\",\"arguments\":{}}}"

discover_result="$(request "$modern_discover")"
assert_jq "modern discovery" "$discover_result" '.jsonrpc == "2.0" and .result.capabilities.tools and ._meta["io.modelcontextprotocol/serverInfo"].name == "kmgccc_player"'

tools_result="$(request "$modern_tools")"
assert_jq "modern tools/list" "$tools_result" '.result.tools | length >= 40'
assert_jq "job annotations" "$tools_result" '(.result.tools[] | select(.name == "source.refresh") | .annotations["x-kmgccc-supports-jobs"]) == true'

resources_result="$(request "$modern_resources")"
assert_jq "modern resources/list" "$resources_result" '.result.resources | length >= 2'

call_result="$(request "$modern_call")"
assert_jq "modern tools/call" "$call_result" '.result.structuredContent.protocolVersion == 1 and .result.isError != true'

legacy_initialize='{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"kmgccc-player-mcp-smoke","version":"1"}}}'
legacy_initialized='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
legacy_ping='{"jsonrpc":"2.0","id":11,"method":"ping","params":{}}'
legacy_result="$(
    {
        printf '%s\n' "$legacy_initialize"
        printf '%s\n' "$legacy_initialized"
        printf '%s\n' "$legacy_ping"
    } | "$MCP_BIN" "${mcp_args[@]}"
)"
legacy_initialize_result="$(jq -s 'map(select(.id == 10))[0]' <<<"$legacy_result")"
legacy_ping_result="$(jq -s 'map(select(.id == 11))[0]' <<<"$legacy_result")"
assert_jq "legacy initialize" "$legacy_initialize_result" '.result.protocolVersion == "2025-11-25"'
assert_jq "legacy ping" "$legacy_ping_result" '.result != null and .error == null'

printf 'MCP stdio smoke passed.\n'
