/*
 * probe_json.h: the shared JSON Lines writer for the WhatCable test-kit probes.
 *
 * Header-only on purpose. scripts/smoke-test.sh compiles every
 * .c file in probes/test-kit into its own binary, one clang call per file, so shared
 * code cannot live in a second .c file. Each probe includes this header once.
 *
 * The output contract is probes/test-kit/FORMAT.md (format 1). Every value is
 * written with its CoreFoundation type: integers keep the width CF reports and
 * their raw bits in hex, never a sign; data is written in full; nothing is cut
 * short. A value the writer cannot represent is written as an explicit failure,
 * never skipped.
 *
 * It also holds the privacy rules every probe shares (the end of this file):
 * the Mac's own identifiers, read once per run and searched for in every form
 * they are known to take, and the key names withheld wherever they appear.
 */
#ifndef PROBE_JSON_H
#define PROBE_JSON_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PJ_FORMAT_VERSION 1
#define PJ_MAX_DEPTH 64
#define PJ_FN static __attribute__((unused))

/* scripts/smoke-test.sh passes -DPROBE_SOURCE_SHA256="\"<hex>\"". A probe built
   any other way says so in its header line. */
#ifndef PROBE_SOURCE_SHA256
#define PROBE_SOURCE_SHA256 "unstamped"
#endif

/* Decides whether a value is written. key is the dictionary key for dictionary
   values and NULL otherwise (array and set members, and dictionary keys being
   checked themselves). Return 0 to write the value, PJ_WITHHOLD to write
   {"t":"withheld"} (personal: counted in the footer), PJ_SKIP to write
   {"t":"skipped"} (recorded on purpose as not hardware, such as boot state), or
   PJ_PART to withhold only some bytes of a CFData value: the writer asks the
   mask hook which ones. PJ_PART on any other type, or with no mask hook,
   withholds the whole value. */
#define PJ_WITHHOLD 1
#define PJ_SKIP 2
#define PJ_PART 3
typedef int (*pj_withhold_fn)(void *ctx, CFStringRef key, CFTypeRef value);

/* For PJ_PART: sets mask[i] to 1 for each of the n bytes in b to withhold.
   mask arrives zeroed. */
typedef void (*pj_mask_fn)(void *ctx, const unsigned char *b, size_t n, unsigned char *mask);

typedef struct {
    FILE *out;
    FILE *rec;                   /* the record being built, in memory: see pj_record_begin */
    char *rec_buf;
    size_t rec_len;
    unsigned long long bytes;    /* bytes written to out so far */
    unsigned long long cap;      /* a record that would take bytes past this is not written; 0 means none */
    int capped;                  /* set once a record has been refused by the cap */
    unsigned long long records;  /* records written, header and footer excluded */
    unsigned long long failures; /* values or reads written as failures */
    unsigned long long withheld; /* values replaced by the withheld marker */
    pj_withhold_fn withhold;
    pj_mask_fn mask;             /* called with withhold_ctx */
    void *withhold_ctx;
    int depth;                   /* depth of the value being decided, for the hook: an
                                    entry's own properties are at depth 1 */
} pj_writer;

PJ_FN void pj_init(pj_writer *w, FILE *out, unsigned long long cap) {
    memset(w, 0, sizeof *w);
    w->out = out;
    w->cap = cap;
}

/* Out of memory in a probe is fatal on purpose: the run then has no footer,
   which every reader treats as an incomplete capture. */
PJ_FN void *pj_xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        fputs("probe_json: out of memory\n", stderr);
        abort();
    }
    return p;
}

PJ_FN void pj_raw(pj_writer *w, const char *s, size_t n) {
    if (n == 0) return;
    if (w->rec) { /* inside a record: held until pj_record_end knows it fits */
        fwrite(s, 1, n, w->rec);
        return;
    }
    fwrite(s, 1, n, w->out);
    w->bytes += n;
}

PJ_FN void pj_lit(pj_writer *w, const char *s) { pj_raw(w, s, strlen(s)); }

PJ_FN void pj_fmt(pj_writer *w, const char *fmt, ...) {
    char buf[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof buf) {
        pj_raw(w, buf, (size_t)n);
        return;
    }
    char *big = pj_xmalloc((size_t)n + 1);
    va_start(ap, fmt);
    vsnprintf(big, (size_t)n + 1, fmt, ap);
    va_end(ap);
    pj_raw(w, big, (size_t)n);
    free(big);
}

/* Writes b[0..n) as a quoted lowercase hex string. */
PJ_FN void pj_hex(pj_writer *w, const unsigned char *b, size_t n) {
    static const char digits[] = "0123456789abcdef";
    char buf[4096];
    size_t used = 0;
    pj_raw(w, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        buf[used++] = digits[b[i] >> 4];
        buf[used++] = digits[b[i] & 15];
        if (used == sizeof buf) {
            pj_raw(w, buf, used);
            used = 0;
        }
    }
    pj_raw(w, buf, used);
    pj_raw(w, "\"", 1);
}

/* 1 when b[0..n) is well-formed UTF-8: no overlong forms, no surrogates,
   nothing above U+10FFFF. */
PJ_FN int pj_utf8_valid(const unsigned char *b, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = b[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        size_t len;
        uint32_t cp;
        if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; }
        else return 0;
        if (i + len > n) return 0;
        for (size_t k = 1; k < len; k++) {
            if ((b[i + k] & 0xC0) != 0x80) return 0;
            cp = (cp << 6) | (b[i + k] & 0x3F);
        }
        if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000)) return 0;
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
        i += len;
    }
    return 1;
}

/* Writes b[0..n), which must be valid UTF-8, as a JSON string. */
PJ_FN void pj_json_string(pj_writer *w, const unsigned char *b, size_t n) {
    static const char digits[] = "0123456789abcdef";
    size_t run = 0; /* start of the pending stretch that needs no escaping */
    pj_raw(w, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = b[i];
        const char *esc = NULL;
        char u[7];
        if (c == '"') esc = "\\\"";
        else if (c == '\\') esc = "\\\\";
        else if (c == '\n') esc = "\\n";
        else if (c == '\r') esc = "\\r";
        else if (c == '\t') esc = "\\t";
        else if (c < 0x20) {
            u[0] = '\\'; u[1] = 'u'; u[2] = '0'; u[3] = '0';
            u[4] = digits[c >> 4]; u[5] = digits[c & 15]; u[6] = 0;
            esc = u;
        }
        if (esc) {
            pj_raw(w, (const char *)b + run, i - run);
            pj_lit(w, esc);
            run = i + 1;
        }
    }
    pj_raw(w, (const char *)b + run, n - run);
    pj_raw(w, "\"", 1);
}

/* A C string (an IOKit name, a literal): a JSON string when it is valid UTF-8,
   otherwise {"hex":"..."} so no byte is lost or mangled. */
PJ_FN void pj_text(pj_writer *w, const char *s) {
    size_t n = strlen(s);
    if (pj_utf8_valid((const unsigned char *)s, n)) {
        pj_json_string(w, (const unsigned char *)s, n);
        return;
    }
    pj_lit(w, "{\"hex\":");
    pj_hex(w, (const unsigned char *)s, n);
    pj_lit(w, "}");
}

/* Writes ,"name": after a record's opening. Names are literals in probe code. */
PJ_FN void pj_field(pj_writer *w, const char *name) {
    pj_raw(w, ",\"", 2);
    pj_lit(w, name);
    pj_raw(w, "\":", 2);
}

/* s as UTF-8 in a malloc'd buffer, or NULL when UTF-8 cannot carry it exactly
   (a lone surrogate). The caller frees. */
PJ_FN unsigned char *pj_cf_utf8(CFStringRef s, size_t *out_len) {
    CFIndex len = CFStringGetLength(s);
    CFIndex max = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8);
    if (max < 0) return NULL;
    unsigned char *buf = pj_xmalloc((size_t)max + 1);
    CFIndex used = 0;
    CFIndex done = CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, buf, max, &used);
    if (done != len || !pj_utf8_valid(buf, (size_t)used)) {
        free(buf);
        return NULL;
    }
    *out_len = (size_t)used;
    return buf;
}

/* s's UTF-16 code units, big-endian, as a quoted hex string. */
PJ_FN void pj_utf16_hex(pj_writer *w, CFStringRef s) {
    CFIndex len = CFStringGetLength(s);
    UniChar *u = pj_xmalloc(sizeof(UniChar) * (size_t)len);
    CFStringGetCharacters(s, CFRangeMake(0, len), u);
    unsigned char *b = pj_xmalloc((size_t)len * 2);
    for (CFIndex i = 0; i < len; i++) {
        b[2 * i] = (unsigned char)(u[i] >> 8);
        b[2 * i + 1] = (unsigned char)(u[i] & 0xFF);
    }
    pj_hex(w, b, (size_t)len * 2);
    free(b);
    free(u);
}

/* A CFString as a bare JSON string (keys, class names, paths), or
   {"utf16":"..."} when UTF-8 cannot carry it. */
PJ_FN void pj_cfstring(pj_writer *w, CFStringRef s) {
    size_t n = 0;
    unsigned char *b = pj_cf_utf8(s, &n);
    if (b) {
        pj_json_string(w, b, n);
        free(b);
        return;
    }
    pj_lit(w, "{\"utf16\":");
    pj_utf16_hex(w, s);
    pj_lit(w, "}");
}

