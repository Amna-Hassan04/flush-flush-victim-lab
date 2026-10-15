#!/usr/bin/env bash

# Stop if a command fails, an unset variable is used, or a pipeline fails.
set -Eeuo pipefail

# Number of experiment trials to run on this server.
TRIALS=20

# Expected message used by the victim and analysis script.
EXPECTED_MESSAGE="amna"

# Fixed shared-memory name used by victim.c and observer.c.
SHM_NAME="/flush_flush_demo"

# Directory containing this script and the experiment source files.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Identify the current machine.
HOST="$(hostname -s 2>/dev/null || hostname)"

# Create a timestamp for this experiment run.
STAMP="$(date +%Y%m%d_%H%M%S)"

# Store all results in a unique directory for this machine and run.
RESULTS_ROOT="${PROJECT_DIR}/cross_machine_results"
OUT="${RESULTS_ROOT}/${HOST}_${STAMP}"

# Print a heading and the selected output directory.
echo "=================================================="
echo "Flush+Flush-Inspired Cross-Machine Experiment"
echo "Host: ${HOST}"
echo "Trials: ${TRIALS}"
echo "Results: ${OUT}"
echo "=================================================="

# Create the output directory.
mkdir -p "${OUT}"

# Save a copy of the host's system information.
{
    echo "Hostname: $(hostname)"
    echo "Date: $(date)"
    echo "Kernel: $(uname -a)"
    echo "Architecture: $(uname -m)"
    echo
    echo "CPU information:"
    lscpu 2>&1 || true
    echo
    echo "Compiler version:"
    gcc --version 2>&1 || true
} > "${OUT}/system_info.txt"

# Confirm that the experiment is running on an x86-64 machine.
ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" ]]; then
    echo "SKIPPED: This experiment requires x86-64."
    echo "Detected architecture: ${ARCH}"
    echo "See ${OUT}/system_info.txt"
    exit 0
fi

# Read CPU flags to check whether the required instructions are supported.
CPU_FLAGS="$(grep -m 1 '^flags' /proc/cpuinfo 2>/dev/null || true)"

# Skip if CLFLUSH is unavailable.
if ! grep -qw 'clflush' <<< "${CPU_FLAGS}"; then
    echo "SKIPPED: CPU does not advertise the CLFLUSH instruction."
    exit 0
fi

# Skip if RDTSCP is unavailable.
if ! grep -qw 'rdtscp' <<< "${CPU_FLAGS}"; then
    echo "SKIPPED: CPU does not advertise the RDTSCP instruction."
    exit 0
fi

# Check that the required compiler is installed.
if ! command -v gcc >/dev/null 2>&1; then
    echo "ERROR: gcc is not installed or is not on PATH."
    exit 1
fi

# Check that Python 3 is available for analysis.
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not installed or is not on PATH."
    exit 1
fi

# Check that timeout is available to prevent hung experiment processes.
if ! command -v timeout >/dev/null 2>&1; then
    echo "ERROR: timeout is unavailable on this server."
    exit 1
fi

# Confirm that the required C source files exist.
for FILE in victim.c observer.c; do
    if [[ ! -f "${PROJECT_DIR}/${FILE}" ]]; then
        echo "ERROR: Missing ${FILE} in ${PROJECT_DIR}"
        exit 1
    fi
done

# Compile the victim program.
echo "Compiling victim.c..."
gcc -O2 -Wall -Wextra \
    "${PROJECT_DIR}/victim.c" \
    -o "${OUT}/victim" \
    2> "${OUT}/victim_compile.log"

# Compile the observer program.
echo "Compiling observer.c..."
gcc -O2 -Wall -Wextra \
    "${PROJECT_DIR}/observer.c" \
    -o "${OUT}/observer" \
    2> "${OUT}/observer_compile.log"

# Record the compiler options used for this run.
echo "Compiler flags: -O2 -Wall -Wextra" > "${OUT}/build_info.txt"

