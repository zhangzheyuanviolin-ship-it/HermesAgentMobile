import copy
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

LISTEN_HOST = os.getenv("API_SERVER_HOST", "127.0.0.1")
LISTEN_PORT = int(os.getenv("API_SERVER_PORT", "8642"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.getenv("HERMES_UPSTREAM_PORT", "8643"))
UPSTREAM_URL = f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}"
ROOT_DIR = "/root/hermes-agent"
PROXY_DIR = Path("/root/.hermes_mobile_proxy")
STATE_DIR = Path("/root/.hermes_mobile_openclaw")
SESSIONS_DIR = STATE_DIR / "sessions"
UPLOADS_DIR = STATE_DIR / "uploads"
WEB_CHAT_FILE = PROXY_DIR / "openclaw_chat.html"

SYSTEM_PROMPT = (
    "You are Hermes Agent on Android. Internal tool progress and internal reasoning are rendered "
    "separately by the client. Keep the final user-facing answer entirely in the normal assistant "
    "content field. Do not emit assistant_process or assistant_final tags. If reasoning fields are "
    "available, keep private planning there instead of mixing it into the final answer."
)

FINAL_CN_STARTS = (
    "以下是", "这是", "最终", "结论", "总结", "汇报", "报告", "结果", "答复", "回复",
    "输出", "建议", "测试报告", "测试结论", "环境详细报告", "详细报告", "完整汇报",
    "检查结果", "检查结果汇总", "总体来看", "你好", "您好", "下面是", "以下内容",
)
FINAL_EN_STARTS = (
    "here is", "here's", "final answer", "summary", "in summary",
    "result", "results", "report", "overall", "to summarize", "hello", "hi ", "here are",
)
PROCESS_PREFIXES = (
    "the user wants", "let me", "i will", "i need to", "i should", "i am going to",
    "i'm going to", "i can see", "now i can", "now i have", "now i will", "first",
    "next", "then", "we need to", "i'll", "好的，我来", "我来操作", "我先", "我来检查",
    "我先检查", "我来加载", "先", "先查看", "先读取", "先检查", "现在", "现在执行", "接下来",
    "然后", "随后", "让我", "我将", "我会", "正在", "开始", "确认", "创建", "读取", "删除",
    "执行", "尝试", "用户要求", "我从 memory", "from memory", "i already have", "无需额外工具调用",
)
TAG_CLEAN_RE = re.compile(
    r"</?(?:assistant_process|assistant_final|think|thinking|reasoning|thought)\b[^>]*>",
    re.IGNORECASE,
)

_child_proc = None
_shutdown = False
SESSION_LOCK = threading.Lock()
RUN_LOCK = threading.Lock()
RUNS = {}
ACTIVE_RUN_BY_SESSION = {}
NON_SERIALIZABLE_RUN_KEYS = {"thread", "response"}


def now_ms():
    return int(time.time() * 1000)


def log(line):
    print(line, flush=True)


def ensure_dirs():
    PROXY_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)


def extract_any_text(value):
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "".join(extract_any_text(item) for item in value)
    if isinstance(value, dict):
        text = extract_any_text(value.get("text"))
        if text:
            return text
        return extract_any_text(value.get("content"))
    return ""


def join_non_empty(parts, separator="\n\n"):
    return separator.join(part.strip() for part in parts if isinstance(part, str) and part.strip()).strip()


def collapse_blank_lines(raw):
    normalized = str(raw or "").replace("\r\n", "\n").replace("\r", "\n")
    normalized = TAG_CLEAN_RE.sub("", normalized)
    normalized = re.sub(r"\n{3,}", "\n\n", normalized)
    return normalized.strip()


def normalize_lead_line(raw_line):
    line = str(raw_line or "").lstrip()
    line = re.sub(r"^[#>\-\*\d\.\)\(\[\]\s]+", "", line)
    line = re.sub(r"^[^A-Za-z0-9\u4e00-\u9fff]+", "", line)
    return line.lstrip()


def looks_like_final_block(block):
    if not block:
        return False
    first_line = normalize_lead_line(str(block).split("\n", 1)[0])
    lower_first = first_line.lower()
    if any(first_line.startswith(word) for word in FINAL_CN_STARTS):
        return True
    if any(lower_first.startswith(word) for word in FINAL_EN_STARTS):
        return True
    if "|------|" in block or "| 类别 |" in block or "| 目标 |" in block:
        return True
    if "### " in block and any(word in block for word in ("报告", "汇报", "总结", "结果")):
        return True
    return False


