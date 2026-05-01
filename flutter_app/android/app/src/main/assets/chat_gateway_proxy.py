import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


LISTEN_HOST = os.getenv("API_SERVER_HOST", "127.0.0.1")
LISTEN_PORT = int(os.getenv("API_SERVER_PORT", "8642"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.getenv("HERMES_UPSTREAM_PORT", "8643"))
ROOT_DIR = "/root/hermes-agent"
UPSTREAM_URL = f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}"

FINAL_CN_STARTS = (
    "以下是", "这是", "最终", "结论", "总结", "汇报", "报告", "结果", "答复", "回复",
    "输出", "建议", "测试报告", "测试结论", "环境详细报告", "详细报告", "完整汇报",
    "检查结果", "检查结果汇总", "总体来看",
)
FINAL_EN_STARTS = (
    "here is", "here's", "final answer", "summary", "in summary",
    "result", "results", "report", "overall", "to summarize",
)
PROCESS_PREFIXES = (
    "the user wants", "let me", "i will", "i need to", "i should", "i am going to",
    "i'm going to", "i can see", "now i can", "now i have", "now i will", "first",
    "next", "then", "we need to", "i'll", "好的，我来", "我来操作", "我先", "我来检查",
    "我先检查", "我来加载", "先", "先查看", "先读取", "先检查", "现在", "现在执行", "接下来",
    "然后", "随后", "让我", "我将", "我会", "正在", "开始", "确认", "创建", "读取", "删除",
    "执行", "尝试",
)

TAG_CLEAN_RE = re.compile(
    r"</?(?:assistant_process|assistant_final|think|thinking|reasoning|thought)\b[^>]*>",
    re.IGNORECASE,
)

_child_proc = None
_shutdown = False


def log(line):
    print(line, flush=True)


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


def normalize_lead_line(raw_line):
    line = raw_line.lstrip()
    line = re.sub(r"^[#>\-\*\d\.\)\(\[\]\s]+", "", line)
    line = re.sub(r"^[^A-Za-z0-9\u4e00-\u9fff]+", "", line)
    return line.lstrip()


def looks_like_final_block(block):
    first_line = normalize_lead_line(block.split("\n", 1)[0])
    lower_first = first_line.lower()
    for word in FINAL_CN_STARTS:
        if first_line.startswith(word):
            return True
    for word in FINAL_EN_STARTS:
        if lower_first.startswith(word):
            return True
    if "测试结论" in block or "环境详细报告" in block or "总体来看" in block:
        return True
    if "| 步骤 |" in block or "|------|" in block or "| 类别 |" in block or "| 目标 |" in block:
        return True
    if "### " in block and any(word in block for word in ("报告", "汇报", "总结", "结果")):
        return True
    return False


def contains_final_signal(text):
    return re.search(
        r"(最终|结论|总结|报告|结果|建议|因此|综上|完成|summary|report|overall|final answer)",
        text,
        re.IGNORECASE,
    ) is not None


def looks_like_process_line(line):
    first_line = normalize_lead_line(line)
    lower_first = first_line.lower()
    for word in PROCESS_PREFIXES:
        if lower_first.startswith(word.lower()):
            return True
    return "工具调用:" in line


def split_line_heuristic_output(raw):
    lines = raw.replace("\r\n", "\n").split("\n")
    if not lines:
        return "", ""
    process_lines = []
    final_lines = []
    in_final = False
    for original in lines:
        line = original.rstrip()
        trimmed = line.strip()
        if not trimmed:
            if in_final:
                final_lines.append(line)
            elif process_lines:
                process_lines.append(line)
            continue
        if not in_final and looks_like_final_block(trimmed):
            in_final = True
        if not in_final and looks_like_process_line(trimmed):
            process_lines.append(line)
            continue
        if in_final:
            final_lines.append(line)
        else:
            in_final = True
            final_lines.append(line)
    process = "\n".join(process_lines).strip()
    final_text = "\n".join(final_lines).strip()
    if not final_text:
        return "", raw.strip()
    return process, final_text


