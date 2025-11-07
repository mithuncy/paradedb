#!/bin/bash

# MT US001 Cluster Recovery Script
# Purpose: Diagnose and recover failed ParadeDB CNPG cluster
# Author: Generated for MT US001 incident recovery
# Date: 2025-11-07

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-paradedb}"
CLUSTER_NAME="${CLUSTER_NAME:-paradedb}"
PRIMARY_POD="${PRIMARY_POD:-paradedb-15}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Check ParadeDB version
check_version() {
    log_info "Checking ParadeDB version on primary..."

    VERSION=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -t -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_search';" 2>/dev/null | tr -d ' ')

    if [ -z "$VERSION" ]; then
        log_error "Could not determine pg_search version"
        return 1
    fi

    log_info "pg_search version: $VERSION"

    # Check if version is < 0.19.4
    if [[ "$VERSION" < "0.19.4" ]]; then
        log_warn "You are running version $VERSION which has a known bug causing write blocks on primaries with hot standbys"
        log_warn "This bug was fixed in v0.19.4"
        log_warn "Recommendation: Upgrade to v0.19.4+ before proceeding"
        echo ""
        read -p "Do you want to continue anyway? (yes/no): " response
        if [[ "$response" != "yes" ]]; then
            log_error "Aborting. Please upgrade to v0.19.4+ first"
            exit 1
        fi
    else
        log_info "Version check passed (>= 0.19.4)"
    fi
}

# Step 2: Check cluster status
check_cluster_status() {
    log_info "Checking cluster pod status..."

    kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" -o wide

    echo ""
    log_info "Checking CNPG cluster status..."
    kubectl get cluster -n "$NAMESPACE" "$CLUSTER_NAME" -o yaml | grep -A 20 "status:" || true
}

# Step 3: Check replication lag
check_replication_lag() {
    log_info "Checking logical replication lag..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as replication_lag,
    restart_lsn,
    confirmed_flush_lsn
FROM pg_replication_slots
ORDER BY slot_type, slot_name;
" || log_warn "Could not check replication slots"
}

# Step 4: Check WAL archiving status
check_wal_archiving() {
    log_info "Checking WAL archiving status..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    last_archived_wal,
    last_archived_time,
    last_failed_wal,
    last_failed_time,
    CASE WHEN last_failed_time IS NULL THEN 'OK'
         ELSE 'FAILED: ' || last_failed_wal
    END as archiving_status
FROM pg_stat_archiver;
" || log_warn "Could not check WAL archiving status"
}

# Step 5: Check primary database size
check_database_size() {
    log_info "Checking database sizes..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) as size
FROM pg_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY pg_database_size(datname) DESC;
" || log_warn "Could not check database sizes"
}

# Step 6: Trigger backup
trigger_backup() {
    log_info "Triggering on-demand backup of primary..."

    TIMESTAMP=$(date +%s)

    kubectl annotate cluster -n "$NAMESPACE" "$CLUSTER_NAME" \
        cnpg.io/reconcile-backup="$TIMESTAMP" \
        --overwrite

    log_info "Backup triggered. Check status with:"
    echo "  kubectl get backup -n $NAMESPACE"
    echo ""
    log_warn "Wait for backup to complete before proceeding with recovery"
}

# Step 7: Check for failed pods
check_failed_pods() {
    log_info "Checking for pods with high restart counts..."

    kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
        | awk '$2 > 2 { print "  Pod " $1 " has " $2 " restarts" }'
}

# Step 8: Check pg_rewind progress
check_pg_rewind_progress() {
    log_info "Checking for ongoing pg_rewind operations..."

    for pod in $(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" -o name); do
        pod_name=$(basename "$pod")
        log_info "Checking logs for $pod_name..."

        kubectl logs -n "$NAMESPACE" "$pod_name" --tail=50 2>/dev/null \
            | grep -i "pg_rewind\|copied" \
            | tail -5 || echo "  No pg_rewind activity"
    done
}

# Step 9: Generate recovery recommendations
generate_recommendations() {
    log_info "Generating recovery recommendations..."
    echo ""
    echo "========================================="
    echo "RECOVERY RECOMMENDATIONS"
    echo "========================================="
    echo ""

    # Check if backup completed
    log_info "1. Verify backup completed successfully:"
    echo "   kubectl get backup -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME"
    echo ""

    log_info "2. If backup is complete and primary is healthy, proceed with Option 2:"
    echo "   - Delete all failed replica pods"
    echo "   - Force CNPG to recreate replicas from latest backup"
    echo ""
    echo "   Commands:"
    echo "   # Delete failed replicas (adjust pod names as needed)"
    echo "   kubectl delete pod -n $NAMESPACE paradedb-16 paradedb-17 paradedb-replica-1"
    echo ""
    echo "   # Scale cluster down then back up to force recreation"
    echo "   kubectl cnpg scale -n $NAMESPACE $CLUSTER_NAME --instances 1"
    echo "   sleep 30"
    echo "   kubectl cnpg scale -n $NAMESPACE $CLUSTER_NAME --instances 3"
    echo ""

    log_info "3. If primary is NOT healthy or data is missing, proceed with Option 1:"
    echo "   - Provision new cluster with fresh S3 bucket"
    echo "   - Backfill from Aurora using logical replication"
    echo "   - This is documented in the RECOVERY_ANALYSIS.md"
    echo ""

    log_warn "4. Monitor replica creation:"
    echo "   kubectl get pods -n $NAMESPACE -w"
    echo "   kubectl logs -n $NAMESPACE <new-replica-pod> -c postgres -f"
    echo ""

    log_info "5. Verify pg_search indexes after replicas join:"
    echo "   # Check that indexes exist on replicas (they will be rebuilt)"
    echo "   kubectl exec -n $NAMESPACE <replica-pod> -c postgres -- \\"
    echo "     psql -U postgres -d <database> -c '\"\di'"
    echo ""

    log_warn "IMPORTANT: ParadeDB Community does NOT replicate pg_search indexes via WAL"
    echo "  - Replicas will rebuild pg_search indexes independently"
    echo "  - Replicas CANNOT serve reads on pg_search indexes (Enterprise feature only)"
    echo "  - Missing WAL files for pg_search operations are expected"
    echo ""
}

# Main execution
main() {
    log_info "Starting MT US001 Cluster Recovery Diagnostic"
    log_info "Namespace: $NAMESPACE"
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Primary Pod: $PRIMARY_POD"
    echo ""

    # Run diagnostics
    check_version
    echo ""

    check_cluster_status
    echo ""

    check_replication_lag
    echo ""

    check_wal_archiving
    echo ""

    check_database_size
    echo ""

    check_failed_pods
    echo ""

    check_pg_rewind_progress
    echo ""

    # Ask if user wants to trigger backup
    read -p "Do you want to trigger an on-demand backup? (yes/no): " response
    if [[ "$response" == "yes" ]]; then
        trigger_backup
    fi

    echo ""
    generate_recommendations

    log_info "Diagnostic complete. Review recommendations above."
}

# Run main function
main
