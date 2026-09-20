#!/usr/bin/env python3
"""A forwarding Unix-socket proxy that sits in front of the Docker socket, so a test can break
exactly one of app-server's connections to Docker.

Run as a subprocess:

    python3 docker_socket_proxy.py <listen_socket_path> <target_socket_path> <control_file_path>

Every accepted connection gets its own child process, which appends
``<child pid> <first request line>`` to the control file before forwarding anything, then pumps
bytes both ways until either side closes. A test polls that file to find the child carrying the
request it cares about (e.g. ``POST /images/create``) and signals that child alone: SIGKILL cuts
the connection mid-stream, SIGSTOP leaves it silent past the client's inactivity limit. Docker
itself, the daemon's event stream and every other connection are unaffected - which is what
app-server observes when one of its connections to Docker breaks while Docker keeps running.

Children never install a handler for the signals a test sends them, and reset the parent's
SIGTERM handling to the default, so only the parent's own shutdown unlinks the listening socket.
That shutdown, on SIGTERM, also kills and reaps every connection child still running, stopped
ones included, and exits 0: once the parent has exited, nothing of the proxy forwards.

A harness-owned low-level helper (t/integration/README.md, rule 5), in the same class as the
harness's own ``docker`` subprocess calls: self-contained stdlib Python that never imports the
CLI.
"""

import os
import select
import signal
import socket
import socketserver
import sys

_CHUNK = 65536

# A request line longer than this is not one this proxy is asked to identify, so the read stops
# and the bytes are forwarded as-is rather than buffered without limit.
_MAX_REQUEST_LINE = 65536


class _ProxyHandler(socketserver.BaseRequestHandler):
    """Serves one accepted connection, in its own child process."""

    def handle(self):
        # The parent's shutdown handler unlinks the listening socket; a child inheriting it would
        # unlink it too. The signals a test sends a child (SIGKILL, SIGSTOP) are uncatchable by
        # construction, so nothing else here needs guarding.
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        try:
            self.server.socket.close()
        except OSError:
            pass

        client = self.request
        target = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            try:
                target.connect(self.server.target_path)
            except OSError as e:
                print(f'docker_socket_proxy: cannot connect to {self.server.target_path}: {e}',
                      file=sys.stderr)
                return

            head = self._read_request_line(client)
            if not head:
                return
            self._record(head)
            try:
                target.sendall(head)
            except OSError:
                return
            self._pump(client, target)
        finally:
            try:
                target.close()
            except OSError:
                pass

    def _read_request_line(self, client):
        """Read from `client` until the first CRLF is in hand, and return everything read."""
        buf = b''
        while b'\r\n' not in buf and len(buf) < _MAX_REQUEST_LINE:
            try:
                chunk = client.recv(_CHUNK)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        return buf

    def _record(self, head):
        line = head.split(b'\r\n', 1)[0].decode('utf-8', errors='replace')
        with open(self.server.control_path, 'a', encoding='utf-8') as fh:
            fh.write(f'{os.getpid()} {line}\n')
            fh.flush()

    def _pump(self, client, target):
        ends = {client: target, target: client}
        open_ends = [client, target]
        while open_ends:
            try:
                readable, _, _ = select.select(open_ends, [], [])
            except OSError:
                return
            for sock in readable:
                try:
                    data = sock.recv(_CHUNK)
                except OSError:
                    return
                if not data:
                    return
                try:
                    ends[sock].sendall(data)
                except OSError:
                    return


class _ProxyServer(socketserver.ForkingMixIn, socketserver.UnixStreamServer):
    # One child per connection, and app-server opens a connection per Docker request, so the
    # ceiling is well above the default 40 - reaching it would make the parent block on an
    # accept instead of serving it, which a test would see as Docker hanging.
    max_children = 512
    # A test kills children deliberately, and the parent's SIGTERM handler kills the rest itself;
    # the server's own close never waits on them.
    block_on_close = False

    def __init__(self, listen_path, target_path, control_path):
        self.target_path = target_path
        self.control_path = control_path
        super().__init__(listen_path, _ProxyHandler)

    def handle_error(self, request, client_address):
        # A connection broken by the test is the point of this proxy, not a fault to report.
        pass


def main(argv):
    if len(argv) != 3:
        print(f'usage: {os.path.basename(sys.argv[0])} '
              f'<listen_socket_path> <target_socket_path> <control_file_path>', file=sys.stderr)
        return 2
    listen_path, target_path, control_path = argv

    listen_dir = os.path.dirname(listen_path)
    if listen_dir:
        os.makedirs(listen_dir, exist_ok=True)
    try:
        os.unlink(listen_path)
    except FileNotFoundError:
        pass

    server = _ProxyServer(listen_path, target_path, control_path)
    os.chmod(listen_path, 0o666)

    def _stop(_signum, _frame):
        try:
            server.socket.close()
        except OSError:
            pass
        try:
            os.unlink(listen_path)
        except OSError:
            pass
        # ForkingMixIn keeps the pids of the children it has forked and not yet reaped in
        # active_children (None until the first fork). SIGKILL reaches a child a test left
        # stopped, which SIGTERM would not until it was continued; reaping each one here leaves
        # no zombie for whatever inherits them.
        for pid in list(getattr(server, 'active_children', None) or ()):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                continue
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _stop)
    # A short poll interval keeps the reaping of exited children prompt: serve_forever runs it
    # between polls.
    server.serve_forever(poll_interval=0.2)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
