#!/usr/bin/env python3
"""
Generate a synthetic *legacy-format* inspection export that deliberately mimics
the real SharePoint list export gotchas, so the Glue backfill has something
realistic to clean:

  * numeric fields carry UNITS as strings:  "24.5 °C", "52 %", "417.3 V", "12.4 A"
  * a per-plant SharePoint list item id (resets to 1 for each plant) -> the Glue
    job adds the offset (P1 +100000, P2 +200000) to derive a globally-unique log_id
  * "Choice"-style text status field
  * two plants (P1, P2) in ONE file with a `plant` column
  * ~2 years of twice-daily (AM/PM) inspections for both plants
  * a small number of intentional out-of-band anomalies

Deterministic (fixed seed) so re-runs produce an identical file.

Output: ./data/backfill_inspections.csv
"""

import csv
import os
import random
from datetime import date, datetime, timedelta

random.seed(20260706)

START = date(2024, 1, 1)
END = date(2025, 12, 31)

PLANTS = ["P1", "P2"]
INSPECTORS = {
    "P1": ["YM2404031", "YM2201017", "YM2312008"],
    "P2": ["YM2405112", "YM2109044", "YM2403021"],
}
SHIFTS = [("AM", 8, 10), ("PM", 13, 15)]

OUT = os.path.join(os.path.dirname(__file__), "data", "backfill_inspections.csv")


def reading(base, spread, lo=None, hi=None):
    v = random.gauss(base, spread)
    if lo is not None:
        v = max(lo, v)
    if hi is not None:
        v = min(hi, v)
    return v


def maybe_anomaly():
    # ~2.5% of rows carry a deliberate out-of-band value.
    return random.random() < 0.025


def build_row(plant, item_id, day, shift, sh_start, sh_end):
    hour = random.randint(sh_start, sh_end - 1)
    minute = random.randint(0, 59)
    ts = datetime(day.year, day.month, day.day, hour, minute)

    temp = reading(23.5, 1.2, 18.5, 26.5)
    humid = reading(50.0, 4.0, 42.0, 58.0)
    ups1_v = reading(415.0, 3.0, 405.0, 425.0)
    ups2_v = reading(414.0, 3.0, 405.0, 425.0)
    ups1_a = reading(12.0, 1.5, 8.0, 16.0)
    ups2_a = reading(11.5, 1.5, 8.0, 16.0)
    status = "OK"

    if maybe_anomaly():
        kind = random.choice(["temp", "humid", "ups1", "ups2"])
        if kind == "temp":
            temp = reading(29.5, 1.0)          # > 27 °C hot aisle event
        elif kind == "humid":
            humid = random.choice([reading(34, 2), reading(66, 3)])
        elif kind == "ups1":
            ups1_v = random.choice([reading(388, 2), reading(437, 3)])
        else:
            ups2_v = random.choice([reading(390, 2), reading(435, 3)])
        status = "Attention"

    inspector = random.choice(INSPECTORS[plant])

    # Legacy formatting: units baked into the string values.
    return {
        "plant": plant,
        "list_item_id": item_id,
        "inspection_date": day.isoformat(),
        "shift": shift,
        "inspected_at": ts.strftime("%Y-%m-%d %H:%M:%S"),
        "inspector_sam": inspector,
        "temperature": f"{temp:.1f} °C",
        "humidity": f"{round(humid)} %",
        "ups1_voltage": f"{ups1_v:.1f} V",
        "ups1_current": f"{ups1_a:.1f} A",
        "ups2_voltage": f"{ups2_v:.1f} V",
        "ups2_current": f"{ups2_a:.1f} A",
        "status": status,
    }


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fields = [
        "plant", "list_item_id", "inspection_date", "shift", "inspected_at",
        "inspector_sam", "temperature", "humidity", "ups1_voltage",
        "ups1_current", "ups2_voltage", "ups2_current", "status",
    ]

    rows = []
    counters = {"P1": 0, "P2": 0}
    day = START
    while day <= END:
        for plant in PLANTS:
            for shift, s, e in SHIFTS:
                counters[plant] += 1
                rows.append(build_row(plant, counters[plant], day, shift, s, e))
        day += timedelta(days=1)

    with open(OUT, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    p1 = counters["P1"]
    p2 = counters["P2"]
    print(f"wrote {len(rows)} rows -> {OUT}  (P1={p1}, P2={p2})")


if __name__ == "__main__":
    main()
