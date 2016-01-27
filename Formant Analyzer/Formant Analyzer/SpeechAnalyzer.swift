//
//  SpeechAnalyzer.swift
//  FormantPlotter
//
//  Created by William Entriken on 1/22/16.
//  Copyright © 2016 William Entriken. All rights reserved.
//

import Foundation

class SpeechAnalyzer {
    // A few constants to be used in LPC and Laguerre algorithms.

//FIXME: make friendlier names for these

    /// Formant model length
    private let ORDER = 20
    
    /// Individual audio samples
    let samples: [Int16]
    
    /// The rates in Hz
    let sampleRate: Int
    
    /// Human formants are < 5 kHz so we do not need signal information above 10 kHz
    lazy var decimationFactor: Int = {
        return self.sampleRate / 10000
    }()
    
    private lazy var strongPart: Range<Int> = {
        return SpeechAnalyzer.findStrongPartOfSignal(self.samples, withChunks: 300, sensitivity: 0.1)
    }()
    
    /// The part of the audio which is a vowel utterance
    lazy var vowelPart: Range<Int> = {
        return SpeechAnalyzer.truncateTailsOfRange(self.strongPart, portion: 0.15)
    }()
    
    private lazy var vowelSamplesDecimated: [Int16] = {
        let range = self.vowelPart
        return SpeechAnalyzer.decimateSamples(self.samples[range], withStride: self.decimationFactor)
    }()
    
    /// Linear prediction coefficients of the vowel signal
    lazy var estimatedLpcCoefficients: [Double] = {
        return SpeechAnalyzer.estimateLpcCoefficients(samples: self.vowelSamplesDecimated, sampleRate: self.sampleRate/self.decimationFactor, modelLength: 20)
    }()
    
    /// Synthesize the frequency response for the estimated LPC coefficients
    ///
    /// - Returns: the response at frequencies 0, 5, ... Hz, the first index (identity) is 1.0
    lazy var synthesizedFrequencyResponse: [Double] = {
        let frequencies = Array(0.stride(to: self.sampleRate/self.decimationFactor/2, by: 15))
        return SpeechAnalyzer.synthesizeResponseForLPC(self.estimatedLpcCoefficients, withRate: self.sampleRate/self.decimationFactor, atFrequencies:frequencies)
    }()
    
    /// Finds at least first four formants which are in the range for estimating human vowel pronunciation
    ///
    /// - Returns: Formants in Hz
    lazy var formants: [Double] = {
        let complexPolynomial = self.estimatedLpcCoefficients.map({0.0.i + $0})
        let formants = SpeechAnalyzer.findFormants(complexPolynomial, sampleRate: self.sampleRate/self.decimationFactor)
        return SpeechAnalyzer.filterSpeechFormants(formants)
    }()

    /// Creates an analyzer with given 16-bit PCM samples
    init(int16Samples data: NSData, withFrequency rate: Int) {
        let bytesPointer = UnsafePointer<Int16>(data.bytes)
        let bufferPointer = UnsafeBufferPointer(start: bytesPointer, count: data.length / sizeof(Int16))
        samples = [Int16](bufferPointer)
        sampleRate = rate
    }
    
    //
    //MARK: Class functions that allow tweaking the parameters
    //
    
    /// Analyzes a signal to find the significant part
    ///
    /// Considers `numChunks` parts of the signal and trims ends with signal strength not greater than a `factor` of the maximum signal strength
    ///
    /// - Returns the range of the selected signal from the selected chunks
    class func findStrongPartOfSignal(signal: [Int16], withChunks numChunks: Int, sensitivity factor: Double) -> Range<Int> {
        let chunkSize = signal.count / numChunks
        var chunkEnergies = [Double]()
        var maxChunkEnergy: Double = 0
        
        guard chunkSize > 0 else {
            return 0...0
        }

        // Find the chunk with the most energy and set energy threshold
        for chunkStart in signal.startIndex.stride(through: signal.endIndex.advancedBy(-chunkSize), by: chunkSize) {
            let range = (chunkStart..<chunkStart+chunkSize)
            let chunkEnergy = signal[range].reduce(0, combine: {$0 + Double($1)*Double($1)})
            maxChunkEnergy = max(maxChunkEnergy, chunkEnergy)
            chunkEnergies.append(chunkEnergy)
        }
        let firstSelectedChunk = chunkEnergies.indexOf {$0 > maxChunkEnergy * factor} ?? 0
        let lastSelectedChunk: Int
        // http://stackoverflow.com/a/33153621/300224
        if let reverseIndex = chunkEnergies.reverse().indexOf({$0 > maxChunkEnergy * factor}) {
            lastSelectedChunk = reverseIndex.base - 1
        } else {
            lastSelectedChunk = chunkEnergies.endIndex - 1
        }
        return firstSelectedChunk * chunkSize ..< (lastSelectedChunk + 1) * chunkSize
    }
    
