{-# LANGUAGE RankNTypes, ScopedTypeVariables #-}
module Rendering.TOC
( renderToCDiff
, renderRPCToCDiff
, renderToCTerm
, diffTOC
, Summaries(..)
, TOCSummary(..)
, isValidSummary
, declaration
, Entry(..)
, tableOfContentsBy
, termTableOfContentsBy
, dedupe
, entrySummary
, toCategoryName
) where

import Prologue
import Analysis.Declaration
import Data.Align (bicrosswalk)
import Data.Aeson
import Data.Blob
import Data.Diff
import Data.Language as Language
import Data.List (sortOn)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Patch
import Data.Location
import Data.Term
import qualified Data.Text as T

data Summaries = Summaries { changes, errors :: !(Map.Map T.Text [Value]) }
  deriving (Eq, Show)

instance Semigroup Summaries where
  (<>) (Summaries c1 e1) (Summaries c2 e2) = Summaries (Map.unionWith (<>) c1 c2) (Map.unionWith (<>) e1 e2)

instance Monoid Summaries where
  mempty = Summaries mempty mempty
  mappend = (<>)

instance ToJSON Summaries where
  toJSON Summaries{..} = object [ "changes" .= changes, "errors" .= errors ]


data TOCSummary
  = TOCSummary
    { summaryCategoryName :: T.Text
    , summaryTermName :: T.Text
    , summarySpan :: Span
    , summaryChangeType :: T.Text
    }
  | ErrorSummary { errorText :: T.Text, errorSpan :: Span, errorLanguage :: Language }
  deriving (Generic, Eq, Show)

instance ToJSON TOCSummary where
  toJSON TOCSummary{..} = object [ "changeType" .= summaryChangeType, "category" .= summaryCategoryName, "term" .= summaryTermName, "span" .= summarySpan ]
  toJSON ErrorSummary{..} = object [ "error" .= errorText, "span" .= errorSpan, "language" .= errorLanguage ]

isValidSummary :: TOCSummary -> Bool
isValidSummary ErrorSummary{} = False
isValidSummary _ = True

-- | Produce the annotations of nodes representing declarations.
declaration :: TermF f (Maybe Declaration) a -> Maybe Declaration
declaration (In annotation _) = annotation


-- | An entry in a table of contents.
data Entry a
  = Changed   { entryPayload :: a } -- ^ An entry for a node containing changes.
  | Inserted  { entryPayload :: a } -- ^ An entry for a change occurring inside an 'Insert' 'Patch'.
  | Deleted   { entryPayload :: a } -- ^ An entry for a change occurring inside a 'Delete' 'Patch'.
  | Replaced  { entryPayload :: a } -- ^ An entry for a change occurring on the insertion side of a 'Replace' 'Patch'.
  deriving (Eq, Show)


-- | Compute a table of contents for a diff characterized by a function mapping relevant nodes onto values in Maybe.
tableOfContentsBy :: (Foldable f, Functor f)
                  => (forall b. TermF f ann b -> Maybe a) -- ^ A function mapping relevant nodes onto values in Maybe.
                  -> Diff f ann ann                       -- ^ The diff to compute the table of contents for.
                  -> [Entry a]                            -- ^ A list of entries for relevant changed nodes in the diff.
tableOfContentsBy selector = cata diffAlgebra
  where diffAlgebra diff = case diff of
          (Patch patch) -> maybeToList (patchEntry <$> bicrosswalk selector selector patch) <> bifoldMap fold fold patch
          (Merge (In (_, ann) r)) -> maybeToList (Changed <$> selector (In ann r)) <> fold r
        patchEntry = patch Deleted Inserted (const Replaced)

termTableOfContentsBy :: (Foldable f, Functor f)
                      => (forall b. TermF f annotation b -> Maybe a)
                      -> Term f annotation
                      -> [a]
termTableOfContentsBy selector = cata termAlgebra
  where termAlgebra r = maybeToList (selector r) <> fold r

newtype DedupeKey = DedupeKey (T.Text, T.Text) deriving (Eq, Ord)

-- Dedupe entries in a final pass. This catches two specific scenarios with
-- different behaviors:
-- 1. Identical entries are in the list.
--    Action: take the first one, drop all subsequent.
-- 2. Two similar entries (defined by a case insensitive comparision of their
--    identifiers) are in the list.
--    Action: Combine them into a single Replaced entry.
dedupe :: [Entry Declaration] -> [Entry Declaration]
dedupe = let tuples = sortOn fst . Map.elems . snd . foldl' go (0, Map.empty) in (fmap . fmap) snd tuples
  where
    go :: (Int, Map.Map DedupeKey (Int, Entry Declaration))
       -> Entry Declaration
       -> (Int, Map.Map DedupeKey (Int, Entry Declaration))
    go (index, m) x | Just (_, similar) <- Map.lookup (dedupeKey x) m
                    = if exactMatch similar x
                      then (succ index, m)
                      else
                        let replacement = Replaced (entryPayload similar)
                        in (succ index, Map.insert (dedupeKey replacement) (index, replacement) m)
                    | otherwise = (succ index, Map.insert (dedupeKey x) (index, x) m)

    dedupeKey entry = DedupeKey (toCategoryName (entryPayload entry), T.toLower (declarationIdentifier (entryPayload entry)))
    exactMatch = (==) `on` entryPayload

-- | Construct a 'TOCSummary' from an 'Entry'.
entrySummary :: Entry Declaration -> TOCSummary
entrySummary entry = case entry of
  Changed  a -> recordSummary "modified" a
  Deleted  a -> recordSummary "removed" a
  Inserted a -> recordSummary "added" a
  Replaced a -> recordSummary "modified" a

-- | Construct a 'TOCSummary' from a node annotation and a change type label.
recordSummary :: T.Text -> Declaration -> TOCSummary
recordSummary changeText record = case record of
  (ErrorDeclaration text _ srcSpan language) -> ErrorSummary text srcSpan language
  decl-> TOCSummary (toCategoryName decl) (formatIdentifier decl) (declarationSpan decl) changeText
  where
    formatIdentifier (MethodDeclaration identifier _ _ Language.Go (Just receiver)) = "(" <> receiver <> ") " <> identifier
    formatIdentifier (MethodDeclaration identifier _ _ _           (Just receiver)) = receiver <> "." <> identifier
    formatIdentifier decl = declarationIdentifier decl

renderToCDiff :: (Foldable f, Functor f) => BlobPair -> Diff f (Maybe Declaration) (Maybe Declaration) -> Summaries
renderToCDiff blobs = uncurry Summaries . bimap toMap toMap . List.partition isValidSummary . diffTOC
  where toMap [] = mempty
        toMap as = Map.singleton summaryKey (toJSON <$> as)
        summaryKey = T.pack $ pathKeyForBlobPair blobs

renderRPCToCDiff :: (Foldable f, Functor f) => BlobPair -> Diff f (Maybe Declaration) (Maybe Declaration) -> ([TOCSummary], [TOCSummary])
renderRPCToCDiff _ = List.partition isValidSummary . diffTOC

diffTOC :: (Foldable f, Functor f) => Diff f (Maybe Declaration) (Maybe Declaration) -> [TOCSummary]
diffTOC = fmap entrySummary . dedupe . filter extraDeclarations . tableOfContentsBy declaration
  where
    extraDeclarations :: Entry Declaration -> Bool
    extraDeclarations entry = case entryPayload entry of
      ImportDeclaration{..} -> False
      CallReference{..} -> False
      _ -> True

renderToCTerm :: (Foldable f, Functor f) => Blob -> Term f (Maybe Declaration) -> Summaries
renderToCTerm Blob{..} = uncurry Summaries . bimap toMap toMap . List.partition isValidSummary . termToC
  where
    toMap [] = mempty
    toMap as = Map.singleton (T.pack blobPath) (toJSON <$> as)

    termToC :: (Foldable f, Functor f) => Term f (Maybe Declaration) -> [TOCSummary]
    termToC = fmap (recordSummary "unchanged") . termTableOfContentsBy declaration

-- The user-facing category name
toCategoryName :: Declaration -> T.Text
toCategoryName declaration = case declaration of
  ClassDeclaration{} -> "Class"
  ImportDeclaration{} -> "Import"
  FunctionDeclaration{} -> "Function"
  MethodDeclaration{} -> "Method"
  CallReference{} -> "Call"
  HeadingDeclaration _ _ _ _ l -> "Heading " <> T.pack (show l)
  ErrorDeclaration{} -> "ParseError"
