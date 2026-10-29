// Bambu printer LAN protocol: MQTT over TLS (port 8883) and implicit FTPS (port 990), on OpenSSL.
#ifndef A1NET_H
#define A1NET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct A1Mqtt A1Mqtt;

// Connects and logs in (user "bblp", password = access code). Returns NULL and fills err on failure.
A1Mqtt* a1_mqtt_connect(const char* host, int port, const char* user, const char* pass, const char* clientId, int timeoutMs,
                        char* err, size_t errLen);
int a1_mqtt_subscribe(A1Mqtt* m, const char* topic);
int a1_mqtt_publish(A1Mqtt* m, const char* topic, const char* payload, size_t len);
// Waits up to timeoutMs for one incoming PUBLISH. Returns 1 with *topic / *payload (free with a1_net_free),
// 0 on timeout, -1 when the connection dropped. Sends keep-alive pings as needed.
int a1_mqtt_poll(A1Mqtt* m, int timeoutMs, char** topic, char** payload, size_t* payloadLen);
void a1_mqtt_close(A1Mqtt* m);

typedef void (*A1UploadProgress)(double fraction, void* ctx);
// Uploads `data` to the printer's SD card as `remoteName`. Returns 0 on success, otherwise fills err.
int a1_ftps_upload(const char* host, int port, const char* user, const char* pass, const char* remoteName, const uint8_t* data,
                   size_t len, A1UploadProgress progress, void* ctx, char* err, size_t errLen);

void a1_net_free(void* p);

#ifdef __cplusplus
}
#endif

#endif
