#!/usr/bin/env python3
"""
OCP SRV CMS - AIPerf Results Parser (parse_results.py)

AIPerf writes profile_export_aiperf.json with per-metric statistics
(avg, min, max, p50, p90, p99, std, etc.). This parser reads that
output and emits CMS-format JSON + CSV for the OCP report renderer.

Input layout (under <results_dir>/aiperf_results/):
    <model>-<endpoint_type>-<mode><N>/
        profile_export_aiperf.json
        profile_export_aiperf.csv
        profile_export.jsonl          (per-request detail)

Output:
    results_aiperf_<suite_name>.json   (combined, structured)
    results_aiperf_<suite_name>.csv    (flat table for HTML report)

Usage:
    python3 parse_results.py <results_dir> <suite_name>
"""

import csv
import glob
import json
import os
import sys
from datetime import datetime, timezone


def log(msg):
    print(f"[PARSER] {msg}")


def _safe_get(data, *keys, default=None):
    """Safely traverse nested dicts."""
    current = data
    for k in keys:
        if isinstance(current, dict) and k in current:
            current = current[k]
        else:
            return default
    return current


def _extract_metric(data, metric_tag):
    """Extract a metric dict from the aiperf JSON by tag name."""
    return data.get(metric_tag, None)


def _parse_aiperf_json(json_path):
    """
    Parse a single profile_export_aiperf.json file into a CMS record.

    AIPerf JSON structure (schema v1.1+):
    {
        "schema_version": "1.1",
        "aiperf_version": "0.8.0",
        "benchmark_id": "...",
        "input_config": { ... },
        "start_time": "2025-...",
        "end_time": "2025-...",
        "time_to_first_token": { "unit": "ms", "avg": ..., "p50": ..., "p99": ..., ... },
        "inter_token_latency": { ... },
        "request_latency": { ... },
        "output_token_throughput_per_request": { ... },
        "request_throughput": { ... },
        ...
    }
    """
    with open(json_path) as f:
        data = json.load(f)

    # Extract input config for metadata
    config = data.get("input_config", {})
    model = config.get("model", "unknown")
    endpoint_type = config.get("endpoint_type", "unknown")

    # Timing
    start_time = data.get("start_time")
    end_time = data.get("end_time")
    duration_s = None
    if start_time and end_time:
        try:
            t0 = datetime.fromisoformat(start_time)
            t1 = datetime.fromisoformat(end_time)
            duration_s = (t1 - t0).total_seconds()
        except (ValueError, TypeError):
            pass

    # Core metrics
    ttft = _extract_metric(data, "time_to_first_token")
    itl = _extract_metric(data, "inter_token_latency")
    req_lat = _extract_metric(data, "request_latency")
    req_tp = _extract_metric(data, "request_throughput")
    out_tp = _extract_metric(data, "output_token_throughput_per_request")
    osl = _extract_metric(data, "output_sequence_length")
    isl = _extract_metric(data, "input_sequence_length")

    # Total throughput metrics (may or may not be present)
    total_out_tp = _extract_metric(data, "output_token_throughput")
    total_in_tp = _extract_metric(data, "input_token_throughput")

    # Request count from output_sequence_length.count or config
    request_count = None
    if osl and osl.get("count"):
        request_count = osl["count"]
    elif config.get("request_count"):
        request_count = config["request_count"]

    # Concurrency / request rate
    concurrency = config.get("concurrency")
    request_rate = config.get("request_rate")

    def _get_stat(metric, stat, default=None):
        if metric is None:
            return default
        return metric.get(stat, default)

    record = {
        "source_file": os.path.relpath(json_path),
        "suite_name": "",  # filled by caller
        "timestamp": datetime.fromtimestamp(
            os.path.getmtime(json_path), tz=timezone.utc,
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "model": model,
        "endpoint_type": endpoint_type,
        "concurrency": concurrency,
        "request_rate": request_rate,
        "successful_requests": request_count,
        "benchmark_duration_s": duration_s,

        # Request throughput
        "request_throughput_req_per_s": _get_stat(req_tp, "avg"),

        # Token throughput
        "output_token_throughput_tok_per_s": _get_stat(total_out_tp, "avg"),
        "input_token_throughput_tok_per_s": _get_stat(total_in_tp, "avg"),

        # TTFT (ms)
        "ttft_avg_ms": _get_stat(ttft, "avg"),
        "ttft_p50_ms": _get_stat(ttft, "p50"),
        "ttft_p90_ms": _get_stat(ttft, "p90"),
        "ttft_p99_ms": _get_stat(ttft, "p99"),
        "ttft_min_ms": _get_stat(ttft, "min"),
        "ttft_max_ms": _get_stat(ttft, "max"),

        # Inter-token latency (ms)
        "itl_avg_ms": _get_stat(itl, "avg"),
        "itl_p50_ms": _get_stat(itl, "p50"),
        "itl_p90_ms": _get_stat(itl, "p90"),
        "itl_p99_ms": _get_stat(itl, "p99"),

        # Request latency (ms)
        "req_latency_avg_ms": _get_stat(req_lat, "avg"),
        "req_latency_p50_ms": _get_stat(req_lat, "p50"),
        "req_latency_p90_ms": _get_stat(req_lat, "p90"),
        "req_latency_p99_ms": _get_stat(req_lat, "p99"),

        # Sequence lengths
        "avg_input_tokens": _get_stat(isl, "avg"),
        "avg_output_tokens": _get_stat(osl, "avg"),

        # AIPerf metadata
        "aiperf_version": data.get("aiperf_version"),
        "schema_version": data.get("schema_version"),
    }

    return record


def _parse_sweep_level_info(json_path, ceiling_dir=None, max_levels=6):
    """
    Locate the sweep_level_info.json belonging to this profile result and
    return its parsed contents (or None).

    aiperf nests its results an unpredictable number of levels below the
    --artifact-dir we pass (it creates a run dir like
    "<model>-<endpoint>-<mode>N/", and may add "profile_runs/run_NNNN/" for
    multi-run). The sweep writes sweep_level_info.json at the hit_<N>pct/
    level, ABOVE the artifact dir. So instead of hardcoding the number of
    "../" hops, we walk UP from the JSON file until we find the marker file
    or hit a ceiling directory.

    Args:
        json_path:    path to a profile_export_aiperf*.json file
        ceiling_dir:  stop walking once we reach (and check) this directory;
                      prevents escaping into unrelated parts of the tree
        max_levels:   hard cap on how many parents to inspect
    """
    current = os.path.dirname(os.path.abspath(json_path))
    ceiling = os.path.abspath(ceiling_dir) if ceiling_dir else None

    for _ in range(max_levels + 1):
        candidate = os.path.join(current, "sweep_level_info.json")
        if os.path.exists(candidate):
            try:
                with open(candidate) as f:
                    return json.load(f)
            except Exception:
                return None
        # Stop conditions: reached ceiling, or hit filesystem root
        if ceiling is not None and current == ceiling:
            break
        parent = os.path.dirname(current)
        if parent == current:  # reached "/"
            break
        current = parent

    return None


def _parse_sweep_summary_csv(results_dir):
    """
    Parse sweep_results/sweep_summary.csv into a list of dicts.
    Returns empty list if not present.
    """
    csv_path = os.path.join(results_dir, "sweep_results", "sweep_summary.csv")
    if not os.path.exists(csv_path):
        # Also check inside aiperf_results (copied by entrypoint)
        csv_path = os.path.join(results_dir, "aiperf_results", "sweep_results", "sweep_summary.csv")
    if not os.path.exists(csv_path):
        return []
    rows = []
    try:
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)
    except Exception:
        pass
    return rows


