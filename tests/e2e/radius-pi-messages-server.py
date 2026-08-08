#!/usr/bin/env python3
"""pi-messages fixture server for the radius e2e.

Asserts the pi-messages request shape (POST /messages, Bearer auth,
model id, context messages, options) and streams a complete event set.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
VALIDATION_OK = "fixture: request shape ok"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        ok = self.validate(body)
        if ok:
            print(VALIDATION_OK, flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        events = [
            {"type": "start"},
            {"type": "text_start", "contentIndex": 0},
            {"type": "text_delta", "contentIndex": 0, "delta": "你好，这是 radius 的回复。"},
            {"type": "text_end", "contentIndex": 0, "content": "你好，这是 radius 的回复。"},
            {
                "type": "done",
                "reason": "stop",
                "responseId": "radius_e2e_1",
                "usage": {"input": 4, "output": 12, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 16},
            },
        ]
        for event in events:
            self.wfile.write(f"data: {json.dumps(event, ensure_ascii=False)}\n\n".encode("utf-8"))
        self.wfile.flush()

    def validate(self, body):
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            print(f"fixture: invalid json body: {body[:200]}", flush=True)
            return False
        if payload.get("model") != "default":
            print(f"fixture: unexpected model {payload.get('model')!r}", flush=True)
            return False
        if self.headers.get("Authorization") != "Bearer radius-e2e-key":
            print(f"fixture: unexpected Authorization {self.headers.get('Authorization')!r}", flush=True)
            return False
        context = payload.get("context", {})
        messages = context.get("messages", [])
        if len(messages) != 1 or messages[0].get("role") != "user":
            print(f"fixture: unexpected messages {messages!r} payload={body}", flush=True)
            return False
        if messages[0].get("content") != "hello":
            print(f"fixture: unexpected message content {messages[0].get('content')!r}", flush=True)
            return False
        options = payload.get("options", {})
        if options.get("maxTokens") != 128:
            print(f"fixture: unexpected options {options!r}", flush=True)
            return False
        return True


server = HTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    server.shutdown()
