#!/usr/bin/env bash

_run_telegram_python() {
    PROJECT_DIR="$PROJECT_DIR" python3 - <<'PY'
import importlib.util
import os

project_dir = os.environ["PROJECT_DIR"]
module_path = os.path.join(project_dir, "lib/plugins/telegram/bot.py")
spec = importlib.util.spec_from_file_location("telegram_bot", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

exec(os.environ["TELEGRAM_TEST_SCRIPT"], {"bot": module})
PY
}


test_telegram_extracts_caption_text_for_file_messages() {
    local output
    local status=0
    output=$(TELEGRAM_TEST_SCRIPT='message = {"caption": "summarize this pdf", "document": {"file_id": "file-1"}}; print(bot.extract_message_text(message))' _run_telegram_python) || status=$?

    assert_eq "$status" "0" "telegram caption extraction exits successfully"
    assert_eq "$output" "summarize this pdf" "telegram file messages use caption as prompt text"
}


test_telegram_handle_event_sends_document_for_file_events() {
    local output
    local status=0
    output=$(TELEGRAM_TEST_SCRIPT='import json, pathlib, tempfile; captured = {}; tmpdir = pathlib.Path(tempfile.mkdtemp()); artifact = tmpdir / "report.txt"; artifact.write_text("hello from shellia", encoding="utf-8"); bot.send_message = lambda *args, **kwargs: None; bot.send_document = lambda chat_id, file_content, filename, caption=None: captured.update({"chat_id": chat_id, "filename": filename, "caption": caption, "content": file_content.decode("utf-8")}) or {"ok": True}; bot.handle_event(42, {"type": "file", "path": str(artifact), "caption": "Generated report"}); print(json.dumps(captured, sort_keys=True))' _run_telegram_python) || status=$?

    assert_eq "$status" "0" "telegram file event handling exits successfully"
    assert_valid_json "$output" "telegram file event emits captured document payload"
    assert_contains "$output" '"chat_id": 42' "telegram file event targets the right chat"
    assert_contains "$output" '"filename": "report.txt"' "telegram file event sends the artifact filename"
    assert_contains "$output" '"caption": "Generated report"' "telegram file event forwards the caption"
    assert_contains "$output" '"content": "hello from shellia"' "telegram file event sends the artifact content"
}


test_telegram_builds_prompt_without_absolute_file_path() {
    local output
    local status=0
    output=$(TELEGRAM_TEST_SCRIPT='file_info = {"file_type": "document", "mime_type": "application/pdf", "file_size": 12}; prompt = bot.build_prompt_text("summarize", file_info, "report.pdf"); print(prompt)' _run_telegram_python) || status=$?

    assert_eq "$status" "0" "telegram prompt builder exits successfully"
    assert_contains "$output" "summarize" "telegram prompt keeps user instruction"
    assert_contains "$output" "report.pdf" "telegram prompt mentions uploaded filename"
    assert_not_contains "$output" "/tmp/" "telegram prompt hides host filesystem paths"
}


test_telegram_download_file_writes_to_destination() {
    local output
    local status=0
    output=$(TELEGRAM_TEST_SCRIPT='import io, json, pathlib, tempfile; tmpdir = pathlib.Path(tempfile.mkdtemp()); destination = tmpdir / "downloaded.txt"; responses = iter([{"ok": True, "result": {"file_path": "docs/report.txt"}}, b"downloaded payload"]); bot.urllib.request.urlopen = lambda req, timeout=0: io.BytesIO(json.dumps(next(responses)).encode("utf-8")) if str(req.full_url).endswith("/getFile") else io.BytesIO(next(responses)); result = bot.download_file("file-1", destination); print(json.dumps({"result": result, "exists": destination.exists(), "content": destination.read_text(encoding="utf-8")}, sort_keys=True))' _run_telegram_python) || status=$?

    assert_eq "$status" "0" "telegram download to path exits successfully"
    assert_valid_json "$output" "telegram download to path returns JSON"
    assert_contains "$output" '"exists": true' "telegram download writes the file to disk"
    assert_contains "$output" '"content": "downloaded payload"' "telegram download preserves file contents"
    assert_contains "$output" '"result": "report.txt"' "telegram download returns the saved filename"
}
