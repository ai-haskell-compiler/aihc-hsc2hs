-- SPDX-License-Identifier: Unlicense
module Hsc2hs
  ( Diagnostic(..), Target(..), Config(..), OutputStyle(..), defaultConfig
  , Token(..), parse, Plan, prepare, prepareWithStyle, finish, generate
  ) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Data.Char (isAlphaNum, isSpace)
import Data.List (intercalate, isPrefixOf)
import Control.Exception (IOException, try)
import Control.Monad (unless)
import System.Exit (ExitCode(..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO (hPutStr, stderr)
import System.Directory (doesDirectoryExist)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Hsc2hs.Object

-- | A source, compiler, filesystem, or object-format diagnostic.
data Diagnostic = Diagnostic String deriving (Eq, Show)
-- | Explicit target ABI and header context. No host-target inference is done.
data Target = Target { targetTriple :: String, targetSysroot :: FilePath, targetFlags :: [String] }
  deriving (Eq, Show)
-- | IO driver settings. Compiler flags must belong to the target build context.
data Config = Config { compiler :: FilePath, target :: Target, cFlags :: [String], compilerTimeoutMicros :: Int, outputStyle :: OutputStyle }
  deriving (Eq, Show)
-- | Upstream's backends differ in macro setup and pragmas. Both styles here
-- use the same compile-only pipeline.
data OutputStyle = NativeStyle | CrossStyle deriving (Eq, Show)

defaultConfig :: Target -> Config
defaultConfig t = Config "clang" t [] 60000000 NativeStyle

data Token = Text Int String | Directive Int String String deriving (Eq, Show)
data Piece = Literal Int String | Expansion String | Control String String | Unsupported String
  deriving (Eq, Show)
data Plan = Plan OutputStyle FilePath [(Int, Piece)] deriving (Eq, Show)

type Result a = Either Diagnostic a
err :: String -> Result a
err = Left . Diagnostic

-- Haskell text is retained verbatim. C arguments use balanced delimiters and
-- quotes; only a top-level newline or closing delimiter terminates bare syntax.
parse :: String -> Result [Token]
parse = go 1 1 ""
  where
    flush start acc rest = [Text start (reverse acc) | not (null acc)] ++ rest
    go _ start acc [] = pure (flush start acc [])
    go line start acc ('#':'#':xs) = go line start ('#':acc) xs
    go line start acc ('#':xs) = do
      let (braced, ys) = case xs of '{':inside -> (True,inside); _ -> (False,xs)
          (key, zs) = span (\c -> isAlphaNum c || c == '_') (dropWhile (\c -> c == ' ' || c == '\t') ys)
      unless (not (null key)) (err ("line " ++ show line ++ ": expected directive name (use ## for a literal hash)"))
      (arg, rest, linesUsed) <- arguments braced zs
      more <- go (line+linesUsed) (line+linesUsed) "" rest
      pure (flush start acc (Directive line key (trim arg):more))
    go line start acc xs@(c:cs)
      | "--" `isPrefixOf` xs = let (a,b) = break (== '\n') xs in go line start (reverse a ++ acc) b
      | "{-" `isPrefixOf` xs = do
          (a,b) <- block 1 "{-" (drop 2 xs)
          go (line+newlines a) start (reverse a ++ acc) b
      | c == '"' || charLiteral xs = do
          (a,b) <- quoted c [c] cs
          go (line+newlines a) start (reverse a ++ acc) b
      | otherwise = go (line + if c == '\n' then 1 else 0) start (c:acc) cs
    charLiteral ('\'':'\\':_) = True
    charLiteral ('\'':_:'\'':_) = True
    charLiteral _ = False

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
newlines :: String -> Int
newlines = length . filter (== '\n')

quoted :: Char -> String -> String -> Result (String,String)
quoted _ _ [] = err "unterminated quoted literal"
quoted q acc ('\\':c:xs) = quoted q (acc ++ ['\\',c]) xs
quoted q acc (c:xs)
  | c == q = pure (acc ++ [c], xs)
  | otherwise = quoted q (acc ++ [c]) xs

block :: Int -> String -> String -> Result (String,String)
block _ _ [] = err "unterminated Haskell block comment"
block n acc xs@(c:cs)
  | "{-" `isPrefixOf` xs = block (n+1) (acc ++ "{-") (drop 2 xs)
  | "-}" `isPrefixOf` xs = if n == 1 then pure (acc ++ "-}", drop 2 xs) else block (n-1) (acc ++ "-}") (drop 2 xs)
  | otherwise = block n (acc ++ [c]) cs

arguments :: Bool -> String -> Result (String,String,Int)
arguments braced = walk [] "" 0
  where
    walk stack acc used []
      | braced || not (null stack) = err "unterminated directive"
      | otherwise = pure (acc,[],used)
    walk stack acc used xs@(c:cs)
      | "\\\n" `isPrefixOf` xs = walk stack acc (used+1) (drop 2 xs)
      | null stack && braced && c == '}' = pure (acc,cs,used)
      | null stack && not braced && (c == '\n' || c `elem` ")]}") = pure (acc,xs,used)
      | c `elem` "\"'" = do
          (a,b) <- quoted c [c] cs
          walk stack (acc++a) (used+newlines a) b
      | "/*" `isPrefixOf` xs = do
          (a,b) <- cComment "/*" (drop 2 xs)
          walk stack (acc++a) (used+newlines a) b
      | c `elem` "([{ " && c /= ' ' = walk (close c:stack) (acc++[c]) used cs
      | c `elem` ")]}" = case stack of
          k:ks | k == c -> walk ks (acc++[c]) used cs
          _ -> err "mismatched directive delimiter"
      | otherwise = walk stack (acc++[c]) (used + if c == '\n' then 1 else 0) cs
    close '(' = ')'
    close '[' = ']'
    close _ = '}'
    cComment _ [] = err "unterminated C comment"
    cComment acc xs@(c:cs)
      | "*/" `isPrefixOf` xs = pure (acc++"*/",drop 2 xs)
      | otherwise = cComment (acc++[c]) cs

-- Records are byte arrays: no target-endian integers, pointers or relocations.
record :: Int -> Int -> String -> String
record ident kind expr =
  "_Static_assert(__builtin_classify_type(" ++ expr ++ ") == 1, \"AIHC_UNSUPPORTED_noninteger_value\");\n" ++
  "_Static_assert(sizeof(" ++ expr ++ ") <= 8, \"AIHC_UNSUPPORTED_value_width\");\n" ++
  "__attribute__((used,aligned(1),section(AIHC_SECTION))) static const unsigned char aihc_answer_" ++ show ident ++ "[24] = {" ++
  intercalate "," (["72","83","67","1"] ++ bytes (show ident) 4 ++ [show kind,"((" ++ expr ++ ") < 0)"] ++ replicate 6 "0" ++ bytes ("(unsigned long long)(" ++ expr ++ ")") 8) ++ "};\n"
  where bytes e n = ["((" ++ e ++ " >> " ++ show (8*i) ++ ") & 255)" | i <- [0..n-1 :: Int]]

prepare :: FilePath -> String -> Result (String, Plan)
prepare = prepareWithStyle NativeStyle

-- | Build a probe and a pure reconstruction plan with explicit output style.
prepareWithStyle :: OutputStyle -> FilePath -> String -> Result (String, Plan)
prepareWithStyle style file source = do
  tokens <- parse source
  pairs <- mapM lower (zip [1..] tokens)
  let headers = if style == CrossStyle then "" else concat
        [location line ++ "#" ++ key ++ " " ++ arg ++ "\n" | Directive line key arg <- tokens, key `elem` controls]
      prelude = "#include <stddef.h>\n#if defined(__APPLE__)\n#define AIHC_SECTION \"__DATA,__aihc_ans\"\n#else\n#define AIHC_SECTION \"aihc_ans\"\n#endif\n" ++ headers ++ record 0 0 "0"
  pure (prelude ++ concatMap fst pairs, Plan style file (map snd pairs))
  where
    lower (ident, Text line s) = pure (record ident 0 "0", (ident,Literal line s))
    lower (ident, Directive line key arg)
      | key `elem` controls =
          let directive = if style == NativeStyle && key `notElem` conditionals then "" else location line ++ "#" ++ key ++ " " ++ arg ++ "\n"
          in pure (directive ++ record ident 0 "0", (ident,Control key arg))
      | otherwise = case query key arg of
          Just expr -> pure (location line ++ "#ifdef hsc_" ++ key ++ "\n#error AIHC_UNSUPPORTED_template_override\n#endif\n" ++ record ident 1 expr, (ident,Expansion key))
          Nothing -> pure (location line ++ "#error AIHC_UNSUPPORTED_directive_" ++ key ++ "\n", (ident,Unsupported key))
    location line = "#line " ++ show line ++ " " ++ show file ++ "\n"
    conditionals = ["if","ifdef","ifndef","elif","else","endif"]
    controls = ["include","define","undef","error","warning"] ++ conditionals

query :: String -> String -> Maybe String
query key arg = case key of
  "const" -> Just ("(" ++ arg ++ ")")
  "size" -> Just ("sizeof(" ++ arg ++ ")")
  "alignment" -> Just ("offsetof(struct { char a; " ++ arg ++ " b; }, b)")
  "offset" -> offset
  "peek" -> offset
  "poke" -> offset
  "ptr" -> offset
  "type" -> Just ("((" ++ arg ++ ")(int)(" ++ arg ++ ")1.4 == (" ++ arg ++ ")1.4 ? (sizeof(" ++ arg ++ ") * 8 + ((" ++ arg ++ ")(-1) < (" ++ arg ++ ")0 ? 100 : 200)) : (sizeof(" ++ arg ++ ") > sizeof(double) ? 3 : sizeof(" ++ arg ++ ") == sizeof(double) ? 2 : 1))")
  _ -> Nothing
  where offset = Just ("offsetof(" ++ arg ++ ")")

finish :: Plan -> M.Map Int Answer -> Result String
finish (Plan style file pieces) answers = do
  unless (M.lookup 0 answers == Just (Answer 0 0)) (err "missing answer sentinel")
  unless (all (`elem` (0:map fst pieces)) (M.keys answers)) (err "unexpected answer ID")
  validate True [] pieces
  rendered <- render False pieces
  let defines = ["{-# OPTIONS_GHC -optc-D" ++ macro arg ++ " #-}\n" | style == NativeStyle, (i,Control "define" arg) <- pieces, M.member i answers]
  pure (concat defines ++ linePragma 1 ++ rendered)
  where
    -- Branch markers distinguish an inactive query from a missing answer.
    validate _ [] [] = pure ()
    validate _ _ [] = err "unclosed conditional in reconstruction plan"
    validate active stack ((ident,piece):rest) =
      let present = M.member ident answers
          require condition = unless condition (err "missing or inconsistent branch/answer record")
      in case piece of
        Control key _ | key `elem` ["if","ifdef","ifndef"] -> do
          require (not present || active)
          validate present ((active,present):stack) rest
        Control "elif" _ -> case stack of
          (parent,taken):outer -> do
            require (not present || (parent && not taken))
            validate present ((parent,taken || present):outer) rest
          _ -> err "unexpected elif"
        Control "else" _ -> case stack of
          (parent,taken):outer -> do
            require (present == (parent && not taken))
            validate present ((parent,True):outer) rest
          _ -> err "unexpected else"
        Control "endif" _ -> case stack of
          (parent,_):outer -> do
            require (present == parent)
            validate parent outer rest
          _ -> err "unexpected endif"
        _ -> do
          require (present == active)
          validate active stack rest
    macro arg = let (k,v) = break isSpace arg in k ++ if null (trim v) then "" else "=" ++ trim v
    linePragma :: Int -> String
    linePragma n = "{-# LINE " ++ show n ++ " " ++ show file ++ " #-}\n"
    render _ [] = pure ""
    render pending ((ident,piece):rest) = case M.lookup ident answers of
      Nothing -> render pending rest
      Just (Answer kind value) -> do
        unless (kind == case piece of Expansion _ -> 1; _ -> 0) (err "answer kind mismatch")
        case piece of
          Literal line s -> do
            let (a,b) = break (== '\n') s
                emitted = if pending && not (null b) then a ++ "\n" ++ linePragma (line+1) ++ drop 1 b else s
            more <- render (pending && null b) rest
            pure (emitted ++ more)
          Expansion key -> do
            s <- expansion key value
            more <- render True rest
            pure (s ++ more)
          Control key _ -> render (pending || (style == NativeStyle && key `elem` ["if","ifdef","ifndef","elif","else","endif"])) rest
          Unsupported key -> err ("unsupported directive: " ++ key)
    expansion key value = case key of
      "const" -> pure (show value)
      "alignment" -> pure (show value)
      "type" -> case value of
        1 -> pure "Float"
        2 -> pure "Double"
        3 -> pure "LDouble"
        _ | value `elem` [108,116,132,164] -> pure ("Int" ++ show (value-100))
          | value `elem` [208,216,232,264] -> pure ("Word" ++ show (value-200))
          | otherwise -> err "unsupported numeric type width"
      "peek" -> pure ("(\\hsc_ptr -> peekByteOff hsc_ptr " ++ show value ++ ")")
      "poke" -> pure ("(\\hsc_ptr -> pokeByteOff hsc_ptr " ++ show value ++ ")")
      "ptr" -> pure ("(\\hsc_ptr -> hsc_ptr `plusPtr` " ++ show value ++ ")")
      _ -> pure ("(" ++ show value ++ ")")

-- This is the only process boundary. There is intentionally no linking or
-- execution operation. All compiler arguments are passed without a shell.
generate :: Config -> FilePath -> String -> IO (Result String)
generate config file source
  | null (targetTriple (target config)) || null (targetSysroot (target config)) = pure (err "explicit target triple and sysroot are required")
  | compilerTimeoutMicros config <= 0 = pure (err "compiler timeout must be positive")
  | otherwise = case prepareWithStyle (outputStyle config) file source of
  Left e -> pure (Left e)
  Right (probe,plan) -> do
    result <- try $ withSystemTempDirectory "aihc-hsc2hs" $ \dir -> do
      let c = dir </> "probe.c"; o = dir </> "probe.o"; t = target config
      exists <- doesDirectoryExist (targetSysroot t)
      if not exists then pure (err ("missing sysroot: " ++ targetSysroot t)) else do
        writeFile c probe
        compiled <- timeout (compilerTimeoutMicros config) $ readProcessWithExitCode (compiler config)
          (["--target=" ++ targetTriple t, "--sysroot=" ++ targetSysroot t] ++ targetFlags t ++ cFlags config ++
           ["-iquote",takeDirectory file,"-fno-lto","-c",c,"-o",o]) ""
        case compiled of
          Nothing -> pure (err "Clang timed out")
          Just (ExitFailure n,out,diagnostics) -> pure (err ("Clang failed (" ++ show n ++ "):\n" ++ out ++ diagnostics))
          Just (ExitSuccess,_,diagnostics) -> do
            hPutStr stderr diagnostics
            bytes <- B.readFile o
            pure $ either (err . ("object decoding: " ++)) (finish plan) (decodeAnswers bytes)
    pure $ case (result :: Either IOException (Result String)) of
      Left e -> err ("tool/filesystem failure: " ++ show e)
      Right value -> value
