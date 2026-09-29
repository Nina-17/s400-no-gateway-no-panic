#!/usr/bin/env python3
"""Bounded local capture using Apple's signed PacketLogger CLI.

No packet data is printed or uploaded. Capture may contain unrelated Bluetooth
traffic; filter to the target scale before analysis. Output lives in device-logs.
"""
import argparse
from datetime import datetime
from pathlib import Path
import signal
import subprocess
import time
import os


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("--tool", type=Path, required=True,
                        help="Path to packetlogger inside your mounted Apple Additional Tools disk image")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 300:
        parser.error("Capture duration must be 5–300 seconds")
    if not args.tool.is_file():
        parser.error("--tool must point to an existing PacketLogger CLI")
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[1] / "device-logs" / "protocol-captures"
    directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    output = directory / f"mihome-{stamp}.pklg"
    console = output.with_suffix(".capture.log")
    with console.open("xb") as log:
        proc = subprocess.Popen([str(args.tool), "convert", "--udid", args.udid,
                                 "--output", str(output)], stdout=log, stderr=log)
        print(f"Capture process started; device readiness must be verified: {output}", flush=True)
        try:
            proc.wait(timeout=args.seconds)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        size = output.stat().st_size if output.exists() else 0
        print(f"Stopped; bytes={size}; exit={proc.returncode}; capture log={console}", flush=True)
        return 0 if size else 1


if __name__ == "__main__":
    raise SystemExit(main())
