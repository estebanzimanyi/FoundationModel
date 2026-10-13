#!/bin/bash
# Download the data of Section 7 of the paper into the directory $DATA (default: data/ beside this
# script). Nothing is redistributed in this repository: each file comes from its publisher.
#   ais/aisdk-DAY.zip   the AIS reports of the day of the Danish Maritime Authority
#   itu_mid.csv         the Maritime Identification Digits that the cleaning of ais_clean.sql
#                       reads, from MobilityLakehouse at the commit whose rules it follows
#   context/            the reference layers of fetch_context.sh (sea areas, economic zones,
#                       territorial seas, World Port Index, traffic separation zones)
# With CROSSDOMAIN=1, also the layers that only the descriptions of 'crossdomain' and the bounds
# of 06_exact.sql read:
#   ddm/                Denmark's Depth Model, 50 m, of the Danish Geodata Agency
#   aux/                GISCO ports 2013 of Eurostat, and the World Database on Protected Areas of
#                       Denmark in its monthly release WDPA_RELEASE (default: the current month)
#   cmems/              the hourly wave products of the Copernicus Marine Service for the day,
#                       which need the Copernicus Marine Toolbox and a free account
#                       (copernicusmarine login)
# The helper fetch is the one fetch_context.sh restates (#fetch); sub wraps the subset command of
# the Copernicus Marine Toolbox, which no other script of this repository calls.
#
#   bash fetch_data.sh [DAY]     (DAY as YYYY-MM-DD, default 2026-01-20)
set -e
DAY=${1:-${DAY:-2026-01-20}}
HERE=$(cd "$(dirname "$0")" && pwd)
export DATA=${DATA:-$HERE/data}
# The commit of https://github.com/MobilityDB/MobilityLakehouse whose cleaning rules ais_clean.sql
# follows.
LAKEHOUSE_COMMIT=546ce51b908f28fd0ec03529630a0610125675ba
mkdir -p "$DATA/ais"

fetch() { # url file
  if [ -s "$2" ]; then echo "present: $2"; else
    echo "fetching: $2"; curl -fL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"; fi
}

fetch "http://aisdata.ais.dk/aisdk-$DAY.zip" "$DATA/ais/aisdk-$DAY.zip"
R="https://raw.githubusercontent.com/MobilityDB/MobilityLakehouse/$LAKEHOUSE_COMMIT/benchmark/planar"
for f in itu_mid.csv itu_mid.LICENSE itu_mid.NOTICE; do
  fetch "$R/$f" "$DATA/$f"
done
bash "$HERE/fetch_context.sh"

if [ "${CROSSDOMAIN:-0}" = 1 ]; then
  mkdir -p "$DATA/ddm" "$DATA/aux" "$DATA/cmems"
  W='https://ftp.sdfe.dk/main.html?download&weblink=b4324b6389898704fd8ec7484882dbf3&subfolder=2024&realfilename='
  fetch "${W}ddm%5F50m%2Edybde%2Etiff" "$DATA/ddm/ddm_50m.dybde.tiff"
  fetch https://ec.europa.eu/eurostat/cache/GISCO/geodatafiles/PORT_2013_SH.zip \
    "$DATA/aux/PORT_2013_SH.zip"
  R=${WDPA_RELEASE:-$(LC_ALL=C date +%b%Y)}
  fetch "https://d1gam3xoknrgr2.cloudfront.net/current/WDPA_WDOECM_${R}_Public_DNK_shp.zip" \
    "$DATA/aux/WDPA_${R}_DNK_shp.zip"
  D=$(echo "$DAY" | tr -d -)
  NEXT=$(date -u -d "$DAY + 1 day" +%F)
  B="-x 3 -X 16.5 -y 53.5 -Y 58.5 -t ${DAY}T00:00:00 -T ${NEXT}T00:00:00 -o $DATA/cmems"
  sub() { # dataset file variables...
    local ds=$1 f=$2; shift 2
    if [ -s "$DATA/cmems/$f" ]; then echo "present: $DATA/cmems/$f"; else
      copernicusmarine subset -i "$ds" "$@" $B -f "$f"; fi
  }
  sub cmems_mod_bal_wav_anfc_PT1H-i "bal_wav_$D.nc" -v VHM0 -v VMDR
  sub cmems_mod_nws_wav_anfc_1.5km_PT1H-i "nws_wav_$D.nc" -v VHM0 -v VMDR
fi
