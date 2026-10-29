#!/usr/bin/env python3
"""
ollama_relay.py -- HTTP relay from the Docker bridge to a loopback-bound Ollama,
rewriting commercial model names to the local model on the way through.

Why a relay at all
------------------
Ollama binds to 127.0.0.1:11434, which containers cannot reach. This relay
listens on all interfaces (including the Docker bridge gateway, 172.17.0.1) and
forwards to Ollama.

Why it rewrites model names
---------------------------
FuzzingBrain hardcodes commercial model names (e.g. claude-sonnet-4-5-20250929).
sitecustomize.py rewrites calls made through LiteLLM, but some code paths call
the Anthropic or OpenAI SDKs directly; those reach Ollama with the commercial
name and fail with "model ... not found". 

Configuration (environment variables)
-------------------------------------
RELAY_LISTEN_HOST   default 0.0.0.0
RELAY_LISTEN_PORT   default 11435
RELAY_UPSTREAM      default http://127.0.0.1:11434
RELAY_LOCAL_MODEL   default qwen3-coder:30b
RELAY_REWRITE       comma-separated name prefixes to rewrite
                    default: claude,gpt-,o1,o3,o4,gemini,grok
RELAY_LOG           1 to log each rewrite (default 1)

"""
import http.client
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("RELAY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("RELAY_LISTEN_PORT", "11435"))
UPSTREAM = urllib.parse.urlsplit(os.environ.get("RELAY_UPSTREAM", "http://127.0.0.1:11434"))
LOCAL_MODEL = os.environ.get("RELAY_LOCAL_MODEL", "qwen3-coder:30b")
PREFIXES = tuple(p.strip() for p in os.environ.get(
    "RELAY_REWRITE", "claude,gpt-,o1,o3,o4,gemini,grok").split(",") if p.strip())
LOG = os.environ.get("RELAY_LOG", "1") == "1"

# Headers that apply to a single connection and must not be forwarded.
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host"}


def log(msg):
    if LOG:
        print(f"[relay] {msg}", file=sys.stderr, flush=True)


def maybe_rewrite(body: bytes) -> bytes:
    """Return the body with a commercial model name replaced, or unchanged."""
    if not body:
        return body
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return body
    if not isinstance(data, dict):
        return body
    model = data.get("model")
    if isinstance(model, str) and model.startswith(PREFIXES):
        data["model"] = LOCAL_MODEL
        log(f"rewrote model {model!r} -> {LOCAL_MODEL!r}")
        return json.dumps(data).encode()
    return body


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = maybe_rewrite(self.rfile.read(length) if length else b"")

        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        if body or self.command in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=3600)
        try:
            conn.request(self.command, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()

            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            # Stream the response through and delimit it by closing the connection:
            # works for both fixed-length and streamed upstream responses.
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception as e:  # upstream unreachable, client hung up, ...
            log(f"error proxying {self.command} {self.path}: {e}")
            try:
                self.send_error(502, f"relay error: {e}")
            except Exception:
                pass
        finally:
            conn.close()
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _proxy

    def log_message(self, fmt, *args):  # silence per-request access logs
        pass


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Relay)
    server.daemon_threads = True
    print(f"[relay] listening on {LISTEN_HOST}:{LISTEN_PORT} -> "
          f"{UPSTREAM.geturl()}; rewriting {', '.join(PREFIXES)}* -> {LOCAL_MODEL}",
          file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()