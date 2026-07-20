#include <stdint.h>
#include <stddef.h>
extern "C" {
#include "vuln_lib.h"
}
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    process_data(Data, Size);
    return 0;
}
