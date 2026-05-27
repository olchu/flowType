//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML
import Foundation

public protocol TokenSampling {
    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult
    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult
}

public struct SamplingResult: Sendable {
    public var tokens: [Int]
    public var logProbs: [Float]
    public var completed: Bool

    public init(
        tokens: [Int],
        logProbs: [Float],
        completed: Bool
    ) {
        self.tokens = tokens
        self.logProbs = logProbs
        self.completed = completed
    }
}

open class GreedyTokenSampler: TokenSampling {
    public var temperature: FloatType
    public var eotToken: Int
    public var decodingOptions: DecodingOptions

    public init(temperature: FloatType, eotToken: Int, decodingOptions: DecodingOptions) {
        self.temperature = temperature
        self.eotToken = eotToken
        self.decodingOptions = decodingOptions
    }

    #if canImport(CoreML.MLState)
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    private func sampleWithMLTensor(logits: MLMultiArray) async -> (token: Int, logprob: Float) {
        // Use MLTensor operations if available for sampling
        // Reference: https://github.com/huggingface/swift-transformers/blob/preview/Sources/Generation/Decoders.swift
        var logitsTensor = MLTensor(MLShapedArray<FloatType>(logits)).cast(to: Float.self)
        var nextTokenTensor: MLTensor
        var nextLogprobTensor: MLTensor

        if temperature != 0.0 {
            // Scale logits by temperature if > 0
            logitsTensor = logitsTensor / temperature
        }

        // Always softmax once
        let softmaxScores = logitsTensor.softmax(alongAxis: -1)

        if temperature != 0.0 {
            // top-k multinomial sampling
            let (topKProbs, topKIndices) = softmaxScores.topK(decodingOptions.topK)

            let rnd = topKProbs.sum() * Float.random(in: 0..<1)
            var accumTopKProbs = topKProbs.cumulativeSum(alongAxis: -1)
            accumTopKProbs += (accumTopKProbs .< rnd) * 100.0
            let topKIndex = accumTopKProbs.argsort()[..., 0]

            nextTokenTensor = topKIndices.gathering(
                atIndices: topKIndex,
                alongAxis: topKIndices.rank - 1
            )
            nextLogprobTensor = topKProbs.gathering(
                atIndices: topKIndex,
                alongAxis: topKIndices.rank - 1
            ).log()
        } else {
            nextTokenTensor = logitsTensor.argmax(alongAxis: -1)
            nextLogprobTensor = softmaxScores.gathering(atIndices: nextTokenTensor, alongAxis: -1).log()
        }

        return (
            token: await nextTokenTensor.toIntArray()[0],
            logprob: await nextLogprobTensor.toFloatArray()[0]
        )
    }
    #endif

    #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
    private func sampleWithCPU(logits: MLMultiArray) -> (token: Int, logprob: Float) {
        let count = logits.count
        guard count > 0 else {
            return (token: eotToken, logprob: 0)
        }

        let temperatureValue = Float(temperature)

        if temperatureValue == 0.0 {
            var nextToken = 0
            var maxLogit = -Float.infinity

            for index in 0..<count {
                let value = logits[index].floatValue
                if value > maxLogit {
                    maxLogit = value
                    nextToken = index
                }
            }

            var sumExp: Float = 0
            for index in 0..<count {
                sumExp += expf(logits[index].floatValue - maxLogit)
            }

            return (token: nextToken, logprob: -logf(sumExp))
        }

        let k = max(1, min(decodingOptions.topK, count))
        var topK: [(index: Int, logit: Float)] = []
        topK.reserveCapacity(k)

        for index in 0..<count {
            let scaledLogit = logits[index].floatValue / temperatureValue

            if topK.count < k {
                topK.append((index, scaledLogit))
                if topK.count == k {
                    topK.sort { $0.logit > $1.logit }
                }
            } else if scaledLogit > topK[k - 1].logit {
                topK[k - 1] = (index, scaledLogit)
                topK.sort { $0.logit > $1.logit }
            }
        }

        let maxLogit = topK[0].logit
        let weights = topK.map { expf($0.logit - maxLogit) }
        let sumWeights = weights.reduce(Float(0), +)

        guard sumWeights.isFinite, sumWeights > 0 else {
            return (token: topK[0].index, logprob: 0)
        }

        let threshold = Float.random(in: 0..<sumWeights)
        var accumulator: Float = 0

        for index in weights.indices {
            accumulator += weights[index]
            if threshold < accumulator {
                let probability = weights[index] / sumWeights
                return (token: topK[index].index, logprob: logf(probability))
            }
        }

        let fallbackProbability = weights[0] / sumWeights
        return (token: topK[0].index, logprob: logf(fallbackProbability))
    }
    #endif

