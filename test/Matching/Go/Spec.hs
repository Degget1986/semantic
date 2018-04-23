{-# LANGUAGE TypeOperators #-}

module Matching.Go.Spec (spec) where

import           Control.Abstract.Matching
import           Data.Abstract.Module
import           Data.List
import qualified Data.Syntax.Declaration as Decl
import qualified Data.Syntax.Literal as Lit
import qualified Data.Syntax.Statement as Stmt
import           Data.Union
import           SpecHelpers

-- This gets the ByteString contents of all integers
integerMatcher :: (Lit.Integer :< fs) => Matcher (Term (Union fs) ann) ByteString
integerMatcher = match Lit.integerContent target

-- This matches all for-loops with its index variable new variable bound to 0,
-- e.g. `for i := 0; i < 10; i++`
loopMatcher :: ( Stmt.For :< fs
               , Stmt.Assignment :< fs
               , Lit.Integer :< fs)
            => TermMatcher fs ann
loopMatcher = target <* go where
  go = match Stmt.forBefore $
         match Stmt.assignmentValue $
            match Lit.integerContent $
               ensure (== "0")

spec :: Spec
spec = describe "matching/go" $ do
  it "extracts integers" $ do
    parsed <- parseFile goParser "test/fixtures/go/matching/integers.go"
    let matched = runMatcher integerMatcher parsed
    sort matched `shouldBe` ["1", "2", "3"]

  it "counts for loops" $ do
    parsed <- parseFile goParser "test/fixtures/go/matching/for.go"
    let matched = runMatcher @[] loopMatcher parsed
    length matched `shouldBe` 2
