// SPDX-FileCopyrightText: 2026 Frank Hunleth
//
// SPDX-License-Identifier: Apache-2.0
//
// Bridge between an Erlang port ({packet, 2} framing) and a command running
// on a pseudo-terminal.
//
// Frames from Erlang are <<type:8, payload/binary>>:
//   type 0: payload is keyboard input to write to the pty
//   type 1: payload is <<rows:16, cols:16>> -> TIOCSWINSZ (kernel sends
//           SIGWINCH to the foreground process group)
//
// Frames to Erlang are raw pty output (no type byte).
//
// Exits with the child's exit status when the child exits. If stdin closes
// (Erlang port closed), the child gets SIGHUP and the bridge exits.

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#define FRAME_DATA 0
#define FRAME_WINSZ 1

// Returns <0 on error, 0 on EOF, len when fully read
static ssize_t read_exact(int fd, uint8_t *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n == 0)
            return 0;
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        got += (size_t) n;
    }
    return (ssize_t) got;
}

static int write_exact(int fd, const uint8_t *buf, size_t len)
{
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        sent += (size_t) n;
    }
    return 0;
}

static int send_frame(const uint8_t *buf, size_t len)
{
    uint8_t hdr[2] = {(uint8_t) (len >> 8), (uint8_t) (len & 0xff)};
    if (write_exact(STDOUT_FILENO, hdr, sizeof(hdr)) < 0)
        return -1;
    return write_exact(STDOUT_FILENO, buf, len);
}

// Returns 0 to continue, <0 to quit
static int handle_stdin_frame(int master)
{
    uint8_t hdr[2];
    uint8_t buf[65536];

    if (read_exact(STDIN_FILENO, hdr, sizeof(hdr)) <= 0)
        return -1;

    size_t len = ((size_t) hdr[0] << 8) | hdr[1];
    if (len == 0)
        return 0;

    if (read_exact(STDIN_FILENO, buf, len) <= 0)
        return -1;

    switch (buf[0]) {
    case FRAME_DATA:
        if (len > 1 && write_exact(master, buf + 1, len - 1) < 0)
            return -1;
        break;

    case FRAME_WINSZ:
        if (len >= 5) {
            struct winsize ws = {0};
            ws.ws_row = (buf[1] << 8) | buf[2];
            ws.ws_col = (buf[3] << 8) | buf[4];
            ioctl(master, TIOCSWINSZ, &ws);
        }
        break;

    default:
        break;
    }
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);

    // Start at 80x24 until a winsize frame arrives
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        perror("forkpty");
        return 1;
    }

    if (pid == 0) {
        execv(argv[1], &argv[1]);
        perror("execv");
        _exit(127);
    }

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(STDIN_FILENO, &rfds);
        FD_SET(master, &rfds);

        int maxfd = master > STDIN_FILENO ? master : STDIN_FILENO;
        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        if (FD_ISSET(STDIN_FILENO, &rfds) && handle_stdin_frame(master) < 0)
            break;

        if (FD_ISSET(master, &rfds)) {
            uint8_t buf[4096];
            ssize_t n = read(master, buf, sizeof(buf));

            // n <= 0 happens when the child exits (EIO on Linux)
            if (n <= 0 || send_frame(buf, (size_t) n) < 0)
                break;
        }
    }

    close(master);
    kill(pid, SIGHUP);

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
