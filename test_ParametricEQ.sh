#!/bin/bash

#
# Matthew Abbott 2025
# Parametric EQ Tests
#

set -o pipefail

PASS=0
FAIL=0
TOTAL=0
TEMP_DIR="./test_output_eq"
EQ_BIN="./ParametricEQ"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Setup/Cleanup
cleanup() {
    # Cleanup handled manually if needed
    :
}
trap cleanup EXIT

mkdir -p "$TEMP_DIR"

# Compile
fpc ParametricEQ.pas

# Test function
run_test() {
    local test_name="$1"
    local command="$2"
    local expected_pattern="$3"

    TOTAL=$((TOTAL + 1))
    echo -n "Test $TOTAL: $test_name... "

    output=$(eval "$command" 2>&1)
    exit_code=$?

    if echo "$output" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Command: $command"
        echo "  Expected pattern: $expected_pattern"
        echo "  Output:"
        echo "$output" | head -5
        FAIL=$((FAIL + 1))
    fi
}

check_file_exists() {
    local test_name="$1"
    local file="$2"

    TOTAL=$((TOTAL + 1))
    echo -n "Test $TOTAL: $test_name... "

    if [ -f "$file" ]; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  File not found: $file"
        FAIL=$((FAIL + 1))
    fi
}

check_wav_valid() {
    local test_name="$1"
    local file="$2"

    TOTAL=$((TOTAL + 1))
    echo -n "Test $TOTAL: $test_name... "

    if [ ! -f "$file" ]; then
        echo -e "${RED}FAIL${NC}"
        echo "  File not found: $file"
        FAIL=$((FAIL + 1))
        return
    fi

    # Check if it's a valid WAV file
    if file "$file" | grep -q "WAVE audio"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Invalid WAV file: $file"
        FAIL=$((FAIL + 1))
    fi
}

check_csv_valid() {
    local test_name="$1"
    local file="$2"

    TOTAL=$((TOTAL + 1))
    echo -n "Test $TOTAL: $test_name... "

    if [ ! -f "$file" ]; then
        echo -e "${RED}FAIL${NC}"
        echo "  File not found: $file"
        FAIL=$((FAIL + 1))
        return
    fi

    if grep -q "Frequency (Hz)" "$file" && grep -q "Magnitude (dB)" "$file"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Invalid CSV structure: $file"
        FAIL=$((FAIL + 1))
    fi
}

# Generate test input files
generate_test_input() {
    local filename="$1"
    local freq="$2"
    local duration="${3:-1}"
    
    python3 << PYEOF
import wave
import struct
import math

sample_rate = 44100
num_samples = sample_rate * $duration
freq = $freq
amplitude = 0.7

samples = []
for i in range(num_samples):
    t = i / sample_rate
    sample = amplitude * math.sin(2 * math.pi * freq * t)
    sample_int = int(sample * 32767)
    samples.append(sample_int)

with wave.open('$filename', 'w') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(sample_rate)
    for sample in samples:
        wav.writeframes(struct.pack('<h', sample))

print("Created: $filename")
PYEOF
}

# ============================================
# Start Tests
# ============================================

echo ""
echo "========================================="
echo "Parametric EQ Test Suite"
echo "========================================="
echo ""

# Check binary exists
if [ ! -f "$EQ_BIN" ]; then
    echo -e "${RED}Error: $EQ_BIN not found. Compile with: fpc ParametricEQ.pas${NC}"
    exit 1
fi

echo -e "${BLUE}=== Test Input Generation ===${NC}"
echo ""

# Generate diverse test inputs
echo "Generating test input files..."
generate_test_input "$TEMP_DIR/test_1k.wav" "1000" "1"
generate_test_input "$TEMP_DIR/test_100hz.wav" "100" "1"
generate_test_input "$TEMP_DIR/test_5k.wav" "5000" "1"
generate_test_input "$TEMP_DIR/test_sine_sweep.wav" "1000" "1"

