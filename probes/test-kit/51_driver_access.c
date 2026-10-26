/*
 * 51_driver_access: what a user-space process may do with the port and
 * Thunderbolt drivers, as format 1 JSON Lines.
 *
 * Replaces the live tests of 21_tb_cfplugin_retimer, 03_hpm_deep_dive and
 * 29_usb4_router_interfaces; their registry dumps are in 50_registry_snapshot
 * (join on the entry IDs). Spec: the "Probe rebuild" project in Linear.
 * Output contract: FORMAT.md beside this file.
 *
 * After the header line it writes, then the footer:
 *   cfplugin               once per IOThunderboltController (21 tried only the
 *                          first): IOCreatePlugInInterfaceForService and a
 *                          QueryInterface on the result
 *   interest_notification  once per IOPortTransportComponentCCUSBPDSOPp (03):
 *                          whether general and busy interest notifications can
 *                          be registered
 *   user_client_open       once per service of probe 29's classes, by entry ID:
 *                          the IOServiceOpen result (29 printed only successes),
 *                          or why it was not tried
 *
 * Every connection opened is closed at once and no method is called on it. As
 * in probe 29, a USB service carrying a mass-storage or HID class is never
 * opened (the macOS removable-volume prompt, or seizing a keyboard or mouse);
 * one whose class could not be read is not opened either (the guard fails
 * closed, and the record says class_unknown). At most 6 IOUSBHostInterface
 * services are tried.
 */
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>

#include "probe_json.h"

#define PROBE_NAME "51_driver_access"
/* The small probes share one cap, far above what they write, so a runaway
   stops with reason "byte_cap" in its footer rather than being discarded
   whole by the app's output limit. */
#define BYTE_CAP (4ULL * 1024 * 1024)
#define MAX_USB_INTERFACES 6

static pj_writer W;
static pj_ids g_ids;
static CFMutableSetRef g_opened; /* entry IDs already given a user_client_open record */

static void field_kr(const char *name, long kr) {
    pj_field(&W, name);
    pj_fmt(&W, "\"0x%08lx\"", (unsigned long)(uint32_t)kr);
}

/* id comes from pj_entry_id, read before the record opened. */
static void field_entry(io_registry_entry_t e, uint64_t id) {
    pj_field(&W, "id");
    pj_fmt(&W, "\"0x%llx\"", (unsigned long long)id);
    CFStringRef cls = IOObjectCopyClass(e);
    pj_field(&W, "class");
    if (cls) {
        pj_cfstring(&W, cls);
        CFRelease(cls);
    } else {
        pj_lit(&W, "null");
    }
}

static void failure(const char *what, const char *cls, kern_return_t kr) {
    W.failures++;
    if (!pj_record_begin(&W, "failure")) return;
    pj_field(&W, "what");
    pj_text(&W, what);
    pj_field(&W, "class");
    pj_text(&W, cls);
    field_kr("kr", kr);
    pj_record_end(&W);
}

/* Calls fn on every service of a class. Reports a matching failure, and an
   iterator the registry invalidated after returning something (an iterator
   over a class with no services also reports invalid, measured on the mini). */
static void each_service(const char *cls, void (*fn)(io_service_t, const char *, int), int limit) {
    io_iterator_t it = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it);
    if (kr != KERN_SUCCESS) {
        failure("matching", cls, kr);
        return;
    }
    io_service_t s;
    int n = 0;
    while (!W.capped && (s = IOIteratorNext(it))) {
        fn(s, cls, limit > 0 && n >= limit);
        IOObjectRelease(s);
        n++;
    }
    if (n > 0 && !W.capped && !IOIteratorIsValid(it)) failure("iterator_invalidated", cls, kIOReturnAborted);
    IOObjectRelease(it);
}

