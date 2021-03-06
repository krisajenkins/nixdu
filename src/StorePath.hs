{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

module StorePath
  ( StoreName (..),
    storeNameToPath,
    storeNameToText,
    storeNameToShortText,
    StorePath (..),
    StoreEnv (..),
    withStoreEnv,
    seLookup,
    seGetRoots,
    seBottomUp,
    seFetchRefs,
  )
where

import Control.Monad (fail)
import Data.Aeson ((.:), FromJSON (..), Value (..), decode)
import qualified Data.HashMap.Strict as HM
import Data.HashMap.Strict (HashMap)
import qualified Data.HashSet as HS
import qualified Data.Text as T
import Protolude
import System.FilePath.Posix (splitDirectories)
import System.Process.Typed (proc, readProcessStdout_)

--------------------------------------------------------------------------------

newtype StoreName s = StoreName Text
  deriving newtype (Show, Eq, Ord, Hashable, NFData)

mkStoreName :: FilePath -> Maybe (StoreName a)
mkStoreName path =
  case splitDirectories path of
    "/" : "nix" : "store" : name : _ -> Just . StoreName $ toS name
    _ -> Nothing

storeNameToText :: StoreName a -> Text
storeNameToText (StoreName n) = n

storeNameToPath :: StoreName a -> FilePath
storeNameToPath (StoreName sn) = "/nix/store/" <> toS sn

storeNameToShortText :: StoreName a -> Text
storeNameToShortText = T.drop 1 . T.dropWhile (/= '-') . storeNameToText

--------------------------------------------------------------------------------

data StorePath s ref payload = StorePath
  { spName :: StoreName s,
    spSize :: Int,
    spRefs :: [ref],
    spPayload :: payload
  }
  deriving (Show, Eq, Ord, Functor, Generic)

instance (NFData a, NFData b) => NFData (StorePath s a b)

mkStorePaths :: NonEmpty (StoreName s) -> IO [StorePath s (StoreName s) ()]
mkStorePaths names = do
  infos <-
    decode @[NixPathInfoResult]
      <$> readProcessStdout_
        ( proc
            "nix"
            ( ["path-info", "--recursive", "--json"]
                ++ map storeNameToPath (toList names)
            )
        )
      >>= maybe (fail "Failed parsing nix path-info output.") return
      >>= mapM assertValidInfo
  mapM infoToStorePath infos
  where
    infoToStorePath NixPathInfo {npiPath, npiNarSize, npiReferences} = do
      name <- mkStoreNameIO npiPath
      refs <- filter (/= name) <$> mapM mkStoreNameIO npiReferences
      return $
        StorePath
          { spName = name,
            spRefs = refs,
            spSize = npiNarSize,
            spPayload = ()
          }
    mkStoreNameIO p =
      maybe
        (fail $ "Failed parsing Nix store path: " ++ show p)
        return
        (mkStoreName p)
    assertValidInfo (NixPathInfoValid pi) = return pi
    assertValidInfo (NixPathInfoInvalid path) =
      fail $ "Invalid path: " ++ path ++ ". Inconsistent /nix/store or ongoing GC."

--------------------------------------------------------------------------------

data StoreEnv s payload = StoreEnv
  { sePaths :: HashMap (StoreName s) (StorePath s (StoreName s) payload),
    seRoots :: NonEmpty (StoreName s)
  }
  deriving (Functor, Generic, NFData)

withStoreEnv ::
  forall m a.
  MonadIO m =>
  NonEmpty FilePath ->
  (forall s. StoreEnv s () -> m a) ->
  m (Either [FilePath] a)
withStoreEnv fnames cb = do
  let names' =
        fnames
          & toList
          & map (\f -> maybe (Left f) Right (mkStoreName f))
          & partitionEithers

  case names' of
    (errs@(_ : _), _) -> return (Left errs)
    ([], xs) -> case nonEmpty xs of
      Nothing -> panic "invariant violation"
      Just names -> do
        paths <- liftIO $ mkStorePaths names
        let env =
              StoreEnv
                ( paths
                    & map (\p@StorePath {spName} -> (spName, p))
                    & HM.fromList
                )
                names
        Right <$> cb env

seLookup :: StoreEnv s a -> StoreName s -> StorePath s (StoreName s) a
seLookup StoreEnv {sePaths} name =
  fromMaybe
    (panic $ "invariant violation, StoreName not found: " <> show name)
    (HM.lookup name sePaths)

seGetRoots :: StoreEnv s a -> NonEmpty (StorePath s (StoreName s) a)
seGetRoots env@StoreEnv {seRoots} =
  map (seLookup env) seRoots

seFetchRefs ::
  StoreEnv s a ->
  (StoreName s -> Bool) ->
  NonEmpty (StoreName s) ->
  [StorePath s (StoreName s) a]
seFetchRefs env predicate =
  fst
    . foldl'
      (\(acc, visited) name -> go acc visited name)
      ([], HS.empty)
  where
    go acc visited name
      | HS.member name visited = (acc, visited)
      | not (predicate name) = (acc, visited)
      | otherwise =
        let sp@StorePath {spRefs} = seLookup env name
         in foldl'
              (\(acc', visited') name' -> go acc' visited' name')
              (sp : acc, HS.insert name visited)
              spRefs

seBottomUp ::
  forall s a b.
  (StorePath s (StorePath s (StoreName s) b) a -> b) ->
  StoreEnv s a ->
  StoreEnv s b
seBottomUp f StoreEnv {sePaths, seRoots} =
  StoreEnv
    { sePaths = snd $ execState (mapM_ go seRoots) (sePaths, HM.empty),
      seRoots
    }
  where
    unsafeLookup k m =
      fromMaybe
        (panic $ "invariant violation: name doesn't exists: " <> show k)
        (HM.lookup k m)
    go ::
      StoreName s ->
      State
        ( HashMap (StoreName s) (StorePath s (StoreName s) a),
          HashMap (StoreName s) (StorePath s (StoreName s) b)
        )
        (StorePath s (StoreName s) b)
    go name = do
      bs <- gets snd
      case name `HM.lookup` bs of
        Just sp -> return sp
        Nothing -> do
          sp@StorePath {spName, spRefs} <- unsafeLookup name <$> gets fst
          refs <- mapM go spRefs
          let new = sp {spPayload = f sp {spRefs = refs}}
          modify
            ( \(as, bs) ->
                ( HM.delete spName as,
                  HM.insert spName new bs
                )
            )
          return new

--------------------------------------------------------------------------------

data NixPathInfo = NixPathInfo
  { npiPath :: FilePath,
    npiNarSize :: Int,
    npiReferences :: [FilePath]
  }

data NixPathInfoResult
  = NixPathInfoValid NixPathInfo
  | NixPathInfoInvalid FilePath

instance FromJSON NixPathInfoResult where
  parseJSON (Object obj) =
    ( NixPathInfoValid
        <$> ( NixPathInfo
                <$> obj .: "path"
                <*> obj .: "narSize"
                <*> obj .: "references"
            )
    )
      <|> ( do
              path <- obj .: "path"
              valid <- obj .: "valid"
              guard (not valid)
              return $ NixPathInfoInvalid path
          )
  parseJSON _ = fail "Expecting an object."
