#!/bin/bash
# Parallel stress test for memory leak validation
# Usage: ./stress_test.sh [total_requests] [parallel_workers]

TOTAL_REQUESTS=${1:-5000}
PARALLEL_WORKERS=${2:-10}
URL="http://localhost:8080/test"
PAYLOAD_FILE="/workspaces/fluent-bit/small_payload.json"

if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "Error: $PAYLOAD_FILE not found"
    exit 1
fi

# Get fluent-bit PID
PID=$(pgrep fluent-bit | head -1)
if [ -z "$PID" ]; then
    echo "Error: fluent-bit is not running"
    exit 1
fi

# Get initial memory
INITIAL_MEM=$(ps -p $PID -o rss= | tr -d ' ')
echo "=== Stress Test Configuration ==="
echo "PID: $PID"
echo "Total requests: $TOTAL_REQUESTS"
echo "Parallel workers: $PARALLEL_WORKERS"
echo "Payload: $(wc -c < $PAYLOAD_FILE) bytes, $(wc -l < $PAYLOAD_FILE) lines"
echo "Initial memory: $INITIAL_MEM KB"
echo ""

# Function to send requests in batch
worker() {
    local worker_id=$1
    local count=$2
    local success=0
    local failed=0
    
    for i in $(seq 1 $count); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d @"$PAYLOAD_FILE" \
            "$URL" 2>/dev/null)
        
        if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            ((success++))
        else
            ((failed++))
        fi
    done
    
    echo "$worker_id $success $failed"
}

# Calculate requests per worker
REQUESTS_PER_WORKER=$((TOTAL_REQUESTS / PARALLEL_WORKERS))
EXTRA_REQUESTS=$((TOTAL_REQUESTS % PARALLEL_WORKERS))

echo "Starting $PARALLEL_WORKERS workers..."
START_TIME=$(date +%s)

# Launch workers
for i in $(seq 1 $PARALLEL_WORKERS); do
    COUNT=$REQUESTS_PER_WORKER
    if [ $i -eq $PARALLEL_WORKERS ]; then
        COUNT=$((COUNT + EXTRA_REQUESTS))
    fi
    worker $i $COUNT &
done

# Monitor progress
while jobs -r | grep -q .; do
    sleep 3
    CURRENT_MEM=$(ps -p $PID -o rss= 2>/dev/null | tr -d ' ')
    if [ -n "$CURRENT_MEM" ]; then
        MEM_INCREASE=$((CURRENT_MEM - INITIAL_MEM))
        ELAPSED=$(($(date +%s) - START_TIME))
        echo "[${ELAPSED}s] Memory: $CURRENT_MEM KB (+$MEM_INCREASE KB) - Workers running: $(jobs -r | wc -l)"
    fi
done

# Wait for all workers
wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Collect results
echo ""
echo "All workers completed in ${ELAPSED}s"
sleep 2

# Final memory check
FINAL_MEM=$(ps -p $PID -o rss= 2>/dev/null | tr -d ' ')
TOTAL_INCREASE=$((FINAL_MEM - INITIAL_MEM))
AVG_PER_REQUEST=$((TOTAL_INCREASE * 1000 / TOTAL_REQUESTS))  # in bytes, convert to KB

echo ""
echo "=== Stress Test Results ==="
echo "Total requests:   $TOTAL_REQUESTS"
echo "Duration:         ${ELAPSED}s"
echo "Throughput:       $((TOTAL_REQUESTS / ELAPSED)) req/s"
echo ""
echo "Initial memory:   $INITIAL_MEM KB"
echo "Final memory:     $FINAL_MEM KB"
echo "Total increase:   $TOTAL_INCREASE KB"
echo "Avg per request:  $((AVG_PER_REQUEST / 1000)).$((AVG_PER_REQUEST % 1000)) KB"
echo ""

# Verdict
if [ $TOTAL_INCREASE -gt $((TOTAL_REQUESTS * 10 / 1000)) ]; then
    echo "⚠️  LEAK DETECTED: $(($TOTAL_INCREASE * 1000 / TOTAL_REQUESTS)) bytes per request"
    exit 1
else
    echo "✓ Memory usage stable: $(($TOTAL_INCREASE * 1000 / TOTAL_REQUESTS)) bytes per request"
    exit 0
fi
