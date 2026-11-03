#include "CRCMLegacy.h"
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

struct CRCMLegacySession {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
    int device_open;
    int interface_open;
};

static int matches(io_service_t service, uint16_t vendor, uint16_t product) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
    CFTypeRef p = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
    int vi = -1, pi = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &vi);
    if (p && CFGetTypeID(p) == CFNumberGetTypeID()) CFNumberGetValue(p, kCFNumberIntType, &pi);
    if (v) CFRelease(v);
    if (p) CFRelease(p);
    return vi == vendor && pi == product;
}

static IOReturn device_interface(io_service_t service, IOUSBDeviceInterface ***out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service,
        kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess) return result;
    if (!plugin) return kIOReturnNoDevice;
    HRESULT query = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)out);
    (*plugin)->Release(plugin);
    return (query == S_OK && *out) ? kIOReturnSuccess : kIOReturnNoDevice;
}

static IOReturn usb_interface(io_service_t service, IOUSBInterfaceInterface ***out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service,
        kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess) return result;
    if (!plugin) return kIOReturnNoDevice;
    HRESULT query = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)out);
    (*plugin)->Release(plugin);
    return (query == S_OK && *out) ? kIOReturnSuccess : kIOReturnNoDevice;
}

void crcm_close(CRCMLegacySession *session) {
    if (!session) return;
    if (session->interface) {
        if (session->interface_open) (*session->interface)->USBInterfaceClose(session->interface);
        (*session->interface)->Release(session->interface);
    }
    if (session->device) {
        if (session->device_open) (*session->device)->USBDeviceClose(session->device);
        (*session->device)->Release(session->device);
    }
    free(session);
}

static IOReturn configure_session(CRCMLegacySession *session, io_service_t service) {
    IOReturn result = device_interface(service, &session->device);
    if (result != kIOReturnSuccess) return result;
    result = (*session->device)->USBDeviceOpen(session->device);
    if (result != kIOReturnSuccess) return result;
    session->device_open = 1;

    IOUSBConfigurationDescriptor *config = NULL;
    result = (*session->device)->GetConfigurationDescriptorPtr(session->device, 0, &config);
    if (result != kIOReturnSuccess || !config) return result == kIOReturnSuccess ? kIOReturnNoDevice : result;
    result = (*session->device)->SetConfiguration(session->device, config->bConfigurationValue);
    if (result != kIOReturnSuccess && result != kIOReturnBusy) return result;

    IOUSBFindInterfaceRequest request = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t iterator = 0;
    result = (*session->device)->CreateInterfaceIterator(session->device, &request, &iterator);
    if (result != kIOReturnSuccess) return result;
    io_service_t interface_service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!interface_service) return kIOReturnNoDevice;
    result = usb_interface(interface_service, &session->interface);
    IOObjectRelease(interface_service);
    if (result != kIOReturnSuccess) return result;
    result = (*session->interface)->USBInterfaceOpen(session->interface);
    if (result != kIOReturnSuccess && result != kIOReturnExclusiveAccess) return result;
    session->interface_open = (result == kIOReturnSuccess);
    return kIOReturnSuccess;
}

CRCMLegacySession *crcm_open(uint16_t vendor, uint16_t product, int32_t *error_code) {
    if (error_code) *error_code = kIOReturnNoDevice;
    const char *classes[] = {"IOUSBDevice", "IOUSBHostDevice"};
    for (int c = 0; c < 2; c++) {
        CFMutableDictionaryRef matching = IOServiceMatching(classes[c]);
        if (!matching) continue;
        io_iterator_t iterator = 0;
        IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
        if (result != kIOReturnSuccess) { if (error_code) *error_code = result; continue; }
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            if (!matches(service, vendor, product)) { IOObjectRelease(service); continue; }
            CRCMLegacySession *session = calloc(1, sizeof(*session));
            if (!session) { IOObjectRelease(service); IOObjectRelease(iterator); return NULL; }
            result = configure_session(session, service);
            IOObjectRelease(service);
            if (result == kIOReturnSuccess) { IOObjectRelease(iterator); return session; }
            if (error_code) *error_code = result;
            crcm_close(session);
        }
        IOObjectRelease(iterator);
    }
    return NULL;
}

int32_t crcm_read_device_id(CRCMLegacySession *session, uint8_t *bytes, uint32_t *length) {
    return (*session->interface)->ReadPipeTO(session->interface, 1, bytes, length, 1000, 1000);
}

int32_t crcm_write_chunk(CRCMLegacySession *session, const uint8_t *bytes, uint32_t length) {
    return (*session->interface)->WritePipeTO(session->interface, 2, (void *)bytes, length, 1000, 1000);
}

int32_t crcm_trigger(CRCMLegacySession *session, uint16_t length) {
    uint8_t *response = calloc(length, 1);
    if (!response) return kIOReturnNoMemory;
    IOUSBDevRequestTO request = {
        .bmRequestType = 0x82, .bRequest = 0, .wValue = 0, .wIndex = 0,
        .wLength = length, .pData = response, .wLenDone = 0,
        .noDataTimeout = 1000, .completionTimeout = 1000
    };
    IOReturn result = (*session->device)->DeviceRequestTO(session->device, &request);
    free(response);
    return result;
}