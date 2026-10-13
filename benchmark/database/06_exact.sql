-- Section 7 of the paper, "Kinematic Bounds on Area Entry": the reconstructed path of
-- every gap as a temporal point, and, for each gap and protected area, whether the vessel could
-- have entered the area during the gap at a speed of at most 30 knots, an exact answer that does
-- not depend on any model, beside whether the reconstructed path enters it.
--
--   psql -d ais -f 06_exact.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS GapPaths CASCADE;
CREATE TABLE GapPaths AS
SELECT g.GapId, g.MMSI, tgeompointSeq(array_agg(tgeompoint(x.Geom, x.T)
  ORDER BY x.T)) AS Path
FROM Gaps g, LATERAL (
  SELECT g.TStart AS T, g.PStart AS Geom
  UNION ALL
  SELECT p.T, r.Geom
  FROM TripPoints p JOIN Reconstructed r USING (GapId, PointIdx)
  WHERE p.GapId = g.GapId AND r.Task = 'gap' AND r.Model = 'crossdomain'
  UNION ALL
  SELECT g.TEnd, g.PEnd ) AS x
GROUP BY g.GapId, g.MMSI;
ALTER TABLE GapPaths ADD PRIMARY KEY (GapId);

DROP TABLE IF EXISTS GapAreas CASCADE;
CREATE TABLE GapAreas AS
WITH Bounds AS (
  SELECT GapId, PStart, PEnd,
    15.4 * extract(epoch FROM TEnd - TStart) AS Reach
  FROM Gaps )
SELECT b.GapId, n.NameEng,
  ST_DWithin(n.Geom, b.PStart, b.Reach) AND
    ST_DWithin(n.Geom, b.PEnd, b.Reach) AS Possible,
  eIntersects(p.Path, n.Geom) AS Reconstructed
FROM Bounds b JOIN GapPaths p USING (GapId), NaturalAreas n
WHERE ST_DWithin(n.Geom, b.PStart, b.Reach);

SELECT Possible, Reconstructed, count(*) AS Pairs, count(DISTINCT GapId) AS Gaps
FROM GapAreas
GROUP BY Possible, Reconstructed
ORDER BY Possible, Reconstructed;