    /// Shrink range by `portion` of its length from each size
    /// - Parameter portion a fraction in the range 0...0.5
    class func truncateTailsOfRange(range: Range<Int>, portion: Double) -> Range<Int> {
        let start = range.startIndex + Int(portion * Double(range.count))
        let end = range.endIndex - Int(portion * Double(range.count))
        return Range(start: start, end: end)
    }

    /// Select the first of every `stride` items from `samples`
    class func decimateSamples<T: CollectionType where T.Index: Strideable>(samples: T, withStride stride: T.Index.Stride) -> Array<T.Generator.Element> {
        let selectedSamples = samples.startIndex.stride(to: samples.endIndex, by: stride)
        return selectedSamples.map({samples[$0]})
    }
    
    /// Reduce horizontal resolution of signal for plotting
    func downsampleStrongPartToSamples(newSampleCount: Int) -> [Int16] {
        let chunkSize = self.samples.count / newSampleCount
        var chunkMaxElements = [Int16]()
        
        // Find the chunk with the most energy and set energy threshold
        for chunkStart in self.strongPart.startIndex.stride(through: self.strongPart.endIndex.advancedBy(-chunkSize), by: chunkSize) {
            let range = (chunkStart..<chunkStart+chunkSize)
            let maxValue = self.samples[range].maxElement()!
            chunkMaxElements.append(maxValue)
        }
        return chunkMaxElements
    }
    
    /// Estimate LPC polynomial coefficients from the signal
    /// Uses the Levinson-Durbin recursion algorithm
    /// - Returns: `modelLength` + 1 autocorrelation coefficients for an all-pole model
    /// the first coefficient is 1.0 for perfect autocorrelation with zero offset
    class func estimateLpcCoefficients(samples samples: [Int16], sampleRate rate: Int, modelLength: Int) -> [Double] {
        var correlations = [Double]()
        var coefficients = [Double]()
        var modelError: Double
        
        guard samples.count > modelLength else {
            return [Double](count: modelLength + 1, repeatedValue: 1)
        }
        
        for delay in 0 ... modelLength {
            var correlationSum = 0.0
            for sampleIndex in 0 ..< samples.count - delay {
                correlationSum += Double(samples[sampleIndex]) * Double(samples[sampleIndex + delay])
            }
            correlations.append(correlationSum)
        }
        
        // The first predictor (delay 0) is 100% correlation
        modelError = correlations[0] // total power is unexplained
        coefficients.append(1.0) // 100% correlation for zero delay
        
        // For each coefficient in turn
        for delay in 1 ... modelLength {
            // Find next reflection coefficient from coefficients and correlations
            var rcNum = 0.0
            for i in 1 ... delay {
                rcNum -= coefficients[delay - i] * correlations[i]
            }
            coefficients.append(rcNum / modelError)
            
            // Perform recursion on coefficients
            for i in 1.stride(through: delay/2, by: 1) {
                let pci = coefficients[i] + coefficients[delay] * coefficients[delay - i]
                let pcki = coefficients[delay - i] + coefficients[delay] * coefficients[i]
                coefficients[i] = pci
                coefficients[delay - i] = pcki
            }

            // Calculate residual error
            modelError *= 1.0 - coefficients[delay] * coefficients[delay]
        }
        return coefficients
    }
    
    /// Synthesize the frequency response for the estimated LPC coefficients
    ///
    /// - Parameter coefficients: an all-pole LPC model
    /// - Parameter samplingRate: the sampling frequency in Hz
    /// - Parameter frequencies: the frequencies whose response you'd like to know
    /// - Returns: a response from 0 to 1 for each frequency you are interrogating
    class func synthesizeResponseForLPC(coefficients: [Double], withRate samplingRate:Int, atFrequencies frequencies:[Int]) -> [Double] {
        var retval = [Double]()
        // Calculate frequency response of the inverse of the predictor filter
        for frequency in frequencies {
            let radians = Double(frequency) / Double(samplingRate) * M_PI * 2
            var response: Complex<Double> = 0.0 + 0.0.i
            for (index, coefficient) in coefficients.enumerate() {
                response += Complex<Double>(abs: coefficient, arg:Double(index) * radians)
            }
            retval.append(20 * log10(1.0 / response.abs))
        }
        return retval
    }
    
    /// Laguerre's method to find one root of the given complex polynomial
    /// Call this method repeatedly to find all the complex roots one by one
    /// Algorithm from Numerical Recipes in C by Press/Teutkolsky/Vetterling/Flannery
    ///
    class func laguerreRoot(polynomial: [Complex<Double>], initialGuess guess: Complex<Double> = 0.0 + 0.0.i) -> Complex<Double> {
        let m = polynomial.count - 1
        
