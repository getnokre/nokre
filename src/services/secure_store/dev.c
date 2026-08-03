// The dev file store: a fifth backend behind the same four verbs
// (secure_store.h), compiled *instead of* the platform one when a build
// declares `.secure_store_dev`. It exists for the binary neither of the
// other stores was designed for — an executable that drives a real app
// and is not a shipped app:
//
//   * macOS refuses the data-protection keychain to an unentitled
//     process. SecItemAdd there answers errSecMissingEntitlement
//     (-34018) from an ad-hoc/linker-signed binary — measured, and the
//     reason ad-hoc signing the entitlement *in* is no way out either
//     (the process is SIGKILLed at launch). What keeps such a binary
//     working today is the legacy file keychain the Apple leg falls back
//     to, which macos.m's own comments and ../../../docs/services.md call
//     dev-only posture rather than contract: it is deprecated, macOS-only,
//     it is the developer's real login keychain, and its per-item ACL
//     binds to a signature that changes on every rebuild — so it can
//     raise a modal the synchronous API blocks the thread behind.
//   * A headless Linux machine — CI — runs no Secret Service daemon at
//     all, so libsecret has nothing to talk to and every verb answers
//     Unavailable. There is no fallback there.
//
// So the dev store is not "the store that works where none does"; it is
// the store a driver should be using instead of a deprecated layer of
// someone's login keychain: named by the build, isolated per run
// ($NOKRE_SECURE_STORE_DEV), shared with nothing, and unable to prompt.
// `zig test` never needs it (there a service *is* its mock) and a shipped
// app never reaches it (build.zig's gates), which leaves exactly the tier
// docs/testing.md's "where the harness stops" says nokre owes its own
// side. Windows has no such gap: Credential Manager answers any process
// in a logon session, so there is no dev store there and build.zig
// refuses to build one.
//
// Nothing here is encrypted, and the name says so at every level — the
// build flag, the directory, and one line on stderr at process start. The
// gates that keep it out of a shipping build are build.zig's (Debug only,
// macOS and desktop Linux only, and never implicitly); this file's job is
// to be unmistakable if one ever failed.
//
// The charter is unchanged: thin, stateless, synchronous. Every policy —
// validation, caps, sort order, the entry-count line — already ran
// Zig-side, so the dev store enforces the same contract as a keychain by
// construction: it is behind the same four verbs, and the Zig above it is
// the same Zig.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdlib.h>
#include <unistd.h>

#include "secure_store.h"

enum {
    NOKRE_SS_DEV_PATH_CAP = 1024, // macOS' PATH_MAX; a store path past it is out of contract
    NOKRE_SS_DEV_REC_HEADER = 3,  // [key_len:u8][value_len:u16 little-endian]
};

// 16 bytes, no NUL (a C array initializer drops it): the file's own
// claim to be one of these. A file that does not open with it belongs to
// something else, and every verb refuses rather than parsing — let alone
// overwriting — a stranger's bytes.
static const char nokre_ss_dev_magic[16] = "nokre-dev-store\x01";

// One line, at process start rather than at first use, so a binary that
// carries this store says so even on the run that never touches it —
// and so the file itself holds nothing between calls, which is the
// native side's charter.
__attribute__((constructor)) static void nokre_ss_dev_announce(void) {
    fprintf(stderr,
            "nokre: secure_store is the DEV FILE STORE — plaintext in "
            "$NOKRE_SECURE_STORE_DEV or $HOME/.nokre-dev-store, not the OS "
            "keychain. Built with .secure_store_dev: a driver's binary, "
            "never a shipping one.\n");
}

