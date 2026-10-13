-- The fingerprint of AISClean, which identifies the cleaned day: the number of reports and the MD5
-- of their keys, one line per report in a total order, a report being keyed by its vessel, its
-- instant in microseconds since 1970 and its piece. It is the fingerprint the MobilityLakehouse
-- pipeline computes for its cleaned reports. For January 20, 2026 it is
--   clean|9374915|75bbc838f5ad9529d2fc78f62489fd19
--
--   psql -d ais -At -f fingerprint.sql

SELECT 'clean', count(*), md5(string_agg(
  MMSI || ',' || (EXTRACT(EPOCH FROM T) * 1000000)::bigint || ',' || Piece, ';'
  ORDER BY MMSI, T))
FROM AISClean;
