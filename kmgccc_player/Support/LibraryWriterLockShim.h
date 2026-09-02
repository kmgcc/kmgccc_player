#ifndef LibraryWriterLockShim_h
#define LibraryWriterLockShim_h

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

/// Swift's Darwin overlay exposes `struct flock` under the same name as the
/// BSD `flock(2)` function. Keep the C boundary explicit and type checked.
static inline int kmgccc_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}

/// Returns 0 only when an independently opened descriptor in a child process
/// observes the parent's lock. All child-side operations are async-signal-safe.
static inline int kmgccc_verify_flock_exclusion(const char *path) {
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return 2;
    }

    pid_t child = fork();
    if (child == 0) {
        close(descriptors[0]);
        uint8_t result = 2;
        int probe = open(path, O_RDWR | O_CLOEXEC);
        if (probe >= 0) {
            if (flock(probe, LOCK_EX | LOCK_NB) == 0) {
                result = 1;
                flock(probe, LOCK_UN);
            } else if (errno == EWOULDBLOCK || errno == EAGAIN) {
                result = 0;
            }
            close(probe);
        }
        (void)write(descriptors[1], &result, sizeof(result));
        close(descriptors[1]);
        _exit(0);
    }

    close(descriptors[1]);
    if (child < 0) {
        close(descriptors[0]);
        return 2;
    }

    uint8_t result = 2;
    ssize_t count = read(descriptors[0], &result, sizeof(result));
    close(descriptors[0]);
    int status = 0;
    pid_t waited = waitpid(child, &status, 0);
    return waited == child && count == (ssize_t)sizeof(result) && result == 0 ? 0 : 2;
}

#endif /* LibraryWriterLockShim_h */
