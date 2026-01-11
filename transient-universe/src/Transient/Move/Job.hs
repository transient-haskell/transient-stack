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
module Transient.Move.Job(job, config, runJobs,collectc,getMicroSeconds) where
import Transient.Internals
import Transient.Move.Internals
import Transient.Move.Defs
import Transient.Indeterminism
import Transient.Move.Logged
import qualified Data.ByteString.Char8 as BC
import Control.Monad.IO.Class
import Data.TCache  hiding (onNothing)
-- import Data.TCache.DefaultPersistence as TC(key)
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

-- newtype Job= Job (Int,BC.ByteString)  deriving (Typeable,Read,Show,Eq)
data Job= Job {jobClosure :: DBRef LocalClosure,jobNode :: Node, jobError :: Maybe SomeException}  deriving (Typeable,Read,Show)
instance TC.Indexable Job where key (Job dbr  _ _)= 'J':keyObjDBRef dbr
-- data Jobs= Jobs{pending :: [Job]}  deriving (Read,Show)
-- instance TC.Indexable Jobs where key _= "__Jobs"

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




job' :: (Maybe String) -> Cloud ()
job' mname  =  local $  do
  mprev :: Maybe Job <- getData 
  liftIO $ writeIORef save True
  when (isJust mprev) $ jobRemove $ fromJust mprev
  -- PrevClos dbprevclos _ _ isapp <- getData `onNothing` noExState "job"
  -- let(idSession,_) = getSessClosure dbprevclos
  endpoint (fmap BC.pack mname) <|> return () -- void $ setCont Nothing idSession 
  tr "AFTER ENDPOINT"
  p@(PrevClos thisclos ms _ isapp) <- getData `onNothing` noExState "job 2"
  -- -- false to force the log Not to recreate this endpoint after replaying
  ttr ("JOB PREVCLOS",p )
  setState $ PrevClos thisclos ms False isapp

  -- PrevClos thisclos _ _ <- getState 
  -- conn <- getData `onNothing` noExState "job conn"
  myNode <- getMyNode
  -- let (s,c) = getSessClosure thisclos
  let this= Job thisclos myNode Nothing
  liftIO $ atomically $ newDBRef this
  --    Jobs  pending <- readDBRef rjobs `onNothing` return (Jobs [])
  --    tr  ("creating job",pending,this)
  --    writeDBRef rjobs $ Jobs $   this:pending
  setData  this
  onException $ \(e :: SomeException) -> do
    ttr ("job exception", e)
     -- distinguish connection errors to reschedule jobs when nodes recover   
    case fromException e of
      Just (ConnectionError _ node) -> liftIO $ atomically $ writeDBRef (getDBRef $ keyResource this)  this{jobNode=node, jobError= Just e}
      Nothing ->                       liftIO $ atomically $ writeDBRef (getDBRef $ keyResource this)  this{jobError= Just  e}
  -- onException $ \e@(ConnectionError _ node) -> do
  --    -- store node in job to be rescheduled when the node recovers
  --    liftIO $ atomically $ newDBRef  this{jobNode=node, jobError= Just $ toException e}
      
    empty


  
  
jobRemove :: Job -> TransIO ()
jobRemove job= do
      ttr ("jobRemove", job)
      liftIO $ atomically $ delDBRef $ (getDBRef $ keyResource job :: DBRef Job)
      delState job



-- A node notify that it is ready to continue unfinished jobs
newtype Ping= Ping Node
newtype AllJobsExecutedFor= AllJobsExecutedFor Node

