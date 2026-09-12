module Custom where
#let twice x = "%d", 2 * (x)
value :: Int
value = #{twice 21}