def looks_like_process_block(block):
    if not block:
        return False
    first_line = normalize_lead_line(str(block).split("\n", 1)[0]).lower()
    if any(first_line.startswith(word.lower()) for word in PROCESS_PREFIXES):
        return True
    return "工具调用:" in str(block)


def remove_duplicate_prefix(prefix_source, text, minimum_overlap=20):
    source = str(prefix_source or "").strip()
    target = str(text or "").strip()
    if not source or not target:
        return target
    max_overlap = min(len(source), len(target), 500)
    for size in range(max_overlap, minimum_overlap - 1, -1):
        if source[-size:] == target[:size]:
            return target[size:].lstrip()
    return target


def normalize_reasoning_and_final(reasoning_text, final_text):
    reasoning = collapse_blank_lines(reasoning_text)
    final_value = collapse_blank_lines(final_text)
    if not reasoning:
        return "", final_value

    blocks = [block.strip() for block in re.split(r"\n\s*\n+", reasoning) if block.strip()]
    if not blocks:
        return "", final_value

    move_index = None
    seen_process_like = False
    for index, block in enumerate(blocks):
        if looks_like_process_block(block):
            seen_process_like = True
            continue
        if seen_process_like and looks_like_final_block(block):
            move_index = index
            break

    if move_index is None and not final_value:
        for index, block in enumerate(blocks):
            if looks_like_final_block(block):
                move_index = index
                break

    if move_index is not None:
        moved = join_non_empty(blocks[move_index:])
        kept = join_non_empty(blocks[:move_index])
        reasoning = kept
        final_value = join_non_empty([moved, remove_duplicate_prefix(moved, final_value)])
    else:
        final_value = remove_duplicate_prefix(reasoning, final_value)

    return collapse_blank_lines(reasoning), collapse_blank_lines(final_value)


def session_file(session_key):
    return SESSIONS_DIR / f"{session_key}.json"


def default_session(session_key):
    timestamp = now_ms()
    return {
        "key": session_key,
        "title": "新聊天",
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "modelProvider": "hermes",
        "model": "hermes-agent",
        "thinkingLevel": "medium",
        "messages": [],
    }


def load_session(session_key):
    path = session_file(session_key)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    data.setdefault("key", session_key)
    data.setdefault("title", "新聊天")
    data.setdefault("createdAt", now_ms())
    data.setdefault("updatedAt", data["createdAt"])
    data.setdefault("modelProvider", "hermes")
    data.setdefault("model", "hermes-agent")
    data.setdefault("thinkingLevel", "medium")
    data.setdefault("messages", [])
    return data


def save_session(session):
    session = copy.deepcopy(session)
    session["updatedAt"] = now_ms()
    path = session_file(session["key"])
    path.write_text(json.dumps(session, ensure_ascii=False, indent=2), encoding="utf-8")
    return session


def create_session(label=""):
    session_key = f"session-{int(time.time())}-{uuid.uuid4().hex[:8]}"
    session = default_session(session_key)
    title = str(label or "").strip()
    if title:
        session["title"] = title[:80]
    save_session(session)
    return session


def latest_text_preview(session):
    messages = session.get("messages") or []
    for row in reversed(messages):
        content = row.get("content") if isinstance(row, dict) else []
        if not isinstance(content, list):
            continue
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = str(item.get("type") or "").strip()
            if item_type == "text":
                text = str(item.get("text") or "").strip()
                if text:
                    parts.append(text)
        preview = join_non_empty(parts, separator=" ")
        if preview:
            preview = re.sub(r"\s+", " ", preview).strip()
            return preview[:180]
    return ""


def derive_title_from_first_user(session):
    messages = session.get("messages") or []
    for row in messages:
        if not isinstance(row, dict) or row.get("role") != "user":
            continue
        content = row.get("content") if isinstance(row.get("content"), list) else []
        preview = join_non_empty(
            [str(item.get("text") or "") for item in content if isinstance(item, dict) and item.get("type") == "text"],
            separator=" ",
        )
        preview = re.sub(r"\s+", " ", preview).strip()
        if preview:
            return preview[:24] + ("..." if len(preview) > 24 else "")
    return session.get("title") or "新聊天"


def list_sessions(limit=200):
    sessions = []
    for path in SESSIONS_DIR.glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        sessions.append({
            "key": str(data.get("key") or path.stem),
            "title": str(data.get("title") or "新聊天"),
            "updatedAtMs": int(data.get("updatedAt") or 0),
            "preview": latest_text_preview(data),
            "modelProvider": str(data.get("modelProvider") or "hermes"),
            "model": str(data.get("model") or "hermes-agent"),
        })
    sessions.sort(key=lambda row: row.get("updatedAtMs") or 0, reverse=True)
    return sessions[: max(1, min(int(limit or 200), 400))]


