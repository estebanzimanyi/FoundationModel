-- The table AISClean: the reports of AISInput with T in [lo, hi) that pass the cleaning rules of
-- the AIS database of Section 7 of the paper, with every column of
-- AISInput, the position projected to EPSG:25832 in Geom, and the number of the piece of the
-- vessel's track the report belongs to in Piece. The rules are those of the MobilityLakehouse
-- pipeline (benchmark/planar/10_stage.sql and 20_clean.sql of
-- https://github.com/MobilityDB/MobilityLakehouse), whose reports fingerprint.sql keys:
--   report   Class A, a ship-station MMSI (nine digits whose first three are Maritime
--            Identification Digits allocated to an administration, itu_mid.csv), a position
--            inside the study area where EPSG:25832 applies, plausible dimensions;
--   dedup    one report per vessel and instant, ties broken by latitude, longitude, ship type,
--            speed over ground and navigational status, then by every other column, a total
--            order, so a rebuild keeps the same report;
--   walk     a report is kept when the last kept one could reach it at 100 kn; the seed is the
--            earliest of the first eleven reports a majority of them can reach, the reports before
--            it are walked backwards from it, and a vessel whose share of reports unreachable from
--            the report before exceeds one half is dropped whole;
--   pieces   a new piece after a silence over 600 s.
-- Every rule reads the reports of one vessel in time order over the whole of [lo, hi).
--
--   psql -d ais -v lo=2026-01-20 -v hi=2026-01-21 -v mid_csv=data/itu_mid.csv -f ais_clean.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

-- A report is reachable from another when the straight line between them needs at most 100 kn:
-- distance <= 100 kn x elapsed time (1 kn = 1852 m/h).
CREATE OR REPLACE FUNCTION pg_temp.reach(d float8, dt float8) RETURNS bool
  LANGUAGE sql IMMUTABLE AS $$ SELECT d <= 100 * dt * 1852 / 3600 $$;

-- The Maritime Identification Digits allocated to an administration.
CREATE TEMP TABLE Mid(Mid integer, Country text);
\set copy_mid '\\copy Mid FROM ' :'mid_csv' ' CSV HEADER'
:copy_mid

-- The reports passing the checks of a single report, one per vessel and instant, numbered in
-- time order. Text columns are ordered by their bytes (COLLATE "C"), whatever the collation of
-- the database.
CREATE TEMP TABLE Kept AS
SELECT *, EXTRACT(EPOCH FROM T)::float8 AS Ts,
  row_number() OVER (PARTITION BY MMSI ORDER BY T) AS Rn
FROM (
  SELECT DISTINCT ON (MMSI, T) *,
    ST_Transform(ST_Point(Longitude, Latitude, 4326), 25832) AS Geom
  FROM AISInput
  WHERE T >= :'lo' AND T < :'hi'
    AND TypeOfMobile = 'Class A'
    AND MMSI BETWEEN 200000000 AND 799999999
    AND MMSI / 1000000 IN (SELECT Mid FROM Mid)
    AND Longitude BETWEEN 3 AND 16 AND Latitude BETWEEN 53 AND 59
    AND (Draught IS NULL OR Draught <= 28.5)
    AND (Width IS NULL OR Width <= 75)
    AND (Length IS NULL OR Length <= 488)
  ORDER BY MMSI, T, Latitude, Longitude, ShipType COLLATE "C", SOG,
    NavigationalStatus COLLATE "C", ROT, COG, Heading, IMO COLLATE "C",
    CallSign COLLATE "C", Name COLLATE "C", CargoType COLLATE "C", Width, Length,
    TypeOfPositionFixingDevice COLLATE "C", Draught, Destination COLLATE "C",
    ETA COLLATE "C", DataSourceType COLLATE "C", SizeA, SizeB, SizeC, SizeD) K;
CREATE INDEX ON Kept (MMSI, Rn);
ANALYZE Kept;

-- The vessels whose share of reports unreachable from the report before is at most one half.
CREATE TEMP TABLE KeepVessel AS
SELECT MMSI FROM (
  SELECT MMSI, NOT coalesce(pg_temp.reach(ST_Distance(lag(Geom) OVER W, Geom),
                                          Ts - lag(Ts) OVER W), true) AS Unreachable
  FROM Kept WINDOW W AS (PARTITION BY MMSI ORDER BY Rn)) S
GROUP BY MMSI HAVING avg(Unreachable::int) <= 0.5;

-- The walk trusts its first report, so the seed is corroborated: the earliest of the first eleven
-- reports of a vessel that a majority of them can reach.
CREATE TEMP TABLE Head AS
SELECT K.MMSI, K.Rn, K.Ts, K.Geom FROM Kept K JOIN KeepVessel USING (MMSI) WHERE K.Rn <= 11;

CREATE TEMP TABLE Seed AS
SELECT MMSI, coalesce(min(Rn) FILTER (WHERE Ok * 2 >= Others), 1) AS SeedRn
FROM (
  SELECT a.MMSI, a.Rn,
    count(*) FILTER (WHERE b.Rn <> a.Rn AND b.Ts <> a.Ts
      AND pg_temp.reach(ST_Distance(a.Geom, b.Geom), abs(b.Ts - a.Ts))) AS Ok,
    count(*) - 1 AS Others
  FROM Head a JOIN Head b USING (MMSI)
  GROUP BY a.MMSI, a.Rn) A
GROUP BY MMSI;

-- The track from the seed on, cut into runs at each report unreachable from the report before
-- it. Inside a run every step is reachable, so the walk decides only, per run, the first report
-- where the track is rejoined.
CREATE TEMP TABLE Fwd AS
SELECT MMSI, Rn, Ts, Geom,
  sum(CASE WHEN NOT coalesce(pg_temp.reach(DPrev, DtPrev), true) THEN 1 ELSE 0 END)
    OVER (PARTITION BY MMSI ORDER BY Rn) AS RunId
FROM (
  SELECT K.MMSI, K.Rn, K.Ts, K.Geom,
    K.Ts - lag(K.Ts) OVER W AS DtPrev, ST_Distance(lag(K.Geom) OVER W, K.Geom) AS DPrev
  FROM Kept K JOIN Seed S USING (MMSI)
  WHERE K.Rn >= S.SeedRn
  WINDOW W AS (PARTITION BY K.MMSI ORDER BY K.Rn)) F;
CREATE INDEX ON Fwd (MMSI, RunId, Rn);

-- The last report of each run, the anchor it hands on.
CREATE TEMP TABLE Runs AS
SELECT DISTINCT ON (MMSI, RunId) MMSI, RunId, Rn AS LastRn, Ts AS LastTs, Geom AS LastGeom
FROM Fwd ORDER BY MMSI, RunId, Rn DESC;
CREATE INDEX ON Runs (MMSI, RunId);
ANALYZE Fwd;
ANALYZE Runs;

-- One step per run, carrying the anchor, the last kept report. Cut is the first report of the
-- run reachable from the anchor; the reports before it are dropped. A run with no reachable
-- report is dropped whole and leaves the anchor in place.
CREATE TEMP TABLE Walk AS
WITH RECURSIVE W AS (
  SELECT MMSI, RunId, 0::bigint AS Cut, LastTs AS ATs, LastGeom AS AGeom
  FROM Runs WHERE RunId = 0
  UNION ALL
  SELECT r.MMSI, r.RunId,
    coalesce(x.K, r.LastRn + 1),
    CASE WHEN x.K IS NULL THEN w.ATs ELSE r.LastTs END,
    CASE WHEN x.K IS NULL THEN w.AGeom ELSE r.LastGeom END
  FROM W w
  JOIN Runs r ON r.MMSI = w.MMSI AND r.RunId = w.RunId + 1
  CROSS JOIN LATERAL (SELECT (
    SELECT f.Rn FROM Fwd f
    WHERE f.MMSI = r.MMSI AND f.RunId = r.RunId AND f.Ts > w.ATs
      AND pg_temp.reach(ST_Distance(w.AGeom, f.Geom), f.Ts - w.ATs)
    ORDER BY f.Rn LIMIT 1) AS K) x)
SELECT MMSI, RunId, Cut FROM W;

-- The reports before the seed, walked backwards from it by the same rule.
CREATE TEMP TABLE PreKeep AS
WITH RECURSIVE B AS (
  SELECT H.MMSI, H.Rn, H.Ts AS ATs, H.Geom AS AGeom, false AS Kept
  FROM Head H JOIN Seed S ON S.MMSI = H.MMSI AND H.Rn = S.SeedRn
  WHERE S.SeedRn > 1
  UNION ALL
  SELECT b.MMSI, h.Rn,
    CASE WHEN r.Ok THEN h.Ts ELSE b.ATs END,
    CASE WHEN r.Ok THEN h.Geom ELSE b.AGeom END,
    r.Ok
  FROM B b
  JOIN Head h ON h.MMSI = b.MMSI AND h.Rn = b.Rn - 1
  CROSS JOIN LATERAL (SELECT pg_temp.reach(ST_Distance(b.AGeom, h.Geom), b.ATs - h.Ts) AS Ok) r)
SELECT MMSI, Rn FROM B WHERE Kept;

-- The reports the walk keeps, cut into pieces at the silences over 600 s.
DROP TABLE IF EXISTS AISClean CASCADE;
CREATE TABLE AISClean AS
SELECT T, TypeOfMobile, MMSI, Latitude, Longitude, NavigationalStatus, ROT, SOG, COG, Heading,
  IMO, CallSign, Name, ShipType, CargoType, Width, Length, TypeOfPositionFixingDevice, Draught,
  Destination, ETA, DataSourceType, SizeA, SizeB, SizeC, SizeD, Geom,
  sum(CASE WHEN Ts - LagTs > 600 THEN 1 ELSE 0 END)
    OVER (PARTITION BY MMSI ORDER BY T)::integer AS Piece
FROM (
  SELECT K.*, lag(K.Ts) OVER (PARTITION BY K.MMSI ORDER BY K.T) AS LagTs
  FROM Kept K
  JOIN (
    SELECT F.MMSI, F.Rn FROM Fwd F JOIN Walk W USING (MMSI, RunId) WHERE F.Rn >= W.Cut
    UNION ALL
    SELECT MMSI, Rn FROM PreKeep) C USING (MMSI, Rn)) S;
ALTER TABLE AISClean ALTER COLUMN Geom TYPE geometry(Point, 25832);
CREATE INDEX ON AISClean (MMSI, T);
ANALYZE AISClean;

-- What each rule kept.
SELECT 'raw reports' AS Step, count(*) AS N FROM AISInput WHERE T >= :'lo' AND T < :'hi'
UNION ALL SELECT 'checked reports', count(*) FROM Kept
UNION ALL SELECT 'clean reports', count(*) FROM AISClean
UNION ALL SELECT 'vessels', count(DISTINCT MMSI) FROM AISClean
UNION ALL SELECT 'pieces', count(*) FROM (SELECT DISTINCT MMSI, Piece FROM AISClean) P;
