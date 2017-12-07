
module Network.WorkerSpec (main, spec) where

import Test.Hspec

import Data.Config
import Network.Worker

import Control.Distributed.Process
import Control.Distributed.Process.Node (localNodeId, runProcess, forkProcess, initRemoteTable, newLocalNode)
import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)
--import Control.Distributed.Process.Backend.SimpleLocalnet

import Control.Monad
import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.MVar
import Data.Set (Set)
import qualified Data.Set as S

import System.Random.MWC
import Data.Vector (singleton)

main :: IO ()
main = hspec spec

data Network
  = Normal
  | Netsplit
  | BigNetsplit
  | FaultySends Double
  | FaultyPeerLocation Double

runNetwork :: Network -> IO [(Int,Double)]

runNetwork Normal = do
  results <- newMVar []
  peers   <- newMVar []
  
  transports <- forM [1..7] $ \n -> do
    let port = show (12340 + n)
    --backend <- initializeBackend "127.0.0.1" port initRemoteTable
    result <- createTransport "127.0.0.1" port (\p -> ("127.0.0.1", p)) defaultTCPParameters
    either (error . show) return result

  configs <- forM transports $ \transport -> do
    gen <- initialize (singleton 0)
    return $ Config { sendDuration = 10
                    , waitDuration = 10
                    , rng = uniformR (0,1) gen
                    , makeLocalNode = newLocalNode transport initRemoteTable
                    , announce = return ()
                    , network = liftIO (readMVar peers)
                    , quorum = 4
                    }

  nodes <- forM configs $ \config -> do
    node <- makeLocalNode config
    modifyMVar_ peers (return . (localNodeId node:))
    return node

  tasks <- forM (zip nodes configs) $ \(node, config) -> do
    pid  <- forkProcess node $ do self <- getSelfPid
                                  liftIO $ putStrLn (show self ++ " started.")
                                  ans@(n,v) <- work config
                                  liftIO $ putStrLn ("<" ++ show n ++ "," ++ show v ++ ">")
                                  liftIO $ modifyMVar_ results (return . (ans:))
    return (node, pid)

  putStrLn "*** waiting..."
  threadDelay (1000000 * 20)
  putStrLn "*** killing tasks..."
  forM_ tasks (\(node,pid) -> forkProcess node $ kill pid "time's up!")

  putStrLn "*** closing transport..."
  forM_ transports (forkIO . closeTransport)

  putStrLn "*** returning the results..."
  takeMVar results
  
spec :: Spec

spec = do

  describe "the number-passing protocol" $ do

    context "under normal network conditions" $ do

      result <- runIO (runNetwork Normal)
      
      it "agrees on a canonical set of messages" $ do
        S.size (S.fromList result) `shouldBe` 1

      it "obtains a response from all nodes" $ do
        length result `shouldBe` 7
      
