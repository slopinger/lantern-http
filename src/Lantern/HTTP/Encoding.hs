{-# LANGUAGE OverloadedStrings #-}
-- Content-coding negotiation; compression itself belongs to the file publisher.
module Lantern.HTTP.Encoding (encodingPreferences) where
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (nub, sortOn)
import Lantern.HTTP (Headers, values, lower, trim, validToken)

-- | Rank supported encodings by qvalue, preserving server order on ties.
-- Identity is a fallback unless explicitly weighted. With no field all offered
-- encodings are acceptable; an empty field permits only identity. Max 128 items;
-- malformed/duplicate entries fail rather than guessing at an exclusion.
encodingPreferences :: [B.ByteString] -> Headers -> Either String [B.ByteString]
encodingPreferences offered headers = do
  let fields = values "accept-encoding" headers
      pieces = filter (not . B.null) (map trim (concatMap (C.split ',') fields))
  when (length (take 129 pieces) > 128) (Left "too many encoding preferences")
  parsed <- mapM entry pieces
  when (length (nub (map fst parsed)) /= length parsed) (Left "duplicate encoding preference")
  let quality coding
        | null fields = 1000
        | Just q <- lookup coding parsed = q
        | coding == "identity" = if lookup "*" parsed == Just 0 then 0 else 1
        | otherwise = maybe 0 id (lookup "*" parsed)
  pure (filter ((>0) . quality) (sortOn (negate . quality) offered))
  where
    entry bytes = case map trim (C.split ';' bytes) of
      [coding] -> pair coding 1000
      [coding,parameter] | "q=" `B.isPrefixOf` lower parameter -> do
        q <- weight (B.drop 2 parameter)
        pair coding q
      _ -> Left "invalid encoding preference"
    pair coding q = do
      unless (validToken coding) (Left "invalid encoding token")
      pure (lower coding,q)
    weight bytes = case B.uncons bytes of
      Just (whole,rest) | whole == 48 || whole == 49 ->
        if B.null rest then Right (if whole==49 then 1000 else 0) else
          case B.uncons rest of
            Just (46,fraction) | B.length fraction <= 3 && B.all digit fraction &&
                                (whole==48 || B.all (==48) fraction) ->
              Right (if whole==49 then 1000 else B.foldl' (\n c -> n*10+fromIntegral (c-48)) 0 fraction * 10^(3-B.length fraction))
            _ -> Left "invalid encoding weight"
      _ -> Left "invalid encoding weight"
    digit c = c>=48 && c<=57
