 {-# LANGUAGE ExistentialQuantification #-}
-- | Named, typed mailboxes for inter-thread publish\/subscribe messaging.
-- The actual implementation lives in 'Transient.Internals' (via 'Transient.LEngine');
-- this module re-exports the public API.
module Transient.Mailboxes(newMailbox,deleteMailbox,deleteMailbox',getMailbox,getMailbox',putMailbox,putMailbox',lastPutMailbox,lastPutMailbox',getEVarFromMailbox,getEVarFromMailbox') where

import Transient.Internals
