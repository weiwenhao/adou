#!/usr/bin/env python3
"""Chunked SSE fixture for the RM-TUI-004 regression.

Serves OpenAI-compatible chunked responses (Transfer-Encoding: chunked with
proper chunk framing) for the two requests of one agent turn:
request 1 streams a bash tool call, request 2 streams the final answer.
Every response is chunked to exercise the std http client's chunked_reader
state machine, matching the real DeepSeek transport that SIGBUS'd.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
REQ_DIR = sys.argv[2]
COUNT = {"n": 0}


def chunk(data):
    body = data.encode("utf-8") if isinstance(data, str) else data
    return b"%x\r\n%s\r\n" % (len(body), body)


def sse_chunk(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def tool_stream():
    arguments = json.dumps({"command": "printf 'CHUNKED_TOOL_OK\\n'"}, separators=(",", ":"))
    return b"".join([
        chunk(sse_chunk({"id": "chatcmpl_1", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]})),
        chunk(sse_chunk({"id": "chatcmpl_1", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"content": "ok, checking"}}]})),
        chunk(sse_chunk({"id": "chatcmpl_1", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_1",
                         "type": "function", "function": {"name": "bash", "arguments": arguments}}]}}]})),
        chunk(sse_chunk({"id": "chatcmpl_1", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})),
        chunk(b"data: [DONE]\n\n"),
        b"0\r\n\r\n",
    ])


def final_stream():
    return b"".join([
        chunk(sse_chunk({"id": "chatcmpl_2", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]})),
        chunk(sse_chunk({"id": "chatcmpl_2", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"content": "MASTER_TLS_TOOL_OK"}}]})),
        chunk(sse_chunk({"id": "chatcmpl_2", "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})),
        chunk(b"data: [DONE]\n\n"),
        b"0\r\n\r\n",
    ])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        COUNT["n"] += 1
        with open(REQ_DIR + "/req-%d.json" % COUNT["n"], "w", encoding="utf-8") as out:
            out.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        # One agent turn is two requests (tool call, then final answer); odd
        # requests carry the tool call, even requests the final text, so a
        # session with several prompts keeps alternating.
        if COUNT["n"] % 2 == 1:
            self.wfile.write(tool_stream())
        else:
            self.wfile.write(final_stream())
        self.wfile.flush()


server = HTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    server.shutdown()
