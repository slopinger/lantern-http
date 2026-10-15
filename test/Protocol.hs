{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import Data.IORef
import Lantern.HTTP
import System.Exit (exitFailure)
import Test.QuickCheck hiding (Fixed, label)

assertTest :: String -> Bool -> IO ()
assertTest label ok = unless ok (fail label)
readerOf :: Int -> B.ByteString -> IO Reader
readerOf size bytes = do
  ref <- newIORef bytes
  newReader (atomicModifyIORef' ref (\b -> let (a,r)=B.splitAt size b in (r,a)))
reject :: String -> B.ByteString -> IO ()
reject name bytes = do
  r <- readerOf 3 bytes
  outcome <- try (readRequest r)
  case outcome of
    Left (_ :: ProtocolError) -> pure ()
    Right _ -> fail ("accepted " ++ name)

base :: B.ByteString
base = "GET /hello?q=1 HTTP/1.1\r\nHost: localhost\r\n\r\n"

main :: IO ()
main = do
  forM_ [1..128] $ \n -> do
    r <- readerOf n (base <> "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" <> base)
    a <- readRequest r
    assertTest "fragmented target" (reqTarget a == "/hello?q=1")
    b <- readRequest r
    body <- collectBody r (reqFraming b) 100
    assertTest "fixed body" (body == "hello")
    c <- readRequest r
    assertTest "pipelining" (a == c)
    chunkReader <- readerOf n "3;abc=\"yes\"\r\nabc\r\n2\r\nde\r\n0\r\nx-checksum: fine\r\n\r\n"
    decoded <- collectBody chunkReader Chunked 5
    assertTest "chunked fragmentation" (decoded == "abcde")
  forM_ [
      ("bare LF","GET / HTTP/1.1\nHost: localhost\n\n"),
      ("space before colon","GET / HTTP/1.1\r\nHost : localhost\r\n\r\n"),
      ("folding","GET / HTTP/1.1\r\nHost: localhost\r\n x: y\r\n\r\n"),
      ("duplicate host","GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
      ("missing host","GET / HTTP/1.1\r\n\r\n"),
      ("CL+TE","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n"),
      ("duplicate CL","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"),
      ("comma CL","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0,0\r\n\r\n"),
      ("signed CL","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +1\r\n\r\n"),
      ("multiple TE","POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"),
      ("critical hop","GET / HTTP/1.1\r\nHost: a\r\nConnection: host\r\n\r\n"),
      ("absolute target","GET http://example.com/ HTTP/1.1\r\nHost: a\r\n\r\n"),
      ("invalid percent escape","GET /bad%zz HTTP/1.1\r\nHost: a\r\n\r\n"),
      ("backslash target","GET /bad\\path HTTP/1.1\r\nHost: a\r\n\r\n"),
      ("HTTP2 preface","PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"),
      ("oversized header","GET / HTTP/1.1\r\nHost: a\r\nX: " <> B.replicate 8193 65 <> "\r\n\r\n")
    ] (uncurry reject)
  forM_ ["z\r\n", "1\r\naX\r\n0\r\n\r\n", "0\r\nHost: evil\r\n\r\n", "6\r\nabcdef\r\n0\r\n\r\n", "1\r\na\r\n"] $ \wire -> do
    r <- readerOf 2 wire
    result <- try (collectBody r Chunked 5)
    case result of Left (_ :: ProtocolError) -> pure (); Right _ -> fail "invalid chunks accepted"
  r <- readerOf 1 "HTTP/1.1 103 Early Hints\r\nLink: x\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
  response <- readResponse r "GET"
  assertTest "interim response" (resStatus response == 200)
  body <- collectBody r (resFraming response) 10
  assertTest "response body" (body == "abc")
  assertTest "hop stripping" (stripHop [("connection","x-private"),("x-private","secret"),("ok","yes")] == [("ok","yes")])
  result <- quickCheckWithResult stdArgs {maxSuccess=3000} propFragmentation
  unless (isSuccess result) exitFailure
  result2 <- quickCheckWithResult stdArgs {maxSuccess=5000,maxSize=2000} propNeverCrash
  unless (isSuccess result2) exitFailure
  putStrLn "protocol regressions passed (128 fragmentation widths, 8000 properties)"

propFragmentation :: Positive Int -> [Word] -> Property
propFragmentation (Positive n) input = ioProperty $ do
  let body = B.pack (map fromIntegral (take 1000 input))
  r <- readerOf (1 + n `mod` 100) body
  actual <- collectBody r (Fixed (fromIntegral (B.length body))) 1000
  pure (body == actual)

propNeverCrash :: [Word] -> Property
propNeverCrash input = ioProperty $ do
  r <- readerOf 7 (B.pack (map fromIntegral input))
  result <- try (readRequest r)
  case result of
    Left (e :: SomeException) -> pure (case fromException e :: Maybe ProtocolError of Just _ -> True; Nothing -> False)
    Right _ -> pure True
