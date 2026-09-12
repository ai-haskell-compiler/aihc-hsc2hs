module Peeks where
#include "layout.h"
import Foreign.Storable
readCount = #{peek struct Sample, count}
