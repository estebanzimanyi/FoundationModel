-- The tables Vessels and Ships, built from AISClean.
--
-- Vessels holds one row per vessel with its static attributes, each the value it reports most
-- often over the period, ties broken by the smallest value.
--
-- Ships holds one row per vessel with its trajectory over the period, in EPSG:25832 in Trip and
-- in longitude and latitude in TripLonLat, and the speed over ground (knots), course over ground
-- (degrees), heading (degrees) and rate of turn (degrees per minute) it reports, as temporal
-- floats. The speed is interpolated linearly between two reports; the course and the heading are
-- angles, which a linear interpolation from 359 to 1 degree would sweep through 180 degrees, so
-- they and the rate of turn use step interpolation, keeping a reported value until the next. Every
-- temporal value has a gap wherever the vessel is silent for more than 600 s, the rule that cuts
-- AISClean into pieces. A speed over ground of 102.3 kn is the code AIS uses for a speed that is
-- not available, and is left out of SOG; the Danish Maritime Authority leaves an unavailable
-- heading or rate of turn empty.
--
--   psql -d ais -f ais_ships.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS Vessels CASCADE;
CREATE TABLE Vessels AS
SELECT MMSI,
  mode() WITHIN GROUP (ORDER BY Name COLLATE "C") AS Name,
  mode() WITHIN GROUP (ORDER BY IMO COLLATE "C") AS IMO,
  mode() WITHIN GROUP (ORDER BY CallSign COLLATE "C") AS CallSign,
  mode() WITHIN GROUP (ORDER BY ShipType COLLATE "C") AS ShipType,
  mode() WITHIN GROUP (ORDER BY CargoType COLLATE "C") AS CargoType,
  mode() WITHIN GROUP (ORDER BY Length) AS Length,
  mode() WITHIN GROUP (ORDER BY Width) AS Width,
  mode() WITHIN GROUP (ORDER BY Draught) AS Draught,
  mode() WITHIN GROUP (ORDER BY SizeA) AS SizeA,
  mode() WITHIN GROUP (ORDER BY SizeB) AS SizeB,
  mode() WITHIN GROUP (ORDER BY SizeC) AS SizeC,
  mode() WITHIN GROUP (ORDER BY SizeD) AS SizeD
FROM AISClean
GROUP BY MMSI;
ALTER TABLE Vessels ADD PRIMARY KEY (MMSI);

DROP TABLE IF EXISTS Ships CASCADE;
CREATE TABLE Ships AS
SELECT MMSI,
  tgeompointSeqSetGaps(array_agg(tgeompoint(Geom, T) ORDER BY T), interval '600 s') AS Trip,
  tgeompointSeqSetGaps(
    array_agg(tgeompoint(ST_Point(Longitude, Latitude, 4326), T) ORDER BY T),
    interval '600 s') AS TripLonLat,
  tfloatSeqSetGaps(array_agg(tfloat(SOG, T) ORDER BY T) FILTER (WHERE SOG < 102.3),
    interval '600 s') AS SOG,
  tfloatSeqSetGaps(array_agg(tfloat(COG, T) ORDER BY T) FILTER (WHERE COG IS NOT NULL),
    interval '600 s', NULL, 'step') AS COG,
  tfloatSeqSetGaps(array_agg(tfloat(Heading, T) ORDER BY T) FILTER (WHERE Heading IS NOT NULL),
    interval '600 s', NULL, 'step') AS Heading,
  tfloatSeqSetGaps(array_agg(tfloat(ROT, T) ORDER BY T) FILTER (WHERE ROT IS NOT NULL),
    interval '600 s', NULL, 'step') AS ROT
FROM AISClean
GROUP BY MMSI;
ALTER TABLE Ships ADD PRIMARY KEY (MMSI);

SELECT count(*) AS Ships, count(SOG) AS WithSOG, count(COG) AS WithCOG,
  count(Heading) AS WithHeading, count(ROT) AS WithROT,
  sum(numSequences(Trip)) AS Pieces
FROM Ships;
