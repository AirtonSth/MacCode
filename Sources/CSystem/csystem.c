#include "CSystem.h"
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>

pid_t rc2_forkpty(int *amaster) {
    return forkpty(amaster, NULL, NULL, NULL);
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
