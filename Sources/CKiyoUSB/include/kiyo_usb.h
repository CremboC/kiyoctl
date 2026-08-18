/*
 * kiyo_usb.h — IOKit transport for the Razer Kiyo Pro vendor extension unit.
 *
 * This is the whole of the platform-specific layer. Everything above it
 * (payloads, sequencing, throttling, CLI) is plain Swift in KiyoKit.
 *
 * The protocol constants this transport carries were reverse-engineered by the
 * cameractrls project (MIT). See LICENSE and README.md.
 */

#ifndef KIYO_USB_H
#define KIYO_USB_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KIYO_VENDOR_ID   0x1532
#define KIYO_PRODUCT_ID  0x0E05

/* The Kiyo Pro extension unit uses exactly eight-byte payloads. */
#define KIYO_MAX_PAYLOAD 8

/*
 * Status codes. 0 is success. Values 1..99 are this shim's own errors. Any
 * other value is a raw IOReturn passed through from IOKit unmodified, so the
 * caller can report e.g. 0xe00002c5 (kIOReturnExclusiveAccess) verbatim.
 */
typedef enum {
    KIYO_OK               = 0,
    KIYO_ERR_BAD_ARG      = 1,
    KIYO_ERR_NOT_FOUND    = 2,  /* no 1532:0e05 on the bus (or no such locationID) */
    KIYO_ERR_NO_XU        = 3,  /* device found, but the Razer XU GUID is not in its descriptors */
    KIYO_ERR_DESCRIPTOR   = 4,  /* configuration descriptor missing or implausible */
    KIYO_ERR_PLUGIN       = 5,  /* IOCFPlugIn / QueryInterface failed */
    KIYO_ERR_NO_MEM       = 6,
    KIYO_ERR_SHORT_XFER   = 7,  /* device ACKed but returned fewer bytes than asked */
    KIYO_ERR_TOO_LONG     = 8,  /* payload exceeds KIYO_MAX_PAYLOAD */
    KIYO_ERR_NO_ZOOM      = 9,  /* Camera Terminal does not advertise Zoom Absolute */
} kiyo_status;

typedef struct {
    uint32_t location_id;   /* stable-ish per physical port; use to disambiguate */
    uint16_t bcd_device;    /* bcdDevice — firmware revision */
    uint8_t  unit_id;       /* DISCOVERED bUnitID of the Razer extension unit */
    uint8_t  vc_interface;  /* DISCOVERED VideoControl bInterfaceNumber */
    bool     xu_found;      /* false => unit_id/vc_interface are meaningless */
    bool     xu_via_fallback; /* true => found by raw GUID scan, not a clean descriptor walk */
    bool     camera_terminal_found;
    bool     zoom_absolute_supported;
    uint8_t  camera_terminal_id;
    uint16_t objective_focal_length_min;
    uint16_t objective_focal_length_max;
    uint16_t ocular_focal_length;
    char     product[128];
    char     serial[128];
} kiyo_device_info;

typedef struct kiyo_handle kiyo_handle;

/*
 * Enumerate every 1532:0e05 on the bus, parsing each one's configuration
 * descriptor for the extension unit. Does NOT open the devices, so this is
 * safe to run at any time and cannot disturb a live video stream.
 *
 * Writes at most max_out entries and sets *out_count to the number written.
 * Returns KIYO_OK even when zero devices matched (*out_count == 0).
 */
int32_t kiyo_enumerate(kiyo_device_info *out, int32_t max_out, int32_t *out_count);

/*
 * Open the device at location_id, or the first match when location_id == 0.
 *
 * Opens the DEVICE, not the VideoControl interface: the system UVC driver holds
 * the interfaces, so USBInterfaceOpen would fail. Device-level requests travel
 * the default control pipe. Callers should still close applications using the
 * camera before writing because this device's firmware is unusually fragile.
 *
 * Uses USBDeviceOpen only. It deliberately does not seize a device held by
 * another client, because doing so can interrupt an active video session.
 */
int32_t kiyo_open(uint32_t location_id, kiyo_handle **out_handle);

/* Closes the device and releases every IOKit object. Safe on NULL. */
void kiyo_close(kiyo_handle *h);

uint8_t  kiyo_unit_id(const kiyo_handle *h);
uint8_t  kiyo_vc_interface(const kiyo_handle *h);
uint32_t kiyo_location_id(const kiyo_handle *h);
uint16_t kiyo_bcd_device(const kiyo_handle *h);

/*
 * UVC GET_LEN (bRequest 0x85) on the extension unit — asks the firmware how
 * long the control's payload is. Cheap insurance against firmware drift; the
 * answer should be 8.
 */
int32_t kiyo_get_len(kiyo_handle *h, uint8_t selector, uint16_t *out_len);

/*
 * UVC SET_CUR (bRequest 0x01) on the extension unit. This is the one that does
 * all the work.
 *
 *   bmRequestType 0x21  (host->device, class, recipient = interface)
 *   wValue        selector << 8
 *   wIndex        (bUnitID << 8) | bVideoControlInterfaceNumber
 */
int32_t kiyo_set_cur(kiyo_handle *h, uint8_t selector, const uint8_t *data, uint16_t len);

/*
 * UVC GET_CUR (bRequest 0x81). Known not to work on the firmware the
 * cameractrls authors tested — exposed only so the failure can be characterised
 * on newer firmware. Treat any error as normal, not as a bug.
 */
int32_t kiyo_get_cur(kiyo_handle *h, uint8_t selector, uint8_t *data, uint16_t len,
                     uint16_t *out_done);

/* Constrained read-only access to CT_ZOOM_ABSOLUTE_CONTROL. `request` must be
 * GET_CUR (0x81), GET_MIN (0x82), GET_MAX (0x83), GET_RES (0x84), GET_INFO
 * (0x86), or GET_DEF (0x87). The first five value requests return a 2-byte
 * little-endian value; GET_INFO returns its one-byte bitmap in out_value. */
int32_t kiyo_zoom_get(kiyo_handle *h, uint8_t request, uint16_t *out_value);

/* Constrained SET_CUR for CT_ZOOM_ABSOLUTE_CONTROL. Range validation is done
 * against the values returned by kiyo_zoom_get before this function is called. */
int32_t kiyo_zoom_set(kiyo_handle *h, uint16_t value);

/* Human-readable name for a status code, or NULL if the code is unrecognised
   (in which case the caller should print it as hex). */
const char *kiyo_status_string(int32_t code);

#ifdef __cplusplus
}
#endif

#endif /* KIYO_USB_H */
