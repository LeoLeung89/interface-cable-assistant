/*
 * 54_power_sources: the power-sources API (IOKit.ps) as format 1 JSON Lines.
 *
 * Replaces 39_system_power_adapter. Spec: the "Probe rebuild" project in
 * Linear. Output contract: FORMAT.md beside this file.
 *
 * After the header line it writes, in this order:
 *   adapter         IOPSCopyExternalPowerAdapterDetails(): the details
 *                   dictionary, or null. Null is not "on battery": Apple
 *                   documents it as "no adapter details or an error", and
 *                   desktops on AC report it too. providing_type tells them apart.
 *   providing_type  IOPSGetProvidingPowerSourceType(): "AC Power",
 *                   "Battery Power" or "UPS Power", or null
 *   source          once per power source, in list order: its description
 * then the footer line. A call that returned nothing is written as a failure
 * record, never skipped.
 *
 * Adapter and battery serials are device serials and are kept (spec,
 * Privacy). The Mac's own identifiers are withheld as in every probe, should
 * one ever appear here.
 */
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>

#include "probe_json.h"

#define PROBE_NAME "54_power_sources"
/* The small probes share one cap, far above what they write (this one writes a
   few KB), so a runaway stops with reason "byte_cap" in its footer rather than
   being discarded whole by the app's output limit. */
#define BYTE_CAP (4ULL * 1024 * 1024)

static pj_writer W;
static pj_ids g_ids;

static void failure(const char *what) {
    W.failures++;
    if (!pj_record_begin(&W, "failure")) return;
    pj_field(&W, "what");
    pj_text(&W, what);
    pj_record_end(&W);
}

int main(void) {
    pj_init(&W, stdout, BYTE_CAP);
    /* The Mac's own identifiers are withheld here too; a lookup that failed
       means a header, a stopped footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;

    CFDictionaryRef adapter = IOPSCopyExternalPowerAdapterDetails();
    if (pj_record_begin(&W, "adapter")) {
        pj_field(&W, "details");
        if (adapter) pj_value(&W, adapter, NULL, 0);
        else pj_lit(&W, "null");
        pj_record_end(&W);
    }
    if (adapter) CFRelease(adapter);

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) {
        failure("power_sources_info");
        pj_footer(&W, W.capped ? "byte_cap" : NULL);
        return 0;
    }

    CFStringRef providing = IOPSGetProvidingPowerSourceType(blob);
    if (pj_record_begin(&W, "providing_type")) {
        pj_field(&W, "value");
        if (providing) pj_value(&W, providing, NULL, 0);
        else pj_lit(&W, "null");
        pj_record_end(&W);
    }

    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) {
        failure("power_sources_list");
    } else {
        CFIndex n = CFArrayGetCount(sources);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef desc = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, i));
            if (!pj_record_begin(&W, "source")) break;
            pj_field(&W, "index");
            pj_fmt(&W, "%ld", (long)i);
            pj_field(&W, "description");
            if (desc) {
                pj_value(&W, desc, NULL, 0);
            } else {
                W.failures++;
                pj_lit(&W, "{\"t\":\"failed\",\"what\":\"power_source_description\"}");
            }
            pj_record_end(&W);
        }
        CFRelease(sources);
    }
    CFRelease(blob);
    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
