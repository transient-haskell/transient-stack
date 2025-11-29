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
choose, for, collect, collect', group, groupByTime, burst
) where

import Transient.Internals 

import Data.IORef
import Control.Applicative
import Data.Monoid
import Data.Maybe
import Control.Concurrent
import Control.Monad.State
-- import Control.Exception hiding (onException)
-- import qualified Data.ByteString.Char8 as BS

-- import System.IO.Unsafe

-- | inject a stream of  values in the computation in as much threads as are available. You can use the
-- 'threads' primitive to control the parallelism.
--
-- unlike normal loops, two or more choose primitives or expressions that use choose can be composed algebraically
choose :: [a] -> TransIO a
choose =  foldr ((<|>) . async . return) empty

-- -- | inject a stream of SMore values in the computation in as much threads as are available. transmit the end of stream witha SLast value
-- chooseStream  ::  [a] -> TransIO (StreamData a)
-- chooseStream []= empty
-- chooseStream   xs = do
--     evs <- liftIO $ newIORef xs
--     parallel $ do
--            es <- atomicModifyIORef evs $ \es -> let tes= tail es in (tes,es)
--            case es  of
--             []  -> return SDone
--             x:_  -> x `seq` return $ SMore x


-- -- | Same as 'choose', but slower and more parallized in some cases

--





-- | Collect the results in groups of @n@ elements.
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
    maybe stop return mn


-- | Collect the first @n@ results. if n==0 it collects all the results until there are no
-- active threads within the argument. When n/=0, when the desired number of results are reached it 
-- kills all the remaining non-free threads before returning the results. 
--
collect ::  Int -> TransIO a -> TransIO [a]
collect n = collect' n 0


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

     gather v= do
       waitEvents $ do
        threadDelay timeout
        atomicModifyIORef v $ \xs -> (mempty , xs)


