-- Test to reproduce JDBC paging error with @@@ operator
-- Simulates multiple executions with OFFSET/LIMIT pagination

-- Create test table
CREATE TABLE test_documents (
    id SERIAL PRIMARY KEY,
    author TEXT,
    content TEXT
);

-- Insert test data
INSERT INTO test_documents (author, content)
SELECT
    'carl',
    'Document ' || i
FROM generate_series(1, 500) AS i;

-- Create ParadeDB index
CALL paradedb.create_bm25_test_table(table_name => 'test_documents', schema_name => 'public');

-- Test 1: Execute same query 20 times with increasing OFFSET (simulating pagination)
-- This simulates what JDBC does when paging through results
DO $$
DECLARE
    page_num INT;
    page_size INT := 20;
    result_count INT;
BEGIN
    FOR page_num IN 0..19 LOOP
        SELECT COUNT(*) INTO result_count
        FROM test_documents
        WHERE author @@@ pdb.match('carl')
        OFFSET (page_num * page_size)
        LIMIT page_size;

        RAISE NOTICE 'Page % (OFFSET %): % results',
            page_num,
            page_num * page_size,
            result_count;
    END LOOP;
END $$;

-- Test 2: Use PREPARE/EXECUTE to simulate JDBC prepared statements
PREPARE paging_query (text, int, int) AS
    SELECT * FROM test_documents
    WHERE author @@@ pdb.match($1)
    OFFSET $2 LIMIT $3;

-- Execute prepared statement 20 times
SELECT 'Executing prepared statement with OFFSET ' || (i * 20) AS test_case, COUNT(*)
FROM generate_series(0, 19) AS i,
LATERAL (
    EXECUTE paging_query('carl', i * 20, 20)
) AS results
GROUP BY i
ORDER BY i;

DEALLOCATE paging_query;

-- Test 3: Test with explicit type casting
PREPARE paging_query_cast (int, int) AS
    SELECT * FROM test_documents
    WHERE author @@@ pdb.match('carl'::text)
    OFFSET $1 LIMIT $2;

-- Execute 20 times
DO $$
DECLARE
    page_num INT;
    page_size INT := 20;
BEGIN
    FOR page_num IN 0..19 LOOP
        EXECUTE 'EXECUTE paging_query_cast(' || (page_num * page_size) || ', ' || page_size || ')';
        RAISE NOTICE 'Prepared query page % completed', page_num;
    END LOOP;
END $$;

DEALLOCATE paging_query_cast;

-- Cleanup
DROP TABLE test_documents CASCADE;
