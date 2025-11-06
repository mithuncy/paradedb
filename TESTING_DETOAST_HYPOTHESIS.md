# Testing the TOAST Hypothesis

## To verify if detoasting is actually the issue:

### 1. Check if arrays are actually TOASTed in production

```sql
-- Run this on your production data
SELECT
    pg_column_size(list_ids) as array_size_bytes,
    array_length(list_ids, 1) as num_elements,
    CASE
        WHEN pg_column_size(list_ids) > 2000 THEN 'likely_toasted'
        ELSE 'inline'
    END as toast_status
FROM contacts_companies_combined_full
WHERE list_ids IS NOT NULL
ORDER BY array_size_bytes DESC
LIMIT 100;
```

**If most large arrays show > 2KB**, they're likely TOASTed (PostgreSQL's default TOAST threshold is ~2KB).

### 2. Add diagnostic logging BEFORE the fix

Temporarily add this to `pg_search/src/postgres/types.rs:178`:

```rust
// Before trying from_datum
pgrx::log!(
    PgLogLevel::WARNING,
    "Array datum: {:?}, is_toasted: {}",
    datum,
    unsafe { pg_sys::VARATT_IS_EXTERNAL_ONDISK(datum.cast_mut_ptr()) }
);
```

This will show if the datum is a TOAST pointer when it crashes.

### 3. Test with intentionally large arrays

```sql
-- Force TOAST by creating huge arrays
CREATE TABLE toast_test (
    id INT,
    huge_array INT[] DEFAULT (SELECT array_agg(i) FROM generate_series(1, 10000) i)
);

INSERT INTO toast_test (id) SELECT generate_series(1, 100);

-- This should crash WITHOUT the fix, work WITH it
CREATE INDEX idx_toast ON toast_test USING bm25 (id, huge_array)
WITH (key_field = 'id');
```

### 4. Alternative test: Disable TOAST temporarily

```sql
-- Create table with storage MAIN (no TOAST)
CREATE TABLE no_toast_test (
    id INT,
    list_ids INT[]
);
ALTER TABLE no_toast_test ALTER COLUMN list_ids SET STORAGE MAIN;

-- If this DOESN'T crash, it confirms TOAST is the issue
```

## What Would Disprove My Theory

If arrays aren't TOASTed in production (all < 2KB), my hypothesis is wrong.

## What Would Prove My Theory

If:
1. Production arrays ARE TOASTed (> 2KB)
2. The diagnostic logging shows `is_toasted: true` when it crashes
3. Forcing STORAGE MAIN prevents the crash
4. The fix resolves the issue in production

Then it's definitely TOAST-related.
