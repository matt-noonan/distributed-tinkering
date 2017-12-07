{-# LANGUAGE RankNTypes #-}

module Network.WorkerSpec (main, spec) where

import Test.Hspec

import Data.Config
import Network.Worker

import Control.Distributed.Process
import Control.Distributed.Process.Node (LocalNode, localNodeId, runProcess, forkProcess, initRemoteTable, newLocalNode)
import Control.Distributed.Process.Serializable
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

-- | Network scenarios to test
data Scenario
  = Normal
  | Netsplit
  | BigNetsplit
  | FlakySends Double
  | FlakyPeerLocation Double
  deriving Show

spec :: Spec
spec = do

  describe "the number-passing protocol" $ do

    context "under normal network conditions" $ do

      result <- runIO (runNetwork Normal)
      it "agrees on a canonical set of messages" (S.size (S.fromList result) `shouldBe` 1)
      it "obtains a response from all nodes"     (length result `shouldBe` 7)
      
    context "under binary netsplit conditions" $ do
      
      result <- runIO (runNetwork Netsplit)
      
      it "agrees on a canonical set of messages" (S.size (S.fromList result) `shouldBe` 1)
      it "obtains a majority response"           (length result `shouldBe` 4)

    context "under a netsplit with no majority components" $ do

      result <- runIO (runNetwork BigNetsplit)

      it "does not receive a response from any node" (result `shouldBe` [])
        
    context "under flaky peer location" $ do

      result <- runIO (runNetwork (FlakyPeerLocation 0.5))

      it "agrees on a canonical set of messages" (S.size (S.fromList result) `shouldBe` 1)

    context "under flaky message sending" $ do

      result <- runIO (runNetwork (FlakySends 0.5))

      it "agrees on a canonical set of messages" (S.size (S.fromList result) `shouldBe` 1)
        
-- | Create some Transports, pass them to the action, and clean up after.           
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

-- | Create a default node configuration with the given transport and random seed.
defaultConfig :: MVar [NodeId] -> Int -> (Transport, Word32) -> IO Config
defaultConfig peers quorumSize (transport, seed) = do
  gen <- initialize (singleton seed)
  return $ Config { sendDuration = 10
                  , waitDuration = 10
                  , rng = uniformR (0,1) gen
                  , makeLocalNode = newLocalNode transport initRemoteTable
                  , announce = return ()
                  , network = liftIO (readMVar peers)
                  , broadcast = \peers name msg -> (forM_ peers $ \peer -> nsendRemote peer name msg)
                  , quorum = quorumSize
                  }

-- | Run the protocol and cons the result into the results list.
run :: Config -> MVar [(Int,Double)] -> Process ()
run config results = do
  ans@(n,v) <- work config
  liftIO $ do
    putStrLn ("<" ++ show n ++ "," ++ show v ++ ">")
    modifyMVar_ results (return . (ans:))

-- | Create and execute the protocol over a 7-node network,
--   subject to the given failure scenario.
runNetwork :: Scenario -> IO [(Int,Double)]

runNetwork scenario = withTransports 7 $ \transports -> do

  putStrLn ("*** Running " ++ show scenario ++ " network scenario.")
  
  results <- newMVar []

  let quorumSize = 1 + (length transports `div` 2)
  net <- configureNetwork scenario quorumSize transports

  -- Launch each worker task
  tasks <- forM net $ \(node, config) -> do
    pid  <- forkProcess node (run config results)
    return (node, pid)

  -- Wait for the timeout period, then kill everything left over.
  threadDelay (1000000 * 20)
  forM_ tasks (\(node,pid) -> forkProcess node $ kill pid "time's up!")

  takeMVar results

-- | Configure a network for the given failure scenario.

configureNetwork :: Scenario -> Int -> [Transport] -> IO [(LocalNode, Config)]

  -- A normal, healthy network.
configureNetwork Normal quorumSize transports = do
  peers   <- newMVar []  
  configs <- mapM (defaultConfig peers quorumSize) (zip transports [1..])

  forM configs $ \config -> do
    node <- makeLocalNode config
    modifyMVar_ peers (return . (localNodeId node:))
    return (node, config)

-- A network split into two components
configureNetwork Netsplit quorumSize transports = do

  net1 <- configureNetwork Normal quorumSize (take quorumSize transports)
  net2 <- configureNetwork Normal quorumSize (drop quorumSize transports)

  return (net1 ++ net2)

-- A network split into components that are each too small to form a majority.
configureNetwork BigNetsplit quorumSize transports = do
  let fragments = chunksOf (quorumSize - 1) transports
  concat <$> mapM (configureNetwork Normal quorumSize) fragments

-- A network where peer location only succeeds with probability 'prob'.
configureNetwork (FlakyPeerLocation prob) quorumSize transports = do
  net <- configureNetwork Normal quorumSize transports
  forM net $ \(node, config) -> do
    let coin = (<= prob) <$> liftIO (rng config)
    return (node, config { network = network config >>= flaky coin })

-- A network where messages only send successfully with probability 'prob'.
configureNetwork (FlakySends prob) quorumSize transports = do
  net <- configureNetwork Normal quorumSize transports

  forM net $ \(node, config) -> do
    let badBroadcast :: forall a. Serializable a => [NodeId] -> String -> a -> Process ()
        badBroadcast network name msg = do
          let coin = (<= prob) <$> liftIO (rng config)
          subset <- flaky coin network
          (broadcast config) subset name msg
          
    return (node, config { broadcast = badBroadcast })

-- | Given a list and a source of booleans, drop elements of
--   the list whenever the source yields False.
flaky :: Monad m => m Bool -> [a] -> m [a]
flaky coin results = fmap concat $ forM results $ \x -> do
  flip <- coin
  return (if flip then [x] else [])

chunksOf :: Int -> [a] -> [[a]]
chunksOf n [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)


