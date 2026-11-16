# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""
Local web server for R Code Quest.

webR can't run from a file:// page, so the game is served from
http://localhost. This server also sends the "cross-origin isolation" headers
that let webR use SharedArrayBuffer, which is what allows a runaway loop to be
interrupted.

Usage:  uv run serve.py [--port 8080] [--no-browser] [--host 127.0.0.1]
   or:  python serve.py ...
"""

import argparse
import http.server
import os
import socketserver
import sys
import threading
import webbrowser

ROOT = os.path.dirname(os.path.abspath(__file__))

TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".md": "text/plain; charset=utf-8",
    ".R": "text/plain; charset=utf-8",
    ".r": "text/plain; charset=utf-8",
    ".wasm": "application/wasm",
    ".so": "application/octet-stream",
    ".gz": "application/octet-stream",
    ".tgz": "application/octet-stream",
    ".data": "application/octet-stream",
    ".metadata": "application/json",
    "": "application/octet-stream",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = TYPES

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def guess_type(self, path):
        # Windows' registry can map .js to text/plain, which breaks ES modules,
        # so use our own table first.
        _, ext = os.path.splitext(path)
        return TYPES.get(ext) or TYPES.get(ext.lower()) or super().guess_type(path)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        if "/vendor/" not in self.path:
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        if self.verbose:
            super().log_message(fmt, *args)

    verbose = False


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1",
                    help="address to listen on (default: this computer only; "
                         "use 0.0.0.0 inside a container)")
    ap.add_argument("--no-browser", action="store_true", help="don't open a browser window")
    ap.add_argument("--verbose", action="store_true", help="log every request")
    args = ap.parse_args()
    Handler.verbose = args.verbose

    # Inside a container the port is fixed by the port mapping, so don't
    # wander to another one.
    ports = range(args.port, args.port + 20) if args.host == "127.0.0.1" else [args.port]
    httpd = None
    for port in ports:
        try:
            httpd = Server((args.host, port), Handler)
            break
        except OSError:
            continue
    if httpd is None:
        sys.exit(f"No free port found starting at {args.port}.")

    # webR needs a "secure context", which plain http only gets on localhost.
    url = f"http://localhost:{port}/"
    offline = os.path.exists(os.path.join(ROOT, "vendor", "webr", "webr.mjs"))
    print(f"R Code Quest is running at {url}", flush=True)
    print("webR: " + ("local copy (works offline)" if offline
                      else "not downloaded - will use the online CDN. Run 'uv run setup_offline.py' for offline play."),
          flush=True)
    print("Press Ctrl+C to stop.")
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
