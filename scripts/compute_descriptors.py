#!/usr/bin/env python3
"""Compute RDKit molecular descriptors for one chunk of a ChEMBL chemreps file.

Input:  a tab-separated file with a header row that contains at least the
        columns "chembl_id" and "canonical_smiles" (the ChEMBL chemreps
        format). Plain text or gzip-compressed (.gz).

Chunks: data rows are numbered from 0, header excluded. Chunk K with size N
        covers rows K*N up to (K+1)*N - 1. Without --chunk-size the whole
        file is one chunk. A Slurm job array can pass its task ID as
        --chunk-index.

Output: two tab-separated files.
        - descriptors: one row per valid molecule, sorted by chembl_id.
          Floats are written with a fixed number of decimal places, so the
          same input always gives byte-identical output.
        - invalid: one row per record that could not be processed, with the
          reason. Invalid SMILES are recorded here; they do not stop the run.

Usage:
    python scripts/compute_descriptors.py \\
        --input data/chembl_37_chemreps.txt.gz \\
        --chunk-size 1000 --chunk-index 0 \\
        --output results/descriptors_0000.tsv
"""

import argparse
import gzip
import math
import os
import sys
import time
from pathlib import Path

import rdkit
from rdkit import Chem, rdBase
from rdkit.Chem import Crippen, Descriptors, Lipinski, QED, rdMolDescriptors

DECIMALS = 4

# (column name, function, kind). "float" columns are rounded to DECIMALS,
# "int" columns are counts. The order here is the column order in the output.
DESCRIPTORS = [
    ("mol_wt", Descriptors.MolWt, "float"),
    ("exact_mol_wt", Descriptors.ExactMolWt, "float"),
    ("logp", Crippen.MolLogP, "float"),
    ("tpsa", rdMolDescriptors.CalcTPSA, "float"),
    ("qed", QED.qed, "float"),
    ("fraction_csp3", rdMolDescriptors.CalcFractionCSP3, "float"),
    ("heavy_atoms", Lipinski.HeavyAtomCount, "int"),
    ("h_donors", rdMolDescriptors.CalcNumHBD, "int"),
    ("h_acceptors", rdMolDescriptors.CalcNumHBA, "int"),
    ("rotatable_bonds", rdMolDescriptors.CalcNumRotatableBonds, "int"),
    ("rings", rdMolDescriptors.CalcNumRings, "int"),
    ("aromatic_rings", rdMolDescriptors.CalcNumAromaticRings, "int"),
]

OUTPUT_COLUMNS = ["chembl_id", "canonical_smiles"] + [name for name, _, _ in DESCRIPTORS]
INVALID_COLUMNS = ["line_number", "chembl_id", "canonical_smiles", "reason"]


class InputError(Exception):
    """The input file or the chunk selection is not usable."""


def format_float(value: float) -> str:
    """Fixed-precision text for a float, e.g. 46.06844 -> '46.0684'."""
    if not math.isfinite(value):
        raise ValueError(f"non-finite value {value!r}")
    text = f"{value:.{DECIMALS}f}"
    # Values like -0.00001 would print as "-0.0000"; write them as "0.0000".
    if text == "-" + "0." + "0" * DECIMALS:
        text = text[1:]
    return text


def parse_smiles(smiles: str):
    """Return (mol, None) for a valid SMILES, or (None, reason) if invalid."""
    if not smiles:
        return None, "empty SMILES"
    # RDKit prints its own warning to stderr for every bad molecule. We
    # record the reason ourselves, so silence those messages.
    with rdBase.BlockLogs():
        # Parse without sanitizing first, so we can ask RDKit what is wrong
        # instead of only getting None back.
        mol = Chem.MolFromSmiles(smiles, sanitize=False)
        if mol is None:
            return None, "SMILES syntax error"
        problems = Chem.DetectChemistryProblems(mol)
        if problems:
            return None, "; ".join(p.Message() for p in problems)
        try:
            Chem.SanitizeMol(mol)
        except Exception as exc:  # RDKit raises several exception types here
            return None, f"sanitization failed: {exc}"
    return mol, None


def compute_row(mol) -> list[str]:
    values = []
    for name, func, kind in DESCRIPTORS:
        value = func(mol)
        values.append(format_float(value) if kind == "float" else str(int(value)))
    return values


