{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}
{-# LANGUAGE InstanceSigs #-}

-- | Event variables ('EVar') for publish-subscribe patterns.
-- Writers call 'writeEVar'; readers subscribe with 'readEVar' and are notified
-- reactively without explicit loops or blocking.
-- The implementation lives in 'Transient.Internals'.
module Transient.EVars(EVar,newEVar, readEVar,readEVar', readEVarId,readEVar1,delReadEVar,delReadEVarPoint,writeEVar) where

import Transient.Internals
