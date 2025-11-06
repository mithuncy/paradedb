# Root Cause Analysis: Parallel Worker Array Crash

## The Mystery

ParadeDB 0.18.14 uses pgrx 0.16.1, which **automatically detoasts arrays** in `Array::from_datum()`.

But production still crashes with "mid > len" errors.

## Hypothesis: Double Detoasting Might Actually Be Necessary

### Scenario 1: pgrx Detoasting Happens Too Late

1. PostgreSQL parallel table scan gives us: `Datum` (TOAST pointer)
2. We pass it to: `try_from_datum_array(datum, oid)`
3. Inside, we call: `pgrx::Array::from_datum(datum, false)`
4. pgrx calls: `RawArray::detoast_from_varlena(ptr)` ← **HERE**
5. But by this point, the TOAST pointer might be **invalid** in the worker's memory context

### Scenario 2: Memory Context Issue

The TOAST pointer is valid when passed to `from_datum`, but during pgrx's detoasting:
- It tries to access the TOAST table
- In a parallel worker, the TOAST table access fails
- Causes memory corruption → "mid > len" panic

## Why My Fix Might Work

By detoasting **BEFORE** passing to pgrx:
```rust
let detoasted_datum = pg_sys::pg_detoast_datum(datum.cast_mut_ptr());
let array: pgrx::Array<Datum> = pgrx::Array::from_datum(Datum::from(detoasted_datum), false)
```

We ensure:
1. Detoasting happens while we still have valid access to the datum
2. We pass actual array data (not a TOAST pointer) to pgrx
3. pgrx's detoasting becomes a no-op (safe, since `pg_detoast_datum` is idempotent)

## Alternative: pgrx Bug

There might be a bug in pgrx 0.16.1's `detoast_from_varlena` that only manifests in parallel workers with large arrays.

## How to Verify

Ask the customer to:
1. Check their production ParadeDB version: `SELECT * FROM pg_available_extensions WHERE name = 'pg_search';`
2. Check if the binary was recently rebuilt
3. Try the fix and see if it resolves the issue
4. If it doesn't, we need to look elsewhere (not array-related)
