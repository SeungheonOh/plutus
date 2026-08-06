{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module MatchingCpuRuntime.Matchers where

import Control.Monad (replicateM)
import Control.Monad.Except (runExcept)
import Data.Either (fromRight)
import Data.List (foldl')
import Data.Vector qualified as Vector
import PlutusCore (freshName, runQuote)
import PlutusCore qualified as PLC
import PlutusCore.Default
  ( DefaultBuiltinPattern (..)
  , DefaultPatternFieldEnd (DefaultPatternFieldsExact)
  )
import PlutusCore.MkPlc (mkConstant)
import UntypedPlutusCore qualified as UPLC

type Term = UPLC.Term PLC.NamedDeBruijn PLC.DefaultUni PLC.DefaultFun ()

matching_implementation :: String
matching_implementation = "nested"

type NamedTerm = UPLC.Term UPLC.Name PLC.DefaultUni PLC.DefaultFun ()

debruijnTermUnsafe
  :: UPLC.Term UPLC.Name uni fun ann
  -> UPLC.Term UPLC.NamedDeBruijn uni fun ann
debruijnTermUnsafe =
  fromRight (error "debruijnTermUnsafe")
    . runExcept @UPLC.FreeVariableError
    . UPLC.deBruijnTerm

capturedIntegerPattern :: Bool -> DefaultBuiltinPattern
capturedIntegerPattern shouldCapture =
  if shouldCapture
    then DefaultPatternDataI DefaultPatternCapture
    else DefaultPatternWildcard

constrNode
  :: Int
  -> Int
  -> (Int -> DefaultBuiltinPattern)
  -> [(Int, DefaultBuiltinPattern)]
  -> DefaultBuiltinPattern
constrNode width tag scalarPattern children =
  DefaultPatternDataConstr
    (fromIntegral tag)
    DefaultPatternFieldsExact
    $ Vector.generate width
    $ \fieldIndex ->
      case lookup fieldIndex children of
        Just child -> child
        Nothing -> scalarPattern fieldIndex

nestedMatcher :: Int -> DefaultBuiltinPattern -> Term
nestedMatcher captureCount patternRoot =
  nestedAlternativesMatcher [(patternRoot, captureCount)]

sumCapturedIntegers :: [UPLC.Name] -> NamedTerm
sumCapturedIntegers [] = mkConstant @Integer () 0
sumCapturedIntegers (firstCapture : laterCaptures) =
  foldl'
    ( \acc capture ->
        UPLC.Apply
          ()
          (UPLC.Apply () (UPLC.Builtin () PLC.AddInteger) acc)
          (UPLC.Var () capture)
    )
    (UPLC.Var () firstCapture)
    laterCaptures

nestedAlternativesMatcher :: [(DefaultBuiltinPattern, Int)] -> Term
nestedAlternativesMatcher alternatives =
  debruijnTermUnsafe $ runQuote $ do
    argument <- freshName "argument"
    branches <-
      traverse
        ( \(patternRoot, captureCount) -> do
            captures <- replicateM captureCount $ freshName "capture"
            let handler =
                  foldr
                    (UPLC.LamAbs ())
                    (sumCapturedIntegers captures)
                    captures
            pure (patternRoot, handler)
        )
        alternatives
    pure $
      UPLC.LamAbs () argument $
        UPLC.Match
          ()
          (UPLC.Var () argument)
          (Vector.fromList branches)

-- Sketch: _ = wildcard; I @ = captured integer; every Constr is exact.

-- Match: Constr 1 [I @] => 1.
match_benchmark_constr_flat_d1_w1_c1_nested :: Term
match_benchmark_constr_flat_d1_w1_c1_nested =
  nestedMatcher 1 $
    let captureValues :: [Integer]
        captureValues = [1]
        scalarPattern :: Int -> DefaultBuiltinPattern
        scalarPattern fieldIndex =
          capturedIntegerPattern $ toInteger (fieldIndex + 1) `elem` captureValues
        patternRoot = constrNode 1 1 scalarPattern []
     in patternRoot

-- Match: Constr 1 [I @, _, ..., I @, _, ..., I @, _, ..., I @] => 34.
match_benchmark_constr_flat_d1_w16_c4_nested :: Term
match_benchmark_constr_flat_d1_w16_c4_nested =
  nestedMatcher 4 $
    let captureValues :: [Integer]
        captureValues = [1, 6, 11, 16]
        scalarPattern :: Int -> DefaultBuiltinPattern
        scalarPattern fieldIndex =
          capturedIntegerPattern $ toInteger (fieldIndex + 1) `elem` captureValues
        patternRoot = constrNode 16 1 scalarPattern []
     in patternRoot

-- Match: Constr 1 [_, ..., I @, _, _, _] => 997.
match_benchmark_constr_flat_d1_w1000_c1_nested :: Term
match_benchmark_constr_flat_d1_w1000_c1_nested =
  nestedMatcher 1 $
    let captureValues :: [Integer]
        captureValues = [997]
        scalarPattern :: Int -> DefaultBuiltinPattern
        scalarPattern fieldIndex =
          capturedIntegerPattern $ toInteger (fieldIndex + 1) `elem` captureValues
        patternRoot = constrNode 1000 1 scalarPattern []
     in patternRoot

-- Match: Constr 1 [...] with I @ at f[6,60,117,...,976,999] => 8452.
match_benchmark_constr_flat_d1_w1000_c16_nested :: Term
match_benchmark_constr_flat_d1_w1000_c16_nested =
  nestedMatcher 16 $
    let captureValues :: [Integer]
        captureValues = [7, 61, 118, 203, 277, 349, 412, 508, 577, 643, 711, 806, 872, 931, 977, 1000]
        scalarPattern :: Int -> DefaultBuiltinPattern
        scalarPattern fieldIndex =
          capturedIntegerPattern $ toInteger (fieldIndex + 1) `elem` captureValues
        patternRoot = constrNode 1000 1 scalarPattern []
     in patternRoot

-- Match: Constr 1 [Constr 2 [Constr 3 [Constr 4 [...],...],...],...];
--        captures I[2,15,21,28,40,47,51,62] => 266.
match_benchmark_constr_spine_front_d4_w16_c8_nested :: Term
match_benchmark_constr_spine_front_d4_w16_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [2, 15, 21, 28, 40, 47, 51, 62]
        childPositions :: [Int]
        childPositions = [0, 0, 0]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 16 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 16 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr 1 [...,Constr 2 [...,Constr 3 [...,Constr 4 [...],...],...],...];
--        captures I[2,15,21,28,40,47,51,62] => 266.
match_benchmark_constr_spine_middle_d4_w16_c8_nested :: Term
match_benchmark_constr_spine_middle_d4_w16_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [2, 15, 21, 28, 40, 47, 51, 62]
        childPositions :: [Int]
        childPositions = [8, 8, 8]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 16 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 16 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr 1 [...,Constr 2 [...,Constr 3 [...,Constr 4 [...]]]];
--        captures I[2,15,21,28,40,47,51,62] => 266.
match_benchmark_constr_spine_last_d4_w16_c8_nested :: Term
match_benchmark_constr_spine_last_d4_w16_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [2, 15, 21, 28, 40, 47, 51, 62]
        childPositions :: [Int]
        childPositions = [15, 15, 15]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 16 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 16 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr 1 [...,Constr 2 [...,Constr 3 [...,Constr 4 [...],...],...],...];
--        captures I[2,15,21,28,40,47,51,62] => 266.
match_benchmark_constr_spine_irregular_d4_w16_c8_nested :: Term
match_benchmark_constr_spine_irregular_d4_w16_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [2, 15, 21, 28, 40, 47, 51, 62]
        childPositions :: [Int]
        childPositions = [3, 12, 5]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 16 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 16 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr 1 [Constr 2 [...Constr 3 [...Constr 4 [...Constr 5
--        [...Constr 6 [...Constr 7 [...Constr 8 [...]]]]]]],...]; captures I[4,12,...,52,61] => 257.
match_benchmark_constr_spine_irregular_d8_w8_c8_nested :: Term
match_benchmark_constr_spine_irregular_d8_w8_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [4, 12, 20, 28, 36, 44, 52, 61]
        childPositions :: [Int]
        childPositions = [0, 4, 7, 2, 6, 1, 5]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 8 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr n [Constr (n+1) [...], _/I @] (n=1..63);
--        Constr 64 [_,I @]; I @ at n=[1,10,19,28,37,46,55,64] => 520.
match_benchmark_constr_spine_front_d64_w2_c8_nested :: Term
match_benchmark_constr_spine_front_d64_w2_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [2, 20, 38, 56, 74, 92, 110, 128]
        childPositions :: [Int]
        childPositions = replicate 63 0

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 2 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 2 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr n [Constr (n+1) [...], _/I @] / Constr n [_/I @, Constr (n+1) [...]];
--        Constr 100 [I @,_]; I @ at n=[1,12,23,...,89,100] => 1005.
match_benchmark_constr_spine_zigzag_d100_w2_c10_nested :: Term
match_benchmark_constr_spine_zigzag_d100_w2_c10_nested =
  nestedMatcher 10 $
    let captureValues :: [Integer]
        captureValues = [2, 23, 46, 67, 90, 111, 134, 155, 178, 199]
        childPositions :: [Int]
        childPositions = [if odd nodeId then 0 else 1 | nodeId <- [1 :: Int .. 99]]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 2 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 2 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: Constr 1 [Constr 2 [Constr 3 [...],...,Constr 4 [...]],...,
--        Constr 5 [Constr 6 [...],...,Constr 7 [...]]]; captures I[7,21,...,105,112] => 504.
match_benchmark_constr_binary_d3_w16_c8_nested :: Term
match_benchmark_constr_binary_d3_w16_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [7, 21, 40, 59, 72, 88, 105, 112]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 16 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 16 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(0, node2), (15, node5)]
        node2 = patternNode 2 [(0, node3), (15, node4)]
        node3 = patternNode 3 []
        node4 = patternNode 4 []
        node5 = patternNode 5 [(0, node6), (15, node7)]
        node6 = patternNode 6 []
        node7 = patternNode 7 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [Constr 2 [_,_,Constr 3 [...],_,_,Constr 66 [...],_,_],
--        _,_,_,_,_,_,Constr 129 [...]]; leaf tags [8,15,...,244,251] have f3=I @ => 33024.
match_benchmark_constr_binary_stress_d8_w8_c32_nested :: Term
match_benchmark_constr_binary_stress_d8_w8_c32_nested =
  nestedMatcher 32 $
    let captureNodeIds :: [Int]
        captureNodeIds =
          [ 8
          , 15
          , 23
          , 30
          , 39
          , 46
          , 54
          , 61
          , 71
          , 78
          , 86
          , 93
          , 102
          , 109
          , 117
          , 124
          , 135
          , 142
          , 150
          , 157
          , 166
          , 173
          , 181
          , 188
          , 198
          , 205
          , 213
          , 220
          , 229
          , 236
          , 244
          , 251
          ]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ nodeId `elem` captureNodeIds && fieldIndex == 3

        go :: Int -> Int -> Int -> DefaultBuiltinPattern
        go level height nodeId =
          constrNode 8 nodeId (scalarPattern nodeId) $
            if height == 1
              then []
              else
                let (leftField, rightField) =
                      if odd level then (0, 7) else (2, 5)
                 in [ (leftField, go (level + 1) (height - 1) (nodeId + 1))
                    , (rightField, go (level + 1) (height - 1) (nodeId + 2 ^ (height - 1)))
                    ]

        patternRoot = go 1 8 1
     in patternRoot

-- Match: Constr 1 [Constr 2 [Constr 3 [...],...,Constr 4 [...],...,Constr 5 [...]],...,
--        Constr 6 [Constr 7 [...],...,Constr 8 [...],...,Constr 9 [...]],...,Constr 10 [...]];
--        captures I[4,18,...,94,104] => 556.
match_benchmark_constr_ternary_d3_w8_c10_nested :: Term
match_benchmark_constr_ternary_d3_w8_c10_nested =
  nestedMatcher 10 $
    let captureValues :: [Integer]
        captureValues = [4, 18, 30, 40, 52, 61, 71, 82, 94, 104]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 8 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(0, node2), (4, node6), (7, node10)]
        node2 = patternNode 2 [(0, node3), (4, node4), (7, node5)]
        node3 = patternNode 3 []
        node4 = patternNode 4 []
        node5 = patternNode 5 []
        node6 = patternNode 6 [(0, node7), (4, node8), (7, node9)]
        node7 = patternNode 7 []
        node8 = patternNode 8 []
        node9 = patternNode 9 []
        node10 = patternNode 10 [(0, node11), (4, node12), (7, node13)]
        node11 = patternNode 11 []
        node12 = patternNode 12 []
        node13 = patternNode 13 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [Constr 2 [...],I @,Constr 7 [...],_,_,
--        Constr 12 [...],_,Constr 17 [...]];
--        captures I[2,10,...,157,168] => 1485.
match_benchmark_constr_quaternary_d3_w8_c17_nested :: Term
match_benchmark_constr_quaternary_d3_w8_c17_nested =
  nestedMatcher 17 $
    let captureValues :: [Integer]
        captureValues = [2, 10, 20, 31, 52, 58, 71, 77, 92, 98, 111, 117, 130, 140, 151, 157, 168]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 8 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(0, node2), (2, node7), (5, node12), (7, node17)]
        node2 = patternNode 2 [(0, node3), (2, node4), (5, node5), (7, node6)]
        node3 = patternNode 3 []
        node4 = patternNode 4 []
        node5 = patternNode 5 []
        node6 = patternNode 6 []
        node7 = patternNode 7 [(0, node8), (2, node9), (5, node10), (7, node11)]
        node8 = patternNode 8 []
        node9 = patternNode 9 []
        node10 = patternNode 10 []
        node11 = patternNode 11 []
        node12 = patternNode 12 [(0, node13), (2, node14), (5, node15), (7, node16)]
        node13 = patternNode 13 []
        node14 = patternNode 14 []
        node15 = patternNode 15 []
        node16 = patternNode 16 []
        node17 = patternNode 17 [(0, node18), (2, node19), (5, node20), (7, node21)]
        node18 = patternNode 18 []
        node19 = patternNode 19 []
        node20 = patternNode 20 []
        node21 = patternNode 21 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [I @,_,Constr 2 [Constr 3 [...Constr 4 [...Constr 5
--        [...Constr 6 [...]]]]],...,Constr 7 [...Constr 8 [...Constr 9 [...]]],_];
--        captures I[1,14,27,40,54,71,74,108] => 389.
match_benchmark_constr_rootfork2_d6_w12_c8_nested :: Term
match_benchmark_constr_rootfork2_d6_w12_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [1, 14, 27, 40, 54, 71, 74, 108]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 12 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 12 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(2, node2), (10, node7)]
        node2 = patternNode 2 [(0, node3)]
        node3 = patternNode 3 [(7, node4)]
        node4 = patternNode 4 [(11, node5)]
        node5 = patternNode 5 [(4, node6)]
        node6 = patternNode 6 []
        node7 = patternNode 7 [(9, node8)]
        node8 = patternNode 8 [(1, node9)]
        node9 = patternNode 9 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [Constr 2 [...Constr 3 [...Constr 4 [...Constr 5 [...]]]],...,
--        Constr 6 [...Constr 7 [...Constr 8 [...]]],...,Constr 9 [...Constr 10 [...]]];
--        captures I[5,11,27,50,52,68,74,83,99] => 469.
match_benchmark_constr_rootfork3_d5_w10_c9_nested :: Term
match_benchmark_constr_rootfork3_d5_w10_c9_nested =
  nestedMatcher 9 $
    let captureValues :: [Integer]
        captureValues = [5, 11, 27, 50, 52, 68, 74, 83, 99]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 10 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 10 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(0, node2), (5, node6), (9, node9)]
        node2 = patternNode 2 [(2, node3)]
        node3 = patternNode 3 [(8, node4)]
        node4 = patternNode 4 [(4, node5)]
        node5 = patternNode 5 []
        node6 = patternNode 6 [(7, node7)]
        node7 = patternNode 7 [(1, node8)]
        node8 = patternNode 8 []
        node9 = patternNode 9 [(5, node10)]
        node10 = patternNode 10 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [Constr 2 [...Constr 3 [...Constr 4 [...]]],_,
--        Constr 5 [...Constr 6 [...]],...,Constr 7 [...],_,Constr 8 [...]];
--        captures I[4,9,21,32,35,47,51,62] => 261.
match_benchmark_constr_rootfork4_d4_w8_c8_nested :: Term
match_benchmark_constr_rootfork4_d4_w8_c8_nested =
  nestedMatcher 8 $
    let captureValues :: [Integer]
        captureValues = [4, 9, 21, 32, 35, 47, 51, 62]
        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

        patternNode nodeId =
          constrNode 8 nodeId (scalarPattern nodeId)

        node1 = patternNode 1 [(0, node2), (2, node5), (5, node7), (7, node8)]
        node2 = patternNode 2 [(3, node3)]
        node3 = patternNode 3 [(7, node4)]
        node4 = patternNode 4 []
        node5 = patternNode 5 [(1, node6)]
        node6 = patternNode 6 []
        node7 = patternNode 7 []
        node8 = patternNode 8 []

        patternRoot = node1
     in patternRoot

