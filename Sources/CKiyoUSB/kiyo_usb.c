#include "kiyo_usb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <IOKit/usb/USBSpec.h>

#include <stdlib.h>   /* calloc, free */
#include <string.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/*
 * Razer XU GUID 23e49ed0-1178-4f31-ae52-d2fb8a8d3b48 in descriptor byte order.
 * The first three GUID fields are little-endian on the wire (USB/GUID
 * convention), which is why this does not read like the canonical string.
 */
static const uint8_t kKiyoXUGuid[16] = {
    0xd0, 0x9e, 0xe4, 0x23, 0x78, 0x11, 0x31, 0x4f,
    0xae, 0x52, 0xd2, 0xfb, 0x8a, 0x8d, 0x3b, 0x48
};

/* USB / UVC descriptor and request constants. */
#define USB_DT_INTERFACE       0x04
#define UVC_DT_CS_INTERFACE    0x24
#define UVC_VC_INPUT_TERMINAL  0x02
#define UVC_VC_EXTENSION_UNIT  0x06
#define USB_CLASS_VIDEO        0x0E
#define USB_SUBCLASS_VIDEOCTL  0x01
#define UVC_ITT_CAMERA          0x0201

#define UVC_SET_CUR            0x01
#define UVC_GET_CUR            0x81
#define UVC_GET_MIN            0x82
#define UVC_GET_MAX            0x83
#define UVC_GET_RES            0x84
#define UVC_GET_LEN            0x85
#define UVC_GET_INFO           0x86
#define UVC_GET_DEF            0x87
#define UVC_CT_ZOOM_ABSOLUTE   0x0B

/* Extension-unit descriptor layout:
 *   0 bLength | 1 bDescriptorType | 2 bDescriptorSubType | 3 bUnitID
 *   4..19 guidExtensionCode | ...
 * so the GUID sits at +4 and bUnitID is the byte immediately before it. */
#define XU_GUID_OFFSET         4
#define XU_MIN_LENGTH          (XU_GUID_OFFSET + 16)
#define CAMERA_TERMINAL_BASE_LENGTH 15
#define CAMERA_ZOOM_ABSOLUTE_BIT 9

#define KIYO_XFER_TIMEOUT_MS   1000

/* Largest configuration descriptor we will believe. A UVC camera's is a few
 * hundred bytes; anything past this means we are reading garbage. */
#define KIYO_MAX_CONFIG_DESC   4096

struct kiyo_handle {
    IOUSBDeviceInterface182 **dev;
    uint32_t location_id;
    uint16_t bcd_device;
    uint8_t  unit_id;
    uint8_t  vc_interface;
    uint8_t  camera_terminal_id;
    bool     zoom_absolute_supported;
    bool     opened;
};

/* ---------------------------------------------------------------------------
 * Registry property helpers
 * ------------------------------------------------------------------------- */

static void copy_string_property(io_service_t svc, const char *key, char *dst, size_t dst_len)
{
    if (dst_len == 0) { return; }
    dst[0] = '\0';

    CFStringRef cf_key = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (cf_key == NULL) { return; }

    CFTypeRef value = IORegistryEntryCreateCFProperty(svc, cf_key, kCFAllocatorDefault, 0);
    CFRelease(cf_key);
    if (value == NULL) { return; }

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        if (!CFStringGetCString((CFStringRef)value, dst, (CFIndex)dst_len, kCFStringEncodingUTF8)) {
            dst[0] = '\0';  /* on failure the buffer contents are unspecified */
        }
    }
    dst[dst_len - 1] = '\0';  /* Swift decodes these as C strings; never leave them open-ended */
    CFRelease(value);
}

