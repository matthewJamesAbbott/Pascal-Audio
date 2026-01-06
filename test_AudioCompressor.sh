#!/bin/bash

#
# Matthew Abbott 2025
# Audio Compressor Tests
#

set -o pipefail

PASS=0
FAIL=0
TOTAL=0
TEMP_DIR="./test_output_comp"
COMP_BIN="./AudioCompressor"

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
fpc -O2 AudioCompressor.pas

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

    if grep -q "Sample,GainReductionDB" "$file"; then
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

with open('$filename', 'wb') as f:
    # Write WAV header
    f.write(b'RIFF')
    chunk_size = 36 + len(samples) * 2
    f.write(struct.pack('<I', chunk_size))
    f.write(b'WAVE')
    
    f.write(b'fmt ')
    f.write(struct.pack('<I', 16))  # Subchunk1Size
    f.write(struct.pack('<H', 1))   # AudioFormat (PCM)
    f.write(struct.pack('<H', 1))   # NumChannels
    f.write(struct.pack('<I', sample_rate))  # SampleRate
    f.write(struct.pack('<I', sample_rate * 2))  # ByteRate
    f.write(struct.pack('<H', 2))   # BlockAlign
    f.write(struct.pack('<H', 16))  # BitsPerSample
    
    f.write(b'data')
    f.write(struct.pack('<I', len(samples) * 2))
    
    for sample in samples:
        f.write(struct.pack('<h', sample))

print("Created: $filename")
PYEOF
}

# ============================================
# Start Tests
# ============================================

echo ""
echo "========================================="
echo "Audio Compressor Test Suite"
echo "========================================="
echo ""

# Check binary exists
if [ ! -f "$COMP_BIN" ]; then
    echo -e "${RED}Error: $COMP_BIN not found. Compile with: fpc -O2 AudioCompressor.pas${NC}"
    exit 1
fi

echo -e "${BLUE}=== Test Input Generation ===${NC}"
echo ""

# Generate diverse test inputs
echo "Generating test input files..."
generate_test_input "$TEMP_DIR/test_1k.wav" "1000" "1"
generate_test_input "$TEMP_DIR/test_100hz.wav" "100" "1"
generate_test_input "$TEMP_DIR/test_5k.wav" "5000" "1"
generate_test_input "$TEMP_DIR/test_complex.wav" "1000" "2"

echo ""

# ============================================
# Basic Help/Usage
# ============================================

echo -e "${BLUE}Group: Help & Usage${NC}"

run_test \
    "Compressor help command" \
    "$COMP_BIN" \
    "AudioCompressor"

run_test \
    "Help shows usage" \
    "$COMP_BIN" \
    "Usage:"

run_test \
    "Help shows compression controls" \
    "$COMP_BIN" \
    "Threshold"

run_test \
    "Help shows stereo linking modes" \
    "$COMP_BIN" \
    "independent"

echo ""

# ============================================
# Basic Compression Tests
# ============================================

echo -e "${BLUE}Group: Basic Compression${NC}"

run_test \
    "Default compression" \
    "$COMP_BIN $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_default.wav" \
    "Done"

check_file_exists \
    "Default compression output created" \
    "$TEMP_DIR/comp_default.wav"

check_wav_valid \
    "Default compression output is valid WAV" \
    "$TEMP_DIR/comp_default.wav"

run_test \
    "Tight compression (4:1 ratio)" \
    "$COMP_BIN -t -15 -r 4 -a 5 -rl 50 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_tight.wav" \
    "Done"

run_test \
    "Gentle compression (2:1 ratio)" \
    "$COMP_BIN -t -20 -r 2 -a 20 -rl 100 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_gentle.wav" \
    "Done"

run_test \
    "Limiter (100:1 ratio)" \
    "$COMP_BIN -t -5 -r 100 -a 1 -rl 50 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_limiter.wav" \
    "Done"

echo ""

# ============================================
# Threshold Tests
# ============================================

echo -e "${BLUE}Group: Threshold Variations${NC}"

run_test \
    "Very low threshold (-50dB)" \
    "$COMP_BIN -t -50 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_thresh_low.wav" \
    "Done"

run_test \
    "Moderate threshold (-20dB)" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_thresh_mid.wav" \
    "Done"