-- Match: Constr 1 [Constr 2 [...Constr 3 [...Constr 4 [...Constr 5
--        [...Constr 6 [...Constr 7 [...Constr 8 [...Constr 9 [...Constr 10 [...]]]]]]]]],...];
--        f16/f82=I @ => 10000.
match_benchmark_constr_spine_stress_d10_w100_c20_nested :: Term
match_benchmark_constr_spine_stress_d10_w100_c20_nested =
  nestedMatcher 20 $
    let captureValues :: [Integer]
        captureValues =
          [17, 83, 117, 183, 217, 283, 317, 383, 417, 483, 517, 583, 617, 683, 717, 783, 817, 883, 917, 983]
        childPositions :: [Int]
        childPositions = [0, 50, 99, 20, 80, 10, 60, 30, 90]

        scalarPattern :: Int -> Int -> DefaultBuiltinPattern
        scalarPattern nodeId fieldIndex =
          capturedIntegerPattern $ toInteger ((nodeId - 1) * 100 + fieldIndex + 1) `elem` captureValues

        go :: Int -> [Int] -> DefaultBuiltinPattern
        go nodeId remainingPositions =
          constrNode 100 nodeId (scalarPattern nodeId) $
            case remainingPositions of
              childPosition : laterPositions ->
                [(childPosition, go (nodeId + 1) laterPositions)]
              [] -> []

        patternRoot = go 1 childPositions
     in patternRoot

