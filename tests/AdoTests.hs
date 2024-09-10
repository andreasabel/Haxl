{-
  Copyright (c) Meta Platforms, Inc. and affiliates.
  All rights reserved.

  This source code is licensed under the BSD-style license found in the
  LICENSE file in the root directory of this source tree.
-}

{-# LANGUAGE RebindableSyntax, OverloadedStrings, ApplicativeDo #-}
module AdoTests (tests) where

import TestUtils
import MockTAO

import Control.Applicative
import Test.HUnit

import Prelude()
import Haxl.Prelude

-- -----------------------------------------------------------------------------

--
-- Test ApplicativeDo batching
--
ado1 = expectResult 12 ado1_

ado1_ = do
  a <- friendsOf =<< id1
  b <- friendsOf =<< id2
  return (length (a ++ b))

ado2 = expectResult 12 ado2_

ado2_ = do
  x <- id1
  a <- friendsOf x
  y <- id2
  b <- friendsOf y
  return (length (a ++ b))

ado3 = expectResult 11 ado3_

ado3_ = do
  x <- id1
  a <- friendsOf x
  a' <- friendsOf =<< if null a then id3 else id4
  y <- id2
  b <- friendsOf y
  b' <- friendsOf  =<< if null b then id4 else id3
  return (length (a' ++ b'))

tests future = TestList
  [ TestLabel "ado1" $ TestCase (ado1 future)
  , TestLabel "ado2" $ TestCase (ado2 future)
  , TestLabel "ado3" $ TestCase (ado3 future)
  ]
