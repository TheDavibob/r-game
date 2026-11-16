"""
Download webR and the R packages the challenges need, so the game runs with no
internet connection.

Run once (and again whenever a task starts using a new package):

    python setup_offline.py                 # packages listed in tasks/*/task.json
    python setup_offline.py dplyr tidyr     # ...plus extra packages

Creates:
    vendor/webr/   the webR runtime (R compiled to WebAssembly), ~100 MB unpacked
    vendor/repo/   a mini package repository holding just the packages needed
                   (and their dependencies), in the layout webr::install() expects
"""

import argparse
import glob
import gzip
import io
import json
import os
import re
import shutil
import sys
import tarfile
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(ROOT, "vendor")
WEBR_DIR = os.path.join(VENDOR, "webr")
REPO_DIR = os.path.join(VENDOR, "repo")
DEFAULT_WEBR = "0.6.1"  # keep in step with WEBR_VERSION in js/engine.js
WEBR_REPO = "https://repo.r-wasm.org"

# Packages that ship inside webR itself.
BASE_PKGS = {
    "R", "base", "compiler", "datasets", "grDevices", "graphics", "grid", "methods",
    "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils", "webr",
}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "r-code-quest-setup"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def download_webr(version, force=False):
    marker = os.path.join(WEBR_DIR, ".version")
    if not force and os.path.exists(marker) and open(marker).read().strip() == version:
        print(f"webR {version} already present.")
        return
    url = f"https://github.com/r-wasm/webr/releases/download/v{version}/webr-{version}.tar.gz"
    print(f"Downloading webR {version} (~40 MB)...")
    data = fetch(url)
    if os.path.exists(WEBR_DIR):
        shutil.rmtree(WEBR_DIR)
    os.makedirs(WEBR_DIR)
    skip = (".map", "repl.js", "repl.css", "repl.html")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for m in tar.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) < 2 or not parts[1] or parts[1].endswith(skip):
                continue
            rel = os.path.normpath(parts[1])
            if rel.startswith("..") or os.path.isabs(rel):
                continue  # never write outside vendor/webr
            dest = os.path.join(WEBR_DIR, rel)
            if m.isdir():
                os.makedirs(dest, exist_ok=True)
            elif m.isfile():
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with tar.extractfile(m) as src, open(dest, "wb") as out:
                    shutil.copyfileobj(src, out)
    with open(marker, "w") as f:
        f.write(version)
    print("webR unpacked into vendor/webr/")


def webr_r_version():
    """Read the R version (e.g. '4.6') that this webR build was compiled with."""
    js = open(os.path.join(WEBR_DIR, "webr.mjs"), encoding="utf-8").read()
    for var in re.findall(r"R_VERSION:([\w$]+)", js):
        v = re.search(r"(?<![\w$])" + re.escape(var) + r'="(\d+\.\d+)\.\d+"', js)
        if v:
            return v.group(1)
    sys.exit("Could not work out webR's R version; pass --r-version, e.g. --r-version 4.6")


def parse_packages_file(text):
    db = {}
    for block in re.split(r"\n\s*\n", text.strip()):
        fields, key = {}, None
        for line in block.splitlines():
            if line[:1].isspace() and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, val = line.split(":", 1)
                fields[key] = val.strip()
        if "Package" in fields:
            db[fields["Package"]] = (fields, block)
    return db


def deps_of(fields):
    out = []
    for field in ("Depends", "Imports"):
        for d in fields.get(field, "").split(","):
            name = re.sub(r"\(.*?\)", "", d).strip()
            if name and name not in BASE_PKGS:
                out.append(name)
    return out


def task_packages():
    pkgs = set()
    for path in glob.glob(os.path.join(ROOT, "tasks", "*", "task.json")):
        with open(path, encoding="utf-8") as f:
            pkgs.update(json.load(f).get("packages", []))
    return pkgs


def mirror_packages(wanted, r_version):
    contrib = f"bin/emscripten/contrib/{r_version}"
    print(f"Reading the webR package index for R {r_version}...")
    db = parse_packages_file(fetch(f"{WEBR_REPO}/{contrib}/PACKAGES").decode("utf-8"))

    needed, queue = set(), list(wanted)
    while queue:
        p = queue.pop()
        if p in needed or p in BASE_PKGS:
            continue
        if p not in db:
            print(f"  ! '{p}' is not available for webR - skipping")
            continue
        needed.add(p)
        queue.extend(deps_of(db[p][0]))

    out_dir = os.path.join(REPO_DIR, *contrib.split("/"))
    os.makedirs(out_dir, exist_ok=True)
    keep = set()
    for i, p in enumerate(sorted(needed), 1):
        fname = f"{p}_{db[p][0]['Version']}.tgz"
        keep.add(fname)
        dest = os.path.join(out_dir, fname)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            continue
        print(f"  [{i}/{len(needed)}] {fname}")
        data = fetch(f"{WEBR_REPO}/{contrib}/{fname}")
        with open(dest + ".part", "wb") as f:
            f.write(data)
        os.replace(dest + ".part", dest)

    # Remove outdated package versions left by earlier runs.
    for old in glob.glob(os.path.join(out_dir, "*.tgz")):
        if os.path.basename(old) not in keep:
            os.remove(old)

    index = "\n\n".join(db[p][1].strip() for p in sorted(needed)) + "\n"
    with open(os.path.join(out_dir, "PACKAGES"), "w", encoding="utf-8", newline="\n") as f:
        f.write(index)
    with gzip.open(os.path.join(out_dir, "PACKAGES.gz"), "wb") as f:
        f.write(index.encode("utf-8"))
    print(f"{len(needed)} package(s) mirrored into vendor/repo/: {', '.join(sorted(needed))}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("packages", nargs="*", help="extra R packages to make available offline")
    ap.add_argument("--webr-version", default=DEFAULT_WEBR)
    ap.add_argument("--r-version", help="override the R version used for the package repo, e.g. 4.6")
    ap.add_argument("--force", action="store_true", help="re-download webR even if present")
    args = ap.parse_args()

    download_webr(args.webr_version, args.force)
    r_version = args.r_version or webr_r_version()
    wanted = task_packages() | set(args.packages)
    if wanted:
        mirror_packages(wanted, r_version)
    else:
        print("No packages requested by tasks.")
    print("\nDone. Start the game with:  python serve.py")


if __name__ == "__main__":
    main()
