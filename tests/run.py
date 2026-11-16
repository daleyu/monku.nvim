#!/usr/bin/env python3
"""Run isolated Neovim tests. Use --tui for a PTY and --snacks PATH for real Snacks tests."""

import argparse
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time


def run(suite, tui, snacks):
    repo = Path(__file__).resolve().parent.parent
    # Resolve symlinks (macOS /var -> /private/var) so the suites' stdpath-under-cwd checks hold.
    with tempfile.TemporaryDirectory(prefix="monku-test-", dir=os.path.realpath(tempfile.gettempdir())) as tmp:
        env = dict(os.environ, REPO=str(repo), OUT="results.txt", TERM="xterm-256color")
        for kind in ("DATA", "STATE", "CACHE", "CONFIG"):
            env[f"XDG_{kind}_HOME"] = f"{tmp}/{kind.lower()}"
        if snacks:
            env["SNACKS"] = str(Path(snacks).resolve())
        cmd = ["nvim", "-i", "NONE", "-u", "NONE"]
        if not tui:
            cmd.append("--headless")
        env["MONKU_TEST"] = str(repo / "tests" / f"{suite}.lua")
        cmd += ["-c", "lua local ok, err = pcall(dofile, vim.env.MONKU_TEST); if not ok then print(err); vim.cmd.cquit() end"]
        if tui:
            master, slave = pty.openpty()
            # Keep the master open: script(1) with closed stdin injects Ctrl-D into Snacks.
            proc = subprocess.Popen(cmd, cwd=tmp, env=env, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = bytearray()
            deadline = time.monotonic() + 120
            try:
                while proc.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            break
                if proc.poll() is None:
                    proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                raise RuntimeError(f"{suite}: Neovim timed out")
            finally:
                os.close(master)
        else:
            proc = subprocess.run(cmd, cwd=tmp, env=env, capture_output=True, timeout=120)
            output = proc.stdout + proc.stderr
        result = Path(tmp, "results.txt")
        report = result.read_text() if result.exists() else ""
        print(f"{suite} ({'TUI' if tui else 'headless'}): {report.strip().splitlines()[-1] if report else 'no report'}")
        if proc.returncode or "FAIL" in report or not report:
            print(report)
            print(bytes(output).decode(errors="replace")[-4000:])
            raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tui", action="store_true")
    parser.add_argument("--snacks", help="path to an existing snacks.nvim checkout (runs its TUI suite)")
    args = parser.parse_args()
    run("selectors", args.tui, None)
    run("editor", args.tui, None)
    run("submit", args.tui, None)
    if args.snacks:
        run("snacks", True, args.snacks)
