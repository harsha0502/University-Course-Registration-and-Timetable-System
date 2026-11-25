-- =====================================================================
--  UNIVERSITY COURSE REGISTRATION & TIMETABLE SYSTEM  |  END-TO-END MYSQL PROJECT
-- =====================================================================
--  Contents:
--    PART 1  : Database & Table Creation (schema)
--    PART 2  : Sample Data (INSERT statements)
--    PART 3  : Indexes (7)
--    PART 4  : Views (8)
--    PART 5  : Functions (2) & Stored Procedures (8 + 1 for Q12)
--    PART 6  : Triggers (7)
--    PART 7  : Reporting Queries Q1-Q4   + Answers
--    PART 8  : Reporting Queries Q5-Q7   + Answers
--    PART 9  : Scenario Questions Q8-Q12 + Answers
--    PART 10 : Demo calls for Views / Procedures / Functions / Triggers
--
--  RDBMS   : MySQL 8.0+ (also compatible with MariaDB 10.x)
--  Notes   : 1) Every ANSWER below a query is a comment showing what that
--               query returns against the sample data in PART 2.
--            2) Run the file top to bottom ONCE. The scenario questions
--               (PART 9) change data (drops, promotions), so to re-run them
--               just re-run the whole file - it starts with DROP DATABASE.
--            3) Lines marked "-- RUN SEPARATELY (expected error)" raise an
--               error ON PURPOSE to prove a trigger works. They are
--               commented out so the file runs without stopping.
--            4) Today's date is NOT used anywhere. Every procedure takes a
--               date parameter, so the demo results never change.
--
--  Design notes (limitations of MySQL worth knowing):
--    * A trigger cannot INSERT into the table it fires on (error 1442).
--      So the "promote the first waitlisted student" rule is split:
--        - trg_promote_waitlist (AFTER UPDATE on registrations) frees the
--          seat, marks the first waiting student PROMOTED and renumbers
--          the rest of the waitlist.
--        - sp_drop_course then inserts that student's registration, in
--          the SAME transaction, and marks the waitlist row CONFIRMED.
--      Always drop through sp_drop_course / sp_add_drop_course.
--    * "18 to 24 credits": 24 is enforced at INSERT time by a trigger
--      (a student cannot be forced to hold 18 credits after one insert).
--      The 18 minimum is checked by v_credit_summary, Q4 and
--      sp_close_registration.
-- =====================================================================


-- =====================================================================
-- PART 1: DATABASE & TABLE CREATION
-- =====================================================================
DROP DATABASE IF EXISTS university_registration;
CREATE DATABASE university_registration;
USE university_registration;

-- ---------- Terms (holds the add-drop window) ----------
CREATE TABLE terms (
    term_id      INT AUTO_INCREMENT PRIMARY KEY,
    term_name    VARCHAR(30),
    start_date   DATE,
    add_drop_end DATE,          -- last day on which a drop is allowed
    end_date     DATE,
    is_closed    TINYINT DEFAULT 0   -- 1 = registration locked
);

-- ---------- Strong Entity: STUDENTS ----------
CREATE TABLE students (
    student_id    INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(100),
    email         VARCHAR(100),
    department    VARCHAR(50),
    year_of_study INT
);

-- ---------- Strong Entity: COURSES ----------
CREATE TABLE courses (
    course_id   INT AUTO_INCREMENT PRIMARY KEY,
    course_code VARCHAR(10),
    course_name VARCHAR(100),
    credits     INT
);

-- ---------- Course -> Prerequisite course (many-to-many on COURSES) ----------
CREATE TABLE course_prerequisites (
    prereq_id        INT AUTO_INCREMENT PRIMARY KEY,
    course_id        INT,       -- the course that needs a prerequisite
    prereq_course_id INT,       -- the course that must be passed first
    FOREIGN KEY (course_id)        REFERENCES courses(course_id),
    FOREIGN KEY (prereq_course_id) REFERENCES courses(course_id)
);

-- ---------- Strong Entity: FACULTY ----------
CREATE TABLE faculty (
    faculty_id         INT AUTO_INCREMENT PRIMARY KEY,
    name               VARCHAR(100),
    department         VARCHAR(50),
    max_hours_per_week INT DEFAULT 12
);

-- ---------- Strong Entity: ROOMS ----------
CREATE TABLE rooms (
    room_id   INT AUTO_INCREMENT PRIMARY KEY,
    room_name VARCHAR(30),
    capacity  INT
);

-- ---------- Strong Entity: TIME_SLOTS ----------
CREATE TABLE time_slots (
    time_slot_id INT AUTO_INCREMENT PRIMARY KEY,
    day          ENUM('Mon','Tue','Wed','Thu','Fri','Sat'),
    start_time   TIME,
    end_time     TIME
);

-- ---------- SECTIONS (a course offered in a term, with faculty/room/slot) ----------
-- room_id is NULL until a room is allocated (see v_unscheduled_sections).
CREATE TABLE sections (
    section_id   INT AUTO_INCREMENT PRIMARY KEY,
    course_id    INT,
    term_id      INT,
    section_code VARCHAR(5),
    faculty_id   INT,
    room_id      INT NULL,
    time_slot_id INT,
    capacity     INT,
    seats_left   INT,
    FOREIGN KEY (course_id)    REFERENCES courses(course_id),
    FOREIGN KEY (term_id)      REFERENCES terms(term_id),
    FOREIGN KEY (faculty_id)   REFERENCES faculty(faculty_id),
    FOREIGN KEY (room_id)      REFERENCES rooms(room_id),
    FOREIGN KEY (time_slot_id) REFERENCES time_slots(time_slot_id)
);

-- ---------- REGISTRATIONS (student <-> section) ----------
CREATE TABLE registrations (
    registration_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id      INT,
    section_id      INT,
    reg_date        DATE,
    status          ENUM('REGISTERED','DROPPED') DEFAULT 'REGISTERED',
    drop_date       DATE NULL,
    FOREIGN KEY (student_id) REFERENCES students(student_id),
    FOREIGN KEY (section_id) REFERENCES sections(section_id)
);

-- ---------- WAITLIST ----------
-- WAITING   = still in the queue
-- PROMOTED  = freed seat offered to this student (set by the trigger)
-- CONFIRMED = registration row created (set by sp_drop_course)
CREATE TABLE waitlist (
    waitlist_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id  INT,
    section_id  INT,
    position    INT NULL,
    added_on    DATE,
    status      ENUM('WAITING','PROMOTED','CONFIRMED') DEFAULT 'WAITING',
    promoted_on DATE NULL,
    FOREIGN KEY (student_id) REFERENCES students(student_id),
    FOREIGN KEY (section_id) REFERENCES sections(section_id)
);

-- ---------- RESULTS (past exam results, used for the prerequisite check) ----------
-- A student can have several rows for one course (fail first, pass later).
CREATE TABLE results (
    result_id   INT AUTO_INCREMENT PRIMARY KEY,
    student_id  INT,
    course_id   INT,
    term_name   VARCHAR(30),
    grade       VARCHAR(2),
    status      ENUM('PASS','FAIL'),
    result_date DATE,
    FOREIGN KEY (student_id) REFERENCES students(student_id),
    FOREIGN KEY (course_id)  REFERENCES courses(course_id)
);

-- ---------- DEAN_APPROVALS (special permission for a late drop) ----------
CREATE TABLE dean_approvals (
    approval_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id  INT,
    section_id  INT,
    approved_by VARCHAR(100),
    reason      VARCHAR(200),
    approved_on DATE,
    FOREIGN KEY (student_id) REFERENCES students(student_id),
    FOREIGN KEY (section_id) REFERENCES sections(section_id)
);


-- =====================================================================
-- PART 2: SAMPLE DATA
-- =====================================================================

-- Terms  (add-drop window closes on 14-Aug-2026)
INSERT INTO terms (term_name, start_date, add_drop_end, end_date, is_closed) VALUES
('Fall 2026', '2026-08-03', '2026-08-14', '2026-12-05', 0);

-- Students
INSERT INTO students (name, email, department, year_of_study) VALUES
('Ravi Teja',     'ravi.teja@univ.edu',     'CSE', 3),   -- 1
('Sita Lakshmi',  'sita.lakshmi@univ.edu',  'CSE', 4),   -- 2
('Karthik Rao',   'karthik.rao@univ.edu',   'CSE', 2),   -- 3
('Ananya Iyer',   'ananya.iyer@univ.edu',   'CSE', 2),   -- 4
('Mohan Das',     'mohan.das@univ.edu',     'ECE', 2),   -- 5
('Divya Sree',    'divya.sree@univ.edu',    'CSE', 1),   -- 6
('Kiran Kumar',   'kiran.kumar@univ.edu',   'ECE', 1),   -- 7
('Pooja Nair',    'pooja.nair@univ.edu',    'ECE', 1);   -- 8