// The file this namespace's store lives in. $NOKRE_SECURE_STORE_DEV names
// it outright — one driver run, one store, wherever the run wants it,
// which is how a driver gets a store no previous run can have touched.
// Otherwise it is $HOME/.nokre-dev-store/<ns>: one directory, named for
// what it is, sitting where a developer can find it and delete it. With
// neither there is no file and every verb answers UNAVAILABLE — the same
// answer a locked keychain gives, and one every consumer already handles.
// Returns 0 when no path could be composed.
static int nokre_ss_dev_path(const uint8_t *ns, size_t ns_len, char *out, size_t cap, int make_dir) {
    const char *override = getenv("NOKRE_SECURE_STORE_DEV");
    if (override != NULL && override[0] != 0) {
        size_t n = strlen(override);
        if (n + 1 > cap) return 0;
        memcpy(out, override, n + 1);
        return 1;
    }
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == 0) return 0;
    static const char dir[] = "/.nokre-dev-store";
    size_t home_len = strlen(home);
    size_t dir_len = home_len + sizeof(dir) - 1;
    // dir + '/' + ns + NUL
    if (dir_len + 1 + ns_len + 1 > cap) return 0;
    memcpy(out, home, home_len);
    memcpy(out + home_len, dir, sizeof(dir) - 1);
    if (make_dir) {
        out[dir_len] = 0;
        if (mkdir(out, 0700) != 0 && errno != EEXIST) return 0;
    }
    out[dir_len] = '/';
    // ns is the app's reverse-DNS id, composed at comptime from the
    // build's declaration — it carries no separator, so the join cannot
    // escape the directory.
    memcpy(out + dir_len + 1, ns, ns_len);
    out[dir_len + 1 + ns_len] = 0;
    return 1;
}

// 1 = all n bytes read, 0 = clean EOF before any of them, -1 = short or failed.
static int nokre_ss_dev_read(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return got == 0 ? 0 : -1;
        got += (size_t)r;
    }
    return 1;
}

static int nokre_ss_dev_write(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        put += (size_t)w;
    }
    return 1;
}

// Opens the store for reading, past the magic. 1 = open in *fd, 0 = no
// store yet (a fresh install: every verb treats it as empty, the way a
// keychain's errSecItemNotFound is treated), -1 = present but unreadable
// or not ours.
static int nokre_ss_dev_open(const char *path, int *fd) {
    int f = open(path, O_RDONLY | O_CLOEXEC);
    if (f < 0) return errno == ENOENT ? 0 : -1;
    char magic[sizeof(nokre_ss_dev_magic)];
    int r = nokre_ss_dev_read(f, magic, sizeof(magic));
    if (r == 0) { // an empty file is a store nothing was ever written to
        close(f);
        return 0;
    }
    if (r < 0 || memcmp(magic, nokre_ss_dev_magic, sizeof(magic)) != 0) {
        close(f);
        return -1;
    }
    *fd = f;
    return 1;
}

// One record's header. 1 = read, 0 = clean end of file, -1 = malformed.
// Out-of-contract lengths are malformed rather than skippable: this file
// format is nokre's own and nothing but this backend writes it, so a
// record the caps could not have produced means the bytes are not what
// they claim — and a store that lies is worse than one that refuses.
static int nokre_ss_dev_header(int fd, size_t *key_len, size_t *value_len) {
    uint8_t head[NOKRE_SS_DEV_REC_HEADER];
    int r = nokre_ss_dev_read(fd, head, sizeof(head));
    if (r <= 0) return r;
    size_t k = head[0];
    size_t v = (size_t)head[1] | ((size_t)head[2] << 8);
    if (k == 0 || k > NOKRE_SS_MAX_KEY_BYTES || v > NOKRE_SS_MAX_VALUE_BYTES) return -1;
    *key_len = k;
    *value_len = v;
    return 1;
}

