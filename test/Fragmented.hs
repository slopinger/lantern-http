{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Exception (evaluate)
import Control.Monad (replicateM_,unless)
import qualified Data.ByteString as B
import Data.IORef
import GHC.Stats
import Lantern.HTTP
import System.CPUTime (getCPUTime)
import System.Mem (performGC)

-- Deterministic parser work, not a network or server throughput benchmark.
main :: IO ()
main = do
  enabled <- getRTSStatsEnabled
  unless enabled (fail "run with +RTS -T")
  let wire = "GET /" <> B.replicate 8100 97 <> " HTTP/1.1\r\nHost: localhost\r\n\r\n"
  _ <- evaluate (B.length wire)
  mapM_ (profile wire) [(1,100),(128,1000),(16384,10000)]

profile :: B.ByteString -> (Int,Int) -> IO ()
profile wire (width,count) = do
  let fragments = split wire
      split bytes | B.null bytes = []
                  | otherwise = let (front,rest)=B.splitAt width bytes in front:split rest
  _ <- evaluate (sum (map B.length fragments))
  performGC
  before <- getRTSStats
  start <- getCPUTime
  replicateM_ count $ do
    source <- newIORef fragments
    reader <- newReader (atomicModifyIORef' source (\xs -> case xs of [] -> ([],B.empty); x:rest -> (rest,x)))
    request <- readRequest reader
    unless (B.length (reqTarget request)==8101 && reqFraming request==NoBody) (fail "incorrect parsed request")
    exhausted <- readIORef source
    unless (null exhausted) (fail "unconsumed fragments")
  performGC
  end <- getCPUTime
  after <- getRTSStats
  putStrLn ("width="++show width++" requests="++show count++
    " wire_bytes="++show (B.length wire)++" allocated_bytes="++show (allocated_bytes after-allocated_bytes before)++
    " cpu_seconds="++show (fromIntegral (end-start)/1e12 :: Double))