-- Courses
INSERT INTO courses (course_code, course_name, credits) VALUES
('CS101', 'Programming Fundamentals',  4),   -- 1
('MA101', 'Engineering Mathematics I', 4),   -- 2
('PH101', 'Engineering Physics',       3),   -- 3
('CS102', 'Data Structures',           4),   -- 4
('MA102', 'Engineering Mathematics II',4),   -- 5
('CS201', 'Database Systems',          4),   -- 6
('CS202', 'Operating Systems',         4),   -- 7
('CS301', 'Advanced DBMS',             3),   -- 8
('EC101', 'Basic Electronics',         3),   -- 9
('HS101', 'Communication Skills',      2),   -- 10
('CS203', 'Computer Networks',         3),   -- 11
('HS102', 'Professional Ethics',       2),   -- 12
('CS204', 'Computer Architecture',     4);   -- 13

-- Prerequisites  (course, must-pass-first)
INSERT INTO course_prerequisites (course_id, prereq_course_id) VALUES
(4, 1),    -- CS102 needs CS101
(5, 2),    -- MA102 needs MA101
(6, 4),    -- CS201 needs CS102
(7, 4),    -- CS202 needs CS102
(8, 6),    -- CS301 needs CS201   (chain: CS301 -> CS201 -> CS102 -> CS101)
(11, 4),   -- CS203 needs CS102
(13, 4);   -- CS204 needs CS102

-- Faculty (max 12 teaching hours per week)
INSERT INTO faculty (name, department, max_hours_per_week) VALUES
('Dr. Suresh Babu',     'CSE',     12),   -- 1
('Dr. Lakshmi Prasad',  'CSE',     12),   -- 2
('Prof. Raghavan',      'Maths',   12),   -- 3
('Dr. Meena Kumari',    'Physics', 12),   -- 4
('Prof. Anil Kumar',    'HSS',     12);   -- 5

-- Rooms
INSERT INTO rooms (room_name, capacity) VALUES
('R101',  60),   -- 1
('R102',  40),   -- 2
('LAB1',  30),   -- 3
('LAB2',  30),   -- 4
('SEM1',  20);   -- 5

-- Time slots (all 2 hours, none overlap)
INSERT INTO time_slots (day, start_time, end_time) VALUES
('Mon','09:00:00','11:00:00'),   -- 1
('Mon','11:00:00','13:00:00'),   -- 2
('Mon','14:00:00','16:00:00'),   -- 3
('Tue','09:00:00','11:00:00'),   -- 4
('Tue','11:00:00','13:00:00'),   -- 5
('Tue','14:00:00','16:00:00'),   -- 6
('Wed','09:00:00','11:00:00'),   -- 7
('Wed','11:00:00','13:00:00'),   -- 8
('Wed','14:00:00','16:00:00'),   -- 9
('Thu','09:00:00','11:00:00'),   -- 10
('Thu','11:00:00','13:00:00'),   -- 11
('Thu','14:00:00','16:00:00'),   -- 12
('Fri','09:00:00','11:00:00'),   -- 13
('Fri','11:00:00','13:00:00');   -- 14

