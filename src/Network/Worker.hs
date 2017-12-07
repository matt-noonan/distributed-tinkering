{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}

module Network.Worker
  ( iohk
  , work
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

-- | Execute the message-sending and agreement phases, and display the result.
iohk :: Config -> Process ()
iohk config = do
  (count, value) <- work config
  liftIO $ putStrLn ("<" ++ show count ++ "," ++ show value ++ ">")

-- | Run the message-sending and agreement phases, returning the number of
--   agreed-upon messages $N$, and the sum $\sum_{k = 1}^N k \cdot m_k$,
--   where $m_k$ is the payload attached to the $k$th agreed-upon message.
work :: Config -> Process (Int, Double)
work config = do
  
    self <- getSelfPid

    -- Announce our existence to the network
    announce config

    -- Gather the process ids for this network
    net <- network config
    let broadcastTo :: forall a. Serializable a => [NodeId] -> String -> a -> Process ()
        broadcastTo = broadcast config
        quorumSize = quorum config

    -- Spawn a worker to accumulate incoming random numbers to the "seen" set.
    seen <- liftIO (newMVar S.empty)
    register "iohk-test" =<< spawnLocal (accumulate seen)

    -- Spawn a worker that will maintain the "canonical" set of messages,
    -- and update it upon request.
    canonical <- liftIO (newMVar S.empty)
    writerPid <- spawnLocal (applyWrite canonical)
    register "writer" writerPid

    -- Spawn a worker that accumulates votes for the agreed-upon answer.
    answer <- liftIO newEmptyMVar
    register "answer" =<< spawnLocal (tallyVotes answer quorumSize)
    
    -- Spawn a worker that will periodically check the 'seen' set and,
    -- if there are elements of seen that are not yet canonical,
    -- request a distributed write of the new elements.
    _ <- spawnLocal (requestWrite (broadcastTo net "writer") quorumSize seen canonical)


    -- Send everybody in the network random values for sendDuration seconds.
    yak <- spawnLocal (yakker config (broadcastTo net "iohk-test"))
    liftIO $ threadDelay (1000000 * sendDuration config)
    kill yak "hush"

    -- Refresh the network list; this gives workers that started early a
    -- chance to see new nodes that may have come online.
    net <- network config

    -- Pause for 50% of the wait period to let in-flight messages come through.
    -- Why 50%? It's just a no-information guess about how much time to allocate
    -- to canonical set propagation vs voting.
    liftIO $ threadDelay (500000 * waitDuration config)

    -- Send everybody our vote for the final result
    kill writerPid "time to vote"
    canon <- liftIO (takeMVar canonical)
    broadcastTo net "answer" (Vote canon)
    
    -- Once the votes are in, return the result.
    ans <- liftIO (takeMVar answer)
    return (S.size ans, sum (zipWith (*) (map payload $ S.toList ans) [1..]))
    

-- | A message containing a random number.
data Msg = Msg { payload :: Double
               , sender  :: ProcessId
               , timestamp :: UTCTime } deriving (Eq, Show, Generic)

instance Ord Msg where
  compare x y = compare (timestamp x, sender x, payload x) (timestamp y, sender y, payload y)
  
instance Binary Msg

-- | Receive random numbers and add them to the "seen" set.
--   This is the "iohk-test" named process.
accumulate :: MVar (Set Msg) -> Process ()
accumulate seen = forever (receiveWait [ match (\msg -> seen %= S.insert msg) ])

-- | Continuously send random numbers to the network.
yakker :: Config -> (Msg -> Process ()) -> Process ()
yakker config netsend = do
  self <- getSelfPid
  
  forever $ do
    now <- liftIO getCurrentTime
    x   <- liftIO (rng config)
    netsend (Msg { payload   = x,
                   sender    = self,
                   timestamp = now })

-- | A unique ID to use for writes. This is used to ensure that each
--   write is acknowledged by a quorum before committing it.
newtype Round = Round Int deriving (Eq, Show, Generic)
instance Binary Round

-- | A request to add the given delta to a node's canonical set.
data RequestWrite = RequestWrite { writeId :: Round, writer :: ProcessId, delta :: Set Msg }
  deriving (Show, Generic)
instance Binary RequestWrite

-- | Acknowledgement of a request to write.
data Ack = Ack Round ProcessId deriving (Eq, Show, Generic)
instance Binary Ack

-- | This worker task periodically checks if this node has seen
--   any messages that are not yet canonical; if so, it broadcasts
--   a request to make the new messages canonical.
requestWrite :: (RequestWrite -> Process ())
             -> Int
             -> MVar (Set Msg)
             -> MVar (Set Msg)
             -> Process ()
requestWrite netsend quorumSize seen canonical = forM_ [0..] $ \k -> do
  
  -- Remove any canonical values from seen; the remaining values are apparently novel
  canon <- inspect canonical
  novel <- (seen %= (`S.difference` canon))

  -- Request a network write of the novel elements
  -- Retry write if a timer goes off?
  when (not (S.null novel)) $ do
    _ <- spawnLocal $ write netsend quorumSize (Round k) novel
    return ()

  -- Pause for 1/10 of a second
  liftIO (threadDelay 100000)

-- | Ask a majority of the network to accept this write.
write :: (RequestWrite -> Process ())
      -> Int
      -> Round
      -> Set Msg
      -> Process ()
write netsend quorumSize wid vs = do
  self <- getSelfPid

  -- Send a write request to the entire network
  netsend (RequestWrite { writeId = wid, writer = self, delta = vs })

  -- Wait for a quorum of acks
  quorum <- replicateM quorumSize (receiveWait [
                                      matchIf (\(Ack k _) -> k == wid)
                                              (\(Ack _ pid) -> return pid) ])
  
  -- At this point, a majority of the network is ready to accept this write.
  -- Tell the quorum to go ahead and commit.
  -- BUG: we need to ensure that the quorum actually did commit here. If only
  --      some members of the quorum actually committed, then we lose the
  --      guarantee that the write will be visible on any majority.
  forM_ quorum $ \peer -> send peer Commit

-- | Tell a member of the quorum to accept the write we proposed.
data Commit = Commit deriving (Show, Generic)
instance Binary Commit

-- | Accept a write request, provisionally at first, committing the write
--   when a @Commit@ message is received.
applyWrite :: MVar (Set Msg) -> Process ()
applyWrite canonical = forever (receiveWait [ match go ])
  where
    go req = do
      -- Send an ack back to the sender.
      -- The ack includes a process handle that can be triggered to commit
      -- the write.
      commit <- spawnLocal (receiveWait [match (\Commit -> do canonical %= S.union (delta req)
                                                              return () ) ])
      send (writer req) (Ack (writeId req) commit)
      
-- | Vote for a given set.     
newtype Vote = Vote (Set Msg) deriving (Show, Generic)
instance Binary Vote

-- | Gather votes for the canonical set, and return the union of all votes.
--   Senders should only be voting for a set if they have accepted it as
--   their canonical set, and every element in a canonical set should belong
--   to the canonical set of some majority of nodes. Hence, if we get back
--   a quorum of votes, then union over the votes is the same as the union
--   over the canonical sets of all nodes.
--
--   (but see BUG in the @write@ function)
tallyVotes :: MVar (Set Msg) -> Int -> Process ()
tallyVotes answer quorumSize = do
  self <- getSelfPid
  ans <- replicateM quorumSize $ receiveWait [ match (\(Vote x) -> return x) ]
  liftIO $ putMVar answer (S.unions ans)

-- | Modify an MVar using the given function, and return the new value.
(%=) :: MonadIO m => MVar a -> (a -> a) -> m a
mvar %= f = liftIO (modifyMVar mvar (\x -> let x' = f x in return (x',x')))

-- | Read the value in an MVar.
inspect :: MonadIO m => MVar a -> m a
inspect mvar = liftIO (readMVar mvar)