PJ_FN void pj_number(pj_writer *w, CFNumberRef n) {
    CFIndex size = CFNumberGetByteSize(n);
    if (CFNumberIsFloatType(n)) {
        if (size == 4) {
            float f;
            if (CFNumberGetValue(n, kCFNumberFloat32Type, &f)) {
                uint32_t b;
                memcpy(&b, &f, sizeof b);
                pj_fmt(w, "{\"t\":\"float\",\"bits\":32,\"hex\":\"%08x\"}", b);
                return;
            }
        } else {
            double d;
            if (CFNumberGetValue(n, kCFNumberFloat64Type, &d)) {
                uint64_t b;
                memcpy(&b, &d, sizeof b);
                pj_fmt(w, "{\"t\":\"float\",\"bits\":64,\"hex\":\"%016llx\"}", (unsigned long long)b);
                return;
            }
        }
    } else {
        int64_t v = 0;
        if (CFNumberGetValue(n, kCFNumberSInt64Type, &v)) {
            int bits = (int)size * 8;
            if (bits != 8 && bits != 16 && bits != 32) bits = 64;
            uint64_t raw = (uint64_t)v;
            if (bits < 64) raw &= (1ULL << bits) - 1;
            pj_fmt(w, "{\"t\":\"int\",\"bits\":%d,\"hex\":\"%0*llx\"}", bits, bits / 4, (unsigned long long)raw);
            return;
        }
    }
    w->failures++;
    pj_fmt(w, "{\"t\":\"failed\",\"what\":\"number\",\"cf_number_type\":%d}", (int)CFNumberGetType(n));
}

typedef struct {
    CFTypeRef k;
    CFTypeRef v;
} pj_pair;

/* String keys first, in CFStringCompare order; any other key after them by
   CF type ID. Only determinism matters: dictionary order means nothing. */
PJ_FN int pj_pair_cmp(const void *a, const void *b) {
    CFTypeRef ka = ((const pj_pair *)a)->k, kb = ((const pj_pair *)b)->k;
    CFTypeID st = CFStringGetTypeID();
    int sa = CFGetTypeID(ka) == st, sb = CFGetTypeID(kb) == st;
    if (sa && sb) return (int)CFStringCompare((CFStringRef)ka, (CFStringRef)kb, 0);
    if (sa != sb) return sa ? -1 : 1;
    CFTypeID ta = CFGetTypeID(ka), tb = CFGetTypeID(kb);
    return ta < tb ? -1 : (ta > tb ? 1 : 0);
}

PJ_FN void pj_value(pj_writer *w, CFTypeRef v, CFStringRef key, int depth);

/* Keys whose string value names the process holding a device as "pid N, name"
   (Darryl, 2026-10-08: the name is kept, Apple's or a third party's, never
   the PID). Measured in the customer-probe corpus: UsbExclusiveOwner (2183
   values) and iAPAuthenticator (12); IOUserClientCreator is skipped with its
   connection. Driver names under the same keys carry no prefix and are
   written as they are. */
static const char *const kPjProcessNameKeys[] = {"UsbExclusiveOwner", "iAPAuthenticator", NULL};

PJ_FN int pj_process_name_key(CFStringRef key) {
    char k[64];
    if (!key || !CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8)) return 0;
    for (int i = 0; kPjProcessNameKeys[i]; i++)
        if (strcmp(k, kPjProcessNameKeys[i]) == 0) return 1;
    return 0;
}

/* When b[0..n) is "pid N, name" with at least one digit and a name, the
   offset of name; otherwise 0. */
PJ_FN size_t pj_process_name_at(const unsigned char *b, size_t n) {
    size_t i = 4;
    if (n < 7 || memcmp(b, "pid ", 4) != 0) return 0;
    while (i < n && b[i] >= '0' && b[i] <= '9') i++;
    if (i == 4 || i + 2 >= n || b[i] != ',' || b[i + 1] != ' ') return 0;
    return i + 2;
}

PJ_FN void pj_members(pj_writer *w, const void **items, CFIndex n, int depth) {
    for (CFIndex i = 0; i < n; i++) {
        if (i) pj_raw(w, ",", 1);
        pj_value(w, items[i], NULL, depth + 1);
    }
}

/* The mask hook's verdict on b[0..n): a malloc'd mask (1 = withhold) and how
   many bytes it marks. The caller frees the mask. */
PJ_FN unsigned char *pj_mask_bytes(pj_writer *w, const unsigned char *b, size_t n, size_t *masked) {
    unsigned char *mask = pj_xmalloc(n ? n : 1);
    memset(mask, 0, n ? n : 1);
    if (w->mask) w->mask(w->withhold_ctx, b, n, mask);
    *masked = 0;
    for (size_t i = 0; i < n; i++) *masked += mask[i] ? 1 : 0;
    return mask;
}

/* b[0..n) as quoted hex with the masked bytes written as 00, then the masked
   stretches as [[offset,length],...] after sep. */
PJ_FN void pj_masked_hex(pj_writer *w, const unsigned char *b, size_t n, const unsigned char *mask, const char *sep) {
    unsigned char *out = pj_xmalloc(n ? n : 1);
    for (size_t i = 0; i < n; i++) out[i] = mask[i] ? 0 : b[i];
    pj_hex(w, out, n);
    free(out);
    pj_lit(w, sep);
    pj_raw(w, "[", 1);
    int first = 1;
    for (size_t i = 0; i < n;) {
        if (!mask[i]) {
            i++;
            continue;
        }
        size_t start = i;
        while (i < n && mask[i]) i++;
        pj_fmt(w, "%s[%zu,%zu]", first ? "" : ",", start, i - start);
        first = 0;
    }
    pj_raw(w, "]", 1);
}

/* {"t":"data",...,"withheld":[[offset,length],...]}: data with the masked bytes
   written as 00 and listed as ranges, or {"t":"withheld"} when every byte is
   masked. Counted once as withheld either way. */
PJ_FN void pj_data_part(pj_writer *w, CFDataRef d) {
    size_t n = (size_t)CFDataGetLength(d), masked = 0;
    const unsigned char *b = CFDataGetBytePtr(d);
    unsigned char *mask = pj_mask_bytes(w, b, n, &masked);
    w->withheld++;
    if (masked == n) { /* nothing left to keep: the plain marker says so more simply */
        pj_lit(w, "{\"t\":\"withheld\"}");
    } else {
        pj_fmt(w, "{\"t\":\"data\",\"len\":%zu,\"hex\":", n);
        pj_masked_hex(w, b, n, mask, ",\"withheld\":");
        pj_lit(w, "}");
    }
    free(mask);
}

/* A small probe's raw-bytes field (a descriptor, an SMC value): ,"name":"<hex>".
   Bytes the mask hook marks (the Mac's own identifiers) are written as 00 and
   listed in a sibling field, ,"name_withheld":[[offset,length],...]; when every
   byte is marked the field is {"t":"withheld"}. Either way it counts once in
   the footer's withheld, as pj_data_part does. */
PJ_FN void pj_bytes_field(pj_writer *w, const char *name, const unsigned char *b, size_t n) {
    size_t masked = 0;
    unsigned char *mask = pj_mask_bytes(w, b, n, &masked);
    pj_field(w, name);
    if (masked == 0) {
        pj_hex(w, b, n);
    } else if (masked == n) {
        w->withheld++;
        pj_lit(w, "{\"t\":\"withheld\"}");
    } else {
        w->withheld++;
        char sep[96];
        snprintf(sep, sizeof sep, ",\"%s_withheld\":", name);
        pj_masked_hex(w, b, n, mask, sep);
    }
    free(mask);
}

