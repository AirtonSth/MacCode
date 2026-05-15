#ifndef RC2_CSYSTEM_H
#define RC2_CSYSTEM_H

#include <unistd.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Wraps macOS's `forkpty(3)` (declared in <util.h>) so Swift can call it
/// without dragging in the full POSIX util module.
///
/// On success the parent returns the child's pid and `*amaster` is set to
/// the master end of the new pty. The child returns 0 and inherits stdin,
/// stdout and stderr connected to the slave end. On error returns -1 and
/// sets errno.
pid_t rc2_forkpty(int *amaster);

/// Sets the controlling terminal window size on the pty master fd.
/// Returns 0 on success or -1 on error (errno is set).
int rc2_set_winsize(int fd, int rows, int cols);

#ifdef __cplusplus
}
#endif

#endif /* RC2_CSYSTEM_H */