static bool copy_number_property(io_service_t svc, const char *key, uint32_t *out)
{
    CFStringRef cf_key = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (cf_key == NULL) { return false; }

    CFTypeRef value = IORegistryEntryCreateCFProperty(svc, cf_key, kCFAllocatorDefault, 0);
    CFRelease(cf_key);
    if (value == NULL) { return false; }

    bool ok = false;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        SInt64 raw = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &raw)) {
            *out = (uint32_t)raw;
            ok = true;
        }
    }
    CFRelease(value);
    return ok;
}

/* ---------------------------------------------------------------------------
 * Descriptor parsing
 * ------------------------------------------------------------------------- */

/*
 * Preferred path: walk the configuration descriptor properly, tracking which
 * VideoControl interface we are inside, and match the extension unit by GUID.
 */
static bool walk_for_xu(const uint8_t *desc, uint16_t total,
                        uint8_t *out_unit_id, uint8_t *out_vc_iface)
{
    uint8_t current_vc = 0;
    bool have_vc = false;
    uint16_t offset = 0;

    while (offset + 2 <= total) {
        uint8_t length = desc[offset];
        uint8_t type = desc[offset + 1];

        /* A zero/short bLength would loop forever, and a descriptor running
         * past wTotalLength means the blob is malformed. Bail to the fallback. */
        if (length < 2 || (uint32_t)offset + length > total) { return false; }

        if (type == USB_DT_INTERFACE && length >= 9) {
            have_vc = desc[offset + 5] == USB_CLASS_VIDEO &&
                      desc[offset + 6] == USB_SUBCLASS_VIDEOCTL;
            if (have_vc) {
                current_vc = desc[offset + 2];  /* bInterfaceNumber */
            }
        } else if (type == UVC_DT_CS_INTERFACE && length >= XU_MIN_LENGTH &&
                   desc[offset + 2] == UVC_VC_EXTENSION_UNIT) {
            if (memcmp(desc + offset + XU_GUID_OFFSET, kKiyoXUGuid, 16) == 0) {
                *out_unit_id = desc[offset + 3];
                *out_vc_iface = have_vc ? current_vc : 0;
                return true;
            }
        }

        offset = (uint16_t)(offset + length);
    }

    return false;
}

static uint16_t read_le16(const uint8_t *bytes)
{
    return (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8));
}

/* Camera Terminal metadata is standard UVC and lives in the cached
 * configuration descriptor, so discovering it does not open the device or
 * issue any control transfer. Zoom (Absolute) is bit D9 of bmControls. */
static void describe_camera_terminal(const uint8_t *desc, uint16_t total,
                                     kiyo_device_info *info)
{
    uint16_t offset = 0;

    while (offset + 2 <= total) {
        uint8_t length = desc[offset];
        uint8_t type = desc[offset + 1];
        if (length < 2 || (uint32_t)offset + length > total) { return; }

        if (type == UVC_DT_CS_INTERFACE &&
            length >= CAMERA_TERMINAL_BASE_LENGTH &&
            desc[offset + 2] == UVC_VC_INPUT_TERMINAL &&
            read_le16(desc + offset + 4) == UVC_ITT_CAMERA) {
            uint8_t control_size = desc[offset + 14];
            if ((uint16_t)CAMERA_TERMINAL_BASE_LENGTH + control_size > length) { return; }

            info->camera_terminal_found = true;
            info->camera_terminal_id = desc[offset + 3];
            info->objective_focal_length_min = read_le16(desc + offset + 8);
            info->objective_focal_length_max = read_le16(desc + offset + 10);
            info->ocular_focal_length = read_le16(desc + offset + 12);

            uint8_t byte_index = CAMERA_ZOOM_ABSOLUTE_BIT / 8;
            uint8_t bit_index = CAMERA_ZOOM_ABSOLUTE_BIT % 8;
            info->zoom_absolute_supported =
                control_size > byte_index &&
                (desc[offset + CAMERA_TERMINAL_BASE_LENGTH + byte_index] &
                 (uint8_t)(1u << bit_index)) != 0;
            return;
        }

        offset = (uint16_t)(offset + length);
    }
}

