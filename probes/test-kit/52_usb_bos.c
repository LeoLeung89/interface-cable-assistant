/*
 * 52_usb_bos: each USB device's raw BOS descriptor, as format 1 JSON Lines.
 *
 * Replaces 25_usb_bos_descriptor. Spec: the "Probe rebuild" project in Linear.
 * Output contract: FORMAT.md beside this file. The devices' registry
 * properties are in 50_registry_snapshot; join on the entry ID.
 *
 * After the header line it writes one bos record per service of the classes
 * probe 25 tried (IOUSBHostDevice and subclasses, the USB4 router and hub
 * classes, the Billboard classes), each once by entry ID, then the footer.
 * Each record carries the result of every step reached, and the descriptor's
 * full bytes when the device returned them. Nothing is parsed.
 *
 * The request goes through DeviceRequestTO on the unopened device interface,
 * the no-open pattern of BillboardDescriptorReader.swift, with a 3 s timeout
 * (probe 25 had none). A device with a mass-storage interface is not asked at
 * all, to avoid the macOS removable-volume prompt; its record says so. One
 * whose classes could not be read is not asked either (the guard fails
 * closed): mass_storage is null and the record says class_unknown.
 */
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#include "probe_json.h"

#define PROBE_NAME "52_usb_bos"
/* The small probes share one cap, far above what they write, so a runaway
   stops with reason "byte_cap" in its footer rather than being discarded
   whole by the app's output limit. */
#define BYTE_CAP (4ULL * 1024 * 1024)
#define BOS_DESCRIPTOR 0x0F
#define REQUEST_TIMEOUT_MS 3000
#define BOS_MAX_BYTES 4096

static pj_writer W;
static pj_ids g_ids;
static CFMutableSetRef g_seen; /* entry IDs already written */

static const char *const kClasses[] = {
    "IOUSBHostDevice",
    "AppleUSB4Hub", "IOThunderboltUSB4Router", "AppleUSB40DevicePort", "AppleUSB40HostPort", "IOUSBHostHubDevice",
    "AppleUSBHostBillboardDevice", "IOUSBHostBillboardDevice",
    NULL,
};

static void field_kr(const char *name, long kr) {
    pj_field(&W, name);
    pj_fmt(&W, "\"0x%08lx\"", (unsigned long)(uint32_t)kr);
}

static IOReturn get_bos(IOUSBDeviceInterface182 **dev, UInt8 *buf, UInt16 len, UInt32 *done) {
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof req);
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
    req.bRequest = kUSBRqGetDescriptor;
    req.wValue = (BOS_DESCRIPTOR << 8) | 0;
    req.wLength = len;
    req.pData = buf;
    req.noDataTimeout = REQUEST_TIMEOUT_MS;
    req.completionTimeout = REQUEST_TIMEOUT_MS;
    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    *done = req.wLenDone;
    return kr;
}

/* Writes the steps after the plugin: header request, then the full one. */
static void request_bos(IOUSBDeviceInterface182 **dev) {
    UInt8 header[5] = {0};
    UInt32 done = 0;
    IOReturn kr = get_bos(dev, header, sizeof header, &done);
    field_kr("header_kr", kr);
    pj_bytes_field(&W, "header", header, done > sizeof header ? sizeof header : done);
    if (kr != kIOReturnSuccess || done < sizeof header) {
        W.failures++;
        return;
    }
    UInt16 total = (UInt16)(header[2] | (header[3] << 8));
    pj_field(&W, "total_length");
    pj_fmt(&W, "%u", (unsigned)total);
    /* A device without a BOS answers with another descriptor type, or a length
       no BOS can have: recorded as it came, not asked again. */
    if (header[1] != BOS_DESCRIPTOR || total < 5 || total > BOS_MAX_BYTES) return;
    UInt8 *buf = calloc(1, total);
    if (!buf) {
        fputs("52_usb_bos: out of memory\n", stderr);
        abort();
    }
    kr = get_bos(dev, buf, total, &done);
    field_kr("bos_kr", kr);
    pj_bytes_field(&W, "bytes", buf, done > total ? total : done);
    if (kr != kIOReturnSuccess || done != total) W.failures++;
    free(buf);
}

static void write_bos(io_service_t s, uint64_t id, const char *matched) {
    CFStringRef cls = IOObjectCopyClass(s);
    if (!pj_record_begin(&W, "bos")) {
        if (cls) CFRelease(cls);
        return;
    }
    pj_field(&W, "id");
    pj_fmt(&W, "\"0x%llx\"", (unsigned long long)id);
    pj_field(&W, "class");
    if (cls) pj_cfstring(&W, cls);
    else pj_lit(&W, "null");
    if (cls) CFRelease(cls);
    pj_field(&W, "matched");
    pj_text(&W, matched);
    /* The device's class, or one of its interfaces, is mass storage
       (pj_usb_class_guard, fail closed): true means not asked; null means the
       guard could not complete its reads, so the device is not asked either,
       and that is a failure. */
    int mass = pj_usb_class_guard(s, 0);
    pj_field(&W, "mass_storage");
    pj_lit(&W, mass < 0 ? "null" : (mass ? "true" : "false"));
    if (mass < 0) {
        pj_field(&W, "not_tried");
        pj_text(&W, "class_unknown");
        W.failures++;
    } else if (!mass) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        field_kr("plugin_kr", kr);
        if (kr != KERN_SUCCESS || !plugin) {
            W.failures++;
        } else {
            IOUSBDeviceInterface182 **dev = NULL;
            HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
            IODestroyPlugInInterface(plugin);
            field_kr("query_hr", hr);
            if (hr || !dev) {
                W.failures++;
            } else {
                request_bos(dev);
                (*dev)->Release(dev);
            }
        }
    }
    pj_record_end(&W);
}

int main(void) {
    pj_init(&W, stdout, BYTE_CAP);
    /* The Mac's own identifiers are withheld here too; a lookup that failed
       means a header, a stopped footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;
    g_seen = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    for (int c = 0; kClasses[c] && !W.capped; c++) {
        io_iterator_t it = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kClasses[c]), &it);
        if (kr != KERN_SUCCESS) {
            W.failures++;
            if (pj_record_begin(&W, "failure")) {
                pj_field(&W, "what");
                pj_text(&W, "matching");
                pj_field(&W, "class");
                pj_text(&W, kClasses[c]);
                field_kr("kr", kr);
                pj_record_end(&W);
            }
            continue;
        }
        io_service_t s;
        int saw_any = 0;
        while (!W.capped && (s = IOIteratorNext(it))) {
            saw_any = 1;
            uint64_t id = 0;
            if (pj_entry_id(&W, s, &id)) { /* a failed lookup is a failure record, not a dropped device */
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
                if (!CFSetContainsValue(g_seen, n)) {
                    CFSetAddValue(g_seen, n);
                    write_bos(s, id, kClasses[c]);
                }
                CFRelease(n);
            }
            IOObjectRelease(s);
        }
        /* The registry changed under the iterator: services may be missing. An
           iterator over a class with no services also reports invalid
           (measured on the mini, 2026-10-07), so only one that returned
           something is checked, as probe 25 did. */
        if (saw_any && !W.capped && !IOIteratorIsValid(it) && pj_record_begin(&W, "failure")) {
            W.failures++;
            pj_field(&W, "what");
            pj_text(&W, "iterator_invalidated");
            pj_field(&W, "class");
            pj_text(&W, kClasses[c]);
            pj_record_end(&W);
        }
        IOObjectRelease(it);
    }
    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
