-- The reference 'kinematic', computed by the database alone from the speed over ground, course over
-- ground, and rate of turn reported at the visible positions. Between two visible positions a and b,
-- a masked position lies on the cubic Hermite curve whose tangents are the reported velocities; when
-- no visible position follows (prediction) or precedes it, the vessel is moved from the nearest
-- visible position at its reported speed, turning at its reported rate (constant turn rate and
-- velocity), which is a straight line when the rate of turn is zero. Below 3 knots the reported
-- course is unreliable, and the reference falls back to the segment between a and b, or to the
-- extrapolation of the velocity of the last two visible positions.
--
--   psql -d ais -v model=kinematic -f kinematic.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DELETE FROM Reconstructed WHERE Model = :'model';

CREATE TEMP TABLE TaskPoints AS
SELECT i.Task, i.GapId, i.PointIdx, p.T, i.Masked, p.Geom
FROM ModelInput i JOIN TripPoints p USING (GapId, PointIdx);
CREATE TEMP TABLE Visible AS
SELECT t.Task, t.GapId, t.PointIdx, t.T, t.Geom, c.SOG, c.ROT,
  CASE WHEN c.COG IS NOT NULL THEN ST_Azimuth(t.Geom, ST_Transform(ST_Project(
    ST_Transform(t.Geom, 4326)::geography, 1000, radians(c.COG))::geometry, 25832)) END AS Az
FROM TaskPoints t JOIN PointContext c USING (GapId, PointIdx)
WHERE NOT t.Masked;
CREATE INDEX ON Visible (Task, GapId, PointIdx);
ANALYZE Visible;

CREATE TEMP TABLE Neighbors AS
SELECT s.Task, s.GapId, s.PointIdx, s.T,
  a.T AS TA, a.Geom AS GA, a.SOG AS KA, a.Az AS AzA, a.ROT AS RA,
  a2.T AS TA2, a2.Geom AS GA2,
  b.T AS TB, b.Geom AS GB, b.SOG AS KB, b.Az AS AzB, b.ROT AS RB
FROM TaskPoints s
  LEFT JOIN LATERAL ( SELECT * FROM Visible v WHERE v.Task = s.Task AND v.GapId = s.GapId
    AND v.PointIdx < s.PointIdx ORDER BY v.PointIdx DESC LIMIT 1 ) a ON true
  LEFT JOIN LATERAL ( SELECT * FROM Visible v WHERE v.Task = s.Task AND v.GapId = s.GapId
    AND v.PointIdx < a.PointIdx ORDER BY v.PointIdx DESC LIMIT 1 ) a2 ON true
  LEFT JOIN LATERAL ( SELECT * FROM Visible v WHERE v.Task = s.Task AND v.GapId = s.GapId
    AND v.PointIdx > s.PointIdx ORDER BY v.PointIdx LIMIT 1 ) b ON true
WHERE s.Masked AND (a.T IS NOT NULL OR b.T IS NOT NULL);

-- Constant turn rate and velocity from position g at azimuth az (radians, clockwise from the grid
-- north), speed k (knots), and rate of turn r (degrees per minute), after dt seconds (negative
-- backwards in time).
CREATE OR REPLACE FUNCTION pg_temp.ctrv(g geometry, az float, k float, r float, dt float)
RETURNS geometry AS $$
  SELECT CASE WHEN abs(w) < 1e-9 THEN
      ST_Translate(g, v * dt * sin(az), v * dt * cos(az))
    ELSE
      ST_Translate(g, v / w * (cos(az) - cos(az + w * dt)), v / w * (sin(az + w * dt) - sin(az)))
    END
  FROM (SELECT k * 1852 / 3600 AS v, radians(coalesce(r, 0)) / 60 AS w) AS p
$$ LANGUAGE sql IMMUTABLE;

INSERT INTO Reconstructed
SELECT :'model', Task, GapId, PointIdx,
  CASE
    WHEN TA IS NOT NULL AND TB IS NOT NULL AND KA >= 3 AND KB >= 3
        AND AzA IS NOT NULL AND AzB IS NOT NULL THEN
      ST_SetSRID(ST_MakePoint(
        (2*s^3 - 3*s^2 + 1) * ST_X(GA) + (s^3 - 2*s^2 + s) * D * KA * 1852 / 3600 * sin(AzA)
          + (-2*s^3 + 3*s^2) * ST_X(GB) + (s^3 - s^2) * D * KB * 1852 / 3600 * sin(AzB),
        (2*s^3 - 3*s^2 + 1) * ST_Y(GA) + (s^3 - 2*s^2 + s) * D * KA * 1852 / 3600 * cos(AzA)
          + (-2*s^3 + 3*s^2) * ST_Y(GB) + (s^3 - s^2) * D * KB * 1852 / 3600 * cos(AzB)), 25832)
    WHEN TA IS NOT NULL AND TB IS NOT NULL THEN
      ST_LineInterpolatePoint(ST_MakeLine(GA, GB), s)
    WHEN TB IS NULL AND KA >= 3 AND AzA IS NOT NULL THEN
      pg_temp.ctrv(GA, AzA, KA, RA, extract(epoch FROM T - TA))
    WHEN TA IS NULL AND KB >= 3 AND AzB IS NOT NULL THEN
      pg_temp.ctrv(GB, AzB, KB, RB, extract(epoch FROM T - TB))
    WHEN TB IS NULL AND TA2 IS NOT NULL THEN
      ST_Translate(GA,
        (ST_X(GA) - ST_X(GA2)) * extract(epoch FROM T - TA) / extract(epoch FROM TA - TA2),
        (ST_Y(GA) - ST_Y(GA2)) * extract(epoch FROM T - TA) / extract(epoch FROM TA - TA2))
    ELSE coalesce(GA, GB) END
FROM ( SELECT *, extract(epoch FROM TB - TA) AS D,
         extract(epoch FROM T - TA) / extract(epoch FROM TB - TA) AS s
       FROM Neighbors ) AS n;
