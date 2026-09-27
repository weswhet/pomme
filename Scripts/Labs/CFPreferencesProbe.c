/*
 * Disposable macOS 26 lab probe; not part of the Pomme agent or startup path.
 * Build with native clang and -framework CoreFoundation; sign before transfer.
 * Run through the guest agent as: sudo -n -H -u pomme PROBE write
 * Then start a separate process: sudo -n -H -u pomme PROBE verify
 * No passwords, arbitrary preference domains, or cleanup actions are accepted.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int fail(const char *stage, const char *reason) {
    fprintf(stderr, "error stage=%s reason=%s\n", stage, reason);
    return 1;
}

static const char *type_name(CFTypeRef value) {
    if (!value) return "missing";
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) return "CFString";
    if (type == CFBooleanGetTypeID()) return "CFBoolean";
    if (type == CFNumberGetTypeID()) return "CFNumber";
    if (type == CFArrayGetTypeID()) return "CFArray";
    if (type == CFDictionaryGetTypeID()) return "CFDictionary";
    if (type == CFDataGetTypeID()) return "CFData";
    if (type == CFDateGetTypeID()) return "CFDate";
    return "other";
}

static int preference(bool write, const char *label, CFStringRef domain,
                      CFStringRef key, CFTypeRef expected) {
    if (write) {
        /* SetValue is void: synchronization and typed readback establish success. */
        CFPreferencesSetValue(key, expected, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        printf("stage=%s action=set expectedType=%s\n", label, type_name(expected));
    }
    Boolean synchronized = CFPreferencesSynchronize(
        domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    printf("stage=%s action=synchronize success=%s scope=currentUser/anyHost\n",
           label, synchronized ? "true" : "false");
    if (!synchronized) return fail(label, "CFPreferencesSynchronize-returned-false");

    CFPropertyListRef actual = CFPreferencesCopyValue(
        key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    bool matching_type = actual && CFGetTypeID(actual) == CFGetTypeID(expected);
    bool matching_value = matching_type && CFEqual(actual, expected);
    printf("stage=%s action=readback actualType=%s actualTypeID=%lu "
           "expectedType=%s expectedTypeID=%lu typeMatches=%s valueMatches=%s\n",
           label, type_name(actual), actual ? (unsigned long)CFGetTypeID(actual) : 0,
           type_name(expected), (unsigned long)CFGetTypeID(expected),
           matching_type ? "true" : "false", matching_value ? "true" : "false");
    if (actual) CFRelease(actual);
    if (!matching_type) return fail(label, "readback-type-mismatch-or-missing");
    if (!matching_value) return fail(label, "readback-value-mismatch");
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2 || (strcmp(argv[1], "write") && strcmp(argv[1], "verify"))) {
        fprintf(stderr, "Usage: CFPreferencesProbe write|verify\n");
        return 2;
    }
    bool write = strcmp(argv[1], "write") == 0;
    errno = 0;
    struct passwd *owner = getpwnam("pomme");
    if (!owner) {
        fprintf(stderr, "error stage=context reason=owner-lookup-failed errno=%d\n", errno);
        return 1;
    }
    const char *home = getenv("HOME");
    bool home_matches = home && strcmp(home, "/Users/pomme") == 0;
    bool account_home_matches = owner->pw_dir && strcmp(owner->pw_dir, "/Users/pomme") == 0;
    printf("stage=context uid=%lu euid=%lu ownerUID=%lu homeMatches=%s accountHomeMatches=%s\n",
           (unsigned long)getuid(), (unsigned long)geteuid(), (unsigned long)owner->pw_uid,
           home_matches ? "true" : "false", account_home_matches ? "true" : "false");
    if (owner->pw_uid == 0 || getuid() != owner->pw_uid || geteuid() != owner->pw_uid)
        return fail("context", "must-run-as-nonroot-pomme-owner");
    if (!home_matches || !account_home_matches)
        return fail("context", "owner-home-must-be-/Users/pomme");

    char build[128] = {0};
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) {
        fprintf(stderr, "error stage=context reason=kern.osversion-read-failed errno=%d\n", errno);
        return 1;
    }
    if (size == 0 || size > sizeof(build) || !memchr(build, '\0', size))
        return fail("context", "kern.osversion-invalid-string");
    if (strcmp(build, "25G83") != 0)
        return fail("context", "guest-build-must-be-25G83");
    printf("stage=context mode=%s home=/Users/pomme guestBuild=25G83\n", argv[1]);

    CFStringRef build_value = CFStringCreateWithCString(NULL, build, kCFStringEncodingUTF8);
    if (!build_value) return fail("setupAssistant", "build-string-allocation-failed");
    int result = preference(write, "com.apple.SetupAssistant/LastSeenBuddyBuildVersion",
                            CFSTR("com.apple.SetupAssistant"),
                            CFSTR("LastSeenBuddyBuildVersion"), build_value);
    CFRelease(build_value);
    if (result) return result;
    result = preference(write, "com.apple.loginwindow/MiniBuddyLaunch",
                        CFSTR("com.apple.loginwindow"), CFSTR("MiniBuddyLaunch"),
                        kCFBooleanFalse);
    if (result) return result;
    printf("stage=complete mode=%s success=true\n", argv[1]);
    return 0;
}
