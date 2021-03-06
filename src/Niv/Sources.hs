{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

module Niv.Sources where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.FileEmbed (embedFile)
import Data.Bifunctor (first)
import Data.Hashable (Hashable)
import Data.List
import Data.String.QQ (s)
import Data.Text.Extended
import Niv.Logger
import Niv.Update
import System.FilePath ((</>))
import UnliftIO
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Extended as Aeson
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.Digest.Pure.MD5 as MD5
import qualified Data.HashMap.Strict as HMS
import qualified Data.Text as T
import qualified System.Directory as Dir

-------------------------------------------------------------------------------
-- sources.json related
-------------------------------------------------------------------------------

-- | Where to find the sources.json
data FindSourcesJson
  = Auto -- ^ use the default (nix/sources.json)
  | AtPath FilePath -- ^ use the specified file path

data SourcesError
  = SourcesDoesntExist
  | SourceIsntJSON
  | SpecIsntAMap

newtype Sources = Sources
  { unSources :: HMS.HashMap PackageName PackageSpec }
  deriving newtype (FromJSON, ToJSON)

getSourcesEither :: FindSourcesJson -> IO (Either SourcesError Sources)
getSourcesEither fsj = do
    Dir.doesFileExist (pathNixSourcesJson fsj) >>= \case
      False -> pure $ Left SourcesDoesntExist
      True ->
        Aeson.decodeFileStrict (pathNixSourcesJson fsj) >>= \case
          Just value -> case valueToSources value of
            Nothing -> pure $ Left SpecIsntAMap
            Just srcs -> pure $ Right srcs
          Nothing -> pure $ Left SourceIsntJSON
  where
    valueToSources :: Aeson.Value -> Maybe Sources
    valueToSources = \case
        Aeson.Object obj -> fmap (Sources . mapKeys PackageName) $ traverse
          (\case
            Aeson.Object obj' -> Just (PackageSpec obj')
            _ -> Nothing
          ) obj
        _ -> Nothing
    mapKeys :: (Eq k2, Hashable k2) => (k1 -> k2) -> HMS.HashMap k1 v -> HMS.HashMap k2 v
    mapKeys f = HMS.fromList . map (first f) . HMS.toList

getSources :: FindSourcesJson -> IO Sources
getSources fsj = do
    warnIfOutdated
    getSourcesEither fsj >>= either
      (\case
        SourcesDoesntExist -> (abortSourcesDoesntExist fsj)
        SourceIsntJSON -> (abortSourcesIsntJSON fsj)
        SpecIsntAMap -> (abortSpecIsntAMap fsj)
      ) pure

setSources :: FindSourcesJson -> Sources -> IO ()
setSources fsj sources = Aeson.encodeFilePretty (pathNixSourcesJson fsj) sources

newtype PackageName = PackageName { unPackageName :: T.Text }
  deriving newtype (Eq, Hashable, FromJSONKey, ToJSONKey, Show)

newtype PackageSpec = PackageSpec { unPackageSpec :: Aeson.Object }
  deriving newtype (FromJSON, ToJSON, Show, Semigroup, Monoid)

-- | Simply discards the 'Freedom'
attrsToSpec :: Attrs -> PackageSpec
attrsToSpec = PackageSpec . fmap snd

-- | @nix/sources.json@ or pointed at by 'FindSourcesJson'
pathNixSourcesJson :: FindSourcesJson -> FilePath
pathNixSourcesJson = \case
    Auto -> "nix" </> "sources.json"
    AtPath f -> f

--
-- ABORT messages
--

abortSourcesDoesntExist :: FindSourcesJson -> IO a
abortSourcesDoesntExist fsj = abort $ T.unlines [ line1, line2 ]
  where
    line1 = "Cannot use " <> T.pack (pathNixSourcesJson fsj)
    line2 = [s|
The sources file does not exist! You may need to run 'niv init'.
|]

abortSourcesIsntJSON :: FindSourcesJson -> IO a
abortSourcesIsntJSON fsj = abort $ T.unlines [ line1, line2 ]
  where
    line1 = "Cannot use " <> T.pack (pathNixSourcesJson fsj)
    line2 = "The sources file should be JSON."

