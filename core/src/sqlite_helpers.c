#include "sqlite3.h"

// Zig 0.15 cannot express SQLITE_TRANSIENT ((sqlite3_destructor_type)-1)
// without triggering alignment or bitcast errors.
// This tiny C shim returns the sentinel value directly.
sqlite3_destructor_type ws_sqlite_transient(void) {
    return SQLITE_TRANSIENT;
}