-- Match: {Constr 1 [...,Constr 9 [...,Constr 10 [...],...,B @]]
--        | Constr 1 [...,Constr 9 [...,Constr 10 [...],...,I @]]}; => 469.
match_benchmark_constr_alt_rootfork3_d5_w10_c9_nested :: Term
match_benchmark_constr_alt_rootfork3_d5_w10_c9_nested =
  nestedAlternativesMatcher
    [ (patternRoot $ DefaultPatternDataB DefaultPatternCapture, 9)
    , (patternRoot $ DefaultPatternDataI DefaultPatternCapture, 9)
    ]
  where
    captureValues :: [Integer]
    captureValues = [11, 14, 27, 50, 52, 68, 74, 83, 90]

    scalarPattern :: DefaultBuiltinPattern -> Int -> Int -> DefaultBuiltinPattern
    scalarPattern finalCapture nodeId fieldIndex
      | nodeId == 9 && fieldIndex == 9 = finalCapture
      | otherwise =
          capturedIntegerPattern $
            toInteger ((nodeId - 1) * 10 + fieldIndex + 1) `elem` captureValues

    patternNode finalCapture nodeId =
      constrNode
        10
        nodeId
        (scalarPattern finalCapture nodeId)

    patternRoot :: DefaultBuiltinPattern -> DefaultBuiltinPattern
    patternRoot finalCapture = node1
      where
        node1 = patternNode finalCapture 1 [(0, node2), (5, node6), (9, node9)]
        node2 = patternNode finalCapture 2 [(2, node3)]
        node3 = patternNode finalCapture 3 [(8, node4)]
        node4 = patternNode finalCapture 4 [(4, node5)]
        node5 = patternNode finalCapture 5 []
        node6 = patternNode finalCapture 6 [(7, node7)]
        node7 = patternNode finalCapture 7 [(1, node8)]
        node8 = patternNode finalCapture 8 []
        node9 = patternNode finalCapture 9 [(5, node10)]
        node10 = patternNode finalCapture 10 []

