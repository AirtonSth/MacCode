#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char executable_path[PATH_MAX];
    uint32_t executable_path_size = sizeof(executable_path);
    if (_NSGetExecutablePath(executable_path, &executable_path_size) != 0) {
        fputs("scheduled task agent path is too long\n", stderr);
        return 78;
    }

    char resources_path[PATH_MAX];
    if (strlcpy(resources_path, executable_path, sizeof(resources_path)) >= sizeof(resources_path)) {
        fputs("scheduled task agent path is too long\n", stderr);
        return 78;
    }

    char *resources_directory = dirname(resources_path);
    char app_executable[PATH_MAX];
    int length = snprintf(
        app_executable,
        sizeof(app_executable),
        "%s/../MacOS/RemoteCode",
        resources_directory
    );
    if (length < 0 || (size_t)length >= sizeof(app_executable)) {
        fputs("RemoteCode executable path is too long\n", stderr);
        return 78;
    }

    char *const child_argv[] = {app_executable, "--scheduled-task-agent", NULL};
    execv(app_executable, child_argv);
    perror("execv");
    return 78;
}