/* One typed value. See FORMAT.md for every shape this can produce. */
PJ_FN void pj_value(pj_writer *w, CFTypeRef v, CFStringRef key, int depth) {
    if (!v) {
        w->failures++;
        pj_lit(w, "{\"t\":\"failed\",\"what\":\"null_reference\"}");
        return;
    }
    if (w->withhold) {
        w->depth = depth;
        int verdict = w->withhold(w->withhold_ctx, key, v);
        if (verdict == PJ_SKIP) {
            pj_lit(w, "{\"t\":\"skipped\"}");
            return;
        }
        if (verdict == PJ_PART && w->mask && CFGetTypeID(v) == CFDataGetTypeID()) {
            pj_data_part(w, (CFDataRef)v);
            return;
        }
        if (verdict) {
            w->withheld++;
            pj_lit(w, "{\"t\":\"withheld\"}");
            return;
        }
    }
    if (depth > PJ_MAX_DEPTH) {
        w->failures++;
        pj_lit(w, "{\"t\":\"failed\",\"what\":\"depth\"}");
        return;
    }
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        size_t n = 0;
        unsigned char *b = pj_cf_utf8((CFStringRef)v, &n);
        int owner = pj_process_name_key(key);
        if (b) {
            size_t at = owner ? pj_process_name_at(b, n) : 0; /* "pid N, name": the name only */
            pj_lit(w, "{\"t\":\"str\",\"v\":");
            pj_json_string(w, b + at, n - at);
            pj_lit(w, "}");
            free(b);
        } else if (owner) {
            /* Not UTF-8, so the prefix cannot be told from the name: never
               written, counted as a failure (no such value has been seen). */
            w->failures++;
            pj_lit(w, "{\"t\":\"failed\",\"what\":\"process_name\"}");
        } else {
            pj_lit(w, "{\"t\":\"str\",\"utf16\":");
            pj_utf16_hex(w, (CFStringRef)v);
            pj_lit(w, "}");
        }
        return;
    }
    if (t == CFNumberGetTypeID()) {
        pj_number(w, (CFNumberRef)v);
        return;
    }
    if (t == CFBooleanGetTypeID()) {
        pj_lit(w, CFBooleanGetValue((CFBooleanRef)v) ? "{\"t\":\"bool\",\"v\":true}" : "{\"t\":\"bool\",\"v\":false}");
        return;
    }
    if (t == CFDataGetTypeID()) {
        CFDataRef d = (CFDataRef)v;
        CFIndex n = CFDataGetLength(d);
        pj_fmt(w, "{\"t\":\"data\",\"len\":%ld,\"hex\":", (long)n);
        pj_hex(w, CFDataGetBytePtr(d), (size_t)n);
        pj_lit(w, "}");
        return;
    }
    if (t == CFArrayGetTypeID()) {
        CFArrayRef a = (CFArrayRef)v;
        CFIndex n = CFArrayGetCount(a);
        const void **items = pj_xmalloc(sizeof(void *) * (size_t)n);
        CFArrayGetValues(a, CFRangeMake(0, n), items);
        pj_lit(w, "{\"t\":\"array\",\"v\":[");
        pj_members(w, items, n, depth);
        pj_lit(w, "]}");
        free(items);
        return;
    }
    if (t == CFSetGetTypeID()) {
        CFSetRef s = (CFSetRef)v;
        CFIndex n = CFSetGetCount(s);
        const void **items = pj_xmalloc(sizeof(void *) * (size_t)n);
        CFSetGetValues(s, items);
        pj_lit(w, "{\"t\":\"set\",\"v\":[");
        pj_members(w, items, n, depth);
        pj_lit(w, "]}");
        free(items);
        return;
    }
    if (t == CFDictionaryGetTypeID()) {
        CFDictionaryRef d = (CFDictionaryRef)v;
        CFIndex n = CFDictionaryGetCount(d);
        const void **ks = pj_xmalloc(sizeof(void *) * (size_t)n);
        const void **vs = pj_xmalloc(sizeof(void *) * (size_t)n);
        CFDictionaryGetKeysAndValues(d, ks, vs);
        pj_pair *p = pj_xmalloc(sizeof(pj_pair) * (size_t)n);
        for (CFIndex i = 0; i < n; i++) {
            p[i].k = ks[i];
            p[i].v = vs[i];
        }
        qsort(p, (size_t)n, sizeof(pj_pair), pj_pair_cmp);
        pj_lit(w, "{\"t\":\"dict\",\"v\":[");
        for (CFIndex i = 0; i < n; i++) {
            int is_str = CFGetTypeID(p[i].k) == CFStringGetTypeID();
            if (i) pj_raw(w, ",", 1);
            if (is_str && w->withhold && w->withhold(w->withhold_ctx, NULL, p[i].k)) {
                /* The key itself carries a withheld identifier: neither half is written. */
                w->withheld++;
                pj_lit(w, "[{\"t\":\"withheld\"},{\"t\":\"withheld\"}]");
                continue;
            }
            pj_raw(w, "[", 1);
            if (is_str) pj_cfstring(w, (CFStringRef)p[i].k);
            else pj_value(w, p[i].k, NULL, depth + 1);
            pj_raw(w, ",", 1);
            pj_value(w, p[i].v, is_str ? (CFStringRef)p[i].k : NULL, depth + 1);
            pj_raw(w, "]", 1);
        }
        pj_lit(w, "]}");
        free(p);
        free(vs);
        free(ks);
        return;
    }
    if (t == CFNullGetTypeID()) {
        pj_lit(w, "{\"t\":\"null\"}");
        return;
    }
    if (t == CFDateGetTypeID()) {
        CFAbsoluteTime at = CFDateGetAbsoluteTime((CFDateRef)v);
        uint64_t b;
        memcpy(&b, &at, sizeof b);
        pj_fmt(w, "{\"t\":\"date\",\"bits\":64,\"hex\":\"%016llx\"}", (unsigned long long)b);
        return;
    }
    /* A CF type format 1 has no encoding for: record that it was there. */
    w->failures++;
    pj_fmt(w, "{\"t\":\"other\",\"cf_type_id\":%lu,\"cf_type\":", (unsigned long)t);
    CFStringRef desc = CFCopyTypeIDDescription(t);
    if (desc) {
        pj_cfstring(w, desc);
        CFRelease(desc);
    } else {
        pj_lit(w, "null");
    }
    pj_lit(w, "}");
}

