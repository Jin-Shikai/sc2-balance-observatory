-- job parameter: raw_root = s3://<bucket>/raw

CREATE SCHEMA IF NOT EXISTS sc2.bronze;

DECLARE OR REPLACE VARIABLE raw_root STRING;
SET VARIABLE raw_root = :raw_root;

BEGIN
  FOR r AS SELECT * FROM VALUES
      ('pulse_seasons',         'source=pulse/endpoint=seasons'),
      ('pulse_patches',         'source=pulse/endpoint=patches'),
      ('pulse_player_base',     'source=pulse/endpoint=player-base'),
      ('pulse_activity',        'source=pulse/endpoint=activity'),
      ('pulse_tier_thresholds', 'source=pulse/endpoint=tier-thresholds'),
      ('pulse_balance_reports', 'source=pulse/endpoint=balance-reports'),
      ('pulse_teams',           'source=pulse/endpoint=teams'),
      ('aligulac_periods',      'source=aligulac/endpoint=periods'),
      ('aligulac_matches',      'source=aligulac/endpoint=matches'),
      ('aligulac_ratings',      'source=aligulac/endpoint=ratings'),
      ('blizzard_season',       'source=blizzard/endpoint=season'),
      ('blizzard_league',       'source=blizzard/endpoint=league'),
      ('blizzard_gm_ladder',    'source=blizzard/endpoint=gm-ladder')
    AS t(tbl, path)
  DO
    EXECUTE IMMEDIATE
      'CREATE TABLE IF NOT EXISTS sc2.bronze.' || r.tbl || ' (doc VARIANT, _file STRING)';
    EXECUTE IMMEDIATE
      'COPY INTO sc2.bronze.' || r.tbl
      || ' FROM (SELECT parse_json(value) doc, _metadata.file_path _file FROM '''
      || raw_root || '/' || r.path || '/'')'
      || ' FILEFORMAT = TEXT FORMAT_OPTIONS (''wholetext'' = ''true'')';
  END FOR;
END;
