import Darwin

enum FileLock {
    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
