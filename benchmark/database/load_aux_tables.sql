-- Ports and protected areas of the study area, read from data/port.csv and data/natural_areas.csv.gz
-- (built by build_aux_data.sh) in the directory $DATA, by default data/ below
-- the working directory.
DROP TABLE IF EXISTS Port;
CREATE TABLE Port (
  Id        integer PRIMARY KEY,
  PortId    varchar(5) NOT NULL,
  DataSrc   bigint,
  PortCoor  varchar(1),
  CntrCode  varchar(2),
  PortName  varchar(100),
  RepMarL   varchar(50),
  Source    varchar(50),
  Traffic   integer,
  Geom      geometry(Polygon,25832)
);
\copy Port (id, PortId, DataSrc, PortCoor, CntrCode, PortName, RepMarL, Source, Traffic, Geom) FROM PROGRAM 'cat "${DATA:-data}/port.csv"' WITH (FORMAT csv, HEADER true, DELIMITER ',')

DROP TABLE IF EXISTS NaturalAreas CASCADE;
CREATE TABLE NaturalAreas (
  Id integer PRIMARY KEY,
  SiteId integer,
  SitePid varchar(52),
  SiteType varchar(80),
  NameEng varchar(80),
  Name varchar(80),
  Desig varchar(80),
  DesigEng varchar(80),
  DesigType varchar(80),
  IucnCat varchar(80),
  IntCrit varchar(80),
  Realm varchar(20),
  RepMArea numeric,
  GisMArea numeric,
  RepArea numeric,
  GisArea numeric,
  NoTake varchar(80),
  NoTkArea numeric,
  Status varchar(80),
  StatusYr integer,
  GovType varchar(80),
  GovSubType varchar(80),
  OwnType varchar(80),
  OwnSubType varchar(80),
  MangAuth varchar(169),
  MangPlan varchar(169),
  Verif varchar(80),
  Metadataid integer,
  PrntISO3 varchar(80),
  ISO3 varchar(80),
  SuppInfo varchar(80),
  ConsObj varchar(80),
  InlndWtrs varchar(80),
  OecmAsmt varchar(80),
  Geom geometry(MultiPolygon,25832)
);
\copy NaturalAreas (Id, SiteId, SitePid, SiteType, NameEng, Name, Desig, DesigEng, DesigType, IucnCat, IntCrit, Realm, RepMArea, GisMArea, RepArea, GisArea, NoTake, NoTkArea, Status, StatusYr, GovType, GovSubType, OwnType, OwnSubType, MangAuth, MangPlan, Verif, Metadataid, PrntISO3, ISO3, SuppInfo, ConsObj, InlndWtrs, OecmAsmt, Geom) FROM PROGRAM 'gzip -dc "${DATA:-data}/natural_areas.csv.gz"' WITH (FORMAT csv, HEADER true, DELIMITER ',')

CREATE INDEX IF NOT EXISTS PortGeomGix ON Port USING GIST (Geom);
CREATE INDEX IF NOT EXISTS NaturalAreasGeomGist ON NaturalAreas USING GIST (Geom);
ANALYZE Port;
ANALYZE NaturalAreas;
SELECT count(*) AS ports FROM Port;
SELECT Realm, count(*) FROM NaturalAreas GROUP BY Realm ORDER BY 2 DESC;
