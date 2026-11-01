import argparse
import csv
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
import tarfile
import time
from pathlib import Path

p = argparse.ArgumentParser(
    description="Compare archive defaults. Requires GNU time and the archive tools in PATH."
)
p.add_argument("directory", type=Path, help="directory for fixtures and JSON/CSV results")
root = p.parse_args().directory.resolve()
rng = random.Random(42)
repo = Path(__file__).resolve().parents[1]
source = (repo / "main.lua").read_bytes() + (repo / "README.md").read_bytes()
seven = shutil.which("7zz") or shutil.which("7z") or shutil.which("7za")
timer = shutil.which("gtime") or shutil.which("time")
if not seven:
    p.error("7-Zip must be in PATH")
if not timer or b"gnu time" not in subprocess.run([timer, "--version"], capture_output=True).stdout.lower():
    p.error("GNU time is required (install gtime on macOS)")
root.mkdir(parents=True, exist_ok=True)
metadata = {
    "platform": platform.platform(),
    "logical_cpus": os.cpu_count(),
    "source_sha256": hashlib.sha256(source).hexdigest(),
    "size_mib": 32,
    "repetitions": 2,
    "settings": "tool defaults",
    "versions": {},
}
for tool in ("zip", "gzip", "xz", "bzip2", seven):
    result = subprocess.run([tool, "i" if tool == seven else "--version"], capture_output=True)
    metadata["versions"][tool] = (
        (result.stdout + result.stderr).decode(errors="replace").strip().splitlines()[:5]
    )
(root / "metadata.json").write_text(json.dumps(metadata, indent=2))
for case in ["text", "mixed", "random"]:
    d = root / case
    d.mkdir(exist_ok=True)
    for i in range(4):
        block = (
            rng.randbytes(8 * 1024 * 1024)
            if case == "random" or case == "mixed" and i % 2
            else (source * ((8 * 1024 * 1024) // len(source) + 1))[: 8 * 1024 * 1024]
        )
        with (d / f"{i}.bin").open("wb") as f:
            f.write(block)
    for i in range(100):
        (d / f"small-{i}.txt").write_bytes(source[:2048] + str(i).encode())
    with tarfile.open(root / (case + ".tar"), "w") as t:
        t.add(d, arcname="input")
rows = []
for case in ["text", "mixed", "random"]:
    for fmt in ["zip", "gz", "xz", "bz2"]:
        for repeat in range(2):
            for backend in ["native", "7zip"] if repeat == 0 else ["7zip", "native"]:
                dest = root / f"bench.{fmt}"
                dest.unlink(missing_ok=True)
                if fmt == "zip":
                    cmd = (
                        ["zip", "-qr", str(dest), case]
                        if backend == "native"
                        else [seven, "a", "-tzip", "-bso0", str(dest), case]
                    )
                elif backend == "native":
                    cmd = [{"gz": "gzip", "xz": "xz", "bz2": "bzip2"}[fmt], "-c", case + ".tar"]
                else:
                    cmd = [
                        seven,
                        "a",
                        "-t" + {"gz": "gzip", "xz": "xz", "bz2": "bzip2"}[fmt],
                        "-bso0",
                        str(dest),
                        case + ".tar",
                    ]
                metrics = root / "time.txt"
                out = dest.open("wb") if fmt != "zip" and backend == "native" else subprocess.DEVNULL
                start = time.monotonic()
                result = subprocess.run(
                    [timer, "-f", "%M", "-o", str(metrics), *cmd],
                    cwd=root,
                    stdout=out,
                    stderr=subprocess.PIPE,
                )
                elapsed = time.monotonic() - start
                if hasattr(out, "close"):
                    out.close()
                assert result.returncode == 0, (cmd, result.stderr)
                row = dict(
                    case=case,
                    format=fmt,
                    backend=backend,
                    repeat=repeat,
                    seconds=round(elapsed, 4),
                    bytes=dest.stat().st_size,
                    peak_kib=int(metrics.read_text().strip()),
                )
                rows.append(row)
                print(row, flush=True)
                (root / "benchmark.json").write_text(json.dumps(rows, indent=2))
with (root / "benchmark.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=rows[0])
    w.writeheader()
    w.writerows(rows)
