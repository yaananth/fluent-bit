#!/bin/bash
# Memory leak reproduction script for fluent-bit HTTP input -> Azure Kusto output
# Usage: ./reproduce_leak.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "=== Building fluent-bit with debug symbols and AddressSanitizer ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Build with ASAN and debug symbols
cmake -DCMAKE_BUILD_TYPE=Debug \
      -DFLB_DEBUG=On \
      -DFLB_SANITIZE_ADDRESS=On \
      -DFLB_SANITIZE_UNDEFINED=Off \
      ..

make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu) fluent-bit

echo ""
echo "=== Build complete. Starting fluent-bit with test configuration ==="
echo ""

# Create test config
cat > /tmp/fluent-bit-leak-test.conf <<'EOF'
[SERVICE]
    Flush        1
    Log_Level    debug
    Parsers_File parsers.conf

[INPUT]
    Name              http
    Host              0.0.0.0
    Port              8080
    Tag               test.http
    # Buffer settings for large payloads
    buffer_max_size   5M
    buffer_chunk_size 1M

[OUTPUT]
    Name              stdout
    Match             *
    Format            json_lines
EOF

echo "Config file created at /tmp/fluent-bit-leak-test.conf"
echo ""
echo "=== Starting fluent-bit (Ctrl+C to stop) ==="
echo "Send test payloads with: curl -X POST -H 'Content-Type: application/json' -d @sample_trigger.json http://localhost:8080/test"
echo ""

# Run with ASAN options
export ASAN_OPTIONS=detect_leaks=1:malloc_context_size=15:log_path=/tmp/asan.log
./bin/fluent-bit -c /tmp/fluent-bit-leak-test.conf
