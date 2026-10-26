# Test-kit probe output, format 1

The contract between the probes numbered 50 and up and everything that reads them (the worker, ingest, the loaders, the index). Written by `probe_json.h`. Spec: the "Probe rebuild" project in Linear.

Probes numbered below 50 print free text in older shapes and are not covered here.

## Lines

- JSON Lines: UTF-8, one JSON object per line, each ending `\n`.
- The first line is the header. The last line is the footer.
- **A file without a footer was cut off** (crash, watchdog kill, runner cap) and is incomplete. Never read it as complete. Its last line can stop mid-record: readers drop that one line and keep the lines before it.

## Header

```json
{"record":"header","format":1,"probe":"50_registry_snapshot","probe_source_sha256":"<64 hex>","app_version":"1.2.3","started_at":"2026-10-07T14:47:24Z"}
```

- `probe_source_sha256`: SHA-256 over the probe's `.c` file followed by `probe_json.h`, stamped by `scripts/smoke-test.sh`. `"unstamped"` when built another way.
- `app_version`: from the `WHATCABLE_APP_VERSION` environment variable the runner sets. `null` when absent.

## Footer

```json
{"record":"footer","status":"complete","reason":null,"step":null,"records":7600,"failures":0,"withheld":942,"bytes_before_footer":9630735,"finished_at":"2026-10-07T14:47:25Z"}
```

- `status`: `complete`, or `stopped` with `reason`: `byte_cap`; `no_root` (50 only); `identifiers_incomplete`, in any probe, when a lookup the privacy rules depend on failed (see Privacy): the footer then follows the header at once and the file holds no records.
- `step`: always present. `null` unless `reason` is `identifiers_incomplete`, then the first identifier lookup that failed, one of the step names listed under Privacy: a fixed name, never anything read from the Mac. It is the only word the file has on why such a run stopped.
- `records`: lines between header and footer.
- `failures`: reads and values written as failures (see below).
- `withheld`: values replaced for privacy.
- A record is written only if it fits under the probe's byte cap, so a capped file is at most the cap plus its footer line. It stops at a record boundary with `status` `stopped` and `reason` `byte_cap`, and `records` counts the records written. Its `failures` and `withheld` can also count values in the record the cap refused.

## Typed values

Every value says what CoreFoundation type it was.

| Shape | Meaning |
|---|---|
| `{"t":"int","bits":32,"hex":"80200000"}` | An integer: the width CF reports (8, 16, 32 or 64) and the raw bits, zero-padded. **No sign.** macOS records only bits and width, so signed or unsigned is the reader's choice per field: `fffffe0c` is -500 as a signed 32-bit value. Every registry integer measured on the mini (2026-10-07) was 32 or 64 bits. |
| `{"t":"float","bits":64,"hex":"3ff0000000000000"}` | IEEE 754 bits of a floating-point number. |
| `{"t":"str","v":"text"}` | A string. |
| `{"t":"str","utf16":"d8000078"}` | A string UTF-8 cannot carry (a lone surrogate): its UTF-16 code units, big-endian. |
| `{"t":"data","len":3,"hex":"00ff10"}` | Bytes, always in full. |
| `{"t":"data","len":4,"hex":"aa0000dd","withheld":[[1,2]]}` | Bytes with some withheld for privacy: each `[offset, length]` range is written as `00` and means nothing. Ranges are in order and never overlap. The other bytes are exact. Counted once in the footer's `withheld`. Data whose every byte would be withheld is written as `{"t":"withheld"}` instead. |
| `{"t":"bool","v":true}` | A boolean. |
| `{"t":"array","v":[...]}` | Members in order. |
| `{"t":"set","v":[...]}` | Members in full. Order is meaningless. |
| `{"t":"dict","v":[[key,value],...]}` | Pairs sorted by key. Order is meaningless. A key is a JSON string, `{"utf16":"..."}`, or a typed value when it is not a CFString. |
| `{"t":"date","bits":64,"hex":"..."}` | A CFDate as the IEEE bits of its absolute time. |
| `{"t":"null"}` | kCFNull. |
| `{"t":"withheld"}` | Withheld for privacy. The key is kept. A dictionary pair whose key itself carried an identifier is `[{"t":"withheld"},{"t":"withheld"}]`. |
| `{"t":"skipped"}` | Not recorded on purpose because it is not hardware (NVRAM boot state and settings). Not counted as withheld. Listed by name in `skipped_summary.properties`. Also the whole `props` of a process connection's `entry` (below). |
| `{"t":"failed","what":"..."}` | A value that could not be read or converted. Counted in the footer. |
| `{"t":"other","cf_type_id":N,"cf_type":"CFURL"}` | A CF type format 1 has no shape for. Counted as a failure. |

