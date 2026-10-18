// Deliberately independent of today's header: compile a representative original
// catalog caller so incompatible signature/layout changes cannot hide in a recompile.
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int file_id;
    int folder_id;
    char path[1024];
    char name[256];
    int duration_ms;
    int64_t content_hash;
} LegacyResult;

extern int ws_init(const char *db_path);
extern void ws_deinit(void);
extern int ws_index_folder(int folder_id, const char *path);
extern int ws_search(const char *query, int folder_id, LegacyResult *out, int max_results);
extern int ws_list_folder(int folder_id, LegacyResult *out, int max_results);

_Static_assert(sizeof(LegacyResult) == 1304, "original result size");
_Static_assert(offsetof(LegacyResult, content_hash) == 1296, "original hash offset");

int ws_legacy_abi_test(void) {
    // A real WAL catalog and a tiny PCM file let the old caller validate bytes
    // written through its frozen result layout, not just link old symbol names.
    char directory[] = "/tmp/wavesearch-legacy-XXXXXX";
    if (!mkdtemp(directory)) return 60;
    char database[256], audio[256], sidecar[272];
    snprintf(database, sizeof(database), "%s/catalog.sqlite", directory);
    snprintf(audio, sizeof(audio), "%s/rain.wav", directory);
    const unsigned char wav[] = {
        'R','I','F','F', 44,0,0,0, 'W','A','V','E',
        'f','m','t',' ', 16,0,0,0, 1,0, 1,0,
        0x80,0xBB,0,0, 0,0x77,1,0, 2,0, 16,0,
        'd','a','t','a', 8,0,0,0, 0,0, 1,0, 2,0, 3,0
    };
    int status = 61;
    FILE *file = fopen(audio, "wb");
    if (!file) goto cleanup;
    size_t written = fwrite(wav, 1, sizeof(wav), file);
    int closed = fclose(file);
    if (written != sizeof(wav) || closed != 0) goto cleanup;
    if (ws_init(database) != 0) goto cleanup;
    status = 62;
    if (ws_index_folder(1, directory) != 0) goto close_catalog;
    LegacyResult results[2];
    int search_count = ws_search("rain", -1, results, 2);
    if (search_count != 1 || results[0].file_id <= 0 || results[0].folder_id != 1 ||
        strcmp(results[0].path, audio) != 0 || strcmp(results[0].name, "rain.wav") != 0 ||
        results[0].duration_ms != 0 || results[0].content_hash == 0) goto close_catalog;
    int folder_count = ws_list_folder(1, results, 2);
    if (folder_count == 1 && strcmp(results[0].path, audio) == 0) status = 0;
close_catalog:
    ws_deinit();
cleanup:
    unlink(audio);
    unlink(database);
    snprintf(sidecar, sizeof(sidecar), "%s-wal", database);
    unlink(sidecar);
    snprintf(sidecar, sizeof(sidecar), "%s-shm", database);
    unlink(sidecar);
    rmdir(directory);
    return status;
}
