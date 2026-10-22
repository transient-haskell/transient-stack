{-|
Module      : GHCJS.Perch
Description : Monadic DOM builder
Copyright   : (c) Athur S. Fayzrakhmanov, 2015
                  Alberto G. Corona, 2015
License     : MIT
Maintainer  : heraldhoi@gmail.com
Stability   : experimental
Portability : Any

Monad and Monoid instances for a builder that hang DOM elements from the
current parent element.

-}

module GHCJS.Perch
  ( -- * Perch DOM Builder
    module Internal.Perch
    -- * Types
  , Elem (..)
  , PropId
  , Attribute
  , NamedEvent (..)
  , JsEvent (..)
    -- * Strings of the backend (in the original package the stub of the server defined @pack@ in Internal.Perch)
  , pack
    -- * Internal API
  , module Internal.API )
  where

import           Internal.API
import           Internal.Perch hiding (withPerch, withPerchBuild)
import           Internal.Type
import           Perch.JS (pack)