run_test \
    "High threshold (-5dB)" \
    "$COMP_BIN -t -5 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_thresh_high.wav" \
    "Done"

echo ""

# ============================================
# Ratio Tests
# ============================================

echo -e "${BLUE}Group: Compression Ratio Variations${NC}"

run_test \
    "Ratio 1.5:1 (subtle)" \
    "$COMP_BIN -t -20 -r 1.5 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ratio_1p5.wav" \
    "Done"

run_test \
    "Ratio 2:1 (moderate)" \
    "$COMP_BIN -t -20 -r 2 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ratio_2.wav" \
    "Done"

run_test \
    "Ratio 6:1 (aggressive)" \
    "$COMP_BIN -t -20 -r 6 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ratio_6.wav" \
    "Done"

run_test \
    "Ratio 10:1 (very aggressive)" \
    "$COMP_BIN -t -20 -r 10 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ratio_10.wav" \
    "Done"

echo ""

# ============================================
# Attack & Release Time Tests
# ============================================

echo -e "${BLUE}Group: Attack & Release Times${NC}"

run_test \
    "Fast attack (1ms)" \
    "$COMP_BIN -t -20 -r 4 -a 1 -rl 50 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_attack_fast.wav" \
    "Done"

run_test \
    "Slow attack (50ms)" \
    "$COMP_BIN -t -20 -r 4 -a 50 -rl 50 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_attack_slow.wav" \
    "Done"

run_test \
    "Very slow attack (200ms)" \
    "$COMP_BIN -t -20 -r 4 -a 200 -rl 50 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_attack_verysi.wav" \
    "Done"

run_test \
    "Fast release (10ms)" \
    "$COMP_BIN -t -20 -r 4 -a 5 -rl 10 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_release_fast.wav" \
    "Done"

run_test \
    "Slow release (500ms)" \
    "$COMP_BIN -t -20 -r 4 -a 5 -rl 500 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_release_slow.wav" \
    "Done"

echo ""

# ============================================
# Soft Knee Tests
# ============================================

echo -e "${BLUE}Group: Soft Knee Processing${NC}"

run_test \
    "Hard knee (0dB)" \
    "$COMP_BIN -t -20 -r 4 -k 0 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_knee_hard.wav" \
    "Done"

run_test \
    "Soft knee (5dB)" \
    "$COMP_BIN -t -20 -r 4 -k 5 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_knee_5db.wav" \
    "Done"

run_test \
    "Wide knee (12dB)" \
    "$COMP_BIN -t -20 -r 4 -k 12 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_knee_12db.wav" \
    "Done"

run_test \
    "Very wide knee (25dB)" \
    "$COMP_BIN -t -20 -r 4 -k 25 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_knee_25db.wav" \
    "Done"

echo ""

# ============================================
# Makeup Gain Tests
# ============================================

echo -e "${BLUE}Group: Makeup Gain${NC}"

run_test \
    "No makeup gain (0dB)" \
    "$COMP_BIN -t -20 -r 4 -m 0 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_makeup_0.wav" \
    "Done"

run_test \
    "Moderate makeup (+3dB)" \
    "$COMP_BIN -t -20 -r 4 -m 3 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_makeup_3.wav" \
    "Done"

run_test \
    "Aggressive makeup (+8dB)" \
    "$COMP_BIN -t -20 -r 4 -m 8 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_makeup_8.wav" \
    "Done"

run_test \
    "Negative makeup (-2dB)" \
    "$COMP_BIN -t -20 -r 4 -m -2 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_makeup_minus.wav" \
    "Done"

echo ""

# ============================================
# Stereo Linking Mode Tests
# ============================================

echo -e "${BLUE}Group: Stereo Linking Modes${NC}"

run_test \
    "Independent channel linking" \
    "$COMP_BIN -link independent -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_link_indep.wav" \
    "Done"

run_test \
    "Average channel linking" \
    "$COMP_BIN -link average -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_link_avg.wav" \
    "Done"

run_test \
    "Max (loudest) channel linking" \
    "$COMP_BIN -link max -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_link_max.wav" \
    "Done"

run_test \
    "RMS channel linking" \
    "$COMP_BIN -link rms -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_link_rms.wav" \
    "Done"

echo ""

# ============================================
# Envelope Detection Mode Tests
# ============================================

echo -e "${BLUE}Group: Envelope Detection Modes${NC}"