def _parse_native_sweep_aggregate(results_dir):
    """
    Ingest AIPerf's NATIVE sweep aggregate output (produced by native
    passthrough mode or any multi-value sweep). This is the documented
    profile_export_aiperf_sweep.json schema containing per-combination
    metrics, best configurations, and Pareto-optimal points.

    Returns a dict suitable for embedding in the CMS JSON output, or None.
    Searches recursively because the file lives at
    <...>/sweep_aggregate/profile_export_aiperf_sweep.json and the parent
    path depends on repeated vs independent mode.
    """
    patterns = [
        os.path.join(results_dir, "aiperf_results", "**",
                     "profile_export_aiperf_sweep.json"),
        os.path.join(results_dir, "**", "profile_export_aiperf_sweep.json"),
    ]
    found = []
    for pat in patterns:
        found.extend(glob.glob(pat, recursive=True))
        if found:
            break
    if not found:
        return None

    agg_path = sorted(set(found))[0]
    try:
        with open(agg_path) as f:
            data = json.load(f)
    except Exception:
        return None

    # Surface the most useful fields without copying the entire (large) blob.
    summary = {
        "source_file": os.path.relpath(agg_path, results_dir),
        "aggregation_type": data.get("aggregation_type"),
        "num_profile_runs": data.get("num_profile_runs"),
        "num_successful_runs": data.get("num_successful_runs"),
        "num_combinations": (data.get("metadata") or {}).get("num_combinations"),
        "sweep_parameters": (data.get("metadata") or {}).get("sweep_parameters"),
        "per_combination_metrics": data.get("per_combination_metrics"),
        "best_configurations": data.get("best_configurations"),
        "pareto_optimal": data.get("pareto_optimal"),
    }
    return summary


