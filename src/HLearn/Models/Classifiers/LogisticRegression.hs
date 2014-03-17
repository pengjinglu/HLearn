module HLearn.Models.Classifiers.LogisticRegression
    where

import Control.DeepSeq
import Control.Monad
import Control.Monad.Random
import Data.List.Extras
import Data.Maybe
import Data.Typeable
import qualified Data.ByteString.Lazy as BS
import qualified Data.Foldable as F
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Storable as VS
import Foreign.Storable
import System.IO

import Data.Csv
import Numeric.LinearAlgebra hiding ((<>))
-- import qualified Numeric.LinearAlgebra as LA

import Debug.Trace

import HLearn.Algebra
import qualified HLearn.Algebra.LinearAlgebra as LA
import HLearn.Evaluation.CrossValidation
import HLearn.Metrics.Lebesgue
import HLearn.Models.Distributions
import HLearn.Models.Classifiers.Common
import qualified HLearn.Optimization.GradientDescent as Recipe
import qualified HLearn.Optimization.NewtonRaphson as Recipe
import qualified HLearn.Optimization.Common as Recipe


-------------------------------------------------------------------------------
-- data types

newtype LogisticRegression dp = LogisticRegression
    { weights :: Map.Map (Label dp) (Attributes dp)
    }

deriving instance 
    ( NFData (Scalar dp)
    , NFData (Label dp)
    , NFData (Attributes dp)
    ) => NFData (LogisticRegression dp)

-- class InnerProduct v where
--     inner :: v -> v -> Scalar v

-- instance (Storable r, Num r) => InnerProduct (Vector r) where
--     inner v1 v2 = sum $ zipWith (*) (VG.toList v1) (VG.toList v2)

deriving instance 
    ( Show (Label dp)
    , Show (Scalar dp)
    , Show (Attributes dp)
    , Storable (Scalar dp)
    ) => Show (LogisticRegression dp)

-------------------------------------------------------------------------------
-- training

instance Monoid (LogisticRegression dp) where
    mempty = undefined
    mappend = undefined


-- squaredLoss yhat y = 0.5 * (yhat-y)^2

zeroOneLoss yhat y = if yhat==y
    then 1
    else 0

instance 
    ( Ord dp
    , Ord (Label dp)
    , Labeled dp
    , Attributes dp ~ vec r
    , VG.Vector vec r
    , Floating r
    , Monoid r
    , Typeable r
    , Typeable vec
    , r ~ Scalar dp
    , Ord r
    , r ~ Scalar (vec r)
    , InnerProduct (vec r)
    , vec ~ LA.Vector
    , LA.Field r
--     , Container vec r
    , Show (Label dp) 
    , Show (vec r)
    , Show r
    , Show dp
    ) => HomTrainer (LogisticRegression dp) 
        where
    type Datapoint (LogisticRegression dp) = dp

    train = lrtrain2
--     train = zeroWeights
--     train = nbtrain 

lrtrain2 :: forall dp vec r container.
    ( Ord dp
    , Ord (Label dp)
    , Labeled dp
    , Attributes dp ~ vec r
    , VG.Vector vec r
    , Floating r
    , Monoid r
    , Typeable r
    , Typeable vec
    , r ~ Scalar dp
    , Ord r
    , r ~ Scalar (vec r)
    , InnerProduct (vec r)
    , vec ~ LA.Vector
    , LA.Field r
    , Show (Label dp) 
    , Show (vec r)
    , Show r
    , Show dp
    , F.Foldable container
    ) => container dp -> LogisticRegression dp
-- lrtrain2 dps = LogisticRegression $ Map.fromList $ go $ Map.assocs $ weights $ nbtrain dps
lrtrain2 dps = LogisticRegression $ Map.fromList $ go $ Map.assocs $ weights $ zeroWeights dps
    where
        -- the weights for the last label are set to zero;
        -- this is equivalent to running the optimization procedure,
        -- but much cheaper
        go ((l,w0):[]) = [(l, VG.replicate (VG.length w0) 0)]

        -- calculate the weights for label l