# Run the experiment repeatedly, storing each trial separately.
for ((TRIAL = 1; TRIAL <= TRIALS; TRIAL++)); do

    # Format the trial number with leading zeroes.
    RUN_NAME="$(printf 'run_%02d' "${TRIAL}")"

    # Create the trial directory.
    RUN_DIR="${OUT}/runs/${RUN_NAME}"
    mkdir -p "${RUN_DIR}"

    # Show progress in the terminal.
    echo
    echo "Starting ${RUN_NAME}/${TRIALS} on ${HOST}..."

    # Launch the victim and save its output to a log.
    (
        cd "${RUN_DIR}"
        timeout 30s "${OUT}/victim"
    ) > "${RUN_DIR}/victim.log" 2>&1 &
    VICTIM_PID=$!

    # Ensure the victim process is cleaned up if the script is interrupted.
    cleanup_trial() {
        kill "${VICTIM_PID}" 2>/dev/null || true
        wait "${VICTIM_PID}" 2>/dev/null || true
    }
    trap cleanup_trial INT TERM

    # Wait briefly for the victim to initialize its shared-memory region.
    READY=0
    for ((WAIT_COUNT = 0; WAIT_COUNT < 100; WAIT_COUNT++)); do
        if grep -q "ready" "${RUN_DIR}/victim.log" 2>/dev/null; then
            READY=1
            break
        fi

        # Stop waiting if the victim has already exited.
        if ! kill -0 "${VICTIM_PID}" 2>/dev/null; then
            break
        fi

        # Avoid busy-waiting while the victim starts.
        sleep 0.1
    done

    # Do not start the observer if the victim failed to initialize.
    if [[ "${READY}" -ne 1 ]]; then
        echo "ERROR: Victim did not become ready for ${RUN_NAME}."
        echo "Inspect ${RUN_DIR}/victim.log"
        cleanup_trial
        trap - INT TERM
        continue
    fi

    # Run the observer and save its output to a log.
    (
        cd "${RUN_DIR}"
        timeout 30s "${OUT}/observer"
    ) > "${RUN_DIR}/observer.log" 2>&1 || true

    # Wait for the victim to finish its trial.
    wait "${VICTIM_PID}" || true
    trap - INT TERM

    # Check that the observer generated timing measurements.
    if [[ ! -f "${RUN_DIR}/victim_timings.csv" ]]; then
        echo "WARNING: No timing CSV found for ${RUN_NAME}."
        continue
    fi

    # Verify that the CSV contains a header and 32 bit measurements.
    LINE_COUNT="$(wc -l < "${RUN_DIR}/victim_timings.csv" | tr -d ' ')"
    if [[ "${LINE_COUNT}" -ne 33 ]]; then
        echo "WARNING: Expected 33 CSV lines, found ${LINE_COUNT}."
        echo "Inspect ${RUN_DIR}/observer.log and the CSV."
        continue
    fi

    # Report successful completion of this trial.
    echo "Completed ${RUN_NAME}: 32 measurements recorded."

done

# Copy the analysis script into the results directory if available.
if [[ -f "${PROJECT_DIR}/analyze_repeats.py" ]]; then
    cp "${PROJECT_DIR}/analyze_repeats.py" "${OUT}/analyze_repeats.py"

    # Run the analysis from the output directory so its runs/ paths resolve.
    echo
    echo "Running timing analysis..."
    (
        cd "${OUT}"
        python3 analyze_repeats.py
    ) 2>&1 | tee "${OUT}/analysis.log" || true
else
    echo "NOTE: analyze_repeats.py is missing; skipping analysis."
fi

# Copy and run the plotting script if it is available.
if [[ -f "${PROJECT_DIR}/plot_repeats.py" ]]; then
    cp "${PROJECT_DIR}/plot_repeats.py" "${OUT}/plot_repeats.py"

    # Generate plots from the results directory.
    echo
    echo "Generating plots..."
    (
        cd "${OUT}"
        python3 plot_repeats.py
    ) 2>&1 | tee "${OUT}/plot.log" || true
else
    echo "NOTE: plot_repeats.py is missing; skipping plots."
fi

# Save a summary of the experiment configuration.
{
    echo "Host: ${HOST}"
    echo "Architecture: ${ARCH}"
    echo "Trials requested: ${TRIALS}"
    echo "Expected message: ${EXPECTED_MESSAGE}"
    echo "Shared-memory name: ${SHM_NAME}"
    echo "Results directory: ${OUT}"
    echo "Finished: $(date)"
} > "${OUT}/run_summary.txt"

# Print the location of the collected data.
echo
echo "=================================================="
echo "Experiment script finished."
echo "Host: ${HOST}"
echo "Results saved in: ${OUT}"
echo "=================================================="
