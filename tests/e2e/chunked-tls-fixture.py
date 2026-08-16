#!/usr/bin/env python3
"""HTTPS chunked SSE fixture for the RM-TUI-004 regression.

Same responses as chunked-sse-fixture.py (tool call, then final answer,
both Transfer-Encoding: chunked), served over TLS with a self-signed
certificate to approximate the real DeepSeek transport that SIGBUS'd.
"""
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 0
REQ_DIR = ""
CERT_DIR = ""
COUNT = {"n": 0}


def chunk(data):
    body = data.encode("utf-8") if isinstance(data, str) else data
    return b"%x\r\n%s\r\n" % (len(body), body)


def sse_chunk(value):
    return ("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode()


def tool_stream():
    arguments = json.dumps({"command": "printf 'CHUNKED_TLS_TOOL_OK\\n'"}, separators=(",", ":"))
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
        if COUNT["n"] % 2 == 1:
            self.wfile.write(tool_stream())
        else:
            self.wfile.write(final_stream())
        self.wfile.flush()


def make_cert(cert_dir):
    cert = os.path.join(cert_dir, "cert.pem")
    key = os.path.join(cert_dir, "key.pem")
    if not (os.path.exists(cert) and os.path.exists(key)):
        import subprocess
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
             "-days", "2", "-nodes", "-subj", "/CN=127.0.0.1"],
            check=True, capture_output=True,
        )
    return cert, key


def main():
    global PORT, REQ_DIR, CERT_DIR
    if len(sys.argv) != 4:
        raise SystemExit("usage: chunked-tls-fixture.py PORT REQUEST_DIR CERT_DIR")
    PORT = int(sys.argv[1])
    REQ_DIR = sys.argv[2]
    CERT_DIR = sys.argv[3]
    cert, key = make_cert(CERT_DIR)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
