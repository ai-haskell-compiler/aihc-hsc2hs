module Main (main) where
import Hsc2hs
import Hsc2hs.Object
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Control.Monad (unless)
import Data.List (isInfixOf, isPrefixOf)

assert :: String -> Bool -> IO ()
assert label ok = unless ok (error label)
main :: IO ()
main = do
  assert "CR removal precedes parsing" (parse "a\rb\r\nc = #{const 1\\\r\n + 2}\r\n" == parse "ab\nc = #{const 1\\\n + 2}\n")
  objectTests
  featureTests
  enumTests
  constStrTests
  letTests
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

-- #const_str owns a length query plus fixed-width byte chunks, and its escaping
-- must reproduce template-hsc.h byte for byte.
constStrTests :: IO ()
constStrTests = do
  case prepare "T.hsc" "x = #{const_str FOO}\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      assert "const_str names its argument once" ("#define aihc_str_2 (FOO)\n" `isInfixOf` probe)
      assert "const_str guards template overrides" ("#ifdef hsc_const_str" `isInfixOf` probe)
      assert "const_str rejects runtime pointers" ("AIHC_UNSUPPORTED_non_constant_string" `isInfixOf` probe)
      assert "const_str bounds the length" ("AIHC_UNSUPPORTED_string_length" `isInfixOf` probe)
      assert "const_str clamps its reads" ("AIHC_BYTE(aihc_str_2,255)" `isInfixOf` probe)
      -- "a\"b\\c\1\&9z\255": escaping, the \& separator and a chunk boundary.
      let bytes = [97,34,98,92,99,1,57,122,255]
          answers = M.fromList ([(0,Answer 0 0),(1,Answer 0 0),(2,Answer 1 (toInteger (length bytes)))] ++
                                chunks 3 bytes ++ [(35,Answer 0 0)])
          output = "{-# LINE 1 \"T.hsc\" #-}\nx = \"a\\\"b\\\\c\\1\\&9z\\255\"\n{-# LINE 2 \"T.hsc\" #-}\n"
      assert "const_str output" (finish plan answers == Right output)
      assert "const_str missing chunk" (case finish plan (M.delete 20 answers) of Left _ -> True; _ -> False)
      assert "const_str chunk kind" (case finish plan (M.insert 20 (Answer 0 0) answers) of Left _ -> True; _ -> False)
      assert "const_str length beyond capacity"
        (case finish plan (M.insert 2 (Answer 1 257) answers) of Left _ -> True; _ -> False)
      assert "const_str empty string"
        (finish plan (M.insert 2 (Answer 1 0) answers) ==
         Right "{-# LINE 1 \"T.hsc\" #-}\nx = \"\"\n{-# LINE 2 \"T.hsc\" #-}\n")
  case prepare "T.hsc" "x = #{const_str (\"a\"\n \"b\")}\n" of
    Left e -> error (show e)
    Right (probe,_) ->
      assert "const_str continues a multi-line argument"
        ("#define aihc_str_2 ((\"a\"\\\n \"b\"))\n" `isInfixOf` probe)
  -- An inactive branch must drop the directive, byte chunks included.
  case prepare "T.hsc" "#if 0\n#{const_str FOO}\n#endif\n" of
    Left e -> error (show e)
    Right (_,plan) -> do
      let inactive = M.fromList [(0,Answer 0 0),(37,Answer 0 0),(38,Answer 0 0)]
      assert "inactive const_str"
        (finish plan inactive == Right "{-# LINE 1 \"T.hsc\" #-}\n\n{-# LINE 4 \"T.hsc\" #-}\n")
      assert "inactive const_str chunk"
        (case finish plan (M.insert 4 (Answer 1 65) inactive) of Left _ -> True; _ -> False)

-- Pack bytes into the eight-byte value field of consecutive chunk records, the
-- way the probe lays them out. Trailing chunks answer with the clamped byte.
chunks :: Int -> [Int] -> [(Int, Answer)]
chunks first bytes =
  [ (first + i, Answer 1 (sum [toInteger b * 256^k | (k,b) <- zip [0 :: Int ..] (group i)]))
  | i <- [0 .. 31] ]
  where
    group i = take 8 (drop (8*i) bytes ++ repeat (case bytes of b:_ -> b; [] -> 0))
