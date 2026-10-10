#include "onnx_bridge.h"

#include "onnxruntime/onnxruntime_c_api.h"

#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__) || defined(__linux__)
#include <dlfcn.h>
#else
#error "onnx_bridge currently supports macOS and Linux dynamic loaders"
#endif

#define WS_ERROR_CAPACITY 1024
#define WS_AUDIO_SAMPLES 480000u
#define WS_TEXT_TOKENS 77u
#define WS_EMBEDDING_SIZE 512u

typedef const OrtApiBase *(ORT_API_CALL *WsOrtGetApiBaseFn)(void);

typedef struct WsSpinLock {
    atomic_flag flag;
} WsSpinLock;

struct WsOnnxRuntime {
    void *library;
    const OrtApiBase *api_base;
    const OrtApi *api;
    OrtEnv *env;
    atomic_size_t references;
    WsSpinLock error_lock;
    char error[WS_ERROR_CAPACITY];
};

struct WsOnnxSession {
    WsOnnxRuntime *runtime;
    OrtSession *session;
    OrtMemoryInfo *cpu_memory;
    char *output_name;
    WsOnnxSessionKind kind;
    pthread_mutex_t run_mutex;
    int run_mutex_initialized;
    WsSpinLock error_lock;
    char error[WS_ERROR_CAPACITY];
};

static void lock_init(WsSpinLock *lock) {
    atomic_flag_clear_explicit(&lock->flag, memory_order_release);
}

static void lock_acquire(WsSpinLock *lock) {
    while (atomic_flag_test_and_set_explicit(&lock->flag, memory_order_acquire)) {
    }
}

static void lock_release(WsSpinLock *lock) {
    atomic_flag_clear_explicit(&lock->flag, memory_order_release);
}

static void copy_string(char *out, size_t capacity, const char *value) {
    size_t length;
    if (out == NULL || capacity == 0) return;
    if (value == NULL) value = "";
    length = strlen(value);
    if (length >= capacity) length = capacity - 1;
    if (length != 0) memcpy(out, value, length);
    out[length] = '\0';
}

static void format_message(char *out, size_t capacity, const char *prefix, const char *detail) {
    if (out == NULL || capacity == 0) return;
    if (detail != NULL && detail[0] != '\0')
        (void)snprintf(out, capacity, "%s: %s", prefix, detail);
    else
        copy_string(out, capacity, prefix);
}

static void runtime_set_error(WsOnnxRuntime *runtime, const char *message) {
    lock_acquire(&runtime->error_lock);
    copy_string(runtime->error, sizeof(runtime->error), message);
    lock_release(&runtime->error_lock);
}

static void session_set_error(WsOnnxSession *session, const char *message) {
    lock_acquire(&session->error_lock);
    copy_string(session->error, sizeof(session->error), message);
    lock_release(&session->error_lock);
}

static int session_fail(WsOnnxSession *session, int code, const char *message) {
    session_set_error(session, message);
    return code;
}

static int session_ort_status(WsOnnxSession *session, OrtStatus *status, const char *operation) {
    char message[WS_ERROR_CAPACITY];
    const char *detail;
    if (status == NULL) return WS_ONNX_OK;
    detail = session->runtime->api->GetErrorMessage(status);
    format_message(message, sizeof(message), operation, detail);
    session->runtime->api->ReleaseStatus(status);
    session_set_error(session, message);
    return WS_ONNX_RUNTIME_ERROR;
}

static int open_ort_status(const OrtApi *api, OrtStatus *status, const char *operation,
                           char *error, size_t error_capacity) {
    char message[WS_ERROR_CAPACITY];
    const char *detail;
    if (status == NULL) return WS_ONNX_OK;
    detail = api->GetErrorMessage(status);
    format_message(message, sizeof(message), operation, detail);
    api->ReleaseStatus(status);
    copy_string(error, error_capacity, message);
    return WS_ONNX_RUNTIME_ERROR;
}

static void runtime_retain(WsOnnxRuntime *runtime) {
    (void)atomic_fetch_add_explicit(&runtime->references, 1, memory_order_relaxed);
}

static void runtime_release(WsOnnxRuntime *runtime) {
    if (runtime == NULL) return;
    if (atomic_fetch_sub_explicit(&runtime->references, 1, memory_order_acq_rel) != 1) return;
    if (runtime->env != NULL) runtime->api->ReleaseEnv(runtime->env);
    if (runtime->library != NULL) (void)dlclose(runtime->library);
    free(runtime);
}

