#include <stddef.h>
#include "layout.h"
_Static_assert(sizeof(struct Sample) >= sizeof(double), "invalid layout");
int aihc_preflight;
