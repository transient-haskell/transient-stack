{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use tuple-section" #-}
{-# LANGUAGE InstanceSigs #-}

{-|
Module      : Transient.EVars
Description : Event variables for the Transient framework
Copyright   : (c) Your Name Here
License     : Your License Here
Maintainer  : your.email@example.com

This module provides event variables (EVars) implementation for the Transient framework.
EVars enable publish-subscribe patterns without explicit blocking or loops, allowing
for seamless composition with other TransIO code.
-}
module Transient.EVars(EVar,newEVar, readEVar,readEVar', readEVarId,readEVar1,delReadEVar,delReadEVarPoint,writeEVar) where

import Transient.Internals
-- import Transient.Indeterminism
-- import Data.Typeable
-- import Control.Applicative
-- import Control.Concurrent.STM
-- import Control.Monad.State
-- import Control.Exception as CE
-- import Data.IORef
-- import System.IO.Unsafe
-- import Control.Concurrent
-- import Data.Maybe
-- import System.Random

-- -- | An event variable that can hold values of type 'a'.
-- -- EVars implement a publish-subscribe pattern where writers can publish values
-- -- and readers can subscribe to receive updates.
-- newtype EVar a = EVar (IORef [(Int, a -> IO())])

-- newtype EVarId = EVarId Int deriving Typeable


-- -- | Creates a new EVar.
-- --
-- -- EVars are event variables that implement a publish-subscribe pattern. Key features:
-- --
-- -- * Writers can publish values using 'writeEVar'
-- -- * Readers can subscribe using 'readEVar'
-- -- * Non-blocking operations
-- -- * Composable with other TransIO code
-- -- * Supports multiple readers and writers
-- -- * Readers execute in parallel when threads are available
-- --
-- -- Example:
-- --
-- -- @
-- -- do
-- --   ev <- newEVar
-- --   r <- readEVar ev <|> do
-- --     writeEVar ev "hello"
-- --     writeEVar ev "world"
-- --     empty
-- --   liftIO $ putStrLn r
-- -- @
-- --
-- -- see https://www.schoolofhaskell.com/user/agocorona/publish-subscribe-variables-transient-effects-v
-- --
-- newEVar :: TransIO (EVar a)
-- newEVar = do
--     ref <- liftIO $ newIORef []
--     return $ EVar ref

-- -- | Reads a stream of events from an EVar.
-- --
-- -- Important notes:
-- --
-- -- * Only succeeds when the EVar has a value written to it
-- -- * Waits for events until the stream is finished
-- -- * No explicit loops needed as this is the default behavior
-- -- * Remains active until 'cleanEVar', 'lastWriteEVar' or 'delReadEvarPoint` are called
-- -- * Multiple executions in a loop will register the continuation multiple times
-- -- * Use 'cleanEVar' to avoid multiple registrations if needed
-- readEVar :: EVar a -> TransIO a
-- readEVar = do
--        id <- genNewId
--        readEVar' id True

-- -- | creates a new subscription point for an EVar. This subscription could be removed with delReadEVarPoint 
-- readEVarId id= readEVar' id True

-- -- | creates a transient EVar subscription for one single read
-- readEVar1= do
--        id <- genNewId
--        readEVar' id False

-- -- | creates a subscription to an EVar with an identifier. The second parameter defines either if the subcription os once or permanent
-- readEVar' :: Bool -> Int -> EVar a -> TransIO a
-- readEVar' keep id (EVar ref)= do
--        tr ("readEVar",id)
--        setState $ EVarId id
--        reactId keep (nameId id) EVarCallback "" (onEVarUpdated id) (return ())
--        where
--        onEVarUpdated id callback= do
--               atomicModifyIORef' ref $ \rs -> ((id,callback):rs,())


-- nameId id= show id <> " EVar"

-- -- | Removes the most recent read handler for an EVar.
-- -- Must be invoked after executing readEVar.
-- delReadEVar :: EVar a -> TransIO ()
-- delReadEVar evar@(EVar ref) =  do
--        EVarId id <- getState <|> error "delReadEVar should be after a readEVar in the flow"
--        delReadEVarPoint ev id
--        -- liftIO $ do
--        --        rs <- readIORef ref
--        --        tr ("evar callbacks", Prelude.map fst rs)
--        --        liftIO $ atomicModifyIORef ref $ \cs -> (Prelude.filter (\c -> fst c /= id) cs,())
--        --        delListener $ nameId id

-- -- | unsuscribe the read handler with the given identifier
-- delReadEVarPoint (EVar ref) id =liftIO $ do
--        rs <- readIORef ref
--        tr ("evar callbacks", Prelude.map fst rs)
--        liftIO $ atomicModifyIORef ref $ \cs -> (Prelude.filter (\c -> fst c /= id) cs,())
--        delListener $ nameId id

-- -- | Writes a value to an EVar.
-- --
-- -- * All registered readers will receive the new value
-- -- * Readers are notified in "last in-first out" order
-- -- * Non-blocking operation
-- writeEVar :: EVar a -> a -> TransIO ()
-- writeEVar (EVar ref) x = do
--        conts <- liftIO $ readIORef ref
--        -- freThreads to detach the forked thread from the calling context tree. 
--        -- it will be atached to the called context. Glory to God
--        freeThreads $ fork $ liftIO $  mapM_ (\(_,f) -> f x)   conts




-- -- | Writes a final value to an EVar and removes all readers.
-- --
-- -- This is equivalent to calling 'writeEVar' followed by 'cleanEVar'.
-- lastWriteEVar :: EVar a -> a -> TransIO ()
-- lastWriteEVar ev x= writeEVar ev x >> cleanEVar ev

-- -- | Removes all reader subscriptions from an EVar.
-- --
-- -- Use this to clean up resources and prevent memory leaks
-- -- when you no longer need to use an EVar.
-- cleanEVar :: EVar a -> TransIO ()
-- cleanEVar (EVar ref)= do
--        ids <- liftIO $ atomicModifyIORef ref $ \evs -> ([], Prelude.map (nameId . fst) evs)
--        tr ("cleanEVar", ids)

--        liftIO $ mapM_ delListener ids




-- -- | a continuation var (CVar) wraps a continuation that expect a parameter of type a
-- -- this continuation is at the site where the CVar is read.
-- -- there is only one readCVar active for each CVar created with newCVar
-- -- once a readEVar is called, all previous readCVar are removed and freed.
-- -- 
-- newtype CVar a = CVar (IORef (Maybe TranShip))

-- newCVar :: (MonadIO m,TransMonad m) => m (CVar a)
-- newCVar = do
--        r <- liftIO $ newIORef Nothing
--        return $ CVar r

-- | writes a value to a CVar (invoques te continuation with this parameter)
-- first it set the state environment that the TranShip state of the CVar carries.
-- Then executes the conitinuation with this environment which has its own
-- exception handlers, state variables, backtracks, finalizations etc
-- finally, recovers the initial state and continues the execution with the
-- original environment.
-- writeCVar :: CVar a -> a -> TransIO ()
-- writeCVar (CVar r) x=  Transient $ do
--        mcont <- liftIO $ readIORef r 
--        when (isNothing mcont) $ error "writeCVar: no readCVar set"
--        let cont= fromJust mcont
--        branch cont x
--        return Nothing


-- readCVar :: CVar a -> TransIO a
-- readCVar (CVar r)=  Transient $ do
--        c <- get
--        liftIO $ writeIORef r $ Just c
--        return Nothing
