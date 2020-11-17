
create or replace function trs_before() returns trigger language plpgsql as $$
BEGIN
  RAISE NOTICE 'BEFORE STATEMENT %', TG_OP;
  RETURN NULL;
END;
$$;

create or replace function trs_after() returns trigger language plpgsql as $$
DECLARE
   r RECORD;
BEGIN
   RAISE NOTICE 'AFTER STATEMENT %', TG_OP;
   IF (TG_OP = 'DELETE') THEN
     FOR R IN select * from old_table
     LOOP
        RAISE NOTICE '  (%)', r.i;
     END LOOP;
   ELSE
     FOR R IN select * from new_table
     LOOP
        RAISE NOTICE '  (%)', r.i;
     END LOOP;
   END IF;
   RETURN NULL;
END;
$$;

create or replace function trr_before() returns trigger language plpgsql as $$
BEGIN
   RAISE NOTICE 'BEFORE ROW %: (%)', TG_OP, NEW.i;
   RETURN NEW;
END;
$$;

create or replace function trr_after() returns trigger language plpgsql as $$
BEGIN
   RAISE NOTICE 'AFTER ROW %: (%)', TG_OP, NEW.i;
   RETURN NEW;
END;
$$;

create table test_tr(i int) using cstore_tableam;

create trigger tr_before_stmt before insert on test_tr
  for each statement execute procedure trs_before();
create trigger tr_after_stmt after insert on test_tr
  referencing new table as new_table
  for each statement execute procedure trs_after();

create trigger tr_before_row before insert on test_tr
  for each row execute procedure trr_before();

-- after triggers require TIDs, which are not supported yet
create trigger tr_after_row after insert on test_tr
  for each row execute procedure trr_after();

insert into test_tr values(1);
insert into test_tr values(2),(3),(4);

SELECT * FROM test_tr ORDER BY i;

drop table test_tr;
create table test_tr(i int) using cstore_tableam;

-- we should be able to clean-up and continue gracefully if we
-- error out in AFTER STATEMENT triggers.
CREATE SEQUENCE counter START 100;
create or replace function trs_after_erroring() returns trigger language plpgsql as $$
BEGIN
  IF nextval('counter') % 2 = 0 THEN
   RAISE EXCEPTION '%', 'error';
  END IF;
  RETURN NULL;
END;
$$;

create trigger tr_after_stmt_erroring after insert on test_tr
  referencing new table as new_table
  for each statement execute procedure trs_after_erroring();

--
-- Once upon a time we didn't clean-up properly after erroring out. Here the first
-- statement errors, but the second succeeds. In old times, because of failure in
-- clean-up, both rows were visible. But only the 2nd one should be visible.
--
insert into test_tr values(5);
insert into test_tr values(6);
SELECT * FROM test_tr ORDER BY i;

drop table test_tr;

--
-- https://github.com/citusdata/cstore2/issues/32
--
create table events(
  user_id bigint,
  event_id bigint,
  event_time timestamp default now(),
  value float default random())
  PARTITION BY RANGE (event_time);

create table events_p2020_11_04_102965
PARTITION OF events FOR VALUES FROM ('2020-11-04 00:00:00+01') TO ('2020-11-05 00:00:00+01')
USING cstore_tableam;

create table events_trigger_target(
  user_id bigint,
  avg float,
  __count__ bigint
) USING cstore_tableam;

CREATE OR REPLACE FUNCTION user_value_by_day()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
    EXECUTE format($exec_format$INSERT INTO %s AS __mat__ SELECT user_id, 0.1 AS avg, pg_catalog.count(*) AS __count__ FROM __ins__ events GROUP BY user_id;
                   $exec_format$, TG_ARGV[0]);
  END IF;
  IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') THEN
    RAISE EXCEPTION $ex$MATERIALIZED VIEW 'user_value_by_day' on table 'events' does not support UPDATE/DELETE$ex$;
  END IF;
  IF (TG_OP = 'TRUNCATE') THEN
    EXECUTE format($exec_format$TRUNCATE TABLE %s; $exec_format$, TG_ARGV[0]);
  END IF;
  RETURN NULL;
END;
$function$;

create trigger "user_value_by_day_INSERT" AFTER INSERT ON events
  REFERENCING NEW TABLE AS __ins__
  FOR EACH STATEMENT EXECUTE FUNCTION user_value_by_day('events_trigger_target');

COPY events FROM STDIN WITH (FORMAT 'csv');
1,1,"2020-11-04 15:54:02.226999-08",1.1
2,3,"2020-11-04 16:54:02.226999-08",2.2
\.

SELECT * FROM events ORDER BY user_id;
SELECT * FROM events_trigger_target ORDER BY user_id;

DROP TABLE events;
