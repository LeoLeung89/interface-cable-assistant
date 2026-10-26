/*
 * 50_registry_snapshot: the whole IORegistry, every plane, as JSON Lines.
 *
 * Spec: the "Probe rebuild" project in Linear. Output contract: FORMAT.md
 * beside this file. Read-only: it opens no user clients, sends no device
 * requests and changes nothing.
 *
 * After the header line it writes:
 *   entry    once per registry entry: id, class, every property as typed values
 *   link     once per (entry, parent) in each plane: plane, id, parent, pos,
 *            name, location, path. An entry's children in a plane are the links
 *            naming it as parent, in pos order.
 *   class    once per class seen: superclass chain and owning bundle
 *   failure  any read that failed, with its kern_return_t
 *   withheld_summary  once: what was withheld, counted by class and key
 *   skipped_summary   once, last: the process connections whose properties
 *                     were not recorded
 * then the footer line.
 *
 * Process connections (entries that are an IOUserClient, which record which app
 * or daemon has a driver open) are not recorded: the snapshot is about hardware,
 * not processes (Darryl, 2026-10-07). Nor is IODTNVRAMDiags (NVRAM access
 * statistics). Such an entry keeps its class and its place in the tree (Darryl,
 * 2026-10-08): its entry record carries {"t":"skipped"} in place of its
 * properties, which are never recorded, and its links are written like any other
 * entry's, so a walk down from the root reaches what hangs beneath it. That is
 * recorded like anything else, because Bluetooth accessories appear as virtual
 * HID devices created through a user client (the MacBook, 2026-10-07:
 * IOHIDUserDevice, IOHIDInterface and event services beneath
 * IOHIDResourceDeviceUserClient). The skipped classes are counted and their
 * entry IDs listed, so the skip is visible. NVRAM variables on the IODTNVRAM
 * entries are written as {"t":"skipped"} unless they describe hardware:
 * Bluetooth (useful for future products and WhatBattery) and the USB-C
 * firmware and display routing variables. Boot state and settings are not
 * hardware.
 *
 * Privacy (spec "Privacy"; the project's hardware-identifier rule): only personal privacy
 * is protected, by the rules all the probes share in probe_json.h. Withheld: what
 * ties this Mac to its owner (serial numbers, platform UUID, chip ID, its own
 * network and Bluetooth addresses) and the home folder path, by key name and by
 * content, because the Mac's own identifiers recur under other keys (measured on
 * the mini 2026-10-07: a network address inside mDNS_Offload_Capable and in
 * IOAVBNub's EntityID; the chip ID in /chosen/iBoot's boot manifest); the user's
 * name by key name only (IOConsoleUsers). Everything else is kept, including
 * every identifier that links information across the registry (port UUIDs,
 * device serials, locationID, volume UUIDs, paired devices' Bluetooth addresses).
 */
#include <IOKit/IOKitLib.h>

#include "probe_json.h"

#define PROBE_NAME "50_registry_snapshot"
/* Every submission must fit one Workers KV value: 25 MiB, after the app gzips and
   base64-encodes it. Output that barely compresses (random data as hex) is
   stored at 0.76 of its raw size (measured 2026-10-07), so 30 MiB raw stays
   under 23 MiB stored. Real snapshots are far smaller: the mini's 9.07 MB raw is
   660 KB stored. */
#define BYTE_CAP (30ULL * 1024 * 1024)
/* Far beyond any real registry (21 levels in IOService on the mini); a scratch
   build can lower it with -DMAX_WALK_DEPTH to exercise the limit. */
#ifndef MAX_WALK_DEPTH
#define MAX_WALK_DEPTH 256
#endif

static pj_writer W;
static CFMutableSetRef g_entries; /* CFNumber entry IDs that have an entry record */
static CFMutableSetRef g_classes; /* CFString class names seen */
/* CFNumber entry ID -> class name, for the process connections themselves
   (entries written with the skipped marker in place of their properties). */
static CFMutableDictionaryRef g_skipped;

/* ---- privacy ------------------------------------------------------------ */

