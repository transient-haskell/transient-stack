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

-- | Inject a stream of values into the computation, spawning a thread per element.
-- Use the 'threads' primitive to control the degree of parallelism.
-- Unlike normal loops, two or more 'choose' expressions can be composed algebraically.
choose :: [a] -> TransIO a
choose =  foldr ((<|>) . async . return) empty






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


