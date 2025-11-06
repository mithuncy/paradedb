# JDBC Paging Issue Reproduction Guide

## Issue Description
Error after 10-18 pages when using JDBC to page through search results:
```
ERROR: The right-hand side of the `@@@` operator must be a text value
```

## Query That Fails
```sql
SELECT * FROM documents.documents_view
WHERE author @@@ pdb.match('carl')
OFFSET 80 LIMIT 20
```

## Changes Made for Diagnosis

Added enhanced error logging in `/home/user/paradedb/pg_search/src/api/operator/atatat.rs:100-111` that will now show:
- The actual type OID that was rejected
- Expected type OIDs (TEXTOID, VARCHAROID, UNKNOWNOID, pdb.Query, SearchQueryInput)

## How to Reproduce and Capture Diagnostics

### Option 1: Run SQL Test
```bash
cd /home/user/paradedb/pg_search
# Build and install with new diagnostics
cargo pgrx run

# In psql:
\i tests/pg_regress/sql/jdbc_paging_reproduce.sql
```

### Option 2: JDBC Test Program

Create `JDBCPagingTest.java`:

```java
import java.sql.*;

public class JDBCPagingTest {
    public static void main(String[] args) throws Exception {
        // IMPORTANT: Try with different prepareThreshold values:
        // - prepareThreshold=0: Always use prepared statements
        // - prepareThreshold=5: Default (prepare after 5 executions)
        // - prepareThreshold=-1: Never use prepared statements

        String url = "jdbc:postgresql://localhost:5432/yourdb?prepareThreshold=5";
        Connection conn = DriverManager.getConnection(url, "user", "password");

        // Test 1: Using PreparedStatement (MOST LIKELY TO REPRODUCE)
        System.out.println("=== Test 1: PreparedStatement ===");
        String sql = "SELECT * FROM documents.documents_view WHERE author @@@ pdb.match(?) OFFSET ? LIMIT 20";
        PreparedStatement ps = conn.prepareStatement(sql);

        for (int page = 0; page < 20; page++) {
            try {
                ps.setString(1, "carl");
                ps.setInt(2, page * 20);
                ResultSet rs = ps.executeQuery();
                int count = 0;
                while (rs.next()) count++;
                System.out.println("Page " + page + " (offset " + (page * 20) + "): " + count + " results");
                rs.close();
            } catch (SQLException e) {
                System.err.println("FAILED at page " + page + ": " + e.getMessage());
                break;
            }
        }
        ps.close();

        // Test 2: Using Statement with string concatenation (LESS LIKELY)
        System.out.println("\n=== Test 2: Statement (no preparation) ===");
        Statement stmt = conn.createStatement();

        for (int page = 0; page < 20; page++) {
            try {
                String query = "SELECT * FROM documents.documents_view " +
                              "WHERE author @@@ pdb.match('carl') " +
                              "OFFSET " + (page * 20) + " LIMIT 20";
                ResultSet rs = stmt.executeQuery(query);
                int count = 0;
                while (rs.next()) count++;
                System.out.println("Page " + page + " (offset " + (page * 20) + "): " + count + " results");
                rs.close();
            } catch (SQLException e) {
                System.err.println("FAILED at page " + page + ": " + e.getMessage());
                break;
            }
        }
        stmt.close();
        conn.close();
    }
}
```

Compile and run:
```bash
javac -cp postgresql-42.7.0.jar JDBCPagingTest.java
java -cp .:postgresql-42.7.0.jar JDBCPagingTest
```

### Option 3: Test with psql PREPARE
```sql
-- This simulates what JDBC does internally
PREPARE paging_query (text, int) AS
    SELECT * FROM documents.documents_view
    WHERE author @@@ pdb.match($1)
    OFFSET $2 LIMIT 20;

-- Execute 20 times
EXECUTE paging_query('carl', 0);
EXECUTE paging_query('carl', 20);
EXECUTE paging_query('carl', 40);
-- ... continue up to OFFSET 360+
EXECUTE paging_query('carl', 360);

DEALLOCATE paging_query;
```

## What to Look For

When the error occurs, the new diagnostic message will show:
```
ERROR: The right-hand side of the `@@@` operator must be a text value.
Got type OID: XXXXX (TEXTOID=25, VARCHAROID=1043, UNKNOWNOID=705, pdb.Query=YYYYY, SearchQueryInput=ZZZZZ)
```

**Key information needed:**
1. What is the actual type OID (XXXXX)?
2. Does it match SearchQueryInput or UNKNOWNOID?
3. At what page/execution number does it first fail?
4. What JDBC connection parameters are you using (especially prepareThreshold)?

## JDBC Connection String Parameters to Try

Test with different settings to narrow down the issue:

```java
// Never use prepared statements
"jdbc:postgresql://localhost:5432/db?prepareThreshold=-1"

// Always use prepared statements (from first execution)
"jdbc:postgresql://localhost:5432/db?prepareThreshold=0"

// Default: prepare after 5 executions
"jdbc:postgresql://localhost:5432/db?prepareThreshold=5"

// Disable statement caching
"jdbc:postgresql://localhost:5432/db?preparedStatementCacheQueries=0"
```

## Next Steps

1. Run one of the reproduction methods above
2. Capture the exact error message with type OIDs
3. Report back with:
   - Exact error message
   - Page number where it failed
   - JDBC settings used
   - PostgreSQL and ParadeDB versions

This will tell us whether the fix should add support for UNKNOWNOID, SearchQueryInput, or something else entirely.
