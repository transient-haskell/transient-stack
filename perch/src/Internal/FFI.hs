{-# LANGUAGE CPP, JavaScriptFFI #-}
module Internal.FFI where

#ifdef BROWSER
import           Perch.JS
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- | GHCJS' callback taking one argument.
-- Handy synonym to simplify type signatures.
type Callback1 = Callback (JSVal -> IO ())

foreign import javascript unsafe "document"
  js_document :: IO JSVal

foreign import javascript unsafe "document.body"
  js_documentBody :: IO JSVal

foreign import javascript unsafe "document.getElementById($1)"
  js_getElementById :: JSString -> IO JSVal

foreign import javascript unsafe "document.querySelectorAll($1)"
  js_querySelectorAll :: JSString -> IO JSVal

foreign import javascript unsafe "document.createElement($1)"
  js_documentCreateNode :: JSString -> IO JSVal

foreign import javascript unsafe "document.createElementNS($1,$2)"
  js_documentCreateNodeNS ::  JSString -> JSString -> IO JSVal

foreign import javascript unsafe "document.createTextNode($1)"
  js_createTextNode :: JSString -> IO JSVal

-- | Check if object is an HTML Element of current DOM.  Works with HTML
-- elements and text nodes.
-- http://stackoverflow.com/a/20476546/1749901
foreign import javascript unsafe
  "$1 !== null && !(!$1.ownerDocument) && (window === ($1.ownerDocument.defaultView || $1.ownerDocument.parentWindow))"
  js_isInCurrentDOM :: JSVal -> IO Bool


foreign import javascript unsafe "$1.parentNode"
  js_parentNode :: JSVal -> IO JSVal

foreign import javascript unsafe "$1.appendChild($2)"
  js_appendChild :: JSVal -> JSVal -> IO ()

foreign import javascript unsafe "$1.replaceChild($2,$3)"
  js_replaceChild :: JSVal -> JSVal -> JSVal -> IO ()

foreign import javascript unsafe "$1.removeChild($2)"
  js_removeChild :: JSVal -> JSVal -> IO ()

foreign import javascript unsafe
  "while ($1.hasChildNodes()) $1.removeChild($1.lastChild)"
  js_clearChildren :: JSVal -> IO ()


foreign import javascript unsafe "$1.setAttribute($2, $3)"
  js_setAttribute :: JSVal -> JSString -> JSString -> IO ()

foreign import javascript unsafe "$1.innerHTML = $2"
  js_setInnerHtml :: JSVal -> JSString -> IO ()


foreign import javascript unsafe
  "$1.addEventListener($2, $3);"
  js_addEventListener :: JSVal -> JSString -> Callback1 -> IO ()

-- | Remove event listener from element.
foreign import javascript unsafe
  "$1.removeEventListener($2, $3);"
  js_removeEventListener :: JSVal -> JSString -> Callback1 -> IO ()
--------------------------------------------------------------------------------
#endif
