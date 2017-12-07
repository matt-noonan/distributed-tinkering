{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}

module Network.Worker
  ( work
  ) where

import Prelude hiding (log)

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable

import GHC.Generics
import Data.Binary (Binary)

import Data.Config

import Control.Monad (forM_)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S

import Control.Concurrent.MVar

import Control.Monad.Reader
import Data.Time.Clock
import Data.Maybe
import Data.Binary.Orphans
import Data.List (foldl')

data Msg = Msg { payload :: Double
               , sender  :: ProcessId
               , timestamp :: UTCTime } deriving (Eq, Show, Generic)

instance Ord Msg where
  compare x y = compare (timestamp x, sender x, payload x) (timestamp y, sender y, payload y)
  
instance Binary Msg

(%=) :: MonadIO m => MVar a -> (a -> a) -> m a
mvar %= f = liftIO (modifyMVar mvar (\x -> let x' = f x in return (x',x')))

inspect :: MonadIO m => MVar a -> m a
inspect mvar = liftIO (readMVar mvar)

accumulate :: MVar (Set Msg) -> Process ()
accumulate seen = forever (receiveWait [ match (\msg -> seen %= S.insert msg) ])
    
yakker :: Config -> (Msg -> Process ()) -> Process ()
yakker config broadcast = do
  self <- getSelfPid
  
  forever $ do
    now <- liftIO getCurrentTime
    x   <- liftIO (rng config)
    broadcast (Msg { payload   = x,
                     sender    = self,
                     timestamp = now })
      
work :: Config -> Process ()
work config = do
  
    -- Announce our existence to the network
    liftIO $ putStrLn "announcing myself"
    announce config

    liftIO (threadDelay 1000000)
    
    -- Gather the process ids for this network
    liftIO $ putStrLn "getting network configuration..."
    net <- network config
    let broadcastTo name = \msg -> forM_ net $ \node -> nsendRemote node name msg
        quorumSize = quorum config
    liftIO $ putStrLn ("got: " ++ show net)
    liftIO $ putStrLn ("quorum size is " ++ show quorumSize)

    -- Spawn another worker on the local node
    liftIO $ putStrLn "spawning a worker locally..."
    seen <- liftIO (newMVar S.empty)
    register "iohk-test" =<< spawnLocal (accumulate seen)

    -- Send everybody in the network a message
    liftIO $ putStrLn "saying hello..."
    self <- getSelfPid

    yak <- spawnLocal (yakker config (broadcastTo "iohk-test"))

    liftIO $ putStrLn "waiting..."

    liftIO $ do
      now <- getCurrentTime
      putStrLn ("began waiting at " ++ show now)
      threadDelay (1000000 * sendDuration config)
      now <- getCurrentTime
      putStrLn ("...ended waiting at " ++ show now)

    kill yak "hush"

    liftIO $ putStrLn "making an agreement..."

    canonical <- liftIO (newMVar S.empty)
    register "writer" =<< spawnLocal (applyWrite canonical)

    answer <- liftIO newEmptyMVar
    register "answer" =<< spawnLocal (tallyVotes answer quorumSize)
    
    -- Spawn a worker that will periodically check the 'seen' set and,
    -- if there are elements of seen that are not yet canonical,
    -- request a distributed write of the new elements.
    _ <- spawnLocal (requestWrite (broadcastTo "writer") quorumSize seen canonical)

    say "begin waiting some more..."
    liftIO $ do
      threadDelay (500000 * waitDuration config)
      withMVar canonical $ \ans -> do
        let result = sum (zipWith (*) (map payload $ S.toList ans) [1..])
        putStrLn (show self ++ ": <" ++ show (length ans) ++ "," ++ show result ++ ">")

    -- Send everybody our final decision
    say "voting..."
    canon <- inspect canonical
    --broadcastTo "answer" (Vote canon self)
    forM_ net $ \peer -> do
      liftIO $ putStrLn (show self ++ " sending vote to " ++ show peer)
      nsendRemote peer "answer" (Vote canon self)
    
    -- Once the votes are in, display the result.
    ans <- liftIO (takeMVar answer)
    let result = sum (zipWith (*) (map payload $ S.toList ans) [1..])
    liftIO $ putStrLn (show self ++ " [ans]: <" ++ show (length ans) ++ "," ++ show result ++ ">")
    say "*** DONE ***"
      
    

newtype Round = Round Int deriving (Eq, Show, Generic)
instance Binary Round

data RequestWrite = RequestWrite { writeId :: Round, writer :: ProcessId, delta :: Set Msg }
  deriving (Show, Generic)
instance Binary RequestWrite

newtype Ack = Ack Round deriving (Eq, Show, Generic)
instance Binary Ack

requestWrite :: (RequestWrite -> Process ())
             -> Int
             -> MVar (Set Msg)
             -> MVar (Set Msg)
             -> Process ()
requestWrite broadcast quorumSize seen canonical = forM_ [0..] $ \k -> do
  
  -- Remove any canonical values from seen; the remaining values are apparently novel
  canon <- inspect canonical
  novel <- (seen %= (`S.difference` canon))

  -- Request a network write of the novel elements
  when (not (S.null novel)) (write broadcast quorumSize (Round k) novel)

  -- Pause for 1/10 of a second
  liftIO (threadDelay 100000)
  
write :: (RequestWrite -> Process ())
      -> Int
      -> Round
      -> Set Msg
      -> Process ()
write broadcast quorumSize wid vs = do
  self <- getSelfPid

  -- Send a write request to the entire network
  broadcast (RequestWrite { writeId = wid, writer = self, delta = vs })

  -- Wait for a quorum of acks
  replicateM_ quorumSize (receiveWait [ matchIf (== Ack wid) (const $ return ()) ])
  -- At this point, a majority of the network has accepted our write,
  -- so it will appear in any read that touches a majority of the network.

applyWrite :: MVar (Set Msg) -> Process ()
applyWrite seen = forever (receiveWait [ match go ])
  where
    go req = do
      -- Update the seen set, and send an ack back to the sender.
      seen %= S.union (delta req)
      send (writer req) (Ack $ writeId req)

data Vote = Vote (Set Msg) ProcessId deriving (Show, Generic)
instance Binary Vote

data AckVote = AckVote deriving (Show, Generic)
instance Binary AckVote

tallyVotes :: MVar (Set Msg) -> Int -> Process ()
tallyVotes answer quorumSize = do
  self <- getSelfPid
  liftIO (putStrLn ("** TALLY-HO! " ++ show self))
  ans <- replicateM quorumSize $ do
    receiveWait [ match (\(Vote x pid) -> do liftIO (putStrLn (show self ++ " tallied vote from " ++ show pid))
                                             return x) ]

  liftIO $ putMVar answer (S.unions ans)
