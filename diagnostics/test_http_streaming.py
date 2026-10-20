#!/usr/bin/env python3
"""Validate the echo server across fragmented input, pipelining and slow reads."""
import argparse
import socket
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmark as b


def request(body, close=False):
    return (b"POST /body HTTP/1.1\r\nHost: localhost\r\nContent-Length: "
            + str(len(body)).encode() + b"\r\nConnection: "
            + (b"close" if close else b"keep-alive") + b"\r\n\r\n" + body)


def response(stream, expected):
    assert stream.readline().split()[1] == b"200"
    headers = {}
    while True:
        line = stream.readline()
        assert line, "response ended inside headers"
        if line == b"\r\n":
            break
        key, value = line.split(b":", 1)
        headers[key.lower()] = value.strip()
    assert int(headers[b"content-length"]) == len(expected)
    assert stream.read(len(expected)) == expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server", type=Path)
    args = parser.parse_args()
    b.prepare_payloads()
    scenario = b.SCENARIOS["body-64k"]
    processes = b.start_servers(b.Server("abla", args.server.resolve()), scenario,
                               18080, 1, {2}, True, 1, 1)
    try:
        b.wait_until_ready(18080, processes, scenario)
        body = bytes(range(256)) * 256
        with socket.create_connection(("127.0.0.1", 18080), timeout=10) as sock:
            stream = sock.makefile("rb")
            encoded = request(body)
            # Include idle gaps with an incomplete header and incomplete body.
            begin = 0
            for end in (17, 1024, 32768, 65536, len(encoded)):
                sock.sendall(encoded[begin:end])
                begin = end
                time.sleep(0.02)
            response(stream, body)
            # A further complete request must work on that same connection.
            sock.sendall(request(b"after-fragments"))
            response(stream, b"after-fragments")
            # Stop reading while pipelining enough data to pressure output.
            payload = bytes(range(256)) * 64
            errors = []
            def send_many():
                try:
                    for _ in range(256):
                        sock.sendall(request(payload))
                except Exception as error:
                    errors.append(error)
            sender = threading.Thread(target=send_many)
            sender.start()
            time.sleep(0.25)
            for _ in range(256):
                response(stream, payload)
            sender.join(timeout=10)
            assert not sender.is_alive() and not errors, errors
            sock.sendall(request(b"final", close=True))
            response(stream, b"final")
            assert stream.read(1) == b""
            stream.close()
        print("PASS fragmented 64 KB body, keep-alive, 256 pipelined responses, slow reader, close")
    finally:
        b.stop_servers(processes)


if __name__ == "__main__":
    main()