-- Past results (used by the prerequisite check)
INSERT INTO results (student_id, course_id, term_name, grade, status, result_date) VALUES
(1, 1, 'Fall 2025',          'A', 'PASS', '2025-12-20'),
(1, 2, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(1, 4, 'Spring 2026',        'B', 'PASS', '2026-05-25'),
(2, 1, 'Fall 2024',          'A', 'PASS', '2024-12-20'),
(2, 2, 'Fall 2024',          'A', 'PASS', '2024-12-20'),
(2, 4, 'Spring 2025',        'B', 'PASS', '2025-05-25'),
(2, 6, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(3, 1, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(3, 2, 'Fall 2025',          'C', 'PASS', '2025-12-20'),
(3, 4, 'Spring 2026',        'F', 'FAIL', '2026-05-25'),   -- Karthik failed CS102 first ...
(3, 4, 'Supplementary 2026', 'C', 'PASS', '2026-07-18'),   -- ... and cleared it as a backlog
(4, 1, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(4, 2, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(4, 4, 'Spring 2026',        'F', 'FAIL', '2026-05-25'),   -- Ananya failed CS102 and has NOT cleared it
(5, 1, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(5, 2, 'Fall 2025',          'B', 'PASS', '2025-12-20'),
(6, 1, 'Fall 2025',          'F', 'FAIL', '2025-12-20'),
(8, 2, 'Fall 2025',          'A', 'PASS', '2025-12-20');

-- Sections (term 1).  seats_left starts equal to capacity and is synced below.
-- room_id NULL = no room allocated yet.
INSERT INTO sections (course_id, term_id, section_code, faculty_id, room_id, time_slot_id, capacity, seats_left) VALUES
( 1, 1, 'A', 1, 1,    1, 40, 40),   -- s1  CS101-A  R101  Mon 09-11
( 2, 1, 'A', 3, 1,    2, 40, 40),   -- s2  MA101-A  R101  Mon 11-13
( 3, 1, 'A', 4, 3,    3,  3,  3),   -- s3  PH101-A  LAB1  Mon 14-16  (tiny section: waitlist demo)
( 4, 1, 'A', 1, 2,    4, 35, 35),   -- s4  CS102-A  R102  Tue 09-11
( 5, 1, 'A', 3, 1,    5, 35, 35),   -- s5  MA102-A  R101  Tue 11-13
( 6, 1, 'A', 1, 1,    7, 30, 30),   -- s6  CS201-A  R101  Wed 09-11
( 7, 1, 'A', 2, 2,    8, 30, 30),   -- s7  CS202-A  R102  Wed 11-13
(13, 1, 'A', 2, 1,   10, 30, 30),   -- s8  CS204-A  R101  Thu 09-11
(11, 1, 'A', 2, 2,   11, 30, 30),   -- s9  CS203-A  R102  Thu 11-13
( 8, 1, 'A', 1, 3,    9, 25, 25),   -- s10 CS301-A  LAB1  Wed 14-16
( 9, 1, 'A', 4, 3,   12, 25, 25),   -- s11 EC101-A  LAB1  Thu 14-16
(10, 1, 'A', 5, 5,   13,  4,  4),   -- s12 HS101-A  SEM1  Fri 09-11  (tiny section: waitlist demo)
(12, 1, 'A', 5, 1,   14, 30, 30),   -- s13 HS102-A  R101  Fri 11-13
( 1, 1, 'B', 1, NULL, 6,  5,  5),   -- s14 CS101-B  (no room yet)    Tue 14-16
( 9, 1, 'B', 4, 3,    4, 25, 25);   -- s15 EC101-B  LAB1  Tue 09-11  (same slot as CS102-A: clash demo)

-- Registrations  (student_id, section_id)
INSERT INTO registrations (student_id, section_id, reg_date, status) VALUES
-- Ravi Teja (22 credits)
(1, 3,  '2026-08-05', 'REGISTERED'),   -- PH101
(1, 5,  '2026-08-05', 'REGISTERED'),   -- MA102
(1, 6,  '2026-08-05', 'REGISTERED'),   -- CS201
(1, 7,  '2026-08-05', 'REGISTERED'),   -- CS202
(1, 8,  '2026-08-05', 'REGISTERED'),   -- CS204
(1, 9,  '2026-08-05', 'REGISTERED'),   -- CS203
-- Sita Lakshmi (18 credits)
(2, 5,  '2026-08-05', 'REGISTERED'),   -- MA102
(2, 7,  '2026-08-05', 'REGISTERED'),   -- CS202
(2, 10, '2026-08-05', 'REGISTERED'),   -- CS301
(2, 11, '2026-08-05', 'REGISTERED'),   -- EC101
(2, 12, '2026-08-05', 'REGISTERED'),   -- HS101
(2, 13, '2026-08-05', 'REGISTERED'),   -- HS102
-- Karthik Rao (15 credits)
(3, 3,  '2026-08-05', 'REGISTERED'),   -- PH101
(3, 6,  '2026-08-05', 'REGISTERED'),   -- CS201 (allowed: CS102 cleared as backlog)
(3, 9,  '2026-08-05', 'REGISTERED'),   -- CS203
(3, 11, '2026-08-05', 'REGISTERED'),   -- EC101
(3, 12, '2026-08-05', 'REGISTERED'),   -- HS101
-- Ananya Iyer (14 credits)
(4, 3,  '2026-08-05', 'REGISTERED'),   -- PH101
(4, 4,  '2026-08-05', 'REGISTERED'),   -- CS102 (retaking)
(4, 5,  '2026-08-05', 'REGISTERED'),   -- MA102
(4, 11, '2026-08-05', 'REGISTERED'),   -- EC101
-- Mohan Das (10 credits)
(5, 4,  '2026-08-05', 'REGISTERED'),   -- CS102
(5, 5,  '2026-08-05', 'REGISTERED'),   -- MA102
(5, 12, '2026-08-05', 'REGISTERED'),   -- HS101
-- Divya Sree (10 credits)
(6, 1,  '2026-08-05', 'REGISTERED'),   -- CS101
(6, 2,  '2026-08-05', 'REGISTERED'),   -- MA101
(6, 12, '2026-08-05', 'REGISTERED'),   -- HS101
-- Kiran Kumar (8 credits)
(7, 1,  '2026-08-05', 'REGISTERED'),   -- CS101
(7, 2,  '2026-08-05', 'REGISTERED'),   -- MA101
-- Pooja Nair (4 credits)
(8, 5,  '2026-08-05', 'REGISTERED');   -- MA102

-- Make seats_left match the registrations just loaded
UPDATE sections s
SET s.seats_left = s.capacity - (SELECT COUNT(*) FROM registrations r
                                 WHERE r.section_id = s.section_id
                                   AND r.status = 'REGISTERED');

-- Waitlist: PH101-A (full, 3 waiting) and HS101-A (full, 1 waiting)
INSERT INTO waitlist (student_id, section_id, position, added_on, status) VALUES
(6, 3,  1, '2026-08-01', 'WAITING'),   -- Divya  waits for PH101
(7, 3,  2, '2026-08-02', 'WAITING'),   -- Kiran  waits for PH101
(8, 3,  3, '2026-08-03', 'WAITING'),   -- Pooja  waits for PH101
(7, 12, 1, '2026-08-04', 'WAITING');   -- Kiran  waits for HS101


-- =====================================================================
-- PART 3: INDEXES
-- =====================================================================
-- Chosen for the JOINs / clash checks / waitlist lookups used throughout.

CREATE INDEX idx_reg_student_section   ON registrations(student_id, section_id);
CREATE INDEX idx_sections_course_term  ON sections(course_id, term_id);
CREATE INDEX idx_slots_day_start       ON time_slots(day, start_time);
CREATE INDEX idx_sections_faculty_slot ON sections(faculty_id, time_slot_id);
CREATE INDEX idx_sections_room_slot    ON sections(room_id, time_slot_id);
CREATE INDEX idx_waitlist_sec_pos      ON waitlist(section_id, position);
CREATE INDEX idx_prereq_course         ON course_prerequisites(course_id);

-- Verify indexes:
-- SHOW INDEX FROM registrations;
-- SHOW INDEX FROM sections;
-- SHOW INDEX FROM waitlist;


-- =====================================================================
-- PART 4: VIEWS
-- =====================================================================

-- 4.1 Weekly timetable of every student (print one student with a WHERE)
CREATE OR REPLACE VIEW v_student_timetable AS
SELECT
    st.student_id,
    st.name                          AS student_name,
    t.term_name,
    ts.day,
    ts.start_time,
    ts.end_time,
    c.course_code,
    c.course_name,
    sec.section_id,
    sec.section_code,
    COALESCE(rm.room_name, 'TBA')    AS room_name,
    f.name                           AS faculty_name
FROM registrations r
JOIN students   st  ON r.student_id    = st.student_id
JOIN sections   sec ON r.section_id    = sec.section_id
JOIN terms      t   ON sec.term_id     = t.term_id
JOIN courses    c   ON sec.course_id   = c.course_id
JOIN time_slots ts  ON sec.time_slot_id = ts.time_slot_id
JOIN faculty    f   ON sec.faculty_id  = f.faculty_id
LEFT JOIN rooms rm  ON sec.room_id     = rm.room_id
WHERE r.status = 'REGISTERED';

-- 4.2 Seats filled and left in every section
CREATE OR REPLACE VIEW v_section_seats AS
SELECT
    sec.section_id,
    c.course_code,
    sec.section_code,
    t.term_name,
    sec.capacity,
    sec.capacity - sec.seats_left AS seats_filled,
    sec.seats_left
FROM sections sec
JOIN courses c ON sec.course_id = c.course_id
JOIN terms   t ON sec.term_id   = t.term_id;

-- 4.3 Weekly teaching hours of each faculty member and % of the limit
CREATE OR REPLACE VIEW v_faculty_load AS
SELECT
    f.faculty_id,
    f.name,
    t.term_name,
    SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600) AS weekly_hours,
    f.max_hours_per_week,
    ROUND(SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600)
          / f.max_hours_per_week * 100, 1)                        AS pct_of_limit
FROM faculty f
JOIN sections   sec ON f.faculty_id      = sec.faculty_id
JOIN terms      t   ON sec.term_id       = t.term_id
JOIN time_slots ts  ON sec.time_slot_id  = ts.time_slot_id
GROUP BY f.faculty_id, f.name, t.term_name, f.max_hours_per_week;

-- 4.4 Registered vs dropped count per course per term
CREATE OR REPLACE VIEW v_registration_summary AS
SELECT
    c.course_code,
    c.course_name,
    t.term_name,
    SUM(CASE WHEN r.status = 'REGISTERED' THEN 1 ELSE 0 END) AS registered,
    SUM(CASE WHEN r.status = 'DROPPED'    THEN 1 ELSE 0 END) AS dropped
FROM sections sec
JOIN courses c ON sec.course_id = c.course_id
JOIN terms   t ON sec.term_id   = t.term_id
LEFT JOIN registrations r ON r.section_id = sec.section_id
GROUP BY c.course_code, c.course_name, t.term_name;

-- 4.5 Hours used per room out of the total weekly hours available
CREATE OR REPLACE VIEW v_room_utilisation AS
SELECT
    rm.room_id,
    rm.room_name,
    rm.capacity,
    COALESCE(SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600), 0) AS hours_used,
    (SELECT SUM(TIME_TO_SEC(TIMEDIFF(end_time, start_time)) / 3600) FROM time_slots) AS hours_available,
    ROUND(COALESCE(SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600), 0)
          / (SELECT SUM(TIME_TO_SEC(TIMEDIFF(end_time, start_time)) / 3600) FROM time_slots)
          * 100, 1) AS util_pct
FROM rooms rm
LEFT JOIN sections   sec ON rm.room_id = sec.room_id
LEFT JOIN time_slots ts  ON sec.time_slot_id = ts.time_slot_id
GROUP BY rm.room_id, rm.room_name, rm.capacity;

-- 4.6 Credits registered per student per term, with a min/max status
CREATE OR REPLACE VIEW v_credit_summary AS
SELECT
    st.student_id,
    st.name,
    t.term_name,
    SUM(c.credits) AS total_credits,
    CASE
        WHEN SUM(c.credits) < 18 THEN 'BELOW MINIMUM'
        WHEN SUM(c.credits) > 24 THEN 'ABOVE MAXIMUM'
        ELSE 'OK'
    END AS credit_status
FROM registrations r
JOIN students st  ON r.student_id  = st.student_id
JOIN sections sec ON r.section_id  = sec.section_id
JOIN terms    t   ON sec.term_id   = t.term_id
JOIN courses  c   ON sec.course_id = c.course_id
WHERE r.status = 'REGISTERED'
GROUP BY st.student_id, st.name, t.term_name;

-- 4.7 Sections that still have no room
CREATE OR REPLACE VIEW v_unscheduled_sections AS
SELECT
    sec.section_id,
    c.course_code,
    sec.section_code,
    t.term_name,
    f.name      AS faculty_name,
    ts.day,
    ts.start_time,
    sec.capacity
FROM sections sec
JOIN courses    c  ON sec.course_id    = c.course_id
JOIN terms      t  ON sec.term_id      = t.term_id
JOIN faculty    f  ON sec.faculty_id   = f.faculty_id
JOIN time_slots ts ON sec.time_slot_id = ts.time_slot_id
WHERE sec.room_id IS NULL;

-- 4.8 Students currently waiting, in queue order
CREATE OR REPLACE VIEW v_waitlist_status AS
SELECT
    w.waitlist_id,
    st.name AS student_name,
    c.course_code,
    sec.section_id,
    w.position,
    w.added_on
FROM waitlist w
JOIN students st  ON w.student_id = st.student_id
JOIN sections sec ON w.section_id = sec.section_id
JOIN courses  c   ON sec.course_id = c.course_id
WHERE w.status = 'WAITING';


-- =====================================================================
-- PART 5: FUNCTIONS & STORED PROCEDURES
-- =====================================================================

-- ---------------------------- FUNCTIONS -------------------------------

-- 5.1 Credits a student currently holds in a term
DROP FUNCTION IF EXISTS fn_credits_registered;
DELIMITER $$
CREATE FUNCTION fn_credits_registered(p_student_id INT, p_term_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_credits INT;

    SELECT COALESCE(SUM(c.credits), 0) INTO v_credits
    FROM registrations r
    JOIN sections sec ON r.section_id  = sec.section_id
    JOIN courses  c   ON sec.course_id = c.course_id
    WHERE r.student_id = p_student_id
      AND sec.term_id  = p_term_id
      AND r.status     = 'REGISTERED';

    RETURN v_credits;
END $$
DELIMITER ;

-- 5.2 Seats still free in a section
DROP FUNCTION IF EXISTS fn_seats_left;
DELIMITER $$
CREATE FUNCTION fn_seats_left(p_section_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_seats INT;

    SELECT seats_left INTO v_seats
    FROM sections
    WHERE section_id = p_section_id;

    RETURN v_seats;
END $$
DELIMITER ;

-- --------------------------- PROCEDURES -------------------------------

-- 5.3 Register a student for a section (goes to the waitlist if full).
--     The prerequisite / clash / credit rules are enforced by triggers.
DROP PROCEDURE IF EXISTS sp_register_course;
DELIMITER $$
CREATE PROCEDURE sp_register_course(
    IN p_student_id INT,
    IN p_section_id INT,
    IN p_date       DATE
)
BEGIN
    DECLARE v_seats  INT;
    DECLARE v_term   INT;
    DECLARE v_closed TINYINT;
    DECLARE v_pos    INT;

    SELECT sec.seats_left, sec.term_id, t.is_closed
    INTO   v_seats, v_term, v_closed
    FROM sections sec
    JOIN terms t ON sec.term_id = t.term_id
    WHERE sec.section_id = p_section_id;

    IF v_term IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Section not found';
    END IF;

    IF v_closed = 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Registration is closed for this term';
    END IF;

    IF v_seats > 0 THEN
        INSERT INTO registrations (student_id, section_id, reg_date, status)
        VALUES (p_student_id, p_section_id, p_date, 'REGISTERED');
        SELECT 'Registered successfully' AS result;
    ELSE
        SELECT COALESCE(MAX(position), 0) + 1 INTO v_pos
        FROM waitlist
        WHERE section_id = p_section_id AND status = 'WAITING';

        INSERT INTO waitlist (student_id, section_id, position, added_on, status)
        VALUES (p_student_id, p_section_id, v_pos, p_date, 'WAITING');
        SELECT CONCAT('Section full - added to waitlist at position ', v_pos) AS result;
    END IF;
END $$
DELIMITER ;

-- 5.4 Drop a student from a section, in ONE transaction.
--     trg_block_late_drop checks the add-drop window,
--     trg_promote_waitlist frees the seat and picks the first waiting
--     student, then this procedure registers that student.
DROP PROCEDURE IF EXISTS sp_drop_course;
DELIMITER $$
CREATE PROCEDURE sp_drop_course(
    IN p_student_id INT,
    IN p_section_id INT,
    IN p_date       DATE
)
BEGIN
    DECLARE v_updated INT;
    DECLARE v_promoted INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    UPDATE registrations
    SET status = 'DROPPED', drop_date = p_date
    WHERE student_id = p_student_id
      AND section_id = p_section_id
      AND status     = 'REGISTERED';
    SET v_updated = ROW_COUNT();

    IF v_updated = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No active registration found to drop';
    END IF;

    -- Student marked PROMOTED by the trigger (if anyone was waiting)
    SELECT student_id INTO v_promoted
    FROM waitlist
    WHERE section_id = p_section_id AND status = 'PROMOTED'
    LIMIT 1;

    IF v_promoted IS NOT NULL THEN
        INSERT INTO registrations (student_id, section_id, reg_date, status)
        VALUES (v_promoted, p_section_id, p_date, 'REGISTERED');

        UPDATE waitlist
        SET status = 'CONFIRMED'
        WHERE section_id = p_section_id
          AND student_id = v_promoted
          AND status     = 'PROMOTED';
    END IF;

    COMMIT;

    SELECT 'Dropped successfully' AS result,
           v_promoted             AS promoted_student_id;
END $$
DELIMITER ;

-- 5.5 Print a student's weekly timetable (Mon..Sat, by start time)
DROP PROCEDURE IF EXISTS sp_generate_timetable;
DELIMITER $$
CREATE PROCEDURE sp_generate_timetable(IN p_student_id INT)
BEGIN
    SELECT day, start_time, end_time, course_code, course_name,
           section_code, room_name, faculty_name
    FROM v_student_timetable
    WHERE student_id = p_student_id
    ORDER BY day, start_time;
END $$
DELIMITER ;

-- 5.6 Report for one section: summary + list of enrolled students
DROP PROCEDURE IF EXISTS sp_section_report;
DELIMITER $$
CREATE PROCEDURE sp_section_report(IN p_section_id INT)
BEGIN
    SELECT * FROM v_section_seats WHERE section_id = p_section_id;

    SELECT st.student_id, st.name, r.reg_date
    FROM registrations r
    JOIN students st ON r.student_id = st.student_id
    WHERE r.section_id = p_section_id
      AND r.status = 'REGISTERED'
    ORDER BY st.name;
END $$
DELIMITER ;

-- 5.7 Add or drop a course with all checks (action = 'ADD' or 'DROP')
DROP PROCEDURE IF EXISTS sp_add_drop_course;
DELIMITER $$
CREATE PROCEDURE sp_add_drop_course(
    IN p_student_id INT,
    IN p_section_id INT,
    IN p_action     VARCHAR(10),
    IN p_date       DATE
)
BEGIN
    IF p_action = 'ADD' THEN
        CALL sp_register_course(p_student_id, p_section_id, p_date);
    ELSEIF p_action = 'DROP' THEN
        CALL sp_drop_course(p_student_id, p_section_id, p_date);
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Action must be ADD or DROP';
    END IF;
END $$
DELIMITER ;

-- 5.8 Allocate a room to a section (capacity + clash checks)
DROP PROCEDURE IF EXISTS sp_assign_room;
DELIMITER $$
CREATE PROCEDURE sp_assign_room(IN p_section_id INT, IN p_room_id INT)
BEGIN
    DECLARE v_sec_cap  INT;
    DECLARE v_room_cap INT;
    DECLARE v_slot     INT;
    DECLARE v_term     INT;
    DECLARE v_clash    INT;

    SELECT capacity, time_slot_id, term_id INTO v_sec_cap, v_slot, v_term
    FROM sections WHERE section_id = p_section_id;

    IF v_slot IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Section not found';
    END IF;

    SELECT capacity INTO v_room_cap FROM rooms WHERE room_id = p_room_id;

    IF v_room_cap IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room not found';
    END IF;

    IF v_sec_cap > v_room_cap THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room capacity is smaller than section capacity';
    END IF;

    SELECT COUNT(*) INTO v_clash
    FROM sections
    WHERE room_id      = p_room_id
      AND time_slot_id = v_slot
      AND term_id      = v_term
      AND section_id  <> p_section_id;

    IF v_clash > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is already booked in that time slot';
    END IF;

    UPDATE sections SET room_id = p_room_id WHERE section_id = p_section_id;
    SELECT 'Room assigned successfully' AS result;
END $$
DELIMITER ;

-- 5.9 Lock registration for a term and list students below 18 credits
DROP PROCEDURE IF EXISTS sp_close_registration;
DELIMITER $$
CREATE PROCEDURE sp_close_registration(IN p_term_id INT)
BEGIN
    UPDATE terms SET is_closed = 1 WHERE term_id = p_term_id;

    SELECT student_id, name, total_credits, 18 - total_credits AS credits_short
    FROM v_credit_summary
    WHERE term_name = (SELECT term_name FROM terms WHERE term_id = p_term_id)
      AND total_credits < 18
    ORDER BY credits_short DESC;
END $$
DELIMITER ;

-- 5.10 Weekly teaching hours of one faculty member in one term
DROP PROCEDURE IF EXISTS sp_faculty_workload;
DELIMITER $$
CREATE PROCEDURE sp_faculty_workload(IN p_faculty_id INT, IN p_term_id INT)
BEGIN
    SELECT f.name,
           SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600) AS weekly_hours,
           f.max_hours_per_week,
           f.max_hours_per_week
             - SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600) AS hours_left
    FROM faculty f
    JOIN sections   sec ON f.faculty_id     = sec.faculty_id
    JOIN time_slots ts  ON sec.time_slot_id = ts.time_slot_id
    WHERE f.faculty_id = p_faculty_id
      AND sec.term_id  = p_term_id
    GROUP BY f.name, f.max_hours_per_week;
END $$
DELIMITER ;

-- 5.11 (extra, needed for Q12) Record dean approval for a late drop
DROP PROCEDURE IF EXISTS sp_dean_approve_drop;
DELIMITER $$
CREATE PROCEDURE sp_dean_approve_drop(
    IN p_student_id  INT,
    IN p_section_id  INT,
    IN p_approved_by VARCHAR(100),
    IN p_reason      VARCHAR(200),
    IN p_date        DATE
)
BEGIN
    INSERT INTO dean_approvals (student_id, section_id, approved_by, reason, approved_on)
    VALUES (p_student_id, p_section_id, p_approved_by, p_reason, p_date);

    SELECT 'Dean approval recorded - the late drop is now allowed' AS result;
END $$
DELIMITER ;


-- =====================================================================
-- PART 6: TRIGGERS
-- =====================================================================
-- Triggers on the same table/event run in the order they are created
-- below: clash -> prerequisite -> credit limit.

-- 6.1 Reject a registration whose time slot clashes with the student's
--     existing registrations (message names the clashing course)
DROP TRIGGER IF EXISTS trg_check_time_clash;
DELIMITER $$
CREATE TRIGGER trg_check_time_clash
BEFORE INSERT ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_slot INT;
    DECLARE v_term INT;
    DECLARE v_code VARCHAR(10) DEFAULT NULL;
    DECLARE v_name VARCHAR(100);
    DECLARE v_msg  VARCHAR(128);

    SELECT time_slot_id, term_id INTO v_slot, v_term
    FROM sections WHERE section_id = NEW.section_id;

    SELECT c.course_code, c.course_name INTO v_code, v_name
    FROM registrations r
    JOIN sections sec ON r.section_id  = sec.section_id
    JOIN courses  c   ON sec.course_id = c.course_id
    WHERE r.student_id       = NEW.student_id
      AND r.status           = 'REGISTERED'
      AND sec.time_slot_id   = v_slot
      AND sec.term_id        = v_term
    LIMIT 1;

    IF v_code IS NOT NULL THEN
        SET v_msg = CONCAT('Timetable clash with ', v_code, ' - ', v_name);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END $$
DELIMITER ;

-- 6.2 Reject a registration when a prerequisite is not passed.
--     Only the student's LATEST result for each prerequisite counts
--     (fail first, pass later as a backlog = cleared).
DROP TRIGGER IF EXISTS trg_check_prereq;
DELIMITER $$
CREATE TRIGGER trg_check_prereq
BEFORE INSERT ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_course  INT;
    DECLARE v_missing VARCHAR(10) DEFAULT NULL;
    DECLARE v_msg     VARCHAR(128);

    SELECT course_id INTO v_course
    FROM sections WHERE section_id = NEW.section_id;

    SELECT c.course_code INTO v_missing
    FROM course_prerequisites cp
    JOIN courses c ON cp.prereq_course_id = c.course_id
    WHERE cp.course_id = v_course
      AND NOT EXISTS (
            SELECT 1
            FROM results r
            WHERE r.student_id = NEW.student_id
              AND r.course_id  = cp.prereq_course_id
              AND r.status     = 'PASS'
              AND r.result_date = (SELECT MAX(r2.result_date)
                                   FROM results r2
                                   WHERE r2.student_id = r.student_id
                                     AND r2.course_id  = r.course_id)
          )
    LIMIT 1;

    IF v_missing IS NOT NULL THEN
        SET v_msg = CONCAT('Prerequisite not cleared: ', v_missing);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END $$
DELIMITER ;

-- 6.3 Reject a registration that takes the student above 24 credits
DROP TRIGGER IF EXISTS trg_check_credit_limit;
DELIMITER $$
CREATE TRIGGER trg_check_credit_limit
BEFORE INSERT ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_term        INT;
    DECLARE v_new_credits INT;
    DECLARE v_current     INT;
    DECLARE v_msg         VARCHAR(128);

    SELECT sec.term_id, c.credits INTO v_term, v_new_credits
    FROM sections sec
    JOIN courses c ON sec.course_id = c.course_id
    WHERE sec.section_id = NEW.section_id;

    SET v_current = fn_credits_registered(NEW.student_id, v_term);

    IF v_current + v_new_credits > 24 THEN
        SET v_msg = CONCAT('Credit limit exceeded: ', v_current, ' held + ',
                           v_new_credits, ' new > 24');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END $$
DELIMITER ;

-- 6.4 Reduce the seat count after a registration (and block if full)
DROP TRIGGER IF EXISTS trg_reduce_seats;
DELIMITER $$
CREATE TRIGGER trg_reduce_seats
AFTER INSERT ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_seats INT;

    UPDATE sections
    SET seats_left = seats_left - 1
    WHERE section_id = NEW.section_id;

    SELECT seats_left INTO v_seats
    FROM sections WHERE section_id = NEW.section_id;

    IF v_seats < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Section is full - no seats left';
    END IF;
END $$
DELIMITER ;

-- 6.5 Block a drop after the add-drop window (unless the dean approved it)
DROP TRIGGER IF EXISTS trg_block_late_drop;
DELIMITER $$
CREATE TRIGGER trg_block_late_drop
BEFORE UPDATE ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_window_end DATE;
    DECLARE v_approved   INT;

    IF OLD.status = 'REGISTERED' AND NEW.status = 'DROPPED' THEN

        IF NEW.drop_date IS NULL THEN
            SET NEW.drop_date = CURDATE();
        END IF;

        SELECT t.add_drop_end INTO v_window_end
        FROM sections sec
        JOIN terms t ON sec.term_id = t.term_id
        WHERE sec.section_id = NEW.section_id;

        SELECT COUNT(*) INTO v_approved
        FROM dean_approvals
        WHERE student_id = NEW.student_id
          AND section_id = NEW.section_id;

        IF NEW.drop_date > v_window_end AND v_approved = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Drop not allowed: add-drop window is closed';
        END IF;
    END IF;
END $$
DELIMITER ;

-- 6.6 After a drop: free the seat, promote the first waiting student and
--     renumber the rest of the waitlist.
--     (The new registration row is inserted by sp_drop_course - MySQL
--      does not let a trigger insert into its own table.)
DROP TRIGGER IF EXISTS trg_promote_waitlist;
DELIMITER $$
CREATE TRIGGER trg_promote_waitlist
AFTER UPDATE ON registrations
FOR EACH ROW
BEGIN
    DECLARE v_first INT DEFAULT NULL;

    IF OLD.status = 'REGISTERED' AND NEW.status = 'DROPPED' THEN

        UPDATE sections
        SET seats_left = seats_left + 1
        WHERE section_id = NEW.section_id;

        SELECT waitlist_id INTO v_first
        FROM waitlist
        WHERE section_id = NEW.section_id AND status = 'WAITING'
        ORDER BY position
        LIMIT 1;

        IF v_first IS NOT NULL THEN
            UPDATE waitlist
            SET status = 'PROMOTED', position = NULL, promoted_on = NEW.drop_date
            WHERE waitlist_id = v_first;

            -- renumber the remaining waiting students 1, 2, 3 ...
            UPDATE waitlist w
            JOIN (SELECT waitlist_id,
                         ROW_NUMBER() OVER (ORDER BY position) AS new_pos
                  FROM waitlist
                  WHERE section_id = NEW.section_id AND status = 'WAITING') x
              ON w.waitlist_id = x.waitlist_id
            SET w.position = x.new_pos;
        END IF;
    END IF;
END $$
DELIMITER ;

-- 6.7 Reject a new section with a room clash, faculty clash, room too
--     small, or faculty over 12 hours a week
DROP TRIGGER IF EXISTS trg_check_section;
DELIMITER $$
CREATE TRIGGER trg_check_section
BEFORE INSERT ON sections
FOR EACH ROW
BEGIN
    DECLARE v_room_cap  INT;
    DECLARE v_clash     INT;
    DECLARE v_hours     DECIMAL(5,2);
    DECLARE v_new_hours DECIMAL(5,2);
    DECLARE v_max_hours INT;

    -- room checks (only when a room is given)
    IF NEW.room_id IS NOT NULL THEN
        SELECT capacity INTO v_room_cap FROM rooms WHERE room_id = NEW.room_id;
        IF NEW.capacity > v_room_cap THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Section capacity exceeds room capacity';
        END IF;

        SELECT COUNT(*) INTO v_clash
        FROM sections
        WHERE room_id = NEW.room_id
          AND time_slot_id = NEW.time_slot_id
          AND term_id = NEW.term_id;
        IF v_clash > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Room clash: room already booked in this time slot';
        END IF;
    END IF;

    -- faculty clash
    SELECT COUNT(*) INTO v_clash
    FROM sections
    WHERE faculty_id = NEW.faculty_id
      AND time_slot_id = NEW.time_slot_id
      AND term_id = NEW.term_id;
    IF v_clash > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Faculty clash: faculty already teaching in this time slot';
    END IF;

    -- faculty weekly hours
    SELECT COALESCE(SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600), 0)
    INTO v_hours
    FROM sections sec
    JOIN time_slots ts ON sec.time_slot_id = ts.time_slot_id
    WHERE sec.faculty_id = NEW.faculty_id
      AND sec.term_id    = NEW.term_id;

    SELECT TIME_TO_SEC(TIMEDIFF(end_time, start_time)) / 3600 INTO v_new_hours
    FROM time_slots WHERE time_slot_id = NEW.time_slot_id;

    SELECT max_hours_per_week INTO v_max_hours
    FROM faculty WHERE faculty_id = NEW.faculty_id;

    IF v_hours + v_new_hours > v_max_hours THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Faculty workload would exceed 12 hours per week';
    END IF;

    IF NEW.seats_left IS NULL THEN
        SET NEW.seats_left = NEW.capacity;
    END IF;
END $$
DELIMITER ;


-- =====================================================================
-- PART 7: REPORTING QUERIES  Q1 - Q4
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. List courses whose waitlist is longer than 20 percent of the
--     section capacity, with the average waiting time of the students.
--     (joins, ratio, DATEDIFF)   -- waiting time measured to 10-Aug-2026
-- ---------------------------------------------------------------------
SELECT c.course_code,
       c.course_name,
       sec.section_id,
       sec.capacity,
       COUNT(w.waitlist_id)                                    AS students_waiting,
       ROUND(COUNT(w.waitlist_id) / sec.capacity * 100, 1)     AS waitlist_pct,
       ROUND(AVG(DATEDIFF('2026-08-10', w.added_on)), 1)       AS avg_wait_days
FROM waitlist w
JOIN sections sec ON w.section_id = sec.section_id
JOIN courses  c   ON sec.course_id = c.course_id
WHERE w.status = 'WAITING'
GROUP BY c.course_code, c.course_name, sec.section_id, sec.capacity
HAVING COUNT(w.waitlist_id) > 0.20 * sec.capacity;
-- ANSWER:
--   course_code | course_name          | section_id | capacity | students_waiting | waitlist_pct | avg_wait_days
--   HS101       | Communication Skills |         12 |        4 |                1 |         25.0 |           6.0
--   PH101       | Engineering Physics  |          3 |        3 |                3 |        100.0 |           8.0

-- ---------------------------------------------------------------------
-- Q2. Find rooms used for less than 40 percent of available weekly
--     hours and suggest sections that could be moved into them.
--     (aggregation, NOT EXISTS)
-- ---------------------------------------------------------------------
-- Q2a: under-used rooms
SELECT room_name, capacity, hours_used, hours_available, util_pct
FROM v_room_utilisation
WHERE util_pct < 40
ORDER BY util_pct;
-- ANSWER (R101 is at 42.9%, so it is NOT listed):
--   room_name | capacity | hours_used | hours_available | util_pct
--   LAB2      |       30 |        0.0 |            28.0 |      0.0
--   SEM1      |       20 |        2.0 |            28.0 |      7.1
--   R102      |       40 |        6.0 |            28.0 |     21.4
--   LAB1      |       30 |        8.0 |            28.0 |     28.6

-- Q2b: sections sitting in well-used rooms (40% or more) that fit an
--      under-used room and whose time slot is free in that room
SELECT low.room_name  AS move_into_room,
       low.util_pct   AS room_util_pct,
       sec.section_id,
       c.course_code,
       sec.capacity,
       ts.day,
       ts.start_time,
       busy.room_name AS currently_in
FROM v_room_utilisation low
JOIN v_room_utilisation busy ON busy.util_pct >= 40
JOIN sections   sec ON sec.room_id      = busy.room_id
JOIN courses    c   ON sec.course_id    = c.course_id
JOIN time_slots ts  ON sec.time_slot_id = ts.time_slot_id
WHERE low.util_pct < 40
  AND sec.capacity <= low.capacity
  AND NOT EXISTS (SELECT 1
                  FROM sections s2
                  WHERE s2.room_id      = low.room_id
                    AND s2.time_slot_id = sec.time_slot_id
                    AND s2.term_id      = sec.term_id)
ORDER BY low.room_name, ts.day, ts.start_time;
-- ANSWER (12 suggestions; every one moves a section out of the busy room R101):
--   move_into_room | room_util_pct | section_id | course_code | capacity | day | start_time | currently_in
--   LAB1           |          28.6 |          6 | CS201       |       30 | Wed | 09:00:00   | R101
--   LAB1           |          28.6 |          8 | CS204       |       30 | Thu | 09:00:00   | R101
--   LAB1           |          28.6 |         13 | HS102       |       30 | Fri | 11:00:00   | R101
--   LAB2           |           0.0 |          6 | CS201       |       30 | Wed | 09:00:00   | R101
--   LAB2           |           0.0 |          8 | CS204       |       30 | Thu | 09:00:00   | R101
--   LAB2           |           0.0 |         13 | HS102       |       30 | Fri | 11:00:00   | R101
--   R102           |          21.4 |          1 | CS101       |       40 | Mon | 09:00:00   | R101
--   R102           |          21.4 |          2 | MA101       |       40 | Mon | 11:00:00   | R101
--   R102           |          21.4 |          5 | MA102       |       35 | Tue | 11:00:00   | R101
--   R102           |          21.4 |          6 | CS201       |       30 | Wed | 09:00:00   | R101
--   R102           |          21.4 |          8 | CS204       |       30 | Thu | 09:00:00   | R101
--   R102           |          21.4 |         13 | HS102       |       30 | Fri | 11:00:00   | R101
--   (SEM1 gets none: it seats only 20.  LAB rooms get only the sections of 30 or fewer seats.)

-- ---------------------------------------------------------------------
-- Q3. Show the complete prerequisite chain with depth for a given course
--     (CS301, course_id 8) and list all students who already satisfy
--     every course in the chain.   (recursive CTE, NOT EXISTS)
-- ---------------------------------------------------------------------
-- Q3a: the chain with depth
WITH RECURSIVE chain AS (
    SELECT cp.prereq_course_id AS course_id, 1 AS depth
    FROM course_prerequisites cp
    WHERE cp.course_id = 8
    UNION ALL
    SELECT cp.prereq_course_id, ch.depth + 1
    FROM course_prerequisites cp
    JOIN chain ch ON cp.course_id = ch.course_id
)
SELECT ch.depth, c.course_code, c.course_name
FROM chain ch
JOIN courses c ON ch.course_id = c.course_id
ORDER BY ch.depth;
-- ANSWER:
--   depth | course_code | course_name
--       1 | CS201       | Database Systems
--       2 | CS102       | Data Structures
--       3 | CS101       | Programming Fundamentals

-- Q3b: students who have passed EVERY course in that chain
WITH RECURSIVE chain AS (
    SELECT cp.prereq_course_id AS course_id, 1 AS depth
    FROM course_prerequisites cp
    WHERE cp.course_id = 8
    UNION ALL
    SELECT cp.prereq_course_id, ch.depth + 1
    FROM course_prerequisites cp
    JOIN chain ch ON cp.course_id = ch.course_id
)
SELECT st.student_id, st.name
FROM students st
WHERE NOT EXISTS (
        SELECT 1
        FROM chain ch
        WHERE NOT EXISTS (SELECT 1
                          FROM results r
                          WHERE r.student_id = st.student_id
                            AND r.course_id  = ch.course_id
                            AND r.status     = 'PASS')
      );
-- ANSWER (only Sita has passed CS201, CS102 and CS101):
--   student_id | name
--            2 | Sita Lakshmi

-- ---------------------------------------------------------------------
-- Q4. List students registered below the minimum (18) or above the
--     maximum (24) credits for the term, with the difference.
--     (CASE, SUM, HAVING)
-- ---------------------------------------------------------------------
SELECT st.student_id,
       st.name,
       SUM(c.credits) AS total_credits,
       CASE
           WHEN SUM(c.credits) < 18 THEN 'BELOW MINIMUM'
           ELSE 'ABOVE MAXIMUM'
       END AS problem,
       CASE
           WHEN SUM(c.credits) < 18 THEN 18 - SUM(c.credits)
           ELSE SUM(c.credits) - 24
       END AS difference
FROM registrations r
JOIN students st  ON r.student_id  = st.student_id
JOIN sections sec ON r.section_id  = sec.section_id
JOIN courses  c   ON sec.course_id = c.course_id
WHERE r.status = 'REGISTERED'
  AND sec.term_id = 1
GROUP BY st.student_id, st.name
HAVING SUM(c.credits) < 18 OR SUM(c.credits) > 24
ORDER BY difference DESC;
-- ANSWER (nobody is above 24 because the credit trigger stops it):
--   student_id | name        | total_credits | problem       | difference
--            8 | Pooja Nair  |             4 | BELOW MINIMUM |         14
--            7 | Kiran Kumar |             8 | BELOW MINIMUM |         10
--            5 | Mohan Das   |            10 | BELOW MINIMUM |          8
--            6 | Divya Sree  |            10 | BELOW MINIMUM |          8
--            4 | Ananya Iyer |            14 | BELOW MINIMUM |          4
--            3 | Karthik Rao |            15 | BELOW MINIMUM |          3


-- =====================================================================
-- PART 8: REPORTING QUERIES  Q5 - Q7
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q5. Show each faculty member's weekly teaching hours and the
--     percentage of the limit, ranking the most loaded. (SUM, RANK)
-- ---------------------------------------------------------------------
SELECT f.faculty_id,
       f.name,
       SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600)  AS weekly_hours,
       f.max_hours_per_week,
       ROUND(SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time)) / 3600)
             / f.max_hours_per_week * 100, 1)                         AS pct_of_limit,
       RANK() OVER (ORDER BY SUM(TIME_TO_SEC(TIMEDIFF(ts.end_time, ts.start_time))) DESC) AS load_rank
