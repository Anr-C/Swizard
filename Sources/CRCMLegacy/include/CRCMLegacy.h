#ifndef CRCM_LEGACY_H
#define CRCM_LEGACY_H
#include <stdint.h>

typedef struct CRCMLegacySession CRCMLegacySession;
CRCMLegacySession *crcm_open(uint16_t vendor_id, uint16_t product_id, int32_t *error_code);
int32_t crcm_read_device_id(CRCMLegacySession *session, uint8_t *bytes, uint32_t *length);
int32_t crcm_write_chunk(CRCMLegacySession *session, const uint8_t *bytes, uint32_t length);
int32_t crcm_trigger(CRCMLegacySession *session, uint16_t length);
void crcm_close(CRCMLegacySession *session);
#endif