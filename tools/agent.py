"""Execute a command through a guest's serial shell using only Python's stdlib.
The guest must run a shell on ttyS0. One command owner per VM; no guest daemon.
"""
import argparse
import json
import secrets
import shlex
import time
import urllib.error
import urllib.request


def execute(api, vm, command, timeout=30):
    base = f"{api.rstrip('/')}/vms/{vm}/console"
    deadline = time.monotonic() + timeout

    def request(url, data=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("guest command deadline exceeded")
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=min(3, remaining)) as r:
            return r.read(), r.headers

    _, headers = request(base)
    cursor = headers["X-Run-Cursor"]
    token = secrets.token_hex(8)
    begin, end = f"RUN_BEGIN_{token}", f"RUN_END_{token}"
    line = f"stty -echo; printf '\\n{begin}\\n'; sh -c {shlex.quote(command)}; printf '\\n{end}:%d\\n' $?\n".encode()
    if len(line) > 3000:
        raise ValueError("command exceeds the serial shell line limit")
    for pos in range(0, len(line), 128):
        while True:
            try:
                request(base, line[pos:pos + 128])
                break
            except urllib.error.HTTPError as e:
                if e.code != 409:
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError("guest input queue did not drain") from e
                time.sleep(0.02)
    output = ""
    while True:
        data, headers = request(base + "?since=" + cursor)
        cursor = headers["X-Run-Cursor"]
        output += data.decode(errors="replace").replace("\r", "")
        if len(output) > 1 << 20:
            raise ValueError("guest output exceeds 1 MiB")
        marker = "\n" + end + ":"
        if marker in output and "\n" in output.split(marker, 1)[1]:
            body, status = output.split(marker, 1)
            return {"stdout": body.split("\n" + begin + "\n", 1)[1], "exit_code": int(status.splitlines()[0])}
        time.sleep(0.02)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command")
    p.add_argument("--api", default="http://127.0.0.1:8080")
    p.add_argument("--vm", type=int, default=0)
    p.add_argument("--timeout", type=float, default=30)
    args = p.parse_args()
    result = execute(args.api, args.vm, args.command, args.timeout)
    print(json.dumps(result))
    raise SystemExit(result["exit_code"])