runJobs= do
  onAll $ onException $ \(e :: SomeException) -> do
          liftIO $ hPutStrLn stderr $ show ("job exception", e)
  -- onAll $ newRState $ Endpoints M.empty

  local $ fork $ do
    liftIO $ index jobNode
    startJobs  <|> commJobs
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
    ttr ("runJobs(commJobs): jobs found", length dbrjobs, node)
    collect 0 $ do
      j <- for $ reverse dbrjobs

      job@(Job dbr _ _) <- (liftIO $  atomically $ readDBRef j) `onNothing` error ("runJobs(commJobs): job not found " ++ show j)

      let (s,clos) = getSessClosure dbr ::  (SessionId, IdClosure)
      (logs,clos') <- getClosureLog s clos
      conn <- getData `onNothing` noExState "runJobs(commJobs): conn not found"
      setState job
      ttr ("JOB LOG",logs)
      Transient $ sendToClosure  logs s mempty conn False clos'
    -- jobRemove job  -- don't remove because it could have spawned new processes
    -- ttr ("END JOB",job)
    putMailbox' node $ AllJobsExecutedFor node



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
-- Once this functionality is finished, there would be a reconfiguration option so that this menu ould be possible:
--
--   config -> implantation; acceptance ; reimplantation if needed
--          -> configuration  port, hostname etc ...
--          -> user preferences ...
--
--   All of this before initNode and ordinary code could start with these parameters
--
--   These config parameters could be provided in the command line as well. Instead, reading them from edited configuration files is not programatic. Configuration files are an antipattern. While command line options can be assigned from environment variables along the execution of a shell program, istead configuration files demand manual edition and revision which is prone to errors and it is a major part of how hard is to install and manage programs. Moreover if the configuration is part of the program, it is ever in sync with that the program really expects, without deprecations, old documentation, confusing mismatch between program options, file configurations and versions of executables. The dialog with the program could be self explanatory without separate documentation. A separate configutation program even if it is explanatory and intuitive, it is prone of being out of sync with what a new version of the real program expects, and need to maintain two separate programs. having the configuration as a part of the whole program eliminates this possibility since the entered configuration becomes part of the stack of variables which the program will really use and it will recover from the TCache database whenever it restarts

-- A more complete explanation https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$DARXcz9ny51BVT1L7RNH7HTa35JQNtatnCaHGFR9LfM?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu

config :: Loggable a => String -> Cloud a -> Cloud a
config name mx = do
   job' $ Just  name
   mx
  


-- | persistent non recursive collect that preserves backtracking handlers
collectc :: Loggable a => Int -> Int -> Cloud a -> Cloud [a]
collectc n delta action= do
  tinit <- local $ fromIntegral <$> getMicroSeconds

  let tfin= tinit +  delta

  t <- onAll $ fromIntegral <$> getMicroSeconds
  let timeleft= let t'= tfin - t in if t' <0 then 0 else t'
  ttr("TIMELEFT",timeleft)
  -- node <- onAll getMyNode
  initState <- gets mfData
  states <- onAll $ liftIO $ newIORef M.empty
  removeBacktracking

  r <- local $ collect' n timeleft $ unCloud $ do
          r <- action

          modifyState' (\prevclos -> prevclos{preservePath=True}) $ noExState "collectc"

          job
          -- onAll $ liftIO $ threadDelay 10000
          onAll $  do
            s <- gets mfData
            s' <-liftIO $ readIORef states

            liftIO $ writeIORef states $ Transient.Internals.merge  s' s
          return r

  s <- onAll $ liftIO $ readIORef states
  modify $ \st -> st{mfData= Transient.Internals.merge initState s}
  return r
  where

  removeBacktracking :: TransMonad m => m ()
  removeBacktracking =  modify $ \st -> st{mfData= M.filterWithKey f $ mfData st}  
    where
    -- change to filterKeys, currently websockets needs Data.Map < 0.8
    f t _=   -- t == typeOf(ofType :: Backtrack Finish)  ||
            typeRepTyCon  t /=  typeRepTyCon (typeOf (ofType :: Backtrack ()))

getMicroSeconds = liftIO $ do
        (TOD seconds picos) <- getClockTime
        return (seconds * 1000000 + picos `div` 1000000)

-- -- | persistent collect. Unlike Transient.collect, Transient.Move.collect  keeps the results across intended and unintended
-- -- shutdowns and restarts
-- collectp :: Loggable a => Int -> Integer -> Cloud a -> Cloud [a]
-- collectp n delta  mx=  do
--   onAll $ liftIO $ writeIORef save True
--   tinit <- local getMicroSeconds
--   tr("COLLECTPP",n,delta)

--   let tfin= tinit +  delta
--       numbered= n > 0
 
--       collectp' n  delta 
--        | n <= 0 && numbered = return []
--        | otherwise= do
--         (rs,delta') <- local $ do
--             t <-  getMicroSeconds

--             let delta'=  tfin -t
--             ttr ("delta'",delta')
--             rs <- if delta' <= 0 then return [] else collectSignal True n (fromIntegral delta) $ unCloud mx
--             ttr ("RS",rs)

--             -- tiene que obtener el delta historico dentro de local, para saber si tiene que recuperar mas jobs
--             -- Alabado sea Dios
--             return (rs,delta')
--         let len= length rs
--         tr ("ITERATION",n,len)
--         let n'= if numbered then n - len else 0
--         if delta'<= 0 || (numbered && len>= n) then return rs else return rs <>  
--                     (job >>  collectp' n' delta')
  
--   tr ("COLLECTP",n,delta)
--   collectp' n delta
  