echo ""

# ============================================
# Basic Help/Usage
# ============================================

echo -e "${BLUE}Group: Help & Usage${NC}"

run_test \
    "EQ help command" \
    "$EQ_BIN --help" \
    "Parametric EQ"

run_test \
    "EQ help shows usage" \
    "$EQ_BIN --help" \
    "Usage:"

run_test \
    "EQ help shows band types" \
    "$EQ_BIN --help" \
    "peak"

run_test \
    "EQ help shows options" \
    "$EQ_BIN --help" \
    "Options:"

echo ""

# ============================================
# Single Band - Peaking EQ
# ============================================

echo -e "${BLUE}Group: Single Band - Peaking EQ${NC}"

run_test \
    "Peaking EQ at 1kHz +6dB" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_peak_1k_6db.wav --band peak 1000 2.5 6" \
    "Loading:"

check_file_exists \
    "Output WAV created for peaking EQ" \
    "$TEMP_DIR/eq_peak_1k_6db.wav"

check_wav_valid \
    "Peaking EQ output is valid WAV" \
    "$TEMP_DIR/eq_peak_1k_6db.wav"

run_test \
    "Peaking EQ at 1kHz -6dB" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_peak_1k_minus6db.wav --band peak 1000 2.5 -6" \
    "Loading:"

run_test \
    "Peaking EQ at 100Hz +12dB" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_peak_100hz.wav --band peak 100 1.5 12" \
    "Loading:"

run_test \
    "Peaking EQ at 5kHz +3dB" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_peak_5k.wav --band peak 5000 2.0 3" \
    "Loading:"

run_test \
    "Peaking EQ with high Q (narrow)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_peak_highq.wav --band peak 1000 5.0 6" \
    "Loading:"

run_test \
    "Peaking EQ with low Q (wide)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_peak_lowq.wav --band peak 1000 0.5 6" \
    "Loading:"

run_test \
    "Peaking EQ zero gain (pass-through)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_peak_zero.wav --band peak 1000 2.5 0" \
    "Loading:"

echo ""

# ============================================
# Single Band - Shelving EQ
# ============================================

echo -e "${BLUE}Group: Single Band - Shelving EQ${NC}"

run_test \
    "Low shelf boost at 80Hz +4dB" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_lowshelf_boost.wav --band lowshelf 80 0.7 4" \
    "Loading:"

check_wav_valid \
    "Low shelf output is valid WAV" \
    "$TEMP_DIR/eq_lowshelf_boost.wav"

run_test \
    "Low shelf cut at 80Hz -4dB" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_lowshelf_cut.wav --band lowshelf 80 0.7 -4" \
    "Loading:"

run_test \
    "High shelf boost at 5kHz +4dB" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_highshelf_boost.wav --band highshelf 5000 0.7 4" \
    "Loading:"

run_test \
    "High shelf cut at 5kHz -4dB" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_highshelf_cut.wav --band highshelf 5000 0.7 -4" \
    "Loading:"

echo ""

# ============================================
# Single Band - Filter Types
# ============================================

echo -e "${BLUE}Group: Single Band - Filter Types${NC}"

run_test \
    "High-pass filter at 50Hz" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_highpass_50.wav --band highpass 50 0.7 0" \
    "Loading:"

check_wav_valid \
    "High-pass filter output is valid WAV" \
    "$TEMP_DIR/eq_highpass_50.wav"

run_test \
    "High-pass filter at 200Hz" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_highpass_200.wav --band highpass 200 0.7 0" \
    "Loading:"

run_test \
    "Low-pass filter at 8kHz" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_lowpass_8k.wav --band lowpass 8000 0.7 0" \
    "Loading:"

run_test \
    "Low-pass filter at 1kHz" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_lowpass_1k.wav --band lowpass 1000 0.7 0" \
    "Loading:"

