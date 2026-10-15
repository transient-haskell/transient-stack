{-# LANGUAGE CPP, JavaScriptFFI, OverloadedStrings, FlexibleInstances #-}
-- | The types and functions of the JavaScript side that "GHCJS.Perch" and the widgets above it use, with one implementation
-- for each backend: the GHC wasm backend, GHCJS, and stubs for the server (where no DOM call can be executed).
--
-- For the wasm backend it offers the part of the API of @ghcjs-base@ that the widgets use (@syncCallback1@,
-- @fromJSVal@...), with the same names, so the code above changes as little as possible.
module Perch.JS
  ( JSVal,
#if defined(wasm32_HOST_ARCH)
    -- the constructors must be in scope for the foreign imports of the other modules
    JSString (..),
    Callback (..),
    OnBlocked (..),
    syncCallback1,
    FromJSVal (..),
    takeWhile,
    drop,
    toLower,
#else
    JSString,
    Callback,
#endif
    pack,
    unpack,
    asyncCallback1,
    jsListOf,
  )
where

#if defined(wasm32_HOST_ARCH)

import qualified Data.Char as C
import Data.String (IsString (..))
import GHC.Wasm.Prim
import Prelude hiding (drop, takeWhile)
import qualified Prelude

pack :: String -> JSString
pack = toJSString

unpack :: JSString -> String
unpack = fromJSString

instance IsString JSString where
  fromString = toJSString

instance Show JSString where
  show = show . unpack

instance Read JSString where
  readsPrec n s = [(pack x, r) | (x, r) <- readsPrec n s]

instance Eq JSString where
  a == b = unpack a == unpack b

instance Ord JSString where
  compare a b = compare (unpack a) (unpack b)

instance Semigroup JSString where
  a <> b = pack (unpack a <> unpack b)

instance Monoid JSString where
  mempty = pack ""

takeWhile :: (Char -> Bool) -> JSString -> JSString
takeWhile p = pack . Prelude.takeWhile p . unpack

drop :: Int -> JSString -> JSString
drop n = pack . Prelude.drop n . unpack

toLower :: JSString -> JSString
toLower = pack . map C.toLower . unpack

-- | A JavaScript function made from a Haskell one. It is not freed: use it for handlers that live as long as the page.
newtype Callback a = Callback JSVal

foreign import javascript "wrapper" js_wrapper1 :: (JSVal -> IO ()) -> IO JSVal

asyncCallback1 :: (JSVal -> IO ()) -> IO (Callback (JSVal -> IO ()))
asyncCallback1 = fmap Callback . js_wrapper1

-- | What GHCJS does when a synchronous callback blocks. In wasm all callbacks are asynchronous, so it is not used.
data OnBlocked = ContinueAsync | ThrowWouldBlock

syncCallback1 :: OnBlocked -> (JSVal -> IO ()) -> IO (Callback (JSVal -> IO ()))
syncCallback1 _ = asyncCallback1

foreign import javascript unsafe "$1.length" js_length :: JSVal -> IO Int

foreign import javascript unsafe "$1[$2]" js_index :: JSVal -> Int -> IO JSVal

foreign import javascript unsafe "$1 == null" js_isNullish :: JSVal -> IO Bool

foreign import javascript unsafe "String($1)" js_toString :: JSVal -> IO JSString

foreign import javascript unsafe "Number($1)" js_toNumber :: JSVal -> IO Double

foreign import javascript unsafe "Boolean($1)" js_toBool :: JSVal -> IO Bool

-- | The elements of a JavaScript array or NodeList.
jsListOf :: JSVal -> IO [JSVal]
jsListOf xs = do
  n <- js_length xs
  mapM (js_index xs) [0 .. n - 1]

-- | Conversion from JavaScript values, as in @ghcjs-base@: 'fromJSVal' gives 'Nothing' for @null@ and @undefined@.
class FromJSVal a where
  fromJSVal :: JSVal -> IO (Maybe a)
  fromJSValUnchecked :: JSVal -> IO a
  fromJSValUnchecked v = fromJSVal v >>= maybe (error "fromJSValUnchecked: null or undefined") return
  fromJSValUncheckedListOf :: JSVal -> IO [a]
  fromJSValUncheckedListOf xs = jsListOf xs >>= mapM fromJSValUnchecked

nullable :: (JSVal -> IO a) -> JSVal -> IO (Maybe a)
nullable f v = do
  n <- js_isNullish v
  if n then return Nothing else Just <$> f v

instance FromJSVal JSVal where
  fromJSVal = nullable return

instance FromJSVal JSString where
  fromJSVal = nullable js_toString

instance {-# OVERLAPPING #-} FromJSVal String where
  fromJSVal = nullable (fmap unpack . js_toString)

instance FromJSVal Int where
  fromJSVal = nullable (fmap round . js_toNumber)

instance FromJSVal Double where
  fromJSVal = nullable js_toNumber

instance FromJSVal Bool where
  fromJSVal = nullable js_toBool

#elif defined(ghcjs_HOST_OS)

import Data.JSString (JSString, pack, unpack)
import GHCJS.Foreign.Callback (Callback, asyncCallback1)
import GHCJS.Marshal (fromJSValUncheckedListOf)
import GHCJS.Types (JSVal)

jsListOf :: JSVal -> IO [JSVal]
jsListOf = fromJSValUncheckedListOf

#else

type JSVal = ()

type JSString = String

pack :: String -> JSString
pack = id

unpack :: JSString -> String
unpack = id

data Callback a = Callback a

asyncCallback1 :: (JSVal -> IO ()) -> IO (Callback (JSVal -> IO ()))
asyncCallback1 = undefined

jsListOf :: JSVal -> IO [JSVal]
jsListOf = undefined

#endif
