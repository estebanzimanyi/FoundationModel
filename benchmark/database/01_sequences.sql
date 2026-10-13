-- Paragraph "Preparing the sequences" of Section 7 of the paper: the gaps of at most 30 minutes
-- of the trips of Ships, and for each gap a window extending 15 minutes before and after it,
-- sampled every minute, the canonical interval of the maritime corpus on which the model is
-- pretrained, together with the last report before the gap and the first one after it, at their
-- own instants, since a trip may end or resume with a single report, which the sampling at whole
-- minutes misses. The instants strictly inside the gap are the positions to reconstruct.
--
-- The variable sample keeps a share of the gaps, in percent (100 by default), chosen by a hash of
-- the key of each gap, so that every run with the same share studies the same gaps; a share of 5
-- lets a computer without a GPU embed the descriptions in a reasonable time.
--
--   psql -d ais -v sample=100 -f 01_sequences.sql

\set ON_ERROR_STOP on
\if :{?sample}
\else
  \set sample 100
\endif
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS Gaps CASCADE;
CREATE TABLE Gaps AS
WITH Seqs AS (
  SELECT MMSI, unnest(sequences(Trip)) AS Seq
  FROM Ships ),
Pairs AS (
  SELECT MMSI, endTimestamp(Seq) AS TStart, endValue(Seq) AS PStart,
    LEAD(startTimestamp(Seq)) OVER w AS TEnd,
    LEAD(startValue(Seq)) OVER w AS PEnd
  FROM Seqs
  WINDOW w AS (PARTITION BY MMSI ORDER BY startTimestamp(Seq)) )
SELECT * FROM (
  SELECT row_number() OVER (ORDER BY MMSI, TStart) AS GapId,
    MMSI, TStart, TEnd, PStart, PEnd
  FROM Pairs
  WHERE TEnd IS NOT NULL AND TEnd - TStart <= interval '30 minutes' ) AS g
WHERE abs(hashtext(format('gap/%s', GapId))) % 100 < :sample;
ALTER TABLE Gaps ADD PRIMARY KEY (GapId);

DROP TABLE IF EXISTS TripPoints CASCADE;
CREATE TABLE TripPoints AS
WITH Windows AS (
  SELECT GapId, MMSI, TStart, TEnd,
    span(TStart - interval '15 minutes', TEnd + interval '15 minutes') AS Win
  FROM Gaps ),
Observed AS (
  SELECT w.GapId, getTimestamp(i) AS T, getValue(i) AS Geom
  FROM Windows w JOIN Ships s USING (MMSI),
    unnest(instants(tsample(atTime(s.Trip, w.Win), interval '1 minute'))) AS i ),
Bounds AS (
  SELECT GapId, TStart AS T, PStart AS Geom FROM Gaps
  UNION ALL
  SELECT GapId, TEnd, PEnd FROM Gaps ),
Missing AS (
  SELECT GapId, T, NULL::geometry AS Geom
  FROM Windows, generate_series(date_bin('1 minute', TStart, '2000-01-03'),
    TEnd, interval '1 minute') AS T
  WHERE T > TStart AND T < TEnd )
SELECT GapId,
  row_number() OVER (PARTITION BY GapId ORDER BY T) - 1 AS PointIdx,
  T, Geom, Geom IS NULL AS InGap
FROM (
  SELECT DISTINCT ON (GapId, T) *
  FROM (SELECT * FROM Observed UNION ALL SELECT * FROM Bounds
        UNION ALL SELECT * FROM Missing) AS u
  ORDER BY GapId, T, Geom IS NULL ) AS p;
ALTER TABLE TripPoints ADD PRIMARY KEY (GapId, PointIdx);
ANALYZE Gaps, TripPoints;

SELECT count(*) AS Gaps, count(DISTINCT MMSI) AS Vessels,
  min(TEnd - TStart) AS Shortest, max(TEnd - TStart) AS Longest
FROM Gaps;
SELECT count(*) AS Positions, count(*) FILTER (WHERE InGap) AS InGap,
  max(PointIdx) + 1 AS LongestWindow
FROM TripPoints;
