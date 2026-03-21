#!/usr/bin/env python3
"""Telegram bot for shellia. No pip dependencies required (stdlib only)."""

from __future__ import annotations

import json
import mimetypes
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
import uuid

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BOT_TOKEN = os.environ.get("SHELLIA_TELEGRAM_BOT_TOKEN", "")
ALLOWED_USERS = os.environ.get("SHELLIA_TELEGRAM_ALLOWED_USERS", "")
SHELLIA_CMD = os.environ.get("SHELLIA_TELEGRAM_SHELLIA_CMD", "shellia")
SESSIONS_DIR = Path(
    os.environ.get("SHELLIA_TELEGRAM_SESSIONS_DIR", "/tmp/shellia_telegram_sessions")
)
SESSIONS_DIR.mkdir(exist_ok=True)
FILES_DIR = SESSIONS_DIR / "files"
FILES_DIR.mkdir(exist_ok=True)

TELEGRAM_API = f"https://api.telegram.org/bot{BOT_TOKEN}"
POLL_TIMEOUT = 30  # Long-polling timeout in seconds
MAX_MESSAGE_LENGTH = 4096

# Parse allowed user IDs into a set of ints (empty set = no restriction)
ALLOWED_USER_IDS: set[int] = set()
if ALLOWED_USERS.strip():
    for uid in ALLOWED_USERS.split(","):
        uid = uid.strip()
        if uid.isdigit():
            ALLOWED_USER_IDS.add(int(uid))

# Per-chat locks to prevent concurrent processing for the same conversation
CHAT_LOCKS: dict[int, threading.Lock] = {}
CHAT_LOCKS_MUTEX = threading.Lock()


# ---------------------------------------------------------------------------
# Telegram Bot API helpers
# ---------------------------------------------------------------------------


def api_call(method: str, payload: dict | None = None, timeout: int = 60) -> dict:
    """Call a Telegram Bot API method. Returns the parsed JSON response."""
    url = f"{TELEGRAM_API}/{method}"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}
        )
    else:
        req = urllib.request.Request(url)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        log(f"API error {exc.code} on {method}: {body}")
        return {"ok": False, "description": body}
    except urllib.error.URLError as exc:
        log(f"Network error on {method}: {exc.reason}")
        return {"ok": False, "description": str(exc.reason)}


def send_message(chat_id: int, text: str, parse_mode: str | None = None) -> dict:
    """Send a text message, automatically splitting if it exceeds the limit."""
    chunks = split_message(text)
    result = {}
    for chunk in chunks:
        payload: dict = {"chat_id": chat_id, "text": chunk}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        result = api_call("sendMessage", payload)
    return result


def send_chat_action(chat_id: int, action: str = "typing") -> None:
    """Send a chat action indicator (e.g. 'typing')."""
    api_call("sendChatAction", {"chat_id": chat_id, "action": action})


def split_message(text: str) -> list[str]:
    """Split a message into chunks that fit within Telegram's limit.

    Splits at paragraph boundaries when possible, falls back to line
    boundaries, and finally hard-splits at the character limit.
    """
    if len(text) <= MAX_MESSAGE_LENGTH:
        return [text]

    chunks: list[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= MAX_MESSAGE_LENGTH:
            chunks.append(remaining)
            break

        # Try to split at a paragraph boundary (double newline)
        cut = remaining.rfind("\n\n", 0, MAX_MESSAGE_LENGTH)
        if cut > 0:
            chunks.append(remaining[:cut])
            remaining = remaining[cut + 2 :]
            continue

        # Fall back to a single newline
        cut = remaining.rfind("\n", 0, MAX_MESSAGE_LENGTH)
        if cut > 0:
            chunks.append(remaining[:cut])
            remaining = remaining[cut + 1 :]
            continue

        # Hard split (no good boundary found)
        chunks.append(remaining[:MAX_MESSAGE_LENGTH])
        remaining = remaining[MAX_MESSAGE_LENGTH:]

    return chunks


def encode_multipart(fields: dict, files: dict | None = None) -> tuple[bytes, str]:
    """Encode form data as multipart/form-data for file uploads.

    Args:
        fields: Dict of regular form fields (str -> str/int)
        files: Dict of file fields (str -> (filename, file_content, content_type))

    Returns:
        (body_bytes, content_type_header)
    """
    boundary = f"----shellia{uuid.uuid4().hex}"
    lines: list[bytes] = []

    for key, value in fields.items():
        lines.append(f"--{boundary}\r\n".encode())
        lines.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode())
        lines.append(f"{value}\r\n".encode())

    if files:
        for key, (filename, content, content_type) in files.items():
            lines.append(f"--{boundary}\r\n".encode())
            lines.append(
                f'Content-Disposition: form-data; name="{key}"; filename="{filename}"\r\n'.encode()
            )
            lines.append(f"Content-Type: {content_type}\r\n\r\n".encode())
            lines.append(content)
            lines.append(b"\r\n")

    lines.append(f"--{boundary}--\r\n".encode())
    body = b"".join(lines)
    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type