--         go ((l,w0):xs) = (l, Recipe.traceOptimization $ Recipe.conjugateGradientDescent g g' w0):go xs
        go ((l,w0):xs) = trace ("f''w0="++show f''w0) 
            $ trace ("eig f''w0="++ show (LA.eigenvalues f''w0))
            $ trace ("loc="++show loc)
            $ trace ("loc'="++show loc')
            $ trace ("loc/loc'="++show (VG.zipWith (/) loc loc'))
            $ deepseq loc $ deepseq loc' $  (l, loc''):go xs
--         go ((l,w0):xs) = (l, Recipe.traceOptimization $ Recipe.newtonRaphson g g' g'' loc):go xs
--         go ((l,w0):xs) = (l, Recipe.traceOptimization $ Recipe.newtonRaphson f f' f'' w0):go xs
--         go ((l,w0):xs) = (l, Recipe.traceOptimization $ Recipe.conjugateGradientDescent f f' w0):go xs
            where

                f w = sumOver dps $ \dp ->
                        logSumOfExp2 0 $ -y dp * inner w (getAttributes dp)

                f' w = inverse $ sumOver dps $ \dp ->
                        (y dp*(1-invlogit (y dp*inner w (getAttributes dp)))) .* (getAttributes dp)
                        
                f'' w = sumOver dps $ \dp ->
                        LA.outerProduct (getAttributes dp) (getAttributes dp)
                        /. (1 + exp (- y dp * inner w (getAttributes dp)))

                y dp = bool2num $ getLabel dp==l 

                g w = fw0
                       + inner (f'w0) (w <> inverse w0)
                       + 0.5 .* ((w <> inverse w0) `LA.matProduct` (f''w0)) `inner` (w <> inverse w0)

                g' w = f'w0
                       <> ((w <> inverse w0) `LA.matProduct` (f''w0))

                g'' w = f''w0

                fw0 = f loc
                f'w0 = f' loc
                f''w0 = f'' loc

                loc = trace "loc" $ Recipe.traceOptimization $ Recipe.newtonRaphson f f' f'' w0
                loc' = Recipe.traceOptimization $ Recipe.newtonRaphson g g' g'' loc
                loc'' = Recipe.traceOptimization $ Recipe.newtonRaphson f f' f'' loc'
--                 loc'' = Recipe.traceOptimization $ Recipe.conjugateGradientDescent f f' loc'


invlogit x = 1 / (1 + exp (-x))

-- | calculates log . sum . map exp in a numerically stable way 
logSumOfExp xs = m + log (sum [ exp $ x-m | x <- xs ] )
    where
        m = maximum xs

-- | calculates log $ exp x1 + exp x2 in a numerically stable way
logSumOfExp2 x1 x2 = m + log ( exp (x1-m) + exp (x2-m) )
    where
        m = max x1 x2

sumOver :: (F.Foldable container, Monoid r) => container x -> (x -> r) -> r
sumOver xs f = F.foldMap f xs


zeroWeights :: forall dp vec r container.
    ( Ord dp
    , Ord (Label dp)
    , Labeled dp
    , Attributes dp ~ vec r
    , VG.Vector vec r
    , Floating r
    , Monoid r
    , r ~ Scalar dp
    , Ord r
    , r ~ Scalar (vec r)
    , InnerProduct (vec r)
    , Show (Label dp) 
    , Show (vec r)
    , Show r
    , F.Foldable container
    ) => container dp -> LogisticRegression dp
zeroWeights dps = LogisticRegression $ Map.fromList [ (label,VG.replicate dim mempty) | label <- labels ]
    where
        labels = map getLabel $ F.toList dps
        dim = VG.length $ getAttributes $ head $ F.toList dps

nbtrain :: forall dp vec r container.
    ( Ord dp
    , Ord (Label dp)
    , Labeled dp
    , Attributes dp ~ vec r
    , VG.Vector vec r
    , Floating r
    , Monoid r
    , r ~ Scalar dp
    , Ord r
    , r ~ Scalar (vec r)
    , InnerProduct (vec r)
    , Show (Label dp) 
    , Show r
    , Show (vec r)
    , F.Foldable container
    ) => container dp -> LogisticRegression dp
nbtrain dps = LogisticRegression $ Map.fromList $ go $ Map.assocs $ weights $ zeroWeights dps
    where
        go [] = []
--         go ((l,w0):xs) = trace ("gaussianMap="++show gaussianMap) $ (l,w'):go xs
        go ((l,w0):xs) = (l,w'):go xs
            where
                w' = (VG.convert $ VG.map (\(n,t) -> mean n/(variance t+1e-6)) normV)
                   VG.// [(0,bias)]

                bias = -sumOver normV (\(n,t) -> (mean n*mean n)/(2*(variance t+1e-6)))

                normV = VG.zip (fromJust $ Map.lookup l gaussianMap) gaussianTot

        gaussianTot = foldl1 (VG.zipWith (<>)) $ Map.elems gaussianMap

        gaussianMap = Map.fromListWith (VG.zipWith (<>)) 
            [ ( getLabel dp
              , V.map (train1dp :: r -> Normal r r) $ VG.convert $ getAttributes dp
              ) 
            | dp <- F.toList dps
            ]

-------------------------------------------------------------------------------
-- classification

instance
    ( Labeled dp
    , Scalar (Attributes dp) ~ Scalar dp
    , InnerProduct (Attributes dp)
    , Floating (Scalar dp)
    , Ord (Scalar dp)
    , Attributes dp ~ vec (Scalar dp)
    , VG.Vector vec (Scalar dp)
    , Show (Scalar dp)
    , Show (Label dp)
    ) => Classifier (LogisticRegression dp)
        where
    classify m attr = fst $ argmax (\(l,s) -> s) $ Map.assocs $ Map.map (\w -> inner w attr) $ weights m

-------------------------------------------------------------------------------
-- test

test = do
    
--     let {filename = "../datasets/uci/haberman.data"; label_index=3}
--     let {filename = "../datasets/uci/pima-indians-diabetes.data"; label_index=8}
--     let {filename = "../datasets/uci/ionosphere.csv"; label_index=34}
    let {filename = "../datasets/uci/sonar.csv"; label_index=60}
--     let {filename = "../datasets/uci/optdigits.train.data"; label_index=64}
        
    let verbose = True

    -----------------------------------
    -- load data

    xse :: Either String (V.Vector (V.Vector String))  
        <- trace "loading reference dataset" $ fmap (decode HasHeader) $ BS.readFile filename
    xs <- case xse of 
        Right rs -> return rs
        Left str -> error $ "failed to parse CSV file " ++ filename ++ ": " ++ take 1000 str

    let numdp = VG.length xs
    let numdim = VG.length $ xs VG.! 0
    let numlabels = Set.size $ Set.fromList $ VG.toList $ VG.map (VG.! label_index) xs

    if verbose 
        then do 
            hPutStrLn stderr "  dataset info:"
            hPutStrLn stderr $ "    num dp:     " ++ show numdp
            hPutStrLn stderr $ "    num dim:    " ++ show numdim
            hPutStrLn stderr $ "    num labels: " ++ show numlabels
        else return ()

    -----------------------------------
    -- convert to right types

    let ys = VG.map (\x -> MaybeLabeled   
            { label = Just $ x VG.! label_index
            , attr = VG.convert ( 
--                 VG.map read $ VG.fromList $ take 2 $ VG.toList $ VG.take label_index x <> VG.drop (label_index+1) x
                VG.map read $ VG.fromList $ (:) "1" $ VG.toList $ VG.take label_index x <> VG.drop (label_index+1) x
--                 VG.map read $ VG.fromList $ VG.toList $ VG.take label_index x <> VG.drop (label_index+1) x
                :: V.Vector Double
                )
            })
            xs
            :: V.Vector (MaybeLabeled String (LA.Vector Double))

    -----------------------------------
    -- convert to right types

--     let m = train ys :: LogisticRegression (MaybeLabeled String (LA.Vector Double))
--     deepseq m $ print $ m

    let res = flip evalRand (mkStdGen 100) $ crossValidate
            (repeatExperiment 1 (kfold 10))
            errorRate
            ys
            (undefined :: LogisticRegression (MaybeLabeled String (LA.Vector Double)))

    putStrLn $ "mean = "++show (mean res)
    putStrLn $ "var  = "++show (variance res)

    putStrLn "done."