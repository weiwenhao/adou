#!/usr/bin/env python3
"""Rapid streaming fixture for the TUI redraw-storm e2e.

Request 1 streams an assistant delta followed immediately by a bash tool call
(tool result arrives from real local bash execution); request 2 streams the
final answer.  No artificial delays: the deltas are emitted back-to-back so
the TUI's deferred redraw coalesces a maximal burst of stream events.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
REQ_DIR = sys.argv[2]
COUNT = {"n": 0}


def event(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def tool_stream():
    arguments = json.dumps({"command": "printf 'REDRAW_TOOL_OK\\n'"}, separators=(",", ":"))
    return b"".join([
        event({"id": "chatcmpl_1", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]}),
        event({"id": "chatcmpl_1", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"content": "ok, checking"}}]}),
        event({"id": "chatcmpl_1", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_1",
               "type": "function", "function": {"name": "bash", "arguments": arguments}}]}}]}),
        event({"id": "chatcmpl_1", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}),
        b"data: [DONE]\n\n",
    ])


def final_stream():
    return b"".join([
        event({"id": "chatcmpl_2", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]}),
        event({"id": "chatcmpl_2", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {"content": "MASTER_TLS_TOOL_OK"}}]}),
        event({"id": "chatcmpl_2", "object": "chat.completion.chunk",
               "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
        b"data: [DONE]\n\n",
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
        self.send_header("Connection", "close")
        self.end_headers()
        if COUNT["n"] == 1:
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
