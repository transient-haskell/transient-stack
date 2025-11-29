{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}



module Main where
import Control.Monad.State
import Control.Monad.Trans.Identity
import Data.Map as M
import Control.Applicative
import Control.Concurrent
import Data.IORef
import Data.Typeable
import Data.ByteString as BS
import Data.ByteString.Lazy as BSL
import Data.Dynamic
import qualified Control.Applicative as Control

type SData = ()

type EventId = Int


data LifeCycle = Alive   -- working
                | Parent -- with some childs
                | Listener -- usually a callback inside react
                | Dead     -- killed waiting to be eliminated
                | DeadParent  -- Dead with some+  deriving (Eq, Show)

data ExecMode = Remote | Parallel | Serial



-- | To define primitives for all the transient monads:  TransIO, Cloud and Widget
-- class MonadState EventF m => TransMonad m

-- instance  MonadState EventF m => TransMonad m



-- introducir streamdata en la definición de TransIO monad:

newtype ContMonad a= ContMonad {runCont :: TransIO a}

newtype Triple m1 m2 m3 a = Triple{runTriple:: IdentityT m1 (IdentityT m2 (IdentityT m3 a))}

instance (Monad m1, Monad m2,Monad m3) => Monad (Triple m1 m2 m3) where
  return = pure
  Triple x >>= f= Triple $ x >>= \x' -> return $ runTriple $ f x'

instance (Applicative m1, Applicative m2,Applicative m3) => Applicative (Triple m1 m2 m3) where 
  pure x= Triple $ pure $ pure $ pure x
  Triple f <*> Triple x= Triple $ f <*> x 
  


-- runTriple :: (Monad m1, Monad m2) => IdentityT m1 (IdentityT m2 (IdentityT f a)) -> m1 (m2 (f a))
-- runTriple t = runIdentityT t >>= \x ->
--               return $ runIdentityT x >>= \y ->
--               return $ runIdentityT y

{-# SPECIALISE runTriple ::  Triple (State EventF) IO StreamData a -> State EventF (IO (StreamData a)) #-}

-- | EventF describes the context of a TransientIO computation:
data EventF = EventF
  {

    fcomp       :: Int -- a -> TransIO b
    -- ^ List of continuations

  , mfData      :: M.Map TypeRep SData
    -- ^ State data accessed with get or put operations

  , mfSequence  :: Int
  , threadId    :: ThreadId
  , freeTh      :: Bool
    -- ^ When 'True', threads are not killed using kill primitives

  , parent      :: IORef(Maybe EventF)
    -- ^ The parent of this thread

  , children    :: MVar [EventF]
    -- ^ Forked child threads, used only when 'freeTh' is 'False'

  , maxThread   :: Maybe (IORef Int)
    -- ^ Maximum number of threads that are allowed to be created

  , labelth     :: IORef (LifeCycle, BS.ByteString)
    -- ^ Label the thread with its lifecycle state and a label string
  , parseContext :: ParseContext
  , execMode :: ExecMode
  } deriving Typeable

-- {-# NOINLINE threadId #-}
-- threadId x= unsafePerformIO $ readIORef $ pthreadId x

newtype StateIO a = StateIO (Triple (State EventF) IO StreamData a) deriving(Monad, Applicative, Functor)

instance MonadState EventF StateIO where
  get= lift get
  put= lift . put

newtype TransIO a = Transient {runTrans :: StateIO a}  deriving
    ( -- AdditionalOperators,
      Functor,
      Semigroup,
      Monoid,
      Num,
      Fractional
    )

instance Monad TransIO where
  return   = pure
  x >>= f  = Transient $ do
    r <- runTrans $ runTriple x
    runTriple (f r)


instance Applicative TransIO where
   pure  = Transient . return . SLast
   mf <*> mx = do
       f <- mf
       f <$> mx

instance Alternative TransIO where
    empty= Transient $ Control.Applicative.empty
    Transient x <|> Transient y= Transient $ x <|> y

instance MonadState EventF TransIO where
  get     = Transient <$> get
  put x   = Transient $ put x
  state f =  Transient $ do
    s <- get
    let ~(a, s') = f s
    put s'
    return $ SLast a




data ParseContext  = ParseContext { more   :: TransIO BSL.ByteString
                                  , buffer :: BSL.ByteString
                                  , done   :: IORef Bool} deriving Typeable



data StreamData a =
      SMore a               -- ^ More  to come           Just sin finalización
    | SLast a               -- ^ This is the last one    Just con finalizacion
    | SDone                 -- ^ No more, we are done    Nothing
    | SBacktrack Dynamic    -- ^ error/backtrack         BackTracking
    deriving (Typeable, Show,Read)

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


instance Monad ContMonad where
  return   = pure
  x >>= f  = ContMonad $ do
    k  <- setEventCont f
    mk <- runTrans x
    resetEventCont k
    case mk of
        Just r  -> runTrans (f r)
        Nothing -> return Nothing


setEventCont :: (a -> TransIO b) -> StateIO (a -> TransIO c)
setEventCont  f  = do
  EventF{fcomp= k} <- get
  let k' y = unsafeCoerce f y >>=  k
  modify $ \EventF { .. } -> EventF { fcomp = k', .. }
  return $ unsafeCoerce k

resetEventCont k= modify $ \EventF { .. } -> EventF {fcomp = k, .. }





-- alternativo: operador de la izquierda: si es sincrono, SLast.  Si es asincrono, SMore.
--              operador de la derecha si es sincrono, SLast si es asincrono, SLast
--              objetivo que todos los elementos del aplicativo den SMore y el ultimo, SLast
--              simular

onBack  e ex = do
     cont <- getCont
     r <- exec cont ()
     case r of
       SMore x -> return $ SMore x
       SLast x -> return $ SLast x
       SDone   -> return SDone
       SBacktrack e' ->
         if typeOf e/= typeOf e'
            then return $ SBackTrack e'
            else do
              back <- ex
              if back  then  return SBakTrack e'
                       else onBack e ex

main= do
     print "hi"
     return ()