int32_t nokre_ss_get(const uint8_t *ns, size_t ns_len,
                     const uint8_t *key, size_t key_len,
                     uint8_t *value_buf, size_t *value_len) {
    char path[NOKRE_SS_DEV_PATH_CAP];
    if (!nokre_ss_dev_path(ns, ns_len, path, sizeof(path), 0)) return NOKRE_SS_ERR_UNAVAILABLE;
    int fd = -1;
    int opened = nokre_ss_dev_open(path, &fd);
    if (opened == 0) return NOKRE_SS_ABSENT; // no store yet: absence, not failure
    if (opened < 0) return NOKRE_SS_ERR_UNAVAILABLE;
    int32_t rc = NOKRE_SS_ABSENT;
    for (;;) {
        size_t k_len, v_len;
        int r = nokre_ss_dev_header(fd, &k_len, &v_len);
        if (r == 0) break;
        if (r < 0) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        uint8_t k[NOKRE_SS_MAX_KEY_BYTES];
        if (nokre_ss_dev_read(fd, k, k_len) != 1) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        if (k_len != key_len || memcmp(k, key, k_len) != 0) {
            if (lseek(fd, (off_t)v_len, SEEK_CUR) < 0) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
            continue;
        }
        // The in/out capacity is always the Zig side's max_value_bytes and
        // the header already refused anything past it, so this cannot
        // truncate — the check stands anyway, because the contract says
        // a value that will not fit is UNAVAILABLE and never short bytes.
        if (v_len > *value_len) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        if (v_len != 0 && nokre_ss_dev_read(fd, value_buf, v_len) != 1) {
            rc = NOKRE_SS_ERR_UNAVAILABLE;
            break;
        }
        *value_len = v_len; // an empty value is a present, empty value
        rc = NOKRE_SS_OK;
        break;
    }
    close(fd);
    return rc;
}

// set and delete are one function: both rewrite the whole file into a
// sibling temp and rename it over, which is the atomic upsert CredWriteW
// and SecItemUpdate give for free. A crash leaves either the old file or
// the new one, never half a store. Two processes writing the same
// namespace at once is last-writer-wins — no worse than the
// enumerate-then-set the Zig side already documents as non-atomic, and a
// dev store has one driver.
static int32_t nokre_ss_dev_rewrite(const uint8_t *ns, size_t ns_len,
                                    const uint8_t *key, size_t key_len,
                                    const uint8_t *value, size_t value_len,
                                    int inserting) {
    char path[NOKRE_SS_DEV_PATH_CAP];
    char tmp[NOKRE_SS_DEV_PATH_CAP + 8];
    if (!nokre_ss_dev_path(ns, ns_len, path, sizeof(path), 1)) return NOKRE_SS_ERR_UNAVAILABLE;
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return NOKRE_SS_ERR_UNAVAILABLE;

    int src = -1;
    int opened = nokre_ss_dev_open(path, &src);
    if (opened < 0) return NOKRE_SS_ERR_UNAVAILABLE; // not ours: never overwritten

    // 0600: the file's protection boundary is the user's own account,
    // which is the same boundary DPAPI and a login keyring give — and the
    // only one a plaintext file can honestly claim.
    int dst = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (dst < 0) {
        if (opened == 1) close(src);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }

    int32_t rc = NOKRE_SS_OK;
    if (!nokre_ss_dev_write(dst, nokre_ss_dev_magic, sizeof(nokre_ss_dev_magic)))
        rc = NOKRE_SS_ERR_UNAVAILABLE;
    while (rc == NOKRE_SS_OK && opened == 1) {
        size_t k_len, v_len;
        int r = nokre_ss_dev_header(src, &k_len, &v_len);
        if (r == 0) break;
        if (r < 0) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        uint8_t k[NOKRE_SS_MAX_KEY_BYTES];
        uint8_t v[NOKRE_SS_MAX_VALUE_BYTES];
        if (nokre_ss_dev_read(src, k, k_len) != 1) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        if (v_len != 0 && nokre_ss_dev_read(src, v, v_len) != 1) { rc = NOKRE_SS_ERR_UNAVAILABLE; break; }
        // The target key is dropped here and re-appended below when
        // inserting: an upsert, and for delete the postcondition itself.
        if (k_len == key_len && memcmp(k, key, k_len) == 0) continue;
        uint8_t head[NOKRE_SS_DEV_REC_HEADER] = {
            (uint8_t)k_len, (uint8_t)(v_len & 0xFF), (uint8_t)(v_len >> 8)};
        if (!nokre_ss_dev_write(dst, head, sizeof(head)) ||
            !nokre_ss_dev_write(dst, k, k_len) ||
            (v_len != 0 && !nokre_ss_dev_write(dst, v, v_len))) {
            rc = NOKRE_SS_ERR_UNAVAILABLE;
            break;
        }
    }
    if (rc == NOKRE_SS_OK && inserting) {
        uint8_t head[NOKRE_SS_DEV_REC_HEADER] = {
            (uint8_t)key_len, (uint8_t)(value_len & 0xFF), (uint8_t)(value_len >> 8)};
        if (!nokre_ss_dev_write(dst, head, sizeof(head)) ||
            !nokre_ss_dev_write(dst, key, key_len) ||
            (value_len != 0 && !nokre_ss_dev_write(dst, value, value_len)))
            rc = NOKRE_SS_ERR_UNAVAILABLE;
    }
    if (opened == 1) close(src);
    if (close(dst) != 0) rc = NOKRE_SS_ERR_UNAVAILABLE;
    if (rc == NOKRE_SS_OK && rename(tmp, path) != 0) rc = NOKRE_SS_ERR_UNAVAILABLE;
    if (rc != NOKRE_SS_OK) unlink(tmp);
    return rc;
}

