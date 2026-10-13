-- Paragraph "Context and descriptions in SQL" of Section 7 of the paper: the description of
-- every observed position, rendered by the slot template of the maritime corpus on which the
-- model is pretrained (enrichment-pipeline/maritime/template/descriptor.py of the thesis), with
-- its labels and its formatting of numbers, so that the embeddings of the descriptions lie where
-- the model learned them. The derived attributes follow the maritime enrichment of the thesis:
--   local time   the time zone of the exclusive economic zone of the position (enrich/temporal.py),
--                its day of the week (0 is Monday), hour, season, and part of the day;
--   vessel type  the transport mode of the ship type (segment/trips.py);
--   phase        the behavioral phase of the navigational status, or of the speed with thresholds
--                of 0.5 and 3 knots (enrich/kinematic.py);
--   port         port approach within 5 nautical miles of a port of the World Port Index, coastal
--                within 20, and beyond that the label 'offshort' of the corpus (enrich/spatial.py).
-- The database holds no harbour polygons, no annotation of stops and gaps, and no ocean currents,
-- so the labels that depend on them ('berthed', 'open_anchorage', 'communication_gap') do not
-- occur, and the currents are rendered as the template renders a missing value.
--
--   psql -d ais -f 03_descriptions.sql

\set ON_ERROR_STOP on
SET TimeZone = 'UTC';

DROP TABLE IF EXISTS PointDescriptor CASCADE;
CREATE TABLE PointDescriptor AS
WITH Local AS (
  SELECT c.*,
    c.T AT TIME ZONE CASE c.EEZ
      WHEN 'DNK' THEN 'Europe/Copenhagen' WHEN 'SWE' THEN 'Europe/Stockholm'
      WHEN 'NOR' THEN 'Europe/Oslo' WHEN 'DEU' THEN 'Europe/Berlin'
      WHEN 'POL' THEN 'Europe/Warsaw' WHEN 'NLD' THEN 'Europe/Amsterdam'
      WHEN 'GBR' THEN 'Europe/London' WHEN 'RUS' THEN 'Europe/Moscow'
      ELSE 'UTC' END AS LocalT,
    CASE
      WHEN lower(c.ShipType) IN ('fishing', 'cargo', 'tanker', 'passenger', 'tug')
        THEN lower(c.ShipType)
      WHEN lower(c.ShipType) IN ('towing', 'towing long/wide', 'port tender') THEN 'tug'
      WHEN lower(c.ShipType) IN ('pleasure', 'sailing') THEN 'pleasure_craft'
      WHEN lower(c.ShipType) IN ('hsc', 'pilot', 'sar', 'dredging', 'law enforcement',
        'military', 'diving', 'anti-pollution', 'medical') THEN 'special_craft'
      ELSE 'unknown' END AS Mode,
    CASE lower(trim(c.NavigationalStatus))
      WHEN 'moored' THEN 'at_berth'
      WHEN 'at anchor' THEN 'anchored' WHEN 'aground' THEN 'anchored'
      WHEN 'engaged in fishing' THEN 'fishing'
      WHEN 'not under command' THEN 'maneuvering'
      WHEN 'restricted maneuverability' THEN 'maneuvering'
      WHEN 'restricted manoeuvrability' THEN 'maneuvering'
      WHEN 'restricted manoeuverability' THEN 'maneuvering'
      WHEN 'constrained by her draught' THEN 'maneuvering'
      WHEN 'power-driven vessel towing astern' THEN 'maneuvering'
      WHEN 'power-driven vessel pushing ahead or towing alongside' THEN 'maneuvering'
      WHEN 'ais-sart is active' THEN 'maneuvering'
      WHEN 'ais-sart active' THEN 'maneuvering'
      ELSE CASE
        WHEN c.SOG IS NULL THEN 'transiting'
        WHEN c.SOG < 0.5 THEN 'anchored'
        WHEN c.SOG < 3 THEN 'slow_transit'
        ELSE 'transiting' END END AS Phase,
    round((c.PortDist / 1852)::numeric, 2) AS PortNm,
    round(((c.Heading - c.COG + 180) - 360 * floor((c.Heading - c.COG + 180) / 360) - 180)
      ::numeric, 2) AS Leeway
  FROM PointContext c ),