FROM faculty f
JOIN sections   sec ON f.faculty_id     = sec.faculty_id
JOIN time_slots ts  ON sec.time_slot_id = ts.time_slot_id
WHERE sec.term_id = 1
GROUP BY f.faculty_id, f.name, f.max_hours_per_week
ORDER BY load_rank;
-- ANSWER:
--   faculty_id | name               | weekly_hours | max_hours_per_week | pct_of_limit | load_rank
--            1 | Dr. Suresh Babu    |         10.0 |                 12 |         83.3 |         1
--            4 | Dr. Meena Kumari   |          6.0 |                 12 |         50.0 |         2
--            2 | Dr. Lakshmi Prasad |          6.0 |                 12 |         50.0 |         2
--            5 | Prof. Anil Kumar   |          4.0 |                 12 |         33.3 |         4
--            3 | Prof. Raghavan     |          4.0 |                 12 |         33.3 |         4

-- ---------------------------------------------------------------------
-- Q6. Detect timetable clashes between any two sections registered by
--     the same student, showing both course names and the time slot.
--     (self join on registrations and time_slots)
-- ---------------------------------------------------------------------
SELECT st.name  AS student,
       c1.course_name AS course_1,
       c2.course_name AS course_2,
       ts1.day, ts1.start_time, ts1.end_time
