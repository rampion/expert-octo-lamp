module Pear.Tree where

import Prelude hiding (lookup, fst, snd, reverse)
import Control.Applicative (liftA2)
import Control.Monad.State (evalState, state)
import Data.Functor.Const (pattern Const, getConst)
import Data.Functor.Identity (pattern Identity, runIdentity)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Numeric.Natural (Natural)
import Pear.Lens
import Pear.Pair hiding (at)
import Pear.Positive

type Tree :: Type -> Type
data Tree a = Top a | Tree (Pair a) :>- Maybe a

deriving instance Eq a => Eq (Tree a)
deriving instance Functor Tree
deriving instance Foldable Tree
deriving instance Traversable Tree

instance Show a => Show (Tree a) where
  showsPrec = undefined

instance Semigroup (Tree a) where
  (<>) = undefined

type Tree0 :: Type -> Type
type Tree0 a = Maybe (Tree a)

reverse :: Tree a -> Tree a
reverse = undefined

reverse0 :: Tree0 a -> Tree0 a
reverse0 = fmap reverse

indexes :: Tree a -> Tree (Natural, a)
indexes = (`evalState` 0). traverse \a -> state \(!i) -> ((i, a), i + 1)

filter :: (a -> Bool) -> Tree a -> Tree0 a
filter p = mapMaybe \a -> if p a then Just a else Nothing

mapMaybe :: (a -> Maybe b) -> Tree a -> Tree0 b
mapMaybe = undefined

push :: a -> Tree a -> Tree a
push = undefined

push0 :: a -> Tree0 a -> Tree a
push0 = liftA2 maybe Top push

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
(??) = flip lookup
infix 9 ??

lookup :: Natural -> Tree a -> Maybe a
lookup i = fmap getConst . at i Const

put :: Natural -> a -> Tree a -> Maybe (Tree a)
put i = modify i . const

modify :: Natural -> (a -> a) -> Tree a -> Maybe (Tree a)
modify i f = fmap runIdentity . at i (Identity . f)

at :: Natural -> (forall f. Functor f => (a -> f a) -> Tree a -> Maybe (f (Tree a)))
at i f t = fmap zipUp . focus f <$> zipDown t ?? i

pop :: Tree a -> (Tree0 a, a)
pop = undefined

pop2 :: Tree (Pair a) -> (Tree a, a)
pop2 = undefined

size :: Tree a -> Positive
size = undefined

size0 :: Tree0 a -> Natural
size0 = undefined

split :: Positive -> Tree a -> Maybe (Tree a, Tree a)
split = undefined

split0 :: Natural -> Tree a -> (Tree0 a, Tree0 a)
split0 = undefined

fuse :: Tree a -> Tree a -> Tree a
fuse = undefined

fuse0 :: Tree0 a -> Tree0 a -> Tree0 a
fuse0 = undefined

fiss :: Positive -> Tree a -> Maybe (Tree a, Tree a)
fiss = undefined

fiss0 :: Natural -> Tree a -> (Tree0 a, Tree0 a)
fiss0 = undefined

fromNonEmpty :: NonEmpty a -> Tree a
fromNonEmpty = undefined

fromList :: [a] -> Tree0 a
fromList = undefined

toNonEmpty :: Tree a -> NonEmpty a
toNonEmpty = undefined

toList :: Tree0 a -> [a]
toList = undefined

generate :: Positive -> (Natural -> a) -> Tree a
generate = undefined

generate0 :: Natural -> (Natural -> a) -> Tree0 a
generate0 = undefined

replicate :: Positive -> a -> Tree a
replicate = undefined

replicate0 :: Natural -> a -> Tree0 a
replicate0 = undefined

data Tree' a where
  AtTop :: Tree' a
  InLeaf :: Tree (Pair a) -> Tree' a
  InFst :: Tree' (Pair a) -> a -> Maybe a -> Tree' a
  InSnd :: Tree' (Pair a) -> a -> Maybe a -> Tree' a

data Zipper a = Zipper
  { context :: Tree' a
  , value :: a
  }

focus :: Lens' a (Zipper a)
focus f Zipper{context,value} = Zipper context <$> f value

zipUp :: Zipper a -> Tree a
zipUp = \Zipper{context,value} -> loop context value where
  loop :: Tree' a -> a -> Tree a
  loop = \case
    AtTop -> Top
    InLeaf ta² -> \a -> ta² :>- Just a
    InFst fa² a₁ ma -> \a₀ -> loop fa² (a₀ :× a₁) :>- ma
    InSnd fa² a₀ ma -> \a₁ -> loop fa² (a₀ :× a₁) :>- ma

zipDown :: Tree a -> Tree (Zipper a)
zipDown = undefined

zipNext :: Zipper a -> Maybe (Zipper a)
zipNext = undefined

zipPrevious :: Zipper a -> Maybe (Zipper a)
zipPrevious = undefined
