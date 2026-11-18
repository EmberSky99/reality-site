#!/usr/bin/env python3
"""Exercise Caddy's actual HTTP-01 listener with a local mock ACME service.

The fixture checks challenge reachability, not CA issuance/signature validation.
No public ACME endpoint, domain lookup or production certificate is used.
"""
import base64
import hashlib
import http.client
import http.server
import ipaddress
import json
import pathlib
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def unb64(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def free_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def main():
    caddy, script = map(str, map(pathlib.Path, sys.argv[1:3]))
    # UDP connect only selects the local route/address; it sends no packet.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect(("192.0.2.1", 9))
        external_ip = route.getsockname()[0]
    assert not ipaddress.ip_address(external_ip).is_loopback
    hosts = [external_ip]
    try:
        with socket.socket(socket.AF_INET6) as probe:
            probe.bind(("::1", 0))
        hosts.append("::1")
    except OSError:
        print("SKIP IPv6: unavailable in this test environment")

    domain, token = "reality-ci.example.com", "http01-listener-check"
    complete = threading.Event()
    state = {"thumbprint": None, "error": None, "checks": []}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, data=None, status=200, location=None):
            body = json.dumps(data or {}).encode()
            self.send_response(status)
            self.send_header("Replay-Nonce", uuid.uuid4().hex)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if location:
                self.send_header("Location", location)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.reply()

        def do_GET(self):
            self.reply({"newNonce": origin + "/nonce", "newAccount": origin + "/account",
                        "newOrder": origin + "/orders", "revokeCert": origin + "/revoke",
                        "keyChange": origin + "/key-change"})

        def do_POST(self):
            try:
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/account":
                    key = json.loads(unb64(request["protected"]))["jwk"]
                    fields = ("crv", "kty", "x", "y") if key["kty"] == "EC" else ("e", "kty", "n")
                    canonical = json.dumps({key_name: key[key_name] for key_name in fields}, sort_keys=True, separators=(",", ":")).encode()
                    state["thumbprint"] = base64.urlsafe_b64encode(hashlib.sha256(canonical).digest()).decode().rstrip("=")
                    self.reply({"status": "valid", "orders": origin + "/orders"}, 201, origin + "/account/1")
                elif self.path == "/orders":
                    self.reply({"status": "pending", "identifiers": [{"type": "dns", "value": domain}],
                                "authorizations": [origin + "/authorization"], "finalize": origin + "/finalize"}, 201, origin + "/order/1")
                elif self.path == "/authorization":
                    self.reply({"identifier": {"type": "dns", "value": domain}, "status": "pending",
                                "challenges": [{"type": "http-01", "url": origin + "/challenge", "status": "pending", "token": token}]})
                elif self.path == "/challenge":
                    for host in hosts:
                        connection = http.client.HTTPConnection(host, http_port, timeout=3)
                        try:
                            connection.request("GET", "/.well-known/acme-challenge/" + token, headers={"Host": domain})
                            response = connection.getresponse()
                            body = response.read().decode()
                            assert response.status == 200, (host, response.status)
                            assert body == token + "." + state["thumbprint"], (host, body)
                            state["checks"].append(host)
                        finally:
                            connection.close()
                    self.reply({"type": "http-01", "url": origin + "/challenge", "status": "processing", "token": token})
                    complete.set()
                else:
                    raise AssertionError("Unexpected ACME endpoint: " + self.path)
            except Exception as error:
                state["error"] = repr(error)
                self.reply({"type": "urn:ietf:params:acme:error:connection", "detail": repr(error)}, 400)
                complete.set()

    # EL8's default Python is 3.6, before ThreadingHTTPServer/text=True existed.
    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = Server(("127.0.0.1", 0), Handler)
    ports = set()
    while len(ports) < 2:
        ports.add(free_port())
    http_port, tls_port = sorted(ports)
    origin = "http://127.0.0.1:" + str(server.server_port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="reality-http01-") as temporary:
        work = pathlib.Path(temporary)
        production = subprocess.check_output(["bash", "-c", 'source "$1"; write_caddyfile "$2" "$3"', "bash", script, domain, str(tls_port)], universal_newlines=True)
        adapted = subprocess.check_output([caddy, "adapt", "--adapter", "caddyfile", "--config", "-"], input=production, universal_newlines=True)
        config = json.loads(adapted)
        config["admin"] = {"disabled": True}
        config["storage"] = {"module": "file_system", "root": str(work / "storage")}
        # Preserve the actual adapter's bind_host. Changing it here would hide
        # the exact regression this test is intended to catch.
        for policy in config["apps"]["tls"]["automation"]["policies"]:
            for issuer in policy["issuers"]:
                if issuer["module"] == "acme":
                    issuer["ca"] = origin + "/directory"
                    issuer["test_ca"] = origin + "/directory"
                    issuer.setdefault("challenges", {}).setdefault("http", {})["alternate_port"] = http_port
        path = work / "config.json"
        path.write_text(json.dumps(config))
        log = work / "caddy.log"
        try:
            with log.open("w") as output:
                process = subprocess.Popen([caddy, "run", "--config", str(path)], stdout=output, stderr=subprocess.STDOUT)
                try:
                    assert complete.wait(25), "ACME HTTP-01 challenge did not run"
                    assert state["error"] is None, state["error"]
                    assert state["checks"] == hosts, state
                    with socket.create_connection(("127.0.0.1", tls_port), timeout=2):
                        pass
                    try:
                        connection = socket.create_connection((external_ip, tls_port), timeout=2)
                    except OSError:
                        pass
                    else:
                        connection.close()
                        raise AssertionError("HTTPS backend became publicly bound")
                finally:
                    process.terminate()
                    try:
                        process.wait(10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for _ in range(20):
                try:
                    with socket.create_connection((external_ip, http_port), timeout=.2):
                        pass
                except OSError:
                    break
                time.sleep(.1)
            else:
                raise AssertionError("Challenge listener remained after Caddy stopped")
            print("PASS actual HTTP-01 challenge on non-loopback IPv4" + (" and IPv6" if len(hosts) > 1 else ""))
            print("PASS HTTPS backend stays loopback-only; challenge listener closes on shutdown")
        except BaseException:
            print(log.read_text())
            raise
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
