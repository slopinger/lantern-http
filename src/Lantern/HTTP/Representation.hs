{-# LANGUAGE OverloadedStrings #-}
-- | Transport-independent conditional and range semantics for an existing
-- representation. Filesystem metadata, body I/O and boundary entropy are callers'.
module Lantern.HTTP.Representation
  ( EntityTag(..), Validators(..), Condition(..), ByteRange(..), RangeSelection(..)
  , parseEntityTag, renderEntityTag, preconditions, selectRanges
  , parseHTTPDate, formatHTTPDate, contentRange, multipartParts
  ) where
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (sortOn)
import Data.Maybe (mapMaybe)
import Data.Time
import Lantern.HTTP (Headers, values, lower, trim)

data EntityTag = Strong B.ByteString | Weak B.ByteString deriving (Eq,Show)
data Validators = Validators
  { currentTag :: Maybe EntityTag, modifiedAt :: Maybe UTCTime, dateIsStrong :: Bool
  } deriving (Eq,Show)
data Condition = Proceed | NotModified | PreconditionFailed deriving (Eq,Show)
data ByteRange = ByteRange { rangeStart :: Integer, rangeLength :: Integer } deriving (Eq,Show)
data RangeSelection = FullRepresentation | PartialRepresentation [ByteRange] | RejectedRanges deriving (Eq,Show)

parseEntityTag :: B.ByteString -> Either String EntityTag
parseEntityTag bytes = do
  unless (B.length bytes<=8192) (Left "entity tag too large")
  (tag,remaining) <- takeTag (trim bytes)
  unless (B.null (trim remaining)) (Left "trailing entity tag data")
  pure tag
renderEntityTag :: EntityTag -> B.ByteString
renderEntityTag (Strong opaque) = "\""<>opaque<>"\""
renderEntityTag (Weak opaque) = "W/\""<>opaque<>"\""

takeTag :: B.ByteString -> Either String (EntityTag,B.ByteString)
takeTag bytes = do
  let (constructor,value)=if "W/" `B.isPrefixOf` bytes then (Weak,B.drop 2 bytes) else (Strong,bytes)
  unless (B.take 1 value == "\"") (Left "quoted entity tag required")
  let (opaque,end)=B.break (==34) (B.drop 1 value)
  unless (not (B.null end) && B.all (\c -> c==33 || (c>=35 && c/=127)) opaque) (Left "invalid entity tag")
  pure (constructor opaque,B.drop 1 end)

tagSet :: [B.ByteString] -> Either String (Maybe [EntityTag])
tagSet fields
  | B.length combined > 32768 = Left "entity tag list too large"
  | trim combined == "*" = Right Nothing
  | otherwise = Just <$> go combined 0 0 []
  where
    combined=B.intercalate "," fields
    go :: B.ByteString -> Int -> Int -> [EntityTag] -> Either String [EntityTag]
    go remaining count empty acc
      | count>128 || empty>128 = Left "too many entity tags or empty list elements"
      | B.null input = Right (reverse acc)
      | B.head input==44 = go (B.drop 1 input) count (empty+1) acc
      | otherwise = do
          unless (count<128) (Left "too many entity tags")
          (tag,tail') <- takeTag input
          case B.uncons (trim tail') of
            Nothing -> Right (reverse (tag:acc))
            Just (44,rest) -> go rest (count+1) empty (tag:acc)
            _ -> Left "invalid entity tag separator"
      where input=trim remaining

opaqueTag :: EntityTag -> B.ByteString
opaqueTag (Strong value)=value
opaqueTag (Weak value)=value
strongEqual :: EntityTag -> EntityTag -> Bool
strongEqual (Strong a) (Strong b)=a==b
strongEqual _ _=False

-- The 50-year rule for obsolete RFC 850 dates depends on the current year.
parseHTTPDate :: UTCTime -> B.ByteString -> Maybe UTCTime
parseHTTPDate now raw
  | B.length raw>128 || not (B.all (\c -> c>=32 && c<127) raw) = Nothing
  | otherwise = case canonical "%a, %d %b %Y %H:%M:%S GMT" 29 input of
      Just date -> Just date
      Nothing -> case obsolete of
        Just date -> Just date
        Nothing -> canonical "%a %b %e %H:%M:%S %Y" 24 input
  where
    input=trim raw
    canonical fmt size value=do
      unless (B.length value==size) Nothing
      date <- parseTimeM True defaultTimeLocale fmt (C.unpack value) :: Maybe UTCTime
      unless (C.pack (formatTime defaultTimeLocale fmt date)==value) Nothing
      pure date
    obsolete=case C.split '-' input of
      [prefix,month,yearTime] | B.length yearTime==15 && B.index yearTime 2==32 &&
          B.all (\c -> c>=48 && c<=57) (B.take 2 yearTime) -> do
        let suffix=B.foldl' (\n c -> n*10+fromIntegral (c-48)) 0 (B.take 2 yearTime)
            (currentYear,_,_)=toGregorian (utctDay now)
            actualYear=((currentYear+50-suffix) `div` 100)*100+suffix
            expanded=prefix<>"-"<>month<>"-"<>C.pack (show actualYear)<>B.drop 2 yearTime
        unless (actualYear>=1000 && actualYear<=9999) Nothing
        canonical "%A, %d-%b-%Y %H:%M:%S GMT" (B.length expanded) expanded
      _ -> Nothing

formatHTTPDate :: UTCTime -> B.ByteString
formatHTTPDate=C.pack . formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT"

preconditions :: UTCTime -> B.ByteString -> Headers -> Validators -> Either String Condition
preconditions now method headers validators = do
  match <- case values "if-match" headers of
    [] -> pure (maybe True (\time -> maybe True (<=time) (modifiedAt validators)) (date "if-unmodified-since"))
    fields -> do
      tags <- tagSet fields
      pure (maybe True (\tags' -> maybe False (\current -> any (strongEqual current) tags') (currentTag validators)) tags)
  if not match then pure PreconditionFailed else do
    unchanged <- case values "if-none-match" headers of
      [] -> pure (retrieval && maybe False (\time -> maybe False (<=time) (modifiedAt validators)) (date "if-modified-since"))
      fields -> do
        tags <- tagSet fields
        pure (maybe True (\tags' -> maybe False (\current -> any ((==opaqueTag current) . opaqueTag) tags') (currentTag validators)) tags)
    pure (if unchanged then if retrieval then NotModified else PreconditionFailed else Proceed)
  where
    retrieval=method `elem` ["GET","HEAD"]
    date name=case values name headers of [value] -> parseHTTPDate now value; _ -> Nothing

selectRanges :: UTCTime -> B.ByteString -> Headers -> Validators -> Integer -> RangeSelection
selectRanges now method headers validators size
  | method /= "GET" || size<0 || not permitted = FullRepresentation
  | otherwise = case values "range" headers of
      [field] | B.length field<=8192 -> parseRanges size field
      _ -> FullRepresentation
  where
    permitted=case values "if-range" headers of
      [] -> True
      [value] -> case parseEntityTag value of
        Right tag -> maybe False (strongEqual tag) (currentTag validators)
        Left _ -> dateIsStrong validators && case parseHTTPDate now value of
          Just time -> modifiedAt validators == Just time
          Nothing -> False
      _ -> False

parseRanges :: Integer -> B.ByteString -> RangeSelection
parseRanges size raw = case C.break (=='=') (trim raw) of
  (unit,rest) | lower unit=="bytes" && not (B.null rest) ->
    let parts=C.split ',' (B.drop 1 rest)
    in if length parts>16 then RejectedRanges else
      case mapM parsePart (filter (not . B.null) (map trim parts)) of
        Nothing -> FullRepresentation
        Just [] -> FullRepresentation
        Just ranges -> let selected=normalize (mapMaybe id ranges)
                       in if null selected then
                            if size==0 && any nonzeroSuffix (map trim parts) then FullRepresentation else RejectedRanges
                          else PartialRepresentation selected
  _ -> FullRepresentation
  where
    nonzeroSuffix part=B.take 1 part=="-" && B.any (/=48) (B.drop 1 part)
    number bytes
      | B.null bytes || not (B.all (\c -> c>=48 && c<=57) bytes) = Nothing
      | otherwise = Just (B.foldl' (\n c -> min (size+1) (n*10+fromIntegral (c-48))) 0 bytes)
    parsePart part = case C.break (=='-') part of
      (first,rest) | not (B.null rest) -> do
        let last'=B.drop 1 rest
        if B.null first then do
          suffix <- number last'
          pure (if size==0 || suffix==0 then Nothing else Just (ByteRange (max 0 (size-suffix)) (min size suffix)))
        else do
          start <- number first
          end <- if B.null last' then Just (size-1) else do
            value <- number last'
            -- Compare arbitrary-width decimals before the bounded conversion.
            unless (decimalOrder first last' /= GT) Nothing
            pure (min (size-1) value)
          pure (if start>=size then Nothing else Just (ByteRange start (end-start+1)))
      _ -> Nothing
    decimalOrder a b=let x=B.dropWhile (==48) a; y=B.dropWhile (==48) b
                     in compare (B.length x,x) (B.length y,y)

-- Merge overlaps/adjacency before emitting a multipart body. Keep the order of
-- first appearances among disjoint groups and never duplicate representation bytes.
normalize :: [ByteRange] -> [ByteRange]
normalize ranges=map (\(_,start,end) -> ByteRange start (end-start+1)) (sortOn (\(i,_,_) -> i) merged)
  where
    ordered=sortOn (\(_,start,_) -> start) [(i,start,start+count-1) | (i,ByteRange start count)<-zip [0::Int ..] ranges]
    merged=reverse (foldl merge [] ordered)
    merge [] next=[next]
    merge ((i,start,end):rest) (j,next,last')
      | next<=end+1 = (min i j,start,max end last'):rest
      | otherwise = (j,next,last'):(i,start,end):rest

contentRange :: Integer -> ByteRange -> B.ByteString
contentRange size (ByteRange start count)="bytes "<>decimal start<>"-"<>decimal (start+count-1)<>"/"<>decimal size
decimal :: Integer -> B.ByteString
decimal=C.pack . show

-- Return validated per-part prefixes, closing delimiter and exact body length.
-- The caller streams range bytes and CRLF after every prefix/body pair.
multipartParts :: B.ByteString -> B.ByteString -> Integer -> [ByteRange]
               -> Either String ([(ByteRange,B.ByteString)],B.ByteString,Integer)
multipartParts boundary mediaType size ranges = do
  unless (not (B.null boundary) && B.length boundary<=70 && B.all safeBoundary boundary) (Left "invalid multipart boundary")
  unless (B.length mediaType<=8192 && B.all (\c -> c==9 || (c>=32 && c/=127)) mediaType) (Left "invalid multipart media type")
  unless (not (null ranges) && length ranges<=16 && all valid ranges) (Left "invalid multipart range")
  let parts=[(range,"--"<>boundary<>"\r\nContent-Type: "<>mediaType<>"\r\nContent-Range: "<>contentRange size range<>"\r\n\r\n") | range<-ranges]
      end="--"<>boundary<>"--\r\n"
      total=fromIntegral (B.length end)+sum [fromIntegral (B.length prefix)+rangeLength range+2 | (range,prefix)<-parts]
  pure (parts,end,total)
  where
    safeBoundary c=(c>=48 && c<=57)||(c>=65 && c<=90)||(c>=97 && c<=122)||c==45||c==95
    valid (ByteRange start count)=start>=0 && count>0 && start+count<=size
