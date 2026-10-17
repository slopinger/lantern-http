{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Lantern's HTTP/1 wire implementation. No HTTP framework or client library.
module Lantern.HTTP
  ( Headers, Reader, ProtocolError(..), Request(..), ResponseHead(..), Framing(..)
  , newReader, readRequest, readRequestMaybe, readResponse, readResponseUpgrade, readChunk, readBody, collectBody, framing
  , header, values, tokens, lower, trim, validToken, connectionClose
  , writeHead, chunk, stripHop, decimal, failHTTP
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef
import Data.Typeable (Typeable)
import Numeric (showHex)

type Headers = [(B.ByteString, B.ByteString)]
data Reader = Reader (IO B.ByteString) (IORef B.ByteString)
data ProtocolError = ProtocolError Int String deriving (Show, Typeable)
instance Exception ProtocolError

data Framing = NoBody | Fixed Integer | Chunked | UntilClose deriving (Eq, Show)
data Request = Request
  { reqMethod :: B.ByteString, reqTarget :: B.ByteString
  , reqVersion :: B.ByteString, reqHeaders :: Headers, reqFraming :: Framing
  } deriving (Eq, Show)
data ResponseHead = ResponseHead
  { resStatus :: Int, resHeaders :: Headers, resFraming :: Framing
  } deriving (Eq, Show)

failHTTP :: Int -> String -> IO a
failHTTP n = throwIO . ProtocolError n

newReader :: IO B.ByteString -> IO Reader
newReader recv = Reader recv <$> newIORef B.empty

lower :: B.ByteString -> B.ByteString
lower = B.map (\c -> if c >= 65 && c <= 90 then c + 32 else c)
trim :: B.ByteString -> B.ByteString
trim = B.dropWhileEnd ows . B.dropWhile ows where ows c = c == 32 || c == 9
validToken :: B.ByteString -> Bool
validToken s = not (B.null s) && B.all tok s
  where tok c = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                (c >= 97 && c <= 122) || c `B.elem` "!#$%&'*+-.^_`|~"
values :: B.ByteString -> Headers -> [B.ByteString]
values k hs = [v | (n,v) <- hs, n == k]
header :: B.ByteString -> Headers -> Maybe B.ByteString
header = lookup
tokens :: B.ByteString -> [B.ByteString]
tokens = map (lower . trim) . C.split ','

decimal :: B.ByteString -> Maybe Integer
decimal s
  | B.null s || B.length s > 19 || not (B.all (\c -> c >= 48 && c <= 57) s) = Nothing
  | otherwise = Just (B.foldl' (\n c -> n * 10 + fromIntegral (c - 48)) 0 s)

-- Retains bytes after the delimiter, including a pipelined next request.
line :: Reader -> Int -> IO B.ByteString
line (Reader recv ref) limit = do
  buf <- readIORef ref
  if B.null buf then do
    more <- recv
    when (B.null more) $ failHTTP 400 "unexpected EOF"
    scan more
  else scan buf
  where
    scan buf = do
      let (front, rest) = B.breakSubstring "\r\n" buf
      if not (B.null rest) then finish front (B.drop 2 rest) else do
        checkPending (B.length buf)
        gather [buf] (B.length buf) (endsCR buf)
    finish front rest = do
      when (B.length front > limit) $ failHTTP 431 "line too large"
      when (B.any (\c -> c == 10 || c == 13) front) $ failHTTP 400 "bare newline"
      writeIORef ref rest
      pure front
    checkPending size = when (size > limit + 1) $ failHTTP 431 "line too large"
    endsCR bytes = not (B.null bytes) && B.last bytes == 13
    -- Search only newly received bytes, plus the possible CR/LF boundary.
    -- Concatenate once, after checking the complete line's size. Repeated
    -- prefix append/search would be quadratic for a byte-at-a-time peer.
    gather pieces size previousCR = do
      more <- recv
      when (B.null more) $ failHTTP 400 "unexpected EOF"
      if previousCR && B.head more == 10 then
        finish (B.init (B.concat (reverse pieces))) (B.tail more)
      else do
        let (front,rest) = B.breakSubstring "\r\n" more
            total = size + B.length front
        if not (B.null rest) then do
          when (total > limit) $ failHTTP 431 "line too large"
          finish (B.concat (reverse (front:pieces))) (B.drop 2 rest)
        else do
          checkPending total
          gather (more:pieces) total (endsCR more)

readHeaders :: Reader -> Int -> Int -> IO Headers
readHeaders r maxBytes maxCount = go 0 0 []
  where
    go used count acc = do
      s <- line r (min 8192 (maxBytes - used))
      let used' = used + B.length s + 2
      when (used' > maxBytes) $ failHTTP 431 "headers too large"
      if B.null s then pure (reverse acc) else do
        when (count >= maxCount) $ failHTTP 431 "too many headers"
        let (name, rest) = C.break (== ':') s
        unless (validToken name && not (B.null rest)) $ failHTTP 400 "invalid header name"
        let v = trim (B.tail rest)
        unless (B.all (\c -> c == 9 || (c >= 32 && c /= 127)) v) $ failHTTP 400 "invalid header value"
        go used' (count + 1) ((lower name,v):acc)

framing :: Bool -> Headers -> IO Framing
framing isRequest hs = do
  let cls = values "content-length" hs
      tes = values "transfer-encoding" hs
  when (length cls > 1 || length tes > 1) $ failHTTP 400 "duplicate framing"
  when (not (null cls) && not (null tes)) $ failHTTP 400 "ambiguous framing"
  case (cls,tes) of
    ([v],[]) -> maybe (failHTTP 400 "invalid content length") (pure . Fixed) (decimal v)
    ([],[v]) | lower v == "chunked" -> pure Chunked
             | otherwise -> failHTTP 501 "unsupported transfer coding"
    ([],[]) -> pure (if isRequest then NoBody else UntilClose)
    _ -> failHTTP 400 "invalid framing"

-- | Clean connection EOF is allowed only before any byte of the next request.
-- Partial request EOF remains a protocol error. Caller must consume the previous
-- body before calling this, use one reader, and close on any parse/I/O failure.
readRequestMaybe :: Reader -> IO (Maybe Request)
readRequestMaybe r@(Reader recv ref) = do
  buffered <- readIORef ref
  if not (B.null buffered) then Just <$> readRequest r else do
    first <- recv
    if B.null first then pure Nothing else do
      writeIORef ref first
      Just <$> readRequest r

readRequest :: Reader -> IO Request
readRequest r = do
  start <- line r 8192
  (method,target,version) <- case C.split ' ' start of
    [m,t,v] | validToken m && B.length m <= 32 && not (B.null t) -> pure (m,t,v)
    _ -> failHTTP 400 "invalid request line"
  unless (version == "HTTP/1.1" || version == "HTTP/1.0") $ failHTTP 505 "unsupported HTTP version"
  unless (B.head target == 47 && B.all (\c -> c > 32 && c < 127 && c /= 35) target) $
    failHTTP 400 "origin-form target required"
  unless (validTarget target) $ failHTTP 400 "invalid request target"
  hs <- readHeaders r 32768 100
  when (length (values "host" hs) /= 1) $ failHTTP 400 "exactly one Host required"
  when (any (not . validToken) (concatMap tokens (values "connection" hs))) $
    failHTTP 400 "invalid Connection tokens"
  -- Framing/routing headers cannot be made hop-by-hop by an attacker.
  when (any (`elem` ["host","content-length","transfer-encoding"])
          (concatMap tokens (values "connection" hs))) $ failHTTP 400 "critical Connection token"
  f <- framing True hs
  when (version == "HTTP/1.0" && f == Chunked) $ failHTTP 400 "HTTP/1.0 transfer encoding"
  pure (Request method target version hs f)

-- URI syntax is validated before a proxy forwards it to a second parser.
validTarget :: B.ByteString -> Bool
validTarget bytes = go 0
  where
    size = B.length bytes
    go offset
      | offset == size = True
      | current == 37 = offset + 2 < size && hex (B.index bytes (offset+1)) &&
                        hex (B.index bytes (offset+2)) && go (offset+3)
      | otherwise = (alphaNum current || current `B.elem` "/?:@!$&'()*+,;=-._~[]") && go (offset+1)
      where current = B.index bytes offset
    alphaNum c = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    hex c = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)

readResponse :: Reader -> B.ByteString -> IO ResponseHead
readResponse = readResponseMode False

-- | Explicit upgrade parser: only callers validating the upgraded protocol may
-- use a returned 101 and then readChunk. Ordinary readResponse still rejects it.
readResponseUpgrade :: Reader -> B.ByteString -> IO ResponseHead
readResponseUpgrade = readResponseMode True

-- | Transfer unread bytes to an upgraded protocol before receiving more. Never
-- resume HTTP parsing on this reader after a successful protocol switch.
readChunk :: Reader -> IO B.ByteString
readChunk (Reader recv ref) = do
  buffered <- atomicModifyIORef' ref (\bytes -> (B.empty,bytes))
  if B.null buffered then recv else pure buffered

readResponseMode :: Bool -> Reader -> B.ByteString -> IO ResponseHead
readResponseMode upgrading r method = go (0 :: Int)
  where
    go interim = do
      when (interim >= 8) $ failHTTP 502 "too many informational responses"
      start <- line r 8192
      (version,code) <- case C.split ' ' start of
        v:c:reasonWords | v `elem` ["HTTP/1.0","HTTP/1.1"] && B.length c == 3 &&
                     not (null reasonWords) && B.all (\x -> x >= 32 && x /= 127) (C.unwords reasonWords) ->
          case decimal c of
            Just n | n >= 100 && n <= 599 -> pure (v,fromInteger n)
            _ -> failHTTP 502 "invalid upstream status"
        _ -> failHTTP 502 "invalid upstream status line"
      hs <- readHeaders r 32768 100
      when (version == "HTTP/1.0" && not (null (values "transfer-encoding" hs))) $
        failHTTP 502 "HTTP/1.0 transfer encoding"
      f <- framing False hs
      when ((code < 200 || code == 204) && (not (null (values "content-length" hs)) || not (null (values "transfer-encoding" hs)))) $
        failHTTP 502 "framing forbidden for this upstream status"
      when (code == 101 && (not upgrading || version /= "HTTP/1.1")) $ failHTTP 502 "upstream protocol upgrade unsupported"
      if code < 200 && code /= 101 then go (interim + 1) else
        pure (ResponseHead code hs (if method == "HEAD" || code `elem` [101,204,304] then NoBody else f))

-- Bounded pieces, not read(n) into an attacker-sized allocation.
takeBytes :: Reader -> Integer -> (B.ByteString -> IO ()) -> IO ()
takeBytes r@(Reader recv ref) count emit
  | count <= 0 = pure ()
  | otherwise = do
      buf <- readIORef ref
      if B.null buf then do
        more <- recv
        when (B.null more) $ failHTTP 400 "truncated body"
        writeIORef ref more
        takeBytes r count emit
      else do
        let n = fromInteger (min count (fromIntegral (B.length buf)))
        writeIORef ref (B.drop n buf)
        emit (B.take n buf)
        takeBytes r (count - fromIntegral n) emit

readBody :: Reader -> Framing -> Integer -> (B.ByteString -> IO ()) -> IO ()
readBody r@(Reader recv ref) mode limit emit = case mode of
  NoBody -> pure ()
  Fixed n -> do
    when (n > limit) $ failHTTP 413 "body too large"
    takeBytes r n emit
  UntilClose -> do
    first <- atomicModifyIORef' ref (\b -> (B.empty,b))
    let loop used b = do
          let used' = used + fromIntegral (B.length b)
          when (used' > limit) $ failHTTP 502 "upstream body too large"
          unless (B.null b) (emit b)
          more <- recv
          unless (B.null more) (loop used' more)
    loop 0 first
  Chunked -> chunks 0 0
  where
    chunks total overhead = do
      s <- line r 1024
      let (digits, ext) = C.break (== ';') s
      unless (not (B.null digits) && B.length digits <= 16 && B.all isHex digits) $
        failHTTP 400 "invalid chunk size"
      -- Strict bounded extensions: printable ASCII, no interpretation or forwarding.
      unless (B.all (\c -> c >= 32 && c < 127) ext) $ failHTTP 400 "invalid chunk extension"
      let size = B.foldl' (\n c -> n * 16 + fromIntegral (hex c)) 0 digits
          overhead' = overhead + B.length s + 2
      when (overhead' > 65536) $ failHTTP 413 "too much chunk overhead"
      when (total + size > limit) $ failHTTP 413 "body too large"
      if size == 0 then do
        trailers <- readHeaders r 8192 32
        unless (all (\(k,_) -> k `notElem` forbiddenTrailers) trailers) $
          failHTTP 400 "forbidden trailer"
      else do
        takeBytes r size emit
        ending <- line r 0
        unless (B.null ending) $ failHTTP 400 "missing chunk terminator"
        chunks (total + size) overhead'
    isHex c = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    hex c | c <= 57 = c - 48
          | otherwise = (c .&. 31) + 9
    forbiddenTrailers = ["content-length","transfer-encoding","host","connection","trailer",
      "authorization","proxy-authorization","cookie","set-cookie","content-encoding","content-type"]

collectBody :: Reader -> Framing -> Integer -> IO B.ByteString
collectBody r f limit = do
  ref <- newIORef []
  readBody r f limit (\b -> modifyIORef' ref (b:))
  B.concat . reverse <$> readIORef ref

connectionClose :: Request -> Bool
connectionClose r = reqVersion r == "HTTP/1.0" ||
  "close" `elem` concatMap tokens (values "connection" (reqHeaders r))

-- Drops both the standard hop fields and every Connection-nominated field.
stripHop :: Headers -> Headers
stripHop hs = filter (\(k,_) -> k `notElem` denied) hs
  where denied = ["connection","keep-alive","proxy-authenticate","proxy-authorization",
          "te","trailer","transfer-encoding","upgrade","proxy-connection","content-length"] ++
          concatMap tokens (values "connection" hs)

-- All callers supply validated/generated headers; still enforce the boundary here.
writeHead :: (B.ByteString -> IO ()) -> Int -> Headers -> IO ()
writeHead send status hs = do
  unless (status >= 100 && status <= 599 && all safe hs) $ failHTTP 500 "unsafe response headers"
  send ("HTTP/1.1 " <> C.pack (show status) <> " " <> reason status <> "\r\n" <>
        B.concat [k <> ": " <> v <> "\r\n" | (k,v) <- hs] <> "\r\n")
  where safe (k,v) = validToken k && B.all (\c -> c == 9 || (c >= 32 && c /= 127)) v

chunk :: (B.ByteString -> IO ()) -> B.ByteString -> IO ()
chunk send b = unless (B.null b) $ send (C.pack (showHex (B.length b) "") <> "\r\n" <> b <> "\r\n")

reason :: Int -> B.ByteString
reason s = case s of
  200 -> "OK"; 201 -> "Created"; 204 -> "No Content"; 206 -> "Partial Content"
  301 -> "Moved Permanently"; 302 -> "Found"; 304 -> "Not Modified"; 308 -> "Permanent Redirect"
  400 -> "Bad Request"; 403 -> "Forbidden"; 404 -> "Not Found"; 405 -> "Method Not Allowed"
  408 -> "Request Timeout"; 412 -> "Precondition Failed"; 416 -> "Range Not Satisfiable"; 413 -> "Content Too Large"; 417 -> "Expectation Failed"
  421 -> "Misdirected Request"; 431 -> "Request Header Fields Too Large"
  500 -> "Internal Server Error"; 501 -> "Not Implemented"; 502 -> "Bad Gateway"
  503 -> "Service Unavailable"; 504 -> "Gateway Timeout"; 505 -> "HTTP Version Not Supported"
  _ -> "Response"
