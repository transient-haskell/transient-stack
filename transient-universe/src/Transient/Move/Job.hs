-----------------------------------------------------------------------------
--
-- Module      :  Transient.Move.Job
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
-- 
--
-- Author: Alabado sea Dios que inspira todo lo bueno que hago. Porque Él es el que obra en mi
--
{-# LANGUAGE ScopedTypeVariables #-}
module Transient.Move.Job(job, config, runJobs,collectc,getMicroSeconds, Ping(..)) where
import Transient.Internals
import Transient.Move.Internals
import Transient.Move.Defs
import Transient.Console
import Transient.Move.Logged
import qualified Data.ByteString.Char8 as BC
import Control.Monad.IO.Class
import Data.TCache  hiding (onNothing)
import Data.TCache.IndexQuery
import qualified Data.TCache.DefaultPersistence as TC

import Control.Applicative
import Control.Monad.State
import Control.Exception.Base hiding (onException)
import Control.Monad
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Typeable
import Data.IORef
import System.Time
import System.IO
import Unsafe.Coerce 

import Control.Concurrent(threadDelay)

-- | A persistent job record: tracks the closure to resume, the node it runs on,
-- and any error string from the last failed attempt.
data Job= Job {jobClosure :: DBRef LocalClosure,jobNode :: Node, jobError :: Maybe String}  deriving (Typeable,Read,Show)
instance TC.Indexable Job where key (Job dbr  _ _)= 'J':keyObjDBRef dbr

-- | -- a job is intended to create tasks that will finish even if the program is interrupted
--
-- If the state of the program is commited (saved) the created thread is restored
-- when the program is restarted if it executes `runJobs`.
--
-- if the thread and all his children becomes inactive the job is removed and it is no longer activated when the program restarts. Until then, the job can send new processes down to the next statements of the monad
-- https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=6317a1c49d3c186299eb6db3

-- The above one does not work. use this:
-- https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$RuHHrgBX410PbJV5TBVEStNGoZgLhBl1SKh6ogxQurk?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu

-- Or search for "On-flow jobs for better composability and clean program design & ease verification"
--
-- Author: Bendito sea Dios que me inspira todo lo bueno que hago. Porque Él es el que obra en mi
--
-- a job can be inserted at any place in the computation, be multithreaded, emit console options, 
-- perform distributed computing etc.
--
-- A job starts from the beginning when it is restarted. To store intermediate results and advance the computation
-- step by step for processes that last for long time, the process could be divided into smaller jobs that are 
-- being completed sucessively
--
-- > main= keep $ initNode $  do
-- >  runJobs
-- >  local $ option "go" "go"
-- >  job $  localIO $ print "hello"  -- of course this is a silly example. a job is useful for potentially very long tasks
-- >  job $ local $ option1 "c" "continue to world" <|>( option1 "s" "stop" >> empty)
-- >  job $  localIO $ print "world"
--
job= job' Nothing




job' :: Maybe String -> Cloud ()
job' mname  =  local $  do
  -- the next job checkpoint eliminates the previous to reflect the advancement of the computation
  mprev :: Maybe Job <- getData
  when (isJust mprev) $ jobRemove $ fromJust mprev

  ttr "save"
  liftIO $ writeIORef save True

  endpoint (fmap BC.pack mname) <|> return () -- void $ setCont Nothing idSession 
  tr "AFTER ENDPOINT"
  p@(PrevClos thisclos ms _ isapp isCollect) :: PrevClos <- getData `onNothing` error "no job state 2"
  -- -- false to force the log Not to recreate this endpoint after replaying
  ttr ("JOB PREVCLOS",p )
  setState (PrevClos thisclos ms False isapp isCollect :: PrevClos)


  myNode <- getMyNode
  let this= Job thisclos myNode Nothing
  liftIO $ atomically $ newDBRef this

  setData  this
  onException $ \(e :: SomeException) -> do
    ttr ("job exception", e,"adding this to the list of tasks to retry")
     -- distinguish connection errors to reschedule jobs when nodes recover   
    case fromException e of
      Just (ConnectionError _ node) -> liftIO $ atomically $ writeDBRef (getDBRef $ keyResource this)  this{jobNode=node, jobError= Just $ show e}
      Nothing ->                       liftIO $ atomically $ writeDBRef (getDBRef $ keyResource this)  this{jobError= Just $ show e}


-- | Remove a job from TCache and clear it from the current state.
jobRemove :: Job -> TransIO ()
jobRemove job= do
      ttr ("jobRemove", job)
      liftIO $ atomically $ delDBRef  (getDBRef $ keyResource job :: DBRef Job)
      delState job



newtype AllJobsExecutedFor= AllJobsExecutedFor Node


-- | Resume all pending 'job's on startup: replays each saved closure so the
-- computation continues from where it was interrupted.  Also listens for 'Ping'
-- messages from other nodes to resume jobs that were running there.
runJobs= do
  local $ fork $ do
    liftIO $ index jobNode
    startJobs <|> commJobs
  where
  startJobs= do
    mynode <- getMyNode
    launchJobsForNode mynode


  commJobs= do
    Ping node <- getMailbox
    launchJobsForNode node

  launchJobsForNode :: Node -> TransIO ()
  launchJobsForNode node= do
    dbrjobs <- liftIO $ atomically $  jobNode .==. node :: TransIO [DBRef Job]
    ttr ("runJobs(commJobs): jobs found",  dbrjobs, node)
    do -- collect 0 $ do
      j <- for $ reverse dbrjobs
      job@(Job dbr _ _) <- (liftIO $  atomically $ readDBRef j) `onNothing` error ("runJobs(commJobs): job not found " ++ show j)

      let (s,clos) = getSessClosure dbr ::  (SessionId, ClosureId)

      (logs,clos') <- getClosureLog s clos
      -- conn :: Connection <- getData `onNothing` error "runJobs(commJobs): conn not found"
      map <- gets mfData
      setState job
      ttr ("JOB LOG",logs,"send to closure",localClos clos',isJust $ localEvar clos',isJust $ localCont clos',TC.key clos',dbr)

      noTrans $ sendToClosure logs s closureId0 map False clos'



-- | A config job is executed once and then his data is used for the rest of the
-- computation without being executed when the program is restarted again.
-- it is useful for having a phase of configuration of the program before what
-- would be the ordinary start of the program.
--
-- Once the config jobs are completed, the program will no longer ask
-- for the configuration and ever will answer the original data
--
-- >  runJobs
-- >  n <- config "basic configuration" $ local $ do
-- >        input (const True) "name? "
-- >  s <- config "advanced configuration" $ local $ do
-- >        input (const True)"surname? " 

-- >  localIO $ putStr "hello "; putStr s; putStr " "; putStrLn s
--
-- Once this functionality is finished, there would be a reconfiguration option so that this menu could be possible:
--
--   config -> implantation; acceptance ; reimplantation if needed
--          -> configuration  port, hostname etc ...
--          -> user preferences ...
--
--   All of this before initNode and ordinary code could start with these parameters
--
--   These config parameters could be provided in the command line as well. Instead, reading them from edited configuration files is not programatic. 
--   Configuration files are an antipattern. While command line options can be assigned from environment variables along the execution of a shell program, 
--   instead configuration files demand manual edition and revision which is prone to errors and it is a major part of how hard is to install and manage programs. Moreover if the configuration is part of the program, it is ever in sync with that the program really expects, without deprecations, old documentation, confusing mismatch between program options, file configurations and versions of executables. The dialog with the program could be self explanatory without separate documentation. A separate configutation program even if it is explanatory and intuitive, it is prone of being out of sync with what a new version of the real program expects, and need to maintain two separate programs. having the configuration as a part of the whole program eliminates this possibility since the entered configuration becomes part of the stack of variables which the program will really use and it will recover from the TCache database whenever it restarts

-- A more complete explanation https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$DARXcz9ny51BVT1L7RNH7HTa35JQNtatnCaHGFR9LfM?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu

config :: Loggable a => String -> Cloud a -> Cloud a
config name mx = do
  localIO $ putStr $ "Configuring: " <> name
  r <- mx
  job' $ Just  name
  resp <- local $ input' 'Y' (\r -> r== 'Y' || r== 'y' || r == 'n' || r == 'N')   "ok with this configuration? (Y/n) "
  if resp== 'Y' || resp== 'y' then return r else config name mx


newtype CollectJobs= CollectJobs [Job]
-- | persistent non recursive collect that preserves backtracking handlers. Unlike Transient.collect, it keeps the results across 
-- intended and unintended shutdowns and restarts.
collectc :: Loggable a => Int -> Int -> Cloud a -> Cloud [a]
collectc n delta action= Cloud $ sandboxDataCond preserveCollectFlag $ unCloud $ do
  modifyData' (\p -> p{isCollect=True}) $ error "collectc: no Previous closure"

  tinit <- local $ fromIntegral <$> getMicroSeconds

  let tfin= tinit +  delta

  t <- onAll $ fromIntegral <$> getMicroSeconds
  let timeleft= let t'= tfin - t in max t' 0
  ttr ("TIMELEFT",timeleft)
  initState <- gets mfData
  states <- onAll $ liftIO $ newIORef M.empty
  onAll $ newRState $ CollectJobs []
  r <- local $ collect' n timeleft $ unCloud $ do
          r <- action

          modifyState' (\prevclos -> prevclos{preservePath=True}) $ error "no CollectJobs state"

          job

          onAll $ do

            j ::  Job <- getState <|> error "collectc: no Job stete"

            
            -- add to the list of collect jobs to delete at the end of collect
            Ref ref  <- getState <|> error "collectc: no state Ref CollectJobs"
            Just (CollectJobs jobs) <- liftIO $ readIORef ref
            liftIO $ writeIORef ref $ Just $ CollectJobs $ j:jobs

          -- merge all states for the result
          onAll $  do
            s <- gets mfData
            s' <-liftIO $ readIORef states
            liftIO $ writeIORef states $ merge  s' s
          return r

  s <- onAll $ liftIO $ readIORef states
  modify $ \st -> st{mfData= merge initState s}
  
  -- remove all the jobs inside  collectc
  CollectJobs js <- onAll $ getRState <|> return (CollectJobs []) 
  ttr ("JOBS TO DELETE",js)
  onAll $ mapM_ jobRemove js

  return r
  where
  merge :: PolyMap -> PolyMap -> PolyMap
  merge = M.unionWithKey combine


  isOfTypeBacktrack t= typeRepTyCon t == typeRepTyCon (typeOf (ofType :: Backtrack ()))

  isOfTypeLog t= typeRepTyCon t == typeRepTyCon (typeOf(ofType :: Log))

  combine :: TypeRep -> SData -> SData -> SData
  combine t x y =   -- tracec ("Merging type: " ++ show t) $ 
    
    if isOfTypeBacktrack t then    
          let list  = case unsafeCoerce x :: Backtrack1 () of
                          Backtrack1 _ list  -> list
              list' = case unsafeCoerce y :: Backtrack1 () of
                          Backtrack1 _ list' -> list'
          in   unsafeCoerce $ Backtrack1 Nothing ( list' ++ list)

    else if isOfTypeLog t then
          let log= unsafeCoerce x  :: Log
              log'= unsafeCoerce y :: Log
          in   unsafeCoerce $ log'{restLog = restLog log ++ restLog log'} 

    else y -- Default behavior: take the second value

  -- preserve the previous isCollect if we are in a anidated collectc
  preserveCollectFlag (Just mnow) (Just mprev) = Just mnow{isCollect=isCollect mprev}

  preserveCollectFlag _ _ = error "PrevClos information"

data Backtrack1 a = Backtrack1 (Maybe a) [SData]

-- | Return the current time in microseconds.
getMicroSeconds = liftIO $ do
        (TOD seconds picos) <- getClockTime
        return (seconds * 1000000 + picos `div` 1000000)

-- | Like 'endpoint' but removes the current 'Job' first, since on-demand
-- endpoints do not need to persist across restarts.
endpointc mname= do
  mprev :: Maybe Job <- getData
  when (isJust mprev) $
    let prev= fromJust mprev
    in do jobRemove prev ; delData prev
  endpoint mname




