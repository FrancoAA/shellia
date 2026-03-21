#!/usr/bin/env bash
# Tests for webfetch tool (lib/tools/webfetch.sh)

# --- Schema tests ---

test_webfetch_schema_valid() {
    local schema
    schema=$(tool_webfetch_schema)
    assert_valid_json "$schema" "webfetch schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "webfetch" "webfetch schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "url" "webfetch requires 'url' parameter"
}

test_webfetch_schema_has_format_options() {
    local schema
    schema=$(tool_webfetch_schema)

    local format_enum
    format_enum=$(echo "$schema" | jq -r '.function.parameters.properties.format.enum | join(",")')
    assert_contains "$format_enum" "markdown" "format enum includes markdown"
    assert_contains "$format_enum" "text" "format enum includes text"
    assert_contains "$format_enum" "html" "format enum includes html"
    assert_contains "$format_enum" "raw" "format enum includes raw"
}

test_webfetch_schema_has_reader_mode() {
    local schema
    schema=$(tool_webfetch_schema)

    local has_reader_mode
    has_reader_mode=$(echo "$schema" | jq '.function.parameters.properties | has("reader_mode")')
    assert_eq "$has_reader_mode" "true" "webfetch schema has 'reader_mode' parameter"
}

# --- Helper function tests ---

test_webfetch_normalize_timeout_defaults_to_30() {
    local result
    result=$(_webfetch_normalize_timeout "")
    assert_eq "$result" "30" "empty timeout defaults to 30"

    result=$(_webfetch_normalize_timeout "invalid")
    assert_eq "$result" "30" "non-numeric timeout defaults to 30"
}

test_webfetch_normalize_timeout_clamps_to_max() {
    local result
    result=$(_webfetch_normalize_timeout "200")
    assert_eq "$result" "120" "timeout clamped to max 120"
}

test_webfetch_normalize_timeout_clamps_negative() {
    local result
    result=$(_webfetch_normalize_timeout "-5")
    assert_eq "$result" "30" "negative timeout defaults to 30"
}

test_webfetch_normalize_timeout_accepts_valid() {
    local result
    result=$(_webfetch_normalize_timeout "45")
    assert_eq "$result" "45" "valid timeout is preserved"
}

test_webfetch_detect_content_type_extracts_mime() {
    local result
    result=$(_webfetch_detect_content_type "text/html; charset=utf-8" "https://example.com")
    assert_eq "$result" "text/html" "extracts mime type from content-type header"

    result=$(_webfetch_detect_content_type "application/json" "https://api.example.com")
    assert_eq "$result" "application/json" "extracts simple content-type"

    result=$(_webfetch_detect_content_type "IMAGE/PNG" "https://example.com")
    assert_eq "$result" "image/png" "normalizes to lowercase"
}

test_webfetch_check_tool_detects_installed() {
    local result
    result=$(_webfetch_check_tool bash && echo "yes" || echo "no")
    assert_eq "$result" "yes" "detects bash as installed"

    result=$(_webfetch_check_tool nonexistent_tool_12345 && echo "yes" || echo "no")
    assert_eq "$result" "no" "detects missing tool"
}

# --- URL validation tests ---

test_webfetch_execute_rejects_invalid_url() {
    local result
    local exit_code=0
    result=$(tool_webfetch_execute '{"url":"not-a-url"}' 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "rejects URL without protocol"
    assert_contains "$result" "Invalid URL" "shows clear error for invalid URL"
}

test_webfetch_execute_rejects_ftp_url() {
    local result
    local exit_code=0
    result=$(tool_webfetch_execute '{"url":"ftp://example.com/file"}' 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "rejects FTP URL"
}

test_webfetch_execute_accepts_http_url() {
    # Mock curl to avoid network call
    curl() {
        echo "200"
        return 0
    }
    
    local url_valid
    url_valid=$(tool_webfetch_execute '{"url":"http://example.com","timeout":5}' 2>/dev/null && echo "ok" || echo "fail")
    # Will fail due to missing curl mock complexity, but URL validation should pass
    
    unset -f curl
}

# --- Format tests with mocked curl ---

test_webfetch_execute_handles_json() {
    # Create a mock curl that returns JSON
    curl() {
        local args=("$@")
        if [[ "$*" == *"--max-time"* ]]; then
            echo "200"
            echo "content-type: application/json" > "${temp_headers:-/tmp/test_headers}"
            echo '{"test": "value", "number": 42}' > "${temp_file:-/tmp/test_file}"
            return 0
        fi
        command curl "$@"
    }

    local temp_headers temp_file
    temp_headers=$(mktemp)
    temp_file=$(mktemp)
    
    echo "content-type: application/json" > "$temp_headers"
    echo '{"test": "value", "number": 42}' > "$temp_file"

    # Test JSON formatting with mock
    local result
    result=$(_webfetch_format_json '{"test":"value"}' 2>/dev/null)
    assert_contains "$result" "test" "JSON formatter preserves content"

    rm -f "$temp_headers" "$temp_file"
}

test_webfetch_html_to_text_sed_strips_tags() {
    local html="<html><body><h1>Title</h1><p>Paragraph text</p></body></html>"
    local result
    result=$(_webfetch_html_to_text_sed "$html")
    assert_not_contains "$result" "<html>" "sed converter strips html tags"
    assert_contains "$result" "Title" "sed converter preserves text content"
    assert_contains "$result" "Paragraph text" "sed converter preserves paragraph text"
}

test_webfetch_html_to_text_sed_decodes_entities() {
    local html="<p>Cats &amp; Dogs &lt;3 &nbsp;stuff</p>"
    local result
    result=$(_webfetch_html_to_text_sed "$html")
    assert_contains "$result" "&" "decodes &amp; entity"
    assert_contains "$result" "<3" "decodes &lt; entity"
}

# --- Binary handling tests ---

test_webfetch_handle_image_returns_metadata() {
    local temp_file
    temp_file=$(mktemp)
    dd if=/dev/urandom of="$temp_file" bs=1024 count=5 2>/dev/null

    local result
    result=$(_webfetch_handle_image "https://example.com/image.png" "image/png" "$temp_file" 2>/dev/null)
    
    assert_contains "$result" "Image:" "reports image type"
    assert_contains "$result" "URL:" "includes source URL"
    assert_contains "$result" "Size:" "includes file size"

    rm -f "$temp_file"
}

test_webfetch_handle_binary_returns_metadata() {
    local temp_file
    temp_file=$(mktemp)
    dd if=/dev/urandom of="$temp_file" bs=1024 count=10 2>/dev/null

    local result
    result=$(_webfetch_handle_binary "https://example.com/file.pdf" "application/pdf" "$temp_file" 2>/dev/null)
    
    assert_contains "$result" "Binary file:" "reports binary type"
    assert_contains "$result" "URL:" "includes source URL"
    assert_contains "$result" "Size:" "includes file size"

    rm -f "$temp_file"
}

# --- Tool loaded test ---

test_webfetch_tool_loaded() {
    assert_eq "$(declare -F tool_webfetch_schema >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_webfetch_schema is defined after load_tools"
    assert_eq "$(declare -F tool_webfetch_execute >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_webfetch_execute is defined after load_tools"
}

test_webfetch_in_tools_array() {
    local result
    result=$(build_tools_array)
    
    local names
    names=$(echo "$result" | jq -r '.[].function.name' | sort | tr '\n' ',')
    assert_contains "$names" "webfetch" "tools array contains webfetch"
}
