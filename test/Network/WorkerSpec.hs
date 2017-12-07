
module Network.WorkerSpec (main, spec) where

import Test.Hspec

import Data.Config
import Network.Worker

import Control.Distributed.Process
import Control.Distributed.Process.Node (LocalNode, localNodeId, runProcess, forkProcess, initRemoteTable, newLocalNode)
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
import GHC.Word (Word32)

main :: IO ()
main = hspec spec

data Network
  = Normal
  | Netsplit
  | BigNetsplit
  | FaultySends Double
  | FaultyPeerLocation Double

withTransports :: Int -> ([Transport] -> IO a) -> IO a
withTransports n action = do
  -- Get the transports
  transports <- forM [1..n] $ \k -> do
    let port = show (12340 + k)
    result <- createTransport "127.0.0.1" port (\p -> ("127.0.0.1", p)) defaultTCPParameters
    either (error . show) return result

  -- Run the action, and then clean up the connections.
  ans <- action transports

  -- TODO: use bracket or something..
  forM_ transports closeTransport
  return ans

defaultConfig :: MVar [NodeId] -> Int -> (Transport, Word32) -> IO Config
defaultConfig peers quorumSize (transport, seed) = do
  gen <- initialize (singleton seed)
  return $ Config { sendDuration = 10
                  , waitDuration = 10
                  , rng = uniformR (0,1) gen
                  , makeLocalNode = newLocalNode transport initRemoteTable
                  , announce = return ()
                  , network = liftIO (readMVar peers)
                  , quorum = quorumSize
                  }

run :: Config -> MVar [(Int,Double)] -> Process ()
run config results = do
  ans@(n,v) <- work config
  liftIO $ do
    putStrLn ("<" ++ show n ++ "," ++ show v ++ ">")
    modifyMVar_ results (return . (ans:))
                                  
runNetwork :: Network -> IO [(Int,Double)]

runNetwork net = withTransports 7 $ \transports -> do
  results <- newMVar []

  let quorumSize = 1 + (length transports `div` 2)
  net <- configureNetwork net quorumSize transports

  tasks <- forM net $ \(node, config) -> do
    pid  <- forkProcess node (run config results)
    return (node, pid)

  -- Wait for the timeout period, then kill everything left over.
  threadDelay (1000000 * 20)
  forM_ tasks (\(node,pid) -> forkProcess node $ kill pid "time's up!")

  takeMVar results

chunksOf :: Int -> [a] -> [[a]]
chunksOf n [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

configureNetwork :: Network -> Int -> [Transport] -> IO [(LocalNode, Config)]

configureNetwork Normal quorumSize transports = do

  peers   <- newMVar []
  
  configs <- mapM (defaultConfig peers quorumSize) (zip transports [1..])

  forM configs $ \config -> do
    node <- makeLocalNode config
    modifyMVar_ peers (return . (localNodeId node:))
    return (node, config)

configureNetwork Netsplit quorumSize transports = do

  net1 <- configureNetwork Normal quorumSize (take quorumSize transports)
  net2 <- configureNetwork Normal quorumSize (drop quorumSize transports)

  return (net1 ++ net2)

configureNetwork BigNetsplit quorumSize transports = do
  let fragments = chunksOf (quorumSize - 1) transports
  concat <$> mapM (configureNetwork Normal quorumSize) fragments

spec :: Spec

spec = do

  describe "the number-passing protocol" $ do

    context "under normal network conditions" $ do

      result <- runIO (runNetwork Normal)
      
      it "agrees on a canonical set of messages" $ do
        S.size (S.fromList result) `shouldBe` 1

      it "obtains a response from all nodes" $ do
        length result `shouldBe` 7
      
    context "under binary netsplit conditions" $ do

      result <- runIO (runNetwork Netsplit)

      it "agrees on a canonical set of messages" $ do
        S.size (S.fromList result) `shouldBe` 1

      it "obtains a response from all nodes in the majority component" $ do
        length result `shouldBe` 4

    context "under netsplit conditions with no majority" $ do

      result <- runIO (runNetwork Netsplit)

      it "does not report anything" $ result `shouldBe` []


