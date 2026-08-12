-- job parameter: raw_root (s3://<bucket>/raw or /Volumes/sc2/bronze/raw)
-- flat statements only: SQL file tasks split on semicolons, so no BEGIN/END blocks

CREATE SCHEMA IF NOT EXISTS sc2.bronze;

DECLARE OR REPLACE VARIABLE raw_root STRING;

SET VARIABLE raw_root = :raw_root;

DECLARE OR REPLACE VARIABLE stmt STRING;

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

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_seasons FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=seasons/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_patches FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=patches/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_player_base FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=player-base/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_activity FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=activity/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_tier_thresholds FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=tier-thresholds/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_balance_reports FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=balance-reports/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.pulse_teams FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=pulse/endpoint=teams/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.aligulac_periods FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=aligulac/endpoint=periods/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.aligulac_matches FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=aligulac/endpoint=matches/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.aligulac_ratings FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=aligulac/endpoint=ratings/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.blizzard_season FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=blizzard/endpoint=season/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.blizzard_league FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=blizzard/endpoint=league/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;

SET VARIABLE stmt = 'COPY INTO sc2.bronze.blizzard_gm_ladder FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM ''' || raw_root || '/source=blizzard/endpoint=gm-ladder/'') FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';

EXECUTE IMMEDIATE stmt;
