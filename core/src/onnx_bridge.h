#ifndef WS_ONNX_BRIDGE_H
#define WS_ONNX_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WsOnnxRuntime WsOnnxRuntime;
typedef struct WsOnnxSession WsOnnxSession;

typedef enum WsOnnxResult {
    WS_ONNX_OK = 0,
    WS_ONNX_INVALID_ARGUMENT = 1,
    WS_ONNX_OUT_OF_MEMORY = 2,
    WS_ONNX_LIBRARY_LOAD_FAILED = 3,
    WS_ONNX_SYMBOL_NOT_FOUND = 4,
    WS_ONNX_API_VERSION_UNSUPPORTED = 5,
    WS_ONNX_RUNTIME_ERROR = 6,
    WS_ONNX_MODEL_CONTRACT_ERROR = 7,
    WS_ONNX_OUTPUT_CONTRACT_ERROR = 8,
    WS_ONNX_WRONG_SESSION_KIND = 9
} WsOnnxResult;

typedef enum WsOnnxSessionKind {
    WS_ONNX_SESSION_AUDIO = 1,
    WS_ONNX_SESSION_TEXT = 2
} WsOnnxSessionKind;

/* Every diagnostic is copied into caller-owned storage and always NUL terminated
 * when error_capacity is nonzero. Objects are opaque and allocated by the bridge. */
int ws_onnx_runtime_open(const char *library_path, WsOnnxRuntime **out_runtime,
                         char *error, size_t error_capacity);
void ws_onnx_runtime_close(WsOnnxRuntime **runtime);
int ws_onnx_runtime_version(const WsOnnxRuntime *runtime, char *out, size_t capacity);
int ws_onnx_runtime_error(const WsOnnxRuntime *runtime, char *out, size_t capacity);

int ws_onnx_session_open(WsOnnxRuntime *runtime, const char *model_path,
                         WsOnnxSessionKind kind, int intra_op_threads,
                         WsOnnxSession **out_session,
                         char *error, size_t error_capacity);
void ws_onnx_session_close(WsOnnxSession **session);
int ws_onnx_session_error(const WsOnnxSession *session, char *out, size_t capacity);

int ws_onnx_run_audio(WsOnnxSession *session,
                      const float *waveform, size_t waveform_count,
                      float *embedding, size_t embedding_count);
int ws_onnx_run_text(WsOnnxSession *session,
                     const int64_t *input_ids, size_t input_ids_count,
                     const int64_t *attention_mask, size_t attention_mask_count,
                     float *embedding, size_t embedding_count);

#ifdef __cplusplus
}
#endif

#endif
