#include "vuln_lib.h"
#include <string.h>

/* Internal helper: validate that data pointer is usable */
static int validate_input(const uint8_t *data, size_t size) {
    if (data == NULL) return 0;
    if (size == 0) return 0;
    return 1;
}

int process_data(const uint8_t *data, size_t size) {
    if (!validate_input(data, size)) return 0;
    if (size < 3) return 0;
    if (data[0] == 'B' &&
        data[1] == 'U' &&
        data[2] == 'G' &&
        data[3] == '!')
    {
        return 1;
    }
    return 0;
}