PJ_FN void pj_now(char out[32]) {
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, 32, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

/* Opens a record ({"record":"<type>"). The record is built in memory and
   pj_record_end writes it only if it fits under the byte cap, so one large
   value can never carry the output past it. Returns 0 and writes nothing once
   the cap has refused a record; the caller then skips the record's fields. */
PJ_FN int pj_record_begin(pj_writer *w, const char *type) {
    if (w->capped) return 0;
    w->rec_buf = NULL;
    w->rec_len = 0;
    w->rec = open_memstream(&w->rec_buf, &w->rec_len);
    if (!w->rec) {
        fputs("probe_json: out of memory\n", stderr);
        abort();
    }
    pj_lit(w, "{\"record\":\"");
    pj_lit(w, type);
    pj_lit(w, "\"");
    return 1;
}

/* Writes the record, or drops it and stops the run when it would pass the cap:
   after that only the footer is written, with reason "byte_cap". */
PJ_FN void pj_record_end(pj_writer *w) {
    pj_lit(w, "}\n");
    fclose(w->rec);
    w->rec = NULL;
    if (w->cap && w->bytes + w->rec_len > w->cap) {
        w->capped = 1;
    } else {
        pj_raw(w, w->rec_buf, w->rec_len);
        w->records++;
    }
    free(w->rec_buf);
    w->rec_buf = NULL;
}

/* The first line of every probe's output. app_version comes from the
   WHATCABLE_APP_VERSION environment variable the runner sets; null without it. */
PJ_FN void pj_header(pj_writer *w, const char *probe) {
    char ts[32];
    pj_now(ts);
    const char *app = getenv("WHATCABLE_APP_VERSION");
    pj_fmt(w, "{\"record\":\"header\",\"format\":%d", PJ_FORMAT_VERSION);
    pj_field(w, "probe");
    pj_text(w, probe);
    pj_field(w, "probe_source_sha256");
    pj_text(w, PROBE_SOURCE_SHA256);
    pj_field(w, "app_version");
    if (app && *app) pj_text(w, app);
    else pj_lit(w, "null");
    pj_field(w, "started_at");
    pj_text(w, ts);
    pj_lit(w, "}\n");
}

/* The last line. reason is NULL for a complete run, otherwise why it stopped
   ("byte_cap" when the cap refused a record). step is the identifier lookup
   that failed when reason is "identifiers_incomplete" (pj_privacy_begin), a
   fixed name from the list in FORMAT.md, and NULL otherwise: it is the only
   word the file has on why such a run stopped (Opus x2 review of PR 693). A
   file without this line was cut off and is incomplete. */
PJ_FN void pj_footer_with_step(pj_writer *w, const char *reason, const char *step) {
    char ts[32];
    pj_now(ts);
    unsigned long long before = w->bytes;
    pj_lit(w, "{\"record\":\"footer\",\"status\":");
    pj_text(w, reason ? "stopped" : "complete");
    pj_field(w, "reason");
    if (reason) pj_text(w, reason);
    else pj_lit(w, "null");
    pj_field(w, "step");
    if (step) pj_text(w, step);
    else pj_lit(w, "null");
    pj_field(w, "records");
    pj_fmt(w, "%llu", w->records);
    pj_field(w, "failures");
    pj_fmt(w, "%llu", w->failures);
    pj_field(w, "withheld");
    pj_fmt(w, "%llu", w->withheld);
    pj_field(w, "bytes_before_footer");
    pj_fmt(w, "%llu", before);
    pj_field(w, "finished_at");
    pj_text(w, ts);
    pj_lit(w, "}\n");
    fflush(w->out);
}

/* The footer of every run but one stopped while gathering identifiers. */
PJ_FN void pj_footer(pj_writer *w, const char *reason) { pj_footer_with_step(w, reason, NULL); }

/* The registry entry ID of e, the key every small probe's record joins to the
   snapshot on. Returns 1 with *id set. On failure returns 0 with *id 0 after
   writing {"record":"failure","what":"entry_id","class":...,"kr":...} and
   counting it, so the caller writes no record for e: no record ever carries a
   null or 0x0 ID (Codex review of PR 693). Call it with no record open, since
   records do not nest. */
PJ_FN int pj_entry_id(pj_writer *w, io_registry_entry_t e, uint64_t *id) {
    *id = 0;
    kern_return_t kr = IORegistryEntryGetRegistryEntryID(e, id);
    if (kr == KERN_SUCCESS) return 1;
    *id = 0;
    w->failures++;
    if (!pj_record_begin(w, "failure")) return 0;
    pj_field(w, "what");
    pj_text(w, "entry_id");
    pj_field(w, "class");
    CFStringRef cls = IOObjectCopyClass(e);
    if (cls) {
        pj_cfstring(w, cls);
        CFRelease(cls);
    } else {
        pj_lit(w, "null");
    }
    pj_field(w, "kr");
    pj_fmt(w, "\"0x%08x\"", (unsigned)kr);
    pj_record_end(w);
    return 0;
}

/* Whether to walk id's children on reaching it at depth, in a walk that stays
   under a depth limit: yes when it has never been walked, or only from deeper.
   A registry entry can have two parents in a plane, and the first path to it
   can hit the limit while a shallower one would not (Codex review of PR 693),
   so the shallowest depth walked from is kept, in shallowest (CFNumber id ->
   depth), and updated here. Reaching an entry again at the same depth or
   deeper is a second parent or a cycle: no. */
PJ_FN int pj_walk_first(CFMutableDictionaryRef shallowest, uint64_t id, int depth) {
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    CFNumberRef old = CFDictionaryGetValue(shallowest, key);
    int before = 0, first = 1;
    if (old) {
        CFNumberGetValue(old, kCFNumberIntType, &before);
        first = depth < before;
    }
    if (first) {
        CFNumberRef now = CFNumberCreate(NULL, kCFNumberIntType, &depth);
        CFDictionarySetValue(shallowest, key, now);
        CFRelease(now);
    }
    CFRelease(key);
    return first;
}

/* ---- privacy -------------------------------------------------------------
 * Spec "Privacy": only personal privacy is protected. Withheld: what ties this
 * Mac to its owner (serial numbers, platform UUID, chip ID, its own network and
 * Bluetooth addresses) and the home folder path, by key name (pj_key_withheld)
 * and by content; the user's name by key name only (IOConsoleUsers). By
 * content means a string or integer holding one of them is withheld whole, and
 * data keeps every byte except the identifier's own. Everything else is kept,
 * including every identifier that links information across the registry.
 *
 * Each probe starts with pj_privacy_begin: it reads the identifiers once
 * (pj_ids_gather, which fails closed), attaches them to its writer
 * (pj_privacy_attach) and writes the header. Every identifier is searched for in every
 * form generated from its value, not in a list of forms someone thought of:
 * a hand-made list missed the chip ID twice (big-endian in the boot manifest
 * and in SMC key RECI, PR 693 review). scripts/probe-tests/snapshot_checks.py
 * generates the same forms independently, from values it reads its own way.
 */

typedef struct {
    CFMutableArrayRef forms; /* CFData: found anywhere inside a string, data or integer value */
    CFMutableArrayRef texts; /* the same, for text forms until pj_ids_finish merges them into forms */
    CFMutableArrayRef exact; /* CFData: found only as a whole data value */
    /* Set by pj_ids_finish: one bit per hash of a form's first 4 bytes, so a
       value is scanned once and almost every position is ruled out by one
       lookup, however many forms there are (searching for each of the mini's
       thousand forms in turn took the snapshot from under 1 s to over 3 s). */
    unsigned char *heads;
    /* The first gathering step that failed (pj_ids_gather), or NULL. */
    const char *incomplete;
    /* Bluetooth controllers seen by the last IOService walk, and the Mac's
       own Bluetooth addresses gathered from every source (pj_ids_gather). */
    int bt_controllers, bt_addresses;
    /* IOService walks the last pj_ids_gather made (1 unless one had to be
       made again). */
    int walks;
    /* The read the last walk failed with no sign of churn (pj_read_churn),
       or NULL: named when the attempts run out, because a read that keeps
       failing with the registry still is a fault on that Mac, not churn. */
    const char *read_failed;
} pj_ids;

/* Fault injection, for scripts/probe-tests/probe_json_test.c only: built with
   PJ_FAULT_INJECTION, pj_fault(step) is 1 for the next pj_fault_times calls
   naming a step in pj_fault_step (one name, or several separated by spaces),
   so a test can make one lookup in pj_ids_gather fail, once or every time.
   A property read that is faulted fails, unless pj_fault_value is set: then
   it returns that dictionary instead, so a test can show the code a shape the
   registry never publishes (a key of the wrong type, an 8-byte address, no
   keys at all). A probe build has no such code: pj_fault is 0. */
#ifdef PJ_FAULT_INJECTION
static const char *pj_fault_step = NULL;
static int pj_fault_times = 0;
static CFDictionaryRef pj_fault_value = NULL;
/* The kern_return a faulted read reports: the identifier walk tells churn
   from a failure by it (MACH_SEND_INVALID_DEST is churn). */
static kern_return_t pj_fault_kr = kIOReturnError;
/* A test's hook, called with the entry before every property read (NULL:
   none), so a test can change the real registry at the moment the walk is
   about to read an entry, as another process closing its connection does. */
static void (*pj_before_read)(io_registry_entry_t e) = NULL;
PJ_FN int pj_fault(const char *step) {
    if (!pj_fault_step || pj_fault_times <= 0) return 0;
    size_t n = strlen(step);
    const char *at = pj_fault_step;
    for (;;) {
        const char *hit = strstr(at, step);
        if (!hit) return 0;
        int whole = (hit == pj_fault_step || hit[-1] == ' ') && (hit[n] == '\0' || hit[n] == ' ');
        if (whole) break;
        at = hit + 1;
    }
    pj_fault_times--;
    return 1;
}
#else
#define pj_fault(step) 0
#define pj_fault_kr kIOReturnError
#endif

/* Every property of e: 1 with *out set, 0 after a failed read (*out NULL,
   *kr the read's kern_return). IORegistryEntryCreateCFProperties has a
   kern_return_t, so a failed read and an entry with no properties are told
   apart; IORegistryEntryCreateCFProperty returns NULL for absent and failed
   alike. step names the read to the fault seam above. */
PJ_FN int pj_read_props_kr(io_registry_entry_t e, const char *step, CFDictionaryRef *out, kern_return_t *kr) {
    CFMutableDictionaryRef props = NULL;
    *out = NULL;
    *kr = KERN_SUCCESS;
#ifdef PJ_FAULT_INJECTION
    if (pj_before_read) pj_before_read(e);
    if (pj_fault(step)) {
        if (!pj_fault_value) {
            *kr = pj_fault_kr;
            return 0;
        }
        *out = (CFDictionaryRef)CFRetain(pj_fault_value);
        return 1;
    }
#else
    (void)step;
#endif
    *kr = IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0);
    if (*kr != KERN_SUCCESS || !props) {
        if (props) CFRelease(props);
        return 0;
    }
    *out = props;
    return 1;
}

/* The same for a caller that does not need the kern_return. */
PJ_FN int pj_read_props(io_registry_entry_t e, const char *step, CFDictionaryRef *out) {
    kern_return_t kr;
    return pj_read_props_kr(e, step, out, &kr);
}

/* 1 when a read of e that failed with kr shows a sign that the registry
   changed, so the failure is churn and not a fault of the read. Measured on
   the mini (Opus x3 review of PR 693, 2026-10-08): a user client closed
   between IOIteratorNext and the read fails the read, its name and its child
   iterator with MACH_SEND_INVALID_DEST (closing destroys its object ports in
   every task) and IORegistryEntryInPlane answers 0, while a live sibling
   answers 1 and the walk's iterator still says valid at 0, 1 and 50 ms. The
   iterator turns invalid only once the walk moves on past the detach, so it
   cannot tell churn from a failure at the moment the read fails; these two
   signs can. Asked with the entry's handle still held, because afterwards
   there is nothing to ask. */
PJ_FN int pj_read_churn(io_registry_entry_t e, kern_return_t kr) {
    if (kr == MACH_SEND_INVALID_DEST) return 1;
    return pj_fault("entry_gone") || !IORegistryEntryInPlane(e, kIOServicePlane);
}

/* ---- the USB class guard (51 and 52) ---------------------------------------
 * A USB service carrying a mass-storage (0x08) or HID (0x03) class is never
 * opened or asked for a descriptor: the macOS removable-volume prompt, or
 * seizing a keyboard or mouse. The guard fails closed (Codex, PR 693 extra
 * pass 2): it answers 1 (found), 0 (confirmed neither) or -1 (unknown), and
 * unknown means the caller leaves the device alone and records why. */

/* The USB class number under key in props: 1 found (in *cls), 0 absent, -1
   there in a shape that is not a number. */
PJ_FN int pj_usb_class_in(CFDictionaryRef props, const char *key, long *cls) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(props, k);
    CFRelease(k);
    if (!v) return 0;
    if (CFGetTypeID(v) != CFNumberGetTypeID() || !CFNumberGetValue(v, kCFNumberLongType, cls)) return -1;
    return 1;
}

/* 1 when the class under key is mass storage, or HID when hid_too; 0 when it
   is another class or absent; -1 when it is there in another shape. */
PJ_FN int pj_usb_class_wanted(CFDictionaryRef props, const char *key, int hid_too) {
    long cls = 0;
    int r = pj_usb_class_in(props, key, &cls);
    if (r != 1) return r;
    return cls == 0x08 || (hid_too && cls == 0x03);
}

/* Whether s, or one of its direct children in the service plane, carries a
   mass-storage class, or a HID class when hid_too (probe 29's guard): 1 yes,
   0 confirmed no, -1 unknown. Unknown is any read that did not complete: the
   service's or a child's properties, the child iterator, or the registry
   changing under it (an iterator over no children stays valid, measured on
   the mini). An absent class key in a dictionary that was read is not that
   class: the USB4 and Thunderbolt hub classes publish none. */
