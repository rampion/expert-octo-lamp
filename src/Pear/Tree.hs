module Pear.Tree 
  ( module Pear.Tree
  , module Pear.Positive
  , module Pear.Pair.LinkToModuleDocumentation
  , module Pear.Zipper
  ) where

import Prelude hiding (lookup, fst, snd, reverse)
import Control.Applicative (liftA2)
import Control.Monad.State (evalState, state)
import Data.Function ((&))
import Data.Functor.Const (pattern Const, getConst)
import Data.Functor.Identity (pattern Identity, runIdentity)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Numeric.Natural (Natural)
import Pear.Pair hiding (at)
import Pear.Pair qualified as Pear.Pair.LinkToModuleDocumentation -- avoid transcluding definitions from Pear.Pair when generating the documentation
import Pear.Positive
import Pear.Zipper

type Tree :: Type -> Type
data Tree a = Top a | Tree (Pair a) :>- Maybe a
infixl 4 :>-

deriving instance Eq a => Eq (Tree a)
deriving instance Functor Tree
deriving instance Foldable Tree
deriving instance Traversable Tree

instance Show a => Show (Tree a) where
  showsPrec p = showParen (p >= 4) . showsTree where
    -- *almost* equivalent to the derived instance, but the derived instance inserts
    -- unnecessary parentheses e.g.
    --
    --  (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing) :>- Just 'e'
    showsTree :: forall a. Show a => Tree a -> ShowS
    showsTree = \case
      Top a -> showString "Top " . showsPrec 10 a
      t :>- ma -> showsTree t . showString " :>- " . showsPrec 4 ma

instance Zipperable Tree where
  -- | one-hole contexts of 'Tree's
  data Context Tree a where
  -- Per Conor McBride, the one-hole context for a type is isomorphic to the
  -- derivative of the algebraic representation of a type.
  --
  -- @
  --  Maybe a                         ↔   1 + a
  --  Hole                            ↔   1
  --
  --  Top a                           ↔   a
  --  Tree (Pair a) :>- Maybe a       ↔   Tree (Pair a) · (1 + a)
  --  Tree a                          ↔   a + Tree (Pair a) · (1 + a)
  --
  --  Context Tree a                  ↔   d(Tree a)/da
  --                                  ↔   da/da + d(Tree (Pair a))/da · (1 + a) + Tree (Pair a) . d(1 + a)/da
  --
  --  da/da                           ↔   1
  --                                  ↔   AtTop
  --
  --  d(Tree (Pair a))/da · (1 + a)   ↔   Context Tree a² · Context Pair a · (1 + a)
  --                                  ↔   Context Tree a² :\ (Context Pair a, Maybe a)
  --
  --  Tree (Pair a) . d(1 + a)/da     ↔   Tree (Pair a) · 1
  --                                  ↔   Tree a² :\- Hole
  -- @
  --
  -- The chain rule is your friend
    AtTop :: Context Tree a
    (:\) :: Context Tree (Pair a) -> (Context Pair a, Maybe a)-> Context Tree a
    (:\-) :: Tree (Pair a) -> Hole -> Context Tree a
    deriving (Show, Eq, Functor)

  fillContext = \case
    AtTop             -> Top
    ta² :\- Hole      -> \a -> ta² :>- Just a
    cta² :\ (cpa, ma) -> \a -> fillContext cta² (fillContext cpa a) :>- ma

  mapWithContext f = \case
    Top a -> Top (f AtTop a)
    ta² :>- ma -> 
      mapWithContext (\cta² -> mapWithContext \cpa -> f (cta² :\ (cpa, ma))) ta² 
        :>- fmap (f (ta² :\- Hole)) ma
    
  nextContext withTree withZipper = \case
    AtTop -> withTree . Top
    ta²  :\- Hole -> withTree . \a -> ta² :>- Just a
    cta² :\ (cpa, ma) -> 
      cpa & nextContext
        do cta² & nextContext
            do \ta² -> maybe (withTree (ta² :>- Nothing)) (withZipper (ta² :\- Hole)) ma
            do \cta² (a₂ :× a₃) -> withZipper (cta² :\ (Hole :< a₃, ma)) a₂
        do \cpa -> withZipper (cta² :\ (cpa, ma))

infixl 4 :\, :\-

instance Traversable (Zipper Tree) where
  traverse = undefined

instance Semigroup (Tree a) where
  (<>) = undefined