def download_file(
    file_id: str, destination: Path | None = None, timeout: int = 60
) -> tuple[bytes, str] | str | None:
    """Download a file from Telegram by its file_id.

    Returns (file_content, filename) when downloading in-memory, or the
    filename when streaming directly to destination.
    """
    result = api_call("getFile", {"file_id": file_id}, timeout=timeout)
    if not result.get("ok"):
        log(f"Failed to get file info: {result.get('description', 'unknown error')}")
        return None

    file_path = result.get("result", {}).get("file_path")
    if not file_path:
        log("No file_path in getFile response")
        return None

    download_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"
    filename = Path(file_path).name

    try:
        req = urllib.request.Request(download_url)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if destination is not None:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open("wb") as file_obj:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        file_obj.write(chunk)
                return filename

            return resp.read(), filename
    except (urllib.error.HTTPError, urllib.error.URLError) as exc:
        log(f"Failed to download file: {exc}")
        return None


def send_document(
    chat_id: int, file_content: bytes, filename: str, caption: str | None = None
) -> dict:
    """Send a document to a chat.

    Args:
        chat_id: Target chat ID
        file_content: Binary content of the file
        filename: Name of the file
        caption: Optional caption for the document

    Returns:
        API response dict
    """
    content_type, _ = mimetypes.guess_type(filename)
    if not content_type:
        content_type = "application/octet-stream"

    fields: dict = {"chat_id": chat_id}
    if caption:
        fields["caption"] = caption

    files = {"document": (filename, file_content, content_type)}
    body, content_type_header = encode_multipart(fields, files)

    url = f"{TELEGRAM_API}/sendDocument"
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": content_type_header}
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_err = exc.read().decode("utf-8", errors="replace")
        log(f"API error {exc.code} on sendDocument: {body_err}")
        return {"ok": False, "description": body_err}
    except urllib.error.URLError as exc:
        log(f"Network error on sendDocument: {exc.reason}")
        return {"ok": False, "description": str(exc.reason)}


# ---------------------------------------------------------------------------
# Chat lock management
# ---------------------------------------------------------------------------


def get_chat_lock(chat_id: int) -> threading.Lock:
    """Return a per-chat lock, creating one if needed."""
    with CHAT_LOCKS_MUTEX:
        lock = CHAT_LOCKS.get(chat_id)
        if lock is None:
            lock = threading.Lock()
            CHAT_LOCKS[chat_id] = lock
        return lock


# ---------------------------------------------------------------------------
# Access control
# ---------------------------------------------------------------------------


def is_user_allowed(user_id: int) -> bool:
    """Check whether a user is in the allowlist. Empty list = allow all."""
    if not ALLOWED_USER_IDS:
        return True
    return user_id in ALLOWED_USER_IDS


# ---------------------------------------------------------------------------
# Bot commands
# ---------------------------------------------------------------------------