int ws_onnx_runtime_open(const char *library_path, WsOnnxRuntime **out_runtime,
                         char *error, size_t error_capacity) {
    WsOnnxRuntime *runtime;
    WsOrtGetApiBaseFn get_api_base = NULL;
    void *symbol;
    const char *loader_error;
    int result;

    if (out_runtime != NULL) *out_runtime = NULL;
    copy_string(error, error_capacity, "");
    if (library_path == NULL || library_path[0] == '\0' || out_runtime == NULL) {
        copy_string(error, error_capacity, "library path and output runtime are required");
        return WS_ONNX_INVALID_ARGUMENT;
    }

    runtime = (WsOnnxRuntime *)calloc(1, sizeof(*runtime));
    if (runtime == NULL) {
        copy_string(error, error_capacity, "failed to allocate ONNX Runtime bridge");
        return WS_ONNX_OUT_OF_MEMORY;
    }
    lock_init(&runtime->error_lock);
    atomic_init(&runtime->references, 1);

    (void)dlerror();
    runtime->library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (runtime->library == NULL) {
        loader_error = dlerror();
        format_message(error, error_capacity, "failed to load ONNX Runtime library", loader_error);
        free(runtime);
        return WS_ONNX_LIBRARY_LOAD_FAILED;
    }

    (void)dlerror();
    symbol = dlsym(runtime->library, "OrtGetApiBase");
    loader_error = dlerror();
    if (loader_error != NULL || symbol == NULL) {
        format_message(error, error_capacity, "ONNX Runtime entry point OrtGetApiBase was not found", loader_error);
        (void)dlclose(runtime->library);
        free(runtime);
        return WS_ONNX_SYMBOL_NOT_FOUND;
    }
    /* POSIX specifies dlsym for function symbols. memcpy avoids a non-ISO object/function cast. */
    memcpy(&get_api_base, &symbol, sizeof(get_api_base));
    runtime->api_base = get_api_base();
    if (runtime->api_base == NULL) {
        copy_string(error, error_capacity, "OrtGetApiBase returned null");
        (void)dlclose(runtime->library);
        free(runtime);
        return WS_ONNX_API_VERSION_UNSUPPORTED;
    }
    runtime->api = runtime->api_base->GetApi(ORT_API_VERSION);
    if (runtime->api == NULL) {
        copy_string(error, error_capacity, "ONNX Runtime does not support C API version 29");
        (void)dlclose(runtime->library);
        free(runtime);
        return WS_ONNX_API_VERSION_UNSUPPORTED;
    }

    result = open_ort_status(runtime->api,
                             runtime->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "wavesearch", &runtime->env),
                             "failed to create ONNX Runtime environment", error, error_capacity);
    if (result != WS_ONNX_OK) {
        (void)dlclose(runtime->library);
        free(runtime);
        return result;
    }
    runtime_set_error(runtime, "");
    *out_runtime = runtime;
    return WS_ONNX_OK;
}

void ws_onnx_runtime_close(WsOnnxRuntime **runtime) {
    WsOnnxRuntime *value;
    if (runtime == NULL || *runtime == NULL) return;
    value = *runtime;
    *runtime = NULL;
    runtime_release(value);
}

int ws_onnx_runtime_version(const WsOnnxRuntime *runtime, char *out, size_t capacity) {
    if (out != NULL && capacity != 0) out[0] = '\0';
    if (runtime == NULL || out == NULL || capacity == 0) return WS_ONNX_INVALID_ARGUMENT;
    copy_string(out, capacity, runtime->api_base->GetVersionString());
    return WS_ONNX_OK;
}

int ws_onnx_runtime_error(const WsOnnxRuntime *runtime_const, char *out, size_t capacity) {
    WsOnnxRuntime *runtime = (WsOnnxRuntime *)runtime_const;
    if (out != NULL && capacity != 0) out[0] = '\0';
    if (runtime == NULL || out == NULL || capacity == 0) return WS_ONNX_INVALID_ARGUMENT;
    lock_acquire(&runtime->error_lock);
    copy_string(out, capacity, runtime->error);
    lock_release(&runtime->error_lock);
    return WS_ONNX_OK;
}