/* The Mac's own identifiers. The rules for them (forms, key names, partial
   withholding) are shared with the small probes in probe_json.h; this probe
   adds NVRAM and counts what it withheld. */
static pj_ids g_ids;

/* What was withheld, as counts per "class: key" (names only, never values), so
   every submission shows whether too much is being withheld. */
static CFMutableDictionaryRef g_withheld_counts;
static CFStringRef g_current_class;

static CFMutableDictionaryRef g_skipped_props; /* "class: key" -> NVRAM variables written as skipped */
static int g_nvram_entry; /* the entry being written holds NVRAM variables */

static void count_label(CFMutableDictionaryRef counts, CFStringRef key) {
    CFStringRef label = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@: %@"),
                                                 g_current_class ? g_current_class : CFSTR("?"),
                                                 key ? key : CFSTR("[member or key]"));
    long n = 0;
    CFNumberRef old = CFDictionaryGetValue(counts, label);
    if (old) CFNumberGetValue(old, kCFNumberLongType, &n);
    n++;
    CFNumberRef now = CFNumberCreate(NULL, kCFNumberLongType, &n);
    CFDictionarySetValue(counts, label, now);
    CFRelease(now);
    CFRelease(label);
}

/* NVRAM variables worth keeping: Bluetooth (Darryl, 2026-10-07: useful for
   future products and WhatBattery) and the two that describe hardware. The
   driver's own IO* keys are registry bookkeeping and stay too. */
static int nvram_variable_kept(CFStringRef key) {
    char k[256];
    if (!CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8)) return 0;
    if (strncmp(k, "IO", 2) == 0) return 1;
    if (strcasestr(k, "bluetooth")) return 1;
    return strncmp(k, "usbc,", 5) == 0 || strncmp(k, "display-crossbar", 16) == 0;
}

static int withhold(void *ctx, CFStringRef key, CFTypeRef value) {
    /* W.depth 1 is an entry's own property: an NVRAM variable, not a value nested in one. */
    if (g_nvram_entry && key && W.depth == 1 && !nvram_variable_kept(key)) {
        count_label(g_skipped_props, key);
        return PJ_SKIP;
    }
    int verdict = pj_privacy_verdict(ctx, key, value);
    if (verdict) count_label(g_withheld_counts, key);
    return verdict;
}

/* ---- records ------------------------------------------------------------ */

static void write_id(uint64_t id) { pj_fmt(&W, "\"0x%llx\"", (unsigned long long)id); }

static int set_add_id(CFMutableSetRef set, uint64_t id) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    int added = !CFSetContainsValue(set, n);
    if (added) CFSetAddValue(set, n);
    CFRelease(n);
    return added;
}

static void set_remove_id(CFMutableSetRef set, uint64_t id) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    CFSetRemoveValue(set, n);
    CFRelease(n);
}

/* One plane's walk state. */
typedef struct {
    CFMutableDictionaryRef shallowest; /* CFNumber id -> least depth walked from (pj_walk_first) */
    CFMutableSetRef links;             /* CFData {id, parent}: the links written */
    CFMutableSetRef refused;           /* CFNumber ids the depth limit stopped at, so far */
} plane_state;

/* 1 the first time (id, parent) is met in this plane. A link is written once
   per pair: an entry walked again from a shallower parent must not repeat
   its children's links. */
static int link_new(CFMutableSetRef links, uint64_t id, uint64_t parent) {
    uint64_t pair[2] = {id, parent};
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)pair, sizeof pair);
    int added = !CFSetContainsValue(links, d);
    if (added) CFSetAddValue(links, d);
    CFRelease(d);
    return added;
}

/* plane and id may be NULL and 0 when the failure is not about one entry. */
static void failure_record(const char *what, const char *plane, uint64_t id, kern_return_t kr) {
    W.failures++;
    if (!pj_record_begin(&W, "failure")) return;
    pj_field(&W, "what");
    pj_text(&W, what);
    pj_field(&W, "plane");
    if (plane) pj_text(&W, plane);
    else pj_lit(&W, "null");
    pj_field(&W, "id");
    if (id) write_id(id);
    else pj_lit(&W, "null");
    pj_field(&W, "kr");
    pj_fmt(&W, "\"0x%08x\"", (unsigned)kr);
    pj_record_end(&W);
}

