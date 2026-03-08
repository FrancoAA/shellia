# Web Serve Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `shellia serve` command that starts a web-based chat UI, allowing browser access to the full shellia agent.

**Architecture:** A directory plugin (`lib/plugins/serve/`) that bundles a thin Python 3 HTTP server and a single-file HTML chat UI. The Python server handles HTTP routing and spawns shellia in a special `--web-mode` for each chat request. Responses stream to the browser via Server-Sent Events (SSE). The entrypoint gets a new `serve` subcommand that delegates to the plugin.

**Tech Stack:** Bash (plugin), Python 3 stdlib (HTTP server, no pip dependencies), HTML/CSS/JS (single file, no build step)

---

### Task 1: Create the serve plugin skeleton

**Files:**
- Create: `lib/plugins/serve/plugin.sh`

**Step 1: Write the plugin skeleton**

Create `lib/plugins/serve/plugin.sh` with the required `plugin_serve_info()` and `plugin_serve_hooks()` functions, plus a REPL command `repl_cmd_serve_handler()` and `repl_cmd_serve_help()`. The main function `shellia_serve()` parses `--port` and `--host` flags and starts the Python server.

```bash
#!/usr/bin/env bash
# Plugin: serve — web-based chat UI for shellia

plugin_serve_info() {
    echo "Web-based chat UI accessible via browser"
}

plugin_serve_hooks() {
    echo ""
}

# REPL command: serve
repl_cmd_serve_handler() {
    shellia_serve "$@"
}

repl_cmd_serve_help() {
    echo -e "  ${THEME_ACCENT}serve${NC}             Start web UI (serve [--port 8080] [--host 0.0.0.0])"
}

# Main serve function
shellia_serve() {
    local port host
    port=$(plugin_config_get "serve" "port" "8080")
    host=$(plugin_config_get "serve" "host" "0.0.0.0")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) port="$2"; shift 2 ;;
            --host) host="$2"; shift 2 ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done

    # Check python3 is available
    if ! command -v python3 &>/dev/null; then
        die "python3 is required for 'shellia serve'. Install Python 3 and try again."
    fi

    local plugin_dir="${SHELLIA_DIR}/lib/plugins/serve"
    local server_script="${plugin_dir}/server.py"

    if [[ ! -f "$server_script" ]]; then
        die "Server script not found: ${server_script}"
    fi

    log_info "Starting shellia web UI..."
    echo -e "  ${THEME_ACCENT}URL:${NC}  http://${host}:${port}"
    echo -e "  ${THEME_MUTED}Press Ctrl+C to stop${NC}"
    echo ""

    # Export config so the Python server can access it
    export SHELLIA_SERVE_PORT="$port"
    export SHELLIA_SERVE_HOST="$host"
    export SHELLIA_SERVE_PLUGIN_DIR="$plugin_dir"
    export SHELLIA_SERVE_SHELLIA_CMD="${SHELLIA_DIR}/shellia"

    # Start the Python server (blocking)
    python3 "$server_script"
}
```

**Step 2: Verify plugin loads**

Run: `bash tests/run_tests.sh`
Expected: All existing tests pass (no regressions). The plugin is auto-discovered by `load_plugins`.

---

### Task 2: Add `serve` subcommand to the entrypoint

**Files:**
- Modify: `shellia` (add serve subcommand block after `plugins` subcommand, around line 46)

**Step 1: Add the serve subcommand**

Add after the `plugins` block:

```bash
if [[ "${1:-}" == "serve" ]]; then
    shift
    load_config
    apply_theme "${SHELLIA_THEME:-default}"
    load_tools
    load_plugins
    fire_hook "init"
    shellia_serve "$@"
    fire_hook "shutdown"
    exit 0
fi
```

**Step 2: Update the help text**

Add to the Options section:
```
echo "  serve                       Start web-based chat UI"
```

Add to the Modes section:
```
echo "  shellia serve               Web UI mode (browser)"
```

**Step 3: Verify**

Run: `bash shellia --help`
Expected: Shows serve in help output

Run: `bash tests/run_tests.sh`
Expected: All tests pass

---

### Task 3: Create the Python HTTP server

**Files:**
- Create: `lib/plugins/serve/server.py`

**Step 1: Write the Python HTTP server**