HELP_TEXT = (
    "I'm *shellia* — an AI shell assistant.\n\n"
    "Send me any message and I'll respond using the configured AI model. "
    "I can also execute shell commands on the host machine when needed.\n\n"
    "You can send me files (documents, images) and I'll analyze them.\n\n"
    "*Commands:*\n"
    "/start  — Welcome message\n"
    "/reset  — Clear conversation history\n"
    "/help   — Show this help"
)


def extract_file_info(message: dict) -> dict | None:
    """Extract file information from a message.

    Returns dict with file_id, file_type, filename, mime_type, file_size
    or None if no file is present.
    """
    if "document" in message:
        doc = message["document"]
        return {
            "file_id": doc.get("file_id"),
            "file_type": "document",
            "filename": doc.get("file_name", "document"),
            "mime_type": doc.get("mime_type", "application/octet-stream"),
            "file_size": doc.get("file_size", 0),
        }

    if "photo" in message:
        photos = message["photo"]
        if photos:
            photo = photos[-1]
            return {
                "file_id": photo.get("file_id"),
                "file_type": "photo",
                "filename": f"photo_{photo.get('file_id', 'unknown')}.jpg",
                "mime_type": "image/jpeg",
                "file_size": photo.get("file_size", 0),
            }

    if "video" in message:
        video = message["video"]
        return {
            "file_id": video.get("file_id"),
            "file_type": "video",
            "filename": video.get(
                "file_name", f"video_{video.get('file_id', 'unknown')}.mp4"
            ),
            "mime_type": video.get("mime_type", "video/mp4"),
            "file_size": video.get("file_size", 0),
        }

    if "audio" in message:
        audio = message["audio"]
        return {
            "file_id": audio.get("file_id"),
            "file_type": "audio",
            "filename": audio.get(
                "file_name", f"audio_{audio.get('file_id', 'unknown')}.mp3"
            ),
            "mime_type": audio.get("mime_type", "audio/mpeg"),
            "file_size": audio.get("file_size", 0),
        }

    if "voice" in message:
        voice = message["voice"]
        return {
            "file_id": voice.get("file_id"),
            "file_type": "voice",
            "filename": f"voice_{voice.get('file_id', 'unknown')}.ogg",
            "mime_type": voice.get("mime_type", "audio/ogg"),
            "file_size": voice.get("file_size", 0),
        }

    return None


def extract_message_text(message: dict) -> str:
    """Extract user-provided text from a Telegram message."""
    return message.get("text", message.get("caption", "")).strip()


def build_prompt_text(
    text: str, file_info: dict | None = None, local_filename: str | None = None
) -> str:
    """Build the prompt passed to shellia for a Telegram message."""
    prompt_parts: list[str] = []
    if text:
        prompt_parts.append(text)

    if file_info and local_filename:
        file_type = file_info.get("file_type", "document")
        mime_type = file_info.get("mime_type", "unknown")
        file_size = file_info.get("file_size", 0)
        prompt_parts.append(
            f"[User uploaded a {file_type} file: {local_filename} "
            f"({mime_type}, {file_size} bytes)]"
        )

    return "\n".join(prompt_parts) if prompt_parts else "The user sent a file."


START_TEXT = (
    "Hello! I'm *shellia*, your AI shell assistant.\n\n"
    "Just send me a message and I'll help you out. "
    "Use /help to see available commands."
)


def handle_command(chat_id: int, command: str) -> bool:
    """Handle a bot command. Returns True if the message was a command."""
    # Strip the @botname suffix if present (e.g. /help@mybotname)
    cmd = command.split("@")[0].lower()

    if cmd == "/start":
        send_message(chat_id, START_TEXT, parse_mode="Markdown")
        return True

    if cmd == "/help":
        send_message(chat_id, HELP_TEXT, parse_mode="Markdown")
        return True

    if cmd == "/reset":
        session_file = SESSIONS_DIR / f"{chat_id}.json"
        if session_file.exists():
            session_file.unlink()
        send_message(chat_id, "Conversation history cleared.")
        return True

    return False


# ---------------------------------------------------------------------------
# Core: process a user message through shellia
# ---------------------------------------------------------------------------


