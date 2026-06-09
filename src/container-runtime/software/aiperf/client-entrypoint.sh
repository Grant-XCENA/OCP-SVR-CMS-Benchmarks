#!/usr/bin/env bash
# =============================================================================
# AIPerf Client Entrypoint
#
# Waits for the lmcache-server to be ready on localhost:30080, then runs
# AIPerf profile against it. Produces CMS-format JSON/CSV + HTML report.
# =============================================================================

# Source CMS common library
if [ -f /opt/cms-utils/cms_common.sh ]; then
    source /opt/cms-utils/cms_common.sh
else
    echo "[ERROR] CMS common library not found"
    exit 1
fi

CMS_SCRIPT_NAME="aiperf-client"
CMS_VERSION="1.0.0"

RESULTS_MOUNT="/opt/aiperf-bench/container_results"
AIPERF_DIR="/opt/aiperf-bench"
SUITE_NAME="${AIPERF_SUITE_NAME:-ocp-cms-aiperf}"

CMS_OUTPUT_PATH="${RESULTS_MOUNT}"
mkdir -p "${CMS_OUTPUT_PATH}"

# Archive previous run
_existing=$(find "${CMS_OUTPUT_PATH}" -mindepth 1 -maxdepth 1 -not -name "previous_runs" 2>/dev/null)
if [ -n "${_existing}" ]; then
    _ts=$(date '+%Y%m%d-%H%M%S')
    _archive="${CMS_OUTPUT_PATH}/previous_runs/${_ts}"
    mkdir -p "${_archive}"
    for _item in "${CMS_OUTPUT_PATH}"/*; do
        [ "$(basename "${_item}")" = "previous_runs" ] && continue
        mv "${_item}" "${_archive}/" 2>/dev/null || true
    done
fi

cms_trap_ctrlc
cms_log_stdout_stderr "${CMS_OUTPUT_PATH}"
cms_display_start_info "aiperf-client ${SUITE_NAME}"

cms_log_info "SUITE_NAME       : ${SUITE_NAME}"
cms_log_info "LMCACHE_BACKEND  : ${LMCACHE_BACKEND:-cpu_offload}"
cms_log_info "MODEL            : ${AIPERF_MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
cms_log_info "ENDPOINT_TYPE    : ${AIPERF_ENDPOINT_TYPE:-chat}"
cms_log_info "CONCURRENCY      : ${AIPERF_CONCURRENCY:-10}"
cms_log_info "REQUEST_COUNT    : ${AIPERF_REQUEST_COUNT:-100}"

# -------------------------------------------------------------------------
# Collect system BOM
# -------------------------------------------------------------------------
cms_log_info "Collecting system information..."
cms_collect_sysinfo "${RESULTS_MOUNT}/sysinfo"
cms_query_topology

# -------------------------------------------------------------------------
# Install extra packages
# -------------------------------------------------------------------------
if [ -n "${EXTRA_PIP_PACKAGES:-}" ]; then
    pip install ${EXTRA_PIP_PACKAGES} || true
fi

# -------------------------------------------------------------------------
# Resolve serving endpoint URL
# -------------------------------------------------------------------------
SERVER_URL="${AIPERF_SERVER_URL:-http://localhost:30080}"
cms_log_info "SERVER_URL       : ${SERVER_URL}"

# -------------------------------------------------------------------------
# Wait for serving endpoint to be ready
# -------------------------------------------------------------------------
TIMEOUT=900
ELAPSED=0

cms_log_info "Waiting for serving endpoint: ${SERVER_URL}/v1/models"

while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    if curl -s "${SERVER_URL}/v1/models" > /dev/null 2>&1; then
        cms_log_info "Server is ready! (waited ${ELAPSED}s)"
        MODEL_RESPONSE=$(curl -s "${SERVER_URL}/v1/models")
        cms_log_info "Available models: ${MODEL_RESPONSE}"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        cms_log_info "Still waiting for server... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    cms_log_error "Timed out waiting for serving endpoint (${TIMEOUT}s)"
    cms_log_error "Is the lmcache-server container running?"
    exit 1
fi

# -------------------------------------------------------------------------
# Extract model name from server
# -------------------------------------------------------------------------
MODEL_KEY=$(curl -s "${SERVER_URL}/v1/models" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data['data'][0]['id'])
except:
    print('${AIPERF_MODEL:-meta-llama/Llama-3.1-8B-Instruct}')
" 2>/dev/null)
cms_log_info "Model key: ${MODEL_KEY}"

# -------------------------------------------------------------------------
# Build AIPerf command
# -------------------------------------------------------------------------
ARTIFACT_DIR="${RESULTS_MOUNT}/aiperf_results"
mkdir -p "${ARTIFACT_DIR}"

MODEL="${AIPERF_MODEL:-${MODEL_KEY}}"
ENDPOINT_TYPE="${AIPERF_ENDPOINT_TYPE:-chat}"
CONCURRENCY="${AIPERF_CONCURRENCY:-10}"
REQUEST_COUNT="${AIPERF_REQUEST_COUNT:-100}"
STREAMING="${AIPERF_STREAMING:-true}"
ISL="${AIPERF_ISL:-}"
OSL="${AIPERF_OSL:-}"
REQUEST_RATE="${AIPERF_REQUEST_RATE:-}"
WARMUP_COUNT="${AIPERF_WARMUP_REQUEST_COUNT:-5}"
TOKENIZER="${AIPERF_TOKENIZER:-}"
NUM_PROFILE_RUNS="${AIPERF_NUM_PROFILE_RUNS:-1}"

# Strip protocol/port to get just host:port for --url
AIPERF_URL=$(echo "${SERVER_URL}" | sed 's|^https\?://||')

# =========================================================================
# SWEEP HELPER FUNCTIONS
# =========================================================================

# _csv_field <csv_string> <1-based-index> <total_levels> — returns value at
# position, repeating the last value if the list is shorter than total_levels.
_csv_field() {
    local csv="$1" idx="$2" total="$3"
    local -a arr
    IFS=',' read -r -a arr <<< "$csv"
    local len=${#arr[@]}
    if [ "$idx" -le "$len" ]; then
        echo "${arr[$((idx-1))]}"
    else
        echo "${arr[$((len-1))]}"
    fi
}

# _default_for <bundles> <target_pct> <field_index_1based> — look up a default
# parameter BY TARGET PERCENTAGE from the keyed DEFAULT_BUNDLES table.
# Field layout: 1=pct 2=turn_mean 3=turn_stddev 4=turn_delay 5=isl 6=osl
#               7=concurrency 8=shared_prompt 9=conv_num 10=dataset_entries
# If the target pct isn't in the table, falls back to the nearest defined pct.
_default_for() {
    local bundles="$1" target="$2" field="$3"
    local line best_line best_diff diff pct
    best_line=""
    best_diff=100000
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        pct="${line%%:*}"
        if [ "$pct" = "$target" ]; then
            echo "$line" | cut -d: -f"$field"
            return
        fi
        # track nearest for graceful fallback on arbitrary custom pct values
        diff=$(( pct > target ? pct - target : target - pct ))
        if [ "$diff" -lt "$best_diff" ]; then
            best_diff="$diff"
            best_line="$line"
        fi
    done <<< "$bundles"
    [ -n "$best_line" ] && echo "$best_line" | cut -d: -f"$field"
}

# _param_for <override_csv> <idx> <total> <target_pct> <field_index> — return
# the user override (positional) if provided, else the percentage-keyed default.
_param_for() {
    local override="$1" idx="$2" total="$3" target="$4" field="$5"
    if [ -n "$override" ]; then
        _csv_field "$override" "$idx" "$total"
    else
        _default_for "$DEFAULT_BUNDLES" "$target" "$field"
    fi
}

# _scrape_metric <metrics_url> <metric_name> — return Prometheus gauge value
_scrape_metric() {
    local url="$1" name="$2"
    local val
    val=$(curl -sf "$url" 2>/dev/null \
        | grep "^${name}" | grep -v '^#' | head -1 | awk '{print $2}') || true
    echo "${val:-N/A}"
}

# _get_cache_hit_rate <metrics_url> — try several vLLM prefix-cache metrics
_get_cache_hit_rate() {
    local url="$1"
    local hr
    hr=$(_scrape_metric "$url" "vllm:prefix_cache_hit_rate")
    if [ "$hr" != "N/A" ] && [ -n "$hr" ]; then
        echo "$hr" | awk '{printf "%.1f", $1 * 100}'; return
    fi
    hr=$(_scrape_metric "$url" "vllm:prefix_cache_block_hit_rate")
    if [ "$hr" != "N/A" ] && [ -n "$hr" ]; then
        echo "$hr" | awk '{printf "%.1f", $1 * 100}'; return
    fi
    local hits misses
    hits=$(_scrape_metric "$url" "vllm:prefix_cache_queries_hit_total")
    misses=$(_scrape_metric "$url" "vllm:prefix_cache_queries_miss_total")
    if [ "$hits" != "N/A" ] && [ "$misses" != "N/A" ]; then
        echo "$hits $misses" | awk '{t=$1+$2; if(t>0) printf "%.1f",$1/t*100; else print "N/A"}'
        return
    fi
    echo "N/A"
}

# _get_gpu_utilization — nvidia-smi fallback
_get_gpu_utilization() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null \
            | awk '{sum+=$1;n++} END{if(n>0) printf "%.1f",sum/n; else print "N/A"}'
    else
        echo "N/A"
    fi
}

# _sample_metrics_bg <outfile> <metrics_url> <interval> — background sampler
_sample_metrics_bg() {
    local outfile="$1" url="$2" interval="$3"
    echo "timestamp,cache_hit_pct,gpu_util_pct" > "$outfile"
    while true; do
        local ts hit gpu
        ts=$(date '+%s')
        hit=$(_get_cache_hit_rate "$url")
        gpu=$(_get_gpu_utilization)
        echo "${ts},${hit},${gpu}" >> "$outfile"
        sleep "$interval"
    done
}

# =========================================================================
# BRANCH: Sweep Mode vs Single-Run Mode
# =========================================================================
SWEEP_ENABLED="${AIPERF_SWEEP_ENABLED:-false}"

if [ "${SWEEP_ENABLED}" = "true" ]; then
    # =====================================================================
    # KV CACHE PARAMETER SWEEP
    # =====================================================================
    cms_log_info "=== KV Cache Parameter Sweep Mode ==="

    # -- Sweep configuration --
    SWEEP_LEVELS_CSV="${AIPERF_SWEEP_LEVELS:-95,90,85,80,75,50,25,15,10,5}"
    IFS=',' read -r -a SWEEP_LEVELS <<< "$SWEEP_LEVELS_CSV"
    NUM_LEVELS=${#SWEEP_LEVELS[@]}

    # Built-in defaults are keyed BY TARGET PERCENTAGE, not by position.
    # This matters when the user runs a SUBSET of levels (e.g. "95,50,5"):
    # the 50% level must get the 50% bundle, not whatever sits at position 2
    # of a positional array. Each entry is:
    #   pct:turn_mean:turn_stddev:turn_delay:isl:osl:concurrency:shared_prompt:conv_num:dataset_entries
    DEFAULT_BUNDLES="\
95:15:2:200:50:100:3:2000:30:100
90:12:2:500:100:120:5:1500:30:150
85:10:3:1000:150:150:8:1000:40:200
80:8:2:2000:200:150:12:800:40:250
75:6:2:3000:300:150:15:500:50:300
50:4:1:5000:500:150:25:200:60:400
25:2:1:10000:800:150:40:100:80:500
15:2:0:15000:1000:200:60:0:100:600
10:1:0:20000:1200:200:80:0:120:700
5:1:0:0:1500:200:100:0:200:1000"

    # User override arrays (positional, aligned with THEIR SWEEP_LEVELS).
    # Empty string => use percentage-keyed defaults for that parameter.
    CFG_TURN_MEAN="${AIPERF_SWEEP_TURN_MEAN:-}"
    CFG_TURN_STDDEV="${AIPERF_SWEEP_TURN_STDDEV:-}"
    CFG_TURN_DELAY="${AIPERF_SWEEP_TURN_DELAY_MS:-}"
    CFG_ISL="${AIPERF_SWEEP_ISL:-}"
    CFG_OSL="${AIPERF_SWEEP_OSL:-}"
    CFG_CONCURRENCY="${AIPERF_SWEEP_CONCURRENCY:-}"
    CFG_SHARED_PROMPT="${AIPERF_SWEEP_SHARED_PROMPT:-}"
    CFG_CONV_NUM="${AIPERF_SWEEP_CONV_NUM:-}"
    CFG_DATASET_ENTRIES="${AIPERF_SWEEP_DATASET_ENTRIES:-}"

    SWEEP_COOLDOWN="${AIPERF_SWEEP_COOLDOWN:-30}"
    SWEEP_DURATION="${AIPERF_SWEEP_DURATION:-}"
    SWEEP_METRICS_INTERVAL="${AIPERF_SWEEP_METRICS_INTERVAL:-5}"
    SWEEP_METRICS_URL="${AIPERF_SWEEP_METRICS_URL:-http://localhost:30080/metrics}"
    SWEEP_GPU_FLOOR="${AIPERF_SWEEP_GPU_UTIL_FLOOR:-75}"
    SWEEP_CONN_STRATEGY="${AIPERF_SWEEP_CONNECTION_STRATEGY:-sticky-user-sessions}"
    SWEEP_SKIP_LEVELS="${AIPERF_SWEEP_SKIP_LEVELS:-}"
    SWEEP_DRY_RUN="${AIPERF_SWEEP_DRY_RUN:-false}"
    SWEEP_NATIVE_PASSTHROUGH="${AIPERF_SWEEP_NATIVE_PASSTHROUGH:-false}"
    SWEEP_NUM_PROFILE_RUNS="${AIPERF_SWEEP_NUM_PROFILE_RUNS:-1}"
    SWEEP_PARAM_SWEEP_MODE="${AIPERF_SWEEP_PARAM_SWEEP_MODE:-repeated}"

    SWEEP_DIR="${RESULTS_MOUNT}/sweep_results"
    SWEEP_CSV="${SWEEP_DIR}/sweep_summary.csv"
    mkdir -p "${SWEEP_DIR}"

    cms_log_info "Sweep levels:    ${SWEEP_LEVELS_CSV}"
    cms_log_info "Cooldown:        ${SWEEP_COOLDOWN}s"
    [ -n "${SWEEP_DURATION}" ] && cms_log_info "Duration:        ${SWEEP_DURATION}s per level"
    cms_log_info "Metrics URL:     ${SWEEP_METRICS_URL}"
    cms_log_info "GPU util floor:  ${SWEEP_GPU_FLOOR}%"
    [ -n "${SWEEP_SKIP_LEVELS}" ] && cms_log_info "Skip levels:     ${SWEEP_SKIP_LEVELS}"
    [ "${SWEEP_NUM_PROFILE_RUNS}" -gt 1 ] 2>/dev/null && cms_log_info "Profile runs:    ${SWEEP_NUM_PROFILE_RUNS} (native confidence aggregation, mode=${SWEEP_PARAM_SWEEP_MODE})"
    [ "${SWEEP_DRY_RUN}" = "true" ] && cms_log_info "*** DRY RUN — commands logged but NOT executed ***"

    # =====================================================================
    # NATIVE PASSTHROUGH MODE
    # ---------------------------------------------------------------------
    # When the user wants a pure single-axis parameter sweep WITHOUT
    # cache-hit-rate targeting, hand the whole thing to native AIPerf in one
    # invocation (e.g. --concurrency 10,20,50,100). AIPerf then owns the
    # parameter expansion, per-value artifact layout, and the documented
    # sweep_aggregate/ output (best configs + Pareto). We do NOT do cache
    # reset or Prometheus verification here, because by definition this mode
    # isn't targeting a cache-hit percentage.
    #
    # Set AIPERF_SWEEP_NATIVE_PASSTHROUGH=true and provide a sweep axis via
    # AIPERF_EXTRA_ARGS, e.g.:
    #   AIPERF_SWEEP_NATIVE_PASSTHROUGH=true
    #   AIPERF_EXTRA_ARGS=--concurrency 10,20,50,100
    # =====================================================================
    if [ "${SWEEP_NATIVE_PASSTHROUGH}" = "true" ]; then
        cms_log_info "=== Native AIPerf passthrough sweep (no cache-hit targeting) ==="

        NATIVE_ARTIFACT="${ARTIFACT_DIR}/native_sweep"
        mkdir -p "${NATIVE_ARTIFACT}"

        NATIVE_ARGS=(
            profile
            --model "${MODEL}"
            --endpoint-type "${ENDPOINT_TYPE}"
            --url "${AIPERF_URL}"
            --artifact-dir "${NATIVE_ARTIFACT}"
            --warmup-request-count "${WARMUP_COUNT}"
        )
        [ "${STREAMING}" = "true" ] && NATIVE_ARGS+=(--streaming)
        [ -n "${TOKENIZER}" ] && NATIVE_ARGS+=(--tokenizer "${TOKENIZER}")
        [ -n "${SWEEP_DURATION}" ] && NATIVE_ARGS+=(--benchmark-duration "${SWEEP_DURATION}")
        if [ "${SWEEP_NUM_PROFILE_RUNS}" -gt 1 ] 2>/dev/null; then
            NATIVE_ARGS+=(--num-profile-runs "${SWEEP_NUM_PROFILE_RUNS}" --parameter-sweep-mode "${SWEEP_PARAM_SWEEP_MODE}")
        fi
        # The sweep axis itself comes from AIPERF_EXTRA_ARGS (e.g. --concurrency 10,20,50)
        if [ -n "${AIPERF_EXTRA_ARGS:-}" ]; then
            # shellcheck disable=SC2206
            NATIVE_ARGS+=(${AIPERF_EXTRA_ARGS})
        fi

        cms_log_info "Command: aiperf ${NATIVE_ARGS[*]}"

        BENCH_EXIT=0
        cd "${AIPERF_DIR}"
        export HF_TOKEN="${HF_TOKEN:-}"

        if [ "${SWEEP_DRY_RUN}" = "true" ]; then
            cms_log_info "[DRY RUN] Skipping native sweep execution"
            echo "aiperf ${NATIVE_ARGS[*]}" >> "${SWEEP_DIR}/dry_run_commands.txt"
        else
            aiperf "${NATIVE_ARGS[@]}" 2>&1 || BENCH_EXIT=$?
            [ ${BENCH_EXIT} -ne 0 ] && cms_log_warn "Native sweep exited with code ${BENCH_EXIT}"
        fi

        cms_log_info "=== Native passthrough sweep complete ==="
        # Record metadata and skip the targeted-loop entirely
        mkdir -p "${RESULTS_MOUNT}/config"
        cat > "${RESULTS_MOUNT}/config/sweep_mode_info.json" << NSJSON
{ "sweep_mode": "native_passthrough", "num_profile_runs": ${SWEEP_NUM_PROFILE_RUNS}, "parameter_sweep_mode": "${SWEEP_PARAM_SWEEP_MODE}" }
NSJSON
        # Jump past the targeted loop by using a guard variable
        SWEEP_TARGETED=false
    else
        SWEEP_TARGETED=true
    fi

    # CSV header (targeted mode only)
    if [ "${SWEEP_TARGETED}" = "true" ]; then
    cat > "${SWEEP_CSV}" << 'CSVHDR'
target_hit_pct,turn_mean,turn_stddev,concurrency,isl,osl,shared_prompt,delay_ms,conv_num,dataset_entries,actual_cache_hit_pct,gpu_util_pct,status
CSVHDR

    BENCH_EXIT=0
    cd "${AIPERF_DIR}"
    export HF_TOKEN="${HF_TOKEN:-}"

    for (( i=0; i<NUM_LEVELS; i++ )); do
        TARGET="${SWEEP_LEVELS[$i]}"
        IDX=$((i + 1))

        # Skip-levels check
        if [ -n "${SWEEP_SKIP_LEVELS}" ]; then
            if echo ",${SWEEP_SKIP_LEVELS}," | grep -q ",${TARGET},"; then
                cms_log_info "SKIPPING ${TARGET}% (in AIPERF_SWEEP_SKIP_LEVELS)"
                continue
            fi
        fi

        # Extract per-level params. Override arrays (if set) are positional
        # against the user's SWEEP_LEVELS; otherwise defaults are looked up by
        # target percentage so subsets like "95,50,5" map to the right bundles.
        # Field indices into DEFAULT_BUNDLES:
        #   2=turn_mean 3=turn_stddev 4=turn_delay 5=isl 6=osl
        #   7=concurrency 8=shared_prompt 9=conv_num 10=dataset_entries
        S_TURN_MEAN=$(_param_for "$CFG_TURN_MEAN" "$IDX" "$NUM_LEVELS" "$TARGET" 2)
        S_TURN_STDDEV=$(_param_for "$CFG_TURN_STDDEV" "$IDX" "$NUM_LEVELS" "$TARGET" 3)
        S_TURN_DELAY=$(_param_for "$CFG_TURN_DELAY" "$IDX" "$NUM_LEVELS" "$TARGET" 4)
        S_ISL=$(_param_for "$CFG_ISL" "$IDX" "$NUM_LEVELS" "$TARGET" 5)
        S_OSL=$(_param_for "$CFG_OSL" "$IDX" "$NUM_LEVELS" "$TARGET" 6)
        S_CONCURRENCY=$(_param_for "$CFG_CONCURRENCY" "$IDX" "$NUM_LEVELS" "$TARGET" 7)
        S_SHARED_PROMPT=$(_param_for "$CFG_SHARED_PROMPT" "$IDX" "$NUM_LEVELS" "$TARGET" 8)
        S_CONV_NUM=$(_param_for "$CFG_CONV_NUM" "$IDX" "$NUM_LEVELS" "$TARGET" 9)
        S_DATASET_ENTRIES=$(_param_for "$CFG_DATASET_ENTRIES" "$IDX" "$NUM_LEVELS" "$TARGET" 10)

        LEVEL_DIR="${SWEEP_DIR}/hit_${TARGET}pct"
        LEVEL_ARTIFACT="${LEVEL_DIR}/artifacts"
        LEVEL_METRICS="${LEVEL_DIR}/metrics_timeseries.csv"
        mkdir -p "${LEVEL_ARTIFACT}"

        cms_log_info "---------------------------------------------------"
        cms_log_info "SWEEP ${IDX}/${NUM_LEVELS}: Target ${TARGET}% cache hit"
        cms_log_info "---------------------------------------------------"
        cms_log_info "  Turns: ${S_TURN_MEAN}±${S_TURN_STDDEV}  Delay: ${S_TURN_DELAY}ms"
        cms_log_info "  ISL: ${S_ISL}  OSL: ${S_OSL}  Concurrency: ${S_CONCURRENCY}"
        cms_log_info "  Shared prompt: ${S_SHARED_PROMPT}  Conversations: ${S_CONV_NUM}"

        # Build per-level aiperf command
        LEVEL_ARGS=(
            profile
            --model "${MODEL}"
            --endpoint-type "${ENDPOINT_TYPE}"
            --url "${AIPERF_URL}"
            --artifact-dir "${LEVEL_ARTIFACT}"
            --warmup-request-count "${WARMUP_COUNT}"
            --synthetic-input-tokens-mean "${S_ISL}"
            --output-tokens-mean "${S_OSL}"
            --num-dataset-entries "${S_DATASET_ENTRIES}"
        )

        [ "${STREAMING}" = "true" ] && LEVEL_ARGS+=(--streaming)
        [ -n "${TOKENIZER}" ] && LEVEL_ARGS+=(--tokenizer "${TOKENIZER}")

        # Multi-turn vs single-turn
        if [ "${S_TURN_MEAN}" -gt 1 ] 2>/dev/null; then
            LEVEL_ARGS+=(
                --conversation-num "${S_CONV_NUM}"
                --conversation-turn-mean "${S_TURN_MEAN}"
                --conversation-turn-stddev "${S_TURN_STDDEV}"
                --conversation-turn-delay-mean "${S_TURN_DELAY}"
                --concurrency "${S_CONCURRENCY}"
                --connection-reuse-strategy "${SWEEP_CONN_STRATEGY}"
            )
            # Add delay stddev (50% of mean)
            if [ "${S_TURN_DELAY}" -gt 0 ] 2>/dev/null; then
                local_delay_std=$((S_TURN_DELAY / 2))
                LEVEL_ARGS+=(--conversation-turn-delay-stddev "${local_delay_std}")
            fi
        else
            LEVEL_ARGS+=(
                --request-count "${S_CONV_NUM}"
                --concurrency "${S_CONCURRENCY}"
            )
        fi

        # Shared system prompt
        if [ "${S_SHARED_PROMPT}" -gt 0 ] 2>/dev/null; then
            LEVEL_ARGS+=(--shared-system-prompt-length "${S_SHARED_PROMPT}")
        fi

        # Per-level benchmark duration
        if [ -n "${SWEEP_DURATION}" ]; then
            LEVEL_ARGS+=(--benchmark-duration "${SWEEP_DURATION}")
        fi

        # Native multi-run confidence aggregation (per level).
        # When >1, AIPerf produces its own aggregate/ dir with mean/std/CI
        # for this level, which the parser surfaces alongside the cache-hit
        # metadata. This is the native-AIPerf half of the hybrid.
        if [ "${SWEEP_NUM_PROFILE_RUNS}" -gt 1 ] 2>/dev/null; then
            LEVEL_ARGS+=(--num-profile-runs "${SWEEP_NUM_PROFILE_RUNS}" --parameter-sweep-mode "${SWEEP_PARAM_SWEEP_MODE}")
        fi

        # Goodput SLOs passthrough
        [ -n "${AIPERF_GOODPUT_TTFT:-}" ] && LEVEL_ARGS+=(--goodput "ttft:${AIPERF_GOODPUT_TTFT}")
        [ -n "${AIPERF_GOODPUT_LATENCY:-}" ] && LEVEL_ARGS+=(--goodput "request_latency:${AIPERF_GOODPUT_LATENCY}")

        # Extra args passthrough
        if [ -n "${AIPERF_EXTRA_ARGS:-}" ]; then
            # shellcheck disable=SC2206
            LEVEL_ARGS+=(${AIPERF_EXTRA_ARGS})
        fi

        cms_log_info "  Command: aiperf ${LEVEL_ARGS[*]}"

        # ----- DRY RUN: log command and write stub results, skip execution -----
        if [ "${SWEEP_DRY_RUN}" = "true" ]; then
            cms_log_info "  [DRY RUN] Skipping execution"

            # Write stub metadata so parse_results.py can still validate
            cat > "${LEVEL_DIR}/sweep_level_info.json" << DRYJSON
{
    "sweep_mode": true,
    "dry_run": true,
    "target_cache_hit_pct": ${TARGET},
    "turn_mean": ${S_TURN_MEAN},
    "turn_stddev": ${S_TURN_STDDEV},
    "turn_delay_ms": ${S_TURN_DELAY},
    "isl": ${S_ISL},
    "osl": ${S_OSL},
    "concurrency": ${S_CONCURRENCY},
    "shared_system_prompt_length": ${S_SHARED_PROMPT},
    "conversation_num": ${S_CONV_NUM},
    "dataset_entries": ${S_DATASET_ENTRIES},
    "actual_cache_hit_pct": "DRY_RUN",
    "gpu_util_pct": "DRY_RUN",
    "status": "dry_run"
}
DRYJSON
            # Write to sweep CSV
            echo "${TARGET},${S_TURN_MEAN},${S_TURN_STDDEV},${S_CONCURRENCY},${S_ISL},${S_OSL},${S_SHARED_PROMPT},${S_TURN_DELAY},${S_CONV_NUM},${S_DATASET_ENTRIES},DRY_RUN,DRY_RUN,dry_run" \
                >> "${SWEEP_CSV}"

            # Log the full command to a file for regression test collection
            echo "aiperf ${LEVEL_ARGS[*]}" >> "${SWEEP_DIR}/dry_run_commands.txt"

            # Skip to cooldown
            if [ ${IDX} -lt ${NUM_LEVELS} ]; then
                cms_log_info "  Cooldown skipped (dry run)"
            fi
            continue
        fi

        # ----- LIVE EXECUTION -----

        # Try to reset prefix cache between levels
        curl -sf -X POST "http://localhost:30080/reset_prefix_cache" &>/dev/null || true
        sleep 2

        # Start background metric sampler
        _sample_metrics_bg "${LEVEL_METRICS}" "${SWEEP_METRICS_URL}" "${SWEEP_METRICS_INTERVAL}" &
        SAMPLER_PID=$!

        # Run benchmark
        LEVEL_EXIT=0
        aiperf "${LEVEL_ARGS[@]}" > "${LEVEL_DIR}/aiperf_stdout.log" 2>&1 || LEVEL_EXIT=$?

        # Stop sampler
        kill "${SAMPLER_PID}" 2>/dev/null || true
        wait "${SAMPLER_PID}" 2>/dev/null || true

        if [ ${LEVEL_EXIT} -ne 0 ]; then
            cms_log_warn "Sweep level ${TARGET}% exited with code ${LEVEL_EXIT}"
            BENCH_EXIT=${LEVEL_EXIT}
        fi

        # Compute average metrics from timeseries
        local_hit="N/A"
        local_gpu="N/A"
        if [ -f "${LEVEL_METRICS}" ] && [ "$(wc -l < "${LEVEL_METRICS}")" -gt 2 ]; then
            local_hit=$(tail -n +2 "${LEVEL_METRICS}" | awk -F',' '
                $2 != "N/A" {sum+=$2; n++} END {if(n>0) printf "%.1f",sum/n; else print "N/A"}
            ')
            local_gpu=$(tail -n +2 "${LEVEL_METRICS}" | awk -F',' '
                $3 != "N/A" {sum+=$3; n++} END {if(n>0) printf "%.1f",sum/n; else print "N/A"}
            ')
        fi

        local_status="success"
        [ ${LEVEL_EXIT} -ne 0 ] && local_status="failed"

        cms_log_info "  Actual cache hit: ${local_hit}%  GPU util: ${local_gpu}%"

        # GPU floor check
        if [ "${local_gpu}" != "N/A" ]; then
            local_gpu_int=$(echo "${local_gpu}" | awk '{printf "%d",$1}')
            if [ "${local_gpu_int}" -lt "${SWEEP_GPU_FLOOR}" ]; then
                cms_log_warn "  GPU util ${local_gpu}% < ${SWEEP_GPU_FLOOR}% floor"
            fi
        fi

        # Append to sweep CSV
        echo "${TARGET},${S_TURN_MEAN},${S_TURN_STDDEV},${S_CONCURRENCY},${S_ISL},${S_OSL},${S_SHARED_PROMPT},${S_TURN_DELAY},${S_CONV_NUM},${S_DATASET_ENTRIES},${local_hit},${local_gpu},${local_status}" \
            >> "${SWEEP_CSV}"

        # Write per-level metadata JSON (for parse_results.py)
        cat > "${LEVEL_DIR}/sweep_level_info.json" << LEVELJSON
{
    "sweep_mode": true,
    "target_cache_hit_pct": ${TARGET},
    "turn_mean": ${S_TURN_MEAN},
    "turn_stddev": ${S_TURN_STDDEV},
    "turn_delay_ms": ${S_TURN_DELAY},
    "isl": ${S_ISL},
    "osl": ${S_OSL},
    "concurrency": ${S_CONCURRENCY},
    "shared_system_prompt_length": ${S_SHARED_PROMPT},
    "conversation_num": ${S_CONV_NUM},
    "dataset_entries": ${S_DATASET_ENTRIES},
    "actual_cache_hit_pct": "${local_hit}",
    "gpu_util_pct": "${local_gpu}",
    "status": "${local_status}"
}
LEVELJSON

        # Cooldown between levels (skip after last)
        if [ ${IDX} -lt ${NUM_LEVELS} ]; then
            cms_log_info "  Cooling down ${SWEEP_COOLDOWN}s..."
            sleep "${SWEEP_COOLDOWN}"
        fi
    done

    # Copy sweep artifacts into aiperf_results for parse_results.py to find
    cp -r "${SWEEP_DIR}"/ "${ARTIFACT_DIR}/" 2>/dev/null || true

    cms_log_info "=== Sweep complete: ${SWEEP_CSV} ==="
    fi  # end targeted-mode (SWEEP_TARGETED) block

else
    # =====================================================================
    # STANDARD SINGLE-RUN MODE (original behavior)
    # =====================================================================

    AIPERF_ARGS=(
        profile
        --model "${MODEL}"
        --endpoint-type "${ENDPOINT_TYPE}"
        --url "${AIPERF_URL}"
        --artifact-dir "${ARTIFACT_DIR}"
        --warmup-request-count "${WARMUP_COUNT}"
    )

    # Streaming
    if [ "${STREAMING}" = "true" ]; then
        AIPERF_ARGS+=(--streaming)
    fi

    # Concurrency vs request-rate mode
    if [ -n "${REQUEST_RATE}" ]; then
        AIPERF_ARGS+=(--request-rate "${REQUEST_RATE}" --request-count "${REQUEST_COUNT}")
    else
        AIPERF_ARGS+=(--concurrency "${CONCURRENCY}" --request-count "${REQUEST_COUNT}")
    fi

    # Input/output sequence lengths
    # Input/output sequence lengths.
    # Use the long-form flags (--synthetic-input-tokens-mean / --output-tokens-mean)
    # for consistency with the sweep path. These are the canonical names;
    # --isl/--osl are aliases for the same options.
    [ -n "${ISL}" ] && AIPERF_ARGS+=(--synthetic-input-tokens-mean "${ISL}")
    [ -n "${OSL}" ] && AIPERF_ARGS+=(--output-tokens-mean "${OSL}")

    # Tokenizer
    [ -n "${TOKENIZER}" ] && AIPERF_ARGS+=(--tokenizer "${TOKENIZER}")

    # Multi-run confidence
    [ "${NUM_PROFILE_RUNS}" -gt 1 ] 2>/dev/null && AIPERF_ARGS+=(--num-profile-runs "${NUM_PROFILE_RUNS}")

    # Public dataset
    if [ -n "${AIPERF_PUBLIC_DATASET:-}" ]; then
        AIPERF_ARGS+=(--public-dataset "${AIPERF_PUBLIC_DATASET}")
    fi

    # Input file (custom prompts / trace)
    if [ -n "${AIPERF_INPUT_FILE:-}" ]; then
        AIPERF_ARGS+=(--input-file "${AIPERF_INPUT_FILE}")
        [ -n "${AIPERF_CUSTOM_DATASET_TYPE:-}" ] && \
            AIPERF_ARGS+=(--custom-dataset-type "${AIPERF_CUSTOM_DATASET_TYPE}")
    fi

    # Fixed schedule (trace replay)
    if [ "${AIPERF_FIXED_SCHEDULE:-false}" = "true" ]; then
        AIPERF_ARGS+=(--fixed-schedule)
    fi

    # Goodput SLOs
    [ -n "${AIPERF_GOODPUT_TTFT:-}" ] && AIPERF_ARGS+=(--goodput "ttft:${AIPERF_GOODPUT_TTFT}")
    [ -n "${AIPERF_GOODPUT_LATENCY:-}" ] && AIPERF_ARGS+=(--goodput "request_latency:${AIPERF_GOODPUT_LATENCY}")

    # Extra args passthrough
    if [ -n "${AIPERF_EXTRA_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        AIPERF_ARGS+=(${AIPERF_EXTRA_ARGS})
    fi

    # -------------------------------------------------------------------------
    # Run AIPerf
    # -------------------------------------------------------------------------
    cms_log_info "Starting AIPerf benchmark..."
    cms_log_info "Command: aiperf ${AIPERF_ARGS[*]}"

    BENCH_EXIT=0
    cd "${AIPERF_DIR}"

    export HF_TOKEN="${HF_TOKEN:-}"

    aiperf "${AIPERF_ARGS[@]}" 2>&1 || BENCH_EXIT=$?

    if [ ${BENCH_EXIT} -ne 0 ]; then
        cms_log_error "AIPerf exited with code ${BENCH_EXIT}"
    fi
fi

# -------------------------------------------------------------------------
# Record backend metadata
# -------------------------------------------------------------------------
mkdir -p "${RESULTS_MOUNT}/config"
cat > "${RESULTS_MOUNT}/config/lmcache_backend_info.json" << EOF
{
    "backend": "${LMCACHE_BACKEND:-cpu_offload}",
    "model": "${MODEL}",
    "max_model_len": "${VLLM_MAX_MODEL_LEN:-4096}",
    "endpoint_type": "${ENDPOINT_TYPE}",
    "concurrency": "${CONCURRENCY}",
    "request_count": "${REQUEST_COUNT}",
    "request_rate": "${REQUEST_RATE:-null}",
    "streaming": ${STREAMING},
    "sweep_enabled": ${SWEEP_ENABLED},
    "sweep_levels": "${AIPERF_SWEEP_LEVELS:-}"
}
EOF

# -------------------------------------------------------------------------
# Parse results into CMS format
# -------------------------------------------------------------------------
cms_log_info "Parsing results..."
python3 "${AIPERF_DIR}/parse_results.py" "${RESULTS_MOUNT}" "${SUITE_NAME}" || \
    cms_log_warn "Parser returned non-zero"

# -------------------------------------------------------------------------
# Generate HTML report + tarball
# -------------------------------------------------------------------------
cms_generate_report "${RESULTS_MOUNT}" "aiperf-${SUITE_NAME}" || true
cms_display_end_info
cms_package_results "${RESULTS_MOUNT}" || true

exit ${BENCH_EXIT}
