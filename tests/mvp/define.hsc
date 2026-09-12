module Defines where
#define LOCAL 7
#define DISCARDED 1
#undef DISCARDED
x = #{const LOCAL}
#ifndef DISCARDED
y = 1
#endif
