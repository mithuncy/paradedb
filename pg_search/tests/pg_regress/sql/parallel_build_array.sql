-- Test parallel index building with array columns (INT[])
-- This test verifies the fix for the "mid > len" crash that occurred
-- when building indexes on array columns in parallel worker contexts

-- Create a table with an INT[] column
CREATE TABLE parallel_array_test (
    id SERIAL PRIMARY KEY,
    name TEXT,
    list_ids INT[]
);

-- Insert test data with varying array sizes to test TOAST scenarios
-- Small arrays (not TOASTed)
INSERT INTO parallel_array_test (name, list_ids)
SELECT
    'name_' || i,
    ARRAY[i, i+1, i+2]
FROM generate_series(1, 1000) i;

-- Medium arrays
INSERT INTO parallel_array_test (name, list_ids)
SELECT
    'medium_' || i,
    ARRAY(SELECT j FROM generate_series(1, 50) j)
FROM generate_series(1, 1000) i;

-- Large arrays (likely to be TOASTed)
INSERT INTO parallel_array_test (name, list_ids)
SELECT
    'large_' || i,
    ARRAY(SELECT j FROM generate_series(1, 500) j)
FROM generate_series(1, 1000) i;

-- Test with NULL arrays
INSERT INTO parallel_array_test (name, list_ids)
VALUES ('null_array', NULL);

-- Test with empty arrays
INSERT INTO parallel_array_test (name, list_ids)
VALUES ('empty_array', ARRAY[]::INT[]);

-- Configure for parallel build
SET max_parallel_maintenance_workers = 4;
SET parallel_leader_participation = true;
SET maintenance_work_mem = '128MB';

-- Create index with array column - this should not crash
CREATE INDEX parallel_array_idx ON parallel_array_test
USING bm25 (id, name, list_ids)
WITH (key_field = 'id');

-- Verify the index was created and contains all documents
SELECT COUNT(*) as num_segments FROM paradedb.index_info('parallel_array_idx');
SELECT SUM(num_docs) as total_docs FROM paradedb.index_info('parallel_array_idx');

-- Test queries on the indexed array column
SELECT COUNT(*) FROM parallel_array_test WHERE list_ids @@ '1';
SELECT COUNT(*) FROM parallel_array_test WHERE name @@@ 'large';

-- Cleanup
DROP INDEX parallel_array_idx;
DROP TABLE parallel_array_test;
