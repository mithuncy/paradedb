#!/bin/bash

# Data Loss Assessment Script for MT US001
# Purpose: Check if forced failover caused data loss due to incomplete WAL archiving
# Author: Generated for MT US001 incident
# Date: 2025-11-07

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-paradedb}"
PRIMARY_POD="${PRIMARY_POD:-paradedb-15}"
S3_BUCKET="${S3_BUCKET:-mt-pdb-prod-us001-backup-storage}"
S3_PREFIX="${S3_PREFIX:-v1/paradedb}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_critical() {
    echo -e "${RED}[CRITICAL]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Check 1: WAL Archiving Configuration
check_wal_archiving_config() {
    log_section "CHECK 1: WAL Archiving Configuration"

    log_info "Checking if WAL archiving is enabled..."

    ARCHIVE_MODE=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -t -c "SHOW archive_mode;" 2>/dev/null | tr -d ' ')

    ARCHIVE_COMMAND=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -t -c "SHOW archive_command;" 2>/dev/null | xargs)

    echo "  archive_mode: $ARCHIVE_MODE"
    echo "  archive_command: $ARCHIVE_COMMAND"
    echo ""

    if [ "$ARCHIVE_MODE" != "on" ]; then
        log_critical "WAL archiving is DISABLED. Data loss is CERTAIN."
        echo "  Any writes on paradedb-16 that weren't replicated to paradedb-15 are LOST."
        return 1
    fi

    if [[ "$ARCHIVE_COMMAND" == *"barman"* ]] || [[ "$ARCHIVE_COMMAND" == *"wal-archive"* ]]; then
        log_info "WAL archiving is enabled with: $ARCHIVE_COMMAND"
    else
        log_warn "archive_command doesn't look like barman. Please verify."
    fi
}

# Check 2: WAL Archiving Status
check_wal_archiving_status() {
    log_section "CHECK 2: WAL Archiving Status"

    log_info "Checking pg_stat_archiver for failed archives..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    archived_count as total_archived,
    last_archived_wal,
    last_archived_time,
    failed_count as total_failed,
    last_failed_wal,
    last_failed_time,
    CASE
        WHEN last_failed_time IS NULL THEN '✓ OK'
        WHEN last_failed_time > last_archived_time THEN '✗ CURRENTLY FAILING'
        WHEN last_failed_time < last_archived_time - INTERVAL '1 hour' THEN '✓ RECOVERED'
        ELSE '⚠ RECENTLY FAILED'
    END as status
FROM pg_stat_archiver;
" 2>/dev/null || log_error "Could not query pg_stat_archiver"

    echo ""
    log_info "Interpreting results:"
    echo "  - If failed_count = 0: WAL archiving has been reliable"
    echo "  - If failed_count > 0 and last_failed_time is recent: PROBLEM"
    echo "  - Recent failures during the incident window = data loss likely"
}

# Check 3: Current WAL Position and Timeline
check_wal_position() {
    log_section "CHECK 3: Current WAL Position"

    log_info "Checking current WAL file and timeline..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    pg_walfile_name(pg_current_wal_lsn()) as current_wal_file,
    pg_current_wal_lsn() as current_lsn;
" 2>/dev/null || log_error "Could not get WAL position"

    echo ""

    log_info "Checking timeline from pg_control..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT timeline_id, redo_lsn
FROM pg_control_checkpoint();
" 2>/dev/null || log_error "Could not get timeline info"
}

# Check 4: Check for Missing WAL in S3
check_s3_wal_files() {
    log_section "CHECK 4: S3 WAL File Check"

    log_warn "This requires AWS CLI access and S3 credentials"
    log_info "Checking for missing WAL file: 000000090000CEAE00000036"
    echo ""

    # Try to list files around the missing WAL
    log_info "Attempting to list WALs in S3 bucket: s3://$S3_BUCKET/$S3_PREFIX/wals/"
    echo "  (This may fail if AWS CLI is not configured)"
    echo ""

    if command -v aws &> /dev/null; then
        aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/wals/000000090000CEAE/" \
            2>/dev/null | grep -E "00000(035|036|037)" || {
            log_warn "Could not list S3 files. Possible reasons:"
            echo "    - AWS CLI not configured"
            echo "    - No S3 credentials"
            echo "    - Different S3 path"
            echo "    - Bucket/prefix doesn't exist"
            echo ""
            echo "  To check manually:"
            echo "    aws s3 ls s3://$S3_BUCKET/$S3_PREFIX/wals/000000090000CEAE/"
        }

        echo ""
        log_info "What to look for:"
        echo "  ✓ 000000090000CEAE00000035.gz - EXISTS"
        echo "  ✗ 000000090000CEAE00000036.gz - MISSING ← Data loss!"
        echo "  ✓ 000000090000CEAE00000037.gz - EXISTS"
        echo ""
        echo "  If 35 and 37 exist but 36 is missing → 16MB of writes are lost"
        echo "  If multiple files are missing → larger data loss"
    else
        log_warn "AWS CLI not found. Cannot check S3."
        echo "  Install AWS CLI and run:"
        echo "    aws s3 ls s3://$S3_BUCKET/$S3_PREFIX/wals/000000090000CEAE/ | grep -C 3 00000036"
    fi
}

