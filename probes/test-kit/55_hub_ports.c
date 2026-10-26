/*
 * 55_hub_ports: each USB hub's raw hub descriptor, as format 1 JSON Lines.
 *
 * Replaces 40_hub_port_statistics. Spec: the "Probe rebuild" project in
 * Linear. Output contract: FORMAT.md beside this file. Probe 40's registry
 * dump (hub and port nodes, port-statistics, current budgets) is in
 * 50_registry_snapshot; join on the entry IDs. This probe keeps the one thing
 * the registry does not publish: the hub descriptor itself (bNumberPorts,
 * wHubCharacteristics, DeviceRemovable), which tells a dock's hardwired ports
 * from its user-facing ones.
 *
 * After the header line it writes one hub_descriptor record per
 * AppleUSB20Hub and AppleUSB30Hub service, then the footer. The request is a
 * class GET_DESCRIPTOR(HUB) to the hub's service-plane parent (the
 * IOUSBHostDevice it sits on), type 0x29 for a USB 2 hub and 0x2A for a
 * SuperSpeed hub, through DeviceRequestTO on the unopened device interface
 * with a 3 s timeout: probe 40's no-open pattern. One request asks for the
 * largest descriptor the type allows (71 and 12 bytes); the hub returns as
 * many as it has. Nothing is parsed.
 */
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#include "probe_json.h"

#define PROBE_NAME "55_hub_ports"
/* The small probes share one cap, far above what they write, so a runaway
   stops with reason "byte_cap" in its footer rather than being discarded
   whole by the app's output limit. */
#define BYTE_CAP (4ULL * 1024 * 1024)
#define REQUEST_TIMEOUT_MS 3000
#define USB2_HUB_DESCRIPTOR 0x29
#define USB3_HUB_DESCRIPTOR 0x2A
/* USB 2.0 11.23.2.1: 7 bytes plus two bitmaps of up to 32 bytes (255 ports).
   USB 3.2 10.15.2.1: always 12 bytes. */
#define USB2_HUB_MAX 71
#define USB3_HUB_MAX 12

static pj_writer W;
static pj_ids g_ids;

static void field_kr(const char *name, long kr) {
    pj_field(&W, name);
    pj_fmt(&W, "\"0x%08lx\"", (unsigned long)(uint32_t)kr);
}

static void field_id(const char *name, uint64_t id) {
    pj_field(&W, name);
    pj_fmt(&W, "\"0x%llx\"", (unsigned long long)id);
}

static void field_class(const char *name, io_registry_entry_t e) {
    CFStringRef cls = IOObjectCopyClass(e);
    pj_field(&W, name);
    if (cls) {
        pj_cfstring(&W, cls);
        CFRelease(cls);
    } else {
        pj_lit(&W, "null");
    }
}

/* The steps after finding the parent device: plugin, interface, request. */
static void request_descriptor(io_service_t device, UInt8 type, UInt16 want) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    field_kr("plugin_kr", kr);
    if (kr != KERN_SUCCESS || !plugin) {
        W.failures++;
        return;
    }
    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    field_kr("query_hr", hr);
    if (hr || !dev) {
        W.failures++;
        return;
    }
    UInt8 buf[USB2_HUB_MAX];
    memset(buf, 0, sizeof buf);
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof req);
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBDevice);
    req.bRequest = kUSBRqGetDescriptor;
    req.wValue = (UInt16)(type << 8);
    req.wLength = want;
    req.pData = buf;
    req.noDataTimeout = REQUEST_TIMEOUT_MS;
    req.completionTimeout = REQUEST_TIMEOUT_MS;
    fflush(stdout); /* a hub that hangs past the timeout loses only this record */
    IOReturn rk = (*dev)->DeviceRequestTO(dev, &req);
    field_kr("request_kr", rk);
    pj_bytes_field(&W, "bytes", buf, req.wLenDone > want ? want : req.wLenDone);
    if (rk != kIOReturnSuccess || req.wLenDone == 0) W.failures++;
    (*dev)->Release(dev);
}

static void write_hub(io_service_t hub, UInt8 type, UInt16 want) {
    /* Both entry IDs are read before the record opens: a lookup that fails is
       a failure record (pj_entry_id), never a null ID. Without the hub's there
       is no record; without the parent's the record stops after parent_kr. */
    uint64_t id = 0, device_id = 0;
    if (!pj_entry_id(&W, hub, &id)) return;
    io_registry_entry_t parent = 0;
    kern_return_t kr = IORegistryEntryGetParentEntry(hub, kIOServicePlane, &parent);
    int have_device = kr == KERN_SUCCESS && parent && pj_entry_id(&W, parent, &device_id);
    if (pj_record_begin(&W, "hub_descriptor")) {
        field_id("id", id);
        field_class("class", hub);
        pj_field(&W, "descriptor_type");
        pj_fmt(&W, "\"%02x\"", type);
        field_kr("parent_kr", kr);
        if (kr != KERN_SUCCESS || !parent) {
            W.failures++;
        } else if (have_device) {
            field_id("device_id", device_id);
            field_class("device_class", parent);
            if (IOObjectConformsTo(parent, "IOUSBHostDevice")) {
                request_descriptor(parent, type, want);
            } else {
                W.failures++; /* nothing to ask: the parent is not a USB device */
            }
        }
        pj_record_end(&W);
    }
    if (parent) IOObjectRelease(parent);
}

int main(void) {
    pj_init(&W, stdout, BYTE_CAP);
    /* The Mac's own identifiers are withheld here too; a lookup that failed
       means a header, a stopped footer and nothing else (FORMAT.md). */
    if (!pj_privacy_begin(&W, &g_ids, PROBE_NAME)) return 0;
    static const struct { const char *cls; UInt8 type; UInt16 want; } kHubs[] = {
        {"AppleUSB20Hub", USB2_HUB_DESCRIPTOR, USB2_HUB_MAX},
        {"AppleUSB30Hub", USB3_HUB_DESCRIPTOR, USB3_HUB_MAX},
    };
    for (size_t c = 0; c < sizeof kHubs / sizeof kHubs[0] && !W.capped; c++) {
        io_iterator_t it = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kHubs[c].cls), &it);
        if (kr != KERN_SUCCESS) {
            W.failures++;
            if (pj_record_begin(&W, "failure")) {
                pj_field(&W, "what");
                pj_text(&W, "matching");
                pj_field(&W, "class");
                pj_text(&W, kHubs[c].cls);
                field_kr("kr", kr);
                pj_record_end(&W);
            }
            continue;
        }
        io_service_t hub;
        int saw_any = 0;
        while (!W.capped && (hub = IOIteratorNext(it))) {
            saw_any = 1;
            write_hub(hub, kHubs[c].type, kHubs[c].want);
            IOObjectRelease(hub);
        }
        /* An iterator over a class with no services also reports invalid
           (measured on the mini, 2026-10-07), so only one that returned
           something is checked. */
        if (saw_any && !W.capped && !IOIteratorIsValid(it) && pj_record_begin(&W, "failure")) {
            W.failures++;
            pj_field(&W, "what");
            pj_text(&W, "iterator_invalidated");
            pj_field(&W, "class");
            pj_text(&W, kHubs[c].cls);
            pj_record_end(&W);
        }
        IOObjectRelease(it);
    }
    pj_footer(&W, W.capped ? "byte_cap" : NULL);
    return 0;
}
