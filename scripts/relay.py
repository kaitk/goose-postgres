#!/usr/bin/env python3
"""Connects a session test program to a Postgres server, and records the bytes.

Goose has no sockets outside goose-http, and the package does no I/O, so a
test program under test/session/ talks to the server through this relay. It
starts the program with --live, and reads its stdout line by line
(test/wire.goose has the program's side):

    >hex   bytes for the server: sent on the socket
    <      the program wants the server's next bytes: answered on its stdin
           with a line of hex, or "eof" when the server closed
    other  the test's output, passed on to this script's stdout

With --record, it writes what crossed the socket to a capture: records of a
direction byte ('C' from the client, 'S' from the server), a 4-byte
big-endian length, and the bytes, which the program replays under
test/run_tests.py. Exits with the program's exit code.

    scripts/relay.py --port 55432 [--record out.cap] -- program [args]
"""

import argparse
import socket
import struct
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--record", help="write the capture here")
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="seconds to wait for the server's bytes (default 30)")
    ap.add_argument("program", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    program = [a for a in args.program if a != "--"]
    if not program:
        ap.error("no program to run")

    sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    proc = subprocess.Popen(program + ["--live"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True)
    records = []
    closed = False
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line.startswith(">"):
            data = bytes.fromhex(line[1:])
            records.append((b"C", data))
            if not closed:
                sock.sendall(data)
        elif line == "<":
            data = b"" if closed else sock.recv(65536)
            if data:
                records.append((b"S", data))
                proc.stdin.write(data.hex() + "\n")
            else:
                closed = True
                proc.stdin.write("eof\n")
            proc.stdin.flush()
        else:
            print(line, flush=True)
    code = proc.wait()
    sock.close()
    if args.record:
        with open(args.record, "wb") as f:
            for kind, data in records:
                f.write(kind + struct.pack(">I", len(data)) + data)
    sys.exit(code)


if __name__ == "__main__":
    main()