The server:
- Serves `index.html` on GET `/`
- Handles POST `/api/chat` — reads JSON body `{"message": "...", "session_id": "..."}`, spawns shellia, streams response via SSE
- Handles POST `/api/chat/reset` — resets a session
- Handles GET `/api/health` — returns `{"status": "ok"}`
- Manages sessions: each session_id maps to a conversation history file
- Binds to `SHELLIA_SERVE_HOST:SHELLIA_SERVE_PORT`

Key design decisions:
- Use `http.server` from Python stdlib (no dependencies)
- Use `threading` for concurrent requests
- Spawn `shellia` subprocess with `--web-mode` flag per request
- Stream output line-by-line as SSE `data:` events
- Session files stored in `/tmp/shellia_web_sessions/`

```python
#!/usr/bin/env python3
"""Thin HTTP server for shellia web UI. No pip dependencies."""

import http.server
import json
import os
import subprocess
import sys
import threading
import uuid
from pathlib import Path
from urllib.parse import urlparse

HOST = os.environ.get("SHELLIA_SERVE_HOST", "0.0.0.0")
PORT = int(os.environ.get("SHELLIA_SERVE_PORT", "8080"))
PLUGIN_DIR = os.environ.get("SHELLIA_SERVE_PLUGIN_DIR", os.path.dirname(__file__))
SHELLIA_CMD = os.environ.get("SHELLIA_SERVE_SHELLIA_CMD", "shellia")
SESSIONS_DIR = Path("/tmp/shellia_web_sessions")
SESSIONS_DIR.mkdir(exist_ok=True)


class ShelliaHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/" or path == "/index.html":
            self._serve_file("index.html", "text/html")
        elif path == "/api/health":
            self._json_response({"status": "ok"})
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/chat":
            self._handle_chat()
        elif path == "/api/chat/reset":
            self._handle_reset()
        else:
            self.send_error(404)

    def _handle_chat(self):
        body = self._read_body()
        if body is None:
            return
        message = body.get("message", "").strip()
        session_id = body.get("session_id", str(uuid.uuid4()))
        if not message:
            self._json_response({"error": "message is required"}, 400)
            return

        # Set up SSE headers
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        # Send session_id as first event
        self._sse_send({"type": "session", "session_id": session_id})

        try:
            # Build shellia command
            env = os.environ.copy()
            env["SHELLIA_WEB_SESSION_ID"] = session_id
            env["SHELLIA_WEB_SESSIONS_DIR"] = str(SESSIONS_DIR)

            cmd = [SHELLIA_CMD, "--web-mode", message]
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                text=True,
            )

            # Stream stdout line by line
            buffer = ""
            for line in iter(process.stdout.readline, ""):
                line = line.rstrip("\n")
                # Check for JSON events (tool calls, status updates)
                if line.startswith("__SHELLIA_EVENT__:"):
                    event_json = line[len("__SHELLIA_EVENT__:"):]
                    try:
                        event = json.loads(event_json)
                        self._sse_send(event)
                    except json.JSONDecodeError:
                        buffer += line + "\n"
                else:
                    buffer += line + "\n"
                    # Send text chunks periodically
                    self._sse_send({"type": "text", "content": line})

            process.wait()

            # Send completion event
            stderr_output = process.stderr.read()
            self._sse_send({
                "type": "done",
                "exit_code": process.returncode,
            })

        except Exception as e:
            self._sse_send({"type": "error", "message": str(e)})

        finally:
            self._sse_send({"type": "close"})

    def _handle_reset(self):
        body = self._read_body()
        if body is None:
            return
        session_id = body.get("session_id", "")
        if session_id:
            session_file = SESSIONS_DIR / f"{session_id}.json"
            if session_file.exists():
                session_file.unlink()
        self._json_response({"status": "ok"})

    def _serve_file(self, filename, content_type):
        filepath = os.path.join(PLUGIN_DIR, filename)
        try:
            with open(filepath, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, f"File not found: {filename}")

    def _json_response(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _sse_send(self, data):
        try:
            msg = f"data: {json.dumps(data)}\n\n"
            self.wfile.write(msg.encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            return json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            self._json_response({"error": "invalid JSON"}, 400)
            return None

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        sys.stderr.write(f"  [{self.log_date_time_string()}] {format % args}\n")


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle requests in threads for concurrent sessions."""
    allow_reuse_address = True

    def process_request(self, request, client_address):
        thread = threading.Thread(target=self._handle, args=(request, client_address))
        thread.daemon = True
        thread.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    server = ThreadedHTTPServer((HOST, PORT), ShelliaHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
```

