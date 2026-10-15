
import csv
import statistics
from pathlib import Path

THRESHOLD = 171
EXPECTED_MESSAGE = b"amna"

def decode_bits(timings):
    bits = [
        "1" if ticks >= THRESHOLD else "0"
        for ticks in timings
    ]
    bit_string = "".join(bits)

    if len(bit_string) % 8 != 0:
        return bit_string, ""

    data = bytes(
        int(bit_string[i:i + 8], 2)
        for i in range(0, len(bit_string), 8)
    )
    return bit_string, data.decode("ascii", errors="replace")


files = sorted(Path("runs").glob("run_*/victim_timings.csv"))

if not files:
    raise SystemExit("No trial CSV files found.")

all_zero = []
all_one = []
total_bits = 0
total_correct = 0

print(f"Threshold: {THRESHOLD} ticks")
print(f"Trials found: {len(files)}\n")
print("trial,measurements,low_median,high_median,"
      "decoded_message,bit_accuracy")

for path in files:
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))

    if len(rows) != 32:
        print(f"{path.parent.name}: skipped, expected 32 rows")
        continue

    timings = [int(row["ticks"]) for row in rows]
    bits, decoded = decode_bits(timings)

    low = [t for t in timings if t < THRESHOLD]
    high = [t for t in timings if t >= THRESHOLD]

    expected_bits = "".join(
        f"{byte:08b}" for byte in EXPECTED_MESSAGE
    )
    correct = sum(
        a == b for a, b in zip(bits, expected_bits)
    )
    accuracy = 100 * correct / len(expected_bits)

    total_bits += len(expected_bits)
    total_correct += correct
    all_zero.extend(low)
    all_one.extend(high)

    print(
        f"{path.parent.name},{len(timings)},"
        f"{statistics.median(low) if low else float('nan'):.1f},"
        f"{statistics.median(high) if high else float('nan'):.1f},"
        f"{decoded},{accuracy:.2f}%"
    )

print("\nOverall timing summary")
print(f"Measurements classified low: {len(all_zero)}")
print(f"Measurements classified high: {len(all_one)}")

if all_zero:
    print(f"Low-group median: {statistics.median(all_zero):.1f} ticks")
if all_one:
    print(f"High-group median: {statistics.median(all_one):.1f} ticks")

if total_bits:
    print(f"Overall bit accuracy: {100 * total_correct / total_bits:.2f}%")
    print(f"Correct bits: {total_correct}/{total_bits}")