PJ_FN int pj_usb_class_guard(io_service_t s, int hid_too) {
    CFDictionaryRef props = NULL;
    if (!pj_read_props(s, "usb_class_props", &props)) return -1;
    int dev = pj_usb_class_wanted(props, "bDeviceClass", hid_too);
    int iface = pj_usb_class_wanted(props, "bInterfaceClass", hid_too);
    CFRelease(props);
    if (dev < 0 || iface < 0) return -1;
    if (dev || iface) return 1;
    io_iterator_t it = 0;
    if (pj_fault("usb_class_children") || IORegistryEntryGetChildIterator(s, kIOServicePlane, &it) != KERN_SUCCESS) return -1;
    int found = 0;
    io_service_t child;
    while (found == 0 && (child = IOIteratorNext(it))) {
        CFDictionaryRef cp = NULL;
        if (!pj_read_props(child, "usb_class_child_props", &cp)) {
            found = -1;
        } else {
            found = pj_usb_class_wanted(cp, "bInterfaceClass", hid_too);
            CFRelease(cp);
        }
        IOObjectRelease(child);
    }
    if (found == 0 && (pj_fault("usb_class_iterator") || !IOIteratorIsValid(it))) found = -1;
    IOObjectRelease(it);
    return found;
}

#define PJ_HEAD_BITS 20

/* Withheld wherever they appear, at any depth (spec "Privacy", Q12, Q17 and the
   rulings after Inspect). die-id is not here: on CPU cluster nodes it is a die
   number, and the one on IODeviceTree:/chosen that carries the chip ID is caught
   by content. */
static const char *const kPjWithheldKeys[] = {
    "IOConsoleUsers", "IOUserClientCreator", "DiskImageURL",
    "IOPlatformSerialNumber", "IOPlatformUUID", "mlb-serial-number",
    "ECID", "unique-chip-id", "unique-device-id",
    "local-mac-address", "device-mac-address", "host-mac-address",
    "ncm-control-ecid-mac",
    NULL,
};
static const char *const kPjWithheldKeyPrefixes[] = {"mac-address", NULL};

PJ_FN int pj_key_withheld(CFStringRef key) {
    char k[256];
    if (!CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8)) return 0;
    for (int i = 0; kPjWithheldKeys[i]; i++)
        if (strcmp(k, kPjWithheldKeys[i]) == 0) return 1;
    for (int i = 0; kPjWithheldKeyPrefixes[i]; i++)
        if (strncmp(k, kPjWithheldKeyPrefixes[i], strlen(kPjWithheldKeyPrefixes[i])) == 0) return 1;
    return 0;
}

PJ_FN void pj_ids_init(pj_ids *ids) {
    ids->forms = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    ids->texts = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    ids->exact = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    ids->heads = NULL;
    ids->incomplete = NULL;
    ids->bt_controllers = 0;
    ids->bt_addresses = 0;
    ids->walks = 0;
    ids->read_failed = NULL;
}

PJ_FN uint32_t pj_head(const unsigned char *b) {
    uint32_t v;
    memcpy(&v, b, 4);
    return (v * 2654435761u) >> (32 - PJ_HEAD_BITS);
}

/* A pattern mostly made of one byte value identifies nothing and matches
   countless unrelated values: a null UUID's 16 zero bytes (measured on the
   mini) or a near-empty network address with five zero bytes (the MacBook's
   Thunderbolt Bridge, 2026-10-07), which matches every small integer. Exactly
   half is not weak: every UTF-16 form of ASCII text is half zero bytes. */
PJ_FN int pj_weak(const unsigned char *b, size_t n) {
    size_t counts[256] = {0}, most = 0;
    for (size_t i = 0; i < n; i++)
        if (++counts[b[i]] > most) most = counts[b[i]];
    return most * 2 > n;
}

PJ_FN void pj_ids_append(CFMutableArrayRef list, const void *b, size_t n) {
    CFDataRef d = CFDataCreate(NULL, b, (CFIndex)n);
    if (!CFArrayContainsValue(list, CFRangeMake(0, CFArrayGetCount(list)), d)) CFArrayAppendValue(list, d);
    CFRelease(d);
}

/* One form, kept only when it is at least 4 bytes (shorter ones match without
   meaning anything) and not weak. */
PJ_FN void pj_ids_add_form(pj_ids *ids, const void *b, size_t n) {
    if (n >= 4 && !pj_weak(b, n)) pj_ids_append(ids->forms, b, n);
}

/* The same for a text form (hex, decimal, a serial, in any encoding). */
PJ_FN void pj_ids_add_text_form(pj_ids *ids, const void *b, size_t n) {
    if (n >= 4 && !pj_weak(b, n)) pj_ids_append(ids->texts, b, n);
}

/* UTF-8 text as itself, UTF-16LE and UTF-16BE: Intel firmware publishes the
   serial as UTF-16LE. Text too short or too uniform to search for gives none. */
PJ_FN void pj_ids_add_encodings(pj_ids *ids, const char *utf8, size_t n) {
    if (n < 4 || pj_weak((const unsigned char *)utf8, n)) return;
    pj_ids_add_text_form(ids, utf8, n);
    CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)utf8, (CFIndex)n, kCFStringEncodingUTF8, false);
    if (!s) return;
    CFIndex len = CFStringGetLength(s);
    UniChar *u = pj_xmalloc(sizeof(UniChar) * (size_t)len);
    CFStringGetCharacters(s, CFRangeMake(0, len), u);
    unsigned char *le = pj_xmalloc((size_t)len * 2), *be = pj_xmalloc((size_t)len * 2);
    for (CFIndex i = 0; i < len; i++) {
        le[2 * i] = be[2 * i + 1] = (unsigned char)(u[i] & 0xFF);
        le[2 * i + 1] = be[2 * i] = (unsigned char)(u[i] >> 8);
    }
    pj_ids_add_text_form(ids, le, (size_t)len * 2);
    pj_ids_add_text_form(ids, be, (size_t)len * 2);
    free(be);
    free(le);
    free(u);
    CFRelease(s);
}

/* A text identifier (a serial, the home folder) as published and, with
   cases, in upper and lower case, each in every encoding. */
PJ_FN void pj_ids_add_text(pj_ids *ids, const char *utf8, size_t n, int cases) {
    pj_ids_add_encodings(ids, utf8, n);
    CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)utf8, (CFIndex)n, kCFStringEncodingUTF8, false);
    if (!s || !cases) {
        if (s) CFRelease(s);
        return;
    }
    for (int upper = 0; upper < 2; upper++) {
        CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, s);
        if (upper) CFStringUppercase(m, NULL);
        else CFStringLowercase(m, NULL);
        size_t len = 0;
        unsigned char *b = pj_cf_utf8(m, &len);
        if (b) pj_ids_add_encodings(ids, (const char *)b, len);
        free(b);
        CFRelease(m);
    }
    CFRelease(s);
}

/* b[0..n) as hex text in both cases, bare and with ':' or '-' between bytes,
   and bare without leading zero digits (how a number is printed). */
PJ_FN void pj_ids_add_hex_texts(pj_ids *ids, const unsigned char *b, size_t n) {
    static const char *const digits[] = {"0123456789abcdef", "0123456789ABCDEF"};
    static const char seps[] = {0, ':', '-'};
    char *t = pj_xmalloc(3 * n + 1);
    for (int c = 0; c < 2; c++) {
        for (size_t s = 0; s < sizeof seps; s++) {
            size_t len = 0;
            for (size_t i = 0; i < n; i++) {
                if (i && seps[s]) t[len++] = seps[s];
                t[len++] = digits[c][b[i] >> 4];
                t[len++] = digits[c][b[i] & 15];
            }
            pj_ids_add_encodings(ids, t, len);
            if (!seps[s]) {
                size_t lead = 0;
                while (lead < len && t[lead] == '0') lead++;
                pj_ids_add_encodings(ids, t + lead, len - lead);
            }
        }
    }
    free(t);
}

/* Every form of a binary identifier: its bytes and their reverse, each with
   leading and with trailing zero bytes stripped (the chip ID as a DER INTEGER
   is big-endian without its leading zero); each of those as hex text; up to 8
   bytes, the value in decimal read either way round; and every text form in
   UTF-8, UTF-16LE and UTF-16BE. An identifier with under 4 bytes once zeros
   are stripped gives no text: "12ab" or "4779" would match countless
   unrelated values. */
PJ_FN void pj_ids_add_binary(pj_ids *ids, const unsigned char *raw, size_t n) {
    size_t first = 0, last = n; /* the significant bytes, zeros at either end stripped */
    while (first < last && raw[first] == 0) first++;
    while (last > first && raw[last - 1] == 0) last--;
    unsigned char *b = pj_xmalloc(n ? n : 1);
    for (int rev = 0; rev < 2; rev++) {
        for (size_t i = 0; i < n; i++) b[i] = rev ? raw[n - 1 - i] : raw[i];
        for (int strip = 0; strip < 4; strip++) {
            size_t lo = 0, hi = n;
            if (strip & 1)
                while (lo < hi && b[lo] == 0) lo++;
            if (strip & 2)
                while (hi > lo && b[hi - 1] == 0) hi--;
            if (hi == lo) continue;
            pj_ids_add_form(ids, b + lo, hi - lo);
            if (last - first >= 4) pj_ids_add_hex_texts(ids, b + lo, hi - lo);
        }
    }
    free(b);
    if (n <= 8 && last - first >= 4) {
        unsigned long long be = 0, le = 0;
        for (size_t i = 0; i < n; i++) {
            be = (be << 8) | raw[i];
            le |= (unsigned long long)raw[i] << (8 * i);
        }
        char t[24];
        pj_ids_add_encodings(ids, t, (size_t)snprintf(t, sizeof t, "%llu", be));
        pj_ids_add_encodings(ids, t, (size_t)snprintf(t, sizeof t, "%llu", le));
    }
}