static int tensor_info_matches(WsOnnxSession *session, const OrtTypeInfo *type_info,
                               ONNXTensorElementDataType expected_type,
                               const int64_t expected_dimensions[2], const char *description) {
    const OrtTensorTypeAndShapeInfo *tensor_info = NULL;
    ONNXTensorElementDataType element_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t rank = 0;
    int64_t dimensions[2] = {0, 0};
    OrtStatus *status;
    char message[WS_ERROR_CAPACITY];

    status = session->runtime->api->CastTypeInfoToTensorInfo(type_info, &tensor_info);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model tensor");
    if (tensor_info == NULL)
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, "model contract requires tensor inputs and outputs");
    status = session->runtime->api->GetTensorElementType(tensor_info, &element_type);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model tensor type");
    status = session->runtime->api->GetDimensionsCount(tensor_info, &rank);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model tensor rank");
    if (rank != 2 || element_type != expected_type) {
        (void)snprintf(message, sizeof(message), "%s must have the required rank-2 element type", description);
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, message);
    }
    status = session->runtime->api->GetDimensions(tensor_info, dimensions, 2);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model tensor dimensions");
    if ((dimensions[0] != -1 && dimensions[0] != expected_dimensions[0]) ||
        (dimensions[1] != -1 && dimensions[1] != expected_dimensions[1])) {
        (void)snprintf(message, sizeof(message), "%s has an incompatible shape", description);
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, message);
    }
    return WS_ONNX_OK;
}

static int validate_named_input(WsOnnxSession *session, const char *expected_name,
                                ONNXTensorElementDataType expected_type,
                                const int64_t expected_dimensions[2]) {
    const OrtApi *api = session->runtime->api;
    OrtAllocator *allocator = NULL;
    size_t count = 0;
    size_t index;
    int found = 0;
    int result;
    OrtStatus *status;

    status = api->SessionGetInputCount(session->session, &count);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model input count");
    status = api->GetAllocatorWithDefaultOptions(&allocator);
    if (status != NULL) return session_ort_status(session, status, "failed to acquire ONNX Runtime allocator");
    for (index = 0; index < count; ++index) {
        char *name = NULL;
        status = api->SessionGetInputName(session->session, index, allocator, &name);
        if (status != NULL) return session_ort_status(session, status, "failed to inspect model input name");
        if (name != NULL && strcmp(name, expected_name) == 0) {
            OrtTypeInfo *type_info = NULL;
            found = 1;
            allocator->Free(allocator, name);
            status = api->SessionGetInputTypeInfo(session->session, index, &type_info);
            if (status != NULL) return session_ort_status(session, status, "failed to inspect model input type");
            result = tensor_info_matches(session, type_info, expected_type, expected_dimensions, expected_name);
            api->ReleaseTypeInfo(type_info);
            return result;
        }
        if (name != NULL) allocator->Free(allocator, name);
    }
    if (!found) {
        char message[WS_ERROR_CAPACITY];
        (void)snprintf(message, sizeof(message), "model input '%s' was not found", expected_name);
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, message);
    }
    return WS_ONNX_OK;
}