def build_model_messages(session):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for row in session.get("messages") or []:
        if not isinstance(row, dict):
            continue
        role = str(row.get("role") or "").strip()
        if role not in {"user", "assistant"}:
            continue
        content = row.get("content") if isinstance(row.get("content"), list) else []
        if role == "user":
            text = join_non_empty(
                [str(item.get("text") or "") for item in content if isinstance(item, dict) and item.get("type") == "text"],
                separator="\n\n",
            )
        else:
            text = join_non_empty(
                [str(item.get("text") or "") for item in content if isinstance(item, dict) and item.get("type") == "text"],
                separator="\n\n",
            )
        if text:
            messages.append({"role": role, "content": text})
    return messages


def make_text_item(text):
    return {"type": "text", "text": collapse_blank_lines(text)}


def make_user_message(text):
    return {
        "role": "user",
        "timestamp": now_ms(),
        "content": [make_text_item(text)],
    }


def build_assistant_content(tool_calls, tool_results, thinking_text, final_text):
    content = []
    for entry in tool_calls:
        name = collapse_blank_lines(entry.get("name") or "")
        arguments = entry.get("arguments")
        item = {"type": "toolCall", "name": name or "unknown"}
        if arguments:
            item["arguments"] = arguments
        content.append(item)
    for result in tool_results:
        text = collapse_blank_lines(result.get("text") or "")
        if not text:
            continue
        item = {"type": "toolResult", "text": text}
        if result.get("isError"):
            item["isError"] = True
        content.append(item)
    thinking = collapse_blank_lines(thinking_text)
    if thinking:
        content.append({"type": "thinking", "thinking": thinking})
    final_value = collapse_blank_lines(final_text)
    if final_value:
        content.append({"type": "text", "text": final_value})
    return content


def make_assistant_message(tool_calls, tool_results, thinking_text, final_text):
    return {
        "role": "assistant",
        "timestamp": now_ms(),
        "content": build_assistant_content(tool_calls, tool_results, thinking_text, final_text),
    }


def create_run_context(session_key):
    timestamp = now_ms()
    run_id = f"run-{timestamp}-{uuid.uuid4().hex[:8]}"
    context = {
        "runId": run_id,
        "sessionKey": session_key,
        "status": "queued",
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "completed": False,
        "cancelled": False,
        "error": "",
        "toolCalls": {},
        "toolResults": [],
        "thinkingText": "",
        "finalText": "",
        "response": None,
        "thread": None,
    }
    with RUN_LOCK:
        RUNS[run_id] = context
        ACTIVE_RUN_BY_SESSION[session_key] = run_id
    return context


def get_run(run_id):
    with RUN_LOCK:
        return RUNS.get(run_id)


def get_active_run_for_session(session_key):
    with RUN_LOCK:
        run_id = ACTIVE_RUN_BY_SESSION.get(session_key)
        return RUNS.get(run_id) if run_id else None


def snapshot_run_context(context):
    if not context:
        return None
    data = {}
    for key, value in context.items():
        if key in NON_SERIALIZABLE_RUN_KEYS:
            continue
        data[key] = copy.deepcopy(value)
    return data


def update_run(run_id, **fields):
    with RUN_LOCK:
        context = RUNS.get(run_id)
        if not context:
            return None
        context.update(fields)
        context["updatedAt"] = now_ms()
        return snapshot_run_context(context)


def clear_active_run(run_id, session_key):
    with RUN_LOCK:
        active_run_id = ACTIVE_RUN_BY_SESSION.get(session_key)
        if active_run_id == run_id:
            ACTIVE_RUN_BY_SESSION.pop(session_key, None)


def cleanup_runs():
    cutoff = now_ms() - 30 * 60 * 1000
    with RUN_LOCK:
        removable = []
        for run_id, context in RUNS.items():
            if context.get("completed") and int(context.get("updatedAt") or 0) < cutoff:
                removable.append(run_id)
        for run_id in removable:
            RUNS.pop(run_id, None)
            for session_key, active_run_id in list(ACTIVE_RUN_BY_SESSION.items()):
                if active_run_id == run_id:
                    ACTIVE_RUN_BY_SESSION.pop(session_key, None)