/* A network or Bluetooth address, in every binary form, and as a whole 6-byte
   data value either way round, so a value that is exactly one is withheld
   whole (PR 693 rerun: three of the mini's own addresses share 5 bytes). One
   mostly made of one byte value is matched only that way (Codex review of PR
   693): its forms are too uniform to search for inside longer values. */
PJ_FN void pj_ids_add_address(pj_ids *ids, const unsigned char m[6]) {
    pj_ids_add_binary(ids, m, 6);
    int same = 1;
    for (int i = 1; i < 6; i++) same &= m[i] == m[0];
    if (same) return; /* all one value (none, or broadcast) is no one's */
    const unsigned char rev[6] = {m[5], m[4], m[3], m[2], m[1], m[0]};
    pj_ids_append(ids->exact, m, 6);
    pj_ids_append(ids->exact, rev, 6);
}

/* A UUID as text (as published, upper, lower), as its 16 bytes in every binary
   form, and in the EFI and SMBIOS order (first three fields little-endian)
   that Intel Macs publish as /efi/platform system-id and in SMBIOS. */
PJ_FN void pj_ids_add_uuid(pj_ids *ids, CFStringRef s) {
    char text[64];
    if (!CFStringGetCString(s, text, sizeof text, kCFStringEncodingUTF8)) return;
    unsigned char raw[16];
    int digits = 0, nonzero = 0;
    for (const char *c = text; *c; c++) {
        if (*c == '-') continue;
        const char *hex = "0123456789abcdef", *at = strchr(hex, *c | 0x20);
        if (!*c || !at || digits >= 32) return; /* not a UUID */
        int v = (int)(at - hex);
        if (digits % 2 == 0) raw[digits / 2] = (unsigned char)(v << 4);
        else raw[digits / 2] |= (unsigned char)v;
        nonzero |= v;
        digits++;
    }
    if (digits != 32 || !nonzero) return; /* the null UUID identifies nothing */
    pj_ids_add_text(ids, text, strlen(text), 1);
    pj_ids_add_binary(ids, raw, sizeof raw);
    const unsigned char efi[16] = {raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6],
                                   raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]};
    pj_ids_add_form(ids, efi, sizeof efi);
}

PJ_FN CFTypeRef pj_copy_prop(io_registry_entry_t e, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    return v;
}

PJ_FN int pj_is_type(CFTypeRef v, CFTypeID t) { return v && CFGetTypeID(v) == t; }

/* ---- gathering the identifiers ---------------------------------------------
 * Fails closed (Codex, last review of PR 693): a lookup that fails, or a key
 * that is there in a shape the probe cannot read, is recorded in
 * ids->incomplete, and pj_privacy_begin then writes no records. A key that is
 * absent is not a failure: Intel Macs have no unique-chip-id. Properties are
 * read whole with IORegistryEntryCreateCFProperties, which says whether the
 * read failed; IORegistryEntryCreateCFProperty returns NULL either way.
 * Every shape below was measured: the corpus holds 447 IOMACAddress values,
 * all 6-byte data; on the mini the serial and UUID are strings, the device
 * tree serials and chip IDs data, the Bluetooth address 6-byte data. */

PJ_FN void pj_ids_fail(pj_ids *ids, const char *step) {
    if (!ids->incomplete) ids->incomplete = step;
}

/* Every property of e, or NULL after recording step as failed. */
PJ_FN CFDictionaryRef pj_ids_props(pj_ids *ids, io_registry_entry_t e, const char *step) {
    CFDictionaryRef props = NULL;
    if (pj_read_props(e, step, &props)) return props;
    pj_ids_fail(ids, step);
    return NULL;
}

/* The value under key in props when it is of type t: 0 absent, 1 found, -1
   there in another shape (recorded as step failed). */
PJ_FN int pj_ids_typed(pj_ids *ids, CFDictionaryRef props, const char *key, CFTypeID t, const char *step, CFTypeRef *out) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(props, k);
    CFRelease(k);
    *out = v;
    if (!v) return 0;
    if (CFGetTypeID(v) == t) return 1;
    pj_ids_fail(ids, step);
    return -1;
}

/* A device-tree data property: as a serial (text, its trailing NULs dropped)
   or as a binary identifier. */
PJ_FN void pj_ids_add_tree_data(pj_ids *ids, CFDictionaryRef props, const char *key, int text, const char *step) {
    CFTypeRef v = NULL;
    if (pj_ids_typed(ids, props, key, CFDataGetTypeID(), step, &v) != 1) return;
    const unsigned char *b = CFDataGetBytePtr(v);
    size_t n = (size_t)CFDataGetLength(v);
    if (text) {
        while (n && b[n - 1] == 0) n--;
        pj_ids_add_text(ids, (const char *)b, n, 1);
    } else {
        pj_ids_add_binary(ids, b, n);
    }
}

/* 1 marked built in, 0 marked not built in, -1 not marked, -2 a read failed
   with no sign of churn (the walk's step network_builtin), -3 churn: a read
   beneath failed with a sign of it (pj_read_churn), or the children changed
   under the check (its iterator no longer valid), whatever it found: a
   marker read from a changing set is stale (Codex x3 review of PR 693: a
   stale "not built in" would keep a Mac-owned address unwithheld). props is the entry's
   properties when the caller has read them already (the walk), else NULL
   and they are read here. Network interfaces publish IOBuiltin on the entry
   or up to two levels below the entry carrying IOMACAddress (measured on
   the mini, 2026-10-07; one level below for both of its factory-assigned
   interfaces, 2026-10-08). */
PJ_FN int pj_builtin_mark(io_registry_entry_t e, CFDictionaryRef props, int depth) {
    CFDictionaryRef own = NULL;
    kern_return_t kr;
    if (!props) {
        if (!pj_read_props_kr(e, "network_builtin", &own, &kr)) return pj_read_churn(e, kr) ? -3 : -2;
        props = own;
    }
    CFTypeRef v = CFDictionaryGetValue(props, CFSTR("IOBuiltin"));
    int mark = -1;
    if (pj_is_type(v, CFBooleanGetTypeID())) mark = CFBooleanGetValue(v) ? 1 : 0;
    if (own) CFRelease(own);
    if (mark >= 0 || depth == 0) return mark;
    io_iterator_t it = 0;
    kr = IORegistryEntryGetChildIterator(e, kIOServicePlane, &it);
    if (kr != KERN_SUCCESS) return pj_read_churn(e, kr) ? -3 : -2;
    io_registry_entry_t c;
    while (mark == -1 && (c = IOIteratorNext(it))) {
        mark = pj_builtin_mark(c, NULL, depth - 1);
        IOObjectRelease(c);
    }
    /* A child iterator over no children stays valid (the snapshot's walk
       checks every one: 0 failures on the mini), so invalid means changed.
       Asked here because the walk's own iterator covers the entries above
       this one, not its children. Measured on the mini (Opus x4 review of
       PR 693, macOS 26, 2026-10-08): this child iterator is a fixed copy of
       the set taken when it is created, and it stays valid after a sibling
       is removed (flatnext, 9 of 9 runs at 0, 20 and 50 ms) or added
       (flatsnap, 6 of 6), so on this kernel the check below is reached only
       through the seam. It is kept as a guard in case a kernel does
       invalidate it. A child added after the copy goes unseen: no marker is
       found there and its interface's address is withheld, the safe
       direction. */
    int valid = !pj_fault("network_builtin_changed") && IOIteratorIsValid(it);
    IOObjectRelease(it);
    return valid ? mark : -3;
}

/* A 6-byte data value under key in props, added as one of the Mac's own
   addresses: 1 added, 0 absent, -1 there in another shape. */
PJ_FN int pj_ids_add_address_key(pj_ids *ids, CFDictionaryRef props, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(props, k);
    CFRelease(k);
    if (!v) return 0;
    if (!pj_is_type(v, CFDataGetTypeID()) || CFDataGetLength(v) != 6) return -1;
    pj_ids_add_address(ids, CFDataGetBytePtr(v));
    return 1;
}

/* The Mac's own Bluetooth address, from the entries that publish it besides
   /chosen (Codex x1 #1: a Mac that publishes it elsewhere was never searched).
   Measured on the mini, 2026-10-08, by searching every plane for the
   controller's address: the device-tree node named bluetooth
   (local-mac-address; the node named fillmore publishes an 8-byte one, so the
   length rule is scoped to this node), the NVRAM blobs that content matching
   covers, the IOBluetoothDevice beneath the controller (BD_ADDR, BTAddress),
   and nothing on the controller entry itself. IOBluetoothDevice is not a
   source: it stands for connected devices too (2 to 10 instances in 106 of
   296 corpus class-discovery captures, rising with accessories), and their
   addresses are kept by the spec. The controller class is counted so the
   caller can tell a Mac without Bluetooth from one whose address could not
   be read: IOBluetoothHCIController is in 296 of 297 captures, Intel and
   Apple silicon alike. Intel Macs publish neither source here (no /chosen
   key, no ARM device tree), so they fail closed; the apps do not support
   Intel Macs. Returns 1; 0 when a present key has another shape (the walk's
   step bluetooth_node, final: a value read whole cannot be churn); -2 when
   the entry's name could not be read with no sign of churn (the same step,
   after the walk is made again); -3 when that read failed with one. */
