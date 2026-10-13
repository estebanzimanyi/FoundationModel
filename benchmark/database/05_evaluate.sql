-- Section 7 of the paper, "Results": the reconstructions written by run_model.py and
-- run_unitraj.py, in the reference system of the database, and their errors at the positions fixed
-- in EvalMasks. kinematic.sql then adds the rows of the reference 'kinematic' to Reconstructed,
-- and analyze.py reads the view Errors.
--
--   psql -d ais -f 05_evaluate.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS Reconstructed CASCADE;
CREATE TABLE Reconstructed AS
SELECT Model, Task, GapId, PointIdx,
  ST_Transform(ST_Point(Lon, Lat, 4326), 25832) AS Geom
FROM ReconstructedLonLat;
ALTER TABLE Reconstructed ADD PRIMARY KEY (Model, Task, GapId, PointIdx);

CREATE VIEW Errors AS
SELECT r.Model, r.Task, r.GapId, r.PointIdx, ST_Distance(r.Geom, p.Geom) AS Err
FROM Reconstructed r JOIN EvalMasks m USING (Task, GapId, PointIdx)
  JOIN TripPoints p USING (GapId, PointIdx);