Strings outside typed values (names, locations, class names) are JSON strings when valid UTF-8, otherwise `{"hex":"..."}`.

### Raw bytes

The small probes write raw bytes (a descriptor, an SMC value) as a lowercase hex string field: 52's `header` and `bytes`, 53's `bytes`, 55's `bytes`. When some bytes hold one of the Mac's own identifiers, they are written as `00` and a sibling field named after it with `_withheld` lists them as `[offset, length]` ranges, in order and never overlapping, as for partly withheld data:

```json
{"record":"smc_key",...,"bytes":"0000000000000000","bytes_withheld":[[1,7]],"truncated":false}
```

When every byte would be withheld, the field is `{"t":"withheld"}` instead of a string. Either way it counts once in the footer's `withheld`.

## 50_registry_snapshot records

Record types: `entry`, `link`, `class`, `failure`, `withheld_summary`, `skipped_summary`.

Between the header and the footer, in this order: one `entry` per registry entry, interleaved with `link` records as the planes are walked, then one `class` per class, then one `withheld_summary` and one `skipped_summary`, with `failure` records wherever a read failed.

**The snapshot covers hardware, not processes or settings.**

- **A process connection's properties are not recorded.** An entry that is an `IOUserClient` records which app or daemon has a driver open. It keeps its class and its place in the tree: its `entry` has `"props":{"t":"skipped"}` in place of its properties, which are never written, and its `link` records are written like any other entry's. What hangs beneath it is recorded like anything else, because a Bluetooth accessory is a virtual HID device created through a user client (`IOHIDUserDevice`, `IOHIDInterface` and the event services beneath `IOHIDResourceDeviceUserClient`). A walk down from the root through `link` records reaches every entry in the file.
- **`IODTNVRAMDiags`** (NVRAM access statistics) is skipped the same way.
- **NVRAM variables** on the `IODTNVRAM` and `IODTNVRAMVariables` entries keep their names, but only these keep their values: Bluetooth variables (any name containing "bluetooth", any case), `usbc,*` (USB-C firmware versions), `display-crossbar*`, and the driver's own `IO*` keys. Every other variable (boot state, settings, installer data) is `{"t":"skipped"}`. A value that holds one of the Mac's identifiers is still withheld.

```json
{"record":"entry","id":"0x100000123","class":"AppleHPMDeviceHALType3","props":{"t":"dict","v":[...]}}
{"record":"entry","id":"0x1000004f2","class":"RootDomainUserClient","props":{"t":"skipped"}}
{"record":"link","plane":"IOService","id":"0x100000123","parent":"0x100000100","pos":0,"name":"Port-USB-C@1","location":"1","path":"IOService:/AppleARMPE/..."}
{"record":"class","name":"AppleHPMDeviceHALType3","super":["AppleHPMDevice","IOService","IORegistryEntry","OSObject"],"bundle":"com.apple.driver.AppleHPM"}
{"record":"failure","what":"iterator_invalidated","plane":"IOService","id":"0x100000100","kr":"0xe00002eb"}
{"record":"withheld_summary","counts":[["IOPlatformExpertDevice: IOPlatformSerialNumber",1],["IOUserNetworkWLAN: IOMACAddress",4]]}
{"record":"skipped_summary","counts":[["IODTNVRAMDiags",1],["RootDomainUserClient",152]],"ids":["0x1000004f1","0x1000004f2"],"properties":[["IODTNVRAM: boot-volume",1]]}
```

