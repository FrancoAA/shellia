# Telegram Bot Plugin for Shellia

**Date:** 2026-03-08
**Status:** Implemented

## Overview

Telegram bot interface for shellia, allowing users to interact with the AI shell assistant through Telegram messages. Follows the same plugin architecture as the web serve plugin.

## Architecture

```
lib/plugins/telegram/
├── plugin.sh    # Plugin registration, CLI/REPL commands
└── bot.py       # Python 3 stdlib-only Telegram bot (long polling)
```

### Flow

```
Telegram API          bot.py (long polling)         shellia --web-mode
    |                       |                              |
    |-- getUpdates -------->|                              |
    |   {message, chat_id}  |                              |
    |                       |-- check allowed_users        |
    |                       |-- /reset? -> delete session  |
    |                       |-- /help? -> send help text   |
    |                       |                              |
    |<-- sendChatAction ----|  ("typing")                  |
    |                       |                              |
    |                       |-- spawn subprocess --------->|
    |                       |   shellia --web-mode "msg"   |
    |                       |   env: SESSION_ID=chat_id    |
    |                       |                              |
    |                       |<-- stderr: __SHELLIA_EVENT__ |
    |<-- sendMessage -------|   (tool call notifications)  |
    |                       |                              |
    |                       |<-- stdout: response text ----|
    |<-- sendMessage(s) ----|   (split if >4096 chars)     |
```

## Design Decisions

1. **Stdlib only** - Uses `urllib.request` + `json` for Telegram Bot API. No pip dependencies, consistent with serve plugin.
2. **Long polling** - Uses `getUpdates` with 30s timeout. Each incoming message processed in its own thread.
3. **Session mapping** - Telegram `chat_id` used as `SHELLIA_WEB_SESSION_ID`. Reuses the existing web-mode session infrastructure.
4. **Access control** - `allowed_users` config with comma-separated Telegram user IDs. Empty = open to all (with warning).
5. **Message splitting** - Splits at paragraph boundaries (double newline), then line boundaries, then hard-splits at 4096 chars.
6. **Tool visibility** - Intermediate messages for tool calls with typing indicators.
7. **Bot commands** - `/start` (welcome), `/reset` (clear history), `/help` (usage).
8. **Concurrency** - Per-chat locks prevent concurrent processing for the same conversation. Different chats process in parallel.

## Configuration

Plugin config file: `~/.config/shellia/plugins/telegram/config`

```
bot_token=123456:ABC-DEF...
allowed_users=12345678,87654321
```

Or via CLI args:

```bash
shellia telegram --token "123456:ABC-DEF..." --allowed-users "12345678,87654321"
```

## Usage

```bash
# Start the Telegram bot
shellia telegram

# With inline args
shellia telegram --token "YOUR_BOT_TOKEN" --allowed-users "YOUR_USER_ID"
```

## Setup

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Copy the bot token
3. Get your Telegram user ID (message [@userinfobot](https://t.me/userinfobot))
4. Configure: `mkdir -p ~/.config/shellia/plugins/telegram && echo -e "bot_token=YOUR_TOKEN\nallowed_users=YOUR_ID" > ~/.config/shellia/plugins/telegram/config`
5. Run: `shellia telegram`
