#ifndef LibraryWriterLockShim_h
#define LibraryWriterLockShim_h

#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>

/// Swift's Darwin overlay exposes `struct flock` under the same name as the
/// BSD `flock(2)` function. Keep the C boundary explicit and type checked.
static inline int kmgccc_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}

#endif /* LibraryWriterLockShim_h */