def decode_tool_arguments(raw_arguments):
    text = str(raw_arguments or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        return text


def upsert_tool_calls(context, tool_calls):
    if not isinstance(tool_calls, list):
        return
    for position, item in enumerate(tool_calls):
        if not isinstance(item, dict):
            continue
        index = item.get("index")
        if not isinstance(index, int):
            index = position
        fn = item.get("function") if isinstance(item.get("function"), dict) else {}
        name_piece = extract_any_text(fn.get("name"))
        args_piece = extract_any_text(fn.get("arguments"))
        with RUN_LOCK:
            entry = context["toolCalls"].setdefault(index, {"name": "", "argumentsText": ""})
            if name_piece:
                if not entry["name"]:
                    entry["name"] = name_piece
                elif name_piece not in entry["name"]:
                    entry["name"] += name_piece
            if args_piece:
                entry["argumentsText"] += args_piece
            context["updatedAt"] = now_ms()


def append_tool_result(context, line, is_error=False):
    text = collapse_blank_lines(line)
    if not text:
        return
    with RUN_LOCK:
        rows = context["toolResults"]
        if rows and rows[-1].get("text") == text and rows[-1].get("isError") == is_error:
            return
        rows.append({"text": text, "isError": is_error})
        context["updatedAt"] = now_ms()


def set_thinking_text(context, value, replace=False):
    text = str(value or "")
    with RUN_LOCK:
        if replace:
            context["thinkingText"] = text
        else:
            context["thinkingText"] += text
        context["updatedAt"] = now_ms()


def set_final_text(context, value, replace=False):
    text = str(value or "")
    with RUN_LOCK:
        if replace:
            context["finalText"] = text
        else:
            context["finalText"] += text
        context["updatedAt"] = now_ms()


def current_partial_message(context):
    with RUN_LOCK:
        tool_calls = []
        for index in sorted(context["toolCalls"].keys()):
            row = context["toolCalls"][index]
            tool_calls.append({
                "name": row.get("name") or "unknown",
                "arguments": decode_tool_arguments(row.get("argumentsText") or ""),
            })
        tool_results = copy.deepcopy(context["toolResults"])
        thinking_text = context.get("thinkingText") or ""
        final_text = context.get("finalText") or ""
        cancelled = context.get("cancelled")
    if cancelled:
        return None
    thinking_text, final_text = normalize_reasoning_and_final(thinking_text, final_text)
    content = build_assistant_content(tool_calls, tool_results, thinking_text, final_text)
    if not content:
        return None
    return {
        "role": "assistant",
        "timestamp": context.get("createdAt") or now_ms(),
        "content": content,
    }


def build_history_response(session_key, limit):
    with SESSION_LOCK:
        session = load_session(session_key)
        if not session:
            session = default_session(session_key)
            save_session(session)
    messages = copy.deepcopy(session.get("messages") or [])
    active_run = get_active_run_for_session(session_key)
    if active_run:
        partial = current_partial_message(active_run)
        if partial:
            messages.append(partial)
    if limit and len(messages) > limit:
        messages = messages[-limit:]
    return {
        "sessionKey": session.get("key") or session_key,
        "messages": messages,
        "thinkingLevel": session.get("thinkingLevel") or "medium",
    }


def save_user_message(session_key, message_text):
    with SESSION_LOCK:
        session = load_session(session_key)
        if not session:
            session = default_session(session_key)
        session.setdefault("messages", []).append(make_user_message(message_text))
        if len(session["messages"]) == 1 or session.get("title") == "新聊天":
            session["title"] = derive_title_from_first_user(session)
        return save_session(session)


def finalize_run_success(context):
    run_id = context["runId"]
    session_key = context["sessionKey"]
    with RUN_LOCK:
        tool_calls = []
        for index in sorted(context["toolCalls"].keys()):
            row = context["toolCalls"][index]
            tool_calls.append({
                "name": row.get("name") or "unknown",
                "arguments": decode_tool_arguments(row.get("argumentsText") or ""),
            })
        tool_results = copy.deepcopy(context["toolResults"])
        thinking_text = context.get("thinkingText") or ""
        final_text = context.get("finalText") or ""
        cancelled = context.get("cancelled")
    if cancelled:
        update_run(run_id, status="aborted", completed=True)
        clear_active_run(run_id, session_key)
        return

    thinking_text, final_text = normalize_reasoning_and_final(thinking_text, final_text)
    message = make_assistant_message(tool_calls, tool_results, thinking_text, final_text)
    if not message["content"]:
        message = make_assistant_message(tool_calls, tool_results, "", final_text or "任务已完成，但没有收到可显示的最终回复。")

    with SESSION_LOCK:
        session = load_session(session_key)
        if not session:
            session = default_session(session_key)
        session.setdefault("messages", []).append(message)
        session["title"] = derive_title_from_first_user(session)
        save_session(session)
    update_run(run_id, status="completed", completed=True, thinkingText=thinking_text, finalText=final_text, response=None)
    clear_active_run(run_id, session_key)


def finalize_run_error(context, error_message):
    run_id = context["runId"]
    session_key = context["sessionKey"]
    if context.get("cancelled"):
        update_run(run_id, status="aborted", completed=True, error="")
    else:
        update_run(run_id, status="failed", completed=True, error=str(error_message or "任务失败"), response=None)
    clear_active_run(run_id, session_key)


def forward_tool_progress(context, payload_text):
    try:
        obj = json.loads(payload_text)
    except Exception:
        obj = {"label": payload_text}
    label = collapse_blank_lines(obj.get("label") or "")
    tool = collapse_blank_lines(obj.get("tool") or "")
    emoji = collapse_blank_lines(obj.get("emoji") or "")
    line = join_non_empty([
        f"{emoji} {label}".strip() if label else "",
        f"工具调用: {tool}" if (not label and tool) else "",
    ], separator="\n")
    if line:
        append_tool_result(context, line)


def parse_choice_payload(context, obj):
    if obj.get("error") is not None:
        raise RuntimeError(extract_any_text(obj.get("error")))
    choices = obj.get("choices")
    if not isinstance(choices, list) or not choices:
        return
    choice = choices[0]
    if not isinstance(choice, dict):
        return
    delta = choice.get("delta")
    if isinstance(delta, dict):
        piece = extract_any_text(delta.get("content"))
        if piece:
            set_final_text(context, piece, replace=False)
        reasoning = "".join(extract_any_text(delta.get(key)) for key in ("reasoning", "reasoning_content", "thinking"))
        if reasoning:
            set_thinking_text(context, reasoning, replace=False)
        upsert_tool_calls(context, delta.get("tool_calls"))
    message = choice.get("message")
    if isinstance(message, dict):
        message_piece = extract_any_text(message.get("content"))
        if message_piece:
            set_final_text(context, message_piece, replace=False)
        upsert_tool_calls(context, message.get("tool_calls"))


def execute_run(run_id):
    context = get_run(run_id)
    if not context:
        return
    session_key = context["sessionKey"]
    try:
        with SESSION_LOCK:
            session = load_session(session_key)
            if not session:
                raise RuntimeError("会话不存在")
            messages = build_model_messages(session)
        req = Request(
            f"{UPSTREAM_URL}/v1/chat/completions",
            data=json.dumps({"model": "hermes-agent", "stream": True, "messages": messages}).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
            method="POST",
        )
        update_run(run_id, status="running")
        upstream = urlopen(req, timeout=600)
        update_run(run_id, response=upstream)
        current_event = ""
        data_lines = []

        def flush_frame():
            nonlocal current_event, data_lines
            payload_text = "\n".join(data_lines).strip()
            event_type = current_event.strip()
            current_event = ""
            data_lines = []
            if not payload_text:
                return False
            if payload_text == "[DONE]":
                return True
            if context.get("cancelled"):
                return True
            if event_type == "hermes.tool.progress":
                forward_tool_progress(context, payload_text)
                return False
            try:
                obj = json.loads(payload_text)
            except Exception:
                return False
            parse_choice_payload(context, obj)
            return False

        try:
            for raw_line in upstream:
                if context.get("cancelled"):
                    break
                line = raw_line.decode("utf-8", errors="replace")
                if line in ("\n", "\r\n"):
                    if flush_frame():
                        break
                    continue
                if line.startswith("event:"):
                    current_event = line[6:].strip()
                    continue
                if line.startswith("data:"):
                    data_lines.append(line[5:].strip())
            if data_lines and not context.get("cancelled"):
                flush_frame()
        finally:
            try:
                upstream.close()
            except Exception:
                pass
        finalize_run_success(context)
    except Exception as exc:
        finalize_run_error(context, str(exc))


def wait_for_run_snapshot(run_id, timeout_ms):
    deadline = time.time() + max(1.0, timeout_ms / 1000.0)
    while time.time() < deadline:
        context = get_run(run_id)
        if not context:
            return None, True
        if context.get("completed"):
            return snapshot_run_context(context), False
        time.sleep(0.25)
    context = get_run(run_id)
    return snapshot_run_context(context) if context else None, True


def set_json(handler, status, payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-cache")
    handler.end_headers()
    handler.wfile.write(data)
    handler.wfile.flush()


def set_text(handler, status, text, content_type):
    data = text.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", f"{content_type}; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-cache")
    handler.end_headers()
    handler.wfile.write(data)
    handler.wfile.flush()


def emit_sse(handler, event_name, payload):
    body = json.dumps(payload, ensure_ascii=False)
    frame = f"event: {event_name}\ndata: {body}\n\n".encode("utf-8")
    handler.wfile.write(frame)
    handler.wfile.flush()


def wait_for_port(host, port, timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def stream_pipe(pipe, prefix):
    def worker():
        try:
            for line in iter(pipe.readline, ""):
                if not line:
                    break
                log(prefix + line.rstrip())
        except Exception:
            pass
    threading.Thread(target=worker, daemon=True).start()


def terminate_child(*_args):
    global _shutdown, _child_proc
    _shutdown = True
    proc = _child_proc
    if proc is None:
        return
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=8)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    _child_proc = None


def start_upstream():
    global _child_proc
    ensure_dirs()
    env = os.environ.copy()
    env["API_SERVER_ENABLED"] = "true"
    env["API_SERVER_HOST"] = "127.0.0.1"
    env["API_SERVER_PORT"] = str(UPSTREAM_PORT)
    cmd = ["/bin/bash", "-lc", "cd /root/hermes-agent && source venv/bin/activate && exec python gateway/run.py"]
    _child_proc = subprocess.Popen(
        cmd,
        cwd=ROOT_DIR,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    stream_pipe(_child_proc.stdout, "[UPSTREAM] ")
    stream_pipe(_child_proc.stderr, "[UPSTREAM-ERR] ")
    if not wait_for_port(UPSTREAM_HOST, UPSTREAM_PORT, timeout=60.0):
        raise RuntimeError(f"Upstream gateway did not start on {UPSTREAM_PORT}")
    log(f"[INFO] Hermes proxy connected to upstream on {UPSTREAM_PORT}")


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HermesOpenClawProxy/1.0"

    def log_message(self, *_args):
        return

    def do_GET(self):
        cleanup_runs()
        parsed = urlparse(self.path)
        path = parsed.path
        if path in {"/", "/openclaw-chat"}:
            if not WEB_CHAT_FILE.exists():
                set_text(self, 500, "openclaw_chat.html not found", "text/plain")
                return
            set_text(self, 200, WEB_CHAT_FILE.read_text(encoding="utf-8"), "text/html")
            return
        if path == "/openclaw-api/health":
            set_json(self, 200, {"ok": True})
            return
        if path == "/openclaw-api/gateway/status":
            ok = wait_for_port(UPSTREAM_HOST, UPSTREAM_PORT, timeout=0.2)
            set_json(self, 200, {"ok": True, "gatewayConnected": ok, "source": "hermes-proxy"})
            return
        if path == "/openclaw-api/sessions":
            query = parse_qs(parsed.query or "")
            limit = int((query.get("limit") or ["200"])[0] or "200")
            set_json(self, 200, {"sessions": list_sessions(limit)})
            return
        self.send_error(404, "Not found")

    def do_POST(self):
        cleanup_runs()
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/v1/chat/completions":
            self.handle_openai_proxy()
            return
        if path == "/openclaw-api/history":
            payload = self.read_json_body()
            session_key = str(payload.get("sessionKey") or "").strip()
            if not session_key:
                set_json(self, 400, {"error": "Missing sessionKey"})
                return
            limit = int(payload.get("limit") or 60)
            set_json(self, 200, build_history_response(session_key, limit))
            return
        if path == "/openclaw-api/send":
            payload = self.read_json_body()
            session_key = str(payload.get("sessionKey") or "").strip()
            message = str(payload.get("message") or "").strip()
            if not session_key or not message:
                set_json(self, 400, {"error": "Missing sessionKey and message"})
                return
            active = get_active_run_for_session(session_key)
            if active and not active.get("completed"):
                set_json(self, 409, {"error": "当前会话已有任务在执行，请先等待完成或终止任务。"})
                return
            save_user_message(session_key, message)
            context = create_run_context(session_key)
            thread = threading.Thread(target=execute_run, args=(context["runId"],), daemon=True)
            update_run(context["runId"], thread=thread)
            thread.start()
            set_json(self, 200, {"ok": True, "runId": context["runId"]})
            return
        if path == "/openclaw-api/run/wait":
            payload = self.read_json_body()
            run_id = str(payload.get("runId") or "").strip()
            if not run_id:
                set_json(self, 400, {"error": "Missing runId"})
                return
            timeout_ms = int(payload.get("timeoutMs") or 9000)
            context, timed_out = wait_for_run_snapshot(run_id, timeout_ms)
            if not context:
                set_json(self, 200, {
                    "ok": False,
                    "runId": run_id,
                    "status": "completed",
                    "completed": True,
                    "error": "Run not found",
                    "waiting": False,
                    "source": "run-cache",
                })
                return
            set_json(self, 200, {
                "ok": context.get("error") in {"", None},
                "runId": run_id,
                "status": context.get("status") or "running",
                "completed": bool(context.get("completed")),
                "error": context.get("error") or None,
                "source": "run-cache",
                "waiting": timed_out and not bool(context.get("completed")),
                "retryable": context.get("status") == "reconnecting",
                "revision": int(context.get("updatedAt") or 0),
            })
            return
        if path == "/openclaw-api/watchdog/status":
            payload = self.read_json_body()
            session_key = str(payload.get("sessionKey") or "").strip()
            active = get_active_run_for_session(session_key) if session_key else None
            if not active:
                set_json(self, 200, {
                    "ok": True,
                    "sessionKey": session_key,
                    "activeRun": False,
                    "runId": "",
                    "status": "idle",
                    "rawStatus": "idle",
                    "completed": True,
                    "waiting": False,
                    "staleMs": 0,
                    "revision": 0,
                    "source": "watchdog",
                    "retryable": True,
                    "recommendAction": "idle",
                })
                return
            stale_ms = max(0, now_ms() - int(active.get("updatedAt") or now_ms()))
            set_json(self, 200, {
                "ok": True,
                "sessionKey": session_key,
                "activeRun": True,
                "runId": active.get("runId") or "",
                "status": active.get("status") or "running",
                "rawStatus": active.get("status") or "running",
                "completed": bool(active.get("completed")),
                "waiting": not bool(active.get("completed")),
                "staleMs": stale_ms,
                "revision": int(active.get("updatedAt") or 0),
                "source": "watchdog",
                "retryable": True,
                "recommendAction": "wait",
            })
            return
        if path == "/openclaw-api/heartbeat/trigger":
            payload = self.read_json_body()
            session_key = str(payload.get("sessionKey") or "").strip()
            active = get_active_run_for_session(session_key) if session_key else None
            if active:
                set_json(self, 200, {
                    "ok": True,
                    "runId": active.get("runId") or "",
                    "status": active.get("status") or "running",
                    "source": "active-run",
                    "message": "任务仍在执行，已返回当前运行状态。",
                })
                return
            set_json(self, 200, {
                "ok": True,
                "runId": "",
                "status": "idle",
                "source": "noop",
                "message": "当前没有可恢复的运行任务。",
            })
            return
        if path == "/openclaw-api/run/abort":
            payload = self.read_json_body()
            run_id = str(payload.get("runId") or "").strip()
            session_key = str(payload.get("sessionKey") or "").strip()
            context = get_run(run_id) if run_id else get_active_run_for_session(session_key)
            if not context:
                set_json(self, 200, {"ok": True, "aborted": True, "status": "aborted", "source": "noop"})
                return
            update_run(context["runId"], cancelled=True, status="aborted")
            response = context.get("response")
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass
            clear_active_run(context["runId"], context.get("sessionKey") or session_key)
            set_json(self, 200, {"ok": True, "aborted": True, "status": "aborted", "source": "proxy"})
            return
        if path == "/openclaw-api/attachments/upload-stream":
            query = parse_qs(parsed.query or "")
            file_name = str((query.get("fileName") or ["attachment.bin"])[0] or "attachment.bin")
            safe_name = re.sub(r"[^A-Za-z0-9._-]+", "_", file_name) or "attachment.bin"
            content_length = int(self.headers.get("Content-Length", "0") or "0")
            data = self.rfile.read(content_length)
            target_path = UPLOADS_DIR / f"{int(time.time())}_{uuid.uuid4().hex[:8]}_{safe_name}"
            target_path.write_bytes(data)
            set_json(self, 200, {
                "path": str(target_path),
                "fileName": safe_name,
                "sizeBytes": len(data),
            })
            return
        if path == "/openclaw-api/sessions/new-independent":
            payload = self.read_json_body()
            label = str(payload.get("label") or "").strip()
            session = create_session(label)
            set_json(self, 200, {"sessionKey": session["key"]})
            return
        if path == "/openclaw-api/sessions/reset":
            session = create_session("")
            set_json(self, 200, {"sessionKey": session["key"]})
            return
        if path == "/openclaw-api/sessions/rename":
            payload = self.read_json_body()
            session_key = str(payload.get("sessionKey") or "").strip()
            label = str(payload.get("label") or "").strip()
            if not session_key or not label:
                set_json(self, 400, {"error": "Missing sessionKey and label"})
                return
            with SESSION_LOCK:
                session = load_session(session_key)
                if not session:
                    set_json(self, 404, {"error": "Session not found"})
                    return
                session["title"] = label[:80]
                save_session(session)
            set_json(self, 200, {"ok": True})
            return
        self.send_error(404, "Not found")

    def read_json_body(self):
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        raw_body = self.rfile.read(content_length)
        if not raw_body:
            return {}
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def handle_openai_proxy(self):
        payload = self.read_json_body()
        if payload.get("stream") is True:
            self.handle_streaming_proxy(payload)
        else:
            self.handle_non_stream_proxy(payload)

    def handle_streaming_proxy(self, payload):
        req = Request(
            f"{UPSTREAM_URL}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
            method="POST",
        )
        try:
            upstream = urlopen(req, timeout=600)
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            set_text(self, exc.code, body, "application/json")
            return
        except URLError as exc:
            set_json(self, 502, {"error": {"message": str(exc)}})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        assistant_parts = []
        reasoning_parts = []
        current_event = ""
        data_lines = []

        def flush_frame():
            nonlocal current_event, data_lines
            payload_text = "\n".join(data_lines).strip()
            event_type = current_event.strip()
            current_event = ""
            data_lines = []
            if not payload_text:
                return False
            if payload_text == "[DONE]":
                thinking_text, final_text = normalize_reasoning_and_final("".join(reasoning_parts), "".join(assistant_parts))
                emit_sse(self, "hermes.thinking.final", {"text": thinking_text})
                emit_sse(self, "hermes.final.final", {"text": final_text})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            if event_type == "hermes.tool.progress":
                try:
                    emit_sse(self, "hermes.tool.progress", json.loads(payload_text))
                except Exception:
                    emit_sse(self, "hermes.tool.progress", {"label": payload_text})
                return False
            try:
                obj = json.loads(payload_text)
            except Exception:
                return False
            choices = obj.get("choices")
            if isinstance(choices, list) and choices and isinstance(choices[0], dict):
                choice = choices[0]
                delta = choice.get("delta") if isinstance(choice.get("delta"), dict) else {}
                piece = extract_any_text(delta.get("content"))
                if piece:
                    assistant_parts.append(piece)
                reasoning = "".join(extract_any_text(delta.get(key)) for key in ("reasoning", "reasoning_content", "thinking"))
                if reasoning:
                    reasoning_parts.append(reasoning)
            return False

        try:
            for raw_line in upstream:
                line = raw_line.decode("utf-8", errors="replace")
                if line in ("\n", "\r\n"):
                    if flush_frame():
                        break
                    continue
                if line.startswith("event:"):
                    current_event = line[6:].strip()
                    continue
                if line.startswith("data:"):
                    data_lines.append(line[5:].strip())
            if data_lines:
                flush_frame()
        finally:
            try:
                upstream.close()
            except Exception:
                pass

    def handle_non_stream_proxy(self, payload):
        req = Request(
            f"{UPSTREAM_URL}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            upstream = urlopen(req, timeout=600)
            raw = upstream.read().decode("utf-8", errors="replace")
            status = getattr(upstream, "status", 200)
        except HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            status = exc.code
        except URLError as exc:
            raw = json.dumps({"error": {"message": str(exc)}}, ensure_ascii=False)
            status = 502

        body = raw
        if status < 400:
            try:
                obj = json.loads(raw)
                choices = obj.get("choices")
                if isinstance(choices, list) and choices and isinstance(choices[0], dict):
                    message = choices[0].get("message")
                    if isinstance(message, dict):
                        assistant_text = extract_any_text(message.get("content"))
                        reasoning_text = "".join(extract_any_text(message.get(key)) for key in ("reasoning", "reasoning_content", "thinking"))
                        _, final_text = normalize_reasoning_and_final(reasoning_text, assistant_text)
                        message["content"] = final_text
                        body = json.dumps(obj, ensure_ascii=False)
            except Exception:
                body = raw
        set_text(self, status, body, "application/json")


def main():
    signal.signal(signal.SIGTERM, terminate_child)
    signal.signal(signal.SIGINT, terminate_child)
    ensure_dirs()
    start_upstream()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    log(f"[INFO] Hermes proxy listening on {LISTEN_HOST}:{LISTEN_PORT}")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        terminate_child()


if __name__ == "__main__":
    main()
