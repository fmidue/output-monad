{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE QuasiQuotes #-}
-- | This module provides common skeletons for printing tasks
module Control.Monad.Output (
  OutputMonad (..),
  Rated,
  addPretext,
  directionsAdvice,
  hoveringInformation,
  multipleChoice,
  printSolutionAndAssert,
  recoverFrom,
  recoverWith,
  simplifiedInformation,
  singleChoice,
  singleChoiceSyntax,
  Out (..),
  ReportT (..),
  Report,
  abortWith,
  alignOutput,
  continueOrAbort,
  getAllOuts,
  getOutsWithResult,
  combineReports,
  combineWithReports,
  combineTwoReports,
  format,
  toAbort,
  toOutput,
  LangM,
  LangM' (LangM),
  Language (..),
  english,
  german,
  localise,
  mapLangM,
  multiLang,
  translate,
  translations,
  withLang,
  yesNo,
  ) where

import qualified Data.Map as M

import Control.Applicative              (Alternative ((<|>)))
import Control.Monad                    (foldM, unless, void, when)
import Control.Monad.IO.Class           (MonadIO (liftIO))
import Control.Monad.Identity           (Identity)
import Control.Monad.State              (State, execState, modify)
import Control.Monad.Trans              (MonadTrans (lift))
import Control.Monad.Trans.Maybe (MaybeT (MaybeT, runMaybeT))
import Control.Monad.Writer (
  MonadWriter (pass, tell),
  WriterT (WriterT, runWriterT),
  execWriterT,
  )
import Data.Containers.ListUtils        (nubOrd)
import Data.Foldable                    (for_)
import Data.List                        (sort)
import Data.Map                         (Map)
import Data.Maybe                       (fromMaybe, isJust)
import Data.Ratio                       ((%))
import Data.String.Interpolate          (i)

hoveringInformation :: OutputMonad m => LangM m
hoveringInformation = translate $ do
  english [i|Please note: Hovering over or clicking on edges / nodes or their labels highlights the respective matching parts.|]
  german [i|Bitte beachten Sie: Beim Bewegen über oder Klicken auf Kanten / Knoten bzw. ihre Beschriftungen werden die jeweils zusammengehörenden Komponenten hervorgehoben.|]

directionsAdvice :: OutputMonad m => LangM m
directionsAdvice = translate $ do
  english [i|As navigation directions are used, please note that aggregations and compositions are only navigable from the "part" toward the "whole", i.e. they are not navigable in the opposite direction!|]
  german [i|Da Navigationsrichtungen verwendet werden, beachten Sie bitte, dass Aggregationen und Kompositionen nur vom "Teil" zum "Ganzen" navigierbar sind, d.h. sie sind nicht in der entgegengesetzten Richtung navigierbar!|]

simplifiedInformation :: OutputMonad m => LangM m
simplifiedInformation = translate $ do
  english [i|Please note: Classes are represented simplified here.
That means they consist of a single box containing only its class name, but do not contain boxes for attributes and methods.
Nevertheless you should treat these simplified class representations as valid classes.|]
  german [i|Bitte beachten Sie: Klassen werden hier vereinfacht dargestellt.
Das heißt, sie bestehen aus einer einfachen Box, die nur den Klassennamen enthält, aber keine Abschnitte für Attribute oder Methoden.
Trotzdem sollten Sie diese vereinfachten Klassendarstellungen als valide Klassen ansehen.|]

{-|
If argument is True,
it will continue after assertion,
otherwise it will stop if assertion fails.
-}
continueOrAbort :: OutputMonad m => Bool -> Bool -> LangM m -> LangM m
continueOrAbort True  = yesNo
continueOrAbort False = assertion

yesNo :: OutputMonad m => Bool -> LangM m -> LangM m
yesNo p q = do
  paragraph q
  paragraph $ indent $ localised code $ translations $
      if p
      then do
        english "Yes."
        german "Ja."
      else do
        english "No."
        german "Nein."

localised :: (String -> LangM' m a) -> Map Language String -> LangM' m a
localised f ts = LangM $ \l ->
  let t = localise l ts
  in f t `withLang` l

addPretext :: OutputMonad m => LangM' m a -> LangM' m a
addPretext = (>>) $
  paragraph $ translate $ do
    english "Remarks on your solution:"
    german "Anmerkungen zur eingereichten Lösung:"

multipleChoice
  :: (OutputMonad m, Ord a)
  => Map Language String
  -> Maybe String
  -> Map a Bool
  -> [a]
  -> Rated m
multipleChoice what msolutionString solution choices = do
  let cs = sort $ nubOrd choices
      points = percentPer
        solution
        (toMapping (M.keys solution) cs)
      isCorrect = null [c | c <- cs, c `notElem` valid]
  yesNo isCorrect $ multiLang [
    (English, "Given " ++ localise English what ++ " are correct?"),
    (German, "Die angegebenen " ++ localise German what ++ " sind korrekt?")
    ]
  when isCorrect $ yesNo (cs ==  valid) $ multiLang [
    (English, "Given " ++ localise English what ++ " are exhaustive?"),
    (German, "Die angegebenen " ++ localise German what ++ " sind vollständig?")
    ]
  printSolutionAndAssert msolutionString points
  where
    valid = M.keys $ M.filter (== True) solution

printSolutionAndAssert
  :: OutputMonad m
  => Maybe String
  -> Rational
  -> Rated m
printSolutionAndAssert msolutionString points = do
  for_ msolutionString $ \solutionString ->
    when (points /= 1) $ paragraph $ do
      translate $ do
        english "The correct solution is:"
        german "Die richtige Lösung ist:"
      code solutionString
  unless (points >= 1 % 2) $ refuse $ return ()
  return points

singleChoiceSyntax
  :: (OutputMonad m, Eq a, Show a)
  => Bool
  -> [a]
  -> a
  -> LangM m
singleChoiceSyntax withSolution options choice = do
  let assert = continueOrAbort withSolution
  assert (choice `elem` options) $ translate $ do
    let c = show choice
    english $ "Chosen option " ++ c  ++ " is available?"
    german $ "Gewählte Option " ++ c ++ " ist verfügbar?"

singleChoice
  :: (OutputMonad m, Eq a)
  => Map Language String
  -> Maybe String
  -> a
  -> a
  -> Rated m
singleChoice what msolutionString solution choice = do
  let correct = solution == choice
      points = if correct then 1 else 0
      assert = continueOrAbort $ isJust msolutionString
  assert correct $ multiLang [
    (English, "Chosen " ++ localise English what ++ " is correct?"),
    (German, "Der/die/das gewählte " ++ localise German what ++ " ist korrekt?")]
  printSolutionAndAssert msolutionString points

{-|
Returns a list stating for each element of the first list
if the element exists within the second list.
-}
toMapping :: Eq a => [a] -> [a] -> [(a, Bool)]
toMapping xs ys = fmap (\x -> (x, x `elem` ys)) xs

{-|
The relative amount of elements in the list
being a member of the map with the same value.
-}
percentPer :: (Eq a, Ord k) => Map k a -> [(k, a)] -> Rational
percentPer xs = (% toInteger (length xs)) . sum
  . fmap (\(k, y) -> if M.lookup k xs == Just y then 1 else 0)

data Language = English | German
  deriving (Enum, Eq, Ord)

multiLang :: OutputMonad m => [(Language, String)] -> LangM m
multiLang = translated . M.fromList

localise :: Language -> Map Language String -> String
localise l lm = fromMaybe nonExistent $ M.lookup l lm
  where
    nonExistent
      | null lm   = error "missing translation"
      | otherwise = snd $ M.findMin lm

translate :: OutputMonad m => State (Map Language String) a -> LangM m
translate = translated . translations

translations :: State (Map k a1) a2 -> Map k a1
translations = flip execState M.empty

english :: String -> State (Map Language String) ()
english = modify . M.insert English

german :: String -> State (Map Language String) ()
german = modify . M.insert German

newtype LangM' m a = LangM { withLang :: Language -> m a}
type LangM m = LangM' m ()
type Rated m = LangM' m Rational

instance MonadIO m => MonadIO (LangM' m) where
  liftIO = LangM . const . liftIO

instance Functor m => Functor (LangM' m) where
  fmap f (LangM o) = LangM $ fmap f . o

instance Applicative m => Applicative (LangM' m) where
  pure x = LangM . const $ pure x
  LangM f <*> LangM x = LangM $ \l -> f l <*> x l

instance Monad m => Monad (LangM' m) where
  LangM x >>= f = LangM $ \l -> x l >>= (\x' -> withLang (f x') l)

instance MonadTrans LangM' where
  lift m = LangM $ const m

class Monad m => OutputMonad m where
  assertion  :: Bool -> LangM m -> LangM m
  enumerate  :: (k -> String) -> (a -> String) -> Map k a -> LangM m
  image      :: FilePath -> LangM m
  images     :: (k -> String) -> (a -> FilePath) -> Map k a -> LangM m
  paragraph  :: LangM m -> LangM m
  refuse     :: LangM m -> LangM m
  text       :: String -> LangM m
  enumerateM :: (a -> LangM m) -> [(a, LangM m)] -> LangM m
  itemizeM   :: [LangM m] -> LangM m
  indent     :: LangM m -> LangM m
  latex      :: String -> LangM m
  code       :: String -> LangM m
  translated :: Map Language String -> LangM m

data Out o =
  Abort |
  Format o |
  Localised (Map Language String)

newtype ReportT o m r = Report { unReport :: MaybeT (WriterT [Out o] m) r }
  deriving newtype (Alternative, Applicative, Functor, Monad, MonadIO)

instance MonadTrans (ReportT o) where
  lift m = Report $ MaybeT $ WriterT $ fmap (\x -> (Just x, [])) m

type Report o r = ReportT o Identity r

recoverFrom :: Alternative m => LangM m -> LangM m
recoverFrom x = LangM $ \l -> (x `withLang` l) <|> pure ()

recoverWith :: Alternative m => a -> LangM' m b -> LangM' m (Either a b)
recoverWith x m = LangM $ \l -> (Right <$> (m `withLang` l)) <|> pure (Left x)

getOutsWithResult :: Monad m => ReportT o m a -> m (Maybe a, [Out o])
getOutsWithResult = runWriterT . getAllOuts'

getAllOuts :: Monad m => ReportT o m a -> m [Out o]
getAllOuts = execWriterT . getAllOuts'

getAllOuts' :: Monad m => ReportT o m a -> WriterT [Out o] m (Maybe a)
getAllOuts' r = do
  x <- runMaybeT $ unReport r
  case x of
    Nothing -> pass $ return (x, (Abort:))
    Just _ -> return x

combineLangMs :: ([m a] -> m b) -> [LangM' m a] -> LangM' m b
combineLangMs f oms = LangM $ \l ->
  let rs = (`withLang` l) <$> oms
  in f rs

combineLangM :: (m a -> m b -> m c) -> LangM' m a -> LangM' m b -> LangM' m c
combineLangM f x y = LangM $ \l ->
  let x' = x `withLang` l
      y' = y `withLang` l
  in f x' y'

combineReports
  :: Monad m
  => (Map Language String -> o)
  -> ([[o]] -> o)
  -> [LangM' (ReportT o m) a]
  -> LangM' (ReportT o m) ()
combineReports l = combineLangMs . combineReports' l

combineReports'
  :: Monad m
  => (Map Language String -> o)
  -> ([[o]] -> o)
  -> [ReportT o m a]
  -> ReportT o m ()
combineReports' l f rs = Report $ do
  rs' <- lift . lift $ getAllOuts `mapM` rs
  os <- MaybeT . return $ mapM (toOutput l) `mapM` rs'
  tell . (:[]) . Format $ f os

combineWithReports
  :: Monad m
  => (Map Language String -> o)
  -> ([b] -> o)
  -> ([o] -> b)
  -> [LangM' (ReportT o m) a]
  -> LangM' (ReportT o m) ()
combineWithReports l f g = combineLangMs $ combineReports' l (f . fmap g)

alignOutput
  :: Monad m
  => (Map Language String -> o)
  -> ([o] -> o)
  -> LangM' (ReportT o m) a
  -> LangM' (ReportT o m) ()
alignOutput l = mapLangM . alignOutput' l

alignOutput'
  :: Monad m
  => (Map Language String -> o)
  -> ([o] -> o)
  -> ReportT o m a
  -> ReportT o m ()
alignOutput' l f r = Report $ do
  r' <- lift . lift . getAllOuts $ r
  xs  <- MaybeT . return $ toOutput l `mapM` r'
  tell . (:[]) . Format $ f xs

toOutput
  :: (Map Language String -> o)
  -> Out o
  -> Maybe o
toOutput _ Abort         = Nothing
toOutput _ (Format x)    = Just x
toOutput f (Localised x) = Just $ f x

combineTwoReports
  :: Monad m
  => (Map Language String -> o)
  -> ([o] -> [o] -> o)
  -> LangM' (ReportT o m) a
  -> LangM' (ReportT o m) b
  -> LangM' (ReportT o m) ()
combineTwoReports l = combineLangM . combineTwoReports' l

combineTwoReports'
  :: Monad m
  => (Map Language String -> o)
  -> ([o] -> [o] -> o)
  -> ReportT o m a
  -> ReportT o m b
  -> ReportT o m ()
combineTwoReports' l f r1 r2 = do
  r1' <- lift $ getAllOuts r1
  case toOutput l `mapM` r1' of
    Nothing -> void r1
    Just x  -> alignOutput' l (f x) r2

format :: Monad m => o -> LangM' (ReportT o m) ()
format = lift . Report . tell . (:[]) . Format

abortWith :: Monad m => o -> LangM' (ReportT o m) b
abortWith d = do
  format d
  lift $ Report $ MaybeT (return Nothing)

toAbort
  :: Monad m
  => (Map Language String -> o)
  -> LangM' (ReportT o m) a
  -> LangM' (ReportT o m) b
toAbort l = mapLangM $ \r -> Report $ do
  r' <- lift . lift $ getAllOuts r
  xs  <- MaybeT . return $ toOutput l `mapM` r'
  tell $ Format <$> xs
  MaybeT $ return Nothing

mapLangM :: (m a -> m b) -> LangM' m a -> LangM' m b
mapLangM f om = LangM $ f . withLang om

instance OutputMonad Maybe where
  assertion b _   = unless b $ lift Nothing
  enumerate _ _ _ = return ()
  image _         = return ()
  images _ _ _    = return ()
  paragraph xs    = xs
  refuse xs       = xs >> lift Nothing
  text _          = return ()
  enumerateM f xs = (\(x, y) -> f x >> y) `mapM_` xs
  itemizeM        = foldM ((>>) . return) ()
  indent xs       = xs
  latex _         = return ()
  code _          = return ()
  translated _    = return ()