abortSpecIsntAMap :: FindSourcesJson -> IO a
abortSpecIsntAMap fsj = abort $ T.unlines [ line1, line2 ]
  where
    line1 = "Cannot use " <> T.pack (pathNixSourcesJson fsj)
    line2 = [s|
The package specifications in the sources file should be JSON maps from
attribute name to attribute value, e.g.:
  { "nixpkgs": { "foo": "bar" } }
|]

-------------------------------------------------------------------------------
-- sources.nix related
-------------------------------------------------------------------------------


-- | All the released versions of nix/sources.nix
data SourcesNixVersion
  = V1
  | V2
  | V3
  | V4
  | V5
  | V6
  | V7
  | V8
  | V9
  | V10
  | V11
  | V12
  | V13
  deriving stock (Bounded, Enum, Eq)

-- | A user friendly version
sourcesVersionToText :: SourcesNixVersion -> T.Text
sourcesVersionToText = \case
    V1 -> "1"
    V2 -> "2"
    V3 -> "3"
    V4 -> "4"
    V5 -> "5"
    V6 -> "6"
    V7 -> "7"
    V8 -> "8"
    V9 -> "9"
    V10 -> "10"
    V11 -> "11"
    V12 -> "12"
    V13 -> "13"

latestVersionMD5 :: T.Text
latestVersionMD5 = sourcesVersionToMD5 maxBound

-- | Find a version based on the md5 of the nix/sources.nix
md5ToSourcesVersion :: T.Text -> Maybe SourcesNixVersion
md5ToSourcesVersion md5 =
    find (\snv -> sourcesVersionToMD5 snv == md5) [minBound .. maxBound]

-- | The MD5 sum of a particular version
sourcesVersionToMD5 :: SourcesNixVersion -> T.Text
sourcesVersionToMD5 = \case
    V1 -> "a7d3532c70fea66ffa25d6bc7ee49ad5"
    V2 -> "24cc0719fa744420a04361e23a3598d0"
    V3 -> "e01ed051e2c416e0fc7355fc72aeee3d"
    V4 -> "f754fe0e661b61abdcd32cb4062f5014"
    V5 -> "c34523590ff7dec7bf0689f145df29d1"
    V6 -> "8143f1db1e209562faf80a998be4929a"
    V7 -> "00a02cae76d30bbef96f001cabeed96f"
    V8 -> "e8b860753dd7fa1fd7b805dd836eb607"
    V9 -> "87149616c1b3b1e5aa73178f91c20b53"
    V10 -> "d8625c0a03dd935e1c79f46407faa8d3"
    V11 -> "8a95b7d93b16f7c7515d98f49b0ec741"
    V12 -> "2f9629ad9a8f181ed71d2a59b454970c"
    V13 -> "5e23c56b92eaade4e664cb16dcac1e0a"

-- | The MD5 sum of ./nix/sources.nix
sourcesNixMD5 :: IO T.Text
sourcesNixMD5 = T.pack . show . MD5.md5 <$> BL8.readFile pathNixSourcesNix

-- | @nix/sources.nix@
pathNixSourcesNix :: FilePath
pathNixSourcesNix = "nix" </> "sources.nix"

warnIfOutdated :: IO ()
warnIfOutdated = do
    tryAny (BL8.readFile pathNixSourcesNix) >>= \case
      Left e -> tsay $ T.unlines -- warn with tsay
        [ T.unwords [ tyellow "WARNING:",  "Could not read" , T.pack pathNixSourcesNix ]
        , T.unwords [ "  ", "(", tshow e, ")" ]
        ]
      Right content -> do
        case md5ToSourcesVersion (T.pack $ show $ MD5.md5 content) of
          -- This is a custom or newer version, we don't do anything
          Nothing -> pure ()
          Just v
            -- The file is the latest
            | v == maxBound -> pure ()
            -- The file is older than than latest
            | otherwise -> do
                tsay $ T.unlines
                  [ T.unwords
                        [ tbold $ tblue "INFO:"
                        , "new sources.nix available:"
                        , sourcesVersionToText v, "->", sourcesVersionToText maxBound
                        ]
                  , "  Please run 'niv init' or add the following line in the " <>
                    T.pack pathNixSourcesNix <> " file:"
                  , "  # niv: no_update"
                  ]

-- | Glue code between nix and sources.json
initNixSourcesNixContent :: B.ByteString
initNixSourcesNixContent = $(embedFile "nix/sources.nix")

-- | Empty JSON map
initNixSourcesJsonContent :: B.ByteString
initNixSourcesJsonContent = "{}"
