"""Tests for scripts/compute_descriptors.py.

Run from the repository root, inside the conda environment:
    mamba run -n rdkit-descriptors python -m unittest discover -s tests -v
(or `conda activate rdkit-descriptors` first, in an interactive terminal).

Uses only the standard library's unittest, so no extra packages are needed.
"""

import gzip
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "compute_descriptors.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
SAMPLE = FIXTURES / "sample_chemreps.tsv"

sys.path.insert(0, str(SCRIPT.parent))
import compute_descriptors as cd  # noqa: E402


def run_script(*args):
    """Run the script as a separate process, the way a Slurm job would."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True,
        text=True,
    )


def read_tsv(path):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]


class TempDirTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)


class TestParseSmiles(unittest.TestCase):
    def test_valid(self):
        mol, reason = cd.parse_smiles("CCO")
        self.assertIsNotNone(mol)
        self.assertIsNone(reason)

    def test_invalid_reasons(self):
        cases = {
            "": "empty SMILES",
            "C1CC(": "SMILES syntax error",
            "CC(C)(C)(C)C": "Explicit valence",
            "c1cccc1": "kekulize",
        }
        for smiles, expected in cases.items():
            with self.subTest(smiles=smiles):
                mol, reason = cd.parse_smiles(smiles)
                self.assertIsNone(mol)
                self.assertIn(expected, reason)


class TestFormatFloat(unittest.TestCase):
    def test_fixed_precision(self):
        self.assertEqual(cd.format_float(46.06844), "46.0684")
        self.assertEqual(cd.format_float(1.0), "1.0000")

    def test_no_negative_zero(self):
        self.assertEqual(cd.format_float(-0.00001), "0.0000")
        self.assertEqual(cd.format_float(-0.0), "0.0000")

    def test_rejects_nan(self):
        with self.assertRaises(ValueError):
            cd.format_float(float("nan"))


class TestWholeFile(TempDirTestCase):
    def test_matches_expected_output(self):
        """Byte-for-byte comparison with the saved expected output.

        If this fails after an RDKit upgrade, check the differences, and only
        update the expected files if the new values are correct.
        """
        out = self.tmp / "d.tsv"
        result = run_script("--input", SAMPLE, "--output", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            out.read_bytes(), (FIXTURES / "expected_descriptors.tsv").read_bytes()
        )
        self.assertEqual(
            (self.tmp / "d.invalid.tsv").read_bytes(),
            (FIXTURES / "expected_invalid.tsv").read_bytes(),
        )

    def test_checksum_file_matches_expected_outputs(self):
        """tests/fixtures/expected.sha256 (used by the CI smoke test) must
        describe the same files as expected_descriptors.tsv and
        expected_invalid.tsv."""
        import hashlib

        sums = {}
        for line in (FIXTURES / "expected.sha256").read_text(encoding="utf-8").splitlines():
            digest, name = line.split("  ", 1)
            sums[name] = digest
        for name, fixture in [
            ("descriptors.tsv", "expected_descriptors.tsv"),
            ("descriptors.invalid.tsv", "expected_invalid.tsv"),
        ]:
            with self.subTest(name=name):
                actual = hashlib.sha256((FIXTURES / fixture).read_bytes()).hexdigest()
                self.assertEqual(sums[name], actual)

    def test_known_values(self):
        """A few values that can be checked by hand."""
        out = self.tmp / "d.tsv"
        run_script("--input", SAMPLE, "--output", out)
        rows = {r["chembl_id"]: r for r in read_tsv(out)}
        ethanol, benzene = rows["FIX0001"], rows["FIX0002"]
        self.assertEqual(ethanol["mol_wt"], "46.0690")  # 2*12.011 + 6*1.008 + 15.999
        self.assertEqual(ethanol["heavy_atoms"], "3")
        self.assertEqual(ethanol["h_donors"], "1")
        self.assertEqual(benzene["mol_wt"], "78.1140")  # 6*12.011 + 6*1.008
        self.assertEqual(benzene["aromatic_rings"], "1")

    def test_invalid_smiles_do_not_stop_the_run(self):
        out = self.tmp / "d.tsv"
        result = run_script("--input", SAMPLE, "--output", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("6 valid, 4 invalid", result.stderr)
        invalid = read_tsv(self.tmp / "d.invalid.tsv")
        self.assertEqual(
            [r["chembl_id"] for r in invalid], ["FIX0007", "FIX0008", "FIX0009", "FIX0010"]
        )

    def test_output_sorted_by_id(self):
        out = self.tmp / "d.tsv"
        run_script("--input", SAMPLE, "--output", out)
        ids = [r["chembl_id"] for r in read_tsv(out)]
        self.assertEqual(ids, sorted(ids))

    def test_same_output_when_input_order_changes(self):
        lines = SAMPLE.read_text(encoding="utf-8").splitlines(keepends=True)
        shuffled = self.tmp / "reversed.tsv"
        shuffled.write_text(lines[0] + "".join(reversed(lines[1:])), encoding="utf-8")
        run_script("--input", SAMPLE, "--output", self.tmp / "a.tsv")
        run_script("--input", shuffled, "--output", self.tmp / "b.tsv")
        self.assertEqual(
            (self.tmp / "a.tsv").read_bytes(), (self.tmp / "b.tsv").read_bytes()
        )

    def test_gzip_input(self):
        gz = self.tmp / "sample.tsv.gz"
        with gzip.open(gz, "wb") as f:
            f.write(SAMPLE.read_bytes())
        out = self.tmp / "d.tsv"
        result = run_script("--input", gz, "--output", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            out.read_bytes(), (FIXTURES / "expected_descriptors.tsv").read_bytes()
        )


class TestChunks(TempDirTestCase):
    def ids_in_chunk(self, size, index):
        out = self.tmp / f"chunk{index}.tsv"
        result = run_script(
            "--input", SAMPLE, "--output", out,
            "--chunk-size", size, "--chunk-index", index,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        valid = [r["chembl_id"] for r in read_tsv(out)]
        invalid = [r["chembl_id"] for r in read_tsv(self.tmp / f"chunk{index}.invalid.tsv")]
        return valid, invalid

    def test_chunk_selects_right_rows(self):
        # Data rows 3, 4, 5: FIX0003, FIX0008 (invalid), FIX0002
        valid, invalid = self.ids_in_chunk(3, 1)
        self.assertEqual(valid, ["FIX0002", "FIX0003"])
        self.assertEqual(invalid, ["FIX0008"])

    def test_last_chunk_may_be_short(self):
        valid, invalid = self.ids_in_chunk(3, 3)  # only data row 9 is left
        self.assertEqual(valid, ["FIX0006"])
        self.assertEqual(invalid, [])

    def test_chunks_cover_every_row_once(self):
        all_ids = []
        for index in range(4):  # 10 rows / 3 per chunk -> 4 chunks
            valid, invalid = self.ids_in_chunk(3, index)
            all_ids += valid + invalid
        self.assertEqual(sorted(all_ids), [f"FIX{i:04d}" for i in range(1, 11)])

    def test_chunk_past_end_is_an_error(self):
        result = run_script(
            "--input", SAMPLE, "--output", self.tmp / "d.tsv",
            "--chunk-size", 3, "--chunk-index", 4,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("past the end", result.stderr)
        self.assertFalse((self.tmp / "d.tsv").exists())


class TestBadInput(TempDirTestCase):
    def test_missing_column(self):
        bad = self.tmp / "bad.tsv"
        bad.write_text("id\tsmiles\nX1\tCCO\n", encoding="utf-8")
        result = run_script("--input", bad, "--output", self.tmp / "d.tsv")
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing column", result.stderr)

    def test_malformed_line_is_recorded(self):
        bad = self.tmp / "bad.tsv"
        bad.write_text(
            "chembl_id\tcanonical_smiles\nX1\tCCO\nX2_no_tab\n", encoding="utf-8"
        )
        result = run_script("--input", bad, "--output", self.tmp / "d.tsv")
        self.assertEqual(result.returncode, 0, result.stderr)
        invalid = read_tsv(self.tmp / "d.invalid.tsv")
        self.assertEqual(invalid[0]["line_number"], "3")
        self.assertIn("malformed", invalid[0]["reason"])


if __name__ == "__main__":
    unittest.main()
