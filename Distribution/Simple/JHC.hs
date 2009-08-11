-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.JHC
-- Copyright   :  Isaac Jones 2003-2006
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This module contains most of the JHC-specific code for configuring, building
-- and installing packages.

{- Copyright (c) 2003-2005, Isaac Jones
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.JHC (
        configure, getInstalledPackages,
        buildLib, buildExe,
        installLib, installExe
 ) where

import Distribution.PackageDescription as PD
       ( PackageDescription(..), BuildInfo(..), Executable(..)
       , Library(..), libModules, hcOptions )
import Distribution.InstalledPackageInfo
                                ( InstalledPackageInfo, emptyInstalledPackageInfo )
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
                                ( InstalledPackageInfo_(package) )
import Distribution.Simple.PackageIndex (PackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.LocalBuildInfo
         ( LocalBuildInfo(..), ComponentLocalBuildInfo(..) )
import Distribution.Simple.BuildPaths
                                ( autogenModulesDir, exeExtension )
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), CompilerId(..), Compiler(..)
         , PackageDB(..), PackageDBStack, Flag, extensionsToFlags )
import Language.Haskell.Extension (Extension(..))
import Distribution.Simple.Program
         ( ConfiguredProgram(..), jhcProgram, ProgramConfiguration
         , userMaybeSpecifyPath, requireProgramVersion, lookupProgram
         , rawSystemProgram, rawSystemProgramStdoutConf )
import Distribution.Version     ( anyVersion )
import Distribution.Package
         ( Package(..) )
import Distribution.Simple.Utils
        ( createDirectoryIfMissingVerbose, writeFileAtomic
        , installOrdinaryFile, installExecutableFile
        , die, intercalate )
import System.FilePath          ( (</>) )
import Distribution.Verbosity
import Distribution.Text
         ( Text(parse), display )
import Distribution.Compat.ReadP
    ( readP_to_S, many, skipSpaces )

import Data.List                ( nub )
import Data.Char                ( isSpace )



-- -----------------------------------------------------------------------------
-- Configuring

configure :: Verbosity -> Maybe FilePath -> Maybe FilePath
          -> ProgramConfiguration -> IO (Compiler, ProgramConfiguration)
configure verbosity hcPath _hcPkgPath conf = do

  (jhcProg, _, conf') <- requireProgramVersion verbosity jhcProgram anyVersion
                           (userMaybeSpecifyPath "jhc" hcPath conf)

  let Just version = programVersion jhcProg
      comp = Compiler {
        compilerId             = CompilerId JHC version,
        compilerExtensions     = jhcLanguageExtensions
      }
  return (comp, conf')

-- | The flags for the supported extensions
jhcLanguageExtensions :: [(Extension, Flag)]
jhcLanguageExtensions =
    [(TypeSynonymInstances       , "")
    ,(ForeignFunctionInterface   , "")
    ,(NoImplicitPrelude          , "--noprelude")
    ,(CPP                        , "-fcpp")
    ]

getInstalledPackages :: Verbosity -> PackageDBStack -> ProgramConfiguration
                    -> IO (PackageIndex InstalledPackageInfo)
getInstalledPackages verbosity packageDBs conf = do
   case packageDBs of
     [GlobalPackageDB] -> return ()
     _                 -> die "JHC does not yet support multiple package DBs"

   str <- rawSystemProgramStdoutConf verbosity jhcProgram conf ["--list-libraries"]
   case pCheck (readP_to_S (many (skipSpaces >> parse)) str) of
     [ps] -> return $ PackageIndex.fromList
                    [ emptyInstalledPackageInfo {
                        InstalledPackageInfo.package = p
                      }
                    | p <- ps ]
     _    -> die "cannot parse package list"
  where
    pCheck :: [(a, [Char])] -> [a]
    pCheck rs = [ r | (r,s) <- rs, all isSpace s ]

-- -----------------------------------------------------------------------------
-- Building

-- | Building a package for JHC.
-- Currently C source files are not supported.
buildLib :: Verbosity -> PackageDescription -> LocalBuildInfo
                      -> Library            -> ComponentLocalBuildInfo -> IO ()
buildLib verbosity pkg_descr lbi lib clbi = do
  let Just jhcProg = lookupProgram jhcProgram (withPrograms lbi)
  let libBi = libBuildInfo lib
  let args  = constructJHCCmdLine lbi libBi clbi (buildDir lbi) verbosity
  rawSystemProgram verbosity jhcProg $
    ["-c"] ++ args ++ map display (libModules lib)
  let pkgid = display (packageId pkg_descr)
      pfile = buildDir lbi </> "jhc-pkg.conf"
      hlfile= buildDir lbi </> (pkgid ++ ".hl")
  writeFileAtomic pfile $ jhcPkgConf pkg_descr
  rawSystemProgram verbosity jhcProg ["--build-hl="++pfile, "-o", hlfile]

-- | Building an executable for JHC.
-- Currently C source files are not supported.
buildExe :: Verbosity -> PackageDescription -> LocalBuildInfo
                      -> Executable         -> ComponentLocalBuildInfo -> IO ()
buildExe verbosity _pkg_descr lbi exe clbi = do
  let Just jhcProg = lookupProgram jhcProgram (withPrograms lbi)
  let exeBi = buildInfo exe
  let out   = buildDir lbi </> exeName exe
  let args  = constructJHCCmdLine lbi exeBi clbi (buildDir lbi) verbosity
  rawSystemProgram verbosity jhcProg (["-o",out] ++ args ++ [modulePath exe])

constructJHCCmdLine :: LocalBuildInfo -> BuildInfo -> ComponentLocalBuildInfo
                    -> FilePath -> Verbosity -> [String]
constructJHCCmdLine lbi bi clbi _odir verbosity =
        (if verbosity >= deafening then ["-v"] else [])
     ++ extensionsToFlags (compiler lbi) (extensions bi)
     ++ hcOptions JHC bi
     ++ ["--noauto","-i-"]
     ++ concat [["-i", l] | l <- nub (hsSourceDirs bi)]
     ++ ["-i", autogenModulesDir lbi]
     ++ ["-optc" ++ opt | opt <- PD.ccOptions bi]
     ++ (concat [ ["-p", display pkg] | pkg <- componentPackageDeps clbi ])

jhcPkgConf :: PackageDescription -> String
jhcPkgConf pd =
  let sline name sel = name ++ ": "++sel pd
      Just lib = library pd
      comma = intercalate "," . map display
  in unlines [sline "name" (display . packageId)
             ,"exposed-modules: " ++ (comma (PD.exposedModules lib))
             ,"hidden-modules: " ++ (comma (otherModules $ libBuildInfo lib))
             ]

installLib :: Verbosity -> FilePath -> FilePath -> PackageDescription -> Library -> IO ()
installLib verb dest build_dir pkg_descr _ = do
    let p = display (packageId pkg_descr)++".hl"
    createDirectoryIfMissingVerbose verb True dest
    installOrdinaryFile verb (build_dir </> p) (dest </> p)

installExe :: Verbosity -> FilePath -> FilePath -> (FilePath,FilePath) -> PackageDescription -> Executable -> IO ()
installExe verb dest build_dir (progprefix,progsuffix) _ exe = do
    let exe_name = exeName exe
        src = exe_name </> exeExtension
        out   = (progprefix ++ exe_name ++ progsuffix) </> exeExtension
    createDirectoryIfMissingVerbose verb True dest
    installExecutableFile verb (build_dir </> src) (dest </> out)