int32_t nokre_ss_set(const uint8_t *ns, size_t ns_len,
                     const uint8_t *key, size_t key_len,
                     const uint8_t *value, size_t value_len) {
    if (key_len == 0 || key_len > NOKRE_SS_MAX_KEY_BYTES ||
        value_len > NOKRE_SS_MAX_VALUE_BYTES)
        return NOKRE_SS_ERR_UNAVAILABLE; // the Zig side refused these already
    return nokre_ss_dev_rewrite(ns, ns_len, key, key_len, value, value_len, 1);
}

int32_t nokre_ss_delete(const uint8_t *ns, size_t ns_len,
                        const uint8_t *key, size_t key_len) {
    if (key_len == 0 || key_len > NOKRE_SS_MAX_KEY_BYTES) return NOKRE_SS_ERR_UNAVAILABLE;
    // Idempotent: rewriting a store the key was never in leaves the same
    // postcondition, so an absent key is OK, never a failure.
    return nokre_ss_dev_rewrite(ns, ns_len, key, key_len, NULL, 0, 0);
}

int32_t nokre_ss_list(const uint8_t *ns, size_t ns_len,
                      uint8_t *list_buf, size_t list_cap) {
    char path[NOKRE_SS_DEV_PATH_CAP];
    if (!nokre_ss_dev_path(ns, ns_len, path, sizeof(path), 0)) return NOKRE_SS_ERR_UNAVAILABLE;
    int fd = -1;
    int opened = nokre_ss_dev_open(path, &fd);
    if (opened == 0) return 0; // a fresh install enumerates to nothing
    if (opened < 0) return NOKRE_SS_ERR_UNAVAILABLE;
    int32_t n = 0;
    size_t off = 0;
    for (;;) {
        size_t k_len, v_len;
        int r = nokre_ss_dev_header(fd, &k_len, &v_len);
        if (r == 0) break;
        if (r < 0) { n = NOKRE_SS_ERR_UNAVAILABLE; break; }
        // Past capacity the subset is unspecified: stop, no error — the
        // determinism bound the other backends state.
        if (off + 1 + k_len > list_cap) break;
        if (nokre_ss_dev_read(fd, list_buf + off + 1, k_len) != 1) {
            n = NOKRE_SS_ERR_UNAVAILABLE;
            break;
        }
        list_buf[off] = (uint8_t)k_len;
        off += 1 + k_len;
        n += 1;
        if (lseek(fd, (off_t)v_len, SEEK_CUR) < 0) { n = NOKRE_SS_ERR_UNAVAILABLE; break; }
    }
    close(fd);
    return n;
}
