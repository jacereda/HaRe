{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

module Language.Haskell.Refact.Utils.DualTree (
    layoutTreeToSourceTree
  , renderSourceTree
  ) where

import qualified FastString as GHC
import qualified GHC        as GHC
import qualified Lexer      as GHC
import qualified Outputable as GHC

import qualified GHC.SYB.Utils as SYB

import Control.Monad.State
import Data.List
import Data.Maybe
import qualified Data.Tree as T

import Language.Haskell.Refact.Utils.GhcBugWorkArounds
import Language.Haskell.Refact.Utils.GhcVersionSpecific
import Language.Haskell.Refact.Utils.Layout
import Language.Haskell.Refact.Utils.LayoutTypes
import Language.Haskell.Refact.Utils.LocUtils
import Language.Haskell.Refact.Utils.Monad
import Language.Haskell.Refact.Utils.TokenUtils
import Language.Haskell.Refact.Utils.TokenUtilsTypes
import Language.Haskell.Refact.Utils.TypeSyn
import Language.Haskell.Refact.Utils.TypeUtils

-- ----------
import Data.Tree.DUAL
import Data.Semigroup
import Data.Monoid.Action
import qualified Data.List.NonEmpty as NE
import qualified Data.Tree.DUAL.Internal as I

-- ---------------------------------------------------------------------

data DeletedSpan = DeletedSpan Span RowOffset SimpPos
              deriving (Show,Eq)

-- TODO: We are not actually using any of these
data Transformation = AsIs
                    | T Integer
                    | TAbove EndOffset (Row,Col) (Row,Col) EndOffset
                    | TDeleted ForestSpan RowOffset SimpPos
                    | TAdded
                    deriving Show

instance Num Transformation where
  fromInteger n = T n


transform :: Transformation -> Prim -> Prim
transform AsIs p = p
-- transform (T n) (PToks s) = (PToks (s++"(T"++ (show n) ++")"))
transform (T n) (PToks s) = (PToks s)
transform (TAbove bo p1 p2 eo) (PToks s)  = (PToks s)
transform (TDeleted sspan ro p) (PToks s) = (PToks s)
transform TAdded                (PToks s) = (PToks s)

-- | The value that bubbles up. This is the Span occupied by the
-- subtree, together with a string representation of the subtree. The
-- origin of the string is the start of the span.

data Up = Up Span (NE.NonEmpty Line) [DeletedSpan]
        | UDeleted [DeletedSpan]
        deriving Show

data Span = Span (Row,Col) (Row,Col)
          deriving (Show,Eq)

data Line = Line Row Col Source String
          deriving Show

data Source = SOriginal
            | SAdded
            deriving Show

data Annot = Ann String
           | ADeleted ForestSpan RowOffset SimpPos
           | ASubtree ForestSpan
           deriving Show

data Prim = PToks [PosToken]
          | PDeleted ForestSpan RowOffset SimpPos
          deriving Show


type SourceTree = DUALTree Transformation Up Annot Prim


instance Semigroup Span where
  (Span p1 _p2) <> (Span _q1 q2) = (Span p1 q2)

-- TODO: combine the strings according to the relative spans.
instance Semigroup Up where
  u1 <> u2 = combineUps u1 u2

instance Semigroup Transformation where
  (T n1) <> (T n2) = T (n1 + n2)

instance (Action Transformation Up) where
  act AsIs s = s
  act (T n)                 (Up span s ds) = (Up span s ds)
  act (TAbove bo p1 p2 eo)  (Up span s ds) = (Up span s ds)
  act (TDeleted sspan ro p) (Up span s ds) = (Up span s ds)
  act TAdded s = s

-- ---------------------------------------------------------------------

instance GHC.Outputable SourceTree where
  ppr (I.DUALTree ot)
      = case getOption ot of
             Nothing -> GHC.text "Nothing"
             Just t  -> GHC.ppr t

instance GHC.Outputable (I.DUALTreeU Transformation Up Annot Prim) where
  ppr (I.DUALTreeU (u,t)) = GHC.parens $ GHC.ppr u GHC.<> GHC.comma GHC.$$ GHC.ppr t

instance GHC.Outputable (I.DUALTreeNE Transformation Up Annot Prim) where
  ppr (I.Leaf u l)   = GHC.parens $ GHC.hang (GHC.text "Leaf")   1 (GHC.ppr u GHC.$$ GHC.ppr l)
  ppr (I.LeafU u)    = GHC.parens $ GHC.hang (GHC.text "LeafU")  1 (GHC.ppr u)
  ppr (I.Concat dts) = GHC.parens $ GHC.hang (GHC.text "Concat") 1 (GHC.ppr dts)
  ppr (I.Act d t)    = GHC.parens $ GHC.hang (GHC.text "Act")    1 (GHC.ppr d GHC.$$ GHC.ppr t)
  ppr (I.Annot a t)  = GHC.parens $ GHC.hang (GHC.text "Annot")  1 (GHC.ppr a GHC.$$ GHC.ppr t)

instance GHC.Outputable Prim where
  ppr (PToks toks) = GHC.parens $ GHC.text "PToks" GHC.<+> GHC.text (show toks)
  ppr (PDeleted ss pg p) = GHC.parens $ GHC.text "PDeleted" GHC.<+> GHC.ppr ss
                               GHC.<+> GHC.ppr pg GHC.<+> GHC.ppr p

instance GHC.Outputable Transformation where
  ppr (AsIs) = GHC.parens $ GHC.text "AsIs"
  ppr (T n)  = GHC.parens $ GHC.text "T" GHC.<+> GHC.text (show n)
  ppr (TAbove bo p1 p2 eo)  = GHC.parens $ GHC.text "TAbove" GHC.<+> GHC.ppr bo
                              GHC.<+> GHC.ppr p1  GHC.<+> GHC.ppr p2
                              GHC.<+> GHC.ppr eo
  ppr (TDeleted sspan ro p) = GHC.parens $ GHC.text "TAbove" GHC.<+> GHC.ppr sspan
                              GHC.<+> GHC.ppr ro  GHC.<+> GHC.ppr p
  ppr (TAdded) = GHC.parens $ GHC.text "TAdded"

instance GHC.Outputable Annot where
  ppr (Ann str) = GHC.parens $ GHC.text "Ann" GHC.<+> GHC.text str
  ppr (ADeleted ss pg p) = GHC.parens $ GHC.text "ADeleted" GHC.<+> GHC.ppr ss
                           GHC.<+> GHC.ppr pg GHC.<+> GHC.ppr p
  ppr (ASubtree ss)      = GHC.parens $ GHC.text "ASubtree" GHC.<+> GHC.ppr ss

instance GHC.Outputable Up where
  ppr (Up ss ls ds) = GHC.parens $ GHC.hang (GHC.text "Up") 1
                                 (GHC.ppr ss GHC.$$ GHC.ppr ls GHC.$$ GHC.ppr ds)
  ppr (UDeleted d)  = GHC.parens $ GHC.text "UDeleted" GHC.<+> GHC.ppr d

instance GHC.Outputable DeletedSpan where
  ppr (DeletedSpan ss ro p) = GHC.parens $ (GHC.text "DeletedSpan")
                               GHC.<+> GHC.ppr ss GHC.<+> GHC.ppr ro
                               GHC.<+> GHC.ppr p


instance GHC.Outputable Span where
  ppr (Span sp ep) = GHC.parens $ GHC.text "Span" GHC.<+> GHC.ppr sp GHC.<+> GHC.ppr ep

instance (GHC.Outputable a) => GHC.Outputable (NE.NonEmpty a) where
  -- ppr (x NE.:| xs) = GHC.parens $ GHC.hang (GHC.text "NonEmpty") 1 (GHC.ppr (x:xs))
  ppr (x NE.:| xs) = (GHC.ppr (x:xs))

instance GHC.Outputable Line where
  ppr (Line r c s str) = GHC.parens $ GHC.text "Line" GHC.<+> GHC.ppr r
                         GHC.<+> GHC.ppr c GHC.<+> GHC.ppr s
                         GHC.<+> GHC.text (show str)

instance GHC.Outputable Source where
  ppr SOriginal = GHC.text "SOriginal"
  ppr SAdded    = GHC.text "SAdded"

-- ---------------------------------------------------------------------

renderSourceTree :: SourceTree -> String
renderSourceTree srcTree = r
  where
    r = case getU srcTree of
         Nothing -> ""
         Just (Up span str ds) -> renderLines $ NE.toList str

-- ---------------------------------------------------------------------

renderLines :: [Line] -> String
renderLines ls = res
  where
    (_,(_,res)) = runState (go 0 ls) ((1,1),"")

    go _ [] = do return ()
    go ci ((Line r c s str):ls') = do
      newPos r (c+ci)
      addString str
      go ci ls'

    -- State operations ----------------

    getRC = do
      (rc,_) <- get
      return rc

    putRC (r,c) = do
      (_,str) <- get
      put ((r,c),str)

    newPos newRow newCol = do
      (oldRow',oldCol) <- getRC

      -- Allow for out of order additions that result from additions
      -- to the tree. Will break the invariant.
      let oldRow = if oldRow' <= newRow then oldRow' else (newRow - 1)
      putRC (oldRow,oldCol)

      if oldRow == newRow
        then addString (take (newCol - oldCol) $ repeat ' ')
        else
          addString ( (take (newRow - oldRow) $ repeat '\n') ++
                      (take (newCol - 1) $ repeat ' ') )

    addString [] = return ()
    addString str = do
      ((r,c),curr) <- get
      let ll = (length $ filter (=='\n') str)
      let c'' = (length $ takeWhile (/='\n') $ reverse str)


      let (r',c') = case ll of
                     0 -> (r,c + c'')
                     _ -> (r + ll, c'' + 1)
      put ((r',c'),curr++str)

      -- checkInvariant $ "addString" ++ show str

    addDebugString str = do
      ((r,c),curr) <- get
      put ((r,c),curr++str)

-- ---------------------------------------------------------------------

layoutTreeToSourceTree :: LayoutTree -> SourceTree

-- TODO: simplify by getting rid of PDeleted, and use leafU
layoutTreeToSourceTree (T.Node (Deleted sspan  pg eg) _)
  = leaf (UDeleted [(DeletedSpan (fs2s sspan) pg eg)]) (PDeleted sspan pg eg)

layoutTreeToSourceTree (T.Node (Entry sspan NoChange [])  ts0)
  = annot (ASubtree sspan) (mconcatl $ map layoutTreeToSourceTree ts0)
layoutTreeToSourceTree (T.Node (Entry sspan (Above bo p1 p2 eo) [])  ts0)
  = annot (ASubtree sspan)
      (applyD (TAbove bo p1 p2 eo) (mconcatl $ map layoutTreeToSourceTree ts0))

layoutTreeToSourceTree (T.Node (Entry sspan _lay toks) _ts) = leaf (mkUp sspan toks) (PToks toks)

-- -------------------------------------

-- We use the foldl version to get a more bushy tree, else the ppr of
-- it is very hard to follow
mconcatl :: (Monoid a) => [a] -> a
mconcatl = foldl mappend mempty

-- ---------------------------------------------------------------------

fs2s :: ForestSpan -> Span
fs2s ss = Span sp ep
  where
    (sp,ep) = forestSpanToSimpPos ss

-- ---------------------------------------------------------------------

mkUp :: ForestSpan -> [PosToken] -> Up
mkUp sspan toks = Up ss ls []
  where
    s = if forestSpanVersionSet sspan then SAdded else SOriginal
    ss = mkSpan sspan
    toksByLine = groupTokensByLine toks

    ls = NE.fromList $ concatMap (mkLinesFromToks s) toksByLine

-- ---------------------------------------------------------------------

mkLinesFromToks :: Source -> [PosToken] -> [Line]
mkLinesFromToks _ [] = []
mkLinesFromToks s toks = [Line ro co s str]
  where
    ro' = tokenRow $ head toks
    co' = tokenCol $ head toks
    (ro,co) = srcPosToSimpPos (tokenRow $ head toks, tokenCol $ head toks)
    toks' = addOffsetToToks (-ro',-co') toks
    str = GHC.showRichTokenStream toks'

-- ---------------------------------------------------------------------

combineUps :: Up -> Up -> Up
combineUps (UDeleted d1) (UDeleted d2)  = UDeleted (d1 <> d2)
combineUps (UDeleted d1) (Up sp2 l2 d2) = (Up sp2 l (d1 <> d2))
  where
    -- deltaL = calcDelta d1
    -- l = NE.map (\(Line r c s str) -> Line (r - deltaL) c s str) l2
    l = adjustForDeleted d1 l2
combineUps (Up sp1 l1 d1) (UDeleted d2) = (Up sp1 l1 (d1 <> d2))
combineUps (Up sp1 l1 d1) (Up sp2 l2 d2) = (Up (sp1 <> sp2) l (d1 <> d2))
  where
    -- (Span (_sr1,_sc1) (_er1,_ec1)) = sp1
    -- (Span (_sr2,_sc2) (_er2,_ec2)) = sp2
    -- Assumptions
    --  1. The first character of (head str1) is at (sr1,sc1)
    --  2. The first character of (head str2) is at (sr2,sc2)
    -- deltaL = calcDelta d1
    -- l2' = NE.map (\(Line r c s str) -> Line (r - deltaL) c s str) l2
    l2' = adjustForDeleted d1 l2

    (Line r1 c1  ss1 s1) = NE.last l1
    (Line r2 c2 _ss2 s2) = NE.head l2'

    l = if r1 == r2
         then NE.fromList $ (NE.init l1) ++ m ++ (NE.tail l2')
         else NE.fromList $ (NE.toList l1) ++ (NE.toList l2')

    m = [Line r1 c1 ss1 (s1 ++ gap ++ s2)]
    gap = take (c2 - (c1 + length s1)) $ repeat ' '



{-
    l = if (d1 == [] && d2 == [])
          then l'
          else error $ "combineUps: (u1,u2)=" ++ showGhc ((Up sp1 l1 d1),(Up sp2 l2 d2))
-}
{-
combineUps: (u1,u2)=((Up
   (Span (3, 1) (4, 8))
   [(Line 3 1 "tup@(h,t) = head $ zip [1..10] [3..ff]"),
    (Line 4 3 "where")]
   []),
 (Up
   (Span (6, 5) (6, 12))
   [(Line 6 5 "ff = 15")]
   [(DeletedSpan (Span (5, 5) (5, 14)) 1 (1, -9))]))
-}
{-

Must only combine any deleted spans that occur in the join point,
assumption is that any internal deletions have already been managed

combineUps: (u1,u2)=
((Up
   (Span (1, 1) (3, 26))
   [(Line 1 1 "module Layout.FromMd1 where"),
    (Line 3 1 "data D = A | B String | C")]
   [(DeletedSpan (Span (5, 1) (5, 17)) 2 (1, -16))]),
 (Up
   (Span (6, 1) (8, 11))
   [(Line 6 1 "ff y = y + zz"), (Line 7 3 "where"),
    (Line 8 5 "zz = 1")]
   []))

-}

adjustForDeleted :: [DeletedSpan] -> NE.NonEmpty Line -> NE.NonEmpty Line
adjustForDeleted d1 l2 = l
  where
    deltaL = calcDelta d1
    l = NE.map go l2

    go (Line r c SOriginal str) =  Line (r - deltaL) c SOriginal str
    go (Line r c SAdded    str) =  Line  r           c SAdded    str

-- -------------------------------------

calcDelta :: [DeletedSpan] -> RowOffset
calcDelta d1 = deltaL
  where
    deltaL = case d1 of
              [] -> 0
              _  -> (-1) + (sum $ map calcDelta' d1)

    calcDelta' :: DeletedSpan -> RowOffset
    calcDelta' (DeletedSpan (Span (rs,_cs) (re,_ce)) pg (rd,_cd)) = r + 1
      where
        ol = re - rs
        eg = rd
        r = (pg + ol + eg) - (max pg eg)


-- ---------------------------------------------------------------------

mkSpan :: ForestSpan -> Span
mkSpan ss = Span s e
  where
   (s,e) = forestSpanToSimpPos ss

-- ---------------------------------------------------------------------

toksToUpStr :: [PosToken] -> [String]
toksToUpStr = lines . removeOffsetToks

-- ---------------------------------------------------------------------

removeOffsetToks :: [PosToken] -> String
removeOffsetToks [] = ""
removeOffsetToks toks = str
  where
    ro' = tokenRow $ head toks
    co' = tokenCol $ head toks
    toks' = addOffsetToToks (-ro',-co') toks
    str = GHC.showRichTokenStream toks'

-- ---------------------------------------------------------------------

normaliseColumns :: [Line] -> [Line]
normaliseColumns [] = []
normaliseColumns ps = ps'
  where
    offset = case (head ps) of
      Line    _r c _ _ -> c - 1
      _                -> 0
    ps' = map remove ps

    remove (Line r c s str) = (Line r (c - offset) s str)
    remove x = x

-- ---------------------------------------------------------------------