FROM registrations r1
JOIN registrations r2  ON r1.student_id = r2.student_id
                      AND r1.registration_id < r2.registration_id
JOIN students   st  ON r1.student_id = st.student_id
JOIN sections   s1  ON r1.section_id = s1.section_id
JOIN sections   s2  ON r2.section_id = s2.section_id
JOIN courses    c1  ON s1.course_id  = c1.course_id
JOIN courses    c2  ON s2.course_id  = c2.course_id
JOIN time_slots ts1 ON s1.time_slot_id = ts1.time_slot_id
JOIN time_slots ts2 ON s2.time_slot_id = ts2.time_slot_id
WHERE r1.status = 'REGISTERED'
  AND r2.status = 'REGISTERED'
  AND ts1.day = ts2.day
  AND ts1.start_time < ts2.end_time
  AND ts2.start_time < ts1.end_time;
-- ANSWER: Empty set (0 rows).
--   The clash trigger (trg_check_time_clash) never lets a clashing pair into
--   registrations, so this audit query finds nothing - which is the proof
--   the rule works.  (Q8 shows the trigger blocking one.)

-- ---------------------------------------------------------------------
-- Q7. Show fill rate for each section and the rank of the section within
--     its course, listing sections below 50 percent.
--     (ratio, RANK PARTITION BY)
-- ---------------------------------------------------------------------
SELECT *
FROM (
    SELECT c.course_code,
           sec.section_id,
           sec.section_code,
           sec.capacity,
           sec.capacity - sec.seats_left                                AS seats_filled,
           ROUND((sec.capacity - sec.seats_left) / sec.capacity * 100, 1) AS fill_pct,
           RANK() OVER (PARTITION BY sec.course_id
                        ORDER BY (sec.capacity - sec.seats_left) / sec.capacity DESC) AS rank_in_course
    FROM sections sec
    JOIN courses c ON sec.course_id = c.course_id
) t
WHERE fill_pct < 50
ORDER BY fill_pct, course_code;
-- ANSWER (13 sections are below 50%; only PH101-A and HS101-A are at 100%):
--   course_code | section_id | section_code | capacity | seats_filled | fill_pct | rank_in_course
--   CS101       |         14 | B            |        5 |            0 |      0.0 |              2
--   EC101       |         15 | B            |       25 |            0 |      0.0 |              2
--   CS204       |          8 | A            |       30 |            1 |      3.3 |              1
--   HS102       |         13 | A            |       30 |            1 |      3.3 |              1
--   CS301       |         10 | A            |       25 |            1 |      4.0 |              1
--   CS101       |          1 | A            |       40 |            2 |      5.0 |              1
--   MA101       |          2 | A            |       40 |            2 |      5.0 |              1
--   CS102       |          4 | A            |       35 |            2 |      5.7 |              1
--   CS201       |          6 | A            |       30 |            2 |      6.7 |              1
--   CS202       |          7 | A            |       30 |            2 |      6.7 |              1
--   CS203       |          9 | A            |       30 |            2 |      6.7 |              1
--   EC101       |         11 | A            |       25 |            3 |     12.0 |              1
--   MA102       |          5 | A            |       35 |            5 |     14.3 |              1


