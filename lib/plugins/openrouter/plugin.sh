#!/usr/bin/env bash
# Plugin: openrouter — find and use free models from OpenRouter

plugin_openrouter_info() {
    echo "OpenRouter utilities (--free flag)"
}

plugin_openrouter_hooks() {
    echo "init"
}

# === CLI flags ===

_SHELLIA_FREE_MODEL_REQUESTED=false

cli_flag_free_handler() {
    _SHELLIA_FREE_MODEL_REQUESTED=true
    echo 0
}

cli_flag_free_help() {
    echo "  --free                    Use a free model from OpenRouter"
}

# === Hooks ===

plugin_openrouter_on_init() {
    [[ "$_SHELLIA_FREE_MODEL_REQUESTED" == "true" ]] || return 0

    if [[ "$SHELLIA_API_URL" != *"openrouter"* ]]; then
        log_warn "--free requires an OpenRouter profile. Current URL: ${SHELLIA_API_URL}"
        return 0
    fi

    debug_log "plugin:openrouter" "fetching free models from OpenRouter..."

    local tmp_response
    tmp_response=$(mktemp)

    local http_code
    local curl_exit=0
    http_code=$(curl -sSL \
        --connect-timeout 10 \
        --max-time 15 \
        -o "$tmp_response" \
        -w "%{http_code}" \
        "https://openrouter.ai/api/frontend/models/find?fmt=cards&max_price=0&output_modalities=text&categories=programming" \
        2>/dev/null) || curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        rm -f "$tmp_response"
        log_warn "--free: could not reach OpenRouter (curl exit ${curl_exit}). Using current model."
        return 0
    fi

    if [[ "$http_code" -ne 200 ]]; then
        rm -f "$tmp_response"
        log_warn "--free: OpenRouter returned HTTP ${http_code}. Using current model."
        return 0
    fi

    local slug
    slug=$(jq -r '.data.models[0].slug // empty' "$tmp_response" 2>/dev/null)
    rm -f "$tmp_response"

    if [[ -z "$slug" ]]; then
        log_warn "--free: no free models found on OpenRouter. Using current model."
        return 0
    fi

    SHELLIA_MODEL="${slug}:free"
    log_info "Using free model: ${SHELLIA_MODEL}"
}
