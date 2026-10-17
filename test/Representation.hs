{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless, forM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (sort)
import Data.Time
import Lantern.HTTP.Encoding (encodingPreferences)
import Lantern.HTTP.Representation
import System.Exit (exitFailure)
import Test.QuickCheck

check :: String -> Bool -> IO ()
check name ok=unless ok (fail name)
now :: UTCTime
now=UTCTime (fromGregorian 2026 10 16) 0
old :: UTCTime
old=UTCTime (fromGregorian 1994 11 6) (5*3600+49*60+37)
validators :: Validators
validators=Validators (Just (Strong "current")) (Just old) True

main :: IO ()
main=do
  let offered=["br","gzip","identity"]
  check "encoding weights" (encodingPreferences offered [("accept-encoding","gzip;q=0.7, br;q=0.3")] == Right ["gzip","br","identity"])
  check "encoding exclusion" (encodingPreferences offered [("accept-encoding","*;q=0")] == Right [])
  check "encoding identity preference" (encodingPreferences offered [("accept-encoding","gzip;q=0.5, identity;q=1")] == Right ["identity","gzip"])
  check "empty encoding field" (encodingPreferences offered [("accept-encoding","")] == Right ["identity"])
  check "invalid encoding weight" (case encodingPreferences offered [("accept-encoding","gzip;q=2")] of Left _ -> True; _ -> False)
  forM_ ["Sun, 06 Nov 1994 05:49:37 GMT", "Sunday, 06-Nov-94 05:49:37 GMT", "Sun Nov  6 05:49:37 1994"] $ \date ->
    check "HTTP date forms" (parseHTTPDate now date==Just old)
  let future=UTCTime (fromGregorian 2075 1 1) 0
      past=UTCTime (fromGregorian 1977 1 1) 0
  check "RFC850 future year within 50" (parseHTTPDate now (C.pack (formatTime defaultTimeLocale "%A, %d-%b-%y %H:%M:%S GMT" future))==Just future)
  check "RFC850 year beyond 50" (parseHTTPDate now (C.pack (formatTime defaultTimeLocale "%A, %d-%b-%y %H:%M:%S GMT" past))==Just past)
  forM_ ["Sun, 31 Feb 2026 00:00:00 GMT", "Sun, 06 Nov 1994 05:49:37 UTC", "Mon, 06 Nov 1994 05:49:37 GMT"] $ \bad ->
    check "invalid HTTP date" (parseHTTPDate now bad==Nothing)
  let cond method hs value=preconditions now method hs value
  check "weak comparison" (cond "GET" [("if-none-match","W/\"current\"")] validators==Right NotModified)
  check "strong comparison" (cond "GET" [("if-match","W/\"current\"")] validators==Right PreconditionFailed)
  check "weak current cannot strong-match" (cond "GET" [("if-match","\"current\"")] validators {currentTag=Just (Weak "current")}==Right PreconditionFailed)
  check "If-Match star" (cond "GET" [("if-match","*")] validators==Right Proceed)
  check "If-None-Match star POST" (cond "POST" [("if-none-match","*")] validators==Right PreconditionFailed)
  check "date not modified" (cond "GET" [("if-modified-since",formatHTTPDate old)] validators==Right NotModified)
  check "date failed" (cond "GET" [("if-unmodified-since","Sun, 06 Nov 1994 04:49:37 GMT")] validators==Right PreconditionFailed)
  check "If-Match supersedes date" (cond "GET" [("if-match","*"),("if-unmodified-since","Sun, 06 Nov 1994 04:49:37 GMT")] validators==Right Proceed)
  check "If-None-Match supersedes date" (cond "GET" [("if-none-match","\"other\""),("if-modified-since",formatHTTPDate old)] validators==Right Proceed)
  check "If-Match evaluated first" (cond "GET" [("if-match","\"other\""),("if-none-match","*")] validators==Right PreconditionFailed)
  check "quoted comma not list split" (cond "GET" [("if-none-match","\"a,b\", \"current\"")] validators==Right NotModified)
  check "repeat tag list field" (cond "GET" [("if-none-match","\"other\""),("if-none-match","\"current\"")] validators==Right NotModified)
  forM_ ["w/\"current\"", "\"x\", *", "\"unterminated", "\"bad\n\"", B.intercalate "," (replicate 129 "\"x\"")] $ \bad ->
    check "invalid tag list" (case cond "GET" [("if-none-match",bad)] validators of Left _ -> True; _ -> False)
  check "empty If-None-Match list" (cond "GET" [("if-none-match","")] validators==Right Proceed)
  check "empty If-Match list" (cond "GET" [("if-match","")] validators==Right PreconditionFailed)
  check "tag opaque backslash" (parseEntityTag "W/\"a\\b,c\""==Right (Weak "a\\b,c"))
  let range method hs v size=selectRanges now method hs v size
      choose value=range "GET" [("range",value)] validators 10
  forM_ [("bytes=0-2",PartialRepresentation [ByteRange 0 3]),
      ("bytes=7-",PartialRepresentation [ByteRange 7 3]),
      ("bytes=-3",PartialRepresentation [ByteRange 7 3]),
      ("bytes=0-9999999999999999999999999999",PartialRepresentation [ByteRange 0 10]),
      ("bytes=-9999999999999999999999999999",PartialRepresentation [ByteRange 0 10]),
      ("bytes=9999999999999999999999999999-",RejectedRanges),
      ("bytes=-0",RejectedRanges),("bytes=10-12",RejectedRanges),
      ("bytes=4-2",FullRepresentation),("unknown=0-1",FullRepresentation),
      ("bytes=0-x",FullRepresentation),("bytes=1 -2",FullRepresentation),
      ("bytes=0-2,1-4,5-6",PartialRepresentation [ByteRange 0 7]),
      ("bytes=8-9,0-1",PartialRepresentation [ByteRange 8 2,ByteRange 0 2]),
      ("bytes=50-60,0-1",PartialRepresentation [ByteRange 0 2]),
      ("bytes=,0-1,",PartialRepresentation [ByteRange 0 2]),
      ("bytes="<>B.intercalate "," (replicate 17 "0-1"),RejectedRanges)] $ \(field,result) ->
    check ("range "++C.unpack field) (choose field==result)
  check "empty file unsatisfiable" (range "GET" [("range","bytes=0-")] validators 0==RejectedRanges)
  check "empty file suffix fallback" (range "GET" [("range","bytes=-1")] validators 0==FullRepresentation)
  check "HEAD ignores ranges" (range "HEAD" [("range","bytes=0-1")] validators 10==FullRepresentation)
  check "matching If-Range" (range "GET" [("range","bytes=0-1"),("if-range","\"current\"")] validators 10==PartialRepresentation [ByteRange 0 2])
  check "weak If-Range" (range "GET" [("range","bytes=0-1"),("if-range","W/\"current\"")] validators 10==FullRepresentation)
  check "date If-Range must be exact" (range "GET" [("range","bytes=0-1"),("if-range","Sun, 06 Nov 1994 06:49:37 GMT")] validators 10==FullRepresentation)
  check "weak date If-Range" (range "GET" [("range","bytes=0-1"),("if-range",formatHTTPDate old)] validators {dateIsStrong=False} 10==FullRepresentation)
  check "strong date If-Range" (range "GET" [("range","bytes=0-1"),("if-range",formatHTTPDate old)] validators 10==PartialRepresentation [ByteRange 0 2])
  forM_ [multipartParts "bad\r\n" "text/plain" 10 [ByteRange 0 1],
         multipartParts "safe" "text/plain\r\nx: y" 10 [ByteRange 0 1],
         multipartParts "safe" "text/plain" 10 [ByteRange 0 11]] $ \bad ->
    check "unsafe multipart rejected" (case bad of Left _ -> True; _ -> False)
  result<-quickCheckWithResult stdArgs {maxSuccess=3000,maxSize=30} propRanges
  unless (isSuccess result) exitFailure
  putStrLn "conditional/date/range regressions and 3000 range coverage/length properties passed"

propRanges :: NonNegative Int -> [(NonNegative Int,NonNegative Int)] -> Bool
propRanges (NonNegative rawSize) rawPairs =
  let size=toInteger (rawSize `mod` 256)
      pairs=take 8 [(min x y,max x y) | (NonNegative a,NonNegative b)<-rawPairs,
                     let x=toInteger (a `mod` 300), let y=toInteger (b `mod` 300)]
      field="bytes="<>B.intercalate "," [C.pack (show a++"-"++show b) | (a,b)<-pairs]
      expected=[i | i<-[0..size-1], any (\(a,b) -> i>=a && i<=b) pairs]
      selection=selectRanges now "GET" [("range",field)] validators size
  in case selection of
    FullRepresentation -> null pairs
    RejectedRanges -> null expected
    PartialRepresentation ranges ->
      let actual=concat [[a..a+count-1] | ByteRange a count<-ranges]
      in sort actual==expected && all (\r -> rangeStart r>=0 && rangeLength r>0 && rangeStart r+rangeLength r<=size) ranges &&
        case multipartParts "independent_test_boundary" "application/octet-stream" size ranges of
          Left _ -> False
          Right (parts,end,total) -> toInteger (B.length (B.concat [prefix<>B.replicate (fromInteger (rangeLength r)) 120<>"\r\n" | (r,prefix)<-parts]<>end))==total