-- Match: {Constr 1 [...,Constr 129 [...,B @]]
--        | Constr 1 [...,Constr 129 [...,I @]]}; => 33024.
match_benchmark_constr_alt_binary_d8_w8_c32_nested :: Term
match_benchmark_constr_alt_binary_d8_w8_c32_nested =
  nestedAlternativesMatcher
    [ (go (DefaultPatternDataB DefaultPatternCapture) 1 8 1, 32)
    , (go (DefaultPatternDataI DefaultPatternCapture) 1 8 1, 32)
    ]
  where
    captureValues :: [Integer]
    captureValues =
      [ 60
      , 116
      , 180
      , 236
      , 308
      , 364
      , 428
      , 484
      , 564
      , 620
      , 684
      , 740
      , 812
      , 868
      , 932
      , 1032
      , 1076
      , 1132
      , 1196
      , 1252
      , 1324
      , 1380
      , 1444
      , 1500
      , 1580
      , 1636
      , 1700
      , 1756
      , 1828
      , 1884
      , 1948
      , 1960
      ]

    scalarPattern :: DefaultBuiltinPattern -> Int -> Int -> DefaultBuiltinPattern
    scalarPattern finalCapture nodeId fieldIndex
      | nodeId == 129 && fieldIndex == 7 = finalCapture
      | otherwise =
          capturedIntegerPattern $
            toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

    go :: DefaultBuiltinPattern -> Int -> Int -> Int -> DefaultBuiltinPattern
    go finalCapture level height nodeId =
      constrNode
        8
        nodeId
        (scalarPattern finalCapture nodeId)
        $ if height == 1
          then []
          else
            let (leftField, rightField) =
                  if odd level then (0, 7) else (2, 5)
             in [ (leftField, go finalCapture (level + 1) (height - 1) (nodeId + 1))
                ,
                  ( rightField
                  , go
                      finalCapture
                      (level + 1)
                      (height - 1)
                      (nodeId + 2 ^ (height - 1))
                  )
                ]