PJ_FN int pj_ids_bluetooth_entry(pj_ids *ids, io_registry_entry_t e, CFDictionaryRef props) {
    if (IOObjectConformsTo(e, "IOBluetoothHCIController")) ids->bt_controllers++;
    if (CFDictionaryContainsKey(props, CFSTR("local-mac-address"))) {
        io_name_t name;
        kern_return_t kr = pj_fault("bluetooth_node") ? pj_fault_kr : IORegistryEntryGetName(e, name);
        if (kr != KERN_SUCCESS) return pj_read_churn(e, kr) ? -3 : -2;
        if (strcmp(name, "bluetooth") == 0) {
            int a = pj_ids_add_address_key(ids, props, "local-mac-address");
            if (a < 0) return 0;
            ids->bt_addresses += a;
        }
    }
    return 1;
}

/* One walk of the IOService plane for the Mac's own network addresses. Kept
   only when macOS marks the interface not built in AND the address is
   factory-assigned: a real adapter. A software-assigned address on an
   interface marked not built in is the Mac's own USB device-mode network
   (AppleUSBDeviceNCMData, en5 to en7 on the mini, 2026-10-07).
   Returns 1 settled (every read succeeded and the registry held still);
   -1 malformed (a value read whole has a shape the registry never
   publishes, which cannot be churn: ids->incomplete names the step and the
   caller stops at once); 0 walk again (the registry changed under the walk,
   or a read failed). A failed read is never final on one walk: it can be
   churn before any iterator says so (pj_read_churn, measured), and other
   such kernel behaviour is unmeasured. When it failed with no sign of
   churn, ids->read_failed names it for the caller to use once the attempts
   run out; a sign of churn, or the walk's iterator invalid afterwards,
   leaves it NULL. The iterator is asked at the end of every walk because a
   detach inside the child set the cursor is on ends the walk early with no
   read failing (measured on the mini, 2026-10-08: 55 of 2611 entries, 9 of
   9 runs), and that check is the only guard against a walk cut short. */
PJ_FN int pj_ids_walk_network(pj_ids *ids) {
    io_iterator_t it = 0;
    ids->read_failed = NULL;
    kern_return_t kr = pj_fault("network_iterator") ? pj_fault_kr
                                                    : IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it);
    if (kr != KERN_SUCCESS) {
        ids->read_failed = "network_iterator"; /* no entry and no iterator to ask: no sign either way */
        return 0;
    }
    io_registry_entry_t e;
    const char *failed = NULL;    /* a read that failed with no sign of churn */
    const char *malformed = NULL; /* a value read whole in a shape that stops the walk */
    int churn = 0;
    ids->bt_controllers = 0;
    while (!failed && !malformed && !churn && (e = IOIteratorNext(it))) {
        CFDictionaryRef props = NULL;
        if (!pj_read_props_kr(e, "network_props", &props, &kr)) {
            if (pj_read_churn(e, kr)) churn = 1;
            else failed = "network_props";
        } else {
            CFTypeRef mac = CFDictionaryGetValue(props, CFSTR("IOMACAddress"));
            if (mac) {
                if (!pj_is_type(mac, CFDataGetTypeID()) || CFDataGetLength(mac) != 6) {
                    malformed = "network_address";
                } else {
                    const unsigned char *m = CFDataGetBytePtr(mac);
                    int software_assigned = (m[0] & 0x02) != 0;
                    int mark = software_assigned ? -1 : pj_builtin_mark(e, props, 2);
                    if (mark == -2) failed = "network_builtin";
                    else if (mark == -3) churn = 1;
                    else if (software_assigned || mark != 0) pj_ids_add_address(ids, m);
                }
            }
            if (!failed && !malformed && !churn) {
                int bt = pj_ids_bluetooth_entry(ids, e, props);
                if (bt == 0) malformed = "bluetooth_node";
                else if (bt == -2) failed = "bluetooth_node";
                else if (bt == -3) churn = 1;
            }
        }
        if (props) CFRelease(props);
        IOObjectRelease(e);
    }
    /* Asked after a failure as well as after a full walk: invalid means the
       registry changed, whatever else happened. */
    if (pj_fault("network_changed") || !IOIteratorIsValid(it)) churn = 1;
    IOObjectRelease(it);
    if (malformed) {
        pj_ids_fail(ids, malformed);
        return -1;
    }
    if (!failed && !churn) return 1;
    if (failed && !churn) ids->read_failed = failed;
    return 0;
}

/* Microseconds to wait before walk attempt number attempt (0 first). Growing,
   so a burst of user clients opening and closing (about 580 a second failed
   most of 60 runs when the 4 attempts ran back to back, measured on the mini,
   2026-10-08) has time to pass. */
PJ_FN useconds_t pj_retry_pause(int attempt) {
    static const useconds_t pauses[] = {0, 10000, 50000, 200000};
    if (attempt < 0) return 0;
    if (attempt >= (int)(sizeof pauses / sizeof pauses[0])) return pauses[sizeof pauses / sizeof pauses[0] - 1];
    return pauses[attempt];
}

/* Reads this Mac's identifiers from the registry and the user database.
   Returns 1 when every lookup succeeded, else 0 with ids->incomplete naming
   the first step that failed (a fixed name from the list in FORMAT.md,
   never anything read from the Mac); the probe then writes no records and
   its footer names the step (pj_privacy_begin). The IOService walk is made
   again, a few times with growing pauses, when the registry changed under it
   or a read in it failed; a malformed value stops it at once. Once the
   attempts run out the step is the read that failed on the last walk with
   no sign of churn, else registry_changing. */
PJ_FN int pj_ids_gather(pj_ids *ids) {
    pj_ids_init(ids);
    io_service_t pe = pj_fault("platform_expert") ? MACH_PORT_NULL
                                                  : IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!pe) pj_ids_fail(ids, "platform_expert");
    CFDictionaryRef props = pe ? pj_ids_props(ids, pe, "platform_props") : NULL;
    if (props) {
        /* Mandatory on every Mac (Codex x1 #1): absent is a failure here,
           unlike the device-tree keys below, which Intel Macs lack. */
        CFTypeRef serial = NULL, uuid = NULL;
        int have = pj_ids_typed(ids, props, "IOPlatformSerialNumber", CFStringGetTypeID(), "platform_serial", &serial);
        if (have == 1) {
            size_t n = 0;
            unsigned char *b = pj_cf_utf8(serial, &n);
            if (b) pj_ids_add_text(ids, (const char *)b, n, 1);
            else pj_ids_fail(ids, "platform_serial");
            free(b);
        } else if (have == 0) {
            pj_ids_fail(ids, "platform_serial");
        }
        have = pj_ids_typed(ids, props, "IOPlatformUUID", CFStringGetTypeID(), "platform_uuid", &uuid);
        if (have == 1) pj_ids_add_uuid(ids, uuid);
        else if (have == 0) pj_ids_fail(ids, "platform_uuid");
        CFRelease(props);
    }
    if (pe) IOObjectRelease(pe);

    io_registry_entry_t dt = pj_fault("device_tree") ? MACH_PORT_NULL : IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/");
    if (!dt) pj_ids_fail(ids, "device_tree");
    props = dt ? pj_ids_props(ids, dt, "device_tree_props") : NULL;
    if (props) {
        pj_ids_add_tree_data(ids, props, "serial-number", 1, "device_tree_props");
        pj_ids_add_tree_data(ids, props, "mlb-serial-number", 1, "device_tree_props");
        CFRelease(props);
    }
    if (dt) IOObjectRelease(dt);

    io_registry_entry_t chosen = pj_fault("chosen") ? MACH_PORT_NULL : IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (!chosen) pj_ids_fail(ids, "chosen");
    props = chosen ? pj_ids_props(ids, chosen, "chosen_props") : NULL;
    if (props) {
        pj_ids_add_tree_data(ids, props, "unique-chip-id", 0, "chosen_props");
        pj_ids_add_tree_data(ids, props, "unique-device-id", 0, "chosen_props");
        pj_ids_add_tree_data(ids, props, "die-id", 0, "chosen_props");
        /* The Mac's own Bluetooth address, one source of several (the others
           are read in the IOService walk, pj_ids_bluetooth_entry). Absent on
           Intel Macs. Paired devices' addresses are not the Mac's and are kept. */
        CFTypeRef bt = NULL;
        if (pj_ids_typed(ids, props, "mac-address-bluetooth0", CFDataGetTypeID(), "chosen_props", &bt) == 1) {
            if (CFDataGetLength(bt) == 6) {
                pj_ids_add_address(ids, CFDataGetBytePtr(bt));
                ids->bt_addresses++;
            } else {
                pj_ids_fail(ids, "chosen_props");
            }
        }
        CFRelease(props);
    }
    if (chosen) IOObjectRelease(chosen);

    /* The Mac's own network addresses, in one pass over IOService. Volume and
       drive UUIDs are not personal and are kept (Darryl, 2026-10-07). An
       address added by a walk that was then invalidated stays: adding is
       deduplicated, and nothing found is wrong. */
    int walk = 0; /* 0: walk again */
    for (int attempt = 0; attempt < 4 && walk == 0; attempt++) {
        if (attempt) usleep(pj_retry_pause(attempt));
        ids->walks++;
        walk = pj_ids_walk_network(ids);
    }
    if (walk == 0) pj_ids_fail(ids, ids->read_failed ? ids->read_failed : "registry_changing");
    /* A Mac with a Bluetooth controller publishes its address somewhere; one
       that gave none from any source cannot be withheld, so fail closed. A Mac
       without a controller has nothing to withhold. */
    if (walk == 1 && ids->bt_controllers > 0 && ids->bt_addresses == 0) pj_ids_fail(ids, "bluetooth");

    struct passwd *pw = pj_fault("passwd") ? NULL : getpwuid(getuid());
    if (pw && pw->pw_dir) pj_ids_add_text(ids, pw->pw_dir, strlen(pw->pw_dir), 0);
    else pj_ids_fail(ids, "passwd");
    return ids->incomplete == NULL;
}

