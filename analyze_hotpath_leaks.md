# Hot Path Memory Leak Analysis

## Likely Culprits for Regular Memory Growth

Based on your large JSON payload (4500+ lines), here are the **hot path** issues causing regular memory growth:

### 1. **HTTP Input - Connection Buffer Not Reset After Processing** ⭐⭐⭐

**Location**: `plugins/in_http/http_conn.c` - `http_conn_event()` lines 98-110

```c
/* If we have extra bytes in our bytes, adjust the extra bytes */
if (0 < (conn->buf_len - request_len)) {
    memmove(conn->buf_data, &conn->buf_data[request_len],
            conn->buf_len - request_len);

    conn->buf_data[conn->buf_len - request_len] = '\0';
    conn->buf_len -= request_len;
}
else {
    memset(conn->buf_data, 0, request_len);  // ← Clears only request_len bytes
    conn->buf_len = 0;
}
```

**Problem**: For large payloads, if buffer was reallocated to 5MB but only 2MB is used, the buffer stays at 5MB forever. With multiple connections, this adds up quickly.

**Fix**: After processing, if buffer is significantly larger than chunk_size, reallocate down:

```c
else {
    conn->buf_len = 0;
    // Shrink oversized buffers back to chunk_size
    if (conn->buf_size > ctx->buffer_chunk_size * 2) {
        char *tmp = flb_realloc(conn->buf_data, ctx->buffer_chunk_size);
        if (tmp) {
            conn->buf_data = tmp;
            conn->buf_size = ctx->buffer_chunk_size;
        }
    }
}
```

### 2. **Log Event Encoder Not Being Reset** ⭐⭐⭐

**Location**: `plugins/in_http/http_prot.c` - `process_pack()` lines 278-373

```c
while (msgpack_unpack_next(&result, buf, size, &off) == MSGPACK_UNPACK_SUCCESS) {
    // ... process record ...
    
    flb_log_event_encoder_reset(&ctx->log_encoder);  // ← Only in loop
}
```

**Problem**: `log_encoder` accumulates internal buffers. With 4500-line JSON, if there are multiple records, the encoder buffer grows but isn't fully released.

**Fix**: Add explicit cleanup after the loop:

```c
msgpack_unpacked_destroy(&result);

// Ensure encoder buffers are fully released
flb_log_event_encoder_destroy(&ctx->log_encoder);
flb_log_event_encoder_init(&ctx->log_encoder, FLB_LOG_EVENT_FORMAT_DEFAULT);

return 0;
```

### 3. **Msgpack Unpacker Zone Allocator Leak** ⭐⭐

**Location**: Both `process_pack()` functions

**Problem**: `msgpack_unpacked_init` creates a zone allocator. For large payloads, this zone grows but may not be fully released on destroy.

**Fix**: Use `MSGPACK_UNPACKER_INIT_BUFFER_SIZE` to limit zone growth:

```c
msgpack_unpacked result;
msgpack_unpacked_init(&result);
// Add: Clear zone more aggressively
result.zone.chunk_size = MSGPACK_ZONE_CHUNK_SIZE;
```

### 4. **Azure Kusto - JSON Buffer Not Released in Streaming Path** ⭐⭐⭐

**Location**: `plugins/out_azure_kusto/azure_kusto.c` - `flb_azure_kusto_format_emit()`

```c
flb_sds_t json_record = flb_msgpack_raw_to_json_sds(mp_sbuf.data,
                                                    mp_sbuf.size,
                                                    escape_unicode);
if (!json_record) {
    // error handling
}

json_record = flb_sds_cat(json_record, "\n", 1);

if (emit_cb(ctx, json_record, cb_data) != 0) {
    flb_sds_destroy(json_record);  // ← Only destroyed on error
    // ...
}
```

**Problem**: `json_record` is passed to `emit_cb` which should destroy it, but if callback doesn't properly destroy for ALL code paths, it leaks.

**Fix**: Ensure callback always destroys. Already fixed in `discard_cb` and `concat_cb`, but verify all paths.

### 5. **Connection Context Memory Never Freed for Keep-Alive** ⭐⭐

**Location**: `plugins/in_http/http_conn.c`

**Problem**: For HTTP keep-alive connections, `http_conn` structures and their buffers persist. With large payloads causing buffer expansion, these never shrink.

**Fix**: Implement periodic connection cleanup or buffer shrinking.

## Reproduction Steps

1. **Build with memory profiling**:

```bash
chmod +x reproduce_leak.sh
./reproduce_leak.sh
```

2. **In another terminal, send load**:

```bash
chmod +x send_test_load.sh
./send_test_load.sh 1000 100  # 1000 requests, 100ms delay
```

3. **Monitor with Valgrind (more detailed)**:

```bash
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes \
         --log-file=/tmp/valgrind.log \
         ./build/bin/fluent-bit -c /tmp/fluent-bit-leak-test.conf
```

4. **Or use heaptrack on Linux**:

```bash
heaptrack ./build/bin/fluent-bit -c /tmp/fluent-bit-leak-test.conf
# Then send requests and analyze with: heaptrack_gui heaptrack.fluent-bit.*.gz
```

## Quick Test to Confirm Hot Path Issue

```bash
# Terminal 1: Start fluent-bit
./reproduce_leak.sh

# Terminal 2: Send one request and check memory
ps aux | grep fluent-bit  # Note RSS before
curl -X POST -H "Content-Type: application/json" -d @sample_trigger.json http://localhost:8080/test
ps aux | grep fluent-bit  # Note RSS after (should increase)

# Send 10 more and see if it keeps growing linearly
for i in {1..10}; do 
    curl -X POST -H "Content-Type: application/json" -d @sample_trigger.json http://localhost:8080/test
    sleep 0.5
done
ps aux | grep fluent-bit  # If RSS increased 10x the first request increase = hot path leak
```

## Expected Findings

- **If buffer shrinking is the issue**: Memory will grow in chunks (e.g., +5MB every few large requests)
- **If encoder is the issue**: Memory grows ~50-100KB per request
- **If keep-alive is the issue**: Memory grows based on number of unique client connections
- **If msgpack zone is the issue**: Memory grows proportional to JSON size (~10% of payload size)

Would you like me to implement the hot path fixes above?
