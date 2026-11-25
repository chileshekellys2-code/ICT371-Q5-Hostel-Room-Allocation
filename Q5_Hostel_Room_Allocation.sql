-- ICT371 Advanced Database
-- QUESTION 5: Hostel Room Allocation
-- Extracted as an individual repository from the supplied Q2-Q10 script.
--
-- PostgreSQL prerequisite:
-- This question schedules a job using pg_cron. The server must have pg_cron
-- installed/configured (including shared_preload_libraries and restart).
-- If pg_cron is unavailable, execute the database objects and seed statements
-- separately, and skip/comment the cron.schedule statement at the end.
--
-- This script creates schema q5; it does not drop existing data.
-- ============================================================

-- Q5  HOSTEL ROOM ALLOCATION
-- =====================================================================
CREATE SCHEMA q5;  SET search_path TO q5;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) only ACTIVE rows occupy beds
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INTEGER AS $$
DECLARE
    v_cap INTEGER;
    v_occ INTEGER;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    SELECT COUNT(*) INTO v_occ FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';
    RETURN v_cap - v_occ;
END;
$$ LANGUAGE plpgsql;

-- (c)
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id: %', p_student_id; END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- lock room
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id: %', p_room_id; END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) same rules for direct SQL; exclude the row being changed from the counts
CREATE OR REPLACE FUNCTION trg_fn_alloc_rules() RETURNS TRIGGER AS $$
DECLARE
    v_cap INTEGER;
    v_occ INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
                     AND a.allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        SELECT COUNT(*) INTO v_occ FROM allocations a
        WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;
        IF v_occ >= v_cap THEN
            RAISE EXCEPTION 'Room % is at full capacity (%)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_alloc_rules();

-- (a) seed: R101 full (2/2), R102 partly (1/3), R103 empty (history only)
INSERT INTO students (student_number, full_name) VALUES
    ('H001','Mwansa Chola'), ('H002','Bwalya Kabwe'), ('H003','Natasha Daka'),
    ('H004','Joseph Mulenga'), ('H005','Esther Sichone');
INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 10, 'ENDED');   -- history, no bed used
-- Should FAIL (room full): CALL pr_allocate_room(5, 1, CURRENT_DATE);

-- (e) LEFT JOIN keeps rooms with no allocations; condition in ON keeps them
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) partial index: only ACTIVE rows (the ones we count)
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) one row per date+room (composite PK); rerun overwrites
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule('q5_occupancy', '55 23 * * *',
    $$SET search_path TO q5; CALL pr_refresh_occupancy()$$);

-- =====================================================================
