{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}

module Data.Config
  ( Config(..)
  , getConfig
  ) where

import Control.Monad (when, forM_)
import Control.Monad.Primitive
import Data.Maybe (fromMaybe)
import System.Exit (die)
import System.Random.MWC
import Options.Generic
import Data.Vector (singleton)

import Control.Distributed.Process hiding (die)
import Control.Distributed.Process.Node (LocalNode, initRemoteTable)
import Control.Distributed.Process.Serializable

-- Tweak this for other backends
import Control.Distributed.Process.Backend.SimpleLocalnet

-- These are from the Network.Socket module, but it seems silly
-- to add a dep and import just to pick up two type aliases.
type HostName    = String
type ServiceName = String

data RawConfig w = RawConfig
  { sendFor  :: w ::: Int
                <?> "Duration of message-sending phase in seconds."
  , waitFor  :: w ::: Int
                <?> "Duration of wait period in seconds."
  , withSeed :: w ::: Maybe Int
                <?> "Seed for the random number generator (defaults to 0)."
  , host     :: w ::: HostName
                <?> "Host"
  , port     :: w ::: ServiceName
                <?> "Port"
  }
  deriving Generic

instance ParseRecord (RawConfig Wrapped) where
    parseRecord = parseRecordWithModifiers lispCaseModifiers

data Config = Config
  { sendDuration  :: Int
  , waitDuration  :: Int
  , rng :: IO Double
  , makeLocalNode :: IO LocalNode
  , announce :: Process ()
  , network :: Process [NodeId]
  , broadcast :: forall a. Serializable a => [NodeId] -> String -> a -> Process ()
  , quorum :: Int
  }

-- | Read the configuration from the command line, or report any problems.
getConfig :: IO Config
getConfig = do
  config <- unwrapRecord "Tinkering with Cloud Haskell"

  when (sendFor config <= 0) $ die "Duration of message-sending phase must be positive."
  when (waitFor config <= 0) $ die "Duration of wait period must be positive."

  let seed = (fromIntegral . fromMaybe 0 . withSeed) config
  gen <- initialize (singleton seed)

  backend <- initializeBackend (host config) (port config) initRemoteTable
  
  return (Config { sendDuration = sendFor config
                 , waitDuration = waitFor config
                 , rng = uniformR (0,1) gen
                 , makeLocalNode = newLocalNode backend
                 , announce = return ()
                 , network = liftIO (findPeers backend 1000000)
                 , broadcast = \peers name msg -> (forM_ peers $ \peer -> nsendRemote peer name msg)
                 , quorum = 4
                 } )
