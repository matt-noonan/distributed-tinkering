{-# LANGUAGE DeriveGeneric #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Node

import Data.Config

import Control.Monad (forM_)

import Network.Worker (work)

main :: IO ()
main = do
  config <- getConfig
  node   <- makeLocalNode config

  magic <- rng config
  putStrLn ("*** Started  " ++ show magic) 
  pid    <- forkProcess node (work config)
  
  threadDelay (1000000 * (sendDuration config + waitDuration config + 10))
  putStrLn ("*** Out of time! " ++ show magic)
  runProcess node (kill pid "time's up!")
  
  putStrLn ("*** Finished " ++ show magic) 
