#!/usr/bin/env python3
"""Loopback-only browser qualification fixture; no credentials or external services.

Run: python3 browser_fixture.py --state-directory /absolute/owned/temp/directory
Read port.txt for the allocated port and state.json / requests.jsonl for evidence.
POST /control/rerender replaces existing form controls on its next 50 ms poll.
GET /form?slow=1 uses a submit that is recorded once before its response is delayed.
"""

import argparse
import html
import json
import os
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def serve(directory, port):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = threading.Lock()
    state = {
        "submission_count": 0,
        "download_count": 0,
        "label": "",
        "rerender_generation": 0,
        "observed_generation": 0,
    }

    def save():
        temporary = directory / "state.json.pending"
        temporary.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
        os.replace(temporary, directory / "state.json")

    def record(method, path, **details):
        with (directory / "requests.jsonl").open("a", encoding="utf-8") as output:
            output.write(json.dumps({"method": method, "path": path, **details}, sort_keys=True) + "\n")

    def page(title, content):
        return ("<!doctype html><html lang='en'><meta charset='utf-8'>"
                "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                "<title>" + html.escape(title) + "</title>"
                "<style>body{font:18px system-ui;max-width:760px;margin:60px auto;padding:24px}"
                "button,input,a{font:inherit;margin:12px 6px 12px 0;padding:8px}"
                "label,input{display:block}main{padding:24px;border:1px solid #aaa;border-radius:12px}"
                "</style><main>" + content + "</main></html>")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def respond(self, body, content_type="text/html; charset=utf-8", status=200, headers=None):
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path in ("/state", "/generation"):
                with lock:
                    result = json.dumps(state, sort_keys=True)
                self.respond(result, "application/json")
                return
            with lock:
                record("GET", self.path)
            if parsed.path == "/":
                self.respond(page("Hex browser qualification", "<h1>Local browser workflow</h1>"
                    "<p>This fixture changes only its temporary local state.</p>"
                    "<a href='/form'>Open draft form</a>"
                    "<a href='/details' target='_blank'>Open reference tab</a>"))
            elif parsed.path == "/form":
                slow = parse_qs(parsed.query).get("slow") == ["1"]
                action = "/submit?mode=slow" if slow else "/submit"
                self.respond(page("Controlled draft form", "<h1>Controlled draft form</h1>"
                    "<form method='post' action='" + action + "'>"
                    "<div id='controls'><label for='label'>Draft label</label>"
                    "<input id='label' name='label' required>"
                    "<button type='submit'>Save local draft</button></div></form>"
                    "<button id='refresh' type='button'>Refresh form controls</button>"
                    "<p role='status' id='status'>Form ready.</p>"
                    "<script>let generation=0;"
                    "function replaceControls(){const old=document.getElementById('label').value;"
                    "document.getElementById('controls').innerHTML="
                    "'<label for=label>Draft label</label><input id=label name=label required>' +"
                    "'<button type=submit>Save local draft</button>';"
                    "document.getElementById('label').value=old;"
                    "document.getElementById('status').textContent='Form refreshed. Use current controls.';}"
                    "document.getElementById('refresh').onclick=async()=>{"
                    "await fetch('/control/rerender',{method:'POST'});};"
                    "setInterval(async()=>{try{const s=await(await fetch('/generation')).json();"
                    "if(s.rerender_generation>generation){generation=s.rerender_generation;"
                    "replaceControls();await fetch('/event/rerender?generation='+generation,{method:'POST'});}}"
                    "catch(e){}},50);</script>"))
            elif parsed.path.startswith("/result/"):
                with lock:
                    label = html.escape(state["label"])
                    count = state["submission_count"]
                self.respond(page("Draft saved", "<h1>Draft saved</h1>"
                    "<p role='status'>Saved local draft: " + label + "</p>"
                    "<p>Total submissions: " + str(count) + "</p>"
                    "<a href='/receipt.txt' download>Download draft receipt</a>"
                    "<a href='/details' target='_blank'>Open reference tab</a>"))
            elif parsed.path == "/receipt.txt":
                with lock:
                    state["download_count"] += 1
                    save()
                    receipt = ("HEX_BROWSER_QUALIFICATION_RECEIPT\nlabel=" + state["label"]
                               + "\nsubmissions=" + str(state["submission_count"]) + "\n")
                self.respond(receipt, "text/plain; charset=utf-8", headers={
                    "Content-Disposition": 'attachment; filename="hex-qualification-receipt.txt"'})
            elif parsed.path == "/details":
                self.respond(page("Reference page", "<h1>Reference page</h1>"
                    "<p>Reference marker: HEX_REFERENCE_PAGE_OK</p>"
                    "<p>This second tab belongs to the same local qualification workflow.</p>"))
            else:
                self.respond(page("Not found", "<h1>Not found</h1>"), status=404)

        def do_POST(self):
            parsed = urlparse(self.path)
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.respond("Bad length", status=400)
                return
            if length < 0 or length > 8192:
                self.respond("Body too large", status=413)
                return
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            if parsed.path == "/control/rerender":
                with lock:
                    state["rerender_generation"] += 1
                    save()
                    record("POST", self.path, generation=state["rerender_generation"])
                self.respond("{}", "application/json")
            elif parsed.path == "/event/rerender":
                generation = int(parse_qs(parsed.query).get("generation", ["0"])[0])
                with lock:
                    state["observed_generation"] = generation
                    save()
                    record("POST", parsed.path, generation=generation)
                self.respond("{}", "application/json")
            elif parsed.path == "/submit":
                label = parse_qs(body).get("label", [""])[0][:256]
                with lock:
                    state["submission_count"] += 1
                    state["label"] = label
                    count = state["submission_count"]
                    save()
                    record("POST", self.path, submission_count=count, label=label)
                if parse_qs(parsed.query).get("mode") == ["slow"]:
                    time.sleep(20)
                self.respond("", status=303, headers={"Location": "/result/" + str(count)})
            else:
                self.respond("Not found", status=404)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    with lock:
        save()
    (directory / "port.txt").write_text(str(server.server_address[1]), encoding="utf-8")
    server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    options = parser.parse_args()
    if not options.state_directory.is_absolute():
        parser.error("--state-directory must be an absolute owned temporary directory")
    serve(options.state_directory, options.port)
