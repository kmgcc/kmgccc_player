#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$REPO_ROOT/Dependencies/PlayerAutomation"
SMOKE_SCRATCH="${PLAYER_AUTOMATION_SMOKE_SCRATCH:-${TMPDIR:-/tmp}/kmgccc-player-automation-mcp-smoke}"
MCP_TIMEOUT="${PLAYER_AUTOMATION_MCP_TIMEOUT:-15}"
MCP_BIN="${PLAYER_AUTOMATION_BIN:-}"

if [[ -z "$MCP_BIN" || ! -x "$MCP_BIN" ]]; then
    swift build --package-path "$PACKAGE_ROOT" --scratch-path "$SMOKE_SCRATCH" -c debug >/dev/stderr
    MCP_BIN="$(swift build --package-path "$PACKAGE_ROOT" --scratch-path "$SMOKE_SCRATCH" -c debug --show-bin-path)/player-automation"
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

assert_jq "audio import contract" "$tools_result" '(.result.tools[] | select(.name == "library.import") | .annotations["x-kmgccc-supports-jobs"] == true and .inputSchema.required == ["filePaths"] and .inputSchema.properties.targetPlaylistID.type == "string")'

dsp_tools='["dsp.schema","dsp.state","dsp.load","dsp.validate","dsp.patch","dsp.wait",
  "dsp.presets.list","dsp.presets.get","dsp.presets.save","dsp.presets.select","dsp.presets.rename",
  "dsp.presets.delete","dsp.presets.duplicate","dsp.presets.import","dsp.presets.export",
  "dsp.impulseResponses.list","dsp.impulseResponses.import",
  "dsp.scripts.get","dsp.scripts.update","dsp.scripts.compile","dsp.scripts.test",
  "dsp.nodes.retry","dsp.errors.get","dsp.errors.clear"]'
assert_jq "DSP tool set" "$tools_result" "($dsp_tools - [.result.tools[].name]) == []"
assert_jq "DSP order and parameter operations" "$tools_result" '(.result.tools[] | select(.name == "dsp.patch") | [.inputSchema.properties.operations.items.oneOf[].properties.op.enum[0]]) as $ops | (["setMaster","setParameter","setEnabled","setOrder","addNode","removeNode","setLimiter","setEqualLoudness"] - $ops) == []'
assert_jq "DSP limiter contract" "$tools_result" '(.result.tools[] | select(.name == "dsp.patch") | .inputSchema.properties.configuration.properties.limiter.properties | keys) == ["ceilingDB","enabled"]'
assert_jq "audio loudness range" "$tools_result" '(.result.tools[] | select(.name == "audio.patch") | .inputSchema.properties.values.properties.loudness.properties.targetLUFS | .minimum == -20 and .maximum == -8)'
assert_jq "DSP load is read-only" "$tools_result" '(.result.tools[] | select(.name == "dsp.load") | .annotations.readOnlyHint) == true'
assert_jq "impulse response import contract" "$tools_result" '(.result.tools[] | select(.name == "dsp.impulseResponses.import") | .inputSchema.required == ["path"] and .annotations.readOnlyHint == false)'
assert_jq "script apply contract" "$tools_result" '(.result.tools[] | select(.name == "dsp.scripts.update") | .inputSchema.properties.apply.type == "boolean")'

# Live DSP calls need the running App with MCP enabled; they never change audio.
if [[ "${PLAYER_AUTOMATION_SMOKE_DSP_LIVE:-0}" == "1" ]]; then
    dsp_call() {
        printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"name":"%s","arguments":%s}}' "$1" "$2" "$3"
    }
    state_result="$(request "$(dsp_call 20 dsp.state '{}')")"
    assert_jq "live dsp.state" "$state_result" '.result.isError != true and (.result.structuredContent.desiredRevision | type) == "string"'
    load_result="$(request "$(dsp_call 21 dsp.load '{"sampleMs":0}')")"
    assert_jq "live dsp.load" "$load_result" '.result.isError != true and (.result.structuredContent.overload | has("chainRuntimeBypassed"))'
    patch_result="$(request "$(dsp_call 22 dsp.patch '{"operations":[{"op":"setMaster","value":true}],"dryRun":true}')")"
    assert_jq "live dsp.patch dry-run" "$patch_result" '.result.isError != true and .result.structuredContent.applied == false'
    ir_result="$(request "$(dsp_call 23 dsp.impulseResponses.list '{}')")"
    assert_jq "live dsp.impulseResponses.list" "$ir_result" '.result.isError != true and (.result.structuredContent.impulseResponses | type) == "array"'
fi

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
