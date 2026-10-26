/*
 * 53_smc_keys: every AppleSMC key, as format 1 JSON Lines.
 *
 * Replaces 34_smc_power_keys. Spec: the "Probe rebuild" project in Linear.
 * Output contract: FORMAT.md beside this file. Read-only: it opens the SMC
 * user client and only reads keys.
 *
 * After the header line it writes:
 *   smc_open   once: the IOServiceOpen result
 *   key_count  once: the #KEY reads and the count they returned
 *   smc_key    once per key index from 0 to count - 1, failed or not: the
 *              return code of each call, the key and type as raw FourCC bits,
 *              the size, and the raw bytes. Nothing is decoded; readers decode
 *              by type code. Probe 34 skipped a key whose index or info call
 *              failed; here that key is still a record, with its codes.
 * then the footer line.
 *
 * A value counts only when the call succeeded AND the SMC's own result byte is
 * 0. Probe 34 checked only the call, so it printed leftover buffer bytes as the
 * value of keys the SMC refused (79 keys on the mini, 2026-10-07, result codes
 * 82, 85, 89 and c7). Here those keys carry their codes and no bytes.
 *
 * The SMC call carries at most 32 value bytes (the AppleSMC ABI used by
 * smcFanControl, libsmc and powermetrics). The kernel refuses a read of a
 * larger key (0xe00002c2, 28 keys on the mini); should one ever succeed, its
 * record holds the 32 bytes returned and "truncated": true.
 */
#include <IOKit/IOKitLib.h>

#include "probe_json.h"

#define PROBE_NAME "53_smc_keys"
/* The small probes share one cap, far above what they write, so a runaway
   stops with reason "byte_cap" in its footer rather than being discarded
   whole by the app's output limit. */
#define BYTE_CAP (4ULL * 1024 * 1024)

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key;
    SMCVers vers;
    SMCPLimit pLimit;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    char bytes[32];
} SMCParam;

enum { kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };
#define KERNEL_INDEX_SMC 2
#define SMC_KEY_COUNT 0x234b4559u /* "#KEY" */

static pj_writer W;
static pj_ids g_ids;

static kern_return_t smc_call(io_connect_t conn, SMCParam *in, SMCParam *out) {
    size_t out_size = sizeof(SMCParam);
    memset(out, 0, sizeof *out);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &out_size);
}

static void field_kr(const char *name, kern_return_t kr) {
    pj_field(&W, name);
    pj_fmt(&W, "\"0x%08x\"", (unsigned)kr);
}

static void field_u32(const char *name, UInt32 v) {
    pj_field(&W, name);
    pj_fmt(&W, "\"%08x\"", (unsigned)v);
}

/* The SMC's own result byte for a call: 0 is success, anything else is the
   SMC refusing (for example 0x84, key not found). */
static void field_result(const char *name, const SMCParam *out) {
    pj_field(&W, name);
    pj_fmt(&W, "\"%02x\"", (unsigned char)out->result);
}

