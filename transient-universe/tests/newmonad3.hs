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
import Data.Dynamic

data StreamData a =
      SMore a               -- ^ More  to come           Just sin finalización
    | SLast a               -- ^ This is the last one    Just con finalizacion
    | SDone                 -- ^ No more, we are done    Nothing
    | SBacktrack Dynamic    -- ^ error/backtrack         BackTracking
    deriving (Typeable, Show)

instance Functor StreamData where
    fmap f (SMore a)= SMore (f a)
    fmap f (SLast a)= SLast (f a)
    fmap _ SDone= SDone
    fmap _ (SBacktrack e)= SBacktrack e

instance Monad StreamData where
    return = SLast
    SMore a >>= f= f a
    SLast a >>= f= f a
    SDone >>= _= SDone
    SBacktrack e >>= _= SBacktrack e

instance Applicative StreamData where
    pure = SLast
    SMore f <*> SMore a= SMore (f a)
    SMore f <*> SLast a= SLast (f a)
    SLast f <*> SMore a= SLast (f a)
    SLast f <*> SLast a= SLast (f a)
    SDone <*> _= SDone
    _ <*> SDone= SDone
    SBacktrack e <*> _= SBacktrack e
    _ <*> SBacktrack e= SBacktrack e

instance Semigroup a => Semigroup (StreamData a) where
  SMore a <> SMore b = SMore (a <> b)
  SMore a <> SLast b = SMore (a <> b)
  SLast a <> SMore b = SMore (a <> b)
  SLast a <> SLast b = SLast (a <> b)
  SDone   <> _  = SDone
  _ <> SDone  = SDone
  SBacktrack e <> _ = SBacktrack e
  _ <> SBacktrack e = SBacktrack e

newtype EventF= EventF Int

newtype TransIO  a = TransIO { runTrans :: EventF ->  IO (StreamData a, EventF) }
  deriving (Functor)

instance Applicative TransIO where
  pure x = TransIO $ \s -> return (SLast x, s)
  TransIO f <*> TransIO x = TransIO $ \s -> do
    (f', s') <- f s
    case f' of
      SMore g -> do
        (x', s'') <- x s'
        case x' of
          SMore a -> return (SMore (g a), s'')
          SLast a -> return (SLast (g a), s'')
          SDone -> return (SDone, s'')
          SBacktrack e -> return (SBacktrack e, s'')
      SLast g -> do
        (x', s'') <- x s'
        case x' of
          SMore a -> return (SMore (g a), s'')
          SLast a -> return (SLast (g a), s'')
          SDone -> return (SDone, s'')
          SBacktrack e -> return (SBacktrack e, s'')
      SDone -> return (SDone, s')
      SBacktrack e -> return (SBacktrack e, s')

instance Monad TransIO where
  return = pure
  TransIO x >>= f = TransIO $ \s -> do
    (x', s') <- x s
    case x' of
      SMore a -> runTrans (f a) s'
      SLast a -> runTrans (f a) s'
      SDone -> return (SDone, s')
      SBacktrack e -> return (SBacktrack e, s')

instance MonadState EventF TransIO where
  get = TransIO $ \s -> return (SLast s, s)
  put s = TransIO $ \_ -> return (SLast (), s)

instance MonadIO TransIO where
  liftIO io = TransIO $ \s -> do
    a <- io
    return (SLast a, s)

instance Alternative TransIO where
  empty = TransIO $ \_ -> return (SDone, undefined)
  TransIO x <|> TransIO y = TransIO $ \s -> do
    (x', s') <- x s
    case x' of
      SDone -> y s
      _ -> return (x', s')

instance Semigroup a => Semigroup (TransIO a) where
  TransIO x <> TransIO y = TransIO $ \s -> do
    (x', s') <- x s
    (y', s'') <- y s'
    return (x' <> y', s'')

instance Monoid a => Monoid (TransIO a) where
  mempty = pure mempty
  mappend = (<>)
