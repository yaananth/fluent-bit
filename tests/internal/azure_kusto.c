#include "flb_tests_internal.h"

#include <stdio.h>
#include <string.h>

#include <fluent-bit/flb_event.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_mem.h>
#include <fluent-bit/flb_sds.h>

#include "../../plugins/out_azure_kusto/azure_kusto.h"

#define AK_RECORDS          64
#define AK_PAYLOAD_SIZE     (64 * 1024)
#define AK_ITERATIONS       20

struct chunk_fixture {
    struct flb_event_chunk *chunk;
    char *data;
};

static int chunk_fixture_init(struct chunk_fixture *fixture)
{
    int i;
    int ret;
    char *payload;
    struct flb_log_event_encoder encoder;

    payload = flb_malloc(AK_PAYLOAD_SIZE);
    if (!payload) {
        return -1;
    }

    memset(payload, 'A', AK_PAYLOAD_SIZE);

    ret = flb_log_event_encoder_init(&encoder, FLB_LOG_EVENT_FORMAT_DEFAULT);
    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        flb_free(payload);
        return -1;
    }

    for (i = 0; i < AK_RECORDS; i++) {
        ret = flb_log_event_encoder_begin_record(&encoder);
        if (ret != FLB_EVENT_ENCODER_SUCCESS) {
            break;
        }

        ret = flb_log_event_encoder_set_current_timestamp(&encoder);
        if (ret != FLB_EVENT_ENCODER_SUCCESS) {
            break;
        }

        ret = flb_log_event_encoder_append_body_values(&encoder,
                                                        FLB_LOG_EVENT_CSTRING_VALUE("log"),
                                                        FLB_LOG_EVENT_STRING_VALUE(payload, AK_PAYLOAD_SIZE));
        if (ret != FLB_EVENT_ENCODER_SUCCESS) {
            break;
        }

        ret = flb_log_event_encoder_commit_record(&encoder);
        if (ret != FLB_EVENT_ENCODER_SUCCESS) {
            break;
        }
    }

    flb_free(payload);

    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        flb_log_event_encoder_destroy(&encoder);
        return -1;
    }

    fixture->data = flb_malloc(encoder.buffer.size);
    if (!fixture->data) {
        flb_log_event_encoder_destroy(&encoder);
        return -1;
    }

    memcpy(fixture->data, encoder.buffer.data, encoder.buffer.size);

    fixture->chunk = flb_event_chunk_create(FLB_EVENT_TYPE_LOGS,
                                            AK_RECORDS,
                                            "azure.kusto.test",
                                            strlen("azure.kusto.test"),
                                            fixture->data,
                                            encoder.buffer.size);
    flb_log_event_encoder_destroy(&encoder);

    if (!fixture->chunk) {
        flb_free(fixture->data);
        fixture->data = NULL;
        return -1;
    }

    return 0;
}

static void chunk_fixture_destroy(struct chunk_fixture *fixture)
{
    if (fixture->chunk) {
        flb_event_chunk_destroy(fixture->chunk);
    }
    if (fixture->data) {
        flb_free(fixture->data);
    }
}

static size_t current_rss_bytes(void)
{
    FILE *fp;
    char line[256];
    size_t rss_kb = 0;

    fp = fopen("/proc/self/status", "r");
    if (!fp) {
        return 0;
    }

    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "VmRSS:", 6) == 0) {
            sscanf(line + 6, "%zu", &rss_kb);
            break;
        }
    }

    fclose(fp);
    return rss_kb * 1024;
}

struct azure_kusto_test_ctx {
    struct flb_azure_kusto ctx;
    struct flb_output_instance ins;
};

static void azure_kusto_test_ctx_init(struct azure_kusto_test_ctx *tctx)
{
    memset(tctx, 0, sizeof(*tctx));
    tctx->ctx.ins = &tctx->ins;
    tctx->ctx.log_key = flb_sds_create(FLB_AZURE_KUSTO_DEFAULT_LOG_KEY);
}

static void azure_kusto_test_ctx_destroy(struct azure_kusto_test_ctx *tctx)
{
    if (tctx->ctx.log_key) {
        flb_sds_destroy(tctx->ctx.log_key);
    }
}

struct concat_cb_ctx {
    flb_sds_t buffer;
};

static int concat_cb(struct flb_azure_kusto *ctx, flb_sds_t record, void *data)
{
    struct concat_cb_ctx *cb = data;

    cb->buffer = flb_sds_cat(cb->buffer, record, flb_sds_len(record));
    flb_sds_destroy(record);
    if (!cb->buffer) {
        return -1;
    }
    return 0;
}

static int discard_cb(struct flb_azure_kusto *ctx, flb_sds_t record, void *data)
{
    (void) ctx;
    (void) data;
    flb_sds_destroy(record);
    return 0;
}

static size_t measure_memory(const struct chunk_fixture *fixture, int streaming)
{
#ifdef __GLIBC__
    size_t before;
    size_t after;
    size_t peak;
    size_t current;
    int i;
    int ret;
    struct azure_kusto_test_ctx tctx;
    struct flb_config config;

    memset(&config, 0, sizeof(config));
    azure_kusto_test_ctx_init(&tctx);

    before = current_rss_bytes();
    peak = before;

    for (i = 0; i < AK_ITERATIONS; i++) {
        if (streaming) {
            ret = flb_azure_kusto_format_emit(&tctx.ctx, fixture->chunk,
                                              &config, discard_cb, NULL);
        }
        else {
            struct concat_cb_ctx cb;

            cb.buffer = flb_sds_create_size(1024);
            if (!cb.buffer) {
                ret = -1;
            }
            else {
                ret = flb_azure_kusto_format_emit(&tctx.ctx, fixture->chunk,
                                                  &config, concat_cb, &cb);
                flb_sds_destroy(cb.buffer);
            }
        }

        if (ret != 0) {
            break;
        }

        current = current_rss_bytes();
        if (current > peak) {
            peak = current;
        }
    }

    after = peak;
    azure_kusto_test_ctx_destroy(&tctx);

    if (ret != 0) {
        return (size_t) -1;
    }

    return after - before;
#else
    (void) fixture;
    (void) streaming;
    return 0;
#endif
}

void flb_test_azure_kusto_streaming_memory(void)
{
    struct chunk_fixture fixture;
#ifdef __GLIBC__
    size_t non_stream;
    size_t stream;
#endif

    if (chunk_fixture_init(&fixture) != 0) {
        TEST_CHECK(!"chunk fixture init failed");
        return;
    }

#ifndef __GLIBC__
    TEST_CHECK(1);
    TEST_MSG("skipped: glibc required for mallinfo2");
    chunk_fixture_destroy(&fixture);
    return;
#else
    non_stream = measure_memory(&fixture, FLB_FALSE);
    stream = measure_memory(&fixture, FLB_TRUE);

    fprintf(stderr, "non_stream=%zu stream=%zu\n", non_stream, stream);
    TEST_CHECK(non_stream != (size_t) -1);
    TEST_CHECK(stream != (size_t) -1);
    TEST_CHECK(stream < (512 * 1024));
    TEST_CHECK(non_stream > stream * 2);

    chunk_fixture_destroy(&fixture);
#endif
}

TEST_LIST = {
    {"streaming_memory", flb_test_azure_kusto_streaming_memory},
    {NULL, NULL}
};
