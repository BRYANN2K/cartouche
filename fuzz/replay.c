// Runs a harness over the files named on the command line, once each, without libFuzzer
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { perror(argv[i]); return 1; }
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        uint8_t *buf = malloc(len > 0 ? (size_t)len : 1);
        if (!buf || (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len)) {
            fprintf(stderr, "%s: cannot read\n", argv[i]);
            return 1;
        }
        fclose(f);
        LLVMFuzzerTestOneInput(buf, (size_t)len);
        free(buf);
    }
    return 0;
}
