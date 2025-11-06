# Bug Analysis: JDBC Paging Error with @@@ Operator

## Summary

**Error:** `The right-hand side of the @@@ operator must be a text value`

**When:** After 10-18 pages of JDBC pagination (roughly 10-18 query executions)

**Root Cause:** The `exec_rewrite` callback in `atatat_support` doesn't allow `UNKNOWNOID` type, which is used by PostgreSQL parameter placeholders in prepared statements.

## Technical Details

### Code Flow

1. **Support Function Chain:**
   ```
   atatat_support (atatat.rs:54)
     └─> request_simplify (operator.rs:416)
           └─> rewrite_rhs_to_search_query_input (operator.rs:563)
                 └─> exec_rewrite callback (atatat.rs:94)
   ```

2. **The Failing Assertion** (atatat.rs:101-103):
   ```rust
   assert!(
       expr_type == pg_sys::TEXTOID || expr_type == pg_sys::VARCHAROID || is_pdb_query,
       "The right-hand side of the `@@@` operator must be a text value"
   );
   ```

3. **Why It Fails:**
   - JDBC prepared statements use parameter placeholders (`$1`, `$2`, etc.)
   - These placeholders are `Param` nodes with type `UNKNOWNOID` (703)
   - The assertion doesn't allow `UNKNOWNOID`

### JDBC Behavior

**Default JDBC PrepareThreshold = 5:**
- Executions 1-5: Simple query protocol (literal values) → Works ✓
- Executions 6+: Server-side prepared statements (parameters) → Fails ❌

**Query transformations:**
```sql
-- Executions 1-5 (simple queries):
SELECT ... WHERE author @@@ pdb.match('carl') OFFSET 0 LIMIT 20
-- Type: pdb::Query (from literal function call) ✓

-- Executions 6+ (prepared statements):
PREPARE stmt AS SELECT ... WHERE author @@@ pdb.match($1) OFFSET $2 LIMIT 20
EXECUTE stmt('carl', 0)
-- Type: UNKNOWNOID (parameter placeholder) ❌
```

### Why User Couldn't Reproduce in psql

The user likely tested with:
```sql
SELECT ... WHERE author @@@ pdb.match('carl') OFFSET X LIMIT 20
```

This uses **literal values**, not parameter placeholders, so type is `pdb::Query`, which passes the assertion.

To reproduce in psql, they would need:
```sql
PREPARE stmt(text, int, int) AS
    SELECT ... WHERE author @@@ pdb.match($1) OFFSET $2 LIMIT $3;
EXECUTE stmt('carl', 0, 20);
```

## The Fix

The `exec_rewrite` callback needs to accept two additional types:

1. **`UNKNOWNOID`** - For parameter placeholders in prepared statements
2. **`SearchQueryInput`** - Defensive, in case PostgreSQL passes a previously transformed expression

### Fixed Code (atatat.rs:94-113):

```rust
|field, _, rhs| {
    let search_query_input_typoid = searchqueryinput_typoid();
    let pdb_query_typoid = pdb_query_typoid();
    let expr_type = get_expr_result_type(rhs);
    let is_pdb_query = expr_type == pdb_query_typoid;
    let is_search_query_input = expr_type == search_query_input_typoid;

    assert!(
        expr_type == pg_sys::TEXTOID
            || expr_type == pg_sys::VARCHAROID
            || expr_type == pg_sys::UNKNOWNOID        // <-- ADD THIS
            || is_pdb_query
            || is_search_query_input,                 // <-- ADD THIS
        "The right-hand side of the `@@@` operator must be a text value, but got type OID: {}",
        expr_type
    );
    // ... rest of function
}
```

### Same Fix Needed for Other Operators

The same issue affects:
- `&&&` operator (andandand.rs)
- `|||` operator (ororor.rs)
- `###` operator (hashhashhash.rs)

All have the same pattern and need the same fix.

## Testing

### Minimal Reproduction

```sql
-- Create test table
CREATE TABLE test (id SERIAL, content TEXT);
INSERT INTO test SELECT i, 'test' FROM generate_series(1, 100) i;
CALL paradedb.create_bm25_test_table('test');

-- This will fail without the fix:
PREPARE test_query(text) AS
    SELECT * FROM test WHERE content @@@ pdb.match($1) LIMIT 10;

-- Execute multiple times
EXECUTE test_query('test');  -- Should work
```

### JDBC Test

```java
String sql = "SELECT * FROM test WHERE content @@@ pdb.match(?) OFFSET ? LIMIT 20";
PreparedStatement ps = conn.prepareStatement(sql);
for (int i = 0; i < 20; i++) {
    ps.setString(1, "test");
    ps.setInt(2, i * 20);
    ps.executeQuery();  // Will fail after prepareThreshold executions
}
```

## Type OID Reference

- `TEXTOID` = 25
- `VARCHAROID` = 1043
- `UNKNOWNOID` = 705
- `pdb::Query` = (dynamic, looked up at runtime)
- `SearchQueryInput` = (dynamic, looked up at runtime)

## Conclusion

The fix is straightforward and correct:
1. Add `UNKNOWNOID` to handle parameter placeholders
2. Add `SearchQueryInput` for defensive programming
3. Apply to all search operators for consistency

This allows JDBC prepared statements to work correctly while maintaining type safety for actual execution.
