#!/bin/bash
# The significant wave height (VHM0) of the day DAY (default 2026-01-20), from the
# Copernicus Marine hourly wave products of the Baltic Sea and the North West
# Shelf, merged and reprojected ONCE to EPSG:25832 on a 1 km grid, one GeoTIFF
# per hourly step. The Baltic value is kept where the Baltic model has one, and
# the North West Shelf value elsewhere (gdalwarp writes the later source over
# the earlier one where the later one has data). Nearest-neighbour resampling
# keeps the model values.
set -e
D=$(echo "${DAY:-2026-01-20}" | tr -d -)
SRC=${DATA:-$PWD/data}/cmems
OUT=$SRC/waves25832
mkdir -p $OUT $SRC/work
cd $SRC/work
for b in $(seq 1 24); do
  h=$(printf '%02d' $((b - 1)))
  gdal_translate -q -b $b -unscale -ot Float32 -a_nodata -9999 -a_srs EPSG:4326 \
    "NETCDF:\"../nws_wav_$D.nc\":VHM0" nws_$h.tif
  gdal_translate -q -b $b -ot Float32 -a_srs EPSG:4326 \
    "NETCDF:\"../bal_wav_$D.nc\":VHM0" bal_$h.tif
  gdalwarp -q -overwrite -t_srs EPSG:25832 -tr 1000 1000 -tap \
    -te_srs EPSG:4326 -te 3 53.5 16.5 58.5 -r near -dstnodata -9999 \
    -co COMPRESS=DEFLATE nws_$h.tif bal_$h.tif $OUT/vhm0_${D}T${h}.tif
  rm -f nws_$h.tif bal_$h.tif
done
ls $OUT | wc -l
gdalinfo -stats $OUT/vhm0_${D}T12.tif | grep -E 'Size is|Minimum='