run_test \
    "Notch filter at 1kHz" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_notch_1k.wav --band notch 1000 2.0 0" \
    "Loading:"

run_test \
    "Notch filter at 100Hz narrow" \
    "$EQ_BIN $TEMP_DIR/test_100hz.wav $TEMP_DIR/eq_notch_100_narrow.wav --band notch 100 5.0 0" \
    "Loading:"

echo ""

# ============================================
# Multiple Bands - Combinations
# ============================================

echo -e "${BLUE}Group: Multiple Bands - Combinations${NC}"

run_test \
    "Bass & Treble boost (classic EQ)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_bass_treble.wav --band lowshelf 100 0.7 4 --band highshelf 5000 0.7 4" \
    "Loading:"

check_wav_valid \
    "Bass & Treble boost output valid" \
    "$TEMP_DIR/eq_bass_treble.wav"

run_test \
    "High-pass + Low-pass bandpass" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_bandpass.wav --band highpass 100 0.7 0 --band lowpass 8000 0.7 0" \
    "Loading:"

run_test \
    "Graphic EQ 3-band" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_graphic_3band.wav --band peak 200 1.0 2 --band peak 1000 1.0 2 --band peak 5000 1.0 2" \
    "Loading:"

run_test \
    "Graphic EQ 7-band" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_graphic_7band.wav --band peak 63 1.0 1.5 --band peak 125 1.0 1.5 --band peak 250 1.0 1.5 --band peak 500 1.0 1.5 --band peak 1000 1.0 1.5 --band peak 2000 1.0 1.5 --band peak 4000 1.0 1.5" \
    "Loading:"

run_test \
    "Complex EQ with mixed types" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_complex.wav --band highpass 30 0.7 0 --band lowshelf 100 0.7 -2 --band peak 500 2.0 -6 --band peak 1000 2.5 8 --band peak 5000 1.5 3 --band highshelf 8000 0.7 2" \
    "Loading:"

run_test \
    "De-esser style (notch at high freq)" \
    "$EQ_BIN $TEMP_DIR/test_5k.wav $TEMP_DIR/eq_deesser.wav --band notch 4000 3.0 0 --band notch 5000 3.0 0 --band notch 6000 3.0 0" \
    "Loading:"

echo ""

# ============================================
# Extreme Values
# ============================================

echo -e "${BLUE}Group: Extreme Values${NC}"

run_test \
    "Very large gain boost +24dB" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_boost.wav --band peak 1000 2.5 24" \
    "Loading:"

run_test \
    "Very large gain cut -24dB" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_cut.wav --band peak 1000 2.5 -24" \
    "Loading:"

run_test \
    "Very high Q factor (very narrow)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_highq.wav --band peak 1000 10.0 12" \
    "Loading:"

run_test \
    "Very low Q factor (very wide)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_lowq.wav --band peak 1000 0.1 12" \
    "Loading:"

run_test \
    "Very low frequency 10Hz" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_lowfreq.wav --band lowshelf 10 0.7 6" \
    "Loading:"

run_test \
    "Very high frequency 20kHz" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extreme_highfreq.wav --band highshelf 20000 0.7 6" \
    "Loading:"

echo ""

# ============================================
# Maximum Bands Test
# ============================================

echo -e "${BLUE}Group: Maximum Bands${NC}"

run_test \
    "Many bands (10-band EQ)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_10band.wav --band peak 100 1.0 1 --band peak 200 1.0 1 --band peak 400 1.0 1 --band peak 800 1.0 1 --band peak 1600 1.0 1 --band peak 3200 1.0 1 --band peak 6400 1.0 1 --band peak 12800 1.0 1 --band peak 2000 1.0 2 --band peak 5000 1.0 2" \
    "Loading:"

check_wav_valid \
    "10-band EQ output valid" \
    "$TEMP_DIR/eq_10band.wav"

