-- Paragraph "Context and descriptions in SQL" of Section 7 of the paper: the context of
-- every observed position of the windows, the attributes from which the descriptions of
-- 03_descriptions.sql are rendered. They are the attributes of the maritime enrichment of the
-- thesis (enrichment-pipeline/maritime/enrich/), computed from the tables of the AIS database
-- (Ships, AISClean, Vessels), of reproduce.sh (Bathymetry, WaveHeight, NaturalAreas), and of
-- load_context.sh (WPIPort, SeaAreas, EEZ, TerritorialSea, TSS). The longitude and latitude of a
-- position come from the trip of the vessel in WGS 84, TripLonLat, so no geometry is transformed.
-- The positions are those of TripPoints and Gaps, and the context is written to PointContext; the
-- psql variables points, gaps, and context name other tables of the same columns, as for the
-- stretches of synthetic.py (SynthPoints, SynthGaps, SynthContext).
--
--   psql -d ais -f 02_context.sql
--   psql -d ais -v points=SynthPoints -v gaps=SynthGaps -v context=SynthContext -f 02_context.sql

\set ON_ERROR_STOP on
\if :{?points}
\else
  \set points TripPoints
\endif
\if :{?gaps}
\else
  \set gaps Gaps
\endif
\if :{?context}
\else
  \set context PointContext
\endif
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS :context CASCADE;
CREATE TABLE :context AS
SELECT p.GapId, p.PointIdx, p.T, g.MMSI, p.Geom,
  valueAtTimestamp(s.TripLonLat, p.T) AS GeomLonLat,
  valueAtTimestamp(s.SOG, p.T) AS SOG, valueAtTimestamp(s.COG, p.T) AS COG,
  valueAtTimestamp(s.Heading, p.T) AS Heading, valueAtTimestamp(s.ROT, p.T) AS ROT,
  r.NavigationalStatus, r.Draught, v.ShipType,
  ( SELECT ST_Value(b.Rast, p.Geom) FROM Bathymetry b
    WHERE ST_Intersects(b.Rast, p.Geom) LIMIT 1 ) AS Depth,
  ( SELECT ST_Value(w.Rast, p.Geom) FROM WaveHeight w
    WHERE w.ValidTime @> p.T AND ST_Intersects(w.Rast, p.Geom) LIMIT 1 ) AS Waves,
  o.Name AS PortName, o.Dist AS PortDist,
  ( SELECT a.Name FROM SeaAreas a WHERE ST_Intersects(a.Geom, p.Geom) LIMIT 1 ) AS SeaArea,
  ( SELECT e.Iso FROM EEZ e WHERE ST_Intersects(e.Geom, p.Geom) LIMIT 1 ) AS EEZ,
  EXISTS ( SELECT 1 FROM TerritorialSea t WHERE ST_Intersects(t.Geom, p.Geom) )
    AS TerritorialSea,
  ( SELECT t.Name FROM TSS t WHERE ST_Intersects(t.Geom, p.Geom) LIMIT 1 ) AS TSS,
  EXISTS ( SELECT 1 FROM TSS t WHERE ST_Intersects(t.Geom, p.Geom) ) AS InTSS,
  ( SELECT n.NameEng FROM NaturalAreas n WHERE ST_Intersects(n.Geom, p.Geom) LIMIT 1 )
    AS Protected,
  EXISTS ( SELECT 1 FROM NaturalAreas n WHERE ST_Intersects(n.Geom, p.Geom) ) AS InProtected
FROM :points p JOIN :gaps g USING (GapId) JOIN Ships s USING (MMSI)
  LEFT JOIN Vessels v USING (MMSI)
  LEFT JOIN LATERAL (
    SELECT c.NavigationalStatus, c.Draught FROM AISClean c
    WHERE c.MMSI = g.MMSI AND c.T <= p.T
    ORDER BY c.T DESC LIMIT 1 ) r ON true
  LEFT JOIN LATERAL (
    SELECT w.Name, ST_Distance(w.Geom, p.Geom) AS Dist FROM WPIPort w
    ORDER BY w.Geom <-> p.Geom LIMIT 1 ) o ON true
WHERE NOT p.InGap;
ALTER TABLE :context ADD PRIMARY KEY (GapId, PointIdx);
ANALYZE :context;

SELECT count(*) AS Positions, count(SOG) AS WithSOG, count(Heading) AS WithHeading,
  count(Depth) AS WithDepth, count(Waves) AS WithWaves, count(SeaArea) AS WithSeaArea,
  count(EEZ) AS WithEEZ, count(*) FILTER (WHERE InTSS) AS InTSS,
  count(*) FILTER (WHERE InProtected) AS InProtected
FROM :context;
