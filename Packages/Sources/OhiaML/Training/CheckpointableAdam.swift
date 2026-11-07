import Foundation
import MLX

enum CheckpointableAdamError: Error, LocalizedError, Equatable {
    case parameterGradientMismatch
    case noState
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .parameterGradientMismatch:
            "Adam gradients did not match the trainable parameter names."
        case .noState:
            "Adam has no optimizer moments to checkpoint."
        case .invalidState(let detail):
            "Adam checkpoint is incompatible: \(detail)"
        }
    }
}

/// Bias-corrected Adam whose named moment tensors form a stable checkpoint
/// contract. MLX Swift's built-in optimizer intentionally exposes only an
/// opaque ordered `innerState`, which cannot safely survive dependency changes.
final class CheckpointableAdam {
    static let identifier = "ohia-adam-bias-corrected"

    private struct Moments {
        let first: MLXArray
        let second: MLXArray
    }

    private static let firstPrefix = "first_moment."
    private static let secondPrefix = "second_moment."

    var learningRate: Float
    let betas: (Float, Float)
    let epsilon: Float
    private(set) var step = 0
    private var moments: [String: Moments] = [:]

    init(
        learningRate: Float,
        betas: (Float, Float) = (0.9, 0.999),
        epsilon: Float = 1e-8
    ) {
        self.learningRate = learningRate
        self.betas = betas
        self.epsilon = epsilon
    }

    func update(
        parameters: [String: MLXArray],
        gradients: [String: MLXArray]
    ) throws -> [String: MLXArray] {
        guard parameters.isEmpty == false,
              Set(parameters.keys) == Set(gradients.keys) else {
            throw CheckpointableAdamError.parameterGradientMismatch
        }

        let nextStep = step + 1
        let beta1Power = Float(Foundation.pow(Double(betas.0), Double(nextStep)))
        let beta2Power = Float(Foundation.pow(Double(betas.1), Double(nextStep)))
        var updated: [String: MLXArray] = [:]
        var nextMoments: [String: Moments] = [:]
        updated.reserveCapacity(parameters.count)
        nextMoments.reserveCapacity(parameters.count)

        for name in parameters.keys.sorted() {
            guard let parameter = parameters[name], let gradient = gradients[name] else {
                throw CheckpointableAdamError.parameterGradientMismatch
            }
            let prior = moments[name] ?? Moments(
                first: MLXArray.zeros(like: parameter),
                second: MLXArray.zeros(like: parameter)
            )
            let first = betas.0 * prior.first + (1 - betas.0) * gradient
            let second = betas.1 * prior.second + (1 - betas.1) * square(gradient)
            let correctedFirst = first / (1 - beta1Power)
            let correctedSecond = second / (1 - beta2Power)
            let value = parameter
                - learningRate * correctedFirst / (sqrt(correctedSecond) + epsilon)
            nextMoments[name] = Moments(first: first, second: second)
            updated[name] = value
        }

        eval(
            Array(updated.values)
                + nextMoments.values.flatMap { [$0.first, $0.second] }
        )
        moments = nextMoments
        step = nextStep
        return updated
    }

    func saveState(
        to url: URL,
        policyIdentifier: String
    ) throws -> TrainingOptimizerStateDescriptor {
        guard moments.isEmpty == false, step > 0 else {
            throw CheckpointableAdamError.noState
        }
        var arrays: [String: MLXArray] = [:]
        arrays.reserveCapacity(moments.count * 2)
        for (name, state) in moments {
            arrays[Self.firstPrefix + name] = state.first
            arrays[Self.secondPrefix + name] = state.second
        }
        let descriptor = TrainingOptimizerStateDescriptor(
            optimizerIdentifier: Self.identifier,
            optimizerStep: step,
            stateTensorCount: arrays.count,
            policyIdentifier: policyIdentifier,
            learningRate: Double(learningRate)
        )
        try MLX.save(
            arrays: arrays,
            metadata: Self.fileMetadata(for: descriptor),
            url: url
        )
        return descriptor
    }

    func loadState(
        from url: URL,
        descriptor: TrainingOptimizerStateDescriptor,
        parameters: [String: MLXArray]
    ) throws {
        guard descriptor.schemaVersion == TrainingOptimizerStateDescriptor.currentSchemaVersion,
              descriptor.optimizerIdentifier == Self.identifier,
              descriptor.policyIdentifier == TrainingOptimizationPolicy.current.identifier
                || descriptor.policyIdentifier.hasPrefix("test-") else {
            throw CheckpointableAdamError.invalidState("descriptor identity did not match")
        }
        let (arrays, metadata) = try MLX.loadArraysAndMetadata(url: url)
        guard metadata == Self.fileMetadata(for: descriptor),
              arrays.count == descriptor.stateTensorCount,
              descriptor.optimizerStep > 0 else {
            throw CheckpointableAdamError.invalidState("file metadata did not match its manifest")
        }

        var restored: [String: Moments] = [:]
        restored.reserveCapacity(parameters.count)
        for (name, parameter) in parameters {
            guard let first = arrays[Self.firstPrefix + name],
                  let second = arrays[Self.secondPrefix + name],
                  first.shape == parameter.shape,
                  second.shape == parameter.shape,
                  first.dtype == parameter.dtype,
                  second.dtype == parameter.dtype else {
                throw CheckpointableAdamError.invalidState(
                    "missing or incompatible moments for \(name)"
                )
            }
            restored[name] = Moments(first: first, second: second)
        }
        guard restored.count * 2 == arrays.count else {
            throw CheckpointableAdamError.invalidState("optimizer contained unexpected tensors")
        }
        eval(restored.values.flatMap { [$0.first, $0.second] })
        moments = restored
        step = descriptor.optimizerStep
        learningRate = Float(descriptor.learningRate)
    }

    private static func fileMetadata(
        for descriptor: TrainingOptimizerStateDescriptor
    ) -> [String: String] {
        [
            "schema_version": String(descriptor.schemaVersion),
            "optimizer_identifier": descriptor.optimizerIdentifier,
            "optimizer_step": String(descriptor.optimizerStep),
            "state_tensor_count": String(descriptor.stateTensorCount),
            "policy_identifier": descriptor.policyIdentifier,
            "learning_rate": String(descriptor.learningRate),
        ]
    }
}
