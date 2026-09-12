-- SPDX-License-Identifier: Unlicense
-- Resolve Cabal conditionals without building or executing package code.
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec
import Distribution.PackageDescription.Configuration
import Distribution.Types.ComponentRequestedSpec
import Distribution.Compiler
import Distribution.System
import Distribution.Version
import qualified Data.ByteString as B
import Distribution.Parsec (simpleParsec)
import Distribution.Simple.Build.Macros (generatePackageVersionMacros)
import Distribution.Verbosity
import Distribution.Pretty
import Distribution.ModuleName (toFilePath, fromString)
import Distribution.Utils.Path (getSymbolicPath)
import System.Directory (listDirectory)
import System.FilePath (takeDirectory, takeExtension, dropExtension, (</>))
import System.Environment
import Data.List (intercalate)
import Data.Maybe (maybeToList)
import qualified Distribution.Compat.NonEmptySet as NES

str s = "\"" ++ concatMap escape s ++ "\"" where
  escape '"' = "\\\""
  escape '\\' = "\\\\"
  escape '\n' = "\\n"
  escape '\r' = "\\r"
  escape '\t' = "\\t"
  escape c = [c]
obj fields = "{" ++ intercalate "," [str k ++ ":" ++ v | (k,v) <- fields] ++ "}"
arr xs = "[" ++ intercalate "," xs ++ "]"
strings = arr . map str
component allPackages ownPackage label mods bi = obj
  [("component",str label),("buildable",if buildable bi then "true" else "false")
  ,("modules",strings (map toFilePath (mods ++ otherModules bi)))
  ,("source_dirs",strings (map getSymbolicPath (hsSourceDirs bi)))
  ,("include_dirs",strings (includeDirs bi))
  ,("includes",strings (includes bi))
  ,("install_includes",strings (installIncludes bi))
  ,("frameworks",strings (frameworks bi))
  ,("macros",str (generatePackageVersionMacros (pkgVersion ownPackage) (ownPackage : [p | p <- allPackages, pkgName p `elem` map depPkgName (targetBuildDepends bi)]) ++ ghcToolMacros))
  ,("cc_options",strings (ccOptions bi)),("cpp_options",strings (cppOptions bi))
  ,("libraries",strings (extraLibs bi)),("library_dirs",strings (extraLibDirs bi))
  ,("pkgconfig",strings (map prettyShow (pkgconfigDepends bi)))
  ,("dependencies",strings (map prettyShow (targetBuildDepends bi)))
  ,("dependency_libraries",arr [obj [("package",str (prettyShow (depPkgName d))),
      ("libraries",strings ["library:" ++ show l | l <- NES.toList (depLibraries d)])]
      | d <- targetBuildDepends bi])
  ,("unsatisfied_haskell_constraints",strings [prettyShow d | d <- targetBuildDepends bi, not (any (\p -> pkgName p == depPkgName d && withinRange (pkgVersion p) (depVerRange d)) allPackages)])]
-- The compiler is pinned to GHC 9.10.3 by the corpus configuration. These are
-- configuration macros for that real build tool, not substitute C declarations.
ghcToolMacros = unlines
  [ "#ifndef TOOL_VERSION_ghc"
  , "#define TOOL_VERSION_ghc \"9.10.3\""
  , "#endif"
  , "#ifndef MIN_TOOL_VERSION_ghc"
  , "#define MIN_TOOL_VERSION_ghc(a,b,c) ((a)<9 || ((a)==9 && ((b)<10 || ((b)==10 && (c)<=3))))"
  , "#endif"
  ]
mainModule path = [fromString (map (\c -> if c == '/' || c == '\\' then '.' else c) (dropExtension path))]
testMain t = case testInterface t of
  TestSuiteExeV10 _ path -> mainModule path
  TestSuiteLibV09 _ modu -> [modu]
  _ -> []
benchMain b = case benchmarkInterface b of
  BenchmarkExeV10 _ path -> mainModule path
  _ -> []
main = do
  arch:os:file:versionsFile:flagArgs <- getArgs
  allPackages <- map (maybe (error "invalid package identifier") id . simpleParsec) . lines <$> readFile versionsFile
  bytes <- B.readFile file
  let g = either (error . show) id (snd (runParseResult (parseGenericPackageDescription bytes)))
      requestedFlags = mkFlagAssignment (map parseFlag flagArgs)
  let platform = Platform (classifyArch Permissive arch) (classifyOS Permissive os)
      compiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9,10,3])) NoAbiTag
  case finalizePD requestedFlags (ComponentRequestedSpec True True) (const True) platform compiler [] g of
    Left e -> error (show e)
    Right (original,flags) -> do
      files <- listDirectory (takeDirectory file)
      hooks <- mapM (B.readFile . (takeDirectory file </>)) [f | f <- files, takeExtension f == ".buildinfo"]
      let parsed = [either (error . show) id (snd (runParseResult (parseHookedBuildInfo h))) | h <- hooks]
          p = foldl (flip updatePackageDescription) original parsed
      putStrLn $ obj
        [("package",str (prettyShow (package p))),("build_type",str (show (buildType p)))
        ,("flags",str (show flags)),("components",arr $
          [component allPackages (package p) ("library:"++show (libName l)) (exposedModules l) (libBuildInfo l) | l <- maybeToList (library p) ++ subLibraries p] ++
          [component allPackages (package p) ("executable:"++prettyShow (exeName e)) (mainModule (modulePath e)) (buildInfo e) | e <- executables p] ++
          [component allPackages (package p) ("test:"++prettyShow (testName t)) (testMain t) (testBuildInfo t) | t <- testSuites p] ++
          [component allPackages (package p) ("benchmark:"++prettyShow (benchmarkName b)) (benchMain b) (benchmarkBuildInfo b) | b <- benchmarks p])]

parseFlag ('+':name) | not (null name) = (mkFlagName name, True)
parseFlag ('-':name) | not (null name) = (mkFlagName name, False)
parseFlag value = error ("Expected +flag or -flag, got " ++ show value)