-- =====================================================================
-- PART 9: SCENARIO QUESTIONS  Q8 - Q12
-- =====================================================================
-- Each scenario shows the situation, the statement that is blocked or
-- allowed, and the result.  Run in order, once.

-- ---------------------------------------------------------------------
-- Q8. A student tries to register for two sections that share the same
--     day and time slot. Show the trigger blocking the second and the
--     message that names the clashing course.
--     (BEFORE INSERT trigger, join)
-- ---------------------------------------------------------------------
-- Mohan (student 5) already has CS102-A on Tue 09-11:
SELECT student_name, course_code, day, start_time, end_time
FROM v_student_timetable
WHERE student_id = 5 AND day = 'Tue';
-- ANSWER:
--   student_name | course_code | day | start_time | end_time
--   Mohan Das    | CS102       | Tue | 09:00:00   | 11:00:00
--   Mohan Das    | MA102       | Tue | 11:00:00   | 13:00:00

-- EC101-B (section 15) is also Tue 09-11, so the second one must fail.
-- RUN SEPARATELY (expected error):
-- CALL sp_register_course(5, 15, '2026-08-06');
-- ANSWER: the BEFORE INSERT trigger blocks it:
--   ERROR 1644 (45000): Timetable clash with CS102 - Data Structures

-- ---------------------------------------------------------------------
-- Q9. A student registers for a course whose prerequisite was passed
--     only as a backlog (failed first). Show the check using the latest
--     result and the outcome.  (trigger, subquery on results)
--     CS201 needs CS102.  Karthik: FAIL then PASS.  Ananya: FAIL only.
-- ---------------------------------------------------------------------
-- The latest CS102 result of each student (this is what the trigger reads):
SELECT st.name, c.course_code AS prerequisite, r.term_name, r.status AS latest_status, r.result_date
FROM results r
JOIN students st ON r.student_id = st.student_id
JOIN courses  c  ON r.course_id  = c.course_id
WHERE r.course_id = 4
  AND r.student_id IN (3, 4)
  AND r.result_date = (SELECT MAX(r2.result_date)
                       FROM results r2
                       WHERE r2.student_id = r.student_id
                         AND r2.course_id  = r.course_id);