def process_message(
    chat_id: int, user_id: int, text: str, file_info: dict | None = None
) -> None:
    """Process an incoming message by spawning shellia in web mode.

    Args:
        chat_id: Telegram chat ID
        user_id: Telegram user ID
        text: Text content of the message (may be empty if file-only)
        file_info: Optional file information dict from extract_file_info()
    """
    lock = get_chat_lock(chat_id)

    if not lock.acquire(blocking=False):
        send_message(
            chat_id,
            "I'm still processing your previous message. Please wait a moment.",
        )
        return

    local_file_path: Path | None = None

    try:
        # Show typing indicator
        send_chat_action(chat_id)

        # Handle file download if present
        if file_info:
            file_id = file_info.get("file_id")
            if not file_id:
                send_message(chat_id, "❌ Invalid file information.")
                return
            filename = file_info.get("filename", "file")
            file_type = file_info.get("file_type", "document")

            send_message(
                chat_id,
                f"📥 Downloading {file_type}: `{filename}`",
                parse_mode="Markdown",
            )
            send_chat_action(chat_id)

            # Save file locally for shellia to access
            chat_files_dir = FILES_DIR / str(chat_id)
            local_file_path = chat_files_dir / filename

            saved_filename = download_file(file_id, local_file_path)
            if saved_filename is None:
                send_message(chat_id, "❌ Failed to download the file.")
                return

            send_message(
                chat_id,
                f"✅ Downloaded {file_type}: `{saved_filename}`",
                parse_mode="Markdown",
            )
            send_chat_action(chat_id)

        # Build environment for shellia subprocess
        env = os.environ.copy()
        env["SHELLIA_WEB_SESSION_ID"] = str(chat_id)
        env["SHELLIA_WEB_SESSIONS_DIR"] = str(SESSIONS_DIR)

        prompt_text = build_prompt_text(
            text,
            file_info,
            local_file_path.name if local_file_path else None,
        )

        cmd = [SHELLIA_CMD, "--web-mode", prompt_text]

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            bufsize=1,
        )

        response_lines: list[str] = []

        # Read stderr in background for tool events
        def read_stderr():
            for line in iter(process.stderr.readline, ""):
                line = line.rstrip("\n")
                if not line:
                    continue
                if line.startswith("__SHELLIA_EVENT__:"):
                    event_json = line[len("__SHELLIA_EVENT__:") :]
                    try:
                        event = json.loads(event_json)
                        handle_event(chat_id, event)
                    except json.JSONDecodeError:
                        pass

        stderr_thread = threading.Thread(target=read_stderr, daemon=True)
        stderr_thread.start()

        # Read stdout for response text and direct events
        for line in iter(process.stdout.readline, ""):
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("__SHELLIA_EVENT__:"):
                event_json = line[len("__SHELLIA_EVENT__:") :]
                try:
                    event = json.loads(event_json)
                    handle_event(chat_id, event)
                except json.JSONDecodeError:
                    response_lines.append(event_json)
            else:
                response_lines.append(line)

        process.wait()
        stderr_thread.join(timeout=5)

        # Send the final response
        response_text = "\n".join(response_lines).strip()
        if response_text:
            send_message(chat_id, response_text)
        elif process.returncode != 0:
            send_message(chat_id, "Something went wrong processing your message.")

    except Exception as exc:
        log(f"Error processing message for chat {chat_id}: {exc}")
        send_message(chat_id, f"An error occurred: {exc}")

    finally:
        lock.release()


