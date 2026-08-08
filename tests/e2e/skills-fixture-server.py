#!/usr/bin/env python3
"""openai-completions fixture server for the skills e2e.

Captures the request body and answers with a minimal completions stream.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
REQUEST = {}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        REQUEST["body"] = body
        print(body, flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        chunks = [
            'data: {"id":"chatcmpl_s","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}',
            'data: {"id":"chatcmpl_s","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"}}]}',
            'data: {"id":"chatcmpl_s","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}}]}',
            'data: [DONE]',
        ]
        self.wfile.write(("\n\n".join(chunks) + "\n\n").encode("utf-8"))
        self.wfile.flush()

server = HTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    server.shutdown()