-- Match: {Constr 1 [Constr 2 [...],_,_,_,_,_,_,B @]
--        | Constr 1 [Constr 2 [...],_,_,_,_,_,_,I @]}; => 544.
match_benchmark_constr_alt_spine_d16_w8_c8_nested :: Term
match_benchmark_constr_alt_spine_d16_w8_c8_nested =
  nestedAlternativesMatcher
    [ (go (DefaultPatternDataB DefaultPatternCapture) 1 childPositions, 8)
    , (go (DefaultPatternDataI DefaultPatternCapture) 1 childPositions, 8)
    ]
  where
    captureValues :: [Integer]
    captureValues = [8, 28, 44, 60, 76, 92, 108, 128]

    childPositions :: [Int]
    childPositions = [0, 7, 2, 5, 0, 7, 2, 5, 0, 7, 2, 5, 0, 7, 2]

    scalarPattern :: DefaultBuiltinPattern -> Int -> Int -> DefaultBuiltinPattern
    scalarPattern finalCapture nodeId fieldIndex
      | nodeId == 1 && fieldIndex == 7 = finalCapture
      | otherwise =
          capturedIntegerPattern $
            toInteger ((nodeId - 1) * 8 + fieldIndex + 1) `elem` captureValues

    go :: DefaultBuiltinPattern -> Int -> [Int] -> DefaultBuiltinPattern
    go finalCapture nodeId remainingPositions =
      constrNode
        8
        nodeId
        (scalarPattern finalCapture nodeId)
        $ case remainingPositions of
          childPosition : laterPositions ->
            [(childPosition, go finalCapture (nodeId + 1) laterPositions)]
          [] -> []