/*
 * Fallback: raw scan for the GUID, exactly as the Linux tool does. Used when
 * the structured walk trips over a malformed bLength. Still validates the
 * three bytes preceding the GUID so a coincidental byte match cannot pass.
 */
static bool scan_for_xu(const uint8_t *desc, uint16_t total,
                        uint8_t *out_unit_id, uint8_t *out_vc_iface)
{
    if (total < XU_MIN_LENGTH) { return false; }

    for (uint16_t i = XU_GUID_OFFSET; i + 16 <= total; i++) {
        if (memcmp(desc + i, kKiyoXUGuid, 16) != 0) { continue; }
        if (desc[i - 3] != UVC_DT_CS_INTERFACE) { continue; }
        if (desc[i - 2] != UVC_VC_EXTENSION_UNIT) { continue; }

        *out_unit_id = desc[i - 1];

        /* Best effort on the interface number: the last plausible VideoControl
         * interface descriptor appearing before the GUID. Defaults to 0, which
         * is what the Kiyo Pro actually uses. */
        *out_vc_iface = 0;
        for (uint16_t j = 0; j + 9 <= i; j++) {
            if (desc[j] == 9 && desc[j + 1] == USB_DT_INTERFACE &&
                desc[j + 5] == USB_CLASS_VIDEO && desc[j + 6] == USB_SUBCLASS_VIDEOCTL) {
                *out_vc_iface = desc[j + 2];
            }
        }
        return true;
    }

    return false;
}

/* ---------------------------------------------------------------------------
 * Device interface plumbing
 * ------------------------------------------------------------------------- */

static int32_t create_device_interface(io_service_t svc, IOUSBDeviceInterface182 ***out)
{
    *out = NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS) { return (int32_t)kr; }
    if (plugin == NULL) { return KIYO_ERR_PLUGIN; }

    /*
     * Newest interface revision first, degrading gracefully. Every revision
     * from 182 up repeats its predecessor's fields in the same order, so a
     * newer interface can be used through the 182 struct. Revision 182 is the
     * oldest one here that provides DeviceRequestTO, which we use for bounded
     * synchronous control transfers.
     */
    CFUUIDRef candidates[] = {
        kIOUSBDeviceInterfaceID942, kIOUSBDeviceInterfaceID650,
        kIOUSBDeviceInterfaceID500, kIOUSBDeviceInterfaceID400,
        kIOUSBDeviceInterfaceID320, kIOUSBDeviceInterfaceID300,
        kIOUSBDeviceInterfaceID245, kIOUSBDeviceInterfaceID197,
        kIOUSBDeviceInterfaceID187, kIOUSBDeviceInterfaceID182,
    };
    const size_t candidate_count = sizeof(candidates) / sizeof(candidates[0]);

    void *iface = NULL;
    for (size_t i = 0; i < candidate_count; i++) {
        HRESULT hr = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(candidates[i]), &iface);
        if (hr == S_OK && iface != NULL) { break; }
        iface = NULL;
    }

    /* The device interface holds its own reference to the underlying service,
     * so the plugin wrapper is done with. */
    (*plugin)->Release(plugin);

    if (iface == NULL) { return KIYO_ERR_PLUGIN; }
    *out = (IOUSBDeviceInterface182 **)iface;
    return KIYO_OK;
}

/*
 * Fills in the discovered unit ID and VideoControl interface number. Reading
 * the cached configuration descriptor does not require the device to be open.
 */
