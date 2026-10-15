{-# LANGUAGE CPP, JavaScriptFFI, OverloadedStrings #-}
-- | The types and functions of the JavaScript side that the rest of the package uses, with one implementation for each
-- backend: the GHC wasm backend, GHCJS, and stubs for the server (where no DOM call can be executed).
module Internal.JS
  ( JSVal,
#if defined(wasm32_HOST_ARCH)
    -- the constructors must be in scope for the foreign imports of the other modules
    JSString (..),
    Callback (..),
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

import Data.String (IsString (..))
import GHC.Wasm.Prim

pack :: String -> JSString
pack = toJSString

unpack :: JSString -> String
unpack = fromJSString

instance IsString JSString where
  fromString = toJSString

-- | A JavaScript function made from a Haskell one. It is not freed: use it for handlers that live as long as the page.
newtype Callback a = Callback JSVal

foreign import javascript "wrapper" js_wrapper1 :: (JSVal -> IO ()) -> IO JSVal

asyncCallback1 :: (JSVal -> IO ()) -> IO (Callback (JSVal -> IO ()))
asyncCallback1 = fmap Callback . js_wrapper1

foreign import javascript unsafe "$1.length" js_length :: JSVal -> IO Int

foreign import javascript unsafe "$1[$2]" js_index :: JSVal -> Int -> IO JSVal

-- | The elements of a JavaScript array or NodeList.
jsListOf :: JSVal -> IO [JSVal]
jsListOf xs = do
  n <- js_length xs
  mapM (js_index xs) [0 .. n - 1]

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
