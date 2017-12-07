{-# LANGUAGE DeriveGeneric #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Node

import Data.Config
import Network.Worker (iohk)

main :: IO ()
main = do
  config <- getConfig
  node   <- makeLocalNode config
  pid    <- forkProcess node (iohk config)
  
  threadDelay (1000000 * (sendDuration config + waitDuration config))
  
  runProcess node (kill pid "time's up!")