int main(void) {
    pj_init(&W, stdout, BYTE_CAP);
    /* The Mac's own identifiers are withheld here too; a lookup that failed
       means a header, a stopped footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;

    io_service_t smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    io_connect_t conn = 0;
    kern_return_t kr = smc ? IOServiceOpen(smc, mach_task_self(), 0, &conn) : kIOReturnNotFound;
    if (smc) IOObjectRelease(smc);
    if (pj_record_begin(&W, "smc_open")) {
        pj_field(&W, "found");
        pj_lit(&W, smc ? "true" : "false");
        field_kr("kr", kr);
        pj_record_end(&W);
    }
    if (kr != KERN_SUCCESS) {
        W.failures++;
        pj_footer(&W, W.capped ? "byte_cap" : NULL);
        return 0;
    }

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    in.key = SMC_KEY_COUNT;
    in.data8 = kSMCGetKeyInfo;
    kern_return_t info_kr = smc_call(conn, &in, &out);
    char info_result = out.result;
    memset(&in, 0, sizeof in);
    in.key = SMC_KEY_COUNT;
    in.keyInfo.dataSize = 4;
    in.data8 = kSMCReadKey;
    kern_return_t read_kr = smc_call(conn, &in, &out);
    UInt32 total = ((UInt32)(unsigned char)out.bytes[0] << 24) | ((UInt32)(unsigned char)out.bytes[1] << 16) |
                   ((UInt32)(unsigned char)out.bytes[2] << 8) | (UInt32)(unsigned char)out.bytes[3];
    int count_ok = info_kr == KERN_SUCCESS && read_kr == KERN_SUCCESS && info_result == 0 && out.result == 0;
    if (pj_record_begin(&W, "key_count")) {
        field_kr("info_kr", info_kr);
        pj_field(&W, "info_result");
        pj_fmt(&W, "\"%02x\"", (unsigned char)info_result);
        field_kr("read_kr", read_kr);
        field_result("read_result", &out);
        pj_bytes_field(&W, "bytes", (const unsigned char *)out.bytes, 4);
        pj_field(&W, "count");
        if (count_ok) pj_fmt(&W, "%u", (unsigned)total);
        else pj_lit(&W, "null");
        pj_record_end(&W);
    }
    if (!count_ok) {
        W.failures++;
        IOServiceClose(conn);
        pj_footer(&W, W.capped ? "byte_cap" : NULL);
        return 0;
    }

    for (UInt32 i = 0; i < total && !W.capped; i++) {
        memset(&in, 0, sizeof in);
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        kern_return_t index_kr = smc_call(conn, &in, &out);
        SMCParam index_out = out;
        UInt32 key = out.key;
        int have_key = index_kr == KERN_SUCCESS && index_out.result == 0 && key != 0;

        kern_return_t key_info_kr = kIOReturnNotReady, key_read_kr = kIOReturnNotReady;
        SMCParam info_out, read_out;
        memset(&info_out, 0, sizeof info_out);
        memset(&read_out, 0, sizeof read_out);
        if (have_key) {
            memset(&in, 0, sizeof in);
            in.key = key;
            in.data8 = kSMCGetKeyInfo;
            key_info_kr = smc_call(conn, &in, &info_out);
            if (key_info_kr == KERN_SUCCESS && info_out.result == 0) {
                memset(&in, 0, sizeof in);
                in.key = key;
                in.keyInfo.dataSize = info_out.keyInfo.dataSize;
                in.keyInfo.dataType = info_out.keyInfo.dataType;
                in.data8 = kSMCReadKey;
                key_read_kr = smc_call(conn, &in, &read_out);
            }
        }
        int have_info = have_key && key_info_kr == KERN_SUCCESS && info_out.result == 0;
        int have_value = have_info && key_read_kr == KERN_SUCCESS && read_out.result == 0;
        if (!have_value) W.failures++;

        if (!pj_record_begin(&W, "smc_key")) break;
        pj_field(&W, "index");
        pj_fmt(&W, "%u", (unsigned)i);
        field_kr("index_kr", index_kr);
        field_result("index_result", &index_out);
        pj_field(&W, "key");
        if (have_key) pj_fmt(&W, "\"%08x\"", (unsigned)key);
        else pj_lit(&W, "null");
        if (have_key) {
            field_kr("info_kr", key_info_kr);
            field_result("info_result", &info_out);
        }
        if (have_info) {
            field_u32("type", info_out.keyInfo.dataType);
            pj_field(&W, "size");
            pj_fmt(&W, "%u", (unsigned)info_out.keyInfo.dataSize);
            pj_field(&W, "attributes");
            pj_fmt(&W, "\"%02x\"", (unsigned char)info_out.keyInfo.dataAttributes);
            field_kr("read_kr", key_read_kr);
            field_result("read_result", &read_out);
        }
        if (have_value) {
            UInt32 size = info_out.keyInfo.dataSize;
            UInt32 n = size > sizeof read_out.bytes ? (UInt32)sizeof read_out.bytes : size;
            /* Withheld where it holds the Mac's own identifiers: key RECI is
               the chip ID, big-endian (measured on the mini, PR 693 review). */
            pj_bytes_field(&W, "bytes", (const unsigned char *)read_out.bytes, n);
            pj_field(&W, "truncated");
            pj_lit(&W, size > sizeof read_out.bytes ? "true" : "false");
        }
        pj_record_end(&W);
    }

    IOServiceClose(conn);
    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
