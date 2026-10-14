# Evaluation in MobilityDB

The scripts of this directory produce the results of Section 7 of the paper, which runs the model
inside [MobilityDB](https://github.com/MobilityDB/MobilityDB) on the gaps in the trips of vessels of
one day of AIS reports of the Danish Maritime Authority (DMA), and compares it with UniTraj and with
the kinematic interpolation that the database computes by itself.

## One command

```bash
bash benchmark/database/reproduce.sh            # January 20, 2026, the day of the paper
bash benchmark/database/reproduce.sh 2026-01-21 # any other day of the DMA archives
```

The command downloads the data from their publishers, builds the database, runs every model and
writes the results to `benchmark/database/results/`:

| File | Content |
|---|---|
| `section7.txt`, `section7.json` | Table db-errors, the window-paired differences of Fig. errors-paired and Table db-unitraj by speed class, the error curves of the moving vessels of Fig. errors-curves, and the travel ratios of the predictions |
| `figures/` | Figs. 11 and 12, drawn with the PGF backend of matplotlib, which needs `pdflatex` |
| `synthetic.txt` | Table synthetic, the synthetic gaps of 5 to 120 minutes on moving vessels |
| `exact.txt` | the bounds on area entry (with `CROSSDOMAIN=1`) |
| `log/` | the output of every step |

The DMA does not allow its AIS data to be redistributed, so no data are held in this repository:
`fetch_data.sh` downloads the day from <http://aisdata.ais.dk/> into `benchmark/database/data/`,
together with the reference layers listed in `fetch_data.sh` and `fetch_context.sh`.

## Requirements

- PostgreSQL with PostGIS and MobilityDB 1.3 or later, in a database the libpq variables name
  (`PGDATABASE`, default `ais`, created if absent; `PGHOST`, `PGPORT`, `PGUSER`);
- `psql`, `createdb`, `curl`, `unzip`, `git`, GDAL's `ogr2ogr`, and `pdflatex` for the figures;
- Python 3.10 or later with the packages of `requirements.txt`, given by `PYTHON` (default
  `python3`); a GPU makes the models faster but is not needed.

The published checkpoint `models/checkpoints/best.pt` loads only with the model code of commit
`8fc3ca2` of this repository, which the command checks out into `data/thesis-8fc3ca2`; UniTraj is
cloned from <https://github.com/Yasoz/UniTraj> into `data/UniTraj` at the commit of its released
weights.

## The model with its descriptions

By default, the command runs every reconstruction except `crossdomain`, the model with its
kinematic and semantic channels. `CROSSDOMAIN=1` adds it, together with the bounds on area entry
that are computed on its reconstructed paths. The descriptions it embeds need, beyond the default
downloads:

- the hourly wave heights of the [Copernicus Marine Service](https://marine.copernicus.eu/), which
  need the Copernicus Marine Toolbox and a free account (`copernicusmarine login`);
- EmbeddingGemma, a gated model of Hugging Face: accept its license on
  <https://huggingface.co/google/embeddinggemma-300m>, then `hf auth login`;
- GDAL's `gdal_translate` and `gdalwarp`, PostGIS's `raster2pgsql` and the `postgis_raster`
  extension, for Denmark's Depth Model and the wave heights;
- the World Database on Protected Areas of Denmark, in the monthly release `WDPA_RELEASE`
  (default: the current month), which must still contain the 283 areas of
  `aux/natural_areas_sites.csv`.

```bash
CROSSDOMAIN=1 bash benchmark/database/reproduce.sh
```

## The steps

| Step | Script | Writes |
|---|---|---|
| 1 | `fetch_data.sh`, `fetch_context.sh` | `data/` |
| 2 | `ais_load.sql`, `ais_clean.sql`, `ais_ships.sql`, `fingerprint.sql` | AISInput, AISClean, Vessels, Ships |
| 3 | `01_sequences.sql` | Gaps, TripPoints |
| 4 | `load_context.sh`, `02_kinematics.sql` (or `build_aux_data.sh`, `load_aux_tables.sql`, `prep_waves.sh`, `load_waves.sh`, `02_context.sql`, `03_descriptions.sql`, `embed.py`) | PointContext (PointDescriptor, PointEmbedding) |
| 5 | `04_masks.sql` | EvalMasks, ModelInput |
| 6 | `run_model.py`, `run_unitraj.py` | ReconstructedLonLat |
| 7 | `05_evaluate.sql`, `kinematic.sql` | Reconstructed, Errors |
| 8 | `winspeed.sql`, `analyze.py`, `figures.py` | WinSpeed, `results/section7.*`, `results/figures/` |
| 9 | `synthetic.py` | `results/synthetic.txt` |
| 10 | `06_exact.sql` | GapPaths, GapAreas, `results/exact.txt` |

Each script states at its top what it computes and how to run it alone.
