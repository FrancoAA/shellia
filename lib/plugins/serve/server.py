#!/usr/bin/env python3
"""Thin HTTP server for shellia web UI. No pip dependencies required."""

import http.server
import json
import os
import subprocess
import sys
import threading
import uuid
from pathlib import Path
from urllib.parse import urlparse
import re

HOST = os.environ.get("SHELLIA_SERVE_HOST", "0.0.0.0")
PORT = int(os.environ.get("SHELLIA_SERVE_PORT", "8080"))
PLUGIN_DIR = os.environ.get(
    "SHELLIA_SERVE_PLUGIN_DIR", os.path.dirname(os.path.abspath(__file__))
)
SHELLIA_CMD = os.environ.get("SHELLIA_SERVE_SHELLIA_CMD", "shellia")
SESSIONS_DIR = Path(
    os.environ.get("SHELLIA_WEB_SESSIONS_DIR", "/tmp/shellia_web_sessions")
)
SESSIONS_DIR.mkdir(exist_ok=True)
SESSION_ID_RE = r"^[A-Za-z0-9._-]+$"

SESSION_LOCKS = {}
SESSION_LOCKS_MUTEX = threading.Lock()


def sanitize_session_id(session_id: str) -> str:
    if not session_id:
        return str(uuid.uuid4())

    if len(session_id) > 128:
        return str(uuid.uuid4())

    if not re.fullmatch(SESSION_ID_RE, session_id):
        return str(uuid.uuid4())

    return session_id


def get_session_lock(session_id: str) -> threading.Lock:
    with SESSION_LOCKS_MUTEX:
        lock = SESSION_LOCKS.get(session_id)
        if lock is None:
            lock = threading.Lock()
            SESSION_LOCKS[session_id] = lock
        return lock


class ShelliaHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/" or path == "/index.html":
            self._serve_file("index.html", "text/html; charset=utf-8")
        elif path == "/api/health":
            self._json_response({"status": "ok", "version": "shellia-web"})
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

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def _handle_chat(self):
        body = self._read_body()
        if body is None:
            return

        message = body.get("message", "").strip()
        session_id = sanitize_session_id(body.get("session_id") or "")

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
            session_lock = get_session_lock(session_id)
            with session_lock:
                # Build environment for shellia subprocess
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
                    bufsize=1,  # Line-buffered
                )

                # Read stderr in a background thread for real-time tool events
                # Events on stderr are prefixed with __SHELLIA_EVENT__:
                def read_stderr():
                    for line in iter(process.stderr.readline, ""):
                        line = line.rstrip("\n")
                        if not line:
                            continue
                        if line.startswith("__SHELLIA_EVENT__:"):
                            event_json = line[len("__SHELLIA_EVENT__:") :]
                            try:
                                event = json.loads(event_json)
                                self._sse_send(event)
                            except json.JSONDecodeError:
                                pass  # Ignore malformed events
                        # Other stderr output (debug logs, tool UX) is ignored for SSE

                stderr_thread = threading.Thread(target=read_stderr, daemon=True)
                stderr_thread.start()

                # Read stdout for the final response text and any direct events
                for line in iter(process.stdout.readline, ""):
                    line = line.rstrip("\n")
                    if not line:
                        continue

                    # Lines prefixed with __SHELLIA_EVENT__: are structured events
                    if line.startswith("__SHELLIA_EVENT__:"):
                        event_json = line[len("__SHELLIA_EVENT__:") :]
                        try:
                            event = json.loads(event_json)
                            self._sse_send(event)
                        except json.JSONDecodeError:
                            self._sse_send({"type": "text", "content": event_json})
                    else:
                        # Regular text output (the final response)
                        self._sse_send({"type": "text", "content": line})

                process.wait()
                stderr_thread.join(timeout=2)

                # Send completion event
                self._sse_send(
                    {
                        "type": "done",
                        "exit_code": process.returncode,
                    }
                )

        except Exception as e:
            self._sse_send({"type": "error", "message": str(e)})

        finally:
            self._sse_send({"type": "close"})

    def _handle_reset(self):
        body = self._read_body()
        if body is None:
            return
        session_id = sanitize_session_id(body.get("session_id", ""))
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
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _sse_send(self, data):
        """Send a Server-Sent Event."""
        try:
            msg = f"data: {json.dumps(data)}\n\n"
            self.wfile.write(msg.encode("utf-8"))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_body(self):
        """Read and parse JSON request body."""
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            return json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            self._json_response({"error": "invalid JSON body"}, 400)
            return None

    def log_message(self, format, *args):
        """Custom log format."""
        sys.stderr.write(f"  [{self.log_date_time_string()}] {format % args}\n")


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a separate thread for concurrent sessions."""

    allow_reuse_address = True

    def process_request(self, request, client_address):
        thread = threading.Thread(
            target=self._handle_request,
            args=(request, client_address),
            daemon=True,
        )
        thread.start()

    def _handle_request(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


def main():
    server = ThreadedHTTPServer((HOST, PORT), ShelliaHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nShutting down...\n")
        server.shutdown()


if __name__ == "__main__":
    main()
