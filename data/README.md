# Data

The dataset is **not stored in this repository**. Download it with:

```bash
python scripts/fetch_data.py
```

This saves `data/chembl_37_chemreps.txt.gz` and checks its SHA-256 checksum.
Running it again when the file is already there only re-checks the checksum.
To check an existing file without downloading, run `python scripts/fetch_data.py --verify-only`.

## Source

| | |
|---|---|
| Database | ChEMBL, release 37 (pinned; the script never uses `latest/`) |
| Publisher | EMBL-EBI (European Bioinformatics Institute) |
| File | `chembl_37_chemreps.txt.gz` |
| URL | https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/chembl_37/chembl_37_chemreps.txt.gz |
| Size | 292,540,141 bytes (gzip-compressed) |
| Server date | Fri, 29 May 2026 06:34:19 GMT (`Last-Modified` header) |
| SHA-256 | `ea6181ce8dc7af41974e35b92e1febb0c9dcbe2c62f7ccc4a5d983ac19f696e7` |
| Checksum source | https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/chembl_37/checksums.txt |

To check the checksum by hand:

```bash
sha256sum data/chembl_37_chemreps.txt.gz
```

## Format

Tab-separated text with one header row and one compound per row:

| Column | Meaning |
|---|---|
| `chembl_id` | ChEMBL compound ID, e.g. `CHEMBL153534` |
| `canonical_smiles` | structure as a SMILES string (the column the workload uses) |
| `standard_inchi` | structure as an InChI string |
| `standard_inchi_key` | hashed InChI |

`scripts/compute_descriptors.py` reads only `chembl_id` and `canonical_smiles`.
SMILES are used as given: salts and mixtures are not stripped or standardized,
so their descriptors cover every component.

## License and attribution

ChEMBL data is licensed under
[Creative Commons Attribution-ShareAlike 3.0 Unported (CC BY-SA 3.0)](https://creativecommons.org/licenses/by-sa/3.0/).
The full license text is in the release folder:
https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/chembl_37/LICENSE

Descriptor tables computed from this data are derived works. If you share them,
share them under CC BY-SA 3.0 as well. ChEMBL asks that users keep the ChEMBL
IDs and state the release number. The output keeps the `chembl_id` column, and
the release is ChEMBL 37.

ChEMBL's requested citation (from
[REQUIRED.ATTRIBUTION](https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/releases/chembl_37/REQUIRED.ATTRIBUTION)):

> Mendez D, Gaulton A, Bento AP, Chambers J, De Veij M, Félix E, Magariños MP,
> Mosquera JF, Mutowo P, Nowotka M, Gordillo-Marañón M, Hunter F, Junco L,
> Mugumbate G, Rodriguez-Lopez M, Atkinson F, Bosc N, Radoux CJ,
> Segura-Cabrera A, Hersey A, Leach AR. ChEMBL: towards direct deposition of
> bioassay data. Nucleic Acids Res. 2019 47(D1):D930-D940.
> DOI: 10.1093/nar/gky1075

## Test fixture

`tests/fixtures/sample_chemreps.tsv` is **not** ChEMBL data. It is a 10-row
file in the same format, written by hand with made-up `FIX` IDs. It holds
common molecules (ethanol, benzene, aspirin, caffeine, sodium acetate, alanine)
and four records that are invalid on purpose.
