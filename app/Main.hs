-- SPDX-License-Identifier: Unlicense
module Main (main) where

import Hsc2hs
import qualified Data.ByteString as B
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (replaceExtension)
import System.Console.GetOpt

options :: [OptDescr (String,String)]
options =
  [ Option ['o'] ["output"] (ReqArg ((,) "output") "FILE") "output Haskell file"
  , Option ['c'] ["cc"] (ReqArg ((,) "cc") "CLANG") "Clang executable"
  , Option [] ["target"] (ReqArg ((,) "target") "TRIPLE") "required Clang target triple"
  , Option [] ["sysroot"] (ReqArg ((,) "sysroot") "DIR") "required target sysroot"
  , Option ['C'] ["cflag"] (ReqArg ((,) "flag") "FLAG") "additional C compiler flag"
  , Option ['I'] [] (ReqArg (\s -> ("flag","-I"++s)) "DIR") "C include directory"
  , Option ['D'] ["define"] (ReqArg (\s -> ("flag","-D"++s)) "NAME[=VALUE]") "C definition"
  , Option ['i'] ["include"] (ReqArg ((,) "include") "FILE") "include C header"
  , Option ['x'] ["cross-compile"] (NoArg ("cross","")) "upstream cross output formatting (always compile-only)"
  , Option ['?'] ["help"] (NoArg ("help","")) "show help"
  , Option ['V'] ["version"] (NoArg ("version","")) "show version"
  ]

main :: IO ()
main = do
  args <- getArgs
  let (opts,files,errors) = getOpt Permute options args
      get k = lookup k (reverse opts)
  if not (null errors) then die (concat errors)
  else if get "help" /= Nothing then putStr (usageInfo "aihc-hsc2hs --target TRIPLE --sysroot DIR [OPTIONS] FILE.hsc" options)
  else if get "version" /= Nothing then putStrLn "aihc-hsc2hs 0.1.0.0 (compile-only MVP)"
  else case (files,get "target",get "sysroot") of
    ([file],Just triple,Just sysroot) | not (null triple) && not (null sysroot) -> do
      let config = (defaultConfig (Target triple sysroot []))
            { compiler = maybe "clang" id (get "cc")
            , outputStyle = if get "cross" == Nothing then NativeStyle else CrossStyle
            , cFlags = concatMap (\(k,v) -> case k of "flag" -> [v]; "include" -> ["-include",v]; _ -> []) opts }
      source <- B.readFile file
      result <- generateBytes config file source
      case result of
        Left (Diagnostic message) -> die message
        Right output -> B.writeFile (maybe (replaceExtension file "hs") id (get "output")) output
    _ -> die "expected one input file and explicit --target TRIPLE --sysroot DIR; use --help"
