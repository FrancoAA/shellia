#!/usr/bin/env bash
# Tool: webfetch — fetch content from URLs and convert to LLM-friendly formats

tool_webfetch_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "webfetch",
        "description": "Fetch content from a URL and convert to LLM-friendly format. Handles HTML (converts to markdown), JSON (pretty prints), images (returns metadata), and binary files. Use format='markdown' for web pages, 'raw' for original content.",
        "parameters": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "URL to fetch (http or https)"
                },
                "format": {
                    "type": "string",
                    "enum": ["markdown", "text", "html", "raw"],
                    "description": "Output format: markdown (default, best for LLMs), text (plain), html (cleaned), raw (original)"
                },
                "reader_mode": {
                    "type": "boolean",
                    "description": "Extract main content only, strip navigation/ads (requires Python readability)"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in seconds (default: 30, max: 120)"
                }
            },
            "required": ["url"]
        }
    }
}
EOF
}

_WEBFETCH_MAX_SIZE="${SHELLIA_WEBFETCH_MAX_SIZE:-1048576}"
_WEBFETCH_USER_AGENT="Mozilla/5.0 (compatible; BashiaWebfetch/1.0)"

_webfetch_check_tool() {
    command -v "$1" >/dev/null 2>&1
}

_webfetch_normalize_timeout() {
    local value="${1:-30}"
    local max=120
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        if [[ "$value" -gt "$max" ]]; then
            echo "$max"
        elif [[ "$value" -lt 1 ]]; then
            echo "30"
        else
            echo "$value"
        fi
    else
        echo "30"
    fi
}

_webfetch_detect_content_type() {
    local content_type_header="$1"
    local url="$2"
    
    echo "$content_type_header" | grep -oEi '^[^;]+' | tr 'A-Z' 'a-z'
}

_webfetch_html_to_markdown_pandoc() {
    local html="$1"
    if _webfetch_check_tool pandoc; then
        echo "$html" | pandoc -f html -t markdown --wrap=none 2>/dev/null
        return $?
    fi
    return 1
}

_webfetch_html_to_markdown_python() {
    local html="$1"
    local reader_mode="$2"
    
    local python_cmd
    if _webfetch_check_tool python3; then
        python_cmd="python3"
    elif _webfetch_check_tool python; then
        python_cmd="python"
    else
        return 1
    fi
    
    local script
    if [[ "$reader_mode" == "true" ]]; then
        script='
import sys
try:
    from readability import Document
    from html2text import HTML2Text
    html = sys.stdin.read()
    doc = Document(html)
    content = doc.summary()
    h = HTML2Text()
    h.ignore_links = False
    h.ignore_images = False
    h.body_width = 0
    print(h.handle(content))
except ImportError:
    sys.exit(1)
'
    else
        script='
import sys
try:
    from html2text import HTML2Text
    html = sys.stdin.read()
    h = HTML2Text()
    h.ignore_links = False
    h.ignore_images = False
    h.body_width = 0
    print(h.handle(html))
except ImportError:
    sys.exit(1)
'
    fi
    
    echo "$html" | "$python_cmd" -c "$script" 2>/dev/null
    return $?
}

_webfetch_html_to_text_lynx() {
    local html="$1"
    if _webfetch_check_tool lynx; then
        echo "$html" | lynx -dump -stdin -nolist 2>/dev/null
        return $?
    fi
    return 1
}

_webfetch_html_to_text_sed() {
    local html="$1"
    echo "$html" | sed -e 's/<[^>]*>//g' | sed -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' | tr -s ' \n' | head -c "$_WEBFETCH_MAX_SIZE"
}

_webfetch_reader_mode_pup() {
    local html="$1"
    if _webfetch_check_tool pup; then
        local content
        content=$(echo "$html" | pup 'article' 2>/dev/null)
        if [[ -n "$content" ]]; then
            echo "$content"
            return 0
        fi
    fi
    return 1
}

_webfetch_format_json() {
    local content="$1"
    if _webfetch_check_tool jq; then
        echo "$content" | jq '.' 2>/dev/null || echo "$content"
    else
        echo "$content"
    fi
}

_webfetch_handle_image() {
    local url="$1"
    local content_type="$2"
    local temp_file="$3"
    
    local size
    size=$(wc -c < "$temp_file" 2>/dev/null | tr -d ' ')
    
    local dimensions=""
    if _webfetch_check_tool identify; then
        dimensions=$(identify -format "%wx%h" "$temp_file" 2>/dev/null)
    elif _webfetch_check_tool file; then
        local file_info
        file_info=$(file "$temp_file" 2>/dev/null)
        dimensions=$(echo "$file_info" | grep -oE '[0-9]+ x [0-9]+' | head -1)
    fi
    
    echo "[Image: ${content_type}]"
    echo "URL: ${url}"
    echo "Size: ${size} bytes"
    [[ -n "$dimensions" ]] && echo "Dimensions: ${dimensions}"
    
    if [[ "$size" -lt 10000 ]]; then
        echo ""
        echo "Base64 (first 500 chars):"
        base64 "$temp_file" 2>/dev/null | head -c 500
        echo ""
    fi
}

