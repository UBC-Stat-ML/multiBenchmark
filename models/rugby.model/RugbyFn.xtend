package rugby

import blang.core.RealVar
import java.util.List
import blang.distributions.Generators

class RugbyFn {

    def static mean(List<RealVar> listRV) {
        listRV.stream.mapToDouble[doubleValue].average.asDouble
    }

    def static edgeCases(double result) {
        switch result {
            case 0 : Generators.ZERO_PLUS_EPS
            case Double.POSITIVE_INFINITY : Double.MAX_VALUE
            default : result
        } 
    }
   
    def static computeTheta(List<RealVar> atkStar, List<RealVar> defStar, int indexAtk, int indexDef, RealVar intercept, RealVar home) {
            edgeCases(Math.exp(atkStar.get(indexAtk).doubleValue + defStar.get(indexDef).doubleValue - mean(atkStar) - mean(defStar) + intercept.doubleValue + home.doubleValue))
        }
    
    
}
