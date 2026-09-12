module Numeric where
#include <stddef.h>
pointerSize :: Int
pointerSize = #{size void *}
intSize :: Int
intSize = #{size int}
answer :: Int
answer = #{const 42}
