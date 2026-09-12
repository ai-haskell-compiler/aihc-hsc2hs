module Pokes where
#include "layout.h"
import Foreign.Storable
writeCount = #{poke struct Sample, count}
