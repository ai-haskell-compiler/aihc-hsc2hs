module Conditions where
#include "layout.h"
#if SAMPLE_NUMBER == 42
x = #{const SAMPLE_NUMBER}
#else
x = 0
#endif
#ifndef UNDEFINED_NUMBER
#ifdef SAMPLE_NUMBER
y = #{size int}
#endif
#elif 1
y = 0
#endif
