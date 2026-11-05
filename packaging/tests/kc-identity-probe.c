// Writes, reads and deletes one dedicated generic-password item in the login
// keychain, the same item shape the app uses (Secrets.swift). The item's ACL is
// left to the system: the creating build is trusted by its designated
// requirement, so a later build signed with the same certificate reads the item
// without a prompt while a different signature is asked.
//
//   kc-identity-probe write <value> | read | delete
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>

static CFStringRef kService = CFSTR("dev.bryann2k.cartouche.k2proof");
static CFStringRef kAccount = CFSTR("builds");

static CFMutableDictionaryRef baseQuery(void) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(q, kSecAttrService, kService);
    CFDictionarySetValue(q, kSecAttrAccount, kAccount);
    return q;
}

static int fail(const char *what, OSStatus st) {
    fprintf(stderr, "kc-identity-probe: %s: %d\n", what, (int)st);
    return 1;
}

static int writeItem(const char *value) {
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)value, (CFIndex)strlen(value));
    CFMutableDictionaryRef q = baseQuery();
    CFDictionarySetValue(q, kSecValueData, data);
    CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
    OSStatus st = SecItemAdd(q, NULL);
    if (st == errSecDuplicateItem) {
        CFMutableDictionaryRef update = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(update, kSecValueData, data);
        CFMutableDictionaryRef match = baseQuery();
        st = SecItemUpdate(match, update);
        CFRelease(match);
        CFRelease(update);
    }
    CFRelease(data);
    CFRelease(q);
    if (st != errSecSuccess) return fail("write", st);
    printf("%s\n", value);
    return 0;
}

static int readItem(void) {
    CFMutableDictionaryRef q = baseQuery();
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching(q, &result);
    CFRelease(q);
    if (st != errSecSuccess) return fail("read", st);
    CFDataRef data = (CFDataRef)result;
    printf("%.*s\n", (int)CFDataGetLength(data), (const char *)CFDataGetBytePtr(data));
    CFRelease(result);
    return 0;
}

static int deleteItem(void) {
    CFMutableDictionaryRef q = baseQuery();
    OSStatus st = SecItemDelete(q);
    CFRelease(q);
    if (st != errSecSuccess && st != errSecItemNotFound) return fail("delete", st);
    return 0;
}

// KC_TAG differs per build so two binaries never share a cdhash.
#ifndef KC_TAG
#define KC_TAG "base"
#endif
static const char kBuildTag[] = KC_TAG;

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s write <value> | read | delete\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "tag") == 0) {
        puts(kBuildTag);
        return 0;
    }
    if (strcmp(argv[1], "write") == 0 && argc == 3) return writeItem(argv[2]);
    if (strcmp(argv[1], "read") == 0) return readItem();
    if (strcmp(argv[1], "delete") == 0) return deleteItem();
    fprintf(stderr, "usage: %s write <value> | read | delete\n", argv[0]);
    return 2;
}
