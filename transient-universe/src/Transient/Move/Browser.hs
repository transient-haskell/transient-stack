{-# LANGUAGE CPP, ForeignFunctionInterface, JavaScriptFFI #-}
-- | The only module with the JavaScript FFI of the browser side of "Transient.Move".
-- It has one implementation for GHC's wasm backend and another for GHCJS.
module Transient.Move.Browser
  ( WebSocket,
    webSocketNew,
    webSocketSend,
    webSocketClose,
    webSocketOnOpen,
    webSocketOnMessage,
    locationHostname,
    locationPort,
    locationProtocol,
    locationPathname,
  )
where

#if defined(wasm32_HOST_ARCH)

import GHC.Wasm.Prim

newtype WebSocket = WebSocket JSVal

instance Show WebSocket where
  show _ = "WebSocket"

foreign import javascript unsafe "new WebSocket($1)" js_new :: JSString -> IO JSVal
foreign import javascript unsafe "$1.send($2)" js_send :: JSVal -> JSString -> IO ()
foreign import javascript unsafe "$1.close()" js_close :: JSVal -> IO ()
foreign import javascript unsafe "$1.onopen = $2" js_onopen :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "$1.onmessage = $2" js_onmessage :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "$1.data" js_data :: JSVal -> IO JSString
foreign import javascript "wrapper" js_callback0 :: IO () -> IO JSVal
foreign import javascript "wrapper" js_callback1 :: (JSVal -> IO ()) -> IO JSVal
foreign import javascript unsafe "window.location.hostname" js_hostname :: IO JSString
foreign import javascript unsafe "window.location.port" js_port :: IO JSString
foreign import javascript unsafe "window.location.protocol" js_protocol :: IO JSString
foreign import javascript unsafe "window.location.pathname" js_pathname :: IO JSString

webSocketNew :: String -> IO WebSocket
webSocketNew url = WebSocket <$> js_new (toJSString url)

webSocketSend :: WebSocket -> String -> IO ()
webSocketSend (WebSocket ws) = js_send ws . toJSString

webSocketClose :: WebSocket -> IO ()
webSocketClose (WebSocket ws) = js_close ws

webSocketOnOpen :: WebSocket -> (() -> IO ()) -> IO ()
webSocketOnOpen (WebSocket ws) cb = js_callback0 (cb ()) >>= js_onopen ws

webSocketOnMessage :: WebSocket -> (String -> IO ()) -> IO ()
webSocketOnMessage (WebSocket ws) cb =
  js_callback1 (\ev -> js_data ev >>= cb . fromJSString) >>= js_onmessage ws

locationHostname, locationProtocol, locationPathname :: IO String
locationHostname = fromJSString <$> js_hostname
locationProtocol = fromJSString <$> js_protocol
locationPathname = fromJSString <$> js_pathname

-- | The port of the page; 80 when the URL does not have one.
locationPort :: IO Int
locationPort = do
  p <- fromJSString <$> js_port
  return $ if null p then 80 else read p

#else

import GHCJS.Foreign.Callback
import GHCJS.Marshal (fromJSValUnchecked)
import GHCJS.Prim (JSVal)
import qualified Data.JSString as JS
import qualified JavaScript.Web.MessageEvent as JM
import JavaScript.Web.MessageEvent.Internal (MessageEvent(..))
import qualified JavaScript.Web.WebSocket as W
import JavaScript.Web.WebSocket (WebSocket)

foreign import javascript safe "window.location.hostname" js_hostname :: JSVal
foreign import javascript safe "window.location.pathname" js_pathname :: JSVal
foreign import javascript safe "window.location.protocol" js_protocol :: JSVal
foreign import javascript safe
  "(function(){var res=window.location.href.split(':')[2];if (res === undefined){return 80} else return res.split('/')[0];})()"
  js_port :: JSVal
foreign import javascript safe "new WebSocket($1)" js_new :: JS.JSString -> IO WebSocket
foreign import javascript safe "$1.onopen =$2;" js_onopen :: WebSocket -> JSVal -> IO ()
foreign import javascript safe "$1.onmessage =$2;" js_onmessage :: WebSocket -> JSVal -> IO ()

webSocketNew :: String -> IO WebSocket
webSocketNew = js_new . JS.pack

webSocketSend :: WebSocket -> String -> IO ()
webSocketSend ws s = W.send (JS.pack s) ws

webSocketClose :: WebSocket -> IO ()
webSocketClose = W.close Nothing Nothing

webSocketOnOpen :: WebSocket -> (() -> IO ()) -> IO ()
webSocketOnOpen ws cb = do
  Callback f <- syncCallback ContinueAsync (cb ())
  js_onopen ws f

webSocketOnMessage :: WebSocket -> (String -> IO ()) -> IO ()
webSocketOnMessage ws cb = do
  Callback f <- syncCallback1 ContinueAsync (\ev -> case JM.getData (MessageEvent ev) of
                                                 JM.StringData t -> cb (JS.unpack t)
                                                 _               -> error "webSocketOnMessage: not a text message")
  js_onmessage ws f

locationHostname, locationProtocol, locationPathname :: IO String
locationHostname = JS.unpack <$> fromJSValUnchecked js_hostname
locationProtocol = JS.unpack <$> fromJSValUnchecked js_protocol
locationPathname = JS.unpack <$> fromJSValUnchecked js_pathname

locationPort :: IO Int
locationPort = fromJSValUnchecked js_port

#endif
