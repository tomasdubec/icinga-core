-- -----------------------------------------
-- upgrade path for Icinga IDOUtils 1.11.0
--
-- -----------------------------------------
-- Copyright (c) 2013-2014 Icinga Development Team (http://www.icinga.org)
--
-- Please check http://docs.icinga.org for upgrading information!
-- -----------------------------------------

-- -----------------------------------------
-- config dump in progress
-- -----------------------------------------

ALTER TABLE icinga_programstatus ADD COLUMN config_dump_in_progress SMALLINT DEFAULT 0;

-- -----------------------------------------
-- #4985
-- -----------------------------------------
CREATE INDEX commenthistory_delete_idx ON icinga_commenthistory (instance_id, comment_time, internal_comment_id);

-- -----------------------------------------
-- #4885
-- -----------------------------------------
DROP TABLE IF EXISTS icinga_sla_periods;
CREATE TABLE icinga_sla_periods (
  timeperiod_object_id BIGINT(20) UNSIGNED NOT NULL,
  start_time TIMESTAMP NOT NULL,
  end_time TIMESTAMP NOT NULL,
  PRIMARY KEY tp_start (timeperiod_object_id, start_time),
  UNIQUE KEY tp_end (timeperiod_object_id, end_time)
) ENGINE InnoDB;

DROP TABLE IF EXISTS icinga_outofsla_periods;
CREATE TABLE icinga_outofsla_periods (
  timeperiod_object_id BIGINT(20) UNSIGNED NOT NULL,
  start_time TIMESTAMP NOT NULL,
  end_time TIMESTAMP NOT NULL,
  PRIMARY KEY tp_start (timeperiod_object_id, start_time),
  UNIQUE KEY tp_end (timeperiod_object_id, end_time)
) ENGINE InnoDB;

DROP PROCEDURE IF EXISTS icinga_refresh_slaperiods;

DELIMITER $$

CREATE PROCEDURE icinga_refresh_slaperiods()
BEGIN
  DECLARE t_start DATETIME;
  DECLARE t_end DATETIME;
  DECLARE tp_id, tpo_id BIGINT UNSIGNED;
  DECLARE fake_result INT UNSIGNED;

  DECLARE done INT DEFAULT FALSE;

  DECLARE cursor_tp CURSOR FOR SELECT
          tpo.object_id,
          tp.timeperiod_object_id
        FROM icinga_timeperiods tp
        JOIN icinga_objects tpo ON tp.timeperiod_object_id = tpo.object_id
            AND tpo.is_active = 1;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  -- Workaround for WARNINGS complaining about unsafe statement (insert using Limit)
  SET SESSION binlog_format = ROW;

  START TRANSACTION;

  TRUNCATE TABLE icinga_sla_periods;
   TRUNCATE TABLE icinga_outofsla_periods;

  SELECT
      CAST(DATE_FORMAT(DATE_SUB(NOW(), INTERVAL 5 YEAR), '%Y-01-01 00:00:00') AS DATETIME),
      CAST(DATE_FORMAT(NOW(), '%Y-12-31 23:59:59') AS DATETIME)
    INTO t_start, t_end;

  OPEN cursor_tp;

  tp_loop: LOOP
    FETCH cursor_tp INTO tp_id, tpo_id;
    IF done THEN
      LEAVE tp_loop;
    END IF;

    SET @tp_lastend := NULL,
        @tp_lastday := NULL,
        @day_offset := NULL;

    INSERT
      INTO icinga_outofsla_periods SELECT
        tpo_id,
        DATE_ADD(CAST(monthly.date AS DATETIME), INTERVAL finaltps.start_sec SECOND) AS start_time,
        DATE_ADD(CAST(monthly.date AS DATETIME), INTERVAL finaltps.end_sec SECOND) AS end_time

      FROM (
        SELECT
          DATE_ADD(DATE(t_start), INTERVAL @day_offset := @day_offset + 1 DAY) AS date,
          DAYOFWEEK(DATE_ADD(DATE(t_start), INTERVAL @day_offset DAY)) - 1 AS weekday
        -- there is no generate_series or similar in MySQL, we need at least 2192 lines:
        FROM icinga_objects o
        JOIN (SELECT @day_offset := -1) day_offset
        -- 6 years (this one plus last 5 years):
        ORDER BY object_id
        LIMIT 2194
      ) monthly JOIN (
        SELECT
          NULL AS day,
          NULL as start_sec,
          NULL AS end_sec
        FROM DUAL
        WHERE (@tp_lastday := NULL) IS NOT NULL
          AND ((@tp_lastend := 0) + (@day_offset := -1)) = 1

        UNION SELECT
          cleantps.day,
          cleantps.start_sec,
          cleantps.end_sec
        FROM (
          SELECT
            @tp_lastday AS last_day,
            sortedtps.day AS day,
            CASE sortedtps.day WHEN @tp_lastday THEN @tp_lastend ELSE (@tp_lastday := sortedtps.day) - sortedtps.day END start_sec,
            sortedtps.start_sec + (@tp_lastend := sortedtps.end_sec) * 0 AS end_sec
          FROM (
            SELECT
              singletps.day,
              singletps.start_sec,
              singletps.end_sec
            FROM (
              -- fake start on every day
              SELECT
                @day_offset := CASE
                  WHEN @day_offset < 6 AND @day_offset >= 0 AND @day_offset IS NOT NULL
                  THEN @day_offset + 1
                  ELSE 0
                END AS day,
                0 AS start_sec,
                0 AS end_sec
              -- Fake generate_series:
              FROM icinga_objects LIMIT 7
            UNION
              -- Fake end for every day
              SELECT
                @day_offset := CASE
                  WHEN @day_offset < 6 AND @day_offset >= 0 AND @day_offset IS NOT NULL
                  THEN @day_offset + 1
                  ELSE 0
                END AS day,
                86400 AS start_sec,
                86400 AS end_sec
              -- Fake generate_series:
              FROM icinga_objects LIMIT 7
            UNION
              -- configured time ranges
              SELECT
                day,
                start_sec AS start_sec,
                end_sec AS end_sec
              FROM icinga_timeperiod_timeranges tpr

              JOIN icinga_timeperiods tp ON tp.timeperiod_id = tpr.timeperiod_id
              WHERE tp.timeperiod_object_id = tpo_id
            ) singletps
            ORDER BY singletps.day, singletps.start_sec, singletps.end_sec
          ) sortedtps
        ) cleantps
        WHERE cleantps.end_sec > cleantps.start_sec
      ) finaltps ON finaltps.day = monthly.weekday
      WHERE DATE_ADD(CAST(monthly.date AS DATETIME), INTERVAL finaltps.end_sec - 1 SECOND) <= t_end;

  END LOOP tp_loop;

  CLOSE cursor_tp;

  COMMIT;
  SET SESSION binlog_format = STATEMENT;
  
  -- Workaround for nasty warning:
  -- | Error | 1329 | No data - zero rows fetched, selected, or processed |
  SELECT 0 INTO fake_result FROM icinga_objects LIMIT 1;
END;
$$
DELIMITER ;

-- -----------------------------------------
-- update dbversion
-- -----------------------------------------

INSERT INTO icinga_dbversion (name, version, create_time, modify_time) VALUES ('idoutils', '1.11.0', NOW(), NOW()) ON DUPLICATE KEY UPDATE version='1.11.0', modify_time=NOW();

