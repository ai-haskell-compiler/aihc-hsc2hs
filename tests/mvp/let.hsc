module Lets where
#include "layout.h"
-- Upstream defines every #let in its header program, so a call may precede the
-- definition, as zeromq4-haskell does with the alignment fallback below.
early = #{alignment struct Sample}
-- The same, for a definition that the target's headers leave dead.
earlyDead = #{offset struct Sample, count}
-- The pre-GHC-8.0 alignment fallback: a #let that shadows a built-in template.
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
#let twice x = "%d", 2 * (x)
#let pair a, b = "(%d, %d)", (a), (b)
#let banner = "-- a #let without arguments"
#let padded x = "%08lx", (unsigned long)(x)
#let joined t = \
    "%lu", (unsigned long)sizeof(t)
#{banner}
shadowed = #{alignment struct Sample}
doubled = #{twice SAMPLE_NUMBER}
tuple = #{pair 3, MODE_READ_WRITE}
padded = #{padded SAMPLE_NUMBER}
joined = #{joined struct Sample}
bare = #twice 5
#if SAMPLE_NUMBER == 0
#let size t = "%d", 1
#let offset t = "%d", 1
#endif
-- The definition above is dead, so this stays the built-in #size.
unshadowed = #{size struct Sample}
