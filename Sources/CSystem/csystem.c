#include "CSystem.h"
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <libproc.h>

pid_t rc2_forkpty(int *amaster) {
    return forkpty(amaster, NULL, NULL, NULL);
}

// Runs in the forked child before exec: syscalls only, no allocation.
// Closes just the descriptors that are open (a sweep to a raised
// RLIMIT_NOFILE would be ~1M close calls and delay exec); falls back to the
// sweep when the list does not fit or cannot be read.
static void rc2_close_inherited_fds(void) {
    struct proc_fdinfo fds[1024];
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, (int)sizeof(fds));
    if (bytes > 0 && bytes < (int)sizeof(fds)) {
        int count = bytes / (int)PROC_PIDLISTFD_SIZE;
        for (int i = 0; i < count; i++) {
            if (fds[i].proc_fd > STDERR_FILENO) {
                (void)close(fds[i].proc_fd);
            }
        }
        return;
    }
    int max_fd = getdtablesize();
    if (max_fd < 0 || max_fd > 65536) {
        max_fd = 65536;
    }
    for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
        (void)close(fd);
    }
}

static pid_t rc2_spawnpty_exec_impl(
    int *amaster,
    const char *cwd,
    const char *path,
    char *const argv[],
    char *const envp[],
    int suspend_before_exec) {
    pid_t pid = forkpty(amaster, NULL, NULL, NULL);
    if (pid < 0) {
        return pid;
    }

    if (pid > 0) {
        if (!suspend_before_exec) {
            return pid;
        }
        int status = 0;
        pid_t wait_result = 0;
        for (int attempt = 0; attempt < 2000; attempt++) {
            wait_result = waitpid(pid, &status, WUNTRACED | WNOHANG);
            if (wait_result == pid) {
                if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGSTOP) {
                    return pid;
                }
                break;
            }
            if (wait_result < 0 && errno == EINTR) {
                continue;
            }
            if (wait_result < 0) {
                break;
            }
            usleep(500);
        }
        int failure_errno = wait_result < 0
            ? errno
            : (wait_result == pid ? ECANCELED : ETIMEDOUT);
        if (wait_result == 0 || (wait_result == pid && WIFSTOPPED(status))) {
            (void)kill(pid, SIGKILL);
            do {
                wait_result = waitpid(pid, &status, 0);
            } while (wait_result < 0 && errno == EINTR);
        }
        close(*amaster);
        *amaster = -1;
        errno = failure_errno;
        return -1;
    }

    if (suspend_before_exec && kill(getpid(), SIGSTOP) != 0) {
        _exit(127);
    }

    // forkpty already put the slave on 0-2. Close every other inherited app
    // descriptor: Foundation Pipe() fds are not close-on-exec, so a shell
    // spawned while a git probe ran kept its write ends and the app's reader
    // never saw EOF; shells also kept app logs.
    rc2_close_inherited_fds();

    if (chdir(cwd) != 0) {
        _exit(127);
    }
    execve(path, argv, envp);
    _exit(127);
}

pid_t rc2_spawnpty_exec(
    int *amaster,
    const char *cwd,
    const char *path,
    char *const argv[],
    char *const envp[]) {
    return rc2_spawnpty_exec_impl(amaster, cwd, path, argv, envp, 0);
}

pid_t rc2_spawnpty_exec_suspended(
    int *amaster,
    const char *cwd,
    const char *path,
    char *const argv[],
    char *const envp[]) {
    return rc2_spawnpty_exec_impl(amaster, cwd, path, argv, envp, 1);
}

int rc2_set_winsize(int fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}