- `id`: the registry entry ID, hex. Unique and stable only within one boot.
- `entry` is written once, the first time the entry is met in any plane. `props` is every property `IORegistryEntryCreateCFProperties` returned, or a `failed` value, or `{"t":"skipped"}` for a process connection (its ID is then in `skipped_summary.ids`).
- `link` is written once per (entry, parent) in each plane. The root's link has `parent` null. An entry's children in a plane are the links naming it as `parent`, in `pos` order. Every `id` and every `parent` has an `entry` record, process connections included.
- `name` and `location` come through IOKit's 128-byte `io_name_t`. `path` comes from `IORegistryEntryCopyPath`, has no length limit, and carries the full names. `location` is null for an entry that has none.
- `class.super` runs from the immediate superclass up to the root class.
- `withheld_summary.counts`: what was withheld, as `[ "Class: key", count ]` pairs sorted by label. Names only, never values. The counts add up to the footer's `withheld`. `[member or key]` stands for an array or set member, or a dictionary key that itself carried an identifier. Read it to see whether a submission withheld more than it should.
- `skipped_summary.counts`: the entries whose properties were not recorded (the process connections and NVRAM statistics themselves, never what hangs beneath them), as `[ class, count ]` pairs sorted by class. `ids`: their entry IDs, ascending. The counts add up to the number of IDs, and every skipped ID has an `entry` record whose `props` is exactly `{"t":"skipped"}`. `properties`: the `{"t":"skipped"}` values inside entries' properties, as `[ "Class: key", count ]` pairs sorted by label, adding up to the number of such markers (a connection's own marker is not one).
- `failure.what`: `child_iterator`, `entry_id`, `name`, `class`, `depth` (the entry sits 256 levels deep in that plane and its children were not walked from there; written after the plane's walk, and not for an entry a shallower path reached), `iterator_invalidated` (the registry changed during the walk, so children of that entry may be missing), `planes`, `plane_name`, `root`.

## 51_driver_access records

Record types: `cfplugin`, `interest_notification`, `user_client_open`, `failure`.

What a user-space process may do with the port and Thunderbolt drivers, which replaces the live tests of probes 21, 03 and 29. Their registry dumps are in `50_registry_snapshot`: join on `id`. Every connection opened is closed at once and no method is called on it.

```json
{"record":"cfplugin","id":"0x100000913","class":"IOThunderboltControllerType7","create_kr":"0xe00002c7","score":0}
{"record":"interest_notification","id":"0x1000174e7","class":"IOPortTransportComponentCCUSBPDSOPp","port_created":true,"general_kr":"0x00000000","busy_kr":"0x00000000"}
{"record":"user_client_open","id":"0x100017467","class":"IOUSBHostInterface","matched":"IOUSBHostInterface","not_tried":null,"open_kr":"0x00000000"}
```

- `cfplugin`: one per `IOThunderboltController`. `create_kr` and `score` from `IOCreatePlugInInterfaceForService`; when it succeeds, `query_hr` and `interface` from a `QueryInterface` on the result.
- `interest_notification`: one per `IOPortTransportComponentCCUSBPDSOPp`. Whether a notification port could be created, then `general_kr` and `busy_kr` from `IOServiceAddInterestNotification`.
- `user_client_open`: one per service of probe 29's classes, once per entry ID. `matched` is the class it was found under. `open_kr` is the `IOServiceOpen` result when it was tried. `not_tried` is null when it was, `storage_or_hid` for a USB service carrying a mass-storage or HID class (never opened: the removable-volume prompt, or seizing an input device), `class_unknown` when the guard could not read the service's or its children's classes (a failed property read, a class key in another shape, a failed child iterator, or the registry changing under it: the service is not opened, and this counts as a failure in the footer), or `interface_limit` past the first 6 `IOUSBHostInterface` services. A refused open is a measured answer, not a failure.
- `failure.what`: `matching` (with `kr`), `iterator_invalidated` (the registry changed while that class was being listed), or `entry_id` (with `class` and `kr`: a service's entry ID could not be read, so it has no record).

## 52_usb_bos records

Record types: `bos`, `failure`.

Each USB device's raw BOS descriptor, which replaces probe 25. One `bos` per service of the classes probe 25 tried (`IOUSBHostDevice` and its subclasses, the USB4 router and hub classes, the Billboard classes), once per entry ID. The device's properties are in `50_registry_snapshot`: join on `id`. Nothing is parsed.

```json
{"record":"bos","id":"0x100017434","class":"IOUSBHostDevice","matched":"IOUSBHostDevice","mass_storage":false,"plugin_kr":"0x00000000","query_hr":"0x00000000","header_kr":"0x00000000","header":"050f2a0003","total_length":42,"bos_kr":"0x00000000","bytes":"050f2a0003..."}
{"record":"failure","what":"iterator_invalidated","class":"IOUSBHostDevice"}
```

- Each step reached adds its fields, in order: `plugin_kr` (`IOCreatePlugInInterfaceForService`), `query_hr` (the device interface), `header_kr` and `header` (the first 5 bytes, as many as came back), `total_length`, then `bos_kr` and `bytes` (the whole descriptor). A step that failed is the last one present and counts as a failure in the footer.
- `mass_storage`: true means the device was not asked at all, to avoid the macOS removable-volume prompt. Not a failure. `null` means the guard could not read the device's or its interfaces' classes (a failed property read, a class key in another shape, a failed child iterator, or the registry changing under it): the device was not asked either, `not_tried` is `class_unknown`, no later fields follow, and this counts as a failure in the footer.
- A `header` whose second byte is not `0f`, or a `total_length` under 5 or over 4096, means the device has no BOS: no full request follows.
- Requests time out after 3 s.
- `failure.what`: `matching` (with `kr`), `iterator_invalidated` (the registry changed while that class was being listed, so services may be missing), or `entry_id` (with `class` and `kr`: a device's entry ID could not be read, so it has no `bos` record).

## 53_smc_keys records

Record types: `smc_open`, `key_count`, `smc_key`.

Every AppleSMC key, which replaces probe 34. In this order: one `smc_open`, one `key_count`, then one `smc_key` per key index from 0 to `count` - 1. Nothing is decoded: readers decode `bytes` by `type`.

```json
{"record":"smc_open","found":true,"kr":"0x00000000"}
{"record":"key_count","info_kr":"0x00000000","info_result":"00","read_kr":"0x00000000","read_result":"00","bytes":"000006c6","count":1734}
{"record":"smc_key","index":0,"index_kr":"0x00000000","index_result":"00","key":"234b4559","info_kr":"0x00000000","info_result":"00","type":"75693332","size":4,"attributes":"80","read_kr":"0x00000000","read_result":"00","bytes":"000006c6","truncated":false}
```

- `*_kr`: the `kern_return_t` of that call, hex. `*_result`: the SMC's own result byte for it, hex. `00` is success. Both must be zero for a value to count.
- `key`, `type`: the FourCC as its 32 raw bits, hex, most significant byte first (`234b4559` is `#KEY`, `75693332` is `ui32`).
- A key whose index call failed has `key` null and no later fields. One whose info call failed stops after `info_result`. One whose read failed or was refused has no `bytes`. Each of these counts as a failure in the footer.
- `bytes`: the raw value, `size` bytes, most significant first as the SMC returns it. The call carries at most 32 bytes; the kernel refuses larger keys (`0xe00002c2`). Raw bytes (see above): key `RECI` holds the chip ID and is written with those bytes withheld.
- If `smc_open.kr` is not zero, or `key_count.count` is null, nothing follows but the footer.

## 54_power_sources records

Record types: `adapter`, `providing_type`, `source`, `failure`.

The power-sources API (IOKit.ps), which replaces probe 39. In this order: one `adapter`, one `providing_type`, then one `source` per power source in list order. A call that returned nothing is a `failure` record instead.

```json
{"record":"adapter","details":{"t":"dict","v":[...]}}
{"record":"providing_type","value":{"t":"str","v":"AC Power"}}
{"record":"source","index":0,"description":{"t":"dict","v":[...]}}
{"record":"failure","what":"power_sources_list"}
```

- `adapter.details`: what `IOPSCopyExternalPowerAdapterDetails` returned, or `null`. Null does not mean "on battery": Apple documents it as "no adapter details or an error", and desktops on AC report it too. Read `providing_type` to tell them apart.
- `providing_type.value`: `IOPSGetProvidingPowerSourceType`: "AC Power", "Battery Power" or "UPS Power", or `null`.
- `source.description`: `IOPSGetPowerSourceDescription` for that source, or a `failed` value.
- `failure.what`: `power_sources_info` (no power-sources blob, so no `providing_type` or `source` records follow) or `power_sources_list`.

## 55_hub_ports records

Record types: `hub_descriptor`, `failure`.

Each USB hub's raw hub descriptor, which replaces probe 40. Probe 40's registry dump (hub and port nodes, `port-statistics`, current budgets) is in `50_registry_snapshot`: join on `id` and `device_id`. One `hub_descriptor` per `AppleUSB20Hub` and `AppleUSB30Hub` service. Nothing is parsed.

```json
{"record":"hub_descriptor","id":"0x100000b8c","class":"AppleUSB20Hub","descriptor_type":"29","parent_kr":"0x00000000","device_id":"0x100000b86","device_class":"IOUSBHostDevice","plugin_kr":"0x00000000","query_hr":"0x00000000","request_kr":"0x00000000","bytes":"092902e9003c6400ff"}
```

- `descriptor_type`: `29` (USB 2 hub, asked for up to 71 bytes) or `2a` (SuperSpeed hub, 12 bytes). The request goes to the hub's service-plane parent, `device_id`, which must be an `IOUSBHostDevice`.
- Each step reached adds its fields: `parent_kr`, `device_id` and `device_class`, `plugin_kr`, `query_hr`, then `request_kr` and `bytes` (as many as the hub returned). A step that failed is the last one present and counts as a failure in the footer.
- Requests time out after 3 s.
- `failure.what`: `matching` (with `kr`), `iterator_invalidated` (the registry changed while that class was being listed, so hubs may be missing), or `entry_id` (with `class` and `kr`): a hub's entry ID could not be read, so it has no `hub_descriptor` record, or its parent device's could not, so the `hub_descriptor` record after the failure stops at `parent_kr`.

## Privacy

See the spec's Privacy section. In short: only personal privacy is protected. A process connection's properties are not recorded at all (see above). What ties the Mac to its owner (serial numbers, platform UUID, chip ID, its own network and Bluetooth addresses) and the home folder path are withheld by key name and by content, in every probe. The user's name is withheld by key name only (`IOConsoleUsers`). A value withheld by key name is withheld whole. A string or integer that holds one of them anywhere is withheld whole. Data that holds one keeps every other byte: only the identifier's bytes are withheld (for example the Mac's own Bluetooth address inside `BluetoothUHEDevices`, next to a paired device's address, which is kept; or the chip ID inside the boot manifest `sfr-manifest-data`). Raw bytes in the small probes follow the same rule (see "Raw bytes").

Each identifier is searched for in every form generated from its value: its bytes and their reverse, with leading or trailing zero bytes stripped; those as hex text in both cases, bare or with `:` or `-` between bytes; up to 8 bytes, its value in decimal either way round; text as published, in upper and lower case for serials and UUIDs; every text form also as UTF-16LE and UTF-16BE; and a UUID in the EFI and SMBIOS byte order. A form shorter than 4 bytes, or more than half one byte value, is not searched for. Each of the Mac's own network and Bluetooth addresses is also matched as a whole 6-byte data value, either way round, so a value that is exactly one is `{"t":"withheld"}`; an address mostly made of one byte value is matched only that way.

Everything else is kept unchanged, including device serials, port and volume UUIDs and every identifier that links information across the registry.

One rewrite, in every probe: a string value of the form `pid N, name` under `UsbExclusiveOwner` or `iAPAuthenticator` (the keys the customer-probe corpus holds such values under, besides `IOUserClientCreator`, which is skipped with its connection) is written as `name` alone: the process holding a USB device is recorded, its process number is not. A value under those keys without that prefix (a driver name) is written as it is; the same text under any other key is not rewritten. Such a value that is not valid UTF-8 is written as `{"t":"failed","what":"process_name"}` and counted as a failure. No output of any probe holds a string starting `pid N, `.

Gathering the identifiers fails closed. Before writing anything, each probe reads them from the registry and the user database, checking every lookup it depends on (the platform expert and its properties, the device tree root and `/chosen` and theirs, a walk of the IOService plane for the Mac's own network and Bluetooth addresses, and the user database). The walk is made again, up to four times with pauses of 10, 50 and 200 ms between, when the registry changed under it (its iterator is no longer valid) or a read in it failed: a read can fail from churn before any iterator says so (a user client closed between the walk reaching it and reading it fails the read while every iterator still says valid, measured). A value read whole but malformed cannot be churn, so it stops the walk at once. Once the attempts run out, the step is the read that failed on the last walk with no sign of churn (the entry still in the plane, a kern_return other than `MACH_SEND_INVALID_DEST`, the iterator still valid); any sign of churn names `registry_changing` instead. `IOPlatformSerialNumber` and `IOPlatformUUID` must be present and strings on every Mac. The device-tree serials, the chip ID keys and `/chosen`'s `mac-address-bluetooth0` may be absent (Intel Macs have none), but one that is present in another shape or length is a failure. The Mac's own Bluetooth address is gathered from every source that publishes it, each on its own: `/chosen` and the device-tree node named `bluetooth` (`local-mac-address`); `IOBluetoothDevice` entries are not a source, because they stand for connected devices too and their addresses are kept. A Mac with an `IOBluetoothHCIController` from which no source gave an address fails closed, and a Mac without one needs none. Intel Macs publish neither source, so on an Intel Mac with Bluetooth every probe stops this way; the apps do not support Intel Macs. If any lookup still fails, the probe cannot tell what to withhold, so it writes only the header and a footer stopped with reason `identifiers_incomplete` and `step` naming the first lookup that failed.

Step names: `platform_expert` (no `IOPlatformExpertDevice`), `platform_props` (its properties could not be read), `platform_serial` (`IOPlatformSerialNumber` absent, not a string, or not UTF-8), `platform_uuid` (`IOPlatformUUID` absent or not a string), `device_tree` (no `IODeviceTree:/`), `device_tree_props` (its properties could not be read, or a serial there in another shape), `chosen` (no `/chosen`), `chosen_props` (its properties could not be read, or a chip ID or Bluetooth key there in another shape or length), `network_iterator` (the IOService walk could not start, on the last attempt), `network_props` (an entry's properties could not be read, on the last walk, with no sign that the registry changed), `network_address` (an `IOMACAddress` that is not 6 bytes of data), `network_builtin` (the built-in check's read failed, on the last walk, with no sign that the registry changed), `bluetooth_node` (an entry carrying `local-mac-address` whose name could not be read with no sign that the registry changed, or the `bluetooth` node's address not 6 bytes of data), `registry_changing` (every walk saw the registry change under it, or a read fail with a sign of it), `bluetooth` (a Bluetooth controller and no address from any source), `passwd` (the user database lookup failed).