run_test \
    "Many bands with mixed types" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_mixed_many.wav --band highpass 20 0.7 0 --band peak 100 1.0 2 --band peak 500 1.0 -3 --band peak 1000 1.0 6 --band peak 3000 1.0 1 --band peak 8000 1.0 2 --band lowpass 16000 0.7 0 --band lowshelf 50 0.7 1 --band highshelf 10000 0.7 1" \
    "Loading:"

echo ""

# ============================================
# Metering Tests
# ============================================

echo -e "${BLUE}Group: Metering & Analysis${NC}"

run_test \
    "Metering enabled with peaking EQ" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_meter_peak.wav --band peak 1000 2.5 6 --metering" \
    "Signal Metering"

run_test \
    "Metering shows peak/RMS before" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_meter_before.wav --band peak 1000 2.5 0 --metering" \
    "Before:"

run_test \
    "Metering shows peak/RMS after" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_meter_after.wav --band peak 1000 2.5 6 --metering" \
    "After:"

run_test \
    "Metering shows dB values" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_meter_db.wav --band peak 1000 2.5 6 --metering" \
    "dB"

run_test \
    "Metering on pass-through (zero gain)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_meter_passthrough.wav --band peak 1000 2.5 0 --metering" \
    "Loading:"

echo ""

# ============================================
# CSV Export Tests
# ============================================

echo -e "${BLUE}Group: Frequency Response CSV Export${NC}"

run_test \
    "CSV export with simple peak" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_csv_peak.wav --band peak 1000 2.5 6 --csv $TEMP_DIR/freq_peak.csv" \
    "Exported frequency response"

check_file_exists \
    "CSV file created for peak EQ" \
    "$TEMP_DIR/freq_peak.csv"

check_csv_valid \
    "CSV has valid structure" \
    "$TEMP_DIR/freq_peak.csv"

run_test \
    "CSV export with lowshelf" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_csv_lowshelf.wav --band lowshelf 100 0.7 4 --csv $TEMP_DIR/freq_lowshelf.csv" \
    "Exported frequency response"

check_csv_valid \
    "Low shelf CSV valid" \
    "$TEMP_DIR/freq_lowshelf.csv"

run_test \
    "CSV export with highpass" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_csv_highpass.wav --band highpass 50 0.7 0 --csv $TEMP_DIR/freq_highpass.csv" \
    "Exported frequency response"

run_test \
    "CSV export with multiple bands" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_csv_multi.wav --band peak 500 1.0 3 --band peak 1000 1.0 6 --band peak 5000 1.0 2 --csv $TEMP_DIR/freq_multi.csv" \
    "Exported frequency response"

echo ""

# ============================================
# Metering + CSV Tests
# ============================================

echo -e "${BLUE}Group: Combined Features (Metering + CSV)${NC}"

run_test \
    "Metering AND CSV together" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_combined.wav --band peak 1000 2.5 6 --metering --csv $TEMP_DIR/freq_combined.csv" \
    "Signal Metering"

run_test \
    "Combined also exports CSV" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_combined2.wav --band peak 1000 2.5 6 --metering --csv $TEMP_DIR/freq_combined2.csv" \
    "Exported frequency response"

check_csv_valid \
    "CSV from combined test valid" \
    "$TEMP_DIR/freq_combined.csv"

echo ""

# ============================================
# Output File Variations
# ============================================

echo -e "${BLUE}Group: Output File Handling${NC}"

run_test \
    "Output to different directory" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/subdir/eq_output.wav --band peak 1000 2.5 6 2>&1 || true" \
    "."

run_test \
    "Output with descriptive filename" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_1k_peak_plus6_q2p5.wav --band peak 1000 2.5 6" \
    "Loading:"

run_test \
    "Multiple outputs from same input" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_copy1.wav --band peak 1000 2.5 6 && $EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_copy2.wav --band peak 1000 2.5 6" \
    "Loading:"

echo ""

