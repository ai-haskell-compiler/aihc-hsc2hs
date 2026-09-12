module Pointers where
#include "layout.h"
import Foreign.Ptr
countPtr = #{ptr struct Sample, count}