static int validate_model_contract(WsOnnxSession *session) {
    const OrtApi *api = session->runtime->api;
    const int64_t audio_shape[2] = {1, WS_AUDIO_SAMPLES};
    const int64_t text_shape[2] = {1, WS_TEXT_TOKENS};
    const int64_t output_shape[2] = {1, WS_EMBEDDING_SIZE};
    size_t input_count = 0;
    size_t output_count = 0;
    OrtTypeInfo *output_type = NULL;
    OrtAllocator *allocator = NULL;
    char *allocated_name = NULL;
    size_t output_name_length;
    OrtStatus *status;
    int result;

    status = api->SessionGetInputCount(session->session, &input_count);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model input count");
    if ((session->kind == WS_ONNX_SESSION_AUDIO && input_count != 1) ||
        (session->kind == WS_ONNX_SESSION_TEXT && input_count != 2))
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, "model has an unexpected number of inputs");

    if (session->kind == WS_ONNX_SESSION_AUDIO) {
        result = validate_named_input(session, "waveform", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, audio_shape);
        if (result != WS_ONNX_OK) return result;
    } else {
        result = validate_named_input(session, "input_ids", ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, text_shape);
        if (result != WS_ONNX_OK) return result;
        result = validate_named_input(session, "attention_mask", ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, text_shape);
        if (result != WS_ONNX_OK) return result;
    }

    status = api->SessionGetOutputCount(session->session, &output_count);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model output count");
    if (output_count == 0)
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, "model has no outputs");
    status = api->SessionGetOutputTypeInfo(session->session, 0, &output_type);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect first model output");
    result = tensor_info_matches(session, output_type, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                                 output_shape, "first model output");
    api->ReleaseTypeInfo(output_type);
    if (result != WS_ONNX_OK) return result;

    status = api->GetAllocatorWithDefaultOptions(&allocator);
    if (status != NULL) return session_ort_status(session, status, "failed to acquire ONNX Runtime allocator");
    status = api->SessionGetOutputName(session->session, 0, allocator, &allocated_name);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect first model output name");
    if (allocated_name == NULL || allocated_name[0] == '\0') {
        if (allocated_name != NULL) allocator->Free(allocator, allocated_name);
        return session_fail(session, WS_ONNX_MODEL_CONTRACT_ERROR, "first model output has no name");
    }
    output_name_length = strlen(allocated_name);
    session->output_name = (char *)malloc(output_name_length + 1);
    if (session->output_name != NULL) memcpy(session->output_name, allocated_name, output_name_length + 1);
    allocator->Free(allocator, allocated_name);
    if (session->output_name == NULL)
        return session_fail(session, WS_ONNX_OUT_OF_MEMORY, "failed to copy first model output name");
    return WS_ONNX_OK;
}

int ws_onnx_session_open(WsOnnxRuntime *runtime, const char *model_path,
                         WsOnnxSessionKind kind, int intra_op_threads,
                         WsOnnxSession **out_session,
                         char *error, size_t error_capacity) {
    WsOnnxSession *session;
    OrtSessionOptions *options = NULL;
    OrtStatus *status;
    int result;

    if (out_session != NULL) *out_session = NULL;
    copy_string(error, error_capacity, "");
    if (runtime == NULL || model_path == NULL || model_path[0] == '\0' || out_session == NULL ||
        (kind != WS_ONNX_SESSION_AUDIO && kind != WS_ONNX_SESSION_TEXT) || intra_op_threads < 0) {
        copy_string(error, error_capacity, "runtime, model path, valid kind, thread count, and output session are required");
        return WS_ONNX_INVALID_ARGUMENT;
    }
    session = (WsOnnxSession *)calloc(1, sizeof(*session));
    if (session == NULL) {
        copy_string(error, error_capacity, "failed to allocate ONNX session bridge");
        return WS_ONNX_OUT_OF_MEMORY;
    }
    lock_init(&session->error_lock);
    if (pthread_mutex_init(&session->run_mutex, NULL) != 0) {
        copy_string(error, error_capacity, "failed to create ONNX session mutex");
        free(session);
        return WS_ONNX_OUT_OF_MEMORY;
    }
    session->run_mutex_initialized = 1;
    session->runtime = runtime;
    session->kind = kind;
    runtime_retain(runtime);

    status = runtime->api->CreateSessionOptions(&options);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to create ONNX session options");
        goto fail;
    }
    status = runtime->api->SetIntraOpNumThreads(options, intra_op_threads);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to configure intra-op threads");
        goto fail;
    }
    status = runtime->api->SetInterOpNumThreads(options, 1);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to configure inter-op threads");
        goto fail;
    }
    status = runtime->api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to enable graph optimization");
        goto fail;
    }
    /* The CPU execution provider is ONNX Runtime's default provider. No platform EP is appended. */
    status = runtime->api->CreateSession(runtime->env, model_path, options, &session->session);
    runtime->api->ReleaseSessionOptions(options);
    options = NULL;
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to open ONNX model");
        goto fail;
    }
    status = runtime->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &session->cpu_memory);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to create CPU memory information");
        goto fail;
    }
    result = validate_model_contract(session);
    if (result != WS_ONNX_OK) goto fail;

    session_set_error(session, "");
    *out_session = session;
    return WS_ONNX_OK;

fail:
    if (options != NULL) runtime->api->ReleaseSessionOptions(options);
    ws_onnx_session_error(session, error, error_capacity);
    if (session->cpu_memory != NULL) runtime->api->ReleaseMemoryInfo(session->cpu_memory);
    if (session->session != NULL) runtime->api->ReleaseSession(session->session);
    free(session->output_name);
    if (session->run_mutex_initialized) (void)pthread_mutex_destroy(&session->run_mutex);
    runtime_release(runtime);
    free(session);
    return result;
}

