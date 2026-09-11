#!/usr/bin/env python3
"""Opt-in, tool-free ChatGPT Codex endpoint capability probe.

Uses the existing local Codex file session without refreshing or modifying it.
Never prints credentials, account IDs, response IDs, or generated content.
Each POST is explicit; there are no retries or replacement requests on failure.
Socket timeouts bound this diagnostic only, not SDK generation policy.
"""
import argparse
from enum import Enum
import datetime
import json
import pathlib
import urllib.error
import urllib.request
import uuid

BASE = "https://chatgpt.com/backend-api/codex/responses"


class ProbeMode(str, Enum):
    COMPLETED_CONTROL = "completed_control"
    DROP_AFTER_CREATED = "drop_after_created"
    DROP_MID_TEXT = "drop_mid_text"
    WITHHOLD_TERMINAL = "withhold_terminal"

    def __str__(self):
        return self.value


class ProbeEventType(str, Enum):
    CREATED = "response.created"
    TEXT_DELTA = "response.output_text.delta"
    COMPLETED = "response.completed"
    FAILED = "response.failed"
    INCOMPLETE = "response.incomplete"
    ERROR = "error"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--modes", nargs="+", type=ProbeMode,
                        default=list(ProbeMode), choices=list(ProbeMode))
    args = parser.parse_args()
    tokens = json.loads((pathlib.Path.home() / ".codex/auth.json").read_text())["tokens"]
    headers = {
        "Authorization": "Bearer " + tokens["access_token"],
        "ChatGPT-Account-ID": tokens["account_id"],
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "originator": "codex_cli_rs",
    }
    report = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "endpoint": BASE, "model": "gpt-5.6-sol", "observations": []}

    def record(value):
        report["observations"].append(value)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(value), flush=True)

    def open_request(label, method, suffix="", body=None, extra=None):
        request = urllib.request.Request(BASE + suffix,
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers | (extra or {}), method=method)
        try:
            response = urllib.request.urlopen(request, timeout=45)
            record({"label": label, "method": method, "status": response.status,
                    "content_type": response.headers.get("Content-Type")})
            return response
        except urllib.error.HTTPError as error:
            # Only allowlisted validation text; never echo arbitrary provider bodies.
            raw = error.read(16384).decode(errors="replace")
            known = [text for text in ["Store must be set to false", "Background mode is not supported",
                     "Unsupported parameter: background", "Not Found", "Method Not Allowed"] if text in raw]
            record({"label": label, "method": method, "status": error.code,
                    "content_type": error.headers.get("Content-Type"), "known_messages": known,
                    "server": error.headers.get("Server"),
                    "cf_mitigated": error.headers.get("cf-mitigated"),
                    "challenge_page": any(s in raw.lower() for s in ["just a moment", "cf-chl-", "challenge-platform"])})
        except Exception as error:
            record({"label": label, "transport_error": type(error).__name__})
        return None

    def body(**changes):
        return {"model": report["model"], "instructions": "Follow the user's instructions. Do not use tools.",
                "input": [{"role": "user", "content": [{"type": "input_text",
                    "text": 'Return JSON with value equal to "ok".'}]}],
                "text": {"format": {"type": "json_schema", "name": "probe", "strict": True,
                    "schema": {"type": "object", "properties": {"value": {"type": "string"}},
                               "required": ["value"], "additionalProperties": False}}},
                "reasoning": {"effort": "low"}, "tools": [], "tool_choice": "auto",
                "parallel_tool_calls": False, "store": False, "stream": True,
                "include": ["reasoning.encrypted_content"], **changes}

    def events(response):
        pending = []
        for raw in response:
            line = raw.decode().strip()
            if line.startswith("data:"):
                pending.append(line[5:].strip())
            elif not line and pending:
                data = "\n".join(pending)
                pending = []
                if data != "[DONE]":
                    yield json.loads(data)

    def retrieve(label, response_id, cursor, request_headers):
        for kind, suffix, extra in [
            ("retrieve", "/" + response_id, {}),
            ("cursor", "/" + response_id + "?stream=true&starting_after=" + str(cursor or 0), {}),
            ("last_event_id", "/" + response_id, {"Last-Event-ID": str(cursor or 0)}),
        ]:
            response = open_request(label + "/" + kind, "GET", suffix, extra=request_headers | extra)
            if response:
                response.close()

    for mode in args.modes:
        identity = str(uuid.uuid4())
        request_headers = {"session_id": identity, "x-client-request-id": identity}
        response = open_request(mode, "POST", body=body(prompt_cache_key=identity),
            extra=request_headers)
        if response is None:
            if mode == ProbeMode.COMPLETED_CONTROL:
                return
            continue
        response_id, cursor, terminal, delivered_terminal, count = None, None, False, False, 0
        client_cursor = None
        turn_state = response.headers.get("x-codex-turn-state")
        if turn_state:
            request_headers["x-codex-turn-state"] = turn_state
        try:
            for event in events(response):
                count += 1
                cursor = event.get("sequence_number", cursor)
                response_id = event.get("response", {}).get("id", response_id)
                event_type = event.get("type")
                if event_type in (ProbeEventType.FAILED, ProbeEventType.INCOMPLETE, ProbeEventType.ERROR):
                    record({"label": mode, "terminal_failure": event_type})
                    break
                if event_type == ProbeEventType.COMPLETED:
                    terminal = True
                    delivered_terminal = mode != "withhold_terminal"
                    if delivered_terminal:
                        client_cursor = cursor
                    break
                client_cursor = cursor
                if mode == ProbeMode.DROP_AFTER_CREATED and event_type == ProbeEventType.CREATED:
                    break
                if mode == ProbeMode.DROP_MID_TEXT and event_type == ProbeEventType.TEXT_DELTA:
                    break
        finally:
            response.close()
        record({"label": mode, "events_seen": count, "response_id_received": bool(response_id),
                "last_sequence": cursor, "provider_completion_observed": terminal,
                "client_last_sequence": client_cursor,
                "turn_state_header_received": bool(turn_state),
                "terminal_delivered_to_simulated_client": delivered_terminal})
        if response_id:
            retrieve(mode, response_id, client_cursor, request_headers)
        if mode == ProbeMode.COMPLETED_CONTROL and not terminal:
            return

    for label, changes in [("store_true", {"store": True}), ("background_true", {"background": True})]:
        response = open_request(label, "POST", body=body(**changes))
        if response:
            types = []
            try:
                for event in events(response):
                    types.append(event.get("type"))
                    if event.get("type") in ("response.completed", "response.failed", "error"):
                        break
            finally:
                response.close()
            record({"label": label, "event_types": types})


if __name__ == "__main__":
    main()