static int32_t describe_device(IOUSBDeviceInterface182 **dev, kiyo_device_info *info)
{
    IOUSBConfigurationDescriptorPtr config = NULL;
    IOReturn r = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &config);
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    if (config == NULL) { return KIYO_ERR_DESCRIPTOR; }

    uint16_t total = USBToHostWord(config->wTotalLength);
    if (total < XU_MIN_LENGTH || total > KIYO_MAX_CONFIG_DESC) {
        return KIYO_ERR_DESCRIPTOR;
    }

    const uint8_t *bytes = (const uint8_t *)config;
    uint8_t unit_id = 0;
    uint8_t vc_iface = 0;

    describe_camera_terminal(bytes, total, info);

    if (walk_for_xu(bytes, total, &unit_id, &vc_iface)) {
        info->unit_id = unit_id;
        info->vc_interface = vc_iface;
        info->xu_found = true;
        info->xu_via_fallback = false;
        return KIYO_OK;
    }

    if (scan_for_xu(bytes, total, &unit_id, &vc_iface)) {
        info->unit_id = unit_id;
        info->vc_interface = vc_iface;
        info->xu_found = true;
        info->xu_via_fallback = true;
        return KIYO_OK;
    }

    info->xu_found = false;
    return KIYO_OK;  /* device is fine, it just has no Razer XU */
}

static CFMutableDictionaryRef kiyo_matching_dictionary(void)
{
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (match == NULL) { return NULL; }

    int32_t vendor = KIYO_VENDOR_ID;
    int32_t product = KIYO_PRODUCT_ID;
    CFNumberRef cf_vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor);
    CFNumberRef cf_product = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product);

    if (cf_vendor == NULL || cf_product == NULL) {
        if (cf_vendor != NULL) { CFRelease(cf_vendor); }
        if (cf_product != NULL) { CFRelease(cf_product); }
        CFRelease(match);
        return NULL;
    }

    /* Strict on both IDs: the Kiyo Pro Ultra is a different device with a
     * different (undocumented) protocol and must never be matched here. */
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), cf_vendor);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), cf_product);
    CFRelease(cf_vendor);
    CFRelease(cf_product);
    return match;
}

static void fill_registry_info(io_service_t svc, kiyo_device_info *info)
{
    copy_string_property(svc, kUSBProductString, info->product, sizeof(info->product));
    copy_string_property(svc, kUSBSerialNumberString, info->serial, sizeof(info->serial));

    uint32_t number = 0;
    if (copy_number_property(svc, "locationID", &number)) {
        info->location_id = number;
    }
    if (copy_number_property(svc, kUSBDeviceReleaseNumber, &number)) {
        info->bcd_device = (uint16_t)number;
    }
}

/* ---------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */

int32_t kiyo_enumerate(kiyo_device_info *out, int32_t max_out, int32_t *out_count)
{
    if (out == NULL || out_count == NULL || max_out <= 0) { return KIYO_ERR_BAD_ARG; }
    *out_count = 0;

    CFMutableDictionaryRef match = kiyo_matching_dictionary();
    if (match == NULL) { return KIYO_ERR_NO_MEM; }

    io_iterator_t iter = IO_OBJECT_NULL;
    /* Consumes `match` whether it succeeds or fails. */
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) { return (int32_t)kr; }

    int32_t written = 0;
    io_service_t svc = IO_OBJECT_NULL;
    while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        if (written >= max_out) {
            IOObjectRelease(svc);
            continue;  /* drain the iterator so it is left in a clean state */
        }

        kiyo_device_info *info = &out[written];
        memset(info, 0, sizeof(*info));
        fill_registry_info(svc, info);

        IOUSBDeviceInterface182 **dev = NULL;
        int32_t status = create_device_interface(svc, &dev);
        if (status != KIYO_OK) {
            IOObjectRelease(svc);
            IOObjectRelease(iter);
            return status;
        }

        status = describe_device(dev, info);
        (*dev)->Release(dev);
        if (status != KIYO_OK) {
            IOObjectRelease(svc);
            IOObjectRelease(iter);
            return status;
        }

        IOObjectRelease(svc);
        written++;
    }
    IOObjectRelease(iter);

    *out_count = written;
    return KIYO_OK;
}