static void try_cfplugin(io_service_t s, const char *cls, int over_limit) {
    (void)cls;
    (void)over_limit;
    uint64_t id = 0;
    if (!pj_entry_id(&W, s, &id) || !pj_record_begin(&W, "cfplugin")) return;
    field_entry(s, id);
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIOCFPlugInInterfaceID, kIOCFPlugInInterfaceID, &plugin, &score);
    field_kr("create_kr", kr);
    pj_field(&W, "score");
    pj_fmt(&W, "%d", (int)score);
    if (kr == KERN_SUCCESS && plugin) {
        void *iface = NULL;
        HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOCFPlugInInterfaceID), &iface);
        field_kr("query_hr", hr);
        pj_field(&W, "interface");
        pj_lit(&W, iface ? "true" : "false");
        if (iface) (*plugin)->Release(plugin); /* QueryInterface added a reference */
        IODestroyPlugInInterface(plugin);
    }
    pj_record_end(&W);
}

static void try_interest(io_service_t s, const char *cls, int over_limit) {
    (void)cls;
    (void)over_limit;
    uint64_t id = 0;
    if (!pj_entry_id(&W, s, &id) || !pj_record_begin(&W, "interest_notification")) return;
    field_entry(s, id);
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    pj_field(&W, "port_created");
    pj_lit(&W, port ? "true" : "false");
    if (port) {
        static const struct { const char *field; const char *type; } kInterests[] = {
            {"general_kr", kIOGeneralInterest},
            {"busy_kr", kIOBusyInterest},
        };
        for (size_t i = 0; i < sizeof kInterests / sizeof kInterests[0]; i++) {
            io_object_t notifier = 0;
            kern_return_t kr = IOServiceAddInterestNotification(port, s, kInterests[i].type, NULL, NULL, &notifier);
            field_kr(kInterests[i].field, kr);
            if (kr == KERN_SUCCESS) IOObjectRelease(notifier);
        }
        IONotificationPortDestroy(port);
    } else {
        W.failures++;
    }
    pj_record_end(&W);
}

static void try_open(io_service_t s, const char *matched, int over_limit) {
    uint64_t id = 0;
    if (!pj_entry_id(&W, s, &id)) return;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    int seen = CFSetContainsValue(g_opened, n);
    if (!seen) CFSetAddValue(g_opened, n);
    CFRelease(n);
    if (seen || !pj_record_begin(&W, "user_client_open")) return;
    field_entry(s, id);
    pj_field(&W, "matched");
    pj_text(&W, matched);
    /* Probe 29's guard (pj_usb_class_guard): a USB service, or one of its
       direct children, carrying a mass-storage or HID class is never opened.
       A guard that could not complete its reads is unknown: not opened either,
       and a failure. The Thunderbolt classes are not USB services. */
    int guard = over_limit || strstr(matched, "Thunderbolt") ? 0 : pj_usb_class_guard(s, 1);
    pj_field(&W, "not_tried");
    if (over_limit) {
        pj_text(&W, "interface_limit");
    } else if (guard < 0) {
        pj_text(&W, "class_unknown");
        W.failures++;
    } else if (guard) {
        pj_text(&W, "storage_or_hid");
    } else {
        pj_lit(&W, "null");
        io_connect_t conn = 0;
        kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &conn);
        field_kr("open_kr", kr);
        if (kr == KERN_SUCCESS) IOServiceClose(conn);
    }
    pj_record_end(&W);
}

int main(void) {
    pj_init(&W, stdout, BYTE_CAP);
    /* The Mac's own identifiers are withheld here too; a lookup that failed
       means a header, a stopped footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;
    g_opened = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);

    each_service("IOThunderboltController", try_cfplugin, 0);
    each_service("IOPortTransportComponentCCUSBPDSOPp", try_interest, 0);

    static const char *const kOpenClasses[] = {
        "IOThunderboltUSB4Router", "IOThunderboltUSB4HostRouter", "IOThunderboltUSB4DeviceRouter",
        "AppleUSB4Hub", "AppleUSB40HostPort", "AppleUSB40DevicePort", "IOThunderboltNHI",
        "IOUSBHostInterface", "IOThunderboltPort", "IOThunderboltSwitch", "IOIOThunderboltSwitch",
        "IOThunderboltConnection", "IOThunderboltTunnelDriver",
        NULL,
    };
    for (int c = 0; kOpenClasses[c] && !W.capped; c++)
        each_service(kOpenClasses[c], try_open, strcmp(kOpenClasses[c], "IOUSBHostInterface") == 0 ? MAX_USB_INTERFACES : 0);

    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
