"""Qualification / soak check reporting pass rate and timing variance for the canary runner."""
import math

PASS = "pass"
INFRA = "infra_unavailable"


def compute_timing_stats(durations_ms):
    """Compute summary timing statistics (min, max, mean, median, variance, stddev, p95, cv)."""
    values = [float(v) for v in durations_ms if v is not None]
    count = len(values)
    if count == 0:
        return {
            "count": 0,
            "minMs": None,
            "maxMs": None,
            "meanMs": None,
            "medianMs": None,
            "varianceMs": None,
            "stddevMs": None,
            "p95Ms": None,
            "cv": None,
        }

    ordered = sorted(values)
    mean = sum(ordered) / count
    mid = count // 2
    if count % 2 == 1:
        median = ordered[mid]
    else:
        median = (ordered[mid - 1] + ordered[mid]) / 2.0

    variance = sum((v - mean) ** 2 for v in ordered) / count
    stddev = math.sqrt(variance)
    p95_index = min(count - 1, max(0, math.ceil(0.95 * count) - 1))
    p95 = ordered[p95_index]
    cv = (stddev / mean) if mean > 0 else 0.0

    return {
        "count": count,
        "minMs": round(ordered[0], 2),
        "maxMs": round(ordered[-1], 2),
        "meanMs": round(mean, 2),
        "medianMs": round(median, 2),
        "varianceMs": round(variance, 2),
        "stddevMs": round(stddev, 2),
        "p95Ms": round(p95, 2),
        "cv": round(cv, 4),
    }


def evaluate_qualification(run_records, requested_runs, scenario):
    """Evaluate N qualification/soak runs and return a machine-readable JSON summary."""
    completed = len(run_records)
    passed = sum(1 for r in run_records if r.get("verdict") == PASS)
    infra = sum(1 for r in run_records if r.get("verdict") == INFRA)
    failed = completed - passed - infra

    consecutive = 0
    longest_streak = 0
    current_streak = 0
    still_leading = True
    for r in run_records:
        if r.get("verdict") == PASS:
            current_streak += 1
            longest_streak = max(longest_streak, current_streak)
            if still_leading:
                consecutive += 1
        else:
            current_streak = 0
            still_leading = False

    qualified = completed == requested_runs and passed == requested_runs and requested_runs > 0
    if qualified:
        verdict = "qualified"
    elif failed == 0 and infra > 0:
        verdict = INFRA
    else:
        verdict = "unqualified"

    pass_rate = round(passed / completed, 4) if completed > 0 else 0.0

    durations = [r.get("durationMs") for r in run_records if r.get("durationMs") is not None]
    step_buckets = {}
    for r in run_records:
        for step_id, ms in (r.get("stepDurationsMs") or {}).items():
            step_buckets.setdefault(step_id, []).append(ms)

    return {
        "version": 1,
        "scenario": scenario,
        "requestedRuns": requested_runs,
        "completedRuns": completed,
        "passedRuns": passed,
        "failedRuns": failed,
        "infraRuns": infra,
        "consecutiveCleanPasses": consecutive,
        "longestCleanStreak": longest_streak,
        "passRate": pass_rate,
        "qualified": qualified,
        "verdict": verdict,
        "timing": compute_timing_stats(durations),
        "stepTiming": {step_id: compute_timing_stats(vals) for step_id, vals in step_buckets.items()},
        "runs": run_records,
    }


def qualification_exit_code(summary):
    if summary.get("qualified"):
        return 0
    if summary.get("verdict") == INFRA:
        return 2
    return 1
