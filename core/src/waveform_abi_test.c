#include "wavesearch.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(WS_WAVEFORM_ANALYZER_ABI_VERSION == 1u, "analyzer ABI");
_Static_assert(sizeof(WSWaveformAnalyzerConfig) == 88, "config layout");
_Static_assert(offsetof(WSWaveformAnalyzerConfig, sample_rate) == 24, "config sample rate");
_Static_assert(offsetof(WSWaveformAnalyzerConfig, reserved) == 72, "config tail");
_Static_assert(sizeof(WSWaveformPCMBuffer) == 56, "PCM buffer layout");
_Static_assert(offsetof(WSWaveformPCMBuffer, interleaved) == 24, "PCM pointer layout");
_Static_assert(sizeof(WSWaveformResultInfo) == 128, "result info layout");
_Static_assert(offsetof(WSWaveformResultInfo, level_bucket_counts) == 56, "level counts");
_Static_assert(offsetof(WSWaveformResultInfo, integrated_lufs) == 96, "loudness fields");
_Static_assert(sizeof(WSWaveformPeak) == 8, "peak layout");

int main(void) {
    WSQueryRequest *request = ws_query_create();
    if (!request) return 20;
    ws_query_cancel(request);
    if (ws_search_v2(request, "hit", -1, NULL, 0, WS_SEARCH_LEXICAL_ONLY) != WS_QUERY_CANCELLED) return 21;
    if (ws_search_v2(request, "hit", -1, NULL, 0, WS_SEARCH_HYBRID) != WS_QUERY_CANCELLED) return 22;
    if (ws_list_folder_v2(request, 1, NULL, 0) != WS_QUERY_CANCELLED) return 23;
    if (ws_search_by_example_v2(request, "/missing.wav", -1, NULL, 0) != WS_QUERY_CANCELLED) return 24;
    if (ws_search_by_example_pcm_v2(request, NULL, 0, 0, 0, -1, NULL, 0) != WS_QUERY_CANCELLED) return 25;
    ws_query_destroy(request);
    ws_query_cancel(NULL);
    ws_query_destroy(NULL);
    uint64_t stale_generation = ws_refinement_generation();
    if (ws_cancel_refinement() != 0) return 9;
    if (ws_acoustic_index_pending_v2(-1, 1, stale_generation) != -1) return 10;
    if (ws_clap_index_pending_v2(-1, 1, stale_generation) != -1) return 11;
    const float samples[] = {-1.0f, 0.25f, 1.0f, -0.5f};
    const float *planes[] = {samples};
    WSWaveformAnalyzerConfig config = {0};
    config.struct_size = sizeof(config);
    config.version = WS_WAVEFORM_ANALYZER_ABI_VERSION;
    config.purpose = WS_WAVEFORM_PURPOSE_DETAILED_4096;
    config.backend = WS_WAVEFORM_BACKEND_PORTABLE;
    config.sample_rate = 48000.0;
    config.total_frames = 4;
    config.channel_count = 1;

    WSWaveformAnalyzer *analyzer = NULL;
    if (ws_waveform_analyzer_create_v1(&config, &analyzer) != WS_WAVEFORM_OK || !analyzer) return 1;

    WSWaveformPCMBuffer pcm = {0};
    pcm.struct_size = sizeof(pcm);
    pcm.version = WS_WAVEFORM_PCM_BUFFER_VERSION;
    pcm.layout = WS_PCM_LAYOUT_PLANAR;
    pcm.channel_count = 1;
    pcm.frame_count = 4;
    pcm.planes = planes;
    if (ws_waveform_analyzer_push_v1(analyzer, &pcm) != WS_WAVEFORM_OK) return 2;

    WSWaveformResult *result = NULL;
    if (ws_waveform_analyzer_finish_v1(analyzer, &result) != WS_WAVEFORM_OK || !result) return 3;
    ws_waveform_analyzer_destroy(analyzer);

    WSWaveformResultInfo info = {0};
    info.struct_size = sizeof(info);
    info.version = WS_WAVEFORM_RESULT_INFO_VERSION;
    if (ws_waveform_result_info_v1(result, &info) != WS_WAVEFORM_OK) return 4;
    if (info.frame_count != 4 || info.source_channel_count != 1 || info.level_count != 1) return 5;

    uint64_t required = 0;
    if (ws_waveform_result_copy_level_v1(result, 0, NULL, 0, &required) != WS_WAVEFORM_OK || required != 4) return 6;
    WSWaveformPeak peaks[4];
    if (ws_waveform_result_copy_level_v1(result, 0, peaks, 4, &required) != WS_WAVEFORM_OK) return 7;
    if (!(peaks[0].minimum <= -0.99f && peaks[2].maximum >= 0.99f)) return 8;

    ws_waveform_result_destroy(result);
    return 0;
}
