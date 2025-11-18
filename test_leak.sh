#!/bin/bash
# Simple memory leak test script
# Usage: ./test_leak.sh [num_requests]

NUM_REQUESTS=${1:-500}
URL="http://localhost:8080/test"
PAYLOAD_FILE="sample_trigger.json"

if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "Error: $PAYLOAD_FILE not found"
    exit 1
fi

# Get process memory in KB
get_memory() {
    pgrep fluent-bit > /dev/null 2>&1 || { echo "0"; return; }
    ps -o rss= -p $(pgrep fluent-bit | head -1) 2>/dev/null | tr -d ' '
}

echo "Sending $NUM_REQUESTS requests"
echo "Payload size: $(wc -c < $PAYLOAD_FILE) bytes ($(wc -l < $PAYLOAD_FILE) lines)"
echo "Target: $URL"
echo ""

START_MEM=$(get_memory)
echo "Initial memory (RSS): ${START_MEM} KB"
echo ""

for i in $(seq 1 $NUM_REQUESTS); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d @"$PAYLOAD_FILE" \
        "$URL")
    
    if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
        echo "Request $i failed with HTTP code: $HTTP_CODE"
    fi
    
    # Report memory every 100 requests
    if [ $((i % 100)) -eq 0 ]; then
        CURRENT_MEM=$(get_memory)
        MEM_INCREASE=$((CURRENT_MEM - START_MEM))
        echo "Request $i/$NUM_REQUESTS - Memory: ${CURRENT_MEM} KB (+${MEM_INCREASE} KB)"
    fi
    
    # Small delay
    sleep 0.05
done

END_MEM=$(get_memory)
TOTAL_INCREASE=$((END_MEM - START_MEM))
AVG_PER_REQUEST=$((TOTAL_INCREASE / NUM_REQUESTS))

echo ""
echo "=== Memory Leak Summary ==="
echo "Initial memory:  ${START_MEM} KB"
echo "Final memory:    ${END_MEM} KB"
echo "Total increase:  ${TOTAL_INCREASE} KB"
echo "Avg per request: ${AVG_PER_REQUEST} KB"
echo ""

if [ $AVG_PER_REQUEST -gt 10 ]; then
    echo "⚠️  WARNING: Significant memory leak detected (${AVG_PER_REQUEST}KB per request)"
    exit 1
elif [ $AVG_PER_REQUEST -gt 1 ]; then
    echo "⚠️  Possible memory leak (${AVG_PER_REQUEST}KB per request)"
    exit 1
else
    echo "✓ Memory usage appears stable"
    exit 0
fi
