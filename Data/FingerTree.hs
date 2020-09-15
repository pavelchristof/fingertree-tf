{-# LANGUAGE FlexibleInstances, FlexibleContexts, TypeFamilies #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.FingerTree
-- Copyright   :  (c) Ross Paterson, Ralf Hinze, Paweł Nowak 2014
-- License     :  BSD-style
-- Maintainer  :  pawel834@gmail.com
-- Stability   :  provisional
-- Portability :  non-portable (TypeFamilies)
--
-- A version of Data.FingerTree from package fingertree modified to use 
-- associated types instead of functional dependencies and MPTCs.
--
-- A general sequence representation with arbitrary annotations, for
-- use as a base for implementations of various collection types, as
-- described in section 4 of
--
--    * Ralf Hinze and Ross Paterson,
--      \"Finger trees: a simple general-purpose data structure\",
--      /Journal of Functional Programming/ 16:2 (2006) pp 197-217.
--      <http://www.soi.city.ac.uk/~ross/papers/FingerTree.html>
--
-- For a directly usable sequence type, see @Data.Sequence@, which is
-- a specialization of this structure.
--
-- An amortized running time is given for each operation, with /n/
-- referring to the length of the sequence.  These bounds hold even in
-- a persistent (shared) setting.
--
-- /Note/: Many of these operations have the same names as similar
-- operations on lists in the "Prelude".  The ambiguity may be resolved
-- using either qualification or the @hiding@ clause.
--
-----------------------------------------------------------------------------

module Data.FingerTree 
    ( FingerTree
    , Measured(..)
    -- * Construction
    , empty, singleton
    , (<|), (|>), (><)
    , fromList
    -- * Deconstruction
    , null
    , ViewL(..), ViewR(..), viewl, viewr
    , split, takeUntil, dropUntil
    -- * Transformation
    , reverse
    , fmap', fmapWithPos, unsafeFmap
    , traverse', traverseWithPos, unsafeTraverse
    ) where

import Prelude hiding (null, reverse)

import Control.Applicative (Applicative(pure, (<*>)), (<$>))
import Data.Foldable (Foldable(foldMap), toList)
import Data.Monoid

infixr 5 ><
infixr 5 <|, :<
infixl 5 |>, :>

-- | View of the left end of a sequence.
data ViewL s a = EmptyL   -- ^ empty sequence
               | a :< s a -- ^ leftmost element and the rest of the sequence
    deriving (Eq, Ord, Show, Read)

-- | View of the right end of a sequence.
data ViewR s a = EmptyR   -- ^ empty sequence
               | s a :> a -- ^ the sequence minus the rightmost element,
                          -- and the rightmost element
    deriving (Eq, Ord, Show, Read)

instance Functor s => Functor (ViewL s) where
    fmap _ EmptyL    = EmptyL
    fmap f (x :< xs) = f x :< fmap f xs

instance Functor s => Functor (ViewR s) where
    fmap _ EmptyR    = EmptyR
    fmap f (xs :> x) = fmap f xs :> f x

instance Measured a => Semigroup (FingerTree a) where
    (<>) = (><)

-- | 'empty' and '><'.
instance Measured a => Monoid (FingerTree a) where
    mempty = empty
    mappend = (<>)

-- Explicit Digit type (Exercise 1)

data Digit a = One a
             | Two a a
             | Three a a a
             | Four a a a a
    deriving Show

instance Foldable Digit where
    foldMap f (One a) = f a
    foldMap f (Two a b) = f a <> f b
    foldMap f (Three a b c) = f a <> f b <> f c
    foldMap f (Four a b c d) = f a <> f b <> f c <> f d

-------------------
-- 4.1 Measurements
-------------------

-- | Things that can be measured.
class Monoid (Measure a) => Measured a where
    type Measure a :: *
    measure :: a -> Measure a

instance Measured a => Measured (Digit a) where
    type Measure (Digit a) = Measure a
    measure = foldMap measure

---------------------------
-- 4.2 Caching measurements
---------------------------

data Node a = Node2 !(Measure a) a a | Node3 !(Measure a) a a a

instance Foldable Node where
    foldMap f (Node2 _ a b) = f a <> f b
    foldMap f (Node3 _ a b c) = f a <> f b <> f c

node2 :: Measured a => a -> a -> Node a
node2 a b = Node2 (measure a <> measure b) a b

node3 :: Measured a => a -> a -> a -> Node a
node3 a b c = Node3 (measure a <> measure b <> measure c) a b c

instance Measured a => Measured (Node a) where
    type Measure (Node a) = Measure a
    measure (Node2 v _ _) = v
    measure (Node3 v _ _ _) = v

nodeToDigit :: Node a -> Digit a
nodeToDigit (Node2 _ a b) = Two a b
nodeToDigit (Node3 _ a b c) = Three a b c

-- | A representation of a sequence of values of type @a@, allowing
-- access to the ends in constant time, and append and split in time
-- logarithmic in the size of the smaller piece.
--
-- The collection is also parameterized by a measure type @v@, which
-- is used to specify a position in the sequence for the 'split' operation.
-- The types of the operations enforce the constraint @'Measured' v a@,
-- which also implies that the type @v@ is determined by @a@.
--
-- A variety of abstract data types can be implemented by using different
-- element types and measurements.
data FingerTree a
    = Empty
    | Single a
    | Deep !(Measure a) !(Digit a) (FingerTree (Node a)) !(Digit a)

deep :: Measured a=> Digit a -> FingerTree (Node a) -> Digit a -> FingerTree a
deep pr m sf = Deep ((measure pr `mappendVal` m) <> measure sf) pr m sf

-- | /O(1)/. The cached measure of a tree.
instance Measured a => Measured (FingerTree a) where
    type Measure (FingerTree a) = Measure a
    measure Empty          = mempty
    measure (Single x)     = measure x
    measure (Deep v _ _ _) = v

instance Foldable FingerTree where
    foldMap _ Empty = mempty
    foldMap f (Single x) = f x
    foldMap f (Deep _ pr m sf) =
        foldMap f pr <> foldMap (foldMap f) m <> foldMap f sf

instance Eq a => Eq (FingerTree a) where
    xs == ys = toList xs == toList ys

instance Ord a => Ord (FingerTree a) where
    compare xs ys = compare (toList xs) (toList ys)

instance Show a => Show (FingerTree a) where
    showsPrec p xs = showParen (p > 10) $
        showString "fromList " . shows (toList xs)

-- | Like 'fmap', but with a more constrained type.
fmap' :: (Measured a, Measured b) 
      => (a -> b) -> FingerTree a -> FingerTree b
fmap' = mapTree

mapTree :: (Measured a, Measured b)
        => (a -> b) -> FingerTree a -> FingerTree b
mapTree _ Empty = Empty
mapTree f (Single x) = Single (f x)
mapTree f (Deep _ pr m sf) =
    deep (mapDigit f pr) (mapTree (mapNode f) m) (mapDigit f sf)

mapNode :: (Measured a, Measured b)
        => (a -> b) -> Node a -> Node b
mapNode f (Node2 _ a b) = node2 (f a) (f b)
mapNode f (Node3 _ a b c) = node3 (f a) (f b) (f c)

mapDigit :: (a -> b) -> Digit a -> Digit b
mapDigit f (One a) = One (f a)
mapDigit f (Two a b) = Two (f a) (f b)
mapDigit f (Three a b c) = Three (f a) (f b) (f c)
mapDigit f (Four a b c d) = Four (f a) (f b) (f c) (f d)

-- | Map all elements of the tree with a function that also takes the
-- measure of the prefix of the tree to the left of the element.
fmapWithPos :: (Measured a, Measured b) 
            => (Measure a -> a -> b) -> FingerTree a -> FingerTree b
fmapWithPos f = mapWPTree f mempty

mapWPTree :: (Measured a, Measured b) 
          => (Measure a -> a -> b) -> Measure a -> FingerTree a -> FingerTree b
mapWPTree _ _ Empty = Empty
mapWPTree f v (Single x) = Single (f v x)
mapWPTree f v (Deep _ pr m sf) =
    deep (mapWPDigit f v pr)
         (mapWPTree (mapWPNode f) vpr m)
         (mapWPDigit f vm sf)
  where
    vpr = v <> measure pr
    vm  = vpr `mappendVal` m

mapWPNode :: (Measured a, Measured b) 
          => (Measure a -> a -> b) -> Measure a -> Node a -> Node b
mapWPNode f v (Node2 _ a b) = node2 (f v a) (f va b)
  where 
    va = v <> measure a
mapWPNode f v (Node3 _ a b c) = node3 (f v a) (f va b) (f vab c)
  where
    va  = v  <> measure a
    vab = va <> measure b

mapWPDigit :: Measured a => (Measure a -> a -> b) -> Measure a -> Digit a -> Digit b
mapWPDigit f v (One a) = One (f v a)
mapWPDigit f v (Two a b) = Two (f v a) (f va b)
  where
    va = v <> measure a
mapWPDigit f v (Three a b c) = Three (f v a) (f va b) (f vab c)
  where    
    va  = v  <> measure a
    vab = va <> measure b
mapWPDigit f v (Four a b c d) = Four (f v a) (f va b) (f vab c) (f vabc d)
  where    
    va   = v   <> measure a
    vab  = va  <> measure b
    vabc = vab <> measure c

-- | Like 'fmap', but safe only if the function preserves the measure.
unsafeFmap :: Measure a ~ Measure b 
           => (a -> b) -> FingerTree a -> FingerTree b
unsafeFmap _ Empty = Empty
unsafeFmap f (Single x) = Single (f x)
unsafeFmap f (Deep v pr m sf) =
    Deep v (mapDigit f pr) (unsafeFmap (unsafeFmapNode f) m) (mapDigit f sf)

unsafeFmapNode :: Measure a ~ Measure b 
               => (a -> b) -> Node a -> Node b
unsafeFmapNode f (Node2 v a b) = Node2 v (f a) (f b)
unsafeFmapNode f (Node3 v a b c) = Node3 v (f a) (f b) (f c)

-- | Like 'traverse', but with a more constrained type.
traverse' :: (Measured a, Measured b, Applicative f) 
          => (a -> f b) -> FingerTree a -> f (FingerTree b)
traverse' = traverseTree

traverseTree :: (Measured b, Applicative f) 
             => (a -> f b) -> FingerTree a -> f (FingerTree b)
traverseTree _ Empty = pure Empty
traverseTree f (Single x) = Single <$> f x
traverseTree f (Deep _ pr m sf) =
    deep <$> traverseDigit f pr <*> traverseTree (traverseNode f) m <*> traverseDigit f sf

traverseNode :: (Measured b, Applicative f) 
             => (a -> f b) -> Node a -> f (Node b)
traverseNode f (Node2 _ a b) = node2 <$> f a <*> f b
traverseNode f (Node3 _ a b c) = node3 <$> f a <*> f b <*> f c

traverseDigit :: (Applicative f) => (a -> f b) -> Digit a -> f (Digit b)
traverseDigit f (One a) = One <$> f a
traverseDigit f (Two a b) = Two <$> f a <*> f b
traverseDigit f (Three a b c) = Three <$> f a <*> f b <*> f c
traverseDigit f (Four a b c d) = Four <$> f a <*> f b <*> f c <*> f d

-- | Traverse the tree with a function that also takes the
-- measure of the prefix of the tree to the left of the element.
traverseWithPos :: (Measured a, Measured b, Applicative f) 
                => (Measure a -> a -> f b) -> FingerTree a -> f (FingerTree b)
traverseWithPos f = traverseWPTree f mempty

traverseWPTree :: (Measured a, Measured b, Applicative f) 
               => (Measure a -> a -> f b) -> Measure a -> FingerTree a -> f (FingerTree b)
traverseWPTree _ _ Empty = pure Empty
traverseWPTree f v (Single x) = Single <$> f v x
traverseWPTree f v (Deep _ pr m sf) =
    deep <$> traverseWPDigit f v pr <*> traverseWPTree (traverseWPNode f) vpr m <*> traverseWPDigit f vm sf
  where    
    vpr = v <> measure pr
    vm  = vpr  `mappendVal` m

traverseWPNode :: (Measured a, Measured b, Applicative f) 
               => (Measure a -> a -> f b) -> Measure a -> Node a -> f (Node b)
traverseWPNode f v (Node2 _ a b) = node2 <$> f v a <*> f va b
  where    
    va = v <> measure a
traverseWPNode f v (Node3 _ a b c) = node3 <$> f v a <*> f va b <*> f vab c
  where    
    va  = v  <> measure a
    vab = va <> measure b

traverseWPDigit :: (Measured a, Applicative f) 
                => (Measure a -> a -> f b) -> Measure a -> Digit a -> f (Digit b)
traverseWPDigit f v (One a) = One <$> f v a
traverseWPDigit f v (Two a b) = Two <$> f v a <*> f va b
  where
    va = v <> measure a
traverseWPDigit f v (Three a b c) = Three <$> f v a <*> f va b <*> f vab c
  where    
    va  = v  <> measure a
    vab = va <> measure b
traverseWPDigit f v (Four a b c d) = Four <$> f v a <*> f va b <*> f vab c <*> f vabc d
  where    
    va   = v   <> measure a
    vab  = va  <> measure b
    vabc = vab <> measure c

-- | Like 'traverse', but safe only if the function preserves the measure.
unsafeTraverse :: (Measure a ~ Measure b, Applicative f) 
               => (a -> f b) -> FingerTree a -> f (FingerTree b)
unsafeTraverse _ Empty = pure Empty
unsafeTraverse f (Single x) = Single <$> f x
unsafeTraverse f (Deep v pr m sf) =
    Deep v <$> traverseDigit f pr <*> unsafeTraverse (unsafeTraverseNode f) m <*> traverseDigit f sf

unsafeTraverseNode :: (Measure a ~ Measure b, Applicative f) 
                   => (a -> f b) -> Node a -> f (Node b)
unsafeTraverseNode f (Node2 v a b) = Node2 v <$> f a <*> f b
unsafeTraverseNode f (Node3 v a b c) = Node3 v <$> f a <*> f b <*> f c

-----------------------------------------------------
-- 4.3 Construction, deconstruction and concatenation
-----------------------------------------------------

-- | /O(1)/. The empty sequence.
empty :: Measured a => FingerTree a
empty = Empty

-- | /O(1)/. A singleton sequence.
singleton :: Measured a => a -> FingerTree a
singleton = Single

-- | /O(n)/. Create a sequence from a finite list of elements.
fromList :: Measured a => [a] -> FingerTree a 
fromList = foldr (<|) Empty

-- | /O(1)/. Add an element to the left end of a sequence.
-- Mnemonic: a triangle with the single element at the pointy end.
(<|) :: Measured a => a -> FingerTree a -> FingerTree a
a <| Empty    =  Single a
a <| Single b =  deep (One a) Empty (One b)
a <| Deep v (Four b c d e) m sf = m `seq`
    Deep (measure a <> v) (Two a b) (node3 c d e <| m) sf
a <| Deep v pr m sf    =
    Deep (measure a <> v) (consDigit a pr) m sf

consDigit :: a -> Digit a -> Digit a
consDigit a (One b) = Two a b
consDigit a (Two b c) = Three a b c
consDigit a (Three b c d) = Four a b c d
consDigit _ (Four _ _ _ _) = illegal_argument "consDigit"

-- | /O(1)/. Add an element to the right end of a sequence.
-- Mnemonic: a triangle with the single element at the pointy end.
(|>) :: Measured a => FingerTree a -> a -> FingerTree a
Empty |> a     =  Single a
Single a |> b  =  deep (One a) Empty (One b)
Deep v pr m (Four a b c d) |> e = m `seq`
    Deep (v <> measure e) pr (m |> node3 a b c) (Two d e)
Deep v pr m sf |> x    =
    Deep (v <> measure x) pr m (snocDigit sf x)

snocDigit :: Digit a -> a -> Digit a
snocDigit (One a) b = Two a b
snocDigit (Two a b) c = Three a b c
snocDigit (Three a b c) d = Four a b c d
snocDigit (Four _ _ _ _) _ = illegal_argument "snocDigit"

-- | /O(1)/. Is this the empty sequence?
null :: Measured a => FingerTree a -> Bool
null Empty = True
null _     = False

-- | /O(1)/. Analyse the left end of a sequence.
viewl :: Measured a => FingerTree a -> ViewL FingerTree a
viewl Empty                 =  EmptyL
viewl (Single x)            =  x :< Empty
viewl (Deep _ (One x) m sf) =  x :< rotL m sf
viewl (Deep _ pr m sf)      =  lheadDigit pr :< deep (ltailDigit pr) m sf

rotL :: Measured a => FingerTree (Node a) -> Digit a -> FingerTree a
rotL m sf = case viewl m of
    EmptyL  -> digitToTree sf
    a :< m' -> Deep (measure m <> measure sf) (nodeToDigit a) m' sf

lheadDigit :: Digit a -> a
lheadDigit (One a) = a
lheadDigit (Two a _) = a
lheadDigit (Three a _ _) = a
lheadDigit (Four a _ _ _) = a

ltailDigit :: Digit a -> Digit a
ltailDigit (One _) = illegal_argument "ltailDigit"
ltailDigit (Two _ b) = One b
ltailDigit (Three _ b c) = Two b c
ltailDigit (Four _ b c d) = Three b c d
 
-- | /O(1)/. Analyse the right end of a sequence.
viewr :: Measured a => FingerTree a -> ViewR FingerTree a
viewr Empty                 =  EmptyR
viewr (Single x)            =  Empty :> x
viewr (Deep _ pr m (One x)) =  rotR pr m :> x
viewr (Deep _ pr m sf)      =  deep pr m (rtailDigit sf) :> rheadDigit sf

rotR :: Measured a => Digit a -> FingerTree (Node a) -> FingerTree a
rotR pr m = case viewr m of
    EmptyR  -> digitToTree pr
    m' :> a -> Deep (measure pr `mappendVal` m) pr m' (nodeToDigit a)

rheadDigit :: Digit a -> a
rheadDigit (One a) = a
rheadDigit (Two _ b) = b
rheadDigit (Three _ _ c) = c
rheadDigit (Four _ _ _ d) = d

rtailDigit :: Digit a -> Digit a
rtailDigit (One _) = illegal_argument "rtailDigit"
rtailDigit (Two a _) = One a
rtailDigit (Three a b _) = Two a b
rtailDigit (Four a b c _) = Three a b c

digitToTree :: Measured a => Digit a -> FingerTree a
digitToTree (One a) = Single a
digitToTree (Two a b) = deep (One a) Empty (One b)
digitToTree (Three a b c) = deep (Two a b) Empty (One c)
digitToTree (Four a b c d) = deep (Two a b) Empty (Two c d)

----------------
-- Concatenation
----------------

-- | /O(log(min(n1,n2)))/. Concatenate two sequences.
(><) :: Measured a => FingerTree a -> FingerTree a -> FingerTree a
(><) = appendTree0

appendTree0 :: Measured a => FingerTree a -> FingerTree a -> FingerTree a
appendTree0 Empty xs =
    xs
appendTree0 xs Empty =
    xs
appendTree0 (Single x) xs =
    x <| xs
appendTree0 xs (Single x) =
    xs |> x
appendTree0 (Deep _ pr1 m1 sf1) (Deep _ pr2 m2 sf2) =
    deep pr1 (addDigits0 m1 sf1 pr2 m2) sf2

addDigits0 :: Measured a => FingerTree (Node a) -> Digit a -> Digit a -> FingerTree (Node a) -> FingerTree (Node a)
addDigits0 m1 (One a) (One b) m2 =
    appendTree1 m1 (node2 a b) m2
addDigits0 m1 (One a) (Two b c) m2 =
    appendTree1 m1 (node3 a b c) m2
addDigits0 m1 (One a) (Three b c d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (One a) (Four b c d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Two a b) (One c) m2 =
    appendTree1 m1 (node3 a b c) m2
addDigits0 m1 (Two a b) (Two c d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (Two a b) (Three c d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Two a b) (Four c d e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Three a b c) (One d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (Three a b c) (Two d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Three a b c) (Three d e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Three a b c) (Four d e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits0 m1 (Four a b c d) (One e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Four a b c d) (Two e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Four a b c d) (Three e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits0 m1 (Four a b c d) (Four e f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2

appendTree1 :: Measured a => FingerTree a -> a -> FingerTree a -> FingerTree a
appendTree1 Empty a xs =
    a <| xs
appendTree1 xs a Empty =
    xs |> a
appendTree1 (Single x) a xs =
    x <| a <| xs
appendTree1 xs a (Single x) =
    xs |> a |> x
appendTree1 (Deep _ pr1 m1 sf1) a (Deep _ pr2 m2 sf2) =
    deep pr1 (addDigits1 m1 sf1 a pr2 m2) sf2

addDigits1 :: Measured a 
           => FingerTree (Node a) -> Digit a -> a -> Digit a -> FingerTree (Node a) -> FingerTree (Node a)
addDigits1 m1 (One a) b (One c) m2 =
    appendTree1 m1 (node3 a b c) m2
addDigits1 m1 (One a) b (Two c d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits1 m1 (One a) b (Three c d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits1 m1 (One a) b (Four c d e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits1 m1 (Two a b) c (One d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits1 m1 (Two a b) c (Two d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits1 m1 (Two a b) c (Three d e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits1 m1 (Two a b) c (Four d e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits1 m1 (Three a b c) d (One e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits1 m1 (Three a b c) d (Two e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits1 m1 (Three a b c) d (Three e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits1 m1 (Three a b c) d (Four e f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits1 m1 (Four a b c d) e (One f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits1 m1 (Four a b c d) e (Two f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits1 m1 (Four a b c d) e (Three f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits1 m1 (Four a b c d) e (Four f g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2

appendTree2 :: Measured a 
            => FingerTree a -> a -> a -> FingerTree a -> FingerTree a
appendTree2 Empty a b xs =
    a <| b <| xs
appendTree2 xs a b Empty =
    xs |> a |> b
appendTree2 (Single x) a b xs =
    x <| a <| b <| xs
appendTree2 xs a b (Single x) =
    xs |> a |> b |> x
appendTree2 (Deep _ pr1 m1 sf1) a b (Deep _ pr2 m2 sf2) =
    deep pr1 (addDigits2 m1 sf1 a b pr2 m2) sf2

addDigits2 :: Measured a 
           => FingerTree (Node a) -> Digit a -> a -> a -> Digit a -> FingerTree (Node a) -> FingerTree (Node a)
addDigits2 m1 (One a) b c (One d) m2 =
    appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits2 m1 (One a) b c (Two d e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits2 m1 (One a) b c (Three d e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits2 m1 (One a) b c (Four d e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits2 m1 (Two a b) c d (One e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits2 m1 (Two a b) c d (Two e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits2 m1 (Two a b) c d (Three e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits2 m1 (Two a b) c d (Four e f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits2 m1 (Three a b c) d e (One f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits2 m1 (Three a b c) d e (Two f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits2 m1 (Three a b c) d e (Three f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits2 m1 (Three a b c) d e (Four f g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits2 m1 (Four a b c d) e f (One g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits2 m1 (Four a b c d) e f (Two g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits2 m1 (Four a b c d) e f (Three g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits2 m1 (Four a b c d) e f (Four g h i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2

appendTree3 :: Measured a 
            => FingerTree a -> a -> a -> a -> FingerTree a -> FingerTree a
appendTree3 Empty a b c xs =
    a <| b <| c <| xs
appendTree3 xs a b c Empty =
    xs |> a |> b |> c
appendTree3 (Single x) a b c xs =
    x <| a <| b <| c <| xs
appendTree3 xs a b c (Single x) =
    xs |> a |> b |> c |> x
appendTree3 (Deep _ pr1 m1 sf1) a b c (Deep _ pr2 m2 sf2) =
    deep pr1 (addDigits3 m1 sf1 a b c pr2 m2) sf2

addDigits3 :: Measured a 
           => FingerTree (Node a) -> Digit a -> a -> a -> a -> Digit a -> FingerTree (Node a) -> FingerTree (Node a)
addDigits3 m1 (One a) b c d (One e) m2 =
    appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits3 m1 (One a) b c d (Two e f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits3 m1 (One a) b c d (Three e f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits3 m1 (One a) b c d (Four e f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits3 m1 (Two a b) c d e (One f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits3 m1 (Two a b) c d e (Two f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits3 m1 (Two a b) c d e (Three f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits3 m1 (Two a b) c d e (Four f g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits3 m1 (Three a b c) d e f (One g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits3 m1 (Three a b c) d e f (Two g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits3 m1 (Three a b c) d e f (Three g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits3 m1 (Three a b c) d e f (Four g h i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
addDigits3 m1 (Four a b c d) e f g (One h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits3 m1 (Four a b c d) e f g (Two h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits3 m1 (Four a b c d) e f g (Three h i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
addDigits3 m1 (Four a b c d) e f g (Four h i j k) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2

appendTree4 :: Measured a 
            => FingerTree a -> a -> a -> a -> a -> FingerTree a -> FingerTree a
appendTree4 Empty a b c d xs =
    a <| b <| c <| d <| xs
appendTree4 xs a b c d Empty =
    xs |> a |> b |> c |> d
appendTree4 (Single x) a b c d xs =
    x <| a <| b <| c <| d <| xs
appendTree4 xs a b c d (Single x) =
    xs |> a |> b |> c |> d |> x
appendTree4 (Deep _ pr1 m1 sf1) a b c d (Deep _ pr2 m2 sf2) =
    deep pr1 (addDigits4 m1 sf1 a b c d pr2 m2) sf2

addDigits4 :: Measured a 
           => FingerTree (Node a) -> Digit a -> a -> a -> a -> a -> Digit a -> FingerTree (Node a) -> FingerTree (Node a)
addDigits4 m1 (One a) b c d e (One f) m2 =
    appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits4 m1 (One a) b c d e (Two f g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits4 m1 (One a) b c d e (Three f g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits4 m1 (One a) b c d e (Four f g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits4 m1 (Two a b) c d e f (One g) m2 =
    appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits4 m1 (Two a b) c d e f (Two g h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits4 m1 (Two a b) c d e f (Three g h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits4 m1 (Two a b) c d e f (Four g h i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
addDigits4 m1 (Three a b c) d e f g (One h) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
addDigits4 m1 (Three a b c) d e f g (Two h i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits4 m1 (Three a b c) d e f g (Three h i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
addDigits4 m1 (Three a b c) d e f g (Four h i j k) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2
addDigits4 m1 (Four a b c d) e f g h (One i) m2 =
    appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
addDigits4 m1 (Four a b c d) e f g h (Two i j) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
addDigits4 m1 (Four a b c d) e f g h (Three i j k) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2
addDigits4 m1 (Four a b c d) e f g h (Four i j k l) m2 =
    appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node3 j k l) m2

----------------
-- 4.4 Splitting
----------------

-- | /O(log(min(i,n-i)))/. Split a sequence at a point where the predicate
-- on the accumulated measure changes from 'False' to 'True'.
--
-- For predictable results, one should ensure that there is only one such
-- point, i.e. that the predicate is /monotonic/.
split :: Measured a 
      => (Measure a -> Bool) -> FingerTree a -> (FingerTree a, FingerTree a)
split _ Empty = (Empty, Empty)
split p xs
  | p (measure xs) = (l, x <| r)
  | otherwise      = (xs, Empty)
  where 
    Split l x r = splitTree p mempty xs

-- | /O(log(min(i,n-i)))/.
-- Given a monotonic predicate @p@, @'takeUntil' p t@ is the largest
-- prefix of @t@ whose measure does not satisfy @p@.
--
-- *  @'takeUntil' p t = 'fst' ('split' p t)@
takeUntil :: Measured a => (Measure a -> Bool) -> FingerTree a -> FingerTree a
takeUntil p = fst . split p

-- | /O(log(min(i,n-i)))/.
-- Given a monotonic predicate @p@, @'dropUntil' p t@ is the rest of @t@
-- after removing the largest prefix whose measure does not satisfy @p@.
--
-- * @'dropUntil' p t = 'snd' ('split' p t)@
dropUntil :: Measured a => (Measure a -> Bool) -> FingerTree a -> FingerTree a
dropUntil p  =  snd . split p

data Split t a = Split t a t

splitTree :: Measured a 
          => (Measure a -> Bool) -> Measure a 
          -> FingerTree a -> Split (FingerTree a) a
splitTree _ _ Empty = illegal_argument "splitTree"
splitTree _ _ (Single x) = Split Empty x Empty
splitTree p i (Deep _ pr m sf)
  | p vpr     = let Split l x r = splitDigit p i pr
                in  Split (maybe Empty digitToTree l) x (deepL r m sf)
  | p vm      = let Split ml xs mr =  splitTree p vpr m
                    Split l x r    =  splitNode p (vpr `mappendVal` ml) xs
                in  Split (deepR pr  ml l) x (deepL r mr sf)
  | otherwise = let Split l x r = splitDigit p vm sf
                in  Split (deepR pr  m  l) x (maybe Empty digitToTree r)
  where    
    vpr = i <> measure pr
    vm  = vpr  `mappendVal` m

-- Avoid relying on right identity (cf Exercise 7)
mappendVal :: Measured a => Measure a -> FingerTree a -> Measure a
mappendVal v Empty = v
mappendVal v t = v <> measure t

deepL :: Measured a 
      => Maybe (Digit a) -> FingerTree (Node a) -> Digit a -> FingerTree a
deepL Nothing m sf   = rotL m sf
deepL (Just pr) m sf = deep pr m sf

deepR :: Measured a 
      => Digit a -> FingerTree (Node a) -> Maybe (Digit a) -> FingerTree a
deepR pr m Nothing   = rotR pr m
deepR pr m (Just sf) = deep pr m sf

splitNode :: Measured a 
          => (Measure a -> Bool) -> Measure a -> Node a 
          -> Split (Maybe (Digit a)) a
splitNode p i (Node2 _ a b)
  | p va         = Split Nothing a (Just (One b))
  | otherwise    = Split (Just (One a)) b Nothing
  where 
    va = i <> measure a
splitNode p i (Node3 _ a b c)
  | p va      = Split Nothing a (Just (Two b c))
  | p vab     = Split (Just (One a)) b (Just (One c))
  | otherwise = Split (Just (Two a b)) c Nothing
  where    
    va  = i  <> measure a
    vab = va <> measure b

splitDigit :: Measured a 
           => (Measure a -> Bool) -> Measure a -> Digit a -> Split (Maybe (Digit a)) a
splitDigit _ i (One a) = i `seq` Split Nothing a Nothing
splitDigit p i (Two a b)
  | p va      = Split Nothing a (Just (One b))
  | otherwise = Split (Just (One a)) b Nothing
  where    
    va = i <> measure a
splitDigit p i (Three a b c)
  | p va      = Split Nothing a (Just (Two b c))
  | p vab     = Split (Just (One a)) b (Just (One c))
  | otherwise = Split (Just (Two a b)) c Nothing
  where    
    va  = i  <> measure a
    vab = va <> measure b
splitDigit p i (Four a b c d)
  | p va      = Split Nothing a (Just (Three b c d))
  | p vab     = Split (Just (One a)) b (Just (Two c d))
  | p vabc    = Split (Just (Two a b)) c (Just (One d))
  | otherwise = Split (Just (Three a b c)) d Nothing
  where    
    va   = i   <> measure a
    vab  = va  <> measure b
    vabc = vab <> measure c

------------------
-- Transformations
------------------

-- | /O(n)/. The reverse of a sequence.
reverse :: Measured a => FingerTree a -> FingerTree a
reverse = reverseTree id

reverseTree :: Measured b => (a -> b) -> FingerTree a -> FingerTree b
reverseTree _ Empty = Empty
reverseTree f (Single x) = Single (f x)
reverseTree f (Deep _ pr m sf) =
    deep (reverseDigit f sf) (reverseTree (reverseNode f) m) (reverseDigit f pr)

reverseNode :: Measured b => (a -> b) -> Node a -> Node b
reverseNode f (Node2 _ a b) = node2 (f b) (f a)
reverseNode f (Node3 _ a b c) = node3 (f c) (f b) (f a)

reverseDigit :: (a -> b) -> Digit a -> Digit b
reverseDigit f (One a) = One (f a)
reverseDigit f (Two a b) = Two (f b) (f a)
reverseDigit f (Three a b c) = Three (f c) (f b) (f a)
reverseDigit f (Four a b c d) = Four (f d) (f c) (f b) (f a)

illegal_argument :: String -> a
illegal_argument name =
    error $ "Logic error: " ++ name ++ " called with illegal argument"

{- $example

Particular abstract data types may be implemented by defining
element types with suitable 'Measured' instances.

(from section 4.5 of the paper)
Simple sequences can be implemented using a 'Sum' monoid as a measure:

> newtype Elem a = Elem { getElem :: a }
>
> instance Measured (Elem a) where
>     type Measure (Elem a) = Sum Int
>     measure (Elem _) = Sum 1
>
> newtype Seq a = Seq (FingerTree (Elem a))

Then the measure of a subsequence is simply its length.
This representation supports log-time extraction of subsequences:

> take :: Int -> Seq a -> Seq a
> take k (Seq xs) = Seq (takeUntil (> Sum k) xs)
>
> drop :: Int -> Seq a -> Seq a
> drop k (Seq xs) = Seq (dropUntil (> Sum k) xs)

The module @Data.Sequence@ is an optimized instantiation of this type.

-}