def parse_aiperf_results(results_dir, suite_name):
    errors = []
    results = []

    # AIPerf writes to <artifact_dir>/<model>-<endpoint>-<mode><N>/
    # We search for all profile_export_aiperf.json files recursively
    json_pattern = os.path.join(
        results_dir, "aiperf_results", "**", "profile_export_aiperf.json"
    )
    json_files = sorted(set(glob.glob(json_pattern, recursive=True)))

    if not json_files:
        errors.append({"error": "No AIPerf profile_export_aiperf.json files found"})
        log("WARNING: No AIPerf result JSON files found")
        log(f"  Searched: {json_pattern}")
        all_json = glob.glob(
            os.path.join(results_dir, "**", "*.json"), recursive=True
        )
        if all_json:
            log(f"  Found {len(all_json)} JSON files total:")
            for f in all_json[:10]:
                log(f"    {os.path.relpath(f, results_dir)}")
    else:
        log(f"Found {len(json_files)} AIPerf result file(s)")

    for json_path in json_files:
        relpath = os.path.relpath(json_path, results_dir)
        log(f"  Parsing: {relpath}")

        try:
            record = _parse_aiperf_json(json_path)
            record["suite_name"] = suite_name
            record["baseline_type"] = "Flat"
            record["baseline_key"] = record.get("model", "unknown")

            # Merge sweep metadata if this result came from a sweep level.
            # Walk up from the JSON toward the aiperf_results dir (ceiling)
            # to find the hit_<N>pct/sweep_level_info.json marker, regardless
            # of how deeply aiperf nested its own run directory.
            sweep_ceiling = os.path.join(results_dir, "aiperf_results")
            sweep_info = _parse_sweep_level_info(json_path, ceiling_dir=sweep_ceiling)
            if sweep_info:
                record["sweep_mode"] = True
                record["target_cache_hit_pct"] = sweep_info.get("target_cache_hit_pct")
                record["actual_cache_hit_pct"] = sweep_info.get("actual_cache_hit_pct")
                record["gpu_util_pct"] = sweep_info.get("gpu_util_pct")
                record["sweep_turn_mean"] = sweep_info.get("turn_mean")
                record["sweep_turn_delay_ms"] = sweep_info.get("turn_delay_ms")
                record["sweep_shared_prompt"] = sweep_info.get("shared_system_prompt_length")
                record["sweep_concurrency"] = sweep_info.get("concurrency")
                record["sweep_conv_num"] = sweep_info.get("conversation_num")
                record["baseline_key"] = f"{record.get('model', 'unknown')}_hit{sweep_info.get('target_cache_hit_pct', '?')}pct"

            results.append(record)
        except Exception as e:
            errors.append({"file": relpath, "error": str(e)})
            log(f"  ERROR parsing {relpath}: {e}")
            continue

    results.sort(key=lambda x: (
        str(x.get("model", "")),
        str(x.get("concurrency", "")),
        str(x.get("request_rate", "")),
    ))

    log(f"Parsed {len(results)} result record(s) with {len(errors)} error(s)")

    # -- Write JSON output --
    json_output = {
        "benchmark": "aiperf",
        "test": suite_name,
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # Promote single-result metrics to top level for report header
    if len(results) == 1:
        promoted = (
            "model", "concurrency", "request_rate",
            "successful_requests", "benchmark_duration_s",
            "request_throughput_req_per_s",
            "output_token_throughput_tok_per_s",
            "ttft_avg_ms", "ttft_p50_ms", "ttft_p99_ms",
            "itl_avg_ms", "itl_p50_ms", "itl_p99_ms",
            "req_latency_avg_ms", "req_latency_p50_ms", "req_latency_p99_ms",
        )
        for k in promoted:
            v = results[0].get(k)
            if v is not None:
                json_output[k] = v

    json_output["results"] = results if results else None
    json_output["errors"] = errors if errors else None

    # Include sweep summary if present
    sweep_rows = _parse_sweep_summary_csv(results_dir)
    if sweep_rows:
        json_output["sweep_summary"] = sweep_rows
        log(f"Included sweep summary: {len(sweep_rows)} levels")

    # Include AIPerf's native sweep aggregate (best configs + Pareto) if present.
    # This appears in native passthrough mode and any multi-value sweep.
    native_agg = _parse_native_sweep_aggregate(results_dir)
    if native_agg:
        json_output["native_sweep_aggregate"] = native_agg
        ncomb = native_agg.get("num_combinations")
        log(f"Included native AIPerf sweep aggregate: {ncomb} combination(s)")

    json_path_out = os.path.join(results_dir, f"results_aiperf_{suite_name}.json")
    with open(json_path_out, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path_out}")

    # -- Write CSV output --
    if results:
        # Detect if any results came from sweep mode
        has_sweep = any(r.get("sweep_mode") for r in results)

        csv_path = os.path.join(results_dir, f"results_aiperf_{suite_name}.csv")
        fieldnames = [
            "Model", "Concurrency", "Request Rate",
            "Requests", "Duration (s)",
            "Req Throughput (req/s)",
            "Output Tok Throughput (tok/s)",
            "TTFT Avg (ms)", "TTFT P50 (ms)", "TTFT P90 (ms)", "TTFT P99 (ms)",
            "ITL Avg (ms)", "ITL P50 (ms)", "ITL P90 (ms)", "ITL P99 (ms)",
            "Req Latency Avg (ms)", "Req Latency P50 (ms)", "Req Latency P99 (ms)",
            "Avg Input Tokens", "Avg Output Tokens",
        ]
        if has_sweep:
            fieldnames.extend([
                "Target Cache Hit %", "Actual Cache Hit %", "GPU Util %",
                "Sweep Turn Mean", "Sweep Delay (ms)", "Sweep Shared Prompt",
            ])
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for r in results:
                row = {
                    "Model": r.get("model", ""),
                    "Concurrency": r.get("concurrency", ""),
                    "Request Rate": r.get("request_rate", ""),
                    "Requests": r.get("successful_requests", ""),
                    "Duration (s)": _fmt(r.get("benchmark_duration_s")),
                    "Req Throughput (req/s)": _fmt(r.get("request_throughput_req_per_s")),
                    "Output Tok Throughput (tok/s)": _fmt(r.get("output_token_throughput_tok_per_s")),
                    "TTFT Avg (ms)": _fmt(r.get("ttft_avg_ms")),
                    "TTFT P50 (ms)": _fmt(r.get("ttft_p50_ms")),
                    "TTFT P90 (ms)": _fmt(r.get("ttft_p90_ms")),
                    "TTFT P99 (ms)": _fmt(r.get("ttft_p99_ms")),
                    "ITL Avg (ms)": _fmt(r.get("itl_avg_ms")),
                    "ITL P50 (ms)": _fmt(r.get("itl_p50_ms")),
                    "ITL P90 (ms)": _fmt(r.get("itl_p90_ms")),
                    "ITL P99 (ms)": _fmt(r.get("itl_p99_ms")),
                    "Req Latency Avg (ms)": _fmt(r.get("req_latency_avg_ms")),
                    "Req Latency P50 (ms)": _fmt(r.get("req_latency_p50_ms")),
                    "Req Latency P99 (ms)": _fmt(r.get("req_latency_p99_ms")),
                    "Avg Input Tokens": _fmt(r.get("avg_input_tokens")),
                    "Avg Output Tokens": _fmt(r.get("avg_output_tokens")),
                }
                if has_sweep:
                    row.update({
                        "Target Cache Hit %": r.get("target_cache_hit_pct", ""),
                        "Actual Cache Hit %": r.get("actual_cache_hit_pct", ""),
                        "GPU Util %": r.get("gpu_util_pct", ""),
                        "Sweep Turn Mean": r.get("sweep_turn_mean", ""),
                        "Sweep Delay (ms)": r.get("sweep_turn_delay_ms", ""),
                        "Sweep Shared Prompt": r.get("sweep_shared_prompt", ""),
                    })
                writer.writerow(row)
        log(f"Wrote CSV: {csv_path} ({len(results)} rows)")


def _fmt(val):
    """Format a numeric value for CSV, rounding floats to 2 decimal places."""
    if val is None:
        return ""
    if isinstance(val, float):
        return f"{val:.2f}"
    return str(val)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <results_dir> <suite_name>")
        sys.exit(1)

    results_dir = sys.argv[1]
    suite_name = sys.argv[2]

    log(f"Parsing AIPerf results: suite={suite_name}")
    log(f"Results directory: {results_dir}")

    parse_aiperf_results(results_dir, suite_name)

    jsons = sorted(glob.glob(os.path.join(results_dir, "results_*.json")))
    csvs = sorted(glob.glob(os.path.join(results_dir, "results_*.csv")))
    log(f"Produced: {len(jsons)} JSON + {len(csvs)} CSV file(s)")
    for j in jsons:
        log(f"  {os.path.basename(j)}")
    for c in csvs:
        rows = sum(1 for _ in open(c)) - 1
        log(f"  {os.path.basename(c)} ({rows} data rows)")


if __name__ == "__main__":
    main()
