#include <stdint.h>
#include <sys/stat.h>

// Keep device/inode extraction portable across libc's differing stat layouts.
int ws_directory_identity(int descriptor, uint64_t identity[2]) {
    struct stat info;
    if (fstat(descriptor, &info) != 0) return -1;
    identity[0] = (uint64_t)info.st_dev;
    identity[1] = (uint64_t)info.st_ino;
    return 0;
}
