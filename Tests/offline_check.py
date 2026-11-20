"""Drive the actual Codex app-server against a local Responses stream."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Lock, Thread
import json
import os
import shlex
import sys
import subprocess
import time


class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.startswith("/google/models/"):
            self.gemini(body)
            return
        tools = [
            *body.get("tools", []),
            *(tool for item in body.get("input", []) if item.get("type") == "additional_tools"
              for tool in item.get("tools", [])),
        ]
        tool_names = {
            entry.get("name")
            for tool in tools
            for entry in [tool, *tool.get("tools", [])]
        }
        route_keys = {
            "/v1/responses": "sk-offline-synthetic-fixture",
            "/deepseek/responses": "sk-offline-deepseek-only",
            "/kimi/coding/v1/responses": "sk-offline-kimi-only",
        }
        expected_key = route_keys.get(self.path)
        if not expected_key or self.headers.get("Authorization") != f"Bearer {expected_key}":
            self.send_error(401)
            return

        with self.server.lock:
            self.server.requests.append((self.path, body.get("model"), (body.get("reasoning") or {}).get("effort")))
            self.server.tools.append(tool_names)
            request_number = len(self.server.requests)
        user_messages = [item for item in body.get("input", []) if item.get("role") == "user"]
        latest = json.dumps(user_messages[-1], ensure_ascii=False) if user_messages else ""
        if "OFFLINE_LONG_TIMELINE" in latest:
            self.long_timeline(body, request_number)
            return
        for mode in ("RULE", "FULL", "RETURN"):
            if f"OFFLINE_APPROVAL_{mode}" in latest:
                self.approval_turn(body, mode, request_number)
                return
        prompt = json.dumps(body.get("input", []), ensure_ascii=False)
        marker = "A" if "OFFLINE_PARALLEL_A" in prompt else "B"
        if "OFFLINE_MCP_STOP" in latest:
            marker = "MCP_STOP"
        expected_history = {
            "ROOT": ("/v1/responses", ["OFFLINE_SWITCH_ROOT"]),
            "DEEPSEEK": ("/deepseek/responses", ["OFFLINE_SWITCH_ROOT", "switch ROOT complete", "OFFLINE_SWITCH_DEEPSEEK"]),
            "KIMI": ("/kimi/coding/v1/responses", ["OFFLINE_SWITCH_ROOT", "switch ROOT complete",
                      "OFFLINE_SWITCH_DEEPSEEK", "switch DEEPSEEK complete", "OFFLINE_SWITCH_KIMI"]),
            "BACK": ("/v1/responses", ["switch ROOT complete", "switch DEEPSEEK complete", "switch KIMI complete", "switch GEMINI_REUSE complete",
                      "OFFLINE_SWITCH_BACK"]),
            "SAME": ("/v1/responses", ["switch ROOT complete", "switch DEEPSEEK complete",
                     "switch KIMI complete", "switch BACK complete", "OFFLINE_SWITCH_SAME"]),
            "STANDALONE": ("/kimi/coding/v1/responses", ["OFFLINE_SWITCH_STANDALONE"]),
        }
        stage = next((key for key in expected_history if "OFFLINE_SWITCH_" + key in latest), None)
        if stage:
            endpoint, expected = expected_history[stage]
            present = [value for value in expected if value in prompt]
            if stage == "DEEPSEEK":
                result = next((item for item in body.get("input", [])
                               if item.get("type") == "function_call_output" and
                                  item.get("call_id") == "call_offline_provider_environment"), None)
                if result is None:
                    command = ("if /usr/bin/printenv WORKBENCH_PROVIDER_TOKEN >/dev/null; "
                               "then /usr/bin/printf CHECK_EXPOSED; else /usr/bin/printf CHECK_ISOLATED; fi")
                    if "shell_command" in tool_names:
                        name, args = "shell_command", {"command": command}
                    elif "exec_command" in tool_names:
                        name, args = "exec_command", {"cmd": command}
                    else:
                        self.send_error(400, "No native command tool was available")
                        return
                    self.direct_tool_call(body, request_number, name, args)
                    return
                self.server.tool_environment_isolated = "CHECK_ISOLATED" in json.dumps(result.get("output"))
                if not self.server.tool_environment_isolated:
                    self.send_error(400, "The native command did not report credential isolation")
                    return
            with self.server.lock:
                self.server.switches.append((stage, self.path == endpoint, len(present), len(expected)))
            if self.path != endpoint or len(present) != len(expected):
                self.send_error(400, "Wrong provider or missing portable conversation context")
                return
            marker = stage
        response_id = f"resp_offline_{request_number}"
        message_id = f"msg_offline_{request_number}"
        prefix = f"switch {stage}" if stage else f"stream {marker}"
        text = f"{prefix} complete"
        item = {"id": message_id, "type": "message", "role": "assistant", "content": [], "status": "in_progress"}
        part = {"type": "output_text", "text": text, "annotations": []}
        completed = {**item, "content": [part], "status": "completed"}
        initial = {
            "id": response_id, "object": "response", "output": [],
            "status": "in_progress", "created_at": 0, "model": body["model"],
        }
        final = {
            **initial, "status": "completed", "output": [completed],
            "usage": {
                "input_tokens": 17, "output_tokens": 6, "total_tokens": 23,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens_details": {"reasoning_tokens": 0},
            },
        }
        events = [
            ("response.created", {"response": initial}),
            ("response.output_item.added", {"output_index": 0, "item": item}),
            ("response.content_part.added", {"item_id": message_id, "output_index": 0, "content_index": 0, "part": {**part, "text": ""}}),
            ("response.output_text.delta", {"item_id": message_id, "output_index": 0, "content_index": 0, "delta": prefix}),
            ("response.output_text.delta", {"item_id": message_id, "output_index": 0, "content_index": 0, "delta": " complete"}),
            ("response.output_text.done", {"item_id": message_id, "output_index": 0, "content_index": 0, "text": text}),
            ("response.content_part.done", {"item_id": message_id, "output_index": 0, "content_index": 0, "part": part}),
            ("response.output_item.done", {"output_index": 0, "item": completed}),
            ("response.completed", {"response": final}),
        ]
        data = [
            f"event: {kind}\ndata: {json.dumps({'type': kind, 'sequence_number': index, **event})}\n\n".encode()
            for index, (kind, event) in enumerate(events)
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(sum(map(len, data))))
        self.end_headers()
        try:
            self.wfile.write(b"".join(data[:4]))
            self.wfile.flush()
            gate = self.server.directory / f"release-{marker}"
            deadline = time.monotonic() + 20
            while marker in ("A", "B", "ROOT", "MCP_STOP") and not gate.exists() and time.monotonic() < deadline:
                time.sleep(0.035)
            self.wfile.write(b"".join(data[4:]))
        except (BrokenPipeError, ConnectionResetError):
            pass

    def gemini(self, body):
        good = (
            self.path == "/google/models/gemini-4-hydrogen:streamGenerateContent?alt=sse"
            and self.headers.get("x-goog-api-key") == "offline-synthetic-google"
            and self.headers.get("Authorization") is None
            and body.get("generationConfig", {}).get("thinkingConfig") == {"thinkingLevel": "xhigh", "includeThoughts": True}
        )
        parts = [part for message in body["contents"] for part in message["parts"]]
        prompt = json.dumps(parts)
        tools = {tool["name"] for bundle in body.get("tools", []) for tool in bundle["functionDeclarations"]}
        required = ("switch ROOT complete", "switch DEEPSEEK complete", "switch KIMI complete", "OFFLINE_SWITCH_GEMINI")
        if not good or any(text not in prompt for text in required):
            self.server.gemini_steps.append("invalid")
            self.send_error(400, "Gemini path, authentication, effort, or carried history did not match")
            return
        reuse = "OFFLINE_SWITCH_GEMINI_REUSE" in prompt
        tool_outputs = [part["functionResponse"] for part in parts if "functionResponse" in part]
        if not tool_outputs:
            tool = "shell_command" if "shell_command" in tools else "exec_command"
            if tool not in tools or reuse:
                self.send_error(400, "Native shell tool unavailable")
                return
            script = ("/usr/bin/printenv WORKBENCH_PROVIDER_TOKEN >/dev/null || "
                      "/usr/bin/printf GEMINI_TOOL_ISOLATED")
            args = {"command" if tool == "shell_command" else "cmd": script}
            self.server.gemini_steps.append("tool")
            self.gemini_events(
                ([{"text": "Gemini fixture thought", "thought": True}], None),
                ([{"functionCall": {"id": "g_fixture", "name": tool, "args": args},
                   "thoughtSignature": "fixture-call-signature"}], "STOP"),
            )
            return
        tool_call = any(part.get("functionCall", {}).get("id") == "g_fixture"
                        and part.get("thoughtSignature") == "fixture-call-signature" for part in parts)
        result = next((part for part in tool_outputs if part.get("id") == "g_fixture"), None)
        if not tool_call or result is None or "GEMINI_TOOL_ISOLATED" not in json.dumps(result):
            self.send_error(400, "Gemini tool call signature, ID, or result was lost")
            return
        if reuse:
            if not any(part.get("text") == "switch GEMINI complete"
                       and part.get("thoughtSignature") == "fixture-text-signature" for part in parts):
                self.send_error(400, "Gemini text signature was lost on the next turn")
                return
            self.server.gemini_steps.append("reuse")
            self.gemini_events(([{"text": "switch GEMINI_REUSE complete"}], "STOP"))
            return
        self.server.gemini_steps.append("tool-return")
        self.gemini_events(
            ([{"text": "switch GEMINI"}], None),
            ([{"text": " complete", "thoughtSignature": "fixture-text-signature"}], "STOP"),
        )

    def gemini_events(self, *events):
        data = []
        for parts, finish in events:
            candidate = {"content": {"role": "model", "parts": parts}}
            chunk = {"candidates": [candidate]}
            if finish:
                candidate["finishReason"] = finish
                chunk["usageMetadata"] = {"promptTokenCount": 18, "candidatesTokenCount": 4,
                                          "thoughtsTokenCount": 3, "totalTokenCount": 25}
            data.append(f"data: {json.dumps(chunk)}\r\n\r\n".encode())
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(sum(map(len, data))))
        self.end_headers()
        for event in data:
            self.wfile.write(event)
            self.wfile.flush()

    def direct_tool_call(self, body, number, name, args):
        response = {"id": f"resp_direct_tool_{number}", "object": "response", "output": [],
                    "status": "in_progress", "created_at": 0, "model": body["model"]}
        tool = {"id": f"fc_direct_{number}", "type": "function_call", "name": name,
                "call_id": "call_offline_provider_environment", "arguments": json.dumps(args), "status": "completed"}
        events = [
            ("response.created", {"response": response}),
            ("response.output_item.added", {"item": {**tool, "arguments": "", "status": "in_progress"}, "output_index": 0}),
            ("response.output_item.done", {"item": tool, "output_index": 0}),
            ("response.completed", {"response": {**response, "status": "completed", "output": [tool]}}),
        ]
        data = b"".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **event})}\n\n".encode() for kind, event in events)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def long_timeline(self, body, request_number):
        response = {"id": f"resp_timeline_{request_number}", "object": "response", "status": "in_progress",
                    "output": [], "created_at": 0, "model": body["model"]}
        events = [("response.created", {"response": response})]
        outputs = []
        for index in range(672):
            item = {"id": f"msg_timeline_{request_number}_{index}", "type": "message", "role": "assistant",
                    "status": "completed", "content": [{"type": "output_text",
                        "text": f"Long timeline item {index:04d}\n\n" + "A paragraph in the long conversation. " * 8,
                        "annotations": []}]}
            events.extend([
                ("response.output_item.added", {"output_index": index,
                                                "item": {**item, "status": "in_progress", "content": []}}),
                ("response.output_item.done", {"output_index": index, "item": item}),
            ])
            outputs.append(item)
        events.append(("response.completed", {"response": {**response, "status": "completed", "output": outputs}}))
        data = b"".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **event})}\n\n".encode() for kind, event in events)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def approval_turn(self, body, mode, request_number):
        with self.server.lock:
            attempt = self.server.approval_steps.get(mode, 0)
            self.server.approval_steps[mode] = attempt + 1
        response = {"id": f"resp_permissions_{request_number}", "object": "response", "status": "in_progress",
                    "output": [], "created_at": 0, "model": body["model"]}
        events = [("response.created", {"response": response})]
        items = []
        if attempt == 0 and mode == "RULE":
            summary = "先核对当前任务的目录，再执行一项本地检查。"
            reasoning_id = f"rs_permissions_{request_number}"
            part = {"type": "summary_text", "text": summary}
            reason = {"type": "reasoning", "id": reasoning_id, "summary": [part], "status": "completed"}
            events += [
                ("response.output_item.added", {"output_index": 0, "item": {**reason, "summary": []}}),
                ("response.reasoning_summary_part.added", {"item_id": reasoning_id, "output_index": 0,
                                                            "summary_index": 0, "part": {**part, "text": ""}}),
                ("response.reasoning_summary_text.delta", {"item_id": reasoning_id, "output_index": 0,
                                                          "summary_index": 0, "delta": summary}),
                ("response.output_item.done", {"output_index": 0, "item": reason})
            ]
            items.append(reason)

        if attempt < (2 if mode == "RULE" else 1):
            target = self.server.directory / f"permission-{mode.lower()}.txt"
            args = {"cmd": shlex.join(["/usr/bin/touch", str(target)]),
                    "sandbox_permissions": "use_default" if mode == "FULL" else "require_escalated",
                    "justification": "Run this local test action in the temporary fixture."}
            if mode != "FULL":
                args["prefix_rule"] = ["/usr/bin/touch", str(target)]
            output = {"id": f"fc_permissions_{request_number}", "type": "function_call", "status": "completed",
                      "call_id": f"call_permissions_{request_number}", "name": "exec_command",
                      "arguments": json.dumps(args)}
        else:
            output = {"id": f"msg_permissions_{request_number}", "type": "message", "role": "assistant",
                      "status": "completed",
                      "content": [{"type": "output_text", "text": f"{mode} verified", "annotations": []}]}
        events += [
            ("response.output_item.added", {"output_index": len(items), "item": {
                **output, "status": "in_progress", **({"arguments": ""} if "arguments" in output else {"content": []})
            }}),
            ("response.output_item.done", {"output_index": len(items), "item": output})
        ]
        items.append(output)
        events.append(("response.completed", {"response": {**response, "status": "completed", "output": items}}))
        data = b"".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **event})}\n\n".encode() for kind, event in events)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/v1/models" or self.headers.get("Authorization") != "Bearer sk-offline-synthetic-fixture":
            self.send_error(404)
            return
        ids = ["gpt-6.1-sol", "gpt-6-luna", "gpt-6.2-sol", "gpt-6.2-astra", "gpt-realtime"]
        data = json.dumps({"object": "list", "data": [{"id": model} for model in ids]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class FixtureServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exception(), (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, client_address)


@contextmanager
def local_fixture(directory):
    with FixtureServer(("127.0.0.1", 0), Fixture) as server:
        server.directory = Path(directory)
        server.requests = []
        server.tools = []
        server.approval_steps = {}
        server.switches = []
        server.gemini_steps = []
        server.tool_environment_isolated = False
        server.lock = Lock()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            for marker in ("A", "B", "ROOT", "MCP_STOP"):
                (server.directory / f"release-{marker}").touch()
            server.shutdown()
            thread.join()


def main():
    project = Path(__file__).resolve().parents[1]
    app_sources = sorted((project / "Sources/UniCodex").glob("*.swift"))
    with TemporaryDirectory(prefix="unicodex-offline-check-") as directory, local_fixture(directory) as fixture:
        program = Path(directory) / "offline-check"
        subprocess.run(
            [
                "/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-DWORKBENCH_UI_FIXTURE",
                *(str(path) for path in app_sources),
                str(project / "Tests/OfflineCheck.swift"),
                "-o", str(program),
            ],
            check=True,
        )
        env = dict(os.environ)
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            env[name] = "http://127.0.0.1:1"
        env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
        endpoint = f"http://127.0.0.1:{fixture.server_port}/v1"
        catalog = project / "Resources/CodexModels.json"
        result = subprocess.run(
            [str(program), directory, endpoint, str(catalog)],
            env=env,
            timeout=115,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            print(f"Local responses received: {fixture.requests}", flush=True)
            print(f"Context and route checks: {fixture.switches}", flush=True)
            print(f"Gemini steps: {fixture.gemini_steps}", flush=True)
            print(result.stderr.split("Backtrace")[0][:2200], flush=True)
            raise SystemExit(result.returncode)
        assert fixture.requests[:2] == [
            ("/v1/responses", "gpt-6.1-sol", "high"),
            ("/v1/responses", "gpt-6.2-sol", "xhigh"),
        ], fixture.requests
        assert "spawn_agent" in fixture.tools[1], fixture.tools
        assert fixture.approval_steps == {"RULE": 3, "FULL": 2, "RETURN": 1}, fixture.approval_steps
        assert fixture.switches == [("ROOT", True, 1, 1), ("DEEPSEEK", True, 3, 3),
                                    ("KIMI", True, 5, 5), ("BACK", True, 5, 5),
                                    ("SAME", True, 5, 5), ("STANDALONE", True, 1, 1)], fixture.switches
        assert fixture.gemini_steps == ["tool", "tool-return", "reuse"], fixture.gemini_steps
        assert ("/v1/responses", "gpt-6.2-astra", "xhigh") in fixture.requests or any(
            request[:2] == ("/v1/responses", "gpt-6.2-astra") for request in fixture.requests
        )
        assert fixture.tool_environment_isolated
        print(result.stdout, end="")
        print(f"Requests received by localhost: {fixture.requests}")


if __name__ == "__main__":
    main()
