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
  -- Exact line limits and delimiter boundaries must be independent of reads.
  forM_ [1,2,3,127,8191,8192,16384] $ \width -> do
    forM_ [8177,8178] $ \padding -> do
      let target = "/" <> B.replicate padding 97
          wire = "GET " <> target <> " HTTP/1.1\r\nHost: localhost\r\nX: " <>
                 B.replicate 8189 98 <> "\r\n\r\n" <> base
      r <- readerOf width wire
      parsed <- readRequest r
      assertTest "exact fragmented line limit" (reqTarget parsed == target)
      next <- readRequest r
      assertTest "large fragmented line preserves pipeline" (reqTarget next == "/hello?q=1")
    r <- readerOf width ("GET /" <> B.replicate 8179 97 <> " HTTP/1.1\r\nHost: localhost\r\n\r\n")
    outcome <- try (readRequest r)
    case outcome of
      Left (ProtocolError status _) -> assertTest "fragmented line overflow status" (status == 431)
      Right _ -> fail "oversized fragmented line accepted"
  -- A CR at the end of a fragment is not a delimiter unless the next byte is LF.
  forM_ ["GET /bad\rX HTTP/1.1\r\nHost: localhost\r\n\r\n",
         "GET / HTTP/1.1\r\nHost: local\nhost\r\n\r\n"] $ \wire ->
    forM_ [1..32] $ \width -> do
      r <- readerOf width wire
      outcome <- try (readRequest r)
      case outcome of Left (_ :: ProtocolError) -> pure (); Right _ -> fail "bare newline accepted"
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
  result3 <- quickCheckWithResult stdArgs {maxSuccess=1000,maxSize=100} propRequestFragments
  unless (isSuccess result3) exitFailure
  forM_ [B.singleton byte | byte <- [0..255]] $ \suffix -> do
    ok <- targetAgrees ("/" <> suffix) 1
    assertTest "single-octet target policy" ok
  forM_ ["%", "%0", "%aZ", "%gg", "%00", "%2F", "%aB", "a%20b", "a%ff%00"] $ \suffix -> do
    ok <- targetAgrees ("/" <> suffix) 1
    assertTest "percent target policy" ok
  result4 <- quickCheckWithResult stdArgs {maxSuccess=3000,maxSize=100} propTargetPolicy
  unless (isSuccess result4) exitFailure
  putStrLn "protocol regressions passed (128 fragmentation widths, line boundaries, 12000 properties)"

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

-- Compare long valid requests and a following message against a whole-buffer read.
propRequestFragments :: NonNegative Int -> [Positive Int] -> Property
propRequestFragments (NonNegative padding) widths = ioProperty $ do
  let target = "/" <> B.take (((padding `mod` 8178)*83) `mod` 8178) (B.concat (replicate 910 "aB09-._~/"))
      wire = "POST " <> target <> " HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc" <> base
      split _ bytes | B.null bytes = []
      split [] bytes = let (front,rest)=B.splitAt 7 bytes in front:split [] rest
      split (Positive n:ns) bytes = let (front,rest)=B.splitAt (1+n `mod` 1024) bytes in front:split ns rest
  ref <- newIORef (split widths wire)
  fragmented <- newReader (atomicModifyIORef' ref (\xs -> case xs of [] -> ([],B.empty); x:rest -> (rest,x)))
  whole <- readerOf (B.length wire) wire
  first <- readRequest fragmented
  expected <- readRequest whole
  body <- collectBody fragmented (reqFraming first) 3
  expectedBody <- collectBody whole (reqFraming expected) 3
  next <- readRequest fragmented
  expectedNext <- readRequest whole
  pure (first == expected && body == expectedBody && body == "abc" && next == expectedNext)

-- Previous list-based grammar is a separate acceptance oracle for the indexed scan.
referenceTarget :: B.ByteString -> Bool
referenceTarget bytes = B.all (\c -> c > 32 && c < 127 && c /= 35) bytes && scan (B.unpack bytes)
  where
    scan [] = True
    scan (37:a:b:rest) = isHex a && isHex b && scan rest
    scan (37:_) = False
    scan (c:rest) = (alphaNum c || c `B.elem` "/?:@!$&'()*+,;=-._~[]") && scan rest
    alphaNum c = (c>=48 && c<=57)||(c>=65 && c<=90)||(c>=97 && c<=122)
    isHex c = (c>=48 && c<=57)||(c>=65 && c<=70)||(c>=97 && c<=102)

targetAgrees :: B.ByteString -> Int -> IO Bool
targetAgrees target width = do
  reader <- readerOf width ("GET " <> target <> " HTTP/1.1\r\nHost: localhost\r\n\r\n")
  outcome <- try (readRequest reader)
  pure $ case outcome of
    Left (_ :: ProtocolError) -> not (referenceTarget target)
    Right request -> referenceTarget target && reqTarget request == target

propTargetPolicy :: Property
propTargetPolicy = forAll generated $ \(target,width) -> ioProperty (targetAgrees target width)
  where
    generated = do
      atoms <- listOf (frequency [(3, B.singleton <$> elements (B.unpack "aBZ019/?:@!$&'()*+,;=-._~[]")),
                                 (1, elements ["%00","%2F","%aB","%7e"])])
      bad <- elements ["", "", "%", "%0", "%gg", "\\", "^", "|", "{", "}", "#", "`"]
      width <- chooseInt (1,128)
      pure ("/" <> B.concat atoms <> bad,width)