run_test \
    "Peak detection" \
    "$COMP_BIN -env peak -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_env_peak.wav" \
    "Done"

run_test \
    "RMS detection" \
    "$COMP_BIN -env rms -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_env_rms.wav" \
    "Done"

run_test \
    "True RMS detection" \
    "$COMP_BIN -env truerms -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_env_truerms.wav" \
    "Done"

echo ""

# ============================================
# Release Curve Tests
# ============================================

echo -e "${BLUE}Group: Release Curve Types${NC}"

run_test \
    "Linear release" \
    "$COMP_BIN -rel linear -t -20 -r 4 -rl 100 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_rel_linear.wav" \
    "Done"

run_test \
    "Exponential release" \
    "$COMP_BIN -rel exponential -t -20 -r 4 -rl 100 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_rel_exp.wav" \
    "Done"

echo ""

# ============================================
# Mix (Dry/Wet) Tests
# ============================================

echo -e "${BLUE}Group: Dry/Wet Mix${NC}"

run_test \
    "Fully wet (0.0)" \
    "$COMP_BIN -mix 0.0 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_mix_wet.wav" \
    "Done"

run_test \
    "50% blend (0.5)" \
    "$COMP_BIN -mix 0.5 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_mix_blend.wav" \
    "Done"

run_test \
    "Fully dry (1.0 - bypass)" \
    "$COMP_BIN -mix 1.0 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_mix_dry.wav" \
    "Done"

echo ""

# ============================================
# Bypass Test
# ============================================

echo -e "${BLUE}Group: Bypass & Pass-through${NC}"

run_test \
    "Bypass mode (pass-through)" \
    "$COMP_BIN -bypass -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_bypass.wav" \
    "Done"

echo ""

# ============================================
# Lookahead Tests
# ============================================

echo -e "${BLUE}Group: Lookahead Buffer${NC}"

run_test \
    "No lookahead (0ms)" \
    "$COMP_BIN -la 0 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_la_0.wav" \
    "Done"

run_test \
    "Small lookahead (2ms)" \
    "$COMP_BIN -la 2 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_la_2.wav" \
    "Done"

run_test \
    "Moderate lookahead (5ms)" \
    "$COMP_BIN -la 5 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_la_5.wav" \
    "Done"

run_test \
    "Max lookahead (10ms)" \
    "$COMP_BIN -la 10 -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_la_10.wav" \
    "Done"

echo ""

# ============================================
# CSV Export Tests
# ============================================

echo -e "${BLUE}Group: CSV Export${NC}"

run_test \
    "CSV export with basic compression" \
    "$COMP_BIN -t -20 -r 4 -csv $TEMP_DIR/gain_reduction.csv $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_csv.wav" \
    "Done"

check_file_exists \
    "CSV file created" \
    "$TEMP_DIR/gain_reduction.csv"

check_csv_valid \
    "CSV has valid structure" \
    "$TEMP_DIR/gain_reduction.csv"

run_test \
    "CSV export with tight compression" \
    "$COMP_BIN -t -10 -r 8 -a 2 -rl 50 -csv $TEMP_DIR/gain_tight.csv $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_csv_tight.wav" \
    "Done"

check_csv_valid \
    "Tight compression CSV valid" \
    "$TEMP_DIR/gain_tight.csv"

run_test \
    "CSV export with limiter" \
    "$COMP_BIN -t -5 -r 100 -a 1 -rl 100 -csv $TEMP_DIR/gain_limiter.csv $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_csv_limiter.wav" \
    "Done"

echo ""

# ============================================
# Verbose Output Tests
# ============================================

echo -e "${BLUE}Group: Verbose Output & Metering${NC}"

run_test \
    "Verbose output shows settings" \
    "$COMP_BIN -v -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_verbose.wav" \
    "COMPRESSOR SETTINGS"

run_test \
    "Verbose shows input metering" \
    "$COMP_BIN -v $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_meter1.wav" \
    "Sample Rate"

run_test \
    "Verbose shows summary metering" \
    "$COMP_BIN -v $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_meter2.wav" \
    "METERING SUMMARY"

run_test \
    "Verbose shows gain reduction" \
    "$COMP_BIN -v $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_meter3.wav" \
    "Gain Reduction"

echo ""

# ============================================
# Combined Parameter Tests
# ============================================

