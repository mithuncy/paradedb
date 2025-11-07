# MT US001 Cluster Recovery Analysis

**Date:** 2025-11-07
**Cluster:** MT Production US001
**Current Status:** 4/5 instances down, cluster critically degraded

## Executive Summary

The MT US001 ParadeDB cluster has suffered a critical failure with missing WAL files in S3 and timeline divergence preventing replicas from joining. Based on code analysis, this is primarily due to **a known bug in ParadeDB Community v0.19.3 and earlier** where writes would get blocked on primaries with hot standbys attached.

**Key Finding:** ParadeDB Community does NOT write pg_search index data to WAL, meaning:
- pg_search indexes are NOT replicated to standbys
- WAL archives do NOT contain pg_search index updates
- Standbys CANNOT serve reads on pg_search indexes (this is an Enterprise-only feature)

## Root Cause Analysis

### 1. Extension Blocking Issue (Primary Cause)

**Bug in v0.19.3 and earlier:**
- Commit [2407641](https://github.com/paradedb/paradedb/commit/2407641297d84b64c713dad81acdd8315e6b79fc) (Oct 31, 2025) fixed a bug where `HotStandbyActive()` incorrectly triggered on the primary when hot standbys were attached
- This caused writes to get blocked on the primary with the error: "Serving reads from a standby requires write-ahead log (WAL) integration"
- **Fixed in v0.19.4** by adding an additional check: `!XLogInsertAllowed()`

**Impact:**
- Primary blocked on writes → unable to fully failover
- Forced manual failover caused timeline divergence
- Extension locks prevented clean failover

### 2. WAL Architecture Limitations

From `/home/user/paradedb/docs/welcome/guarantees.mdx`:

> "ParadeDB Community does NOT write to the WAL, and therefore does not guarantee durability in the face of crashes. For production use cases that require full durability, ParadeDB Enterprise — a closed-source fork of ParadeDB for enterprise customers — includes full WAL integration."

**Implications:**
- pg_search index data exists ONLY on the primary
- `pg_basebackup` and `pg_rewind` do NOT sync pg_search indexes
- Missing WAL files (e.g., `000000090000CEAE00000036`) may be expected for pg_search operations
- Replicas must rebuild pg_search indexes independently

### 3. Timeline Divergence

From logs: `paradedb-16` and `paradedb-17` are attempting `pg_rewind` but failing to join due to:
- Timeline divergence from forced manual promotion
- Potentially missing PostgreSQL system WAL files (not pg_search related)
- Large rewind size (214GB) indicating significant divergence

### 4. Known Enterprise Bug (v0.17.1)

From `/home/user/paradedb/docs/changelog/0.17.1.mdx`:

> "During the upgrade process from 0.16.4 to 0.17.0, ParadeDB hot standbys could go out of sync with the primary, causing read queries to those standbys to fail until the primary updated."

This suggests Enterprise clusters have had similar sync issues during upgrades.

## Current Cluster State Assessment

### Working Components
- ✅ `paradedb-15` (current primary, manually promoted from 16)
- ✅ Pooler pods (rw and ro) are running
- ✅ WAL archiving appears functional on current primary

### Failed Components
- ❌ `paradedb-16` - Running pg_rewind (30%+ complete, 214GB), 2 restarts
- ❌ `paradedb-17` - Failed to join (WAL file `000000090000CEAE00000036` not found)
- ❌ `paradedb-replica-1` - Running, 20 restarts, unable to join
- ❌ Unknown status of 2 other replicas

### Critical Questions

1. **What version is running?** If v0.19.3 or earlier, you're hitting the known blocking bug
2. **Is this ParadeDB Community or Enterprise?**
   - Community: pg_search indexes are NOT replicated
   - Enterprise: Should have WAL integration (but may have sync issues)
3. **What is the data freshness of paradedb-15?** Does it have all data from Aurora upstream?
4. **Are you using Logical Replication from Aurora?** If so, has the replication slot kept up?

## Recovery Options

### Option 1: Complete Cluster Rebuild (RECOMMENDED)

**Best for:** Ensuring data consistency with Aurora upstream

**Steps:**
1. Provision new CNPG cluster with fresh S3 bucket path
2. Backfill from Aurora using Logical Replication
3. Wait for full sync before cutover
4. Keep old cluster read-only as backup during transition

**Pros:**
- Guaranteed data consistency with upstream
- Clean slate eliminates timeline issues
- No risk of missing data

**Cons:**
- Downtime during backfill (~hours to days depending on data size)
- Requires coordination with customers
- Resource intensive (2 clusters running temporarily)

### Option 2: Salvage Current Primary + Rebuild Replicas

**Best for:** Minimizing downtime if paradedb-15 is current

**Prerequisites:**
- Verify `paradedb-15` is fully caught up with Aurora
- Confirm no data loss in Logical Replication slot
- Ensure you're on v0.19.4+ or ready to upgrade

**Steps:**
1. Upgrade to v0.19.4 if not already (fixes primary blocking bug)
2. Take full backup from `paradedb-15`
3. Force new timeline with backup as base
4. Delete all failed replicas
5. Let CNPG recreate replicas from new backup
6. Verify pg_search indexes rebuild correctly on new replicas

**Pros:**
- Less downtime (minutes to hours)
- Preserves current primary if it's healthy
- Faster recovery

**Cons:**
- Risk of data loss if paradedb-15 is not fully synced
- Requires confidence in current primary state
- May still face sync issues with replicas

### Option 3: Wait for pg_rewind Completion (NOT RECOMMENDED)

**Current Status:** paradedb-16 is 30% through 214GB pg_rewind

**Why not recommended:**
- pg_rewind won't sync pg_search indexes (Community limitation)
- Replicas will still fail on pg_search reads
- Timeline divergence may cause ongoing issues
- paradedb-16 has already restarted 2 times (may hit more issues)
- Even if successful, you'd have 1 replica max (need 2+ for HA)

## Immediate Actions Required

### 1. Version Check
```bash
kubectl exec -n paradedb paradedb-15 -c postgres -- psql -U postgres -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_search';"
```

### 2. Data Freshness Check
```bash
# Check Logical Replication lag
kubectl exec -n paradedb paradedb-15 -c postgres -- psql -U postgres -d <database> -c "
SELECT
  slot_name,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as replication_lag,
  active,
  restart_lsn,
  confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_type = 'logical';
"
```

### 3. Backup Current Primary
```bash
# Trigger CNPG backup immediately
kubectl annotate -n paradedb cluster paradedb \
  cnpg.io/reconcile-backup="$(date +%s)"
```

### 4. Decision Point

**If paradedb-15 is fully synced and on v0.19.4:**
→ Proceed with Option 2 (Salvage + Rebuild)

**If any doubts about data completeness:**
→ Proceed with Option 1 (Complete Rebuild)

**If Aurora replication slot is behind:**
→ MUST do Option 1 (data loss has occurred)

## Architecture Recommendations Going Forward

### 1. Upgrade to v0.19.4+
Critical fix for primary blocking with hot standbys

### 2. Consider ParadeDB Enterprise
If you need:
- WAL integration for pg_search indexes
- True HA with readable replicas for search workloads
- Guaranteed durability for search indexes

### 3. CNPG Configuration Best Practices

```yaml
spec:
  instances: 3  # Minimum for HA

  postgresql:
    parameters:
      max_wal_senders: "10"
      wal_keep_size: "1GB"
      hot_standby_feedback: "on"
      shared_preload_libraries: "pg_search"  # Required for PG < 17

  backup:
    barmanObjectStore:
      destinationPath: "s3://bucket/path"
      wal:
        compression: "gzip"
        maxParallel: 2
    retentionPolicy: "30d"

  # Important: Schedule regular backups
  scheduledBackups:
    - name: daily-backup
      schedule: "0 2 * * *"  # 2 AM daily
      backupOwnerReference: self
```

### 4. Monitoring & Alerting

Add alerts for:
- Replication lag exceeding 100MB
- Failed replica join attempts
- WAL archive failures
- Backup failures
- Extension-related errors in logs

### 5. Testing Failover Procedures

Regularly test:
- Controlled primary failover
- Replica recovery from backup
- Logical replication catchup after outage
- pg_search index consistency across instances

## Code References

- **Hot standby check:** `pg_search/src/postgres/storage/metadata.rs:115`
- **WAL integration requirement:** `docs/welcome/guarantees.mdx:13`
- **Fix commit:** `2407641` - "fix: only show hot standby warning if XLogInsertAllowed()"
- **Replication tests:** `tests/tests/replication.rs` (physical/logical replication test suite)
- **CNPG docs:** `docs/deploy/self-hosted/high-availability/configuration.mdx`

## Next Steps

1. **Immediate:** Answer the critical questions above
2. **Within 1 hour:** Decide between Option 1 or Option 2
3. **Within 24 hours:** Execute chosen recovery plan
4. **Post-recovery:** Implement architecture recommendations
5. **Within 1 week:** Document incident and update runbooks

## Questions for ParadeDB Team

1. Is there an upgrade path from Community to Enterprise for existing clusters?
2. Are there tools to verify pg_search index consistency across instances?
3. What is the recommended procedure for recovering from timeline divergence with pg_search indexes?
4. Should CNPG be configured differently for ParadeDB Community vs Enterprise?

---

**Prepared by:** Claude (AI Assistant)
**Repository:** paradedb/paradedb
**Branch:** claude/recover-paradedb-cluster-011CUsqQap6uFrLpbLdyZE2a
