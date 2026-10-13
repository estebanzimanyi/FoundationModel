-- The database reference `kinematic` of Section 7 of the paper (Sect. "Kinematic Interpolation"),
-- for the three tasks: a masked position between two visible positions a and b lies on the cubic
-- Hermite curve whose tangents are the velocities reported at a and b (speed over ground and course
-- over ground); with only a preceding visible position it is moved from a at the reported speed
-- along the reported course, turning at the reported rate of turn (constant turn rate and
-- velocity), and with only a following one it is moved backwards from b in the same way. Below
-- 3 knots the course is unreliable: the segment between a and b, or the extrapolation at the
-- velocity of the last two (first two) visible positions. The course is turned into a grid azimuth
-- of EPSG:25832 through the point 1 km away along the course on the ellipsoid.
-- Reads ModelInput, TripPoints, PointContext; writes the rows of model 'kinematic' of Reconstructed.
\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS KinTaskPoints;
CREATE TABLE KinTaskPoints AS
SELECT i.Task, i.GapId, i.PointIdx, extract(epoch FROM p.T) AS Ts, i.Masked, p.Geom,
  c.SOG, c.ROT,
  CASE WHEN NOT i.Masked AND c.COG IS NOT NULL THEN
    ST_Azimuth(p.Geom, ST_Transform(ST_Project(c.GeomLonLat::geography, 1000,
      radians(c.COG))::geometry, 25832)) END AS Az
FROM ModelInput i JOIN TripPoints p USING (GapId, PointIdx)
  LEFT JOIN PointContext c USING (GapId, PointIdx);
CREATE INDEX ON KinTaskPoints (Task, GapId, PointIdx) WHERE NOT Masked;
ANALYZE KinTaskPoints;

DELETE FROM Reconstructed WHERE Model = 'kinematic';
INSERT INTO Reconstructed
WITH Q AS (
  SELECT s.Task, s.GapId, s.PointIdx, s.Ts,
    a.Ts AS ta, a.Geom AS pa, a.SOG * 1852 / 3600 AS va, a.Az AS aza, a.ROT AS rota, a.SOG AS ka,
    b.Ts AS tb, b.Geom AS pb, b.SOG * 1852 / 3600 AS vb, b.Az AS azb, b.ROT AS rotb, b.SOG AS kb,
    a2.Ts AS ta2, a2.Geom AS pa2, b2.Ts AS tb2, b2.Geom AS pb2
  FROM KinTaskPoints s
    LEFT JOIN LATERAL ( SELECT * FROM KinTaskPoints v WHERE NOT v.Masked AND v.Task = s.Task
      AND v.GapId = s.GapId AND v.PointIdx < s.PointIdx ORDER BY v.PointIdx DESC LIMIT 1 ) a ON true
    LEFT JOIN LATERAL ( SELECT * FROM KinTaskPoints v WHERE NOT v.Masked AND v.Task = s.Task
      AND v.GapId = s.GapId AND v.PointIdx < a.PointIdx ORDER BY v.PointIdx DESC LIMIT 1 ) a2 ON true
    LEFT JOIN LATERAL ( SELECT * FROM KinTaskPoints v WHERE NOT v.Masked AND v.Task = s.Task
      AND v.GapId = s.GapId AND v.PointIdx > s.PointIdx ORDER BY v.PointIdx LIMIT 1 ) b ON true
    LEFT JOIN LATERAL ( SELECT * FROM KinTaskPoints v WHERE NOT v.Masked AND v.Task = s.Task
      AND v.GapId = s.GapId AND v.PointIdx > b.PointIdx ORDER BY v.PointIdx LIMIT 1 ) b2 ON true
  WHERE s.Masked AND (a.Ts IS NOT NULL OR b.Ts IS NOT NULL) ),
-- One-sided motion from a (forward, dt > 0) or from b (backward, dt < 0): constant turn rate and
-- velocity, omega in radians per second from the rate of turn in degrees per minute.
R AS (
  SELECT *, (Ts - ta) / NULLIF(tb - ta, 0) AS sfrac, tb - ta AS TT,
    CASE WHEN tb IS NULL THEN Ts - ta ELSE Ts - tb END AS dt,
    CASE WHEN tb IS NULL THEN va ELSE vb END AS v1,
    CASE WHEN tb IS NULL THEN aza ELSE azb END AS az1,
    CASE WHEN tb IS NULL THEN ka ELSE kb END AS k1,
    radians(coalesce(CASE WHEN tb IS NULL THEN rota ELSE rotb END, 0)) / 60 AS w1,
    CASE WHEN tb IS NULL THEN pa ELSE pb END AS p1
  FROM Q )
SELECT 'kinematic', Task, GapId, PointIdx,
  CASE
    -- both sides: Hermite, or the segment below 3 knots
    WHEN ta IS NOT NULL AND tb IS NOT NULL THEN
      CASE WHEN ka >= 3 AND kb >= 3 AND aza IS NOT NULL AND azb IS NOT NULL THEN
        ST_SetSRID(ST_MakePoint(
          (2*sfrac^3 - 3*sfrac^2 + 1) * ST_X(pa) + (sfrac^3 - 2*sfrac^2 + sfrac) * TT * va * sin(aza)
            + (-2*sfrac^3 + 3*sfrac^2) * ST_X(pb) + (sfrac^3 - sfrac^2) * TT * vb * sin(azb),
          (2*sfrac^3 - 3*sfrac^2 + 1) * ST_Y(pa) + (sfrac^3 - 2*sfrac^2 + sfrac) * TT * va * cos(aza)
            + (-2*sfrac^3 + 3*sfrac^2) * ST_Y(pb) + (sfrac^3 - sfrac^2) * TT * vb * cos(azb)), 25832)
      ELSE ST_LineInterpolatePoint(ST_MakeLine(pa, pb), sfrac) END
    -- one side, reliable course: constant turn rate and velocity
    WHEN k1 >= 3 AND az1 IS NOT NULL THEN
      CASE WHEN abs(w1) < 1e-9 THEN
        ST_Translate(p1, v1 * dt * sin(az1), v1 * dt * cos(az1))
      ELSE
        ST_Translate(p1, v1 / w1 * (cos(az1) - cos(az1 + w1 * dt)),
                         v1 / w1 * (sin(az1 + w1 * dt) - sin(az1))) END
    -- one side, slow: the velocity of the last (first) two visible positions
    WHEN tb IS NULL AND ta2 IS NOT NULL THEN
      ST_Translate(pa, (ST_X(pa) - ST_X(pa2)) * (Ts - ta) / (ta - ta2),
                       (ST_Y(pa) - ST_Y(pa2)) * (Ts - ta) / (ta - ta2))
    WHEN ta IS NULL AND tb2 IS NOT NULL THEN
      ST_Translate(pb, (ST_X(pb2) - ST_X(pb)) * (Ts - tb) / (tb2 - tb),
                       (ST_Y(pb2) - ST_Y(pb)) * (Ts - tb) / (tb2 - tb))
    ELSE coalesce(pa, pb) END
FROM R;

SELECT Task, count(*) FROM Reconstructed WHERE Model = 'kinematic' GROUP BY Task ORDER BY Task;
