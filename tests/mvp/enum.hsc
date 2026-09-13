module Enums where
#include "layout.h"
#{enum Count, Count, SAMPLE_NUMBER}
#{enum Count, Count, sampleShift = (SAMPLE_NUMBER << 1), MODE_READ_WRITE}
#{enum   Count  ,  Count  , wideMax = 18446744073709551615ULL}
#{enum Count, Count, negative = -9223372036854775807LL - 1}
#{enum Count, fromIntegral, colourGreen = COLOUR_GREEN}
#if SAMPLE_NUMBER == 42
#{enum Count, Count, activeOnly = SAMPLE_NUMBER}
#else
#{enum Count, Count, inactiveOnly = SAMPLE_NUMBER}
#endif
#{enum Count}
trailer = #{const SAMPLE_NUMBER}
