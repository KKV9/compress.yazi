import json
import os
import platform
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path


def download(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": "compress.yazi"})
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    with urllib.request.urlopen(request, timeout=60) as response:
        path.write_bytes(response.read())
    return path


root = Path(".tools").resolve()
root.mkdir(exist_ok=True)
release = download(
    "https://api.github.com/repos/sxyazi/yazi/releases/tags/" + sys.argv[1],
    root / "release.json",
)
arch = "aarch64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
target = {"Linux": "unknown-linux-musl", "Darwin": "apple-darwin", "Windows": "pc-windows-msvc"}[
    platform.system()
]
asset = next(a for a in json.loads(release.read_text())["assets"] if a["name"] == f"yazi-{arch}-{target}.zip")
with zipfile.ZipFile(download(asset["browser_download_url"], root / "yazi.zip")) as archive:
    archive.extractall(root / "yazi")
suffix = ".exe" if os.name == "nt" else ""
yazi = next((root / "yazi").rglob("yazi" + suffix))
for name in ("yazi", "ya"):
    (yazi.parent / (name + suffix)).chmod(0o755)
paths = [str(yazi.parent)]

if os.name == "nt":
    seven = Path(r"C:\Program Files\7-Zip")
    paths.append(str(seven))
    installer = download("https://www.rarlab.com/rar/winrar-x64-723.exe", root / "rar.exe")
    subprocess.run(
        [str(seven / "7z.exe"), "x", "-y", "-o" + str(root / "rar"), str(installer), "Rar.exe"], check=True
    )
else:
    machine = "arm" if arch == "aarch64" else "x64"
    system = "macos" if sys.platform == "darwin" else "linux"
    archive = download(f"https://www.rarlab.com/rar/rar{system}-{machine}-723.tar.gz", root / "rar.tar.gz")
    with tarfile.open(archive) as packed:
        packed.extractall(root / "rar", filter="data")
rar = next((root / "rar").rglob("rar" + suffix))
rar.chmod(0o755)
paths.append(str(rar.parent))
if sys.platform == "darwin":
    paths.append(subprocess.check_output(["brew", "--prefix", "libarchive"], text=True).strip() + "/bin")
with open(os.environ["GITHUB_PATH"], "a") as output:
    output.write("\n".join(paths) + "\n")
