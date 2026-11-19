#!/usr/bin/env python3
"""Merge per-chunk outputs of compute_descriptors.py into one sorted file.

Expects chunk files named chunk_0000.tsv, chunk_0001.tsv, ... (and the
matching chunk_NNNN.invalid.tsv files) in one folder. Fails, without writing
anything, if any expected chunk is missing or if the headers differ.

The merged files are sorted the same way as compute_descriptors.py sorts a
single chunk, so merging the chunks gives byte-identical output to processing
all the rows in one run.

Uses only the Python standard library.

Usage:
    python scripts/merge_results.py --chunks-dir results/subset/chunks \\
        --expected 20 --output results/subset/descriptors.tsv
"""

import argparse
import os
import sys
from pathlib import Path


class MergeError(Exception):
    """The chunk files are missing or inconsistent."""


def read_tsv(path: Path):
    with path.open("r", encoding="utf-8", newline="") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise MergeError(f"{path} is empty (no header)")
    return lines[0], [line.split("\t") for line in lines[1:]]


def merge(paths: list[Path], sort_key):
    header = None
    rows = []
    for path in paths:
        this_header, these_rows = read_tsv(path)
        if header is None:
            header = this_header
        elif this_header != header:
            raise MergeError(f"{path} has a different header:\n  {this_header}\n  expected {header}")
        rows.extend(these_rows)
    rows.sort(key=sort_key)
    return header, rows


def write_atomic(path: Path, header: str, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        f.write(header + "\n")
        for row in rows:
            f.write("\t".join(row) + "\n")
    tmp.replace(path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--chunks-dir", type=Path, required=True)
    parser.add_argument("--expected", type=int, required=True, help="number of chunks (0 to N-1)")
    parser.add_argument("--output", type=Path, required=True, help="merged descriptor TSV")
    parser.add_argument(
        "--invalid-output",
        type=Path,
        help="merged invalid-record TSV (default: next to --output, ending in .invalid.tsv)",
    )
    args = parser.parse_args(argv)
    if args.expected < 1:
        parser.error("--expected must be at least 1")

    invalid_output = args.invalid_output or args.output.with_name(
        args.output.name.removesuffix(".tsv") + ".invalid.tsv"
    )
    valid_paths = [args.chunks_dir / f"chunk_{i:04d}.tsv" for i in range(args.expected)]
    invalid_paths = [args.chunks_dir / f"chunk_{i:04d}.invalid.tsv" for i in range(args.expected)]

    missing = [str(p) for p in valid_paths + invalid_paths if not p.is_file()]
    if missing:
        print(f"ERROR: {len(missing)} expected chunk file(s) missing:", file=sys.stderr)
        for p in missing:
            print(f"  {p}", file=sys.stderr)
        return 2

    try:
        # Same sort keys as compute_descriptors.py.
        v_header, v_rows = merge(valid_paths, lambda r: (r[0], r[1]))
        i_header, i_rows = merge(invalid_paths, lambda r: (r[1], int(r[0])))
    except MergeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    ids = [r[0] for r in v_rows] + [r[1] for r in i_rows]
    if len(ids) != len(set(ids)):
        print("ERROR: some chembl_id values appear in more than one chunk", file=sys.stderr)
        return 2

    write_atomic(args.output, v_header, v_rows)
    write_atomic(invalid_output, i_header, i_rows)
    print(
        f"Merged {args.expected} chunks: {len(v_rows)} valid, {len(i_rows)} invalid "
        f"({len(v_rows) + len(i_rows)} rows)\n"
        f"  descriptors: {args.output}\n"
        f"  invalid:     {invalid_output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
