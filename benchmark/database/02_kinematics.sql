-- The columns of PointContext that the reconstructions read when no descriptions are rendered:
-- the position in WGS 84, the speed over ground, course over ground, heading and rate of turn of
-- every observed position, and the exclusive economic zone that fixes its local time in the view
-- ModelInput. 02_context.sql computes the same columns, and the context of the descriptions beside
-- them; reproduce.sh runs this file instead when the descriptions are not embedded, since neither
-- 'coordinates', nor the UniTraj models, nor 'kinematic' reads them.
--
--   psql -d ais -f 02_kinematics.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS PointContext CASCADE;
CREATE TABLE PointContext AS
SELECT p.GapId, p.PointIdx, p.T, g.MMSI, p.Geom,
  valueAtTimestamp(s.TripLonLat, p.T) AS GeomLonLat,
  valueAtTimestamp(s.SOG, p.T) AS SOG, valueAtTimestamp(s.COG, p.T) AS COG,
  valueAtTimestamp(s.Heading, p.T) AS Heading, valueAtTimestamp(s.ROT, p.T) AS ROT,
  ( SELECT e.Iso FROM EEZ e WHERE ST_Intersects(e.Geom, p.Geom) LIMIT 1 ) AS EEZ
FROM TripPoints p JOIN Gaps g USING (GapId) JOIN Ships s USING (MMSI)
WHERE NOT p.InGap;
ALTER TABLE PointContext ADD PRIMARY KEY (GapId, PointIdx);
ANALYZE PointContext;

SELECT count(*) AS Positions, count(SOG) AS WithSOG, count(COG) AS WithCOG, count(ROT) AS WithROT,
  count(EEZ) AS WithEEZ FROM PointContext;