static void write_entry(io_registry_entry_t e, uint64_t id) {
    CFStringRef cls = IOObjectCopyClass(e);
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0);
    if (pj_record_begin(&W, "entry")) {
        pj_field(&W, "id");
        write_id(id);
        pj_field(&W, "class");
        if (cls) pj_cfstring(&W, cls);
        else pj_lit(&W, "null");
        pj_field(&W, "props");
        if (kr == KERN_SUCCESS && props) {
            g_current_class = cls;
            g_nvram_entry = IOObjectConformsTo(e, "IODTNVRAM") || IOObjectConformsTo(e, "IODTNVRAMVariables");
            pj_value(&W, props, NULL, 0);
            g_nvram_entry = 0;
            g_current_class = NULL;
        } else {
            W.failures++;
            pj_fmt(&W, "{\"t\":\"failed\",\"what\":\"properties\",\"kr\":\"0x%08x\"}", (unsigned)kr);
        }
        pj_record_end(&W);
    }
    if (cls) {
        CFSetAddValue(g_classes, cls);
        CFRelease(cls);
    } else {
        failure_record("class", NULL, id, kIOReturnError);
    }
    if (props) CFRelease(props);
}

static void write_link(const char *plane, io_registry_entry_t e, uint64_t id, uint64_t parent, int pos, int is_root) {
    io_name_t name, location;
    kern_return_t name_kr = IORegistryEntryGetNameInPlane(e, plane, name);
    kern_return_t location_kr = IORegistryEntryGetLocationInPlane(e, plane, location);
    CFStringRef path = IORegistryEntryCopyPath(e, plane);
    if (pj_record_begin(&W, "link")) {
        pj_field(&W, "plane");
        pj_text(&W, plane);
        pj_field(&W, "id");
        write_id(id);
        pj_field(&W, "parent");
        if (is_root) pj_lit(&W, "null");
        else write_id(parent);
        pj_field(&W, "pos");
        pj_fmt(&W, "%d", pos);
        pj_field(&W, "name");
        if (name_kr == KERN_SUCCESS) pj_text(&W, name);
        else pj_lit(&W, "null");
        pj_field(&W, "location"); /* most entries have none: null, not a failure */
        if (location_kr == KERN_SUCCESS) pj_text(&W, location);
        else pj_lit(&W, "null");
        pj_field(&W, "path");
        if (path) pj_cfstring(&W, path);
        else pj_lit(&W, "null");
        pj_record_end(&W);
    }
    if (name_kr != KERN_SUCCESS) failure_record("name", plane, id, name_kr);
    if (path) CFRelease(path);
}

/* The entry record of e, a process connection: its class, and the skipped
   marker in place of its properties, which are never written (the app or daemon
   name lives there). Written once, the first time it is met; listed in
   skipped_summary. Its links are written by the caller like any entry's. */
static void write_connection(io_registry_entry_t e, uint64_t id) {
    if (!set_add_id(g_entries, id)) return;
    CFStringRef cls = IOObjectCopyClass(e);
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    CFDictionarySetValue(g_skipped, key, cls ? cls : CFSTR("?"));
    CFRelease(key);
    if (pj_record_begin(&W, "entry")) {
        pj_field(&W, "id");
        write_id(id);
        pj_field(&W, "class");
        if (cls) pj_cfstring(&W, cls);
        else pj_lit(&W, "null");
        pj_field(&W, "props");
        pj_lit(&W, "{\"t\":\"skipped\"}");
        pj_record_end(&W);
    }
    if (cls) {
        CFSetAddValue(g_classes, cls);
        CFRelease(cls);
    } else {
        failure_record("class", NULL, id, kIOReturnError);
    }
}