**Step 2: Verify the server starts**

Run: `SHELLIA_SERVE_PLUGIN_DIR=lib/plugins/serve python3 lib/plugins/serve/server.py &`
Then: `curl http://localhost:8080/api/health`
Expected: `{"status": "ok"}`
Kill: `kill %1`

---

### Task 4: Add `--web-mode` to the shellia entrypoint

**Files:**
- Modify: `shellia` (add web-mode flag handling and output format)

**Step 1: Add web-mode flag to the flag parser**

In the flag parsing `while` loop, add:
```bash
--web-mode)
    SHELLIA_WEB_MODE=true
    shift
    ;;
```

**Step 2: Add web-mode dispatch**

In the single-prompt dispatch section (after `if [[ -n "$PROMPT" ]]; then`), add web-mode handling that:
- Sets `SHELLIA_WEB_MODE=true` as export
- Uses the web session conversation file if `SHELLIA_WEB_SESSION_ID` is set
- Outputs JSON events instead of plain text
- Uses `api_chat_loop` with conversation history

The web mode should:
1. Check for existing session conversation file
2. Build messages with history if session exists
3. Call `api_chat_loop`
4. Save updated conversation to session file
5. Output the response

**Step 3: Verify**

Run: `bash shellia --web-mode "echo hello"` (with valid config)
Expected: Outputs text response (may also output events)

Run: `bash tests/run_tests.sh`
Expected: All tests pass

---

### Task 5: Create the web chat UI

**Files:**
- Create: `lib/plugins/serve/index.html`

**Step 1: Write the single-file chat UI**

A self-contained HTML file with inline CSS and JS featuring:
- Clean, minimal design matching shellia's terminal aesthetic
- Dark theme (terminal-inspired)
- Chat message bubbles (user right-aligned, assistant left-aligned)
- Input box at the bottom with send button
- Real-time streaming via EventSource/fetch with SSE
- Basic markdown rendering (bold, italic, code blocks, inline code)
- Shows tool execution status (command name, running indicator)
- Session management (auto-generates session_id, stored in localStorage)
- Reset button to clear conversation
- Responsive layout (works on mobile)
- Connection status indicator

---

### Task 6: Write tests for the serve plugin

**Files:**
- Create: `tests/test_serve.sh`

**Step 1: Write plugin loading tests**

```bash
test_serve_plugin_loads() — verify plugin is discovered and loaded
test_serve_plugin_info() — verify info string is returned
test_serve_plugin_hooks() — verify hooks list (empty)
test_serve_repl_command_registered() — verify 'serve' is in REPL commands
test_serve_repl_help_shown() — verify help text includes 'serve'
```

**Step 2: Write shellia_serve function tests**

```bash
test_serve_requires_python3() — verify it fails gracefully without python3
test_serve_default_port() — verify default port is 8080
test_serve_default_host() — verify default host is 0.0.0.0
test_serve_custom_port() — verify --port flag works
test_serve_custom_host() — verify --host flag works
test_serve_exports_env_vars() — verify environment variables are exported
```

**Step 3: Write web-mode tests**

```bash
test_web_mode_flag_recognized() — verify --web-mode is parsed without error
test_web_mode_session_file_created() — verify session file is created
test_web_mode_session_file_updated() — verify session accumulates history
```

**Step 4: Run tests**

Run: `bash tests/run_tests.sh`
Expected: All tests pass including new serve tests

---

### Task 7: Update help text and documentation

**Files:**
- Modify: `shellia` (help text — already done in Task 2)
- Modify: `README.md` (add web UI section)

**Step 1: Add web UI section to README**

Add a section documenting:
- `shellia serve` command and options
- Default port/host
- Configuration via plugin config file
- Security considerations (network binding)
- Requirements (python3)

**Step 2: Commit**

```bash
git add lib/plugins/serve/ shellia tests/test_serve.sh README.md
git commit -m "feat: add web UI plugin with 'shellia serve' command"
```
