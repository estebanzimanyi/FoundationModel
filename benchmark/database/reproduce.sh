#!/bin/bash
# Reproduce the results of Section 7 of the paper, the evaluation in MobilityDB, from one day of
# the AIS archives of the Danish Maritime Authority:
#
#   bash benchmark/database/reproduce.sh [DAY]     (DAY as YYYY-MM-DD, default 2026-01-20)
#
# The steps, each a script of this directory, write into the PostgreSQL database named by the
# libpq variables (PGDATABASE, default ais; PGHOST, PGPORT, PGUSER), which is created if absent
# and needs PostGIS and MobilityDB 1.3 or later:
#   1  fetch_data.sh        the AIS day and the reference layers, from their publishers
#   2  ais_*.sql            AISInput, AISClean (checked by fingerprint.sql), Vessels, Ships
#   3  01_sequences.sql     Gaps and TripPoints, the windows of the gaps sampled every minute
#   4  load_context.sh, 02_kinematics.sql (or 02_context.sql, 03_descriptions.sql, embed.py)
#   5  04_masks.sql         EvalMasks and the view ModelInput, fixed before any model runs
#   6  run_model.py         'coordinates' (and 'crossdomain'), the published checkpoint
#      run_unitraj.py       'unitraj', 'unitraj-sd', 'unitraj-wt', UniTraj zero-shot
#   7  05_evaluate.sql, kinematic.sql   Reconstructed, Errors, and the reference 'kinematic'
#   8  winspeed.sql, analyze.py         Tables db-errors and db-unitraj, and the values of
#                                       Figs. 11 and 12, in RESULTS/section7.{txt,json}
#      figures.py           Figs. 11 and 12, in RESULTS/figures/ (needs pdflatex)
#   9  synthetic.py         Table synthetic, in RESULTS/synthetic.{txt,json}; with CROSSDOMAIN=1,
#                           02_context.sql, 03_descriptions.sql, and embed.py on its stretches
#  10  06_exact.sql         the bounds on area entry, in RESULTS/exact.txt (CROSSDOMAIN=1)
# The published checkpoint loads only with the model code of commit 8fc3ca2 of this repository,
# which is checked out into $DATA/thesis-8fc3ca2; UniTraj is cloned from Yasoz/UniTraj into
# $DATA/UniTraj at the commit of its released weights.
#
# CROSSDOMAIN=1 also runs 'crossdomain', whose descriptions need the wave heights of the
# Copernicus Marine Service (copernicusmarine login) and whose text encoder, EmbeddingGemma, is a
# gated model of Hugging Face (accept its license, then hf auth login); without it, every
# result of the section that does not involve 'crossdomain' is produced.
# DATA (default: data/ beside this script) holds the downloads, RESULTS (default: results/ beside
# this script) the results and the log of every step, PYTHON (default: python3) the interpreter
# with the packages of requirements.txt.
set -eo pipefail
DAY=${1:-2026-01-20}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
export DAY DATA=${DATA:-$HERE/data} RESULTS=${RESULTS:-$HERE/results}
export PGDATABASE=${PGDATABASE:-ais}
PYTHON=${PYTHON:-python3}
CROSSDOMAIN=${CROSSDOMAIN:-0}
UNITRAJ_COMMIT=8dbd123d3592e1f00e8461176d4489e4373739b8
THESIS_COMMIT=8fc3ca2d49b957e1fff70ce7718b25b1342ad198
export THESIS=$DATA/thesis-8fc3ca2 UNITRAJ=$DATA/UniTraj
PSQL="psql -X -v ON_ERROR_STOP=1"
mkdir -p "$DATA" "$RESULTS/log"
cd "$HERE"

step() { # name command...: run a step, its output in RESULTS/log/<name>.log and on the terminal
  local name=$1; shift
  echo "== $name"
  "$@" 2>&1 | tee "$RESULTS/log/$name.log"
}

# 1. data and code
step 01_fetch bash fetch_data.sh "$DAY"
if [ ! -d "$THESIS" ]; then
  if git -C "$REPO" cat-file -e "$THESIS_COMMIT" 2> /dev/null; then
    git clone -q --no-checkout "$REPO" "$THESIS"
  else
    git clone -q --no-checkout https://github.com/MobilityDB/FoundationModel "$THESIS"
  fi
