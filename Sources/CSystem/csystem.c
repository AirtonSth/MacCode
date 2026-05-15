#include "CSystem.h"
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>

pid_t rc2_forkpty(int *amaster) {
    return forkpty(amaster, NULL, NULL, NULL);
}

int rc2_set_winsize(int fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}
