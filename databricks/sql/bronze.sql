-- raw files live in the sc2.bronze.raw volume:
--   Free Edition: managed volume, synced from S3 manually
--   full mode: external volume backed by s3://<bucket>/raw
-- either way the path below is identical, so no dynamic SQL is needed

CREATE SCHEMA IF NOT EXISTS sc2.bronze;

CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_seasons          (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_patches          (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_player_base      (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_activity         (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_tier_thresholds  (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_balance_reports  (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.pulse_teams            (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.aligulac_periods       (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.aligulac_matches       (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.aligulac_ratings       (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.blizzard_season        (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.blizzard_league        (doc VARIANT, _file STRING);
CREATE TABLE IF NOT EXISTS sc2.bronze.blizzard_gm_ladder     (doc VARIANT, _file STRING);

COPY INTO sc2.bronze.pulse_seasons
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=seasons/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_patches
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=patches/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_player_base
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=player-base/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_activity
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=activity/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_tier_thresholds
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=tier-thresholds/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_balance_reports
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=balance-reports/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.pulse_teams
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=pulse/endpoint=teams/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.aligulac_periods
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=aligulac/endpoint=periods/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.aligulac_matches
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=aligulac/endpoint=matches/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.aligulac_ratings
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=aligulac/endpoint=ratings/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.blizzard_season
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=blizzard/endpoint=season/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.blizzard_league
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=blizzard/endpoint=league/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');

COPY INTO sc2.bronze.blizzard_gm_ladder
FROM (SELECT parse_json(value) doc, _metadata.file_path _file
      FROM '/Volumes/sc2/bronze/raw/source=blizzard/endpoint=gm-ladder/')
FILEFORMAT = TEXT FORMAT_OPTIONS ('wholetext' = 'true');
