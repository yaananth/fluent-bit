#!/bin/bash
# Send repeated test payloads to fluent-bit HTTP input to reproduce memory leak
# Usage: ./send_test_load.sh [num_requests] [delay_ms]

NUM_REQUESTS=${1:-1000}
DELAY_MS=${2:-100}
URL="http://localhost:8080/test"
PAYLOAD_FILE="sample_trigger.json"

if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "Error: $PAYLOAD_FILE not found"
    exit 1
fi

echo "Sending $NUM_REQUESTS requests with ${DELAY_MS}ms delay between each"
echo "Payload size: $(wc -c < $PAYLOAD_FILE) bytes"
echo "Target: $URL"
echo ""

# Function to get RSS memory for fluent-bit process
get_memory() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        ps -o rss= -p $(pgrep fluent-bit | head -1) 2>/dev/null | awk '{print $1}'
    else
        # Linux
        ps -o rss= -p $(pgrep fluent-bit | head -1) 2>/dev/null
    fi
}

START_MEM=$(get_memory)
echo "Initial memory (RSS): ${START_MEM} KB"
echo ""

for i in $(seq 1 $NUM_REQUESTS); do
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d @"$PAYLOAD_FILE" \
        "$URL" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    
    if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
        echo "Request $i failed with HTTP code: $HTTP_CODE"
    fi
    
    # Report memory every 100 requests
    if [ $((i % 100)) -eq 0 ]; then
        CURRENT_MEM=$(get_memory)
        MEM_INCREASE=$((CURRENT_MEM - START_MEM))
        echo "Request $i/$NUM_REQUESTS - Memory: ${CURRENT_MEM} KB (+${MEM_INCREASE} KB)"
    fi
    
    # Small delay to avoid overwhelming the server
    sleep $(echo "scale=3; $DELAY_MS / 1000" | bc)
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
    echo "⚠️  WARNING: Significant memory leak detected (>${AVG_PER_REQUEST}KB per request)"
elif [ $AVG_PER_REQUEST -gt 1 ]; then
    echo "⚠️  Possible memory leak (${AVG_PER_REQUEST}KB per request)"
else
    echo "✓ Memory usage appears stable"
fi
