#!/bin/bash
# Download the reference layers that the descriptions of the use case need beyond the AIS data, into $DATA/context (default: data/ below the working directory), for the study area
# of the AIS database (longitude 3 to 16, latitude 53 to 59). They are the sources of the
# maritime enrichment of the thesis:
#   iho.geojson        IHO sea areas of the VLIZ Marine Regions, through its WFS service
#   eez.geojson        exclusive economic zones of the VLIZ Marine Regions
#   eez_12nm.geojson   12 nautical mile territorial seas of the VLIZ Marine Regions
#   wpi.csv            World Port Index, Publication 150 of the US National
#                      Geospatial-Intelligence Agency
#   tss.geojson        traffic separation zones of OpenStreetMap (seamark:type =
#                      separation_zone), through the Overpass API
# Nothing is redistributed in this repository: each file comes from its publisher. The helper
# fetch is #fetch of fetch_data.sh.
#
#   bash fetch_context.sh
set -e
DATA=${DATA:-$PWD/data}
mkdir -p "$DATA/context"
cd "$DATA/context"

fetch() { # url file
  if [ -s "$2" ]; then echo "present: $2"; else
    echo "fetching: $2"; curl -fL --retry 3 -A "MobilityDataScienceBook/1.0" -o "$2.part" "$1" \
      && mv "$2.part" "$2"; fi
}

W="https://geo.vliz.be/geoserver/MarineRegions/wfs?service=WFS&version=1.0.0&request=GetFeature"
for layer in iho eez eez_12nm; do
  fetch "$W&typeName=MarineRegions:$layer&outputFormat=application/json&bbox=3,53,16,59" \
    "$layer.geojson"
done
fetch "https://msi.nga.mil/api/publications/download?type=view&key=16920959/SFH00000/UpdatedPub150.csv" \
  wpi.csv

if [ -s tss.geojson ]; then echo "present: tss.geojson"; else
  echo "fetching: tss.geojson"
  curl -fsS --retry 3 -A "MobilityDataScienceBook/1.0" -o tss.json --data-urlencode \
    'data=[out:json][timeout:100];way["seamark:type"="separation_zone"](53,3,59,16);out geom;' \
    https://overpass-api.de/api/interpreter
  # Every closed way becomes a polygon named by its seamark name, or its name.
  python3 - <<'EOF'
import json
ways = json.load(open('tss.json'))['elements']
features = []
for w in ways:
    ring = [[p['lon'], p['lat']] for p in w.get('geometry', [])]
    if len(ring) < 4 or ring[0] != ring[-1]:
        continue
    tags = w.get('tags', {})
    features.append({'type': 'Feature', 'geometry': {'type': 'Polygon', 'coordinates': [ring]},
                     'properties': {'osm_id': w['id'],
                                    'name': tags.get('seamark:name') or tags.get('name')}})
json.dump({'type': 'FeatureCollection', 'features': features}, open('tss.geojson', 'w'))
print(f'{len(features)} traffic separation zones')
EOF
  rm tss.json
fi
