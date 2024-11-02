{-# LANGUAGE DeriveDataTypeable #-}
module Transient.EVars where

import Transient.Internals
import Data.Typeable

import Control.Applicative
import Control.Concurrent.STM
import Control.Monad.State

import Control.Exception as CE

data EVar a= EVar  (TChan (StreamData a)) deriving  Typeable


-- | creates an EVar.
--
-- Evars are event vars. `writeEVar` trigger the execution of all the continuations associated to the  `readEVar` of this variable
-- (the code that is after them).
--
-- It is like the publish-subscribe pattern but without inversion of control, since a readEVar can be inserted at any place in the
-- Transient flow.
--
-- EVars can be used to communicate two or more sub-threads of the monad. Following the Transient philosophy they
-- do not block his own thread if used with alternative operators, unlike the IORefs and TVars. And unlike STM vars, that are composable,
-- they wait for their respective events, while TVars execute the whole expression when any variable is modified.
--
-- The current implementation use TChans, so the data is buffered by writeEVar in a queue if for some
-- reason the readEVar is not executed at the same pace. For example, if the receiving side has a limited
-- number of threads.

-- Since TChans are used, any combination of N readers and M writers scenarios are possible.

-- the readEvar's are executed in parallel if there are threads available. It is a kind of publish/suscribe
-- pattern, but without inversion of control and with reactive behaviour.
--
-- see https://www.fpcomplete.com/user/agocorona/publish-subscribe-variables-transient-effects-v
--

newEVar ::  TransIO (EVar a)
newEVar  = Transient $ do
   ref <-liftIO  newBroadcastTChanIO
   return . Just $ EVar  ref

-- | delete al the subscriptions for an EVar.
cleanEVar :: EVar a -> TransIO ()
cleanEVar (EVar  ref1)= liftIO $ atomically $  writeTChan  ref1 SDone


-- | read the EVar. It only succeed when the EVar is being updated
-- The continuation gets registered to be executed whenever the variable is updated.
--
-- if readEVar is re-executed in any kind of loop, this will register
-- again. The effect is that the continuation will be executed multiple times
-- To avoid multiple registrations, use `cleanEVar`. Transient discourages the use of loops
readEVar :: EVar a -> TransIO a
readEVar (EVar  ref1)=  do
     tchan <-  liftIO . atomically $ dupTChan ref1
     r <-  parallel $ atomically $  readTChan tchan
     checkFinalize r

-- |  update the EVar and execute all readEVar blocks with "last in-first out" priority
--
writeEVar :: EVar a -> a -> TransIO ()
writeEVar (EVar  ref1) x= liftIO $ atomically $ do
       writeTChan  ref1 $ SMore x


-- | write the EVar and drop all the `readEVar` handlers.
--
-- It is like a combination of `writeEVar` and `cleanEVar`
lastWriteEVar (EVar ref1) x= liftIO $ atomically $ do
       writeTChan  ref1 $ SLast x