void ws_onnx_session_close(WsOnnxSession **session_pointer) {
    WsOnnxSession *session;
    WsOnnxRuntime *runtime;
    if (session_pointer == NULL || *session_pointer == NULL) return;
    session = *session_pointer;
    *session_pointer = NULL;
    runtime = session->runtime;
    if (session->cpu_memory != NULL) runtime->api->ReleaseMemoryInfo(session->cpu_memory);
    if (session->session != NULL) runtime->api->ReleaseSession(session->session);
    free(session->output_name);
    if (session->run_mutex_initialized) (void)pthread_mutex_destroy(&session->run_mutex);
    free(session);
    runtime_release(runtime);
}

int ws_onnx_session_error(const WsOnnxSession *session_const, char *out, size_t capacity) {
    WsOnnxSession *session = (WsOnnxSession *)session_const;
    if (out != NULL && capacity != 0) out[0] = '\0';
    if (session == NULL || out == NULL || capacity == 0) return WS_ONNX_INVALID_ARGUMENT;
    lock_acquire(&session->error_lock);
    copy_string(out, capacity, session->error);
    lock_release(&session->error_lock);
    return WS_ONNX_OK;
}

static int validate_and_copy_output(WsOnnxSession *session, OrtValue *output, float *embedding) {
    const OrtApi *api = session->runtime->api;
    OrtTensorTypeAndShapeInfo *info = NULL;
    ONNXTensorElementDataType element_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t rank = 0;
    size_t element_count = 0;
    int64_t dimensions[2] = {0, 0};
    int is_tensor = 0;
    void *data = NULL;
    OrtStatus *status;

    status = api->IsTensor(output, &is_tensor);
    if (status != NULL) return session_ort_status(session, status, "failed to identify model output");
    if (!is_tensor) return session_fail(session, WS_ONNX_OUTPUT_CONTRACT_ERROR, "first model output is not a tensor");
    status = api->GetTensorTypeAndShape(output, &info);
    if (status != NULL) return session_ort_status(session, status, "failed to inspect model output");
    status = api->GetTensorElementType(info, &element_type);
    if (status != NULL) goto ort_failure;
    status = api->GetDimensionsCount(info, &rank);
    if (status != NULL) goto ort_failure;
    if (rank != 2 || element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        api->ReleaseTensorTypeAndShapeInfo(info);
        return session_fail(session, WS_ONNX_OUTPUT_CONTRACT_ERROR, "first model output must be float32 rank 2");
    }
    status = api->GetDimensions(info, dimensions, 2);
    if (status != NULL) goto ort_failure;
    status = api->GetTensorShapeElementCount(info, &element_count);
    if (status != NULL) goto ort_failure;
    if (dimensions[0] != 1 || dimensions[1] != WS_EMBEDDING_SIZE || element_count != WS_EMBEDDING_SIZE) {
        api->ReleaseTensorTypeAndShapeInfo(info);
        return session_fail(session, WS_ONNX_OUTPUT_CONTRACT_ERROR, "first model output must have shape [1,512]");
    }
    api->ReleaseTensorTypeAndShapeInfo(info);
    status = api->GetTensorMutableData(output, &data);
    if (status != NULL) return session_ort_status(session, status, "failed to access model output data");
    if (data == NULL) return session_fail(session, WS_ONNX_OUTPUT_CONTRACT_ERROR, "first model output has no data");
    memcpy(embedding, data, WS_EMBEDDING_SIZE * sizeof(float));
    return WS_ONNX_OK;

ort_failure:
    api->ReleaseTensorTypeAndShapeInfo(info);
    return session_ort_status(session, status, "failed to validate model output shape and type");
}

