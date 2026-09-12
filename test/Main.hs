module Main (main) where
import Hsc2hs
import Hsc2hs.Object
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Control.Monad (unless)
import Data.List (isInfixOf)

assert :: String -> Bool -> IO ()
assert label ok = unless ok (error label)
main :: IO ()
main = do
  objectTests
  featureTests
  assert "escaped hash" (parse "x = ##x" == Right [Text 1 "x = #x"])
  assert "protected text" (parse "x = \"#bad\" -- #bad\n{- #bad {- x -} -}" == Right [Text 1 "x = \"#bad\" -- #bad\n{- #bad {- x -} -}"])
  assert "braced query" (parse "x=#{const (1 + 2)}" == Right [Text 1 "x=",Directive 1 "const" "(1 + 2)"])
  assert "bare query" (parse "(#const 3)" == Right [Text 1 "(",Directive 1 "const" "3",Text 1 ")"])
  assert "unterminated" (case parse "#{const 3" of Left _ -> True; _ -> False)
  assert "unknown format" (case decodeAnswers B.empty of Left _ -> True; _ -> False)
  assert "truncated ELF" (case decodeAnswers (B.pack [127,69,76,70]) of Left _ -> True; _ -> False)
  case prepare "T.hsc" "x = #{const -2}\n" of
    Left e -> error (show e)
    Right (_,p) -> do
      let a = M.fromList [(0,Answer 0 0),(1,Answer 0 0),(2,Answer 1 (-2)),(3,Answer 0 0)]
      assert "exact reconstruction" (finish p a == Right "{-# LINE 1 \"T.hsc\" #-}\nx = -2\n{-# LINE 2 \"T.hsc\" #-}\n")
      assert "sentinel required" (case finish p (M.delete 0 a) of Left _ -> True; _ -> False)
      assert "unknown ID" (case finish p (M.insert 99 (Answer 0 0) a) of Left _ -> True; _ -> False)
      assert "missing query" (case finish p (M.delete 2 a) of Left _ -> True; _ -> False)
  putStrLn "pure unit tests passed"

featureTests :: IO ()
featureTests = mapM_ check
  [ ("const -3", -3, "-3", "(-3)")
  , ("size int", 4, "(4)", "sizeof(int)")
  , ("alignment int", 4, "4", "offsetof(struct")
  , ("offset struct S, x", 8, "(8)", "offsetof(struct S, x)")
  , ("peek struct S, x", 8, "(\\hsc_ptr -> peekByteOff hsc_ptr 8)", "offsetof(struct S, x)")
  , ("poke struct S, x", 8, "(\\hsc_ptr -> pokeByteOff hsc_ptr 8)", "offsetof(struct S, x)")
  , ("ptr struct S, x", 8, "(\\hsc_ptr -> hsc_ptr `plusPtr` 8)", "offsetof(struct S, x)")
  , ("type unsigned int", 232, "Word32", "sizeof(unsigned int)")
  , ("type signed char", 108, "Int8", "sizeof(signed char)")
  , ("type double", 2, "Double", "sizeof(double)")
  ]
  where
    check (directive,value,expected,probeText) = case prepare "T.hsc" ("#{" ++ directive ++ "}") of
      Left e -> error (show e)
      Right (probe,plan) -> do
        assert (directive ++ " probe") (probeText `isInfixOf` probe)
        assert (directive ++ " output") (finish plan (M.fromList [(0,Answer 0 0),(1,Answer 1 value)]) == Right ("{-# LINE 1 \"T.hsc\" #-}\n" ++ expected))

-- Minimal independently constructed COFF containers exercise byte extraction,
-- signed values, metadata validation, and corrupt answer records.
coff :: [Int] -> Int -> B.ByteString
coff payload reloc = B.pack (map fromIntegral (header ++ section ++ payload))
  where
    le width value = [fromInteger ((value `div` (256^i)) `mod` 256) | i <- [0..width-1 :: Int]]
    header = [100,134,1,0] ++ replicate 16 0
    section = map fromEnum "aihc_ans" ++ replicate 8 0 ++ le 4 (toInteger (length payload)) ++ le 4 60 ++ replicate 8 0 ++ le 2 (toInteger reloc) ++ replicate 6 0

objectTests :: IO ()
objectTests = do
  let record = [72,83,67,1,7,0,0,0,1,1] ++ replicate 6 0 ++ [254] ++ replicate 7 255
      bad b = case decodeAnswers b of Left _ -> True; _ -> False
  assert "COFF signed payload" (decodeAnswers (coff record 0) == Right (M.singleton 7 (Answer 1 (-2))))
  assert "ELF little endian" (decodeAnswers (elf True record) == Right (M.singleton 7 (Answer 1 (-2))))
  assert "ELF big endian" (decodeAnswers (elf False record) == Right (M.singleton 7 (Answer 1 (-2))))
  assert "duplicate answer" (bad (coff (record ++ record) 0))
  assert "relocation rejected" (bad (coff record 1))
  assert "truncated record" (bad (coff (take 23 record) 0))
  assert "wrong version" (bad (coff (take 3 record ++ [2] ++ drop 4 record) 0))
  assert "invalid reserved bytes" (bad (coff (take 10 record ++ [1] ++ drop 11 record) 0))
  assert "all truncated prefixes" (all (bad . (`B.take` coff record 0)) [0..83])

elf :: Bool -> [Int] -> B.ByteString
elf little payload = B.pack (map fromIntegral (header ++ replicate 64 0 ++ namesSection ++ answerSection ++ strings ++ payload))
  where
    put fields = foldl (\b (off,width,value) -> take off b ++ encoded width value ++ drop (off+width) b) (replicate 64 0) fields
    encoded width value = let bytes = [fromInteger ((value `div` (256^i)) `mod` 256) | i <- [0..width-1 :: Int]] in if little then bytes else reverse bytes
    header = [127,69,76,70,2,if little then 1 else 2,1] ++ drop 7 (put [(16,2,1),(40,8,64),(52,2,64),(58,2,64),(60,2,3),(62,2,1)])
    strings = map fromEnum "\0.shstrtab\0aihc_ans\0"
    namesSection = put [(0,4,1),(4,4,3),(24,8,256),(32,8,toInteger (length strings))]
    answerSection = put [(0,4,11),(4,4,1),(24,8,toInteger (256+length strings)),(32,8,toInteger (length payload))]
