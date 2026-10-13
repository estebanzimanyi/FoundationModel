-- The table AISInput: the position reports of the Danish Maritime Authority with the 26 columns
-- of its CSV files, unchanged. MMSI is bigint and text columns are unbounded, so a single
-- malformed value cannot abort the load. reproduce.sh appends one CSV file per day with
--
--   unzip -p aisdk-2026-01-20.zip | PGOPTIONS='-c datestyle=ISO,DMY' psql -d ais -c "\copy
--     AISInput FROM STDIN CSV HEADER"
--
--   psql -d ais -f ais_load.sql

\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS mobilitydb CASCADE;

DROP TABLE IF EXISTS AISInput CASCADE;
CREATE TABLE AISInput(
  T timestamp,
  TypeOfMobile text,
  MMSI bigint,
  Latitude float,
  Longitude float,
  NavigationalStatus text,
  ROT float,
  SOG float,
  COG float,
  Heading integer,
  IMO text,
  CallSign text,
  Name text,
  ShipType text,
  CargoType text,
  Width float,
  Length float,
  TypeOfPositionFixingDevice text,
  Draught float,
  Destination text,
  ETA text,
  DataSourceType text,
  SizeA float,
  SizeB float,
  SizeC float,
  SizeD float
);
