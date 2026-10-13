-- The mean speed of the vessel in each window, which sets the speed classes of Section 7 of the
-- paper (Fig. errors-paired, "5,356 of the 8,192 windows"): the length of the path through the
-- observed positions of the window outside the gap, in EPSG:25832, over the time it spans, in
-- knots. analyze.py classes a window as below 0.5 knots, 0.5 to 3 knots, or 3 knots or more, a
-- window of zero duration counting as below 0.5 knots.
--
--   psql -d ais -f winspeed.sql

\set ON_ERROR_STOP on
DROP TABLE IF EXISTS WinSpeed;
CREATE TABLE WinSpeed AS
SELECT GapId, (sum(d) / nullif(sum(dt), 0)) * 1.9438445 AS Kn
FROM ( SELECT GapId, ST_Distance(Geom, lag(Geom) OVER w) AS d,
         extract(epoch FROM T - lag(T) OVER w) AS dt
       FROM TripPoints WHERE NOT InGap WINDOW w AS (PARTITION BY GapId ORDER BY T) ) x
GROUP BY GapId;
ALTER TABLE WinSpeed ADD PRIMARY KEY (GapId);

SELECT count(*) FILTER (WHERE coalesce(Kn, 0) < 0.5) AS Below05,
  count(*) FILTER (WHERE Kn >= 0.5 AND Kn < 3) AS From05To3,
  count(*) FILTER (WHERE Kn >= 3) AS From3
FROM WinSpeed;
