# MT US001 Cluster Recovery - Quick Start Guide

**CRITICAL SITUATION:** 4/5 instances down, timeline divergence, missing WAL files

## TL;DR - What You Need to Know

### The Core Issue
ParadeDB Community (not Enterprise) **does NOT write pg_search indexes to WAL**. This means:
- ❌ pg_search indexes are NOT in WAL archives (missing WAL files are expected)
- ❌ Replicas CANNOT read from pg_search indexes
- ❌ `pg_basebackup` and `pg_rewind` do NOT sync pg_search indexes
- ✅ Only PostgreSQL system data is replicated (tables, regular indexes, etc.)

### The Bug That Started This
**Version 0.19.3 and earlier** had a bug where the primary would get blocked on writes when hot standbys were connected. This was fixed in **v0.19.4**.

If you're on v0.19.3 or earlier, you MUST upgrade.

## Quick Decision Tree

```
Is paradedb-15 (current primary) fully synced with Aurora?
│
├─ YES → Can you afford ~1 hour downtime?
│  │
│  ├─ YES → Option 2: Salvage Current Primary + Rebuild Replicas (recommended)
│  │
│  └─ NO → Must assess if data loss is acceptable (NOT recommended)
│
└─ NO or UNSURE → Option 1: Complete Cluster Rebuild (safest)
```

## Option 2: Fast Recovery (Salvage + Rebuild)

**Use this if:** Current primary is healthy and synced with Aurora

### Prerequisites Check
```bash
# 1. Check version (must be 0.19.4+)
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_search';"

# 2. Check replication lag (should be < 100MB)
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -d <your_database> -c "
SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots WHERE slot_type = 'logical';
"
```

### Recovery Steps

#### Step 1: Trigger Backup (5 minutes)
```bash
kubectl annotate cluster -n paradedb paradedb cnpg.io/reconcile-backup="$(date +%s)"

# Wait for completion
kubectl get backup -n paradedb -w
```

#### Step 2: Delete Failed Replicas (1 minute)
```bash
# Delete pods that are failing to join
kubectl delete pod -n paradedb paradedb-16
kubectl delete pod -n paradedb paradedb-17
kubectl delete pod -n paradedb paradedb-replica-1
```

#### Step 3: Force Replica Rebuild (30-60 minutes)
```bash
# Option A: Let CNPG recreate naturally
# Just wait for CNPG to recreate the deleted pods from backup

# Option B: Force recreation by scaling
kubectl cnpg scale -n paradedb paradedb --instances 1
sleep 60
kubectl cnpg scale -n paradedb paradedb --instances 3

# Monitor recreation
kubectl get pods -n paradedb -w
```

#### Step 4: Verify Replicas Join Successfully
```bash
# Watch logs for new replica
kubectl logs -n paradedb paradedb-<new-pod-number> -c postgres -f

# Look for:
# - "database system is ready to accept read-only connections"
# - No errors about WAL files (pg_search WAL errors are expected)
# - pg_search indexes will rebuild independently
```

#### Step 5: Verify Replication
```bash
# Check replication status from primary
kubectl exec -n paradedb paradedb-15 -c postgres -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Should show 2 replicas connected (if instances=3)
```

### Expected Timeline
- Backup: 5 minutes (cluster is small) to 1 hour (large cluster)
- Pod deletion: 1 minute
- Replica bootstrap from backup: 30-60 minutes per replica
- **Total: 1-2 hours**

## Option 1: Complete Rebuild (Safest but Slower)

**Use this if:** Unsure about current primary health or data completeness

### Steps
1. Create new CNPG cluster with different name and S3 path
2. Configure logical replication from Aurora
3. Wait for full sync (hours to days)
4. Cut over to new cluster
5. Decommission old cluster

**Detailed steps:** See `MT_US001_CLUSTER_RECOVERY_ANALYSIS.md`

## Common Issues & Solutions

### Issue: "WAL file not found in recovery object store"
**Solution:** This is EXPECTED for ParadeDB Community. pg_search indexes are not in WAL.
- Ignore errors for pg_search-related WAL files
- Only worry if PostgreSQL system table WAL files are missing

### Issue: Replica won't start after recreation
**Check:**
1. Is backup completed and valid?
2. Is S3 credentials/permissions correct?
3. Are there actual missing PostgreSQL WAL files (not pg_search)?

**Debug:**
```bash
kubectl logs -n paradedb paradedb-<pod> -c postgres --tail=200
```

### Issue: pg_rewind taking forever (paradedb-16)
**Solution:** Just delete the pod and let CNPG recreate from backup instead.

`pg_rewind` won't help because:
- It doesn't sync pg_search indexes anyway (Community limitation)
- Timeline divergence will cause ongoing issues
- Faster to bootstrap from backup

### Issue: Primary still blocking on writes
**Solution:** You're on v0.19.3 or earlier. Upgrade to v0.19.4+

```bash
# Check if writes are blocked
kubectl logs -n paradedb paradedb-15 -c postgres | grep -i "standby\|xlog"
```

## Monitoring During Recovery

### Watch Pod Status
```bash
watch kubectl get pods -n paradedb -l cnpg.io/cluster=paradedb
```

### Watch Backup Status
```bash
watch kubectl get backup -n paradedb
```

### Monitor Primary Logs
```bash
kubectl logs -n paradedb paradedb-15 -c postgres -f
```

### Monitor New Replica Logs
```bash
# Replace <N> with actual replica number
kubectl logs -n paradedb paradedb-<N> -c postgres -f
```

## Red Flags to Watch For

🚨 **Immediate attention required:**
- Logical replication lag > 1GB (data loss risk)
- Primary can't write (check version, upgrade needed)
- Backup fails (check S3 permissions/quota)
- New replicas restart more than 3 times (deeper issue)

⚠️ **Monitor but may be expected:**
- "WAL file not found" for pg_search operations
- Replicas taking time to rebuild pg_search indexes
- pg_rewind showing slow progress (just delete and recreate)

✅ **Good signs:**
- Backup completes successfully
- New replicas show "ready to accept read-only connections"
- Replication lag is stable and low
- No restart loops

## Post-Recovery Checklist

- [ ] All 3 pods are running and healthy
- [ ] `kubectl get cluster paradedb` shows 3/3 ready
- [ ] Logical replication from Aurora is working
- [ ] Recent backup exists and is valid
- [ ] No pods in restart loop
- [ ] Monitoring alerts are configured
- [ ] Incident postmortem scheduled

## Need Help?

1. **Run diagnostics:** `bash scripts/recover_cluster.sh`
2. **Read full analysis:** `MT_US001_CLUSTER_RECOVERY_ANALYSIS.md`
3. **Check CNPG docs:** https://cloudnative-pg.io/documentation/

## Key Takeaways

1. **ParadeDB Community != HA for pg_search**
   - Replicas are for PostgreSQL data HA only
   - pg_search indexes exist only on primary
   - Consider Enterprise for true search HA

2. **Upgrade to v0.19.4+**
   - Critical fix for primary blocking bug
   - Required for stable HA operation

3. **Test Failover Regularly**
   - Don't wait for production incident
   - Practice primary promotion
   - Verify replica can be promoted

4. **Monitor Proactively**
   - Replication lag alerts
   - Backup success/failure
   - Pod restart counts
   - Extension-related errors

---

**Created:** 2025-11-07
**For:** MT US001 Production Incident
**Branch:** claude/recover-paradedb-cluster-011CUsqQap6uFrLpbLdyZE2a
