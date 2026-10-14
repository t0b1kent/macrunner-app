/* Native macOS session lifetime: App pipe EOF stops our unreaped child PID.
 * No namespace lookup, polling App PID, global signal, or signal-handler IO. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t cancelled;
static void cancel(int sig) { (void)sig; cancelled = 1; }
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int stop_child(pid_t child) {
    int status;
    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child || (waited < 0 && errno == ECHILD)) return 0;
    /* Same signal as wineserver -k, directed to our unreaped child.
     * It cannot acquire a reused PID until we reap it. */
    kill(child, SIGINT);
    const double deadline = now() + 2;
    const struct timespec pause = {0, 20000000};
    while (now() < deadline) {
        waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno == ECHILD)) return 0;
        nanosleep(&pause, NULL);
    }
    kill(child, SIGKILL);
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    return waited == child ? 0 : 1;
}
int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') return 2;
    struct sigaction sa = {0};
    sa.sa_handler = cancel;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addinherit_np(&fa, STDOUT_FILENO);
    posix_spawn_file_actions_addinherit_np(&fa, STDERR_FILENO);
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child = 0;
    int err = posix_spawn(&child, argv[1], &fa, &attr, &argv[1], environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (err) { fprintf(stderr, "MACRUNNER_SESSION_SPAWN_ERROR %d\n", err); return 1; }
    fprintf(stderr, "MACRUNNER_SESSION_CHILD %ld\n", (long)child);
    fflush(stderr);
    int kq = kqueue();
    if (kq < 0) { stop_child(child); return 1; }
    struct kevent changes[2], event;
    EV_SET(&changes[0], STDIN_FILENO, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    EV_SET(&changes[1], child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(kq, changes, 2, NULL, 0, NULL) < 0) {
        /* Child may have exited between spawn and NOTE_EXIT registration. */
        int status;
        pid_t got = waitpid(child, &status, WNOHANG);
        close(kq);
        if (got == child) return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        stop_child(child); return 1;
    }
    while (!cancelled) {
        int n = kevent(kq, NULL, 0, &event, 1, NULL);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 || (event.flags & EV_ERROR)) break;
        if (event.filter == EVFILT_PROC) {
            int status;
            pid_t got;
            do { got = waitpid(child, &status, 0); } while (got < 0 && errno == EINTR);
            close(kq);
            return got == child && WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        }
        if (event.filter == EVFILT_READ) {
            char buf[32];
            ssize_t nread = read(STDIN_FILENO, buf, sizeof(buf));
            if (nread == 0 || (nread < 0 && errno != EINTR)) break;
        }
    }
    close(kq);
    return stop_child(child);
}
