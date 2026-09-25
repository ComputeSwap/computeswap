"""Serves the front end on http://127.0.0.1:5173 with caching turned off, so edits show up on the next reload.

    python frontend/serve.py            # or: python frontend/serve.py 8080
"""
import functools
import http.server
import pathlib
import sys


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5173
    handler = functools.partial(NoCacheHandler, directory=str(pathlib.Path(__file__).resolve().parent))
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
        print(f"Serving the app on http://127.0.0.1:{port} (Ctrl+C to stop)")
        server.serve_forever()
