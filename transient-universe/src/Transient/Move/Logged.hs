 {-#Language OverloadedStrings, FlexibleContexts #-}
-----------------------------------------------------------------------------
--
-- Module      :  Transient.Logged
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
-- | The 'logged' primitive is used to save the results of the subcomputations
-- of a transient computation (including all its threads) in a  buffer.  The log
-- contains purely application level state, and is therefore independent of the
-- underlying machine architecture. The saved logs can be sent across the wire
-- to another machine and the computation can then be resumed on that machine.
-- We can also save the log to gather diagnostic information.
--

-----------------------------------------------------------------------------
{-# LANGUAGE  CPP, ExistentialQuantification, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}
module Transient.Move.Logged(
Loggable(..), logged, received, param, getLog, exec,wait, emptyLog, Log(..),hashExec) where

import Data.Typeable
import Data.Maybe
import Unsafe.Coerce
import Transient.Internals
import Transient.Indeterminism(choose)
import Transient.Parse
import Transient.Loggable
import Transient.Move.Defs

import Control.Applicative
import Control.Monad.State
import System.Directory
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.Map as M
import Data.IORef
import System.IO.Unsafe
import GHC.Stack

import Data.ByteString.Builder

import Data.TCache (getDBRef)


u= unsafePerformIO
exec=  lazyByteString $ BS.pack "e/"
wait=  lazyByteString $ BS.pack "w/"





-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--

hashExec= 10000000
hashWait= 100000
hashDone= 1000




logged :: Loggable a => TransIO a -> Cloud a
logged mx =  Cloud $ do




    r <- res <** outdent

    tr ("finish logged stmt of type",typeOf res, "with value", r)
    

    return r
    where

    res = do
          log <- getLog
          -- tr "resetting PrevClos"
          -- modifyState'(\(PrevClos a b _) -> PrevClos a b False) (error "logged: no prevclos") -- (PrevClos 0 "0" False) -- 11

          debug <- getParseBuffer
          tr (if recover log then "recovering" else "excecuting" <> " logged stmt of type",typeOf res,"parseString", debug,"PARTLOG",partLog log)
          indent
          let segment= partLog log


          rest <- getParseBuffer 

          setData log{partLog=  segment <> exec, hashClosure= hashClosure log + hashExec}
          
          r <-(if not $ BS.null rest
                then recoverIt
                else do
                  tr "resetting PrevClos"
                  modifyState'(\(PrevClos a b _) -> PrevClos a b False) (error "logged: no prevclos") -- (PrevClos 0 "0" False) -- 11

                  mx)  <|> addWait segment
                              -- when   p1 <|> p2, to avoid the re-execution of p1 at the
                              -- recovery when p1 is asynchronous or  empty
          rest <- giveParseString

          let add= serialize r <> lazyByteString (BS.pack "/")
              recov= not $ BS.null rest  
              parlog= segment <> add 

          PrevClos s c hadTeleport <- getData `onNothing` (error $ "logged: no prevclos") -- return (PrevClos 0 "0" False)
          modifyState'  (\log ->  -- problemsol 10
                        if  hadTeleport 
                          then 
                            trace (show("set log","")) $ log{recover=recov, partLog= mempty,hashClosure= hashClosure log  }
                          else 
                            trace (show("set log",parlog)) $ log{recover=recov, partLog= parlog, hashClosure= hashClosure log + hashDone } 
                        ) 
                        emptyLog



          return r


    
    addWait segment= do
      -- tr ("ADDWAIT",segment)
      -- outdent

      tr ("finish logged stmt of type",typeOf res, "with empty")
      modifyData' (\log -> log{partLog=segment <> wait, hashClosure=hashClosure log + hashWait})
                      -- case recover log of
                      --           False -> log{partLog=segment <> wait, hashClosure=hashClosure log + hashWait}
                      --           True  -> log)
                  emptyLog
      empty


    

    recoverIt = do

        s <- giveParseString

        -- tr ("recoverIt recover", s)
        let (h,t)=  BS.splitAt 2 s 
        case  (BS.unpack h,t) of
          ("e/",r) -> do
            -- tr "EXEC"
            setParseString r
            mx

          ("w/",r) -> do
            tr "WAIT"
            setParseString r
            modify $ \s -> s{execMode= if execMode s /= Remote then Parallel else Remote}  
                          -- in recovery, execmode can not be parallel(NO; see below)
            empty                                

          _ -> value

    value = r
      where
      typeOfr :: TransIO a -> a
      typeOfr _= undefined

      r= (do
        -- tr "VALUE"
        -- set serial for deserialization, restore execution mode
        x <- do mod <-gets execMode;modify $ \s -> s{execMode=Serial}; r <- deserialize; modify $ \s -> s{execMode= mod};return r  -- <|> errparse 
        tr ("value parsed",x)
        psr <- giveParseString
        when (not $ BS.null psr) $ (tChar '/' >> return ()) --  <|> errparse
        return x) <|> errparse

      errparse :: TransIO a
      errparse = do psr <- getParseBuffer;
                    stack <- liftIO currentCallStack
                    errorWithStackTrace  ("error parsing <" <> BS.unpack psr <> ">  to " <> show (typeOf $ typeOfr r) <> "\n" <> show stack)





-------- parsing the log for API's

received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       (Transient.Internals.try $ tChar '/'  >> return ())<|> return () --maybe there is a '/' to drop
       --(Transient.Internals.try $ tTakeWhile (/= '/') >>= liftIO . print >> empty) <|> return ()
       if      t == typeOf (undefined :: String)     then return . unsafeCoerce . BS.unpack =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BS.ByteString) then return . unsafeCoerce =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BSS.ByteString)  then return . unsafeCoerce . BS.toStrict =<< tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


