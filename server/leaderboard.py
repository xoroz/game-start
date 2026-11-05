#!/usr/bin/env python3
"""Star Drift leaderboard API. Standard library only (Python 3.8+), scores kept in SQLite.

  GET  /api/scores                                    -> {"top": [{"name", "score", "level"}, ...]}
  POST /api/scores {"name": "ABC", "score": 1234, "level": 5} -> {"rank": 7, "top": [...]}

In production nginx serves the game files and proxies /stardrift/api/ here.
For local testing, --static serves the web build from the same port:
  python3 server/leaderboard.py --static dist/web --port 8000
"""
import argparse
import functools
import json
import os
import re
import sqlite3
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

TOP_N = 5
MAX_SCORE = 10_000_000
POSTS_PER_MINUTE = 10
NAME_RE = re.compile(r"^[A-Z]{3}$")

db_lock = threading.Lock()
recent_posts = {}  # ip -> [timestamps]


def open_db(path):
    db = sqlite3.connect(path, check_same_thread=False)
    db.execute("""CREATE TABLE IF NOT EXISTS scores (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        score INTEGER NOT NULL,
        level INTEGER NOT NULL,
        created_at INTEGER NOT NULL)""")
    db.execute("CREATE INDEX IF NOT EXISTS scores_by_score ON scores (score DESC, id)")
    db.commit()
    return db


def top(db):
    rows = db.execute("SELECT name, score, level FROM scores ORDER BY score DESC, id LIMIT ?", (TOP_N,))
    return [{"name": n, "score": s, "level": l} for n, s, l in rows]


def rate_limited(ip):
    now = time.time()
    stamps = [t for t in recent_posts.get(ip, []) if now - t < 60]
    stamps.append(now)
    recent_posts[ip] = stamps
    return len(stamps) > POSTS_PER_MINUTE


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm"}

    def is_api(self):
        return self.path.split("?")[0].rstrip("/").endswith("/api/scores")

    def client_ip(self):
        # behind nginx the real address arrives in X-Real-IP
        if self.client_address[0] == "127.0.0.1" and self.headers.get("X-Real-IP"):
            return self.headers["X-Real-IP"]
        return self.client_address[0]

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.is_api():
            with db_lock:
                return self.send_json(200, {"top": top(self.server.db)})
        if self.server.static_dir is None:
            return self.send_json(404, {"error": "not found"})
        return super().do_GET()

    def do_POST(self):
        if not self.is_api():
            return self.send_json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > 1024:
                raise ValueError("too large")
            body = json.loads(self.rfile.read(length))
            name, score, level = str(body["name"]).upper(), int(body["score"]), int(body["level"])
            if not NAME_RE.match(name) or not 0 < score <= MAX_SCORE or not 1 <= level <= 999:
                raise ValueError("bad values")
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": "invalid score"})
        with db_lock:
            if rate_limited(self.client_ip()):
                return self.send_json(429, {"error": "slow down"})
            db = self.server.db
            db.execute("INSERT INTO scores (name, score, level, created_at) VALUES (?, ?, ?, ?)",
                       (name, score, level, int(time.time())))
            db.commit()
            new_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]
            rank = db.execute("SELECT COUNT(*) FROM scores WHERE score > ? OR (score = ? AND id < ?)",
                              (score, score, new_id)).fetchone()[0] + 1
            return self.send_json(200, {"rank": rank, "top": top(db)})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--db", default="leaderboard.sqlite3")
    ap.add_argument("--static", help="also serve this folder (local testing)")
    args = ap.parse_args()

    static_dir = os.path.abspath(args.static) if args.static else None
    handler = functools.partial(Handler, directory=static_dir or os.getcwd())
    server = ThreadingHTTPServer((args.host, args.port), handler)
    server.db = open_db(args.db)
    server.static_dir = static_dir
    print(f"Leaderboard on http://{args.host}:{args.port}/api/scores (db: {os.path.abspath(args.db)})")
    server.serve_forever()


if __name__ == "__main__":
    main()
