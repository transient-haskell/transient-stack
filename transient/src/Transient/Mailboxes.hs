 {-# LANGUAGE ExistentialQuantification #-}
module Transient.Mailboxes where

import Transient.Internals
import Transient.EVars
import qualified Data.Map as M
import Data.IORef
import Data.Typeable
import System.IO.Unsafe
import Unsafe.Coerce
import Control.Monad.IO.Class

mailboxes :: IORef (M.Map MailboxId (EVar SData))
mailboxes= unsafePerformIO $ newIORef M.empty

data MailboxId =  forall a .(Typeable a, Ord a) => MailboxId a TypeRep
--type SData= ()
instance Eq MailboxId where
   id1 == id2 =  id1 `compare` id2== EQ

instance Ord MailboxId where
   MailboxId n t `compare` MailboxId n' t'=
     case typeOf n `compare` typeOf n' of
         EQ -> case n `compare` unsafeCoerce n' of
                 EQ -> t `compare` t'
                 LT -> LT
                 GT -> GT

         other -> other

instance Show MailboxId where
    show ( MailboxId _ t) = show t

-- | write to the mailbox
-- Mailboxes are node-wide, for all processes that share the same connection data, that is, are under the
-- same `listen`  or `connect`
-- while EVars are only visible by the process that initialized  it and his children.
-- Internally, the mailbox is in a well known EVar stored by `listen` in the `Connection` state.
putMailbox :: Typeable val => val -> TransIO ()
putMailbox = putMailbox' (0::Int)

-- | write to a mailbox identified by an identifier besides the type
putMailbox' :: (Typeable key, Ord key, Typeable val) =>  key -> val -> TransIO ()
putMailbox'  idbox dat= do
   let name= MailboxId idbox $ typeOf dat
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> newMailbox name >> putMailbox' idbox dat
     Just ev -> writeEVar ev $ unsafeCoerce dat


newMailbox :: MailboxId -> TransIO ()
newMailbox name= do
--   return ()  -- !> "newMailBox"
   ev <- newEVar
   liftIO $ atomicModifyIORef mailboxes $ \mv ->   (M.insert name ev mv,())



-- | get messages from the mailbox that matches with the type expected.
-- The order of reading is defined by `readTChan`
-- This is reactive. it means that each new message trigger the execution of the continuation
-- each message wake up all the `getMailbox` computations waiting for it.
getMailbox :: Typeable val => TransIO val
getMailbox =  getMailbox' (0 :: Int)

-- | read from a mailbox identified by an identifier besides the type
getMailbox' :: (Typeable key, Ord key, Typeable val) => key -> TransIO val
getMailbox' mboxid = x where
 x = do
   let name= MailboxId mboxid $ typeOf $ typeOfM x
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing ->newMailbox name >> getMailbox' mboxid
     Just ev ->unsafeCoerce $ readEVar ev

 typeOfM :: TransIO a -> a
 typeOfM = undefined

-- | delete all subscriptions for that mailbox expecting this kind of data
deleteMailbox :: Typeable a => a -> TransIO ()
deleteMailbox = deleteMailbox'  (0 ::Int)

-- | clean a mailbox identified by an Int and the type
deleteMailbox' :: (Typeable key, Ord key, Typeable a) => key ->  a -> TransIO ()
deleteMailbox'  mboxid witness= do
   let name= MailboxId mboxid $ typeOf witness
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> return()
     Just ev -> do cleanEVar ev
                   liftIO $ atomicModifyIORef mailboxes $ \bs -> (M.delete name bs,())
