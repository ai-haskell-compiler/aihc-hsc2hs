module Syntax where
-- #ignored
{- nested {- #ignored -} comment -}
s = "#ignored"
f' = #{const (1 + \
 2)} + #{const 4}
g = (#const 9)
