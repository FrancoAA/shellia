#!/usr/bin/env python3
"""MCP Bridge — HTTP server that connects to MCP servers and exposes their tools.

Shellia's Bash plugin communicates with this bridge via simple HTTP:
  GET  /health   → bridge status
  GET  /tools    → discovered tools in OpenAI function-calling format
  POST /call     → forward a tool call to an MCP server
  POST /shutdown → graceful shutdown
"""

import argparse
import asyncio
import json
import logging
import os
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_LEVEL = os.environ.get("SHELLIA_MCP_LOG_LEVEL", "WARNING").upper()

logger = logging.getLogger("shellia.mcp_bridge")
logger.setLevel(getattr(logging, LOG_LEVEL, logging.WARNING))

_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(
    logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
)
logger.addHandler(_handler)

# ---------------------------------------------------------------------------
# MCP Client — manages connections to MCP servers
# ---------------------------------------------------------------------------

class MCPServerConnection:
    """Manages a single MCP server connection via stdio."""

    def __init__(self, name, config):
        self.name = name
        self.config = config
        self.process = None
        self.tools = []
        self._request_id = 0
        self._lock = threading.Lock()

    def _next_id(self):
        with self._lock:
            self._request_id += 1
            return self._request_id

    def connect(self):
        """Start the MCP server subprocess and initialize the connection."""
        command = self.config.get("command")
        args = self.config.get("args", [])
        env_overrides = self.config.get("env", {})

        if not command:
            logger.error("Server '%s': no command specified", self.name)
            return False

        env = os.environ.copy()
        env.update(env_overrides)

        try:
            self.process = subprocess.Popen(
                [command] + args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
            logger.info("Server '%s': started (pid=%d)", self.name, self.process.pid)
        except FileNotFoundError:
            logger.error("Server '%s': command not found: %s", self.name, command)
            return False
        except Exception as e:
            logger.error("Server '%s': failed to start: %s", self.name, e)
            return False

        # Send initialize request
        init_response = self._send_request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "shellia", "version": "1.0.0"},
        })

        if init_response is None:
            logger.error("Server '%s': initialize failed", self.name)
            self.disconnect()
            return False

        # Send initialized notification
        self._send_notification("notifications/initialized", {})

        # Discover tools
        tools_response = self._send_request("tools/list", {})
        if tools_response and "tools" in tools_response.get("result", {}):
            self.tools = tools_response["result"]["tools"]
            logger.info(
                "Server '%s': discovered %d tools", self.name, len(self.tools)
            )
        else:
            self.tools = []
            logger.warning("Server '%s': no tools discovered", self.name)

        return True

    def disconnect(self):
        """Stop the MCP server subprocess."""
        if self.process:
            try:
                self.process.stdin.close()
                self.process.terminate()
                self.process.wait(timeout=5)
            except Exception:
                self.process.kill()
                self.process.wait(timeout=2)
            logger.info("Server '%s': disconnected", self.name)
            self.process = None

    def call_tool(self, tool_name, arguments):
        """Call a tool on this MCP server."""
        response = self._send_request("tools/call", {
            "name": tool_name,
            "arguments": arguments,
        })

        if response is None:
            return {"error": f"Tool call failed: no response from server '{self.name}'"}

        result = response.get("result", {})
        if result.get("isError"):
            content = result.get("content", [])
            error_text = "\n".join(
                c.get("text", "") for c in content if c.get("type") == "text"
            )
            return {"error": error_text or "Tool returned an error"}

        content = result.get("content", [])
        text_parts = [
            c.get("text", "") for c in content if c.get("type") == "text"
        ]
        return {"result": "\n".join(text_parts)}

    def _send_request(self, method, params):
        """Send a JSON-RPC request and wait for the response."""
        if not self.process or self.process.poll() is not None:
            return None

        request_id = self._next_id()
        message = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }

        try:
            line = json.dumps(message) + "\n"
            self.process.stdin.write(line.encode("utf-8"))
            self.process.stdin.flush()

            # Read response lines until we get one with our request ID
            while True:
                response_line = self.process.stdout.readline()
                if not response_line:
                    return None
                try:
                    response = json.loads(response_line.decode("utf-8").strip())
                    if response.get("id") == request_id:
                        return response
                    # Skip notifications and other messages
                except json.JSONDecodeError:
                    continue
        except (BrokenPipeError, OSError) as e:
            logger.error("Server '%s': communication error: %s", self.name, e)
            return None

    def _send_notification(self, method, params):
        """Send a JSON-RPC notification (no response expected)."""
        if not self.process or self.process.poll() is not None:
            return

        message = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }

        try:
            line = json.dumps(message) + "\n"
            self.process.stdin.write(line.encode("utf-8"))
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            pass


