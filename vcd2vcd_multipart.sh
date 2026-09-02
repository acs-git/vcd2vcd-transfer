#!/bin/bash
#
# VCD -> VCD vApp Template Migration  v23
# Source : lvn-cm3-vcd2.broadcom.com            / Ascend-Base-Catalog
# Target : vcd-acs-vedp-ldn.ascendcloudsolutions.com / ocvs_ldn_iso_preprod
#
# DOWNLOAD STRATEGY (Phase 1):
#   Downloads the template as a native OVF bundle — not a single OVA blob.
#   1. POST enableDownload on the vAppTemplate to activate download links.
#   2. Re-GET vAppTemplate; use rel="download:default" (OVF bundle) href.
#   3. GET the OVF descriptor; parse every <File> reference element to build
#      the file list (name + expected size from ovf:size attribute).
#   4. For each file in the file list:
#        a. Download in sequential chunks (Range-GET) into a temp chunk dir.
#        b. Reassemble chunks → final file on disk.
#        c. On any chunk failure: retry up to UPLOAD_RETRY_MAX times before aborting.
#   Each file gets its own sentinel so partial downloads resume cleanly.
#
# STAGING LAYOUT:
#   $STAGING_DIR/<template>/          ← bundle directory
#     descriptor.ovf                  ← OVF descriptor

#     disk-0.vmdk, disk-1.vmdk …     ← raw VMDK / nvram files
#
# UPLOAD STRATEGY (Phase 3):
#   OVF bundle upload via VCD REST API — destination does not accept OVA.
#   1. POST UploadVAppTemplateParams → VCD returns a vAppTemplate with a
#      descriptor.ovf transfer href.
#   2. PUT descriptor.ovf to that href; VCD parses it and generates per-file
#      transfer hrefs for every VMDK / nvram.
#   3. Re-GET vAppTemplate; parse all <File> entries: name + size + transfer href.
#   4. For each file: PUT the staged file in sequential CHUNK_SIZE_MB chunks
#      using Content-Range headers (VCD requires strict offset ordering).
#      After every file upload verify VCD's bytesTransferred == size.
#      On mismatch: retry the upload up to UPLOAD_RETRY_MAX times.
#      UL_PARALLEL_JOBS files upload concurrently.
#
# PARALLELISM:
#   DL_PARALLEL_JOBS  — concurrent Range-GET chunks per file during download (default 8)
#   UL_PARALLEL_JOBS  — concurrent file uploads during OVF bundle upload     (default 8)
#   CHUNK_SIZE_MB     — chunk size for both download and upload               (default 256)
#
# TOKEN REFRESH:
#   Background daemon re-authenticates both VCDs every 45 min.
#   Tokens written to temp files; all chunk subshells read the latest.
#
# RESUME:
#   Each file has a per-file sentinel. Phase sentinels gate each phase.
#   Re-running the script skips completed files and phases automatically.
#

set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────
timestamp()  { date '+%Y-%m-%d %H:%M:%S'; }
log() {
    local msg; msg="$(timestamp) $*"
    if [ -f "${_PROGRESS_LOG_QUIET:-/nonexistent}" ] 2>/dev/null; then
        echo "$msg" >> "${_PROGRESS_LOG_QUIET}.buf"
    else
        echo "$msg"
    fi
}
log_phase()  { echo ""; echo "$(timestamp) ══════ $* ══════"; echo ""; }
die()        { echo ""; echo "ERROR: $*" >&2; exit 1; }

_progress_quiet_start() { touch "${_PROGRESS_LOG_QUIET}"; }
_progress_quiet_stop()  {
    rm -f "${_PROGRESS_LOG_QUIET}"
    if [ -s "${_PROGRESS_LOG_QUIET}.buf" ]; then
        cat "${_PROGRESS_LOG_QUIET}.buf"
        rm -f "${_PROGRESS_LOG_QUIET}.buf"
    fi
}

START_TIME=$(date +%s)

# ─── Load env ─────────────────────────────────────────────────────────────────
ENV_FILE="/home/ubuntu/scripts/.vcd2vcd_multipart.env"
[ -f "$ENV_FILE" ] || die "Cannot find $ENV_FILE"
source "$ENV_FILE"

# ─── Arguments ────────────────────────────────────────────────────────────────
[ -z "${1:-}" ] && die "Usage: $0 <vapp-template-name>"
VAPP_TEMPLATE="$1"
VCD_TEMPLATE="${VAPP_TEMPLATE%.ova}"

# ─── Env defaults (all overridable via .env) ──────────────────────────────────
SRC_VCD_HOST="${SRC_VCD_HOST:-lvn-cm3-vcd2.broadcom.com}"
SRC_VCD_ORG="${SRC_VCD_ORG:-lvn3-vcd2-eduprod-r}"
SRC_VCD_CATALOG="${SRC_VCD_CATALOG:-Ascend-Base-Catalog}"
SRC_VCD_USERNAME="${SRC_VCD_USERNAME:-check1}"
SRC_VCD_PASSWORD="${SRC_VCD_PASSWORD:-VMware123!}"

DST_VCD_HOST="${DST_VCD_HOST:-vcd-acs-vedp-ldn.ascendcloudsolutions.com}"
DST_VCD_ORG="${DST_VCD_ORG:-vsan-prd-01-wkld}"
DST_VCD_CATALOG="${DST_VCD_CATALOG:-ocvs_ldn_iso_preprod}"
DST_VCD_USERNAME="${DST_VCD_USERNAME:-template_manager}"
DST_VCD_PASSWORD="${DST_VCD_PASSWORD:-Acs123}"
VCD_API_VERSION="${VCD_API_VERSION:-39.1}"

STAGING_DIR="${STAGING_DIR:-/staging}"
LOG_DIR="${LOG_DIR:-${STAGING_DIR}/logs}"
mkdir -p "$LOG_DIR"

# ── OVF bundle staging directory ──────────────────────────────────────────────
# All downloaded files (descriptor.ovf, VMDKs) land here.
OVF_BUNDLE_DIR="${STAGING_DIR}/${VCD_TEMPLATE}"
OVF_DESCRIPTOR="${OVF_BUNDLE_DIR}/descriptor.ovf"

CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-256}"
DL_PARALLEL_JOBS="${DL_PARALLEL_JOBS:-8}"
DL_FILE_PARALLEL_JOBS="${DL_FILE_PARALLEL_JOBS:-5}"
UL_PARALLEL_JOBS="${UL_PARALLEL_JOBS:-8}"
UPLOAD_RETRY_MAX="${UPLOAD_RETRY_MAX:-5}"
UPLOAD_RETRY_DELAY="${UPLOAD_RETRY_DELAY:-30}"
REMOTE_STAGING="${REMOTE_STAGING:-}"
RSYNC_BW_LIMIT="${RSYNC_BW_LIMIT:-0}"

CHUNK_BYTES=$(( CHUNK_SIZE_MB * 1024 * 1024 ))

# ─── Dependency check ─────────────────────────────────────────────────────────
for cmd in curl rsync numfmt dd stat; do
    command -v "$cmd" &>/dev/null || die "'${cmd}' not found — please install it."
done

# ─── Exclusive lock — prevent concurrent runs for the same template ───────────
LOCK_FILE="${STAGING_DIR}/${VCD_TEMPLATE}.lock"
exec 200>"${LOCK_FILE}"
flock -n 200 || die "Another instance is already running for '${VCD_TEMPLATE}'. Remove ${LOCK_FILE} if stale."

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    VCD → VCD Template Migration  v23 (OVF bundle, no OVA)   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Template      : %-44s║\n" "$VCD_TEMPLATE"
printf "║  Source VCD    : %-44s║\n" "$SRC_VCD_HOST"
printf "║  Source Catalog: %-44s║\n" "$SRC_VCD_CATALOG"
printf "║  Target VCD    : %-44s║\n" "$DST_VCD_HOST"
printf "║  Target Catalog: %-44s║\n" "$DST_VCD_CATALOG"
printf "║  Bundle dir    : %-44s║\n" "$OVF_BUNDLE_DIR"
printf "║  Chunk size    : %-44s║\n" "${CHUNK_SIZE_MB} MB"
printf "║  DL files      : %-44s║\n" "${DL_FILE_PARALLEL_JOBS} files x ${DL_PARALLEL_JOBS} chunks/file"
printf "║  UL parallel   : %-44s║\n" "$UL_PARALLEL_JOBS"
printf "║  API version   : %-44s║\n" "$VCD_API_VERSION"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

log "SRC_VCD_HOST         = $SRC_VCD_HOST"
log "DST_VCD_HOST         = $DST_VCD_HOST"
log "DST Password Len     = ${#DST_VCD_PASSWORD}"
log "CHUNK_SIZE_MB        = $CHUNK_SIZE_MB"
log "DL_PARALLEL_JOBS     = $DL_PARALLEL_JOBS"
log "DL_FILE_PARALLEL_JOBS = $DL_FILE_PARALLEL_JOBS"
log "UL_PARALLEL_JOBS     = $UL_PARALLEL_JOBS"
log "UPLOAD_RETRY_MAX     = $UPLOAD_RETRY_MAX"
log "UPLOAD_RETRY_DELAY   = $UPLOAD_RETRY_DELAY"

log "Checking available staging space on ${STAGING_DIR}"
df -h "${STAGING_DIR}"


# ═════════════════════════════════════════════════════════════════════════════
# TOKEN FILES — written at auth, refreshed every 45 min by background daemon.
# Every chunk subshell reads the file at launch time so it always gets the
# latest token even after a mid-transfer refresh.
# ═════════════════════════════════════════════════════════════════════════════
SRC_TOKEN_FILE=$(mktemp /tmp/vcd_src_token_XXXXXX.txt)
DST_TOKEN_FILE=$(mktemp /tmp/vcd_dst_token_XXXXXX.txt)
# Quiet-mode sentinel: when this file exists, log() buffers to file instead of terminal.
# Defined here so token_refresh_daemon (started below) inherits the path.
_PROGRESS_LOG_QUIET="${LOG_DIR}/.progress_quiet_$$"

cleanup() {
    log "Cleaning up temp files and background jobs …"
    kill -- -$$ 2>/dev/null || kill 0 2>/dev/null || true
    rm -f "${SRC_TOKEN_FILE}" "${DST_TOKEN_FILE}" \
          "${_PROGRESS_LOG_QUIET}" "${_PROGRESS_LOG_QUIET}.buf" 2>/dev/null || true
}
trap cleanup EXIT


# ─── Auth helpers ─────────────────────────────────────────────────────────────
_auth_src() {
    local hdr
    hdr=$(mktemp /tmp/vcd_src_refresh_XXXXXX.txt)
    curl --silent --show-error --fail --insecure \
        -D "${hdr}" -X POST \
        -u "${SRC_VCD_USERNAME}@${SRC_VCD_ORG}:${SRC_VCD_PASSWORD}" \
        -H "Accept: application/json;version=${VCD_API_VERSION}" \
        "https://${SRC_VCD_HOST}/cloudapi/1.0.0/sessions" -o /dev/null
    local tok
    tok=$(grep -i '^X-VMWARE-VCLOUD-ACCESS-TOKEN:' "${hdr}" | awk '{print $2}' | tr -d '\r\n')
    rm -f "$hdr"
    [ -z "$tok" ] && { log "WARNING: Source token refresh failed!"; return 1; }
    echo "$tok" > "${SRC_TOKEN_FILE}"
    log "[token] Source token refreshed (len=${#tok})."
}

_auth_dst() {
    local hdr
    hdr=$(mktemp /tmp/vcd_dst_refresh_XXXXXX.txt)
    curl --silent --show-error --fail --insecure \
        -D "${hdr}" -X POST \
        -u "${DST_VCD_USERNAME}@${DST_VCD_ORG}:${DST_VCD_PASSWORD}" \
        -H "Accept: application/json;version=${VCD_API_VERSION}" \
        "https://${DST_VCD_HOST}/cloudapi/1.0.0/sessions" -o /dev/null
    local tok
    tok=$(grep -i '^X-VMWARE-VCLOUD-ACCESS-TOKEN:' "${hdr}" | awk '{print $2}' | tr -d '\r\n')
    rm -f "$hdr"
    [ -z "$tok" ] && { log "WARNING: Dest token refresh failed!"; return 1; }
    echo "$tok" > "${DST_TOKEN_FILE}"
    log "[token] Dest token refreshed (len=${#tok})."
}

# ─── curl wrappers (always read token from file) ──────────────────────────────
_src_vcd() {
    local tok; tok=$(cat "${SRC_TOKEN_FILE}")
    curl --silent --show-error --fail --insecure \
         -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
         -H "Authorization: Bearer ${tok}" "$@"
}

_dst_vcd() {
    local tok; tok=$(cat "${DST_TOKEN_FILE}")
    curl --silent --show-error --fail --insecure \
         -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
         -H "Authorization: Bearer ${tok}" "$@"
}