fi
git -C "$THESIS" checkout -q "$THESIS_COMMIT"
[ -d "$UNITRAJ" ] || git clone -q https://github.com/Yasoz/UniTraj "$UNITRAJ"
git -C "$UNITRAJ" checkout -q "$UNITRAJ_COMMIT"

# 2. the AIS database of the day
psql -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1 \
  || createdb "$PGDATABASE"
NEXT=$(date -u -d "$DAY + 1 day" +%F)
load_ais() {
  $PSQL -q -f ais_load.sql
  unzip -p "$DATA/ais/aisdk-$DAY.zip" | PGOPTIONS='-c datestyle=ISO,DMY' \
    $PSQL -c "\copy AISInput FROM STDIN CSV HEADER"
  $PSQL -v lo="$DAY" -v hi="$NEXT" -v mid_csv="$DATA/itu_mid.csv" -f ais_clean.sql
  $PSQL -f ais_ships.sql
  $PSQL -At -f fingerprint.sql
}
step 02_ais load_ais

# 3-5. sequences, context, masks
step 03_sequences $PSQL -v sample=100 -f 01_sequences.sql
context() {
  bash load_context.sh
  if [ "$CROSSDOMAIN" = 1 ]; then
    $PSQL -q -c "CREATE EXTENSION IF NOT EXISTS postgis_raster"
    bash build_aux_data.sh
    $PSQL -q -f load_aux_tables.sql
    if [ ! -s "$DATA/ddm/ddm_50m_25832.tif" ]; then
      # nearest-neighbour warp in tiled blocks, which fixes the pixels that the warp chooses
      gdalwarp -q -t_srs EPSG:25832 -tr 50 50 -tap -r near -co COMPRESS=DEFLATE -co TILED=YES \
        "$DATA/ddm/ddm_50m.dybde.tiff" "$DATA/ddm/ddm_50m_25832.tif"
    fi
    $PSQL -q -c "DROP TABLE IF EXISTS Bathymetry"
    (cd "$DATA/ddm" && raster2pgsql -s 25832 -t 256x256 -I -C -M -F \
      ddm_50m_25832.tif public.Bathymetry 2> /dev/null) | $PSQL -q
    bash prep_waves.sh
    bash load_waves.sh
    $PSQL -f 02_context.sql
    $PSQL -f 03_descriptions.sql
    "$PYTHON" embed.py
  else
    $PSQL -f 02_kinematics.sql
    $PSQL -q -c "DROP TABLE IF EXISTS PointEmbedding CASCADE"
  fi
}
step 04_context context
step 05_masks $PSQL -f 04_masks.sql

# 6. the learned reconstructions
step 06_model "$PYTHON" run_model.py
step 06_unitraj "$PYTHON" run_unitraj.py
step 06_unitraj-sd env NORM=std MODEL_NAME=unitraj-sd "$PYTHON" run_unitraj.py
step 06_unitraj-wt env NORM=worldtrace MODEL_NAME=unitraj-wt "$PYTHON" run_unitraj.py

# 7-8. errors, the reference, and the results
step 07_evaluate $PSQL -f 05_evaluate.sql
step 07_kinematic $PSQL -v model=kinematic -f kinematic.sql
step 08_winspeed $PSQL -f winspeed.sql
step 08_analyze "$PYTHON" analyze.py
cp "$RESULTS/log/08_analyze.log" "$RESULTS/section7.txt"
step 08_figures "$PYTHON" figures.py

# 9. synthetic gaps: the stretches, with the descriptions of their positions for 'crossdomain'
synth_points() {
  "$PYTHON" synthetic.py points
  if [ "$CROSSDOMAIN" = 1 ]; then
    $PSQL -v points=SynthPoints -v gaps=SynthGaps -v context=SynthContext -f 02_context.sql
    $PSQL -v context=SynthContext -v descriptor=SynthDescriptor -f 03_descriptions.sql
    DESCRIPTOR=SynthDescriptor EMBEDDING=SynthEmbedding "$PYTHON" embed.py
  else
    $PSQL -q -c "DROP TABLE IF EXISTS SynthEmbedding"
  fi
}
step 09_synthpoints synth_points
step 09_synthetic "$PYTHON" synthetic.py
cp "$RESULTS/log/09_synthetic.log" "$RESULTS/synthetic.txt"

# 10. bounds on area entry
if [ "$CROSSDOMAIN" = 1 ]; then
  step 10_exact $PSQL -f 06_exact.sql
  cp "$RESULTS/log/10_exact.log" "$RESULTS/exact.txt"
fi
echo "results in $RESULTS"
