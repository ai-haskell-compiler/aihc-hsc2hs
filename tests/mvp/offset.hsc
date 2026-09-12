module Offsets where
#include "layout.h"
a = #{offset struct Sample, count}
b = #{offset struct Packed, count}
