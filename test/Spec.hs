import Test.Hspec
import qualified Domain.TypesSpec
import qualified State.BidSpec

main :: IO ()
main = hspec $ do
    Domain.TypesSpec.spec
    State.BidSpec.spec