int32_t kiyo_open(uint32_t location_id, kiyo_handle **out_handle)
{
    if (out_handle == NULL) { return KIYO_ERR_BAD_ARG; }
    *out_handle = NULL;

    CFMutableDictionaryRef match = kiyo_matching_dictionary();
    if (match == NULL) { return KIYO_ERR_NO_MEM; }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) { return (int32_t)kr; }

    io_service_t svc = IO_OBJECT_NULL;
    io_service_t chosen = IO_OBJECT_NULL;
    kiyo_device_info info;
    memset(&info, 0, sizeof(info));

    while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        if (chosen != IO_OBJECT_NULL) {
            IOObjectRelease(svc);
            continue;
        }

        kiyo_device_info candidate;
        memset(&candidate, 0, sizeof(candidate));
        fill_registry_info(svc, &candidate);

        if (location_id != 0 && candidate.location_id != location_id) {
            IOObjectRelease(svc);
            continue;
        }

        chosen = svc;  /* ownership transferred; released below */
        info = candidate;
    }
    IOObjectRelease(iter);

    if (chosen == IO_OBJECT_NULL) { return KIYO_ERR_NOT_FOUND; }

    IOUSBDeviceInterface182 **dev = NULL;
    int32_t status = create_device_interface(chosen, &dev);
    IOObjectRelease(chosen);
    if (status != KIYO_OK) { return status; }

    status = describe_device(dev, &info);
    if (status != KIYO_OK) {
        (*dev)->Release(dev);
        return status;
    }
    if (!info.xu_found) {
        (*dev)->Release(dev);
        return KIYO_ERR_NO_XU;
    }

    /* Device-level open. Never seize a camera held by another client: Apple's
     * seize operation requests exclusive access and may force that client to
     * close, disrupting an active video session. */
    IOReturn r = (*dev)->USBDeviceOpen(dev);
    if (r != kIOReturnSuccess) {
        (*dev)->Release(dev);
        return (int32_t)r;
    }

    kiyo_handle *h = (kiyo_handle *)calloc(1, sizeof(kiyo_handle));
    if (h == NULL) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return KIYO_ERR_NO_MEM;
    }

    h->dev = dev;
    h->location_id = info.location_id;
    h->bcd_device = info.bcd_device;
    h->unit_id = info.unit_id;
    h->vc_interface = info.vc_interface;
    h->camera_terminal_id = info.camera_terminal_id;
    h->zoom_absolute_supported = info.zoom_absolute_supported;
    h->opened = true;

    *out_handle = h;
    return KIYO_OK;
}

void kiyo_close(kiyo_handle *h)
{
    if (h == NULL) { return; }
    if (h->dev != NULL) {
        if (h->opened) { (*h->dev)->USBDeviceClose(h->dev); }
        (*h->dev)->Release(h->dev);
    }
    free(h);
}

uint8_t  kiyo_unit_id(const kiyo_handle *h)      { return h != NULL ? h->unit_id : 0; }
uint8_t  kiyo_vc_interface(const kiyo_handle *h) { return h != NULL ? h->vc_interface : 0; }
uint32_t kiyo_location_id(const kiyo_handle *h)  { return h != NULL ? h->location_id : 0; }
uint16_t kiyo_bcd_device(const kiyo_handle *h)   { return h != NULL ? h->bcd_device : 0; }

/* wIndex addresses the unit within the VideoControl interface. The recipient
 * stays "interface" even though the request goes out through the device
 * handle. */
static uint16_t kiyo_windex(const kiyo_handle *h)
{
    return (uint16_t)(((uint16_t)h->unit_id << 8) | h->vc_interface);
}

static uint16_t kiyo_entity_windex(const kiyo_handle *h, uint8_t entity_id)
{
    return (uint16_t)(((uint16_t)entity_id << 8) | h->vc_interface);
}