-- A #let call carries both readings of the directive: the template's own and
-- the built-in it shadows. Only the C preprocessor knows which one is live.
letTests :: IO ()
letTests = do
  case prepare "T.hsc" "#let twice x = \"%d twice\", 2 * (x)\nv = #{twice 21}\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      assert "let defines an expression macro"
        ("#define aihc_let_twice_0(x) (2 * (x))" `isInfixOf` probe)
      assert "let marks its own definedness" ("#define aihc_let_defined_twice 1" `isInfixOf` probe)
      assert "let call substitutes through the C preprocessor"
        ("aihc_let_twice_0(21)" `isInfixOf` probe)
      assert "let call guards on definedness" ("#ifdef aihc_let_defined_twice" `isInfixOf` probe)
      -- A name with no built-in reading has no fallback query to answer.
      assert "let call without a built-in" ("#error AIHC_UNSUPPORTED_directive_twice" `isInfixOf` probe)
      let answers = M.fromList ([(i,Answer 0 0) | i <- [0,1,2,3,4,6]] ++ [(5,Answer 1 42)])
      assert "let output" (finish plan answers == Right
        "{-# LINE 1 \"T.hsc\" #-}\n\nv = 42 twice\n{-# LINE 3 \"T.hsc\" #-}\n")
      assert "let argument kind" (case finish plan (M.insert 5 (Answer 0 42) answers) of Left _ -> True; _ -> False)
      assert "let missing argument" (case finish plan (M.delete 5 answers) of Left _ -> True; _ -> False)
  -- The corpus idiom: a #let that shadows a built-in template.
  case prepare "T.hsc" "#let alignment t = \"%lu\", (unsigned long)sizeof(t)\nv = #{alignment int}\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      assert "shadowed built-in keeps its own query" ("offsetof(struct { char a;" `isInfixOf` probe)
      assert "shadowed built-in keeps its override guard" ("#ifdef hsc_alignment" `isInfixOf` probe)
      let common = M.fromList [(i,Answer 0 0) | i <- [0,1,2,3,7]]
          chosen = M.union common (M.fromList [(4,Answer 0 0),(5,Answer 1 4)])
          shadowed = M.insert 6 (Answer 1 8) common
          rendered value = Right ("{-# LINE 1 \"T.hsc\" #-}\n\nv = " ++ value ++ "\n{-# LINE 3 \"T.hsc\" #-}\n")
      assert "live #let wins" (finish plan chosen == rendered "4")
      assert "dead #let falls back to the built-in" (finish plan shadowed == rendered "8")
      assert "both readings cannot answer"
        (case finish plan (M.insert 6 (Answer 1 8) chosen) of Left _ -> True; _ -> False)
      assert "neither reading answers" (case finish plan common of Left _ -> True; _ -> False)
  -- Formatting is reconstructed here; the values are ordinary target queries.
  mapM_ formatted
    [ ("%d", -3, "-3"), ("%5d", 42, "   42"), ("%-5d|", 42, "42   |")
    , ("%05d", 42, "00042"), ("%+d", 42, "+42"), ("%08lx", 42, "0000002a")
    , ("%#o", 8, "010"), ("%#X", 255, "0XFF"), ("%.4u", 7, "0007")
    , ("%llu", 18446744073709551615, "18446744073709551615"), ("%c", 65, "A")
    , ("100%% of %d", 1, "100% of 1") ]
  mapM_ rejected
    [ "#let bad x = \"%s\", (x)\nv = #{bad 1}\n"
    , "#let bad x = \"%f\", (x)\nv = #{bad 1}\n"
    , "#let bad x = \"%d %d\", (x)\nv = #{bad 1}\n"
    , "#let bad x = FORMAT, (x)\nv = #{bad 1}\n"
    , "#let 9bad x = \"%d\", (x)\nv = #{9bad 1}\n"
    , "#let bad x = \"%d\", (x)\n#let bad x = \"%d\", 2 * (x)\nv = #{bad 1}\n" ]
  -- Upstream defines every #let in its header program, so a call may precede
  -- the definition. The macros are hoisted into the prelude to match.
  case prepare "T.hsc" "v = #{twice 21}\n#let twice x = \"%d\", 2 * (x)\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      let prelude = takeWhile (/= "#line 1 \"T.hsc\"") (lines probe)
      assert "let macros are hoisted"
        (any ("#define aihc_let_twice_0(x) (2 * (x))" `isPrefixOf`) prelude)
      let answers = M.fromList ([(i,Answer 0 0) | i <- [0,1,2,3,5,6,7]] ++ [(4,Answer 1 42)])
      assert "call before definition" (finish plan answers == Right
        "{-# LINE 1 \"T.hsc\" #-}\nv = 42\n{-# LINE 2 \"T.hsc\" #-}\n\n")
  -- An unsupported #let that is never called is not an error, and neither is
  -- one whose call sits in a dead branch.
  case prepare "T.hsc" "#let bad x = \"%s\", (x)\nv = #{const 1}\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      assert "unused #let stays silent" (not ("#error AIHC_UNSUPPORTED_let" `isInfixOf` probe))
      assert "unused #let output" (finish plan (M.fromList [(0,Answer 0 0),(1,Answer 0 0),(2,Answer 0 0),(3,Answer 1 1),(4,Answer 0 0)])
        == Right "{-# LINE 1 \"T.hsc\" #-}\n\nv = 1\n{-# LINE 3 \"T.hsc\" #-}\n")
  where
    -- One conversion, one argument: the smallest complete #let round trip.
    formatted (format,value,expected) =
      case prepare "T.hsc" ("#let fmt x = \"" ++ format ++ "\", (x)\nv = #{fmt 0}") of
        Left e -> error (show e)
        Right (_,plan) -> do
          let answers = M.fromList ([(i,Answer 0 0) | i <- [0,1,2,3,4]] ++ [(5,Answer 1 value)])
          assert ("let format " ++ format)
            (finish plan answers == Right ("{-# LINE 1 \"T.hsc\" #-}\n\nv = " ++ expected))
    rejected source = case prepare "T.hsc" source of
      Left _ -> pure ()
      Right (probe,_) -> assert ("rejected #let: " ++ source) ("#error AIHC_UNSUPPORTED_let" `isInfixOf` probe)

-- #enum owns one query per enumerated constant, so it exercises multi-answer
-- directives as well as upstream's exact naming and spacing quirks.
enumTests :: IO ()
enumTests = do
  case prepare "T.hsc" "#{enum Count  ,  Count, FOO_BAR, named = BAZ}\n" of
    Left e -> error (show e)
    Right (probe,plan) -> do
      assert "enum probes each constant" (all (`isInfixOf` probe) ["(FOO_BAR)","( BAZ)"])
      assert "enum guards template overrides" ("defined(hsc_enum) || defined(hsc_haskellize)" `isInfixOf` probe)
      let answers = M.fromList [(0,Answer 0 0),(1,Answer 0 0),(2,Answer 1 7),(3,Answer 1 (-1)),(4,Answer 0 0)]
      assert "enum output" (finish plan answers == Right (concat
        [ "{-# LINE 1 \"T.hsc\" #-}\n"
        , "fooBar :: Count\nfooBar = Count 7\n"
        , "named  :: Count\nnamed  = Count (-1)\n"
        , "\n{-# LINE 2 \"T.hsc\" #-}\n" ]))
      assert "enum missing constant" (case finish plan (M.delete 3 answers) of Left _ -> True; _ -> False)
      assert "enum unexpected constant" (case finish plan (M.insert 5 (Answer 1 0) answers) of Left _ -> True; _ -> False)
      assert "enum constant kind" (case finish plan (M.insert 2 (Answer 0 0) answers) of Left _ -> True; _ -> False)
  -- Upstream emits nothing for an argument without a constructor separator.
  case prepare "T.hsc" "#{enum Count}" of
    Left e -> error (show e)
    Right (_,plan) ->
      assert "malformed enum output" (finish plan (M.fromList [(0,Answer 0 0),(1,Answer 0 0)]) == Right "{-# LINE 1 \"T.hsc\" #-}\n")
  -- An inactive branch must drop the whole directive, constants included.
  case prepare "T.hsc" "#if 0\n#{enum Count, Count, A, B}\n#endif\n" of
    Left e -> error (show e)
    Right (_,plan) -> do
      let inactive = M.fromList [(0,Answer 0 0),(7,Answer 0 0),(8,Answer 0 0)]
      assert "inactive enum" (finish plan inactive == Right "{-# LINE 1 \"T.hsc\" #-}\n\n{-# LINE 4 \"T.hsc\" #-}\n")
      assert "inactive enum constant" (case finish plan (M.insert 4 (Answer 1 1) inactive) of Left _ -> True; _ -> False)

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
