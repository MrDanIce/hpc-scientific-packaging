"""Tests for scripts/merge_results.py.

Run from the repository root, inside the conda environment:
    mamba run -n rdkit-descriptors python -m unittest discover -s tests -v
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPUTE = REPO_ROOT / "scripts" / "compute_descriptors.py"
MERGE = REPO_ROOT / "scripts" / "merge_results.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
SAMPLE = FIXTURES / "sample_chemreps.tsv"


def run(script, *args):
    return subprocess.run(
        [sys.executable, str(script), *map(str, args)], capture_output=True, text=True
    )


class TestMerge(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.chunks = self.tmp / "chunks"
        # The 10-row fixture as 4 chunks of 3 rows, like a job array would.
        for i in range(4):
            result = run(
                COMPUTE, "--input", SAMPLE, "--chunk-size", 3, "--chunk-index", i,
                "--output", self.chunks / f"chunk_{i:04d}.tsv",
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def merge(self, expected=4):
        return run(
            MERGE, "--chunks-dir", self.chunks, "--expected", expected,
            "--output", self.tmp / "merged.tsv",
        )

    def test_merged_chunks_equal_single_run(self):
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("6 valid, 4 invalid", result.stderr)
        self.assertEqual(
            (self.tmp / "merged.tsv").read_bytes(),
            (FIXTURES / "expected_descriptors.tsv").read_bytes(),
        )
        self.assertEqual(
            (self.tmp / "merged.invalid.tsv").read_bytes(),
            (FIXTURES / "expected_invalid.tsv").read_bytes(),
        )

    def test_missing_chunk_fails_and_writes_nothing(self):
        (self.chunks / "chunk_0002.tsv").unlink()
        result = self.merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn("chunk_0002.tsv", result.stderr)
        self.assertFalse((self.tmp / "merged.tsv").exists())

    def test_expecting_more_chunks_than_exist_fails(self):
        result = self.merge(expected=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("chunk_0004.tsv", result.stderr)

    def test_different_header_fails(self):
        path = self.chunks / "chunk_0001.tsv"
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        path.write_text("other_header\n" + "".join(lines[1:]), encoding="utf-8")
        result = self.merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn("different header", result.stderr)

    def test_duplicate_ids_fail(self):
        shutil.copy(self.chunks / "chunk_0000.tsv", self.chunks / "chunk_0001.tsv")
        result = self.merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn("more than one chunk", result.stderr)


if __name__ == "__main__":
    unittest.main()