def join_unique_non_empty(parts):
    unique = []
    for part in parts:
        trimmed = part.strip()
        if not trimmed:
            continue
        merged = False
        for index, existing in enumerate(unique):
            if existing == trimmed or existing.find(trimmed) >= 0:
                merged = True
                break
            if trimmed.find(existing) >= 0:
                unique[index] = trimmed
                merged = True
                break
        if not merged:
            unique.append(trimmed)
    return "\n\n".join(unique).strip()


def remove_tag_wrappers(raw):
    return TAG_CLEAN_RE.sub("", raw)


def split_structured_output(raw):
    process_match = re.search(r"<assistant_process\b[^>]*>([\s\S]*?)(?:</assistant_process\s*>|$)", raw, re.IGNORECASE)
    final_match = re.search(r"<assistant_final\b[^>]*>([\s\S]*?)(?:</assistant_final\s*>|$)", raw, re.IGNORECASE)
    think_matches = re.findall(
        r"<(?:think|thinking|reasoning|thought)\b[^>]*>([\s\S]*?)(?:</(?:think|thinking|reasoning|thought)\s*>|$)",
        raw,
        re.IGNORECASE,
    )
    process = process_match.group(1).strip() if process_match else ""
    final_text = final_match.group(1).strip() if final_match else ""
    think_process = "\n\n".join(item.strip() for item in think_matches if item.strip()).strip()
    if think_process:
        process = join_unique_non_empty([process, think_process])
    if final_text or process:
        if not final_text:
            cleaned = remove_tag_wrappers(raw).strip()
            final_text = cleaned
        return process, final_text
    return "", ""


def split_heuristic_output(raw):
    normalized = raw.replace("\r\n", "\n").strip()
    if not normalized:
        return "", ""
    blocks = [block.strip() for block in re.split(r"\n\s*\n+", normalized) if block.strip()]
    if not blocks:
        return "", ""
    if len(blocks) < 2:
        return split_line_heuristic_output(normalized)
    for index, block in enumerate(blocks):
        if looks_like_final_block(block):
            return "\n\n".join(blocks[:index]).strip(), "\n\n".join(blocks[index:]).strip()
    leading_process_count = 0
    for block in blocks:
        if looks_like_process_line(block):
            leading_process_count += 1
        else:
            break
    if 0 < leading_process_count < len(blocks):
        remaining = "\n\n".join(blocks[leading_process_count:])
        if leading_process_count >= 2 or contains_final_signal(remaining):
            return (
                "\n\n".join(blocks[:leading_process_count]).strip(),
                remaining.strip(),
            )
    return split_line_heuristic_output(normalized)


def split_tagged_output(raw):
    normalized = raw.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    process, final_text = split_structured_output(normalized)
    if process or final_text:
        return process, final_text
    cleaned = remove_tag_wrappers(normalized).strip()
    return split_heuristic_output(cleaned)


