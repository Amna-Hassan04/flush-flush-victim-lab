
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

THRESHOLD = 171
MESSAGE = b"amna"
OUTPUT = Path("report_figures")
OUTPUT.mkdir(exist_ok=True)

expected_bits = [
    (byte >> shift) & 1
    for byte in MESSAGE
    for shift in range(7, -1, -1)
]

runs = []

for path in sorted(Path("runs").glob("run_*/victim_timings.csv")):
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))

    if len(rows) != len(expected_bits):
        print(f"Skipping incomplete file: {path}")
        continue

    timings = [int(row["ticks"]) for row in rows]
    predictions = [int(t >= THRESHOLD) for t in timings]
    accuracy = 100 * sum(
        p == b for p, b in zip(predictions, expected_bits)
    ) / len(expected_bits)

    runs.append({
        "name": path.parent.name,
        "timings": timings,
        "accuracy": accuracy,
    })

if not runs:
    raise SystemExit("No valid trial CSV files found.")

print(f"Loaded {len(runs)} trials.")
print(f"Using threshold: {THRESHOLD} ticks.")

# Figure 1: Timing distributions grouped by the known bit.
zero_times = []
one_times = []

for run in runs:
    for bit, ticks in zip(expected_bits, run["timings"]):
        if bit == 0:
            zero_times.append(ticks)
        else:
            one_times.append(ticks)

plt.figure(figsize=(9, 5.5))
plt.hist(zero_times, bins=20, alpha=0.65, label="Expected bit 0")
plt.hist(one_times, bins=20, alpha=0.65, label="Expected bit 1")
plt.axvline(
    THRESHOLD,
    linestyle="--",
    linewidth=2,
    label=f"Threshold = {THRESHOLD} ticks",
)
plt.xlabel("CLFLUSH timing (TSC ticks)")
plt.ylabel("Number of measurements")
plt.title("CLFLUSH Timing Distributions by Expected Bit")
plt.legend()
plt.tight_layout()
plt.savefig(OUTPUT / "01_timing_distributions.png", dpi=300)
plt.close()

# Figure 2: Timing for each bit position across all trials.
plt.figure(figsize=(10, 5.5))

for bit_value, label, marker in [
    (0, "Expected bit 0", "o"),
    (1, "Expected bit 1", "^"),
]:
    xs = []
    ys = []

    for run_index, run in enumerate(runs, start=1):
        for bit_index, (expected, ticks) in enumerate(
            zip(expected_bits, run["timings"])
        ):
            if expected == bit_value:
                xs.append(bit_index)
                ys.append(ticks)

    plt.scatter(
        xs, ys, alpha=0.65, s=24, marker=marker, label=label
    )

plt.axhline(
    THRESHOLD,
    linestyle="--",
    linewidth=2,
    label=f"Threshold = {THRESHOLD} ticks",
)
plt.xlabel("Bit position in message (0–31)")
plt.ylabel("CLFLUSH timing (TSC ticks)")
plt.title("Timing Measurements by Message Bit Position")
plt.xticks(range(32))
plt.legend()
plt.tight_layout()
plt.savefig(OUTPUT / "02_timing_by_bit.png", dpi=300)
plt.close()

# Figure 3: Decoding accuracy for each trial.
names = [run["name"] for run in runs]
accuracies = [run["accuracy"] for run in runs]

plt.figure(figsize=(10, 5.5))
bars = plt.bar(names, accuracies)
plt.axhline(100, linestyle="--", linewidth=1)
plt.ylim(85, 101)
plt.ylabel("Bit accuracy (%)")
plt.xlabel("Trial")
plt.title("Message Decoding Accuracy Across 20 Trials")
plt.xticks(rotation=45)
for bar, accuracy in zip(bars, accuracies):
    plt.text(
        bar.get_x() + bar.get_width() / 2,
        accuracy + 0.1,
        f"{accuracy:.2f}%",
        ha="center",
        va="bottom",
        fontsize=8,
    )
plt.tight_layout()
plt.savefig(OUTPUT / "03_accuracy_by_trial.png", dpi=300)
plt.close()

print("\nSaved figures:")
for path in sorted(OUTPUT.glob("*.png")):
    print(f"{path} ({path.stat().st_size:,} bytes)")
