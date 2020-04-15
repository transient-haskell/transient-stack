-----------------------------------------------------------------------------
--
-- Module      :  Transient.MoveTLS
-- Copyright   :
-- License     :  GPL-3
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | see <https://www.fpcomplete.com/user/agocorona/moving-haskell-processes-between-nodes-transient-effects-iv>
-----------------------------------------------------------------------------

{-# LANGUAGE   CPP, OverloadedStrings, BangPatterns, ScopedTypeVariables #-}

module Transient.TLS(initTLS, initTLS') where
#ifndef ghcjs_HOST_OS
import           Transient.Internals
import           Transient.Move.Internals
import           Transient.Backtrack
import           Transient.Parse

import           Network.Socket                     as NSS
import           Network.Socket.ByteString          as NS

import           Network.TLS                        as TLS
import           Network.TLS.Extra                  as TLSExtra
import qualified Crypto.Random.AESCtr               as AESCtr

import qualified Network.Socket.ByteString.Lazy     as SBSL

import qualified Data.ByteString.Lazy               as BL
import qualified Data.ByteString.Lazy.Char8         as BL8
import qualified Data.ByteString.Char8              as B
import qualified Data.ByteString                    as BE

import qualified Data.X509.CertificateStore         as C
import           Data.Default
import           Control.Applicative
import           Control.Exception                  as E hiding (onException)
import           Control.Monad.State
import           Data.IORef
import           Unsafe.Coerce
import           System.IO.Unsafe
import           System.Directory
import           System.X509 (getSystemCertificateStore)  --to avoid checking certificate. delete
import Debug.Trace




-- | init TLS with the files "cert.pem" and "key.pem"
initTLS :: MonadIO m => m ()
initTLS =  do
  c <- liftIO $ doesFileExist "cert.pem"
  k <- liftIO $ doesFileExist "key.pem"
  if not c || not k 
     then error "cert.pem and key.pem must exist withing the current directory"
     else initTLS' "cert.pem" "key.pem"


-- | init TLS using  certificate.pem and a key.pem files
initTLS' :: MonadIO m => FilePath -> FilePath -> m ()
initTLS' certpath keypath = liftIO $ writeIORef
  tlsHooks
  ( unsafeCoerce $ (TLS.sendData :: TLS.Context -> BL8.ByteString -> IO ())
  , unsafeCoerce $ (TLS.recvData :: TLS.Context -> IO BE.ByteString)
  , unsafeCoerce $ Transient.TLS.maybeTLSServerHandshake certpath keypath
  , unsafeCoerce $ Transient.TLS.maybeClientTLSHandshake
  , unsafeCoerce $ (Transient.TLS.tlsClose :: TLS.Context -> IO ())
  )

tlsClose ctx= bye ctx >> contextClose ctx

maybeTLSServerHandshake
  :: FilePath -> FilePath -> Socket -> BL8.ByteString -> TransIO ()
maybeTLSServerHandshake certpath keypath sock input= do
 if ((not $ BL.null input) && BL.head input  == 0x16)
   then  do
        mctx <- liftIO $( do
              ctx <- makeServerContext (ssettings certpath keypath) sock  input
              TLS.handshake ctx
              return $Just ctx )
               `catch` \(e:: SomeException) -> do
                     print e
                     return Nothing               -- !> "after handshake"

        case mctx of
          Nothing -> return ()
          Just ctx -> do
             -- modifyState $ \(Just c) -> Just  c{connData= Just $ TLSNode2Node $ unsafeCoerce ctx}
             conn <- getSData <|> error "TLS: no socket connection"
             liftIO $ writeIORef (connData conn) $  Just $ TLSNode2Node $ unsafeCoerce ctx 
                   
             modify $ \s -> s{ parseContext=ParseContext (TLS.recvData ctx >>= return . SMore . BL8.fromStrict)
                               ("" ::   BL8.ByteString)}

             onException $ \(e:: SomeException) -> liftIO $ TLS.contextClose ctx
   else return ()

ssettings :: FilePath -> FilePath -> ServerParams
ssettings certpath keypath = unsafePerformIO $ do
      cred <- either error id <$> TLS.credentialLoadX509 certpath keypath
      return $ makeServerSettings    cred


maybeClientTLSHandshake :: String -> Socket -> BL8.ByteString -> TransIO ()
maybeClientTLSHandshake hostname sock input = do
   mctx <- liftIO $ (do
           global <- getSystemCertificateStore
           let sp= makeClientSettings global hostname
           ctx <- makeClientContext sp sock input
           TLS.handshake ctx
--           return () !> "after handshake"
           return $ Just ctx)
              `catch` \(e :: SomeException) -> return Nothing
   case mctx of
     Nothing -> liftIO $ print "No TLS connection" >> return ()                   --  !> "NO TLS"
     Just ctx -> do
        liftIO $ print "TLS connection" >> return ()                           --  !> "TLS"
        --modifyState $ \(Just c) -> Just  c{connData= Just $ TLSNode2Node $ unsafeCoerce ctx}
        conn <- getSData <|> error "TLS: no socket connection"
        liftIO $ writeIORef (connData conn) $  Just $ TLSNode2Node $ unsafeCoerce ctx 
        modify $ \st -> st{parseContext= ParseContext (TLS.recvData ctx >>= return . SMore . BL.fromChunks . (:[]))
                               ("" ::   BL8.ByteString)}
        onException $ \(e:: SomeException) ->  liftIO $ TLS.contextClose ctx

makeClientSettings global hostname= ClientParams{
         TLS.clientUseMaxFragmentLength= Nothing
      ,  TLS.clientServerIdentification= (hostname,"")
      ,  TLS.clientUseServerNameIndication = False
      ,  TLS.clientWantSessionResume = Nothing
      ,  TLS.clientShared  = novalidate
      ,  TLS.clientHooks = def
      ,  TLS.clientDebug= def
      ,  TLS.clientSupported = supported
      }
  where
  novalidate    = def
            { TLS.sharedCAStore         = global
            , TLS.sharedValidationCache = validationCache
            -- , TLS.sharedSessionManager  = connectionSessionManager
            }

  validationCache= TLS.ValidationCache (\_ _ _ -> return TLS.ValidationCachePass)
                                    (\_ _ _ -> return ())


makeServerSettings credential = def { -- TLS.ServerParams
        TLS.serverWantClientCert = False
      , TLS.serverCACertificates = []
      , TLS.serverDHEParams      = Nothing
      , TLS.serverHooks          = hooks
      , TLS.serverShared         = shared
      , TLS.serverSupported      = supported
      }
    where
    -- Adding alpn to user's tlsServerHooks.
    hooks =  def
--    TLS.ServerHooks {
--        TLS.onALPNClientSuggest = TLS.onALPNClientSuggest tlsServerHooks <|>
--          (if settingsHTTP2Enabled set then Just alpn else Nothing)
--      }

    shared = def {
        TLS.sharedCredentials = TLS.Credentials [credential]
      }
supported = def { -- TLS.Supported
        TLS.supportedVersions       = [TLS.TLS12,TLS.TLS11,TLS.TLS10]
      , TLS.supportedCiphers        = ciphers
      , TLS.supportedCompressions   = [TLS.nullCompression]
      , TLS.supportedHashSignatures = [
          -- Safari 8 and go tls have bugs on SHA 512 and SHA 384.
          -- So, we don't specify them here at this moment.
          (TLS.HashSHA256, TLS.SignatureRSA)
        , (TLS.HashSHA224, TLS.SignatureRSA)
        , (TLS.HashSHA1,   TLS.SignatureRSA)
        , (TLS.HashSHA1,   TLS.SignatureDSS)
        ]
      , TLS.supportedSecureRenegotiation = True
      , TLS.supportedClientInitiatedRenegotiation = False
      , TLS.supportedSession             = True
      , TLS.supportedFallbackScsv        = True
      }
ciphers :: [TLS.Cipher]
ciphers =
    [ TLSExtra.cipher_ECDHE_RSA_AES128GCM_SHA256
    , TLSExtra.cipher_ECDHE_RSA_AES128CBC_SHA256
    , TLSExtra.cipher_ECDHE_RSA_AES128CBC_SHA
    , TLSExtra.cipher_DHE_RSA_AES128GCM_SHA256
    , TLSExtra.cipher_DHE_RSA_AES256_SHA256
    , TLSExtra.cipher_DHE_RSA_AES128_SHA256
    , TLSExtra.cipher_DHE_RSA_AES256_SHA1
    , TLSExtra.cipher_DHE_RSA_AES128_SHA1
    , TLSExtra.cipher_DHE_DSS_AES128_SHA1
    , TLSExtra.cipher_DHE_DSS_AES256_SHA1
    , TLSExtra.cipher_AES128_SHA1
    , TLSExtra.cipher_AES256_SHA1
    ]

makeClientContext params sock input= do
    inputBuffer <- newIORef input
    liftIO $ TLS.contextNew (backend inputBuffer) params
    where
    backend inputBuffer= TLS.Backend {
        TLS.backendFlush = return ()
      , TLS.backendClose = NSS.close sock
      , TLS.backendSend  = NS.sendAll sock
      , TLS.backendRecv  = \n -> do
          input <- readIORef inputBuffer

          let (res,input')= BL.splitAt (fromIntegral n) input

          writeIORef inputBuffer input'
          return $ BL8.toStrict res
      }
--    step !acc 0 = return acc
--    step !acc n = do
--        bs <- NS.recv sock n
--        step (acc `B.append` bs) (n - B.length bs)

-- | Make a server-side TLS 'Context' for the given settings, on top of the
-- given TCP `Socket` connected to the remote end.
makeServerContext :: MonadIO m => TLS.ServerParams -> Socket -> BL.ByteString  -> m Context
makeServerContext params sock input= liftIO $ do
    inputBuffer <- newIORef input
    TLS.contextNew (backend inputBuffer)  params


    where
    backend inputBuffer= TLS.Backend {
        TLS.backendFlush = return ()
      , TLS.backendClose = NSS.close sock
      , TLS.backendSend  = NS.sendAll sock
      , TLS.backendRecv  =  \n -> do

          input <- readIORef inputBuffer
          let (res,input')= BL.splitAt (fromIntegral n) input

          writeIORef inputBuffer input'
          return $ toStrict res
      }


    toStrict s= BE.concat $ BL.toChunks s :: BE.ByteString

--sendAll' sock bs =  NS.sendAll sock bs   `E.catch` \(SomeException e) -> throwIO e
#else
import Control.Monad.IO.Class

initTLS :: MonadIO m => m ()
initTLS= return ()

initTLS' :: MonadIO m => FilePath -> FilePath -> m ()
initTLS' _ _ = return ()
#endif
