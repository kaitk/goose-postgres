#!/usr/bin/env python3
"""Serves a Unix socket that forwards each connection to a TCP port.

scripts/live.sh runs test/live/socket.goose through a Unix socket with this:
Docker Desktop can't share a socket file between its VM and the host, so
Postgres's own Unix socket isn't reachable from a program outside the
container. The program connects to PATH, as a Postgres socket directory's
.s.PGSQL.<port> file, and this script copies bytes both ways to the
server's TCP port until either side closes. It runs until it is killed.

    scripts/unix-forward.py PATH PORT
"""

import os
import socket
import sys
import threading


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    for s in (src, dst):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def serve(client, port):
    try:
        server = socket.create_connection(("127.0.0.1", port))
    except OSError:
        client.close()
        return
    threading.Thread(target=pipe, args=(server, client), daemon=True).start()
    pipe(client, server)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    path, port = sys.argv[1], int(sys.argv[2])
    if os.path.exists(path):
        os.unlink(path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(16)
    while True:
        client, _ = listener.accept()
        threading.Thread(target=serve, args=(client, port), daemon=True).start()


if __name__ == "__main__":
    main()