def open_text(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", newline="")
    return path.open("r", encoding="utf-8", newline="")


def read_chunk(path: Path, chunk_size: int | None, chunk_index: int):
    """Yield (line_number, fields, column_index) for the rows in the chunk.

    line_number is the 1-based line number in the file (header is line 1),
    so it can be used to find the row again.
    """
    start = 0 if chunk_size is None else chunk_index * chunk_size
    stop = None if chunk_size is None else start + chunk_size

    with open_text(path) as f:
        header = f.readline().rstrip("\r\n").split("\t")
        missing = {"chembl_id", "canonical_smiles"} - set(header)
        if missing:
            raise InputError(
                f"{path}: header is missing column(s) {sorted(missing)}; got {header}"
            )
        cols = {name: header.index(name) for name in ("chembl_id", "canonical_smiles")}

        found_any = False
        for row_number, line in enumerate(f):
            if row_number < start:
                continue
            if stop is not None and row_number >= stop:
                break
            found_any = True
            yield row_number + 2, line.rstrip("\r\n").split("\t"), cols

    if not found_any:
        raise InputError(
            f"chunk {chunk_index} (rows {start} to {stop - 1 if stop else 'end'}) "
            f"is past the end of {path}"
        )


def write_tsv_atomic(path: Path, columns: list[str], rows: list[list[str]]) -> None:
    """Write to a temporary file, then rename. A job killed half-way through
    never leaves a truncated file with the final name."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        f.write("\t".join(columns) + "\n")
        for row in rows:
            f.write("\t".join(row) + "\n")
    tmp.replace(path)


def process(path: Path, chunk_size: int | None, chunk_index: int):
    """Return (valid_rows, invalid_rows), each sorted for stable output."""
    valid, invalid = [], []
    for line_number, fields, cols in read_chunk(path, chunk_size, chunk_index):
        if len(fields) <= max(cols.values()):
            chembl_id = fields[0] if fields else ""
            invalid.append([str(line_number), chembl_id, "", "malformed line: too few columns"])
            continue
        chembl_id = fields[cols["chembl_id"]]
        smiles = fields[cols["canonical_smiles"]]

        mol, reason = parse_smiles(smiles)
        if mol is not None:
            try:
                valid.append([chembl_id, smiles] + compute_row(mol))
                continue
            except Exception as exc:
                reason = f"descriptor calculation failed: {exc}"
        invalid.append([str(line_number), chembl_id, smiles, reason])

    # Sort by ID (then SMILES, in case an ID repeats) so the output does not
    # depend on input order. Invalid rows sort by ID, then line number.
    valid.sort(key=lambda r: (r[0], r[1]))
    invalid.sort(key=lambda r: (r[1], int(r[0])))
    return valid, invalid


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--input", type=Path, required=True, help="chemreps .txt or .txt.gz file")
    parser.add_argument("--output", type=Path, required=True, help="descriptor TSV to write")
    parser.add_argument(
        "--invalid-output",
        type=Path,
        help="TSV of records that could not be processed "
        "(default: next to --output, ending in .invalid.tsv)",
    )
    parser.add_argument("--chunk-size", type=int, help="rows per chunk (default: whole file)")
    parser.add_argument("--chunk-index", type=int, default=0, help="which chunk, from 0 (default: 0)")
    args = parser.parse_args(argv)

    if args.chunk_size is not None and args.chunk_size < 1:
        parser.error("--chunk-size must be at least 1")
    if args.chunk_index < 0:
        parser.error("--chunk-index must be 0 or more")
    if args.chunk_size is None and args.chunk_index != 0:
        parser.error("--chunk-index needs --chunk-size")

    invalid_output = args.invalid_output or args.output.with_name(
        args.output.name.removesuffix(".tsv") + ".invalid.tsv"
    )

    started = time.perf_counter()
    try:
        valid, invalid = process(args.input, args.chunk_size, args.chunk_index)
    except InputError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    write_tsv_atomic(args.output, OUTPUT_COLUMNS, valid)
    write_tsv_atomic(invalid_output, INVALID_COLUMNS, invalid)

    elapsed = time.perf_counter() - started
    print(
        f"RDKit {rdkit.__version__}: {len(valid) + len(invalid)} rows read, "
        f"{len(valid)} valid, {len(invalid)} invalid, {elapsed:.1f} s\n"
        f"  descriptors: {args.output}\n"
        f"  invalid:     {invalid_output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