echo -e "${BLUE}Group: Real-world Compression Scenarios${NC}"

run_test \
    "Vocal leveling preset" \
    "$COMP_BIN -t -15 -r 4 -a 5 -rl 80 -m 4 -k 3 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_vocal.wav" \
    "Done"

run_test \
    "Drum bus compression" \
    "$COMP_BIN -link average -t -8 -r 2.5 -a 1 -rl 150 -m 2 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_drums.wav" \
    "Done"

run_test \
    "Bass guitar processing" \
    "$COMP_BIN -t -12 -r 6 -a 2 -rl 120 -m 4 -k 5 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_bass.wav" \
    "Done"

run_test \
    "Master limiter" \
    "$COMP_BIN -t -0.5 -r 1000 -a 0.1 -rl 100 -m 0 $TEMP_DIR/test_complex.wav $TEMP_DIR/comp_master.wav" \
    "Done"

run_test \
    "Transparent compression (gentle)" \
    "$COMP_BIN -t -25 -r 1.5 -a 30 -rl 200 -k 8 -m 2 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_transparent.wav" \
    "Done"

run_test \
    "RMS-based smooth compression" \
    "$COMP_BIN -env rms -rel exponential -t -18 -r 3 -a 10 -rl 120 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_smooth.wav" \
    "Done"

echo ""

# ============================================
# Different Input Signals
# ============================================

echo -e "${BLUE}Group: Multiple Input Frequencies${NC}"

run_test \
    "Compress 100Hz signal" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_100hz.wav $TEMP_DIR/comp_100hz.wav" \
    "Done"

run_test \
    "Compress 1kHz signal" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_1k.wav" \
    "Done"

run_test \
    "Compress 5kHz signal" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_5k.wav $TEMP_DIR/comp_5k.wav" \
    "Done"

run_test \
    "Compress longer duration" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_complex.wav $TEMP_DIR/comp_2sec.wav" \
    "Done"

echo ""

# ============================================
# Extreme Settings (Boundary Tests)
# ============================================

echo -e "${BLUE}Group: Boundary Conditions${NC}"

run_test \
    "No compression (ratio 1.0)" \
    "$COMP_BIN -r 1.0 -t -20 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_no_comp.wav" \
    "Done"

run_test \
    "Very low threshold (-60dB)" \
    "$COMP_BIN -t -60 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_very_low.wav" \
    "Done"

run_test \
    "Very fast attack (0.1ms)" \
    "$COMP_BIN -a 0.1 -r 4 -t -20 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ultrafast.wav" \
    "Done"

run_test \
    "Very slow release (2000ms)" \
    "$COMP_BIN -rl 2000 -r 4 -t -20 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_ultraslow.wav" \
    "Done"

echo ""

# ============================================
# Combination Tests
# ============================================

echo -e "${BLUE}Group: Feature Combinations${NC}"

run_test \
    "Soft knee + RMS + Exponential" \
    "$COMP_BIN -k 8 -env rms -rel exponential -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_combo1.wav" \
    "Done"

run_test \
    "CSV + Verbose + Makeup Gain" \
    "$COMP_BIN -v -m 6 -csv $TEMP_DIR/combo_meter.csv $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_combo2.wav" \
    "Done"

run_test \
    "Lookahead + RMS + Wide Knee" \
    "$COMP_BIN -la 8 -env rms -k 12 -t -15 -r 3 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_combo3.wav" \
    "Done"

run_test \
    "Limiter with lookahead and makeup" \
    "$COMP_BIN -la 10 -t -5 -r 100 -a 0.5 -rl 80 -m 3 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_combo4.wav" \
    "Done"

echo ""

# ============================================
# Output File Variations
# ============================================

echo -e "${BLUE}Group: Output File Handling${NC}"

run_test \
    "Output to different filename" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_renamed.wav" \
    "Done"

run_test \
    "Multiple compressions of same input" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_run1.wav && $COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_run2.wav" \
    "Done"

run_test \
    "Compress then re-compress" \
    "$COMP_BIN -t -20 -r 4 $TEMP_DIR/test_1k.wav $TEMP_DIR/comp_intermediate.wav && $COMP_BIN -t -15 -r 6 $TEMP_DIR/comp_intermediate.wav $TEMP_DIR/comp_double.wav" \
    "Done"

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
