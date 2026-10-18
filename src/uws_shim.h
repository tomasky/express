/*
 * C ABI for the uWebSockets native shim used by the MoonBit express binding.
 *
 * The shim owns every µWebSockets object. MoonBit only ever sees opaque
 * pointers plus copies of request/response data, because µWebSockets
 * invalidates a request object as soon as its handler returns.
 */
#ifndef MOONBIT_UWS_SHIM_H
#define MOONBIT_UWS_SHIM_H

#include <stdint.h>
#include <moonbit.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Callbacks implemented on the MoonBit side and registered once at startup. */
typedef void (*uwb_req_cb)(uint64_t app_id, void *res, void *req);
typedef void (*uwb_body_cb)(uint64_t request_id, moonbit_bytes_t body, int32_t len, int32_t status);
typedef void (*uwb_abort_cb)(uint64_t request_id);

/* status for uwb_body_cb */
#define UWB_BODY_OK 0
#define UWB_BODY_TOO_LARGE 1

void uwb_set_callbacks(
    uwb_req_cb req_cb,
    uwb_body_cb body_cb,
    uwb_abort_cb abort_cb);

/* --- application --- */
void *uwb_app_new(void);
void uwb_app_any(void *app, uint64_t app_id, moonbit_bytes_t path, int32_t path_len);
int32_t uwb_app_listen(
    void *app,
    uint64_t app_id,
    moonbit_bytes_t host,
    int32_t host_len,
    int32_t port);
void uwb_app_run(void *app);
void uwb_app_close(void *app);

/* --- request snapshot (only valid inside the request callback) --- */
moonbit_bytes_t uwb_req_method(void);
moonbit_bytes_t uwb_req_url(void);
moonbit_bytes_t uwb_req_query(void);
int32_t uwb_req_header_count(void);
moonbit_bytes_t uwb_req_header_name(int32_t index);
moonbit_bytes_t uwb_req_header_value(int32_t index);

/* --- response (usable asynchronously, e.g. from an onData callback) --- */
void uwb_res_write_status(void *res, moonbit_bytes_t status, int32_t len);
void uwb_res_write_header(
    void *res,
    moonbit_bytes_t name,
    int32_t name_len,
    moonbit_bytes_t value,
    int32_t value_len);
void uwb_res_end(void *res, moonbit_bytes_t body, int32_t len);
void uwb_res_end_empty(void *res);
void uwb_res_on_aborted(void *res, uint64_t request_id);
void uwb_res_on_data(void *res, uint64_t request_id, int32_t limit);
moonbit_bytes_t uwb_res_remote_address(void *res);

/* --- filesystem helpers for express.static --- */
/* kind: 0 = missing, 1 = regular file, 2 = directory */
int32_t uwb_fs_kind(moonbit_bytes_t path, int32_t path_len);
moonbit_bytes_t uwb_fs_read_file(moonbit_bytes_t path, int32_t path_len);

#ifdef __cplusplus
}
#endif

#endif