/* Walks parent's children in plane: an entry and a link for each, then its own
   children. A process connection gets an entry without properties, and its
   children are walked all the same, so the tree stays whole (an accessory's
   virtual HID device hangs beneath a user client). An entry with two parents
   in a plane is linked once per parent and walked once, unless the first path
   to it hit the depth limit and a later one is shallower: then it is walked
   from there (pj_walk_first), and its children's links are not repeated. An
   entry still stopped by the limit at the end of the plane is a depth failure. */
static void walk(const char *plane, io_registry_entry_t parent, uint64_t parent_id, plane_state *st, int depth) {
    io_iterator_t it = 0;
    kern_return_t kr = IORegistryEntryGetChildIterator(parent, plane, &it);
    if (kr != KERN_SUCCESS) {
        failure_record("child_iterator", plane, parent_id, kr);
        return;
    }
    int pos = 0;
    io_registry_entry_t child;
    while (!W.capped && (child = IOIteratorNext(it))) {
        uint64_t id = 0;
        kr = IORegistryEntryGetRegistryEntryID(child, &id);
        if (kr != KERN_SUCCESS) {
            failure_record("entry_id", plane, parent_id, kr);
        } else {
            if (IOObjectConformsTo(child, "IOUserClient") || IOObjectConformsTo(child, "IODTNVRAMDiags")) {
                write_connection(child, id); /* a process connection or NVRAM statistics: not hardware */
            } else if (set_add_id(g_entries, id)) {
                write_entry(child, id);
            }
            if (link_new(st->links, id, parent_id)) write_link(plane, child, id, parent_id, pos, 0);
            if (pj_walk_first(st->shallowest, id, depth + 1)) {
                if (depth + 1 >= MAX_WALK_DEPTH) {
                    set_add_id(st->refused, id); /* its children wait for a shallower path, if any */
                } else {
                    set_remove_id(st->refused, id);
                    walk(plane, child, id, st, depth + 1);
                }
            }
        }
        IOObjectRelease(child);
        pos++;
    }
    /* The registry changed under the iterator: children of this entry may be missing. */
    if (!W.capped && !IOIteratorIsValid(it)) failure_record("iterator_invalidated", plane, parent_id, kIOReturnAborted);
    IOObjectRelease(it);
}

static CFComparisonResult plane_order(const void *a, const void *b, void *ctx) {
    (void)ctx;
    int sa = CFEqual(a, CFSTR(kIOServicePlane)), sb = CFEqual(b, CFSTR(kIOServicePlane));
    if (sa != sb) return sa ? kCFCompareLessThan : kCFCompareGreaterThan;
    return CFStringCompare(a, b, 0);
}

/* Plane names from the root's IORegistryPlanes, IOService first, the rest by name. */
static CFMutableArrayRef copy_planes(io_registry_entry_t root, uint64_t root_id) {
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFTypeRef planes = pj_copy_prop(root, "IORegistryPlanes");
    if (pj_is_type(planes, CFDictionaryGetTypeID())) {
        CFIndex n = CFDictionaryGetCount(planes);
        const void **keys = pj_xmalloc(sizeof(void *) * (size_t)n);
        CFDictionaryGetKeysAndValues(planes, keys, NULL);
        for (CFIndex i = 0; i < n; i++)
            if (pj_is_type(keys[i], CFStringGetTypeID())) CFArrayAppendValue(out, keys[i]);
        free(keys);
    }
    if (planes) CFRelease(planes);
    if (CFArrayGetCount(out) == 0) {
        failure_record("planes", NULL, root_id, kIOReturnNotFound);
        CFArrayAppendValue(out, CFSTR(kIOServicePlane));
    }
    CFArraySortValues(out, CFRangeMake(0, CFArrayGetCount(out)), plane_order, NULL);
    return out;
}

static CFComparisonResult name_order(const void *a, const void *b, void *ctx) {
    (void)ctx;
    return CFStringCompare(a, b, 0);
}