typedef struct {
    CFDataRef d;
    int text;
} pj_form;

PJ_FN int pj_form_shorter(const void *a, const void *b) {
    CFIndex la = CFDataGetLength(((const pj_form *)a)->d), lb = CFDataGetLength(((const pj_form *)b)->d);
    return la < lb ? -1 : (la > lb ? 1 : 0);
}

/* 1 when s occurs in l with nothing else in l but bytes a dropped form may
   leave unmasked: zero bytes, and in a text form the '0' character too. */
PJ_FN int pj_only_padding_besides(const pj_form *l, CFDataRef s) {
    const unsigned char *lb = CFDataGetBytePtr(l->d), *sb = CFDataGetBytePtr(s);
    size_t ln = (size_t)CFDataGetLength(l->d), sn = (size_t)CFDataGetLength(s);
    for (const unsigned char *at = memmem(lb, ln, sb, sn); at; at = memmem(at + 1, ln - (size_t)(at + 1 - lb), sb, sn)) {
        size_t off = (size_t)(at - lb);
        int padding = 1;
        for (size_t i = 0; i < ln && padding; i++)
            if (i < off || i >= off + sn) padding = lb[i] == 0 || (l->text && lb[i] == '0');
        if (padding) return 1;
    }
    return 0;
}

/* Readies ids for searching, once every identifier is added. A form that holds
   a shorter form is dropped when everything else in it is padding the shorter
   one leaves out (zero bytes; in text, '0' digits too), so masking the shorter
   one leaves nothing of an identifier visible. Any other byte keeps the longer
   form: three of the mini's own addresses share 5 bytes, and dropping on
   containment alone left their sixth byte in clear (PR 693 rerun). Dropping
   forms with leading zero bytes also keeps them from matching at almost every
   position of zero-filled data. */
PJ_FN void pj_ids_finish(pj_ids *ids) {
    if (ids->heads) return;
    CFIndex nb = CFArrayGetCount(ids->forms), nt = CFArrayGetCount(ids->texts);
    pj_form *all = pj_xmalloc(sizeof(pj_form) * (size_t)(nb + nt + 1));
    size_t n = 0;
    for (CFIndex i = 0; i < nb; i++) all[n++] = (pj_form){CFArrayGetValueAtIndex(ids->forms, i), 0};
    for (CFIndex i = 0; i < nt; i++) {
        CFDataRef d = CFArrayGetValueAtIndex(ids->texts, i);
        /* Bytes that are a binary form too keep the binary rule, the stricter. */
        if (!CFArrayContainsValue(ids->forms, CFRangeMake(0, nb), d)) all[n++] = (pj_form){d, 1};
    }
    qsort(all, n, sizeof *all, pj_form_shorter);
    CFMutableArrayRef kept = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    ids->heads = pj_xmalloc(1u << (PJ_HEAD_BITS - 3));
    memset(ids->heads, 0, 1u << (PJ_HEAD_BITS - 3));
    for (size_t i = 0; i < n; i++) {
        int redundant = 0;
        for (CFIndex k = 0; k < CFArrayGetCount(kept) && !redundant; k++)
            redundant = pj_only_padding_besides(&all[i], CFArrayGetValueAtIndex(kept, k));
        if (redundant) continue;
        CFArrayAppendValue(kept, all[i].d);
        uint32_t h = pj_head(CFDataGetBytePtr(all[i].d));
        ids->heads[h >> 3] |= (unsigned char)(1u << (h & 7));
    }
    free(all);
    CFRelease(ids->forms);
    ids->forms = kept;
    CFArrayRemoveAllValues(ids->texts);
}

/* Finds every form in b[0..n). With mask NULL, returns 1 at the first one;
   otherwise marks the bytes of each in mask and returns whether any was found. */
PJ_FN int pj_ids_scan(const pj_ids *ids, const unsigned char *b, size_t n, unsigned char *mask) {
    int found = 0;
    CFIndex count = CFArrayGetCount(ids->forms);
    for (size_t i = 0; i + 4 <= n; i++) {
        uint32_t h = pj_head(b + i);
        if (!(ids->heads[h >> 3] & (1u << (h & 7)))) continue;
        for (CFIndex k = 0; k < count; k++) {
            CFDataRef d = CFArrayGetValueAtIndex(ids->forms, k);
            size_t m = (size_t)CFDataGetLength(d);
            if (m > n - i || memcmp(b + i, CFDataGetBytePtr(d), m) != 0) continue;
            if (!mask) return 1;
            memset(mask + i, 1, m);
            found = 1;
        }
    }
    return found;
}

PJ_FN int pj_ids_hit(const pj_ids *ids, const unsigned char *b, size_t n) { return pj_ids_scan(ids, b, n, NULL); }

/* 1 when b[0..n) is exactly one of the exact-only forms. */
PJ_FN int pj_ids_exact(const pj_ids *ids, const unsigned char *b, size_t n) {
    CFDataRef d = CFDataCreate(NULL, b, (CFIndex)n);
    int hit = CFArrayContainsValue(ids->exact, CFRangeMake(0, CFArrayGetCount(ids->exact)), d);
    CFRelease(d);
    return hit;
}

/* 1 when the value is withheld by its key's name or holds an identifier. */
PJ_FN int pj_ids_match(const pj_ids *ids, CFStringRef key, CFTypeRef value) {
    if (key && pj_key_withheld(key)) return 1;
    CFTypeID t = CFGetTypeID(value);
    if (t == CFStringGetTypeID()) {
        size_t n = 0;
        unsigned char *b = pj_cf_utf8((CFStringRef)value, &n);
        int hit = b ? pj_ids_hit(ids, b, n) : 0;
        free(b);
        return hit;
    }
    if (t == CFDataGetTypeID()) {
        const unsigned char *b = CFDataGetBytePtr((CFDataRef)value);
        size_t n = (size_t)CFDataGetLength((CFDataRef)value);
        return pj_ids_hit(ids, b, n) || pj_ids_exact(ids, b, n);
    }
    /* Integers carry identifiers too: IOAVBNub's EntityID is built from the
       built-in Ethernet address (measured on the mini, 2026-10-07). Match the
       value's bytes in both orders. */
    if (t == CFNumberGetTypeID() && !CFNumberIsFloatType((CFNumberRef)value)) {
        int64_t v = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &v)) {
            unsigned char le[8], be[8];
            for (int i = 0; i < 8; i++) {
                le[i] = (unsigned char)((uint64_t)v >> (8 * i));
                be[7 - i] = le[i];
            }
            return pj_ids_hit(ids, le, sizeof le) || pj_ids_hit(ids, be, sizeof be);
        }
    }
    return 0;
}

/* The verdict for one value: 0 to write it, PJ_PART for data that holds an
   identifier among other bytes (Darryl, 2026-10-07: BluetoothUHEDevices holds
   the Mac's Bluetooth address next to a paired device's), PJ_WITHHOLD
   otherwise. A key withheld by name is withheld whole. */
PJ_FN int pj_privacy_verdict(const pj_ids *ids, CFStringRef key, CFTypeRef value) {
    if (!pj_ids_match(ids, key, value)) return 0;
    if (CFGetTypeID(value) == CFDataGetTypeID() && !(key && pj_key_withheld(key))) return PJ_PART;
    return PJ_WITHHOLD;
}

/* The writer's hooks, with the pj_ids as context. */
PJ_FN int pj_privacy_withhold(void *ctx, CFStringRef key, CFTypeRef value) {
    return pj_privacy_verdict(ctx, key, value);
}

/* Marks every byte of every identifier found in b. */
PJ_FN void pj_privacy_mask(void *ctx, const unsigned char *b, size_t n, unsigned char *mask) {
    const pj_ids *ids = ctx;
    if (pj_ids_exact(ids, b, n)) memset(mask, 1, n);
    else pj_ids_scan(ids, b, n, mask);
}

/* Withholds the Mac's identifiers in everything w writes from now on: values
   through pj_value, raw bytes through pj_bytes_field. Add no identifier after. */
PJ_FN void pj_privacy_attach(pj_writer *w, pj_ids *ids) {
    pj_ids_finish(ids);
    w->withhold = pj_privacy_withhold;
    w->mask = pj_privacy_mask;
    w->withhold_ctx = ids;
}

/* Every probe's first act: gathers the identifiers, attaches them, writes
   the header. Returns 1 to go on. When gathering is incomplete the probe
   cannot tell what to withhold, so it fails closed: the footer follows the
   header at once, stopped with reason identifiers_incomplete and the step
   that failed, and the caller returns without writing a record (FORMAT.md,
   "Footer"). */
PJ_FN int pj_privacy_begin(pj_writer *w, pj_ids *ids, const char *probe) {
    int complete = pj_ids_gather(ids);
    pj_privacy_attach(w, ids);
    pj_header(w, probe);
    if (complete) return 1;
    pj_footer_with_step(w, "identifiers_incomplete", ids->incomplete);
    return 0;
}

#endif /* PROBE_JSON_H */