static void kiyo_prepare_request(IOUSBDevRequestTO *req, const kiyo_handle *h,
                                 uint8_t direction, uint8_t request,
                                 uint8_t selector, void *data, uint16_t len)
{
    memset(req, 0, sizeof(*req));
    req->bmRequestType = USBmakebmRequestType(direction, kUSBClass, kUSBInterface);
    req->bRequest = request;
    req->wValue = (uint16_t)((uint16_t)selector << 8);
    req->wIndex = kiyo_windex(h);
    req->wLength = len;
    req->pData = data;
    req->noDataTimeout = KIYO_XFER_TIMEOUT_MS;
    req->completionTimeout = KIYO_XFER_TIMEOUT_MS;
}

static void kiyo_prepare_entity_request(IOUSBDevRequestTO *req, const kiyo_handle *h,
                                        uint8_t entity_id, uint8_t direction,
                                        uint8_t request, uint8_t selector,
                                        void *data, uint16_t len)
{
    kiyo_prepare_request(req, h, direction, request, selector, data, len);
    req->wIndex = kiyo_entity_windex(h, entity_id);
}

int32_t kiyo_get_len(kiyo_handle *h, uint8_t selector, uint16_t *out_len)
{
    if (h == NULL || h->dev == NULL || out_len == NULL) { return KIYO_ERR_BAD_ARG; }

    uint8_t buffer[2] = { 0, 0 };
    IOUSBDevRequestTO req;
    kiyo_prepare_request(&req, h, kUSBIn, UVC_GET_LEN, selector, buffer, sizeof(buffer));

    IOReturn r = (*h->dev)->DeviceRequestTO(h->dev, &req);
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    if (req.wLenDone < 2) { return KIYO_ERR_SHORT_XFER; }

    *out_len = (uint16_t)(buffer[0] | ((uint16_t)buffer[1] << 8));
    return KIYO_OK;
}

int32_t kiyo_set_cur(kiyo_handle *h, uint8_t selector, const uint8_t *data, uint16_t len)
{
    if (h == NULL || h->dev == NULL || data == NULL || len != KIYO_MAX_PAYLOAD) {
        return KIYO_ERR_BAD_ARG;
    }

    /* IOUSBDevRequestTO.pData is non-const, so the payload is copied. */
    uint8_t buffer[KIYO_MAX_PAYLOAD];
    memcpy(buffer, data, len);

    IOUSBDevRequestTO req;
    kiyo_prepare_request(&req, h, kUSBOut, UVC_SET_CUR, selector, buffer, len);

    IOReturn r = (*h->dev)->DeviceRequestTO(h->dev, &req);
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    if (req.wLenDone < len) { return KIYO_ERR_SHORT_XFER; }
    return KIYO_OK;
}

int32_t kiyo_get_cur(kiyo_handle *h, uint8_t selector, uint8_t *data, uint16_t len,
                     uint16_t *out_done)
{
    if (h == NULL || h->dev == NULL || data == NULL || len == 0) { return KIYO_ERR_BAD_ARG; }
    if (len > KIYO_MAX_PAYLOAD) { return KIYO_ERR_TOO_LONG; }

    memset(data, 0, len);

    IOUSBDevRequestTO req;
    kiyo_prepare_request(&req, h, kUSBIn, UVC_GET_CUR, selector, data, len);

    IOReturn r = (*h->dev)->DeviceRequestTO(h->dev, &req);
    if (out_done != NULL) { *out_done = (uint16_t)req.wLenDone; }
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    return KIYO_OK;
}