    private func sampleWithBNNS(logits: MLMultiArray) -> (token: Int, logprob: Float) {
        // TODO: BNNS operations here are deprecated, replace with vDSP or MLX
        var softmaxOutput: BNNSNDArrayDescriptor?
        var argmaxOutput: BNNSNDArrayDescriptor?
        var softmaxInput: BNNSNDArrayDescriptor?
        var softmaxInputNeedsDeallocate = false

        var nextToken: Int?

        do {
            let logitsRawPointer = UnsafeMutableRawBufferPointer(
                start: logits.dataPointer,
                count: logits.count * MemoryLayout<FloatType>.stride
            )

            let logitsDescriptor = BNNSNDArrayDescriptor(
                data: logitsRawPointer,
                scalarType: FloatType.self,
                shape: .vector(logits.count, stride: 1)
            )!

            softmaxInput = logitsDescriptor

            // Scale logits by temperature if > 0
            if temperature != 0.0 {
                let scaledLogits = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: FloatType.self,
                    shape: .vector(logits.count, stride: 1)
                )

                try! BNNS.applyActivation(
                    activation: BNNS.ActivationFunction.linear(alpha: Float(1 / temperature)),
                    input: logitsDescriptor,
                    output: scaledLogits,
                    batchSize: 1
                )

                softmaxInput = scaledLogits
                softmaxInputNeedsDeallocate = true
            }

            // Always softmax once
            softmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                scalarType: Float.self,
                shape: .vector(logits.count, stride: 1)
            )

            try BNNS.applyActivation(
                activation: BNNS.ActivationFunction.softmax,
                input: softmaxInput!,
                output: softmaxOutput!,
                batchSize: 1
            )

            if temperature != 0.0 {
                // top-k multinomial sampling
                let k = decodingOptions.topK
                let bestValues = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Float.self,
                    shape: .vector(k, stride: 1)
                )
                let bestIndices = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Int32.self,
                    shape: .vector(k, stride: 1)
                )

                try! BNNS.applyTopK(
                    k: k,
                    input: softmaxOutput!,
                    bestValues: bestValues,
                    bestIndices: bestIndices,
                    axis: 0,
                    batchSize: 1
                )

                let bestValuesResult = bestValues.makeArray(of: Float.self)!
                let bestIndicesResult = bestIndices.makeArray(of: Int32.self)!

                bestValues.deallocate()
                bestIndices.deallocate()

                // multinomial sample from top-k
                let sumOfbestIndicesResult = bestValuesResult.reduce(0, +)
                let rnd = Float.random(in: 0..<sumOfbestIndicesResult)
                var accumulator = Float(0.0)
                var chosenIndex = 0
                for i in 0..<bestValuesResult.count {
                    accumulator += bestValuesResult[i]
                    if rnd < accumulator {
                        chosenIndex = i
                        break
                    }
                }

                nextToken = Int(bestIndicesResult[chosenIndex])
            } else {
                argmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Float.self,
                    shape: .vector(1, stride: 1)
                )

                try! BNNS.applyReduction(
                    BNNS.ReductionFunction.argMax,
                    input: logitsDescriptor,
                    output: argmaxOutput!,
                    weights: nil
                )

                let argmaxResult = argmaxOutput!.makeArray(of: Float.self)!

                nextToken = Int(argmaxResult[0])
            }
        } catch {
            Logging.error("Sampling error: \(error)")
        }

        // Log of softmax probability of chosen token
        let softmaxResult = softmaxOutput!.makeArray(of: Float.self)!
        let nextLogprob = log(Float(softmaxResult[nextToken!]))
        // Deallocations
        softmaxOutput?.deallocate()
        argmaxOutput?.deallocate()
        if softmaxInputNeedsDeallocate {
            softmaxInput?.deallocate()
        }

        return (token: nextToken!, logprob: nextLogprob)
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        var nextTokens = tokens
        var nextLogprobs = logProbs
        var completed = false

        var result: (token: Int, logprob: Float)
        #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
        result = sampleWithCPU(logits: logits)
        #elseif canImport(CoreML.MLState)
        if #available(macOS 15.0, iOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            result = await sampleWithMLTensor(logits: logits)
        } else {
            result = sampleWithBNNS(logits: logits)
        }
        #else
        result = sampleWithBNNS(logits: logits)
        #endif

        nextTokens = tokens + [result.token]
        nextLogprobs = logProbs + [result.logprob]
        completed = result.token == eotToken

        return SamplingResult(
            tokens: nextTokens,
            logProbs: nextLogprobs,
            completed: completed
        )
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        var finalTokens = tokens
        var finalLogProbs = logProbs
        if tokens.last != eotToken {
            finalTokens.append(eotToken)
            finalLogProbs.append(0)
        }

        return SamplingResult(tokens: finalTokens, logProbs: finalLogProbs, completed: true)
    }
}

open class BeamSearchTokenSampler: TokenSampling {
    public var beamSize: Int
    public var eotToken: Int
    public var patience: Float
    var maxCandidates: Int
    var finishedSequences: [Float]

    public init(
        beamSize: Int,
        eotToken: Int,
        patience: Float = 1
    ) {
        self.beamSize = beamSize
        self.eotToken = eotToken
        self.patience = patience
        self.maxCandidates = Int(Float(beamSize) * patience)
        self.finishedSequences = []
        if self.maxCandidates <= 0 {
            self.maxCandidates = 1
            fatalError("Invalid beam size \(beamSize) or patience \(patience)")
        }
    }

    public func reset() {
        finishedSequences = []
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }
}
