#!/usr/bin/env python3

import base64
import json
import os
import pty
import resource
import select
import signal
import struct
import subprocess
import sys
import termios
from fcntl import ioctl


def send_event(event: str, **payload: object) -> None:
    sys.stdout.write(json.dumps({"event": event, **payload}) + "\n")
    sys.stdout.flush()


def decode_config(raw: str) -> dict[str, object]:
    return json.loads(base64.b64decode(raw).decode("utf-8"))


def set_window_size(fd: int, rows: int, cols: int) -> None:
    try:
        ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def attach_controlling_terminal(slave_fd: int) -> None:
    os.setsid()

    try:
        ioctl(slave_fd, termios.TIOCSCTTY, 0)
    except OSError:
        pass

    try:
        os.tcsetpgrp(slave_fd, os.getpgrp())
    except OSError:
        pass


def resolve_signal(name: object) -> int:
    if not isinstance(name, str):
        return signal.SIGTERM

    return int(getattr(signal, name, signal.SIGTERM))


def kill_terminal_group(child_pid: int, signum: int) -> None:
    try:
        target_group = os.getpgid(child_pid)
    except ProcessLookupError:
        return

    try:
        os.killpg(target_group, signum)
    except ProcessLookupError:
        pass


def close_extra_fds() -> None:
    try:
        _, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (OSError, ValueError):
        hard_limit = 256

    max_fd = 256 if hard_limit in (-1, resource.RLIM_INFINITY) else int(min(hard_limit, 4096))
    try:
        os.closerange(3, max_fd)
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        print("missing terminal bridge config", file=sys.stderr)
        return 1

    config = decode_config(sys.argv[1])
    argv = config.get("argv")
    cwd = config.get("cwd")
    env = config.get("env")
    cols = int(config.get("cols", 80))
    rows = int(config.get("rows", 24))

    if not isinstance(argv, list) or not argv or not all(isinstance(entry, str) for entry in argv):
        print("invalid argv", file=sys.stderr)
        return 1

    if not isinstance(cwd, str) or not cwd:
        print("invalid cwd", file=sys.stderr)
        return 1

    if not isinstance(env, dict):
        print("invalid env", file=sys.stderr)
        return 1

    master_fd, slave_fd = pty.openpty()
    set_window_size(slave_fd, rows, cols)
    child = subprocess.Popen(
        argv,
        cwd=cwd,
        env={str(key): str(value) for key, value in env.items()},
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        preexec_fn=lambda: attach_controlling_terminal(slave_fd),
    )
    child_pid = child.pid
    os.close(slave_fd)

    os.set_blocking(master_fd, False)
    os.set_blocking(sys.stdin.fileno(), False)

    def forward_signal(signum: int, _frame: object) -> None:
        kill_terminal_group(child_pid, signum)

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)

    send_event("ready", pid=child_pid)

    stdin_buffer = bytearray()
    stdin_closed = False

    while True:
        child_status = child.poll()

        watched_fds: list[int] = []
        if not stdin_closed:
            watched_fds.append(sys.stdin.fileno())
        if master_fd >= 0:
            watched_fds.append(master_fd)

        if child_status is not None and master_fd < 0:
            break

        readable, _, _ = select.select(watched_fds, [], [], 0.05)
        for fd in readable:
            if fd == master_fd:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""

                if chunk:
                    send_event("output", data=base64.b64encode(chunk).decode("ascii"))
                    continue

                try:
                    os.close(master_fd)
                except OSError:
                    pass
                master_fd = -1
                continue

            try:
                incoming = os.read(sys.stdin.fileno(), 4096)
            except BlockingIOError:
                incoming = b""

            if not incoming:
                stdin_closed = True
                continue

            stdin_buffer.extend(incoming)
            while True:
                newline_index = stdin_buffer.find(b"\n")
                if newline_index < 0:
                    break

                raw_line = bytes(stdin_buffer[:newline_index])
                del stdin_buffer[: newline_index + 1]
                if not raw_line:
                    continue

                try:
                    command = json.loads(raw_line.decode("utf-8"))
                except json.JSONDecodeError:
                    continue

                event = command.get("event")
                if event == "write" and master_fd >= 0:
                    try:
                        payload = base64.b64decode(str(command.get("data", "")))
                        if payload:
                            os.write(master_fd, payload)
                    except OSError:
                        pass
                    continue

                if event == "resize" and master_fd >= 0:
                    set_window_size(master_fd, int(command.get("rows", rows)), int(command.get("cols", cols)))
                    continue

                if event == "signal":
                    kill_terminal_group(child_pid, resolve_signal(command.get("signal")))
                    continue

                if event == "close":
                    kill_terminal_group(child_pid, signal.SIGHUP)
                    if master_fd >= 0:
                        try:
                            os.close(master_fd)
                        except OSError:
                            pass
                        master_fd = -1

    exit_code = child.wait()

    send_event("exit", exitCode=exit_code)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