class MCPBridge:
    """Manages multiple MCP server connections and tool dispatch."""

    def __init__(self, config_path):
        self.config_path = config_path
        self.servers = {}  # name -> MCPServerConnection
        self.tool_map = {}  # tool_name -> server_name

    def connect_all(self):
        """Connect to all configured MCP servers."""
        try:
            with open(self.config_path, "r") as f:
                config = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            logger.error("Failed to read config: %s", e)
            return

        mcp_servers = config.get("mcpServers", {})
        for name, server_config in mcp_servers.items():
            # Skip URL-based servers for now (SSE transport — future work)
            if "url" in server_config:
                logger.warning(
                    "Server '%s': SSE transport not yet supported, skipping", name
                )
                continue

            conn = MCPServerConnection(name, server_config)
            if conn.connect():
                self.servers[name] = conn
                for tool in conn.tools:
                    self.tool_map[tool["name"]] = name

    def disconnect_all(self):
        """Disconnect from all MCP servers."""
        for conn in self.servers.values():
            conn.disconnect()
        self.servers.clear()
        self.tool_map.clear()

    def get_tools_openai_format(self):
        """Return all discovered tools in OpenAI function-calling schema format."""
        tools = []
        for server_name, conn in self.servers.items():
            for tool in conn.tools:
                openai_tool = {
                    "type": "function",
                    "function": {
                        "name": tool["name"],
                        "description": tool.get("description", ""),
                        "parameters": tool.get("inputSchema", {
                            "type": "object",
                            "properties": {},
                        }),
                        "_mcp_server": server_name,
                    },
                }
                tools.append(openai_tool)
        return tools

    def call_tool(self, tool_name, arguments):
        """Forward a tool call to the appropriate MCP server."""
        server_name = self.tool_map.get(tool_name)
        if not server_name or server_name not in self.servers:
            return {"error": f"Unknown tool: {tool_name}"}
        return self.servers[server_name].call_tool(tool_name, arguments)

    def call_tool_on_server(self, server_name, tool_name, arguments):
        """Call a tool on a specific MCP server."""
        if server_name not in self.servers:
            return {"error": f"Unknown server: {server_name}"}
        return self.servers[server_name].call_tool(tool_name, arguments)


# ---------------------------------------------------------------------------
# HTTP Server
# ---------------------------------------------------------------------------

# Global bridge instance (set in main)
_bridge = None
_shutdown_event = threading.Event()


class BridgeHTTPHandler(BaseHTTPRequestHandler):
    """HTTP handler for the MCP bridge."""

    def log_message(self, format, *args):
        """Suppress default request logging."""
        logger.debug(format, *args)

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def do_GET(self):
        if self.path == "/health":
            self._send_json({
                "status": "ok",
                "servers": len(_bridge.servers),
                "tools": len(_bridge.tool_map),
            })
        elif self.path == "/tools":
            tools = _bridge.get_tools_openai_format()
            self._send_json(tools)
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/call":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            try:
                request = json.loads(body)
            except json.JSONDecodeError:
                self._send_json({"error": "invalid JSON"}, 400)
                return

            tool_name = request.get("tool", "")
            arguments = request.get("arguments", {})
            server_name = request.get("server", "")

            if server_name:
                result = _bridge.call_tool_on_server(
                    server_name, tool_name, arguments
                )
            else:
                result = _bridge.call_tool(tool_name, arguments)

            self._send_json(result)

        elif self.path == "/shutdown":
            self._send_json({"status": "shutting down"})
            _shutdown_event.set()
        else:
            self._send_json({"error": "not found"}, 404)


def run_server(port):
    """Run the HTTP server."""
    server = HTTPServer(("127.0.0.1", port), BridgeHTTPHandler)
    server.timeout = 1

    logger.info("Bridge HTTP server listening on 127.0.0.1:%d", port)

    while not _shutdown_event.is_set():
        server.handle_request()

    server.server_close()
    logger.info("Bridge HTTP server stopped")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global _bridge

    parser = argparse.ArgumentParser(description="MCP Bridge for shellia")
    parser.add_argument("--port", type=int, default=7898, help="HTTP server port")
    parser.add_argument("--config", required=True, help="Path to servers.json")
    args = parser.parse_args()

    _bridge = MCPBridge(args.config)

    # Handle signals
    def handle_signal(signum, frame):
        _shutdown_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Connect to all MCP servers
    _bridge.connect_all()

    if not _bridge.servers:
        logger.warning("No MCP servers connected — bridge will still run")

    # Run HTTP server (blocks until shutdown)
    try:
        run_server(args.port)
    finally:
        _bridge.disconnect_all()


if __name__ == "__main__":
    main()