        let MR = 8
        let MT = 10
        let maximumIterations = MR * MT // is MR * MT

        /// Error threshold
        let EPSS = 1.0e-7

        var abx, abp, abm, err: Double
        var dx, x1, b, d, f, g, h, sq, gp, gm, g2: Complex<Double>
        let frac = [0.0, 0.5, 0.25, 0.75, 0.125, 0.375, 0.625, 0.875, 1.0]
        var x = guess
        
        for iteration in 1 ... maximumIterations {
            b = polynomial[m]
            err = b.abs
            d = 0.0 + 0.0.i
            f = 0.0 + 0.0.i
            abx = x.abs
            for j in (m-1).stride(through: 0, by: -1) {
                // efficient computation of 1st and 2nd derivatives of polynomials
                // f is P``/2
                f = x * f + d
                d = x * d + b
                b = x * b + polynomial[j]
                err = b.abs + abx * err
            }
            err *= EPSS // estimate of round-off error in evaluating polynomial
            if (b.abs < err) {
                return x
            }
            g = d / b
            g2 = g * g
            h = g2 - 2.0 * f / b
            sq = sqrt((Double(m) - 1) * (Double(m) * h - g2))
            gp = g + sq
            gm = g - sq
            abp = gp.abs
            abm = gm.abs
            if (abp < abm) {
                gp = gm
            }
            dx = max(abp, abm) > 0.0 ? Double(m) / gp : (1 + abx) * (cos(Double(iteration)) + sin(Double(iteration)).i)
            x1 = x - dx
            if (x == x1) {
                return x // converged
            }
            // Every so often we take a fractional step, to break any limit cycle (itself a rare occurrence)
            if iteration % MT > 0 {
                x = x1
            } else {
                x = x - frac[iteration/MT] * dx
            }
        }
        NSLog("Too many iterations in Laguerre, giving up")
        return 0 + 0.i
    }
    
    /// Use Laguerre's method to find roots.
    ///
    /// - Parameter polynomial: coefficients of the input polynomial
    /// - Note: Does not implement root polishing, so accuracy may be impacted
    /// - Note: May include duplicated roots/formants
    class func findFormants(polynomial: [Complex<Double>], sampleRate rate: Int) -> [Double] {
        /// Laguerre imaginary noise gate
        let EPS = 2.0e-6

        var roots = [Complex<Double>]()
        var deflatedPolynomial = polynomial
        let modelOrder = polynomial.count - 1
        
        for j in modelOrder.stride(through: 1, by: -1) {
            var root = SpeechAnalyzer.laguerreRoot(deflatedPolynomial)
            
            // If imaginary part is very small, ignore it
            if abs(root.imag) < 2.0 * EPS * abs(root.real) {
                root.imag = 0.0
            }
            roots.append(root)
            
            // Perform forward deflation. Divide by the factor of the root found above
            var b = deflatedPolynomial[j]
            for jj in (j-1).stride(through: 0, by: -1) {
                let c = deflatedPolynomial[jj]
                deflatedPolynomial[jj] = b
                b = root * b + c
            }
        }
        
        let polishedRoots = roots.map({SpeechAnalyzer.laguerreRoot(polynomial, initialGuess: $0)})
        //MAYBE: This may cause duplicated roots, is that a problem?
        
        // Find real frequencies corresponding to all roots
        let formantFrequencies = polishedRoots.map({$0.arg * Double(rate) / M_PI / 2})
        return formantFrequencies.sort()
    }

    /// Finds the first four formants and cleans out negatives, and other problems
    ///
    /// - Returns: Formants in Hz
    class func filterSpeechFormants(formants: [Double]) -> [Double] {
        /// Human minimum format ability in Hz
        let MIN_FORMANT = 50.0
        
        /// Maximum format ability in Hz
        ///
        /// - Note: This should be lower than sampling rate / 2 - MIN_FORMANT
        let MAX_FORMANT = 5000.0
        
        /// Formants closer than this will be merged into one, in Hz
        let MIN_DISTANCE = 10.0
        
        var editedFormants = formants.sort().flatMap({$0 >= MIN_FORMANT && $0 <= MAX_FORMANT ? $0 : nil})
        var done = false
        while !done {
            {
                for (index, formantA) in editedFormants.enumerate() {
                    guard index < editedFormants.count - 1 else {
                        continue
                    }
                    let formantB = editedFormants[index.successor()]
                    if abs(formantA - formantB) < MIN_DISTANCE {
                        let newFormant = (formantA + formantB) / 2
                        editedFormants.removeAtIndex(editedFormants.indexOf(formantA)!)
                        editedFormants.removeAtIndex(editedFormants.indexOf(formantB)!)
                        editedFormants.append(newFormant)
                        editedFormants = editedFormants.sort()
                        return
                    }
                }
                done = true
            }()
        }
        return editedFormants
    }
}