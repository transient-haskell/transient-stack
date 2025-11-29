{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE InstanceSigs #-}

import Control.Monad.State.Strict
import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Class
import Control.Applicative
import Data.Functor
import Data.Monoid

newtype StateTMaybeIO s a = StateTMaybeIO { runStateTMaybeIO :: s ->  IO (Maybe a, s) }
  deriving (Functor)

instance Monad (StateTMaybeIO s) where
  return :: a -> StateTMaybeIO s a
  return x = StateTMaybeIO $ \s -> return (Just x, s)

  (>>=) :: StateTMaybeIO s a -> (a -> StateTMaybeIO s b) -> StateTMaybeIO s b
  StateTMaybeIO m >>= f = StateTMaybeIO $ \s -> do
    (ma, s') <- m s
    case ma of
      Nothing -> return (Nothing, s')
      Just a  -> runStateTMaybeIO (f a) s'

instance Applicative (StateTMaybeIO s) where
  pure :: a -> StateTMaybeIO s a
  pure = return

  (<*>) :: StateTMaybeIO s (a -> b) -> StateTMaybeIO s a -> StateTMaybeIO s b
  StateTMaybeIO mf <*> StateTMaybeIO mx = StateTMaybeIO $ \s -> do
    (mf', s') <- mf s
    case mf' of
      Nothing -> return (Nothing, s')
      Just f  -> do
        (mx', s'') <- mx s'
        return (f <$> mx', s'')

instance Alternative (StateTMaybeIO s) where
  empty :: StateTMaybeIO s a
  empty = StateTMaybeIO $ \s -> return (Nothing, s)

  (<|>) :: StateTMaybeIO s a -> StateTMaybeIO s a -> StateTMaybeIO s a
  StateTMaybeIO m1 <|> StateTMaybeIO m2 = StateTMaybeIO $ \s -> do
    (ma, s') <- m1 s
    case ma of
      Nothing -> m2 s'
      Just _  -> return (ma, s')

instance Monoid a => Semigroup (StateTMaybeIO s a) where
  (<>) :: StateTMaybeIO s a -> StateTMaybeIO s a -> StateTMaybeIO s a
  StateTMaybeIO m1 <> StateTMaybeIO m2 = StateTMaybeIO $ \s -> do
    (ma1, s1) <- m1 s
    (ma2, s2) <- m2 s1
    return (mappend <$> ma1 <*> ma2, s2)

instance Monoid a => Monoid (StateTMaybeIO s a) where
  mempty :: StateTMaybeIO s a
  mempty = StateTMaybeIO $ \s -> return (Just mempty, s)