/* Writes counts as [["label",n],...], sorted by label. */
static void write_label_counts(CFDictionaryRef counts) {
    CFIndex n = CFDictionaryGetCount(counts);
    const void **keys = pj_xmalloc(sizeof(void *) * (size_t)n);
    CFDictionaryGetKeysAndValues(counts, keys, NULL);
    CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < n; i++) CFArrayAppendValue(sorted, keys[i]);
    free(keys);
    CFArraySortValues(sorted, CFRangeMake(0, n), name_order, NULL);
    pj_raw(&W, "[", 1);
    for (CFIndex i = 0; i < n; i++) {
        CFStringRef label = CFArrayGetValueAtIndex(sorted, i);
        long count = 0;
        CFNumberGetValue(CFDictionaryGetValue(counts, label), kCFNumberLongType, &count);
        if (i) pj_raw(&W, ",", 1);
        pj_raw(&W, "[", 1);
        pj_cfstring(&W, label);
        pj_fmt(&W, ",%ld]", count);
    }
    pj_raw(&W, "]", 1);
    CFRelease(sorted);
}

/* {"record":"withheld_summary","counts":[["IOPlatformExpertDevice: IOPlatformUUID",1],...]}:
   what was withheld, by class and key, sorted. The counts add up to the
   footer's withheld figure. */
static void write_withheld_summary(void) {
    if (pj_record_begin(&W, "withheld_summary")) {
        pj_field(&W, "counts");
        write_label_counts(g_withheld_counts);
        pj_record_end(&W);
    }
}

static CFComparisonResult id_order(const void *a, const void *b, void *ctx) {
    (void)ctx;
    return CFNumberCompare(a, b, NULL);
}

/* A depth failure for each entry the limit stopped at and no shallower path
   reached, in ascending ID order, once the plane's walk is over. */
static void write_depth_failures(const char *plane, CFSetRef refused) {
    CFIndex n = CFSetGetCount(refused);
    if (n == 0) return;
    const void **ids = pj_xmalloc(sizeof(void *) * (size_t)n);
    CFSetGetValues(refused, ids);
    CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < n; i++) CFArrayAppendValue(sorted, ids[i]);
    free(ids);
    CFArraySortValues(sorted, CFRangeMake(0, n), id_order, NULL);
    for (CFIndex i = 0; i < n; i++) {
        uint64_t id = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(sorted, i), kCFNumberSInt64Type, &id);
        failure_record("depth", plane, id, kIOReturnOverrun);
    }
    CFRelease(sorted);
}

/* {"record":"skipped_summary","counts":[["RootDomainUserClient",152],...],"ids":["0x...",...],
    "properties":[["IODTNVRAM: boot-volume",1],...]}: the entries whose
   properties were not recorded (the process connections and NVRAM statistics
   themselves) by class, their entry IDs in ascending order, and the NVRAM
   variables written as skipped. The counts add up to the number of IDs and of
   skipped markers inside entries' properties. */