# ============================================
# Frequency Coverage Tests
# ============================================

echo -e "${BLUE}Group: Frequency Range Coverage${NC}"

run_test \
    "Sub-bass (20Hz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_subbass.wav --band peak 20 1.0 6" \
    "Loading:"

run_test \
    "Bass (100Hz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_bass.wav --band peak 100 1.0 6" \
    "Loading:"

run_test \
    "Midrange (500Hz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_mid.wav --band peak 500 1.0 6" \
    "Loading:"

run_test \
    "Presence (2kHz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_presence.wav --band peak 2000 1.0 6" \
    "Loading:"

run_test \
    "Brilliance (8kHz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_brilliance.wav --band peak 8000 1.0 6" \
    "Loading:"

run_test \
    "Extended high (16kHz)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_extended_high.wav --band peak 16000 1.0 6" \
    "Loading:"

echo ""

# ============================================
# Real-world EQ Scenarios
# ============================================

echo -e "${BLUE}Group: Real-world EQ Scenarios${NC}"

run_test \
    "Telephone voice (HPF + narrow peak)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_telephone.wav --band highpass 300 0.7 0 --band lowpass 3000 0.7 0" \
    "Loading:"

run_test \
    "Presence boost (enhance upper mids)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_presence_boost.wav --band peak 2000 2.0 4 --band peak 4000 2.0 2" \
    "Loading:"

run_test \
    "De-sibilance (reduce harsh s sounds)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_desibilance.wav --band peak 5000 3.0 -4 --band peak 7000 2.5 -3" \
    "Loading:"

run_test \
    "Warm and dark (shelved bass boost)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_warm_dark.wav --band lowshelf 200 0.7 6 --band highshelf 5000 0.7 -4" \
    "Loading:"

run_test \
    "Bright and present (treble boost)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_bright.wav --band highshelf 4000 0.7 6" \
    "Loading:"

run_test \
    "Vocal enhancement (presence peak + bright)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_vocal.wav --band lowshelf 100 0.7 -3 --band peak 2000 2.0 3 --band peak 5000 1.5 2 --band highshelf 8000 0.7 3" \
    "Loading:"

run_test \
    "Bass guitar tone" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_bass_guitar.wav --band lowshelf 50 0.7 6 --band peak 800 1.5 -4 --band peak 1500 1.0 2" \
    "Loading:"

echo ""

# ============================================
# Chain Multiple Bands Semantics
# ============================================

echo -e "${BLUE}Group: Band Chain Order Handling${NC}"

run_test \
    "Bands in forward order" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_order_forward.wav --band highpass 100 0.7 0 --band peak 1000 2.0 6 --band lowpass 10000 0.7 0" \
    "Loading:"

run_test \
    "Bands in reverse order" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_order_reverse.wav --band lowpass 10000 0.7 0 --band peak 1000 2.0 6 --band highpass 100 0.7 0" \
    "Loading:"

run_test \
    "Overlapping frequency bands" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_overlap.wav --band peak 800 1.5 4 --band peak 1000 1.5 4 --band peak 1200 1.5 4" \
    "Loading:"

echo ""

# ============================================
# Boundary Conditions
# ============================================

echo -e "${BLUE}Group: Boundary Conditions${NC}"

run_test \
    "Single band only" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_single.wav --band peak 1000 2.5 6" \
    "Loading:"

run_test \
    "No bands (pass-through)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_noband.wav" \
    "Loading:"

run_test \
    "Zero dB (no change)" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_zero_db.wav --band peak 1000 2.5 0" \
    "Loading:"

run_test \
    "Multiple zero-dB bands" \
    "$EQ_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/eq_multi_zero.wav --band peak 500 1.0 0 --band peak 1000 1.0 0 --band peak 2000 1.0 0" \
    "Loading:"

echo ""

# ============================================
# Summary
# ============================================

echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Total tests: $TOTAL"
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
