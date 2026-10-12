#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef OG_PROGRAM
#error OG_PROGRAM must name the packaged executable
#endif
#ifndef OG_STATIC_PREFIX
#define OG_STATIC_PREFIX ""
#endif

typedef const char *(*libroot_prefix_function)(void);

static int join_path(char output[PATH_MAX], const char *prefix, const char *suffix) {
    int length = snprintf(output, PATH_MAX, "%s%s", prefix, suffix);
    return length > 0 && length < PATH_MAX;
}

static const char *bootstrap_prefix(void) {
    static char resolved[PATH_MAX];
    const char *configured = OG_STATIC_PREFIX;
    if (configured[0]) return configured;
    void *handle = dlopen("@executable_path/../lib/libroot.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;
    libroot_prefix_function get_prefix =
        (libroot_prefix_function)dlsym(handle, "libroot_get_jbroot_prefix");
    if (!get_prefix) return NULL;
    const char *prefix = get_prefix();
    if (!prefix || prefix[0] != '/') return NULL;
    size_t length = strlen(prefix);
    while (length > 1 && prefix[length - 1] == '/') length--;
    if (length >= sizeof(resolved)) return NULL;
    memcpy(resolved, prefix, length);
    resolved[length] = 0;
    return resolved;
}

static void configure_environment(const char *prefix) {
    const char *current = getenv("PATH");
    char *path = NULL;
    if (asprintf(&path, "%s/usr/local/bin:%s/usr/bin:%s/bin:%s/usr/sbin:%s/sbin%s%s",
                 prefix, prefix, prefix, prefix, prefix,
                 current && current[0] ? ":" : "", current && current[0] ? current : "") >= 0) {
        setenv("PATH", path, 1);
        free(path);
    }
    const char *shell = getenv("SHELL");
    char candidate[PATH_MAX];
    if (shell && (strncmp(shell, "/bin/", 5) == 0 || strncmp(shell, "/usr/bin/", 9) == 0) &&
        join_path(candidate, prefix, shell)) setenv("SHELL", candidate, 1);
    if (!getenv("SSL_CERT_FILE")) {
        const char *certificates[] = {"/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"};
        for (size_t index = 0; index < 2; index++) {
            if (join_path(candidate, prefix, certificates[index]) && access(candidate, R_OK) == 0) {
                setenv("SSL_CERT_FILE", candidate, 1);
                break;
            }
        }
    }
    if (!getenv("BROWSER") && join_path(candidate, prefix, "/usr/bin/uiopen") &&
        access(candidate, X_OK) == 0) setenv("BROWSER", candidate, 1);
}

int main(int argc, char **argv) {
    const char *prefix = bootstrap_prefix();
    if (!prefix) {
        fprintf(stderr, "%s: cannot resolve the jailbreak bootstrap with libroot\n", OG_PROGRAM);
        return 127;
    }
    configure_environment(prefix);
    char executable[PATH_MAX];
    if (!join_path(executable, prefix, "/usr/libexec/" OG_PROGRAM "/" OG_PROGRAM)) return 127;
    /* iOS cannot safely share the upstream background daemon. Keep the
       option before user arguments, including any end-of-options marker. */
    int has_no_daemon = 0;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--") == 0) break;
        if (strcmp(argv[index], "--no-daemon") == 0) has_no_daemon = 1;
    }
    char **arguments = calloc((size_t)argc + 2, sizeof(*arguments));
    if (!arguments) {
        fprintf(stderr, "%s: cannot allocate launch arguments\n", OG_PROGRAM);
        return 126;
    }
    arguments[0] = executable;
    int next = 1;
    if (!has_no_daemon) arguments[next++] = "--no-daemon";
    for (int index = 1; index < argc; index++) arguments[next++] = argv[index];
    execv(executable, arguments);
    int error = errno;
    free(arguments);
    fprintf(stderr, "%s: cannot execute %s: %s\n", OG_PROGRAM, executable, strerror(error));
    return error == ENOENT ? 127 : 126;
}
