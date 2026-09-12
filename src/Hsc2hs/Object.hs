-- SPDX-License-Identifier: Unlicense
-- Container parsing is independent of the host ABI and never executes code.
module Hsc2hs.Object (decodeAnswers, Answer(..)) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Data.Bits (shiftL)
import Control.Monad (unless, when, forM)

data Answer = Answer { answerKind :: Int, answerValue :: Integer }
  deriving (Eq, Show)

type Result a = Either String a

slice :: B.ByteString -> Integer -> Integer -> Result B.ByteString
slice b off len
  | off < 0 || len < 0 || off + len > toInteger (B.length b) = Left "truncated object or invalid section bounds"
  | otherwise = Right (B.take (fromInteger len) (B.drop (fromInteger off) b))

number :: B.ByteString -> Bool -> Integer -> Integer -> Result Integer
number b little off len = do
  bytes <- B.unpack <$> slice b off len
  pure (foldl (\n v -> n * 256 + toInteger v) 0 (if little then reverse bytes else bytes))

name :: B.ByteString -> Integer -> Integer -> Result String
name b off len = map (toEnum . fromEnum) . B.unpack . B.takeWhile (/= 0) <$> slice b off len

-- Find only named sections; magic bytes elsewhere are never considered answers.
sections :: B.ByteString -> Result [B.ByteString]
sections b
  | B.take 4 b == B.pack [127,69,76,70] = elf
  | B.take 4 b == B.pack [207,250,237,254] = macho True True
  | B.take 4 b == B.pack [206,250,237,254] = macho True False
  | B.take 4 b == B.pack [254,237,250,207] = macho False True
  | B.take 4 b == B.pack [254,237,250,206] = macho False False
  | B.take 2 b `elem` map B.pack [[100,134],[76,1],[100,170]] = coff
  | otherwise = Left "unsupported object format (MVP supports ELF, Mach-O and COFF)"
  where
    elf = do
      cls <- number b True 4 1
      endian <- number b True 5 1
      unless (cls `elem` [1,2] && endian `elem` [1,2]) (Left "invalid ELF class or byte order")
      let wide = cls == 2; n = number b (endian == 1)
          word = if wide then 8 else 4
      typ <- n 16 2
      unless (typ == 1) (Left "expected relocatable ELF object")
      start <- n (if wide then 40 else 32) word
      stride <- n (if wide then 58 else 46) 2
      count <- n (if wide then 60 else 48) 2
      names <- n (if wide then 62 else 50) 2
      unless (stride >= (if wide then 64 else 40) && count > 0 && names < count) (Left "unsupported ELF section table")
      _ <- slice b start (stride * count)
      let at i = start + i * stride
          contents i = do
            off <- n (at i + if wide then 24 else 16) word
            len <- n (at i + if wide then 32 else 20) word
            slice b off len
      strings <- contents names
      found <- forM [0..count-1] $ \i -> do
        ni <- n (at i) 4
        nm <- name strings ni (toInteger (B.length strings) - ni)
        if nm /= "aihc_ans" then pure [] else do
          sectionType <- n (at i + 4) 4
          unless (sectionType == 1) (Left "answer section must contain file-backed data")
          mapM_ (\j -> do
            t <- n (at j + 4) 4
            info <- n (at j + if wide then 44 else 28) 4
            len <- n (at j + if wide then 32 else 20) word
            when (t `elem` [4,9] && info == i && len /= 0) (Left "relocations in answer section")) [0..count-1]
          (:[]) <$> contents i
      pure (concat found)
    macho little wide = do
      let n = number b little
      typ <- n 12 4
      unless (typ == 1) (Left "expected relocatable Mach-O object")
      count <- n 16 4
      commandBytes <- n 20 4
      let start = if wide then 32 else 28
      _ <- slice b start commandBytes
      let go 0 pos = if pos == start + commandBytes then pure [] else Left "invalid Mach-O command size"
          go remaining pos = do
            cmd <- n pos 4
            len <- n (pos+4) 4
            unless (len >= 8 && pos + len <= start + commandBytes) (Left "invalid Mach-O load command")
            here <- if cmd /= (if wide then 25 else 1) then pure [] else do
              ns <- n (pos + if wide then 64 else 48) 4
              let base = pos + if wide then 72 else 56
                  stride = if wide then 80 else 68
              unless (base + ns * stride <= pos + len) (Left "invalid Mach-O section table")
              fmap concat $ forM [0..ns-1] $ \i -> do
                let s = base+i*stride
                nm <- name b s 16
                if nm /= "__aihc_ans" then pure [] else do
                  lenS <- n (s + if wide then 40 else 36) (if wide then 8 else 4)
                  off <- n (s + if wide then 48 else 40) 4
                  rel <- n (s + if wide then 60 else 52) 4
                  flags <- n (s + if wide then 64 else 56) 4
                  unless (rel == 0 && flags `mod` 256 == 0) (Left "relocated or non-data Mach-O answer section")
                  (:[]) <$> slice b off lenS
            rest <- go (remaining-1) (pos+len)
            pure (here ++ rest)
      go count start
    coff = do
      count <- number b True 2 2
      optional <- number b True 16 2
      unless (optional == 0) (Left "expected relocatable COFF object")
      _ <- slice b 20 (count*40)
      fmap concat $ forM [0..count-1] $ \i -> do
        let s = 20+i*40; n = number b True
        nm <- name b s 8
        if nm /= "aihc_ans" then pure [] else do
          len <- n (s+16) 4
          off <- n (s+20) 4
          rel <- n (s+32) 2
          unless (rel == 0) (Left "relocations in answer section")
          (:[]) <$> slice b off len

decodeAnswers :: B.ByteString -> Result (M.Map Int Answer)
decodeAnswers object = do
  payloads <- sections object
  records <- case payloads of
    [payload] -> parse payload
    _ -> Left "expected exactly one answer section"
  let answers = M.fromList records
  unless (M.size answers == length records) (Left "duplicate answer ID")
  pure answers
  where
    parse b
      | B.null b = pure []
      | otherwise = do
          record <- slice b 0 24
          unless (B.take 4 record == B.pack [72,83,67,1]) (Left "invalid answer magic/version")
          ident <- number record True 4 4
          kind <- number record True 8 1
          negative <- number record True 9 1
          reserved <- number record True 10 6
          unless (kind <= 1 && negative <= 1 && reserved == 0) (Left "invalid answer record")
          value <- number record True 16 8
          let signed = if negative == 1 then value - (1 `shiftL` 64) else value
          when (kind == 0 && (negative /= 0 || value /= 0)) (Left "invalid presence record")
          rest <- parse (B.drop 24 b)
          pure ((fromInteger ident, Answer (fromInteger kind) signed):rest)