type Tree0 :: Type -> Type
type Tree0 a = Maybe (Tree a)

reverse :: Tree a -> Tree a
reverse = undefined

reverse0 :: Tree0 a -> Tree0 a
reverse0 = fmap reverse

filter :: (a -> Bool) -> Tree a -> Tree0 a
filter p = mapMaybe \a -> if p a then Just a else Nothing

mapMaybe :: (a -> Maybe b) -> Tree a -> Tree0 b
mapMaybe = undefined

size :: Tree a -> Positive
size =  \case
  Top _ -> ObI
  ta² :>- ma -> size ta² :. maybe O (const I) ma

size0 :: Tree0 a -> Natural
size0 = maybe 0 (toNatural . size)

head :: Tree a -> a
head = loop id where
  loop :: (b -> a) -> Tree b -> a
  loop k = \case
    Top b -> k b
    ta² :>- _ -> loop (k . fst) ta²

last :: Tree a -> a
last = loop id where
  loop :: (b -> a) -> Tree b -> a
  loop k = \case
    Top b -> k b
    ta² :>- Nothing -> loop (k . snd) ta²
    _ :>- Just a -> k a

(??) :: Tree a -> Natural -> Maybe a
(??) = flip \i -> fmap getConst . at i Const
infix 9 ??

put :: Natural -> a -> Tree a -> Maybe (Tree a)
put i = modify i . const

modify :: Natural -> (a -> a) -> Tree a -> Maybe (Tree a)
modify i f = fmap runIdentity . at i (Identity . f)

at :: Natural -> (forall f. Functor f => (a -> f a) -> Tree a -> Maybe (f (Tree a)))
at i f t = fmap zipUp . focus f <$> zipDown t ?? i

indexes :: Tree a -> Tree (Natural, a)
indexes = (`evalState` 0). traverse \a -> state \(!i) -> ((i, a), i + 1)

singleton :: a -> Tree a
singleton = Top

push :: a -> Tree a -> Tree a
push a = \case
  Top a₀ -> Top (a₀ :× a) :>- Nothing
  ta² :>- Nothing -> ta² :>- Just a
  ta² :>- Just a₀ -> push (a₀ :× a) ta² :>- Nothing

push0 :: a -> Tree0 a -> Tree a
push0 = liftA2 maybe Top push

pop :: Tree a -> (Tree0 a, a)
pop = \case 
  Top a -> (Nothing, a)
  ta² :>- Just a -> (Just (ta² :>- Nothing), a)
  ta² :>- Nothing ->
    let ~(ta, a) = pop2 ta² in (Just ta, a)

pop2 :: Tree (Pair a) -> (Tree a, a)
pop2 = \case
  Top (a₀ :× a₁) -> (Top a₀, a₁)
  ta⁴ :>- Just (a₀ :× a₁) -> (ta⁴ :>- Nothing :>- Just a₀, a₁)
  ta⁴ :>- Nothing -> 
    let ~(ta², a₀ :× a₁) = pop2 ta⁴ in (ta² :>- Just a₀, a₁)

split :: Positive -> Tree a -> Maybe (Tree a, Tree a)
split = undefined

split0 :: Natural -> Tree a -> (Tree0 a, Tree0 a)
split0 = undefined

fuse :: Tree a -> Tree a -> Tree a
fuse = undefined

fuse0 :: Tree0 a -> Tree0 a -> Tree0 a
fuse0 = liftA2 fuse

fiss :: Positive -> Tree a -> Maybe (Tree a, Tree a)
fiss = undefined

fiss0 :: Natural -> Tree a -> (Tree0 a, Tree0 a)
fiss0 = undefined

fromNonEmpty :: NonEmpty a -> Tree a
fromNonEmpty = undefined

fromList :: [a] -> Tree0 a
fromList = fmap fromNonEmpty . NonEmpty.nonEmpty

toNonEmpty :: Tree a -> NonEmpty a
toNonEmpty = undefined

toList :: Tree0 a -> [a]
toList = maybe [] (NonEmpty.toList . toNonEmpty)

generate :: Positive -> (Natural -> a) -> Tree a
generate = undefined

generate0 :: Natural -> (Natural -> a) -> Tree0 a
generate0 = maybe (const Nothing) (fmap Just . generate) . fromNatural

replicate :: Positive -> a -> Tree a
replicate n = generate n . const

replicate0 :: Natural -> a -> Tree0 a
replicate0 n = generate0 n . const