Slots AS (
  SELECT l.*, extract(isodow FROM LocalT)::int - 1 AS Dow, extract(hour FROM LocalT)::int AS Hour,
    CASE WHEN extract(month FROM LocalT) IN (3, 4, 5) THEN 'spring'
         WHEN extract(month FROM LocalT) IN (6, 7, 8) THEN 'summer'
         WHEN extract(month FROM LocalT) IN (9, 10, 11) THEN 'autumn'
         ELSE 'winter' END AS Season,
    CASE WHEN extract(hour FROM LocalT) < 5 THEN 'night'
         WHEN extract(hour FROM LocalT) < 7 THEN 'early_morning'
         WHEN extract(hour FROM LocalT) < 9 THEN 'am_rush'
         WHEN extract(hour FROM LocalT) < 12 THEN 'morning'
         WHEN extract(hour FROM LocalT) < 14 THEN 'midday'
         WHEN extract(hour FROM LocalT) < 17 THEN 'afternoon'
         WHEN extract(hour FROM LocalT) < 19 THEN 'pm_rush'
         WHEN extract(hour FROM LocalT) < 22 THEN 'evening'
         ELSE 'night' END AS Tod,
    CASE WHEN PortNm < 5 THEN 'port_approach' WHEN PortNm < 20 THEN 'coastal'
         ELSE 'offshort' END AS PortLabel,
    CASE WHEN Heading IS NULL THEN 'unknown'
         ELSE (ARRAY['North', 'Northeast', 'East', 'Southeast', 'South', 'Southwest', 'West',
           'Northwest'])[floor((Heading::numeric % 360 + 22.5) / 45)::int % 8 + 1] END AS HeadCard
  FROM Local l )
SELECT GapId, PointIdx, concat_ws(' ',
  format('[AGENT]: %s, %s, draught %s, speed over ground: %s kn.', Mode, Phase,
    coalesce(round(Draught::numeric, 1)::text, 'unknown'),
    coalesce(round(SOG::numeric, 1)::text, 'unknown')),
  format('[CORRIDOR]: %s, %s.', coalesce(SeaArea, 'open sea'),
    CASE WHEN InTSS THEN format('inside traffic separation scheme (name: %s)',
      coalesce(nullif(TSS, ''), 'unknown'))
    ELSE 'no traffic separation scheme' END),
  format('[INFRASTRUCTURE]: %s, closest to port %s (%s nm).', PortLabel, PortName,
    round(PortNm, 1)),
  format('[REGULATORY_ZONE]: %s%s, %s.',
    CASE WHEN EEZ IS NULL THEN 'high seas' ELSE EEZ || ' Exclusive Economic Zone' END,
    CASE WHEN TerritorialSea THEN ' (territorial sea)' ELSE '' END,
    CASE WHEN InProtected AND nullif(Protected, '') IS NOT NULL
           THEN format('marine protected area (%s)', Protected)
         WHEN InProtected THEN 'marine protected area'
         ELSE 'not within a marine protected area' END),
  format('[BEHAVIORAL_PHASE]: %s, %s, heading %s%s, navigational status: %s.',
    replace(Phase, '_', ' '),
    coalesce(round(SOG::numeric, 1) || ' kn', 'unknown speed'), HeadCard,
    CASE WHEN abs(Leeway) > 10 THEN format(', leeway %s%s degrees',
      CASE WHEN Leeway > 0 THEN '+' ELSE '' END, round(Leeway)) ELSE '' END,
    coalesce(nullif(lower(trim(NavigationalStatus)), ''), 'unknown')),
  format('[ENVIRONMENT]: %s, current data unavailable.',
    coalesce('waves ' || round(Waves::numeric, 1) || ' m', 'wave height unknown')),
  format('[TEMPORAL]: %s, %s:00, %s, %s.',
    (ARRAY['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'])[Dow + 1], lpad(Hour::text, 2, '0'), Tod, Season),
  format('[SPATIAL_CONTEXT]: %s.', concat_ws(', ',
    coalesce('water depth ' || round(Depth::numeric) || ' m', 'water depth unknown'),
    'geohash ' || ST_GeoHash(GeomLonLat, 7)))) AS Description
FROM Slots;
ALTER TABLE PointDescriptor ADD PRIMARY KEY (GapId, PointIdx);

SELECT Description FROM PointDescriptor ORDER BY GapId, PointIdx LIMIT 3;
