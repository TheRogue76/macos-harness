#include <adwaita.h>
#include <gtk/gtk.h>
#include <sys/prctl.h>

/// Makes the process non-dumpable, so other processes of the same user can't read its memory or
/// its environment through /proc. prctl is variadic, which Swift can't call.
static inline int harness_forbid_dumps(void) {
    return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
}