def handle_event(chat_id: int, event: dict) -> None:
    """Handle a structured shellia event by sending status to Telegram."""
    event_type = event.get("type", "")

    if event_type == "status":
        status = event.get("status", "")
        if status == "thinking":
            send_chat_action(chat_id)

    elif event_type == "tool_call":
        tool_name = event.get("name", "unknown")
        tool_args = event.get("arguments", {})

        # Build a concise status message for the user
        if tool_name == "run_command":
            cmd = tool_args.get("command", "")
            if cmd:
                send_message(chat_id, f"⚙️ Running: `{cmd}`", parse_mode="Markdown")
        elif tool_name == "run_plan":
            send_message(chat_id, "📋 Executing a multi-step plan...")
        elif tool_name == "delegate_task":
            task = tool_args.get("task", "")
            if task:
                send_message(chat_id, f"🔀 Delegating: _{task}_", parse_mode="Markdown")
        else:
            send_message(chat_id, f"🔧 Using tool: {tool_name}")

        # Keep typing indicator alive
        send_chat_action(chat_id)

    elif event_type == "file":
        file_path = event.get("path", "")
        caption = event.get("caption")
        if not file_path:
            send_message(chat_id, "⚠️ Received a file event without a path.")
            return

        artifact = Path(file_path)
        if not artifact.is_file():
            send_message(
                chat_id, f"⚠️ File not found: `{artifact.name}`", parse_mode="Markdown"
            )
            return

        result = send_document(
            chat_id,
            artifact.read_bytes(),
            artifact.name,
            caption=caption,
        )
        if not result.get("ok"):
            send_message(chat_id, "Failed to send generated file back to Telegram.")


# ---------------------------------------------------------------------------
# Long-polling loop
# ---------------------------------------------------------------------------


def poll_updates(offset: int) -> tuple[list[dict], int]:
    """Fetch new updates from Telegram using long polling.

    Returns (updates, new_offset).
    """
    payload = {"timeout": POLL_TIMEOUT, "allowed_updates": ["message"]}
    if offset:
        payload["offset"] = offset

    result = api_call("getUpdates", payload, timeout=POLL_TIMEOUT + 10)

    if not result.get("ok"):
        return [], offset

    updates = result.get("result", [])
    new_offset = offset
    for update in updates:
        uid = update.get("update_id", 0)
        if uid >= new_offset:
            new_offset = uid + 1

    return updates, new_offset


def run_bot() -> None:
    """Main bot loop with long polling."""
    if not BOT_TOKEN:
        log("FATAL: No bot token configured.")
        sys.exit(1)

    # Verify the token by calling getMe
    me = api_call("getMe")
    if not me.get("ok"):
        log(f"FATAL: Invalid bot token. getMe response: {me}")
        sys.exit(1)

    bot_info = me.get("result", {})
    bot_name = bot_info.get("username", "unknown")
    log(f"Bot started: @{bot_name} (id: {bot_info.get('id')})")

    if ALLOWED_USER_IDS:
        log(f"Access restricted to user IDs: {ALLOWED_USER_IDS}")
    else:
        log("WARNING: No allowed_users configured — bot is open to everyone!")

    # Set bot commands for the menu
    api_call(
        "setMyCommands",
        {
            "commands": [
                {"command": "help", "description": "Show help and available commands"},
                {"command": "reset", "description": "Clear conversation history"},
            ]
        },
    )

    offset = 0
    while True:
        try:
            updates, offset = poll_updates(offset)

            for update in updates:
                message = update.get("message")
                if not message:
                    continue

                chat_id = message["chat"]["id"]
                user_id = message.get("from", {}).get("id", 0)
                text = extract_message_text(message)

                # Access control
                if not is_user_allowed(user_id):
                    send_message(
                        chat_id,
                        "Sorry, you are not authorized to use this bot.",
                    )
                    log(f"Unauthorized access attempt from user {user_id}")
                    continue

                # Handle commands
                if text.startswith("/"):
                    if handle_command(chat_id, text):
                        continue

                # Check for file attachments
                file_info = extract_file_info(message)

                # Skip if no text and no file
                if not text and not file_info:
                    continue

                # Process messages (text and/or files) in a separate thread
                thread = threading.Thread(
                    target=process_message,
                    args=(chat_id, user_id, text, file_info),
                    daemon=True,
                )
                thread.start()

        except KeyboardInterrupt:
            log("Shutting down...")
            break

        except Exception as exc:
            log(f"Polling error: {exc}")
            time.sleep(5)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def log(message: str) -> None:
    """Log a message to stderr."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write(f"  [{timestamp}] {message}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_bot()