# ─── Retry helper ─────────────────────────────────────────────────────────────
_retry_chunk() {
    local attempt=1 delay="$UPLOAD_RETRY_DELAY" rc
    while [ "$attempt" -le "$UPLOAD_RETRY_MAX" ]; do
        rc=0
        "$@" || rc=$?
        [ "$rc" -eq 0 ] && return 0
        log "  Chunk attempt ${attempt}/${UPLOAD_RETRY_MAX} failed (rc=${rc}). Waiting ${delay}s …"
        sleep "$delay"
        delay=$(( delay * 2 ))
        attempt=$(( attempt + 1 ))
    done
    return 1
}

# ─── PID throttle drain ───────────────────────────────────────────────────────
_drain_to_limit() {
    local max_jobs="$1"
    local arr_name="${2:-chunk_pids}"
    local failed=0
    local -n _pids_ref="$arr_name"

    # Sliding-window drain: reap exactly ONE completed pid per call so the
    # outer loop queues exactly one replacement.  Sweeping all completed pids
    # at once causes the "start N → wait for all N → start next N" batch effect
    # when multiple small files finish within the same poll window.
    while [ "${#_pids_ref[@]}" -ge "$max_jobs" ]; do
        local found=0
        local i
        for (( i = 0; i < ${#_pids_ref[@]}; i++ )); do
            local pid="${_pids_ref[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                local wrc=0
                wait "$pid" 2>/dev/null; wrc=$?
                # wrc=127 means already reaped (race / grandchild edge-case) — not a failure
                if [ "$wrc" -ne 0 ] && [ "$wrc" -ne 127 ]; then
                    failed=1
                fi
                # Remove exactly this one element, then break so the outer loop
                # can queue one replacement immediately.
                _pids_ref=( "${_pids_ref[@]:0:$i}" "${_pids_ref[@]:$(( i + 1 ))}" )
                found=1
                break
            fi
        done
        [ "$found" -eq 0 ] && sleep 0.2
    done
    return "$failed"
}

# ─── Download file-level slot drain ──────────────────────────────────────────
# Like _drain_to_limit but also tracks the parallel dl_file_slots array so we
# know exactly which display slot just freed up.  Sets _DL_FREED_SLOT.
# Returns 1 if the reaped job exited non-zero.
_DL_FREED_SLOT=0
_drain_dl_files() {
    local failed=0
    while [ "${#dl_file_pids[@]}" -ge "$DL_FILE_PARALLEL_JOBS" ]; do
        local found=0 i
        for (( i = 0; i < ${#dl_file_pids[@]}; i++ )); do
            local pid="${dl_file_pids[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                local wrc=0
                wait "$pid" 2>/dev/null; wrc=$?
                [ "$wrc" -ne 0 ] && [ "$wrc" -ne 127 ] && failed=1
                _DL_FREED_SLOT="${dl_file_slots[$i]}"
                dl_file_pids=(  "${dl_file_pids[@]:0:$i}"  "${dl_file_pids[@]:$(( i + 1 ))}" )
                dl_file_slots=( "${dl_file_slots[@]:0:$i}" "${dl_file_slots[@]:$(( i + 1 ))}" )
                found=1
                break
            fi
        done
        [ "$found" -eq 0 ] && sleep 0.2
    done
    return "$failed"
}

# ─── Helper: extract href for a specific rel= from VCD XML ───────────────────
_extract_link_href() {
    local rel_val="$1" xml="$2"
    echo "$xml" \
        | tr '\n' ' ' \
        | grep -oP '<Link[^>]+>' \
        | grep "rel=\"${rel_val}\"" \
        | grep -oP '(?<=href=")[^"]+' \
        | head -1 || true
}

# ─── Helper: resolve file size via HEAD + Range probe ─────────────────────────
_resolve_file_size() {
    local url="$1" token_file="$2"
    local sz=""

    sz=$(curl --silent --insecure --head --fail --location \
        -H "Authorization: Bearer $(cat "${token_file}")" \
        -H "Accept: application/octet-stream" \
        "${url}" \
        | grep -i '^content-length:' | tail -1 \
        | awk '{print $2}' | tr -d '\r\n' || true)

    if [ -z "$sz" ] || ! [[ "$sz" =~ ^[0-9]+$ ]] || [ "$sz" -eq 0 ]; then
        sz=$(curl --silent --insecure --fail \
            -H "Authorization: Bearer $(cat "${token_file}")" \
            -H "Accept: application/octet-stream" \
            -H "Range: bytes=0-0" \
            -D - "${url}" -o /dev/null \
            | grep -i '^content-range:' \
            | grep -oP '(?<=/)\d+' | tr -d '\r\n' || true)
    fi

    echo "${sz:-0}"
}

# ─── Helper: live progress bar + speed for one file download ──────────────────
# Usage: _progress_daemon <f_name> <f_size> <chunk_dir> <start_epoch_ns>
# Runs in the background; killed by the caller when the download finishes.
# Writes to stderr so it doesn't pollute stdout/log files.
# Output format (single \r-updated line):
#   [file.vmdk]  [████████░░░░░░░░]  45%   4.53 GiB / 10.1 GiB  @ 312 MiB/s  ETA 18s
_progress_daemon() {
    local f_name="$1" f_size="$2" chunk_dir="$3" start_ns="$4"
    local bar_width=20

    # Emit a blank line so the first \r doesn't clobber a log line
    printf '\n' >&2

    while true; do
        sleep 1

        # Sum sizes of all chunk files written so far
        local done_bytes=0
        if [ -d "$chunk_dir" ]; then
            done_bytes=$(find "$chunk_dir" -name 'chunk_*' -printf '%s\n' 2>/dev/null \
                         | awk '{s+=$1} END{print s+0}')
        fi

        local now_ns elapsed_s speed_bps eta_s
        now_ns=$(date +%s%N)
        elapsed_s=$(( (now_ns - start_ns) / 1000000000 ))
        [ "$elapsed_s" -lt 1 ] && elapsed_s=1

        speed_bps=$(( done_bytes / elapsed_s ))

        local pct=0
        [ "$f_size" -gt 0 ] && pct=$(( done_bytes * 100 / f_size ))
        [ "$pct" -gt 100 ] && pct=100

        # ETA
        if [ "$speed_bps" -gt 0 ] && [ "$done_bytes" -lt "$f_size" ]; then
            eta_s=$(( (f_size - done_bytes) / speed_bps ))
        else
            eta_s=0
        fi

        # Bar
        local filled=$(( pct * bar_width / 100 ))
        local empty=$(( bar_width - filled ))
        local bar=""
        local i
        for (( i=0; i<filled; i++ )); do bar="${bar}█"; done
        for (( i=0; i<empty;  i++ )); do bar="${bar}░"; done

        # Human-readable sizes and speed
        local done_h total_h speed_h
        done_h=$(numfmt --to=iec-i --suffix=B "$done_bytes"  2>/dev/null || echo "${done_bytes}B")
        total_h=$(numfmt --to=iec-i --suffix=B "$f_size"     2>/dev/null || echo "${f_size}B")
        speed_h=$(numfmt --to=iec-i --suffix=B/s "$speed_bps" 2>/dev/null || echo "${speed_bps}B/s")

        # ETA string
        local eta_str
        if [ "$pct" -ge 100 ]; then
            eta_str="done"
        elif [ "$eta_s" -ge 3600 ]; then
            eta_str="$(( eta_s/3600 ))h $(( (eta_s%3600)/60 ))m"
        elif [ "$eta_s" -ge 60 ]; then
            eta_str="$(( eta_s/60 ))m $(( eta_s%60 ))s"
        else
            eta_str="${eta_s}s"
        fi

        # Truncate filename to 20 chars for display
        local short_name="${f_name}"
        [ "${#short_name}" -gt 22 ] && short_name="…${short_name: -21}"

        printf '\r  %-22s [%s] %3d%%  %s / %s  @ %-12s  ETA %-8s' \
            "${short_name}" "${bar}" "${pct}" \
            "${done_h}" "${total_h}" "${speed_h}" "${eta_str}" >&2
    done
}

# ─── Multi-file progress daemon (parallel file downloads) ────────────────────
# Mirrors the upload _progress_monitor style exactly:
#   Line 1 : [DOWNLOAD] overall bar  pct%  done/total  (N/M done)  @ speed  ETA
#   Line 2 : separator ─────────────
#   Lines 3+: per-slot row  filename  status-label  [bar]  pct%  done/total
#
# Usage: _multifile_progress_daemon <n_slots> <total_bytes> <start_epoch_ns>
#                                   <state_dir> <done_bytes_file>
#
# State files: <state_dir>/sNN  (written by the download subshell, one per slot)
#   Single-line format:  fname|fsize|chunk_dir|done_flag
#     done_flag: 0=active  1=complete  2=failed
_multifile_progress_daemon() {
    local n_slots="$1" total_size="$2" start_ns="$3"
    local state_dir="$4" done_file="$5"
    local overall_bar_width=60
    local file_bar_width=28
    local fw=40            # filename column width
    local display_lines=$(( n_slots + 2 ))   # overall + separator + n_slots rows

    # Reserve vertical space on stderr; redraws overwrite this block in-place
    local _r; for (( _r=0; _r<display_lines; _r++ )); do printf '\n' >&2; done

    while true; do
        sleep 1
        printf '\033[%dA' "$display_lines" >&2    # cursor back to top of block

        # ── Grand total from finished files ───────────────────────────────────
        local grand_done=0
        if [ -f "$done_file" ]; then
            grand_done=$(awk '{s+=$1} END{print s+0}' "$done_file" 2>/dev/null || echo 0)
            [[ "$grand_done" =~ ^[0-9]+$ ]] || grand_done=0
        fi
        local active_bytes=0
        local done_count=0 total_known=0

        # ── Per-slot state (first pass: collect active_bytes + counts) ────────
        local slot
        local -a _fname _fsize _cdir _dflag _fdone
        for (( slot=1; slot<=n_slots; slot++ )); do
            _fname[$slot]="" _fsize[$slot]=0 _cdir[$slot]="" _dflag[$slot]=-1 _fdone[$slot]=0
            local sf="${state_dir}/$(printf 's%02d' "$slot")"
            if [ -f "$sf" ]; then
                IFS='|' read -r _fname[$slot] _fsize[$slot] _cdir[$slot] _dflag[$slot] \
                    < "$sf" 2>/dev/null || true
                [[ "${_fsize[$slot]}" =~ ^[0-9]+$ ]] || _fsize[$slot]=0
                [[ "${_dflag[$slot]}" =~ ^[0-9]+$ ]] || _dflag[$slot]=0
                total_known=$(( total_known + 1 ))
                if [ "${_dflag[$slot]}" -eq 1 ]; then
                    done_count=$(( done_count + 1 ))
                elif [ "${_dflag[$slot]}" -eq 0 ]; then
                    local _fb=0
                    local _cd="${_cdir[$slot]}"
                    if [ -n "$_cd" ] && [ -d "$_cd" ]; then
                        _fb=$(find "$_cd" -name 'chunk_*' -printf '%s\n' 2>/dev/null \
                              | awk '{s+=$1} END{print s+0}')
                        [[ "$_fb" =~ ^[0-9]+$ ]] || _fb=0
                    fi
                    _fdone[$slot]="$_fb"
                    active_bytes=$(( active_bytes + _fb ))
                fi
            fi
        done

        # ── Overall bar ───────────────────────────────────────────────────────
        local overall=$(( grand_done + active_bytes ))
        local opct=0
        [ "$total_size" -gt 0 ] && opct=$(( overall * 100 / total_size ))
        [ "$opct" -gt 100 ] && opct=100
        local ofilled=$(( opct * overall_bar_width / 100 ))
        local oempty=$(( overall_bar_width - ofilled ))

        local now_ns elapsed_s speed_bps eta_s
        now_ns=$(date +%s%N)
        elapsed_s=$(( (now_ns - start_ns) / 1000000000 ))
        [ "$elapsed_s" -lt 1 ] && elapsed_s=1
        speed_bps=$(( overall / elapsed_s ))
        eta_s=0
        [ "$speed_bps" -gt 0 ] && [ "$overall" -lt "$total_size" ] && \
            eta_s=$(( (total_size - overall) / speed_bps ))

        local done_h total_h speed_h
        done_h=$(numfmt --to=iec-i --suffix=B "$overall"     2>/dev/null || echo "${overall}B")
        total_h=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B")
        speed_h=$(numfmt --to=iec-i --suffix=B/s "$speed_bps" 2>/dev/null || echo "${speed_bps}B/s")

        local eta_str
        if   [ "$opct" -ge 100 ];   then eta_str="done"
        elif [ "$eta_s" -ge 3600 ]; then eta_str="$(( eta_s/3600 ))h$(( (eta_s%3600)/60 ))m"
        elif [ "$eta_s" -ge 60 ];   then eta_str="$(( eta_s/60 ))m$(( eta_s%60 ))s"
        else                             eta_str="${eta_s}s"
        fi

        printf '\033[2K\r' >&2
        printf '\033[1;36m[DOWNLOAD]\033[0m [' >&2
        local _j
        for (( _j=0; _j<ofilled; _j++ )); do printf '█' >&2; done
        for (( _j=0; _j<oempty;  _j++ )); do printf '░' >&2; done
        printf '] \033[1m%3d%%\033[0m  %s / %s  \033[33m(%d/%d done)\033[0m  @ %s  ETA %s\n' \
            "$opct" "$done_h" "$total_h" "$done_count" "$total_known" "$speed_h" "$eta_str" >&2

        # ── Separator ─────────────────────────────────────────────────────────
        printf '\033[2K\r\033[90m' >&2
        for (( _j=0; _j<$(( overall_bar_width + 40 )); _j++ )); do printf '─' >&2; done
        printf '\033[0m\n' >&2

        # ── Per-slot rows ─────────────────────────────────────────────────────
        for (( slot=1; slot<=n_slots; slot++ )); do
            printf '\033[2K\r' >&2

            if [ "${_dflag[$slot]}" -eq -1 ]; then
                printf '  %-*s \033[90m… waiting  \033[0m\033[90m[' "$fw" "—" >&2
                for (( _j=0; _j<file_bar_width; _j++ )); do printf '·' >&2; done
                printf ']\033[0m   0%%\n' >&2
                continue
            fi

            local fn="${_fname[$slot]}"
            local fsz="${_fsize[$slot]}"
            local dfl="${_dflag[$slot]}"
            local fb="${_fdone[$slot]:-0}"

            local display_name="$fn"
            [ "${#fn}" -gt "$fw" ] && display_name="…${fn: -$(( fw - 1 ))}"

            local fpct=0
            [ "$fsz" -gt 0 ] && fpct=$(( fb * 100 / fsz ))
            [ "$fpct" -gt 100 ] && fpct=100
            local ffilled=$(( fpct * file_bar_width / 100 ))
            local fempty=$(( file_bar_width - ffilled ))

            local fdone_h fsz_h
            fdone_h=$(numfmt --to=iec-i --suffix=B "$fb"  2>/dev/null || echo "${fb}B")
            fsz_h=$(numfmt --to=iec-i   --suffix=B "$fsz" 2>/dev/null || echo "${fsz}B")

            case "$dfl" in
            1)  # completed — green full bar
                printf '  \033[32m%-*s ✔ done    \033[0m\033[32m[' "$fw" "$display_name" >&2
                for (( _j=0; _j<file_bar_width; _j++ )); do printf '█' >&2; done
                printf ']\033[0m 100%%  %s\n' "$fsz_h" >&2
                ;;
            2)  # failed — red empty bar
                printf '  \033[31m%-*s ✖ failed  \033[0m\033[31m[' "$fw" "$display_name" >&2
                for (( _j=0; _j<file_bar_width; _j++ )); do printf '░' >&2; done
                printf ']\033[0m  FAIL\n' >&2
                ;;
            *)  # active — cyan inflight bar
                printf '  \033[36m%-*s ↓ download\033[0m [' "$fw" "$display_name" >&2
                for (( _j=0; _j<ffilled; _j++ )); do printf '▓' >&2; done
                for (( _j=0; _j<fempty;  _j++ )); do printf '·' >&2; done
                printf '] %3d%%  %s / %s\n' "$fpct" "$fdone_h" "$fsz_h" >&2
                ;;
            esac
        done
    done
}

# ─── Helper: download one file in chunks with retry ──────────────────────────
# Usage: _download_file_with_checksum <name> <url> <dest_path> [chunk_dir_path]
# Optional 4th arg: caller-supplied chunk dir path (used by parallel mode so the
# progress daemon knows where to scan).  If omitted, mktemp creates a random dir.
# Returns 0 on success, 1 on permanent failure.
_download_file_with_checksum() {
    local f_name="$1" f_url="$2" f_dest="$3" f_chunk_dir_hint="${4:-}"
    local attempt=1 delay="$UPLOAD_RETRY_DELAY"

    while [ "$attempt" -le "$UPLOAD_RETRY_MAX" ]; do
        log "  [DL attempt ${attempt}/${UPLOAD_RETRY_MAX}] ${f_name} …"

        # ── Resolve size ──────────────────────────────────────────────────────
        local f_size
        f_size=$(_resolve_file_size "${f_url}" "${SRC_TOKEN_FILE}")
        if [ -z "$f_size" ] || ! [[ "$f_size" =~ ^[0-9]+$ ]] || [ "$f_size" -eq 0 ]; then
            log "  WARNING: Cannot determine size of ${f_name} — retrying in ${delay}s"
            sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 ))
            continue
        fi
        local f_size_h
        f_size_h=$(numfmt --to=iec-i --suffix=B "${f_size}" 2>/dev/null || echo "${f_size}B")
        log "    Size: ${f_size_h} (${f_size} bytes)"

        # ── Chunked download ──────────────────────────────────────────────────
        local chunk_dir
        if [ -n "$f_chunk_dir_hint" ]; then
            chunk_dir="$f_chunk_dir_hint"
            rm -rf "$chunk_dir"          # clear any partial chunks from a previous attempt
            mkdir -p "$chunk_dir"
        else
            chunk_dir=$(mktemp -d "${LOG_DIR}/.dl_chunks_XXXXXX")
        fi
        local dl_log="${LOG_DIR}/${VCD_TEMPLATE}_dl_${f_name//\//_}.chunklog"
        > "$dl_log"

        # ── Start progress bar daemon ─────────────────────────────────────────
        # Suppressed when DL_FILE_PARALLEL_JOBS>1 — the aggregate daemon handles display.
        local dl_start_ns progress_pid
        dl_start_ns=$(date +%s%N)
        progress_pid=0
        if [ "${DL_FILE_PARALLEL_JOBS:-1}" -le 1 ]; then
            _progress_daemon "${f_name}" "${f_size}" "${chunk_dir}" "${dl_start_ns}" &
            progress_pid=$!
        fi

        local chunk_pids=()
        local chunk_num=0
        local offset=0
        local failed_dl=0

        while [ "$offset" -lt "$f_size" ]; do
            local remaining=$(( f_size - offset ))
            local length=$(( remaining < CHUNK_BYTES ? remaining : CHUNK_BYTES ))
            local end=$(( offset + length - 1 ))
            local chunk_file="${chunk_dir}/chunk_$(printf '%08d' "$chunk_num")"

            if ! _drain_to_limit "$DL_PARALLEL_JOBS"; then
                tail -20 "${dl_log}" >&2
                rm -rf "${chunk_dir}"
                log "  ERROR: A chunk failed for ${f_name}."
                failed_dl=1
                break
            fi

            local c_offset="$offset" c_length="$length" c_end="$end"
            local c_file="$chunk_file" c_num="$chunk_num"
            local c_url="$f_url"

            (
                set +e
                local tok; tok=$(cat "${SRC_TOKEN_FILE}")

                _dl_chunk_attempt() {
                    local tmp_code
                    tmp_code=$(mktemp /tmp/vcd_dl_code_XXXXXX.txt)
                    curl --silent --show-error --insecure --location \
                        -H "Authorization: Bearer ${tok}" \
                        -H "Accept: application/octet-stream" \
                        -H "Range: bytes=${c_offset}-${c_end}" \
                        --write-out '%{http_code}' \
                        -o "${c_file}" \
                        "${c_url}" > "${tmp_code}" 2>>"${dl_log}" || true
                    local http_code
                    http_code=$(cat "${tmp_code}" 2>/dev/null || echo "000")
                    rm -f "${tmp_code}"

                    # 4xx may mean the token on the transfer URL expired — retry without auth
                    if [[ "${http_code}" == 4* ]]; then
                        echo "DL_RETRY_NO_AUTH chunk=${c_num} http=${http_code}" >> "${dl_log}"
                        rm -f "${c_file}"
                        local tmp_code2
                        tmp_code2=$(mktemp /tmp/vcd_dl_code_XXXXXX.txt)
                        curl --silent --show-error --insecure --location \
                            -H "Accept: application/octet-stream" \
                            -H "Range: bytes=${c_offset}-${c_end}" \
                            --write-out '%{http_code}' \
                            -o "${c_file}" \
                            "${c_url}" > "${tmp_code2}" 2>>"${dl_log}" || true
                        http_code=$(cat "${tmp_code2}" 2>/dev/null || echo "000")
                        rm -f "${tmp_code2}"
                    fi

                    if [ "${http_code}" != "206" ] && [ "${http_code}" != "200" ]; then
                        echo "DL_HTTP_ERR chunk=${c_num} http=${http_code} offset=${c_offset}" >> "${dl_log}"
                        rm -f "${c_file}"
                        return 1
                    fi

                    echo "DL_OK chunk=${c_num} bytes=${c_offset}-${c_end} size=${c_length}" >> "${dl_log}"
                    return 0
                }

                _retry_chunk _dl_chunk_attempt
                exit $?
            ) &
            chunk_pids+=($!)
            chunk_num=$(( chunk_num + 1 ))
            offset=$(( offset + length ))
        done

        # Wait for all chunks
        for pid in "${chunk_pids[@]+"${chunk_pids[@]}"}"; do
            if ! wait "$pid"; then failed_dl=1; fi
        done

        # ── Stop progress bar daemon ──────────────────────────────────────────
        if [ "$progress_pid" -ne 0 ]; then
            kill "$progress_pid" 2>/dev/null || true
            wait "$progress_pid" 2>/dev/null || true
            printf '\n' >&2
        fi

        if [ "$failed_dl" -ne 0 ]; then
            log "  ERROR: Chunk download failed for ${f_name}. See ${dl_log}"
            rm -rf "${chunk_dir}"
            sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 ))
            continue
        fi

        # ── Compute and log overall download speed ────────────────────────────
        local dl_end_ns dl_elapsed_s avg_speed_h
        dl_end_ns=$(date +%s%N)
        dl_elapsed_s=$(( (dl_end_ns - dl_start_ns) / 1000000000 ))
        [ "$dl_elapsed_s" -lt 1 ] && dl_elapsed_s=1
        local avg_speed_bps=$(( f_size / dl_elapsed_s ))
        avg_speed_h=$(numfmt --to=iec-i --suffix=B/s "$avg_speed_bps" 2>/dev/null || echo "${avg_speed_bps}B/s")

        # ── Reassemble chunks ─────────────────────────────────────────────────
        mkdir -p "$(dirname "${f_dest}")"
        log "    Reassembling ${chunk_num} chunk(s) → ${f_dest} …"
        find "${chunk_dir}" -name 'chunk_*' | sort | xargs cat > "${f_dest}"
        rm -rf "${chunk_dir}"

        log "  ✔ ${f_name} downloaded (${f_size_h} in ${dl_elapsed_s}s @ ${avg_speed_h})."
        return 0
    done

    log "  FATAL: ${f_name} failed after ${UPLOAD_RETRY_MAX} attempts."
    return 1
}


