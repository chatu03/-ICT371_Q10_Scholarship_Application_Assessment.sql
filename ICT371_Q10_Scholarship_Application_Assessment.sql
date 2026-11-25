-- ICT371 Advanced Databases | Question 10
-- Scholarship Application Assessment
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q10.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The six PENDING rows cover both qualifying age limits, exact income and mark cutoffs,
-- and three failures just outside the eligibility rules.
CREATE SCHEMA ict371_q10;
SET search_path = ict371_q10, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE students (
    student_id integer PRIMARY KEY,
    student_number text NOT NULL UNIQUE,
    full_name text NOT NULL
);

CREATE TABLE applications (
    application_id integer PRIMARY KEY,
    student_id integer NOT NULL REFERENCES students,
    age_at_application integer NOT NULL CHECK (age_at_application > 0),
    monthly_income numeric(12,2) NOT NULL
        CHECK (monthly_income >= 0 AND monthly_income <> 'NaN'),
    average_mark numeric(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on date NOT NULL CHECK (isfinite(submitted_on)),
    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id integer NOT NULL REFERENCES applications,
    old_status text NOT NULL,
    new_status text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO students VALUES
    (1, 'ST001', 'Ruth Banda'), (2, 'ST002', 'David Phiri'),
    (3, 'ST003', 'Mary Zulu'), (4, 'ST004', 'Joseph Tembo'),
    (5, 'ST005', 'Grace Chanda'), (6, 'ST006', 'Peter Mwale');

INSERT INTO applications
    (application_id, student_id, age_at_application, monthly_income,
     average_mark, submitted_on, status)
VALUES
    (1, 1, 18, 3000.00, 70.00, DATE '2026-11-23', 'PENDING'),
    (2, 2, 25, 2800.00, 82.00, DATE '2026-11-23', 'PENDING'),
    (3, 3, 17, 1500.00, 90.00, DATE '2026-11-23', 'PENDING'),
    (4, 4, 22, 3000.01, 85.00, DATE '2026-11-24', 'PENDING'),
    (5, 5, 21, 2500.00, 69.99, DATE '2026-11-24', 'PENDING'),
    (6, 6, 20, 1200.00, 76.00, DATE '2026-11-24', 'PENDING');

-- (b) Function
-- Inputs must be valid before eligibility is evaluated. Qualifying inputs satisfy all
-- three inclusive limits.
CREATE FUNCTION fn_scholarship_eligible(
    p_age integer, p_income numeric, p_mark numeric
)
RETURNS boolean LANGUAGE plpgsql SET search_path = ict371_q10, pg_catalog AS $$
BEGIN
    IF p_age IS NULL OR p_age <= 0
       OR p_income IS NULL OR p_income < 0 OR p_income >= 'Infinity'::numeric
       OR p_mark IS NULL OR p_mark NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'Invalid age, household income or average mark';
    END IF;

    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$;

-- (c) Procedure
-- The row lock holds the application while it is read and assessed. The procedure
-- raises an exception if the ID does not exist or the status is already decided.
CREATE PROCEDURE pr_assess_application(p_application_id integer)
LANGUAGE plpgsql SET search_path = ict371_q10, pg_catalog AS $$
DECLARE
    v_application applications%ROWTYPE;
BEGIN
    SELECT * INTO v_application FROM applications
    WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application ID: %', p_application_id;
    END IF;
    IF v_application.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed', p_application_id;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(
        v_application.age_at_application,
        v_application.monthly_income,
        v_application.average_mark
    ) THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
-- The trigger records the old and new status. The changed_at default saves the time of
-- the audit insert.
CREATE FUNCTION fn_audit_scholarship_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q10, pg_catalog AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status)
    VALUES (NEW.application_id, OLD.status, NEW.status);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_scholarship_status
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_audit_scholarship_status();

-- (e) View
-- The approved view displays the requested four columns. After the assessment run, the
-- seeded approvals are Ruth, David and Peter.
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications AS a JOIN students AS s USING (student_id)
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants ORDER BY student_number;

-- (f) Index and execution plan
-- The status column supports equality matching. The submitted_on column then bounds the
-- scan to the requested submission dates.
CREATE INDEX idx_applications_status_date ON applications (status, submitted_on);

EXPLAIN (COSTS OFF)
SELECT application_id, student_id, submitted_on FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN DATE '2026-11-23' AND DATE '2026-11-24';

-- Plan observed on the seed dataset:
-- Seq Scan on applications
--   Filter: ((submitted_on >= '2026-11-23'::date) AND (submitted_on <= '2026-11-24'::date) AND (status = 'PENDING'::text))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_applications_status_date on applications
--   Index Cond: ((status = 'PENDING'::text) AND (submitted_on >= '2026-11-23'::date) AND (submitted_on <= '2026-11-24'::date))

-- (g) Scheduled job
-- The weekly job runs on Monday at 08:00. The query FOR loop locks pending rows in ID
-- order and calls the assessment procedure for each. Later runs select only
-- applications that are still pending.
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql SET search_path = ict371_q10, pg_catalog AS $$
DECLARE
    v_application record;
BEGIN
    FOR v_application IN
        SELECT application_id FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
        FOR UPDATE
    LOOP
        CALL pr_assess_application(v_application.application_id);
    END LOOP;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_assess_pending();
CALL pr_assess_pending();
SELECT * FROM v_approved_applicants ORDER BY student_number;
SELECT COUNT(*) AS audit_rows FROM decision_audit;
ROLLBACK;

-- The first run makes three approvals and three rejections. The second adds zero
-- decisions, so the audit table still contains six rows.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q10',
    '0 8 * * 1',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q10.pr_assess_pending();
    $job$
);
*/
