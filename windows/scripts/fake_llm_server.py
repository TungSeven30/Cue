"""A stand-in OpenAI-compatible chat-completions server for CI.

Translates each subtitle to "[<target>] <text>". With FAIL_IDS set (a comma
list), any request containing one of those ids gets a 401 the first time,
so a test can interrupt a run and check that the next one resumes. Every
request's segment ids are appended to REQUEST_LOG as one JSON line.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FAIL_IDS = {int(x) for x in os.environ.get("FAIL_IDS", "").split(",") if x}
LOG = os.environ.get("REQUEST_LOG")
failed_once = set()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        system, user = body["messages"][0]["content"], body["messages"][1]["content"]
        target = re.search(r"Target language: (.+?)\.\n", system).group(1)
        segments = json.loads(user.split("Segments:\n", 1)[1])
        ids = [s["id"] for s in segments]
        if LOG:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(ids) + "\n")
        blocked = FAIL_IDS.intersection(ids) - failed_once
        if blocked:
            failed_once.update(blocked)
            self.reply(401, {"error": {"message": "bad key"}})
            return
        content = json.dumps({"segments": [{"id": s["id"], "text": f"[{target}] {s['text']}"} for s in segments]})
        self.reply(200, {"choices": [{"message": {"content": content}, "finish_reason": "stop"}]})

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.serve_forever()
