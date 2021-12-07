 -----------------------------------------------------------------------------
--
-- Module      :  Transient.Indeterminism
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | see <https://www.fpcomplete.com/user/agocorona/beautiful-parallel-non-determinism-transient-effects-iii>
--
-----------------------------------------------------------------------------
{-# LANGUAGE  ScopedTypeVariables, CPP #-}
module Transient.Indeterminism (
choose,  choose', for, chooseStream, collect, collect', group, groupByTime, burst
) where

import Transient.Internals hiding (retry)

import Data.IORef
import Control.Applicative
import Data.Monoid
import Control.Concurrent  
import Control.Monad.State
import Control.Exception hiding (onException)
import qualified Data.ByteString.Char8 as BS

import System.IO.Unsafe

-- | inject a stream of  values in the computation in as much threads as are available. You can use the
-- 'threads' primitive to control the parallelism.
--
choose  ::  [a] -> TransIO  a
choose []= empty
choose   xs = chooseStream xs >>= checkFinalize  

-- | inject a stream of SMore values in the computation in as much threads as are available. transmit the end of stream witha SLast value
chooseStream  ::  [a] -> TransIO (StreamData a)
chooseStream []= empty
chooseStream   xs = do
    evs <- liftIO $ newIORef xs
    parallel $ do
           es <- atomicModifyIORef evs $ \es -> let tes= tail es in (tes,es)
           case es  of
            [x]  -> x `seq` return $ SLast x
            x:_  -> x `seq` return $ SMore x


-- | Same as 'choose', but slower in some cases. However it uses 

--
choose' :: [a] -> TransIO a
choose' xs = foldr (<|>) empty $ map (async . return) xs

-- | for loop, single threaaded with de-inversion of control
--
-- >> do
-- >>   i <- for [1..10]
-- >>   liftIO $ print i
--
-- Composes with any other transient primitive
--
-- >> main= keep  $  do
-- >>  x <- for[1..10::Int] <|> (option ("n" :: String) "enter another number < 10" >> input (< 10 ) "number? >")
-- >>  liftIO $ print (x * 2)
--
for :: [a] -> TransIO a
for = threads 0 . choose

-- | Collect the results of a task set in groups of @n@ elements.
--
group :: Int -> TransIO a -> TransIO [a]
group num proc =  do
    v <- liftIO $ newIORef (0,[])
    x <- proc

    mn <- liftIO $ atomicModifyIORef v $ \(n,xs) ->
            let n'=n +1
            in  if n'== num

              then ((0,[]), Just $ x:xs)
              else ((n', x:xs),Nothing)
    case mn of
      Nothing -> stop
      Just xs -> return xs


-- | Collect the results of the first @n@ tasks.  Synchronizes concurrent tasks
-- to collect the results safely and kills all the non-free threads before
-- returning the results.  Results are returned in the thread where 'collect'
-- is called.
--
collect ::  Int -> TransIO a -> TransIO [a]
collect n = collect' n 0

-- | Like 'collect' but with a timeout. When the timeout is zero it behaves
-- exactly like 'collect'. If the timeout (second parameter) is non-zero,
-- collection stops after the timeout and the results collected till now are
-- returned.
--
-- collect' :: Int -> Int -> TransIO a -> TransIO [a]
-- collect' n t search= do


--   rv <- liftIO $ newMVar $ Just[]     -- !> "NEWMVAR"

--   results <- liftIO $ newIORef (0,[])

--   let worker =  do
--         abduce
--         r <- search
--         liftIO $ withMVar rv $ \mns ->
--            case mns of 
--               Nothing -> return Nothing
--               Just ns -> return $ Just (r:ns) -- `catch` \BlockedIndefinitelyOnMVar ->  myThreadId >>= killThread >> return()
--         empty



--       timer= do
--              when (t > 0) $ do
--                 --addThreads 1
--                 async $ threadDelay t >> putMVar rv Nothing 
--              empty
      
--       monitor=  liftIO loop 

--           where
--           loop = do
--                 mr <- takeMVar rv
--                 (n',rs) <- readIORef results
--                 case mr of
--                   Nothing -> return rs
--                   Just rs' -> do
--                     --  liftIO $ print $ length rs'
--                      let n''= n' + length rs'
--                      let rs''= rs'++rs
--                      writeIORef results  (n'',rs'')

--                      if (n > 0 && n'' >= n)
--                        then  return (rs'')
--                        else putMVar rv (Just rs'') >> loop
--               `catch` \(_ :: BlockedIndefinitelyOnMVar) -> do
--                                    readIORef results >>= return . snd

--   -- localExceptions $ do
--   --   onException $ \(e :: SomeException) -> empty

--   oneThread $  (timer <|> worker <|> monitor)



-- | insert `SDone` response every time there is a timeout since the last response

burst :: Int -> TransIO a -> TransIO (StreamData a)
burst timeout comp= do
     r <- oneThread comp 
     return (SMore r) <|> (async (threadDelay timeout) >> return SDone)

-- | Collect the results of a task set, grouping all results received within
-- every time interval specified by the first parameter as `diffUTCTime`. 
groupByTime :: Monoid a => Int -> TransIO a -> TransIO a
groupByTime timeout comp= do
     v <- liftIO $ newIORef mempty 
     gather v <|> run v 
     where
     run v =  do 
        x <-  comp
        liftIO $ atomicModifyIORef v $ \xs -> (xs <> x,())
        empty
        
     gather v= waitEvents $ do
             threadDelay timeout 
             atomicModifyIORef v $ \xs -> (mempty , xs) 


 