# Check 5: Logical Replication Status
check_logical_replication() {
    log_section "CHECK 5: Logical Replication Slots"

    log_info "Checking replication slots on current primary..."

    kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -c "
SELECT
    slot_name,
    slot_type,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag_from_current
FROM pg_replication_slots
ORDER BY slot_type, slot_name;
" 2>/dev/null || log_error "Could not query replication slots"

    echo ""
    log_critical "IMPORTANT: This shows slots on paradedb-15 (subscriber)."
    log_critical "The slot on AURORA (publisher) is what matters for data loss assessment."
    echo ""
    log_info "You need to check Aurora's replication slot:"
    echo "  1. Connect to Aurora"
    echo "  2. Run:"
    echo "     SELECT slot_name, restart_lsn, confirmed_flush_lsn,"
    echo "            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag"
    echo "     FROM pg_replication_slots"
    echo "     WHERE slot_name = '<your_paradedb_slot_name>';"
    echo ""
    echo "  3. Compare Aurora's confirmed_flush_lsn with paradedb-15's current LSN"
    echo "  4. If Aurora's LSN > paradedb-15's LSN → data loss confirmed"
}

# Check 6: Synchronous Replication Configuration
check_sync_replication_config() {
    log_section "CHECK 6: Synchronous Replication Configuration"

    log_info "Checking if synchronous replication was enabled..."

    SYNC_COMMIT=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -t -c "SHOW synchronous_commit;" 2>/dev/null | tr -d ' ')

    SYNC_STANDBY=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
        psql -U postgres -t -c "SHOW synchronous_standby_names;" 2>/dev/null | tr -d ' ')

    echo "  synchronous_commit: $SYNC_COMMIT"
    echo "  synchronous_standby_names: $SYNC_STANDBY"
    echo ""

    if [ "$SYNC_COMMIT" == "on" ] && [ "$SYNC_STANDBY" != "" ]; then
        log_info "Synchronous replication IS enabled."
        echo "  This means paradedb-15 should have had all committed writes."
        echo "  Data loss is less likely (but still possible if failover was forced)."
    else
        log_warn "Synchronous replication is NOT enabled."
        echo "  This means paradedb-16 could commit without waiting for paradedb-15."
        echo "  Data loss is MORE LIKELY during forced failover."
    fi
}

# Summary
generate_summary() {
    log_section "SUMMARY & RECOMMENDATIONS"

    echo "Based on the checks above, assess your data loss risk:"
    echo ""

    log_critical "HIGH RISK INDICATORS:"
    echo "  ✗ archive_mode = off"
    echo "  ✗ failed_count > 0 in pg_stat_archiver"
    echo "  ✗ last_failed_time during incident window (~7:00-9:00 UTC)"
    echo "  ✗ Missing WAL files in S3 (000000090000CEAE00000036)"
    echo "  ✗ synchronous_standby_names = '' (not set)"
    echo "  ✗ Aurora's confirmed_flush_lsn > paradedb-15's current LSN"
    echo ""

    log_info "MEDIUM RISK INDICATORS:"
    echo "  ⚠ Only 1-2 WAL files missing"
    echo "  ⚠ Last archive was < 5 minutes before failover"
    echo "  ⚠ Small LSN difference between Aurora and paradedb-15"
    echo ""

    log_info "LOW RISK INDICATORS:"
    echo "  ✓ archive_mode = on with no failures"
    echo "  ✓ All WAL files present in S3"
    echo "  ✓ synchronous_standby_names was set"
    echo "  ✓ Aurora LSN ≈ paradedb-15 LSN"
    echo ""

    log_section "NEXT STEPS"

    echo "1. If HIGH RISK → You likely have data loss"
    echo "   - Quantify the gap (check Aurora slot vs paradedb-15 LSN)"
    echo "   - Decide if acceptable or need full rebuild from Aurora"
    echo ""

    echo "2. If MEDIUM RISK → Possible data loss"
    echo "   - Check application logs for missing data"
    echo "   - Verify critical transactions"
    echo "   - May be acceptable depending on business requirements"
    echo ""

    echo "3. If LOW RISK → Minimal/no data loss"
    echo "   - Proceed with fast recovery (Option 2)"
    echo "   - Still verify no data anomalies"
    echo ""

    log_warn "The most important check you haven't done yet:"
    echo "  → Compare Aurora's replication slot LSN with paradedb-15's current LSN"
    echo "  → This will definitively tell you if data was lost"
}

# Main execution
main() {
    log_section "MT US001 Data Loss Assessment"
    echo "This script checks if forced failover caused data loss"
    echo "due to incomplete WAL archiving."
    echo ""
    log_info "Target: $NAMESPACE/$PRIMARY_POD"
    echo ""

    check_wal_archiving_config || true
    echo ""

    check_wal_archiving_status
    echo ""

    check_wal_position
    echo ""

    check_s3_wal_files
    echo ""

    check_logical_replication
    echo ""

    check_sync_replication_config
    echo ""

    generate_summary

    log_info "Assessment complete."
    echo ""
    log_critical "CRITICAL: Check Aurora's replication slot position!"
    echo "  This is the definitive test for data loss."
}

# Run main function
main
