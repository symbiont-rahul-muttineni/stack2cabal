{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | A simplistic model of cabal multi-package files and convertors from Stackage.
module StackageToHackage.Hackage
  ( stackToCabal
  , isHackageDep
  , Project(..), printProject
  , Freeze(..), printFreeze
  , FreezeRemotes(..)
  , PinGHC(..)
  ) where


import           Cabal.Index                    (PackageInfo)
import           Control.Monad                  (forM)
import           Control.Monad.Catch            (handleIOError)
import           Data.List                      (sort, unionBy)
import           Data.List.Extra                (nubOrdOn)
import           Data.List.NonEmpty             (NonEmpty ((:|)))
import qualified Data.List.NonEmpty             as NEL
import qualified Data.Map.Lazy                  as ML
import qualified Data.Map.Strict                as M
import           Data.Maybe                     (fromMaybe, mapMaybe, catMaybes)
import           Data.Semigroup
import qualified Data.HashMap.Strict            as H
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.PackageDescription.Parsec (readGenericPackageDescription)
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription(..))
import           Distribution.Types.PackageDescription (PackageDescription(..))
import           Distribution.Types.PackageId   (PackageIdentifier(..))
import           Distribution.Types.PackageName (PackageName, unPackageName, mkPackageName)
import           Distribution.Verbosity         (silent)
import           Safe                           (headMay)
import           StackageToHackage.Stackage
import           System.FilePath                ((</>),addTrailingPathSeparator)
import           System.FilePattern.Directory   (getDirectoryFiles)
import           System.IO.Temp                 (withSystemTempDirectory)
import           System.Process                 (callProcess)

type HackagePkgs = ML.Map PackageName PackageInfo

newtype FreezeRemotes = FreezeRemotes Bool

newtype PinGHC = PinGHC Bool

-- | Converts a stack.yaml (and list of local packages) to cabal.project and
-- cabal.project.freeze.
stackToCabal :: FreezeRemotes
             -> [PackageName] -- ^ ignore these (local non-hackage pkgs)
             -> HackagePkgs
             -> FilePath
             -> Stack
             -> IO (Project, Freeze)
stackToCabal (FreezeRemotes freezeRemotes) ignore hackageDeps dir stack = do
  resolvers <- unroll dir stack
  let resolver = sconcat resolvers
      project = genProject stack resolver
  localForks <-
      fmap (nubOrdOn pkgName . filter (flip isHackageDep hackageDeps . pkgName) . catMaybes)
    . handleIOError (\_ -> pure [])
    . traverse getPackageIdent
    . NEL.toList
    . pkgs
    $ project
  let freeze = genFreeze resolver localForks ignore
  freezeAll <- if freezeRemotes
               then freezeRemoteRepos project hackageDeps freeze
               else pure freeze
  pure (project, freezeAll)

printProject :: PinGHC -> Project -> Maybe Text -> IO Text
printProject (PinGHC pin) (Project (Ghc ghc) pkgs srcs ghcOpts) hack = do
  ghcOpts' <- printGhcOpts ghcOpts
  pure $ T.concat $ [ "-- Generated by stackage-to-hackage\n\n"] <>
         withCompiler <>
         [ "packages:\n    ", packages, "\n\n"
         , sources, "\n"
         , "allow-older: *\n"
         , "allow-newer: *\n"
         ] <> ghcOpts' <> verbatim hack
  where
    withCompiler
      | pin = ["with-compiler: ", ghc, "\n\n"]
      | otherwise = []
    verbatim Nothing = []
    verbatim (Just txt) = ["\n-- Verbatim\n", txt]
    packages = T.intercalate "\n  , " (T.pack . addTrailingPathSeparator <$>
                                     NEL.toList pkgs)
    sources = T.intercalate "\n" (source =<< srcs)
    source Git{repo, commit, subdirs} =
      let base = T.concat [ "source-repository-package\n    "
                        , "type: git\n    "
                        , "location: ", repo, "\n    "
                        , "tag: ", commit, "\n"]
      in if null subdirs
         then [base]
         else (\d -> T.concat [base, "    subdir: ", d, "\n"]) <$> subdirs

    -- Get the ghc options. This requires IO, because we have to figure out
    -- the local package names.
    printGhcOpts (GhcOptions locals _ everything (PackageGhcOpts packagesGhcOpts)) = do
      -- locals are basically pkgs since cabal-install-3.4.0.0
      localsPrint <- case locals of
        Just x -> fmap concat $ forM pkgs $ \pkg -> do
          name <- fmap (unPackageName . pkgName) <$> getPackageIdent pkg
          pure $ maybe []
            (\n -> if M.member n $ M.mapKeys (unPackageName . pkgName . unPkgId)
                                             packagesGhcOpts
                   then []
                   else ["\npackage ", T.pack n, "\n    ", "flags: ", x, "\n"]
            )
            name
        Nothing -> pure []
      let everythingPrint = case everything of
            Just x -> ["\npackage ", "*", "\n    ", "flags: ", x, "\n"]
            Nothing -> []
      let pkgSpecificPrint = M.foldrWithKey
            (\k a b -> ["\npackage "
                       , (T.pack . unPackageName . pkgName . unPkgId $ k)
                       , "\n    "
                       , "flags: "
                       , a
                       , "\n"] <> b)
            [] packagesGhcOpts
      pure (everythingPrint <> localsPrint <> pkgSpecificPrint)