int32_t kiyo_zoom_get(kiyo_handle *h, uint8_t request, uint16_t *out_value)
{
    if (h == NULL || h->dev == NULL || out_value == NULL) { return KIYO_ERR_BAD_ARG; }
    if (!h->zoom_absolute_supported || h->camera_terminal_id == 0) {
        return KIYO_ERR_NO_ZOOM;
    }

    switch (request) {
    case UVC_GET_CUR:
    case UVC_GET_MIN:
    case UVC_GET_MAX:
    case UVC_GET_RES:
    case UVC_GET_INFO:
    case UVC_GET_DEF:
        break;
    default:
        return KIYO_ERR_BAD_ARG;
    }

    uint8_t buffer[2] = { 0, 0 };
    uint16_t length = request == UVC_GET_INFO ? 1 : 2;
    IOUSBDevRequestTO req;
    kiyo_prepare_entity_request(&req, h, h->camera_terminal_id, kUSBIn,
                                request, UVC_CT_ZOOM_ABSOLUTE, buffer, length);

    IOReturn r = (*h->dev)->DeviceRequestTO(h->dev, &req);
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    if (req.wLenDone < length) { return KIYO_ERR_SHORT_XFER; }

    *out_value = request == UVC_GET_INFO
        ? buffer[0]
        : read_le16(buffer);
    return KIYO_OK;
}

int32_t kiyo_zoom_set(kiyo_handle *h, uint16_t value)
{
    if (h == NULL || h->dev == NULL) { return KIYO_ERR_BAD_ARG; }
    if (!h->zoom_absolute_supported || h->camera_terminal_id == 0) {
        return KIYO_ERR_NO_ZOOM;
    }

    uint8_t buffer[2] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
    };
    IOUSBDevRequestTO req;
    kiyo_prepare_entity_request(&req, h, h->camera_terminal_id, kUSBOut,
                                UVC_SET_CUR, UVC_CT_ZOOM_ABSOLUTE,
                                buffer, sizeof(buffer));

    IOReturn r = (*h->dev)->DeviceRequestTO(h->dev, &req);
    if (r != kIOReturnSuccess) { return (int32_t)r; }
    if (req.wLenDone < sizeof(buffer)) { return KIYO_ERR_SHORT_XFER; }
    return KIYO_OK;
}

const char *kiyo_status_string(int32_t code)
{
    switch (code) {
    case KIYO_OK:             return "success";
    case KIYO_ERR_BAD_ARG:    return "invalid argument";
    case KIYO_ERR_NOT_FOUND:  return "no Razer Kiyo Pro (1532:0e05) found";
    case KIYO_ERR_NO_XU:      return "device found but the Razer extension unit is not in its descriptors";
    case KIYO_ERR_DESCRIPTOR: return "configuration descriptor missing or implausible";
    case KIYO_ERR_PLUGIN:     return "could not create an IOUSBDeviceInterface for the device";
    case KIYO_ERR_NO_MEM:     return "out of memory";
    case KIYO_ERR_SHORT_XFER: return "device accepted the request but transferred too few bytes";
    case KIYO_ERR_TOO_LONG:   return "payload longer than the transport allows";
    case KIYO_ERR_NO_ZOOM:    return "Camera Terminal does not advertise Zoom Absolute";
    default: break;
    }

    /* Raw IOReturn passthrough — the ones actually worth naming here. */
    switch ((IOReturn)code) {
    case kIOReturnExclusiveAccess: return "device is in use by another client; close camera applications and retry";
    case kIOReturnNotPermitted:    return "not permitted (missing USB entitlement, or blocked by policy)";
    case kIOReturnNoDevice:        return "device went away";
    case kIOReturnNotOpen:         return "device is not open";
    case kIOReturnNotResponding:   return "device is not responding";
    case kIOReturnTimeout:         return "control transfer timed out";
    case kIOReturnAborted:         return "control transfer aborted";
    case kIOReturnBadArgument:     return "IOKit rejected the request parameters";
    case kIOReturnUnsupported:     return "unsupported operation";
    case kIOReturnNoResources:     return "out of IOKit resources";
    case kIOUSBPipeStalled:        return "endpoint stalled (firmware rejected the request, or is wedged)";
    case kIOUSBTransactionTimeout: return "USB transaction timed out";
    default: return NULL;
    }
}