static void write_skipped_summary(void) {
    CFIndex total = CFDictionaryGetCount(g_skipped);
    const void **idv = pj_xmalloc(sizeof(void *) * (size_t)total);
    const void **clsv = pj_xmalloc(sizeof(void *) * (size_t)total);
    CFDictionaryGetKeysAndValues(g_skipped, idv, clsv);
    CFMutableArrayRef ids = CFArrayCreateMutable(NULL, total, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef counts = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (CFIndex i = 0; i < total; i++) {
        CFArrayAppendValue(ids, idv[i]);
        long c = 0;
        CFNumberRef old = CFDictionaryGetValue(counts, clsv[i]);
        if (old) CFNumberGetValue(old, kCFNumberLongType, &c);
        c++;
        CFNumberRef now = CFNumberCreate(NULL, kCFNumberLongType, &c);
        CFDictionarySetValue(counts, clsv[i], now);
        CFRelease(now);
    }
    free(clsv);
    free(idv);
    CFIndex m = CFArrayGetCount(ids);
    CFArraySortValues(ids, CFRangeMake(0, m), id_order, NULL);
    if (pj_record_begin(&W, "skipped_summary")) {
        pj_field(&W, "counts");
        write_label_counts(counts);
        pj_field(&W, "ids");
        pj_raw(&W, "[", 1);
        for (CFIndex i = 0; i < m; i++) {
            uint64_t id = 0;
            CFNumberGetValue(CFArrayGetValueAtIndex(ids, i), kCFNumberSInt64Type, &id);
            if (i) pj_raw(&W, ",", 1);
            write_id(id);
        }
        pj_raw(&W, "]", 1);
        pj_field(&W, "properties");
        write_label_counts(g_skipped_props);
        pj_record_end(&W);
    }
    CFRelease(counts);
    CFRelease(ids);
}

static void write_classes(void) {
    CFIndex n = CFSetGetCount(g_classes);
    const void **names = pj_xmalloc(sizeof(void *) * (size_t)n);
    CFSetGetValues(g_classes, names);
    CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < n; i++) CFArrayAppendValue(sorted, names[i]);
    free(names);
    CFArraySortValues(sorted, CFRangeMake(0, n), name_order, NULL);
    for (CFIndex i = 0; i < n && !W.capped; i++) {
        CFStringRef name = CFArrayGetValueAtIndex(sorted, i);
        if (!pj_record_begin(&W, "class")) break;
        pj_field(&W, "name");
        pj_cfstring(&W, name);
        pj_field(&W, "super");
        pj_raw(&W, "[", 1);
        CFStringRef cur = CFRetain(name);
        for (int hops = 0; cur && hops < 64; hops++) {
            CFStringRef up = IOObjectCopySuperclassForClass(cur);
            CFRelease(cur);
            cur = up;
            if (!up) break;
            if (hops) pj_raw(&W, ",", 1);
            pj_cfstring(&W, up);
        }
        if (cur) CFRelease(cur);
        pj_raw(&W, "]", 1);
        pj_field(&W, "bundle");
        CFStringRef bundle = IOObjectCopyBundleIdentifierForClass(name);
        if (bundle) {
            pj_cfstring(&W, bundle);
            CFRelease(bundle);
        } else {
            pj_lit(&W, "null");
        }
        pj_record_end(&W);
    }
    CFRelease(sorted);
}

int main(void) {
    static char outbuf[1 << 16];
    setvbuf(stdout, outbuf, _IOFBF, sizeof outbuf);
    pj_init(&W, stdout, BYTE_CAP);
    /* Fails closed: an identifier lookup that failed means a header, a stopped
       footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;
    W.withhold = withhold; /* the shared rules, plus NVRAM and the withheld_summary counts */
    g_withheld_counts = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    g_entries = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    g_classes = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    g_skipped = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    g_skipped_props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    uint64_t root_id = 0;
    kern_return_t kr = root ? IORegistryEntryGetRegistryEntryID(root, &root_id) : kIOReturnNotFound;
    if (kr != KERN_SUCCESS) {
        failure_record("root", NULL, 0, kr);
        pj_footer(&W, "no_root");
        return 0;
    }
    set_add_id(g_entries, root_id);
    write_entry(root, root_id);

    CFMutableArrayRef planes = copy_planes(root, root_id);
    for (CFIndex i = 0; i < CFArrayGetCount(planes) && !W.capped; i++) {
        io_name_t plane;
        if (!CFStringGetCString(CFArrayGetValueAtIndex(planes, i), plane, sizeof plane, kCFStringEncodingUTF8)) {
            failure_record("plane_name", NULL, root_id, kIOReturnBadArgument);
            continue;
        }
        plane_state st = {
            CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks),
            CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks),
            CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks),
        };
        pj_walk_first(st.shallowest, root_id, 0);
        write_link(plane, root, root_id, 0, 0, 1);
        walk(plane, root, root_id, &st, 0);
        write_depth_failures(plane, st.refused);
        CFRelease(st.refused);
        CFRelease(st.links);
        CFRelease(st.shallowest);
    }
    CFRelease(planes);
    write_classes();
    write_withheld_summary();
    write_skipped_summary();
    IOObjectRelease(root);
    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
