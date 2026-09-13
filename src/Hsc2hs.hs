-- SPDX-License-Identifier: Unlicense
module Hsc2hs
  ( Diagnostic(..), Target(..), Config(..), OutputStyle(..), defaultConfig
  , Token(..), parse, Plan, prepare, prepareWithStyle, finish, generate, generateBytes
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map.Strict as M
import Data.Bits (shiftR, (.&.))
import Data.Char (digitToInt, isAlphaNum, isDigit, isHexDigit, isOctDigit, isSpace, toLower, toUpper)
import Data.List (intercalate, isPrefixOf)
import Data.Maybe (fromMaybe)
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
data Piece = Literal Int String | Expansion String | Enumeration String String [(Int, String)]
           | StringExpansion [Int] | Control String String | LetDefinition
           | LetCall [FormatItem] Int [Int] (Maybe (String, Int))
           | Unsupported String
  deriving (Eq, Show)

-- | A @#let@ body is a printf argument list: a literal format string and one C
-- expression per conversion. The expressions become ordinary constant queries
-- and the formatting is done here, so no printf is ever executed.
data LetDef = LetDef { letParams :: String, letFormat :: [FormatItem], letArguments :: [String] }
  deriving (Eq, Show)
-- | A parsed format string: verbatim text and printf conversions.
data FormatItem = Verbatim String | Conversion String (Maybe Int) (Maybe Int) Char
  deriving (Eq, Show)

-- | Query IDs a piece owns beyond its own presence marker: one per enumerated
-- constant for @#enum@, one per byte chunk for @#const_str@, and for a @#let@
-- call a marker for the @#let@ branch, one query per format argument and the
-- query of the built-in it shadows, because only the C preprocessor knows which
-- branch is live.
subQueries :: Piece -> [Int]
subQueries (Enumeration _ _ entries) = map fst entries
subQueries (StringExpansion chunks) = chunks
subQueries (LetCall _ marker args builtin) = marker : args ++ map snd (maybe [] pure builtin)
subQueries _ = []
data Plan = Plan OutputStyle FilePath [(Int, Piece)] deriving (Eq, Show)

type Result a = Either Diagnostic a
err :: String -> Result a
err = Left . Diagnostic

-- Remove carriage returns as upstream does before parsing. Other Haskell text
-- is retained verbatim. C arguments use balanced delimiters and
-- quotes; only a top-level newline or closing delimiter terminates bare syntax.
parse :: String -> Result [Token]
parse = go 1 1 "" . filter (/= '\r')
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
  answerArray ident ([show kind,"((" ++ expr ++ ") < 0)"] ++ replicate 6 "0" ++
                     littleEndian ("(unsigned long long)(" ++ expr ++ ")") 8)

-- | A 24-byte answer record: magic, version, query ID, then the caller's
-- kind byte, flag byte, six reserved bytes and eight value bytes.
answerArray :: Int -> [String] -> String
answerArray ident fields =
  "__attribute__((used,aligned(1),section(AIHC_SECTION))) static const unsigned char aihc_answer_" ++ show ident ++ "[24] = {" ++
  intercalate "," (["72","83","67","1"] ++ littleEndian (show ident) 4 ++ fields) ++ "};\n"

littleEndian :: String -> Int -> [String]
littleEndian e n = ["((" ++ e ++ " >> " ++ show (8*i) ++ ") & 255)" | i <- [0..n-1]]

-- | Eight string bytes packed into one record's value field. The value field is
-- little-endian, so the bytes are simply laid out in order. Clang folds the
-- indexing of a constant string; the clamp keeps every read in bounds even when
-- the chunk runs past the terminator, and the length answer says where to stop.
stringRecord :: Int -> String -> Int -> String
stringRecord ident name base =
  answerArray ident (["1","0"] ++ replicate 6 "0" ++
                     ["AIHC_BYTE(" ++ name ++ "," ++ show (base+i) ++ ")" | i <- [0..7]])

-- Strings are answered in a single compile, so the probe must reserve a fixed
-- number of byte chunks. Longer strings are rejected rather than truncated.
stringCapacity :: Int
stringCapacity = 256

-- A directive argument may span source lines; a macro body may not, so the
-- newlines are continued rather than flattened, keeping the argument verbatim.
continued :: String -> String
continued = concatMap (\c -> if c == '\n' then "\\\n" else [c])

-- Reading past the terminator would leave the constant expression, so every
-- index is clamped to a byte the string definitely has.
stringMacros :: String
stringMacros =
  "#define AIHC_LEN(x) __builtin_strlen(x)\n" ++
  "#define AIHC_BYTE(x,k) ((unsigned char)((x)[(k) < AIHC_LEN(x) ? (k) : 0]))\n"

prepare :: FilePath -> String -> Result (String, Plan)
prepare = prepareWithStyle NativeStyle

-- | Build a probe and a pure reconstruction plan with explicit output style.
prepareWithStyle :: OutputStyle -> FilePath -> String -> Result (String, Plan)
prepareWithStyle style file source = do
  tokens <- parse source
  let definitions = letDefinitions tokens
      -- Upstream defines every #let in its header program, so a definition is
      -- in scope for call sites that precede it. Reproducing that means
      -- hoisting the control directives too, and a file that uses #let
      -- therefore builds the same probe in both output styles.
      hoisted = style == NativeStyle || not (M.null definitions)
  pairs <- allocate definitions hoisted 1 tokens
  let headers = if not hoisted then "" else concat
        [ if key == "let"
            then either (const "") (location line ++) (fmap (defineLet (letName arg))
                   (M.findWithDefault (Left "malformed #let") (letName arg) definitions))
            else location line ++ "#" ++ key ++ " " ++ arg ++ "\n"
        | Directive line key arg <- tokens, key `elem` controls || key == "let" ]
      strings = not (null [() | Directive _ "const_str" _ <- tokens])
      prelude = "#include <stddef.h>\n#if defined(__APPLE__)\n#define AIHC_SECTION \"__DATA,__aihc_ans\"\n#else\n#define AIHC_SECTION \"aihc_ans\"\n#endif\n" ++ (if strings then stringMacros else "") ++ headers ++ record 0 0 "0"
  pure (prelude ++ concatMap fst pairs, Plan style file (map snd pairs))
  where
    -- Directives may own more than one query ID, so IDs are threaded rather
    -- than zipped against the token list.
    allocate _ _ _ [] = pure []
    allocate defs hoisted ident (tok:toks) = do
      entry <- lower defs hoisted ident tok
      more <- allocate defs hoisted (ident + 1 + length (subQueries (snd (snd entry)))) toks
      pure (entry:more)
    lower _ _ ident (Text line s) = pure (record ident 0 "0", (ident,Literal line s))
    lower defs hoisted ident (Directive line key arg)
      -- The macros were emitted in the prelude; the definition itself is only a
      -- presence marker here. A definition upstream would accept but this tool
      -- cannot represent is only a failure where it is called, never by itself.
      | key == "let" = pure (record ident 0 "0", (ident,LetDefinition))
      | key `elem` controls =
          let directive = if hoisted && key `notElem` conditionals then "" else location line ++ "#" ++ key ++ " " ++ arg ++ "\n"
          in pure (directive ++ record ident 0 "0", (ident,Control key arg))
      | key == "enum" =
          -- One presence marker plus one constant query per enumerated name.
          -- A malformed argument yields no output, exactly as upstream does.
          let (ty,constructor,entries) = fromMaybe ("","",[]) (parseEnum arg)
              numbered = zip [ident+1..] entries
              guardTemplates = location line ++ "#if defined(hsc_enum) || defined(hsc_haskellize)\n#error AIHC_UNSUPPORTED_template_override\n#endif\n"
              probe = guardTemplates ++ record ident 0 "0" ++
                concat [record i 1 ("(" ++ cName ++ ")") | (i,(_,cName)) <- numbered]
          in pure (probe, (ident, Enumeration ty constructor
                            [(i, fromMaybe (haskellize cName) hsName) | (i,(hsName,cName)) <- numbered]))
      | M.member key defs =
          pure (letCall line key arg ident (M.findWithDefault (Left "malformed #let") key defs))
      | key == "const_str" =
          -- A length query plus fixed-width byte chunks. The argument is named
          -- once as a macro so the probe does not repeat it per byte.
          let name = "aihc_str_" ++ show ident
              chunks = zip [ident+1 .. ident + stringCapacity `div` 8] [0,8..]
              probe = location line ++ "#ifdef hsc_const_str\n#error AIHC_UNSUPPORTED_template_override\n#endif\n" ++
                "#define " ++ name ++ " (" ++ continued arg ++ ")\n" ++
                "_Static_assert(__builtin_constant_p(AIHC_LEN(" ++ name ++ ")), \"AIHC_UNSUPPORTED_non_constant_string\");\n" ++
                "_Static_assert(AIHC_LEN(" ++ name ++ ") <= " ++ show stringCapacity ++ ", \"AIHC_UNSUPPORTED_string_length\");\n" ++
                record ident 1 ("AIHC_LEN(" ++ name ++ ")") ++
                concat [stringRecord i name base | (i,base) <- chunks] ++
                "#undef " ++ name ++ "\n"
          in pure (probe, (ident, StringExpansion (map fst chunks)))
      | otherwise = case query key arg of
          Just expr -> pure (location line ++ builtinProbe key expr ident, (ident,Expansion key))
          Nothing -> pure (unsupported line ("directive_" ++ key) ident ("unsupported directive: " ++ key))
    -- Whether a #let name is in scope is a C preprocessor fact: its definition
    -- can sit in a branch only the target's headers decide. Both readings are
    -- emitted and the branch that survives says which one to reconstruct.
    letCall line key arg ident entry = case entry of
      Left reason -> unsupported line "let_definition" ident reason
      Right def ->
        let count = length (letArguments def)
            marker = ident + 1
            args = [ident + 2 .. ident + 1 + count]
            builtin = fmap (const (key, ident + 2 + count)) (query key arg)
            fallback = case builtin of
              Just (name,fid) -> location line ++ builtinProbe name (fromMaybe "0" (query name arg)) fid
              Nothing -> "#error AIHC_UNSUPPORTED_directive_" ++ key ++ "\n"
            probe = location line ++ "#ifdef " ++ letFlag key ++ "\n" ++ record marker 0 "0" ++
                    concat [record i 1 (letMacro key k ++ "(" ++ arg ++ ")") | (k,i) <- zip [0..] args] ++
                    "#else\n" ++ fallback ++ "#endif\n" ++ record ident 0 "0"
        in (probe, (ident, LetCall (letFormat def) marker args builtin))
    builtinProbe key expr ident =
      "#ifdef hsc_" ++ key ++ "\n#error AIHC_UNSUPPORTED_template_override\n#endif\n" ++ record ident 1 expr
    unsupported line tag ident message =
      (location line ++ "#error AIHC_UNSUPPORTED_" ++ tag ++ "\n", (ident,Unsupported message))
    location line = "#line " ++ show line ++ " " ++ show file ++ "\n"
    conditionals = ["if","ifdef","ifndef","elif","else","endif"]
    controls = ["include","define","undef","error","warning"] ++ conditionals

-- | Split @#enum type, constructor, name = expr, ...@ exactly as upstream does,
-- including its lack of trimming around an explicit Haskell name.
parseEnum :: String -> Maybe (String, String, [(Maybe String, String)])
parseEnum arg = case break (== ',') arg of
  (_, []) -> Nothing
  (ty, _:afterType) -> case break (== ',') afterType of
    (constructor, afterConstructor) -> Just (ty, constructor, entries afterConstructor)
  where
    entries [] = []
    entries (_:rest) = case break (== ',') rest of
      (entry, more) -> split (dropWhile isSpace entry) : entries more
    split entry = case break (== '=') entry of
      (cName, []) -> (Nothing, cName)
      (hsName, _:cName) -> (Just hsName, cName)

-- | Collect every @#let@ definition. A name defined more than once carries the
-- reason it cannot be used: upstream lets the last definition win for every
-- call site, which is not decidable here when the definitions are conditional.
letDefinitions :: [Token] -> M.Map String (Either String LetDef)
letDefinitions tokens = M.fromListWith duplicate
  [(letName arg, parseLet arg) | Directive _ "let" arg <- tokens]
  where duplicate _ _ = Left "a #let name is defined more than once"

-- | The name a @#let@ binds, without validating the rest of the definition.
letName :: String -> String
letName = takeWhile (not . isSpace) . trim . takeWhile (/= '=')

-- | Split @#let name params = "format", expr, ...@ exactly as upstream does:
-- the first @=@ ends the header and the first space in the header ends the name.
parseLet :: String -> Either String LetDef
parseLet arg = case break (== '=') arg of
  (_, "") -> Left "a #let definition needs a body"
  (header, _:body) -> do
    let (name, params) = break isSpace (trim header)
    unless (identifier name) (Left ("#let defines an invalid name: " ++ name))
    pieces <- splitTop body
    case pieces of
      (text:exprs) -> do
        items <- parseFormat =<< stringLiteral text
        let conversions = length [c | Conversion _ _ _ c <- items]
        unless (conversions == length exprs)
          (Left ("#let " ++ name ++ " has " ++ show conversions ++ " conversions for "
                 ++ show (length exprs) ++ " arguments"))
        pure (LetDef (trim params) items (map trim exprs))
      [] -> Left "a #let body needs a format string"

identifier :: String -> Bool
identifier [] = False
identifier name@(c:_) = not (isDigit c) && all (\x -> isAlphaNum x || x == '_') name

-- | Split a C argument list on top-level commas, preserving quotes, comments
-- and nested delimiters verbatim.
splitTop :: String -> Either String [String]
splitTop = walk [] "" []
  where
    unbalanced = Left "unbalanced delimiters in a #let body"
    walk stack acc out [] = if null stack then Right (reverse (reverse acc:out)) else unbalanced
    walk stack acc out xs@(c:cs)
      | null stack && c == ',' = walk stack "" (reverse acc:out) cs
      | c `elem` "\"'" = case quoted c [c] cs of
          Left (Diagnostic m) -> Left m
          Right (a,b) -> walk stack (reverse a ++ acc) out b
      | "/*" `isPrefixOf` xs = case comment (drop 2 xs) of
          Nothing -> Left "unterminated C comment in a #let body"
          Just (a,b) -> walk stack (reverse ("/*" ++ a) ++ acc) out b
      | c `elem` "([{" = walk (close c:stack) (c:acc) out cs
      | c `elem` ")]}" = case stack of
          k:ks | k == c -> walk ks (c:acc) out cs
          _ -> unbalanced
      | otherwise = walk stack (c:acc) out cs
    comment [] = Nothing
    comment xs@(c:cs)
      | "*/" `isPrefixOf` xs = Just ("*/", drop 2 xs)
      | otherwise = fmap (\(a,b) -> (c:a,b)) (comment cs)
    close '(' = ')'
    close '[' = ']'
    close _ = '}'

-- | Decode one or more adjacent C string literals into the bytes printf would
-- write for them.
stringLiteral :: String -> Either String String
stringLiteral text = case trim text of
  ('"':rest) -> go rest
  _ -> Left "a #let format must be a literal string"
  where
    go [] = Left "unterminated #let format string"
    go ('"':rest) = case trim rest of
      "" -> Right ""
      ('"':more) -> go more
      _ -> Left "unexpected text after a #let format string"
    go ('\\':c:rest) = do (decoded,more) <- escape c rest; (decoded ++) <$> go more
    go (c:rest) = (c:) <$> go rest
    escape c rest = case lookup c simple of
      Just decoded -> Right ([decoded], rest)
      Nothing
        | c == 'x' -> case span isHexDigit rest of
            ([], _) -> Left "empty \\x escape in a #let format string"
            (ds, more) -> Right ([toEnum (number 16 ds `mod` 256)], more)
        | isOctDigit c -> let ds = c : take 2 (takeWhile isOctDigit rest)
                          in Right ([toEnum (number 8 ds `mod` 256)], drop (length ds - 1) rest)
        | otherwise -> Left ("unsupported escape \\" ++ [c] ++ " in a #let format string")
    number base = foldl (\acc d -> acc * base + digitToInt d) 0
    simple = zip "ntrfvab\\\"'?" "\n\t\r\f\v\a\b\\\"'?"

-- | Parse a printf format into literal text and conversions. Only conversions
-- with an integer argument are representable as a compile-time constant, so
-- everything else is rejected here rather than guessed at.
parseFormat :: String -> Either String [FormatItem]
parseFormat = go ""
  where
    verbatim acc = [Verbatim (reverse acc) | not (null acc)]
    go acc [] = Right (verbatim acc)
    go acc ('%':'%':cs) = go ('%':acc) cs
    go acc ('%':cs) = do
      let (flags, afterFlags) = span (`elem` "-+ #0") cs
          (width, afterWidth) = span isDigit afterFlags
          (precision, afterPrecision) = case afterWidth of
            '.':more -> let (digits,rest) = span isDigit more in (Just (number digits), rest)
            _ -> (Nothing, afterWidth)
          (len, body) = span (`elem` "hljzt") afterPrecision
      case body of
        c:rest | c `elem` "diouxX" || (c == 'c' && null len) -> do
                   unless (len `elem` ["","h","hh","l","ll","j","z","t"])
                     (Left ("unsupported length modifier %" ++ len ++ [c] ++ " in a #let format"))
                   (verbatim acc ++) . (Conversion flags (fmap number (nonEmpty width)) precision c:) <$> go "" rest
               | otherwise -> Left ("unsupported conversion %" ++ [c] ++ " in a #let format")
        [] -> Left "truncated conversion in a #let format"
    go acc (c:cs) = go (c:acc) cs
    nonEmpty s = if null s then Nothing else Just s
    number = foldl (\acc d -> acc * 10 + digitToInt d) 0

-- | Reproduce printf formatting for the decoded values, one per conversion.
formatLet :: [FormatItem] -> [Integer] -> Result String
formatLet format values = concat <$> go format values
  where
    go [] [] = pure []
    go (Verbatim text:rest) vs = (text:) <$> go rest vs
    go (item:rest) (v:vs) = do
      text <- conversion item v
      (text:) <$> go rest vs
    go _ _ = err "mismatched #let format arguments"

conversion :: FormatItem -> Integer -> Result String
conversion (Verbatim text) _ = pure text
conversion (Conversion flags width precision conv) value
  | conv == 'c' = pure (justify flags width [toEnum (fromInteger (value `mod` 256))])
  | conv `notElem` "di" && value < 0 =
      err ("#let format uses %" ++ [conv] ++ " for the negative value " ++ show value)
  | otherwise = pure (justify flags width (sign ++ digits))
  where
    base = case conv of { 'o' -> 8; 'x' -> 16; 'X' -> 16; _ -> 10 }
    body = showBase base (conv == 'X') (abs value)
    digits | precision == Just 0 && value == 0 = ""
           | otherwise = replicate (fromMaybe 0 precision - length body) '0' ++ body
    sign | conv `elem` "di" && value < 0 = "-"
         | conv `elem` "di" && '+' `elem` flags = "+"
         | conv `elem` "di" && ' ' `elem` flags = " "
         | '#' `elem` flags && conv == 'o' && take 1 digits /= "0" = "0"
         | '#' `elem` flags && conv `elem` "xX" && value /= 0 = if conv == 'x' then "0x" else "0X"
         | otherwise = ""
    justify fs w text
      | padding <= 0 = text
      | '-' `elem` fs = text ++ replicate padding ' '
      | '0' `elem` fs && precision == Nothing && conv /= 'c' =
          take (length sign) text ++ replicate padding '0' ++ drop (length sign) text
      | otherwise = replicate padding ' ' ++ text
      where padding = fromMaybe 0 w - length text

showBase :: Integer -> Bool -> Integer -> String
showBase base upper value
  | value < base = [digit value]
  | otherwise = showBase base upper (value `div` base) ++ [digit (value `mod` base)]
  where digit d = (if upper then toUpper else id) ("0123456789abcdef" !! fromInteger d)

-- | The probe-side names a @#let@ definition introduces: a definedness flag and
-- one expression macro per format argument. Parameter substitution is left to
-- the C preprocessor, which also decides whether the definition is live.
letFlag :: String -> String
letFlag name = "aihc_let_defined_" ++ name
letMacro :: String -> Int -> String
letMacro name index = "aihc_let_" ++ name ++ "_" ++ show index
defineLet :: String -> LetDef -> String
defineLet name def = concat (("#define " ++ letFlag name ++ " 1\n") :
  [ "#define " ++ letMacro name index ++ "(" ++ letParams def ++ ") (" ++ joinLines expr ++ ")\n"
  | (index,expr) <- zip [0..] (letArguments def) ])
  where joinLines = intercalate " \\\n" . lines

-- Mirrors template-hsc.h's hsc_haskellize: lower case with underscores
-- consumed and the following letter upper-cased.
haskellize :: String -> String
haskellize [] = []
haskellize (c:cs) = toLower c : go False cs
  where
    go _ [] = []
    go _ ('_':rest) = go True rest
    go upper (x:rest) = (if upper then toUpper x else toLower x) : go False rest

-- Mirrors template-hsc.h's hsc_const_str. Printable ASCII passes through, the
-- quote and backslash are escaped, and every other byte becomes a decimal
-- escape, followed by "\\&" when the next character would extend the number.
-- The escaped form is always ASCII, so it does not depend on the output encoding.
escapeString :: [Int] -> String
escapeString bytes = "\"" ++ concat (zipWith piece bytes (map Just (drop 1 bytes) ++ [Nothing])) ++ "\""
  where
    piece b next
      | b == 34 || b == 92 = ['\\', toEnum b]
      | b >= 0x20 && b <= 0x7E = [toEnum b]
      | otherwise = '\\' : show b ++ (if maybe False digit next then "\\&" else "")
    digit n = n >= 48 && n <= 57

-- The C preprocessor collapses whitespace when stringifying the enum type and
-- constructor. Reproduce that instead of emitting the raw argument text.
stringify :: String -> String
stringify = unwords . words

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
  unless (all (`elem` (0 : concatMap (\(i,p) -> i : subQueries p) pieces)) (M.keys answers)) (err "unexpected answer ID")
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
        -- Exactly one of the #let and built-in readings survives preprocessing.
        LetCall _ marker args builtin -> do
          let chosen = M.member marker answers
              shadowed = maybe False (\(_,i) -> M.member i answers) builtin
          require (present == active)
          require (if active then chosen /= shadowed else not (chosen || shadowed))
          require (all (\i -> M.member i answers == chosen) args)
          validate active stack rest
        _ -> do
          require (present == active)
          require (all (\i -> M.member i answers == active) (subQueries piece))
          validate active stack rest
    macro arg = let (k,v) = break isSpace arg in k ++ if null (trim v) then "" else "=" ++ trim v
    linePragma :: Int -> String
    linePragma n = "{-# LINE " ++ show n ++ " " ++ show file ++ " #-}\n"
    render _ [] = pure ""
    render pending ((ident,piece):rest) = case M.lookup ident answers of
      Nothing -> render pending rest
      Just (Answer kind value) -> do
        unless (kind == case piece of Expansion _ -> 1; StringExpansion _ -> 1; _ -> 0) (err "answer kind mismatch")
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
          Enumeration ty constructor entries -> do
            ss <- mapM (enumLine ty constructor) entries
            more <- render True rest
            pure (concat ss ++ more)
          StringExpansion chunks -> do
            bytes <- concat <$> mapM chunkBytes chunks
            unless (value >= 0 && value <= toInteger (length bytes)) (err "string length out of range")
            more <- render True rest
            pure (escapeString (take (fromInteger value) bytes) ++ more)
          LetCall format marker args builtin -> do
            s <- if M.member marker answers
                   then mapM answer args >>= formatLet format
                   else case builtin of
                     Just (key,i) -> answer i >>= expansion key
                     Nothing -> err "missing or inconsistent branch/answer record"
            more <- render True rest
            pure (s ++ more)
          -- A definition emits nothing, exactly as upstream's does.
          LetDefinition -> render pending rest
          Control key _ -> render (pending || (style == NativeStyle && key `elem` ["if","ifdef","ifndef","elif","else","endif"])) rest
          Unsupported message -> err message
    chunkBytes ident = case M.lookup ident answers of
      Nothing -> err "missing or inconsistent branch/answer record"
      Just (Answer kind value) -> do
        unless (kind == 1) (err "answer kind mismatch")
        unless (value >= 0) (err "invalid string chunk")
        pure [fromInteger ((value `shiftR` (8*i)) .&. 255) | i <- [0..7 :: Int]]
    answer ident = case M.lookup ident answers of
      Just (Answer 1 value) -> pure value
      _ -> err "missing or inconsistent branch/answer record"
    enumLine ty constructor (ident,hsName) = case M.lookup ident answers of
      Nothing -> err "missing or inconsistent branch/answer record"
      Just (Answer kind value) -> do
        unless (kind == 1) (err "answer kind mismatch")
        pure (hsName ++ " :: " ++ stringify ty ++ "\n" ++
              hsName ++ " = " ++ stringify constructor ++ " " ++ literal value ++ "\n")
    literal value = if value < 0 then "(" ++ show value ++ ")" else show value
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
generate = generateWith (\path -> B.writeFile path . T.encodeUtf8 . T.pack)

-- | Preprocess raw source bytes, matching upstream under a UTF-8 output locale.
-- Native output preserves source bytes; cross output encodes byte-valued
-- characters as UTF-8, matching upstream's text output handle.
-- Neither input decoding nor output encoding depends on the process locale.
generateBytes :: Config -> FilePath -> B.ByteString -> IO (Result B.ByteString)
generateBytes config file source =
  fmap (fmap encode) (generateWith (\path -> B.writeFile path . B8.pack) config file (B8.unpack source))
  where
    encode = case outputStyle config of
      NativeStyle -> B8.pack
      CrossStyle -> T.encodeUtf8 . T.pack

generateWith :: (FilePath -> String -> IO ()) -> Config -> FilePath -> String -> IO (Result String)
generateWith writeProbe config file source
  | null (targetTriple (target config)) || null (targetSysroot (target config)) = pure (err "explicit target triple and sysroot are required")
  | compilerTimeoutMicros config <= 0 = pure (err "compiler timeout must be positive")
  | otherwise = case prepareWithStyle (outputStyle config) file source of
  Left e -> pure (Left e)
  Right (probe,plan) -> do
    result <- try $ withSystemTempDirectory "aihc-hsc2hs" $ \dir -> do
      let c = dir </> "probe.c"; o = dir </> "probe.o"; t = target config
      exists <- doesDirectoryExist (targetSysroot t)
      if not exists then pure (err ("missing sysroot: " ++ targetSysroot t)) else do
        writeProbe c probe
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