-- ANSWER:
--   name        | prerequisite | term_name          | latest_status | result_date
--   Karthik Rao | CS102        | Supplementary 2026 | PASS          | 2026-07-18
--   Ananya Iyer | CS102        | Spring 2026        | FAIL          | 2026-05-25
--   (Karthik also failed in Spring 2026, but his LATEST result is the PASS.)

-- Outcome 1: Karthik's latest CS102 result is PASS, so his CS201
-- registration was accepted:
SELECT student_name, course_code, day, start_time
FROM v_student_timetable
WHERE student_id = 3 AND course_code = 'CS201';
-- ANSWER: accepted (backlog cleared):
--   student_name | course_code | day | start_time
--   Karthik Rao  | CS201       | Wed | 09:00:00

-- Outcome 2: Ananya's latest CS102 result is FAIL, so CS201 is rejected.
-- RUN SEPARATELY (expected error):
-- CALL sp_register_course(4, 6, '2026-08-06');
-- ANSWER: rejected (latest result is FAIL):
--   ERROR 1644 (45000): Prerequisite not cleared: CS102

-- ---------------------------------------------------------------------
-- Q10. A student with a confirmed seat drops the course while three
--      students wait. Show the first waitlisted student promoted, the
--      waitlist positions renumbered and seat counts updated in one
--      transaction.  (AFTER UPDATE trigger, ROW_NUMBER)
--      PH101-A (section 3): capacity 3, full, 3 waiting. Ananya drops.
-- ---------------------------------------------------------------------
-- BEFORE the drop:
SELECT * FROM v_section_seats WHERE section_id = 3;
SELECT student_name, position, added_on FROM v_waitlist_status WHERE section_id = 3 ORDER BY position;
-- ANSWER (before): the section is full and three students wait
--   section_id | course_code | capacity | seats_filled | seats_left
--            3 | PH101       |        3 |            3 |          0
--   student_name | position | added_on
--   Divya Sree   |        1 | 2026-08-01
--   Kiran Kumar  |        2 | 2026-08-02
--   Pooja Nair   |        3 | 2026-08-03

