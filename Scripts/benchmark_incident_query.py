#!/usr/bin/env python3
"""Reproduce the hot incident-count query on synthetic data, never the live store."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import statistics
import tempfile
import time


def benchmark(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="radar-query-") as temporary:
        with sqlite3.connect(Path(temporary) / "fixture.sqlite") as db:
            db.executescript("""
                CREATE TABLE incidents(id INTEGER PRIMARY KEY, signature_id TEXT NOT NULL,
                    started_at REAL NOT NULL, resolved_at REAL, reasons_json TEXT NOT NULL);
                CREATE INDEX incidents_signature_active ON incidents(signature_id, resolved_at);
            """)
            db.executemany("INSERT INTO incidents VALUES(?, ?, ?, ?, ?)",
                           ((i, f"family-{i % 1000}", float(i), None if i % 9 == 0 else float(i + 1),
                             '["synthetic evidence"]' * 12) for i in range(120_000)))
            db.commit()
            ids = [f"family-{i}" for i in range(400)]
            sql = ("SELECT signature_id, COUNT(*) FROM incidents WHERE signature_id IN ("
                   + ",".join("?" for _ in ids) + ") AND started_at >= ? GROUP BY signature_id")
            parameters = ids + [60_000]
            results: dict[str, object] = {"rows": 120_000, "signatures_queried": 400,
                                          "sqlite_version": sqlite3.sqlite_version}
            expected = None
            for label in ["before", "after"]:
                if label == "after":
                    db.execute("CREATE INDEX incidents_signature_started ON incidents(signature_id, started_at)")
                times = []
                for iteration in range(9):
                    start = time.perf_counter_ns()
                    rows = db.execute(sql, parameters).fetchall()
                    elapsed = (time.perf_counter_ns() - start) / 1e6
                    if iteration >= 2:
                        times.append(elapsed)
                    if expected is None:
                        expected = rows
                    assert rows == expected, "The optimization changed recurrence counts"
                steps = [0]

                def progress() -> int:
                    steps[0] += 1000
                    return 0

                db.set_progress_handler(progress, 1000)
                db.execute(sql, parameters).fetchall()
                db.set_progress_handler(None, 0)
                plan = [row[3] for row in db.execute("EXPLAIN QUERY PLAN " + sql, parameters)]
                results[label] = {"milliseconds": times, "median_ms": statistics.median(times),
                                  "approximate_vm_steps": steps[0], "query_plan": plan}
            results["identical_results"] = True
            output.write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(results, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    benchmark(parser.parse_args().output)