data Project = Project
    { ghc :: Ghc
    , pkgs :: (NonEmpty FilePath)
    , srcs :: [Git]
    , ghcOpts :: GhcOptions
    } deriving (Show)

genProject :: Stack -> Resolver -> Project
genProject stack Resolver{compiler, deps} = Project
  (fromMaybe (Ghc "ghc") compiler)
  (localDirs stack `appendList` localDeps deps)
  (nubOrdOn repo $ mapMaybe pickGit deps)
  (ghcOptions stack)
  where
    pickGit (Hackage _ )  = Nothing
    pickGit (LocalDep _)  = Nothing
    pickGit (SourceDep g) = Just g
    --
    localDeps = catMaybes . map fromLocalDeps
    fromLocalDeps (Hackage _) = Nothing
    fromLocalDeps (SourceDep _) = Nothing
    fromLocalDeps (LocalDep d) = Just d
    --
    appendList :: NonEmpty a -> [a] -> NonEmpty a
    appendList (x:|xs) ys = x:|(xs++ys)

printFreeze :: Freeze -> Text
printFreeze (Freeze deps (Flags flags)) =
  T.concat [ "constraints: ", constraints, "\n"]
  where
    spacing = ",\n             "
    constraints = T.intercalate spacing (constrait <$> sort deps)
    constrait pkg =
      let name = (T.pack . unPackageName . pkgName $ pkg)
          ver  = (T.pack . prettyShow . pkgVersion $ pkg)
          base = T.concat ["any.", name, " ==", ver]
      in case M.lookup name flags of
        Nothing      -> base
        Just entries -> T.concat [name, " ", (custom entries), spacing, base]
    custom (M.toList -> lst) = T.intercalate " " $ (renderFlag <$> lst)
    renderFlag (name, True)  = "+" <> name
    renderFlag (name, False) = "-" <> name

data Freeze = Freeze [PackageIdentifier] Flags deriving (Show)

genFreeze :: Resolver
          -> [PackageIdentifier] -- ^ additional local hackage forks (vendored)
          -> [PackageName]       -- ^ ignore these (local non-hackage deps)
          -> Freeze
genFreeze Resolver{deps, flags} localForks ignore =
  let pkgs = filter noSelfs $ unPkgId <$> mapMaybe pick deps
      uniqpkgs = nubOrdOn pkgName (unionBy (\a b -> pkgName a == pkgName b) localForks pkgs)
   in Freeze uniqpkgs flags
  where pick (Hackage p)   = Just p
        pick (SourceDep _) = Nothing
        pick (LocalDep _) = Nothing
        noSelfs (pkgName -> n) = notElem n ignore


-- | Acquire all package identifiers from a list of subdirs
-- of a git repository.
getPackageIdents :: Git -> IO [PackageIdentifier]
getPackageIdents (Git (T.unpack -> repo) (T.unpack -> commit) (fmap T.unpack -> subdirs)) =
  withSystemTempDirectory "stack2cabal" $ \dir -> do
    callProcess "git" ["clone", repo, dir]
    callProcess "git" ["-C", dir, "reset", "--hard", commit]
    forM subdirs $ \subdir -> do
      (Just pid) <- getPackageIdent (dir </> subdir)
      pure pid

-- | Get package identifier from project directory.
getPackageIdent :: FilePath  -- ^ absolute path to project repository
                -> IO (Maybe PackageIdentifier)
getPackageIdent dir = do
  cabalFile <- headMay <$> getDirectoryFiles dir ["*.cabal"]
  forM cabalFile $ \f->
    (package . packageDescription)
      <$> readGenericPackageDescription silent (dir </> f)

-- | Also freeze all remote repositories that are hackage deps.
freezeRemoteRepos :: Project -> HackagePkgs -> Freeze -> IO Freeze
freezeRemoteRepos (Project { srcs }) hackageDeps (Freeze deps flags) = do
  clonedDeps <- fmap concat
    $ forM srcs
    $ \src -> fmap (filter (flip isHackageDep hackageDeps . pkgName))
        . getPackageIdents
        $ src
  let newDeps = fromHM $ H.union (toHM clonedDeps) (toHM deps)
  pure $ Freeze newDeps flags
 where
  toHM = H.fromList . fmap (\(PackageIdentifier a b) -> (unPackageName a, b))
  fromHM = fmap (\(a, b) -> PackageIdentifier (mkPackageName a) b) . H.toList


-- | Whether this package is on hackage. This is checked against the local
-- index.
isHackageDep :: PackageName
             -> HackagePkgs -- ^ the local index
             -> Bool
isHackageDep = ML.member