CALL sp_drop_course(4, 3, '2026-08-10');
-- ANSWER:
--   result               | promoted_student_id
--   Dropped successfully |                   6

-- AFTER the drop:
SELECT * FROM v_section_seats WHERE section_id = 3;
SELECT student_name, position, added_on FROM v_waitlist_status WHERE section_id = 3 ORDER BY position;
SELECT w.waitlist_id, st.name, w.status, w.position, w.promoted_on
FROM waitlist w JOIN students st ON w.student_id = st.student_id
WHERE w.section_id = 3 ORDER BY w.waitlist_id;
SELECT st.name, r.status, r.reg_date, r.drop_date
FROM registrations r JOIN students st ON r.student_id = st.student_id
WHERE r.section_id = 3 ORDER BY r.registration_id;
-- ANSWER (after): Divya (id 6) is promoted and registered, Kiran and Pooja
-- move up to positions 1 and 2, and the section is full again (seats_left = 0:
-- +1 for the drop, -1 for the promoted student).
--   student_name | position | added_on
--   Kiran Kumar  |        1 | 2026-08-02
--   Pooja Nair   |        2 | 2026-08-03
--
--   waitlist_id | name        | status    | position | promoted_on
--             1 | Divya Sree  | CONFIRMED |     NULL | 2026-08-10
--             2 | Kiran Kumar | WAITING   |        1 | NULL
--             3 | Pooja Nair  | WAITING   |        2 | NULL
--
--   name        | status     | reg_date   | drop_date
--   Ravi Teja   | REGISTERED | 2026-08-05 | NULL
--   Karthik Rao | REGISTERED | 2026-08-05 | NULL
--   Ananya Iyer | DROPPED    | 2026-08-05 | 2026-08-10
--   Divya Sree  | REGISTERED | 2026-08-10 | NULL

-- ---------------------------------------------------------------------
-- Q11. A student with 22 credits adds a 4-credit course with a limit of
--      24. Show the credit-limit trigger rejecting it and how a 2-credit
--      course is accepted.  (trigger, SUM)
--      Ravi (student 1) holds 22 credits.
-- ---------------------------------------------------------------------
SELECT fn_credits_registered(1, 1) AS ravi_credits_now;
-- ANSWER:
--   ravi_credits_now = 22

-- CS101-B (section 14) is a 4-credit course: 22 + 4 = 26 > 24.
-- RUN SEPARATELY (expected error):
-- CALL sp_register_course(1, 14, '2026-08-06');
-- ANSWER: the credit-limit trigger rejects it:
--   ERROR 1644 (45000): Credit limit exceeded: 22 held + 4 new > 24

-- HS102-A (section 13) is a 2-credit course: 22 + 2 = 24, which is allowed.
CALL sp_register_course(1, 13, '2026-08-06');
SELECT fn_credits_registered(1, 1) AS ravi_credits_after;
-- ANSWER: the 2-credit course is accepted:
--   result = Registered successfully
--   ravi_credits_after = 24

-- ---------------------------------------------------------------------
-- Q12. A drop is requested on the day after the add-drop window closed.
--      Show the trigger rejecting it and the special-permission
--      procedure that records dean approval.  (trigger, procedure)
--      Window closes 14-Aug-2026. Mohan (student 5) drops HS101 on 15-Aug.
-- ---------------------------------------------------------------------
SELECT term_name, add_drop_end FROM terms WHERE term_id = 1;
-- ANSWER:
--   term_name | add_drop_end
--   Fall 2026 | 2026-08-14

-- RUN SEPARATELY (expected error):
-- CALL sp_drop_course(5, 12, '2026-08-15');
-- ANSWER: the BEFORE UPDATE trigger rejects the drop (15-Aug is after 14-Aug):
--   ERROR 1644 (45000): Drop not allowed: add-drop window is closed

-- Dean approves the late drop (records who, why and when):
CALL sp_dean_approve_drop(5, 12, 'Dean of Academics', 'Medical grounds - certificate submitted', '2026-08-15');

-- The same drop now succeeds (and Kiran, first on the HS101 waitlist, gets the seat):
CALL sp_drop_course(5, 12, '2026-08-15');
SELECT * FROM dean_approvals;
SELECT st.name, r.status, r.drop_date
FROM registrations r JOIN students st ON r.student_id = st.student_id
WHERE r.section_id = 12 ORDER BY r.registration_id;
-- ANSWER: approval recorded, then the drop succeeds and Kiran (id 7) is promoted:
--   approval_id | student_id | section_id | approved_by       | reason                                  | approved_on
--             1 |          5 |         12 | Dean of Academics | Medical grounds - certificate submitted | 2026-08-15
--
--   name         | status     | drop_date
--   Sita Lakshmi | REGISTERED | NULL
--   Karthik Rao  | REGISTERED | NULL
--   Mohan Das    | DROPPED    | 2026-08-15
--   Divya Sree   | REGISTERED | NULL
--   Kiran Kumar  | REGISTERED | NULL


-- =====================================================================
-- PART 10: DEMO CALLS FOR VIEWS / PROCEDURES / FUNCTIONS / TRIGGERS
-- =====================================================================

-- ----- Views -----
SELECT * FROM v_student_timetable WHERE student_id = 2 ORDER BY day, start_time;
SELECT * FROM v_section_seats;
SELECT * FROM v_faculty_load;
SELECT * FROM v_registration_summary;
SELECT * FROM v_room_utilisation;
SELECT * FROM v_credit_summary;
SELECT * FROM v_unscheduled_sections;
SELECT * FROM v_waitlist_status;

-- ----- Functions -----
SELECT fn_credits_registered(2, 1) AS sita_credits,
       fn_seats_left(3)            AS ph101_seats_left;

-- ----- Procedures -----
CALL sp_generate_timetable(2);          -- print Sita's weekly timetable
CALL sp_section_report(5);              -- MA102-A summary + students
CALL sp_faculty_workload(1, 1);         -- Dr. Suresh Babu, Fall 2026
CALL sp_assign_room(14, 4);             -- give CS101-B the room LAB2
SELECT * FROM v_unscheduled_sections;   -- now empty
CALL sp_add_drop_course(8, 2, 'ADD', '2026-08-07');   -- Pooja adds MA101-A
CALL sp_close_registration(1);          -- lock the term, list students under 18 credits

-- ----- Trigger demo: section rules (RUN SEPARATELY, each gives an error) -----
-- Room clash (R101 is already used on Mon 09-11 by CS101-A):
-- INSERT INTO sections (course_id, term_id, section_code, faculty_id, room_id, time_slot_id, capacity)
-- VALUES (3, 1, 'B', 4, 1, 1, 20);
--   -> ERROR 1644 (45000): Room clash: room already booked in this time slot
-- Room too small (SEM1 holds 20, section wants 30):
-- INSERT INTO sections (course_id, term_id, section_code, faculty_id, room_id, time_slot_id, capacity)
-- VALUES (3, 1, 'C', 4, 5, 6, 30);
--   -> ERROR 1644 (45000): Section capacity exceeds room capacity
-- Faculty clash (Dr. Suresh Babu already teaches on Mon 09-11):
-- INSERT INTO sections (course_id, term_id, section_code, faculty_id, room_id, time_slot_id, capacity)
-- VALUES (3, 1, 'D', 1, 4, 1, 20);
--   -> ERROR 1644 (45000): Faculty clash: faculty already teaching in this time slot
-- =====================================================================
--  END OF PROJECT
-- =====================================================================