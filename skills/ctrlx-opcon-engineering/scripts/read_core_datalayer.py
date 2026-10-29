"""Authenticated Data Layer reads/browse/SSE; no PLC write or engineering login."""
import argparse
import json
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Redirect refused; authentication stays on the selected CORE")


def node_path(value):
    if not value or value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/")):
        raise argparse.ArgumentTypeError("Use a nonempty relative Data Layer node path")
    if any(c in value for c in "?,#\r\n\\"):
        raise argparse.ArgumentTypeError("Node path contains a reserved delimiter")
    return value


def readable(value):
    """Decode string-valued provider JSON and omit authentication fields in output."""
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, (dict, list)):
                return readable(parsed)
        except (ValueError, TypeError):
            pass
    if isinstance(value, dict):
        return {k: ("<redacted>" if k.lower() in {
            "password", "passwd", "access_token", "refresh_token", "authorization", "client_secret"
        } else readable(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [readable(v) for v in value]
    return value


class CoreReader:
    def __init__(self, config, expected_host, self_signed=False):
        fields = {e.tag.split("}")[-1]: e.text for e in ET.parse(config).iter() if len(e) == 0}
        if fields.get("Hostname") != expected_host:
            raise ValueError("Target configuration does not match --expect-host")
        parsed = urllib.parse.urlsplit("https://" + expected_host)
        if parsed.hostname != expected_host or parsed.path or parsed.query or parsed.fragment:
            raise ValueError("Expected host must contain only a hostname or IPv4 address")
        self.base = "https://" + expected_host
        context = ssl._create_unverified_context() if self_signed else ssl.create_default_context()
        # Controller traffic stays direct; global proxy/certificate settings are unchanged.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context), NoRedirect())
        body = json.dumps({"name": fields["Username"], "password": fields["Password"]}).encode()
        request = urllib.request.Request(self.base + "/identity-manager/api/v2/auth/token", body,
                                         {"Content-Type": "application/json"}, method="POST")
        with self.opener.open(request, timeout=8) as response:
            self.token = json.load(response)["access_token"]

    def get(self, path, timeout=8, accept="application/json"):
        request = urllib.request.Request(self.base + "/automation/api/v2/" + path,
            headers={"Authorization": "Bearer " + self.token, "Accept": accept}, method="GET")
        return self.opener.open(request, timeout=timeout)

    def read(self, node, mode):
        path = "nodes/" + urllib.parse.quote(node, safe="/")
        if mode != "read":
            path += "?" + urllib.parse.urlencode({"type": mode})
        try:
            with self.get(path) as response:
                return {"node": node, "mode": mode, "httpStatus": response.status, "data": readable(json.load(response))}
        except urllib.error.HTTPError as error:
            return {"node": node, "mode": mode, "httpStatus": error.code}

    def subscribe(self, nodes, seconds, interval_ms, emit):
        query = urllib.parse.urlencode({"nodes": ",".join(nodes), "publishIntervalMs": interval_ms})
        start = time.monotonic()
        updates = 0
        errors = 0
        buffer = b""
        # GET /events owns a connection-scoped stream, not a persistent named resource.
        with self.get("events?" + query, timeout=seconds + 1, accept="text/event-stream") as response:
            if response.headers.get_content_type() != "text/event-stream":
                raise RuntimeError("CORE did not return an SSE stream")
            emit({"kind": "subscription-open", "httpStatus": response.status, "nodes": nodes})
            while time.monotonic() - start < seconds:
                try:
                    chunk = response.read1(8192)
                except (socket.timeout, TimeoutError):
                    break
                if not chunk:
                    break
                buffer += chunk.replace(b"\r", b"")
                if len(buffer) > 1048576:
                    raise RuntimeError("SSE frame exceeds 1 MiB")
                while b"\n\n" in buffer:
                    frame, buffer = buffer.split(b"\n\n", 1)
                    event, payload = "message", []
                    for line in frame.decode("utf-8").splitlines():
                        if line.startswith("event:"):
                            event = line[6:].strip()
                        elif line.startswith("data:"):
                            payload.append(line[5:].lstrip())
                    if not payload:
                        continue
                    updates += event == "update"
                    errors += event == "error"
                    emit({"kind": "event", "event": event, "data": readable("\n".join(payload))})
        emit({"kind": "subscription-closed", "elapsedSeconds": round(time.monotonic() - start, 2),
              "updates": updates, "errors": errors, "automaticReconnect": False})
        return updates > 0 and errors == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-config", type=Path, required=True)
    parser.add_argument("--expect-host", required=True)
    parser.add_argument("--node", type=node_path, action="append", required=True)
    parser.add_argument("--mode", choices=("read", "browse", "metadata", "subscribe"), default="read")
    parser.add_argument("--seconds", type=int, choices=range(1, 31), default=10, metavar="1..30")
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--allow-self-signed", action="store_true",
                        help="Explicitly use the existing local CORE self-signed HTTPS route")
    parser.add_argument("--output", type=Path, help="Optional NEW JSONL file; existing files are never overwritten")
    args = parser.parse_args()
    if not 250 <= args.interval_ms <= 60000:
        parser.error("--interval-ms must be 250..60000")
    output = None
    try:
        if args.output:
            output = args.output.open("x", encoding="utf-8")

        def emit(value):
            value = {"sampledAtUtc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), **value}
            line = json.dumps(value, ensure_ascii=False)
            print(line, flush=True)
            if output:
                output.write(line + "\n")
                output.flush()

        reader = CoreReader(args.target_config, args.expect_host, args.allow_self_signed)
        if args.mode == "subscribe":
            return 0 if reader.subscribe(args.node, args.seconds, args.interval_ms, emit) else 2
        success = True
        for node in args.node:
            result = reader.read(node, args.mode)
            success &= result["httpStatus"] == 200
            emit(result)
        return 0 if success else 2
    except urllib.error.HTTPError as error:
        print("CORE HTTP error: " + str(error.code) + "; no automatic retry", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, RuntimeError, ET.ParseError) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 2
    finally:
        if output:
            output.close()


if __name__ == "__main__":
    raise SystemExit(main())
