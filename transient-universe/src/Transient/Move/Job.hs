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
module Transient.Move.Job where -- (job, config, runJobs) where
import Transient.Internals
import Transient.Move.Internals
import Transient.Move.Defs
import Transient.Indeterminism
import Transient.Move.Logged
import qualified Data.ByteString.Char8 as BC
import Control.Monad.IO.Class
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC

import Control.Applicative
import Control.Monad
import Data.List
import Data.Maybe
import Data.Typeable

newtype Job= Job {jobSession :: Int,jobName :: BC.ByteString,jobNode :: Node, jobError :: Exception}  deriving (Typeable,Read,Show,Eq)
data Jobs= Jobs{pending :: [Job]}  deriving (Read,Show)
instance TC.Indexable Jobs where key _= "__Jobs"

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



job :: (Maybe String) -> Cloud ()
job mname  =  local $  do
      mprev :: Maybe Job <- getData 
      when (isJust mprev) $ jobRemove $ fromJust mprev
      PrevClos dbprevclos _ isapp <- getData `onNothing` noExState "job"
      let(idSession,_) = getSessClosure dbprevclos
      endpoint (fmap BC.pack mname) -- void $ setCont Nothing idSession 
      tr "AFTER ENDPOINT"
      PrevClos thisclos _ isapp <- getData `onNothing` noExState "job 2"
      -- false to force the log Not to recreate this endpoint when replaying
      setState $ PrevClos thisclos False isapp

      -- PrevClos thisclos _ _ <- getState 
      let (s,c) = getSessClosure thisclos
          this= Job s c myNode Nothing
      liftIO $ atomically $ do
         Jobs  pending <- readDBRef rjobs `onNothing` return (Jobs [])
         tr  ("creating job",pending,this)
         writeDBRef rjobs $ Jobs $   this:pending
      setData  this

      onException $ \e@(ConnectionError node _) $ do
         -- store node in job to be rescheduled when node recovers
         liftIO $ atomically $ writeDBRef rjobs this{nodeJob=node,nodeError=e}
         empty


  
  
jobRemove :: Job -> TransIO ()
jobRemove conclos= do
      liftIO $ atomically $ do
        -- unsafeIOToSTM $ print "REMOVE"
        Jobs  pending <- readDBRef rjobs `onNothing` return (Jobs [])
        tr ("REMOVE",pending,conclos,pending \\[conclos])
        writeDBRef rjobs $ Jobs  $ pending \\ [conclos]
      delState conclos

rjobs = getDBRef "__Jobs"

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
   job (Just name) 
   mx

-- A node notify that it is ready to continue unfinished jobs
newtype Ping= Ping Node

runJobs= local $ startJobs <|> commJobs
  where
  startJobs= do
    Jobs  pending <-liftIO $ atomically $ readDBRef rjobs `onNothing` return (Jobs  [])
    tr ("runJobs",pending )
    myNode <- getMyNode
    Job (id,clos) <- choose pending
    schedule $ Job id clos myNode Nothing

  commJobs= do
    Ping node <- getMailbox
    jobs <- atomically $ readDBRef rjobs `onNothing` return (Jobs  [])
    let js= filterByNode node jobs
    j <- choose js
    schedule j

  schedule job@(Job id clos node Nothing)= do
    (log,clos') <- getClosureLog id $ BC.unpack clos
    let conn= Connection{remoteNode= lazy $ newIORef node} 
    jobRemove job
    Transient $ sendToClosure  log 0 mempty conn False clos'


-- | persistent collect. Unlike Transient.collect, Transient.Move.collect  keeps the results across intended and unintended
-- shutdowns and restarts
collectp n delta  mx=  do
  onAll $ liftIO $ writeIORef save True
  tinit <- local getMicroSeconds
  ttr("COLLECTPP",n,delta)

  let tfin= tinit +  delta
      numbered= n > 0
 
      collectp' n  delta 
       | n <= 0 && numbered = return []
       | otherwise= do
        (rs,delta') <- local $ do
            t <-  getMicroSeconds

            let delta'=  tfin -t
            ttr ("delta'",delta')
            rs <- if delta' <= 0 then return [] else collectSignal True n (fromIntegral delta) $ unCloud mx
            ttr ("RS",rs)

            -- tiene que obtener el delta historico dentro de local, para saber si tiene que recuperar mas jobs
            -- Alabado sea Dios
            return (rs,delta')
        let len= length rs
        ttr ("ITERATION",n,len)
        if delta'<= 0 || (numbered && len>= n) then return rs else return rs <>  
                    (do job Nothing ;  collectp' (n-len) delta')
  
  ttr ("COLLECTP",n,delta)
  collectp' n delta