_webfetch_handle_binary() {
    local url="$1"
    local content_type="$2"
    local temp_file="$3"
    
    local size
    size=$(wc -c < "$temp_file" 2>/dev/null | tr -d ' ')
    
    echo "[Binary file: ${content_type}]"
    echo "URL: ${url}"
    echo "Size: ${size} bytes"
    
    if _webfetch_check_tool file; then
        local file_info
        file_info=$(file -b "$temp_file" 2>/dev/null)
        echo "Type: ${file_info}"
    fi
}

tool_webfetch_execute() {
    local args_json="$1"
    
    local url format reader_mode timeout
    url=$(echo "$args_json" | jq -r '.url')
    format=$(echo "$args_json" | jq -r '.format // "markdown"')
    reader_mode=$(echo "$args_json" | jq -r '.reader_mode // false')
    timeout=$(_webfetch_normalize_timeout "$(echo "$args_json" | jq -r '.timeout // empty')")
    
    debug_log "tool" "webfetch: url=${url} format=${format} reader_mode=${reader_mode} timeout=${timeout}"
    tool_trace "webfetch: ${url}"
    
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "Error: Invalid URL. Must start with http:// or https://"
        return 1
    fi
    
    local temp_file temp_headers
    temp_file=$(mktemp)
    temp_headers=$(mktemp)
    
    trap "rm -f '$temp_file' '$temp_headers'" EXIT
    
    local http_code content_type
    if _webfetch_check_tool curl; then
        http_code=$(curl -sSL --max-time "$timeout" --max-filesize "$_WEBFETCH_MAX_SIZE" \
            -H "User-Agent: $_WEBFETCH_USER_AGENT" \
            -D "$temp_headers" \
            -o "$temp_file" \
            -w "%{http_code}" \
            "$url" 2>/dev/null)
        
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to fetch URL (timeout or size limit exceeded)"
            return 1
        fi
        
        content_type=$(grep -i "^content-type:" "$temp_headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
    elif _webfetch_check_tool wget; then
        wget -q --timeout="$timeout" --max-redirect=5 \
            --user-agent="$_WEBFETCH_USER_AGENT" \
            -O "$temp_file" \
            "$url" 2>/dev/null
        
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to fetch URL"
            return 1
        fi
        
        http_code="200"
        content_type=$(file -b --mime-type "$temp_file" 2>/dev/null)
    else
        echo "Error: Neither curl nor wget available"
        return 1
    fi
    
    if [[ "$http_code" =~ ^[45][0-9][0-9]$ ]]; then
        echo "Error: HTTP ${http_code} - $(cat "$temp_file" 2>/dev/null | head -c 200)"
        return 1
    fi
    
    local mime_type
    mime_type=$(_webfetch_detect_content_type "$content_type" "$url")
    
    if [[ "$mime_type" =~ ^image/ ]]; then
        _webfetch_handle_image "$url" "$mime_type" "$temp_file"
        return 0
    fi
    
    if [[ "$mime_type" =~ ^application/(pdf|zip|x-rar|octet-stream|x-tar|gzip|x-bzip) ]] || \
       [[ "$mime_type" =~ ^video/ ]] || \
       [[ "$mime_type" =~ ^audio/ ]]; then
        _webfetch_handle_binary "$url" "$mime_type" "$temp_file"
        return 0
    fi
    
    if [[ "$mime_type" =~ application/json ]] || [[ "$url" =~ \.json$ ]]; then
        local content
        content=$(cat "$temp_file")
        
        if [[ "$format" == "raw" ]]; then
            echo "$content"
        else
            _webfetch_format_json "$content"
        fi
        return 0
    fi
    
    if [[ "$format" == "raw" ]]; then
        cat "$temp_file"
        return 0
    fi
    
    if [[ "$mime_type" =~ text/html ]] || [[ "$url" =~ \.html?$ ]]; then
        local html
        html=$(cat "$temp_file")
        
        if [[ "$format" == "html" ]]; then
            echo "$html"
            return 0
        fi
        
        if [[ "$reader_mode" == "true" ]]; then
            local reader_html
            reader_html=$(_webfetch_reader_mode_pup "$html")
            if [[ -n "$reader_html" ]]; then
                html="$reader_html"
            fi
        fi
        
        if [[ "$format" == "markdown" ]]; then
            local result
            
            result=$(_webfetch_html_to_markdown_pandoc "$html")
            if [[ $? -eq 0 && -n "$result" ]]; then
                echo "$result"
                return 0
            fi
            
            result=$(_webfetch_html_to_markdown_python "$html" "$reader_mode")
            if [[ $? -eq 0 && -n "$result" ]]; then
                echo "$result"
                return 0
            fi
            
            result=$(_webfetch_html_to_text_lynx "$html")
            if [[ $? -eq 0 && -n "$result" ]]; then
                echo "$result"
                return 0
            fi
            
            _webfetch_html_to_text_sed "$html"
            return 0
        fi
        
        if [[ "$format" == "text" ]]; then
            local result
            
            result=$(_webfetch_html_to_text_lynx "$html")
            if [[ $? -eq 0 && -n "$result" ]]; then
                echo "$result"
                return 0
            fi
            
            _webfetch_html_to_text_sed "$html"
            return 0
        fi
    fi
    
    cat "$temp_file"
}