# ─── Initial authentication ───────────────────────────────────────────────────
log "Authenticating to source VCD (${SRC_VCD_HOST}) …"
_auth_src || die "Initial source authentication failed."

log "Authenticating to destination VCD (${DST_VCD_HOST}) …"
_auth_dst || die "Initial destination authentication failed."

# ─── Token refresh daemon ─────────────────────────────────────────────────────
token_refresh_daemon() {
    local interval=$(( 45 * 60 ))
    while true; do
        sleep "$interval"
        log "[token-refresh] Refreshing source token …"
        _auth_src || log "WARNING: source token refresh failed — will retry next cycle"
        log "[token-refresh] Refreshing destination token …"
        _auth_dst || log "WARNING: dest token refresh failed — will retry next cycle"
    done
}
token_refresh_daemon &
TOKEN_REFRESH_PID=$!
log "Token refresh daemon started (PID=${TOKEN_REFRESH_PID}, interval=45 min)."


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Download OVF bundle from Source VCD
#
# Strategy:
#   1. Query vAppTemplate by name → get its REST href.
#   2. POST enableDownload → VCD activates /transfer/ download links.
#   3. Re-GET vAppTemplate; use rel="download:default" href (OVF bundle).
#   4. GET the OVF descriptor from that base URL.
#   5. Parse <File> elements from the OVF to build the file list.
#   6. For each file: chunked Range-GET → reassemble → on fail, retry.
#
# SENTINEL: EXPORT_DONE is written only after all files are downloaded.
#   Per-file sentinels (<file>.dl_complete) allow resuming after interruption.
# ═════════════════════════════════════════════════════════════════════════════
log_phase "PHASE 1 — OVF bundle download from Source VCD (${SRC_VCD_HOST})"

EXPORT_DONE="${OVF_BUNDLE_DIR}/.bundle_download_complete"
if [ -f "$EXPORT_DONE" ]; then
    log "Download sentinel found — skipping Phase 1."