static int run_values(WsOnnxSession *session, const char *const *names,
                      OrtValue *const *values, size_t value_count, float *embedding) {
    const OrtApi *api = session->runtime->api;
    const OrtValue *const *const_values = (const OrtValue *const *)values;
    const char *output_names[1];
    OrtValue *output = NULL;
    OrtStatus *status;
    int result;

    output_names[0] = session->output_name;
    status = api->Run(session->session, NULL, names, const_values, value_count,
                      output_names, 1, &output);
    if (status != NULL) {
        if (output != NULL) api->ReleaseValue(output);
        return session_ort_status(session, status, "ONNX Runtime inference failed");
    }
    if (output == NULL) return session_fail(session, WS_ONNX_OUTPUT_CONTRACT_ERROR, "ONNX Runtime returned no first output");
    result = validate_and_copy_output(session, output, embedding);
    api->ReleaseValue(output);
    return result;
}

int ws_onnx_run_audio(WsOnnxSession *session,
                      const float *waveform, size_t waveform_count,
                      float *embedding, size_t embedding_count) {
    const OrtApi *api;
    const int64_t shape[2] = {1, WS_AUDIO_SAMPLES};
    const char *names[1] = {"waveform"};
    OrtValue *input = NULL;
    OrtValue *values[1];
    OrtStatus *status;
    int result;

    if (session == NULL || waveform == NULL || embedding == NULL ||
        waveform_count != WS_AUDIO_SAMPLES || embedding_count != WS_EMBEDDING_SIZE)
        return session == NULL ? WS_ONNX_INVALID_ARGUMENT :
               session_fail(session, WS_ONNX_INVALID_ARGUMENT, "audio input must be float32 [1,480000] and output capacity 512");
    if (session->kind != WS_ONNX_SESSION_AUDIO)
        return session_fail(session, WS_ONNX_WRONG_SESSION_KIND, "audio inference requires an audio session");

    (void)pthread_mutex_lock(&session->run_mutex);
    api = session->runtime->api;
    status = api->CreateTensorWithDataAsOrtValue(session->cpu_memory, (void *)waveform,
                                                  waveform_count * sizeof(float), shape, 2,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input);
    if (status != NULL) {
        if (input != NULL) api->ReleaseValue(input);
        result = session_ort_status(session, status, "failed to create audio input tensor");
    } else {
        values[0] = input;
        result = run_values(session, names, values, 1, embedding);
        api->ReleaseValue(input);
    }
    if (result == WS_ONNX_OK) session_set_error(session, "");
    (void)pthread_mutex_unlock(&session->run_mutex);
    return result;
}

int ws_onnx_run_text(WsOnnxSession *session,
                     const int64_t *input_ids, size_t input_ids_count,
                     const int64_t *attention_mask, size_t attention_mask_count,
                     float *embedding, size_t embedding_count) {
    const OrtApi *api;
    const int64_t shape[2] = {1, WS_TEXT_TOKENS};
    const char *names[2] = {"input_ids", "attention_mask"};
    OrtValue *values[2] = {NULL, NULL};
    OrtStatus *status;
    int result;

    if (session == NULL || input_ids == NULL || attention_mask == NULL || embedding == NULL ||
        input_ids_count != WS_TEXT_TOKENS || attention_mask_count != WS_TEXT_TOKENS ||
        embedding_count != WS_EMBEDDING_SIZE)
        return session == NULL ? WS_ONNX_INVALID_ARGUMENT :
               session_fail(session, WS_ONNX_INVALID_ARGUMENT, "text inputs must be int64 [1,77] and output capacity 512");
    if (session->kind != WS_ONNX_SESSION_TEXT)
        return session_fail(session, WS_ONNX_WRONG_SESSION_KIND, "text inference requires a text session");

    (void)pthread_mutex_lock(&session->run_mutex);
    api = session->runtime->api;
    status = api->CreateTensorWithDataAsOrtValue(session->cpu_memory, (void *)input_ids,
                                                  input_ids_count * sizeof(int64_t), shape, 2,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &values[0]);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to create input_ids tensor");
        goto done;
    }
    status = api->CreateTensorWithDataAsOrtValue(session->cpu_memory, (void *)attention_mask,
                                                  attention_mask_count * sizeof(int64_t), shape, 2,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &values[1]);
    if (status != NULL) {
        result = session_ort_status(session, status, "failed to create attention_mask tensor");
        goto done;
    }
    result = run_values(session, names, values, 2, embedding);

done:
    if (values[1] != NULL) api->ReleaseValue(values[1]);
    if (values[0] != NULL) api->ReleaseValue(values[0]);
    if (result == WS_ONNX_OK) session_set_error(session, "");
    (void)pthread_mutex_unlock(&session->run_mutex);
    return result;
}
