#!/usr/bin/env python3
"""Download one pinned ChEMBL release file and verify its SHA-256 checksum.

The dataset is ChEMBL release 37, file chembl_37_chemreps.txt.gz (one row per
compound: ChEMBL ID, canonical SMILES, InChI, InChIKey). Source, license and
checksum are recorded in data/README.md.

The URL points at the fixed release folder (releases/chembl_37/), not at
"latest/", so the file cannot change under us when ChEMBL publishes a new
release. The expected checksum is taken from that folder's checksums.txt.

Uses only the Python standard library.

Usage:
    python scripts/fetch_data.py                 # download into data/
    python scripts/fetch_data.py --verify-only   # only check an existing file
"""

import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

RELEASE = "37"
FILENAME = f"chembl_{RELEASE}_chemreps.txt.gz"
URL = (
    "https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/"
    f"chembl_{RELEASE}/{FILENAME}"
)
# From https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/chembl_37/checksums.txt
SHA256 = "ea6181ce8dc7af41974e35b92e1febb0c9dcbe2c62f7ccc4a5d983ac19f696e7"
SIZE_BYTES = 292_540_141

REPO_ROOT = Path(__file__).resolve().parent.parent
CHUNK = 1024 * 1024  # read and hash 1 MiB at a time


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, dest: Path) -> str:
    """Stream url to dest, printing progress. Returns the SHA-256 of the bytes."""
    h = hashlib.sha256()
    done = 0
    next_report = 0.1
    with urllib.request.urlopen(url, timeout=60) as resp, dest.open("wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        for block in iter(lambda: resp.read(CHUNK), b""):
            out.write(block)
            h.update(block)
            done += len(block)
            if total and done / total >= next_report:
                print(f"  {done / total:4.0%}  ({done:,} / {total:,} bytes)", flush=True)
                next_report += 0.1
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--dest-dir",
        type=Path,
        default=REPO_ROOT / "data",
        help="folder to save the file in (default: data/ in the repository)",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="do not download; only check the checksum of an existing file",
    )
    args = parser.parse_args()

    target = args.dest_dir / FILENAME
    print(f"ChEMBL release {RELEASE}: {FILENAME}")
    print(f"Expected SHA-256: {SHA256}")

    if target.exists():
        print(f"Found existing file {target}, checking it ...")
        actual = sha256_of(target)
        if actual == SHA256:
            print("Checksum OK. Nothing to do.")
            return 0
        print(f"Checksum MISMATCH: got {actual}", file=sys.stderr)
        if args.verify_only:
            return 1
        print("Downloading a fresh copy.")
    elif args.verify_only:
        print(f"ERROR: {target} does not exist.", file=sys.stderr)
        return 1

    args.dest_dir.mkdir(parents=True, exist_ok=True)
    # Download to a .part file first, so an interrupted download never
    # leaves a file with the final name that looks complete.
    partial = target.with_name(target.name + ".part")
    print(f"Downloading {URL}")
    print(f"  ({SIZE_BYTES:,} bytes) to {partial}")
    actual = download(URL, partial)

    if actual != SHA256:
        print(f"ERROR: checksum mismatch after download: got {actual}", file=sys.stderr)
        print(f"The partial file was kept for inspection: {partial}", file=sys.stderr)
        return 1

    partial.replace(target)
    print(f"Checksum OK. Saved {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