else
    mkdir -p "${OVF_BUNDLE_DIR}"

    # ── 1a. Find vAppTemplate ─────────────────────────────────────────────────
    log "Finding vApp template '${VCD_TEMPLATE}' in source catalog '${SRC_VCD_CATALOG}' …"
    SRC_TMPL_QUERY=$(_src_vcd \
        "https://${SRC_VCD_HOST}/api/query?type=vAppTemplate&filter=name==${VCD_TEMPLATE}")
    echo "$SRC_TMPL_QUERY" > "${LOG_DIR}/src_template_query.xml"

    # Filter results to the configured source catalog so that templates with the same
    # name in multiple catalogs don't cause the wrong one to be selected.
    SRC_TMPL_HREF=$(echo "$SRC_TMPL_QUERY" \
        | grep -oP '<VAppTemplateRecord[^>]+>' \
        | grep "catalogName=\"${SRC_VCD_CATALOG}\"" \
        | grep -oP 'href="https://[^"]+/api/vAppTemplate/[^"]+"' \
        | head -1 | grep -oP '(?<=href=")[^"]+')
    [ -z "$SRC_TMPL_HREF" ] && \
        die "Template '${VCD_TEMPLATE}' not found in source catalog '${SRC_VCD_CATALOG}'. See ${LOG_DIR}/src_template_query.xml"
    log "Source template HREF : ${SRC_TMPL_HREF}"

    # ── 1b. GET vAppTemplate detail; find enableDownload href ─────────────────
    SRC_TMPL_DETAIL=$(_src_vcd "${SRC_TMPL_HREF}")
    echo "$SRC_TMPL_DETAIL" > "${LOG_DIR}/src_template_detail.xml"

    ENABLE_DL_HREF=$(_extract_link_href "enable" "$SRC_TMPL_DETAIL")
    if [ -z "$ENABLE_DL_HREF" ]; then
        ENABLE_DL_HREF="${SRC_TMPL_HREF}/action/enableDownload"
        log "  rel=enable link not found — using constructed href: ${ENABLE_DL_HREF}"
    fi
    log "enableDownload HREF : ${ENABLE_DL_HREF}"

    # ── 1c. POST enableDownload ────────────────────────────────────────────────
    log "Calling enableDownload on vAppTemplate …"
    _src_vcd -X POST "${ENABLE_DL_HREF}" \
        -H "Content-Length: 0" \
        -o /dev/null 2>&1 || \
        log "WARNING: enableDownload returned non-zero (may already be enabled — continuing)."
    sleep 5

    # ── 1d. Re-GET vAppTemplate; extract OVF bundle download href ─────────────
    log "Re-fetching vAppTemplate to extract OVF bundle download link …"
    SRC_TMPL_DETAIL=$(_src_vcd "${SRC_TMPL_HREF}")
    echo "$SRC_TMPL_DETAIL" > "${LOG_DIR}/src_template_detail.xml"

    # Prefer download:identity (OVF with MAC addresses and VM UUIDs embedded by VCD)
    # over download:default (plain OVF without identity info).
    OVF_DESCRIPTOR_HREF=$(_extract_link_href "download:identity" "$SRC_TMPL_DETAIL")
    if [ -n "$OVF_DESCRIPTOR_HREF" ]; then
        log "  Using download:identity OVF descriptor (preserves MACs and UUIDs)."
    else
        log "  download:identity not found — falling back to download:default."
        OVF_DESCRIPTOR_HREF=$(_extract_link_href "download:default" "$SRC_TMPL_DETAIL")
    fi
    if [ -z "$OVF_DESCRIPTOR_HREF" ]; then
        log "  download:default not found — trying download:ovfDescriptor …"
        OVF_DESCRIPTOR_HREF=$(_extract_link_href "download:ovfDescriptor" "$SRC_TMPL_DETAIL")
    fi
    [ -z "$OVF_DESCRIPTOR_HREF" ] && \
        die "No OVF bundle download link found after enableDownload. See ${LOG_DIR}/src_template_detail.xml"
    log "OVF descriptor HREF : ${OVF_DESCRIPTOR_HREF}"

    # Derive the transfer base URL for VMDK downloads by stripping the filename
    OVF_BASE_URL="${OVF_DESCRIPTOR_HREF%/*}"

    # ── 1e. Download descriptor.ovf ────────────────────────────────────────────
    log "Downloading descriptor.ovf …"
    curl --silent --show-error --fail --insecure --location \
        -H "Authorization: Bearer $(cat "${SRC_TOKEN_FILE}")" \
        -H "Accept: application/octet-stream" \
        "${OVF_DESCRIPTOR_HREF}" \
        -o "${OVF_DESCRIPTOR}" || die "Failed to download descriptor.ovf"
    [ -s "${OVF_DESCRIPTOR}" ] || die "descriptor.ovf is empty."
    log "  ✔ descriptor.ovf ($(numfmt --to=iec-i --suffix=B "$(stat -c%s "${OVF_DESCRIPTOR}")"))"

    # ── 1f. Parse <File> references from OVF descriptor ───────────────────────
    # OVF File elements:  <File ovf:href="disk-0.vmdk" ovf:size="NNN" .../>
    log "Parsing file list from descriptor.ovf …"
    OVF_FILE_LIST=$(mktemp /tmp/vcd_ovf_files_XXXXXX.txt)

    # Extract name|size pairs; size attribute may be absent for the descriptor itself.
    # Handles both namespace-prefixed tags (<ovf:File .../>) and plain (<File .../>),
    # and both self-closing (/>) and open+close (<File ...></File>) forms.
    { grep -oP '<(?:ovf:)?File\b[^>]*/>' "${OVF_DESCRIPTOR}" \
      || grep -oP '<(?:ovf:)?File\b[^>]*>' "${OVF_DESCRIPTOR}" \
      || true; } \
        | awk '
            {
                href=""; fsize=""
                # ovf:href takes priority, fall back to plain href
                n = split($0, a, /ovf:href="/)
                if (n<2) n = split($0, a, /href="/)
                if (n>=2) { sub(/".*/, "", a[2]); href=a[2] }
                # ovf:size takes priority, fall back to plain size
                n = split($0, b, /ovf:size="/)
                if (n<2) n = split($0, b, /size="/)
                if (n>=2) { sub(/".*/, "", b[2]); fsize=b[2] }
                if (href != "") print href "|" fsize
            }
        ' > "${OVF_FILE_LIST}" || true

    OVF_FILE_COUNT=$(wc -l < "${OVF_FILE_LIST}")
    log "OVF references ${OVF_FILE_COUNT} file(s):"
    while IFS='|' read -r _fn _fs; do
        log "  ${_fn}  (size=${_fs:-unknown})"
    done < "${OVF_FILE_LIST}"

    [ "$OVF_FILE_COUNT" -eq 0 ] && die "No <File> references found in descriptor.ovf"

    # ── 1h. Download each referenced file ─────────────────────────────────────
    log "Downloading ${OVF_FILE_COUNT} file(s) from OVF bundle (${DL_FILE_PARALLEL_JOBS} files in parallel) …"
    dl_file_num=0
    dl_failed=0
    dl_file_pids=()
    dl_file_slots=()   # parallel to dl_file_pids — tracks which display slot each pid owns

    # Initialise the free-slot pool [1 … DL_FILE_PARALLEL_JOBS].
    # A slot is popped when a file starts and pushed back when its pid is reaped.
    # This prevents the cyclic-assignment race where file N+k overwrites the state
    # file of file k before file k has finished.
    _dl_avail_slots=()
    for (( _s=1; _s<=DL_FILE_PARALLEL_JOBS; _s++ )); do _dl_avail_slots+=("$_s"); done

    # Shared state for the multi-file progress display
    _DL_STATE_DIR="${LOG_DIR}/.dl_state_$$"
    _DL_DONE_BYTES_FILE="${LOG_DIR}/.dl_done_bytes_$$"
    mkdir -p "${_DL_STATE_DIR}"
    > "${_DL_DONE_BYTES_FILE}"

    # Pre-compute total pending bytes (OVF-declared sizes for non-completed files)
    _dl_total_pending=0
    while IFS='|' read -r _pfn _pfs; do
        [ -f "${OVF_BUNDLE_DIR}/${_pfn}.dl_complete" ] && continue
        [[ "$_pfs" =~ ^[0-9]+$ ]] && _dl_total_pending=$(( _dl_total_pending + _pfs ))
    done < "${OVF_FILE_LIST}"

    # Start the multi-file progress display when downloading in parallel.
    # Quiet mode buffers log() output so token-refresh messages don't corrupt the display.
    _DL_AGG_PID=0
    if [ "$DL_FILE_PARALLEL_JOBS" -gt 1 ] && [ "$_dl_total_pending" -gt 0 ]; then
        _progress_quiet_start
        _multifile_progress_daemon \
            "$DL_FILE_PARALLEL_JOBS" "$_dl_total_pending" "$(date +%s%N)" \
            "${_DL_STATE_DIR}" "${_DL_DONE_BYTES_FILE}" &
        _DL_AGG_PID=$!
    fi

    while IFS='|' read -r dl_fname dl_fsize; do
        dl_file_num=$(( dl_file_num + 1 ))
        dl_dest="${OVF_BUNDLE_DIR}/${dl_fname}"
        dl_sentinel="${dl_dest}.dl_complete"

        if [ -f "${dl_sentinel}" ]; then
            log "  [${dl_file_num}/${OVF_FILE_COUNT}] ${dl_fname} — already downloaded, skipping."
            continue
        fi
        # Sentinel missing but file exists with correct size (e.g. prior run didn't create
        # sentinel, or files were placed manually).  Treat as complete; write the sentinel
        # so future runs skip this file without re-downloading.
        if [ -f "${dl_dest}" ] && [[ "${dl_fsize}" =~ ^[1-9][0-9]*$ ]]; then
            _dl_actual=$(stat -c '%s' "${dl_dest}" 2>/dev/null || echo "0")
            if [ "$_dl_actual" -eq "$dl_fsize" ]; then
                log "  [${dl_file_num}/${OVF_FILE_COUNT}] ${dl_fname} — correct size (${dl_fsize}), marking complete."
                touch "${dl_sentinel}"
                continue
            fi
            # File exists but size is wrong — partial download. Delete and re-download.
            log "  [${dl_file_num}/${OVF_FILE_COUNT}] ${dl_fname} — partial download (${_dl_actual}/${dl_fsize}), re-downloading."
            rm -f "${dl_dest}"
        fi

        dl_url="${OVF_BASE_URL}/${dl_fname}"
        mkdir -p "$(dirname "${dl_dest}")"

        # Claim a free display slot — drain one running job first if the pool is empty.
        # This is the sliding-window gate: exactly one slot opens → exactly one file starts.
        if [ "${#_dl_avail_slots[@]}" -eq 0 ]; then
            if ! _drain_dl_files; then
                [ "$_DL_AGG_PID" -ne 0 ] && { kill "$_DL_AGG_PID" 2>/dev/null; printf '\n' >&2; }
                die "A file download job failed — check ${LOG_DIR}/"
            fi
            _dl_avail_slots+=("$_DL_FREED_SLOT")
        fi

        # Pop a slot (LIFO keeps low-numbered slots active longest for stable display)
        _snap_slot="${_dl_avail_slots[-1]}"
        _dl_avail_slots=( "${_dl_avail_slots[@]:0:$(( ${#_dl_avail_slots[@]} - 1 ))}" )

        _snap_state_file="${_DL_STATE_DIR}/$(printf 's%02d' "${_snap_slot}")"
        _snap_chunk_dir="${LOG_DIR}/.dl_chunks_${dl_fname//\//_}_$$"

        # Snapshot all loop vars the subshell needs at fork time
        _snap_fname="${dl_fname}" _snap_dest="${dl_dest}" _snap_fsize="${dl_fsize}"
        _snap_sentinel="${dl_sentinel}" _snap_url="${dl_url}" _snap_num="${dl_file_num}"

        # Write initial slot state so the daemon shows this file immediately
        printf '%s|%s|%s|0\n' "${dl_fname}" "${dl_fsize:-0}" "${_snap_chunk_dir}" \
            > "${_snap_state_file}"

        (
            set +e
            # Route log() output to a per-file log; keeps the terminal clean for the display
            exec >> "${LOG_DIR}/${VCD_TEMPLATE}_dl_${_snap_fname//\//_}.log" 2>&1
            _dl_attempt=0
            _dl_max_attempts=3
            _dl_success=0
            while [ "$_dl_attempt" -lt "$_dl_max_attempts" ]; do
                _dl_attempt=$(( _dl_attempt + 1 ))
                [ "$_dl_attempt" -gt 1 ] && log "  DL_RETRY ${_snap_fname} attempt ${_dl_attempt}/${_dl_max_attempts}"
                rm -f "${_snap_dest}"   # remove any partial file before (re-)downloading
                if ! _download_file_with_checksum \
                        "${_snap_fname}" "${_snap_url}" "${_snap_dest}" "${_snap_chunk_dir}"; then
                    log "  DL_FAIL ${_snap_fname} attempt ${_dl_attempt} — download function returned error"
                    continue
                fi
                # Verify downloaded size matches the ovf:size declared in the descriptor
                if [[ "${_snap_fsize}" =~ ^[1-9][0-9]*$ ]]; then
                    _dl_actual=$(stat -c '%s' "${_snap_dest}" 2>/dev/null || echo "0")
                    if [ "$_dl_actual" -ne "$_snap_fsize" ]; then
                        log "  DL_SIZE_MISMATCH ${_snap_fname} attempt ${_dl_attempt} — got ${_dl_actual} expected ${_snap_fsize}; will retry"
                        continue
                    fi
                fi
                _dl_success=1
                break
            done
            if [ "$_dl_success" -eq 1 ]; then
                touch "${_snap_sentinel}"
                # Mark slot done and record completed bytes for the overall bar
                printf '%s|%s|%s|1\n' "${_snap_fname}" "${_snap_fsize:-0}" "${_snap_chunk_dir}" \
                    > "${_snap_state_file}"
                [[ "${_snap_fsize}" =~ ^[0-9]+$ ]] && \
                    printf '%s\n' "${_snap_fsize}" >> "${_DL_DONE_BYTES_FILE}"
                exit 0
            else
                log "  DL_FATAL ${_snap_fname} — failed after ${_dl_max_attempts} attempts (size mismatch or download error)"
                printf '%s|%s|%s|2\n' "${_snap_fname}" "${_snap_fsize:-0}" "${_snap_chunk_dir}" \
                    > "${_snap_state_file}"
                exit 1
            fi
        ) &
        dl_file_pids+=($!)
        dl_file_slots+=("$_snap_slot")
    done < "${OVF_FILE_LIST}"

    rm -f "${OVF_FILE_LIST}"

    # Wait for any in-flight downloads still running after the manifest loop
    _dl_wrc=0
    for pid in "${dl_file_pids[@]+"${dl_file_pids[@]}"}"; do
        wait "$pid" 2>/dev/null; _dl_wrc=$?
        if [ "$_dl_wrc" -ne 0 ] && [ "$_dl_wrc" -ne 127 ]; then
            dl_failed=$(( dl_failed + 1 ))
        fi
    done

    # Stop the progress display, restore log() terminal output, flush buffered messages
    if [ "$_DL_AGG_PID" -ne 0 ]; then
        kill "$_DL_AGG_PID" 2>/dev/null || true
        wait "$_DL_AGG_PID" 2>/dev/null || true
        printf '\n' >&2
        _progress_quiet_stop
    fi
    rm -rf "${_DL_STATE_DIR}" "${_DL_DONE_BYTES_FILE}"

    if [ "$dl_failed" -gt 0 ]; then
        die "${dl_failed} file(s) failed to download. See ${LOG_DIR}/"
    fi

    log "✔ All ${dl_file_num} OVF bundle file(s) downloaded and verified."
    touch "$EXPORT_DONE"

fi  # end Phase 1 block


# Verify OVF bundle exists before continuing
[ -f "${OVF_DESCRIPTOR}" ] || die "OVF descriptor not found at ${OVF_DESCRIPTOR} — Phase 1 incomplete."
log "OVF bundle dir : ${OVF_BUNDLE_DIR}"
log "OVF descriptor : ${OVF_DESCRIPTOR} ($(numfmt --to=iec-i --suffix=B "$(stat -c%s "${OVF_DESCRIPTOR}")"))"



# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Optional rsync of OVF bundle to remote staging host
# ═════════════════════════════════════════════════════════════════════════════
log_phase "PHASE 2 — rsync OVF bundle to remote staging (optional)"

RSYNC_DONE="${OVF_BUNDLE_DIR}/.bundle_rsync_complete"

if [ -n "$REMOTE_STAGING" ]; then
    if [ -f "$RSYNC_DONE" ]; then
        log "rsync previously completed — skipping."
    else
        REMOTE_BUNDLE="${REMOTE_STAGING}/${VCD_TEMPLATE}"
        log "rsyncing '${OVF_BUNDLE_DIR}/' → ${REMOTE_BUNDLE}/ …"
        RSYNC_OPTS=(
            --archive --partial --partial-dir=".rsync-partial"
            --checksum --compress --info=progress2 --human-readable
        )
        [ "${RSYNC_BW_LIMIT}" -gt 0 ] && RSYNC_OPTS+=( --bwlimit="${RSYNC_BW_LIMIT}" )
        rsync "${RSYNC_OPTS[@]}" "${OVF_BUNDLE_DIR}/" "${REMOTE_BUNDLE}/"
        touch "$RSYNC_DONE"
        log "rsync completed."
    fi
else
    log "REMOTE_STAGING not set — using local staging directly."
fi


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Upload OVF bundle to Destination VCD via VCD REST API
#
# Strategy:
#   1. POST UploadVAppTemplateParams → VCD returns a vAppTemplate with a
#      descriptor.ovf transfer href.
#   2. PUT descriptor.ovf (Content-Length, full file in one shot — it's small).
#      VCD parses the OVF and generates per-file transfer hrefs for each VMDK.
#   3. Re-GET vAppTemplate; parse all <File> entries: name + size + transfer href.
#   4. For each file: PUT in sequential CHUNK_SIZE_MB chunks with Content-Range.
#      UL_PARALLEL_JOBS files upload concurrently.
#      After each file: verify bytesTransferred == size via VCD API, then
#      After every file upload, verify VCD's bytesTransferred == size.
#      On mismatch: retry the upload up to UPLOAD_RETRY_MAX times.
#      On any failure: retry the entire file upload up to UPLOAD_RETRY_MAX times.
#
# SENTINEL: TRANSFER_DONE written after all uploads complete and VCD is READY.
# ═════════════════════════════════════════════════════════════════════════════
log_phase "PHASE 3 — OVF bundle upload to Destination VCD (${DST_VCD_HOST})"

TRANSFER_DONE="${OVF_BUNDLE_DIR}/.bundle_transfer_complete"

if [ -f "$TRANSFER_DONE" ]; then
    log "Upload previously completed — skipping Phase 3."
else

    # ── Pre-flight: check for existing template in the destination catalog ───────
    # Three cases:
    #   status=8 (READY)     → abort; user must remove it manually.
    #   unresolved + live transfer hrefs on <File> elements
    #                        → REUSE the existing template; skip POST/PUT OVF;
    #                          jump straight to file-level upload using the live hrefs.
    #   unresolved + no live transfer hrefs (truly dead zombie)
    #                        → delete and start fresh as before.
    log "Checking for existing template '${VCD_TEMPLATE}' in '${DST_VCD_CATALOG}' …"
    _EXISTING_QUERY=$(_dst_vcd \
        "https://${DST_VCD_HOST}/api/query?type=vAppTemplate&filter=name==${VCD_TEMPLATE}" \
        2>/dev/null || true)
    echo "$_EXISTING_QUERY" > "${LOG_DIR}/existing_template_query.xml"

    _EXISTING_RECORD=$(echo "$_EXISTING_QUERY" \
        | tr '\n' ' ' \
        | grep -oP '<VAppTemplateRecord[^>]+/>' \
        | grep -P "catalogName=\"${DST_VCD_CATALOG}\"" \
        | head -1 || true)

    # Will be set to 1 if we successfully attach to an existing upload session.
    _REUSE_SESSION=0

    if [ -n "$_EXISTING_RECORD" ]; then
        _EXISTING_HREF=$(echo "$_EXISTING_RECORD" \
            | grep -oP '(?<=href=")[^"]+' | head -1 || true)
        _EXISTING_STATUS=$(echo "$_EXISTING_RECORD" \
            | grep -oP '(?<=status=")[^"]+' | head -1 || true)
        log "  Found existing template (status=${_EXISTING_STATUS:-unknown}): ${_EXISTING_HREF}"

        if [ "${_EXISTING_STATUS}" = "8" ]; then
            die "Template '${VCD_TEMPLATE}' already exists and is READY (status=8) in '${DST_VCD_CATALOG}'. Remove it from the VCD UI before re-running."
        fi

        # Template is unresolved — fetch its full XML and check for live hrefs.
        log "  Unresolved template found — probing for live transfer hrefs …"
        _PROBE_XML=$(curl --silent --insecure \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            "${_EXISTING_HREF}" 2>/dev/null || true)
        echo "$_PROBE_XML" > "${LOG_DIR}/existing_template_detail.xml"

        # Count <File> elements that carry a non-empty transfer href (upload:default link).
        # A live session will have these; a dead zombie will not.
        _LIVE_HREFS=$(echo "$_PROBE_XML" \
            | perl -0777 -pe 's|(<File\b[^>]*>)\s*(.*?)\s*</File>|$1.$2|gs' \
            | grep -oP '<File [^>]+>.*?(?=<File |$)' \
            | grep -v 'descriptor\.ovf' \
            | grep -oP 'href="https://[^"]+/transfer/[^"]+"' \
            | wc -l || true)

        log "  Live transfer hrefs found: ${_LIVE_HREFS}"

        if [ "${_LIVE_HREFS}" -gt 0 ]; then
            log "  ✔ Existing upload session is still alive — reusing it (skipping POST + OVF PUT)."
            VAPP_TMPL_HREF="${_EXISTING_HREF}"
            TMPL_XML="${_PROBE_XML}"
            FILE_COUNT=$(echo "$TMPL_XML" | grep -c '<File ' || true)
            log "  Files visible in existing session: ${FILE_COUNT}"
            echo "$TMPL_XML" > "${LOG_DIR}/vapptemplate_files.xml"
            _REUSE_SESSION=1
        else
            # No live transfer hrefs. Before treating as zombie, check whether all
            # data files already have bytesTransferred == size.  VCD clears transfer
            # hrefs after a successful upload, so a fully-uploaded template looks
            # identical to a dead zombie from the href perspective alone.
            _ALL_UPLOADED=$(echo "$_PROBE_XML" \
                | perl -0777 -ne '
                    my ($total, $done) = (0, 0);
                    while (/<File\b[^>]*>.*?<\/File>/gs) {
                        my $b = $&; $b =~ s/\n/ /g;
                        next if $b =~ /descriptor\.ovf/;
                        my ($sz) = ($b =~ /\bsize="(\d+)"/);
                        next unless defined $sz && $sz > 0;
                        $total++;
                        my ($bt) = ($b =~ /\bbytesTransferred="(\d+)"/);
                        $done++ if defined $bt && $bt == $sz;
                    }
                    print($total > 0 && $done == $total ? "yes" : "no");
                ' || echo "no")
            log "  All files fully uploaded (hrefs cleared by VCD): ${_ALL_UPLOADED}"

            if [ "$_ALL_UPLOADED" = "yes" ]; then
                log "  ✔ Upload already complete — reusing session for polling only."
                VAPP_TMPL_HREF="${_EXISTING_HREF}"
                TMPL_XML="${_PROBE_XML}"
                FILE_COUNT=$(echo "$TMPL_XML" | grep -c '<File ' || true)
                echo "$TMPL_XML" > "${LOG_DIR}/vapptemplate_files.xml"
                _REUSE_SESSION=1
            else
                log "  No live transfer hrefs and upload incomplete — treating as dead zombie. Deleting …"
                _DEL_HTTP=$(curl --silent --show-error --insecure \
                    --write-out '%{http_code}' -X DELETE \
                    -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
                    -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                    "${_EXISTING_HREF}" -o /dev/null 2>>"${LOG_DIR}/delete_zombie.log")
                if [ "${_DEL_HTTP}" = "204" ] || [ "${_DEL_HTTP}" = "200" ]; then
                    log "  ✔ Zombie deleted (HTTP ${_DEL_HTTP}). Waiting 10 s for VCD to settle …"
                    sleep 10
                else
                    die "DELETE of zombie template returned HTTP ${_DEL_HTTP}. Remove '${VCD_TEMPLATE}' manually and re-run."
                fi
            fi
        fi
    else
        log "  No existing template found — proceeding with fresh upload."
    fi
    unset _EXISTING_QUERY _EXISTING_RECORD _EXISTING_HREF _EXISTING_STATUS
    unset _PROBE_XML _LIVE_HREFS

    if [ "${_REUSE_SESSION}" -eq 0 ]; then
        # ── Step 1: find catalog upload action href ───────────────────────────
        log "Looking up destination catalog …"
        CAT_XML=$(curl --silent --show-error --insecure \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            "https://${DST_VCD_HOST}/api/query?type=catalog&filter=name==${DST_VCD_CATALOG}" \
            2>/dev/null || true)
        echo "$CAT_XML" > "${LOG_DIR}/dst_catalog_query.xml"

        CAT_HREF=$(echo "$CAT_XML" \
            | tr '\n' ' ' \
            | grep -oP 'href="https://[^"]+/api/catalog/[^"]+"' \
            | head -1 | grep -oP '(?<=href=")[^"]+')
        [ -z "$CAT_HREF" ] && \
            die "Catalog '${DST_VCD_CATALOG}' not found on ${DST_VCD_HOST}. See ${LOG_DIR}/dst_catalog_query.xml"
        log "Catalog HREF: ${CAT_HREF}"

        CAT_DETAIL=$(curl --silent --show-error --insecure \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            "${CAT_HREF}" 2>/dev/null || true)
        UPLOAD_ACTION_HREF=$(echo "$CAT_DETAIL" \
            | tr '\n' ' ' \
            | grep -oP '<Link[^>]+>' \
            | grep 'uploadVAppTemplateParams\+xml' \
            | grep -oP '(?<=href=")[^"]+' | head -1 || true)
        [ -z "$UPLOAD_ACTION_HREF" ] && \
            UPLOAD_ACTION_HREF="${CAT_HREF}/action/upload"
        log "Upload action: ${UPLOAD_ACTION_HREF}"

        # ── Step 2: POST UploadVAppTemplateParams → get vAppTemplate href ─────
        log "Creating vAppTemplate upload session …"
        UPLOAD_RESP=$(curl --silent --show-error --insecure \
            -w '\nHTTP_STATUS:%{http_code}' \
            -X POST \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            -H "Content-Type: application/vnd.vmware.vcloud.uploadVAppTemplateParams+xml" \
            -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<UploadVAppTemplateParams
    xmlns=\"http://www.vmware.com/vcloud/v1.5\"
    name=\"${VCD_TEMPLATE}\">
    <Description>Migrated from ${SRC_VCD_HOST}</Description>
</UploadVAppTemplateParams>" \
            "${UPLOAD_ACTION_HREF}" 2>>"${LOG_DIR}/upload_session.log")
        _upload_http_status=$(echo "$UPLOAD_RESP" | grep -oP '(?<=HTTP_STATUS:)\d+' || echo "000")
        UPLOAD_RESP=$(echo "$UPLOAD_RESP" | grep -v '^HTTP_STATUS:')
        echo "$UPLOAD_RESP" > "${LOG_DIR}/upload_session_response.xml"
        if [ "$_upload_http_status" != "201" ]; then
            log "ERROR: Upload session POST returned HTTP ${_upload_http_status}. VCD response:"
            grep -oP '<Message>[^<]+</Message>' "${LOG_DIR}/upload_session_response.xml" | \
                sed 's/<[^>]*>//g' | while IFS= read -r _msg; do log "  ${_msg}"; done
            die "Failed to create upload session (HTTP ${_upload_http_status}). See ${LOG_DIR}/upload_session_response.xml"
        fi

        VAPP_TMPL_HREF=$(echo "$UPLOAD_RESP" \
            | grep -oP 'href="https://[^"]+/api/vAppTemplate/[^"]+"' \
            | head -1 | grep -oP '(?<=href=")[^"]+')
        [ -z "$VAPP_TMPL_HREF" ] && \
            die "No vAppTemplate href in upload session response. See ${LOG_DIR}/upload_session_response.xml"
        log "vAppTemplate href: ${VAPP_TMPL_HREF}"

        # ── Step 2b: validate staged file sizes against descriptor.ovf ──────────
        # ovf:size is authoritative (declared by source VCD).  If any staged file
        # is smaller than its declared size the download was incomplete; uploading
        # a truncated file would corrupt the VM on the destination.  Abort here so
        # the operator can delete the partial files and re-run Phase 1 to re-download.
        log "Validating staged file sizes against descriptor.ovf …"
        _size_errors=0
        while IFS= read -r _attr; do
            _href=$(echo "$_attr" | grep -oP '(?<=ovf:href=")[^"]+')
            _decl=$(echo "$_attr" | grep -oP '(?<=ovf:size=")[0-9]+')
            _staged="${OVF_BUNDLE_DIR}/${_href}"
            _actual=$(stat -c '%s' "${_staged}" 2>/dev/null || echo "0")
            if [ "$_actual" -ne "$_decl" ]; then
                log "  SIZE_MISMATCH ${_href}: declared=${_decl} actual=${_actual} — download incomplete"
                _size_errors=$(( _size_errors + 1 ))
            fi
        done < <(grep -oP 'ovf:href="[^"]+" ovf:size="[0-9]+"' "${OVF_DESCRIPTOR}" || true)
        if [ "$_size_errors" -gt 0 ]; then
            log ""
            log "  REMEDIATION: the incomplete files were listed above."
            log "  To re-download only the truncated files, run:"
            log "    rm ${OVF_BUNDLE_DIR}/<incomplete-file>"
            log "    rm ${OVF_BUNDLE_DIR}/.bundle_download_complete"
            log "  Then re-run this script — Phase 1 will skip correctly-sized files"
            log "  and re-download only those that are missing or truncated."
            die "${_size_errors} staged file(s) have incomplete downloads (actual size < declared ovf:size)."
        fi
        log "  All staged files match their declared ovf:size."

        # ── Step 3: PUT descriptor.ovf ────────────────────────────────────────
        log "Uploading descriptor.ovf …"
        OVF_SIZE=$(stat -c%s "${OVF_DESCRIPTOR}")
        [ "$OVF_SIZE" -eq 0 ] && die "Staged descriptor.ovf is empty."
        log "  OVF size: ${OVF_SIZE} bytes"

        # GET vAppTemplate to find descriptor.ovf transfer href
        TMPL_XML=$(curl --silent --show-error --insecure \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            "${VAPP_TMPL_HREF}" 2>/dev/null || true)
        DESCRIPTOR_HREF=$(echo "$TMPL_XML" \
            | tr '\n' ' ' \
            | grep -oP '<File[^>]+descriptor\.ovf[^>]+>' \
            | grep -oP 'href="[^"]+"' \
            | grep -oP '(?<=href=")[^"]+' | head -1 || true)
        [ -z "$DESCRIPTOR_HREF" ] && \
            DESCRIPTOR_HREF=$(echo "$TMPL_XML" \
                | grep -oP 'href="https://[^"]+/transfer/[^"]+"' \
                | head -1 | grep -oP '(?<=href=")[^"]+')
        [ -z "$DESCRIPTOR_HREF" ] && \
            die "No descriptor.ovf transfer href found. See ${LOG_DIR}/upload_session_response.xml"
        log "  Descriptor transfer href: ${DESCRIPTOR_HREF}"

        DESC_HTTP=$(curl --silent --show-error --insecure \
            -X PUT \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            -H "Content-Type: application/ovf+xml" \
            -H "Content-Length: ${OVF_SIZE}" \
            --data-binary "@${OVF_DESCRIPTOR}" \
            --write-out '%{http_code}' \
            -o /dev/null \
            "${DESCRIPTOR_HREF}" 2>>"${LOG_DIR}/upload_session.log")
        [ "${DESC_HTTP}" = "200" ] || [ "${DESC_HTTP}" = "201" ] || [ "${DESC_HTTP}" = "204" ] || \
            die "descriptor.ovf upload returned HTTP ${DESC_HTTP}"
        log "  ✔ descriptor.ovf uploaded (HTTP ${DESC_HTTP})."

        # ── Step 4: wait for VCD to parse OVF and expose VMDK transfer hrefs ──
        log "Waiting for VCD to parse OVF and generate file transfer hrefs …"
        parse_wait=0; parse_max=24   # 24 × 5 s = 2 min
        FILE_COUNT=0
        while [ "$parse_wait" -lt "$parse_max" ]; do
            TMPL_XML=$(_dst_vcd "${VAPP_TMPL_HREF}" 2>/dev/null || true)
            FILE_COUNT=$(echo "$TMPL_XML" | grep -c '<File ' || true)
            log "  Files visible: ${FILE_COUNT} (wait ${parse_wait}/${parse_max})"
            [ "$FILE_COUNT" -gt 1 ] && break
            sleep 5
            parse_wait=$(( parse_wait + 1 ))
        done
        [ "$FILE_COUNT" -le 1 ] && \
            die "VCD did not generate VMDK transfer hrefs after OVF upload. Check ${LOG_DIR}/upload_session_response.xml"
        echo "$TMPL_XML" > "${LOG_DIR}/vapptemplate_files.xml"

    fi  # end _REUSE_SESSION==0 block

    # ── Step 5: parse all File entries → name, size, transfer href ───────────
    UL_CHUNK_LOG="${LOG_DIR}/${VCD_TEMPLATE}_ul.chunklog"
    > "$UL_CHUNK_LOG"

    FILE_MANIFEST=$(mktemp /tmp/vcd_file_manifest_XXXXXX.txt)

    while IFS='|' read -r f_name f_size f_href f_xfer; do
        # Skip if name or href is missing — unusable record
        { [ -z "$f_name" ] || [ -z "$f_href" ]; } && continue
        [[ "$f_name" == *descriptor.ovf* ]] && continue

        # Skip if VCD hasn't populated a real size yet (size=0 or missing)
        if [ -z "$f_size" ] || [ "$f_size" = "0" ]; then
            echo "WARN file=${f_name} size=0 or missing — skipping (VCD did not register size)" >> "${UL_CHUNK_LOG}"
            continue
        fi

        # Only skip if bytesTransferred is a real non-zero number that matches size
        # (guards against the 0==0 false-positive on a fresh upload session)
        if [[ "$f_size" =~ ^[1-9][0-9]*$ ]] && \
           [[ "$f_xfer" =~ ^[1-9][0-9]*$ ]] && \
           [ "${f_xfer}" = "${f_size}" ]; then
            echo "SKIP file=${f_name} already_complete bytesTransferred=${f_xfer}" >> "${UL_CHUNK_LOG}"
            continue
        fi

        echo "${f_name}|${f_size}|${f_href}"
    done < <(
        # Collapse each <File>...</File> block onto a single line so that the
        # child <Link rel="upload:default" href="..."/> is visible alongside
        # the parent <File name= size= bytesTransferred=> attributes.
        # Use perl to both collapse and split — avoids the grep lookahead $
        # anchor bug that silently dropped all but the first <File> block.
        echo "$TMPL_XML" \
            | perl -0777 -ne '
                while (/<File\b[^>]*>.*?<\/File>/gs) {
                    (my $block = $&) =~ s/\n/ /g;
                    print $block, "\n";
                }
            ' \
            | awk '
                /descriptor[.]ovf/ { next }
                {
                    fname=""; fsize=""; fhref=""; fxfer=""
                    n = split($0, a, /name="/);   if (n>=2) { sub(/".*/, "", a[2]); fname=a[2] }
                    n = split($0, b, /size="/);   if (n>=2) { sub(/".*/, "", b[2]); fsize=b[2] }
                    # href lives on the child <Link rel="upload:default"> element
                    n = split($0, c, /href="/);   if (n>=2) { sub(/".*/, "", c[2]); fhref=c[2] }
                    n = split($0, d, /bytesTransferred="/); if (n>=2) { sub(/".*/, "", d[2]); fxfer=d[2] }
                    if (fname != "" && fsize != "" && fhref != "") print fname "|" fsize "|" fhref "|" fxfer
                }
            ' || true
    ) >> "${FILE_MANIFEST}"

    TOTAL_FILES=$(wc -l < "${FILE_MANIFEST}")
    log "Files to upload: ${TOTAL_FILES}"

    # ── Step 6: upload each file in chunks — UL_PARALLEL_JOBS concurrent ──────
    # Each file is uploaded sequentially in CHUNK_SIZE_MB slices using
    # Content-Range headers.  VCD requires strict offset order per transfer href.
    # After each file: verify bytesTransferred then re-hash staged file.

    # ── Progress monitor (background) ────────────────────────────────────────
    # Reads UL_CHUNK_OK / UL_VERIFIED lines from UL_CHUNK_LOG every 2 s and
    # renders an ANSI progress display: one overall bar + per-active-file rows.
    UL_PROGRESS_FILE=$(mktemp /tmp/vcd_ul_progress_XXXXXX.txt)   # name|size per queued file

    # Compute total bytes to upload (sum of all file sizes in manifest)
    _UL_TOTAL_BYTES=0
    while IFS='|' read -r _pn _ps _ph; do
        _UL_TOTAL_BYTES=$(( _UL_TOTAL_BYTES + _ps ))
    done < "${FILE_MANIFEST}"

    _progress_monitor() {
        local chunk_log="$1" progress_file="$2" total_bytes="$3"

        # Wait until the progress file has at least one entry
        while [ ! -s "$progress_file" ]; do sleep 1; done

        declare -A FILE_SIZE        # name → total bytes
        declare -A FILE_SENT        # name → bytes confirmed sent
        declare -A FILE_CHUNKS_DONE # name → chunks completed
        declare -A FILE_CHUNKS_TOT  # name → total chunks expected (computed from size/CHUNK_BYTES)
        declare -A FILE_DONE        # name → 1 when UL_VERIFIED seen
        declare -A FILE_ORDER       # name → queue index for stable display order
        declare -A FILE_STATUS      # name → "active"|"verify"|"done"|"error"

        local overall_sent=0
        local overall_bar_width=60
        local file_bar_width=28
        local _last_lines=0
        local _log_pos=0            # byte offset — only read new lines each cycle
        local _queue_idx=0

        # ── Ingest new log lines (incremental, from _log_pos) ────────────────
        _ingest() {
            local new_lines
            new_lines=$(tail -c +"$(( _log_pos + 1 ))" "$chunk_log" 2>/dev/null || true)
            local new_bytes=${#new_lines}
            _log_pos=$(( _log_pos + new_bytes ))

            local line fn bstart bend bsent
            while IFS= read -r line; do
                # UL_CHUNK_OK file=X chunk=N bytes=START-END
                if [[ "$line" =~ ^UL_CHUNK_OK[[:space:]]file=([^[:space:]]+)[[:space:]]chunk=([0-9]+)[[:space:]]bytes=([0-9]+)-([0-9]+) ]]; then
                    fn="${BASH_REMATCH[1]}"
                    bstart="${BASH_REMATCH[3]}"
                    bend="${BASH_REMATCH[4]}"
                    bsent=$(( bend - bstart + 1 ))
                    FILE_SENT["$fn"]=$(( ${FILE_SENT["$fn"]:-0} + bsent ))
                    FILE_CHUNKS_DONE["$fn"]=$(( ${FILE_CHUNKS_DONE["$fn"]:-0} + 1 ))
                    FILE_STATUS["$fn"]="active"
                # UL_VERIFIED file=X ...
                elif [[ "$line" =~ ^UL_VERIFIED[[:space:]]file=([^[:space:]]+) ]]; then
                    fn="${BASH_REMATCH[1]}"
                    FILE_DONE["$fn"]=1
                    FILE_STATUS["$fn"]="done"
                    FILE_SENT["$fn"]="${FILE_SIZE[$fn]:-${FILE_SENT[$fn]:-0}}"
                # UL_CHUNK_ERR / UL_CHUNK_FAIL
                elif [[ "$line" =~ ^UL_CHUNK_(ERR|FAIL)[[:space:]]file=([^[:space:]]+) ]]; then
                    fn="${BASH_REMATCH[2]}"
                    FILE_STATUS["$fn"]="error"
                fi
            done <<< "$new_lines"
        }

        # ── Sync FILE_SIZE / FILE_ORDER from progress_file ───────────────────
        _sync_registry() {
            local pn ps
            while IFS='|' read -r pn ps; do
                if [ -z "${FILE_SIZE[$pn]:-}" ]; then
                    FILE_SIZE["$pn"]="$ps"
                    FILE_ORDER["$pn"]="$_queue_idx"
                    _queue_idx=$(( _queue_idx + 1 ))
                    # pre-compute total chunks (ceiling division)
                    local cb="${CHUNK_BYTES:-268435456}"
                    FILE_CHUNKS_TOT["$pn"]=$(( ( ps + cb - 1 ) / cb ))
                fi
            done < "$progress_file"
        }

        # ── Render ───────────────────────────────────────────────────────────
        _render() {
            # Recompute overall_sent
            overall_sent=0
            local fn
            for fn in "${!FILE_SENT[@]}"; do
                overall_sent=$(( overall_sent + ${FILE_SENT[$fn]} ))
            done
            [ "$overall_sent" -gt "$total_bytes" ] && overall_sent="$total_bytes"

            # Erase previous render
            if [ "$_last_lines" -gt 0 ]; then
                printf '\033[%dA\033[J' "$_last_lines"
            fi
            local lines_printed=0

            # ── Overall bar ──────────────────────────────────────────────────
            local pct=0 filled=0 empty=0 sent_h total_h done_count=0
            [ "$total_bytes" -gt 0 ] && pct=$(( overall_sent * 100 / total_bytes ))
            filled=$(( pct * overall_bar_width / 100 ))
            empty=$(( overall_bar_width - filled ))
            sent_h=$(numfmt --to=iec-i --suffix=B "$overall_sent" 2>/dev/null || echo "${overall_sent}B")
            total_h=$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || echo "${total_bytes}B")
            local total_files="${#FILE_SIZE[@]}"
            for fn in "${!FILE_DONE[@]}"; do done_count=$(( done_count + 1 )); done

            printf '\033[1;32m[UPLOAD  ]\033[0m ['
            printf '%.0s█' $(seq 1 "$filled")
            printf '%.0s░' $(seq 1 "$empty")
            printf '] \033[1m%3d%%\033[0m  %s / %s  \033[33m(%d/%d done)\033[0m\n' \
                "$pct" "$sent_h" "$total_h" "$done_count" "$total_files"
            lines_printed=$(( lines_printed + 1 ))

            # Separator
            printf '\033[90m%s\033[0m\n' "$(printf '─%.0s' $(seq 1 $(( overall_bar_width + 40 ))))"
            lines_printed=$(( lines_printed + 1 ))

            # ── Per-file rows — sorted by queue order ─────────────────────
            # Build sorted list
            local sorted_names=()
            for fn in "${!FILE_ORDER[@]}"; do
                sorted_names+=( "${FILE_ORDER[$fn]}:${fn}" )
            done
            IFS=$'\n' sorted_names=( $(printf '%s\n' "${sorted_names[@]}" | sort -t: -k1,1n) )
            unset IFS

            local fw=40  # filename display width
            for entry in "${sorted_names[@]}"; do
                fn="${entry#*:}"
                local fsz="${FILE_SIZE[$fn]:-0}"
                local fsent="${FILE_SENT[$fn]:-0}"
                local fchk_done="${FILE_CHUNKS_DONE[$fn]:-0}"
                local fchk_tot="${FILE_CHUNKS_TOT[$fn]:-?}"
                local fstatus="${FILE_STATUS[$fn]:-queued}"
                local fdone="${FILE_DONE[$fn]:-0}"

                local fpct=0
                [ "$fsz" -gt 0 ] && fpct=$(( fsent * 100 / fsz ))
                local ffilled=$(( fpct * file_bar_width / 100 ))
                local fempty=$(( file_bar_width - ffilled ))

                local fsent_h fsz_h
                fsent_h=$(numfmt --to=iec-i --suffix=B "$fsent" 2>/dev/null || echo "${fsent}B")
                fsz_h=$(numfmt --to=iec-i --suffix=B "$fsz" 2>/dev/null || echo "${fsz}B")

                # Truncate filename
                local display_name="$fn"
                [ "${#fn}" -gt "$fw" ] && display_name="…${fn: -$(( fw - 1 ))}"

                # Colour and status label by state (10-char labels match download display)
                local color label
                case "$fstatus" in
                    done)   color='\033[32m'; label='✔ done    ' ;;
                    verify) color='\033[33m'; label='⟳ verify  ' ;;
                    error)  color='\033[31m'; label='✖ error   ' ;;
                    active) color='\033[36m'; label='↑ upload  ' ;;
                    *)      color='\033[90m'; label='… queued  ' ;;
                esac

                printf "  ${color}%-*s\033[0m ${label}" "$fw" "$display_name"

                if [ "$fstatus" = "done" ]; then
                    # Completed — show full bar in green
                    printf '\033[32m['
                    printf '%.0s█' $(seq 1 "$file_bar_width")
                    printf ']\033[0m 100%%  %s  chunks:%d/%d\n' \
                        "$fsz_h" "$fchk_done" "$fchk_tot"
                elif [ "$fstatus" = "queued" ]; then
                    # Not started yet — empty bar
                    printf '\033[90m['
                    printf '%.0s·' $(seq 1 "$file_bar_width")
                    printf ']\033[0m   0%%  %s  chunks:0/%d\n' "$fsz_h" "$fchk_tot"
                else
                    # In-flight or verifying
                    printf '['
                    printf '%.0s▓' $(seq 1 "$ffilled")
                    printf '%.0s·' $(seq 1 "$fempty")
                    printf '] %3d%%  %s / %s  chunks:%d/%d\n' \
                        "$fpct" "$fsent_h" "$fsz_h" "$fchk_done" "$fchk_tot"
                fi
                lines_printed=$(( lines_printed + 1 ))
            done

            _last_lines="$lines_printed"
        }

        # ── Main monitor loop ────────────────────────────────────────────────
        while true; do
            _sync_registry
            _ingest
            _render
            sleep 2
            if [ -f "${UL_PROGRESS_FILE}.done" ]; then
                _sync_registry
                _ingest
                _render   # final render
                printf '\n'
                break
            fi
        done
    }

    # Start the monitor in background; quiet mode prevents log() from corrupting the display
    _progress_quiet_start
    _progress_monitor "${UL_CHUNK_LOG}" "${UL_PROGRESS_FILE}" "${_UL_TOTAL_BYTES}" &
    _PROGRESS_PID=$!

    ul_pids=()
    ul_file_num=0

    # ── Per-file upload lock dir — prevents any race that could start the same ──
    # file twice (e.g. a stale PID being double-reaped by _drain_to_limit).
    # Each file atomically claims a lock file before uploading; a second attempt
    # on the same file finds the lock already taken and exits cleanly.
    _UL_LOCK_DIR="${LOG_DIR}/.ul_locks_$$"
    mkdir -p "${_UL_LOCK_DIR}"

    # Clean up stale ul_lock dirs from previous runs whose PIDs are gone.
    # A dead PID's lock dir left on disk would wrongly prevent re-upload of the
    # same file in this run (the per-file mkdir lock would see the dir already).
    for _stale_dir in "${LOG_DIR}"/.ul_locks_*; do
        [ -d "$_stale_dir" ] || continue
        _stale_pid="${_stale_dir##*.ul_locks_}"
        [ "$_stale_pid" -eq "$$" ] 2>/dev/null && continue   # skip our own dir
        kill -0 "$_stale_pid" 2>/dev/null && continue         # PID still alive — leave it
        rm -rf "$_stale_dir"
    done

    # _upload_one_file_body — runs the chunked upload for one file.
    # Called as:  _upload_one_file_body <name> <size> <href>
    # Must NOT contain any background ( ) & inside — the caller backgrounds it
    # so $! reliably captures this exact process and nothing else.
    _upload_one_file_body() {
        local f_name="$1" f_size="$2" f_href="$3"
        set +e

        # ── Per-file exclusive lock (atomic mkdir) ────────────────────────────
        # If another worker somehow already claimed this file, exit immediately.
        local _lock_path="${_UL_LOCK_DIR}/${f_name//\//_}.lock"
        if ! mkdir "${_lock_path}" 2>/dev/null; then
            echo "UL_SKIP_DUP file=${f_name} lock already held — duplicate launch prevented" >> "${UL_CHUNK_LOG}"
            exit 0
        fi
        # Lock held; remove on exit (success or failure).
        trap 'rm -rf "${_lock_path}"' EXIT

        local attempt=1 delay="$UPLOAD_RETRY_DELAY"
        local f_staged="${OVF_BUNDLE_DIR}/${f_name}"
        local local_chunk_bytes=$CHUNK_BYTES   # may be halved on repeated STUCK
        local stuck_count=0                    # consecutive attempts with same bytesTransferred

        local prev_bxt=-1
        while [ "$attempt" -le "$UPLOAD_RETRY_MAX" ]; do

            # Re-fetch live transfer href on every attempt (VCD URLs expire)
            local live_href
            live_href=$(curl --silent --insecure \
                -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
                -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                "${VAPP_TMPL_HREF}" 2>/dev/null \
                | tr '\n' ' ' \
                | { grep -oP '<File [^>]+>.*?</File>' || true; } \
                | { grep "name=\"${f_name}\"" || true; } \
                | head -1 \
                | { grep -oP 'href="https://[^"]+/transfer/[^"]+"' || true; } \
                | { grep -oP '(?<=href=")[^"]+' || true; } \
                | head -1 || true)
            if [ -z "$live_href" ]; then
                # VCD clears the transfer href once the file is fully committed.
                # Re-fetch bytesTransferred now to check before falling back.
                local _pre_bxt
                _pre_bxt=$(curl --silent --insecure \
                    -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
                    -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                    "${VAPP_TMPL_HREF}" 2>/dev/null \
                    | perl -0777 -ne 'while (/<File\b[^>]*>.*?<\/File>/gs) { (my $b=$&)=~s/\n/ /g; print $b,"\n" }' \
                    | grep "name=\"${f_name}\"" \
                    | grep -oP '(?<=bytesTransferred=")[^"]+' \
                    | head -1 || echo "0")
                [[ "$_pre_bxt" =~ ^[0-9]+$ ]] || _pre_bxt=0
                if [ "$_pre_bxt" -eq "$f_size" ]; then
                    echo "UL_VERIFIED file=${f_name} bytesTransferred=${_pre_bxt} (href cleared — already complete)" >> "${UL_CHUNK_LOG}"
                    exit 0
                fi
                echo "UL_WARN file=${f_name} attempt=${attempt} no live transfer href (bytesTransferred=${_pre_bxt}/${f_size}) — using stale manifest href; VCD session may have expired" >> "${UL_CHUNK_LOG}"
                live_href="$f_href"
            fi

            # ── Chunked PUT with Content-Range ────────────────────────────────
            # Query VCD for how many bytes it already committed so we can
            # resume from that offset rather than always starting from 0.
            local _bxt
            _bxt=$(curl --silent --insecure \
                -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
                -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                "${VAPP_TMPL_HREF}" 2>/dev/null \
                | perl -0777 -ne 'while (/<File\b[^>]*>.*?<\/File>/gs) { (my $b=$&)=~s/\n/ /g; print $b,"\n" }' \
                | grep "name=\"${f_name}\"" \
                | grep -oP '(?<=bytesTransferred=")[^"]+' \
                | head -1 || echo "0")
            [[ "$_bxt" =~ ^[0-9]+$ ]] || _bxt=0
            # If VCD made zero progress since the last attempt, the upload slot
            # may be in a corrupted state.  Add an extra sleep to let it recover.
            if [ "$attempt" -gt 1 ] && [ "$_bxt" -eq "$prev_bxt" ]; then
                stuck_count=$(( stuck_count + 1 ))
                # Halve chunk size each time we're stuck (min 64 MB) so VCD's staging
                # buffer isn't overwhelmed — logs show 512 MB chunks stall at 256 MB.
                local _half=$(( local_chunk_bytes / 2 ))
                [ "$_half" -lt 67108864 ] && _half=67108864
                local_chunk_bytes=$_half
                echo "UL_STUCK file=${f_name} attempt=${attempt} stuck_count=${stuck_count} bytesTransferred=${_bxt} — no progress; chunk_bytes shrunk to $(( local_chunk_bytes / 1048576 ))MB; extra sleep ${delay}s" >> "${UL_CHUNK_LOG}"
                if [ "$stuck_count" -ge 3 ]; then
                    echo "UL_FATAL file=${f_name} VCD transfer session unrecoverable at bytesTransferred=${_bxt} — delete the vApp template in VCD and re-run this script" >> "${UL_CHUNK_LOG}"
                    exit 1
                fi
                sleep "$delay"
            else
                stuck_count=0
            fi
            prev_bxt="$_bxt"
            local ul_offset="$_bxt"
            local ul_chunk_num=$(( _bxt / local_chunk_bytes ))
            local chunk_failed=0
            if [ "$ul_offset" -gt 0 ]; then
                echo "UL_RESUME file=${f_name} attempt=${attempt} offset=${ul_offset}" >> "${UL_CHUNK_LOG}"
                # Seed the progress monitor with already-committed bytes (first attempt of
                # a fresh run only — avoids double-counting within-run retries).
                [ "$attempt" -eq 1 ] && \
                    echo "UL_CHUNK_OK file=${f_name} chunk=0 bytes=0-$(( ul_offset - 1 ))" >> "${UL_CHUNK_LOG}"
            fi
            while [ "$ul_offset" -lt "$f_size" ]; do
                local ul_remaining=$(( f_size - ul_offset ))
                local ul_length=$(( ul_remaining < local_chunk_bytes ? ul_remaining : local_chunk_bytes ))
                local ul_end=$(( ul_offset + ul_length - 1 ))

                local chunk_http
                # Use 1M block size: skip/count are in blocks, so divide byte offsets.
                # ul_offset and ul_length are always multiples of CHUNK_BYTES (1M-aligned)
                # except for the final chunk — handle that with bs=1 only for the tail.
                local dd_bs=1048576  # 1 MiB
                local dd_skip=$(( ul_offset / dd_bs ))
                local dd_count=$(( ul_length / dd_bs ))
                local dd_tail=$(( ul_length % dd_bs ))
                if [ "$dd_count" -gt 0 ] && [ "$dd_tail" -eq 0 ]; then
                    # Perfectly aligned chunk — fast path
                    chunk_http=$(dd if="${f_staged}" bs=${dd_bs} skip="${dd_skip}" count="${dd_count}" status=none 2>/dev/null \
                        | curl --silent --show-error --insecure \
                            -X PUT \
                            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                            -H "Content-Type: application/octet-stream" \
                            -H "Content-Length: ${ul_length}" \
                            -H "Content-Range: bytes ${ul_offset}-${ul_end}/${f_size}" \
                            --data-binary @- \
                            --write-out '%{http_code}' \
                            -o /dev/null \
                            "${live_href}" 2>>"${UL_CHUNK_LOG}" || echo "000")
                else
                    # Final or unaligned chunk — two-stage dd to avoid bs=1 byte-loop penalty.
                    # Stage A: bulk read of the aligned 1 MiB prefix (fast).
                    # Stage B: bs=1 read of the remaining tail bytes only (small).
                    local tmp_chunk
                    tmp_chunk=$(mktemp /tmp/vcd_ul_chunk_XXXXXX.bin)
                    {
                        [ "$dd_count" -gt 0 ] && \
                            dd if="${f_staged}" bs=${dd_bs} skip="${dd_skip}" count="${dd_count}" status=none 2>/dev/null
                        [ "$dd_tail" -gt 0 ] && \
                            dd if="${f_staged}" bs=1 skip=$(( ul_offset + dd_count * dd_bs )) count="${dd_tail}" status=none 2>/dev/null
                    } > "${tmp_chunk}" 2>/dev/null
                    chunk_http=$(curl --silent --show-error --insecure \
                        -X PUT \
                        -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                        -H "Content-Type: application/octet-stream" \
                        -H "Content-Length: ${ul_length}" \
                        -H "Content-Range: bytes ${ul_offset}-${ul_end}/${f_size}" \
                        --data-binary "@${tmp_chunk}" \
                        --write-out '%{http_code}' \
                        -o /dev/null \
                        "${live_href}" 2>>"${UL_CHUNK_LOG}" || echo "000")
                    rm -f "${tmp_chunk}"
                fi

                if [ "${chunk_http}" != "200" ] && [ "${chunk_http}" != "201" ] && [ "${chunk_http}" != "204" ] && [ "${chunk_http}" != "206" ]; then
                    echo "UL_CHUNK_ERR file=${f_name} chunk=${ul_chunk_num} offset=${ul_offset} http=${chunk_http}" >> "${UL_CHUNK_LOG}"
                    chunk_failed=1
                    break
                fi

                echo "UL_CHUNK_OK file=${f_name} chunk=${ul_chunk_num} bytes=${ul_offset}-${ul_end}" >> "${UL_CHUNK_LOG}"
                ul_offset=$(( ul_offset + ul_length ))
                ul_chunk_num=$(( ul_chunk_num + 1 ))
            done

            if [ "$chunk_failed" -ne 0 ]; then
                local _next_attempt=$(( attempt + 1 ))
                local _retry_label
                [ "$_next_attempt" -le "$UPLOAD_RETRY_MAX" ] && _retry_label="retrying (${_next_attempt}/${UPLOAD_RETRY_MAX})" || _retry_label="all retries exhausted"
                echo "UL_CHUNK_FAIL file=${f_name} attempt=${attempt} — ${_retry_label}" >> "${UL_CHUNK_LOG}"
                [ "$_next_attempt" -le "$UPLOAD_RETRY_MAX" ] && { sleep "$delay"; delay=$(( delay * 2 )); }
                attempt=$(( attempt + 1 ))
                continue
            fi

            # Confirm VCD committed every byte before declaring success
            local _vbxt
            _vbxt=$(curl --silent --insecure \
                -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
                -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
                "${VAPP_TMPL_HREF}" 2>/dev/null \
                | perl -0777 -ne 'while (/<File\b[^>]*>.*?<\/File>/gs) { (my $b=$&)=~s/\n/ /g; print $b,"\n" }' \
                | grep "name=\"${f_name}\"" \
                | grep -oP '(?<=bytesTransferred=")[^"]+' \
                | head -1 || echo "0")
            [[ "$_vbxt" =~ ^[0-9]+$ ]] || _vbxt=0
            if [ "$_vbxt" -ne "$f_size" ]; then
                echo "UL_VERIFY_FAIL file=${f_name} attempt=${attempt} bytesTransferred=${_vbxt} expected=${f_size}" >> "${UL_CHUNK_LOG}"
                local _vna=$(( attempt + 1 ))
                [ "$_vna" -le "$UPLOAD_RETRY_MAX" ] && { sleep "$delay"; delay=$(( delay * 2 )); }
                attempt=$(( attempt + 1 ))
                continue
            fi

            echo "UL_VERIFIED file=${f_name} bytesTransferred=${_vbxt}" >> "${UL_CHUNK_LOG}"
            exit 0

        done  # retry loop

        echo "UL_FATAL file=${f_name} giving up after ${UPLOAD_RETRY_MAX} attempts" >> "${UL_CHUNK_LOG}"
        exit 1
    }

    while IFS='|' read -r f_name f_size f_href; do
        ul_file_num=$(( ul_file_num + 1 ))
        log "  [${ul_file_num}/${TOTAL_FILES}] Queuing ${f_name} ($(numfmt --to=iec-i --suffix=B "${f_size}")) …"
        # Register file in progress monitor
        echo "${f_name}|${f_size}" >> "${UL_PROGRESS_FILE}"

        # Background the upload body directly — $! captures exactly this process,
        # with no internal & inside the function to pollute it.
        _upload_one_file_body "$f_name" "$f_size" "$f_href" &
        ul_pids+=($!)

        # Drain AFTER enqueuing so we always have UL_PARALLEL_JOBS running concurrently
        if ! _drain_to_limit "$UL_PARALLEL_JOBS" ul_pids; then
            tail -20 "${UL_CHUNK_LOG}" >&2
            die "A file upload job failed — see ${UL_CHUNK_LOG}"
        fi
    done < "${FILE_MANIFEST}"
    rm -f "${FILE_MANIFEST}"
    rm -rf "${_UL_LOCK_DIR}"

    log "Waiting for all ${ul_file_num} file uploads to complete …"
    ul_failed=0
    for pid in "${ul_pids[@]+"${ul_pids[@]}"}"; do
        if ! wait "$pid"; then ul_failed=1; fi
    done

    # Signal progress monitor to do a final render and exit; flush buffered log messages
    touch "${UL_PROGRESS_FILE}.done"
    wait "$_PROGRESS_PID" 2>/dev/null || true
    rm -f "${UL_PROGRESS_FILE}" "${UL_PROGRESS_FILE}.done"
    _progress_quiet_stop

    if [ "$ul_failed" -ne 0 ]; then
        tail -40 "${UL_CHUNK_LOG}" >&2
        die "One or more file uploads failed — see ${UL_CHUNK_LOG}"
    fi

    log "✔ All ${ul_file_num} file(s) uploaded successfully."
    touch "$TRANSFER_DONE"

    # ── Poll until VCD marks template READY (status=8) ────────────────────────
    log "Polling destination VCD for template readiness …"
    POLL_INTERVAL=30
    POLL_MAX=480    # 4 hours max
    poll=0

    while [ "$poll" -lt "$POLL_MAX" ]; do
        TMPL_XML=$(curl --silent --insecure \
            -H "Accept: application/*+xml;version=${VCD_API_VERSION}" \
            -H "Authorization: Bearer $(cat "${DST_TOKEN_FILE}")" \
            "https://${DST_VCD_HOST}/api/query?type=vAppTemplate&filter=name==${VCD_TEMPLATE}" \
            || true)

        STATUS=$(echo "$TMPL_XML" \
            | tr '\n' ' ' \
            | grep -oP '<VAppTemplateRecord[^>]+/>' \
            | grep -P "catalogName=\"${DST_VCD_CATALOG}\"" \
            | grep -oP '(?<=status=")[^"]+' | head -1 || true)

        _TASK_PROGRESS=$(echo "$TMPL_XML" \
            | grep -oP '(?<=progress=")[^"]+' | head -1 || true)
        _TASK_OP=$(echo "$TMPL_XML" \
            | grep -oP '(?<=operationName=")[^"]+' | head -1 || true)

        _POLL_DETAIL=""
        [ -n "$_TASK_PROGRESS" ] && _POLL_DETAIL="${_POLL_DETAIL} progress=${_TASK_PROGRESS}%"
        [ -n "$_TASK_OP" ]       && _POLL_DETAIL="${_POLL_DETAIL} op=${_TASK_OP}"

        log "  Template status=${STATUS:-unknown}${_POLL_DETAIL}  (poll $((poll+1))/${POLL_MAX})"

        if [ "${STATUS}" = "8" ]; then
            log "✔ Template is READY in ${DST_VCD_CATALOG}."
            touch "$TRANSFER_DONE"
            break
        fi
        [ "${STATUS}" = "-1" ] && \
            die "VCD reported status=-1 (ERROR). Check VCD UI and ${LOG_DIR}/"

        sleep "$POLL_INTERVAL"
        poll=$(( poll + 1 ))
    done

    if [ "$poll" -ge "$POLL_MAX" ]; then
        die "Timed out waiting for template READY after $((POLL_MAX * POLL_INTERVAL / 60)) min. " \
            "Check VCD UI at https://${DST_VCD_HOST} and re-run to retry."
    fi

fi  # end TRANSFER_DONE block


# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Migration Complete                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "OVF bundle retained in staging for validation:"
echo "  ${OVF_BUNDLE_DIR}/"
echo ""
echo "After confirming the template is READY in ${DST_VCD_CATALOG}:"
echo "  rm -rf  '${OVF_BUNDLE_DIR}/'"
echo ""

END_TIME=$(date +%s)
RUNTIME=$(( END_TIME - START_TIME ))
log "Total runtime: $((RUNTIME/3600))h $(((RUNTIME%3600)/60))m $((RUNTIME%60))s"