def split_reasoning_output(raw):
    normalized = remove_tag_wrappers(raw.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")).strip()
    if not normalized:
        return "", ""
    blocks = [block.strip() for block in re.split(r"\n\s*\n+", normalized) if block.strip()]
    if not blocks:
        return "", ""
    if len(blocks) < 2:
        return split_line_heuristic_output(normalized)
    for index, block in enumerate(blocks):
        if looks_like_final_block(block):
            return "\n\n".join(blocks[:index]).strip(), "\n\n".join(blocks[index:]).strip()
    leading_process_count = 0
    for block in blocks:
        if looks_like_process_line(block):
            leading_process_count += 1
        else:
            break
    if 0 < leading_process_count < len(blocks):
        remaining = "\n\n".join(blocks[leading_process_count:])
        if leading_process_count >= 2 or contains_final_signal(remaining):
            return (
                "\n\n".join(blocks[:leading_process_count]).strip(),
                remaining.strip(),
            )
    line_process, line_final = split_line_heuristic_output(normalized)
    if line_final:
        return line_process, line_final
    return normalized, ""


def derive_sections(reasoning_text, assistant_text):
    assistant_process, assistant_final = split_tagged_output(assistant_text)
    reasoning_body, reasoning_final = split_reasoning_output(reasoning_text)
    final_fallback = assistant_final.strip()
    if not final_fallback and not assistant_process.strip():
        final_fallback = remove_tag_wrappers(assistant_text).strip()
    return (
        join_unique_non_empty([reasoning_body, assistant_process]),
        join_unique_non_empty([reasoning_final, final_fallback]),
    )


def emit_sse(handler, event_type, payload):
    handler.wfile.write(f"event: {event_type}\n".encode("utf-8"))
    handler.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8"))
    handler.wfile.flush()


def forward_tool_calls(handler, tool_calls):
    if not isinstance(tool_calls, list):
        return
    for item in tool_calls:
        if not isinstance(item, dict):
            continue
        function = item.get("function")
        if not isinstance(function, dict):
            continue
        name = str(function.get("name") or "").strip()
        args = str(function.get("arguments") or "").strip()
        if not name:
            continue
        line = f"工具调用: {name}"
        if args:
            line = f"{line} 参数: {args}"
        emit_sse(handler, "hermes.tool.progress", {"label": line, "tool": name})


def wait_for_port(host, port, timeout=60.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def stream_pipe(src, prefix):
    def runner():
        try:
            for raw_line in iter(src.readline, ""):
                if not raw_line:
                    break
                line = raw_line.rstrip("\n")
                if line:
                    log(f"{prefix}{line}")
        finally:
            try:
                src.close()
            except Exception:
                pass
    threading.Thread(target=runner, daemon=True).start()


def terminate_child(*_args):
    global _shutdown
    _shutdown = True
    proc = _child_proc
    if proc is not None and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404, "Not found")
            return

        content_length = int(self.headers.get("Content-Length", "0") or "0")
        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except Exception:
            self.send_error(400, "Invalid JSON body")
            return

        stream = payload.get("stream") is True
        if stream:
            self.handle_streaming(payload)
        else:
            self.handle_non_stream(payload)

    def handle_streaming(self, payload):
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
            self.send_response(exc.code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body.encode("utf-8"))))
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            self.wfile.flush()
            return
        except URLError as exc:
            body = json.dumps({"error": {"message": str(exc)}}, ensure_ascii=False).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
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
                thinking_text, final_text = derive_sections(
                    "".join(reasoning_parts),
                    "".join(assistant_parts),
                )
                emit_sse(self, "hermes.thinking.final", {"text": thinking_text})
                emit_sse(self, "hermes.final.final", {"text": final_text})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            if event_type == "hermes.tool.progress":
                try:
                    obj = json.loads(payload_text)
                except Exception:
                    obj = {"label": payload_text}
                emit_sse(self, "hermes.tool.progress", obj)
                return False
            try:
                obj = json.loads(payload_text)
            except Exception:
                return False
            if obj.get("error") is not None:
                emit_sse(self, "hermes.error", obj["error"])
                return False
            choices = obj.get("choices")
            if not isinstance(choices, list) or not choices:
                return False
            choice = choices[0]
            if not isinstance(choice, dict):
                return False
            delta = choice.get("delta")
            if isinstance(delta, dict):
                piece = extract_any_text(delta.get("content"))
                if piece:
                    assistant_parts.append(piece)
                reasoning = "".join(
                    extract_any_text(delta.get(key))
                    for key in ("reasoning", "reasoning_content", "thinking")
                ).strip()
                if reasoning:
                    reasoning_parts.append(reasoning)
                forward_tool_calls(self, delta.get("tool_calls"))
            message = choice.get("message")
            if isinstance(message, dict):
                msg_piece = extract_any_text(message.get("content"))
                if msg_piece:
                    assistant_parts.append(msg_piece)
                forward_tool_calls(self, message.get("tool_calls"))
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
                elif line.startswith("data:"):
                    data_lines.append(line[5:].strip())
            if data_lines:
                flush_frame()
        finally:
            try:
                upstream.close()
            except Exception:
                pass

    def handle_non_stream(self, payload):
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
                        reasoning_text = "".join(
                            extract_any_text(message.get(key))
                            for key in ("reasoning", "reasoning_content", "thinking")
                        )
                        _, final_text = derive_sections(reasoning_text, assistant_text)
                        message["content"] = final_text
                        body = json.dumps(obj, ensure_ascii=False)
            except Exception:
                body = raw

        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()


def start_upstream():
    global _child_proc
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


def main():
    signal.signal(signal.SIGTERM, terminate_child)
    signal.signal(signal.SIGINT, terminate_child)
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
