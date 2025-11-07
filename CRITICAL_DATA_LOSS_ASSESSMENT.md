# CRITICAL UPDATE: WAL Archiving and Data Loss Assessment

**IMPORTANT CORRECTION TO INITIAL ANALYSIS**

The missing WAL file `000000090000CEAE00000036` may NOT be a pg_search-related WAL that's safe to ignore. It could indicate **actual data loss** from incomplete WAL archiving during the forced failover.

## The Real Question

**Was paradedb-16's WAL fully archived to S3 before you promoted paradedb-15?**

### What Happened (Likely Scenario)

1. **paradedb-16** was the primary, making writes
2. Extension locked up → writes blocked on paradedb-16
3. You **force-promoted paradedb-15** (which was a replica, behind paradedb-16)
4. **paradedb-16's recent WAL may not have been archived** before promotion
5. Logical replication slot on Aurora (publisher) **already advanced** - can't replay those changes

### The Data Loss Window

```
Aurora → paradedb-16 (old primary, made progress X)
                ↓
            WAL Archive (to S3)
                ↓
         paradedb-15 (replica, only had progress X - gap)
                ↓
         [FORCED PROMOTION]
                ↓
         paradedb-15 (new primary, missing some of X)
```

**If WAL archiving didn't finish for paradedb-16's last writes:**
- paradedb-15 doesn't have them
- S3 doesn't have them
- Logical replication slot on Aurora moved forward (can't replay)
- **Those writes are LOST**

## Immediate Assessment Required

### 1. Check if WAL Archiving Was Enabled and Working

```bash
# On paradedb-15 (current primary)
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "SHOW archive_mode;"

kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "SHOW archive_command;"
```

Expected for CNPG:
```
archive_mode = on
archive_command = 'barman-cloud-wal-archive ...'
```

If `archive_mode = off` → **You DEFINITELY have data loss**

### 2. Check WAL Archiving Status

```bash
# Check for failed WAL archives (smoking gun)
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "
SELECT
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time,
    CASE
        WHEN last_failed_time IS NULL THEN 'OK'
        WHEN last_failed_time > last_archived_time THEN 'FAILING NOW'
        ELSE 'RECOVERED'
    END as status
FROM pg_stat_archiver;
"
```

If `failed_count > 0` and `last_failed_time` is recent → **WAL archiving was failing**

### 3. Check the Missing WAL File in S3

```bash
# List WAL files around the missing one
# Replace with your actual S3 bucket path from the logs
aws s3 ls s3://mt-pdb-prod-us001-backup-storage/v1/paradedb/wals/000000090000CEAE/ \
  | grep -C 5 "00000036"
```

Look for:
- `000000090000CEAE00000035` (one before)
- `000000090000CEAE00000036` (missing)
- `000000090000CEAE00000037` (one after)

**If both 35 and 37 exist but 36 is missing:**
- This is a PostgreSQL system WAL (not pg_search)
- **You have data loss** in that WAL segment (16MB of writes)

**If many WALs are missing starting from some point:**
- WAL archiving stopped working
- **Data loss is larger**

### 4. Check the Timeline Divergence

```bash
# On paradedb-15 (current primary)
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "
SELECT pg_walfile_name(pg_current_wal_lsn());
SELECT timeline_id, redo_lsn FROM pg_control_checkpoint();
"
```

Compare the timeline ID to what paradedb-16/17 are trying to join from. If different timelines → confirms forced promotion created a fork.

### 5. Check Logical Replication Slot Position (on Aurora)

**This is the critical one** - can you check Aurora's logical replication slot?

```sql
-- On Aurora (the publisher)
SELECT
    slot_name,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
FROM pg_replication_slots
WHERE slot_name = '<your_paradedb_slot_name>';
```

**If `confirmed_flush_lsn` > paradedb-15's current LSN:**
- The slot has advanced past where paradedb-15 is
- **You cannot recover those writes**
- Data loss is confirmed

## Data Loss Severity Assessment

### Scenario A: Small Gap (Best Case)

**If:**
- Only 1-2 WAL files are missing (like `000000090000CEAE00000036`)
- Last archived time was close to promotion time (< 5 minutes)
- Failed count in `pg_stat_archiver` is low (< 5)

**Data Loss:**
- Up to ~16MB of WAL per missing file
- Likely < 5 minutes of writes
- May be acceptable depending on business requirements

### Scenario B: Large Gap (Worst Case)

**If:**
- Many WAL files are missing
- Last archived time was hours before promotion
- Failed count is high or WAL archiving was disabled

**Data Loss:**
- Could be hours of writes
- **Cluster may be irrecoverable without Aurora replication restart**

## What the "sync-rep to secondary" Point Means

You mentioned: *"If you don't have this thing (or sync-rep to the secondary) enabled then any failover implicitly means data-loss is possible."*

**Synchronous Replication Configuration:**

```sql
-- This ensures paradedb-15 (replica) had all writes before primary could commit
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM SET synchronous_standby_names = '*';  -- or specific replica names
```

**If this was NOT set:**
- paradedb-16 could commit writes without waiting for paradedb-15 to receive them
- When paradedb-16 died and paradedb-15 was promoted → **gap exists**
- Even with WAL archiving, there's a window where WAL wasn't archived yet

**This is likely your situation.**

## Recovery Options Revised

### Option 1: Accept Data Loss and Move Forward (If Small)

**If WAL gap is small (minutes) and business can accept:**

1. Acknowledge data loss window
2. Proceed with Option 2 from original recovery doc
3. Notify customers of potential data inconsistency
4. Set up sync-rep going forward

### Option 2: Rebuild from Aurora (If Large)

**If WAL gap is large or unacceptable:**

1. **Stop logical replication subscription** on paradedb-15
2. **Restart the logical replication slot on Aurora:**
   ```sql
   -- On Aurora
   SELECT pg_drop_replication_slot('<slot_name>');
   SELECT pg_create_logical_replication_slot('<slot_name>', 'pgoutput');
   ```
3. **Recreate subscription** on paradedb-15 with `copy_data = true`
4. **Wait for full re-sync** (hours to days)

This is essentially starting over but guarantees data consistency.

### Option 3: Provision New Cluster from Scratch

Same as Option 1 from original doc - cleanest but slowest.

## Enabling Sync-Rep Going Forward

After recovery, **prevent this from happening again:**

```yaml
# In CNPG cluster spec
spec:
  postgresql:
    parameters:
      synchronous_commit: "on"
      synchronous_standby_names: "*"  # Wait for any standby
      # OR be specific:
      # synchronous_standby_names: "paradedb-16,paradedb-17"
```

**Trade-off:**
- **Pro:** Zero data loss on failover (replica has everything)
- **Con:** Write latency increases (must wait for replica ACK)
- **Con:** If all standbys are down, writes will block

**Alternative (less strict):**
```yaml
synchronous_commit: "remote_write"  # Faster, still safe
```

## Immediate Action Items

1. **Run all 5 checks above** to assess data loss severity
2. **Check Aurora replication slot position** (critical!)
3. **If data loss is small:** Proceed with fast recovery, document the gap
4. **If data loss is large:** Must rebuild from Aurora
5. **Enable sync-rep** in recovered cluster

## The pg_search vs PostgreSQL WAL Distinction

**I was partially wrong in my initial analysis:**

- ✅ Correct: pg_search indexes don't write to WAL in Community
- ✅ Correct: Missing pg_search WAL is expected
- ❌ Incomplete: The missing WAL `000000090000CEAE00000036` **could be PostgreSQL system WAL**

**How to tell the difference:**
- If S3 has continuous WAL files except one specific one missing → likely PostgreSQL WAL → data loss
- If you can verify the WAL archiving was failing → definitely data loss
- If `pg_stat_archiver` shows failures → data loss

## Key Insight You Provided

> "The logical replication slot is on the publisher, so it's already been advanced and can't help you here."

**This is the killer.** If the slot on Aurora has moved past where paradedb-15 is, those changes are **gone** unless you:
- Restart the slot (full re-sync)
- Or build a new cluster

## Questions to Answer

1. **What does `pg_stat_archiver` show on paradedb-15?**
2. **Can you check the Aurora replication slot LSN vs paradedb-15's current LSN?**
3. **What's in S3 around WAL `000000090000CEAE00000036`?**
4. **Was `synchronous_standby_names` configured?**

Answers to these will tell us exactly how much data loss occurred.

---

**Created:** 2025-11-07 (Updated)
**Critical Priority:** Assess data loss before proceeding with any recovery
